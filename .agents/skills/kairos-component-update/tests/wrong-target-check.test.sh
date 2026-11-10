#!/usr/bin/env bash
# wrong-target-check.test.sh — tests for scripts/wrong-target-check.sh
# TEST_FILTER refused (single sequential fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in wrong-target-check.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

WTC_COMMON=bitbucket.org/ifs-pd/kairos-component-common

# One go.mod per shape, reused across cases.
wtc_gomod_codev() { # wtc_gomod_codev <path>
  cat > "$1" <<EOF
module example.com/tpl

go 1.26

require $WTC_COMMON/toolkit v1.0.0

replace $WTC_COMMON/toolkit => ../local/toolkit
EOF
}
wtc_gomod_plain() { # wtc_gomod_plain <path>
  cat > "$1" <<EOF
module example.com/tpl

go 1.26

require $WTC_COMMON/toolkit v1.0.0
EOF
}

if t "wrong-target-check.sh verdicts (Phase 3.5 tripwire)"; then
WTC=$SANDBOX/wtc
RUN_A=$WTC/state
TPL_A=$WTC/localtpl
mkdir -p "$RUN_A" "$TPL_A"

# (1) not applicable: no TEMPLATE_PATH recorded (no local template was given)
printf 'COMMON_REPO_PATH=%s\n' "$WTC_COMMON" > "$RUN_A/context.env"
wtc_gomod_plain "$RUN_A/template-go.mod"
RUN=$RUN_A "$SKILL_DIR/scripts/wrong-target-check.sh" \
  > "$SANDBOX/wtc-na.out" 2> "$SANDBOX/wtc-na.err"
expect "no TEMPLATE_PATH recorded exits 0 (not applicable)" test $? -eq 0
expect "not-applicable is announced on stderr" grep -q 'not applicable' "$SANDBOX/wtc-na.err"
expect "not-applicable produces no stdout" test ! -s "$SANDBOX/wtc-na.out"

# (2) clear: local template recorded, but its go.mod has no co-dev replaces
printf 'COMMON_REPO_PATH=%s\nTEMPLATE_PATH=%s\n' "$WTC_COMMON" "$TPL_A" > "$RUN_A/context.env"
wtc_gomod_plain "$TPL_A/go.mod"
wtc_gomod_plain "$RUN_A/template-go.mod"
RUN=$RUN_A "$SKILL_DIR/scripts/wrong-target-check.sh" \
  > "$SANDBOX/wtc-clear.out" 2> "$SANDBOX/wtc-clear.err"
expect "working tree without co-dev replaces exits 0 (clear)" test $? -eq 0

# (3) STOP: working tree co-develops common, TARGET does not
wtc_gomod_codev "$TPL_A/go.mod"
wtc_gomod_plain "$RUN_A/template-go.mod"
RUN=$RUN_A "$SKILL_DIR/scripts/wrong-target-check.sh" \
  > "$SANDBOX/wtc-stop.out" 2> "$SANDBOX/wtc-stop.err"
WTC_STOP_RC=$?
expect "co-dev working tree + plain TARGET exits 2 (STOP)" test "$WTC_STOP_RC" -eq 2
expect "the STOP verdict is announced on stderr" grep -q '^STOP:' "$SANDBOX/wtc-stop.err"
expect "the STOP message names the working-tree replace" \
  grep -q 'toolkit => \.\./local/toolkit' "$SANDBOX/wtc-stop.err"
expect "the STOP verdict produces no stdout" test ! -s "$SANDBOX/wtc-stop.out"

# (4) clear: BOTH sides co-develop — the target carries the replaces too
wtc_gomod_codev "$RUN_A/template-go.mod"
RUN=$RUN_A "$SKILL_DIR/scripts/wrong-target-check.sh" \
  > /dev/null 2> "$SANDBOX/wtc-both.err"
expect "co-dev on both sides exits 0 (clear)" test $? -eq 0

# (4b) not applicable: a BARE local template (pre-flight accepts one) has no
# working tree, so there is no working-tree go.mod to compare — exit 0, not a
# permanent exit-3 stop no answer could ever clear. Distinct from the gone-path
# case in the next block, which must stay exit 3.
git init --bare -q "$WTC/baretpl"
printf 'COMMON_REPO_PATH=%s\nTEMPLATE_PATH=%s\n' "$WTC_COMMON" "$WTC/baretpl" > "$RUN_A/context.env"
wtc_gomod_plain "$RUN_A/template-go.mod"
RUN=$RUN_A "$SKILL_DIR/scripts/wrong-target-check.sh" \
  > /dev/null 2> "$SANDBOX/wtc-bare.err"
expect "a bare TEMPLATE_PATH exits 0 (not applicable, not exit 3)" test $? -eq 0
expect "the bare case is announced as not applicable" \
  grep -q 'bare repo.*not applicable' "$SANDBOX/wtc-bare.err"
fi

if t "wrong-target-check.sh — exit 3 is never rounded to 0"; then
WTC=$SANDBOX/wtc
RUN_B=$WTC/state3
TPL_B=$WTC/localtpl3
mkdir -p "$RUN_B" "$TPL_B"

# (5) the compaction case: context.env names a TEMPLATE_PATH that no longer
# exists (moved checkout, resumed on another machine). A local template WAS
# given — this must be "could not determine", NEVER "not applicable".
printf 'COMMON_REPO_PATH=%s\nTEMPLATE_PATH=%s\n' "$WTC_COMMON" "$WTC/ghost" > "$RUN_B/context.env"
wtc_gomod_plain "$RUN_B/template-go.mod"
RUN=$RUN_B "$SKILL_DIR/scripts/wrong-target-check.sh" \
  > "$SANDBOX/wtc-gone.out" 2> "$SANDBOX/wtc-gone.err"
WTC_GONE_RC=$?
expect "a recorded-but-gone TEMPLATE_PATH exits 3" test "$WTC_GONE_RC" -eq 3
expect "a recorded-but-gone TEMPLATE_PATH is NOT exit 0 (not applicable)" \
  test "$WTC_GONE_RC" -ne 0
expect "the lost path is announced as FAIL: naming the recorded value" \
  grep -q "^FAIL:.*$WTC/ghost" "$SANDBOX/wtc-gone.err"
expect "a lost TEMPLATE_PATH produces no stdout" test ! -s "$SANDBOX/wtc-gone.out"

# (6) regression: an unreadable working-tree go.mod must exit 3, not read as
# "no co-dev replaces". The former phase fragment invoked codev-check.sh
# through bare command substitution and discarded its exit 2 — this is the
# defect the script exists to fix.
printf 'COMMON_REPO_PATH=%s\nTEMPLATE_PATH=%s\n' "$WTC_COMMON" "$TPL_B" > "$RUN_B/context.env"
cat > "$TPL_B/go.mod" <<'EOF'
this is not a valid go.mod
replace ( unterminated
EOF
RUN=$RUN_B "$SKILL_DIR/scripts/wrong-target-check.sh" > /dev/null 2>&1
WTC_BAD_RC=$?
expect "a malformed working-tree go.mod exits 3 (codev-check failure is never silence)" \
  test "$WTC_BAD_RC" -eq 3

# (7) a malformed TARGET go.mod is the same failure on the other side
wtc_gomod_codev "$TPL_B/go.mod"
cat > "$RUN_B/template-go.mod" <<'EOF'
this is not a valid go.mod either
EOF
RUN=$RUN_B "$SKILL_DIR/scripts/wrong-target-check.sh" > /dev/null 2>&1
expect "a malformed TARGET go.mod exits 3" test $? -eq 3

# (8) missing $RUN/template-go.mod (not yet extracted) exits 3
rm -f "$RUN_B/template-go.mod"
RUN=$RUN_B "$SKILL_DIR/scripts/wrong-target-check.sh" > /dev/null 2>&1
expect "a missing \$RUN/template-go.mod exits 3" test $? -eq 3

# (9) COMMON_REPO_PATH missing from context.env exits 3 (lost context)
printf 'TEMPLATE_PATH=%s\n' "$TPL_B" > "$RUN_B/context.env"
wtc_gomod_plain "$RUN_B/template-go.mod"
RUN=$RUN_B "$SKILL_DIR/scripts/wrong-target-check.sh" > /dev/null 2>&1
expect "a missing COMMON_REPO_PATH exits 3" test $? -eq 3

# (10) RUN unset and a missing context.env are bad input — still 3, never the
# exit-2 verdict and never 0
"$SKILL_DIR/scripts/wrong-target-check.sh" > /dev/null 2>&1
expect "unset RUN exits 3" test $? -eq 3
RUN=$WTC/no-such-state "$SKILL_DIR/scripts/wrong-target-check.sh" > /dev/null 2>&1
expect "a missing context.env exits 3" test $? -eq 3
fi

if t "pre-flight.sh records TEMPLATE_PATH into \$RUN/context.env"; then
# The tripwire reads TEMPLATE_PATH from context.env, never from conversation
# memory — so the script that learns it (pre-flight) must record it durably.
setup_merge_fixture
cd "$COMP"
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/wtc-pf.out" 2> "$SANDBOX/wtc-pf.log"
expect "pre-flight passes with a local template path" test $? -eq 0
expect "pre-flight records TEMPLATE_PATH into \$RUN/context.env" \
  grep -qx "TEMPLATE_PATH=$TPL" .kairos/migration/state/context.env
expect "the existing CACHE recording is untouched" \
  grep -qx 'CACHE=.kairos/migration/state/template' .kairos/migration/state/context.env
expect "the existing TEMPLATE_LOCAL_BRANCH recording is untouched" \
  grep -qx 'TEMPLATE_LOCAL_BRANCH=main' .kairos/migration/state/context.env

# End-to-end: with the recorded context and a plain TARGET go.mod, the tripwire
# runs off disk alone — no conversation state — and reads clear (the fixture
# template does not co-develop common).
git -C .kairos/migration/state/template show "main:go.mod" > .kairos/migration/state/template-go.mod
printf 'COMMON_REPO_PATH=%s\n' "$WTC_COMMON" >> .kairos/migration/state/context.env
RUN=.kairos/migration/state "$SKILL_DIR/scripts/wrong-target-check.sh" \
  > /dev/null 2> "$SANDBOX/wtc-e2e.err"
expect "the tripwire runs clear from recorded context alone" test $? -eq 0

# A fresh run WITHOUT a local template sweeps the state dir and records no
# TEMPLATE_PATH — the not-applicable case must be reachable again, not a stale
# leftover from the previous run.
MODE=fresh PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > /dev/null 2> "$SANDBOX/wtc-pf2.log"
expect "pre-flight passes without a local template path" test $? -eq 0
refute "a fresh run without --template-path leaves no stale TEMPLATE_PATH" \
  grep -q '^TEMPLATE_PATH=' .kairos/migration/state/context.env
fi

finish_suite
