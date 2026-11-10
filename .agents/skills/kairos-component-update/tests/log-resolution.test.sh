#!/usr/bin/env bash
# log-resolution.test.sh — tests for scripts/log-resolution.sh
# TEST_FILTER supported (blocks are independent; each builds its own $RUN).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

LRS="$SKILL_DIR/scripts/log-resolution.sh"

if t "log-resolution.sh append — one verdict costs exactly one four-column row"; then
# This block PINS the interface:
#   env in : RUN (required), SHARD (the batch slug, or unset for the role-switch
#            fallback's single file), FILE, VERDICT, REASON, REGION. ACTION defaults
#            to append.
#   effect : one `<file> <TAB> <verdict> <TAB> <reason> <TAB> <region>` row appended
#            to $RUN/resolutions.<slug>.tsv, or to $RUN/resolutions.tsv when SHARD is
#            unset. NO header row — handoff-structural.sh and spawn-summary.sh both
#            count non-empty lines, so a header would inflate every tally by one.
#            REGION is the LAST field on purpose: the three consumers parse $1/$2, so
#            appending is invisible to them (see the consumer-compat block below).
#   WHY a writer: this ledger has FOUR machine parsers and had no format owner. The
#   per-batch shards were written by subagents from a prose row spec, the
#   orchestrator concatenated them by prose, and the no-dispatch fallback appended to
#   the concatenated file row by row.
LR=$SANDBOX/lr-append

RUN=$LR SHARD=batch1 FILE=pkg/foo.go VERDICT=ours REASON='user customization wins' REGION=1 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: an append exits 0"; else fail "log-resolution: an append exits 0 (rc=$rc)"; fi
expect "log-resolution: SHARD=batch1 writes \$RUN/resolutions.batch1.tsv" test -f "$LR/resolutions.batch1.tsv"
refute "log-resolution: SHARD set does NOT write the concatenated file" test -e "$LR/resolutions.tsv"
if [[ "$(wc -l < "$LR/resolutions.batch1.tsv" | tr -d ' ')" = 1 ]]; then pass "log-resolution: the shard holds exactly one line (no header)"; else fail "log-resolution: the shard holds exactly one line (no header)"; fi
if [[ "$(awk -F'\t' 'NR==1{print NF}' "$LR/resolutions.batch1.tsv")" = 4 ]]; then pass "log-resolution: the row has four tab-separated columns"; else fail "log-resolution: the row has four tab-separated columns"; fi
if [[ "$(awk -F'\t' 'NR==1{print $1"|"$2"|"$3"|"$4}' "$LR/resolutions.batch1.tsv")" = 'pkg/foo.go|ours|user customization wins|1' ]]; then
  pass "log-resolution: file, verdict, reason and region land in columns 1, 2, 3 and 4"
else
  fail "log-resolution: file, verdict, reason and region land in columns 1, 2, 3 and 4"
fi

# A second append to the same shard adds a row, never a header.
RUN=$LR SHARD=batch1 FILE=pkg/bar.go VERDICT=theirs REASON='template change adopted' REGION=1 bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LR/resolutions.batch1.tsv" | tr -d ' ')" = 2 ]]; then pass "log-resolution: a second append adds one row"; else fail "log-resolution: a second append adds one row"; fi

# SHARD unset is the role-switch fallback: its OWN reserved shard. It is NOT the
# aggregate — collect rebuilds that file, so no append path may target it (C6).
LRF=$SANDBOX/lr-fallback
RUN=$LRF FILE=pkg/foo.go VERDICT=merged REASON='hand-woven from both sides' REGION=1 bash "$LRS" >/dev/null 2>&1
expect "log-resolution: SHARD unset writes the reserved \$RUN/resolutions.role-switch.tsv" test -f "$LRF/resolutions.role-switch.tsv"
refute "log-resolution: SHARD unset never writes \$RUN/resolutions.tsv (collect's rebuild target)" test -e "$LRF/resolutions.tsv"

fi

if t "log-resolution.sh append — the verdict vocabulary is closed"; then
# This block PINS the interface:
#   VERDICT is validated against the vocabulary in agents/conflict-resolver.md.
#   An unrecognised verdict is refused and writes NOTHING — it is exactly what makes
#   a removal-verdict filter (followup-completeness.sh's kept-delete derivation)
#   silently under-match, and a typo'd verdict is invisible to every consumer.
LR=$SANDBOX/lr-vocab

# REGION=1 is supplied for all eight: the conflict-region verdicts require the
# ordinal, and the reasoning-bucket verdicts force it to '-' regardless of what
# came in — so one env shape drives the whole vocabulary.
for v in ours theirs merged user ported kept-delete kept-customization renamed-merged; do
  RUN=$LR SHARD=v FILE="pkg/$v.go" VERDICT="$v" REASON='because' REGION=1 bash "$LRS" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 0 ]] && [[ "$(awk -F'\t' -v f="pkg/$v.go" '$1==f{print $2}' "$LR/resolutions.v.tsv")" = "$v" ]]; then
    pass "log-resolution: VERDICT=$v is accepted and lands in column 2"
  else
    fail "log-resolution: VERDICT=$v is accepted and lands in column 2 (rc=$rc)"
  fi
done

LRERR=$SANDBOX/lr-vocab.err
RUN=$LR SHARD=v FILE=pkg/x.go VERDICT=kept_delete REASON='typo' bash "$LRS" >/dev/null 2>"$LRERR"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: a verdict outside the vocabulary is refused non-zero"; else fail "log-resolution: a verdict outside the vocabulary is refused non-zero (rc=$rc)"; fi
refute "log-resolution: the refused verdict wrote no row" grep -qF 'pkg/x.go' "$LR/resolutions.v.tsv"
expect "log-resolution: the refusal names the accepted vocabulary" grep -qF 'kept-delete' "$LRERR"
RUN=$LR SHARD=v FILE=pkg/y.go REASON='no verdict' bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: a missing VERDICT is refused"; else fail "log-resolution: a missing VERDICT is refused"; fi
RUN=$LR SHARD=v VERDICT=ours REASON='no file' bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: a missing FILE is refused"; else fail "log-resolution: a missing FILE is refused"; fi
if [[ -f "$LRS" ]] && ! env -u RUN FILE=pkg/z.go VERDICT=ours REASON=x bash "$LRS" >/dev/null 2>&1; then
  pass "log-resolution: a missing RUN is refused"
else
  fail "log-resolution: a missing RUN is refused"
fi

fi

if t "log-resolution.sh append — a tab or newline in a field still costs one row"; then
# This block PINS the interface:
#   FILE and REASON are collapsed — the same collapse() contract the three ledger
#   writers already assert. REASON is the sharpest case in the whole skill: resolvers
#   quote recorded intent entries VERBATIM into it, so a newline there is routine, and
#   an uncollapsed one splits a resolution across two rows — the second of which has
#   one column and reads to every consumer as a file path with no verdict.
LR=$SANDBOX/lr-collapse

RUN=$LR SHARD=c FILE="$(printf 'pkg/we\tird.go')" VERDICT=ours \
  REASON="$(printf 'intent says:\nweb/ is deliberately absent')" REGION=1 bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LR/resolutions.c.tsv" | tr -d ' ')" = 1 ]]; then pass "log-resolution: a newline-bearing REASON still costs one row"; else fail "log-resolution: a newline-bearing REASON still costs one row"; fi
if [[ "$(awk -F'\t' 'NR==1{print NF}' "$LR/resolutions.c.tsv")" = 4 ]]; then pass "log-resolution: the collapsed row is still four columns"; else fail "log-resolution: the collapsed row is still four columns"; fi
if [[ "$(awk -F'\t' 'NR==1{print $1"|"$3}' "$LR/resolutions.c.tsv")" = 'pkg/we ird.go|intent says: web/ is deliberately absent' ]]; then
  pass "log-resolution: the tab in FILE and the newline in REASON both collapse to single spaces"
else
  fail "log-resolution: the tab in FILE and the newline in REASON both collapse (got '$(awk -F'\t' 'NR==1{print $1"|"$3}' "$LR/resolutions.c.tsv")')"
fi

fi

if t "log-resolution.sh collect — rebuilds the concatenated ledger, never appends onto it"; then
# This block PINS the interface:
#   ACTION=collect concatenates every $RUN/resolutions.<slug>.tsv into
#   $RUN/resolutions.tsv, replacing the prose concatenation Phase 5 used to do.
#   It REBUILDS: a `cat >>` on a retried batch doubles every row from the batches
#   that already succeeded, and a doubled row is indistinguishable from a real one
#   to all four consumers.
LR=$SANDBOX/lr-collect
RUN=$LR SHARD=b1 FILE=pkg/a.go VERDICT=ours REASON='r1' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LR SHARD=b1 FILE=pkg/b.go VERDICT=theirs REASON='r2' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LR SHARD=b2 FILE=pkg/c.go VERDICT=merged REASON='r3' REGION=1 bash "$LRS" >/dev/null 2>&1

RUN=$LR ACTION=collect bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: collect exits 0"; else fail "log-resolution: collect exits 0 (rc=$rc)"; fi
if [[ "$(wc -l < "$LR/resolutions.tsv" | tr -d ' ')" = 3 ]]; then pass "log-resolution: collect gathers every shard's rows (3)"; else fail "log-resolution: collect gathers every shard's rows (got $(wc -l < "$LR/resolutions.tsv"))"; fi
expect "log-resolution: collect keeps rows from the first shard" grep -qF 'pkg/a.go' "$LR/resolutions.tsv"
expect "log-resolution: collect keeps rows from the second shard" grep -qF 'pkg/c.go' "$LR/resolutions.tsv"
expect "log-resolution: collect leaves the shards in place (they are the durable record)" test -f "$LR/resolutions.b1.tsv"

# Re-running collect is byte-identical — the retried-batch hazard.
cp "$LR/resolutions.tsv" "$SANDBOX/lr-collect.snap"
RUN=$LR ACTION=collect bash "$LRS" >/dev/null 2>&1
expect "log-resolution: a second collect is byte-identical (rebuild, not append)" \
  cmp -s "$SANDBOX/lr-collect.snap" "$LR/resolutions.tsv"
if [[ "$(grep -cF 'pkg/a.go' "$LR/resolutions.tsv")" = 1 ]]; then pass "log-resolution: no row is doubled by a second collect"; else fail "log-resolution: no row is doubled by a second collect"; fi

# A late shard is picked up by re-collecting — the retry path.
RUN=$LR SHARD=b3 FILE=pkg/d.go VERDICT=ported REASON='moved to internal/' bash "$LRS" >/dev/null 2>&1
RUN=$LR ACTION=collect bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LR/resolutions.tsv" | tr -d ' ')" = 4 ]]; then pass "log-resolution: re-collecting picks up a shard written after the first collect"; else fail "log-resolution: re-collecting picks up a later shard"; fi

# Zero shards: a clean no-op when nothing was dispatched, a hard failure when
# something was. "no conflicts" and "the resolvers' work is unrecorded" must not be
# the same answer.
LRZ=$SANDBOX/lr-collect-zero
mkdir -p "$LRZ"
RUN=$LRZ ACTION=collect bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: collect over zero shards is a clean no-op when none were expected"; else fail "log-resolution: collect over zero shards is a clean no-op (rc=$rc)"; fi
refute "log-resolution: the no-op collect wrote no empty ledger" test -e "$LRZ/resolutions.tsv"
RUN=$LRZ ACTION=collect EXPECT=3 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: collect over zero shards FAILS when dispatches were expected"; else fail "log-resolution: collect over zero shards FAILS when dispatches were expected (rc=$rc)"; fi
refute "log-resolution: the failed collect still wrote no ledger" test -e "$LRZ/resolutions.tsv"

# The fallback's reserved shard collects like any other shard, exactly once — the
# aggregate is never both an input and an append target, so nothing doubles.
LRS1=$SANDBOX/lr-collect-fallback
RUN=$LRS1 FILE=pkg/a.go VERDICT=ours REASON='role-switch fallback' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRS1 ACTION=collect bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LRS1/resolutions.tsv" | tr -d ' ')" = 1 ]]; then
  pass "log-resolution: collect publishes the fallback's reserved shard as the aggregate (one row, not doubled)"
else
  fail "log-resolution: collect publishes the fallback's reserved shard as the aggregate (got $(wc -l < "$LRS1/resolutions.tsv"))"
fi
RUN=$LRS1 ACTION=collect bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LRS1/resolutions.tsv" | tr -d ' ')" = 1 ]]; then
  pass "log-resolution: re-collecting the fallback-only run still yields one row (the fold cannot double a shard row)"
else
  fail "log-resolution: re-collecting the fallback-only run still yields one row (got $(wc -l < "$LRS1/resolutions.tsv"))"
fi

fi

if t "log-resolution.sh — rows written here parse in all four consumers"; then
# This block PINS the interface — and it is the assertion that carries most of this
# script's value. One columnar format, four machine parsers; asserting them against
# the WRITER rather than against four hand-built fixtures is the only way a column
# shift is caught, which is the failure no per-script test could see while the
# writer was prose.
LR=$SANDBOX/lr-rt
LRC=$SANDBOX/lr-rt-comp
mkdir -p "$LRC" && ( cd "$LRC" && git init -q -b main && echo x > f.txt && git add -A && git commit -qm init )

# Every row goes in through the writer, including one whose reason quotes an intent
# entry with a newline in it — the real-world shape of the free-text column.
RUN=$LR SHARD=b1 FILE=pkg/a.go VERDICT=ours REASON='user customization wins' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LR SHARD=b1 FILE=pkg/b.go VERDICT=theirs REASON='template change adopted' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LR SHARD=b2 FILE=pkg/c.go VERDICT=merged REASON='hand-woven' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LR SHARD=b2 FILE=pkg/d.go VERDICT=user REASON='the user decided' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LR SHARD=b2 FILE=web/old.go VERDICT=kept-delete \
  REASON="$(printf 'intent says:\nweb/ is deliberately absent')" bash "$LRS" >/dev/null 2>&1
RUN=$LR ACTION=collect bash "$LRS" >/dev/null 2>&1

# Consumer 1: handoff-structural.sh's per-verdict tallies.
: > "$LR/conflicts.txt"
( cd "$LRC" && RUN=$LR PHASE_KEY=$PK_PLANNING bash "$SKILL_DIR/scripts/handoff-structural.sh" \
    > "$SANDBOX/lr-rt-handoff.txt" 2>/dev/null )
expect "log-resolution: handoff-structural.sh counts 5 resolutions" \
  grep -qx 'resolutions_total: 5' "$SANDBOX/lr-rt-handoff.txt"
expect "log-resolution: handoff-structural.sh counts the ours row" \
  grep -qx 'resolutions_ours: 1' "$SANDBOX/lr-rt-handoff.txt"
expect "log-resolution: handoff-structural.sh counts the theirs row" \
  grep -qx 'resolutions_theirs: 1' "$SANDBOX/lr-rt-handoff.txt"
expect "log-resolution: handoff-structural.sh counts the merged row" \
  grep -qx 'resolutions_merged: 1' "$SANDBOX/lr-rt-handoff.txt"
expect "log-resolution: handoff-structural.sh counts the user row" \
  grep -qx 'resolutions_user: 1' "$SANDBOX/lr-rt-handoff.txt"

# Consumer 2: spawn-summary.sh's resolution-row count.
seed_model_pins "$LR"
RUN=$LR PHASE=5 PHASE_KEY=$PK_STRUCTURAL ROLE=conflict-resolver TIER=strong MODEL=opus-x \
  ITEM=b1 OUTCOME=ok bash "$SKILL_DIR/scripts/log-spawn.sh" >/dev/null 2>&1
LRPLAN=$SANDBOX/lr-rt-PLAN.md
printf '### T01: a\n' > "$LRPLAN"
RUN=$LR PLAN=$LRPLAN bash "$SKILL_DIR/scripts/spawn-summary.sh" > "$SANDBOX/lr-rt-summary.txt" 2>/dev/null
expect "log-resolution: spawn-summary.sh reads 5 resolution rows (no header inflating the count)" \
  grep -q '5 resolution' "$SANDBOX/lr-rt-summary.txt"

fi

if t "log-resolution.sh append — an exact-duplicate append costs no second row (re-dispatch idempotency)"; then
# This block PINS the interface:
#   append DEDUPS on the exact three-column row, the same `grep -Fxq` idiom as
#   log-intent.sh / log-learning.sh. A conflict-resolver re-dispatched for the
#   same slug (a needs-input round trip, a retried batch that happens to land
#   on the same verdict) may re-log a region it already resolved identically;
#   the shard must not double that row, or every one of the four consumers
#   double-counts it.
LR=$SANDBOX/lr-dedup

RUN=$LR SHARD=d1 FILE=pkg/dup.go VERDICT=ours REASON='user customization wins' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LR SHARD=d1 FILE=pkg/dup.go VERDICT=ours REASON='user customization wins' REGION=1 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: a repeated identical append still exits 0"; else fail "log-resolution: a repeated identical append still exits 0 (rc=$rc)"; fi
if [[ "$(wc -l < "$LR/resolutions.d1.tsv" | tr -d ' ')" = 1 ]]; then pass "log-resolution: the exact-duplicate append costs no second row"; else fail "log-resolution: the exact-duplicate append costs no second row (got $(wc -l < "$LR/resolutions.d1.tsv"))"; fi

# A different REASON for the same file/verdict is NOT a duplicate — dedup is on
# the exact row, never on FILE alone.
RUN=$LR SHARD=d1 FILE=pkg/dup.go VERDICT=ours REASON='a different reason' REGION=1 bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LR/resolutions.d1.tsv" | tr -d ' ')" = 2 ]]; then pass "log-resolution: a same-file different-reason append is a distinct row, not a dup"; else fail "log-resolution: a same-file different-reason append is a distinct row, not a dup (got $(wc -l < "$LR/resolutions.d1.tsv"))"; fi

# The role-switch fallback's reserved shard (SHARD unset) dedups the same way.
LRF=$SANDBOX/lr-dedup-fallback
RUN=$LRF FILE=pkg/foo.go VERDICT=merged REASON='hand-woven' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRF FILE=pkg/foo.go VERDICT=merged REASON='hand-woven' REGION=1 bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LRF/resolutions.role-switch.tsv" | tr -d ' ')" = 1 ]]; then pass "log-resolution: the fallback's reserved shard dedups the same way"; else fail "log-resolution: the fallback's reserved shard dedups the same way (got $(wc -l < "$LRF/resolutions.role-switch.tsv"))"; fi

fi

if t "log-resolution.sh reset — clears a shard so a re-dispatch supersedes rather than doubles it"; then
# This block PINS the interface:
#   ACTION=reset SHARD=<slug> removes $RUN/resolutions.<slug>.tsv if present.
#   Exact-duplicate dedup (above) only catches a re-append that lands on the
#   SAME verdict; a genuine re-dispatch (the resolver's whole batch redone —
#   a wrong-model fail per log-spawn.sh, or a fresh-context retry) may reach a
#   DIFFERENT verdict for the same file, which no line-level dedup can
#   reconcile — the shard would hold two rows for one file, and every
#   consumer would see both. reset clears the prior shard so the re-dispatch
#   supersedes it outright before writing again. SHARD unset targets the
#   fallback's resolutions.tsv directly instead (its own block, below) — there
#   is no "reset everything ambiguously" footgun either way, each SHARD value
#   maps to exactly one target file.
LR=$SANDBOX/lr-reset

RUN=$LR SHARD=r1 FILE=pkg/x.go VERDICT=ours REASON='first pass' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LR SHARD=r1 FILE=pkg/y.go VERDICT=theirs REASON='first pass, unrelated file' REGION=1 bash "$LRS" >/dev/null 2>&1

RUN=$LR ACTION=reset SHARD=r1 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: reset exits 0"; else fail "log-resolution: reset exits 0 (rc=$rc)"; fi
refute "log-resolution: reset removes the shard file" test -e "$LR/resolutions.r1.tsv"

# The re-dispatched resolver reaches a DIFFERENT verdict for the same file this
# time — a genuine supersede, not a duplicate.
RUN=$LR SHARD=r1 FILE=pkg/x.go VERDICT=theirs REASON='re-dispatch: template change actually applies' REGION=1 bash "$LRS" >/dev/null 2>&1

RUN=$LR ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1
if [[ "$(grep -cF 'pkg/x.go' "$LR/resolutions.tsv")" = 1 ]]; then pass "log-resolution: collect after reset+re-append carries exactly one row for the re-dispatched file"; else fail "log-resolution: collect after reset+re-append carries exactly one row (got $(grep -cF 'pkg/x.go' "$LR/resolutions.tsv"))"; fi
if [[ "$(awk -F'\t' '$1=="pkg/x.go"{print $2}' "$LR/resolutions.tsv")" = 'theirs' ]]; then
  pass "log-resolution: the collected row carries the NEW verdict, not the pre-reset one"
else
  fail "log-resolution: the collected row carries the NEW verdict (got '$(awk -F'\t' '$1=="pkg/x.go"{print $2}' "$LR/resolutions.tsv")')"
fi
refute "log-resolution: reset clears the WHOLE shard, so the unrelated pre-reset row is also gone" grep -qF 'pkg/y.go' "$LR/resolutions.tsv"

# reset on a shard that was never written (the batch's first-ever dispatch,
# or a shard already reset) is a clean no-op, not an error.
RUN=$LR ACTION=reset SHARD=never-written bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: reset on a nonexistent shard is a clean no-op"; else fail "log-resolution: reset on a nonexistent shard is a clean no-op (rc=$rc)"; fi

fi

if t "log-resolution.sh reset — SHARD unset targets the fallback's reserved shard AND the aggregate"; then
# This block PINS the interface:
#   reset with SHARD unset clears the role-switch fallback's own target — the
#   reserved $RUN/resolutions.role-switch.tsv shard append's SHARD-unset path
#   writes — AND $RUN/resolutions.tsv. Without the first, the role-switch
#   fallback (no dispatch, no re-dispatch) has no supersede mechanism at all:
#   append's dedup only catches an EXACT repeat, so a genuine re-decision (a
#   different verdict for a file already logged) could only ever ADD a second row
#   in that mode — precisely the state dedup/reset exist to prevent everywhere
#   else. Without the second, collect's transition fold would resurrect the
#   superseded verdict out of a pre-fix aggregate, restoring the two-verdicts-for-
#   one-file state by the back door. Dropping the aggregate loses nothing: the
#   next collect rebuilds it from the shards.
LRRF=$SANDBOX/lr-reset-fallback

RUN=$LRRF FILE=pkg/z.go VERDICT=ours REASON='role-switch: first decision' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRRF ACTION=collect bash "$LRS" >/dev/null 2>&1
expect "log-resolution: the fallback's reserved shard exists before reset" test -f "$LRRF/resolutions.role-switch.tsv"
expect "log-resolution: the collected aggregate exists before reset" test -f "$LRRF/resolutions.tsv"

RUN=$LRRF ACTION=reset bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: reset with SHARD unset exits 0"; else fail "log-resolution: reset with SHARD unset exits 0 (rc=$rc)"; fi
refute "log-resolution: reset with SHARD unset removes the reserved shard" test -e "$LRRF/resolutions.role-switch.tsv"
refute "log-resolution: reset with SHARD unset removes \$RUN/resolutions.tsv too (so the fold cannot resurrect the superseded row)" test -e "$LRRF/resolutions.tsv"

# A re-decision after the reset costs exactly one row, carrying the new verdict —
# and collecting it yields exactly that one row, with no trace of the first.
RUN=$LRRF FILE=pkg/z.go VERDICT=theirs REASON='role-switch: re-decided' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRRF ACTION=collect bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LRRF/resolutions.tsv" | tr -d ' ')" = 1 ]]; then pass "log-resolution: a fresh append after the fallback reset yields exactly one row"; else fail "log-resolution: a fresh append after the fallback reset yields exactly one row (got $(wc -l < "$LRRF/resolutions.tsv"))"; fi
if [[ "$(awk -F'\t' '$1=="pkg/z.go"{print $2}' "$LRRF/resolutions.tsv")" = 'theirs' ]]; then pass "log-resolution: that row carries the re-decided verdict"; else fail "log-resolution: that row carries the re-decided verdict (got '$(awk -F'\t' '$1=="pkg/z.go"{print $2}' "$LRRF/resolutions.tsv")')"; fi
refute "log-resolution: the superseded pre-reset verdict is gone from the collected ledger" grep -qF 'first decision' "$LRRF/resolutions.tsv"

# reset with SHARD unset on a fallback file that was never written is a clean
# no-op too.
LRRF2=$SANDBOX/lr-reset-fallback-empty
mkdir -p "$LRRF2"
RUN=$LRRF2 ACTION=reset bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: reset with SHARD unset on a never-written fallback file is a clean no-op"; else fail "log-resolution: reset with SHARD unset on a never-written fallback file is a clean no-op (rc=$rc)"; fi

fi

if t "log-resolution.sh collect — a run that mixed dispatched and in-conversation resolution loses no verdicts"; then
# This block PINS the interface — and it is the C6 regression:
#   collect REBUILDS $RUN/resolutions.tsv. Before the fix the role-switch
#   fallback appended its rows into that same aggregate, so the first collect on
#   any resume that mixed the two modes (a run that started with no runtime
#   dispatch, resumed with it — or a fallback pass followed by one dispatched
#   batch) OVERWROTE every in-conversation verdict with the shard concatenation.
#   The verdicts were unrecoverable: the aggregate was the fallback's only copy.
#   Every resolution row now flows through the same shard model, so collect
#   treats both modes uniformly and no mode owns the rebuild target.
LRMIX=$SANDBOX/lr-mix

# Phase 1 of the run: no runtime dispatch, so the resolver runs in-conversation
# and logs without SHARD — exactly the invocation phases/5-structural.md's
# no-runtime-dispatch bullet and agents/conflict-resolver.md's role-switch mode
# instruct.
RUN=$LRMIX FILE=pkg/inconv.go VERDICT=merged REASON='role-switch: hand-woven from both sides' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRMIX FILE=web/gone.go VERDICT=kept-delete REASON='role-switch: intent says web/ is deliberately absent' bash "$LRS" >/dev/null 2>&1

# Phase 2 of the same run: dispatch becomes available, one batch is dispatched,
# and the orchestrator collects.
RUN=$LRMIX SHARD=batch1 FILE=pkg/dispatched.go VERDICT=theirs REASON='template change adopted' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRMIX ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: collect over a mixed-mode run exits 0"; else fail "log-resolution: collect over a mixed-mode run exits 0 (rc=$rc)"; fi

expect "log-resolution: collect keeps the dispatched shard's row" \
  grep -qF 'pkg/dispatched.go' "$LRMIX/resolutions.tsv"
expect "log-resolution: collect keeps the in-conversation merged row (C6: was destroyed by the rebuild)" \
  grep -qF 'pkg/inconv.go' "$LRMIX/resolutions.tsv"
expect "log-resolution: collect keeps the in-conversation kept-delete row (a lost one silently drops a stale-reference follow-up)" \
  grep -qF 'web/gone.go' "$LRMIX/resolutions.tsv"
if [[ "$(awk 'NF' "$LRMIX/resolutions.tsv" | wc -l | tr -d ' ')" = 3 ]]; then
  pass "log-resolution: the collected ledger holds all three rows, from both modes"
else
  fail "log-resolution: the collected ledger holds all three rows, from both modes (got $(awk 'NF' "$LRMIX/resolutions.tsv" | wc -l | tr -d ' '))"
fi

fi

if t "log-resolution.sh append — the reserved role-switch slug is the fallback's shard, explicit or implicit"; then
# This block PINS the interface:
#   `role-switch` is the RESERVED shard slug of the in-conversation fallback. The
#   docs (phases/5-structural.md's no-runtime-dispatch bullet,
#   agents/conflict-resolver.md's role-switch mode) instruct it explicitly, and
#   SHARD unset resolves to the same file so an older invocation is not a data-loss
#   trap. Same file, same dedup, same collect treatment — the whole point of C6's
#   fix is that the fallback has no privileged write path.
LRRS=$SANDBOX/lr-reserved

RUN=$LRRS SHARD=role-switch FILE=pkg/explicit.go VERDICT=ours REASON='role-switch: explicit slug' REGION=1 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: an explicit SHARD=role-switch append exits 0"; else fail "log-resolution: an explicit SHARD=role-switch append exits 0 (rc=$rc)"; fi
expect "log-resolution: SHARD=role-switch writes \$RUN/resolutions.role-switch.tsv" test -f "$LRRS/resolutions.role-switch.tsv"
refute "log-resolution: SHARD=role-switch never writes the aggregate" test -e "$LRRS/resolutions.tsv"

# Implicit (SHARD unset) lands in the SAME file — so a mode switch mid-run cannot
# split the fallback's verdicts across two files.
RUN=$LRRS FILE=pkg/implicit.go VERDICT=theirs REASON='role-switch: implicit slug' REGION=1 bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LRRS/resolutions.role-switch.tsv" | tr -d ' ')" = 2 ]]; then pass "log-resolution: SHARD unset appends to the same reserved shard"; else fail "log-resolution: SHARD unset appends to the same reserved shard (got $(wc -l < "$LRRS/resolutions.role-switch.tsv"))"; fi
# An exact repeat through the OTHER spelling is still a dedup, not a second row.
RUN=$LRRS SHARD=role-switch FILE=pkg/implicit.go VERDICT=theirs REASON='role-switch: implicit slug' REGION=1 bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LRRS/resolutions.role-switch.tsv" | tr -d ' ')" = 2 ]]; then pass "log-resolution: the explicit and implicit spellings dedup against each other (one file)"; else fail "log-resolution: the explicit and implicit spellings dedup against each other (got $(wc -l < "$LRRS/resolutions.role-switch.tsv"))"; fi

# And collect publishes them: the fallback mode now collects with EXPECT unset/0,
# which is how the aggregate its four consumers read comes to exist at all.
RUN=$LRRS ACTION=collect bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: collect over the reserved shard alone exits 0 (EXPECT unset)"; else fail "log-resolution: collect over the reserved shard alone exits 0 (rc=$rc)"; fi
expect "log-resolution: the explicitly-slugged row reaches the aggregate" grep -qF 'pkg/explicit.go' "$LRRS/resolutions.tsv"
expect "log-resolution: the implicitly-slugged row reaches the aggregate" grep -qF 'pkg/implicit.go' "$LRRS/resolutions.tsv"
if [[ "$(awk 'NF' "$LRRS/resolutions.tsv" | wc -l | tr -d ' ')" = 2 ]]; then pass "log-resolution: the aggregate holds exactly the two fallback rows"; else fail "log-resolution: the aggregate holds exactly the two fallback rows (got $(awk 'NF' "$LRRS/resolutions.tsv" | wc -l | tr -d ' '))"; fi

fi

if t "log-resolution.sh collect — idempotent even when it folded an aggregate row"; then
# This block PINS the interface:
#   collect is a rebuild, so running it twice must be byte-identical — the
#   retried-batch hazard. The transition fold reads $RUN/resolutions.tsv, which is
#   collect's OWN output, so idempotency is the property most at risk from it: a
#   fold that re-appended what it just wrote would double every row on each
#   collect, and the doubled rows are indistinguishable from real ones to all four
#   consumers. Dedup is on the exact row, and shard rows always win their own
#   place, so the second collect adds nothing.
LRID=$SANDBOX/lr-collect-idem

RUN=$LRID SHARD=b1 FILE=pkg/shard.go VERDICT=ours REASON='dispatched' REGION=1 bash "$LRS" >/dev/null 2>&1
# A previously-collected aggregate (four-column): one row that lives ONLY here, and
# one that a shard also carries at the SAME ordinal (so it dedups exactly, the way a
# row collected once before does).
mkdir -p "$LRID"
{ printf 'pkg/legacy.go\tmerged\tlegacy in-conversation row\t2\n'
  printf 'pkg/shard.go\tours\tdispatched\t1\n'; } > "$LRID/resolutions.tsv"

RUN=$LRID ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1
cp "$LRID/resolutions.tsv" "$SANDBOX/lr-collect-idem.snap1"
if [[ "$(awk 'NF' "$LRID/resolutions.tsv" | wc -l | tr -d ' ')" = 2 ]]; then pass "log-resolution: the fold adds the aggregate-only row once and the shared row not at all"; else fail "log-resolution: the fold adds the aggregate-only row once and the shared row not at all (got $(awk 'NF' "$LRID/resolutions.tsv" | wc -l | tr -d ' '))"; fi
if [[ "$(grep -cF 'pkg/shard.go' "$LRID/resolutions.tsv")" = 1 ]]; then pass "log-resolution: a row present in BOTH the shard and the aggregate lands exactly once"; else fail "log-resolution: a row present in BOTH the shard and the aggregate lands exactly once (got $(grep -cF 'pkg/shard.go' "$LRID/resolutions.tsv"))"; fi

RUN=$LRID ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1
expect "log-resolution: a second collect after a fold is byte-identical" \
  cmp -s "$SANDBOX/lr-collect-idem.snap1" "$LRID/resolutions.tsv"
RUN=$LRID ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1
expect "log-resolution: a third collect is still byte-identical (the fold never compounds)" \
  cmp -s "$SANDBOX/lr-collect-idem.snap1" "$LRID/resolutions.tsv"
if [[ "$(grep -cF 'pkg/legacy.go' "$LRID/resolutions.tsv")" = 1 ]]; then pass "log-resolution: the folded row is not doubled by re-collecting"; else fail "log-resolution: the folded row is not doubled by re-collecting (got $(grep -cF 'pkg/legacy.go' "$LRID/resolutions.tsv"))"; fi
expect "log-resolution: collect leaves no temp files behind in \$RUN" \
  bash -c "! ls '$LRID'/.resolutions.* >/dev/null 2>&1"

fi

if t "log-resolution.sh collect — folds a pre-existing aggregate instead of overwriting it (C6 transition)"; then
# This block PINS the interface:
#   the transition case for C6. A state dir written BEFORE the fallback got its own
#   shard holds in-conversation verdicts in $RUN/resolutions.tsv and nowhere else —
#   an in-flight migration, or a resumed run whose $RUN predates this script. The
#   first collect after the upgrade must carry those rows forward, not overwrite
#   them: they are the only copy, and the four consumers (the planner's review,
#   handoff-structural.sh's tallies, spawn-summary.sh's count,
#   followup-completeness.sh's kept-delete derivation) read the aggregate.
LRTR=$SANDBOX/lr-transition
mkdir -p "$LRTR"

# A previously-collected aggregate (four-column), written before this resume.
{ printf 'pkg/old-a.go\tmerged\thand-woven, logged in a prior collect\t1\n'
  printf 'web/old-b.go\tkept-delete\tintent says web/ is deliberately absent\t-\n'; } > "$LRTR/resolutions.tsv"
# The resumed run dispatches one batch and collects.
RUN=$LRTR SHARD=batch1 FILE=pkg/new.go VERDICT=theirs REASON='template change adopted' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRTR ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: collect over a pre-fix aggregate exits 0"; else fail "log-resolution: collect over a pre-fix aggregate exits 0 (rc=$rc)"; fi

expect "log-resolution: the pre-fix merged row survives collect" grep -qF 'pkg/old-a.go' "$LRTR/resolutions.tsv"
expect "log-resolution: the pre-fix kept-delete row survives collect" grep -qF 'web/old-b.go' "$LRTR/resolutions.tsv"
expect "log-resolution: the new shard's row is there too" grep -qF 'pkg/new.go' "$LRTR/resolutions.tsv"
if [[ "$(awk 'NF' "$LRTR/resolutions.tsv" | wc -l | tr -d ' ')" = 3 ]]; then pass "log-resolution: all three rows survive (2 folded + 1 shard)"; else fail "log-resolution: all three rows survive (got $(awk 'NF' "$LRTR/resolutions.tsv" | wc -l | tr -d ' '))"; fi
# Column integrity of a folded row: the fold copies bytes, it does not re-format.
if [[ "$(awk -F'\t' '$1=="web/old-b.go"{print NF"|"$2}' "$LRTR/resolutions.tsv")" = '4|kept-delete' ]]; then
  pass "log-resolution: a folded row keeps its four columns and its verdict"
else
  fail "log-resolution: a folded row keeps its four columns and its verdict (got '$(awk -F'\t' '$1=="web/old-b.go"{print NF"|"$2}' "$LRTR/resolutions.tsv")')"
fi
# Shard rows come first, folded leftovers after — a stable order, so a diff of two
# collects of the same state is empty.
if [[ "$(awk -F'\t' 'NF{print $1}' "$LRTR/resolutions.tsv" | head -1)" = 'pkg/new.go' ]]; then pass "log-resolution: shard rows lead, folded rows follow"; else fail "log-resolution: shard rows lead, folded rows follow (got '$(awk -F'\t' 'NF{print $1}' "$LRTR/resolutions.tsv" | head -1)')"; fi

# A pre-fix aggregate with NO shards at all is left exactly as it is: collect over
# zero shards is a no-op, so the fold cannot become a way to lose that file either.
LRTR2=$SANDBOX/lr-transition-noshards
mkdir -p "$LRTR2"
printf 'pkg/only.go\tours\tfallback-only run, never collected\n' > "$LRTR2/resolutions.tsv"
cp "$LRTR2/resolutions.tsv" "$SANDBOX/lr-transition-noshards.snap"
RUN=$LRTR2 ACTION=collect bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: collect with a pre-fix aggregate and zero shards exits 0"; else fail "log-resolution: collect with a pre-fix aggregate and zero shards exits 0 (rc=$rc)"; fi
expect "log-resolution: that aggregate is left byte-identical (zero shards is a no-op, not a truncation)" \
  cmp -s "$SANDBOX/lr-transition-noshards.snap" "$LRTR2/resolutions.tsv"

fi

if t "log-resolution.sh reset — a re-dispatch AFTER a collect supersedes; the aggregate cannot resurrect the old verdict"; then
# This block PINS the interface:
#   EVERY reset removes $RUN/resolutions.tsv, not just the SHARD-unset one. The
#   documented wrong-model-retry remedy (phases/5-structural.md's dispatch step) is
#   `reset SHARD=<slug>` then re-dispatch — and once a collect has already run, the
#   aggregate holds the failed attempt's rows. A reset that spared the aggregate let
#   the next collect's transition fold carry those rows forward as "rows no shard
#   carries" (the reset just deleted the shard that carried them), so the superseded
#   verdict came back and the file ended with TWO conflicting verdicts. Nothing is
#   lost by dropping the aggregate: it is rebuilt from the shards, and any row that
#   lives ONLY in the aggregate is materialized into the script-owned
#   resolutions.legacy.tsv shard first.
LRSUP=$SANDBOX/lr-supersede

RUN=$LRSUP SHARD=batchA FILE=a.go VERDICT=ours REASON='first pass: user customization wins' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRSUP ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1
expect "log-resolution: the first collect published the aggregate" test -f "$LRSUP/resolutions.tsv"

RUN=$LRSUP ACTION=reset SHARD=batchA bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: reset SHARD=<slug> after a collect exits 0"; else fail "log-resolution: reset SHARD=<slug> after a collect exits 0 (rc=$rc)"; fi
refute "log-resolution: reset SHARD=<slug> removes the shard" test -e "$LRSUP/resolutions.batchA.tsv"
refute "log-resolution: reset SHARD=<slug> removes the aggregate too (the fold cannot resurrect the superseded row)" \
  test -e "$LRSUP/resolutions.tsv"

# The re-dispatched batch reaches a DIFFERENT verdict for the same file.
RUN=$LRSUP SHARD=batchA FILE=a.go VERDICT=theirs REASON='re-dispatch: the template change actually applies' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRSUP ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: the collect after reset+re-append exits 0"; else fail "log-resolution: the collect after reset+re-append exits 0 (rc=$rc)"; fi
if [[ "$(grep -cF 'a.go' "$LRSUP/resolutions.tsv")" = 1 ]]; then pass "log-resolution: the aggregate holds exactly ONE row for the re-dispatched file"; else fail "log-resolution: the aggregate holds exactly ONE row for the re-dispatched file (got $(grep -cF 'a.go' "$LRSUP/resolutions.tsv"))"; fi
if [[ "$(awk -F'\t' '$1=="a.go"{print $2}' "$LRSUP/resolutions.tsv")" = 'theirs' ]]; then pass "log-resolution: that row carries the NEW verdict"; else fail "log-resolution: that row carries the NEW verdict (got '$(awk -F'\t' '$1=="a.go"{print $2}' "$LRSUP/resolutions.tsv")')"; fi
refute "log-resolution: the superseded first-pass row is gone from the aggregate" grep -qF 'first pass' "$LRSUP/resolutions.tsv"

fi

if t "log-resolution.sh collect — an empty shard cannot wipe an aggregate that is the only copy of its rows"; then
# This block PINS the interface:
#   the transition fold must survive shards that concatenate to ZERO bytes — a
#   dispatched batch that created its shard and logged nothing (every item came back
#   needs-input), which is a normal outcome. The `NR == FNR` seen-set idiom is
#   silently wrong on an empty first file: awk never reads a record from it, so
#   NR == FNR stays true across the SECOND file and every aggregate row is classified
#   as already-seen — the fold emitted nothing and collect wrote an EMPTY ledger over
#   a pre-fix aggregate that was the only copy of those verdicts, exit 0.
LREM=$SANDBOX/lr-empty-shards
mkdir -p "$LREM"
printf 'pkg/legacy-only.go\tmerged\tin-conversation row, no other copy\t1\n' > "$LREM/resolutions.tsv"
: > "$LREM/resolutions.b1.tsv"          # the batch was dispatched; it logged nothing

RUN=$LREM ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: collect over an empty shard exits 0"; else fail "log-resolution: collect over an empty shard exits 0 (rc=$rc)"; fi
expect "log-resolution: the aggregate-only row survives a zero-byte shard concatenation" \
  grep -qF 'pkg/legacy-only.go' "$LREM/resolutions.tsv"
expect "log-resolution: that row was materialized into the script-owned legacy shard" \
  grep -qF 'pkg/legacy-only.go' "$LREM/resolutions.legacy.tsv"
if [[ "$(awk 'NF' "$LREM/resolutions.tsv" | wc -l | tr -d ' ')" = 1 ]]; then pass "log-resolution: the rebuilt aggregate holds exactly that one row"; else fail "log-resolution: the rebuilt aggregate holds exactly that one row (got $(awk 'NF' "$LREM/resolutions.tsv" | wc -l | tr -d ' '))"; fi

fi

if t "log-resolution.sh collect — a folded row is MATERIALIZED into a shard, so the aggregate stays rebuildable"; then
# This block PINS the interface:
#   the fix that makes "every reset drops the aggregate" safe. A row that lives only
#   in a pre-fix $RUN/resolutions.tsv is appended ONCE to $RUN/resolutions.legacy.tsv
#   — a script-owned shard nobody else may write — and the aggregate is then rebuilt
#   purely from shards. After that first collect the aggregate is derived state: it
#   can be deleted at any point (by a reset, by a stray `rm`) and the next collect
#   reproduces it in full.
LRMAT=$SANDBOX/lr-materialize
mkdir -p "$LRMAT"
printf 'pkg/pre-fix.go\tours\tlogged in a prior collect\t1\n' > "$LRMAT/resolutions.tsv"
RUN=$LRMAT SHARD=b1 FILE=pkg/new.go VERDICT=theirs REASON='template change adopted' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRMAT ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1

expect "log-resolution: collect creates the legacy shard for the aggregate-only row" test -f "$LRMAT/resolutions.legacy.tsv"
if [[ "$(awk 'NF' "$LRMAT/resolutions.legacy.tsv" | wc -l | tr -d ' ')" = 1 ]]; then pass "log-resolution: the legacy shard holds only the aggregate-only row (a shard-carried row is not copied into it)"; else fail "log-resolution: the legacy shard holds only the aggregate-only row (got $(awk 'NF' "$LRMAT/resolutions.legacy.tsv" | wc -l | tr -d ' '))"; fi

# Now destroy the aggregate — a reset, or any other loss — and rebuild.
rm -f "$LRMAT/resolutions.tsv"
RUN=$LRMAT ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: re-collecting after the aggregate was deleted exits 0"; else fail "log-resolution: re-collecting after the aggregate was deleted exits 0 (rc=$rc)"; fi
expect "log-resolution: the materialized legacy row is back in the rebuilt aggregate" \
  grep -qF 'pkg/pre-fix.go' "$LRMAT/resolutions.tsv"
expect "log-resolution: the dispatched shard's row is there too" grep -qF 'pkg/new.go' "$LRMAT/resolutions.tsv"
if [[ "$(awk 'NF' "$LRMAT/resolutions.tsv" | wc -l | tr -d ' ')" = 2 ]]; then pass "log-resolution: the rebuild holds both rows and neither is doubled"; else fail "log-resolution: the rebuild holds both rows and neither is doubled (got $(awk 'NF' "$LRMAT/resolutions.tsv" | wc -l | tr -d ' '))"; fi
# The legacy shard does not grow on re-collect: its rows are shard rows now.
if [[ "$(awk 'NF' "$LRMAT/resolutions.legacy.tsv" | wc -l | tr -d ' ')" = 1 ]]; then pass "log-resolution: the legacy shard is not re-appended to by a later collect"; else fail "log-resolution: the legacy shard is not re-appended to by a later collect (got $(awk 'NF' "$LRMAT/resolutions.legacy.tsv" | wc -l | tr -d ' '))"; fi

fi

if t "log-resolution.sh reset — materializes an uncollected aggregate before dropping it (nothing is lost)"; then
# This block PINS the interface:
#   reset drops the aggregate, so reset must first make it reproducible. A pre-fix
#   aggregate holding rows no shard carries, reset BEFORE any collect ever ran, is
#   the case where a bare `rm` would destroy the only copy. Materialization runs
#   first, and it runs BEFORE the shard removal — reading the shard that is about to
#   go means the superseded rows count as shard-carried and are NOT preserved, which
#   is the whole point of the reset.
LRRM=$SANDBOX/lr-reset-materialize
mkdir -p "$LRRM"
printf 'pkg/pre-fix.go\tmerged\thand-woven in-conversation, only copy\t1\n' > "$LRRM/resolutions.tsv"
RUN=$LRRM SHARD=b1 FILE=pkg/x.go VERDICT=ours REASON='first pass' REGION=1 bash "$LRS" >/dev/null 2>&1

RUN=$LRRM ACTION=reset SHARD=b1 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: reset over an uncollected pre-fix aggregate exits 0"; else fail "log-resolution: reset over an uncollected pre-fix aggregate exits 0 (rc=$rc)"; fi
refute "log-resolution: reset dropped the aggregate" test -e "$LRRM/resolutions.tsv"
expect "log-resolution: reset materialized the aggregate-only row into the legacy shard first" \
  grep -qF 'pkg/pre-fix.go' "$LRRM/resolutions.legacy.tsv"

RUN=$LRRM SHARD=b1 FILE=pkg/x.go VERDICT=theirs REASON='re-dispatch: template change applies' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRRM ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1
expect "log-resolution: the pre-fix row survives the reset + re-collect" grep -qF 'pkg/pre-fix.go' "$LRRM/resolutions.tsv"
if [[ "$(grep -cF 'pkg/x.go' "$LRRM/resolutions.tsv")" = 1 ]]; then pass "log-resolution: the re-dispatched file still has exactly one row"; else fail "log-resolution: the re-dispatched file still has exactly one row (got $(grep -cF 'pkg/x.go' "$LRRM/resolutions.tsv"))"; fi
if [[ "$(awk -F'\t' '$1=="pkg/x.go"{print $2}' "$LRRM/resolutions.tsv")" = 'theirs' ]]; then pass "log-resolution: and it carries the re-dispatched verdict"; else fail "log-resolution: and it carries the re-dispatched verdict (got '$(awk -F'\t' '$1=="pkg/x.go"{print $2}' "$LRRM/resolutions.tsv")')"; fi
refute "log-resolution: reset did not preserve the superseded shard row as a legacy row" \
  grep -qF 'first pass' "$LRRM/resolutions.legacy.tsv"

fi

if t "log-resolution.sh — the 'legacy' slug is script-owned and refused from append and reset"; then
# This block PINS the interface:
#   `resolutions.legacy.tsv` is written by collect/reset alone — it is where an
#   aggregate row no shard carries is materialized, which is what makes the aggregate
#   derived state. A dispatched batch that happened to be slugged `legacy` would share
#   that file, and a `reset SHARD=legacy` would delete the one copy of every
#   pre-fix verdict. Both are refused before a path is built from the slug. The OTHER
#   reserved slug, `role-switch`, stays usable: the docs instruct it by name for the
#   in-conversation fallback (its own block, above).
LRLEG=$SANDBOX/lr-legacy-slug
mkdir -p "$LRLEG"

LRLEGERR=$SANDBOX/lr-legacy-slug.err
RUN=$LRLEG SHARD=legacy FILE=pkg/x.go VERDICT=ours REASON='r' bash "$LRS" >/dev/null 2>"$LRLEGERR"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: append with SHARD=legacy is refused"; else fail "log-resolution: append with SHARD=legacy is refused (rc=$rc)"; fi
refute "log-resolution: the refused append created no legacy shard" test -e "$LRLEG/resolutions.legacy.tsv"
expect "log-resolution: the refusal names the reserved slug" grep -qF 'legacy' "$LRLEGERR"

# A real legacy shard, created the only way it may be: by collect materializing a
# pre-fix aggregate row.
printf 'pkg/pre-fix.go\tours\tonly copy\t1\n' > "$LRLEG/resolutions.tsv"
RUN=$LRLEG SHARD=b1 FILE=pkg/new.go VERDICT=theirs REASON='r' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRLEG ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1
expect "log-resolution: collect is the writer that creates the legacy shard" test -f "$LRLEG/resolutions.legacy.tsv"

RUN=$LRLEG ACTION=reset SHARD=legacy bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: reset with SHARD=legacy is refused"; else fail "log-resolution: reset with SHARD=legacy is refused (rc=$rc)"; fi
expect "log-resolution: the refused reset left the legacy shard intact" \
  grep -qF 'pkg/pre-fix.go' "$LRLEG/resolutions.legacy.tsv"

fi

if t "log-resolution.sh — SHARD is validated against a filename-safe charset (append and reset refuse identically)"; then
# This block PINS the interface:
#   SHARD interpolates directly into resolutions.$SHARD.tsv in BOTH append and
#   reset — reset's `rm -f` is the skill's only destructive op on an
#   unvalidated interpolated variable. collapse() only folds whitespace, so a
#   '/' in SHARD used to fail LOUDLY on append (the nested path's parent dir
#   doesn't exist, so the `>>` redirection errors) but SILENTLY NO-OP on reset
#   (`rm -f` on a path whose parent dir is missing still exits 0) — and a
#   SHARD built from '..' segments can walk `rm -f` outside $RUN entirely.
#   Real dispatch slugs (phases/5-structural.md, agents/conflict-resolver.md)
#   are plain batch labels ("batch1", task ids) — never a path — so the
#   charset is pinned to what a legitimate slug can be: letters, digits, '.',
#   '_', '-'. Both actions refuse anything else, identically.
LR=$SANDBOX/lr-shard-charset
mkdir -p "$LR"
RUN=$LR SHARD=safe FILE=pkg/keep.go VERDICT=ours REASON='untouched control row' REGION=1 bash "$LRS" >/dev/null 2>&1
BEFORE=$(ls -A "$LR" | LC_ALL=C sort)

RUN=$LR SHARD='sub/dir' FILE=pkg/x.go VERDICT=ours REASON='r' bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: append with a '/'-bearing SHARD is refused"; else fail "log-resolution: append with a '/'-bearing SHARD is refused (rc=$rc)"; fi
if [[ "$(ls -A "$LR" | LC_ALL=C sort)" = "$BEFORE" ]]; then pass "log-resolution: the refused append left \$RUN untouched"; else fail "log-resolution: the refused append left \$RUN untouched"; fi

RUN=$LR ACTION=reset SHARD='sub/dir' bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: reset with a '/'-bearing SHARD is refused (not a silent no-op)"; else fail "log-resolution: reset with a '/'-bearing SHARD is refused (rc=$rc)"; fi
if [[ "$(ls -A "$LR" | LC_ALL=C sort)" = "$BEFORE" ]]; then pass "log-resolution: the refused reset left \$RUN untouched"; else fail "log-resolution: the refused reset left \$RUN untouched"; fi

RUN=$LR ACTION=reset SHARD='../evil' bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: reset with a '..'-bearing SHARD is refused (no escaping \$RUN)"; else fail "log-resolution: reset with a '..'-bearing SHARD is refused (rc=$rc)"; fi

RUN=$LR SHARD='../evil' FILE=pkg/x.go VERDICT=ours REASON='r' bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: append with a '..'-bearing SHARD is refused identically"; else fail "log-resolution: append with a '..'-bearing SHARD is refused identically (rc=$rc)"; fi

# The control shard's row survives every refusal untouched.
if [[ "$(awk -F'\t' '$1=="pkg/keep.go"{print $2}' "$LR/resolutions.safe.tsv")" = 'ours' ]]; then pass "log-resolution: the control shard's row is unchanged by any refusal"; else fail "log-resolution: the control shard's row is unchanged by any refusal"; fi

fi

if t "log-resolution.sh append — a conflict-region verdict REQUIRES a positive-integer REGION"; then
# This block PINS the interface:
#   the four conflict-region verdicts (ours|theirs|merged|user) name a real hunk, so
#   REGION is the 1-based ordinal of that region within the file — a positive integer
#   (^[1-9][0-9]*$). Absent, empty, non-numeric or zero is the resolver failing its
#   obligation, and is refused (exit 2) before any row is written. This is the
#   red-first guard for the new required field.
LRREG=$SANDBOX/lr-region-required
LRREGERR=$SANDBOX/lr-region-required.err

# Absent REGION.
RUN=$LRREG SHARD=b1 FILE=pkg/x.go VERDICT=ours REASON='r' bash "$LRS" >/dev/null 2>"$LRREGERR"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-resolution: an absent REGION on an 'ours' verdict is refused non-zero"; else fail "log-resolution: an absent REGION on an 'ours' verdict is refused non-zero (rc=$rc)"; fi
expect "log-resolution: the refusal names REGION" grep -qF 'REGION' "$LRREGERR"
refute "log-resolution: the refused append wrote no shard" test -e "$LRREG/resolutions.b1.tsv"

# Empty, non-numeric, zero, leading-zero, and the bucket sentinel '-' — all refused
# on a conflict-region verdict.
for bad in '' abc 0 007 -; do
  RUN=$LRREG SHARD=b1 FILE=pkg/x.go VERDICT=theirs REASON='r' REGION="$bad" bash "$LRS" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "log-resolution: REGION='$bad' on a conflict verdict is refused"; else fail "log-resolution: REGION='$bad' on a conflict verdict is refused (rc=$rc)"; fi
done
refute "log-resolution: none of the refused appends created the shard" test -e "$LRREG/resolutions.b1.tsv"

# A valid positive integer is accepted and lands in column 4.
RUN=$LRREG SHARD=b1 FILE=pkg/ok.go VERDICT=merged REASON='r' REGION=3 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: a positive-integer REGION is accepted"; else fail "log-resolution: a positive-integer REGION is accepted (rc=$rc)"; fi
if [[ "$(awk -F'\t' '$1=="pkg/ok.go"{print $4}' "$LRREG/resolutions.b1.tsv")" = 3 ]]; then pass "log-resolution: the ordinal lands in column 4"; else fail "log-resolution: the ordinal lands in column 4 (got '$(awk -F'\t' '$1=="pkg/ok.go"{print $4}' "$LRREG/resolutions.b1.tsv")')"; fi

fi

if t "log-resolution.sh append — a reasoning-bucket verdict carries region '-'"; then
# This block PINS the interface:
#   the four reasoning-bucket verdicts (ported|kept-delete|kept-customization|
#   renamed-merged) have no regions by construction, so REGION is FORCED to the
#   literal '-' — pass '-', leave it unset, or even pass a number: the written region
#   is '-' either way, keeping the row four fields wide so a positional reader never
#   sees a short row.
LRBUCK=$SANDBOX/lr-bucket-dash

RUN=$LRBUCK SHARD=b1 FILE=web/gone.go VERDICT=kept-delete REASON='intent: deliberately absent' REGION=- bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: a bucket verdict with REGION=- is accepted"; else fail "log-resolution: a bucket verdict with REGION=- is accepted (rc=$rc)"; fi
if [[ "$(awk -F'\t' 'NR==1{print NF"|"$4}' "$LRBUCK/resolutions.b1.tsv")" = '4|-' ]]; then pass "log-resolution: the bucket row is four columns with region '-'"; else fail "log-resolution: the bucket row is four columns with region '-' (got '$(awk -F'\t' 'NR==1{print NF"|"$4}' "$LRBUCK/resolutions.b1.tsv")')"; fi

# Unset REGION on a bucket verdict normalizes to '-' too.
RUN=$LRBUCK SHARD=b2 FILE=web/moved.go VERDICT=ported REASON='moved to internal/' bash "$LRS" >/dev/null 2>&1
if [[ "$(awk -F'\t' '$1=="web/moved.go"{print $4}' "$LRBUCK/resolutions.b2.tsv")" = '-' ]]; then pass "log-resolution: an unset REGION on a bucket verdict is forced to '-'"; else fail "log-resolution: an unset REGION on a bucket verdict is forced to '-' (got '$(awk -F'\t' '$1=="web/moved.go"{print $4}' "$LRBUCK/resolutions.b2.tsv")')"; fi

fi

if t "log-resolution.sh append — two verdicts differing ONLY in ordinal are distinct rows"; then
# This block PINS the interface — and it is the red-first test for the collapse
# defect the region column fixes:
#   two verdicts on different regions of one file, with identical file/verdict/reason,
#   used to be one exact-duplicate row and collapsed to a single entry — so every
#   ledger count under-reported by that amount. With the ordinal in column 4 they are
#   DISTINCT rows and both must survive the append dedup AND the collect rebuild.
LRORD=$SANDBOX/lr-ordinal

RUN=$LRORD SHARD=b1 FILE=pkg/multi.go VERDICT=ours REASON='user customization wins' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRORD SHARD=b1 FILE=pkg/multi.go VERDICT=ours REASON='user customization wins' REGION=2 bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LRORD/resolutions.b1.tsv" | tr -d ' ')" = 2 ]]; then pass "log-resolution: same file/verdict/reason at different ordinals are two rows, not one"; else fail "log-resolution: same file/verdict/reason at different ordinals are two rows (got $(wc -l < "$LRORD/resolutions.b1.tsv"))"; fi

# And both survive collect (the count the consumers read must not collapse them).
RUN=$LRORD ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>&1
if [[ "$(grep -cF 'pkg/multi.go' "$LRORD/resolutions.tsv")" = 2 ]]; then pass "log-resolution: both ordinals survive the collect rebuild"; else fail "log-resolution: both ordinals survive the collect rebuild (got $(grep -cF 'pkg/multi.go' "$LRORD/resolutions.tsv"))"; fi

# A re-append at the SAME ordinal is still an exact-duplicate no-op — the dedup is
# intact, it just now keys on four fields.
RUN=$LRORD SHARD=b1 FILE=pkg/multi.go VERDICT=ours REASON='user customization wins' REGION=1 bash "$LRS" >/dev/null 2>&1
if [[ "$(wc -l < "$LRORD/resolutions.b1.tsv" | tr -d ' ')" = 2 ]]; then pass "log-resolution: a same-ordinal re-append is still a dedup no-op"; else fail "log-resolution: a same-ordinal re-append is still a dedup no-op (got $(wc -l < "$LRORD/resolutions.b1.tsv"))"; fi

fi

if t "log-resolution.sh collect/reset — a four-column shard round-trips byte-stably with no warning"; then
# This block PINS the interface:
#   with post-column shards there are no three-field rows to normalize, so collect is
#   byte-identical across runs (the retried-batch hazard) and emits NO legacy warning.
#   reset then supersedes and a re-collect rebuilds a clean four-column ledger.
LRRT4=$SANDBOX/lr-roundtrip4
LRRT4ERR=$SANDBOX/lr-roundtrip4.err

RUN=$LRRT4 SHARD=b1 FILE=pkg/a.go VERDICT=ours REASON='r1' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRRT4 SHARD=b1 FILE=pkg/a.go VERDICT=merged REASON='r1' REGION=2 bash "$LRS" >/dev/null 2>&1
RUN=$LRRT4 SHARD=b2 FILE=web/g.go VERDICT=kept-delete REASON='gone' REGION=- bash "$LRS" >/dev/null 2>&1

RUN=$LRRT4 ACTION=collect EXPECT=2 bash "$LRS" >/dev/null 2>"$LRRT4ERR"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: collect over four-column shards exits 0"; else fail "log-resolution: collect over four-column shards exits 0 (rc=$rc)"; fi
refute "log-resolution: no legacy warning is emitted for post-column shards" grep -qF 'WARNING' "$LRRT4ERR"
if [[ "$(awk -F'\t' 'NF && NF!=4{n++} END{print n+0}' "$LRRT4/resolutions.tsv")" = 0 ]]; then pass "log-resolution: every rebuilt row is four columns"; else fail "log-resolution: every rebuilt row is four columns"; fi
cp "$LRRT4/resolutions.tsv" "$SANDBOX/lr-roundtrip4.snap"
RUN=$LRRT4 ACTION=collect EXPECT=2 bash "$LRS" >/dev/null 2>&1
expect "log-resolution: a second collect is byte-identical (four-column round-trip)" \
  cmp -s "$SANDBOX/lr-roundtrip4.snap" "$LRRT4/resolutions.tsv"

# reset supersedes a shard and a re-collect rebuilds a valid four-column ledger.
RUN=$LRRT4 ACTION=reset SHARD=b1 bash "$LRS" >/dev/null 2>&1
RUN=$LRRT4 SHARD=b1 FILE=pkg/a.go VERDICT=theirs REASON='re-decided' REGION=1 bash "$LRS" >/dev/null 2>&1
RUN=$LRRT4 ACTION=collect EXPECT=2 bash "$LRS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: collect after a reset+re-append exits 0"; else fail "log-resolution: collect after a reset+re-append exits 0 (rc=$rc)"; fi
if [[ "$(awk -F'\t' '$1=="pkg/a.go"{print $2":"$4}' "$LRRT4/resolutions.tsv" | sort | tr '\n' ',')" = 'theirs:1,' ]]; then pass "log-resolution: the superseded shard's rows are gone, the re-append's row remains"; else fail "log-resolution: the superseded shard's rows are gone, the re-append's row remains (got '$(awk -F'\t' '$1=="pkg/a.go"{print $2":"$4}' "$LRRT4/resolutions.tsv" | sort | tr '\n' ',')')"; fi

fi

if t "log-resolution.sh collect — a three-column shard is normalized to region=-, warned once, never refused"; then
# This block PINS the interface:
#   a shard from an older run (a resume that spans a skill upgrade, a stale $RUN)
#   carries three-field rows whose ordinal was never written. collect normalizes each
#   to four fields (region=-) on read, emits ONE stderr warning naming the count and
#   the shard, and does NOT refuse the run — most consumers never read the column, and
#   the only recovery would discard every resolver verdict (see the script header).
LRLEGSH=$SANDBOX/lr-legacy-shard
LRLEGSHERR=$SANDBOX/lr-legacy-shard.err
mkdir -p "$LRLEGSH"
{ printf 'pkg/old.go\tours\tuser customization wins\n'
  printf 'pkg/old2.go\ttheirs\ttemplate change adopted\n'; } > "$LRLEGSH/resolutions.b1.tsv"

RUN=$LRLEGSH ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>"$LRLEGSHERR"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: a run over a three-column shard is NOT refused (exit 0)"; else fail "log-resolution: a run over a three-column shard is NOT refused (rc=$rc)"; fi
if [[ "$(awk -F'\t' '$1=="pkg/old.go"{print NF"|"$4}' "$LRLEGSH/resolutions.tsv")" = '4|-' ]]; then pass "log-resolution: the legacy row is normalized to four columns with region '-'"; else fail "log-resolution: the legacy row is normalized to region '-' (got '$(awk -F'\t' '$1=="pkg/old.go"{print NF"|"$4}' "$LRLEGSH/resolutions.tsv")')"; fi
expect "log-resolution: the warning names the count (2)" grep -qE 'WARNING: 2 pre-column' "$LRLEGSHERR"
expect "log-resolution: the warning names the shard that carried them" grep -qF 'resolutions.b1.tsv' "$LRLEGSHERR"
if [[ "$(grep -c 'WARNING' "$LRLEGSHERR")" = 1 ]]; then pass "log-resolution: the warning is emitted ONCE, not per row"; else fail "log-resolution: the warning is emitted ONCE, not per row (got $(grep -c 'WARNING' "$LRLEGSHERR"))"; fi

fi

if t "log-resolution.sh collect — a three-column aggregate row is materialized into the legacy shard, normalized and warned"; then
# This block PINS the interface:
#   a pre-column aggregate (a state dir predating the region column) holds three-field
#   rows no shard carries. collect materializes each into the script-owned legacy
#   shard, normalized to region=-, warns once naming the aggregate, and never refuses.
LRLEGAGG=$SANDBOX/lr-legacy-agg
LRLEGAGGERR=$SANDBOX/lr-legacy-agg.err
mkdir -p "$LRLEGAGG"
printf 'pkg/pre.go\tmerged\thand-woven before the column existed\n' > "$LRLEGAGG/resolutions.tsv"
RUN=$LRLEGAGG SHARD=b1 FILE=pkg/new.go VERDICT=theirs REASON='adopted' REGION=1 bash "$LRS" >/dev/null 2>&1

RUN=$LRLEGAGG ACTION=collect EXPECT=1 bash "$LRS" >/dev/null 2>"$LRLEGAGGERR"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "log-resolution: a run over a three-column aggregate is NOT refused (exit 0)"; else fail "log-resolution: a run over a three-column aggregate is NOT refused (rc=$rc)"; fi
expect "log-resolution: the pre-column aggregate row is materialized into the legacy shard" \
  grep -qF 'pkg/pre.go' "$LRLEGAGG/resolutions.legacy.tsv"
if [[ "$(awk -F'\t' '$1=="pkg/pre.go"{print NF"|"$4}' "$LRLEGAGG/resolutions.legacy.tsv")" = '4|-' ]]; then pass "log-resolution: the materialized legacy row is four columns with region '-'"; else fail "log-resolution: the materialized legacy row is four columns with region '-' (got '$(awk -F'\t' '$1=="pkg/pre.go"{print NF"|"$4}' "$LRLEGAGG/resolutions.legacy.tsv")')"; fi
expect "log-resolution: the rebuilt aggregate carries the normalized legacy row" \
  grep -qF 'pkg/pre.go' "$LRLEGAGG/resolutions.tsv"
expect "log-resolution: the warning names the count (1)" grep -qE 'WARNING: 1 pre-column' "$LRLEGAGGERR"
expect "log-resolution: the warning names the aggregate that carried it" \
  grep -qF "$LRLEGAGG/resolutions.tsv)" "$LRLEGAGGERR"
if [[ "$(grep -c 'WARNING' "$LRLEGAGGERR")" = 1 ]]; then pass "log-resolution: warned exactly once"; else fail "log-resolution: warned exactly once (got $(grep -c 'WARNING' "$LRLEGAGGERR"))"; fi

fi

if t "log-resolution.sh — appended region is invisible to all three consumers (3-column vs 4-column, identical output)"; then
# This block PINS the interface — and it is the assertion that proves "appended is
# invisible" rather than assuming it. handoff-structural.sh, followup-completeness.sh
# and spawn-summary.sh all parse $1/$2 only, so a three-column ledger and a
# four-column ledger carrying the SAME verdicts must produce byte-identical output.
# The same $RUN dir is reused across the two runs so embedded paths cannot differ —
# only the ledger's column count changes between them.
CCRUN=$SANDBOX/cc-run
CCREPO=$SANDBOX/cc-repo
CCPLAN=$SANDBOX/cc-PLAN.md
mkdir -p "$CCRUN"
mkdir -p "$CCREPO" && ( cd "$CCREPO" && git init -q -b main && echo x > f.txt && git add -A && git commit -qm init )
: > "$CCRUN/clean-merged.txt"
printf '# Plan\n' > "$CCPLAN"

cc_write3() {
  { printf 'pkg/a.go\tours\tuser customization wins\n'
    printf 'pkg/b.go\ttheirs\ttemplate change adopted\n'
    printf 'pkg/c.go\tmerged\thand-woven\n'
    printf 'pkg/d.go\tuser\tthe user decided\n'
    printf 'web/e.go\tkept-delete\tintent says web/ is absent\n'; } > "$CCRUN/resolutions.tsv"
}
cc_write4() {
  { printf 'pkg/a.go\tours\tuser customization wins\t1\n'
    printf 'pkg/b.go\ttheirs\ttemplate change adopted\t2\n'
    printf 'pkg/c.go\tmerged\thand-woven\t1\n'
    printf 'pkg/d.go\tuser\tthe user decided\t3\n'
    printf 'web/e.go\tkept-delete\tintent says web/ is absent\t-\n'; } > "$CCRUN/resolutions.tsv"
}

# handoff-structural.sh — stdout.
cc_write3; RUN=$CCRUN PHASE_KEY=$PK_PLANNING bash "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/cc-h3" 2>&1
cc_write4; RUN=$CCRUN PHASE_KEY=$PK_PLANNING bash "$SKILL_DIR/scripts/handoff-structural.sh" > "$SANDBOX/cc-h4" 2>&1
expect "log-resolution: handoff-structural.sh output is identical across 3- and 4-column ledgers" \
  cmp -s "$SANDBOX/cc-h3" "$SANDBOX/cc-h4"

# spawn-summary.sh — stdout.
cc_write3; RUN=$CCRUN PLAN=$CCPLAN bash "$SKILL_DIR/scripts/spawn-summary.sh" > "$SANDBOX/cc-s3" 2>&1
cc_write4; RUN=$CCRUN PLAN=$CCPLAN bash "$SKILL_DIR/scripts/spawn-summary.sh" > "$SANDBOX/cc-s4" 2>&1
expect "log-resolution: spawn-summary.sh output is identical across 3- and 4-column ledgers" \
  cmp -s "$SANDBOX/cc-s3" "$SANDBOX/cc-s4"

# followup-completeness.sh — runs in the component repo; its output is on stderr.
cc_write3; ( cd "$CCREPO" && RUN=$CCRUN PLAN=$CCPLAN bash "$SKILL_DIR/scripts/followup-completeness.sh" > "$SANDBOX/cc-f3" 2>&1 )
cc_write4; ( cd "$CCREPO" && RUN=$CCRUN PLAN=$CCPLAN bash "$SKILL_DIR/scripts/followup-completeness.sh" > "$SANDBOX/cc-f4" 2>&1 )
expect "log-resolution: followup-completeness.sh output is identical across 3- and 4-column ledgers" \
  cmp -s "$SANDBOX/cc-f3" "$SANDBOX/cc-f4"

fi

finish_suite
