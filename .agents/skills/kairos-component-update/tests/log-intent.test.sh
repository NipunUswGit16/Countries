#!/usr/bin/env bash
# log-intent.test.sh — tests for scripts/log-intent.sh
# TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

if t "log-intent.sh — qa-ledger writer (schema, dedupe, no cap)"; then
# This block PINS the interface:
#   env in : RUN (required, created if missing), QUESTION (required, non-empty),
#            ANSWER (required, non-empty), PHASE (required, non-empty),
#            SCOPE (optional — empty first column when the answer is
#            component-wide) — the same env-var convention as log-learning.sh.
#   effect : append exactly ONE row `scope TAB question TAB answer TAB phase`
#            to $RUN/qa-ledger.tsv, creating the file on first append (no
#            header — the schema SKILL.md documents and conflict-resolvers
#            read). Newlines and tabs inside any field collapse to single
#            spaces BEFORE the emptiness check, so one answer always costs one
#            row and free prose can never break the 4-column schema. An EXACT
#            duplicate row is dropped (file unchanged, exit 0). NO entry cap —
#            the ledger is the durable record of what the user said, and
#            refusing to record is the failure the script exists to prevent.
#   keyless: NO PHASE_KEY guard. Appends happen at answer time from many
#            phases; it is not a phase entry point.
#   exit   : non-zero on a missing/empty RUN, QUESTION, ANSWER or PHASE.
LIS="$SKILL_DIR/scripts/log-intent.sh"
LI=$SANDBOX/li-basic

RUN=$LI SCOPE='web/' QUESTION='keep web/?' ANSWER='we deleted web/ deliberately' PHASE=5 \
  bash "$LIS" 2>/dev/null; rc=$?
expect "log-intent: the first append exits 0" test "$rc" -eq 0
expect "log-intent: \$RUN is created if missing (mkdir -p)" test -d "$LI"
expect "log-intent: the first append creates \$RUN/qa-ledger.tsv" test -f "$LI/qa-ledger.tsv"
expect "log-intent: the row is exactly scope TAB question TAB answer TAB phase" \
  grep -Fxq -- "$(printf 'web/\tkeep web/?\twe deleted web/ deliberately\t5')" "$LI/qa-ledger.tsv"
expect "log-intent: no header row — the file is data rows only" \
  bash -c "test \"\$(wc -l < '$LI/qa-ledger.tsv' | tr -d ' ')\" = 1"

# SCOPE is optional: a component-wide answer has an empty first column but the
# row still holds exactly 4 tab-separated fields, so readers never special-case.
env -u SCOPE RUN=$LI QUESTION='use the event handler?' ANSWER='no, it is unused' PHASE=5 \
  bash "$LIS" 2>/dev/null; rc=$?
expect "log-intent: a missing SCOPE still exits 0 (optional)" test "$rc" -eq 0
expect "log-intent: the scopeless row has an EMPTY first column, question in column 2" \
  grep -Fxq -- "$(printf '\tuse the event handler?\tno, it is unused\t5')" "$LI/qa-ledger.tsv"
expect "log-intent: every row holds exactly 4 tab-separated fields" \
  bash -c "awk -F'\t' 'NF != 4 { bad = 1 } END { exit bad }' '$LI/qa-ledger.tsv'"

# The schema survives hostile prose: tabs and newlines inside ANSWER collapse to
# single spaces, so the answer costs ONE row of exactly 4 columns.
LIHOSTILE=$SANDBOX/li-hostile
RUN=$LIHOSTILE SCOPE=cmd/worker QUESTION='take cmd/worker?' ANSWER='yes,
take it	all —
	every file' PHASE=5 bash "$LIS" 2>/dev/null; rc=$?
expect "log-intent: an answer with tabs and newlines exits 0" test "$rc" -eq 0
expect "log-intent: the hostile answer costs exactly one row" \
  bash -c "test \"\$(wc -l < '$LIHOSTILE/qa-ledger.tsv' | tr -d ' ')\" = 1"
expect "log-intent: tabs/newlines collapsed — the row still holds exactly 4 fields" \
  bash -c "awk -F'\t' 'NF != 4 { bad = 1 } END { exit bad }' '$LIHOSTILE/qa-ledger.tsv'"
expect "log-intent: the collapsed answer reads as one whitespace-squeezed line" \
  grep -Fxq -- "$(printf 'cmd/worker\ttake cmd/worker?\tyes, take it all — every file\t5')" "$LIHOSTILE/qa-ledger.tsv"

# An EXACT duplicate row is dropped — file unchanged, exit 0. A re-asked
# question or resumed phase must not double the record.
RUN=$LI SCOPE='web/' QUESTION='keep web/?' ANSWER='we deleted web/ deliberately' PHASE=5 \
  bash "$LIS" 2>/dev/null; rc=$?
expect "log-intent: an EXACT duplicate exits 0" test "$rc" -eq 0
expect "log-intent: an EXACT duplicate is dropped (row count unchanged)" \
  bash -c "test \"\$(wc -l < '$LI/qa-ledger.tsv' | tr -d ' ')\" = 2"

# A near-duplicate is a different record: same question, different answer lands.
RUN=$LI SCOPE='web/' QUESTION='keep web/?' ANSWER='actually, restore it' PHASE=7 \
  bash "$LIS" 2>/dev/null
expect "log-intent: a near-duplicate (same question, different answer) is NOT dropped" \
  bash -c "test \"\$(wc -l < '$LI/qa-ledger.tsv' | tr -d ' ')\" = 3"
expect "log-intent: append order is preserved (the first row stays on line 1)" \
  bash -c "test \"\$(awk 'NR==1' '$LI/qa-ledger.tsv')\" = \"\$(printf 'web/\tkeep web/?\twe deleted web/ deliberately\t5')\""

# NO cap — unlike log-learning.sh's 40-entry ceiling. Seed 59 rows; the 60th
# still lands. Silently refusing to record an answer is the failure this
# script exists to prevent.
LI59=$SANDBOX/li-59
mkdir -p "$LI59"
for i in $(seq 1 59); do printf 'scope%s\tq%s\ta%s\t5\n' "$i" "$i" "$i"; done > "$LI59/qa-ledger.tsv"
RUN=$LI59 SCOPE=scope60 QUESTION='q60' ANSWER='the sixtieth answer' PHASE=5 \
  bash "$LIS" 2> "$SANDBOX/li-60.err"; rc=$?
expect "log-intent: the 60th append exits 0" test "$rc" -eq 0
expect "log-intent: NO cap — the 60th row still lands (unlike log-learning.sh)" \
  grep -Fq 'the sixtieth answer' "$LI59/qa-ledger.tsv"
expect "log-intent: the file now holds exactly 60 rows" \
  bash -c "test \"\$(wc -l < '$LI59/qa-ledger.tsv' | tr -d ' ')\" = 60"
refute "log-intent: no cap warning on stderr — every answer is recorded" \
  grep -qi 'warn' "$SANDBOX/li-60.err"

# KEYLESS by design: appends happen at answer time from many phases, so a
# PHASE_KEY guard would brick them. This is the regression guard for that rule.
LIKEYLESS=$SANDBOX/li-keyless
env -u PHASE_KEY RUN=$LIKEYLESS QUESTION='keyless?' ANSWER='keyless by design' PHASE=3.5 \
  bash "$LIS" 2>/dev/null; rc=$?
expect "log-intent: KEYLESS — runs with NO PHASE_KEY in the environment" test "$rc" -eq 0
expect "log-intent: the keyless append actually landed" \
  grep -Fq 'keyless by design' "$LIKEYLESS/qa-ledger.tsv"

# Required inputs are refused non-zero and write nothing. Whitespace-only is as
# empty as unset — the collapse runs BEFORE the emptiness check (guarded on the
# script existing, so a missing script is RED here rather than vacuously green).
LIBAD=$SANDBOX/li-bad
if [[ -f "$LIS" ]] && ! env -u RUN QUESTION=q ANSWER=a PHASE=5 bash "$LIS" 2>/dev/null; then pass "log-intent: a missing RUN exits non-zero"; else fail "log-intent: a missing RUN exits non-zero"; fi
if [[ -f "$LIS" ]] && ! RUN= QUESTION=q ANSWER=a PHASE=5 bash "$LIS" 2>/dev/null; then pass "log-intent: an empty RUN exits non-zero"; else fail "log-intent: an empty RUN exits non-zero"; fi
if [[ -f "$LIS" ]] && ! env -u QUESTION RUN=$LIBAD ANSWER=a PHASE=5 bash "$LIS" 2>/dev/null; then pass "log-intent: a missing QUESTION exits non-zero"; else fail "log-intent: a missing QUESTION exits non-zero"; fi
if [[ -f "$LIS" ]] && ! RUN=$LIBAD QUESTION='
  ' ANSWER=a PHASE=5 bash "$LIS" 2>/dev/null; then pass "log-intent: a whitespace-only QUESTION exits non-zero"; else fail "log-intent: a whitespace-only QUESTION exits non-zero"; fi
if [[ -f "$LIS" ]] && ! env -u ANSWER RUN=$LIBAD QUESTION=q PHASE=5 bash "$LIS" 2>/dev/null; then pass "log-intent: a missing ANSWER exits non-zero"; else fail "log-intent: a missing ANSWER exits non-zero"; fi
if [[ -f "$LIS" ]] && ! RUN=$LIBAD QUESTION=q ANSWER='
	 ' PHASE=5 bash "$LIS" 2>/dev/null; then pass "log-intent: a whitespace-only ANSWER exits non-zero"; else fail "log-intent: a whitespace-only ANSWER exits non-zero"; fi
if [[ -f "$LIS" ]] && ! env -u PHASE RUN=$LIBAD QUESTION=q ANSWER=a bash "$LIS" 2>/dev/null; then pass "log-intent: a missing PHASE exits non-zero"; else fail "log-intent: a missing PHASE exits non-zero"; fi
if [[ -f "$LIS" ]] && ! RUN=$LIBAD QUESTION=q ANSWER=a PHASE= bash "$LIS" 2>/dev/null; then pass "log-intent: an empty PHASE exits non-zero"; else fail "log-intent: an empty PHASE exits non-zero"; fi
refute "log-intent: a rejected input writes nothing" test -e "$LIBAD/qa-ledger.tsv"

fi

finish_suite
