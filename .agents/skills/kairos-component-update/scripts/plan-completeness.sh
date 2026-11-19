#!/usr/bin/env bash
# plan-completeness.sh — completeness gate before PLAN.md is committed. Every
# slug in the template, amended, and common-library upgrade lists must have a
# disposition row in the plan.
#
# WHY an absent input list is exit 2 and not an empty slug set: this gate used to
# skip every list it could not find, so a session resuming into planning against a
# swept (or never populated) $RUN compared an EMPTY slug set against the plan and
# printed "OK: every upgrade-file slug is dispositioned". The one artifact whose
# absence means classification never ran was also the one the gate treated as
# optional. Nothing downstream re-derives the applicable set — PLAN.md is frozen at
# approval — so a slug that drops out here drops out of the migration silently.
# `upgrades-added.txt` is written unconditionally by build-manifest.sh (empty when
# the range added no upgrade-files), which is what makes present-and-empty
# distinguishable from absent at all.
#
# Env in:  RUN   migration state dir (required)
#          PLAN  path to PLAN.md (required)
# Reads:   $RUN/upgrades-added.txt          REQUIRED — Phase 3's witness
#          $RUN/upgrades-modified.txt (optional)
#          $RUN/common-upgrades-added.txt   required when the run-context anchor
#                                           records COMMON_MODULES=present
#          $RUN/common-upgrades-modified.txt (optional)
#          $RUN/lib-upgrades-added.txt      required when the run-context anchor
#                                           records LIB_MODULES=present
#          $RUN/lib-upgrades-modified.txt (optional)
#          $RUN/context.env (optional) — COMMON_MODULES / LIB_MODULES, normalized
#                                           (CR stripped, surrounding space trimmed)
#                                           before the compare against `present`
# Stderr:  missing slug names on failure; an OK line on success — silence is not
#          a result a caller can read, and a crash before any output would be
#          indistinguishable from a clean pass
# Exit:    0  every slug dispositioned
#          1  one or more slugs missing from the plan
#          2  an input list is ABSENT — the gate cannot answer, and must not
#             answer "clean". Re-run Phase 3 (and Phase 3.5 / collect-lib.sh)
#             and come back.
set -u

: "${RUN:?FAIL: RUN not set}"
: "${PLAN:?FAIL: PLAN not set}"

[[ -f "$PLAN" ]] || { echo "FAIL: plan not found: $PLAN" >&2; exit 1; }

# --- input presence, before any slug is read ----------------------------------
[[ -f "$RUN/upgrades-added.txt" ]] || {
  echo "FAIL: $RUN/upgrades-added.txt is absent — Phase 3 classification never ran here, or the state dir was swept. This gate cannot pass over missing inputs: re-run classification (phases/3-classify.md), then re-run this gate." >&2
  exit 2
}

# Phase 3.5's lists are legitimately absent only when there was nothing to collect
# (COMMON_MODULES=none — the phase is skipped entirely). When the anchor says the
# component DOES consume common modules, an absent list is the same missing input:
# it is the exact shape a lost COMMON_REPO_PATH/COMMON_CACHE produces upstream —
# a plausible skip tally and not one collected file.
#
# The read is NORMALIZED before the compare — a trailing CR (a CRLF-authored or
# CRLF-edited context.env) or stray surrounding spaces (a hand-appended line) make
# the recorded value stop equalling `present`, and this gate's failure mode on a
# non-match is to go quiet: it stops requiring the common list and prints "OK" over
# a run that collected nothing. record-context.sh refuses both shapes at the writing
# end, but this file can also arrive from an older run, an editor, or a hand edit,
# and a reader that relies on the writer's hygiene has no defence of its own.
# Normalization is not coercion: `none`, `presentish` and an empty value all stay
# what they are.
#
# `| tail -1`: a DUPLICATE COMMON_MODULES= line (a hand-edited or concatenated
# context.env — record-context.sh's own upsert always leaves at most one) makes
# the sed extraction a multi-line value. That multi-line string never string-equals
# the literal `present`, so the gate again goes quiet on a run that recorded
# COMMON_MODULES=present twice. `tail -1` takes the LAST line, matching
# record-context.sh's own "last write wins" semantics and wrong-target-check.sh's
# ctx_get helper, which reads context.env the same way.
COMMON_MODULES=""
[[ -f "$RUN/context.env" ]] \
  && COMMON_MODULES=$(sed -n 's/^COMMON_MODULES=//p' "$RUN/context.env" \
       | tail -1 | tr -d '\r' | awk '{ $1 = $1; print }')
if [[ "$COMMON_MODULES" = present ]] && [[ ! -f "$RUN/common-upgrades-added.txt" ]]; then
  echo "FAIL: the run context records COMMON_MODULES=present but $RUN/common-upgrades-added.txt is absent — common-library collection never ran here. Re-run Phase 3.5 (phases/3.5-collect-common.md), then re-run this gate." >&2
  exit 2
fi

# Mirror of the COMMON_MODULES block for frontend kind:library collection.
# collect-lib.sh writes LIB_MODULES=present|none on the frontend arm only —
# absent by design on a template run (the inverse of COMMON_MODULES). When the
# key is present, an absent list is the same missing-input shape: "no lib files
# in range" is an empty-but-present list, never a missing file.
LIB_MODULES=""
[[ -f "$RUN/context.env" ]] \
  && LIB_MODULES=$(sed -n 's/^LIB_MODULES=//p' "$RUN/context.env" \
       | tail -1 | tr -d '\r' | awk '{ $1 = $1; print }')
if [[ "$LIB_MODULES" = present ]] && [[ ! -f "$RUN/lib-upgrades-added.txt" ]]; then
  echo "FAIL: the run context records LIB_MODULES=present but $RUN/lib-upgrades-added.txt is absent — library-module collection never ran here. Re-run the Phase 3 frontend arm (phases/3-classify.md — build-manifest.sh AND collect-lib.sh as one unit), then re-run this gate." >&2
  exit 2
fi

TMP=$(mktemp "${TMPDIR:-/tmp}/plan-completeness.XXXXXX")
trap 'rm -f "$TMP"' EXIT

# The path is ANCHORED before basename and the slug written with printf. Neither
# shape is reachable through the documented `.kairos-updates/<timestamp>-<slug>.md`
# naming (that basename starts with a digit), so this is class closure rather than
# a live fix — kept because both failure modes are silent: an unanchored
# leading-dash path reaches basename as options and comes back EMPTY, and bash's
# builtin echo reads a slug that is exactly an option string (`-n`, `-e`, any
# combination) as its own options. Either way the append is an empty line, the
# read loop below skips it, and the slug is never demanded of the plan.
slug_from_path() {
  local base p
  case "$1" in /*|./*) p="$1" ;; *) p="./$1" ;; esac
  base=$(basename "$p")
  printf '%s\n' "${base%.md}"
}

> "$TMP"
for list in upgrades-added.txt upgrades-modified.txt common-upgrades-added.txt common-upgrades-modified.txt lib-upgrades-added.txt lib-upgrades-modified.txt; do
  [[ -f "$RUN/$list" ]] || continue
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    slug_from_path "$path" >> "$TMP"
  done < "$RUN/$list"
done

sort -u "$TMP" -o "$TMP"

DISPOSITIONED=$(mktemp "${TMPDIR:-/tmp}/plan-dispositions.XXXXXX")
trap 'rm -f "$TMP" "$DISPOSITIONED"' EXIT

awk '
  /^## Upgrade-file Dispositions/ { t = 1; next }
  t && /^## / { t = 0 }
  t && /^\| `/ {
    line = $0
    sub(/^\| `/, "", line)
    sub(/`.*/, "", line)
    gsub(/^ +| +$/, "", line)
    if (line != "" && line != "Upgrade-file") print line
  }
' "$PLAN" | sort -u > "$DISPOSITIONED"

MISSING=0
while IFS= read -r slug; do
  [[ -n "$slug" ]] || continue
  # `--`: a slug is an operand, not a pattern-shaped option (see slug_from_path).
  if ! grep -qxF -- "$slug" "$DISPOSITIONED"; then
    echo "MISSING: $slug" >&2
    MISSING=$((MISSING + 1))
  fi
done < "$TMP"

if [[ "$MISSING" -gt 0 ]]; then
  echo "FAIL: $MISSING upgrade-file slug(s) lack a disposition in $PLAN" >&2
  exit 1
fi
echo "OK: every upgrade-file slug is dispositioned in $PLAN" >&2
