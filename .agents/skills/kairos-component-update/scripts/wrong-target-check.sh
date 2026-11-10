#!/usr/bin/env bash
# wrong-target-check.sh — Phase 3.5's wrong-target tripwire, as a script with a
# real stop. When migrating against a local template checkout whose go.mod
# co-develops kairos-component-common (local-path replaces) while the resolved
# TARGET's go.mod does not, the run is almost certainly aimed at the wrong ref
# (e.g. TARGET defaulted to main while the author's work sits on a feature
# branch) — stop and ask before the hours-long phases run.
#
# WHY a script and not the former phase-doc shell fragment: the fragment invoked
# codev-check.sh through bare command substitution and never looked at the exit
# status, so codev-check's exit 2 ("could not parse — silence must never read as
# a clean result") was discarded and an unreadable go.mod read as "no co-dev
# replaces" — disarming exactly the defense codev-check's own header documents.
# Here every non-zero codev-check.sh exit maps to exit 3, never to silence.
#
# WHY exit 3 exists at all: TEMPLATE_PATH is read from $RUN/context.env, the
# durable record pre-flight.sh writes — not from conversation memory, which
# compaction can evict. But durability cuts both ways: a recorded path can stop
# resolving (moved checkout, different machine after a resume). "No local
# template was ever given" (exit 0, not applicable) and "a local template WAS
# given and I can no longer check it" (exit 3, stop and ask) must be different
# answers — a lost value must never read as "not applicable". For the same
# reason every bad-input case (RUN unset, context.env missing) is exit 3, not
# the neighbors' exit-2 bad-input convention: here 2 is the verdict code, and
# an input failure rounded into a verdict would be this script lying about the
# one thing it exists to determine.
#
# Env in:  RUN  migration state dir (required)
# Reads:   $RUN/context.env        TEMPLATE_PATH (recorded by pre-flight.sh;
#                                  absent/empty => no local template => exit 0)
#                                  and COMMON_REPO_PATH (recorded by
#                                  clone-common.sh)
#          $TEMPLATE_PATH/go.mod   the working tree's dependency statement
#          $RUN/template-go.mod    the TARGET's go.mod, extracted in Phase 3.5
# Stdout:  nothing (verdict lines go to stderr)
# Exit:    0  not applicable (no local template recorded) OR clear (working
#             tree does not co-develop common, or TARGET co-develops too)
#          2  STOP — working tree co-develops common and TARGET does not;
#             ask the user whether TARGET is right before continuing
#          3  could not determine — TEMPLATE_PATH is recorded but the path is
#             gone, codev-check.sh failed on either go.mod, or required context
#             is missing; stop and ask, never treat as clear
set -u

fail3() { echo "FAIL: $*" >&2; exit 3; }

[[ -n "${RUN:-}" ]] || fail3 "RUN not set — could not determine (exit 3, not clear)"

CTX="$RUN/context.env"
[[ -f "$CTX" ]] || fail3 "$CTX not found — run context is missing; could not determine"

# context.env is one KEY=VALUE per line, last write wins (record-context.sh).
# Read it with sed, not `source`: values are arbitrary single-line strings.
ctx_get() { LC_ALL=C sed -n "s/^$1=//p" "$CTX" | tail -1; }

TEMPLATE_PATH=$(ctx_get TEMPLATE_PATH)
if [[ -z "$TEMPLATE_PATH" ]]; then
  echo "OK: no local template recorded in $CTX — wrong-target check not applicable" >&2
  exit 0
fi

# A bare local template (pre-flight.sh accepts one — it checks TEMPLATE_PATH/HEAD)
# has no working tree, so there is no working-tree go.mod whose co-dev replaces
# could diverge from TARGET: genuinely not applicable, and exit 3 here would stop
# every run forever with a question no answer can clear. Distinct from the
# vanished-checkout case below — rev-parse fails on a gone path and falls through.
if [[ "$(git -C "$TEMPLATE_PATH" rev-parse --is-bare-repository 2>/dev/null)" = true ]]; then
  echo "OK: $TEMPLATE_PATH is a bare repo — no working tree to co-develop common; wrong-target check not applicable" >&2
  exit 0
fi

# The compaction/resume case: a TEMPLATE_PATH was recorded, so a local template
# WAS in play — if the path no longer resolves, that is exit 3, never 0.
[[ -f "$TEMPLATE_PATH/go.mod" ]] \
  || fail3 "TEMPLATE_PATH recorded as '$TEMPLATE_PATH' but $TEMPLATE_PATH/go.mod is gone — could not determine (a lost value is not 'not applicable')"

COMMON_REPO_PATH=$(ctx_get COMMON_REPO_PATH)
[[ -n "$COMMON_REPO_PATH" ]] \
  || fail3 "COMMON_REPO_PATH missing from $CTX (clone-common.sh records it in Phase 1) — could not determine"

TARGET_GOMOD="$RUN/template-go.mod"
[[ -f "$TARGET_GOMOD" ]] \
  || fail3 "$TARGET_GOMOD not found — extract the TARGET go.mod first (Phase 3.5)"

HERE=$(cd "$(dirname "$0")" && pwd)

# The assignments below DO check the substituted command's exit status — the
# `|| fail3` is the whole point (see header). codev-check.sh prints its own
# FAIL: line to stderr before ours names which side could not be read.
WT_REPLACES=$(COMMON_REPO_PATH="$COMMON_REPO_PATH" "$HERE/codev-check.sh" "$TEMPLATE_PATH/go.mod") \
  || fail3 "codev-check.sh could not read $TEMPLATE_PATH/go.mod — could not determine"

if [[ -z "$WT_REPLACES" ]]; then
  echo "OK: $TEMPLATE_PATH/go.mod does not co-develop $COMMON_REPO_PATH — clear" >&2
  exit 0
fi

TARGET_REPLACES=$(COMMON_REPO_PATH="$COMMON_REPO_PATH" "$HERE/codev-check.sh" "$TARGET_GOMOD") \
  || fail3 "codev-check.sh could not read $TARGET_GOMOD — could not determine"

if [[ -z "$TARGET_REPLACES" ]]; then
  {
    echo "STOP: the local template's working tree co-develops $COMMON_REPO_PATH but the TARGET go.mod has no local-path replaces."
    echo "STOP: working-tree replaces:"
    printf '%s\n' "$WT_REPLACES" | sed 's/^/STOP:   /'
    echo "STOP: TARGET may be the wrong ref (e.g. main instead of the feature branch) — ask the user before continuing."
  } >&2
  exit 2
fi

echo "OK: both the working tree and TARGET co-develop $COMMON_REPO_PATH — clear" >&2
exit 0
