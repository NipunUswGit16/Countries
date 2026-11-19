#!/usr/bin/env bash
# extract-template-gomod.sh — the format owner for $RUN/template-go.mod: the
# template's `go.mod` as of TARGET, which is where the common-library version
# resolution reads the versions the template pins.
#
# WHY this script exists: it was a prose one-liner —
#   git -C "$CACHE" show "$TARGET:go.mod" > "$RUN/template-go.mod"
# — parsed by TWO scripts (codev-check.sh, and wrong-target-check.sh, which reads it
# as `$RUN/template-go.mod` directly). Both mentions under scripts/ are READS, so the
# artifact-writer lint could not see the gap until the check learned to tell a writer
# from a reader.
#
# WHY it is not merely tidiness — the fail-open. A shell redirect CREATES the file
# before the command runs, so a bad ref, an empty cache, or a TARGET carrying no
# go.mod left a ZERO-BYTE template-go.mod behind and the pipeline continued. Both
# consumers then read it happily as "no requires, no replaces": codev-check reports no
# co-development, and wrong-target-check's tripwire — whose entire job is to catch a
# wrong TARGET — reports clear. A wrong ref disarmed the check that exists to catch a
# wrong ref. So this script extracts to a temp file, verifies it looks like a go.mod
# (a `module ` line), and only then installs it: a refusal leaves any previous good
# extraction byte-identical and writes no empty file at all.
#
# In :  RUN        run-state dir (required). Created if missing.
#       CACHE      the template mirror clone (required).
#       TARGET     the resolved target SHA (required).
#       PHASE_KEY  proof-of-load key stated in phases/3.5-collect-common.md.
# Out:  $RUN/template-go.mod   the go.mod at TARGET. Re-run safe (byte-identical).
# Exit: 0 done
#       1 PHASE_KEY missing/wrong
#       2 bad input, an unresolvable TARGET:go.mod, or output that is not a go.mod
set -u

[[ "${PHASE_KEY:-}" = "9059z5gm" ]] \
  || { echo "FAIL: load phases/3.5-collect-common.md first" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 2; }

RUN="${RUN:-}"; CACHE="${CACHE:-}"; TARGET="${TARGET:-}"
[[ -n "$RUN" ]]    || fail "RUN required (the run-state dir)"
[[ -n "$CACHE" ]]  || fail "CACHE required (the template mirror clone)"
[[ -n "$TARGET" ]] || fail "TARGET required (the resolved target SHA)"

mkdir -p "$RUN" || fail "cannot create $RUN"
OUT="$RUN/template-go.mod"

TMP=$(mktemp "$RUN/.template-go.mod.XXXXXX") || fail "cannot create a temp file in $RUN"
trap 'rm -f "$TMP"' EXIT

git -C "$CACHE" show "$TARGET:go.mod" > "$TMP" 2>/dev/null \
  || fail "cannot read go.mod at $TARGET in $CACHE — check the target SHA and that the mirror is up to date"

# An empty or shapeless extraction must never reach the consumers: they would read
# it as a go.mod with no requires and no replaces, which is a valid-looking answer.
[[ -s "$TMP" ]] \
  || fail "the go.mod extracted at $TARGET is empty — refusing to install it (both readers would score it as 'no requires, no replaces')"
grep -qE '^module[[:space:]]+[^[:space:]]+' "$TMP" \
  || fail "the file extracted at $TARGET:go.mod carries no 'module' line — refusing to install it as a go.mod"

mv "$TMP" "$OUT" || fail "could not write $OUT"
trap - EXIT
