#!/usr/bin/env bash
# handoff-structural.test.sh — tests for scripts/handoff-structural.sh
# TEST_FILTER refused (blocks share sequential handoff fixtures).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in handoff-structural.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "handoff-structural.sh (read-time handoff card entering Phase 6)"; then
# The planner starts from this card instead of `git show HEAD` of the whole
# structural commit — and it must not re-embed full TSV bodies or raw logs.
HS=$SANDBOX/handoff-structural
mkdir -p "$HS"
printf 'clean1.txt\nclean2.txt\nclean3.txt\n' > "$HS/clean-merged.txt"
printf 'conflict1.txt\n' > "$HS/conflicts.txt"
printf 'conflict1.txt\tours\tuser customization kept, template change dropped\nconflict1.txt\tmerged\thand-woven region combining both intents\nother.txt\ttheirs\tclean template evolution\n' > "$HS/resolutions.tsv"
printf 'docs/readme.txt\n' > "$HS/coverage-blind.txt"
echo OK > "$HS/build-postmerge.status"
printf 'pkg/foo::TestA\n' > "$HS/test-baseline.failures.txt"
printf 'pkg/foo::TestA\npkg/bar::TestB\n' > "$HS/test-postmerge.failures.txt"   # TestB is a NEW regression
printf 'fail\tchart/templates/a.yaml\tparse\tsyntax error\nskip\tchart\thelm-render\tno binary\n' > "$HS/yaml-gate-postmerge.tsv"

HS_OUT=$SANDBOX/hs.out
RUN=$HS PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$HS_OUT" 2> "$SANDBOX/hs.log"
expect "handoff-structural.sh exits 0" test $? -eq 0
refute "handoff-structural.sh does not write a disk handoff card" test -f "$HS/handoff-structural.md"
expect "clean_merged count"      grep -qx 'clean_merged: 3'      "$HS_OUT"
expect "conflicts count"         grep -qx 'conflicts: 1'         "$HS_OUT"
expect "resolutions_total count" grep -qx 'resolutions_total: 3' "$HS_OUT"
expect "resolutions_ours count (dropped template changes)"   grep -qx 'resolutions_ours: 1'   "$HS_OUT"
expect "resolutions_theirs count"                             grep -qx 'resolutions_theirs: 1' "$HS_OUT"
expect "resolutions_merged count (hand-woven, highest risk)"  grep -qx 'resolutions_merged: 1' "$HS_OUT"
expect "coverage_blind count"    grep -qx 'coverage_blind: 1'    "$HS_OUT"
expect "build_status carried through" grep -qx 'build_status: OK' "$HS_OUT"
expect "test_regressions counts only the NEW failure, not the pre-existing one" \
  grep -qx 'test_regressions: 1' "$HS_OUT"
expect "yaml_fail count"  grep -qx 'yaml_fail: 1' "$HS_OUT"
expect "yaml_skip count"  grep -qx 'yaml_skip: 1' "$HS_OUT"
expect "pointer to conflicts.txt"     grep -q "conflicts: $HS/conflicts.txt"         "$HS_OUT"
expect "pointer to resolutions.tsv"   grep -q "resolutions: $HS/resolutions.tsv"     "$HS_OUT"
expect "pointer to coverage-blind.txt" grep -q "coverage-blind: $HS/coverage-blind.txt" "$HS_OUT"
refute "handoff card does not embed a resolution's free-text reason (no TSV body)" \
  grep -q 'hand-woven region combining both intents' "$HS_OUT"

fi

if t "handoff-structural.sh reflects rework when re-read (read-time, not stale)"; then
printf 'conflict1.txt\nconflict2.txt\n' > "$HS/conflicts.txt"
HS_REWORK=$SANDBOX/hs-rework.out
RUN=$HS PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$HS_REWORK" 2> "$SANDBOX/hs-rework.log"
expect "re-read handoff exits 0" test $? -eq 0
expect "re-read handoff reflects updated conflict count" grep -qx 'conflicts: 2' "$HS_REWORK"

fi

if t "handoff-structural.sh empty inputs produce an exact well-formed document"; then
HS2=$SANDBOX/handoff-structural-empty
mkdir -p "$HS2"
: > "$HS2/clean-merged.txt"
: > "$HS2/conflicts.txt"
HS2_OUT=$SANDBOX/hs2.out
RUN=$HS2 PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$HS2_OUT" 2> "$SANDBOX/hs2.log"
expect "handoff-structural.sh still exits 0 with no resolutions/coverage-blind/build-status/yaml files" \
  test $? -eq 0
refute "empty-input handoff does not write a disk card" test -f "$HS2/handoff-structural.md"
HS2_WANT=$(cat <<EOF
# Structural handoff

clean_merged: 0
conflicts: 0
resolutions_total: 0
resolutions_ours: 0
resolutions_theirs: 0
resolutions_merged: 0
resolutions_user: 0
resolutions_ported: 0
resolutions_kept-delete: 0
resolutions_kept-customization: 0
resolutions_renamed-merged: 0
coverage_blind: 0
build_status: NOT_RUN
test_regressions: NOT_RUN
yaml_fail: 0
yaml_skip: 0
postmerge_gate: no gate card found

## Pointers
conflicts: $HS2/conflicts.txt
resolutions: $HS2/resolutions.tsv
coverage-blind: $HS2/coverage-blind.txt
gate-card: $HS2/gate-postmerge.tsv
EOF
)
if [[ "$(cat "$HS2_OUT")" = "$HS2_WANT" ]]; then
  pass "empty-input handoff stdout matches the exact expected document"
else
  fail "empty-input handoff stdout differs from the exact expected document"
  diff -u <(printf '%s\n' "$HS2_WANT") "$HS2_OUT" >&2 || true
fi
refute "empty-input handoff has no stray bare-numeric lines" \
  grep -qxE '^[0-9]+$' "$HS2_OUT"

fi

if t "handoff-structural.sh counts non-blank entries (newline/blank edge cases)"; then
HS_NL=$SANDBOX/handoff-structural-no-nl
mkdir -p "$HS_NL"
printf 'a\nb\nc' > "$HS_NL/conflicts.txt"
RUN=$HS_NL PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-nl.out" 2> "$SANDBOX/hs-nl.log"
expect "handoff-structural (no trailing newline) exits 0" test $? -eq 0
expect "handoff-structural counts 3 conflicts without trailing newline" \
  grep -qx 'conflicts: 3' "$SANDBOX/hs-nl.out"

HS_BL=$SANDBOX/handoff-structural-blank
mkdir -p "$HS_BL"
printf 'a\n\nb\n' > "$HS_BL/conflicts.txt"
RUN=$HS_BL PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-bl.out" 2> "$SANDBOX/hs-bl.log"
expect "handoff-structural (embedded blank line) exits 0" test $? -eq 0
expect "handoff-structural skips embedded blank lines (count 2)" \
  grep -qx 'conflicts: 2' "$SANDBOX/hs-bl.out"

fi

if t "handoff-structural.sh never reports a regression count on an extractor mismatch"; then
# run-check.sh writes test-postmerge.status, but the card derived its count from
# the comm alone: an EXTRACTOR_MISMATCH (command failed, extractor matched
# nothing) left an empty comm and the card printed `test_regressions: 0` — a
# false zero delivered straight into planning, with nothing downstream to
# re-check it. Worse than the Phase 8 case, which the final gate backstops.
HS_MM=$SANDBOX/handoff-structural-mismatch
mkdir -p "$HS_MM"
printf 'pkg/foo::TestA\n' > "$HS_MM/test-baseline.failures.txt"
: > "$HS_MM/test-postmerge.failures.txt"           # extractor matched nothing
echo EXTRACTOR_MISMATCH > "$HS_MM/test-postmerge.status"
RUN=$HS_MM PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-mm.out" 2> "$SANDBOX/hs-mm.log"
expect "handoff-structural (extractor mismatch) exits 0" test $? -eq 0
refute "extractor mismatch does not report zero regressions" \
  grep -qx 'test_regressions: 0' "$SANDBOX/hs-mm.out"
refute "extractor mismatch reports no number at all (nothing to misread as a count)" \
  grep -qxE 'test_regressions: [0-9]+' "$SANDBOX/hs-mm.out"
expect "extractor mismatch says the count is unavailable and why" \
  grep -qx 'test_regressions: UNAVAILABLE (EXTRACTOR_MISMATCH)' "$SANDBOX/hs-mm.out"

# Same class, different cause: the Go multi-module sweep reports SKIP when no
# module carries *_test.go, so nothing ran and the empty comm is silence again.
echo SKIP > "$HS_MM/test-postmerge.status"
RUN=$HS_MM PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-skip.out" 2> "$SANDBOX/hs-skip.log"
expect "handoff-structural (sweep SKIP) exits 0" test $? -eq 0
expect "a sweep that ran nothing says the count is unavailable and why" \
  grep -qx 'test_regressions: UNAVAILABLE (SKIP)' "$SANDBOX/hs-skip.out"

fi

if t "handoff-structural.sh keeps counting on OK / FAIL / absent post-merge status"; then
# The mismatch branch must not cost the three paths that already worked, including
# older run dirs written before run-check.sh recorded a status at all.
HS_ST=$SANDBOX/handoff-structural-status
mkdir -p "$HS_ST"
printf 'pkg/foo::TestA\n' > "$HS_ST/test-baseline.failures.txt"
printf 'pkg/bar::TestB\npkg/foo::TestA\n' > "$HS_ST/test-postmerge.failures.txt"
echo FAIL > "$HS_ST/test-postmerge.status"
RUN=$HS_ST PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-fail.out" 2> "$SANDBOX/hs-fail.log"
expect "FAIL status still counts the new failure" \
  grep -qx 'test_regressions: 1' "$SANDBOX/hs-fail.out"

echo OK > "$HS_ST/test-postmerge.status"
printf 'pkg/foo::TestA\n' > "$HS_ST/test-postmerge.failures.txt"
RUN=$HS_ST PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-ok.out" 2> "$SANDBOX/hs-ok.log"
expect "OK status with no new failures still reports a genuine zero" \
  grep -qx 'test_regressions: 0' "$SANDBOX/hs-ok.out"

rm -f "$HS_ST/test-postmerge.status"
printf 'pkg/bar::TestB\npkg/foo::TestA\n' > "$HS_ST/test-postmerge.failures.txt"
RUN=$HS_ST PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-nostatus.out" 2> "$SANDBOX/hs-nostatus.log"
expect "absent status (older run dir) keeps today's count" \
  grep -qx 'test_regressions: 1' "$SANDBOX/hs-nostatus.out"

fi

if t "handoff-structural.sh regression count survives collation drift"; then
# The two failure files are written by plain `sort -u` in whatever locale their
# sessions ran — the Phase 4.5 baseline and the post-merge run can disagree on
# LC_COLLATE. A file sorted under en_US ('a' before 'B') violates C collation
# ('B' before 'a'); comm walking it un-resorted invents phantom regressions.
# The card must re-sort both sides under LC_ALL=C before comparing.
HS_COLL=$SANDBOX/handoff-structural-collation
mkdir -p "$HS_COLL"
printf 'pkg/a::TestX\npkg/B::TestY\n' > "$HS_COLL/test-baseline.failures.txt"    # locale order, NOT C order
printf 'pkg/B::TestY\npkg/a::TestX\n' > "$HS_COLL/test-postmerge.failures.txt"   # C order, same set
echo FAIL > "$HS_COLL/test-postmerge.status"
RUN=$HS_COLL PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-coll.out" 2> "$SANDBOX/hs-coll.log"
expect "collation-drift handoff exits 0" test $? -eq 0
expect "identical failure sets in different sort orders count 0 regressions" \
  grep -qx 'test_regressions: 0' "$SANDBOX/hs-coll.out"

fi

if t "handoff-structural.sh counts resolutions from the shards too (an uncollected ledger is not zero)"; then
# The resolution tallies are counted over $RUN/resolutions.tsv UNION every
# $RUN/resolutions.<slug>.tsv shard, de-duplicated on the exact row.
# $RUN/resolutions.tsv is written by log-resolution.sh's `collect` alone, so a run
# whose session died or compacted between the last resolution and the collect has its
# whole ledger in shards — and the card printed `resolutions_total: 0` straight into
# planning, because the tallies were `[ -f resolutions.tsv ]`-guarded with zero
# defaults. The planner sizes its review from these numbers: a false zero reads as "no
# template change was dropped anywhere", which is the one thing this card exists to
# prevent. De-dup matters because after a collect every shard row is ALSO an aggregate
# row; the union must not double them.
HS_SH=$SANDBOX/handoff-structural-shards
mkdir -p "$HS_SH"
{ printf 'pkg/a.go\tours\tuser customization wins\n'
  printf 'pkg/b.go\ttheirs\ttemplate change adopted\n'
  printf 'pkg/c.go\tmerged\thand-woven from both sides\n'
  printf 'pkg/d.go\tuser\tthe user decided\n'
  printf 'web/gone.go\tkept-delete\tintent says web/ is deliberately absent\n'; } \
  > "$HS_SH/resolutions.role-switch.tsv"
RUN=$HS_SH PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-shards.out" 2> "$SANDBOX/hs-shards.log"
expect "handoff-structural (shards only) exits 0" test $? -eq 0
expect "an uncollected role-switch shard is counted in resolutions_total (5, not 0)" \
  grep -qx 'resolutions_total: 5' "$SANDBOX/hs-shards.out"
expect "per-verdict tallies read the shard too (ours)"   grep -qx 'resolutions_ours: 1'   "$SANDBOX/hs-shards.out"
expect "per-verdict tallies read the shard too (theirs)" grep -qx 'resolutions_theirs: 1' "$SANDBOX/hs-shards.out"
expect "per-verdict tallies read the shard too (merged)" grep -qx 'resolutions_merged: 1' "$SANDBOX/hs-shards.out"
expect "per-verdict tallies read the shard too (user)"   grep -qx 'resolutions_user: 1'   "$SANDBOX/hs-shards.out"
refute "the card still embeds no free-text reason from a shard" \
  grep -q 'hand-woven from both sides' "$SANDBOX/hs-shards.out"

# After the collect the same rows live in BOTH the aggregate and the shard: the union
# de-dups on the exact row, so the total stays 5.
cp "$HS_SH/resolutions.role-switch.tsv" "$HS_SH/resolutions.tsv"
RUN=$HS_SH PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-shards-coll.out" 2> "$SANDBOX/hs-shards-coll.log"
expect "a collected ledger is not double-counted against its own shards (still 5)" \
  grep -qx 'resolutions_total: 5' "$SANDBOX/hs-shards-coll.out"
expect "and neither are the per-verdict tallies (ours still 1)" \
  grep -qx 'resolutions_ours: 1' "$SANDBOX/hs-shards-coll.out"

# A LEGACY three-field shard row and its normalized aggregate twin are ONE
# resolution. log-resolution.sh's collect appends `\t-` to a pre-region-column row
# as it rebuilds the aggregate but leaves the shard's original three-field row on
# disk, so the two twins are not the same bytes — and de-duplicating on the raw row
# counted both. That inflated every tally on this card by one per legacy row, in
# exactly the resume-across-a-skill-upgrade case the normalization exists for.
HS_LEG=$SANDBOX/handoff-structural-legacy
mkdir -p "$HS_LEG"
printf 'pkg/old.go\tours\tpre-column row\n' > "$HS_LEG/resolutions.batch1.tsv"
printf 'pkg/old.go\tours\tpre-column row\t-\n' > "$HS_LEG/resolutions.tsv"
RUN=$HS_LEG PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-legacy.out" 2> "$SANDBOX/hs-legacy.log"
expect "handoff-structural (legacy twin) exits 0" test $? -eq 0
expect "a three-field shard row and its normalized aggregate twin count ONCE (total 1)" \
  grep -qx 'resolutions_total: 1' "$SANDBOX/hs-legacy.out"
expect "and once in its verdict tally (ours 1)" \
  grep -qx 'resolutions_ours: 1' "$SANDBOX/hs-legacy.out"
# Non-vacuity: a genuinely different legacy row still adds, so the normalization
# collapses twins and not the whole legacy class.
printf 'pkg/other.go\tours\tanother pre-column row\n' >> "$HS_LEG/resolutions.batch1.tsv"
RUN=$HS_LEG PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-legacy2.out" 2> "$SANDBOX/hs-legacy2.log"
expect "a second, distinct legacy row is still counted (total 2)" \
  grep -qx 'resolutions_total: 2' "$SANDBOX/hs-legacy2.out"

# A shard row the aggregate does not carry (a batch logged after the last collect)
# adds to the total instead of being invisible.
printf 'pkg/late.go\tours\tlogged after the last collect\n' > "$HS_SH/resolutions.batch9.tsv"
RUN=$HS_SH PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-shards-late.out" 2> "$SANDBOX/hs-shards-late.log"
expect "a post-collect shard row is counted (total 6)" \
  grep -qx 'resolutions_total: 6' "$SANDBOX/hs-shards-late.out"
expect "and lands in its verdict tally (ours 2)" \
  grep -qx 'resolutions_ours: 2' "$SANDBOX/hs-shards-late.out"

fi

if t "handoff-structural.sh tallies every verdict the resolution ledger can carry"; then
# log-resolution.sh owns a CLOSED verdict vocabulary of eight kinds: the four mechanical
# ones (ours/theirs/merged/user) and the four reasoning-bucket ones the conflict-resolver
# assigns to modify-delete and rename cases (ported/kept-delete/kept-customization/
# renamed-merged). The card tallied only the first four, so every reasoning-bucket
# verdict was counted in resolutions_total and then named nowhere — and those are the
# EXPENSIVE rows: a `kept-delete` drops a template change outright and a `ported` moves
# it somewhere the planner has to go look. The planner sizes its review from this card,
# so an unnamed row is a review that never happens. The arithmetic is the tell: total
# minus the four printed tallies was a silent remainder.
HS_V=$SANDBOX/handoff-structural-verdicts
mkdir -p "$HS_V"
# The vocabulary is read from log-resolution.sh's own accepted-verdict case arm, not
# retyped here: a ninth kind added there must fail this block rather than pass it.
HS_VOCAB=$(grep -oE 'ours\|[a-z|-]+\) ;;' "$SKILL_DIR/scripts/log-resolution.sh" \
           | head -1 | sed 's/) ;;$//' | tr '|' ' ')
HS_NVOCAB=$(printf '%s\n' $HS_VOCAB | grep -c .)
if [[ "${HS_NVOCAB:-0}" -ge 8 ]]; then
  pass "the accepted-verdict vocabulary extracts from log-resolution.sh ($HS_NVOCAB kind(s))"
else
  fail "the accepted-verdict vocabulary extracts from log-resolution.sh (got ${HS_NVOCAB:-0}, want >=8 — the case arm moved)"
fi
expect "the extracted vocabulary includes the reasoning-bucket verdicts" \
  bash -c 'printf "%s\n" $1 | grep -qx kept-delete && printf "%s\n" $1 | grep -qx renamed-merged' _ "$HS_VOCAB"
# One row per kind, logged through log-resolution.sh itself so the ledger is written by
# its format owner rather than by a printf that could drift from it.
LRS_V="$SKILL_DIR/scripts/log-resolution.sh"
# REGION=1 satisfies the writer's now-required ordinal for the four conflict-region
# verdicts; the four reasoning-bucket verdicts force it to '-' regardless.
for v in $HS_VOCAB; do
  RUN=$HS_V SHARD=b1 FILE="pkg/$v.go" VERDICT="$v" REASON="one $v row" REGION=1 bash "$LRS_V" >/dev/null 2>&1
done
HS_VOUT=$SANDBOX/hs-verdicts.out
RUN=$HS_V PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$HS_VOUT" 2> "$SANDBOX/hs-verdicts.log"
expect "handoff-structural (one row per verdict kind) exits 0" test $? -eq 0
expect "resolutions_total counts every kind" grep -qx "resolutions_total: $HS_NVOCAB" "$HS_VOUT"
for v in $HS_VOCAB; do
  expect "the card names the '$v' tally" grep -qx "resolutions_$v: 1" "$HS_VOUT"
done
# The invariant, and what a ninth unnamed kind would break: the per-verdict tallies must
# ACCOUNT FOR the total, so no row can be counted and then left unnamed.
HS_SUM=$(awk -F': ' '/^resolutions_/ && $1 != "resolutions_total" { n += $2 } END { print n+0 }' "$HS_VOUT")
HS_TOT=$(awk -F': ' '/^resolutions_total: / { print $2 }' "$HS_VOUT")
if [[ "$HS_SUM" = "$HS_TOT" ]]; then
  pass "the per-verdict tallies sum to resolutions_total ($HS_SUM) — no row is counted and then unnamed"
else
  fail "the per-verdict tallies sum to resolutions_total (sum $HS_SUM vs total $HS_TOT — $((HS_TOT - HS_SUM)) row(s) counted but named nowhere)"
fi
refute "the verdict tallies still embed no free-text reason" grep -q 'one kept-delete row' "$HS_VOUT"

fi

if t "handoff-structural.sh carries the postmerge-gate verdict"; then
# agents/planner.md promises the card includes the postmerge-gate verdict; it must
# come from $RUN/gate-postmerge.tsv (gate.sh's card), aggregate plus every
# non-PASS check row — and degrade to an explicit absence marker, never silence.
printf 'build\tPASS\tbuild clean\tstatus=OK\ntests\tFAIL\t2 new failing test ID(s) vs baseline: a,b\tx vs y\nyaml\tINCOMPLETE\t1 skipped layer\tz\nAGGREGATE\tFAIL\n' \
  > "$HS/gate-postmerge.tsv"
RUN=$HS PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-gate.out" 2> "$SANDBOX/hs-gate.log"
expect "gate AGGREGATE verdict carried into the card" grep -qx 'postmerge_gate: FAIL' "$SANDBOX/hs-gate.out"
expect "non-PASS gate row surfaces (tests FAIL)" \
  grep -q '^postmerge_gate_row: tests FAIL' "$SANDBOX/hs-gate.out"
expect "non-PASS gate row surfaces (yaml INCOMPLETE)" \
  grep -q '^postmerge_gate_row: yaml INCOMPLETE' "$SANDBOX/hs-gate.out"
refute "PASS gate rows are not repeated in the card" \
  grep -q '^postmerge_gate_row: build' "$SANDBOX/hs-gate.out"
expect "gate-card pointer present" grep -q "gate-card: $HS/gate-postmerge.tsv" "$SANDBOX/hs-gate.out"
rm -f "$HS/gate-postmerge.tsv"
RUN=$HS PHASE_KEY=$PK_PLANNING "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/hs-nogate.out" 2> "$SANDBOX/hs-nogate.log"
expect "an absent gate card degrades to an explicit marker" \
  grep -qx 'postmerge_gate: no gate card found' "$SANDBOX/hs-nogate.out"

fi

finish_suite
