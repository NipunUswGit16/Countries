#!/usr/bin/env bash
# log-learning.sh — append one component fact to $RUN/learnings.md, the per-run
# file every later executor reads at start so it stops re-discovering what an
# earlier task already learned the hard way.
#
# Content contract: facts about the COMPONENT only — commands, environment
# requirements, flaky suites, generated-file boundaries, surprising layout. Never
# instructions (PLAN.md stays the only authority on what to do), never task
# status (the migration log owns that), never secrets.
#
# WHY keyless — no PHASE_KEY guard: the load guards make a phase's ENTRY-POINT
# script refuse to run until the orchestrator has loaded that phase's file. This
# script's callers are executor subagents, which never load a phase file, so a
# guard here would brick every append. It is not a phase entry point and must not
# appear in the key inventory tests/skill-lint.test.sh audits.
#
# WHY a refused append still exits ZERO: the 40-entry cap is a context-budget
# guard (the file has to stay a screenful for the next executor), not a quality
# bar. A chatty executor must never fail its task by over-sharing, so hitting the
# cap is a stderr warning to the caller, not an error.
#
# In :  RUN   run-state dir (required). Created if missing.
#       ITEM  item key the fact came from (task id, gate label, …), non-empty.
#       TEXT  the learning, one fact, non-empty. Newlines collapse to single
#             spaces and the ends are trimmed, so one fact always costs one line.
# Out:  $RUN/learnings.md  created on first append (no header — bullets only),
#                          then one appended `- [<ITEM>] <TEXT>` line. An exact
#                          duplicate of a line already there is dropped, and an
#                          append past 40 entries is refused with a warning.
# Exit: 0 appended, dropped as a duplicate, or refused at the cap;
#       non-zero if RUN, ITEM or TEXT is missing/empty.
set -euo pipefail

RUN="${RUN:?ERROR: RUN dir required}"

# Collapse and trim BEFORE the emptiness check: a TEXT of nothing but whitespace
# is as empty as an unset one, and would append a bullet carrying no fact.
collapse() { printf '%s' "$1" | tr '\n\r\t' '   ' | awk '{ $1 = $1; print }'; }
ITEM=$(collapse "${ITEM:-}")
TEXT=$(collapse "${TEXT:-}")
[[ -n "$ITEM" ]] || { echo "ERROR: ITEM required (the item the fact came from)" >&2; exit 1; }
[[ -n "$TEXT" ]] || { echo "ERROR: TEXT required (the learning, one fact)" >&2; exit 1; }

mkdir -p "$RUN"
learnings="$RUN/learnings.md"
line="- [$ITEM] $TEXT"

# An exact repeat is a no-op, not an error: two executors tripping over the same
# quirk is the normal case, and the second must not be punished for reporting it.
if [[ -f "$learnings" ]] && LC_ALL=C grep -Fxq -- "$line" "$learnings"; then
  exit 0
fi

# Entries are the '- [' lines — the only lines the file is allowed to hold.
if [[ -f "$learnings" ]]; then
  entries=$(LC_ALL=C grep -c '^- \[' "$learnings" || true)
else
  entries=0
fi
if [[ "$entries" -ge 40 ]]; then
  echo "WARNING: learnings cap reached (40 entries) — not appending: $line" >&2
  exit 0
fi

printf '%s\n' "$line" >> "$learnings"
