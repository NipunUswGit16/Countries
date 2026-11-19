#!/usr/bin/env bash
# skill-lint.test.sh — static/packaging checks (not about a single script).
# Covers spawn-by-path, genericity containment, gate wiring docs, continue.md
# budget= degradation, SKILL.md model/spawn wiring, PLAN.md Flag contract,
# phase-index stub-lint, phase-key enforcement, the architecture-doc runtime
# boundary, and the recurrence lints (bucket ownership, artifact-writer coverage,
# $RUN-artifact indexing, placeholder quoting in runnable bash blocks, record
# writes going through printf) — the greps that found the largest seam defects,
# promoted from reviewer attention to red tests.
#
# Plus the fixed-once lints: a defect class fixed once is not fixed until it is
# swept AND linted — the ambient-locale comm, the unsanitized ledger field and the
# loose plan-task anchor were each the one instance their class's earlier fix
# missed. And the Phase 8 ordering lints, because that sequence is prose.
#
# The two bash-hygiene lints at the end each carry a quoting-aware awk scanner
# rather than a grep, because in both classes the hazard and the legal form differ
# only in quote state. Both are proven twice — an exclusion fixture pinned by line
# number, and a mutation planted in a real file of the tree.
# TEST_FILTER supported (blocks are independent).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

if t "spawn-by-path packaging check (no role-file pasting)"; then
# The paste form ("<contents of agents/executor.md>\n\n...") duplicates 5-8KB of
# role prose into orchestrator history per spawn — a 15-task migration with
# several conflicted files repeats this dozens of times for no benefit, since a
# subagent can read a path itself. This must never come back.
refute "no spawn instruction pastes an agents/*.md body into the prompt" \
  grep -qE 'contents of (\$SKILL_DIR/)?agents/[A-Za-z0-9_-]+\.md' "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/phases/*.md

MISSING_AGENT_PATHS=0
for p in $(grep -ohE '(\$SKILL_DIR/)?agents/[A-Za-z0-9_-]+\.md' "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/phases/*.md | sed 's#^\$SKILL_DIR/##' | sort -u); do
  [[ -f "$SKILL_DIR/$p" ]] || MISSING_AGENT_PATHS=$((MISSING_AGENT_PATHS + 1))
done
if [[ "$MISSING_AGENT_PATHS" -eq 0 ]]; then
  pass "every agents/*.md path named in SKILL.md + phases/ resolves to an existing file"
else
  fail "$MISSING_AGENT_PATHS agent path(s) named in SKILL.md + phases/ do not resolve to an existing file"
fi

expect "executor subagent spawn tells the subagent to read its role file by path" \
  grep -qiE 'read[^.]*agents/executor\.md' "$SKILL_DIR/phases/7-execution.md"
expect "conflict-resolver subagent spawn tells the subagent to read its role file by path" \
  grep -qiE 'read[^.]*agents/conflict-resolver\.md' "$SKILL_DIR/phases/5-structural.md"

fi

if t "genericity containment — no fixture identifier leaks into the skill"; then
# The cheap mechanical guard on the PRD's genericity constraint: every detector
# added by the merge-correctness work must derive its expectations from a tree or
# artifact the run materializes, never from a hardcoded list of names. A detector
# quietly keyed to a real key/path/symbol would fail to fire on the INVENTED
# fixture names below (nobody ships them), so its own test would go red — but a
# hardcoded literal in a script/reference/agent would ALSO show up here. This keeps
# genericity a test outcome, not a review opinion. It lives in this suite (not
# tools/lint-skills) because it keys off THIS work's fixture vocabulary.
# Comments are scanned too, and deliberately so: a rationale comment reaching for a
# fixture name as its example is the first step of the leak this lint exists to
# stop, and a neutral placeholder (`"…/<removed-dir>"`) says the same thing.
GENERIC_IDS="sprocket flangebox frobnicator frobnitz wibble wobble gearbox"
LEAKED=""
for id in $GENERIC_IDS; do
  if grep -rIq -- "$id" "$SKILL_DIR/scripts" "$SKILL_DIR/reference" "$SKILL_DIR/agents" 2>/dev/null; then
    LEAKED="$LEAKED $id"
  fi
done
if [[ -z "$LEAKED" ]]; then
  pass "no merge-correctness fixture identifier appears under scripts/ reference/ agents/"
else
  fail "fixture identifier(s) leaked into the skill (hardcoded literal):$LEAKED"
fi
fi

if t "gate wiring — phases run the gate; the card-interpretation contract lives in reference/gate-cards.md"; then
expect "phases/5-structural.md runs scripts/gate.sh" grep -qF 'scripts/gate.sh' "$SKILL_DIR/phases/5-structural.md"
expect "phases/8-finalize.md runs scripts/gate.sh" grep -qF 'scripts/gate.sh' "$SKILL_DIR/phases/8-finalize.md"
refute "phase 5 no longer sequences run-check-modules.sh itself" \
  grep -q 'run-check-modules' "$SKILL_DIR/phases/5-structural.md"
refute "phase 8 no longer sequences run-check-modules.sh itself" \
  grep -q 'run-check-modules' "$SKILL_DIR/phases/8-finalize.md"
expect "reference/gates.md documents the card and its AGGREGATE line" \
  grep -qF 'AGGREGATE' "$SKILL_DIR/reference/gates.md"
expect "reference/gate-cards.md carries the red-on-red rule (the card-interpretation contract's home)" \
  bash -c "grep -qi 'red-on-red' '$SKILL_DIR/reference/gate-cards.md'"
# review-2026-08-25-round3 M4: gate-cards.md is a load-and-act exception (SKILL.md:25),
# so the act-on-gate sites must tell the reader to READ it before acting — a bare
# parenthetical citation means "do not load" under the load contract, which would
# leave the interpretation contract unread at the exact sites that need it. The
# contract itself must name the carve-out so the bare-is-a-pointer rule cannot
# silently demote a declared load-and-act exception.
expect "phases/5 directs reading the interpretation contract before acting on a non-PASS row" \
  grep -qF 'interpretation contract before acting' "$SKILL_DIR/phases/5-structural.md"
expect "phases/8 directs reading the interpretation contract before acting on a non-PASS row" \
  grep -qF 'interpretation contract before acting' "$SKILL_DIR/phases/8-finalize.md"
expect "SKILL.md's load contract carves out the load-and-act exceptions" \
  grep -qF 'load-and-act exception' "$SKILL_DIR/SKILL.md"
expect "reference/gates.md carries the extractor-silence rule" \
  bash -c "grep -qi 'silence' '$SKILL_DIR/reference/gates.md'"
expect "reference/gates.md carries the incomplete-coverage rule" \
  bash -c "grep -qi 'incomplete semantic coverage' '$SKILL_DIR/reference/gates.md'"
expect "reference/gates.md carries the setext-underline caveat for the marker scan" \
  bash -c "grep -qi 'setext' '$SKILL_DIR/reference/gates.md'"
expect "phases/1-preflight.md drives scripts/clone-common.sh" \
  grep -qF 'clone-common.sh' "$SKILL_DIR/phases/1-preflight.md"
expect "phases/4-migration-branch.md drives scripts/suggest-branch.sh" \
  grep -qF 'suggest-branch.sh' "$SKILL_DIR/phases/4-migration-branch.md"
expect "phases/5-structural.md drives scripts/apply-ask-user.sh" \
  grep -qF 'apply-ask-user.sh' "$SKILL_DIR/phases/5-structural.md"
expect "phases/3.5-collect-common.md drives scripts/wrong-target-check.sh" \
  grep -qF 'wrong-target-check.sh' "$SKILL_DIR/phases/3.5-collect-common.md"
expect "phases/8-finalize.md drives scripts/template-parity.sh" \
  grep -qF 'template-parity.sh' "$SKILL_DIR/phases/8-finalize.md"
fi

if t "continue.md's postmerge Decide arm reads the gate AGGREGATE, not merely the card's presence"; then
# review-2026-08-25-round3 M2: gate.sh writes gate-postmerge.tsv on EVERY completed
# run (AGGREGATE may be FAIL/NEEDS-INPUT/PASS). A resume that keyed only on the
# card's presence would treat a completed-but-FAILED postmerge gate as satisfied and
# skip the postmerge-only ask-user / replace-directive re-disposition for good.
expect "the Decide arm reads the disposition off the card, not merely its presence" \
  grep -qF 'not merely its presence' "$SKILL_DIR/reference/continue.md"
expect "the Decide arm routes a non-PASS AGGREGATE back into step 9's disposition" \
  grep -qF 'AGGREGATE' "$SKILL_DIR/reference/continue.md"
fi

if t "SKILL.md description covers continue/resume/abort triggering (fresh-session match)"; then
# phases/7-execution.md and reference/continue.md both tell the user to say
# "continue" in a FRESH session, where the description is the only thing that
# can match — this is the only mechanical check available for that triggering
# fix (a trigger-eval harness is out of scope).
DESC=$(awk -F': ' '/^description:/{ $1=""; print substr($0,2) }' "$SKILL_DIR/SKILL.md")
expect "description mentions continue" grep -qiF 'continue' <(printf '%s' "$DESC")
expect "description mentions resume" grep -qiF 'resume' <(printf '%s' "$DESC")
expect "description mentions abort" grep -qiF 'abort' <(printf '%s' "$DESC")
expect "description keeps the update/migrate/upgrade first sentence intact" \
  grep -qiE 'update, migrate, or upgrade' <(printf '%s' "$DESC")
fi

if t "continue.md documents the budget= degradation to balanced"; then
expect "continue.md: a keyed model.txt without a budget= line degrades to balanced" \
  grep -qiE 'budget=.*degrad.*balanced' "$SKILL_DIR/reference/continue.md"
fi

if t "SKILL.md wires model-resolution + spawn-accounting (structural)"; then
# Survive Model-selection rewording: assert wiring and pins, not exact phrases.
# Pure exact-phrase greps (e.g. 'budget frugal|balanced|thorough') deleted —
# they break when prose is slimmed without behavior changing.
expect "SKILL.md drives scripts/resolve-models.sh" grep -qF 'scripts/resolve-models.sh' "$SKILL_DIR/SKILL.md"
expect "SKILL.md reads \$RUN/model.txt pins" grep -qF '$RUN/model.txt' "$SKILL_DIR/SKILL.md"
expect "SKILL.md names the strong= pin" grep -qF 'strong=' "$SKILL_DIR/SKILL.md"
expect "SKILL.md names the coder= pin" grep -qF 'coder=' "$SKILL_DIR/SKILL.md"
expect "SKILL.md names the executor= pin" grep -qF 'executor=' "$SKILL_DIR/SKILL.md"
expect "SKILL.md names the budget= pin" grep -qF 'budget=' "$SKILL_DIR/SKILL.md"
expect "SKILL.md documents the ~/.kairos/models.yaml answers file" grep -qF '~/.kairos/models.yaml' "$SKILL_DIR/SKILL.md"
expect "SKILL.md wires scripts/log-spawn.sh" grep -qF 'scripts/log-spawn.sh' "$SKILL_DIR/SKILL.md"
expect "SKILL.md wires the \$RUN/spawns.tsv ledger" grep -qF '$RUN/spawns.tsv' "$SKILL_DIR/SKILL.md"
expect "SKILL.md runs scripts/spawn-summary.sh at Phase 8" grep -qF 'scripts/spawn-summary.sh' "$SKILL_DIR/SKILL.md"
expect "SKILL.md mentions the first-spawn actual-model probe" grep -qiF 'model it believes it is' "$SKILL_DIR/SKILL.md"
# The probe's detailed MECHANICS were demoted out of the always-resident file into
# reference/model-resolution.md; SKILL.md keeps only the conceptual mention + pointer. Pin
# the new home so the mechanics cannot vanish in the move, and SKILL.md's pointer with it.
expect "SKILL.md points the probe mechanics at reference/model-resolution.md" \
  bash -c "grep -F 'actual-model probe' '$SKILL_DIR/SKILL.md' | grep -qF 'reference/model-resolution.md'"
expect "reference/model-resolution.md carries the actual-model probe mechanics (ACTUAL_MODEL + actual_model column)" \
  bash -c "grep -qF 'ACTUAL_MODEL' '$SKILL_DIR/reference/model-resolution.md' && grep -qF 'actual_model' '$SKILL_DIR/reference/model-resolution.md' && grep -qiF 'model it believes it is' '$SKILL_DIR/reference/model-resolution.md'"

# Every scripts/*.sh path named in SKILL.md or a phase file must resolve to an existing file.
MISSING_SCRIPT_PATHS=0
for p in $(grep -ohE 'scripts/[A-Za-z0-9_-]+\.sh' "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/phases/*.md | sort -u); do
  [[ -f "$SKILL_DIR/$p" ]] || MISSING_SCRIPT_PATHS=$((MISSING_SCRIPT_PATHS + 1))
done
if [[ "$MISSING_SCRIPT_PATHS" -eq 0 ]]; then
  pass "every scripts/*.sh path in SKILL.md + phases/ resolves to a file"
else
  fail "$MISSING_SCRIPT_PATHS scripts/*.sh path(s) in SKILL.md + phases/ do not resolve to a file"
fi

# =============================================================================
fi

if t "SKILL.md carries the 'Speaking to the user' contract (plain-language pins)"; then
# The skill's questions/refusals used to leak internal vocabulary (unresolvable
# module, in_progress block, BASE..TARGET) to component owners who do not know the
# internals. The contract makes plain-language translation a standing rule; pin its
# presence and its load-bearing parts so a reword cannot quietly drop it. Assert the
# wiring, not exact sentences — but the translation table's job IS specific pairs, so
# a couple of those are pinned by their user-facing phrasing.
expect "SKILL.md has the 'Speaking to the user' section" \
  grep -qF '## Speaking to the user' "$SKILL_DIR/SKILL.md"
expect "the contract frames the audience as a component owner without internals knowledge" \
  bash -c "grep -qiF 'component owner' '$SKILL_DIR/SKILL.md'"
expect "the contract says translate every question, not read it aloud" \
  bash -c "grep -qiF 'translate every one' '$SKILL_DIR/SKILL.md'"
expect "the translation table maps 'unresolvable' to plain language" \
  bash -c "grep -qiF \"couldn't work out which of that library\" '$SKILL_DIR/SKILL.md'"
expect "the translation table maps continue/abort to plain language" \
  bash -c "grep -qiF 'pick up where it left off' '$SKILL_DIR/SKILL.md'"
# The two worst-offender prompts model the contract in place — pin that they point
# back to it, so the exemplars and the rule cannot drift apart.
expect "Phase 3.5's shared-library question cites the contract" \
  bash -c "grep -qF 'Speaking to the user' '$SKILL_DIR/phases/3.5-collect-common.md'"
expect "the planner's grill-me Q&A cites the contract" \
  bash -c "grep -qF 'Speaking to the user' '$SKILL_DIR/agents/planner.md'"
# =============================================================================
fi

if t "PLAN.md Flag field is the recorded per-task model-routing signal"; then
# Closes the under-spec: Phase 7 used to claim "recorded signals" the plan schema
# never carried. Flag is optional (omit for routine); when set, executor→coder and
# verifier→strong.
expect "planner task schema declares a Flag field" \
  grep -qE '\*\*Flag\*\*' "$SKILL_DIR/agents/planner.md"
expect "planner Flag values include hand-woven|coverage-blind|complex" \
  grep -qE 'hand-woven \| coverage-blind \| complex' "$SKILL_DIR/agents/planner.md"

# Phase 7 must read the plan's Flag *field* (not the word "flagged") and route
# off it. Match **Flag** / `Flag` / Flag: — never bare "flagged".
PHASE7=$(cat "$SKILL_DIR/phases/7-execution.md")
flag_field() { printf '%s\n' "$PHASE7" | grep -E '\*\*Flag\*\*|`Flag`|[[:space:]]Flag:'; }
if flag_field >/dev/null; then
  pass "Phase 7 reads the recorded Flag field"
else
  fail "Phase 7 reads the recorded Flag field"
fi
# Flagged task → coder executor + strong verifier (same Flag-bearing lines)
if flag_field | grep -q 'CODER_MODEL' && flag_field | grep -q 'STRONG_MODEL'; then
  pass "Phase 7: Flag routes executor to coder and verifier to strong"
else
  fail "Phase 7: Flag routes executor to coder and verifier to strong"
fi
# Routine (no Flag) → executor tier — require Flag-absence language, not bare "routine"
if printf '%s\n' "$PHASE7" | grep -qE 'EXECUTOR_MODEL' \
  && printf '%s\n' "$PHASE7" | grep -qiE 'no Flag|without Flag|Flag (is )?(absent|unset|omitted)|Flag is omitted|omit.*Flag'; then
  pass "Phase 7: routine (no Flag) routes to executor"
else
  fail "Phase 7: routine (no Flag) routes to executor"
fi

# =============================================================================
fi

if t "SKILL.md phase index stubs are not executable (stub-lint)"; then
# The index's one job is to force the load: a stub carrying a command, a $RUN/
# artifact path, a flag name, or a phase key would let an orchestrator improvise
# the phase without reading its file. Non-vacuity first — an empty extraction
# must fail the test, never pass it.
awk '/^## Phase index$/{f=1} /^## / && !/^## Phase index$/{f=0} f' "$SKILL_DIR/SKILL.md" \
  > "$SANDBOX/phase-index.txt"
if [[ -s "$SANDBOX/phase-index.txt" ]]; then
  pass "SKILL.md has a '## Phase index' section"
else
  fail "SKILL.md has a '## Phase index' section"
fi
expect "the load rule is stated above the stubs" \
  grep -qF 'the file is the phase' "$SANDBOX/phase-index.txt"

# Every phases/*.md file on disk is named in the index (a phase without a stub
# is unreachable; a stub without a file is checked by the loop after it).
PIDX_MISSING=0
for f in "$SKILL_DIR"/phases/*.md; do
  grep -qF "phases/$(basename "$f")" "$SANDBOX/phase-index.txt" || PIDX_MISSING=$((PIDX_MISSING + 1))
done
if [[ "$PIDX_MISSING" -eq 0 ]]; then
  pass "every phases/*.md file is named in the index"
else
  fail "$PIDX_MISSING phases/*.md file(s) are missing from the index"
fi
PIDX_BROKEN=0
for p in $(grep -oE 'phases/[A-Za-z0-9._-]+\.md' "$SANDBOX/phase-index.txt" | sort -u); do
  [[ -f "$SKILL_DIR/$p" ]] || PIDX_BROKEN=$((PIDX_BROKEN + 1))
done
if [[ "$PIDX_BROKEN" -eq 0 ]]; then
  pass "every phases/*.md path named in the index resolves to a file"
else
  fail "$PIDX_BROKEN phases/*.md path(s) in the index do not resolve to a file"
fi

refute "no fenced code block in the phase index" grep -q '^```' "$SANDBOX/phase-index.txt"
refute "no \$RUN/ artifact path in the phase index" grep -qF '$RUN/' "$SANDBOX/phase-index.txt"
refute "no PHASE_KEY in the phase index" grep -q 'PHASE_KEY' "$SANDBOX/phase-index.txt"
refute "no --flag name in the phase index" grep -qE -- '--[a-z]' "$SANDBOX/phase-index.txt"

fi

if t "phase keys — entry scripts stop until their phase file is loaded"; then
# Each keyed script's key is stated ONLY in its phase file; the guard converts a
# skipped load into a stop ('FAIL: load phases/<n>-….md first') instead of a
# phase improvised from the index stub. The fixture runs above already prove
# every keyed script runs normally WITH its correct key — here we pin the two
# refusal legs, guard passage on the correct key, and the key bookkeeping
# (8 chars, stated in exactly one phase file, matching its script, all unique).
# Scrub the suite's exported fixture env so the correct-key leg fails on missing
# env right after the guard instead of doing real work.
PK_SCRUB="env -u RUN -u CACHE -u BASE -u TARGET -u SYNTH -u MODE -u TEMPLATE_PATH
          -u TEMPLATE_REPO -u TEMPLATE_GOMOD -u COMPONENT_GOMOD -u COMMON_REPO_PATH -u COMMON_CACHE"
PK_PAIRS="1-preflight.md:pre-flight.sh
1.5-model-resolution.md:resolve-models.sh
2-resolve-target.md:scope-check.sh
2-resolve-target.md:bellwether-detect.sh
2-resolve-target.md:resolve-component-name.sh
2.5-materialize.md:materialize.sh
2.5-materialize.md:materialize-frontend.sh
3-classify.md:build-manifest.sh
3.5-collect-common.md:collect-common.sh
3.5-collect-common.md:extract-template-gomod.sh
4-migration-branch.md:suggest-branch.sh
4-migration-branch.md:ensure-state-ignored.sh
4-migration-branch.md:in-progress.sh
4.5-test-baseline.md:write-test-commands.sh
5-structural.md:structural-merge.sh
5-structural.md:gate.sh
6-planning.md:handoff-structural.sh"
PK_DIR=$SANDBOX/pk-neutral && mkdir -p "$PK_DIR"   # neutral cwd: refusal fires before any tree access
for pair in $PK_PAIRS; do
  pf=${pair%%:*}; sc=${pair##*:}
  key=$(phase_key "$pf")
  # Per-script neutral dir: ensure-state-ignored.sh succeeds under its correct
  # key even here (it writes a .gitignore into cwd), so a shared dir would stop
  # being pristine for the pairs after it.
  PD="$PK_DIR/$sc" && mkdir -p "$PD"
  if printf '%s' "$key" | grep -qE '^[A-Za-z0-9]{8}$'; then
    pass "phases/$pf states an 8-char PHASE_KEY"
  else
    fail "phases/$pf states an 8-char PHASE_KEY (got '${key:-<none>}')"
  fi
  KC=$(grep -lF "$key" "$SKILL_DIR"/phases/*.md 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$KC" = 1 ]]; then
    pass "key for $sc is stated only in phases/$pf"
  else
    fail "key for $sc appears in $KC phase file(s) (want exactly 1)"
  fi
  expect "scripts/$sc embeds that same key (file and guard cannot drift)" \
    grep -qF "$key" "$SKILL_DIR/scripts/$sc"

  ( cd "$PD" && $PK_SCRUB -u PHASE_KEY "$SKILL_DIR/scripts/$sc" ) \
    > /dev/null 2> "$SANDBOX/pk-absent.log"; rc=$?
  if [[ "$rc" -ne 0 ]] && grep -qF "FAIL: load phases/$pf first" "$SANDBOX/pk-absent.log"; then
    pass "$sc without PHASE_KEY exits non-zero: load phases/$pf first"
  else
    fail "$sc without PHASE_KEY exits non-zero: load phases/$pf first (rc=$rc)"
  fi
  ( cd "$PD" && $PK_SCRUB PHASE_KEY=not-the-key "$SKILL_DIR/scripts/$sc" ) \
    > /dev/null 2> "$SANDBOX/pk-wrong.log"; rc=$?
  if [[ "$rc" -ne 0 ]] && grep -qF "FAIL: load phases/$pf first" "$SANDBOX/pk-wrong.log"; then
    pass "$sc with a wrong PHASE_KEY exits non-zero: load phases/$pf first"
  else
    fail "$sc with a wrong PHASE_KEY exits non-zero: load phases/$pf first (rc=$rc)"
  fi
  ( cd "$PD" && $PK_SCRUB PHASE_KEY="$key" "$SKILL_DIR/scripts/$sc" ) \
    > /dev/null 2> "$SANDBOX/pk-right.log" || true
  refute "$sc with the correct key gets past the load guard" \
    grep -q 'load phases/' "$SANDBOX/pk-right.log"
done

# gate.sh serves two phases (5 postmerge, 8 final): it accepts EITHER phase's
# key, and its refusal names the phase file for the label being attempted.
if printf '%s' "$PK_FINALIZE" | grep -qE '^[A-Za-z0-9]{8}$'; then
  pass "phases/8-finalize.md states an 8-char PHASE_KEY"
else
  fail "phases/8-finalize.md states an 8-char PHASE_KEY (got '${PK_FINALIZE:-<none>}')"
fi
PK_FIN_COUNT=$(grep -lF "$PK_FINALIZE" "$SKILL_DIR"/phases/*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$PK_FIN_COUNT" = 1 ]]; then
  pass "the finalize key is stated only in phases/8-finalize.md"
else
  fail "the finalize key appears in $PK_FIN_COUNT phase file(s) (want exactly 1)"
fi
expect "scripts/gate.sh embeds the phase-8 key" grep -qF "$PK_FINALIZE" "$SKILL_DIR/scripts/gate.sh"
( cd "$PK_DIR" && $PK_SCRUB -u PHASE_KEY LABEL=final "$SKILL_DIR/scripts/gate.sh" ) \
  > /dev/null 2> "$SANDBOX/pk-gate-final.log"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF "FAIL: load phases/8-finalize.md first" "$SANDBOX/pk-gate-final.log"; then
  pass "gate.sh under LABEL=final without PHASE_KEY says: load phases/8-finalize.md first"
else
  fail "gate.sh under LABEL=final without PHASE_KEY says: load phases/8-finalize.md first (rc=$rc)"
fi
( cd "$PK_DIR" && $PK_SCRUB PHASE_KEY=not-the-key LABEL=final "$SKILL_DIR/scripts/gate.sh" ) \
  > /dev/null 2> "$SANDBOX/pk-gate-wrong.log"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF "FAIL: load phases/8-finalize.md first" "$SANDBOX/pk-gate-wrong.log"; then
  pass "gate.sh with a wrong PHASE_KEY exits non-zero: load phases/8-finalize.md first"
else
  fail "gate.sh with a wrong PHASE_KEY exits non-zero: load phases/8-finalize.md first (rc=$rc)"
fi
( cd "$PK_DIR" && $PK_SCRUB PHASE_KEY="$PK_FINALIZE" LABEL=final "$SKILL_DIR/scripts/gate.sh" ) \
  > /dev/null 2> "$SANDBOX/pk-gate-fin-ok.log" || true
refute "gate.sh with the finalize key gets past the load guard" \
  grep -q 'load phases/' "$SANDBOX/pk-gate-fin-ok.log"
( cd "$PK_DIR" && $PK_SCRUB PHASE_KEY="$PK_STRUCTURAL" LABEL=final "$SKILL_DIR/scripts/gate.sh" ) \
  > /dev/null 2> "$SANDBOX/pk-gate-cross1.log" || true
refute "gate.sh accepts the phase-5 key under LABEL=final (one gate, two call sites)" \
  grep -q 'load phases/' "$SANDBOX/pk-gate-cross1.log"
( cd "$PK_DIR" && $PK_SCRUB PHASE_KEY="$PK_FINALIZE" LABEL=postmerge "$SKILL_DIR/scripts/gate.sh" ) \
  > /dev/null 2> "$SANDBOX/pk-gate-cross2.log" || true
refute "gate.sh accepts the phase-8 key under LABEL=postmerge" \
  grep -q 'load phases/' "$SANDBOX/pk-gate-cross2.log"

# reference/gates.md's "PHASE_KEY proof-of-load" section RESTATES the three
# phase keys as literals. Unlike the phase files (pinned to the scripts above),
# that prose has no other correspondence check — so pin its copies to the
# phase-file-derived keys here. If a key is ever rotated, the phase file and its
# script move together under the checks above while gates.md would silently go
# stale; these assertions turn that into a lint failure that forces the update.
# (gates.md is a reference doc, not a phase file, so restating here does not
# violate the "stated only in that phase file" rule the phase-file checks pin.)
GATES_MD="$SKILL_DIR/reference/gates.md"
expect "reference/gates.md restates the phase-5 key (proof-of-load section stays in sync)" \
  grep -qF "$PK_STRUCTURAL" "$GATES_MD"
expect "reference/gates.md restates the phase-7 key (proof-of-load section stays in sync)" \
  grep -qF "$PK_EXECUTION" "$GATES_MD"
expect "reference/gates.md restates the phase-8 key (proof-of-load section stays in sync)" \
  grep -qF "$PK_FINALIZE" "$GATES_MD"

# --- Phase 4.5 key: run-check-modules.sh guards ONLY the baseline call site ---
# The baseline capture (OUT=$RUN/test-baseline) is the one place this script is
# a phase entry point; gate.sh's internal build-<label>/test-<label> invocations
# must stay keyless so the guard can never break the gate.
if printf '%s' "$PK_BASELINE" | grep -qE '^[A-Za-z0-9]{8}$'; then
  pass "phases/4.5-test-baseline.md states an 8-char PHASE_KEY"
else
  fail "phases/4.5-test-baseline.md states an 8-char PHASE_KEY (got '${PK_BASELINE:-<none>}')"
fi
PK_BL_COUNT=$(grep -lF "$PK_BASELINE" "$SKILL_DIR"/phases/*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$PK_BL_COUNT" = 1 ]]; then
  pass "the baseline key is stated only in phases/4.5-test-baseline.md"
else
  fail "the baseline key appears in $PK_BL_COUNT phase file(s) (want exactly 1)"
fi
expect "scripts/run-check-modules.sh embeds the baseline key" \
  grep -qF "$PK_BASELINE" "$SKILL_DIR/scripts/run-check-modules.sh"

RCMB=$SANDBOX/rcm-baseline-key
mkdir -p "$RCMB/run" && cd "$RCMB"
CHECK=test CMD='echo suite ran' OUT="$RCMB/run/test-baseline" \
  "$SKILL_DIR/scripts/run-check-modules.sh" > /dev/null 2> "$SANDBOX/rcm-nokey.log"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/4.5-test-baseline.md first' "$SANDBOX/rcm-nokey.log"; then
  pass "run-check-modules.sh on a baseline OUT without PHASE_KEY exits non-zero: load phases/4.5-test-baseline.md first"
else
  fail "run-check-modules.sh on a baseline OUT without PHASE_KEY exits non-zero: load phases/4.5-test-baseline.md first (rc=$rc)"
fi
refute "the refused baseline run wrote no status artifact" test -e "$RCMB/run/test-baseline.status"
CHECK=test CMD='echo suite ran' OUT="$RCMB/run/test-baseline" PHASE_KEY=not-the-key \
  "$SKILL_DIR/scripts/run-check-modules.sh" > /dev/null 2> "$SANDBOX/rcm-wrongkey.log"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/4.5-test-baseline.md first' "$SANDBOX/rcm-wrongkey.log"; then
  pass "run-check-modules.sh on a baseline OUT with a wrong PHASE_KEY exits non-zero"
else
  fail "run-check-modules.sh on a baseline OUT with a wrong PHASE_KEY exits non-zero (rc=$rc)"
fi
CHECK=test CMD='echo suite ran' OUT="$RCMB/run/test-baseline" PHASE_KEY=$PK_BASELINE \
  "$SKILL_DIR/scripts/run-check-modules.sh" > /dev/null 2> "$SANDBOX/rcm-rightkey.log"; rc=$?
refute "run-check-modules.sh with the baseline key gets past the load guard" \
  grep -q 'load phases/' "$SANDBOX/rcm-rightkey.log"
expect "run-check-modules.sh with the baseline key runs the check (exit 0, status written)" \
  bash -c "[ $rc -eq 0 ] && test -f '$RCMB/run/test-baseline.status'"
# Any other OUT — the gate's internal stems included — needs no key at all.
CHECK=build CMD='echo compiled' OUT="$RCMB/run/build-postmerge" \
  "$SKILL_DIR/scripts/run-check-modules.sh" > /dev/null 2> "$SANDBOX/rcm-gatestem.log"; rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q 'load phases/' "$SANDBOX/rcm-gatestem.log"; then
  pass "a non-baseline OUT (gate-internal stem) runs keyless — the gate never breaks"
else
  fail "a non-baseline OUT (gate-internal stem) runs keyless — the gate never breaks (rc=$rc)"
fi
CHECK=test CMD='echo suite ran' OUT="$RCMB/run/test-midplan" \
  "$SKILL_DIR/scripts/run-check-modules.sh" > /dev/null 2> "$SANDBOX/rcm-midstem.log"; rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q 'load phases/' "$SANDBOX/rcm-midstem.log"; then
  pass "the midplan gate stem (test-midplan) also runs keyless"
else
  fail "the midplan gate stem (test-midplan) also runs keyless (rc=$rc)"
fi
cd "$SANDBOX"

# --- Phase 7 key: log-spawn.sh requires the key of the DISPATCHING phase ------
# PHASE=5 dispatches (conflict resolvers) prove phases/5-structural.md was
# loaded; PHASE=7 dispatches (executors/verifiers) prove phases/7-execution.md.
if printf '%s' "$PK_EXECUTION" | grep -qE '^[A-Za-z0-9]{8}$'; then
  pass "phases/7-execution.md states an 8-char PHASE_KEY"
else
  fail "phases/7-execution.md states an 8-char PHASE_KEY (got '${PK_EXECUTION:-<none>}')"
fi
PK_EX_COUNT=$(grep -lF "$PK_EXECUTION" "$SKILL_DIR"/phases/*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$PK_EX_COUNT" = 1 ]]; then
  pass "the execution key is stated only in phases/7-execution.md"
else
  fail "the execution key appears in $PK_EX_COUNT phase file(s) (want exactly 1)"
fi
expect "scripts/log-spawn.sh embeds the execution key" \
  grep -qF "$PK_EXECUTION" "$SKILL_DIR/scripts/log-spawn.sh"
expect "scripts/gate.sh embeds the execution key (midplan call site)" \
  grep -qF "$PK_EXECUTION" "$SKILL_DIR/scripts/gate.sh"
expect "scripts/log-spawn.sh embeds the structural key (PHASE=5 dispatches)" \
  grep -qF "$PK_STRUCTURAL" "$SKILL_DIR/scripts/log-spawn.sh"

LSK=$SANDBOX/ls-key
# log-spawn.sh also validates MODEL against the tier's pin, so the pins have to be
# on disk for the key assertions to isolate the key.
seed_model_pins "$LSK" opus-x sonnet-x m
lsk_row() { RUN=$LSK ROLE=executor TIER=executor MODEL=m ITEM=Tk OUTCOME=ok "$@" bash "$SKILL_DIR/scripts/log-spawn.sh"; }
lsk_row env PHASE=7 > /dev/null 2> "$SANDBOX/lsk-7-nokey.log"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/7-execution.md first' "$SANDBOX/lsk-7-nokey.log"; then
  pass "log-spawn PHASE=7 without PHASE_KEY exits non-zero: load phases/7-execution.md first"
else
  fail "log-spawn PHASE=7 without PHASE_KEY exits non-zero: load phases/7-execution.md first (rc=$rc)"
fi
refute "the refused dispatch logged no row" test -e "$LSK/spawns.tsv"
lsk_row env PHASE=7 PHASE_KEY=not-the-key > /dev/null 2> "$SANDBOX/lsk-7-wrong.log"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/7-execution.md first' "$SANDBOX/lsk-7-wrong.log"; then
  pass "log-spawn PHASE=7 with a wrong PHASE_KEY is refused"
else
  fail "log-spawn PHASE=7 with a wrong PHASE_KEY is refused (rc=$rc)"
fi
lsk_row env PHASE=7 PHASE_KEY="$PK_STRUCTURAL" > /dev/null 2> "$SANDBOX/lsk-7-cross.log"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/7-execution.md first' "$SANDBOX/lsk-7-cross.log"; then
  pass "log-spawn PHASE=7 rejects the phase-5 key (keys are per dispatching phase)"
else
  fail "log-spawn PHASE=7 rejects the phase-5 key (rc=$rc)"
fi
lsk_row env PHASE=7 PHASE_KEY="$PK_EXECUTION" > /dev/null 2> "$SANDBOX/lsk-7-right.log"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'Tk' "$LSK/spawns.tsv"; then
  pass "log-spawn PHASE=7 with the execution key logs the row"
else
  fail "log-spawn PHASE=7 with the execution key logs the row (rc=$rc)"
fi
lsk_row env PHASE=5 > /dev/null 2> "$SANDBOX/lsk-5-nokey.log"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/5-structural.md first' "$SANDBOX/lsk-5-nokey.log"; then
  pass "log-spawn PHASE=5 without PHASE_KEY exits non-zero: load phases/5-structural.md first"
else
  fail "log-spawn PHASE=5 without PHASE_KEY exits non-zero: load phases/5-structural.md first (rc=$rc)"
fi
lsk_row env PHASE=5 PHASE_KEY="$PK_EXECUTION" > /dev/null 2> "$SANDBOX/lsk-5-cross.log"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/5-structural.md first' "$SANDBOX/lsk-5-cross.log"; then
  pass "log-spawn PHASE=5 rejects the phase-7 key"
else
  fail "log-spawn PHASE=5 rejects the phase-7 key (rc=$rc)"
fi
lsk_row env PHASE=5 PHASE_KEY="$PK_STRUCTURAL" > /dev/null 2> "$SANDBOX/lsk-5-right.log"; rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "log-spawn PHASE=5 with the structural key logs the row"
else
  fail "log-spawn PHASE=5 with the structural key logs the row (rc=$rc)"
fi
# A PHASE value that is not a dispatching phase keeps the historical keyless
# behavior — the guard maps exactly the two phases the skill dispatches from.
lsk_row env PHASE=2 > /dev/null 2> "$SANDBOX/lsk-other.log"; rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "log-spawn with an unmapped PHASE keeps the keyless behavior"
else
  fail "log-spawn with an unmapped PHASE keeps the keyless behavior (rc=$rc)"
fi

PK_RESOLVE=$(phase_key 2-resolve-target.md)
PK_BRANCH=$(phase_key 4-migration-branch.md)
PK_UNIQ=$(printf '%s\n' "$PK_PREFLIGHT" "$PK_MODELS" "$PK_RESOLVE" "$PK_MATERIALIZE" "$PK_CLASSIFY" "$PK_COMMON" \
  "$PK_BRANCH" "$PK_BASELINE" "$PK_STRUCTURAL" "$PK_PLANNING" "$PK_EXECUTION" "$PK_FINALIZE" | sort -u | grep -c .)
if [[ "$PK_UNIQ" = 12 ]]; then
  pass "the twelve phase keys are unique"
else
  fail "the twelve phase keys are unique (got $PK_UNIQ distinct)"
fi
# No key value anywhere in SKILL.md — the always-loaded file must not be able to
# satisfy a guard the phase file exists to gate.
LEAKED_KEYS=0
for k in "$PK_PREFLIGHT" "$PK_MODELS" "$PK_RESOLVE" "$PK_MATERIALIZE" "$PK_CLASSIFY" "$PK_COMMON" \
         "$PK_BRANCH" "$PK_BASELINE" "$PK_STRUCTURAL" "$PK_PLANNING" "$PK_EXECUTION" "$PK_FINALIZE"; do
  [[ -n "$k" ]] && grep -qF "$k" "$SKILL_DIR/SKILL.md" && LEAKED_KEYS=$((LEAKED_KEYS + 1))
done
if [[ "$LEAKED_KEYS" -eq 0 ]]; then
  pass "no phase-key value appears anywhere in SKILL.md"
else
  fail "$LEAKED_KEYS phase-key value(s) leaked into SKILL.md"
fi
fi

if t "the in_progress block has ONE writer, and every caller goes through it"; then
# The block is the skill's central interlock — five readers depend on it, and it
# is the one COMMITTED, cross-phase, unrecoverable file the $RUN-scoped
# artifact-writer lint below cannot see. Until this round it had no writer at
# all: Phase 4 and Phase 8 described a YAML edit in prose and a model performed
# it twice per run. A caller that describes the edit instead of running the
# script makes the writer bypassable and the whole guarantee decorative, so the
# wiring is asserted per caller.
IPW="$SKILL_DIR/scripts/in-progress.sh"
expect "scripts/in-progress.sh exists (the block's format owner)" test -f "$IPW"
for caller in phases/4-migration-branch.md phases/8-finalize.md \
              reference/abort.md reference/continue.md; do
  expect "$caller drives scripts/in-progress.sh" \
    grep -qF 'scripts/in-progress.sh' "$SKILL_DIR/$caller"
done
expect "phases/4-migration-branch.md writes the block with ACTION=set" \
  grep -qF 'ACTION=set' "$SKILL_DIR/phases/4-migration-branch.md"
expect "reference/continue.md's redo path also uses ACTION=set" \
  grep -qF 'ACTION=set' "$SKILL_DIR/reference/continue.md"
expect "phases/8-finalize.md removes the block with ACTION=clear" \
  grep -qF 'ACTION=clear' "$SKILL_DIR/phases/8-finalize.md"
expect "reference/abort.md removes the block with ACTION=clear" \
  grep -qF 'ACTION=clear' "$SKILL_DIR/reference/abort.md"

# clear is KEYLESS by design and both its callers must invoke it that way. Phase
# 8's guarded entry point is gate.sh under LABEL=final, and abort.md is a
# reference document holding no phase key at all — so a clear that demanded
# Phase 4's key would brick abort, the one remedy for a component already
# carrying a bad block.
for caller in phases/8-finalize.md reference/abort.md; do
  expect "$caller's clear passes NO phase key (env -u PHASE_KEY)" \
    bash -c "grep -F 'ACTION=clear' '$SKILL_DIR/$caller' | grep -qF 'env -u PHASE_KEY'"
done
refute "no clear call site states a phase key value" \
  bash -c "grep -hF 'ACTION=clear' '$SKILL_DIR'/phases/*.md '$SKILL_DIR'/reference/*.md | grep -qE 'PHASE_KEY=[A-Za-z0-9]{8}'"

# Scope: the baseline advance is a SEPARATE ACTION of the same script, not part of
# clear. abort calls clear while rolling a migration BACK, so a clear that also
# moved template.sha would finalize the migration it is undoing. The assertion is
# therefore about the boundary between the two actions, not about the script.
expect "scripts/in-progress.sh owns the baseline advance (ACTION=advance)" \
  grep -qE '^  advance\)' "$IPW"
expect "phases/8-finalize.md drives the advance through the script" \
  grep -qF 'ACTION=advance' "$SKILL_DIR/phases/8-finalize.md"
refute "phases/8-finalize.md no longer assigns template.sha in prose" \
  grep -qE '^- `template\.sha`' "$SKILL_DIR/phases/8-finalize.md"
expect "scripts/in-progress.sh owns the bootstrap write (ACTION=bootstrap)" \
  grep -qE '^  bootstrap\)' "$IPW"
# reference/bellwether-detection.md used to be a second caller here; F15 moved the
# bootstrap invocation block into phases/2 as its single home, so phases/2 is now
# the only doc that DRIVES the manifest write.
for caller in phases/2-resolve-target.md; do
  expect "$caller drives the initial manifest through ACTION=bootstrap" \
    grep -qF 'ACTION=bootstrap' "$SKILL_DIR/$caller"
  expect "$caller resolves NAME via scripts/resolve-component-name.sh" \
    grep -qF 'scripts/resolve-component-name.sh' "$SKILL_DIR/$caller"
done
expect "Phase 2 asks the user when schema.ComponentName is missing, rather than guessing" \
  grep -qF 'ASK: pkg/schema/globals.go' "$SKILL_DIR/phases/2-resolve-target.md"
refute "bellwether-detection.md no longer defaults NAME to the directory basename" \
  grep -qF 'the directory basename unless the user says otherwise' \
    "$SKILL_DIR/reference/bellwether-detection.md"
refute "reference/bellwether-detection.md no longer prints a manifest to transcribe" \
  grep -qF 'bootstrapped: true                # CRITICAL' "$SKILL_DIR/reference/bellwether-detection.md"
# record-floor is the fifth write action: it appends one frontend.outstanding_floors
# element when a crossed template floor is unmet and the frontend run is declined. It is a
# Phase-8 consent-epilogue write with ONE caller (8-finalize.md) and REUSES Phase 8's key
# (vk3rq8hd) rather than minting a new one — same phase as advance. Pin the ownership and
# the single caller so a reword that describes the append in prose (bypassing the writer)
# goes red, exactly as for the other actions.
expect "scripts/in-progress.sh owns the frontend-floor debt append (ACTION=record-floor)" \
  grep -qE '^  record-floor\)' "$IPW"
expect "phases/8-finalize.md drives the floor append through the script (ACTION=record-floor)" \
  grep -qF 'ACTION=record-floor' "$SKILL_DIR/phases/8-finalize.md"
# The per-action key split is the whole reason clear stays reachable from abort.
expect "in-progress.sh states Phase 8's key for advance" \
  grep -qF "$PK_FINALIZE" "$IPW"
expect "phases/8-finalize.md calls record-floor with Phase 8's key (reused, not a new key)" \
  bash -c "grep -F 'ACTION=record-floor' '$SKILL_DIR/phases/8-finalize.md' | grep -qF 'PHASE_KEY=$PK_FINALIZE'"
expect "in-progress.sh states Phase 2's key for bootstrap" \
  grep -qF "$(phase_key 2-resolve-target.md)" "$IPW"
fi

if t ".kairos/intent.md has ONE writer, and every caller goes through it"; then
# The other committed, machine-parsed file the $RUN-scoped artifact-writer lint
# cannot see. It was prose-written from THREE places, which is how SKILL.md's
# always-loaded one-line description came to claim it was "written only by Phase 8's
# promotion step" — untrue on two of the three paths. intent-check.sh already ships
# an intent-unparseable.md output BECAUSE the file arrives malformed. Same per-caller
# wiring assertions as the in_progress block, for the same reason: a caller that
# describes the edit instead of running the script makes the writer bypassable.
PIW="$SKILL_DIR/scripts/promote-intent.sh"
expect "scripts/promote-intent.sh exists (the intent file's format owner)" test -f "$PIW"
for caller in phases/8-finalize.md phases/5-structural.md reference/abort.md; do
  expect "$caller drives scripts/promote-intent.sh" \
    grep -qF 'scripts/promote-intent.sh' "$SKILL_DIR/$caller"
done
expect "phases/5-structural.md's re-confirm uses the retire action" \
  grep -qF 'ACTION=retire' "$SKILL_DIR/phases/5-structural.md"
expect "phases/5-structural.md's re-confirm uses the update action" \
  grep -qF 'ACTION=update' "$SKILL_DIR/phases/5-structural.md"
# Keyless by design — abort.md holds no phase key, and a key would brick the one
# path that keeps a run's answers when the run is being thrown away.
refute "no promote-intent.sh call site states a phase key value" \
  bash -c "grep -hF 'promote-intent.sh' '$SKILL_DIR'/phases/*.md '$SKILL_DIR'/reference/*.md | grep -qE 'PHASE_KEY=[A-Za-z0-9]{8}'"
refute "scripts/promote-intent.sh carries no PHASE_KEY guard" grep -q 'PHASE_KEY' "$PIW"
# SKILL.md's always-loaded one-liner must name the writer, not one of three callers.
expect "SKILL.md names promote-intent.sh as the intent file's writer" \
  grep -qF 'promote-intent.sh' "$SKILL_DIR/SKILL.md"
refute "SKILL.md no longer claims Phase 8's promotion is the only writer" \
  grep -qF 'Written only by Phase 8' "$SKILL_DIR/SKILL.md"
fi

if t "the planner does not re-ask what Phase 5 already asked AND enacted"; then
# A CROSS-FILE contradiction, which is why the fix is too: the no-re-asking promise
# lives in the dispatching phase (phases/6-planning.md), while the imperative "Always
# ask when applicable" bullets live in the role file that phase loads — and the
# imperative text wins at the point of use. Two of those bullets re-asked decisions
# Phase 5 asked and ENACTED (heavyweight additions via apply-ask-user.sh, modify-delete
# via the resolver fan-out), so the user answered them twice and could answer them
# differently the second time.
PLN="$SKILL_DIR/agents/planner.md"
P6="$SKILL_DIR/phases/6-planning.md"
refute "agents/planner.md no longer lists heavyweight additions as a question to always ask" \
  bash -c "awk '/^Always ask when applicable/{t=1} t' '$PLN' | grep -q 'added-heavyweight-ask-user'"
refute "agents/planner.md no longer lists modify-delete as a question to always ask" \
  bash -c "awk '/^Always ask when applicable/{t=1} t' '$PLN' | grep -qi 'Modify-delete cases.*which side wins'"
expect "agents/planner.md reframes both as reviewing the recorded outcome" \
  grep -qiE 'never re-ask it|Review what Phase 5 already settled' "$PLN"
expect "agents/planner.md names ask-user-applied.tsv as the heavyweight outcome source" \
  grep -qF 'ask-user-applied.tsv' "$PLN"
expect "agents/planner.md names the resolution ledger as the modify-delete outcome source" \
  grep -qiE 'resolution ledger|resolutions\.tsv' "$PLN"
# The promise must be checkable against those bullets, so the phase names the same
# two sources rather than asserting a property of a file that did not carry it.
expect "phases/6-planning.md still promises the Q&A never re-asks what is recorded" \
  grep -qiF 'never re-asks what is already recorded' "$P6"
expect "phases/6-planning.md names ask-user-applied.tsv as one recorded source" \
  grep -qF 'ask-user-applied.tsv' "$P6"
fi

if t "recurrence lint: every refusal that names continue/abort has an arm in that document"; then
# pre-flight refuses states and names continue or abort as the way out. When the
# named document has no arm for the state, the refusal is a dead end that only
# reads like a remedy — which is exactly how the partial-block deadlock shipped:
# check 3 named abort, and abort.md hard-stopped on the missing previous_branch.
# Crude textual coupling, same drift class as the Phase 8 ordering lint below.
RR_LINES=$SANDBOX/remedy-refusals.txt
grep -v '^[[:space:]]*#' "$SKILL_DIR/scripts/pre-flight.sh" \
  | grep -F 'fail "' | grep -Ei 'continue|abort' > "$RR_LINES"
RR_N=$(grep -c . "$RR_LINES" || true)
# Non-vacuity FIRST — an extraction that finds nothing must fail, never pass.
if [[ "${RR_N:-0}" -gt 0 ]]; then
  pass "remedy-naming refusal extraction from pre-flight.sh is non-empty ($RR_N refusal(s))"
else
  fail "remedy-naming refusal extraction from pre-flight.sh is non-empty (got 0 — extraction broke)"
fi

# Declared map, one row per line: <id>|<match>|<doc-or-verdict>|<needle>
# <match>  a distinctive literal from the refusal message.
# A row whose third field is `declared-not-a-remedy` states that the message
# names continue/abort only to say they do NOT apply — the remedy is elsewhere.
# A new refusal naming continue/abort must be added here AND given an arm, or
# this test goes red. That is the point.
RR_MAP='already-on-live|already on $CURRENT and a migration is in progress|reference/continue.md|template.in_progress
already-on-live|already on $CURRENT and a migration is in progress|reference/abort.md|in_progress.previous_branch
blockless-branch|records no migration in progress|declared-not-a-remedy|
mode-typo|is not a run mode this skill knows|declared-not-a-remedy|
live-block-fresh|say '"'"'continue'"'"' to resume it|reference/continue.md|template.in_progress
live-block-fresh|say '"'"'continue'"'"' to resume it|reference/abort.md|scripts/in-progress.sh
dirty-beyond-exempt|dirty beyond|reference/continue.md|the dirt reaches past
continue-source-mismatch|MODE=continue with RUN_SOURCE=|reference/continue.md|RUN_SOURCE=$SRC'

# 1. Every declared arm is actually present in the document it names.
while IFS='|' read -r id match doc needle; do
  [[ -n "$id" ]] || continue
  case "$doc" in
    declared-not-a-remedy)
      if grep -Fq "$match" "$RR_LINES" \
         && grep -F "$match" "$RR_LINES" | grep -qiE 'nothing to continue|no migration|not a run mode this skill knows'; then
        pass "refusal '$id' declares continue/abort do NOT apply (remedy stated inline)"
      else
        fail "refusal '$id' declares continue/abort do NOT apply (declaration missing)"
      fi ;;
    *)
      if grep -qF "$needle" "$SKILL_DIR/$doc"; then
        pass "refusal '$id' → $doc has its arm ($needle)"
      else
        fail "refusal '$id' → $doc has NO arm for the state it is named as the remedy for (missing: $needle)"
      fi ;;
  esac
done <<RRMAP
$RR_MAP
RRMAP

# 2. Every extracted refusal is covered by at least one declared row — a new
#    refusal naming continue/abort cannot ship without an arm.
RR_UNMAPPED=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  covered=0
  while IFS='|' read -r id match doc needle; do
    [[ -n "$id" ]] || continue
    case "$line" in *"$match"*) covered=1 ;; esac
  done <<RRMAP
$RR_MAP
RRMAP
  [[ "$covered" = 1 ]] || RR_UNMAPPED=$((RR_UNMAPPED + 1))
done < "$RR_LINES"
if [[ "$RR_UNMAPPED" -eq 0 ]]; then
  pass "every pre-flight refusal naming continue/abort is covered by a declared arm"
else
  fail "$RR_UNMAPPED refusal(s) name continue/abort with no declared remedy arm (add a row and an arm)"
fi

# 3. The map must not rot in the other direction: a row whose refusal no longer
#    exists is a stale declaration, not a live guarantee.
RR_STALE=""
while IFS='|' read -r id match doc needle; do
  [[ -n "$id" ]] || continue
  grep -Fq "$match" "$RR_LINES" || RR_STALE="$RR_STALE $id"
done <<RRMAP
$RR_MAP
RRMAP
if [[ -z "$RR_STALE" ]]; then
  pass "every declared remedy row still matches a live pre-flight refusal"
else
  fail "stale remedy row(s) — pre-flight no longer emits the refusal:$RR_STALE"
fi
fi

if t "architecture document exists and stays outside the runtime boundary"; then
# docs/kairos-component-update-architecture.md is for maintainers, never loaded
# at runtime, and never copied when a component vendors skills/. The boundary is
# mechanical: the doc must exist, and nothing the skill can load at runtime —
# SKILL.md, phases/, reference/, agents/, scripts/ — may reference it or docs/
# at all, so the human doc can never quietly become load-bearing. tests/ is
# excluded from the scan: test suites are never runtime-loaded, and this suite
# must name the doc to assert its existence.
ARCH_DOC="$SKILL_DIR/../../docs/kairos-component-update-architecture.md"
# The doc is a repo-root sibling of skills/, outside the skill dir. If it is absent — a
# partial checkout — say so with a message that names what is missing, not a bare failed
# `test -f`.
if [[ -f "$ARCH_DOC" ]]; then
  pass "docs/kairos-component-update-architecture.md exists at the repo root"
else
  fail "docs/kairos-component-update-architecture.md is absent at $ARCH_DOC — the maintainer architecture doc must exist as a repo-root sibling of skills/ (partial checkout?)"
fi
refute "no runtime file references the architecture document by name" \
  grep -rq --exclude-dir=tests 'kairos-component-update-architecture' "$SKILL_DIR"
refute "no runtime file references docs/ at all" \
  grep -rq --exclude-dir=tests -- 'docs/' "$SKILL_DIR"
fi

if t "recurrence lint: every classified bucket has a named owner in a phase file"; then
# The largest defect this skill ever shipped was a bucket the classifier emitted,
# a phase asked the user about, and nothing enacted. This lint re-runs that
# analysis mechanically: enumerate the bucket names build-manifest.sh emits
# (emit calls plus the two heavyweight re-bucket assignments), then require each
# to appear in an explicitly numbered phase step — next to its owning script
# where a script owns the enactment. A bucket mentioned only in flowing prose
# (e.g. 3-classify.md's bucket glossary, which has no numbered steps) does not
# count as owned.
{ sed 's/#.*//' "$SKILL_DIR/scripts/build-manifest.sh" | grep -oE 'emit [a-z][a-z-]*' | awk '{print $2}'
  sed 's/#.*//' "$SKILL_DIR/scripts/build-manifest.sh" | grep -oE '\$1 = "[a-z][a-z-]*"' | sed 's/.*"\([a-z-]*\)".*/\1/'
} | sort -u > "$SANDBOX/buckets.txt"
BUCKET_N=$(grep -c . "$SANDBOX/buckets.txt" || true)
# Non-vacuity FIRST: an extraction that finds nothing must fail, never pass.
if [[ "${BUCKET_N:-0}" -gt 0 ]]; then
  pass "bucket extraction from build-manifest.sh is non-empty ($BUCKET_N bucket(s))"
else
  fail "bucket extraction from build-manifest.sh is non-empty (got 0 — extraction broke)"
fi

# Declared owner map — bucket:owner. Owners: a script (must share a numbered
# step with the bucket), 'numbered-step' (an explicitly numbered phase step is
# itself the owner), or 'declared-no-action' (the docs must SAY nothing happens).
# A new bucket must be added here AND given an owner in a phase file, or this
# test goes red — that is the point.
BUCKET_OWNERS="merge-pipeline:structural-merge.sh
added-mechanical:structural-merge.sh
renamed-mechanical:structural-merge.sh
deleted-by-template-mechanical:structural-merge.sh
noop-already-deleted:declared-no-action
binary-for-user:apply-ask-user.sh
added-heavyweight-ask-user:apply-ask-user.sh
deleted-heavyweight-ask-user:apply-ask-user.sh
modify-delete-for-ai:numbered-step
renamed-with-mods-for-ai:numbered-step
unknown-status:numbered-step"

# bucket_owned <bucket> [needle] — some '### <n>' numbered section in a phase
# file contains the bucket (and the needle, when given).
bucket_owned() {
  local bkt="$1" ndl="${2:-}" f
  for f in "$SKILL_DIR"/phases/*.md; do
    awk -v b="$bkt" -v s="$ndl" '
      function flush() { if (hb && (s == "" || hs)) ok = 1; hb = hs = 0 }
      /^### / { flush(); num = ($0 ~ /^### [0-9]/) }
      num     { if (index($0, b)) hb = 1; if (s != "" && index($0, s)) hs = 1 }
      END     { flush(); exit !ok }' "$f" && return 0
  done
  return 1
}

while IFS= read -r bkt; do
  owner=""
  for row in $BUCKET_OWNERS; do
    case "$row" in "$bkt":*) owner=${row#*:} ;; esac
  done
  if [[ -z "$owner" ]]; then
    fail "bucket '$bkt' emitted by build-manifest.sh has no declared owner (add one to a phase file and to this map)"
    continue
  fi
  case "$owner" in
    declared-no-action)
      if grep -h "$bkt" "$SKILL_DIR"/phases/*.md | grep -qiE 'nothing to do|no action'; then
        pass "bucket '$bkt' is declared no-action in a phase file"
      else
        fail "bucket '$bkt' is declared no-action in a phase file (declaration missing)"
      fi ;;
    numbered-step)
      if bucket_owned "$bkt"; then
        pass "bucket '$bkt' is owned by an explicitly numbered phase step"
      else
        fail "bucket '$bkt' is owned by an explicitly numbered phase step (no numbered step names it)"
      fi ;;
    *)
      if bucket_owned "$bkt" "$owner"; then
        pass "bucket '$bkt' shares a numbered phase step with its owner $owner"
      else
        fail "bucket '$bkt' shares a numbered phase step with its owner $owner (not found)"
      fi ;;
  esac
done < "$SANDBOX/buckets.txt"

# The map must not go stale in the other direction either: every declared bucket
# must still be one build-manifest.sh emits.
STALE_MAP=0
for row in $BUCKET_OWNERS; do
  grep -qxF "${row%%:*}" "$SANDBOX/buckets.txt" || STALE_MAP=$((STALE_MAP + 1))
done
if [[ "$STALE_MAP" -eq 0 ]]; then
  pass "every bucket in the owner map is still emitted by build-manifest.sh"
else
  fail "$STALE_MAP owner-map bucket(s) are no longer emitted by build-manifest.sh (stale map)"
fi
fi

if t "recurrence lint: the ask-user bucket triplet is bound across gate.sh, apply-ask-user.sh, and the classifier"; then
# The bucket-ownership lint above proves every classified bucket has an owner
# script; it says nothing about whether that owner's OWN idea of the ask-user
# set agrees with everyone ELSE who hardcodes it. Five sites carry the same
# {binary-for-user, added-heavyweight-ask-user, deleted-heavyweight-ask-user}
# triplet as independent literals: gate.sh's postmerge coverage row (check 7),
# apply-ask-user.sh's classified-set builder (the identical awk one-liner) AND
# its decision-vocabulary case statement, handoff-classify.sh's ask-user tally
# loop, and build-manifest.sh — the classifier that actually produces the set,
# by re-bucketing (added-/deleted-heavyweight) or direct emission
# (binary-for-user). Nothing bound them: a properly-owned FOURTH ask-user
# bucket added to the classifier but missed in gate.sh's or apply-ask-user.sh's
# awk literal would be silently un-enacted by apply-ask-user.sh while the
# coverage row's own (equally incomplete) set comes out empty of it too — so
# it PASSES. This lint turns that drift into one red test instead of five
# greps a reviewer has to remember to run by hand.

# --- extractors, one per site, each taking a file PATH so the refute test
# below can point them at a mutated sandbox copy instead of the real script.
# Every extractor is anchored on a STRUCTURAL landmark (an awk match action, a
# case/`*)` pair, a doc heading, an awk field-reassignment shape) — never on a
# line number — so the concurrent edits elsewhere in gate.sh and
# apply-ask-user.sh cannot break it.

# au_awk_triplet <file> — the bucket set inside a
# `$1 == "<b1>" || $1 == "<b2>" || ...` awk literal whose match action is
# `{ print $1 "\t" $4 }`. gate.sh's coverage row and apply-ask-user.sh's
# classified-set builder share this literal byte-for-byte. Continuation lines
# are joined first (ls_norm's idiom, above) because the match action sits on
# the line AFTER the backslash continuation, not the line naming the buckets.
au_awk_triplet() {
  sed -e :a -e '/\\$/N; s/\\\n//; ta' "$1" \
    | grep -F '{ print $1 "\t" $4 }' \
    | grep -oE '\$1 == "[a-z][a-z-]*"' \
    | sed -E 's/.*"([a-z-]+)".*/\1/' | sort -u
}

# au_decision_vocab <file> — the bucket set named in apply-ask-user.sh's
# `case "$bucket:$decision" in` vocabulary: every `<bucket>:<word>` arm between
# that case and its `*)` catch-all.
au_decision_vocab() {
  awk '/case "\$bucket:\$decision" in/{f=1; next} f && /^[[:space:]]*\*\)/{exit} f' "$1" \
    | grep -oE '[a-z][a-z-]*:[a-z]+' | cut -d: -f1 | sort -u
}

# au_handoff_list <file> — the bucket set in handoff-classify.sh's
# `for b in ...; do` loop under the "## Ask-user buckets" heading (the sibling
# for-AI loop a few lines below is excluded by stopping at the next bare
# `echo`).
au_handoff_list() {
  awk '/## Ask-user buckets/{f=1; next} f && /^[[:space:]]*echo[[:space:]]*$/{exit} f' "$1" \
    | grep -oE 'for b in .*; do' | sed -E 's/for b in (.*); do/\1/' \
    | tr ' ' '\n' | sort -u
}

# au_classifier_set <file> — the bucket set build-manifest.sh (the classifier)
# routes INTO the ask-user tier. The two heavyweight re-buckets are found
# structurally: `$1 = "<bucket>"` (single `=`, an awk field REASSIGNMENT) is a
# shape this file uses ONLY for heavyweight re-bucketing, so any bucket named
# that way is picked up generically, whatever it is named. binary-for-user has
# no such distinguishing shape of its own — an `emit <bucket> ...` call looks
# identical for every one of the ~11 buckets this file emits — so, same as the
# two awk-literal sites, it is named literally here. This is the one place a
# genuinely new-shaped ask-user bucket (neither re-bucketed nor named
# binary-for-user) could enter the classifier and slip past this lint; see the
# WI report for why that residual is accepted rather than papered over with a
# false sense of full auto-discovery.
au_classifier_set() {
  { grep -oE '\$1 = "[a-z][a-z-]*"' "$1" | sed -E 's/.*"([a-z-]+)".*/\1/'
    grep -oE 'emit binary-for-user\b' "$1" | awk '{print $2}'
  } | sort -u
}

# au_sets_agree <gate.sh> <apply-ask-user.sh> <handoff-classify.sh>
# <build-manifest.sh> — the lint's core. Fail-closed FIRST: any extractor that
# finds nothing is reported and fails the whole check, never silently treated
# as "no buckets, so nothing to disagree about". Only once every set is
# non-empty are the five extracted sets compared against gate.sh's.
au_sets_agree() {
  local gate="$1" aau="$2" handoff="$3" bm="$4" bad=0 label val ref pair
  local s_gate s_aau_awk s_aau_vocab s_handoff s_bm
  s_gate=$(au_awk_triplet "$gate")
  s_aau_awk=$(au_awk_triplet "$aau")
  s_aau_vocab=$(au_decision_vocab "$aau")
  s_handoff=$(au_handoff_list "$handoff")
  s_bm=$(au_classifier_set "$bm")

  for pair in "gate.sh coverage row:$s_gate" \
              "apply-ask-user.sh classified-set builder:$s_aau_awk" \
              "apply-ask-user.sh decision vocabulary:$s_aau_vocab" \
              "handoff-classify.sh ask-user tally:$s_handoff" \
              "build-manifest.sh classifier routing:$s_bm"; do
    label=${pair%%:*}; val=${pair#*:}
    if [[ -z "$val" ]]; then
      echo "extraction found no ask-user buckets in $label — the lint's anchor drifted"
      bad=1
    fi
  done
  [[ "$bad" -eq 0 ]] || return 1

  ref="$s_gate"
  for pair in "apply-ask-user.sh classified-set builder:$s_aau_awk" \
              "apply-ask-user.sh decision vocabulary:$s_aau_vocab" \
              "handoff-classify.sh ask-user tally:$s_handoff" \
              "build-manifest.sh classifier routing:$s_bm"; do
    label=${pair%%:*}; val=${pair#*:}
    if [[ "$val" != "$ref" ]]; then
      echo "ask-user bucket set mismatch: gate.sh has [$(printf '%s' "$ref" | tr '\n' ' ')] but $label has [$(printf '%s' "$val" | tr '\n' ' ')]"
      bad=1
    fi
  done
  return $bad
}

# --- the lint itself, on the real scripts -------------------------------------
if au_sets_agree "$SKILL_DIR/scripts/gate.sh" "$SKILL_DIR/scripts/apply-ask-user.sh" \
     "$SKILL_DIR/scripts/handoff-classify.sh" "$SKILL_DIR/scripts/build-manifest.sh" \
     > "$SANDBOX/au-live.log" 2>&1; then
  pass "the ask-user bucket triplet is bound: gate.sh, apply-ask-user.sh (both sites), handoff-classify.sh and build-manifest.sh agree"
else
  fail "ask-user bucket triplet disagreement: $(tr '\n' '; ' < "$SANDBOX/au-live.log")"
fi

# --- non-vacuity, direction 1 (required refute test): a mutation to exactly
# ONE site's awk literal must turn the lint red. A copy of gate.sh is mutated
# in $SANDBOX; apply-ask-user.sh, handoff-classify.sh and build-manifest.sh are
# the real, untouched files, so a green result here would mean the compare
# logic never really looks at gate.sh's set at all. ---------------------------
AU_MUT=$SANDBOX/au-mutated-gate.sh
sed 's/\$1 == "deleted-heavyweight-ask-user"/$1 == "deleted-heavyweight-ask-user" || $1 == "fourth-heavyweight-ask-user"/' \
  "$SKILL_DIR/scripts/gate.sh" > "$AU_MUT"
refute "the mutated copy actually differs from gate.sh (the sed pattern still matches — sanity check on the fixture, not the lint)" \
  cmp -s "$AU_MUT" "$SKILL_DIR/scripts/gate.sh"
refute "au_sets_agree: a fourth bucket added to ONLY gate.sh's awk literal is caught (non-vacuity proof)" \
  au_sets_agree "$AU_MUT" "$SKILL_DIR/scripts/apply-ask-user.sh" \
    "$SKILL_DIR/scripts/handoff-classify.sh" "$SKILL_DIR/scripts/build-manifest.sh"

# --- non-vacuity, direction 2: an anchor that matches NOTHING must fail
# loudly, never pass vacuously — the CRITICAL fail-closed requirement. --------
AU_EMPTY=$SANDBOX/au-empty.sh
: > "$AU_EMPTY"
if au_sets_agree "$AU_EMPTY" "$AU_EMPTY" "$AU_EMPTY" "$AU_EMPTY" > "$SANDBOX/au-empty.log" 2>&1; then
  fail "au_sets_agree: a file with no ask-user literals at all must be refused, not passed vacuously"
else
  expect "au_sets_agree: a file with no ask-user literals fails with the anchor-drift message, not a silent pass" \
    grep -q 'anchor drifted' "$SANDBOX/au-empty.log"
fi
fi

if t "recurrence lint: every duplicated shell helper is byte-identical across its copies"; then
# scripts/ carries several helpers that exist as literal COPIES in two or three
# scripts rather than in a shared lib — a deliberate choice (each script stays a
# standalone file an orchestrator can invoke by path), but one nothing enforced.
# A bug fixed in one copy therefore stays live in the others, and the fix reads as
# done: oneline() was locale-pinned in producer-idempotence.sh, where a non-UTF-8
# byte had truncated a verdict cell, while the byte-for-byte identical copies in
# gate.sh and yaml-gate.sh kept the same bug in the same detail-cell role. This
# lint binds them: every twin group below must extract byte-identically, so a
# one-sided edit is one red test instead of a review someone has to remember to do.
# Story 42 moved snap_upgrade / z_log_name_only into scripts/lib/; those are no
# longer twins — they are sourced. The groups below are the remaining copies.
#
# The bodies are NEVER hardcoded here — they are extracted from the live scripts at
# run time and compared to each other. The lint therefore states "these copies
# agree", not "these copies say X", and stays correct across any edit that lands in
# all of them.

# fn_def <file> <fn> — the function's definition, from the `<fn>() {` line to its
# closing brace. Same anchoring rule as the extractors above: a STRUCTURAL landmark,
# never a line number, so concurrent edits elsewhere in these files cannot break it.
# A one-line definition closes on its own line (it ends in `}`); a multi-line one
# closes on a `}` at column 0, which is this repo's shell style throughout.
fn_def() { # fn_def <file> <fn>
  awk -v fn="$2" '
    !f && $0 ~ "^" fn "\\(\\)[ \t]*\\{" { f=1; print; if ($0 ~ /\}[ \t]*$/) exit; next }
    f { print; if ($0 ~ /^\}/) exit }
  ' "$1" 2>/dev/null
}

# fn_twins_agree <fn> <file> <file> [<file>...] — the lint's core. Fail-closed
# FIRST: a group whose extraction comes back empty from any file is reported and
# fails, never silently treated as "nothing to compare". Only non-empty definitions
# are compared, and every mismatch names the function AND both files.
fn_twins_agree() {
  local fn="$1"; shift
  local ref="" reffile="" f d bad=0
  for f in "$@"; do
    d=$(fn_def "$f" "$fn")
    if [[ -z "$d" ]]; then
      echo "extraction found no ${fn}() definition in $f — the lint's anchor drifted"
      bad=1
      continue
    fi
    if [[ -z "$reffile" ]]; then ref="$d"; reffile="$f"; continue; fi
    if [[ "$d" != "$ref" ]]; then
      echo "${fn}() drifted: $reffile and $f no longer carry byte-identical definitions"
      bad=1
    fi
  done
  [[ -n "$reffile" ]] || bad=1
  return $bad
}

# The twin table: "<fn>:<file> <file> [...]", paths relative to the skill dir. Each
# group was confirmed to be a literal textual copy — NOT merely a shared name.
# `record()` is deliberately absent: gate.sh/yaml-gate.sh write 4-column rows and
# producer-idempotence.sh/run-check-modules.sh write 3-column rows, so those four
# are same-named siblings with different contracts, not twins.
FN_TWINS='oneline:scripts/producer-idempotence.sh scripts/gate.sh scripts/yaml-gate.sh
line:scripts/gate.sh scripts/producer-idempotence.sh
show_synth:scripts/build-manifest.sh scripts/structural-merge.sh
is_binary_file:scripts/materialize.sh scripts/structural-merge.sh scripts/materialize-frontend.sh
esc:scripts/materialize.sh scripts/bellwether-detect.sh
esc_pat:scripts/materialize.sh scripts/bellwether-detect.sh'

FN_GROUPS=0
while IFS= read -r spec; do
  [[ -n "$spec" ]] || continue
  FN_FN=${spec%%:*}
  FN_ARGS=""
  for rel in ${spec#*:}; do FN_ARGS="$FN_ARGS $SKILL_DIR/$rel"; done
  FN_GROUPS=$((FN_GROUPS + 1))
  # shellcheck disable=SC2086
  if fn_twins_agree "$FN_FN" $FN_ARGS > "$SANDBOX/fn-twin.log" 2>&1; then
    pass "${FN_FN}() is byte-identical across ${spec#*:}"
  else
    fail "${FN_FN}() twin drift: $(tr '\n' '; ' < "$SANDBOX/fn-twin.log")"
  fi
done <<EOF
$FN_TWINS
EOF
# The table itself must not silently empty out (a bad edit to FN_TWINS would make
# every assertion above vanish rather than fail).
if [[ "$FN_GROUPS" -eq 6 ]]; then
  pass "the twin table still lists all 6 duplicated helpers"
else
  fail "the twin table lists $FN_GROUPS helper group(s), expected 6 — a group was dropped, not fixed"
fi

# --- non-vacuity, direction 1: ONE byte changed in ONE copy must turn the lint
# red and name both sides. gate.sh is copied to $SANDBOX and mutated there;
# producer-idempotence.sh and yaml-gate.sh are the real, untouched files, so a
# green result here would mean the comparison never really reads gate.sh. --------
FN_MUT=$SANDBOX/fn-mutated-gate.sh
sed 's/^oneline() { LC_ALL=C tr /oneline() { LC_ALL=C  tr /' "$SKILL_DIR/scripts/gate.sh" > "$FN_MUT"
refute "the mutated copy actually differs from gate.sh (sanity check on the fixture, not the lint)" \
  cmp -s "$FN_MUT" "$SKILL_DIR/scripts/gate.sh"
if fn_twins_agree oneline "$SKILL_DIR/scripts/producer-idempotence.sh" "$FN_MUT" \
     "$SKILL_DIR/scripts/yaml-gate.sh" > "$SANDBOX/fn-mut.log" 2>&1; then
  fail "fn_twins_agree: a single added space in one oneline() copy must be caught (non-vacuity proof)"
else
  expect "fn_twins_agree: the drift message names the function" \
    grep -q 'oneline() drifted' "$SANDBOX/fn-mut.log"
  expect "fn_twins_agree: the drift message names the reference file" \
    grep -q 'producer-idempotence.sh' "$SANDBOX/fn-mut.log"
  expect "fn_twins_agree: the drift message names the mutated file" \
    grep -q 'fn-mutated-gate.sh' "$SANDBOX/fn-mut.log"
fi

# --- non-vacuity, direction 1b: the same proof for a MULTI-LINE helper, mutated
# strictly INSIDE its body. oneline() above is a one-liner, so on its own it would
# pass even if fn_def only ever compared the `<fn>() {` header — every multi-line
# group would then be vacuously green. This mutates materialize.sh's
# is_binary_file() body (twinned in structural-merge.sh / materialize-frontend.sh)
# and leaves its header untouched, so only a slice that really spans to the
# closing brace is red. (show_synth is a remaining twin but a one-liner, so it
# cannot prove the slice; snap_upgrade / z_log_name_only moved to scripts/lib/.)
FN_MUT2=$SANDBOX/fn-mutated-materialize.sh
awk '
  !f && /^is_binary_file\(\)[ \t]*\{/ { f=1; print; next }
  f && /^\}/ { print "  : # drifted"; f=0 }
  { print }
' "$SKILL_DIR/scripts/materialize.sh" > "$FN_MUT2"
refute "the multi-line mutant actually differs from materialize.sh (sanity check on the fixture)" \
  cmp -s "$FN_MUT2" "$SKILL_DIR/scripts/materialize.sh"
expect "the multi-line mutant left the function's header line untouched (the drift is body-only)" \
  bash -c "grep -qxF \"\$(grep -m1 '^is_binary_file() {' '$SKILL_DIR/scripts/materialize.sh')\" '$FN_MUT2'"
refute "fn_twins_agree: a line added inside a multi-line helper's BODY is caught (the slice spans the whole definition)" \
  fn_twins_agree is_binary_file "$FN_MUT2" "$SKILL_DIR/scripts/structural-merge.sh"

# --- non-vacuity, direction 2: an anchor that matches NOTHING must fail loudly,
# never pass vacuously — the same fail-closed requirement as au_sets_agree. ------
FN_EMPTY=$SANDBOX/fn-empty.sh
: > "$FN_EMPTY"
if fn_twins_agree oneline "$FN_EMPTY" "$SKILL_DIR/scripts/gate.sh" \
     > "$SANDBOX/fn-empty.log" 2>&1; then
  fail "fn_twins_agree: a file carrying no such function must be refused, not passed vacuously"
else
  expect "fn_twins_agree: a missing definition fails with the anchor-drift message, not a silent pass" \
    grep -q 'anchor drifted' "$SANDBOX/fn-empty.log"
fi
fi

if t "story-42 helpers live in scripts/lib/ and every walk sources them"; then
# snap_upgrade / z_log_name_only moved out of the twin table; a walk that stops
# sourcing them silently reverts to an inlined copy (or has neither). Pin the
# source sites, and that the walk files no longer define the helpers themselves.
for walk in scripts/build-manifest.sh scripts/collect-common.sh scripts/collect-lib.sh; do
  expect "$walk sources snap-upgrade.sh" \
    grep -q 'lib/snap-upgrade.sh' "$SKILL_DIR/$walk"
  expect "$walk sources z-log-name-only.sh" \
    grep -q 'lib/z-log-name-only.sh' "$SKILL_DIR/$walk"
  refute "$walk no longer defines snap_upgrade()" \
    grep -q '^snap_upgrade()' "$SKILL_DIR/$walk"
  refute "$walk no longer defines z_log_name_only()" \
    grep -q '^z_log_name_only()' "$SKILL_DIR/$walk"
done
expect "scripts/lib/snap-upgrade.sh defines snap_upgrade()" \
  grep -q '^snap_upgrade()' "$SKILL_DIR/scripts/lib/snap-upgrade.sh"
expect "scripts/lib/z-log-name-only.sh defines z_log_name_only()" \
  grep -q '^z_log_name_only()' "$SKILL_DIR/scripts/lib/z-log-name-only.sh"
fi

if t "recurrence lint: every \$RUN/ artifact in the docs has a format owner"; then
# The intent ledger shipped with no writer script — the one load-bearing TSV the
# orchestrator hand-appended. This lint re-runs the analysis that found it:
# every $RUN/<file> referenced in the runtime docs must either be named in a
# script (its format owner) or sit on the short DECLARED hand-written
# allowlist. The allowlist is the point: "this file has no format owner" must be
# a deliberate, reviewed statement. It also catches the inverse — a doc naming
# an artifact nothing produces. Templated names (resolutions.<slug>.tsv) and
# extensionless stems/dirs (test-baseline, upgrades) are excluded: their names
# are composed at runtime, so a literal grep cannot attest them.
#
# THE DOC SET IS reference/ INCLUDED. It was SKILL.md + phases/ + agents/ only,
# and reference/ is where the artifact prose is thickest: abort.md, continue.md
# and structural-merge.md name 12-14 artifacts each, so a phantom `$RUN/<name>`
# in any of them passed this lint outright. reference/state-files.md is in the
# set too, deliberately: as the artifact INDEX its rows spell bare backticked
# names (`context.env`), not `$RUN/`-prefixed paths, so index rows never enter
# this extraction and cannot self-certify anything — the one `$RUN/`-prefixed
# mention it does carry is a quoted phase invocation, a real reference like any
# other. If the index ever adopts `$RUN/` prefixes, a row for an artifact with no
# writer belongs on AW_ALLOWLIST, which is the declaration this lint exists for.
AW_ALLOWLIST="ref-overrides.tsv yaml-gate-ack.tsv ask-user-decisions.tsv committed-binaries-ok.txt"
# aw_extract <out> <doc…> — the artifact list a doc set contributes. A function so
# the self-test below can run the REAL extraction over a mutated doc set.
aw_extract() {
  local out="$1"; shift
  grep -ohE '\$RUN/[A-Za-z0-9._-]+' "$@" \
    | sed 's#^\$RUN/##; s/\.$//' | grep '\.' | sort -u > "$out"
}
# ONE source of truth for the swept doc set. The reference/ guard below measures
# THIS sweep's own output file, so narrowing the list cannot pass unnoticed.
AW_DOCS_NONREF=("$SKILL_DIR/SKILL.md" "$SKILL_DIR"/phases/*.md "$SKILL_DIR"/agents/*.md)
AW_DOCS_REF=("$SKILL_DIR"/reference/*.md)
aw_extract "$SANDBOX/run-artifacts.txt" "${AW_DOCS_NONREF[@]}" "${AW_DOCS_REF[@]}"
AW_N=$(grep -c . "$SANDBOX/run-artifacts.txt" || true)
# Non-vacuity FIRST.
if [[ "${AW_N:-0}" -gt 0 ]]; then
  pass "\$RUN/ artifact extraction from the docs is non-empty ($AW_N artifact(s))"
else
  fail "\$RUN/ artifact extraction from the docs is non-empty (got 0 — extraction broke)"
fi

# The check has to tell a WRITER from a READER. The old version returned true on
# any literal mention anywhere under scripts/, so a script that only consumed an
# artifact certified it as owned — which is how `$RUN/test-command.txt` passed this
# lint for its whole life with no writer at all (gate.sh mentions it as a reader).
#
# But the write shape it demands has to be the shape the scripts ACTUALLY use.
# Two idioms dominate, and neither puts the artifact's literal name next to a
# redirection operator:
#   * assign, then redirect through the variable —
#       spawns="$RUN/spawns.tsv" … >> "$spawns"
#     (log-spawn.sh, log-intent.sh, log-learning.sh, intent-check.sh, gate.sh,
#      spawn-summary.sh)
#   * temp file + mv —
#       tmp_out="$RUN/model.txt.tmp" … mv "$tmp_out" "$RUN/model.txt"
#     (resolve-models.sh, record-context.sh, apply-ask-user.sh, in-progress.sh,
#      write-test-commands.sh, log-resolution.sh)
# A "the artifact name is the target of > / tee" check fails on 17 of the 41
# doc-referenced artifacts today, ~15 of which have perfectly good format owners.
# Allowlisting those would inverte the lint's meaning, so the check resolves ONE
# level of variable assignment before deciding. One level is enough for every
# current writer; stopping at one is what keeps it from degenerating back toward
# "mentioned somewhere".

# aw_write_re <token-ere> — an ERE matching a line that WRITES to a path whose
# trailing part matches <token-ere>: a redirection / tee / -o target, or the LAST
# argument of an mv/cp (the destination; a source is a read).
# The token is ANCHORED at its end (quote, whitespace, `;`, `)`, or end of line) so
# a longer name cannot certify a shorter one: without it `> "$OUT.modules.tsv"`
# certifies `…mod`, and `> "$X.txt.gz"` certifies `…txt`.
aw_write_re() {
  printf '%s' "((>>?|tee([[:space:]]+-a)?|-o|--output)[[:space:]=]*\"?[^\"[:space:]]*${1}([\"[:space:];)]|\$))"
}
aw_move_re() {
  printf '%s' "\\b(mv|cp)[[:space:]].*[[:space:]]\"?[^\"[:space:]]*${1}\"?[[:space:]]*\$"
}
# aw_writes <file> <token-ere> — does this script write to such a path? Whole-line
# comments are stripped first: every script header documents the artifacts it
# READS, and those mentions are exactly the hole being closed.
aw_writes() {
  local body; body=$(grep -v '^[[:space:]]*#' "$1")
  printf '%s\n' "$body" | grep -qE "$(aw_write_re "$2")" && return 0
  printf '%s\n' "$body" | grep -qE "$(aw_move_re "$2")"
}
aw_esc() { printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'; }

# aw_owned_in <file> <name> — <file> writes <name>, either directly or through one
# level of variable assignment (`VAR=…<name>[<suffix>]` … then `$VAR` written to).
aw_owned_in() {
  local f="$1" tok v body
  tok=$(aw_esc "$2")
  aw_writes "$f" "$tok" && return 0
  body=$(grep -v '^[[:space:]]*#' "$f")
  for v in $(printf '%s\n' "$body" \
      | sed -nE "s/^[[:space:]]*(local|export|readonly|declare)?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*${tok}.*/\\2/p" \
      | sort -u); do
    aw_writes "$f" "[\$][{]?${v}[}]?" && return 0
  done
  return 1
}

# aw_writer_ok <name> [scripts-dir] — some script under <scripts-dir> is <name>'s
# format owner. Falls back, for names composed at runtime, to a stem the scripts
# know plus a $VAR-anchored suffix ("$OUT.status") — which must itself be WRITTEN
# to, not merely read.
aw_writer_ok() {
  local dir=${2:-$SKILL_DIR/scripts} f stem sfx esc
  for f in "$dir"/*.sh; do
    [[ -f "$f" ]] || continue
    aw_owned_in "$f" "$1" && return 0
  done
  stem=${1%%.*}; sfx=${1#*.}
  [[ "$sfx" != "$1" ]] || return 1
  grep -rqF "$stem" "$dir" || return 1
  esc=$(aw_esc "$sfx")
  for f in "$dir"/*.sh; do
    [[ -f "$f" ]] || continue
    aw_writes "$f" "[\$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?[.]${esc}" && return 0
  done
  return 1
}

# --- the check's own self-test, from BOTH directions -------------------------
# Both directions have already failed once. A reader-only mention used to certify
# an artifact as owned — that is how $RUN/test-command.txt passed this lint for its
# whole life while nothing under scripts/ wrote it. And a naive "the artifact name
# sits next to a redirection operator" check fails on 17 of the 41 doc-referenced
# artifacts, nearly all of which have perfectly good format owners written the house
# way. A check that rejects the house idioms would condemn ~15 owned artifacts and
# invite an allowlist that inverts the lint's meaning. So both are pinned here.
awf() { mkdir -p "$SANDBOX/awf/$1"; printf '%s\n' "$2" > "$SANDBOX/awf/$1/s.sh"; printf '%s' "$SANDBOX/awf/$1"; }

D=$(awf reader 'CMDFILE="$RUN/thing.txt"
line() { sed -n "${1}p" "$CMDFILE"; }
echo "consult $RUN/thing.txt for the commands" >&2
if [[ -f "$RUN/thing.txt" ]]; then cat "$RUN/thing.txt"; fi')
refute "aw_writer_ok: a script that only READS an artifact does not certify it" \
  aw_writer_ok thing.txt "$D"

D=$(awf redirect 'printf "x\n" > "$RUN/thing.txt"')
expect "aw_writer_ok: a direct redirect certifies it" aw_writer_ok thing.txt "$D"

D=$(awf append 'printf "x\n" >> "$RUN/thing.txt"')
expect "aw_writer_ok: a direct append certifies it" aw_writer_ok thing.txt "$D"

# House idiom 1 — assign the path to a variable, then redirect through the variable.
# log-spawn.sh:57, log-intent.sh, log-learning.sh, intent-check.sh, gate.sh,
# spawn-summary.sh all do exactly this.
D=$(awf assign 'spawns="$RUN/thing.txt"
if [[ ! -f "$spawns" ]]; then printf "header\n" > "$spawns"; fi
printf "row\n" >> "$spawns"')
expect "aw_writer_ok: assign-then-redirect-through-the-variable certifies it" \
  aw_writer_ok thing.txt "$D"

# House idiom 2 — write a temp file, then mv it into place. resolve-models.sh:90,319,
# record-context.sh, apply-ask-user.sh and in-progress.sh all do exactly this.
D=$(awf tmpmv 'tmp_out="$RUN/thing.txt.tmp"
printf "x\n" > "$tmp_out"
mv "$tmp_out" "$RUN/thing.txt"')
expect "aw_writer_ok: temp-file-plus-mv certifies it" aw_writer_ok thing.txt "$D"

# The same idiom where even the destination goes through a variable.
D=$(awf tmpmvvar 'out="$RUN/thing.txt"
tmp="$out.tmp"
printf "x\n" > "$tmp"
mv "$tmp" "$out"')
expect "aw_writer_ok: temp-file-plus-mv through two variables certifies it" \
  aw_writer_ok thing.txt "$D"

D=$(awf tee 'printf "x\n" | tee "$RUN/thing.txt"')
expect "aw_writer_ok: a tee target certifies it" aw_writer_ok thing.txt "$D"

D=$(awf dashO 'sort -u "$RUN/other.txt" -o "$RUN/thing.txt"')
expect "aw_writer_ok: an -o output target certifies it" aw_writer_ok thing.txt "$D"

# A COMMENT naming the artifact is not a write — script headers document every
# artifact they read, and that is precisely the reader-mention hole.
D=$(awf comment '# Out: $RUN/thing.txt   the positional command file
# reads $RUN/thing.txt by line number
grep -q x "$RUN/thing.txt"')
refute "aw_writer_ok: a header comment naming the artifact does not certify it" \
  aw_writer_ok thing.txt "$D"

# An mv whose artifact is the SOURCE is a read, not a write.
D=$(awf mvsrc 'mv "$RUN/thing.txt" "$RUN/archived.txt"')
refute "aw_writer_ok: an artifact that is only an mv SOURCE does not certify it" \
  aw_writer_ok thing.txt "$D"

# The runtime-composed fallback still works, and still needs a write shape.
D=$(awf composed 'OUT="$RUN/test-baseline"
printf "OK\n" > "$OUT.status"')
expect "aw_writer_ok: a stem plus a \$VAR-anchored suffix written to certifies it" \
  aw_writer_ok test-baseline.status "$D"
D=$(awf composedread 'OUT="$RUN/test-baseline"
cat "$OUT.status"')
refute "aw_writer_ok: a composed name that is only READ does not certify it" \
  aw_writer_ok test-baseline.status "$D"

# A LONGER written name must not certify a shorter one — the anchor. `$BOUT.modules.tsv`
# certified `template-go.mod` before it was added.
D=$(awf longer 'BOUT="$RUN/build-x"
printf "x\n" > "$BOUT.modules.tsv"
grep -q x "$RUN/thing.mod"')
refute "aw_writer_ok: writing \$VAR.modules.tsv does not certify an artifact ending .mod" \
  aw_writer_ok thing.mod "$D"
D=$(awf longer2 'printf "x\n" > "$RUN/thing.txt.gz"
cat "$RUN/thing.txt"')
refute "aw_writer_ok: writing thing.txt.gz does not certify thing.txt" \
  aw_writer_ok thing.txt "$D"

# aw_unowned <artifact-list-file> — the sweep itself: every listed artifact that is
# neither allowlisted nor owned by a writer script. A function for the same reason
# aw_extract is: the self-test below runs THIS sweep, not a paraphrase of it.
aw_unowned() {
  local a u=""
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    case " $AW_ALLOWLIST " in *" $a "*) continue ;; esac
    aw_writer_ok "$a" || u="$u $a"
  done < "$1"
  printf '%s' "$u"
}
AW_UNOWNED=$(aw_unowned "$SANDBOX/run-artifacts.txt")
if [[ -z "$AW_UNOWNED" ]]; then
  pass "every doc-referenced \$RUN/ artifact has a writer script or a declared hand-written entry"
else
  fail "\$RUN/ artifact(s) with no format owner (add a writer script or a deliberate allowlist entry):$AW_UNOWNED"
fi

# --- the doc set really includes reference/, proven both ways ------------------
# Direction 1: the artifacts only reference/ names must appear in the SWEEP'S OWN
# OUTPUT. The previous form of this guard re-ran aw_extract over reference/*.md and
# counted the result — a measurement of a SEPARATE call, not of the sweep, so dropping
# reference/*.md from the sweep's argument list reverted the whole extension with
# nothing red. Everything below reads $SANDBOX/run-artifacts.txt, the file the sweep
# above actually produced, off the same AW_DOCS_* lists the sweep was given.
aw_extract "$SANDBOX/aw-ref-only.txt" "${AW_DOCS_REF[@]}"
aw_extract "$SANDBOX/aw-nonref.txt" "${AW_DOCS_NONREF[@]}"
AW_REF_ONLY=$(LC_ALL=C comm -13 "$SANDBOX/aw-nonref.txt" "$SANDBOX/aw-ref-only.txt" | tr '\n' ' ')
# Non-vacuity FIRST: with no reference-only artifact, the sweep's output holds nothing
# that can attest reference/'s membership. Fail closed rather than pass on nothing — if
# the docs ever legitimately reach that state, this guard needs a different witness.
if [[ -n "${AW_REF_ONLY// /}" ]]; then
  pass "reference/ names artifact(s) no other doc does, so the sweep's output can witness its membership ($AW_REF_ONLY)"
else
  fail "reference/ names no artifact the other docs miss — direction 1 has lost its witness; re-witness the swept doc set another way"
fi
AW_REF_MISSING=""
for a in $AW_REF_ONLY; do
  grep -qxF "$a" "$SANDBOX/run-artifacts.txt" || AW_REF_MISSING="$AW_REF_MISSING $a"
done
if [[ -z "$AW_REF_MISSING" ]]; then
  pass "the sweep's own artifact list carries every reference/-only artifact (reference/*.md is really swept)"
else
  fail "the sweep's artifact list is missing reference/-only artifact(s) — reference/*.md dropped out of the swept doc set:$AW_REF_MISSING"
fi
# A floor on reference/'s contribution too, so gutting the artifact prose there shows
# up as a count change instead of silently shrinking what direction 1 can witness.
AW_REF_N=$(grep -c . "$SANDBOX/aw-ref-only.txt" || true)
if [[ "${AW_REF_N:-0}" -ge 20 ]]; then
  pass "reference/*.md contributes its usual bulk of artifact names ($AW_REF_N artifact(s))"
else
  fail "reference/*.md contributes its usual bulk of artifact names (got ${AW_REF_N:-0}, want >=20)"
fi

# Direction 2, the mutation: a phantom artifact planted in a COPY of a reference doc
# must be extracted and reported unowned. The plant goes in a scratch copy of the doc
# set — never in the tree — and rides the real aw_extract + aw_unowned path.
AW_MUT=$SANDBOX/aw-mutant
mkdir -p "$AW_MUT"
cp "$SKILL_DIR/reference/continue.md" "$AW_MUT/continue.md"
printf '\nRe-read `$RUN/aw-phantom-artifact.tsv` before resuming.\n' >> "$AW_MUT/continue.md"
aw_extract "$SANDBOX/aw-mut-artifacts.txt" "$AW_MUT/continue.md"
expect "the planted phantom is extracted from a reference doc" \
  grep -qxF 'aw-phantom-artifact.tsv' "$SANDBOX/aw-mut-artifacts.txt"
AW_MUT_UNOWNED=$(aw_unowned "$SANDBOX/aw-mut-artifacts.txt")
case " $AW_MUT_UNOWNED " in
  *" aw-phantom-artifact.tsv "*)
    pass "a phantom \$RUN/ artifact in a reference doc is reported unowned (non-vacuity of the extension)" ;;
  *)
    fail "a phantom \$RUN/ artifact in a reference doc is reported unowned (got:$AW_MUT_UNOWNED)" ;;
esac
# The mutant's OTHER artifacts — the ones continue.md really names — must not be
# swept up with it, or the extension would be reporting false positives on a doc
# whose every artifact has a proper writer.
AW_MUT_FALSE=""
for a in $AW_MUT_UNOWNED; do
  [[ "$a" = "aw-phantom-artifact.tsv" ]] || AW_MUT_FALSE="$AW_MUT_FALSE $a"
done
if [[ -z "$AW_MUT_FALSE" ]]; then
  pass "the reference doc's real artifacts all resolve to a writer (no false positives from the extension)"
else
  fail "the extension reports reference/continue.md artifact(s) as unowned:$AW_MUT_FALSE"
fi

# The allowlist must not rot: an entry no doc references anymore is a stale
# declaration, not a live exemption.
AW_STALE=""
for a in $AW_ALLOWLIST; do
  grep -qxF "$a" "$SANDBOX/run-artifacts.txt" || AW_STALE="$AW_STALE $a"
done
if [[ -z "$AW_STALE" ]]; then
  pass "every hand-written allowlist entry is still referenced by the docs"
else
  fail "stale hand-written allowlist entr(ies) — no doc references:$AW_STALE"
fi

# The doc and the enforcement must not be able to disagree about which files are
# exempt. reference/state-files.md's hand-written section used to state the set as a
# prose count ("the three hand-written artifacts"), which is a claim nothing checked;
# it is asserted item for item here instead, in both directions.
AW_DOC=$SANDBOX/aw-doc.txt
awk '/^## The hand-written artifacts/{t=1; next} t && /^## /{t=0} t' \
  "$SKILL_DIR/reference/state-files.md" \
  | grep -ohE '`[A-Za-z0-9._-]+\.(tsv|txt|md|env|sh|gz)`' | tr -d '`' | sort -u > "$AW_DOC"
printf '%s\n' $AW_ALLOWLIST | sort -u > "$SANDBOX/aw-list.txt"
if [[ -s "$AW_DOC" ]] && cmp -s "$AW_DOC" "$SANDBOX/aw-list.txt"; then
  pass "reference/state-files.md names exactly the lint's hand-written allowlist"
else
  fail "reference/state-files.md and AW_ALLOWLIST disagree (doc: $(tr '\n' ' ' < "$AW_DOC")| lint: $(tr '\n' ' ' < "$SANDBOX/aw-list.txt"))"
fi
refute "the hand-written section states the set as a list, not as a prose count" \
  grep -qE '^## The (two|three|four|five) hand-written artifacts' "$SKILL_DIR/reference/state-files.md"

# KNOWN RESIDUAL, recorded rather than hidden. The runtime-composed fallback
# (a stem the scripts know plus a `$VAR.<suffix>` that is written to) is what
# legitimately certifies the `test-baseline.*` / `test-<label>.failures.txt` family,
# where run-check.sh writes "$OUT.status" and only its CALLER knows the stem. The
# same looseness means any `*.tsv` whose stem is mentioned anywhere can ride an
# unrelated `"$RUN/yaml-gate-$LABEL.tsv"`-shaped write. Allowlisted entries are
# skipped before the fallback is consulted, so it cannot mask a declared exemption —
# but it could mask a NEW unowned `.tsv`. Tightening it needs the composed
# variable tied back to its stem, which today lives in the phase prose, not in a
# script. That is successor work, not something to paper over with an allowlist.
fi

if t "fixed-once lint: every comm invocation under scripts/ is LC_ALL=C-pinned"; then
# producer-idempotence.sh snapshotted under `LC_ALL=C sort` but ran its `comm -13`
# delta in the ambient locale, so BSD comm reported a line present in BOTH sets as
# new and the `??` handler rm -rf'd a pre-existing untracked file — the same defect
# handoff-structural.sh and gate.sh had already fixed, one instance the sweep
# missed. Whole-line comments are skipped: the rationale paragraphs that DISCUSS
# comm are not invocations.
COMM_LINES=$SANDBOX/comm-lines.txt
: > "$COMM_LINES"
for f in "$SKILL_DIR"/scripts/*.sh; do
  grep -v '^[[:space:]]*#' "$f" | grep -nE '(^|[^A-Za-z0-9_.-])comm[[:space:]]+-' \
    | sed "s#^#$(basename "$f"):#" >> "$COMM_LINES"
done
COMM_N=$(grep -c . "$COMM_LINES" || true)
# Non-vacuity FIRST — an extraction that finds nothing must fail, never pass.
if [[ "${COMM_N:-0}" -gt 0 ]]; then
  pass "comm-invocation extraction from scripts/ is non-empty ($COMM_N invocation(s))"
else
  fail "comm-invocation extraction from scripts/ is non-empty (got 0 — extraction broke)"
fi
COMM_UNPINNED=$(grep -v 'LC_ALL=C' "$COMM_LINES" | tr '\n' ' ' || true)
if [[ -z "$COMM_UNPINNED" ]]; then
  pass "every comm invocation under scripts/ carries LC_ALL=C on the same line"
else
  fail "unpinned comm invocation(s) — an ambient-locale delta mis-reports shared lines as new: $COMM_UNPINNED"
fi
# The one comm the ORCHESTRATOR runs by hand (Phase 7's failure-set check) is the
# same class and is pinned in the doc, both sides of the comparison included.
expect "phases/7-execution.md's failure-set comm is LC_ALL=C-pinned" \
  grep -qF 'LC_ALL=C comm -13' "$SKILL_DIR/phases/7-execution.md"
fi

if t "fixed-once lint: every env-fed ledger row is sanitized before it is written"; then
# log-spawn.sh was the one ledger that did not collapse tabs/newlines out of its
# fields, so a conflict path containing a tab shifted every column after it and
# silently corrupted spawn-summary.sh's tallies. Discovery is by row SHAPE, not by
# script name: a variable assigned from its OWN env value (`X=$(f "${X:-}")`) that
# then lands in a tab-separated printf is a ledger field, and a ledger field must
# be either collapsed or constrained to a closed set before it reaches the row.
ls_norm() { # code lines only, backslash-continuations joined into one statement
  grep -v '^[[:space:]]*#' "$1" | sed -e :a -e '/\\$/N; s/\\\n//; ta'
}
LS_LEDGERS=""
for f in "$SKILL_DIR"/scripts/*.sh; do
  norm=$(ls_norm "$f")
  rows=$(printf '%s\n' "$norm" | grep -E 'printf' | grep -F '\t' || true)
  [[ -n "$rows" ]] || continue
  fields=""
  for v in $(printf '%s\n' "$norm" | grep -oE '^[[:space:]]*[A-Z][A-Z0-9_]*=' | tr -d ' =' | sort -u); do
    printf '%s\n' "$norm" | grep -qE "^[[:space:]]*$v=.*[\$]\{$v:[-?]" || continue
    printf '%s\n' "$rows" | grep -qE "[\$]\{?$v[^A-Za-z0-9_]" || continue
    fields="$fields $v"
  done
  [[ -n "$fields" ]] || continue
  b=$(basename "$f")
  LS_LEDGERS="$LS_LEDGERS $b"
  for v in $fields; do
    if printf '%s\n' "$norm" | grep -qE "^[[:space:]]*$v=[\$]\((collapse|sanitize)" \
       || printf '%s\n' "$norm" | grep -qE "case[[:space:]]+\"[\$]\{?$v" ; then
      pass "$b: ledger field $v is sanitized (collapsed, or validated against a closed set)"
    else
      fail "$b: ledger field $v reaches the TSV row unsanitized — a tab in it shifts every later column"
    fi
  done
done
# Non-vacuity: the shape scan must still find the ledger writers it was built for.
if [[ -n "$LS_LEDGERS" ]]; then
  pass "env-fed TSV ledger discovery is non-empty ($(printf '%s' "$LS_LEDGERS" | wc -w | tr -d ' ') script(s):$LS_LEDGERS)"
else
  fail "env-fed TSV ledger discovery is non-empty (got 0 — extraction broke)"
fi
# The row-shape scan cannot see the non-TSV per-run ledgers (learnings.md's bullet,
# context.env's KEY=VALUE line), so the log-*/record-* family is swept by name too:
# every one of them takes free-form env fields and must sanitize them. A rejection
# (record-context.sh refuses a value carrying a newline) counts as a sanitizer.
LS_FAMILY_N=0
for f in "$SKILL_DIR"/scripts/log-*.sh "$SKILL_DIR"/scripts/record-*.sh; do
  [[ -f "$f" ]] || continue
  LS_FAMILY_N=$((LS_FAMILY_N + 1))
  b=$(basename "$f")
  if grep -qE '^(collapse|sanitize)\(\)' "$f" || grep -q 'contains a newline' "$f"; then
    pass "$b sanitizes its env fields (collapse helper, or an explicit rejection)"
  else
    fail "$b writes env fields into a per-run ledger with no collapse/reject step"
  fi
done
if [[ "$LS_FAMILY_N" -gt 0 ]]; then
  pass "the log-*/record-* ledger family is non-empty ($LS_FAMILY_N script(s))"
else
  fail "the log-*/record-* ledger family is non-empty (got 0 — glob broke)"
fi
fi

if t "fixed-once lint: plan task headings are matched with plan-slice.sh's anchor"; then
# spawn-summary.sh counted expected tasks with `/^### T/`, which also matches prose
# headings ("### Testing notes") and manufactured a false skipped-task signal, while
# plan-slice.sh had used the tight anchor all along. Every literal `### T` in script
# CODE must carry the full `^### T[0-9]+:` anchor (plan-slice.sh's per-task form
# composes the id into the pattern and so has no literal `### T` to check).
TA_LINES=$SANDBOX/task-anchor-lines.txt
: > "$TA_LINES"
for f in "$SKILL_DIR"/scripts/*.sh; do
  grep -v '^[[:space:]]*#' "$f" | grep -nF '### T' | sed "s#^#$(basename "$f"):#" >> "$TA_LINES"
done
TA_N=$(grep -c . "$TA_LINES" || true)
# Non-vacuity FIRST.
if [[ "${TA_N:-0}" -gt 0 ]]; then
  pass "plan-task-heading extraction from scripts/ is non-empty ($TA_N line(s))"
else
  fail "plan-task-heading extraction from scripts/ is non-empty (got 0 — extraction broke)"
fi
TA_LOOSE=$(grep -vF '^### T[0-9]+:' "$TA_LINES" | tr '\n' ' ' || true)
if [[ -z "$TA_LOOSE" ]]; then
  pass "every script matching plan task headings uses plan-slice.sh's ^### T[0-9]+: anchor"
else
  fail "task-heading match(es) looser than ^### T[0-9]+: — prose headings would be counted as tasks: $TA_LOOSE"
fi
fi

if t "ordering lint: Phase 8's load-bearing sequence survives an edit"; then
# Phase 8's order is prose, and prose drifts: the spawn cross-check used to run
# AFTER the commit that git rm's PLAN.md, so `logged N of ~M expected` always
# compared against zero and the undispatched-task detector could never fire. Two
# crude textual guards — exactly the class of drift this catches.
F8=$SKILL_DIR/phases/8-finalize.md
SS_LINE=$(grep -nF 'spawn-summary.sh' "$F8" | head -1 | cut -d: -f1)
RM_LINE=$(grep -nE 'git rm .*PLAN\.md' "$F8" | head -1 | cut -d: -f1)
if [[ -n "$SS_LINE" ]] && [[ -n "$RM_LINE" ]]; then
  pass "phases/8-finalize.md names both spawn-summary.sh and the PLAN.md removal"
else
  fail "phases/8-finalize.md names both spawn-summary.sh and the PLAN.md removal (spawn-summary=${SS_LINE:-<none>}, git rm=${RM_LINE:-<none>})"
fi
if [[ -n "$SS_LINE" ]] && [[ -n "$RM_LINE" ]] && [[ "$SS_LINE" -lt "$RM_LINE" ]]; then
  pass "spawn-summary.sh runs textually BEFORE the git rm of PLAN.md (the N-of-M check is live)"
else
  fail "spawn-summary.sh must appear before the git rm of PLAN.md (spawn-summary=${SS_LINE:-<none>}, git rm=${RM_LINE:-<none>})"
fi
# The baseline-advance commit is the run's LAST write, so its stated file list has
# to carry .kairos/migration-log.md — the finalize summary, the Template feedback
# and Phase 7's final task entry all ride it or the run ends dirty.
expect "the baseline-advance commit stages .kairos/migration-log.md" \
  grep -qE '^git add .*\.kairos/migration-log\.md' "$F8"
expect "phases/7-execution.md says its final task entry is carried by Phase 8" \
  grep -qF 'migration-log.md' "$SKILL_DIR/phases/7-execution.md"
# The clear is the write that makes Continue mode unreachable, so it must sit in
# the SAME code block as the commit — a clear in its own block re-opens the
# conversation-gap crash window (block gone, baseline advanced, nothing to resume
# into). Textual guard: the fenced block that runs ACTION=clear also commits.
F8_CLEAR_FUSED=$(awk '/^```bash$/{buf=""; inb=1; next}
  /^```$/{if (inb && buf ~ /ACTION=clear/ && buf ~ /git commit/) found=1; inb=0}
  inb{buf=buf "\n" $0} END{print found+0}' "$F8")
if [[ "$F8_CLEAR_FUSED" = 1 ]]; then
  pass "the ACTION=clear call shares one fenced block with the baseline-advance commit"
else
  fail "the ACTION=clear call must share one fenced block with the baseline-advance commit (the clear-to-commit crash window is a conversation gap otherwise)"
fi
fi

if t "twin-helper lint: the resolution ledger's norm() copies never diverge"; then
# log-resolution.sh owns the resolution-row format; handoff-structural.sh,
# dropped-template-changes.sh and spawn-summary.sh each carry a copy of its norm()
# because no shared shell lib exists to factor it into (lib/ holds awk only). A
# divergent copy re-opens the double-count the normalization closed: a legacy
# 3-field shard row and its normalized 4-field aggregate twin both surviving the
# de-dup, inflating the planner's handoff tallies, double-scanning dropped-template
# evidence, and over-counting Phase 8's "resolutions logged" fact.
NORM_SIGS=$SANDBOX/norm-sigs.tsv
: > "$NORM_SIGS"
for s in log-resolution.sh handoff-structural.sh dropped-template-changes.sh spawn-summary.sh; do
  awk -v src="$s" '/function norm\(line,/ {
    sig = $0
    for (i = 1; i <= 3; i++) { if ((getline l) <= 0) break; sig = sig "|" l }
    gsub(/[[:space:]]+/, "", sig)
    print src "\t" sig
  }' "$SKILL_DIR/scripts/$s" >> "$NORM_SIGS"
done
# Non-vacuity per file FIRST: a renamed helper must fail, never quietly vanish
# from the comparison.
for s in log-resolution.sh handoff-structural.sh dropped-template-changes.sh spawn-summary.sh; do
  if grep -q "^$s" "$NORM_SIGS"; then
    pass "$s carries a norm() copy"
  else
    fail "$s carries a norm() copy (extraction found none — renamed or removed)"
  fi
done
NORM_UNIQ=$(cut -f2 "$NORM_SIGS" | sort -u | grep -c .)
if [[ "$NORM_UNIQ" -eq 1 ]]; then
  pass "every norm() copy is identical (whitespace aside)"
else
  fail "the norm() copies diverged ($NORM_UNIQ variants) — log-resolution.sh is the format owner; re-sync the other two"
fi
fi

if t "anchor lint: the re-spawn REGION-ordinal contract survives a reword"; then
# A needs-input round trip is the one place the positional ordinal can silently
# go wrong: the re-spawned resolver sees a file whose earlier markers are gone,
# so re-counting logs the verdict against somebody else's region — and
# dropped-template-changes.sh, which re-derives regions positionally, then hands
# the planner a DIFFERENT region's template text as evidence, in range and
# error-free. The contract is prose in two files and unenforceable mechanically
# (log-resolution.sh sees only a valid integer), so these needles keep its two
# halves — the orchestrator passes the ordinal, the resolver uses it verbatim —
# from being reworded away independently.
expect "phases/5-structural.md requires the re-spawn prompt to state the ordinal verbatim" \
  grep -qF "must state the needs-input region's \`REGION\` ordinal verbatim" "$SKILL_DIR/phases/5-structural.md"
expect "phases/5-structural.md forbids the re-spawned resolver re-counting the file" \
  grep -qF 'rather than re-counting the file' "$SKILL_DIR/phases/5-structural.md"
# Anchor matches, not verbatim sentences: the contract is that BOTH ideas are
# stated (use the given ordinal on a re-spawn; REGION is positional in the file
# as first received), not their exact 2026 wording — a meaning-preserving
# copyedit must not fail the lint and force a paired test edit.
expect "agents/conflict-resolver.md tells a re-spawned resolver to use the given ordinal" \
  grep -qiE 're-?spawn.*ordinal' "$SKILL_DIR/agents/conflict-resolver.md"
expect "agents/conflict-resolver.md defines REGION positionally (file as first received)" \
  grep -qiE 'position in the file as you (first )?received it' "$SKILL_DIR/agents/conflict-resolver.md"
fi

# =============================================================================
# The tool-call-boundary class. Each phase code block runs in a FRESH shell, so a
# variable set in an earlier tool call is empty in the next one — and an empty
# variable never announces itself: it satisfies a loop vacuously, makes
# `git log $A..HEAD` an empty range, turns `${TARGET:0:7}` into nothing in a commit
# message, makes `git reset --soft` a no-op reset to HEAD, and lets a
# record-context call write `BASE=` into the anchor itself. Four such leaks shipped
# at once (the finalize squash, the materialize extraction, Phase 3's env setup,
# Phase 3.5's common paths), which is what makes this a class rather than four bugs.
# Closed by convention — every consuming block opens by re-reading the anchor — and
# the convention is only closed if it is linted.
# The WHOLE preamble line, not a prefix. A prefix check has two holes, and both were
# open: strip the `| grep . || echo "FAIL: …"` clause from every preamble in a phase
# file and the sweep stayed green over blocks whose lost values no longer announce
# themselves at all; drop the `RUN=.kairos/migration/state` assignment and the sweep
# stayed green over blocks where `$RUN` — and therefore every `ctx` read and every
# `RUN=$RUN` handed to a script — is empty. Both are single-clause edits to the one
# line this whole class of defect is closed by, so the comparison is the full line.
ANCHOR_PRE='RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }'
# The canonical anchor keys, taken from SKILL.md itself rather than restated here:
# a lint carrying its own copy of the list is the drift it exists to prevent.
ANCHOR_KEY_LINE='At every phase start'
ANCHOR_KEYS=$(grep -F "$ANCHOR_KEY_LINE" "$SKILL_DIR/SKILL.md" \
  | grep -oE '`[A-Z][A-Z0-9_]*`' | tr -d '`' | sort -u | tr '\n' ' ')
if t "fixed-once lint: the anchor-read preamble opens every cross-phase code block"; then
# Non-vacuity first, and on the KEY LIST before anything else: an extraction that
# broke would silently find no keys and pass every block below.
ANCHOR_KEY_N=$(printf '%s' "$ANCHOR_KEYS" | wc -w | tr -d ' ')
if [[ "${ANCHOR_KEY_N:-0}" -ge 10 ]]; then
  pass "the canonical anchor-key list extracts from SKILL.md ($ANCHOR_KEY_N keys)"
else
  fail "the canonical anchor-key list extracts from SKILL.md (got ${ANCHOR_KEY_N:-0} — SKILL.md's '$ANCHOR_KEY_LINE' sentence moved or lost its backticked keys)"
fi
expect "SKILL_DIR is one of the canonical anchor keys (recorded at pre-flight)" \
  bash -c "printf '%s' '$ANCHOR_KEYS' | grep -qw SKILL_DIR"
# -f <file>, not an inline pattern: the preamble carries double quotes, so embedding
# it in a `bash -c` string is a quoting accident waiting to happen.
ANCHOR_PRE_FILE=$SANDBOX/anchor-preamble.txt
printf '%s\n' "$ANCHOR_PRE" > "$ANCHOR_PRE_FILE"
expect "SKILL.md states the preamble itself, verbatim and in FULL, as the standard opening" \
  grep -qF -f "$ANCHOR_PRE_FILE" "$SKILL_DIR/SKILL.md"
# The two clauses a prefix check could not see, asserted separately against SKILL.md's
# own line (found by a LOOSE anchor) so a regression names the clause that went missing
# rather than reading as "the canonical statement moved".
SK_PRE_LINE=$SANDBOX/skill-md-preamble.txt
grep -F 'ctx() {' "$SKILL_DIR/SKILL.md" > "$SK_PRE_LINE" || true
if [[ "$(grep -c . "$SK_PRE_LINE" || true)" -ge 1 ]]; then
  pass "SKILL.md's preamble line is locatable by a loose anchor (ctx() {)"
else
  fail "SKILL.md's preamble line is locatable by a loose anchor (ctx() { — the canonical statement is gone entirely)"
fi
expect "SKILL.md's canonical preamble carries the RUN assignment" \
  grep -qF 'RUN=.kairos/migration/state;' "$SK_PRE_LINE"
expect "SKILL.md's canonical preamble carries the FAIL echo (a lost key announces itself)" \
  grep -qF 'missing from $RUN/context.env' "$SK_PRE_LINE"

ANCHOR_DOCS=""
# reference/bellwether-detection.md is kept in the sweep defensively. F15 moved its
# formerly STANDALONE runnable copy of Phase 2's bootstrap invocation into phases/2,
# leaving the doc rationale-only (zero fenced blocks today, so the sweep finds nothing
# there). It stays in the loop so that if a runnable block ever returns to the doc, the
# bare-anchor-read leak this class exists to catch is caught the moment it lands.
for f in "$SKILL_DIR"/phases/*.md "$SKILL_DIR/reference/continue.md" \
         "$SKILL_DIR/reference/abort.md" "$SKILL_DIR/reference/bellwether-detection.md"; do
  ANCHOR_DOCS="$ANCHOR_DOCS $f"
done
ANCHOR_REPORT=$SANDBOX/anchor-report.txt
# One pass over every fenced block of every swept doc. Emits one line per finding
# plus a SEEN/PRE/EXEMPT census, so the assertions below read a fact rather than
# re-deriving one. Bare `sed -n 's/^KEY=//p'` counts as a read too: keys whose
# ABSENCE is the record of something (SQUASH_ON_FINISH, COMMON_CACHE, TEMPLATE_PATH,
# TEMPLATE_LOCAL_BRANCH) must not be read through `ctx`, which reports empty as a
# failure. A block that ESTABLISHES values instead of consuming them says so with
# `# anchor-exempt: <why>`.
# shellcheck disable=SC2016
awk -v keys="$ANCHOR_KEYS" -v pre="$ANCHOR_PRE" '
  BEGIN { n = split(keys, K, " ") }
  # A block CONSUMES a key two ways, and both must count: `$KEY` and a bare name on
  # an `export` line. Phase 3 leaked through the second form — `export SYNTH CACHE
  # BASE TARGET RUN` hands four cross-phase values to the classifier without a
  # single `$` in sight, so a lint watching only for sigils would have called the
  # worst of the four leaks clean.
  function consumes(text, k) {
    if (text ~ ("[$]" k "[^A-Za-z0-9_]") || text ~ ("[$]" k "$") || text ~ ("[$][{]" k "[^A-Za-z0-9_]")) return 1
    if (text ~ ("(^|\n)[[:space:]]*export([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)*[[:space:]]+" k "([^A-Za-z0-9_=]|$)")) return 1
    return 0
  }
  /^[[:space:]]*```/ {
    if (inb) {
      refs = ""; first = 0
      for (i = 1; i <= n; i++) {
        k = K[i]
        if (consumes(buf, k)) refs = refs " " k
      }
      if (refs != "") {
        print "SEEN " FILENAME ":" start
        has_pre = (index(buf, pre) > 0)
        exempt  = (index(buf, "# anchor-exempt") > 0)
        if (exempt) {
          print "EXEMPT " FILENAME ":" start
          # the reason is the point of the marker: bare markers are not exemptions
          if (buf !~ /# anchor-exempt:[[:space:]]*[^[:space:]]/) print "BARE-EXEMPT " FILENAME ":" start
        } else if (!has_pre) {
          print "NO-PREAMBLE " FILENAME ":" start refs
        } else {
          print "PRE " FILENAME ":" start
          for (i = 1; i <= n; i++) {
            k = K[i]
            if (refs !~ ("(^| )" k "$") && refs !~ ("(^| )" k " ")) continue
            got = (index(buf, "ctx " k) > 0) || (index(buf, "s/^" k "=//p") > 0) \
                  || (buf ~ ("(^|\n)[[:space:]]*" k "="))
            if (!got) print "UNREAD " FILENAME ":" start " " k
          }
          # the preamble has to come FIRST: a re-read placed after the consuming
          # statement documents the convention without applying it.
          # nl from split(), never length(L): length() over an ARRAY is a GNU/mawk
          # extension that the awk on the Ubuntu seam is not promised to carry.
          nl = split(buf, L, "\n")
          pl = 0; rl = 0
          for (j = 1; j <= nl; j++) {
            if (!pl && index(L[j], pre) > 0) pl = j
            if (!rl) for (i = 1; i <= n; i++) {
              k = K[i]
              if (consumes("\n" L[j] "\n", k)) { rl = j; break }
            }
          }
          if (pl && rl && pl > rl) print "LATE-PREAMBLE " FILENAME ":" start
        }
      }
      inb = 0
    } else { inb = 1; start = FNR; buf = "" }
    next
  }
  inb { buf = buf $0 "\n" }
' $ANCHOR_DOCS > "$ANCHOR_REPORT"

A_SEEN=$(grep -c '^SEEN ' "$ANCHOR_REPORT" || true)
A_PRE=$(grep -c '^PRE ' "$ANCHOR_REPORT" || true)
A_EX=$(grep -c '^EXEMPT ' "$ANCHOR_REPORT" || true)
# Non-vacuity: the block scan must still find the ~35 consuming blocks it was built
# for. A fence-parsing regression would otherwise report a clean sweep of nothing.
if [[ "${A_SEEN:-0}" -ge 25 ]] && [[ "${A_PRE:-0}" -ge 20 ]]; then
  pass "cross-phase code-block discovery is non-empty ($A_SEEN consuming block(s), $A_PRE with the preamble, $A_EX exempt)"
else
  fail "cross-phase code-block discovery is non-empty (got seen=${A_SEEN:-0} pre=${A_PRE:-0} — fence/key extraction broke)"
fi

A_MISSING=$(sed -n 's/^NO-PREAMBLE //p' "$ANCHOR_REPORT" | tr '\n' ';')
if [[ -z "$A_MISSING" ]]; then
  pass "every swept phase code block consuming a cross-phase value opens by re-reading the anchor"
else
  fail "code block(s) consume a cross-phase value with no anchor-read preamble (and no '# anchor-exempt:'): $A_MISSING"
fi
A_UNREAD=$(sed -n 's/^UNREAD //p' "$ANCHOR_REPORT" | tr '\n' ';')
if [[ -z "$A_UNREAD" ]]; then
  pass "every cross-phase key a block references is read from the anchor in that same block"
else
  fail "key(s) referenced but never read from the anchor in their own block (dead across the tool-call boundary): $A_UNREAD"
fi
A_LATE=$(sed -n 's/^LATE-PREAMBLE //p' "$ANCHOR_REPORT" | tr '\n' ';')
if [[ -z "$A_LATE" ]]; then
  pass "the preamble opens the block — never placed after the statement that consumes the value"
else
  fail "anchor-read preamble appears AFTER the first consuming statement: $A_LATE"
fi
A_BARE=$(sed -n 's/^BARE-EXEMPT //p' "$ANCHOR_REPORT" | tr '\n' ';')
if [[ -z "$A_BARE" ]]; then
  pass "every '# anchor-exempt' marker states why the block establishes rather than consumes"
else
  fail "bare '# anchor-exempt' marker(s) with no reason: $A_BARE"
fi
fi

if t "fixed-once lint: continue.md's context-key list matches SKILL.md's canonical list"; then
# A resume that reads a shortened list omits values its own later steps consume —
# and both lists are prose, so they drift silently. continue.md restates SKILL.md's
# list in FULL (no `COMMON_*` glob) precisely so the two can be compared.
CONT_KEY_LINE='The canonical anchor keys, as last recorded'
CONT_KEYS=$(grep -F "$CONT_KEY_LINE" "$SKILL_DIR/reference/continue.md" \
  | grep -oE '`[A-Z][A-Z0-9_]*`' | tr -d '`' | sort -u | tr '\n' ' ')
CONT_KEY_N=$(printf '%s' "$CONT_KEYS" | wc -w | tr -d ' ')
if [[ "${CONT_KEY_N:-0}" -ge 10 ]]; then
  pass "continue.md's context-key list extracts ($CONT_KEY_N keys)"
else
  fail "continue.md's context-key list extracts (got ${CONT_KEY_N:-0} — the '$CONT_KEY_LINE' line moved, or the list was globbed back to COMMON_*)"
fi
if [[ "$CONT_KEYS" = "$ANCHOR_KEYS" ]]; then
  pass "continue.md's context-key list is exactly SKILL.md's canonical list"
else
  fail "continue.md's context-key list diverges from SKILL.md's — continue: [$CONT_KEYS] canonical: [$ANCHOR_KEYS]"
fi
expect "continue.md points at SKILL.md as the list's owner" \
  bash -c "grep -F \"$CONT_KEY_LINE\" -A2 '$SKILL_DIR/reference/continue.md' | grep -qF 'SKILL.md'"
fi

if t "fixed-once lint: the four known tool-call-boundary leaks stay fixed"; then
F8=$SKILL_DIR/phases/8-finalize.md
F25=$SKILL_DIR/phases/2.5-materialize.md
F3=$SKILL_DIR/phases/3-classify.md
F35=$SKILL_DIR/phases/3.5-collect-common.md

# C8 — the squash read $PREV_SHA from the step-5 tool call, so it was empty and
# `git reset --soft` reset to HEAD: a silent no-op AFTER the plan removal and
# baseline advance had already been committed, with the block that carried the SHA
# deleted by `clear`. The squash now reads the anchor, and step 5 re-anchors what it
# reads from the manifest in the same call.
expect "phase 8's squash reads PREV_SHA from the anchor" \
  bash -c "grep -qF 'PREV_SHA=\$(ctx PREV_SHA)' '$F8'"
expect "phase 8's squash still resets to the SHA (both branch modes)" \
  grep -qF 'git reset --soft $PREV_SHA' "$F8"
expect "phase 8 re-anchors previous_sha in the call that reads it off the manifest" \
  bash -c "grep -A2 -F 'in_progress.previous_sha' '$F8' | grep -qF 'record-context.sh'"
expect "phase 8 says an empty PREV_SHA must not be reset over" \
  bash -c "grep -qiE 'reset --soft.*(empty|no-op)|empty argument' '$F8'"

# A1 — the materialize invocation piped the script into sed, so \$? was sed's and a
# failed materialization surfaced two phases later as an empty \$SYNTH.
expect "phase 2.5 captures materialize.sh's exit status before extracting SYNTH" \
  bash -c "grep -qF 'MAT_RC=\$?' '$F25'"
refute "phase 2.5 no longer pipes materialize.sh straight into sed" \
  grep -qE 'materialize\.sh" *\| *sed' "$F25"
expect "phase 2.5 stops the phase on a non-zero exit" \
  bash -c "grep -qF 'MAT_RC' '$F25' && grep -qiE 'stop the phase|exit 1' '$F25'"

# A2/A3 — Phase 3 classified against whatever the Phase 2.5 call had left in the
# shell; Phase 3.5 read the common paths the same way, and a lost COMMON_CACHE
# drops EVERY common-library upgrade-file behind a plausible skip tally.
for k in SYNTH CACHE BASE TARGET; do
  expect "phase 3 reads $k from the anchor" bash -c "grep -qF '(ctx $k)' '$F3'"
done
expect "phase 3.5 reads COMMON_REPO_PATH from the anchor" \
  bash -c "grep -qF '(ctx COMMON_REPO_PATH)' '$F35'"
expect "phase 3.5 reads COMMON_CACHE from the anchor (bare form — empty is an answer)" \
  bash -c "grep -qF \"s/^COMMON_CACHE=//p\" '$F35'"
expect "phase 3.5 says a lost common path drops every common upgrade-file" \
  bash -c "grep -qiE 'skip-no-cache.*(every|all)|(every|all).*common-library upgrade-file' '$F35'"

# A4 — SKILL_DIR is recorded by the script that knows it, at the first write to the
# anchor; every later block locates the scripts through it.
expect "pre-flight.sh records SKILL_DIR into the anchor" \
  bash -c "grep -qF 'SKILL_DIR=\$(dirname \"\$HERE\")' '$SKILL_DIR/scripts/pre-flight.sh'"
expect "reference/pre-flight.md documents SKILL_DIR as a recorded key" \
  bash -c "grep -F 'Record run context' '$SKILL_DIR/reference/pre-flight.md' | grep -q 'SKILL_DIR'"

# Story 20 — the salvage step's completion was written for the arm with a checkout,
# so an abort BEFORE Phase 4 (no block at all) discarded a populated Q&A ledger.
AB=$SKILL_DIR/reference/abort.md
expect "abort's salvage covers the arms with no block and no branch" \
  bash -c "grep -F 'Salvage standing intent' '$AB' | grep -qiE 'every arm|no block'"
expect "abort's no-block arm runs the salvage before exiting cleanly" \
  bash -c "grep -F 'No block at all' '$AB' | grep -qi 'salvage'"
refute "abort's no-block arm is no longer described as a plain no-op" \
  bash -c "grep -F 'No block at all' '$AB' | grep -q 'abort is a no-op'"

# Story 21 — resuming into planning with no upgrade-file list must re-run
# classification, not pass the completeness gate vacuously.
CD=$SKILL_DIR/reference/continue.md
expect "continue.md's Phase 6 arm re-runs classification when upgrades-added.txt is absent" \
  bash -c "grep -F 'upgrades-added.txt' '$CD' | grep -qi 'phase 3'"
expect "phases/6-planning.md documents plan-completeness.sh's exit 2 as 'inputs absent'" \
  bash -c "grep -F 'exit 2' '$SKILL_DIR/phases/6-planning.md' | grep -qi 'absent'"
fi

if t "fixed-once lint: the conflict-marker scan is documented as final-gate-only"; then
# gate.sh runs the marker scan under `if [[ "$LABEL" = final ]]` and nowhere else, so a
# postmerge/midplan card carries NO conflict-markers row — not even an INCOMPLETE one.
# Phase 5's gate step used to list "the conflict-marker scan" among the checks it
# sequences, which invites reading a postmerge PASS as proof the markers are gone: the
# one misreading the label split can cause, and the failure the resolver hand-off
# check exists to catch instead. Both directions are asserted, because the honest
# version has to keep saying it at Phase 8, where the scan really does run.
G5=$SKILL_DIR/phases/5-structural.md
G8=$SKILL_DIR/phases/8-finalize.md
GDOC=$SKILL_DIR/reference/gates.md
expect "gate.sh runs the marker check at LABEL=final only" \
  grep -qF 'if [[ "$LABEL" = final ]]; then' "$SKILL_DIR/scripts/gate.sh"
# The guard alone proves nothing if the scan migrates out of it: extract the guarded
# span (guard line to its column-0 `fi`) and require the scan's candidate list —
# the marker check's one unmistakable fingerprint — to sit INSIDE it.
GFSPAN=$SANDBOX/gate-final-span.txt
awk '/^if \[\[ "\$LABEL" = final \]\]; then$/{grab=1} grab{print} grab && /^fi$/{exit}' \
  "$SKILL_DIR/scripts/gate.sh" > "$GFSPAN"
if [[ "$(grep -c . "$GFSPAN" || true)" -gt 5 ]] && grep -qF '.gate-marker-files' "$GFSPAN"; then
  pass "the marker scan itself sits inside the LABEL=final guard (span $(grep -c . "$GFSPAN") lines)"
else
  fail "the marker scan itself sits inside the LABEL=final guard (span $(grep -c . "$GFSPAN" || echo 0) lines; fingerprint .gate-marker-files $(grep -qF '.gate-marker-files' "$GFSPAN" && echo present || echo ABSENT))"
fi
G5_LEAD=$(grep -F 'it sequences build' "$G5" || true)
G8_LEAD=$(grep -F 'it sequences build' "$G8" || true)
# Non-vacuity FIRST: both leads must extract, or the two greps below prove nothing.
if [[ -n "$G5_LEAD" ]] && [[ -n "$G8_LEAD" ]]; then
  pass "the gate-step lead sentence extracts from both phases/5-structural.md and phases/8-finalize.md"
else
  fail "the gate-step lead sentence extracts from both phase files (5:'${G5_LEAD:0:40}' 8:'${G8_LEAD:0:40}' — the 'it sequences build' wording moved)"
fi
refute "phase 5's gate step does not list the conflict-marker scan among the checks it sequences" \
  bash -c "printf '%s' \"\$1\" | grep -q 'conflict-marker'" _ "$G5_LEAD"
expect "phase 8's gate step DOES list the conflict-marker scan (that label runs it)" \
  bash -c "printf '%s' \"\$1\" | grep -q 'conflict-marker'" _ "$G8_LEAD"
expect "phase 5 states the marker scan happens only at the final gate" \
  grep -qiF 'only at the final gate' "$G5"
expect "reference/gates.md says a postmerge/midplan PASS is not evidence the tree is marker-free" \
  grep -qiF 'evidence the tree is marker-free' "$GDOC"
expect "reference/gates.md names what covers the interval instead (the resolver's own hand-off check)" \
  bash -c "grep -A12 -F 'marker scan runs at' '$GDOC' | grep -qF 'agents/conflict-resolver.md'"

# The ask-user row's classification/SYNTH binding: gate.sh check 7 re-verifies
# classification-trees.tsv BEFORE it tallies, fails on drift or a missing binding, and
# degrades BOTH clean arms to INCOMPLETE when $SYNTH cannot be checked at all. A doc
# that describes only the tally lets an INCOMPLETE ask-user row read as a gate bug.
AUSEC=$SANDBOX/gates-askuser-section.txt
sed -n '/^## Ask-user enactment coverage/,/^## [^A]/p' "$GDOC" > "$AUSEC"
if [[ "$(grep -c . "$AUSEC" || true)" -gt 5 ]]; then
  pass "reference/gates.md's ask-user section extracts"
else
  fail "reference/gates.md's ask-user section extracts (the heading moved)"
fi
expect "the ask-user section names the classification/SYNTH binding it re-verifies" \
  grep -qF 'classification-trees.tsv' "$AUSEC"
expect "the ask-user section states the unverifiable-binding degradation to INCOMPLETE" \
  grep -qF 'INCOMPLETE' "$AUSEC"
expect "gate.sh really degrades that row rather than failing it" \
  bash -c "grep -qF 'AUST=INCOMPLETE' '$SKILL_DIR/scripts/gate.sh'"
fi

if t "the conflict-resolver spawn prompt carries the run dir and the skill dir"; then
# The role file's mandatory step is one log-resolution.sh call per resolved region,
# invoked as "$SKILL_DIR/scripts/log-resolution.sh" with RUN= — so a spawn prompt that
# names neither value dispatches a resolver that cannot log the verdicts its own role
# requires, and the planner then reviews a merge with an empty ledger. Phase 7's
# executor spawn already passes both; this asserts Phase 5's contract says so too.
CR=$SKILL_DIR/agents/conflict-resolver.md
P5=$SKILL_DIR/phases/5-structural.md
expect "the role file logs verdicts through \$SKILL_DIR/scripts/log-resolution.sh" \
  grep -qF '"$SKILL_DIR/scripts/log-resolution.sh"' "$CR"
expect "the role file states both paths arrive in the spawn prompt" \
  bash -c "grep -qF 'named in your spawn prompt' '$CR' && grep -qF 'SKILL_DIR' '$CR'"
PC=$SANDBOX/resolver-prompt-contract.txt
sed -n '/The prompt names/,/malformed/p' "$P5" > "$PC"
# Bounded on BOTH ends: a sed range never closes on its start line, so if the doc
# regresses to the pre-fix one-line wording ('The prompt names … malformed' together)
# the slice overruns to EOF and every needle below matches incidental prose. The cap
# is what makes the needles proof of the CONTRACT and not of the file.
PC_N=$(grep -c . "$PC" || true)
if [[ "${PC_N:-0}" -gt 2 ]] && [[ "${PC_N:-0}" -le 15 ]]; then
  pass "phase 5's resolver prompt contract extracts tightly ($PC_N lines)"
else
  fail "phase 5's resolver prompt contract extracts tightly (got ${PC_N:-0} lines — >15 means the '/malformed/' anchor no longer closes the range (one-line regression overruns to EOF); <3 means the anchors moved)"
fi
for needed in SKILL_DIR RUN qa-ledger.tsv intent-active.md log-resolution.sh; do
  expect "the resolver prompt contract names $needed" grep -qF "$needed" "$PC"
done
# Those whole-slice needles are necessary but NOT sufficient, and on their own they
# do not test the requirement at all: the slice already carries both names for
# other reasons — its range-start line points the subagent at
# `$SKILL_DIR/agents/conflict-resolver.md` (a path to READ, not a value to pass),
# the shard bullet names `$RUN/resolutions.<slug>.tsv`, and the closing sentence
# mentions "`$RUN` and `SKILL_DIR`" in a parenthetical about Phase 7. So the one
# bullet that actually states "the prompt must carry BOTH of these values" can be
# deleted outright and all five needles above still match. The requirement is a
# SINGLE line binding the two, so that is what is asserted: one bullet-shaped line
# inside the bounded slice naming RUN and SKILL_DIR together.
p5_binds_both_in_one_bullet() { # p5_binds_both_in_one_bullet <5-structural.md>
  sed -n '/The prompt names/,/malformed/p' "$1" \
    | grep -E '^[[:space:]]*-[[:space:]]' | grep -F 'SKILL_DIR' | grep -qF 'RUN'
}
expect "the resolver prompt contract binds RUN and SKILL_DIR in ONE requirement bullet" \
  p5_binds_both_in_one_bullet "$P5"

# --- non-vacuity: a copy of the phase file with that bullet replaced by a
# non-bullet sentence keeping the SAME words must turn the new needle red while
# every whole-slice needle above stays green — which is precisely the hole. The
# mutation is structural (drop the bullet the needle looks for), so it does not
# encode the bullet's current wording. phases/5-structural.md itself is untouched.
P5_MUT=$SANDBOX/p5-bullet-deleted.md
awk '/^[[:space:]]*-[[:space:]]/ && /SKILL_DIR/ && /RUN/ {
       print "     The role file logs each verdict through \"$SKILL_DIR/scripts/log-resolution.sh\" with RUN= set."
       next }
     { print }' "$P5" > "$P5_MUT"
refute "the mutant really dropped the bullet (sanity check on the fixture, not the lint)" \
  cmp -s "$P5_MUT" "$P5"
PC_MUT=$SANDBOX/resolver-prompt-contract-mutant.txt
sed -n '/The prompt names/,/malformed/p' "$P5_MUT" > "$PC_MUT"
for needed in SKILL_DIR RUN qa-ledger.tsv intent-active.md log-resolution.sh; do
  expect "the old whole-slice needle for $needed still matches the mutant (proof it was satisfiable without the requirement)" \
    grep -qF "$needed" "$PC_MUT"
done
refute "deleting the requirement bullet while keeping the incidental mentions is caught (non-vacuity proof)" \
  p5_binds_both_in_one_bullet "$P5_MUT"
expect "phase 7's executor spawn passes both values too (the same contract, stated)" \
  bash -c "grep -qF '\$SKILL_DIR' '$SKILL_DIR/phases/7-execution.md' && grep -qF 'SKILL_DIR is <absolute path to this skill>' '$SKILL_DIR/phases/7-execution.md'"
fi

if t "fixed-once lint: the ONE sanctioned hand-edit of .kairos/intent.md is declared"; then
# promote-intent.sh owns the file, and MATCH looks a fact up by its `- <date>: <fact>`
# bullet — so a line the parser rejected AS A LINE (a `* `/`+ ` bullet, a `-` with no
# space, a tab-indented bullet) has no fact to name and no action can reach it. That
# one deletion is the exception; the orphaned column-0 `guard:` is NOT, because the
# retire or update of the entry that OWNS it resolves it — swept, or adopted as that
# entry's own indented guard. The doc used to run the two cases together and instruct a
# bare hand-removal for both.
P5=$SKILL_DIR/phases/5-structural.md
refute "phases/5-structural.md no longer instructs an unqualified hand-removal of an unparseable line" \
  grep -qF 'so remove the stray line in the same edit' "$P5"
expect "phases/5-structural.md declares the wrong-style-bullet deletion as the sanctioned exception" \
  grep -qiF 'sanctioned hand-edit' "$P5"
expect "phases/5-structural.md routes the orphaned column-0 guard through the script instead" \
  bash -c "grep -F 'orphaned column-0' '$P5' | grep -qiE 'the script removes it|sweep'"
expect "phases/5-structural.md names update's adoption of an orphan under a guardless entry" \
  bash -c "grep -qiF 'adopted' '$P5'"
# The sweep is ENTRY-SCOPED, and the scope is OWNERSHIP: a retire/update rewrite takes
# the column-0 orphans owned by the MATCHED entry (adopted instead when that entry is
# guardless and neither GUARD nor DROP_GUARD was given) plus those owned by no entry at
# all, and every orphan owned by ANOTHER entry survives untouched whatever guards that
# entry already carries. So each rewrite needs BOTH rules, and a count of one of them is
# not the semantics: the unconditional sweep alone is the old "takes every column-0
# guard" behaviour (it de-guarded a foreign entry, which then vetted itself on whatever
# guard it had left), and the protect rule alone sweeps nothing. Order is load-bearing
# too — the exemption is done BY RULE ORDER, so a protect rule sitting after the
# unconditional sweep is dead code and the hole is back.
# The rule condition is `cls == "orphan"`, not the literal `/^guard:/` it once was:
# m_class routes a `guard:` hidden behind a whitespace-variant indent (NBSP/VT/FF) to the
# same column-0 orphan verdict, and a `/^guard:/` pattern would slip past its NBSP prefix
# (Finding 4). The two rewrites still carry BOTH rules, protect first — that contract is
# what this lint pins; only the spelling of the condition moved.
pi_rule_count() { # pi_rule_count <promote-intent.sh> protect|sweep
  case "$2" in
    protect) grep -cE '^[[:space:]]*cls[[:space:]]*==[[:space:]]*"orphan"[[:space:]]*&&[[:space:]]*index\(prot,' "$1" ;;
    sweep)   grep -cE '^[[:space:]]*cls[[:space:]]*==[[:space:]]*"orphan"[[:space:]]+\{[[:space:]]*next[[:space:]]*\}' "$1" ;;
    *)       echo "bad rule name: $2" >&2; return 2 ;;
  esac
}
# pi_sweep_scope_intact <promote-intent.sh> — both rules, in both rewrites, protect
# first. The mutation proofs below run THIS function, not a copy of its greps.
pi_sweep_scope_intact() {
  [[ "$(pi_rule_count "$1" protect)" = 2 ]] || return 1
  [[ "$(pi_rule_count "$1" sweep)" = 2 ]] || return 1
  awk '
    /^[[:space:]]*cls[[:space:]]*==[[:space:]]*"orphan"[[:space:]]*&&[[:space:]]*index\(prot,/ { p = FNR; next }
    /^[[:space:]]*cls[[:space:]]*==[[:space:]]*"orphan"[[:space:]]+\{[[:space:]]*next[[:space:]]*\}/ { if (p != FNR - 1) bad = 1 }
    END { exit (bad ? 1 : 0) }
  ' "$1"
}
PI_SH=$SKILL_DIR/scripts/promote-intent.sh
PI_PROT_N=$(pi_rule_count "$PI_SH" protect)
PI_SWEEP_N=$(pi_rule_count "$PI_SH" sweep)
if [[ "${PI_PROT_N:-0}" = 2 ]] && [[ "${PI_SWEEP_N:-0}" = 2 ]]; then
  pass "promote-intent.sh's retire AND update rewrites each carry the foreign-orphan protect rule and the sweep rule"
else
  fail "promote-intent.sh's two rewrites must each carry both rules (got protect=${PI_PROT_N:-0} sweep=${PI_SWEEP_N:-0}, want 2 and 2)"
fi
expect "the protect rule precedes the unconditional sweep in both rewrites (order does the exemption)" \
  pi_sweep_scope_intact "$PI_SH"
# --- mutation proofs, on scratch copies: promote-intent.sh itself is untouched. Each
# mutation removes ONE half of the semantics and must be caught.
PI_NO_PROT=$SANDBOX/pi-no-protect.sh
PI_NO_SWEEP=$SANDBOX/pi-no-sweep.sh
PI_REORDER=$SANDBOX/pi-sweep-first.sh
grep -vE '^[[:space:]]*cls[[:space:]]*==[[:space:]]*"orphan"[[:space:]]*&&[[:space:]]*index\(prot,' "$PI_SH" > "$PI_NO_PROT"
grep -vE '^[[:space:]]*cls[[:space:]]*==[[:space:]]*"orphan"[[:space:]]+\{[[:space:]]*next[[:space:]]*\}' "$PI_SH" > "$PI_NO_SWEEP"
awk '
  /^[[:space:]]*cls[[:space:]]*==[[:space:]]*"orphan"[[:space:]]*&&[[:space:]]*index\(prot,/ { held = $0; next }
  /^[[:space:]]*cls[[:space:]]*==[[:space:]]*"orphan"[[:space:]]+\{[[:space:]]*next[[:space:]]*\}/ && held != "" {
    print; print held; held = ""; next }
  { print }
' "$PI_SH" > "$PI_REORDER"
for m in "$PI_NO_PROT" "$PI_NO_SWEEP" "$PI_REORDER"; do
  refute "$(basename "$m") really differs from promote-intent.sh (sanity check on the fixture, not the lint)" \
    cmp -s "$m" "$PI_SH"
done
refute "deleting the foreign-orphan protect rule is caught (mutation proof)" \
  pi_sweep_scope_intact "$PI_NO_PROT"
refute "deleting the unconditional sweep rule is caught (mutation proof)" \
  pi_sweep_scope_intact "$PI_NO_SWEEP"
refute "moving the protect rule AFTER the sweep is caught (it would never fire)" \
  pi_sweep_scope_intact "$PI_REORDER"
# The exception must be stated wherever the single-writer rule is stated, or the rule
# and its one hole live in different files.
expect "SKILL.md's intent-ledger entry states the exception" \
  bash -c "grep -F 'never by hand' '$SKILL_DIR/SKILL.md' | grep -qiE 'exception|sanctioned'"
expect "reference/state-files.md's single-writer paragraph states the exception" \
  bash -c "grep -F 'never a hand edit' '$SKILL_DIR/reference/state-files.md' | grep -qiF 'exception'"
expect "reference/state-files.md excludes the orphaned guard from the exception" \
  grep -qiF 'orphaned column-0 `guard:` is **not** in the exception' "$SKILL_DIR/reference/state-files.md"
fi

if t "recurrence lint: every literal \$RUN artifact a script writes is in the state-files index"; then
# reference/state-files.md calls itself the index, and four phase docs send you there
# to find out what a file is — so a family with no row is a doc that says "look here"
# about a place the thing isn't. Two of them (the go.mod extraction, the in-place
# classification rewrite) went unindexed for exactly that long.
#
# SCOPE, stated because it is what keeps this maintainable: only write targets whose
# path is a LITERAL under $RUN and does not begin with a dot. Variable-bearing stems
# ($RUN/gate-$LABEL.tsv, $OUT.*) and dot-prefixed internal scratch ($RUN/.helm-err)
# are out of reach of a grep and are covered by the curated family list below instead.
SFI=$SKILL_DIR/reference/state-files.md
RUNW=$SANDBOX/run-write-targets.txt
grep -hoE '(>>?|mv[^|]*|cp[^|]*|mkdir -p)[[:space:]]*"\$RUN/[A-Za-z0-9][A-Za-z0-9._/-]*"' "$SKILL_DIR"/scripts/*.sh \
  | grep -oE '\$RUN/[A-Za-z0-9][A-Za-z0-9._/-]*' | sed 's|\$RUN/||' | sort -u > "$RUNW"
RUNW_N=$(grep -c . "$RUNW" || true)
# Non-vacuity FIRST: the extraction found 44 targets when this lint was written, so a
# regression in the pattern must go red rather than sweep an empty set clean.
if [[ "${RUNW_N:-0}" -ge 40 ]]; then
  pass "literal \$RUN write-target extraction is non-empty ($RUNW_N target(s) across scripts/)"
else
  fail "literal \$RUN write-target extraction is non-empty (got ${RUNW_N:-0}, want >=40 — the redirect/mv/cp pattern broke)"
fi
# Declared exemptions: a write target that deliberately gets no row. Empty on purpose —
# every current target is indexed, including the same-run temporaries. Add a name here
# only with the reason, and expect to be asked why the index cannot carry it instead.
SFI_EXEMPT=""
SFI_MISSING=""
# sfi_indexed <artifact> [index-file] — the membership test itself, as a function so
# the self-test below feeds its sentinel through THIS code and not a copy of it.
# Boundary-anchored, not substring: `added.txt` must not be satisfied by the
# `upgrades-added.txt` row, nor `classification.tsv` by `classification.tsv.tmp`.
sfi_indexed() {
  local art_re; art_re=$(printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
  grep -qE "(^|[^A-Za-z0-9._-])${art_re}([^A-Za-z0-9._-]|\$)" "${2:-$SFI}"
}
while IFS= read -r art; do
  [[ -n "$art" ]] || continue
  case " $SFI_EXEMPT " in *" $art "*) continue ;; esac
  sfi_indexed "$art" || SFI_MISSING="$SFI_MISSING $art"
done < "$RUNW"
if [[ -z "$SFI_MISSING" ]]; then
  pass "every literal \$RUN artifact written by a script has a row in reference/state-files.md"
else
  fail "artifact(s) written into \$RUN with no row in reference/state-files.md:$SFI_MISSING"
fi

# The curated half: the parameterized families a grep over literals cannot see. These
# are the ones other docs read BY NAME (the gate stems, the shards), which is what
# makes their absence from the index expensive rather than untidy.
SFI_FAMILY_MISSING=""
for fam in 'gate-<label>.tsv' 'yaml-gate-<label>.tsv' 'yaml-gate-<label>.txt' \
           'build-<label>' 'test-<label>' 'producer-build' '.gate-marker-files' \
           'test-baseline' 'test-task-<id>' 'resolutions.<slug>.tsv' \
           'resolutions.legacy.tsv' 'materialize-<side>' 'synthetic/' 'ours/' \
           'context.env' 'model.txt' 'test-command.txt' 'spawns.tsv' 'learnings.md' \
           'qa-ledger.tsv' 'intent-active.md' 'intent-quarantined.md' \
           'intent-unparseable.md' 'ask-user-decisions.tsv' 'yaml-gate-ack.tsv' \
           'ref-overrides.tsv'; do
  grep -qF "$fam" "$SFI" || SFI_FAMILY_MISSING="$SFI_FAMILY_MISSING $fam"
done
if [[ -z "$SFI_FAMILY_MISSING" ]]; then
  pass "every curated parameterized artifact family has a row in reference/state-files.md"
else
  fail "artifact family/families missing from reference/state-files.md:$SFI_FAMILY_MISSING"
fi
# Self-test of the membership check: the sentinel is RUN THROUGH sfi_indexed, the same
# function the sweep above calls. Asserting only that the sentinel is absent from the
# doc — which is what this used to do — proves the sentinel is a sentinel and nothing
# about the check: a membership test wired to return true unconditionally would still
# have passed it.
refute "sfi_indexed: an unindexed sentinel is reported missing against the real index" \
  sfi_indexed no-such-artifact.tsv
expect "sfi_indexed: an artifact the index really carries is found" \
  sfi_indexed classification.tsv
# The boundary anchoring, against a fixture index rather than the live doc, so the
# claim stays a claim about the regex and not about today's rows.
SFI_FIX=$SANDBOX/sfi-index-fixture.md
printf '| `upgrades-added.txt` | build-manifest.sh |\n| `classification.tsv.tmp` | same-run temporary |\n' \
  > "$SFI_FIX"
expect "sfi_indexed: a row present in the fixture index is found" \
  sfi_indexed upgrades-added.txt "$SFI_FIX"
refute "sfi_indexed: a longer row does not satisfy a shorter name (added.txt vs upgrades-added.txt)" \
  sfi_indexed added.txt "$SFI_FIX"
refute "sfi_indexed: a .tmp row does not satisfy the artifact it is a temporary for" \
  sfi_indexed classification.tsv "$SFI_FIX"
fi

if t "fixed-once lint: the sampled doc-vs-script drift corrections stay fixed"; then
# One block per correction, each anchored on the FACT it got wrong rather than on the
# sentence that said it.
PLN=$SKILL_DIR/agents/planner.md
GDOC=$SKILL_DIR/reference/gates.md
BM=$SKILL_DIR/scripts/build-manifest.sh

# classification.tsv has SEVEN columns — the planner's input list stopped at six, so a
# planner reading it could not know the `paired-by-dir-rename` tag exists at all.
expect "build-manifest.sh still emits seven classification columns" \
  grep -qF "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n'" "$BM"
expect "agents/planner.md states the column count" grep -qiF 'seven columns' "$PLN"
expect "agents/planner.md names the seventh column's value" \
  bash -c "grep -F 'classification.tsv' '$PLN' | grep -qF 'paired-by-dir-rename'"

# run-check-modules.sh takes a PHASE_KEY at exactly one call site (OUT=…/test-baseline);
# the sweep's contract table listed neither the variable nor the condition, so the one
# guarded entry point read as unguarded.
expect "run-check-modules.sh guards only the test-baseline stem" \
  bash -c "grep -qF 'test-baseline' '$SKILL_DIR/scripts/run-check-modules.sh' && grep -qF 'PHASE_KEY' '$SKILL_DIR/scripts/run-check-modules.sh'"
RCM_ROW=$(grep -F '| Env in | `CMD` (required), `OUT` (required)' "$GDOC" || true)
if [[ -n "$RCM_ROW" ]]; then
  pass "the multi-module sweep's Env-in row extracts from reference/gates.md"
else
  fail "the multi-module sweep's Env-in row extracts from reference/gates.md (the table moved)"
fi
expect "that row names PHASE_KEY and the one stem that requires it" \
  bash -c "printf '%s' \"\$1\" | grep -qF 'PHASE_KEY' && printf '%s' \"\$1\" | grep -qF 'test-baseline'" _ "$RCM_ROW"
expect "yaml-gate's Env-in row names the optional SKILL_DIR it reads for lib/*.awk" \
  bash -c "grep -F 'buried-key acknowledgments' '$GDOC' | grep -qF 'SKILL_DIR'"

# A redo of the structural merge deletes resolutions.tsv AND every shard. Three docs
# tell you to redo Phase 5; none of them used to say what the redo costs.
expect "structural-merge.sh still clears the aggregate and every shard" \
  grep -qF 'rm -f "$RUN/resolutions.tsv" "$RUN"/resolutions.*.tsv' "$SKILL_DIR/scripts/structural-merge.sh"
for doc in phases/5-structural.md reference/continue.md reference/structural-merge.md; do
  expect "$doc warns that a Phase 5 redo discards the logged resolver verdicts" \
    bash -c "grep -qiE 'discards (every resolver verdict|the whole ledger)' '$SKILL_DIR/$doc'"
done

# --template-path is the clone ORIGIN; pre-flight still builds and every phase still
# reads the per-component mirror at $RUN/template. "Instead of the cache" said the
# opposite, and the consequence it hid is that uncommitted work there is invisible.
expect "pre-flight.sh uses TEMPLATE_PATH as the clone origin, not as the cache" \
  bash -c "grep -qF 'ORIGIN=\"\$TEMPLATE_PATH\"' '$SKILL_DIR/scripts/pre-flight.sh'"
refute "SKILL.md no longer describes --template-path as replacing the cache" \
  bash -c "grep -F '\`--template-path' '$SKILL_DIR/SKILL.md' | grep -qF 'instead of the cache'"
expect "SKILL.md's --template-path entry says uncommitted work there is invisible to the run" \
  bash -c "grep -F '\`--template-path' '$SKILL_DIR/SKILL.md' | grep -qiF 'invisible'"

# Continue-mode pre-flight exempts FOUR by-design-dirty paths — the script added a
# .gitignore exemption for the mid-Phase-4 `git add .gitignore` window, but the doc
# counted only three, so a model reasoning from the doc during a dirty-tree triage
# would mis-route a legitimately staged .gitignore.
expect "pre-flight.sh exempts .gitignore under MODE=continue (the fourth pathspec)" \
  grep -qF "':(exclude).gitignore'" "$SKILL_DIR/scripts/pre-flight.sh"
expect "reference/pre-flight.md check 1 says FOUR exempt pathspecs" \
  grep -qF 'carries **four**' "$SKILL_DIR/reference/pre-flight.md"
expect "reference/pre-flight.md check 1 names .gitignore as an exemption" \
  grep -qF '`.gitignore`' "$SKILL_DIR/reference/pre-flight.md"

# The silenced-test scan's needle table must carry `.todo` (a pending marker whose body
# never runs, so it silences a test like `.skip`); the phases/4.5 doc claimed `.todo`
# AND over-claimed commented-out assertions, which no needle grammar catches.
expect "silenced-tests.sh carries the it.todo needle" \
  grep -qF 'needle[++n] = "it.todo"' "$SKILL_DIR/scripts/silenced-tests.sh"
expect "phases/4.5-test-baseline.md's silenced-test relay names .todo as covered" \
  bash -c "grep -F 'silenced-test scan still runs' '$SKILL_DIR/phases/4.5-test-baseline.md' | grep -qF '.todo'"
refute "phases/4.5-test-baseline.md no longer lists commented-out assertions as a covered needle" \
  grep -qF '`xit`, commented-out assertions' "$SKILL_DIR/phases/4.5-test-baseline.md"
fi

if t "orphan lint: every script and scripts/lib file is named somewhere that can reach it"; then
# A script nobody names is a script nobody runs: no phase invokes it, no doc tells you
# it exists, and no other script calls it — so it rots against the state formats around
# it and the next reader cannot tell whether it is load-bearing or dead. This sweeps the
# whole of scripts/ (and scripts/lib/, whose *.awk files are only ever reachable BY
# NAME from a script) against the four places a name can legitimately come from.
# WHY name-matching and not call-site parsing: the invocations are spread across shell,
# markdown code blocks and prose pointers, and a parser strict enough to find them all
# would be a second implementation of the skill. A bare mention is a weak signal on
# purpose — this lint catches abandonment, not miswiring.
OL_FILES=$(ls "$SKILL_DIR"/scripts/*.sh "$SKILL_DIR"/scripts/lib/* 2>/dev/null)
OL_N=$(printf '%s\n' $OL_FILES | grep -c .)
# Non-vacuity FIRST: 40 files when this lint was written, so a glob regression must go
# red rather than sweep an empty set clean.
if [[ "${OL_N:-0}" -ge 35 ]]; then
  pass "the script inventory is non-empty ($OL_N file(s) under scripts/ + scripts/lib/)"
else
  fail "the script inventory is non-empty (got ${OL_N:-0}, want >=35 — the scripts/ glob broke)"
fi
# ol_named <basename> [its-own-path] — the membership test, as a function so the
# self-test below runs THIS code against its sentinel.
#   (a) named by a doc: SKILL.md, a phase, a reference file (model-families.yaml
#       included — reference/ is read as one set), or an agent role file.
#   (b) named by ANOTHER script (a helper called only from its caller is not an orphan).
#       Self-matches are excluded: every script names itself in its own header, so the
#       file's own path is passed in and filtered out of the match list.
# The two search sets are globals so the self-test can point them at a fixture tree
# and exercise the arms in isolation; the sweep itself always runs against these.
OL_DOCS=("$SKILL_DIR/SKILL.md" "$SKILL_DIR"/phases/*.md "$SKILL_DIR"/reference/* "$SKILL_DIR"/agents/*.md)
OL_SCRIPTS=("$SKILL_DIR"/scripts/*.sh "$SKILL_DIR"/scripts/lib/*)
ol_named() {
  grep -qF -- "$1" "${OL_DOCS[@]}" 2>/dev/null && return 0
  grep -lF -- "$1" "${OL_SCRIPTS[@]}" 2>/dev/null | grep -qvxF "${2:-}"
}
OL_ORPHANS=""
for f in $OL_FILES; do
  n=$(basename "$f")
  ol_named "$n" "$f" && continue
  OL_ORPHANS="$OL_ORPHANS $n"
done
if [[ -z "$OL_ORPHANS" ]]; then
  pass "every script/lib file is named by a doc or by another script"
else
  fail "script(s) named by no doc and no other script — dead, or wired only in someone's head:$OL_ORPHANS"
fi
# Self-test of the membership check: the sentinel is RUN THROUGH ol_named, the same
# function the sweep above calls. Asserting only that the sentinel is absent from the
# tree — which is what this used to do — proves the sentinel is a sentinel and nothing
# about the check: an ol_named wired to return true unconditionally would still have
# passed it, and the sweep would report no orphan however dead the script.
refute "ol_named: a script name nothing in the tree mentions is reported as an orphan" \
  ol_named no-such-script.sh
expect "ol_named: a script the docs name is not reported (the doc arm really matches)" \
  ol_named gate.sh "$SKILL_DIR/scripts/gate.sh"
# Each arm in isolation, against a fixture tree — the live tree cannot prove the
# self-match exclusion, because every real script is also named by a doc, so arm (a)
# short-circuits before arm (b) is ever reached.
OL_FIX=$SANDBOX/ol-fix
mkdir -p "$OL_FIX/docs" "$OL_FIX/scripts"
printf '# a doc naming ol-documented.sh and nothing else\n' > "$OL_FIX/docs/d.md"
printf '#!/usr/bin/env bash\n# ol-lonely.sh — mentions only its own name\n' > "$OL_FIX/scripts/ol-lonely.sh"
printf '#!/usr/bin/env bash\n# ol-caller.sh — calls the helper\nbash ol-helper.sh\n' > "$OL_FIX/scripts/ol-caller.sh"
printf '#!/usr/bin/env bash\n# ol-helper.sh\n' > "$OL_FIX/scripts/ol-helper.sh"
printf '#!/usr/bin/env bash\n# ol-documented.sh\n' > "$OL_FIX/scripts/ol-documented.sh"
OL_DOCS_REAL=("${OL_DOCS[@]}"); OL_SCRIPTS_REAL=("${OL_SCRIPTS[@]}")
OL_DOCS=("$OL_FIX"/docs/*.md); OL_SCRIPTS=("$OL_FIX"/scripts/*.sh)
refute "ol_named: a script named ONLY in its own header is an orphan (self-match excluded)" \
  ol_named ol-lonely.sh "$OL_FIX/scripts/ol-lonely.sh"
expect "ol_named: a helper named by another script is not an orphan (script arm)" \
  ol_named ol-helper.sh "$OL_FIX/scripts/ol-helper.sh"
expect "ol_named: a script named by a doc is not an orphan (doc arm)" \
  ol_named ol-documented.sh "$OL_FIX/scripts/ol-documented.sh"
refute "ol_named: the fixture's sentinel is an orphan there too" \
  ol_named no-such-script.sh "$OL_FIX/scripts/ol-lonely.sh"
OL_DOCS=("${OL_DOCS_REAL[@]}"); OL_SCRIPTS=("${OL_SCRIPTS_REAL[@]}")
expect "ol_named: the real search sets are restored after the fixture run" \
  bash -c "printf '%s\n' \"\$@\" | grep -qxF '$SKILL_DIR/SKILL.md'" _ "${OL_DOCS[@]}"
fi

if t "coverage lint: every scripts/*.sh has its own test suite or a declared exemption"; then
# `make test-skills` is the only thing standing between a state-format edit and a
# migration that half-writes someone's repo, so an untested script is an untested
# format owner. tests/run-tests.sh's roster is 1:1 with scripts/ by design — this lint
# is what keeps it that way as scripts get added.
#
# THE EXEMPTION LIST, and why it is exactly this: five scripts are exercised inside
# tests/merge-path.test.sh instead of a file of their own, because they only mean
# anything in SEQUENCE against one mutating tree (materialize writes the synthetic trees,
# build-manifest classifies what materialize wrote, structural-merge enacts that
# classification, scope-overlap-check and handoff-classify read across that merged state,
# and the post-merge sweep re-reads the merged tree). pre-flight builds the mirror at the
# head of that chain, so its sequence-dependent behaviors are exercised here too — but its
# invocation-level checks (the git-toplevel guard, the continue-mode dirty exemption, the
# fresh-over-live-$RUN interlock) reason from a single static invocation and so earn their
# own tests/pre-flight.test.sh; it is therefore NOT on this list. Split into five suites
# they would each need to rebuild the whole chain, and the seams BETWEEN them — where the
# defects actually live — would go untested. The grouping is documented in both headers
# (asserted below), so the exemption is a stated design decision and not a place to park
# an untested script.
CL_EXEMPT="materialize.sh build-manifest.sh scope-overlap-check.sh handoff-classify.sh structural-merge.sh"
MP=$SKILL_DIR/tests/merge-path.test.sh
CL_UNDOC=""
for e in $CL_EXEMPT; do
  # Really exercised there, and the grouping really documented in both headers.
  grep -qF -- "$e" "$MP" || CL_UNDOC="$CL_UNDOC $e(not-in-merge-path)"
  head -20 "$MP" | grep -qF -- "${e%.sh}" || CL_UNDOC="$CL_UNDOC $e(not-in-merge-path-header)"
  # Whole-file grep, and it stays a header check by construction: an exempt script has
  # no tests/<name>.test.sh, so its name cannot appear in the SUITES array — the only
  # place run-tests.sh can name it is the merge-path grouping comment.
  grep -qF -- "$e" "$SKILL_DIR/tests/run-tests.sh" \
    || CL_UNDOC="$CL_UNDOC $e(not-in-run-tests-grouping)"
done
if [[ -z "$CL_UNDOC" ]]; then
  pass "every exempted script is exercised in merge-path.test.sh and its grouping is documented in both headers"
else
  fail "exemption(s) that are not what they claim:$CL_UNDOC"
fi
# A stale exemption is as bad as a missing test: once a script gets its own suite the
# name must leave this list, or the list starts documenting fiction.
CL_STALE=""
for e in $CL_EXEMPT; do
  [[ -f "$SKILL_DIR/tests/${e%.sh}.test.sh" ]] && CL_STALE="$CL_STALE $e"
done
if [[ -z "$CL_STALE" ]]; then
  pass "no exemption is stale (none of the exempted scripts has a suite of its own)"
else
  fail "exemption(s) now covered by their own tests/<name>.test.sh — drop them from the list:$CL_STALE"
fi
CL_N=0
CL_MISSING=""
for f in "$SKILL_DIR"/scripts/*.sh; do
  n=$(basename "$f")
  CL_N=$((CL_N + 1))
  case " $CL_EXEMPT " in *" $n "*) continue ;; esac
  [[ -f "$SKILL_DIR/tests/${n%.sh}.test.sh" ]] || CL_MISSING="$CL_MISSING $n"
done
if [[ "$CL_N" -ge 35 ]]; then
  pass "the scripts/*.sh sweep is non-empty ($CL_N script(s))"
else
  fail "the scripts/*.sh sweep is non-empty (got $CL_N, want >=35 — the glob broke)"
fi
if [[ -z "$CL_MISSING" ]]; then
  pass "every non-exempt scripts/*.sh has a matching tests/<name>.test.sh"
else
  fail "script(s) with no tests/<name>.test.sh and no declared exemption:$CL_MISSING"
fi
# --- the suite roster vs the suites on disk ---
# Same class of defect one level up: tests/run-tests.sh names its suites explicitly, so
# a new tests/<name>.test.sh that nobody adds to the list never runs — and the
# aggregator then prints `passed: n/n` over a suite nobody executed, which is worse than
# a red run. The comparison lives in TWO places on purpose, doing two different jobs:
# run-tests.sh checks it before the first suite (it owns the list, and it is the only
# place that still works if the roster ever drops skill-lint.test.sh itself, taking this
# block with it), and here it is an assertion with a name, so `bash tests/skill-lint.
# test.sh` alone reports the drift and the review has a red test to point at.
CL_RT=$SKILL_DIR/tests/run-tests.sh
CL_LISTED=$SANDBOX/rt-suites-listed.txt
CL_ONDISK=$SANDBOX/rt-suites-ondisk.txt
# The SUITES=( … ) block only — not every *.test.sh mention in the header prose.
awk '/^SUITES=\(/ { inb = 1; next } inb && /^\)/ { inb = 0 } inb' "$CL_RT" \
  | tr -d ' \t' | grep '\.test\.sh$' | LC_ALL=C sort > "$CL_LISTED"
( cd "$SKILL_DIR/tests" && ls -1 -- *.test.sh ) | LC_ALL=C sort > "$CL_ONDISK"
CL_NL=$(grep -c . "$CL_LISTED" || true)
if [[ "${CL_NL:-0}" -ge 30 ]]; then
  pass "run-tests.sh's SUITES list extracts ($CL_NL suite(s))"
else
  fail "run-tests.sh's SUITES list extracts (got ${CL_NL:-0}, want >=30 — the array shape changed)"
fi
# LC_ALL=C on both sides: comm walks its inputs under ITS collation, and the
# ambient-locale-vs-C mismatch is the trap this suite already keeps a fixed-once lint over.
# De-duplicated on the listed side: a name listed twice IS on disk, and reporting it as
# unmatched here would send the reader after the wrong bug. Duplication is its own row.
uniq "$CL_LISTED" > "$CL_LISTED.uniq"
CL_DRIFT=$(LC_ALL=C comm -3 "$CL_ONDISK" "$CL_LISTED.uniq" | tr -d '\t' | tr '\n' ' ')
if [[ -z "$CL_DRIFT" ]]; then
  pass "every tests/*.test.sh is in run-tests.sh's SUITES list, and every listed suite exists"
else
  fail "run-tests.sh's SUITES list has drifted from tests/*.test.sh (unmatched: $CL_DRIFT)"
fi
CL_RTDUP=$(uniq -d "$CL_LISTED" | tr '\n' ' ')
if [[ -z "$CL_RTDUP" ]]; then
  pass "no suite is listed twice (a duplicate's assertions would be counted twice)"
else
  fail "suite(s) listed more than once in run-tests.sh: $CL_RTDUP"
fi
# And the aggregator's own fail-fast, which is what protects a full run even when this
# block is the thing that went missing.
expect "run-tests.sh still checks its SUITES list before running the first suite" \
  bash -c "grep -qF 'has drifted from tests/*.test.sh' '$CL_RT'"
expect "that check names both directions and the duplicate case" \
  bash -c 'grep -qF "NOT in SUITES" "$1" && grep -qF "NOT on disk" "$1" \
        && grep -qF "listed more than once" "$1"' _ "$CL_RT"

# --- the aggregate's own accounting invariants ---
# A suite that dies before finish_suite prints no `passed: n/m`, and the aggregate used
# to sum "nothing" for it: 31 assertions left a Go-less run with the aggregate still
# exiting 0. Two things had to change and neither may be quietly reverted — the missing
# line must fail, and the summed totals must balance. Both are greps because the
# behaviour is proven by the reduced-roster smoke, not here; this only pins that the
# code is still present.
expect "run-tests.sh fails a suite that printed no terminal 'passed: n/m' line" \
  bash -c "grep -qF \"printed no terminal 'passed: n/m' line\" '$CL_RT'"
expect "run-tests.sh asserts the summed totals balance" \
  bash -c "grep -qF 'TOTAL_PASS\" -ne \"\$TOTAL_TESTS' '$CL_RT'"
# `grep … | tail -1` exits 0 on a no-match, so the presence test must read the captured
# value. `if line=$(… | tail -1); then` is the shape that let the absence through.
refute "run-tests.sh does not test the passed-line grep by its pipeline status" \
  grep -qE '^[[:space:]]*if[[:space:]]+line=\$\(grep' "$CL_RT"
expect "run-tests.sh surfaces a per-suite skip count in the aggregate summary" \
  bash -c "grep -qF 'SKIP_BY_SUITE' '$CL_RT' && grep -qF 'skipped: ' '$CL_RT'"
fi

if t "single-source lint: the intent-guard reference exists and every consumer points at it"; then
# Finding 2's consolidation: the closed guard grammar, the whole-file-refusal repair, and
# the orphaned-`guard:` ownership/adoption/sweep rules used to be hand-duplicated across
# SKILL.md, phases/5-structural.md, phases/8-finalize.md and reference/abort.md, kept in
# sync only by a lint. They now have ONE doc home — reference/intent-guard.md — with the
# clause-by-clause sweep mechanics still in promote-intent.sh's header. This lint holds the
# single-source WIRING (the reference exists; each consumer carries a pointer to it) so it
# cannot silently break, plus the anti-regression invariant the retired sync-lint really
# protected — no site may call a FOREIGN entry's orphan sweepable, or make its survival
# conditional on that entry being guardless, while promote-intent.sh protects it
# unconditionally — now checked against the two places that still STATE the sweep rule:
# reference/intent-guard.md and promote-intent.sh's header.
IG=$SKILL_DIR/reference/intent-guard.md
expect "reference/intent-guard.md exists (the single authoritative home)" test -f "$IG"
for consumer in SKILL.md phases/5-structural.md phases/8-finalize.md reference/abort.md; do
  expect "$consumer points at reference/intent-guard.md" \
    grep -qF 'reference/intent-guard.md' "$SKILL_DIR/$consumer"
done
# The reference must actually carry the three consolidated subjects, or the pointers lead
# nowhere: the grammar, the whole-file refusal, and the orphaned-guard rules.
expect "the reference carries the closed guard grammar and the GUARD_TIMEOUT bound" \
  bash -c "grep -qiF 'closed guard grammar' '$IG' && grep -qF 'GUARD_TIMEOUT' '$IG'"
expect "the reference carries the whole-file refusal and its sanctioned repair" \
  bash -c "grep -qiF 'refuse the WHOLE file' '$IG' && grep -qiF 'sanctioned' '$IG'"
expect "the reference carries the orphaned-guard ownership/sweep rules" \
  grep -qiF 'entry-scoped by ownership' "$IG"

# --- anti-regression: the two sweep-rule statements carry the ownership markers and neither
# carries the guardless-conditional wording. Same normalization and mutation proofs as the
# retired sync-lint, relocated to track where the content now lives. Markers matched on
# NORMALIZED text (bold/backticks stripped, whitespace collapsed, lowercased).
sw_norm() { tr -d '*`' | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' '; }
sw_script() { awk '/^# WHY THE SWEEP IS ENTRY-SCOPED/ { f = 1 } f { print } f && /^# See orphan_rows\(\) for the rule clause by clause/ { exit }' "$1"; }
sw_ref()    { awk '/^### Orphaned column-0/ { f = 1 } f { print } f && /Never delete an orphaned/ { exit }' "$1"; }
SW_REQ_SCRIPT=$SANDBOX/sw-req-script.txt
cat > "$SW_REQ_SCRIPT" <<'SWSCRIPT'
whatever guards that entry already carries
the ones above every bullet in the file
otherwise the retraction target the parser carries forward
the verdict is protect wherever this rewrite
and a refusal wherever it can
SWSCRIPT
SW_REQ_REF=$SANDBOX/sw-req-ref.txt
cat > "$SW_REQ_REF" <<'SWREF'
nearest preceding column-0 - bullet
intent-check.sh attributes the line
only when no - line precedes it anywhere
whatever guards that entry already carries
update on that entry
an orphan owned by any other entry is always left in place
a blank line is held, never closing the entry
neither guard= nor drop_guard=1 was given
reaching across a blank line or any other structure
SWREF
# The forbidden half, shared by both sites: every phrasing that makes a foreign entry's
# orphan sweepable, or its survival conditional on that entry being guardless. NOT here:
# "guardless" alone and "a guardless matched entry" — the ADOPTION rule is legitimately
# conditioned on the MATCHED entry being guardless, and forbidding the word would push the
# docs into dropping a condition the script really has.
SW_FORBID=$SANDBOX/sw-forbid.txt
cat > "$SW_FORBID" <<'SWFORBID'
no guardless entry
different guardless entry
another guardless entry
only when that other entry is guardless
owned by a guardless entry
other entry's orphan is swept
other entry's orphans are swept
SWFORBID
# sw_check <label> <normalized-passage-file> <required-markers-file> — fail-closed FIRST:
# a passage that came back short is a drifted anchor or a deleted site, never "no markers".
sw_check() {
  local label="$1" txt="$2" req="$3" bad=0 marker n
  n=$(wc -c < "$txt" | tr -d ' ')
  if [[ "${n:-0}" -lt 1200 ]]; then
    echo "$label: extraction yielded ${n:-0} byte(s) (want >=1200) — the anchor drifted, the passage moved, or the site is gone"
    return 1
  fi
  while IFS= read -r marker; do
    [[ -n "$marker" ]] || continue
    grep -qF -- "$marker" "$txt" || { echo "$label: MISSING final-rule marker [$marker]"; bad=1; }
  done < "$req"
  while IFS= read -r marker; do
    [[ -n "$marker" ]] || continue
    if grep -qF -- "$marker" "$txt"; then
      echo "$label: STALE guardless-conditional wording [$marker] — promote-intent.sh protects a foreign entry's orphan unconditionally"
      bad=1
    fi
  done < "$SW_FORBID"
  return $bad
}
# sw_pair_ok <tag> <promote-intent.sh> <intent-guard.md>
sw_pair_ok() {
  local tag="$1" bad=0
  sw_script "$2" | sw_norm > "$SANDBOX/sw-$tag-script.txt"
  sw_ref    "$3" | sw_norm > "$SANDBOX/sw-$tag-ref.txt"
  sw_check "promote-intent.sh header's entry-scoped-sweep rule" "$SANDBOX/sw-$tag-script.txt" "$SW_REQ_SCRIPT" || bad=1
  sw_check "reference/intent-guard.md orphaned-guard rule"      "$SANDBOX/sw-$tag-ref.txt"    "$SW_REQ_REF"    || bad=1
  return $bad
}
SW_SCRIPT=$SKILL_DIR/scripts/promote-intent.sh
if sw_pair_ok live "$SW_SCRIPT" "$IG" > "$SANDBOX/sw-live.log" 2>&1; then
  pass "both sweep-rule statements carry the ownership rules and neither carries the guardless-conditional wording"
else
  fail "sweep-semantics doc drift: $(tr '\n' '; ' < "$SANDBOX/sw-live.log")"
fi

# --- non-vacuity, direction 1: reverting EITHER site to the stale wording must go red, with
# the other file real and untouched. One sed serves both: it drops the required marker AND
# plants a forbidden phrase, which is what the revert actually did.
SW_STALE_SED='s/whatever guards that entry already carries/unless it belongs to a different guardless entry/'
SW_MUT_SCRIPT=$SANDBOX/sw-mutant-promote-intent.sh
SW_MUT_REF=$SANDBOX/sw-mutant-intent-guard.md
sed "$SW_STALE_SED" "$SW_SCRIPT" > "$SW_MUT_SCRIPT"
sed "$SW_STALE_SED" "$IG"        > "$SW_MUT_REF"
refute "the promote-intent.sh mutant really differs (sanity check on the fixture, not the lint)" \
  cmp -s "$SW_MUT_SCRIPT" "$SW_SCRIPT"
refute "the reference mutant really differs (sanity check on the fixture, not the lint)" \
  cmp -s "$SW_MUT_REF" "$IG"
refute "reverting promote-intent.sh's header alone to the guardless-conditional wording is caught (non-vacuity proof)" \
  sw_pair_ok mut-script "$SW_MUT_SCRIPT" "$IG"
refute "reverting reference/intent-guard.md alone to the guardless-conditional wording is caught (non-vacuity proof)" \
  sw_pair_ok mut-ref "$SW_SCRIPT" "$SW_MUT_REF"

# --- non-vacuity, direction 2: an anchor that matches NOTHING must fail loudly, never pass
# vacuously — a passage rewritten past its own opening words is a site this lint stopped
# guarding, and that has to be a red test rather than a silent one.
SW_EMPTY=$SANDBOX/sw-empty.md
: > "$SW_EMPTY"
if sw_pair_ok empty "$SW_EMPTY" "$SW_EMPTY" > "$SANDBOX/sw-empty.log" 2>&1; then
  fail "sw_pair_ok: a file with neither passage must be refused, not passed vacuously"
else
  pass "sw_pair_ok fails closed when an extractor finds nothing ($(grep -c 'extraction yielded' "$SANDBOX/sw-empty.log") site(s) reported as drifted)"
fi
fi

if t "recurrence lint: every <placeholder> inside a fenced bash block is quoted"; then
# The bash blocks in these docs are meant to be RUN — an orchestrator pastes them into a
# tool call verbatim. An unquoted placeholder there is not a blank to fill in, it is
# shell SYNTAX: `SHARD=<slug>` is a redirect from a file named `slug`, so the line dies
# on "No such file", and a two-token placeholder is that redirect PLUS a truncating `>`
# on a file the reader never named. Both land mid-migration, in phases whose whole job is
# not to lose the component's work. Quoting costs two bytes, and all ~60 placeholders in
# this tree now carry them — this is what keeps it that way.
#
# The token shape allows INTERNAL SPACES (`MODEL=<the corrected slug>`) because the
# multi-word placeholder is the strictly worse half of the class and the first shape here
# was blind to it: a single-word `<slug>` is one failed redirect, while a multi-word one
# is a bash SYNTAX error (`>` with no operand before the next word) that takes the whole
# block down, and the doc author writing prose into a runnable block is exactly the
# author most likely to write more than one word. It stays safe against real redirection
# because every spaced group must end in a word character before the closing `>`: neither
# `cmd < in.txt > out.txt` nor the space-less `cmd <in.txt >out.txt` (nor that form with a
# trailing `2>&1`) can match, since the regex cannot cross a `>` to reach one.
#
# The escape hatch is a COMMENT: prose ABOUT a placeholder is not a command, and the
# scanner stops at an unquoted `#`. There is deliberately no exemption list — a bare
# placeholder that must stay bare inside a runnable block does not exist.
#
# ```text / ```markdown blocks are out of scope on purpose: agents/conflict-resolver.md
# illustrates diff3 with `<<<<<<< <ours-label>`, which is a picture of OUTPUT, not a
# command anyone runs.
PH_AWK=$SANDBOX/placeholder-hygiene.awk
# The scanner tracks bash quoting instead of grepping for `<`, because the legal ways a
# `<` reaches these blocks all look like a placeholder to a grep: a QUOTED placeholder
# (the sanctioned form — and it spans lines, since Phase 5's commit message is one
# double-quoted string carrying four of them), a real redirection (`< in.txt`), process
# substitution (`<(…)`), and a heredoc BODY (a file being written, not commands being
# run). A token is reported only when its `<` is unquoted, outside a heredoc body, outside
# a comment, and immediately followed by word-ish characters — then any number of
# space-separated word-ish groups — and a `>` with no whitespace before it, which is what
# excludes `cmd < in.txt > out.txt` and `cmd <in.txt >out.txt` without an exception.
cat > "$PH_AWK" <<'PHAWK'
# Emits, over fenced ```bash blocks only:
#   BLOCK <file>:<fence-line>      one per bash block entered (fence-parity census)
#   LINE                           one per scanned line (non-vacuity census)
#   HIT <file>:<line> <token>      one per unquoted word-ish <placeholder>
#
# code_of() blanks every quoted span to `_` and cuts any comment tail, ONE output
# character per input character — so a `<` that survives is code, and its offset still
# indexes the raw line. `q` carries an open quote across lines on purpose (Phase 5's
# commit message is one double-quoted string spanning six). Position-preserving is what
# lets the heredoc opener be found on the code part and its DELIMITER read from the raw
# line: `# … <<<<<<< HEAD …` in a comment must not open a body, and `cat <<'EOF'`'s
# delimiter is unreadable once the quotes are blanked.
function code_of(line,   n, i, c, out, prev) {
  n = length(line); i = 1; out = ""
  while (i <= n) {
    c = substr(line, i, 1)
    if (q != "") {                                  # inside a quote, possibly carried
      if (q == "\"" && c == "\\") { out = out "__"; i += 2; continue }
      out = out "_"
      if (c == q) q = ""
      i++; continue
    }
    if (c == "\\") { out = out "__"; i += 2; continue }
    if (c == "'" || c == "\"") { q = c; out = out "_"; i++; continue }
    prev = (i == 1 ? "" : substr(line, i - 1, 1))
    if (c == "#" && (i == 1 || prev ~ /[[:space:]]/ || prev ~ /[;&|(]/)) return out
    out = out c
    i++
  }
  return out
}
/^[[:space:]]*```/ {
  if (inb) { inb = 0; next }
  lang = $0; sub(/^[[:space:]]*```/, "", lang); gsub(/[[:space:]]/, "", lang)
  inb = 1; q = ""; hd = ""                          # state never crosses a block
  if (lang == "bash") print "BLOCK " FILENAME ":" FNR
  next
}
!inb || lang != "bash" { next }
{
  if (hd != "") {                                   # heredoc body: data, not commands
    body = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", body)
    if (body == hd) hd = ""
    next
  }
  print "LINE"
  m = code_of($0)
  rest = m; off = 0
  while (match(rest, /<[A-Za-z][A-Za-z0-9_.:\/-]*([ ]+[A-Za-z0-9_.:\/-]+)*>/)) {
    print "HIT " FILENAME ":" FNR " " substr($0, off + RSTART, RLENGTH)
    off += RSTART + RLENGTH - 1
    rest = substr(rest, RSTART + RLENGTH)
  }
  # A heredoc opener needs an unquoted `<<` and a closed quote state; `<<<` is a
  # herestring and consumes no lines.
  if (q != "" || !match(m, /<</)) next
  raw = substr($0, RSTART)
  if (raw ~ /^<<</) next
  if (match(raw, /^<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/)) {
    d = substr(raw, RSTART, RLENGTH)
    sub(/^<<-?[[:space:]]*/, "", d); gsub(/['"]/, "", d)
    hd = d
  }
}
PHAWK
# ONE scanner for the real tree, the exclusion fixture and the mutant — a second copy of
# the rules is a second thing to keep in step, and the fixture would stop proving anything
# about the sweep.
ph_scan() { awk -f "$PH_AWK" "$@"; }
PH_DOCS=("$SKILL_DIR/SKILL.md" "$SKILL_DIR"/phases/*.md "$SKILL_DIR"/reference/*.md "$SKILL_DIR"/agents/*.md)
PH_REPORT=$SANDBOX/placeholder-report.txt
ph_scan "${PH_DOCS[@]}" > "$PH_REPORT"
PH_BLOCKS=$(grep -c '^BLOCK' "$PH_REPORT" || true)
PH_LINES=$(grep -c '^LINE' "$PH_REPORT" || true)
PH_FENCES=$(grep -hE '^[[:space:]]*```bash' "${PH_DOCS[@]}" | grep -c . || true)
# Non-vacuity FIRST, and as fence PARITY rather than a floor: one unbalanced fence
# anywhere in the set inverts the in-block/out-of-block phase, at which point ```bash
# lines read as CLOSERS and the sweep scans nothing while reporting a clean tree.
# 75 blocks / ~490 lines when this lint was written.
if [[ "${PH_BLOCKS:-0}" -ge 60 ]] && [[ "${PH_BLOCKS:-0}" = "${PH_FENCES:-0}" ]]; then
  pass "the fenced-bash sweep is non-empty and fence parity holds ($PH_BLOCKS block(s), $PH_LINES line(s) of bash)"
else
  fail "the fenced-bash sweep is non-empty and fence parity holds (entered ${PH_BLOCKS:-0} block(s) for ${PH_FENCES:-0} bash fence(s), want equal and >=60 — an unbalanced fence inverts the parse)"
fi
if [[ "${PH_LINES:-0}" -ge 300 ]]; then
  pass "the scanned-line census is non-empty ($PH_LINES line(s) scanned)"
else
  fail "the scanned-line census is non-empty (got ${PH_LINES:-0}, want >=300 — heredoc skipping or the fence parse ate the blocks)"
fi
PH_HITS=$(sed -n 's/^HIT //p' "$PH_REPORT" | tr '\n' ';')
if [[ -z "$PH_HITS" ]]; then
  pass "no fenced bash block carries an unquoted <placeholder>"
else
  fail "unquoted <placeholder>(s) in a runnable bash block — quote them (FOO=\"<bar>\"): $PH_HITS"
fi

# --- the exclusions, as a fixture: each legal form on its own line, so a scanner that
# went blunt (reporting every `<`) and one that went blind (reporting none) both name
# themselves. The expectation is stated as LINE NUMBERS, the only form that catches both.
PH_FIX=$SANDBOX/ph-exclusions.md
cat > "$PH_FIX" <<'PHFIX'
```bash
SHARD=<slug>
MODEL=<the corrected slug>
FILE="<path>"
MODEL="<the corrected slug>"
echo "prefix <tok> suffix"
cmd < in.txt > out.txt
cmd <in.txt >out.txt 2>&1
diff <(cmd a) <(cmd b)
# a comment naming <slug> and <the corrected slug>
cat <<'EOF'
heredoc body naming <slug>
EOF
TASK=<id>tail
printf '%s\n' '<lit>'
MULTI="line one
continued <N> still quoted"
```

```text
IGNORED=<slug>
```

prose <slug> outside any fence
PHFIX
PH_FIX_HITS=$(ph_scan "$PH_FIX" | sed -n 's/^HIT .*:\([0-9][0-9]*\) .*/\1/p' | tr '\n' ' ')
if [[ "$PH_FIX_HITS" = "2 3 14 " ]]; then
  pass "the scanner reports exactly the three bare placeholders — single-word, multi-word and suffixed — and none of the legal forms (quoted, quoted multi-word, quoted-in-string, spaced redirection, space-less redirection pair, process substitution, comment, heredoc body, multi-line string, single-quoted, non-bash fence, prose)"
else
  fail "the exclusion fixture must report exactly lines '2 3 14 ' (got '$PH_FIX_HITS' — fewer means an exclusion swallowed a hazard, more means a legal form is being flagged)"
fi

# --- and the mutation proof against a REAL doc: the fixture shows the rules work on a
# file built for them, this shows the SWEEP catches the same plant where it would actually
# happen. phases/5-structural.md on disk is untouched.
PH_SRC=$SKILL_DIR/phases/5-structural.md
PH_MUT=$SANDBOX/ph-mutant-5-structural.md
awk '{ print }
     !planted && /^[[:space:]]*```bash[[:space:]]*$/ { print "SHARD=<slug>"; planted = 1 }' \
  "$PH_SRC" > "$PH_MUT"
refute "the mutant really differs from phases/5-structural.md (sanity check on the fixture, not the lint)" \
  cmp -s "$PH_MUT" "$PH_SRC"
PH_MUT_N=$(ph_scan "$PH_MUT" | grep -c '^HIT' || true)
if [[ "${PH_MUT_N:-0}" -eq 1 ]]; then
  pass "planting one unquoted SHARD=<slug> in a real doc's bash block goes red (mutation proof)"
else
  fail "planting one unquoted SHARD=<slug> in a real doc's bash block goes red (got ${PH_MUT_N:-0} finding(s), want exactly 1)"
fi

# --- and the same plant in its MULTI-WORD shape, the half the first scanner was blind to.
# Proven against a real doc too, not just the fixture: the token rule is the only thing
# standing between a prose-shaped blank and a syntax error in a pasted block.
PH_MUT2=$SANDBOX/ph-mutant-5-structural-multiword.md
awk '{ print }
     !planted && /^[[:space:]]*```bash[[:space:]]*$/ { print "MODEL=<the corrected slug>"; planted = 1 }' \
  "$PH_SRC" > "$PH_MUT2"
refute "the multi-word mutant really differs from phases/5-structural.md (sanity check on the fixture, not the lint)" \
  cmp -s "$PH_MUT2" "$PH_SRC"
PH_MUT2_N=$(ph_scan "$PH_MUT2" | grep -c '^HIT' || true)
if [[ "${PH_MUT2_N:-0}" -eq 1 ]]; then
  pass "planting one unquoted MODEL=<the corrected slug> in a real doc's bash block goes red (multi-word mutation proof)"
else
  fail "planting one unquoted MODEL=<the corrected slug> in a real doc's bash block goes red (got ${PH_MUT2_N:-0} finding(s), want exactly 1 — the token shape rejects internal spaces again)"
fi
fi

if t "recurrence lint: no script writes a record with echo — printf is the sanctioned form"; then
# Why this is a class and not a bug: `echo "$path" > "$f"` reads as a record write and is
# really an argument parse. A value that happens to begin with `-n` (or `-e`, or `-E`) is
# swallowed as an OPTION by the builtin, and the values these scripts write come from
# callers, manifests and git output — an option-shaped override, a path from a repo nobody
# here controls. The record then lands missing its first field or its newline, and the
# thing that reports the damage is whatever reads that file later: a gate, a ledger, a
# phase, several steps downstream of the line that caused it. `printf '%s\n' "$v"` cannot
# do it — the format string owns the options. Six scripts were swept to printf for exactly
# this reason; this lint is the half that keeps them swept.
#
# SCOPE, stated because it is what keeps the lint usable: a finding needs BOTH an `echo`
# whose arguments contain an expansion (`$…`, backticks) AND a file redirect (`>`/`>>` to
# something other than `&N`) in the SAME command. So `echo OK > "$f"` (a literal record),
# `echo "$STATUS: $N modules" >&2` (a diagnostic to stderr, which no one parses as a
# record), `echo >> "$f"` (a blank separator) and `echo '$X' > "$f"` (single-quoted, so
# nothing expands) all stay legal. A computed value reaching a FILE is the whole target.
#
# THE REDIRECT IS NOT ALWAYS ON THE ECHO. The first scanner here only looked inside one
# command, so every way of putting the redirect somewhere else walked straight through it:
# `{ echo "$row"; } >> f`, `while …; do echo "$row"; done >> f`, `if …; then echo "$row";
# fi >> f` — all four verified passing — and `echo "$row" | tee -a f`, which has no
# redirect at all. These are not exotic; the brace form is what a script reaches for the
# moment two lines have to land in the same file, so the blind spot covered the shape most
# likely to be written NEXT. So the scanner now also tracks compound nesting: an echo
# inside a compound whose CLOSING token (`}` / `done` / `fi` / `esac`) carries a file
# redirect is a write to that file, and so is an echo piped into `tee`. Two exclusions
# inside that rule, both load-bearing:
#   - an echo carrying its OWN stdout redirect to a descriptor (`echo "$X" >&2`) is not
#     writing to the block's file at all; `echo "$X" 2>&1` still is, and is kept.
#   - a pipeline out of the block (`} | awk … > f`) is deliberately NOT a finding: the
#     value passes through a filter that owns its own parse, and `|` ends the tail scan.
#
# Inside a compound the finding is narrowed to the RECORD shape — the expansion starts the
# first argument (`echo "$row"`, `echo "$m/$t …"`), the only position where `echo`'s option
# parse can eat it. A labelled report line (`echo "base_sha: $BASE"` inside materialize.sh's
# `{ … } > materialization.txt`, and yaml-gate.sh's summary block) cannot lose a field that
# way, and a redirected compound is usually exactly that: a human-readable report assembled
# in one place. The in-line rule stays broader (fixture line 17 pins it) because there the
# echo IS the write; that asymmetry is deliberate, and the mid-line-value-in-a-report-block
# shape is the declared residual of this lint.
RW_AWK=$SANDBOX/record-write-hygiene.awk
# Quote-tracking again, for a sharper reason than the placeholder scanner: a `>` is only a
# redirect when it is unquoted. `echo "component_module: ${M:-<no go.mod>}"` — a real line
# in materialize.sh — carries a `>` inside a quoted default value, and a grep for
# `echo.*>` calls that a record write.
cat > "$RW_AWK" <<'RWAWK'
# Emits, over the scripts handed to it:
#   LINE                                          one per scanned line (non-vacuity)
#   HIT <TAB> <basename> <TAB> <line> <TAB> <statement>
#
# code_of() is the placeholder block's helper with one difference, and the difference is
# the rule: single-quoted spans blank completely (a `$` in them expands to nothing), while
# double-quoted spans keep their `$` and backticks and blank everything else — so what
# survives is exactly "is there an expansion here, and is this `>` a redirect". Spelled
# out again rather than shared, so either block still runs alone under TEST_FILTER.
function code_of(line,   n, i, c, out, prev) {
  n = length(line); i = 1; out = ""
  while (i <= n) {
    c = substr(line, i, 1)
    if (q == "'") { out = out "_"; if (c == "'") q = ""; i++; continue }
    if (q == "\"") {
      if (c == "\\") { out = out "__"; i += 2; continue }
      out = out ((c == "$" || c == "`") ? c : "_")
      if (c == "\"") q = ""
      i++; continue
    }
    if (c == "\\") { out = out "__"; i += 2; continue }
    if (c == "'" || c == "\"") { q = c; out = out "_"; i++; continue }
    prev = (i == 1 ? "" : substr(line, i - 1, 1))
    if (c == "#" && (i == 1 || prev ~ /[[:space:]]/ || prev ~ /[;&|(]/)) return out
    out = out c
    i++
  }
  return out
}
function emit(orig, ln,   f, stmt) {
  f = FILENAME; sub(/.*\//, "", f)
  stmt = orig; gsub(/^[[:space:]]+|[[:space:]]+$/, "", stmt)
  print "HIT\t" f "\t" ln "\t" stmt
}
function check(orig, m,   parts, nseg, k, seg, rest, args) {
  gsub(/>&/, "@@", m)          # fd duplication (>&2, 2>&1) is never a file write
  gsub(/[;|&]/, "\n", m)       # attribute each redirect to ITS OWN command
  nseg = split(m, parts, "\n")
  for (k = 1; k <= nseg; k++) {
    seg = parts[k]
    if (!match(seg, /(^|[[:space:]({])echo([[:space:]]|$)/)) continue
    rest = substr(seg, RSTART + RLENGTH)
    if (!match(rest, />>?[[:space:]]*[^[:space:]>]/)) continue
    args = substr(rest, 1, RSTART - 1)
    if (args !~ /[$`]/) continue
    emit(orig, FNR)
    return 1
  }
  return 0
}
# --- the enclosing-redirect half: compound nesting and `tee` ------------------
# `depth` and the pend_* arrays are FILE-scoped state (reset at FNR == 1), because the
# shape this exists for spans lines: the `{` and the `} >> f` are rarely on one line.
# A pending echo is held with the depth it was seen at; when a compound closes WITHOUT a
# redirect the pendings inside it move out one level (an outer `} > f` still captures
# them), and reaching level 0 drops them — that is what stops an echo in one function
# from being attributed to an unrelated `done > f` later in the file.
function is_open(t)  { return (t == "{" || t == "do" || t == "then" || t == "case") }
function is_close(t) { return (t == "}" || t == "done" || t == "fi" || t == "esac") }
function is_sep(t)   { return (t == ";" || t == "|" || t == "&") }   # `&&`/`;;` split into these
function is_redir(t) { return (t ~ /^>>?$/) }
function walk(orig, m,   w, n, i, j, k, tok, args, sawredir, closing, teehit) {
  gsub(/>&/, "@@", m)          # `@@2` = stdout went to a descriptor; `2@@1` did not
  gsub(/[{}]/, " & ", m)       # tokenize: braces, separators and redirects stand alone
  gsub(/[;|&]/, " & ", m)
  gsub(/>+/, " & ", m)
  n = split(m, w, /[[:space:]]+/)
  for (i = 1; i <= n; i++) {
    tok = w[i]
    if (tok == "elif") { skipthen = 1; continue }          # `elif … then` reopens nothing
    if (tok == "then" && skipthen) { skipthen = 0; continue }
    if (is_open(tok)) { depth++; continue }
    if (is_close(tok)) {
      closing = depth
      sawredir = 0
      for (j = i + 1; j <= n; j++) {                       # the closer's own tail only
        if (is_sep(w[j])) break                            # `} | awk … > f` is out of scope
        if (is_redir(w[j])) { sawredir = 1; break }
      }
      if (closing > 0) depth--
      for (j = 1; j <= npend; j++) {
        if (pend_used[j] || pend_depth[j] < closing) continue
        if (sawredir) { emit(pend_orig[j], pend_line[j]); pend_used[j] = 1 }
        else if (closing - 1 <= 0) pend_used[j] = 1
        else pend_depth[j] = closing - 1
      }
      continue
    }
    if (tok != "echo") continue
    args = ""; sawredir = 0
    for (j = i + 1; j <= n; j++) {
      if (is_sep(w[j]) || is_close(w[j])) break
      if (is_redir(w[j]) || w[j] ~ /^@@/) { sawredir = 1; break }
      args = args " " w[j]
    }
    if (sawredir) continue                                 # check() owns the in-line form
    if (args !~ /[$`]/) continue
    if (j <= n && w[j] == "|") {                           # `echo "$row" | tee -a f`
      for (k = j + 1; k <= n; k++) {
        if (is_sep(w[k])) break
        if (w[k] == "tee") { if (!teehit) { emit(orig, FNR); teehit = 1 } break }
      }
      continue
    }
    # a RECORD: the expansion starts the first argument (the blanked opening quote is the
    # one `_` allowed before it) — the only position `echo`'s option parse can eat.
    if (depth > 0 && args ~ /^[[:space:]]*_?[$`]/) {
      npend++
      pend_orig[npend] = orig; pend_line[npend] = FNR
      pend_depth[npend] = depth; pend_used[npend] = 0
    }
  }
}
FNR == 1 { q = ""; hd = ""; depth = 0; npend = 0; skipthen = 0 }
{
  if (hd != "") {              # a heredoc body is data the script WRITES, not code
    body = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", body)
    if (body == hd) hd = ""
    next
  }
  print "LINE"
  m = code_of($0)
  check($0, m)
  walk($0, m)                  # unconditional: the nesting count must see every line, and
                               # walk() skips any echo check() could have reported
  # Same opener rule as the placeholder block, and the same reason it is not a plain grep:
  # intent-check.sh documents git conflict markers in a comment (`<<<<<<< HEAD`), and a
  # grep for `<<WORD` reads that as a heredoc whose delimiter never arrives — silently
  # skipping the 667 lines below it.
  if (q != "" || !match(m, /<</)) next
  raw = substr($0, RSTART)
  if (raw ~ /^<<</) next
  if (match(raw, /^<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/)) {
    d = substr(raw, RSTART, RLENGTH)
    sub(/^<<-?[[:space:]]*/, "", d); gsub(/['"]/, "", d)
    hd = d
  }
}
RWAWK
rw_scan() { awk -f "$RW_AWK" "$@"; }
RW_REPORT=$SANDBOX/record-write-report.txt
rw_scan "$SKILL_DIR"/scripts/*.sh > "$RW_REPORT"
RW_LINES=$(grep -c '^LINE' "$RW_REPORT" || true)
RW_SCRIPTS=$(printf '%s\n' "$SKILL_DIR"/scripts/*.sh | grep -c . || true)
RW_SRCLINES=$(awk 'END { print NR + 0 }' "$SKILL_DIR"/scripts/*.sh)
# Non-vacuity FIRST, and against the real line total rather than a floor: the only lines a
# working scanner skips are heredoc BODIES (~200 of ~10400 across 38 scripts), so a
# phantom heredoc — the defect above — shows up here as a census that fell off a cliff.
if [[ "${RW_SCRIPTS:-0}" -ge 35 ]] && [[ "${RW_LINES:-0}" -ge $((RW_SRCLINES * 90 / 100)) ]]; then
  pass "the scripts/*.sh census is non-empty ($RW_LINES of $RW_SRCLINES line(s) scanned across $RW_SCRIPTS script(s); the rest are heredoc bodies)"
else
  fail "the scripts/*.sh census is non-empty (scanned ${RW_LINES:-0} of ${RW_SRCLINES:-0} line(s) across ${RW_SCRIPTS:-0} script(s), want >=90% and >=35 scripts — a phantom heredoc opener swallows everything below it)"
fi
# THE EXEMPTION LIST, keyed on the exact STATEMENT and not on the script — a whole-file
# exemption would blind the lint for that file's next record write. Every entry states why
# no option-shaped value can reach argv[1] AT THAT STATEMENT; none of them is "this file is
# fine". Sweeping any of them to printf would be an improvement and would shorten this
# list; until then they are declared with their reason rather than silently tolerated.
#
#   1. run-check-modules.sh's status write. Its value is assigned from a closed literal
#      vocabulary ten lines above it (OK / FAIL / SKIP / EXTRACTOR_MISMATCH — four
#      literals, no caller data anywhere near them).
#   2. bellwether-detect.sh's top-candidate line, inside `done > "$RUN/…-top.txt"` (both
#      scans share the statement byte-for-byte, so one entry covers both). The leading
#      field is `$m/$t` read from the scores file, whose two numbers this script printed
#      itself with awk's `%d` — digits cannot be read as an option, and the arbitrary text
#      (the commit subject) is mid-line.
#   3. ensure-state-ignored.sh's .gitignore append, inside `{ …; echo "$PATTERN"; } >> …`.
#      `PATTERN` is a single-quoted literal assigned at the top of the script, never an
#      argument and never derived from the tree.
# The last two are findings the enclosing-redirect half surfaced on its first run; they are
# listed because they were checked and found safe, not because compounds are tolerated.
RW_EXEMPT=$SANDBOX/record-write-exempt.tsv
{ printf '%s\t%s\n' 'run-check-modules.sh' 'echo "$STATUS" > "$OUT_ABS.status"'
  printf '%s\t%s\n' 'bellwether-detect.sh' 'echo "$m/$t $sha $(git -C "$CACHE" log -1 --pretty=%s "$sha")"'
  printf '%s\t%s\n' 'ensure-state-ignored.sh' '{ [[ -s .gitignore ]] && [[ -n "$(tail -c1 .gitignore)" ]] && echo; echo "$PATTERN"; } >> .gitignore'
} > "$RW_EXEMPT"
RW_HITFILE=$SANDBOX/record-write-hits.tsv
awk -F'\t' '$1 == "HIT" { print $2 "\t" $3 "\t" $4 }' "$RW_REPORT" > "$RW_HITFILE"
RW_TAB=$(printf '\t')
RW_UNEXPECTED=""
RW_CLAIMED=$SANDBOX/record-write-claimed.tsv
: > "$RW_CLAIMED"
while IFS="$RW_TAB" read -r rw_f rw_n rw_stmt; do
  [[ -n "${rw_f:-}" ]] || continue
  rw_key=$(printf '%s\t%s' "$rw_f" "$rw_stmt")
  if grep -qxF -- "$rw_key" "$RW_EXEMPT"; then
    printf '%s\n' "$rw_key" >> "$RW_CLAIMED"
  else
    RW_UNEXPECTED="$RW_UNEXPECTED $rw_f:$rw_n"
  fi
done < "$RW_HITFILE"
if [[ -z "$RW_UNEXPECTED" ]]; then
  pass "no script writes a record into a file with echo-of-a-computed-value"
else
  fail "echo-into-a-file record write(s) — use printf '%s\\n' \"\$v\" (echo swallows an option-shaped value):$RW_UNEXPECTED"
fi
# A stale exemption is worse than none: once the statement is swept to printf the entry
# describes nothing, and the next reader takes it as evidence the class is tolerated.
RW_STALE=""
while IFS= read -r rw_e; do
  [[ -n "$rw_e" ]] || continue
  grep -qxF -- "$rw_e" "$RW_CLAIMED" || RW_STALE="$RW_STALE [${rw_e%%$RW_TAB*}]"
done < "$RW_EXEMPT"
if [[ -z "$RW_STALE" ]]; then
  pass "no exemption is stale (every declared exemption still matches a real echo-write)"
else
  fail "exemption(s) matching nothing in the sweep — drop them from the list:$RW_STALE"
fi

# --- the exclusions and the hazards in one fixture, again as line numbers so a blunt
# scanner and a blind one both name themselves. Lines 12/13/17 are the in-line writes: an
# `&&`-guarded one, a plain ledger append, and one whose literal prefix does not make the
# value any less computed. Lines 18-24 are the enclosing-redirect half — one-line brace,
# multi-line brace, loop, if, and both `tee` forms — each paired below with the legal shape
# it is one character away from.
RW_FIX=$SANDBOX/rw-fixture.sh
cat > "$RW_FIX" <<'RWFIX'
#!/usr/bin/env bash
# prose: echo "$X" > "$f" inside a comment is not a record write
echo OK > "$f"
echo "status: ready" >> "$f"
echo "$X" >&2
echo "$X" 2>&1
echo >> "$f"
printf '%s\n' "$X" > "$f"
echo "component_module: ${M:-<no go.mod>}"
echo '$X' > "$f"
printf '%s\n' "$row" >> "$ledger"; echo done
[ -n "$X" ] && echo "$X" > "$f"
echo "$row" >> "$ledger"
cat <<'EOF' > "$f"
echo "$X" > "$g"
EOF
echo "prefix $X" > "$f"
{ echo "$row"; } >> "$ledger"
{
  echo "$row"
} >> "$ledger"
while read -r l; do echo "$l"; done >> "$ledger"
if [ -n "$row" ]; then echo "$row"; fi > "$f"
echo "$row" | tee -a "$ledger"
echo "$row" | tee "$f" > /dev/null
{ echo OK; echo "label: $X"; } > "$f"
{ printf '%s\n' "$row"; } >> "$ledger"
{ echo "$row"; } | awk 'NR == 1' > "$f"
while :; do echo "$X" >&2; done > "$f"
for f in *; do echo "$f"; done
report() {
  echo "$row"
}
done_marker=1
RWFIX
RW_FIX_HITS=$(rw_scan "$RW_FIX" | awk -F'\t' '$1 == "HIT" { printf "%s ", $3 }')
if [[ "$RW_FIX_HITS" = "12 13 17 18 20 22 23 24 25 " ]]; then
  pass "the scanner reports exactly the nine writes — three in-line, four via a compound closer, two via tee — and none of the legal forms (literal, literal append, >&2, 2>&1, bare echo, printf, quoted-'>', single-quoted value, comment, heredoc body, labelled value in a report block, printf in a brace block, pipeline out of a block, block-level redirect with the echo on >&2, unredirected loop, echo in a function body)"
else
  fail "the record-write fixture must report exactly lines '12 13 17 18 20 22 23 24 25 ' (got '$RW_FIX_HITS' — fewer means a hazard is being excluded, more means a legal form is being flagged)"
fi

# --- and the mutation proof against a REAL script: log-intent.sh's ledger append is the
# exact shape the sweep protects, so turning its printf back into an echo must go red.
# scripts/log-intent.sh on disk is untouched.
RW_SRC=$SKILL_DIR/scripts/log-intent.sh
RW_MUT=$SANDBOX/rw-mutant-log-intent.sh
expect "log-intent.sh still appends its ledger row with printf (the sweep landed)" \
  grep -qE '^printf [^|]* "\$row" >> "\$ledger"$' "$RW_SRC"
sed 's|^printf [^|]* "$row" >> "$ledger"$|echo "$row" >> "$ledger"|' "$RW_SRC" > "$RW_MUT"
refute "the mutant really differs from scripts/log-intent.sh (sanity check on the fixture, not the lint)" \
  cmp -s "$RW_MUT" "$RW_SRC"
RW_MUT_N=$(rw_scan "$RW_MUT" | grep -c '^HIT' || true)
if [[ "${RW_MUT_N:-0}" -eq 1 ]]; then
  pass "reverting log-intent.sh's ledger append from printf to echo goes red (mutation proof)"
else
  fail "reverting log-intent.sh's ledger append from printf to echo goes red (got ${RW_MUT_N:-0} finding(s), want exactly 1)"
fi

# --- and the same revert in each shape that WALKED PAST the first scanner, planted at the
# same real line so the proof is about the rule and not about the fixture. Every one of
# these was verified passing before the enclosing-redirect half existed; each must now
# report exactly one finding, in the real script's own context (a `case`, several
# functions and two loops above it), which is what makes the nesting count the thing under
# test rather than a two-line snippet.
rw_mutate_and_count() { # <tag> <replacement bash, \n-separated>
  local tag="$1" repl="$2" mut n
  mut=$SANDBOX/rw-mutant-$tag.sh
  awk -v repl="$repl" '{ if ($0 ~ /^printf [^|]* "\$row" >> "\$ledger"$/) { gsub(/\\n/, "\n", repl); print repl } else print }' \
    "$RW_SRC" > "$mut"
  if cmp -s "$mut" "$RW_SRC"; then echo "PLANT-FAILED"; return 0; fi
  n=$(rw_scan "$mut" | grep -c '^HIT' || true)
  echo "${n:-0}"
}
while IFS='|' read -r rw_tag rw_desc rw_repl; do
  [[ -n "${rw_tag:-}" ]] || continue
  rw_got=$(rw_mutate_and_count "$rw_tag" "$rw_repl")
  if [[ "$rw_got" = "1" ]]; then
    pass "$rw_desc goes red (mutation proof, one finding)"
  else
    fail "$rw_desc goes red (got '$rw_got' finding(s) in scripts/log-intent.sh's mutant, want exactly 1)"
  fi
done <<'RWMUTS'
brace-oneline|a one-line `{ echo "$row"; } >> "$ledger"`|{ echo "$row"; } >> "$ledger"
brace-multiline|a multi-line brace block redirected at its `}`|{\n  echo "$row"\n} >> "$ledger"
loop|a `while … done >> "$ledger"` around the echo|while :; do echo "$row"; break; done >> "$ledger"
ifthen|an `if … fi >> "$ledger"` around the echo|if [ -n "$row" ]; then echo "$row"; fi >> "$ledger"
tee|an `echo` of the row piped into `tee -a`|echo "$row" | tee -a "$ledger" > /dev/null
RWMUTS
fi

if t "dropped-change evidence PRD: planner evidence pointer, resolver reason discipline, verifier refutation stance, bent-test trigger, silenced-test relay"; then
# Five lints for docs/prd-dropped-change-evidence.md. Pattern-matched on stable
# tokens (script names, closed vocabulary, distinctive phrases) rather than exact
# sentences, so a later reword of the surrounding prose doesn't break these.

# --- 1. agents/planner.md step 1.5: names the evidence artifact, AND the
#        ours/dropped-change sentence no longer points review at `git show HEAD`
#        (scoped — the `merged` bullet legitimately keeps it).
PLN="$SKILL_DIR/agents/planner.md"
expect "agents/planner.md references the dropped-template-changes evidence artifact" \
  grep -qF 'dropped-template-changes' "$PLN"

# Extract the `ours` bullet's own paragraph (up to the `merged` bullet that follows
# it) and the `merged` bullet's paragraph (up to the next `- **` bullet), so the
# git-show-HEAD assertion is scoped to the right one in each direction.
PLN_OURS=$SANDBOX/planner-ours-bullet.txt
PLN_MERGED=$SANDBOX/planner-merged-bullet.txt
awk '/^- \*\*`ours`/{f=1} /^- \*\*`merged`/{f=0} f' "$PLN" > "$PLN_OURS"
awk '/^- \*\*`merged`/{f=1} /^- \*\*`theirs`/{f=0} f' "$PLN" > "$PLN_MERGED"
if [[ -s "$PLN_OURS" ]]; then
  pass "agents/planner.md's ours bullet is locatable"
else
  fail "agents/planner.md's ours bullet is locatable (extraction found nothing — bullet moved or reworded past the anchor)"
fi
if [[ -s "$PLN_MERGED" ]]; then
  pass "agents/planner.md's merged bullet is locatable"
else
  fail "agents/planner.md's merged bullet is locatable (extraction found nothing — bullet moved or reworded past the anchor)"
fi
refute "agents/planner.md's ours/dropped-change bullet no longer points review at git show HEAD (the regression guard) — the invocation form, not an explanatory mention of why it can't work" \
  grep -qiF 'git show head --' "$PLN_OURS"
expect "agents/planner.md's merged bullet still legitimately uses git show HEAD (not a blanket removal)" \
  grep -qiF 'git show head --' "$PLN_MERGED"
# The top-of-file reading-discipline sentence: "dropped changes" must no longer be
# grouped with the files that legitimately earn a full git show HEAD read.
expect "agents/planner.md's top reading-discipline sentence still names merged regions / coverage-blind logic for git show HEAD" \
  grep -qiE 'merged regions.{0,40}coverage-blind' "$PLN"
refute "agents/planner.md's top reading-discipline sentence no longer lists dropped changes among files needing git show HEAD" \
  bash -c "grep -iE 'git show HEAD.{0,80}dropped changes|dropped changes.{0,80}git show HEAD' '$PLN'"

# --- 2. agents/conflict-resolver.md: the ours reason must name what the
#        target/template side changed and is being given up.
CR="$SKILL_DIR/agents/conflict-resolver.md"
expect "agents/conflict-resolver.md ties the ours verdict to a reason requirement" \
  grep -qiE 'ours.{0,200}reason' "$CR"
expect "agents/conflict-resolver.md requires the ours reason to name what the target/template side changed" \
  grep -qiE '(target|template) side changed' "$CR"
expect "agents/conflict-resolver.md requires the ours reason to state what is dropped or given up, not only why ours won" \
  grep -qiE 'given up|this verdict drops|(is|was) dropped' "$CR"

# --- 3. phases/7-execution.md step 5: refutation framing AND an
#        uncertainty-resolves-to-reporting instruction.
EXE="$SKILL_DIR/phases/7-execution.md"
expect "phases/7-execution.md step 5 carries refutation framing (find/refute a defect, not confirm it)" \
  grep -qiE 'refute|find a concrete defect' "$EXE"
expect "phases/7-execution.md step 5 resolves uncertainty toward reporting rather than toward PASS" \
  grep -qiE 'uncertainty.{0,80}(toward|resolves).{0,80}(report|PASS)' "$EXE"

# --- 4. phases/7-execution.md: the bent-test trigger — a modified pre-existing
#        test file makes the verifier run, and the prompt diffs against the
#        structural commit (STRUCTURAL_SHA).
expect "phases/7-execution.md names a bent-test trigger" \
  grep -qi 'bent-test trigger' "$EXE"
expect "phases/7-execution.md's bent-test trigger reads STRUCTURAL_SHA from the anchor" \
  grep -qF 'STRUCTURAL_SHA' "$EXE"
expect "phases/7-execution.md's bent-test trigger fires the verifier even when Approach would otherwise exempt the task" \
  grep -qiE 'otherwise exempt' "$EXE"
expect "phases/7-execution.md instructs diffing a bent test against the structural commit" \
  grep -qiE 'git show <?STRUCTURAL_SHA' "$EXE"

# --- 5. phases/8-finalize.md step 1: runs the silenced-test scan and relays
#        its findings (scoped to step 1, before the baseline advance in step 5).
FIN="$SKILL_DIR/phases/8-finalize.md"
FIN_STEP1=$SANDBOX/finalize-step1.txt
awk '/^### 1\./{f=1} /^### 2\./{f=0} f' "$FIN" > "$FIN_STEP1"
if [[ -s "$FIN_STEP1" ]]; then
  pass "phases/8-finalize.md step 1 is locatable"
else
  fail "phases/8-finalize.md step 1 is locatable (extraction found nothing — step numbering moved)"
fi
expect "phases/8-finalize.md step 1 runs scripts/silenced-tests.sh" \
  grep -qF 'scripts/silenced-tests.sh' "$FIN_STEP1"
expect "phases/8-finalize.md step 1 relays the silenced-test findings alongside the verdict card" \
  grep -qiE 'relay.{0,40}(its )?findings.{0,60}(alongside|beside).{0,20}(verdict card|gate)' "$FIN_STEP1"
fi

if t "test-population census PRD: recorded through write-test-commands.sh, the empty-baseline refusal, the final-gate relay, and unattributed labeling"; then
# Four lints for docs/prd-test-population-census.md. Pattern-matched on stable
# tokens (script names, closed vocabulary) rather than exact sentences, so a
# later reword of the surrounding prose doesn't break these.

# --- 1. phases/4.5-test-baseline.md: the census recipe is recorded THROUGH
#        write-test-commands.sh — a CENSUS= value passed into that same call —
#        never a hand write to the sibling file.
BASE45="$SKILL_DIR/phases/4.5-test-baseline.md"
expect "phases/4.5-test-baseline.md passes a CENSUS= value to write-test-commands.sh" \
  bash -c "grep -B6 'write-test-commands\.sh\"' '$BASE45' | grep -q 'CENSUS='"
refute "phases/4.5-test-baseline.md never hand-writes the sibling census-command.txt file" \
  grep -qE '(^|[^A-Za-z])>{1,2}[[:space:]]*\"?\$RUN/census-command\.txt\"?' "$BASE45"

# --- 2. phases/4.5-test-baseline.md: the empty-baseline-population refusal — a
#        census recipe is recorded only on non-empty evidence.
expect "phases/4.5-test-baseline.md states the empty-baseline-population refusal" \
  grep -qiE 'empty.{0,40}population.{0,80}(refus|not recorded|never recorded)' "$BASE45"

# --- 3. phases/8-finalize.md step 1: relays the census row and names its
#        INCOMPLETE vocabulary (scoped to step 1, same extraction the
#        dropped-change-evidence block above already proved locatable).
FIN="$SKILL_DIR/phases/8-finalize.md"
CENSUS_FIN_STEP1=$SANDBOX/finalize-step1-census.txt
awk '/^### 1\./{f=1} /^### 2\./{f=0} f' "$FIN" > "$CENSUS_FIN_STEP1"
if [[ -s "$CENSUS_FIN_STEP1" ]]; then
  pass "phases/8-finalize.md step 1 is locatable (census relay check)"
else
  fail "phases/8-finalize.md step 1 is locatable (census relay check) (extraction found nothing — step numbering moved)"
fi
expect "phases/8-finalize.md step 1 relays the census row" \
  grep -qiE '`?census`? row' "$CENSUS_FIN_STEP1"
expect "phases/8-finalize.md step 1 names the census row's INCOMPLETE vocabulary" \
  grep -qF 'INCOMPLETE' "$CENSUS_FIN_STEP1"
expect "phases/8-finalize.md step 1 still relays the silenced-test findings (unchanged by the census addition)" \
  grep -qiE 'relay.{0,40}(its )?findings.{0,60}(alongside|beside).{0,20}(verdict card|gate)' "$CENSUS_FIN_STEP1"

# --- 4. reference/gates.md: a degraded (postmerge-census-absent) diff labels its
#        findings unattributed.
expect "reference/gates.md states that unattributed findings are labeled as such" \
  grep -qi 'unattributed' "$SKILL_DIR/reference/gates.md"
fi

if t "review-followup PRD: Phase 5's region logging and amend re-record, Phase 7's STRUCTURAL_SHA hard guard, Phase 8's PREV_SHA fallback, continue.md's structural-commit recovery"; then
# Five prose contracts from docs/prd-review-followup-component-update-skill.md. Each one
# is a rule the runtime cannot enforce for itself: a fallback snippet that instructed a
# ledger call log-resolution.sh REFUSES (a region verdict with no ordinal), a cross-phase
# anchor value that went stale on the two sanctioned amend paths, a bare read whose empty
# expansion turned the bent-test verifier into a diff of a file against itself, and a scan
# skipped while its input still sat in the manifest. Every anchor below is proven in BOTH
# directions — the pre-fix semantics goes red, and an extractor that matches nothing fails
# instead of passing vacuously — because these are exactly the lints that go stale silently.
RF_P5=$SKILL_DIR/phases/5-structural.md
RF_EXE=$SKILL_DIR/phases/7-execution.md
RF_FIN=$SKILL_DIR/phases/8-finalize.md
RF_CONT=$SKILL_DIR/reference/continue.md

# --- 1. Phase 5's no-runtime-dispatch arm logs one row per conflict REGION, with the
#        ordinal. SCOPED to that arm on purpose: the dispatched arm above it already
#        states the contract (and agents/conflict-resolver.md states it in full), so a
#        whole-file grep passes on THEIR text while the fallback keeps instructing the
#        refused per-file call — which is precisely the defect that shipped.
rf_p5_fallback_arm() { # rf_p5_fallback_arm <5-structural.md> → that arm's slice
  awk '/^- \*\*No runtime dispatch\*\*/{f=1} f && /^[^[:space:]-]/{f=0} f' "$1"
}
RF_ARM=$SANDBOX/rf-p5-fallback-arm.txt
rf_p5_fallback_arm "$RF_P5" > "$RF_ARM"
RF_ARM_N=$(grep -c . "$RF_ARM" || true)
if [[ "${RF_ARM_N:-0}" -ge 8 ]] && [[ "${RF_ARM_N:-0}" -le 60 ]]; then
  pass "phase 5's no-runtime-dispatch arm extracts tightly ($RF_ARM_N lines)"
else
  fail "phase 5's no-runtime-dispatch arm extracts tightly (got ${RF_ARM_N:-0} lines — <8 means the bullet moved or was reworded past the anchor, >60 means the closing paragraph no longer ends the slice)"
fi
expect "the fallback arm states the ledger's unit is the region, logged once per region" \
  grep -qiE 'once per region' "$RF_ARM"
expect "the fallback arm names the 1-based ordinal the script requires" \
  grep -qiE '1-based ordinal' "$RF_ARM"
expect "the fallback arm keeps the reasoning-bucket verdicts at once per file" \
  bash -c "grep -qiE 'once per file' '$RF_ARM'"
refute "the fallback arm no longer frames conflict-region logging as once per resolved file" \
  grep -qiF 'once per resolved file' "$RF_ARM"
# The invocation itself, not only the prose around it: every log-resolution.sh call in
# this arm must carry REGION beside its VERDICT, or the row is refused (exit 2) at
# runtime and the arm's instructions cannot be followed at all.
rf_p5_arm_pairs_region() { # rf_p5_arm_pairs_region <5-structural.md>
  local v r
  v=$(rf_p5_fallback_arm "$1" | grep -c 'VERDICT=' || true)
  r=$(rf_p5_fallback_arm "$1" | grep -c 'REGION=' || true)
  [[ "${v:-0}" -ge 2 ]] || return 1
  [[ "${r:-0}" -ge "${v:-0}" ]] || return 1
}
expect "every VERDICT= invocation in the fallback arm carries a REGION= beside it" \
  rf_p5_arm_pairs_region "$RF_P5"
# non-vacuity 1: strip REGION from the file and the pairing check must go red. The
# mutation is structural (drop the lines the check counts), so it encodes no wording.
RF_P5_NOREGION=$SANDBOX/rf-p5-no-region.md
grep -v 'REGION=' "$RF_P5" > "$RF_P5_NOREGION"
refute "the no-REGION mutant really differs from phases/5-structural.md (sanity check on the fixture, not the lint)" \
  cmp -s "$RF_P5_NOREGION" "$RF_P5"
refute "dropping REGION from the fallback arm's invocations is caught (mutation proof)" \
  rf_p5_arm_pairs_region "$RF_P5_NOREGION"
# non-vacuity 2: an extractor that finds no arm at all must FAIL, never pass on an
# empty slice — the fail-closed direction every anchor here needs.
refute "the pairing check refuses a file with no no-runtime-dispatch arm (fails loudly, not vacuously)" \
  rf_p5_arm_pairs_region "$RF_EXE"

# --- 2. Phase 5 step 9: BOTH amend arms (the replace-directive drop, FAIL option a)
#        re-record STRUCTURAL_SHA before the gate re-run. The invariant is stated as a
#        correspondence rather than a count of one wording: every line of step 9 that
#        talks about amending must also name the key it invalidates, so a third amend
#        arm added later without a re-record goes red on arrival.
rf_p5_step9() { awk '/^### 9\./{f=1} f' "$1"; }
rf_p5_amend_arms_rerecord() { # rf_p5_amend_arms_rerecord <5-structural.md>
  local a b
  a=$(rf_p5_step9 "$1" | grep -ic 'amend' || true)
  b=$(rf_p5_step9 "$1" | grep -i 'amend' | grep -c 'STRUCTURAL_SHA' || true)
  [[ "${a:-0}" -ge 2 ]] || return 1
  [[ "${a:-0}" = "${b:-0}" ]] || return 1
}
expect "every amend arm in phase 5 step 9 names the STRUCTURAL_SHA re-record" \
  rf_p5_amend_arms_rerecord "$RF_P5"
# Slice to a file for the two piped greps below: `bash -c` gets a fresh shell with none
# of this suite's functions in it, so a `rf_p5_step9 | grep` inside one silently reads
# an empty stream and the assertion passes on nothing.
RF_STEP9=$SANDBOX/rf-p5-step9.txt
rf_p5_step9 "$RF_P5" > "$RF_STEP9"
RF_STEP9_N=$(grep -c . "$RF_STEP9" || true)
if [[ "${RF_STEP9_N:-0}" -ge 10 ]]; then
  pass "phase 5's step 9 extracts ($RF_STEP9_N lines)"
else
  fail "phase 5's step 9 extracts (got ${RF_STEP9_N:-0} lines — the '### 9.' heading moved)"
fi
expect "phase 5 step 9 re-records the key through record-context.sh, not by hand" \
  bash -c "grep -F 'record-context.sh' '$RF_STEP9' | grep -q 'STRUCTURAL_SHA='"
expect "phase 5 step 9 orders the re-record before the gate re-run" \
  bash -c "grep -i 'STRUCTURAL_SHA' '$RF_STEP9' | grep -qiE 'before the gate re-run|before re-running the gate'"
# non-vacuity 1: an amend arm that stops naming the key goes red. The mutation blanks
# the token on the FIRST such line only — one arm regressing, which is the real shape of
# this drift — and leaves every other assertion above satisfiable.
RF_P5_AMEND_MUT=$SANDBOX/rf-p5-amend-arm-no-rerecord.md
awk '/^### 9\./ { s = 1 }
     s && !done && /amend/ && /STRUCTURAL_SHA/ { gsub(/STRUCTURAL_SHA/, "the structural commit"); done = 1 }
     { print }' "$RF_P5" > "$RF_P5_AMEND_MUT"
refute "the amend-arm mutant really differs from phases/5-structural.md (sanity check on the fixture, not the lint)" \
  cmp -s "$RF_P5_AMEND_MUT" "$RF_P5"
refute "one amend arm dropping the re-record is caught (mutation proof)" \
  rf_p5_amend_arms_rerecord "$RF_P5_AMEND_MUT"
# non-vacuity 2: a file with no step 9 must be refused, not read as compliant.
refute "the amend-arm check refuses a file with no step 9 (fails loudly, not vacuously)" \
  rf_p5_amend_arms_rerecord "$RF_EXE"

# --- 3. Phase 7's bent-test trigger reads STRUCTURAL_SHA through the `:?` hard guard.
#        `ctx` only REPORTS a missing key (it exits 0), so a bare read leaves the
#        expansion empty: `git cat-file -e ":<path>"` then hits the INDEX (present for
#        every tracked file) and the verifier's `git show :<path>` shows the file's own
#        content — it diffs the test against itself and returns PASS. Scoped to step 5,
#        the only place the trigger is specified.
rf_p7_step5() { awk '/^5\. \*\*Risky tasks/{f=1} /^6\. /{f=0} f' "$1"; }
RF_P7_STEP5=$SANDBOX/rf-p7-step5.txt
rf_p7_step5 "$RF_EXE" > "$RF_P7_STEP5"
RF_P7_N=$(grep -c . "$RF_P7_STEP5" || true)
if [[ "${RF_P7_N:-0}" -ge 8 ]] && [[ "${RF_P7_N:-0}" -le 80 ]]; then
  pass "phase 7's risky-task step extracts tightly ($RF_P7_N lines)"
else
  fail "phase 7's risky-task step extracts tightly (got ${RF_P7_N:-0} lines — the step numbering moved, or step 6 no longer closes the slice)"
fi
rf_p7_hard_guards_sha() { # rf_p7_hard_guards_sha <7-execution.md>
  rf_p7_step5 "$1" | grep -qF '${STRUCTURAL_SHA:?'
}
expect "phase 7's bent-test trigger reads STRUCTURAL_SHA through the :? hard guard" \
  rf_p7_hard_guards_sha "$RF_EXE"
expect "phase 7 says what an empty STRUCTURAL_SHA would do instead (the vacuous pass it prevents)" \
  grep -qiE 'against itself|vacuous' "$RF_P7_STEP5"
# non-vacuity 1: deleting the guard line — the pre-fix state, where the key was read
# bare — must go red.
RF_P7_MUT=$SANDBOX/rf-p7-no-hard-guard.md
grep -vF '${STRUCTURAL_SHA:?' "$RF_EXE" > "$RF_P7_MUT"
refute "the hard-guard mutant really differs from phases/7-execution.md (sanity check on the fixture, not the lint)" \
  cmp -s "$RF_P7_MUT" "$RF_EXE"
refute "reading STRUCTURAL_SHA bare (guard line deleted) is caught (mutation proof)" \
  rf_p7_hard_guards_sha "$RF_P7_MUT"
# non-vacuity 2: a file with no risky-task step must be refused, not pass on an empty slice.
refute "the hard-guard check refuses a file with no risky-task step (fails loudly, not vacuously)" \
  rf_p7_hard_guards_sha "$RF_P5"

# --- 4. Phase 8 step 1's silenced-test scan falls back to the manifest's
#        in_progress.previous_sha — the same source step 5 already trusts — and the
#        skip-that-escalates survives only when NEITHER source has the SHA.
rf_f8_step1() { awk '/^### 1\./{f=1} /^### 2\./{f=0} f' "$1"; }
rf_f8_step1_manifest_fallback() { # rf_f8_step1_manifest_fallback <8-finalize.md>
  rf_f8_step1 "$1" | grep -qF 'in_progress.previous_sha'
}
rf_f8_step1_skip_conditional() { # rf_f8_step1_skip_conditional <8-finalize.md>
  rf_f8_step1 "$1" | grep -i 'skip that escalates' | grep -qiE 'neither|only when'
}
expect "phase 8 step 1 takes PREV_SHA from the manifest when the anchor lacks it" \
  rf_f8_step1_manifest_fallback "$RF_FIN"
expect "phase 8 step 1's skip-that-escalates applies only when neither source has PREV_SHA" \
  rf_f8_step1_skip_conditional "$RF_FIN"
# non-vacuity 1a: remove the fallback and the fallback check goes red.
RF_F8_NOFB=$SANDBOX/rf-f8-no-fallback.md
grep -vF 'in_progress.previous_sha' "$RF_FIN" > "$RF_F8_NOFB"
refute "the no-fallback mutant really differs from phases/8-finalize.md (sanity check on the fixture, not the lint)" \
  cmp -s "$RF_F8_NOFB" "$RF_FIN"
refute "dropping the manifest fallback from step 1 is caught (mutation proof)" \
  rf_f8_step1_manifest_fallback "$RF_F8_NOFB"
# non-vacuity 1b: reverting the skip sentence to its unconditional form goes red. The
# mutation blanks the two conditioning markers rather than restating the old sentence.
RF_F8_UNCOND=$SANDBOX/rf-f8-unconditional-skip.md
# Both markers, in either capitalization — awk's gsub is case-sensitive and a
# sentence-initial "Only when" would otherwise survive the mutation and keep the
# check green over a mutant that no longer conditions the skip on anything.
awk '/skip that escalates/ { gsub(/[Nn]either/, "no"); gsub(/[Oo]nly when/, "when") } { print }' \
  "$RF_FIN" > "$RF_F8_UNCOND"
refute "the unconditional-skip mutant really differs from phases/8-finalize.md (sanity check on the fixture, not the lint)" \
  cmp -s "$RF_F8_UNCOND" "$RF_FIN"
refute "an unconditional skip-that-escalates is caught (mutation proof)" \
  rf_f8_step1_skip_conditional "$RF_F8_UNCOND"
# non-vacuity 2: both checks must refuse a file with no step 1 rather than pass empty.
refute "the fallback check refuses a file with no step 1 (fails loudly, not vacuously)" \
  rf_f8_step1_manifest_fallback "$RF_CONT"
refute "the conditional-skip check refuses a file with no step 1 (fails loudly, not vacuously)" \
  rf_f8_step1_skip_conditional "$RF_CONT"

# --- 5. continue.md's lost-anchor arm: STRUCTURAL_SHA has a recovery rule (locate the
#        structural commit by its fixed subject, confirm with the user on an amended or
#        ambiguous history) and is therefore NOT on the genuinely-lost list. The list is
#        anchored as its own sentence, because the paragraph that carries it legitimately
#        names the key while saying it is recoverable.
rf_cont_lost_arm() { # rf_cont_lost_arm <continue.md> → the swept-anchor recovery arm
  awk '/context\.env` is gone entirely/{f=1} f && /^2\. /{f=0} f' "$1"
}
RF_LOST=$SANDBOX/rf-continue-lost-arm.txt
rf_cont_lost_arm "$RF_CONT" > "$RF_LOST"
RF_LOST_N=$(grep -c . "$RF_LOST" || true)
if [[ "${RF_LOST_N:-0}" -ge 10 ]] && [[ "${RF_LOST_N:-0}" -le 80 ]]; then
  pass "continue.md's lost-anchor arm extracts tightly ($RF_LOST_N lines)"
else
  fail "continue.md's lost-anchor arm extracts tightly (got ${RF_LOST_N:-0} lines — the arm's opening sentence moved, or step 2 no longer closes the slice)"
fi
expect "the lost-anchor arm carries a STRUCTURAL_SHA recovery rule" \
  grep -qF 'STRUCTURAL_SHA' "$RF_LOST"
expect "the recovery locates the structural commit by its fixed commit subject" \
  grep -qF 'chore: structural merge' "$RF_LOST"
expect "the recovered SHA is re-recorded through record-context.sh" \
  bash -c "grep -F 'record-context.sh' '$RF_LOST' | grep -q 'STRUCTURAL_SHA'"
expect "the recovery requires user confirmation on an amended or ambiguous history" \
  bash -c "grep -iE 'amend|rebas|not exactly one' '$RF_LOST' | grep -qiE 'confirm|ask the user'"
# The genuinely-lost list, as its own sentence: exactly the two keys the manifest cannot
# supply, and STRUCTURAL_SHA is not one of them.
RF_LOSTLIST=$SANDBOX/rf-continue-lost-list.txt
grep -o 'genuinely lost[^.]*\.' "$RF_CONT" > "$RF_LOSTLIST" || true
if [[ "$(wc -c < "$RF_LOSTLIST" | tr -d ' ')" -ge 40 ]]; then
  pass "continue.md's genuinely-lost sentence extracts"
else
  fail "continue.md's genuinely-lost sentence extracts (got $(wc -c < "$RF_LOSTLIST" | tr -d ' ') bytes — the 'genuinely lost' wording moved, so the list below is unanchored)"
fi
expect "the genuinely-lost list still names TEMPLATE_PATH" grep -qF 'TEMPLATE_PATH' "$RF_LOSTLIST"
expect "the genuinely-lost list still names SQUASH_ON_FINISH" grep -qF 'SQUASH_ON_FINISH' "$RF_LOSTLIST"
rf_lost_list_excludes_sha() { # rf_lost_list_excludes_sha <continue.md>
  local s
  s=$(grep -o 'genuinely lost[^.]*\.' "$1")
  [[ -n "$s" ]] || return 1
  printf '%s\n' "$s" | grep -qF 'STRUCTURAL_SHA' && return 1
  return 0
}
expect "the genuinely-lost list does NOT include STRUCTURAL_SHA (it is recoverable from history)" \
  rf_lost_list_excludes_sha "$RF_CONT"
# non-vacuity: putting the key back on that list goes red, and a file with no such
# sentence is refused rather than passed.
RF_CONT_MUT=$SANDBOX/rf-continue-sha-lost-again.md
awk '/genuinely lost/ { sub(/`TEMPLATE_PATH`/, "`STRUCTURAL_SHA` and `TEMPLATE_PATH`") } { print }' \
  "$RF_CONT" > "$RF_CONT_MUT"
refute "the lost-list mutant really differs from reference/continue.md (sanity check on the fixture, not the lint)" \
  cmp -s "$RF_CONT_MUT" "$RF_CONT"
refute "listing STRUCTURAL_SHA as genuinely lost again is caught (mutation proof)" \
  rf_lost_list_excludes_sha "$RF_CONT_MUT"
refute "the lost-list check refuses a file carrying no such sentence (fails loudly, not vacuously)" \
  rf_lost_list_excludes_sha "$RF_EXE"
fi

if t "recurrence lint: the review-fix contracts stay pinned across their files"; then
# Each assertion here holds a cross-file contract a review found broken, so the same
# contradiction cannot silently reopen in a later edit (PRD: fix-review defects).

# (a) The actual-model probe is the run's only wrong-model check, and both dispatched
# role files impose an exclusive return-shape template — so each MUST carve the probe an
# explicit exception, or a subagent following its template drops the one signal the check
# reads (Finding 3).
for rf in agents/executor.md agents/conflict-resolver.md; do
  expect "$rf carves the actual-model probe into its return-shape contract" \
    bash -c "grep -qiF 'which model you believe you are' '$SKILL_DIR/$rf'"
done
expect "SKILL.md still describes the first-dispatch actual-model probe (the contract both role files serve)" \
  grep -qiF 'model it believes it is' "$SKILL_DIR/SKILL.md"

# (b) The intent ledger is the only bridge a Phase 5 redo / plan revision / Phase 8
# promotion crosses without re-asking the user — so the planner records its Q&A at answer
# time, Phase 6 verifies the ledger grew, and Phase 7's needs-input arm records too
# (Finding 2). Each of the three must name the logger.
expect "planner.md records each grill answer via log-intent.sh at answer time" \
  bash -c "grep -qF 'log-intent.sh' '$SKILL_DIR/agents/planner.md' && grep -qiF 'answer time' '$SKILL_DIR/agents/planner.md'"
expect "phases/6-planning.md makes the orchestrator confirm the planner Q&A reached the ledger before the plan commit" \
  bash -c "grep -qF 'qa-ledger.tsv' '$SKILL_DIR/phases/6-planning.md' && grep -qF 'log-intent.sh' '$SKILL_DIR/phases/6-planning.md'"
expect "phases/7-execution.md's needs-input arm records the answer via log-intent.sh" \
  bash -c "grep -qi 'needed input' '$SKILL_DIR/phases/7-execution.md' && grep -qF 'log-intent.sh' '$SKILL_DIR/phases/7-execution.md'"

# (c) The synthetic repo addresses its two sides by git TAG at the repo root — there is no
# $SYNTH/target or $SYNTH/base subdirectory, and abort's debris classifier used to probe
# one (Finding 5). No doc may reintroduce the dead path, and abort must use the tag check.
expect "abort.md classifies template debris by the target-side git tag" \
  grep -qF 'kairos-target:' "$SKILL_DIR/reference/abort.md"
refute "no skill doc probes a nonexistent \$SYNTH/target or \$SYNTH/base subdirectory" \
  grep -rF -e '$SYNTH/target' -e '$SYNTH/base' \
    "$SKILL_DIR/SKILL.md" "$SKILL_DIR/reference" "$SKILL_DIR/phases" "$SKILL_DIR/agents"

# (d) resolve-models.sh has TWO exits that leave an existing model.txt intact (the
# phase-key refusal and the override-shape refusal); Phase 1.5 named only the first, and
# the reference doc names both (Finding 6). Both files must name both, so an orchestrator
# never hand-deletes a still-valid pin file after a rejected override.
for f in phases/1.5-model-resolution.md reference/model-resolution.md; do
  expect "$f names BOTH no-wipe exits (phase-key refusal and override-shape refusal)" \
    bash -c "grep -qiF 'phase-key refusal' '$SKILL_DIR/$f' && grep -qiF 'override-shape refusal' '$SKILL_DIR/$f'"
done

# (18) The Phase 8 empty-PREV_SHA rationale points at its twin in Phase 4. It used to cite
# a line RANGE, which silently drifted onto a blank line — so the citation is now symbolic
# (it names Phase 4's `.gitignore`-add if-form block, not a line number). Confirm both ends
# still hold: Phase 8 names the Phase 4 file symbolically, and Phase 4 actually carries the
# if-form/no-op rationale being pointed at — so a future edit that removes either goes red.
expect "phases/8-finalize.md points at phases/4-migration-branch.md for the empty-PREV_SHA if-form (symbolic, not a line range)" \
  bash -c "grep -qF 'phases/4-migration-branch.md' '$SKILL_DIR/phases/8-finalize.md'"
refute "phases/8-finalize.md has NOT regressed to a brittle line-range citation" \
  grep -qE 'phases/4-migration-branch\.md:[0-9]+-[0-9]+' "$SKILL_DIR/phases/8-finalize.md"
expect "phases/4-migration-branch.md carries the if-form/no-op rationale Phase 8 points at" \
  bash -c "grep -qiF 'no-op' '$SKILL_DIR/phases/4-migration-branch.md' && grep -qiF 'if-form' '$SKILL_DIR/phases/4-migration-branch.md'"
fi

if t "recurrence lint: the run's SOURCE is one env across pre-flight, the consent step, continue and finalize"; then
# Five contracts a review found broken, each pinned where it can silently reopen.

# (a) RUN_SOURCE is pre-flight's switch, and BOTH checks that key off it exist in the
# script — not just in the prose. The chained frontend re-entry stands on a FINISHED
# template run's branch with no live block (PRD story 12), which is the crash window's
# shape and the opposite meaning; the env is the only thing that tells them apart.
PFS=$SKILL_DIR/scripts/pre-flight.sh
expect "pre-flight.sh accepts RUN_SOURCE and refuses an unknown value" \
  bash -c "grep -qE \"^  ''\\|template\\|frontend\\) ;;\" '$PFS'"
expect "pre-flight.sh check 3 has a frontend arm for the block-less migration-shaped branch" \
  bash -c "grep -qF 'RUN_SOURCE\" = frontend ]' '$PFS'"
expect "pre-flight.sh still refuses that branch without the env (the crash-window message survives)" \
  bash -c "grep -qF 'records no migration in progress' '$PFS'"
expect "pre-flight.sh check 0b skips the CLI probe on a frontend run" \
  bash -c "grep -qF 'Kairos CLI probe not applicable' '$PFS'"
expect "pre-flight.sh records the run's source on the anchor when it was given one" \
  bash -c "grep -qF 'RUN_SOURCE=\$RUN_SOURCE' '$PFS'"

# (b) The three docs that own those two behaviours must document the env — and must no
# longer carry the admissions that stood in for it. A "known gap" note left next to a
# working switch is worse than no note: it tells the next reader not to rely on it.
expect "reference/pre-flight.md documents RUN_SOURCE as check 3's chained-case switch" \
  bash -c "grep -qF 'RUN_SOURCE=frontend' '$SKILL_DIR/reference/pre-flight.md'"
refute "reference/pre-flight.md no longer admits the chained case as a known gap" \
  grep -qiF 'known gap' "$SKILL_DIR/reference/pre-flight.md"
refute "reference/pre-flight.md no longer says the CLI probe does not key off the source" \
  grep -qiF 'does not yet key off' "$SKILL_DIR/reference/pre-flight.md"
expect "reference/pre-flight.md states the frontend arm of check 0b (not applicable, no probe)" \
  bash -c "grep -qiF 'not applicable' '$SKILL_DIR/reference/pre-flight.md'"
expect "phases/1-preflight.md passes RUN_SOURCE into the pre-flight call" \
  bash -c "grep -qF 'RUN_SOURCE=\"\$RUN_SOURCE\"' '$SKILL_DIR/phases/1-preflight.md'"
expect "phases/8-finalize.md's frontend re-entry names the env the chained run must pass" \
  bash -c "grep -qF 'RUN_SOURCE=frontend' '$SKILL_DIR/phases/8-finalize.md'"

# (c) THE ORDER of the frontend-consent rules, asserted as an order and not as prose.
# What the user SAID must be settled before anything is inferred from the component's
# state: with the bootstrap ask ahead of them, a template-only invocation on a legacy
# component with web/ gets asked (it must be silent) and an explicit "both" gets re-asked.
CONS=$SANDBOX/consent-rules.txt
awk '/^Then apply the rules in this order/{f=1} f && /^\*\*Starting one means/{f=0} f && /^[0-9]+\. /{print}' \
  "$SKILL_DIR/phases/8-finalize.md" > "$CONS"
CONS_N=$(grep -c . "$CONS" || true)
if [[ "${CONS_N:-0}" -eq 6 ]]; then
  pass "the frontend-consent rule list extracts as six ordered rules"
else
  fail "the frontend-consent rule list extracts as six ordered rules (got ${CONS_N:-0} — the list moved or changed length)"
fi
cons_rule_no() { # cons_rule_no <needle...> → the rule number whose text matches all needles
  local n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    local all=1 needle
    for needle in "$@"; do
      case "$line" in *"$needle"*) ;; *) all=0 ;; esac
    done
    [[ "$all" = 1 ]] && { printf '%s\n' "$n"; return 0; }
  done < "$CONS"
  return 1
}
R_TEMPLATE_ONLY=$(cons_rule_no 'Intent `template-only`' || echo 0)
R_EXPLICIT=$(cons_rule_no 'Intent `frontend-only` or `both`' || echo 0)
R_BOOTSTRAP=$(cons_rule_no 'FRONTEND_BOOTSTRAP' || echo 0)
R_UNSAID=$(cons_rule_no 'Intent `unsaid`' || echo 0)
if [[ "$R_TEMPLATE_ONLY" -gt 0 ]] && [[ "$R_EXPLICIT" -gt 0 ]] && [[ "$R_BOOTSTRAP" -gt 0 ]] && [[ "$R_UNSAID" -gt 0 ]]; then
  pass "all four order-sensitive consent rules are locatable (template-only=$R_TEMPLATE_ONLY explicit=$R_EXPLICIT bootstrap=$R_BOOTSTRAP unsaid=$R_UNSAID)"
else
  fail "all four order-sensitive consent rules are locatable (template-only=$R_TEMPLATE_ONLY explicit=$R_EXPLICIT bootstrap=$R_BOOTSTRAP unsaid=$R_UNSAID)"
fi
if [[ "$R_TEMPLATE_ONLY" -lt "$R_BOOTSTRAP" ]]; then
  pass "template-only (skip silently) is decided BEFORE the bootstrap ask"
else
  fail "template-only (skip silently) is decided BEFORE the bootstrap ask — a legacy component with web/ would be asked"
fi
if [[ "$R_EXPLICIT" -lt "$R_BOOTSTRAP" ]]; then
  pass "frontend-only/both (never re-ask) is decided BEFORE the bootstrap ask"
else
  fail "frontend-only/both (never re-ask) is decided BEFORE the bootstrap ask — an explicit 'both' would be re-asked"
fi
if [[ "$R_BOOTSTRAP" -lt "$R_UNSAID" ]]; then
  pass "the bootstrap ask precedes the plain unsaid ask (it is the no-SHA case of it)"
else
  fail "the bootstrap ask precedes the plain unsaid ask (it is the no-SHA case of it)"
fi
# The prose's own count of silent outcomes has to match the list it introduces.
expect "the lead sentence counts four of the six as ending in no question" \
  bash -c "grep -qiF 'four of the six' '$SKILL_DIR/phases/8-finalize.md'"
refute "the stale three-of-six count is gone" \
  grep -qiF 'three of the six' "$SKILL_DIR/phases/8-finalize.md"
# Mutation proof: swapping the bootstrap rule ahead of the explicit-intent one must go red.
CONS_MUT=$SANDBOX/consent-rules-mutant.txt
awk -v b="$R_BOOTSTRAP" -v e="$R_EXPLICIT" 'NR==b{bl=$0} NR==e{el=$0} {l[NR]=$0} END{l[b]=el; l[e]=bl; for(i=1;i<=NR;i++) print l[i]}' \
  "$CONS" > "$CONS_MUT"
refute "the swapped-rule mutant really differs from the real list (sanity check on the fixture)" \
  cmp -s "$CONS_MUT" "$CONS"
CONS_REAL=$CONS; CONS=$CONS_MUT
MUT_EXPLICIT=$(cons_rule_no 'Intent `frontend-only` or `both`' || echo 0)
MUT_BOOTSTRAP=$(cons_rule_no 'FRONTEND_BOOTSTRAP' || echo 0)
CONS=$CONS_REAL
if [[ "$MUT_EXPLICIT" -gt "$MUT_BOOTSTRAP" ]]; then
  pass "the order assertion really is order-sensitive (the mutant inverts it)"
else
  fail "the order assertion really is order-sensitive (the mutant inverts it: explicit=$MUT_EXPLICIT bootstrap=$MUT_BOOTSTRAP)"
fi

# (d) continue.md must re-materialize through the arm the run's source belongs to, and
# must rebuild RUN_SOURCE when it rebuilds a lost anchor — it IS derivable there, from
# whichever <source>.in_progress block is live, which is how that arm already derives SRC.
CONT=$SKILL_DIR/reference/continue.md
expect "continue.md's \$SYNTH re-establish step names the frontend builder too" \
  bash -c "grep -qF 'materialize-frontend.sh' '$CONT'"
expect "and says the frontend arm needs no Kairos CLI" \
  bash -c "grep -F 'materialize-frontend.sh' '$CONT' | grep -qiF 'no Kairos CLI'"
expect "continue.md's lost-anchor arm re-records RUN_SOURCE from the live block" \
  bash -c "grep -F 'record-context.sh' '$CONT' | grep -q 'RUN_SOURCE=\$SRC'"
expect "continue.md passes RUN_SOURCE into its pre-flight call" \
  bash -c "grep -qF 'RUN_SOURCE=\"\$RUN_SOURCE\"' '$CONT'"
refute "SKILL.md no longer claims RUN_SOURCE cannot be re-derived mid-run" \
  grep -qF 'nothing on disk can re-derive mid-run' "$SKILL_DIR/SKILL.md"
expect "SKILL.md says instead that the live block derives it" \
  bash -c "grep -qF 'derivable from the live block' '$SKILL_DIR/SKILL.md'"

# (e) Phase 8's advance refuses a source disagreement: the manifest block and the anchor
# answer "which source is this run" independently, and a mismatch means this run's gates
# ran for the other source — a frontend baseline must never advance on a root Go suite.
expect "phases/8-finalize.md's advance step reads RUN_SOURCE alongside the block-derived SRC" \
  bash -c "grep -qF 'RUN_SOURCE=\$(sed -n' '$SKILL_DIR/phases/8-finalize.md'"
expect "and refuses when the two disagree" \
  bash -c "grep -qF '[ \"\$SRC\" != \"\$RUN_SOURCE\" ]' '$SKILL_DIR/phases/8-finalize.md'"

# (f) The frontend module subtree is resolved from the SOURCE's config.yaml, by the
# script — the doc used to say "whoever resolved it passes the answer in", and nothing
# did, so an upstream module relocation failed at extraction.
expect "materialize-frontend.sh resolves the module path from the source's config.yaml at TARGET" \
  bash -c "grep -qF 'modules[strenv(MOD)].path' '$SKILL_DIR/scripts/materialize-frontend.sh'"
expect "and warns when the config and the manifest disagree" \
  bash -c "grep -F 'WARN:' '$SKILL_DIR/scripts/materialize-frontend.sh' | grep -qF 'at TARGET puts module'"
expect "reference/materialization.md names the resolver instead of deferring it" \
  bash -c "grep -qF 'resolved by this script' '$SKILL_DIR/reference/materialization.md'"
refute "and no longer says whoever resolved it passes the answer in" \
  grep -qiF 'whoever resolved it' "$SKILL_DIR/reference/materialization.md"
expect "phases/2.5-materialize.md passes the module KEY through to the frontend builder" \
  bash -c "grep -qF 'MODULE=\"\$FRONTEND_TEMPLATE\"' '$SKILL_DIR/phases/2.5-materialize.md'"
fi

if t "recurrence lint: the frontend run's mirror, module path, branch continuity and guards stay wired"; then
# Eight contracts an adversarial review found broken, each pinned where it can silently
# reopen. They share one theme: the frontend run is a SECOND source with its own repo,
# and every place that forgot to say so fell back on the template's answer.
PFS=$SKILL_DIR/scripts/pre-flight.sh
MFS=$SKILL_DIR/scripts/materialize-frontend.sh
BWS=$SKILL_DIR/scripts/bellwether-detect.sh
BMS=$SKILL_DIR/scripts/build-manifest.sh
IPS_=$SKILL_DIR/scripts/in-progress.sh
TPS=$SKILL_DIR/scripts/template-parity.sh
SBS=$SKILL_DIR/scripts/suggest-branch.sh

# (a) The mirror exists as a pre-flight check, is recorded, and the sweep spares it.
# Without the sparing, every reuse/refresh arm — here and in materialize-frontend.sh —
# is dead code and each frontend run re-clones the monorepo.
expect "pre-flight.sh establishes the frontend mirror on a frontend run" \
  bash -c "grep -qF 'FRONTEND_CACHE=\$RUN/frontend' '$PFS'"
expect "and reuses a same-origin one rather than re-cloning" \
  bash -c "grep -qF 'refreshed existing frontend mirror' '$PFS'"
expect "and records it on the anchor" \
  bash -c "grep -qF 'FRONTEND_CACHE=\$FRONTEND_CACHE' '$PFS'"
expect "the fresh-mode sweep spares frontend/ in BOTH of its passes (rm and survivor check)" \
  bash -c "test \"\$(grep -c '! -name template ! -name common ! -name frontend' '$PFS')\" -ge 2"
expect "FRONTEND_CACHE is one of SKILL.md's canonical anchor keys" \
  bash -c "printf '%s' '$ANCHOR_KEYS' | grep -qw FRONTEND_CACHE"
expect "reference/pre-flight.md documents it as check 8.6" \
  bash -c "grep -qF '8.6' '$SKILL_DIR/reference/pre-flight.md'"

# (b) The two phases that read a mirror on the frontend arm read the FRONTEND one.
# Each of them used to be handed $CACHE — the template mirror — where a frontend SHA
# resolves to nothing and the module's upgrade-files do not exist. The frontend-arm
# invocation block used to live in reference/bellwether-detection.md too; F15 moved
# it into phases/2 (its single home), leaving that doc rationale-only.
for fe_doc in phases/2-resolve-target.md phases/3-classify.md; do
  expect "$fe_doc reads FRONTEND_CACHE off the anchor" \
    bash -c "grep -qF \"s/^FRONTEND_CACHE=//p\" '$SKILL_DIR/$fe_doc'"
done
expect "phases/3-classify.md's frontend block feeds CACHE from FRONTEND_CACHE" \
  bash -c "grep -qF 'CACHE=\$FRONTEND_CACHE' '$SKILL_DIR/phases/3-classify.md'"
expect "phases/2-resolve-target.md's frontend block does the same" \
  bash -c "grep -qF 'CACHE=\$FRONTEND_CACHE' '$SKILL_DIR/phases/2-resolve-target.md'"
expect "phases/2.5-materialize.md passes the mirror through to the builder" \
  bash -c "grep -qF 'FRONTEND_CACHE=\"\$FRONTEND_CACHE\"' '$SKILL_DIR/phases/2.5-materialize.md'"

# (c) The module subtree is resolved PER SIDE and written BACK. A single TARGET-side
# resolution made an in-range relocation unmigratable; a manifest-only read at Phase 8
# made the parity basis a different subtree than the merge used.
expect "materialize-frontend.sh resolves a path per side" \
  bash -c "grep -qF 'resolve_side_path' '$MFS'"
expect "and materializes each side from its own path" \
  bash -c "grep -qF 'materialize_side \"\$BASE\" base \"\$BASE_MODULE_PATH\"' '$MFS'"
expect "and warns when the module moved inside the range" \
  bash -c "grep -F 'WARN:' '$MFS' | grep -qF 'MOVED inside this range'"
expect "and records the RESOLVED module path / mirror / mount on the anchor" \
  bash -c "grep -qF 'FRONTEND_MODULE_PATH=\$MODULE_PATH' '$MFS' \
        && grep -qF 'FRONTEND_CACHE=\$FE_CACHE' '$MFS' \
        && grep -qF 'FRONTEND_MOUNT=\$MOUNT/' '$MFS'"
expect "reference/materialization.md says the resolution is per side" \
  bash -c "grep -qF 'PER SIDE' '$SKILL_DIR/reference/materialization.md'"

# (d) bellwether-detect agrees with materialize about precedence, and a declared module
# with no bellwethers does not fall into the repo-root legacy list.
expect "bellwether-detect.sh lets the config's module path outrank the passed one" \
  bash -c "grep -qF 'MODULE_PATH=\$CFG_MODULE_PATH' '$BWS'"
expect "and warns on disagreement instead of preferring one silently" \
  bash -c "grep -qF 'WARN:' '$BWS' && grep -qF 'puts module' '$BWS'"
expect "a config-DECLARED module gates tier 2" \
  bash -c "grep -qF 'CFG_MODULE_DECLARED' '$BWS'"
expect "and the skip is stated with the fix" \
  bash -c "grep -qF 'is SKIPPED' '$BWS' && grep -qF 'Declare bellwethers' '$BWS'"
expect "reference/bellwether-detection.md documents the tier-2 skip" \
  bash -c "grep -qF 'Skipped when' '$SKILL_DIR/reference/bellwether-detection.md'"

# (e) The module key is validated before it scopes an upgrade-file walk: an undeclared
# key collects nothing and reports success, which reads as "no migration steps".
expect "build-manifest.sh validates MODULE against the source's config.yaml at TARGET" \
  bash -c "grep -qF 'modules | has(strenv(MOD))' '$BMS'"
expect "and refuses an undeclared one loudly" \
  bash -c "grep -qF 'is not declared in the source' '$BMS'"
expect "phases/3-classify.md says so where the module is passed" \
  bash -c "grep -qF 'validates \`MODULE\`' '$SKILL_DIR/phases/3-classify.md'"

# (f) Two guards: `set` for a non-template source needs the block to pre-exist, and
# continue mode fails closed on a source disagreement.
expect "in-progress.sh set requires the source block for a non-template SOURCE" \
  bash -c "grep -qF 'a \$SOURCE run cannot record an in-progress block' '$IPS_'"
expect "pre-flight.sh refuses a continue whose RUN_SOURCE contradicts the live block" \
  bash -c "grep -qF 'MODE=continue with RUN_SOURCE=' '$PFS'"
expect "reference/pre-flight.md documents that continue-mode refusal" \
  bash -c "grep -qF 'contradicting' '$SKILL_DIR/reference/pre-flight.md'"

# (g) Branch continuity across the chained re-entry, whose fresh sweep takes the anchor
# with it — so the checked-out branch is the second source of the same fact.
expect "suggest-branch.sh falls back to the migration-shaped branch it is standing on" \
  bash -c "grep -qF 'CURRENT_BRANCH=\$(git rev-parse --abbrev-ref HEAD' '$SBS'"
expect "matching the same two globs pre-flight accepts" \
  bash -c "grep -qF 'topic/*/template-update-*|topic/*/frontend-update-*' '$SBS'"
expect "phases/4-migration-branch.md explains the self-healing arm" \
  bash -c "grep -qiF 'self-healing' '$SKILL_DIR/phases/4-migration-branch.md'"
expect "SKILL.md's branch default states it too" \
  bash -c "grep -qF 'prints the branch you are already standing on' '$SKILL_DIR/SKILL.md'"

# (h) Parity's frontend basis lists symlinks and guards its helper source.
expect "template-parity.sh lists symlinks in the frontend basis" \
  bash -c "grep -qF 'find . \\( -type f -o -type l \\)' '$TPS'"
expect "and guards the replacement-map source instead of sourcing it blind" \
  bash -c "grep -qF '[ -r \"\$SCRIPT_DIR/lib/frontend-substitute.sh\" ]' '$TPS'"

# (i) The create-time substitution whitelist lives in THREE copies — the shipped
# scripts/lib/frontend-substitute.sh and the two test doubles that reproduce the CLI's
# behavior (tests/fake-kairos.sh, tests/lib.sh). They must carry IDENTICAL whitelist
# CONTENT, not merely the same explanatory comment: T7's drift (renovate.config.js in one
# basename list but not the others) slid past a comment-only grep. So extract the three
# load-bearing fragments from each copy and require they agree across all three — the
# extension alternation (what Path().suffix is tested against), the basename alternation
# (extension-less files kept verbatim), and the module-rewrite sed literal. The variable
# names differ per copy (_fsub_base vs base), so we compare the alternation payloads, not
# whole lines.
FSUB_COPIES="scripts/lib/frontend-substitute.sh tests/fake-kairos.sh tests/lib.sh"
# The extension list is the pipe-run beginning `.json|`; the basename list the pipe-run
# beginning `Makefile|`; each runs up to the closing `)` of its case pattern.
fsub_ext_list()  { grep -oE '\.json\|[^)]+' "$1" | head -1; }
fsub_base_list() { grep -oE 'Makefile\|[^)]+' "$1" | head -1; }
FSUB_EXT_REF=""; FSUB_BASE_REF=""; FSUB_DRIFT=""; FSUB_N=0
for fsub_copy in $FSUB_COPIES; do
  FSUB_N=$((FSUB_N + 1))
  fsub_cp="$SKILL_DIR/$fsub_copy"
  # The WHY still stated (Path().suffix semantics), and both payloads present.
  grep -qF 'Path().suffix' "$fsub_cp" || FSUB_DRIFT="$FSUB_DRIFT $fsub_copy(no-Path().suffix)"
  fsub_e=$(fsub_ext_list "$fsub_cp"); fsub_b=$(fsub_base_list "$fsub_cp")
  [[ -n "$fsub_e" ]] || FSUB_DRIFT="$FSUB_DRIFT $fsub_copy(no-ext-list)"
  [[ -n "$fsub_b" ]] || FSUB_DRIFT="$FSUB_DRIFT $fsub_copy(no-base-list)"
  # renovate.config.js must be IN the basename list (T7's exact drift), and the module
  # rewrite must name the template module path.
  case "$fsub_b" in *renovate.config.js*) : ;; *) FSUB_DRIFT="$FSUB_DRIFT $fsub_copy(base-missing-renovate.config.js)" ;; esac
  grep -qF 'bitbucket.org/ifs-pd/kairos-component-template' "$fsub_cp" \
    || FSUB_DRIFT="$FSUB_DRIFT $fsub_copy(no-module-rewrite)"
  if [[ -z "$FSUB_EXT_REF" ]] && [[ "$FSUB_N" -eq 1 ]]; then
    FSUB_EXT_REF=$fsub_e; FSUB_BASE_REF=$fsub_b
  else
    [[ "$fsub_e" = "$FSUB_EXT_REF" ]] || FSUB_DRIFT="$FSUB_DRIFT $fsub_copy(ext-list-drift)"
    [[ "$fsub_b" = "$FSUB_BASE_REF" ]] || FSUB_DRIFT="$FSUB_DRIFT $fsub_copy(base-list-drift)"
  fi
done
if [[ "$FSUB_N" -eq 3 ]] && [[ -z "$FSUB_DRIFT" ]]; then
  pass "all three create-time whitelist copies carry identical extension + basename content (incl. renovate.config.js) and the module-rewrite rule"
else
  fail "create-time whitelist copies drifted:$FSUB_DRIFT (n=$FSUB_N)"
fi
fi

if t "recurrence lint: the frontend run's common idle, gate cwd, executor cwd and abort isolation stay wired"; then
# Four contracts a post-implementation review found broken or unpinned. Their shared
# theme: a phase that says nothing about the frontend arm is only correct when it is
# GENUINELY source-agnostic — each pin below marks a place that turned out not to be.

# (a) The common side idles on a frontend run — at the CALL, in the SCRIPT, and in
# Phase 3.5's premise. Without all three, a frontend run records
# COMMON_MODULES=present, Phase 3.5 collects nothing, and plan-completeness.sh
# deadlocks Phase 6 with a remedy ("re-run Phase 3.5") the frontend arm forbids.
expect "phases/1-preflight.md guards the clone-common call as template-only" \
  bash -c "grep -qF 'on a frontend run (\`RUN_SOURCE=frontend\`) skip this whole step' '$SKILL_DIR/phases/1-preflight.md'"
expect "clone-common.sh enforces the same arm itself (reads RUN_SOURCE off the anchor)" \
  bash -c "grep -qF 'RUN_SOURCE=frontend' '$SKILL_DIR/scripts/clone-common.sh' \
        && grep -q 'not applicable' '$SKILL_DIR/scripts/clone-common.sh'"
expect "phases/3.5-collect-common.md's absence premise names Phase 1's skip" \
  bash -c "grep -qF 'Phase 1 skips' '$SKILL_DIR/phases/3.5-collect-common.md'"

# (b) EVERY gate a frontend run reaches runs with cwd at the mount — gate.sh has no
# frontend flag (the cwd IS the parameter), so each calling phase must carry the
# mount arm itself. The two omissions this pin closes ran the mount's recorded
# commands at the component root, against a baseline captured at the mount.
for gate_doc in phases/4.5-test-baseline.md phases/5-structural.md phases/7-execution.md phases/8-finalize.md; do
  expect "$gate_doc hard-stops on a lost mount and cds into it" \
    bash -c "grep -qF 'FRONTEND_MOUNT missing from the run-context anchor' '$SKILL_DIR/$gate_doc' \
          && grep -qF 'cd \"\$MOUNT\"' '$SKILL_DIR/$gate_doc'"
done
refute "gate.sh itself stays mount-free — the cwd is the parameter, by design" \
  grep -qi 'FRONTEND\|MOUNT' "$SKILL_DIR/scripts/gate.sh"
# The missing-\$SYNTH remedy names the DISPATCH, not materialize.sh: the template
# arm on a frontend resume rebuilds \$SYNTH from the component template — the
# wrong trees entirely (reference/continue.md says why).
for mat_doc in phases/5-structural.md phases/7-execution.md phases/8-finalize.md; do
  expect "$mat_doc's missing-\$SYNTH remedy dispatches by RUN_SOURCE" \
    bash -c "grep -qF 'dispatches by \`RUN_SOURCE\`' '$SKILL_DIR/$mat_doc'"
done

# (c) The executor's cwd travels through PLAN.md, not conversation: the planner
# writes it into ## Test Baseline, the executor reads it there and runs every
# command and verify-script from it. Without this, reference/upgrade-files.md's
# "the executor cds to the mount first" is a contract nothing implements.
expect "agents/planner.md's Test Baseline template carries the Cwd line" \
  bash -c "grep -qF -- '- Cwd:' '$SKILL_DIR/agents/planner.md'"
expect "agents/executor.md reads the Cwd from the Test Baseline" \
  bash -c "grep -qF 'Test Baseline → Cwd' '$SKILL_DIR/agents/executor.md'"
expect "agents/executor.md runs verify-scripts at that cwd (subtree-relative contract)" \
  bash -c "grep -qF 'subtree-relative' '$SKILL_DIR/agents/executor.md'"

# (d) Phase 8's frontend final gate stays two ORDERED layers with the root layer
# BUILD-only, and abort stays per-source. Both live as prose (no script to test),
# so the load-bearing sentences are pinned here.
expect "phases/8-finalize.md keeps the frontend final gate two layers, in order" \
  bash -c "grep -qF 'two layers, in this order' '$SKILL_DIR/phases/8-finalize.md'"
expect "and the Go test suite never gates the frontend baseline" \
  bash -c "grep -qF 'must never gate the frontend baseline' '$SKILL_DIR/phases/8-finalize.md'"
expect "reference/abort.md resolves its source from the live block" \
  bash -c "grep -qF 'has(\"in_progress\")' '$SKILL_DIR/reference/abort.md'"
expect "and states both directions of the baseline isolation invariant" \
  bash -c "grep -qF 'keeps the advanced \`template.sha\`' '$SKILL_DIR/reference/abort.md' \
        && grep -qF 'aborting a template run never touches \`frontend.sha\`' '$SKILL_DIR/reference/abort.md'"
fi

if t "SKILL.md frontmatter description stays within the 1024-char trigger budget"; then
# A 1059-char description shipped once because nothing measured it. The trigger match
# reads a bounded description; an over-budget one silently loses its tail — and the
# continue/resume/abort words a fresh-session match depends on live near the end.
DESC=$(sed -n 's/^description: //p' "$SKILL_DIR/SKILL.md")
DESC_LEN=$(printf '%s' "$DESC" | wc -c | tr -d ' ')
# Non-vacuity first: the extraction must find a description at all.
if [[ "${DESC_LEN:-0}" -gt 0 ]]; then
  pass "SKILL.md description extracts (non-empty: $DESC_LEN chars)"
else
  fail "SKILL.md description extracts (got 0 — the 'description:' line moved or wrapped)"
fi
if [[ "${DESC_LEN:-0}" -le 1024 ]]; then
  pass "SKILL.md description is within 1024 chars ($DESC_LEN)"
else
  fail "SKILL.md description is $DESC_LEN chars — over the 1024 trigger budget; trim it"
fi
# Mutation: the same measurement must reject a 1059-char description (the gap that shipped).
MUT_DESC=$(head -c 1059 < /dev/zero | tr '\0' x)
if [[ "$(printf '%s' "$MUT_DESC" | wc -c | tr -d ' ')" -gt 1024 ]]; then
  pass "the budget check rejects a 1059-char description (mutation proof)"
else
  fail "the budget check rejects a 1059-char description (mutation proof)"
fi
fi

if t "the Phase-1 frontend re-entry env is RUN_SOURCE=frontend, never a bare SOURCE=frontend"; then
# The re-entry passes RUN_SOURCE=frontend to pre-flight; a doc that abbreviated it to
# SOURCE=frontend would name a variable pre-flight never reads, so the frontend run
# would skip nothing and refuse the branch it is standing on (reference/pre-flight.md
# checks 0b and 3). SKILL.md's chained-runs paragraph and phases/8-finalize.md agree.
expect "SKILL.md's chained-runs paragraph names RUN_SOURCE=frontend" \
  grep -qF 'over the same phases with `RUN_SOURCE=frontend`' "$SKILL_DIR/SKILL.md"
expect "phases/8-finalize.md's fresh re-entry names RUN_SOURCE=frontend on the Phase 1 call" \
  grep -qF 'RUN_SOURCE=frontend` on Phase 1' "$SKILL_DIR/phases/8-finalize.md"
# A bare SOURCE=frontend — one not the tail of RUN_SOURCE=frontend — is the wrong var.
wrong_source() { grep -qE '(^|[^_A-Za-z])SOURCE=frontend' "$1"; }
refute "SKILL.md tells no operator to pass a bare SOURCE=frontend" wrong_source "$SKILL_DIR/SKILL.md"
refute "phases/8-finalize.md tells no operator to pass a bare SOURCE=frontend" \
  wrong_source "$SKILL_DIR/phases/8-finalize.md"
# Mutation: a bare SOURCE=frontend must trip the guard, and the correct form must not.
printf 'pass %s on the re-entry\n' 'SOURCE=frontend' > "$SANDBOX/rs-wrong.md"
printf 'pass %s on the re-entry\n' 'RUN_SOURCE=frontend' > "$SANDBOX/rs-ok.md"
if wrong_source "$SANDBOX/rs-wrong.md"; then
  pass "the wrong-var guard catches a bare SOURCE=frontend (mutation proof)"
else
  fail "the wrong-var guard catches a bare SOURCE=frontend (mutation proof)"
fi
refute "the guard does not fire on the correct RUN_SOURCE=frontend form" \
  wrong_source "$SANDBOX/rs-ok.md"
fi

if t "cross-repo mirror: the consumer contract mirrors the author schema (both change together)"; then
# reference/upgrade-files.md's template-kind-module section is the CONSUMER contract;
# core-skills/kairos-document-updates/reference/upgrade-file-schema.md (same repo) is the
# AUTHOR side it mirrors. Pin the shared invariant literals so a reword on either side
# alone goes red. The prose framing ("template framing applies verbatim", the executable-
# verification difference) is too fuzzy to pin line-for-line — the exact shared fragments
# below are the strongest honest pin.
UF="$SKILL_DIR/reference/upgrade-files.md"
SCHEMA="$SKILL_DIR/../../core-skills/kairos-document-updates/reference/upgrade-file-schema.md"
expect "upgrade-files.md names the author schema as the mirror source" \
  grep -qF 'core-skills/kairos-document-updates/reference/upgrade-file-schema.md' "$UF"
expect "upgrade-files.md states it wins on divergence" \
  grep -qF 'this doc wins if the two ever diverge' "$UF"
# The author schema is a sibling-repo checkout (core-skills/kairos-document-updates). When
# it is absent — a partial checkout — fail LOUDLY and skip the cross-repo comparison,
# rather than letting every `grep … "$SCHEMA"` below spray raw "No such file" to stderr.
if [[ ! -f "$SCHEMA" ]]; then
  fail "the author schema is absent at $SCHEMA — the sibling core-skills/kairos-document-updates checkout is required for the cross-repo mirror lint; cannot verify the mirror without it"
else
expect "the author schema exists at its cross-repo path" test -f "$SCHEMA"
MIRROR_FRAGS='.kairos-updates/<module>/<timestamp>-<slug>.md
component-template repo in miniature
module subtree
web/…
template/react/…
package.json'
MF_N=0; MF_BOTH=0; MF_MISS=""
while IFS= read -r frag; do
  [[ -n "$frag" ]] || continue
  MF_N=$((MF_N + 1))
  if grep -qF "$frag" "$UF" && grep -qF "$frag" "$SCHEMA"; then
    MF_BOTH=$((MF_BOTH + 1))
  else
    MF_MISS="$MF_MISS [$frag]"
  fi
done <<MIRRORFRAGS
$MIRROR_FRAGS
MIRRORFRAGS
if [[ "$MF_N" -ge 6 ]] && [[ "$MF_BOTH" -eq "$MF_N" ]]; then
  pass "all $MF_N shared invariant fragments appear on both sides of the mirror"
else
  fail "shared mirror fragment(s) on only one side (or extraction broke): missing=$MF_MISS n=$MF_N both=$MF_BOTH"
fi
# Mutation: a fragment dropped from ONE side alone must be detected.
grep -vF 'package.json' "$SCHEMA" > "$SANDBOX/mirror-mut.md"
if grep -qF 'package.json' "$UF" && ! grep -qF 'package.json' "$SANDBOX/mirror-mut.md"; then
  pass "a fragment dropped from one side alone is detected (mutation proof)"
else
  fail "a fragment dropped from one side alone is detected (mutation proof)"
fi
fi
fi

if t "optional-application (ask:) contract is pinned on both the field doc and the planner"; then
# The `ask:` field makes an upgrade-file's application the user's choice: the
# planner surfaces it and dispositions apply/skip by the answer, gated on the
# `before:` applicability grep. This is behavioural prose in two files that must
# stay in step — pin the load-bearing fragments so a reword on either alone goes red.
UF="$SKILL_DIR/reference/upgrade-files.md"
PL="$SKILL_DIR/agents/planner.md"
SCHEMA="$SKILL_DIR/../../core-skills/kairos-document-updates/reference/upgrade-file-schema.md"
# The canonical one-liner is shared verbatim with the AUTHOR schema (change both
# together), same discipline as the cross-repo mirror block above.
CANON="makes application optional: the user decides whether to apply"
expect "upgrade-files.md carries the canonical optional-application sentence" \
  grep -qF "$CANON" "$UF"
expect "upgrade-files.md documents the ask: field as the user's choice" \
  grep -qiE "ask:.*optional|Optional application" "$UF"
expect "upgrade-files.md gates the ask on the before: applicability grep" \
  grep -qF 'the same grep the executor already runs' "$UF"
expect "planner.md makes the ask: ask mandatory (not the infer-economy)" \
  grep -qF "carrying an \`ask:\` field" "$PL"
expect "planner.md skips a ask: upgrade whose before: does not match, without asking" \
  grep -qF 'not applicable — before: did not match' "$PL"
# Change-both-together: the AUTHOR schema must carry the same canonical sentence.
if [[ ! -f "$SCHEMA" ]]; then
  fail "the author schema is absent at $SCHEMA — cannot verify the ask: field is mirrored author-side"
else
  expect "the author schema mirrors the canonical optional-application sentence" \
    grep -qF "$CANON" "$SCHEMA"
fi
# Mutation: dropping the canonical sentence from the field doc is detected.
grep -vF "$CANON" "$UF" > "$SANDBOX/prompt-mut.md"
if grep -qF "$CANON" "$UF" && ! grep -qF "$CANON" "$SANDBOX/prompt-mut.md"; then
  pass "a dropped canonical optional-application sentence is detected (mutation proof)"
else
  fail "a dropped canonical optional-application sentence is detected (mutation proof)"
fi
fi

if t "frontend-floor (requires-frontend:) contract is pinned byte-identical on both the consumer contract and the author schema"; then
# `requires-frontend:` on a template upgrade-file declares a frontend compatibility
# floor: frontend.sha must CONTAIN the floor commit (an ancestry test, not a numeric
# >=). The one-line semantics is stated verbatim in TWO files that must move together —
# the CONSUMER contract (reference/upgrade-files.md) and the AUTHOR schema
# (core-skills/kairos-document-updates/reference/upgrade-file-schema.md) — so a reword on
# either side alone goes red. Same cross-repo change-both-together discipline as the ask:
# block above and the mirror block; the ancestry-vs-version distinction is the load-bearing
# byte, so it is what gets pinned.
UF="$SKILL_DIR/reference/upgrade-files.md"
SCHEMA="$SKILL_DIR/../../core-skills/kairos-document-updates/reference/upgrade-file-schema.md"
FLOOR_CANON="A frontend floor is satisfied when the component's frontend.sha contains the floor commit — an ancestry test, not a version comparison."
expect "upgrade-files.md carries the canonical frontend-floor sentence" \
  grep -qF "$FLOOR_CANON" "$UF"
if [[ ! -f "$SCHEMA" ]]; then
  fail "the author schema is absent at $SCHEMA — cannot verify the requires-frontend: floor sentence is mirrored author-side"
else
  expect "the author schema mirrors the canonical frontend-floor sentence" \
    grep -qF "$FLOOR_CANON" "$SCHEMA"
fi
# Mutation: dropping the canonical sentence from EITHER side alone must be detected.
grep -vF "$FLOOR_CANON" "$UF" > "$SANDBOX/floor-mut-consumer.md"
if grep -qF "$FLOOR_CANON" "$UF" && ! grep -qF "$FLOOR_CANON" "$SANDBOX/floor-mut-consumer.md"; then
  pass "a dropped frontend-floor sentence on the consumer side is detected (mutation proof)"
else
  fail "a dropped frontend-floor sentence on the consumer side is detected (mutation proof)"
fi
if [[ -f "$SCHEMA" ]]; then
  grep -vF "$FLOOR_CANON" "$SCHEMA" > "$SANDBOX/floor-mut-author.md"
  if grep -qF "$FLOOR_CANON" "$SCHEMA" && ! grep -qF "$FLOOR_CANON" "$SANDBOX/floor-mut-author.md"; then
    pass "a dropped frontend-floor sentence on the author side is detected (mutation proof)"
  else
    fail "a dropped frontend-floor sentence on the author side is detected (mutation proof)"
  fi
fi
fi

if t "supersede (supersedes:) contract is pinned across the consumer docs and the author schema"; then
# `supersedes:` retires earlier shipped guidance mechanically. The behavior-defining
# prose is spread across the schema contract (reference/upgrade-files.md, wins on
# divergence), its author mirror, the planner (deferral + ask-disclosure + batch skips
# + legacy watch), the Phase 6 gate wiring, and the Phase 8 undeclared-supersede flip.
# Pinned so a reword cannot silently drop the load-bearing halves.
UF="$SKILL_DIR/reference/upgrade-files.md"
SCHEMA="$SKILL_DIR/../../core-skills/kairos-document-updates/reference/upgrade-file-schema.md"
PL="$SKILL_DIR/agents/planner.md"
P6="$SKILL_DIR/phases/6-planning.md"
P8="$SKILL_DIR/phases/8-finalize.md"

# --- schema contract + author mirror (change both together) --------------------
expect "upgrade-files.md carries the Superseding prior guidance section" \
  grep -qF '## Superseding prior guidance' "$UF"
expect "upgrade-files.md documents the tombstone disposition" \
  grep -qF 'apply (tombstone)' "$UF"
expect "upgrade-files.md states the same-source/same-module scope" \
  grep -qiF 'same source, same module only' "$UF"
if [[ ! -f "$SCHEMA" ]]; then
  fail "the author schema is absent at $SCHEMA — cannot verify supersedes: is mirrored author-side"
else
  expect "the author schema mirrors the Superseding prior guidance section" \
    grep -qF 'Superseding prior guidance' "$SCHEMA"
  expect "the author schema documents the tombstone shape" \
    grep -qiF 'tombstone' "$SCHEMA"
fi

# --- planner: deferral, ask-disclosure, batch skips, legacy watch --------------
DISCLOSE='also retires the earlier rule'
expect "planner.md defers superseded slugs as invisible bookkeeping" \
  grep -qF 'invisible bookkeeping' "$PL"
expect "planner.md ask-disclosure states what applying RETIRES" \
  grep -qF "$DISCLOSE" "$PL"
expect "planner.md ask-disclosure states what declining PRESERVES" \
  grep -qF 'the earlier rule stays in force' "$PL"
expect "planner.md surfaces supersede skips as Dispositions-table rows (carve-out from per-skip sign-off)" \
  grep -qF 'surfaced as its own row in the `## Upgrade-file Dispositions` table' "$PL"
# The deferral placeholder shape is what supersede-check.sh matches literally (a
# `^deferred` disposition cell); pin both halves so a reword cannot drop the
# format the gate reads.
DEFER_CELL='its disposition cell is the literal lowercase word `deferred`'
DEFER_WAIT='`waits on <superseder-stem>`'
expect "planner.md pins the deferred disposition cell" \
  grep -qF "$DEFER_CELL" "$PL"
expect "planner.md pins the 'waits on <superseder-stem>' reason grammar" \
  grep -qF "$DEFER_WAIT" "$PL"
grep -vF "$DEFER_CELL" "$PL" > "$SANDBOX/supersede-defer-mut.md"
if grep -qF "$DEFER_CELL" "$PL" && ! grep -qF "$DEFER_CELL" "$SANDBOX/supersede-defer-mut.md"; then
  pass "a dropped deferred-cell pin is detected (mutation proof)"
else
  fail "a dropped deferred-cell pin is detected (mutation proof)"
fi
expect "planner.md keeps a legacy undeclared-contradiction watch" \
  grep -qF 'superseded — undeclared' "$PL"
# Mutation: dropping the ask-disclosure retires-half must be detected — without it a
# bare yes/no on the new file silently decides the old file's fate.
grep -vF "$DISCLOSE" "$PL" > "$SANDBOX/supersede-disclose-mut.md"
if grep -qF "$DISCLOSE" "$PL" && ! grep -qF "$DISCLOSE" "$SANDBOX/supersede-disclose-mut.md"; then
  pass "a dropped ask-disclosure retires-half is detected (mutation proof)"
else
  fail "a dropped ask-disclosure retires-half is detected (mutation proof)"
fi

# --- Phase 6 gate wiring + Phase 8 undeclared-supersede flip -------------------
expect "6-planning.md invokes the supersede gate" \
  grep -qF 'scripts/supersede-check.sh' "$P6"
expect "8-finalize.md carries the surface-and-confirm flip disposition" \
  grep -qF 'superseded — confirmed at final gate' "$P8"
expect "8-finalize.md forbids auto-flipping the undeclared-supersede gate" \
  grep -qiF 'never auto-flip' "$P8"
expect "8-finalize.md exempts a tombstone from re-verification" \
  bash -c "grep -F 'apply (tombstone)' '$P8' | grep -qiF exempt"
# `skip (tombstone)` is not a defined disposition (the only tombstone disposition
# is `apply (tombstone)`, which is what fires the edge). It must appear nowhere in
# the skill prose, or the gate would silently mishandle it.
refute "8-finalize.md never invents a skip (tombstone) disposition" \
  grep -qF 'skip (tombstone)' "$P8"
expect "planner.md records the tombstone disposition (no Phase 7 task)" \
  grep -qF 'apply (tombstone)' "$PL"
fi

if t "frontend-floor cross-run debt is wired end-to-end: a reader exists AND Phase 8 consumes it"; then
# The debt record-floor writes into frontend.outstanding_floors is only useful if a LATER
# run reads it back. in-progress.sh must expose the list-floors reader, and Phase 8 must
# union its output into the floor check's input — otherwise the debt is write-only and a
# declined floor is silently forgotten once BASE advances past its upgrade-file. And the
# step-5 advance must pass FRONTEND_CACHE, or the auto-clear that retires a satisfied floor
# never fires. All three moved together when this feature was completed; pin them together.
IPS="$SKILL_DIR/scripts/in-progress.sh"
FIN="$SKILL_DIR/phases/8-finalize.md"
expect "in-progress.sh implements the list-floors reader action" \
  grep -qE '^[[:space:]]*list-floors\)' "$IPS"
expect "list-floors prints the three frontend-floors.tsv columns (@tsv over outstanding_floors)" \
  bash -c "grep -F 'outstanding_floors' '$IPS' | grep -qF '@tsv'"
expect "Phase 8 invokes the list-floors reader" \
  grep -qF 'ACTION=list-floors' "$FIN"
expect "Phase 8 unions the persisted debt into the floor check's FLOORS_TSV (not the bare range table)" \
  grep -qF 'FLOORS_TSV="$FLOORS_UNION"' "$FIN"
expect "Phase 8's step-5 advance passes FRONTEND_CACHE so the floor auto-clear can fire" \
  grep -qF 'FRONTEND_CACHE="$FRONTEND_CACHE" "$SKILL_DIR/scripts/in-progress.sh"' "$FIN"
fi

if t "writer commit-subjects and continue.md's recovery greps stay in correspondence"; then
# The migration commits carry FIXED subject prefixes; reference/continue.md locates a
# crashed run's phase by grepping those subjects and counting migrate() commits. Until now
# only continue.md's side was pinned — a writer reword silently broke resume. Pin BOTH:
# extract the writer-emitted subjects and require (A) every continue.md needle is a prefix
# of a writer subject — a writer reword orphans it, a continue drift to a phantom subject
# fails it — and (B) every resume-relevant subject keeps a needle in continue.md, so a
# dropped recovery grep is caught even though (A) stays green when a needle just vanishes.
WSUBJ=$SANDBOX/writer-subjects.txt
grep -rhoE 'git commit -m "[^"$<]*' "$SKILL_DIR"/phases/*.md \
  | sed -E 's/^git commit -m "//; s/[[:space:]]+$//' | sort -u > "$WSUBJ"
W_N=$(grep -c . "$WSUBJ" || true)
# Non-vacuity: the six writer subjects (scaffolding, structural, plan, migrate, advance,
# squash) must extract — a broken extraction would pass every check below vacuously.
if [[ "${W_N:-0}" -ge 6 ]]; then
  pass "writer commit-subjects extract from phases/ ($W_N distinct prefixes)"
else
  fail "writer commit-subjects extract from phases/ (got ${W_N:-0} — the git commit -m lines moved)"
fi
is_prefix_of_writer() { # <needle> — true if needle prefixes some extracted writer subject
  local needle=$1 s
  while IFS= read -r s; do
    case "$s" in "$needle"*) return 0 ;; esac
  done < "$WSUBJ"
  return 1
}
# Enumeration: every expected writer subject — INCLUDING Phase 8 advance and squash — is
# emitted. This is the writer-side pin that was missing; a Phase-8 reword now goes red too.
WEXPECT='chore: begin migration
chore: structural merge
chore: migration plan
migrate(
chore: advance
chore: migrate to'
WE_MISS=""
while IFS= read -r e; do
  [[ -n "$e" ]] || continue
  is_prefix_of_writer "$e" || WE_MISS="$WE_MISS [$e]"
done <<WEXP
$WEXPECT
WEXP
if [[ -z "$WE_MISS" ]]; then
  pass "every expected writer subject (scaffolding, structural, plan, migrate, advance, squash) is emitted"
else
  fail "writer no longer emits expected subject(s):$WE_MISS"
fi
# continue.md's recovery needles — the chore:/migrate( subjects it greps and counts on.
CNEED=$SANDBOX/continue-needles.txt
grep -oE 'chore: [a-z]+( [a-z]+)*|migrate\(' "$SKILL_DIR/reference/continue.md" | sort -u > "$CNEED"
CN_N=$(grep -c . "$CNEED" || true)
if [[ "${CN_N:-0}" -gt 0 ]]; then
  pass "continue.md recovery needles extract ($CN_N)"
else
  fail "continue.md recovery needles extract (got 0 — the recovery greps moved)"
fi
# Direction A (continue -> writer): every continue needle is a prefix of a writer subject.
CN_ORPHAN=""
while IFS= read -r nd; do
  [[ -n "$nd" ]] || continue
  is_prefix_of_writer "$nd" || CN_ORPHAN="$CN_ORPHAN [$nd]"
done < "$CNEED"
if [[ -z "$CN_ORPHAN" ]]; then
  pass "every continue.md recovery needle is a prefix of a writer-emitted subject"
else
  fail "continue.md needle(s) match no writer subject (writer reworded, or continue drifted):$CN_ORPHAN"
fi
# Direction B (writer -> continue): each resume-relevant subject keeps a needle in
# continue.md, so a dropped recovery grep is caught.
CRESUME='chore: begin migration
chore: structural merge
chore: migration plan
migrate('
CR_MISS=""
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  grep -qF "$r" "$SKILL_DIR/reference/continue.md" || CR_MISS="$CR_MISS [$r]"
done <<CRES
$CRESUME
CRES
if [[ -z "$CR_MISS" ]]; then
  pass "continue.md keeps a recovery needle for every resume-relevant subject"
else
  fail "continue.md dropped the recovery grep for:$CR_MISS"
fi
fi

if t "bare anchor reads are sanctioned — optional-list, FRONTEND_*, or a locally-justified comment"; then
# The anchor lint's UNREAD check accepts a bare `sed -n 's/^KEY=//p' "$RUN/context.env"`
# as a satisfying read for ANY key, so SKILL.md's always-optional list constrained
# nothing: a block could bare-read BASE/TARGET/SYNTH — swallowing a missing key as empty
# — and pass. This scan makes the list load-bearing. A bare ANCHOR read (the sed reads
# context.env — distinct from parsing a script's stdout) is sanctioned iff the key is in
# SKILL.md's always-optional list, is FRONTEND_* (absence is the record of something), or
# the read carries a local justification: a comment on the read's own line or the line
# above (SKILL.md's "the block says so in a comment where it does"), or a block-scoped
# comment announcing the bare-read convention (abort/continue's "Bare reads throughout"
# form). Feasibility: the justification is free prose — phases/3's is an arm-guard note
# with no "bare" in it — so adjacency is the primary signal and a "bare"-mentioning block
# comment the fallback. The detector is deliberately permissive (it can MISS an
# unsanctioned read that happens to sit beside an unrelated comment) but never
# false-fails, and it is proven on fixtures before it is trusted over the real docs.
OPT_KEYS=" $(grep -F 'always* optional' "$SKILL_DIR/SKILL.md" | sed 's/Those are the keys.*//' \
  | grep -oE '`[A-Z][A-Z0-9_]*[A-Z0-9]`' | tr -d '`' | sort -u | tr '\n' ' ')"
OPT_N=$(printf '%s' "$OPT_KEYS" | wc -w | tr -d ' ')
# Non-vacuity: the always-optional list must extract, or every read passes vacuously.
if [[ "${OPT_N:-0}" -ge 7 ]]; then
  pass "SKILL.md's always-optional key list extracts ($OPT_N keys)"
else
  fail "SKILL.md's always-optional key list extracts (got ${OPT_N:-0} — the 'always* optional' sentence moved or lost its backticked keys)"
fi
expect "TARGET_REF is one of the always-optional keys" \
  bash -c "printf '%s' '$OPT_KEYS' | grep -qw TARGET_REF"
bare_read_scan() { # <space-padded-optkeys> <file...> -> "FILE:LINE KEY" per UNSANCTIONED bare anchor read
  local opt=$1; shift
  awk -v opt="$opt" '
    function is_opt(k){ return index(opt, " " k " ") > 0 }
    function flush(   i,key,justified,p,hasbarecmt) {
      hasbarecmt=0
      for (i=1;i<=nb;i++) if (L[i] ~ /#/ && tolower(L[i]) ~ /bare/) hasbarecmt=1
      for (i=1;i<=nb;i++) {
        if (L[i] ~ /s\/\^[A-Z][A-Z0-9_]*=\/\/p/ && index(L[i],"context.env")>0) {
          key=L[i]; sub(/.*s\/\^/,"",key); sub(/=\/\/p.*/,"",key)
          if (key ~ /^FRONTEND_/) continue
          if (is_opt(key)) continue
          justified = (index(L[i],"#")>0) || hasbarecmt
          if (!justified) { for (p=i-1;p>=1;p--){ if (L[p] ~ /^[[:space:]]*$/) continue; if (L[p] ~ /^[[:space:]]*#/) justified=1; break } }
          if (!justified) print FILENAME ":" LN[i] " " key
        }
      }
    }
    /^[[:space:]]*```/ { if (inb){ flush(); inb=0 } else { inb=1; nb=0 } next }
    inb { nb++; L[nb]=$0; LN[nb]=FNR }
  ' "$@"
}
# Fixtures prove the detector before it is trusted over the real docs. Quoted heredocs
# keep the sed/$-forms literal.
BR=$SANDBOX/bare-read && mkdir -p "$BR"
cat > "$BR/unsanctioned.md" <<'BRFIX'
```bash
BASE=$(sed -n 's/^BASE=//p' "$RUN/context.env")
```
BRFIX
cat > "$BR/adjacent.md" <<'BRFIX'
```bash
# absence routes through the Decide arms, not to a failure
PREV_SHA=$(sed -n 's/^PREV_SHA=//p' "$RUN/context.env")
```
BRFIX
cat > "$BR/optional.md" <<'BRFIX'
```bash
TARGET_REF=$(sed -n 's/^TARGET_REF=//p' "$RUN/context.env")
```
BRFIX
cat > "$BR/frontend.md" <<'BRFIX'
```bash
FRONTEND_MOUNT=$(sed -n 's/^FRONTEND_MOUNT=//p' "$RUN/context.env")
```
BRFIX
cat > "$BR/blockcomment.md" <<'BRFIX'
```bash
# Bare reads throughout: this arm exists BECAUSE the state is partial
PREV_BRANCH=$(sed -n 's/^PREV_BRANCH=//p' "$RUN/context.env")
PREV_SHA=$(sed -n 's/^PREV_SHA=//p' "$RUN/context.env")
```
BRFIX
cat > "$BR/stdout-parse.md" <<'BRFIX'
```bash
CACHE=$(printf '%s\n' "$PF" | sed -n 's/^CACHE=//p')
```
BRFIX
# Called in-shell, never via `bash -c` — bare_read_scan is a shell function a
# subshell would not inherit (a missing function would make every refute pass
# vacuously and the expect fail).
if bare_read_scan "$OPT_KEYS" "$BR/unsanctioned.md" | grep -q ' BASE$'; then
  pass "an unsanctioned bare anchor read (no comment) is flagged (mutation proof)"
else
  fail "an unsanctioned bare anchor read (no comment) is flagged (mutation proof)"
fi
for fx in adjacent:adjacent-comment optional:always-optional-key \
          frontend:FRONTEND_* blockcomment:block-scoped-bare-comment \
          stdout-parse:script-stdout-not-a-bare-anchor-read; do
  f=${fx%%:*}; label=${fx##*:}
  if bare_read_scan "$OPT_KEYS" "$BR/$f.md" | grep -q .; then
    fail "sanctioned/irrelevant read wrongly flagged ($label)"
  else
    pass "sanctioned/irrelevant read accepted ($label)"
  fi
done
# The real sweep: no swept doc carries an unsanctioned bare anchor read.
BR_FOUND=$(bare_read_scan "$OPT_KEYS" "$SKILL_DIR"/phases/*.md \
  "$SKILL_DIR/reference/continue.md" "$SKILL_DIR/reference/abort.md" \
  "$SKILL_DIR/reference/bellwether-detection.md" | tr '\n' ';')
if [[ -z "$BR_FOUND" ]]; then
  pass "no swept doc bare-reads a non-optional, non-FRONTEND anchor key without a local justification"
else
  fail "unsanctioned bare anchor read(s) — use ctx, or justify in a comment: $BR_FOUND"
fi
fi

finish_suite
