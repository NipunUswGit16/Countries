#!/usr/bin/env bash
# silenced-tests.test.sh — tests for scripts/silenced-tests.sh
# TEST_FILTER supported (every block builds its own isolated repo).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

ST="$SKILL_DIR/scripts/silenced-tests.sh"

if t "silenced-tests.sh reports a skip construct added within the range (file, line, construct)"; then
R1=$SANDBOX/st1
mkdir -p "$R1/repo/pkg" && cd "$R1/repo" && git init -q -b main
cat > pkg/foo_test.go <<'EOF'
package foo

func TestFoo(t *testing.T) {
	doStuff()
}
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
cat > pkg/foo_test.go <<'EOF'
package foo

func TestFoo(t *testing.T) {
	t.Skip("reason")
	doStuff()
}
EOF
git add -A && git commit -qm "silence foo"
mkdir -p "$R1/state"
RUN="$R1/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st1.log"
expect "exits 0" test $? -eq 0
expect "reports pkg/foo_test.go line 4 construct t.Skip" \
  grep -qxF -- "$(printf 'pkg/foo_test.go\t4\tt.Skip')" "$R1/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh reports a JS/TS .todo pending marker added within the range"; then
# Regression (m4): the phases/4.5 doc claims the scan covers `.todo`; the needle table
# must actually carry it. A `.todo` test's body never runs, so it silences a test just
# as `.skip` does.
RT=$SANDBOX/st-todo
mkdir -p "$RT/repo/src" && cd "$RT/repo" && git init -q -b main
cat > src/app.test.ts <<'EOF'
import { it } from "vitest"

it("adds", () => { expect(1 + 1).toBe(2) })
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
cat > src/app.test.ts <<'EOF'
import { it } from "vitest"

it.todo("adds — will implement later")
EOF
git add -A && git commit -qm "stub out the test with .todo"
mkdir -p "$RT/state"
RUN="$RT/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st-todo.log"
expect "exits 0" test $? -eq 0
expect "reports src/app.test.ts line 3 construct it.todo" \
  grep -qxF -- "$(printf 'src/app.test.ts\t3\tit.todo')" "$RT/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: the same construct already present before PREV_SHA is silent"; then
R2=$SANDBOX/st2
mkdir -p "$R2/repo/pkg" && cd "$R2/repo" && git init -q -b main
cat > pkg/foo_test.go <<'EOF'
package foo

func TestFoo(t *testing.T) {
	t.Skip("already here")
	doStuff()
}
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
# Unrelated change in the same file; the skip line itself is untouched.
sed 's/doStuff()/doOtherStuff()/' pkg/foo_test.go > t.tmp && mv t.tmp pkg/foo_test.go
git add -A && git commit -qm "unrelated change"
mkdir -p "$R2/state"
RUN="$R2/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st2.log"
expect "exits 0" test $? -eq 0
refute "a pre-existing t.Skip is not reported" \
  grep -q 't.Skip' "$R2/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: a skip added and later removed within the range is silent (net diff)"; then
R3=$SANDBOX/st3
mkdir -p "$R3/repo/pkg" && cd "$R3/repo" && git init -q -b main
cat > pkg/bar_test.go <<'EOF'
package bar

func TestBar(t *testing.T) {
	doStuff()
}
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
cat > pkg/bar_test.go <<'EOF'
package bar

func TestBar(t *testing.T) {
	t.Skip("temporary")
	doStuff()
}
EOF
git add -A && git commit -qm "add skip"
# Restore the exact baseline content — net diff for this file is empty.
cat > pkg/bar_test.go <<'EOF'
package bar

func TestBar(t *testing.T) {
	doStuff()
}
EOF
git add -A && git commit -qm "remove skip again"
mkdir -p "$R3/state"
RUN="$R3/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st3.log"
expect "exits 0" test $? -eq 0
refute "a skip added then removed within the range is not reported" \
  grep -q 'bar_test.go' "$R3/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: a construct added in a NON-test file is ignored"; then
R4=$SANDBOX/st4
mkdir -p "$R4/repo/pkg" && cd "$R4/repo" && git init -q -b main
cat > pkg/plain.go <<'EOF'
package plain

func DoWork() {
	work()
}
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
cat > pkg/plain.go <<'EOF'
package plain

func DoWork() {
	t.Skip("this is not even a test file")
	work()
}
EOF
git add -A && git commit -qm "skip-shaped line in a non-test file"
mkdir -p "$R4/state"
RUN="$R4/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st4.log"
expect "exits 0" test $? -eq 0
refute "a construct in a non-test file (plain.go) is never reported" \
  grep -q 'plain.go' "$R4/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: a construct on an added COMMENT line is reported (documented behavior)"; then
R5=$SANDBOX/st5
mkdir -p "$R5/repo/pkg" && cd "$R5/repo" && git init -q -b main
cat > pkg/baz_test.go <<'EOF'
package baz

func TestBaz(t *testing.T) {
	doStuff()
}
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
cat > pkg/baz_test.go <<'EOF'
package baz

func TestBaz(t *testing.T) {
	// TODO: t.Skip this once the flake is understood
	doStuff()
}
EOF
git add -A && git commit -qm "comment mentions a skip"
mkdir -p "$R5/state"
RUN="$R5/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st5.log"
expect "exits 0" test $? -eq 0
expect "a match on an added comment line is still reported (line 4, t.Skip)" \
  grep -qxF -- "$(printf 'pkg/baz_test.go\t4\tt.Skip')" "$R5/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: zero findings is positive evidence, not silence"; then
R6=$SANDBOX/st6
mkdir -p "$R6/repo/pkg" && cd "$R6/repo" && git init -q -b main
cat > pkg/qux_test.go <<'EOF'
package qux

func TestQux(t *testing.T) {
	assertEqual(1, 1)
}
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
cat > pkg/qux_test.go <<'EOF'
package qux

func TestQux(t *testing.T) {
	assertEqual(2, 2)
}
EOF
git add -A && git commit -qm "ordinary test edit, no silencing"
mkdir -p "$R6/state"
RUN="$R6/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st6.log"
expect "exits 0" test $? -eq 0
expect "the artifact exists" test -f "$R6/state/silenced-tests.tsv"
expect "the artifact is empty of findings" test ! -s "$R6/state/silenced-tests.tsv"
expect "stderr names a positive scanned-file count" \
  grep -qE 'OK: scanned [1-9][0-9]* test file' "$SANDBOX/st6.log"
expect "stderr names zero newly-silenced constructs" \
  grep -qE '0 newly-silenced construct' "$SANDBOX/st6.log"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: PREV_SHA missing/unset never produces a clean-reading artifact"; then
R7=$SANDBOX/st7
mkdir -p "$R7/repo" && cd "$R7/repo" && git init -q -b main
echo x > f.txt && git add -A && git commit -qm baseline
git commit --allow-empty -qm "second commit"
mkdir -p "$R7/state"

# (a) PREV_SHA entirely unset.
( unset PREV_SHA; RUN="$R7/state" bash "$ST" ) > /dev/null 2> "$SANDBOX/st7a.log"
RC=$?
expect "unset PREV_SHA exits non-zero" test "$RC" -ne 0
refute "unset PREV_SHA writes no artifact" test -e "$R7/state/silenced-tests.tsv"

# (b) PREV_SHA set but does not resolve to a commit.
RUN="$R7/state" PREV_SHA="not-a-real-commit-ish" bash "$ST" > /dev/null 2> "$SANDBOX/st7b.log"
RC=$?
expect "unresolvable PREV_SHA exits non-zero" test "$RC" -ne 0
refute "unresolvable PREV_SHA writes no artifact" test -e "$R7/state/silenced-tests.tsv"

# (c) A prior successful run's artifact must survive a later failing invocation
# untouched — it must never be overwritten with an empty "clean" file.
PREV=$(git rev-parse HEAD~1)
RUN="$R7/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st7c.log"
expect "a real prior run succeeds" test $? -eq 0
BEFORE=$(cat "$R7/state/silenced-tests.tsv")
RUN="$R7/state" PREV_SHA="" bash "$ST" > /dev/null 2> "$SANDBOX/st7d.log"
expect "a later empty-PREV_SHA invocation exits non-zero" test $? -ne 0
AFTER=$(cat "$R7/state/silenced-tests.tsv")
if [[ "$BEFORE" = "$AFTER" ]]; then
  pass "the earlier successful artifact is left untouched by the later failure"
else
  fail "the earlier successful artifact was overwritten by the later failure"
fi
cd "$SANDBOX"
fi

if t "silenced-tests.sh: a FAILED range diff is a loud stop, never a false clean"; then
# The diff's exit status was never checked (and its stderr was discarded), so a diff
# that FAILED — a pruned or corrupted object in the store — left an empty $DIFF, and
# the scan then wrote a zero-finding artifact over a good one and printed OK/exit 0.
# That contradicts this script's own contract for every other failure: on failure it
# writes nothing and leaves an earlier successful artifact untouched. Reproduced by
# removing the baseline blob the range diff has to read — `git rev-parse` still
# resolves both commits, only the content read fails.
R7B=$SANDBOX/st7b-diff
mkdir -p "$R7B/repo/pkg" && cd "$R7B/repo" && git init -q -b main
cat > pkg/foo_test.go <<'EOF'
package foo

func TestFoo(t *testing.T) {
	doStuff()
}
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
cat > pkg/foo_test.go <<'EOF'
package foo

func TestFoo(t *testing.T) {
	t.Skip("silenced in range")
	doStuff()
}
EOF
git add -A && git commit -qm "silence foo"
mkdir -p "$R7B/state"
RUN="$R7B/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st7b1.log"
expect "the healthy run succeeds first" test $? -eq 0
expect "the healthy run really did record a finding" test -s "$R7B/state/silenced-tests.tsv"
BEFORE=$(cat "$R7B/state/silenced-tests.tsv")

# Break exactly one thing: the baseline blob the range diff must read.
BLOB=$(git rev-parse "$PREV:pkg/foo_test.go")
rm -f ".git/objects/${BLOB:0:2}/${BLOB:2}"
refute "the fixture's range diff really does fail now" git diff "$PREV" HEAD
expect "both commits still resolve (only the content read is broken)" \
  bash -c "git rev-parse --verify --quiet '$PREV^{commit}' >/dev/null && git rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null"

RUN="$R7B/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st7b2.log"
RC=$?
expect "a failed range diff exits non-zero" test "$RC" -ne 0
expect "the failure says no artifact was written" \
  grep -q 'no .*silenced-tests.tsv was written' "$SANDBOX/st7b2.log"
expect "git's own reason is relayed (stderr is not swallowed)" \
  grep -qi 'fatal' "$SANDBOX/st7b2.log"
refute "no OK line claims a clean scan" grep -q '^OK: scanned' "$SANDBOX/st7b2.log"
AFTER=$(cat "$R7B/state/silenced-tests.tsv")
if [[ "$BEFORE" = "$AFTER" ]]; then
  pass "the earlier successful artifact is left untouched by the failed diff"
else
  fail "the failed diff overwrote the earlier successful artifact"
fi
cd "$SANDBOX"
fi

if t "silenced-tests.sh: a non-ASCII test path is scanned and reported"; then
R8=$SANDBOX/st8
mkdir -p "$R8/repo/pkg" && cd "$R8/repo" && git init -q -b main
cat > "pkg/héllo_test.go" <<'EOF'
package hello

func TestHello(t *testing.T) {
	doStuff()
}
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
cat > "pkg/héllo_test.go" <<'EOF'
package hello

func TestHello(t *testing.T) {
	t.Skip("unicode path")
	doStuff()
}
EOF
git add -A && git commit -qm "silence the unicode-named test"
mkdir -p "$R8/state"
RUN="$R8/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st8.log"
expect "exits 0" test $? -eq 0
expect "the non-ASCII path is reported exactly, line 4, t.Skip" \
  grep -qxF -- "$(printf 'pkg/héllo_test.go\t4\tt.Skip')" "$R8/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: a test-file rename within the range where the new path gained a skip line is still scanned"; then
R9=$SANDBOX/st9
mkdir -p "$R9/repo/pkg" && cd "$R9/repo" && git init -q -b main
seq 1 12 | sed 's/^/line /' > pkg/old_test.go
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
git mv pkg/old_test.go pkg/new_test.go
printf 't.Skip("renamed and silenced")\n' >> pkg/new_test.go
git add -A && git commit -qm "rename and silence"
mkdir -p "$R9/state"
RUN="$R9/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st9.log"
expect "exits 0" test $? -eq 0
expect "the added line under the NEW path is reported (line 13, t.Skip)" \
  grep -qxF -- "$(printf 'pkg/new_test.go\t13\tt.Skip')" "$R9/state/silenced-tests.tsv"
refute "the old (pre-rename) path is never reported" \
  grep -q 'old_test.go' "$R9/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: every construct in the fixed list is matched, one fixture per filename-pattern family"; then
RS=$SANDBOX/st-sweep
mkdir -p "$RS/repo" && cd "$RS/repo" && git init -q -b main
echo x > unrelated.txt
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)

mkdir -p pkg
# Go: t.SkipNow and t.Skipf — both are literal prefixes of/by "t.Skip", so this
# also asserts the longer, more specific construct wins over the shorter one.
cat > pkg/sweep_test.go <<'EOF'
package sweep

func TestSweep(t *testing.T) {
	t.SkipNow()
	t.Skipf("reason %s", "x")
}
EOF
# JS/TS: matched via the generic *.test.* filename pattern.
cat > sweep.test.js <<'EOF'
it.skip('a', () => {})
describe.skip('b', () => {})
test.skip('c', () => {})
xit('d', () => {})
xdescribe('e', () => {})
EOF
# Java: no dedicated filename pattern exists for it in this skill's design
# (only *_test.go / *.test.* / *.spec.* / test_*.py / *_test.py are matched);
# a Java file that happens to satisfy the generic *.test.*/*.spec.* pattern is
# still classified as a test file, which is the literal point of matching by
# filename pattern rather than by language.
cat > Sweep.test.java <<'EOF'
@Disabled
class Sweep {}
EOF
cat > Sweep.spec.java <<'EOF'
@Ignore
class Sweep2 {}
EOF
# Python: pytest.mark.skipif must win over the shorter pytest.mark.skip it
# is prefixed by, same argument as the Go pair above.
cat > sweep_test.py <<'EOF'
@pytest.mark.skip
def test_a():
    pass


@pytest.mark.skipif(True, reason="x")
def test_b():
    pass
EOF
git add -A && git commit -qm "sweep: one of every construct"
mkdir -p "$RS/state"
RUN="$RS/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st-sweep.log"
TSV="$RS/state/silenced-tests.tsv"
expect "exits 0" test $? -eq 0

expect "go: t.SkipNow reported precisely (not truncated to t.Skip)" \
  grep -qxF -- "$(printf 'pkg/sweep_test.go\t4\tt.SkipNow')" "$TSV"
expect "go: t.Skipf reported precisely (not truncated to t.Skip)" \
  grep -qxF -- "$(printf 'pkg/sweep_test.go\t5\tt.Skipf')" "$TSV"

expect "js/ts: it.skip" grep -qxF -- "$(printf 'sweep.test.js\t1\tit.skip')" "$TSV"
expect "js/ts: describe.skip" grep -qxF -- "$(printf 'sweep.test.js\t2\tdescribe.skip')" "$TSV"
expect "js/ts: test.skip" grep -qxF -- "$(printf 'sweep.test.js\t3\ttest.skip')" "$TSV"
expect "js/ts: xit" grep -qxF -- "$(printf 'sweep.test.js\t4\txit')" "$TSV"
expect "js/ts: xdescribe" grep -qxF -- "$(printf 'sweep.test.js\t5\txdescribe')" "$TSV"

expect "java: @Disabled (via the generic *.test.* pattern)" \
  grep -qxF -- "$(printf 'Sweep.test.java\t1\t@Disabled')" "$TSV"
expect "java: @Ignore (via the generic *.spec.* pattern)" \
  grep -qxF -- "$(printf 'Sweep.spec.java\t1\t@Ignore')" "$TSV"

expect "python: pytest.mark.skip" \
  grep -qxF -- "$(printf 'sweep_test.py\t1\tpytest.mark.skip')" "$TSV"
expect "python: pytest.mark.skipif reported precisely (not truncated to pytest.mark.skip)" \
  grep -qxF -- "$(printf 'sweep_test.py\t6\tpytest.mark.skipif')" "$TSV"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: Go's canonical os.Exit(m.Run()) TestMain wrapper is not mistaken for Jasmine's xit (word-boundary fix)"; then
R10=$SANDBOX/st10
mkdir -p "$R10/repo/pkg" && cd "$R10/repo" && git init -q -b main
cat > pkg/foo_test.go <<'EOF'
package foo

func TestFoo(t *testing.T) {
	doStuff()
}
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
# A migration-shaped addition: the standard TestMain wrapper, which contains
# the substring "xit" inside "os.Exit" — this must NOT classify as the
# Jasmine `xit` skip construct.
cat > pkg/main_test.go <<'EOF'
package foo

func TestMain(m *testing.M) {
	os.Exit(m.Run())
}
EOF
git add -A && git commit -qm "add TestMain wrapper"
mkdir -p "$R10/state"
RUN="$R10/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st10.log"
expect "exits 0" test $? -eq 0
refute "os.Exit(m.Run()) inside TestMain produces no finding at all" \
  grep -q 'main_test.go' "$R10/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: a genuine xit(...) addition alongside an os.Exit TestMain in the same range still produces a finding"; then
R11=$SANDBOX/st11
mkdir -p "$R11/repo/pkg" && cd "$R11/repo" && git init -q -b main
cat > pkg/main_test.go <<'EOF'
package foo

func TestMain(m *testing.M) {
	m.Run()
}
EOF
cat > sweep.test.js <<'EOF'
it('a', () => {})
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
cat > pkg/main_test.go <<'EOF'
package foo

func TestMain(m *testing.M) {
	os.Exit(m.Run())
}
EOF
cat > sweep.test.js <<'EOF'
xit('a', () => {})
EOF
git add -A && git commit -qm "add TestMain wrapper and silence a JS test"
mkdir -p "$R11/state"
RUN="$R11/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st11.log"
expect "exits 0" test $? -eq 0
refute "the TestMain/os.Exit line is still not reported" \
  grep -q 'main_test.go' "$R11/state/silenced-tests.tsv"
expect "the genuine xit(...) addition is reported (line 1, xit)" \
  grep -qxF -- "$(printf 'sweep.test.js\t1\txit')" "$R11/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: needles embedded inside unrelated longer identifiers are not false positives (systematic boundary check, not just xit)"; then
R12=$SANDBOX/st12
mkdir -p "$R12/repo/pkg" && cd "$R12/repo" && git init -q -b main
cat > pkg/cart_test.go <<'EOF'
package cart

func TestCart(t *testing.T) {
	doStuff()
}
EOF
cat > plain.test.js <<'EOF'
runTests()
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
# "receipt.Skip()" embeds the literal substring "t.Skip" (an unrelated method
# on an unrelated "receipt" value, not Go's t.Skip(...)); "circuit.skip()"
# embeds the literal substring "it.skip" (an unrelated "circuit" value, not
# Jasmine/Jest's it.skip(...)). Neither is a real skip construct — both are
# infixes of a longer identifier — so neither may be reported.
cat > pkg/cart_test.go <<'EOF'
package cart

func TestCart(t *testing.T) {
	receipt.Skip()
	doStuff()
}
EOF
cat > plain.test.js <<'EOF'
runTests()
circuit.skip()
EOF
git add -A && git commit -qm "unrelated identifiers that happen to embed needle substrings"
mkdir -p "$R12/state"
RUN="$R12/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st12.log"
expect "exits 0" test $? -eq 0
expect "the artifact is empty of findings" test ! -s "$R12/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

if t "silenced-tests.sh: a repo-local diff.noprefix=true does not truncate reported paths"; then
R13=$SANDBOX/st13
mkdir -p "$R13/repo/pkg" && cd "$R13/repo" && git init -q -b main
# Reproduces the bug directly: with diff.noprefix on, `git diff` headers arrive
# as `--- pkg/foo_test.go` instead of `--- a/pkg/foo_test.go`, and an unguarded
# `substr(p, 3)` (written for the fixed 2-char `a/`/`b/` prefix) instead drops
# the path's own first two characters, truncating it to `g/foo_test.go`. Set as
# a REPO-local config (not global) so the fixture is self-contained and never
# depends on — or pollutes — the machine running the suite.
git config diff.noprefix true
cat > pkg/foo_test.go <<'EOF'
package foo

func TestFoo(t *testing.T) {
	doStuff()
}
EOF
git add -A && git commit -qm baseline
PREV=$(git rev-parse HEAD)
cat > pkg/foo_test.go <<'EOF'
package foo

func TestFoo(t *testing.T) {
	t.Skip("reason")
	doStuff()
}
EOF
git add -A && git commit -qm "silence foo"
mkdir -p "$R13/state"
RUN="$R13/state" PREV_SHA="$PREV" bash "$ST" > /dev/null 2> "$SANDBOX/st13.log"
expect "exits 0" test $? -eq 0
expect "the path is reported intact (not truncated to o_test.go)" \
  grep -qxF -- "$(printf 'pkg/foo_test.go\t4\tt.Skip')" "$R13/state/silenced-tests.tsv"
refute "the truncated path (g/foo_test.go, dropping the leading 'pk') never appears as a row's path" \
  grep -qE '^g/foo_test\.go' "$R13/state/silenced-tests.tsv"
cd "$SANDBOX"
fi

finish_suite
