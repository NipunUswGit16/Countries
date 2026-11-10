#!/usr/bin/env bash
# scope-check.sh — advisory pre-classification scope signal. Counts commits in
# BASE..TARGET and reports whether the range exceeds the advisory threshold.
# Cannot resolve the range — hard stop (exit 2), never a false OK.
#
# Env in:  PHASE_KEY   required — proof-of-load key stated in phases/2-resolve-target.md
#          CACHE       source mirror clone — template mirror on a template run,
#                      frontend mirror on a frontend run (required)
#          BASE        baseline SHA in that mirror's history (required)
#          TARGET      target SHA in that mirror's history (required)
#          THRESHOLD   commit-count advisory ceiling (default 30)
# Stdout:  COMMITS=<n>, THRESHOLD=<t>, then OK: or ADVISORY:
# Exit:    0  range resolved (advisory only — never blocks on commit count)
#          1  PHASE_KEY missing/wrong
#          2  BASE..TARGET could not be resolved
set -u

# Phase-load guard: this key is stated ONLY in phases/2-resolve-target.md, so an
# orchestrator that skipped loading that file cannot know it. The guard turns a
# skipped load into a stop instead of a phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "k3wq8vfr" ]] \
  || { echo "FAIL: load phases/2-resolve-target.md first" >&2; exit 1; }

: "${CACHE:?FAIL: CACHE not set}"
: "${BASE:?FAIL: BASE not set}"
: "${TARGET:?FAIL: TARGET not set}"
THRESHOLD="${THRESHOLD:-30}"

N=$(git -C "$CACHE" rev-list --count "$BASE..$TARGET" 2>/dev/null) || N=
if [[ -z "$N" ]]; then
  echo "COMMITS=unknown"
  echo "THRESHOLD=$THRESHOLD"
  echo "FAIL: cannot resolve BASE..TARGET in $CACHE — unresolvable range" >&2
  exit 2
fi

echo "COMMITS=$N"
echo "THRESHOLD=$THRESHOLD"

if [[ "$N" -gt "$THRESHOLD" ]]; then
  echo "ADVISORY: $N commits in BASE..TARGET exceeds the $THRESHOLD-commit advisory threshold — merge-pipeline overlap after classification is the blocking gate"
else
  echo "OK: $N commits in BASE..TARGET is within the $THRESHOLD-commit advisory threshold"
fi
