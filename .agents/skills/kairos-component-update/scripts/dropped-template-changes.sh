#!/usr/bin/env bash
# dropped-template-changes.sh — materialize, for every `ours`-resolved conflict
# region, ONLY the target-side (template) text of that region — the change the
# component's customization dropped — plus an index. Deterministic, zero agent
# tokens. The fifth consumer of the resolution ledger.
#
# WHY THIS EXISTS: an `ours` verdict means the resolved content IS the component's
# prior content, so the region contributes NO hunk to the structural commit — the
# template's dropped change exists only in $SYNTH at the kairos-target tag. The
# planner's step 1.5 review needs that text; `git show HEAD -- <file>` cannot
# supply it. This script re-derives each `ours` region deterministically from the
# same three sides structural-merge.sh merged, and emits the target side of the
# regions the ledger marks `ours`.
#
# WHY RE-DERIVE RATHER THAN RECORD THE HUNK: line numbers shift as regions are
# resolved, so a recorded range is stale the moment the resolver finishes the file.
# The ledger records a 1-based ORDINAL; this script re-derives the regions from the
# tree and counts them the SAME way structural-merge.sh's merge_one did, so the
# TREE — not the resolver's self-report — is what locates the hunk. An ordinal out
# of range for the re-derived set is a HARD ERROR naming the file, NEVER a silent
# fall back to a whole-file diff (that whole-file diff would include hunks the
# resolver correctly ADOPTED — a false-positive generator this design forbids).
#
# THE DERIVATION IS POSITIONAL, AND THAT IS THE CONTRACT THE ORDINAL MUST MATCH:
# the regions are counted top-to-bottom over the ORIGINAL conflicted file (the
# three sides as first merged), so ordinal N always names the Nth region in the
# file, whatever order the resolver worked them in and whichever ones it skipped.
# agents/conflict-resolver.md defines REGION that way for exactly this reason, and
# phases/5-structural.md makes a needs-input re-spawn carry the original ordinal
# rather than re-count a file whose earlier markers are already gone. A resolver
# that renumbered by resolution order would still hand this script an in-range
# ordinal — and it would extract a DIFFERENT region's text as evidence, silently.
#
# WHY THE OURS SIDE IS `tr -d '\r'`-NORMALIZED UNCONDITIONALLY: structural-merge.sh
# strips \r from the working-tree copy before `git merge-file` runs, so the regions
# the resolver counted were computed over LF bytes — while the structural commit's
# PARENT still holds the CRLF original. Re-deriving against the un-normalized parent
# blob makes every line conflict, the region set explodes, and every ordinal in a
# normalized file re-derives against a different set and hard-errors — on exactly
# the file class structural-merge.sh names as its largest source of conflict volume.
# `tr -d '\r'` is a no-op on LF content, so normalizing unconditionally reproduces
# the merge's input byte-for-byte without consulting normalized-ours.txt.
#
# WHY THE TARGET-SIDE BLOB IS READ THROUGH A GUARDED ACCESSOR (theirs_problem),
# not a bare `git show`: a symlink at the tag `git show`s its LINK TEXT, a gitlink
# is a commit, a directory is a tree — all three pass an existence probe and none
# can locate a conflict region. One ls-tree gives mode AND type, so absent / tree /
# gitlink / symlink are told apart and each names the operator's actual problem.
# The base-side blob is read through the swallowing shape (show_synth): base absence
# is legitimate (an added file has an empty base).
#
# WHY A PRE-COLUMN (three-field) OR `-` OURS ROW IS `unlocatable`, NOT AN ERROR:
# its ordinal was never written and is unrecoverable. It is recorded in the index as
# `unlocatable` with the reason, emits NO evidence, does NOT fall back to a
# whole-file diff, and does NOT fail the run — a resume that spans a skill upgrade
# must still compute what it can. A bucket verdict (ported|kept-delete|
# kept-customization|renamed-merged) carrying `-` is simply NOT `ours`, so it is
# ignored entirely: the verdict vocabulary is the disambiguator (an `ours` row
# carrying `-` can ONLY be a pre-column row).
#
# WHY THE LEDGER ROW IS NORMALIZED BEFORE THE DE-DUP: log-resolution.sh's collect
# normalizes a legacy three-field (pre-region-column) row to four fields as it
# rebuilds the aggregate, but leaves the on-disk shard row three-field. De-duping
# on the raw row then kept BOTH twins, and this script scanned the same `ours` row
# twice — two index rows, two evidence blocks, for one resolution. norm() is
# log-resolution.sh's, character for character (that script owns the ledger
# format); handoff-structural.sh carries the same copy.
#
# WHY LEDGER READS ARE shards UNION aggregate, de-duplicated on the exact row: the
# aggregate ($RUN/resolutions.tsv) is written by log-resolution.sh's `collect`
# ALONE, so a run whose session died before that collect has its whole ledger in
# shards — reading only the aggregate would report zero `ours` rows, the one thing
# this script exists to prevent. This is the rule reference/state-files.md already
# states for the other four consumers; this script is the fifth.
#
# WHY ABSENT $SYNTH / MISSING TAG IS EXIT 2 (skip that escalates), NEVER A PASS:
# with no synthetic repo the question "what did the template change here" cannot be
# asked. Writing an empty artifact would read as "nothing was dropped" — the exact
# false negative this evidence exists to prevent. So exit 2 writes NO artifact and
# says why, mirroring structural-merge.sh's up-front tag probe.
#
# Env in:  RUN            required — migration state dir
#          SYNTH          required — synthetic repo (tags kairos-base / kairos-target)
#          STRUCTURAL_SHA optional — the structural commit (default HEAD). The `ours`
#                         side is that commit's PARENT: ${STRUCTURAL_SHA:-HEAD}^.
#          (cwd = component root, a git repo)
# Reads (in $RUN):
#   resolutions.tsv + resolutions.*.tsv   the ledger (file<TAB>verdict<TAB>reason<TAB>region)
#   classification.tsv                    merge-pipeline rows: dest(col4) -> tpath(col3), old_tpath(col5)
# Writes (in $RUN):
#   dropped-template-changes.tsv   index: path<TAB>region<TAB>status<TAB>detail
#                                  (status located|unlocatable|error), leading `#` summary
#   dropped-template-changes.txt   evidence: per located row, a header then the
#                                  region's target-side text
# Exit:  0  computed cleanly (INCLUDING zero `ours` rows — positive evidence — and
#           runs with only benign `unlocatable` rows). Both artifacts written.
#        1  hard error(s): an ordinal out of range, or a target-side blob the
#           derivation cannot read. Artifacts ARE written (error rows + located
#           evidence for the good ones — partial success reported as partial).
#        2  skip that escalates: $SYNTH unset or a required tag missing. No artifact.
set -u

: "${RUN:?FAIL: RUN not set}"

SBASE=kairos-base
STARGET=kairos-target

# --- exit-2 probes: run BEFORE any artifact is created or truncated -----------
# so a skip leaves nothing on disk that could read as "nothing was dropped".
[[ -n "${SYNTH:-}" ]] || {
  echo "SKIP: SYNTH not set — cannot re-derive dropped template changes without the synthetic repo (kairos-base / kairos-target). This is incomplete coverage, not a clean result; no artifact was written." >&2
  exit 2
}
for tg in "$SBASE" "$STARGET"; do
  git -C "$SYNTH" rev-parse --verify --quiet "$tg^{commit}" >/dev/null 2>&1 || {
    echo "SKIP: $SYNTH is missing tag $tg — the target-side text of an ours region cannot be read without it. Incomplete coverage, not a clean result; re-run scripts/materialize.sh. No artifact was written." >&2
    exit 2
  }
done

OURS_REF="${STRUCTURAL_SHA:-HEAD}^"

IDX="$RUN/dropped-template-changes.tsv"
EVID="$RUN/dropped-template-changes.txt"

# --- scratch ------------------------------------------------------------------
IDX_BODY=$(mktemp "${TMPDIR:-/tmp}/dtc-idx.XXXXXX")
EVID_BODY=$(mktemp "${TMPDIR:-/tmp}/dtc-evid.XXXXXX")
OURS_LIST=$(mktemp "${TMPDIR:-/tmp}/dtc-ours.XXXXXX")
OURS_TMP=$(mktemp "${TMPDIR:-/tmp}/dtc-ours-blob.XXXXXX")
BASE_TMP=$(mktemp "${TMPDIR:-/tmp}/dtc-base-blob.XXXXXX")
TGT_TMP=$(mktemp "${TMPDIR:-/tmp}/dtc-tgt-blob.XXXXXX")
REGION_OUT=$(mktemp "${TMPDIR:-/tmp}/dtc-region.XXXXXX")
trap 'rm -f "$IDX_BODY" "$EVID_BODY" "$OURS_LIST" "$OURS_TMP" "$BASE_TMP" "$TGT_TMP" "$REGION_OUT"' EXIT

# The guarded target-side accessor, modeled on structural-merge.sh's
# theirs_problem(): one ls-tree gives mode AND type, so an absent entry, a tree, a
# gitlink and a symlink are told apart in one probe. Prints the problem (non-empty)
# or nothing (a writable/readable blob). :(literal) stops a glob-charactered path
# from matching anything else.
theirs_problem() { # theirs_problem <template_path>
  local entry mode type
  entry=$(git -C "$SYNTH" ls-tree "$STARGET" -- ":(literal)$1" 2>/dev/null)
  [[ -n "$entry" ]] || {
    echo "absent from the target tree — tag $STARGET carries no entry at that path"
    return 0
  }
  mode="${entry%% *}"; entry="${entry#* }"; type="${entry%% *}"
  case "$type" in
    blob) ;;
    *) echo "not a file at tag $STARGET — that path is a git '$type' object (mode $mode)"
       return 0 ;;
  esac
  case "$mode" in
    100644|100755) ;;
    *) echo "unsupported git mode $mode at tag $STARGET — a symlink or gitlink cannot ride the blob read path (its link text is not the file content)"
       return 0 ;;
  esac
}

# --- read the ledger: shards UNION aggregate, de-dup the NORMALIZED row, ours --
# `awk 'NF'` per file (not `cat`): a hand-written or truncated ledger with no
# trailing newline would otherwise splice its last row onto the next file's first.
# region = $4 when present, else the literal '-' (a three-field pre-column row).
# Reason is NEVER re-split: only $1/$2/$4 are read positionally.
OURS_ROWS=0
for f in "$RUN/resolutions.tsv" "$RUN"/resolutions.*.tsv; do
  [[ -f "$f" ]] || continue
  awk 'NF' "$f"
done | awk -F'\t' '
  function norm(line,   n, arr) {
    n = split(line, arr, "\t")
    return (n == 3) ? line "\t-" : line
  }
  NF { row = norm($0)
       if (!(row in seen)) { seen[row] = 1
                             if ($2 == "ours") print $1 "\t" (NF >= 4 ? $4 : "-") } }
' > "$OURS_LIST"

LOCATED=0; UNLOCATABLE=0; ERRORS=0

idx_row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$IDX_BODY"; }

while IFS=$'\t' read -r file region; do
  [[ -n "$file" ]] || continue
  OURS_ROWS=$((OURS_ROWS + 1))

  # 1. Pre-column / `-` / non-positive-int region: unlocatable, benign.
  case "$region" in
    [1-9]*) case "$region" in *[!0-9]*) region="" ;; esac ;;
    *) region="" ;;
  esac
  if [[ -z "$region" ]]; then
    idx_row "$file" "-" "unlocatable" "no region ordinal recorded (pre-column row)"
    UNLOCATABLE=$((UNLOCATABLE + 1))
    continue
  fi
  N="$region"

  # 2. Recover the template paths by joining ledger `file` (= dest) against the
  #    merge-pipeline classification row. awk -F'\t' preserves empty interior
  #    fields, so col 5 (old_tpath) is read correctly whether or not it is set.
  paths=""
  if [[ -f "$RUN/classification.tsv" ]]; then
    paths=$(awk -F'\t' -v d="$file" '$1 == "merge-pipeline" && $4 == d { print $3 "\t" $5; exit }' "$RUN/classification.tsv")
  fi
  if [[ -z "$paths" ]]; then
    idx_row "$file" "$N" "error" "no merge-pipeline classification row for '$file'"
    ERRORS=$((ERRORS + 1))
    continue
  fi
  tpath=${paths%%$'\t'*}
  old_tpath=${paths#*$'\t'}

  # 3a. target side — through the guarded accessor, never a bare git show.
  why=$(theirs_problem "$tpath")
  if [[ -n "$why" ]]; then
    idx_row "$file" "$N" "error" "target-side blob for '$tpath' cannot be located: $why"
    ERRORS=$((ERRORS + 1))
    continue
  fi
  if ! git -C "$SYNTH" show "$STARGET:$tpath" > "$TGT_TMP" 2>/dev/null; then
    idx_row "$file" "$N" "error" "target-side blob $STARGET:$tpath could not be read from $SYNTH"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # 3b. base side — swallow absence (legitimate for an added file's empty base).
  #     For a rename the baseline lived at the OLD path (mirror merge_one).
  git -C "$SYNTH" show "$SBASE:${old_tpath:-$tpath}" > "$BASE_TMP" 2>/dev/null || : > "$BASE_TMP"

  # 3c. ours side — the structural commit's PARENT blob. Try dest, fall back to
  #     old_tpath when dest is absent there (mirror merge_one's ours_src). Then
  #     `tr -d '\r'` UNCONDITIONALLY (see header: the CRLF normalization).
  if git rev-parse --verify --quiet "$OURS_REF:$file" >/dev/null 2>&1; then
    git show "$OURS_REF:$file" 2>/dev/null | tr -d '\r' > "$OURS_TMP"
  elif [[ -n "$old_tpath" ]] && git rev-parse --verify --quiet "$OURS_REF:$old_tpath" >/dev/null 2>&1; then
    git show "$OURS_REF:$old_tpath" 2>/dev/null | tr -d '\r' > "$OURS_TMP"
  else
    : > "$OURS_TMP"
  fi

  # 4. 3-way merge with diff3 markers. merge-file modifies the first arg in place;
  #    exit code = conflict count (0..127), >=128 is a real error.
  git merge-file --diff3 -L ours -L base -L theirs "$OURS_TMP" "$BASE_TMP" "$TGT_TMP" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -ge 128 ]]; then
    idx_row "$file" "$N" "error" "git merge-file could not re-derive regions (rc=$rc)"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Count regions the same way the resolver did: one `<<<<<<< ` start per region.
  K=$(awk '/^<<<<<<< / { r++ } END { print r+0 }' "$OURS_TMP")

  # 5. Ordinal out of range → HARD ERROR naming the file, never a whole-file diff.
  if [[ "$N" -gt "$K" ]]; then
    idx_row "$file" "$N" "error" "ordinal $N out of range ($K regions re-derived) — derivation mismatch"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # 6. Extract the target-side text of the Nth region: the lines between that
  #    region's `=======` and its `>>>>>>>`. In diff3 the separator always follows
  #    the `|||||||` base marker, so recognizing it only in the base section keeps
  #    a `=======` CONTENT line on either the ours side (still in `base`/`ours`) or
  #    the theirs side (already in `theirs`) from being mistaken for the separator:
  #    the `next` fires ONLY on the true base->theirs flip; an in-`theirs` line
  #    matching /^=======$/ falls through to the print rule below.
  awk -v want="$N" '
    /^<<<<<<< / { r++; sect="ours"; next }
    /^\|\|\|\|\|\|\| / { if (r > 0) sect="base"; next }
    /^=======$/ { if (sect == "base") { sect="theirs"; next } }
    /^>>>>>>> / { sect=""; next }
    (sect == "theirs" && r == want) { print }
  ' "$OURS_TMP" > "$REGION_OUT"

  printf '===== %s (region %s) =====\n' "$file" "$N" >> "$EVID_BODY"
  cat "$REGION_OUT" >> "$EVID_BODY"
  printf '\n' >> "$EVID_BODY"

  idx_row "$file" "$N" "located" "target-side text of region $N"
  LOCATED=$((LOCATED + 1))
done < "$OURS_LIST"

# --- write both artifacts (records via printf) --------------------------------
if [[ "$OURS_ROWS" -eq 0 ]]; then
  printf '# dropped-template-changes: 0 ours resolution(s) scanned — nothing was dropped by an ours verdict (positive evidence). SYNTH=%s STRUCTURAL_SHA=%s\n' \
    "$SYNTH" "${STRUCTURAL_SHA:-HEAD}" > "$IDX"
else
  printf '# dropped-template-changes: %s ours resolution(s) scanned; located=%s unlocatable=%s error=%s. SYNTH=%s STRUCTURAL_SHA=%s\n' \
    "$OURS_ROWS" "$LOCATED" "$UNLOCATABLE" "$ERRORS" "$SYNTH" "${STRUCTURAL_SHA:-HEAD}" > "$IDX"
fi
cat "$IDX_BODY" >> "$IDX"
cp "$EVID_BODY" "$EVID"

# --- exit -------------------------------------------------------------------
if [[ "$ERRORS" -gt 0 ]]; then
  echo "FAIL: $ERRORS ours region(s) could not be located (see $IDX); located=$LOCATED unlocatable=$UNLOCATABLE. Artifacts written with the rows that could be located." >&2
  exit 1
fi
echo "OK: dropped-template-changes computed (ours=$OURS_ROWS located=$LOCATED unlocatable=$UNLOCATABLE); wrote $IDX and $EVID" >&2
exit 0
