#!/usr/bin/env bash
# frontend-floor-check.sh — the FRONTEND COMPATIBILITY FLOOR check, relayed beside
# the Phase 8 frontend-run consent epilogue (phases/8-finalize.md §6.3). A "floor"
# is a claim a crossed template upgrade-file made — `requires-frontend: <module>@<sha>`
# — that adopting the backend change assumes the component's frontend baseline
# CONTAINS a given frontend-template commit. build-manifest.sh collected the crossed
# floors into $RUN/frontend-floors.tsv at Phase 3; this script decides, for the
# component's own frontend baseline, whether every floor for its module is contained.
#
# WHY IT IS A "BESIDE THE GATE" REPORT, NOT A PHASE-GATE SCRIPT: like template-parity.sh
# and silenced-tests.sh it feeds the human dispositioning at Phase 8 — it never advances
# the baseline, writes no $RUN artifact, and carries NO PHASE_KEY guard (the write
# actions do; a read-only report does not). The template merge is already committed by
# the time this runs; a floor is a post-merge consistency SIGNAL, never a gate — so this
# script ALWAYS exits 0 and the consent rules in 8-finalize.md decide what to say.
#
# WHY ANCESTRY, NOT A VERSION COMPARE: git SHAs have no order. "Is my frontend.sha at
# least the floor?" is `git merge-base --is-ancestor <floor-sha> <frontend.sha>` run in
# the frontend mirror — a CONTAINS test. A divergent-lineage frontend.sha (on a fork
# that never carried the floor commit) resolves to "not contained" → unmet, with a
# message that says *contains*, never *older than*.
#
# WHY A CLONE IS PAID ONLY WHEN A MATCHING FLOOR EXISTS: the ancestry test needs the
# frontend repo's OBJECTS, not just an ls-remote. During a template run the frontend
# mirror may never have been cloned. So the bounded-cost contract is: if the floors file
# is empty, or no crossed floor targets THIS component's module (FRONTEND_TEMPLATE),
# print FLOOR_STATE=none and clone NOTHING. Only a real matching floor buys the clone.
#
# WHY unverified IS NEVER A FALSE satisfied: any clone/fetch failure, an unresolvable or
# empty FRONTEND_SHA, or a floor commit the mirror cannot evaluate degrades to
# FLOOR_STATE=unverified (advisory: "required, but I could not verify your web/
# baseline") — mirroring 8-finalize.md rule 3's "I could not check" is never "it is
# current". The one thing this script must never do is report satisfied when it did not
# actually prove containment.
#
# WHY A THIRD SELF-CONTAINED COPY OF reuse-or-clone + require_replaceable_cache: pre-flight.sh
# and materialize-frontend.sh each already carry their OWN deliberate copy of this mirror
# acquisition logic (materialize-frontend.sh's header is a monument to why they are not
# refactored into a shared lib at this point in the run — no lib all three can source is
# in scope here, and the copies are pinned by their suites). This is the third such copy,
# on purpose. The ONE adaptation: where materialize-frontend.sh's containment guard
# fail()s (exit 1), this report degrades to FLOOR_STATE=unverified and exits 0 — it must
# NEVER destroy a caller-supplied FRONTEND_CACHE that turns out to be a working checkout,
# and it must never abort the run.
#
# Env in:  RUN               required — migration state dir.
#          FLOORS_TSV        optional — the crossed-floor table; default
#                            $RUN/frontend-floors.tsv. Columns TAB-separated, one row per
#                            crossed upgrade-file that declares a floor:
#                            <upgrade-file-path> <TAB> <module> <TAB> <floor-sha>.
#          FRONTEND_TEMPLATE the component's frontend module (manifest frontend.template).
#                            A floor row binds only when its module == this value.
#          FRONTEND_SHA      the component's recorded frontend baseline (manifest
#                            frontend.sha) — the right side of the ancestry test.
#          FRONTEND_REPO     the frontend source URL to clone the mirror from when one is
#                            not already present (manifest frontend.repo).
#          FRONTEND_CACHE    optional — bare mirror of the frontend source; default
#                            $RUN/frontend (where a frontend run's pre-flight puts it, and
#                            what materialize-frontend.sh reuses). Reused when it already
#                            mirrors the same origin; otherwise cloned on demand.
# Cwd:     component root (only used to resolve $RUN/$FRONTEND_CACHE relatives).
# Stdout:  exactly one `FLOOR_STATE=<none|satisfied|unmet|unverified>` line, followed by
#          zero or more `UNMET<TAB>file<TAB>module<TAB>sha` detail lines (one per missing
#          floor) when the state is unmet.
# Writes:  NOTHING under $RUN except the FRONTEND_CACHE mirror it may clone (a cache, not
#          a state artifact — so it never earns a state-files index entry).
# Exit:    ALWAYS 0 (advisory; a floor never aborts the already-merged template run).
set -u

: "${RUN:?FAIL: RUN not set}"

TAB=$(printf '\t')
FLOORS_TSV=${FLOORS_TSV:-$RUN/frontend-floors.tsv}
FRONTEND_TEMPLATE=${FRONTEND_TEMPLATE:-}
FRONTEND_SHA=${FRONTEND_SHA:-}
FRONTEND_REPO=${FRONTEND_REPO:-}
FE_CACHE=${FRONTEND_CACHE:-$RUN/frontend}

# The single stdout contract: one FLOOR_STATE line (plus, for callers, whatever detail
# lines were already printed to it), then exit 0.
verdict() { printf 'FLOOR_STATE=%s\n' "$1"; exit 0; }

# --- step 1: is there a matching floor at all? (no clone otherwise) -------------
# Empty/missing table, or no crossed floor for THIS component's module → none.
[[ -s "$FLOORS_TSV" ]] || verdict none
MATCHING=$(awk -F'\t' -v m="$FRONTEND_TEMPLATE" 'NF>=3 && $2==m { print }' "$FLOORS_TSV")
[[ -n "$MATCHING" ]] || verdict none

# A matching floor exists, so the ancestry test is now owed — and it needs a right side.
# An empty FRONTEND_SHA can never be resolved; short-circuit to unverified BEFORE paying
# for a clone (never a false satisfied, and no needless network cost).
[[ -n "$FRONTEND_SHA" ]] || verdict unverified

# --- the frontend mirror (THIRD self-contained copy; see header) ---------------
FE_ORIGIN=$FRONTEND_REPO

# Same normalization pre-flight check 7 and materialize-frontend.sh use: a local origin
# given once relative and once absolute is the SAME repo, so a byte comparison would miss
# the match and re-clone. Kept identical to those copies on purpose (no shared lib here).
origins_match() { # origins_match <existing-origin> <new-origin>
  [[ "$1" = "$2" ]] && return 0
  local a b
  a=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  b=$(cd "$2" 2>/dev/null && pwd -P) || return 1
  [[ -n "$a" ]] && [[ "$a" = "$b" ]]
}

# CONTAINMENT for every `rm -rf "$FE_CACHE"` below. FRONTEND_CACHE is caller-supplied, so
# this script must contain its own blast radius exactly as materialize-frontend.sh does.
# Destroy the path ONLY when it does not exist yet (rm is a no-op), lives under $RUN, or
# is a BARE git mirror (top-level HEAD present AND core.bare=true — the only non-$RUN
# shape this tooling creates). Anything else (a working checkout, $PWD) is REFUSED. The
# one adaptation from materialize-frontend.sh's copy: a refusal returns non-zero and the
# caller degrades to unverified — this report never fail()s and never rm -rf's a checkout.
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
  echo "INFO: frontend-floor-check refusing to 'rm -rf' the frontend mirror path '$p': it is neither under this run's state dir ($RUN) nor a bare git mirror (HEAD present and core.bare=true). FRONTEND_CACHE is caller-supplied; refusing to destroy it — degrading the floor check to unverified." >&2
  return 1
}

if [[ -f "$FE_CACHE/HEAD" ]] && [[ -z "$FE_ORIGIN" ]]; then
  : # a mirror someone else established, and nothing to check it against — use it
elif [[ -f "$FE_CACHE/HEAD" ]]; then
  # Reuse only a mirror of the SAME origin, and refresh it; a stale mirror of a DIFFERENT
  # origin would serve another repo's commits under this run's SHAs. A failed refresh
  # (corrupt mirror, unreachable origin) falls back to a clean re-clone.
  FE_EXISTING=$(git -C "$FE_CACHE" config --get remote.origin.url 2>/dev/null || echo "")
  if origins_match "$FE_EXISTING" "$FE_ORIGIN" && git -C "$FE_CACHE" remote update --prune >/dev/null 2>&1; then
    : # refreshed the existing mirror
  else
    require_replaceable_cache "$FE_CACHE" || verdict unverified
    rm -rf "$FE_CACHE"
    git clone --mirror "$FE_ORIGIN" "$FE_CACHE" >/dev/null 2>&1 || verdict unverified
  fi
elif [[ -n "$FE_ORIGIN" ]]; then
  require_replaceable_cache "$FE_CACHE" || verdict unverified
  rm -rf "$FE_CACHE"
  git clone --mirror "$FE_ORIGIN" "$FE_CACHE" >/dev/null 2>&1 || verdict unverified
else
  # No mirror to reuse and no origin to clone from — the ancestry test cannot be run.
  verdict unverified
fi

# The right side of every ancestry test. Unresolvable (a bad or absent frontend.sha in
# the mirror) → unverified, never a guessed satisfied.
git -C "$FE_CACHE" rev-parse --verify --quiet "${FRONTEND_SHA}^{commit}" >/dev/null 2>&1 \
  || verdict unverified

# --- the ancestry test, per matching floor -------------------------------------
# merge-base --is-ancestor exit codes: 0 contained, 1 not contained, other = error (e.g.
# a floor commit the mirror does not carry). unmet (definite miss) OUTRANKS a mid-scan
# error: a real not-contained floor is actionable and must surface, while an error with
# NO definite miss can only degrade to unverified — never a satisfied it did not prove.
DETAILS=$(mktemp "${TMPDIR:-/tmp}/floor-details.XXXXXX")
trap 'rm -f "$DETAILS"' EXIT
UNMET_FOUND=0
ERROR_FOUND=0
while IFS="$TAB" read -r file module sha _rest; do
  [[ -n "$sha" ]] || { ERROR_FOUND=1; continue; }
  git -C "$FE_CACHE" merge-base --is-ancestor "$sha" "$FRONTEND_SHA" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    :                                     # contained
  elif [[ "$rc" -eq 1 ]]; then
    UNMET_FOUND=1
    printf 'UNMET\t%s\t%s\t%s\n' "$file" "$module" "$sha" >> "$DETAILS"
  else
    ERROR_FOUND=1                         # floor commit unevaluable in the mirror
  fi
done <<EOF
$MATCHING
EOF

if [[ "$UNMET_FOUND" -eq 1 ]]; then
  printf 'FLOOR_STATE=unmet\n'
  cat "$DETAILS"
  exit 0
elif [[ "$ERROR_FOUND" -eq 1 ]]; then
  verdict unverified
else
  verdict satisfied
fi
