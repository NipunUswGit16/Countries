#!/usr/bin/env bash
# materialize.sh — produce the BASE and TARGET template trees the merge runs
# against by invoking the Kairos CLI itself, then commit both into a throwaway
# synthetic git repo. Classification diffs the two synthetic commits; the merger
# reads its base/theirs blobs from them.
#
# WHY the CLI and not our own substitution: components are BORN from
# `kairos component create`. Substitution logic re-implemented in this skill
# drifts from it silently. The first real migration landed files importing the
# TEMPLATE's Go module path — a hard build failure — because the skill knew
# nothing about the CLI's module-path rewrite, its extra token forms
# (<YOUR_BC_NAME>, bare YOUR_COMPONENT_NAME, lowercase filename forms), or the
# fact that it only rewrites content inside an extension whitelist. Letting the
# CLI materialize both sides makes that parity structural instead of maintained.
#
# Consequence (accepted): migrations are impossible without an up-to-date Kairos
# CLI. pre-flight.sh probes for it and fails loudly BEFORE any state is written.
#
# Env in:  PHASE_KEY       required — proof-of-load key stated in phases/2.5-materialize.md
#          CACHE           template mirror (git dir)
#          BASE            baseline template SHA
#          TARGET          target template SHA
#          RUN             migration state dir
#          COMPONENT_NAME  optional — default manifest `name:`, else cwd basename
#          KAIROS_BIN      optional — default `kairos`
#          COMPONENT_KIND  optional — facade | component; default lib/component-kind.sh
#                          (manifest template.kind, else the `.init.mk` facade check)
#          FORCE_MATERIALIZE  optional — set to ignore the reuse stamp
# Cwd:     component root
# Out (in $RUN):
#   synthetic/                git repo; tags kairos-base / kairos-target
#   materialization.txt       what was materialized, and whether a corrective
#                             module-path substitution was applied
#   surviving-tokens.tsv      side <TAB> path <TAB> token — placeholder-shaped
#                             strings the CLI did NOT substitute. Template
#                             feedback, NOT an error: an unregistered token is
#                             the template author's bug, and it would otherwise
#                             surface only as unexplained merge noise.
# Stdout:  SYNTH=<path-to-synthetic-repo>
set -u

fail() { echo "FAIL: $*" >&2; exit 1; }

# Phase-load guard: this key is stated ONLY in phases/2.5-materialize.md, so an
# orchestrator that skipped loading that file cannot know it. The guard turns a
# skipped load into a stop instead of a phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "n41g1bxq" ]] || fail "load phases/2.5-materialize.md first"

for v in CACHE BASE TARGET RUN; do
  [[ -n "$(eval echo "\${$v:-}")" ]] || fail "$v not set"
done

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/component-kind.sh
. "$HERE/lib/component-kind.sh" || fail "could not source $HERE/lib/component-kind.sh"

# Both success paths (fresh materialization and stamped reuse) record
# SYNTH/BASE/TARGET into the run-context anchor: a compacted session re-reads
# $RUN/context.env instead of trusting conversation memory (SKILL.md).
record_context() {
  RUN="$RUN" "$HERE/record-context.sh" "SYNTH=$SYNTH" "BASE=$BASE" "TARGET=$TARGET" \
    || fail "could not record run context in $RUN/context.env"
}

KAIROS_BIN=${KAIROS_BIN:-kairos}
COMPONENT_NAME=${COMPONENT_NAME:-}
[[ -n "$COMPONENT_NAME" ]] || COMPONENT_NAME=$(yq -r '.name // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
[[ -n "$COMPONENT_NAME" ]] || COMPONENT_NAME=$(basename "$(pwd)")
# A facade is born from `kairos component facade create`, so its merge sides are
# materialized the same way: `component create` would rewrite the component
# template's module path, which a facade tree does not carry.
COMPONENT_KIND=${COMPONENT_KIND:-$(component_kind .)}
case "$COMPONENT_KIND" in
  facade|component) ;;
  *) fail "COMPONENT_KIND must be facade or component (got '$COMPONENT_KIND')" ;;
esac

# The component's own module path is the authority for the corrective
# substitution below. Read it before we cd anywhere.
COMP_MODULE=$(awk '$1 == "module" { print $2; exit }' go.mod 2>/dev/null || echo "")

# Fail loudly HERE if the mirror is gone: under `set -u` without `set -e` a
# failed `cd` would leave CACHE_ABS empty and surface later as a baffling
# worktree-add error pointing nowhere near the real cause.
CACHE_ABS=$(cd "$CACHE" 2>/dev/null && pwd) || fail "CACHE dir missing or unreadable: $CACHE"
[[ -n "$CACHE_ABS" ]] || fail "could not resolve CACHE dir to an absolute path: $CACHE"
MAT="$RUN/mat"
SYNTH="$RUN/synthetic"
STAMP="$SYNTH/.materialize-stamp"
WANT_STAMP="$BASE $TARGET $COMPONENT_NAME ${COMP_MODULE:-none} $COMPONENT_KIND"

# --- reuse guard ---------------------------------------------------------------
# Materializing costs two full CLI runs over the whole template tree. Continue
# mode re-enters mid-migration and must not re-pay that, so a stamp recording
# the exact inputs lets an unchanged run skip straight to the existing repo.
if [[ -z "${FORCE_MATERIALIZE:-}" ]] && [[ -f "$STAMP" ]] && [[ -d "$SYNTH/.git" ]] \
   && [[ "$(cat "$STAMP")" = "$WANT_STAMP" ]] \
   && git -C "$SYNTH" rev-parse -q --verify kairos-base >/dev/null 2>&1 \
   && git -C "$SYNTH" rev-parse -q --verify kairos-target >/dev/null 2>&1; then
  echo "INFO: reusing materialized trees in $SYNTH (stamp matches)" >&2
  record_context
  echo "SYNTH=$SYNTH"
  exit 0
fi

rm -rf "$MAT" "$SYNTH"
# CHECKED, and naming the run dir — the same guard the CACHE path gets above, for the
# same failure class. An unwritable $RUN used to let these mkdirs fail SILENTLY (set -u,
# no set -e); the absolute-path derivation just below then resolved to the EMPTY string,
# and materialize_side built wt="$MAT_ABS/wt-$side" = "/wt-base", out = "/out-base", and
# ran `rm -rf` / `git worktree add` against filesystem-ROOT paths. Stop at the first
# failed creation instead, before any such path can be formed.
mkdir -p "$MAT" "$SYNTH" \
  || fail "could not create the per-run scratch dirs under $RUN (is $RUN writable?): $MAT and $SYNTH — refusing to continue, because the absolute-path derivation below would otherwise resolve to the empty string and later operations would target filesystem-root paths (/wt-base, /out-base)"
: > "$RUN/surviving-tokens.tsv" \
  || fail "could not initialize $RUN/surviving-tokens.tsv (is $RUN writable?)"

# $RUN is relative (the orchestrator passes .kairos/migration/state). Two
# consumers below cannot take a relative path: `git -C "$CACHE" worktree add`
# resolves it against the MIRROR's directory, and the CLI's click Path option
# resolves it against the CLI's own cwd. Both need it absolute. $SYNTH stays
# relative — nothing ever cds away from the component root, and downstream
# scripts address it the same way they address every other $RUN artifact.
# CHECKED, exactly as CACHE_ABS is above (and for the identical reason): a silent `cd`
# failure here left MAT_ABS empty, and every worktree/output path below is built from it —
# an empty value turns "$MAT_ABS/wt-$side" into the filesystem-root "/wt-$side".
MAT_ABS=$(cd "$MAT" 2>/dev/null && pwd) \
  || fail "could not resolve the scratch dir to an absolute path: $MAT (is $RUN writable?)"
[[ -n "$MAT_ABS" ]] \
  || fail "resolved the scratch dir to an EMPTY absolute path: $MAT — refusing to build worktree/output paths against filesystem root"

git -C "$SYNTH" init -q -b main >/dev/null 2>&1 || fail "could not init synthetic repo at $SYNTH"
# The synthetic repo exists only to give the classifier a diff and the merger
# blob addresses. Nothing here is ever pushed or shown, so identity is fixed
# locally rather than inherited from the user's config (which may be unset).
git -C "$SYNTH" config user.name  "kairos-component-update" >/dev/null 2>&1
git -C "$SYNTH" config user.email "kairos-component-update@localhost" >/dev/null 2>&1
# The component may ship a .gitattributes with eol//text rules; a synthetic repo
# that honoured them would re-introduce exactly the CRLF churn this pipeline
# normalizes away. Keep it attribute-free and byte-exact.
git -C "$SYNTH" config core.autocrlf false >/dev/null 2>&1
# Signing and hooks are pinned off for the same reason identity is pinned above:
# these commits are throwaway diff scaffolding, but a user-level
# `commit.gpgsign=true` (common) makes each one block on a pinentry prompt — a
# hang in an unattended multi-hour run, or a hard failure with no agent — and a
# global core.hooksPath would run the user's hooks against trees they were never
# written for. `/dev/null` is git's documented way to disable hooks per-repo.
git -C "$SYNTH" config commit.gpgsign false >/dev/null 2>&1
git -C "$SYNTH" config tag.gpgSign false >/dev/null 2>&1
git -C "$SYNTH" config core.hooksPath /dev/null >/dev/null 2>&1
# IGNORE AND FILTER SEMANTICS ARE PINNED OFF TOO, for a reason the autocrlf note
# above only half states: staging here must be COMPLETE and BYTE-EXACT, and both
# properties are decided by config and by files the TEMPLATE itself installs into
# this repo moments before `git add` runs.
#   * ignore rules — the template's own .gitignore lands in $SYNTH, and an
#     operator's global core.excludesFile applies with no template cooperation.
#     Either one matching an installed template file removed it from BOTH
#     synthetic commits, so the classifier's diff was EMPTY for that path and the
#     template's change to it was silently dropped from the migration. Hence
#     core.excludesFile=/dev/null AND `git add -f -A` below (the -f forces past
#     any .gitignore the template ships, which config cannot reach).
#   * attribute filters — a `filter=` driver named by an installed .gitattributes
#     and defined in the operator's global config (the git-lfs shape) REWRITES
#     every blob on the way into the index: the merge then ran against content
#     neither side has, and a real v1->v2 change whose difference the clean filter
#     normalizes away collapsed to no diff at all. $GIT_DIR/info/attributes has
#     the HIGHEST precedence of any attributes source (gitattributes(5)), so it is
#     the only mechanism that provably wins over a .gitattributes installed in the
#     work tree — a config setting cannot. `-text` neutralizes eol/text conversion
#     at the same precedence, belt-and-braces with core.autocrlf above.
#     DELIBERATELY NOT `-diff`: unsetting diff makes git report every path as
#     "Binary files differ", and build-manifest.sh derives binaries-template.txt
#     from `diff --numstat`, so it would route the ENTIRE template into the
#     binary-for-user bucket.
git -C "$SYNTH" config core.excludesFile /dev/null >/dev/null 2>&1
# core.symlinks=false (a Windows-shaped global) would record a materialized
# symlink as a regular file carrying its link text; the 120000 modes this repo
# hands the merge have to be real.
git -C "$SYNTH" config core.symlinks true >/dev/null 2>&1
printf '* -filter -text\n' > "$SYNTH/.git/info/attributes" \
  || fail "could not pin attribute handling off for the synthetic repo ($SYNTH/.git/info/attributes) — without it an installed .gitattributes plus an operator-global filter driver would rewrite every staged blob, and the merge would run against content neither template side has"

# NUL byte in the first 8KB → binary. (Deliberately NOT `grep -q $'\x00'` —
# shell arguments can't carry NUL, so that pattern silently becomes empty and
# matches everything.)
is_binary_file() {
  [[ -f "$1" ]] || return 1
  [[ "$(head -c 8192 "$1" | LC_ALL=C tr -d '\000' | wc -c)" -ne "$(head -c 8192 "$1" | wc -c)" ]]
}

esc()     { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's|/|\\/|g' -e 's/&/\\&/g'; }
esc_pat() { printf '%s' "$1" | sed -e 's/[][\.*^$/]/\\&/g'; }

CORRECTIVE=""      # human-readable note for materialization.txt

# --- one `component create` attempt --------------------------------------------
# KAIROS_SKIP_NAME_VALIDATION: real component names legitimately contain
# 'kairos'/'nga' (kairos-notes-demo), which the CLI otherwise rejects with an
# INTERACTIVE re-prompt — that would hang the migration. --no-tidy/--no-frontend
# keep this a pure tree materialization: no goproxy, no Go env, no network clone
# of the frontend template, no interactive template picker.
#
# Clearing $out is part of THIS function, not of its caller, so the retry below
# cannot start from a half-created tree: the first attempt aborted mid-write, and
# a second create layered over that debris would either refuse to run or produce
# a tree mixing both attempts.
#
# A facade goes through `component facade create`, which has no frontend step and
# no --no-frontend flag (passing one is a click usage error).
create_component() { # create_component <worktree> <out> <log>
  local wt="$1" out="$2" log="$3"

  rm -rf "$out"
  mkdir -p "$out"
  if [[ "$COMPONENT_KIND" = facade ]]; then
    KAIROS_SKIP_NAME_VALIDATION=1 "$KAIROS_BIN" component facade create \
      "$COMPONENT_NAME" "$out" \
      --template-path "$wt" \
      --no-repository --no-skills --no-tidy \
      > "$log" 2>&1
  else
    KAIROS_SKIP_NAME_VALIDATION=1 "$KAIROS_BIN" component create \
      "$COMPONENT_NAME" "$out" \
      --template-path "$wt" \
      --no-repository --no-skills --no-tidy --no-frontend \
      > "$log" 2>&1
  fi
}

# --- materialize one side ------------------------------------------------------
# A worktree checked out from the mirror is exactly what a developer would hand
# to `--template-path`, so the CLI takes the same code path it takes at component
# birth. No network per materialization.
#
# Deliberately returns nothing on stdout: the output path is deterministic
# ($MAT/out-<side>/$COMPONENT_NAME), and capturing a value with $(...) would run
# this in a subshell where `fail`'s exit could not stop the parent script.
materialize_side() { # materialize_side <sha> <side-label>
  local sha="$1" side="$2"
  local wt="$MAT_ABS/wt-$side" out="$MAT_ABS/out-$side"
  local log="$RUN/materialize-$side.log"

  rm -rf "$wt"
  git -C "$CACHE_ABS" worktree add --detach --force "$wt" "$sha" >/dev/null 2>&1 \
    || fail "could not check out template worktree for $side ($sha)"

  # The template tree must be the component's kind. A facade merged against
  # kairos-component-template gains runtimes; a component merged against the
  # facade template loses them. Either is the wrong TEMPLATE_REPO, not a merge.
  # Classified by the tree's go.mod module line (lib/component-kind.sh), never
  # by an .init.mk marker the facade template does not commit.
  local tkind
  tkind=$(template_tree_kind "$wt")
  if [[ "$tkind" != "$COMPONENT_KIND" ]]; then
    git -C "$CACHE_ABS" worktree remove --force "$wt" >/dev/null 2>&1 || true
    if [[ "$COMPONENT_KIND" = facade ]]; then
      fail "this component is a facade, but the template at $side ($sha) is not the facade template (its go.mod module is not $FACADE_TEMPLATE_MODULE). Migrate against $FACADE_TEMPLATE_REPO: fix template.repo in .kairos/manifest.yaml, or TEMPLATE_REPO/--template-path on a bootstrap."
    else
      fail "the template at $side ($sha) is the facade template (its go.mod module is $FACADE_TEMPLATE_MODULE), but this component is not a facade. Migrate against $COMPONENT_TEMPLATE_REPO, or record template.kind: facade if the component really is one."
    fi
  fi

  # Retry ONCE. The first production migration lost its first `component create`
  # to `component_create() missing 1 required positional argument` — the CLI
  # install changed under the running invocation (an out-of-band update to
  # nga-local-dev leaves pending work that the next invocation settles: a
  # dependency reinstall, a version-state migration) and a plain manual retry
  # then succeeded. pre-flight burns a throwaway invocation to absorb that, but
  # the CLI exposes no way to force it from here, so the warm-up is best-effort
  # and this retry is the actual defense. One retry only: a create that fails
  # twice is a real failure, not a race, and must stop the migration.
  if ! create_component "$wt" "$out" "$log"; then
    mv "$log" "$RUN/materialize-$side.attempt1.log" 2>/dev/null || true
    echo "WARN: kairos component create failed materializing $side ($sha) — retrying once. First attempt: $RUN/materialize-$side.attempt1.log" >&2
    if ! create_component "$wt" "$out" "$log"; then
      git -C "$CACHE_ABS" worktree remove --force "$wt" >/dev/null 2>&1 || true
      echo "--- last 20 lines of $log ---" >&2
      tail -20 "$log" >&2
      fail "kairos component create failed twice (initial + retry) materializing $side ($sha). See $log"
    fi
  fi

  git -C "$CACHE_ABS" worktree remove --force "$wt" >/dev/null 2>&1 || true

  [[ -d "$out/$COMPONENT_NAME" ]] \
    || fail "CLI produced no tree at $out/$COMPONENT_NAME for $side"
}

# --- install a materialized tree into the synthetic repo ----------------------
# Text files are LF-normalized on the way in. Doing it here (rather than only at
# merge time) also makes the BASE..TARGET diff itself line-ending-proof, so a
# template that flipped a file's endings doesn't present as a whole-file change
# to the classifier.
install_side() { # install_side <src-tree> <side-label> <mat-module>
  local src="$1" side="$2" mat_module="$3"
  local subst=0
  if [[ -n "$mat_module" ]] && [[ -n "$COMP_MODULE" ]] && [[ "$mat_module" != "$COMP_MODULE" ]]; then
    subst=1
  fi

  # Clear the working tree (keep .git and the stamp) so a deletion between BASE
  # and TARGET shows up as a deletion in the synthetic diff. Checked, like every
  # other side-effecting step in this script: an unchecked `|| true` here used to
  # swallow a partial clear (a locked file, a permission change mid-run) and let
  # the OTHER side's already-committed files ride into this side's install —
  # silently corrupting the classification diff with content neither BASE nor
  # TARGET actually has at this path. A hard stop here, before anything for this
  # side is installed, is strictly better: nothing for $side is written on top of
  # a tree that isn't cleanly the other side's any more.
  CLEAR_ERR=$(find "$SYNTH" -mindepth 1 -maxdepth 1 \
    ! -name .git ! -name "$(basename "$STAMP")" -exec rm -rf {} + 2>&1)
  CLEAR_RC=$?
  [[ "$CLEAR_RC" -eq 0 ]] || fail "could not clear $SYNTH before installing the $side side (exit $CLEAR_RC): $CLEAR_ERR — a partial clear would let the other side's already-installed files ride into this side's tree and corrupt the classification diff. Nothing for $side was installed."

  # The install list is materialized to a file so the copy loop runs in THIS
  # shell. Its former `find | while` form put every write in a subshell: a
  # failed mkdir or a short write was invisible and its exit status lost, so a
  # full disk produced a TRUNCATED synthetic tree that the classifier and the
  # merger then trusted as the template. Any failure below is now a hard stop
  # naming the offending file, before anything is committed or tagged. The list
  # lives under $MAT (removed with it on success) rather than in TMPDIR, so an
  # aborted side leaves nothing outside the run's own state dir.
  # SYMLINKS ARE LISTED TOO (-type l). A plain `-type f` walk skipped every one of
  # them, so a template symlink was absent from BOTH synthetic sides: the
  # classifier saw no row for it, a retargeted link was silently dropped from the
  # migration, and structural-merge.sh's 120000-mode arm — written precisely to
  # refuse a symlink it cannot ride the blob write path — was unreachable. They are
  # installed as real symlinks below, so git records mode 120000 and that refusal
  # becomes reachable for the rows that actually changed. A silent skip is never
  # the answer here (see this file's failure-handling discipline throughout).
  local list="$MAT/.install-list-$side" rel arel dir link
  ( cd "$src" && find . \( -type f -o -type l \) -print ) > "$list" \
    || fail "could not list the materialized $side tree at $src"

  while IFS= read -r rel; do
    rel=${rel#./}
    case "$rel" in
      .git/*|.git) continue ;;
      # Template tooling, never part of a component. Upgrade-file discovery and
      # the placeholder registry read real template HISTORY from $CACHE, not
      # these trees, so dropping it here costs nothing and keeps the diff clean.
      .kairos-updates/*|.kairos-updates) continue ;;
    esac
    # ANCHORED before dirname, then de-anchored again for the `$SYNTH/$dir` join.
    # $rel comes from a find over the materialized TEMPLATE tree, so a template
    # carrying a leading-dash path hands dirname a bundle of options (it has no
    # portable `--`): dirname printed a usage error and returned EMPTY, and for a
    # leading-dash DIRECTORY the `mkdir -p "$SYNTH/"` that followed succeeded
    # vacuously — so the guard below never fired and the write failed instead,
    # aborting materialization with a message blaming the file rather than the
    # missing directory.
    case "$rel" in /*|./*) arel="$rel" ;; *) arel="./$rel" ;; esac
    dir=$(dirname "$arel"); dir=${dir#./}
    mkdir -p "$SYNTH/$dir" \
      || fail "could not create $SYNTH/$dir installing $rel ($side)"
    # A symlink is installed BY LINK TEXT, before any content probe: reading it as
    # a file would either follow it (installing the target's bytes at the link's
    # path, a silent content forgery) or, for a dangling link, fail and abort the
    # whole materialization over a file the template legitimately ships. The link
    # text is copied verbatim — no LF normalization and no module-path
    # substitution: it is a path, not file content, and rewriting it would
    # invent a link the template does not have.
    if [[ -L "$src/$rel" ]]; then
      link=$(readlink "$src/$rel") \
        || fail "could not read the symlink target of $rel ($side) — refusing to install it as a regular file, which would forge content at that path"
      [[ -n "$link" ]] \
        || fail "the symlink $rel ($side) reports an EMPTY target — refusing to install it, because an empty link text cannot be reproduced and a silent skip would drop the template's change to it"
      rm -f "$SYNTH/$rel"
      ln -s -- "$link" "$SYNTH/$rel" \
        || fail "could not install the symlink $rel -> $link into $SYNTH ($side)"
      continue
    fi
    if is_binary_file "$src/$rel"; then
      cp -p "$src/$rel" "$SYNTH/$rel" \
        || fail "could not install $rel into $SYNTH ($side)"
      continue
    fi
    if [[ "$subst" -eq 1 ]]; then
      # pipefail-scoped to this one pipe (the script relies on `||` chains, not a
      # global set -e): without it the pipeline reports only sed's status, so a
      # FAILED `tr` (short read, disk error) would let a truncated blob land under
      # a 0 exit — silent content loss on the branch that fires on essentially
      # every real migration. cf. clean-artifacts.sh / template-parity.sh.
      ( set -o pipefail
        tr -d '\r' < "$src/$rel" \
          | sed "s/$(esc_pat "$mat_module")/$(esc "$COMP_MODULE")/g" > "$SYNTH/$rel" ) \
        || fail "could not install $rel into $SYNTH ($side)"
    else
      tr -d '\r' < "$src/$rel" > "$SYNTH/$rel" \
        || fail "could not install $rel into $SYNTH ($side)"
    fi
    # Preserve only the execute bit; content came through a pipe.
    if [[ -x "$src/$rel" ]]; then
      chmod +x "$SYNTH/$rel" || fail "could not set the execute bit on $rel ($side)"
    fi
  done < "$list"
  rm -f "$list"

  # Surviving placeholder-shaped tokens. The CLI substitutes a known set inside
  # an extension whitelist; anything left matching <UPPER_SNAKE> is a token the
  # template uses but nothing replaces — upstream's bug, surfaced as feedback.
  ( cd "$SYNTH" && find . -type f -print ) | sed 's|^\./||' | while IFS= read -r rel; do
    case "$rel" in .git/*) continue ;; esac
    is_binary_file "$SYNTH/$rel" && continue
    # LC_ALL=C: the [A-Z] range and the dedupe order are both locale-dependent,
    # and a token list that changes with the operator's locale is not feedback.
    LC_ALL=C grep -oE '<[A-Z][A-Z0-9_]{2,}>' "$SYNTH/$rel" 2>/dev/null | LC_ALL=C sort -u \
      | while IFS= read -r tok; do
          printf '%s\t%s\t%s\n' "$side" "$rel" "$tok" >> "$RUN/surviving-tokens.tsv"
        done
  done

  # Checked, and with stderr left visible: an unchecked stage/commit/tag is how a
  # partial install reached the merge as if it were the template. --allow-empty
  # stays — an intentionally empty side (a template with no files at that SHA)
  # must stay representable, and emptiness caused by a write failure is now
  # unreachable because the write above aborts first.
  # -f, so an installed .gitignore (or any exclude source config cannot reach)
  # cannot keep a template file out of the commit — see the ignore/filter pinning
  # block up top for what that silently cost.
  git -C "$SYNTH" add -f -A >/dev/null \
    || fail "could not stage the materialized $side tree in $SYNTH"
  git -C "$SYNTH" commit -q --allow-empty -m "materialized template @ $side" >/dev/null \
    || fail "could not commit materialized $side tree"
  git -C "$SYNTH" tag -f "kairos-$side" >/dev/null \
    || fail "could not tag the materialized $side tree as kairos-$side"
  return 0
}

module_of() { awk '$1 == "module" { print $2; exit }' "$1/go.mod" 2>/dev/null || true; }

# Each side's own root go.mod is the authority — a template that changed its own
# module path between BASE and TARGET is corrected per-side, not once globally.
echo "INFO: materializing BASE ($BASE) via $KAIROS_BIN as component '$COMPONENT_NAME'" >&2
materialize_side "$BASE" base
BASE_TREE="$MAT_ABS/out-base/$COMPONENT_NAME"
BASE_MODULE=$(module_of "$BASE_TREE")
install_side "$BASE_TREE" base "$BASE_MODULE"

echo "INFO: materializing TARGET ($TARGET)" >&2
materialize_side "$TARGET" target
TARGET_TREE="$MAT_ABS/out-target/$COMPONENT_NAME"
TARGET_MODULE=$(module_of "$TARGET_TREE")
install_side "$TARGET_TREE" target "$TARGET_MODULE"

if [[ -n "$COMP_MODULE" ]] && [[ -n "$BASE_MODULE" ]] && [[ "$BASE_MODULE" != "$COMP_MODULE" ]]; then
  CORRECTIVE="$BASE_MODULE -> $COMP_MODULE (base), ${TARGET_MODULE:-?} -> $COMP_MODULE (target)"
fi

printf '%s' "$WANT_STAMP" > "$STAMP"

{
  echo "component_name:  $COMPONENT_NAME"
  echo "component_module: ${COMP_MODULE:-<no go.mod>}"
  echo "base_sha:        $BASE"
  echo "base_module:     ${BASE_MODULE:-<none>}"
  echo "target_sha:      $TARGET"
  echo "target_module:   ${TARGET_MODULE:-<none>}"
  echo "component_kind:  $COMPONENT_KIND ($( [ "$COMPONENT_KIND" = facade ] && echo 'kairos component facade create' || echo 'kairos component create'))"
  echo "cli:             $("$KAIROS_BIN" --version 2>/dev/null | tail -1)"
  if [[ -n "$CORRECTIVE" ]]; then
    echo "corrective_module_substitution: $CORRECTIVE"
  else
    echo "corrective_module_substitution: none (CLI convention matches the component)"
  fi
} > "$RUN/materialization.txt"

rm -rf "$MAT"

echo "OK: materialized base+target into $SYNTH" >&2
sed 's/^/  /' "$RUN/materialization.txt" >&2
if [[ -s "$RUN/surviving-tokens.tsv" ]]; then
  echo "WARN: placeholder-shaped tokens survived materialization (template feedback, not an error):" >&2
  cut -f3 "$RUN/surviving-tokens.tsv" | sort -u | sed 's/^/    /' >&2
  echo "    full list: $RUN/surviving-tokens.tsv" >&2
fi

record_context
echo "SYNTH=$SYNTH"
