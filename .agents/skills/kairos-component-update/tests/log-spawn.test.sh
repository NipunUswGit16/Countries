#!/usr/bin/env bash
# log-spawn.test.sh — tests for scripts/log-spawn.sh
# TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

if t "log-spawn.sh — appends a well-formed spawns.tsv row"; then
# This block PINS the interface:
#   env in : RUN (required), PHASE, ROLE, TIER, MODEL (the REQUESTED model), ITEM,
#            OUTCOME (one of: ok|needs-input|fail|escalated|retried), ACTUAL_MODEL (optional).
#   effect : append ONE tab-separated row to $RUN/spawns.tsv; on the first write, emit
#            a header row FIRST. The header columns are, literally (note column 4 is
#            literally named 'requested_model'):
#              phase  role  tier  requested_model  item  outcome  actual_model
#            Every data row is 7 columns; actual_model (col 7) is empty unless
#            ACTUAL_MODEL is set. A second append must NOT re-emit the header.
#   exit   : non-zero on a bad OUTCOME value or a missing RUN.
LSS="$SKILL_DIR/scripts/log-spawn.sh"
LS_HDR=$(printf 'phase\trole\ttier\trequested_model\titem\toutcome\tactual_model')
LS=$SANDBOX/ls-basic
seed_model_pins "$LS"
seed_model_pins "$SANDBOX/ls-bad"

RUN=$LS PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=haiku-x ITEM=T01 OUTCOME=ok \
  bash "$LSS" 2>/dev/null
if [[ -f "$LS/spawns.tsv" ]]; then pass "log-spawn: first append creates \$RUN/spawns.tsv"; else fail "log-spawn: first append creates \$RUN/spawns.tsv"; fi
if [[ "$(head -1 "$LS/spawns.tsv" 2>/dev/null)" = "$LS_HDR" ]]; then pass "log-spawn: header is the 7 named columns (col 4 literally 'requested_model')"; else fail "log-spawn: header is the 7 named columns (col 4 literally 'requested_model')"; fi
if [[ "$(awk -F'\t' 'NR==2{print NF}' "$LS/spawns.tsv" 2>/dev/null)" = 7 ]]; then pass "log-spawn: the data row has 7 tab-separated columns"; else fail "log-spawn: the data row has 7 tab-separated columns"; fi
if [[ "$(awk -F'\t' 'NR==2{print $4}' "$LS/spawns.tsv" 2>/dev/null)" = haiku-x ]]; then pass "log-spawn: the requested MODEL lands in column 4"; else fail "log-spawn: the requested MODEL lands in column 4"; fi
if [[ "$(awk -F'\t' 'NR==2{print $6}' "$LS/spawns.tsv" 2>/dev/null)" = ok ]]; then pass "log-spawn: OUTCOME lands in column 6"; else fail "log-spawn: OUTCOME lands in column 6"; fi
if [[ "$(awk -F'\t' 'NR==2{print NF"|"$7}' "$LS/spawns.tsv" 2>/dev/null)" = '7|' ]]; then pass "log-spawn: actual_model (col 7) is empty when ACTUAL_MODEL is unset"; else fail "log-spawn: actual_model (col 7) is empty when ACTUAL_MODEL is unset"; fi

# A second append adds a row without re-emitting the header.
RUN=$LS PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=verifier TIER=strong MODEL=opus-x ITEM=T01 OUTCOME=ok \
  bash "$LSS" 2>/dev/null
LS_HDRC=$(awk -F'\t' '$1=="phase"' "$LS/spawns.tsv" 2>/dev/null | wc -l | tr -d ' ')
LS_LINEC=$(wc -l < "$LS/spawns.tsv" 2>/dev/null | tr -d ' ')
if [[ "$LS_HDRC" = 1 ]] && [[ "$LS_LINEC" = 3 ]]; then pass "log-spawn: a second append adds a row without duplicating the header"; else fail "log-spawn: a second append adds a row without duplicating the header"; fi

# ACTUAL_MODEL lands in column 7 on the row where it is set.
RUN=$LS PHASE=5 PHASE_KEY=$PK_STRUCTURAL ROLE=conflict-resolver TIER=strong MODEL=opus-x ITEM=fileA OUTCOME=ok ACTUAL_MODEL=probed-slug \
  bash "$LSS" 2>/dev/null
if [[ "$(awk -F'\t' '$5=="fileA"{print $7}' "$LS/spawns.tsv" 2>/dev/null)" = probed-slug ]]; then pass "log-spawn: ACTUAL_MODEL lands in column 7 on the row it is set"; else fail "log-spawn: ACTUAL_MODEL lands in column 7 on the row it is set"; fi

# A bad OUTCOME is rejected non-zero.
if [[ -f "$LSS" ]] && ! RUN=$SANDBOX/ls-bad PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=m ITEM=Tx OUTCOME=weird bash "$LSS" 2>/dev/null; then pass "log-spawn: a bad OUTCOME (not ok|needs-input|fail|escalated|retried) is rejected non-zero"; else fail "log-spawn: a bad OUTCOME (not ok|needs-input|fail|escalated|retried) is rejected non-zero"; fi
# A missing RUN exits non-zero.
if [[ -f "$LSS" ]] && ! env -u RUN PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=m ITEM=Tx OUTCOME=ok bash "$LSS" 2>/dev/null; then pass "log-spawn: a missing RUN exits non-zero"; else fail "log-spawn: a missing RUN exits non-zero"; fi

fi

if t "log-spawn.sh — the OUTCOME vocabulary carries 'retried' and stays closed"; then
# This block PINS the interface:
#   OUTCOME is a CLOSED set of five values: ok|needs-input|fail|escalated|retried.
#   'retried' marks the auto-retry dispatch (the first attempt's row keeps 'fail') —
#   the same mechanism-over-result convention 'escalated' already uses. Every value in
#   the set lands a normal 7-column row with the value in column 6; adding 'retried'
#   must not weaken the validation, so anything outside the set is still rejected
#   non-zero, logs nothing, and the stderr message still names the whole accepted set.
#   Rows are logged under PHASE=7, so every dispatch needs Phase 7's key.
LSS="$SKILL_DIR/scripts/log-spawn.sh"
LSR=$SANDBOX/ls-retried
seed_model_pins "$LSR"

RUN=$LSR PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=haiku-x ITEM=T07 OUTCOME=retried \
  bash "$LSS" 2>/dev/null
if [[ -f "$LSR/spawns.tsv" ]]; then pass "log-spawn: OUTCOME=retried is accepted (the row lands)"; else fail "log-spawn: OUTCOME=retried is accepted (the row lands)"; fi
if [[ "$(awk -F'\t' '$5=="T07"{print $6}' "$LSR/spawns.tsv" 2>/dev/null)" = retried ]]; then pass "log-spawn: 'retried' lands in column 6"; else fail "log-spawn: 'retried' lands in column 6"; fi
if [[ "$(awk -F'\t' '$5=="T07"{print NF}' "$LSR/spawns.tsv" 2>/dev/null)" = 7 ]]; then pass "log-spawn: a retried row is a normal 7-column row"; else fail "log-spawn: a retried row is a normal 7-column row"; fi

# The whole vocabulary lands — 'retried' is an addition, not a replacement.
for o in ok needs-input fail escalated retried; do
  RUN=$LSR PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=haiku-x ITEM="V-$o" OUTCOME="$o" \
    bash "$LSS" 2>/dev/null
  if [[ "$(awk -F'\t' -v i="V-$o" '$5==i{print $6}' "$LSR/spawns.tsv" 2>/dev/null)" = "$o" ]]; then pass "log-spawn: OUTCOME=$o is accepted and lands in column 6"; else fail "log-spawn: OUTCOME=$o is accepted and lands in column 6"; fi
done

# The set stays CLOSED: a near-miss of the new value is still rejected, logs nothing,
# and the rejection still enumerates the accepted set (now including 'retried').
LSERR=$SANDBOX/ls-retried.err
if [[ -f "$LSS" ]] && ! RUN=$LSR PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=m ITEM=Tx OUTCOME=retry bash "$LSS" 2>"$LSERR"; then pass "log-spawn: a near-miss OUTCOME ('retry') is still rejected non-zero"; else fail "log-spawn: a near-miss OUTCOME ('retry') is still rejected non-zero"; fi
if ! awk -F'\t' '$5=="Tx"' "$LSR/spawns.tsv" 2>/dev/null | grep -q .; then pass "log-spawn: a rejected OUTCOME logs no row"; else fail "log-spawn: a rejected OUTCOME logs no row"; fi
if grep -q 'ok|needs-input|fail|escalated|retried' "$LSERR" 2>/dev/null; then pass "log-spawn: the rejection names the full accepted set (retried included)"; else fail "log-spawn: the rejection names the full accepted set (retried included)"; fi

fi

if t "log-spawn.sh — a dispatch with no resolved pins is refused, and leaves no file"; then
# This block PINS the interface:
#   log-spawn.sh reads $RUN/model.txt and refuses to record a dispatch when it is
#   ABSENT. That is the fail-closed reading of the skill's own rule — "every
#   dispatched subagent names its model explicitly, never inherit the session
#   model" was guarded by nothing at all, so a skipped model resolution surfaced at
#   Phase 8 as a missing budget= line, after every dispatch had already run on the
#   wrong model. The refusal must name the remedy (resolve-models.sh), and — the
#   assertion that matters for a RECORDER used as a check — a refused first call
#   must write NO header either, or a later accepted call appends its row beneath a
#   header that certifies a run whose first dispatch was rejected.
LSS="$SKILL_DIR/scripts/log-spawn.sh"
LSN=$SANDBOX/ls-nopins
mkdir -p "$LSN"
LSNERR=$SANDBOX/ls-nopins.err

RUN=$LSN PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=haiku-x ITEM=T01 OUTCOME=ok \
  bash "$LSS" 2>"$LSNERR"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-spawn: a dispatch with no \$RUN/model.txt is refused non-zero"; else fail "log-spawn: a dispatch with no \$RUN/model.txt is refused non-zero (rc=$rc)"; fi
refute "log-spawn: the refused first dispatch wrote no spawns.tsv at all (no orphan header)" test -e "$LSN/spawns.tsv"
expect "log-spawn: the refusal names resolve-models.sh as the remedy" grep -qF 'resolve-models.sh' "$LSNERR"

# Once the pins exist, the same call is recorded — the refusal is about the missing
# file, not about the dispatch.
seed_model_pins "$LSN"
RUN=$LSN PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=haiku-x ITEM=T01 OUTCOME=ok \
  bash "$LSS" 2>/dev/null
if [[ "$(awk -F'\t' '$5=="T01"{print $6}' "$LSN/spawns.tsv" 2>/dev/null)" = ok ]]; then pass "log-spawn: with the pins on disk the same dispatch records normally"; else fail "log-spawn: with the pins on disk the same dispatch records normally"; fi
if [[ "$(wc -l < "$LSN/spawns.tsv" 2>/dev/null | tr -d ' ')" = 2 ]]; then pass "log-spawn: the accepted call writes header + one row (the refusal left nothing behind)"; else fail "log-spawn: the accepted call writes header + one row (the refusal left nothing behind)"; fi

fi

if t "log-spawn.sh — the requested MODEL must be the pin for the declared TIER"; then
# This block PINS the interface:
#   For TIER in strong|coder|executor, MODEL must equal that tier's pin in
#   $RUN/model.txt. A mismatch is refused non-zero, names BOTH slugs (requested and
#   pinned), and logs nothing — a hallucinated or hand-typed slug stops the run at
#   the FIRST dispatch that used it rather than after every dispatch has.
#   The check is a RECORDER's check: it fires after the dispatch already ran, so the
#   refusal also has to name the disposition of the work that exists. What it buys
#   is the BOUND, not prevention.
LSS="$SKILL_DIR/scripts/log-spawn.sh"
LSP=$SANDBOX/ls-pins
seed_model_pins "$LSP"    # strong=opus-x coder=sonnet-x executor=haiku-x

# Every tier's matching pin is accepted.
for pair in strong:opus-x coder:sonnet-x executor:haiku-x; do
  tier=${pair%%:*}; slug=${pair#*:}
  RUN=$LSP PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER="$tier" MODEL="$slug" ITEM="ok-$tier" OUTCOME=ok \
    bash "$LSS" 2>/dev/null
  if [[ "$(awk -F'\t' -v i="ok-$tier" '$5==i{print $3"|"$4}' "$LSP/spawns.tsv" 2>/dev/null)" = "$tier|$slug" ]]; then
    pass "log-spawn: TIER=$tier with its pin ($slug) is recorded"
  else
    fail "log-spawn: TIER=$tier with its pin ($slug) is recorded"
  fi
done

# Every tier's MISMATCHED slug is refused, names both slugs, and logs nothing.
for pair in strong:sonnet-x coder:haiku-x executor:opus-x; do
  tier=${pair%%:*}; wrong=${pair#*:}
  case "$tier" in strong) pinned=opus-x ;; coder) pinned=sonnet-x ;; executor) pinned=haiku-x ;; esac
  LSPERR=$SANDBOX/ls-pins-$tier.err
  RUN=$LSP PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER="$tier" MODEL="$wrong" ITEM="bad-$tier" OUTCOME=ok \
    bash "$LSS" 2>"$LSPERR"; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "log-spawn: TIER=$tier with a non-pin model ($wrong) is refused non-zero"; else fail "log-spawn: TIER=$tier with a non-pin model ($wrong) is refused non-zero (rc=$rc)"; fi
  if grep -qF "$wrong" "$LSPERR" && grep -qF "$pinned" "$LSPERR"; then
    pass "log-spawn: the TIER=$tier refusal names both the requested and the pinned slug"
  else
    fail "log-spawn: the TIER=$tier refusal names both the requested and the pinned slug"
  fi
  refute "log-spawn: the refused TIER=$tier dispatch logged no row" \
    grep -qF "bad-$tier" "$LSP/spawns.tsv"
done

# The refusal names the disposition of the work that already ran — the check fires
# at recording time, so "what do I do with the commit" is the user's next question.
expect "log-spawn: the refusal says the recorded work must be redone or reverted on the pin" \
  grep -qiE 're-?dispatch' "$SANDBOX/ls-pins-executor.err"

# A TIER outside the three pinned ones is recorded WITHOUT a model check: a future
# tier must not brick the ledger.
RUN=$LSP PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=probe TIER=futuretier MODEL=whatever-x ITEM=future OUTCOME=ok \
  bash "$LSS" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(awk -F'\t' '$5=="future"{print $4}' "$LSP/spawns.tsv" 2>/dev/null)" = whatever-x ]]; then
  pass "log-spawn: an unrecognised TIER is recorded with no model check"
else
  fail "log-spawn: an unrecognised TIER is recorded with no model check (rc=$rc)"
fi

# ACTUAL_MODEL is explicitly NOT validated — it is the probe's honest report, and
# the mismatch it may reveal is the entire reason the probed row exists.
RUN=$LSP PHASE=5 PHASE_KEY=$PK_STRUCTURAL ROLE=conflict-resolver TIER=strong MODEL=opus-x \
  ITEM=probed OUTCOME=ok ACTUAL_MODEL=something-else-entirely bash "$LSS" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(awk -F'\t' '$5=="probed"{print $7}' "$LSP/spawns.tsv" 2>/dev/null)" = something-else-entirely ]]; then
  pass "log-spawn: ACTUAL_MODEL is never validated against the pins (the probe reports honestly)"
else
  fail "log-spawn: ACTUAL_MODEL is never validated against the pins (rc=$rc)"
fi

# The header is still written exactly once across all of the above.
if [[ "$(awk -F'\t' '$1=="phase"' "$LSP/spawns.tsv" | wc -l | tr -d ' ')" = 1 ]]; then
  pass "log-spawn: the header is written exactly once despite the refusals in between"
else
  fail "log-spawn: the header is written exactly once despite the refusals in between"
fi

fi

if t "log-spawn.sh — tabs and newlines in a field cannot shift the TSV columns"; then
# This block PINS the interface:
#   Every free-form field (ROLE, TIER, MODEL, ITEM, ACTUAL_MODEL) is collapsed —
#   tabs, CRs and newlines become single spaces, then the value is trimmed — BEFORE
#   it reaches the row, the same collapse() log-intent.sh applies. ITEM carries
#   conflict-file paths, so one dispatch always costs exactly ONE 7-column row no
#   matter what the path contains, and spawn-summary.sh's tallies read the same
#   numbers they would for a plain path.
#   Collapsing happens BEFORE the tier-pin comparison, which is why the executor
#   pin below is seeded as the COLLAPSED form of the tab-bearing MODEL this block
#   sends: the pin check must compare the value that lands in the row, not the raw
#   env string, or a sanitized field would read as a pin violation.
LSS="$SKILL_DIR/scripts/log-spawn.sh"
LSC=$SANDBOX/ls-collapse
seed_model_pins "$LSC" opus-x sonnet-x 'haiku x'

# A conflict path carrying a TAB: without collapsing, column 5 splits and the row
# becomes 8 columns, shifting outcome/actual_model one place right.
ITEM_TAB=$(printf 'pkg/we\tird.go')
RUN=$LSC PHASE=5 PHASE_KEY=$PK_STRUCTURAL ROLE=conflict-resolver TIER=strong MODEL=opus-x \
  ITEM="$ITEM_TAB" OUTCOME=ok bash "$LSS" 2>/dev/null
if [[ "$(wc -l < "$LSC/spawns.tsv" 2>/dev/null | tr -d ' ')" = 2 ]]; then pass "log-spawn: a tab-bearing ITEM still costs exactly one row"; else fail "log-spawn: a tab-bearing ITEM still costs exactly one row"; fi
if [[ "$(awk -F'\t' 'NR==2{print NF}' "$LSC/spawns.tsv" 2>/dev/null)" = 7 ]]; then pass "log-spawn: a tab-bearing ITEM keeps the row at 7 columns"; else fail "log-spawn: a tab-bearing ITEM keeps the row at 7 columns"; fi
if [[ "$(awk -F'\t' 'NR==2{print $5}' "$LSC/spawns.tsv" 2>/dev/null)" = 'pkg/we ird.go' ]]; then pass "log-spawn: the tab inside ITEM collapses to a single space"; else fail "log-spawn: the tab inside ITEM collapses to a single space"; fi
if [[ "$(awk -F'\t' 'NR==2{print $6}' "$LSC/spawns.tsv" 2>/dev/null)" = ok ]]; then pass "log-spawn: OUTCOME stays in column 6 despite the tab-bearing ITEM"; else fail "log-spawn: OUTCOME stays in column 6 despite the tab-bearing ITEM"; fi

# A NEWLINE-bearing ITEM must not split one dispatch across two lines.
ITEM_NL=$(printf 'pkg/two\nlines.go')
RUN=$LSC PHASE=5 PHASE_KEY=$PK_STRUCTURAL ROLE=conflict-resolver TIER=strong MODEL=opus-x \
  ITEM="$ITEM_NL" OUTCOME=ok bash "$LSS" 2>/dev/null
if [[ "$(wc -l < "$LSC/spawns.tsv" 2>/dev/null | tr -d ' ')" = 3 ]]; then pass "log-spawn: a newline-bearing ITEM still costs exactly one row"; else fail "log-spawn: a newline-bearing ITEM still costs exactly one row"; fi
if [[ "$(awk -F'\t' 'NR==3{print NF"|"$5}' "$LSC/spawns.tsv" 2>/dev/null)" = '7|pkg/two lines.go' ]]; then pass "log-spawn: the newline inside ITEM collapses to a single space"; else fail "log-spawn: the newline inside ITEM collapses to a single space"; fi

# The other free-form fields are sanitized too, not just ITEM.
RUN=$LSC PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE="$(printf 'exec\tutor')" TIER="$(printf ' executor \n')" \
  MODEL="$(printf 'haiku\tx')" ITEM=T09 OUTCOME=ok ACTUAL_MODEL="$(printf 'probed\nslug')" \
  bash "$LSS" 2>/dev/null
if [[ "$(awk -F'\t' '$5=="T09"{print NF}' "$LSC/spawns.tsv" 2>/dev/null)" = 7 ]]; then pass "log-spawn: tabs/newlines in ROLE, TIER, MODEL and ACTUAL_MODEL keep the row at 7 columns"; else fail "log-spawn: tabs/newlines in ROLE, TIER, MODEL and ACTUAL_MODEL keep the row at 7 columns"; fi
if [[ "$(awk -F'\t' '$5=="T09"{print $2"|"$3"|"$4"|"$7}' "$LSC/spawns.tsv" 2>/dev/null)" = 'exec utor|executor|haiku x|probed slug' ]]; then pass "log-spawn: ROLE/TIER/MODEL/ACTUAL_MODEL are collapsed and trimmed"; else fail "log-spawn: ROLE/TIER/MODEL/ACTUAL_MODEL are collapsed and trimmed"; fi

# End to end: a ledger written entirely from tab/newline-bearing paths must give
# spawn-summary.sh the same tallies plain paths would.
LSCS=$SANDBOX/ls-collapse-summary
seed_model_pins "$LSCS"
for i in 1 2 3; do
  RUN=$LSCS PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=haiku-x \
    ITEM="$(printf 'T0%s\tweird\npath.go' "$i")" OUTCOME=ok bash "$LSS" 2>/dev/null
done
LSCPLAN=$SANDBOX/ls-collapse-PLAN.md
printf '### T01: a\n### T02: b\n### T03: c\n' > "$LSCPLAN"
LSCOUT=$SANDBOX/ls-collapse-summary.out
RUN=$LSCS PLAN=$LSCPLAN bash "$SKILL_DIR/scripts/spawn-summary.sh" > "$LSCOUT" 2>/dev/null
expect "log-spawn: a sanitized ledger tallies its tier correctly (tier executor: 3)" \
  grep -q 'tier executor: 3' "$LSCOUT"
expect "log-spawn: a sanitized ledger keeps the executor cross-check honest (3 of ~3)" \
  grep -q 'executor: logged 3 of ~3 expected' "$LSCOUT"

fi

if t "log-spawn.sh — a dispatch from a pinned phase needs that phase's key (proof-of-load)"; then
# This block PINS the interface:
#   Dispatches are logged from exactly two phases, and each phase's key is stated
#   ONLY in its own file (PHASE=5 -> phases/5-structural.md, PHASE=7 ->
#   phases/7-execution.md). A dispatch under PHASE=5 or PHASE=7 whose PHASE_KEY does
#   not match — wrong value OR unset — is refused non-zero, names the phase file to
#   load, and logs nothing: the key is the proof the dispatching phase's file was
#   actually loaded, not improvised from stub knowledge. Any OTHER PHASE value (or
#   none) is not a phase entry point today and deliberately keeps the historical
#   keyless behavior, so the guarantee is only as strong as the caller setting PHASE.
#   The key check runs BEFORE the model-pin check, so pins are seeded here only to
#   prove the refusal is the KEY talking, not a missing model.txt downstream.
LSS="$SKILL_DIR/scripts/log-spawn.sh"

for pair in "5:$PK_STRUCTURAL:phases/5-structural.md" "7:$PK_EXECUTION:phases/7-execution.md"; do
  ph=${pair%%:*}; rest=${pair#*:}; goodkey=${rest%%:*}; wantfile=${rest#*:}
  LSK=$SANDBOX/ls-key-$ph
  seed_model_pins "$LSK"

  # Wrong key -> refused, names the phase file, logs nothing.
  LSKERR=$SANDBOX/ls-key-$ph.err
  RUN=$LSK PHASE=$ph PHASE_KEY=not-the-key ROLE=executor TIER=executor MODEL=haiku-x ITEM=Tk OUTCOME=ok \
    bash "$LSS" 2>"$LSKERR"; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "log-spawn: PHASE=$ph with a wrong PHASE_KEY is refused non-zero"; else fail "log-spawn: PHASE=$ph with a wrong PHASE_KEY is refused non-zero (rc=$rc)"; fi
  expect "log-spawn: the PHASE=$ph key refusal names $wantfile to load" grep -qF "$wantfile" "$LSKERR"
  refute "log-spawn: the refused PHASE=$ph dispatch wrote no spawns.tsv" test -e "$LSK/spawns.tsv"

  # Unset key -> same refusal (the guard reads PHASE_KEY:-, so empty is wrong too).
  RUN=$LSK PHASE=$ph ROLE=executor TIER=executor MODEL=haiku-x ITEM=Tk OUTCOME=ok \
    env -u PHASE_KEY bash "$LSS" 2>/dev/null; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "log-spawn: PHASE=$ph with an unset PHASE_KEY is refused non-zero"; else fail "log-spawn: PHASE=$ph with an unset PHASE_KEY is refused non-zero (rc=$rc)"; fi

  # Right key -> accepted (the refusal is about the key, not the phase).
  RUN=$LSK PHASE=$ph PHASE_KEY=$goodkey ROLE=executor TIER=executor MODEL=haiku-x ITEM=Tk OUTCOME=ok \
    bash "$LSS" 2>/dev/null
  if [[ "$(awk -F'\t' '$5=="Tk"{print $6}' "$LSK/spawns.tsv" 2>/dev/null)" = ok ]]; then pass "log-spawn: PHASE=$ph with the correct key records normally"; else fail "log-spawn: PHASE=$ph with the correct key records normally"; fi
done

# An out-of-range PHASE (or none) is NOT a phase entry point today and keeps the
# historical keyless behavior — recorded with no key check. This documents the
# deliberate gap: the proof-of-load guarantee depends on the caller setting PHASE.
LSKX=$SANDBOX/ls-key-other
seed_model_pins "$LSKX"
RUN=$LSKX PHASE=3 ROLE=executor TIER=executor MODEL=haiku-x ITEM=Tother OUTCOME=ok \
  env -u PHASE_KEY bash "$LSS" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(awk -F'\t' '$5=="Tother"{print $6}' "$LSKX/spawns.tsv" 2>/dev/null)" = ok ]]; then
  pass "log-spawn: an out-of-range PHASE keeps historical keyless behavior (no key check)"
else
  fail "log-spawn: an out-of-range PHASE keeps historical keyless behavior (rc=$rc)"
fi

fi

if t "log-spawn.sh — PHASE is validated digits-only before it can shift a column or skip the guard"; then
# This block PINS the interface:
#   PHASE lands in column 1 AND gates the proof-of-load case (literal 5 / 7), so a
#   value carrying a tab/newline/space ("5 ", "7\tx") would BOTH shift every later
#   column spawn-summary.sh tallies and slip past the key guard. PHASE is therefore
#   refused non-zero unless it is digits only, BEFORE anything reads it — collapse()
#   is not enough (a collapsed "5 " still is not "5"). A refused call logs nothing.
#   A digit value other than 5/7 keeps the historical keyless behavior (recorded).
LSS="$SKILL_DIR/scripts/log-spawn.sh"
LSPH=$SANDBOX/ls-phase
seed_model_pins "$LSPH"

# (a) PHASE with an embedded tab / newline / internal space -> refused, no row.
# NOTE: these are assigned to a var (not passed via $(...)) so a trailing space or
# newline survives — command substitution would strip it and mask the very hazard.
b_tab=$(printf '5\tx'); b_nl=$(printf '7\n8'); b_sp='5 6'
for bad in "$b_tab" "$b_nl" "$b_sp" "5x" "phase5"; do
  rm -f "$LSPH/spawns.tsv"
  LSPHERR=$SANDBOX/ls-phase.err
  RUN=$LSPH PHASE="$bad" PHASE_KEY=$PK_STRUCTURAL ROLE=executor TIER=executor MODEL=haiku-x ITEM=Tp OUTCOME=ok \
    bash "$LSS" 2>"$LSPHERR"; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "log-spawn: a non-digit PHASE is refused non-zero"; else fail "log-spawn: a non-digit PHASE is refused non-zero (rc=$rc, bad=[$bad])"; fi
  refute "log-spawn: the refused non-digit PHASE wrote no spawns.tsv" test -e "$LSPH/spawns.tsv"
  expect "log-spawn: the refusal names PHASE as digits-only" grep -qF 'PHASE must be digits only' "$LSPHERR"
done

# A trailing-space PHASE ("5 ") must be refused too — the exact "looks like phase 5
# but slips the guard" shape. Assigned directly so the trailing byte is preserved.
b_trail='5 '
rm -f "$LSPH/spawns.tsv"
LSPHERR=$SANDBOX/ls-phase-trail.err
RUN=$LSPH PHASE="$b_trail" PHASE_KEY=$PK_STRUCTURAL ROLE=executor TIER=executor MODEL=haiku-x ITEM=Tp OUTCOME=ok \
  bash "$LSS" 2>"$LSPHERR"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-spawn: a trailing-space PHASE ('5 ') is refused (cannot masquerade as phase 5)"; else fail "log-spawn: a trailing-space PHASE ('5 ') is refused (rc=$rc)"; fi
refute "log-spawn: the refused trailing-space PHASE wrote no spawns.tsv" test -e "$LSPH/spawns.tsv"

# An unset/empty PHASE is refused too (the phase number is required).
rm -f "$LSPH/spawns.tsv"
RUN=$LSPH PHASE='' PHASE_KEY=$PK_STRUCTURAL ROLE=executor TIER=executor MODEL=haiku-x ITEM=Tp OUTCOME=ok \
  bash "$LSS" 2>/dev/null; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "log-spawn: an empty PHASE is refused non-zero"; else fail "log-spawn: an empty PHASE is refused non-zero (rc=$rc)"; fi
refute "log-spawn: the refused empty PHASE wrote no spawns.tsv" test -e "$LSPH/spawns.tsv"

# (b) PHASE=05 is all digits -> passes the digit check. It is not the literal "5",
# so it is NOT a dispatching-phase entry point: it keeps the historical keyless
# behavior (recorded, no key needed) and lands its clean value in column 1. Refusing
# "05" while accepting "3" (which the suite above and skill-lint's PHASE=2 test pin
# as keyless) would need arbitrary leading-zero logic, so digits-only is the line.
rm -f "$LSPH/spawns.tsv"
RUN=$LSPH PHASE=05 ROLE=executor TIER=executor MODEL=haiku-x ITEM=Tzero OUTCOME=ok \
  env -u PHASE_KEY bash "$LSS" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(awk -F'\t' '$5=="Tzero"{print $1}' "$LSPH/spawns.tsv" 2>/dev/null)" = 05 ]]; then
  pass "log-spawn: PHASE=05 (all digits, not literal 5) is recorded keyless with 05 in column 1"
else
  fail "log-spawn: PHASE=05 is recorded keyless with 05 in column 1 (rc=$rc)"
fi

fi

if t "log-spawn.sh — an exact re-append is dropped, but a real second dispatch lands"; then
# This block PINS the interface:
#   The ledger records ONE first-attempt row per (phase, role, tier, model, item,
#   outcome). Two byte-identical rows can only be a replay (a compaction/resume
#   re-running a logging block), so an exact re-append is a no-op (exit 0, one row),
#   the same grep -Fxq dedup log-intent.sh applies. Genuinely distinct dispatches
#   never collide: they differ in some column — e.g. OUTCOME — so both rows land.
LSS="$SKILL_DIR/scripts/log-spawn.sh"
LSD=$SANDBOX/ls-dedup
seed_model_pins "$LSD"

# (c) The same dispatch logged twice -> a single data row, exit 0 both times.
for n in 1 2; do
  RUN=$LSD PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=haiku-x ITEM=Tdup OUTCOME=ok \
    bash "$LSS" 2>/dev/null; rc=$?
  if [[ "$rc" -eq 0 ]]; then pass "log-spawn: append #$n of an identical row exits 0"; else fail "log-spawn: append #$n of an identical row exits 0 (rc=$rc)"; fi
done
if [[ "$(awk -F'\t' '$5=="Tdup"' "$LSD/spawns.tsv" 2>/dev/null | wc -l | tr -d ' ')" = 1 ]]; then
  pass "log-spawn: an exact re-append is dropped — the dispatch is counted once"
else
  fail "log-spawn: an exact re-append is dropped — the dispatch is counted once"
fi
# The header is still present exactly once (dedup does not disturb it).
if [[ "$(awk -F'\t' '$1=="phase"' "$LSD/spawns.tsv" | wc -l | tr -d ' ')" = 1 ]]; then pass "log-spawn: the header survives the dedup exactly once"; else fail "log-spawn: the header survives the dedup exactly once"; fi

# (d) The SAME row but a different OUTCOME is a distinct dispatch -> both rows land.
RUN=$LSD PHASE=7 PHASE_KEY=$PK_EXECUTION ROLE=executor TIER=executor MODEL=haiku-x ITEM=Tdup OUTCOME=retried \
  bash "$LSS" 2>/dev/null
if [[ "$(awk -F'\t' '$5=="Tdup"' "$LSD/spawns.tsv" 2>/dev/null | wc -l | tr -d ' ')" = 2 ]]; then
  pass "log-spawn: a row differing only in OUTCOME is NOT a duplicate — both land"
else
  fail "log-spawn: a row differing only in OUTCOME is NOT a duplicate — both land"
fi
if [[ "$(awk -F'\t' '$5=="Tdup"{print $6}' "$LSD/spawns.tsv" 2>/dev/null | sort | tr '\n' ',')" = 'ok,retried,' ]]; then
  pass "log-spawn: the two Tdup rows carry the distinct outcomes ok and retried"
else
  fail "log-spawn: the two Tdup rows carry the distinct outcomes ok and retried"
fi

fi

finish_suite
