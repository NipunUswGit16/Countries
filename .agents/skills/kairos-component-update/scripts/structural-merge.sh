#!/usr/bin/env bash
# structural-merge.sh — execute the mechanical part of the structural step,
# driven by $RUN/classification.tsv (produced by build-manifest.sh).
#
# Handles these buckets:
#   added-mechanical                write target blob
#   renamed-mechanical              write target blob at new path, remove old
#   deleted-by-template-mechanical  delete the local file
#   merge-pipeline                  3-way merge; result recorded as clean or conflict
#
# All other buckets (binary-for-user, added-heavyweight-ask-user,
# deleted-heavyweight-ask-user, modify-delete-for-ai, renamed-with-mods-for-ai,
# noop-already-deleted, unknown-status) are the orchestrator's to handle — this
# script skips them.
#
# Blobs come from the synthetic repo built by materialize.sh, so they are already
# placeholder-substituted and already LF. No substitution happens here.
#
# $SYNTH VALIDITY: show_synth() swallows git errors because BASE-side blob
# absence is legitimate (an added file has an empty base). REPO-level absence is
# not: a $SYNTH wiped between phases would then render as a green run with every
# added-mechanical file written EMPTY and every merge run against an empty base.
# The two tags are therefore probed up front, before any list is truncated or any
# file is touched; show_synth() keeps swallowing the base-blob case.
#
# THEIRS-SIDE ABSENCE IS NEVER LEGITIMATE, hence write_theirs() rather than
# show_synth() for that side. Every bucket this script handles was classified
# BECAUSE the target tree carries the path (added/renamed: it is new there;
# merge-pipeline: it changed there), so a missing target blob means the
# classification is describing a tree that is not the one being merged. Read
# through the swallowing accessor it was invisible: the added file landed EMPTY
# in added.txt, and a merge-pipeline row whose ours side matched base merged
# "cleanly" to zero bytes and was recorded in clean-merged.txt — data loss
# reported as a green run, caught only where a compiler happened to object.
#
# THE PRE-SCAN IS WHERE THAT IS DECIDED, not the enactment loop. A hard error
# raised from inside the loop stops at the FIRST bad row, and every row before it
# is already enacted: a file written, a rename's source deleted, both recorded —
# a half-migrated tree behind an exit 1, which is the one thing the refusals
# promise not to leave (reference/structural-merge.md). So every row that will be
# written is vetted up front, before the output lists are truncated, before the
# previous attempt's resolver verdicts are removed, and before any tree write;
# ALL bad rows are reported at once, because the remedy is one Phase 3 redo for
# the whole set and a first-bad-row-only message hides how much is stale. This is
# apply-ask-user.sh's failing-path-left-unmodified rule, applied to the buckets
# this script enacts. write_theirs() keeps its own check as a backstop (a row
# reaching it unvetted would be a bug in the pre-scan, not a stale
# classification), and its message says the tree may be half-migrated, because by
# then it is.
#
# MODE, NOT JUST PRESENCE. A symlink at the target tag is a blob: it passes every
# existence probe, and `git show` of it prints the LINK TEXT, so writing it
# through the blob path lands a regular file whose content is a path
# ("/etc/passwd"). A gitlink is a commit and a directory is a tree at the same
# path shape. All three are unwritable rows named for what they are — an absent
# entry, a tree and a 120000 blob are three different operator problems and one
# "has no such file" message misdescribes two of them.
#
# CLASSIFICATION/SYNTH BINDING closes the same hole one level up. The pre-scan
# above only catches rows that name an entry it cannot write at all; a
# $SYNTH re-materialized between Phase 3 and Phase 5 invalidates EVERY row
# (statuses, merge bases, bucket choices) while most of them still merge
# plausibly. build-manifest.sh therefore stamps the two tree oids it derived from
# into $RUN/classification-trees.tsv, and this script refuses to merge against
# anything else. Tree oids, not commit oids: identical re-materialized content is
# correctly not a drift.
#
# LINE ENDINGS: all three merge inputs are normalized to LF and the merged output
# is always written LF. A file differing from the template only in CRLF-vs-LF
# would otherwise conflict in EVERY line — the single largest source of false
# conflict volume in the first production migration, drowning the real hunks.
# There is deliberately no preserve-ours mode and no .gitattributes awareness:
# one policy, stated once, is what makes the resulting diff explainable. Files
# whose "ours" side was rewritten are recorded in normalized-ours.txt so the
# migration log can declare the one-time whole-file diff rather than surprise
# the reviewer with it.
#
# RE-RUN SAFETY: a second invocation after a partial run would read a still-
# conflicted working-tree file back in as "ours" and nest diff3 markers inside
# diff3 markers — corrupting every conflicted file at once. So (mirroring how
# materialize.sh stamps completion to make re-entry explicit) the guard below
# refuses to run while any file recorded in a previous run's $RUN/conflicts.txt
# still carries live markers: restore the tree first — with the PATH-SCOPED
# reset (`git checkout -- . ':(exclude).kairos/migration-log.md'
# ':(exclude).kairos/intent.md' ':(exclude).kairos/manifest.yaml'` then
# `git clean -fd -e .kairos/intent.md`), never the blanket form: the tree at
# this moment legitimately carries an uncommitted migration-log entry (it rides
# the next commit by design) and a dirty .kairos/intent.md — TRACKED-MODIFIED
# when the component has recorded intent before (Phase 5 step 1's standing-intent
# re-confirmation, which the intent.md checkout exclusion protects) or a
# first-ever untracked file (which the clean's -e protects). The checkout must
# carry all THREE exclusions reference/continue.md owns: dropping the intent.md
# one reverts the tracked-modified re-confirmation, which nothing can regenerate.
# A blanket reset destroys all of it — then redo Phase 5.
# Once that guard passes, any resolver artifacts from a previous attempt
# ($RUN/resolutions.tsv and per-batch resolutions.<slug>.tsv) are removed: a
# redone merge must never inherit a prior attempt's verdicts — resolutions
# describe conflict hunks in a tree that no longer exists.
#
# EVERY WRITE IS CHECKED, because `set -u` without `-e` makes a failed write a
# no-op the next line cannot see. One read-only path or one full disk fails a
# single cp, printf or redirection and the loop carries straight on: the merged
# file never landed while the rename's old copy was removed anyway (both copies
# gone), or the file landed while conflicts.txt never got its row — and that row
# is the ONLY input to the re-run guard above, so the next Phase 5 reads the
# still-marked file back in as "ours" and nests markers, the exact corruption
# that guard exists to prevent. The staging blobs are the same hazard read
# backwards: $RUN/base, $RUN/target and $RUN/ours are never cleared between runs,
# so a failed stage on a redo leaves the PREVIOUS run's content at that path and
# it merges as if it were this run's. Every such site therefore fails loudly
# through write_failed(), naming the file and what state the tree and the records
# are in — the same disposition write_theirs() states, and for the same reason:
# these fire mid-enactment, so earlier rows ARE enacted.
#
# RECORD ORDER IS PART OF THAT CHECK. conflicts.txt is written BEFORE the marked
# content lands; every other record is written AFTER the write it describes. The
# asymmetry is the re-run guard: over-reporting conflicts.txt costs a listed-but-
# clean file (harmless — the guard greps it and finds no markers), while
# under-reporting it hides a marked file from the guard. Every other list is read
# as a statement that something happened to the tree, so for those a row standing
# for a write that failed is the harmful direction.
#
# Env in:  PHASE_KEY  required — proof-of-load key stated in phases/5-structural.md
#          SYNTH  BASE  TARGET  RUN     (cwd = component root)
#          BASE/TARGET are used only for the diff3 marker labels.
# Reads (in $RUN):
#   classification.tsv        the rows to enact (build-manifest.sh)
#   classification-trees.tsv  the synthetic trees those rows were derived from;
#                             a mismatch against $SYNTH is a hard stop
# Out (in $RUN):
#   clean-merged.txt     files that 3-way merged without conflict
#   conflicts.txt        files left with diff3 conflict markers (for the resolver)
#   merge-errors.txt     files git merge-file errored on
#   binaries.txt         files that turned out binary (local safety net) — ask the
#                        user. One path per line; a RENAME-flavored row appends a
#                        TAB and the pre-rename path (the rename was not completed
#                        — see merge_one), which apply-ask-user.sh enacts.
#   normalized-ours.txt  files whose working-tree copy was CRLF -> LF normalized
#   added.txt / deleted.txt / renamed.txt   mechanical actions taken
set -u

# Phase-load guard: this key is stated ONLY in phases/5-structural.md, so an
# orchestrator that skipped loading that file cannot know it. The guard turns a
# skipped load into a stop instead of a phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "p2enxd25" ]] \
  || { echo "FAIL: load phases/5-structural.md first" >&2; exit 1; }

for v in SYNTH BASE TARGET RUN; do
  [[ -n "$(eval echo "\${$v:-}")" ]] || { echo "FAIL: $v not set" >&2; exit 1; }
done

SBASE=kairos-base
STARGET=kairos-target

# $SYNTH validity probe (see header): repo-level absence is a hard stop, and the
# remedy is repeated in the message so the orchestrator can act without loading
# a doc.
for t in "$SBASE" "$STARGET"; do
  git -C "$SYNTH" rev-parse --verify --quiet "$t^{commit}" >/dev/null 2>&1 \
    || { echo "ERROR: $SYNTH is not a usable synthetic repo (missing tag $t) — re-run scripts/materialize.sh (stamped; an unchanged re-run reuses the trees)" >&2; exit 1; }
done

[[ -f "$RUN/classification.tsv" ]] || { echo "FAIL: $RUN/classification.tsv missing — run build-manifest.sh first" >&2; exit 1; }

# Classification/SYNTH binding (see header): verified here, before any list is
# truncated and before any file is touched, so a refusal is indistinguishable
# from not having run. Editing individual rows by hand (a wrong dir-rename
# pairing — reference/structural-merge.md) does not disturb the binding; only
# re-materializing $SYNTH does.
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
  echo "      \$SYNTH was re-materialized after classification, so every row may name a path," >&2
  echo "      status or merge base that no longer exists — merging against it would write" >&2
  echo "      empty files and record them as cleanly merged. Nothing was touched." >&2
  echo "      Re-run Phase 3 classification (scripts/build-manifest.sh) against this \$SYNTH," >&2
  echo "      then redo Phase 5." >&2
  exit 1
}

# LEADING-DASH OPERANDS. Every component path this script hands to a command is
# anchored through anchor(): `-dash.txt` reaches rm/cp/grep/dirname as a bundle of
# OPTIONS, not as a file, and each site failed differently and quietly — the
# deleted-by-template rm failed while deleted.txt recorded the deletion, a
# rename's old copy survived beside the new one while renamed.txt recorded the
# move, and the re-run guard's grep errored into /dev/null and read as "no live
# markers". `--` fixes rm/cp/grep/mv/merge-file and is used alongside; it does
# NOT fix `dirname`, which has no portable end-of-options marker, and the same
# path reaches both. Anchoring covers every site, so it is the rule here.
# RECORDS AND GIT SPECS KEEP THE ORIGINAL PATH: added.txt / deleted.txt /
# renamed.txt / conflicts.txt / clean-merged.txt are read by later phases (and by
# this script's own re-run guard, which anchors on the way back in), so a `./`
# would leak a second spelling of every path into them. Same split as
# apply-ask-user.sh.
#
# ...WHICH IS WHY EVERY RECORD WRITE IS `printf`, NEVER `echo`. Anchoring cannot
# help the records — they must carry the raw path — and bash's builtin `echo`
# treats an argument that is EXACTLY an option string (`-n`, `-e`, `-E`, `-ne`,
# `-neE`, any combination) as its own options: it writes an empty line, or with
# `-n` in the set no line at all. A file whose whole name is one of those then
# went UNRECORDED in a list the run reports from and later phases read: a
# conflicted file was absent from conflicts.txt, so no resolver was dispatched for
# it AND the re-run guard — which reads that list back — could not see it, so the
# next Phase 5 read the still-marked file in as "ours" and nested diff3 markers,
# the exact corruption that guard exists to prevent. `printf '%s\n'` has no such
# argument reading.
anchor() { case "$1" in /*|./*) printf '%s\n' "$1" ;; *) printf './%s\n' "$1" ;; esac; }

# Re-run guard (see header): must run BEFORE the output lists are cleared below,
# so a refusal leaves the previous run's conflicts.txt intact for the operator.
#
# `|| [ -n "$cf" ]` for the same reason the pre-scan and the enactment loop have
# it, and here it is the guard's own correctness: a conflicts.txt whose LAST line
# carries no trailing newline is a row `read` returns non-zero on, so without the
# clause the loop exits before ever testing that file — and the guard that exists
# to stop marker nesting waves the re-run through, nesting diff3 markers inside
# diff3 markers in the one file it was pointed at. This script's own writes always
# end in a newline; the shape arrives out of band, from an operator or an agent
# trimming resolved entries out of the list by hand (which the state-TSV docs
# sanction elsewhere) with an editor that drops the final newline.
if [[ -f "$RUN/conflicts.txt" ]]; then
  while IFS= read -r cf || [[ -n "$cf" ]]; do
    [[ -n "$cf" ]] || continue
    acf=$(anchor "$cf")
    [[ -f "$acf" ]] || continue
    if LC_ALL=C grep -qE -- '^(<{7}|\|{7}|>{7}) |^={7}$' "$acf" 2>/dev/null; then
      echo "FAIL: $cf (listed in $RUN/conflicts.txt by a previous run) still carries live conflict markers." >&2
      echo "      Re-running now would nest markers. Restore the tree first — path-scoped, never blanket:" >&2
      echo "        git checkout -- . ':(exclude).kairos/migration-log.md' ':(exclude).kairos/intent.md' ':(exclude).kairos/manifest.yaml'" >&2
      echo "        git clean -fd -e .kairos/intent.md" >&2
      echo "      (a blanket reset would destroy the pending migration-log entry and an untracked" >&2
      echo "      first-ever .kairos/intent.md — reference/continue.md owns this form)," >&2
      echo "      then redo Phase 5." >&2
      exit 1
    fi
  done < "$RUN/conflicts.txt"
fi

# Split a classification row on tabs into F[], preserving empty INTERIOR fields.
# `IFS=$'\t' read` collapses them (bash treats tab as whitespace): a for-AI row
# like `... M p DEST "" <comp_path>` has an empty old_tpath before a populated
# component_path, which would shift the columns. Those rows are skipped by both
# loops below, but a positional %%-split keeps every field correct regardless of
# which columns are populated, and is bash-3.2 safe. One splitter for the
# pre-scan and the enactment loop, so they can never disagree about a row.
split_row() { # split_row <line> — sets bucket status tpath dest old_tpath
  local rest="$1"
  F=()
  while :; do
    F+=("${rest%%$'\t'*}")
    case "$rest" in *$'\t'*) rest="${rest#*$'\t'}" ;; *) break ;; esac
  done
  bucket="${F[0]}" status="${F[1]:-}" tpath="${F[2]:-}" dest="${F[3]:-}" old_tpath="${F[4]:-}"
}

# Why <template_path> cannot be written out of the target tree — empty when it
# can. One `ls-tree` gives mode AND type, so absence, a tree, a gitlink and a
# symlink are told apart in one probe (see header: MODE, NOT JUST PRESENCE).
# `:(literal)` keeps a path containing glob characters from matching anything
# else; -z is unnecessary because only the leading mode/type fields are read.
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
    *) echo "unsupported git mode $mode at tag $STARGET — a symlink or gitlink cannot ride the blob write path (its link text would land as the file's content)"
       return 0 ;;
  esac
}

# Pre-scan (see header): every row this script would WRITE or REMOVE is vetted
# here, before the resolver verdicts are removed below, before the output lists are
# truncated and before any tree write. deleted-by-template-mechanical does NOT get
# the target-tree probe — those rows name a path the target tree cannot carry BY
# DEFINITION (the template deleted it), so theirs_problem would report a spurious
# absence for every one — but its enactment (rm -f -- "$dest") reads column 4, and
# an empty column 4 makes that `rm -f -- ./`, which fails MID-loop and is reported
# by write_failed as a disk/permissions fault: a stale or hand-edited row
# misdescribed as a filesystem problem, behind a half-enacted tree. So its one
# read input is vetted here too, before anything is removed. The ask-user / for-AI
# buckets stay out of scope — apply-ask-user.sh vets those itself.
BADROWS=""; NBAD=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  split_row "$line"
  case "$bucket" in added-mechanical|renamed-mechanical|merge-pipeline|deleted-by-template-mechanical) ;; *) continue ;; esac
  why=""
  if [[ "$bucket" = deleted-by-template-mechanical ]]; then
    # Enactment reads ONLY column 4 and never touches the target tree, so skip the
    # tpath / theirs_problem checks and vet the one input it does read.
    [[ -n "$dest" ]] || why="deleted row names no destination (column 4 is empty), so there is nothing to remove for it"
  elif [[ -z "$tpath" ]]; then
    why="row names no template path (column 3 is empty), so there is nothing to read from the target tree"
  elif [[ -z "$dest" ]]; then
    why="row names no destination (column 4 is empty), so nothing could be written for it"
  elif [[ "$bucket" = renamed-mechanical ]] && [[ -z "$old_tpath" ]]; then
    # A renamed-mechanical row's enactment ALWAYS writes the target blob at the new
    # path (write_theirs), but the old-path removal and the renamed.txt record both
    # live behind `if [ -n "$old_tpath" ]`. An empty column 5 therefore enacts a
    # SILENT, UNRECORDED write: the file lands but the move is in neither renamed.txt
    # nor added.txt, so the abort path's debris classifier and any post-mortem are
    # blind to it. Refuse it here, before anything is touched — consistent with this
    # pre-scan's refuse-everything-first design (see header).
    why="renamed-mechanical row names no pre-rename old path (column 5 is empty): its target blob would be written at the new path while the move is recorded in neither $RUN/renamed.txt nor $RUN/added.txt — invisible to abort's debris pass and to post-mortem. Likeliest cause: a hand-edited rename pairing (reference/structural-merge.md)"
  else
    why=$(theirs_problem "$tpath")
  fi
  [[ -n "$why" ]] || continue
  NBAD=$((NBAD + 1))
  BADROWS="$BADROWS
        $bucket ${tpath:-<no template path>}: $why"
done < "$RUN/classification.tsv"
[[ "$NBAD" -eq 0 ]] || {
  echo "FAIL: $NBAD classification row(s) name a target-side entry this merge cannot write:$BADROWS" >&2
  echo "      Likeliest cause: a stale classification — $RUN/classification.tsv was derived" >&2
  echo "      from a different target tree than the one being merged now. (A row naming no" >&2
  echo "      template path or no destination is a hand-edit slip instead — see" >&2
  echo "      reference/structural-merge.md on editing a wrong rename pairing.)" >&2
  echo "      Nothing was written, removed or recorded: the tree, this run's output lists and" >&2
  echo "      any previous attempt's resolver verdicts are exactly as they were." >&2
  echo "      Re-run Phase 3 classification (scripts/build-manifest.sh) against this \$SYNTH," >&2
  echo "      then redo Phase 5." >&2
  exit 1
}

# The live-marker guard and the pre-scan above have passed, so this is a
# legitimate fresh/redo merge: clear the previous attempt's resolver verdicts
# (see header). Placed AFTER both so a refused run leaves them intact.
# (`rm -f` treats an unexpanded no-match glob as a missing operand and stays
# silent — no nullglob dance needed under set -u.)
rm -f "$RUN/resolutions.tsv" "$RUN"/resolutions.*.tsv

# BASE-side materialized template blob at <tag:path>; empty output if the blob is
# absent, which for that side is legitimate (an added file has an empty base).
show_synth() { git -C "$SYNTH" show "$1" 2>/dev/null || true; }

# THEIRS-side accessor: write the target-tree blob for <template_path> to
# <outfile>. The pre-scan above already vetted every row that reaches here, so
# this check is a backstop against a bug in that scan, not the stale-
# classification path — and unlike the pre-scan it fires mid-enactment, so its
# message says what that means for the tree. Checked BEFORE <outfile> is opened,
# so it never leaves an empty or truncated file behind.
write_theirs() { # write_theirs <template_path> <outfile>
  local d out why
  why=$(theirs_problem "$1")
  [[ -z "$why" ]] || {
    echo "FAIL: $1 is classified for the merge but $why" >&2
    echo "      Nothing was written for it, but earlier rows in this pass ARE enacted:" >&2
    echo "      restore the tree — path-scoped, never blanket (reference/continue.md):" >&2
    echo "        git checkout -- . ':(exclude).kairos/migration-log.md'" >&2
    echo "        git clean -fd -e .kairos/intent.md" >&2
    echo "      then redo Phase 5 after re-running Phase 3 classification" >&2
    echo "      (scripts/build-manifest.sh) against this \$SYNTH. (This row should have been" >&2
    echo "      refused by the pre-scan before anything was touched — reaching here means" >&2
    echo "      that scan missed it.)" >&2
    exit 1
  }
  # Anchored before dirname: an unanchored `-dash.txt` made dirname print a usage
  # error, so $d was EMPTY and the row died on "could not create " — a legal
  # filename reported as an unwritable destination with no path in the message.
  out=$(anchor "$2")
  d=$(dirname "$out")
  mkdir -p "$d" || { echo "FAIL: could not create $d (for $2)" >&2; exit 1; }
  git -C "$SYNTH" show "$STARGET:$1" > "$out" \
    || { echo "FAIL: could not read $STARGET:$1 out of $SYNTH" >&2; exit 1; }
}

# NUL byte in the first 8KB → binary. (Deliberately NOT `grep -q $'\x00'` —
# shell arguments can't carry NUL, so that pattern silently becomes empty and
# matches everything.)
is_binary_file() {
  [[ -f "$1" ]] || return 1
  [[ "$(head -c 8192 "$1" | LC_ALL=C tr -d '\000' | wc -c)" -ne "$(head -c 8192 "$1" | wc -c)" ]]
}

# The output lists start empty, and a truncation that FAILED is checked here
# rather than discovered later: an unwritable list keeps the previous attempt's
# rows and this run then appends to them, so clean-merged.txt would claim files
# this pass never touched (and every append to that same list is going to fail
# anyway). Still ahead of every tree write, so the disposition is milder than
# write_failed()'s — nothing is enacted yet.
for f in clean-merged.txt conflicts.txt merge-errors.txt binaries.txt \
         normalized-ours.txt added.txt deleted.txt renamed.txt; do
  : > "$RUN/$f" || {
    echo "FAIL: could not truncate $RUN/$f — this run cannot record what it does." >&2
    echo "      Nothing has been written to the working tree and no row has been recorded, but" >&2
    echo "      the lists cleared before this one are now empty and a previous attempt's resolver" >&2
    echo "      verdicts have already been removed." >&2
    echo "      Fix the write failure (disk space, permissions on $RUN), then redo Phase 5." >&2
    exit 1
  }
done

# Enactment-time write failure (see header: EVERY WRITE IS CHECKED). Distinct
# from write_theirs()'s refusal, which names a stale classification: a write that
# fails names an ENVIRONMENT problem — a full disk, a read-only path, a lock — so
# re-running Phase 3 would only re-derive the same rows. Fix that first, and only
# then restore and redo. The per-site lines say what state that file's content and
# records are in; the epilogue below says what the pass as a whole left behind.
write_failed() { # write_failed <headline> [detail-line...]
  local l
  echo "FAIL: $1" >&2; shift
  for l in "$@"; do echo "      $l" >&2; done
  echo "      This fired mid-enactment, so earlier rows in this pass ARE enacted: the tree is" >&2
  echo "      half-migrated and this run's output lists describe only the rows before this one." >&2
  echo "      Fix the write failure (disk space, permissions on the paths named above), then" >&2
  echo "      restore the tree — path-scoped, never blanket (reference/continue.md):" >&2
  echo "        git checkout -- . ':(exclude).kairos/migration-log.md'" >&2
  echo "        git clean -fd -e .kairos/intent.md" >&2
  echo "      and redo Phase 5." >&2
  exit 1
}

# A component that replaced a template-managed file with a symlink is a CONFLICT,
# not a mechanical action. Every working-tree write below (write_theirs to $dest,
# cp of the merged blob to $a_dest) opens the destination through whatever is
# there — so a `[ -L ]` destination sends git show / cp output to the LINK TARGET,
# potentially outside the repo, while the tree keeps the link and no artifact of
# this run names the divergence. apply-ask-user.sh (enact) refuses the same shape
# with its own dest check; here the file is ROUTED to conflicts.txt (the user
# checkpoint) rather than removed: the link is component intent, and silently
# erasing it to write over it is the very unrecorded non-enactment this script
# exists to end. A symlink parked in conflicts.txt is the harmless direction for
# the re-run guard (it greps the file for markers and finds none).
# Returns 0 to proceed with the write, 1 when it routed the row (caller skips).
route_symlink_dest() { # route_symlink_dest <dest>
  [[ -L "$(anchor "$1")" ]] || return 0
  printf '%s\n' "$1" >> "$RUN/conflicts.txt" \
    || write_failed "could not record the symlink conflict at $1 in $RUN/conflicts.txt" \
         "$1 is a symlink in the working tree where the template carries a regular file, so" \
         "nothing was written to it — a write would follow the link, possibly outside the repo —" \
         "but the row that routes it to its user checkpoint could not be recorded."
  echo "  routed $1 to conflicts (symlink where the template carries a regular file)" >&2
  return 1
}

merge_one() { # merge_one <status> <template_path> <dest> <old_template_path?>
  local status="$1" tpath="$2" dest="$3" old_tpath="${4:-}"
  # Checked BEFORE any staging: a symlink at $dest is routed to conflicts and this
  # row is skipped, so neither the ours side is staged THROUGH the link nor the
  # merged blob written back THROUGH it. See route_symlink_dest.
  route_symlink_dest "$dest" || return
  local base_blob="$RUN/base/$dest" tgt_blob="$RUN/target/$dest" ours_blob="$RUN/ours/$dest"
  mkdir -p "$(dirname "$base_blob")" "$(dirname "$tgt_blob")" "$(dirname "$ours_blob")" \
    || write_failed "could not create the staging directories under $RUN for $dest" \
         "None of the three merge inputs could be staged, so nothing was merged or written."

  # Base: for renames the baseline content lived at the OLD path. For a rename
  # re-paired by build-manifest.sh this is precisely the recovered merge base.
  #
  # The check is on the REDIRECTION, not on git: show_synth() swallows the git
  # error because base-side blob absence is legitimate (an added file has an empty
  # base). A failed redirection is never legitimate, and it is not a no-op either
  # — $RUN/base, $RUN/target and $RUN/ours are never cleared between runs, so on a
  # redo the file already at that path is the PREVIOUS run's content, which would
  # then be merged as if this run had staged it (see header).
  show_synth "$SBASE:${old_tpath:-$tpath}" > "$base_blob" \
    || write_failed "could not stage the base side of $dest at $base_blob" \
         "Nothing was written for $dest. On a redo that path may still hold the PREVIOUS run's" \
         "base blob, which is why this is a stop and not a warning."
  write_theirs "$tpath" "$tgt_blob"

  # Ours: the component's current file. For renames the user may still have it
  # at the old location — merge from wherever it lives.
  # $a_* are the anchored spellings (see anchor()): everything handed to cp, rm
  # or dirname below goes through them, while $dest/$old_dest keep the original
  # spelling for the records and the "is this a real rename" comparison.
  local ours_src="$dest" old_dest="" a_dest a_old="" a_ours
  a_dest=$(anchor "$dest")
  if [[ -n "$old_tpath" ]]; then
    old_dest="$old_tpath"
    a_old=$(anchor "$old_dest")
    [[ ! -e "$a_dest" ]] && [[ -e "$a_old" ]] && ours_src="$old_dest"
  fi
  a_ours=$(anchor "$ours_src")
  # Same stale-blob hazard as the base side above, and the worse half of it: this
  # blob is what git merge-file merges IN PLACE and what is then copied over the
  # working-tree file, so a failed stage on a redo would merge the previous run's
  # "ours" and write the result over the component's current file.
  if [[ -f "$a_ours" ]]; then
    cp -- "$a_ours" "$ours_blob" \
      || write_failed "could not stage the component's current $ours_src at $ours_blob" \
           "Nothing was written for $dest. That blob is the one merge-file rewrites in place and" \
           "the one copied over the working-tree file, so on a redo a stale copy of it would be" \
           "merged as 'ours' and land on top of the component's current content."
  else
    : > "$ours_blob" \
      || write_failed "could not stage an empty ours side for $dest at $ours_blob" \
           "Nothing was written for $dest. The component has no file at $ours_src, so this side" \
           "must be truncated to empty; leaving a previous run's blob there would merge it as" \
           "though the component still carried that content."
  fi

  # Local binary safety net (template-side binaries were routed earlier). Checked
  # BEFORE normalization: stripping 0x0D from a binary would corrupt it.
  #
  # RENAME-AWARE, because this return is taken BEFORE the rename is completed
  # below: nothing was written at $dest and $a_old still holds the component's
  # copy. Recording the bare new path made the user's later `theirs` answer land
  # the blob at the new path with the old copy still beside it — a silent
  # duplicate in the structural commit that no artifact named. So a rename-
  # flavored row (an R100 whose local copy is customized, or a paired-by-dir-
  # rename row) records the OLD path as a second TAB-separated field, and
  # apply-ask-user.sh removes it when the user takes theirs. The second field is
  # APPENDED, never inserted: every reader of this list takes the path from field
  # 1, so a non-rename row stays byte-identical to what it always was.
  #
  # The append is checked because that list is the ONLY thing that routes the file
  # to its user checkpoint: unrecorded, the run reaches "OK: structural merge done"
  # with the file silently left undecided and named by no artifact.
  if is_binary_file "$ours_blob" || is_binary_file "$tgt_blob" || is_binary_file "$base_blob"; then
    if [[ -n "$old_dest" ]] && [[ "$old_dest" != "$dest" ]]; then
      printf '%s\t%s\n' "$dest" "$old_dest" >> "$RUN/binaries.txt" \
        || write_failed "could not record the binary $dest (renamed from $old_dest) in $RUN/binaries.txt" \
             "The tree is untouched for it — nothing was written at $dest and $old_dest still holds" \
             "the component's copy — but that list is what takes it to its user checkpoint."
    else
      printf '%s\n' "$dest" >> "$RUN/binaries.txt" \
        || write_failed "could not record the binary $dest in $RUN/binaries.txt" \
             "The tree is untouched for it, but that list is what takes it to its user checkpoint."
    fi
    return
  fi

  # Normalize ours to LF. base/theirs arrive LF from materialize.sh; doing ours
  # here (not there) is what lets us record which working-tree files were touched.
  if LC_ALL=C grep -q $'\r' "$ours_blob" 2>/dev/null; then
    LC_ALL=C tr -d '\r' < "$ours_blob" > "$ours_blob.lf" && mv "$ours_blob.lf" "$ours_blob" \
      || write_failed "could not normalize the ours side of $dest to LF" \
           "Nothing was written for $dest. The un-normalized copy is still at $ours_blob, and" \
           "merging it against the LF base and theirs sides would conflict on EVERY line."
    printf '%s\n' "$dest" >> "$RUN/normalized-ours.txt" \
      || write_failed "could not record $dest in $RUN/normalized-ours.txt" \
           "Nothing was written for $dest. Its working-tree copy is about to be rewritten" \
           "CRLF -> LF, and that list is what makes the resulting whole-file diff a declared" \
           "one-time change instead of a surprise for the reviewer."
  fi

  # 3-way merge with diff3 markers. git merge-file modifies the first arg in
  # place; exit code = conflict count (1..127), >=128 means a real error.
  git merge-file --diff3 \
    -L "ours" -L "base (template@${BASE:0:7})" -L "theirs (template@${TARGET:0:7})" \
    "$ours_blob" "$base_blob" "$tgt_blob"
  local rc=$?

  # On a real error (>=128) merge-file may leave the blob mangled — leave the
  # working tree untouched and let the orchestrator inspect the file as-is.
  #
  # RENAME-AWARE for the same reason binaries.txt is above: this return is taken
  # BEFORE the rename below completes, so nothing was written at $dest and the
  # component's copy still sits at the OLD path. A record naming only $dest sends
  # the orchestrator to inspect a path that does not exist, while the old copy
  # rides silently into the structural commit as a duplicate no artifact names.
  # Same shape as binaries.txt: the old path is an APPENDED second TAB field, so
  # every reader takes the path from field 1 and a non-rename row is unchanged.
  if [[ "$rc" -ge 128 ]]; then
    if [[ -n "$old_dest" ]] && [[ "$old_dest" != "$dest" ]]; then
      printf '%s\t%s\n' "$dest" "$old_dest" >> "$RUN/merge-errors.txt" \
        || write_failed "could not record the merge-file error on $dest (renamed from $old_dest) in $RUN/merge-errors.txt" \
             "git merge-file exited $rc and the working tree was deliberately left untouched for" \
             "this file — the component's copy is still at $old_dest, nothing exists at $dest —" \
             "so unrecorded the error would vanish from a run that reports OK."
    else
      printf '%s\n' "$dest" >> "$RUN/merge-errors.txt" \
        || write_failed "could not record the merge-file error on $dest in $RUN/merge-errors.txt" \
             "git merge-file exited $rc and the working tree was deliberately left untouched for" \
             "this file, so unrecorded the error would vanish from a run that reports OK."
    fi
    return
  fi

  # The conflict row is recorded BEFORE the marked content lands, and a failed
  # append is a stop BEFORE that write for the same reason: the re-run guard reads
  # conflicts.txt to find files that may carry live markers, so neither a kill nor
  # a failed append between the two may leave a MARKED file the guard cannot see.
  # A listed-but-clean file is the harmless direction (the guard greps it and finds
  # nothing); a marked-but-unlisted one is the corruption the guard exists to
  # prevent. Hence record-before-write here and write-before-record everywhere
  # else, where a row stands for something that happened to the tree (see header).
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$dest" >> "$RUN/conflicts.txt" \
      || write_failed "could not record the conflict in $dest in $RUN/conflicts.txt" \
           "Nothing was written to $dest, so the tree carries no markers this missing row could" \
           "hide from the re-run guard — which is exactly why the row goes first."
  fi

  mkdir -p "$(dirname "$a_dest")" \
    || write_failed "could not create the directory for $dest" \
         "Nothing was written for it; the merged content is staged at $ours_blob."
  if ! cp -- "$ours_blob" "$a_dest"; then
    if [[ -n "$old_dest" ]] && [[ "$old_dest" != "$dest" ]]; then
      write_failed "could not write the merged result of $dest" \
        "The merged content is staged at $ours_blob and $dest is unchanged. The pre-rename copy" \
        "at $old_dest was NOT removed: that rm sits below this write and is gated on it, so a" \
        "failed write can never leave the file at neither path. The rename is not completed."
    else
      write_failed "could not write the merged result of $dest" \
        "The merged content is staged at $ours_blob; the working-tree file is unchanged."
    fi
  fi
  # Complete the rename once content has landed at the new path — reached only
  # when the write above succeeded, so the old copy outlives a failed write.
  if [[ -n "$old_dest" ]] && [[ "$old_dest" != "$dest" ]]; then
    rm -f -- "$a_old" \
      || write_failed "wrote the merged $dest but could not remove the pre-rename copy at $old_dest" \
           "The tree now carries BOTH paths — the merged content at $dest and the component's" \
           "pre-rename copy at $old_dest — and no artifact of this run names that duplicate."
  fi

  # Recorded AFTER the write, the opposite way round from the conflict row above:
  # a clean-merged row for a file that was never written tells every later phase
  # the template's change landed when it did not.
  if [[ "$rc" -eq 0 ]]; then
    printf '%s\n' "$dest" >> "$RUN/clean-merged.txt" \
      || write_failed "could not record the clean merge of $dest in $RUN/clean-merged.txt" \
           "The merged content IS in the working tree at $dest; only the record is missing, so" \
           "later phases would read this file as untouched by the template."
  fi
}

# `|| [ -n "$line" ]` for the same reason the pre-scan has it: a final row with no
# trailing newline must be enacted, not silently dropped — and the two loops must
# agree on the row set, or the pre-scan is vetting rows the enactment skips (or
# worse, skipping rows it enacts).
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  split_row "$line"          # same splitter the pre-scan used (see split_row)
  [[ -n "${bucket:-}" ]] || continue
  case "$bucket" in
    # The record appends and the rm's are checked for the same reason merge_one's
    # are (see header): unchecked, a failed rm left the rename's old copy beside
    # the new one — or the deleted file in place — while the record said the
    # action had happened, and the run still reported OK.
    added-mechanical)
      # A symlink at $dest is a conflict, not a mechanical add: write_theirs would
      # follow it (git show > the link target). Route and skip. See route_symlink_dest.
      route_symlink_dest "$dest" || continue
      write_theirs "$tpath" "$dest"
      printf '%s\n' "$dest" >> "$RUN/added.txt" \
        || write_failed "wrote $dest but could not record it in $RUN/added.txt" \
             "The file IS in the working tree; only the record of the addition is missing."
      ;;
    renamed-mechanical)
      # A symlink at the rename DESTINATION is a conflict, not a mechanical rename:
      # write_theirs would follow it, and the old-path removal below would then drop
      # the component's only regular copy. Route and skip (old copy left in place).
      route_symlink_dest "$dest" || continue
      write_theirs "$tpath" "$dest"
      if [[ -n "$old_tpath" ]]; then
        if [[ "$old_tpath" != "$dest" ]]; then
          rm -f -- "$(anchor "$old_tpath")" \
            || write_failed "wrote $dest but could not remove the pre-rename copy at $old_tpath" \
                 "The tree now carries BOTH paths and no artifact of this run names the duplicate."
        fi
        printf '%s\n' "$old_tpath -> $dest" >> "$RUN/renamed.txt" \
          || write_failed "completed the rename $old_tpath -> $dest but could not record it in $RUN/renamed.txt" \
               "The tree is correct; only the record of the move is missing."
      fi
      ;;
    deleted-by-template-mechanical)
      rm -f -- "$(anchor "$dest")" \
        || write_failed "could not delete $dest, which the template removed" \
             "The file is still in the working tree and was NOT recorded as deleted."
      printf '%s\n' "$dest" >> "$RUN/deleted.txt" \
        || write_failed "deleted $dest but could not record it in $RUN/deleted.txt" \
             "The file IS gone from the working tree; only the record of the deletion is missing."
      ;;
    merge-pipeline)
      merge_one "$status" "$tpath" "$dest" "$old_tpath"
      ;;
    *) ;; # ask-user / for-AI buckets: orchestrator's job
  esac
done < "$RUN/classification.tsv"

echo "OK: structural merge done" >&2
for f in clean-merged conflicts merge-errors binaries normalized-ours added deleted renamed; do
  n=$(grep -c . "$RUN/$f.txt" || true)
  [[ "${n:-0}" -gt 0 ]] && echo "  $f: $n" >&2
done
if [[ -s "$RUN/normalized-ours.txt" ]]; then
  echo "  NOTE: the files above were CRLF and are now LF — declare this in the" >&2
  echo "        migration log; their diffs will show every line changed." >&2
fi
exit 0
