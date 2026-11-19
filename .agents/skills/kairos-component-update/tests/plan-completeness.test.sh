#!/usr/bin/env bash
# plan-completeness.test.sh — tests for scripts/plan-completeness.sh
# TEST_FILTER refused (single sequential fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in plan-completeness.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "plan-completeness.sh gates missing upgrade-file dispositions"; then
PC=$SANDBOX/plan-completeness
mkdir -p "$PC"
printf '.kairos-updates/20260101T000000-alpha.md\n.kairos-updates/20260102T000000-beta.md\n' \
  > "$PC/upgrades-added.txt"
printf '.kairos-updates/api/20260103T000000-gamma.md\n' > "$PC/common-upgrades-added.txt"
printf '.kairos-updates/common/20260104T000000-delta.md\n' > "$PC/common-upgrades-modified.txt"
printf '.kairos-updates/lib/20260105T000000-epsilon.md\n' > "$PC/lib-upgrades-added.txt"
cat > "$PC/PLAN-complete.md" <<'EOF'
## Upgrade-file Dispositions

| Upgrade-file | Disposition | Task / Reason |
|---|---|---|
| `20260101T000000-alpha` | apply | T01 |
| `20260102T000000-beta` | skip | not applicable |
| `20260103T000000-gamma` | apply | T02 |
| `20260104T000000-delta` | apply | T03 |
| `20260105T000000-epsilon` | apply | T04 |
EOF
RUN=$PC PLAN=$PC/PLAN-complete.md "$SKILL_DIR/scripts/plan-completeness.sh" 2> "$SANDBOX/pc-ok.log"
expect "plan-completeness passes when every slug is dispositioned (including a common-modified one)" test $? -eq 0
# Silence is not a readable result: a crash before any output looks exactly like a
# clean pass to the caller reading the gate.
expect "a passing gate says so on stderr" grep -q '^OK:' "$SANDBOX/pc-ok.log"

cat > "$PC/PLAN-missing.md" <<'EOF'
## Upgrade-file Dispositions

| Upgrade-file | Disposition | Task / Reason |
|---|---|---|
| `20260101T000000-alpha` | apply | T01 |
EOF
RUN=$PC PLAN=$PC/PLAN-missing.md "$SKILL_DIR/scripts/plan-completeness.sh" \
  > "$SANDBOX/pc-miss.out" 2> "$SANDBOX/pc-miss.log"
PC_MISS_RC=$?
if [[ "$PC_MISS_RC" -ne 0 ]]; then pass "plan-completeness fails when a slug lacks a disposition"; else fail "plan-completeness passed with missing slugs"; fi
expect "missing-slug failure names beta" grep -q '20260102T000000-beta' "$SANDBOX/pc-miss.log"
expect "missing-slug failure names gamma" grep -q '20260103T000000-gamma' "$SANDBOX/pc-miss.log"
expect "missing-slug failure names delta (common-upgrades-modified.txt is gated too)" \
  grep -q '20260104T000000-delta' "$SANDBOX/pc-miss.log"
expect "missing-slug failure names epsilon (lib-upgrades-added.txt is gated too)" \
  grep -q '20260105T000000-epsilon' "$SANDBOX/pc-miss.log"

# A slug whose ONLY disposition row lives in a LATER section must NOT satisfy the
# gate: the table scan has to reset at the next `## ` heading, exactly like
# followup-completeness.sh. Regression — the gate used to set t=1 at the
# dispositions heading and never clear it, so a row in `## Follow-up Dispositions`
# (or any later section) counted as a disposition.
cat > "$PC/PLAN-late.md" <<'EOF'
## Upgrade-file Dispositions

| Upgrade-file | Disposition | Task / Reason |
|---|---|---|
| `20260101T000000-alpha` | apply | T01 |
| `20260103T000000-gamma` | apply | T02 |
| `20260104T000000-delta` | apply | T03 |
| `20260105T000000-epsilon` | apply | T04 |

## Follow-up Dispositions

| Follow-up | Disposition | Task / Reason |
|---|---|---|
| `20260102T000000-beta` | apply | T09 |
EOF
RUN=$PC PLAN=$PC/PLAN-late.md "$SKILL_DIR/scripts/plan-completeness.sh" \
  > "$SANDBOX/pc-late.out" 2> "$SANDBOX/pc-late.log"
PC_LATE_RC=$?
if [[ "$PC_LATE_RC" -ne 0 ]]; then pass "plan-completeness rejects a slug dispositioned only in a later section"; else fail "plan-completeness accepted a slug whose only row is in a later section"; fi
expect "later-section leak names the missing slug (beta)" \
  grep -q 'MISSING: 20260102T000000-beta' "$SANDBOX/pc-late.log"

fi

if t "plan-completeness.sh derives a slug that presents as an option string"; then
# CLASS CLOSURE, not a live defect: the documented `.kairos-updates/` naming is
# `<timestamp>-<slug>.md`, so a real upgrade-file's basename starts with a digit
# and neither shape below is reachable through it today. The class is worth
# closing anyway because both failure modes are silent — a dropped slug is a slug
# nobody dispositions — and the derivation would inherit any future naming:
#   * `echo "${base%.md}"` swallowed a slug that is exactly an option string
#     (`-n`, `-e`, any combination), appending an empty line the read loop then
#     skipped;
#   * `basename "$1"` on an unanchored leading-dash PATH read it as options and
#     returned empty, dropping the slug the same way from the other end.
PCD=$SANDBOX/pc-dash
mkdir -p "$PCD"
printf -- '-n.md\n.kairos-updates/-e.md\n' > "$PCD/upgrades-added.txt"
cat > "$PCD/PLAN.md" <<'EOF'
## Upgrade-file Dispositions

| Upgrade-file | Disposition | Task / Reason |
|---|---|---|
EOF
RUN=$PCD PLAN=$PCD/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" \
  > /dev/null 2> "$SANDBOX/pc-dash.log"
expect "the gate fails rather than passing over the dropped slugs" test $? -eq 1
expect "a slug whose whole name is an option string is demanded" \
  grep -qx 'MISSING: -n' "$SANDBOX/pc-dash.log"
expect "a leading-dash list PATH still yields its slug" \
  grep -qx 'MISSING: -e' "$SANDBOX/pc-dash.log"
refute "no basename usage error leaks to stderr" \
  grep -qE 'illegal option|invalid option|usage: basename' "$SANDBOX/pc-dash.log"

fi

if t "plan-completeness.sh refuses to pass vacuously on an ABSENT upgrade-file list"; then
# The resume defect: a session that resumes into planning with a swept (or never
# populated) $RUN has no upgrades-added.txt. Every list was `[ -f ] || continue`,
# so the gate compared an EMPTY slug set against the plan and printed
# "OK: every upgrade-file slug is dispositioned" — a green gate over missing
# inputs, on the one artifact whose absence means classification never ran. The
# gate now exits 2 and names re-running Phase 3, which is the only way to get the
# list back; nothing downstream re-derives the applicable set, so a slug that
# drops out here drops out of the migration silently.
PCV=$SANDBOX/pc-vacuous
mkdir -p "$PCV"
cat > "$PCV/PLAN.md" <<'EOF'
## Upgrade-file Dispositions

| Upgrade-file | Disposition | Task / Reason |
|---|---|---|
EOF
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" \
  > "$SANDBOX/pcv.out" 2> "$SANDBOX/pcv.log"
PCV_RC=$?
if [[ "$PCV_RC" -eq 2 ]]; then
  pass "an absent upgrades-added.txt exits 2 (inputs missing), not 0"
else
  fail "an absent upgrades-added.txt exits 2 (inputs missing), not 0 (rc=$PCV_RC)"
fi
refute "the vacuous run never claims every slug is dispositioned" \
  grep -q '^OK:' "$SANDBOX/pcv.log"
expect "the refusal names the missing list" \
  grep -q 'upgrades-added.txt' "$SANDBOX/pcv.log"
expect "the refusal names re-running classification as the remedy" \
  grep -qi 'classif' "$SANDBOX/pcv.log"

# An EMPTY list is a legitimate result (a range that added no upgrade-files) and
# must still pass — the distinction the gate has to draw is present-and-empty vs
# absent, never "no rows found".
: > "$PCV/upgrades-added.txt"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2> "$SANDBOX/pcv-empty.log"
expect "a present-but-EMPTY upgrades-added.txt still passes (no upgrade-files in range)" test $? -eq 0
expect "the empty-but-present pass still says so on stderr" grep -q '^OK:' "$SANDBOX/pcv-empty.log"

# Phase 3.5's lists are optional only when there is nothing to collect. When the
# anchor records COMMON_MODULES=present, an absent common list is the same class
# of missing input — and it is exactly the shape a lost COMMON_REPO_PATH/
# COMMON_CACHE produces upstream: a plausible skip tally and no collected files.
printf 'COMMON_MODULES=present\n' > "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" \
  > /dev/null 2> "$SANDBOX/pcv-common.log"
PCV_C_RC=$?
if [[ "$PCV_C_RC" -eq 2 ]]; then
  pass "COMMON_MODULES=present with no common-upgrades-added.txt exits 2"
else
  fail "COMMON_MODULES=present with no common-upgrades-added.txt exits 2 (rc=$PCV_C_RC)"
fi
expect "the common refusal names the missing list" \
  grep -q 'common-upgrades-added.txt' "$SANDBOX/pcv-common.log"
: > "$PCV/common-upgrades-added.txt"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "the collected-but-empty common list passes" test $? -eq 0
# COMMON_MODULES=none is the skip-the-phase record: no common list is expected.
printf 'COMMON_MODULES=none\n' > "$PCV/context.env"
rm -f "$PCV/common-upgrades-added.txt"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "COMMON_MODULES=none needs no common list (Phase 3.5 is skipped entirely)" test $? -eq 0
# No context.env at all (a pre-anchor run) must stay backward compatible.
rm -f "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "no context.env leaves the common lists optional (backward compatible)" test $? -eq 0

# The COMMON_MODULES read is an EXACT string compare against `present`, so any
# invisible decoration on the recorded value silently turns the gate back into the
# vacuous one this whole block exists to prevent: a CRLF-authored context.env leaves
# `present\r`, a hand-appended line leaves `present ` — neither equals `present`, so
# the common list stops being required and a resume with no collected files prints
# "OK". record-context.sh refuses both shapes at the writing end now, but this gate
# reads a file that can also arrive from an older run, an editor, or a hand edit, and
# a reader that trusts the writer's hygiene is a reader with no defence at all.
for deco in cr trailsp leadsp crlf_line; do
  rm -f "$PCV/common-upgrades-added.txt"
  case $deco in
    cr)        printf 'COMMON_MODULES=present\r\n' > "$PCV/context.env" ;;
    trailsp)   printf 'COMMON_MODULES=present   \n' > "$PCV/context.env" ;;
    leadsp)    printf 'COMMON_MODULES=   present\n' > "$PCV/context.env" ;;
    crlf_line) printf 'BASE=abc\r\nCOMMON_MODULES=present\r\nTARGET=def\r\n' > "$PCV/context.env" ;;
  esac
  RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" \
    > /dev/null 2> "$SANDBOX/pcv-deco-$deco.log"
  PCV_D_RC=$?
  if [[ "$PCV_D_RC" -eq 2 ]]; then
    pass "COMMON_MODULES=present survives $deco decoration — the gate still requires the common list"
  else
    fail "COMMON_MODULES=present survives $deco decoration (rc=$PCV_D_RC — the gate passed vacuously)"
  fi
  refute "the $deco run never claims every slug is dispositioned" \
    grep -q '^OK:' "$SANDBOX/pcv-deco-$deco.log"
done
# Non-vacuity from the other direction: normalization must not turn a DIFFERENT
# value into `present`. `none` decorated the same way is still `none`.
printf 'COMMON_MODULES=none\r\n' > "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "a decorated COMMON_MODULES=none is still none (normalization is not coercion)" test $? -eq 0
printf 'COMMON_MODULES=presentish\n' > "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "a value that merely STARTS with present is not present" test $? -eq 0

# Regression: `sed -n 's/^COMMON_MODULES=//p' context.env` with no `tail -1`
# returns EVERY matching line when the key is duplicated (a hand-edited or
# concatenated context.env — record-context.sh's own upsert never leaves more
# than one). A multi-line value never string-equals the literal `present`, so the
# gate silently stopped requiring the common list over a run that recorded
# COMMON_MODULES=present twice. `tail -1` takes the LAST occurrence, matching
# record-context.sh's "last write wins" upsert semantics.
rm -f "$PCV/common-upgrades-added.txt"
printf 'COMMON_MODULES=none\nCOMMON_MODULES=present\n' > "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" \
  > /dev/null 2> "$SANDBOX/pcv-dup-present.log"
PCV_DP_RC=$?
if [[ "$PCV_DP_RC" -eq 2 ]]; then
  pass "a duplicated COMMON_MODULES key still gates: last value 'present' wins"
else
  fail "a duplicated COMMON_MODULES key still gates: last value 'present' wins (rc=$PCV_DP_RC — the multi-line read passed vacuously)"
fi
expect "the duplicated-key refusal names the missing common list" \
  grep -q 'common-upgrades-added.txt' "$SANDBOX/pcv-dup-present.log"

printf 'COMMON_MODULES=present\nCOMMON_MODULES=none\n' > "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "a duplicated COMMON_MODULES key the other way: last value 'none' still passes with no common list" \
  test $? -eq 0

# --- LIB_MODULES: mirror of the COMMON_MODULES block for frontend kind:library ---
# collect-lib.sh writes LIB_MODULES=present|none on the frontend arm only.
# present + missing list → exit 2 (resume with a swept $RUN). none → no list
# required. Decorations and last-write-wins match the COMMON_MODULES reader.
: > "$PCV/upgrades-added.txt"
rm -f "$PCV/common-upgrades-added.txt" "$PCV/lib-upgrades-added.txt"
printf 'LIB_MODULES=present\n' > "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" \
  > /dev/null 2> "$SANDBOX/pcv-lib.log"
PCV_L_RC=$?
if [[ "$PCV_L_RC" -eq 2 ]]; then
  pass "LIB_MODULES=present with no lib-upgrades-added.txt exits 2"
else
  fail "LIB_MODULES=present with no lib-upgrades-added.txt exits 2 (rc=$PCV_L_RC)"
fi
expect "the lib refusal names the missing list" \
  grep -q 'lib-upgrades-added.txt' "$SANDBOX/pcv-lib.log"
: > "$PCV/lib-upgrades-added.txt"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "the collected-but-empty lib list passes" test $? -eq 0
printf 'LIB_MODULES=none\n' > "$PCV/context.env"
rm -f "$PCV/lib-upgrades-added.txt"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "LIB_MODULES=none needs no lib list" test $? -eq 0

for deco in cr trailsp leadsp crlf_line; do
  rm -f "$PCV/lib-upgrades-added.txt"
  case $deco in
    cr)        printf 'LIB_MODULES=present\r\n' > "$PCV/context.env" ;;
    trailsp)   printf 'LIB_MODULES=present   \n' > "$PCV/context.env" ;;
    leadsp)    printf 'LIB_MODULES=   present\n' > "$PCV/context.env" ;;
    crlf_line) printf 'BASE=abc\r\nLIB_MODULES=present\r\nTARGET=def\r\n' > "$PCV/context.env" ;;
  esac
  RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" \
    > /dev/null 2> "$SANDBOX/pcv-lib-deco-$deco.log"
  PCV_LD_RC=$?
  if [[ "$PCV_LD_RC" -eq 2 ]]; then
    pass "LIB_MODULES=present survives $deco decoration — the gate still requires the lib list"
  else
    fail "LIB_MODULES=present survives $deco decoration (rc=$PCV_LD_RC — the gate passed vacuously)"
  fi
done
printf 'LIB_MODULES=none\r\n' > "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "a decorated LIB_MODULES=none is still none (normalization is not coercion)" test $? -eq 0
printf 'LIB_MODULES=presentish\n' > "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "a value that merely STARTS with present is not present (LIB_MODULES)" test $? -eq 0

rm -f "$PCV/lib-upgrades-added.txt"
printf 'LIB_MODULES=none\nLIB_MODULES=present\n' > "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" \
  > /dev/null 2> "$SANDBOX/pcv-lib-dup-present.log"
PCV_LDP_RC=$?
if [[ "$PCV_LDP_RC" -eq 2 ]]; then
  pass "a duplicated LIB_MODULES key still gates: last value 'present' wins"
else
  fail "a duplicated LIB_MODULES key still gates: last value 'present' wins (rc=$PCV_LDP_RC — the multi-line read passed vacuously)"
fi
expect "the duplicated-key refusal names the missing lib list" \
  grep -q 'lib-upgrades-added.txt' "$SANDBOX/pcv-lib-dup-present.log"

printf 'LIB_MODULES=present\nLIB_MODULES=none\n' > "$PCV/context.env"
RUN=$PCV PLAN=$PCV/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh" 2>/dev/null
expect "a duplicated LIB_MODULES key the other way: last value 'none' still passes with no lib list" \
  test $? -eq 0

fi

finish_suite
