#!/usr/bin/env bash
# scope-check.test.sh — tests for scripts/scope-check.sh
# TEST_FILTER refused (single sequential fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in scope-check.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite
PK_RESOLVE=$(phase_key 2-resolve-target.md)

if t "scope-check.sh (scope tripwire)"; then
SC_TPL=$SANDBOX/scope-tpl
mkdir -p "$SC_TPL" && cd "$SC_TPL" && git init -q -b main
echo v0 > f.txt && git add -A && git commit -qm "c0"
SC_BASE=$(git rev-parse HEAD)
for i in 1 2 3 4 5; do echo "v$i" > f.txt && git commit -qam "c$i"; done
SC_TARGET=$(git rev-parse HEAD)   # 5 commits in BASE..TARGET

# Phase-load guard: refused without the Phase 2 key, even with valid inputs.
CACHE=$SC_TPL BASE=$SC_BASE TARGET=$SC_TARGET THRESHOLD=10 \
  "$SKILL_DIR/scripts/scope-check.sh" > /dev/null 2> "$SANDBOX/sc-nokey.log"
SC_NOKEY_RC=$?
if [[ "$SC_NOKEY_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/2-resolve-target.md first' "$SANDBOX/sc-nokey.log"; then
  pass "without PHASE_KEY is refused: load phases/2-resolve-target.md first"
else
  fail "without PHASE_KEY is refused: load phases/2-resolve-target.md first (rc=$SC_NOKEY_RC)"
fi
CACHE=$SC_TPL BASE=$SC_BASE TARGET=$SC_TARGET THRESHOLD=10 PHASE_KEY=not-the-key \
  "$SKILL_DIR/scripts/scope-check.sh" > /dev/null 2> "$SANDBOX/sc-wrongkey.log"
SC_WRONG_RC=$?
if [[ "$SC_WRONG_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/2-resolve-target.md first' "$SANDBOX/sc-wrongkey.log"; then
  pass "with a wrong PHASE_KEY is refused: load phases/2-resolve-target.md first"
else
  fail "with a wrong PHASE_KEY is refused: load phases/2-resolve-target.md first (rc=$SC_WRONG_RC)"
fi

CACHE=$SC_TPL BASE=$SC_BASE TARGET=$SC_TARGET THRESHOLD=10 PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/scope-check.sh" > "$SANDBOX/sc-under.out" 2>&1
expect "under threshold exits 0" test $? -eq 0
expect "under-threshold reports the real commit count" grep -qx 'COMMITS=5' "$SANDBOX/sc-under.out"
expect "under-threshold verdict says OK" grep -q '^OK:' "$SANDBOX/sc-under.out"
refute "under-threshold does not say ASK" grep -q '^ASK:' "$SANDBOX/sc-under.out"

CACHE=$SC_TPL BASE=$SC_BASE TARGET=$SC_TARGET THRESHOLD=3 PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/scope-check.sh" > "$SANDBOX/sc-over.out" 2>&1
RC=$?
expect "over threshold is advisory only (exits 0)" test "$RC" -eq 0
expect "over-threshold reports the real commit count" grep -qx 'COMMITS=5' "$SANDBOX/sc-over.out"
expect "over-threshold names its own threshold" grep -qx 'THRESHOLD=3' "$SANDBOX/sc-over.out"
expect "over-threshold verdict is advisory, not blocking" grep -q '^ADVISORY:' "$SANDBOX/sc-over.out"
refute "advisory commit-count check does not block with ASK" grep -q '^ASK:' "$SANDBOX/sc-over.out"

CACHE=$SC_TPL BASE=0000000000000000000000000000000000000000 TARGET=$SC_TARGET THRESHOLD=3 PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/scope-check.sh" > "$SANDBOX/sc-bad.out" 2> "$SANDBOX/sc-bad.log"
SC_BAD_RC=$?
if [[ "$SC_BAD_RC" -eq 2 ]]; then pass "unresolvable range exits 2"; else fail "unresolvable range exited $SC_BAD_RC (want 2)"; fi
refute "unresolvable range never reports OK" grep -q '^OK:' "$SANDBOX/sc-bad.out"
expect "unresolvable range names the failure" grep -qi 'unresolvable' "$SANDBOX/sc-bad.log"
expect "unresolvable range keeps COMMITS= on stdout (machine-readable contract)" \
  grep -qx 'COMMITS=unknown' "$SANDBOX/sc-bad.out"
expect "unresolvable range keeps THRESHOLD= on stdout" grep -qx 'THRESHOLD=3' "$SANDBOX/sc-bad.out"

CACHE=$SC_TPL BASE=$SC_BASE TARGET=$SC_TARGET PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/scope-check.sh" > "$SANDBOX/sc-default.out" 2>&1
expect "default threshold (30) exits 0 for a small range" test $? -eq 0
expect "default threshold is named" grep -qx 'THRESHOLD=30' "$SANDBOX/sc-default.out"

CACHE=$SC_TPL BASE=$SC_BASE TARGET=$SC_BASE THRESHOLD=1 PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/scope-check.sh" > "$SANDBOX/sc-zero.out" 2>&1
expect "an empty range (BASE == TARGET) is never a scope problem" test $? -eq 0
expect "empty range reports zero commits" grep -qx 'COMMITS=0' "$SANDBOX/sc-zero.out"

fi

finish_suite
