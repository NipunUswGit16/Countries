#!/usr/bin/env bash
# census-diff.test.sh — tests for scripts/census-diff.sh
# TEST_FILTER supported (every block builds its own isolated $RUN fixture dir).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

CD="$SKILL_DIR/scripts/census-diff.sh"

# status_of/detail_of/evidence_of <row-file> — the row is exactly one line:
# `census <TAB> STATUS <TAB> detail <TAB> evidence`.
status_of()   { awk -F'\t' 'NR==1{print $2}' "$1"; }
detail_of()   { awk -F'\t' 'NR==1{print $3}' "$1"; }
evidence_of() { awk -F'\t' 'NR==1{print $4}' "$1"; }

if t "census-diff.sh — a disappeared test at final (postmerge usable) is executor-era, row FAIL"; then
R1=$SANDBOX/cd1
mkdir -p "$R1"
printf 'TestA\nTestB\n' > "$R1/test-postmerge.population.txt"
: > "$R1/test-postmerge.skips.txt"
printf 'OK\n' > "$R1/test-postmerge.census.status"
printf 'TestB\n' > "$R1/test-final.population.txt"
: > "$R1/test-final.skips.txt"
printf 'OK\n' > "$R1/test-final.census.status"

OUT=$(RUN="$R1" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd1.row"
if [[ "$rc" -ne 0 ]]; then pass "census-diff: a disappeared test exits non-zero"; else fail "census-diff: a disappeared test exits non-zero (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd1.row")" = FAIL ]]; then pass "census-diff: a disappeared test is row FAIL"; else fail "census-diff: a disappeared test is row FAIL (got '$(status_of "$SANDBOX/cd1.row")')"; fi
expect "census-diff: the disappearance is recorded executor-era in census-final.tsv" \
  grep -qxF "$(printf 'disappeared\tTestA\texecutor-era')" "$R1/census-final.tsv"

fi

if t "census-diff.sh — the same absence already present at postmerge vs baseline is template-era CONTEXT, not a finding: row PASS"; then
R2=$SANDBOX/cd2
mkdir -p "$R2"
printf 'TestX\nTestY\n' > "$R2/test-baseline.population.txt"
: > "$R2/test-baseline.skips.txt"
printf 'OK\n' > "$R2/test-baseline.census.status"
# TestX already gone by postmerge (structural merge deleted it) — nothing left for
# the executor-era diff to blame.
printf 'TestY\n' > "$R2/test-postmerge.population.txt"
: > "$R2/test-postmerge.skips.txt"
printf 'OK\n' > "$R2/test-postmerge.census.status"
printf 'TestY\n' > "$R2/test-final.population.txt"
: > "$R2/test-final.skips.txt"
printf 'OK\n' > "$R2/test-final.census.status"

OUT=$(RUN="$R2" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd2.row"
if [[ "$rc" -eq 0 ]]; then pass "census-diff: a template-era-only removal exits 0"; else fail "census-diff: a template-era-only removal exits 0 (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd2.row")" = PASS ]]; then pass "census-diff: a template-era-only removal is row PASS"; else fail "census-diff: a template-era-only removal is row PASS (got '$(status_of "$SANDBOX/cd2.row")')"; fi
expect "census-diff: TestX never appears as an executor-era finding" \
  bash -c "! grep -qF 'TestX' '$R2/census-final.tsv' 2>/dev/null"
expect "census-diff: census-final.tsv is empty on PASS" test ! -s "$R2/census-final.tsv"
if printf '%s' "$(detail_of "$SANDBOX/cd2.row")" | grep -qF 'template-era'; then
  pass "census-diff: the template-era removal still shows as CONTEXT on the detail line"
else
  fail "census-diff: the template-era removal still shows as CONTEXT on the detail line (got '$(detail_of "$SANDBOX/cd2.row")')"
fi

fi

if t "census-diff.sh — pass at postmerge, skip at final is newly-skipped, row FAIL"; then
R3=$SANDBOX/cd3
mkdir -p "$R3"
printf 'TestA\nTestB\n' > "$R3/test-postmerge.population.txt"
: > "$R3/test-postmerge.skips.txt"
printf 'OK\n' > "$R3/test-postmerge.census.status"
printf 'TestA\n' > "$R3/test-final.population.txt"
printf 'TestB\n' > "$R3/test-final.skips.txt"
printf 'OK\n' > "$R3/test-final.census.status"

OUT=$(RUN="$R3" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd3.row"
if [[ "$rc" -ne 0 ]]; then pass "census-diff: a newly-skipped test exits non-zero"; else fail "census-diff: a newly-skipped test exits non-zero (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd3.row")" = FAIL ]]; then pass "census-diff: a newly-skipped test is row FAIL"; else fail "census-diff: a newly-skipped test is row FAIL (got '$(status_of "$SANDBOX/cd3.row")')"; fi
expect "census-diff: the silencing is recorded newly-skipped executor-era in census-final.tsv" \
  grep -qxF "$(printf 'newly-skipped\tTestB\texecutor-era')" "$R3/census-final.tsv"
expect "census-diff: TestB is never ALSO recorded as disappeared (it is seen, just skipped)" \
  bash -c "! grep -qF 'disappeared	TestB' '$R3/census-final.tsv'"

fi

if t "census-diff.sh — a born-skipped new test (never in any population) is NO census finding: row PASS"; then
# This is the documented boundary: the census sees what stopped, never what arrived
# already silenced. A skip at final that was never a population member anywhere
# must not read as a finding of any kind.
R4=$SANDBOX/cd4
mkdir -p "$R4"
printf 'TestA\n' > "$R4/test-postmerge.population.txt"
: > "$R4/test-postmerge.skips.txt"
printf 'OK\n' > "$R4/test-postmerge.census.status"
printf 'TestA\n' > "$R4/test-final.population.txt"
printf 'TestNew\n' > "$R4/test-final.skips.txt"
printf 'OK\n' > "$R4/test-final.census.status"

OUT=$(RUN="$R4" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd4.row"
if [[ "$rc" -eq 0 ]]; then pass "census-diff: a born-skipped new test exits 0"; else fail "census-diff: a born-skipped new test exits 0 (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd4.row")" = PASS ]]; then pass "census-diff: a born-skipped new test is row PASS"; else fail "census-diff: a born-skipped new test is row PASS (got '$(status_of "$SANDBOX/cd4.row")')"; fi
expect "census-diff: census-final.tsv carries NO finding for the born-skipped test (the construct scan's blind spot, not this diff's)" \
  test ! -s "$R4/census-final.tsv"

fi

if t "census-diff.sh — a renamed test is one disappeared finding plus a non-zero added count, row FAIL"; then
R5=$SANDBOX/cd5
mkdir -p "$R5"
printf 'TestOld\n' > "$R5/test-postmerge.population.txt"
: > "$R5/test-postmerge.skips.txt"
printf 'OK\n' > "$R5/test-postmerge.census.status"
printf 'TestNew\n' > "$R5/test-final.population.txt"
: > "$R5/test-final.skips.txt"
printf 'OK\n' > "$R5/test-final.census.status"

OUT=$(RUN="$R5" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd5.row"
if [[ "$rc" -ne 0 ]]; then pass "census-diff: a rename exits non-zero"; else fail "census-diff: a rename exits non-zero (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd5.row")" = FAIL ]]; then pass "census-diff: a rename is row FAIL"; else fail "census-diff: a rename is row FAIL (got '$(status_of "$SANDBOX/cd5.row")')"; fi
expect "census-diff: the old id is recorded disappeared" \
  grep -qxF "$(printf 'disappeared\tTestOld\texecutor-era')" "$R5/census-final.tsv"
if [[ "$(grep -c . "$R5/census-final.tsv")" = 1 ]]; then pass "census-diff: a rename yields exactly one finding line, not two"; else fail "census-diff: a rename yields exactly one finding line, not two"; fi
if printf '%s' "$(detail_of "$SANDBOX/cd5.row")" | grep -qE '[1-9][0-9]* added'; then
  pass "census-diff: the detail names a non-zero added count alongside the disappearance"
else
  fail "census-diff: the detail names a non-zero added count alongside the disappearance (got '$(detail_of "$SANDBOX/cd5.row")')"
fi

fi

if t "census-diff.sh — postmerge census MISSING degrades to a single baseline->final diff, findings labeled unattributed, row FAIL"; then
R6=$SANDBOX/cd6
mkdir -p "$R6"
printf 'TestA\nTestB\n' > "$R6/test-baseline.population.txt"
: > "$R6/test-baseline.skips.txt"
printf 'OK\n' > "$R6/test-baseline.census.status"
# postmerge census never recorded at all — no .population.txt, no .skips.txt, no
# .census.status (a run resumed across the upgrade).
printf 'TestA\n' > "$R6/test-final.population.txt"
: > "$R6/test-final.skips.txt"
printf 'OK\n' > "$R6/test-final.census.status"

OUT=$(RUN="$R6" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd6.row"
if [[ "$rc" -ne 0 ]]; then pass "census-diff: a missing postmerge census with a real disappearance exits non-zero"; else fail "census-diff: a missing postmerge census with a real disappearance exits non-zero (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd6.row")" = FAIL ]]; then pass "census-diff: a missing postmerge census, disappearance present, is row FAIL"; else fail "census-diff: a missing postmerge census, disappearance present, is row FAIL (got '$(status_of "$SANDBOX/cd6.row")')"; fi
expect "census-diff: the finding is recorded UNATTRIBUTED (baseline->final, not executor-era)" \
  grep -qxF "$(printf 'disappeared\tTestB\tunattributed')" "$R6/census-final.tsv"
if printf '%s' "$(detail_of "$SANDBOX/cd6.row")" | grep -qF 'unattributed'; then
  pass "census-diff: the detail names the degrade as unattributed"
else
  fail "census-diff: the detail names the degrade as unattributed (got '$(detail_of "$SANDBOX/cd6.row")')"
fi

fi

if t "census-diff.sh — baseline census ALSO missing (only final present): row INCOMPLETE, exit non-zero, census-final.tsv empty"; then
R7=$SANDBOX/cd7
mkdir -p "$R7"
# Neither baseline nor postmerge ever recorded a census — only final has one.
printf 'TestA\n' > "$R7/test-final.population.txt"
: > "$R7/test-final.skips.txt"
printf 'OK\n' > "$R7/test-final.census.status"

OUT=$(RUN="$R7" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd7.row"
if [[ "$rc" -ne 0 ]]; then pass "census-diff: no usable base epoch exits non-zero"; else fail "census-diff: no usable base epoch exits non-zero (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd7.row")" = INCOMPLETE ]]; then pass "census-diff: no usable base epoch is row INCOMPLETE"; else fail "census-diff: no usable base epoch is row INCOMPLETE (got '$(status_of "$SANDBOX/cd7.row")')"; fi
expect "census-diff: census-final.tsv carries no artifact that could read as clean" \
  test ! -s "$R7/census-final.tsv"

fi

if t "census-diff.sh — both finding sets empty: row PASS with a positive-evidence detail naming population sizes compared"; then
R8=$SANDBOX/cd8
mkdir -p "$R8"
printf 'TestA\nTestB\n' > "$R8/test-postmerge.population.txt"
: > "$R8/test-postmerge.skips.txt"
printf 'OK\n' > "$R8/test-postmerge.census.status"
printf 'TestA\nTestB\n' > "$R8/test-final.population.txt"
: > "$R8/test-final.skips.txt"
printf 'OK\n' > "$R8/test-final.census.status"

OUT=$(RUN="$R8" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd8.row"
if [[ "$rc" -eq 0 ]]; then pass "census-diff: a clean run exits 0"; else fail "census-diff: a clean run exits 0 (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd8.row")" = PASS ]]; then pass "census-diff: a clean run is row PASS"; else fail "census-diff: a clean run is row PASS (got '$(status_of "$SANDBOX/cd8.row")')"; fi
if printf '%s' "$(evidence_of "$SANDBOX/cd8.row")" | grep -qE '2 base .* vs 2 final'; then
  pass "census-diff: the evidence names the population sizes actually compared, not a bare 'ok'"
else
  fail "census-diff: the evidence names the population sizes actually compared, not a bare 'ok' (got '$(evidence_of "$SANDBOX/cd8.row")')"
fi

fi

if t "census-diff.sh — a MISMATCH at the final epoch is row INCOMPLETE, never PASS, never findings"; then
R9=$SANDBOX/cd9
mkdir -p "$R9"
printf 'TestA\nTestB\n' > "$R9/test-baseline.population.txt"
: > "$R9/test-baseline.skips.txt"
printf 'OK\n' > "$R9/test-baseline.census.status"
printf 'TestA\nTestB\n' > "$R9/test-postmerge.population.txt"
: > "$R9/test-postmerge.skips.txt"
printf 'OK\n' > "$R9/test-postmerge.census.status"
# The final run-check subset cross-check failed: run-check.sh deletes the
# population/skips artifacts on MISMATCH and writes only the status.
printf 'MISMATCH\n' > "$R9/test-final.census.status"

OUT=$(RUN="$R9" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd9.row"
if [[ "$rc" -ne 0 ]]; then pass "census-diff: a MISMATCH at final exits non-zero"; else fail "census-diff: a MISMATCH at final exits non-zero (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd9.row")" = INCOMPLETE ]]; then pass "census-diff: a MISMATCH at final is row INCOMPLETE"; else fail "census-diff: a MISMATCH at final is row INCOMPLETE (got '$(status_of "$SANDBOX/cd9.row")')"; fi
if printf '%s' "$(detail_of "$SANDBOX/cd9.row")" | grep -qi 'MISMATCH'; then
  pass "census-diff: the detail names the MISMATCH"
else
  fail "census-diff: the detail names the MISMATCH (got '$(detail_of "$SANDBOX/cd9.row")')"
fi
expect "census-diff: census-final.tsv is empty (no findings derived from a discarded census)" \
  test ! -s "$R9/census-final.tsv"

fi

if t "census-diff.sh — a FAILED census (the recipe errored) is row INCOMPLETE, never PASS, even broken at every epoch"; then
# The C1 downstream: a model-authored recipe broken from the start (missing tool,
# wrong flag) errors at EVERY epoch. run-check.sh now records census.status FAILED and
# discards the population rather than writing OK over an empty one. If census-diff
# treated FAILED like OK, its empty↔empty arm would certify PASS — the layer built to
# catch MISSING GREEN reporting clean on a component whose census never ran. It must
# read FAILED as unusable → INCOMPLETE, exactly as MISMATCH.
R17=$SANDBOX/cd17
mkdir -p "$R17"
# Broken at baseline and final: status FAILED, no population/skips files (run-check.sh
# deletes them on a FAILED recipe).
printf 'FAILED\n' > "$R17/test-baseline.census.status"
printf 'FAILED\n' > "$R17/test-final.census.status"

OUT=$(RUN="$R17" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd17.row"
if [[ "$rc" -ne 0 ]]; then pass "census-diff: a FAILED census at final exits non-zero"; else fail "census-diff: a FAILED census at final exits non-zero (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd17.row")" = INCOMPLETE ]]; then pass "census-diff: a FAILED census at final is row INCOMPLETE, never PASS"; else fail "census-diff: a FAILED census at final is row INCOMPLETE (got '$(status_of "$SANDBOX/cd17.row")')"; fi
detail_of "$SANDBOX/cd17.row" > "$SANDBOX/cd17.detail"
if grep -qi 'FAILED' "$SANDBOX/cd17.detail"; then
  pass "census-diff: the detail names the census as FAILED (the recipe errored)"
else
  fail "census-diff: the detail names the census as FAILED (got '$(cat "$SANDBOX/cd17.detail")')"
fi
refute "census-diff: a FAILED census manufactures no empty↔empty PASS rationale" \
  grep -qi 'never a population to lose' "$SANDBOX/cd17.detail"
expect "census-diff: a FAILED census writes no findings" test ! -s "$R17/census-final.tsv"

# The counterpart the FAILED rule protects: a usable base epoch with a FAILED final —
# still INCOMPLETE (the question cannot be asked at final), never a disappearance FAIL
# invented from an absent population.
R18=$SANDBOX/cd18
mkdir -p "$R18"
printf 'TestA\nTestB\n' > "$R18/test-postmerge.population.txt"
: > "$R18/test-postmerge.skips.txt"
printf 'OK\n' > "$R18/test-postmerge.census.status"
printf 'FAILED\n' > "$R18/test-final.census.status"
OUT=$(RUN="$R18" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd18.row"
if [[ "$(status_of "$SANDBOX/cd18.row")" = INCOMPLETE ]]; then pass "census-diff: a FAILED final against a populated base is INCOMPLETE, not a mass-disappearance FAIL"; else fail "census-diff: a FAILED final against a populated base is INCOMPLETE (got '$(status_of "$SANDBOX/cd18.row")')"; fi
detail_of "$SANDBOX/cd18.row" > "$SANDBOX/cd18.detail"
refute "census-diff: a FAILED final invents no mass-disappearance" \
  grep -qi 'mass test disappearance' "$SANDBOX/cd18.detail"

fi

if t "census-diff.sh — a populated base epoch and an empty-but-censused final epoch is a mass-disappearance FAIL, with the rationale in the row"; then
# The fail-closed posture: deleting every test in the component is the one total-loss
# case the census exists for, and NO other gate row can see it — every other row
# compares FAILURE sets, and a component with no tests left produces no failures. So
# populated → empty is a FAIL, not an INCOMPLETE riding through a passing aggregate.
R10=$SANDBOX/cd10
mkdir -p "$R10"
printf 'TestA\nTestB\n' > "$R10/test-postmerge.population.txt"
: > "$R10/test-postmerge.skips.txt"
printf 'OK\n' > "$R10/test-postmerge.census.status"
# The final epoch RAN and censused nothing: status OK, population file present, empty.
: > "$R10/test-final.population.txt"
: > "$R10/test-final.skips.txt"
printf 'OK\n' > "$R10/test-final.census.status"

OUT=$(RUN="$R10" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd10.row"
if [[ "$rc" -ne 0 ]]; then pass "census-diff: a populated->empty transition exits non-zero"; else fail "census-diff: a populated->empty transition exits non-zero (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd10.row")" = FAIL ]]; then pass "census-diff: a populated->empty transition is row FAIL"; else fail "census-diff: a populated->empty transition is row FAIL (got '$(status_of "$SANDBOX/cd10.row")')"; fi
# The user-visible rationale, not a bare count: the operator must be able to read WHY
# from the row alone.
if printf '%s' "$(detail_of "$SANDBOX/cd10.row")" | grep -qiF 'mass test disappearance'; then
  pass "census-diff: the row carries the mass-test-disappearance rationale"
else
  fail "census-diff: the row carries the mass-test-disappearance rationale (got '$(detail_of "$SANDBOX/cd10.row")')"
fi
if printf '%s' "$(detail_of "$SANDBOX/cd10.row")" | grep -qi 'census recipe'; then
  pass "census-diff: the row also names the other explanation the operator must rule out (a census recipe that stopped matching)"
else
  fail "census-diff: the row also names the other explanation the operator must rule out (got '$(detail_of "$SANDBOX/cd10.row")')"
fi
expect "census-diff: every id that stopped running is recorded as a finding, era-labeled" \
  grep -qxF "$(printf 'disappeared\tTestA\texecutor-era')" "$R10/census-final.tsv"
expect "census-diff: the second id too (the artifact carries the whole loss, the row carries the rationale)" \
  grep -qxF "$(printf 'disappeared\tTestB\texecutor-era')" "$R10/census-final.tsv"

# The preserved distinction (the thing that makes the rule above safe): "the suite ran
# and censused an empty population" is a FAIL, "no census at all" stays INCOMPLETE.
# Same fixture, minus the final epoch's population FILE — nothing ran, nothing censused.
rm -f "$R10/test-final.population.txt"
OUT=$(RUN="$R10" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd10b.row"
if [[ "$(status_of "$SANDBOX/cd10b.row")" = INCOMPLETE ]]; then pass "census-diff: an ABSENT final census is still INCOMPLETE, never the mass-disappearance FAIL"; else fail "census-diff: an ABSENT final census is still INCOMPLETE, never the mass-disappearance FAIL (got '$(status_of "$SANDBOX/cd10b.row")')"; fi
detail_of "$SANDBOX/cd10b.row" > "$SANDBOX/cd10b.detail"
refute "census-diff: an absent final census manufactures no mass-disappearance rationale" \
  grep -qi 'mass test disappearance' "$SANDBOX/cd10b.detail"
expect "census-diff: an absent final census writes no findings" \
  test ! -s "$R10/census-final.tsv"

fi

if t "census-diff.sh — an empty base epoch and an empty final epoch stays green: nothing was ever there to disappear"; then
# The false positive the rule above must never produce: a component with a legitimately
# test-free population (an all-helpers module set — run-check-modules.sh writes census
# status OK with an empty population for exactly that) censuses empty at every epoch.
# Empty->empty is not a transition, so it is a PASS.
R13=$SANDBOX/cd13
mkdir -p "$R13"
: > "$R13/test-baseline.population.txt"
: > "$R13/test-baseline.skips.txt"
printf 'OK\n' > "$R13/test-baseline.census.status"
: > "$R13/test-final.population.txt"
: > "$R13/test-final.skips.txt"
printf 'OK\n' > "$R13/test-final.census.status"

OUT=$(RUN="$R13" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd13.row"
if [[ "$rc" -eq 0 ]]; then pass "census-diff: empty base + empty final exits 0"; else fail "census-diff: empty base + empty final exits 0 (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd13.row")" = PASS ]]; then pass "census-diff: empty base + empty final is row PASS"; else fail "census-diff: empty base + empty final is row PASS (got '$(status_of "$SANDBOX/cd13.row")')"; fi
detail_of "$SANDBOX/cd13.row" > "$SANDBOX/cd13.detail"
refute "census-diff: no mass-disappearance is claimed against a population that never existed" \
  grep -qi 'mass test disappearance' "$SANDBOX/cd13.detail"
expect "census-diff: census-final.tsv is empty on that PASS" test ! -s "$R13/census-final.tsv"
# Same shape at the postmerge epoch rather than the baseline: still green.
R14=$SANDBOX/cd14
mkdir -p "$R14"
: > "$R14/test-postmerge.population.txt"
: > "$R14/test-postmerge.skips.txt"
printf 'OK\n' > "$R14/test-postmerge.census.status"
: > "$R14/test-final.population.txt"
: > "$R14/test-final.skips.txt"
printf 'OK\n' > "$R14/test-final.census.status"
OUT=$(RUN="$R14" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd14.row"
if [[ "$(status_of "$SANDBOX/cd14.row")" = PASS ]]; then pass "census-diff: an empty postmerge epoch with an empty final epoch is row PASS too"; else fail "census-diff: an empty postmerge epoch with an empty final epoch is row PASS too (got '$(status_of "$SANDBOX/cd14.row")')"; fi

fi

if t "census-diff.sh — an INCOMPLETE reason names the epoch that actually failed, per epoch"; then
# The mislabeled-reason regression: both base epochs unusable, and the row reported the
# BASELINE probe's reason behind a hardcoded 'postmerge:' label — sending the reader to
# the wrong artifact. Each reason must name its own epoch, and both must appear.
R15=$SANDBOX/cd15
mkdir -p "$R15"
# postmerge: censused, then discarded as internally inconsistent.
printf 'MISMATCH\n' > "$R15/test-postmerge.census.status"
# baseline: never censused at all.
printf 'TestA\n' > "$R15/test-final.population.txt"
: > "$R15/test-final.skips.txt"
printf 'OK\n' > "$R15/test-final.census.status"

OUT=$(RUN="$R15" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd15.row"
if [[ "$(status_of "$SANDBOX/cd15.row")" = INCOMPLETE ]]; then pass "census-diff: no usable base epoch is row INCOMPLETE"; else fail "census-diff: no usable base epoch is row INCOMPLETE (got '$(status_of "$SANDBOX/cd15.row")')"; fi
detail_of "$SANDBOX/cd15.row" > "$SANDBOX/cd15.detail"
CD15_DET=$(cat "$SANDBOX/cd15.detail")
if grep -qE 'postmerge census MISMATCH' "$SANDBOX/cd15.detail"; then
  pass "census-diff: the postmerge MISMATCH is reported under the postmerge epoch's name"
else
  fail "census-diff: the postmerge MISMATCH is reported under the postmerge epoch's name (got '$CD15_DET')"
fi
if grep -qE 'baseline census absent' "$SANDBOX/cd15.detail"; then
  pass "census-diff: the baseline failure is reported under the baseline epoch's name, not relabeled postmerge"
else
  fail "census-diff: the baseline failure is reported under the baseline epoch's name, not relabeled postmerge (got '$CD15_DET')"
fi
refute "census-diff: no baseline reason is ever printed behind a postmerge label" \
  grep -qE 'postmerge: baseline' "$SANDBOX/cd15.detail"

fi

if t "census-diff.sh — an empty postmerge population degrades to baseline rather than manufacturing a suite-wide disappearance"; then
R11=$SANDBOX/cd11
mkdir -p "$R11"
printf 'TestA\nTestB\n' > "$R11/test-baseline.population.txt"
: > "$R11/test-baseline.skips.txt"
printf 'OK\n' > "$R11/test-baseline.census.status"
# postmerge census.status is OK but its population is empty — a broken recipe on
# that run, not a real "everything vanished at postmerge" event.
: > "$R11/test-postmerge.population.txt"
: > "$R11/test-postmerge.skips.txt"
printf 'OK\n' > "$R11/test-postmerge.census.status"
printf 'TestA\nTestB\n' > "$R11/test-final.population.txt"
: > "$R11/test-final.skips.txt"
printf 'OK\n' > "$R11/test-final.census.status"

OUT=$(RUN="$R11" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd11.row"
if [[ "$rc" -eq 0 ]]; then pass "census-diff: an empty postmerge population that degrades cleanly to baseline exits 0"; else fail "census-diff: an empty postmerge population that degrades cleanly to baseline exits 0 (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd11.row")" = PASS ]]; then pass "census-diff: no mass-disappearance is manufactured from an empty postmerge population"; else fail "census-diff: no mass-disappearance is manufactured from an empty postmerge population (got '$(status_of "$SANDBOX/cd11.row")')"; fi
if printf '%s' "$(detail_of "$SANDBOX/cd11.row")" | grep -qF 'unattributed'; then
  pass "census-diff: the detail attributes the diff as unattributed (degraded to baseline, not postmerge)"
else
  fail "census-diff: the detail attributes the diff as unattributed (degraded to baseline, not postmerge) (got '$(detail_of "$SANDBOX/cd11.row")')"
fi

fi

if t "census-diff.sh — LABEL=postmerge is always row INCOMPLETE (informational relay), detail carries the template-era count"; then
R12=$SANDBOX/cd12
mkdir -p "$R12"
printf 'TestA\nTestB\nTestC\n' > "$R12/test-baseline.population.txt"
: > "$R12/test-baseline.skips.txt"
printf 'OK\n' > "$R12/test-baseline.census.status"
printf 'TestA\nTestB\n' > "$R12/test-postmerge.population.txt"
: > "$R12/test-postmerge.skips.txt"
printf 'OK\n' > "$R12/test-postmerge.census.status"

OUT=$(RUN="$R12" LABEL=postmerge bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd12.row"
if [[ "$rc" -ne 0 ]]; then pass "census-diff: LABEL=postmerge exits non-zero (it blocks nothing, but is never a pass either)"; else fail "census-diff: LABEL=postmerge exits non-zero (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd12.row")" = INCOMPLETE ]]; then pass "census-diff: LABEL=postmerge is row INCOMPLETE"; else fail "census-diff: LABEL=postmerge is row INCOMPLETE (got '$(status_of "$SANDBOX/cd12.row")')"; fi
if printf '%s' "$(detail_of "$SANDBOX/cd12.row")" | grep -qE 'template-era.*1 removed, 0 added'; then
  pass "census-diff: the detail carries the template-era removed/added count for the planner"
else
  fail "census-diff: the detail carries the template-era removed/added count for the planner (got '$(detail_of "$SANDBOX/cd12.row")')"
fi
expect "census-diff: LABEL=postmerge never writes a census-final.tsv" \
  test ! -e "$R12/census-final.tsv"

fi

if t "census-diff.sh — the verdict stands even when the evidence file itself cannot be written, but the row says so"; then
# The verdict (PASS/FAIL) is computed from $WORK, never from the $OUTTSV write —
# so a failed write must not flip it. But `> "$OUTTSV" 2>/dev/null || true`
# used to swallow that failure outright: the row read clean while the evidence
# file it points at was silently missing/partial. Force the write to fail
# DAC-independently by pre-creating census-final.tsv as a DIRECTORY.
R16=$SANDBOX/cd16
mkdir -p "$R16" "$R16/census-final.tsv"
printf 'TestA\nTestB\n' > "$R16/test-postmerge.population.txt"
: > "$R16/test-postmerge.skips.txt"
printf 'OK\n' > "$R16/test-postmerge.census.status"
printf 'TestB\n' > "$R16/test-final.population.txt"
: > "$R16/test-final.skips.txt"
printf 'OK\n' > "$R16/test-final.census.status"

OUT=$(RUN="$R16" LABEL=final bash "$CD"); rc=$?
printf '%s' "$OUT" > "$SANDBOX/cd16.row"
if [[ "$rc" -ne 0 ]]; then pass "census-diff: the verdict (disappeared TestA) still exits non-zero despite the evidence write failure"; else fail "census-diff: the verdict still exits non-zero despite the evidence write failure (rc=$rc)"; fi
if [[ "$(status_of "$SANDBOX/cd16.row")" = FAIL ]]; then pass "census-diff: the row is still FAIL — the write failure does not flip the verdict"; else fail "census-diff: the row is still FAIL (got '$(status_of "$SANDBOX/cd16.row")')"; fi
if printf '%s' "$(detail_of "$SANDBOX/cd16.row")" | grep -qi 'evidence write failed'; then
  pass "census-diff: the detail surfaces the evidence write failure instead of swallowing it"
else
  fail "census-diff: the detail surfaces the evidence write failure (got '$(detail_of "$SANDBOX/cd16.row")')"
fi
rmdir "$R16/census-final.tsv" 2>/dev/null || true

fi

finish_suite
