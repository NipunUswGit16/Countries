#!/usr/bin/env bash
# apply-ask-user.test.sh — tests for scripts/apply-ask-user.sh
# TEST_FILTER supported (every block builds its own fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

AAU="$SKILL_DIR/scripts/apply-ask-user.sh"

# Fixture: a synthetic repo with a kairos-target tag (the enactment source) and
# a component tree with a RUN dir. The classified ask-user set exercises all
# three buckets plus the classification.tsv/binaries.txt union:
#   logo.bin   binary-for-user in classification AND in binaries.txt (de-dup)
#   extra.bin  binaries.txt ONLY (the local safety net contributes to the set)
#   bigdir/*, cmd/worker/main.go   added-heavyweight-ask-user (per-file rows)
#   legacy/*   deleted-heavyweight-ask-user
# Both binaries carry NUL and CRLF bytes so byte-exactness (no LF
# normalization) is actually asserted, not vacuously true on text.

# The classification/SYNTH binding build-manifest.sh stamps: the TREE oids of the
# two side tags classification.tsv was derived from. apply-ask-user.sh refuses to
# enact against any other trees — the same refusal structural-merge.sh makes — so
# every fixture needs the sidecar, and any fixture that re-tags $SYNTH has to
# re-stamp it or it is asserting drift by accident.
stamp_ctrees() { # stamp_ctrees — write $RUN/classification-trees.tsv from $SYNTH's tags
  printf 'base\t%s\ntarget\t%s\n' \
    "$(git -C "$SYNTH" rev-parse --verify --quiet 'kairos-base^{tree}' || echo none)" \
    "$(git -C "$SYNTH" rev-parse --verify --quiet "$TARGET_TAG^{tree}" || echo none)" \
    > "$RUN/classification-trees.tsv"
}
TARGET_TAG=${TARGET_TAG:-kairos-target}

make_aau_fixture() { # make_aau_fixture <name> — sets SYNTH/COMP/RUN, cd $COMP
  local name="$1"
  SYNTH=$SANDBOX/$name-synth
  mkdir -p "$SYNTH" && cd "$SYNTH" && git init -q -b main
  # Both side tags: a real $SYNTH always carries base and target, and the binding
  # check reads a tree oid for each.
  git commit -q --allow-empty -m base && git tag kairos-base
  printf 'BIN\0TARGET\r\nv2\r\n' > logo.bin
  printf 'EXTRA\0TARGET\r\n' > extra.bin
  mkdir -p bigdir cmd/worker
  printf 'aye\n' > bigdir/a.txt
  printf 'bee\n' > bigdir/b.txt
  printf 'package main\n\nfunc main() {}\n' > cmd/worker/main.go
  git add -A && git commit -qm target
  git tag kairos-target

  COMP=$SANDBOX/$name-comp
  RUN=$COMP/.run
  mkdir -p "$COMP/legacy" "$RUN"
  cd "$COMP"
  printf 'BIN\0OURS\r\nv1\r\n' > logo.bin
  printf 'EXTRA\0OURS\r\n' > extra.bin
  for f in x y z; do echo "legacy $f" > "legacy/$f.txt"; done
  cp logo.bin "$SANDBOX/$name-logo.ours"
  cp extra.bin "$SANDBOX/$name-extra.ours"
  {
    printf 'merge-pipeline\tM\tkept.txt\tkept.txt\n'
    printf 'binary-for-user\tM\tlogo.bin\tlogo.bin\n'
    printf 'added-heavyweight-ask-user\tA\tbigdir/a.txt\tbigdir/a.txt\n'
    printf 'added-heavyweight-ask-user\tA\tbigdir/b.txt\tbigdir/b.txt\n'
    printf 'added-heavyweight-ask-user\tA\tcmd/worker/main.go\tcmd/worker/main.go\n'
    printf 'deleted-heavyweight-ask-user\tD\tlegacy/x.txt\tlegacy/x.txt\n'
    printf 'deleted-heavyweight-ask-user\tD\tlegacy/y.txt\tlegacy/y.txt\n'
    printf 'deleted-heavyweight-ask-user\tD\tlegacy/z.txt\tlegacy/z.txt\n'
  } > "$RUN/classification.tsv"
  printf 'logo.bin\nextra.bin\n' > "$RUN/binaries.txt"
  export SYNTH RUN
  stamp_ctrees
}

# The full decision set for the fixture above. bigdir is a CHERRY-PICK: the
# user's "take a.txt, skip b.txt" arrives as plain per-file rows — no grouped
# special case exists for the enactor to mishandle.
write_full_decisions() {
  {
    printf 'binary-for-user\tlogo.bin\ttheirs\n'
    printf 'binary-for-user\textra.bin\tours\n'
    printf 'added-heavyweight-ask-user\tbigdir/a.txt\ttake\n'
    printf 'added-heavyweight-ask-user\tbigdir/b.txt\tskip\n'
    printf 'added-heavyweight-ask-user\tcmd/worker/main.go\ttake\n'
    printf 'deleted-heavyweight-ask-user\tlegacy/x.txt\tdelete\n'
    printf 'deleted-heavyweight-ask-user\tlegacy/y.txt\tdelete\n'
    printf 'deleted-heavyweight-ask-user\tlegacy/z.txt\tkeep\n'
  } > "$RUN/ask-user-decisions.tsv"
}

if t "apply-ask-user.sh enacts every decision value (cherry-pick as per-file rows)"; then
make_aau_fixture full
write_full_decisions
PHASE_KEY=$PK_STRUCTURAL "$AAU" > "$SANDBOX/aau.out" 2> "$SANDBOX/aau.log"
expect "apply-ask-user.sh exits 0 on a complete decision set" test $? -eq 0

# theirs — byte-exact on a FIXTURE BINARY, never LF-normalized.
git -C "$SYNTH" cat-file blob kairos-target:logo.bin > "$SANDBOX/logo.want"
expect "theirs lands the target blob BYTE-EXACT (binary with NUL + CRLF)" \
  cmp -s logo.bin "$SANDBOX/logo.want"
expect "the written binary still carries CR bytes (no LF normalization)" \
  bash -c "LC_ALL=C grep -q \$'\r' logo.bin"
refute "theirs really replaced ours (not a silent keep)" \
  cmp -s logo.bin "$SANDBOX/full-logo.ours"

# ours — tree untouched.
expect "ours keeps the component's blob untouched" \
  cmp -s extra.bin "$SANDBOX/full-extra.ours"

# take / skip — the cherry-pick: a.txt lands, b.txt does not.
expect "take lands the heavyweight file, parent dirs created" test -f bigdir/a.txt
expect "taken file carries the target's content" grep -qx aye bigdir/a.txt
refute "skip leaves the cherry-picked-away file absent" test -e bigdir/b.txt
expect "take creates nested parent dirs (cmd/worker/)" test -f cmd/worker/main.go

# delete / keep — removal plus the confirmed-deletes bookkeeping.
refute "delete removes legacy/x.txt" test -e legacy/x.txt
refute "delete removes legacy/y.txt" test -e legacy/y.txt
expect "keep leaves legacy/z.txt in place" test -f legacy/z.txt
expect "delete appends legacy/x.txt to confirmed-deletes.txt" \
  grep -qxF legacy/x.txt "$RUN/confirmed-deletes.txt"
expect "delete appends legacy/y.txt to confirmed-deletes.txt" \
  grep -qxF legacy/y.txt "$RUN/confirmed-deletes.txt"
refute "keep is NOT recorded as a confirmed delete" \
  grep -qxF legacy/z.txt "$RUN/confirmed-deletes.txt"

# Applied rows — one per decision row, no-ops included (silence is never a record).
expect "ask-user-applied.tsv was written" test -f "$RUN/ask-user-applied.tsv"
APPLIED_N=$(grep -c . "$RUN/ask-user-applied.tsv" || true)
if [[ "$APPLIED_N" -eq 8 ]]; then
  pass "applied TSV has one row per decision row (8)"
else
  fail "applied TSV has $APPLIED_N rows (want 8)"
fi
expect "theirs row carries outcome 'written'" \
  grep -qx $'binary-for-user\tlogo.bin\ttheirs\twritten' "$RUN/ask-user-applied.tsv"
expect "no-op ours still writes an applied row (outcome 'unchanged')" \
  grep -qx $'binary-for-user\textra.bin\tours\tunchanged' "$RUN/ask-user-applied.tsv"
expect "no-op skip still writes an applied row" \
  grep -qx $'added-heavyweight-ask-user\tbigdir/b.txt\tskip\tunchanged' "$RUN/ask-user-applied.tsv"
expect "no-op keep still writes an applied row" \
  grep -qx $'deleted-heavyweight-ask-user\tlegacy/z.txt\tkeep\tunchanged' "$RUN/ask-user-applied.tsv"
expect "delete row carries outcome 'deleted'" \
  grep -qx $'deleted-heavyweight-ask-user\tlegacy/x.txt\tdelete\tdeleted' "$RUN/ask-user-applied.tsv"
expect "the summary tallies the outcomes" \
  grep -q '3 written, 3 unchanged, 2 deleted' "$SANDBOX/aau.log"

fi

if t "re-running the same TSV is a no-op (same tree, applied rewritten not appended)"; then
# A redone Phase 5 or a retried step must converge, not compound.
make_aau_fixture rerun
write_full_decisions
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2>&1
expect "the first run exits 0" test $? -eq 0
git -C "$SYNTH" cat-file blob kairos-target:logo.bin > "$SANDBOX/rerun-logo.want"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-rerun.log"
expect "the re-run exits 0" test $? -eq 0
expect "the re-run lands the identical theirs blob" cmp -s logo.bin "$SANDBOX/rerun-logo.want"
expect "ours side still untouched" cmp -s extra.bin "$SANDBOX/rerun-extra.ours"
refute "skipped file still absent" test -e bigdir/b.txt
refute "deleted file still absent" test -e legacy/x.txt
expect "kept file still present" test -f legacy/z.txt
APPLIED_N=$(grep -c . "$RUN/ask-user-applied.tsv" || true)
if [[ "$APPLIED_N" -eq 8 ]]; then
  pass "applied TSV rewritten, not appended (still 8 rows)"
else
  fail "applied TSV has $APPLIED_N rows after re-run (want 8 — rewritten, not appended)"
fi
CD_N=$(grep -c . "$RUN/confirmed-deletes.txt" || true)
if [[ "$CD_N" -eq 2 ]]; then
  pass "confirmed-deletes.txt append is idempotent (still 2 lines)"
else
  fail "confirmed-deletes.txt has $CD_N lines after re-run (want 2 — no duplicates)"
fi

fi

if t "an incomplete decision set exits 1, names each MISSING item, writes NO applied rows"; then
make_aau_fixture incomplete
# Two classified paths have no row: extra.bin (from binaries.txt — the union
# must count it) and legacy/z.txt. The provided take/theirs rows must NOT be
# enacted either: half-answered means nothing happens.
{
  printf 'binary-for-user\tlogo.bin\ttheirs\n'
  printf 'added-heavyweight-ask-user\tbigdir/a.txt\ttake\n'
  printf 'added-heavyweight-ask-user\tbigdir/b.txt\tskip\n'
  printf 'added-heavyweight-ask-user\tcmd/worker/main.go\ttake\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/x.txt\tdelete\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/y.txt\tdelete\n'
} > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-inc.log"
INC_RC=$?
if [[ "$INC_RC" -eq 1 ]]; then pass "incomplete set exits 1"; else fail "incomplete set exited $INC_RC (want 1)"; fi
MISS_N=$(grep -c '^MISSING: ' "$SANDBOX/aau-inc.log" || true)
if [[ "$MISS_N" -eq 2 ]]; then
  pass "one MISSING: line per undecided item (2)"
else
  fail "$MISS_N MISSING: lines (want 2)"
fi
expect "MISSING names the binaries.txt-only path as <bucket>:<path>" \
  grep -qx 'MISSING: binary-for-user:extra.bin' "$SANDBOX/aau-inc.log"
expect "MISSING names the undecided delete as <bucket>:<path>" \
  grep -qx 'MISSING: deleted-heavyweight-ask-user:legacy/z.txt' "$SANDBOX/aau-inc.log"
refute "the merge-pipeline row never demands a decision" \
  grep -q 'kept.txt' "$SANDBOX/aau-inc.log"
refute "NO applied rows are written on refusal" test -e "$RUN/ask-user-applied.tsv"
expect "the refusal enacted NOTHING: theirs not written" cmp -s logo.bin "$SANDBOX/incomplete-logo.ours"
refute "the refusal enacted NOTHING: take not landed" test -e bigdir/a.txt
expect "the refusal enacted NOTHING: delete not removed" test -f legacy/x.txt
refute "the refusal enacted NOTHING: no confirmed-deletes append" \
  test -e "$RUN/confirmed-deletes.txt"

fi

if t "a validation refusal removes a stale prior ask-user-applied.tsv (gate must fail closed on ANY refused re-answer)"; then
# A Phase 5 redo restores the tree with `git checkout -- . && git clean -fd`,
# which spares the gitignored $RUN — so a COMPLETE ask-user-applied.tsv from a
# prior (since-rolled-back) enactment can survive into a re-answer attempt.
# Seed exactly that: a complete, valid applied TSV as if a prior run finished.
make_aau_fixture staleapplied
{
  printf 'binary-for-user\tlogo.bin\ttheirs\twritten\n'
  printf 'binary-for-user\textra.bin\tours\tunchanged\n'
  printf 'added-heavyweight-ask-user\tbigdir/a.txt\ttake\twritten\n'
  printf 'added-heavyweight-ask-user\tbigdir/b.txt\tskip\tunchanged\n'
  printf 'added-heavyweight-ask-user\tcmd/worker/main.go\ttake\twritten\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/x.txt\tdelete\tdeleted\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/y.txt\tdelete\tdeleted\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/z.txt\tkeep\tunchanged\n'
} > "$RUN/ask-user-applied.tsv"

# Now re-answer INCOMPLETE: legacy/z.txt (deleted-heavyweight-ask-user) has no
# decision row at all.
{
  printf 'binary-for-user\tlogo.bin\ttheirs\n'
  printf 'binary-for-user\textra.bin\tours\n'
  printf 'added-heavyweight-ask-user\tbigdir/a.txt\ttake\n'
  printf 'added-heavyweight-ask-user\tbigdir/b.txt\tskip\n'
  printf 'added-heavyweight-ask-user\tcmd/worker/main.go\ttake\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/x.txt\tdelete\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/y.txt\tdelete\n'
} > "$RUN/ask-user-decisions.tsv"

PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-stale.log"
SA_RC=$?
if [[ "$SA_RC" -eq 1 ]]; then pass "the incomplete re-answer exits 1"; else fail "the incomplete re-answer exited $SA_RC (want 1)"; fi
expect "MISSING names the undecided item on stderr" \
  grep -qx 'MISSING: deleted-heavyweight-ask-user:legacy/z.txt' "$SANDBOX/aau-stale.log"
refute "the stale ask-user-applied.tsv is GONE, not left describing a rolled-back tree" \
  test -e "$RUN/ask-user-applied.tsv"

fi

if t "a Phase 5 redo does not leave a stale confirmed-deletes.txt line after a delete flips to keep"; then
make_aau_fixture cdflip
write_full_decisions
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-cdflip1.log"
expect "attempt 1 exits 0" test $? -eq 0
expect "attempt 1: legacy/x.txt lands in confirmed-deletes.txt" \
  grep -qxF legacy/x.txt "$RUN/confirmed-deletes.txt"
expect "attempt 1: legacy/y.txt lands in confirmed-deletes.txt" \
  grep -qxF legacy/y.txt "$RUN/confirmed-deletes.txt"

# Redo with the SAME classified set: legacy/y.txt flips delete -> keep. A real
# Phase 5 redo (`git checkout -- . && git clean -fd`) would have restored
# legacy/y.txt to the tree; this fixture has no git-tracked component tree, so
# recreate it by hand to stand in for that restore.
echo "legacy y" > legacy/y.txt
{
  printf 'binary-for-user\tlogo.bin\ttheirs\n'
  printf 'binary-for-user\textra.bin\tours\n'
  printf 'added-heavyweight-ask-user\tbigdir/a.txt\ttake\n'
  printf 'added-heavyweight-ask-user\tbigdir/b.txt\tskip\n'
  printf 'added-heavyweight-ask-user\tcmd/worker/main.go\ttake\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/x.txt\tdelete\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/y.txt\tkeep\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/z.txt\tkeep\n'
} > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-cdflip2.log"
expect "attempt 2 (y flipped to keep) exits 0" test $? -eq 0
refute "confirmed-deletes.txt no longer lists the path flipped to keep" \
  grep -qxF legacy/y.txt "$RUN/confirmed-deletes.txt"
expect "confirmed-deletes.txt still lists the delete still enacted THIS run" \
  grep -qxF legacy/x.txt "$RUN/confirmed-deletes.txt"
expect "legacy/y.txt (kept on the redo) survives in the tree" test -f legacy/y.txt

fi

if t "a confirmed-deletes.txt rebuild that cannot be truncated exits 1, loud, and enacts nothing"; then
# The rebuild-from-outcomes truncate is a write in the enactment loop like any
# other and must be checked (see "nothing may fail silently" above): occupy
# the path with a DIRECTORY so `: > "$RUN/confirmed-deletes.txt"` can never
# succeed — for any user, including root, since this is a file-type mismatch
# (EISDIR), not a permission check a chmod-based fixture would dodge under root.
make_aau_fixture cdtrunc
write_full_decisions
mkdir -p "$RUN/confirmed-deletes.txt"
printf 'stale\n' > "$RUN/ask-user-applied.tsv"   # a previous run's applied set
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-cdtrunc.log"
CDT_RC=$?
if [[ "$CDT_RC" -eq 1 ]]; then pass "an untruncatable confirmed-deletes.txt exits 1"; else fail "an untruncatable confirmed-deletes.txt exited $CDT_RC (want 1)"; fi
expect "the FAIL names confirmed-deletes.txt" \
  grep -q 'confirmed-deletes.txt' "$SANDBOX/aau-cdtrunc.log"
refute "the stale applied TSV was removed so the gate fails closed" \
  test -e "$RUN/ask-user-applied.tsv"
refute "nothing was enacted: the take never landed" test -e bigdir/a.txt
expect "nothing was enacted: the delete never removed the file" test -f legacy/x.txt

fi

if t "a take whose source blob is absent at the tag exits 1 and enacts nothing"; then
make_aau_fixture noblob
# ghost.txt is classified but the target tree has no such blob — a take must
# fail LOUDLY before any tree change, not write an empty file.
printf 'added-heavyweight-ask-user\tA\tbigdir/ghost.txt\tbigdir/ghost.txt\n' \
  >> "$RUN/classification.tsv"
write_full_decisions
printf 'added-heavyweight-ask-user\tbigdir/ghost.txt\ttake\n' >> "$RUN/ask-user-decisions.tsv"
# Exercise the DECISIONS override while at it: same content, non-default path.
mv "$RUN/ask-user-decisions.tsv" "$SANDBOX/noblob-decisions.tsv"
DECISIONS=$SANDBOX/noblob-decisions.tsv PHASE_KEY=$PK_STRUCTURAL "$AAU" \
  > /dev/null 2> "$SANDBOX/aau-noblob.log"
NB_RC=$?
if [[ "$NB_RC" -eq 1 ]]; then pass "absent source blob exits 1"; else fail "absent source blob exited $NB_RC (want 1)"; fi
expect "the failure names the absent blob's path" \
  grep -q 'bigdir/ghost.txt' "$SANDBOX/aau-noblob.log"
refute "no applied rows written" test -e "$RUN/ask-user-applied.tsv"
refute "no ghost file written" test -e bigdir/ghost.txt
expect "the valid theirs row was NOT enacted either (fail-closed)" \
  cmp -s logo.bin "$SANDBOX/noblob-logo.ours"
expect "the valid delete row was NOT enacted either" test -f legacy/x.txt

fi

if t "an invalid decision value for its bucket exits 1 and enacts nothing"; then
make_aau_fixture invalid
write_full_decisions
# 'yes-please' is not a binary-for-user decision (that bucket speaks theirs|ours).
awk 'BEGIN { FS = OFS = "\t" } $2 == "logo.bin" { $3 = "yes-please" } { print }' \
  "$RUN/ask-user-decisions.tsv" > "$RUN/ask-user-decisions.tsv.tmp" \
  && mv "$RUN/ask-user-decisions.tsv.tmp" "$RUN/ask-user-decisions.tsv"
expect "the fixture edit really landed" \
  grep -q 'yes-please' "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-bad.log"
BAD_RC=$?
if [[ "$BAD_RC" -eq 1 ]]; then pass "invalid decision exits 1"; else fail "invalid decision exited $BAD_RC (want 1)"; fi
expect "the error names the bad value and its bucket" \
  bash -c "grep -q 'yes-please' '$SANDBOX/aau-bad.log' && grep -q 'binary-for-user' '$SANDBOX/aau-bad.log'"
refute "no applied rows written" test -e "$RUN/ask-user-applied.tsv"
expect "nothing enacted: take not landed" bash -c "! test -e bigdir/a.txt"
expect "nothing enacted: delete not removed" test -f legacy/x.txt

fi

if t "zero classified ask-user items is a clean pass (empty applied TSV)"; then
# Mirrors the gate's zero-classified PASS: an empty applied TSV is the
# evidence that the step ran and had nothing to do.
Z_RUN=$SANDBOX/zero-run; Z_COMP=$SANDBOX/zero-comp
mkdir -p "$Z_RUN" "$Z_COMP"
printf 'merge-pipeline\tM\tkept.txt\tkept.txt\n' > "$Z_RUN/classification.tsv"
: > "$Z_RUN/binaries.txt"
cd "$Z_COMP"
# No blob is ever read here, but $SYNTH still has to be a real synthetic repo:
# the validity probe runs before the classified set is even built, so that a
# stale $SYNTH can never present as "nothing to enact".
Z_SYNTH=$SANDBOX/zero-synth
mkdir -p "$Z_SYNTH" && git -C "$Z_SYNTH" init -q -b main
git -C "$Z_SYNTH" commit -q --allow-empty -m base && git -C "$Z_SYNTH" tag kairos-base
git -C "$Z_SYNTH" commit -q --allow-empty -m target && git -C "$Z_SYNTH" tag kairos-target
printf 'base\t%s\ntarget\t%s\n' \
  "$(git -C "$Z_SYNTH" rev-parse 'kairos-base^{tree}')" \
  "$(git -C "$Z_SYNTH" rev-parse 'kairos-target^{tree}')" > "$Z_RUN/classification-trees.tsv"
RUN=$Z_RUN SYNTH=$Z_SYNTH PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-zero.log"
expect "zero classified items exits 0 with no decisions file" test $? -eq 0
expect "an EMPTY applied TSV is still written (the step's evidence)" \
  bash -c "test -f '$Z_RUN/ask-user-applied.tsv' && ! test -s '$Z_RUN/ask-user-applied.tsv'"
refute "no MISSING lines on an empty classified set" \
  grep -q '^MISSING: ' "$SANDBOX/aau-zero.log"

fi

if t "enactment is loud: dir-clash take, dir delete, and git modes applied"; then
# The gate row audits COVERAGE, never the tree — so a silently mis-enacted row
# would pass it. Every failure in the enactment loop must therefore be loud.

# (a) a take whose destination is occupied by a local DIRECTORY: an unchecked
# mv would drop the blob INSIDE the dir under its temp name, record `written`,
# and exit 0 — the silent non-enactment class this script exists to end.
SYNTH=$SANDBOX/loud-synth
mkdir -p "$SYNTH" && cd "$SYNTH" && git init -q -b main
git commit -q --allow-empty -m base && git tag kairos-base
printf 'clash content\n' > clashpath
git add -A && git commit -qm target && git tag kairos-target
COMP=$SANDBOX/loud-comp; RUN=$COMP/.run
mkdir -p "$COMP" "$RUN" && cd "$COMP"
printf 'added-heavyweight-ask-user\tA\tclashpath\tclashpath\n' > "$RUN/classification.tsv"
printf 'added-heavyweight-ask-user\tclashpath\ttake\n' > "$RUN/ask-user-decisions.tsv"
export SYNTH RUN
# Each `git tag -f kairos-target` below moves the target TREE, so the binding
# sidecar is re-stamped alongside it — otherwise these blocks would be asserting
# classification drift rather than the enactment behaviour they are about.
stamp_ctrees
mkdir clashpath
printf 'stale\n' > "$RUN/ask-user-applied.tsv"   # a previous run's applied set
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/loud-clash.log"
expect "a take onto a directory exits 1 (never a silent mv into it)" test $? -eq 1
expect "the failure names the clashing path" grep -q 'clashpath' "$SANDBOX/loud-clash.log"
expect "the directory was not replaced or written into" \
  bash -c "test -d clashpath && test -z \"\$(ls -A clashpath)\""
refute "no .apply-ask-user temp file leaked into the tree" \
  bash -c "find . -name '.apply-ask-user.*' | grep -q ."
refute "the stale applied TSV was removed so the gate fails closed" \
  test -e "$RUN/ask-user-applied.tsv"

# (b) same loudness for a delete whose path is (unexpectedly) a directory:
# rm -f exits non-zero, and a recorded `deleted` must never stand for a path
# still in the tree.
printf 'deleted-heavyweight-ask-user\tD\tclashpath\tclashpath\n' > "$RUN/classification.tsv"
printf 'deleted-heavyweight-ask-user\tclashpath\tdelete\n' > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/loud-del.log"
expect "a delete of a directory path exits 1" test $? -eq 1
expect "the still-present path is NOT recorded as a confirmed delete" \
  bash -c "! test -e '$RUN/confirmed-deletes.txt' || ! grep -qxF clashpath '$RUN/confirmed-deletes.txt'"
refute "no applied TSV after the failed delete" test -e "$RUN/ask-user-applied.tsv"

# (c) written files carry the tag's git mode: a 100755 tool keeps its exec bit
# (mktemp's raw 0600 would land it unexecutable in the structural commit) and
# a plain 100644 file is world-readable again, not 0600.
cd "$SYNTH"
printf '#!/bin/sh\necho hi\n' > tool.sh && chmod 755 tool.sh
printf 'plain\n' > plain.txt
git add -A && git commit -qm modes && git tag -f kairos-target
stamp_ctrees
cd "$COMP" && rmdir clashpath
{
  printf 'added-heavyweight-ask-user\tA\ttool.sh\ttool.sh\n'
  printf 'added-heavyweight-ask-user\tA\tplain.txt\tplain.txt\n'
} > "$RUN/classification.tsv"
{
  printf 'added-heavyweight-ask-user\ttool.sh\ttake\n'
  printf 'added-heavyweight-ask-user\tplain.txt\ttake\n'
} > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/loud-mode.log"
expect "takes with mode fixtures exit 0" test $? -eq 0
expect "a 100755 blob lands executable" test -x tool.sh
refute "a 100644 blob does NOT land executable" test -x plain.txt
expect "a 100644 blob is world-readable (not mktemp's 0600)" \
  bash -c "ls -l plain.txt | grep -q '^-rw-r--r--'"

# (d) a dash-leading path is a legal repo path and must ENACT — never read as
# an option by dirname/mkdir/mv/chmod (all ops go through the ./-anchored dst).
cd "$SYNTH"
printf 'dash content\n' > ./-dash.txt
git add -- ./-dash.txt && git commit -qm dash && git tag -f kairos-target
stamp_ctrees
cd "$COMP"
printf 'added-heavyweight-ask-user\tA\t-dash.txt\t-dash.txt\n' > "$RUN/classification.tsv"
printf 'added-heavyweight-ask-user\t-dash.txt\ttake\n' > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/loud-dash.log"
expect "a dash-leading path enacts (exit 0)" test $? -eq 0
expect "the dash-leading file landed with the target content" \
  grep -qx 'dash content' ./-dash.txt

# (e) a symlink PARENT is rejected: writing or deleting through it would land
# the operation outside the git-visible path while the applied row says
# written/deleted — invisible to the coverage-only gate row.
cd "$SYNTH"
mkdir -p linkdir && printf 'inner\n' > linkdir/inner.txt
git add -A && git commit -qm linkdir && git tag -f kairos-target
stamp_ctrees
cd "$COMP"
mkdir -p realdir && ln -s realdir linkdir
printf 'added-heavyweight-ask-user\tA\tlinkdir/inner.txt\tlinkdir/inner.txt\n' > "$RUN/classification.tsv"
printf 'added-heavyweight-ask-user\tlinkdir/inner.txt\ttake\n' > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/loud-symp.log"
expect "a take through a symlink parent exits 1" test $? -eq 1
expect "the failure names the symlink parent" grep -q 'symlink parent' "$SANDBOX/loud-symp.log"
refute "nothing landed behind the link" test -e realdir/inner.txt
refute "the applied TSV was removed (fail closed)" test -e "$RUN/ask-user-applied.tsv"

printf 'victim\n' > realdir/victim.txt
printf 'deleted-heavyweight-ask-user\tD\tlinkdir/victim.txt\tlinkdir/victim.txt\n' > "$RUN/classification.tsv"
printf 'deleted-heavyweight-ask-user\tlinkdir/victim.txt\tdelete\n' > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/loud-symd.log"
expect "a delete through a symlink parent exits 1" test $? -eq 1
expect "the real file behind the link survived" test -f realdir/victim.txt

# (f) duplicate rows for one path are a CONTRADICTION — refused whole at
# validation, nothing enacted, never resolved by file order.
rm -f plain.txt
printf 'added-heavyweight-ask-user\tA\tplain.txt\tplain.txt\n' > "$RUN/classification.tsv"
{
  printf 'added-heavyweight-ask-user\tplain.txt\ttake\n'
  printf 'added-heavyweight-ask-user\tplain.txt\tskip\n'
} > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/loud-dup.log"
expect "a contradictory duplicate-row set exits 1" test $? -eq 1
expect "the refusal names the duplicated path" \
  grep -q 'duplicate decision row for plain.txt' "$SANDBOX/loud-dup.log"
refute "nothing was enacted on the duplicate refusal" test -e plain.txt

# (g) a symlink ENTRY at the tag (mode 120000) is refused at VALIDATION —
# before any tree change, so a pre-existing destination is never first
# overwritten with the link-target text and then abandoned.
cd "$SYNTH"
ln -s plain.txt alias.lnk
git add -A && git commit -qm symlink-entry && git tag -f kairos-target
stamp_ctrees
cd "$COMP"
printf 'added-heavyweight-ask-user\tA\talias.lnk\talias.lnk\n' > "$RUN/classification.tsv"
printf 'added-heavyweight-ask-user\talias.lnk\ttake\n' > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/loud-mode2.log"
expect "a 120000 (symlink) entry at the tag is refused at validation" test $? -eq 1
expect "the refusal names the unsupported mode" grep -q '120000' "$SANDBOX/loud-mode2.log"
refute "the destination was never touched (validation-time refusal)" test -e alias.lnk

fi

if t "apply-ask-user.sh guards its inputs (PHASE_KEY, RUN/SYNTH, classification.tsv)"; then
make_aau_fixture guards
write_full_decisions
# PHASE_KEY proof-of-load: stated only in phases/5-structural.md.
env -u PHASE_KEY RUN=$RUN SYNTH=$SYNTH bash "$AAU" > /dev/null 2> "$SANDBOX/aau-nokey.log"
NOKEY_RC=$?
if [[ "$NOKEY_RC" -ne 0 ]]; then pass "no PHASE_KEY is refused"; else fail "no PHASE_KEY was accepted"; fi
expect "the refusal says to load phases/5-structural.md" \
  grep -q 'load phases/5-structural.md' "$SANDBOX/aau-nokey.log"
PHASE_KEY=wrong-key bash "$AAU" > /dev/null 2>&1
if [[ $? -ne 0 ]]; then pass "a wrong PHASE_KEY is refused"; else fail "a wrong PHASE_KEY was accepted"; fi
refute "a key refusal enacted nothing (no applied rows)" test -e "$RUN/ask-user-applied.tsv"
expect "a key refusal touched no tree (delete not removed)" test -f legacy/x.txt

env -u RUN SYNTH=$SYNTH PHASE_KEY=$PK_STRUCTURAL bash "$AAU" > /dev/null 2>&1
if [[ $? -ne 0 ]]; then pass "a missing RUN exits non-zero"; else fail "a missing RUN was accepted"; fi
env -u SYNTH RUN=$RUN PHASE_KEY=$PK_STRUCTURAL bash "$AAU" > /dev/null 2>&1
if [[ $? -ne 0 ]]; then pass "a missing SYNTH exits non-zero"; else fail "a missing SYNTH was accepted"; fi

NOCLS=$SANDBOX/guards-nocls; mkdir -p "$NOCLS"
RUN=$NOCLS SYNTH=$SYNTH PHASE_KEY=$PK_STRUCTURAL bash "$AAU" > /dev/null 2> "$SANDBOX/aau-nocls.log"
if [[ $? -ne 0 ]]; then pass "a missing classification.tsv exits non-zero"; else fail "a missing classification.tsv was accepted"; fi
expect "the failure points at build-manifest.sh" \
  grep -q 'build-manifest.sh' "$SANDBOX/aau-nocls.log"

fi

if t "apply-ask-user.sh refuses a \$SYNTH that is not a usable synthetic repo"; then
# Every blob written here comes from $TARGET_TAG. A $SYNTH wiped between phases
# (the compaction case the docs name) is REPO-level absence — a different
# failure from the per-path blob absence the validation pass reports — and must
# be a hard stop carrying its own remedy.
make_aau_fixture probe
write_full_decisions

# (a) the directory is gone entirely.
SYNTH=$SANDBOX/probe-no-such-synth PHASE_KEY=$PK_STRUCTURAL "$AAU" \
  > /dev/null 2> "$SANDBOX/aau-probe-missing.log"
expect "a missing \$SYNTH directory exits 1" test $? -eq 1
expect "the refusal names the missing tag" \
  grep -q 'missing tag kairos-target' "$SANDBOX/aau-probe-missing.log"
expect "the refusal carries the re-materialize remedy" \
  grep -q 'scripts/materialize.sh' "$SANDBOX/aau-probe-missing.log"

# (b) the directory exists but is not a git repo.
PROBE_NOREPO=$SANDBOX/probe-not-a-repo; mkdir -p "$PROBE_NOREPO"
SYNTH=$PROBE_NOREPO PHASE_KEY=$PK_STRUCTURAL "$AAU" \
  > /dev/null 2> "$SANDBOX/aau-probe-norepo.log"
expect "a \$SYNTH that is not a git repo exits 1" test $? -eq 1
expect "the not-a-repo refusal names materialize.sh" \
  grep -q 'scripts/materialize.sh' "$SANDBOX/aau-probe-norepo.log"

# (c) a real repo whose target tag is absent (a half-materialized run).
PROBE_NOTAG=$SANDBOX/probe-no-tag
mkdir -p "$PROBE_NOTAG" && git -C "$PROBE_NOTAG" init -q -b main
git -C "$PROBE_NOTAG" commit -q --allow-empty -m base && git -C "$PROBE_NOTAG" tag kairos-base
SYNTH=$PROBE_NOTAG PHASE_KEY=$PK_STRUCTURAL "$AAU" \
  > /dev/null 2> "$SANDBOX/aau-probe-notag.log"
expect "a repo missing kairos-target exits 1" test $? -eq 1
expect "the refusal names the tag that is missing" \
  grep -q 'missing tag kairos-target' "$SANDBOX/aau-probe-notag.log"
expect "the missing-tag refusal names materialize.sh" \
  grep -q 'scripts/materialize.sh' "$SANDBOX/aau-probe-notag.log"

# The probe precedes every read and write, so no refusal enacted anything.
refute "no probe refusal wrote applied rows" test -e "$RUN/ask-user-applied.tsv"
expect "no probe refusal enacted a delete" test -f legacy/x.txt
refute "no probe refusal enacted a take" test -e bigdir/a.txt
expect "no probe refusal overwrote the ours-side binary" \
  cmp -s logo.bin "$SANDBOX/probe-logo.ours"

# Happy path unchanged: the same decision set against the real $SYNTH enacts.
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-probe-ok.log"
expect "a live \$SYNTH still enacts (exit 0)" test $? -eq 0
refute "the happy path prints no probe error" \
  grep -q 'not a usable synthetic repo' "$SANDBOX/aau-probe-ok.log"
expect "the happy path enacted the take" test -f bigdir/a.txt

fi

if t "apply-ask-user.sh refuses a classification bound to OTHER synthetic trees"; then
# structural-merge.sh refuses to MERGE a classification whose synthetic-tree
# binding no longer matches $SYNTH. The ask-user rows come out of that same
# classification.tsv, so ENACTING them against a re-materialized $SYNTH is the
# identical defect one step later — and the per-path blob check is not a
# substitute for the binding check: the fixture below re-materializes $SYNTH with
# every classified path still present, so every take resolves to a valid blob and
# the whole stale set enacts, answering the user's decisions against a tree they
# never saw. gate.sh check 7 catches the drift, but only post-hoc, after the tree
# has already been written.
make_aau_fixture bound
write_full_decisions
WANT_TARGET=$(git -C "$SYNTH" rev-parse 'kairos-target^{tree}')
( cd "$SYNTH" && printf 'BIN\0REMATERIALIZED\r\nv3\r\n' > logo.bin \
    && git add -A && git commit -qm rematerialized >/dev/null && git tag -f kairos-target 2>/dev/null )
HAVE_TARGET=$(git -C "$SYNTH" rev-parse 'kairos-target^{tree}')
refute "the fixture really moved the target TREE (not just the commit)" \
  test "$WANT_TARGET" = "$HAVE_TARGET"
expect "every classified take still resolves to a blob (the blob-level check would pass)" \
  bash -c "git -C '$SYNTH' cat-file -e 'kairos-target:bigdir/a.txt' && git -C '$SYNTH' cat-file -e 'kairos-target:logo.bin'"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-drift.log"
DR_RC=$?
if [[ "$DR_RC" -eq 1 ]]; then pass "a drifted binding exits 1"; else fail "a drifted binding exited $DR_RC (want 1)"; fi
expect "the refusal names the tree the classification was derived FROM" \
  grep -qF "$WANT_TARGET" "$SANDBOX/aau-drift.log"
expect "the refusal names the tree \$SYNTH holds NOW" \
  grep -qF "$HAVE_TARGET" "$SANDBOX/aau-drift.log"
expect "the refusal carries the re-run-Phase-3 remedy" \
  grep -q 'build-manifest.sh' "$SANDBOX/aau-drift.log"
refute "nothing enacted: no applied rows" test -e "$RUN/ask-user-applied.tsv"
refute "nothing enacted: confirmed-deletes.txt never truncated into existence" \
  test -e "$RUN/confirmed-deletes.txt"
refute "nothing enacted: the take never landed" test -e bigdir/a.txt
expect "nothing enacted: the delete never removed the file" test -f legacy/x.txt
expect "nothing enacted: the ours-side binary is byte-identical" \
  cmp -s logo.bin "$SANDBOX/bound-logo.ours"

# The BASE side is bound too — classification statuses and merge bases are derived
# from it, so a moved baseline invalidates the bucket choices even when the target
# tree is untouched.
make_aau_fixture boundbase
write_full_decisions
WANT_BASE=$(git -C "$SYNTH" rev-parse 'kairos-base^{tree}')
( cd "$SYNTH" && printf 'moved baseline\n' > basefile.txt && git add basefile.txt \
    && git commit -qm newbase >/dev/null && git tag -f kairos-base 2>/dev/null )
refute "the fixture really moved the base TREE" \
  test "$WANT_BASE" = "$(git -C "$SYNTH" rev-parse 'kairos-base^{tree}')"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-drift-base.log"
BD_RC=$?
if [[ "$BD_RC" -eq 1 ]]; then pass "base-side drift exits 1 even with the target tag intact"; else fail "base-side drift exited $BD_RC (want 1)"; fi
expect "the base-side refusal names the side that drifted" \
  grep -q 'base: classified against' "$SANDBOX/aau-drift-base.log"
refute "base-side drift enacted nothing" test -e "$RUN/ask-user-applied.tsv"
expect "base-side drift removed no file" test -f legacy/x.txt

# A missing sidecar is a hard stop, not a shrug: an unbound classification cannot
# be checked at all, so it is never enacted. (build-manifest.sh deletes the
# sidecar itself when it empties a classification it cannot represent.)
make_aau_fixture nobind
write_full_decisions
rm -f "$RUN/classification-trees.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-nobind.log"
NB2_RC=$?
if [[ "$NB2_RC" -eq 1 ]]; then pass "a missing binding sidecar exits 1"; else fail "a missing binding sidecar exited $NB2_RC (want 1)"; fi
expect "the refusal names the missing sidecar" \
  grep -q 'classification-trees.tsv' "$SANDBOX/aau-nobind.log"
expect "the missing-sidecar refusal carries the re-run-Phase-3 remedy" \
  grep -q 'build-manifest.sh' "$SANDBOX/aau-nobind.log"
refute "nothing enacted on the missing sidecar" test -e "$RUN/ask-user-applied.tsv"
refute "no confirmed-deletes.txt on the missing sidecar" test -e "$RUN/confirmed-deletes.txt"
expect "no delete enacted on the missing sidecar" test -f legacy/x.txt

# Non-vacuity: a sidecar that MATCHES still enacts, so the check is a binding
# test and not a blanket refusal.
make_aau_fixture boundok
write_full_decisions
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-boundok.log"
expect "a matching binding still enacts (exit 0)" test $? -eq 0
expect "the matching binding enacted the take" test -f bigdir/a.txt
refute "the happy path prints no binding error" \
  grep -q 'derived from different synthetic trees' "$SANDBOX/aau-boundok.log"

fi

if t "a RENAMED binary: theirs completes the rename, ours leaves the tree alone"; then
# The rename arrives by BOTH routes into this script, so both are fixtured here:
#   assets/logo.bin   a binary-for-user classification row, old path in column 5
#                     (build-manifest.sh's R* arm — the template renamed a binary)
#   assets/icon.bin   a binaries.txt row with the old path as a second TAB field
#                     (structural-merge.sh's safety net, which diverts BEFORE it
#                     completes the rename)
# Neither route has moved anything yet: the component's copy still sits at the old
# path. `theirs` therefore owes BOTH halves — the blob at the new path and the old
# copy gone — or the structural commit carries the file twice with nothing saying
# so. `ours` owes the opposite: the tree exactly as it is, since the decision means
# "keep mine" and enacting the template's move would relocate a file the user just
# declined.
RN_SYNTH=$SANDBOX/rn-synth
mkdir -p "$RN_SYNTH/assets" && cd "$RN_SYNTH" && git init -q -b main
git commit -q --allow-empty -m base && git tag kairos-base
printf 'BIN\0LOGO-TARGET\r\n' > assets/logo.bin
printf 'BIN\0ICON-TARGET\r\n' > assets/icon.bin
git add -A && git commit -qm target && git tag kairos-target

RN_COMP=$SANDBOX/rn-comp
RUN=$RN_COMP/.run
mkdir -p "$RUN" && cd "$RN_COMP"
printf 'BIN\0LOGO-OURS\r\n' > logo.bin          # still at the PRE-rename path
printf 'BIN\0ICON-OURS\r\n' > icon.bin
cp icon.bin "$SANDBOX/rn-icon.ours"
{
  printf 'binary-for-user\tR087\tassets/logo.bin\tassets/logo.bin\tlogo.bin\n'
  printf 'merge-pipeline\tR100\tassets/icon.bin\tassets/icon.bin\ticon.bin\n'
} > "$RUN/classification.tsv"
printf 'assets/icon.bin\ticon.bin\n' > "$RUN/binaries.txt"
SYNTH=$RN_SYNTH
export SYNTH RUN
stamp_ctrees
{
  printf 'binary-for-user\tassets/logo.bin\ttheirs\n'
  printf 'binary-for-user\tassets/icon.bin\tours\n'
} > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > "$SANDBOX/aau-rn.out" 2> "$SANDBOX/aau-rn.log"
expect "the renamed-binary decision set enacts (exit 0)" test $? -eq 0

# The binaries.txt row's second field must not leak into the classified path — a
# tab-joined "path" matches no decision row, so the whole set would fail closed as
# MISSING for an item the user actually answered.
refute "the two-field binaries.txt row is not reported MISSING" \
  grep -q 'MISSING' "$SANDBOX/aau-rn.log"

# theirs — both halves.
git -C "$SYNTH" cat-file blob kairos-target:assets/logo.bin > "$SANDBOX/rn-logo.want"
expect "theirs writes the target blob at the NEW path" cmp -s assets/logo.bin "$SANDBOX/rn-logo.want"
refute "theirs removes the PRE-rename copy (no silent duplicate in the commit)" test -e logo.bin
expect "the removed old path is recorded in confirmed-deletes.txt" \
  grep -qxF logo.bin "$RUN/confirmed-deletes.txt"
expect "the applied row is still one row per decided path, outcome written" \
  grep -qx $'binary-for-user\tassets/logo.bin\ttheirs\twritten' "$RUN/ask-user-applied.tsv"
refute "the NEW path is not itself recorded as a delete" \
  grep -qxF assets/logo.bin "$RUN/confirmed-deletes.txt"

# ours — nothing moves, nothing is recorded as deleted.
expect "ours leaves the component's binary at its current path, byte-exact" \
  cmp -s icon.bin "$SANDBOX/rn-icon.ours"
refute "ours does NOT create the template's new path" test -e assets/icon.bin
refute "ours records no delete" grep -qxF icon.bin "$RUN/confirmed-deletes.txt"
expect "ours still writes its applied row (outcome unchanged)" \
  grep -qx $'binary-for-user\tassets/icon.bin\tours\tunchanged' "$RUN/ask-user-applied.tsv"

# Re-running the same TSV converges: the old path is already gone, so the second
# pass must neither fail on the absent file nor invent a phantom delete line for
# Phase 6's stale-reference sweep to chase.
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-rn2.log"
expect "a second identical run is still exit 0 (old path already removed)" test $? -eq 0
RN_CD=$(grep -c . "$RUN/confirmed-deletes.txt" || true)
if [[ "${RN_CD:-0}" -eq 0 ]]; then
  pass "the rebuilt confirmed-deletes.txt records no delete for an already-absent old path"
else
  fail "the rebuilt confirmed-deletes.txt has $RN_CD row(s) (want 0 — the old path was gone before this pass)"
fi
expect "and the new path still carries the target blob" cmp -s assets/logo.bin "$SANDBOX/rn-logo.want"

fi

if t "a rename OLD path with a '..' segment is refused before the rm can leave the tree"; then
# classification.tsv column 5 (the pre-rename path) is hand-editable
# (structural-merge.md), and the enactment loop drives an `rm -f` on it. Git never
# emits a `..` in a rename, so this is the hand-edited / hostile case: an old path
# of `../escape.bin` resolves OUTSIDE the component tree, and without the shape
# gate on `oldp` the enactor would `rm -f -- ./../escape.bin` and delete it. The
# gate — the SAME one the decision path took at validation — refuses it first.
RNB_SYNTH=$SANDBOX/rnbad-synth
mkdir -p "$RNB_SYNTH/assets" && cd "$RNB_SYNTH" && git init -q -b main
git commit -q --allow-empty -m base && git tag kairos-base
printf 'BIN\0LOGO-TARGET\r\n' > assets/logo.bin
git add -A && git commit -qm target && git tag kairos-target

RNB_COMP=$SANDBOX/rnbad-comp
RUN=$RNB_COMP/.run
mkdir -p "$RUN" && cd "$RNB_COMP"
# The sentinel sits one level ABOVE the component root; `../escape.bin` from here
# names it exactly. It must survive: a passing test proves the rm never fired.
printf 'DO-NOT-DELETE\n' > "$SANDBOX/rnbad-escape.bin"
{
  printf 'binary-for-user\tR087\tassets/logo.bin\tassets/logo.bin\t../escape.bin\n'
} > "$RUN/classification.tsv"
SYNTH=$RNB_SYNTH
export SYNTH RUN
stamp_ctrees
printf 'binary-for-user\tassets/logo.bin\ttheirs\n' > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > "$SANDBOX/aau-rnbad.out" 2> "$SANDBOX/aau-rnbad.log"
RNB_RC=$?
if [[ "$RNB_RC" -ne 0 ]]; then pass "a '..'-segment rename old path is refused non-zero"; else fail "a '..'-segment rename old path was NOT refused (rc=$RNB_RC)"; fi
expect "the escape sentinel above the component tree is untouched" \
  test -f "$SANDBOX/rnbad-escape.bin"
expect "the refusal names the pre-rename path and its shape" \
  bash -c "grep -qF '../escape.bin' \"$SANDBOX/aau-rnbad.log\" && grep -qi 'relative path' \"$SANDBOX/aau-rnbad.log\""

fi

if t "a template-DELETED binary: theirs adopts the deletion, ours keeps the component's copy"; then
# The delete-flavored binary row (build-manifest.sh's D arm: the template DROPPED
# a binary the component customized). There is no blob at the tag to write, so
# `theirs` cannot mean "write the template's file" — it means adopt the DELETION,
# enacted and recorded exactly like every other delete this script owns. The
# flavor rides the classification row's existing STATUS column (`D`), not a fourth
# bucket: gate.sh, handoff-classify.sh and this script each hardcode the same
# three-bucket ask-user triplet as independent literals, so a new bucket would
# have to land in all of them at once to be enacted and audited at all.
DL_SYNTH=$SANDBOX/delbin-synth
mkdir -p "$DL_SYNTH/assets" && cd "$DL_SYNTH" && git init -q -b main
printf 'BIN\0LEGACY-TEMPLATE\r\n' > assets/legacy-logo.png
printf 'BIN\0KEEPER-TEMPLATE\r\n' > keep-mine.png
printf 'still here\n' > survivor.txt
git add -A && git commit -qm base && git tag kairos-base
git rm -q assets/legacy-logo.png keep-mine.png      # the template deletes both
git commit -qm target && git tag kairos-target

DL_COMP=$SANDBOX/delbin-comp
RUN=$DL_COMP/.run
mkdir -p "$RUN" "$DL_COMP/assets" && cd "$DL_COMP"
printf 'BIN\0LEGACY-OURS\r\n' > assets/legacy-logo.png    # customized: hence the ask
printf 'BIN\0KEEPER-OURS\r\n' > keep-mine.png
cp keep-mine.png "$SANDBOX/delbin-keep.ours"
{
  printf 'binary-for-user\tD\tassets/legacy-logo.png\tassets/legacy-logo.png\n'
  printf 'binary-for-user\tD\tkeep-mine.png\tkeep-mine.png\n'
} > "$RUN/classification.tsv"
: > "$RUN/binaries.txt"
SYNTH=$DL_SYNTH
export SYNTH RUN
stamp_ctrees
{
  printf 'binary-for-user\tassets/legacy-logo.png\ttheirs\n'
  printf 'binary-for-user\tkeep-mine.png\tours\n'
} > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-del.log"
expect "the delete-flavored decision set enacts (exit 0)" test $? -eq 0
refute "a row with no blob at the tag is NOT reported as an absent source blob" \
  grep -q 'source blob absent' "$SANDBOX/aau-del.log"

# theirs — the deletion, recorded where every other enacted delete is recorded.
refute "theirs removes the template-deleted binary" test -e assets/legacy-logo.png
expect "the removed path is recorded in confirmed-deletes.txt" \
  grep -qxF assets/legacy-logo.png "$RUN/confirmed-deletes.txt"
expect "the applied row's outcome is 'deleted', never 'written'" \
  grep -qx $'binary-for-user\tassets/legacy-logo.png\ttheirs\tdeleted' "$RUN/ask-user-applied.tsv"

# ours — the component's binary stays, byte-exact, and nothing is recorded.
expect "ours keeps the component's binary byte-exact (NUL + CRLF intact)" \
  cmp -s keep-mine.png "$SANDBOX/delbin-keep.ours"
refute "ours records no delete" grep -qxF keep-mine.png "$RUN/confirmed-deletes.txt"
expect "ours still writes its applied row (outcome unchanged)" \
  grep -qx $'binary-for-user\tkeep-mine.png\tours\tunchanged' "$RUN/ask-user-applied.tsv"
expect "the summary counts the adopted deletion as a delete, not a write" \
  grep -q '2 row(s): 0 written, 1 unchanged, 1 deleted' "$SANDBOX/aau-del.log"

# A redone Phase 5 (or a retried step) converges: the file is already gone, so the
# second pass must neither fail on the absent path nor double the record.
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-del2.log"
expect "a second identical run is still exit 0 (the file is already gone)" test $? -eq 0
refute "the file stays deleted" test -e assets/legacy-logo.png
expect "the kept binary is still byte-exact after the re-run" \
  cmp -s keep-mine.png "$SANDBOX/delbin-keep.ours"
DL_CD=$(grep -c . "$RUN/confirmed-deletes.txt" || true)
if [[ "${DL_CD:-0}" -eq 1 ]]; then
  pass "confirmed-deletes.txt is rebuilt, not doubled (still 1 line)"
else
  fail "confirmed-deletes.txt has $DL_CD line(s) after the re-run (want 1 — rebuilt, not appended)"
fi
DL_AP=$(grep -c . "$RUN/ask-user-applied.tsv" || true)
if [[ "${DL_AP:-0}" -eq 2 ]]; then
  pass "applied TSV rewritten, not appended (still 2 rows)"
else
  fail "applied TSV has $DL_AP row(s) after the re-run (want 2)"
fi

# A `theirs` that would delete a file the TARGET TREE STILL SHIPS is refused at
# validation. The delete flavor is the one decision here that destroys data on a
# mis-encoded row (a hand-edited classification, a mangled status column), so the
# blob check is INVERTED rather than skipped: absent at the tag is required.
DL_COMP2=$SANDBOX/delbin-contra
RUN=$DL_COMP2/.run
mkdir -p "$RUN" && cd "$DL_COMP2"
printf 'still here\n' > survivor.txt
printf 'binary-for-user\tD\tsurvivor.txt\tsurvivor.txt\n' > "$RUN/classification.tsv"
: > "$RUN/binaries.txt"
export RUN
stamp_ctrees
printf 'binary-for-user\tsurvivor.txt\ttheirs\n' > "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-del-contra.log"
DL_RC=$?
if [[ "$DL_RC" -eq 1 ]]; then
  pass "a delete-flavored row the target tree still carries exits 1"
else
  fail "a delete-flavored row the target tree still carries exited $DL_RC (want 1)"
fi
expect "the refusal names the contradicting path" \
  grep -q 'survivor.txt' "$SANDBOX/aau-del-contra.log"
expect "the file the template still ships was NOT deleted" test -f survivor.txt
refute "no applied rows written on the refusal" test -e "$RUN/ask-user-applied.tsv"
refute "confirmed-deletes.txt was never truncated into existence" \
  test -e "$RUN/confirmed-deletes.txt"

fi

if t "a decision row for a path OUTSIDE the classified set is enacted AND recorded"; then
# The header's contract: "Decision rows for paths outside the classified set are
# enacted as written — the decisions file is the record of instruction." Its
# applied row is the ONLY record of such a row anywhere: the postmerge gate's
# coverage compare walks the CLASSIFIED set, so a missing applied row for an
# out-of-set path is invisible to it — which is why the row's append is now
# checked and why "enacted but unrecorded" must not be a reachable state. This
# block pins the contract from the enacting side: both a write and a delete for
# unclassified paths land in the tree and both get their applied row.
make_aau_fixture outofset
# An unclassified blob at the tag, so an out-of-set `take` has a real source.
printf 'see\n' > "$SYNTH/bigdir/c.txt"
git -C "$SYNTH" add -A
git -C "$SYNTH" commit -qm "target + an unclassified blob" >/dev/null
git -C "$SYNTH" tag -f kairos-target >/dev/null 2>&1
cd "$COMP"
stamp_ctrees                       # the tag moved — re-bind or this asserts drift
printf 'extra legacy\n' > legacy/extra.txt   # unclassified, present in the tree

write_full_decisions
{ printf 'added-heavyweight-ask-user\tbigdir/c.txt\ttake\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/extra.txt\tdelete\n'
} >> "$RUN/ask-user-decisions.tsv"

PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-outofset.log"
OOS_RC=$?
if [[ "$OOS_RC" -eq 0 ]]; then pass "an out-of-set decision row does not fail the pass"; else fail "an out-of-set decision row exited $OOS_RC (want 0)"; fi
expect "the out-of-set take landed in the tree" test -f bigdir/c.txt
expect "the out-of-set take carries the target's content" grep -qx see bigdir/c.txt
refute "the out-of-set delete removed the file" test -e legacy/extra.txt
expect "the out-of-set delete is recorded in confirmed-deletes.txt" \
  grep -qxF legacy/extra.txt "$RUN/confirmed-deletes.txt"
expect "the out-of-set take has its applied row (never enacted-but-unrecorded)" \
  grep -qx $'added-heavyweight-ask-user\tbigdir/c.txt\ttake\twritten' "$RUN/ask-user-applied.tsv"
expect "the out-of-set delete has its applied row" \
  grep -qx $'deleted-heavyweight-ask-user\tlegacy/extra.txt\tdelete\tdeleted' "$RUN/ask-user-applied.tsv"
OOS_N=$(grep -c . "$RUN/ask-user-applied.tsv" || true)
if [[ "${OOS_N:-0}" -eq 10 ]]; then
  pass "applied TSV has one row per decision row, out-of-set rows included (10)"
else
  fail "applied TSV has $OOS_N rows (want 10 — 8 classified + 2 out-of-set)"
fi
expect "the summary counts the out-of-set rows too (4 written, 3 deleted)" \
  grep -q '10 row(s): 4 written, 3 unchanged, 3 deleted' "$SANDBOX/aau-outofset.log"

fi

if t "the applied TSV's own writes cannot fail silently (temp truncate, final mv)"; then
# Three writes in and around the enactment loop were unchecked while every
# sibling carried `|| enact_fail`, in a loop whose header states "nothing in the
# enactment loop may fail silently":
#   * `: > "$APPLIED_TMP"`   — $APPLIED_TMP survives a KILLED prior attempt (the
#     trap never ran), so a silent truncate failure left that attempt's rows in
#     the file and this attempt's appends stacked on top: one applied set
#     describing two answer sets, and a superset the gate's coverage compare
#     passes.
#   * the per-row append — the tree change already happened, so a dropped row is
#     a divergence between the tree and the only artifact describing it (see the
#     out-of-set block above for the case no gate can see).
#   * `mv "$APPLIED_TMP" "$RUN/ask-user-applied.tsv"` — the worst: exit 0 with
#     "OK: ask-user decisions enacted" while a PREVIOUS run's COMPLETE applied
#     TSV stayed in place and satisfied postmerge gate check 7, describing an
#     enactment that is not the one just performed. Removing that file on failure
#     is what every other refusal path here already does, and why.

# Arm 1 — the temp truncate. Occupied by a DIRECTORY, the same root-proof
# file-type mismatch (EISDIR) the confirmed-deletes truncate block above uses
# instead of a chmod fixture.
make_aau_fixture applytmp
write_full_decisions
mkdir -p "$RUN/.ask-user-applied.tmp"
printf 'stale\n' > "$RUN/ask-user-applied.tsv"   # a previous run's applied set
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-applytmp.log"
AT_RC=$?
if [[ "$AT_RC" -eq 1 ]]; then pass "an untruncatable applied temp exits 1, not 0 with 'OK'"; else fail "an untruncatable applied temp exited $AT_RC (want 1)"; fi
# Anchored on ^FAIL:, not a bare path match: with the truncate unchecked, bash's
# own "Is a directory" noise names the same path, so an unanchored grep passes on
# the very shape this asserts against.
expect "the FAIL names the applied temp it could not truncate" \
  grep -q '^FAIL:.*\.ask-user-applied\.tmp' "$SANDBOX/aau-applytmp.log"
refute "the previous run's applied TSV is removed so the gate fails closed" \
  test -f "$RUN/ask-user-applied.tsv"
refute "nothing was enacted: the take never landed" test -e bigdir/a.txt
expect "nothing was enacted: the delete never removed the file" test -f legacy/x.txt
refute "no success line was printed" grep -q '^OK:' "$SANDBOX/aau-applytmp.log"

# Arm 2 — the final mv. Simulated with an `mv` shim ahead of PATH that fails ONLY
# when its destination is ask-user-applied.tsv, and execs the real mv otherwise —
# so the per-blob `mv "$blob_tmp" "$dst"` inside the loop is untouched and this is
# a targeted simulation of the ONE unchecked rename, not a broken-mv fixture. The
# taken blob landing in the tree below is the proof the shim is that narrow.
REALMV=$(command -v mv)
mkdir -p "$SANDBOX/applymvfail"
cat > "$SANDBOX/applymvfail/mv" <<EOF
#!/usr/bin/env bash
case "\$2" in
  */ask-user-applied.tsv|ask-user-applied.tsv) exit 1 ;;
esac
exec "$REALMV" "\$@"
EOF
chmod +x "$SANDBOX/applymvfail/mv"

make_aau_fixture applymv
write_full_decisions
# A COMPLETE applied TSV from a prior (since-rolled-back) enactment — the record
# that used to survive the failed mv and pass gate check 7 on its own.
{
  printf 'binary-for-user\tlogo.bin\ttheirs\twritten\n'
  printf 'binary-for-user\textra.bin\tours\tunchanged\n'
  printf 'added-heavyweight-ask-user\tbigdir/a.txt\ttake\twritten\n'
  printf 'added-heavyweight-ask-user\tbigdir/b.txt\tskip\tunchanged\n'
  printf 'added-heavyweight-ask-user\tcmd/worker/main.go\ttake\twritten\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/x.txt\tdelete\tdeleted\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/y.txt\tdelete\tdeleted\n'
  printf 'deleted-heavyweight-ask-user\tlegacy/z.txt\tkeep\tunchanged\n'
} > "$RUN/ask-user-applied.tsv"
PATH="$SANDBOX/applymvfail:$PATH" PHASE_KEY=$PK_STRUCTURAL "$AAU" \
  > /dev/null 2> "$SANDBOX/aau-applymv.log"
AM_RC=$?
if [[ "$AM_RC" -eq 1 ]]; then pass "a failed final mv exits 1, not 0 with 'OK'"; else fail "a failed final mv exited $AM_RC (want 1)"; fi
refute "no success line was printed on the failed mv" grep -q '^OK:' "$SANDBOX/aau-applymv.log"
expect "the FAIL names the applied TSV it could not install" \
  grep -q '^FAIL:.*ask-user-applied\.tsv' "$SANDBOX/aau-applymv.log"
refute "the PREVIOUS run's complete applied TSV is GONE, so gate check 7 fails closed" \
  test -e "$RUN/ask-user-applied.tsv"
refute "no applied temp debris survives the failure" \
  test -e "$RUN/.ask-user-applied.tmp"
# enact_fail's documented posture: earlier rows in this pass stay enacted. That is
# also the non-vacuity proof for the shim — the per-blob mv still worked.
expect "the shim is narrow: the taken blob still landed in the tree" test -f bigdir/a.txt

fi

if t "a decision row with an ABSOLUTE path is refused — enactment can never leave the component tree"; then
make_aau_fixture abspath
write_full_decisions
# A canary OUTSIDE the component tree at an absolute path. Unguarded, a delete
# row naming it would rm -f a file the component never owned; the path-shape
# check must refuse it during validation, before any row is enacted.
CANARY=$SANDBOX/abs-canary.txt
printf 'do not touch\n' > "$CANARY"
printf 'deleted-heavyweight-ask-user\t%s\tdelete\n' "$CANARY" >> "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-abs.log"
ABS_RC=$?
if [[ "$ABS_RC" -eq 1 ]]; then pass "an absolute-path row exits 1"; else fail "an absolute-path row exited $ABS_RC (want 1)"; fi
expect "the failure names the offending path" grep -qF "$CANARY" "$SANDBOX/aau-abs.log"
expect "the canary outside the tree is untouched" test -f "$CANARY"
refute "NO applied rows written on refusal" test -e "$RUN/ask-user-applied.tsv"
refute "no confirmed-deletes append on refusal" test -e "$RUN/confirmed-deletes.txt"
refute "the valid take was NOT enacted (fail-closed)" test -e bigdir/a.txt
expect "the valid delete was NOT enacted (fail-closed)" test -f legacy/x.txt

fi

if t "a decision row with a '..' path component is refused (escapes the tree)"; then
make_aau_fixture dotdot
write_full_decisions
# The canary sits one level ABOVE the component root; a '../…' delete would
# escape the tree. '..' is matched as a whole path COMPONENT.
printf 'do not touch\n' > "$COMP/../dotdot-escape.txt"
printf 'deleted-heavyweight-ask-user\t../dotdot-escape.txt\tdelete\n' >> "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-dotdot.log"
DD_RC=$?
if [[ "$DD_RC" -eq 1 ]]; then pass "a '..'-component row exits 1"; else fail "a '..'-component row exited $DD_RC (want 1)"; fi
expect "the failure names the offending path" grep -qF '../dotdot-escape.txt' "$SANDBOX/aau-dotdot.log"
expect "the canary above the tree is untouched" test -f "$COMP/../dotdot-escape.txt"
refute "NO applied rows written on refusal" test -e "$RUN/ask-user-applied.tsv"
refute "the valid take was NOT enacted (fail-closed)" test -e bigdir/a.txt

fi

if t "a legitimately-named file with '..' in its BASENAME (a..b) is still enactable"; then
# The shape check matches '..' only as a whole path component, never as a
# substring, so a real file named a..b is taken like any other.
SYNTH=$SANDBOX/dotname-synth
mkdir -p "$SYNTH" && cd "$SYNTH" && git init -q -b main
git commit -q --allow-empty -m base && git tag kairos-base
printf 'the real content\n' > 'a..b'
git add -A && git commit -qm target && git tag kairos-target
COMP=$SANDBOX/dotname-comp; RUN=$COMP/.run
mkdir -p "$COMP" "$RUN" && cd "$COMP"
printf 'added-heavyweight-ask-user\tA\ta..b\ta..b\n' > "$RUN/classification.tsv"
printf 'added-heavyweight-ask-user\ta..b\ttake\n' > "$RUN/ask-user-decisions.tsv"
export SYNTH RUN
stamp_ctrees
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-dotname.log"
DN_RC=$?
if [[ "$DN_RC" -eq 0 ]]; then pass "the a..b take exits 0"; else fail "the a..b take exited $DN_RC (want 0)"; fi
expect "a..b was actually landed in the tree" test -f 'a..b'
expect "a..b carries the target content" grep -qx 'the real content' 'a..b'
expect "the applied TSV records the a..b row" \
  grep -qF 'a..b' "$RUN/ask-user-applied.tsv"

fi

if t "a decision row citing the WRONG bucket for a classified path is refused (join is (bucket,path))"; then
make_aau_fixture wrongbucket
write_full_decisions
# legacy/x.txt is classified deleted-heavyweight-ask-user; cite it under
# added-heavyweight-ask-user instead — a bucket:decision combo valid on its own
# (added:take) but answering a question the classifier never asked.
awk 'BEGIN { FS = OFS = "\t" }
     $2 == "legacy/x.txt" { $1 = "added-heavyweight-ask-user"; $3 = "take" }
     { print }' "$RUN/ask-user-decisions.tsv" > "$RUN/ask-user-decisions.tsv.tmp" \
  && mv "$RUN/ask-user-decisions.tsv.tmp" "$RUN/ask-user-decisions.tsv"
expect "the fixture edit really landed" \
  grep -q 'added-heavyweight-ask-user.*legacy/x.txt.*take' "$RUN/ask-user-decisions.tsv"
PHASE_KEY=$PK_STRUCTURAL "$AAU" > /dev/null 2> "$SANDBOX/aau-wb.log"
WB_RC=$?
if [[ "$WB_RC" -eq 1 ]]; then pass "a wrong-bucket row exits 1"; else fail "a wrong-bucket row exited $WB_RC (want 1)"; fi
expect "the error names the CITED bucket" \
  grep -q "cites bucket 'added-heavyweight-ask-user'" "$SANDBOX/aau-wb.log"
expect "the error names the classifier's ACTUAL bucket" \
  grep -q "classifier placed it in 'deleted-heavyweight-ask-user'" "$SANDBOX/aau-wb.log"
refute "NO applied rows written on refusal" test -e "$RUN/ask-user-applied.tsv"
expect "nothing enacted: legacy/x.txt still present" test -f legacy/x.txt
refute "nothing enacted: the valid take not landed" test -e bigdir/a.txt

fi

finish_suite
