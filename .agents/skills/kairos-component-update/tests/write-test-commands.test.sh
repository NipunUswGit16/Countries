#!/usr/bin/env bash
# write-test-commands.test.sh — tests for scripts/write-test-commands.sh
# TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

WTC="$SKILL_DIR/scripts/write-test-commands.sh"

if t "write-test-commands.sh — writes the four positional lines"; then
# This block PINS the interface:
#   env in : RUN (required), PHASE_KEY (Phase 4.5's), TEST_CMD, EXTRACTOR,
#            BUILD_CMD, REGEN_CMD.
#   effect : $RUN/test-command.txt carries exactly the four positional lines the
#            contract in reference/gates.md defines — 1 test, 2 extractor, 3 build,
#            4 regeneration — and nothing else.
#   Until this script the orchestrator hand-wrote those four lines, and every gate
#   label, every executor and every verifier read them BY LINE NUMBER: a shifted
#   line silently redefines what "regression" means for the whole run.
W1=$SANDBOX/w1
RUN=$W1 PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep -E "^--- FAIL" | sort -u' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' bash "$WTC" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "write-test-commands: a complete call exits 0"; else fail "write-test-commands: a complete call exits 0 (rc=$rc)"; fi
expect "write-test-commands: \$RUN/test-command.txt is created" test -f "$W1/test-command.txt"
if [[ "$(sed -n 1p "$W1/test-command.txt" 2>/dev/null)" = 'go test ./...' ]]; then pass "write-test-commands: line 1 is the test command"; else fail "write-test-commands: line 1 is the test command"; fi
if [[ "$(sed -n 2p "$W1/test-command.txt" 2>/dev/null)" = 'grep -E "^--- FAIL" | sort -u' ]]; then pass "write-test-commands: line 2 is the failure extractor"; else fail "write-test-commands: line 2 is the failure extractor"; fi
if [[ "$(sed -n 3p "$W1/test-command.txt" 2>/dev/null)" = 'go build ./...' ]]; then pass "write-test-commands: line 3 is the build command"; else fail "write-test-commands: line 3 is the build command"; fi
if [[ "$(sed -n 4p "$W1/test-command.txt" 2>/dev/null)" = 'make generate' ]]; then pass "write-test-commands: line 4 is the regeneration command"; else fail "write-test-commands: line 4 is the regeneration command"; fi
if [[ "$(wc -l < "$W1/test-command.txt" | tr -d ' ')" = 4 ]]; then pass "write-test-commands: the file is exactly four lines"; else fail "write-test-commands: the file is exactly four lines"; fi

fi

if t "write-test-commands.sh — an empty value becomes its literal placeholder"; then
# This block PINS the interface:
#   An empty TEST_CMD / BUILD_CMD / REGEN_CMD lands the LITERAL 'no tests detected'
#   / 'no build check' / 'no regen command' on its own line, because every reader
#   reads by line number: a blank or omitted line would shift every line below it
#   and silently redefine what the gates compare. Those three literals are the
#   vocabulary gate.sh and producer-idempotence.sh already recognise as an honest
#   absence (INCOMPLETE, not FAIL).
#   Line 2 is the one exception: with no test command there is no extractor, and it
#   is left EMPTY rather than given a literal. That is the fail-closed choice — if
#   line 1 ever became a real command, an empty line 2 is a gate-internal FAIL,
#   while an invented literal would be eval'd as an extractor.
W2=$SANDBOX/w2
RUN=$W2 PHASE_KEY=$PK_BASELINE TEST_CMD='' EXTRACTOR='' BUILD_CMD='' REGEN_CMD='' \
  bash "$WTC" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "write-test-commands: an all-empty call is a legitimate record, not an error"; else fail "write-test-commands: an all-empty call is a legitimate record, not an error (rc=$rc)"; fi
if [[ "$(sed -n 1p "$W2/test-command.txt" 2>/dev/null)" = 'no tests detected' ]]; then pass "write-test-commands: an empty TEST_CMD becomes the literal 'no tests detected'"; else fail "write-test-commands: an empty TEST_CMD becomes the literal 'no tests detected'"; fi
if [[ "$(sed -n 2p "$W2/test-command.txt" 2>/dev/null)" = '' ]]; then pass "write-test-commands: line 2 stays empty when there is no test command"; else fail "write-test-commands: line 2 stays empty when there is no test command"; fi
if [[ "$(sed -n 3p "$W2/test-command.txt" 2>/dev/null)" = 'no build check' ]]; then pass "write-test-commands: an empty BUILD_CMD becomes the literal 'no build check'"; else fail "write-test-commands: an empty BUILD_CMD becomes the literal 'no build check'"; fi
if [[ "$(sed -n 4p "$W2/test-command.txt" 2>/dev/null)" = 'no regen command' ]]; then pass "write-test-commands: an empty REGEN_CMD becomes the literal 'no regen command'"; else fail "write-test-commands: an empty REGEN_CMD becomes the literal 'no regen command'"; fi
if [[ "$(wc -l < "$W2/test-command.txt" | tr -d ' ')" = 4 ]]; then pass "write-test-commands: the all-empty file is still exactly four lines (no shift)"; else fail "write-test-commands: the all-empty file is still exactly four lines (no shift)"; fi

# An UNSET var is the same as an empty one — the phase discovers "nothing fits" by
# not setting the variable at all.
W2B=$SANDBOX/w2b
env -u TEST_CMD -u EXTRACTOR -u BUILD_CMD -u REGEN_CMD \
  RUN=$W2B PHASE_KEY=$PK_BASELINE bash "$WTC" >/dev/null 2>&1
if [[ "$(tr '\n' '|' < "$W2B/test-command.txt" 2>/dev/null)" = 'no tests detected||no build check|no regen command|' ]]; then
  pass "write-test-commands: unset vars produce the same placeholder layout as empty ones"
else
  fail "write-test-commands: unset vars produce the same placeholder layout as empty ones (got '$(tr '\n' '|' < "$W2B/test-command.txt" 2>/dev/null)')"
fi

# A middle line can be absent on its own without disturbing its neighbours.
W2C=$SANDBOX/w2c
RUN=$W2C PHASE_KEY=$PK_BASELINE TEST_CMD='pytest -q' EXTRACTOR='tail -5' BUILD_CMD='' REGEN_CMD='make generate' \
  bash "$WTC" >/dev/null 2>&1
if [[ "$(sed -n 3p "$W2C/test-command.txt" 2>/dev/null)" = 'no build check' ]] \
   && [[ "$(sed -n 4p "$W2C/test-command.txt" 2>/dev/null)" = 'make generate' ]]; then
  pass "write-test-commands: one missing middle command does not shift the line below it"
else
  fail "write-test-commands: one missing middle command does not shift the line below it"
fi

fi

if t "write-test-commands.sh — refuses a TEST_CMD with no EXTRACTOR, and refuses it at write time"; then
# This block PINS the interface:
#   A line 1 that carries a command while line 2 carries no extractor is ALREADY a
#   gate-internal FAIL downstream ("the failure set cannot be compared against the
#   baseline"). Refuse it at write time instead: the run stops at Phase 4.5 with a
#   fixable message rather than at the post-merge gate with an internal error.
#   A refusal must write NOTHING — the file is byte-identical afterwards, or absent
#   if it never existed, so a rejected call cannot leave a half-written contract.
W3=$SANDBOX/w3
W3ERR=$SANDBOX/w3.err
RUN=$W3 PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='' BUILD_CMD='go build ./...' \
  REGEN_CMD='make generate' bash "$WTC" >/dev/null 2>"$W3ERR"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "write-test-commands: a TEST_CMD with no EXTRACTOR is refused non-zero"; else fail "write-test-commands: a TEST_CMD with no EXTRACTOR is refused non-zero (rc=$rc)"; fi
refute "write-test-commands: the refusal wrote no test-command.txt at all" test -e "$W3/test-command.txt"
expect "write-test-commands: the refusal names EXTRACTOR" grep -qF 'EXTRACTOR' "$W3ERR"

# The refusal must not damage an already-correct file either.
W3B=$SANDBOX/w3b
RUN=$W3B PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' BUILD_CMD='go build ./...' \
  REGEN_CMD='make generate' bash "$WTC" >/dev/null 2>&1
cp "$W3B/test-command.txt" "$SANDBOX/w3b.before"
RUN=$W3B PHASE_KEY=$PK_BASELINE TEST_CMD='pytest' EXTRACTOR='' BUILD_CMD='' REGEN_CMD='' \
  bash "$WTC" >/dev/null 2>&1 || true
expect "write-test-commands: a refused call leaves an existing file byte-identical" \
  cmp -s "$SANDBOX/w3b.before" "$W3B/test-command.txt"

# The placeholder is not a command, so it needs no extractor.
W3C=$SANDBOX/w3c
RUN=$W3C PHASE_KEY=$PK_BASELINE TEST_CMD='' EXTRACTOR='' BUILD_CMD='go build ./...' REGEN_CMD='' \
  bash "$WTC" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "write-test-commands: 'no tests detected' needs no extractor"; else fail "write-test-commands: 'no tests detected' needs no extractor (rc=$rc)"; fi

# The INVERSE the header also forbids ("must be empty when [TEST_CMD] is not"): an
# EXTRACTOR with no TEST_CMD would ride onto line 2 above a 'no tests detected'
# line 1 — and if line 1 ever became a real command that stray extractor gates it.
# It is refused non-zero at write time, writing nothing, the same posture as the
# TEST_CMD-without-EXTRACTOR half above.
W3D=$SANDBOX/w3d
W3DERR=$SANDBOX/w3d.err
RUN=$W3D PHASE_KEY=$PK_BASELINE TEST_CMD='' EXTRACTOR='grep FAIL' BUILD_CMD='go build ./...' \
  REGEN_CMD='' bash "$WTC" >/dev/null 2>"$W3DERR"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "write-test-commands: an EXTRACTOR with no TEST_CMD is refused non-zero"; else fail "write-test-commands: an EXTRACTOR with no TEST_CMD is refused non-zero (rc=$rc)"; fi
refute "write-test-commands: the inverse refusal wrote no test-command.txt at all" test -e "$W3D/test-command.txt"
expect "write-test-commands: the inverse refusal names EXTRACTOR and TEST_CMD" \
  bash -c "grep -qF EXTRACTOR \"$W3DERR\" && grep -qF TEST_CMD \"$W3DERR\""

fi

if t "write-test-commands.sh — a newline in a value cannot shift the positional lines"; then
# This block PINS the interface:
#   Every value is collapsed — newlines, CRs and tabs become single spaces, then the
#   value is trimmed — BEFORE it reaches the file. This is the positional analogue of
#   the collapse() the three ledger writers apply to their columns: a discovered
#   command pasted with a trailing newline, or a two-line extractor pipeline, would
#   otherwise push the build command onto line 4 and the regeneration command out of
#   the file entirely.
W4=$SANDBOX/w4
RUN=$W4 PHASE_KEY=$PK_BASELINE \
  TEST_CMD="$(printf 'go test\n./...')" \
  EXTRACTOR="$(printf 'grep FAIL |\n sort -u')" \
  BUILD_CMD="$(printf '  go build ./...  ')" \
  REGEN_CMD="$(printf 'make\tgenerate')" \
  bash "$WTC" >/dev/null 2>&1
if [[ "$(wc -l < "$W4/test-command.txt" | tr -d ' ')" = 4 ]]; then pass "write-test-commands: newline-bearing values still produce exactly four lines"; else fail "write-test-commands: newline-bearing values still produce exactly four lines"; fi
if [[ "$(sed -n 1p "$W4/test-command.txt")" = 'go test ./...' ]]; then pass "write-test-commands: a newline inside TEST_CMD collapses to a space"; else fail "write-test-commands: a newline inside TEST_CMD collapses to a space"; fi
if [[ "$(sed -n 2p "$W4/test-command.txt")" = 'grep FAIL | sort -u' ]]; then pass "write-test-commands: a newline inside EXTRACTOR collapses to a space"; else fail "write-test-commands: a newline inside EXTRACTOR collapses to a space"; fi
if [[ "$(sed -n 3p "$W4/test-command.txt")" = 'go build ./...' ]]; then pass "write-test-commands: surrounding whitespace is trimmed (a blank-looking line is never written)"; else fail "write-test-commands: surrounding whitespace is trimmed"; fi
if [[ "$(sed -n 4p "$W4/test-command.txt")" = 'make generate' ]]; then pass "write-test-commands: a tab inside REGEN_CMD collapses to a space"; else fail "write-test-commands: a tab inside REGEN_CMD collapses to a space"; fi

# A whitespace-only value is as absent as an unset one — it must become the
# placeholder, not a blank line the gates read as 'not a command'.
W4B=$SANDBOX/w4b
RUN=$W4B PHASE_KEY=$PK_BASELINE TEST_CMD='   ' EXTRACTOR='' BUILD_CMD="$(printf ' \t ')" REGEN_CMD='' \
  bash "$WTC" >/dev/null 2>&1
if [[ "$(sed -n 1p "$W4B/test-command.txt")" = 'no tests detected' ]] \
   && [[ "$(sed -n 3p "$W4B/test-command.txt")" = 'no build check' ]]; then
  pass "write-test-commands: a whitespace-only value becomes the placeholder, not a blank line"
else
  fail "write-test-commands: a whitespace-only value becomes the placeholder, not a blank line"
fi

fi

if t "write-test-commands.sh — rejections append strictly after line 4"; then
# This block PINS the interface:
#   REJECT=<candidate> REASON=<why> appends one `# rejected: <cmd> — <reason>` line
#   AFTER line 4 and never above it. That placement is the whole point: a rejection
#   recorded by the zero-evidence guard landing on line 1–4 would be read as a
#   command by a gate (and both gate.sh and producer-idempotence.sh carry an
#   explicit arm for the drifted-comment case precisely because it used to happen).
#   The four positional lines are created as placeholders first when the file does
#   not exist yet, because during discovery the first rejection can precede the
#   chosen command.
W5=$SANDBOX/w5
RUN=$W5 PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' bash "$WTC" >/dev/null 2>&1
RUN=$W5 PHASE_KEY=$PK_BASELINE REJECT='make vet' REASON='compiled zero packages' \
  bash "$WTC" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "write-test-commands: a REJECT call exits 0"; else fail "write-test-commands: a REJECT call exits 0 (rc=$rc)"; fi
if [[ "$(sed -n 5p "$W5/test-command.txt" 2>/dev/null)" = '# rejected: make vet — compiled zero packages' ]]; then
  pass "write-test-commands: the rejection lands on line 5 in the documented shape"
else
  fail "write-test-commands: the rejection lands on line 5 in the documented shape (got '$(sed -n 5p "$W5/test-command.txt" 2>/dev/null)')"
fi
refute "write-test-commands: no rejection comment sits on any of lines 1-4" \
  bash -c "sed -n '1,4p' '$W5/test-command.txt' | grep -q '# rejected'"
if [[ "$(sed -n 1p "$W5/test-command.txt")" = 'go test ./...' ]] \
   && [[ "$(sed -n 4p "$W5/test-command.txt")" = 'make generate' ]]; then
  pass "write-test-commands: the four positional lines are untouched by the append"
else
  fail "write-test-commands: the four positional lines are untouched by the append"
fi

# A rejection recorded BEFORE any command is chosen still cannot reach line 1.
W5B=$SANDBOX/w5b
RUN=$W5B PHASE_KEY=$PK_BASELINE REJECT='make vet' REASON='vacuous green' bash "$WTC" >/dev/null 2>&1
if [[ "$(sed -n 1p "$W5B/test-command.txt" 2>/dev/null)" = 'no tests detected' ]] \
   && [[ "$(sed -n 5p "$W5B/test-command.txt" 2>/dev/null)" = '# rejected: make vet — vacuous green' ]]; then
  pass "write-test-commands: a rejection on a fresh run creates the four placeholders first"
else
  fail "write-test-commands: a rejection on a fresh run creates the four placeholders first"
fi

# Writing the chosen commands afterwards must PRESERVE the rejections — otherwise
# the discovery order (reject, then choose) silently discards the audit trail.
RUN=$W5B PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' bash "$WTC" >/dev/null 2>&1
if [[ "$(sed -n 1p "$W5B/test-command.txt")" = 'go test ./...' ]] \
   && [[ "$(sed -n 5p "$W5B/test-command.txt")" = '# rejected: make vet — vacuous green' ]]; then
  pass "write-test-commands: writing the commands preserves rejections recorded earlier"
else
  fail "write-test-commands: writing the commands preserves rejections recorded earlier"
fi

# Several rejections stack in order, all still below line 4.
RUN=$W5B PHASE_KEY=$PK_BASELINE REJECT='npm test' REASON='no test script' bash "$WTC" >/dev/null 2>&1
if [[ "$(sed -n 6p "$W5B/test-command.txt")" = '# rejected: npm test — no test script' ]]; then
  pass "write-test-commands: a second rejection appends beneath the first"
else
  fail "write-test-commands: a second rejection appends beneath the first"
fi

# A REJECT with no REASON is refused: '# rejected: <cmd> — ' records nothing
# auditable, which is the only reason the line exists.
W5CERR=$SANDBOX/w5c.err
RUN=$W5B PHASE_KEY=$PK_BASELINE REJECT='cargo test' bash "$WTC" >/dev/null 2>"$W5CERR"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "write-test-commands: a REJECT with no REASON is refused non-zero"; else fail "write-test-commands: a REJECT with no REASON is refused non-zero (rc=$rc)"; fi
refute "write-test-commands: the reasonless rejection wrote no line" \
  grep -qF 'cargo test' "$W5B/test-command.txt"

# A newline in either field cannot become two lines — one rejection, one line.
RUN=$W5B PHASE_KEY=$PK_BASELINE REJECT="$(printf 'make\nvet2')" REASON="$(printf 'zero\npackages')" \
  bash "$WTC" >/dev/null 2>&1
if [[ "$(sed -n 7p "$W5B/test-command.txt")" = '# rejected: make vet2 — zero packages' ]]; then
  pass "write-test-commands: newlines in REJECT/REASON collapse — one rejection costs one line"
else
  fail "write-test-commands: newlines in REJECT/REASON collapse (got '$(sed -n 7p "$W5B/test-command.txt")')"
fi

fi

if t "write-test-commands.sh — a re-run with the same values is byte-identical"; then
# This block PINS the interface:
#   Re-run safety is what makes this callable from Continue mode's re-entry into
#   Phase 4.5 without doubling anything. Two identical command writes give a
#   byte-identical file, and an identical rejection is dropped rather than stacked —
#   the same duplicate-drop the other ledger writers apply.
W6=$SANDBOX/w6
for _ in 1 2; do
  RUN=$W6 PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
    BUILD_CMD='go build ./...' REGEN_CMD='make generate' bash "$WTC" >/dev/null 2>&1
done
if [[ "$(wc -l < "$W6/test-command.txt" | tr -d ' ')" = 4 ]]; then pass "write-test-commands: two identical command writes leave four lines"; else fail "write-test-commands: two identical command writes leave four lines"; fi
cp "$W6/test-command.txt" "$SANDBOX/w6.snap"
RUN=$W6 PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' bash "$WTC" >/dev/null 2>&1
expect "write-test-commands: a third identical write is byte-identical" \
  cmp -s "$SANDBOX/w6.snap" "$W6/test-command.txt"

RUN=$W6 PHASE_KEY=$PK_BASELINE REJECT='make vet' REASON='vacuous green' bash "$WTC" >/dev/null 2>&1
RUN=$W6 PHASE_KEY=$PK_BASELINE REJECT='make vet' REASON='vacuous green' bash "$WTC" >/dev/null 2>&1
if [[ "$(grep -cF '# rejected: make vet — vacuous green' "$W6/test-command.txt")" = 1 ]]; then
  pass "write-test-commands: an identical rejection is recorded once, not twice"
else
  fail "write-test-commands: an identical rejection is recorded once, not twice"
fi

fi

if t "write-test-commands.sh — the Phase 4.5 key is required"; then
# This block PINS the interface:
#   This is Phase 4.5's FIRST script call, so it is the phase's proof-of-load entry
#   point: without PHASE_KEY=u7qk3mfp it refuses and names the phase file, and it
#   writes nothing.
W7=$SANDBOX/w7
W7ERR=$SANDBOX/w7.err
env -u PHASE_KEY RUN=$W7 TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' bash "$WTC" >/dev/null 2>"$W7ERR"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/4.5-test-baseline.md first' "$W7ERR"; then
  pass "write-test-commands: without PHASE_KEY it exits non-zero naming phases/4.5-test-baseline.md"
else
  fail "write-test-commands: without PHASE_KEY it exits non-zero naming phases/4.5-test-baseline.md (rc=$rc)"
fi
refute "write-test-commands: the keyless call wrote nothing" test -e "$W7/test-command.txt"
RUN=$W7 PHASE_KEY=not-the-key TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' bash "$WTC" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "write-test-commands: a wrong PHASE_KEY is refused non-zero"; else fail "write-test-commands: a wrong PHASE_KEY is refused non-zero (rc=$rc)"; fi
if [[ -f "$WTC" ]] && ! env -u RUN PHASE_KEY=$PK_BASELINE TEST_CMD='' bash "$WTC" >/dev/null 2>&1; then
  pass "write-test-commands: a missing RUN is refused non-zero"
else
  fail "write-test-commands: a missing RUN is refused non-zero"
fi

fi

if t "write-test-commands.sh — the positional contract round-trips through its real readers"; then
# This block PINS the interface — and it is the assertion that carries most of this
# script's value. The positional contract has two ends: this writer and the readers
# that index it by line number (gate.sh at all three labels, producer-idempotence.sh
# for lines 3-4). Asserting them against EACH OTHER is the only way to catch a
# shifted line; a hand-built fixture would just re-encode whatever the writer does.
WRT=$SANDBOX/rt-run; WRC=$SANDBOX/rt-comp; WRS=$SANDBOX/rt-synth
mkdir -p "$WRT" "$WRC" "$WRS"
( cd "$WRS" && git init -q -b main \
  && printf 'name: sprocket\nreplicas: 2\n' > config.yaml \
  && git add -A && git commit -qm target && git tag kairos-target )
( cd "$WRC" && git init -q -b main \
  && printf 'name: sprocket\nreplicas: 2\n' > config.yaml \
  && git add -A && git commit -qm init )

# Write the contract with the script under test — no hand-built fixture anywhere.
RUN=$WRT PHASE_KEY=$PK_BASELINE \
  TEST_CMD='echo ALLPASS' \
  EXTRACTOR="grep '^FAILID ' | awk '{print \$2}'" \
  BUILD_CMD='echo compiled' \
  REGEN_CMD='' \
  bash "$WTC" >/dev/null 2>&1
# And record a rejection, so the readers are exercised on a file that carries the
# audit trail below line 4 — the shape a real run actually has.
RUN=$WRT PHASE_KEY=$PK_BASELINE REJECT='make vet' REASON='compiled zero packages' bash "$WTC" >/dev/null 2>&1
: > "$WRT/test-baseline.failures.txt"
: > "$WRT/classification.tsv"

gate_row() { awk -F'\t' -v c="$2" '$1==c{print $2}' "$1"; }
for pair in postmerge:$PK_STRUCTURAL midplan:$PK_EXECUTION final:$PK_FINALIZE; do
  label=${pair%%:*}; key=${pair#*:}
  ( cd "$WRC" && LABEL="$label" RUN=$WRT SYNTH=$WRS PHASE_KEY="$key" \
      bash "$SKILL_DIR/scripts/gate.sh" > "$SANDBOX/rt-$label.card" 2>/dev/null )
  if [[ "$(gate_row "$SANDBOX/rt-$label.card" build)" = PASS ]]; then
    pass "write-test-commands: gate.sh LABEL=$label reads line 3 as the build command (build PASS)"
  else
    fail "write-test-commands: gate.sh LABEL=$label reads line 3 as the build command (got '$(gate_row "$SANDBOX/rt-$label.card" build)')"
  fi
  if [[ "$(gate_row "$SANDBOX/rt-$label.card" tests)" = PASS ]]; then
    pass "write-test-commands: gate.sh LABEL=$label reads lines 1-2 as command + extractor (tests PASS)"
  else
    fail "write-test-commands: gate.sh LABEL=$label reads lines 1-2 as command + extractor (got '$(gate_row "$SANDBOX/rt-$label.card" tests)')"
  fi
  # Line 4 is the honest placeholder here, so the producer row must read INCOMPLETE
  # (no regeneration command) — never the gate-internal FAIL a drifted line gives.
  if [[ "$(gate_row "$SANDBOX/rt-$label.card" producer-idempotence)" = PASS ]]; then
    pass "write-test-commands: gate.sh LABEL=$label reads line 4's placeholder without a gate-internal FAIL"
  else
    fail "write-test-commands: gate.sh LABEL=$label reads line 4's placeholder (got '$(gate_row "$SANDBOX/rt-$label.card" producer-idempotence)')"
  fi
done

# producer-idempotence.sh reads lines 3 and 4 itself: a real regeneration command
# written by this script must be found and run, not read as a comment.
RUN=$WRT PHASE_KEY=$PK_BASELINE TEST_CMD='echo ALLPASS' \
  EXTRACTOR="grep '^FAILID ' | awk '{print \$2}'" \
  BUILD_CMD='echo compiled' REGEN_CMD='echo regenerated' bash "$WTC" >/dev/null 2>&1
( cd "$WRC" && RUN=$WRT bash "$SKILL_DIR/scripts/producer-idempotence.sh" >/dev/null 2>&1 )
if [[ "$(awk -F'\t' '$1=="regenerate"{print $2}' "$WRT/producer-idempotence.tsv" 2>/dev/null)" = clean ]]; then
  pass "write-test-commands: producer-idempotence.sh reads line 4 as the regeneration command (verdict clean)"
else
  fail "write-test-commands: producer-idempotence.sh reads line 4 as the regeneration command (got '$(awk -F'\t' '$1=="regenerate"{print $2}' "$WRT/producer-idempotence.tsv" 2>/dev/null)')"
fi
if [[ "$(awk -F'\t' '$1=="build"{print $2}' "$WRT/producer-idempotence.tsv" 2>/dev/null)" = clean ]]; then
  pass "write-test-commands: producer-idempotence.sh reads line 3 as the build producer (verdict clean)"
else
  fail "write-test-commands: producer-idempotence.sh reads line 3 as the build producer (got '$(awk -F'\t' '$1=="build"{print $2}' "$WRT/producer-idempotence.tsv" 2>/dev/null)')"
fi
refute "write-test-commands: the rejection comment below line 4 was never read as a producer" \
  grep -qi 'rejected' "$WRT/producer-idempotence.tsv"

fi

if t "write-test-commands.sh — CENSUS writes the sibling census-command.txt in the same call"; then
# This block PINS the interface:
#   CENSUS rides the command-write call into a SIBLING file, $RUN/census-command.txt
#   — never a fifth positional line on test-command.txt (everything below line 4
#   there is the rejection audit trail, read by line count, not by content).
W8=$SANDBOX/w8
RUN=$W8 PHASE_KEY=$PK_BASELINE TEST_CMD='go test -json ./...' EXTRACTOR='jq -r select(.Action=="fail")' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' \
  CENSUS='jq -r "select(.Test) | \"\(.Test)\t\(.Action)\""' \
  bash "$WTC" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "write-test-commands: a call with CENSUS exits 0"; else fail "write-test-commands: a call with CENSUS exits 0 (rc=$rc)"; fi
expect "write-test-commands: \$RUN/census-command.txt is created" test -f "$W8/census-command.txt"
if [[ "$(sed -n 1p "$W8/census-command.txt" 2>/dev/null)" = 'jq -r "select(.Test) | \"\(.Test)\t\(.Action)\""' ]]; then
  pass "write-test-commands: census-command.txt carries the collapsed CENSUS value"
else
  fail "write-test-commands: census-command.txt carries the collapsed CENSUS value (got '$(sed -n 1p "$W8/census-command.txt" 2>/dev/null)')"
fi
if [[ "$(wc -l < "$W8/census-command.txt" | tr -d ' ')" = 1 ]]; then
  pass "write-test-commands: census-command.txt is exactly one line"
else
  fail "write-test-commands: census-command.txt is exactly one line"
fi
# test-command.txt itself is untouched by CENSUS — still the four positional lines.
if [[ "$(wc -l < "$W8/test-command.txt" | tr -d ' ')" = 4 ]]; then
  pass "write-test-commands: test-command.txt stays four lines when CENSUS is also written"
else
  fail "write-test-commands: test-command.txt stays four lines when CENSUS is also written"
fi

fi

if t "write-test-commands.sh — an empty CENSUS becomes the literal 'no census extractor'"; then
# This block PINS the interface:
#   Empty (or unset) CENSUS is as honest an absence as an unset TEST_CMD — it gets
#   the recognised literal, never a blank line a reader could eval as an extractor.
W9=$SANDBOX/w9
RUN=$W9 PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' CENSUS='' \
  bash "$WTC" >/dev/null 2>&1
if [[ "$(sed -n 1p "$W9/census-command.txt" 2>/dev/null)" = 'no census extractor' ]]; then
  pass "write-test-commands: an empty CENSUS becomes the literal 'no census extractor'"
else
  fail "write-test-commands: an empty CENSUS becomes the literal 'no census extractor' (got '$(sed -n 1p "$W9/census-command.txt" 2>/dev/null)')"
fi

# An unset CENSUS behaves identically to an empty one.
W9B=$SANDBOX/w9b
env -u CENSUS RUN=$W9B PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' bash "$WTC" >/dev/null 2>&1
if [[ "$(sed -n 1p "$W9B/census-command.txt" 2>/dev/null)" = 'no census extractor' ]]; then
  pass "write-test-commands: an unset CENSUS also becomes the literal 'no census extractor'"
else
  fail "write-test-commands: an unset CENSUS also becomes the literal 'no census extractor'"
fi

fi

if t "write-test-commands.sh — embedded newlines/tabs in CENSUS collapse to single spaces"; then
# This block PINS the interface:
#   CENSUS is collapsed exactly like the other fields — a discovered census pipeline
#   pasted across two lines, or with a tab, must still land as ONE line so the sibling
#   file's one-line contract holds.
W10=$SANDBOX/w10
RUN=$W10 PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' \
  CENSUS="$(printf 'grep -E census |\n sort\t-u')" \
  bash "$WTC" >/dev/null 2>&1
if [[ "$(wc -l < "$W10/census-command.txt" | tr -d ' ')" = 1 ]]; then
  pass "write-test-commands: a newline/tab-bearing CENSUS still produces exactly one line"
else
  fail "write-test-commands: a newline/tab-bearing CENSUS still produces exactly one line"
fi
if [[ "$(sed -n 1p "$W10/census-command.txt")" = 'grep -E census | sort -u' ]]; then
  pass "write-test-commands: newlines/tabs inside CENSUS collapse to single spaces"
else
  fail "write-test-commands: newlines/tabs inside CENSUS collapse to single spaces (got '$(sed -n 1p "$W10/census-command.txt")')"
fi

fi

if t "write-test-commands.sh — an identical command+census write leaves census-command.txt byte-identical"; then
# This block PINS the interface:
#   Re-run safety extends to the sibling file: Continue mode's re-entry into Phase
#   4.5 must not perturb census-command.txt just because it also rewrites
#   test-command.txt on every pass.
W11=$SANDBOX/w11
for _ in 1 2; do
  RUN=$W11 PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
    BUILD_CMD='go build ./...' REGEN_CMD='make generate' CENSUS='grep -E census' \
    bash "$WTC" >/dev/null 2>&1
done
cp "$W11/census-command.txt" "$SANDBOX/w11.snap"
RUN=$W11 PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' CENSUS='grep -E census' \
  bash "$WTC" >/dev/null 2>&1
expect "write-test-commands: an idempotent re-entry leaves census-command.txt byte-identical" \
  cmp -s "$SANDBOX/w11.snap" "$W11/census-command.txt"

fi

if t "write-test-commands.sh — test-command.txt is byte-identical to a pre-census run when no CENSUS is passed"; then
# This block PINS the interface:
#   The census sibling-file write must not perturb test-command.txt's own bytes for
#   callers that never pass CENSUS at all — the "pre-change" shape (four positional
#   lines, nothing else) is preserved exactly.
W12A=$SANDBOX/w12a
W12B=$SANDBOX/w12b
RUN=$W12A PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' \
  bash "$WTC" >/dev/null 2>&1
env -u CENSUS RUN=$W12B PHASE_KEY=$PK_BASELINE TEST_CMD='go test ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' \
  bash "$WTC" >/dev/null 2>&1
expect "write-test-commands: test-command.txt is byte-identical whether or not CENSUS is passed" \
  cmp -s "$W12A/test-command.txt" "$W12B/test-command.txt"
expect "write-test-commands: a call with no CENSUS still writes census-command.txt with the placeholder literal" \
  grep -qx 'no census extractor' "$W12A/census-command.txt"

fi

# =============================================================================
# Frontend-run discovery (MOUNT set) — PRD "Gate cwd": the mount's default `test`
# script is watch-mode vitest and must never become a gate command.
# =============================================================================

# fe_mount <dir> <package.json body> — a mount with a package.json, plus a root
# Makefile carrying a `test` target, so every case below also proves the root's
# `make test` is never what a frontend run records (it never sees the mount).
fe_mount() {
  mkdir -p "$1/web" "$1/run"
  cat > "$1/web/package.json"
  printf 'test:\n\techo ROOT MAKE TEST\n' > "$1/Makefile"
}
fe_run() { ( cd "$1" && RUN="$1/run" MOUNT="${2:-web/}" PHASE_KEY=$PK_BASELINE bash "$WTC" ) >"$1/out" 2>"$1/err"; FRC=$?; }
fe_line() { sed -n "${2}p" "$1/run/test-command.txt" 2>/dev/null; }

if t "write-test-commands.sh — a frontend run records the CI entry and REJECTS the watch-mode default"; then
# This block PINS the interface:
#   env in : MOUNT (+ RUN, PHASE_KEY) and NOTHING else — lines 1 and 3 are
#            discovered from $MOUNT/package.json.
#   effect : line 1 is the non-interactive CI entry (`test:ci`), line 3 is the
#            mount's build with typecheck JOINED to it, and the package default
#            `test` — watch-mode vitest, the first thing a reader would reach for —
#            leaves a `# rejected:` line below line 4 as evidence it was refused.
#            A gate that ran the watch-mode script would HANG the migration rather
#            than fail it, which is the failure this discovery exists to prevent.
F1=$SANDBOX/fe1
fe_mount "$F1" <<'EOF'
{
  "name": "acme",
  "scripts": {
    "test": "pnpm test:watch",
    "test:watch": "vitest",
    "test:ci": "vitest run",
    "build": "vite build",
    "typecheck": "tsc -b"
  }
}
EOF
fe_run "$F1"
if [[ "$FRC" -eq 0 ]]; then pass "frontend discovery: a MOUNT-only call exits 0"; else fail "frontend discovery: a MOUNT-only call exits 0 (rc=$FRC, err=$(cat "$F1/err"))"; fi
if [[ "$(fe_line "$F1" 1)" = 'pnpm run test:ci' ]]; then pass "frontend discovery: line 1 is the non-interactive CI entry"; else fail "frontend discovery: line 1 is the non-interactive CI entry (got '$(fe_line "$F1" 1)')"; fi
expect "frontend discovery: line 1 is never the watch-mode default" \
  bash -c "! grep -qx 'pnpm run test' '$F1/run/test-command.txt'"
expect "frontend discovery: the root's make test is never recorded" \
  bash -c "! grep -q 'make test' '$F1/run/test-command.txt'"
if [[ "$(fe_line "$F1" 3)" = 'pnpm run build && pnpm run typecheck' ]]; then pass "frontend discovery: line 3 is the mount build with typecheck joined"; else fail "frontend discovery: line 3 is the mount build with typecheck joined (got '$(fe_line "$F1" 3)')"; fi
if [[ "$(fe_line "$F1" 1)" != 'pnpm run typecheck' ]]; then pass "frontend discovery: typecheck never stands in for the tests on line 1"; else fail "frontend discovery: typecheck never stands in for the tests on line 1"; fi
if [[ -n "$(fe_line "$F1" 2)" ]]; then pass "frontend discovery: line 2 carries a failure extractor (a bare line 2 is a gate-internal FAIL)"; else fail "frontend discovery: line 2 carries a failure extractor"; fi
if [[ "$(fe_line "$F1" 4)" = 'no regen command' ]]; then pass "frontend discovery: line 4 is the literal placeholder when the mount declares no generator"; else fail "frontend discovery: line 4 is the literal placeholder when the mount declares no generator (got '$(fe_line "$F1" 4)')"; fi
expect "frontend discovery: the watch-mode default is recorded as a rejection below line 4" \
  bash -c "tail -n +5 '$F1/run/test-command.txt' | grep -q '^# rejected: pnpm run test — '"
expect "frontend discovery: the rejection reason names watch-mode and the hang it would cause" \
  bash -c "tail -n +5 '$F1/run/test-command.txt' | grep -q 'watch-mode' && tail -n +5 '$F1/run/test-command.txt' | grep -q 'hang'"
expect "frontend discovery: the rejection sits strictly BELOW the four positional lines" \
  bash -c "! sed -n '1,4p' '$F1/run/test-command.txt' | grep -q '^# rejected:'"
fi

if t "write-test-commands.sh — a frontend run rejects the watch-mode default even when it is the ONLY test script, and records the vitest run fallback"; then
# This block PINS the interface:
#   With no `test:ci` and no CI-shaped script, the default watch-mode `test` is STILL
#   refused; the run falls back to invoking the runner non-interactively itself,
#   which is only legitimate because the mount declares vitest as a dependency.
F2=$SANDBOX/fe2
fe_mount "$F2" <<'EOF'
{
  "name": "acme",
  "scripts": { "test": "vitest", "build": "vite build" },
  "devDependencies": { "vitest": "^1.6.0" }
}
EOF
fe_run "$F2"
if [[ "$FRC" -eq 0 ]]; then pass "frontend discovery: the fallback path exits 0"; else fail "frontend discovery: the fallback path exits 0 (rc=$FRC, err=$(cat "$F2/err"))"; fi
if [[ "$(fe_line "$F2" 1)" = 'pnpm exec vitest run' ]]; then pass "frontend discovery: the fallback is a non-interactive vitest run"; else fail "frontend discovery: the fallback is a non-interactive vitest run (got '$(fe_line "$F2" 1)')"; fi
expect "frontend discovery: the only test script is still rejected for being watch-mode" \
  bash -c "tail -n +5 '$F2/run/test-command.txt' | grep -q '^# rejected: pnpm run test — '"
if [[ "$(fe_line "$F2" 3)" = 'pnpm run build' ]]; then pass "frontend discovery: line 3 is the mount build when no typecheck script exists"; else fail "frontend discovery: line 3 is the mount build when no typecheck script exists (got '$(fe_line "$F2" 3)')"; fi
fi

if t "write-test-commands.sh — a frontend run FAILS LOUDLY when the mount offers no non-interactive entry at all"; then
# This block PINS the interface:
#   No CI script, no vitest to fall back on: nothing is recorded and the exit is 2.
#   Recording the watch-mode command anyway would hang the first gate; recording the
#   `no tests detected` literal would silently advance a frontend baseline on zero
#   test evidence. So this is a loud stop, and the message names the remedy.
F3=$SANDBOX/fe3
fe_mount "$F3" <<'EOF'
{ "name": "acme", "scripts": { "test": "jest --watch" } }
EOF
fe_run "$F3"
if [[ "$FRC" -eq 2 ]]; then pass "frontend discovery: no non-interactive entry exits 2"; else fail "frontend discovery: no non-interactive entry exits 2 (rc=$FRC)"; fi
expect "frontend discovery: nothing was written on the loud-failure path" \
  bash -c "! test -e '$F3/run/test-command.txt'"
expect "frontend discovery: the failure names test:ci as the remedy" grep -q "test:ci" "$F3/err"
fi

if t "write-test-commands.sh — the default vitest extractor captures an unhandled-rejection failure (not just per-test lines)"; then
# Regression (F12): a vitest suite that exits non-zero PURELY from an unhandled rejection
# prints no per-test FAIL/✗/× line, so a FAIL/✗/×-only extractor matched nothing and the
# gate read a genuine red run as EXTRACTOR_MISMATCH — an uncomparable failure set, so
# red-on-red could not be dispositioned as a pass. The default extractor must also catch
# the rejection header and the `Errors N error` summary so the run yields a comparable id.
FUR=$SANDBOX/fe-unhandled
fe_mount "$FUR" <<'EOF'
{
  "name": "acme",
  "scripts": { "test": "vitest" },
  "devDependencies": { "vitest": "^1.6.0" }
}
EOF
fe_run "$FUR"
EXT=$(fe_line "$FUR" 2)
[[ -n "$EXT" ]] && pass "an extractor was recorded" || fail "an extractor was recorded"
# Sample vitest output for a suite that failed ONLY from an unhandled rejection: no ×/FAIL
# per-test line anywhere, just the rejection banner and the error-count summary.
UNHANDLED=$(printf '%s\n' \
  ' RUN  v1.6.0' \
  '' \
  '⎯⎯⎯⎯⎯⎯⎯⎯ Unhandled Rejection ⎯⎯⎯⎯⎯⎯⎯⎯' \
  'Error: connect ECONNREFUSED' \
  '' \
  ' Test Files  1 failed (1)' \
  '      Tests  no tests' \
  '     Errors  1 error')
UOUT=$(printf '%s\n' "$UNHANDLED" | eval "$EXT")
[[ -n "$UOUT" ]] && pass "the default extractor yields a NON-empty (comparable) set for an unhandled rejection" \
  || fail "the default extractor still matched nothing on an unhandled rejection (EXTRACTOR_MISMATCH survives): EXT=[$EXT]"
# Control 1: a normal per-test failure still extracts (no regression to the FAIL/×/✗ path).
PERTEST=$(printf '%s\n' ' ❯ src/app.test.ts (1)' ' × src/app.test.ts > adds (2)' '   → expected 2 to be 3')
POUT=$(printf '%s\n' "$PERTEST" | eval "$EXT")
[[ -n "$POUT" ]] && pass "a normal per-test × failure is still extracted" || fail "a normal per-test × failure is still extracted"
# Control 2: a clean passing run extracts nothing (no false failure set).
GREEN=$(printf '%s\n' ' ✓ src/app.test.ts (2)' ' Test Files  1 passed (1)' '      Tests  2 passed (2)')
GOUT=$(printf '%s\n' "$GREEN" | eval "$EXT")
[[ -z "$GOUT" ]] && pass "a green run extracts nothing (no invented failures)" || fail "a green run extracted something: [$GOUT]"
fi

if t "write-test-commands.sh — a frontend run refuses hand-passed TEST_CMD/BUILD_CMD, and a mount with no package.json"; then
# This block PINS the interface:
#   MOUNT means "discover"; passing the discovered lines as well is ambiguous about
#   which one wins, so it is refused rather than silently preferred either way.
F4=$SANDBOX/fe4
fe_mount "$F4" <<'EOF'
{ "name": "acme", "scripts": { "test:ci": "vitest run" } }
EOF
( cd "$F4" && RUN="$F4/run" MOUNT=web/ TEST_CMD='make test' EXTRACTOR='grep FAIL' PHASE_KEY=$PK_BASELINE bash "$WTC" ) >/dev/null 2>"$F4/err2"; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "frontend discovery: MOUNT + TEST_CMD is refused"; else fail "frontend discovery: MOUNT + TEST_CMD is refused (rc=$rc)"; fi
expect "frontend discovery: the refusal says discovery owns lines 1 and 3" \
  grep -q 'DISCOVERED' "$F4/err2"
( cd "$F4" && RUN="$F4/run" MOUNT=web/ BUILD_CMD='go build ./...' PHASE_KEY=$PK_BASELINE bash "$WTC" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "frontend discovery: MOUNT + BUILD_CMD is refused"; else fail "frontend discovery: MOUNT + BUILD_CMD is refused (rc=$rc)"; fi
F5=$SANDBOX/fe5
mkdir -p "$F5/web" "$F5/run"
( cd "$F5" && RUN="$F5/run" MOUNT=web/ PHASE_KEY=$PK_BASELINE bash "$WTC" ) >/dev/null 2>"$F5/err"; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "frontend discovery: a mount with no package.json exits 2"; else fail "frontend discovery: a mount with no package.json exits 2 (rc=$rc)"; fi
expect "frontend discovery: the message names package.json and the mount" \
  bash -c "grep -q 'package.json' '$F5/err' && grep -q 'web' '$F5/err'"
fi

if t "write-test-commands.sh — a frontend run honours a declared generator and a caller extractor, and is re-run safe"; then
# This block PINS the interface:
#   A `generate` script becomes line 4 (never invented when absent); a caller-passed
#   EXTRACTOR wins over the default; a second identical call is byte-identical,
#   rejections included — Continue mode re-enters Phase 4.5 and must not restack.
F6=$SANDBOX/fe6
fe_mount "$F6" <<'EOF'
{
  "name": "acme",
  "scripts": { "test": "pnpm test:watch", "test:ci": "vitest run", "build": "vite build", "generate": "openapi-codegen" }
}
EOF
( cd "$F6" && RUN="$F6/run" MOUNT=web/ EXTRACTOR='grep -E "^ FAIL" | sort -u' PHASE_KEY=$PK_BASELINE bash "$WTC" ) >/dev/null 2>&1
if [[ "$(fe_line "$F6" 4)" = 'pnpm run generate' ]]; then pass "frontend discovery: a declared generate script becomes line 4"; else fail "frontend discovery: a declared generate script becomes line 4 (got '$(fe_line "$F6" 4)')"; fi
if [[ "$(fe_line "$F6" 2)" = 'grep -E "^ FAIL" | sort -u' ]]; then pass "frontend discovery: a caller-passed EXTRACTOR is kept verbatim"; else fail "frontend discovery: a caller-passed EXTRACTOR is kept verbatim (got '$(fe_line "$F6" 2)')"; fi
cp "$F6/run/test-command.txt" "$SANDBOX/fe6.snap"
( cd "$F6" && RUN="$F6/run" MOUNT=web/ EXTRACTOR='grep -E "^ FAIL" | sort -u' PHASE_KEY=$PK_BASELINE bash "$WTC" ) >/dev/null 2>&1
expect "frontend discovery: an identical re-run is byte-identical (no restacked rejection)" \
  cmp -s "$SANDBOX/fe6.snap" "$F6/run/test-command.txt"
fi

if t "write-test-commands.sh — a CI-flagged NON-test script is never mistaken for the test suite"; then
# This block PINS the interface:
#   `--ci` / `CI=1` bodies are accepted as non-interactive shapes, so a `lint` or
#   `e2e` script carrying that flag would otherwise be picked up as line 1 and the
#   frontend baseline would advance on LINT evidence. Only test-NAMED scripts are
#   candidates: with no test entry at all this is the same loud stop as fe3, and with
#   vitest installed the fallback runner wins over the CI-flagged non-test script.
F8=$SANDBOX/fe8
fe_mount "$F8" <<'EOF'
{ "name": "acme", "scripts": { "lint": "eslint . --ci", "e2e": "playwright test --ci", "build": "vite build" } }
EOF
fe_run "$F8"
if [[ "$FRC" -eq 2 ]]; then pass "frontend discovery: a CI-flagged lint script is not a test entry (loud stop)"; else fail "frontend discovery: a CI-flagged lint script is not a test entry (rc=$FRC, line1='$(fe_line "$F8" 1)')"; fi
expect "frontend discovery: nothing was written when only non-test scripts are CI-shaped" \
  bash -c "! test -e '$F8/run/test-command.txt'"
F9=$SANDBOX/fe9
fe_mount "$F9" <<'EOF'
{
  "name": "acme",
  "scripts": { "lint": "eslint . --ci", "test": "vitest", "build": "vite build" },
  "devDependencies": { "vitest": "^1.6.0" }
}
EOF
fe_run "$F9"
if [[ "$(fe_line "$F9" 1)" = 'pnpm exec vitest run' ]]; then pass "frontend discovery: the vitest fallback wins over a CI-flagged non-test script"; else fail "frontend discovery: the vitest fallback wins over a CI-flagged non-test script (got '$(fe_line "$F9" 1)')"; fi
expect "frontend discovery: the lint script is never on line 1" \
  bash -c "! grep -qx 'pnpm run lint' '$F9/run/test-command.txt'"
fi

if t "write-test-commands.sh — the template path is byte-identical when MOUNT is unset"; then
# This block PINS the interface:
#   Everything above is gated on MOUNT. With MOUNT unset (or empty) the script is the
#   pure format owner it was before frontend runs existed — the mount is not looked
#   at, no package.json is read, and the four lines are exactly what was passed.
F7A=$SANDBOX/fe7a; F7B=$SANDBOX/fe7b
mkdir -p "$F7A" "$F7B"
RUN=$F7A PHASE_KEY=$PK_BASELINE TEST_CMD='go test -json ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' CENSUS='grep census' bash "$WTC" >/dev/null 2>&1
env -u MOUNT RUN=$F7B PHASE_KEY=$PK_BASELINE TEST_CMD='go test -json ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' CENSUS='grep census' bash "$WTC" >/dev/null 2>&1
expect "template path: test-command.txt is byte-identical whether or not MOUNT is in the environment" \
  cmp -s "$F7A/test-command.txt" "$F7B/test-command.txt"
expect "template path: census-command.txt is byte-identical too" \
  cmp -s "$F7A/census-command.txt" "$F7B/census-command.txt"
# MOUNT set-but-EMPTY is the same as unset: a frontend key that never reached this
# call must not silently turn the run into a mount discovery against `./`.
F7C=$SANDBOX/fe7c; mkdir -p "$F7C"
MOUNT='' RUN=$F7C PHASE_KEY=$PK_BASELINE TEST_CMD='go test -json ./...' EXTRACTOR='grep FAIL' \
  BUILD_CMD='go build ./...' REGEN_CMD='make generate' CENSUS='grep census' bash "$WTC" >/dev/null 2>&1
expect "template path: an empty MOUNT records the passed commands unchanged" \
  cmp -s "$F7A/test-command.txt" "$F7C/test-command.txt"
fi

if t "write-test-commands.sh — the frontend rejection queue never leaks out of \$RUN on the loud-failure path"; then
# S10: the queue is a mktemp in $TMPDIR, created lazily during discovery — and the
# no-CI-entry stop fires AFTER a watch-mode candidate has been queued, so every refused
# run used to leave one unlinked temp file behind. It is the only place this script
# writes outside the run state, which is exactly why it has to clean up after itself.
FQ=$SANDBOX/fe-rejq
FQTMP=$FQ/tmp
mkdir -p "$FQTMP"
fe_mount "$FQ" <<'EOF'
{ "name": "acme", "scripts": { "test": "jest --watch", "test:ci": "jest --watch" } }
EOF
( cd "$FQ" && RUN="$FQ/run" MOUNT=web/ TMPDIR="$FQTMP" PHASE_KEY=$PK_BASELINE bash "$WTC" ) \
  >"$FQ/out" 2>"$FQ/err"; FQ_RC=$?
if [[ "$FQ_RC" -eq 2 ]]; then
  pass "the fixture really takes the loud-failure path (both scripts are watch-mode, no vitest to fall back on)"
else
  fail "the fixture really takes the loud-failure path (rc=$FQ_RC — no jest-only watch fixture, so the queue was never created)"
fi
expect "the failure names test:ci as the remedy (the queued rejections were real)" \
  grep -q 'test:ci' "$FQ/err"
FQ_LEFT=$(find "$FQTMP" -mindepth 1 -print 2>/dev/null | tr '\n' ' ')
if [[ -z "$FQ_LEFT" ]]; then
  pass "no temp file leaked into TMPDIR on the refused run"
else
  fail "temp file(s) leaked into TMPDIR on the refused run: $FQ_LEFT"
fi
expect "and nothing was written under \$RUN either" \
  bash -c "! test -e '$FQ/run/test-command.txt'"

# The SUCCESS path already cleaned up; assert it stays that way, so the fix cannot be
# read as "cleanup happens only on failure".
FQ2=$SANDBOX/fe-rejq-ok
FQ2TMP=$FQ2/tmp
mkdir -p "$FQ2TMP"
fe_mount "$FQ2" <<'EOF'
{ "name": "acme", "scripts": { "test": "vitest", "test:ci": "vitest run" } }
EOF
( cd "$FQ2" && RUN="$FQ2/run" MOUNT=web/ TMPDIR="$FQ2TMP" PHASE_KEY=$PK_BASELINE bash "$WTC" ) \
  >/dev/null 2>&1; FQ2_RC=$?
expect "the successful frontend discovery exits 0" test "$FQ2_RC" -eq 0
expect "the watch-mode default still left its rejection line in the artifact" \
  grep -q '# rejected:' "$FQ2/run/test-command.txt"
FQ2_LEFT=$(find "$FQ2TMP" -mindepth 1 -print 2>/dev/null | tr '\n' ' ')
if [[ -z "$FQ2_LEFT" ]]; then
  pass "no temp file left in TMPDIR after a successful run either"
else
  fail "temp file(s) left in TMPDIR after a successful run: $FQ2_LEFT"
fi
fi

finish_suite
