#!/usr/bin/env bash
# build-manifest.sh — diff the two CLI-materialized template trees and classify
# every changed file into a routing bucket. Classification only uses what is
# knowable WITHOUT merging (diff status + local file state) — whether a merge is
# clean or conflicted is discovered later by structural-merge.sh, as a result.
#
# Content and paths arrive ALREADY substituted, because materialize.sh built both
# sides with `kairos component create` (see its header for why). So this script
# performs no substitution of its own: a synthetic-repo path IS the component
# path, and `template_path` and `dest` carry the same value. The old in-script
# sed map is gone precisely because it drifted from the CLI's behavior.
#
# Env in:  PHASE_KEY  required — proof-of-load key stated in phases/3-classify.md
#          SYNTH  synthetic repo from materialize.sh (tags kairos-base/kairos-target)
#          CACHE  template mirror — real HISTORY, needed for upgrade-file
#                 discovery (the synthetic repo has only two commits)
#          BASE   baseline template SHA (history addressing)
#          TARGET target template SHA
#          RUN    migration state dir
#          MODULE optional — the source-repo module this run migrates. VALIDATED
#                 against the source's .kairos-updates/config.yaml at TARGET when that
#                 file exists: an undeclared key is a hard refusal, because scoping the
#                 walks to a nonexistent directory collects nothing and reports success.
#                 Set, the
#                 upgrade-file walks are scoped to `.kairos-updates/<MODULE>/`
#                 (a configured source repo files its upgrade-files per module at
#                 the REPO ROOT, outside the subtree it mounts); empty or absent,
#                 they cover `.kairos-updates/` as they always have. Collection
#                 semantics — commit order, newest body, amend-in-range — are the
#                 same either way; only the directory the walks look in changes
# Cwd:     component root
# Out (in $RUN):
#   diff.raw.tsv                `git diff --name-status -M -z` of the two sides,
#                               NUL stream converted to TAB-delimited rows carrying
#                               the RAW path bytes (see the diff block)
#   diff.tsv                    same, with directory-rename pairs folded into RP rows
#   dir-rename-pairs.tsv        old <TAB> new — renames re-paired by this script
#   classification.tsv          bucket <TAB> status <TAB> template_path <TAB> dest
#                               <TAB> old_template_path <TAB> component_path <TAB> tag
#   classification-trees.tsv    side <TAB> tree-oid — the identities of the two
#                               synthetic trees classification.tsv was derived
#                               from; structural-merge.sh refuses to merge
#                               against anything else (see below). Removed before
#                               the first artifact write and re-written as the
#                               LAST one, so it is also this run's completion
#                               stamp: an interrupted run leaves none
#   component-rename-map.tsv    old(baseline) <TAB> new(component) <TAB> score
#   deleted-heavyweight-dirs.txt  subtrees the template empties wholesale
#   upgrades-added.txt          upgrade-files added in BASE..TARGET, in commit order,
#                               carrying RAW path bytes (the history walks read -z,
#                               like the diff; a TAB/newline in an upgrade-file name
#                               is a hard stop naming the file, never a silent drop)
#   upgrades-added.tsv          <add-commit-sha> <TAB> <path>, same order
#   upgrades-modified.txt       upgrade-files amended (not added) in BASE..TARGET
#   upgrades/<basename>.md      snapshot of each added/modified upgrade-file's BODY,
#                               read from the commit that introduced/amended it
#                               (0 bytes when the committed file is empty — that is
#                               a body, not a failure; see snap_upgrade)
#   frontend-floors.tsv          <upgrade-file-path> <TAB> <module> <TAB> <floor-sha>,
#                               one row per crossed upgrade-file declaring
#                               requires-frontend: (empty file = no floor in
#                               range, the common case). Column 1 is the EXACT
#                               path string from upgrades-added.txt/-modified.txt
#   snapshot-refusals.tsv       slug <TAB> source <TAB> reason — one row per body
#                               that could NOT be read (git show failed). The WARN
#                               is stderr-only and the call sites are `|| true`, so
#                               this is what makes a refusal visible to the phase
#                               and to next-upgrade-file.sh
#   legacy-upgrade-commits.txt  commits ADDING or MODIFYING legacy root UPGRADE.md
#                               (--diff-filter=AM keeps only adds/modifies, so a
#                               commit that merely removes UPGRADE.md carries no
#                               migration note and retiring the frozen file leaves
#                               no junk entry — NOT the lowercase-exclude form
#                               --diff-filter=d, which drops all rows under a
#                               pathspec walk with history simplification)
#   binaries-template.txt       template-side binary paths (from --numstat)
#   summary.txt                 bucket <TAB> count tally, plus move/rename/
#                                heavyweight-deletion counts — the documented
#                                read path in place of `cat classification.tsv`
#   query.sh                    executable; `query.sh <bucket> [column]` wraps
#                                the awk forms callers used to hand-retype
set -u

HERE=$(cd "$(dirname "$0")" && pwd)

# Phase-load guard: this key is stated ONLY in phases/3-classify.md, so an
# orchestrator that skipped loading that file cannot know it. The guard turns a
# skipped load into a stop instead of a phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "i82l699l" ]] \
  || { echo "FAIL: load phases/3-classify.md first" >&2; exit 1; }

for v in SYNTH CACHE BASE TARGET RUN; do
  [[ -n "${!v:-}" ]] || { echo "FAIL: $v not set" >&2; exit 1; }
done
mkdir -p "$RUN"

SBASE=kairos-base
STARGET=kairos-target

# --- resolve the two sides ONCE -----------------------------------------------
# Both tags are resolved to TREE oids here, and every tree read below (the diff,
# --numstat, ls-tree, git show) addresses those oids instead of the tag names.
# The same two oids are stamped into classification-trees.tsv as the LAST
# artifact write of the run (the binding block at the bottom), so the file names
# the trees the rows were actually derived from AND its presence certifies that
# the whole artifact set was written — see that block for why it is a stamp.
#
# ONE read, not two, because the second read was a TOCTOU window: the diff took
# the tags at the top of the script and the stamp re-read them ~450 lines later.
# A $SYNTH re-materialized in between (a corrected BASE, a moved TARGET, a
# concurrent FORCE_MATERIALIZE) moved the tags between the two reads, so the
# stamp described trees the classification was NOT derived from — and
# structural-merge.sh's binding check, whose entire job is catching exactly that
# drift, then passed and merged the stale classification "clean", silently
# dropping a file that the certified target tree carries. Narrowing the window is
# not a fix; removing the second read is. The resolution doubles as the
# tag-existence probe, so there is no earlier read either.
T_BASE=$(git -C "$SYNTH" rev-parse --verify --quiet "$SBASE^{tree}" 2>/dev/null || echo "")
T_TARGET=$(git -C "$SYNTH" rev-parse --verify --quiet "$STARGET^{tree}" 2>/dev/null || echo "")
[[ -n "$T_BASE" ]] && [[ -n "$T_TARGET" ]] || {
  echo "FAIL: $SYNTH carries no usable $SBASE/$STARGET tags (could not resolve their trees) — run scripts/materialize.sh first" >&2
  exit 1
}

# --- the binding is a COMPLETION STAMP ----------------------------------------
# Torn down HERE, before the first artifact write of the run, and re-written as
# the very LAST one (the binding block at the bottom). In between, every artifact
# this script owns is half-written, and the binding is the only thing that tells
# Phase 5 whether it may trust them.
#
# It has to be a stamp because a stale binding cannot detect its own staleness: a
# run killed between the truncations below and the stamp (a TERM, a timeout, a
# closed session) left a PARTIAL classification.tsv beside the PREVIOUS run's
# binding — which still MATCHED, because $SYNTH had not moved. So
# structural-merge.sh's binding check passed, gate.sh's binding row printed
# "binding verified", and every row after the kill point was silently dropped
# from the migration: 52 of 600 rows merged, exit 0, PASS. A kill in the
# upgrade-discovery block was the same shape one artifact over — a complete-
# looking, certified classification beside an EMPTIED upgrades-added.txt, i.e.
# every migration step the template ships silently skipped.
#
# An interrupted run now leaves NO binding, so Phase 5 hard-stops on the missing
# one (a refusal naming the Phase 3 redo) instead of merging a fragment. The two
# badnames refusals below tear it down explicitly for the same reason: they exit
# before reaching the stamp, and re-running the phase is what re-writes it.
rm -f "$RUN/classification-trees.tsv"

# Substituted template blob at <tree-oid:path>; empty output if the blob is absent.
show_synth() { git -C "$SYNTH" show "$1" 2>/dev/null || true; }

# Does the component's local file still match the materialized template blob at a
# side? Used to tell "unmodified" from "customized". The synthetic side is already
# LF (materialize.sh normalizes on the way in); the local side may not be.
#
# AN ABSENT LOCAL FILE IS NOT A MATCH, and the guard is load-bearing rather than
# defensive: with $2 missing, `tr -d '\r' < "$2"` produced 0 bytes (its error
# swallowed by the 2>/dev/null on the caller's side), so an absent local file
# compared EQUAL to an EMPTY template blob. The R100 arm below only guarantees
# that ONE of OLD_DEST/DEST exists, so a template that renamed a 0-byte
# placeholder classified `renamed-mechanical` for a component that had deleted the
# old path and written its OWN content at the new one — and Phase 5 enacts that
# bucket by overwriting the destination unconditionally, i.e. customized content
# destroyed with no conflict and no checkpoint. "Missing" is a different answer
# from "identical", including when the template blob is empty.
matches_template() { # matches_template <tree-oid:path> <local-file>
  [[ -f "$2" ]] || return 1
  git -C "$SYNTH" show "$1" 2>/dev/null | cmp -s - <(tr -d '\r' < "$2")
}

# BYTE-EXACT variant, for BINARY rows only: no LF normalization on either side.
# matches_template above strips 0x0D from the local side and not from the blob,
# which is right for text and wrong for a binary — a blob that differs from the
# baseline only by embedded 0x0D bytes would compare EQUAL and be routed to the
# mechanical delete, i.e. a customized binary removed without ever asking. Same
# `<(… < "$2")` shape as above so a leading-dash path is never an operand.
matches_template_raw() { # matches_template_raw <tree-oid:path> <local-file>
  [[ -f "$2" ]] || return 1
  git -C "$SYNTH" show "$1" 2>/dev/null | cmp -s - <(cat < "$2")
}

# OURS-SIDE binary probe: NUL byte in the first 8KB. Substantively identical to
# structural-merge.sh's is_binary_file, and needed HERE because the buckets that
# never enter that script's merge pipeline (the for-AI and ask-user ones) never
# reach its safety net either — for those arms the classifier is the only layer
# that can see a file the COMPONENT made binary. Deliberately NOT
# `grep -q $'\x00'`: shell arguments cannot carry NUL, so that pattern silently
# becomes empty and matches everything. The file is read through `<` so a
# leading-dash path can never be an option to head.
is_binary_local() { # is_binary_local <local-file>
  [[ -f "$1" ]] || return 1
  [[ "$(head -c 8192 < "$1" | tr -d '\000' | wc -c)" \
    -ne "$(head -c 8192 < "$1" | wc -c)" ]]
}

# --- diff ---------------------------------------------------------------------
# RAW PATH BYTES, via -z. `core.quotepath=off` is NOT enough and never was: it
# governs bytes >= 0x80 only, so a path carrying a `"`, a `\` or any other <0x80
# special still arrived C-quoted ("wei\"rd.txt") and that spelling then travelled
# through classification into every consumer as a path that exists nowhere. The
# damage was not cosmetic: structural-merge.sh's pre-scan refused the WHOLE run
# ("absent from the target tree … re-run Phase 3") over a perfectly legal file,
# and re-running Phase 3 reproduced the same rows forever — an unrecoverable
# migration behind a looping remedy. A quoted member also silently defeated the
# `[ ! -e "$DEST" ]` probe (row → noop-already-deleted) and the emptied-subtree
# scan, so the wholesale-deletion checkpoint disappeared for the run.
#
# `-z` emits paths verbatim (quotepath cannot apply), so the invariant every
# consumer depends on holds for any filename git can store: classification.tsv
# rows carry the RAW path bytes.
#
# TAB and NEWLINE are the exception, and they are a hard stop rather than a
# quoting problem: diff.tsv and classification.tsv are TAB-delimited line
# records, so such a path cannot ride the format at all. See the refusal below.
TABCH=$'\t'
NLCH=$'\n'

# Convert a `--name-status -z` stream on stdin into TAB-delimited rows carrying
# raw path bytes: `<status>\t<path>[\t<path2>]`. Paths that cannot ride a
# TAB-delimited line record are NOT emitted; they are appended to <badfile>, one
# `printf %q` rendering per line, so the caller can name them in a message
# without the name itself breaking the message.
z_name_status() { # z_name_status <badfile>   (stream on stdin, rows on stdout)
  local bad="$1" st p1 p2
  while IFS= read -r -d '' st; do
    [[ -n "$st" ]] || continue
    IFS= read -r -d '' p1 || break
    case "$st" in
      R*|C*) IFS= read -r -d '' p2 || break ;;
      *)     p2="" ;;
    esac
    case "$p1$p2" in
      *"$TABCH"*|*"$NLCH"*)
        printf '%q\n' "$p1" >> "$bad"
        [[ -n "$p2" ]] && printf '%q\n' "$p2" >> "$bad"
        continue ;;
    esac
    if [[ -n "$p2" ]]; then printf '%s\t%s\t%s\n' "$st" "$p1" "$p2"
    else                  printf '%s\t%s\n'     "$st" "$p1"
    fi
  done
}

# Written to a file first, and its status checked, so a failed diff can never
# reach the parser as "no changes at all".
git -C "$SYNTH" diff --name-status -M -z "$T_BASE" "$T_TARGET" > "$RUN/.diff.z" \
  || { echo "FAIL: could not diff the synthetic trees in $SYNTH — re-run scripts/materialize.sh" >&2; exit 1; }
: > "$RUN/.diff-badnames.txt"
z_name_status "$RUN/.diff-badnames.txt" < "$RUN/.diff.z" > "$RUN/diff.raw.tsv"
if [[ -s "$RUN/.diff-badnames.txt" ]]; then
  # Nothing usable is left for Phase 5: the classification is emptied AND its
  # tree binding removed, so a Phase 5 run against this $RUN hard-stops on the
  # missing binding instead of merging an empty row set and reporting success.
  : > "$RUN/classification.tsv"
  rm -f "$RUN/classification-trees.tsv"
  echo "FAIL: the template change carries file name(s) this migration cannot represent:" >&2
  sed 's/^/        /' "$RUN/.diff-badnames.txt" >&2
  echo "      A TAB or a newline in a filename cannot ride \$RUN/diff.tsv or" >&2
  echo "      \$RUN/classification.tsv — both are TAB-delimited line records — and carrying" >&2
  echo "      it quoted instead would hand every downstream consumer a path that exists" >&2
  echo "      nowhere. Nothing in this phase can work around the name, so repeating the" >&2
  echo "      phase cannot clear this." >&2
  echo "      Remedy: rename the file in the template (or in the component, if that is the" >&2
  echo "      side that carries it) to drop the TAB/newline, then redo Phase 2.5" >&2
  echo "      (materialize) and this phase." >&2
  exit 1
fi
rm -f "$RUN/.diff.z" "$RUN/.diff-badnames.txt"

# --- directory-rename auto-pairing --------------------------------------------
# When a whole directory is renamed, git pairs most files by similarity but drops
# any file whose content changed too much to clear the 50% threshold. That file
# then splits into a fake delete + a fake add: the add lands as a brand-new file
# and the merge LOSES ITS BASE, so heavy template changes arrive as a wholesale
# overwrite instead of as reviewable conflicts.
#
# We can recover it. If >=3 renames git DID detect share one old-dir -> new-dir
# mapping, that directory rename is corroborated by evidence independent of the
# file in question. An unpaired delete + add whose paths differ only by that
# mapping AND whose basenames match exactly is then the same file, and we rewrite
# the pair into a single RP row carrying the old path as the true merge base.
#
# Both conditions are load-bearing: the >=3 corroboration stops one coincidental
# rename from inventing a mapping, and the exact-basename test stops two
# unrelated files from being welded together.
: > "$RUN/dir-rename-pairs.tsv"
awk -F'\t' '$1 ~ /^R/ {
    od = $2; if (sub(/\/[^\/]*$/, "", od) == 0) od = "."
    nd = $3; if (sub(/\/[^\/]*$/, "", nd) == 0) nd = "."
    if (od != nd) c[od "\t" nd]++
  }
  END { for (k in c) if (c[k] >= 3) print k }' "$RUN/diff.raw.tsv" \
  > "$RUN/dir-rename-maps.tsv"

awk -F'\t' -v OFS='\t' -v pairs="$RUN/dir-rename-pairs.tsv" -v maps="$RUN/dir-rename-maps.tsv" '
    # Load the corroborated old-dir -> new-dir mappings with getline, NOT the usual
    # `FNR == NR` two-file idiom. Most migrations contain fewer than 3 directory
    # renames, so this map file is normally EMPTY — and with an empty first file FNR
    # never advances for it, leaving FNR == NR true for every record of the SECOND
    # file. The idiom would then swallow the whole diff as map entries and emit an
    # empty classification: no changed files, no merge, silently. getline is immune.
    # (A dir renamed to two places at once is pathological; last one wins.)
    BEGIN { while ((getline line < maps) > 0) {
              split(line, a, "\t"); if (a[1] != "") map[a[1]] = a[2] } }
    { n++; st[n] = $1; p1[n] = $2; p2[n] = $3
      if ($1 == "A") addidx[$2] = n
      if ($1 == "D") delidx[$2] = n
    }
    END {
      for (d in delidx) {
        dd = d; if (sub(/\/[^\/]*$/, "", dd) == 0) dd = "."
        b = d;  sub(/^.*\//, "", b)
        if (!(dd in map)) continue
        cand = (map[dd] == "." ? b : map[dd] "/" b)
        if (!(cand in addidx)) continue
        i = addidx[cand]
        # AN ADD ROW CAN BE CLAIMED ONCE, so claiming it removes it from the pool.
        # Two old directories can each carry a corroborated mapping into the SAME
        # new one (a template folding oldapi/ and oldweb/ into api/), and when both
        # also carry an unpaired delete of the same BASENAME, both deletes matched
        # this one add row: the second claim overwrote the merge base of the first RP
        # row (which of the two, decided by hash order), while the second delete was
        # still marked dropped and VANISHED from diff.tsv — a template deletion
        # silently skipped, with no bucket, no merge and nothing on stderr. The
        # row-conservation check below could not see it either: the bogus second pair
        # row paid for the lost delete row and the arithmetic balanced. First claimant
        # wins; the other delete keeps its plain D row, which is the honest answer —
        # nothing corroborates WHICH of two same-named files became the one add.
        # (No apostrophes in this block: the whole program rides single quotes.)
        delete addidx[cand]
        st[i] = "RP"; p1[i] = d; p2[i] = cand   # reuse the add row slot
        dropped[delidx[d]] = 1
        print d, cand > pairs
      }
      for (i = 1; i <= n; i++) {
        if (i in dropped) continue
        if (st[i] ~ /^(R|RP)/) print st[i], p1[i], p2[i]
        else                   print st[i], p1[i]
      }
    }
  ' "$RUN/diff.raw.tsv" > "$RUN/diff.tsv"

# The pairing pass rewrites rows; it must never LOSE any. A silent drop here shows
# up as "no changed files" rather than as an error, so assert the invariant.
RAW_N=$(grep -c . "$RUN/diff.raw.tsv" || true)
OUT_N=$(grep -c . "$RUN/diff.tsv" || true)
PAIR_N=$(grep -c . "$RUN/dir-rename-pairs.tsv" || true)
if [[ "$((OUT_N + PAIR_N))" -ne "${RAW_N:-0}" ]]; then
  echo "FAIL: rename-pairing lost rows — raw=$RAW_N out=$OUT_N paired=$PAIR_N" >&2
  exit 1
fi

if [[ -s "$RUN/dir-rename-pairs.tsv" ]]; then
  sort -o "$RUN/dir-rename-pairs.tsv" "$RUN/dir-rename-pairs.tsv"
  echo "INFO: re-paired $(grep -c . "$RUN/dir-rename-pairs.tsv") rename(s) across corroborated directory renames" >&2
fi

# --- upgrade-file discovery (reads real template HISTORY, not the trees) -------
# Order matters: upgrade-files apply in COMMIT order (the order they landed on the
# template's default branch), not filename/timestamp order — a timestamp is set by
# the author's clock and can disagree with merge order. So walk the log oldest-first
# (--reverse) and dedupe while PRESERVING that order (awk instead of `sort -u`, which
# would re-sort alphabetically and destroy commit order). Within a single commit git
# emits paths in tree order (alphabetical ≈ timestamp), a stable intra-commit tiebreak.
#
# ONE pass produces two outputs:
#   upgrades-added.txt  paths in apply (first-seen) order — dedupe keeps the FIRST
#                       commit a path was added in, which is its apply slot.
#   upgrades-added.tsv  <newest-add-sha> <TAB> <path>, same order — we read each
#                       file's BODY from that sha below. Because --reverse is
#                       oldest-first, the LAST sha seen per path is its newest
#                       addition, so a delete-then-re-add of the same path snapshots
#                       the corrected (latest) body, not the stale first one.
# Reading bodies from history (not the TARGET tip) is essential: authors prune
# already-shipped upgrade-files from the working directory, so each squashed PR
# commit carries only the files IT introduced, and `.kairos-updates/` at
# TARGET does NOT hold the full history. `--pretty=format:'commit %H'` tags each
# commit; the awk carries that SHA down onto the file lines that follow it.
#
# WHICH DIRECTORY the walks look in is the one thing a module-scoped source changes.
# A configured source repo (`.kairos-updates/config.yaml`) files each module's
# upgrade-files at `.kairos-updates/<module>/` at the REPO ROOT — they cannot live
# inside the subtree the CLI copies into the mount — so a run migrating one module
# must walk that module's directory and NO OTHER. Collecting a sibling module's
# files would manufacture migration steps for a template this component was never
# built from; the walks below are pathspec-scoped AND the parsers re-check the
# prefix, because a pathspec is a filter and the prefix check is the invariant.
# Empty MODULE is today's behavior, byte for byte.
MODULE=${MODULE:-}
if [[ -n "$MODULE" ]]; then
  # VALIDATED against the source's own config.yaml at TARGET first. A module key is a
  # STRING that names a directory, so a stale or mis-cased one ('React', a module the
  # component was migrated off) silently scopes every walk to a directory that does not
  # exist: zero upgrade-files collected, no error, "OK" on stdout, and a plan that
  # drops every migration step the range actually carried. That is the one failure this
  # scoping must not have, and the source repo already declares the answer.
  #
  # Only when the config is READABLE at TARGET: a source repo that does not
  # self-describe (or a frontend repo older than the config) cannot be asked, and there
  # the passed key stands exactly as before — an unvalidatable key is not an invalid
  # one. A KNOWN module with zero upgrade-files in range stays a success: that is the
  # ordinary "nothing to migrate" answer.
  MODULE_CFG=.kairos-updates/config.yaml
  if command -v yq >/dev/null 2>&1 \
     && git -C "$CACHE" cat-file -e "$TARGET:$MODULE_CFG" 2>/dev/null; then
    MODULE_KNOWN=$(git -C "$CACHE" show "$TARGET:$MODULE_CFG" 2>/dev/null \
                     | MOD="$MODULE" yq -r '.modules | has(strenv(MOD))' - 2>/dev/null || echo "")
    if [[ "$MODULE_KNOWN" != true ]]; then
      MODULE_DECLARED=$(git -C "$CACHE" show "$TARGET:$MODULE_CFG" 2>/dev/null \
                          | yq -r '.modules | keys | join(", ")' - 2>/dev/null || echo "")
      echo "FAIL: MODULE='$MODULE' is not declared in the source's $MODULE_CFG at TARGET (it declares: ${MODULE_DECLARED:-<none readable>}). Every upgrade-file walk below would be scoped to .kairos-updates/$MODULE/ — a directory that does not exist — so the run would collect NOTHING and report success, dropping every migration step this range carries. Fix the module key (the component manifest's frontend.template selects it) and re-run this phase." >&2
      exit 1
    fi
  fi
  UPG_DIR=".kairos-updates/$MODULE/"
  echo "INFO: upgrade-file collection scoped to $UPG_DIR (module '$MODULE')" >&2
else
  UPG_DIR=".kairos-updates/"
fi

mkdir -p "$RUN/upgrades"
: > "$RUN/upgrades-added.txt"
: > "$RUN/upgrades-added.tsv"
# Frontend compatibility floor (PRD frontend-compatibility-floor): truncated here
# like every other per-run artifact below, and populated once both snapshot
# passes complete (see the extraction loop after the modify-pass). Empty file =
# no floor declared in this range = the common case = zero behavioural change.
: > "$RUN/frontend-floors.tsv"
# Supersede edges — this collector's OWN artifact (never shared with
# collect-common.sh / collect-lib.sh, which write their own per-source files), so
# a plain truncate here is safe and a Phase 3 redo cannot clobber another
# source's rows. Populated by the extraction loop after both snapshot passes.
: > "$RUN/supersede-edges.tsv" \
  || { echo "FAIL: cannot truncate $RUN/supersede-edges.tsv — refusing to classify over a stale edge file (is $RUN writable?)" >&2; exit 1; }

# Snapshots land in the SHARED $RUN/upgrades/ dir keyed by BASENAME only (the
# same dir collect-common.sh writes common-library snapshots into), so two
# DIFFERENT upgrade-files that happen to share a basename would silently
# overwrite each other and one body would vanish before the planner ever saw
# it. Every write goes through snap_upgrade, which records basename -> source
# in a sidecar and WARNs (never fails — the newest write still wins, matching
# the intentional modified-pass body override) when a basename is re-written
# from a DIFFERENT source with different content. Same-source overwrites (an
# amend of the same file) stay silent by design.
SNAP_SOURCES="$RUN/upgrade-snapshot-sources.tsv"
# Truncated here, at the Phase 3 write, like every other per-run artifact: rows
# accumulated across re-runs would make the collision WARN fire against this
# run's own predecessor. collect-common.sh APPENDS its Phase 3.5 rows to this
# same file later and drops only its own on re-run — do not truncate again there.
: > "$SNAP_SOURCES"
# Refused snapshots are recorded here, one row per refusal: slug <TAB> source
# <TAB> reason. collect-common.sh appends its Phase 3.5 rows to this same file and
# drops only its own on re-run. next-upgrade-file.sh reads it to tell a FAILED
# capture from a body that was simply never collected.
#
# PER-SOURCE truncation, not a whole-file one, because preservation that runs in
# only ONE direction is not preservation. This side used to truncate the whole
# file while collect-common.sh surgically replaced just its own rows, so a Phase 3
# redo — the documented remedy when Phase 5 finds no binding (phases/5-structural.md)
# — DELETED Phase 3.5's common-module refusal rows. next-upgrade-file.sh then
# flipped from exit 5 ("the capture was refused; re-running is not the remedy") to
# exit 4 ("never captured — re-run the phase") for those slugs, i.e. it pointed the
# planner straight at the loop those two exit codes exist to keep it out of.
# OUR rows are the ones whose SOURCE id is a bare path; collect-common's carry a
# module prefix ("<module>:.kairos-updates/…"), which a template source id — which
# IS a path — can never be. Same predicate as there, inverted.
SNAP_REFUSALS="$RUN/snapshot-refusals.tsv"
# The prune chain is CHECKED stage by stage (under `set -u` alone an `&&` chain
# just short-circuits): a failed awk or mv used to skip the truncation silently
# AND leak the temp, leaving THIS run's stale template refusal rows in place —
# and next-upgrade-file.sh reads them to answer exit 5 ("refused; re-running is
# not the remedy") for slugs this run never refused, the very stale-loop this
# reset exists to clear. On any failure the temp is removed and the run stops.
if [[ -f "$SNAP_REFUSALS" ]]; then
  reftmp=$(mktemp "${TMPDIR:-/tmp}/snap-refusals.XXXXXX") \
    || { echo "FAIL: could not create a temp file to prune $SNAP_REFUSALS" >&2; exit 1; }
  # The ^[^:]+:\.kairos-updates/ shape is shared by common and lib and is safe
  # only because their RUN_SOURCEs are disjoint (one $RUN ledger only ever holds
  # one of the two).
  if ! awk -F'\t' '$2 ~ /^[^:]+:\.kairos-updates\//' "$SNAP_REFUSALS" > "$reftmp"; then
    rm -f "$reftmp"
    echo "FAIL: could not prune stale rows from $SNAP_REFUSALS — a stale refusal row left here makes next-upgrade-file.sh answer exit 5 for a slug this run never refused." >&2
    exit 1
  fi
  mv "$reftmp" "$SNAP_REFUSALS" \
    || { rm -f "$reftmp"; echo "FAIL: could not replace $SNAP_REFUSALS with its pruned copy — check that $RUN is writable." >&2; exit 1; }
else
  : > "$SNAP_REFUSALS" \
    || { echo "FAIL: could not create $SNAP_REFUSALS — check that $RUN is writable." >&2; exit 1; }
fi
#
# READ-FAILURE vs EMPTY-BODY lives in scripts/lib/snap-upgrade.sh (story 42).
# RAW PATH BYTES / -z parsing lives in scripts/lib/z-log-name-only.sh. The
# walks below are unchanged; only the helper definitions moved out.
[[ -r "$HERE/lib/snap-upgrade.sh" ]] \
  || { echo "FAIL: missing $HERE/lib/snap-upgrade.sh — it owns snap_upgrade (story 42)" >&2; exit 1; }
[[ -r "$HERE/lib/z-log-name-only.sh" ]] \
  || { echo "FAIL: missing $HERE/lib/z-log-name-only.sh — it owns z_log_name_only (story 42)" >&2; exit 1; }
# shellcheck source=lib/snap-upgrade.sh
. "$HERE/lib/snap-upgrade.sh" \
  || { echo "FAIL: could not source $HERE/lib/snap-upgrade.sh" >&2; exit 1; }
# shellcheck source=lib/z-log-name-only.sh
. "$HERE/lib/z-log-name-only.sh" \
  || { echo "FAIL: could not source $HERE/lib/z-log-name-only.sh" >&2; exit 1; }
[[ -r "$HERE/lib/supersede-edges.sh" ]] \
  || { echo "FAIL: missing $HERE/lib/supersede-edges.sh — it owns supersede_emit" >&2; exit 1; }
# shellcheck source=lib/supersede-edges.sh
. "$HERE/lib/supersede-edges.sh" \
  || { echo "FAIL: could not source $HERE/lib/supersede-edges.sh" >&2; exit 1; }

# TAB and NEWLINE stay the hard stop they are on the diff side, and for the same
# reason: upgrades-added.txt is a line list and upgrades-added.tsv a TAB-delimited
# line record, so such a name cannot ride EITHER — no quoting scheme makes it
# representable. Note the diff-side refusal cannot cover this: materialize.sh
# strips .kairos-updates/ from both synthetic trees, so an upgrade-file name only
# ever surfaces on these history walks. Called at TOP level after each conversion
# (never from inside a `… | while` subshell, where `exit` would kill only the
# subshell and let the run finish "OK").
UPG_BAD="$RUN/.upgrades-badnames.txt"
: > "$UPG_BAD"
# Records the parser could not attribute to a commit (see z_log_name_only). Kept in
# its own ledger, and refused with its own message, because the remedy is a
# different one: nothing about the FILE is wrong, the walk's OUTPUT is.
UPG_STRAY="$RUN/.upgrades-strayrecords.txt"
: > "$UPG_STRAY"
upg_refuse_stray() { # upg_refuse_stray <which-walk>
  [[ -s "$UPG_STRAY" ]] || return 0
  # Same teardown as the other two refusals: an empty, unbound classification is
  # what stops Phase 5 from merging as if this run had succeeded.
  : > "$RUN/classification.tsv"
  rm -f "$RUN/classification-trees.tsv"
  echo "FAIL: $1 emitted output this phase cannot parse — record(s) that belong to no commit:" >&2
  sed 's/^/        /' "$UPG_STRAY" >&2
  echo "      Each upgrade-file path has to be attributed to the commit that introduced it," >&2
  echo "      and these records arrived before any 'commit <sha>' header, so the walk's own" >&2
  echo "      output is carrying text that is not part of the log. Continuing would drop" >&2
  echo "      those records — i.e. skip migration steps the template ships — and report" >&2
  echo "      success." >&2
  echo "      Most likely cause: git config that writes to 'git log' STDOUT (e.g." >&2
  echo "      log.showSignature=true against signed template commits). This phase already" >&2
  echo "      passes --no-show-signature, so check \`git -C $CACHE config --list\` for other" >&2
  echo "      output-injecting log.* settings, unset it for the mirror, and re-run this phase." >&2
  exit 1
}
upg_refuse_badnames() {
  [[ -s "$UPG_BAD" ]] || return 0
  # Same teardown as the diff refusal: nothing usable is left for Phase 5, so the
  # classification is emptied AND its tree binding removed — a stale pair from a
  # previous run would otherwise let Phase 5 merge as if this run had succeeded.
  : > "$RUN/classification.tsv"
  rm -f "$RUN/classification-trees.tsv"
  echo "FAIL: the template carries upgrade-file name(s) this migration cannot represent:" >&2
  sed 's/^/        /' "$UPG_BAD" >&2
  echo "      A TAB or a newline in a filename cannot ride \$RUN/upgrades-added.txt (a line" >&2
  echo "      list) or \$RUN/upgrades-added.tsv (a TAB-delimited line record), and dropping" >&2
  echo "      it silently would skip a migration step the template ships. Nothing in this" >&2
  echo "      phase can work around the name, so repeating the phase cannot clear this." >&2
  echo "      Remedy: rename the upgrade-file in the template to drop the TAB/newline," >&2
  echo "      then redo Phase 2.5 (materialize) and this phase." >&2
  exit 1
}

# A FAILED WALK IS A REFUSAL, never an empty result. Every walk below writes to a
# file and its exit status is CHECKED — that is the whole reason they are written to
# a file and converted separately, instead of piped (the same discipline the diff
# above follows). They used to end in `2>/dev/null || true`, so a mirror that could
# not be read (a pruned/corrupt object, a $CACHE that does not carry $BASE..$TARGET,
# a broken clone) produced an EMPTY upgrades-added.txt / upgrades-modified.txt /
# legacy-upgrade-commits.txt and exit 0: every migration step the template ships
# silently skipped, which is strictly worse than a loud refusal (see the RAW PATH
# BYTES note above — same failure, different cause). There is no legitimate non-zero
# exit to swallow here: a pathspec that matches nothing exits 0 with these forms, so
# non-zero means the walk itself failed. stderr is deliberately NOT redirected: git's
# own line ("fatal: Invalid revision range …", "fatal: unable to read …") is the
# diagnosis, and the refusal below names which walk it belongs to.
upg_refuse_walk() { # upg_refuse_walk <which-walk>
  # Same teardown as the badnames refusal above, for the same reason.
  : > "$RUN/classification.tsv"
  rm -f "$RUN/classification-trees.tsv"
  echo "FAIL: $1 failed over $BASE..$TARGET in $CACHE (see git's error above)." >&2
  echo "      That walk is how this phase discovers the migration steps the template" >&2
  echo "      ships, so continuing would report an EMPTY upgrade-file set as success and" >&2
  echo "      skip every one of them silently." >&2
  echo "      Remedy: repair the template mirror (re-fetch \$CACHE), or correct BASE/TARGET," >&2
  echo "      then re-run this phase." >&2
  exit 1
}

# --no-show-signature ON EVERY WALK THE PARSER CONSUMES. Ambient
# `log.showSignature=true` (a common global for people who sign) makes git print the
# signature verification of each signed commit to log's STDOUT, which corrupts the
# very first -z record and silently emptied the whole upgrade-file set — see
# z_log_name_only for the full shape. The flag is per-invocation and cannot be
# overridden by the mirror's config, unlike anything we could pin once.
git -C "$CACHE" log --no-show-signature --reverse --topo-order --diff-filter=A --name-only -z \
    --pretty=format:'commit %H' "$BASE..$TARGET" -- "$UPG_DIR" \
  > "$RUN/.upg-added.z" \
  || upg_refuse_walk "the upgrade-file ADD walk (--diff-filter=A)"
z_log_name_only "$UPG_BAD" "$UPG_STRAY" < "$RUN/.upg-added.z" > "$RUN/.upg-added.tsv"
upg_refuse_badnames
upg_refuse_stray "the upgrade-file ADD walk (--diff-filter=A)"
rm -f "$RUN/.upg-added.z"
# CHECKED, not `|| true`: this awk IS the write of the two load-bearing add-side
# artifacts (upgrades-added.txt names the slugs the planner must dispose of;
# upgrades-added.tsv drives the body snapshots below), both already truncated at
# the top of this phase. A mid-scan awk death used to leave a PARTIAL list and
# exit 0 — a subset of the template's migration steps presented as the whole set,
# the same fail-open shape the walk header above declares fixed. No legitimate
# non-zero exists here (the walk already succeeded), so any failure is a stop.
# The dir PREFIX travels through the ENVIRONMENT, never `awk -v` (collect-common.sh's
# twin documents the rule: awk expands escape sequences in a -v assignment, so a dir
# carrying a backslash would reach the program mangled and match nothing — a silent
# empty walk). A BEGIN copy from ENVIRON[] leaves the rest of the program unchanged.
# The other -v values are $RUN OUTPUT paths, not match keys; the same doctrine applies
# to the three dir-filter sites below.
UPG_DIR="$UPG_DIR" awk -F'\t' -v txt="$RUN/upgrades-added.txt" -v tsv="$RUN/upgrades-added.tsv" '
    BEGIN { dir = ENVIRON["UPG_DIR"] }
    substr($2, 1, length(dir)) == dir && length($2) > length(dir) {
      if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2; print $2 > txt }
      latest[$2] = $1
    }
    END { for (i = 1; i <= n; i++) print latest[order[i]] "\t" order[i] > tsv }
  ' "$RUN/.upg-added.tsv" \
  || { echo "FAIL: could not build the add-side upgrade-file lists (upgrades-added.txt/.tsv) from the ADD walk — a partial list would present a subset of the template's migration steps as the whole set. Check that $RUN is writable, then re-run this phase." >&2; exit 1; }
rm -f "$RUN/.upg-added.tsv"

# Modified-only list: upgrade-files that existed before BASE and were amended.
git -C "$CACHE" log --no-show-signature --reverse --topo-order --diff-filter=M --name-only -z \
    --pretty=format:'commit %H' "$BASE..$TARGET" -- "$UPG_DIR" \
  > "$RUN/.upg-mod.z" \
  || upg_refuse_walk "the upgrade-file MODIFIED-list walk (--diff-filter=M)"
z_log_name_only "$UPG_BAD" "$UPG_STRAY" < "$RUN/.upg-mod.z" > "$RUN/.upg-mod.tsv"
upg_refuse_badnames
upg_refuse_stray "the upgrade-file MODIFIED-list walk (--diff-filter=M)"
rm -f "$RUN/.upg-mod.z"
# ONE checkable awk instead of `cut | awk | awk | grep -vxF … || true`: that
# pipeline masked a real failure of any stage as exit 0 (a partial modified list
# read downstream as the whole set), and its terminal `grep -vxF` conflated its
# own legitimate exit 1 (EVERY modified file was also added, so the list is empty)
# with a genuine error — the two cannot be told apart without pipefail games. The
# awk reads upgrades-added.txt as the exclusion set (the grep -vxF's job), applies
# the same dir-prefix filter and first-seen dedup, and its exit status is now
# unambiguous: any non-zero is a real failure and a stop. An empty list is a clean
# exit 0 with a zero-line file, exactly as the old zero-survivor case produced.
UPG_DIR="$UPG_DIR" awk -F'\t' -v added="$RUN/upgrades-added.txt" '
    BEGIN { dir = ENVIRON["UPG_DIR"]; while ((getline a < added) > 0) skip[a] = 1 }
    substr($2, 1, length(dir)) == dir && length($2) > length(dir) {
      if (!($2 in skip) && !seen[$2]++) print $2
    }
  ' "$RUN/.upg-mod.tsv" > "$RUN/upgrades-modified.txt" \
  || { echo "FAIL: could not build $RUN/upgrades-modified.txt from the MODIFIED-list walk — a partial list would drop amended migration steps silently. Check that $RUN is writable, then re-run this phase." >&2; exit 1; }
rm -f "$RUN/.upg-mod.tsv"

# Snapshot each upgrade-file's body from the commit that introduced or last
# amended it — never from TARGET tip, which may have pruned already-shipped
# upgrade-files. Added files: from their newest add commit (see above). Modified
# files: from the newest amend commit; always overwrite the added-pass snapshot
# since an M-event is newer content.
# Limit: the modified-pass unconditionally wins over the added-pass on the
# assumption an M-event is strictly newer than the A-event. A pathological
# add -> modify -> delete -> re-add of the SAME path within BASE..TARGET could
# leave the stale M body; such churn on one upgrade-file basename is not a real
# authoring pattern (identity is append-only), so we don't reconcile it here.
while IFS=$'\t' read -r sha path; do
  [[ -n "${path:-}" ]] || continue
  snap_upgrade "$CACHE" "$sha:$path" "$path" "$(basename "$path")" || true
done < "$RUN/upgrades-added.tsv"

git -C "$CACHE" log --no-show-signature --topo-order --diff-filter=M --name-only -z \
    --pretty=format:'commit %H' "$BASE..$TARGET" -- "$UPG_DIR" \
  > "$RUN/.upg-modbody.z" \
  || upg_refuse_walk "the upgrade-file MODIFIED-body walk (--diff-filter=M, newest-first)"
z_log_name_only "$UPG_BAD" "$UPG_STRAY" < "$RUN/.upg-modbody.z" > "$RUN/.upg-modbody.tsv"
upg_refuse_badnames
upg_refuse_stray "the upgrade-file MODIFIED-body walk (--diff-filter=M, newest-first)"
rm -f "$RUN/.upg-modbody.z" "$UPG_BAD" "$UPG_STRAY"
# NOT --reverse, unlike the two walks above: `!seen[$2]++` then keeps the NEWEST
# amending commit per path, which is the body that wins.
UPG_DIR="$UPG_DIR" awk -F'\t' '
      BEGIN { dir = ENVIRON["UPG_DIR"] }
      substr($2, 1, length(dir)) == dir && length($2) > length(dir) { if (!seen[$2]++) print }
    ' "$RUN/.upg-modbody.tsv" \
  | while IFS=$'\t' read -r sha path; do
      [[ -n "${path:-}" ]] || continue
      # Same source id as the add-pass above, so this intentional body
      # override of an amended file is same-source and never flagged.
      snap_upgrade "$CACHE" "$sha:$path" "$path" "$(basename "$path")" || true
    done
rm -f "$RUN/.upg-modbody.tsv"

# Frontend compatibility floor extraction: every upgrade-file this run just
# snapshotted (added AND modified — a floor can land in either pass) may
# declare `requires-frontend: <module>@<40-hex-sha>` (module defaults to react
# when only a bare sha is given, per the frozen field grammar). Modeled on
# collect-common.sh's field-presence loop above (common-upgrades-added.txt /
# common-upgrades-modified.txt against $RUN/upgrades/<basename>) but this
# EXTRACTS a value instead of only flagging absence. Column 1 of
# frontend-floors.tsv is the EXACT path string read from upgrades-added.txt /
# upgrades-modified.txt — frontend-floor-check.sh and the manifest debt it
# feeds key off that identity, never a basename-only spelling. A malformed
# `requires-frontend:` value (author-side validation should have caught it
# before this ever reached TARGET) is skipped rather than failing the phase:
# a bad floor is a missed advisory, not a corrupted classification.
# tr -d '\r' before the sed, and a trailing-whitespace strip in the sed itself:
# snap_upgrade's `git show` does no LF normalization, so a CRLF upgrade-file
# body keeps its trailing \r in the snapshot, and either that \r or plain
# trailing spaces after the sha would survive the leading-whitespace-only sed
# and defeat the $-anchored validators below ($ can't match past a stray
# byte) — silently dropping a well-formed floor instead of just a malformed
# one.
for list in upgrades-added.txt upgrades-modified.txt; do
  [[ -f "$RUN/$list" ]] || continue
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    base=$(basename "$path")
    snap="$RUN/upgrades/$base"
    [[ -f "$snap" ]] || continue
    # Basename-collision guard. The snapshot is keyed by basename ($RUN/upgrades/
    # <basename>), so two crossed upgrade-files sharing a basename land in ONE file
    # and the LAST writer wins (snap_upgrade records every write in $SNAP_SOURCES and
    # WARNs on the clash). The on-disk body may therefore belong to a DIFFERENT file
    # than $path — reading a floor from it would attribute the wrong file (or miss
    # $path's own). So extract only when the winning snapshot actually came from
    # $path; otherwise skip LOUDLY rather than record a possibly-wrong (path, floor)
    # row. Practically unreachable (timestamp-prefixed slugs are unique; a
    # configured-source run is module-scoped), but silent misattribution is exactly
    # the false "you're fine" this feature exists to prevent.
    won=$(b="$base" awk -F'\t' '$1==ENVIRON["b"]{s=$2} END{if(s!="")print s}' "$SNAP_SOURCES" 2>/dev/null)
    if [[ -n "$won" ]] && [[ "$won" != "$path" ]]; then
      echo "WARN: skipping requires-frontend extraction for $path — its snapshot basename '$base' was overwritten by $won (basename collision); no floor recorded from a possibly-wrong body" >&2
      continue
    fi
    # EVERY requires-frontend line, not just the first: a file that declares more than
    # one floor must not have the rest silently dropped. Each well-formed line becomes
    # its own row; a malformed one is skipped (a missed advisory, not a corrupted
    # classification). tr -d '\r' + trailing-ws strip so a CRLF body or trailing
    # spaces after the sha cannot defeat the $-anchored validators (see note above).
    grep -E '^requires-frontend:' "$snap" | while IFS= read -r fline; do
      field=$(printf '%s' "$fline" | tr -d '\r' | sed -E 's/^requires-frontend:[[:space:]]*//; s/[[:space:]]+$//')
      [[ -n "$field" ]] || continue
      if printf '%s' "$field" | grep -qE '^[A-Za-z0-9_-]+@[0-9a-f]{40}$'; then
        module="${field%%@*}"
        sha="${field##*@}"
      elif printf '%s' "$field" | grep -qE '^[0-9a-f]{40}$'; then
        module="react"
        sha="$field"
      else
        continue
      fi
      printf '%s\t%s\t%s\n' "$path" "$module" "$sha" >> "$RUN/frontend-floors.tsv"
    done
  done < "$RUN/$list"
done

# --- supersede edges ----------------------------------------------------------
# Parse each snapshot's `supersedes:` into edges. Template runs walk a single
# namespace (MODULE empty for the component-template, or the one template-kind
# module when MODULE is set), so every collected file shares one module label —
# cross-module never fires here, and the direction rule is checked against
# upgrades-added.txt's apply order. The list file carries added + modified so the
# helper's kind column drives supersede-check.sh's added-only enforcement.
# Every step is CHECKED (not just `set -u`): a failed temp file or a failed input
# build would hand the helper an empty list, and the helper would then emit
# nothing into the edge file this script already truncated — indistinguishable
# from "no supersedes in range" for supersede-check.sh, which would then wave a
# plan through with a retired slug left unskipped. A failed helper call removes
# the edge file itself (see lib/supersede-edges.sh); this arm fails the phase.
{
  bm_fail() { rm -f "${bm_order:-}" "${bm_list:-}" "$RUN/supersede-edges.tsv"; echo "FAIL: $* — supersede-edges.tsv removed rather than left empty (an empty edge file reads as 'no supersedes in range'). Check that ${TMPDIR:-/tmp} and $RUN are writable, then re-run this phase." >&2; exit 1; }
  bm_order=$(mktemp "${TMPDIR:-/tmp}/bm-order.XXXXXX") || bm_fail "could not create a temp file for the supersede apply-order list"
  bm_list=$(mktemp "${TMPDIR:-/tmp}/bm-list.XXXXXX")   || bm_fail "could not create a temp file for the supersede module map"
  # A NON-EMPTY module label matters twice: an empty leading field would let a
  # tab-IFS read collapse it, and the helper treats an empty module as "not
  # collected" — both would misclassify template edges. Plain template runs use
  # the literal `template`; a template-kind run uses its own MODULE.
  bm_mod=${MODULE:-template}
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    b=${p##*/}; printf '%s\t%s\n' "$bm_mod" "${b%.md}"
  done < "$RUN/upgrades-added.txt" > "$bm_order" || bm_fail "could not build the supersede apply-order list from upgrades-added.txt"
  awk -F'\t' '{ print $1"\t"$2"\tadded" }' "$bm_order" > "$bm_list" || bm_fail "could not build the supersede module map"
  if [[ -f "$RUN/upgrades-modified.txt" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      b=${p##*/}; printf '%s\t%s\tmodified\n' "$bm_mod" "${b%.md}"
    done < "$RUN/upgrades-modified.txt" >> "$bm_list" || bm_fail "could not add the modified list to the supersede module map"
  fi
  supersede_emit "$bm_order" "$bm_list" "$RUN/upgrades" "$RUN/supersede-edges.tsv" \
    || bm_fail "supersede edge emission failed"
  rm -f "$bm_order" "$bm_list"
}

# Legacy upgrade path (components older than .kairos-updates/):
# --no-show-signature for the same reason as the walks above, and here the damage
# needs no parser to happen: the verification text lands in
# legacy-upgrade-commits.txt line by line, as if each were a commit SHA the planner
# should read.
# --diff-filter=AM keeps only ADDED/MODIFIED, excluding deletions: legacy notes were
# always added or modified (a section appended to UPGRADE.md), so a delete commit
# carries no migration instruction — excluding it lets a repo retire the frozen
# UPGRADE.md without the removal surfacing as a spurious legacy note in any migration
# window it straddles. AM (include form), not d (lowercase-exclude): under a pathspec
# walk with history simplification, --diff-filter=d drops EVERY row, not just deletes.
git -C "$CACHE" log --no-show-signature --pretty=format:%H --diff-filter=AM "$BASE..$TARGET" -- UPGRADE.md \
  > "$RUN/legacy-upgrade-commits.txt" \
  || upg_refuse_walk "the legacy UPGRADE.md walk"

# Template-side binaries: --numstat prints "-" for binary blobs — including for a
# DELETED one, which is what lets the D arm probe this list too. A rename record
# is keyed by its NEW path (see the -z note below), which is the path the R* arm
# probes — so a renamed binary is recognized here and never reaches a for-AI
# bucket. structural-merge.sh's local NUL-byte safety net remains the second
# layer, for rows only the ours side makes binary (and for RP re-pairings, whose
# two halves were classified before this list could pair them) — but ONLY for
# buckets that enter its merge pipeline. The D arm's rows never do, so that arm
# runs the ours-side probe itself (is_binary_local, above).
#
# -z for the same raw-path-bytes reason the diff carries it: this list is matched
# against classification paths with `grep -qxF`, so one quoted spelling here means
# a binary is never recognized as one and gets routed into the TEXT merge path.
# In -z mode a rename/copy row prints its two paths as separate NUL fields after
# an EMPTY path field, so the record is read and then completed below.
# CHECKED, not `|| true`: binaries-template.txt is derived ONLY from this list, and
# it is what routes template-side binaries around the TEXT merge path (matched with
# `grep -qxF`). A failed numstat used to leave an empty .numstat.z and exit 0, so
# every template binary silently fell through to the text merge and got CRLF/merge
# treatment that corrupts it. The same trees were already diffed for name-status
# above without incident, so a failure here is an environment problem, not a no-op.
git -C "$SYNTH" diff --numstat -M -z "$T_BASE" "$T_TARGET" > "$RUN/.numstat.z" \
  || { echo "FAIL: could not read the template binary list (git diff --numstat) over $T_BASE..$T_TARGET in $SYNTH — an empty list would route template binaries into the text merge and corrupt them. Re-run scripts/materialize.sh, then this phase." >&2; exit 1; }
: > "$RUN/binaries-template.txt"
while IFS= read -r -d '' rec; do
  [[ -n "$rec" ]] || continue
  nadd="${rec%%$TABCH*}"; nrest="${rec#*$TABCH}"; npath="${nrest#*$TABCH}"
  if [[ -z "$npath" ]]; then
    IFS= read -r -d '' _nold || break
    IFS= read -r -d '' npath || break
  fi
  [[ "$nadd" = "-" ]] || continue
  case "$npath" in *"$TABCH"*|*"$NLCH"*) continue ;; esac
  printf '%s\n' "$npath" >> "$RUN/binaries-template.txt"
done < "$RUN/.numstat.z"
rm -f "$RUN/.numstat.z"

# --- component-side rename detection (enrichment only) ------------------------
# The component may have MOVED a template-managed file and customized it
# (e.g. internal/foo.go -> pkg/foo.go). When the template later modifies the
# ORIGINAL path, path-only classification sees "absent locally" and routes it to
# modify-delete. We do NOT auto-merge onto the guessed file — rename detection is
# a content-similarity heuristic, and a mis-paired match would silently corrupt an
# unrelated file with no review checkpoint. Instead we ATTACH git's best-guess move
# target to the row, so the AI/planner starts from "closest match is pkg/foo.go"
# instead of searching blind. Building the baseline tree writes loose objects
# into the component repo (git hash-object -w); those are unreferenced and
# harmless (a later gc collects them), and every real run already writes far
# more into the migration state dir.
# The path goes in through the ENVIRONMENT, never `awk -v`: awk expands escape
# sequences in a -v assignment, so a path carrying a backslash ("back\\slash.go")
# reaches the program mangled and can never match its own map row.
rename_target() { p="$1" awk -F'\t' '$1==ENVIRON["p"]{print $2; exit}' "$RUN/component-rename-map.tsv"; }

: > "$RUN/component-rename-map.tsv"
# The materialized baseline is already component-shaped, so we only have to copy
# its blobs into THIS repo's object store to make them addressable by git diff.
# NUL-delimited, both ends. `ls-tree --name-only` C-quotes any path with a
# non-ASCII byte ("caf\303\251.go"), and that quoted spelling then went straight
# back into `git show "<base>:<path>"` — which fails, silently, because the loop
# swallows it — so the file's baseline blob became the EMPTY blob and its
# component-side move could never be paired (0% similarity against nothing).
# `-z` emits paths verbatim (quotepath cannot apply) and `update-index -z` reads
# them verbatim, so the round trip is byte-exact for any filename git can store.
BL_IDX="$RUN/.baseline.index"; rm -f "$BL_IDX"
git -C "$SYNTH" ls-tree -r -z --name-only "$T_BASE" \
  | while IFS= read -r -d '' tpath; do
      case "$tpath" in .kairos-updates/*) continue ;; esac
      blob=$(git -C "$SYNTH" show "$T_BASE:$tpath" 2>/dev/null | git hash-object -w --stdin)
      printf '100644 %s\t%s\0' "$blob" "$tpath"
    done \
  | GIT_INDEX_FILE="$BL_IDX" git update-index -z --index-info 2>/dev/null
BASELINE_TREE=$(GIT_INDEX_FILE="$BL_IDX" git write-tree 2>/dev/null || echo "")
rm -f "$BL_IDX"
if [[ -n "$BASELINE_TREE" ]]; then
  # R<score>\told(template baseline)\tnew(component); score kept as advisory context.
  # -z through the same converter as the template diff, so a map row carries RAW
  # path bytes and rename_target can match it. A COMPONENT-side path that cannot
  # ride a TAB-delimited row is dropped with a WARN rather than failing the run:
  # this map is advisory enrichment (a move candidate attached to a for-AI row),
  # so losing one candidate degrades a hint, while the template-side refusal above
  # exists because a classification ROW cannot be degraded.
  : > "$RUN/.rnmap-badnames.txt"
  git -c core.quotepath=off diff --find-renames=50% --name-status -z "$BASELINE_TREE" HEAD \
    > "$RUN/.rnmap.z" 2>/dev/null || true
  z_name_status "$RUN/.rnmap-badnames.txt" < "$RUN/.rnmap.z" \
    | awk -F'\t' '$1 ~ /^R/ { r=$1; sub(/^R/,"",r); print $2"\t"$3"\t"(r+0) }' \
    > "$RUN/component-rename-map.tsv" || true
  if [[ -s "$RUN/.rnmap-badnames.txt" ]]; then
    echo "WARN: component-side move detection skipped path(s) whose name carries a TAB or newline (no move candidate can be attached for them):" >&2
    sed 's/^/        /' "$RUN/.rnmap-badnames.txt" >&2
  fi
  rm -f "$RUN/.rnmap.z" "$RUN/.rnmap-badnames.txt"
fi

# --- classification -----------------------------------------------------------
: > "$RUN/classification.tsv"
emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
           "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" "${7:-}" >> "$RUN/classification.tsv"; }

while IFS=$'\t' read -r status p1 p2; do
  [[ -n "${status:-}" ]] || continue
  # .kairos-updates/ is template-tooling-only — never copied into components.
  # materialize.sh already drops it, so this is a belt-and-braces guard.
  case "$p1" in .kairos-updates/*) continue ;; esac
  case "${p2:-}" in .kairos-updates/*) continue ;; esac

  case "$status" in
    A)
      DEST="$p1"
      if grep -qxF -- "$p1" "$RUN/binaries-template.txt"; then
        emit binary-for-user A "$p1" "$DEST"
      elif [[ -e "$DEST" ]]; then
        emit merge-pipeline A "$p1" "$DEST"          # exists locally too: 3-way with empty base
      else
        emit added-mechanical A "$p1" "$DEST"        # heavyweight re-bucketing happens below
      fi
      ;;
    D)
      DEST="$p1"
      # BINARY, EITHER SIDE, NEVER REACHES THE for-AI BUCKET — the same contract
      # the A, M and R* arms honor (reference/structural-merge.md). A
      # template-deleted, component-CUSTOMIZED binary used to land in
      # modify-delete-for-ai and be dispatched to the conflict-resolver, an agent
      # that cannot read the file it is asked to reason about; and unlike the
      # merge-pipeline rows, nothing downstream could rescue it — for-AI buckets
      # never enter structural-merge.sh, so its NUL-byte safety net never sees
      # them. Hence BOTH probes here: the template-side list, and the ours side,
      # which is the only layer that can see a file the COMPONENT made binary.
      #
      # The probe sits on the CUSTOMIZED branch, not ahead of the whole arm as it
      # does on A/M/R*, because the two cases it would otherwise swallow are
      # already correct and asking about them costs more than it buys. An
      # UNMODIFIED binary the template drops is a mechanical delete — no merge, no
      # AI, and its content is byte-identical to the baseline, so nothing is lost —
      # and routing it to the user would additionally break the wholesale-deletion
      # checkpoint below, which only sees deleted-by-template-mechanical rows: one
      # binary in an emptied directory would make that subtree look merely thinned
      # and the batched confirmation would silently disappear. "Unmodified" is
      # decided byte-exactly for a binary (matches_template_raw) — see there.
      #
      # THE ROW IS DELETE-FLAVORED, and its flavor rides the EXISTING status
      # column (column 2 = `D`): the template carries no blob at this path any
      # more, so `theirs` means adopt the DELETION, not write a file.
      # apply-ask-user.sh keys on that column — no new bucket, no new artifact,
      # no change to the theirs|ours vocabulary.
      if [[ ! -e "$DEST" ]]; then
        emit noop-already-deleted D "$p1" "$DEST"    # both sides deleted — nothing to do
      elif grep -qxF -- "$p1" "$RUN/binaries-template.txt" || is_binary_local "$DEST"; then
        if matches_template_raw "$T_BASE:$p1" "$DEST"; then
          emit deleted-by-template-mechanical D "$p1" "$DEST"
        else
          emit binary-for-user D "$p1" "$DEST"       # template deleted, component customized
        fi
      elif matches_template "$T_BASE:$p1" "$DEST"; then
        emit deleted-by-template-mechanical D "$p1" "$DEST"
      else
        emit modify-delete-for-ai D "$p1" "$DEST"    # template deleted, component customized
      fi
      ;;
    M)
      DEST="$p1"
      if grep -qxF -- "$p1" "$RUN/binaries-template.txt"; then
        emit binary-for-user M "$p1" "$DEST"
      elif [[ ! -e "$DEST" ]]; then
        # Absent at the template's path — component deleted or MOVED it. Attach git's
        # move candidate (empty if none) so the AI decides from a starting point;
        # never auto-merge (never resurrect silently).
        emit modify-delete-for-ai M "$p1" "$DEST" "" "$(rename_target "$DEST")"
      else
        emit merge-pipeline M "$p1" "$DEST"
      fi
      ;;
    RP)
      # Re-paired across a corroborated directory rename (see above). Route to
      # merge-pipeline so the recovered old path serves as the true merge base and
      # heavy template change surfaces as ordinary conflicts.
      OLD_DEST="$p1"; DEST="$p2"
      if [[ -e "$DEST" ]] || [[ -e "$OLD_DEST" ]]; then
        # A binary here needs no probe: this row enters structural-merge.sh, whose
        # NUL-byte safety net diverts it to binaries.txt carrying the same
        # new/old pair (see reference/structural-merge.md → Binary detection).
        emit merge-pipeline RP "$p2" "$DEST" "$p1" "" paired-by-dir-rename
      elif grep -qxF -- "$p2" "$RUN/binaries-template.txt"; then
        # The for-AI branch has no such second layer — this row would go straight
        # to the conflict-resolver — so the template-side probe has to happen
        # here. `theirs` writes the target blob at the new path; the old path is
        # already absent locally (that is why this branch was taken), so
        # apply-ask-user.sh's rename removal is a no-op for it.
        emit binary-for-user RP "$p2" "$DEST" "$p1" "" paired-by-dir-rename
      else
        emit modify-delete-for-ai RP "$p2" "$DEST" "$p1" \
             "$(rename_target "$OLD_DEST")" paired-by-dir-rename
      fi
      ;;
    R*)
      OLD_DEST="$p1"; DEST="$p2"; SCORE=${status#R}
      # BINARY WINS OVER EVERY RENAME SHAPE, and is therefore checked FIRST — the
      # same precedence the A and M arms give it. Git computes rename similarity
      # over binary content too, so `R<100` on a moved-and-modified image or font
      # is a real status; without this check that row was emitted as
      # renamed-with-mods-for-ai and dispatched to the conflict-resolver, which
      # is precisely the "never auto-merge, never send to AI" contract
      # (reference/structural-merge.md) inverted — and the local NUL-byte safety
      # net in structural-merge.sh could not catch it, because for-AI buckets
      # never enter that script's merge pipeline at all.
      # THE ROW CARRIES THE OLD PATH in column 5 (like every other rename row),
      # which is what makes the user's decision enactable: apply-ask-user.sh
      # writes the target blob at the new path AND removes the old copy on
      # `theirs`, instead of leaving both spellings in the structural commit.
      # binaries-template.txt is keyed by the NEW path: in `--numstat -z` a
      # rename record prints old then new after an empty path field, and the
      # reader above keeps the second.
      if grep -qxF -- "$p2" "$RUN/binaries-template.txt"; then
        emit binary-for-user "$status" "$p2" "$DEST" "$p1"
      elif [[ "$SCORE" != "100" ]]; then
        # THE OURS SIDE NEEDS PROBING ON THIS BRANCH TOO, and only on this one.
        # renamed-with-mods-for-ai goes to the conflict-resolver, which never
        # enters structural-merge.sh's merge pipeline — so a file the COMPONENT
        # made binary would reach an agent that cannot read it, the same shape as
        # the D arm above. The component's copy may still sit at the OLD path
        # (it has not moved yet), which is where merge_one would read "ours" from.
        # An R100 whose local copy is binary is deliberately NOT probed here: that
        # row goes to merge-pipeline, where the safety net catches it and records
        # the new/old pair in binaries.txt — one route, kept as it is.
        if is_binary_local "$DEST" || { [[ ! -e "$DEST" ]] && is_binary_local "$OLD_DEST"; }; then
          emit binary-for-user "$status" "$p2" "$DEST" "$p1"
        else
          emit renamed-with-mods-for-ai "$status" "$p2" "$DEST" "$p1" # rename + content change
        fi
      elif [[ ! -e "$OLD_DEST" ]] && [[ ! -e "$DEST" ]]; then
        # Not at either template path — deleted, or moved elsewhere? Rename+mods always
        # needs judgment, so stay for-AI, but attach git's move candidate to inform it.
        emit modify-delete-for-ai "$status" "$p2" "$DEST" "$p1" "$(rename_target "$OLD_DEST")"
      else
        # SCORE==100 pure rename (old-template blob == new-template blob), and at
        # least one of OLD_DEST/DEST exists (the both-absent case left above). The
        # mechanical enactment (structural-merge.sh) OVERWRITES $DEST with the target
        # blob and DELETES $OLD_DEST — lossless ONLY when neither side carries
        # customized content. Deciding on the OLD path alone (the previous test) let
        # a pristine old path route to `renamed-mechanical` even when the component
        # had written its OWN file at $DEST, which was then clobbered with no
        # conflict and no checkpoint; the mirror case (customized old + $DEST already
        # == target) silently deleted the customized old path. "Clean" = absent, or
        # byte-identical to its own template side (base for the old path, target for
        # the new).
        OLD_CLEAN=no; DEST_CLEAN=no
        { [[ ! -e "$OLD_DEST" ]] || matches_template "$T_BASE:$p1" "$OLD_DEST" 2>/dev/null; } && OLD_CLEAN=yes
        { [[ ! -e "$DEST" ]]     || matches_template "$T_TARGET:$p2" "$DEST" 2>/dev/null; }     && DEST_CLEAN=yes
        if [[ "$OLD_CLEAN" = yes ]] && [[ "$DEST_CLEAN" = yes ]]; then
          emit renamed-mechanical "$status" "$p2" "$DEST" "$p1"
        elif [[ "$OLD_CLEAN" = no ]] && [[ -e "$DEST" ]]; then
          # The component customized BOTH the old path AND the new path. merge_one
          # reads "ours" from $DEST when it exists, so a merge-pipeline row would
          # keep the new-path work but drop the old-path customization with no
          # checkpoint. Surface it as a modify/delete decision (old-path content +
          # the rename target attached) rather than losing it.
          emit modify-delete-for-ai "$status" "$p2" "$DEST" "$p1" "$(rename_target "$OLD_DEST")"
        else
          # Exactly one side is customized. merge-pipeline is lossless here: for a
          # pure rename base == theirs, so the 3-way keeps "ours", and merge_one
          # reads ours from wherever the component's file actually lives (the new
          # path if present, else the old path — porting an old-path customization
          # onto the new name).
          emit merge-pipeline "$status" "$p2" "$DEST" "$p1"           # customized: merge at new path
        fi
      fi
      ;;
    *)
      # C* can't occur (diff runs with -M, not -C); anything unexpected lands
      # here and the orchestrator inspects it in Phase 5.
      emit unknown-status "$status" "$p1" "$p1"
      ;;
  esac
done < "$RUN/diff.tsv"

# --- heavyweight ADDITION re-bucketing -----------------------------------------
# A NEW top-level dir at component root with >3 added files, or any NEW
# cmd/<name>/, is a heavyweight addition — the user decides take/skip/cherry-pick.
#
# cmd/<name> is special-cased on purpose, and the name is not a template-vintage
# detail: in Go/Kairos a directory under cmd/ IS a runtime entrypoint ("app"), and
# a new one is a high-stakes "the template added a new runtime — do you want it?"
# decision worth surfacing at any size. Two consequences follow, both of which the
# plain top-level rule would miss:
#   1. group and existence-check at the SECOND level (cmd/<name>), because cmd/
#      already exists in every component — grouping at the top level would bucket a
#      new cmd/<name>/ under the existing `cmd` root and the [ -e ] guard below
#      would skip it regardless of how many files it carries.
#   2. qualify regardless of file count — a new runtime is worth asking about even
#      when it ships as a lone main.go, so the >3 threshold does not apply to it.
#
# THE ROOT IS WRITTEN WITH `printf`, NEVER `echo` — here and in the emptied-subtree
# chain below, which hops a path through three lists. bash's builtin `echo` reads an
# argument that is EXACTLY an option string (`-n`, `-e`, `-E`, `-ne`, `-en`, any
# combination) as its own options and writes an empty line, or with `-n` in the set
# nothing at all. A directory so named therefore dropped out of the list silently,
# the `[ -s ]` guard below saw an empty file, and the rows kept their `*-mechanical`
# bucket: the batched user checkpoint this whole block exists to raise simply did not
# happen, with nothing on stderr to say so. `printf '%s\n'` has no option reading.
awk -F'\t' '$1 == "added-mechanical" && index($4, "/") { print $4 }' "$RUN/classification.tsv" \
  | awk -F/ '{ if ($1 == "cmd" && NF > 2) print $1"/"$2; else print $1 }' \
  | sort | uniq -c \
  | while read -r n root; do
      [[ -e "$root" ]] && continue                     # dir already exists locally → not a new subsystem
      case "$root" in
        cmd/*) ;;                                     # any new cmd/<name>/ qualifies (new runtime)
        *) [[ "$n" -gt 3 ]] || continue ;;
      esac
      printf '%s\n' "$root"
    done > "$RUN/heavyweight-roots.txt"

# CHECKED stage by stage, like the SNAP_REFUSALS prune at the top of this file: under
# `set -u` alone an `&& mv` chain just SHORT-CIRCUITS, so a failed awk or a failed mv
# silently leaves the rows mechanical, the batched user checkpoint this whole block
# exists to raise never fires, and the completion stamp still lands with exit 0 —
# "OK: manifest written", a new subsystem applied in Phase 5 with nobody asked. On any
# failure the temp is removed and the run stops before that stamp.
if [[ -s "$RUN/heavyweight-roots.txt" ]]; then
  while IFS= read -r root; do
    if ! r="$root/" awk -F'\t' -v OFS='\t' \
      '{ if ($1 == "added-mechanical" && index($4, ENVIRON["r"]) == 1) $1 = "added-heavyweight-ask-user"; print }' \
      "$RUN/classification.tsv" > "$RUN/classification.tsv.tmp"; then
      rm -f "$RUN/classification.tsv.tmp"
      echo "FAIL: could not re-bucket heavyweight additions under '$root' — leaving the rows mechanical would apply a new subsystem in Phase 5 with no user checkpoint. Check that $RUN is writable, then re-run this phase." >&2
      exit 1
    fi
    mv "$RUN/classification.tsv.tmp" "$RUN/classification.tsv" \
      || { rm -f "$RUN/classification.tsv.tmp"; echo "FAIL: could not replace $RUN/classification.tsv with its re-bucketed copy (heavyweight additions under '$root') — check that $RUN is writable." >&2; exit 1; }
  done < "$RUN/heavyweight-roots.txt"
fi

# --- heavyweight DELETION re-bucketing -----------------------------------------
# Mechanical deletion of one stray file is noise; mechanical deletion of an entire
# subtree is a structural decision. A template cleanup silently removed five files
# and left a component's CI build targets undeclared, with nobody asked — because
# deletions had no checkpoint while heavyweight ADDITIONS already had one. This
# closes that asymmetry: a directory the template empties WHOLESALE (every tracked
# file under it deleted) with >=3 files becomes one batched confirmation.
#
# Scattered single-file deletions deliberately stay mechanical — routing those to
# the user degenerates the checkpoint into reflexive "all as recommended".
: > "$RUN/deleted-heavyweight-dirs.txt"
awk -F'\t' '$1 == "deleted-by-template-mechanical" { print $4 }' "$RUN/classification.tsv" \
  > "$RUN/deleted-list.txt"

if [[ -s "$RUN/deleted-list.txt" ]]; then
  # The survivor scan below needs a DIFFERENT set than the candidate/re-bucket set.
  # "Is this subtree emptied wholesale?" asks whether the template removed EVERY
  # tracked file under it — and the template also removes files the component
  # customized, which are (correctly) routed to modify-delete-for-ai / binary-for-user
  # with status D, not deleted-by-template-mechanical. Their component copy is still
  # tracked here (Phase 5 has not run), so a survivor scan keyed on the mechanical set
  # alone counts a customized deletion as a KEPT file and disqualifies the subtree —
  # silencing the checkpoint exactly when the component has a customization at stake,
  # the inverse of this block's purpose. So the oracle counts every template-deleted
  # path; the candidate dirs and the re-bucket below stay on the mechanical set,
  # because those are the rows silently applied in Phase 5 with no other checkpoint
  # (the for-AI / binary rows already have their own user-decision path).
  awk -F'\t' '
    $1 == "deleted-by-template-mechanical" { print $4 }
    ($1 == "modify-delete-for-ai" || $1 == "binary-for-user") && $2 == "D" { print $4 }
  ' "$RUN/classification.tsv" | sort -u > "$RUN/.del-removed-all.txt"

  # Every ancestor directory of a deleted file is a candidate subtree. A root-level
  # file has no directory part, so sed leaves it unchanged; the `[ -d ]` test below
  # discards those.
  sed 's|/[^/]*$||' "$RUN/deleted-list.txt" | grep -v '^$' | sort -u \
    | while IFS= read -r d; do
        while [[ -n "$d" ]] && [[ "$d" != "." ]]; do
          printf '%s\n' "$d"
          case "$d" in */*) d="${d%/*}" ;; *) d="" ;; esac
        done
      done | sort -u > "$RUN/.del-cand-dirs.txt"

  # A candidate qualifies when EVERY tracked file under it is in the deletion set
  # (so the subtree really is emptied, not merely thinned) and there are >=3 of them.
  # The listing is `-z`, for the same reason the diff is: the deletion set carries
  # RAW path bytes, so a single C-quoted member here ("wei\"rd.txt",
  # "caf\303\251.txt") never matched it, the subtree looked merely thinned, and the
  # batched user checkpoint for a wholesale deletion silently disappeared for the
  # whole run. Membership is tested per file (`grep -qxF --`, so a leading-dash
  # member is an operand and not a bundle of options) and the walk stops at the
  # first survivor, which disqualifies the directory whatever its file count.
  # `:(literal)` keeps a directory whose name contains glob characters from
  # matching anything else.
  : > "$RUN/.del-emptied.txt"
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    tracked=0; survivor=0
    while IFS= read -r -d '' f; do
      if ! grep -qxF -- "$f" "$RUN/.del-removed-all.txt"; then survivor=1; break; fi
      tracked=$((tracked + 1))
    done < <(git ls-files -z -- ":(literal)$d" 2>/dev/null)
    [[ "$survivor" -eq 0 ]] && [[ "$tracked" -ge 3 ]] && printf '%s\n' "$d" >> "$RUN/.del-emptied.txt"
  done < "$RUN/.del-cand-dirs.txt"

  # Keep only MAXIMAL emptied subtrees: if a/b/c and a/b are both fully emptied,
  # the user should be asked once about a/b, not twice about nested halves of it.
  if [[ -s "$RUN/.del-emptied.txt" ]]; then
    sort -u "$RUN/.del-emptied.txt" > "$RUN/.del-emptied-sorted.txt"
    while IFS= read -r d; do
      keep=1; p="$d"
      while :; do
        case "$p" in */*) p="${p%/*}" ;; *) break ;; esac
        grep -qxF -- "$p" "$RUN/.del-emptied-sorted.txt" && { keep=0; break; }
      done
      [[ "$keep" -eq 1 ]] && printf '%s\n' "$d"
    done < "$RUN/.del-emptied-sorted.txt" > "$RUN/deleted-heavyweight-dirs.txt"
  fi

  # CHECKED stage by stage for the same reason as the ADDITION re-bucket above: an
  # `&& mv` chain that short-circuits under `set -u` would silently keep a wholesale
  # subtree deletion mechanical and still stamp completion, applying it in Phase 5
  # with no batched user checkpoint. On any failure the temp is removed and the run stops.
  if [[ -s "$RUN/deleted-heavyweight-dirs.txt" ]]; then
    while IFS= read -r d; do
      if ! r="$d/" awk -F'\t' -v OFS='\t' \
        '{ if ($1 == "deleted-by-template-mechanical" && index($4, ENVIRON["r"]) == 1) $1 = "deleted-heavyweight-ask-user"; print }' \
        "$RUN/classification.tsv" > "$RUN/classification.tsv.tmp"; then
        rm -f "$RUN/classification.tsv.tmp"
        echo "FAIL: could not re-bucket the wholesale deletion of '$d' — leaving the rows mechanical would empty a subtree in Phase 5 with no user checkpoint. Check that $RUN is writable, then re-run this phase." >&2
        exit 1
      fi
      mv "$RUN/classification.tsv.tmp" "$RUN/classification.tsv" \
        || { rm -f "$RUN/classification.tsv.tmp"; echo "FAIL: could not replace $RUN/classification.tsv with its re-bucketed copy (wholesale deletion of '$d') — check that $RUN is writable." >&2; exit 1; }
    done < "$RUN/deleted-heavyweight-dirs.txt"
  fi
  rm -f "$RUN/.del-cand-dirs.txt" "$RUN/.del-emptied.txt" "$RUN/.del-emptied-sorted.txt" "$RUN/.del-removed-all.txt"
fi

# --- affordance removal: summary.txt + query.sh --------------------------------
# The expensive read is `cat classification.tsv`; make the cheap one (a tally
# plus a query helper) more convenient than retyping the awk one-liners this
# file's callers currently ask agents to hand-write.
{
  cut -f1 "$RUN/classification.tsv" | sort | uniq -c | awk '{ print $2 "\t" $1 }' | sort -t$'\t' -k1,1
  [[ -s "$RUN/component-rename-map.tsv" ]] && printf 'component-side-moves\t%s\n' "$(grep -c . "$RUN/component-rename-map.tsv")"
  [[ -s "$RUN/dir-rename-pairs.tsv" ]] && printf 'dir-rename-pairs\t%s\n' "$(grep -c . "$RUN/dir-rename-pairs.tsv")"
  if [[ -s "$RUN/deleted-heavyweight-dirs.txt" ]]; then
    printf 'deleted-heavyweight-dirs\t%s\n' "$(paste -sd, "$RUN/deleted-heavyweight-dirs.txt")"
  fi
} > "$RUN/summary.txt"

cat > "$RUN/query.sh" <<'QUERYSH'
#!/usr/bin/env bash
# query.sh — generated by build-manifest.sh, regenerated on every run.
# Wraps the classification.tsv awk forms so a bucket query is a one-liner
# instead of a retyped `awk -F'\t' '$1=="<bucket>"' classification.tsv`.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
TSV="$DIR/classification.tsv"
usage() {
  echo "usage: $(basename "$0") <bucket> [column]" >&2
  echo "buckets present in this run's classification.tsv:" >&2
  cut -f1 "$TSV" | sort -u | sed 's/^/  /' >&2
}
[ $# -ge 1 ] || { usage; exit 1; }
BUCKET=$1
if [ $# -ge 2 ]; then
  awk -F'\t' -v b="$BUCKET" -v c="$2" '$1 == b { print $c }' "$TSV"
else
  awk -F'\t' -v b="$BUCKET" '$1 == b' "$TSV"
fi
QUERYSH
chmod +x "$RUN/query.sh"

# --- classification/SYNTH binding ---------------------------------------------
# Every row above is a statement about ONE pair of synthetic trees: which paths
# exist, which side changed, what the merge base is. Re-materialize $SYNTH after
# this ran (a corrected BASE, a moved TARGET, a FORCE_MATERIALIZE) and the file
# still parses while describing trees that no longer exist — rows then name paths
# the target tree does not carry, which used to reach the merge as empty files
# recorded as cleanly merged. So the trees are identified beside the
# classification and structural-merge.sh re-verifies them before merging
# anything (see its header).
#
# TREE oids, not commit oids: the tree is the content, so a re-materialization
# that produces the same trees (the stamped-reuse path, a re-run over unchanged
# inputs) is correctly NOT a drift, while a commit oid would move with its
# timestamp and refuse a classification that is in fact still valid.
#
# The oids stamped here are the ones resolved at the TOP of this script — the same
# two the diff, the numstat, the baseline ls-tree and every blob read addressed.
# They are deliberately NOT re-read from the tags: see the resolve-once block up
# there for what the second read cost.
#
# LAST ARTIFACT WRITE, deliberately: the binding doubles as this run's completion
# stamp (see the teardown block near the top), so nothing may be written after
# it and nothing may report success before it. Every artifact a later phase
# reads — classification.tsv, the upgrade lists and snapshots, summary.txt,
# query.sh — is on disk by the time it lands.
printf 'base\t%s\ntarget\t%s\n' "$T_BASE" "$T_TARGET" > "$RUN/classification-trees.tsv" \
  || { echo "FAIL: could not write $RUN/classification-trees.tsv" >&2; exit 1; }

echo "OK: manifest written to $RUN/classification.tsv" >&2
cut -f1 "$RUN/classification.tsv" | sort | uniq -c | sort -rn >&2
if [[ -s "$RUN/component-rename-map.tsv" ]]; then
  echo "  (component-side moves detected: $(grep -c . "$RUN/component-rename-map.tsv"))" >&2
fi
if [[ -s "$RUN/dir-rename-pairs.tsv" ]]; then
  echo "  (renames re-paired across directory renames: $(grep -c . "$RUN/dir-rename-pairs.tsv"))" >&2
fi
if [[ -s "$RUN/deleted-heavyweight-dirs.txt" ]]; then
  echo "  (subtrees the template empties wholesale, needing a user decision:)" >&2
  sed 's/^/    /' "$RUN/deleted-heavyweight-dirs.txt" >&2
fi
