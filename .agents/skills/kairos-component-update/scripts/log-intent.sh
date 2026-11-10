#!/usr/bin/env bash
# log-intent.sh — append one Q&A row to $RUN/qa-ledger.tsv, the format owner for
# the one file that bridges the conversation to every fresh-context
# conflict-resolver and to the Phase 6 planner. The orchestrator appends at
# answer time, in whatever phase; readers get the schema SKILL.md documents:
# scope <TAB> question <TAB> answer <TAB> phase, no header, one row per answer.
#
# Content contract: what the USER said — every relayed needs-input answer and
# every intent fact volunteered unprompted. Never agent-discovered component
# facts (log-learning.sh owns those), never task status (the migration log owns
# that), never secrets.
#
# WHY newlines/tabs collapse to single spaces BEFORE the emptiness check: one
# answer must always cost one row, and a tab or newline inside free prose would
# silently corrupt the 4-column schema every resolver parses. Collapsing first
# also means a QUESTION or ANSWER of nothing but whitespace is as empty as an
# unset one — it would append a row carrying no answer.
#
# WHY keyless — no PHASE_KEY guard: the load guards make a phase's ENTRY-POINT
# script refuse to run until the orchestrator has loaded that phase's file. This
# script is appended from many phases and is not any phase's entry point, so a
# guard here would brick answer-time appends. It must not appear in the key
# inventory tests/skill-lint.test.sh audits.
#
# WHY there is NO entry cap (unlike log-learning.sh): the learnings cap is a
# context-budget guard on a file the next executor must be able to skim; the
# ledger is the durable record of what the user actually said, and silently
# refusing to record an answer is the exact failure this script exists to
# prevent. Every answer lands, however many came before it.
#
# In :  RUN       run-state dir (required). Created if missing.
#       QUESTION  the question asked (or "volunteered" context), non-empty.
#       ANSWER    the user's answer or volunteered fact, non-empty.
#       PHASE     phase label the row was recorded in, non-empty.
#       SCOPE     optional path/module the question concerns; empty when the
#                 answer is component-wide.
# Out:  $RUN/qa-ledger.tsv  created on first append (no header — data rows
#                           only), then one appended
#                           `<scope> TAB <question> TAB <answer> TAB <phase>`
#                           row. An exact duplicate of a row already there is
#                           dropped.
# Exit: 0 appended or dropped as a duplicate;
#       non-zero if RUN, QUESTION, ANSWER or PHASE is missing/empty.
set -euo pipefail

RUN="${RUN:?ERROR: RUN dir required}"

# Collapse and trim BEFORE the emptiness check (see header WHY).
collapse() { printf '%s' "$1" | tr '\n\r\t' '   ' | awk '{ $1 = $1; print }'; }
SCOPE=$(collapse "${SCOPE:-}")
QUESTION=$(collapse "${QUESTION:-}")
ANSWER=$(collapse "${ANSWER:-}")
PHASE=$(collapse "${PHASE:-}")
[[ -n "$QUESTION" ]] || { echo "ERROR: QUESTION required (the question asked)" >&2; exit 1; }
[[ -n "$ANSWER" ]] || { echo "ERROR: ANSWER required (what the user said)" >&2; exit 1; }
[[ -n "$PHASE" ]] || { echo "ERROR: PHASE required (the phase the row was recorded in)" >&2; exit 1; }

mkdir -p "$RUN"
ledger="$RUN/qa-ledger.tsv"
row=$(printf '%s\t%s\t%s\t%s' "$SCOPE" "$QUESTION" "$ANSWER" "$PHASE")

# An exact repeat is a no-op, not an error: the same answer relayed twice (a
# re-asked question, a resumed phase) must not double the record.
if [[ -f "$ledger" ]] && LC_ALL=C grep -Fxq -- "$row" "$ledger"; then
  exit 0
fi

printf '%s\n' "$row" >> "$ledger"
