#!/usr/bin/env bash
# dropped-template-changes.test.sh — tests for scripts/dropped-template-changes.sh
# Tested at the script seam: env in, exit code + written artifacts out, never
# internals. TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

DTC="$SKILL_DIR/scripts/dropped-template-changes.sh"

# --- helpers -----------------------------------------------------------------
gcommit() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm "$2" --allow-empty >/dev/null 2>&1; }

# mk_single <dir> <base> <target> <ours-parent> <ours-structural> [filename]
# Builds SYNTH (kairos-base/kairos-target tags) and COMP (parent commit = the
# `ours` side, HEAD = the structural commit) around one file, plus a RUN dir with
# a merge-pipeline classification row (tpath = dest = filename). %b interprets
# \n / \r so callers can spell CRLF content inline. Sets globals SYNTH COMP RUN FN.
mk_single() {
  local d=$1 fn=${6:-f.txt}
  SYNTH=$d/synth; COMP=$d/comp; RUN=$d/run; FN=$fn
  mkdir -p "$SYNTH" "$COMP" "$RUN"
  git -C "$SYNTH" init -q -b main
  printf '%b' "$2" > "$SYNTH/$fn"; gcommit "$SYNTH" base;   git -C "$SYNTH" tag kairos-base
  printf '%b' "$3" > "$SYNTH/$fn"; gcommit "$SYNTH" target; git -C "$SYNTH" tag kairos-target
  git -C "$COMP" init -q -b main
  printf '%b' "$4" > "$COMP/$fn"; gcommit "$COMP" parent
  printf '%b' "$5" > "$COMP/$fn"; gcommit "$COMP" structural
  printf 'merge-pipeline\tM\t%s\t%s\t\n' "$fn" "$fn" > "$RUN/classification.tsv"
}

# run_dtc <tag> — run the script from the component root with the globals set by
# mk_single. Captures RC, stdout->$D/<tag>.out, stderr->$D/<tag>.err.
run_dtc() {
  ( cd "$COMP" && RUN="$RUN" SYNTH="$SYNTH" "$DTC" ) > "$D/$1.out" 2> "$D/$1.err"
  RC=$?
}

IDXF() { echo "$RUN/dropped-template-changes.tsv"; }
EVF()  { echo "$RUN/dropped-template-changes.txt"; }

# =============================================================================
if t "an ours row whose template path is absent at kairos-target -> error naming the file"; then
D=$SANDBOX/absent
mk_single "$D" 'a\nSHARED\nc\n' 'a\nTEMPLATE\nc\n' 'a\nCUSTOM\nc\n' 'a\nCUSTOM\nc\n'
# The classification points the merge at a template path that does NOT exist at
# the target tag; the join succeeds but the target-side blob cannot be located.
printf 'merge-pipeline\tM\tmissing.txt\tf.txt\t\n' > "$RUN/classification.tsv"
printf 'f.txt\tours\tkept our value\t1\n' > "$RUN/resolutions.tsv"
run_dtc absent
expect "hard error exits 1" test "$RC" -eq 1
expect "index carries an error row for the file" \
  grep -qE $'^f\.txt\t1\terror\t' "$(IDXF)"
expect "error detail names the absent template path" \
  grep -q "missing.txt" "$(IDXF)"
expect "no evidence emitted for an unlocatable target" test ! -s "$(EVF)"
fi

# =============================================================================
if t "a template path that is a symlink at the tag -> error with a mode/type message"; then
D=$SANDBOX/symlink
SYNTH=$D/synth; COMP=$D/comp; RUN=$D/run
mkdir -p "$SYNTH" "$COMP" "$RUN"
git -C "$SYNTH" init -q -b main
printf 'base\n' > "$SYNTH/f.txt"; gcommit "$SYNTH" base; git -C "$SYNTH" tag kairos-base
rm "$SYNTH/f.txt"; ln -s /etc/hostname "$SYNTH/f.txt"; gcommit "$SYNTH" target; git -C "$SYNTH" tag kairos-target
git -C "$COMP" init -q -b main
printf 'custom\n' > "$COMP/f.txt"; gcommit "$COMP" parent
gcommit "$COMP" structural
printf 'merge-pipeline\tM\tf.txt\tf.txt\t\n' > "$RUN/classification.tsv"
printf 'f.txt\tours\tkept our value\t1\n' > "$RUN/resolutions.tsv"
run_dtc symlink
expect "symlink at the tag exits 1" test "$RC" -eq 1
expect "index carries an error row" grep -qE $'^f\.txt\t1\terror\t' "$(IDXF)"
expect "error detail describes the git mode / symlink" \
  grep -qiE 'mode|symlink|gitlink' "$(IDXF)"
expect "no evidence emitted" test ! -s "$(EVF)"
fi

# =============================================================================
if t "the ledger is read whether present only as shards or only as an aggregate"; then
D=$SANDBOX/shards
mk_single "$D" 'a\nSHARED\nc\n' 'a\nTEMPLATE-CHANGE\nc\n' 'a\nCUSTOM\nc\n' 'a\nCUSTOM\nc\n'
# (a) ledger present only as a shard, no aggregate.
printf 'f.txt\tours\tkept our value\t1\n' > "$RUN/resolutions.batch1.tsv"
run_dtc shards_only
expect "shard-only ledger exits 0" test "$RC" -eq 0
expect "shard-only ledger locates the region" \
  grep -qE $'^f\.txt\t1\tlocated\t' "$(IDXF)"
expect "shard-only ledger emits the target-side text" \
  grep -qF 'TEMPLATE-CHANGE' "$(EVF)"
# (b) ledger present only as an aggregate, no shard.
rm -f "$RUN/resolutions.batch1.tsv"
printf 'f.txt\tours\tkept our value\t1\n' > "$RUN/resolutions.tsv"
run_dtc agg_only
expect "aggregate-only ledger exits 0" test "$RC" -eq 0
expect "aggregate-only ledger locates the region" \
  grep -qE $'^f\.txt\t1\tlocated\t' "$(IDXF)"
expect "aggregate-only ledger emits the target-side text" \
  grep -qF 'TEMPLATE-CHANGE' "$(EVF)"
fi

# =============================================================================
if t "zero ours rows is a clean positive-evidence result, not an error"; then
D=$SANDBOX/zero-ours
mk_single "$D" 'a\nSHARED\nc\n' 'a\nTEMPLATE\nc\n' 'a\nCUSTOM\nc\n' 'a\nCUSTOM\nc\n'
# A real clean state: a theirs verdict (adopted), no ours verdict anywhere.
printf 'f.txt\ttheirs\tadopted template change\t1\n' > "$RUN/resolutions.tsv"
run_dtc zero
expect "zero ours rows exits 0" test "$RC" -eq 0
expect "index carries the positive-evidence 0-ours note" \
  grep -qE '^# .*0 ours resolution' "$(IDXF)"
expect "both artifacts are written" test -f "$(IDXF)" -a -f "$(EVF)"
expect "no located/error rows in the index" test ! -s "$(EVF)"
fi

# =============================================================================
if t "SYNTH unset and present-but-missing-tag both exit 2 with no artifact"; then
# (a) SYNTH unset entirely — the question cannot be asked.
D=$SANDBOX/skip-unset
mk_single "$D" 'a\nSHARED\nc\n' 'a\nTEMPLATE\nc\n' 'a\nCUSTOM\nc\n' 'a\nCUSTOM\nc\n'
printf 'f.txt\tours\tkept our value\t1\n' > "$RUN/resolutions.tsv"
( cd "$COMP" && RUN="$RUN" "$DTC" ) > "$D/unset.out" 2> "$D/unset.err"; RC=$?
expect "SYNTH unset exits 2" test "$RC" -eq 2
expect "SYNTH unset writes no index artifact" test ! -e "$(IDXF)"
expect "SYNTH unset writes no evidence artifact" test ! -e "$(EVF)"
expect "SYNTH unset says why on stderr" grep -qi 'SYNTH' "$D/unset.err"
# (b) SYNTH present but missing the kairos-target tag.
D=$SANDBOX/skip-notag
SYNTH=$D/synth; COMP=$D/comp; RUN=$D/run
mkdir -p "$SYNTH" "$COMP" "$RUN"
git -C "$SYNTH" init -q -b main
printf 'a\n' > "$SYNTH/f.txt"; gcommit "$SYNTH" base; git -C "$SYNTH" tag kairos-base   # kairos-target deliberately absent
git -C "$COMP" init -q -b main
printf 'a\n' > "$COMP/f.txt"; gcommit "$COMP" parent; gcommit "$COMP" structural
printf 'merge-pipeline\tM\tf.txt\tf.txt\t\n' > "$RUN/classification.tsv"
printf 'f.txt\tours\tkept our value\t1\n' > "$RUN/resolutions.tsv"
run_dtc notag
expect "missing tag exits 2" test "$RC" -eq 2
expect "missing tag writes no index artifact" test ! -e "$(IDXF)"
expect "missing tag writes no evidence artifact" test ! -e "$(EVF)"
expect "missing tag names the tag on stderr" grep -qi 'kairos-target' "$D/notag.err"
fi

# =============================================================================
if t "a non-ASCII path and a reason with odd text are read positionally without re-splitting"; then
D=$SANDBOX/nonascii
mk_single "$D" 'a\nSHARED\nc\n' 'a\nTEMPLATE-CHANGE\nc\n' 'a\nCUSTOM\nc\n' 'a\nCUSTOM\nc\n' 'café.txt'
# The reason field (already collapsed by the format owner) carries incidental
# text; the reader must take $2/$4 positionally and never re-split reason.
printf 'caf\xc3\xa9.txt\tours\tgave up the template key; note: see PR-42\t1\n' > "$RUN/resolutions.tsv"
run_dtc nonascii
expect "non-ASCII path exits 0" test "$RC" -eq 0
expect "non-ASCII path is located at the recorded ordinal" \
  grep -qF "$(printf 'caf\xc3\xa9.txt\t1\tlocated\t')" "$(IDXF)"
expect "the target-side text is emitted for the non-ASCII path" \
  grep -qF 'TEMPLATE-CHANGE' "$(EVF)"
expect "the evidence header carries the non-ASCII path" \
  grep -qF "$(printf 'caf\xc3\xa9.txt')" "$(EVF)"
fi

# =============================================================================
if t "a file with several regions where only some are ours carries exactly those target hunks"; then
D=$SANDBOX/some-regions
mk_single "$D" \
  'L1\nA\nL2\nB\nL3\nC\nL4\n' \
  'L1\nA-T\nL2\nB-T\nL3\nC-T\nL4\n' \
  'L1\nA-O\nL2\nB-O\nL3\nC-O\nL4\n' \
  'L1\nA-O\nL2\nB-O\nL3\nC-O\nL4\n'
# Three conflict regions. Regions 1 and 3 resolved `ours`; region 2 adopted
# `theirs` (present in the ledger, must be ignored — verdict is the disambiguator).
{ printf 'f.txt\tours\tkept region 1\t1\n'
  printf 'f.txt\ttheirs\tadopted region 2\t2\n'
  printf 'f.txt\tours\tkept region 3\t3\n'; } > "$RUN/resolutions.tsv"
run_dtc some
expect "mixed-verdict file exits 0" test "$RC" -eq 0
expect "region 1 target text is present" grep -qF 'A-T' "$(EVF)"
expect "region 3 target text is present" grep -qF 'C-T' "$(EVF)"
refute "region 2 (adopted theirs) target text is NOT emitted" grep -qF 'B-T' "$(EVF)"
refute "no whole-file adopted hunk: the ours-side text is never emitted" grep -qF 'A-O' "$(EVF)"
expect "exactly the two ours regions are indexed located" \
  test "$(grep -cE $'^f\.txt\t[0-9]+\tlocated\t' "$(IDXF)")" -eq 2
fi

# =============================================================================
if t "an ordinal past the end of the re-derived region set hard-errors, never a whole-file fallback"; then
D=$SANDBOX/out-of-range
mk_single "$D" 'a\nSHARED\nc\n' 'a\nTEMPLATE-CHANGE\nc\n' 'a\nCUSTOM\nc\n' 'a\nCUSTOM\nc\n'
# Exactly one region re-derives, but the ledger claims region 2.
printf 'f.txt\tours\tkept our value\t2\n' > "$RUN/resolutions.tsv"
run_dtc oor
expect "ordinal out of range exits 1" test "$RC" -eq 1
expect "index error names the file and the derivation mismatch" \
  grep -qE $'^f\.txt\t2\terror\t.*out of range' "$(IDXF)"
expect "no whole-file fallback: no evidence emitted" test ! -s "$(EVF)"
fi

# =============================================================================
if t "a CRLF ours side re-derives the same regions the resolver saw (missing-normalization guard)"; then
# base/target are LF; the structural parent's ours blob is CRLF. With the
# unconditional tr -d '\r' the re-derivation yields TWO regions and ordinal 2
# locates B-T. Drop the normalization and the CRLF ours conflicts on every line,
# the region set collapses to one whole-file hunk, and ordinal 2 hard-errors —
# which is exactly what this test would then catch.
D=$SANDBOX/crlf
mk_single "$D" \
  'L1\nA\nL2\nB\nL3\n' \
  'L1\nA-T\nL2\nB-T\nL3\n' \
  'L1\r\nA-O\r\nL2\r\nB-O\r\nL3\r\n' \
  'L1\r\nA-O\r\nL2\r\nB-O\r\nL3\r\n'
printf 'f.txt\tours\tkept region 2\t2\n' > "$RUN/resolutions.tsv"
run_dtc crlf
expect "CRLF ours exits 0 (normalization reproduces the merge's LF region set)" test "$RC" -eq 0
expect "ordinal 2 locates region 2 on the normalized file" \
  grep -qE $'^f\.txt\t2\tlocated\t' "$(IDXF)"
expect "the target-side text of region 2 is B-T" grep -qF 'B-T' "$(EVF)"
refute "region 1 target text is not emitted (ordinal 2 only)" grep -qF 'A-T' "$(EVF)"
fi

# =============================================================================
if t "legacy rows: an ours row carrying - is unlocatable, benign, and never a whole-file fallback"; then
D=$SANDBOX/legacy-dash
mk_single "$D" 'a\nSHARED\nc\n' 'a\nTEMPLATE\nc\n' 'a\nCUSTOM\nc\n' 'a\nCUSTOM\nc\n'
printf 'f.txt\tours\tpre-column reason\t-\n' > "$RUN/resolutions.tsv"
run_dtc dash
expect "an ours row carrying - exits 0 (benign)" test "$RC" -eq 0
expect "the - ours row is indexed unlocatable" \
  grep -qE $'^f\.txt\t-\tunlocatable\t' "$(IDXF)"
expect "no evidence is emitted for it" test ! -s "$(EVF)"
fi

# =============================================================================
if t "legacy rows: a three-field pre-column row is treated as unlocatable"; then
D=$SANDBOX/legacy-3field
mk_single "$D" 'a\nSHARED\nc\n' 'a\nTEMPLATE\nc\n' 'a\nCUSTOM\nc\n' 'a\nCUSTOM\nc\n'
printf 'f.txt\tours\tpre-column reason\n' > "$RUN/resolutions.tsv"   # only three fields
run_dtc threefield
expect "a three-field ours row exits 0" test "$RC" -eq 0
expect "a three-field ours row is indexed unlocatable" \
  grep -qE $'^f\.txt\t-\tunlocatable\t' "$(IDXF)"
expect "no evidence is emitted for a three-field row" test ! -s "$(EVF)"
fi

# =============================================================================
if t "legacy rows: a three-field shard row and its normalized aggregate twin are ONE row"; then
# log-resolution.sh's collect normalizes a pre-column row to four fields while
# rebuilding the aggregate, and leaves the shard's three-field original on disk.
# The twins are therefore not the same BYTES, so de-duplicating on the raw row kept
# both — and this script scanned the same `ours` resolution twice: two index rows
# and (for a locatable one) two evidence blocks for one resolution, in the very
# resume-across-a-skill-upgrade case the normalization exists for.
D=$SANDBOX/legacy-twin
mk_single "$D" 'a\nSHARED\nc\n' 'a\nTEMPLATE-CHANGE\nc\n' 'a\nCUSTOM\nc\n' 'a\nCUSTOM\nc\n'
printf 'f.txt\tours\tpre-column reason\n'   > "$RUN/resolutions.batch1.tsv"   # shard: three fields
printf 'f.txt\tours\tpre-column reason\t-\n' > "$RUN/resolutions.tsv"          # aggregate: normalized
run_dtc twin
expect "the legacy twin pair exits 0" test "$RC" -eq 0
expect "the twins are scanned as ONE ours resolution" \
  grep -qE '^#.*1 ours resolution' "$(IDXF)"
expect "and produce exactly one unlocatable row" \
  grep -qE '^#.*unlocatable=1' "$(IDXF)"
TWIN_N=$(grep -cE $'^f\.txt\t' "$(IDXF)" || true)
if [[ "${TWIN_N:-0}" -eq 1 ]]; then
  pass "the index carries one row for the file, not one per twin"
else
  fail "the index carries $TWIN_N rows for the file (want 1 — the twins were counted separately)"
fi

# The same twinning on a LOCATABLE row: the aggregate copy of a four-field row is
# byte-identical to its shard, so this half was always correct — asserted here so
# the normalization cannot regress into collapsing two DIFFERENT regions instead.
printf 'f.txt\tours\tkept our value\t1\n' > "$RUN/resolutions.batch1.tsv"
printf 'f.txt\tours\tkept our value\t1\n' > "$RUN/resolutions.tsv"
run_dtc twin_located
expect "a four-field twin pair also scans once" \
  grep -qE '^#.*1 ours resolution' "$(IDXF)"
expect "and emits the target-side text exactly once" \
  test "$(grep -c 'TEMPLATE-CHANGE' "$(EVF)")" -eq 1
fi

# =============================================================================
if t "legacy rows: a mixed ledger locates ordinal rows and reports - rows as unlocatable (partial)"; then
D=$SANDBOX/legacy-mixed
mk_single "$D" \
  'L1\nA\nL2\nB\nL3\n' \
  'L1\nA-T\nL2\nB-T\nL3\n' \
  'L1\nA-O\nL2\nB-O\nL3\n' \
  'L1\nA-O\nL2\nB-O\nL3\n' \
  'located.txt'
# A second, locatable file with its own conflict; plus a - ours row on another
# file; plus a bucket verdict carrying - (must be IGNORED, not counted).
{ printf 'located.txt\tours\tkept region 1\t1\n'
  printf 'oldfile.txt\tours\tpre-column\t-\n'
  printf 'gone.txt\tkept-delete\tdeclined re-add\t-\n'; } > "$RUN/resolutions.tsv"
# classification only needs the merge-pipeline row for located.txt (written by
# mk_single); the - / bucket rows never reach the classification join.
run_dtc mixed
expect "a mixed ledger exits 0 (partial: unlocatable is benign)" test "$RC" -eq 0
expect "the ordinal row is located with exact evidence" \
  grep -qF 'A-T' "$(EVF)"
expect "the ordinal row is indexed located" \
  grep -qE $'^located\.txt\t1\tlocated\t' "$(IDXF)"
expect "the - ours row is indexed unlocatable" \
  grep -qE $'^oldfile\.txt\t-\tunlocatable\t' "$(IDXF)"
refute "the kept-delete bucket row is NOT in the index at all" \
  grep -q 'gone.txt' "$(IDXF)"
expect "the summary counts exactly one unlocatable (bucket - row not counted)" \
  grep -qE '^#.*unlocatable=1' "$(IDXF)"
fi

# =============================================================================
if t "a bare ======= content line on the target side is preserved in the evidence, not eaten as a separator"; then
# The target-side text of the region contains a line that is exactly seven equals
# (e.g. a Markdown setext H1 underline / decorative rule) plus ordinary neighbours.
# In the re-derived diff3 the region's theirs section is TOP / ======= / BOTTOM;
# the awk must recognize only the true base->theirs separator and let an in-theirs
# `=======` fall through to the print rule. Against the OLD awk (unconditional
# `next`) the bare ======= line is silently dropped from the evidence artifact the
# planner reviews; this fixture fails there and passes with the gated `next`.
D=$SANDBOX/bare-sep
mk_single "$D" \
  'L1\nSHARED\nL3\n' \
  'L1\nTOP\n=======\nBOTTOM\nL3\n' \
  'L1\nCUSTOM\nL3\n' \
  'L1\nCUSTOM\nL3\n'
printf 'f.txt\tours\tkept our value\t1\n' > "$RUN/resolutions.tsv"
run_dtc baresep
expect "bare-separator fixture exits 0" test "$RC" -eq 0
expect "the region is located" grep -qE $'^f\.txt\t1\tlocated\t' "$(IDXF)"
expect "the ordinary neighbour lines are emitted" grep -qF 'TOP' "$(EVF)"
expect "the trailing neighbour line is emitted" grep -qF 'BOTTOM' "$(EVF)"
expect "the bare ======= content line survives in the evidence" \
  grep -qxF '=======' "$(EVF)"
fi

finish_suite
