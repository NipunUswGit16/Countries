#!/usr/bin/env bash
# clone-common.sh — mirror-clone the kairos-component-common repo (the shared Go
# libraries the component consumes) into the migration state dir, so Phase 3.5
# can collect its consumer-facing upgrade-files.
#
# The module-path prefix is the canonical bitbucket.org/ifs-pd/kairos-component-common
# (also derivable as the shared prefix of the require'd common modules in go.mod);
# the clone URL follows from it. If go.mod requires no module under that prefix,
# there are no common upgrades to collect — the clone is skipped cleanly.
#
# WHY A MISSING OR UNREADABLE go.mod IS A HARD FAILURE and not that same clean skip:
# the probe was `grep -qF … go.mod 2>/dev/null`, which cannot tell "this component
# consumes no common module" (grep exit 1) from "there is no go.mod here" or "I could
# not read it" (grep exit 2, stderr discarded). Both took the none path and recorded
# COMMON_MODULES=none — a POSITIVELY worded INFO ("go.mod requires no module under
# <prefix>") about a file that was never read — and that key is durable: Phase 3.5
# skips collection entirely on it, so collect-common.sh's own go.mod hard-error
# guards never run and plan-completeness accepts the run. Every common-side gate in
# the migration turns off at once, on the strength of a file nobody opened. This is a
# Go component migration: go.mod must exist and be readable, so only a go.mod that
# was actually READ and did not match records `none`.
#
# WHY a failed clone degrades to a skip instead of a broken cache: leaving
# COMMON_CACHE pointing at a half-cloned dir would make collect-common.sh mark
# every module 'unresolvable' (missing tag) and flood Phase 3.5 with false
# prompts. So the cache line is only emitted when the mirror actually exists.
#
# WHY COMMON_MODULES is a separate key from COMMON_CACHE: an unset COMMON_CACHE
# means two different things — "there is nothing to collect" and "the mirror is
# unusable" — and Phase 3.5 must treat them differently (skip the phase entirely
# vs. run collection anyway and let it record one honest skip-no-cache row per
# module). COMMON_MODULES carries the fact Phase 3.5 actually branches on, so
# neither case has to be inferred from the absence of the other key.
#
# WHY A FRONTEND RUN RECORDS NOTHING AT ALL (not even `none`): common is a
# Go-library dependency of the component, not of a frontend module, and Phase 3.5
# is idle on that arm — so on a frontend run the anchor's RUN_SOURCE=frontend
# takes an early exit 0 that emits and records NOTHING. The absence of every
# COMMON_* key is the record (SKILL.md — legitimately absent keys). Recording
# COMMON_MODULES=present on that arm is not a harmless extra fact: it arms
# plan-completeness.sh's common-upgrades check against a phase that correctly
# never runs, and the run deadlocks at Phase 6 with a remedy ("re-run Phase 3.5")
# that Phase 3.5's frontend arm explicitly forbids.
#
# Env in:  RUN               migration state dir (required; RUN_SOURCE is read
#                            from $RUN/context.env — `frontend` takes the N/A
#                            skip above, anything else means template)
#          COMMON_REPO_PATH  optional — module-path prefix override
#                            (default bitbucket.org/ifs-pd/kairos-component-common)
#          COMMON_CLONE_URL  optional — clone URL override (default
#                            https://$COMMON_REPO_PATH.git); exists for hermetic
#                            tests and local mirrors
# Cwd:     component root (reads go.mod — required, see above)
# Stdout:  COMMON_REPO_PATH=<prefix>       on every template-run exit-0 path
#          COMMON_MODULES=none|present     on every template-run exit-0 path —
#                                          `none` only when a go.mod that WAS READ
#                                          requires no module under
#                                          COMMON_REPO_PATH (an unreadable
#                                          go.mod exits 1 and records nothing)
#          COMMON_CACHE=<dir>              only when the mirror exists and is usable
#          (a frontend run emits none of the three — INFO on stderr only)
# Artifacts: the same three keys upserted into $RUN/context.env (record-context.sh);
#          nothing on a frontend run
# Exit:    0 — a non-consuming component, a failed clone, or a frontend run's
#          not-applicable skip is a clean skip (WARN/INFO on stderr), never a stop
#          1 — go.mod is absent or unreadable: the one input this script cannot
#              answer any question about, and the answer it used to invent
#              (COMMON_MODULES=none) disables the whole common side of the migration
set -u

fail() { echo "FAIL: $*" >&2; exit 1; }

: "${RUN:?FAIL: RUN not set}"
COMMON_REPO_PATH=${COMMON_REPO_PATH:-bitbucket.org/ifs-pd/kairos-component-common}
COMMON_CLONE_URL=${COMMON_CLONE_URL:-https://$COMMON_REPO_PATH.git}
COMMON_CACHE=$RUN/common
HERE=$(cd "$(dirname "$0")" && pwd)

# The frontend N/A skip comes FIRST — before any Go question is asked. A frontend
# run has no common side (see header), so it must not hard-fail on go.mod shapes
# and must not record a single COMMON_* key: absence is the record. Bare read —
# RUN_SOURCE unset or an absent anchor means template, matching pre-flight's
# default; `tail -1` matches every other last-write-wins reader of the anchor.
RUN_SOURCE=""
[[ -f "$RUN/context.env" ]] \
  && RUN_SOURCE=$(sed -n 's/^RUN_SOURCE=//p' "$RUN/context.env" | tail -1)
if [[ "$RUN_SOURCE" = frontend ]]; then
  echo "INFO: frontend run (RUN_SOURCE=frontend on the anchor) — the common side is not applicable: nothing cloned, no COMMON_* key emitted or recorded" >&2
  exit 0
fi

# go.mod must be READ before COMMON_MODULES can be recorded — see the header: the
# `none` value turns off every common-side gate downstream, so it may only ever be
# the answer of a file that was actually opened. Each shape gets its own sentence,
# matching collect-common.sh's go.mod guards (an operator pointed at a DIRECTORY was
# sent off to check permissions by a single "not readable" for everything). Checked
# BEFORE the first context.env write, so a refusal writes no state at all.
[[ -e go.mod ]] \
  || fail "no go.mod in $(pwd) — this is a Go component migration, so go.mod must exist; refusing to record COMMON_MODULES=none (which would silently disable common-library collection for the whole run)"
[[ -d go.mod ]] \
  && fail "go.mod is a directory in $(pwd), not a file — refusing to record COMMON_MODULES=none from a file that cannot be read"
[[ -f go.mod ]] && [[ -r go.mod ]] \
  || fail "go.mod is not readable in $(pwd) — refusing to record COMMON_MODULES=none from a file that cannot be read (check its permissions)"

echo "COMMON_REPO_PATH=$COMMON_REPO_PATH"
# Recorded into the run-context anchor so a compacted session re-reads it from
# disk rather than conversation memory (SKILL.md — Run-context anchor).
RUN="$RUN" "$HERE/record-context.sh" "COMMON_REPO_PATH=$COMMON_REPO_PATH"

# COMMON_MODULES is emitted on BOTH paths — it is the only durable record of
# whether there is anything to collect, and Phase 3.5 branches on it rather than
# on the presence of COMMON_CACHE.
# -F: the prefix is a path, not a pattern. Unescaped, its dots match any char, so
# a require on `exampleXcom/...` would read as a consumer of `example.com/...`.
#
# grep's exit status is read in THREE ways, not two: 0 match, 1 no match, >1 error.
# The guards above rule out the ordinary error shapes; anything left (an I/O error, a
# go.mod that became unreadable between the guard and here) is still a failure to
# READ the file, and must not be recorded as its answer. stderr is deliberately not
# discarded — grep's own complaint is the only description of such a case.
grep -qF "$COMMON_REPO_PATH/" go.mod
GREP_RC=$?
[[ "$GREP_RC" -le 1 ]] \
  || fail "could not read go.mod in $(pwd) while looking for modules under $COMMON_REPO_PATH (grep exited $GREP_RC) — refusing to record COMMON_MODULES from a read that failed"
if [[ "$GREP_RC" -eq 1 ]]; then
  echo "COMMON_MODULES=none"
  RUN="$RUN" "$HERE/record-context.sh" "COMMON_MODULES=none"
  echo "INFO: go.mod requires no module under $COMMON_REPO_PATH — skipping common upgrade collection" >&2
  exit 0
fi
echo "COMMON_MODULES=present"
RUN="$RUN" "$HERE/record-context.sh" "COMMON_MODULES=present"

CLONE_ERR=""
# The reuse test is existence-only, and pre-flight's fresh-mode sweep now SPARES
# $RUN/common, so a mirror can outlive the run that cloned it. Stated gap: unlike
# pre-flight's template reuse, this path does not compare the existing mirror's
# origin against $COMMON_CLONE_URL, so a mirror cloned under an overridden URL or
# prefix would be reused silently by a later default-URL run. Unreachable through
# any documented path — no phase or CLI flag sets either override; they exist for
# hermetic tests and local mirrors, and each test uses its own $RUN.
if [[ ! -f "$COMMON_CACHE/HEAD" ]]; then
  # An interrupted clone leaves a partial dir with no HEAD, and `git clone`
  # refuses a non-empty destination — so without this rm every retry would fail
  # forever on the same debris. Clear it first (pre-flight.sh's reclone() does
  # the same for the template mirror). Git's own stderr is captured and folded
  # into the WARN below, not discarded — a silent clone failure was undebuggable.
  rm -rf "$COMMON_CACHE"
  CLONE_ERR=$(git clone --mirror "$COMMON_CLONE_URL" "$COMMON_CACHE" 2>&1) || true
fi

if [[ -f "$COMMON_CACHE/HEAD" ]]; then
  git -C "$COMMON_CACHE" remote update --prune >/dev/null 2>&1 || true   # keep tags current
  # COMMON_CACHE is recorded ONLY when the mirror is real and usable — the same
  # rule as the stdout line: a recorded path to a broken cache would make
  # collect-common.sh flood Phase 3.5 with false 'unresolvable' prompts.
  RUN="$RUN" "$HERE/record-context.sh" "COMMON_CACHE=$COMMON_CACHE"
  echo "COMMON_CACHE=$COMMON_CACHE"
else
  DETAIL=""
  [[ -n "$CLONE_ERR" ]] && DETAIL=" — $(printf '%s' "$CLONE_ERR" | tr '\n\t' '  ' | cut -c1-300)"
  # Not a phase skip: COMMON_MODULES=present, so Phase 3.5 still runs collection
  # and records one skip-no-cache row per module — a degraded run with a visible
  # record, not a silent one.
  echo "WARN: could not clone common$DETAIL; common collection degrades to skip-no-cache per module" >&2
fi
