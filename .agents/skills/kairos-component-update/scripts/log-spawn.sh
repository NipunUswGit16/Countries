#!/usr/bin/env bash
# log-spawn.sh — append one dispatch row to $RUN/spawns.tsv.
#
# WHY newlines/tabs collapse to single spaces: one dispatch must always cost one
# 7-column row, and ITEM carries conflict-file paths — a path with a tab in it
# shifts every column after it and silently corrupts spawn-summary.sh's tallies.
# Same collapse() helper, same reason, as log-intent.sh and log-learning.sh.
#
# WHY it also validates MODEL against the pins in $RUN/model.txt: the
# model-selection seam had no enforcement at all. `model.txt` was read by no
# script — only by prose — so "every dispatched subagent names its model
# explicitly, never inherit the session model" was guarded by less than the
# batching rule was. A skipped resolution or a drifted slug surfaced at Phase 8 as
# a missing budget= line, after every dispatch had already run on the wrong model,
# at the wrong cost, for the whole migration. This script is the choke point every
# dispatch already passes through, is already phase-key-guarded, and already owns a
# closed vocabulary (OUTCOME) — so the check goes here.
#
# WHAT THE PLACEMENT DOES AND DOES NOT BUY — state it plainly, because it is a
# real limitation. This is a RECORDER: it is called once the outcome is known
# (phases/5-structural.md) and in Phase 7 AFTER the task commit. So a wrong model
# is caught after that one dispatch has already run, and in Phase 7 after its work
# is committed. The gain is the BOUND, not prevention: a whole migration silently
# run on the session model becomes one item's worth of wrong-model work plus a hard
# stop. Refusing to log is the right lever anyway — the ledger must not record a
# dispatch that violates the pins, and the refusal is what makes the violation
# visible at all. Because work already exists when the check fires, the message
# names the disposition, not just the mismatch.
#
# In :  RUN       run-state dir (required). Created if missing.
#                 $RUN/model.txt must exist: a dispatch with no resolved pins IS
#                 the failure, so its absence is refused fail-closed.
#       PHASE     phase number of the dispatch. Digits only — a value carrying a
#                 tab/newline/space (or otherwise non-digit) is refused (exit 1)
#                 before it can shift a column or slip past the PHASE_KEY guard.
#       PHASE_KEY proof-of-load key, required for the two dispatching phases:
#                 PHASE=5 needs the key stated in phases/5-structural.md,
#                 PHASE=7 the one in phases/7-execution.md.
#       ROLE      role name (e.g. executor, verifier, conflict-resolver).
#       TIER      capability tier requested (strong|coder|executor). For those
#                 three, MODEL must equal that tier's pin in $RUN/model.txt. Any
#                 OTHER value is recorded without a model check, so a future tier
#                 cannot brick the ledger.
#       MODEL     the REQUESTED model slug (lands in column requested_model).
#                 Compared to the pin AFTER collapse(), i.e. the value that lands.
#       ITEM      item key (task id, conflict file, …).
#       OUTCOME   ok|needs-input|fail|escalated|retried.
#       ACTUAL_MODEL  optional; lands in column 7 when set, else empty. Explicitly
#                 NOT validated against the pins — it is the probe's honest report,
#                 and the mismatch it may reveal is the whole reason the one probed
#                 row exists.
# Out:  $RUN/spawns.tsv   header on first write, then one appended data row.
#                 A refused call writes NOTHING — not even the header on the run's
#                 first dispatch, so a rejected dispatch cannot leave a half-file a
#                 later successful call then appends beneath. An EXACT re-append of a
#                 row already present is dropped (a replay is not a second dispatch).
# Exit: 0 on success (row appended, or dropped as an exact duplicate); non-zero if
#       RUN missing/empty, PHASE non-digit, OUTCOME invalid, $RUN/model.txt absent,
#       or MODEL is not the pin for a pinned TIER.
set -euo pipefail

# Validate PHASE FIRST — it lands in column 1 and it gates the proof-of-load case
# below, so a mangled value corrupts both. A PHASE carrying a tab/newline/space
# ("5 ", "7\tx") would shift every later column that spawn-summary.sh tallies AND
# slip past the case (which matches the literal strings 5 and 7), silently
# bypassing the key guard. So a non-digit PHASE is refused outright, BEFORE the
# case and before it can reach the row; collapse() is not enough here (a collapsed
# "5 " would still not equal "5"). Digit values other than 5/7 are not a phase
# entry point today and keep the historical keyless behavior.
PHASE="${PHASE:?ERROR: PHASE required (the phase number of the dispatch)}"
case "$PHASE" in
  *[!0-9]*)
    echo "FAIL: PHASE must be digits only (got: ${PHASE})" >&2
    exit 1
    ;;
esac

# Phase-load guard: dispatches are logged from exactly two phases, and each
# phase's key is stated ONLY in its own file — PHASE=5 in phases/5-structural.md,
# PHASE=7 in phases/7-execution.md. A dispatch logged without the matching key
# means the dispatching phase's file was never loaded. Any other (digit) PHASE
# value is not a phase entry point today and keeps the historical keyless behavior.
case "$PHASE" in
  5) [[ "${PHASE_KEY:-}" = "p2enxd25" ]] \
       || { echo "FAIL: load phases/5-structural.md first" >&2; exit 1; } ;;
  7) [[ "${PHASE_KEY:-}" = "e9tr6bjs" ]] \
       || { echo "FAIL: load phases/7-execution.md first" >&2; exit 1; } ;;
esac

RUN="${RUN:?ERROR: RUN dir required}"

# Collapse tabs/newlines out of every free-form field before it reaches the row
# (see header WHY). OUTCOME is a closed set validated below; PHASE is validated
# digits-only above, so neither can shift the columns.
collapse() { printf '%s' "$1" | tr '\n\r\t' '   ' | awk '{ $1 = $1; print }'; }
ROLE=$(collapse "${ROLE:-}")
TIER=$(collapse "${TIER:-}")
MODEL=$(collapse "${MODEL:-}")
ITEM=$(collapse "${ITEM:-}")
ACTUAL_MODEL=$(collapse "${ACTUAL_MODEL:-}")

OUTCOME="${OUTCOME:-}"
case "$OUTCOME" in
  ok|needs-input|fail|escalated|retried) ;;
  *)
    echo "ERROR: OUTCOME must be ok|needs-input|fail|escalated|retried (got: ${OUTCOME})" >&2
    exit 1
    ;;
esac

# --- the model-pin check -----------------------------------------------------
# Fail CLOSED on a missing model.txt: a dispatch with no resolved pins IS the
# failure. By contract the file always exists by the first dispatch (Continue
# re-derives it; resolve-models.sh's judgment fallback ends in a re-run that
# writes it), so its absence means model resolution was skipped entirely.
pins="$RUN/model.txt"
[[ -f "$pins" ]] || {
  echo "FAIL: no $pins — model resolution never ran, so this dispatch has no pinned model." >&2
  echo "      Remedy: run scripts/resolve-models.sh (SKILL.md -> Model selection), then re-dispatch." >&2
  exit 1
}

# Only the three pinned tiers are checked. An unrecognised TIER is recorded as-is
# so a future tier cannot brick the ledger, and ACTUAL_MODEL is never checked — it
# is the probe's honest report, and the mismatch it may reveal is the whole reason
# the one probed row exists.
case "$TIER" in
  strong|coder|executor)
    # strip a trailing CR so a CRLF-authored model.txt doesn't spuriously fail the
    # equality below (MODEL is already CR-free via collapse()); mirrors the CR strip
    # plan-completeness.sh does on its analogous context.env read.
    pinned=$(sed -n "s/^${TIER}=//p" "$pins" | head -1 | tr -d '\r')
    if [[ -z "$pinned" ]]; then
      # A keyed file missing this tier's line is the legacy shape
      # reference/continue.md degrades gracefully over (pins kept, the missing tier
      # derived fresh). There is nothing to compare against, so record and say so
      # rather than refusing a dispatch the skill's own resume path produced.
      echo "WARNING: $pins has no '${TIER}=' pin — recording this dispatch unchecked." >&2
    elif [[ "$MODEL" != "$pinned" ]]; then
      echo "FAIL: TIER=$TIER is pinned to '$pinned' but this dispatch requested '$MODEL'." >&2
      echo "      Refusing to record it: the ledger must not carry a dispatch that violates the pins." >&2
      echo "      The dispatch ALREADY RAN — this is a recorder, not a pre-flight check. Disposition:" >&2
      echo "        Phase 7 task — git revert (or amend) the task commit, then re-dispatch on '$pinned'." >&2
      echo "        Phase 5 batch — re-dispatch the batch's items on '$pinned'." >&2
      echo "      Either way the row lands only once the dispatch honors the pin. To change the pins," >&2
      echo "      re-run scripts/resolve-models.sh (SKILL.md -> Model selection); do not edit the row." >&2
      exit 1
    fi
    ;;
esac

mkdir -p "$RUN"
spawns="$RUN/spawns.tsv"

row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "$PHASE" \
  "$ROLE" \
  "$TIER" \
  "$MODEL" \
  "$ITEM" \
  "$OUTCOME" \
  "$ACTUAL_MODEL")

# Drop an exact re-append: the ledger records ONE first-attempt row per
# (phase, role, tier, requested_model, item, outcome), so two byte-identical rows
# can only be the same logging block run twice — a compaction/resume replaying
# Phase 7's post-commit logging, or a re-entered Phase 5 batch. An unconditional
# append double-counts the dispatch and Phase 8 then reports `logged N of ~M` with
# N > M. Two genuinely distinct dispatches never collide: a retry lands OUTCOME=
# retried and an escalation OUTCOME=escalated, so their rows differ in column 6.
# Same grep -Fxq dedup, same reason, as log-intent.sh / log-learning.sh /
# log-resolution.sh; guarded on file existence so the first write still lands.
if [[ -f "$spawns" ]] && LC_ALL=C grep -Fxq -- "$row" "$spawns"; then
  exit 0
fi

if [[ ! -f "$spawns" ]]; then
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n' > "$spawns"
fi

printf '%s\n' "$row" >> "$spawns"
