#!/usr/bin/env bash
# clone-common.test.sh — tests for scripts/clone-common.sh
# TEST_FILTER refused (blocks share sequential fixtures).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in clone-common.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "clone-common.sh — mirrors common only when go.mod consumes it"; then
CCM=$SANDBOX/clone-common
LCR=$CCM/common-origin
mkdir -p "$LCR" && ( cd "$LCR" && git init -q -b main && echo lib > lib.go \
  && git add -A && git commit -qm init )
CCC=$CCM/consumer && mkdir -p "$CCC/run" && cd "$CCC"
printf 'module example.com/comp\n\nrequire bitbucket.org/ifs-pd/kairos-component-common/api v1.2.3\n' > go.mod
RUN=$CCC/run COMMON_CLONE_URL=$LCR "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccm.out" 2> "$SANDBOX/ccm.log"
expect "a consuming component clones cleanly (exit 0)" test $? -eq 0
expect "the canonical COMMON_REPO_PATH is emitted" \
  grep -qx 'COMMON_REPO_PATH=bitbucket.org/ifs-pd/kairos-component-common' "$SANDBOX/ccm.out"
expect "COMMON_CACHE is emitted when the mirror landed" \
  grep -q '^COMMON_CACHE=' "$SANDBOX/ccm.out"
expect "the mirror exists under \$RUN/common" test -f "$CCC/run/common/HEAD"
expect "clone-common records COMMON_REPO_PATH into context.env" \
  grep -qx 'COMMON_REPO_PATH=bitbucket.org/ifs-pd/kairos-component-common' "$CCC/run/context.env"
expect "clone-common records COMMON_CACHE when the mirror landed" \
  grep -qx "COMMON_CACHE=$CCC/run/common" "$CCC/run/context.env"
# COMMON_MODULES answers "is there anything to collect", COMMON_CACHE answers
# "is the mirror usable" — Phase 3.5 branches on the first, so it must be
# recorded on every path, not inferred from the second.
expect "a consumer emits COMMON_MODULES=present" \
  grep -qx 'COMMON_MODULES=present' "$SANDBOX/ccm.out"
expect "a consumer records COMMON_MODULES=present into context.env" \
  grep -qx 'COMMON_MODULES=present' "$CCC/run/context.env"
RUN=$CCC/run COMMON_CLONE_URL=$LCR "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccm2.out" 2> "$SANDBOX/ccm2.log"
expect "a second run is idempotent and still emits the cache" \
  grep -q '^COMMON_CACHE=' "$SANDBOX/ccm2.out"
expect "a second run keeps context.env free of duplicate keys (upsert)" \
  bash -c "test \"\$(grep -c '^COMMON_CACHE=' '$CCC/run/context.env')\" = 1"
expect "a second run does not duplicate COMMON_MODULES either (upsert)" \
  bash -c "test \"\$(grep -c '^COMMON_MODULES=' '$CCC/run/context.env')\" = 1"

CCN=$CCM/nonconsumer && mkdir -p "$CCN/run" && cd "$CCN"
printf 'module example.com/standalone\n' > go.mod
RUN=$CCN/run COMMON_CLONE_URL=$LCR "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccm3.out" 2> "$SANDBOX/ccm3.log"
expect "a non-consumer skips cleanly (exit 0)" test $? -eq 0
refute "a non-consumer gets no COMMON_CACHE line" \
  grep -q '^COMMON_CACHE=' "$SANDBOX/ccm3.out"
refute "a non-consumer never clones" test -e "$CCN/run/common"
expect "the skip says why on stderr" grep -qi 'skipping common' "$SANDBOX/ccm3.log"
expect "a non-consumer still records COMMON_REPO_PATH into context.env" \
  grep -qx 'COMMON_REPO_PATH=bitbucket.org/ifs-pd/kairos-component-common' "$CCN/run/context.env"
refute "a non-consumer records no COMMON_CACHE" \
  grep -q '^COMMON_CACHE=' "$CCN/run/context.env"
# 'nothing to collect' — Phase 3.5 skips entirely on this key, no artifacts, no prompts.
expect "a non-consumer emits COMMON_MODULES=none" \
  grep -qx 'COMMON_MODULES=none' "$SANDBOX/ccm3.out"
expect "a non-consumer records COMMON_MODULES=none into context.env" \
  grep -qx 'COMMON_MODULES=none' "$CCN/run/context.env"

CCF=$CCM/failclone && mkdir -p "$CCF/run" && cd "$CCF"
printf 'module example.com/comp2\n\nrequire bitbucket.org/ifs-pd/kairos-component-common/api v1.0.0\n' > go.mod
RUN=$CCF/run COMMON_CLONE_URL=$CCM/does-not-exist "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccm4.out" 2> "$SANDBOX/ccm4.log"
expect "a failed clone degrades to a clean skip (exit 0)" test $? -eq 0
refute "a failed clone leaves no COMMON_CACHE line (collect-common must not see a broken cache)" \
  grep -q '^COMMON_CACHE=' "$SANDBOX/ccm4.out"
expect "the failed clone WARNs" grep -q 'WARN' "$SANDBOX/ccm4.log"
expect "the WARN folds in git's own stderr, not a bare 'could not clone'" \
  grep -qi 'does not exist' "$SANDBOX/ccm4.log"
expect "a failed clone still records COMMON_REPO_PATH" \
  grep -qx 'COMMON_REPO_PATH=bitbucket.org/ifs-pd/kairos-component-common' "$CCF/run/context.env"
refute "a failed clone records no COMMON_CACHE (a recorded broken cache would poison Phase 3.5)" \
  grep -q '^COMMON_CACHE=' "$CCF/run/context.env"
# The failed clone is the case the third key exists for: there ARE common modules,
# so Phase 3.5 must still run collection (degraded, one skip-no-cache row per
# module) rather than read the missing cache as 'nothing to collect'.
expect "a failed clone still emits COMMON_MODULES=present" \
  grep -qx 'COMMON_MODULES=present' "$SANDBOX/ccm4.out"
expect "a failed clone still records COMMON_MODULES=present into context.env" \
  grep -qx 'COMMON_MODULES=present' "$CCF/run/context.env"
refute "a failed clone never records COMMON_MODULES=none" \
  grep -qx 'COMMON_MODULES=none' "$CCF/run/context.env"

# The prefix is a path, not a pattern: `common.lib` must not match `commonXlib`.
# Unescaped, the dot matched any char and a require on an unrelated module read as
# a consumer of common — cloning the mirror and running collection for nothing.
CCR=$CCM/regexprefix && mkdir -p "$CCR/run" && cd "$CCR"
printf 'module example.com/comp4\n\nrequire example.com/ifs-pd/commonXlib/api v1.0.0\n' > go.mod
RUN=$CCR/run COMMON_REPO_PATH=example.com/ifs-pd/common.lib COMMON_CLONE_URL=$LCR \
  "$SKILL_DIR/scripts/clone-common.sh" > "$SANDBOX/ccm6.out" 2> "$SANDBOX/ccm6.log"
expect "a near-miss require (regex metacharacter in the prefix) is not a consumer" \
  grep -qx 'COMMON_MODULES=none' "$SANDBOX/ccm6.out"
refute "the near-miss never clones the mirror" test -e "$CCR/run/common"

# An interrupted clone leaves a partial $RUN/common (dir exists, no HEAD);
# `git clone` refuses a non-empty destination, so without the rm-first the
# retry would fail forever on the same debris.
CCP=$CCM/partialclone && mkdir -p "$CCP/run/common/objects" && cd "$CCP"
printf 'module example.com/comp3\n\nrequire bitbucket.org/ifs-pd/kairos-component-common/api v1.0.0\n' > go.mod
echo debris > "$CCP/run/common/objects/tmp_pack_debris"
RUN=$CCP/run COMMON_CLONE_URL=$LCR "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccm5.out" 2> "$SANDBOX/ccm5.log"
expect "a partial clone dir (no HEAD) recovers on the next run (exit 0)" test $? -eq 0
expect "the recovered mirror is real (HEAD exists)" test -f "$CCP/run/common/HEAD"
expect "COMMON_CACHE is emitted after recovery" grep -q '^COMMON_CACHE=' "$SANDBOX/ccm5.out"
refute "the pre-clone debris did not survive into the mirror" \
  test -e "$CCP/run/common/objects/tmp_pack_debris"
cd "$SANDBOX"

fi

if t "clone-common.sh — an unread go.mod is a hard failure, never COMMON_MODULES=none"; then
# `grep -qF … go.mod 2>/dev/null` could not tell "no match" (a legitimate
# non-consumer) from "no go.mod" or "cannot read it": all three took the none path
# and recorded COMMON_MODULES=none, with a positively-worded INFO about a file that
# was never opened. That key is durable and Phase 3.5 SKIPS collection on it, so
# collect-common.sh's own go.mod guards never run and plan-completeness accepts the
# run — the whole common side of the migration switched off by a file nobody read.
CCG=$SANDBOX/clone-common-gomod
LCR2=$CCG/common-origin
mkdir -p "$LCR2" && ( cd "$LCR2" && git init -q -b main && echo lib > lib.go \
  && git add -A && git commit -qm init )

# 1. go.mod absent entirely.
CCG1=$CCG/nogomod && mkdir -p "$CCG1/run" && cd "$CCG1"
RUN=$CCG1/run COMMON_CLONE_URL=$LCR2 "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccg1.out" 2> "$SANDBOX/ccg1.log"
CCG1_RC=$?
if [[ "$CCG1_RC" -eq 1 ]]; then pass "a missing go.mod exits 1"; else fail "a missing go.mod exited $CCG1_RC (want 1)"; fi
expect "the refusal is loud and says go.mod is missing" \
  bash -c "grep -q '^FAIL' '$SANDBOX/ccg1.log' && grep -qi 'go.mod' '$SANDBOX/ccg1.log'"
refute "a missing go.mod never emits COMMON_MODULES=none" \
  grep -q 'COMMON_MODULES=none' "$SANDBOX/ccg1.out"
refute "a missing go.mod never RECORDS COMMON_MODULES=none (the durable off-switch)" \
  bash -c "grep -q 'COMMON_MODULES' '$CCG1/run/context.env' 2>/dev/null"
refute "and it never claims the go.mod requires no common module" \
  grep -qi 'requires no module' "$SANDBOX/ccg1.log"
refute "a refusal writes no context.env state at all" test -f "$CCG1/run/context.env"
refute "a missing go.mod never clones" test -e "$CCG1/run/common"

# 2. go.mod present but unreadable. Root bypasses chmod 000 (DAC), so the file
# would stay readable and the assertion would test nothing — same skip-pass posture
# as collect-common.test.sh's unreadable-template block.
CCG2=$CCG/unreadable && mkdir -p "$CCG2/run" && cd "$CCG2"
printf 'module example.com/comp\n\nrequire bitbucket.org/ifs-pd/kairos-component-common/api v1.2.3\n' > go.mod
if [[ "$(id -u)" -eq 0 ]]; then
  pass "unreadable go.mod case skipped (running as root)"
else
  chmod 000 go.mod
  RUN=$CCG2/run COMMON_CLONE_URL=$LCR2 "$SKILL_DIR/scripts/clone-common.sh" \
    > "$SANDBOX/ccg2.out" 2> "$SANDBOX/ccg2.log"
  CCG2_RC=$?
  chmod 644 go.mod 2>/dev/null || true
  if [[ "$CCG2_RC" -eq 1 ]]; then pass "an unreadable go.mod exits 1"; else fail "an unreadable go.mod exited $CCG2_RC (want 1)"; fi
  refute "an unreadable go.mod never emits COMMON_MODULES=none" \
    grep -q 'COMMON_MODULES=none' "$SANDBOX/ccg2.out"
  refute "an unreadable go.mod never records COMMON_MODULES=none" \
    bash -c "grep -q 'COMMON_MODULES' '$CCG2/run/context.env' 2>/dev/null"
  expect "the refusal points at permissions, not at 'no common modules'" \
    bash -c "grep -qi 'not readable' '$SANDBOX/ccg2.log'"
fi

# 3. A DIRECTORY at go.mod gets its own sentence — the same diagnosis-quality rule
# collect-common.sh's go.mod guards follow (one "not readable" for every shape sent
# an operator who had pointed at a directory off to check permissions).
CCG3=$CCG/dirgomod && mkdir -p "$CCG3/run" "$CCG3/go.mod" && cd "$CCG3"
RUN=$CCG3/run COMMON_CLONE_URL=$LCR2 "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccg3.out" 2> "$SANDBOX/ccg3.log"
CCG3_RC=$?
if [[ "$CCG3_RC" -eq 1 ]]; then pass "a directory at go.mod exits 1"; else fail "a directory at go.mod exited $CCG3_RC (want 1)"; fi
expect "a directory is diagnosed as a directory, not as 'not readable'" \
  grep -qi 'director' "$SANDBOX/ccg3.log"
refute "a directory at go.mod never records COMMON_MODULES=none" \
  bash -c "grep -q 'COMMON_MODULES' '$CCG3/run/context.env' 2>/dev/null"

# 4. The legitimate case must still work: a go.mod that WAS read and matches
# nothing records `none` and exits 0. This is the assertion that keeps the fix from
# being "fail on everything".
CCG4=$CCG/readable-nomatch && mkdir -p "$CCG4/run" && cd "$CCG4"
printf 'module example.com/standalone\n\ngo 1.27.1\n' > go.mod
RUN=$CCG4/run COMMON_CLONE_URL=$LCR2 "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccg4.out" 2> "$SANDBOX/ccg4.log"
CCG4_RC=$?
if [[ "$CCG4_RC" -eq 0 ]]; then pass "a readable go.mod with no common require still exits 0"; else fail "a readable non-consumer exited $CCG4_RC (want 0)"; fi
expect "and it still records COMMON_MODULES=none — the read answer, not an invented one" \
  grep -qx 'COMMON_MODULES=none' "$CCG4/run/context.env"
cd "$SANDBOX"

fi

if t "clone-common.sh — a frontend run is a not-applicable skip that records NOTHING"; then
# The deadlock this guards against: a frontend run that records
# COMMON_MODULES=present arms plan-completeness.sh's common-upgrades check against
# a Phase 3.5 that is (correctly) idle on that arm — the run then dies at Phase 6
# with a remedy the frontend arm forbids. Absence of every COMMON_* key is the
# record Phase 3.5's bare read expects.
CCF=$SANDBOX/clone-common-frontend
LCRF=$CCF/common-origin
mkdir -p "$LCRF" && ( cd "$LCRF" && git init -q -b main && echo lib > lib.go \
  && git add -A && git commit -qm init )
CCF1=$CCF/consumer && mkdir -p "$CCF1/run" && cd "$CCF1"
# A CONSUMING go.mod on purpose: the skip must win even when the component root
# genuinely requires common modules — the frontend run still has no common side.
printf 'module example.com/comp\n\nrequire bitbucket.org/ifs-pd/kairos-component-common/api v1.2.3\n' > go.mod
printf 'RUN_SOURCE=frontend\n' > "$CCF1/run/context.env"
RUN=$CCF1/run COMMON_CLONE_URL=$LCRF "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccf1.out" 2> "$SANDBOX/ccf1.log"
CCF1_RC=$?
if [[ "$CCF1_RC" -eq 0 ]]; then pass "the frontend skip exits 0"; else fail "the frontend skip exited $CCF1_RC (want 0)"; fi
refute "no COMMON_* key is emitted on stdout" \
  grep -q '^COMMON_' "$SANDBOX/ccf1.out"
refute "no COMMON_* key lands on the anchor" \
  grep -q '^COMMON_' "$CCF1/run/context.env"
refute "nothing is cloned" test -e "$CCF1/run/common"
expect "the skip names the arm and says it is not applicable, on stderr" \
  bash -c "grep -q 'RUN_SOURCE=frontend' '$SANDBOX/ccf1.log' && grep -qi 'not applicable' '$SANDBOX/ccf1.log'"

# The guard reads the LAST RUN_SOURCE line (last-write-wins, like every other
# anchor reader) — a stale template line above a frontend one must not re-arm
# the common side.
CCF2=$CCF/lastwins && mkdir -p "$CCF2/run" && cd "$CCF2"
printf 'module example.com/comp\n\nrequire bitbucket.org/ifs-pd/kairos-component-common/api v1.2.3\n' > go.mod
printf 'RUN_SOURCE=template\nRUN_SOURCE=frontend\n' > "$CCF2/run/context.env"
RUN=$CCF2/run COMMON_CLONE_URL=$LCRF "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccf2.out" 2> "$SANDBOX/ccf2.log"
expect "a duplicate RUN_SOURCE reads last-write-wins (frontend skips)" \
  bash -c "! grep -q '^COMMON_' '$SANDBOX/ccf2.out' && ! grep -q '^COMMON_' '$CCF2/run/context.env'"

# And the template arm is untouched: RUN_SOURCE=template (or an absent anchor —
# the suite's other blocks) still clones and records exactly as before.
CCF3=$CCF/template && mkdir -p "$CCF3/run" && cd "$CCF3"
printf 'module example.com/comp\n\nrequire bitbucket.org/ifs-pd/kairos-component-common/api v1.2.3\n' > go.mod
printf 'RUN_SOURCE=template\n' > "$CCF3/run/context.env"
RUN=$CCF3/run COMMON_CLONE_URL=$LCRF "$SKILL_DIR/scripts/clone-common.sh" \
  > "$SANDBOX/ccf3.out" 2> "$SANDBOX/ccf3.log"
expect "RUN_SOURCE=template still records COMMON_MODULES=present" \
  grep -qx 'COMMON_MODULES=present' "$CCF3/run/context.env"
expect "RUN_SOURCE=template still clones the mirror" test -f "$CCF3/run/common/HEAD"
cd "$SANDBOX"
fi

finish_suite
