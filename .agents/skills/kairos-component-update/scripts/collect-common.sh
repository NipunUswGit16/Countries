#!/usr/bin/env bash
# collect-common.sh — resolve per-module BASE/TARGET versions for the
# kairos-component-common libraries a component consumes, and collect their
# consumer-facing upgrade-files over each module's version range.
#
# Common is a DEPENDENCY, never merged into the component: the only artifact is
# the upgrade-files, fed into the SAME planner/executor pipeline as template
# upgrade-files. Per module, BASE is the version in the component's go.mod and
# TARGET is the version the template pins at the migration target — so a version
# the component has already advanced past is naturally outside the range and no
# "already handled" bookkeeping is needed.
#
# WHY the co-dev resolution paths exist: a template author co-developing common
# pinned it by pseudo-version and carried branch-only upgrade-files that tag-based
# resolution could never find; the run collected nothing and no one noticed. Three
# resolution improvements close that gap: a pseudo-version resolves via its embedded
# commit when the commit is in the mirror (only genuinely-unpushed work stays
# unresolvable, and its detail names the commit); a per-module REF_OVERRIDES input
# makes the batched "provide a ref" answer mechanically actionable; and a local
# common clone with a dirty .kairos-updates/ tree warns, since commit-based
# collection cannot see uncommitted files. The batched unresolvable prompt remains
# the single funnel for what none of these resolve.
#
# Env in:
#   PHASE_KEY         required — proof-of-load key stated in phases/3.5-collect-common.md
#   RUN               output dir (required)
#   COMPONENT_GOMOD   component's go.mod (default: go.mod) — the source of BASE
#                     versions, read the way go resolves them: a `replace` wins
#                     over the `require` on BOTH sides of the range (see
#                     effective_version), so a component pinned by replace is not
#                     measured against a require it does not build with.
#   TEMPLATE_GOMOD    template's go.mod at the migration TARGET (required) —
#                     the source of TARGET versions. Verified present, readable and
#                     parseable before any module is resolved: absent or shapeless,
#                     it is a hard error, never "the template pins nothing".
#   COMMON_REPO_PATH  module-path prefix identifying common modules (required),
#                     e.g. bitbucket.org/ifs-pd/kairos-component-common
#   COMMON_CACHE      mirror clone of the common repo, tags fetched (required for
#                     collection; optional for resolution-only)
#   TEMPLATE_GOMOD_DIR  dir the template go.mod lives in, for resolving relative
#                     local-path replace directives (optional)
#   REF_OVERRIDES     optional TSV (module <TAB> ref): for a listed module the
#                     range endpoint is that ref resolved in COMMON_CACHE, decision
#                     collect. Makes the batched "provide a ref" answer actionable —
#                     write the override, re-run — instead of hand-collection.
#                     SET BUT UNREADABLE IS A HARD ERROR, never a silent ignore:
#                     this file IS the operator's answer to the batched prompt, and
#                     a typo'd path used to make that answer vanish and the module
#                     report the unrelated diagnostic it had before answering.
# Out (in $RUN):
#   common-resolution.tsv          module <TAB> base <TAB> target <TAB> tag_prefix
#                                  <TAB> dir <TAB> decision <TAB> detail <TAB> repo
#     decision ∈ collect | skip-downgrade | skip-absent-target | skip-no-cache | unresolvable
#       skip-no-cache: a resolvable range but COMMON_CACHE is unset, so there is no
#       mirror to collect from — recorded as a skip (never collect-with-empty-repo,
#       never unresolvable) so the tally is honest and no batched prompt fires.
#     repo is the git dir a collect row is collected from (COMMON_CACHE, or the
#     local clone for a local-path replace).
#   common-unresolvable.txt        module <TAB> detail, for each unresolvable module —
#                                  batched for the orchestrator to surface (skip / ref / abort)
#   common-upgrades-added.txt      collected upgrade-file identities, per-module commit order,
#                                  at their FINAL (post-rename) path within the range, carrying
#                                  RAW path bytes (every collection walk reads -z; a TAB/newline
#                                  in a name is a hard stop naming the file, never a silent drop)
#   common-upgrades-added.tsv      add-sha <TAB> module <TAB> path (source/module provenance)
#   common-upgrades-modified.txt   upgrade-files that existed before BASE and were amended
#                                  (not (re)discovered as an add) within the range
#   upgrades/<basename>.md         each collected/modified file's BODY, read from its newest
#                                  add or amend commit — never the tip — with any in-range
#                                  rename resolved to the identity's final path (see NOTE below)
#                                  (shared with template collection; same dir the planner reads)
#   common-legacy-upgrade-commits.txt  legacy root-UPGRADE.md commits, ceiling-gated, deduped
set -u

fail() { echo "FAIL: $*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)

# Phase-load guard: this key is stated ONLY in phases/3.5-collect-common.md, so an
# orchestrator that skipped loading that file cannot know it. The guard turns a
# skipped load into a stop instead of a phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "9059z5gm" ]] || fail "load phases/3.5-collect-common.md first"

# Disjointness self-guard — the mirror of clone-common.sh's frontend guard and of
# collect-lib.sh's RUN_SOURCE guard. Common collection belongs to a TEMPLATE run;
# lib is its inverse and owns the frontend arm. The two RUN_SOURCEs are disjoint and
# one $RUN ledger only ever holds one of them, so on a frontend run common has nothing
# to do — no-op rather than resolve common modules a frontend migration never consumes,
# or hard-fail on a missing TEMPLATE_GOMOD it was never going to use. Bare read before
# the required-var loop: RUN_SOURCE unset or an absent anchor means template (pre-flight's
# default), and RUN unset falls through to the loop below, which names it.
if [[ -n "${RUN:-}" ]] && [[ -f "$RUN/context.env" ]] \
   && [[ "$(sed -n 's/^RUN_SOURCE=//p' "$RUN/context.env" | tail -1 | tr -d '\r')" = frontend ]]; then
  echo "INFO: frontend run (RUN_SOURCE=frontend on the anchor) — collect-common.sh runs only on a template run: nothing resolved or collected, no COMMON_* artifact written." >&2
  exit 0
fi

for v in RUN TEMPLATE_GOMOD COMMON_REPO_PATH; do
  [[ -n "${!v:-}" ]] || fail "$v not set"
done
COMPONENT_GOMOD="${COMPONENT_GOMOD:-go.mod}"
COMMON_CACHE="${COMMON_CACHE:-}"
REF_OVERRIDES="${REF_OVERRIDES:-}"
# TEMPLATE_GOMOD_DIR is deliberately NOT defaulted here: its default is
# `cd $(dirname "$TEMPLATE_GOMOD")`, which on a bad TEMPLATE_GOMOD printed a raw
# shell `cd: no such file or directory` line BEFORE the guard that explains what is
# actually wrong — the operator read the shell's complaint about a directory instead
# of the message naming the input. It is computed after the input guards below, and
# only there.
mkdir -p "$RUN"

# The user's answer to the batched "provide a ref" prompt, per module (empty when
# none). First match wins.
#
# The file's readability is NOT tested here — it is a hard error at the input guard
# below. The old `[ -f … ] || return 0` treated a set-but-missing path as "no
# overrides at all", so a typo'd REF_OVERRIDES silently discarded the operator's
# whole answer and every listed module reported the same diagnostic it had reported
# before they answered — an unresolvable module that looked stuck no matter what
# they wrote. By the time this runs, REF_OVERRIDES is either empty or a readable file.
#
# The trailing CR strip is for the same reason record-context.sh:68 refuses one: a
# CRLF-authored override yields the ref `codev<CR>`, which git cannot resolve, and
# the resulting "ref override 'codev' not found in common mirror" names a ref that
# looks exactly right on screen. Refusing is not an option here (the value is a
# per-row field of an operator-authored TSV, not a single recorded key), so the CR
# is stripped where it can only have arrived from the line ending.
ref_override_for() { # ref_override_for <module>
  [[ -n "$REF_OVERRIDES" ]] || return 0
  awk -F'\t' -v m="$1" '$1==m{sub(/\r$/, "", $2); print $2; exit}' "$REF_OVERRIDES"
}

for tool in go yq; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "required tool '$tool' not found on PATH."
done

# Co-dev range endpoints resolve against a LOCAL clone that may be BEHIND its
# remote — a BASE pin released upstream after the clone last fetched would be
# absent and the range would land unresolvable for a stale-clone reason alone.
# fetch_local_clone (best-effort, non-destructive) closes that gap. Sourced up
# here, before the resolution loop that calls collect_local_range.
[[ -r "$HERE/lib/fetch-local-clone.sh" ]] \
  || fail "missing $HERE/lib/fetch-local-clone.sh — it owns fetch_local_clone"
# shellcheck source=lib/fetch-local-clone.sh
. "$HERE/lib/fetch-local-clone.sh" \
  || fail "could not source $HERE/lib/fetch-local-clone.sh"

# --- version helpers ---------------------------------------------------------
# is $1 >= $2 ?  (semver, both with a leading v)
# Pre-release aware: semver says v1.2.3-rc1 PRECEDES v1.2.3, but `sort -V`
# orders the suffixed form AFTER the release — which declared a component
# pinned at an rc "at/ahead of" the release and silently skipped its range.
# So bases are compared with sort -V, and on equal bases the un-suffixed
# release wins; two pre-releases of one base fall back to sort -V between
# themselves. Go pseudo-versions never reach this: is_pseudo routes them to
# the commit-ancestry check first.
semver_ge() {
  [[ "$1" = "$2" ]] && return 0
  local a="$1" b="$2" abase bbase
  abase=${a%%-*}
  bbase=${b%%-*}
  if [[ "$abase" != "$bbase" ]]; then
    [[ "$(printf '%s\n%s\n' "$abase" "$bbase" | sort -V | tail -1)" = "$abase" ]]
  elif [[ "$a" = "$abase" ]]; then
    return 0   # a is the release, b (differing) is a pre-release of it
  elif [[ "$b" = "$bbase" ]]; then
    return 1   # b is the release, a is a pre-release of it
  else
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]]
  fi
}

# is $1 > $2 ?  (strictly greater)
semver_gt() { [[ "$1" != "$2" ]] && semver_ge "$1" "$2"; }

# A pseudo-version (…<sep><14-digit-timestamp>-<12-hex-commit>) has no released
# tag, but it EMBEDS the exact commit it was cut from — so its range endpoint
# resolves to that commit when the commit is present in the repo being collected
# from. Go emits three forms and the separator before the timestamp differs:
#   vX.0.0-<ts>-<sha>          no release tag on the module at all
#   vX.Y.Z-pre.0.<ts>-<sha>    base is a pre-release
#   vX.Y.(Z+1)-0.<ts>-<sha>    base is a release
# Every common module carries release tags, so the DOT forms are the ones a real
# co-dev pin uses; matching only the dash form sent them down the tag path, where
# they failed tag_exists and landed 'unresolvable' with a missing-tag detail
# naming the wrong remedy. Hence [-.] for the separator.
is_pseudo() { printf '%s' "$1" | grep -qE -- '[-.][0-9]{14}-[0-9a-f]{12}$'; }
# The 12-hex commit a pseudo-version embeds (empty for a non-pseudo version).
pseudo_commit() { printf '%s' "$1" | grep -oE -- '[-.][0-9]{14}-[0-9a-f]{12}$' | grep -oE -- '[0-9a-f]{12}$'; }

# Map a go.mod version (or a bare sha already stored for a local-path/override
# row) to the git ref that bounds a module's range: a pseudo-version's embedded
# commit, a released version's <module>/<tag>, or a literal sha as-is. Used by
# BOTH resolution (to verify the endpoint exists) and collection (to walk it), so
# the two never disagree on what a range endpoint means.
range_ref() { # range_ref <module> <version-or-sha>
  local mod="$1" v="$2" c
  c=$(pseudo_commit "$v")
  if [[ -n "$c" ]]; then printf '%s' "$c"
  else case "$v" in v*) printf '%s/%s' "$mod" "$v" ;; *) printf '%s' "$v" ;; esac
  fi
}

# Does ref $2 resolve to a commit in repo $1?
ref_exists_in() { git -C "$1" rev-parse -q --verify "$2^{commit}" >/dev/null 2>&1; }

# semver can't order a commit-bounded (pseudo-version) range, so the semver_ge
# downgrade check below never sees these. Fall back to commit ancestry in the
# mirror: if TARGET's commit is an ancestor of BASE's (and they differ), the
# component is already at or ahead of the target — a downgrade/no-op, not a
# collect. Both endpoints are known present (missing_endpoint ran first).
range_is_downgrade() { # range_is_downgrade <module> <base> <target>
  local lo hi
  lo=$(git -C "$COMMON_CACHE" rev-parse -q --verify "$(range_ref "$1" "$2")^{commit}" 2>/dev/null) || return 1
  hi=$(git -C "$COMMON_CACHE" rev-parse -q --verify "$(range_ref "$1" "$3")^{commit}" 2>/dev/null) || return 1
  [[ "$lo" != "$hi" ]] && git -C "$COMMON_CACHE" merge-base --is-ancestor "$hi" "$lo" 2>/dev/null
}

# Permanent per-module legacy ceiling — the one-time boundary where structured
# .kairos-updates/ files took over from the frozen root UPGRADE.md. Fixed
# constants (see PRD): UPGRADE.md is frozen and everything beyond the ceiling is
# owned by structured upgrade-files, so these are NEVER recomputed at runtime.
ceiling_for() {
  case "$1" in
    api)           echo v1.2.26 ;;
    common)        echo v1.3.23 ;;
    event-handler) echo v1.2.38 ;;
    toolkit)       echo v1.0.38 ;;
    *)             echo "" ;;
  esac
}

# Does <tag> ($2) resolve to a commit in the given repo ($1)?
tag_exists_in() { git -C "$1" rev-parse -q --verify "refs/tags/$2^{commit}" >/dev/null 2>&1; }
# Same, against the mirror clone (the common case).
tag_exists() { tag_exists_in "$COMMON_CACHE" "$1"; }

# Verify both endpoints of a module's range resolve in $COMMON_CACHE. Echoes a
# human description of the FIRST unresolvable endpoint (empty when both resolve):
# a pseudo-version's commit that's ABSENT (unpushed work) is named so the user
# knows to push or pick another ref; a missing released tag keeps its prior wording.
missing_endpoint() { # missing_endpoint <module> <base-version> <target-version>
  local mod="$1" v c which
  for which in base:"$2" target:"$3"; do
    v=${which#*:}
    if is_pseudo "$v"; then
      c=$(pseudo_commit "$v")
      ref_exists_in "$COMMON_CACHE" "$c" \
        || { echo "pseudo-version $v commit $c absent from common repo (unpushed?) — push it or name a released ref"; return; }
    else
      tag_exists "$mod/$v" || { echo "missing tag $mod/$v in common repo"; return; }
    fi
  done
}

# --- go.mod parsing ----------------------------------------------------------
# `go mod edit -json` validates and normalizes; real go.mod files always parse.
#
# A require row is SPACE-joined and read with the default IFS, which is safe by
# construction: both fields are go-validated (a module path may contain no space
# and no tab, and a version is `vX.Y.Z…`). A REPLACE row cannot be: its New.Path is
# a module path OR A FILESYSTEM PATH, and a local-path replace target with a space
# in it is legal go.mod (quoted: `=> "../My Code/common"`) and routine on macOS.
# Space-joined, that row shifted every field right — the `-` marking "no version"
# landed nowhere, the LOCAL: arm was never entered, and the module resolved to a
# nonsense TARGET, went out as `skip-downgrade`, and dropped every one of its
# upgrade-files at exit 0. So replace rows are TAB-delimited and read with
# IFS=$'\t': a tab cannot appear in a module path or a version, and the one place
# it COULD appear (a filesystem replace target) is refused by name at the input
# guard rather than silently misread. The two version fields are emptiness-marked
# "-" because a tab is IFS-whitespace to `read`, which collapses an empty middle
# field and shifts the very fields this projection exists to keep aligned.
gomod_requires() { go mod edit -json "$1" | yq -p=json -r '.Require[]? | .Path + " " + .Version'; }
gomod_replaces() {
  go mod edit -json "$1" \
    | yq -p=json -r '.Replace[]? | [.Old.Path, (.Old.Version // "-"), .New.Path, (.New.Version // "-")] | @tsv'
}

# The version a `require` line pins for a module path ("" when it pins none).
require_version() { # require_version <gomod> <module-path>
  local p v
  while read -r p v; do
    [[ "$p" = "$2" ]] && { printf '%s' "$v"; return 0; }
  done < <(gomod_requires "$1")
  printf ''
}

# The version a go.mod EFFECTIVELY resolves a module to — what it actually builds
# against, which is what a migration range endpoint has to mean. A `replace` wins
# over the `require`, exactly as the go tool resolves it.
#
# REPLACE APPLICABILITY, previously ignored on both sides: an UNQUALIFIED replace
# (`replace M => …`) applies to whatever version is required, but a
# VERSION-QUALIFIED one (`replace M v1.2.0 => …`) applies ONLY when the required
# version is EXACTLY v1.2.0 — otherwise it is inert and the require stands. Honoring
# a qualified replace unconditionally moved the endpoint for requires the replace
# never named, and `replace M v1.2.0 => M v1.2.5` (pinning past one bad release) is
# precisely that shape, so the wrong endpoint was the ordinary case, not an exotic
# one. When both forms name the same module, the qualified one wins for its version
# (go's own precedence), which is why the loop collects both and decides after.
#
# Emits "LOCAL:<dir>" for a filesystem-path replace target, the replaced version,
# the required version when no replace applies, or "" when neither pins the module.
effective_version() { # effective_version <gomod> <module-path> <required-version>
  local file="$1" path="$2" req="$3" old oldver new newver
  local qnew="" qver="" unew="" uver="" have_q="" have_u=""
  while IFS=$'\t' read -r old oldver new newver; do
    [[ "$old" = "$path" ]] || continue
    if [[ "$oldver" = "-" ]]; then
      [[ -n "$have_u" ]] || { have_u=1; unew="$new"; uver="$newver"; }
    elif [[ "$oldver" = "$req" ]]; then
      [[ -n "$have_q" ]] || { have_q=1; qnew="$new"; qver="$newver"; }
    fi
  done < <(gomod_replaces "$file")
  if [[ -n "$have_q" ]]; then new="$qnew"; newver="$qver"
  elif [[ -n "$have_u" ]]; then new="$unew"; newver="$uver"
  else printf '%s' "$req"; return 0
  fi
  case "$newver" in
    -) printf 'LOCAL:%s' "$new" ;;
    *) printf '%s' "$newver" ;;
  esac
}

# TARGET version for a module path, honoring a replace directive over require.
# Emits the resolved version, or "" when the template does not pin the module.
target_version() { # target_version <module-path>
  effective_version "$TEMPLATE_GOMOD" "$1" "$(require_version "$TEMPLATE_GOMOD" "$1")"
}

# --- input guard -------------------------------------------------------------
# Replace rows are read POSITIONALLY, so a row that does not project to exactly
# four fields is not a parse error — it is a SHIFT, and the shift is silent: the
# "-" that marks "no version" lands in the wrong column, the LOCAL: arm is skipped,
# and the module goes out with a nonsense endpoint and an empty collection at exit
# 0. Module paths and versions cannot carry a TAB or a newline (go validates both),
# but a local-path replace TARGET is a filesystem path and can carry either, so the
# shape is verified rather than assumed and a name that cannot ride the projection
# is refused BY NAME — the same call the collection walks make for a TAB in an
# upgrade-file name. Runs at the top level (not inside the command-substituted
# resolver, where an `exit` would kill only the subshell and let the run finish OK).
check_replaces_shape() { # check_replaces_shape <label> <gomod>
  local bad
  bad=$(gomod_replaces "$2" | awk -F'\t' '
    NF != 4 || ($2 != "-" && $2 !~ /^v/) || ($4 != "-" && $4 !~ /^v/) { print; exit }')
  [[ -z "$bad" ]] && return 0
  fail "$1 go.mod carries a replace directive this phase cannot read: $2
      row: $(printf '%s' "$bad" | tr '\t' ' ')
      It does not project to (old-path, old-version, new-path, new-version). A TAB or
      a newline in a local-path replace TARGET is the only way to produce this, and no
      quoting scheme makes such a path readable field-by-field — misreading it would
      silently drop every upgrade-file of the replaced module.
      Remedy: point the replace at a path with no TAB or newline in it, and re-run."
}

# The resolution loop is driven by `gomod_requires "$COMPONENT_GOMOD"`, and a
# process-substitution read loop over a failing command is an EMPTY loop: a
# missing go.mod — or a python-flavored yq that rejects `-p=json` — produced zero
# rows, an empty resolution tsv and a green "OK", silently dropping every common
# migration. Both are hard errors naming the path instead. pipefail is scoped to
# the probe (the pipeline's own status is yq's, which succeeds on empty input).
# Each shape gets its own sentence: "not readable" sent an operator who had pointed
# at a DIRECTORY off to check permissions.
[[ -e "$COMPONENT_GOMOD" ]] || fail "component go.mod not found: $COMPONENT_GOMOD"
[[ -d "$COMPONENT_GOMOD" ]] && fail "component go.mod is a directory, not a file: $COMPONENT_GOMOD — COMPONENT_GOMOD names the go.mod itself"
[[ -f "$COMPONENT_GOMOD" ]] && [[ -r "$COMPONENT_GOMOD" ]] \
  || fail "component go.mod not readable: $COMPONENT_GOMOD"
( set -o pipefail; gomod_requires "$COMPONENT_GOMOD" >/dev/null 2>&1 ) \
  || fail "cannot read requires from component go.mod: $COMPONENT_GOMOD (check it parses and that 'yq' is the mikefarah build)"
# The component's REPLACE directives are read too (BASE honors them, see
# effective_version), so the same fail-open applies to them: a failing projection
# would be an empty replace loop, i.e. "this component replaces nothing", and BASE
# would fall back to a require the component does not build with.
( set -o pipefail; gomod_replaces "$COMPONENT_GOMOD" >/dev/null 2>&1 ) \
  || fail "cannot read replaces from component go.mod: $COMPONENT_GOMOD (check it parses and that 'yq' is the mikefarah build)"
check_replaces_shape component "$COMPONENT_GOMOD"

# The SAME fail-open on the other input, and a worse one: every module's TARGET
# comes from the template go.mod via target_version, whose two read loops are
# process substitutions too. An absent, unreadable or unparseable template go.mod
# therefore resolved EVERY module to an empty target — recorded as
# skip-absent-target "template does not pin <module>", exit 0, a plausible tally —
# and the whole common-library side of the migration vanished without a word. So
# the template go.mod is verified present, readable, shaped like a go.mod and
# parseable BEFORE any module is resolved. The shape test exists because an EMPTY
# go.mod parses fine and is indistinguishable from "pins nothing", which is exactly
# the silent skip being closed (extract-template-gomod.sh refuses the same file at
# install time, one step earlier).
[[ -e "$TEMPLATE_GOMOD" ]] \
  || fail "template go.mod not found: $TEMPLATE_GOMOD (Phase 3.5 writes it with scripts/extract-template-gomod.sh)"
[[ -d "$TEMPLATE_GOMOD" ]] \
  && fail "template go.mod is a directory, not a file: $TEMPLATE_GOMOD — TEMPLATE_GOMOD names the go.mod itself, not the directory holding it"
[[ -f "$TEMPLATE_GOMOD" ]] && [[ -r "$TEMPLATE_GOMOD" ]] \
  || fail "template go.mod not readable: $TEMPLATE_GOMOD (Phase 3.5 writes it with scripts/extract-template-gomod.sh)"

# SHAPE VALIDATION IS GO'S, not a grep of our own. The old probe was
# `grep -qE '^module[[:space:]]+…'`, which is STRICTER than the parser that actually
# reads this file: a `module` line indented by a tab (go accepts it) was reported as
# "carries no 'module' line", and a UTF-8 BOM — which go rejects with a precise
# "unexpected input character '\ufeff'" — was reported the same way, sending the
# operator to look for a missing line that is right there. So `go mod edit -json`
# decides, and its own message is relayed. The empty-go.mod case that this guard
# exists for still lands: go parses an empty file happily and reports an EMPTY
# Module.Path, which is the check below.
if ! TPL_JSON=$(go mod edit -json "$TEMPLATE_GOMOD" 2>&1); then
  fail "cannot parse template go.mod: $TEMPLATE_GOMOD — go reports: $(printf '%s' "$TPL_JSON" | tr '\n' ' ')"
fi
TPL_MODULE=$(printf '%s\n' "$TPL_JSON" | yq -p=json -r '.Module.Path // ""') \
  || fail "cannot read the parsed template go.mod through 'yq': $TEMPLATE_GOMOD (check 'yq' is the mikefarah build — a python-flavored yq rejects -p=json)"
[[ -n "$TPL_MODULE" ]] \
  || fail "template go.mod carries no 'module' line: $TEMPLATE_GOMOD — refusing to resolve TARGET versions from it (every module would resolve to 'template does not pin')"
( set -o pipefail; gomod_replaces "$TEMPLATE_GOMOD" >/dev/null 2>&1 ) \
  || fail "cannot read replaces from template go.mod: $TEMPLATE_GOMOD (check it parses and that 'yq' is the mikefarah build)"
check_replaces_shape template "$TEMPLATE_GOMOD"

# REF_OVERRIDES is the operator's ANSWER to the batched unresolvable prompt, so a
# path that is set but unusable is the one thing it must never be read as "no answer
# given": the run then repeats the same per-module diagnostics the operator was
# answering, with nothing on screen pointing at the file they actually wrote. Each
# shape gets its own sentence for the same reason the go.mod guards do — "not
# readable" sent an operator who had pointed at a DIRECTORY off to check permissions.
if [[ -n "$REF_OVERRIDES" ]]; then
  [[ -e "$REF_OVERRIDES" ]] \
    || fail "REF_OVERRIDES not found: $REF_OVERRIDES — it is set, so it is an answer to the batched unresolvable prompt; refusing to run as if no overrides were given (expected a TSV of 'module<TAB>ref' lines)"
  [[ -d "$REF_OVERRIDES" ]] \
    && fail "REF_OVERRIDES is a directory, not a file: $REF_OVERRIDES — it names the TSV of 'module<TAB>ref' lines itself"
  [[ -f "$REF_OVERRIDES" ]] && [[ -r "$REF_OVERRIDES" ]] \
    || fail "REF_OVERRIDES not readable: $REF_OVERRIDES — refusing to run as if no overrides were given"
fi

# Safe now that the file is known good (see the note where the other defaults are
# set): resolving relative local-path replaces needs the directory it lives in.
TEMPLATE_GOMOD_DIR="${TEMPLATE_GOMOD_DIR:-$(cd "$(dirname "$TEMPLATE_GOMOD")" 2>/dev/null && pwd)}"
# The component's OWN local-path replaces (consumer-side co-development) resolve
# relative to the component go.mod's dir, not the template's — the mirror of the
# line above for the other side of the range.
COMPONENT_GOMOD_DIR="$(cd "$(dirname "$COMPONENT_GOMOD")" 2>/dev/null && pwd)"

# --- resolve each common module the component uses ---------------------------
# columns: module base target tag_prefix dir decision detail repo
: > "$RUN/common-resolution.tsv"
emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$RUN/common-resolution.tsv"; }

# Resolve a co-dev module against a LOCAL common clone: collect its upgrade-files
# over <base>..local-HEAD, reading COMMITTED history only. Shared by the two arms
# that reach a local clone from opposite sides of the range — the TEMPLATE
# co-develops common (its go.mod's replace makes TARGET a local dir, BASE the
# component's effective version) or the COMPONENT itself co-develops it (its own
# go.mod replaces common with a local dir, BASE the surviving `require` pin). Both
# collect from the same committed history the same way, so the resolution lives in
# one place and the two arms cannot drift. Emits exactly one common-resolution row.
#   $1 module   $2 base (version/pseudo bounding the FROM end, resolved via range_ref
#               so a released tag and a pseudo-version's embedded commit both work)
#   $3 local_abs (already-resolved clone dir)   $4 dir (.kairos-updates/<module>/)
#   $5 kind (human label for this replace, used verbatim in the row detail)
# A dry-run against unreleased HEAD always applies, so the semver no-downgrade rule
# does not gate it — HEAD is by definition ahead of any released BASE.
collect_local_range() { # collect_local_range <module> <base> <local_abs> <dir> <kind>
  local module="$1" base="$2" local_abs="$3" dir="$4" kind="$5" repo head_sha
  if [[ -d "$local_abs" ]] && repo=$(git -C "$local_abs" rev-parse --show-toplevel 2>/dev/null); then
    # Bring the clone current with its remote before bounding the range against it:
    # a BASE pin released upstream after this clone last fetched would otherwise be
    # absent and the module would land unresolvable for a stale-clone reason alone.
    # Best-effort and non-destructive (tags/remote-tracking only, never HEAD or the
    # working tree); deduped so multiple modules on one clone fetch once. See
    # lib/fetch-local-clone.sh.
    fetch_local_clone "$repo" "co-dev common clone for module '$module'"
    head_sha=$(git -C "$repo" rev-parse --short HEAD)
    # Collection reads COMMITTED history only; a dirty/untracked .kairos-updates/
    # tree in the clone is invisible — warn (non-fatal) so the author commits first.
    if [[ -n "$(git -C "$repo" status --porcelain -- "$dir" 2>/dev/null)" ]]; then
      echo "WARNING: local common clone $repo has uncommitted changes under $dir — commit-based collection cannot see them for module '$module'. Commit them before migrating." >&2
    fi
    # The range is base..HEAD, so the clone must be able to RESOLVE base — otherwise
    # `git log base..HEAD` silently resolves to nothing and the migration is dropped
    # without a word. Through range_ref (like every other endpoint) so a pseudo-version
    # base resolves via its embedded commit rather than a tag name that never exists.
    if ref_exists_in "$repo" "$(range_ref "$module" "$base")"; then
      emit "$module" "$base" "$head_sha" "$module" "$dir" collect "$kind -> $local_abs" "$repo"
    else
      emit "$module" "$base" "$head_sha" "$module" "$dir" unresolvable "$kind $local_abs cannot resolve BASE $base (looked for '$(range_ref "$module" "$base")') — cannot bound the range" "$repo"
    fi
  else
    emit "$module" "$base" "" "$module" "$dir" unresolvable "$kind is not a git repo: $local_abs" ""
  fi
}

while read -r path base_req; do
  case "$path" in
    "$COMMON_REPO_PATH"/*) ;;
    *) continue ;;
  esac
  module=${path#"$COMMON_REPO_PATH"/}
  dir=".kairos-updates/$module/"

  # BASE is what the component EFFECTIVELY builds against, not merely what its
  # `require` line says — the same replace-over-require resolution the TARGET side
  # has always used (asymmetric before: only the template's replaces were honored).
  # Reading the require alone was wrong in BOTH directions, and both were silent:
  # a component replaced UP past the target was collected as if it were behind, so
  # upgrade-files it had already adopted were served again; a component replaced
  # DOWN below the target came out `skip-downgrade`, dropping every migration that
  # genuinely applied to it.
  base=$(effective_version "$COMPONENT_GOMOD" "$path" "$base_req")

  # Co-development on the CONSUMER side: the component's own go.mod replaces this
  # module with a local directory. This is the exact mirror of the template-side
  # local-path arm below, and it collects the same way: the replace says only WHERE
  # to read the newer upgrade-files (the local clone's committed history, TARGET =
  # its HEAD), never the range's lower bound. BASE is NOT the LOCAL: path — it is the
  # surviving `require` pin ($base_req), the released version the component migrates
  # FROM. `effective_version` returns LOCAL: because a replace wins over require for
  # BUILDING, but the require line stays in go.mod and is a real endpoint, so a
  # co-developed common is collected instead of dropped. Decided BEFORE the
  # ref-override lookup on purpose: an override supplies the TARGET end of a range, so
  # it could never bound this FROM end anyway. $base_req is guaranteed set here — this
  # loop iterates `require` lines, so every module it reaches has one — which is why
  # this arm always collects rather than testing for a missing FROM end. A module
  # replaced to a local dir with NO `require` line never reaches this loop at all; that
  # orphan is caught after the loop (see the post-loop scan) so it is never dropped.
  case "$base" in
    LOCAL:*)
      newpath=${base#LOCAL:}
      case "$newpath" in
        /*) local_abs="$newpath" ;;
        *)  local_abs="$COMPONENT_GOMOD_DIR/$newpath" ;;
      esac
      collect_local_range "$module" "$base_req" "$local_abs" "$dir" "component go.mod local-path replace"
      continue
      ;;
  esac

  # A ref-override (the user's answer to the batched "provide a ref" prompt) wins
  # over template resolution: collect the module's range against that ref, resolved
  # to a commit in the mirror cache. TARGET becomes the resolved sha, so collection
  # walks BASE..sha exactly as it would a released tag.
  ovr=$(ref_override_for "$module")
  if [[ -n "$ovr" ]]; then
    if [[ -z "$COMMON_CACHE" ]] || ! sha=$(git -C "$COMMON_CACHE" rev-parse -q --verify --short "$ovr^{commit}" 2>/dev/null); then
      emit "$module" "$base" "" "$module" "$dir" unresolvable "ref override '$ovr' not found in common mirror" "$COMMON_CACHE"
    elif ! ref_exists_in "$COMMON_CACHE" "$(range_ref "$module" "$base")"; then
      emit "$module" "$base" "$sha" "$module" "$dir" unresolvable "ref override '$ovr' set, but BASE $base is absent from common repo — cannot bound the range" "$COMMON_CACHE"
    else
      emit "$module" "$base" "$sha" "$module" "$dir" collect "ref override '$ovr' -> $sha" "$COMMON_CACHE"
    fi
    continue
  fi

  target=$(target_version "$path")

  # local-path replace: TARGET is the local clone's HEAD (co-developing template +
  # common), and that same local clone is where the upgrade-files are collected from.
  # Resolution (dirty-tree warning, BASE-must-resolve, no-downgrade) lives in
  # collect_local_range, shared with the consumer-side arm above; here BASE is the
  # component's effective version and the clone is found via the template go.mod dir.
  case "$target" in
    LOCAL:*)
      newpath=${target#LOCAL:}
      case "$newpath" in
        /*) local_abs="$newpath" ;;
        *)  local_abs="$TEMPLATE_GOMOD_DIR/$newpath" ;;
      esac
      collect_local_range "$module" "$base" "$local_abs" "$dir" "local-path replace"
      continue
      ;;
  esac

  if [[ -z "$target" ]]; then
    emit "$module" "$base" "" "$module" "$dir" skip-absent-target "template does not pin $path" ""
  elif is_pseudo "$base" || is_pseudo "$target"; then
    # Pseudo-version pins embed the exact commit — resolve to it rather than
    # declaring the whole range unresolvable. Only a commit absent from the mirror
    # (genuinely unpushed) stays unresolvable, and its detail names the commit.
    if [[ -z "$COMMON_CACHE" ]]; then
      # No mirror to collect against: this is the resolution-only / no-cache mode
      # the skill's Phase 1 promises "degrades to a clean skip". Do NOT mark it
      # unresolvable — that would fire the batched user prompt for a module we were
      # never going to collect. Skip it honestly instead.
      emit "$module" "$base" "$target" "$module" "$dir" skip-no-cache "pseudo-version pin $base..$target and no COMMON_CACHE mirror to resolve/collect against" ""
    elif miss=$(missing_endpoint "$module" "$base" "$target"); [[ -n "$miss" ]]; then
      emit "$module" "$base" "$target" "$module" "$dir" unresolvable "$miss" "$COMMON_CACHE"
    elif range_is_downgrade "$module" "$base" "$target"; then
      emit "$module" "$base" "$target" "$module" "$dir" skip-downgrade "component $base at/ahead of target $target (commit ancestry)" "$COMMON_CACHE"
    else
      emit "$module" "$base" "$target" "$module" "$dir" collect "pseudo-version resolved via embedded commit" "$COMMON_CACHE"
    fi
  elif semver_ge "$base" "$target"; then
    emit "$module" "$base" "$target" "$module" "$dir" skip-downgrade "component $base >= template $target" "$COMMON_CACHE"
  elif [[ -n "$COMMON_CACHE" ]] && ! tag_exists "$module/$base"; then
    emit "$module" "$base" "$target" "$module" "$dir" unresolvable "missing tag $module/$base in common repo" "$COMMON_CACHE"
  elif [[ -n "$COMMON_CACHE" ]] && ! tag_exists "$module/$target"; then
    emit "$module" "$base" "$target" "$module" "$dir" unresolvable "missing tag $module/$target in common repo" "$COMMON_CACHE"
  elif [[ -z "$COMMON_CACHE" ]]; then
    # A collectable range but no mirror to collect it from (resolution-only mode).
    # Recording `collect` here would lie: the collection loop skips a row with an
    # empty repo column, so it would report collect for a module nothing collected.
    # Skip honestly — the skill's Phase 1 "unset cache degrades to a clean skip".
    emit "$module" "$base" "$target" "$module" "$dir" skip-no-cache "would collect $module/$base..$module/$target but no COMMON_CACHE mirror is set" ""
  else
    emit "$module" "$base" "$target" "$module" "$dir" collect "" "$COMMON_CACHE"
  fi
done < <(gomod_requires "$COMPONENT_GOMOD")

# Orphan local-path replaces: a common module the component `replace`s with a local
# directory but never `require`s. The resolution loop above iterates `require` lines,
# so such a module is invisible to it — and a co-developed common that is only
# replaced, never required, would have its upgrade-files silently dropped, the exact
# failure the local-path arms exist to prevent. Catch every orphan here. It has no
# `require` pin to bound the FROM end, so it cannot be a range and lands unresolvable
# with the remedy named — never a fabricated endpoint, never a silent drop. `go mod
# tidy` normally writes a placeholder `require` (a zero pseudo-version), which DOES
# reach the loop and lands unresolvable there via collect_local_range; this closes the
# hand-written, un-tidied gap. Only UNQUALIFIED local replaces (Old.Version "-") count:
# a version-qualified replace with no matching require is inert (go ignores it), so it
# co-develops nothing and must not be surfaced.
required_paths=$(gomod_requires "$COMPONENT_GOMOD" | awk '{print $1}')
while IFS=$'\t' read -r old oldver new newver; do
  case "$old" in "$COMMON_REPO_PATH"/*) ;; *) continue ;; esac
  [[ "$oldver" = "-" ]] && [[ "$newver" = "-" ]] || continue      # unqualified local-path replace only
  printf '%s\n' "$required_paths" | grep -qxF "$old" && continue   # required → already handled by the loop
  module=${old#"$COMMON_REPO_PATH"/}
  dir=".kairos-updates/$module/"
  emit "$module" "LOCAL:$new" "" "$module" "$dir" unresolvable \
    "component go.mod replaces $old with local directory $new but has no 'require' line to bound the range from (add a 'require $old <version>' naming the release the co-dev migrates from, or skip this module)" ""
done < <(gomod_replaces "$COMPONENT_GOMOD")

# Batch every unresolvable module (odd pin, missing tag, unresolvable replace) so
# the orchestrator can surface them per module — skip / provide-ref / abort —
# before the expensive collection work, rather than silently dropping a migration.
awk -F'\t' '$6=="unresolvable"{print $1"\t"$7}' "$RUN/common-resolution.tsv" \
  > "$RUN/common-unresolvable.txt"

# --- collect each collect-module's upgrade-files over its version range -------
# Per module, walk <module>/BASE..<module>/TARGET (or ..local-HEAD) path-filtered
# to .kairos-updates/<module>/. Because every module shares one linear history,
# the per-module path filter is what prevents cross-module contamination: a file
# authored for `common` never lands in `api`'s range. Bodies are read from each
# file's newest add/amend commit (never the tip) — authors prune already-shipped
# files, so a pruned-at-tip file is still fully recovered from history. Mirrors
# the template upgrade-file discovery in build-manifest.sh, with source/module
# provenance added.
#
# NOTE: collection is "latest state within range", not add-only — exactly one
# identity per upgrade-file, at its newest path, carrying its newest body, in its
# original apply slot:
#   - Discovery runs with --no-renames, so an in-range rename surfaces as a plain
#     D(old)+A(new) pair instead of the R git would otherwise hide from
#     --diff-filter=A. A rename-map pass (--diff-filter=R -M, same range and
#     pathspec) then rewrites any entry recorded against the pre-rename path onto
#     the file's FINAL path, transitively through rename chains, before ordering
#     and dedupe — so a drafted-then-renamed file is served once, under its final
#     slug, in the apply slot it earned when first added.
#   - A --diff-filter=M pass (mirroring build-manifest.sh's upgrades-modified.txt
#     mechanism) unconditionally overrides the add-pass body snapshot with the
#     newest amending commit's content, rename-rewritten the same way. Files
#     amended in range that were NOT (re)discovered as an add — added before
#     BASE, or amended under a pre-rename name — land in
#     common-upgrades-modified.txt instead of common-upgrades-added.txt.
# This is what makes drafting, amending and renaming an upgrade-file on a
# co-development branch (a local-path replace or a REF_OVERRIDES ref, whose
# range walks raw, unsquashed branch history) reach the planner with the body
# and identity the file has on that branch, not its first draft. It is also a
# no-op on tag-bounded, append-only history: merged upgrade-files never churn, so
# the R/M passes find nothing and released collection is byte-identical to
# before this NOTE was rewritten.
# The collection output files are TRUNCATED fail-closed, not blindly. An
# unwritable $RUN (a permission change, ENOSPC, a $RUN that is not the dir it was
# on the resolution pass) used to fail the `: >` silently and leave the PREVIOUS
# run's stale list in place — then read downstream as this run's complete upgrade
# set, the exact "partial list read as complete" failure the resolution stage and
# the badnames refusal already defend against, but on the collection side. Every
# truncation's status is checked and a failure names the file. mkdir is checked
# for the same class: a pre-existing non-directory at $RUN/upgrades would swallow
# every snapshot body with no word.
mkdir -p "$RUN/upgrades" \
  || fail "cannot create the snapshot dir $RUN/upgrades — is $RUN writable and is there no non-directory in the way?"
: > "$RUN/common-upgrades-added.txt" \
  || fail "cannot truncate $RUN/common-upgrades-added.txt — refusing to collect over a stale list (is $RUN writable?)"
: > "$RUN/common-upgrades-added.tsv" \
  || fail "cannot truncate $RUN/common-upgrades-added.tsv — refusing to collect over a stale list (is $RUN writable?)"
: > "$RUN/common-upgrades-modified.txt" \
  || fail "cannot truncate $RUN/common-upgrades-modified.txt — refusing to collect over a stale list (is $RUN writable?)"
# The supersede edge file is this collector's OWN artifact (never shared with
# build-manifest.sh / collect-lib.sh), so a plain checked truncate is safe — a
# Phase 3 redo cannot clobber another source's rows the way a shared file would.
: > "$RUN/common-supersede-edges.tsv" \
  || fail "cannot truncate $RUN/common-supersede-edges.tsv — refusing to collect over a stale edge file (is $RUN writable?)"

# Snapshots land in the SHARED $RUN/upgrades/ dir keyed by BASENAME only (the
# same dir build-manifest.sh writes template snapshots into), so two DIFFERENT
# upgrade-files that happen to share a basename would silently overwrite each
# other and one body would vanish before the planner ever saw it. Every write
# goes through snap_upgrade, which records basename -> source in a sidecar and
# WARNs (never fails — the newest write still wins, matching the intentional
# modified-pass body override) when a basename is re-written from a DIFFERENT
# source with different content. Same-source overwrites (an amend of the same
# file) stay silent by design.
SNAP_SOURCES="$RUN/upgrade-snapshot-sources.tsv"

# Re-run idempotence, shared-file variant: build-manifest.sh truncates this
# sidecar at its Phase 3 write, this script appends to it in Phase 3.5. So we
# must NOT truncate (that would discard Phase 3's template rows) and must not
# just append (a re-run would accumulate duplicate rows and make the collision
# WARN fire against our own previous run). Drop only OUR rows — source id
# "<module>:.kairos-updates/…", which no template row can match since a template
# source id IS a path and carries no module prefix.
if [[ -f "$SNAP_SOURCES" ]]; then
  # CHECKED stage by stage, like build-manifest.sh's SNAP_REFUSALS prune: under
  # `set -u` alone the old `mktemp && awk && mv` chain just SHORT-CIRCUITED, so a
  # failed stage silently SKIPPED the prune (this run's own stale rows survived and
  # made the basename-collision WARN fire against our own predecessor) AND leaked the
  # temp. On any failure the temp is removed and the run stops.
  snaptmp=$(mktemp "${TMPDIR:-/tmp}/snap-sources.XXXXXX") \
    || fail "could not create a temp file to prune $SNAP_SOURCES"
  # The ^[^:]+:\.kairos-updates/ shape is shared by common and lib and is safe
  # only because their RUN_SOURCEs are disjoint (one $RUN ledger only ever holds
  # one of the two).
  if ! awk -F'\t' '$2 !~ /^[^:]+:\.kairos-updates\//' "$SNAP_SOURCES" > "$snaptmp"; then
    rm -f "$snaptmp"
    fail "could not prune this run's own rows from $SNAP_SOURCES — a stale source row left here makes the basename-collision WARN fire against our own previous run."
  fi
  mv "$snaptmp" "$SNAP_SOURCES" \
    || { rm -f "$snaptmp"; fail "could not replace $SNAP_SOURCES with its pruned copy — check that $RUN is writable."; }
fi

# Same shared-file dance for the refusal ledger: build-manifest.sh truncates it at
# its Phase 3 write, we append ours and drop only our own rows on a re-run. Our
# rows are the ones whose SOURCE id is module-prefixed ("<module>:.kairos-updates/…"),
# which no template row can be — a template source id IS a path.
SNAP_REFUSALS="$RUN/snapshot-refusals.tsv"
if [[ -f "$SNAP_REFUSALS" ]]; then
  # Same checked prune as SNAP_SOURCES above: a stale refusal row left here makes
  # next-upgrade-file.sh answer exit 5 ("refused; re-running is not the remedy") for a
  # slug this run never refused — the very stale loop dropping our own rows exists to clear.
  reftmp=$(mktemp "${TMPDIR:-/tmp}/snap-refusals.XXXXXX") \
    || fail "could not create a temp file to prune $SNAP_REFUSALS"
  # The ^[^:]+:\.kairos-updates/ shape is shared by common and lib and is safe
  # only because their RUN_SOURCEs are disjoint (one $RUN ledger only ever holds
  # one of the two).
  if ! awk -F'\t' '$2 !~ /^[^:]+:\.kairos-updates\//' "$SNAP_REFUSALS" > "$reftmp"; then
    rm -f "$reftmp"
    fail "could not prune this run's own rows from $SNAP_REFUSALS — a stale refusal row left here makes next-upgrade-file.sh answer exit 5 for a slug this run never refused."
  fi
  mv "$reftmp" "$SNAP_REFUSALS" \
    || { rm -f "$reftmp"; fail "could not replace $SNAP_REFUSALS with its pruned copy — check that $RUN is writable."; }
else
  : > "$SNAP_REFUSALS" \
    || fail "could not create $SNAP_REFUSALS — check that $RUN is writable."
fi

#
# READ-FAILURE vs EMPTY-BODY lives in scripts/lib/snap-upgrade.sh (story 42).
# RAW PATH BYTES / -z parsing lives in scripts/lib/z-log-name-only.sh. The
# walks below are unchanged; only the helper definitions moved out.
[[ -r "$HERE/lib/snap-upgrade.sh" ]] \
  || fail "missing $HERE/lib/snap-upgrade.sh — it owns snap_upgrade (story 42)"
[[ -r "$HERE/lib/z-log-name-only.sh" ]] \
  || fail "missing $HERE/lib/z-log-name-only.sh — it owns z_log_name_only (story 42)"
# shellcheck source=lib/snap-upgrade.sh
. "$HERE/lib/snap-upgrade.sh" \
  || fail "could not source $HERE/lib/snap-upgrade.sh"
# shellcheck source=lib/z-log-name-only.sh
. "$HERE/lib/z-log-name-only.sh" \
  || fail "could not source $HERE/lib/z-log-name-only.sh"
[[ -r "$HERE/lib/supersede-edges.sh" ]] \
  || fail "missing $HERE/lib/supersede-edges.sh — it owns supersede_emit"
# shellcheck source=lib/supersede-edges.sh
. "$HERE/lib/supersede-edges.sh" \
  || fail "could not source $HERE/lib/supersede-edges.sh"

# RAW PATH BYTES on every collection walk, via -z. `core.quotepath=off` is NOT
# enough and never was: it governs bytes >= 0x80 only, so an upgrade-file named
# `we"ird.md` or `back\slash.md` still arrived C-quoted from `git log --name-only`
# ('".kairos-updates/api/we\"ird.md"'), failed the `index($0, d) == 1` prefix
# filter on every walk below — add pass, modified-list pass, modified body-override
# pass, and the rename map that feeds all three — and VANISHED. Nothing in
# common-upgrades-added.txt, nothing in snapshot-refusals.tsv, no WARN, exit 0: a
# migration step the common library SHIPS, silently skipped, with no downstream
# consumer able to tell. These are legal filenames, and `-z` emits them verbatim
# (quotepath cannot apply), so they are COLLECTED, not refused.
TABCH=$'\t'
NLCH=$'\n'

# The rename walk's twin: `--name-status -z` emits <status>\0<old>\0<new>\0 per
# rename, with the same EMPTY record between commits (skipped by the status
# guard, which is why the guard reads before the paths are consumed).
z_rename_pairs() { # z_rename_pairs <badfile>   (stream on stdin, rows on stdout)
  local bad="$1" st p1 p2
  while IFS= read -r -d '' st; do
    [[ -n "$st" ]] || continue
    case "$st" in R*) ;; *) continue ;; esac
    IFS= read -r -d '' p1 || break
    IFS= read -r -d '' p2 || break
    case "$p1$p2" in
      *"$TABCH"*|*"$NLCH"*)
        printf '%q\n' "$p1" >> "$bad"
        printf '%q\n' "$p2" >> "$bad"
        continue ;;
    esac
    printf '%s\t%s\n' "$p1" "$p2"
  done
}

# TAB and NEWLINE are the hard stop, mirroring build-manifest.sh: a name carrying
# either cannot ride common-upgrades-added.txt (a line list) or
# common-upgrades-added.tsv (a TAB-delimited line record), and no quoting scheme
# makes it representable. Both collection loops are `awk … | while … done`
# pipelines, i.e. SUBSHELLS — an `exit` inside one kills only the subshell and
# lets the run finish "OK" — so the converters only ACCUMULATE here and every
# refusal fires from the top level after the loop that produced it.
CC_BAD="$RUN/.common-upgrades-badnames.txt"
: > "$CC_BAD" || fail "cannot truncate $CC_BAD — is $RUN writable?"

# A FAILED WALK IS A REFUSAL, never an empty result — the same discipline
# build-manifest.sh's upg_refuse_walk applies to the template-side git walks.
# Each collection git-log below writes to a temp and its EXIT STATUS is checked:
# a mirror that cannot be read (a pruned/corrupt object, a $repo that does not
# carry $lo..$hi, a partial clone) used to end in `2>/dev/null … || true` — an
# EMPTY common-upgrades-added.txt and exit 0, every migration step the common
# library ships silently skipped, strictly worse than a loud refusal. Because the
# collection loops are `awk … | while … done` SUBSHELLS (an `exit` there kills
# only the subshell), a failed walk ACCUMULATES a "module<TAB>stage" row here and
# the refusal fires from the top level after the loop — exactly like the badnames
# refusal above. git's own stderr is NOT redirected on these walks: its
# "fatal: …" line is the diagnosis, and cc_refuse_walk names which module/stage
# it belongs to.
CC_WALKFAIL="$RUN/.common-walk-failures.txt"
: > "$CC_WALKFAIL" || fail "cannot truncate $CC_WALKFAIL — is $RUN writable?"
cc_refuse_walk() {
  [[ -s "$CC_WALKFAIL" ]] || return 0
  # Whatever the loops collected before/around the failed walk is a PARTIAL list,
  # and a partial list read as complete is the very failure this refusal prevents.
  # Same teardown as the badnames refusal.
  : > "$RUN/common-upgrades-added.txt"
  : > "$RUN/common-upgrades-added.tsv"
  : > "$RUN/common-upgrades-modified.txt"
  echo "FAIL: a common-library upgrade-file walk failed — refusing to report a partial upgrade set:" >&2
  while IFS="$TABCH" read -r m stage; do
    echo "        $m: $stage" >&2
  done < "$CC_WALKFAIL"
  echo "      That walk is how this phase discovers the migration steps a common" >&2
  echo "      library ships, so continuing would report an EMPTY or PARTIAL upgrade-file" >&2
  echo "      set as success and skip those steps silently (see git's error above)." >&2
  echo "      Remedy: repair the common mirror (re-fetch \$COMMON_CACHE or the local" >&2
  echo "      clone), or correct the module's BASE/TARGET, then re-run this phase." >&2
  exit 1
}
cc_refuse_badnames() {
  [[ -s "$CC_BAD" ]] || return 0
  # Whatever the loops managed to collect before the offending name is a PARTIAL
  # list, and a partial list read as a complete one is the very failure this
  # refusal exists to prevent. Drop all three.
  : > "$RUN/common-upgrades-added.txt"
  : > "$RUN/common-upgrades-added.tsv"
  : > "$RUN/common-upgrades-modified.txt"
  echo "FAIL: the common repo carries upgrade-file name(s) this migration cannot represent:" >&2
  sed 's/^/        /' "$CC_BAD" >&2
  echo "      A TAB or a newline in a filename cannot ride \$RUN/common-upgrades-added.txt" >&2
  echo "      (a line list) or \$RUN/common-upgrades-added.tsv (a TAB-delimited line record)," >&2
  echo "      and dropping it silently would skip a migration step the common library ships." >&2
  echo "      Nothing in this phase can work around the name, so repeating the phase cannot" >&2
  echo "      clear this." >&2
  echo "      Remedy: rename the upgrade-file in kairos-component-common to drop the" >&2
  echo "      TAB/newline, release it, and re-run this phase." >&2
  exit 1
}

# A module's in-range rename map: "<old-path>\t<final-path>" pairs, transitively
# resolved through rename chains (old -> mid -> final all resolve to final), over
# the SAME range and pathspec as discovery below — so a rename elsewhere in the
# common repo, or in another module's directory, can never leak in. Reused by
# both the add-pass and the modify-pass so an entry recorded against a pre-rename
# path always lands on the same final identity in either list.
rename_map_for() { # rename_map_for <repo> <lo> <hi> <dir>  (rows on stdout; returns non-zero if the walk itself failed)
  # git into a temp so its exit status is not lost to the pipeline head: a failed
  # rename walk that resolved to "no renames" used to leave entries under their
  # pre-rename identity in BOTH the add and modify lists (this map feeds both),
  # silently mis-slotting a migration. On failure return non-zero so the caller
  # routes the module to cc_refuse_walk instead of collecting a mis-mapped list.
  local rz; rz=$(mktemp "${TMPDIR:-/tmp}/collect-common-rn.XXXXXX") || return 3
  if ! git -C "$1" log --no-show-signature --reverse --diff-filter=R -M --name-status -z --pretty=format: "$2..$3" -- "$4" > "$rz"; then
    rm -f "$rz"; return 3
  fi
  z_rename_pairs "$CC_BAD" < "$rz" \
    | awk -F'\t' '
        { old[NR] = $1; new[NR] = $2; map[$1] = $2 }
        END {
          for (i = 1; i <= NR; i++) {
            cur = new[i]
            for (g = 0; (cur in map) && g < 100; g++) cur = map[cur]
            print old[i] "\t" cur
          }
        }
      '
  rm -f "$rz"
}

# Drive from an awk projection of only the collect rows' non-empty columns:
# `read` collapses an empty middle field (tab is IFS-whitespace), which would
# shift `repo` off; awk splits fields exactly, so project first.
awk -F'\t' '$6=="collect"{print $1"\t"$2"\t"$3"\t"$5"\t"$8}' "$RUN/common-resolution.tsv" \
| while IFS=$'\t' read -r module base target dir repo; do
  [[ -n "$repo" ]] || continue
  # range_ref maps each endpoint to its git ref: a released tag, a pseudo-version's
  # embedded commit, or a literal sha (local-path/override rows). Resolution already
  # verified both exist, so the walk below never silently resolves to nothing.
  lo=$(range_ref "$module" "$base")
  hi=$(range_ref "$module" "$target")
  RNMAP=$(mktemp "${TMPDIR:-/tmp}/collect-common-rnmap.XXXXXX")
  if ! rename_map_for "$repo" "$lo" "$hi" "$dir" > "$RNMAP"; then
    printf '%s%s%s\n' "$module" "$TABCH" "the rename-map walk (--diff-filter=R, $lo..$hi)" >> "$CC_WALKFAIL"
    rm -f "$RNMAP"; continue
  fi
  # git-log into a temp so its EXIT STATUS survives (a pipe head's status is lost).
  # A failed add walk routes the module to cc_refuse_walk rather than collecting an
  # empty list as success; the converter+awk stage runs pipefail-scoped so an awk
  # that dies mid-scan or an unwritable output surfaces too instead of `|| true`.
  addz=$(mktemp "${TMPDIR:-/tmp}/collect-common-addz.XXXXXX")
  if ! git -C "$repo" log --no-show-signature --reverse --topo-order --no-renames --diff-filter=A --name-only -z \
      --pretty=format:'commit %H' "$lo..$hi" -- "$dir" > "$addz"; then
    printf '%s%s%s\n' "$module" "$TABCH" "the add-pass walk (--diff-filter=A, $lo..$hi)" >> "$CC_WALKFAIL"
    rm -f "$addz" "$RNMAP"; continue
  fi
  ( set -o pipefail
    z_log_name_only "$CC_BAD" < "$addz" \
    | CC_DIR="$dir" awk -F'\t' -v mod="$module" -v rnmap="$RNMAP" \
          -v txt="$RUN/common-upgrades-added.txt" -v tsv="$RUN/common-upgrades-added.tsv" '
        BEGIN { while ((getline line < rnmap) > 0) { split(line, a, "\t"); if (a[1] != "") rn[a[1]] = a[2] } }
        function rewrite(p) { return (p in rn) ? rn[p] : p }
        # The dir prefix goes through the ENVIRONMENT, never `awk -v`: awk expands
        # escape sequences in a -v assignment, so a dir carrying a backslash would
        # reach the program mangled and match nothing.
        length($2) > length(ENVIRON["CC_DIR"]) && index($2, ENVIRON["CC_DIR"]) == 1 {
          p = rewrite($2)
          if (!(p in seen)) { seen[p] = 1; order[++n] = p; print p >> txt }
          latest[p] = $1
        }
        END { for (i = 1; i <= n; i++) print latest[order[i]] "\t" mod "\t" order[i] >> tsv }
      ' ) \
    || printf '%s%s%s\n' "$module" "$TABCH" "the add-pass conversion/write (--diff-filter=A)" >> "$CC_WALKFAIL"
  rm -f "$addz" "$RNMAP"
done
cc_refuse_walk
cc_refuse_badnames

# Snapshot each collected identity's body from its newest add commit into the
# shared $RUN/upgrades/ dir the planner/executor already consume for template
# upgrades. Paths in common-upgrades-added.tsv are already the FINAL (rewritten)
# identity, and the recorded sha is the commit at which that exact path existed
# with that content (either a genuine add, or the synthetic A a rename produces
# under --no-renames, whose content is unchanged by the move) — so `git show
# sha:path` is always valid without further rewriting here.
while IFS=$'\t' read -r sha module path; do
  [[ -n "${path:-}" ]] || continue
  repo=$(awk -F'\t' -v m="$module" '$1==m{print $8; exit}' "$RUN/common-resolution.tsv")
  snap_upgrade "$repo" "$sha:$path" "$module:$path" "$(basename "$path")" || true
done < "$RUN/common-upgrades-added.tsv"

# Body override + modified-list, mirroring build-manifest.sh:176-206: a
# --diff-filter=M pass (rename-rewritten the same way) unconditionally overwrites
# the add-pass snapshot with the newest amending commit's content — an amendment
# is strictly newer than the add it corrects. Limit carried over verbatim from
# the template side: an add -> modify -> delete -> re-add of the SAME path within
# one range can leave the stale M body; not a real authoring pattern, not worth
# reconciling here.
awk -F'\t' '$6=="collect"{print $1"\t"$2"\t"$3"\t"$5"\t"$8}' "$RUN/common-resolution.tsv" \
| while IFS=$'\t' read -r module base target dir repo; do
  [[ -n "$repo" ]] || continue
  lo=$(range_ref "$module" "$base")
  hi=$(range_ref "$module" "$target")
  RNMAP=$(mktemp "${TMPDIR:-/tmp}/collect-common-rnmap.XXXXXX")
  if ! rename_map_for "$repo" "$lo" "$hi" "$dir" > "$RNMAP"; then
    printf '%s%s%s\n' "$module" "$TABCH" "the rename-map walk (--diff-filter=R, $lo..$hi)" >> "$CC_WALKFAIL"
    rm -f "$RNMAP"; continue
  fi

  # Modified-only: amended in range but not (re)discovered as an add above —
  # either genuinely pre-existing (added before this module's BASE) or amended
  # under a pre-rename name that the rename map resolves to its final identity.
  # git into a temp so its status survives; the terminal grep -vxF legitimately
  # exits 1 when every modified path was already in the added list, so its `|| true`
  # STAYS — only the git walk's own failure is promoted to a refusal.
  modz=$(mktemp "${TMPDIR:-/tmp}/collect-common-modz.XXXXXX")
  if ! git -C "$repo" log --no-show-signature --reverse --topo-order --diff-filter=M --name-only -z \
      --pretty=format:'commit %H' "$lo..$hi" -- "$dir" > "$modz"; then
    printf '%s%s%s\n' "$module" "$TABCH" "the modified-list walk (--diff-filter=M, $lo..$hi)" >> "$CC_WALKFAIL"
    rm -f "$modz" "$RNMAP"; continue
  fi
  z_log_name_only "$CC_BAD" < "$modz" \
    | CC_DIR="$dir" awk -F'\t' -v rnmap="$RNMAP" '
        BEGIN { while ((getline line < rnmap) > 0) { split(line, a, "\t"); if (a[1] != "") rn[a[1]] = a[2] } }
        function rewrite(p) { return (p in rn) ? rn[p] : p }
        length($2) > length(ENVIRON["CC_DIR"]) && index($2, ENVIRON["CC_DIR"]) == 1 {
          p = rewrite($2); if (!seen[p]++) print p
        }
      ' \
    | grep -vxF -f "$RUN/common-upgrades-added.txt" >> "$RUN/common-upgrades-modified.txt" 2>/dev/null || true
  rm -f "$modz"

  # NOT --reverse, unlike the list pass above: `!(p in seen)` then keeps the
  # NEWEST amending commit per identity, which is the body that wins.
  mbz=$(mktemp "${TMPDIR:-/tmp}/collect-common-mbz.XXXXXX")
  if ! git -C "$repo" log --no-show-signature --topo-order --diff-filter=M --name-only -z \
      --pretty=format:'commit %H' "$lo..$hi" -- "$dir" > "$mbz"; then
    printf '%s%s%s\n' "$module" "$TABCH" "the modified-body walk (--diff-filter=M, newest-first, $lo..$hi)" >> "$CC_WALKFAIL"
    rm -f "$mbz" "$RNMAP"; continue
  fi
  z_log_name_only "$CC_BAD" < "$mbz" \
    | CC_DIR="$dir" awk -F'\t' -v rnmap="$RNMAP" '
        BEGIN { while ((getline line < rnmap) > 0) { split(line, a, "\t"); if (a[1] != "") rn[a[1]] = a[2] } }
        function rewrite(p) { return (p in rn) ? rn[p] : p }
        length($2) > length(ENVIRON["CC_DIR"]) && index($2, ENVIRON["CC_DIR"]) == 1 {
          p = rewrite($2)
          if (!(p in seen)) { seen[p] = 1; print $1 "\t" $2 "\t" p }
        }
      ' \
    | while IFS=$'\t' read -r sha origpath finalpath; do
        [[ -n "${finalpath:-}" ]] || continue
        # Read from the ORIGINAL path at that sha (what the file was actually
        # called then); write to the FINAL identity's basename. The source id
        # uses the final path, so this intentional override of the add-pass
        # snapshot is same-source and never flagged as a collision.
        snap_upgrade "$repo" "$sha:$origpath" "$module:$finalpath" "$(basename "$finalpath")" || true
      done

  rm -f "$mbz" "$RNMAP"
done
cc_refuse_walk
cc_refuse_badnames
rm -f "$CC_BAD"

# Fidelity signal (US6): collection is the last point that knows which commit a
# body came from. A snapshot carrying none of the machine-read fields looks like
# a well-formed upgrade-file but silently degrades before:/verify-script: into
# no-ops — flag it rather than let it pass unremarked.
for list in common-upgrades-added.txt common-upgrades-modified.txt; do
  [[ -f "$RUN/$list" ]] || continue
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    snap="$RUN/upgrades/$(basename "$path")"
    if [[ -f "$snap" ]] && ! grep -qE '^(intent|before|verify-script|verify):' "$snap"; then
      echo "WARNING: $(basename "$path") has none of intent:/before:/verify-script:/verify: — before:/verify-script: will no-op if relied on" >&2
    fi
  done < "$RUN/$list"
done

# --- supersede edges ----------------------------------------------------------
# Parse each collected file's `supersedes:` declaration into edges. The order
# file is the added list in apply order (module in col2, path in col3); the list
# file is every collected file (added ∪ modified) with its kind, so the helper
# can tell same-module from cross-module. Modules for the modified list come from
# the .kairos-updates/<module>/ path segment (that list carries no module column).
#
# Every step is CHECKED: a failed temp file or input build would hand the helper
# an empty list and it would emit nothing into the edge file truncated up top —
# indistinguishable from "no supersedes in range" for supersede-check.sh, which
# would then pass a plan that left a retired slug unskipped. On any failure the
# edge file is REMOVED (the helper does the same for its own failures) so the
# gate refuses (exit 2) instead of reading an empty file as clean.
{
  cc_fail() { rm -f "${cc_order:-}" "${cc_list:-}" "$RUN/common-supersede-edges.tsv"; fail "$* — common-supersede-edges.tsv removed rather than left empty (an empty edge file reads as 'no supersedes in range'). Check that ${TMPDIR:-/tmp} and $RUN are writable, then re-run this phase."; }
  cc_order=$(mktemp "${TMPDIR:-/tmp}/cc-order.XXXXXX") || cc_fail "could not create a temp file for the supersede apply-order list"
  cc_list=$(mktemp "${TMPDIR:-/tmp}/cc-list.XXXXXX")   || cc_fail "could not create a temp file for the supersede module map"
  awk -F'\t' '{ stem=$3; sub(/.*\//,"",stem); sub(/\.md$/,"",stem); print $2"\t"stem }' \
    "$RUN/common-upgrades-added.tsv" > "$cc_order" || cc_fail "could not build the supersede apply-order list from common-upgrades-added.tsv"
  awk -F'\t' '{ print $1"\t"$2"\tadded" }' "$cc_order" > "$cc_list" || cc_fail "could not build the supersede module map"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    m=${path#*.kairos-updates/}; m=${m%%/*}
    b=${path##*/}; stem=${b%.md}
    printf '%s\t%s\tmodified\n' "$m" "$stem" >> "$cc_list"
  done < "$RUN/common-upgrades-modified.txt" || cc_fail "could not add the modified list to the supersede module map"
  supersede_emit "$cc_order" "$cc_list" "$RUN/upgrades" "$RUN/common-supersede-edges.tsv" \
    || cc_fail "supersede edge emission failed"
  rm -f "$cc_order" "$cc_list"
}

# --- legacy root UPGRADE.md, gated by the per-module ceiling ------------------
# For each migrating module whose BASE is at or below its ceiling, capture the
# commits touching the frozen root UPGRADE.md over <module>/BASE..<module>/ceiling
# and feed them to the planner as free-form legacy migration notes (mirroring the
# template's legacy-UPGRADE.md mechanism). Union across modules, deduped. The
# capture self-gates: if no UPGRADE.md commit falls in range, nothing is fed. A
# module whose BASE is above its ceiling is in the structured era — ignored.
#
# NOTE: unlike the BASE-tag guard in the local-path block above (which emits
# 'unresolvable' when the tag is missing), the ceiling tag is intentionally NOT
# verified for local-path repos. It only bounds this legacy UPGRADE.md capture,
# which is off-path in co-dev mode — authors test the new structured files they
# are writing, not frozen legacy history. A local clone missing the ceiling tag
# resolves this `git log` to nothing, silently, which is harmless. BASE is guarded
# because it bounds structured collection — the actual point of local-path mode.
: > "$RUN/common-legacy-upgrade-commits.txt"
legraw="$RUN/.legacy-raw"; : > "$legraw"
awk -F'\t' '$6=="collect"{print $1"\t"$2"\t"$8}' "$RUN/common-resolution.tsv" \
| while IFS=$'\t' read -r module base repo; do
    ceil=$(ceiling_for "$module")
    [[ -n "$ceil" ]] && [[ -n "$repo" ]] || continue
    # Both endpoints go through range_ref, exactly like the normal upgrade-file
    # walk (~623-624): a pseudo-version BASE resolves to its embedded commit
    # instead of a literal "$module/$base" tag that never exists for an
    # unreleased pin — the git log below used to fail "bad revision" and be
    # swallowed by `|| true`, silently dropping legacy notes for a co-dev pin.
    lo=$(range_ref "$module" "$base")
    hi=$(range_ref "$module" "$ceil")
    if is_pseudo "$base"; then
      # semver_gt can't order a commit-bounded BASE (it would read a Go
      # post-release pseudo-version's dash suffix as a pre-release and place
      # it BEFORE the ceiling it's actually past). Fall back to commit
      # ancestry against the resolved refs, mirroring range_is_downgrade:
      # BASE is above ceiling iff ceiling's commit is a strict ancestor of it.
      [[ "$lo" != "$hi" ]] && git -C "$repo" merge-base --is-ancestor "$hi" "$lo" 2>/dev/null && continue
    else
      semver_gt "$base" "$ceil" && continue   # BASE above ceiling → structured era
    fi
    git -C "$repo" log --no-show-signature --pretty=format:%H "$lo..$hi" -- UPGRADE.md \
      >> "$legraw" 2>/dev/null || true
    echo >> "$legraw"
done
grep -v '^$' "$legraw" 2>/dev/null | sort -u > "$RUN/common-legacy-upgrade-commits.txt" || true
rm -f "$legraw"

echo "OK: common resolution written to $RUN/common-resolution.tsv" >&2
cut -f6 "$RUN/common-resolution.tsv" | sort | uniq -c | sort -rn >&2
