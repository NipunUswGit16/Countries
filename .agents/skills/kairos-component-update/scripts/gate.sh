#!/usr/bin/env bash
# gate.sh — one script, one verdict card, for the three gate labels: the Phase 5
# postmerge gate (LABEL=postmerge), Phase 7's midplan gate (LABEL=midplan — same
# check set as postmerge, run over the current tree after every fifth committed
# task and after each Flag-set task), and the Phase 8 final gate (LABEL=final).
#
# WHY: the two gates run the same check sequence (build → tests-vs-baseline →
# YAML → producer idempotence, plus one label-specific check each), and their
# interpretation rules used to live as near-identical prose in two phase files,
# re-applied by the model late in a long context. A misapplication silently
# advances a broken baseline — the worst outcome the skill has. This script makes
# the interpretation deterministic: "red-on-red equals pass", "extractor silence
# is never green", and "a skip is never clean" are code here, not prose rules the
# model must remember to apply identically twice per run.
#
# FAIL-CLOSED BY CONSTRUCTION: a PASS row requires positive parsed evidence —
# the underlying check's status artifact exists, parses, and reads a recognized
# value — and that evidence is recorded in the card's evidence column. A missing
# status file, an unrecognized status string, an empty extracted failure set on
# a non-zero exit, or any state this script did not anticipate maps to
# "FAIL: gate-internal", never to PASS. That skews this script's own bug surface
# toward false FAILs — visible, annoying, safe — and makes the dangerous class
# (a failure rounded up to PASS) require two independent defects at once.
#
# Checks, in order (reusing the existing scripts unchanged; raw artifacts are
# written exactly as before — the card adds pointers, it replaces nothing):
#   1. build                run-check-modules.sh CHECK=build (line 3 of
#                           test-command.txt); INCOMPLETE when "no build check"
#   2. tests                run-check-modules.sh CHECK=test + comm -13 against
#                           test-baseline.failures.txt — the SCRIPT computes
#                           "new-failures empty ⇒ PASS even when the suite is red"
#   3. yaml                 yaml-gate.sh (honors $RUN/yaml-gate-ack.tsv)
#   4. producer-idempotence producer-idempotence.sh
#   5. conflict-markers     LABEL=final only: marker grep over the git-known set
#                           (tracked + untracked-but-not-ignored, minus
#                           .kairos/, vendor/ and node_modules/), including the
#                           bare-`=======` separator. The listing is consumed as
#                           git's own NUL stream — never re-split on newlines,
#                           which silently dropped a path containing one — and
#                           every listed candidate is accounted for: scanned,
#                           or counted as a directory entry / a path no longer
#                           on disk, or named in an INCOMPLETE row. The
#                           candidate list is left at
#                           $RUN/.gate-marker-files.<LABEL> as a record and is
#                           grepped in batches (one exec over a huge set is
#                           E2BIG, i.e. a scan that never ran); a `git ls-files`
#                           that FAILS, and a list that cannot be written, are
#                           both gate-internal, never the empty-list PASS
#   6. replace-directives   LABEL=postmerge/midplan only: local-path replace
#                           directives whose target resolves OUTSIDE the
#                           component root (`../…`, absolute; an in-repo
#                           `./pkg/schema` passes) across EVERY go.mod under the component
#                           root (the same module set run-check-modules.sh
#                           sweeps, .git/ vendor/ .kairos/ node_modules/
#                           testdata/ excluded) — emitted as NEEDS-INPUT, never
#                           auto-decided. Parsed with `go mod edit -json`
#                           (codev-check.sh's primitive) and, where `go` is
#                           absent or its parse fails, with a block-aware awk
#                           fallback: a block-form `replace ( … )` carries the
#                           keyword only on the OPENING line, so the line-form
#                           grep this check used to be missed exactly the
#                           co-dev shape it exists for. That fallback covers the
#                           block and line forms, CRLF line endings and go.mod's
#                           quoted token spellings, and nothing outside that
#                           shape — it is a scanner, not go's modfile parser, so
#                           it narrows coverage. The row's detail names
#                           which method ran, and a file neither method could
#                           parse is gate-internal — never a PASS claiming
#                           more than was checked
#   7. ask-user             LABEL=postmerge ONLY: coverage compare of the
#                           classified ask-user set (the three ask-user buckets
#                           across classification.tsv + binaries.txt, union
#                           de-duplicated by path — the same union
#                           apply-ask-user.sh enacts from) against
#                           $RUN/ask-user-applied.tsv. Not at midplan/final: a
#                           plan task may legitimately revert an applied item,
#                           and a row flagging that would be a false positive —
#                           the coverage question is only well-posed
#                           immediately after Phase 5. Deliberately redundant
#                           with apply-ask-user.sh's own fail-closed check:
#                           the script catches a half-answered batch; only
#                           this row catches step 4b being skipped entirely.
#                           The classification's synthetic-tree binding
#                           ($RUN/classification-trees.tsv vs $SYNTH — the same
#                           one structural-merge.sh refuses on) is re-verified
#                           BEFORE the tally: a coverage number computed from a
#                           classification derived against other trees audits a
#                           set nobody enacted. A mismatch or a missing binding
#                           is a FAIL carrying the re-run-Phase-3 remedy; a
#                           binding this run cannot check at all ($SYNTH unset or
#                           no longer a synthetic repo) degrades the row to
#                           INCOMPLETE — unverifiable coverage is never a silent
#                           PASS, and never a block on an optional input
#   8. census               LABEL=final: the executor-era test-population diff
#                           (census-diff.sh) — a `disappeared` or `newly-skipped`
#                           top-level test id is a FAIL, and so is a final epoch
#                           that ran and censused an EMPTY population where the
#                           base epoch had ids (mass test disappearance: the one
#                           total loss no failure-set row can see, since a
#                           component with no tests left produces no failures).
#                           Phase 8's stop-or-accept valve applies to both.
#                           LABEL=postmerge: the Phase 5
#                           informational relay, always INCOMPLETE, carrying the
#                           template-era count for the planner. No census row at
#                           midplan. The recipe is read from the sibling
#                           $RUN/census-command.txt and fed to the test check's
#                           single suite run as CENSUS — no second run, ever; an
#                           absent/`no census extractor` recipe writes no census
#                           artifacts and census-diff reports INCOMPLETE. So does
#                           any tests-check refusal arm: this label's census
#                           triplet is cleared before that check dispatches, so
#                           the row can only ever describe a suite run THIS
#                           invocation made
#
# Env in:  PHASE_KEY  required — the key stated in phases/5-structural.md,
#                     phases/7-execution.md OR phases/8-finalize.md (one gate,
#                     three call sites; any of those keys proves a load)
#          LABEL      postmerge | midplan | final (required)
#          RUN        migration state dir (required)
#          SYNTH      optional — materialized target tree, read by TWO
#                     consumers: the YAML shape layer's oracle (unset → that
#                     layer reports a skip) and the postmerge ask-user row's
#                     classification-tree binding re-verify at check 7 (unset →
#                     that binding is unverifiable and the row degrades to
#                     INCOMPLETE). Either way incomplete coverage, never a
#                     silent pass
# Cwd:     the run's gate cwd — a committed git tree the calling phase cds
#          into and gate.sh reads in place; the cwd IS the parameter, gate.sh
#          takes no flag naming which tree (reference/gates.md → The gate cwd)
# Stdout:  the verdict card, TSV — check <TAB> status <TAB> detail <TAB> evidence,
#          one row per check, then a final "AGGREGATE <TAB> <status>" line.
#          status ∈ PASS | FAIL | INCOMPLETE | NEEDS-INPUT. The card is also
#          written to $RUN/gate-<LABEL>.tsv. Interpretation contract (what the
#          orchestrator does with each status): reference/gates.md.
# Exit:    0 = AGGREGATE PASS; 1 = anything else
set -u

# Phase-load guard: the three keys are stated ONLY in phases/5-structural.md,
# phases/7-execution.md and phases/8-finalize.md, so an orchestrator that
# skipped loading the phase file cannot know any of them. One gate serves three
# phases, so any of the keys proves a load; the refusal names the file for the
# label being attempted.
case "${PHASE_KEY:-}" in
  p2enxd25|vk3rq8hd|e9tr6bjs) : ;;
  *)
    case "${LABEL:-}" in
      final)   echo "FAIL: load phases/8-finalize.md first" >&2 ;;
      midplan) echo "FAIL: load phases/7-execution.md first" >&2 ;;
      *)       echo "FAIL: load phases/5-structural.md first" >&2 ;;
    esac
    exit 1
    ;;
esac

[[ -n "${RUN:-}" ]] || { echo "FAIL: RUN not set" >&2; exit 1; }
case "${LABEL:-}" in
  postmerge|midplan|final) : ;;
  *) echo "FAIL: LABEL must be postmerge, midplan or final (got '${LABEL:-}')" >&2; exit 1 ;;
esac
mkdir -p "$RUN"

# The card on disk is only ever THIS run's verdict: remove any previous
# $RUN/gate-<LABEL>.tsv up front, so an interrupted re-run leaves no card at
# all — never a stale "AGGREGATE PASS" describing a tree this run never checked.
rm -f "$RUN/gate-$LABEL.tsv"

HERE=$(cd "$(dirname "$0")" && pwd)
CARD=$(mktemp "${TMPDIR:-/tmp}/gate-card.XXXXXX")
CMP=$(mktemp "${TMPDIR:-/tmp}/gate-comm.XXXXXX")
CMPA=$(mktemp "${TMPDIR:-/tmp}/gate-comm-a.XXXXXX")
CMPB=$(mktemp "${TMPDIR:-/tmp}/gate-comm-b.XXXXXX")
AURAW=$(mktemp "${TMPDIR:-/tmp}/gate-askuser-raw.XXXXXX")
AUC=$(mktemp "${TMPDIR:-/tmp}/gate-askuser.XXXXXX")
MRAW=$(mktemp "${TMPDIR:-/tmp}/gate-marker-raw.XXXXXX")
MERR=$(mktemp "${TMPDIR:-/tmp}/gate-marker-err.XXXXXX")
MOUT=$(mktemp "${TMPDIR:-/tmp}/gate-marker-hits.XXXXXX")
RRAW=$(mktemp "${TMPDIR:-/tmp}/gate-gomod-raw.XXXXXX")
RLIST=$(mktemp "${TMPDIR:-/tmp}/gate-gomod.XXXXXX")
RHITSF=$(mktemp "${TMPDIR:-/tmp}/gate-replace-hits.XXXXXX")
# Every mktemp above is checked before anything runs. A failed mktemp (a stale
# or reaped TMPDIR — macOS cleans /var/folders/…/T — or a full disk) yields an
# EMPTY variable, and this script deliberately runs without set -e: every
# `row()` append onto an empty "$CARD" then fails silently, and the aggregate
# awk at the bottom is handed a null ARGV element — which POSIX awk SKIPS,
# falling through to stdin: zero records on a closed stdin prints PASS. That is
# the final gate reporting success over a tree it never checked, so the refusal
# lives here, before any check can run against a missing work file.
for _gt in "$CARD" "$CMP" "$CMPA" "$CMPB" "$AURAW" "$AUC" "$MRAW" "$MERR" "$MOUT" "$RRAW" "$RLIST" "$RHITSF"; do
  { [[ -n "$_gt" ]] && [[ -f "$_gt" ]]; } || {
    echo "FAIL: gate-internal: mktemp could not create a work file under ${TMPDIR:-/tmp} — the gate cannot run (fix TMPDIR or free disk space, then re-run)" >&2
    exit 1
  }
done
trap 'rm -f "$CARD" "$CMP" "$CMPA" "$CMPB" "$AURAW" "$AUC" "$MRAW" "$MERR" "$MOUT" "$RRAW" "$RLIST" "$RHITSF"' EXIT

# comm requires both sets ordered under ITS collation, but the failure files are
# written by plain `sort -u` in whatever locale their session ran — and the
# Phase 4.5 baseline and this gate can run in sessions with different
# LC_COLLATE. Re-sorting both sides under LC_ALL=C makes the comparison a
# function of file contents, never of an environment this script doesn't own.
compare_sets() { # $1 = baseline, $2 = extracted failures → new IDs land in $CMP
  LC_ALL=C sort -u "$1" > "$CMPA" 2>/dev/null \
    && LC_ALL=C sort -u "$2" > "$CMPB" 2>/dev/null \
    && LC_ALL=C comm -13 "$CMPA" "$CMPB" > "$CMP" 2>/dev/null
}

row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$CARD"; }
# One line, no embedded tabs/newlines — details and evidence land in a TSV.
# Byte-identical to producer-idempotence.sh's and yaml-gate.sh's definitions; the
# three are bound by a skill-lint check, so edit them together or not at all.
# Every stage is pinned to LC_ALL=C because what this collapses (build and test
# output, a status file, a line of test-command.txt) is not guaranteed valid
# UTF-8: BSD `tr` in a UTF-8 locale ABORTS on the first invalid byte ("tr:
# Illegal byte sequence" onto the gate's stderr) and truncates the detail there,
# so the evidence the operator reads would depend on the ambient locale. Under C
# the whole thing is bytes: the cut budget is 300 bytes rather than 300
# characters, which is the intended order of magnitude and is now the same
# everywhere.
oneline() { LC_ALL=C tr '\n\t' '  ' | LC_ALL=C sed 's/  */ /g; s/^ //; s/ $//' | LC_ALL=C cut -c1-300; }

CMDFILE="$RUN/test-command.txt"
# Lines are trimmed before validation: a whitespace-only line or a space-prefixed
# rejection comment (" # rejected: …" drifted onto a positional line) must hit
# the not-a-command guards below, not slip past them into eval — where a bare
# "   " or " # …" exits 0 doing nothing and manufactures a vacuous PASS.
line() { { [[ -f "$CMDFILE" ]] && sed -n "${1}p" "$CMDFILE" || true; } | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
TEST_CMD=$(line 1)
EXTRACTOR=$(line 2)
BUILD_CMD=$(line 3)
BASELINE="$RUN/test-baseline.failures.txt"

# The census recipe lives in a SIBLING file, never a fifth positional line (its
# absence is the honest "no census recorded"; everything below line 4 of
# test-command.txt is the rejection audit trail). Read it the same trimmed way, and
# treat the honest-absence literal, a drifted comment, or an empty line as "no
# census" — an empty CENSUS makes run-check-modules.sh write not one census byte, so
# a component with no population-capable recipe is byte-identical to a pre-census run.
CENSUSFILE="$RUN/census-command.txt"
CENSUS_CMD=$( { [[ -f "$CENSUSFILE" ]] && sed -n 1p "$CENSUSFILE" || true; } | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' )
case "$CENSUS_CMD" in
  ''|'no census extractor') CENSUS_CMD= ;;
  '#'*)                     CENSUS_CMD= ;;
esac

# --- check 1: build ------------------------------------------------------------
if [[ ! -f "$CMDFILE" ]]; then
  row build FAIL "gate-internal: $CMDFILE missing — Phase 4.5 never recorded the discovered commands" "-"
elif [[ "$BUILD_CMD" = "no build check" ]]; then
  row build INCOMPLETE "no-build-check: line 3 of test-command.txt is 'no build check' — nothing compiled the tree; this gate is weaker than usual here" "$CMDFILE line 3"
elif [[ -z "$BUILD_CMD" ]] || [[ "${BUILD_CMD#\#}" != "$BUILD_CMD" ]]; then
  row build FAIL "gate-internal: line 3 of test-command.txt is not a command or the literal 'no build check' (got '$(printf '%s' "$BUILD_CMD" | oneline)')" "-"
else
  BOUT="$RUN/build-$LABEL"
  # Stale artifacts from an earlier run must never satisfy this run: if the
  # runner dies before writing its status, the gap has to read as a missing
  # file (FAIL: gate-internal), not as last time's verdict. The glob also
  # clears the PER-MODULE stems ($BOUT.<slug>.status …) that
  # run-check-modules.sh reads back — a stale per-module status would
  # otherwise fill a crashed module runner's gap with last time's verdict.
  rm -f "$BOUT".*
  # EXTRACTOR is cleared: it belongs to the test check; inherited into the build
  # check it could turn a plain FAIL into EXTRACTOR_MISMATCH.
  CHECK=build CMD="$BUILD_CMD" OUT="$BOUT" EXTRACTOR= "$HERE/run-check-modules.sh" >/dev/null 2>&1 || true
  BST=$(cat "$BOUT.status" 2>/dev/null || true)
  case "$BST" in
    OK)
      if [[ -f "$BOUT.modules.tsv" ]]; then
        NBM=$(grep -c . "$BOUT.modules.tsv" || true)
        row build PASS "build clean across all modules" "status=OK over $NBM module(s) — $BOUT.status, $BOUT.modules.tsv"
      else
        row build PASS "build clean" "status=OK — $BOUT.status"
      fi
      ;;
    FAIL)
      SNIP=""
      [[ -f "$BOUT.excerpt.txt" ]] && SNIP=$(head -3 "$BOUT.excerpt.txt" | oneline)
      if [[ -f "$BOUT.modules.tsv" ]]; then
        BMODS=$(awk -F'\t' '$2=="FAIL"{print $1}' "$BOUT.modules.tsv" | paste -sd, - )
        row build FAIL "failing module(s): ${BMODS:-<none listed>} — ${SNIP:-see excerpt}" "$BOUT.modules.tsv, $BOUT.excerpt.txt"
      else
        row build FAIL "build failed: ${SNIP:-see excerpt} — $BOUT.excerpt.txt" "$BOUT.status"
      fi
      ;;
    EXTRACTOR_MISMATCH)
      row build FAIL "extractor: build exited non-zero and the extractor matched nothing — fix the extractor and re-run; silence is never green" "$BOUT.status"
      ;;
    "")
      row build FAIL "gate-internal: $BOUT.status missing after the build check ran" "-"
      ;;
    *)
      row build FAIL "gate-internal: unrecognized status '$(printf '%s' "$BST" | oneline)' in $BOUT.status" "-"
      ;;
  esac
fi

# --- check 2: tests vs baseline --------------------------------------------------
# The census triplet for THIS label is cleared BEFORE the arm dispatch below, not
# inside the one arm that runs the suite. Check 8 runs unconditionally and reads
# whatever epoch artifacts are on disk, so leaving a previous gate invocation's
# population/skips/census.status here lets a refusal arm (missing command file,
# 'no tests detected', a malformed line 1/2, a missing or unreadable baseline)
# hand the census a full epoch this run never produced: a resumed run whose test
# discovery degraded after an earlier gate attempt would get a positive-evidence
# census PASS — or a false disappearance FAIL — out of last attempt's evidence.
# Clearing unconditionally makes "the census reads only this run's artifacts"
# true by construction: no run of the suite, no epoch, INCOMPLETE. Only the
# CURRENT label's triplet goes: the other epochs (test-baseline.*, and
# test-postmerge.* at LABEL=final) are legitimate earlier-epoch inputs this run
# diffs against, and are outside this glob-free, explicitly named set.
rm -f "$RUN/test-$LABEL.population.txt" \
      "$RUN/test-$LABEL.skips.txt" \
      "$RUN/test-$LABEL.census.status"
if [[ ! -f "$CMDFILE" ]]; then
  row tests FAIL "gate-internal: $CMDFILE missing — Phase 4.5 never recorded the discovered commands" "-"
elif [[ "$TEST_CMD" = "no tests detected" ]]; then
  row tests INCOMPLETE "no-tests: line 1 of test-command.txt is 'no tests detected' — no suite ran; this gate is weaker than usual here" "$CMDFILE line 1"
elif [[ -z "$TEST_CMD" ]] || [[ "${TEST_CMD#\#}" != "$TEST_CMD" ]]; then
  row tests FAIL "gate-internal: line 1 of test-command.txt is not a command or the literal 'no tests detected' (got '$(printf '%s' "$TEST_CMD" | oneline)')" "-"
elif [[ -z "$EXTRACTOR" ]] || [[ "${EXTRACTOR#\#}" != "$EXTRACTOR" ]]; then
  row tests FAIL "gate-internal: line 2 of test-command.txt carries no extractor, or a drifted rejection comment where one belongs (got '$(printf '%s' "$EXTRACTOR" | oneline)') — the failure set cannot be compared against the baseline" "-"
elif [[ ! -f "$BASELINE" ]]; then
  row tests FAIL "gate-internal: $BASELINE missing — no pre-merge baseline to compare against (Phase 4.5)" "-"
elif [[ ! -r "$BASELINE" ]]; then
  row tests FAIL "gate-internal: $BASELINE exists but is unreadable — the failure set cannot be compared against it" "-"
else
  TOUT="$RUN/test-$LABEL"
  # Same stale-artifact rule as the build check, per-module stems included; the
  # baseline lives outside this glob ($RUN/test-baseline.*, not test-$LABEL.*).
  rm -f "$TOUT".*
  # CENSUS rides the same single suite run as the failure extractor — one pipe over
  # the same output, producing test-<label>.population.txt / .skips.txt /
  # .census.status as a free side effect. Empty CENSUS → no census artifacts.
  CHECK=test CMD="$TEST_CMD" OUT="$TOUT" EXTRACTOR="$EXTRACTOR" CENSUS="$CENSUS_CMD" \
    "$HERE/run-check-modules.sh" >/dev/null 2>&1 || true
  TST=$(cat "$TOUT.status" 2>/dev/null || true)
  case "$TST" in
    OK)
      if [[ ! -f "$TOUT.failures.txt" ]]; then
        row tests FAIL "gate-internal: status OK but $TOUT.failures.txt was never written — the extractor did not run" "-"
      # The comparison runs to a file with every step's exit status checked: a
      # comm that dies with empty output inside $(...) is indistinguishable
      # from "no new failures", and a verdict must never ride on an unchecked
      # comparison.
      elif ! compare_sets "$BASELINE" "$TOUT.failures.txt"; then
        row tests FAIL "gate-internal: comparing $TOUT.failures.txt against $BASELINE failed — the failure sets were never compared" "-"
      else
        TNEW=$(sed '/^$/d' "$CMP")
        if [[ -n "$TNEW" ]]; then
          row tests FAIL "gate-internal: status OK yet the failure set contains IDs absent from the baseline — inconsistent artifacts" "-"
        else
          row tests PASS "suite green; no new failures vs baseline" "status=OK, new-failures=0 — $TOUT.status vs $BASELINE"
        fi
      fi
      ;;
    FAIL)
      if [[ ! -s "$TOUT.failures.txt" ]]; then
        # A red suite whose extracted failure set is empty is the extractor's
        # silence wearing a FAIL status — run-check.sh calls that
        # EXTRACTOR_MISMATCH itself, so reaching here means the artifacts are
        # inconsistent. Never read the empty comm as red-on-red.
        row tests FAIL "gate-internal: status FAIL but the extracted failure set is empty — extractor silence, not a comparable red suite" "-"
      # Same rule as the OK branch, but here the stakes are the dangerous class:
      # a swallowed comparison failure yields an empty TNEW, and empty TNEW is
      # the red-on-red PASS arm — a regression rounded up to PASS on zero
      # evidence.
      elif ! compare_sets "$BASELINE" "$TOUT.failures.txt"; then
        row tests FAIL "gate-internal: comparing $TOUT.failures.txt against $BASELINE failed — the failure sets were never compared, so this red suite is not comparable" "-"
      else
        TNEW=$(sed '/^$/d' "$CMP")
        if [[ -z "$TNEW" ]]; then
          row tests PASS "suite red exactly where the baseline was red (red-on-red, no new failures)" "status=FAIL, new-failures=0 — $TOUT.failures.txt vs $BASELINE"
        else
          NNEW=$(printf '%s\n' "$TNEW" | grep -c .)
          TIDS=$(printf '%s\n' "$TNEW" | head -10 | paste -sd, - )
          row tests FAIL "$NNEW new failing test ID(s) vs baseline: $TIDS" "$TOUT.failures.txt vs $BASELINE"
        fi
      fi
      ;;
    EXTRACTOR_MISMATCH)
      row tests FAIL "extractor: suite exited non-zero and the extractor matched nothing — the empty failure set is the extractor's silence, never a pass; fix the extractor and re-run" "$TOUT.status"
      ;;
    SKIP)
      row tests INCOMPLETE "no-tests: no module carries *_test.go, nothing ran — not a pass; this gate is weaker than usual here" "$TOUT.status, $TOUT.modules.tsv"
      ;;
    "")
      row tests FAIL "gate-internal: $TOUT.status missing after the test check ran" "-"
      ;;
    *)
      row tests FAIL "gate-internal: unrecognized status '$(printf '%s' "$TST" | oneline)' in $TOUT.status" "-"
      ;;
  esac
fi

# --- check 3: yaml ---------------------------------------------------------------
# FILES / CHART_DIR / ACK / TARGET_TAG are scrubbed so the card is a function of
# (RUN, SYNTH, LABEL, tree) only — the ack path stays the documented default,
# $RUN/yaml-gate-ack.tsv.
env -u FILES -u CHART_DIR -u ACK -u TARGET_TAG \
  SYNTH="${SYNTH:-}" RUN="$RUN" LABEL="$LABEL" "$HERE/yaml-gate.sh" >/dev/null 2>&1
YRC=$?
YTSV="$RUN/yaml-gate-$LABEL.tsv"
if [[ ! -f "$YTSV" ]]; then
  row yaml FAIL "gate-internal: $YTSV missing after the yaml gate ran (exit $YRC)" "-"
else
  NYFAIL=$(awk -F'\t' 'NF && $1=="fail"{n++} END{print n+0}' "$YTSV")
  NYSKIP=$(awk -F'\t' 'NF && $1=="skip"{n++} END{print n+0}' "$YTSV")
  NYODD=$(awk -F'\t' 'NF && $1!="fail" && $1!="skip"{n++} END{print n+0}' "$YTSV")
  if [[ "$NYODD" -gt 0 ]]; then
    row yaml FAIL "gate-internal: $NYODD row(s) with an unrecognized severity in $YTSV" "-"
  elif [[ "$NYFAIL" -gt 0 ]]; then
    YDET=$(awk -F'\t' '$1=="fail"{print $2" ("$3": "$4") |"}' "$YTSV" | head -5 | oneline)
    row yaml FAIL "$NYFAIL failing YAML finding(s): $YDET" "$YTSV, $RUN/yaml-gate-$LABEL.txt"
  elif [[ "$YRC" -ne 0 ]]; then
    row yaml FAIL "gate-internal: yaml-gate.sh exited $YRC with no fail row in $YTSV — inconsistent artifacts" "-"
  elif [[ "$NYSKIP" -gt 0 ]]; then
    YDET=$(awk -F'\t' '$1=="skip"{print $3": "$4" |"}' "$YTSV" | head -5 | oneline)
    row yaml INCOMPLETE "$NYSKIP skipped/acknowledged layer(s) — incomplete semantic coverage, never clean: $YDET" "$YTSV"
  else
    row yaml PASS "no parse, duplicate-key, helm-render, or buried-key finding; no layer skipped" "0 fail / 0 skip rows — $YTSV"
  fi
fi

# --- check 4: producer idempotence -----------------------------------------------
# BUILD_CMD / REGEN_CMD are scrubbed: the gate's producers come from
# test-command.txt lines 3–4, never from inherited environment.
#
# LABEL is passed through, so the verdict lands at
# $RUN/producer-idempotence-<LABEL>.tsv — per label, cleared at the start of each
# run, exactly like the build/test sweep stems. It used to be ONE unlabelled file
# shared by all three labels, and phases/6-planning.md derives plan-blocking
# `skip:producer-*` acknowledgments from it: a plan revised after the midplan gate
# had run derived postmerge-mandatory follow-ups from a MIDPLAN verdict, and where
# midplan's producer arm was clean the acknowledgment silently stopped being
# required. followup-completeness.sh now reads the postmerge file by name.
env -u BUILD_CMD -u REGEN_CMD RUN="$RUN" LABEL="$LABEL" "$HERE/producer-idempotence.sh" >/dev/null 2>&1
PRC=$?
PTSV="$RUN/producer-idempotence-$LABEL.tsv"
if [[ ! -f "$PTSV" ]]; then
  row producer-idempotence FAIL "gate-internal: $PTSV missing after the producer check ran (exit $PRC)" "-"
else
  # producer-failed is a recognized verdict, not an unanticipated state: the
  # producer exited non-zero and the check classified and restored anyway. It is
  # a finding (a clean FAIL naming the producer), never gate-internal.
  NPFIND=$(awk -F'\t' 'NF && ($2=="dirty-tracked" || $2=="untracked-output" || $2=="producer-failed"){n++} END{print n+0}' "$PTSV")
  NPCLEAN=$(awk -F'\t' 'NF && $2=="clean"{n++} END{print n+0}' "$PTSV")
  NPSKIP=$(awk -F'\t' 'NF && $2=="skip"{n++} END{print n+0}' "$PTSV")
  NPODD=$(awk -F'\t' 'NF && $2!="clean" && $2!="skip" && $2!="dirty-tracked" && $2!="untracked-output" && $2!="producer-failed"{n++} END{print n+0}' "$PTSV")
  if [[ "$NPODD" -gt 0 ]]; then
    row producer-idempotence FAIL "gate-internal: $NPODD row(s) with an unrecognized verdict in $PTSV" "-"
  elif [[ "$NPFIND" -gt 0 ]]; then
    PDET=$(awk -F'\t' '$2=="dirty-tracked" || $2=="untracked-output" || $2=="producer-failed" {print $1" "$2": "$3" |"}' "$PTSV" | head -5 | oneline)
    row producer-idempotence FAIL "$NPFIND producer finding(s): $PDET" "$PTSV"
  elif [[ "$PRC" -ne 0 ]]; then
    row producer-idempotence FAIL "gate-internal: producer-idempotence.sh exited $PRC with no finding row in $PTSV — inconsistent artifacts" "-"
  elif [[ "$NPSKIP" -gt 0 ]]; then
    PDET=$(awk -F'\t' '$2=="skip"{print $1": "$3" |"}' "$PTSV" | head -5 | oneline)
    row producer-idempotence INCOMPLETE "producer(s) skipped — incomplete coverage, never a pass: $PDET" "$PTSV"
  elif [[ "$NPCLEAN" -gt 0 ]]; then
    row producer-idempotence PASS "every producer left tracked state clean" "clean=$NPCLEAN, skip=0 — $PTSV"
  else
    row producer-idempotence INCOMPLETE "no producer ran (no build or regeneration command recorded) — nothing audited" "0 rows — $PTSV"
  fi
fi

# --- check 5 (final only): conflict markers ---------------------------------------
if [[ "$LABEL" = final ]]; then
  # The candidate set comes from git, not from a filesystem walk: tracked UNION
  # untracked-but-not-ignored — the same union yaml-gate.sh builds, for the same
  # reason. A file that landed in THIS merge is untracked at the gate, so a
  # tracked-only scan would be blind to exactly the content the check exists to
  # inspect. Asking git also drops every ignored build directory (.venv/, dist/):
  # a marker-shaped line there is not this migration's merge surface, and it used
  # to block finalize on content the merge never touched. Three prefixes are
  # excluded EXPLICITLY, because git lists them whenever the component commits
  # them: .kairos/ (the migration's own tree — pre-flight excludes its state dir,
  # and this scan drops the whole prefix) plus vendor/ and node_modules/. vendor/
  # and node_modules/ match yaml-gate.sh's and run-check-modules.sh's filters
  # exactly; the .kairos/ scope does NOT — yaml-gate.sh drops only
  # .kairos/migration/state/, so the marker scan is stricter about .kairos/ than
  # the YAML gate is. A committed vendor tree is the case
  # that matters: a Markdown setext underline in a vendored README is a bare
  # ======= and would fail finalize on content the merge never touched.
  # Directory entries (a submodule gitlink) are dropped here rather than left for
  # grep, which would exit 2 on them and turn a clean tree into a gate-internal
  # FAIL.
  MLIST="$RUN/.gate-marker-files.$LABEL"
  MHITS=""; MRC=0; MNF=0; MNCAND=0; MNDIR=0; MNGONE=0; MUNSCAN=""; MNUNSCAN=0
  # A list that could not be BUILT is NOT an empty list: the scan never ran.
  # Distinguishing the two is the whole fail-closed rule of this script — without
  # the guard, a failing `git ls-files` (cwd is not a repo, index corrupt) or an
  # unwritable $MLIST leaves the loop with zero candidates and the marker check
  # reports PASS over a tree it never opened. So the listing runs with its exit
  # status captured explicitly — never as the head of a pipeline whose status is
  # sort's and whose stderr is discarded.
  MLISTOK=yes; MLSERR=""
  if ! git ls-files -z > "$MRAW" 2> "$MERR"; then
    MLISTOK=git; MLSERR=$(head -1 "$MERR" | oneline)
  elif ! git ls-files -z --others --exclude-standard >> "$MRAW" 2> "$MERR"; then
    MLISTOK=git; MLSERR=$(head -1 "$MERR" | oneline)
  fi
  # $MLIST is a RECORD of what was listed; the scan itself never reads it back.
  # It used to be both, built with `tr '\0' '\n' | grep -v … | sort -u`, and a
  # path containing an EMBEDDED NEWLINE (legal in git and on every filesystem the
  # skill runs on — `git ls-files -z` exists precisely for it) became two lines,
  # NEITHER of which names a file: both were dropped by the `[ -f ]` test below,
  # nothing reconciled the counts, and the row printed "0 hits across N candidate
  # file(s)" over a tree that could be carrying markers in exactly the file
  # nobody opened. So the walk consumes git's NUL stream directly and the prefix
  # filters are bash `case` patterns rather than greps: a quoted pattern is
  # matched literally, `*` spans `/`, so `*/vendor/*` is the `(^|/)vendor/` anchor
  # of the old ERE, byte-exactly and without a line-splitting stage.
  #
  # Sorting goes with the re-split (there is no NUL-safe `sort` on both BSD and
  # GNU): git lists tracked paths in index order — byte-sorted — and appends the
  # untracked set the same way, and the two sets are disjoint, so the record is
  # still stable run to run and free of duplicates. Its writability is proven
  # BEFORE the walk, because an unwritable record is a broken gate artifact and
  # this check reports that as gate-internal rather than silently. A path holding
  # a newline is still ambiguous IN the record — accepted: the record is evidence
  # for a reader, and no verdict is computed from it any more.
  MFILES=()
  if [[ "$MLISTOK" = yes ]]; then
    : > "$MLIST" 2>/dev/null || MLISTOK=no
    { [[ -f "$MLIST" ]] && [[ -r "$MLIST" ]] && [[ -w "$MLIST" ]]; } || MLISTOK=no
  fi
  if [[ "$MLISTOK" = yes ]]; then
    while IFS= read -r -d '' mf; do
      [[ -n "$mf" ]] || continue
      case "$mf" in
        .kairos/*|.git/*|*/.git/*|node_modules/*|*/node_modules/*|vendor/*|*/vendor/*) continue ;;
      esac
      MNCAND=$((MNCAND + 1))
      printf '%s\n' "$mf"
      # Every candidate is accounted for. Three states legitimately carry no
      # scannable text and are COUNTED into the row's evidence rather than
      # dropped: a regular file is scanned; a DIRECTORY entry is a submodule
      # gitlink (grep exits 2 on it, which would turn a clean tree into a
      # gate-internal FAIL); a path no longer on disk is a deletion the merge or
      # the operator made, and holds nothing. Anything else exists and is NOT
      # scannable, so it is named and the row degrades — never a PASS over a
      # candidate this scan dropped.
      if [[ -f "$mf" ]]; then
        MFILES+=("$mf")
      elif [[ -d "$mf" ]]; then
        MNDIR=$((MNDIR + 1))
      elif [[ ! -e "$mf" ]]; then
        MNGONE=$((MNGONE + 1))
      else
        MNUNSCAN=$((MNUNSCAN + 1))
        MUNSCAN="$MUNSCAN $mf;"
      fi
    done < "$MRAW" > "$MLIST"
  fi
  # One grep per batch of candidates, never one grep over the whole set: a
  # component with a large git-known file set (a committed vendor tree is
  # thousands of paths) overflows ARG_MAX, the exec fails with E2BIG, and grep
  # exits 126 having scanned nothing — which the arms below read as
  # gate-internal, a FAIL no user action can clear. Batching keeps every exit
  # status meaningful: per batch 0 = hits, 1 = none, anything else = the scan
  # itself failed. A bad rc is sticky and dominant (MBAD) so a real scan failure
  # still reads gate-internal even when another batch reported hits.
  #
  # MARKER_RE allows exactly one optional trailing CR on the bare-separator
  # alternative: a bare `=======` line saved or checked out with CRLF endings
  # is `=======\r` on disk, and GNU grep's ERE engine anchors `$` at the LF,
  # not before a trailing CR — so `^={7}$` never matches that line (BSD grep's
  # `$` is lenient about a trailing CR and matches it by accident, which is why
  # this only showed up on Linux). The optional CR is a LITERAL byte, built via
  # bash's $'...' quoting, and never the two-character sequence backslash-r:
  # neither GNU nor BSD grep's ERE interprets \r as carriage return, so that
  # spelling would match a literal backslash followed by the letter r instead
  # of matching nothing extra. The labeled-marker alternatives are untouched —
  # only the bare-separator arm gets the trailing-CR allowance.
  CR=$'\r'
  MARKER_RE='^(<{7}|\|{7}|>{7}) |^={7}'"$CR"'?$'
  MBAD=0
  mgrep_batch() {
    local mout mrc
    # -I: conflict markers are text-only by construction, so a binary
    # (image/font/PDF) whose bytes happen to line up with a marker pattern is
    # never a real conflict — without -I it hard-blocks finalize on a
    # non-problem, with no acknowledgment path, exactly what this gate forbids.
    mout=$(grep -IlE "$MARKER_RE" -- "$@" 2>/dev/null)
    mrc=$?
    if [[ "$mrc" -eq 0 ]]; then
      printf '%s\n' "$mout" >> "$MOUT"
    elif [[ "$mrc" -ne 1 ]]; then
      MBAD=$mrc
    fi
  }
  if [[ "$MLISTOK" = yes ]]; then
    MNF=${#MFILES[@]}
    if [[ "$MNF" -eq 0 ]]; then
      # No candidates is a real, clean state (an empty or fully-ignored tree),
      # and it must read as PASS-with-evidence. It must also never reach grep:
      # with no file arguments grep reads stdin and the gate hangs forever.
      MRC=1
    else
      : > "$MOUT"
      MBATCH=()
      for mf in "${MFILES[@]}"; do
        MBATCH+=("$mf")
        if [[ ${#MBATCH[@]} -ge 500 ]]; then
          mgrep_batch "${MBATCH[@]}"
          MBATCH=()
        fi
      done
      [[ ${#MBATCH[@]} -eq 0 ]] || mgrep_batch "${MBATCH[@]}"
      MHITS=$(grep -v '^$' "$MOUT")
      if [[ "$MBAD" -ne 0 ]]; then
        MRC=$MBAD
      elif [[ -n "$MHITS" ]]; then
        MRC=0
      else
        MRC=1
      fi
    fi
  fi
  # Arm order is the fail-closed order: a listing or scan that did not complete
  # first, then real hits, then a coverage gap, and only last the PASS. A hit
  # outranks an unscannable candidate (the finding is already the harder verdict),
  # and both outrank the clean row.
  if [[ "$MLISTOK" = git ]]; then
    row conflict-markers FAIL "gate-internal: git ls-files failed: ${MLSERR:-<no stderr>} — the candidate file list was never built, so the marker scan never ran" "-"
  elif [[ "$MLISTOK" != yes ]]; then
    row conflict-markers FAIL "gate-internal: the candidate file list $MLIST could not be written or read back — the marker scan never ran" "-"
  elif [[ "$MRC" -eq 0 ]] && [[ -n "$MHITS" ]]; then
    NMH=$(printf '%s\n' "$MHITS" | grep -c .)
    MDET=$(printf '%s\n' "$MHITS" | head -10 | paste -sd, - | oneline)
    # The full hit list is persisted under $RUN: this is the one row that blocks
    # finalize and demands per-file human inspection of EVERY hit, and the mktemp
    # it lived in is deleted by the EXIT trap while the detail column is
    # head-10-truncated. If $RUN can't take the write, fall back to naming the
    # truncation honestly rather than citing a file that isn't there.
    MHITSKEEP="$RUN/gate-marker-hits.$LABEL.txt"
    if printf '%s\n' "$MHITS" > "$MHITSKEEP" 2>/dev/null; then
      MEV="full hit list: $MHITSKEEP"
    else
      MEV="hit list truncated to the first 10 in the detail column ($RUN not writable for the full list)"
    fi
    # `grep -l` reports its hits newline-delimited, so a hit in a path that itself
    # holds a newline counts as two here: the FAIL, and the file being NAMED, are
    # unaffected — only $NMH can read one high. Accepted, because the alternative
    # (`grep -lZ`/`--null`) is not portable across the BSD and GNU greps this runs on.
    row conflict-markers FAIL "$NMH file(s) carry conflict markers or a bare ======= separator: $MDET — inspect each (a ^={7}\$ hit may be a Markdown setext underline: reference/gates.md)" "$MEV"
  elif [[ "$MRC" -ne 1 ]]; then
    row conflict-markers FAIL "gate-internal: marker grep exited $MRC — scan did not complete" "-"
  elif [[ -n "$MUNSCAN" ]]; then
    # No hits among what WAS scanned, but the listing named something this check
    # could not open — neither a regular file, nor a directory entry, nor absent.
    # INCOMPLETE rather than FAIL: incomplete coverage must be relayed, and
    # blocking finalize on a candidate nobody can act on would be the false
    # positive this gate forbids. It is never the PASS row either.
    row conflict-markers INCOMPLETE "$MNUNSCAN listed candidate(s) could not be scanned (not a regular file, not a directory entry, not absent):$(printf '%s' "$MUNSCAN" | oneline) — coverage is incomplete, never clean" "$MNF of $MNCAND listed candidate(s) scanned — $MLIST"
  else
    row conflict-markers PASS "no labeled conflict marker or bare ======= separator in any tracked or new file" "0 hits across $MNF candidate file(s), every one of $MNCAND listed accounted for ($MNDIR directory/submodule entr(ies), $MNGONE no longer on disk) — tracked + untracked-not-ignored, minus .kairos/, vendor/ and node_modules/ (labeled markers + bare-======= pattern)"
  fi
fi

# --- check 6 (postmerge/midplan): inherited local-path replace directives ----------
# midplan is the postmerge check set re-run at Phase 7 cadence, so it carries this check too.
#
# WHY not a grep: block-form `replace ( … )` groups carry the `replace` keyword
# only on the OPENING line, so `grep '^…replace.*=>'` sees none of the inner
# directives — and a co-developed component is exactly where several replaces
# accumulate and get grouped. The line-form grep this check used to be therefore
# reported "no local-path replace directive" for the one shape the check exists
# to catch. codev-check.sh already documents the pitfall and ships the right
# primitive; this row uses the same one.
#
# WHY every go.mod, not just the root: a sibling module (`pkg/schema`,
# `web/entrypoint`) breaks CI on an inherited local replace exactly as the root
# does, and the old root-only form ALSO reported a clean PASS for a component
# whose root carries no go.mod at all — a PASS that claimed more than it checked.
# The candidate set is the module set run-check-modules.sh sweeps, discovered the
# same way and with the same exclusions, so the modules that get built are the
# modules that get audited.
if [[ "$LABEL" = postmerge ]] || [[ "$LABEL" = midplan ]]; then
  # The fallback parse. Block-aware by construction: it tracks replace-group
  # state rather than matching a keyword per line, so inner directives are seen.
  # `//` line comments are stripped first (a commented-out replace is not state).
  #
  # WHY the trim includes \r: the block-open match is $-anchored, so on a CRLF
  # go.mod `replace (\r` failed it, the group state was never entered and every
  # inner directive was skipped as a stray line — a PASS over a file carrying a
  # local-path replace. The trim is the right home for it rather than that one
  # regex: the same \r otherwise rides into the printed directive and lands as a
  # control character mid-TSV-field in the card.
  #
  # WHY the optional quote before the dot: go.mod tokens may be quoted
  # (`"example.com/common" => "../kairos-component-common"`), which
  # `go mod edit -json` reports as a New.Path of `../…` like any other. Only the
  # new-path side needs it — the old-path side is never matched on (the line-form
  # arm keys off the leading `replace` keyword, which quoting does not move).
  #
  # WHY a bare `.` or `..` too: Go's modfile.IsDirectoryPath accepts them, so
  # `replace example.com/common => ..` is a local replace like `../x`. A filter
  # that required a trailing `/` dropped it before replace_by_root could see it.
  #
  # WHY absolute paths too: `go mod edit -replace mod=$(pwd)/../common` — the
  # natural CLI spelling — writes an ABSOLUTE new path, which breaks CI exactly
  # as `../` does. A filter that only matched `./`/`../` issued an affirmative
  # PASS over it. A module path can never start with `/` (the first element must
  # be a domain), so a leading `/` on the new-path side is always a filesystem
  # path, never a module.
  gomod_replace_awk() { # $1 = go.mod path → one "old => new" line per local-path replace
    awk '
      { s = $0; sub(/\/\/.*/, "", s); gsub(/^[ \t\r]+|[ \t\r]+$/, "", s) }
      s == "" { next }
      blk == 1 { if (s ~ /^\)/) { blk = 0; next } }
      blk == 0 && s ~ /^replace[ \t]*\([ \t]*$/ { blk = 1; next }
      blk == 0 { if (s !~ /^replace[ \t]/) next; sub(/^replace[ \t]+/, "", s) }
      s ~ /=>[ \t]*"?(\/|\.\.?(\/|"|[ \t]|$))/ { print s }
    ' "$1"
  }
  # The preferred parse — byte-for-byte the primitive codev-check.sh uses, minus
  # its common-prefix filter (any local-path replace breaks CI, not only one on
  # the common module). pipefail is load-bearing for the same reason it is there:
  # `yq` exits 0 on EMPTY stdin, so without it a failing `go mod edit -json`
  # (unparseable go.mod, missing yq) is indistinguishable from "no local-path
  # replaces" — silence read as a clean result, which is what this script exists
  # to make impossible. It is set in a subshell so the rest of the gate's
  # pipelines keep their documented statuses.
  gomod_replace_go() { # $1 = go.mod path → same lines; non-zero = did not parse
    ( set -o pipefail
      go mod edit -json "$1" \
        | yq -p=json -r '.Replace[]? | select(.New.Path | test("^(\\.{1,2}(/|$)|/)")) | .Old.Path + " => " + .New.Path' )
  }
  # Only a target OUTSIDE the component root is co-development state. Every
  # template-born go.mod carries `replace …/pkg/schema => ./pkg/schema`, and CI
  # resolves an in-repo target exactly as the author's machine does, so flagging
  # it asked on every component and offered a Drop that unhooks the root module
  # from its own pkg/schema. The target is resolved lexically against its own
  # go.mod's directory (a nested `web/entrypoint` reaches `../../pkg/schema`);
  # a `..` that climbs above the root, or any absolute path (machine-specific
  # even when it points into this checkout), stays a finding.
  # stdin/stdout: "<go.mod>: <old> => <new>" lines; KEEP=out prints the escaping
  # ones, KEEP=in the in-repo ones.
  replace_by_root() { # $1 = out|in
    awk -v keep="$1" '
      {
        line = $0; gm = line; sub(/: .*/, "", gm)
        t = line; sub(/^.*=>[ \t]*/, "", t); sub(/[ \t].*$/, "", t); gsub(/"/, "", t)
        out = 0
        if (t ~ /^\//) out = 1
        else {
          d = gm; if (d ~ /\//) sub(/\/[^\/]*$/, "", d); else d = "."
          n = split(d "/" t, seg, "/"); depth = 0
          for (i = 1; i <= n; i++) {
            if (seg[i] == "" || seg[i] == ".") continue
            if (seg[i] == "..") { if (depth == 0) { out = 1; break } depth-- }
            else depth++
          }
        }
        if ((keep == "out" && out) || (keep == "in" && !out)) print line
      }'
  }
  # A listing that FAILED is not an empty listing (the marker check's rule): find
  # exiting non-zero means part of the tree was never walked, so the module set is
  # unknown and a PASS over it would be a claim nobody checked. Sorting is a
  # separate step so the status captured is find's own, not sort's.
  RDISCOK=yes
  find . -name go.mod -type f \
       -not -path './.git/*' \
       -not -path './.kairos/*' \
       -not -path '*/vendor/*' \
       -not -path '*/node_modules/*' \
       -not -path '*/testdata/*' > "$RRAW" 2>/dev/null || RDISCOK=no
  if [[ "$RDISCOK" = yes ]]; then
    sed 's|^\./||' "$RRAW" | LC_ALL=C sort -u > "$RLIST" || RDISCOK=no
    { [[ -f "$RLIST" ]] && [[ -r "$RLIST" ]]; } || RDISCOK=no
  fi
  RNGOMOD=0; RNGO=0; RNAWK=0; RBAD=""; RHAVEGO=no
  if [[ "$RDISCOK" = yes ]]; then
    RNGOMOD=$(grep -c . "$RLIST" || true)
    command -v go >/dev/null 2>&1 && RHAVEGO=yes
    : > "$RHITSF"
    while IFS= read -r RGM; do
      [[ -n "$RGM" ]] || continue
      if [[ ! -r "$RGM" ]]; then RBAD="$RBAD $RGM (unreadable);"; continue; fi
      RONE=""; RMETH=""
      if [[ "$RHAVEGO" = yes ]]; then
        if RONE=$(gomod_replace_go "$RGM" 2>/dev/null); then RMETH=go; RNGO=$((RNGO+1)); fi
      fi
      if [[ -z "$RMETH" ]]; then
        # `go` absent, or present and unable to parse this file (a `go` directive
        # above the installed toolchain is one way, and a template bump raising it
        # is a migration's bread and butter). The fallback is a line scanner with
        # group state, not a second `modfile` implementation: it covers the block
        # and line forms, CRLF, and go.mod's quoted token spellings, and nothing
        # outside that shape. So degrading to it narrows coverage, which is why the
        # row's detail always names the parse that produced it rather than letting
        # the substitution pass unstated.
        if RONE=$(gomod_replace_awk "$RGM" 2>/dev/null); then RMETH=awk; RNAWK=$((RNAWK+1));
        else RBAD="$RBAD $RGM (parse failed);"; continue; fi
      fi
      [[ -z "$RONE" ]] || printf '%s\n' "$RONE" | awk -v p="$RGM" 'NF { print p ": " $0 }' >> "$RHITSF"
    done < "$RLIST"
  fi
  if [[ "$RNAWK" -eq 0 ]]; then
    RMETHD="parsed via go mod edit -json"
  elif [[ "$RNGO" -eq 0 ]] && [[ "$RHAVEGO" = no ]]; then
    RMETHD="parsed via the block-aware fallback ('go' not on PATH)"
  else
    RMETHD="parsed via go mod edit -json ($RNGO) + the block-aware fallback ($RNAWK, where go mod edit -json failed)"
  fi
  RHITS=$(grep -v '^$' "$RHITSF" 2>/dev/null | replace_by_root out || true)
  RNIN=$(grep -v '^$' "$RHITSF" 2>/dev/null | replace_by_root in | grep -c . || true)
  if [[ "$RDISCOK" != yes ]]; then
    row replace-directives FAIL "gate-internal: the go.mod candidate list could not be built or read back — no module was scanned for local-path replace directives" "-"
  elif [[ -n "$RBAD" ]]; then
    row replace-directives FAIL "gate-internal: $(printf '%s' "$RBAD" | oneline) — neither go mod edit -json nor the fallback parse could read these, so the scan did not complete" "-"
  elif [[ "$RNGOMOD" -eq 0 ]]; then
    row replace-directives PASS "no go.mod under the component root — nothing to check" "0 go.mod file(s) found (excluding .git/, .kairos/, vendor/, node_modules/, testdata/)"
  elif [[ -n "$RHITS" ]]; then
    RNH=$(printf '%s\n' "$RHITS" | grep -c .)
    RDET=$(printf '%s\n' "$RHITS" | head -5 | oneline)
    row replace-directives NEEDS-INPUT "$RNH inherited local-path replace directive(s) pointing outside the component root across $RNGOMOD go.mod file(s), $RMETHD — detect-and-ask, never auto-dropped (kept, they break CI): $RDET" "$(printf '%s\n' "$RHITS" | awk -F': ' '{print $1}' | LC_ALL=C sort -u | paste -sd, - | oneline)"
  else
    row replace-directives PASS "no local-path replace directive outside the component root in $RNGOMOD go.mod file(s), $RMETHD" "0 out-of-root local-path replace(s), ${RNIN:-0} in-repo replace(s) kept, across $RNGOMOD go.mod file(s) — $(LC_ALL=C sort "$RLIST" | head -5 | paste -sd, - | oneline)"
  fi
fi

# --- check 7 (postmerge only): ask-user enactment coverage --------------------------
# Postmerge ONLY — a plan task may legitimately revert an applied ask-user item,
# so this row at midplan or final would flag correct work: a false positive,
# which this gate's standing design rule forbids (false negatives are fine).
if [[ "$LABEL" = postmerge ]]; then
  AUAPPLIED="$RUN/ask-user-applied.tsv"
  AUCT="$RUN/classification-trees.tsv"
  # The classified set is only meaningful against the synthetic trees it was
  # DERIVED from: a $SYNTH re-materialized after Phase 3 leaves every row naming
  # a path or status that no longer exists, so a tally computed from it audits a
  # set nobody enacted. structural-merge.sh refuses to merge against a
  # classification whose stamp does not match (its CLASSIFICATION/SYNTH BINDING);
  # this row consumes the same file and owes the same verification, or the gate
  # reports coverage over a stale classification with no sign that it did.
  # Three outcomes, because $SYNTH is optional here (see Env in): ok, drift/
  # missing (a finding), or unknown — unverifiable, which may never read as a
  # clean pass but must not block either.
  AUBIND=unknown; AUBDET=""
  if [[ -n "${SYNTH:-}" ]] \
     && git -C "$SYNTH" rev-parse --verify --quiet 'kairos-base^{tree}' >/dev/null 2>&1 \
     && git -C "$SYNTH" rev-parse --verify --quiet 'kairos-target^{tree}' >/dev/null 2>&1; then
    if [[ ! -f "$AUCT" ]] || [[ ! -r "$AUCT" ]]; then
      AUBIND=missing
    else
      AUBIND=ok
      for auside in base target; do
        case "$auside" in base) autag=kairos-base ;; *) autag=kairos-target ;; esac
        AUWANT=$(awk -F'\t' -v s="$auside" '$1 == s { print $2; exit }' "$AUCT")
        AUHAVE=$(git -C "$SYNTH" rev-parse --verify --quiet "$autag^{tree}" 2>/dev/null || echo "")
        if [[ -z "$AUWANT" ]] || [[ "$AUWANT" != "$AUHAVE" ]]; then
          AUBIND=drift
          AUBDET="$AUBDET $auside: classified against ${AUWANT:-<not recorded>}, \$SYNTH now holds ${AUHAVE:-<none>};"
        fi
      done
    fi
  fi
  if [[ ! -f "$RUN/classification.tsv" ]] || [[ ! -r "$RUN/classification.tsv" ]]; then
    row ask-user FAIL "gate-internal: $RUN/classification.tsv missing or unreadable — the classified ask-user set cannot be derived (build-manifest.sh never ran?)" "-"
  elif [[ "$AUBIND" = missing ]]; then
    row ask-user FAIL "gate-internal: $AUCT missing or unreadable, so $RUN/classification.tsv carries no synthetic-tree binding and the coverage tally cannot be shown to describe this merge — re-run Phase 3 classification (scripts/build-manifest.sh), then redo Phase 5" "-"
  elif [[ "$AUBIND" = drift ]]; then
    row ask-user FAIL "$RUN/classification.tsv was derived from other synthetic trees than \$SYNTH holds now ($(printf '%s' "$AUBDET" | oneline)) — the classified set is stale, so its coverage says nothing about what was enacted; re-run Phase 3 classification (scripts/build-manifest.sh), then redo Phase 5" "$AUCT vs $SYNTH"
  else
    # The classified set mirrors apply-ask-user.sh exactly: the three ask-user
    # buckets across classification.tsv (path = column 4) plus binaries.txt
    # (bucket binary-for-user; absent reads as empty), union de-duplicated by
    # path with the classification.tsv bucket winning on duplicates. The two
    # computations must agree, or this row audits a different set than the
    # script enacted.
    AUOK=yes
    awk -F'\t' '$1 == "binary-for-user" || $1 == "added-heavyweight-ask-user" || $1 == "deleted-heavyweight-ask-user" \
                  { print $1 "\t" $4 }' "$RUN/classification.tsv" > "$AURAW" || AUOK=no
    if [[ "$AUOK" = yes ]] && [[ -f "$RUN/binaries.txt" ]]; then
      # A rename-flavored row carries an optional second TAB field (the pre-rename
      # old path — reference/state-files.md). $0 keeps it; the $2-keyed de-dupe and
      # coverage join below still land on the path in field 1, and the old path
      # never becomes a coverage item of its own. The guard is apply-ask-user.sh's
      # own (its :257 union): -F'\t' with $1 != "" so an empty-first-field row is
      # DROPPED on both sides — otherwise the gate would demand an applied row for a
      # phantom empty path the enactor never classified (a false coverage FAIL).
      awk -F'\t' 'NF && $1 != "" { print "binary-for-user\t" $0 }' "$RUN/binaries.txt" >> "$AURAW" || AUOK=no
    fi
    if [[ "$AUOK" = yes ]]; then
      awk -F'\t' '!seen[$2]++' "$AURAW" > "$AUC" || AUOK=no
    fi
    # A verified binding is positive evidence and is recorded as such; an
    # unverifiable one (AUBIND=unknown: $SYNTH unset or no longer a synthetic
    # repo) degrades the two clean arms to INCOMPLETE. It cannot be a FAIL — the
    # gate's contract makes $SYNTH optional, and blocking finalize on a directory
    # an operator legitimately cleaned up would be the false positive this script
    # forbids — but it may not be a silent PASS either: the tally is then computed
    # from a classification nothing can check.
    if [[ "$AUBIND" = ok ]]; then
      AUST=PASS; AUSUF=""
      AUBEV="binding verified: $AUCT matches the trees in $SYNTH"
    else
      AUST=INCOMPLETE
      AUBEV="binding could not be verified (\$SYNTH unset or not a synthetic repo) — $AUCT unchecked"
      AUSUF=" — $AUBEV, so this coverage is not known to describe the classification Phase 5 enacted"
    fi
    if [[ "$AUOK" != yes ]]; then
      row ask-user FAIL "gate-internal: the classified ask-user set could not be derived from $RUN/classification.tsv + binaries.txt — the coverage compare never ran" "-"
    else
      NAUC=$(grep -c . "$AUC" || true)
      if [[ "$NAUC" -eq 0 ]]; then
        # Zero classified items is a real, clean state and owes a PASS with
        # evidence — the marker check's empty-candidate precedent — never an
        # INCOMPLETE, and never a reason to demand an applied file. (Unless the
        # binding is unverifiable: a stale classification can carry zero ask-user
        # rows while the current one carries several.)
        row ask-user "$AUST" "no ask-user item classified — nothing owed an applied row$AUSUF" "applied 0 of 0 classified — no ask-user bucket row in $RUN/classification.tsv or binaries.txt; $AUBEV"
      elif [[ ! -f "$AUAPPLIED" ]] || [[ ! -r "$AUAPPLIED" ]]; then
        row ask-user FAIL "gate-internal: $AUAPPLIED missing or unreadable while $NAUC classified ask-user item(s) exist — apply-ask-user.sh (Phase 5 step 4b) never ran" "-"
      else
        NAUBAD=$(awk -F'\t' 'NF && (NF != 4 || $1 == "" || $2 == "" || $3 == "" || ($4 != "written" && $4 != "unchanged" && $4 != "deleted")) { n++ } END { print n+0 }' "$AUAPPLIED")
        if [[ "$NAUBAD" -gt 0 ]]; then
          row ask-user FAIL "gate-internal: $NAUBAD unparseable row(s) in $AUAPPLIED (want bucket<TAB>path<TAB>decision<TAB>written|unchanged|deleted) — coverage cannot be trusted" "-"
        else
          # FILENAME keys the join (not the empty-first-file-unsafe NR==FNR):
          # an applied file with zero rows must still be compared against the
          # classified set, not mistaken for it.
          AUMISS=$(awk -F'\t' '
            FILENAME == ARGV[1] { applied[$2] = 1; next }
            NF && !($2 in applied) { print $1 ":" $2 }
          ' "$AUAPPLIED" "$AUC")
          if [[ -n "$AUMISS" ]]; then
            NAUM=$(printf '%s\n' "$AUMISS" | grep -c .)
            AUDET=$(printf '%s\n' "$AUMISS" | head -10 | paste -sd, - | oneline)
            row ask-user FAIL "$NAUM of $NAUC classified ask-user item(s) have no applied row: $AUDET" "$AUAPPLIED vs the classified set in $RUN/classification.tsv + binaries.txt"
          else
            row ask-user "$AUST" "every classified ask-user item has an applied row$AUSUF" "applied $NAUC of $NAUC classified — $AUAPPLIED vs $RUN/classification.tsv + binaries.txt; $AUBEV"
          fi
        fi
      fi
    fi
  fi
fi

# --- check 8 (final: executor-era diff; postmerge: informational relay): census ----
# Every check above compares FAILURE sets, so none can see a test that stopped
# running. The census can: it diffs the populations recorded at each epoch.
#   final     → the executor-era disappearance / newly-skipped diff (FAIL on a
#               finding — the Phase 8 stop-or-accept valve applies).
#   postmerge → the Phase 5 informational relay: always INCOMPLETE (the final epoch
#               does not exist yet), carrying the template-era count for the planner.
# midplan carries NO census row — the census is a postmerge/final concern. census-diff.sh
# reads only this run's census artifacts and prints exactly one `census<TAB>…` row;
# a missing or malformed line is gate-internal, never a silent absence of the question.
if [[ "$LABEL" = final ]] || [[ "$LABEL" = postmerge ]]; then
  CROW=$(RUN="$RUN" LABEL="$LABEL" "$HERE/census-diff.sh" 2>/dev/null || true)
  CF1=$(printf '%s\n' "$CROW" | awk -F'\t' 'NR==1{print $1}')
  CCST=$(printf '%s\n' "$CROW" | awk -F'\t' 'NR==1{print $2}')
  CCDET=$(printf '%s\n' "$CROW" | awk -F'\t' 'NR==1{print $3}')
  CCEV=$(printf '%s\n' "$CROW" | awk -F'\t' 'NR==1{print $4}')
  if [[ "$CF1" = census ]] && { [[ "$CCST" = PASS ]] || [[ "$CCST" = FAIL ]] || [[ "$CCST" = INCOMPLETE ]]; }; then
    row census "$CCST" "$CCDET" "$CCEV"
  else
    row census FAIL "gate-internal: census-diff.sh produced no valid census row (got '$(printf '%s' "$CROW" | oneline)')" "-"
  fi
fi

# --- aggregate ---------------------------------------------------------------------
# FAIL beats NEEDS-INPUT beats PASS. INCOMPLETE never flips the aggregate — it is
# incomplete coverage the orchestrator must relay into the migration log, not a
# block — but every INCOMPLETE row stays in the card.
#
# An EMPTY card is a refusal, never a PASS: every label writes at least the
# build and tests rows, so zero rows means the appends themselves failed
# (TMPDIR filled or vanished mid-run) and the aggregate would be summarizing
# checks that never recorded their verdicts.
[[ -s "$CARD" ]] || {
  echo "FAIL: gate-internal: the verdict card is empty — no check recorded a row (a work-file write failed mid-run?), so there is nothing to aggregate" >&2
  exit 1
}
# A NON-empty card can still be a PARTIAL one: every check emits exactly one row,
# but if a row() append failed after the first rows landed (TMPDIR filled or
# vanished mid-run) the survivors would aggregate to a verdict that silently omits
# a lost FAIL row — the [ -s ] guard above only catches the all-or-nothing case.
# The row count is fixed per label (the label-gated checks make it 7/5/6), so a
# card that does not carry exactly that many is missing (or has doubled) a check,
# and aggregating it would summarize a set of checks that is not the one this label
# runs. Refuse rather than aggregate a partial card.
case "$LABEL" in
  postmerge) EXPECT_ROWS=7 ;;
  final)     EXPECT_ROWS=6 ;;
  midplan)   EXPECT_ROWS=5 ;;
esac
NROWS=$(awk 'END{print NR+0}' "$CARD")
if [[ "$NROWS" -ne "$EXPECT_ROWS" ]]; then
  echo "FAIL: gate-internal: the verdict card carries $NROWS check row(s), not the $EXPECT_ROWS that LABEL=$LABEL runs — a check row was lost to a failed work-file write (or duplicated); refusing to aggregate a partial card" >&2
  exit 1
fi
AGG=$(awk -F'\t' '
  $2=="FAIL"        { f=1 }
  $2=="NEEDS-INPUT" { n=1 }
  END { if (f) print "FAIL"; else if (n) print "NEEDS-INPUT"; else print "PASS" }
' "$CARD")
printf 'AGGREGATE\t%s\n' "$AGG" >> "$CARD"

# Checked: the on-disk card is what the orchestrator and later phases cite, so a
# failed copy must not exit as the aggregate's own status with no card behind it.
cp "$CARD" "$RUN/gate-$LABEL.tsv" || {
  echo "FAIL: gate-internal: could not write $RUN/gate-$LABEL.tsv — the verdict card was not persisted" >&2
  exit 1
}
cat "$CARD"

[[ "$AGG" = PASS ]]
