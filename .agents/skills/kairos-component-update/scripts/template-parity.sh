#!/usr/bin/env bash
# template-parity.sh — whole-tree parity check: template paths that exist in the
# materialized TARGET tree but are ABSENT from the component's committed tree,
# relayed beside the final gate at Phase 8 step 1 for per-row disposition.
#
# WHY THIS EXISTS: every other verification layer in this skill is DELTA-scoped —
# gate.sh proves the tree still builds and its failure set matches the baseline,
# dropped-template-changes.sh recovers the target side of `ours`-resolved conflict
# REGIONS, the census tracks the test population. None of them can see a template
# file the component simply does NOT HAVE. Two ways a file goes missing are both
# invisible to a delta: a cosmetic change dropped on merge that still compiles, and
# — the larger class — PRE-EXISTING drift, a file the component diverged from before
# this migration, which never appears in a BASE..TARGET diff at all. A set-difference
# of the target tree against the component tree is the only thing that surfaces them.
#
# WHY AGAINST $SYNTH's kairos-target, NOT the raw template repo: the target tag is
# the tree `kairos component create` PRODUCES from TARGET — COMPONENT_NAME and the
# Go module path already substituted, and the template-authoring files a real
# component never carries (CHANGELOG.md, UPGRADE.md, .kairos-updates/, web/, skills/)
# already stripped by the CLI's own creation path (materialize.sh runs it with
# --no-frontend --no-skills). So the comparison basis is "what a freshly-created
# component at TARGET looks like", which is exactly the parity question — and it is
# substitution-aware for free, so a path is never false-flagged for carrying the
# component's name. This is the same reason the merge reads target blobs from here
# and never from the template's own tree (reference/materialization.md).
#
# WHY ONLY ABSENT PATHS ARE REPORTED, never present-but-modified: a template file
# present in the component with different content is the MERGE's job — gate.sh's
# build/test layers and dropped-template-changes.sh already cover it, and a
# whole-tree content diff would drown the signal in generated-artifact churn (the
# component regenerates sql/openapi/topic-config to its own content) and in every
# legitimate customization. Presence-only sidesteps all of that: a regenerated file
# is present in both trees, so it is never a finding. This is also what keeps the
# check GENERIC — it needs no list of "which files a template generates", the one
# thing this skill refuses to hardcode (producer-idempotence.sh's header).
#
# WHY THREE STATUSES (absent / relocated / rename?) AND HOW EACH IS DERIVED — all
# from the trees themselves, no hardcoded names:
#   * relocated — the absent template path's EXACT content (same git blob oid) lives
#     at some OTHER path in the component. A blob oid is content-addressed, so an
#     oid match is byte-identical with zero false positives: the file was moved, not
#     lost. This catches an unfollowed rename whose body the component kept verbatim
#     (e.g. a config.go the template renamed to app_config.go, body unchanged).
#   * rename? — no oid match, but a component-only file (present in the component,
#     absent from the target) sits in the SAME directory with the SAME extension.
#     A hint, not an assertion: the body diverged (a renamed file that also changed),
#     so a human confirms. Deliberately weak — one candidate or several are listed;
#     the reader judges.
#   * absent — neither. The template ships it and the component has nothing like it.
# relocated is tried before rename? because an exact-content match is strictly
# stronger evidence than a same-dir/ext neighbour, and a file can satisfy both.
#
# WHY INTENT-GUARDED ABSENCES ARE SUBTRACTED via $RUN/intent-active.md, not re-
# evaluated here: a deliberate absence the user already dispositioned (`web/ is
# gone`, `sql/README.md deliberately deleted`) is recorded as a standing-intent
# entry whose guard is an ABSENCE assertion (`test ! -e <path>`). That path is
# genuinely absent from the component, so it would re-surface as a finding on every
# future migration — the "cries wolf" failure this subtraction prevents. The guard
# TRUST MODEL is a security boundary owned by intent-check.sh (a closed grammar,
# never handed to a shell — reference/intent-guard.md); this script must NOT re-
# implement it. So it reads intent-check.sh's already-VETTED output — the active set
# — and lifts only the paths from absence-form guards there. If that file is absent
# (a run that never reached Phase 5's vet, or a stale state dir), nothing is
# subtracted: a finding may re-appear, which is the safe direction — a spurious
# "restore?" prompt is cheap, a hidden real miss is the bug this whole check fixes.
#
# WHY THE COMPONENT TREE IS `git ls-files` (tracked), not a working-tree walk: the
# migration's deliverable is the COMMITTED tree — that is what advances the baseline
# and what the next component sees. An untracked scratch file or a gitignored build
# artifact is not part of what the component ships, and folding it in would both
# hide a genuinely-absent tracked file (a stray copy makes it look present) and add
# ignored-output noise. This mirrors gate.sh scoping its marker scan to what git
# tracks or would track.
#
# WHY records are written with `printf`, never `echo`: a path field is arbitrary
# tracked content, and bash's builtin `echo` treats a leading `-e`/`-n`/`-E` operand
# as its own flag rather than data. Every row goes through `printf '%s\t%s\t%s\n'`,
# the same rule silenced-tests.sh and coverage-blind.sh hold to.
#
# WHY `-c core.quotePath=false` on every git listing whose paths are compared or
# keyed (`ls-tree -r` on the template arm, `ls-files -s` on both): git's default
# C-quotes any byte >= 0x80, so a non-ASCII path is spelled `"caf\303\251.tsx"` by
# git but `café.tsx` by the frontend arm's own `find` walk and by a raw guard path
# in intent-active.md. Left on, the two sides never match on such a path: on the
# frontend arm a PRESENT file reads as `absent` (a `restore` disposition would then
# overwrite the component's own customization), and on the template arm an
# intent-guarded absence never subtracts (the dispositioned absence cries wolf every
# migration). Off, git emits the literal UTF-8 bytes, matching `find` and the guard
# text — the same reason silenced-tests.sh pins it.
#
# WHY ABSENT $SYNTH / MISSING TAG IS EXIT 2 (a skip that escalates), NEVER A PASS:
# with no target tree the question "what does the template ship that the component
# lacks" cannot be asked. Writing an empty artifact would read as "nothing is
# missing" — the exact false negative this check exists to prevent. So exit 2 writes
# NO artifact and says why, the same contract dropped-template-changes.sh uses for
# the same missing input.
#
# THE FRONTEND ARM (MOUNT set) — same question, different basis. A frontend run's
# parity question is "what does the frontend template ship that this component's mount
# does not have", so the basis is the module's TARGET subtree, SUBSTITUTED with the
# CLI's create-time replacement map (scripts/lib/frontend-substitute.sh) and MAPPED
# onto the mount. Both halves are load-bearing: the raw subtree carries
# `<YOUR_BC_NAME>` where the mount carries the component's own name, so an
# unsubstituted basis is not a parity basis at all; and the subtree is rooted at the
# module path, so an unmapped basis compares `src/App.tsx` against a component that
# has `web/src/App.tsx` and calls every file absent. It deliberately does NOT read
# $SYNTH: the template arm's `kairos-target` tree is produced by `component create
# --no-frontend`, which strips `web/` on purpose (see above), so it is empty exactly
# where a frontend run needs content. Everything after the basis — the intent-guard
# subtraction, the three statuses, presence-only, tracked-tree-only — is shared code
# and means the same thing on both arms.
#
# Env in:  RUN    required — migration state dir.
#          SYNTH  required on the TEMPLATE arm — synthetic repo carrying the
#                 kairos-target tag (materialize.sh; reference/materialization.md).
#                 Off the anchor. Ignored on the frontend arm.
#          MOUNT  set = the FRONTEND arm; the mount the module is compared at
#                 (e.g. `web/`, the manifest's `frontend.mount`). Unset = the
#                 template arm, byte-identical to before this arm existed.
#          Frontend arm, either an already-materialized basis:
#            FE_TARGET_TREE  a directory holding the module's target subtree with the
#                            substitution ALREADY applied (rooted at the subtree root).
#          or the inputs to build one:
#            FE_CACHE        the frontend source clone/mirror to read the tree from
#            FE_TARGET       the target commit-ish inside it
#            FE_MODULE_PATH  the module's subtree path (manifest `frontend.path`)
#            COMPONENT_NAME  optional — defaults to `.kairos/manifest.yaml`'s `name:`;
#                            the substitution map's only input.
#          (cwd = component root, a git repo)
# Reads (in $RUN):
#   intent-active.md   optional — intent-check.sh's vetted active entries; the
#                      absence-form guards there name paths to subtract. Absent =
#                      subtract nothing (noted in the summary).
# Writes (in $RUN):
#   frontend-parity-target/  frontend arm only, and only when FE_TARGET_TREE was not
#                        supplied: the substituted, mount-mapped basis, kept on disk
#                        so a `restore` disposition can copy the file out of it
#                        (phases/8-finalize.md step 4) instead of re-materializing.
#   template-parity.tsv   path <TAB> status <TAB> detail, one row per template path
#                         absent from the component; status absent|relocated|
#                         rename?  — leading `#` summary. ALWAYS written on success,
#                         INCLUDING when empty: zero findings is positive evidence
#                         that the check ran and the trees agree, not silence about
#                         whether it ran.
# Stderr:  one summary line — counts, or the reason no artifact was written.
# Exit:    0  computed cleanly (INCLUDING zero findings — positive evidence).
#          2  skip that escalates: on the template arm $SYNTH unset or the
#             kairos-target tag missing; on the frontend arm no usable basis (no
#             FE_TARGET_TREE and no FE_CACHE/FE_TARGET/FE_MODULE_PATH, an
#             unresolvable target, no component name to substitute with, or a basis
#             that came out empty). No artifact written — an empty basis would read
#             as "nothing is missing", the false negative this check exists to stop.
set -u

: "${RUN:?FAIL: RUN not set}"

STARGET=kairos-target
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MOUNT=${MOUNT:-}
MDIR=${MOUNT%/}

skip() { echo "SKIP: $*" >&2; exit 2; }

# --- exit-2 probes: BEFORE any artifact is created or truncated ---------------
# so a skip leaves nothing on disk that could read as "nothing is missing".
if [[ -z "$MOUNT" ]]; then
  [[ -n "${SYNTH:-}" ]] || {
    echo "SKIP: SYNTH not set — cannot compute template parity without the target tree (tag $STARGET). Incomplete coverage, not a clean result; no artifact was written." >&2
    exit 2
  }
  git -C "$SYNTH" rev-parse --verify --quiet "$STARGET^{commit}" >/dev/null 2>&1 || {
    echo "SKIP: $SYNTH is missing tag $STARGET — the target tree cannot be listed. Incomplete coverage, not a clean result; re-run scripts/materialize.sh. No artifact was written." >&2
    exit 2
  }
else
  if [[ -n "${FE_TARGET_TREE:-}" ]]; then
    [[ -d "$FE_TARGET_TREE" ]] \
      || skip "FE_TARGET_TREE=$FE_TARGET_TREE is not a directory — the frontend parity basis cannot be listed. Incomplete coverage, not a clean result; no artifact was written."
    PBASE=$FE_TARGET_TREE
    PBASIS="the supplied substituted target tree $FE_TARGET_TREE"
  else
    [[ -n "${FE_CACHE:-}" ]] && [[ -n "${FE_TARGET:-}" ]] && [[ -n "${FE_MODULE_PATH:-}" ]] \
      || skip "the frontend arm (MOUNT=$MOUNT) needs either FE_TARGET_TREE or all of FE_CACHE/FE_TARGET/FE_MODULE_PATH — got FE_CACHE='${FE_CACHE:-}' FE_TARGET='${FE_TARGET:-}' FE_MODULE_PATH='${FE_MODULE_PATH:-}'. Incomplete coverage, not a clean result; no artifact was written."
    git -C "$FE_CACHE" rev-parse --verify --quiet "$FE_TARGET^{commit}" >/dev/null 2>&1 \
      || skip "$FE_TARGET does not resolve to a commit in $FE_CACHE — the frontend target tree cannot be listed. Incomplete coverage, not a clean result; no artifact was written."
    NAME=${COMPONENT_NAME:-}
    if [[ -z "$NAME" ]] && [[ -f .kairos/manifest.yaml ]]; then
      NAME=$(yq -r '.name // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
    fi
    # No name, no substitution — and an UNSUBSTITUTED basis false-flags every file
    # that carries the component's name, which is most of them. Skip loudly instead.
    [[ -n "$NAME" ]] \
      || skip "no component name to substitute the frontend target tree with (COMPONENT_NAME unset and .kairos/manifest.yaml has no name:). An unsubstituted basis would report nearly every mount file as drifted. Incomplete coverage, not a clean result; no artifact was written."
    PBASE=$RUN/frontend-parity-target
    mkdir -p "$RUN"
    rm -rf "$PBASE"
    mkdir -p "$PBASE"
    git -C "$FE_CACHE" archive "$FE_TARGET:$FE_MODULE_PATH" 2>/dev/null | tar -x -C "$PBASE" 2>/dev/null \
      || skip "cannot extract $FE_MODULE_PATH at $FE_TARGET from $FE_CACHE — the frontend target tree cannot be listed. Incomplete coverage, not a clean result; no artifact was written."
    # The SAME map component create applies after copy — merge sides and this basis
    # must be create-equivalent or every substituted file reads as drifted.
    # GUARDED, like materialize-frontend.sh's source of the same helper: an unreadable
    # or missing lib/ (a partial checkout, a moved file) sourced blind leaves
    # apply_create_substitution undefined, and the failure then reads as "the
    # substitution failed over this tree" — a claim about the tree, pointing the reader
    # at the wrong repo entirely.
    [[ -r "$SCRIPT_DIR/lib/frontend-substitute.sh" ]] \
      || skip "missing $SCRIPT_DIR/lib/frontend-substitute.sh — it owns the create-time replacement map, and without it the frontend parity basis cannot be made create-equivalent (every token-bearing mount file would read as drifted). Incomplete coverage, not a clean result; no artifact was written."
    # shellcheck source=lib/frontend-substitute.sh
    . "$SCRIPT_DIR/lib/frontend-substitute.sh" \
      || skip "could not source $SCRIPT_DIR/lib/frontend-substitute.sh. Incomplete coverage, not a clean result; no artifact was written."
    command -v apply_create_substitution >/dev/null 2>&1 \
      || skip "$SCRIPT_DIR/lib/frontend-substitute.sh defined no apply_create_substitution — refusing to compare against a RAW (unsubstituted) basis. Incomplete coverage, not a clean result; no artifact was written."
    apply_create_substitution "$PBASE" "$NAME" \
      || skip "the create-time substitution failed over $PBASE — the basis would not be create-equivalent. Incomplete coverage, not a clean result; no artifact was written."
    PBASIS="frontend module $FE_MODULE_PATH at $(git -C "$FE_CACHE" rev-parse --short "$FE_TARGET" 2>/dev/null || echo "$FE_TARGET"), substituted for $NAME"
  fi
fi

OUT="$RUN/template-parity.tsv"
mkdir -p "$RUN"

# --- scratch ------------------------------------------------------------------
TMPL=$(mktemp "${TMPDIR:-/tmp}/tparity-tmpl.XXXXXX")
COMP=$(mktemp "${TMPDIR:-/tmp}/tparity-comp.XXXXXX")
GUARDS=$(mktemp "${TMPDIR:-/tmp}/tparity-guards.XXXXXX")
BODY=$(mktemp "${TMPDIR:-/tmp}/tparity-body.XXXXXX")
# Frontend-arm only: mount files that exist in the WORKING TREE but that `git ls-files`
# (tracked-only, below) omits — untracked or git-ignored. Empty on the template arm.
DISKPRESENT=$(mktemp "${TMPDIR:-/tmp}/tparity-disk.XXXXXX")
trap 'rm -f "$TMPL" "$COMP" "$GUARDS" "$BODY" "$DISKPRESENT"' EXIT

if [[ -z "$MOUNT" ]]; then
  # Template blobs: oid <TAB> path. `-r` recurses; keep only type `blob` (a submodule
  # is a `commit`, a subtree a `tree` — neither is a file the component could carry).
  # pipefail-scoped to this one pipeline (the script otherwise relies on `||` chains,
  # not a global `set -e`): a failed `ls-tree` with an unguarded pipe leaves $TMPL
  # empty, and an empty basis reads as "the target ships nothing" — zero findings
  # presented as positive evidence instead of the hard error it is.
  ( set -o pipefail
    git -C "$SYNTH" -c core.quotePath=false ls-tree -r "$STARGET" \
      | awk '$2 == "blob" { oid = $3; sub(/^[^\t]*\t/, ""); print oid "\t" $0 }' > "$TMPL"
  ) || skip "git ls-tree -r $STARGET in $SYNTH failed — the template basis could not be listed. Incomplete coverage, not a clean result; no artifact was written."
else
  # Frontend basis: the substituted subtree's entries, hashed with the SAME object
  # hash `git ls-files -s` reports below, and each path prefixed with the mount so the
  # two sides are comparable at all. Regular files and symlinks are hashed differently
  # (see the two passes below) precisely so both sides mean the same thing.
  FLIST=$(mktemp "${TMPDIR:-/tmp}/tparity-flist.XXXXXX")
  FOIDS=$(mktemp "${TMPDIR:-/tmp}/tparity-foids.XXXXXX")
  trap 'rm -f "$TMPL" "$COMP" "$GUARDS" "$BODY" "$DISKPRESENT" "$FLIST" "$FOIDS" "$FLIST.reg" "$FLIST.lnk" "$FLIST.regoid"' EXIT
  # `-type f -o -type l`, the same list materialize-frontend.sh installs from: the
  # template arm lists every blob in the target tree INCLUDING 120000 (symlink) blobs,
  # so a files-only walk here made a shipped symlink the one absence this check can
  # never report — invisible on exactly the arm where the mount is the whole deliverable.
  ( cd "$PBASE" && find . \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort ) > "$FLIST"
  [[ -s "$FLIST" ]] \
    || skip "the frontend parity basis ($PBASIS) contains no files — an empty basis would read as 'nothing is missing'. Incomplete coverage, not a clean result; no artifact was written."
  # Two hashing passes, joined into ONE `oid <TAB> relpath` file, because a symlink's
  # blob is its LINK TEXT: git stores it as a blob whose content is the target path,
  # which is exactly what `git ls-files -s` reports for the component side. Hashing it
  # through the link (what `--stdin-paths` does) would compare the pointed-at file's
  # bytes against a link blob — a guaranteed non-match, i.e. a false `absent` — and a
  # DANGLING link would fail the batch outright and skip the entire scan. Regular files
  # keep the single batched call; links are hashed one at a time, of which a tree has few.
  : > "$FOIDS"
  FREG="$FLIST.reg"; FLNK="$FLIST.lnk"
  : > "$FREG"; : > "$FLNK"
  while IFS= read -r frel; do
    [[ -n "$frel" ]] || continue
    if [[ -L "$PBASE/$frel" ]]; then printf '%s\n' "$frel" >> "$FLNK"
    else printf '%s\n' "$frel" >> "$FREG"; fi
  done < "$FLIST"
  if [[ -s "$FREG" ]]; then
    # git >= 2.50 `hash-object --stdin-paths` resolves each RELATIVE path against the
    # repo ROOT, NOT the process cwd — a `cd "$PBASE"` does not move it. $PBASE sits
    # inside the component work tree, so a bare relpath would (a) abort the whole batch
    # on any basis-only file ("could not open '<relpath>'"), skipping the entire scan,
    # and (b) where the same relpath ALSO exists at the repo root, silently hash the
    # WRONG (root) blob — a false content match. Feed ABSOLUTE paths so the resolution
    # base is irrelevant; oids come back in input order and paste against the relpaths.
    PBASE_ABS=$(cd "$PBASE" && pwd) \
      || skip "cannot resolve the frontend parity basis dir $PBASE to an absolute path. Incomplete coverage, not a clean result; no artifact was written."
    awk -v b="$PBASE_ABS/" '{ print b $0 }' "$FREG" | git hash-object --stdin-paths > "$FLIST.regoid" \
      || skip "cannot hash the frontend parity basis under $PBASE. Incomplete coverage, not a clean result; no artifact was written."
    paste "$FLIST.regoid" "$FREG" >> "$FOIDS"
  fi
  while IFS= read -r frel; do
    [[ -n "$frel" ]] || continue
    flink=$(readlink "$PBASE/$frel" 2>/dev/null) \
      || skip "cannot read the symlink $frel in the frontend parity basis under $PBASE. Incomplete coverage, not a clean result; no artifact was written."
    foid=$(printf '%s' "$flink" | git hash-object --stdin) \
      || skip "cannot hash the symlink $frel in the frontend parity basis under $PBASE. Incomplete coverage, not a clean result; no artifact was written."
    printf '%s\t%s\n' "$foid" "$frel" >> "$FOIDS"
  done < "$FLNK"
  rm -f "$FREG" "$FLNK" "$FLIST.regoid"
  # $FOIDS is already `oid <TAB> relpath`; the mount prefix is what makes the two sides
  # comparable at all.
  LC_ALL=C sort -t "$(printf '\t')" -k2,2 "$FOIDS" \
    | awk -F'\t' -v m="${MDIR:+$MDIR/}" '{ printf "%s\t%s%s\n", $1, m, $2 }' > "$TMPL"
fi

# Component blobs: oid <TAB> path, from the tracked (committed/index) tree.
git -c core.quotePath=false ls-files -s \
  | awk '{ oid = $2; sub(/^[^\t]*\t/, ""); print oid "\t" $0 }' > "$COMP"

# Frontend-arm presence supplement. `git ls-files` above lists only TRACKED files, but
# a component's ROOT .gitignore (a Go backend's `*.local`, `.env*`, `dist/`, …) can hide
# a mount file that is present on disk and a genuine frontend deliverable. On the
# template arm that basis is `component create` output, sharing the component's ignore
# semantics, so tracked-only is right (header). On the FRONTEND arm the basis is the
# frontend template's files judged against a backend's ignore rules — so a present-but-
# ignored mount file would be misreported as `absent`, and Phase 8 would offer a
# spurious `restore` that force-adds or clobbers the user's own file. Capture the mount's
# working-tree files (tracked or not, cwd is the component root so paths are mount-
# prefixed) so the classify pass can call such a file present-but-untracked, not absent.
if [[ -n "$MOUNT" ]] && [[ -d "$MDIR" ]]; then
  find "$MDIR" \( -type f -o -type l \) -print 2>/dev/null | LC_ALL=C sort -u > "$DISKPRESENT"
fi

# Absence-form guard paths from the VETTED active set. The closed grammar's absence
# forms are `test ! -e|-f|-d|-s <path>` (reference/intent-guard.md). We read only
# those — a `grep -q` guard or a non-negated `test` asserts something else. The
# leading `guard:` may be indented; the `!` is required for an absence assertion.
if [[ -f "$RUN/intent-active.md" ]]; then
  awk '
    /^[[:space:]]*guard:[[:space:]]*test[[:space:]]+![[:space:]]+-[efds][[:space:]]/ {
      # tokens: ... guard: test ! -X <path>
      for (i = 1; i <= NF; i++) if ($i == "!") { print $(i+2); break }
    }
  ' "$RUN/intent-active.md" | sed '/^$/d' > "$GUARDS"
fi

# --- classify: all set logic in one awk, maps built before the target scan -----
# Files are read in arg order (guards, comp, tmpl); by the time tmpl is scanned the
# component maps and the component-only same-dir/ext index are complete. No
# associative-array bashism — the maps live in awk, portable to mawk/gawk/bwk.
awk -F'\t' -v gf="$GUARDS" -v cf="$COMP" -v tf="$TMPL" -v df="$DISKPRESENT" -v marm="$MOUNT" '
  function dirof(p,   i) { i = length(p); while (i > 0 && substr(p,i,1) != "/") i--; return (i > 0) ? substr(p,1,i) : "" }
  function extof(p,   b, i) { b = p; sub(/^.*\//, "", b); i = length(b); while (i > 0 && substr(b,i,1) != ".") i--; return (i > 0) ? substr(b,i) : b }
  function key(p) { return dirof(p) SUBSEP extof(p) }

  FILENAME == gf { guard[$1] = 1; next }
  FILENAME == df { diskpath[$1] = 1; next }
  FILENAME == cf {
    comppath[$2] = 1
    if ($1 in compoid) compoid[$1] = compoid[$1] ", " $2; else compoid[$1] = $2
    corder[++cn] = $0                       # defer component-only index to END
    next
  }
  FILENAME == tf { tpath[$2] = 1; toid[$2] = $1; torder[++tn] = $2; next }

  END {
    # Component-only files (present in component, absent from target) indexed by
    # dir+ext — the rename? candidate pool.
    for (i = 1; i <= cn; i++) {
      split(corder[i], f, "\t"); p = f[2]
      if (!(p in tpath)) {
        k = key(p)
        if (k in conly) conly[k] = conly[k] ", " p; else conly[k] = p
      }
    }
    absent = 0; relocated = 0; renamed = 0; subtracted = 0; untracked = 0
    for (i = 1; i <= tn; i++) {
      p = torder[i]
      if (p in comppath) continue          # present in the committed tree — parity OK
      # Frontend arm: present in the WORKING TREE but not committed (untracked or hidden
      # by the component root .gitignore). It is NOT absent — reporting it so would drive
      # a spurious Phase 8 restore. Surface it as its own status: the file is there, but
      # it will not ride the migration commit until it is force-added.
      if (marm != "" && (p in diskpath)) {
        printf "%s\tuntracked\tpresent in the working tree but not committed (git-ignored or unstaged) — run git add -f to include it in the migration commit\n", p
        untracked++
        continue
      }
      if (p in guard)  { subtracted++; continue }   # dispositioned deliberate absence — a guard that
                                                     # actually suppressed a finding (absent template path)
      o = toid[p]
      if (o in compoid) {
        printf "%s\trelocated\tidentical content at: %s\n", p, compoid[o]
        relocated++
      } else if (key(p) in conly) {
        printf "%s\trename?\tsame dir/ext component-only file(s): %s\n", p, conly[key(p)]
        renamed++
      } else {
        printf "%s\tabsent\tno counterpart in the component\n", p
        absent++
      }
    }
    printf "@@COUNTS@@\t%d\t%d\t%d\t%d\t%d\n", absent, relocated, renamed, subtracted, untracked > "/dev/stderr"
  }
' "$GUARDS" "$DISKPRESENT" "$COMP" "$TMPL" > "$BODY" 2> "$BODY.counts"
AWK_STATUS=$?
# The `@@COUNTS@@` line is only ever written by the awk program's own END block —
# so it shares fd 2 with whatever awk itself prints on a mid-scan die (a runtime
# error, an out-of-memory abort). Grep it out by its own marker rather than
# trusting "first line of stderr": an awk death otherwise gets `read` into
# ABSENT/RELOCATED/RENAMED/SUBTRACTED as if it were the real counts, and the
# defaulting below (`${ABSENT:-0}`) would then silently paper over it as zero
# findings instead of surfacing the failure.
COUNTS_LINE=$(grep '^@@COUNTS@@	' "$BODY.counts" || true)
if [[ "$AWK_STATUS" -ne 0 ]] || [[ -z "$COUNTS_LINE" ]]; then
  {
    echo "the classify awk pass failed (exit $AWK_STATUS) or never reached its END block — treating as a hard error, not an empty parity report. awk stderr:"
    cat "$BODY.counts"
  } >&2
  rm -f "$BODY.counts"
  skip "template-parity's classification pass did not complete cleanly. Incomplete coverage, not a clean result; no artifact was written."
fi
read -r _ ABSENT RELOCATED RENAMED SUBTRACTED UNTRACKED <<EOF
$COUNTS_LINE
EOF
rm -f "$BODY.counts"
ABSENT=${ABSENT:-0}; RELOCATED=${RELOCATED:-0}; RENAMED=${RENAMED:-0}; SUBTRACTED=${SUBTRACTED:-0}; UNTRACKED=${UNTRACKED:-0}
TOTAL=$((ABSENT + RELOCATED + RENAMED))
NOTE=""
[[ -f "$RUN/intent-active.md" ]] || NOTE=" (no intent-active.md — no deliberate-absence subtraction applied)"
# The frontend arm names its basis in the artifact: which module, which commit, and
# that it is the substituted tree mapped onto the mount — the reader dispositioning a
# row needs to know what "the template ships this" meant here.
[[ -z "$MOUNT" ]] || NOTE="$NOTE Basis: $PBASIS, mapped onto $MDIR/ (kept at $PBASE)."

# The untracked note appears only when the frontend arm found present-but-uncommitted
# mount files (UNTRACKED>0), so the template arm's report stays byte-identical.
UNTRACKED_NOTE=""
[[ "$UNTRACKED" -gt 0 ]] && UNTRACKED_NOTE=" ${UNTRACKED} present in the working tree but untracked/ignored (not committed — 'git add -f' to include them)."

printf '# template-parity: %d template path(s) absent from the component (absent=%d relocated=%d rename?=%d); %d intent-guarded absence(s) subtracted.%s%s\n' \
  "$TOTAL" "$ABSENT" "$RELOCATED" "$RENAMED" "$SUBTRACTED" "$UNTRACKED_NOTE" "$NOTE" > "$OUT"
cat "$BODY" >> "$OUT"

printf 'OK: template-parity computed — %d finding(s) (absent=%d relocated=%d rename?=%d), %d guarded absence(s) subtracted;%s wrote %s\n' \
  "$TOTAL" "$ABSENT" "$RELOCATED" "$RENAMED" "$SUBTRACTED" "$UNTRACKED_NOTE" "$OUT" >&2
exit 0
