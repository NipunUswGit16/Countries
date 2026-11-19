#!/usr/bin/env bash
# plan-slice.sh — extracts exactly one task section from PLAN.md, from `### T<id>:`
# up to the next `### T` heading or `## Upgrade-file Dispositions`, whichever
# comes first. Portable on BSD and GNU userland (replaces GNU-only sed addresses).
#
# Env in:  PLAN  path to PLAN.md (required)
#          TASK  task id, e.g. T02 or 02 (required)
# Stdout:  the task section only
# Exit:    0  task found
#          1  task not found
set -u

: "${PLAN:?FAIL: PLAN not set}"
: "${TASK:?FAIL: TASK not set}"

case "$TASK" in
  T*) TASK_ID="$TASK" ;;
  *) TASK_ID="T$TASK" ;;
esac

OUT=$(awk -v id="$TASK_ID" '
  $0 ~ "^### " id ":" { p = 1; print; next }
  p && /^## Upgrade-file Dispositions/ { exit }
  p && /^### T[0-9]+:/ { exit }
  p { print }
' "$PLAN")

if ! printf '%s\n' "$OUT" | grep -q "^### ${TASK_ID}:"; then
  echo "FAIL: task $TASK_ID not found in $PLAN" >&2
  exit 1
fi

printf '%s\n' "$OUT"
