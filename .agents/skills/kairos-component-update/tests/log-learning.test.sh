#!/usr/bin/env bash
# log-learning.test.sh — tests for scripts/log-learning.sh
# TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

if t "log-learning.sh — per-run learnings file (append, dedupe, cap)"; then
# This block PINS the interface:
#   env in : RUN (required, created if missing), ITEM (required, non-empty),
#            TEXT (required, non-empty) — the same env-var convention as log-spawn.sh.
#   effect : append exactly ONE line "- [<ITEM>] <TEXT>" to $RUN/learnings.md, creating
#            the file on first append (no header line — just the bullet lines). Newlines
#            inside TEXT collapse to single spaces and leading/trailing whitespace is
#            trimmed, so the one-line-per-fact invariant always holds. An EXACT duplicate
#            of a line already in the file is dropped (file unchanged, exit 0). A hard cap
#            of 40 entries (entries = lines beginning with '- [') refuses any further
#            append with a stderr WARNING and exit 0 — a chatty executor must never fail
#            its task by over-sharing.
#   keyless: NO PHASE_KEY guard. The callers are executor subagents, which never load
#            phase files, so a guard would brick every append.
#   exit   : non-zero on a missing/empty RUN, ITEM or TEXT.
LLS="$SKILL_DIR/scripts/log-learning.sh"
LL=$SANDBOX/ll-basic

RUN=$LL ITEM=T01 TEXT='make test needs CGO_ENABLED=0' bash "$LLS" 2>/dev/null; rc=$?
expect "log-learning: the first append exits 0" test "$rc" -eq 0
expect "log-learning: \$RUN is created if missing (mkdir -p)" test -d "$LL"
expect "log-learning: the first append creates \$RUN/learnings.md" test -f "$LL/learnings.md"
expect "log-learning: the line is exactly '- [<ITEM>] <TEXT>'" \
  grep -Fxq -- '- [T01] make test needs CGO_ENABLED=0' "$LL/learnings.md"
expect "log-learning: no header line — the file is bullets only" \
  bash -c "test \"\$(wc -l < '$LL/learnings.md' | tr -d ' ')\" = 1"

# A second, different fact adds a second line; earlier facts keep their place.
RUN=$LL ITEM=T02 TEXT='sql/1.gen is generated; never hand-edit it' bash "$LLS" 2>/dev/null
expect "log-learning: a second, different append adds a second line" \
  bash -c "test \"\$(wc -l < '$LL/learnings.md' | tr -d ' ')\" = 2"
expect "log-learning: append order is preserved (the first fact stays on line 1)" \
  bash -c "test \"\$(awk 'NR==1' '$LL/learnings.md')\" = '- [T01] make test needs CGO_ENABLED=0'"
expect "log-learning: the second fact lands on line 2" \
  bash -c "test \"\$(awk 'NR==2' '$LL/learnings.md')\" = '- [T02] sql/1.gen is generated; never hand-edit it'"

# An EXACT duplicate is dropped — same ITEM, same TEXT, file unchanged, exit 0.
RUN=$LL ITEM=T01 TEXT='make test needs CGO_ENABLED=0' bash "$LLS" 2>/dev/null; rc=$?
expect "log-learning: an EXACT duplicate exits 0" test "$rc" -eq 0
expect "log-learning: an EXACT duplicate is dropped (line count unchanged)" \
  bash -c "test \"\$(wc -l < '$LL/learnings.md' | tr -d ' ')\" = 2"

# A near-duplicate is a different fact: same ITEM, different TEXT, so it lands.
RUN=$LL ITEM=T01 TEXT='make test is flaky under -race' bash "$LLS" 2>/dev/null
expect "log-learning: a near-duplicate (same ITEM, different TEXT) is NOT dropped" \
  bash -c "test \"\$(wc -l < '$LL/learnings.md' | tr -d ' ')\" = 3"

# Multi-line TEXT collapses onto ONE line and is trimmed — the file must never gain a
# line that is not a '- [' entry, or a reader's screenful budget stops being countable.
RUN=$LL ITEM=T03 TEXT='  first part
second part  ' bash "$LLS" 2>/dev/null
expect "log-learning: a multi-line TEXT is collapsed onto one line, whitespace trimmed" \
  grep -Fxq -- '- [T03] first part second part' "$LL/learnings.md"
expect "log-learning: the collapsed fact costs exactly one line" \
  bash -c "test \"\$(wc -l < '$LL/learnings.md' | tr -d ' ')\" = 4"
refute "log-learning: every line in the file is a '- [' entry (one fact per line)" \
  grep -qv '^- \[' "$LL/learnings.md"

# The cap is a ceiling, not an off-by-one: at 39 entries the 40th still lands.
LL39=$SANDBOX/ll-39
mkdir -p "$LL39"
for i in $(seq 1 39); do printf -- '- [T%02d] seeded fact %s\n' "$i" "$i"; done > "$LL39/learnings.md"
RUN=$LL39 ITEM=T40 TEXT='the fortieth fact' bash "$LLS" 2>/dev/null; rc=$?
expect "log-learning: the 40th append exits 0" test "$rc" -eq 0
expect "log-learning: at 39 entries the 40th append still lands" \
  grep -Fxq -- '- [T40] the fortieth fact' "$LL39/learnings.md"
expect "log-learning: the file now holds exactly 40 entries" \
  bash -c "test \"\$(grep -c '^- \[' '$LL39/learnings.md')\" = 40"

# At the cap the append is REFUSED — warned about, but never fatal to the caller.
LLCAP=$SANDBOX/ll-cap
mkdir -p "$LLCAP"
for i in $(seq 1 40); do printf -- '- [T%02d] seeded fact %s\n' "$i" "$i"; done > "$LLCAP/learnings.md"
RUN=$LLCAP ITEM=T41 TEXT='one fact too many' bash "$LLS" 2> "$SANDBOX/ll-cap.err"; rc=$?
expect "log-learning: an append past the 40-entry cap still exits 0 (over-sharing never fails a task)" \
  test "$rc" -eq 0
expect "log-learning: the refusal is warned about on stderr" grep -qi 'warn' "$SANDBOX/ll-cap.err"
expect "log-learning: the capped file still holds exactly 40 entries" \
  bash -c "test \"\$(grep -c '^- \[' '$LLCAP/learnings.md')\" = 40"
refute "log-learning: the refused text is not in the file" \
  grep -Fq 'one fact too many' "$LLCAP/learnings.md"

# KEYLESS by design: executor subagents never load a phase file, so a PHASE_KEY guard
# would brick every append. This is the regression guard for that rule.
LLK=$SANDBOX/ll-keyless
env -u PHASE_KEY RUN=$LLK ITEM=T07 TEXT='keyless by design' bash "$LLS" 2>/dev/null; rc=$?
expect "log-learning: KEYLESS — runs with NO PHASE_KEY in the environment" test "$rc" -eq 0
expect "log-learning: the keyless append actually landed" \
  grep -Fxq -- '- [T07] keyless by design' "$LLK/learnings.md"

# Required inputs are refused non-zero and write nothing (guarded on the script
# existing, so a missing script is RED here rather than vacuously green).
LLBAD=$SANDBOX/ll-bad
if [[ -f "$LLS" ]] && ! env -u RUN ITEM=T01 TEXT='no run dir' bash "$LLS" 2>/dev/null; then pass "log-learning: a missing RUN exits non-zero"; else fail "log-learning: a missing RUN exits non-zero"; fi
if [[ -f "$LLS" ]] && ! RUN= ITEM=T01 TEXT='empty run dir' bash "$LLS" 2>/dev/null; then pass "log-learning: an empty RUN exits non-zero"; else fail "log-learning: an empty RUN exits non-zero"; fi
if [[ -f "$LLS" ]] && ! env -u ITEM RUN=$LLBAD TEXT='no item key' bash "$LLS" 2>/dev/null; then pass "log-learning: a missing ITEM exits non-zero"; else fail "log-learning: a missing ITEM exits non-zero"; fi
if [[ -f "$LLS" ]] && ! RUN=$LLBAD ITEM= TEXT='empty item key' bash "$LLS" 2>/dev/null; then pass "log-learning: an empty ITEM exits non-zero"; else fail "log-learning: an empty ITEM exits non-zero"; fi
refute "log-learning: a rejected ITEM writes nothing" test -e "$LLBAD/learnings.md"
if [[ -f "$LLS" ]] && ! env -u TEXT RUN=$LLBAD ITEM=T09 bash "$LLS" 2>/dev/null; then pass "log-learning: a missing TEXT exits non-zero"; else fail "log-learning: a missing TEXT exits non-zero"; fi
if [[ -f "$LLS" ]] && ! RUN=$LLBAD ITEM=T09 TEXT= bash "$LLS" 2>/dev/null; then pass "log-learning: an empty TEXT exits non-zero"; else fail "log-learning: an empty TEXT exits non-zero"; fi
refute "log-learning: a rejected TEXT writes nothing" test -e "$LLBAD/learnings.md"

fi

finish_suite
