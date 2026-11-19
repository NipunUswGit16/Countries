#!/usr/bin/env bash
# spawn-summary.test.sh — tests for scripts/spawn-summary.sh
# TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

if t "spawn-summary.sh — per-tier tally + executor cross-check"; then
# This block PINS the interface:
#   env in : RUN (required); reads $RUN/spawns.tsv and $RUN/resolutions.tsv (row count =
#            resolutions logged, reported as a plain fact). PLAN (default
#            .kairos/migration/PLAN.md; count of '### T<n>:' task headings = executor expected M).
#   stdout : a per-tier REQUESTED tally that lists strong, coder AND executor even at 0
#            spawns; an escalation count; a retry count (rows whose outcome is 'retried'),
#            printed at 0 like the tier tally; TWO plain conflict-resolver facts (dispatch
#            count and resolution-row count — different units, never compared); and ONE
#            'logged N of ~M expected' line, for the executor, counting first attempts only
#            (the FIRST 'ok'-or-'fail' executor row per ITEM — a green-retried task logs
#            [fail, retried, ok] and a needs-input task [needs-input, ok], so one row per
#            ITEM counts each task once) against the PLAN task
#            headings. The word 'requested' appears, labelling the counts as requests, not
#            actual runs. Pinned, greppable output lines:
#              tier strong: <n> / tier coder: <n> / tier executor: <n>
#              escalations: <n>
#              retries: <n>
#              conflict-resolver: <n> dispatches, <n> resolutions logged
#              executor: logged <n> of ~<m> expected
SSS="$SKILL_DIR/scripts/spawn-summary.sh"
SS=$SANDBOX/ss-happy
mkdir -p "$SS"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tfileA\tok\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT02\tok\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT03\tok\t\n'
  printf '7\tverifier\tstrong\topus-x\tT01\tescalated\t\n'
} > "$SS/spawns.tsv"
printf 'fileA\tmerged\n' > "$SS/resolutions.tsv"    # 1 dispatch produced 1 resolution row
SSPLAN=$SANDBOX/ss-happy-PLAN.md
cat > "$SSPLAN" <<'MD'
# Plan
### T01: first
### T02: second
### T03: third
MD
SSOUT=$SANDBOX/ss-happy.out
RUN=$SS PLAN=$SSPLAN bash "$SSS" > "$SSOUT" 2>/dev/null; rc=$?
expect "spawn-summary: exits 0 on well-formed input" test "$rc" -eq 0
expect "spawn-summary: tier tally shows strong = 2 (conflict-resolver + verifier)" grep -q 'tier strong: 2' "$SSOUT"
expect "spawn-summary: tier tally INCLUDES the zero-spawn coder tier (coder = 0)" grep -q 'tier coder: 0' "$SSOUT"
expect "spawn-summary: tier tally shows executor = 3" grep -q 'tier executor: 3' "$SSOUT"
expect "spawn-summary: reports the escalation count (1)" grep -q 'escalations: 1' "$SSOUT"
expect "spawn-summary: reports the retry count even at zero (no retried rows => retries: 0)" grep -q 'retries: 0' "$SSOUT"
expect "spawn-summary: reports conflict-resolver dispatches and resolution rows as two plain facts" \
  grep -q 'conflict-resolver: 1 dispatches, 1 resolutions logged' "$SSOUT"
expect "spawn-summary: cross-checks executors vs the PLAN.md task count" grep -q 'executor: logged 3 of ~3 expected' "$SSOUT"
expect "spawn-summary: labels the counts as 'requested' (not actual runs)" grep -qi 'requested' "$SSOUT"

# Dispatches and resolution rows are DIFFERENT UNITS — Phase 5 batches ~10 items per
# dispatch and each dispatch logs one row per resolved region. Three dispatches against
# thirty resolution rows is a normal run, so the line must carry no 'expected' term for
# a reader (or a grep) to mistake for a discrepancy.
SSB=$SANDBOX/ss-batched
mkdir -p "$SSB"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tbatch1\tok\t\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tbatch2\tok\t\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tbatch3\tok\t\n'
} > "$SSB/spawns.tsv"
for i in $(seq 1 30); do printf 'region%s\tmerged\n' "$i"; done > "$SSB/resolutions.tsv"
SSOUTB=$SANDBOX/ss-batched.out
RUN=$SSB PLAN=$SSPLAN bash "$SSS" > "$SSOUTB" 2>/dev/null
expect "spawn-summary: 3 batched dispatches against 30 resolution rows print both numbers" \
  grep -q 'conflict-resolver: 3 dispatches, 30 resolutions logged' "$SSOUTB"
refute "spawn-summary: the conflict-resolver line carries NO 'expected' term (units cannot be compared)" \
  bash -c "grep '^conflict-resolver:' '$SSOUTB' | grep -q 'expected'"

# A deliberately UNDER-logged executor tally (fewer first attempts than PLAN tasks) must
# SHOW N<M, never silently pass: same spawns.tsv (3 first-attempt executor rows) against a
# 5-task plan. Two tasks were never dispatched — that skip is the whole reason the
# comparison is kept, and it only means "skipped" because retries/escalations are excluded.
SSPLAN5=$SANDBOX/ss-underlog-PLAN.md
cat > "$SSPLAN5" <<'MD'
### T01: a
### T02: b
### T03: c
### T04: d
### T05: e
MD
SSOUTU=$SANDBOX/ss-underlog.out
RUN=$SS PLAN=$SSPLAN5 bash "$SSS" > "$SSOUTU" 2>/dev/null
expect "spawn-summary: an under-logged executor tally is flagged (logged 3 of ~5, N<M visible)" \
  grep -q 'executor: logged 3 of ~5 expected' "$SSOUTU"

# Retried rows are counted separately from escalated ones, and are STILL spawns: each one
# counts toward its tier. They do NOT count toward the executor comparison — that counts
# FIRST attempts only, so N<M keeps its one specific meaning (tasks were skipped) and the
# re-spawns stay visible in the retries:/escalations: lines instead. T02 and T03 each failed
# once and were re-spawned (outcome 'retried'); T03's retry then escalated. So 3 planned
# tasks yield 6 executor rows, of which 3 are first attempts: 'logged 3 of ~3'.
SSR=$SANDBOX/ss-retry
mkdir -p "$SSR"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tfileA\tok\t\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tfileB\tok\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT02\tfail\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT02\tretried\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT03\tfail\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT03\tretried\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT03\tescalated\t\n'
  printf '7\tverifier\tstrong\topus-x\tT01\tok\t\n'
} > "$SSR/spawns.tsv"
{ printf 'fileA\tmerged\n'; printf 'fileB\tmerged\n'; } > "$SSR/resolutions.tsv"   # 2 rows
SSRPLAN=$SANDBOX/ss-retry-PLAN.md
cat > "$SSRPLAN" <<'MD'
### T01: a
### T02: b
### T03: c
MD
SSOUTR=$SANDBOX/ss-retry.out
RUN=$SSR PLAN=$SSRPLAN bash "$SSS" > "$SSOUTR" 2>/dev/null
expect "spawn-summary: reports the retry count (2 retried rows)" grep -q 'retries: 2' "$SSOUTR"
expect "spawn-summary: counts escalations independently of retries (1 escalated alongside 2 retried)" \
  grep -q 'escalations: 1' "$SSOUTR"
expect "spawn-summary: retried rows still count toward their tier (executor = 6)" grep -q 'tier executor: 6' "$SSOUTR"
expect "spawn-summary: retried rows do not disturb the strong tier (2 conflict-resolvers + 1 verifier)" \
  grep -q 'tier strong: 3' "$SSOUTR"
expect "spawn-summary: the zero-spawn coder tier survives retried rows (coder = 0)" grep -q 'tier coder: 0' "$SSOUTR"
expect "spawn-summary: retried rows do not disturb the conflict-resolver facts (2 dispatches, 2 rows)" \
  grep -q 'conflict-resolver: 2 dispatches, 2 resolutions logged' "$SSOUTR"
expect "spawn-summary: retried and escalated rows are EXCLUDED from the executor comparison (3 of ~3)" \
  grep -q 'executor: logged 3 of ~3 expected' "$SSOUTR"

# An ABSENT spawns.tsv takes the script's fallback code path, which prints the zero-tally from a
# separate awk program. Every line the Phase 8 entry folds in must be there too — a summary that
# silently loses a row on the empty-ledger path is the second-code-path miss this pins shut.
SSE=$SANDBOX/ss-empty-ledger
mkdir -p "$SSE"                                   # no spawns.tsv, no resolutions.tsv
SSOUTE=$SANDBOX/ss-empty-ledger.out
RUN=$SSE PLAN=$SSRPLAN bash "$SSS" > "$SSOUTE" 2>/dev/null; rc=$?
expect "spawn-summary: an absent spawns.tsv still exits 0" test "$rc" -eq 0
expect "spawn-summary: the empty-ledger fallback prints retries: 0" grep -q 'retries: 0' "$SSOUTE"
expect "spawn-summary: the empty-ledger fallback prints escalations: 0" grep -q 'escalations: 0' "$SSOUTE"
expect "spawn-summary: the empty-ledger fallback still lists every tier at zero" \
  bash -c "grep -q 'tier strong: 0' '$SSOUTE' && grep -q 'tier coder: 0' '$SSOUTE' && grep -q 'tier executor: 0' '$SSOUTE'"
expect "spawn-summary: the empty-ledger fallback still cross-checks executors against the PLAN" \
  grep -q 'executor: logged 0 of ~3 expected' "$SSOUTE"
expect "spawn-summary: the empty-ledger fallback prints both conflict-resolver facts at zero" \
  grep -q 'conflict-resolver: 0 dispatches, 0 resolutions logged' "$SSOUTE"
refute "spawn-summary: the empty-ledger fallback's conflict-resolver line carries no 'expected' term either" \
  bash -c "grep '^conflict-resolver:' '$SSOUTE' | grep -q 'expected'"

# PLAN defaults to .kairos/migration/PLAN.md (relative to cwd) when PLAN is unset.
SSD=$SANDBOX/ss-defplan
mkdir -p "$SSD/run" "$SSD/.kairos/migration"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\t\n'
} > "$SSD/run/spawns.tsv"
printf 'x\tmerged\n' > "$SSD/run/resolutions.tsv"
printf '### T01: only\n' > "$SSD/.kairos/migration/PLAN.md"
SSOUTD=$SANDBOX/ss-defplan.out
( cd "$SSD" && RUN="$SSD/run" bash "$SSS" ) > "$SSOUTD" 2>/dev/null
expect "spawn-summary: PLAN defaults to .kairos/migration/PLAN.md when unset" \
  grep -q 'executor: logged 1 of ~1 expected' "$SSOUTD"

# A missing RUN exits non-zero (guarded on the script existing, so it is RED now).
if [[ -f "$SSS" ]] && ! ( cd "$SANDBOX" && env -u RUN bash "$SSS" ) >/dev/null 2>&1; then pass "spawn-summary: a missing RUN exits non-zero"; else fail "spawn-summary: a missing RUN exits non-zero"; fi
fi

if t "spawn-summary.sh — resolution rows are counted from the shards too, never reported as a false zero"; then
# This block PINS the interface:
#   the resolution-row fact is counted over $RUN/resolutions.tsv UNION every
#   $RUN/resolutions.<slug>.tsv shard, de-duplicated on the exact row.
#   $RUN/resolutions.tsv is written by log-resolution.sh's `collect` alone, so a run
#   whose session died or compacted between the last resolution and the collect has
#   its whole ledger in shards and no aggregate at all — and this line reported
#   "0 resolutions logged" into the Phase 8 summary, silently, because the count was
#   `[ -f resolutions.tsv ]`-guarded with a zero default. The in-conversation
#   role-switch fallback is the sharpest case: it never dispatches, so the dispatch
#   count is a legitimate 0 and the row count was the only signal that any resolution
#   happened at all. De-dup matters because after a collect every shard row is ALSO
#   an aggregate row; the union must not double them.
SSS="$SKILL_DIR/scripts/spawn-summary.sh"
SSPLAN1=$SANDBOX/ss-shards-PLAN.md
printf '### T01: only\n' > "$SSPLAN1"

# Uncollected: two role-switch fallback rows, no aggregate, no spawns.tsv.
SSU=$SANDBOX/ss-uncollected
mkdir -p "$SSU"
{ printf 'pkg/a.go\tmerged\thand-woven from both sides\n'
  printf 'web/gone.go\tkept-delete\tintent says web/ is deliberately absent\n'; } \
  > "$SSU/resolutions.role-switch.tsv"
SSOUTUN=$SANDBOX/ss-uncollected.out
RUN=$SSU PLAN=$SSPLAN1 bash "$SSS" > "$SSOUTUN" 2>/dev/null; rc=$?
expect "spawn-summary: an uncollected shard ledger still exits 0" test "$rc" -eq 0
expect "spawn-summary: an uncollected role-switch shard is counted (0 dispatches, 2 resolutions logged)" \
  grep -q 'conflict-resolver: 0 dispatches, 2 resolutions logged' "$SSOUTUN"
refute "spawn-summary: it is NOT reported as zero resolutions" \
  grep -q 'conflict-resolver: 0 dispatches, 0 resolutions logged' "$SSOUTUN"

# Collected: the same rows now exist in BOTH the aggregate and the shard. The union
# de-dups on the exact row, so the count is 2, not 4.
cp "$SSU/resolutions.role-switch.tsv" "$SSU/resolutions.tsv"
SSOUTCO=$SANDBOX/ss-collected.out
RUN=$SSU PLAN=$SSPLAN1 bash "$SSS" > "$SSOUTCO" 2>/dev/null
expect "spawn-summary: after a collect the aggregate/shard union still counts 2 (byte-identical rows de-duped)" \
  grep -q 'conflict-resolver: 0 dispatches, 2 resolutions logged' "$SSOUTCO"

# Rows in shards that the aggregate does NOT carry (a batch logged after the last
# collect) add to the count instead of being invisible.
printf 'pkg/late.go\ttheirs\tlogged after the last collect\n' > "$SSU/resolutions.batch9.tsv"
SSOUTLA=$SANDBOX/ss-late.out
RUN=$SSU PLAN=$SSPLAN1 bash "$SSS" > "$SSOUTLA" 2>/dev/null
expect "spawn-summary: a shard row the aggregate does not carry is counted (3)" \
  grep -q 'conflict-resolver: 0 dispatches, 3 resolutions logged' "$SSOUTLA"

# No ledger of any kind is still a genuine zero — the false-zero fix must not
# manufacture a count out of nothing.
SSN=$SANDBOX/ss-no-ledger
mkdir -p "$SSN"
SSOUTNL=$SANDBOX/ss-no-ledger.out
RUN=$SSN PLAN=$SSPLAN1 bash "$SSS" > "$SSOUTNL" 2>/dev/null
expect "spawn-summary: no ledger at all is still 0 resolutions" \
  grep -q 'conflict-resolver: 0 dispatches, 0 resolutions logged' "$SSOUTNL"
fi

if t "spawn-summary.sh — a legacy three-field shard row and its normalized aggregate copy count once"; then
# This block PINS the interface:
#   the union is de-duplicated on the NORMALIZED row, not the raw one. log-resolution.sh's
#   collect rebuilds the aggregate with a legacy three-field (pre-region-column) row
#   normalized to four fields — trailing `\t-` — and leaves the on-disk shard row
#   three-field. De-duplicating on the raw row kept BOTH twins, so this fact came out one
#   high per legacy row, in exactly the resume-across-a-skill-upgrade case the
#   normalization exists for. handoff-structural.sh and dropped-template-changes.sh
#   already normalize before their de-dup; this is the third reader of the same ledger.
SSS="$SKILL_DIR/scripts/spawn-summary.sh"
SSLPLAN=$SANDBOX/ss-legacy-PLAN.md
printf '### T01: only\n' > "$SSLPLAN"
SSL=$SANDBOX/ss-legacy
mkdir -p "$SSL"
# The shard as an older skill version wrote it: three fields, no region column.
printf 'pkg/legacy.go\tours\tkept the local shape\n' > "$SSL/resolutions.batch1.tsv"
# The same row as `collect` rebuilt it into the aggregate: normalized to four fields.
printf 'pkg/legacy.go\tours\tkept the local shape\t-\n' > "$SSL/resolutions.tsv"
SSLOUT=$SANDBOX/ss-legacy.out
RUN=$SSL PLAN=$SSLPLAN bash "$SSS" > "$SSLOUT" 2>/dev/null; rc=$?
expect "spawn-summary: a legacy shard beside its normalized aggregate copy exits 0" test "$rc" -eq 0
expect "spawn-summary: the legacy twin pair counts ONCE (1 resolution logged)" \
  grep -q 'conflict-resolver: 0 dispatches, 1 resolutions logged' "$SSLOUT"
refute "spawn-summary: it is NOT double-counted as two resolutions" \
  grep -q 'conflict-resolver: 0 dispatches, 2 resolutions logged' "$SSLOUT"

# Non-vacuity: normalization must not collapse rows that are genuinely different —
# a real fourth-field value is not the same row as the legacy one.
printf 'pkg/legacy.go\tours\tkept the local shape\tREGION 2\n' >> "$SSL/resolutions.batch1.tsv"
SSLOUT2=$SANDBOX/ss-legacy-distinct.out
RUN=$SSL PLAN=$SSLPLAN bash "$SSS" > "$SSLOUT2" 2>/dev/null
expect "spawn-summary: a row differing only in its region column still counts separately (2)" \
  grep -q 'conflict-resolver: 0 dispatches, 2 resolutions logged' "$SSLOUT2"
fi

if t "spawn-summary.sh — a spawn log with no header row loses no row"; then
# This block PINS the interface:
#   row 1 of spawns.tsv is skipped ONLY when it is the header log-spawn.sh writes
#   (first column literally `phase`; a data row's phase column is a digit, enforced by
#   log-spawn.sh), and a headerless ledger says so on one stdout line.
# log-spawn.sh always writes the header, but spawns.tsv is a plain TSV in a state dir
# that gets hand-edited, truncated and copied between runs — and the unconditional
# `NR == 1 { next }` dropped the first DATA row of a headerless log. Silently, and in
# the direction that hides work: a 3-spawn ledger read as 2, and the executor
# cross-check turned that missing first attempt into a phantom skipped task
# ('logged 1 of ~2 expected'), which is a Phase 8 summary that accuses a complete run.
SSS="$SKILL_DIR/scripts/spawn-summary.sh"
SSH=$SANDBOX/ss-headerless
mkdir -p "$SSH"
SSHROWS() { # the same three data rows, used with and without a header
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT02\tok\t\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tfileA\tok\t\n'
}
SSHROWS > "$SSH/spawns.tsv"
SSHPLAN=$SANDBOX/ss-headerless-PLAN.md
printf '### T01: a\n### T02: b\n' > "$SSHPLAN"
SSHOUT=$SANDBOX/ss-headerless.out
RUN=$SSH PLAN=$SSHPLAN bash "$SSS" > "$SSHOUT" 2>/dev/null; rc=$?
expect "spawn-summary: a headerless spawns.tsv still exits 0" test "$rc" -eq 0
expect "spawn-summary: the first data row of a headerless log is counted (executor = 2, not 1)" \
  grep -q 'tier executor: 2' "$SSHOUT"
expect "spawn-summary: the headerless log's other rows keep counting (strong = 1)" \
  grep -q 'tier strong: 1' "$SSHOUT"
expect "spawn-summary: no phantom skipped task comes out of a headerless log (2 of ~2)" \
  grep -q 'executor: logged 2 of ~2 expected' "$SSHOUT"
expect "spawn-summary: the headerless ledger is stated on one line, not handled silently" \
  grep -qi 'no header row' "$SSHOUT"

# The control, and the non-vacuity of the line above: the SAME rows WITH the header
# tally identically, the header itself is still not counted as a spawn, and the
# headerless note is absent — so the skip is a header test, not a dropped guard.
SSHH=$SANDBOX/ss-headerful
mkdir -p "$SSHH"
{ printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'; SSHROWS; } > "$SSHH/spawns.tsv"
SSHHOUT=$SANDBOX/ss-headerful.out
RUN=$SSHH PLAN=$SSHPLAN bash "$SSS" > "$SSHHOUT" 2>/dev/null
expect "spawn-summary: the header row is still not counted as a spawn (executor = 2, strong = 1)" \
  bash -c "grep -q 'tier executor: 2' '$SSHHOUT' && grep -q 'tier strong: 1' '$SSHHOUT'"
refute "spawn-summary: a headerful log carries no headerless note" \
  grep -qi 'no header row' "$SSHHOUT"
fi

if t "spawn-summary.sh — the expected-task count uses plan-slice.sh's task anchor"; then
# This block PINS the interface:
#   M counts ONLY real task headings — `^### T[0-9]+:`, plan-slice.sh's anchor
#   verbatim. A looser `^### T` also matches prose headings a plan legitimately
#   carries ("### Testing notes", "### Troubleshooting"), inflating M and
#   manufacturing a false "tasks were skipped" signal out of a complete run.
SSS="$SKILL_DIR/scripts/spawn-summary.sh"
SSA=$SANDBOX/ss-anchor
mkdir -p "$SSA"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT02\tok\t\n'
} > "$SSA/spawns.tsv"
SSAPLAN=$SANDBOX/ss-anchor-PLAN.md
cat > "$SSAPLAN" <<'MD'
# Plan
### T01: first
### T02: second
### Testing notes
Run the suite per task.
### Troubleshooting
### TODO: leftovers
MD
SSAOUT=$SANDBOX/ss-anchor.out
RUN=$SSA PLAN=$SSAPLAN bash "$SSS" > "$SSAOUT" 2>/dev/null
expect "spawn-summary: prose '### T...' headings are NOT counted as tasks (2 of ~2, not ~5)" \
  grep -q 'executor: logged 2 of ~2 expected' "$SSAOUT"

# The anchor must not over-tighten either: multi-digit task ids still count.
SSAPLAN2=$SANDBOX/ss-anchor-wide-PLAN.md
cat > "$SSAPLAN2" <<'MD'
### T9: nine
### T10: ten
### T100: hundred
### Testing notes
MD
SSAOUT2=$SANDBOX/ss-anchor-wide.out
RUN=$SSA PLAN=$SSAPLAN2 bash "$SSS" > "$SSAOUT2" 2>/dev/null
expect "spawn-summary: one-, two- and three-digit task ids all count (2 of ~3)" \
  grep -q 'executor: logged 2 of ~3 expected' "$SSAOUT2"
fi

if t "spawn-summary.sh — a needs-input relay is not a first attempt (N never exceeds M)"; then
# This block PINS the interface:
#   the executor first-attempt count excludes 'needs-input' rows, the same way it
#   excludes 'retried'/'escalated'. A needs-input task logs its needs-input row AND,
#   after the answer, an 'ok' row for the re-spawn (phases/7 step 6) — counting both
#   pushes N above M and manufactures an N>M shape phases/8 never explains. The tier
#   tally still counts every executor-tier row (the two are different units).
SSS="$SKILL_DIR/scripts/spawn-summary.sh"
SNI=$SANDBOX/ss-needsinput
mkdir -p "$SNI"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tneeds-input\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT02\tok\t\n'
} > "$SNI/spawns.tsv"
SNIPLAN=$SANDBOX/ss-needsinput-PLAN.md
printf '### T01: a\n### T02: b\n' > "$SNIPLAN"
SNIOUT=$SANDBOX/ss-needsinput.out
RUN=$SNI PLAN=$SNIPLAN bash "$SSS" > "$SNIOUT" 2>/dev/null; rc=$?
expect "spawn-summary: needs-input input exits 0" test "$rc" -eq 0
expect "spawn-summary: the needs-input row is NOT a first attempt (2 of ~2, not 3 of ~2)" \
  grep -q 'executor: logged 2 of ~2 expected' "$SNIOUT"
expect "spawn-summary: the tier tally still counts every executor-tier row (executor = 3)" \
  grep -q 'tier executor: 3' "$SNIOUT"
fi

if t "spawn-summary.sh — a green-retried task [fail, retried, ok] is ONE first attempt (tally reset)"; then
# This block PINS the interface:
#   phases/7 step 6 logs a trailing `ok` on every successful commit, INCLUDING a task
#   that recovered via auto-retry, so a green-retried task's rows are [fail, retried, ok]
#   — exactly analogous to needs-input's [needs-input, ok], and the same shape that
#   makes the phases/7 escalation tally reset to zero on the committed `ok`. The
#   first-attempt count must count that task ONCE: excluding only retried/escalated/
#   needs-input would count BOTH the `fail` and the trailing `ok` (2 of ~2 → 3 of ~2, an
#   N>M shape phases/8 never explains). Counting the first `ok`-or-`fail` row per ITEM
#   counts it once. T01 recovered via auto-retry; T02 is a plain success.
SSS="$SKILL_DIR/scripts/spawn-summary.sh"
SGR=$SANDBOX/ss-greenretry
mkdir -p "$SGR"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tfail\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tretried\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT02\tok\t\n'
} > "$SGR/spawns.tsv"
SGRPLAN=$SANDBOX/ss-greenretry-PLAN.md
printf '### T01: a\n### T02: b\n' > "$SGRPLAN"
SGROUT=$SANDBOX/ss-greenretry.out
RUN=$SGR PLAN=$SGRPLAN bash "$SSS" > "$SGROUT" 2>/dev/null; rc=$?
expect "spawn-summary: a green-retried task input exits 0" test "$rc" -eq 0
expect "spawn-summary: [fail, retried, ok] + [ok] is 2 first attempts, not 3 (fail and its committed ok count once)" \
  grep -q 'executor: logged 2 of ~2 expected' "$SGROUT"
expect "spawn-summary: the retry is still visible in the retry count (1 retried row)" \
  grep -q 'retries: 1' "$SGROUT"
expect "spawn-summary: the tier tally still counts every executor-tier row (executor = 4)" \
  grep -q 'tier executor: 4' "$SGROUT"
fi

if t "spawn-summary.sh — a role-switch run logs 0 first attempts legitimately (carve-out note, no false skip)"; then
# This block PINS the interface:
#   a role-switch run dispatches nothing and log-spawn.sh refuses a session-model row,
#   so a clean role-switch run logs N=0. That is NOT the 'tasks were skipped' signal it
#   is for a dispatch run; the summary prints a carve-out note (mode over plan count),
#   in BOTH shapes: no spawns.tsv at all (the fallback), and a spawns.tsv with rows but
#   no executor first attempts (the main tally). A dispatch run with executor rows must
#   NOT carry the note — the note is the zero-first-attempt signal, not boilerplate.
SSS="$SKILL_DIR/scripts/spawn-summary.sh"
# (a) no spawns.tsv at all — the fallback path.
SRA=$SANDBOX/ss-roleswitch-nofile
mkdir -p "$SRA"
SRAPLAN=$SANDBOX/ss-roleswitch-nofile-PLAN.md
printf '### T01: a\n### T02: b\n' > "$SRAPLAN"
SRAOUT=$SANDBOX/ss-roleswitch-nofile.out
RUN=$SRA PLAN=$SRAPLAN bash "$SSS" > "$SRAOUT" 2>/dev/null; rc=$?
expect "spawn-summary: a role-switch run with no spawns.tsv exits 0" test "$rc" -eq 0
expect "spawn-summary: it reports 0 first attempts against the plan (0 of ~2)" \
  grep -q 'executor: logged 0 of ~2 expected' "$SRAOUT"
expect "spawn-summary: and carries the role-switch carve-out note (0 is legitimate)" \
  grep -qi 'role-switch run dispatches nothing' "$SRAOUT"
# (b) a spawns.tsv that DISPATCHED (a conflict-resolver row) but logged no executor
# first attempt — this is a DISPATCH run that skipped Phase 7 execution, NOT a
# role-switch run. The carve-out note must NOT fire here: "0 is legitimate" would
# gloss a real skip and flatly contradict the "1 dispatches" line printed just above
# it. The genuine skip signal is the "logged 0 of ~2 expected" line, which stands.
SRB=$SANDBOX/ss-roleswitch-cronly
mkdir -p "$SRB"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tfileA\tok\t\n'
} > "$SRB/spawns.tsv"
SRBOUT=$SANDBOX/ss-roleswitch-cronly.out
RUN=$SRB PLAN=$SRAPLAN bash "$SSS" > "$SRBOUT" 2>/dev/null
expect "spawn-summary: rows-but-no-executor-first-attempt still reports 0 of ~2 (the skip signal)" \
  grep -q 'executor: logged 0 of ~2 expected' "$SRBOUT"
expect "spawn-summary: the dispatch that DID happen is reported as the real signal" \
  grep -q 'conflict-resolver: 1 dispatches' "$SRBOUT"
refute "spawn-summary: a dispatch run that skipped execution carries NO role-switch carve-out note" \
  grep -qi 'role-switch run dispatches nothing' "$SRBOUT"
# (c) the control / non-vacuity: a dispatch run with executor first attempts carries NO note.
SRC_=$SANDBOX/ss-roleswitch-control
mkdir -p "$SRC_"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\t\n'
  printf '7\texecutor\texecutor\thaiku-x\tT02\tok\t\n'
} > "$SRC_/spawns.tsv"
SRCOUT=$SANDBOX/ss-roleswitch-control.out
RUN=$SRC_ PLAN=$SRAPLAN bash "$SSS" > "$SRCOUT" 2>/dev/null
expect "spawn-summary: the control dispatch run cross-checks normally (2 of ~2)" \
  grep -q 'executor: logged 2 of ~2 expected' "$SRCOUT"
refute "spawn-summary: a normal dispatch run (executor first attempts logged) has no role-switch note" \
  grep -qi 'role-switch run dispatches nothing' "$SRCOUT"
fi

if t "spawn-summary.sh — the actual-model probe emits one MISMATCH line per drifted row"; then
# This block PINS the interface:
#   spawn-summary.sh reads spawns.tsv column 7 (actual_model). For each row whose
#   actual_model is non-empty AND differs from the requested_model (column 4) —
#   compared after trimming whitespace and case-insensitively — it emits exactly one
#   report line, non-blocking, in the format:
#     MISMATCH: requested=<requested_model> actual=<actual_model> (phase <phase>, item <item>)
#   An empty column 7 (the common case) emits nothing; a col-7 that matches the
#   requested model (up to case/whitespace) emits nothing. The line is a report only:
#   the exit code and every existing count stay as they were.
SSS="$SKILL_DIR/scripts/spawn-summary.sh"
SSMPLAN=$SANDBOX/ss-mismatch-PLAN.md
printf '### T01: a\n' > "$SSMPLAN"

# (a) empty col 7 → no MISMATCH line. (b) matching col 7 → no MISMATCH line.
SSMOK=$SANDBOX/ss-mismatch-ok
mkdir -p "$SSMOK"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\t\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tfileA\tok\topus-x\n'
} > "$SSMOK/spawns.tsv"
SSMOKOUT=$SANDBOX/ss-mismatch-ok.out
RUN=$SSMOK PLAN=$SSMPLAN bash "$SSS" > "$SSMOKOUT" 2>/dev/null; rc=$?
expect "spawn-summary: a probe with no drift still exits 0" test "$rc" -eq 0
refute "spawn-summary: an empty col-7 row emits no MISMATCH line" grep -q '^MISMATCH:' "$SSMOKOUT"
refute "spawn-summary: a matching col-7 row emits no MISMATCH line" grep -q '^MISMATCH:' "$SSMOKOUT"

# (c) differing col 7 → exactly one line, in the exact format.
SSMD=$SANDBOX/ss-mismatch-drift
mkdir -p "$SSMD"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tfileA\tok\tsonnet-x\n'
} > "$SSMD/spawns.tsv"
SSMDOUT=$SANDBOX/ss-mismatch-drift.out
RUN=$SSMD PLAN=$SSMPLAN bash "$SSS" > "$SSMDOUT" 2>/dev/null
expect "spawn-summary: a drifted probe emits the MISMATCH line in the exact format" \
  grep -qF 'MISMATCH: requested=opus-x actual=sonnet-x (phase 5, item fileA)' "$SSMDOUT"
expect "spawn-summary: exactly one MISMATCH line per drifted row" \
  bash -c "test \"\$(grep -c '^MISMATCH:' '$SSMDOUT')\" -eq 1"
expect "spawn-summary: the MISMATCH line does not disturb the existing counts" \
  grep -q 'tier strong: 1' "$SSMDOUT"

# (d) case- and whitespace-only difference is NOT a mismatch.
SSMCW=$SANDBOX/ss-mismatch-casews
mkdir -p "$SSMCW"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tfileA\tok\tOPUS-X\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\t  haiku-x  \n'
} > "$SSMCW/spawns.tsv"
SSMCWOUT=$SANDBOX/ss-mismatch-casews.out
RUN=$SSMCW PLAN=$SSMPLAN bash "$SSS" > "$SSMCWOUT" 2>/dev/null
refute "spawn-summary: a case-only col-7 difference is not a mismatch" grep -q '^MISMATCH:' "$SSMCWOUT"
refute "spawn-summary: a whitespace-only col-7 difference is not a mismatch" \
  bash -c "grep -q '^MISMATCH:' '$SSMCWOUT'"

# Two drifted rows → two lines, one each.
SSM2=$SANDBOX/ss-mismatch-two
mkdir -p "$SSM2"
{
  printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model\n'
  printf '5\tconflict-resolver\tstrong\topus-x\tfileA\tok\tsonnet-x\n'
  printf '7\texecutor\texecutor\thaiku-x\tT01\tok\topus-x\n'
} > "$SSM2/spawns.tsv"
SSM2OUT=$SANDBOX/ss-mismatch-two.out
RUN=$SSM2 PLAN=$SSMPLAN bash "$SSS" > "$SSM2OUT" 2>/dev/null
expect "spawn-summary: two drifted rows emit two MISMATCH lines" \
  bash -c "test \"\$(grep -c '^MISMATCH:' '$SSM2OUT')\" -eq 2"
expect "spawn-summary: the first drifted row's line is exact" \
  grep -qF 'MISMATCH: requested=opus-x actual=sonnet-x (phase 5, item fileA)' "$SSM2OUT"
expect "spawn-summary: the second drifted row's line is exact" \
  grep -qF 'MISMATCH: requested=haiku-x actual=opus-x (phase 7, item T01)' "$SSM2OUT"
fi

finish_suite
