#!/usr/bin/env bash
# pre-flight.sh — all pre-flight checks for a kairos component migration.
# Fails loudly on the first problem.
#
# Env in:
#   PHASE_KEY      required — proof-of-load key stated in phases/1-preflight.md
#   MODE           fresh (default) | continue
#   RUN_SOURCE     optional — which upgrade source this invocation migrates:
#                  template (default, and what an unset value means) | frontend.
#                  The SAME name the run-context anchor uses for the run's
#                  identity, because it is the same fact learned one phase
#                  earlier: the invocation knows it before Phase 2 anchors it.
#                  Three checks key off it — 0b (a frontend run materializes
#                  nothing through the Kairos CLI, so the CLI probe is n/a),
#                  3 (a chained or frontend-only run legitimately stands on a
#                  FINISHED template run's migration branch, which carries no
#                  in-progress block; and, in continue mode, a caller-declared
#                  source that contradicts the live block is refused) and
#                  8.6 (only a frontend run establishes the frontend mirror).
#                  A template run with it unset behaves byte-for-byte as before.
#   TEMPLATE_PATH  optional — local template clone to use instead of cloning
#   TEMPLATE_REPO  optional — template repo URL override (needed for bootstrap,
#                  when .kairos/manifest.yaml doesn't exist yet)
#   FRONTEND_PATH  optional — local checkout of the FRONTEND source repo (the
#                  monorepo root, or any path inside it: check 8.5 normalizes it
#                  to the enclosing git toplevel). --template-path's analog for
#                  the second upgrade source. On a frontend run it is also check
#                  8.6's clone origin.
#   FRONTEND_REPO  optional — frontend source URL, read only as check 8.6's clone
#                  origin and only to FILL A GAP: the manifest's recorded
#                  frontend.repo wins, so this is the bootstrap case (no block yet).
#   KAIROS_BIN     optional — Kairos CLI binary to probe (default: kairos)
#   KAIROS_MIN_VERSION  optional — minimum accepted CLI version (default: 0.3.12)
#   SWEEP_STALE_RUN     optional — set to acknowledge and sweep a $RUN that
#                  carries an unpromoted qa-ledger.tsv but never reached Phase 4
#                  (check 6's interlock). The escape hatch for a genuinely stale
#                  pre-Phase-4 leftover; a fresh run refuses it by default so a
#                  second invocation cannot silently destroy a live run's Q&A.
# Stdout on success:
#   RUN=<path-to-migration-state-dir>
#   CACHE=<path-to-template-git-dir>
#   TEMPLATE_LOCAL_BRANCH=<branch>  (only with TEMPLATE_PATH, on a branch)
#   IN_PROGRESS_SOURCE=<template|frontend>  (only when a live block exists)
#   FRONTEND_CACHE=<path-to-frontend-mirror>  (only on a frontend run — check 8.6)
#   COMPONENT_KIND=facade           (only for a facade: manifest template.kind, else
#                                    the .init.mk facade check, lib/component-kind.sh)
#   TEMPLATE_REPO=<url>             (only when check 7 defaulted a facade bootstrap
#                                    to kairos-component-facade-template)
#   FRONTEND_*                      (only when a frontend source is present —
#                                    see check 8.5; a component with no `web/package.json`
#                                    and no `frontend:` block emits nothing)
# Everything else goes to stderr.
#
# WHY there are two in-progress keys to look for: a component is assembled from
# more than the component template, and `web/` is a second, template-shaped
# upgrade source with its own repo, its own SHAs and its own run. A frontend
# migration records `frontend.in_progress`, not `template.in_progress`. This
# script's job is to see EITHER and to treat them as mutually exclusive: every
# question the block answers — which branch, which target, which rollback SHA —
# has exactly one answer per component, so two live blocks is an unanswerable
# state rather than a degraded one.
#
# WHY the local-branch line exists: a template author co-developing on a feature
# branch ran a migration with --template-path at a checked-out branch 54 commits
# ahead of main; TARGET silently defaulted to main and the whole run was mis-scoped
# but completed green. The strongest statement of "migrate against what I have here"
# is the branch the local clone actually has checked out — so pre-flight emits it
# for Phase 2's default chain, and warns when that clone's working tree is dirty
# (uncommitted content never reaches the mirror clone, so it is invisible to the run).
#
# NOTE: baseline/target SHA validation is NOT here — those SHAs are only
# resolved in Phase 2, which validates them itself.
set -u

fail() { echo "FAIL: $*" >&2; exit 1; }

# Phase-load guard: this key is stated ONLY in phases/1-preflight.md, so an
# orchestrator that skipped loading that file cannot know it. The guard turns a
# skipped load into a stop instead of a phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "zsdjxztv" ]] || fail "load phases/1-preflight.md first"

# --- which upgrade source this invocation migrates ---------------------------
# Normalized ONCE, here, so the two checks that key off it (0b and 3) read a
# settled value and no arm has to re-decide what an empty string means. Unset is
# `template`: that is what every invocation before the second source existed
# meant, and it is what keeps a template run's output byte-identical.
#
# A typo is a HARD FAIL rather than a silent fall back to `template`: falling
# back would restore check 3's refusal on exactly the chained run the caller was
# trying to declare, and the message the user would get ("delete this branch")
# is destructive advice for a legitimate state.
RUN_SOURCE=${RUN_SOURCE:-}
case "$RUN_SOURCE" in
  ''|template|frontend) ;;
  *) fail "RUN_SOURCE='$RUN_SOURCE' is not an upgrade source this skill knows. Pass 'template' or 'frontend' (or leave it unset, which means template)." ;;
esac

# MODE typos are refused, not silently treated as fresh: every `${MODE:-fresh}`
# read below tests for the literal `continue`, so `MODE=continu` would sail
# through as a FRESH run — paying check 1's dirty-tree refusal and check 3's
# "delete this branch" advice on exactly the resume the caller was trying to
# declare, the same destructive fall-back RUN_SOURCE is guarded against above.
case "${MODE:-fresh}" in
  fresh|continue) ;;
  *) fail "MODE='$MODE' is not a run mode this skill knows. Pass 'continue' to resume, or leave it unset/'fresh' to start a new migration." ;;
esac

# Fixed migration paths — one migration per repo at a time. The template bare
# clone lives inside the migration state dir so each component owns its own
# copy; no home-directory side effects and no sharing between components.
RUN=.kairos/migration/state
CACHE=$RUN/template

# --- 0. Tool dependencies ----------------------------------------------------
for tool in git yq; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "required tool '$tool' not found on PATH. Install it and re-run."
done

# Two unrelated tools install as `yq`, and the right one has two incompatible major
# versions. Every yq call in this skill is written for mikefarah (Go) v4; the python
# one (kislyuk/yq, a jq wrapper) takes different flags and fails in two incompatible
# ways — LOUDLY in yaml-gate.sh, and SILENTLY in collect-common.sh, which then
# completes "OK" with zero common modules resolved and every common migration
# dropped. Identify the flavor AND the major version here, where the wrong install
# is one message instead of a green run that skipped work.
YQ_VERSION=$(yq --version 2>&1 || true)
case "$YQ_VERSION" in
  *mikefarah*|'yq version '*) ;;
  *) fail "'yq' on PATH is not the mikefarah build (reported: ${YQ_VERSION:-<no output>}). Migration is written against mikefarah/yq v4 and the python 'yq' silently resolves nothing. Install it (brew install yq, or go install github.com/mikefarah/yq/v4@latest) ahead of the other one on PATH and re-run." ;;
esac

# mikefarah v3 CLEARS the flavor arm above — it reports `yq version 3.4.1`, which is
# exactly the `yq version ` spelling early v4 builds use — and then every v4-only
# construct this skill relies on fails several phases later: `strenv()` and the `|
# tag` operator in in-progress.sh, `-p=json` in collect-common.sh / codev-check.sh,
# `yq e` in yaml-gate.sh. So the major version is a check in its own right.
#
# Both v4 spellings must pass: `yq (https://github.com/mikefarah/yq/) version v4.x.y`
# (current) and the older bare `yq version 4.9.6`, with or without the `v`. The
# number is read from AFTER the last `version ` — never as "the first digits in the
# output", because the current spelling carries a URL and a future one may carry more.
#
# Pure parameter expansion, no sed/awk/grep: this is a TOOL PROBE, and it must not
# itself depend on tools it never checked for. (The suite narrows PATH to git/yq/perl
# for exactly these probes, which is where a pipeline through sed silently produced an
# empty version and mis-reported a perfectly good v4 as unreadable.)
YQ_MAJOR=${YQ_VERSION##*[Vv]ersion }   # after the last "version "; unchanged if absent
YQ_MAJOR=${YQ_MAJOR#v}                 # v4.53.3 -> 4.53.3
YQ_MAJOR=${YQ_MAJOR%%.*}               # 4.53.3  -> 4
case "${YQ_MAJOR:-}" in
  ''|*[!0123456789]*)
    fail "could not read a major version from 'yq --version' (reported: ${YQ_VERSION:-<no output>}). Migration requires mikefarah/yq v4 or newer — update it (brew upgrade yq, or go install github.com/mikefarah/yq/v4@latest) and re-run." ;;
esac
[[ "$YQ_MAJOR" -ge 4 ]] \
  || fail "'yq' on PATH is mikefarah v$YQ_MAJOR (reported: $YQ_VERSION), but migration requires major version 4 or newer: strenv(), the 'tag' operator and '-p=json' are all v4-only, so a v3 install fails mid-run in Phase 2 instead of here. Update it (brew upgrade yq, or go install github.com/mikefarah/yq/v4@latest) and re-run."

# `perl` is a HARD dependency too: intent-check.sh runs every `grep` intent guard
# under `perl -e 'alarm ...'`, the portable wall-clock timeout on BSD userland (the
# `test` guards of the grammar are evaluated as a shell builtin and need no
# timeout). Without perl the wrapper itself fails on every grep guard, so ONE
# missing tool reads as N phantom guard failures — the orchestrator then argues
# with the intent ledger instead of installing perl.
command -v perl >/dev/null 2>&1 \
  || fail "required tool 'perl' not found on PATH (grep intent guards run under a perl alarm timeout; without it every one of them reads as a failure). Install perl and re-run."

# `go` is a HARD dependency too — but only for a Go component, so the probe is
# conditional on the component root actually carrying a go.mod. Phase 3.5 parses
# it twice with the go tool (codev-check.sh's wrong-target tripwire and
# collect-common.sh's module list), and both hard-fail without it. Same
# philosophy as check 0b: fail at the earliest point, before a single byte of
# state is written, instead of mid-phase with a half-built migration to unwind.
if [[ -f ./go.mod ]]; then
  command -v go >/dev/null 2>&1 \
    || fail "required tool 'go' not found on PATH (this component has a go.mod; migration parses it with 'go mod edit'). Install it and re-run."
fi

# Resolved here — AFTER check 0's tool probes, BEFORE check 7/8.6 use it — for two
# reasons. It must be past the probes: those narrow PATH to git/yq/perl to test their
# own messages, and computing HERE (via `dirname`) or sourcing before them would fail
# under that stripped PATH with the wrong diagnostic. And it must be before the mirror
# builds: check 7 (--template-path) and check 8.6 (--frontend-path) clone the mirror
# FROM a local checkout, which inherits exactly the refs that checkout last fetched, so
# fetch_local_clone brings the checkout current first (a BASE/TARGET released upstream
# since would otherwise be absent from the mirror). $HERE is reused at check 9's
# record-context call.
HERE=$(cd "$(dirname "$0")" && pwd)
[[ -r "$HERE/lib/fetch-local-clone.sh" ]] \
  || fail "missing $HERE/lib/fetch-local-clone.sh — it owns fetch_local_clone"
# shellcheck source=lib/fetch-local-clone.sh
. "$HERE/lib/fetch-local-clone.sh" \
  || fail "could not source $HERE/lib/fetch-local-clone.sh"
[[ -r "$HERE/lib/bitbucket-url.sh" ]] \
  || fail "missing $HERE/lib/bitbucket-url.sh — it owns canonical_ssh_url"
# shellcheck source=lib/bitbucket-url.sh
. "$HERE/lib/bitbucket-url.sh" \
  || fail "could not source $HERE/lib/bitbucket-url.sh"
[[ -r "$HERE/lib/component-kind.sh" ]] \
  || fail "missing $HERE/lib/component-kind.sh — it owns component_kind"
# shellcheck source=lib/component-kind.sh
. "$HERE/lib/component-kind.sh" \
  || fail "could not source $HERE/lib/component-kind.sh"

# --- 0a. Run from the component root (the git work-tree toplevel) -------------
# Every check below is anchored at the component root, and each fails SILENTLY
# WRONG from a subdirectory rather than refusing: check 1's dirty scan is
# pathspec-scoped to `.` (so it reports clean from web/ while the root is dirty),
# checks 3 and 6 read .kairos/manifest.yaml by relative path (invisible from a
# subdir, so BOTH live-run refusals skip and a fresh run sweeps a live one), and
# checks 5/6/9 create .kairos/migration/state under the cwd (a second state dir
# at web/.kairos/migration/state). A frontend run legitimately cds into the
# mount in later phases (4.5/7/8), so being invoked from there is realistic.
# One toplevel comparison closes all of it — refuse anywhere but the root.
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) \
  || fail "not inside a git work tree (a bare or mirror clone has no work tree). Run pre-flight from the component's git checkout."
[[ "$TOPLEVEL" = "$(pwd -P)" ]] \
  || fail "must be run from the component root, not a subdirectory. The component root is the git toplevel ($TOPLEVEL); the current directory is $(pwd -P). Every check keys off the root — from a subdir the dirty scan reports clean, the manifest is invisible, and a second state dir is created. cd \"$TOPLEVEL\" and re-run."

# --- 0b. Kairos CLI, at a version that can materialize template trees ---------
# A TEMPLATE run's merge sides are built by `kairos component create` itself (see
# materialize.sh for why), so the CLI is a HARD dependency of every template
# migration — there is no substitution-map fallback path any more. Probe it HERE, before a
# single byte of state is written, because discovering it mid-run means a
# half-built migration to unwind.
#
# Two independent checks, because either can fail alone: an old CLI is on PATH
# (version too low), or a CLI reports a new version but was built without the
# flags (a local checkout mid-rebase). The flag probe is the one that actually
# matters, so it is not merely implied by the version.
#
# NOT APPLICABLE ON A FRONTEND RUN (PRD story 32). Nothing on that arm goes
# through `component create`: materialize-frontend.sh extracts the module
# subtree at each SHA and applies the create-time replacement map itself (the
# CLI can only clone the frontend at branch HEAD, which is neither BASE nor
# TARGET), so a missing or old CLI has nothing to break there. Probing it anyway
# would block a frontend run on a tool it never invokes — which is exactly the
# dependency this fork removes. The probe is skipped, said out loud, and NOT
# turned into a soft warning: "not applicable" is a different claim from "old".
# A facade (manifest template.kind, else the .init.mk facade check in
# lib/component-kind.sh) is materialized with `kairos component facade create` (CLI >= 0.3.35),
# which has no --no-frontend flag: probe THAT subcommand for it.
COMPONENT_KIND=$(component_kind .)
[[ "$COMPONENT_KIND" != facade ]] \
  || echo "INFO: this component is a facade (template.kind, or .init.mk sets MASTERDATA_INCLUDE_NO_CDC or GENERATE_MODULES without sql/all) — its template is kairos-component-facade-template" >&2
if [[ "$RUN_SOURCE" = frontend ]]; then
  echo "INFO: Kairos CLI probe not applicable — a frontend run materializes its merge sides from the module subtree plus the skill's own replacement map (scripts/lib/frontend-substitute.sh) and invokes no CLI" >&2
else
  KAIROS_BIN=${KAIROS_BIN:-kairos}
  KAIROS_MIN_VERSION=${KAIROS_MIN_VERSION:-0.3.12}

  command -v "$KAIROS_BIN" >/dev/null 2>&1 \
    || fail "Kairos CLI ('$KAIROS_BIN') not found on PATH. Migration materializes the template trees with it — install/update nga-local-dev and re-run."

  # Warm-up: one THROWAWAY invocation, output and exit status both discarded, whose
  # only job is to let a pending CLI update settle before anything depends on the
  # install staying still. Every kairos invocation bootstraps first — reinstalling
  # dependencies when they changed, applying version-state migrations — and the
  # first migration lost its first `kairos component create` to exactly that work
  # landing mid-invocation. Paying it here means the probes below read a settled
  # install, and materialization does too.
  #
  # Best-effort ON PURPOSE: the CLI has no on-invoke self-updater and no flag to
  # force a pending update to complete, so nothing here can guarantee the install
  # is stable later. materialize.sh's retry-once around `component create` is the
  # load-bearing defense; this only shrinks the window.
  "$KAIROS_BIN" --version >/dev/null 2>&1 || true

  # Take the LAST version-bearing line: the CLI may print an auto-update INFO line
  # first, and that line itself contains version numbers.
  KAIROS_VERSION=$("$KAIROS_BIN" --version 2>/dev/null | grep -i version | tail -1 \
                     | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
  [[ -n "$KAIROS_VERSION" ]] \
    || fail "could not read a version from '$KAIROS_BIN --version'. Update nga-local-dev and re-run."

  if ! awk -v have="$KAIROS_VERSION" -v want="$KAIROS_MIN_VERSION" '
        BEGIN {
          nh = split(have, h, "."); nw = split(want, w, ".")
          for (i = 1; i <= 3; i++) {
            hv = (i <= nh ? h[i] + 0 : 0); wv = (i <= nw ? w[i] + 0 : 0)
            if (hv > wv) exit 0
            if (hv < wv) exit 1
          }
          exit 0
        }'; then
    fail "Kairos CLI $KAIROS_VERSION is too old — migration requires >= $KAIROS_MIN_VERSION. Update nga-local-dev (git pull) and re-run."
  fi

  if [[ "$COMPONENT_KIND" = facade ]]; then
    KAIROS_SUBCMD="component facade create"; KAIROS_FLAGS="--no-tidy --template-path"
    KAIROS_HELP=$("$KAIROS_BIN" component facade create --help 2>&1 || true)
  else
    KAIROS_SUBCMD="component create"; KAIROS_FLAGS="--no-tidy --no-frontend"
    KAIROS_HELP=$("$KAIROS_BIN" component create --help 2>&1 || true)
  fi
  MISSING_FLAGS=""
  for flag in $KAIROS_FLAGS; do
    case "$KAIROS_HELP" in
      *"$flag"*) ;;
      *) MISSING_FLAGS="$MISSING_FLAGS $flag" ;;
    esac
  done
  if [[ -n "$MISSING_FLAGS" ]] && [[ "$COMPONENT_KIND" = facade ]]; then
    fail "Kairos CLI $KAIROS_VERSION reports no$MISSING_FLAGS on '$KAIROS_SUBCMD'. A facade is materialized with 'kairos component facade create' (CLI >= 0.3.35) — update nga-local-dev and re-run."
  fi
  [[ -z "$MISSING_FLAGS" ]] \
    || fail "Kairos CLI $KAIROS_VERSION reports no$MISSING_FLAGS on 'component create'. Migration needs these to materialize template trees non-interactively — update nga-local-dev and re-run."

  echo "INFO: Kairos CLI $KAIROS_VERSION supports migration materialization" >&2
fi

# --- 1. Clean working tree ---------------------------------------------------
# Untracked files in untracked/gitignored locations are OK. The point is:
# abort must be safe — anything uncommitted at migration end is presumed to be
# the AI's in-progress work and gets discarded.
#
# Continue mode exempts four paths that are dirty BY DESIGN mid-run: every
# .kairos/migration-log.md entry is written after the commit it describes and
# rides the NEXT commit (Phase 5 structural entry, Phase 7 per-task entries,
# Phase 8 pre-finalize writes), .kairos/intent.md is appended by promotion
# or abort-salvage before Phase 8's finalize commit carries it,
# .kairos/manifest.yaml is left staged/modified in two resume windows
# reference/continue.md names verbatim (a kill after Phase 4's in-progress `set`
# but before the scaffolding commit, and a kill inside Phase 8 step 5 between the
# baseline advance and the commit that carries it), and .gitignore is left STAGED
# in that same mid-Phase-4 window: Phase 4 runs `git add .gitignore` (the
# state-dir ignore migration on the legacy components this skill targets) several
# statements before the scaffolding commit, so a kill there leaves it staged.
# abort.md's mid-Phase-4 arm already unstages it; continue must not refuse the
# same window. Refusing on any of the four would refuse the exact resumes those
# windows land in — and continue.md forbids committing/stashing past this check,
# so leaving one un-exempt makes every triage arm that runs step 2's pre-flight
# first a dead end. Refusing on those would also refuse every legitimate resume
# after Phase 5 — the exact state Phase 7's context checkpoint tells the user to
# resume from. Anything dirty beyond the four is still a refusal: continue.md's
# triage owns that shape.
if [[ "${MODE:-fresh}" = "continue" ]]; then
  git diff --quiet -- . ':(exclude).kairos/migration-log.md' ':(exclude).kairos/intent.md' ':(exclude).kairos/manifest.yaml' ':(exclude).gitignore' \
    && git diff --cached --quiet -- . ':(exclude).kairos/migration-log.md' ':(exclude).kairos/intent.md' ':(exclude).kairos/manifest.yaml' ':(exclude).gitignore' \
    || fail "working tree is dirty beyond .kairos/migration-log.md, .kairos/intent.md, .kairos/manifest.yaml and a staged .gitignore. See reference/continue.md's dirty-tree triage before resuming."
else
  git diff --quiet && git diff --cached --quiet \
    || fail "working tree is dirty. Commit or stash before migrating."
fi

# --- 2. On a branch (not detached HEAD) --------------------------------------
git symbolic-ref -q HEAD >/dev/null \
  || fail "detached HEAD. Check out a branch before migrating."

# --- 3. No live migration in the way (unless continuing) ---------------------
# Authority is the manifest's in_progress BLOCK — under EITHER source key: while
# one exists a run owns $RUN, on whatever branch. in_progress.branch (user-chosen
# names) and the topic/<user>/{template,frontend}-update-* patterns only tell us
# where we are standing.
CURRENT=$(git rev-parse --abbrev-ref HEAD)
IN_PROGRESS_BRANCH=""
IN_PROGRESS_PREV=""
IN_PROGRESS_TARGET=""
IN_PROGRESS_BLOCK=false
IN_PROGRESS_SOURCE=""
if [[ -f .kairos/manifest.yaml ]]; then
  # PRESENCE, via has() — NOT a value read. `.template.in_progress // ""`
  # collapses "key present but NULL-VALUED" into "key absent": an `in_progress:`
  # with nothing under it (a hand-edit, or a conflicted-merge restore of the
  # committed manifest — the two sources reference/abort.md names) rounds to ""
  # and reads as "no migration". That disarms the refusal below AND check 6's
  # sweep guard, so a fresh run over a LIVE migration overwrites its
  # qa-ledger.tsv, model.txt and context.env, deletes its tracked PLAN.md, and
  # exits 0. in-progress.sh's clear action states the rule for the same file:
  # has() "is the only check that tells a deleted key apart from one left empty
  # or null — which is the entire failure mode". So ANY present key — null, {},
  # or fully populated — is a live migration for the purposes of this refusal.
  # The per-FIELD reads below stay value reads: those want the value, and an
  # absent field legitimately reads as empty (Phase 4 omits branch: under
  # --no-branch, which is exactly why the presence decision cannot key on it).
  #
  # Fail CLOSED on a manifest yq cannot read: this check and check 6's sweep
  # guard both reason from it, and a parse error rounded to "no migration" would
  # sweep the run's state (PLAN.md, context.env, qa-ledger) below. "Manifest
  # absent" is fine (bootstrap); "manifest present but unreadable" never is.
  #
  # BOTH source keys are read, and both reads are fail-closed for the same reason.
  # The two blocks are mutually exclusive live runs (see the WHY in the header):
  # every value below has exactly one answer per component, so a state carrying
  # both is refused here rather than silently resolved to one of them.
  TEMPLATE_IN_PROGRESS=$(yq -r '.template | has("in_progress")' .kairos/manifest.yaml 2>/dev/null) \
    || fail "cannot parse .kairos/manifest.yaml (yq error) — refusing to reason about migration state from an unreadable manifest."
  FRONTEND_IN_PROGRESS=$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml 2>/dev/null) \
    || fail "cannot parse .kairos/manifest.yaml (yq error) — refusing to reason about migration state from an unreadable manifest."
  if [[ "$TEMPLATE_IN_PROGRESS" != false ]] && [[ "$FRONTEND_IN_PROGRESS" != false ]]; then
    fail ".kairos/manifest.yaml carries BOTH template.in_progress and frontend.in_progress. Exactly one migration is live at a time: the two blocks answer the same three questions — which branch the run is on, which target it is heading to, which SHA rolls it back — with different values, and no reader can pick between them. Roll the stale run back with the rollback runbook for the source it belongs to, then re-run."
  fi
  # Which source is live decides which block every field below comes from. The
  # KEY PREFIX is what varies; nothing else about the checks does.
  if [[ "$FRONTEND_IN_PROGRESS" != false ]]; then
    IN_PROGRESS_SOURCE=frontend
    IN_PROGRESS_BLOCK=$FRONTEND_IN_PROGRESS
  else
    IN_PROGRESS_SOURCE=template
    IN_PROGRESS_BLOCK=$TEMPLATE_IN_PROGRESS
  fi
  IPP=".$IN_PROGRESS_SOURCE.in_progress"
  IN_PROGRESS_BRANCH=$(yq -r "$IPP"'.branch // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
  IN_PROGRESS_PREV=$(yq -r "$IPP"'.previous_branch // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
  IN_PROGRESS_TARGET=$(yq -r "$IPP"'.target_sha // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
  # Say WHICH source owns the live run, machine-readably — continue and abort both
  # act on one source's block, and inferring it from the branch name is exactly the
  # guess this line removes. Emitted only when a block exists, so a component with
  # no live migration prints what it always printed.
  [[ "$IN_PROGRESS_BLOCK" = false ]] || echo "IN_PROGRESS_SOURCE=$IN_PROGRESS_SOURCE"
fi
# `!= false`, not `= true`: has() only ever prints one of the two, and an
# unreadable manifest already failed above — but if a future yq ever printed
# something else, "I could not tell" must land on the REFUSING side, never on the
# sweeping one. Same disposition in-progress.sh's clear applies to its own read.
on_migration_branch=false
if [[ -n "$IN_PROGRESS_BRANCH" ]] && [[ "$CURRENT" = "$IN_PROGRESS_BRANCH" ]]; then
  on_migration_branch=true
elif [[ -z "$IN_PROGRESS_BRANCH" ]] && [[ "$IN_PROGRESS_BLOCK" != false ]] \
     && [[ -n "$IN_PROGRESS_PREV" ]] && [[ "$CURRENT" = "$IN_PROGRESS_PREV" ]]; then
  # Phase 4 omits branch: under --no-branch — the migration then lives on the
  # branch it started from, recorded as previous_branch. Being back on it with
  # the block present IS being on the migration branch.
  on_migration_branch=true
else
  case "$CURRENT" in
    topic/*/template-update-*|topic/*/frontend-update-*) on_migration_branch=true ;;
  esac
fi
if [[ "${MODE:-fresh}" != "continue" ]]; then
  if [[ "$on_migration_branch" = true ]] && [[ "$IN_PROGRESS_BLOCK" != false ]]; then
    fail "already on $CURRENT and a migration is in progress. Run with continue/abort or switch branches first. (live source: $IN_PROGRESS_SOURCE)"
  fi
  if [[ "$on_migration_branch" = true ]] && [[ "$RUN_SOURCE" = frontend ]]; then
    # THE CHAINED CASE, and it is a legitimate state — not the crash window below.
    # A frontend run that follows a finished template run keeps that run's branch on
    # purpose (one PR carries both, PRD story 12): Phase 8 cleared template.in_progress,
    # the consent step got a yes, and the fresh-mode Phase 1 re-entry therefore lands on
    # a migration-shaped branch with NO live block. Same shape for a frontend-only
    # invocation started while standing on a finished migration branch.
    #
    # Only the BLOCK-LESS shape is accepted here. A live block of either source still
    # takes the refusal above: "one migration at a time" is unchanged by chaining, and
    # that is the check this arm must not weaken.
    echo "INFO: on migration-shaped branch $CURRENT with no in-progress block, and this invocation is a frontend run — accepted as the chained/frontend re-entry (the template run finished and cleared its block; the frontend run continues on the same branch so one PR carries both). Recorded on the run-context anchor as RUN_SOURCE=frontend." >&2
  elif [[ "$on_migration_branch" = true ]]; then
    # Block-less crash window: Phase 4 created the branch and died before writing
    # the in-progress block, so there is no recorded run for continue or abort to
    # act on. The only working remedy is to leave the branch behind by hand.
    fail "already on migration branch $CURRENT, but .kairos/manifest.yaml records no migration in progress (Phase 4 died between creating the branch and writing the in-progress block) — nothing to continue or abort: switch off the branch and delete it (git checkout <your-branch> && git branch -D $CURRENT), then re-run. If this is instead a FRONTEND run chaining onto a FINISHED template run's branch, re-run pre-flight with RUN_SOURCE=frontend, which is what tells the two states apart."
  fi
  # Fresh over a LIVE run, from anywhere. The block suppresses check 6's sweep,
  # so without this a fresh run on an unrelated branch inherits the live run's
  # $RUN wholesale — stale qa-ledger answers, spawns, context.env values — and
  # nothing downstream can tell they belong to another migration. No override
  # flag: the escape hatch is abort, which exists precisely for this.
  if [[ "$IN_PROGRESS_BLOCK" != false ]]; then
    fail "a $IN_PROGRESS_SOURCE migration to ${IN_PROGRESS_TARGET:-<unrecorded target>} is in progress (branch ${IN_PROGRESS_BRANCH:-${IN_PROGRESS_PREV:-unknown}}) — say 'continue' to resume it or 'abort' to roll it back before starting fresh"
  fi
else
  # CONTINUE MODE pays none of the refusals above — a resume is standing on the
  # migration branch over a live block by design. But one of check 3's facts still
  # has to be honoured here: WHICH SOURCE the live run belongs to. The live block IS
  # the run's source (SKILL.md → Run-context anchor), and a caller-supplied
  # RUN_SOURCE that contradicts it is recorded onto the anchor by check 9 —
  # last-write-wins — so the resumed run takes the WRONG arm (wrong target chain,
  # wrong upgrade-file directory, wrong gate cwd) all the way to Phase 8, where the
  # advance step's cross-check is the first thing that notices. Fail closed instead,
  # while nothing has been recorded. Only when BOTH are known: an unset RUN_SOURCE on
  # a resume is the ordinary case (continue derives it from the block), and a resume
  # with no live block is continue.md's own lost-block triage, not this check's.
  if [[ -n "$RUN_SOURCE" ]] && [[ "$IN_PROGRESS_BLOCK" != false ]] \
     && [[ "$RUN_SOURCE" != "$IN_PROGRESS_SOURCE" ]]; then
    fail "MODE=continue with RUN_SOURCE=$RUN_SOURCE, but the live migration is a $IN_PROGRESS_SOURCE run ($IN_PROGRESS_SOURCE.in_progress is the block on disk). The live block IS the run's source, so these cannot both be right: resume WITHOUT RUN_SOURCE (continue derives it from the block), or pass RUN_SOURCE=$IN_PROGRESS_SOURCE. Nothing was recorded — a contradicting value would land on the run-context anchor and the resume would take the wrong arm (wrong target chain, wrong upgrade-file directory, wrong gate cwd) until Phase 8."
  fi
fi

# --- 4. Component metadata present OR bootstrap will run ---------------------
[[ -f .kairos/manifest.yaml ]] \
  || echo "INFO: no .kairos/manifest.yaml found. Bootstrap will run in Phase 2." >&2

# --- 5. Ignore the state dir before it exists --------------------------------
# Check 6 creates the state dir and clones tens of MB of git objects into it.
# Un-ignored, that floods `git status` for the entire run (users reasonably ask
# where the bare clones' hooks/*.sample files came from).
#
# .git/info/exclude, not .gitignore: this is local scratch, and editing a
# tracked file here would dirty the working tree check 1 just demanded be clean
# — leaving a stray edit to unwind on abort, and blocking a re-run after a later
# check fails. Phase 4 still adds the durable, shared .gitignore entry.
EXCLUDE="$(git rev-parse --git-dir)/info/exclude"
mkdir -p "$(dirname "$EXCLUDE")"
grep -qxF '.kairos/migration/state/' "$EXCLUDE" 2>/dev/null \
  || printf '\n%s\n' '.kairos/migration/state/' >> "$EXCLUDE"

# --- 6. Sweep stale state from prior runs ------------------------------------
# One migration runs per repo at a time, so .kairos/migration/ is a single
# fixed dir (state/ scratch + the committed PLAN.md). In fresh mode any leftover
# is from a completed or crashed prior run — remove it so we start clean. Never
# sweep while a migration is in progress: continue needs PLAN.md + state/, and
# the in_progress BLOCK in the manifest is the guard — the block's existence,
# NOT its branch: field, which Phase 4 deliberately omits under --no-branch.
# Keying on the field would read a live --no-branch migration as "no migration"
# and destroy exactly the state continue needs (PLAN.md, context.env,
# qa-ledger.tsv, the test baseline) on any fresh re-invocation.
#
# We SPARE all THREE mirror clones — the template at $RUN/template, the
# kairos-component-common mirror at $RUN/common, and the frontend source's at
# $RUN/frontend: they are expensive to rebuild and safe to reuse — git objects are
# immutable, and each is refreshed in place on the next run (check 7 for the template;
# check 8.6 for the frontend; clone-common.sh's `remote update
# --prune`, which also clears and re-clones a partial mirror). The frontend mirror
# joined the list when check 8.6 started establishing it: sweeping it made the
# reuse/refresh arm here and in materialize-frontend.sh unreachable, so every frontend
# run re-cloned the whole monorepo. Everything else
# under .kairos/migration is regenerated per run, so it goes.
# Check 3 already refused an unparseable manifest, but the sweep is the
# destructive step — keep this read fail-closed in its own right.
#
# has(), the same PRESENCE read check 3 uses and for the same reason (its comment
# carries the full rationale): `.template.in_progress // ""` cannot tell a DELETED
# key from one left null, so a null-valued block read as "no migration" here and
# the sweep below then destroyed the live run's state with exit 0. The block's
# EXISTENCE is the guard — not its branch: field, which Phase 4 deliberately omits
# under --no-branch, and not its value, which a hand-edit can empty.
# EITHER source key, for the same reason check 3 reads both: a live frontend run
# owns $RUN exactly as a template one does, and a sweep that only looked at
# `.template` would destroy a frontend run's PLAN.md and context.env on the next
# invocation. Two separate fail-closed reads, not check 3's values re-used — this
# is the destructive step and it stays independently guarded.
IN_PROGRESS=false
if [[ -f .kairos/manifest.yaml ]]; then
  for k in template frontend; do
    HAS_K=$(yq -r ".$k"' | has("in_progress")' .kairos/manifest.yaml 2>/dev/null) \
      || fail "cannot parse .kairos/manifest.yaml — a live migration must never read as 'no migration'; refusing to sweep."
    [[ "$HAS_K" = false ]] || IN_PROGRESS=$HAS_K
  done
fi
# Only the gitignored $RUN scratch is swept here — it is safe to remove before a
# later fail-able check. The TRACKED, committed PLAN.md is swept separately in
# check 10, past every check that can still `fail`: deleting it here and then
# failing check 7/9 would leave a tracked deletion that check 1 refuses on the
# next fresh re-run, wedging the documented clean re-run.
if [[ "${MODE:-fresh}" != "continue" ]] && [[ "$IN_PROGRESS" = false ]]; then
  # Interlock against a SECOND fresh invocation launched while a first run is
  # still live in Phases 1-3.5. Both refusals above (check 3) and the sweep guard
  # here key on the in-progress BLOCK, which Phase 4 does not write until after
  # all the asking is done — so a run mid-Phase-3.5 has an unpromoted qa-ledger of
  # the user's answers, a model.txt, synthetic trees and a classification, and NO
  # block for continue or abort to recover them from. Without this, the second
  # fresh run sweeps all of it and exits 0; abort's no-block arm then reports "only
  # the ledger" — already deleted. The ledger is the one artifact that exists
  # NOWHERE else (the rest re-derives), so it is the signal: refuse the sweep when
  # a non-empty qa-ledger.tsv sits over a run that never reached Phase 4.
  #
  # "Never reached Phase 4" is read as PREV_SHA absent from context.env: Phase 4
  # anchors PREV_SHA on every path (create / skip-create / --no-branch) BEFORE it
  # writes the block, and Phase 8 re-anchors it — so a FINISHED run's leftover
  # (block cleared, $RUN kept for post-mortem per 8-finalize.md) carries PREV_SHA
  # and sweeps as before, which is the ordinary "start the next migration" path.
  # Only the pre-Phase-4 window has a ledger but no PREV_SHA.
  #
  # A frontend run is exempt: the chained frontend re-entry sweeps the finished
  # template run's $RUN BY DESIGN (RUN_SOURCE=frontend, 8-finalize.md). The escape
  # hatch for a genuinely stale pre-Phase-4 leftover — a crash before Phase 4, or an
  # abort whose no-block arm already salvaged the ledger — is SWEEP_STALE_RUN=1.
  if [[ "$RUN_SOURCE" != frontend ]] && [[ -z "${SWEEP_STALE_RUN:-}" ]] \
     && [[ -s "$RUN/qa-ledger.tsv" ]] \
     && ! grep -qs '^PREV_SHA=' "$RUN/context.env"; then
    fail "a prior run left an unpromoted Q&A ledger under $RUN ($RUN/qa-ledger.tsv holds Phase 3.5 answers) but never reached Phase 4 — no PREV_SHA is anchored and no in-progress block exists, which is the shape of a migration still live in Phases 1-3.5. Its answers exist nowhere else and no block records it for recovery, so sweeping it would discard them silently. Refusing. If a migration is still running (another session), let it finish. Otherwise say 'cancel' / 'undo' to salvage the ledger and roll the run back, or — if you are sure it is stale (a crash before Phase 4, or a rollback that already salvaged it) — re-run with SWEEP_STALE_RUN=1 to sweep it and start fresh."
  fi
  if [[ -d "$RUN" ]]; then
    # Was there real leftover scratch (anything but the spared mirror clones)?
    # Captured BEFORE the sweep so the decision line below announces an actual
    # cleanup, never the template/common/frontend mirror dirs — whose presence
    # alone is not "a prior run's state". This is what lets the orchestrator relay
    # ground truth instead of improvising a fresh-vs-resume theory from a state dir
    # it can still see on disk.
    SWEPT_ANY=$(find "$RUN" -mindepth 1 -maxdepth 1 ! -name template ! -name common ! -name frontend 2>/dev/null | head -1)
    # Checked, like materialize.sh's analogous clear (install_side's CLEAR_ERR/
    # CLEAR_RC): this is the one destructive step whose partial failure the
    # comment above calls out by name — a root-owned leftover from a
    # Docker-based test run (or any other undeletable entry) must not let a
    # fresh run proceed over a stale model.txt (which log-spawn.sh actively
    # ENFORCES), a stale qa-ledger, or a stale context.env. An unchecked
    # `|| true` here used to swallow exactly that.
    SWEEP_ERR=$(find "$RUN" -mindepth 1 -maxdepth 1 ! -name template ! -name common ! -name frontend -exec rm -rf {} + 2>&1)
    SWEEP_RC=$?
    [[ "$SWEEP_RC" -eq 0 ]] \
      || fail "could not sweep stale state from $RUN (exit $SWEEP_RC): $SWEEP_ERR — a partial sweep would let this fresh run proceed over a stale model.txt, qa-ledger, or context.env left by a prior run. Nothing was started; remove the offending path(s) under $RUN by hand (they may need sudo/chmod first) and re-run."
    # Belt-and-suspenders: verify nothing unexpected is still there even when
    # `find`/`rm` reported success — same one-level scope, still sparing
    # template/, common/ and frontend/. A survivor here is the same hazard as a non-zero
    # exit above, so it gets the same refusal shape.
    SWEEP_SURVIVORS=$(find "$RUN" -mindepth 1 -maxdepth 1 ! -name template ! -name common ! -name frontend 2>/dev/null)
    [[ -z "$SWEEP_SURVIVORS" ]] \
      || fail "stale state under $RUN survived the sweep: $(printf '%s' "$SWEEP_SURVIVORS" | tr '\n' ' ') — refusing to start a fresh run over it. Remove the listed path(s) by hand (they may need sudo/chmod first) and re-run."
    # Announce the decision, but ONLY when something was actually removed. Reaching
    # here means checks 3 and 6 found NO live migration — a live in_progress block or a
    # still-live pre-Phase-4 Q&A ledger would have REFUSED above — so this leftover was
    # dead scratch from a finished or crashed run, safe to discard. Saying so gives the
    # orchestrator a fact to relay ("swept dead scratch, this is a fresh run") instead of
    # a theory inferred from the state dir. Silent when there was nothing to sweep, so a
    # first-ever run on a clean component still emits nothing.
    [[ -z "$SWEPT_ANY" ]] \
      || echo "INFO: swept leftover migration scratch under $RUN from a prior (finished or crashed) run — no in-progress block and no live pre-Phase-4 run were found, so this is a FRESH run, not a resume (a live migration would have been refused, not swept). The template/common/frontend mirror clones were kept and are refreshed in place." >&2
  fi
fi
mkdir -p "$RUN"

# --- 7. Template source reachable --------------------------------------------
# Resolve the clone origin — always a path or URL we clone FROM into $CACHE.
# TEMPLATE_PATH (a local git repo) and TEMPLATE_REPO (a remote URL) are both
# valid clone origins; local clones are fast and use hardlinks on the same FS.
if [[ -n "${TEMPLATE_PATH:-}" ]]; then
  # -e, not -d: a linked worktree (and a submodule) presents .git as a FILE
  # pointing at the real gitdir, and `git -C` / `git clone` resolve it from
  # there — the natural co-dev checkout layout is a git repo like any other.
  # The HEAD arm covers a bare clone, which has no .git at all.
  { [[ -e "$TEMPLATE_PATH/.git" ]] || [[ -f "$TEMPLATE_PATH/HEAD" ]]; } \
    || fail "--template-path $TEMPLATE_PATH is not a git repo."
  ORIGIN="$TEMPLATE_PATH"
  # The mirror is cloned FROM this local checkout, so it inherits exactly the refs
  # the checkout last fetched. Bring the checkout current with its own remote first,
  # or a BASE/TARGET released upstream since would be absent from the mirror and
  # Phase 2's rev-parse would refuse two SHAs that are both perfectly good. Only for
  # a local ORIGIN — a URL origin is cloned/updated directly and is already current.
  # Best-effort and non-destructive (see lib/fetch-local-clone.sh).
  fetch_local_clone "$TEMPLATE_PATH" "local template checkout (--template-path)"
else
  ORIGIN="${TEMPLATE_REPO:-$(yq -r '.template.repo // ""' .kairos/manifest.yaml 2>/dev/null || echo "")}"
  # A facade bootstrap with no URL given defaults to the facade template — the
  # canonical component-template URL would score and merge it as a component.
  if [[ -z "$ORIGIN" ]] && [[ ! -f .kairos/manifest.yaml ]] && [[ "$COMPONENT_KIND" = facade ]]; then
    ORIGIN=$FACADE_TEMPLATE_REPO
    TEMPLATE_REPO_DEFAULTED=$ORIGIN
    echo "INFO: facade bootstrap with no TEMPLATE_REPO — defaulting to $ORIGIN" >&2
  fi
  # The two known template repos are not interchangeable. A URL naming the other
  # kind's template is refused here, before bellwether scoring picks a baseline
  # from the wrong history. Forks and local mirrors under other names pass;
  # materialize.sh checks each template tree's go.mod module line either way.
  case "$COMPONENT_KIND:$ORIGIN" in
    facade:*kairos-component-template|facade:*kairos-component-template.git|facade:*kairos-component-template/)
      fail "this component is a facade (template.kind, or .init.mk sets MASTERDATA_INCLUDE_NO_CDC or GENERATE_MODULES without sql/all), but the template repo is $ORIGIN. Facades migrate against $FACADE_TEMPLATE_REPO — re-run with TEMPLATE_REPO set to it (or fix template.repo in .kairos/manifest.yaml)." ;;
    component:*kairos-component-facade-template|component:*kairos-component-facade-template.git|component:*kairos-component-facade-template/)
      fail "the template repo $ORIGIN is the facade template, but this component is not a facade (no template.kind: facade, and .init.mk sets neither MASTERDATA_INCLUDE_NO_CDC nor GENERATE_MODULES without sql/all). Migrate against $COMPONENT_TEMPLATE_REPO." ;;
  esac
  [[ -n "$ORIGIN" ]] \
    || fail "no template repo known. Either .kairos/manifest.yaml is missing template.repo, or this is a bootstrap — determine the repo (ask the user / canonical default) and re-run with TEMPLATE_REPO set."
  # A manifest written before Bitbucket moved SSH to ssh.bitbucket.org names the old
  # host, which no longer serves SSH. Clone from the current host instead; Phase 8's
  # advance writes the same mapping back (see lib/bitbucket-url.sh).
  MAPPED_ORIGIN=$(canonical_ssh_url "$ORIGIN")
  if [[ "$MAPPED_ORIGIN" != "$ORIGIN" ]]; then
    echo "INFO: template repo $ORIGIN names bitbucket.org, which no longer serves SSH — cloning from $MAPPED_ORIGIN" >&2
    ORIGIN=$MAPPED_ORIGIN
  fi
fi

# Two clone origins name the SAME source when they are byte-equal, OR when both
# resolve to the same physical local directory reached by different spellings
# (../tpl vs an absolute path, a trailing slash, a symlinked ancestor). Byte
# equality alone paid a full re-clone on a cosmetic spelling change of a local
# --template-path. Normalization is LOCAL-DIRECTORY ONLY: a URL origin has no
# filesystem to resolve, so `cd` fails on it and the function falls back to the
# byte test already made — a genuinely different origin (or an empty existing
# one) never matches, so the safe direction (re-clone) is preserved.
origins_match() { # origins_match <existing-origin> <new-origin>
  [[ "$1" = "$2" ]] && return 0
  # A mirror cloned from the old Bitbucket SSH host is the same source as one from
  # the current host; reuse_mirror points it at the current host before refreshing.
  [[ "$(canonical_ssh_url "$1")" = "$(canonical_ssh_url "$2")" ]] && return 0
  local a b
  a=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  b=$(cd "$2" 2>/dev/null && pwd -P) || return 1
  [[ -n "$a" ]] && [[ "$a" = "$b" ]]
}

reclone() {
  rm -rf "$CACHE"
  # --mirror (not --bare) configures a +refs/*:refs/* fetch refspec, so the
  # reuse path below can `remote update` an existing clone to the origin's exact
  # ref state — the canonical local-mirror pattern.
  git clone --mirror "$ORIGIN" "$CACHE" \
    || fail "unable to clone $ORIGIN into $CACHE"
}

# A clone survives here from a prior run in two cases: continue mode (never
# swept) or fresh mode (check 6 spares $RUN/template). Reuse it instead of
# paying a full clone — but ONLY when it mirrors the SAME origin, else a stale
# clone of a different template would silently serve wrong content. A failed
# refresh (corrupt clone, unreachable origin) falls back to a clean re-clone.
# reuse_mirror <mirror> <existing-origin> <origin> — refresh a matched mirror from
# <origin>. Its remote is re-pointed first when the stored spelling differs (an old
# Bitbucket SSH host, a different spelling of the same local directory), so the
# refresh never dials a host that no longer serves SSH.
reuse_mirror() {
  if [[ "$2" != "$3" ]]; then
    git -C "$1" remote set-url origin "$3" 2>/dev/null || return 1
  fi
  git -C "$1" remote update --prune 2>/dev/null
}

if [[ -f "$CACHE/HEAD" ]]; then
  EXISTING_ORIGIN=$(git -C "$CACHE" config --get remote.origin.url 2>/dev/null || echo "")
  if origins_match "$EXISTING_ORIGIN" "$ORIGIN" && reuse_mirror "$CACHE" "$EXISTING_ORIGIN" "$ORIGIN"; then
    echo "INFO: refreshed existing template clone at $CACHE" >&2
  else
    reclone
  fi
else
  reclone
fi

git -C "$CACHE" worktree prune 2>/dev/null || true

# --- 8. Local template intent signal -----------------------------------------
# When migrating against a LOCAL template clone, the strongest statement of
# "migrate against what I have here" is the branch that clone has checked out —
# not main. Emit it as a machine-readable line so Phase 2's default chain can
# prefer it over the manifest branch. Only meaningful for a local path; a remote
# URL has no working checkout. A detached HEAD yields no branch name — emit
# nothing rather than a misleading value, and let Phase 2 fall through the chain.
if [[ -n "${TEMPLATE_PATH:-}" ]]; then
  LOCAL_BRANCH=$(git -C "$TEMPLATE_PATH" symbolic-ref -q --short HEAD 2>/dev/null || echo "")
  [[ -n "$LOCAL_BRANCH" ]] && echo "TEMPLATE_LOCAL_BRANCH=$LOCAL_BRANCH"

  # Migration collects from the mirror CLONE, which only carries COMMITTED history.
  # A dirty local template working tree is therefore invisible to the whole run —
  # warn loudly, but never block: co-dev authors edit here on purpose. Skip for a
  # bare clone (no working tree, so "dirty" is meaningless).
  if [[ "$(git -C "$TEMPLATE_PATH" rev-parse --is-bare-repository 2>/dev/null)" != true ]] \
     && [[ -n "$(git -C "$TEMPLATE_PATH" status --porcelain 2>/dev/null)" ]]; then
    echo "WARNING: local template $TEMPLATE_PATH has uncommitted changes — they never reach the mirror clone and are INVISIBLE to this migration. Commit them first if they should be included." >&2
  fi
fi

# --- 8.5 Frontend source — the second upgrade source -------------------------
# `web/` is a template-shaped upgrade source with its own repo, its own SHAs and
# its own run. Everything this block emits is a fact about that source, learned
# here so the consent step and Phase 2's frontend target chain never re-derive it
# from conversation memory (the context.env rule: the script that learns a value
# records it).
#
# SILENCE IS A FEATURE. A component with no `frontend:` block and no `web/package.json` emits
# nothing and records nothing — a backend-only component must see zero new lines
# and zero new prompts out of any of this.
# Captured BEFORE the manifest read below overwrites the variable: FRONTEND_REPO is
# also an env override, TEMPLATE_REPO's analog, and for the same reason — a legacy
# component bootstrapping its frontend baseline has no `frontend:` block to read the
# URL from, so check 8.6 would have no clone origin at all. It only ever FILLS A GAP
# here (the manifest's recorded repo is the component's provenance and wins), which is
# the one difference from TEMPLATE_REPO.
FRONTEND_REPO_ENV=$(canonical_ssh_url "${FRONTEND_REPO:-}")
FRONTEND_BLOCK=false
FRONTEND_REPO=""; FRONTEND_SHA=""; FRONTEND_BRANCH=""
FRONTEND_TEMPLATE=""; FRONTEND_MOUNT=""; FRONTEND_MODULE_PATH=""
FRONTEND_BOOTSTRAP=""
if [[ -f .kairos/manifest.yaml ]]; then
  FRONTEND_BLOCK=$(yq -r 'has("frontend")' .kairos/manifest.yaml 2>/dev/null) \
    || fail "cannot parse .kairos/manifest.yaml (yq error) — refusing to reason about the frontend source from an unreadable manifest."
fi
if [[ "$FRONTEND_BLOCK" = true ]]; then
  FRONTEND_REPO=$(yq -r '.frontend.repo // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
  # Same mapping as check 7's template origin: the old Bitbucket host no longer serves
  # SSH. The mapped value is what is emitted, cloned and (Phase 8) written back.
  MAPPED_FRONTEND_REPO=$(canonical_ssh_url "$FRONTEND_REPO")
  if [[ "$MAPPED_FRONTEND_REPO" != "$FRONTEND_REPO" ]]; then
    echo "INFO: frontend repo $FRONTEND_REPO names bitbucket.org, which no longer serves SSH — using $MAPPED_FRONTEND_REPO" >&2
    FRONTEND_REPO=$MAPPED_FRONTEND_REPO
  fi
  FRONTEND_SHA=$(yq -r '.frontend.sha // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
  FRONTEND_BRANCH=$(yq -r '.frontend.branch // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
  # The module KEY, not a path: it selects the entry in the source repo's
  # .kairos-updates/config.yaml that supplies the subtree, the upgrade-file
  # directory and the bellwethers. Nothing here assumes `react`.
  FRONTEND_TEMPLATE=$(yq -r '.frontend.template // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
  FRONTEND_MODULE_PATH=$(yq -r '.frontend.path // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
  # `mount:` is optional and defaults to `web/`. The default is materialized HERE,
  # once, so no later reader has to remember it — and none can default it
  # differently.
  FRONTEND_MOUNT=$(yq -r '.frontend.mount // "web/"' .kairos/manifest.yaml 2>/dev/null || echo "web/")
  echo "FRONTEND_REPO=$FRONTEND_REPO"
  echo "FRONTEND_SHA=$FRONTEND_SHA"
  echo "FRONTEND_BRANCH=$FRONTEND_BRANCH"
  echo "FRONTEND_TEMPLATE=$FRONTEND_TEMPLATE"
  echo "FRONTEND_MODULE_PATH=$FRONTEND_MODULE_PATH"
  echo "FRONTEND_MOUNT=$FRONTEND_MOUNT"
elif [[ -f web/package.json ]]; then
  # `web/package.json`, not `web/`: both template refs ship a backend-only `web/`
  # shell (Dockerfile, configs/, entrypoint/) with no package.json, and a mounted
  # frontend always carries one. A bare `web/` is that shell — silence, not a
  # candidate (asking would then hard-fail at Phase 4.5 on the missing package.json).
  # A pre-existing component: `web/` is there but no baseline was ever recorded, so
  # a frontend run has to BOOTSTRAP one (score, show, confirm once) the way the
  # template does. Reported as a CANDIDATE, never assumed — nothing here starts a
  # run, and the consent step still asks.
  FRONTEND_BOOTSTRAP=web/
  echo "FRONTEND_BOOTSTRAP=$FRONTEND_BOOTSTRAP"
  echo "INFO: web/package.json is present but .kairos/manifest.yaml records no frontend: block — a frontend run would bootstrap its baseline in Phase 2." >&2
fi

# --frontend-path: an author's local checkout of the frontend source repo,
# --template-path's analog. It is NORMALIZED to the enclosing git toplevel,
# because the module subtree is not a git repo of its own — the history, the
# .kairos-updates/config.yaml and the per-module upgrade-files all live at the
# repo root, so a path at `template/react` and a path at the root must resolve to
# the same clone origin.
FRONTEND_LOCAL_BRANCH=""
if [[ -n "${FRONTEND_PATH:-}" ]]; then
  [[ -d "$FRONTEND_PATH" ]] || fail "--frontend-path $FRONTEND_PATH is not a directory."
  FRONTEND_TOPLEVEL=$(git -C "$FRONTEND_PATH" rev-parse --show-toplevel 2>/dev/null || echo "")
  [[ -n "$FRONTEND_TOPLEVEL" ]] \
    || fail "--frontend-path $FRONTEND_PATH is not inside a git work tree. It must be a checkout of the frontend source repo — its root, or any path inside it. A bare or mirror clone has no work tree and cannot be normalized. The module subtree is not a repo of its own: the git history, .kairos-updates/config.yaml and the per-module upgrade-files all live at the repo root."
  # `pwd -P`, not `pwd`: `git rev-parse --show-toplevel` prints the PHYSICAL path,
  # so a logical cwd carrying a symlinked ancestor (/var -> /private/var on macOS,
  # any symlinked checkout root elsewhere) would never compare equal to it — the
  # given root would be misread as a subtree, and the module-mismatch warning below
  # would fire against a path that is not a subtree at all.
  FRONTEND_PATH_ABS=$(cd "$FRONTEND_PATH" && pwd -P)
  if [[ "$FRONTEND_PATH_ABS" != "$FRONTEND_TOPLEVEL" ]]; then
    FRONTEND_PATH_SUBTREE=${FRONTEND_PATH_ABS#"$FRONTEND_TOPLEVEL"/}
    echo "INFO: --frontend-path $FRONTEND_PATH normalized to the enclosing git toplevel $FRONTEND_TOPLEVEL (the given path was the subtree $FRONTEND_PATH_SUBTREE)." >&2
    # The one mistake normalization would otherwise HIDE: a subtree that is not the
    # module this component was built from. The run uses the manifest's module
    # either way, so say so rather than migrating against a module the author was
    # not looking at.
    if [[ -n "$FRONTEND_MODULE_PATH" ]] \
       && [[ "${FRONTEND_PATH_SUBTREE%/}" != "${FRONTEND_MODULE_PATH%/}" ]]; then
      echo "WARNING: --frontend-path pointed at the subtree '$FRONTEND_PATH_SUBTREE', but this component's manifest selects module '${FRONTEND_TEMPLATE:-<unset>}' at path '$FRONTEND_MODULE_PATH'. The run uses the MANIFEST's module — frontend.template is what selects it. Point at the repo root, or fix the module, if you meant the other one." >&2
    fi
  fi
  FRONTEND_PATH=$FRONTEND_TOPLEVEL
  echo "FRONTEND_PATH=$FRONTEND_PATH"
  # The local checkout's checked-out branch is the strongest statement of "migrate
  # against what I have here" — Phase 2's frontend target chain prefers it over the
  # manifest branch, exactly as TEMPLATE_LOCAL_BRANCH works for the template. A
  # detached HEAD yields nothing rather than a misleading value.
  FRONTEND_LOCAL_BRANCH=$(git -C "$FRONTEND_PATH" symbolic-ref -q --short HEAD 2>/dev/null || echo "")
  [[ -n "$FRONTEND_LOCAL_BRANCH" ]] && echo "FRONTEND_LOCAL_BRANCH=$FRONTEND_LOCAL_BRANCH"
  if [[ -n "$(git -C "$FRONTEND_PATH" status --porcelain 2>/dev/null)" ]]; then
    echo "WARNING: local frontend $FRONTEND_PATH has uncommitted changes — they never reach the mirror clone and are INVISIBLE to this migration. Commit them first if they should be included." >&2
  fi
fi

# --- 8.6 The frontend mirror — established HERE, on a frontend run -------------
# WHY pre-flight and not materialize: three consumers need the mirror BEFORE Phase 2.5
# ever runs, and none of them can build it. Phase 2's frontend arm validates BASE and
# the resolved target against it; the frontend bootstrap scores the mount against
# candidate commits in it; Phase 3's frontend classification walks the module's
# upgrade-file history in it. All three used to be pointed at $CACHE — the TEMPLATE
# mirror — where a frontend SHA resolves to nothing and the walk finds no upgrade-files,
# so the run refused (or, worse, reported an empty range) with a message about SHAs
# that were perfectly good. One mirror, established once, recorded on the anchor as
# FRONTEND_CACHE, at the same conventional location materialize-frontend.sh defaults to
# ($RUN/frontend) and spared by check 6's sweep exactly as $RUN/template is.
#
# A TEMPLATE run pays none of this and emits nothing: the frontend source is not its
# source, and cloning a monorepo it will never read is pure cost.
FRONTEND_CACHE=""
if [[ "$RUN_SOURCE" = frontend ]]; then
  # Origin, in the order of decreasing directness: the local checkout the author
  # pointed at, then the component's recorded repo, then the env override that exists
  # for the bootstrap case (no block yet, so no recorded repo).
  FE_ORIGIN=${FRONTEND_PATH:-}
  [[ -n "$FE_ORIGIN" ]] || FE_ORIGIN=$FRONTEND_REPO
  if [[ -z "$FE_ORIGIN" ]] && [[ -n "$FRONTEND_REPO_ENV" ]]; then
    FE_ORIGIN=$FRONTEND_REPO_ENV
    FRONTEND_REPO=$FRONTEND_REPO_ENV
    echo "FRONTEND_REPO=$FRONTEND_REPO"
    echo "INFO: no frontend.repo recorded in .kairos/manifest.yaml — using the FRONTEND_REPO passed to this run as the frontend source (this is the bootstrap case; Phase 2's frontend bootstrap records it in the manifest)." >&2
  fi
  [[ -n "$FE_ORIGIN" ]] \
    || fail "this is a frontend run (RUN_SOURCE=frontend) but there is no frontend source to clone: no --frontend-path, no frontend.repo in .kairos/manifest.yaml, and no FRONTEND_REPO passed. A frontend run reads its BASE, its target and its module's upgrade-files from that repo's mirror, so one of the three has to name it."
  # When the origin is the author's LOCAL checkout (--frontend-path), the frontend
  # mirror inherits exactly the refs that checkout last fetched — the same stale-clone
  # trap as check 7's template mirror. Bring it current first so a BASE/TARGET released
  # upstream since resolves. Only for the local case: a URL origin is cloned directly
  # and is already current. Best-effort and non-destructive (see lib/fetch-local-clone.sh).
  [[ -n "${FRONTEND_PATH:-}" ]] \
    && fetch_local_clone "$FRONTEND_PATH" "local frontend checkout (--frontend-path)"
  FRONTEND_CACHE=$RUN/frontend
  fe_reclone() {
    rm -rf "$FRONTEND_CACHE"
    # --mirror, like check 7's: the +refs/*:refs/* refspec is what makes the refresh
    # path below exact.
    git clone --mirror "$FE_ORIGIN" "$FRONTEND_CACHE" \
      || fail "unable to clone the frontend source $FE_ORIGIN into $FRONTEND_CACHE"
  }
  if [[ -f "$FRONTEND_CACHE/HEAD" ]]; then
    # Same rule as check 7's, and for the same two reasons: a mirror left by an earlier
    # run does not carry commits pushed since, and a mirror of a DIFFERENT origin would
    # serve another repo's commits under this run's SHAs.
    FE_EXISTING=$(git -C "$FRONTEND_CACHE" config --get remote.origin.url 2>/dev/null || echo "")
    if origins_match "$FE_EXISTING" "$FE_ORIGIN" && reuse_mirror "$FRONTEND_CACHE" "$FE_EXISTING" "$FE_ORIGIN"; then
      echo "INFO: refreshed existing frontend mirror at $FRONTEND_CACHE" >&2
    else
      fe_reclone
    fi
  else
    fe_reclone
  fi
  git -C "$FRONTEND_CACHE" worktree prune 2>/dev/null || true
  echo "FRONTEND_CACHE=$FRONTEND_CACHE"
fi

# --- 9. Record run context -----------------------------------------------------
# Runs AFTER the fresh-mode sweep (check 6), so the sweep can never delete what
# this run just recorded. context.env is the run-context anchor (SKILL.md): a
# compacted session re-reads it instead of trusting conversation memory.
# ($HERE is resolved once just after check 0's tool probes, where it also sources
# lib/fetch-local-clone.sh; the record-context call below reuses it.)
# TEMPLATE_PATH is recorded too — this script learns it, so this script records
# it (the context.env rule). Phase 3.5's wrong-target-check.sh reads it from
# context.env, never from conversation memory: a value that lives only in chat
# disarms that tripwire after any compaction or resume.
#
# SKILL_DIR follows the same rule and is the one value EVERY later phase needs:
# every phase code block invokes "$SKILL_DIR/scripts/...", and after a compaction
# the orchestrator has nothing left to derive that path from — the skill was loaded
# turns ago. This script is the first one to run and knows the path from its own
# location, so it is the recorder. Absolute (via HERE, already resolved), because
# phases run from the component root while a subagent's cwd is its own.
set -- "CACHE=$CACHE" "SKILL_DIR=$(dirname "$HERE")"
# RUN_SOURCE, when the invocation declared one: this script is the first to know
# which source is being migrated (checks 0b and 3 already acted on it), so it is
# the recorder — Phase 2's own write of the same key is then an idempotent
# re-statement rather than the first record. Recorded ONLY when it was given:
# absence keeps a template run's context.env byte-identical to what it always
# was, and Phase 2 anchors the value for those runs as before.
[[ -n "$RUN_SOURCE" ]] && set -- "$@" "RUN_SOURCE=$RUN_SOURCE"
[[ -n "${TEMPLATE_PATH:-}" ]] && set -- "$@" "TEMPLATE_PATH=$TEMPLATE_PATH"
[[ -n "${LOCAL_BRANCH:-}" ]] && set -- "$@" "TEMPLATE_LOCAL_BRANCH=$LOCAL_BRANCH"
# The frontend source's facts, on the same rule and for the same reason: the
# consent step, Phase 2's frontend target chain and the frontend materialize all
# run in later tool calls, and a value that lives only in this stdout is gone the
# moment the orchestrator's shell exits. Recorded ONLY when there is a frontend
# source at all — absence stays the record of "this component has none".
[[ -n "${FRONTEND_PATH:-}" ]] && set -- "$@" "FRONTEND_PATH=$FRONTEND_PATH"
[[ -n "${FRONTEND_LOCAL_BRANCH:-}" ]] && set -- "$@" "FRONTEND_LOCAL_BRANCH=$FRONTEND_LOCAL_BRANCH"
if [[ "$FRONTEND_BLOCK" = true ]]; then
  set -- "$@" "FRONTEND_REPO=$FRONTEND_REPO" "FRONTEND_SHA=$FRONTEND_SHA" \
    "FRONTEND_BRANCH=$FRONTEND_BRANCH" "FRONTEND_TEMPLATE=$FRONTEND_TEMPLATE" \
    "FRONTEND_MODULE_PATH=$FRONTEND_MODULE_PATH" "FRONTEND_MOUNT=$FRONTEND_MOUNT"
fi
[[ -n "$FRONTEND_BOOTSTRAP" ]] && set -- "$@" "FRONTEND_BOOTSTRAP=$FRONTEND_BOOTSTRAP"
# The bootstrap case's repo: no `frontend:` block to read it from, so the value came
# from the env override in check 8.6 and this script is still the one that learned it.
# (With a block, the loop above already recorded the manifest's own value.)
[[ "$FRONTEND_BLOCK" = true ]] || [[ -z "$FRONTEND_REPO" ]] || set -- "$@" "FRONTEND_REPO=$FRONTEND_REPO"
# The frontend mirror, on a frontend run only — the key Phase 2's SHA validation, the
# frontend bootstrap's scoring, Phase 3's module-scoped history walk and Phase 8's
# parity basis all read instead of $CACHE (the TEMPLATE mirror).
[[ -z "$FRONTEND_CACHE" ]] || set -- "$@" "FRONTEND_CACHE=$FRONTEND_CACHE"
RUN="$RUN" "$HERE/record-context.sh" "$@" \
  || fail "could not record run context in $RUN/context.env"

# --- 10. Sweep the tracked PLAN.md — only now, past every fail-able check ------
# Deferred out of check 6's fresh-mode sweep because PLAN.md is a TRACKED,
# committed file. Every check above can still `fail` (check 7's clone, check 9's
# context.env write); deleting the tracked file before one of them fails would
# leave a tracked deletion in the working tree, which check 1's clean-tree gate
# then refuses on the next fresh run with "working tree is dirty" — wedging a
# clean re-run the user never dirtied. Nothing between check 6 and here reads
# PLAN.md, so removing it now is equivalent except that it happens only once
# pre-flight is certain to succeed. Same fresh-mode guard as check 6 — never
# delete a live/continue run's PLAN.md, which continue needs.
if [[ "${MODE:-fresh}" != "continue" ]] && [[ "$IN_PROGRESS" = false ]]; then
  rm -f .kairos/migration/PLAN.md 2>/dev/null || true
fi

echo "OK: pre-flight passed" >&2
echo "RUN=$RUN"
echo "CACHE=$CACHE"
if [[ "$COMPONENT_KIND" = facade ]]; then echo "COMPONENT_KIND=facade"; fi
if [[ -n "${TEMPLATE_REPO_DEFAULTED:-}" ]]; then echo "TEMPLATE_REPO=$TEMPLATE_REPO_DEFAULTED"; fi
exit 0
