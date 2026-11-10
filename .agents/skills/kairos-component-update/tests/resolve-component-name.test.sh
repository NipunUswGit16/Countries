#!/usr/bin/env bash
# resolve-component-name.test.sh — tests for scripts/resolve-component-name.sh
# TEST_FILTER supported (blocks are independent; each builds its own tree).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

RCN="$SKILL_DIR/scripts/resolve-component-name.sh"
PK=$PK_RESOLVE

# rcn_tree <dir> <component-name> — a component root carrying pkg/schema/globals.go.
rcn_tree() {
  rm -rf "$1"; mkdir -p "$1/pkg/schema"
  printf 'package schema\n\nconst ComponentName = "%s"\n' "$2" > "$1/pkg/schema/globals.go"
}

if t "resolve-component-name.sh — phase-load guard"; then
rcn_tree "$SANDBOX/rcn-key" todo-demo
( cd "$SANDBOX/rcn-key" && env -u PHASE_KEY bash "$RCN" ) \
  >/dev/null 2> "$SANDBOX/rcn-nokey.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/2-resolve-target.md first' "$SANDBOX/rcn-nokey.err"; then
  pass "without PHASE_KEY is refused: load phases/2-resolve-target.md first"
else
  fail "without PHASE_KEY is refused: load phases/2-resolve-target.md first (rc=$rc)"
fi
( cd "$SANDBOX/rcn-key" && PHASE_KEY=not-the-key bash "$RCN" ) \
  >/dev/null 2> "$SANDBOX/rcn-wrongkey.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/2-resolve-target.md first' "$SANDBOX/rcn-wrongkey.err"; then
  pass "with a wrong PHASE_KEY is refused: load phases/2-resolve-target.md first"
else
  fail "with a wrong PHASE_KEY is refused: load phases/2-resolve-target.md first (rc=$rc)"
fi
fi

if t "resolve-component-name.sh — reads schema.ComponentName, not the directory basename"; then
# The defect this script exists to close: checkout dir kairos-todo-demo, identity
# todo-demo. Stdout is the constant; a WARN names the disagreeing basename.
DIR=$SANDBOX/kairos-todo-demo
rcn_tree "$DIR" todo-demo
GOT=$(cd "$DIR" && PHASE_KEY=$PK bash "$RCN" 2> "$SANDBOX/rcn-ok.err"); rc=$?
if [[ "$rc" -eq 0 ]]; then pass "a readable ComponentName exits 0"; else fail "a readable ComponentName exits 0 (rc=$rc)"; fi
if [[ "$GOT" = "todo-demo" ]]; then
  pass "stdout is schema.ComponentName (todo-demo), not the directory basename"
else
  fail "stdout is schema.ComponentName (got '$GOT', want todo-demo)"
fi
expect "stderr names pkg/schema/globals.go as the source" \
  grep -qF "pkg/schema/globals.go" "$SANDBOX/rcn-ok.err"
expect "stderr WARNs when the directory basename disagrees" \
  grep -qF "directory basename is 'kairos-todo-demo'" "$SANDBOX/rcn-ok.err"
fi

if t "resolve-component-name.sh — refuses a missing, placeholder, or unparseable constant"; then
EMPTY=$SANDBOX/rcn-empty
rm -rf "$EMPTY"; mkdir -p "$EMPTY"
( cd "$EMPTY" && PHASE_KEY=$PK bash "$RCN" ) >/dev/null 2> "$SANDBOX/rcn-missing.err"; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "missing globals.go is exit 2"; else fail "missing globals.go is exit 2 (rc=$rc)"; fi
expect "the missing-file refusal names globals.go and forbids the directory basename" \
  bash -c "grep -qF 'pkg/schema/globals.go' '$SANDBOX/rcn-missing.err' && grep -qi 'directory basename' '$SANDBOX/rcn-missing.err'"

PH=$SANDBOX/rcn-placeholder
rcn_tree "$PH" YOUR_COMPONENT_NAME
( cd "$PH" && PHASE_KEY=$PK bash "$RCN" ) >/dev/null 2> "$SANDBOX/rcn-ph.err"; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "the YOUR_COMPONENT_NAME placeholder is refused"; else fail "the YOUR_COMPONENT_NAME placeholder is refused (rc=$rc)"; fi
expect "the placeholder refusal forbids the directory basename" \
  grep -qi 'directory basename' "$SANDBOX/rcn-ph.err"

BAD=$SANDBOX/rcn-bad
rm -rf "$BAD"; mkdir -p "$BAD/pkg/schema"
printf 'package schema\n\nconst Other = "x"\n' > "$BAD/pkg/schema/globals.go"
( cd "$BAD" && PHASE_KEY=$PK bash "$RCN" ) >/dev/null 2> "$SANDBOX/rcn-bad.err"; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "a globals.go with no ComponentName assignment is refused"; else fail "a globals.go with no ComponentName assignment is refused (rc=$rc)"; fi
fi

finish_suite
