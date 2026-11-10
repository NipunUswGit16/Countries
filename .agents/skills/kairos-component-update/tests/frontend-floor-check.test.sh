#!/usr/bin/env bash
# frontend-floor-check.test.sh — tests for scripts/frontend-floor-check.sh
# Tested at the script seam: env in (RUN, FLOORS_TSV, FRONTEND_TEMPLATE,
# FRONTEND_SHA, FRONTEND_REPO, FRONTEND_CACHE) and the single stdout contract
# (one FLOOR_STATE line + any UNMET detail lines) + exit code, never internals.
# TEST_FILTER supported. Builds on lib.sh's setup_frontend_fixture (a linear
# BASE -> INTERMEDIATE -> TARGET frontend monorepo).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

FFC="$SKILL_DIR/scripts/frontend-floor-check.sh"
TAB=$(printf '\t')

# The frontend fixture: FRONTEND_REPO_DIR + FRONTEND_BASE/INTERMEDIATE/TARGET_SHA.
setup_frontend_fixture

# A divergent commit off BASE that TARGET never contained — the "not contained"
# lineage that must resolve to unmet (not unverified: the commit IS in the mirror,
# it is just not an ancestor of TARGET).
git -C "$FRONTEND_REPO_DIR" checkout -q -b fork "$FRONTEND_BASE_SHA"
printf 'fork-only change\n' > "$FRONTEND_REPO_DIR/template/react/fork.txt"
git -C "$FRONTEND_REPO_DIR" add -A >/dev/null 2>&1
git -C "$FRONTEND_REPO_DIR" commit -qm "fork commit off base" >/dev/null 2>&1
FRONTEND_FORK_SHA=$(git -C "$FRONTEND_REPO_DIR" rev-parse HEAD)
git -C "$FRONTEND_REPO_DIR" checkout -q main

OUT="$SANDBOX/ffc.out"
ERR="$SANDBOX/ffc.err"

# ffc <run> <floors_tsv> <template> <sha> <repo> <cache> -> OUT/ERR/RC
ffc() {
  RUN="$1" FLOORS_TSV="$2" FRONTEND_TEMPLATE="$3" FRONTEND_SHA="$4" \
    FRONTEND_REPO="$5" FRONTEND_CACHE="$6" "$FFC" > "$OUT" 2> "$ERR"
  RC=$?
}
state() { sed -n 's/^FLOOR_STATE=//p' "$OUT" | head -1; }
# floor_row <file> <module> <sha> — one TSV row on stdout.
floor_row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# =============================================================================
if t "empty floors table -> none, and no clone happens"; then
D=$SANDBOX/none-empty; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv; : > "$TSV"
CACHE=$D/cache
ffc "$RUN" "$TSV" react "$FRONTEND_TARGET_SHA" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=none" test "$(state)" = none
refute "no mirror was cloned" test -e "$CACHE"
fi

# =============================================================================
if t "missing floors file -> none"; then
D=$SANDBOX/none-missing; RUN=$D/state; mkdir -p "$RUN"
CACHE=$D/cache
ffc "$RUN" "$RUN/does-not-exist.tsv" react "$FRONTEND_TARGET_SHA" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=none" test "$(state)" = none
refute "no mirror was cloned" test -e "$CACHE"
fi

# =============================================================================
if t "module mismatch (solid floor, react component) -> none, and no clone happens"; then
D=$SANDBOX/none-module; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv
floor_row ".kairos-updates/20260115T000000-x.md" solid "$FRONTEND_BASE_SHA" > "$TSV"
CACHE=$D/cache
ffc "$RUN" "$TSV" react "$FRONTEND_TARGET_SHA" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=none (the react component ignores a solid floor)" test "$(state)" = none
refute "no mirror was cloned when no floor matches the module" test -e "$CACHE"
fi

# =============================================================================
if t "floor=BASE, frontend.sha=TARGET -> satisfied (TARGET contains BASE)"; then
D=$SANDBOX/satisfied; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv
floor_row ".kairos-updates/20260115T000000-app-export-renamed.md" react "$FRONTEND_BASE_SHA" > "$TSV"
CACHE=$D/cache
ffc "$RUN" "$TSV" react "$FRONTEND_TARGET_SHA" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=satisfied" test "$(state)" = satisfied
refute "no UNMET detail lines on a satisfied floor" grep -q '^UNMET' "$OUT"
fi

# =============================================================================
if t "floor=TARGET, frontend.sha=BASE -> unmet, with a UNMET detail line"; then
D=$SANDBOX/unmet; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv
UF=".kairos-updates/20260115T000000-app-export-renamed.md"
floor_row "$UF" react "$FRONTEND_TARGET_SHA" > "$TSV"
CACHE=$D/cache
ffc "$RUN" "$TSV" react "$FRONTEND_BASE_SHA" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=unmet" test "$(state)" = unmet
expect "an UNMET detail line names the file/module/sha" \
  grep -qF "UNMET${TAB}${UF}${TAB}react${TAB}${FRONTEND_TARGET_SHA}" "$OUT"
fi

# =============================================================================
if t "divergent lineage (fork commit off BASE) -> unmet, not unverified"; then
D=$SANDBOX/divergent; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv
floor_row ".kairos-updates/20260120T000000-fork.md" react "$FRONTEND_FORK_SHA" > "$TSV"
CACHE=$D/cache
# frontend.sha = TARGET, which never contained the fork commit -> not contained.
ffc "$RUN" "$TSV" react "$FRONTEND_TARGET_SHA" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=unmet (a divergent lineage does not contain the floor)" test "$(state)" = unmet
expect "the divergent floor is reported as UNMET" grep -q "^UNMET${TAB}" "$OUT"
fi

# =============================================================================
if t "multiple floors, one contained one not -> unmet with only the missing detail"; then
D=$SANDBOX/multi; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv
{ floor_row "a.md" react "$FRONTEND_BASE_SHA"      # contained by TARGET
  floor_row "b.md" react "$FRONTEND_FORK_SHA"; } > "$TSV"   # NOT contained by TARGET
CACHE=$D/cache
ffc "$RUN" "$TSV" react "$FRONTEND_TARGET_SHA" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=unmet (every declared floor must be contained)" test "$(state)" = unmet
expect "the missing floor (b.md) is reported" grep -q "^UNMET${TAB}b.md${TAB}" "$OUT"
refute "the contained floor (a.md) is NOT reported" grep -q "^UNMET${TAB}a.md${TAB}" "$OUT"
fi

# =============================================================================
if t "bogus FRONTEND_REPO (clone fails) -> unverified, never a false satisfied"; then
D=$SANDBOX/unverified-repo; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv
floor_row "x.md" react "$FRONTEND_BASE_SHA" > "$TSV"
CACHE=$D/cache
ffc "$RUN" "$TSV" react "$FRONTEND_TARGET_SHA" "file://$SANDBOX/does-not-exist-repo" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=unverified" test "$(state)" = unverified
refute "no UNMET detail lines on unverified" grep -q '^UNMET' "$OUT"
fi

# =============================================================================
if t "empty FRONTEND_SHA -> unverified, short-circuited BEFORE any clone"; then
D=$SANDBOX/unverified-sha; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv
floor_row "x.md" react "$FRONTEND_BASE_SHA" > "$TSV"
CACHE=$D/cache
ffc "$RUN" "$TSV" react "" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=unverified" test "$(state)" = unverified
refute "an empty frontend.sha is answered without paying for a clone" test -e "$CACHE"
fi

# =============================================================================
if t "on-demand clone: a matching floor creates FRONTEND_CACHE (bare mirror)"; then
D=$SANDBOX/ondemand; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv
floor_row "x.md" react "$FRONTEND_BASE_SHA" > "$TSV"
CACHE=$D/cache
refute "cache absent before the run" test -e "$CACHE"
ffc "$RUN" "$TSV" react "$FRONTEND_TARGET_SHA" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "FLOOR_STATE=satisfied" test "$(state)" = satisfied
expect "the mirror was cloned on demand" test -f "$CACHE/HEAD"
expect "the on-demand clone is a bare mirror" \
  test "$(git -C "$CACHE" config --get core.bare 2>/dev/null)" = true
fi

# =============================================================================
if t "reuse of a pre-seeded bare mirror -> not destroyed (sentinel survives)"; then
D=$SANDBOX/reuse; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv
floor_row "x.md" react "$FRONTEND_BASE_SHA" > "$TSV"
CACHE=$D/cache
git clone --mirror "file://$FRONTEND_REPO_DIR" "$CACHE" >/dev/null 2>&1
touch "$CACHE/SENTINEL-not-recloned"
ffc "$RUN" "$TSV" react "$FRONTEND_TARGET_SHA" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=satisfied from the reused mirror" test "$(state)" = satisfied
expect "the pre-seeded mirror was reused, not re-cloned (sentinel intact)" \
  test -f "$CACHE/SENTINEL-not-recloned"
fi

# =============================================================================
if t "containment guard: a working checkout at FRONTEND_CACHE is refused, never rm -rf'd"; then
D=$SANDBOX/guard; RUN=$D/state; mkdir -p "$RUN"
TSV=$RUN/frontend-floors.tsv
floor_row "x.md" react "$FRONTEND_BASE_SHA" > "$TSV"
# A real (non-bare) working checkout OUTSIDE $RUN — no top-level HEAD, core.bare=false.
CACHE=$D/live-checkout
mkdir -p "$CACHE" && git -C "$CACHE" init -q -b main
printf 'precious local work\n' > "$CACHE/precious.txt"
git -C "$CACHE" add -A >/dev/null 2>&1 && git -C "$CACHE" commit -qm work >/dev/null 2>&1
ffc "$RUN" "$TSV" react "$FRONTEND_TARGET_SHA" "file://$FRONTEND_REPO_DIR" "$CACHE"
expect "exit 0" test "$RC" -eq 0
expect "FLOOR_STATE=unverified (refused to touch a non-mirror cache)" test "$(state)" = unverified
expect "the working checkout's file survives" test -f "$CACHE/precious.txt"
expect "the refusal is explained on stderr" grep -q 'refusing to' "$ERR"
fi

finish_suite
