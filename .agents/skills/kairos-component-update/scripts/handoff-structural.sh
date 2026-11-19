#!/usr/bin/env bash
# handoff-structural.sh — prints a read-time structural handoff card to stdout:
# clean/conflict/resolution counts, the postmerge-gate verdict, and pointers — so
# the planner starts from a tally instead of `git show HEAD` of the whole
# structural commit, and a resumed Continue session always sees current state.
#
# Env in:  PHASE_KEY  required — proof-of-load key stated in phases/6-planning.md
#          RUN        migration state dir (required)
# Reads (all optional; a missing/empty input degrades to 0 / NOT_RUN, never a
#         hard failure — some inputs genuinely don't exist yet, e.g. no
#         conflicts means no resolutions.tsv):
#   $RUN/clean-merged.txt
#   $RUN/conflicts.txt
#   $RUN/resolutions.tsv                 (file <TAB> verdict <TAB> reason <TAB> region)
#   $RUN/resolutions.<slug>.tsv          the per-batch shards, read alongside the
#                                        aggregate and de-duplicated against it — the
#                                        aggregate only exists after a `collect`
#   $RUN/coverage-blind.txt
#   $RUN/build-postmerge.status          ("OK" / "FAIL" / "EXTRACTOR_MISMATCH" / "SKIP")
#   $RUN/test-baseline.failures.txt + $RUN/test-postmerge.failures.txt
#   $RUN/test-postmerge.status           ("OK" / "FAIL" / "EXTRACTOR_MISMATCH" / "SKIP")
#   $RUN/yaml-gate-postmerge.tsv         (severity <TAB> file <TAB> kind <TAB> detail)
#   $RUN/gate-postmerge.tsv              (check <TAB> status <TAB> detail <TAB> evidence,
#                                         plus AGGREGATE <TAB> status — written by gate.sh)
# Stdout:  counts and pointers only; never a resolution's free-text reason or a
#          raw log body. The per-verdict resolution tallies cover log-resolution.sh's
#          WHOLE closed vocabulary — the four mechanical verdicts and the four
#          reasoning-bucket ones — so they account for resolutions_total exactly.
# Exit:    0
set -u

# Phase-load guard: this key is stated ONLY in phases/6-planning.md, so an
# orchestrator that skipped loading that file cannot know it. This script is the
# planner's entry point; the guard turns a skipped load into a stop instead of a
# planning phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "hw5c2vnd" ]] \
  || { echo "FAIL: load phases/6-planning.md first" >&2; exit 1; }

: "${RUN:?FAIL: RUN not set}"

count_entries() {
  if [[ -f "$1" ]]; then
    awk 'NF { n++ } END { print n+0 }' "$1"
  else
    echo 0
  fi
}

CLEAN=$(count_entries "$RUN/clean-merged.txt")
CONFLICTS=$(count_entries "$RUN/conflicts.txt")

# Resolution tallies are counted over $RUN/resolutions.tsv UNION every
# $RUN/resolutions.<slug>.tsv shard, de-duplicated on the exact row.
#
# WHY the union: the aggregate is written by log-resolution.sh's `collect` ALONE, so a
# run whose session died or compacted between the last resolution and that collect
# has its whole ledger in shards. Reading only the aggregate printed
# `resolutions_total: 0` straight into planning — and the planner sizes its review
# from these numbers, where a false zero reads as "no template change was dropped
# anywhere", the one thing this card exists to prevent. followup-completeness.sh
# already reads the shards for the same reason.
#
# WHY de-duplicated: after a collect every shard row is ALSO an aggregate row, so a
# naive union doubles every tally — as wrong as the zero it replaces.
#
# WHY norm() BEFORE the de-dup: log-resolution.sh's collect normalizes a legacy
# three-field (pre-region-column) row to four fields as it rebuilds the aggregate,
# but leaves the on-disk shard row three-field. De-duplicating on the raw row then
# kept BOTH twins — the three-field shard row and its four-field aggregate copy —
# and every tally on this card came out one high per legacy row, in exactly the
# resume-across-a-skill-upgrade case the normalization exists for. norm() is
# log-resolution.sh's, character for character (that script owns the ledger
# format); dropped-template-changes.sh and spawn-summary.sh carry the same copy.
# Keep the four in step: a fourth field appended there is a fourth field owed here.
#
# `awk 'NF'` per file rather than `cat`: a hand-written or truncated ledger with no
# trailing newline would otherwise splice its last row onto the next file's first.
res_count() { # res_count [verdict] — deduped rows across the aggregate and all shards
  local v="${1:-}"
  for f in "$RUN/resolutions.tsv" "$RUN"/resolutions.*.tsv; do
    [[ -f "$f" ]] || continue
    awk 'NF' "$f"
  done | awk -F'\t' -v v="$v" '
    function norm(line,   n, arr) {
      n = split(line, arr, "\t")
      return (n == 3) ? line "\t-" : line
    }
    NF { row = norm($0)
         if (!(row in seen)) { seen[row] = 1; if (v == "" || $2 == v) c++ } }
    END { print c+0 }'
}

RES_TOTAL=$(res_count)
RES_OURS=$(res_count ours)
RES_THEIRS=$(res_count theirs)
RES_MERGED=$(res_count merged)
RES_USER=$(res_count user)
# The four reasoning-bucket verdicts complete log-resolution.sh's closed vocabulary.
# They were counted in RES_TOTAL and named nowhere, which made the total a number with a
# silent remainder — and these are the rows that cost the most to miss: a `kept-delete`
# drops a template change outright, a `ported` moves it somewhere the planner has to go
# look, `kept-customization` declines a template deletion and `renamed-merged` wove two
# changes at a new path. The planner sizes its review from this card, so a row that is
# counted but unnamed is a review that never happens. INVARIANT: the per-verdict tallies
# must account for RES_TOTAL, so a ninth verdict kind added to log-resolution.sh needs a
# line here (tests/handoff-structural.test.sh reads the vocabulary from that script's
# accepted-verdict case arm and checks the sum).
RES_PORTED=$(res_count ported)
RES_KEPT_DELETE=$(res_count kept-delete)
RES_KEPT_CUSTOMIZATION=$(res_count kept-customization)
RES_RENAMED_MERGED=$(res_count renamed-merged)

COVERAGE_BLIND=$(count_entries "$RUN/coverage-blind.txt")

BUILD_STATUS=NOT_RUN
[[ -f "$RUN/build-postmerge.status" ]] && BUILD_STATUS=$(cat "$RUN/build-postmerge.status")

TEST_REGRESSIONS=NOT_RUN
if [[ -f "$RUN/test-baseline.failures.txt" ]] && [[ -f "$RUN/test-postmerge.failures.txt" ]]; then
  # Only a status that means the suite really ran licenses a count. On
  # EXTRACTOR_MISMATCH the run failed and the extractor matched nothing; on SKIP
  # (the Go multi-module sweep finding no module with tests) nothing ran at all.
  # Either way the empty comm is silence, not a clean merge, and any number here
  # would be a false zero the planner sizes the work from. An absent status file
  # is an older run dir, which keeps counting.
  PM_STATUS=$(cat "$RUN/test-postmerge.status" 2>/dev/null || true)
  case "$PM_STATUS" in
    OK|FAIL|"")
      # comm requires both sets ordered under ITS collation, but the two failure
      # files were written by plain `sort -u` in whatever locale their sessions
      # ran — and the Phase 4.5 baseline and the post-merge run can come from
      # sessions with different LC_COLLATE. Re-sort both sides under LC_ALL=C
      # (the same pattern as gate.sh's compare_sets) so the count is a function
      # of file contents, never of an environment this script doesn't own. A
      # failed comparison reads UNAVAILABLE, never a false zero.
      HS_CMPA=$(mktemp "${TMPDIR:-/tmp}/handoff-comm-a.XXXXXX") || HS_CMPA=""
      HS_CMPB=$(mktemp "${TMPDIR:-/tmp}/handoff-comm-b.XXXXXX") || HS_CMPB=""
      if [[ -n "$HS_CMPA" ]] && [[ -n "$HS_CMPB" ]] \
         && LC_ALL=C sort -u "$RUN/test-baseline.failures.txt" > "$HS_CMPA" 2>/dev/null \
         && LC_ALL=C sort -u "$RUN/test-postmerge.failures.txt" > "$HS_CMPB" 2>/dev/null; then
        TEST_REGRESSIONS=$(
          LC_ALL=C comm -13 "$HS_CMPA" "$HS_CMPB" \
            | awk 'NF { n++ } END { print n+0 }'
        )
      else
        TEST_REGRESSIONS="UNAVAILABLE (comparison failed)"
      fi
      rm -f "${HS_CMPA:-}" "${HS_CMPB:-}" 2>/dev/null
      ;;
    *)
      TEST_REGRESSIONS="UNAVAILABLE ($PM_STATUS)"
      ;;
  esac
fi

YAML_FAIL=0 YAML_SKIP=0
if [[ -f "$RUN/yaml-gate-postmerge.tsv" ]]; then
  YAML_FAIL=$(awk -F'\t' 'NF && $1 == "fail" { n++ } END { print n+0 }' "$RUN/yaml-gate-postmerge.tsv")
  YAML_SKIP=$(awk -F'\t' 'NF && $1 == "skip" { n++ } END { print n+0 }' "$RUN/yaml-gate-postmerge.tsv")
fi

# Postmerge-gate verdict, read from the card gate.sh wrote. The card is
# per-check rows (check <TAB> status <TAB> detail <TAB> evidence) plus a final
# AGGREGATE row; the handoff carries the aggregate plus every non-PASS check row
# so the planner sees the gate's actual findings, not a summary of a summary. An
# absent card degrades to an explicit "no gate card found" — never a silent
# omission the planner could misread as a pass.
GATE_TSV="$RUN/gate-postmerge.tsv"
POSTMERGE_GATE="no gate card found"
GATE_ROWS=""
if [[ -f "$GATE_TSV" ]]; then
  POSTMERGE_GATE=$(awk -F'\t' '$1 == "AGGREGATE" { print $2 }' "$GATE_TSV" | tail -1)
  [[ -n "$POSTMERGE_GATE" ]] || POSTMERGE_GATE="no AGGREGATE line in gate card"
  GATE_ROWS=$(awk -F'\t' 'NF && $1 != "AGGREGATE" && $2 != "PASS" \
    { print "postmerge_gate_row: " $1 " " $2 " — " $3 }' "$GATE_TSV")
fi

{
  echo "# Structural handoff"
  echo
  echo "clean_merged: $CLEAN"
  echo "conflicts: $CONFLICTS"
  echo "resolutions_total: $RES_TOTAL"
  echo "resolutions_ours: $RES_OURS"
  echo "resolutions_theirs: $RES_THEIRS"
  echo "resolutions_merged: $RES_MERGED"
  echo "resolutions_user: $RES_USER"
  echo "resolutions_ported: $RES_PORTED"
  echo "resolutions_kept-delete: $RES_KEPT_DELETE"
  echo "resolutions_kept-customization: $RES_KEPT_CUSTOMIZATION"
  echo "resolutions_renamed-merged: $RES_RENAMED_MERGED"
  echo "coverage_blind: $COVERAGE_BLIND"
  echo "build_status: $BUILD_STATUS"
  echo "test_regressions: $TEST_REGRESSIONS"
  echo "yaml_fail: $YAML_FAIL"
  echo "yaml_skip: $YAML_SKIP"
  echo "postmerge_gate: $POSTMERGE_GATE"
  if [[ -n "$GATE_ROWS" ]]; then
    printf '%s\n' "$GATE_ROWS"
  fi
  echo
  echo "## Pointers"
  echo "conflicts: $RUN/conflicts.txt"
  echo "resolutions: $RUN/resolutions.tsv"
  echo "coverage-blind: $RUN/coverage-blind.txt"
  echo "gate-card: $GATE_TSV"
}
