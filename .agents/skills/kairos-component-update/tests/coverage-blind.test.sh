#!/usr/bin/env bash
# coverage-blind.test.sh — tests for scripts/coverage-blind.sh
# TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

if t "coverage-blind.sh (clean-merged files with no sibling test)"; then
# The gate is blind to a clean-merged file nothing imports; this list is what the
# planner eyeballs. The sibling-test heuristic keys off a tracked file whose name
# carries both the stem and test/spec.
CB=$SANDBOX/coverage-blind
mkdir -p "$CB/repo/pkg" && cd "$CB/repo" && git init -q -b main
# widget.go HAS a sibling test → covered (not blind)
echo x > pkg/widget.go && echo x > pkg/widget_test.go
# lonely.go has NO sibling test → blind
echo x > pkg/lonely.go
# foo.bar.go (regex-metachar stem) — its only near-name sibling is fooxbar_test.go,
# which tests a DIFFERENT file. An unescaped stem regex ('.' matches any char) would
# match fooxbar and wrongly treat foo.bar.go as covered; the literal-safe fix keeps
# it blind.
echo x > pkg/foo.bar.go && echo x > pkg/fooxbar.go && echo x > pkg/fooxbar_test.go
git add -A && git commit -qm fixtures
printf 'pkg/widget.go\npkg/lonely.go\npkg/foo.bar.go\n' > "$CB/clean-merged.txt"
# state dir holds clean-merged.txt; run from the component work tree
mkdir -p "$CB/state" && cp "$CB/clean-merged.txt" "$CB/state/clean-merged.txt"
RUN="$CB/state" "$SKILL_DIR/scripts/coverage-blind.sh" > "$SANDBOX/cb.out" 2> "$SANDBOX/cb.log"
expect "coverage-blind.sh exits 0" test $? -eq 0
refute "a file with a sibling test is not coverage-blind" \
  grep -qx 'pkg/widget.go' "$CB/state/coverage-blind.txt"
expect "a file with no sibling test is coverage-blind" \
  grep -qx 'pkg/lonely.go' "$CB/state/coverage-blind.txt"
expect "a regex-metachar stem matches literally (foo.bar.go stays blind, not fooled by fooxbar_test.go)" \
  grep -qx 'pkg/foo.bar.go' "$CB/state/coverage-blind.txt"

fi

if t "coverage-blind.sh scopes the sibling search to the file's own directory, not the whole repo"; then
# Regression for the "." bug: git ls-files "." on a root-level file lists the
# WHOLE repo, so a test anywhere (e.g. internal/domain/maintenance_test.go)
# falsely "covered" a root main.go with no sibling of its own.
RB=$SANDBOX/coverage-blind-root
mkdir -p "$RB/repo/internal/domain" && cd "$RB/repo" && git init -q -b main
# root main.go has NO root sibling test, but an unrelated test exists deep
# in the tree — must still be reported coverage-blind.
echo x > main.go
echo x > internal/domain/maintenance.go
echo x > internal/domain/maintenance_test.go
git add -A && git commit -qm fixtures
mkdir -p "$RB/state"
printf 'main.go\n' > "$RB/state/clean-merged.txt"
RUN="$RB/state" "$SKILL_DIR/scripts/coverage-blind.sh" > "$SANDBOX/cb-root.out" 2> "$SANDBOX/cb-root.log"
expect "coverage-blind.sh exits 0" test $? -eq 0
expect "root main.go with no root sibling test IS coverage-blind, despite an unrelated test elsewhere in the repo" \
  grep -qx 'main.go' "$RB/state/coverage-blind.txt"

# Now give it a real root sibling test — it must no longer be coverage-blind.
echo x > main_test.go
git add -A && git commit -qm "add root sibling test"
RUN="$RB/state" "$SKILL_DIR/scripts/coverage-blind.sh" > "$SANDBOX/cb-root2.out" 2> "$SANDBOX/cb-root2.log"
expect "coverage-blind.sh exits 0" test $? -eq 0
refute "a root main.go WITH a root main_test.go is not coverage-blind" \
  grep -qx 'main.go' "$RB/state/coverage-blind.txt"

cd "$SANDBOX"
fi

if t "coverage-blind.sh matches BASENAMES, so a directory named after a stem cannot fake coverage"; then
# Regression for the full-path bug: the stem/test regex was matched against the
# candidate's whole PATH, so under internal/service/ every entry contains
# "service" and any *_test.go sibling satisfied 'service.*(test|spec)' —
# service.go was silently marked covered and dropped off the planner's list.
DB=$SANDBOX/coverage-blind-dirstem
mkdir -p "$DB/repo/internal/service" && cd "$DB/repo" && git init -q -b main
# service.go's only sibling test tests a DIFFERENT file (handler.go).
echo x > internal/service/service.go
echo x > internal/service/handler.go
echo x > internal/service/handler_test.go
git add -A && git commit -qm fixtures
mkdir -p "$DB/state"
printf 'internal/service/service.go\n' > "$DB/state/clean-merged.txt"
RUN="$DB/state" "$SKILL_DIR/scripts/coverage-blind.sh" > /dev/null 2> "$SANDBOX/cb-dirstem.log"
expect "coverage-blind.sh exits 0" test $? -eq 0
expect "service.go in a directory named 'service' IS coverage-blind (handler_test.go does not cover it)" \
  grep -qx 'internal/service/service.go' "$DB/state/coverage-blind.txt"

# A REAL sibling test in the same stem-named directory must still count as coverage.
echo x > internal/service/service_test.go
git add -A && git commit -qm "add the real sibling test"
RUN="$DB/state" "$SKILL_DIR/scripts/coverage-blind.sh" > /dev/null 2> "$SANDBOX/cb-dirstem2.log"
expect "coverage-blind.sh exits 0" test $? -eq 0
refute "service.go WITH service_test.go beside it is not coverage-blind" \
  grep -qx 'internal/service/service.go' "$DB/state/coverage-blind.txt"

cd "$SANDBOX"
fi

if t "coverage-blind.sh dotfiles keep a non-empty stem (no collapse onto every test/spec sibling)"; then
# `${b%.*}` treats a dotfile's ONLY dot (the leading one) as an extension
# separator: ".env" collapses to an EMPTY stem. An empty stem makes the
# coverage regex "(test|spec).*|.*(test|spec)" — unanchored on the stem side —
# so ANY sibling containing "test"/"spec" falsely "covers" the dotfile, and
# every dotfile in the directory collapses onto the same (empty) key.
# Regression.
DF=$SANDBOX/coverage-blind-dotfile
mkdir -p "$DF/repo" && cd "$DF/repo" && git init -q -b main
# .env has NO sibling that actually tests it; main_test.go is unrelated but
# would satisfy the collapsed empty-stem regex.
echo x > .env
echo x > main.go
echo x > main_test.go
git add -A && git commit -qm fixtures
mkdir -p "$DF/state"
printf '.env\n' > "$DF/state/clean-merged.txt"
RUN="$DF/state" "$SKILL_DIR/scripts/coverage-blind.sh" > /dev/null 2> "$SANDBOX/cb-dotfile.log"
expect "coverage-blind.sh exits 0" test $? -eq 0
expect "a dotfile with no real sibling test IS coverage-blind (not falsely covered by an unrelated *_test.go)" \
  grep -qx '.env' "$DF/state/coverage-blind.txt"

# A dotfile that genuinely has its own sibling test must still count as covered.
echo x > .env_test
git add -A && git commit -qm "add a real sibling test for .env"
RUN="$DF/state" "$SKILL_DIR/scripts/coverage-blind.sh" > /dev/null 2> "$SANDBOX/cb-dotfile2.log"
expect "coverage-blind.sh exits 0" test $? -eq 0
refute "a dotfile WITH its own sibling test is not coverage-blind" \
  grep -qx '.env' "$DF/state/coverage-blind.txt"

cd "$SANDBOX"
fi

if t "coverage-blind.sh handles a path whose whole name is an option string (record + scoping)"; then
# clean-merged.txt is written by structural-merge.sh, which now records such paths
# faithfully — so this script is the first consumer that has to read one. Two
# defects, one fixture:
#   * the record write was `echo "$f"`, and bash's builtin echo reads an argument
#     that is EXACTLY an option string (`-n`, `-e`, `-E`, any combination) as its
#     own options: a coverage-blind file named `-n` was written as an empty line
#     or, with `-n` in the set, not at all — it dropped off the planner's eyeball
#     list with nothing to show it had ever been considered.
#   * `basename`/`dirname` on an UNANCHORED leading-dash path read it as options
#     too: both printed a usage error to the operator's stderr and returned
#     empty, so the stem was empty and `$d` matched no directory in the cached
#     listing. Every leading-dash entry then classified blind regardless of the
#     siblings it actually has — the same wrong answer for the opposite reason.
DASH=$SANDBOX/coverage-blind-dash
mkdir -p "$DASH/repo/pkg" && cd "$DASH/repo" && git init -q -b main
echo x > ./-n              # whole name is an option string, no sibling test -> blind
echo x > ./-e.go           # leading dash, HAS its own sibling test -> covered
echo x > ./-e_test.go
echo x > pkg/-n.go         # leading dash on the BASENAME only (the arg is not an
echo x > pkg/other.go      # option string) — control: this shape always worked
git add -A -- . && git commit -qm fixtures
mkdir -p "$DASH/state"
printf -- '-n\n-e.go\npkg/-n.go\n' > "$DASH/state/clean-merged.txt"
RUN="$DASH/state" "$SKILL_DIR/scripts/coverage-blind.sh" > /dev/null 2> "$SANDBOX/cb-dash.log"
expect "coverage-blind.sh exits 0" test $? -eq 0
expect "a coverage-blind file whose whole name is an option string IS recorded" \
  grep -qxF -- '-n' "$DASH/state/coverage-blind.txt"
expect "a leading-dash basename under a subdirectory is recorded (control)" \
  grep -qxF -- 'pkg/-n.go' "$DASH/state/coverage-blind.txt"
refute "a leading-dash file WITH its own sibling test is still classified as covered" \
  grep -qxF -- '-e.go' "$DASH/state/coverage-blind.txt"
refute "no basename/dirname usage error leaks to stderr" \
  grep -qE 'illegal option|invalid option|usage:' "$SANDBOX/cb-dash.log"
cd "$SANDBOX"
fi

if t "coverage-blind.sh: hoisting git ls-files out of the loop does not change per-entry results"; then
# The sibling search used to call `git ls-files -- "$d"` once PER clean-merged
# entry (a full-repo listing for every root-level entry, since d="." there) —
# O(n) git spawns. It is now cached once and filtered per entry with awk. This
# fixture mixes root-level and several distinct subdirectories in ONE
# clean-merged.txt so the single cached listing has to be re-scoped correctly
# by dirname for every different $d, not just the last one filtered.
HE=$SANDBOX/coverage-blind-hoist
mkdir -p "$HE/repo/a" "$HE/repo/b/c" && cd "$HE/repo" && git init -q -b main
echo x > root.go                     # root, no sibling test -> blind
echo x > a/one.go                    # covered by a/one_test.go
echo x > a/one_test.go
echo x > b/c/two.go                  # no sibling test -> blind
echo x > b/c/unrelated_test.go       # tests something else in the same dir
git add -A && git commit -qm fixtures
mkdir -p "$HE/state"
printf 'root.go\na/one.go\nb/c/two.go\n' > "$HE/state/clean-merged.txt"
RUN="$HE/state" "$SKILL_DIR/scripts/coverage-blind.sh" > /dev/null 2> "$SANDBOX/cb-hoist.log"
expect "coverage-blind.sh exits 0" test $? -eq 0
WANT=$(printf 'b/c/two.go\nroot.go\n')
GOT=$(sort "$HE/state/coverage-blind.txt")
if [[ "$GOT" = "$WANT" ]]; then
  pass "mixed root/subdir entries against one cached listing classify identically to per-entry scoping (blind: root.go, b/c/two.go; covered: a/one.go)"
else
  fail "mixed root/subdir classification changed under the hoisted listing (got '$GOT', want '$WANT')"
fi
cd "$SANDBOX"
fi

if t "coverage-blind.sh empty clean-merged list yields empty output"; then
# Run from inside the git repo (not $SANDBOX): coverage-blind.sh now hard-fails
# when `git ls-files` fails (see the git-ls-files-fails test below), so this case
# must exercise the real "git ls-files succeeds, clean-merged.txt is empty" path
# rather than accidentally pass via a masked git failure outside any repo.
: > "$CB/state/clean-merged.txt"
( cd "$CB/repo" && RUN="$CB/state" "$SKILL_DIR/scripts/coverage-blind.sh" > /dev/null 2>&1 )
expect "coverage-blind.sh exits 0" test $? -eq 0
expect "empty input → empty coverage-blind.txt" test ! -s "$CB/state/coverage-blind.txt"

fi

if t "coverage-blind.sh's directory-match awk survives a backslash in \$d (ENVIRON, not -v)"; then
# Regression: the per-entry directory match was `awk -v d="$d" '... == d ...'`.
# `awk -v` ESCAPE-PROCESSES its assigned string (verified: a value of `foo\bar`
# arrives inside the awk program as `fooar` — `\b` is consumed as the backspace
# escape), so a directory name carrying a literal backslash byte (legal on POSIX
# filesystems) never equals the SAME string as it appears, unprocessed, in the
# `git ls-files` cache. The fix routes `d` through `d="$d" awk '... ENVIRON["d"]
# ...'` instead — the environment hands awk the bytes verbatim.
#
# NOT tested by driving `coverage-blind.sh` end-to-end against a real git-tracked
# backslash-carrying directory: `git ls-files` (called at line ~61 with no `-z`)
# unconditionally C-quotes any path containing a backslash — wraps it in `"..."`
# and doubles the backslash — regardless of `core.quotePath`. That is a SEPARATE,
# pre-existing defect in this script, out of this fix's scope. Verified
# empirically (both against the unpatched and the patched line ~90): a real
# `a\bc/thing.go` with a real sibling `a\bc/thing_test.go` is misclassified
# coverage-blind identically under BOTH versions, because the cached listing
# never contains the raw byte sequence to compare against `$d` either way — the
# quoting confound dominates and the two versions are indistinguishable through
# that path. A git-fixture test here would be green (or red) on both the buggy
# and the fixed code and prove nothing about this fix.
#
# So this exercises the exact awk PROGRAM the script runs (extracted from the
# live file, with a drift guard below) against a synthetic, UNQUOTED cache file
# — the shape the input would need to be in for the ENVIRON/-v choice to be the
# only variable — matching the format `git ls-files` produces for any path with
# no special characters.
AWK_PROG='{ i = match($0, "/[^/]*$"); if ((i ? substr($0, 1, i - 1) : ".") == ENVIRON["d"]) print (i ? substr($0, i + 1) : $0) }'
expect "drift guard: this test's awk program is byte-identical to the live line in coverage-blind.sh" \
  grep -qF -- "$AWK_PROG" "$SKILL_DIR/scripts/coverage-blind.sh"

ALLSYN=$SANDBOX/allfiles-synth.txt
printf 'a\\bc/thing.go\na\\bc/other.go\nother/thing.go\n' > "$ALLSYN"

GOT_NEW=$(d='a\bc' awk "$AWK_PROG" "$ALLSYN" | sort)
WANT=$(printf 'other.go\nthing.go')
if [[ "$GOT_NEW" = "$WANT" ]]; then
  pass "the live ENVIRON-based awk finds both siblings under a backslash-carrying directory"
else
  fail "the live ENVIRON-based awk finds both siblings under a backslash-carrying directory (got '$GOT_NEW', want '$WANT')"
fi

# Sanity check on the repro itself: the OLD `awk -v d="$d"` shape must NOT find
# them — if it did, this fixture would not be reproducing the historical bug at
# all, and the assertion above would be vacuous.
OLD_PROG='{ i = match($0, "/[^/]*$"); if ((i ? substr($0, 1, i - 1) : ".") == d) print (i ? substr($0, i + 1) : $0) }'
GOT_OLD=$(awk -v d='a\bc' "$OLD_PROG" "$ALLSYN" | sort)
if [[ "$GOT_OLD" != "$WANT" ]]; then
  pass "sanity: the old awk -v shape does NOT find the siblings (the repro is real, not vacuous)"
else
  fail "sanity: the old awk -v shape found the siblings too — this fixture does not reproduce the bug"
fi

fi

if t "coverage-blind.sh: a non-ASCII sibling test still covers its file (git ls-files unquoted)"; then
# git C-quotes any byte >= 0x80 in a path by default, so a sibling test with a
# non-ASCII name (café_test.go) arrives from `git ls-files` as "caf\303\251_test.go":
# its computed dirname no longer equals the raw $d, it drops out of the candidate
# pool, and the file it covers is over-reported coverage-blind. core.quotePath=false
# keeps the listing raw so the sibling is seen. (A backslash byte is a SEPARATE,
# out-of-scope quoting confound — see the ENVIRON test above — so this uses a
# non-ASCII UTF-8 name, which quotePath=false genuinely fixes.)
NA=$SANDBOX/coverage-blind-nonascii
mkdir -p "$NA/repo/pkg" && cd "$NA/repo" && git init -q -b main
printf 'x\n' > 'pkg/café.go'
printf 'x\n' > 'pkg/café_test.go'   # real sibling test with a non-ASCII name
printf 'x\n' > pkg/lonely.go        # control: no sibling -> stays blind
git add -A && git commit -qm fixtures
mkdir -p "$NA/state"
printf 'pkg/café.go\npkg/lonely.go\n' > "$NA/state/clean-merged.txt"
RUN="$NA/state" "$SKILL_DIR/scripts/coverage-blind.sh" > /dev/null 2> "$SANDBOX/cb-nonascii.log"
expect "coverage-blind.sh exits 0" test $? -eq 0
refute "a file whose only sibling test has a non-ASCII name is NOT over-reported blind" \
  grep -qxF -- 'pkg/café.go' "$NA/state/coverage-blind.txt"
expect "the control file with no sibling test is still blind" \
  grep -qxF -- 'pkg/lonely.go' "$NA/state/coverage-blind.txt"
cd "$SANDBOX"
fi

if t "coverage-blind.sh fails loudly when clean-merged.txt is missing"; then
rm -f "$CB/state/clean-merged.txt"
RUN="$CB/state" "$SKILL_DIR/scripts/coverage-blind.sh" > /dev/null 2> "$SANDBOX/cb-missing.log"
expect "missing clean-merged.txt exits non-zero" test $? -ne 0

cd "$SANDBOX"
fi

if t "coverage-blind.sh fails loudly when git ls-files fails, instead of over-reporting everything blind"; then
# Run outside any git repo: `git ls-files` fails, and an unchecked failure would
# leave $ALLFILES empty — every clean-merged entry would then classify blind
# regardless of the sibling tests it actually has (over-reporting, not silence).
NG=$SANDBOX/coverage-blind-nogit
mkdir -p "$NG/state"
printf 'pkg/widget.go\n' > "$NG/state/clean-merged.txt"
( cd "$NG" && RUN="$NG/state" "$SKILL_DIR/scripts/coverage-blind.sh" > /dev/null 2> "$SANDBOX/cb-nogit.log" )
expect "git ls-files failure exits non-zero" test $? -ne 0
expect "diagnostic names git ls-files as the failure" \
  grep -qi 'git ls-files' "$SANDBOX/cb-nogit.log"
refute "no coverage-blind.txt written on this failure" \
  test -s "$NG/state/coverage-blind.txt"

cd "$SANDBOX"
fi

finish_suite
