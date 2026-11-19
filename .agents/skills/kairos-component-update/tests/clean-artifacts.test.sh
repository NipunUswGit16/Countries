#!/usr/bin/env bash
# clean-artifacts.test.sh — tests for scripts/clean-artifacts.sh
# TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

CA="$SKILL_DIR/scripts/clean-artifacts.sh"

# mkrepo <dir> — a component work-tree with a .gitignore declaring disposable
# build output, one committed file, and the gitignored run-state dir present (as
# it is by Phase 4.5). Echoes the RUN dir.
mkrepo() {
  local d="$1"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main
    printf 'bin/\n*.test\ncoverage.out\ndist/\nnode_modules/\nvendor/\n.kairos/migration/state/\n' > .gitignore
    mkdir -p .kairos/migration/state
    git add .gitignore; git commit -qm init
  )
  echo "$d/.kairos/migration/state"
}

if t "clean-artifacts.sh — bad input is refused with exit 2"; then
D=$SANDBOX/ca-bad; RUN=$(mkrepo "$D")

RUN= ACTION=snapshot bash "$CA" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "unset RUN exits 2"; else fail "unset RUN exits 2 (rc=$rc)"; fi

RUN=/no/such/dir ACTION=snapshot bash "$CA" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "non-existent RUN exits 2"; else fail "non-existent RUN exits 2 (rc=$rc)"; fi

RUN=$RUN ACTION=bogus bash "$CA" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "unknown ACTION exits 2"; else fail "unknown ACTION exits 2 (rc=$rc)"; fi

# cwd not a git work-tree — snapshot must refuse, never rm blindly.
NG=$SANDBOX/ca-nogit; mkdir -p "$NG/state"
( cd "$NG" && RUN="$NG/state" ACTION=snapshot bash "$CA" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "cwd not a git work-tree exits 2"; else fail "cwd not a git work-tree exits 2 (rc=$rc)"; fi
fi

if t "clean-artifacts.sh — snapshot is write-once"; then
D=$SANDBOX/ca-once; RUN=$(mkrepo "$D")
( cd "$D" && RUN="$RUN" ACTION=snapshot bash "$CA" ) >/dev/null 2>&1
expect "snapshot writes pre-test-ignored.txt" test -f "$RUN/pre-test-ignored.txt"
# A file created AFTER the first snapshot must not enter a second snapshot: the
# second call keeps the first.
( cd "$D" && touch coverage.out && RUN="$RUN" ACTION=snapshot bash "$CA" ) > "$SANDBOX/once.out" 2>&1
expect "a second snapshot reports it kept the original" grep -q '^kept existing snapshot' "$SANDBOX/once.out"
refute "the polluting artifact did NOT enter the kept snapshot" \
  grep -qx 'coverage.out' "$RUN/pre-test-ignored.txt"
fi

if t "clean-artifacts.sh — clean removes only run-created ignored artifacts"; then
D=$SANDBOX/ca-clean; RUN=$(mkrepo "$D")
# Pre-existing ignored paths that must SURVIVE.
( cd "$D" && mkdir -p node_modules/pkg bin && echo dep > node_modules/pkg/i.js && echo old > bin/old )
( cd "$D" && RUN="$RUN" ACTION=snapshot bash "$CA" ) >/dev/null 2>&1
# The run produces artifacts.
( cd "$D" \
    && echo bin > server-binary \
    && echo t > unit.test \
    && echo c > coverage.out \
    && mkdir -p dist && echo b > dist/app.js \
    && echo new > bin/new )   # new file inside a PRE-EXISTING ignored dir
( cd "$D" && RUN="$RUN" ACTION=clean bash "$CA" ) > "$SANDBOX/clean.out" 2>&1

refute "an ignored .test file is removed" test -e "$D/unit.test"
refute "ignored coverage output is removed" test -e "$D/coverage.out"
refute "a brand-new ignored dir is removed whole" test -e "$D/dist"
expect "a NOT-ignored binary is left alone (git add -A's job, not ours)" test -e "$D/server-binary"
expect "a pre-existing ignored dir survives" test -e "$D/node_modules/pkg/i.js"
expect "a new file inside a pre-existing ignored dir survives (collapsed-entry tradeoff)" \
  test -e "$D/bin/new"
expect "the pre-existing file in that dir also survives" test -e "$D/bin/old"
expect "the summary line reports what was removed" grep -q '^cleaned: 3 removed' "$SANDBOX/clean.out"
fi

if t "clean-artifacts.sh — protected dirs are kept even when run-created"; then
D=$SANDBOX/ca-protect; RUN=$(mkrepo "$D")
( cd "$D" && RUN="$RUN" ACTION=snapshot bash "$CA" ) >/dev/null 2>&1
# A build step mints node_modules/ and vendor/ that did not exist at snapshot time.
( cd "$D" \
    && mkdir -p node_modules/x vendor/y && echo a > node_modules/x/a && echo b > vendor/y/b \
    && echo strip > junk.test )
( cd "$D" && RUN="$RUN" ACTION=clean bash "$CA" ) > "$SANDBOX/protect.out" 2>&1
expect "a run-created node_modules/ is kept (expensive to recreate)" test -e "$D/node_modules/x/a"
expect "a run-created vendor/ is kept" test -e "$D/vendor/y/b"
expect "the report names them as protected" grep -q 'kept (protected)' "$SANDBOX/protect.out"
refute "an ordinary artifact alongside them is still removed" test -e "$D/junk.test"
fi

if t "clean-artifacts.sh — the run-state dir under .kairos/ is never removed"; then
D=$SANDBOX/ca-state; RUN=$(mkrepo "$D")
( cd "$D" && RUN="$RUN" ACTION=snapshot bash "$CA" ) >/dev/null 2>&1
( cd "$D" && echo x > "$RUN/scratch.tmp" && echo t > drop.test )
( cd "$D" && RUN="$RUN" ACTION=clean bash "$CA" ) >/dev/null 2>&1
expect "the gitignored run state survives for post-mortem" test -f "$RUN/scratch.tmp"
expect "the snapshot file itself survives" test -f "$RUN/pre-test-ignored.txt"
refute "an ordinary artifact is still removed" test -e "$D/drop.test"
fi

if t "clean-artifacts.sh — clean with no snapshot is a SKIP, not a blind clean"; then
D=$SANDBOX/ca-nosnap; RUN=$(mkrepo "$D")
# Ignored artifacts exist but NO snapshot was ever taken (a legacy/pre-baseline run).
( cd "$D" && echo t > pre.test && mkdir -p node_modules && echo d > node_modules/d )
( cd "$D" && RUN="$RUN" ACTION=clean bash "$CA" ) > "$SANDBOX/nosnap.out" 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "clean with no snapshot exits 0 (best-effort, not a failure)"; else fail "clean with no snapshot exits 0 (rc=$rc)"; fi
expect "it reports a SKIP" grep -q '^SKIP:' "$SANDBOX/nosnap.out"
expect "and removes NOTHING without a snapshot to diff against" test -e "$D/pre.test"
expect "the pre-existing ignored dir is untouched too" test -e "$D/node_modules/d"
fi

if t "clean-artifacts.sh — an empty snapshot makes every current ignored path a delta"; then
# An empty pre-test snapshot means nothing was ignored before the run, so every
# ignored path now is run-created (protected dirs still excepted).
D=$SANDBOX/ca-empty; RUN=$(mkrepo "$D")
: > "$RUN/pre-test-ignored.txt"   # force an empty snapshot
( cd "$D" && echo t > only.test )
( cd "$D" && RUN="$RUN" ACTION=clean bash "$CA" ) >/dev/null 2>&1
refute "the artifact is removed against an empty snapshot" test -e "$D/only.test"
fi

if t "clean-artifacts.sh — snapshot and clean agree even when invoked from a subdir"; then
# Both actions pin cwd to the work-tree root, so a phase that happens to invoke
# from a subdirectory still lists/removes the whole component tree — not just the
# subtree it was called from. Without that, `git ls-files`'s cwd-relative,
# cwd-and-below listing would make the two captures disagree and mis-flag paths.
D=$SANDBOX/ca-subdir; RUN=$(mkrepo "$D")
( cd "$D" && mkdir -p sub/nested )
# Snapshot from one subdir; a run-created artifact then lands at the repo root.
( cd "$D/sub" && RUN="$RUN" ACTION=snapshot bash "$CA" ) >/dev/null 2>&1
expect "snapshot from a subdir still writes the snapshot" test -f "$RUN/pre-test-ignored.txt"
( cd "$D" && echo t > root.test && mkdir -p dist && echo b > dist/app.js )
# Clean from a DIFFERENT, deeper subdir must still reach the root artifacts.
( cd "$D/sub/nested" && RUN="$RUN" ACTION=clean bash "$CA" ) > "$SANDBOX/subdir.out" 2>&1
refute "a root-level .test is removed despite clean running from a nested subdir" test -e "$D/root.test"
refute "a root-level new ignored dir is removed too" test -e "$D/dist"
expect "the summary reports both removals" grep -q '^cleaned: 2 removed' "$SANDBOX/subdir.out"
fi

if t "clean-artifacts.sh — path-count messages report a single count on an empty snapshot"; then
# Regression: `grep -c . "$SNAP" || echo 0` doubled the "0" (grep -c itself
# prints "0" AND exits 1 on no match, then `|| echo 0` printed a second "0").
# Both messages that shell out to grep -c must report exactly one count.
D=$SANDBOX/ca-count; RUN=$(mkrepo "$D")
: > "$RUN/pre-test-ignored.txt"   # pre-seed an EMPTY snapshot (0 paths)
( cd "$D" && RUN="$RUN" ACTION=snapshot bash "$CA" ) > "$SANDBOX/count-kept.out" 2>&1
expect "'kept existing snapshot' reports exactly one 0, not two" \
  grep -qx 'kept existing snapshot (0 path(s))' "$SANDBOX/count-kept.out"

D2=$SANDBOX/ca-count-fresh; mkdir -p "$D2"; ( cd "$D2"
  git init -q -b main
  printf 'nothing-currently-matches/\n' > .gitignore
  git add .gitignore; git commit -qm init
)
RUN2="$D2/.kairos/migration/state"; mkdir -p "$RUN2"
( cd "$D2" && RUN="$RUN2" ACTION=snapshot bash "$CA" ) > "$SANDBOX/count-captured.out" 2>&1
expect "'captured' reports exactly one 0 when nothing is ignored yet" \
  grep -qx 'captured 0 ignored path(s)' "$SANDBOX/count-captured.out"
fi

if t "clean-artifacts.sh — NESTED node_modules/ and vendor/ are protected, not just root"; then
# The default frontend spelling is web/node_modules/, and a monorepo carries
# sub/vendor/ — both sit under a source dir git cannot collapse away, so git
# lists the nested ignored dir itself. The protected set mirrors gate.sh:528's
# root-and-nested arms, so these survive exactly like a root node_modules/.
D=$SANDBOX/ca-nested; mkdir -p "$D"; ( cd "$D"
  git init -q -b main
  printf 'node_modules/\nvendor/\n*.test\n.kairos/migration/state/\n' > .gitignore
  mkdir -p web sub .kairos/migration/state
  echo 'export const x = 1' > web/index.ts   # tracked source keeps web/ un-collapsed
  echo 'package sub'        > sub/keep.go     # tracked source keeps sub/ un-collapsed
  git add .gitignore web/index.ts sub/keep.go; git commit -qm init
)
RUN="$D/.kairos/migration/state"
( cd "$D" && RUN="$RUN" ACTION=snapshot bash "$CA" ) >/dev/null 2>&1
# A build mints deps under the source dirs AFTER the snapshot, plus a stray artifact.
( cd "$D" \
    && mkdir -p web/node_modules/pkg sub/vendor/y \
    && echo dep > web/node_modules/pkg/a.js \
    && echo dep > sub/vendor/y/b.go \
    && echo t   > stray.test )
( cd "$D" && RUN="$RUN" ACTION=clean bash "$CA" ) > "$SANDBOX/nested.out" 2>&1
expect "a nested web/node_modules/ survives" test -e "$D/web/node_modules/pkg/a.js"
expect "a nested sub/vendor/ survives"       test -e "$D/sub/vendor/y/b.go"
expect "the report names web/node_modules/ as protected" \
  grep -q 'kept (protected): web/node_modules/' "$SANDBOX/nested.out"
expect "the report names sub/vendor/ as protected" \
  grep -q 'kept (protected): sub/vendor/' "$SANDBOX/nested.out"
refute "an ordinary artifact alongside them is still removed" test -e "$D/stray.test"
fi

if t "clean-artifacts.sh — a git-listing failure FAILS the snapshot, never captures an empty set"; then
# Regression (fail-closed): list_ignored ends in `| sort -u`; without pipefail a
# git ls-files failure (exit 128) was masked by sort's exit 0, so the snapshot
# recorded an EMPTY set and every pre-existing ignored path then read as
# run-created and was deleted at Phase 8. A corrupt index must instead surface as
# the FAIL exit with NO snapshot written.
D=$SANDBOX/ca-gitfail; RUN=$(mkrepo "$D")
# Pre-existing ignored paths that an empty snapshot would later condemn.
( cd "$D" && mkdir -p node_modules && echo dep > node_modules/d && echo t > pre.test )
printf 'garbage' > "$D/.git/index"   # corrupt index → git ls-files exits 128
( cd "$D" && RUN="$RUN" ACTION=snapshot bash "$CA" ) > "$SANDBOX/gitfail.out" 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "a git-listing failure exits 2 (FAIL), not 0"; else fail "a git-listing failure exits 2 (rc=$rc)"; fi
expect "it reports the listing failure" grep -q '^FAIL: could not list ignored paths' "$SANDBOX/gitfail.out"
refute "no snapshot file is written on a failed listing" test -e "$RUN/pre-test-ignored.txt"
fi

if t "clean-artifacts.sh — pre-existing user content that becomes ignored mid-run is NOT deleted"; then
# Regression: a path untracked-and-NOT-ignored at snapshot time (the user's own
# docs/generated/), that a template-introduced .gitignore rule starts matching
# during the run, was in the Phase 8 delta (ignored-now, absent-from-snapshot) and
# got rm -rf'd — the user's content, which `git add -A` never staged. The snapshot
# now also records the untracked-not-ignored set, and clean protects it.
D=$SANDBOX/ca-newignore; RUN=$(mkrepo "$D")
# User content present BEFORE the run, untracked and not yet ignored.
( cd "$D" && mkdir -p docs/generated && echo mine > docs/generated/report.html && echo note > keep.txt )
# Phase 4.5 snapshot — captures both the ignored set and the untracked-not-ignored set.
( cd "$D" && RUN="$RUN" ACTION=snapshot bash "$CA" ) >/dev/null 2>&1
expect "the untracked-not-ignored snapshot is written" test -f "$RUN/pre-test-untracked.txt"
expect "pre-existing user content is recorded in it (dir may collapse to docs/)" grep -q '^docs/' "$RUN/pre-test-untracked.txt"
# The run introduces a .gitignore rule that now matches the pre-existing content,
# and drops a genuine build artifact too.
( cd "$D" && printf 'docs/generated/\n' >> .gitignore && git add -A && git commit -qm "ignore generated docs" \
    && touch stray.test )
# Phase 8 clean.
( cd "$D" && RUN="$RUN" ACTION=clean bash "$CA" ) > "$SANDBOX/newignore.out" 2>&1
expect "the newly-ignored user content SURVIVES" test -e "$D/docs/generated/report.html"
expect "clean reports it kept the pre-existing content" \
  grep -q 'kept (pre-existing user content newly ignored): docs/generated/' "$SANDBOX/newignore.out"
refute "the genuine run-created artifact is still removed" test -e "$D/stray.test"
fi

if t "clean-artifacts.sh — a NEW ignored path created mid-run inside a newly-ignored NAME is still removed"; then
# Guard against over-protecting: a directory name that did NOT exist at snapshot
# time (so is absent from the untracked snapshot) is a genuine run artifact and
# must still be removed, even if a same-named prefix appears nowhere in the snapshot.
D=$SANDBOX/ca-newdir; RUN=$(mkrepo "$D")
( cd "$D" && echo note > keep.txt )
( cd "$D" && RUN="$RUN" ACTION=snapshot bash "$CA" ) >/dev/null 2>&1
( cd "$D" && printf 'build/\n' >> .gitignore && git add -A && git commit -qm ignore-build \
    && mkdir -p build && echo out > build/artifact )
( cd "$D" && RUN="$RUN" ACTION=clean bash "$CA" ) > "$SANDBOX/newdir.out" 2>&1
refute "a run-created ignored dir absent from the snapshot IS removed" test -e "$D/build"
expect "clean reports it removed" grep -q '^  removed: build/' "$SANDBOX/newdir.out"
fi

finish_suite
