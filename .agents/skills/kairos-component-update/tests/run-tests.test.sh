#!/usr/bin/env bash
# run-tests.test.sh — tests for tests/run-tests.sh, the aggregator that turns each
# suite's output into the run's verdict. Finding 10: the runner was the one untested
# component of the test layer, and a regression in its `passed: n/m` parsing, its
# totals balancing, its terminal-line requirement, or its roster-vs-disk check would
# convert every future failure into a false green over the whole suite.
#
# It is tested AS-IS through its CLI: each scenario copies run-tests.sh verbatim except
# for its SUITES=( … ) array, which is rewritten to name fixture suites we place in a
# sandbox tests-dir. run-tests.sh resolves TESTS_DIR from its own location, so a copy
# run out of the sandbox scans and aggregates our fixtures instead of the real roster.
# The skill-lint greps that pin these invariants EXIST in the source are the static
# half; this suite is the behavioral half they defer to ("proven by the reduced-roster
# smoke, not here").
#
# TEST_FILTER supported (blocks are independent; each builds its own sandbox tests-dir).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

RT_SRC="$SKILL_DIR/tests/run-tests.sh"

# make_runner <dest-dir> <suite-name>... — copy run-tests.sh into <dest-dir> with its
# SUITES=( … ) array replaced by the given fixture suite names. Everything else is
# byte-verbatim, so the runner's own logic (roster check, per-suite loop, aggregate) is
# exercised unchanged. `bash <dest-dir>/run-tests.sh` then resolves TESTS_DIR to <dest-dir>.
make_runner() {
  local dir=$1; shift
  awk -v names="$*" '
    /^SUITES=\(/ { print "SUITES=("; n = split(names, a, " "); for (i = 1; i <= n; i++) print "  " a[i]; skip = 1; next }
    skip && /^\)/ { print ")"; skip = 0; next }
    skip { next }
    { print }
  ' "$RT_SRC" > "$dir/run-tests.sh"
}

# mkfix <dir> <name> <exit-code> <output-line>... — write a fixture suite that echoes
# the given lines and exits with the given code. %q keeps leading spaces (the skip grep
# needs them) and any metacharacters literal.
mkfix() {
  local dir=$1 name=$2 code=$3; shift 3
  local l
  : > "$dir/$name"
  for l in "$@"; do printf 'echo %q\n' "$l" >> "$dir/$name"; done
  printf 'exit %s\n' "$code" >> "$dir/$name"
}

# run_runner <dir> — run the sandbox runner; RT_RC holds the exit code, RT_OUT the
# combined stdout+stderr written to <dir>/output.log (not a *.test.sh, so the runner's
# own roster scan never mistakes it for a suite).
run_runner() {
  RT_OUT="$1/output.log"
  bash "$1/run-tests.sh" > "$RT_OUT" 2>&1; RT_RC=$?
}

if t "run-tests.sh — an all-green roster sums the per-suite totals and exits 0"; then
D=$SANDBOX/rt-green; mkdir -p "$D"
mkfix "$D" a.test.sh 0 'ok: one' 'passed: 3/3'
mkfix "$D" b.test.sh 0 'ok: two' 'passed: 5/5'
make_runner "$D" a.test.sh b.test.sh
run_runner "$D"
expect "all-green: exits 0" test "$RT_RC" -eq 0
expect "all-green: the aggregate sums both suites' totals (8/8)" grep -qx 'passed: 8/8' "$RT_OUT"
refute "all-green: no FAIL line anywhere" grep -q 'FAIL:' "$RT_OUT"
expect "all-green: both suites actually ran" grep -qF '===== suite: b.test.sh =====' "$RT_OUT"
fi

if t "run-tests.sh — a red suite fails the aggregate and unbalances the totals"; then
D=$SANDBOX/rt-red; mkdir -p "$D"
mkfix "$D" a.test.sh 0 'ok: one' 'passed: 3/3'
mkfix "$D" f.test.sh 1 'FAIL: broke' 'passed: 2/3'
make_runner "$D" a.test.sh f.test.sh
run_runner "$D"
expect "red suite: exits 1" test "$RT_RC" -eq 1
expect "red suite: the failing suite is named with its exit code" \
  grep -qF 'FAIL: f.test.sh (exit 1)' "$RT_OUT"
expect "red suite: the aggregate carries the real counts (5/6)" grep -qx 'passed: 5/6' "$RT_OUT"
expect "red suite: the balance check reports the shortfall" \
  grep -qi 'totals do not balance' "$RT_OUT"
fi

if t "run-tests.sh — a suite that prints no terminal 'passed: n/m' line is a failure, not zero"; then
D=$SANDBOX/rt-noline; mkdir -p "$D"
mkfix "$D" a.test.sh 0 'ok: one' 'passed: 3/3'
# Exits 0 but never printed a terminal count — a bare `exit 0` skip, a `cd` bail, an
# early return. Summing "nothing" here is how a whole suite's assertions leave silently.
mkfix "$D" n.test.sh 0 'ok: did some work' 'ok: but never reached finish_suite'
make_runner "$D" a.test.sh n.test.sh
run_runner "$D"
expect "no-line: exits 1 despite the suite's own exit 0" test "$RT_RC" -eq 1
expect "no-line: names the suite that printed no terminal count" \
  grep -qF "printed no terminal 'passed: n/m' line" "$RT_OUT"
expect "no-line: only the counted suite reaches the aggregate (3/3)" grep -qx 'passed: 3/3' "$RT_OUT"
fi

if t "run-tests.sh — the balance check catches a suite whose exit status lies about its count"; then
D=$SANDBOX/rt-lie; mkdir -p "$D"
mkfix "$D" a.test.sh 0 'ok: one' 'passed: 3/3'
# Reports 2/3 but exits 0 — the exit status no longer mirrors the count. The totals
# balance is the SECOND, independent path to red for exactly this.
mkfix "$D" l.test.sh 0 'FAIL: swallowed' 'passed: 2/3'
make_runner "$D" a.test.sh l.test.sh
run_runner "$D"
expect "lying suite: exits 1 (via the balance check, not the exit code)" test "$RT_RC" -eq 1
expect "lying suite: the aggregate reports the true counts (5/6)" grep -qx 'passed: 5/6' "$RT_OUT"
expect "lying suite: the balance failure names the shortfall" \
  grep -qi 'totals do not balance' "$RT_OUT"
fi

if t "run-tests.sh — a roster/disk drift stops the run before any suite executes (exit 2)"; then
# On disk but not listed: the new suite never runs, and the aggregate would print n/n over it.
D=$SANDBOX/rt-drift-extra; mkdir -p "$D"
mkfix "$D" a.test.sh 0 'passed: 1/1'
mkfix "$D" b.test.sh 0 'passed: 1/1'
mkfix "$D" z.test.sh 0 'passed: 1/1'    # on disk, deliberately left out of SUITES
make_runner "$D" a.test.sh b.test.sh
run_runner "$D"
expect "drift (disk extra): exits 2" test "$RT_RC" -eq 2
expect "drift (disk extra): names the drift" grep -qF 'SUITES list has drifted' "$RT_OUT"
expect "drift (disk extra): names the unlisted suite under 'NOT in SUITES'" \
  bash -c "grep -A2 'NOT in SUITES' '$RT_OUT' | grep -qF 'z.test.sh'"
refute "drift (disk extra): no suite ran (the check is before the loop)" \
  grep -qF '===== suite:' "$RT_OUT"

# Listed but not on disk: a renamed/deleted suite the list still names.
D=$SANDBOX/rt-drift-ghost; mkdir -p "$D"
mkfix "$D" a.test.sh 0 'passed: 1/1'
make_runner "$D" a.test.sh ghost.test.sh
run_runner "$D"
expect "drift (listed ghost): exits 2" test "$RT_RC" -eq 2
expect "drift (listed ghost): names it under 'NOT on disk'" \
  bash -c "grep -A2 'NOT on disk' '$RT_OUT' | grep -qF 'ghost.test.sh'"

# Listed twice: its assertions would be counted twice.
D=$SANDBOX/rt-drift-dupe; mkdir -p "$D"
mkfix "$D" a.test.sh 0 'passed: 1/1'
mkfix "$D" b.test.sh 0 'passed: 1/1'
make_runner "$D" a.test.sh a.test.sh b.test.sh
run_runner "$D"
expect "drift (dupe): exits 2" test "$RT_RC" -eq 2
expect "drift (dupe): names the duplicate" \
  bash -c "grep -A2 'listed more than once' '$RT_OUT' | grep -qF 'a.test.sh'"
fi

if t "run-tests.sh --list — a doc change selects the doc-asserting suites, not just skill-lint"; then
# T3: *.md used to map to skill-lint alone, but intent-check parses every doc's
# `guard:` examples and in-progress + merge-path grep phase/reference prose, so a
# reword could go red in a suite --affected never ran. --affected keys on the
# repo-root-relative paths `git status` prints, so the fixture nests the skill one
# level down (repo/skill/tests) to reproduce the leading directory the patterns
# match; only SKILL.md is left changed after the commit.
D=$SANDBOX/aff-md; SK=$D/skill; TD=$SK/tests
mkdir -p "$TD"
for s in skill-lint intent-check in-progress merge-path gate; do : > "$TD/$s.test.sh"; done
make_runner "$TD" skill-lint.test.sh intent-check.test.sh in-progress.test.sh merge-path.test.sh gate.test.sh
( cd "$D" && git init -q -b main && git add -A && git commit -qm base ) >/dev/null 2>&1
echo reworded > "$SK/SKILL.md"
bash "$TD/run-tests.sh" --list > "$D/list.out" 2>&1
expect "doc change: --list exits 0 having run no suite" bash -c "! grep -q '===== suite:' '$D/list.out'"
for want in skill-lint.test.sh intent-check.test.sh in-progress.test.sh merge-path.test.sh; do
  expect "doc change: selects $want" grep -qF "  $want" "$D/list.out"
done
refute "doc change: does not drag in an unrelated suite (gate)" grep -qF '  gate.test.sh' "$D/list.out"
fi

if t "run-tests.sh --list — a scripts/lib helper selects its consumers' suites, grep-derived"; then
# T3: the old */scripts/lib/* arm sent every helper to yaml-gate+skill-lint, but
# frontend-substitute.sh is sourced by materialize-frontend, template-parity,
# bellwether-detect and pre-flight. Consumers are derived by grepping scripts/*.sh
# for the helper's basename, so the fixture writes throwaway consumer scripts that
# name it; a script that does not is left out. The fixture deliberately gives its
# pre-flight consumer NO suite of its own, so it still exercises the suite-less ->
# merge-path arm even though the real pre-flight.sh now has tests/pre-flight.test.sh.
D=$SANDBOX/aff-lib; SK=$D/skill; TD=$SK/tests
mkdir -p "$TD" "$SK/scripts/lib"
for s in skill-lint materialize-frontend template-parity bellwether-detect merge-path gate; do : > "$TD/$s.test.sh"; done
for c in materialize-frontend template-parity bellwether-detect pre-flight; do
  printf '. lib/frontend-substitute.sh\n' > "$SK/scripts/$c.sh"   # no pre-flight suite in THIS fixture -> merge-path arm
done
printf 'echo nohelper\n' > "$SK/scripts/gate.sh"                  # names no helper -> not selected
: > "$SK/scripts/lib/frontend-substitute.sh"
make_runner "$TD" skill-lint.test.sh materialize-frontend.test.sh template-parity.test.sh bellwether-detect.test.sh merge-path.test.sh gate.test.sh
( cd "$D" && git init -q -b main && git add -A && git commit -qm base ) >/dev/null 2>&1
echo x >> "$SK/scripts/lib/frontend-substitute.sh"
bash "$TD/run-tests.sh" --list > "$D/list.out" 2>&1
for want in skill-lint.test.sh materialize-frontend.test.sh template-parity.test.sh bellwether-detect.test.sh merge-path.test.sh; do
  expect "lib change: selects consumer suite $want" grep -qF "  $want" "$D/list.out"
done
refute "lib change: a script that never sources the helper is not selected (gate)" \
  grep -qF '  gate.test.sh' "$D/list.out"
fi

if t "lib.sh — bootstrap_suite isolates fixture git repos from the box's global/system config"; then
# T4: without this, a maintainer's ambient core.hooksPath / core.autocrlf reaches
# every throwaway repo the suites build — hooksPath fails the fixtures' own commits
# (suggest-branch.test.sh drops to 21/24) and autocrlf strips the CR the CRLF fixture
# commits on purpose. bootstrap_suite (already run at suite start) pins a controlled
# empty global and drops system config, so a Mac box and a CI container agree.
expect "GIT_CONFIG_NOSYSTEM is exported as 1" test "${GIT_CONFIG_NOSYSTEM:-}" = 1
expect "GIT_CONFIG_GLOBAL points at the controlled sandbox file" \
  test "${GIT_CONFIG_GLOBAL:-}" = "$SANDBOX/gitconfig-global"
expect "that controlled global exists" test -f "$SANDBOX/gitconfig-global"
refute "and it carries none of the box's config (no hooksPath/autocrlf)" \
  grep -Eq 'hooksPath|autocrlf' "$SANDBOX/gitconfig-global"
fi

if t "fake-kairos — accepts the flag-first form its own usage string documents"; then
# m5: create's usage is `create [OPTIONS] COMPONENT_NAME [TARGET_DIRECTORY]`, but the
# shim used to hard-require positionals at $3/$4, so any caller that put a flag first
# exited 2. fake-kairos is on PATH as `kairos` (bootstrap_suite).
FK=$SANDBOX/fk; mkdir -p "$FK/tpl" "$FK/out"
printf 'seed\n' > "$FK/tpl/seed.txt"
KAIROS_SKIP_NAME_VALIDATION=1 kairos component create \
  --no-repository --no-skills --no-tidy --no-frontend --template-path "$FK/tpl" \
  fkcomp "$FK/out" > "$FK/flag-first.out" 2> "$FK/flag-first.err"
expect "flag-first create exits 0" test $? -eq 0
expect "flag-first create materialized the component tree" test -d "$FK/out/fkcomp"
# The historical positionals-first shape (what materialize.sh emits) still works.
rm -rf "$FK/out"; mkdir -p "$FK/out"
KAIROS_SKIP_NAME_VALIDATION=1 kairos component create \
  fkcomp "$FK/out" --no-repository --no-skills --no-tidy --no-frontend --template-path "$FK/tpl" \
  >/dev/null 2>&1
expect "positionals-first create still exits 0" test $? -eq 0
# A stray third positional is still rejected.
refute "a third positional is refused" \
  bash -c "KAIROS_SKIP_NAME_VALIDATION=1 kairos component create a b c \
    --no-repository --no-skills --no-tidy --no-frontend --template-path '$FK/tpl' >/dev/null 2>&1"
fi

if t "run-tests.sh — skipped blocks are counted and surfaced without changing the verdict"; then
D=$SANDBOX/rt-skip; mkdir -p "$D"
mkfix "$D" a.test.sh 0 '  skip: no helm on this box' '  skip: no docker either' 'passed: 3/3'
mkfix "$D" b.test.sh 0 'passed: 2/2'
make_runner "$D" a.test.sh b.test.sh
run_runner "$D"
expect "skips: still exits 0 (a missing tool shrinks the total, not the verdict)" test "$RT_RC" -eq 0
expect "skips: the aggregate summary reports the skip count" \
  grep -qi 'skipped: 2 block' "$RT_OUT"
expect "skips: the summary attributes the skips to the suite" grep -qF 'a.test.sh:2' "$RT_OUT"
fi

finish_suite
