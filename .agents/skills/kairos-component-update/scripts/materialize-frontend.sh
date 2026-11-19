#!/usr/bin/env bash
# materialize-frontend.sh — the FRONTEND arm of Phase 2.5. Produces the BASE and
# TARGET merge sides for a frontend run (RUN_SOURCE=frontend) and commits both
# into the same throwaway synthetic repo the template arm builds, so Phase 3
# (build-manifest.sh) and Phase 5 (structural-merge.sh) run bit-for-bit
# unchanged: same $SYNTH path, same kairos-base / kairos-target tags, same
# "a synthetic path IS a component path" invariant.
#
# WHY A SECOND SCRIPT AND NOT A FLAG ON materialize.sh: the two arms share a
# contract, not a mechanism. The template arm's mechanism is `kairos component
# create` — the command components are BORN from — and its whole point is that
# substitution parity is structural rather than maintained. A frontend run
# cannot use it:
#   * `component create` clones the frontend template at BRANCH HEAD, which is
#     neither this run's BASE nor its TARGET. There is no CLI invocation that
#     materializes the frontend subtree at an arbitrary SHA.
#   * dropping --no-frontend to get web/ would hand us HEAD anyway, plus an
#     interactive template picker and a network clone.
#   * a frontend run must not require the Kairos CLI at all (PRD story 32):
#     being blocked by a tool only the template arm needs is exactly the
#     failure this fork removes. git + coreutils only here — no KAIROS_BIN, no
#     CLI version probe.
# And the sides are NOT "plain git trees": `component create` copies the subtree
# verbatim and then walks the WHOLE component, web/ included, applying its
# content+filename replacement map. A component's mount therefore holds the
# component's own name where the subtree holds <YOUR_BC_NAME>. Merge sides that
# skipped that map would conflict on every substituted file (package.json, the
# vite config, index.html) — so both sides run the map through the ONE helper
# that owns it, scripts/lib/frontend-substitute.sh, which is pinned to the CLI's
# token lists by tests/materialize-frontend.test.sh's contract test. Never
# open-code a replacement here; that is the drift the template arm's header is
# a monument to.
#
# Env in:  PHASE_KEY       required — proof-of-load key stated in phases/2.5-materialize.md
#          RUN             migration state dir
#          BASE            baseline frontend SHA   (the anchor's BASE for this run)
#          TARGET          target frontend SHA     (the anchor's TARGET for this run)
#          MODULE          optional — the config.yaml module KEY (the manifest's
#                          `frontend.template`); default: that manifest value. Same
#                          name and same meaning as in bellwether-detect.sh.
#                          Selects which entry of the source repo's
#                          .kairos-updates/config.yaml supplies the subtree.
#          MODULE_PATH     module subtree inside the source repo (e.g. template/react).
#                          The FALLBACK, not the authority: this script resolves the
#                          subtree from the source's own config.yaml AT EACH SIDE's
#                          commit first (modules.<MODULE>.path), and falls back to this
#                          value — then to the manifest's `frontend.path`. Per side,
#                          because a module relocated INSIDE base..target sits at two
#                          different paths and a single resolution makes that range the
#                          one range that cannot adopt the relocation. Nothing about
#                          `react` is known here either way.
#          MOUNT           where that subtree lives in the component. Default: the
#                          manifest's `frontend.mount`, else `web/`.
#          COMPONENT_NAME  optional — default manifest `name:`, else cwd basename
#          FRONTEND_CACHE  optional — mirror clone of the frontend source repo.
#                          Default $RUN/frontend, which is where pre-flight check 8.6
#                          establishes it on a frontend run (and what it records on the
#                          anchor); created here when absent, for a caller that skipped
#                          pre-flight.
#          FRONTEND_PATH   optional — local checkout (already normalized to the git
#                          toplevel by pre-flight check 8.5); the clone origin.
#          FRONTEND_REPO   optional — upstream URL; the clone origin when no local
#                          checkout was given.
#          FORCE_MATERIALIZE  optional — set to ignore the reuse stamp
# Cwd:     component root
# Out (in $RUN):
#   synthetic/                git repo; tags kairos-base / kairos-target. Contains
#                             <mount>/** and NOTHING else — the frontend source is
#                             one subtree of the component, so every other component
#                             path is legitimately absent from both sides and the
#                             classifier sees no row for it.
#   materialization.txt       what was materialized (source, module, mount, SHAs; plus
#                             base_module_path when the module moved inside the range)
#   surviving-tokens.tsv      side <TAB> path <TAB> token — placeholder-shaped
#                             strings the replacement map did NOT substitute.
#                             Frontend-template feedback, NOT an error.
# Also records on the run-context anchor ($RUN/context.env): SYNTH, BASE, TARGET, and
# the RESOLVED FRONTEND_MODULE_PATH / FRONTEND_CACHE / FRONTEND_MOUNT — later phases
# (Phase 8's parity basis in particular) must read the subtree this run merged, not the
# possibly-stale one in the manifest.
# Stdout:  SYNTH=<path-to-synthetic-repo>
set -u

fail() { echo "FAIL: $*" >&2; exit 1; }

# Phase-load guard — the SAME key as materialize.sh: one phase file states it and
# owns both arms, so a run that loaded phases/2.5-materialize.md can take either.
[[ "${PHASE_KEY:-}" = "n41g1bxq" ]] || fail "load phases/2.5-materialize.md first"

for v in RUN BASE TARGET; do
  [[ -n "$(eval echo "\${$v:-}")" ]] || fail "$v not set"
done

HERE=$(cd "$(dirname "$0")" && pwd)

# The replacement map lives in exactly one place; sourcing it (rather than
# re-deriving it) is what the contract test can pin.
[[ -r "$HERE/lib/frontend-substitute.sh" ]] \
  || fail "missing $HERE/lib/frontend-substitute.sh — it owns the create-time replacement map; without it the merge sides would not be create-equivalent and every substituted file would conflict"
# shellcheck source=lib/frontend-substitute.sh
. "$HERE/lib/frontend-substitute.sh" \
  || fail "could not source $HERE/lib/frontend-substitute.sh"
command -v apply_create_substitution >/dev/null 2>&1 \
  || fail "lib/frontend-substitute.sh defined no apply_create_substitution — refusing to materialize raw (unsubstituted) frontend trees"

# The anchor write-back. SYNTH/BASE/TARGET are the template arm's three; the FRONTEND_*
# three are this script's own RESOLVED values, and recording them is what makes later
# phases read the subtree this run actually merged. Phase 8's parity basis used to take
# FRONTEND_MODULE_PATH straight off the manifest, so after an upstream relocation (which
# this script follows on purpose) parity compared the component against a DIFFERENT
# subtree than the merge used and reported the delta between two modules as component
# drift. FRONTEND_CACHE and FRONTEND_MOUNT ride along for the same reason: the mirror
# this run actually used, and the mount it actually mapped onto.
record_context() {
  RUN="$RUN" "$HERE/record-context.sh" "SYNTH=$SYNTH" "BASE=$BASE" "TARGET=$TARGET" \
    "FRONTEND_MODULE_PATH=$MODULE_PATH" "FRONTEND_CACHE=$FE_CACHE" "FRONTEND_MOUNT=$MOUNT/" \
    || fail "could not record run context in $RUN/context.env"
}

COMPONENT_NAME=${COMPONENT_NAME:-}
[[ -n "$COMPONENT_NAME" ]] || COMPONENT_NAME=$(yq -r '.name // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
[[ -n "$COMPONENT_NAME" ]] || COMPONENT_NAME=$(basename "$(pwd)")

# --- the mount ------------------------------------------------------------------
# (The module SUBTREE is resolved further down, once the mirror exists: its
# authority is the source repo's own config.yaml, which lives in that mirror.)
MOUNT=${MOUNT:-}
[[ -n "$MOUNT" ]] \
  || MOUNT=$(yq -r '.frontend.mount // "web/"' .kairos/manifest.yaml 2>/dev/null || echo "web/")
[[ -n "$MOUNT" ]] || MOUNT=web/
# One canonical form from here on: no trailing slash for path joins, and every
# rejected shape rejected LOUDLY. An absolute or dot-dot mount would place the
# synthetic side outside the component tree the classifier compares against, and
# `.git` as a mount would make the synthetic repo eat its own metadata.
MOUNT=${MOUNT%/}
case "$MOUNT" in
  ""|/*|*..*|.|./*|.git|.git/*) fail "MOUNT must be a relative path inside the component, not '.', '.git' or a path with '..' (got '${MOUNT:-<empty>}')" ;;
esac

# --- the frontend mirror -------------------------------------------------------
# Same shape as the template mirror at $RUN/template: a --mirror clone inside the
# run's own state dir, reused when it already mirrors the same origin. Addressed
# through a variable (never a literal "$RUN/frontend" write target) exactly as
# materialize.sh addresses $MAT.
FE_CACHE=${FRONTEND_CACHE:-$RUN/frontend}
FE_ORIGIN=${FRONTEND_PATH:-${FRONTEND_REPO:-}}

# Same normalization pre-flight check 7 uses (origins_match): a local origin given
# once as a relative --frontend-path and recorded once as an absolute path is the
# SAME repo, so a byte comparison would miss the match and re-clone the whole
# monorepo. Kept identical to pre-flight.sh's copy on purpose (no shared lib both
# scripts can source at this point in the run).
origins_match() { # origins_match <existing-origin> <new-origin>
  [[ "$1" = "$2" ]] && return 0
  local a b
  a=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  b=$(cd "$2" 2>/dev/null && pwd -P) || return 1
  [[ -n "$a" ]] && [[ "$a" = "$b" ]]
}

# CONTAINMENT for every `rm -rf "$FE_CACHE"` below. FRONTEND_CACHE is a
# caller-supplied env value (advertised in the header): pre-flight.sh ASSIGNS
# FRONTEND_CACHE=$RUN/frontend and ignores any inbound value, which is what makes
# its identical rm -rf unreachable on a foreign path — this script accepts the
# value, so it must contain the blast radius itself. A non-bare working checkout
# has no top-level HEAD, so passing a real checkout (or $PWD) would fall to the
# establish branch and rm -rf it. Destroy the path ONLY when it does not exist yet
# (rm is a no-op), lives under $RUN (this run's own scratch), or is a BARE git
# mirror (HEAD present AND core.bare=true — the only non-$RUN shape this tooling
# ever creates here); anything else is refused LOUDLY before a byte is removed.
require_replaceable_cache() { # require_replaceable_cache <path>
  local p="$1" abs run_abs
  [[ -e "$p" ]] || return 0                            # nothing there — rm -rf is a no-op
  abs=$(cd "$p" 2>/dev/null && pwd -P) || abs=""      # a file, or an unreadable dir
  run_abs=$(cd "$RUN" 2>/dev/null && pwd -P) || run_abs=""
  if [[ -n "$abs" ]] && [[ -n "$run_abs" ]]; then
    case "$abs/" in "$run_abs"/*) return 0 ;; esac    # under $RUN
  fi
  if [[ -f "$p/HEAD" ]] && [[ "$(git -C "$p" config --get core.bare 2>/dev/null)" = true ]]; then
    return 0                                          # a bare mirror this tooling created
  fi
  fail "refusing to 'rm -rf' the frontend mirror path '$p': it is neither under this run's state dir ($RUN) nor a bare git mirror (HEAD present and core.bare=true). FRONTEND_CACHE is a caller-supplied path; pointing it at a working checkout or any other directory would destroy it. Pass a path under \$RUN, an existing bare mirror, or leave FRONTEND_CACHE unset to use the default \$RUN/frontend."
}

if [[ -f "$FE_CACHE/HEAD" ]] && [[ -z "$FE_ORIGIN" ]]; then
  : # a mirror someone else established, and nothing to check it against — use it
elif [[ -f "$FE_CACHE/HEAD" ]]; then
  # Same rule as the template mirror's (pre-flight check 7): reuse only a mirror of
  # the SAME origin, and refresh it — a mirror left by an earlier run does not have
  # commits pushed since, and a stale mirror of a DIFFERENT origin would silently
  # serve another repo's commits under this run's SHAs. A failed refresh (corrupt
  # mirror, unreachable origin) falls back to a clean re-clone.
  FE_EXISTING=$(git -C "$FE_CACHE" config --get remote.origin.url 2>/dev/null || echo "")
  if origins_match "$FE_EXISTING" "$FE_ORIGIN" && git -C "$FE_CACHE" remote update --prune >/dev/null 2>&1; then
    echo "INFO: refreshed existing frontend mirror at $FE_CACHE" >&2
  else
    require_replaceable_cache "$FE_CACHE"
    rm -rf "$FE_CACHE"
    git clone --mirror "$FE_ORIGIN" "$FE_CACHE" >/dev/null 2>&1 \
      || fail "the frontend mirror at $FE_CACHE could not be refreshed against '$FE_ORIGIN' (it mirrors '${FE_EXISTING:-<unset>}') and re-cloning it failed"
  fi
elif [[ -n "$FE_ORIGIN" ]]; then
  require_replaceable_cache "$FE_CACHE"
  rm -rf "$FE_CACHE"
  git clone --mirror "$FE_ORIGIN" "$FE_CACHE" >/dev/null 2>&1 \
    || fail "unable to clone the frontend source $FE_ORIGIN into $FE_CACHE"
else
  fail "no frontend mirror at $FE_CACHE and no origin to clone from (FRONTEND_PATH / FRONTEND_REPO both empty). Pre-flight records the manifest's frontend.repo and any --frontend-path; one of them must reach this script."
fi
FE_CACHE_ABS=$(cd "$FE_CACHE" 2>/dev/null && pwd) \
  || fail "frontend mirror missing or unreadable: $FE_CACHE"
[[ -n "$FE_CACHE_ABS" ]] || fail "could not resolve the frontend mirror to an absolute path: $FE_CACHE"

# --- the module subtree, resolved against the SOURCE, PER SIDE ------------------
# Resolution order (PRD, "Source-repo config"): the source repo's own
# .kairos-updates/config.yaml AT THAT SIDE'S COMMIT — `modules.<MODULE>.path` — then the
# value the caller passed, then the component manifest's `frontend.path`.
#
# WHY the config outranks the manifest, and why this is not merely tidier: the subtree
# path is the SOURCE's fact, and the moment upstream RELOCATES a module every existing
# component's manifest is stale. A manifest-only resolution then fails at extraction
# ("module path is not a directory at the target commit"), which reads as a wrong SHA
# or a wrong module — the two things it is not. Reading it from the range instead
# follows the relocation for free, and a disagreement is reported rather than silently
# preferred.
#
# WHY PER SIDE and not "at TARGET, for both": a relocation that happened INSIDE
# BASE..TARGET is exactly the case a single resolution cannot express. Resolved only at
# TARGET, the new path is then demanded at BASE too — where the module still sat at the
# old one — and the run refuses with "module path is not a directory at the base
# commit". That made a relocated module PERMANENTLY unmigratable: the one range that
# carries the relocation is the only range that can adopt it. Each side is therefore
# resolved against ITS OWN commit, which is what the config at that commit means.
#
# TOLERANT BY DESIGN — no config.yaml, no module key, no entry for it, no yq: the
# passed/manifest value stands, and that is not an error. It is every source repo that
# does not self-describe (the component template, common), and it is the state a
# frontend run in an older frontend repo is in.
#
# Read the SAME way bellwether-detect.sh's tier 1 reads it, with the same names (CFG,
# MODULE, `modules[strenv(MOD)]`): one module, one resolution, two scripts that cannot
# drift into disagreeing about which subtree a component was built from.
CFG=.kairos-updates/config.yaml
MODULE=${MODULE:-}
[[ -n "$MODULE" ]] \
  || MODULE=$(yq -r '.frontend.template // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
MODULE_PATH=${MODULE_PATH:-}
[[ -n "$MODULE_PATH" ]] \
  || MODULE_PATH=$(yq -r '.frontend.path // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
MODULE_PATH=${MODULE_PATH%/}
# The DECLARED value's shape is checked before the config can override it: a caller (or
# a manifest) handing this script a path that escapes the source repo is a bug worth
# stopping even when the config would have replaced it — an override that quietly
# swallowed it would hide the bug until the day the config is absent.
# (An empty value matches none of these arms — absence is answered by the config read
# below, or by the hard stop after it.)
case "$MODULE_PATH" in
  /*|*..*|.|./*) fail "MODULE_PATH must be a relative path inside the source repo with no '..' segment (got '$MODULE_PATH')" ;;
esac
MODULE_PATH_DECL=$MODULE_PATH

# cfg_module_path <commit-ish> — the module's declared subtree AT that commit, or empty
# when the source does not self-describe there (no config, no such module, no yq).
cfg_module_path() {
  local sha="$1" out=""
  [[ -n "$MODULE" ]] || return 0
  command -v yq >/dev/null 2>&1 || return 0
  git -C "$FE_CACHE_ABS" cat-file -e "$sha:$CFG" 2>/dev/null || return 0
  out=$(git -C "$FE_CACHE_ABS" show "$sha:$CFG" 2>/dev/null \
          | MOD="$MODULE" yq -r '.modules[strenv(MOD)].path // ""' - 2>/dev/null || echo "")
  case "$out" in null) out="" ;; esac
  printf '%s' "${out%/}"
}

# resolve_side_path <commit-ish> <side-label> — that side's subtree, config first.
# It runs in a command substitution, so it must not call fail() (whose exit would only
# leave the subshell and let the run continue on an empty path): it returns non-zero and
# the CALLER stops the script.
resolve_side_path() {
  local sha="$1" side="$2" cfgp
  cfgp=$(cfg_module_path "$sha")
  # The shape check applies to the SOURCE's value too: a config that names an escaping
  # path is upstream's bug, and extracting through it would leave the source repo.
  case "$cfgp" in
    /*|*..*|.|./*)
      echo "FAIL: the frontend source's $CFG at the $side commit $sha puts module '$MODULE' at '$cfgp', which is not a relative path inside the source repo with no '..' segment" >&2
      return 1 ;;
  esac
  if [[ -n "$cfgp" ]]; then printf '%s' "$cfgp"; else printf '%s' "$MODULE_PATH_DECL"; fi
}

BASE_MODULE_PATH=$(resolve_side_path "$BASE" base) \
  || fail "could not resolve the module subtree for the base side (see the FAIL above)"
TARGET_MODULE_PATH=$(resolve_side_path "$TARGET" target) \
  || fail "could not resolve the module subtree for the target side (see the FAIL above)"
CFG_TARGET_PATH=$(cfg_module_path "$TARGET")
if [[ -n "$CFG_TARGET_PATH" ]]; then
  if [[ -n "$MODULE_PATH_DECL" ]] && [[ "$MODULE_PATH_DECL" != "$CFG_TARGET_PATH" ]]; then
    # The relocation case, said out loud: the config wins, and the user is told which
    # value lost, because the stale one is in a file (their manifest) that a later
    # phase — and the next migration — still reads.
    echo "WARN: the frontend source's $CFG at TARGET puts module '$MODULE' at '$CFG_TARGET_PATH', but this run was given '$MODULE_PATH_DECL' (component manifest frontend.path, or MODULE_PATH). Using the SOURCE's value '$CFG_TARGET_PATH' — it is the authority, and an upstream relocation makes every component's recorded path stale. Update .kairos/manifest.yaml's frontend.path to match." >&2
  else
    echo "INFO: module '$MODULE' subtree resolved from the source's $CFG at TARGET: $CFG_TARGET_PATH" >&2
  fi
fi
# The relocation that happened INSIDE the range. Both sides are still mapped onto the
# SAME mount, so the merge sees ordinary content changes (and the adds/deletes of files
# the two subtrees do not share) rather than a rename of the mount — say so, because the
# classification is otherwise an unexplained pile of adds and deletes.
if [[ "$BASE_MODULE_PATH" != "$TARGET_MODULE_PATH" ]]; then
  echo "WARN: module '$MODULE' MOVED inside this range — the source's $CFG puts it at '$BASE_MODULE_PATH' at BASE and '$TARGET_MODULE_PATH' at TARGET. Each side is materialized from its own path (that is what makes the relocation adoptable at all), and both land on the same mount '$MOUNT/', so the classification shows content changes plus adds/deletes for files the two subtrees do not share — not a rename of the mount." >&2
fi
# The canonical single value for the stamp, the report and the run-context anchor is the
# TARGET side's: it is the subtree the run is migrating TO, and the one every later phase
# (Phase 8's parity basis above all) has to compare the component against.
MODULE_PATH=$TARGET_MODULE_PATH
[[ -n "$BASE_MODULE_PATH" ]] && [[ -n "$MODULE_PATH" ]] \
  || fail "no module subtree could be resolved: the frontend source's $CFG declares no path for module '${MODULE:-<unset>}' at BASE and/or TARGET (or carries no such module), MODULE_PATH was not passed, and .kairos/manifest.yaml has no frontend.path. The module subtree is what IS the template — one of the three has to name it."

# --- the two SHAs, and the subtree at each of them -----------------------------
# Validated HERE, before any state is written: a bad SHA or a module path that
# does not exist at one side is a wrong RUN, not a recoverable hiccup, and the
# git-archive failure it would otherwise cause reads as a tooling error. Each side is
# checked against ITS OWN resolved path (see the per-side rationale above).
for side_sha in "base:$BASE:$BASE_MODULE_PATH" "target:$TARGET:$TARGET_MODULE_PATH"; do
  side=${side_sha%%:*}; rest=${side_sha#*:}; sha=${rest%%:*}; mpath=${rest#*:}
  git -C "$FE_CACHE_ABS" cat-file -e "$sha^{commit}" 2>/dev/null \
    || fail "$side SHA $sha does not resolve to a commit in the frontend mirror $FE_CACHE — check the frontend baseline/target this run was given"
  OBJ=$(git -C "$FE_CACHE_ABS" cat-file -t "$sha:$mpath" 2>/dev/null || echo "")
  [[ "$OBJ" = tree ]] \
    || fail "module path '$mpath' is not a directory at the $side commit $sha (got '${OBJ:-nothing}'). The module subtree IS the template: a run whose module path is absent at one side has the wrong module or the wrong SHA."
done

MAT="$RUN/mat-frontend"
SYNTH="$RUN/synthetic"
STAMP="$SYNTH/.materialize-stamp"
# Both resolved paths ride the stamp: a run whose BASE side comes from a different
# subtree than a previous run's is not the same materialization, however equal the SHAs.
WANT_STAMP="frontend $BASE $TARGET $COMPONENT_NAME $BASE_MODULE_PATH $MODULE_PATH $MOUNT"

# --- reuse guard ---------------------------------------------------------------
# Same contract as the template arm's: Continue mode re-enters mid-migration and
# must not rebuild the trees. The stamp carries the SOURCE too, so a chained
# frontend run can never mistake the template run's synthetic repo for its own.
if [[ -z "${FORCE_MATERIALIZE:-}" ]] && [[ -f "$STAMP" ]] && [[ -d "$SYNTH/.git" ]] \
   && [[ "$(cat "$STAMP")" = "$WANT_STAMP" ]] \
   && git -C "$SYNTH" rev-parse -q --verify kairos-base >/dev/null 2>&1 \
   && git -C "$SYNTH" rev-parse -q --verify kairos-target >/dev/null 2>&1; then
  echo "INFO: reusing materialized frontend trees in $SYNTH (stamp matches)" >&2
  record_context
  echo "SYNTH=$SYNTH"
  exit 0
fi

rm -rf "$MAT" "$SYNTH"
# CHECKED, and naming the run dir — the same guard and the same reason as the
# template arm: an unwritable $RUN used to let these mkdirs fail silently (set -u,
# no set -e), the absolute-path derivation below then resolved to the EMPTY string,
# and later operations targeted filesystem-root paths.
mkdir -p "$MAT" "$SYNTH" \
  || fail "could not create the per-run scratch dirs under $RUN (is $RUN writable?): $MAT and $SYNTH — refusing to continue, because the absolute-path derivation below would otherwise resolve to the empty string and later operations would target filesystem-root paths"
: > "$RUN/surviving-tokens.tsv" \
  || fail "could not initialize $RUN/surviving-tokens.tsv (is $RUN writable?)"
MAT_ABS=$(cd "$MAT" 2>/dev/null && pwd) \
  || fail "could not resolve the scratch dir to an absolute path: $MAT (is $RUN writable?)"
[[ -n "$MAT_ABS" ]] \
  || fail "resolved the scratch dir to an EMPTY absolute path: $MAT — refusing to build extraction paths against filesystem root"

# --- the synthetic repo -------------------------------------------------------
# Byte-for-byte the hygiene the template arm pins, and for the identical reasons
# (materialize.sh documents each one at length): a synthetic repo that honoured
# the operator's autocrlf/attributes/excludes/hooks config would hand the merge
# content neither side has, block on a pinentry prompt, or drop files from a side.
git -C "$SYNTH" init -q -b main >/dev/null 2>&1 || fail "could not init synthetic repo at $SYNTH"
git -C "$SYNTH" config user.name  "kairos-component-update" >/dev/null 2>&1
git -C "$SYNTH" config user.email "kairos-component-update@localhost" >/dev/null 2>&1
git -C "$SYNTH" config core.autocrlf false >/dev/null 2>&1
git -C "$SYNTH" config commit.gpgsign false >/dev/null 2>&1
git -C "$SYNTH" config tag.gpgSign false >/dev/null 2>&1
git -C "$SYNTH" config core.hooksPath /dev/null >/dev/null 2>&1
git -C "$SYNTH" config core.excludesFile /dev/null >/dev/null 2>&1
git -C "$SYNTH" config core.symlinks true >/dev/null 2>&1
printf '* -filter -text\n' > "$SYNTH/.git/info/attributes" \
  || fail "could not pin attribute handling off for the synthetic repo ($SYNTH/.git/info/attributes) — without it an installed .gitattributes plus an operator-global filter driver would rewrite every staged blob, and the merge would run against content neither frontend side has"

# NUL byte in the first 8KB → binary. (Deliberately NOT `grep -q $'\x00'` —
# shell arguments can't carry NUL, so that pattern silently becomes empty and
# matches everything.)
is_binary_file() {
  [[ -f "$1" ]] || return 1
  [[ "$(head -c 8192 "$1" | LC_ALL=C tr -d '\000' | wc -c)" -ne "$(head -c 8192 "$1" | wc -c)" ]]
}

# --- materialize one side ------------------------------------------------------
# `git archive <sha>:<module_path>` addresses the SUBTREE as a tree-ish, so the
# entries come out relative to the module root and land straight under the mount.
# Extracting the whole commit and pruning would be the same result three ways to
# get wrong. .kairos-updates/ sits at the source repo ROOT, outside the subtree,
# so it is structurally absent here — asserted below rather than assumed, because
# a repo that ever moved its upgrade-files INTO a module subtree would otherwise
# ship template tooling into a component's mount.
materialize_side() { # materialize_side <sha> <side-label> <module-path> -> $MAT_ABS/tree-<side>
  local sha="$1" side="$2" MODULE_PATH="$3"
  local tree="$MAT_ABS/tree-$side" tar="$MAT_ABS/$side.tar"

  rm -rf "$tree"
  mkdir -p "$tree/$MOUNT" || fail "could not create the extraction dir $tree/$MOUNT ($side)"
  # -o rather than a pipe: without pipefail a failed `git archive` into `tar -x`
  # is invisible, and an empty side then reads as "the frontend deleted
  # everything" — the most destructive possible misreading of a tooling failure.
  git -C "$FE_CACHE_ABS" archive --format=tar -o "$tar" "$sha:$MODULE_PATH" \
    || fail "could not archive $MODULE_PATH at $sha ($side) from the frontend mirror $FE_CACHE"
  tar -xf "$tar" -C "$tree/$MOUNT" \
    || fail "could not extract the $side module subtree into $tree/$MOUNT"
  rm -f "$tar"

  [[ -n "$(find "$tree/$MOUNT" \( -type f -o -type l \) -print -quit 2>/dev/null)" ]] \
    || fail "the module subtree '$MODULE_PATH' at the $side commit $sha extracted to an EMPTY tree. An empty side would classify the component's whole mount as removed upstream; refusing."

  local stowaway
  stowaway=$(find "$tree" -name .kairos-updates -print 2>/dev/null | head -1)
  [[ -z "$stowaway" ]] \
    || fail "the $side module subtree contains .kairos-updates ($stowaway). Upgrade-files live at the SOURCE REPO ROOT under the module name, outside the subtree the CLI copies into the mount — a subtree that carries them would install template tooling into the component."

  # Create-equivalence, through the one helper that owns the map. Applied to the
  # whole synthetic tree, which is what `component create` does (it walks the
  # created component, mount included) — here the tree IS the mount.
  apply_create_substitution "$tree" "$COMPONENT_NAME" \
    || fail "the create-time replacement map failed on the $side tree ($tree) — refusing to install an unsubstituted side, which would conflict against the component's mount on every substituted file"
}

# --- install a materialized tree into the synthetic repo ----------------------
# Text files are LF-normalized on the way in, so the BASE..TARGET diff is itself
# line-ending-proof. No module-path substitution arm here: the frontend module
# subtree carries no go.mod, and the CLI's bitbucket rewrite is already part of
# the replacement map applied above.
install_side() { # install_side <src-tree> <side-label> <that-side's-module-path>
  # The third arg exists for the relocation case: when the module moved inside the
  # range, each side's synthetic commit must name the path IT was extracted from —
  # labeling the base side with the target's path records a fact that is simply
  # false about that commit. Metadata only (the tree is per-side regardless), but
  # the commit message is exactly what someone debugging a relocation reads.
  local src="$1" side="$2" side_module_path="$3"

  # Clear the working tree (keep .git and the stamp) so a deletion between BASE
  # and TARGET shows up as a deletion in the synthetic diff. Checked, like the
  # template arm's: a partial clear would let the other side's files ride into
  # this side's tree and silently corrupt the classification diff.
  CLEAR_ERR=$(find "$SYNTH" -mindepth 1 -maxdepth 1 \
    ! -name .git ! -name "$(basename "$STAMP")" -exec rm -rf {} + 2>&1)
  CLEAR_RC=$?
  [[ "$CLEAR_RC" -eq 0 ]] || fail "could not clear $SYNTH before installing the $side side (exit $CLEAR_RC): $CLEAR_ERR — a partial clear would let the other side's already-installed files ride into this side's tree and corrupt the classification diff. Nothing for $side was installed."

  # The install list is materialized to a file so the copy loop runs in THIS
  # shell: in a `find | while` subshell a failed mkdir or a short write is
  # invisible and its status lost, so a full disk produces a TRUNCATED side that
  # the classifier and the merger then trust. Symlinks are listed too (-type l),
  # so a link the template ships is present on both sides and the merger's
  # 120000-mode refusal stays reachable.
  local list="$MAT/.install-list-$side" rel arel dir link
  ( cd "$src" && find . \( -type f -o -type l \) -print ) > "$list" \
    || fail "could not list the materialized $side tree at $src"

  while IFS= read -r rel; do
    rel=${rel#./}
    case "$rel" in
      .git/*|.git) continue ;;
    esac
    # ANCHORED before dirname, then de-anchored again for the join: a
    # leading-dash path hands dirname a bundle of options (it has no portable
    # `--`), and the usage error that follows is blamed on the file rather than
    # on the missing directory.
    case "$rel" in /*|./*) arel="$rel" ;; *) arel="./$rel" ;; esac
    dir=$(dirname "$arel"); dir=${dir#./}
    mkdir -p "$SYNTH/$dir" \
      || fail "could not create $SYNTH/$dir installing $rel ($side)"
    # A symlink is installed BY LINK TEXT, before any content probe: reading it
    # as a file would either follow it (forging the target's bytes at the link's
    # path) or, for a dangling link, abort materialization over a file the
    # template legitimately ships. Link text is a path, not content — no LF
    # normalization.
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
    tr -d '\r' < "$src/$rel" > "$SYNTH/$rel" \
      || fail "could not install $rel into $SYNTH ($side)"
    # Preserve only the execute bit; content came through a pipe.
    if [[ -x "$src/$rel" ]]; then
      chmod +x "$SYNTH/$rel" || fail "could not set the execute bit on $rel ($side)"
    fi
  done < "$list"
  rm -f "$list"

  # Surviving placeholder-shaped tokens — the frontend template's author's bug,
  # surfaced as Phase 8 feedback exactly as the template arm surfaces the CLI's.
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

  # Checked, and with stderr visible: an unchecked stage/commit/tag is how a
  # partial install reaches the merge as if it were the template. -f, so an
  # installed .gitignore cannot keep a mount file out of the commit.
  git -C "$SYNTH" add -f -A >/dev/null \
    || fail "could not stage the materialized $side tree in $SYNTH"
  git -C "$SYNTH" commit -q --allow-empty -m "materialized frontend module $side_module_path @ $side" >/dev/null \
    || fail "could not commit materialized $side tree"
  git -C "$SYNTH" tag -f "kairos-$side" >/dev/null \
    || fail "could not tag the materialized $side tree as kairos-$side"
  return 0
}

echo "INFO: materializing frontend BASE ($BASE) — module $BASE_MODULE_PATH onto $MOUNT/ as component '$COMPONENT_NAME'" >&2
materialize_side "$BASE" base "$BASE_MODULE_PATH"
install_side "$MAT_ABS/tree-base" base "$BASE_MODULE_PATH"

echo "INFO: materializing frontend TARGET ($TARGET) — module $TARGET_MODULE_PATH" >&2
materialize_side "$TARGET" target "$TARGET_MODULE_PATH"
install_side "$MAT_ABS/tree-target" target "$TARGET_MODULE_PATH"

printf '%s' "$WANT_STAMP" > "$STAMP"

{
  echo "source:          frontend"
  echo "component_name:  $COMPONENT_NAME"
  echo "module_path:     $MODULE_PATH"
  [[ "$BASE_MODULE_PATH" = "$MODULE_PATH" ]] \
    || echo "base_module_path: $BASE_MODULE_PATH  (the module moved inside this range)"
  echo "mount:           $MOUNT/"
  echo "base_sha:        $BASE"
  echo "target_sha:      $TARGET"
  echo "frontend_mirror: $FE_CACHE"
  echo "substitution:    create-equivalent (scripts/lib/frontend-substitute.sh)"
  echo "cli:             none — a frontend run requires no Kairos CLI"
  echo "corrective_module_substitution: none (frontend run — the module subtree carries no go.mod)"
} > "$RUN/materialization.txt"

rm -rf "$MAT"

echo "OK: materialized frontend base+target into $SYNTH" >&2
sed 's/^/  /' "$RUN/materialization.txt" >&2
if [[ -s "$RUN/surviving-tokens.tsv" ]]; then
  echo "WARN: placeholder-shaped tokens survived materialization (frontend-template feedback, not an error):" >&2
  cut -f3 "$RUN/surviving-tokens.tsv" | sort -u | sed 's/^/    /' >&2
  echo "    full list: $RUN/surviving-tokens.tsv" >&2
fi

record_context
echo "SYNTH=$SYNTH"
