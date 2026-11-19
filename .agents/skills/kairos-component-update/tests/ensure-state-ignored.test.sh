#!/usr/bin/env bash
# ensure-state-ignored.test.sh — tests for scripts/ensure-state-ignored.sh
# TEST_FILTER refused (single sequential fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in ensure-state-ignored.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite
PK_BRANCH=$(phase_key 4-migration-branch.md)

if t "ensure-state-ignored.sh (Phase 4 gitignore migration/append)"; then
ESI=$SANDBOX/ensure-state-ignored
run_esi() { rm -rf "$ESI" && mkdir -p "$ESI" && cd "$ESI"; }

# (0) phase-load guard: refused without the Phase 4 key, before touching .gitignore
run_esi
"$SKILL_DIR/scripts/ensure-state-ignored.sh" > /dev/null 2> "$SANDBOX/esi-nokey.log"
ESI_NOKEY_RC=$?
if [[ "$ESI_NOKEY_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/4-migration-branch.md first' "$SANDBOX/esi-nokey.log"; then
  pass "without PHASE_KEY is refused: load phases/4-migration-branch.md first"
else
  fail "without PHASE_KEY is refused: load phases/4-migration-branch.md first (rc=$ESI_NOKEY_RC)"
fi
refute "the refused run wrote no .gitignore" test -f "$ESI/.gitignore"
PHASE_KEY=not-the-key "$SKILL_DIR/scripts/ensure-state-ignored.sh" > /dev/null 2> "$SANDBOX/esi-wrongkey.log"
ESI_WRONG_RC=$?
if [[ "$ESI_WRONG_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/4-migration-branch.md first' "$SANDBOX/esi-wrongkey.log"; then
  pass "with a wrong PHASE_KEY is refused: load phases/4-migration-branch.md first"
else
  fail "with a wrong PHASE_KEY is refused: load phases/4-migration-branch.md first (rc=$ESI_WRONG_RC)"
fi

# (1) missing .gitignore → created with the pattern, reported modified
run_esi
ESI_OUT=$(PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/ensure-state-ignored.sh")
expect "missing .gitignore is created" test -f "$ESI/.gitignore"
expect "created .gitignore carries the state pattern" \
  grep -qxF '.kairos/migration/state/' "$ESI/.gitignore"
expect "creating .gitignore reports modified" test "$ESI_OUT" = modified

# (2) legacy broad ignore is migrated to the state-only pattern
run_esi
printf 'node_modules/\n.kairos/migration/\nbin/\n' > .gitignore
ESI_OUT=$(PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/ensure-state-ignored.sh")
refute "the broad .kairos/migration/ ignore is removed (it would hide PLAN.md)" \
  grep -qxF '.kairos/migration/' "$ESI/.gitignore"
expect "the broad ignore is replaced by the state-only pattern" \
  grep -qxF '.kairos/migration/state/' "$ESI/.gitignore"
expect "migrating the legacy pattern reports modified" test "$ESI_OUT" = modified

# (3) no trailing newline → appended pattern is not glued to the last line
run_esi
printf 'cmd/db-script-runner/Makefile' > .gitignore   # NO trailing newline
PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/ensure-state-ignored.sh" > /dev/null
refute "the pattern is not glued onto the last unterminated line" \
  grep -q 'Makefile.kairos/migration/state/' "$ESI/.gitignore"
expect "the last line survives intact after the guarded append" \
  grep -qxF 'cmd/db-script-runner/Makefile' "$ESI/.gitignore"
expect "the state pattern lands on its own line" \
  grep -qxF '.kairos/migration/state/' "$ESI/.gitignore"

# (4) already present → no duplicate, reported unchanged
run_esi
printf 'node_modules/\n.kairos/migration/state/\n' > .gitignore
ESI_OUT=$(PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/ensure-state-ignored.sh")
expect "an already-present pattern reports unchanged" test "$ESI_OUT" = unchanged
expect "no duplicate state pattern is appended" \
  test "$(grep -cxF '.kairos/migration/state/' "$ESI/.gitignore")" = 1

# (5) present without a trailing slash also counts as ignored (no re-append)
run_esi
printf '.kairos/migration/state\n' > .gitignore
ESI_OUT=$(PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/ensure-state-ignored.sh")
expect "the slashless form is recognized as already ignored" test "$ESI_OUT" = unchanged

# (6) idempotent: a second run on an already-migrated file is unchanged
run_esi
printf '.kairos/migration/\n' > .gitignore
PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/ensure-state-ignored.sh" > /dev/null   # migrates
ESI_OUT=$(PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/ensure-state-ignored.sh")    # second run
expect "a second run after migration is unchanged (idempotent)" test "$ESI_OUT" = unchanged

# (7) present in the leading-slash form (`/.kairos/migration/state/`, which
# anchors to the repo root exactly like the slashless form here) is recognized
# as already ignored: no duplicate append, and no false "modified" report.
# Regression.
run_esi
printf '/.kairos/migration/state/\n' > .gitignore
ESI_OUT=$(PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/ensure-state-ignored.sh")
expect "a leading-slash existing entry is recognized as already ignored" test "$ESI_OUT" = unchanged
expect "no duplicate (slashless) state pattern is appended alongside the leading-slash form" \
  test "$(grep -c 'kairos/migration/state' "$ESI/.gitignore")" = 1
expect "the original leading-slash line is left untouched" \
  grep -qxF '/.kairos/migration/state/' "$ESI/.gitignore"

# (8) same, but the leading-slash form has no trailing slash either.
run_esi
printf '/.kairos/migration/state\n' > .gitignore
ESI_OUT=$(PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/ensure-state-ignored.sh")
expect "a leading-slash, slashless-suffix entry is recognized as already ignored" test "$ESI_OUT" = unchanged
expect "no duplicate is appended alongside the leading-slash slashless form" \
  test "$(grep -c 'kairos/migration/state' "$ESI/.gitignore")" = 1

# (9) a read-only .gitignore cannot be appended to — the script must fail
# loudly (non-zero, no "modified" claim) instead of reporting success on a
# write that never happened. Regression for the unconditional CHANGED=1.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 444 stays writable) — the read-only-.gitignore refusal arm is not exercised: 4 assertions (non-zero exit, no modified claim, FAIL diagnostic, pattern not appended)"
else
  run_esi
  printf 'node_modules/\n' > .gitignore
  chmod 444 .gitignore
  ESI_RO_OUT=$(PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/ensure-state-ignored.sh" 2> "$SANDBOX/esi-readonly.log")
  ESI_RO_RC=$?
  chmod 644 .gitignore   # restore so cleanup/next run_esi's rm -rf isn't fighting perms
  if [[ "$ESI_RO_RC" -ne 0 ]]; then pass "a read-only .gitignore is refused (non-zero exit)"; else fail "a read-only .gitignore was refused (rc=$ESI_RO_RC, want non-zero)"; fi
  refute "a refused write never claims modified" test "$ESI_RO_OUT" = modified
  expect "a refused write reports a FAIL diagnostic" grep -qF 'FAIL:' "$SANDBOX/esi-readonly.log"
  refute "the read-only .gitignore is left without the state pattern" \
    grep -qxF '.kairos/migration/state/' "$ESI/.gitignore"
fi
fi

finish_suite
