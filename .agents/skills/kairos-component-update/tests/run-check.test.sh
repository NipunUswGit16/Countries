#!/usr/bin/env bash
# run-check.test.sh — tests for scripts/run-check.sh
# TEST_FILTER refused (single sequential fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in run-check.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "run-check.sh writes compressed raw logs paired with a plain failures file"; then
# The raw test/build log must not be the convenient read — a naive `cat` should
# get nothing plain-text — while the normalized failure set (or, for a build
# command with no EXTRACTOR, nothing extra at all) stays the documented, cheap,
# plain-text artifact.
RC=$SANDBOX/run-check
mkdir -p "$RC"

cat > "$RC/fake-build.sh" <<'EOF'
#!/usr/bin/env bash
echo "compiling package foo"
echo "compiling package bar"
exit 1
EOF
chmod +x "$RC/fake-build.sh"

CMD="$RC/fake-build.sh" OUT="$RC/build-postmerge" "$SKILL_DIR/scripts/run-check.sh"
BUILD_RC=$?
expect "run-check.sh (build, no EXTRACTOR) propagates the command's exit code" \
  test "$BUILD_RC" -eq 1
expect "raw build log written gzip-compressed" test -f "$RC/build-postmerge.txt.gz"
refute "no plain-text raw build log written alongside it" test -f "$RC/build-postmerge.txt"
expect "gzip-compressed build log decompresses to the real output" \
  bash -c "gzip -dc '$RC/build-postmerge.txt.gz' | grep -q 'compiling package foo'"
refute "no failures file for a build command (no EXTRACTOR given)" \
  test -f "$RC/build-postmerge.failures.txt"

cat > "$RC/fake-test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS pkg/foo::TestOne"
echo "FAIL pkg/foo::TestTwo"
echo "FAIL pkg/bar::TestThree"
exit 1
EOF
chmod +x "$RC/fake-test.sh"

CMD="$RC/fake-test.sh" OUT="$RC/test-baseline" EXTRACTOR="grep -E '^FAIL' | awk '{print \$2}'" \
  "$SKILL_DIR/scripts/run-check.sh"
TEST_RC=$?
expect "run-check.sh (test, with EXTRACTOR) propagates the command's exit code" \
  test "$TEST_RC" -eq 1
expect "raw test log written gzip-compressed" test -f "$RC/test-baseline.txt.gz"
refute "no plain-text raw test log written alongside it" test -f "$RC/test-baseline.txt"
expect "gzip-compressed test log decompresses to the real output" \
  bash -c "gzip -dc '$RC/test-baseline.txt.gz' | grep -q 'TestOne'"
WANT_FAILURES=$(printf 'pkg/bar::TestThree\npkg/foo::TestTwo\n')
GOT_FAILURES=$(cat "$RC/test-baseline.failures.txt" 2>/dev/null)
if [[ "$GOT_FAILURES" = "$WANT_FAILURES" ]]; then
  pass "test-baseline.failures.txt is the sorted, normalized, plain-text failure set"
else
  fail "test-baseline.failures.txt = '$GOT_FAILURES' (want '$WANT_FAILURES')"
fi

cat > "$RC/fake-test-green.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS pkg/foo::TestOne"
echo "PASS pkg/bar::TestTwo"
exit 0
EOF
chmod +x "$RC/fake-test-green.sh"
CMD="$RC/fake-test-green.sh" OUT="$RC/test-green" EXTRACTOR="grep -E '^FAIL' | awk '{print \$2}'" \
  "$SKILL_DIR/scripts/run-check.sh"
GREEN_RC=$?
expect "run-check.sh (green suite) exits 0" test "$GREEN_RC" -eq 0
expect "green suite status is OK" grep -qx OK "$RC/test-green.status"
expect "green suite has an empty failure set file" test -f "$RC/test-green.failures.txt"
expect "green suite failure set is empty" test ! -s "$RC/test-green.failures.txt"
refute "green suite does not write an excerpt" test -f "$RC/test-green.excerpt.txt"

cat > "$RC/fake-test-mismatch.sh" <<'EOF'
#!/usr/bin/env bash
echo "panic: something exploded"
echo "no test lines here"
exit 1
EOF
chmod +x "$RC/fake-test-mismatch.sh"
CMD="$RC/fake-test-mismatch.sh" OUT="$RC/test-mismatch" EXTRACTOR="grep -E '^FAIL' | awk '{print \$2}'" \
  "$SKILL_DIR/scripts/run-check.sh" > "$SANDBOX/rc-mm.out" 2> "$SANDBOX/rc-mm.log"
MM_RC=$?
expect "run-check.sh (extractor mismatch) propagates the command exit code" test "$MM_RC" -eq 1
expect "extractor mismatch status is EXTRACTOR_MISMATCH" \
  grep -qx EXTRACTOR_MISMATCH "$RC/test-mismatch.status"
expect "extractor mismatch failure set is empty" test ! -s "$RC/test-mismatch.failures.txt"
expect "extractor mismatch names the problem on stderr" \
  grep -qi 'EXTRACTOR_MISMATCH' "$SANDBOX/rc-mm.log"
expect "extractor mismatch writes a bounded excerpt" test -s "$RC/test-mismatch.excerpt.txt"
expect "build failure writes a status artifact" grep -qx FAIL "$RC/build-postmerge.status"
expect "build failure writes a bounded excerpt" test -s "$RC/build-postmerge.excerpt.txt"

fi

if t "run-check.sh creates OUT's parent directory when it does not yet exist"; then
# A caller building OUT from a run id the current invocation just minted (e.g.
# "$RUN/checks/$TASK_ID/build") has no reason to have mkdir'd that directory
# first — run-check.sh owns every "$OUT.*" artifact, so it must create the
# parent itself rather than fail the redirection and silently drop every
# artifact while still exiting with the wrapped command's own (successful) code.
NESTED="$SANDBOX/run-check-nested/does/not/exist/yet"
refute "the nested OUT directory does not exist yet (precondition)" \
  test -d "$(dirname "$NESTED")"
CMD="true" OUT="$NESTED/out" "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2> "$SANDBOX/rc-nested.log"
NESTED_RC=$?
expect "a successful command under a missing OUT dir still exits 0" test "$NESTED_RC" -eq 0
expect "the missing OUT parent directory was created" test -d "$(dirname "$NESTED")"
expect "the compressed log landed in the newly created directory" test -f "$NESTED/out.txt.gz"
expect "the status artifact landed in the newly created directory" grep -qx OK "$NESTED/out.status"
fi

if t "run-check.sh writes its artifacts even when CMD exits the shell itself"; then
# A recorded command can carry a top-level `exit N` — a discovered `make`
# one-liner, a shell snippet pasted into test-command.txt. `eval` runs it in THIS
# shell, so that exit terminated run-check.sh mid-flight: the exit code still
# propagated (the caller saw a plain failure) but not one artifact was written —
# no .status, no .txt.gz, no excerpt. Every downstream reader then had to
# interpret a missing artifact set, and producer-idempotence.sh's skip reason came
# out of an empty log. The command is run in a SUBSHELL now, so its exit ends the
# command, never the wrapper.
EX=$SANDBOX/run-check-exit
mkdir -p "$EX"
CMD='echo hi; exit 3' OUT="$EX/check" "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2> "$SANDBOX/rc-exit.log"
EXIT_RC=$?
expect "a CMD with a top-level exit propagates its own exit code" test "$EXIT_RC" -eq 3
expect "a self-exiting CMD still gets its compressed log" test -f "$EX/check.txt.gz"
expect "the compressed log holds the output produced before the exit" \
  bash -c "gzip -dc '$EX/check.txt.gz' | grep -qx hi"
expect "a self-exiting CMD still gets its status artifact" grep -qx FAIL "$EX/check.status"
expect "a self-exiting CMD still gets its excerpt" test -s "$EX/check.excerpt.txt"

# The same, with an EXTRACTOR: the failure set is an artifact too.
CMD='echo "FAIL pkg/foo::TestOne"; exit 3' OUT="$EX/check-x" \
  EXTRACTOR="grep -E '^FAIL' | awk '{print \$2}'" \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
EXITX_RC=$?
expect "a self-exiting CMD with an EXTRACTOR propagates its exit code" test "$EXITX_RC" -eq 3
expect "a self-exiting CMD still gets its failure set" \
  grep -qx 'pkg/foo::TestOne' "$EX/check-x.failures.txt"
expect "a self-exiting CMD's status reflects its failure" grep -qx FAIL "$EX/check-x.status"

# A successful command that exits explicitly is a pass, not a FAIL.
CMD='echo done; exit 0' OUT="$EX/check-ok" "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
EXIT0_RC=$?
expect "a CMD exiting 0 explicitly still exits 0" test "$EXIT0_RC" -eq 0
expect "a CMD exiting 0 explicitly is recorded OK" grep -qx OK "$EX/check-ok.status"
refute "a CMD exiting 0 explicitly writes no excerpt" test -f "$EX/check-ok.excerpt.txt"
fi

if t "run-check.sh CENSUS unset is byte-identical to a pre-census run (the rider is invisible)"; then
# CENSUS is a rider on the runner, not a fork of it. Prove invisibility rather
# than assume it: run the SAME CMD+EXTRACTOR twice, once with CENSUS unset and
# once with it set, and diff every non-census artifact between the two runs.
# Stale census artifacts from an earlier run at this OUT stem must also be
# cleared when CENSUS is unset — a caller that flips CENSUS off between runs
# must never have last run's population read as this run's.
RC=$SANDBOX/run-check-census
mkdir -p "$RC"

cat > "$RC/fake-test-census.sh" <<'EOF'
#!/usr/bin/env bash
echo "RESULT TestA pass"
echo "RESULT TestB pass"
echo "RESULT TestC fail"
echo "RESULT TestD skip"
exit 1
EOF
chmod +x "$RC/fake-test-census.sh"

CENSUS_EXTRACTOR='grep "^RESULT " | awk "{print \$2\"\t\"\$3}"'

touch "$RC/test-census-unset.population.txt" "$RC/test-census-unset.skips.txt"
echo OK > "$RC/test-census-unset.census.status"
CMD="$RC/fake-test-census.sh" OUT="$RC/test-census-unset" \
  EXTRACTOR="grep -E ' fail\$' | awk '{print \$2}'" \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
UNSET_RC=$?
expect "CENSUS unset still propagates CMD's own exit code" test "$UNSET_RC" -eq 1
refute "CENSUS unset clears a stale population.txt from an earlier run" \
  test -f "$RC/test-census-unset.population.txt"
refute "CENSUS unset clears a stale skips.txt from an earlier run" \
  test -f "$RC/test-census-unset.skips.txt"
refute "CENSUS unset clears a stale census.status from an earlier run" \
  test -f "$RC/test-census-unset.census.status"

CMD="$RC/fake-test-census.sh" OUT="$RC/test-census-set" \
  EXTRACTOR="grep -E ' fail\$' | awk '{print \$2}'" CENSUS="$CENSUS_EXTRACTOR" \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
SET_RC=$?
expect "CENSUS set propagates the same CMD exit code as CENSUS unset" test "$SET_RC" -eq "$UNSET_RC"
expect "the raw log content is identical whether or not CENSUS ran" \
  bash -c "diff <(gzip -dc '$RC/test-census-unset.txt.gz') <(gzip -dc '$RC/test-census-set.txt.gz')"
expect "the .status artifact is byte-identical whether or not CENSUS ran" \
  diff "$RC/test-census-unset.status" "$RC/test-census-set.status"
expect "the .failures.txt artifact is byte-identical whether or not CENSUS ran" \
  diff "$RC/test-census-unset.failures.txt" "$RC/test-census-set.failures.txt"

fi

if t "run-check.sh CENSUS: population/skips/status on green and failing runs"; then
# A census recipe emits "id<TAB>pass|fail|skip" over the SAME captured output as
# EXTRACTOR. The runner splits it into population (pass+fail) and skips, both
# top-level only, and cross-checks the failure set against the population.
CC=$SANDBOX/run-check-census-cases
mkdir -p "$CC"
CENSUS_EXTRACTOR='grep "^RESULT " | awk "{print \$2\"\t\"\$3}"'

cat > "$CC/fake-green.sh" <<'EOF'
#!/usr/bin/env bash
echo "RESULT TestA pass"
echo "RESULT TestB pass"
echo "RESULT TestC skip"
exit 0
EOF
chmod +x "$CC/fake-green.sh"
CMD="$CC/fake-green.sh" OUT="$CC/test-green" CENSUS="$CENSUS_EXTRACTOR" \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
GREEN_RC=$?
expect "a green census run exits 0" test "$GREEN_RC" -eq 0
WANT_POP=$(printf 'TestA\nTestB\n')
GOT_POP=$(cat "$CC/test-green.population.txt" 2>/dev/null)
if [[ "$GOT_POP" = "$WANT_POP" ]]; then
  pass "green run population.txt carries the pass ids, sorted"
else
  fail "green run population.txt = '$GOT_POP' (want '$WANT_POP')"
fi
expect "green run skips.txt carries the skip id" grep -qx TestC "$CC/test-green.skips.txt"
expect "green run census.status is OK" grep -qx OK "$CC/test-green.census.status"

# A census extractor emitting subtest ids (containing '/') — those are data, and
# the top-level filter is the RUNNER's, not the recipe's good manners.
cat > "$CC/fake-subtest.sh" <<'EOF'
#!/usr/bin/env bash
echo "RESULT TestA pass"
echo "RESULT TestA/sub1 pass"
echo "RESULT TestA/sub2 fail"
echo "RESULT TestB pass"
exit 0
EOF
chmod +x "$CC/fake-subtest.sh"
CMD="$CC/fake-subtest.sh" OUT="$CC/test-subtest" CENSUS="$CENSUS_EXTRACTOR" \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
WANT_SUB=$(printf 'TestA\nTestB\n')
GOT_SUB=$(cat "$CC/test-subtest.population.txt" 2>/dev/null)
if [[ "$GOT_SUB" = "$WANT_SUB" ]]; then
  pass "subtest ids (containing '/') are excluded from population.txt"
else
  fail "population.txt = '$GOT_SUB' (want '$WANT_SUB' — subtests must be excluded)"
fi
refute "the excluded subtest id never appears in population.txt" \
  grep -qx 'TestA/sub1' "$CC/test-subtest.population.txt"

# A failing run whose failure set is NOT a subset of the population: the census
# and the extractor describe different runs, so population/skips are deleted and
# the MAIN status stays exactly what CMD's exit code already said.
cat > "$CC/fake-mismatch.sh" <<'EOF'
#!/usr/bin/env bash
echo "RESULT TestA pass"
echo "RESULT TestB pass"
echo "FAIL pkg::Ghost"
exit 1
EOF
chmod +x "$CC/fake-mismatch.sh"
CMD="$CC/fake-mismatch.sh" OUT="$CC/test-mismatch" \
  EXTRACTOR="grep -E '^FAIL' | awk '{print \$2}'" CENSUS="$CENSUS_EXTRACTOR" \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
MM_RC=$?
expect "a census MISMATCH still propagates CMD's own exit code" test "$MM_RC" -eq 1
expect "census MISMATCH is recorded" grep -qx MISMATCH "$CC/test-mismatch.census.status"
expect "the MAIN status is untouched — still FAIL from CMD's exit" \
  grep -qx FAIL "$CC/test-mismatch.status"
refute "census MISMATCH deletes population.txt" test -f "$CC/test-mismatch.population.txt"
refute "census MISMATCH deletes skips.txt" test -f "$CC/test-mismatch.skips.txt"

# Red-on-red with a failing SUBTEST is NOT a MISMATCH. A JSON failure extractor
# emits a failing subtest (TestFoo/case1) alongside its failing parent (TestFoo),
# but the population is top-level only — so the subset check must project the
# failure set to top-level too, or a single kept-red subtest would false-MISMATCH
# the census and delete it exactly where there is red for a disappearance to hide
# behind. The parent, which IS top-level and verdict-bearing, is in the population;
# that is what the check validates.
cat > "$CC/fake-subtest-fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "RESULT TestA pass"
echo "RESULT TestFoo fail"
echo "RESULT TestFoo/case1 fail"
echo "FAILID TestFoo"
echo "FAILID TestFoo/case1"
exit 1
EOF
chmod +x "$CC/fake-subtest-fail.sh"
CMD="$CC/fake-subtest-fail.sh" OUT="$CC/test-subfail" \
  EXTRACTOR="grep '^FAILID ' | awk '{print \$2}'" CENSUS="$CENSUS_EXTRACTOR" \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
expect "a failing subtest in the failure set does NOT MISMATCH the census (top-level projection)" \
  grep -qx OK "$CC/test-subfail.census.status"
expect "the population survives a red-on-red subtest run" test -s "$CC/test-subfail.population.txt"
expect "the top-level parent of the failing subtest is in the population" \
  grep -qx TestFoo "$CC/test-subfail.population.txt"
refute "the failing subtest id itself is not in the population" \
  grep -qx 'TestFoo/case1' "$CC/test-subfail.population.txt"

# An OK run whose census output is legitimately empty (a helpers-only module runs
# green and emits no per-test event) — honest at the runner: OK with an empty
# population.txt that still EXISTS (emptiness is judged elsewhere, per the PRD).
cat > "$CC/fake-empty.sh" <<'EOF'
#!/usr/bin/env bash
echo "no per-test events here"
exit 0
EOF
chmod +x "$CC/fake-empty.sh"
CMD="$CC/fake-empty.sh" OUT="$CC/test-empty" CENSUS="$CENSUS_EXTRACTOR" \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
expect "an OK run with an empty census still exits 0" test $? -eq 0
expect "an OK run with an empty census still writes population.txt" \
  test -f "$CC/test-empty.population.txt"
expect "that population.txt is empty" test ! -s "$CC/test-empty.population.txt"
expect "an OK run with an empty census reports census.status OK, not MISMATCH" \
  grep -qx OK "$CC/test-empty.census.status"

# A census extractor that itself exits non-zero: its own exit code never reaches
# the runner's — main artifacts and the runner's exit code are still CMD's. But it
# MUST reach census.status: a recipe that errored cannot be trusted, so it is FAILED
# with its population discarded, never OK over that output (which downstream would
# read as a real epoch).
cat > "$CC/fake-basic.sh" <<'EOF'
#!/usr/bin/env bash
echo "RESULT TestA pass"
exit 0
EOF
chmod +x "$CC/fake-basic.sh"
CMD="$CC/fake-basic.sh" OUT="$CC/test-census-exits" \
  CENSUS='grep "^RESULT " | awk "{print \$2\"\t\"\$3}"; exit 5' \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
expect "a self-exiting CENSUS never changes the runner's own exit code" test $? -eq 0
expect "a self-exiting CENSUS leaves the main status as CMD's" \
  grep -qx OK "$CC/test-census-exits.status"
expect "a CENSUS recipe that exits non-zero is recorded FAILED, not OK over its output" \
  grep -qx FAILED "$CC/test-census-exits.census.status"
refute "a FAILED census recipe leaves no population to be read as this run's" \
  test -f "$CC/test-census-exits.population.txt"

fi

if t "run-check.sh CENSUS: a recipe that errors outright is FAILED over an empty population, never a silent OK"; then
# The exact C1 failure: a model-authored recipe that is broken from the start (the
# tool it names is absent, or a flag is wrong) exits non-zero and emits NO rows. An
# un-captured status wrote OK over an EMPTY population.txt — indistinguishable from a
# suite that legitimately censused nothing — and since a broken-from-the-start recipe
# is broken at EVERY epoch, census-diff's empty↔empty arm certified PASS: the layer
# built to catch MISSING GREEN reporting clean on a component whose census never ran.
# The recipe's own exit status is captured now; a failure is a loud, distinct FAILED.
CF=$SANDBOX/run-check-census-failed
mkdir -p "$CF"
cat > "$CF/fake-green.sh" <<'EOF'
#!/usr/bin/env bash
echo "RESULT TestA pass"
echo "RESULT TestB pass"
exit 0
EOF
chmod +x "$CF/fake-green.sh"
# The recipe names a command that does not exist: it exits 127 having matched nothing.
CMD="$CF/fake-green.sh" OUT="$CF/test-final" \
  CENSUS='this_census_tool_does_not_exist_xyz --json' \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2> "$SANDBOX/rc-cfailed.log"
CF_RC=$?
expect "a broken CENSUS recipe never changes the runner's own (successful) exit code" \
  test "$CF_RC" -eq 0
expect "the main status is still CMD's own OK" grep -qx OK "$CF/test-final.status"
expect "a broken CENSUS recipe is recorded FAILED, NOT OK" \
  grep -qx FAILED "$CF/test-final.census.status"
refute "a broken CENSUS recipe writes no OK-over-empty population.txt" \
  test -f "$CF/test-final.population.txt"
refute "a broken CENSUS recipe writes no skips.txt either" \
  test -f "$CF/test-final.skips.txt"
expect "the broken recipe is named loudly on stderr" \
  grep -qi 'CENSUS recipe exited' "$SANDBOX/rc-cfailed.log"

# The residual C1 class: a MULTI-STAGE recipe whose broken stage is NOT last. Without
# pipefail census_rc was only the LAST stage's, so `<broken> | cat` (cat exits 0 over
# the empty stream) wrote OK over an empty population — the same fail-open, one stage
# deeper. pipefail makes a broken stage anywhere in the recipe's own pipeline the pipe's
# status. An error-exit is >= 2 (a wrong flag shape, a fatal awk/jq); exit 1 stays benign
# because grep's no-match (the empty-census idiom above) is exactly exit 1.
CMD="$CF/fake-green.sh" OUT="$CF/test-multistage" \
  CENSUS='sh -c "exit 2" | cat' \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
expect "a multi-stage recipe whose non-last stage errors (>=2) is FAILED, not OK on the last stage's 0" \
  grep -qx FAILED "$CF/test-multistage.census.status"
refute "the fail-open multi-stage recipe writes no OK-over-empty population.txt" \
  test -f "$CF/test-multistage.population.txt"
# The verifier's exact named case: an absent tool (127) feeding a tool that succeeds.
CMD="$CF/fake-green.sh" OUT="$CF/test-missing-first" \
  CENSUS='this_census_tool_does_not_exist_xyz --json | cat' \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
expect "a recipe whose FIRST stage is a missing tool (127) is FAILED, not OK over cat's empty output" \
  grep -qx FAILED "$CF/test-missing-first.census.status"
# The other half of the trade-off: grep's no-match (exit 1) as the non-last stage of a
# multi-stage recipe is a LEGITIMATE empty census, NOT a breakage — it must stay OK even
# under pipefail, or every helpers-only module reports FAILED.
CMD="$CF/fake-green.sh" OUT="$CF/test-nomatch-multistage" \
  CENSUS='grep "^NOSUCHLINE " | awk "{print \$2\"\tpass\"}"' \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
expect "a multi-stage recipe whose first stage matched nothing (exit 1) stays OK, not FAILED" \
  grep -qx OK "$CF/test-nomatch-multistage.census.status"
expect "that legitimately empty census still writes an (empty) population.txt" \
  test -f "$CF/test-nomatch-multistage.population.txt"

fi

if t "run-check.sh bounds the excerpt at EXCERPT_MAX and picks the right source per branch"; then
# The excerpt is a CHEAP, BOUNDED triage view, not the whole log. Two branches on a
# failing command: with an EXTRACTOR that matched, it is the HEAD of the extracted
# failure set (the first failing ids, in emission order); with no EXTRACTOR, or one
# that matched nothing, it is the TAIL of the raw log (the end, where a panic/summary
# lands). Both bounded to EXCERPT_MAX lines. Mutating head/tail to cat, or swapping
# the two sources, must go red here — neither was pinned before.
XM=$SANDBOX/run-check-excerpt
mkdir -p "$XM"

# Branch 1: EXTRACTOR matched — excerpt is the HEAD of the extracted set, bounded.
cat > "$XM/fail10.sh" <<'EOF'
#!/usr/bin/env bash
for n in 01 02 03 04 05 06 07 08 09 10; do echo "FAIL Test$n"; done
exit 1
EOF
chmod +x "$XM/fail10.sh"
CMD="$XM/fail10.sh" OUT="$XM/head" EXCERPT_MAX=3 \
  EXTRACTOR="grep '^FAIL' | awk '{print \$2}'" \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
expect "the extractor-branch excerpt is bounded to EXCERPT_MAX lines" \
  bash -c "test \"\$(grep -c . '$XM/head.excerpt.txt')\" = 3"
WANT_HEAD=$(printf 'Test01\nTest02\nTest03\n')
GOT_HEAD=$(cat "$XM/head.excerpt.txt" 2>/dev/null)
if [[ "$GOT_HEAD" = "$WANT_HEAD" ]]; then
  pass "the extractor-branch excerpt is the HEAD of the extracted failure set (first ids, from the extractor pass — not the raw log tail)"
else
  fail "the extractor-branch excerpt = '$GOT_HEAD' (want the first 3 extracted ids '$WANT_HEAD')"
fi

# Branch 2: no EXTRACTOR — excerpt is the TAIL of the raw log, bounded.
cat > "$XM/raw10.sh" <<'EOF'
#!/usr/bin/env bash
for n in 01 02 03 04 05 06 07 08 09 10; do echo "line$n"; done
exit 1
EOF
chmod +x "$XM/raw10.sh"
CMD="$XM/raw10.sh" OUT="$XM/tail" EXCERPT_MAX=4 \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
expect "the raw-tail-branch excerpt is bounded to EXCERPT_MAX lines" \
  bash -c "test \"\$(grep -c . '$XM/tail.excerpt.txt')\" = 4"
WANT_TAIL=$(printf 'line07\nline08\nline09\nline10\n')
GOT_TAIL=$(cat "$XM/tail.excerpt.txt" 2>/dev/null)
if [[ "$GOT_TAIL" = "$WANT_TAIL" ]]; then
  pass "the no-extractor excerpt is the TAIL of the raw log (last lines, where a panic/summary lands)"
else
  fail "the no-extractor excerpt = '$GOT_TAIL' (want the last 4 raw lines '$WANT_TAIL')"
fi

# Branch 3: EXTRACTOR set but matched NOTHING on a failing command — the excerpt
# falls back to the raw tail, NOT the (empty) extracted set. This is the
# EXTRACTOR_MISMATCH branch's excerpt source, previously unasserted.
cat > "$XM/panic.sh" <<'EOF'
#!/usr/bin/env bash
for n in 01 02 03 04 05 06 07 08 09 10; do echo "noise$n"; done
echo "panic: boom"
exit 2
EOF
chmod +x "$XM/panic.sh"
CMD="$XM/panic.sh" OUT="$XM/fallback" EXCERPT_MAX=3 \
  EXTRACTOR="grep '^FAIL' | awk '{print \$2}'" \
  "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2>&1
expect "the fallback excerpt is bounded to EXCERPT_MAX lines" \
  bash -c "test \"\$(grep -c . '$XM/fallback.excerpt.txt')\" = 3"
expect "an extractor that matched nothing falls back to the raw TAIL (the log end, carrying the panic)" \
  grep -qx 'panic: boom' "$XM/fallback.excerpt.txt"

fi

if t "run-check.sh keeps the raw log plain, with a diagnostic, when gzip itself fails"; then
# Unchecked, a failed compress leaves a truncated/absent $OUT.txt.gz sitting
# beside a status that still reads OK/FAIL normally — silent evidence loss.
# Force the failure DAC-independently (works even as root, unlike chmod 000):
# pre-create $OUT.txt.gz as a DIRECTORY, so the `> "$OUT.txt.gz"` redirection
# itself cannot open a regular file there.
GZ=$SANDBOX/run-check-gzipfail
mkdir -p "$GZ" "$GZ/out.txt.gz"
CMD="echo hello" OUT="$GZ/out" "$SKILL_DIR/scripts/run-check.sh" > /dev/null 2> "$SANDBOX/rc-gzipfail.log"
GZ_RC=$?
expect "the wrapped command's own exit code is untouched by the gzip failure" \
  test "$GZ_RC" -eq 0
expect "a diagnostic names the gzip failure" \
  grep -qi 'gzip' "$SANDBOX/rc-gzipfail.log"
# The diagnostic must report gzip's OWN (non-zero) exit code, not "exit 0":
# capturing gz_rc inside `if ! gzip; then` reads the negation's status (always 0
# on a real failure), so the one message whose job is diagnosis read as success.
expect "the diagnostic reports gzip's real non-zero exit, not 'exit 0'" \
  bash -c "! grep -qi 'exit 0' '$SANDBOX/rc-gzipfail.log'"
expect "the raw log is kept plain instead of lost" test -s "$GZ/out.txt"
expect "the plain fallback carries the command's real output" \
  grep -qx hello "$GZ/out.txt"
expect "the status artifact is unaffected — still CMD's own OK" \
  grep -qx OK "$GZ/out.status"

fi

finish_suite
