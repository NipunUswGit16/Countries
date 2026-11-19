#!/usr/bin/env bash
# apply-ask-user.sh — enactment owner for the three ask-user buckets. Phase 5
# step 4 collects one decision per classified path into a TSV; this script is
# the only thing that turns those answers into tree changes, so a "take"
# answer can never again evaporate between the question and the structural
# commit.
#
# Decisions per bucket — ONE ROW PER PATH. Grouping (by root dir, by
# directory) is a presentation concern of the batched question only; a
# cherry-pick is expressed as per-file take/skip rows, with no special case:
#   binary-for-user               theirs | ours
#   added-heavyweight-ask-user    take   | skip
#   deleted-heavyweight-ask-user  delete | keep
#
# A RENAMED BINARY IS STILL ONE ROW, ONE DECISION — the rename is enacted as
# part of it, never asked about separately. The template can rename a binary and
# change it in the same commit (git computes similarity on binary content, so
# R<100 on a moved image is a real status), and the component may have
# customized it at the old path. Both routes into this script carry the
# pre-rename path beside the row: build-manifest.sh's binary-for-user rows in
# column 5, and structural-merge.sh's binaries.txt rows as a second TAB field.
# The two decisions mean:
#   theirs  the rename is taken: the target blob is written at the NEW path AND
#           the old copy is removed (recorded in confirmed-deletes.txt, the same
#           record every other enacted delete lands in — leaving it behind was a
#           silent duplicate in the structural commit that no artifact named).
#   ours    the tree is left exactly as it is: the component's binary stays at
#           whatever path it currently occupies and the new path is NOT created.
#           Identical to `ours` on any other binary row — the decision means
#           "keep mine", and enacting the template's rename anyway would move a
#           file the user just declined to adopt. The dropped rename is visible
#           to the planner as the un-taken template change it is.
#
# A DELETE-FLAVORED BINARY ROW IS THE SAME ONE ROW, ONE DECISION, with `theirs`
# meaning the DELETION. When the template DELETES a binary the component
# customized (build-manifest.sh's D arm), there is no blob at $TARGET_TAG to
# write — adopting the template's change IS removing the file. So:
#   theirs  the file is removed and recorded in confirmed-deletes.txt, the same
#           record every other enacted delete lands in, and the applied row's
#           outcome is `deleted` (not `written` — nothing was written).
#   ours    the component's binary is kept byte-for-byte where it is, outcome
#           `unchanged`, and nothing is recorded as deleted.
# THE FLAVOR RIDES THE CLASSIFICATION ROW'S EXISTING STATUS COLUMN (column 2 =
# `D`) — no fourth bucket, no new artifact, no new decision word. That matters
# beyond tidiness: gate.sh, handoff-classify.sh and this script each hardcode the
# same three-bucket ask-user set as independent literals, so a fourth bucket
# would have to land in all of them at once to be enacted and audited at all.
# The D arm is the only emitter of a status-`D` binary-for-user row, and
# binaries.txt can never contribute one — an ask-user bucket never enters
# structural-merge.sh's merge pipeline, so its safety net never sees these paths.
# The validation pass inverts the blob check for these rows: a delete-flavored
# path must be ABSENT at $TARGET_TAG (see there).
#
# FAIL-CLOSED: nothing is enacted until every classified ask-user path — the
# union, de-duplicated by path, of the three buckets across classification.tsv
# and binaries.txt, the same union step 4 batches its question from — has a
# decision row, every decision is valid for its bucket, and every theirs/take
# source blob exists at $TARGET_TAG. A half-answered batch must never produce
# a half-enacted merge. On refusal NO applied rows are written and the tree is
# untouched. The postmerge `ask-user` gate row is deliberately redundant with
# this check: this catches a half-answered batch; only the gate catches the
# step being skipped entirely. Removing either restores a live failure mode.
# Decision rows for paths outside the classified set are enacted as written —
# the decisions file is the record of instruction — and they get an applied row
# like every other. That row is the ONLY record of them anywhere: the postmerge
# gate's coverage compare walks the CLASSIFIED set, so it can see a missing
# applied row for a classified path and can never see a missing one for an
# out-of-set path. Which is why the applied-row write is checked (below) rather
# than trusted: an out-of-set row whose record was dropped is a tree change no
# artifact and no gate mentions.
#
# BYTE-EXACT — NEVER UNIFY THIS WRITE PATH WITH THE MERGE PIPELINE'S:
# theirs/take blobs are written raw (`git cat-file blob`, which — unlike
# `git show` — can never apply textconv) and are NEVER LF-normalized.
# Binaries ride this path. structural-merge.sh's unconditional LF policy is
# correct there because only text reaches its merge; pointing "write a file
# from the target tree" at that pipeline would silently corrupt every binary
# the user chose to take.
#
# No-op decisions (ours / keep / skip) change nothing in the tree but STILL
# write an applied row — silence is never a record, and the gate's coverage
# compare needs every classified path accounted for.
#
# RE-RUN SAFE: enacting the same TSV twice yields the same tree;
# ask-user-applied.tsv is REWRITTEN (never appended) and confirmed-deletes.txt
# is REBUILT from this run's enacted deletes (truncated at the start of the
# enactment pass, then appended per delete — never appended across runs) so a
# redone Phase 5 or a retried step converges instead of compounding. Rebuild,
# not append-with-dedup: a delete enacted on attempt 1 and flipped to `keep` on
# a Phase 5 redo must not leave a stale line for Phase 6's stale-reference sweep
# to chase (the append-only shape was a real, if fail-safe, footgun here).
#
# Env in:  PHASE_KEY  required — proof-of-load key stated in phases/5-structural.md
#          RUN        migration state dir (required)
#          SYNTH      synthetic repo from materialize.sh — the enactment source (required)
#          DECISIONS  decisions TSV (default $RUN/ask-user-decisions.tsv)
#          TARGET_TAG tag naming the target tree in $SYNTH (default kairos-target)
# Cwd:     component root
# In:      $DECISIONS                 bucket <TAB> path <TAB> decision
#          $RUN/classification.tsv    ask-user rows; path is column 4
#          $RUN/classification-trees.tsv  the synthetic trees those rows were derived
#                                     from; a mismatch against $SYNTH is a hard stop,
#                                     the same one structural-merge.sh makes
#          $RUN/binaries.txt          local binary safety net from structural-merge.sh
#                                     (one path per line, plus an optional second
#                                     TAB field naming the pre-rename path; absent
#                                     reads as empty)
# Out:     $RUN/ask-user-applied.tsv  bucket <TAB> path <TAB> decision <TAB> outcome
#                                     (outcome: written | unchanged | deleted;
#                                     written files carry the tag's git mode —
#                                     644, or 755 for a 100755 entry)
#          $RUN/confirmed-deletes.txt REBUILT each successful run from THIS
#                                     run's enacted deletes (one line per path;
#                                     truncated at the start of the enactment
#                                     pass, then appended per delete — never
#                                     appended across runs; a renamed binary's
#                                     pre-rename path is one of those deletes)
# Exit:    0  every row enacted
#          1  $SYNTH missing $TARGET_TAG (repo-level absence — re-materialize),
#             a missing or drifted classification/SYNTH binding (the classification
#             was derived from other trees than $SYNTH now holds — re-run Phase 3,
#             don't retry Phase 5),
#             an incomplete decision set (one "MISSING: <bucket>:<path>" per item on
#             stderr — same shape as plan-completeness.sh), an invalid decision,
#             a duplicate row for the same path (a contradictory set must be
#             refused whole, not enacted in file order), a theirs/take whose
#             source blob is absent at $TARGET_TAG, a delete-flavored binary row
#             whose path is still PRESENT at $TARGET_TAG (the classification
#             contradicts the tree, and a `theirs` there would delete a file the
#             template still ships), or a non-blob git mode at
#             the tag (a symlink or gitlink cannot ride the blob write path).
#             On a validation refusal NO applied rows are written, the tree is
#             untouched, and any previous run's ask-user-applied.tsv is REMOVED
#             (same posture as a mid-enactment enact_fail, below) rather than
#             left in place. Why: a Phase 5 redo (reference/continue.md)
#             restores the tree with the path-scoped reset (`git checkout -- .
#             ':(exclude).kairos/migration-log.md'` + `git clean -fd -e
#             .kairos/intent.md`), which spares the gitignored $RUN — so a
#             stale COMPLETE
#             applied.tsv can survive a tree restore and go on describing an
#             enactment that restore already rolled back. "It still describes
#             the last completed enactment" is true but not sufficient: that
#             completed enactment may no longer be the tree on disk, and a
#             refused re-answer must not let the postmerge gate's coverage
#             compare pass on that stale record. confirmed-deletes.txt is left
#             untouched by a refusal — it is rebuilt only once validation
#             passes (see RE-RUN SAFE and the Out: section above). If a step
#             fails MID-enactment — the blob read (only when $SYNTH changed
#             after validation), a destination occupied by a directory or
#             symlink, a symlink among the destination's parent components
#             (writing or deleting through a link could land outside the
#             component tree while the coverage-only gate row still passes), or
#             a failed mkdir/mktemp/mv/rm — earlier rows in THIS attempt stay
#             enacted, the failing path is left unmodified (temp-file + mv,
#             never a truncating redirect), and ask-user-applied.tsv is REMOVED
#             so the postmerge gate fails closed instead of passing on a stale
#             applied set. confirmed-deletes.txt reflects only the deletes THIS
#             attempt enacted before the failing row — moot for the same
#             reason: the removed applied TSV already blocks the run, so only
#             an attempt that reaches exit 0 ever writes a confirmed-deletes.txt
#             Phase 6 will read. Nothing in the enactment loop may fail
#             silently: the gate row audits coverage, never the tree, so a
#             wrongly-recorded outcome is invisible to it. That rule covers the
#             applied TSV's OWN three writes as much as the tree ops — the
#             truncate of the temp, each row's append, and the final mv into
#             place. The final mv is the sharpest of the three: unchecked, a
#             failed rename exited 0 with "OK" while a PREVIOUS run's COMPLETE
#             ask-user-applied.tsv stayed in place and satisfied the postmerge
#             gate's coverage compare — the stale-record failure mode every
#             refusal path in this script removes that file to prevent. So it
#             fails through enact_fail like every other write.
set -u

# Phase-load guard: this key is stated ONLY in phases/5-structural.md, so an
# orchestrator that skipped loading that file cannot know it. The guard turns a
# skipped load into a stop instead of a phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "p2enxd25" ]] \
  || { echo "FAIL: load phases/5-structural.md first" >&2; exit 1; }

for v in RUN SYNTH; do
  [[ -n "$(eval echo "\${$v:-}")" ]] || { echo "FAIL: $v not set" >&2; exit 1; }
done
DECISIONS="${DECISIONS:-$RUN/ask-user-decisions.tsv}"
TARGET_TAG="${TARGET_TAG:-kairos-target}"

# $SYNTH validity probe — the same one structural-merge.sh runs, for the same
# reason: every blob this script writes comes from $TARGET_TAG, and a $SYNTH
# wiped between phases is REPO-level absence, not the legitimate blob-level
# absence the validation pass already reports per path. Probed before anything
# is read or written; the remedy is repeated in the message so the orchestrator
# can act without loading a doc.
git -C "$SYNTH" rev-parse --verify --quiet "$TARGET_TAG^{commit}" >/dev/null 2>&1 \
  || { echo "ERROR: $SYNTH is not a usable synthetic repo (missing tag $TARGET_TAG) — re-run scripts/materialize.sh (stamped; an unchanged re-run reuses the trees)" >&2; exit 1; }

[[ -f "$RUN/classification.tsv" ]] \
  || { echo "FAIL: $RUN/classification.tsv missing — run build-manifest.sh first" >&2; exit 1; }

# Classification/SYNTH binding — the SAME check structural-merge.sh makes, kept
# textually as close to it as two scripts can be, because two spellings of one
# rule are two rules the day they disagree. See that script's header for the
# reasoning; the short form is that the ask-user rows this script enacts come out
# of the same classification.tsv, so a $SYNTH re-materialized between Phase 3 and
# Phase 5 invalidates them exactly as it invalidates the merge rows — every
# bucket choice, every path. The per-path blob check below is not a substitute:
# a stale classification whose paths still resolve to valid blobs at the new tag
# passes it row by row and enacts a set of answers the user gave about a
# different tree. Verified here, before any list is read and before any file is
# touched, so a refusal is indistinguishable from not having run.
SBASE=kairos-base
STARGET="$TARGET_TAG"
CTREES="$RUN/classification-trees.tsv"
[[ -f "$CTREES" ]] || {
  echo "FAIL: $CTREES missing — $RUN/classification.tsv carries no synthetic-tree binding," >&2
  echo "      so it cannot be verified against the trees in $SYNTH." >&2
  echo "      Re-run Phase 3 classification (scripts/build-manifest.sh), then redo Phase 5." >&2
  exit 1
}
CT_DRIFT=""
for side in base target; do
  case "$side" in base) tag="$SBASE" ;; *) tag="$STARGET" ;; esac
  want=$(awk -F'\t' -v s="$side" '$1 == s { print $2; exit }' "$CTREES")
  have=$(git -C "$SYNTH" rev-parse --verify --quiet "$tag^{tree}" 2>/dev/null || echo "")
  [[ -n "$want" ]] && [[ "$want" = "$have" ]] && continue
  CT_DRIFT="$CT_DRIFT
        $side: classified against ${want:-<not recorded>}, $SYNTH now holds ${have:-<none>}"
done
[[ -z "$CT_DRIFT" ]] || {
  echo "FAIL: $RUN/classification.tsv was derived from different synthetic trees than $SYNTH holds now:$CT_DRIFT" >&2
  echo "      \$SYNTH was re-materialized after classification, so the ask-user set may name" >&2
  echo "      paths, buckets and blobs that no longer exist — enacting it would answer the" >&2
  echo "      user's decisions against a tree they never saw. Nothing was touched." >&2
  echo "      Re-run Phase 3 classification (scripts/build-manifest.sh) against this \$SYNTH," >&2
  echo "      then redo Phase 5." >&2
  exit 1
}

CLASSIFIED=$(mktemp "${TMPDIR:-/tmp}/aau-classified.XXXXXX")
DECIDED=$(mktemp "${TMPDIR:-/tmp}/aau-decided.XXXXXX")
RENAMES=$(mktemp "${TMPDIR:-/tmp}/aau-renames.XXXXXX")
DELFLAV=$(mktemp "${TMPDIR:-/tmp}/aau-delflav.XXXXXX")
APPLIED_TMP="$RUN/.ask-user-applied.tmp"
blob_tmp=
trap 'rm -f "$CLASSIFIED" "$DECIDED" "$RENAMES" "$DELFLAV" "$APPLIED_TMP" ${blob_tmp:+"$blob_tmp"}' EXIT

# --- the classified set: union of the three ask-user buckets, de-duped by path.
# classification.tsv rows come first so their bucket wins over the binaries.txt
# safety net when a path appears in both sources.
# binaries.txt is read with -F'\t' and field 1 taken, never `$0`: a rename-
# flavored row carries the pre-rename path as a second field, and splicing the
# whole line in would make the classified "path" a tab-joined pair that no
# decision row can ever match (a fail-closed MISSING for a path that was
# answered).
{
  awk -F'\t' '$1 == "binary-for-user" || $1 == "added-heavyweight-ask-user" || $1 == "deleted-heavyweight-ask-user" \
                { print $1 "\t" $4 }' "$RUN/classification.tsv"
  if [[ -f "$RUN/binaries.txt" ]]; then
    awk -F'\t' 'NF && $1 != "" { print "binary-for-user\t" $1 }' "$RUN/binaries.txt"
  fi
} | awk -F'\t' '!seen[$2]++' > "$CLASSIFIED"

# --- the rename map: <path> -> <pre-rename path>, for binary rows only.
# Same source order and the same first-wins rule as the classified set above, so
# the two can never disagree about which row describes a path. A row whose old
# path is empty or equal to the new one is not a rename and contributes nothing.
{
  awk -F'\t' '$1 == "binary-for-user" && $4 != "" && $5 != "" && $5 != $4 { print $4 "\t" $5 }' \
    "$RUN/classification.tsv"
  if [[ -f "$RUN/binaries.txt" ]]; then
    awk -F'\t' 'NF >= 2 && $1 != "" && $2 != "" && $2 != $1 { print $1 "\t" $2 }' "$RUN/binaries.txt"
  fi
} | awk -F'\t' '!seen[$1]++' > "$RENAMES"

# The path goes in through the ENVIRONMENT, never `awk -v`: awk expands escape
# sequences in a -v assignment, so a path carrying a backslash reaches the
# program mangled and can never match its own map row (the same rule
# build-manifest.sh's rename_target follows).
old_path_for() { # old_path_for <path> — the pre-rename path, or nothing
  p="$1" awk -F'\t' '$1 == ENVIRON["p"] { print $2; exit }' "$RENAMES"
}

# --- the delete-flavored set: binary rows the TEMPLATE deleted (see the header).
# Keyed off the classification row's existing status column, which the D arm is
# the only emitter of for this bucket; binaries.txt cannot contribute one. Both
# `theirs` arms below — the validation check and the enactment — read this one
# list, so they can never disagree about which rows have no blob to write.
awk -F'\t' '$1 == "binary-for-user" && $2 == "D" && $4 != "" { print $4 }' \
  "$RUN/classification.tsv" > "$DELFLAV"

is_delete_flavored() { # is_delete_flavored <path> — 0 iff `theirs` means DELETE
  LC_ALL=C grep -qxF -- "$1" "$DELFLAV"
}

# --- validation pass: parse and vet EVERY row before touching anything --------
# Split on tab positionally (same rationale as structural-merge.sh: `IFS=$'\t'
# read` treats tab as whitespace and collapses runs, shifting columns).
ERRORS=0
: > "$DECIDED"
if [[ -f "$DECISIONS" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    rest="$line"; F=()
    while :; do
      F+=("${rest%%$'\t'*}")
      case "$rest" in *$'\t'*) rest="${rest#*$'\t'}" ;; *) break ;; esac
    done
    bucket="${F[0]}" path="${F[1]:-}" decision="${F[2]:-}"
    if [[ -z "$bucket" ]] || [[ -z "$path" ]] || [[ -z "$decision" ]]; then
      echo "ERROR: malformed decision row (want bucket<TAB>path<TAB>decision): $line" >&2
      ERRORS=1; continue
    fi
    # PATH SHAPE — refused HERE, before any tree change, for the same reason
    # materialize-frontend.sh refuses an escaping MOUNT/MODULE_PATH: an absolute
    # path, a `.`/`./…`, or a `..` component makes enactment write or delete
    # OUTSIDE the component tree, while the coverage-only postmerge gate row
    # (which audits the classified path list, never the filesystem) still passes
    # — the exact "outside the component tree" hazard enact_delete/parents_real
    # guard mid-enactment, closed one step earlier so a hand-edited or hostile
    # decisions file can never reach the enactment loop at all. `..` matches only
    # as a whole path COMPONENT (`..`, `../x`, `x/..`, `x/../y`), never as a
    # substring, so a legitimately-named file like `a..b` stays enactable.
    case "$path" in
      /*|.|./*|..|../*|*/..|*/../*)
        echo "ERROR: decision row path '$path' is not a relative path inside the component tree (no absolute path, no '.', no '..' segment): $line" >&2
        ERRORS=1; continue ;;
    esac
    # Two rows for one path are a CONTRADICTION (take then skip, take then
    # delete), not emphasis — enacting them in file order would make the final
    # tree depend on row order and write a self-contradictory applied record.
    if LC_ALL=C grep -qxF -- "$path" "$DECIDED"; then
      echo "ERROR: duplicate decision row for $path — one path, one decision" >&2
      ERRORS=1; continue
    fi
    case "$bucket:$decision" in
      binary-for-user:theirs|binary-for-user:ours) ;;
      added-heavyweight-ask-user:take|added-heavyweight-ask-user:skip) ;;
      deleted-heavyweight-ask-user:delete|deleted-heavyweight-ask-user:keep) ;;
      *) echo "ERROR: invalid decision '$decision' for bucket '$bucket' ($path)" >&2
         ERRORS=1; continue ;;
    esac
    # Coverage join is (bucket, path), not path alone: a row citing the WRONG
    # bucket for a classified path — but a bucket:decision combination valid on
    # its own (e.g. deleted-heavyweight-ask-user:delete on a path the classifier
    # placed in added-heavyweight-ask-user) — would otherwise enact the
    # DECISION's semantics under a question the classifier never asked, and the
    # applied row would misstate which bucket was answered. The path goes in
    # through the ENVIRONMENT, never `awk -v` (awk expands escapes in a -v
    # assignment), matching old_path_for above. A path OUTSIDE the classified set
    # has no bucket to match against and stays enacted as written (the header's
    # out-of-set rule); only a path the classifier DID place is bucket-checked.
    cbucket_for=$(p="$path" awk -F'\t' '$2 == ENVIRON["p"] { print $1; exit }' "$CLASSIFIED")
    if [[ -n "$cbucket_for" ]] && [[ "$cbucket_for" != "$bucket" ]]; then
      echo "ERROR: decision row for $path cites bucket '$bucket' but the classifier placed it in '$cbucket_for' — the decision answers a different question than was asked" >&2
      ERRORS=1; continue
    fi
    case "$decision" in
      theirs|take)
        # Blob presence AND mode are vetted HERE, before any tree change: a
        # symlink entry at the tag (120000) passes cat-file -e, and rejecting
        # it only mid-enactment would first overwrite the destination with the
        # link-target text — violating the failing-path-left-unmodified rule.
        if [[ "$bucket" = binary-for-user ]] && is_delete_flavored "$path"; then
          # A delete-flavored row has NO source blob by construction, so the
          # presence check below would refuse every one of them. The CONVERSE is
          # what gets vetted: the tag must not carry the path. A row claiming the
          # template deleted a binary the target tree still ships is
          # self-contradictory (a hand-edited classification, a status column
          # mangled by an editor), and enacting `theirs` on it would delete a
          # live template file — so it is refused here, before any tree change,
          # rather than silently removing what the template still wants.
          if git -C "$SYNTH" cat-file -e "$TARGET_TAG:$path" 2>/dev/null; then
            echo "ERROR: $path is classified as a template-DELETED binary (status D) but $TARGET_TAG still carries it in $SYNTH — the classification contradicts the tree" >&2
            ERRORS=1
          fi
        elif ! git -C "$SYNTH" cat-file -e "$TARGET_TAG:$path" 2>/dev/null; then
          echo "ERROR: source blob absent at $TARGET_TAG:$path in $SYNTH" >&2; ERRORS=1
        else
          vmode=$(git -C "$SYNTH" ls-tree "$TARGET_TAG" -- ":(literal)$path" | awk '{print $1}')
          case "$vmode" in
            100644|100755) ;;
            *) echo "ERROR: unsupported git mode '${vmode:-none}' at $TARGET_TAG:$path — a symlink or gitlink cannot ride the blob write path" >&2
               ERRORS=1 ;;
          esac
        fi
        ;;
    esac
    printf '%s\n' "$path" >> "$DECIDED"
  done < "$DECISIONS"
fi

MISSING=0
while IFS= read -r crow; do
  [[ -n "$crow" ]] || continue
  cbucket="${crow%%$'\t'*}"; cpath="${crow#*$'\t'}"
  if ! LC_ALL=C grep -qxF -- "$cpath" "$DECIDED"; then
    echo "MISSING: $cbucket:$cpath" >&2
    MISSING=$((MISSING + 1))
  fi
done < "$CLASSIFIED"

if [[ "$MISSING" -gt 0 ]] || [[ "$ERRORS" -ne 0 ]]; then
  [[ "$MISSING" -gt 0 ]] \
    && echo "FAIL: $MISSING classified ask-user item(s) have no decision in $DECISIONS" >&2
  [[ "$ERRORS" -ne 0 ]] \
    && echo "FAIL: unusable decision row(s) in $DECISIONS (see ERROR lines above)" >&2
  # Same posture as enact_fail below: a Phase 5 redo restores the tree via the
  # path-scoped reset (reference/continue.md), which spares the gitignored $RUN, so
  # a stale COMPLETE ask-user-applied.tsv here could still describe an
  # enactment that tree restore already rolled back. Remove it so the
  # postmerge gate's coverage compare fails closed on ANY refused re-answer
  # instead of trusting a record that may no longer match the tree.
  rm -f "$RUN/ask-user-applied.tsv"
  echo "      Nothing was enacted and no applied rows were written." >&2
  exit 1
fi

# --- enactment pass (validation passed: every row below is well-formed) --------
# EVERY mid-enactment failure funnels through enact_fail: earlier rows stay
# enacted, but the applied TSV is removed so the postmerge gate's coverage
# compare fails closed instead of passing on a stale set (see Exit above).
# An unchecked step here is the one shape of bug the gate cannot see — it
# audits coverage, never the tree — so nothing in this loop may fail silently.
enact_fail() {
  rm -f "$APPLIED_TMP" "$RUN/ask-user-applied.tsv"
  echo "FAIL: $* — earlier rows in this pass stay enacted; ask-user-applied.tsv removed so the gate fails closed" >&2
  exit 1
}

# confirmed-deletes.txt is REBUILT here, once per successful validation pass —
# never appended across runs (see RE-RUN SAFE above). apply-ask-user.sh is its
# SOLE writer, so a delete enacted on attempt 1 and flipped to `keep` on a
# Phase 5 redo must not leave a stale line for Phase 6's stale-reference sweep
# to chase. Truncating HERE (after validation passed, never on a refusal —
# WI-4 above already fails the gate closed for that case) means a mid-pass
# enact_fail still leaves this attempt's already-enacted deletes recorded; the
# overall run is blocked regardless, because ask-user-applied.tsv is removed,
# so only an attempt that reaches exit 0 ever produces a confirmed-deletes.txt
# Phase 6 will read. Checked like every other write in this loop (see the
# "nothing may fail silently" rule above): an unchecked truncate that failed
# (the path replaced by a directory, made read-only, etc.) would leave stale
# lines in place while the rest of the pass enacted anyway and exited 0 —
# exactly the silent non-application WI-5 exists to close.
: > "$RUN/confirmed-deletes.txt" \
  || enact_fail "could not truncate confirmed-deletes.txt to rebuild it for this run"

# Writing or deleting THROUGH a symlinked parent would land the operation
# outside the git-visible path: the applied row would say written/deleted, the
# committed tree would say otherwise, and the coverage-only gate row cannot see
# it. Walk every parent component; missing dirs are fine (mkdir creates real
# ones), links are not.
parents_real() { # parents_real <./path> — 0 iff no parent component is a symlink
  local p
  p=$(dirname "$1")
  while [[ "$p" != "." ]] && [[ "$p" != "/" ]]; do
    [[ -L "$p" ]] && return 1
    p=$(dirname "$p")
  done
  return 0
}

# ONE delete, enacted and recorded — the shape the two UNCONDITIONAL delete paths
# share: a `deleted-heavyweight-ask-user:delete` row, and a `theirs` on a
# delete-flavored binary row (the template deleted the binary; adopting that IS
# the removal). Kept as one function because the two must not drift: a delete
# recorded in only one of them is a path Phase 6's stale-reference sweep never
# chases, and a missing symlink-parent check is a delete outside the component
# tree that the coverage-only gate row cannot see. The renamed-binary removal in
# the loop stays its own code: it is CONDITIONAL on the old path still existing
# (an absent one is a no-op, never a phantom confirmed-deletes line) and says so
# in its own message. `rm -f` exits non-zero on a directory, so a
# recorded `deleted` outcome can never stand for a path still in the tree; the
# append is checked like every other write in this loop, and no per-line dedup is
# needed because the file was truncated at the top of this pass and validation
# already refused a second row for this path.
enact_delete() { # enact_delete <path> <why-clause>
  local p="$1" why="$2" d
  case "$p" in /*|./*) d=$p ;; *) d=./$p ;; esac
  parents_real "$d" \
    || enact_fail "$p has a symlink parent component — enactment would delete outside the component tree"
  rm -f -- "$d" \
    || enact_fail "could not delete $p ($why; a directory here means the classified path was not a file)"
  printf '%s\n' "$p" >> "$RUN/confirmed-deletes.txt" \
    || enact_fail "could not append $p to confirmed-deletes.txt"
}

N=0; W=0; U=0; D=0
# Checked like the confirmed-deletes truncate above, and for the same class of
# reason: $APPLIED_TMP can survive a killed prior attempt (the trap never ran),
# so a truncate that failed silently left THAT attempt's rows in the file, the
# appends below stacked this attempt's rows on top, and the final mv installed
# the pair as one applied set — a superset the gate's coverage compare passes
# while it describes two different answer sets.
: > "$APPLIED_TMP" \
  || enact_fail "could not truncate $APPLIED_TMP before recording this pass's applied rows"
if [[ -f "$DECISIONS" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    rest="$line"; F=()
    while :; do
      F+=("${rest%%$'\t'*}")
      case "$rest" in *$'\t'*) rest="${rest#*$'\t'}" ;; *) break ;; esac
    done
    bucket="${F[0]}" path="${F[1]}" decision="${F[2]}"
    # `theirs` on a DELETE-FLAVORED binary row is a delete, not a write (see the
    # header): the template deleted the binary, so there is no blob at the tag and
    # adopting the template's change IS removing the file. Resolved to its own
    # enactment shape HERE, before the dispatch, so the case below stays one arm
    # per shape and the applied row still records the decision the user actually
    # gave (`theirs`) rather than this internal spelling.
    act="$decision"
    if [[ "$act" = theirs ]] && [[ "$bucket" = binary-for-user ]] \
       && is_delete_flavored "$path"; then
      act=theirs-delete
    fi
    case "$act" in
      theirs-delete)
        # Outcome `deleted`, never `written`: nothing was written, and an applied
        # row at odds with the tree is invisible to the coverage-only gate row.
        enact_delete "$path" "the template deleted this binary and 'theirs' adopts that"
        outcome=deleted; D=$((D + 1))
        ;;
      theirs|take)
        # All filesystem ops go through $dst — the same path anchored with ./
        # so a leading dash can never read as an option to dirname/mkdir/mv/
        # chmod. Records and git specs keep the original $path.
        case "$path" in /*|./*) dst=$path ;; *) dst=./$path ;; esac
        # The destination must be a regular non-symlink file or absent: `mv`
        # onto a directory (or a symlink) would silently drop the blob INSIDE
        # or THROUGH it, record `written`, and the gate row would PASS — the
        # silent non-enactment this script exists to end.
        if { [[ -e "$dst" ]] || [[ -L "$dst" ]]; } \
           && { [[ ! -f "$dst" ]] || [[ -L "$dst" ]]; }; then
          enact_fail "$path exists and is not a regular file — cannot enact '$decision' over a directory or symlink"
        fi
        parents_real "$dst" \
          || enact_fail "$path has a symlink parent component — enactment would write outside the component tree"
        pdir=$(dirname "$dst")
        mkdir -p "$pdir" \
          || enact_fail "mkdir failed for $pdir"
        # Raw blob bytes via a same-directory temp file + mv: a plain `> "$dst"`
        # redirect truncates the destination before git can fail. See the
        # BYTE-EXACT header rule — never route this through the merge pipeline.
        blob_tmp=$(mktemp "$pdir/.apply-ask-user.XXXXXX") \
          || enact_fail "mktemp failed under $pdir"
        git -C "$SYNTH" cat-file blob "$TARGET_TAG:$path" > "$blob_tmp" \
          || enact_fail "could not write $TARGET_TAG:$path from $SYNTH"
        mv "$blob_tmp" "$dst" \
          || enact_fail "could not move the written blob into place at $path"
        blob_tmp=
        # mktemp creates 0600 — apply the mode git records at the tag instead,
        # or a taken 100755 tool lands unexecutable in the structural commit.
        # The mode was vetted 100644/100755 during validation; anything else
        # here means $SYNTH changed mid-run.
        mode=$(git -C "$SYNTH" ls-tree "$TARGET_TAG" -- ":(literal)$path" | awk '{print $1}')
        case "$mode" in
          100755) chmod 755 "$dst" ;;
          100644) chmod 644 "$dst" ;;
          *) enact_fail "unsupported git mode '${mode:-none}' for $TARGET_TAG:$path — a symlink or gitlink cannot ride the blob write path" ;;
        esac
        # A RENAMED binary is not enacted until the OLD copy is gone (see the
        # header): the blob landed at the new path above, and neither route into
        # this script completed the rename — build-manifest.sh only classifies,
        # and structural-merge.sh diverted the row before its rename step. Left
        # behind, the old copy rides into the structural commit as a duplicate no
        # artifact names. Only binary rows can carry a rename, and only a path
        # that is really there is removed and recorded — an absent old path is a
        # no-op, never a phantom line for Phase 6's stale-reference sweep.
        if [[ "$bucket" = binary-for-user ]]; then
          oldp=$(old_path_for "$path")
          if [[ -n "$oldp" ]] && [[ "$oldp" != "$path" ]]; then
            # The rename OLD path comes from the classification's rename column,
            # which is hand-editable (structural-merge.md) — so it gets the SAME
            # shape gate the decision path took at validation (:321): an absolute
            # path, a `.`/`./…`, or a `..` component would steer the `rm -f` below
            # OUTSIDE the component tree, the exact hazard the decision-path gate
            # closes one step earlier. `..` matches only as a whole path component.
            case "$oldp" in
              /*|.|./*|..|../*|*/..|*/../*)
                enact_fail "the pre-rename path '$oldp' of $path is not a relative path inside the component tree (no absolute path, no '.', no '..' segment) — a hand-edited rename operand cannot reach the rm below" ;;
            esac
            case "$oldp" in /*|./*) odst=$oldp ;; *) odst=./$oldp ;; esac
            if [[ -e "$odst" ]] || [[ -L "$odst" ]]; then
              parents_real "$odst" \
                || enact_fail "$oldp (the pre-rename path of $path) has a symlink parent component — enactment would delete outside the component tree"
              rm -f -- "$odst" \
                || enact_fail "could not remove $oldp, the pre-rename path of $path (a directory here means the classified rename did not name a file)"
              printf '%s\n' "$oldp" >> "$RUN/confirmed-deletes.txt" \
                || enact_fail "could not append $oldp to confirmed-deletes.txt"
            fi
          fi
        fi
        outcome=written; W=$((W + 1))
        ;;
      ours|keep|skip)
        outcome=unchanged; U=$((U + 1))
        ;;
      delete)
        enact_delete "$path" "classified for deletion"
        outcome=deleted; D=$((D + 1))
        ;;
    esac
    # The row goes in AFTER its enactment, like every other record in this loop,
    # and is checked like every other write: the tree change above already
    # happened, so a dropped row is a silent divergence between the tree and the
    # only artifact that describes it — and for an out-of-set path (see the
    # header) it is a divergence no gate can ever see.
    printf '%s\t%s\t%s\t%s\n' "$bucket" "$path" "$decision" "$outcome" >> "$APPLIED_TMP" \
      || enact_fail "could not record the applied row for $path ($bucket / $decision -> $outcome) in $APPLIED_TMP — the enactment DID happen; only the record is missing"
    N=$((N + 1))
  done < "$DECISIONS"
fi
# The last write of the pass, and the one whose silent failure was worst: without
# this check a failed rename printed "OK: ask-user decisions enacted" and exited
# 0 while a PREVIOUS run's complete ask-user-applied.tsv stayed on disk and
# passed the postmerge gate's coverage compare — describing an enactment that is
# not the one just performed. enact_fail removes that file, which is exactly the
# posture every other refusal path here takes for the same reason.
#
# The status is captured on its own line rather than trailed by `|| enact_fail`
# (the shape every other write here uses) for one mechanical reason: the
# artifact-writer lint in tests/skill-lint.test.sh certifies an `mv`-written
# artifact by matching the DESTINATION at end of line, so a trailing `\` or `||`
# would leave $RUN/ask-user-applied.tsv with no detectable format owner. Same
# `RC=$?` idiom pre-flight.sh's sweep and record-context.sh's filter use.
mv "$APPLIED_TMP" "$RUN/ask-user-applied.tsv"
APPLIED_MV_RC=$?
[[ "$APPLIED_MV_RC" -eq 0 ]] \
  || enact_fail "could not install this pass's applied rows at $RUN/ask-user-applied.tsv (mv exit $APPLIED_MV_RC; the tree changes ARE enacted, and leaving a previous run's applied set in place would let the postmerge gate pass on a record of a different enactment)"

echo "OK: ask-user decisions enacted — $N row(s): $W written, $U unchanged, $D deleted" >&2
exit 0
