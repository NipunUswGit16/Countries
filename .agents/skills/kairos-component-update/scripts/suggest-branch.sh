#!/usr/bin/env bash
# suggest-branch.sh — derive the suggested migration branch name from the target
# SHA and the local username. The suggestion is exactly that: Phase 4 must still
# confirm it with the user (or take --branch) before creating anything.
#
# Username resolution prefers the $HOME basename, falling back to a real login
# name when HOME is empty or something generic (/Users/Shared, root) — the same
# first-non-empty-wins chain the phase prose always described. Either source is
# sanitized into a git ref path component before use (see sanitize_ref_component
# below) — raw filesystem/login text is not ref-safe.
#
# SOURCE parameterizes the topic segment, and a CHAINED frontend run reuses the
# branch the template run already created: one PR carries both runs by default, so
# the frontend run must not suggest a second branch off the first one's tip. That reuse
# has TWO sources, because the first does not survive the chained re-entry:
# $MIGRATION_BRANCH off the anchor when it is there, else the branch the run is STANDING
# on when that branch is itself migration-shaped. A frontend-only invocation from an
# ordinary branch matches neither and gets its own name.
#
# Env in:  PHASE_KEY  required — proof-of-load key stated in phases/4-migration-branch.md
#          TARGET     required — the resolved target SHA (full or short)
#          SOURCE     template (default) | frontend — the topic segment. An
#                     unknown value is refused, never defaulted.
#          MIGRATION_BRANCH  read ONLY under SOURCE=frontend: the branch the
#                     template run of this same invocation created. When set, it is
#                     printed verbatim — the chained run continues it. A template
#                     run never consults it (its own branch is what it is about to
#                     create, so reusing one would make Phase 4 a no-op). When it is
#                     absent (the fresh sweep took the anchor with it), an already
#                     checked-out migration-shaped branch is used instead.
# Cwd:     the component root on a frontend run (the current-branch fallback reads
#          it); anywhere otherwise — outside a git work tree that fallback is empty
# Stdout:  topic/<username>/<source>-update-<short-target-sha>; or, on a chained
#          frontend run, $MIGRATION_BRANCH — else the migration-shaped branch that is
#          already checked out
# Exit:    0; 1 when PHASE_KEY is missing/wrong, TARGET is missing, or SOURCE is
#          not one of template|frontend
set -u

# Phase-load guard: this key is stated ONLY in phases/4-migration-branch.md, so an
# orchestrator that skipped loading that file cannot know it. The guard turns a
# skipped load into a stop instead of a phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "m6dh2pjx" ]] \
  || { echo "FAIL: load phases/4-migration-branch.md first" >&2; exit 1; }

: "${TARGET:?FAIL: TARGET not set}"

# `${SOURCE-template}`, not `${SOURCE:-template}`: unset defaults (every
# pre-frontend caller passes none), set-but-empty is refused. Phase 4 interpolates
# `SOURCE=$RUN_SOURCE` off the run-context anchor, so an empty value is a lost
# anchor key rather than a choice — and defaulted it names a frontend run's branch
# `template-update-…`, the one thing that name is supposed to tell you.
case "${SOURCE-template}" in
  template) SOURCE=template ;;
  frontend)
    SOURCE=frontend
    # The chained case: keep the migration branch the template run created, so one
    # PR carries both runs. Printed verbatim rather than re-derived — the name is
    # the USER's (Phase 4 confirmed it, and they may have overridden the
    # suggestion), and re-deriving it from $TARGET would silently rename it.
    if [[ -n "${MIGRATION_BRANCH:-}" ]]; then
      printf '%s\n' "$MIGRATION_BRANCH"
      exit 0
    fi
    # SELF-HEALING second source of the same fact: the branch we are STANDING ON.
    # MIGRATION_BRANCH lives only in $RUN/context.env, and the chained frontend run
    # re-enters through a FRESH pre-flight whose sweep deletes that file — so by the
    # time Phase 4 asks, the anchor no longer carries it and the arm above cannot fire.
    # A new topic/<user>/frontend-update-<sha> branch is then created off the template
    # run's tip and the invocation ends with TWO branches and two PRs, the opposite of
    # the documented default (phases/8-finalize.md; PRD story 12). The current branch
    # already IS the answer in exactly that case, and it is durable: a frontend run
    # standing on a migration-shaped branch is the chained/frontend re-entry pre-flight
    # check 3 accepts.
    #
    # Deliberately narrow — only the two suggested shapes count, the same globs
    # pre-flight matches — so a frontend-only run from a feature branch or from main
    # still gets its own name and the normal create path. Cwd is the component root
    # (Phase 4 runs there); outside a git work tree there is nothing to read and the
    # derivation below stands.
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    case "$CURRENT_BRANCH" in
      topic/*/template-update-*|topic/*/frontend-update-*)
        echo "INFO: already on migration-shaped branch $CURRENT_BRANCH and this is a frontend run — suggesting that branch, so the chained run continues it and one PR carries both. Pass --branch <name> for a separate PR." >&2
        printf '%s\n' "$CURRENT_BRANCH"
        exit 0 ;;
    esac ;;
  "") echo "FAIL: SOURCE is set but EMPTY (want template|frontend). Unset defaults to template; empty means \$RUN_SOURCE never reached this call." >&2; exit 1 ;;
  *) echo "FAIL: unknown SOURCE '${SOURCE:-}' (want template|frontend)" >&2; exit 1 ;;
esac

# $HOME's basename is arbitrary local-machine text, no more constrained than the
# filesystem allows — a space ("/Users/Jane Doe"), or ~^:?*[\ — none of which
# git accepts in a ref path component. Left raw, one of those bytes reaches the
# suggested name and turns a SUGGESTION Phase 4 must still let the user confirm
# into a name `git branch`/`git checkout -b` refuses outright. Runs of invalid
# bytes collapse to one dash rather than one per byte — the same idea yaml-gate.sh's
# release_name() uses for a helm release name — and a leading/trailing dot (also
# ref-invalid) is trimmed the same way release_name trims stray dashes.
sanitize_ref_component() { # sanitize_ref_component <text> — a name git accepts
  printf '%s' "$1" | LC_ALL=C tr -s ' ~^:?*[\' '-' \
    | LC_ALL=C sed -e 's/^\.*//' -e 's/\.*$//'
}

USERNAME=$(sanitize_ref_component "$(basename "${HOME:-}" 2>/dev/null || true)")
case "$USERNAME" in
  ""|"/"|Shared|root) USERNAME=$(sanitize_ref_component "$(id -un 2>/dev/null || whoami)") ;;
esac
# A fully-invalid login name (every byte illegal, or an all-dot name) sanitizes
# to nothing too — same residual release_name() names for an all-illegal chart
# directory — and an empty USERNAME segment would print a bare "topic//…".
[[ -n "$USERNAME" ]] || USERNAME=kairos-user

printf 'topic/%s/%s-update-%s\n' "$USERNAME" "$SOURCE" "${TARGET:0:7}"
