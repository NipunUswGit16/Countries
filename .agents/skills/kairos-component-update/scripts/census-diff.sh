#!/usr/bin/env bash
# census-diff.sh — the deterministic test-population diff behind the gate's `census`
# row. Every other gate compares FAILURE sets, so it can see new red but never
# missing green: a test that was deleted, t.Skip-ped, excluded by a build tag, or
# dropped because its package stopped compiling passes every failure gate by
# construction. This diffs the POPULATIONS the census recorded at each epoch and
# reports what stopped running.
#
# WHY it is run by gate.sh and not a phase: it consumes only artifacts the gate
# already produced this run — `$RUN/test-<epoch>.population.txt` / `.skips.txt` /
# `.census.status`, written as a free rider on the same suite runs (run-check.sh's
# CENSUS pipe). No second suite run, ever; the diff is `comm`.
#
# Two findings, each per TOP-LEVEL test id:
#   disappeared    — in the base-epoch population, absent from the final population
#                    AND the final skips (deleted, or no longer compiled in).
#   newly-skipped  — verdict-bearing in the base-epoch population, a skip at final
#                    (silenced at runtime; a skip is not a disappearance).
# The row also carries the count of tests ADDED since the base epoch, so a rename
# (one disappearance + one addition) reads as a rename rather than pure loss.
#
# Attribution (LABEL=final):
#   * postmerge census usable → EXECUTOR-ERA diff (final vs postmerge). The
#     structural merge legitimately deletes tests the planner already reviewed;
#     those live in the template-era CONTEXT line (postmerge vs baseline), never in
#     the row's status.
#   * postmerge census NOT usable (a run resumed across this upgrade, an INCOMPLETE
#     postmerge-gate test row) → degrade to a single baseline→final diff whose findings
#     are labeled UNATTRIBUTED — template noise must never read as executor guilt.
#
# LABEL=postmerge is the Phase 5 informational relay: the executor-era question has
# no `final` epoch yet, so the row is always INCOMPLETE (never a pass, never a
# block) and its detail carries the template-era count for the planner to see.
#
# NEVER GREEN ON A QUESTION IT COULD NOT ASK: a census that is unavailable, a
# MISMATCH, a FAILED recipe (it errored — run-check.sh discards the population and
# records that, never OK over an empty one), or a missing population at any needed
# epoch → INCOMPLETE, never a finding.
#
# EMPTY IS NOT ABSENT. An epoch whose census.status reads OK and whose population file
# exists but is EMPTY did run and did census — it censused nothing (run-check-modules.sh
# writes exactly that for an all-helpers module set: every module green, no test id in
# the tree). That is a different fact from "no census recorded", and at the final epoch
# the two are graded differently:
#   * final censused EMPTY, the base epoch was POPULATED → FAIL: mass test
#     disappearance. Only that TRANSITION fails, and it is the one total-loss case the
#     census exists for. No other gate row would catch it: every other row compares
#     FAILURE sets, and a component with no tests left produces no failures at all, so
#     deleting every test reads as a clean build and a clean tests row.
#   * final censused EMPTY and the base epoch censused empty too → PASS: there was
#     never a population to lose.
#   * final censused EMPTY and no base epoch censused at all → INCOMPLETE (nothing to
#     compare the emptiness against).
# A census recipe that silently stopped matching also produces an empty population, so
# the FAIL row says so and Phase 8's stop-or-accept valve dispositions it — a visible,
# answerable finding rather than an INCOMPLETE row riding through a passing aggregate.
#
# A base epoch (baseline/postmerge) whose population is empty is not a usable diff BASE
# — there is nothing to compare a later epoch against — so attribution degrades to the
# next epoch, or the row reads INCOMPLETE.
#
# Env in:  RUN    migration state dir (required)
#          LABEL  postmerge | final (default final)
# Cwd:     any
# Stdout:  exactly ONE gate row — `census <TAB> STATUS <TAB> detail <TAB> evidence`,
#          STATUS ∈ PASS | FAIL | INCOMPLETE. gate.sh appends it to the card.
# Out:     $RUN/census-<LABEL>.tsv — `finding <TAB> id <TAB> era`, one row per
#          finding (empty file on PASS/INCOMPLETE, so a stale one never reads as
#          findings). The evidence column points here.
# Exit:    0 = PASS; non-zero = anything else (FAIL or INCOMPLETE) — so a caller
#          that wants a bit, not the row, still fails closed.
set -u

: "${RUN:?FAIL: RUN not set}"
LABEL="${LABEL:-final}"
case "$LABEL" in
  postmerge|final) : ;;
  *) printf 'census\tINCOMPLETE\tgate-internal: LABEL must be postmerge or final (got %s)\t-\n' "$LABEL"; exit 1 ;;
esac

OUTTSV="$RUN/census-$LABEL.tsv"
mkdir -p "$RUN" 2>/dev/null || true
: > "$OUTTSV" 2>/dev/null || true

WORK=$(mktemp -d "${TMPDIR:-/tmp}/census-diff.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pop() { printf '%s/test-%s.population.txt' "$RUN" "$1"; }
skp() { printf '%s/test-%s.skips.txt' "$RUN" "$1"; }
cst() { printf '%s/test-%s.census.status' "$RUN" "$1"; }

# flat — one line, no embedded tabs/newlines; the detail/evidence land in a TSV.
# Deliberately NOT named oneline(): this file carries no copy of gate.sh's helper,
# so nothing binds them and this one may stay simple (census ids are test names).
flat() { tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-300; }

# emit <status> <detail> <evidence> — the one row, then exit with the fail-closed
# code. gate.sh reads the status field; the exit is for a standalone caller.
emit() {
  printf 'census\t%s\t%s\t%s\n' "$1" "$(printf '%s' "$2" | flat)" "$(printf '%s' "$3" | flat)"
  [[ "$1" = PASS ]] && exit 0 || exit 1
}

# epoch_usable <epoch> — census.status reads OK AND population exists non-empty, i.e.
# the epoch is a usable DIFF SIDE with ids in it. Sets EPOCH_REASON on failure.
# MISMATCH/ABSENT/missing are unusable and map to INCOMPLETE upstream. An empty
# population is unusable as a diff BASE for the same reason (no id to compare against)
# — but at the FINAL epoch it is a censused fact, not an absence: see epoch_ran.
EPOCH_REASON=""
epoch_usable() {
  local e="$1" s
  if [[ ! -f "$(cst "$e")" ]]; then EPOCH_REASON="$e census absent (no census recorded)"; return 1; fi
  s=$(tr -d '[:space:]' < "$(cst "$e")" 2>/dev/null)
  case "$s" in
    OK) : ;;
    MISMATCH) EPOCH_REASON="$e census MISMATCH (population discarded as internally inconsistent)"; return 1 ;;
    ABSENT)   EPOCH_REASON="$e census ABSENT (no module produced one)"; return 1 ;;
    FAILED)   EPOCH_REASON="$e census FAILED (the recipe itself errored — no population captured)"; return 1 ;;
    *)        EPOCH_REASON="$e census status '${s:-<empty>}' unrecognized"; return 1 ;;
  esac
  if [[ ! -f "$(pop "$e")" ]]; then EPOCH_REASON="$e population file missing"; return 1; fi
  if [[ ! -s "$(pop "$e")" ]]; then EPOCH_REASON="$e censused an empty population (no id to diff against)"; return 1; fi
  return 0
}

# epoch_ran <epoch> — census.status reads OK AND the population FILE exists; its
# contents may be empty. This is the "a suite run censused this epoch" fact, kept
# deliberately separate from epoch_usable's "…and found ids in it": run-check-modules.sh
# writes status OK with an empty population for a legitimately test-free module set, and
# ABSENT/MISMATCH (or nothing at all) when no run censused anything. The FAIL rule at
# final needs exactly that distinction, so this predicate must never fold the two.
# It leaves EPOCH_REASON alone — the caller's reason for the epoch it asked about first
# is what the row reports, and clobbering it here would rename the failing epoch.
epoch_ran() {
  local e="$1" s
  [[ -f "$(cst "$e")" ]] || return 1
  s=$(tr -d '[:space:]' < "$(cst "$e")" 2>/dev/null)
  [[ "$s" = OK ]] || return 1
  [[ -f "$(pop "$e")" ]] || return 1
  return 0
}

# sorted-set helpers, all LC_ALL=C so the comparison is a function of file contents,
# never of the ambient locale two epochs may have run under.
sset() { LC_ALL=C sort -u "$1" 2>/dev/null | sed '/^$/d'; }
# minus <A> <B> → ids in A not in B ; inter <A> <B> → ids in both.
minus() { LC_ALL=C comm -23 "$1" "$2"; }
inter() { LC_ALL=C comm -12 "$1" "$2"; }
# grep -c prints "0" AND exits 1 on an empty file, so a `|| echo 0` would double it;
# the files counted here are always produced by sset/minus/inter, so they exist.
ncount() { grep -c . "$1" 2>/dev/null || true; }

# --- template-era context (baseline vs postmerge), used by both labels ----------
# Returns a human phrase in TPL_CONTEXT; blank when baseline or postmerge is unusable
# (attribution is simply not available then — never invented).
TPL_CONTEXT=""
template_era() {
  if epoch_usable baseline && epoch_usable postmerge; then
    sset "$(pop baseline)" > "$WORK/bl.pop"
    sset "$(pop postmerge)" > "$WORK/pm.pop"
    sset "$(skp postmerge)" > "$WORK/pm.skp"
    LC_ALL=C sort -u "$WORK/pm.pop" "$WORK/pm.skp" > "$WORK/pm.seen"
    minus "$WORK/bl.pop" "$WORK/pm.seen" > "$WORK/tpl.gone"
    minus "$WORK/pm.pop" "$WORK/bl.pop" > "$WORK/tpl.added"
    TPL_CONTEXT="template-era (baseline→postmerge): $(ncount "$WORK/tpl.gone") removed, $(ncount "$WORK/tpl.added") added"
  else
    TPL_CONTEXT="template-era: unavailable (baseline or postmerge census not usable)"
  fi
}

# --- LABEL=postmerge: the Phase 5 informational relay ---------------------------
# The disappearance question needs a `final` epoch, which does not exist yet, so this
# is INCOMPLETE by construction — it blocks nothing and is relayed into the planner's
# log as the template-era count it should plan around.
if [[ "$LABEL" = postmerge ]]; then
  template_era
  emit INCOMPLETE \
    "no executor-era diff at postmerge (the final epoch does not exist yet) — informational: $TPL_CONTEXT" \
    "$TPL_CONTEXT"
fi

# --- LABEL=final: the executor-era diff ----------------------------------------
# Three final-epoch states, not two (see EMPTY IS NOT ABSENT in the header): populated,
# censused-empty (the run happened and found nothing — FIN_EMPTY), and no census at all.
# Only the third could not ask the question.
FIN_EMPTY=no
if ! epoch_usable final; then
  if epoch_ran final; then
    FIN_EMPTY=yes
  else
    emit INCOMPLETE "census unavailable at the final epoch: $EPOCH_REASON — the disappearance question could not be asked" "-"
  fi
fi
sset "$(pop final)" > "$WORK/fin.pop"
sset "$(skp final)" > "$WORK/fin.skp"
LC_ALL=C sort -u "$WORK/fin.pop" "$WORK/fin.skp" > "$WORK/fin.seen"

# Pick the attribution base: postmerge (executor-era) or, degraded, baseline
# (unattributed). If neither is usable there is nothing to diff against → INCOMPLETE.
#
# Each epoch's reason is captured under ITS OWN name: EPOCH_REASON is overwritten by
# every probe, so the row used to report the BASELINE probe's reason behind a hardcoded
# "postmerge:" label — sending the reader to the wrong artifact. The reason strings
# already name their epoch, so the row simply carries both.
PM_REASON=""; BL_REASON=""
if epoch_usable postmerge; then
  BASE=postmerge; ERA=executor-era
else
  PM_REASON="$EPOCH_REASON"
  if epoch_usable baseline; then
    BASE=baseline; ERA=unattributed
  else
    BL_REASON="$EPOCH_REASON"
    # No POPULATED base epoch. If final censused empty and a base epoch censused empty
    # too, the honest answer is PASS: both sides ran, neither had a population, so no
    # test stopped running. This is the case the FAIL rule below must not swallow — a
    # component that never had tests (an all-helpers module set) is not a mass deletion.
    if [[ "$FIN_EMPTY" = yes ]]; then
      EB=""
      if epoch_ran postmerge; then EB=postmerge
      elif epoch_ran baseline; then EB=baseline
      fi
      if [[ -n "$EB" ]]; then
        emit PASS \
          "no test disappeared or was newly skipped: the $EB epoch and the final epoch both censused an EMPTY population — there was never a population to lose (a legitimately test-free module set reads this way)" \
          "compared 0 base ($EB) vs 0 final population id(s) — $OUTTSV"
      fi
    fi
    emit INCOMPLETE "no usable base epoch to diff the final population against (${PM_REASON}; ${BL_REASON}) — census attribution impossible" "-"
  fi
fi
sset "$(pop "$BASE")" > "$WORK/base.pop"

# disappeared = base-pop \ (final-pop ∪ final-skips)
minus "$WORK/base.pop" "$WORK/fin.seen" > "$WORK/disappeared"
# newly-skipped = base-pop ∩ final-skips
inter "$WORK/base.pop" "$WORK/fin.skp" > "$WORK/newly-skipped"
# additions (count only, for rename context) = final-pop \ base-pop
minus "$WORK/fin.pop" "$WORK/base.pop" > "$WORK/added"

ND=$(ncount "$WORK/disappeared"); NS=$(ncount "$WORK/newly-skipped"); NA=$(ncount "$WORK/added")
NBASE=$(ncount "$WORK/base.pop"); NFIN=$(ncount "$WORK/fin.pop")

# The findings artifact — written whether or not the row is a pass, so a stale one
# never survives; era-labeled so the reader knows which side to suspect. The verdict
# above is computed from $WORK, not from this write, so a failed write must NOT flip
# PASS/FAIL — but it silently pointed the reader at partial/absent evidence before
# this check existed, so EVIDENCE_WARN carries the failure into the row's detail
# instead of swallowing it with `|| true`.
EVIDENCE_WARN=""
# Redirection order is load-bearing: `2>err` FIRST, `>"$OUTTSV"` second. Bash
# applies redirects left-to-right, and a failed redirect's own diagnostic goes
# to whatever fd 2 currently is — set the stderr redirect up before the one
# that can fail (e.g. $OUTTSV is unwritable, or a stray directory sits at that
# path) so bash's own "cannot create..." lands in $WORK/outtsv.err, not on the
# caller's real stderr where a gate run would leak it as unattributed noise.
{
  awk -v e="$ERA" 'NF { print "disappeared\t" $0 "\t" e }' "$WORK/disappeared"
  awk -v e="$ERA" 'NF { print "newly-skipped\t" $0 "\t" e }' "$WORK/newly-skipped"
} 2>"$WORK/outtsv.err" > "$OUTTSV" \
  || EVIDENCE_WARN=" EVIDENCE WRITE FAILED: $OUTTSV may be missing or partial ($(flat < "$WORK/outtsv.err" 2>/dev/null))."

# Template-era context is a line on the row, never its status (executor-era only).
template_era
ATTR="$ERA"
[[ "$ERA" = unattributed ]] && ATTR="unattributed (postmerge census not usable, degraded to a baseline→final diff)"

if [[ "$ND" -eq 0 ]] && [[ "$NS" -eq 0 ]]; then
  emit PASS \
    "no test disappeared or was newly skipped ($ATTR); $NA added; $TPL_CONTEXT$EVIDENCE_WARN" \
    "compared $NBASE base ($BASE) vs $NFIN final population id(s) — $OUTTSV"
elif [[ "$FIN_EMPTY" = yes ]] && [[ "$ND" -gt 0 ]]; then
  # The transition case: a POPULATED base epoch, and a final epoch that ran and censused
  # nothing. Every disappeared id is in $OUTTSV, so the row carries the RATIONALE instead
  # of a per-id list — total loss is the fact here, not which ids. (An empty final
  # population made entirely of skips lands in the generic arm below: those ids are
  # newly-skipped findings, not disappearances.)
  emit FAIL \
    "mass test disappearance: the final epoch censused an EMPTY population where $BASE had $NBASE test id(s) — $ND disappeared, $NS newly-skipped ($ERA), no verdict-bearing test ran at final. A census recipe that stopped matching reads this way too — check it before accepting$EVIDENCE_WARN" \
    "$OUTTSV — $NBASE id(s) from $BASE vs an empty final population"
else
  DIDS=$( { head -5 "$WORK/disappeared"; head -5 "$WORK/newly-skipped"; } | flat )
  emit FAIL \
    "$ND disappeared, $NS newly-skipped ($ATTR), $NA added; ${DIDS:-see artifact}; $TPL_CONTEXT$EVIDENCE_WARN" \
    "$OUTTSV — compared $BASE vs final"
fi
