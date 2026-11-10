#!/usr/bin/env bash
# plan-slice.test.sh — tests for scripts/plan-slice.sh
# TEST_FILTER refused (single sequential fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in plan-slice.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "plan-slice.sh extracts exactly one task section (BSD-safe)"; then
PS=$SANDBOX/plan-slice
mkdir -p "$PS"
cat > "$PS/PLAN.md" <<'EOF'
# Migration Plan

## Test Baseline
command: make test

### T01: First task
- **Files**: a.txt
- **Approach**: direct edit

### T02: Second task
- **Files**: b.txt
- **Approach**: TDD
- **Acceptance**: tests pass

### T03: Third task
- **Files**: c.txt
- **Approach**: config change
- **Acceptance**: builds cleanly

## Upgrade-file Dispositions
| Upgrade-file | Disposition | Task / Reason |
|---|---|---|
| `20260101T000000-alpha` | apply | T03 |
EOF
PLAN=$PS/PLAN.md TASK=T02 "$SKILL_DIR/scripts/plan-slice.sh" > "$SANDBOX/ps-t02.out"
expect "plan-slice exits 0 for an existing task" test $? -eq 0
expect "plan-slice includes the requested task heading" grep -qx '### T02: Second task' "$SANDBOX/ps-t02.out"
expect "plan-slice includes task body lines" grep -q 'Approach.*TDD' "$SANDBOX/ps-t02.out"
refute "plan-slice does not include the next task heading" grep -q '### T03:' "$SANDBOX/ps-t02.out"
refute "plan-slice does not run through Upgrade-file Dispositions" \
  grep -q 'Upgrade-file Dispositions' "$SANDBOX/ps-t02.out"
refute "plan-slice does not include an earlier task" grep -q '### T01:' "$SANDBOX/ps-t02.out"

# Regression: GNU-only sed address with \| prints to EOF on BSD — must not happen here.
if sed -n '/^### T02:/,/^### T\|^## Upgrade-file/p' "$PS/PLAN.md" | grep -q 'Upgrade-file Dispositions'; then
  BSD_BROKEN=1
else
  BSD_BROKEN=0
fi
if [[ "$BSD_BROKEN" -eq 1 ]]; then
  pass "this machine's BSD sed reproduces the GNU-only plan-slice bug"
else
  echo "  skip: BSD sed did not reproduce the GNU-only bug on this machine"
fi
if ! grep -q 'Upgrade-file Dispositions' "$SANDBOX/ps-t02.out"; then
  pass "plan-slice.sh stays bounded on BSD userland"
else
  fail "plan-slice.sh ran through Upgrade-file Dispositions"
fi

PLAN=$PS/PLAN.md TASK=T99 "$SKILL_DIR/scripts/plan-slice.sh" > "$SANDBOX/ps-miss.out" 2> "$SANDBOX/ps-miss.log"
if [[ $? -ne 0 ]]; then pass "plan-slice exits non-zero for a missing task"; else fail "plan-slice exited 0 for a missing task"; fi

fi

finish_suite
