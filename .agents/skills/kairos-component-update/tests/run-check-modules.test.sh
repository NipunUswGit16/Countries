#!/usr/bin/env bash
# run-check-modules.test.sh — tests for scripts/run-check-modules.sh
# TEST_FILTER refused (blocks share sequential module fixtures).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in run-check-modules.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "run-check-modules.sh sweeps every Go module, not just the root one"; then
# `go build ./...` compiles the module it runs in and nothing else. A component
# can carry sibling go.mod modules (pkg/schema, web/entrypoint); a break the merge
# landed in one of them was invisible to both gates and was found by a manual
# build after the fact.
mod_verdict() { awk -F'\t' -v m="$2" '$1 == m { print $2 }' "$1"; }
mod_is() { # mod_is <modules.tsv> <module> <want-verdict>
  local got; got=$(mod_verdict "$1" "$2")
  if [[ "$got" = "$3" ]]; then pass "module $2 = $3"; else fail "module $2 = ${got:-<none>} (want $3)"; fi
}
mod_absent() { # mod_absent <modules.tsv> <module> <desc>
  if [[ -z "$(mod_verdict "$1" "$2")" ]]; then pass "$3"; else fail "$3 (module was swept)"; fi
}

# The guard below wraps EVERY block in this suite, not just this one: the $MM
# fixture tree is built inside it and all four blocks consume it. A guard that
# closed after the first block left the later blocks dereferencing an unset $MM,
# so on a Go-less box the suite died on `MM: unbound variable` (set -u) before
# finish_suite — no `passed:` line at all, which the aggregator then counted as
# zero assertions. Keep the `else` closed after the LAST block.
if ! command -v go >/dev/null 2>&1; then
  echo "  skip: go not installed — the multi-module sweep is not exercised (this block and the three below)"
else
# Hermetic: no toolchain download, no module fetch. The fixture modules have no
# dependencies, so GOPROXY=off costs nothing and proves it stays offline.
export GOTOOLCHAIN=local GOPROXY=off
MM=$SANDBOX/multimodule
mkdir -p "$MM/pkg/schema" "$MM/web/entrypoint" "$MM/vendor/dep" \
         "$MM/.kairos/migration/state/synthetic" "$MM/node_modules/dep" \
         "$MM/pkg/schema/testdata/fixturemod" "$MM/state"
cd "$MM"
gomod() { printf 'module %s\n\ngo 1.21\n' "$1" > "$2/go.mod"; }
gomod example.com/mm .
printf 'package main\n\nfunc main() {}\n' > main.go
printf 'package main\n\nimport "testing"\n\nfunc TestRootOne(t *testing.T) {}\n' > main_test.go
gomod example.com/mm/pkg/schema pkg/schema
printf 'package schema\n\nvar Ok = 1\n' > pkg/schema/schema.go
# The module that lands in the merge and never gets built: deliberate compile error.
gomod example.com/mm/web/entrypoint web/entrypoint
printf 'package main\n\nfunc main() { undefinedSymbol() }\n' > web/entrypoint/main.go
# None of these are the component's own code and none may be swept.
gomod example.com/vendored vendor/dep
gomod example.com/synthetic .kairos/migration/state/synthetic
gomod example.com/frontend node_modules/dep
# `go build ./...` refuses to match anything under testdata/, so a fixture module
# there is code the component never compiles. Sweeping it would fail a gate on a
# deliberately-broken fixture — hence the compile error, which must stay unseen.
gomod example.com/fixture pkg/schema/testdata/fixturemod
printf 'package main\n\nfunc main() { undefinedFixtureSymbol() }\n' \
  > pkg/schema/testdata/fixturemod/main.go

MM_BUILD=$MM/state/build-final
CHECK=build CMD="go build ./..." OUT=$MM_BUILD "$SKILL_DIR/scripts/run-check-modules.sh" \
  > "$SANDBOX/mm-build.out" 2> "$SANDBOX/mm-build.log"
MM_RC=$?
if [[ "$MM_RC" -ne 0 ]]; then pass "a broken sibling module fails the build gate"; else fail "broken sibling module passed the build gate"; fi
mod_is "$MM_BUILD.modules.tsv" web/entrypoint FAIL
mod_is "$MM_BUILD.modules.tsv" .              OK
mod_is "$MM_BUILD.modules.tsv" pkg/schema     OK
expect "aggregate status is FAIL" grep -qx FAIL "$MM_BUILD.status"
expect "the failure NAMES the module on stderr (relayable as such)" \
  grep -q 'web/entrypoint' "$SANDBOX/mm-build.log"
expect "aggregate excerpt names the module and the compile error" \
  bash -c "grep -q 'web/entrypoint' '$MM_BUILD.excerpt.txt' && grep -q 'undefinedSymbol' '$MM_BUILD.excerpt.txt'"
expect "the module keeps its own excerpt for triage" test -s "$MM_BUILD.web_entrypoint.excerpt.txt"
expect "the module keeps its own compressed log"    test -f "$MM_BUILD.web_entrypoint.txt.gz"
mod_absent "$MM_BUILD.modules.tsv" vendor/dep "vendor/ modules are not swept"
mod_absent "$MM_BUILD.modules.tsv" .kairos/migration/state/synthetic \
  "the migration's own synthetic tree is not swept"
mod_absent "$MM_BUILD.modules.tsv" node_modules/dep "node_modules/ is not swept"
mod_absent "$MM_BUILD.modules.tsv" pkg/schema/testdata/fixturemod \
  "a module under testdata/ is not discovered (go build ./... ignores it too)"

printf 'package main\n\nfunc main() {}\n' > web/entrypoint/main.go   # repair it
MM_OK=$MM/state/build-ok
CHECK=build CMD="go build ./..." OUT=$MM_OK "$SKILL_DIR/scripts/run-check-modules.sh" \
  > "$SANDBOX/mm-ok.out" 2> "$SANDBOX/mm-ok.log"
expect "the repaired tree passes the build gate" test $? -eq 0
expect "every module is reported, not just the failing one" \
  bash -c "test \"\$(grep -c . '$MM_OK.modules.tsv')\" = 3"

if t "the test gate skips modules with no *_test.go instead of banking a vacuous green"; then
MM_EXTRACT="grep -E '^--- FAIL' | awk '{print \$3}'"
MM_SKIP=$MM/state/test-skip
CHECK=test CMD="go test ./..." OUT=$MM_SKIP EXTRACTOR="$MM_EXTRACT" \
  "$SKILL_DIR/scripts/run-check-modules.sh" > "$SANDBOX/mm-skip.out" 2> "$SANDBOX/mm-skip.log"
expect "test sweep exits 0 when the only module carrying tests is green" test $? -eq 0
mod_is "$MM_SKIP.modules.tsv" .              OK
mod_is "$MM_SKIP.modules.tsv" pkg/schema     SKIP
mod_is "$MM_SKIP.modules.tsv" web/entrypoint SKIP
expect "the skip carries a logged reason" \
  bash -c "awk -F'\t' '\$1 == \"pkg/schema\" { print \$3 }' '$MM_SKIP.modules.tsv' | grep -q '_test.go'"
expect "a skipped module ran nothing (no status artifact of its own)" \
  test ! -f "$MM_SKIP.pkg_schema.status"

fi

if t "a per-module test failure names its module without breaking baseline comparability"; then
printf 'package main\n\nimport "testing"\n\nfunc TestRootBroken(t *testing.T) { t.Fatal("boom") }\n' \
  > root_broken_test.go
printf 'package schema\n\nimport "testing"\n\nfunc TestSchemaBroken(t *testing.T) { t.Fatal("boom") }\n' \
  > pkg/schema/schema_test.go
MM_FAIL=$MM/state/test-fail
CHECK=test CMD="go test ./..." OUT=$MM_FAIL EXTRACTOR="$MM_EXTRACT" \
  "$SKILL_DIR/scripts/run-check-modules.sh" > "$SANDBOX/mm-tfail.out" 2> "$SANDBOX/mm-tfail.log"
MM_TRC=$?
if [[ "$MM_TRC" -ne 0 ]]; then pass "a sibling-module test failure fails the test gate"; else fail "sibling-module test failure passed the test gate"; fi
mod_is "$MM_FAIL.modules.tsv" .              FAIL
mod_is "$MM_FAIL.modules.tsv" pkg/schema     FAIL
mod_is "$MM_FAIL.modules.tsv" web/entrypoint SKIP
expect "a non-root failure ID is prefixed with its module" \
  grep -qx 'pkg/schema:TestSchemaBroken' "$MM_FAIL.failures.txt"
expect "a root failure ID stays verbatim (comm -13 against the baseline still holds)" \
  grep -qx 'TestRootBroken' "$MM_FAIL.failures.txt"

fi

if t "non-Go and single-module components are unaffected"; then
touch "$MM/state/build-nongo.modules.tsv"   # stale sweep report from an earlier run
CHECK=build CMD="/bin/echo compiled everything" OUT=$MM/state/build-nongo \
  "$SKILL_DIR/scripts/run-check-modules.sh" > "$SANDBOX/mm-nongo.out" 2> "$SANDBOX/mm-nongo.log"
expect "a non-go command exits 0 (delegated to run-check.sh at the root)" test $? -eq 0
refute "a non-go command is never swept" test -f "$MM/state/build-nongo.modules.tsv"
expect "the delegated run still writes run-check.sh's artifacts" \
  bash -c "test -f '$MM/state/build-nongo.status' && test -f '$MM/state/build-nongo.txt.gz'"

SM=$SANDBOX/singlemodule
mkdir -p "$SM/state" && cd "$SM"
printf 'module example.com/single\n\ngo 1.21\n' > go.mod
printf 'package main\n\nfunc main() {}\n' > main.go
CHECK=build CMD="go build ./..." OUT=$SM/state/build "$SKILL_DIR/scripts/run-check-modules.sh" \
  > "$SANDBOX/sm-build.out" 2> "$SANDBOX/sm-build.log"
expect "a single-module Go component passes the build gate" test $? -eq 0
refute "a single-module Go component is not swept (byte-identical to today)" \
  test -f "$SM/state/build.modules.tsv"

unset GOTOOLCHAIN GOPROXY
cd "$SANDBOX"
fi

if t "run-check-modules.sh CENSUS unions per-module populations with the same <module>: prefixing as failures"; then
# A fresh tree (not the $MM one above, which by now carries broken tests from
# earlier blocks): root carries tests, moda carries tests, modc-helpers' only
# *_test.go holds a helper with zero Test funcs (compiles, runs green, emits no
# per-test event), modd-notests carries no *_test.go at all. `go test -json`
# gives per-test pass/fail/skip events even for a passing suite, which plain
# `go test` does not — the census recipe a real discovery would record.
export GOTOOLCHAIN=local GOPROXY=off
CM=$SANDBOX/censusmodules
mkdir -p "$CM/moda" "$CM/modc-helpers" "$CM/modd-notests"
cd "$CM"
printf 'module example.com/censusroot\n\ngo 1.21\n' > go.mod
printf 'package main\n\nfunc main() {}\n' > main.go
printf 'package main\n\nimport "testing"\n\nfunc TestRootOne(t *testing.T){}\nfunc TestRootTwo(t *testing.T){ t.Skip("later") }\n' \
  > main_test.go
printf 'module example.com/censusroot/moda\n\ngo 1.21\n' > moda/go.mod
printf 'package moda\n\nfunc Ok() int { return 1 }\n' > moda/moda.go
printf 'package moda\n\nimport "testing"\n\nfunc TestAOne(t *testing.T){}\nfunc TestATwo(t *testing.T){ t.Fatal("boom") }\n' \
  > moda/moda_test.go
# helpers-only: a _test.go file exists (so the test gate does not SKIP this
# module) but declares no TestXxx function — `go test` runs it, finds "no tests
# to run", and exits 0 having emitted zero per-test census events.
printf 'module example.com/censusroot/modc-helpers\n\ngo 1.21\n' > modc-helpers/go.mod
printf 'package modc\n\nfunc Ok() int { return 1 }\n' > modc-helpers/modc.go
printf 'package modc\n\nimport "testing"\n\nfunc assertThing(t *testing.T, ok bool) {\n\tif !ok { t.Fatal("nope") }\n}\n' \
  > modc-helpers/modc_test.go
printf 'module example.com/censusroot/modd-notests\n\ngo 1.21\n' > modd-notests/go.mod
printf 'package modd\n\nfunc Ok() int { return 1 }\n' > modd-notests/modd.go

# One census extractor, id<TAB>verdict from `go test -json`'s own event stream —
# the shipped known-good recipe per the PRD. The runner's own top-level filter
# (an id containing '/' is a subtest) does the rest; this recipe does not need to
# know about it.
CENSUS_JSON='grep -E "\"Action\":\"(pass|fail|skip)\"" | grep "\"Test\"" | sed -E "s/.*\"Action\":\"([a-z]+)\".*\"Test\":\"([^\"]+)\".*/\2\t\1/"'
EXTRACTOR_JSON='grep -E "\"Action\":\"fail\"" | grep "\"Test\"" | sed -E "s/.*\"Test\":\"([^\"]+)\".*/\1/"'

CM_BASIC=$CM/out-basic
CHECK=test CMD="go test -json ./..." OUT=$CM_BASIC EXTRACTOR="$EXTRACTOR_JSON" CENSUS="$CENSUS_JSON" \
  "$SKILL_DIR/scripts/run-check-modules.sh" > "$SANDBOX/cm-basic.out" 2> "$SANDBOX/cm-basic.log"
CM_RC=$?
if [[ "$CM_RC" -ne 0 ]]; then pass "moda's genuine failure still fails the test gate"; else fail "moda's failure did not fail the test gate"; fi
mod_is "$CM_BASIC.modules.tsv" moda           FAIL
mod_is "$CM_BASIC.modules.tsv" modd-notests   SKIP
WANT_CM_POP=$(printf 'TestRootOne\nmoda:TestAOne\nmoda:TestATwo\n')
GOT_CM_POP=$(cat "$CM_BASIC.population.txt" 2>/dev/null)
if [[ "$GOT_CM_POP" = "$WANT_CM_POP" ]]; then
  pass "aggregate population.txt: root id verbatim, moda's prefixed 'moda:'"
else
  fail "aggregate population.txt = '$GOT_CM_POP' (want '$WANT_CM_POP')"
fi
expect "aggregate skips.txt carries the root's skip id, verbatim" \
  grep -qx TestRootTwo "$CM_BASIC.skips.txt"
expect "aggregate census.status is OK (a per-module FAIL does not taint it)" \
  grep -qx OK "$CM_BASIC.census.status"

# The no-tests module contributed nothing and did NOT force ABSENT — census.status
# above is OK, not ABSENT, precisely because moda and root DID produce a census.
refute "the skipped module's id never appears in the aggregate population" \
  grep -q '^modd-notests:' "$CM_BASIC.population.txt"

# The helpers-only module ran (it is not SKIP — it carries a _test.go file), and
# its own per-module census.status must be OK on a legitimately empty set, not
# MISMATCH — that is what keeps the aggregate from tipping to MISMATCH.
mod_is "$CM_BASIC.modules.tsv" modc-helpers OK
expect "the helpers-only module's own census is OK (empty is honest, not MISMATCH)" \
  grep -qx OK "$CM_BASIC.modc-helpers.census.status"
refute "the helpers-only module contributes no ids to the aggregate population" \
  grep -q '^modc-helpers:' "$CM_BASIC.population.txt"

fi

if t "run-check-modules.sh CENSUS: a multi-module tree with NO tests anywhere censuses OK-empty, not ABSENT"; then
# Regression (M1): when EVERY module is SKIPped for carrying no *_test.go, the census
# used to write ABSENT, which census-diff reads as "could not census" → a NON-blocking
# INCOMPLETE. So a migration that DELETED every test file across a multi-module tree
# rode through as an aggregate PASS — while the single-root path (`go test ./...` over a
# testless tree, run-check.sh) censuses OK-empty and FAILs the same deletion via its
# mass-disappearance rule. The two must agree: the total-testless multi-module sweep now
# writes OK with an EMPTY population, so census-diff can see the mass disappearance.
export GOTOOLCHAIN=local GOPROXY=off
NT=$SANDBOX/notests-multimodule
mkdir -p "$NT/pkg/schema"
cd "$NT"
printf 'module example.com/notestsroot\n\ngo 1.21\n' > go.mod
printf 'package main\n\nfunc main() {}\n' > main.go        # no *_test.go at root
printf 'module example.com/notestsroot/pkg/schema\n\ngo 1.21\n' > pkg/schema/go.mod
printf 'package schema\n\nfunc Ok() int { return 1 }\n' > pkg/schema/schema.go   # no *_test.go
CENSUS_JSON='grep -E "\"Action\":\"(pass|fail|skip)\"" | grep "\"Test\"" | sed -E "s/.*\"Action\":\"([a-z]+)\".*\"Test\":\"([^\"]+)\".*/\2\t\1/"'
NT_OUT=$NT/out-notests
CHECK=test CMD="go test -json ./..." OUT=$NT_OUT CENSUS="$CENSUS_JSON" \
  "$SKILL_DIR/scripts/run-check-modules.sh" > "$SANDBOX/nt.out" 2>/dev/null
NT_RC=$?
expect "a fully test-free sweep still exits 0 (no failing module)" test "$NT_RC" -eq 0
mod_is "$NT_OUT.modules.tsv" .          SKIP
mod_is "$NT_OUT.modules.tsv" pkg/schema SKIP
expect "aggregate census.status is OK, NOT ABSENT (the total-testless sweep)" \
  grep -qx OK "$NT_OUT.census.status"
expect "the population file exists" test -f "$NT_OUT.population.txt"
refute "and it is empty (a run happened and found no tests)" test -s "$NT_OUT.population.txt"
fi

if t "run-check-modules.sh CENSUS: any module MISMATCH taints the aggregate, deleting population/skips rather than shrinking it"; then
# Same tree as above, PLUS a module whose only failure is one this particular
# census recipe cannot see (a stand-in for "a recipe that mishandles one failure
# shape" — the mechanism, not the exact cause, is what the aggregate must react
# to). Its EXTRACTOR still reports the failure (extractors and census recipes are
# independent commands over the same output), so the module's own subset check
# (failures ⊆ population) fails, and that module reports MISMATCH.
if [[ ! -d "$SANDBOX/censusmodules" ]]; then
  echo "  skip: the preceding CENSUS-union block did not build its fixture tree" >&2
else
export GOTOOLCHAIN=local GOPROXY=off
CM=$SANDBOX/censusmodules
mkdir -p "$CM/modb"
cd "$CM"
printf 'module example.com/censusroot/modb\n\ngo 1.21\n' > modb/go.mod
printf 'package modb\n\nfunc Ok() int { return 1 }\n' > modb/modb.go
printf 'package modb\n\nimport "testing"\n\nfunc TestBOne(t *testing.T){}\nfunc TestGhostBug(t *testing.T){ t.Fatal("boom") }\n' \
  > modb/modb_test.go

CENSUS_JSON='grep -E "\"Action\":\"(pass|fail|skip)\"" | grep "\"Test\"" | sed -E "s/.*\"Action\":\"([a-z]+)\".*\"Test\":\"([^\"]+)\".*/\2\t\1/"'
# Blind to TestGhostBug specifically. The trailing `| cat` keeps the recipe exiting
# 0 on a test-free module (a bare `grep -v` exits 1 when it selects no lines, which is
# now the distinct FAILED case — a broken RECIPE, tested separately), so the
# helpers-only module stays OK-empty and only modb's escaped failure drives the
# MISMATCH under test here.
CENSUS_BLIND="$CENSUS_JSON"' | grep -v Ghost | cat'
EXTRACTOR_JSON='grep -E "\"Action\":\"fail\"" | grep "\"Test\"" | sed -E "s/.*\"Test\":\"([^\"]+)\".*/\1/"'

CM_MM=$CM/out-mismatch
CHECK=test CMD="go test -json ./..." OUT=$CM_MM EXTRACTOR="$EXTRACTOR_JSON" CENSUS="$CENSUS_BLIND" \
  "$SKILL_DIR/scripts/run-check-modules.sh" > "$SANDBOX/cm-mm.out" 2> "$SANDBOX/cm-mm.log"
expect "the sweep still fails on the genuine test failures" test $? -ne 0
expect "modb's own census is MISMATCH (its failure escaped this census recipe)" \
  grep -qx MISMATCH "$CM_MM.modb.census.status"
expect "the aggregate census.status is MISMATCH" grep -qx MISMATCH "$CM_MM.census.status"
refute "a partly-censused sweep never leaves a smaller aggregate population" \
  test -f "$CM_MM.population.txt"
refute "a partly-censused sweep never leaves a smaller aggregate skips set" \
  test -f "$CM_MM.skips.txt"

unset GOTOOLCHAIN GOPROXY
cd "$SANDBOX"
fi
fi

if t "run-check-modules.sh sweeps every module even when the recorded command reads stdin"; then
# The sweep loop reads the module list on its OWN stdin, and run-check.sh eval's
# the recorded command with stdin inherited. So a command whose pipeline reads
# stdin swallowed the remaining module lines: the loop ended after the first
# module, every artifact agreed with every other, and the aggregate reported OK
# "across all modules" having checked one. `cat` stands in for that whole class
# (xargs, a bare `read`, a prompting binary) — it drains whatever fd 0 offers,
# exactly as xargs would, and unlike xargs it behaves the same on BSD and GNU.
# Fresh tree: the $MM one above carries deliberately-broken tests by now, and this
# block needs every module green so a shrunken sweep cannot hide behind red.
export GOTOOLCHAIN=local GOPROXY=off
SD=$SANDBOX/stdinmodules
mkdir -p "$SD/moda" "$SD/modb"
cd "$SD"
printf 'module example.com/stdinroot\n\ngo 1.21\n' > go.mod
printf 'package main\n\nfunc main() {}\n' > main.go
printf 'package main\n\nimport "testing"\n\nfunc TestStdinRoot(t *testing.T){}\n' > main_test.go
printf 'module example.com/stdinroot/moda\n\ngo 1.21\n' > moda/go.mod
printf 'package moda\n\nfunc Ok() int { return 1 }\n' > moda/moda.go
printf 'package moda\n\nimport "testing"\n\nfunc TestModaOne(t *testing.T){}\n' > moda/moda_test.go
printf 'module example.com/stdinroot/modb\n\ngo 1.21\n' > modb/go.mod
printf 'package modb\n\nfunc Ok() int { return 1 }\n' > modb/modb.go
printf 'package modb\n\nimport "testing"\n\nfunc TestModbOne(t *testing.T){}\n' > modb/modb_test.go

SD_BUILD=$SD/out-build
CHECK=build CMD="go build ./... && cat >/dev/null" OUT=$SD_BUILD \
  "$SKILL_DIR/scripts/run-check-modules.sh" > "$SANDBOX/sd-build.out" 2> "$SANDBOX/sd-build.log"
expect "a stdin-reading build command still exits 0" test $? -eq 0
mod_is "$SD_BUILD.modules.tsv" .    OK
mod_is "$SD_BUILD.modules.tsv" moda OK
mod_is "$SD_BUILD.modules.tsv" modb OK
expect "all 3 modules are reported — the command did not eat the module list" \
  bash -c "test \"\$(grep -c . '$SD_BUILD.modules.tsv')\" = 3"
expect "every module left its own status artifact" \
  bash -c "test -f '$SD_BUILD.root.status' && test -f '$SD_BUILD.moda.status' && test -f '$SD_BUILD.modb.status'"
expect "the aggregate log carries one header per module, not one" \
  bash -c "gzip -dc '$SD_BUILD.txt.gz' | grep -c '^=== module ' | grep -qx 3"
expect "the relayed sweep line counts 3 passed, not 1" \
  grep -qE '^  passed: +3$' "$SANDBOX/sd-build.log"
expect "aggregate status is OK" grep -qx OK "$SD_BUILD.status"

# The census is the reader with the worst blast radius: a sweep truncated to the
# root module writes a SMALLER population, which at the next epoch reads as "the
# other modules' tests disappeared" (or hides a real disappearance behind it).
SD_CENSUS='grep -E "\"Action\":\"(pass|fail|skip)\"" | grep "\"Test\"" | sed -E "s/.*\"Action\":\"([a-z]+)\".*\"Test\":\"([^\"]+)\".*/\2\t\1/"'
SD_TEST=$SD/out-test
CHECK=test CMD="go test -json ./... && cat >/dev/null" OUT=$SD_TEST CENSUS="$SD_CENSUS" \
  "$SKILL_DIR/scripts/run-check-modules.sh" > "$SANDBOX/sd-test.out" 2> "$SANDBOX/sd-test.log"
expect "a stdin-reading test command still exits 0" test $? -eq 0
mod_is "$SD_TEST.modules.tsv" .    OK
mod_is "$SD_TEST.modules.tsv" moda OK
mod_is "$SD_TEST.modules.tsv" modb OK
WANT_SD_POP=$(printf 'TestStdinRoot\nmoda:TestModaOne\nmodb:TestModbOne\n')
GOT_SD_POP=$(cat "$SD_TEST.population.txt" 2>/dev/null)
if [[ "$GOT_SD_POP" = "$WANT_SD_POP" ]]; then
  pass "the census population still covers every module's tests"
else
  fail "census population = '$GOT_SD_POP' (want '$WANT_SD_POP') — a stdin-reading command shrank the sweep"
fi
expect "aggregate census.status is OK" grep -qx OK "$SD_TEST.census.status"

unset GOTOOLCHAIN GOPROXY
cd "$SANDBOX"
fi

if t "run-check-modules.sh surfaces a module whose command failed but whose EXTRACTOR matched nothing as EXTRACTOR_MISMATCH, and fails the sweep"; then
# Extractor silence is never green (scripts/gate.sh). A module whose `go test` fails
# to COMPILE exits non-zero but emits no `--- FAIL:` line, so the failure extractor
# matches nothing. At the multi-module layer that must surface as EXTRACTOR_MISMATCH —
# recorded per module in modules.tsv, carried into the aggregate status, counted in
# the relayed sweep line, and FAILING the sweep — never silently banked as OK. Before
# this, EXTRACTOR_MISMATCH had zero coverage at the module layer, and the mutations
# (record OK / drop N_MISMATCH from the report / drop it from the exit condition) all
# stayed green.
export GOTOOLCHAIN=local GOPROXY=off
XM=$SANDBOX/extractormismatch
mkdir -p "$XM/modx"
cd "$XM"
printf 'module example.com/xmroot\n\ngo 1.21\n' > go.mod
printf 'package main\n\nfunc main() {}\n' > main.go
printf 'package main\n\nimport "testing"\n\nfunc TestXmRoot(t *testing.T){}\n' > main_test.go
# modx carries a _test.go that fails to COMPILE: `go test` exits non-zero with a
# build error and no `--- FAIL:` line, so the failure extractor matches nothing.
printf 'module example.com/xmroot/modx\n\ngo 1.21\n' > modx/go.mod
printf 'package modx\n\nfunc Ok() int { return 1 }\n' > modx/modx.go
printf 'package modx\n\nimport "testing"\n\nfunc TestModx(t *testing.T){ undefinedModxSymbol() }\n' \
  > modx/modx_test.go

XM_EXTRACT="grep -E '^--- FAIL' | awk '{print \$3}'"
XM_OUT=$XM/out-test
CHECK=test CMD="go test ./..." OUT=$XM_OUT EXTRACTOR="$XM_EXTRACT" \
  "$SKILL_DIR/scripts/run-check-modules.sh" > "$SANDBOX/xm.out" 2> "$SANDBOX/xm.log"
XM_RC=$?
if [[ "$XM_RC" -ne 0 ]]; then pass "a module whose extractor matched nothing on a failing command fails the sweep (exit condition keeps N_MISMATCH)"; else fail "an EXTRACTOR_MISMATCH module did not fail the sweep (rc=$XM_RC)"; fi
mod_is "$XM_OUT.modules.tsv" modx EXTRACTOR_MISMATCH
mod_is "$XM_OUT.modules.tsv" .    OK
expect "aggregate status is EXTRACTOR_MISMATCH, not OK and not a plain FAIL" \
  grep -qx EXTRACTOR_MISMATCH "$XM_OUT.status"
expect "the relayed sweep line counts one extractor mismatch, not zero" \
  grep -qE '^  extractor mismatches: +1$' "$SANDBOX/xm.log"
expect "the module keeps its own excerpt for triage (the extractor matched nothing → raw tail)" \
  test -s "$XM_OUT.modx.excerpt.txt"

unset GOTOOLCHAIN GOPROXY
cd "$SANDBOX"
fi

fi   # end of the `go on PATH` branch — everything above needs the $MM fixtures

fi

if t "run-check-modules.sh fails closed when the go.mod discovery walk cannot complete"; then
# A listing that FAILED is not an empty listing: an unreadable subdirectory makes
# `find` exit non-zero mid-walk, so the module set is unknown. The pre-fix script
# piped find straight into sed/sort, lost that exit status, and a partial walk
# read as a complete-but-smaller sweep with a clean OK. No `go` needed here — the
# walk runs, and must fail closed, before CMD is ever inspected.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the go.mod discovery walk-failure arm is not exercised: 3 assertions (FAIL status, non-zero exit, diagnostic names the walk failure)"
else
WD=$SANDBOX/walkfail-mod
mkdir -p "$WD/blocked"
printf 'module example.com/wd\n\ngo 1.21\n' > "$WD/go.mod"
chmod 000 "$WD/blocked"
cd "$WD"
WD_OUT=$WD/out
CMD="true" OUT=$WD_OUT "$SKILL_DIR/scripts/run-check-modules.sh" \
  > "$SANDBOX/wd-mod.out" 2> "$SANDBOX/wd-mod.log"
WD_RC=$?
chmod 755 "$WD/blocked"
expect "an incomplete go.mod walk exits non-zero rather than sweeping a shrunken list" \
  test "$WD_RC" -ne 0
expect "status is FAIL, not a shrunken OK" grep -qx FAIL "$WD_OUT.status"
expect "the diagnostic names the walk failure, not a silently smaller module set" \
  grep -qi 'discovery walk failed' "$SANDBOX/wd-mod.log"
cd "$SANDBOX"
fi
fi

if t "run-check-modules.sh fails closed when the *_test.go discovery walk cannot complete"; then
# Same discipline for the CHECK=test walk: the pre-fix script let a failed walk
# here mark every module SKIP "no *_test.go" — a vacuous green, not a refusal.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the *_test.go discovery walk-failure arm is not exercised: 3 assertions (FAIL status, non-zero exit, diagnostic names the walk failure)"
else
WT=$SANDBOX/walkfail-test
mkdir -p "$WT/moda" "$WT/blocked"
printf 'module example.com/wt\n\ngo 1.21\n' > "$WT/go.mod"
printf 'module example.com/wt/moda\n\ngo 1.21\n' > "$WT/moda/go.mod"
chmod 000 "$WT/blocked"
cd "$WT"
WT_OUT=$WT/out
CHECK=test CMD="true" OUT=$WT_OUT "$SKILL_DIR/scripts/run-check-modules.sh" \
  > "$SANDBOX/wt-test.out" 2> "$SANDBOX/wt-test.log"
WT_RC=$?
chmod 755 "$WT/blocked"
expect "an incomplete *_test.go walk exits non-zero rather than vacuously skipping every module" \
  test "$WT_RC" -ne 0
expect "status is FAIL, not a vacuous per-module SKIP" grep -qx FAIL "$WT_OUT.status"
expect "the diagnostic names the walk failure" \
  grep -qi 'discovery walk failed' "$SANDBOX/wt-test.log"
cd "$SANDBOX"
fi
fi

finish_suite
