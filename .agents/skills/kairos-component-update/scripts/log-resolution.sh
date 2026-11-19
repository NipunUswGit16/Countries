#!/usr/bin/env bash
# log-resolution.sh — the format owner for the resolution ledger.
#
# WHY this script exists: the resolution ledger has FOUR machine parsers
# (handoff-structural.sh, spawn-summary.sh, followup-completeness.sh's kept-delete
# derivation, and the planner reading it as evidence) and had no writer at all. The
# per-batch shards were written by conflict-resolver SUBAGENTS from a prose row
# spec, the orchestrator concatenated them by prose, and the no-runtime-dispatch
# fallback appended to the concatenated file row by row. Three prose writers, four
# parsers, and a free-text `reason` column — the field most likely to carry a tab or
# a newline, since resolvers quote recorded intent entries into it verbatim.
#
# WHY the schema is `file <TAB> verdict <TAB> reason <TAB> region`, region APPENDED:
# the ledger's unit is the conflict REGION (agents/conflict-resolver.md logs one
# call per resolved region), but the old three-column shape carried no region
# identity, so two verdicts on different regions of one file whose reason text
# matched collapsed into one row under append's exact-row dedup — every ledger count
# then under-reported by that amount. The `region` column makes those rows DISTINCT.
# It is the LAST field on purpose: all three script consumers parse `$1`/`$2` only
# (none does `cut -f3-`, treats reason as trailing, or checks the column count), so
# appending is invisible to them by construction — inserting region before reason
# would break every one of them. The consumer-compatibility assertions in
# tests/log-resolution.test.sh keep that from being re-litigated by assumption.
#
# WHY region's two forms: for the four conflict-region verdicts (ours|theirs|
# merged|user) it is the 1-based ordinal of the region within the file, a positive
# integer the resolver supplies (a counter — it already works the regions in file
# order). The four reasoning-bucket verdicts (ported|kept-delete|kept-customization|
# renamed-merged) have no regions by construction, so region is the literal '-'. A
# non-empty placeholder keeps a positional reader from ever seeing a short row, and
# the vocabularies are disjoint, so a downstream consumer disambiguates by VERDICT:
# an `ours` row carrying '-' can ONLY be a pre-column row (see below). Do NOT add a
# second sentinel.
#
# WHY collapse(): one resolution must always cost exactly ONE four-column row. An
# uncollapsed newline in REASON splits a resolution across two lines, and the
# orphaned second line reads to every consumer as a file path with no verdict.
# REGION is collapsed too — it is env-fed like the others, and the skill-lint's
# "every env-fed ledger row is sanitized before it is written" rule requires it.
# Same helper, same reason, as log-intent.sh / log-learning.sh / log-spawn.sh.
#
# WHY a pre-column three-field row is NORMALIZED on read, warned once, and NEVER
# refused: a resume that spans a skill upgrade, a stale $RUN, or the `legacy` shard
# materialized from an older aggregate can still hand a four-field reader a
# three-field row whose ordinal was NEVER written and is unrecoverable. collect and
# reset (the rebuild paths that read shards and the pre-existing aggregate) append
# `\t-` to any such row — region=- is the only honest value — and emit ONE stderr
# warning per invocation naming the count and the file(s) that carried them. It does
# not refuse: a resume must not hard-stop over rows most consumers never read, and
# the only recovery would re-run structural-merge.sh, discarding every resolver
# verdict and forcing a full Phase 5 step 6 redo. (This is deliberate; see the PRD.)
#
# WHY the vocabulary is closed: an unrecognised verdict is invisible to every
# consumer that filters by verdict — and it is exactly what makes
# followup-completeness.sh's removal-verdict filter silently UNDER-match, dropping a
# stale-reference follow-up for a deletion that really happened.
#
# WHY there is NO header row: handoff-structural.sh and spawn-summary.sh both count
# non-empty lines to get their tallies, so a header would inflate every count by one.
#
# WHY it is KEYLESS: its callers are conflict-resolver subagents, which hold no
# phase key — the same argument log-learning.sh already carries, and the reason the
# env-var shape matters (a subagent can call it). Phase 5's own dispatch step keeps
# its key via log-spawn.sh. Do not "fix" this by adding a key.
#
# WHY append DEDUPS (grep -Fxq) like log-intent.sh / log-learning.sh: a
# conflict-resolver re-dispatched for the same slug (a needs-input round trip
# that also resends an already-logged row, a retried batch that happens to land
# on the same verdict) must not double a row it already wrote — a doubled row
# is indistinguishable from a real second resolution to all four consumers.
# This catches only an EXACT-duplicate re-append.
#
# WHY that is not enough on its own, and ACTION=reset exists too: a genuine
# re-dispatch is a SUPERSEDE, not a repeat — the resolver may reach a DIFFERENT
# verdict for the same file on the retry (fresh context, sometimes a different
# model after a wrong-model fail; see log-spawn.sh's "re-dispatch the batch's
# items" remedy). Exact-line dedup cannot reconcile two different verdicts for
# one file: the shard would hold both rows, and every consumer would see two
# resolutions for a file that has one. A re-dispatcher must reset the prior
# shard before writing again, so the retry's rows are the ONLY rows for that
# slug. See phases/5-structural.md's dispatch step and reference/state-files.md
# for where this is invoked.
#
# WHY the role-switch fallback ALSO writes a shard (the reserved 'role-switch'
# slug), instead of appending straight into resolutions.tsv: collect REBUILDS the
# aggregate from the shards. While the fallback owned the aggregate directly, any
# run that mixed the two modes — started with no runtime dispatch, resumed with
# it; or resolved the bucket rows in-conversation and dispatched the conflict
# files — destroyed every in-conversation verdict at the first collect, with no
# second copy anywhere. Two writers, one file, one of them a rebuilder: the only
# stable fix is that NO append path targets the rebuild's output. SHARD unset
# still means "the fallback's own file" — that file is now
# resolutions.role-switch.tsv, and collect folds it in like any other shard.
# Consequence for the fallback mode: it MUST run collect (EXPECT=0) to publish
# the aggregate its four consumers read. Phases/5-structural.md says so.
#
# WHY a pre-existing aggregate row is MATERIALIZED into a shard rather than
# folded in on every collect: a run that logged fallback rows into resolutions.tsv
# under the OLD behavior (an in-flight migration, a resumed run whose state dir
# predates this fix) still has verdicts that exist nowhere else. Carrying them
# forward on each collect — reading the aggregate as a second input to its own
# rebuild — made the aggregate load-bearing state that could never be dropped, and
# that is what broke supersede: `reset SHARD=<slug>` deleted the shard, so the
# failed attempt's rows in the aggregate became "rows no shard carries" and the
# next collect resurrected them alongside the retry's new verdict — two verdicts
# for one file, the exact state reset exists to prevent. So collect (and reset)
# instead APPENDS such a row, once, to the script-owned $RUN/resolutions.legacy.tsv
# shard, and the aggregate is then rebuilt purely from shards. After that the
# aggregate is derived state: deletable at any moment, reproducible in full.
#
# WHY EVERY reset clears the aggregate, whatever SHARD says: once the aggregate is
# derived state, dropping it is free — and it is the only way a supersede can be
# total, because a superseded row that reached the aggregate has no other way out.
# Materialization runs FIRST and reads the shard that is about to be removed, so
# the rows being superseded count as shard-carried and are deliberately NOT
# preserved; only rows with no shard behind them move to the legacy shard.
#
# WHY reset with SHARD unset exists at all: the no-runtime-dispatch role-switch
# fallback never re-dispatches, so append's dedup (an exact repeat only) was its
# whole protection — a genuine re-decision (a different verdict for a file
# already logged) could only ever ADD a second row. SHARD unset here means "the
# fallback's own target", the same meaning it has for append, never "reset every
# shard".
#
# WHY the seen-set is loaded with getline rather than the `NR == FNR` idiom: awk
# never reads a record from an EMPTY first file, so NR == FNR stays true across the
# second file and every one of its rows is classified as already-seen. The shard
# concatenation is legitimately empty (a dispatched batch that created its shard and
# returned every item as needs-input), and with `NR == FNR` that made collect emit
# nothing and write an empty ledger over an aggregate that was the only copy of its
# verdicts — silently, exit 0. `while ((getline line < f) > 0)` is correct on an
# empty file and on an absent one alike, and portable to mawk.
#
# WHY the signal traps exit: a handler that only removes its temp files falls
# through to the next command, so a Ctrl-C mid-collect cleaned up and then finished
# the rebuild it was meant to abort — over a half-built temp file. Each signal trap
# exits with the conventional 128+signum after cleaning up.
#
# WHY SHARD is validated against a filename-safe charset in BOTH append and
# reset: SHARD interpolates directly into resolutions.$SHARD.tsv, and reset's
# `rm -f` is the skill's only destructive op on an unvalidated interpolated
# variable. collapse() only folds whitespace — a '/' used to fail LOUDLY on
# append (the nested path's parent dir doesn't exist, so `>>` errors) but
# SILENTLY NO-OP on reset (`rm -f` on a path with a missing parent still exits
# 0), and a SHARD built from '..' segments could walk `rm -f` outside $RUN
# entirely. Real dispatch slugs (phases/5-structural.md,
# agents/conflict-resolver.md) are plain batch labels — "batch1", a task id —
# never a path, so the charset is pinned to what a legitimate slug can be.
#
# In :  ACTION   append (default) | collect | reset
#       RUN      run-state dir (required). Created if missing.
#       append:
#         SHARD    the batch slug. Set → $RUN/resolutions.<slug>.tsv (one file per
#                  dispatch, so concurrent resolvers cannot interleave appends).
#                  Unset → $RUN/resolutions.role-switch.tsv, the reserved shard of
#                  the in-conversation role-switch fallback (identical to passing
#                  SHARD=role-switch explicitly, which is what the docs instruct).
#                  NO append path ever writes $RUN/resolutions.tsv — that file is
#                  collect's output alone (see WHY above).
#                  Letters, digits, '.', '_', '-' only when set (see WHY above);
#                  anything else is refused before it reaches a path. The slug
#                  `legacy` is refused too — that shard is script-owned (see
#                  collect).
#         FILE     the resolved path (required).
#         VERDICT  required, one of:
#                    ours | theirs | merged | user           (conflict-region)
#                    ported | kept-delete | kept-customization | renamed-merged
#                                                             (reasoning-bucket)
#         REASON   one-line reason (required — an unexplained verdict is what the
#                  planner cannot review).
#         REGION   the region identity, keyed off VERDICT (see WHY above):
#                  conflict-region verdict → REQUIRED, the 1-based ordinal of the
#                    region within the file, a positive integer (^[1-9][0-9]*$).
#                    Empty, '-', '0' or non-numeric is refused (exit 2) — a fresh
#                    region verdict without an ordinal is the resolver failing its
#                    obligation.
#                  reasoning-bucket verdict → forced to the literal '-' (no regions
#                    by construction; pass '-' or leave unset).
#         The written row is FILE <TAB> VERDICT <TAB> REASON <TAB> REGION.
#         An exact repeat of a row already in the target file is a no-op, not a
#         second row (see WHY above). Two verdicts on the same file that differ only
#         in ordinal are DISTINCT rows and both survive — that is the de-dup fix.
#       collect:
#         EXPECT   how many dispatches were expected (default 0). Zero shards is a
#                  clean no-op when EXPECT is 0 — a merge with no conflicts — and a
#                  hard failure when dispatches were expected but wrote nothing.
#                  The reserved role-switch shard counts as a shard here, so the
#                  fallback mode collects with EXPECT unset/0; the script-owned
#                  legacy shard does NOT (it is no evidence a resolver ran).
#                  Rows already in $RUN/resolutions.tsv that no shard carries are
#                  MATERIALIZED into $RUN/resolutions.legacy.tsv — once — and the
#                  aggregate is then rebuilt from the shards alone, legacy last.
#                  That is the transition guard for state dirs written before the
#                  reserved shard existed, and it is what makes the aggregate
#                  derived state (see WHY above). Exact-row duplicates land once.
#                  Any three-field (pre-column) row in a shard or the aggregate is
#                  normalized to four fields (region=-) on read and warned once (see
#                  WHY above); the run is never refused over it.
#       reset:
#         SHARD    the batch slug being re-dispatched. Set → removes
#                  $RUN/resolutions.<slug>.tsv if present, so the re-dispatch's
#                  rows supersede the prior attempt's instead of accumulating
#                  alongside them. Unset → the role-switch fallback's own
#                  supersede path, i.e. exactly SHARD=role-switch: the file
#                  append's SHARD-unset path writes. It is never "reset every
#                  shard". EITHER WAY reset also removes $RUN/resolutions.tsv, after
#                  materializing any row of it that no shard carries into the legacy
#                  shard — so no superseded verdict can come back and no
#                  only-copy row is lost (see WHY above); the next collect rebuilds
#                  the aggregate. Same charset restriction as append when set,
#                  `legacy` refused likewise. A target that was never written (the
#                  batch's first-ever dispatch, or one already reset) is a clean
#                  no-op either way. Pre-column three-field rows are normalized to
#                  region=- on read and warned once, exactly as collect does.
# Out:  $RUN/resolutions.<slug>.tsv        (append, SHARD set; removed by reset)
#       $RUN/resolutions.role-switch.tsv   (append with SHARD unset; removed by
#                                           reset with SHARD unset)
#       $RUN/resolutions.legacy.tsv        (collect/reset only — never an append
#                                           target; materialized aggregate rows no
#                                           shard carries. Read as a shard, last.)
#       $RUN/resolutions.tsv               (collect only; removed by every reset)
# Exit: 0 done; 2 bad input (including a SHARD outside the allowed charset), an
#       unwritable file, or collect finding no shards when dispatches were
#       expected.
set -u

fail() { echo "FAIL: $*" >&2; exit 2; }

collapse() { printf '%s' "$1" | tr '\n\r\t' '   ' | awk '{ $1 = $1; print }'; }

# The reserved shard slug of the in-conversation role-switch fallback. It is a
# shard like any other so collect (a REBUILD) treats both modes uniformly — see
# header WHY. Must satisfy check_shard's charset.
FALLBACK_SHARD=role-switch

# The script-owned shard. collect and reset write it (materialized aggregate rows
# no other shard carries); NOTHING else may. It is the only copy of a pre-fix
# in-conversation verdict, so a dispatched batch slugged `legacy` sharing the file —
# or a `reset SHARD=legacy` deleting it — would lose verdicts outright. Refused in
# check_shard below. Contrast the OTHER reserved slug, role-switch: that one stays a
# legitimate append/reset target because the docs instruct it by name
# (phases/5-structural.md's no-runtime-dispatch bullet), and it is only "reserved"
# in the sense that a dispatch must not reuse the label.
LEGACY_SHARD=legacy

# SHARD becomes a filename component (resolutions.$SHARD.tsv) in both append
# and reset; reset's `rm -f` is destructive. A '/' would either misroute
# append onto a nested path it then fails to create, or make reset silently
# no-op / walk outside $RUN on a '..'-laden slug — so both refuse identically,
# before either ever builds a path from it. Empty (SHARD unset) is not this
# function's concern; callers check that separately where it matters.
check_shard() {
  case "$1" in
    "$LEGACY_SHARD")
      fail "SHARD '$LEGACY_SHARD' is reserved: \$RUN/resolutions.$LEGACY_SHARD.tsv is written by collect/reset alone (materialized rows that exist in no other shard) — pick another slug"
      ;;
    *[!A-Za-z0-9._-]*)
      fail "SHARD must contain only letters, digits, '.', '_', '-' (got '$1') — it becomes a filename component"
      ;;
  esac
}

# --- shard/aggregate plumbing shared by collect and reset --------------------
AGGREGATE=""       # set once RUN is known
LEGACY_FILE=""
SCRATCH=""
SHARD_COUNT=0
LEGACY_TOTAL=0     # pre-column (three-field) rows seen this invocation
LEGACY_FILES=""    # the file(s) that carried them, for the one warning

cleanup() { [[ -n "$SCRATCH" ]] && rm -rf "$SCRATCH"; SCRATCH=""; return 0; }

# One scratch dir per invocation, inside $RUN so the rename onto the aggregate is
# same-filesystem. The signal traps EXIT after cleaning up — a handler that only
# removed its temps fell through and finished the very rebuild the signal aborted
# (see header WHY). 128+signum is the conventional status for a signal death.
scratch_dir() {
  [[ -n "$SCRATCH" ]] && return 0
  SCRATCH=$(mktemp -d "$RUN/.resolutions.XXXXXX") || fail "cannot create a temp dir in $RUN"
  trap 'cleanup' EXIT
  trap 'cleanup; exit 129' HUP
  trap 'cleanup; exit 130' INT
  trap 'cleanup; exit 143' TERM
}

# Fills SHARDS[]/SHARD_COUNT with every shard EXCEPT the script-owned legacy one,
# in glob order. $RUN/resolutions.tsv can never match resolutions.*.tsv (that
# pattern needs a second '.'), so the aggregate is never an input to its own
# rebuild — the property that makes it derived state.
shard_list() {
  SHARDS=()
  SHARD_COUNT=0
  for f in "$RUN"/resolutions.*.tsv; do
    [[ -f "$f" ]] || continue
    [[ "$f" = "$LEGACY_FILE" ]] && continue
    SHARDS[SHARD_COUNT]=$f
    SHARD_COUNT=$((SHARD_COUNT + 1))
  done
}

# shard_concat <dest> — every non-legacy shard's rows, or an empty file when there
# are none. Legitimately empty: a dispatched batch that returned every item as
# needs-input still created its shard. Any three-field (pre-column) row is
# normalized to four fields (region=-) as it is read — see header WHY. A four-field
# row is emitted byte-for-byte, so a rebuild over post-column shards is byte-stable.
shard_concat() {
  : > "$1" || fail "cannot write $1"
  [[ "$SHARD_COUNT" -gt 0 ]] || return 0
  local f
  for f in "${SHARDS[@]}"; do
    awk -F'\t' 'NF == 3 { $0 = $0 "\t-" } { print }' "$f" >> "$1" \
      || fail "cannot read the resolution shards"
  done
}

# Rows of <file> that neither <seen-a> nor <seen-b> already carries, in order,
# exact-duplicates collapsed. Pass /dev/null for an unused seen-source. getline
# (not `NR == FNR`) because a seen-source is legitimately EMPTY — see header WHY.
# norm() appends `\t-` to a three-field (pre-column) row so the comparison, and the
# rows this emits, are on normalized four-field rows — a pre-column aggregate row
# and its already-normalized shard/legacy twin then dedup as the same row instead
# of both surviving. A four-field row is returned unchanged (byte-stable).
rows_not_seen() { # rows_not_seen <file> <seen-a> <seen-b> <dest>
  awk -F'\t' -v a="$2" -v b="$3" '
    function norm(line,   n, arr) {
      n = split(line, arr, "\t")
      return (n == 3) ? line "\t-" : line
    }
    BEGIN {
      while ((getline line < a) > 0) if (line != "") seen[norm(line)] = 1
      while ((getline line < b) > 0) if (line != "") seen[norm(line)] = 1
    }
    NF { row = norm($0); if (!(row in seen)) { seen[row] = 1; print row } }
  ' "$1" > "$4" || fail "cannot read $1"
}

# MATERIALIZE, don't fold: an aggregate row no shard carries is a verdict that
# exists nowhere else (a state dir written before the role-switch fallback got its
# own shard). Move it into the legacy shard ONCE, so from here on the aggregate is
# rebuildable from shards alone and every reset can drop it (see header WHY).
# Callers invoke this BEFORE removing anything.
materialize_legacy() { # materialize_legacy <shard-concat>
  [[ -f "$AGGREGATE" ]] || return 0
  rows_not_seen "$AGGREGATE" "$1" "$LEGACY_FILE" "$SCRATCH/legacy-new"
  [[ -s "$SCRATCH/legacy-new" ]] || return 0
  cat "$SCRATCH/legacy-new" >> "$LEGACY_FILE" \
    || fail "cannot append to $LEGACY_FILE"
}

# Count the pre-column (three-field) rows across the on-disk aggregate and every
# shard (the legacy shard included), name the files that carried them, and emit ONE
# stderr warning per invocation — never per row, never a refusal (see header WHY).
# Run on the rebuild path only: a collect that leaves a pre-column aggregate
# untouched (zero shards, EXPECT 0) normalizes nothing, so it must warn about
# nothing. $RUN/resolutions.tsv can never match resolutions.*.tsv, so the aggregate
# is named explicitly.
scan_and_warn_legacy() {
  local f n
  LEGACY_TOTAL=0
  LEGACY_FILES=""
  for f in "$AGGREGATE" "$RUN"/resolutions.*.tsv; do
    [[ -f "$f" ]] || continue
    n=$(awk -F'\t' 'NF == 3 { c++ } END { print c+0 }' "$f")
    [[ "$n" -gt 0 ]] || continue
    LEGACY_TOTAL=$((LEGACY_TOTAL + n))
    LEGACY_FILES="$LEGACY_FILES $f"
  done
  [[ "$LEGACY_TOTAL" -gt 0 ]] || return 0
  echo "WARNING: $LEGACY_TOTAL pre-column resolution row(s) normalized to region=- (shard(s):$LEGACY_FILES)" >&2
}

ACTION=$(collapse "${ACTION:-append}")
RUN="${RUN:-}"
[[ -n "$RUN" ]] || fail "RUN required (the run-state dir)"
AGGREGATE="$RUN/resolutions.tsv"
LEGACY_FILE="$RUN/resolutions.$LEGACY_SHARD.tsv"

case "$ACTION" in
  append)
    SHARD=$(collapse "${SHARD:-}")
    check_shard "$SHARD"
    FILE=$(collapse "${FILE:-}")
    VERDICT=$(collapse "${VERDICT:-}")
    REASON=$(collapse "${REASON:-}")
    REGION=$(collapse "${REGION:-}")

    [[ -n "$FILE" ]] || fail "FILE required (the resolved path)"
    [[ -n "$REASON" ]] || fail "REASON required (one line; the planner reviews these)"
    case "$VERDICT" in
      ours|theirs|merged|user|ported|kept-delete|kept-customization|renamed-merged) ;;
      "") fail "VERDICT required (ours|theirs|merged|user|ported|kept-delete|kept-customization|renamed-merged)" ;;
      *)  fail "VERDICT must be one of ours|theirs|merged|user|ported|kept-delete|kept-customization|renamed-merged (got '$VERDICT')" ;;
    esac

    # REGION is keyed off the (now-validated) verdict class — see header WHY. The
    # four conflict-region verdicts name a real hunk, so the resolver MUST supply
    # its 1-based ordinal; empty / '-' / '0' / leading-zero / non-numeric is the
    # resolver failing that obligation and is refused before a row is written. The
    # four reasoning-bucket verdicts have no regions, so REGION is FORCED to '-'
    # whatever came in (the documented input is '-' or unset). This keeps the
    # written row four fields wide either way, so a positional reader never sees a
    # short row.
    case "$VERDICT" in
      ours|theirs|merged|user)
        case "$REGION" in
          ''|*[!0-9]*|0*)
            fail "REGION must be a positive integer (the 1-based conflict-region ordinal, ^[1-9][0-9]*\$) for a '$VERDICT' verdict — got '$REGION'. The ordinal is the region's position in the FILE, top to bottom — it does not change with the order you resolve regions in." ;;
        esac
        ;;
      ported|kept-delete|kept-customization|renamed-merged)
        REGION='-' ;;
    esac

    mkdir -p "$RUN" || fail "cannot create $RUN"
    # SHARD unset is the role-switch fallback — which gets its OWN shard, not the
    # aggregate collect rebuilds (see header WHY).
    [[ -n "$SHARD" ]] || SHARD=$FALLBACK_SHARD
    OUT="$RUN/resolutions.$SHARD.tsv"
    ROW=$(printf '%s\t%s\t%s\t%s' "$FILE" "$VERDICT" "$REASON" "$REGION")

    # An exact repeat is a no-op, not a second row (see header WHY): a
    # re-dispatch that resends an already-logged region at the same verdict
    # must not double-count it for the four consumers.
    if [[ -f "$OUT" ]] && LC_ALL=C grep -Fxq -- "$ROW" "$OUT"; then
      exit 0
    fi

    printf '%s\n' "$ROW" >> "$OUT" || fail "cannot append to $OUT"
    ;;

  collect)
    EXPECT=$(collapse "${EXPECT:-0}")
    mkdir -p "$RUN" || fail "cannot create $RUN"

    shard_list
    if [[ "$SHARD_COUNT" -eq 0 ]]; then
      # A merge with no conflicts dispatches nothing and must stay a clean no-op.
      # But zero shards WHEN DISPATCHES WERE EXPECTED means every resolver's work
      # is unrecorded, and silently writing an empty ledger would tell four
      # consumers that nothing was resolved. The legacy shard is excluded from the
      # count deliberately: materialized pre-fix rows are no evidence that a
      # resolver dispatched in THIS run wrote anything.
      case "$EXPECT" in
        ''|0) ;;
        *) fail "$EXPECT dispatch(es) were expected but $RUN holds no resolutions.<slug>.tsv shard — the resolvers' verdicts are unrecorded" ;;
      esac
      # Nothing to rebuild FROM, so leave any pre-fix aggregate exactly as it is:
      # zero shards must not become a way to truncate the only copy of its rows.
      # (Nothing deletes that aggregate either — every reset materializes first.)
      [[ -f "$LEGACY_FILE" ]] || exit 0
    fi

    # REBUILD, never append onto a previous result: a `cat >>` on a retried batch
    # doubles every row from the batches that already succeeded, and the doubled
    # rows are indistinguishable from real ones to every consumer.
    scratch_dir
    # Warn once BEFORE the rebuild normalizes anything away — scanning the on-disk
    # inputs while the pre-column rows are still three fields.
    scan_and_warn_legacy
    shard_concat "$SCRATCH/aggregate"

    # Any aggregate row no shard carries becomes a legacy-shard row, once. From
    # here the aggregate is derived state (see header WHY).
    materialize_legacy "$SCRATCH/aggregate"

    # Legacy rows land AFTER the shard rows, and only when no shard already
    # carries them — a stable order, so re-collecting the same state is
    # byte-identical, and a row that later shows up in a real shard is not doubled.
    if [[ -f "$LEGACY_FILE" ]]; then
      rows_not_seen "$LEGACY_FILE" "$SCRATCH/aggregate" /dev/null "$SCRATCH/legacy-add"
      cat "$SCRATCH/legacy-add" >> "$SCRATCH/aggregate" \
        || fail "cannot append the legacy shard's rows"
    fi

    mv "$SCRATCH/aggregate" "$AGGREGATE" || fail "cannot write $AGGREGATE"
    cleanup
    trap - EXIT HUP INT TERM
    ;;

  reset)
    SHARD=$(collapse "${SHARD:-}")
    check_shard "$SHARD"
    mkdir -p "$RUN" || fail "cannot create $RUN"
    # Symmetric with append: SHARD unset means the role-switch fallback's own
    # target, not "reset every shard" (see header WHY).
    [[ -n "$SHARD" ]] || SHARD=$FALLBACK_SHARD

    # Materialize BEFORE removing anything. The aggregate is about to go, and the
    # rows that must survive it are exactly the ones no shard carries — so this
    # reads the shard that is about to be deleted ON PURPOSE: its rows are the
    # superseded ones, and counting them as shard-carried is what keeps them from
    # being preserved.
    scratch_dir
    scan_and_warn_legacy
    shard_list
    shard_concat "$SCRATCH/shards"
    materialize_legacy "$SCRATCH/shards"

    rm -f "$RUN/resolutions.$SHARD.tsv" || fail "cannot remove $RUN/resolutions.$SHARD.tsv"
    # EVERY reset drops the aggregate: a superseded row that already reached it has
    # no other way out, and the next collect rebuilds it from the shards (the
    # legacy shard included), so nothing is lost.
    rm -f "$AGGREGATE" || fail "cannot remove $AGGREGATE"
    cleanup
    trap - EXIT HUP INT TERM
    # A target that was never written is a clean no-op, not an error: the
    # batch's first-ever dispatch, or a target already reset, has nothing to
    # supersede.
    ;;

  *) fail "unknown ACTION '$ACTION' (want append|collect|reset)" ;;
esac
