#!/usr/bin/env bash
# spawn-summary.sh — summarize $RUN/spawns.tsv for Phase 8 (requested tallies).
#
# In :  RUN       run-state dir (required); reads $RUN/spawns.tsv (header row
#                 optional — a headerless ledger is counted in full and says so).
#       PLAN      plan markdown (default .kairos/migration/PLAN.md); used to
#                 count `### T<n>:` task headings as the executor expected M.
# Out:  stdout    per-tier REQUESTED tally (strong/coder/executor, incl. zeros),
#                 escalations count, retries count, two plain conflict-resolver
#                 facts (dispatches from spawns.tsv, resolution rows from
#                 $RUN/resolutions.tsv UNION its per-batch resolutions.<slug>.tsv
#                 shards, de-duplicated on the exact row — a different unit from
#                 dispatches, deliberately NOT compared), and one executor cross-check
#                 of first-attempt
#                 dispatches (the FIRST 'ok'-or-'fail' executor row per ITEM — a
#                 green-retried task logs [fail, retried, ok] and a needs-input task
#                 logs [needs-input, ok] on the committed re-spawn, so counting every
#                 non-retry/non-escalation/non-needs-input row would count the
#                 recovered task TWICE; one row per ITEM counts each task once)
#                 against the PLAN
#                 task headings, as 'logged N of ~M expected' — N < M means tasks
#                 were skipped, EXCEPT on a role-switch run, which dispatches nothing
#                 and legitimately logs 0 (a note says so; judge against the run mode).
# Exit: 0 on success; non-zero if RUN missing/empty.
set -euo pipefail

RUN="${RUN:?ERROR: RUN dir required}"
PLAN="${PLAN:-.kairos/migration/PLAN.md}"
spawns="$RUN/spawns.tsv"
resolutions="$RUN/resolutions.tsv"

# Resolution data-row count → resolutions logged (nothing anywhere → 0). This is a
# fact about the merge's size, not an expectation: Phase 5 batches ~10 items per
# dispatch and each dispatch logs one row per resolved region, so dispatches and
# resolution rows are different units and cannot audit each other.
#
# Counted over $RUN/resolutions.tsv UNION every $RUN/resolutions.<slug>.tsv shard,
# de-duplicated on the exact row. WHY the union: the aggregate is written by
# log-resolution.sh's `collect` ALONE, so a run whose session died or compacted
# between the last resolution and that collect has its whole ledger in shards — and
# reading only the aggregate reported "0 resolutions logged" into the Phase 8 summary,
# silently, because the count was `[ -f ]`-guarded with a zero default. The
# in-conversation role-switch fallback is the sharpest case: it never dispatches, so
# the dispatch count is a legitimate 0 and this number is the only signal that any
# resolution happened at all. WHY de-duplicated: after a collect every shard row is
# also an aggregate row, and a doubled tally is as wrong as a zero one.
# `awk 'NF'` per file, not `cat`: a hand-written ledger with no trailing newline
# would otherwise splice its last row onto the next file's first.
#
# WHY norm() BEFORE the de-dup: log-resolution.sh's collect normalizes a legacy
# three-field (pre-region-column) row to four fields as it rebuilds the aggregate,
# but leaves the on-disk shard row three-field. De-duplicating on the RAW row then
# keeps both twins — the three-field shard row and its four-field aggregate copy —
# and this fact comes out one high per legacy row, in exactly the
# resume-across-a-skill-upgrade case the normalization exists for. norm() is
# log-resolution.sh's, character for character (that script owns the ledger format);
# handoff-structural.sh and dropped-template-changes.sh carry the same copy. Keep
# the four in step: a fourth field appended there is a fourth field owed here
# (tests/skill-lint.test.sh binds the copies).
res_rows=$(
  for f in "$resolutions" "$RUN"/resolutions.*.tsv; do
    [[ -f "$f" ]] || continue
    awk 'NF' "$f"
  done | awk -F'\t' '
    function norm(line,   n, arr) {
      n = split(line, arr, "\t")
      return (n == 3) ? line "\t-" : line
    }
    NF { row = norm($0)
         if (!(row in seen)) { seen[row] = 1; n++ } }
    END { print n+0 }'
)

# PLAN task headings → executor expected M (absent → 0). The anchor is
# plan-slice.sh's `^### T[0-9]+:` verbatim: a looser `^### T` also matches prose
# headings ("### Testing notes") and manufactures a false skipped-task signal.
if [[ -f "$PLAN" ]]; then
  exec_expected=$(awk '/^### T[0-9]+:/{n++} END{print n+0}' "$PLAN")
else
  exec_expected=0
fi

# Tally from spawns.tsv. Absent/empty → all zeros.
#
# Row 1 is skipped only when it IS the header log-spawn.sh writes — first column
# literally `phase`, where a data row's phase column is a digit that script enforces.
# An unconditional `NR == 1 { next }` dropped the first DATA row of a headerless
# ledger: spawns.tsv is a plain TSV in a state dir that gets hand-edited, truncated
# and copied between runs, and the loss was silent and one-directional (work hidden,
# never invented) — the missing first attempt also read as a phantom skipped task in
# the executor cross-check below, which accuses a complete run. A headerless ledger is
# counted in full and says so on one line instead.
awk -F'\t' -v res_rows="$res_rows" -v exec_expected="$exec_expected" '
function trim(s) { gsub(/^[ \t\r\n]+/, "", s); gsub(/[ \t\r\n]+$/, "", s); return s }
NR == 1 && $1 == "phase" { next }
NR == 1                  { headerless = 1 }
NF < 1  { next }
{
  tier = $3
  role = $2
  outcome = $6
  # actual-model probe: column 7 is the subagent'\''s honest report of the model it
  # actually ran on (log-spawn.sh records it unchecked; the pin check only guards the
  # REQUESTED model in column 4). A row that carries an actual_model differing from
  # the requested one is the run'\''s one wrong-model signal — emit it as a report line,
  # non-blocking. Compared trimmed and case-insensitively so a whitespace- or
  # case-only difference is not a false mismatch; the line quotes the raw columns.
  req = trim($4); act = trim($7)
  if (act != "" && tolower(act) != tolower(req))
    mism[++n_mism] = "MISMATCH: requested=" $4 " actual=" $7 " (phase " $1 ", item " $5 ")"
  if (tier == "strong")   n_strong++
  else if (tier == "coder")    n_coder++
  else if (tier == "executor") n_exec_tier++
  if (outcome == "escalated") n_esc++
  if (outcome == "retried") n_retry++
  if (role == "conflict-resolver") n_cr++
  # Only FIRST attempts are comparable to planned tasks, and a task contributes
  # exactly ONE. A completed task can log several executor rows: a green-retried task
  # is [fail, retried, ok] and a needs-input task is [needs-input, ok] on the committed
  # re-spawn (phases/7 step 6 logs the trailing `ok` on every successful commit,
  # INCLUDING one reached via auto-retry). Excluding only retried/escalated/needs-input
  # would count BOTH the `fail` and the trailing `ok` of a green-retried task, pushing N
  # above M. So count the first `ok`-or-`fail` executor row per ITEM (column 5) and no
  # more: retried/escalated/needs-input rows never count (they are re-spawns of a task
  # already counted, each with its own signal — retries/escalations print above), and a
  # second ok/fail row for an item is that same task, already counted once.
  if (role == "executor" && (outcome == "ok" || outcome == "fail") && !($5 in exec_seen)) {
    exec_seen[$5] = 1; n_exec_role++
  }
}
END {
  print "requested spawns by tier:"
  printf "tier strong: %d\n", n_strong + 0
  printf "tier coder: %d\n", n_coder + 0
  printf "tier executor: %d\n", n_exec_tier + 0
  printf "escalations: %d\n", n_esc + 0
  printf "retries: %d\n", n_retry + 0
  printf "conflict-resolver: %d dispatches, %d resolutions logged\n", n_cr + 0, res_rows + 0
  printf "executor: logged %d of ~%d expected\n", n_exec_role + 0, exec_expected + 0
  # Role-switch carve-out, the same style the resolutions count carries: an
  # in-conversation role-switch run never dispatches, and log-spawn.sh refuses a
  # session-model row, so a clean role-switch run legitimately logs 0 first attempts.
  # 0 here is NOT the "tasks were skipped" signal it is for a dispatch run — judge it
  # against the run mode, not the plan count. But ONLY a run that dispatched NOTHING
  # is a role-switch run: a run carrying conflict-resolver dispatches or tier requests
  # (executor tasks that stalled at needs-input, say) is a DISPATCH run that skipped
  # execution, and "0 is legitimate" would gloss a real skip and flatly contradict the
  # "N dispatches" line above it. So gate the note on no dispatch of any kind having
  # been requested; when dispatches exist, the "logged 0 of ~M expected" line stands
  # as the genuine skip signal it is.
  if (n_exec_role + 0 == 0 && exec_expected + 0 > 0 && (n_strong + n_coder + n_exec_tier + n_cr) + 0 == 0)
    print "note: executor logged 0 — a role-switch run dispatches nothing (log-spawn refuses a session-model row), so 0 is legitimate there; judge against the run mode, not the plan count"
  if (headerless)
    print "note: spawns.tsv has no header row (hand-written, truncated or copied) — every row was counted as a dispatch"
  for (i = 1; i <= n_mism; i++) print mism[i]
}
' "${spawns}" 2>/dev/null || awk -v res_rows="$res_rows" -v exec_expected="$exec_expected" 'BEGIN {
  print "requested spawns by tier:"
  print "tier strong: 0"
  print "tier coder: 0"
  print "tier executor: 0"
  print "escalations: 0"
  print "retries: 0"
  printf "conflict-resolver: 0 dispatches, %d resolutions logged\n", res_rows + 0
  printf "executor: logged 0 of ~%d expected\n", exec_expected + 0
  # Same role-switch carve-out as the main block: no spawns.tsv at all is the shape a
  # clean role-switch run leaves (it dispatches nothing and log-spawn refuses a
  # session-model row), so 0 first attempts is legitimate — judge against the run mode.
  if (exec_expected + 0 > 0)
    print "note: executor logged 0 — a role-switch run dispatches nothing (log-spawn refuses a session-model row), so 0 is legitimate there; judge against the run mode, not the plan count"
}'
