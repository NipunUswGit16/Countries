#!/usr/bin/env bash
# guard-binaries.test.sh — tests for scripts/guard-binaries.sh, the tripwire that
# refuses run-created binary blobs into migration history (Phase 7 per-commit /
# Phase 8 range backstop). TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

G="$SKILL_DIR/scripts/guard-binaries.sh"

# bin <label> <path> — write a file git will classify as BINARY. Git's heuristic
# keys on a NUL byte in the content, so a plausible-looking ELF string with no NUL
# is TEXT and the guard (correctly) ignores it — the fixture must carry a NUL.
bin() { mkdir -p "$(dirname "$2")"; printf '\x7fELF\x02\x01\x00%s\x00\x00end' "$1" > "$2"; }

# mkrepo <dir> — a component work-tree with one committed text file, one committed
# BINARY asset (to prove pre-existing binaries are never flagged), and a
# .gitignore. Echoes "<dir> <BASE_SHA>".
mkrepo() {
  local d="$1"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main
    printf 'bin/\n*.test\n' > .gitignore
    printf 'package main\n' > main.go
    bin logo assets/logo.png
    git add -A; git commit -qm base
  )
  echo "$d $(cd "$d" && git rev-parse HEAD)"
}

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — bad input is refused with exit 2"; then
read -r D BASE < <(mkrepo "$SANDBOX/gb-bad")

( cd "$D" && MODE=staged bash "$G" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "unset BASE exits 2"; else fail "unset BASE exits 2 (rc=$rc)"; fi

( cd "$D" && MODE=staged BASE=deadbeefdeadbeef bash "$G" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "unresolvable BASE exits 2"; else fail "unresolvable BASE exits 2 (rc=$rc)"; fi

( cd "$D" && MODE=bogus BASE="$BASE" bash "$G" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "unknown MODE exits 2"; else fail "unknown MODE exits 2 (rc=$rc)"; fi

( cd "$D" && MODE=range BASE="$BASE" SAFE_EXTRA=nope bash "$G" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "unresolvable SAFE_EXTRA exits 2"; else fail "unresolvable SAFE_EXTRA exits 2 (rc=$rc)"; fi

NG=$SANDBOX/gb-nogit; mkdir -p "$NG"
( cd "$NG" && MODE=staged BASE="$BASE" bash "$G" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "cwd not a git work-tree exits 2"; else fail "cwd not a git work-tree exits 2 (rc=$rc)"; fi
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — staged: a new binary blob is flagged, text is not"; then
read -r D BASE < <(mkrepo "$SANDBOX/gb-staged")
( cd "$D"
  bin srv server                      # run-created binary, absent at base
  printf 'more\n' >> main.go          # a legit text edit alongside it
  git add -A )
( cd "$D" && MODE=staged BASE="$BASE" bash "$G" ) > "$SANDBOX/gbs.out" 2>&1; rc=$?
if [[ "$rc" -eq 3 ]]; then pass "a staged run-created binary exits 3"; else fail "exit 3 expected (rc=$rc)"; fi
expect "the flagged path is named" grep -qx 'server' "$SANDBOX/gbs.out"
refute "the text edit is NOT named" grep -qx 'main.go' "$SANDBOX/gbs.out"
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — staged: text build output is out of scope (binary-only)"; then
read -r D BASE < <(mkrepo "$SANDBOX/gb-text")
( cd "$D" && printf 'mode: count\nmain.go:1\n' > coverage.out && git add -A )   # text
( cd "$D" && MODE=staged BASE="$BASE" bash "$G" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "a text artifact is not flagged (exit 0)"; else fail "text artifact wrongly flagged (rc=$rc)"; fi
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — staged: modifying a pre-existing tracked binary is clean"; then
read -r D BASE < <(mkrepo "$SANDBOX/gb-mod")
( cd "$D" && bin logo2 assets/logo.png && git add -A )   # present at base -> allowed
( cd "$D" && MODE=staged BASE="$BASE" bash "$G" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "modifying a base-tracked binary exits 0"; else fail "exit 0 expected (rc=$rc)"; fi
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — staged: DELETING a run-created binary is not flagged"; then
read -r D BASE < <(mkrepo "$SANDBOX/gb-del")
( cd "$D" && bin srv server && git add -A && git commit -qm t1 && git rm -q server )
( cd "$D" && MODE=staged BASE="$BASE" bash "$G" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "a staged binary DELETION exits 0"; else fail "deletion wrongly flagged (rc=$rc)"; fi
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — ALLOW exempts a user-approved binary path"; then
read -r D BASE < <(mkrepo "$SANDBOX/gb-allow")
( cd "$D" && bin tool tool.bin && git add -A )
( cd "$D" && MODE=staged BASE="$BASE" bash "$G" ) >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "unapproved binary exits 3" || fail "unapproved binary should exit 3"
( cd "$D" && mkdir -p .kairos && printf 'tool.bin\n' > .kairos/allow.txt \
  && MODE=staged BASE="$BASE" ALLOW=".kairos/allow.txt" bash "$G" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "an ALLOW-listed binary exits 0"; else fail "ALLOW exemption failed (rc=$rc)"; fi
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — range: catches a committed binary across the range"; then
read -r D BASE < <(mkrepo "$SANDBOX/gb-range")
( cd "$D" && mkdir -p .kairos/migration/state
  bin srv server && git add -A && git commit -qm t1
  printf 'x\n' >> main.go && git add -A && git commit -qm t2 )   # binary persists to HEAD
( cd "$D" && RUN=.kairos/migration/state MODE=range BASE="$BASE" bash "$G" ) > "$SANDBOX/gbr.out" 2>&1; rc=$?
if [[ "$rc" -eq 3 ]]; then pass "a range-committed binary exits 3"; else fail "exit 3 expected (rc=$rc)"; fi
expect "the committed path is named on stdout" grep -qx 'server' "$SANDBOX/gbr.out"
expect "the flagged path is persisted to committed-binaries.txt" \
  grep -qx 'server' "$D/.kairos/migration/state/committed-binaries.txt"
( cd "$D" && MODE=range BASE="$BASE" bash "$G" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "range without RUN exits 2"; else fail "range needs RUN (rc=$rc)"; fi
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — range: SAFE_EXTRA (structural) excludes a template asset"; then
read -r D BASE < <(mkrepo "$SANDBOX/gb-safe")
# A binary adopted at the "structural" commit (a template asset) must not be
# re-flagged by the range backstop; a binary added AFTER it must still be caught.
( cd "$D" && mkdir -p .kairos/migration/state
  bin tmpl vendored.bin && git add -A && git commit -qm structural )
STRUCT=$( cd "$D" && git rev-parse HEAD )
( cd "$D" && bin run leaked.bin && git add -A && git commit -qm task )
( cd "$D" && RUN=.kairos/migration/state MODE=range BASE="$BASE" SAFE_EXTRA="$STRUCT" bash "$G" ) > "$SANDBOX/gbe.out" 2>&1; rc=$?
if [[ "$rc" -eq 3 ]]; then pass "the post-structural binary still exits 3"; else fail "exit 3 expected (rc=$rc)"; fi
expect "the run-created blob is named" grep -qx 'leaked.bin' "$SANDBOX/gbe.out"
refute "the structural template asset is NOT named" grep -qx 'vendored.bin' "$SANDBOX/gbe.out"
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — nested path from a subdir cwd is reported root-relative"; then
# The frontend case: Phase 7 commits at the mount (web/). The guard must pin cwd
# to the repo root so numstat and the tree lookups agree, and report web/-prefixed.
read -r D BASE < <(mkrepo "$SANDBOX/gb-mount")
( cd "$D" && mkdir -p web && bin dist web/dist.bin && git add -A )
( cd "$D/web" && MODE=staged BASE="$BASE" bash "$G" ) > "$SANDBOX/gbm.out" 2>&1; rc=$?
if [[ "$rc" -eq 3 ]]; then pass "a mount-dir binary exits 3 from the subdir cwd"; else fail "exit 3 expected (rc=$rc)"; fi
expect "the path is reported root-relative (web/dist.bin)" grep -qx 'web/dist.bin' "$SANDBOX/gbm.out"
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — clean tree exits 0 silently"; then
read -r D BASE < <(mkrepo "$SANDBOX/gb-clean")
( cd "$D" && printf 'more\n' >> main.go && git add -A )
( cd "$D" && MODE=staged BASE="$BASE" bash "$G" ) > "$SANDBOX/gbc.out" 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "a clean staged set exits 0"; else fail "exit 0 expected (rc=$rc)"; fi
refute "nothing is printed to stdout on a clean run" test -s "$SANDBOX/gbc.out"
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — range: a binary added then removed WITHIN the range is still flagged"; then
# Regression: the range backstop used a NET `diff BASE HEAD`, so a binary added in
# one checkpoint commit and removed in a later one — absent at both endpoints, yet
# still living in the intermediate commit object that the default (checkpoints kept)
# pushes — never appeared in the diff and rode into history unflagged. The scan now
# walks every commit's ADDS across the range, so the add is caught from its commit.
read -r D BASE < <(mkrepo "$SANDBOX/gb-intermediate")
( cd "$D" && mkdir -p .kairos/migration/state
  bin junk throwaway.bin && git add -A && git commit -qm t3     # add a compiled blob
  git rm -q throwaway.bin && git commit -qm t5 )                # remove it before HEAD
( cd "$D" && RUN=.kairos/migration/state MODE=range BASE="$BASE" bash "$G" ) > "$SANDBOX/gbi.out" 2>&1; rc=$?
if [[ "$rc" -eq 3 ]]; then pass "an intermediate-only binary exits 3"; else fail "exit 3 expected (rc=$rc)"; fi
expect "the intermediate-only blob is named" grep -qx 'throwaway.bin' "$SANDBOX/gbi.out"
expect "it is persisted to committed-binaries.txt" \
  grep -qx 'throwaway.bin' "$D/.kairos/migration/state/committed-binaries.txt"
fi

# ---------------------------------------------------------------------------------
if t "guard-binaries.sh — range: DELETING a pre-existing BASE binary is NOT flagged"; then
# Control against over-broadening: a binary tracked at BASE (a component asset) that
# the run removes must stay clean — it is a good deletion, not a run-created add. The
# adds-only scan never lists a deletion, and the BASE exemption would exclude it anyway.
read -r D BASE < <(mkrepo "$SANDBOX/gb-basedel")
( cd "$D" && mkdir -p .kairos/migration/state
  git rm -q assets/logo.png && git commit -qm "drop the old asset" )
( cd "$D" && RUN=.kairos/migration/state MODE=range BASE="$BASE" bash "$G" ) > "$SANDBOX/gbbd.out" 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "removing a pre-existing BASE binary exits 0"; else fail "exit 0 expected (rc=$rc)"; fi
refute "nothing is flagged" grep -qx 'assets/logo.png' "$SANDBOX/gbbd.out"
fi

finish_suite
