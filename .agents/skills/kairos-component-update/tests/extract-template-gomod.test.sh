#!/usr/bin/env bash
# extract-template-gomod.test.sh — tests for scripts/extract-template-gomod.sh
# TEST_FILTER supported (blocks are independent).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

EGS="$SKILL_DIR/scripts/extract-template-gomod.sh"

# eg_cache <dir> — a bare-ish template repo whose TARGET commit carries a go.mod.
eg_cache() {
  rm -rf "$1"; mkdir -p "$1"; ( cd "$1" && git init -q -b main \
    && printf 'module bitbucket.org/ifs-pd/kairos-component-template\n\ngo 1.26\n\nrequire bitbucket.org/ifs-pd/kairos-component-common/api v1.2.30\n' > go.mod \
    && printf 'x\n' > other.txt && git add -A && git commit -qm target )
}

if t "extract-template-gomod.sh — extracts the TARGET go.mod into \$RUN"; then
# This block PINS the interface:
#   env in : RUN, CACHE (the template mirror), TARGET (the resolved SHA),
#            PHASE_KEY (Phase 3.5's).
#   effect : $RUN/template-go.mod holds the go.mod as of TARGET.
#   WHY a script: this was a prose `git show … > $RUN/template-go.mod` one-liner
#   parsed by TWO scripts (codev-check.sh, wrong-target-check.sh). The artifact-writer
#   lint found it once the check could tell a writer from a reader — both mentions
#   were reads.
EG=$SANDBOX/eg; EGRUN=$SANDBOX/eg-run
eg_cache "$EG"
T=$(git -C "$EG" rev-parse HEAD)
mkdir -p "$EGRUN"

RUN=$EGRUN CACHE=$EG TARGET=$T PHASE_KEY=$PK_COMMON bash "$EGS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "extract-template-gomod: a good extraction exits 0"; else fail "extract-template-gomod: a good extraction exits 0 (rc=$rc)"; fi
expect "extract-template-gomod: \$RUN/template-go.mod is written" test -f "$EGRUN/template-go.mod"
expect "extract-template-gomod: the extracted file is the template's go.mod" \
  grep -q '^module bitbucket.org/ifs-pd/kairos-component-template$' "$EGRUN/template-go.mod"
expect "extract-template-gomod: the require block came with it" \
  grep -q 'kairos-component-common/api v1.2.30' "$EGRUN/template-go.mod"

# The two real consumers must read what this wrote.
COMMON_REPO_PATH=bitbucket.org/ifs-pd/kairos-component-common \
  bash "$SKILL_DIR/scripts/codev-check.sh" "$EGRUN/template-go.mod" > "$SANDBOX/eg-codev.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "extract-template-gomod: codev-check.sh parses the extracted file"; else fail "extract-template-gomod: codev-check.sh parses the extracted file (rc=$rc)"; fi

# Re-running is byte-identical — Continue mode re-enters this phase.
cp "$EGRUN/template-go.mod" "$SANDBOX/eg.snap"
RUN=$EGRUN CACHE=$EG TARGET=$T PHASE_KEY=$PK_COMMON bash "$EGS" >/dev/null 2>&1
expect "extract-template-gomod: a re-run is byte-identical" cmp -s "$SANDBOX/eg.snap" "$EGRUN/template-go.mod"

fi

if t "extract-template-gomod.sh — refuses an extraction that is not a go.mod"; then
# This block PINS the interface — and the fail-open it closes. The prose one-liner
# wrote whatever `git show` produced, INCLUDING nothing: a redirect creates the file
# before the command runs, so a bad ref left a ZERO-BYTE template-go.mod behind. Both
# consumers then read it happily as "no requires, no replaces" — codev-check reports
# no co-development, and wrong-target-check's tripwire, whose entire job is to catch a
# wrong TARGET, reports clear. A wrong ref disarms the check that exists to catch it.
EG=$SANDBOX/eg-bad; EGRUN=$SANDBOX/eg-bad-run
eg_cache "$EG"
mkdir -p "$EGRUN"

RUN=$EGRUN CACHE=$EG TARGET=0000000000000000000000000000000000000000 PHASE_KEY=$PK_COMMON \
  bash "$EGS" >/dev/null 2>"$SANDBOX/eg-bad.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "extract-template-gomod: an unresolvable TARGET is refused non-zero"; else fail "extract-template-gomod: an unresolvable TARGET is refused non-zero (rc=$rc)"; fi
refute "extract-template-gomod: the refusal left NO zero-byte template-go.mod behind" \
  test -e "$EGRUN/template-go.mod"

# A commit that genuinely has no go.mod is refused too, and named as such.
( cd "$EG" && git rm -q go.mod && git commit -qm "drop go.mod" )
T2=$(git -C "$EG" rev-parse HEAD)
RUN=$EGRUN CACHE=$EG TARGET=$T2 PHASE_KEY=$PK_COMMON bash "$EGS" >/dev/null 2>"$SANDBOX/eg-nogomod.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "extract-template-gomod: a TARGET carrying no go.mod is refused"; else fail "extract-template-gomod: a TARGET carrying no go.mod is refused (rc=$rc)"; fi
refute "extract-template-gomod: that refusal wrote nothing either" test -e "$EGRUN/template-go.mod"

# A previous good extraction is not damaged by a later bad one.
EGK=$SANDBOX/eg-keep-run
mkdir -p "$EGK"
RUN=$EGK CACHE=$EG TARGET=$(git -C "$EG" rev-parse HEAD~1) PHASE_KEY=$PK_COMMON bash "$EGS" >/dev/null 2>&1
cp "$EGK/template-go.mod" "$SANDBOX/eg-keep.snap"
RUN=$EGK CACHE=$EG TARGET=$T2 PHASE_KEY=$PK_COMMON bash "$EGS" >/dev/null 2>&1 || true
expect "extract-template-gomod: a failed re-extraction leaves the good file byte-identical" \
  cmp -s "$SANDBOX/eg-keep.snap" "$EGK/template-go.mod"

fi

if t "extract-template-gomod.sh — carries Phase 3.5's key and its required inputs"; then
EG=$SANDBOX/eg-key; EGRUN=$SANDBOX/eg-key-run
eg_cache "$EG"
T=$(git -C "$EG" rev-parse HEAD)
mkdir -p "$EGRUN"

env -u PHASE_KEY RUN=$EGRUN CACHE=$EG TARGET=$T bash "$EGS" >/dev/null 2>"$SANDBOX/eg-nokey.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/3.5-collect-common.md first' "$SANDBOX/eg-nokey.err"; then
  pass "extract-template-gomod: without PHASE_KEY it exits non-zero naming phases/3.5-collect-common.md"
else
  fail "extract-template-gomod: without PHASE_KEY it exits non-zero naming phases/3.5-collect-common.md (rc=$rc)"
fi
refute "extract-template-gomod: the keyless call wrote nothing" test -e "$EGRUN/template-go.mod"
eg_without() { # eg_without <VAR> — run with every input but <VAR>
  local skip="$1" args=() k
  for k in "RUN=$EGRUN" "CACHE=$EG" "TARGET=$T"; do
    [[ "${k%%=*}" = "$skip" ]] || args+=("$k")
  done
  env -u RUN -u CACHE -u TARGET "${args[@]}" PHASE_KEY=$PK_COMMON bash "$EGS"
}
for missing in RUN CACHE TARGET; do
  eg_without "$missing" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "extract-template-gomod: a missing $missing is refused"; else fail "extract-template-gomod: a missing $missing is refused"; fi
done

fi

finish_suite
