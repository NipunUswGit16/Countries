#!/usr/bin/env bash
# merge-path.test.sh — shared mutable TPL/COMP/RUN chain through the post-merge
# pre-flight sweep. Alone-run for pre-flight / materialize / build-manifest /
# scope-overlap-check / handoff-classify / structural-merge (and the empty-map
# guard). Those scripts do NOT get separate *.test.sh files.
# TEST_FILTER is refused — blocks mutate a shared fixture chain.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in merge-path.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite
setup_merge_fixture

if t "pre-flight.sh gates on the Kairos CLI"; then
# A stale CLI must fail LOUDLY before any state is written — the whole point of
# probing at pre-flight instead of discovering it mid-materialization.
FAKE_KAIROS_STALE=1 MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-stale.out" 2> "$SANDBOX/pf-stale.log"
if [[ $? -ne 0 ]]; then pass "stale CLI fails pre-flight"; else fail "stale CLI passed pre-flight"; fi
expect "stale-CLI failure names the version floor" \
  grep -q '0\.3\.12' "$SANDBOX/pf-stale.log"
expect "stale-CLI failure says to update nga-local-dev" \
  grep -qi 'nga-local-dev' "$SANDBOX/pf-stale.log"
expect "stale CLI wrote no synthetic state" test ! -d "$COMP/.kairos/migration/state/synthetic"

MODE=fresh TEMPLATE_PATH=$TPL FAKE_KAIROS_CALL_LOG=$SANDBOX/pf-calls.log \
  PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" > "$SANDBOX/pf.out" 2> "$SANDBOX/pf.log"
expect "pre-flight passes with a current CLI" test $? -eq 0
expect "pre-flight reports the CLI version" grep -q 'Kairos CLI 0\.3\.12' "$SANDBOX/pf.log"
expect "pre-flight prints CACHE" grep -q '^CACHE=' "$SANDBOX/pf.out"
expect "pre-flight prints RUN"   grep -q '^RUN=' "$SANDBOX/pf.out"

# The run-context anchor: pre-flight records what it learned into context.env
# AFTER the fresh-mode sweep, so a compacted session re-reads it from disk.
expect "pre-flight records CACHE into \$RUN/context.env" \
  grep -qx 'CACHE=.kairos/migration/state/template' .kairos/migration/state/context.env
expect "pre-flight records the local template's checked-out branch too" \
  grep -qx 'TEMPLATE_LOCAL_BRANCH=main' .kairos/migration/state/context.env
# TEMPLATE_PATH is recorded by the script that learns it, so Phase 3.5's
# wrong-target-check.sh reads it from disk — a value living only in chat
# disarms that tripwire after any compaction or resume.
expect "pre-flight records TEMPLATE_PATH into \$RUN/context.env" \
  grep -qx "TEMPLATE_PATH=$TPL" .kairos/migration/state/context.env
# SKILL_DIR is recorded for the same reason and by the same rule (the script that
# learns a value records it): every later phase locates its scripts through
# $SKILL_DIR, and after a compaction the orchestrator has nothing else to derive
# it from. Recorded as an ABSOLUTE path — phases run from the component root, and
# a relative one would resolve against whatever cwd the next tool call has.
expect "pre-flight records SKILL_DIR into \$RUN/context.env" \
  grep -qx "SKILL_DIR=$SKILL_DIR" .kairos/migration/state/context.env
expect "the recorded SKILL_DIR is absolute" \
  bash -c "sed -n 's/^SKILL_DIR=//p' .kairos/migration/state/context.env | grep -q '^/'"
expect "the recorded SKILL_DIR resolves to the scripts the phases run" \
  bash -c "test -x \"\$(sed -n 's/^SKILL_DIR=//p' .kairos/migration/state/context.env)/scripts/pre-flight.sh\""

# The CLI warm-up absorbs a pending CLI update (dependency reinstall, version-state
# migration) on a throwaway call, so the probes below it — and materialization
# later — read a settled install. Its only observable trace is that the version
# probe is no longer the FIRST invocation, so that is what the test asserts; the
# warm-up is best-effort by design and makes no promise about its effect.
expect "the warm-up invocation comes before any probe" \
  bash -c "head -1 '$SANDBOX/pf-calls.log' | grep -qx -- --version"
WARMUP_CALLS=$(grep -cx -- --version "$SANDBOX/pf-calls.log" || true)
if [[ "$WARMUP_CALLS" -eq 2 ]]; then
  pass "pre-flight burns one throwaway --version before probing the version"
else
  fail "pre-flight made $WARMUP_CALLS --version calls (want 2: warm-up + probe)"
fi

# =============================================================================
fi

if t "pre-flight.sh requires 'go' when the component carries a go.mod"; then
# Phase 3.5 parses go.mod with the go tool twice (codev-check.sh's wrong-target
# tripwire, collect-common.sh's module list) and both hard-fail without it — so
# a Go component must fail HERE, before any state is written, not mid-phase.
# PATH is narrowed to a dir carrying only git and yq, so check 0's earlier
# probes still pass and the failure is unambiguously about `go`.
cd "$COMP"
expect "the fixture component really does have a go.mod" test -f go.mod
PF_NOGO_BIN=$SANDBOX/nogo-bin; mkdir -p "$PF_NOGO_BIN"
for b in git yq perl; do ln -sf "$(command -v "$b")" "$PF_NOGO_BIN/$b"; done
env PATH="$PF_NOGO_BIN" MODE=fresh TEMPLATE_PATH="$TPL" PHASE_KEY="$PK_PREFLIGHT" \
  "$(command -v bash)" "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-nogo.out" 2> "$SANDBOX/pf-nogo.log"
PF_NOGO_RC=$?
if [[ "$PF_NOGO_RC" -ne 0 ]]; then pass "missing go fails pre-flight"; else fail "missing go passed pre-flight"; fi
expect "the failure names 'go' as the missing tool" \
  grep -q "required tool 'go' not found" "$SANDBOX/pf-nogo.log"
expect "the failure explains why (the component has a go.mod)" \
  grep -q 'go\.mod' "$SANDBOX/pf-nogo.log"
refute "a failed dependency probe emits no RUN/CACHE lines" \
  grep -qE '^(RUN|CACHE)=' "$SANDBOX/pf-nogo.out"

# =============================================================================
fi

if t "pre-flight.sh probes the yq flavor and perl (the two silent-failure tools)"; then
# Two unrelated tools install as `yq`. The python one (kislyuk/yq, a jq wrapper)
# takes different flags: yaml-gate.sh fails LOUDLY under it, collect-common.sh
# fails SILENTLY — reporting OK with zero common modules resolved and every
# common migration dropped. Both probes narrow PATH to keep the failure
# unambiguous; the `go` probe sits behind them, so getting past them is visible.
cd "$COMP"
PF_YQ_BIN=$SANDBOX/pyyq-bin; mkdir -p "$PF_YQ_BIN"
for b in git perl; do ln -sf "$(command -v "$b")" "$PF_YQ_BIN/$b"; done
# /bin/sh, not env bash: PATH is narrowed to this dir, so a `#!/usr/bin/env bash`
# shim would die resolving its own interpreter and the probe would be testing the
# wrong failure.
cat > "$PF_YQ_BIN/yq" <<'PYYQ'
#!/bin/sh
# kislyuk/yq as it identifies itself — no mikefarah marker anywhere.
[ "${1:-}" = "--version" ] && { echo "yq 3.4.3"; exit 0; }
echo "yq: error: unrecognized arguments: $*" >&2; exit 2
PYYQ
chmod +x "$PF_YQ_BIN/yq"
env PATH="$PF_YQ_BIN" MODE=fresh TEMPLATE_PATH="$TPL" PHASE_KEY="$PK_PREFLIGHT" \
  "$(command -v bash)" "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-pyyq.out" 2> "$SANDBOX/pf-pyyq.log"
PF_YQ_RC=$?
if [[ "$PF_YQ_RC" -ne 0 ]]; then pass "a python-flavored yq fails pre-flight"; else fail "a python-flavored yq passed pre-flight"; fi
expect "the failure names the implementation the skill needs" \
  grep -q 'mikefarah' "$SANDBOX/pf-pyyq.log"
expect "the failure quotes what the wrong yq reported" \
  grep -q '3\.4\.3' "$SANDBOX/pf-pyyq.log"
expect "the failure carries an install remedy" \
  grep -qi 'brew install yq' "$SANDBOX/pf-pyyq.log"
refute "a failed flavor probe emits no RUN/CACHE lines" \
  grep -qE '^(RUN|CACHE)=' "$SANDBOX/pf-pyyq.out"

# mikefarah v3 CLEARS the flavor arm: it reports `yq version 3.4.1`, the same
# spelling early v4 builds use. Every v4-only construct then fails several phases
# later instead — strenv() and `| tag` in in-progress.sh, `-p=json` in
# collect-common.sh / codev-check.sh — so the MAJOR VERSION is a check of its own.
# The shim answers everything except --version with empty output and exit 0, the way
# a working yq does for an absent manifest key, so the only thing under test is the
# version gate.
cat > "$PF_YQ_BIN/yq" <<'YQ3'
#!/bin/sh
[ "${1:-}" = "--version" ] && { echo "yq version 3.4.1"; exit 0; }
exit 0
YQ3
chmod +x "$PF_YQ_BIN/yq"
env PATH="$PF_YQ_BIN" MODE=fresh TEMPLATE_PATH="$TPL" PHASE_KEY="$PK_PREFLIGHT" \
  "$(command -v bash)" "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-yq3.out" 2> "$SANDBOX/pf-yq3.log"
PF_YQ3_RC=$?
if [[ "$PF_YQ3_RC" -ne 0 ]]; then pass "a mikefarah yq v3 fails pre-flight"
else fail "a mikefarah yq v3 passed pre-flight (its flags fail at Phase 2 instead)"; fi
expect "the failure names the required major version" \
  grep -qi 'major version 4' "$SANDBOX/pf-yq3.log"
expect "the failure quotes what the v3 build reported" \
  grep -q '3\.4\.1' "$SANDBOX/pf-yq3.log"
expect "the failure names a v4-only construct, so the diagnosis is checkable" \
  grep -q 'strenv' "$SANDBOX/pf-yq3.log"
expect "the failure carries an upgrade remedy" \
  grep -qi 'yq/v4@latest\|brew upgrade yq' "$SANDBOX/pf-yq3.log"
refute "a rejected v3 emits no RUN/CACHE lines" \
  grep -qE '^(RUN|CACHE)=' "$SANDBOX/pf-yq3.out"

# Both v4 spellings must clear the gate: the current URL-bearing one, and the older
# bare `yq version 4.9.6` — with or without the leading `v`. The version is read from
# AFTER the word `version`, never as "the first digits in the output", because the
# current spelling carries a URL.
for YQ4_SPELL in 'yq (https://github.com/mikefarah/yq/) version v4.53.3' \
                 'yq (https://github.com/mikefarah/yq/) version 4.30.8' \
                 'yq version 4.9.6'; do
  { printf '#!/bin/sh\n'
    printf '[ "${1:-}" = "--version" ] && { echo "%s"; exit 0; }\n' "$YQ4_SPELL"
    printf 'exit 0\n'
  } > "$PF_YQ_BIN/yq"
  chmod +x "$PF_YQ_BIN/yq"
  env PATH="$PF_YQ_BIN" MODE=fresh TEMPLATE_PATH="$TPL" PHASE_KEY="$PK_PREFLIGHT" \
    "$(command -v bash)" "$SKILL_DIR/scripts/pre-flight.sh" \
    > /dev/null 2> "$SANDBOX/pf-yq4.log" || true
  refute "v4 spelling '$YQ4_SPELL' clears the version gate" \
    grep -qi 'major version 4' "$SANDBOX/pf-yq4.log"
  refute "v4 spelling '$YQ4_SPELL' is not read as an unknown version either" \
    grep -qi 'could not read a major version' "$SANDBOX/pf-yq4.log"
done

# The real mikefarah build on the SAME narrowed PATH must get past the probe, or
# the assertion above would be satisfied by any yq at all being rejected.
ln -sf "$(command -v yq)" "$PF_YQ_BIN/yq"
env PATH="$PF_YQ_BIN" MODE=fresh TEMPLATE_PATH="$TPL" PHASE_KEY="$PK_PREFLIGHT" \
  "$(command -v bash)" "$SKILL_DIR/scripts/pre-flight.sh" \
  > /dev/null 2> "$SANDBOX/pf-realyq.log"
refute "the real mikefarah yq clears the flavor probe" \
  grep -q 'not the mikefarah build' "$SANDBOX/pf-realyq.log"
refute "the real mikefarah yq clears the major-version probe too" \
  grep -qi 'major version 4\|could not read a major version' "$SANDBOX/pf-realyq.log"

# intent-check.sh runs every guard under `perl -e 'alarm ...'` — the portable
# wall-clock timeout on BSD userland. Without perl the wrapper fails on each
# guard, so ONE missing tool reads as N phantom guard failures.
PF_NOPERL_BIN=$SANDBOX/noperl-bin; mkdir -p "$PF_NOPERL_BIN"
for b in git yq; do ln -sf "$(command -v "$b")" "$PF_NOPERL_BIN/$b"; done
env PATH="$PF_NOPERL_BIN" MODE=fresh TEMPLATE_PATH="$TPL" PHASE_KEY="$PK_PREFLIGHT" \
  "$(command -v bash)" "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-noperl.out" 2> "$SANDBOX/pf-noperl.log"
PF_NOPERL_RC=$?
if [[ "$PF_NOPERL_RC" -ne 0 ]]; then pass "missing perl fails pre-flight"; else fail "missing perl passed pre-flight"; fi
expect "the failure names 'perl' as the missing tool" \
  grep -q "required tool 'perl' not found" "$SANDBOX/pf-noperl.log"
expect "the failure explains what breaks without it (the guard timeout)" \
  grep -qi 'guard' "$SANDBOX/pf-noperl.log"
expect "the failure carries an install remedy" \
  grep -qi 'install perl' "$SANDBOX/pf-noperl.log"
refute "a failed perl probe emits no RUN/CACHE lines" \
  grep -qE '^(RUN|CACHE)=' "$SANDBOX/pf-noperl.out"

# =============================================================================
fi

if t "pre-flight.sh accepts a linked-worktree --template-path"; then
# A linked worktree — the natural co-dev checkout layout for a template author,
# and how a submodule presents too — carries .git as a FILE pointing at the real
# gitdir. `git -C` and `git clone` resolve it from there, so the directory-only
# test rejected a perfectly usable repo.
cd "$COMP"
PF_WT=$SANDBOX/pf-worktree
git -C "$TPL" worktree add -q -b wt/codev "$PF_WT"
expect "the linked worktree presents .git as a file, not a directory" \
  bash -c "test -f '$PF_WT/.git' && ! test -d '$PF_WT/.git'"
MODE=fresh TEMPLATE_PATH=$PF_WT PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-wt.out" 2> "$SANDBOX/pf-wt.log"
expect "pre-flight accepts a linked worktree as --template-path" test $? -eq 0
refute "no 'not a git repo' refusal" grep -q 'is not a git repo' "$SANDBOX/pf-wt.log"
expect "the worktree's checked-out branch reaches Phase 2's default chain" \
  grep -qx 'TEMPLATE_LOCAL_BRANCH=wt/codev' "$SANDBOX/pf-wt.out"
expect "the mirror clone really landed from the worktree origin" \
  test -f .kairos/migration/state/template/HEAD
git -C "$TPL" worktree remove --force "$PF_WT"

# =============================================================================
fi

if t "pre-flight.sh surfaces the local template's checked-out branch and dirtiness"; then
# A template author co-develops on a feature branch in a local clone. TARGET must
# default to THAT branch, not main — so pre-flight has to emit which branch the
# clone actually has checked out, loudly, before any expensive phase runs.
PFT=$SANDBOX/pf-template
git clone -q "$TPL" "$PFT"
git -C "$PFT" checkout -q -b feat/codev
MODE=fresh TEMPLATE_PATH=$PFT PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-branch.out" 2> "$SANDBOX/pf-branch.log"
expect "pre-flight exits 0 on a feature-branch template" test $? -eq 0
expect "pre-flight emits the local clone's checked-out branch" \
  grep -qx 'TEMPLATE_LOCAL_BRANCH=feat/codev' "$SANDBOX/pf-branch.out"
expect "the recorded TEMPLATE_LOCAL_BRANCH follows the checked-out branch (upsert)" \
  grep -qx 'TEMPLATE_LOCAL_BRANCH=feat/codev' .kairos/migration/state/context.env
expect "the recorded TEMPLATE_PATH follows the local clone (upsert)" \
  grep -qx "TEMPLATE_PATH=$PFT" .kairos/migration/state/context.env
refute "clean local template emits no dirty warning" \
  grep -qi 'uncommitted' "$SANDBOX/pf-branch.log"

# A dirty local template working tree never reaches the mirror clone, so its
# uncommitted content is invisible to the whole migration — warn, but don't block
# (deliberate co-dev workflows edit here constantly).
echo "uncommitted edit" >> "$PFT/kept.txt"
MODE=fresh TEMPLATE_PATH=$PFT PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-dirty.out" 2> "$SANDBOX/pf-dirty.log"
expect "pre-flight still exits 0 on a dirty template (non-fatal)" test $? -eq 0
expect "pre-flight warns that the dirty template is invisible to the migration" \
  bash -c "grep -qi 'uncommitted' '$SANDBOX/pf-dirty.log' && grep -qi 'invisible' '$SANDBOX/pf-dirty.log'"
git -C "$PFT" checkout -q -- kept.txt   # restore clean for later reuse

# Without a local template path there is no working checkout to speak of — a plain
# migration must behave exactly as before (no branch line, no dirty warning).
MODE=fresh PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-nopath.out" 2> "$SANDBOX/pf-nopath.log"
expect "pre-flight exits 0 without a local template path" test $? -eq 0
refute "no local path emits no TEMPLATE_LOCAL_BRANCH line" \
  grep -q '^TEMPLATE_LOCAL_BRANCH=' "$SANDBOX/pf-nopath.out"
refute "no local path emits no dirty warning" \
  grep -qi 'uncommitted' "$SANDBOX/pf-nopath.log"
refute "no local path records no TEMPLATE_LOCAL_BRANCH (fresh sweep cleared the stale one)" \
  grep -q '^TEMPLATE_LOCAL_BRANCH=' .kairos/migration/state/context.env
refute "no local path records no TEMPLATE_PATH (a stale one would mis-arm the wrong-target tripwire)" \
  grep -q '^TEMPLATE_PATH=' .kairos/migration/state/context.env
expect "CACHE is re-recorded on every successful pre-flight" \
  grep -qx 'CACHE=.kairos/migration/state/template' .kairos/migration/state/context.env

# =============================================================================
fi

if t "pre-flight.sh check 1 exempts the by-design dirty paths under MODE=continue"; then
# Every migration-log entry is written AFTER the commit it describes and rides
# the next one, and intent promotion appends to .kairos/intent.md before the
# finalize commit — so a resume after Phase 5 arrives at a dirty tree by
# design. Check 1 must not refuse that shape in continue mode, and must still
# refuse it in fresh mode and refuse any dirt beyond the two exempt paths.
# Isolated clone: the shared $COMP chain must not gain commits or dirt.
PFD=$SANDBOX/pf-continue-dirty
git clone -q "$COMP" "$PFD"
printf '# migration log\n' > "$PFD/.kairos/migration-log.md"
printf '# standing intent\n' > "$PFD/.kairos/intent.md"
git -C "$PFD" add .kairos/migration-log.md .kairos/intent.md
git -C "$PFD" -c user.email=t@t -c user.name=t commit -qm "seed tracked log + intent"

printf -- '- pending entry for the task that just committed\n' >> "$PFD/.kairos/migration-log.md"
printf -- '- 2026-08-13: promoted fact\n' >> "$PFD/.kairos/intent.md"
( cd "$PFD" && MODE=continue TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT \
    "$SKILL_DIR/scripts/pre-flight.sh" ) > "$SANDBOX/pf-cd.out" 2> "$SANDBOX/pf-cd.log"
expect "continue mode passes with only the two by-design paths dirty" test $? -eq 0
refute "no dirty-tree refusal for the pending log entry" \
  grep -qi 'working tree is dirty' "$SANDBOX/pf-cd.log"

# A STAGED .gitignore is the mid-Phase-4 shape (review-2026-08-25-round3 M3): Phase 4
# runs `git add .gitignore` (the state-dir ignore migration) several statements
# before the scaffolding commit, so a kill there leaves it staged. abort.md's
# mid-Phase-4 arm already unstages it; continue must not refuse the same window, or
# the resume is unreachable (step 2's pre-flight refuses, and continue.md forbids
# committing/stashing past the check).
printf 'a-newly-ignored-path/\n' >> "$PFD/.gitignore"
git -C "$PFD" add .gitignore
( cd "$PFD" && MODE=continue TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT \
    "$SKILL_DIR/scripts/pre-flight.sh" ) > "$SANDBOX/pf-gi.out" 2> "$SANDBOX/pf-gi.log"
expect "continue mode passes with a staged .gitignore (mid-Phase-4 window)" test $? -eq 0
refute "no dirty-tree refusal for the staged .gitignore" \
  grep -qi 'working tree is dirty' "$SANDBOX/pf-gi.log"
( cd "$PFD" && MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT \
    "$SKILL_DIR/scripts/pre-flight.sh" ) > "$SANDBOX/pf-gi-fresh.out" 2> "$SANDBOX/pf-gi-fresh.log"
if [[ $? -ne 0 ]]; then pass "fresh mode still refuses a staged .gitignore (exemption is continue-only)"; else fail "fresh mode passed with a staged .gitignore"; fi
git -C "$PFD" restore --staged .gitignore && git -C "$PFD" checkout -q -- .gitignore

echo "stray edit" >> "$PFD/kept.txt"
( cd "$PFD" && MODE=continue TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT \
    "$SKILL_DIR/scripts/pre-flight.sh" ) > "$SANDBOX/pf-cd2.out" 2> "$SANDBOX/pf-cd2.log"
if [[ $? -ne 0 ]]; then pass "continue mode still refuses dirt beyond the exempt paths"; else fail "continue mode passed with a dirty tracked source file"; fi
expect "the refusal names the boundary, not a blanket 'dirty'" \
  grep -q 'dirty beyond' "$SANDBOX/pf-cd2.log"
expect "the refusal points at continue.md's triage instead of 'commit or stash'" \
  grep -q 'continue\.md' "$SANDBOX/pf-cd2.log"
git -C "$PFD" checkout -q -- kept.txt

( cd "$PFD" && MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT \
    "$SKILL_DIR/scripts/pre-flight.sh" ) > "$SANDBOX/pf-cd3.out" 2> "$SANDBOX/pf-cd3.log"
if [[ $? -ne 0 ]]; then pass "fresh mode still refuses the same dirty log entry"; else fail "fresh mode passed on a dirty tree"; fi
expect "fresh mode keeps the commit-or-stash message" \
  grep -q 'Commit or stash' "$SANDBOX/pf-cd3.log"

# =============================================================================
fi

if t "pre-flight.sh refuses a MODE typo instead of silently running fresh"; then
# Every `${MODE:-fresh}` read below tests for the literal `continue`, so a typo
# like `continu` would silently mean FRESH — paying check 1's dirty-tree refusal
# and check 3's "delete this branch" advice on exactly the resume the caller was
# trying to declare. The closed-set check fires before any state is read, the
# same discipline the RUN_SOURCE typo already gets. It exits at the vocabulary
# gate ahead of every filesystem check, so running it against $COMP mutates
# nothing.
( cd "$COMP" && MODE=continu TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT \
    "$SKILL_DIR/scripts/pre-flight.sh" ) > "$SANDBOX/pf-modetypo.out" 2> "$SANDBOX/pf-modetypo.log"
if [[ $? -ne 0 ]]; then pass "a MODE typo is refused"; else fail "MODE=continu passed pre-flight (silently ran fresh)"; fi
expect "the refusal is the MODE closed-set message, not a dirty-tree fall-through" \
  grep -qi 'not a run mode' "$SANDBOX/pf-modetypo.log"
expect "the refusal names the bad MODE value" \
  grep -q "continu" "$SANDBOX/pf-modetypo.log"
refute "it never reached check 1 (no fresh-mode dirty-tree message leaked)" \
  grep -qi 'working tree is dirty' "$SANDBOX/pf-modetypo.log"
fi

if t "materialize.sh builds both merge sides through the CLI"; then
cd "$COMP"
export RUN=$COMP/.kairos/migration/state
export CACHE=$TPL BASE TARGET
export SYNTH=$RUN/synthetic
PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > "$SANDBOX/mat.out" 2> "$SANDBOX/mat.log"
expect "materialize.sh exits 0" test $? -eq 0
expect "materialize prints SYNTH" grep -q '^SYNTH=' "$SANDBOX/mat.out"
expect "synthetic repo has a base tag"   git -C "$SYNTH" rev-parse -q --verify kairos-base
expect "synthetic repo has a target tag" git -C "$SYNTH" rev-parse -q --verify kairos-target

# The run-context anchor: materialize records the merge-side coordinates so a
# compacted session re-reads them from disk, never from conversation memory.
expect "materialize records SYNTH into context.env"  grep -qx "SYNTH=$SYNTH" "$RUN/context.env"
expect "materialize records BASE into context.env"   grep -qx "BASE=$BASE" "$RUN/context.env"
expect "materialize records TARGET into context.env" grep -qx "TARGET=$TARGET" "$RUN/context.env"

# Paths arrive already substituted, so a synthetic path IS a component path.
expect "tokenized dir materialized at the component path" \
  git -C "$SYNTH" cat-file -e kairos-target:mycomp/config.txt
expect "tokenized content substituted by the CLI" \
  bash -c "git -C '$SYNTH' show kairos-target:mycomp/config.txt | grep -q 'extra: mycomp-setting'"

# Corrective module-path substitution: the CLI rewrites the template module to its
# own bitbucket.org/ifs-pd/<name> convention, which is NOT this component's module.
# The component's root go.mod is the authority, and both sides must agree with it.
expect "corrective substitution fixes the module path in go.mod" \
  bash -c "git -C '$SYNTH' show kairos-target:go.mod | grep -qx 'module example.com/custom/mycomp'"
expect "corrective substitution fixes imports too" \
  bash -c "git -C '$SYNTH' show kairos-target:importer.go | grep -q 'example.com/custom/mycomp/pkg/foo'"
refute "CLI-convention module path does not survive anywhere" \
  bash -c "git -C '$SYNTH' grep -q 'ifs-pd/mycomp' kairos-target"
refute "template module path does not survive anywhere" \
  bash -c "git -C '$SYNTH' grep -q 'kairos-component-template' kairos-target"
expect "materialization.txt records the corrective substitution" \
  grep -q 'corrective_module_substitution: bitbucket.org/ifs-pd/mycomp -> example.com/custom/mycomp' \
    "$RUN/materialization.txt"

# Template tooling is never part of a component.
refute "no .kairos-updates/ in the synthetic tree" \
  bash -c "git -C '$SYNTH' ls-tree -r --name-only kairos-target | grep -q '^\.kairos-updates'"

# The synthetic repo must not inherit the user's signing or hooks config: a
# global commit.gpgsign=true makes every throwaway scaffolding commit block on a
# pinentry prompt — a hang in an unattended multi-hour run — and a global
# core.hooksPath would run the user's hooks against trees they were never
# written for. Pinned locally, like identity and autocrlf above them.
expect "synthetic repo pins commit.gpgsign off" \
  bash -c "test \"\$(git -C '$SYNTH' config --local commit.gpgsign)\" = false"
expect "synthetic repo pins tag.gpgSign off" \
  bash -c "test \"\$(git -C '$SYNTH' config --local tag.gpgSign)\" = false"
expect "synthetic repo pins hooks away from any global hooksPath" \
  bash -c "test \"\$(git -C '$SYNTH' config --local core.hooksPath)\" = /dev/null"

# Surviving placeholder-shaped tokens are template FEEDBACK, not errors.
expect "surviving token reported" \
  bash -c "grep -q '<YOUR_MODULE_PATH>' '$RUN/surviving-tokens.tsv'"
expect "surviving token names the file that carries it" \
  bash -c "awk -F'\t' '\$3==\"<YOUR_MODULE_PATH>\"{print \$2}' '$RUN/surviving-tokens.tsv' | grep -qx tokened.txt"
refute "surviving-token scan ignores .kairos-updates/" \
  grep -q '\.kairos-updates' "$RUN/surviving-tokens.tsv"
refute "materialize did not exit non-zero over surviving tokens" \
  grep -q '^FAIL' "$SANDBOX/mat.log"

fi

if t "materialize.sh retries a failed 'kairos component create' once"; then
# The production failure: the CLI install changed under the first invocation and
# `component create` died with `missing 1 required positional argument`; a manual
# retry succeeded. The retry has to clear the output directory first — the aborted
# attempt leaves debris that would otherwise ride into the materialized tree and
# poison the merge base. Runs in its own $RUN so the main run's state stands.
RETRY_RUN=$SANDBOX/mat-retry
RUN=$RETRY_RUN FAKE_KAIROS_FAIL_ONCE=$SANDBOX/fail-once.state \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > "$SANDBOX/mat-retry.out" 2> "$SANDBOX/mat-retry.log"
expect "materialize.sh recovers from a first-call CLI failure" test $? -eq 0
expect "the retry is announced, not silently swallowed" \
  grep -qi 'retrying once' "$SANDBOX/mat-retry.log"
expect "the failed first attempt's log is kept for diagnosis" \
  grep -q 'component_name' "$RETRY_RUN/materialize-base.attempt1.log"
expect "the retried side landed real template content" \
  git -C "$RETRY_RUN/synthetic" cat-file -e kairos-base:kept.txt
expect "the unaffected side materialized as usual" \
  git -C "$RETRY_RUN/synthetic" rev-parse -q --verify kairos-target
refute "the aborted attempt's partial tree did not survive into the merge base" \
  bash -c "git -C '$RETRY_RUN/synthetic' ls-tree -r --name-only kairos-base | grep -q PARTIAL-ABORTED"

# =============================================================================
fi

if t "materialize.sh fails a side on an unwritable destination (no truncated tree)"; then
# ENOSPC mid-install used to be invisible: the copy loop ran in a `find | while`
# subshell, so a failed write left an empty file, the loop carried on, and the
# side was committed and tagged as if it were the template. Reproduced by making
# the synthetic repo unwritable the moment the CLI has produced its tree — a
# KAIROS_BIN wrapper is the only seam between materialization and install. Its
# own tiny template (ONE file) keeps the named file deterministic.
if [[ "$(id -u)" -eq 0 ]]; then
  # Root bypasses chmod 500 (DAC), so the lock wrapper cannot make the
  # destination unwritable — materialize genuinely succeeds and every assertion
  # below would test nothing. BB CI runs this suite as root; same skip-pass
  # posture as gate.test.sh's unreadable-baseline block.
  pass "unwritable-destination case skipped (running as root, chmod 500 stays writable)"
else
WC_TPL=$SANDBOX/writecheck-tpl
mkdir -p "$WC_TPL" && cd "$WC_TPL" && git init -q -b main
printf 'only one\n' > only.txt
git add -A && git commit -qm wc-base
WC_BASE=$(git rev-parse HEAD)
printf 'only two\n' > only.txt
git add -A && git commit -qm wc-target
WC_TARGET=$(git rev-parse HEAD)

WC_COMP=$SANDBOX/writecheck-comp
mkdir -p "$WC_COMP/.kairos" && cd "$WC_COMP" && git init -q -b main
printf 'module example.com/custom/wccomp\n' > go.mod
cat > .kairos/manifest.yaml <<EOF
name: wccomp
template:
  repo: file://$WC_TPL
  sha: $WC_BASE
  branch: main
EOF
git add -A && git commit -qm wc-comp

cat > "$SANDBOX/kairos-lock" <<'WRAP'
#!/usr/bin/env bash
# Wraps the fake CLI on PATH: once a tree has been materialized, the synthetic
# repo becomes unwritable, so the install that follows cannot write into it.
kairos "$@"; rc=$?
[ -n "${LOCK_SYNTH:-}" ] && [ -d "$LOCK_SYNTH" ] && chmod 500 "$LOCK_SYNTH"
exit $rc
WRAP
chmod +x "$SANDBOX/kairos-lock"

WC_RUN=$WC_COMP/.kairos/migration/state; mkdir -p "$WC_RUN"
RUN=$WC_RUN CACHE=$WC_TPL BASE=$WC_BASE TARGET=$WC_TARGET \
  KAIROS_BIN=$SANDBOX/kairos-lock LOCK_SYNTH=$WC_RUN/synthetic \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" \
  > "$SANDBOX/wc-mat.out" 2> "$SANDBOX/wc-mat.log"
WC_RC=$?
chmod 755 "$WC_RUN/synthetic" 2>/dev/null || true   # restore before any cleanup
if [[ "$WC_RC" -ne 0 ]]; then
  pass "an unwritable destination fails the side (exit $WC_RC)"
else
  fail "an unwritable destination materialized 'successfully'"
fi
expect "the failure names the file that could not be installed" \
  grep -q 'only.txt' "$SANDBOX/wc-mat.log"
refute "no truncated tree was committed (no kairos-base tag)" \
  git -C "$WC_RUN/synthetic" rev-parse -q --verify kairos-base
refute "a failed side emits no SYNTH line for downstream phases to trust" \
  grep -q '^SYNTH=' "$SANDBOX/wc-mat.out"
cd "$COMP"
fi

# =============================================================================
fi

if t "materialize.sh refuses an unwritable \$RUN before forming any filesystem-root path"; then
# Finding 8. The per-run scratch dirs ($RUN/mat, $RUN/synthetic) were created UNCHECKED,
# and MAT_ABS=$(cd "$MAT" && pwd) was unchecked too, so an unwritable $RUN left MAT_ABS
# EMPTY and materialize_side then built wt="$MAT_ABS/wt-$side" = "/wt-base", out =
# "/out-base" and ran `rm -rf` / `git worktree add` against filesystem-ROOT paths. The
# CACHE path two dozen lines up already guards this class; the scratch path now does too —
# a hard stop at the FIRST failed creation, naming the run dir, before any such path forms.
if [[ "$(id -u)" -eq 0 ]]; then
  pass "unwritable-\$RUN case skipped (running as root, chmod 500 stays writable)"
else
UW_TPL=$SANDBOX/uw-tpl
mkdir -p "$UW_TPL" && cd "$UW_TPL" && git init -q -b main
printf 'only one\n' > only.txt; git add -A && git commit -qm uw-base
UW_BASE=$(git rev-parse HEAD)
printf 'only two\n' > only.txt; git add -A && git commit -qm uw-target
UW_TARGET=$(git rev-parse HEAD)

UW_COMP=$SANDBOX/uw-comp
mkdir -p "$UW_COMP/.kairos" && cd "$UW_COMP" && git init -q -b main
printf 'module example.com/custom/uwcomp\n' > go.mod
cat > .kairos/manifest.yaml <<EOF
name: uwcomp
template:
  repo: file://$UW_TPL
  sha: $UW_BASE
  branch: main
EOF
git add -A && git commit -qm uw-comp

# A read-only PARENT so materialize's own `mkdir -p "$RUN/mat"` cannot create the
# scratch dir — the exact state that used to leave MAT_ABS empty.
UW_LOCK=$SANDBOX/uw-locked
mkdir -p "$UW_LOCK"; chmod 500 "$UW_LOCK"
UW_RUN=$UW_LOCK/state      # does not exist; the read-only parent blocks its creation
RUN=$UW_RUN CACHE=$UW_TPL BASE=$UW_BASE TARGET=$UW_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" \
  > "$SANDBOX/uw-mat.out" 2> "$SANDBOX/uw-mat.log"; UW_RC=$?
chmod 755 "$UW_LOCK" 2>/dev/null || true    # restore before cleanup
expect "unwritable \$RUN: materialize exits non-zero" test "$UW_RC" -ne 0
expect "unwritable \$RUN: the failure names the real cause (scratch dir / writability)" \
  grep -qiE 'scratch|writable' "$SANDBOX/uw-mat.log"
refute "unwritable \$RUN: it never reached a worktree/CLI error against a formed path" \
  grep -qiE 'component create failed|worktree for' "$SANDBOX/uw-mat.log"
refute "unwritable \$RUN: no filesystem-root scratch path was formed (/wt-base)" test -e /wt-base
refute "unwritable \$RUN: no filesystem-root scratch path was formed (/out-base)" test -e /out-base
refute "unwritable \$RUN: emits no SYNTH line for downstream phases to trust" \
  grep -q '^SYNTH=' "$SANDBOX/uw-mat.out"
cd "$COMP"
fi
fi

if t "materialize.sh hard-stops on a failed between-sides clear of \$SYNTH"; then
# install_side() clears $SYNTH's working tree (everything but .git and the reuse
# stamp) before installing each side, so a deletion between BASE and TARGET shows
# up as a deletion in the diff. That clear used to swallow its own failure
# (`2>/dev/null || true`): a partial clear (a locked file, a permission change
# mid-run) let BASE's already-committed files ride into TARGET's install,
# corrupting the classification diff with content that belongs to neither side.
# Reproduced by locking the directory BASE installed, between the two
# `kairos component create` calls — the only seam available between
# materialize_side(base)'s install and materialize_side(target)'s clear.
if [[ "$(id -u)" -eq 0 ]]; then
  # Root bypasses chmod 500 (DAC) exactly as the unwritable-destination case
  # above does, so the lock cannot make the directory unremovable there either.
  pass "failed between-sides clear case skipped (running as root, chmod 500 stays writable)"
else
CL_TPL=$SANDBOX/clearlock-tpl
mkdir -p "$CL_TPL/locked" && cd "$CL_TPL" && git init -q -b main
printf 'base plain\n'      > plain.txt
printf 'base keep\n'       > locked/keep.txt
git add -A && git commit -qm cl-base
CL_BASE=$(git rev-parse HEAD)
printf 'target plain\n'    > plain.txt
printf 'target keep\n'     > locked/keep.txt
git add -A && git commit -qm cl-target
CL_TARGET=$(git rev-parse HEAD)

CL_COMP=$SANDBOX/clearlock-comp
mkdir -p "$CL_COMP/.kairos" && cd "$CL_COMP" && git init -q -b main
printf 'module example.com/custom/clcomp\n' > go.mod
cat > .kairos/manifest.yaml <<EOF
name: clcomp
template:
  repo: file://$CL_TPL
  sha: $CL_BASE
  branch: main
EOF
git add -A && git commit -qm cl-comp

cat > "$SANDBOX/kairos-clearlock" <<'WRAP'
#!/usr/bin/env bash
# Wraps the fake CLI on PATH: after EVERY `component create` call, if the lock
# target already exists, lock it. On the BASE call $LOCK_DIR doesn't exist yet
# (harmless no-op, per -d below); by the TARGET call BASE's install has already
# committed it into the synthetic tree's working copy, so this locks it exactly
# between materialize_side(target)'s create and install_side(target)'s clear —
# the one window that matters.
kairos "$@"; rc=$?
[ -n "${LOCK_DIR:-}" ] && [ -d "$LOCK_DIR" ] && chmod 500 "$LOCK_DIR"
exit $rc
WRAP
chmod +x "$SANDBOX/kairos-clearlock"

CL_RUN=$CL_COMP/.kairos/migration/state; mkdir -p "$CL_RUN"
RUN=$CL_RUN CACHE=$CL_TPL BASE=$CL_BASE TARGET=$CL_TARGET \
  KAIROS_BIN=$SANDBOX/kairos-clearlock LOCK_DIR=$CL_RUN/synthetic/locked \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" \
  > "$SANDBOX/cl-mat.out" 2> "$SANDBOX/cl-mat.log"
CL_RC=$?
chmod -R 755 "$CL_RUN/synthetic/locked" 2>/dev/null || true   # restore before cleanup
if [[ "$CL_RC" -ne 0 ]]; then
  pass "a failed between-sides clear stops the script (exit $CL_RC)"
else
  fail "a failed between-sides clear did not stop the script"
fi
expect "the failure names \$SYNTH's clear, not a generic error" \
  grep -qi 'clear' "$SANDBOX/cl-mat.log"
expect "BASE's side is tagged (it installed before the lock landed)" \
  git -C "$CL_RUN/synthetic" rev-parse -q --verify kairos-base
refute "TARGET's side is NOT tagged (the clear failed before its install ran)" \
  git -C "$CL_RUN/synthetic" rev-parse -q --verify kairos-target
refute "a failed clear emits no SYNTH line for downstream phases to trust" \
  grep -q '^SYNTH=' "$SANDBOX/cl-mat.out"
cd "$COMP"
fi

# =============================================================================
fi

if t "materialize.sh installs a template path whose directory or name is an option string"; then
# The install loop's `dirname "$rel"` was unanchored, and `$rel` comes straight
# from a `find` over the materialized TEMPLATE tree — so a template carrying a
# leading-dash path reached dirname as a bundle of OPTIONS (it has no portable
# `--`). dirname printed a usage error and returned EMPTY, which lands two ways:
#   * a leading-dash DIRECTORY (`-e/x.txt`): `mkdir -p "$SYNTH/"` succeeded
#     vacuously, so the guard never fired, and the write that followed failed for
#     want of the directory — materialization aborted blaming the FILE, with the
#     real cause (the swallowed dirname) only in a stray usage line on stderr;
#   * a root file whose whole name is an option string (`-n`): installed, but with
#     the same usage error leaking into the operator's log.
# Its own tiny template rather than the shared fixture, so the dash paths cannot
# perturb every other suite's classification counts.
DM_TPL=$SANDBOX/dashmat-tpl
mkdir -p "$DM_TPL/-e" && cd "$DM_TPL" && git init -q -b main
printf 'dash file v1\n' > ./-n
printf 'dash dir v1\n'  > ./-e/x.txt
printf 'plain v1\n'     > plain.txt
git add -A -- . && git commit -qm dm-base
DM_BASE=$(git rev-parse HEAD)
printf 'dash file v2\n' > ./-n
printf 'dash dir v2\n'  > ./-e/x.txt
git add -A -- . && git commit -qm dm-target
DM_TARGET=$(git rev-parse HEAD)

DM_COMP=$SANDBOX/dashmat-comp
mkdir -p "$DM_COMP/.kairos" && cd "$DM_COMP" && git init -q -b main
printf 'module example.com/custom/dmcomp\n' > go.mod
cat > .kairos/manifest.yaml <<EOF
name: dmcomp
template:
  repo: file://$DM_TPL
  sha: $DM_BASE
  branch: main
EOF
git add -A && git commit -qm dm-comp
DM_RUN=$DM_COMP/.kairos/migration/state; mkdir -p "$DM_RUN"
RUN=$DM_RUN CACHE=$DM_TPL BASE=$DM_BASE TARGET=$DM_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" \
  > "$SANDBOX/dm-mat.out" 2> "$SANDBOX/dm-mat.log"
expect "materialize.sh exits 0 over leading-dash template paths" test $? -eq 0
expect "both sides are tagged" \
  bash -c "git -C '$DM_RUN/synthetic' rev-parse -q --verify kairos-base >/dev/null && git -C '$DM_RUN/synthetic' rev-parse -q --verify kairos-target >/dev/null"
expect "a file under a leading-dash DIRECTORY is installed on both sides" \
  bash -c "git -C '$DM_RUN/synthetic' show kairos-base:-e/x.txt | grep -qx 'dash dir v1' && git -C '$DM_RUN/synthetic' show kairos-target:-e/x.txt | grep -qx 'dash dir v2'"
expect "a root file whose whole name is an option string is installed on both sides" \
  bash -c "git -C '$DM_RUN/synthetic' show kairos-base:-n | grep -qx 'dash file v1' && git -C '$DM_RUN/synthetic' show kairos-target:-n | grep -qx 'dash file v2'"
expect "the ordinary sibling still installs (no collateral)" \
  bash -c "git -C '$DM_RUN/synthetic' show kairos-target:plain.txt | grep -qx 'plain v1'"
refute "no dirname usage error leaks into the materialize log" \
  grep -qE 'illegal option|invalid option|usage: dirname' "$SANDBOX/dm-mat.log"
cd "$COMP"

# =============================================================================
fi

if t "materialize.sh — install_side aborts when tr fails mid-pipe (pipefail, not sed's status)"; then
# The corrective-substitution pipe is `tr -d '\r' < src | sed ... > out`: the
# pipeline reports SED's status, so a FAILED tr (short read / disk error) that
# emits nothing still lets sed exit 0 and installs a truncated blob under a 0
# exit — silent content loss on the branch that fires on essentially every real
# migration. This block shadows tr so `-d '\r'` fails (is_binary_file's
# `-d '\000'` and the CLI's `A-Z a-z` pass through to the real tr untouched) and
# pins that install_side now ABORTS instead of committing the truncation.
# A go.mod whose module differs from the component's forces subst=1, so the
# corrective-substitution arm is the one that runs.
TR_TPL=$SANDBOX/trfail-tpl
mkdir -p "$TR_TPL" && cd "$TR_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n\ngo 1.26\n' > go.mod
printf 'hello v1\n' > app.txt
git add -A && git commit -qm tr-base
TR_BASE=$(git rev-parse HEAD)
printf 'hello v2\n' > app.txt
git add -A && git commit -qm tr-target
TR_TARGET=$(git rev-parse HEAD)

TR_COMP=$SANDBOX/trfail-comp
mkdir -p "$TR_COMP/.kairos" && cd "$TR_COMP" && git init -q -b main
printf 'module example.com/custom/trcomp\n\ngo 1.26\n' > go.mod
cat > .kairos/manifest.yaml <<EOF
name: trcomp
template:
  repo: file://$TR_TPL
  sha: $TR_BASE
  branch: main
EOF
git add -A && git commit -qm tr-comp
TR_RUN=$TR_COMP/.kairos/migration/state; mkdir -p "$TR_RUN"

# tr shadow: fail ONLY the `tr -d '\r'` invocation the subst pipe passes (the
# two-char backslash-r argument); pass everything else through to the real tr.
TR_SHADOW=$SANDBOX/trfail-bin; mkdir -p "$TR_SHADOW"
REAL_TR=$(command -v tr)
cat > "$TR_SHADOW/tr" <<EOF
#!/usr/bin/env bash
if [ -n "\${TR_FAIL_DASH_R:-}" ] && [ "\$1" = "-d" ] && [ "\$2" = '\\r' ]; then
  exit 1   # emit nothing and fail: the short-read/disk-error shape
fi
exec "$REAL_TR" "\$@"
EOF
chmod +x "$TR_SHADOW/tr"

env PATH="$TR_SHADOW:$PATH" TR_FAIL_DASH_R=1 \
  RUN="$TR_RUN" CACHE="$TR_TPL" BASE="$TR_BASE" TARGET="$TR_TARGET" \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" \
  > "$SANDBOX/trfail-mat.out" 2> "$SANDBOX/trfail-mat.log"
TRFAIL_RC=$?
expect "materialize.sh exits non-zero when the subst pipe's tr fails" \
  test "$TRFAIL_RC" -ne 0
expect "the failure is the install abort naming the file, not a downstream symptom" \
  grep -qF 'could not install' "$SANDBOX/trfail-mat.log"
refute "no success SYNTH= line is printed on the failed run (truncation not committed)" \
  grep -q '^SYNTH=' "$SANDBOX/trfail-mat.out"
cd "$COMP"

# =============================================================================
fi

if t "the synthetic sides are staged COMPLETELY and byte-exactly (ignore rules and clean filters pinned off)"; then
# `git add -A` in $SYNTH obeyed whatever ignore and filter semantics were in reach —
# and the TEMPLATE's own .gitignore/.gitattributes are installed into $SYNTH moments
# before staging, so the template itself supplies half the ammunition:
#   (a) a template .gitignore matching one of its OWN installed files kept that file
#       out of BOTH synthetic commits, so the classifier's diff was empty for it and
#       the template's change to it was silently dropped from the migration;
#   (b) an operator-global core.excludesFile did the same with no template
#       cooperation at all;
#   (c) a `filter=` driver named by the installed .gitattributes and DEFINED in the
#       operator's global config (the git-lfs shape) rewrote every blob on the way
#       into the index — the merge then ran against content neither template side
#       has, and a real v1 -> v2 change whose difference the clean filter normalizes
#       away collapsed to NO diff at all.
# A tracked file matched by .gitignore is perfectly ordinary (ignore rules only
# govern UNTRACKED paths), which is why the template can ship one; only the
# synthetic re-add ever saw it as ignorable. The ambient global config is injected
# with GIT_CONFIG_GLOBAL on the migration invocations only, so the fixture repos
# themselves are built under ordinary config.
IG_TPL=$SANDBOX/ignorefilter-tpl
mkdir -p "$IG_TPL" && cd "$IG_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'self-ignored.txt\n' > .gitignore       # the template ignores one of its own files
printf '* filter=mangle\n'  > .gitattributes   # names a driver only the OPERATOR defines
printf 'self v1\n'     > self-ignored.txt
printf 'global v1\n'   > globally-ignored.txt
printf 'filtered v1\n' > filtered.txt
git add -A -f && git commit -qm ig-base
IG_BASE=$(git rev-parse HEAD)
printf 'self v2\n'     > self-ignored.txt
printf 'global v2\n'   > globally-ignored.txt
printf 'filtered v2\n' > filtered.txt
git add -A -f && git commit -qm ig-target
IG_TARGET=$(git rev-parse HEAD)

IG_COMP=$SANDBOX/ignorefilter-comp
mkdir -p "$IG_COMP/.kairos" && cd "$IG_COMP" && git init -q -b main
printf 'module example.com/custom/igcomp\n' > go.mod
for f in self-ignored.txt globally-ignored.txt filtered.txt; do
  git -C "$IG_TPL" show "$IG_BASE:$f" > "$f"
done
cat > .kairos/manifest.yaml <<EOF
name: igcomp
template:
  repo: file://$IG_TPL
  sha: $IG_BASE
  branch: main
EOF
git add -A && git commit -qm ig-comp

# The operator's global config: an excludesFile that hides a template file, plus the
# clean filter the template's .gitattributes asks for. The filter normalizes BOTH
# versions to the same text, which is what turns a real change into no diff.
IG_EXCLUDES=$SANDBOX/ignorefilter-excludes
printf 'globally-ignored.txt\n' > "$IG_EXCLUDES"
IG_GLOBAL=$SANDBOX/ignorefilter-gitconfig
{ printf '[core]\n\texcludesFile = %s\n' "$IG_EXCLUDES"
  printf '[filter "mangle"]\n\tclean = sed -e s/v1/MANGLED/ -e s/v2/MANGLED/\n\tsmudge = cat\n'
} > "$IG_GLOBAL"

IG_RUN=$IG_COMP/.kairos/migration/state; mkdir -p "$IG_RUN"
IG_SYNTH=$IG_RUN/synthetic
GIT_CONFIG_GLOBAL=$IG_GLOBAL RUN=$IG_RUN CACHE=$IG_TPL BASE=$IG_BASE TARGET=$IG_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" \
  > "$SANDBOX/ig-mat.out" 2> "$SANDBOX/ig-mat.log"
expect "materialize.sh exits 0 under ambient ignore/filter config" test $? -eq 0

# The pins themselves, asserted the way the signing/hooks pins above are.
expect "synthetic repo pins core.excludesFile at /dev/null" \
  bash -c "test \"\$(git -C '$IG_SYNTH' config --local core.excludesFile)\" = /dev/null"
expect "synthetic repo carries its own highest-precedence attributes file" \
  test -f "$IG_SYNTH/.git/info/attributes"
# check-attr is the proof that the mechanism chosen actually WINS over the
# .gitattributes the template installed one directory up from it.
expect "the attribute pin beats the template's own .gitattributes (filter unset)" \
  bash -c "git -C '$IG_SYNTH' check-attr filter -- filtered.txt | grep -qx 'filtered.txt: filter: unset'"
expect "the attribute pin beats it for eol/text too (text unset)" \
  bash -c "git -C '$IG_SYNTH' check-attr text -- filtered.txt | grep -qx 'filtered.txt: text: unset'"
# ...and `-diff` is deliberately NOT part of that pin: unsetting diff makes git call
# every path binary, and build-manifest.sh derives binaries-template.txt from
# `diff --numstat`, so the whole template would land in binary-for-user.
expect "diff is left alone, so --numstat still tells text from binary" \
  bash -c "git -C '$IG_SYNTH' check-attr diff -- filtered.txt | grep -qx 'filtered.txt: diff: unspecified'"

for f in self-ignored.txt globally-ignored.txt filtered.txt; do
  expect "$f is present in the BASE side despite the ignore rules" \
    git -C "$IG_SYNTH" cat-file -e "kairos-base:$f"
  expect "$f is present in the TARGET side despite the ignore rules" \
    git -C "$IG_SYNTH" cat-file -e "kairos-target:$f"
done
expect "the self-ignored file's TARGET blob is the template's v2 content" \
  bash -c "git -C '$IG_SYNTH' show kairos-target:self-ignored.txt | grep -qx 'self v2'"
expect "the globally-ignored file's TARGET blob is the template's v2 content" \
  bash -c "git -C '$IG_SYNTH' show kairos-target:globally-ignored.txt | grep -qx 'global v2'"
expect "the filtered file is staged BYTE-EXACTLY (the clean filter never ran)" \
  bash -c "git -C '$IG_SYNTH' show kairos-target:filtered.txt | grep -qx 'filtered v2'"
refute "no blob on either side carries the clean filter's rewrite" \
  bash -c "git -C '$IG_SYNTH' grep -q MANGLED kairos-base || git -C '$IG_SYNTH' grep -q MANGLED kairos-target"

cd "$IG_COMP"
GIT_CONFIG_GLOBAL=$IG_GLOBAL RUN=$IG_RUN CACHE=$IG_TPL BASE=$IG_BASE TARGET=$IG_TARGET \
  SYNTH=$IG_SYNTH PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" \
  2> "$SANDBOX/ig-bm.log"
expect "the ignore/filter fixture classifies" test $? -eq 0
for f in self-ignored.txt globally-ignored.txt filtered.txt; do
  expect "the classifier sees the template's change to $f" \
    bash -c "awk -F'\t' '\$4==\"$f\"' '$IG_RUN/classification.tsv' | grep -q ."
done
cd "$COMP"

# =============================================================================
fi

if t "a template symlink rides both synthetic sides, so a retargeted link is never silently dropped"; then
# install_side listed the materialized tree with `find . -type f`, which skips
# symlinks: a template symlink was absent from BOTH synthetic sides, so retargeting
# one between BASE and TARGET produced no diff row, no bucket and no merge — the
# change vanished with nothing on stderr. It also left structural-merge.sh's
# 120000-mode arm unreachable, i.e. the one place that knows a symlink cannot ride
# the blob write path could never fire. Symlinks are now installed AS symlinks
# (mode 120000), so the change is classified and that refusal is reachable.
SL_TPL=$SANDBOX/symlink-tpl
mkdir -p "$SL_TPL" && cd "$SL_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'contents of a\n' > real-a.txt
printf 'contents of b\n' > real-b.txt
ln -s real-a.txt link.txt
git add -A && git commit -qm sl-base
SL_BASE=$(git rev-parse HEAD)
ln -sfn real-b.txt link.txt          # the ONLY change in range: the link's target
git add -A && git commit -qm sl-target
SL_TARGET=$(git rev-parse HEAD)

SL_COMP=$SANDBOX/symlink-comp
mkdir -p "$SL_COMP/.kairos" && cd "$SL_COMP" && git init -q -b main
printf 'module example.com/custom/slcomp\n' > go.mod
git -C "$SL_TPL" show "$SL_BASE:real-a.txt" > real-a.txt
git -C "$SL_TPL" show "$SL_BASE:real-b.txt" > real-b.txt
ln -s real-a.txt link.txt            # the component still has the baseline link
cat > .kairos/manifest.yaml <<EOF
name: slcomp
template:
  repo: file://$SL_TPL
  sha: $SL_BASE
  branch: main
EOF
git add -A && git commit -qm sl-comp

SL_RUN=$SL_COMP/.kairos/migration/state; mkdir -p "$SL_RUN"
SL_SYNTH=$SL_RUN/synthetic
RUN=$SL_RUN CACHE=$SL_TPL BASE=$SL_BASE TARGET=$SL_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" \
  > "$SANDBOX/sl-mat.out" 2> "$SANDBOX/sl-mat.log"
expect "materialize.sh exits 0 over a template symlink" test $? -eq 0
expect "the symlink is committed on the BASE side" \
  git -C "$SL_SYNTH" cat-file -e kairos-base:link.txt
expect "the symlink is committed on the TARGET side" \
  git -C "$SL_SYNTH" cat-file -e kairos-target:link.txt
expect "git records it as a symlink (mode 120000) on the BASE side" \
  bash -c "git -C '$SL_SYNTH' ls-tree kairos-base -- link.txt | grep -q '^120000 blob '"
expect "git records it as a symlink (mode 120000) on the TARGET side" \
  bash -c "git -C '$SL_SYNTH' ls-tree kairos-target -- link.txt | grep -q '^120000 blob '"
expect "the BASE side carries the baseline LINK TEXT" \
  bash -c "test \"\$(git -C '$SL_SYNTH' show kairos-base:link.txt)\" = real-a.txt"
expect "the TARGET side carries the retargeted LINK TEXT" \
  bash -c "test \"\$(git -C '$SL_SYNTH' show kairos-target:link.txt)\" = real-b.txt"
refute "the link was not installed as a regular file carrying its target's CONTENT" \
  bash -c "git -C '$SL_SYNTH' show kairos-target:link.txt | grep -q 'contents of b'"

cd "$SL_COMP"
RUN=$SL_RUN CACHE=$SL_TPL BASE=$SL_BASE TARGET=$SL_TARGET SYNTH=$SL_SYNTH \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/sl-bm.log"
expect "the symlink fixture classifies" test $? -eq 0
expect "the retargeted symlink is a diff row" \
  bash -c "grep -qx 'M	link.txt' '$SL_RUN/diff.tsv'"
expect "the retargeted symlink reaches a bucket" \
  bash -c "awk -F'\t' '\$4==\"link.txt\"' '$SL_RUN/classification.tsv' | grep -q ."
# End to end: the row now reaches structural-merge.sh, whose 120000 arm refuses it
# by NAME instead of the change disappearing. A loud refusal is the contract here —
# the blob write path would land the link text as the file's content.
RUN=$SL_RUN SYNTH=$SL_SYNTH BASE=$SL_BASE TARGET=$SL_TARGET \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/sl-merge.log"
SL_MERGE_RC=$?
if [[ "$SL_MERGE_RC" -ne 0 ]]; then
  pass "the symlink row is refused by the merge (exit $SL_MERGE_RC), not silently dropped"
else
  fail "the symlink row merged 'successfully' — the 120000 arm is still unreachable"
fi
expect "the refusal names the symlink path" grep -qF 'link.txt' "$SANDBOX/sl-merge.log"
expect "the refusal names the mode it cannot ride" grep -q '120000' "$SANDBOX/sl-merge.log"
expect "the component's symlink is left untouched" \
  bash -c "test \"\$(readlink link.txt)\" = real-a.txt"
cd "$COMP"

# =============================================================================
fi

if t "build-manifest.sh classification"; then
# Seeded stale row: the snapshot-sources sidecar is a per-run artifact like every
# other, and rows surviving a re-run would make the basename-collision WARN fire
# against this run's own predecessor.
printf 'stale.md\tstale-source-from-a-previous-run\n' > "$RUN/upgrade-snapshot-sources.tsv"
# The refusal ledger is SHARED with Phase 3.5, and the preservation has to run in
# both directions: collect-common.sh already drops only its own module-prefixed
# rows, while this script truncated the whole file — so a Phase 3 redo (the
# documented remedy for a missing binding) deleted Phase 3.5's common refusals and
# next-upgrade-file.sh flipped from exit 5 (capture REFUSED — re-running is not the
# remedy) to exit 4 (never captured — re-run the phase), pointing the planner at a
# loop. Seeded here: one row this script owns (bare-path source, must be replaced)
# and one Phase 3.5 row (module-prefixed source, must survive).
{ printf 'stale-own\t.kairos-updates/20250101T000000-stale-own.md\tstale refusal from a previous Phase 3 run\n'
  printf 'common-refused\tcommon:.kairos-updates/common/20260101T000000-x.md\tgit show failed — the body could not be read\n'
} > "$RUN/snapshot-refusals.tsv"
PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/bm.log"
expect "build-manifest.sh exits 0" test $? -eq 0

# The binding classification.tsv is only valid against: the trees this run diffed.
# Phase 5 re-verifies it, so the classifier owes it on every run.
expect "classification records the base tree it was derived from" \
  grep -qxF "$(printf 'base\t%s' "$(git -C "$SYNTH" rev-parse 'kairos-base^{tree}')")" \
    "$RUN/classification-trees.tsv"
expect "classification records the target tree it was derived from" \
  grep -qxF "$(printf 'target\t%s' "$(git -C "$SYNTH" rev-parse 'kairos-target^{tree}')")" \
    "$RUN/classification-trees.tsv"

refute "the snapshot-sources sidecar is truncated at the Phase 3 write" \
  grep -q 'stale-source-from-a-previous-run' "$RUN/upgrade-snapshot-sources.tsv"
expect "this run's own snapshot sources are recorded in it" \
  bash -c "awk -F'\t' '\$1==\"20260102T000000-second.md\"' '$RUN/upgrade-snapshot-sources.tsv' | grep -q ."

expect "a Phase 3.5 refusal row survives a Phase 3 re-run (one-directional preservation)" \
  bash -c "cut -f2 '$RUN/snapshot-refusals.tsv' | grep -qx 'common:.kairos-updates/common/20260101T000000-x.md'"
refute "this script's OWN stale refusal row is replaced, not accumulated" \
  grep -q 'stale-own' "$RUN/snapshot-refusals.tsv"

bucket_is kept.txt                          merge-pipeline
bucket_is clean.txt                         merge-pipeline
bucket_is crlf.txt                          merge-pipeline
bucket_is mycomp/config.txt                 merge-pipeline
bucket_is importer.go                       merge-pipeline
bucket_is newfile.txt                       added-mechanical
bucket_is bigdir/a.txt                      added-heavyweight-ask-user
bucket_is cmd/worker/main.go                added-heavyweight-ask-user
bucket_is gone-unmodified.txt               deleted-by-template-mechanical
bucket_is gone-customized.txt               modify-delete-for-ai
bucket_is modified-but-locally-deleted.txt  modify-delete-for-ai
bucket_is rename-dst.txt                    renamed-mechanical
bucket_is rename-custom-dst.txt             merge-pipeline
bucket_is rename-mods-dst.txt               renamed-with-mods-for-ai
bucket_is logo.bin                          binary-for-user

# component-side move: template modified moved-src.txt; component relocated it to
# relocated/moved-dst.txt. Enrichment-only — the row stays modify-delete-for-ai
# (never auto-merged) but carries git's guessed move target in component_path.
bucket_is moved-src.txt                     modify-delete-for-ai
expect "component-move attaches candidate path in column 6" \
  bash -c "awk -F'\t' '\$4==\"moved-src.txt\"{print \$6}' '$RUN/classification.tsv' | grep -qxF relocated/moved-dst.txt"
expect "component-rename-map maps moved-src.txt -> relocated/moved-dst.txt" \
  bash -c "awk -F'\t' '\$1==\"moved-src.txt\"{print \$2}' '$RUN/component-rename-map.tsv' | grep -qxF relocated/moved-dst.txt"
# The materialized baseline is already component-shaped, so a placeholder in the
# PATH can no longer desynchronize the rename-map lookup key.
bucket_is mycomp/moved-tok-src.txt          modify-delete-for-ai
expect "tokenized-path move attaches its candidate" \
  bash -c "awk -F'\t' '\$4==\"mycomp/moved-tok-src.txt\"{print \$6}' '$RUN/classification.tsv' | grep -qxF mycomp/relocated/moved-tok.txt"

expect "no .kairos-updates/ rows leak into classification" \
  test -z "$(cut -f3 "$RUN/classification.tsv" | grep '^\.kairos-updates/')"
expect "upgrades-added has both range files, not the baseline file" \
  bash -c "grep -q second '$RUN/upgrades-added.txt' && grep -q third '$RUN/upgrades-added.txt' && ! grep -q first '$RUN/upgrades-added.txt'"
expect "upgrades-added is in COMMIT order (third before second), not timestamp order" \
  bash -c "awk '/third/{t=NR} /second/{s=NR} END{exit !(t && s && t<s)}' '$RUN/upgrades-added.txt'"
expect "pruned upgrade (deleted before TARGET) still listed as added" \
  grep -q '20260201T000000-pruned' "$RUN/upgrades-added.txt"
expect "pruned upgrade body recovered from its add commit, not the empty tip" \
  bash -c "grep -q 'body-that-must-survive-pruning' '$RUN/upgrades/20260201T000000-pruned.md'"
expect "normal upgrade body snapshotted into \$RUN/upgrades/ too" \
  bash -c "grep -q 'upgrade 2' '$RUN/upgrades/20260102T000000-second.md'"

# Frontend compatibility floor (PRD frontend-compatibility-floor, Phase 3
# collection): the "second" upgrade-file's body carries requires-frontend:
# react@<40-hex>; every other crossed upgrade-file (first excluded from range,
# third, pruned) carries none, so it alone must produce a row.
expect "frontend-floors.tsv has exactly one row" \
  bash -c "test \$(wc -l < '$RUN/frontend-floors.tsv') -eq 1"
expect "frontend-floors.tsv row 1 is the EXACT upgrades-added.txt path" \
  bash -c "cut -f1 '$RUN/frontend-floors.tsv' | grep -qxF '.kairos-updates/20260102T000000-second.md'"
expect "frontend-floors.tsv row 1 module is react" \
  bash -c "cut -f2 '$RUN/frontend-floors.tsv' | grep -qx react"
expect "frontend-floors.tsv row 1 sha is the fabricated 40-hex floor" \
  bash -c "cut -f3 '$RUN/frontend-floors.tsv' | grep -qx '1234567890abcdef1234567890abcdef12345678'"
expect "files without requires-frontend: contribute no row (third has none)" \
  bash -c "! grep -q '^.kairos-updates/20260301T000000-third.md' '$RUN/frontend-floors.tsv'"

# supersede edges: `second` (target commit) supersedes `third` (landed first) — a
# backward, in-range edge. build-manifest.sh emits it into its own edge file with
# kind=added and the literal `template` in the module column (never empty: the
# helper reads an empty module as "not collected").
expect "supersede-edges.tsv is written by build-manifest.sh" \
  test -f "$RUN/supersede-edges.tsv"
expect "the backward template edge is emitted (superseder, superseded, added)" \
  bash -c "awk -F'\t' '\$2==\"20260102T000000-second\" && \$3==\"20260301T000000-third\" && \$4==\"added\"' '$RUN/supersede-edges.tsv' | grep -q ."

fi

if t "wholesale subtree deletion becomes a user checkpoint"; then
# Three files emptying legacy/ is a structural decision, not mechanical cleanup.
bucket_is legacy/x.txt                      deleted-heavyweight-ask-user
bucket_is legacy/y.txt                      deleted-heavyweight-ask-user
bucket_is legacy/z.txt                      deleted-heavyweight-ask-user
expect "the emptied subtree is named for the batched prompt" \
  grep -qx 'legacy' "$RUN/deleted-heavyweight-dirs.txt"
# A scattered single-file deletion must stay mechanical, or the checkpoint
# degenerates into reflexive "all as recommended".
expect "scattered single deletion stays mechanical" \
  bash -c "awk -F'\t' '\$4==\"gone-unmodified.txt\"{print \$1}' '$RUN/classification.tsv' | grep -qx deleted-by-template-mechanical"

fi

if t "a failed heavyweight re-bucket write is a loud stop, not a silent exit-0 with the completion stamp"; then
# SC4. The two heavyweight re-bucket loops were the only writes in build-manifest.sh
# exempt from its own fail-closed discipline: an `&& mv` chain short-circuits under
# `set -u`, so a failed awk or mv left the rows mechanical, STILL stamped
# classification-trees.tsv, printed "OK: manifest written" and exited 0 — a new
# subsystem (added) or a wholesale subtree deletion applied in Phase 5 with nobody
# asked, the exact batched checkpoint these blocks exist to raise. The redirect target
# `classification.tsv.tmp` is pre-created as a DIRECTORY so the awk's
# `> classification.tsv.tmp` cannot open it; the ADDITION loop trips first (the fixture's
# bigdir/ and cmd/worker/ are heavyweight roots), exercising the checked shape both loops
# now share. Both loops receive the byte-identical treatment; the deletion loop's success
# path is pinned by "wholesale subtree deletion becomes a user checkpoint" above.
SC4_RUN=$SANDBOX/sc4-run; rm -rf "$SC4_RUN"; mkdir -p "$SC4_RUN"
mkdir "$SC4_RUN/classification.tsv.tmp"    # the re-bucket redirect cannot overwrite a directory
RUN=$SC4_RUN CACHE=$CACHE BASE=$BASE TARGET=$TARGET SYNTH=$SYNTH \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" > /dev/null 2> "$SANDBOX/sc4-bm.log"
SC4_RC=$?
if [[ "$SC4_RC" -ne 0 ]]; then
  pass "an unwritable re-bucket temp is a loud stop (exit $SC4_RC), not a silent skip"
else
  fail "build-manifest.sh exited 0 despite a failed heavyweight re-bucket write"
fi
expect "the diagnostic names the re-bucket failure" \
  grep -qi 're-bucket heavyweight' "$SANDBOX/sc4-bm.log"
# The whole point: the run must NOT reach the completion stamp when a checkpoint write
# failed. classification-trees.tsv is the LAST artifact write; its absence proves the
# abort landed before it (with the unchecked chain it was still written, exit 0).
refute "the completion stamp is written despite the aborted re-bucket" \
  test -f "$SC4_RUN/classification-trees.tsv"
fi

if t "R100 pure rename never mechanically clobbers a customized destination or deletes a customized source"; then
# The mechanical rename enactment (structural-merge.sh) OVERWRITES the destination
# with the target blob and DELETES the old path. Deciding renamed-mechanical on the
# OLD path alone let a pristine old path route there even when the component had its
# OWN customized file at the new path — silently clobbered, no conflict, no
# checkpoint (review-2026-08-25-round3 M1). Both sides must be clean (absent, or
# byte-identical to their own template side) for the mechanical route.
M1_TPL=$SANDBOX/m1-tpl
mkdir -p "$M1_TPL" && cd "$M1_TPL" && git init -q -b main
printf 'renamed content\n' > pure-src.txt      # clean case: pristine old, no dst
printf 'moved content\n'   > clobber-src.txt    # main case: pristine old + CUSTOM dst
printf 'both content\n'    > both-src.txt        # sub-case: CUSTOM old + dst==target
printf 'keep\n'            > keep.txt
git add -A && git -c user.email=t@t -c user.name=t commit -qm m1-base
M1_BASE=$(git rev-parse HEAD)
git mv pure-src.txt pure-dst.txt
git mv clobber-src.txt clobber-dst.txt
git mv both-src.txt both-dst.txt
git -c user.email=t@t -c user.name=t commit -qm m1-target   # three R100 renames
M1_TARGET=$(git rev-parse HEAD)

M1_COMP=$SANDBOX/m1-comp
mkdir -p "$M1_COMP/.kairos" && cd "$M1_COMP" && git init -q -b main
printf 'module example.com/custom/m1comp\n' > go.mod
cat > .kairos/manifest.yaml <<EOF
name: m1comp
template:
  repo: file://$M1_TPL
  sha: $M1_BASE
  branch: main
EOF
printf 'renamed content\n' > pure-src.txt                 # pristine old, no pure-dst.txt
printf 'moved content\n'   > clobber-src.txt              # pristine old
printf 'DO NOT LOSE ME\n'  > clobber-dst.txt              # the component's OWN work at the new path
printf 'MY OLD-PATH WORK\n'> both-src.txt                 # customized old
printf 'both content\n'    > both-dst.txt                 # already == target at the new path
printf 'keep\n'            > keep.txt
git add -A && git -c user.email=t@t -c user.name=t commit -qm m1-comp

M1_RUN=$M1_COMP/.kairos/migration/state; mkdir -p "$M1_RUN"
M1_SYNTH=$M1_RUN/synthetic
RUN=$M1_RUN CACHE=$M1_TPL BASE=$M1_BASE TARGET=$M1_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" \
  > "$SANDBOX/m1-mat.out" 2> "$SANDBOX/m1-mat.log"
expect "materialize.sh exits 0 for the R100 fixture" test $? -eq 0
cd "$M1_COMP"
RUN=$M1_RUN CACHE=$M1_TPL BASE=$M1_BASE TARGET=$M1_TARGET SYNTH=$M1_SYNTH \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/m1-bm.log"
expect "build-manifest.sh classifies the R100 fixture" test $? -eq 0

m1_bucket() { awk -F'\t' -v d="$1" '$4==d{print $1}' "$M1_RUN/classification.tsv"; }
if [[ "$(m1_bucket pure-dst.txt)" = renamed-mechanical ]]; then
  pass "clean pure rename (pristine old, absent dst) still routes renamed-mechanical"
else
  fail "clean pure rename bucket = $(m1_bucket pure-dst.txt) (want renamed-mechanical)"
fi
if [[ "$(m1_bucket clobber-dst.txt)" = merge-pipeline ]]; then
  pass "pristine old + CUSTOMIZED dst → merge-pipeline (dst preserved by the 3-way), not renamed-mechanical"
else
  fail "customized-dst R100 bucket = $(m1_bucket clobber-dst.txt) (want merge-pipeline — renamed-mechanical would clobber DO NOT LOSE ME)"
fi
if [[ "$(m1_bucket both-dst.txt)" = modify-delete-for-ai ]]; then
  pass "customized old + dst==target → modify-delete-for-ai (old-path work surfaced), not renamed-mechanical"
else
  fail "customized-old R100 bucket = $(m1_bucket both-dst.txt) (want modify-delete-for-ai — renamed-mechanical would delete MY OLD-PATH WORK)"
fi
cd "$COMP"

# =============================================================================
fi

if t "the rename-pairing pass never loses diff rows"; then
# Regression guard: the pairing pass reads a map file that is EMPTY whenever the
# range contains fewer than 3 directory renames — which is most real migrations.
# An awk `FNR == NR` idiom silently swallowed the entire diff in that case, and the
# failure mode was an empty classification (no changed files, no merge, no error)
# rather than a crash. Assert row conservation, and assert it again below on a
# range with NO renames at all.
RAW_N=$(grep -c . "$RUN/diff.raw.tsv" || true)
OUT_N=$(grep -c . "$RUN/diff.tsv" || true)
PAIR_N=$(grep -c . "$RUN/dir-rename-pairs.tsv" || true)
if [[ "$((OUT_N + PAIR_N))" -eq "$RAW_N" ]] && [[ "$RAW_N" -gt 0 ]]; then
  pass "diff rows conserved through pairing (raw=$RAW_N out=$OUT_N paired=$PAIR_N)"
else
  fail "pairing lost rows: raw=$RAW_N out=$OUT_N paired=$PAIR_N"
fi

fi

if t "renames git dropped are re-paired across a corroborated dir rename"; then
bucket_is newpkg/a.go   renamed-mechanical
bucket_is newpkg/big.go merge-pipeline
col_is newpkg/big.go 5 oldpkg/big.go "re-paired rename carries the old path as its merge base"
col_is newpkg/big.go 7 paired-by-dir-rename "re-paired rename is tagged"
expect "the pairing is recorded for review" \
  bash -c "grep -qx 'oldpkg/big.go	newpkg/big.go' '$RUN/dir-rename-pairs.tsv'"
refute "re-paired file is NOT a plain addition (which would lose the merge base)" \
  bash -c "awk -F'\t' '\$4==\"newpkg/big.go\" && \$1 ~ /^added/' '$RUN/classification.tsv' | grep -q ."
refute "re-paired file's old path is NOT a separate deletion row" \
  bash -c "awk -F'\t' '\$4==\"oldpkg/big.go\"' '$RUN/classification.tsv' | grep -q ."

# =============================================================================
fi

if t "two old directories merging into ONE never weld both deletes onto one add"; then
# The re-pairing pass claimed an add row without REMOVING it from the pool, so when
# two old directories each carried a corroborated mapping into the SAME new one and
# each carried an unpaired delete of the same BASENAME, both deletes matched the one
# add: the second claim overwrote the first RP row's merge base, and the second D row
# was marked dropped and VANISHED from diff.tsv — a template deletion silently
# skipped. The row-conservation check could not see it, because the bogus second pair
# row balanced the lost delete exactly. Built as its own template/component pair: the
# single-directory shape above cannot produce two mappings onto one target.
DR_TPL=$SANDBOX/dirmerge-tpl
mkdir -p "$DR_TPL" && cd "$DR_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
mkdir -p oldapi oldweb
for f in a b c; do seq 1 8 | sed "s/^/api $f line /" > "oldapi/$f.go"; done
for f in d e f; do seq 1 8 | sed "s/^/web $f line /" > "oldweb/$f.go"; done
seq 1 20 | sed 's/^/alpha original line /' > oldapi/big.go
seq 1 20 | sed 's/^/bravo original line /' > oldweb/big.go
git add -A && git commit -qm dr-base
DR_BASE=$(git rev-parse HEAD)
# BOTH directories fold into shared/: 3 clean renames corroborate each mapping, and
# the two big.go files are rewritten with zero shared lines, so git reports them as
# deletes plus ONE add at shared/big.go — the same basename from two old dirs.
mkdir shared
for f in a b c; do git mv "oldapi/$f.go" "shared/$f.go"; done
for f in d e f; do git mv "oldweb/$f.go" "shared/$f.go"; done
git rm -q oldapi/big.go oldweb/big.go
seq 1 20 | sed 's/^/zulu rewritten line /' > shared/big.go
git add -A && git commit -qm dr-target
DR_TARGET=$(git rev-parse HEAD)

DR_COMP=$SANDBOX/dirmerge-comp
mkdir -p "$DR_COMP/.kairos" && cd "$DR_COMP" && git init -q -b main
printf 'module example.com/custom/drcomp\n' > go.mod
mkdir -p oldapi oldweb
for f in a b c; do git -C "$DR_TPL" show "$DR_BASE:oldapi/$f.go" > "oldapi/$f.go"; done
for f in d e f; do git -C "$DR_TPL" show "$DR_BASE:oldweb/$f.go" > "oldweb/$f.go"; done
{ git -C "$DR_TPL" show "$DR_BASE:oldapi/big.go"; echo "api customization"; } > oldapi/big.go
{ git -C "$DR_TPL" show "$DR_BASE:oldweb/big.go"; echo "web customization"; } > oldweb/big.go
cat > .kairos/manifest.yaml <<EOF
name: drcomp
template:
  repo: file://$DR_TPL
  sha: $DR_BASE
  branch: main
EOF
git add -A && git commit -qm dr-comp

DR_RUN=$DR_COMP/.kairos/migration/state; mkdir -p "$DR_RUN"
RUN=$DR_RUN CACHE=$DR_TPL BASE=$DR_BASE TARGET=$DR_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/dr-mat.log"
expect "the two-into-one fixture materializes" test $? -eq 0
RUN=$DR_RUN CACHE=$DR_TPL BASE=$DR_BASE TARGET=$DR_TARGET SYNTH=$DR_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/dr-bm.log"
expect "the two-into-one fixture classifies" test $? -eq 0

# The fixture is only worth anything if BOTH mappings really are corroborated.
expect "both oldapi -> shared and oldweb -> shared are corroborated mappings" \
  bash -c "grep -qx 'oldapi	shared' '$DR_RUN/dir-rename-maps.tsv' && grep -qx 'oldweb	shared' '$DR_RUN/dir-rename-maps.tsv'"

DR_PAIRN=$(grep -c . "$DR_RUN/dir-rename-pairs.tsv" || true)
if [[ "${DR_PAIRN:-0}" -eq 1 ]]; then
  pass "exactly one pair row is written for the single add row (both deletes cannot claim it)"
else
  fail "$DR_PAIRN pair row(s) written for one add row (want 1)"
fi
DR_RPN=$(awk -F'\t' '$1 == "RP"' "$DR_RUN/diff.tsv" | grep -c . || true)
if [[ "${DR_RPN:-0}" -eq 1 ]]; then
  pass "exactly one RP row rides diff.tsv"
else
  fail "$DR_RPN RP row(s) in diff.tsv (want 1)"
fi

# Which of the two deletes claims the add is not corroborated by anything (that is
# the point), so the assertions read the claim and check the OTHER one survived.
DR_CLAIMED=$(cut -f1 "$DR_RUN/dir-rename-pairs.tsv")
case "$DR_CLAIMED" in
  oldapi/big.go) DR_OTHER=oldweb/big.go ;;
  oldweb/big.go) DR_OTHER=oldapi/big.go ;;
  *)             DR_OTHER="" ;;
esac
expect "the claim is one of the two deletes, paired onto the single add" \
  bash -c "test -n '$DR_OTHER' && grep -qx '$DR_CLAIMED	shared/big.go' '$DR_RUN/dir-rename-pairs.tsv'"
expect "the OTHER delete survives as a plain D row in diff.tsv" \
  bash -c "grep -qx 'D	$DR_OTHER' '$DR_RUN/diff.tsv'"
refute "the claimed delete is not ALSO left as a plain D row" \
  bash -c "grep -qx 'D	$DR_CLAIMED' '$DR_RUN/diff.tsv'"
expect "the surviving delete still reaches a bucket (it is a customized file the template dropped)" \
  bash -c "awk -F'\t' '\$4==\"$DR_OTHER\"{print \$1}' '$DR_RUN/classification.tsv' | grep -qx modify-delete-for-ai"
expect "the re-paired row carries its old path as the merge base" \
  bash -c "awk -F'\t' '\$4==\"shared/big.go\"{print \$5}' '$DR_RUN/classification.tsv' | grep -qxF '$DR_CLAIMED'"

DR_RAW=$(grep -c . "$DR_RUN/diff.raw.tsv" || true)
DR_OUT=$(grep -c . "$DR_RUN/diff.tsv" || true)
if [[ "$((DR_OUT + DR_PAIRN))" -eq "$DR_RAW" ]] && [[ "$DR_RAW" -gt 0 ]]; then
  pass "diff rows conserved through the two-into-one pairing (raw=$DR_RAW out=$DR_OUT paired=$DR_PAIRN)"
else
  fail "two-into-one pairing lost rows: raw=$DR_RAW out=$DR_OUT paired=$DR_PAIRN"
fi
cd "$COMP"

# =============================================================================
fi

if t "a failed upgrade-discovery walk is a loud stop, never an empty upgrade list"; then
# The four history walks ended in `2>/dev/null || true`, so a $CACHE that could not
# answer them (a broken clone, a mirror that does not carry BASE..TARGET, a pruned
# object) produced an EMPTY upgrades-added.txt / upgrades-modified.txt /
# legacy-upgrade-commits.txt and exit 0 — every migration step the template ships
# silently skipped, which the script's own comments call strictly worse than a loud
# refusal. Re-uses the two-into-one fixture above (its last use) with a $CACHE that
# carries neither revision, which is the cheapest way to make a walk fail.
DR_BADCACHE=$SANDBOX/dirmerge-badcache
mkdir -p "$DR_BADCACHE" && cd "$DR_BADCACHE" && git init -q -b main
printf 'unrelated\n' > x.txt && git add -A && git commit -qm badcache
cd "$DR_COMP"
RUN=$DR_RUN CACHE=$DR_BADCACHE BASE=$DR_BASE TARGET=$DR_TARGET SYNTH=$DR_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/dr-badwalk.log"
DR_BW_RC=$?
if [[ "$DR_BW_RC" -ne 0 ]]; then
  pass "an unreadable history walk exits non-zero"
else
  fail "an unreadable history walk exited 0 (an empty upgrade list reported as success)"
fi
expect "the refusal names which walk failed" \
  grep -q 'ADD walk' "$SANDBOX/dr-badwalk.log"
expect "git's own reason is relayed (stderr is not swallowed)" \
  grep -qi 'fatal' "$SANDBOX/dr-badwalk.log"
expect "the refusal points at repairing the mirror, not at re-running blind" \
  grep -qi 're-fetch' "$SANDBOX/dr-badwalk.log"
refute "no tree binding is left behind, so Phase 5 hard-stops instead of merging" \
  test -f "$DR_RUN/classification-trees.tsv"
refute "the classification is not left standing as if the run had succeeded" \
  test -s "$DR_RUN/classification.tsv"
cd "$COMP"

# =============================================================================
fi

if t "an ambient log.showSignature never empties the upgrade-file set"; then
# The discovery walks parse `git log --pretty=format:'commit %H' --name-only -z`.
# With log.showSignature=true in reach (a common global for people who sign), git
# verifies each SIGNED commit and writes the verifier's output to log's STDOUT, so
# the first -z record arrives as "gpg: Good signature …\ncommit <sha>\n<path>": it
# matched neither parser arm, sha stayed EMPTY, and every record was dropped — zero
# upgrade-file rows, exit 0, "OK: manifest written", every migration step the
# template ships silently skipped. The legacy walk needed no parser to be damaged:
# the signature lines landed in legacy-upgrade-commits.txt as if each were a SHA.
# The signed commit is a stand-in — a fabricated gpgsig header plus a fake
# gpg.program is all git needs to emit verification text, so the fixture needs no
# GPG install and no keys.
SS_TPL=$SANDBOX/showsig-tpl
mkdir -p "$SS_TPL/.kairos-updates" && cd "$SS_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'seed\n' > seed.txt
printf '# legacy notes\nv1\n' > UPGRADE.md
git add -A && git commit -qm ss-base
SS_BASE=$(git rev-parse HEAD)
printf '# signed upgrade\nintent: migrate the call sites\nbody-behind-the-signature\n' \
  > .kairos-updates/20260601T000000-signed.md
printf 'seed changed\n' > seed.txt
printf '# legacy notes\nv1\nv2\n' > UPGRADE.md
git add -A && git commit -qm ss-target

# A gpgsig header spliced into the target commit, and a gpg.program that behaves
# like a verifier: git relays the verifier's output into the log stream, which is
# exactly how signature text reaches log's stdout.
git cat-file commit HEAD > "$SANDBOX/ss-commit.raw"
awk '!done && /^committer /{ print;
       print "gpgsig -----BEGIN PGP SIGNATURE-----"; print " "; print " AAAAFAKESIG"
       print " -----END PGP SIGNATURE-----"; done=1; next } { print }' \
  "$SANDBOX/ss-commit.raw" > "$SANDBOX/ss-commit-signed.raw"
SS_TARGET=$(git hash-object -t commit -w "$SANDBOX/ss-commit-signed.raw")
git update-ref refs/heads/main "$SS_TARGET"
cat > "$SANDBOX/ss-fake-gpg" <<'FAKEGPG'
#!/bin/sh
echo "gpg: Signature made Mon Jun  1 00:00:00 2026" >&2
echo "gpg: Good signature from \"Template Author <a@example.com>\" [ultimate]" >&2
exit 0
FAKEGPG
chmod +x "$SANDBOX/ss-fake-gpg"
git config gpg.program "$SANDBOX/ss-fake-gpg"
git config log.showSignature true
# The fixture is worthless unless the repro is live, so prove the injection first.
expect "the fixture really does put signature text on git log's stdout" \
  bash -c "git -C '$SS_TPL' log -1 --pretty=format:'commit %H' --name-only | grep -q '^gpg: '"

SS_COMP=$SANDBOX/showsig-comp
mkdir -p "$SS_COMP/.kairos" && cd "$SS_COMP" && git init -q -b main
printf 'module example.com/custom/sscomp\n' > go.mod
git -C "$SS_TPL" show "$SS_BASE:seed.txt" > seed.txt
cat > .kairos/manifest.yaml <<EOF
name: sscomp
template:
  repo: file://$SS_TPL
  sha: $SS_BASE
  branch: main
EOF
git add -A && git commit -qm ss-comp

SS_RUN=$SS_COMP/.kairos/migration/state; mkdir -p "$SS_RUN"
RUN=$SS_RUN CACHE=$SS_TPL BASE=$SS_BASE TARGET=$SS_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/ss-mat.log"
expect "the signed-commit fixture materializes" test $? -eq 0
RUN=$SS_RUN CACHE=$SS_TPL BASE=$SS_BASE TARGET=$SS_TARGET SYNTH=$SS_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/ss-bm.log"
expect "the signed-commit fixture classifies" test $? -eq 0
expect "the upgrade-file added in the SIGNED commit is discovered" \
  grep -qx '.kairos-updates/20260601T000000-signed.md' "$SS_RUN/upgrades-added.txt"
expect "its provenance row carries the signed commit's SHA, not signature text" \
  bash -c "awk -F'\t' '\$2==\".kairos-updates/20260601T000000-signed.md\"{print \$1}' '$SS_RUN/upgrades-added.tsv' | grep -qx '$SS_TARGET'"
expect "its body is snapshotted" \
  grep -q body-behind-the-signature "$SS_RUN/upgrades/20260601T000000-signed.md"
expect "the legacy UPGRADE.md walk records the commit" \
  grep -qx "$SS_TARGET" "$SS_RUN/legacy-upgrade-commits.txt"
refute "no signature text is recorded as if it were a commit SHA" \
  grep -q '^gpg:' "$SS_RUN/legacy-upgrade-commits.txt"

# Defense in depth: with --no-show-signature on every walk, the parser arm that
# refuses an unattributable record is no longer reachable through config — so it is
# proven with a `git` shim that injects text into the ADD walk's stdout regardless,
# standing in for the NEXT setting that writes there. The refusal must be loud and
# must tear down what a previous successful run left behind.
SS_SHIM=$SANDBOX/showsig-shim; mkdir -p "$SS_SHIM"
SS_REALGIT=$(command -v git)
{ cat <<'SSSHIM'
#!/bin/sh
# Prepends text to the ADD walk's STDOUT and forwards everything else untouched.
for a in "$@"; do
  [ "$a" = "--diff-filter=A" ] || continue
  printf 'gpg: Good signature from "Template Author"\n'
  break
done
SSSHIM
  printf 'exec %s "$@"\n' "$SS_REALGIT"
} > "$SS_SHIM/git"
chmod +x "$SS_SHIM/git"
# The shim must still BE git for everything else, or the block below would be
# testing a broken git rather than the parser's refusal.
expect "the injecting shim still forwards ordinary git commands" \
  bash -c "PATH='$SS_SHIM:\$PATH' git -C '$SS_TPL' rev-parse --verify '$SS_TARGET' >/dev/null"
env PATH="$SS_SHIM:$PATH" RUN=$SS_RUN CACHE=$SS_TPL BASE=$SS_BASE TARGET=$SS_TARGET \
  SYNTH=$SS_RUN/synthetic PHASE_KEY=$PK_CLASSIFY \
  bash "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/ss-stray.log"
SS_STRAY_RC=$?
if [[ "$SS_STRAY_RC" -ne 0 ]]; then
  pass "a record that belongs to no commit exits non-zero instead of being skipped"
else
  fail "an unattributable record was silently dropped (exit 0)"
fi
expect "the refusal names which walk emitted it" \
  grep -q 'ADD walk' "$SANDBOX/ss-stray.log"
expect "the refusal quotes the stray record" \
  grep -q 'Good signature' "$SANDBOX/ss-stray.log"
expect "the refusal names the likely cause and where to look" \
  grep -qi 'showSignature' "$SANDBOX/ss-stray.log"
refute "no tree binding is left behind, so Phase 5 hard-stops instead of merging" \
  test -f "$SS_RUN/classification-trees.tsv"
refute "the classification is not left standing as if the run had succeeded" \
  test -s "$SS_RUN/classification.tsv"
cd "$COMP"

# =============================================================================
fi

if t "a delete of legacy UPGRADE.md is ignored while an in-range modify is still recorded"; then
# The legacy walk carries --diff-filter=AM (adds/modifies only, excluding deletions):
# legacy notes were
# always added or modified (a section appended to UPGRADE.md), so a commit that only
# REMOVES the frozen file carries no migration instruction. A repo retiring UPGRADE.md
# must not have that removal surface as a spurious legacy note in any BASE..TARGET
# window it straddles — while an in-range add/modify is a real note and must survive.
DL_TPL=$SANDBOX/legacydel-tpl
mkdir -p "$DL_TPL" && cd "$DL_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'seed\n' > seed.txt
printf '# legacy notes\nv1\n' > UPGRADE.md
git add -A && git commit -qm dl-base
DL_BASE=$(git rev-parse HEAD)
printf '# legacy notes\nv1\nv2\n' > UPGRADE.md      # MODIFY — a real legacy note in range
printf 'seed changed\n' > seed.txt
git add -A && git commit -qm dl-modify
DL_MOD=$(git rev-parse HEAD)
git rm -q UPGRADE.md                                # DELETE — must be ignored
printf 'seed changed again\n' > seed.txt
git add -A && git commit -qm dl-delete
DL_TARGET=$(git rev-parse HEAD)

DL_COMP=$SANDBOX/legacydel-comp
mkdir -p "$DL_COMP/.kairos" && cd "$DL_COMP" && git init -q -b main
printf 'module example.com/custom/dlcomp\n' > go.mod
git -C "$DL_TPL" show "$DL_BASE:seed.txt" > seed.txt
cat > .kairos/manifest.yaml <<EOF
name: dlcomp
template:
  repo: file://$DL_TPL
  sha: $DL_BASE
  branch: main
EOF
git add -A && git commit -qm dl-comp

DL_RUN=$DL_COMP/.kairos/migration/state; mkdir -p "$DL_RUN"
RUN=$DL_RUN CACHE=$DL_TPL BASE=$DL_BASE TARGET=$DL_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/dl-mat.log"
expect "the legacy-delete fixture materializes" test $? -eq 0
RUN=$DL_RUN CACHE=$DL_TPL BASE=$DL_BASE TARGET=$DL_TARGET SYNTH=$DL_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/dl-bm.log"
expect "the legacy-delete fixture classifies" test $? -eq 0
expect "the in-range MODIFY of UPGRADE.md is recorded" \
  grep -qx "$DL_MOD" "$DL_RUN/legacy-upgrade-commits.txt"
refute "the DELETE of UPGRADE.md is NOT recorded as a legacy note" \
  grep -qx "$DL_TARGET" "$DL_RUN/legacy-upgrade-commits.txt"
cd "$COMP"

# =============================================================================
fi

if t "an R100 rename of an EMPTY template placeholder never claims the component's own file"; then
# matches_template compared `git show <blob>` against `tr -d '\r' < "$2"`, and with
# $2 ABSENT that redirection yielded 0 bytes (its error hidden by the caller's
# 2>/dev/null): an absent local file compared EQUAL to an EMPTY template blob. The
# R100 arm only guarantees that ONE of OLD_DEST/DEST exists, so a template renaming
# a 0-byte placeholder classified `renamed-mechanical` for a component that had
# deleted the old path and written its OWN content at the new one — and Phase 5
# enacts that bucket with an unconditional overwrite of the destination: customized
# content destroyed, no conflict, no checkpoint.
EP_TPL=$SANDBOX/emptyren-tpl
mkdir -p "$EP_TPL" && cd "$EP_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'seed\n' > seed.txt
: > placeholder-old.txt                       # a 0-byte placeholder the template ships
git add -A && git commit -qm ep-base
EP_BASE=$(git rev-parse HEAD)
git mv placeholder-old.txt placeholder-new.txt
printf 'seed changed\n' > seed.txt
git add -A && git commit -qm ep-target
EP_TARGET=$(git rev-parse HEAD)

EP_COMP=$SANDBOX/emptyren-comp
mkdir -p "$EP_COMP/.kairos" && cd "$EP_COMP" && git init -q -b main
printf 'module example.com/custom/epcomp\n' > go.mod
git -C "$EP_TPL" show "$EP_BASE:seed.txt" > seed.txt
# The component dropped the placeholder and wrote its OWN file at the path the
# template later renames INTO — the shape the pre-fix comparison called identical.
printf 'my own content that must survive\n' > placeholder-new.txt
cat > .kairos/manifest.yaml <<EOF
name: epcomp
template:
  repo: file://$EP_TPL
  sha: $EP_BASE
  branch: main
EOF
git add -A && git commit -qm ep-comp

EP_RUN=$EP_COMP/.kairos/migration/state; mkdir -p "$EP_RUN"
RUN=$EP_RUN CACHE=$EP_TPL BASE=$EP_BASE TARGET=$EP_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/ep-mat.log"
expect "the empty-placeholder fixture materializes" test $? -eq 0
RUN=$EP_RUN CACHE=$EP_TPL BASE=$EP_BASE TARGET=$EP_TARGET SYNTH=$EP_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/ep-bm.log"
expect "the empty-placeholder fixture classifies" test $? -eq 0
# The fixture only tests anything if git really reports the rename as R100.
expect "git reports the placeholder rename as R100 (the arm under test)" \
  bash -c "grep -qx 'R100	placeholder-old.txt	placeholder-new.txt' '$EP_RUN/diff.tsv'"
refute "the row is NOT renamed-mechanical (which Phase 5 overwrites unconditionally)" \
  bash -c "awk -F'\t' '\$4==\"placeholder-new.txt\" && \$1==\"renamed-mechanical\"' '$EP_RUN/classification.tsv' | grep -q ."
expect "it routes to the merge pipeline instead, where the local content is a side" \
  bash -c "awk -F'\t' '\$4==\"placeholder-new.txt\"{print \$1}' '$EP_RUN/classification.tsv' | grep -qx merge-pipeline"
# End to end: the component's content survives the structural merge.
cd "$EP_COMP"
RUN=$EP_RUN SYNTH=$EP_RUN/synthetic BASE=$EP_BASE TARGET=$EP_TARGET \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/ep-merge.log"
expect "the merge runs over the empty-placeholder rename" test $? -eq 0
expect "the component's own content survived the merge" \
  grep -qx 'my own content that must survive' placeholder-new.txt
cd "$COMP"

# =============================================================================
fi

if t "a snapshot body that cannot be WRITTEN is a recorded refusal, not a phantom capture"; then
# snap_upgrade's final `mv "$tmp" "$dest"` was unchecked and the "captured" row in
# upgrade-snapshot-sources.tsv was written unconditionally after it, while both call
# sites are `|| true`. An unwritable $RUN/upgrades (a permission change, ENOSPC, a
# cross-device rename) therefore produced: the slug in upgrades-added.txt with NO
# body, no refusal row, a sources row claiming a capture that never happened, and
# exit 0 — and next-upgrade-file.sh then answered exit 4 ("never captured — re-run
# the phase") for a slug re-running cannot produce, i.e. exactly the loop the
# exit-4/5 split exists to keep the planner out of.
if [[ "$(id -u)" -eq 0 ]]; then
  pass "unwritable-\$RUN/upgrades case skipped (running as root, chmod 500 stays writable)"
else
UW2_TPL=$SANDBOX/snapwrite-tpl
mkdir -p "$UW2_TPL/.kairos-updates" && cd "$UW2_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'seed\n' > seed.txt
git add -A && git commit -qm uw2-base
UW2_BASE=$(git rev-parse HEAD)
printf '# unwritable\nintent: migrate\nbody-that-cannot-land\n' \
  > .kairos-updates/20260701T000000-unwritable.md
printf 'seed changed\n' > seed.txt
git add -A && git commit -qm uw2-target
UW2_TARGET=$(git rev-parse HEAD)

UW2_COMP=$SANDBOX/snapwrite-comp
mkdir -p "$UW2_COMP/.kairos" && cd "$UW2_COMP" && git init -q -b main
printf 'module example.com/custom/uw2comp\n' > go.mod
git -C "$UW2_TPL" show "$UW2_BASE:seed.txt" > seed.txt
cat > .kairos/manifest.yaml <<EOF
name: uw2comp
template:
  repo: file://$UW2_TPL
  sha: $UW2_BASE
  branch: main
EOF
git add -A && git commit -qm uw2-comp

UW2_RUN=$UW2_COMP/.kairos/migration/state; mkdir -p "$UW2_RUN"
RUN=$UW2_RUN CACHE=$UW2_TPL BASE=$UW2_BASE TARGET=$UW2_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/uw2-mat.log"
expect "the snapshot-write fixture materializes" test $? -eq 0
# The snapshot destination exists but cannot be written into: the read succeeds and
# only the final mv fails, which is the case the unchecked write hid.
mkdir -p "$UW2_RUN/upgrades"; chmod 500 "$UW2_RUN/upgrades"
RUN=$UW2_RUN CACHE=$UW2_TPL BASE=$UW2_BASE TARGET=$UW2_TARGET SYNTH=$UW2_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/uw2-bm.log"
UW2_RC=$?
chmod 755 "$UW2_RUN/upgrades" 2>/dev/null || true    # restore before any cleanup
# One unstorable body is a loud skip, not an aborted classification — the same
# posture the failed-READ path takes.
expect "the run still completes (exit 0)" test "$UW2_RC" -eq 0
expect "the slug is still listed as an upgrade to apply" \
  grep -q '20260701T000000-unwritable' "$UW2_RUN/upgrades-added.txt"
refute "no body was left behind at the destination" \
  test -e "$UW2_RUN/upgrades/20260701T000000-unwritable.md"
expect "the failure is loud on stderr" \
  grep -qi '20260701T000000-unwritable' "$SANDBOX/uw2-bm.log"
expect "the refusal is RECORDED, so the read end can tell it from 'never collected'" \
  bash -c "cut -f1 '$UW2_RUN/snapshot-refusals.tsv' | grep -qx 20260701T000000-unwritable"
expect "the recorded reason names the write, not a read or an emptiness" \
  bash -c "awk -F'\t' '\$1==\"20260701T000000-unwritable\"{print \$3}' '$UW2_RUN/snapshot-refusals.tsv' | grep -qi 'could not be written'"
refute "no 'captured' row claims a body that never landed" \
  bash -c "cut -f1 '$UW2_RUN/upgrade-snapshot-sources.tsv' | grep -qx 20260701T000000-unwritable.md"
# The whole point of the row: the read end must NOT send the planner back to re-run
# the phase (exit 4) for a body re-running cannot produce.
RUN=$UW2_RUN SLUG=20260701T000000-unwritable LIST=$UW2_RUN/upgrades-added.txt \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > /dev/null 2> "$SANDBOX/uw2-serve.log"
UW2_SERVE_RC=$?
if [[ "$UW2_SERVE_RC" -eq 5 ]]; then
  pass "the read end reports the refused capture (exit 5), not 're-run the phase' (exit 4)"
else
  fail "the read end exited $UW2_SERVE_RC for an unstorable body (want 5)"
fi

# MN-S5c: the SNAP_REFUSALS prune chain (mktemp && awk > tmp && mv) is now checked
# stage by stage — under `set -u` alone the old `&&` chain just short-circuited, so
# a failed stage silently SKIPPED the truncation (this run's stale refusal rows
# survived, and next-upgrade-file.sh reads them to answer a stale exit 5) and
# leaked the temp. The mktemp is forced to fail by exporting a TMPDIR that does not
# exist (the argument the script builds is `$TMPDIR/snap-refusals.XXXXXX`); the
# prune branch is reached because a refusal row is present. git tolerates the bad
# env TMPDIR for the diff/log walks, so classification proceeds to the prune.
printf 'ghost\t.kairos-updates/20260101T000000-ghost.md\tstale refusal from a previous run\n' \
  > "$UW2_RUN/snapshot-refusals.tsv"
TMPDIR=/nonexistent/kairos-no-such-dir \
  RUN=$UW2_RUN CACHE=$UW2_TPL BASE=$UW2_BASE TARGET=$UW2_TARGET SYNTH=$UW2_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" > /dev/null 2> "$SANDBOX/uw2-prune.log"
UW2_PRUNE_RC=$?
if [[ "$UW2_PRUNE_RC" -ne 0 ]]; then
  pass "an unprunable refusal ledger is a loud stop (exit $UW2_PRUNE_RC), not a silent skip"
else
  fail "build-manifest.sh exited 0 despite a failed refusal-ledger prune"
fi
expect "the diagnostic names the prune failure" \
  grep -qi 'temp file to prune' "$SANDBOX/uw2-prune.log"
cd "$COMP"
fi

# =============================================================================
fi

if t "build-manifest.sh emits summary.txt + query.sh (affordance removal)"; then
# The expensive read is `cat classification.tsv`; the cheap one must be more
# convenient than retyping an awk one-liner, or agents keep doing the expensive
# thing regardless of the prose telling them not to.
expect "summary.txt was written" test -s "$RUN/summary.txt"
TOTAL_ROWS=$(grep -c . "$RUN/classification.tsv" || true)
SUMMARY_SUM=$(awk -F'\t' '$1 !~ /^(component-side-moves|dir-rename-pairs|deleted-heavyweight-dirs)$/ && NF==2 { s += $2 } END { print s+0 }' "$RUN/summary.txt")
if [[ "$SUMMARY_SUM" = "$TOTAL_ROWS" ]]; then
  pass "summary.txt bucket counts sum to the full classification (=$TOTAL_ROWS)"
else
  fail "summary.txt bucket counts sum to $SUMMARY_SUM, want $TOTAL_ROWS"
fi
for b in merge-pipeline added-mechanical added-heavyweight-ask-user modify-delete-for-ai renamed-mechanical renamed-with-mods-for-ai binary-for-user deleted-heavyweight-ask-user; do
  want=$(awk -F'\t' -v b="$b" '$1==b' "$RUN/classification.tsv" | grep -c . || true)
  got=$(awk -F'\t' -v b="$b" '$1==b{print $2}' "$RUN/summary.txt")
  if [[ "${got:-0}" = "$want" ]]; then pass "summary.txt count for $b = $want"; else fail "summary.txt count for $b = ${got:-<none>} (want $want)"; fi
done

expect "query.sh was generated"  test -f "$RUN/query.sh"
expect "query.sh is executable" test -x "$RUN/query.sh"
expect "query.sh with no args fails with a usage message" bash -c "! '$RUN/query.sh' 2>/dev/null"
DIRECT=$(awk -F'\t' '$1=="modify-delete-for-ai"' "$RUN/classification.tsv")
QUERIED=$("$RUN/query.sh" modify-delete-for-ai)
if [[ "$QUERIED" = "$DIRECT" ]]; then
  pass "query.sh <bucket> matches the documented awk one-liner"
else
  fail "query.sh <bucket> output differs from the documented awk one-liner"
fi
QCOL=$("$RUN/query.sh" modify-delete-for-ai 4)
DCOL=$(awk -F'\t' '$1=="modify-delete-for-ai"{print $4}' "$RUN/classification.tsv")
if [[ "$QCOL" = "$DCOL" ]]; then
  pass "query.sh <bucket> <column> selects a single field"
else
  fail "query.sh <bucket> <column> output differs from the documented awk form"
fi

fi

if t "scope-overlap-check.sh (advisory signal after classification)"; then
OVERLAP_MP=$(awk -F'\t' '$1=="merge-pipeline"{print $2}' "$RUN/summary.txt")
RUN=$RUN THRESHOLD=$((OVERLAP_MP + 5)) "$SKILL_DIR/scripts/scope-overlap-check.sh" \
  > "$SANDBOX/sc-overlap-ok.out" 2>&1
expect "under merge-pipeline threshold exits 0" test $? -eq 0
expect "overlap check names merge-pipeline count" grep -qx "MERGE_PIPELINE=$OVERLAP_MP" "$SANDBOX/sc-overlap-ok.out"
expect "overlap under-threshold verdict says OK" grep -q '^OK:' "$SANDBOX/sc-overlap-ok.out"

# Over the threshold the run gets more expensive, not wrong. Blocking here could
# only ever offer a smaller TARGET — a trade many components cannot make — so the
# signal must stay advisory and never stop the migration to ask.
RUN=$RUN THRESHOLD=$((OVERLAP_MP - 1)) "$SKILL_DIR/scripts/scope-overlap-check.sh" \
  > "$SANDBOX/sc-overlap-adv.out" 2>&1
SO_RC=$?
expect "over merge-pipeline threshold is advisory only (exits 0)" test "$SO_RC" -eq 0
expect "overlap over-threshold reports the real count" grep -qx "MERGE_PIPELINE=$OVERLAP_MP" "$SANDBOX/sc-overlap-adv.out"
expect "overlap over-threshold names its own threshold" grep -qx "THRESHOLD=$((OVERLAP_MP - 1))" "$SANDBOX/sc-overlap-adv.out"
expect "overlap over-threshold verdict says ADVISORY" grep -q '^ADVISORY:' "$SANDBOX/sc-overlap-adv.out"
refute "overlap check never blocks with ASK" grep -q '^ASK:' "$SANDBOX/sc-overlap-adv.out"

# A healthy small migration can have ZERO merge-pipeline files. build-manifest
# tallies buckets with `uniq -c`, so an empty bucket produces no line at all — a
# well-formed summary.txt simply omits the `merge-pipeline` row. That must read as
# count 0 (exit 0, OK), not the "build-manifest didn't run" hard stop (exit 2).
# Regression: the gate used to read the missing row as an empty count and exit 2.
SO0=$SANDBOX/scope-overlap-zero; mkdir -p "$SO0"
printf 'added-mechanical\t3\nmodify-delete-for-ai\t1\n' > "$SO0/summary.txt"
RUN=$SO0 "$SKILL_DIR/scripts/scope-overlap-check.sh" > "$SANDBOX/so-zero.out" 2> "$SANDBOX/so-zero.err"
SO_ZERO_RC=$?
if [[ "$SO_ZERO_RC" -eq 0 ]]; then pass "zero merge-pipeline rows reads as count 0 (exit 0)"; else fail "zero merge-pipeline rows exited $SO_ZERO_RC (want 0)"; fi
expect "zero-overlap verdict reports MERGE_PIPELINE=0" grep -qx 'MERGE_PIPELINE=0' "$SANDBOX/so-zero.out"
expect "zero-overlap verdict says OK" grep -q '^OK:' "$SANDBOX/so-zero.out"
refute "zero-overlap never warns" grep -q '^ADVISORY:' "$SANDBOX/so-zero.out"
refute "zero-overlap never FAILs" grep -qi 'FAIL' "$SANDBOX/so-zero.err"

# A genuinely missing summary.txt is still the build-manifest-didn't-run hard stop.
SOM=$SANDBOX/scope-overlap-missing; mkdir -p "$SOM"
RUN=$SOM "$SKILL_DIR/scripts/scope-overlap-check.sh" > /dev/null 2>&1
if [[ $? -eq 2 ]]; then pass "missing summary.txt still exits 2 (hard stop)"; else fail "missing summary.txt did not exit 2"; fi

fi

if t "handoff-classify.sh (read-time handoff card entering Phase 5)"; then
# Entering Phase 5, the orchestrator reads THIS instead of re-deriving bucket
# state from classification.tsv or from earlier conversation history.
HC_OUT=$SANDBOX/hc.out
RUN=$RUN "$SKILL_DIR/scripts/handoff-classify.sh" > "$HC_OUT" 2> "$SANDBOX/hc.log"
expect "handoff-classify.sh exits 0" test $? -eq 0
refute "handoff-classify.sh does not write a disk handoff card" test -f "$RUN/handoff-classify.md"

for b in merge-pipeline added-mechanical added-heavyweight-ask-user modify-delete-for-ai; do
  want=$(awk -F'\t' -v b="$b" '$1==b{print $2}' "$RUN/summary.txt")
  if grep -qx "$(printf '%s\t%s' "$b" "$want")" "$HC_OUT"; then
    pass "handoff-classify stdout bucket tally for $b = $want"
  else
    fail "handoff-classify stdout missing bucket tally line for $b = $want"
  fi
done

expect "ask-user buckets get a ready query.sh one-liner" \
  bash -c "grep -q 'added-heavyweight-ask-user' '$HC_OUT' && grep -q 'query.sh added-heavyweight-ask-user' '$HC_OUT'"
expect "for-AI buckets get a ready query.sh one-liner" \
  bash -c "grep -q 'modify-delete-for-ai' '$HC_OUT' && grep -q 'query.sh modify-delete-for-ai' '$HC_OUT'"
refute "a bucket absent from this run (unknown-status) is not listed as a query" \
  grep -q 'query.sh unknown-status' "$HC_OUT"
refute "handoff card does not embed classification row content (a file path)" \
  grep -q 'mycomp/config.txt' "$HC_OUT"
expect "pointer to classification.tsv for post-mortem only" \
  grep -q "$RUN/classification.tsv" "$HC_OUT"
expect "pointer to the emptied-subtree list" \
  grep -q "$RUN/deleted-heavyweight-dirs.txt" "$HC_OUT"

fi

if t "handoff-classify.sh degrades when summary.txt or query.sh are absent"; then
HC_SPARSE=$SANDBOX/handoff-classify-sparse
mkdir -p "$HC_SPARSE"
cp "$RUN/classification.tsv" "$HC_SPARSE/"
RUN=$HC_SPARSE "$SKILL_DIR/scripts/handoff-classify.sh" > "$SANDBOX/hc-sparse.out" 2> "$SANDBOX/hc-sparse.log"
expect "handoff-classify.sh exits 0 with only classification.tsv present" test $? -eq 0
expect "sparse handoff still names classification.tsv" \
  grep -q "$HC_SPARSE/classification.tsv" "$SANDBOX/hc-sparse.out"
refute "sparse handoff does not reference a missing query.sh" \
  grep -q 'query.sh' "$SANDBOX/hc-sparse.out"

fi

if t "handoff-classify.sh counts non-blank entries (newline/blank edge cases)"; then
HC_NL=$SANDBOX/handoff-classify-no-nl
mkdir -p "$HC_NL"
printf 'modify-delete-for-ai\tM\t.\ta.txt\nmodify-delete-for-ai\tM\t.\tb.txt\nmodify-delete-for-ai\tM\t.\tc.txt' \
  > "$HC_NL/classification.tsv"
RUN=$HC_NL "$SKILL_DIR/scripts/handoff-classify.sh" > "$SANDBOX/hc-nl.out" 2> "$SANDBOX/hc-nl.log"
expect "handoff-classify (no trailing newline) exits 0" test $? -eq 0
expect "handoff-classify counts 3 entries without trailing newline" \
  grep -qx 'modify-delete-for-ai	3' "$SANDBOX/hc-nl.out"

HC_BL=$SANDBOX/handoff-classify-blank
mkdir -p "$HC_BL"
printf 'modify-delete-for-ai\tM\t.\ta.txt\n\nmodify-delete-for-ai\tM\t.\tb.txt\n' \
  > "$HC_BL/classification.tsv"
RUN=$HC_BL "$SKILL_DIR/scripts/handoff-classify.sh" > "$SANDBOX/hc-bl.out" 2> "$SANDBOX/hc-bl.log"
expect "handoff-classify (embedded blank line) exits 0" test $? -eq 0
expect "handoff-classify skips embedded blank lines (count 2)" \
  grep -qx 'modify-delete-for-ai	2' "$SANDBOX/hc-bl.out"

fi

if t "handoff-classify.sh sums duplicate summary.txt rows instead of dropping the bucket"; then
# Two rows for the same bucket (a hand-edit, or a resumed run whose tally got
# appended to rather than replaced) used to hand query_line() a multi-line
# count; its numeric "-gt 0" test errored out silently and the whole bucket
# vanished from both the ask-user tally and the query.sh one-liner instead of
# reporting the true total. Regression.
HC_DUP=$SANDBOX/handoff-classify-dup
mkdir -p "$HC_DUP"
printf 'added-heavyweight-ask-user\t3\nadded-heavyweight-ask-user\t4\nmodify-delete-for-ai\t2\n' \
  > "$HC_DUP/summary.txt"
cat > "$HC_DUP/query.sh" <<'EOF'
#!/usr/bin/env bash
true
EOF
chmod +x "$HC_DUP/query.sh"
RUN=$HC_DUP "$SKILL_DIR/scripts/handoff-classify.sh" > "$SANDBOX/hc-dup.out" 2> "$SANDBOX/hc-dup.log"
expect "handoff-classify.sh (duplicate summary rows) exits 0" test $? -eq 0
expect "duplicate ask-user rows are summed, not dropped, in the ready query line" \
  grep -qx "$(printf 'added-heavyweight-ask-user\t7\t%s/query.sh added-heavyweight-ask-user' "$HC_DUP")" "$SANDBOX/hc-dup.out"

# =============================================================================
fi

if t "structural-merge.sh refuses a \$SYNTH that is not a usable synthetic repo"; then
# show_synth() swallows git errors because BLOB-level absence is legitimate (an
# added file has an empty base). REPO-level absence is not: a stale $SYNTH would
# otherwise reach "OK: structural merge done" with every added file written
# EMPTY. Runs before the real merge below, so the "nothing was touched"
# assertions are checked against a tree the merge has not yet entered.
SYNTH=$SANDBOX/no-such-synth PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/sm-probe-missing.log"
expect "a missing \$SYNTH directory exits 1" test $? -eq 1
expect "the refusal names the tag it could not find" \
  grep -q 'missing tag kairos-base' "$SANDBOX/sm-probe-missing.log"
expect "the refusal carries the re-materialize remedy" \
  grep -q 'scripts/materialize.sh' "$SANDBOX/sm-probe-missing.log"

SM_NOREPO=$SANDBOX/sm-not-a-repo; mkdir -p "$SM_NOREPO"
SYNTH=$SM_NOREPO PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/sm-probe-norepo.log"
expect "a \$SYNTH that is not a git repo exits 1" test $? -eq 1
expect "the not-a-repo refusal names materialize.sh" \
  grep -q 'scripts/materialize.sh' "$SANDBOX/sm-probe-norepo.log"

SM_NOTAG=$SANDBOX/sm-no-target-tag
mkdir -p "$SM_NOTAG" && git -C "$SM_NOTAG" init -q -b main
git -C "$SM_NOTAG" commit -q --allow-empty -m base && git -C "$SM_NOTAG" tag kairos-base
SYNTH=$SM_NOTAG PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/sm-probe-notag.log"
expect "a repo carrying only one side tag exits 1" test $? -eq 1
expect "the refusal names the side tag that is missing" \
  grep -q 'missing tag kairos-target' "$SANDBOX/sm-probe-notag.log"

# The probe precedes the list truncation and every write, so a refused run is
# indistinguishable from not having run at all.
refute "no probe refusal created the output lists" test -e "$RUN/added.txt"
refute "no probe refusal wrote an added-mechanical file (the empty-file failure)" \
  test -e newfile.txt

fi

if t "a missing target-side blob is a hard error, never an empty file"; then
# The repo-level probe above cannot see the per-ROW case: a classification row
# naming a path the THEIRS tree does not carry — the shape classification.tsv
# takes once it is stale against a re-materialized $SYNTH. The pre-fix accessor
# swallowed that git error, so the row landed as an EMPTY file recorded in
# clean-merged.txt / added.txt and the run still reported "OK".
#
# Own fixture, own $RUN: the synthetic repo is built by hand because two tagged
# commits is the entire contract materialize.sh leaves behind, and the component
# only has to be a git repo the classifier can diff against.
ST_SYNTH=$SANDBOX/stale-theirs-synth
mkdir -p "$ST_SYNTH" && git -C "$ST_SYNTH" init -q -b main
seq 1 5 | sed 's/^/keep line /'   > "$ST_SYNTH/kept.txt"
seq 1 5 | sed 's/^/doomed line /' > "$ST_SYNTH/doomed.txt"
git -C "$ST_SYNTH" add -A && git -C "$ST_SYNTH" commit -qm st-base
git -C "$ST_SYNTH" tag -f kairos-base >/dev/null
ST_BASE=$(git -C "$ST_SYNTH" rev-parse HEAD)
sed 's/keep line 3/keep line three CHANGED/' "$ST_SYNTH/kept.txt" > "$ST_SYNTH/kept.new" \
  && mv "$ST_SYNTH/kept.new" "$ST_SYNTH/kept.txt"
rm -f "$ST_SYNTH/doomed.txt"        # deleted at TARGET: no theirs-side blob
git -C "$ST_SYNTH" add -A && git -C "$ST_SYNTH" commit -qm st-target
git -C "$ST_SYNTH" tag -f kairos-target >/dev/null
ST_TARGET=$(git -C "$ST_SYNTH" rev-parse HEAD)

ST_COMP=$SANDBOX/stale-theirs-comp
mkdir -p "$ST_COMP" && cd "$ST_COMP" && git init -q -b main
git -C "$ST_SYNTH" show "kairos-base:kept.txt" | sed 's/keep line 4/keep line four MINE/' > kept.txt
git -C "$ST_SYNTH" show "kairos-base:doomed.txt" > doomed.txt   # byte-identical to base
cp doomed.txt "$SANDBOX/st-doomed.orig"
git add -A && git commit -qm st-comp
ST_RUN=$SANDBOX/stale-theirs-run; mkdir -p "$ST_RUN"

# A real classification first, so the binding below is valid and the only thing
# under test is the absent blob. $ST_SYNTH doubles as $CACHE: the only history
# read is `.kairos-updates/`, which this fixture has none of.
SYNTH=$ST_SYNTH CACHE=$ST_SYNTH BASE=$ST_BASE TARGET=$ST_TARGET RUN=$ST_RUN \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/st-bm.log"
expect "the stale-theirs fixture classifies" test $? -eq 0

st_merge() { # st_merge <log-name> — run the merge over the crafted classification
  SYNTH=$ST_SYNTH BASE=$ST_BASE TARGET=$ST_TARGET RUN=$ST_RUN \
    PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
    > /dev/null 2> "$SANDBOX/$1"
}

# (a) merge-pipeline against a vanished theirs blob — the silent-wipe case: ours
# equals base, so an empty theirs merges CLEAN and empties the file.
printf 'merge-pipeline\tM\tdoomed.txt\tdoomed.txt\t\t\t\n' > "$ST_RUN/classification.tsv"
st_merge st-merge-missing.log
if [[ $? -ne 0 ]]; then
  pass "a merge-pipeline row whose theirs blob is absent exits non-zero"
else
  fail "a merge-pipeline row whose theirs blob is absent exited 0"
fi
expect "the refusal names the path"      grep -qF 'doomed.txt' "$SANDBOX/st-merge-missing.log"
expect "the refusal names the stale classification as the likely cause" \
  grep -qi 'stale' "$SANDBOX/st-merge-missing.log"
expect "the refusal carries the re-classify remedy" \
  grep -q 'build-manifest.sh' "$SANDBOX/st-merge-missing.log"
expect "the component's file is left byte-identical (not emptied)" \
  cmp -s doomed.txt "$SANDBOX/st-doomed.orig"
refute "nothing was recorded as cleanly merged" test -s "$ST_RUN/clean-merged.txt"
refute "the refused run did not report success" \
  grep -q 'OK: structural merge done' "$SANDBOX/st-merge-missing.log"

# (b) added-mechanical against a vanished theirs blob — the empty-file case.
printf 'added-mechanical\tA\tghost.txt\tghost.txt\t\t\t\n' > "$ST_RUN/classification.tsv"
st_merge st-added-missing.log
if [[ $? -ne 0 ]]; then
  pass "an added-mechanical row whose theirs blob is absent exits non-zero"
else
  fail "an added-mechanical row whose theirs blob is absent exited 0"
fi
refute "no empty file was written for the absent addition" test -e ghost.txt
refute "nothing was recorded as mechanically added" test -s "$ST_RUN/added.txt"

# (c) renamed-mechanical against a vanished theirs blob — the worst shape: the
# pre-fix path wrote an empty file at the new path and then DELETED the old one.
printf 'renamed-mechanical\tR100\tghost-new.txt\tghost-new.txt\tdoomed.txt\t\t\n' \
  > "$ST_RUN/classification.tsv"
st_merge st-renamed-missing.log
if [[ $? -ne 0 ]]; then
  pass "a renamed-mechanical row whose theirs blob is absent exits non-zero"
else
  fail "a renamed-mechanical row whose theirs blob is absent exited 0"
fi
refute "no empty file was written at the rename destination" test -e ghost-new.txt
expect "the rename's old path was NOT removed" test -f doomed.txt
refute "nothing was recorded as renamed" test -s "$ST_RUN/renamed.txt"

cd "$COMP"
fi

if t "the classification is bound to the synthetic trees it was derived from"; then
# Same fixture. classification.tsv is only meaningful against the exact trees it
# was diffed from; a $SYNTH re-materialized between Phase 3 and Phase 5 (a
# corrected BASE, a moved TARGET) leaves every row describing a tree that no
# longer exists. The binding turns that into a refusal naming the remedy.
cd "$ST_COMP"
st_classify() {
  SYNTH=$ST_SYNTH CACHE=$ST_SYNTH BASE=$ST_BASE TARGET=$ST_TARGET RUN=$ST_RUN \
    PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/$1"
}
# Restore the fixture tree before every merge below, so each refusal is
# attributable to the binding alone and never to the live-marker re-run guard
# left armed by a previous sub-run. Anchored with -C on the fixture path, never
# on the cwd: a whole-tree checkout/clean must be impossible to aim anywhere else.
st_restore() {
  git -C "$ST_COMP" checkout -- . >/dev/null 2>&1
  git -C "$ST_COMP" clean -fdq >/dev/null 2>&1
}
st_classify st-bm2.log
expect "re-classifying against the current trees exits 0" test $? -eq 0
expect "the classifier stamps the base tree it derived from" \
  grep -qxF "$(printf 'base\t%s' "$(git -C "$ST_SYNTH" rev-parse 'kairos-base^{tree}')")" \
    "$ST_RUN/classification-trees.tsv"
expect "the classifier stamps the target tree it derived from" \
  grep -qxF "$(printf 'target\t%s' "$(git -C "$ST_SYNTH" rev-parse 'kairos-target^{tree}')")" \
    "$ST_RUN/classification-trees.tsv"

# An unstamped classification cannot be verified, so it is refused rather than
# trusted — a hand-written or pre-binding file fails closed.
rm -f "$ST_RUN/classification-trees.tsv"
st_restore; st_merge st-unstamped.log
if [[ $? -ne 0 ]]; then
  pass "a classification carrying no tree binding is refused"
else
  fail "a classification carrying no tree binding was merged"
fi
expect "the unstamped refusal names the re-classify remedy" \
  grep -q 'build-manifest.sh' "$SANDBOX/st-unstamped.log"

# Now re-materialize: a new TARGET tree under a classification stamped against
# the old one.
st_classify st-bm-restamp.log
printf 'brand new at target\n' > "$ST_SYNTH/newly-added.txt"
git -C "$ST_SYNTH" add -A && git -C "$ST_SYNTH" commit -qm st-target-2
git -C "$ST_SYNTH" tag -f kairos-target >/dev/null
ST_TARGET=$(git -C "$ST_SYNTH" rev-parse HEAD)
st_restore; st_merge st-target-drift.log
if [[ $? -ne 0 ]]; then
  pass "a target tree re-materialized after classification is refused"
else
  fail "a target tree re-materialized after classification was merged"
fi
expect "the refusal names the side that drifted" \
  grep -q 'target' "$SANDBOX/st-target-drift.log"
expect "the refusal directs the orchestrator to re-run classification" \
  grep -q 'build-manifest.sh' "$SANDBOX/st-target-drift.log"
refute "the refused run recorded nothing as cleanly merged" test -s "$ST_RUN/clean-merged.txt"
refute "the refused run wrote no file from the new target tree" test -e newly-added.txt
expect "the refused run left the component's files intact" \
  cmp -s doomed.txt "$SANDBOX/st-doomed.orig"

# The base side is bound too — a corrected BASE is the other half of the case.
st_classify st-bm3.log
git -C "$ST_SYNTH" tag -f kairos-base "$ST_TARGET" >/dev/null
st_restore; st_merge st-base-drift.log
if [[ $? -ne 0 ]]; then
  pass "a base tree re-materialized after classification is refused"
else
  fail "a base tree re-materialized after classification was merged"
fi
expect "the base-side refusal names the base side" \
  grep -q 'base' "$SANDBOX/st-base-drift.log"
git -C "$ST_SYNTH" tag -f kairos-base "$ST_BASE" >/dev/null

# And the documented remedy actually clears it: re-run Phase 3, then Phase 5.
st_classify st-bm4.log
st_restore; st_merge st-remedy.log
expect "re-running classification clears the refusal" test $? -eq 0
expect "the remedied merge reports success" \
  grep -q 'OK: structural merge done' "$SANDBOX/st-remedy.log"
expect "the remedied merge lands the new target file" test -f newly-added.txt

cd "$COMP"
fi

if t "every unwritable row is refused up front, all at once, tree untouched"; then
# The per-row hard error alone fired from INSIDE the enactment loop, so a bad row
# at position 5 of 9 left rows 1-4 enacted: a file written, a rename's source
# DELETED, both recorded — a half-migrated tree behind an exit 1, while
# reference/structural-merge.md promises a refused run is indistinguishable from
# not having run. The pre-scan makes that literally true and names EVERY bad row
# instead of dying on the first, so one Phase 3 redo fixes the whole set.
#
# Own fixture, own $RUN: the target tree carries a symlink and a directory
# alongside the good paths, so all four unwritable shapes (absent, tree,
# symlink mode, no destination) are reachable from one classification, and the
# two control shapes (a legitimately-absent deleted-by-template row, an ask-user
# row this script never enacts) ride along to pin the pre-scan's scope.
PS_SYNTH=$SANDBOX/prescan-synth
mkdir -p "$PS_SYNTH" && git -C "$PS_SYNTH" init -q -b main
seq 1 6 | sed 's/^/two line /' > "$PS_SYNTH/two.txt"
printf 'src at base\n'  > "$PS_SYNTH/rename-src.txt"
printf 'doomed at base\n' > "$PS_SYNTH/gone.txt"
git -C "$PS_SYNTH" add -A && git -C "$PS_SYNTH" commit -qm ps-base
git -C "$PS_SYNTH" tag -f kairos-base >/dev/null
PS_BASE=$(git -C "$PS_SYNTH" rev-parse HEAD)
sed 's/two line 2/two line two CHANGED/' "$PS_SYNTH/two.txt" > "$PS_SYNTH/two.new" \
  && mv "$PS_SYNTH/two.new" "$PS_SYNTH/two.txt"
printf 'brand new at target\n' > "$PS_SYNTH/added-ok.txt"
printf 'also new at target\n'  > "$PS_SYNTH/nodest.txt"
printf '#!/bin/sh\necho hi\n'  > "$PS_SYNTH/exec.sh"; chmod 755 "$PS_SYNTH/exec.sh"
git -C "$PS_SYNTH" mv rename-src.txt renamed.txt
git -C "$PS_SYNTH" rm -q gone.txt
mkdir -p "$PS_SYNTH/subdir" && printf 'inside\n' > "$PS_SYNTH/subdir/keep.txt"
ln -sf /etc/passwd "$PS_SYNTH/evil-link"
git -C "$PS_SYNTH" add -A && git -C "$PS_SYNTH" commit -qm ps-target
git -C "$PS_SYNTH" tag -f kairos-target >/dev/null
PS_TARGET=$(git -C "$PS_SYNTH" rev-parse HEAD)
expect "the fixture target tree really carries a symlink" \
  bash -c "git -C '$PS_SYNTH' ls-tree kairos-target -- evil-link | grep -q '^120000'"

PS_COMP=$SANDBOX/prescan-comp
mkdir -p "$PS_COMP" && cd "$PS_COMP" && git init -q -b main
git -C "$PS_SYNTH" show "kairos-base:two.txt"        > two.txt   # == base: merges clean
git -C "$PS_SYNTH" show "kairos-base:rename-src.txt" > rename-src.txt
git -C "$PS_SYNTH" show "kairos-base:gone.txt"       > gone.txt
git add -A && git commit -qm ps-comp
PS_RUN=$SANDBOX/prescan-run; mkdir -p "$PS_RUN"

ps_merge() { # ps_merge <log-name>
  SYNTH=$PS_SYNTH BASE=$PS_BASE TARGET=$PS_TARGET RUN=$PS_RUN \
    PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
    > /dev/null 2> "$SANDBOX/$1"
}
# Structure AND content, so a stray mkdir -p (write_theirs makes the destination's
# parent before it writes) is as visible as a written file.
ps_snap() { # ps_snap <prefix>
  ( cd "$PS_COMP" && find . -path ./.git -prune -o -print | LC_ALL=C sort ) > "$1.paths"
  ( cd "$PS_COMP" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort \
      | xargs cksum ) > "$1.sums"
}
ps_lists() { # ps_lists <dir>
  rm -rf "$1"; mkdir -p "$1"
  for f in clean-merged conflicts merge-errors binaries normalized-ours added deleted renamed; do
    cp "$PS_RUN/$f.txt" "$1/$f.txt" 2>/dev/null || true
  done
}

SYNTH=$PS_SYNTH CACHE=$PS_SYNTH BASE=$PS_BASE TARGET=$PS_TARGET RUN=$PS_RUN \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/ps-bm.log"
expect "the pre-scan fixture classifies (valid tree binding)" test $? -eq 0

# A PREVIOUS, legitimate run: its output lists and resolver verdicts are what a
# refusal must leave alone. Hand-editing rows keeps the binding valid, so the
# crafted classifications below are exactly the documented editing case.
printf 'merge-pipeline\tM\ttwo.txt\ttwo.txt\t\t\t\n' > "$PS_RUN/classification.tsv"
ps_merge ps-prior.log
expect "the prior run merged" test $? -eq 0
expect "the prior run recorded two.txt as cleanly merged" \
  grep -qxF two.txt "$PS_RUN/clean-merged.txt"
printf 'two.txt\t1\tours\tprevious attempt\n' > "$PS_RUN/resolutions.tsv"
cp "$PS_RUN/resolutions.tsv" "$PS_RUN/resolutions.role-switch.tsv"
ps_snap "$SANDBOX/ps-before"; ps_lists "$SANDBOX/ps-lists-before"

# Ten rows: good, good, control, control, BAD, BAD, BAD, BAD, BAD, good. The good
# rows straddle the bad ones, so "nothing was enacted" is not vacuous. The fifth bad
# row is a renamed-mechanical whose old-path column (5) is empty but whose template
# path IS a writable target blob — so it clears theirs_problem and only the new
# old-path clause catches it (Finding 9); untouched, its enactment writes the blob
# and records the move nowhere.
printf '%s\n' \
  $'added-mechanical\tA\tadded-ok.txt\tadded-ok.txt\t\t\t' \
  $'renamed-mechanical\tR100\trenamed.txt\trenamed.txt\trename-src.txt\t\t' \
  $'deleted-by-template-mechanical\tD\tgone.txt\tgone.txt\t\t\t' \
  $'added-heavyweight-ask-user\tA\tbigdir/x.txt\tbigdir/x.txt\t\t\t' \
  $'added-mechanical\tA\tghost.txt\tghost.txt\t\t\t' \
  $'added-mechanical\tA\tevil-link\tevil-link\t\t\t' \
  $'merge-pipeline\tM\tsubdir\tsubdir\t\t\t' \
  $'added-mechanical\tA\tnodest.txt\t\t\t\t' \
  $'renamed-mechanical\tR100\texec.sh\texec.sh\t\t\t' \
  $'merge-pipeline\tM\ttwo.txt\ttwo.txt\t\t\t' \
  > "$PS_RUN/classification.tsv"
ps_merge ps-refused.log
PS_RC=$?
if [[ "$PS_RC" -eq 1 ]]; then
  pass "a classification carrying unwritable rows exits 1"
else
  fail "a classification carrying unwritable rows exited $PS_RC (want 1)"
fi
refute "the refused run did not report success" \
  grep -q 'OK: structural merge done' "$SANDBOX/ps-refused.log"

# ALL of them, in one refusal — a first-bad-row-only stop makes the operator
# re-run Phase 3 once per bad row.
expect "the refusal names the absent path"        grep -qF 'ghost.txt'   "$SANDBOX/ps-refused.log"
expect "the refusal names the symlink path"       grep -qF 'evil-link'   "$SANDBOX/ps-refused.log"
expect "the refusal names the directory path"     grep -qF 'subdir'      "$SANDBOX/ps-refused.log"
expect "the refusal names the destination-less path" grep -qF 'nodest.txt' "$SANDBOX/ps-refused.log"
expect "the refusal counts every bad row (5)" \
  grep -q '5 classification row' "$SANDBOX/ps-refused.log"
# One message per shape: "has no such file" for a directory or a symlink
# misdescribes what is wrong and sends the operator looking for a missing file.
expect "an absent entry is described as absent" \
  bash -c "grep -F 'ghost.txt' '$SANDBOX/ps-refused.log' | grep -qi 'absent'"
expect "a symlink entry names its git mode, not absence" \
  bash -c "grep -F 'evil-link' '$SANDBOX/ps-refused.log' | grep -q '120000'"
expect "a symlink refusal says the link text would have been written as content" \
  grep -qi 'link text' "$SANDBOX/ps-refused.log"
expect "a directory entry is described as a tree, not absence" \
  bash -c "grep -F 'subdir' '$SANDBOX/ps-refused.log' | grep -q 'tree'"
expect "a destination-less row says so" \
  bash -c "grep -F 'nodest.txt' '$SANDBOX/ps-refused.log' | grep -qi 'destination'"
# Finding 9: a renamed-mechanical row whose OLD-path column is empty clears
# theirs_problem (its template path is a real target blob) but must still be
# refused — untouched, its enactment writes the blob and records the move nowhere.
expect "an empty-old-path renamed-mechanical row is refused (its reason names the missing old path)" \
  bash -c "grep -F 'renamed-mechanical' '$SANDBOX/ps-refused.log' | grep -qi 'old path'"
expect "the refusal names the stale classification as the likely cause" \
  grep -qi 'stale' "$SANDBOX/ps-refused.log"
expect "the refusal carries the re-classify remedy" \
  grep -q 'build-manifest.sh' "$SANDBOX/ps-refused.log"
# Scope: rows this script does not enact are never flagged. A
# deleted-by-template row names a path the target tree cannot carry BY
# DEFINITION, and the ask-user buckets are vetted by apply-ask-user.sh.
refute "a deleted-by-template row is not flagged for its legitimate absence" \
  grep -qF 'gone.txt' "$SANDBOX/ps-refused.log"
refute "an ask-user row is not flagged (apply-ask-user.sh owns it)" \
  grep -qF 'bigdir/x.txt' "$SANDBOX/ps-refused.log"
refute "the good rows are not named in the refusal" \
  grep -qF 'added-ok.txt' "$SANDBOX/ps-refused.log"

# Indistinguishable from not having run: tree, output lists, resolver verdicts.
ps_snap "$SANDBOX/ps-after"
expect "the refused run changed no path in the tree" \
  cmp -s "$SANDBOX/ps-before.paths" "$SANDBOX/ps-after.paths"
expect "the refused run changed no file content in the tree" \
  cmp -s "$SANDBOX/ps-before.sums" "$SANDBOX/ps-after.sums"
refute "the good added row was NOT written before the bad row was reached" test -e added-ok.txt
expect "the good rename's SOURCE still exists (it was not enacted)" test -f rename-src.txt
refute "the good rename's destination was not created" test -e renamed.txt
expect "the control deletion did not happen" test -f gone.txt
refute "no symlink target text landed as a file" test -e evil-link
refute "no directory was materialized for the tree row" test -e subdir
ps_lists "$SANDBOX/ps-lists-after"
expect "the previous run's output lists survive the refusal byte-for-byte" \
  diff -r "$SANDBOX/ps-lists-before" "$SANDBOX/ps-lists-after"
expect "the previous run's clean-merged.txt was not truncated" \
  grep -qxF two.txt "$PS_RUN/clean-merged.txt"
expect "the previous attempt's aggregate resolver verdicts survive" \
  test -s "$PS_RUN/resolutions.tsv"
expect "the previous attempt's resolver shards survive" \
  test -s "$PS_RUN/resolutions.role-switch.tsv"

# The control: the same classification minus the four bad rows runs to completion,
# so the pre-scan blocks unwritable rows and nothing else. exec.sh (mode 100755)
# rides along — the mode check admits both blob modes, not just 100644.
printf '%s\n' \
  $'added-mechanical\tA\tadded-ok.txt\tadded-ok.txt\t\t\t' \
  $'added-mechanical\tA\texec.sh\texec.sh\t\t\t' \
  $'renamed-mechanical\tR100\trenamed.txt\trenamed.txt\trename-src.txt\t\t' \
  $'deleted-by-template-mechanical\tD\tgone.txt\tgone.txt\t\t\t' \
  $'added-heavyweight-ask-user\tA\tbigdir/x.txt\tbigdir/x.txt\t\t\t' \
  $'merge-pipeline\tM\ttwo.txt\ttwo.txt\t\t\t' \
  > "$PS_RUN/classification.tsv"
ps_merge ps-green.log
expect "the same classification without the bad rows merges" test $? -eq 0
expect "the good addition landed"            grep -q 'brand new at target' added-ok.txt
expect "an executable-mode blob is admitted" test -f exec.sh
expect "the rename landed at the new path"   test -f renamed.txt
refute "the rename source is gone"           test -e rename-src.txt
refute "the control deletion was enacted"    test -e gone.txt
expect "the merge-pipeline row took the template change" \
  grep -q 'two line two CHANGED' two.txt
refute "the ask-user row was still not enacted by this script" test -e bigdir/x.txt

cd "$COMP"
fi

if t "structural-merge.sh — a working-tree symlink at a write destination is routed to conflicts, never written THROUGH (F12)"; then
# F12: a component that replaced a template-managed file with a symlink. Every
# working-tree write (write_theirs to $dest, the cp of the merged blob to
# $a_dest) opens the destination through whatever is there, so a `[ -L ]` dest
# sent git show / cp output to the LINK TARGET — potentially outside the repo —
# while the tree kept the link and no artifact named the divergence. Distinct
# from the target-side 120000 case the pre-scan already refuses: here the TARGET
# tree carries a REGULAR file at each path (theirs_problem passes), and it is the
# component's own working-tree file that is the symlink. All three write arms are
# exercised: added-mechanical, merge-pipeline, renamed-mechanical.
SL2_SYNTH=$SANDBOX/sl2-synth
mkdir -p "$SL2_SYNTH" && git -C "$SL2_SYNTH" init -q -b main
printf 'base merge content\n' > "$SL2_SYNTH/merge-me.txt"
printf 'src at base\n'        > "$SL2_SYNTH/ren-src.txt"
git -C "$SL2_SYNTH" add -A && git -C "$SL2_SYNTH" -c user.email=t@t -c user.name=t commit -qm sl2-base
git -C "$SL2_SYNTH" tag -f kairos-base >/dev/null
SL2_BASE=$(git -C "$SL2_SYNTH" rev-parse HEAD)
printf 'target merge content\n' > "$SL2_SYNTH/merge-me.txt"   # M row
printf 'brand new content\n'     > "$SL2_SYNTH/add-me.txt"     # A row
git -C "$SL2_SYNTH" mv ren-src.txt ren-dst.txt                 # R row
git -C "$SL2_SYNTH" add -A && git -C "$SL2_SYNTH" -c user.email=t@t -c user.name=t commit -qm sl2-target
git -C "$SL2_SYNTH" tag -f kairos-target >/dev/null
SL2_TARGET=$(git -C "$SL2_SYNTH" rev-parse HEAD)

# Canaries OUTSIDE the component tree: if any write follows a link, THESE change.
SL2_CANARY=$SANDBOX/sl2-canary
mkdir -p "$SL2_CANARY"
printf 'CANARY MERGE UNCHANGED\n' > "$SL2_CANARY/merge-target"
printf 'CANARY ADD UNCHANGED\n'   > "$SL2_CANARY/add-target"
printf 'CANARY REN UNCHANGED\n'   > "$SL2_CANARY/ren-target"

SL2_COMP=$SANDBOX/sl2-comp
mkdir -p "$SL2_COMP" && cd "$SL2_COMP" && git init -q -b main
git -C "$SL2_SYNTH" show kairos-base:ren-src.txt > ren-src.txt   # the rename's real source
git add -A && git -c user.email=t@t -c user.name=t commit -qm sl2-comp-seed
# The component replaced each template-managed path with a symlink pointing OUT of
# the tree — the exact shape F12 addresses.
ln -s "$SL2_CANARY/merge-target" merge-me.txt
ln -s "$SL2_CANARY/add-target"   add-me.txt
ln -s "$SL2_CANARY/ren-target"   ren-dst.txt

SL2_RUN=$SANDBOX/sl2-run; mkdir -p "$SL2_RUN"
# Hand-stamp the tree binding (build-manifest's job) so structural-merge accepts
# the crafted classification, exactly as the pre-scan test does.
printf 'base\t%s\ntarget\t%s\n' \
  "$(git -C "$SL2_SYNTH" rev-parse kairos-base^{tree})" \
  "$(git -C "$SL2_SYNTH" rev-parse kairos-target^{tree})" \
  > "$SL2_RUN/classification-trees.tsv"
printf '%s\n' \
  $'added-mechanical\tA\tadd-me.txt\tadd-me.txt\t\t\t' \
  $'merge-pipeline\tM\tmerge-me.txt\tmerge-me.txt\t\t\t' \
  $'renamed-mechanical\tR100\tren-dst.txt\tren-dst.txt\tren-src.txt\t\t' \
  > "$SL2_RUN/classification.tsv"

SYNTH=$SL2_SYNTH BASE=$SL2_BASE TARGET=$SL2_TARGET RUN=$SL2_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/sl2-merge.log"
expect "the merge exits 0 (routing a symlink dest is a conflict, not a run failure)" test $? -eq 0
expect "the run still reports completion" grep -q 'OK: structural merge done' "$SANDBOX/sl2-merge.log"

# The three destinations are STILL the component's symlinks.
expect "the added destination is still the component's symlink"  test -L add-me.txt
expect "the merge destination is still the component's symlink"  test -L merge-me.txt
expect "the rename destination is still the component's symlink" test -L ren-dst.txt
# Nothing was written THROUGH any link — the out-of-tree canaries are untouched.
expect "the add link target was not overwritten" \
  grep -qx 'CANARY ADD UNCHANGED' "$SL2_CANARY/add-target"
expect "the merge link target was not overwritten" \
  grep -qx 'CANARY MERGE UNCHANGED' "$SL2_CANARY/merge-target"
expect "the rename link target was not overwritten" \
  grep -qx 'CANARY REN UNCHANGED' "$SL2_CANARY/ren-target"
# The rename's real source survives — its removal sits behind the skipped write.
expect "the rename source is left in place (its removal was skipped with the write)" test -f ren-src.txt

# All three are routed to the conflicts list (the user checkpoint) ...
expect "the added dest is routed to conflicts"  grep -qxF add-me.txt   "$SL2_RUN/conflicts.txt"
expect "the merge dest is routed to conflicts"  grep -qxF merge-me.txt "$SL2_RUN/conflicts.txt"
expect "the rename dest is routed to conflicts" grep -qxF ren-dst.txt  "$SL2_RUN/conflicts.txt"
# ... and NOT recorded as if the mechanical action had happened.
refute "the routed add is not recorded as a completed add"     grep -qxF add-me.txt   "$SL2_RUN/added.txt"
refute "the routed merge is not recorded as cleanly merged"    grep -qxF merge-me.txt "$SL2_RUN/clean-merged.txt"
refute "the routed rename is not recorded as a completed move" grep -q 'ren-dst.txt'  "$SL2_RUN/renamed.txt"
# The diagnostic names the shape so the operator knows why it is a checkpoint.
expect "the routing diagnostic names the symlink reason" \
  grep -qi 'symlink' "$SANDBOX/sl2-merge.log"

cd "$COMP"
fi

if t "structural-merge.sh — an empty-old-path renamed-mechanical row is refused, never a silent unrecorded write"; then
# Finding 9, at the enactment seam it protects, and as the ONLY row so a refusal is
# unambiguous. renamed-mechanical ALWAYS writes the target blob (write_theirs), but the
# rm of the old copy and the renamed.txt record both sit behind `if [ -n "$old_tpath" ]`.
# Pre-fix, a row with an empty old-path column but a valid template path cleared the
# pre-scan and enacted: the blob landed at the new path and the move was recorded in
# NEITHER renamed.txt nor added.txt — invisible to abort's debris classifier and to
# post-mortem. Reuses PS_SYNTH's tags (added-ok.txt is a real target blob, so
# theirs_problem passes and only the empty column 5 can stop the row).
EOP_COMP=$SANDBOX/eop-comp
mkdir -p "$EOP_COMP" && cd "$EOP_COMP" && git init -q -b main
printf 'placeholder\n' > placeholder.txt && git add -A && git commit -qm eop-comp
EOP_RUN=$SANDBOX/eop-run; mkdir -p "$EOP_RUN"
# A valid tree binding to PS_SYNTH, so the merge reaches the pre-scan rather than
# refusing on a stale/absent binding first.
printf 'base\t%s\ntarget\t%s\n' \
  "$(git -C "$PS_SYNTH" rev-parse kairos-base^{tree})" \
  "$(git -C "$PS_SYNTH" rev-parse kairos-target^{tree})" > "$EOP_RUN/classification-trees.tsv"
printf 'renamed-mechanical\tR100\tadded-ok.txt\tadded-ok.txt\t\t\t\n' > "$EOP_RUN/classification.tsv"
SYNTH=$PS_SYNTH BASE=$PS_BASE TARGET=$PS_TARGET RUN=$EOP_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/eop.log"; EOP_RC=$?
expect "empty-old-path rename: the merge refuses (exit non-zero)" test "$EOP_RC" -ne 0
refute "empty-old-path rename: it did not report success" \
  grep -q 'OK: structural merge done' "$SANDBOX/eop.log"
refute "empty-old-path rename: the target blob was NOT written to the tree (no silent write)" \
  test -e "$EOP_COMP/added-ok.txt"
refute "empty-old-path rename: nothing was recorded in renamed.txt" \
  bash -c "grep -q . '$EOP_RUN/renamed.txt' 2>/dev/null"
refute "empty-old-path rename: nothing was recorded in added.txt either" \
  bash -c "grep -q . '$EOP_RUN/added.txt' 2>/dev/null"
expect "empty-old-path rename: the refusal names the missing old-path column" \
  bash -c "grep -F 'renamed-mechanical' '$SANDBOX/eop.log' | grep -qi 'old path'"
cd "$COMP"
fi

if t "structural-merge.sh — an empty-destination deleted-by-template-mechanical row is refused by the pre-scan, not diagnosed mid-enactment"; then
# The one enacted bucket the pre-scan used to skip entirely. Its enactment reads
# ONLY column 4 (rm -f -- "$dest") and never probes the target tree — the template
# DELETED the path, so theirs_problem cannot vet it — but an empty column 4 makes
# that `rm -f -- ./`, which fails MID-loop: write_failed then reports it as a
# disk/permissions fault behind a half-migrated tree, when it is a stale or
# hand-edited row. The pre-scan now vets the one input the enactment reads, so the
# run refuses BEFORE anything is removed. As the only row, so the refusal is
# unambiguous. Reuses PS_SYNTH's tags with a valid tree binding.
DBD_COMP=$SANDBOX/dbd-comp
mkdir -p "$DBD_COMP" && cd "$DBD_COMP" && git init -q -b main
printf 'placeholder\n' > placeholder.txt && git add -A && git commit -qm dbd-comp
DBD_RUN=$SANDBOX/dbd-run; mkdir -p "$DBD_RUN"
printf 'base\t%s\ntarget\t%s\n' \
  "$(git -C "$PS_SYNTH" rev-parse kairos-base^{tree})" \
  "$(git -C "$PS_SYNTH" rev-parse kairos-target^{tree})" > "$DBD_RUN/classification-trees.tsv"
# tpath present (gone.txt); DESTINATION column (4) EMPTY — the enactment's one input.
printf 'deleted-by-template-mechanical\tD\tgone.txt\t\t\t\t\n' > "$DBD_RUN/classification.tsv"
SYNTH=$PS_SYNTH BASE=$PS_BASE TARGET=$PS_TARGET RUN=$DBD_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/dbd.log"; DBD_RC=$?
expect "empty-dest deleted row: the merge refuses (exit non-zero)" test "$DBD_RC" -ne 0
refute "empty-dest deleted row: it did not report success" \
  grep -q 'OK: structural merge done' "$SANDBOX/dbd.log"
expect "empty-dest deleted row: it is caught by the PRE-SCAN (nothing removed), not mid-enactment" \
  grep -qF 'Nothing was written, removed or recorded' "$SANDBOX/dbd.log"
refute "empty-dest deleted row: it did NOT fall through to the mid-enactment write_failed diagnosis" \
  grep -qF 'This fired mid-enactment' "$SANDBOX/dbd.log"
expect "empty-dest deleted row: the refusal names the missing destination column" \
  bash -c "grep -F 'deleted-by-template-mechanical' '$SANDBOX/dbd.log' | grep -qi 'destination'"
cd "$COMP"
fi

if t "structural-merge.sh"; then
PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" 2> "$SANDBOX/sm.log"
expect "structural-merge.sh exits 0" test $? -eq 0
# The stamp matches the trees this merge just read, so the binding check is a
# no-op here and every assertion below is unchanged from before it existed.
refute "a matching tree binding produces no refusal noise" \
  grep -qi 'classification' "$SANDBOX/sm.log"

expect "kept.txt recorded as conflict"     grep -qxF kept.txt "$RUN/conflicts.txt"
expect "kept.txt has diff3 markers"        grep -qE '^<{7} ' kept.txt
expect "kept.txt keeps ours side"          grep -q 'customized locally' kept.txt
expect "kept.txt carries theirs side"      grep -q 'from template' kept.txt
expect "clean.txt merged clean"            grep -qxF clean.txt "$RUN/clean-merged.txt"
expect "clean.txt got template change"     grep -q 'gamma-improved' clean.txt
expect "config merged clean at subst path" grep -qxF mycomp/config.txt "$RUN/clean-merged.txt"
expect "config new line substituted"       grep -q 'extra: mycomp-setting' mycomp/config.txt
expect "newfile.txt added, substituted"    grep -q 'hello mycomp' newfile.txt
expect "heavyweight bigdir NOT created"    test ! -e bigdir
expect "heavyweight cmd/worker NOT created (awaits user)" test ! -e cmd/worker
expect "existing cmd/ runtime untouched"   test -f cmd/existing/main.go
expect "template-deleted file removed"     test ! -e gone-unmodified.txt
expect "customized deletion left alone"    test -f gone-customized.txt
expect "locally-deleted file not resurrected" test ! -e modified-but-locally-deleted.txt
expect "pure rename landed"                test -f rename-dst.txt
expect "pure rename old path removed"      test ! -e rename-src.txt
expect "customized rename merged at new path" grep -q 'my custom line' rename-custom-dst.txt
expect "customized rename old path removed"   test ! -e rename-custom-src.txt
expect "rename-with-mods untouched (for-AI)"  test ! -e rename-mods-dst.txt
expect "component-move left for AI (not auto-merged)" \
  bash -c "! grep -qxF relocated/moved-dst.txt '$RUN/clean-merged.txt'"
expect "component-move relocated file NOT auto-changed" \
  bash -c "test -f relocated/moved-dst.txt && ! grep -q 'moved line ten CHANGED' relocated/moved-dst.txt"
expect "component-move NOT resurrected at template path" test ! -e moved-src.txt
expect "binary untouched"                  cmp -s logo.bin "$SANDBOX/logo.bin.orig"
expect "no merge errors"                   test ! -s "$RUN/merge-errors.txt"

fi

if t "heavyweight deletions are NOT applied mechanically"; then
expect "wholesale-deleted subtree still present for the user to decide" test -f legacy/x.txt
refute "heavyweight deletion not recorded as a mechanical delete" \
  grep -qxF legacy/x.txt "$RUN/deleted.txt"

fi

if t "line-ending-proof merge"; then
# The single largest source of false conflict volume in the first production
# migration. Content-identical-but-CRLF must merge CLEANLY.
expect "CRLF-vs-LF file merged CLEAN (not a whole-file conflict)" \
  grep -qxF crlf.txt "$RUN/clean-merged.txt"
refute "CRLF file is not in conflicts" grep -qxF crlf.txt "$RUN/conflicts.txt"
expect "CRLF file received the template's change" grep -q 'IMPROVED' crlf.txt
expect "normalization is declared, not silent" grep -qxF crlf.txt "$RUN/normalized-ours.txt"
# test -f first: a refute over a relative file operand passes vacuously if the
# file is absent (grep exits non-zero for "no such file" exactly as for "no
# match"), so the merged output vanishing entirely would read as "no CR bytes".
# Assert the file EXISTS and carries no CR.
expect "merged output carries no CR bytes" \
  bash -c "test -f crlf.txt && ! LC_ALL=C grep -q \$'\r' crlf.txt"

fi

if t "module-path correction makes the merged import compile"; then
expect "importer.go merged clean (no phantom module-path conflict)" \
  grep -qxF importer.go "$RUN/clean-merged.txt"
expect "merged importer.go keeps the COMPONENT's module path" \
  grep -q 'example.com/custom/mycomp/pkg/foo' importer.go
refute "merged importer.go does not import the template's module" \
  grep -q 'kairos-component-template' importer.go
expect "merged importer.go took the template's change" grep -q 'var keep = 2' importer.go

fi

if t "re-paired rename merged at the new path with a real base"; then
expect "re-paired rename landed at the new path" test -f newpkg/big.go
expect "re-paired rename removed the old path"   test ! -e oldpkg/big.go
expect "re-paired rename went through the merge pipeline" \
  bash -c "grep -qxF newpkg/big.go '$RUN/conflicts.txt' || grep -qxF newpkg/big.go '$RUN/clean-merged.txt'"

fi

if t "structural-merge.sh refuses to re-run over live conflict markers"; then
# kept.txt above is still conflicted in the working tree. A second invocation
# would feed the marked content back in as "ours" and nest markers — the guard
# must refuse BEFORE truncating any $RUN list or touching the tree.
# Seed resolver artifacts as if a previous attempt had resolved conflicts: a
# REFUSED re-run must leave them intact (the operator still needs them), while
# a legitimate redo (tested below) must clear them.
printf 'kept.txt\tours\tstale verdict from a previous attempt\n' > "$RUN/resolutions.tsv"
printf 'kept.txt\tours\tstale batch verdict\n' > "$RUN/resolutions.batch1.tsv"
SM_MARKS_BEFORE=$(grep -c '^<<<<<<< ' kept.txt || true)
PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" > /dev/null 2> "$SANDBOX/sm-rerun.log"
SM_RERUN_RC=$?
if [[ "$SM_RERUN_RC" -ne 0 ]]; then
  pass "re-run over live markers is refused (non-zero exit)"
else
  fail "re-run over live markers exited 0"
fi
expect "refusal names the marked file" grep -q 'kept.txt' "$SANDBOX/sm-rerun.log"
expect "refusal states the restore procedure" grep -q 'git checkout -- \.' "$SANDBOX/sm-rerun.log"
expect "refused re-run leaves the previous conflicts.txt intact (not truncated)" \
  grep -qxF kept.txt "$RUN/conflicts.txt"
SM_MARKS_AFTER=$(grep -c '^<<<<<<< ' kept.txt || true)
if [[ "$SM_MARKS_AFTER" = "$SM_MARKS_BEFORE" ]]; then
  pass "the refused re-run nested no markers (count unchanged)"
else
  fail "marker count changed on the refused re-run ($SM_MARKS_BEFORE -> $SM_MARKS_AFTER)"
fi
expect "the refused re-run leaves resolutions.tsv intact" \
  grep -qF 'stale verdict from a previous attempt' "$RUN/resolutions.tsv"
expect "the refused re-run leaves resolutions.<slug>.tsv intact" \
  test -f "$RUN/resolutions.batch1.tsv"

# The guard only sees files conflicts.txt lists, so the row has to be recorded
# BEFORE the marked content lands — a kill between the two would otherwise hide
# a marked file from the next run's guard and nest markers inside markers. A kill
# is not reproducible at runtime, so the ordering is asserted on the source.
SM_SRC=$SKILL_DIR/scripts/structural-merge.sh
SM_ROW_LN=$(grep -n '>> "$RUN/conflicts.txt"' "$SM_SRC" | head -1 | cut -d: -f1)
# Matched on the operand pair, not the whole command: the destination is written
# through its ANCHORED spelling (see the leading-dash block above), so the
# operands are what stays stable across the `--` and `./` guards around them.
SM_CP_LN=$(grep -n '"\$ours_blob" "\$a_dest"' "$SM_SRC" | head -1 | cut -d: -f1)
if [[ -n "$SM_ROW_LN" ]] && [[ -n "$SM_CP_LN" ]] && [[ "$SM_ROW_LN" -lt "$SM_CP_LN" ]]; then
  pass "the conflict row is recorded before the marked file is written"
else
  fail "conflicts.txt row (line ${SM_ROW_LN:-<none>}) is not recorded before the marker write (line ${SM_CP_LN:-<none>})"
fi

fi

if t "a legitimate redo clears the previous attempt's resolver verdicts"; then
# Follow the guard's own restore procedure, then redo the merge: resolutions
# describe conflict hunks in a tree that no longer exists, so a redone merge
# must never inherit them — a stale 'ours' verdict would ride into planning as
# if this run's resolver had produced it.
git checkout -- . && git clean -fd >/dev/null 2>&1
PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" > /dev/null 2> "$SANDBOX/sm-redo.log"
expect "the restored tree re-merges cleanly (exit 0)" test $? -eq 0
refute "stale resolutions.tsv is cleared on a legitimate redo" test -e "$RUN/resolutions.tsv"
refute "stale resolutions.<slug>.tsv is cleared on a legitimate redo" test -e "$RUN/resolutions.batch1.tsv"
expect "the redo regenerated this run's conflicts (kept.txt conflicted again)" \
  grep -qxF kept.txt "$RUN/conflicts.txt"

# =============================================================================
fi

if t "a failed write in the merge path is a loud stop, never a silent record"; then
# structural-merge.sh runs under `set -u` without `-e`, so every unchecked write
# was a no-op the next line could not see. The merge path had five of them, and
# they compounded: a failed `cp` of the merged blob to the destination was
# followed unconditionally by the `rm` of the rename's OLD path (both copies of
# the file gone) and by the clean-merged.txt row (the loss reported as a green
# merge). A failed conflicts.txt append was the same defect aimed at the re-run
# guard, whose ONLY input that list is: the marked content landed anyway, the
# guard could not see the file, and the next Phase 5 read the markers back in as
# "ours" and nested them. And a failed stage of the ours side left the PREVIOUS
# run's blob at $RUN/ours/<dest> (those dirs are never cleared), which then merged
# as "ours" and was copied over the component's current file.
#
# Own fixture, own $RUN, and the destination of the rename row lives inside a
# directory the test makes read-only: chmod is the portable EACCES seam (macOS has
# no tmpfs to fill). One row conflicts and lands BEFORE the failing row, so the
# mid-loop abort can be checked for guard soundness rather than just for exit 1.
if [[ "$(id -u)" -eq 0 ]]; then
  # Root bypasses DAC, so neither chmod a-w nor chmod a-r can deny the write and
  # every assertion below would test nothing. Same skip-pass posture as the
  # unwritable-destination block above.
  pass "merge-path write-failure cases skipped (running as root, chmod denies nothing)"
else
WF_SYNTH=$SANDBOX/writefail-synth
mkdir -p "$WF_SYNTH" && git -C "$WF_SYNTH" init -q -b main
seq 1 8 | sed 's/^/ren line /' > "$WF_SYNTH/wf-ren-src.txt"
seq 1 8 | sed 's/^/cf line /'  > "$WF_SYNTH/wf-conflict.txt"
mkdir -p "$WF_SYNTH/locked" && printf 'keep\n' > "$WF_SYNTH/locked/keep.txt"
git -C "$WF_SYNTH" add -A && git -C "$WF_SYNTH" commit -qm wf-base
git -C "$WF_SYNTH" tag -f kairos-base >/dev/null
WF_BASE=$(git -C "$WF_SYNTH" rev-parse HEAD)
# TARGET: the rename lands INSIDE locked/ (that is the directory the test seals),
# and each side edits a different line so the rename row merges CLEAN — which is
# what makes the pre-fix clean-merged.txt row a lie rather than a near-miss.
git -C "$WF_SYNTH" mv wf-ren-src.txt locked/wf-ren-dst.txt
sed 's/^ren line 2$/ren line two FROM TEMPLATE/' "$WF_SYNTH/locked/wf-ren-dst.txt" \
  > "$WF_SYNTH/wf.new" && mv "$WF_SYNTH/wf.new" "$WF_SYNTH/locked/wf-ren-dst.txt"
sed 's/^cf line 4$/cf line four FROM TEMPLATE/' "$WF_SYNTH/wf-conflict.txt" \
  > "$WF_SYNTH/wf.new" && mv "$WF_SYNTH/wf.new" "$WF_SYNTH/wf-conflict.txt"
git -C "$WF_SYNTH" add -A && git -C "$WF_SYNTH" commit -qm wf-target
git -C "$WF_SYNTH" tag -f kairos-target >/dev/null
WF_TARGET=$(git -C "$WF_SYNTH" rev-parse HEAD)

WF_COMP=$SANDBOX/writefail-comp
mkdir -p "$WF_COMP" && cd "$WF_COMP" && git init -q -b main
git -C "$WF_SYNTH" show "kairos-base:wf-ren-src.txt" \
  | sed 's/^ren line 7$/ren line seven MINE/' > wf-ren-src.txt
git -C "$WF_SYNTH" show "kairos-base:wf-conflict.txt" \
  | sed 's/^cf line 4$/cf line four MINE/' > wf-conflict.txt
mkdir -p locked && git -C "$WF_SYNTH" show "kairos-base:locked/keep.txt" > locked/keep.txt
git add -A && git commit -qm wf-comp
cp wf-ren-src.txt  "$SANDBOX/wf-ren-src.orig"
cp wf-conflict.txt "$SANDBOX/wf-conflict.orig"
WF_RUN=$SANDBOX/writefail-run; mkdir -p "$WF_RUN"

wf_merge() { # wf_merge <log-name>
  SYNTH=$WF_SYNTH BASE=$WF_BASE TARGET=$WF_TARGET RUN=$WF_RUN \
    PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
    > /dev/null 2> "$SANDBOX/$1"
}
# Anchored with -C on the fixture path, never on the cwd: a whole-tree
# checkout/clean must be impossible to aim anywhere else (as st_restore above).
wf_restore() {
  git -C "$WF_COMP" checkout -- . >/dev/null 2>&1
  git -C "$WF_COMP" clean -fdq >/dev/null 2>&1
}
WF_ROWS=$(printf '%s\n' \
  $'merge-pipeline\tM\twf-conflict.txt\twf-conflict.txt\t\t\t' \
  $'merge-pipeline\tR089\tlocked/wf-ren-dst.txt\tlocked/wf-ren-dst.txt\twf-ren-src.txt\t\t')

SYNTH=$WF_SYNTH CACHE=$WF_SYNTH BASE=$WF_BASE TARGET=$WF_TARGET RUN=$WF_RUN \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/wf-bm.log"
expect "the write-failure fixture classifies (valid tree binding)" test $? -eq 0

# --- control: every write can land, so the checks cost the happy path nothing ---
printf '%s\n' "$WF_ROWS" > "$WF_RUN/classification.tsv"
wf_merge wf-green.log
expect "the fixture merges when every write can land" test $? -eq 0
expect "the control run recorded the conflict"        grep -qxF wf-conflict.txt "$WF_RUN/conflicts.txt"
expect "the control run merged the rename clean at its new path" \
  grep -qxF locked/wf-ren-dst.txt "$WF_RUN/clean-merged.txt"
expect "the control rename landed"                    test -f locked/wf-ren-dst.txt
refute "the control rename removed the old path"      test -e wf-ren-src.txt

# --- (a) the destination write fails: the old copy must survive, and the row
# must not claim a merge that never landed ---------------------------------------
wf_restore
printf '%s\n' "$WF_ROWS" > "$WF_RUN/classification.tsv"
chmod a-w locked
wf_merge wf-lockdest.log
WF_RC=$?
chmod u+w locked          # restore before any assertion can leave it sealed
if [[ "$WF_RC" -ne 0 ]]; then
  pass "a failed destination write exits non-zero (exit $WF_RC)"
else
  fail "a failed destination write exited 0"
fi
expect "the failure names the file it could not write" \
  grep -qF 'locked/wf-ren-dst.txt' "$SANDBOX/wf-lockdest.log"
expect "the failure says the pre-rename copy was NOT removed" \
  bash -c "grep -F 'wf-ren-src.txt' '$SANDBOX/wf-lockdest.log' | grep -q 'NOT removed'"
expect "the failure states the tree is half-migrated" \
  grep -qi 'half-migrated' "$SANDBOX/wf-lockdest.log"
expect "the failure states the restore procedure" \
  grep -q 'git checkout -- \.' "$SANDBOX/wf-lockdest.log"
# The bug, three ways: the old path deleted, the new path absent, the row written.
expect "a failed destination write leaves the pre-rename copy in place" test -f wf-ren-src.txt
expect "the pre-rename copy is byte-identical (it is the only copy of the content)" \
  cmp -s wf-ren-src.txt "$SANDBOX/wf-ren-src.orig"
refute "nothing landed at the rename destination"     test -e locked/wf-ren-dst.txt
refute "a file that was never written is not recorded as cleanly merged" \
  grep -qxF locked/wf-ren-dst.txt "$WF_RUN/clean-merged.txt"
refute "the failed run did not report success" \
  grep -q 'OK: structural merge done' "$SANDBOX/wf-lockdest.log"
# Guard soundness across the mid-loop abort: the row that DID land its markers is
# in conflicts.txt, so the next run can still see it. That is the whole reason the
# conflict row is written before the marked content and a failed row-write is a
# stop before it.
expect "the conflicted file merged before the abort carries markers" \
  grep -qE '^<{7} ' wf-conflict.txt
expect "conflicts.txt carries its row, so the re-run guard can see it" \
  grep -qxF wf-conflict.txt "$WF_RUN/conflicts.txt"
wf_merge wf-guard.log
if [[ $? -ne 0 ]]; then
  pass "the next run is refused over the marked file the abort left behind"
else
  fail "the next run was not refused over the marked file the abort left behind"
fi
expect "the guard's refusal names that file" grep -qF 'wf-conflict.txt' "$SANDBOX/wf-guard.log"

# --- (b) the conflicts.txt row cannot be written: stop BEFORE the markers land ---
# The append is the re-run guard's only input, so the order is not cosmetic. A
# `git` wrapper on PATH is the only seam between the 3-way merge and the row it
# appends (same shape as the kairos-lock wrapper in the materialize block above).
wf_restore
printf '%s\n' $'merge-pipeline\tM\twf-conflict.txt\twf-conflict.txt\t\t\t' \
  > "$WF_RUN/classification.tsv"
WF_GIT=$(command -v git)
mkdir -p "$SANDBOX/gitlock"
cat > "$SANDBOX/gitlock/git" <<WRAP
#!/usr/bin/env bash
# Real git, then: the instant a 3-way merge has run, \$LOCK_LIST becomes
# unwritable, so the row that follows it cannot be appended.
"$WF_GIT" "\$@"; rc=\$?
case " \$* " in *" merge-file "*) [ -z "\${LOCK_LIST:-}" ] || chmod a-w "\$LOCK_LIST" ;; esac
exit \$rc
WRAP
chmod +x "$SANDBOX/gitlock/git"
PATH="$SANDBOX/gitlock:$PATH" LOCK_LIST=$WF_RUN/conflicts.txt \
  SYNTH=$WF_SYNTH BASE=$WF_BASE TARGET=$WF_TARGET RUN=$WF_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/wf-rowfail.log"
WF_RC=$?
chmod u+w "$WF_RUN/conflicts.txt"
if [[ "$WF_RC" -ne 0 ]]; then
  pass "a conflict row that cannot be recorded exits non-zero (exit $WF_RC)"
else
  fail "a conflict row that cannot be recorded exited 0"
fi
expect "the failure names the list it could not append to" \
  grep -qF 'conflicts.txt' "$SANDBOX/wf-rowfail.log"
expect "the failure names the conflicted file" \
  grep -qF 'wf-conflict.txt' "$SANDBOX/wf-rowfail.log"
refute "NO markers landed in the tree for a row that could not be recorded" \
  grep -qE '^<{7} ' wf-conflict.txt
expect "the working-tree file is byte-identical (the guard has nothing to miss)" \
  cmp -s wf-conflict.txt "$SANDBOX/wf-conflict.orig"
refute "the row-failure run did not report success" \
  grep -q 'OK: structural merge done' "$SANDBOX/wf-rowfail.log"

# --- (c) the ours side cannot be staged: never merge a previous run's blob -------
# $RUN/ours is never cleared between runs, so the stale blob is seeded here to be
# exactly what a redo would find.
wf_restore
printf '%s\n' $'merge-pipeline\tM\twf-conflict.txt\twf-conflict.txt\t\t\t' \
  > "$WF_RUN/classification.tsv"
mkdir -p "$WF_RUN/ours"
printf 'STALE BLOB FROM A PREVIOUS RUN\n' > "$WF_RUN/ours/wf-conflict.txt"
chmod a-r wf-conflict.txt
wf_merge wf-oursfail.log
WF_RC=$?
chmod u+r wf-conflict.txt
if [[ "$WF_RC" -ne 0 ]]; then
  pass "an ours side that cannot be staged exits non-zero (exit $WF_RC)"
else
  fail "an ours side that cannot be staged exited 0"
fi
expect "the failure names the file it could not stage" \
  grep -qF 'wf-conflict.txt' "$SANDBOX/wf-oursfail.log"
refute "the previous run's staged blob was NOT merged into the working tree" \
  grep -qF 'STALE BLOB FROM A PREVIOUS RUN' wf-conflict.txt
expect "the component's file is byte-identical" \
  cmp -s wf-conflict.txt "$SANDBOX/wf-conflict.orig"
refute "nothing was recorded as cleanly merged" test -s "$WF_RUN/clean-merged.txt"
refute "nothing was recorded as conflicted"     test -s "$WF_RUN/conflicts.txt"
rm -f "$WF_RUN/ours/wf-conflict.txt"

# --- (d) an output list that cannot even be truncated is refused up front -------
# An unwritable list keeps the PREVIOUS attempt's rows and this run appends to
# them: clean-merged.txt would then claim files this pass never touched.
wf_restore
printf '%s\n' $'merge-pipeline\tM\twf-conflict.txt\twf-conflict.txt\t\t\t' \
  > "$WF_RUN/classification.tsv"
printf 'wf-stale-from-a-previous-attempt.txt\n' > "$WF_RUN/clean-merged.txt"
chmod a-w "$WF_RUN/clean-merged.txt"
wf_merge wf-truncfail.log
WF_RC=$?
chmod u+w "$WF_RUN/clean-merged.txt"
if [[ "$WF_RC" -ne 0 ]]; then
  pass "an output list that cannot be truncated exits non-zero (exit $WF_RC)"
else
  fail "an output list that cannot be truncated exited 0"
fi
expect "the refusal names the list" grep -qF 'clean-merged.txt' "$SANDBOX/wf-truncfail.log"
expect "the refusal says nothing was written to the tree" \
  grep -qi 'Nothing has been written' "$SANDBOX/wf-truncfail.log"
expect "the tree was not touched" cmp -s wf-conflict.txt "$SANDBOX/wf-conflict.orig"
expect "the previous attempt's stale row was not merged with this run's" \
  grep -qxF wf-stale-from-a-previous-attempt.txt "$WF_RUN/clean-merged.txt"
refute "the truncation refusal did not report success" \
  grep -q 'OK: structural merge done' "$SANDBOX/wf-truncfail.log"

cd "$COMP"
fi

# =============================================================================
fi

if t "a range with NO directory renames still classifies (empty-map guard)"; then
# The common case, and the one the pairing bug broke completely. Built as its own
# tiny template/component pair so the assertion can't be satisfied by the rename
# fixture above happening to populate the map file.
NR_TPL=$SANDBOX/norename-tpl
mkdir -p "$NR_TPL" && cd "$NR_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'alpha\nbeta\ngamma\n' > plain.txt
printf 'key: value\n' > conf.yaml
git add -A && git commit -qm "nr-base"
NR_BASE=$(git rev-parse HEAD)
printf 'alpha\nbeta-changed\ngamma\n' > plain.txt
printf 'key: value\nadded: yes\n' > conf.yaml
printf 'brand new\n' > fresh.txt
git add -A && git commit -qm "nr-target"
NR_TARGET=$(git rev-parse HEAD)

NR_COMP=$SANDBOX/norename-comp
mkdir -p "$NR_COMP/.kairos" && cd "$NR_COMP" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/norename-comp\n' > go.mod
git -C "$NR_TPL" show "$NR_BASE:plain.txt" > plain.txt
git -C "$NR_TPL" show "$NR_BASE:conf.yaml" > conf.yaml
cat > .kairos/manifest.yaml <<EOF
name: norename-comp
template:
  repo: file://$NR_TPL
  sha: $NR_BASE
  branch: main
EOF
git add -A && git commit -qm "nr-comp"

NR_RUN=$NR_COMP/.kairos/migration/state; mkdir -p "$NR_RUN"
RUN=$NR_RUN CACHE=$NR_TPL BASE=$NR_BASE TARGET=$NR_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > "$SANDBOX/nr-mat.out" 2>&1
expect "no-rename fixture materializes" test $? -eq 0

# The stamped-reuse path is a success path too: it must re-record the run
# context even when it skips the expensive CLI runs (a Continue session's
# compaction recovery reads context.env, not the stamp).
rm -f "$NR_RUN/context.env"
RUN=$NR_RUN CACHE=$NR_TPL BASE=$NR_BASE TARGET=$NR_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > "$SANDBOX/nr-mat2.out" 2> "$SANDBOX/nr-mat2.log"
expect "stamped re-run exits 0" test $? -eq 0
expect "stamped re-run reused the trees (no re-materialization)" \
  grep -q 'reusing materialized trees' "$SANDBOX/nr-mat2.log"
expect "the reuse path still records SYNTH/BASE/TARGET into context.env" \
  bash -c "grep -qx 'SYNTH=$NR_RUN/synthetic' '$NR_RUN/context.env' \
    && grep -qx 'BASE=$NR_BASE' '$NR_RUN/context.env' \
    && grep -qx 'TARGET=$NR_TARGET' '$NR_RUN/context.env'"
RUN=$NR_RUN CACHE=$NR_TPL BASE=$NR_BASE TARGET=$NR_TARGET SYNTH=$NR_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/nr-bm.log"
expect "no-rename fixture classifies without error" test $? -eq 0
expect "dir-rename map really is empty for this range" \
  bash -c "! test -s '$NR_RUN/dir-rename-maps.tsv'"
NRC=$(grep -c . "$NR_RUN/classification.tsv" || true)
if [[ "${NRC:-0}" -eq 3 ]]; then
  pass "all 3 changed files classified with an empty rename map"
else
  fail "classification has $NRC rows with an empty rename map (want 3)"
  cat "$SANDBOX/nr-bm.log"
fi
expect "the modified file routed to merge-pipeline" \
  bash -c "awk -F'\t' '\$4==\"plain.txt\"{print \$1}' '$NR_RUN/classification.tsv' | grep -qx merge-pipeline"

fi

if t "non-ASCII template paths classify unquoted (core.quotepath=off)"; then
# git C-quotes any path carrying a non-ASCII byte by default ("caf\303\251.txt"),
# and that quoted form travels through classification into every consumer as a
# path that exists nowhere. Kept as its own fixture so the assertion cannot be
# satisfied by an ASCII-only chain above.
UTF_NAME=$(printf 'caf\303\251.txt')
QP_TPL=$SANDBOX/quotepath-tpl
mkdir -p "$QP_TPL" && cd "$QP_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'un\ndeux\ntrois\n' > "$UTF_NAME"
git add -A && git commit -qm qp-base
QP_BASE=$(git rev-parse HEAD)
printf 'un\ndeux-change\ntrois\n' > "$UTF_NAME"
git add -A && git commit -qm qp-target
QP_TARGET=$(git rev-parse HEAD)

QP_COMP=$SANDBOX/quotepath-comp
mkdir -p "$QP_COMP/.kairos" && cd "$QP_COMP" && git init -q -b main
printf 'module example.com/custom/qpcomp\n' > go.mod
git -C "$QP_TPL" show "$QP_BASE:$UTF_NAME" > "$UTF_NAME"
cat > .kairos/manifest.yaml <<EOF
name: qpcomp
template:
  repo: file://$QP_TPL
  sha: $QP_BASE
  branch: main
EOF
git add -A && git commit -qm qp-comp

QP_RUN=$QP_COMP/.kairos/migration/state; mkdir -p "$QP_RUN"
RUN=$QP_RUN CACHE=$QP_TPL BASE=$QP_BASE TARGET=$QP_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/qp-mat.log"
expect "the non-ASCII fixture materializes" test $? -eq 0
RUN=$QP_RUN CACHE=$QP_TPL BASE=$QP_BASE TARGET=$QP_TARGET SYNTH=$QP_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/qp-bm.log"
expect "the non-ASCII fixture classifies" test $? -eq 0
expect "the raw diff carries the path unquoted" grep -qF "$UTF_NAME" "$QP_RUN/diff.raw.tsv"
refute "no C-quoted octal escape reaches the diff" grep -q '303' "$QP_RUN/diff.raw.tsv"
expect "the classified dest is the real path, not a quoted one" \
  bash -c "awk -F'\t' '\$1==\"merge-pipeline\"{print \$4}' '$QP_RUN/classification.tsv' | grep -qxF '$UTF_NAME'"
cd "$COMP"

fi

if t "one non-ASCII filename does not disable move or emptied-subtree detection"; then
# The diff already runs with core.quotepath=off (block above), but build-manifest
# lists files through TWO more git commands, and both spoke the quoted dialect:
#   * `ls-tree -r --name-only` feeds the baseline-blob loop. The quoted name made
#     `git show "<tag>:\"caf\303\251.go\""` fail, so the file's baseline blob became
#     the EMPTY blob — silently, since the loop swallows the failure — and every
#     component-side MOVE of a non-ASCII file was then unpaireable (0% similarity
#     against an empty base), so the planner got no move candidate to start from.
#   * `ls-files "$d"` decides whether a subtree was emptied WHOLESALE, by matching
#     against the (unquoted) deletion list. One quoted member never matched, the
#     subtree looked merely thinned, and the batched user checkpoint for a
#     wholesale deletion silently disappeared for the whole run.
UTF_MOVE=$(printf 'caf\303\251.txt')

# --- seam 1: the baseline blobs behind component-move detection ---------------
QM_TPL=$SANDBOX/quotemove-tpl
mkdir -p "$QM_TPL" && cd "$QM_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
seq 1 20 | sed 's/^/accented line /' > "$UTF_MOVE"
git add -A && git commit -qm qm-base
QM_BASE=$(git rev-parse HEAD)
sed 's/accented line 10/accented line ten CHANGED/' "$UTF_MOVE" > t && mv t "$UTF_MOVE"
git add -A && git commit -qm qm-target
QM_TARGET=$(git rev-parse HEAD)

QM_COMP=$SANDBOX/quotemove-comp
mkdir -p "$QM_COMP/.kairos" "$QM_COMP/docs" && cd "$QM_COMP" && git init -q -b main
printf 'module example.com/custom/qmcomp\n' > go.mod
git -C "$QM_TPL" show "$QM_BASE:$UTF_MOVE" > "docs/$UTF_MOVE"   # component MOVED it here
cat > .kairos/manifest.yaml <<EOF
name: qmcomp
template:
  repo: file://$QM_TPL
  sha: $QM_BASE
  branch: main
EOF
git add -A && git commit -qm qm-comp

QM_RUN=$QM_COMP/.kairos/migration/state; mkdir -p "$QM_RUN"
RUN=$QM_RUN CACHE=$QM_TPL BASE=$QM_BASE TARGET=$QM_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/qm-mat.log"
expect "the non-ASCII move fixture materializes" test $? -eq 0
RUN=$QM_RUN CACHE=$QM_TPL BASE=$QM_BASE TARGET=$QM_TARGET SYNTH=$QM_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/qm-bm.log"
expect "the non-ASCII move fixture classifies" test $? -eq 0
expect "a non-ASCII file's component-side move is detected" \
  bash -c "awk -F'\t' '\$1==\"$UTF_MOVE\"{print \$2}' '$QM_RUN/component-rename-map.tsv' | grep -qxF 'docs/$UTF_MOVE'"
expect "the move candidate reaches the classification row" \
  bash -c "awk -F'\t' '\$4==\"$UTF_MOVE\"{print \$6}' '$QM_RUN/classification.tsv' | grep -qxF 'docs/$UTF_MOVE'"

# --- seam 2: the wholesale-deletion checkpoint --------------------------------
QD_TPL=$SANDBOX/quotedel-tpl
mkdir -p "$QD_TPL/legacy" && cd "$QD_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'a\n' > legacy/a.txt; printf 'b\n' > legacy/b.txt; printf 'c\n' > "legacy/$UTF_MOVE"
printf 'keep\n' > keep.txt
git add -A && git commit -qm qd-base
QD_BASE=$(git rev-parse HEAD)
git rm -q legacy/a.txt legacy/b.txt "legacy/$UTF_MOVE"
printf 'keep changed\n' > keep.txt
git add -A && git commit -qm qd-target
QD_TARGET=$(git rev-parse HEAD)

QD_COMP=$SANDBOX/quotedel-comp
mkdir -p "$QD_COMP/.kairos" "$QD_COMP/legacy" && cd "$QD_COMP" && git init -q -b main
printf 'module example.com/custom/qdcomp\n' > go.mod
printf 'a\n' > legacy/a.txt; printf 'b\n' > legacy/b.txt; printf 'c\n' > "legacy/$UTF_MOVE"
printf 'keep\n' > keep.txt
cat > .kairos/manifest.yaml <<EOF
name: qdcomp
template:
  repo: file://$QD_TPL
  sha: $QD_BASE
  branch: main
EOF
git add -A && git commit -qm qd-comp

QD_RUN=$QD_COMP/.kairos/migration/state; mkdir -p "$QD_RUN"
RUN=$QD_RUN CACHE=$QD_TPL BASE=$QD_BASE TARGET=$QD_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/qd-mat.log"
expect "the non-ASCII deletion fixture materializes" test $? -eq 0
RUN=$QD_RUN CACHE=$QD_TPL BASE=$QD_BASE TARGET=$QD_TARGET SYNTH=$QD_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/qd-bm.log"
expect "the non-ASCII deletion fixture classifies" test $? -eq 0
expect "a subtree with a non-ASCII member is still seen as emptied wholesale" \
  grep -qx 'legacy' "$QD_RUN/deleted-heavyweight-dirs.txt"
expect "its non-ASCII member is re-bucketed to the user checkpoint" \
  bash -c "awk -F'\t' '\$4==\"legacy/$UTF_MOVE\"{print \$1}' '$QD_RUN/classification.tsv' | grep -qx deleted-heavyweight-ask-user"
expect "so are its ASCII siblings" \
  bash -c "awk -F'\t' '\$4==\"legacy/a.txt\"{print \$1}' '$QD_RUN/classification.tsv' | grep -qx deleted-heavyweight-ask-user"
cd "$COMP"

fi

# Path -> bucket assertions go through the ENVIRONMENT, never through an awk
# program built by string interpolation: these very filenames are what breaks a
# `bash -c "awk '\$4==\"$p\"'"` form (the quote closes the program, the
# backslash is eaten as an escape) — a test that cannot spell the path cannot
# check it.
bucket_at() { # bucket_at <tsv> <dest> <want-bucket>
  local got
  got=$(D="$2" awk -F'\t' '$4 == ENVIRON["D"] { print $1 }' "$1")
  if [[ "$got" = "$3" ]]; then pass "bucket of $2 is $3"
  else fail "bucket of $2 is ${got:-<none>} (want $3)"; fi
}

if t "shell-special filenames ride the classification as raw bytes, end to end"; then
# `core.quotepath=off` (the block above) governs bytes >= 0x80 ONLY. A path
# carrying a `"`, a `\` or any other <0x80 special is C-quoted regardless, so the
# QUOTED spelling used to travel through classification into structural-merge —
# whose pre-scan then refused the WHOLE run ("absent from the target tree … re-run
# Phase 3") over a file that exists perfectly well. Re-running Phase 3 reproduced
# the same rows, so the migration was unrecoverable behind a looping remedy.
QN='wei"rd.txt'          # a double quote: C-quoted by git at every listing site
QB='back\slash.txt'      # a backslash: same, and an awk -v landmine on top
QD='-dash.bin'           # leading dash: an unguarded grep operand (and binary)
QS_TPL=$SANDBOX/qspecial-tpl
mkdir -p "$QS_TPL" && cd "$QS_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'un\ndeux\ntrois\n' > "$QN"
printf 'alpha\nbeta\ngamma\n' > "$QB"
git add -A && git commit -qm qs-base
QS_BASE=$(git rev-parse HEAD)
printf 'un\ndeux-changed\ntrois\n' > "$QN"          # M, component has it → merge-pipeline
printf 'alpha\nbeta\ngamma\ndelta-added\n' > "$QB"  # M, absent locally → modify-delete
printf 'BIN\0DATA\n' > "$QD"                         # A + binary → binary-for-user
git add -A && git commit -qm qs-target
QS_TARGET=$(git rev-parse HEAD)

QS_COMP=$SANDBOX/qspecial-comp
mkdir -p "$QS_COMP/.kairos" && cd "$QS_COMP" && git init -q -b main
printf 'module example.com/custom/qscomp\n' > go.mod
git -C "$QS_TPL" show "$QS_BASE:$QN" > "$QN"        # unmodified copy of the base
cat > .kairos/manifest.yaml <<EOF
name: qscomp
template:
  repo: file://$QS_TPL
  sha: $QS_BASE
  branch: main
EOF
git add -A && git commit -qm qs-comp

QS_RUN=$QS_COMP/.kairos/migration/state; mkdir -p "$QS_RUN"
RUN=$QS_RUN CACHE=$QS_TPL BASE=$QS_BASE TARGET=$QS_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/qs-mat.log"
expect "the shell-special fixture materializes" test $? -eq 0
RUN=$QS_RUN CACHE=$QS_TPL BASE=$QS_BASE TARGET=$QS_TARGET SYNTH=$QS_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/qs-bm.log"
expect "the shell-special fixture classifies" test $? -eq 0
refute "no C-quoted spelling reaches the raw diff" grep -q '\\"' "$QS_RUN/diff.raw.tsv"
bucket_at "$QS_RUN/classification.tsv" "$QN" merge-pipeline
bucket_at "$QS_RUN/classification.tsv" "$QB" modify-delete-for-ai
# The leading-dash operand: `grep -qxF "$p1" binaries-template.txt` without `--`
# parses the path as options, so the binary probe silently answers "not binary"
# and a binary file is routed to the text merge path.
expect "the leading-dash binary is recorded as a template-side binary" \
  grep -qxF -- "$QD" "$QS_RUN/binaries-template.txt"
bucket_at "$QS_RUN/classification.tsv" "$QD" binary-for-user

cd "$QS_COMP"
BASE=$QS_BASE TARGET=$QS_TARGET SYNTH=$QS_RUN/synthetic RUN=$QS_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" 2> "$SANDBOX/qs-sm.log"
QS_SM_RC=$?
expect "the merge runs (a legal filename is never a refusal)" test "$QS_SM_RC" -eq 0
refute "the merge does not claim the path is absent from the target tree" \
  grep -q 'absent from the target tree' "$SANDBOX/qs-sm.log"
expect "the quote-bearing file merged clean" \
  grep -qxF "$QN" "$QS_RUN/clean-merged.txt"
expect "the quote-bearing file carries the template change" \
  grep -q 'deux-changed' "$QN"
cd "$COMP"

fi

if t "a leading-dash path is an OPERAND at every enactment site, not a bundle of options"; then
# The block above proved the leading dash out of the CLASSIFIER. This one proves
# it out of the ENACTMENT: structural-merge.sh hands component paths to rm, cp and
# dirname, and each of those read `-dash.txt` as options. Every failure was silent
# in a different way, and all four are recorded as done in the run's own lists —
# which is what makes them worth one fixture each rather than a source grep:
#   rm  (deleted-by-template) — rm errors, the file survives, deleted.txt says it
#                               went, and the run still exits 0.
#   rm  (rename's old path)   — both copies survive while renamed.txt records a move.
#   cp  (merge write-back)    — the merged content never lands, and the file is
#                               recorded in clean-merged.txt anyway.
#   dirname (write_theirs)    — `$d` comes back EMPTY, so a perfectly legal
#                               filename hard-stops the whole run on
#                               "could not create " with no path in the message.
# The re-run guard is the fifth: its grep errored into /dev/null, which reads as
# "no live markers", so the guard that exists to stop marker nesting waved the
# second run through.
LD_TPL=$SANDBOX/ldash-tpl
mkdir -p "$LD_TPL" && cd "$LD_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'delete me\n'                > '-doomed.txt'
printf 'renamed body\none\ntwo\n'   > '-rn-src.txt'
printf 'alpha\nbeta\ngamma\n'       > '-merged.txt'
printf 'one\ntwo\nthree\n'          > '-conflict.txt'
git add -A && git commit -qm ld-base
LD_BASE=$(git rev-parse HEAD)
rm -f -- '-doomed.txt'                            # D  → deleted-by-template-mechanical
mv -- '-rn-src.txt' '-rn-dst.txt'                 # R100 → renamed-mechanical
printf 'alpha\nbeta\ngamma-improved\n'  > '-merged.txt'    # M → merge-pipeline (clean)
printf 'one\ntwo-from-template\nthree\n' > '-conflict.txt' # M → merge-pipeline (conflict)
printf 'brand new\n'                > '-added.txt'         # A → added-mechanical
git add -A && git commit -qm ld-target
LD_TARGET=$(git rev-parse HEAD)

LD_COMP=$SANDBOX/ldash-comp
mkdir -p "$LD_COMP/.kairos" && cd "$LD_COMP" && git init -q -b main
printf 'module example.com/custom/ldcomp\n' > go.mod
git -C "$LD_TPL" show "$LD_BASE:-doomed.txt"  > '-doomed.txt'   # untouched → mechanical delete
git -C "$LD_TPL" show "$LD_BASE:-rn-src.txt"  > '-rn-src.txt'   # untouched → mechanical rename
printf 'alpha-local\nbeta\ngamma\n'      > '-merged.txt'        # edits a different line
printf 'one\ntwo-from-component\nthree\n' > '-conflict.txt'     # edits the SAME line
cat > .kairos/manifest.yaml <<EOF
name: ldcomp
template:
  repo: file://$LD_TPL
  sha: $LD_BASE
  branch: main
EOF
git add -A && git commit -qm ld-comp

LD_RUN=$LD_COMP/.kairos/migration/state; mkdir -p "$LD_RUN"
RUN=$LD_RUN CACHE=$LD_TPL BASE=$LD_BASE TARGET=$LD_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/ld-mat.log"
expect "the leading-dash fixture materializes" test $? -eq 0
RUN=$LD_RUN CACHE=$LD_TPL BASE=$LD_BASE TARGET=$LD_TARGET SYNTH=$LD_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/ld-bm.log"
expect "the leading-dash fixture classifies" test $? -eq 0
bucket_at "$LD_RUN/classification.tsv" '-doomed.txt'   deleted-by-template-mechanical
bucket_at "$LD_RUN/classification.tsv" '-rn-dst.txt'   renamed-mechanical
bucket_at "$LD_RUN/classification.tsv" '-added.txt'    added-mechanical
bucket_at "$LD_RUN/classification.tsv" '-merged.txt'   merge-pipeline
bucket_at "$LD_RUN/classification.tsv" '-conflict.txt' merge-pipeline

cd "$LD_COMP"
BASE=$LD_BASE TARGET=$LD_TARGET SYNTH=$LD_RUN/synthetic RUN=$LD_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" 2> "$SANDBOX/ld-sm.log"
expect "the leading-dash merge exits 0 (a legal filename is never a refusal)" test $? -eq 0

# (c) dirname in write_theirs — the loudest of the four, and the only one that
# stopped the run instead of quietly mis-reporting it.
refute "no row died on an empty destination path from dirname" \
  grep -q 'could not create ' "$SANDBOX/ld-sm.log"
expect "the added file landed at its leading-dash path" test -f '-added.txt'
expect "the added file carries the template's content" grep -q -- 'brand new' '-added.txt'

# (a) rm for deleted-by-template — deleted.txt must not be able to claim a
# deletion that did not happen.
refute "the template-deleted file is really gone" test -e '-doomed.txt'
expect "and the run recorded that deletion" grep -qxF -- '-doomed.txt' "$LD_RUN/deleted.txt"

# (b) rm for the rename's old path — the failure left BOTH copies on disk while
# renamed.txt recorded a move, so the component silently gained a duplicate.
expect "the rename landed at the new path" test -f '-rn-dst.txt'
refute "the rename's old path is really gone (no surviving duplicate)" test -e '-rn-src.txt'
expect "and the run recorded the rename" \
  grep -qxF -- '-rn-src.txt -> -rn-dst.txt' "$LD_RUN/renamed.txt"

# (d) cp write-back in merge_one — recorded clean-merged while the working-tree
# file still held the pre-merge content.
expect "the leading-dash merge-pipeline file merged clean" \
  grep -qxF -- '-merged.txt' "$LD_RUN/clean-merged.txt"
expect "and the merged content actually reached the working tree" \
  grep -q -- 'gamma-improved' '-merged.txt'
expect "the merge kept the component's own edit" grep -q -- 'alpha-local' '-merged.txt'

# The re-run guard: the conflicted file below is what arms it.
expect "the leading-dash conflict is recorded" \
  grep -qxF -- '-conflict.txt' "$LD_RUN/conflicts.txt"
expect "the conflicted file carries diff3 markers" grep -qE -- '^<{7} ' '-conflict.txt'
LD_MARKS_BEFORE=$(grep -c -- '^<<<<<<< ' '-conflict.txt' || true)
BASE=$LD_BASE TARGET=$LD_TARGET SYNTH=$LD_RUN/synthetic RUN=$LD_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" > /dev/null 2> "$SANDBOX/ld-rerun.log"
LD_RERUN_RC=$?
if [[ "$LD_RERUN_RC" -ne 0 ]]; then
  pass "the re-run guard sees a leading-dash conflicted file and refuses"
else
  fail "the re-run guard read the leading-dash path as options and let the re-run through (exit 0)"
fi
expect "the refusal names the leading-dash file" grep -qF -- '-conflict.txt' "$SANDBOX/ld-rerun.log"
LD_MARKS_AFTER=$(grep -c -- '^<<<<<<< ' '-conflict.txt' || true)
if [[ "$LD_MARKS_AFTER" = "$LD_MARKS_BEFORE" ]]; then
  pass "the refused re-run nested no markers (count unchanged)"
else
  fail "marker count changed on the refused re-run ($LD_MARKS_BEFORE -> $LD_MARKS_AFTER)"
fi
cd "$COMP"

fi

if t "a path that IS an echo option string is recorded, not swallowed"; then
# The block above proved the leading dash out of the COMMANDS (rm/cp/grep/dirname).
# This one proves it out of the RECORDS. `-n`, `-E`, `-ne`, `-en` and their kin are
# not merely leading-dash paths: they are exactly what bash's builtin `echo` reads as
# its OWN options, so `echo "$dest" >> list` appends an empty line — or, with `-n` in
# the set, nothing at all — and the path is absent from the run's own record of what
# it did. Every consumer of those lists then works from a tree it cannot see:
#   conflicts.txt      — no resolver is dispatched for the file, AND the re-run guard
#                        (which reads this list back) cannot see it, so a second
#                        Phase 5 reads the still-marked file in as "ours" and nests
#                        diff3 markers — the one corruption that guard exists to stop.
#   clean-merged.txt   — the merged file is invisible to the migration log.
#   added.txt / deleted.txt — the mechanical action goes unreported.
#   normalized-ours.txt — a whole-file CRLF->LF diff reaches the reviewer unannounced.
#   binaries.txt       — the ask-user hand-off for a binary silently disappears.
# (merge-errors.txt is the eighth writer and shares the fixed form; forcing
# `git merge-file` to exit >=128 takes no fixture this suite can build honestly.)
# The plain-named conflict beside `-n` is what makes the count assertion meaningful:
# the swallowed path shows up as "1 conflict" where the tree has two.
# Every name here is distinct case-INSENSITIVELY (`-E` appears, `-e` does not): the
# suite has to pass on a case-folding filesystem too, where `-e` and `-E` would be
# one file and the fixture would quietly stop testing what it claims to.
EO_TPL=$SANDBOX/echoopt-tpl
mkdir -p "$EO_TPL" && cd "$EO_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'one\ntwo\nthree\n'          > '-n'                  # → conflict
printf 'plain one\ntwo\nthree\n'    > 'plain-conflict.txt'  # → conflict (named normally)
printf 'alpha\nbeta\ngamma\n'       > '-E'                  # → clean merge
printf 'delete me\n'                > '-ne'                 # → deleted-by-template
printf 'crlf a\ncrlf b\ncrlf c\n'   > '-en'                 # → clean merge, ours is CRLF
printf 'bin base\n'                 > '-nne'                # → ours side is binary
git add -A && git commit -qm eo-base
EO_BASE=$(git rev-parse HEAD)
printf 'one\ntwo-from-template\nthree\n'       > '-n'
printf 'plain one\ntwo-from-template\nthree\n' > 'plain-conflict.txt'
printf 'alpha\nbeta\ngamma-improved\n'         > '-E'
rm -f -- '-ne'
printf 'crlf a\ncrlf b IMPROVED\ncrlf c\n'     > '-en'
printf 'bin target\n'                          > '-nne'
printf 'brand new\n'                           > '-nen'     # → added-mechanical
git add -A && git commit -qm eo-target
EO_TARGET=$(git rev-parse HEAD)

EO_COMP=$SANDBOX/echoopt-comp
mkdir -p "$EO_COMP/.kairos" && cd "$EO_COMP" && git init -q -b main
printf 'module example.com/custom/eocomp\n' > go.mod
printf 'one\ntwo-from-component\nthree\n'       > '-n'                 # same line → conflict
printf 'plain one\ntwo-from-component\nthree\n' > 'plain-conflict.txt' # same line → conflict
printf 'alpha-local\nbeta\ngamma\n'             > '-E'                 # other line → clean
git -C "$EO_TPL" show "$EO_BASE:-ne" > '-ne'                           # untouched → mechanical delete
printf 'crlf a\r\ncrlf b\r\ncrlf c\r\n'         > '-en'                # base content, CRLF
printf 'BIN\0DATA local\n'                      > '-nne'               # ours side binary
cat > .kairos/manifest.yaml <<EOF
name: eocomp
template:
  repo: file://$EO_TPL
  sha: $EO_BASE
  branch: main
EOF
git add -A && git commit -qm eo-comp

EO_RUN=$EO_COMP/.kairos/migration/state; mkdir -p "$EO_RUN"
RUN=$EO_RUN CACHE=$EO_TPL BASE=$EO_BASE TARGET=$EO_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/eo-mat.log"
expect "the echo-option fixture materializes" test $? -eq 0
RUN=$EO_RUN CACHE=$EO_TPL BASE=$EO_BASE TARGET=$EO_TARGET SYNTH=$EO_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/eo-bm.log"
expect "the echo-option fixture classifies" test $? -eq 0
bucket_at "$EO_RUN/classification.tsv" '-n'    merge-pipeline
bucket_at "$EO_RUN/classification.tsv" '-E'    merge-pipeline
bucket_at "$EO_RUN/classification.tsv" '-en'   merge-pipeline
bucket_at "$EO_RUN/classification.tsv" '-nne'  merge-pipeline
bucket_at "$EO_RUN/classification.tsv" '-ne'   deleted-by-template-mechanical
bucket_at "$EO_RUN/classification.tsv" '-nen'  added-mechanical

cd "$EO_COMP"
BASE=$EO_BASE TARGET=$EO_TARGET SYNTH=$EO_RUN/synthetic RUN=$EO_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" 2> "$SANDBOX/eo-sm.log"
expect "the echo-option merge exits 0 (a legal filename is never a refusal)" test $? -eq 0

expect "the conflict named '-n' is recorded in conflicts.txt" \
  grep -qxF -- '-n' "$EO_RUN/conflicts.txt"
EO_NCONF=$(grep -c . "$EO_RUN/conflicts.txt" || true)
if [[ "$EO_NCONF" = 2 ]]; then
  pass "conflicts.txt reports BOTH conflicts (a swallowed path reports one)"
else
  fail "conflicts.txt reports $EO_NCONF conflict(s), want 2 (-n and plain-conflict.txt)"
fi
expect "the clean merge named '-E' is recorded in clean-merged.txt" \
  grep -qxF -- '-E' "$EO_RUN/clean-merged.txt"
expect "the addition named '-nen' is recorded in added.txt" \
  grep -qxF -- '-nen' "$EO_RUN/added.txt"
expect "the deletion named '-ne' is recorded in deleted.txt" \
  grep -qxF -- '-ne' "$EO_RUN/deleted.txt"
expect "the CRLF rewrite of '-en' is recorded in normalized-ours.txt" \
  grep -qxF -- '-en' "$EO_RUN/normalized-ours.txt"
expect "the ours-side binary '-nne' is recorded in binaries.txt" \
  grep -qxF -- '-nne' "$EO_RUN/binaries.txt"

# The re-run guard reads conflicts.txt back, so a path missing from that list is a
# file the guard cannot protect: the second run reads the already-marked working-tree
# copy in as "ours" and nests markers inside markers. To make that the ONLY thing
# under test, plain-conflict.txt is resolved first (a resolver did its file, the
# operator redid Phase 5 before the rest were done — reference/continue.md's own
# scenario). Now the guard has nothing but `-n` to trip on: with the path recorded it
# refuses, and with the path swallowed it waves the run through and `-n` is corrupted.
expect "the conflicted '-n' carries diff3 markers" grep -qE -- '^<{7} ' '-n'
printf 'plain one\ntwo-resolved\nthree\n' > 'plain-conflict.txt'
refute "plain-conflict.txt is resolved, so only '-n' can arm the guard" \
  grep -qE -- '^<{7} ' 'plain-conflict.txt'
EO_MARKS_BEFORE=$(grep -c -- '^<<<<<<< ' '-n' || true)
BASE=$EO_BASE TARGET=$EO_TARGET SYNTH=$EO_RUN/synthetic RUN=$EO_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" > /dev/null 2> "$SANDBOX/eo-rerun.log"
EO_RERUN_RC=$?
if [[ "$EO_RERUN_RC" -ne 0 ]]; then
  pass "the re-run guard refuses while '-n' still carries markers"
else
  fail "the re-run guard could not see '-n' in conflicts.txt and let the re-run through (exit 0)"
fi
expect "the refusal names '-n' as a listed conflict" \
  grep -qF -- 'FAIL: -n (listed in' "$SANDBOX/eo-rerun.log"
EO_MARKS_AFTER=$(grep -c -- '^<<<<<<< ' '-n' || true)
if [[ "$EO_MARKS_AFTER" = "$EO_MARKS_BEFORE" ]]; then
  pass "no markers nested inside '-n' (count unchanged)"
else
  fail "diff3 markers NESTED in '-n' ($EO_MARKS_BEFORE -> $EO_MARKS_AFTER)"
fi
cd "$COMP"

fi

if t "a DIRECTORY that is an echo option string still reaches its user checkpoint"; then
# build-manifest.sh carries the same swallowed-record defect one level up, on
# DIRECTORY names: the heavyweight-ADDITION root list and the emptied-subtree chain
# (candidate dirs -> emptied dirs -> maximal dirs) are each built by echoing a path
# into a file. A directory named `-n` or `-en` is swallowed at every one of those
# hops, the `[ -s ]` guard downstream sees an empty list, and the rows keep their
# `*-mechanical` bucket — so the batched user checkpoint for "the template added a
# new subsystem" / "the template empties this subtree wholesale" silently does not
# happen. Both passes are asserted because the deletion chain has three echo hops
# and fixing fewer than all of them still loses the checkpoint.
#
# $SYNTH IS BUILT BY HAND HERE, not by materialize.sh, and that is a statement about
# a different script: materialize.sh's install loop takes `dirname` of an UNANCHORED
# relative path, so for any leading-dash DIRECTORY it gets an empty `$dir`, never
# creates the subdir, and hard-stops on "could not install -n/c.txt" — a site outside
# this block's subject and outside the two scripts it exercises. Cloning the template
# and tagging its two commits gives build-manifest.sh exactly what its contract asks
# for (a repo carrying kairos-base/kairos-target; this fixture holds no placeholders
# and no CRLF, so there is nothing for materialization to substitute or normalize).
EOD_TPL=$SANDBOX/echodir-tpl
mkdir -p "$EOD_TPL" && cd "$EOD_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
mkdir -p -- '-n'
for f in a b c; do printf 'legacy %s\n' "$f" > "-n/$f.txt"; done
git add -A && git commit -qm eod-base
EOD_BASE=$(git rev-parse HEAD)
git rm -q -- '-n/a.txt' '-n/b.txt' '-n/c.txt'                     # wholesale emptied subtree
mkdir -p -- '-en'
for f in p q r s; do printf 'new %s\n' "$f" > "-en/$f.txt"; done  # 4 files > 3 → heavyweight
git add -A && git commit -qm eod-target
EOD_TARGET=$(git rev-parse HEAD)

EOD_COMP=$SANDBOX/echodir-comp
mkdir -p "$EOD_COMP/.kairos" && cd "$EOD_COMP" && git init -q -b main
printf 'module example.com/custom/eodcomp\n' > go.mod
mkdir -p -- '-n'
for f in a b c; do git -C "$EOD_TPL" show "$EOD_BASE:-n/$f.txt" > "-n/$f.txt"; done
cat > .kairos/manifest.yaml <<EOF
name: eodcomp
template:
  repo: file://$EOD_TPL
  sha: $EOD_BASE
  branch: main
EOF
git add -A && git commit -qm eod-comp

EOD_SYNTH=$SANDBOX/echodir-synth
git clone -q "$EOD_TPL" "$EOD_SYNTH"
git -C "$EOD_SYNTH" tag kairos-base "$EOD_BASE"
git -C "$EOD_SYNTH" tag kairos-target "$EOD_TARGET"

EOD_RUN=$EOD_COMP/.kairos/migration/state; mkdir -p "$EOD_RUN"
cd "$EOD_COMP"
RUN=$EOD_RUN CACHE=$EOD_TPL BASE=$EOD_BASE TARGET=$EOD_TARGET SYNTH=$EOD_SYNTH \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/eod-bm.log"
expect "the echo-option-directory fixture classifies" test $? -eq 0

expect "the new subsystem root '-en' is listed in heavyweight-roots.txt" \
  grep -qxF -- '-en' "$EOD_RUN/heavyweight-roots.txt"
bucket_at "$EOD_RUN/classification.tsv" '-en/p.txt' added-heavyweight-ask-user
expect "the emptied subtree '-n' is listed in deleted-heavyweight-dirs.txt" \
  grep -qxF -- '-n' "$EOD_RUN/deleted-heavyweight-dirs.txt"
bucket_at "$EOD_RUN/classification.tsv" '-n/a.txt' deleted-heavyweight-ask-user
cd "$COMP"

fi

if t "a TAB-bearing filename is a named hard stop, not a re-run loop"; then
# classification.tsv and diff.tsv are TAB-delimited line records, so a path
# carrying a TAB (or a newline) cannot ride them at ALL — no quoting scheme makes
# it representable. The only remedy is renaming the file upstream, so the refusal
# has to say that: the previous behavior (quote it, then refuse in Phase 5 with
# "re-run Phase 3") sent the operator around a loop that reproduces itself.
TB_NAME=$(printf 'tab\tname.txt')
TB_TPL=$SANDBOX/tabname-tpl
mkdir -p "$TB_TPL" && cd "$TB_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'seed\n' > seed.txt
git add -A && git commit -qm tb-base
TB_BASE=$(git rev-parse HEAD)
printf 'tabbed\n' > "$TB_NAME"
printf 'seed changed\n' > seed.txt
git add -A && git commit -qm tb-target
TB_TARGET=$(git rev-parse HEAD)

TB_COMP=$SANDBOX/tabname-comp
mkdir -p "$TB_COMP/.kairos" && cd "$TB_COMP" && git init -q -b main
printf 'module example.com/custom/tbcomp\n' > go.mod
git -C "$TB_TPL" show "$TB_BASE:seed.txt" > seed.txt
cat > .kairos/manifest.yaml <<EOF
name: tbcomp
template:
  repo: file://$TB_TPL
  sha: $TB_BASE
  branch: main
EOF
git add -A && git commit -qm tb-comp

TB_RUN=$TB_COMP/.kairos/migration/state; mkdir -p "$TB_RUN"
RUN=$TB_RUN CACHE=$TB_TPL BASE=$TB_BASE TARGET=$TB_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/tb-mat.log"
expect "the TAB-name fixture materializes" test $? -eq 0
RUN=$TB_RUN CACHE=$TB_TPL BASE=$TB_BASE TARGET=$TB_TARGET SYNTH=$TB_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/tb-bm.log"
TB_RC=$?
if [[ "$TB_RC" -ne 0 ]]; then pass "classification refuses a TAB-bearing filename (exit $TB_RC)"; else fail "classification accepted a TAB-bearing filename (exit 0)"; fi
expect "the refusal names the offending file" \
  grep -q 'tab.*name.txt' "$SANDBOX/tb-bm.log"
expect "the refusal states the remedy that works: rename it upstream" \
  bash -c "grep -qi 'rename' '$SANDBOX/tb-bm.log'"
refute "the refusal does NOT send the operator back through this phase" \
  bash -c "grep -qi 're-run.*phase 3\|re-run this phase\|re-run classification' '$SANDBOX/tb-bm.log'"
refute "no classification is left behind for Phase 5 to merge from" \
  test -s "$TB_RUN/classification.tsv"
refute "and no tree binding either, so a Phase 5 run stops instead of merging nothing" \
  test -e "$TB_RUN/classification-trees.tsv"
cd "$COMP"

fi

if t "upgrade-file DISCOVERY collects quote- and backslash-bearing names"; then
# The diff walk went `-z` long ago; the upgrade-file discovery walks did not, and
# `core.quotepath=off` governs bytes >= 0x80 ONLY. So an upgrade-file named
# `we"ird.md` or `back\slash.md` still arrived C-quoted from `git log --name-only`
# ('".kairos-updates/we\"ird.md"'), failed the `^\.kairos-updates/` awk filter,
# and VANISHED: no row in upgrades-added.txt, no row in snapshot-refusals.tsv, no
# WARN, exit 0. A migration step the template SHIPS was silently skipped, which is
# strictly worse than any loud refusal. These are legal filenames, so the fix
# COLLECTS them rather than refusing them.
#
# All three discovery walks are exercised: the A pass (added in range), the M
# body-override pass (amended in range), and the M list pass (existed before BASE,
# amended in range -> upgrades-modified.txt).
UQ='20260301T000000-we"ird'      # a double quote
UB='20260302T000000-back\slash'  # a backslash — also an awk -v landmine
UP='20260101T000000-pre"amend'   # added BEFORE base, amended in range
UU_TPL=$SANDBOX/upgquote-tpl
mkdir -p "$UU_TPL/.kairos-updates" && cd "$UU_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'seed\n' > seed.txt
printf 'intent: pre-existing\nbody-preamend-v1\n' > ".kairos-updates/$UP.md"
git add -A && git commit -qm uu-base
UU_BASE=$(git rev-parse HEAD)
printf 'intent: quoted\nbody-weird-v1\n'   > ".kairos-updates/$UQ.md"
printf 'intent: slashed\nbody-backslash\n' > ".kairos-updates/$UB.md"
printf 'seed changed\n' > seed.txt
git add -A && git commit -qm uu-add
printf 'intent: quoted\nbody-weird-v2-amended\n'  > ".kairos-updates/$UQ.md"
printf 'intent: pre-existing\nbody-preamend-v2\n' > ".kairos-updates/$UP.md"
git add -A && git commit -qm uu-amend
UU_TARGET=$(git rev-parse HEAD)

UU_COMP=$SANDBOX/upgquote-comp
mkdir -p "$UU_COMP/.kairos" && cd "$UU_COMP" && git init -q -b main
printf 'module example.com/custom/uucomp\n' > go.mod
git -C "$UU_TPL" show "$UU_BASE:seed.txt" > seed.txt
cat > .kairos/manifest.yaml <<EOF
name: uucomp
template:
  repo: file://$UU_TPL
  sha: $UU_BASE
  branch: main
EOF
git add -A && git commit -qm uu-comp

UU_RUN=$UU_COMP/.kairos/migration/state; mkdir -p "$UU_RUN"
RUN=$UU_RUN CACHE=$UU_TPL BASE=$UU_BASE TARGET=$UU_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/uu-mat.log"
expect "the quoted-upgrade fixture materializes" test $? -eq 0
RUN=$UU_RUN CACHE=$UU_TPL BASE=$UU_BASE TARGET=$UU_TARGET SYNTH=$UU_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/uu-bm.log"
expect "the quoted-upgrade fixture classifies" test $? -eq 0

expect "the quote-named upgrade-file is discovered, under its RAW name" \
  grep -qxF -- ".kairos-updates/$UQ.md" "$UU_RUN/upgrades-added.txt"
expect "the backslash-named upgrade-file is discovered, under its RAW name" \
  grep -qxF -- ".kairos-updates/$UB.md" "$UU_RUN/upgrades-added.txt"
refute "no C-quoted spelling reaches the added list" \
  grep -q '\\"' "$UU_RUN/upgrades-added.txt"
expect "the quote-named file carries an add-sha in upgrades-added.tsv" \
  bash -c "P='.kairos-updates/$UQ.md' awk -F'\t' '\$2==ENVIRON[\"P\"] && \$1 ~ /^[0-9a-f]{40}$/' '$UU_RUN/upgrades-added.tsv' | grep -q ."
expect "the backslash-named file carries an add-sha in upgrades-added.tsv" \
  bash -c "P='.kairos-updates/$UB.md' awk -F'\t' '\$2==ENVIRON[\"P\"] && \$1 ~ /^[0-9a-f]{40}$/' '$UU_RUN/upgrades-added.tsv' | grep -q ."
expect "the quote-named body is snapshotted, from its newest AMEND (M pass)" \
  grep -q body-weird-v2-amended "$UU_RUN/upgrades/$UQ.md"
expect "the backslash-named body is snapshotted" \
  grep -q body-backslash "$UU_RUN/upgrades/$UB.md"
expect "a quote-named file amended (not added) in range lands in upgrades-modified.txt" \
  grep -qxF -- ".kairos-updates/$UP.md" "$UU_RUN/upgrades-modified.txt"
expect "its snapshot carries the AMENDED body, not the pre-BASE one" \
  grep -q body-preamend-v2 "$UU_RUN/upgrades/$UP.md"
refute "an added file is not ALSO listed as modified" \
  grep -qxF -- ".kairos-updates/$UQ.md" "$UU_RUN/upgrades-modified.txt"
refute "nothing was refused — a legal filename is collected, not skipped" \
  test -s "$UU_RUN/snapshot-refusals.tsv"
cd "$COMP"

fi

if t "a TAB-bearing upgrade-file name is a named hard stop, not a silent skip"; then
# upgrades-added.txt is a line list and upgrades-added.tsv a TAB-delimited line
# record, so a TAB (or newline) in an upgrade-file name cannot ride EITHER — and
# unlike a `"`, no amount of raw-bytes plumbing makes it representable. The one
# thing it must never be is what it used to be: dropped, with the phase reporting
# success while a shipped migration step went missing. Note the diff-side refusal
# cannot cover this, because materialize.sh strips .kairos-updates/ from both
# synthetic trees — the name only ever surfaces on the history walk.
UT_NAME=$(printf '20260401T000000-tab\tname')
UT_TPL=$SANDBOX/upgtab-tpl
mkdir -p "$UT_TPL/.kairos-updates" && cd "$UT_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'seed\n' > seed.txt
git add -A && git commit -qm ut-base
UT_BASE=$(git rev-parse HEAD)
printf 'intent: tabbed\nbody-tabbed\n' > ".kairos-updates/$UT_NAME.md"
printf 'seed changed\n' > seed.txt
git add -A && git commit -qm ut-add
UT_TARGET=$(git rev-parse HEAD)

UT_COMP=$SANDBOX/upgtab-comp
mkdir -p "$UT_COMP/.kairos" && cd "$UT_COMP" && git init -q -b main
printf 'module example.com/custom/utcomp\n' > go.mod
git -C "$UT_TPL" show "$UT_BASE:seed.txt" > seed.txt
cat > .kairos/manifest.yaml <<EOF
name: utcomp
template:
  repo: file://$UT_TPL
  sha: $UT_BASE
  branch: main
EOF
git add -A && git commit -qm ut-comp

UT_RUN=$UT_COMP/.kairos/migration/state; mkdir -p "$UT_RUN"
RUN=$UT_RUN CACHE=$UT_TPL BASE=$UT_BASE TARGET=$UT_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/ut-mat.log"
expect "the TAB-upgrade fixture materializes" test $? -eq 0
RUN=$UT_RUN CACHE=$UT_TPL BASE=$UT_BASE TARGET=$UT_TARGET SYNTH=$UT_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/ut-bm.log"
UT_RC=$?
if [[ "$UT_RC" -ne 0 ]]; then pass "classification refuses a TAB-bearing upgrade-file name (exit $UT_RC)"; else fail "classification accepted a TAB-bearing upgrade-file name (exit 0)"; fi
expect "the refusal names the offending upgrade-file" \
  grep -q 'tab.*name' "$SANDBOX/ut-bm.log"
expect "the refusal states the remedy that works: rename it upstream" \
  bash -c "grep -qi 'rename' '$SANDBOX/ut-bm.log'"
refute "the refusal does NOT send the operator back through this phase" \
  bash -c "grep -qi 're-run.*phase 3\|re-run this phase\|re-run classification' '$SANDBOX/ut-bm.log'"
refute "no classification is left behind for Phase 5 to merge from" \
  test -s "$UT_RUN/classification.tsv"
refute "and no tree binding either, so a Phase 5 run stops instead of merging nothing" \
  test -e "$UT_RUN/classification-trees.tsv"
cd "$COMP"

fi

if t "an emptied subtree with a shell-special member still hits the user checkpoint"; then
# Two independent quoting seams meet here. The D row's `[ ! -e "$DEST" ]` probe was
# handed the QUOTED spelling, which exists nowhere, so the row became
# noop-already-deleted; and `git ls-files "$d"` quoted the same member again, so it
# never matched the (unquoted) deletion set. Either one alone makes the subtree look
# merely thinned, and the batched wholesale-deletion checkpoint disappears for the
# whole run — silently.
QN='wei"rd.txt'
QE_TPL=$SANDBOX/qempty-tpl
mkdir -p "$QE_TPL/legacy" && cd "$QE_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'a\n' > legacy/a.txt; printf 'b\n' > legacy/b.txt; printf 'c\n' > "legacy/$QN"
printf 'keep\n' > keep.txt
git add -A && git commit -qm qe-base
QE_BASE=$(git rev-parse HEAD)
git rm -q legacy/a.txt legacy/b.txt "legacy/$QN"
printf 'keep changed\n' > keep.txt
git add -A && git commit -qm qe-target
QE_TARGET=$(git rev-parse HEAD)

QE_COMP=$SANDBOX/qempty-comp
mkdir -p "$QE_COMP/.kairos" "$QE_COMP/legacy" && cd "$QE_COMP" && git init -q -b main
printf 'module example.com/custom/qecomp\n' > go.mod
printf 'a\n' > legacy/a.txt; printf 'b\n' > legacy/b.txt; printf 'c\n' > "legacy/$QN"
printf 'keep\n' > keep.txt
cat > .kairos/manifest.yaml <<EOF
name: qecomp
template:
  repo: file://$QE_TPL
  sha: $QE_BASE
  branch: main
EOF
git add -A && git commit -qm qe-comp

QE_RUN=$QE_COMP/.kairos/migration/state; mkdir -p "$QE_RUN"
RUN=$QE_RUN CACHE=$QE_TPL BASE=$QE_BASE TARGET=$QE_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/qe-mat.log"
expect "the shell-special deletion fixture materializes" test $? -eq 0
RUN=$QE_RUN CACHE=$QE_TPL BASE=$QE_BASE TARGET=$QE_TARGET SYNTH=$QE_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/qe-bm.log"
expect "the shell-special deletion fixture classifies" test $? -eq 0
refute "no C-quoted spelling reaches the classification" grep -q '\\"' "$QE_RUN/classification.tsv"
expect "a subtree with a quote-bearing member is still seen as emptied wholesale" \
  grep -qx 'legacy' "$QE_RUN/deleted-heavyweight-dirs.txt"
bucket_at "$QE_RUN/classification.tsv" "legacy/$QN" deleted-heavyweight-ask-user
bucket_at "$QE_RUN/classification.tsv" "legacy/a.txt" deleted-heavyweight-ask-user
cd "$COMP"

fi

if t "a RENAMED binary never reaches a for-AI bucket, and its old path rides the record"; then
# Two escapes from "binary -> binary-for-user, never send to AI", one per layer.
#   (a) CLASSIFIER: git computes rename similarity over binary content too, so an
#       R<100 on a moved-and-modified image is a real status. The R* arm probed no
#       binary list, so that row was emitted as renamed-with-mods-for-ai and
#       dispatched to the conflict-resolver — which has no binary handling at all,
#       and which structural-merge.sh's NUL-byte safety net can never rescue,
#       because for-AI buckets never enter its merge pipeline.
#   (b) SAFETY NET: a rename-flavored merge-pipeline row whose OURS side is binary
#       diverts to binaries.txt BEFORE merge_one completes the rename, so the old
#       copy is still in the tree. Recording only the new path made a later
#       `theirs` answer write the blob at the new path and leave the old one beside
#       it — a duplicate in the structural commit that no artifact named.
RB_TPL=$SANDBOX/rbin-tpl
mkdir -p "$RB_TPL" && cd "$RB_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
# A binary big enough that appending a few bytes keeps it well above git's rename
# threshold — the point is R<100, not "git lost the pairing".
{ printf 'BIN\0LOGO\n'; seq 1 60 | sed 's/^/logo payload line /'; } > logo.bin
seq 1 12 | sed 's/^/icon line /' > icon.txt
git add -A && git commit -qm rb-base
RB_BASE=$(git rev-parse HEAD)
mkdir -p assets
git mv logo.bin assets/logo.bin
printf 'MODIFIED\0TAIL\n' >> assets/logo.bin      # rename + content change: R<100 on a binary
git mv icon.txt assets/icon.txt                    # pure R100 rename of a TEXT file
git add -A && git commit -qm rb-target
RB_TARGET=$(git rev-parse HEAD)

RB_COMP=$SANDBOX/rbin-comp
mkdir -p "$RB_COMP/.kairos" && cd "$RB_COMP" && git init -q -b main
printf 'module example.com/custom/rbcomp\n' > go.mod
git -C "$RB_TPL" show "$RB_BASE:logo.bin" > logo.bin          # untouched copy at the OLD path
# The component replaced the template's text file with a BINARY one at the old
# path: template-side detection cannot see it, so only the local NUL-byte net can.
printf 'OURS\0ICON\n' > icon.txt
cp icon.txt "$SANDBOX/rb-icon.ours"
cat > .kairos/manifest.yaml <<EOF
name: rbcomp
template:
  repo: file://$RB_TPL
  sha: $RB_BASE
  branch: main
EOF
git add -A && git commit -qm rb-comp

RB_RUN=$RB_COMP/.kairos/migration/state; mkdir -p "$RB_RUN"
RUN=$RB_RUN CACHE=$RB_TPL BASE=$RB_BASE TARGET=$RB_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/rb-mat.log"
expect "the renamed-binary fixture materializes" test $? -eq 0
RUN=$RB_RUN CACHE=$RB_TPL BASE=$RB_BASE TARGET=$RB_TARGET SYNTH=$RB_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/rb-bm.log"
expect "the renamed-binary fixture classifies" test $? -eq 0

# The fixture is only meaningful if git really reported a RENAME for the binary —
# a delete+add pair would exercise the A arm's long-standing check instead.
expect "git reports the binary move as a rename (the status this block is about)" \
  awk -F'\t' '$1 ~ /^R/ && $3 == "assets/logo.bin" { found = 1 } END { exit !found }' "$RB_RUN/diff.raw.tsv"
refute "and it is NOT a pure R100 (the rename carries a content change)" \
  grep -qxF $'R100\tlogo.bin\tassets/logo.bin' "$RB_RUN/diff.raw.tsv"

# (a) the classifier: user bucket, never a for-AI one, with the old path attached.
bucket_at "$RB_RUN/classification.tsv" assets/logo.bin binary-for-user
refute "the renamed binary is in NO for-AI bucket" \
  awk -F'\t' '$4 == "assets/logo.bin" && ($1 == "renamed-with-mods-for-ai" || $1 == "modify-delete-for-ai") { f = 1 } END { exit !f }' \
    "$RB_RUN/classification.tsv"
RB_OLD=$(awk -F'\t' '$1 == "binary-for-user" && $4 == "assets/logo.bin" { print $5 }' "$RB_RUN/classification.tsv")
if [[ "$RB_OLD" = logo.bin ]]; then
  pass "the binary-for-user row carries the pre-rename path (enactable decision)"
else
  fail "the binary-for-user row carries the pre-rename path (got '${RB_OLD:-<empty>}')"
fi

# (b) the safety net: the text rename whose OURS side is binary.
bucket_at "$RB_RUN/classification.tsv" assets/icon.txt merge-pipeline
cd "$RB_COMP"
BASE=$RB_BASE TARGET=$RB_TARGET SYNTH=$RB_RUN/synthetic RUN=$RB_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" 2> "$SANDBOX/rb-sm.log"
expect "the merge runs" test $? -eq 0
expect "the binary ours side is diverted to binaries.txt WITH its pre-rename path" \
  grep -qxF $'assets/icon.txt\ticon.txt' "$RB_RUN/binaries.txt"
expect "the diverted row left the component's copy at the OLD path untouched" \
  cmp -s icon.txt "$SANDBOX/rb-icon.ours"
refute "and wrote nothing at the new path (the rename was NOT completed)" \
  test -e assets/icon.txt
refute "a diverted binary is never recorded as cleanly merged" \
  grep -qF 'assets/icon.txt' "$RB_RUN/clean-merged.txt"
# The second field is APPENDED, never unconditional: a non-rename diversion keeps
# its bare one-field spelling (asserted on `-nne` in the leading-dash block above),
# so every reader can go on taking the path from field 1.
cd "$COMP"

fi

if t "a template-DELETED binary the component customized is a user decision, not a resolver dispatch"; then
# The LAST escape from "binary -> binary-for-user, never send to AI". The A, M and
# R* arms all probe the binary list first; the D arm did not, so a template that
# DROPS a binary the component customized emitted modify-delete-for-ai — a for-AI
# bucket — and the conflict-resolver was dispatched to "reason about" a file it
# cannot read. Nothing downstream could rescue it either: for-AI buckets never
# enter structural-merge.sh, so its NUL-byte safety net never sees them.
#
# Two probes are needed, and both are fixtured: the template-side list (--numstat
# prints "-" for a DELETED binary too) and the ours side, for a file the COMPONENT
# turned binary — the only layer that can see that one, for exactly the same
# reason.
#
# The block also pins what must NOT change: the D arm's text behavior, and the
# UNMODIFIED binary, which stays a mechanical delete. That second one is not
# incidental — routing it to the user would take the wholesale-deletion checkpoint
# with it, since only deleted-by-template-mechanical rows feed the emptied-subtree
# scan.
DB_TPL=$SANDBOX/dbin-tpl
mkdir -p "$DB_TPL/assets" && cd "$DB_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'BIN\0LEGACY-LOGO\n' > assets/legacy-logo.png   # component customizes this
printf 'BIN\0KEEPER\n'      > assets/keep.png          # component leaves it alone
printf 'notes line one\nnotes line two\n' > notes.txt  # component customizes this
printf 'plain one\nplain two\n'           > plain.txt  # component leaves it alone
printf 'key: value\nother: thing\n'       > turned.txt # component replaces with BINARY
git add -A && git commit -qm db-base
DB_BASE=$(git rev-parse HEAD)
git rm -q assets/legacy-logo.png assets/keep.png notes.txt plain.txt turned.txt
git commit -qm db-target
DB_TARGET=$(git rev-parse HEAD)

DB_COMP=$SANDBOX/dbin-comp
mkdir -p "$DB_COMP/.kairos" "$DB_COMP/assets" && cd "$DB_COMP" && git init -q -b main
printf 'module example.com/custom/dbcomp\n' > go.mod
printf 'BIN\0LEGACY-LOGO-OURS\n' > assets/legacy-logo.png          # customized binary
git -C "$DB_TPL" show "$DB_BASE:assets/keep.png" > assets/keep.png # byte-identical
printf 'notes line one\nnotes line two\nmy own line\n' > notes.txt # customized text
git -C "$DB_TPL" show "$DB_BASE:plain.txt" > plain.txt             # unmodified text
printf 'OURS\0NOW-BINARY\n' > turned.txt                           # ours-side-only binary
cp assets/legacy-logo.png "$SANDBOX/db-logo.ours"
cp turned.txt "$SANDBOX/db-turned.ours"
cat > .kairos/manifest.yaml <<EOF
name: dbcomp
template:
  repo: file://$DB_TPL
  sha: $DB_BASE
  branch: main
EOF
git add -A && git commit -qm db-comp

DB_RUN=$DB_COMP/.kairos/migration/state; mkdir -p "$DB_RUN"
RUN=$DB_RUN CACHE=$DB_TPL BASE=$DB_BASE TARGET=$DB_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/db-mat.log"
expect "the deleted-binary fixture materializes" test $? -eq 0
RUN=$DB_RUN CACHE=$DB_TPL BASE=$DB_BASE TARGET=$DB_TARGET SYNTH=$DB_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/db-bm.log"
expect "the deleted-binary fixture classifies" test $? -eq 0

# Non-vacuity: the fixture is only about the D arm if git really reported deletes,
# and the template-side probe only works if --numstat marks a DELETED binary.
expect "the template really deletes the binary (status D)" \
  grep -qxF $'D\tassets/legacy-logo.png' "$DB_RUN/diff.tsv"
expect "a deleted binary is recorded as a template-side binary" \
  grep -qxF -- 'assets/legacy-logo.png' "$DB_RUN/binaries-template.txt"
refute "the ours-side-only case is NOT in the template list (only the local probe can see it)" \
  grep -qxF -- 'turned.txt' "$DB_RUN/binaries-template.txt"

# The defect itself: the customized binary is the user's decision, never the AI's.
bucket_at "$DB_RUN/classification.tsv" assets/legacy-logo.png binary-for-user
refute "the deleted binary is in NO for-AI bucket" \
  awk -F'\t' '$4 == "assets/legacy-logo.png" && ($1 == "modify-delete-for-ai" || $1 == "renamed-with-mods-for-ai") { f = 1 } END { exit !f }' \
    "$DB_RUN/classification.tsv"
# The row is DELETE-FLAVORED, and the flavor rides the existing status column —
# there is no template blob to write, so `theirs` has to mean the deletion.
DB_ST=$(awk -F'\t' '$1 == "binary-for-user" && $4 == "assets/legacy-logo.png" { print $2 }' \
          "$DB_RUN/classification.tsv")
if [[ "$DB_ST" = D ]]; then
  pass "the binary-for-user row carries status D (apply-ask-user.sh's delete flavor)"
else
  fail "the binary-for-user row carries status D (got '${DB_ST:-<empty>}')"
fi

# The ours-side probe: template text, component binary. Only the classifier can
# catch this one — the row never reaches structural-merge.sh's safety net.
bucket_at "$DB_RUN/classification.tsv" turned.txt binary-for-user

# UNCHANGED D-arm behavior for text, both ways.
bucket_at "$DB_RUN/classification.tsv" notes.txt modify-delete-for-ai
bucket_at "$DB_RUN/classification.tsv" plain.txt deleted-by-template-mechanical
# ...and the unmodified BINARY stays mechanical: nothing is lost by deleting a
# byte-identical copy, and the emptied-subtree checkpoint counts these rows.
bucket_at "$DB_RUN/classification.tsv" assets/keep.png deleted-by-template-mechanical

# Phase 5 step 2 must leave both user-bucket rows alone — they are apply-ask-user's
# to enact, and a customized binary silently deleted here would never be asked about.
cd "$DB_COMP"
BASE=$DB_BASE TARGET=$DB_TARGET SYNTH=$DB_RUN/synthetic RUN=$DB_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" 2> "$SANDBOX/db-sm.log"
expect "the merge runs" test $? -eq 0
expect "the customized binary is untouched by the mechanical merge" \
  cmp -s assets/legacy-logo.png "$SANDBOX/db-logo.ours"
expect "the ours-side-only binary is untouched too" \
  cmp -s turned.txt "$SANDBOX/db-turned.ours"
refute "neither user-bucket row is recorded as a mechanical deletion" \
  grep -qE '^(assets/legacy-logo\.png|turned\.txt)$' "$DB_RUN/deleted.txt"
expect "the unmodified binary IS mechanically deleted" \
  bash -c "! test -e assets/keep.png && grep -qxF assets/keep.png '$DB_RUN/deleted.txt'"
cd "$COMP"

fi

if t "one customized deletion does not suppress the wholesale-deletion checkpoint for its mechanical siblings"; then
# The emptied-subtree oracle asks "did the template remove every tracked file
# under this directory?". A file the template deleted that the component ALSO
# customized is (correctly) routed to modify-delete-for-ai / binary-for-user, not
# deleted-by-template-mechanical — but its component copy is still tracked, so a
# survivor scan keyed on the mechanical set alone counts it as a KEPT file and
# disqualifies the whole subtree. That inverts the checkpoint the way seam 2 does
# for a quoted member: it goes SILENT for the mechanical siblings (they stay
# deleted-by-template-mechanical and are removed in Phase 5 with nobody asked)
# exactly when the component has a customization at stake. The oracle must count
# every template-deleted path (mechanical + status-D for-AI + status-D binary),
# while still re-bucketing only the mechanical rows (the customized one keeps its
# own user path).
MD_TPL=$SANDBOX/mixdel-tpl
mkdir -p "$MD_TPL/legacy" && cd "$MD_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'a\n' > legacy/a.txt; printf 'b\n' > legacy/b.txt
printf 'c\n' > legacy/c.txt; printf 'd\n' > legacy/d.txt
printf 'keep\n' > keep.txt
git add -A && git commit -qm md-base
MD_BASE=$(git rev-parse HEAD)
git rm -q legacy/a.txt legacy/b.txt legacy/c.txt legacy/d.txt
git commit -qm md-target
MD_TARGET=$(git rev-parse HEAD)

MD_COMP=$SANDBOX/mixdel-comp
mkdir -p "$MD_COMP/.kairos" "$MD_COMP/legacy" && cd "$MD_COMP" && git init -q -b main
printf 'module example.com/custom/mdcomp\n' > go.mod
printf 'a\n' > legacy/a.txt; printf 'b\n' > legacy/b.txt; printf 'c\n' > legacy/c.txt
printf 'd\nmy own line\n' > legacy/d.txt          # component CUSTOMIZED this one
printf 'keep\n' > keep.txt
cat > .kairos/manifest.yaml <<EOF
name: mdcomp
template:
  repo: file://$MD_TPL
  sha: $MD_BASE
  branch: main
EOF
git add -A && git commit -qm md-comp

MD_RUN=$MD_COMP/.kairos/migration/state; mkdir -p "$MD_RUN"
RUN=$MD_RUN CACHE=$MD_TPL BASE=$MD_BASE TARGET=$MD_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/md-mat.log"
expect "the mixed-deletion fixture materializes" test $? -eq 0
RUN=$MD_RUN CACHE=$MD_TPL BASE=$MD_BASE TARGET=$MD_TARGET SYNTH=$MD_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/md-bm.log"
expect "the mixed-deletion fixture classifies" test $? -eq 0
# Non-vacuity: the customized member really is a for-AI delete, not mechanical.
bucket_at "$MD_RUN/classification.tsv" legacy/d.txt modify-delete-for-ai
# The oracle counts it as removed, so legacy still reads as emptied wholesale.
expect "the subtree with one customized member is still seen as emptied wholesale" \
  grep -qx 'legacy' "$MD_RUN/deleted-heavyweight-dirs.txt"
# ...and the mechanical siblings are re-bucketed to the user checkpoint instead of
# being silently applied in Phase 5.
bucket_at "$MD_RUN/classification.tsv" legacy/a.txt deleted-heavyweight-ask-user
bucket_at "$MD_RUN/classification.tsv" legacy/b.txt deleted-heavyweight-ask-user
bucket_at "$MD_RUN/classification.tsv" legacy/c.txt deleted-heavyweight-ask-user
# The customized member keeps its OWN path — the re-bucket touches only mechanical rows.
bucket_at "$MD_RUN/classification.tsv" legacy/d.txt modify-delete-for-ai
cd "$COMP"

fi

if t "an R<100 rename whose OURS side is binary is a user decision, not a resolver dispatch"; then
# The last for-AI branch without a binary probe. renamed-with-mods-for-ai is a
# resolver bucket, so it never enters structural-merge.sh's NUL-byte safety net —
# and the template-side list cannot see a file only the COMPONENT made binary. So
# a text file the template renamed-and-edited, whose local copy the component
# replaced with a binary, was dispatched to an agent that cannot read "ours".
#
# Deliberately NOT generalized to the whole R* arm: an R100 with a binary ours
# side goes to merge-pipeline, where the safety net catches it and records the
# new/old pair in binaries.txt (asserted in the renamed-binary block above). One
# route each, and this fixture keeps both honest by carrying both shapes.
OB_TPL=$SANDBOX/oursbin-tpl
mkdir -p "$OB_TPL" && cd "$OB_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
seq 1 20 | sed 's/^/tool line /' > tool.sh
git add -A && git commit -qm ob-base
OB_BASE=$(git rev-parse HEAD)
mkdir -p bin && git mv tool.sh bin/tool.sh
sed 's/tool line 7/tool line seven CHANGED/' bin/tool.sh > t && mv t bin/tool.sh
git add -A && git commit -qm ob-target
OB_TARGET=$(git rev-parse HEAD)

OB_COMP=$SANDBOX/oursbin-comp
mkdir -p "$OB_COMP/.kairos" && cd "$OB_COMP" && git init -q -b main
printf 'module example.com/custom/obcomp\n' > go.mod
printf 'OURS\0TOOL\n' > tool.sh          # still at the OLD path, and now BINARY
cp tool.sh "$SANDBOX/ob-tool.ours"
cat > .kairos/manifest.yaml <<EOF
name: obcomp
template:
  repo: file://$OB_TPL
  sha: $OB_BASE
  branch: main
EOF
git add -A && git commit -qm ob-comp

OB_RUN=$OB_COMP/.kairos/migration/state; mkdir -p "$OB_RUN"
RUN=$OB_RUN CACHE=$OB_TPL BASE=$OB_BASE TARGET=$OB_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/ob-mat.log"
expect "the ours-binary rename fixture materializes" test $? -eq 0
RUN=$OB_RUN CACHE=$OB_TPL BASE=$OB_BASE TARGET=$OB_TARGET SYNTH=$OB_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/ob-bm.log"
expect "the ours-binary rename fixture classifies" test $? -eq 0

# Non-vacuity: an R<100 (rename + content change) on a file the template keeps as
# TEXT — so only the local probe can reach the verdict below.
expect "git reports a rename with a content change (R<100)" \
  awk -F'\t' '$1 ~ /^R/ && $1 != "R100" && $3 == "bin/tool.sh" { f = 1 } END { exit !f }' \
    "$OB_RUN/diff.raw.tsv"
refute "the template side is NOT binary (the list cannot see this one)" \
  grep -qxF -- 'bin/tool.sh' "$OB_RUN/binaries-template.txt"

bucket_at "$OB_RUN/classification.tsv" bin/tool.sh binary-for-user
refute "it is NOT dispatched to the resolver" \
  awk -F'\t' '$4 == "bin/tool.sh" && $1 == "renamed-with-mods-for-ai" { f = 1 } END { exit !f }' \
    "$OB_RUN/classification.tsv"
OB_OLD=$(awk -F'\t' '$1 == "binary-for-user" && $4 == "bin/tool.sh" { print $5 }' \
           "$OB_RUN/classification.tsv")
if [[ "$OB_OLD" = tool.sh ]]; then
  pass "the row still carries the pre-rename path (the decision stays enactable)"
else
  fail "the row still carries the pre-rename path (got '${OB_OLD:-<empty>}')"
fi
cd "$OB_COMP"
BASE=$OB_BASE TARGET=$OB_TARGET SYNTH=$OB_RUN/synthetic RUN=$OB_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" 2> "$SANDBOX/ob-sm.log"
expect "the merge runs" test $? -eq 0
expect "the component's binary is untouched at its current path" \
  cmp -s tool.sh "$SANDBOX/ob-tool.ours"
refute "nothing was written at the new path" test -e bin/tool.sh
cd "$COMP"

fi

if t "the classification stamp names the trees the rows were actually diffed from"; then
# TOCTOU: the diff read the two tags at the top of the run and the stamp re-read
# the same tags ~450 lines later. A $SYNTH re-materialization in between (a
# corrected BASE, a concurrent FORCE_MATERIALIZE) moved the tags between the two
# reads, so classification-trees.tsv stamped trees the rows were NOT derived from —
# and structural-merge.sh's binding check, whose whole job is to catch exactly that,
# then passed and merged a stale classification clean.
#
# The race cannot be interleaved from a black-box test (there is no hook inside one
# script run), so it is pinned two ways that together close it:
#   (1) behaviorally — the stamped oids must REPRODUCE the recorded diff, i.e. the
#       rows and the stamp describe one pair of trees; and
#   (2) structurally — the script must resolve each tag EXACTLY ONCE and address
#       every tree read through the resolved oid, so no second read exists to race.
CTS_BASE=$(awk -F'\t' '$1=="base"{print $2}' "$RUN/classification-trees.tsv")
CTS_TGT=$(awk -F'\t' '$1=="target"{print $2}' "$RUN/classification-trees.tsv")
expect "the stamp records a base tree oid" bash -c "[ -n '$CTS_BASE' ]"
expect "the stamp records a target tree oid" bash -c "[ -n '$CTS_TGT' ]"
znorm() { tr '\000\011' '\n\n' | grep -v '^$' | sort; }
git -C "$SYNTH" diff --name-status -M -z "$CTS_BASE" "$CTS_TGT" | znorm > "$SANDBOX/cts-redrive.txt"
znorm < "$RUN/diff.raw.tsv" > "$SANDBOX/cts-recorded.txt"
expect "diffing the stamped trees reproduces the recorded diff exactly" \
  cmp -s "$SANDBOX/cts-redrive.txt" "$SANDBOX/cts-recorded.txt"
BM=$SKILL_DIR/scripts/build-manifest.sh
RP_N=$(grep -c 'rev-parse' "$BM" || true)
if [[ "${RP_N:-0}" -eq 2 ]]; then
  pass "build-manifest.sh resolves the two synthetic tags exactly once each (2 rev-parse reads)"
else
  fail "build-manifest.sh performs ${RP_N:-0} rev-parse reads (want exactly 2 — one per side; a second read of a tag is the TOCTOU window)"
fi
# `<rev>:<path>` is how a blob/tree read is spelled; the two `^{tree}` reads above
# ARE the single resolution and are counted by the rev-parse assertion instead.
TAGREAD_N=$(grep -cE '\$(SBASE|STARGET):' "$BM" || true)
if [[ "${TAGREAD_N:-0}" -eq 0 ]]; then
  pass "no tree/blob read addresses a tag name (every read goes through the resolved oid)"
else
  fail "${TAGREAD_N:-0} tree/blob read(s) still address \$SBASE/\$STARGET by tag name instead of the resolved oid"
fi

fi

if t "the tree binding is a COMPLETION stamp: an interrupted classification leaves none"; then
# The binding above proves WHICH trees the rows came from. It cannot prove there
# are ALL the rows — and a stale binding cannot detect its own staleness. A run
# killed after classification.tsv was truncated but before the stamp left a
# PARTIAL classification beside the PREVIOUS run's binding, which still MATCHED
# because $SYNTH had not moved: Phase 5's binding check passed, gate check 7
# printed PASS, and every row after the kill point was silently dropped from the
# migration (52 of 600 rows merged, exit 0).
#
# So the binding is torn down before the first artifact write and re-written as
# the last one. An interrupted run then leaves NO binding, which Phase 5 already
# refuses on.
#
# The kill is made deterministic through a `cmp` shim rather than a timing race:
# matches_template() is the only caller in build-manifest.sh that spells its
# comparison `cmp -s - <(...)` (the upgrade-snapshot one passes two real paths),
# and it runs from inside the classification emission loop — exactly the window
# the stamp exists for. The shim SIGKILLs the script itself, so this is a real
# kill mid-emit, not a simulated file state.
CS_TPL=$SANDBOX/cstamp-tpl
mkdir -p "$CS_TPL" && cd "$CS_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'doomed\n' > zzz-doomed.txt          # D, last in path order → emitted last
git add -A && git commit -qm cs-base
CS_BASE=$(git rev-parse HEAD)
rm -f zzz-doomed.txt
for i in 1 2 3; do printf 'added %s\n' "$i" > "aaa$i.txt"; done   # A, emitted first
git add -A && git commit -qm cs-target
CS_TARGET=$(git rev-parse HEAD)

CS_COMP=$SANDBOX/cstamp-comp
mkdir -p "$CS_COMP/.kairos" && cd "$CS_COMP" && git init -q -b main
printf 'module example.com/custom/cscomp\n' > go.mod
git -C "$CS_TPL" show "$CS_BASE:zzz-doomed.txt" > zzz-doomed.txt   # untouched → mechanical delete
cat > .kairos/manifest.yaml <<EOF
name: cscomp
template:
  repo: file://$CS_TPL
  sha: $CS_BASE
  branch: main
EOF
git add -A && git commit -qm cs-comp

CS_RUN=$CS_COMP/.kairos/migration/state; mkdir -p "$CS_RUN"
RUN=$CS_RUN CACHE=$CS_TPL BASE=$CS_BASE TARGET=$CS_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/cs-mat.log"
expect "the completion-stamp fixture materializes" test $? -eq 0
cs_classify() { # cs_classify <logfile>
  RUN=$CS_RUN CACHE=$CS_TPL BASE=$CS_BASE TARGET=$CS_TARGET SYNTH=$CS_RUN/synthetic \
    PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/$1"
}
cs_merge() { # cs_merge <logfile>
  BASE=$CS_BASE TARGET=$CS_TARGET SYNTH=$CS_RUN/synthetic RUN=$CS_RUN \
    PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" > /dev/null 2> "$SANDBOX/$1"
}

# A COMPLETE run: the stamp is present and the fragment test below has a full-run
# row count to be measured against.
cs_classify cs-bm-full.log
expect "a complete classification exits 0" test $? -eq 0
expect "a complete run leaves a tree binding" test -s "$CS_RUN/classification-trees.tsv"
CS_FULL_ROWS=$(grep -c . "$CS_RUN/classification.tsv" || true)
expect "the complete run classified the deletion" \
  grep -q 'deleted-by-template-mechanical' "$CS_RUN/classification.tsv"
cp "$CS_RUN/classification-trees.tsv" "$SANDBOX/cs-good-binding.tsv"

# Now kill one mid-emit. The binding saved above is the one the PREVIOUS
# (complete) run wrote, and it still matches $SYNTH exactly — that is the whole
# hazard, and it is why teardown has to happen up front rather than on exit.
CS_KBIN=$SANDBOX/cstamp-bin; mkdir -p "$CS_KBIN"
CS_REAL_CMP=$(command -v cmp)
cat > "$CS_KBIN/cmp" <<CSCMP
#!/bin/sh
# \$2 = "-" ⇒ matches_template(), i.e. we are inside the emission loop with
# classification.tsv truncated and only partly rewritten. Kill the script there.
if [ "\${2:-}" = "-" ]; then
  kill -9 "\$(cat "\$CS_PID_FILE")" 2>/dev/null
  sleep 1
fi
exec "$CS_REAL_CMP" "\$@"
CSCMP
chmod +x "$CS_KBIN/cmp"
CS_PID_FILE=$SANDBOX/cs-bm.pid
# `bash -c` + exec so the recorded pid IS the build-manifest.sh process ($$ in a
# plain ( ) subshell would still be the harness's pid). The whole thing runs in a
# subshell whose stderr is the log, because the shell that WAITS on a SIGKILLed
# foreground job prints "Killed: 9" to its own stderr — that belongs in the log,
# not in the suite output. The `echo $?` keeps a second command in the subshell,
# so bash cannot collapse it into the exec'd child and report the death itself.
( bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$CS_PID_FILE" \
    env PATH="$CS_KBIN:$PATH" CS_PID_FILE="$CS_PID_FILE" \
        RUN="$CS_RUN" CACHE="$CS_TPL" BASE="$CS_BASE" TARGET="$CS_TARGET" \
        SYNTH="$CS_RUN/synthetic" PHASE_KEY="$PK_CLASSIFY" \
        "$SKILL_DIR/scripts/build-manifest.sh"
  echo $? > "$SANDBOX/cs-kill-rc" ) 2> "$SANDBOX/cs-bm-killed.log"
CS_KILL_RC=$(cat "$SANDBOX/cs-kill-rc")
if [[ "$CS_KILL_RC" -eq 137 ]]; then
  pass "the classification run was really SIGKILLed mid-emit (exit 137)"
else
  fail "the classification run was not killed mid-emit (exit $CS_KILL_RC — the shim never fired, so nothing below is testing an interrupt)"
fi
CS_PART_ROWS=$(grep -c . "$CS_RUN/classification.tsv" || true)
if [[ "${CS_PART_ROWS:-0}" -gt 0 ]] && [[ "${CS_PART_ROWS:-0}" -lt "${CS_FULL_ROWS:-0}" ]]; then
  pass "the interrupted run left a PARTIAL classification ($CS_PART_ROWS of $CS_FULL_ROWS rows)"
else
  fail "the interrupted run left $CS_PART_ROWS rows (want 0 < n < $CS_FULL_ROWS — a partial file is the state under test)"
fi
refute "the interrupted run left NO tree binding" test -e "$CS_RUN/classification-trees.tsv"

cs_merge cs-sm-partial.log
CS_SM_RC=$?
if [[ "$CS_SM_RC" -ne 0 ]]; then
  pass "Phase 5 refuses the fragment an interrupted classification left behind"
else
  fail "Phase 5 merged the fragment an interrupted classification left behind (exit 0)"
fi
expect "the refusal directs the operator back through classification" \
  grep -q 'build-manifest.sh' "$SANDBOX/cs-sm-partial.log"
refute "the refused merge enacted nothing" test -s "$CS_RUN/added.txt"
expect "the row the kill dropped is still on disk, unmerged" test -f zzz-doomed.txt

# The counterfactual that makes the teardown load-bearing: hand the SAME fragment
# the previous run's binding back — it still matches, so the binding check has
# nothing to object to and Phase 5 enacts the fragment as a complete migration.
# This is the 52-of-600 run, reproduced.
cp "$SANDBOX/cs-good-binding.tsv" "$CS_RUN/classification-trees.tsv"
cs_merge cs-sm-stale.log
if [[ $? -eq 0 ]]; then
  pass "a matching binding beside a fragment is merged clean — the binding alone cannot see the truncation"
else
  fail "expected the stale-binding fragment to merge (exit 0); the counterfactual no longer holds"
fi
refute "and the dropped row is silently skipped: the template-deleted file survives" \
  bash -c "test ! -e zzz-doomed.txt"
git -C "$CS_COMP" checkout -- . >/dev/null 2>&1
git -C "$CS_COMP" clean -fdq >/dev/null 2>&1

# The remedy the refusal names actually clears it.
cs_classify cs-bm-redo.log
expect "re-running classification restores the binding" test -s "$CS_RUN/classification-trees.tsv"
cs_merge cs-sm-redo.log
expect "and Phase 5 then runs green" test $? -eq 0
expect "the redone merge enacted the row the kill had dropped" test ! -e zzz-doomed.txt
cd "$COMP"

# A kill cannot be aimed at every line, so the ordering itself is pinned on the
# source: teardown before the FIRST write to $RUN, stamp as the LAST one. Both
# halves matter — a stamp written before summary.txt would certify a run whose
# later artifacts are still missing.
BMS=$SKILL_DIR/scripts/build-manifest.sh
CS_TEARDOWN_LN=$(grep -n '^rm -f "\$RUN/classification-trees.tsv"$' "$BMS" | head -1 | cut -d: -f1)
CS_FIRST_WRITE_LN=$(grep -nE '>>? "\$RUN/' "$BMS" | head -1 | cut -d: -f1)
CS_LAST_WRITE_LN=$(grep -nE '>>? "\$RUN/' "$BMS" | tail -1 | cut -d: -f1)
if [[ -n "$CS_TEARDOWN_LN" ]] && [[ -n "$CS_FIRST_WRITE_LN" ]] && [[ "$CS_TEARDOWN_LN" -lt "$CS_FIRST_WRITE_LN" ]]; then
  pass "the binding is torn down (line $CS_TEARDOWN_LN) before the first \$RUN write (line $CS_FIRST_WRITE_LN)"
else
  fail "binding teardown (line ${CS_TEARDOWN_LN:-<none>}) does not precede the first \$RUN write (line ${CS_FIRST_WRITE_LN:-<none>})"
fi
if [[ -n "$CS_LAST_WRITE_LN" ]] && sed -n "${CS_LAST_WRITE_LN}p" "$BMS" | grep -q 'classification-trees.tsv'; then
  pass "the binding write is the LAST \$RUN write in the script (line $CS_LAST_WRITE_LN)"
else
  fail "the last \$RUN write is line ${CS_LAST_WRITE_LN:-<none>}, which is not the binding stamp — an artifact is written after the completion stamp"
fi

fi

if t "a failed snapshot read never overwrites a good upgrade-file body"; then
# snap_upgrade takes the body on STDIN from `git show <sha>:<path>`, and that
# command failing (a pruned or corrupted object in the mirror, a bad sha) is an
# EMPTY stdin, not an error the pipeline can see: `cat > tmp; mv tmp dest`
# replaced a good snapshot with a ZERO-BYTE file, and the planner then planned
# from an empty upgrade-file. Reproduced by removing the loose blob from the
# mirror between two runs — `git log --name-only` still lists the path (it reads
# trees), only the body read fails.
SG_TPL=$SANDBOX/snapguard-tpl
mkdir -p "$SG_TPL/.kairos-updates" && cd "$SG_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'seed\n' > seed.txt
git add -A && git commit -qm sg-base
SG_BASE=$(git rev-parse HEAD)
printf '# up-one\n\nintent: migrate the call sites\nbody-must-survive\n' \
  > .kairos-updates/20260401T000000-one.md
printf 'seed changed\n' > seed.txt
git add -A && git commit -qm sg-target
SG_TARGET=$(git rev-parse HEAD)

SG_COMP=$SANDBOX/snapguard-comp
mkdir -p "$SG_COMP/.kairos" && cd "$SG_COMP" && git init -q -b main
printf 'module example.com/custom/sgcomp\n' > go.mod
git -C "$SG_TPL" show "$SG_BASE:seed.txt" > seed.txt
cat > .kairos/manifest.yaml <<EOF
name: sgcomp
template:
  repo: file://$SG_TPL
  sha: $SG_BASE
  branch: main
EOF
git add -A && git commit -qm sg-comp

SG_RUN=$SG_COMP/.kairos/migration/state; mkdir -p "$SG_RUN"
RUN=$SG_RUN CACHE=$SG_TPL BASE=$SG_BASE TARGET=$SG_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/sg-mat.log"
expect "the snapshot-guard fixture materializes" test $? -eq 0
sg_classify() {
  RUN=$SG_RUN CACHE=$SG_TPL BASE=$SG_BASE TARGET=$SG_TARGET SYNTH=$SG_RUN/synthetic \
    PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$1"
}
sg_classify "$SANDBOX/sg-bm1.log"
expect "run 1 classifies" test $? -eq 0
expect "run 1 snapshotted the upgrade-file body" \
  grep -q body-must-survive "$SG_RUN/upgrades/20260401T000000-one.md"

# Break exactly one thing: the blob behind that upgrade-file.
SG_BLOB=$(git -C "$SG_TPL" rev-parse "$SG_TARGET:.kairos-updates/20260401T000000-one.md")
rm -f "$SG_TPL/.git/objects/${SG_BLOB:0:2}/${SG_BLOB:2}"
refute "the fixture's body read really does fail now" \
  git -C "$SG_TPL" show "$SG_TARGET:.kairos-updates/20260401T000000-one.md"

sg_classify "$SANDBOX/sg-bm2.log"
SG_RC2=$?
expect "the good body survives a failed re-snapshot" \
  grep -q body-must-survive "$SG_RUN/upgrades/20260401T000000-one.md"
refute "the snapshot was not truncated to zero bytes" \
  bash -c "test ! -s '$SG_RUN/upgrades/20260401T000000-one.md'"
expect "the refusal is loud: one line naming the file and saying it refused" \
  grep -qi 'refus.*20260401T000000-one\|20260401T000000-one.*refus' "$SANDBOX/sg-bm2.log"
# The classification itself is still valid — one unreadable upgrade-file body must
# not abort the whole manifest (the planner's own gate refuses a missing body).
expect "the run still completes (exit 0)" test "$SG_RC2" -eq 0

# The WARN alone was stderr-only, and every call site is `|| true`, so nothing
# downstream could tell a refused body from one that was never in range: the phase
# relayed a tally, the planner asked for the slug, and the read end said "not
# snapshotted" — three places, no shared fact. The refusal is now ALSO a row the
# phase and next-upgrade-file.sh both read.
expect "a refused snapshot is recorded in \$RUN/snapshot-refusals.tsv" \
  bash -c "cut -f1 '$SG_RUN/snapshot-refusals.tsv' | grep -qx 20260401T000000-one"
expect "the recorded row carries the source it failed to read" \
  grep -q '.kairos-updates/20260401T000000-one.md' "$SG_RUN/snapshot-refusals.tsv"
expect "the recorded row states the failure, not an emptiness" \
  bash -c "cut -f3 '$SG_RUN/snapshot-refusals.tsv' | grep -qi 'git show'"
if [[ "$(grep -c . "$SG_RUN/snapshot-refusals.tsv")" = 1 ]]; then
  pass "the refusal file carries one row per refusal, not one per re-run"
else
  fail "the refusal file accumulated $(grep -c . "$SG_RUN/snapshot-refusals.tsv") rows across runs (want 1)"
fi
# End to end: with the surviving body removed, the read end names the RECORDED
# cause (exit 5) instead of the generic never-snapshotted answer, which is what
# keeps the operator off a re-run loop that reproduces the same failure.
rm -f "$SG_RUN/upgrades/20260401T000000-one.md"
RUN=$SG_RUN SLUG=20260401T000000-one LIST=$SG_RUN/upgrades-added.txt \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > /dev/null 2> "$SANDBOX/sg-serve.log"
SG_SERVE_RC=$?
if [[ "$SG_SERVE_RC" -eq 5 ]]; then pass "the read end reports the refused capture (exit 5)"; else fail "the read end exited $SG_SERVE_RC for a refused capture (want 5)"; fi
expect "the read-end message relays the recorded reason" \
  grep -qi 'git show' "$SANDBOX/sg-serve.log"
cd "$COMP"

fi

if t "a legitimately EMPTY upgrade-file is snapshotted and served, not dead-ended"; then
# The B3 guard refused on an EMPTY BODY, which conflated two different facts: a
# `git show` that FAILED (empty stdin, the case it was written for) and one that
# SUCCEEDED against a zero-byte blob. A genuinely empty upgrade-file committed in
# the template was therefore unmigratable forever — WARN on every run, the slug
# still listed in upgrades-added.txt, next-upgrade-file refusing to serve it, and
# plan-completeness blocking on a disposition the planner could never fetch a body
# for. The fix is at the root: capture `git show`'s EXIT STATUS separately from its
# output, so "failed" and "empty" are different answers.
EU_TPL=$SANDBOX/emptyup-tpl
mkdir -p "$EU_TPL/.kairos-updates" && cd "$EU_TPL" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
printf 'seed\n' > seed.txt
git add -A && git commit -qm eu-base
EU_BASE=$(git rev-parse HEAD)
: > .kairos-updates/20260501T000000-empty.md          # committed at zero bytes
printf '# real\n\nintent: something\nbody-real\n' > .kairos-updates/20260501T000001-real.md
printf 'seed changed\n' > seed.txt
git add -A && git commit -qm eu-target
EU_TARGET=$(git rev-parse HEAD)

EU_COMP=$SANDBOX/emptyup-comp
mkdir -p "$EU_COMP/.kairos" && cd "$EU_COMP" && git init -q -b main
printf 'module example.com/custom/eucomp\n' > go.mod
git -C "$EU_TPL" show "$EU_BASE:seed.txt" > seed.txt
cat > .kairos/manifest.yaml <<EOF
name: eucomp
template:
  repo: file://$EU_TPL
  sha: $EU_BASE
  branch: main
EOF
git add -A && git commit -qm eu-comp

EU_RUN=$EU_COMP/.kairos/migration/state; mkdir -p "$EU_RUN"
RUN=$EU_RUN CACHE=$EU_TPL BASE=$EU_BASE TARGET=$EU_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/eu-mat.log"
expect "the empty-upgrade-file fixture materializes" test $? -eq 0
RUN=$EU_RUN CACHE=$EU_TPL BASE=$EU_BASE TARGET=$EU_TARGET SYNTH=$EU_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/eu-bm.log"
expect "the empty-upgrade-file fixture classifies" test $? -eq 0
expect "the empty upgrade-file is in the apply list" \
  grep -q '20260501T000000-empty.md' "$EU_RUN/upgrades-added.txt"
expect "an empty body is snapshotted (the file exists)" \
  test -f "$EU_RUN/upgrades/20260501T000000-empty.md"
refute "the empty snapshot is not padded with anything" \
  test -s "$EU_RUN/upgrades/20260501T000000-empty.md"
refute "a successful read of an empty blob is not recorded as a refusal" \
  bash -c "cut -f1 '$EU_RUN/snapshot-refusals.tsv' 2>/dev/null | grep -qx 20260501T000000-empty"
refute "and it is not reported as a refusal on stderr either" \
  grep -qi 'refus' "$SANDBOX/eu-bm.log"
expect "the non-empty sibling in the same commit is unaffected" \
  grep -q body-real "$EU_RUN/upgrades/20260501T000001-real.md"
RUN=$EU_RUN SLUG=20260501T000000-empty LIST=$EU_RUN/upgrades-added.txt \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > "$SANDBOX/eu-serve.out" 2> "$SANDBOX/eu-serve.log"
EU_SERVE_RC=$?
if [[ "$EU_SERVE_RC" -eq 0 ]]; then pass "the planner can read the empty upgrade-file (exit 0, no dead end)"; else fail "serving the empty upgrade-file exited $EU_SERVE_RC (want 0)"; fi
expect "the planner is told the body is empty" grep -q '^EMPTY:' "$SANDBOX/eu-serve.out"
cd "$COMP"

fi

if t "pre-flight.sh refuses a fresh run over a live migration, and sweeps otherwise"; then
cd "$COMP"
git add -A && git commit -qm "post-merge state"   # sweep test needs a clean tree
cat > .kairos/manifest.yaml <<EOF
name: mycomp
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
  in_progress:
    target_sha: $TARGET
    branch: topic/tester/template-update-test
    previous_branch: main
EOF
git commit -qam "add in_progress block"
mkdir -p .kairos/migration/state
touch .kairos/migration/PLAN.md

# Fresh over a LIVE run, standing on a DIFFERENT branch than the migration's:
# the block owns $RUN, so the run is refused wherever the user is standing.
# Without this the block suppresses check 6's sweep and the fresh run inherits
# the live run's qa-ledger answers, spawns and context.env values wholesale.
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-live.out" 2> "$SANDBOX/pf-live.log"
PF_LIVE_RC=$?
if [[ "$PF_LIVE_RC" -ne 0 ]]; then pass "fresh over a live migration is refused from another branch"; else fail "fresh over a live migration was accepted from another branch"; fi
expect "the refusal names the in-progress target" grep -qF "$TARGET" "$SANDBOX/pf-live.log"
expect "the refusal names the in-progress branch" \
  grep -qF 'topic/tester/template-update-test' "$SANDBOX/pf-live.log"
expect "the refusal offers continue" grep -q "'continue'" "$SANDBOX/pf-live.log"
expect "the refusal offers abort"    grep -q "'abort'" "$SANDBOX/pf-live.log"
refute "the refused fresh run emits no RUN/CACHE lines" \
  grep -qE '^(RUN|CACHE)=' "$SANDBOX/pf-live.out"
expect "in-progress migration preserved"    test -d .kairos/migration/state
expect "in-progress PLAN.md preserved"      test -f .kairos/migration/PLAN.md

# Continue mode is the sanctioned way past it — same manifest, same branch.
MODE=continue TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf.out" 2> "$SANDBOX/pf.log"
expect "continue mode passes over the same live migration" test $? -eq 0
expect "continue preserved the in-progress state dir"      test -d .kairos/migration/state
expect "continue preserved the in-progress PLAN.md"        test -f .kairos/migration/PLAN.md

# --no-branch: Phase 4 omits branch: from the block. The sweep guard keys on
# the BLOCK's existence, never the branch: field — keying on the field would
# read a live --no-branch migration as "no migration" and destroy exactly the
# state continue needs. And being back on previous_branch with a branchless
# block IS being on the migration branch (check 3).
PREV_SHA_FIX=$(git rev-parse HEAD)
cat > .kairos/manifest.yaml <<EOF
name: mycomp
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
  in_progress:
    target_sha: $TARGET
    previous_branch: main
    previous_sha: $PREV_SHA_FIX
EOF
git commit -qam "branchless in_progress block (--no-branch)"
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > /dev/null 2> "$SANDBOX/pf-nb.log"
PF_NB_RC=$?
if [[ "$PF_NB_RC" -ne 0 ]]; then pass "fresh mode on a live --no-branch migration's branch is refused (check 3)"; else fail "fresh mode on a live --no-branch migration was accepted"; fi
expect "the refusal offers continue/abort" grep -q 'continue/abort' "$SANDBOX/pf-nb.log"
expect "nothing was swept by the refused run (PLAN.md preserved)" \
  test -f .kairos/migration/PLAN.md

# From an unrelated branch the block still refuses the fresh run — and with no
# branch: field the message falls back to previous_branch, so the user is still
# told where the live run lives.
git checkout -q -b elsewhere
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > /dev/null 2> "$SANDBOX/pf-nb2.log"
PF_NB2_RC=$?
if [[ "$PF_NB2_RC" -ne 0 ]]; then pass "fresh over a live branchless migration is refused from an unrelated branch"; else fail "fresh over a live branchless migration was accepted from an unrelated branch"; fi
expect "the branchless refusal falls back to previous_branch" \
  grep -q 'branch main' "$SANDBOX/pf-nb2.log"
expect "the branchless refusal offers both continue and abort" \
  bash -c "grep -q \"'continue'\" '$SANDBOX/pf-nb2.log' && grep -q \"'abort'\" '$SANDBOX/pf-nb2.log'"
expect "the refused run swept nothing (PLAN.md preserved)" \
  test -f .kairos/migration/PLAN.md
expect "the state dir survived the refused fresh run" \
  test -d .kairos/migration/state
git checkout -q main

# An UNPARSEABLE manifest must fail CLOSED, never read as "no migration": the
# sweep guard and check 3 both reason from it, and a yq parse error rounded to
# "" would sweep a live migration's unrecoverable state.
printf 'template:\n  in_progress: [unclosed\n' > .kairos/manifest.yaml
git commit -qam "corrupt manifest"
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > /dev/null 2> "$SANDBOX/pf-badyaml.log"
PF_BY_RC=$?
if [[ "$PF_BY_RC" -ne 0 ]]; then pass "an unparseable manifest is refused (fail closed)"; else fail "an unparseable manifest was accepted"; fi
expect "the refusal names the manifest parse failure" grep -qi 'parse' "$SANDBOX/pf-badyaml.log"
expect "nothing was swept on the unparseable manifest (PLAN.md preserved)" \
  test -f .kairos/migration/PLAN.md
cat > .kairos/manifest.yaml <<EOF
name: mycomp
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
  in_progress:
    target_sha: $TARGET
    previous_branch: main
    previous_sha: $PREV_SHA_FIX
EOF
git commit -qam "restore parseable manifest"

touch .kairos/migration/state/stale-marker
# Both mirror clones are expensive to rebuild and safe to reuse, so the sweep
# spares BOTH — the common mirror the same way it spares the template. The
# marker file is what distinguishes "spared" from "swept and re-cloned".
mkdir -p .kairos/migration/state/common
touch .kairos/migration/state/common/SPARE-ME
yq -i 'del(.template.in_progress)' .kairos/manifest.yaml
git commit -qam "clear in_progress block"
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf.out" 2> "$SANDBOX/pf.log"
expect "pre-flight exits 0 (no in_progress)"  test $? -eq 0
expect "stale PLAN.md swept"                  test ! -f .kairos/migration/PLAN.md
expect "stale state marker swept"             test ! -e .kairos/migration/state/stale-marker
expect "fresh template clone present"         test -f .kairos/migration/state/template/HEAD
expect "common mirror spared by the fresh sweep, like the template" \
  test -f .kairos/migration/state/common/SPARE-ME

expect "state dir excluded, so the clone stays out of git status" \
  test -z "$(git status --porcelain | grep '\.kairos/migration/state')"
expect "exclusion recorded in .git/info/exclude" \
  grep -qxF '.kairos/migration/state/' .git/info/exclude
expect "exclusion is idempotent across runs" \
  bash -c "test \"\$(grep -cxF '.kairos/migration/state/' .git/info/exclude)\" = 1"
expect "pre-flight left the working tree clean" \
  test -z "$(git status --porcelain --untracked-files=no)"

# =============================================================================
fi

if t "pre-flight.sh check 6 refuses a fresh sweep that cannot fully remove stale state"; then
# The bug this guards: an unchecked `|| true` on the sweep's `find -exec rm -rf`
# let a partially-failed remove (e.g. a root-owned leftover from a Docker-based
# test run) go unnoticed, and a fresh run then proceeded over whatever of the
# stale run's model.txt, qa-ledger, or context.env the sweep failed to clear —
# model.txt is actively ENFORCED downstream by log-spawn.sh. Reproduced here
# with a chmod-protected directory holding a file: the directory's own missing
# write permission (not the file's) is what stops `rm -rf` from clearing it.
if [[ "$(id -u)" -eq 0 ]]; then
  # Root bypasses the directory's chmod (DAC), so `rm -rf` genuinely succeeds
  # and every assertion below would test nothing — same skip-pass posture as
  # the unwritable-destination case in materialize.sh's block above.
  pass "undeletable-stale-state sweep case skipped (running as root, chmod 500 stays removable)"
else
# Isolated clone: this block leaves a locked, undeletable directory behind on
# purpose, which must never ride into the shared $COMP chain the later blocks
# depend on.
PFU=$SANDBOX/pf-undeletable
git clone -q "$COMP" "$PFU"
mkdir -p "$PFU/.kairos/migration/state"
touch "$PFU/.kairos/migration/PLAN.md"
yq -i 'del(.template.in_progress)' "$PFU/.kairos/manifest.yaml"
git -C "$PFU" add -A
git -C "$PFU" -c user.email=t@t -c user.name=t commit -qm "state for the undeletable-sweep test"

mkdir -p "$PFU/.kairos/migration/state/locked-leftover"
touch "$PFU/.kairos/migration/state/locked-leftover/inside.txt"
chmod 500 "$PFU/.kairos/migration/state/locked-leftover"

( cd "$PFU" && MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT \
    "$SKILL_DIR/scripts/pre-flight.sh" ) > "$SANDBOX/pf-undel.out" 2> "$SANDBOX/pf-undel.log"
PF_UNDEL_RC=$?
chmod 700 "$PFU/.kairos/migration/state/locked-leftover"   # restore so cleanup can remove it

if [[ "$PF_UNDEL_RC" -ne 0 ]]; then pass "a fresh sweep that cannot remove a locked leftover is refused"; else fail "a fresh sweep over a locked leftover was accepted"; fi
expect "the refusal names the surviving path" \
  grep -q 'locked-leftover' "$SANDBOX/pf-undel.log"
expect "the refusal reads as a FAIL, in the script's established style" \
  grep -q '^FAIL:' "$SANDBOX/pf-undel.log"
refute "the refused run emits no RUN/CACHE lines" \
  grep -qE '^(RUN|CACHE)=' "$SANDBOX/pf-undel.out"
expect "the locked leftover survived untouched (no partial gutting)" \
  test -e "$PFU/.kairos/migration/state/locked-leftover/inside.txt"
fi

# =============================================================================
fi

if t "the partial-block deadlock: pre-flight refuses it, in-progress.sh clear reopens it"; then
# THE regression test for the deadlock, and it needs BOTH halves — either alone
# re-admits it. A block that reads as LIVE but carries no previous_branch gets
# every fresh run refused (pre-flight check 3, which names abort as the remedy)
# while abort's own read hard-fails on the missing previous_branch. The only
# remedy that restores a state a fresh run accepts is clearing the block, so the
# pair asserted here is: refused → cleared → accepted.
cd "$COMP"

pf_fresh() { # pf_fresh <logfile> — a fresh-mode pre-flight, exit status returned
  MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
    > /dev/null 2> "$1"
}

# Shape 1: `in_progress: {}` — what Phase 8 leaves behind when a model empties
# the mapping instead of deleting the key, on a migration that SUCCEEDED.
# Shape 2: a block with branch: and target_sha: but no previous_branch: — what
# Phase 4 leaves behind when it writes the key before its children.
for shape in empty-mapping no-previous-branch; do
  case "$shape" in
    empty-mapping)
      yq -i '.template.in_progress = {}' .kairos/manifest.yaml ;;
    no-previous-branch)
      yq -i ".template.in_progress = {\"target_sha\": \"$TARGET\", \"branch\": \"topic/tester/template-update-test\"}" .kairos/manifest.yaml ;;
  esac
  git commit -qam "bad in_progress block ($shape)"

  pf_fresh "$SANDBOX/pf-dead-$shape.log"
  if [[ $? -ne 0 ]]; then
    pass "$shape: a fresh run is refused (the block reads as a live migration)"
  else
    fail "$shape: a fresh run is refused (the block reads as a live migration)"
  fi
  expect "$shape: the refusal names abort as the remedy" \
    grep -q "'abort'" "$SANDBOX/pf-dead-$shape.log"
  # ...and abort's OLD read cannot act on it: previous_branch is what it needs.
  expect "$shape: the block carries no previous_branch for abort to check out" \
    bash -c "test -z \"\$(yq -r '.template.in_progress.previous_branch // \"\"' .kairos/manifest.yaml)\""

  CLEARED=$(env -u PHASE_KEY ACTION=clear "$SKILL_DIR/scripts/in-progress.sh" 2>&1)
  expect "$shape: abort's arm clears the block (reports 'cleared')" \
    test "$CLEARED" = cleared
  git commit -qam "abort: clear the in_progress block"

  pf_fresh "$SANDBOX/pf-alive-$shape.log"
  if [[ $? -eq 0 ]]; then
    pass "$shape: a fresh run is accepted again — the deadlock is open"
  else
    fail "$shape: a fresh run is accepted again — the deadlock is open"
  fi
done

# =============================================================================
fi

if t "a NULL-VALUED in_progress key is a LIVE migration: refused, and nothing swept"; then
# THE fail-open the VALUE read hid. `yq -r '.template.in_progress // ""'` cannot
# tell a DELETED key from one left null — both come back "" — so `in_progress:`
# with nothing under it (a hand-edit, or a conflicted-merge restore of the
# committed manifest: the two sources reference/abort.md names) read as "no
# migration" in BOTH of pre-flight's reads at once. Check 3 then waved the fresh
# run through and check 6's sweep destroyed exactly the state continue needs —
# model.txt (which log-spawn.sh actively ENFORCES), context.env, the qa-ledger,
# and the TRACKED PLAN.md — and pre-flight exited 0. `{}` survived the value read
# and refused; null did not, and null is the shape an editor leaves behind.
# in-progress.sh's clear action states the rule the fix mirrors: has() "is the
# only check that tells a deleted key apart from one left empty or null".
cd "$COMP"
yq -i '.template.in_progress = null' .kairos/manifest.yaml
git commit -qam "null-valued in_progress block"
expect "the fixture really is a null-valued key, not a deleted one" \
  bash -c "test \"\$(yq -r '.template | has(\"in_progress\")' .kairos/manifest.yaml)\" = true"
expect "and the OLD value read would have called it absent (the fail-open, pinned)" \
  bash -c "test -z \"\$(yq -r '.template.in_progress // \"\"' .kairos/manifest.yaml)\""

# The live run's state, one recognisable value per file, so a survivor is told
# apart from a re-created empty. PLAN.md is COMMITTED: check 10 deletes the
# tracked file, and a tracked deletion is the damage the user cannot un-see.
mkdir -p .kairos/migration/state
printf 'strong=live-run-pin\ncoder=live-run-pin\nexecutor=live-run-pin\nbudget=balanced\n' \
  > .kairos/migration/state/model.txt
printf 'TARGET=live-run-target\n' > .kairos/migration/state/context.env
printf 'q1\tanswered-by-the-live-run\n' > .kairos/migration/state/qa-ledger.tsv
printf '# the live run plan\n' > .kairos/migration/PLAN.md
git add .kairos/migration/PLAN.md && git commit -qm "the live run's tracked PLAN.md"

MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-null.out" 2> "$SANDBOX/pf-null.log"
PF_NULL_RC=$?
if [[ "$PF_NULL_RC" -ne 0 ]]; then pass "a fresh run over a null-valued block is REFUSED"; else fail "a fresh run over a null-valued block was accepted (exit 0) — the sweep ran over a live migration"; fi
expect "the refusal offers continue and abort, like any other live block" \
  bash -c "grep -q \"'continue'\" '$SANDBOX/pf-null.log' && grep -q \"'abort'\" '$SANDBOX/pf-null.log'"
refute "the refused run emits no RUN/CACHE lines" \
  grep -qE '^(RUN|CACHE)=' "$SANDBOX/pf-null.out"
# ...and NOTHING was swept: each file still carries the live run's own content.
expect "model.txt survived un-swept (log-spawn.sh ENFORCES this pin)" \
  grep -qx 'strong=live-run-pin' .kairos/migration/state/model.txt
expect "context.env survived un-overwritten (check 9 never ran)" \
  grep -qx 'TARGET=live-run-target' .kairos/migration/state/context.env
expect "the qa-ledger's answers survived" \
  grep -q 'answered-by-the-live-run' .kairos/migration/state/qa-ledger.tsv
expect "the TRACKED PLAN.md was not deleted (check 10 never ran)" \
  test -f .kairos/migration/PLAN.md
expect "and no tracked deletion was left in the working tree" \
  bash -c "test -z \"\$(git status --porcelain --untracked-files=no)\""

# The deadlock stays openable for this shape too: has() sees the null key, so
# abort's clear is not a no-op, and a fresh run is accepted once it is really gone.
CLEARED=$(env -u PHASE_KEY ACTION=clear "$SKILL_DIR/scripts/in-progress.sh" 2>&1)
expect "abort's arm clears a NULL-valued block (reports 'cleared')" \
  test "$CLEARED" = cleared
git commit -qam "abort: clear the null-valued block"
# The block is gone, but the planted qa-ledger carries answers with no PREV_SHA
# anchored — the pre-Phase-4 interlock (check 6) refuses to sweep them SILENTLY
# and names its escape hatch. In the real flow abort's salvage precedes the
# clear, so acknowledging with SWEEP_STALE_RUN=1 is the sanctioned stale path.
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > /dev/null 2> "$SANDBOX/pf-null-ledger.log"
if [[ $? -ne 0 ]]; then pass "block cleared, but the unpromoted ledger still refuses a silent sweep"; else fail "a fresh run swept an unpromoted pre-Phase-4 ledger without acknowledgment"; fi
expect "that refusal names the SWEEP_STALE_RUN=1 escape hatch" \
  grep -q 'SWEEP_STALE_RUN=1' "$SANDBOX/pf-null-ledger.log"
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT SWEEP_STALE_RUN=1 "$SKILL_DIR/scripts/pre-flight.sh" \
  > /dev/null 2> "$SANDBOX/pf-null-after.log"
if [[ $? -eq 0 ]]; then pass "with the key really deleted and the sweep acknowledged a fresh run is accepted again"; else fail "a fresh run was still refused after the block was cleared and the sweep acknowledged"; fi
refute "and NOW the stale state is swept — the guard is not vacuous" \
  test -e .kairos/migration/state/model.txt
refute "the stale tracked PLAN.md is swept too, once the key is really gone" \
  test -f .kairos/migration/PLAN.md
git commit -qam "sweep the stale PLAN.md"   # restore a clean tree for later blocks

# =============================================================================
fi

if t "previous_sha: capture, abort guard, and squash target (doc contract)"; then
# Under --no-branch the previous_branch NAME is worthless as a rollback point —
# its ref moves with every migration commit — so abort and --squash-on-finish
# are only correct against a SHA captured at Phase 4. The capture and both
# consumers are orchestrator prose, so the contract is asserted on the docs,
# the same way the previous_branch chain always has been.
P4=$SKILL_DIR/phases/4-migration-branch.md
expect "phase 4 captures PREV_SHA beside PREV_BRANCH" \
  grep -qF 'PREV_SHA=$(git rev-parse HEAD)' "$P4"
expect "phase 4 records PREV_SHA into context.env alongside PREV_BRANCH" \
  grep -qF 'PREV_BRANCH=$PREV_BRANCH PREV_SHA=$PREV_SHA' "$P4"
expect "phase 4 sets the in-progress block through its writer script, not by hand" \
  bash -c "grep -F 'scripts/in-progress.sh' '$P4' | grep -q 'ACTION=set' || grep -B4 -F 'scripts/in-progress.sh' '$P4' | grep -q 'ACTION=set'"
expect "the writer call passes PREV_SHA (previous_sha's only source)" \
  grep -qF 'PREV_SHA=$PREV_SHA' "$P4"
expect "previous_sha is written on EVERY path (branch mode or not)" \
  bash -c "grep -F 'previous_sha' '$P4' | grep -q 'EVERY path'"
refute "phase 4 no longer describes the block's YAML shape beside the call (a hand-editable copy)" \
  grep -qE '^\s+in_progress:' "$P4"
expect "branch: is omitted from the in-progress block under --no-branch" \
  bash -c "grep -F 'branch:' '$P4' | grep -qiE 'omit|unset|empty'"
expect "the --no-branch path still records previous_sha" \
  bash -c "grep -F -- '--no-branch' '$P4' | grep -qF 'previous_sha: \$PREV_SHA'"

AB=$SKILL_DIR/reference/abort.md
expect "abort reads previous_sha from the manifest" \
  grep -qF 'in_progress.previous_sha' "$AB"
expect "abort's branch delete is guarded (never deletes the checked-out branch)" \
  grep -qF 'if [ -n "$BRANCH" ] && [ "$BRANCH" != "$PREV" ]; then git branch -D "$BRANCH"; fi' "$AB"
expect "abort under --no-branch offers a reset to previous_sha" \
  grep -qF 'git reset --hard "$PREV_SHA"' "$AB"
expect "the --no-branch reset stays user-confirmed (destructive on the user's branch)" \
  grep -q 'only after the user explicitly confirms' "$AB"

F8=$SKILL_DIR/phases/8-finalize.md
expect "phase 8 re-reads previous_sha before removing the in-progress block" \
  grep -qF 'in_progress.previous_sha' "$F8"
expect "the squash resets to the SHA in both branch modes" \
  grep -qF 'git reset --soft $PREV_SHA' "$F8"
refute "the squash no longer resets to the branch name" \
  grep -qF 'git reset --soft $PREV_BRANCH' "$F8"
refute "the --no-branch squash refusal is gone (previous_sha removed its only justification)" \
  grep -qi 'unsupported' "$F8"
expect "continue mode re-reads TEMPLATE_PATH from context.env (re-arms the wrong-target tripwire)" \
  grep -qF 'TEMPLATE_PATH' "$SKILL_DIR/reference/continue.md"
fi

if t "a merge-file ERROR on a rename-paired row records the pre-rename path"; then
# git merge-file exit >=128 leaves the tree deliberately untouched — but for a
# rename-flavored row that means nothing exists at $dest and the component's
# copy still sits at the OLD path. A merge-errors.txt row naming only $dest sent
# the orchestrator to inspect a path that does not exist, while the old copy
# rode silently into the structural commit as a duplicate no artifact named —
# the same hazard binaries.txt's rename-aware append already closes. The row now
# appends the pre-rename old path as a second TAB field, same shape.
#
# rc>=128 is an ENVIRONMENT error (unreadable input, OOM) that no file content
# reaches deterministically — git's own binary sniff shares the script's ~8KB
# window — so it is forced the way the suite fakes the kairos CLI: a `git` shim
# ahead of PATH that delegates everything to the real git except `merge-file`,
# which exits 255.
ME_SYNTH=$SANDBOX/merr-synth
mkdir -p "$ME_SYNTH" && git -C "$ME_SYNTH" init -q -b main
seq 1 5 | sed 's/^/moved line /' > "$ME_SYNTH/oldname.txt"
seq 1 5 | sed 's/^/plain line /' > "$ME_SYNTH/plain.txt"
git -C "$ME_SYNTH" add -A && git -C "$ME_SYNTH" commit -qm me-base
git -C "$ME_SYNTH" tag -f kairos-base >/dev/null
ME_BASE=$(git -C "$ME_SYNTH" rev-parse HEAD)
git -C "$ME_SYNTH" mv oldname.txt newname.txt
sed 's/moved line 3/moved line three TEMPLATE/' "$ME_SYNTH/newname.txt" > "$ME_SYNTH/newname.new" \
  && mv "$ME_SYNTH/newname.new" "$ME_SYNTH/newname.txt"
sed 's/plain line 3/plain line three TEMPLATE/' "$ME_SYNTH/plain.txt" > "$ME_SYNTH/plain.new" \
  && mv "$ME_SYNTH/plain.new" "$ME_SYNTH/plain.txt"
git -C "$ME_SYNTH" add -A && git -C "$ME_SYNTH" commit -qm me-target
git -C "$ME_SYNTH" tag -f kairos-target >/dev/null
ME_TARGET=$(git -C "$ME_SYNTH" rev-parse HEAD)

ME_COMP=$SANDBOX/merr-comp
mkdir -p "$ME_COMP" && cd "$ME_COMP" && git init -q -b main
git -C "$ME_SYNTH" show "kairos-base:oldname.txt" | sed 's/moved line 4/moved line four MINE/' > oldname.txt
git -C "$ME_SYNTH" show "kairos-base:plain.txt"   | sed 's/plain line 4/plain line four MINE/' > plain.txt
cp oldname.txt "$SANDBOX/me-oldname.orig"
git add -A && git commit -qm me-comp
ME_RUN=$SANDBOX/merr-run; mkdir -p "$ME_RUN"

# A real classification first, so the tree binding is valid — then the rows are
# crafted (the ST fixture's pattern): one rename-paired merge row, one plain one.
SYNTH=$ME_SYNTH CACHE=$ME_SYNTH BASE=$ME_BASE TARGET=$ME_TARGET RUN=$ME_RUN \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" > /dev/null 2> "$SANDBOX/me-bm.log"
expect "the merge-error fixture classifies" test $? -eq 0
{ printf 'merge-pipeline\tM\tnewname.txt\tnewname.txt\toldname.txt\t\tpaired-by-dir-rename\n'
  printf 'merge-pipeline\tM\tplain.txt\tplain.txt\t\t\t\n'
} > "$ME_RUN/classification.tsv"

ME_SHIM=$SANDBOX/merr-gitshim; mkdir -p "$ME_SHIM"
ME_REALGIT=$(command -v git)
printf '#!/usr/bin/env bash\nif [ "$1" = merge-file ]; then exit 255; fi\nexec %s "$@"\n' "$ME_REALGIT" > "$ME_SHIM/git"
chmod +x "$ME_SHIM/git"

PATH="$ME_SHIM:$PATH" SYNTH=$ME_SYNTH BASE=$ME_BASE TARGET=$ME_TARGET RUN=$ME_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > "$SANDBOX/me-merge.out" 2> "$SANDBOX/me-merge.log"
expect "a merge-file error is recorded, not a run failure (exit 0)" test $? -eq 0
expect "the rename-paired error row carries dest AND the pre-rename old path" \
  grep -qx "newname.txt${TAB:-$(printf '\t')}oldname.txt" "$ME_RUN/merge-errors.txt"
expect "a non-rename error row stays the single field it always was" \
  grep -qx 'plain.txt' "$ME_RUN/merge-errors.txt"
refute "nothing was written at the rename destination" test -e newname.txt
expect "the component's copy still sits untouched at the old path" \
  cmp -s oldname.txt "$SANDBOX/me-oldname.orig"
refute "the errored rename was not recorded as renamed" test -s "$ME_RUN/renamed.txt"
refute "the errored rows were not recorded as cleanly merged" test -s "$ME_RUN/clean-merged.txt"
cd "$COMP"
fi

if t "the re-run guard survives a conflicts.txt with NO trailing newline"; then
# The guard's read loop was the ONLY one of this script's three conflicts-file
# loops missing `|| [ -n "$cf" ]` — the pre-scan and the enactment loop both carry
# it, and the header says why. So a conflicts.txt whose LAST line lacks a trailing
# newline is a row `read` returns non-zero on: the loop exited before ever testing
# that file, the guard that exists to stop marker nesting waved the re-run
# through, and the second Phase 5 read the still-marked working-tree copy back in
# as "ours" — two `<<<<<<< ours` in one file, the exact corruption the guard is
# for. This script's own writes always end in a newline; the shape arrives out of
# band, from an operator or an agent trimming resolved entries out of the list by
# hand with an editor that drops the final newline. Same guard, same block shape
# as the leading-dash case above; the fixture is its own so nothing here depends
# on which paths a shared chain happens to have left conflicted.
NLC_SYNTH=$SANDBOX/nlconf-synth
mkdir -p "$NLC_SYNTH" && git -C "$NLC_SYNTH" init -q -b main
printf 'alpha\nbeta\ngamma\n' > "$NLC_SYNTH/conf.txt"
git -C "$NLC_SYNTH" add -A && git -C "$NLC_SYNTH" commit -qm nlc-base
git -C "$NLC_SYNTH" tag -f kairos-base >/dev/null 2>&1
NLC_BASE=$(git -C "$NLC_SYNTH" rev-parse HEAD)
printf 'alpha\nbeta-TEMPLATE\ngamma\n' > "$NLC_SYNTH/conf.txt"
git -C "$NLC_SYNTH" add -A && git -C "$NLC_SYNTH" commit -qm nlc-target
git -C "$NLC_SYNTH" tag -f kairos-target >/dev/null 2>&1
NLC_TARGET=$(git -C "$NLC_SYNTH" rev-parse HEAD)

NLC_COMP=$SANDBOX/nlconf-comp
mkdir -p "$NLC_COMP" && cd "$NLC_COMP" && git init -q -b main
printf 'alpha\nbeta-MINE\ngamma\n' > conf.txt   # same line the template changed -> conflict
git add -A && git commit -qm nlc-comp
NLC_RUN=$SANDBOX/nlconf-run; mkdir -p "$NLC_RUN"

# A real classification first, so the tree binding is valid — then the one row is
# crafted (the ME fixture's pattern just above).
SYNTH=$NLC_SYNTH CACHE=$NLC_SYNTH BASE=$NLC_BASE TARGET=$NLC_TARGET RUN=$NLC_RUN \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" > /dev/null 2> "$SANDBOX/nlc-bm.log"
expect "the newline-less-conflicts fixture classifies" test $? -eq 0
printf 'merge-pipeline\tM\tconf.txt\tconf.txt\t\t\t\n' > "$NLC_RUN/classification.tsv"

SYNTH=$NLC_SYNTH BASE=$NLC_BASE TARGET=$NLC_TARGET RUN=$NLC_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/nlc-sm.log"
expect "the first merge exits 0" test $? -eq 0
expect "conf.txt conflicted and was recorded" grep -qx 'conf.txt' "$NLC_RUN/conflicts.txt"
expect "the working-tree copy carries live diff3 markers" grep -qE '^<{7} ' conf.txt

# Strip the trailing newline: one row, no terminator — what a hand-trim leaves.
printf '%s' "$(cat "$NLC_RUN/conflicts.txt")" > "$NLC_RUN/conflicts.nonl"
mv "$NLC_RUN/conflicts.nonl" "$NLC_RUN/conflicts.txt"
# `$(...)` strips a trailing newline, so a non-empty last byte IS the missing one.
expect "the fixture really has no trailing newline" \
  bash -c "test -n \"\$(tail -c1 '$NLC_RUN/conflicts.txt')\""
expect "and the row itself is still there" grep -q 'conf.txt' "$NLC_RUN/conflicts.txt"

NLC_MARKS_BEFORE=$(grep -c '^<<<<<<< ' conf.txt || true)
SYNTH=$NLC_SYNTH BASE=$NLC_BASE TARGET=$NLC_TARGET RUN=$NLC_RUN \
  PHASE_KEY=$PK_STRUCTURAL "$SKILL_DIR/scripts/structural-merge.sh" \
  > /dev/null 2> "$SANDBOX/nlc-rerun.log"
NLC_RERUN_RC=$?
if [[ "$NLC_RERUN_RC" -ne 0 ]]; then
  pass "the re-run guard reads the final partial line and refuses"
else
  fail "the re-run guard dropped the newline-less final row and let the re-run through (exit 0)"
fi
expect "the refusal names the still-marked file" grep -qF 'conf.txt' "$SANDBOX/nlc-rerun.log"
expect "the refusal points at the path-scoped restore, not a blanket reset" \
  grep -qF "git checkout -- . ':(exclude).kairos/migration-log.md'" "$SANDBOX/nlc-rerun.log"
# Pin the FULL three-exclusion form, not just the migration-log prefix: dropping the
# intent.md exclusion reverts a tracked-modified standing-intent re-confirmation
# (nothing regenerates it — reference/continue.md). A prefix-only grep passes the
# deficient one-exclusion form, so assert intent.md and manifest.yaml are excluded too.
expect "the restore excludes .kairos/intent.md (protects the tracked-modified re-confirmation)" \
  grep -qF "':(exclude).kairos/intent.md'" "$SANDBOX/nlc-rerun.log"
expect "the restore excludes .kairos/manifest.yaml (the third by-design exclusion)" \
  grep -qF "':(exclude).kairos/manifest.yaml'" "$SANDBOX/nlc-rerun.log"
NLC_MARKS_AFTER=$(grep -c '^<<<<<<< ' conf.txt || true)
if [[ "$NLC_MARKS_AFTER" = "$NLC_MARKS_BEFORE" ]]; then
  pass "no markers were nested by the refused re-run (count unchanged)"
else
  fail "marker count changed on the refused re-run ($NLC_MARKS_BEFORE -> $NLC_MARKS_AFTER) — markers nested"
fi
expect "the refusal left the previous run's conflicts.txt intact for the operator" \
  grep -q 'conf.txt' "$NLC_RUN/conflicts.txt"
cd "$COMP"
fi

if t "pre-flight.sh sees the frontend source under EITHER key, and stays silent without one"; then
# `web/` is a SECOND, template-shaped upgrade source with its own repo and its own
# SHAs (docs/prd-generalized-upgrade-sources-and-frontend-migration.md). Three
# things are asserted here, and each has a distinct failure mode:
#   * a recorded `frontend:` block reaches the anchor — a value that lives only in
#     this stdout is gone by the next tool call, and the consent step runs hours
#     later;
#   * `web/` with NO block is reported as a bootstrap CANDIDATE, never as a
#     decision;
#   * a component with neither emits NOTHING. That silence is the contract for
#     backend-only components (story 21): a single stray line here is a prompt the
#     user was promised they would not see.
FEP=$SANDBOX/fe-comp
mkdir -p "$FEP" && cd "$FEP" && git init -q -b main
mkdir -p .kairos
cat > .kairos/manifest.yaml <<EOF
name: fecomp
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
frontend:
  repo: git@bitbucket.org:ifs-pd/kairos-frontend.git
  path: template/react
  template: react
  branch: main
  sha: 2222222222222222222222222222222222222222
EOF
mkdir -p web/src && echo 'export const x = 1' > web/src/main.ts
git add -A && git commit -qm fe-comp

MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-fe.out" 2> "$SANDBOX/pf-fe.log"
expect "pre-flight exits 0 on a component with a recorded frontend block" test $? -eq 0
# The manifest names the old Bitbucket SSH host; pre-flight emits the current one.
expect "it emits the frontend repo, on the current Bitbucket SSH host" \
  grep -qxF 'FRONTEND_REPO=git@ssh.bitbucket.org:ifs-pd/kairos-frontend.git' "$SANDBOX/pf-fe.out"
expect "it emits the frontend baseline" grep -qx 'FRONTEND_SHA=2222222222222222222222222222222222222222' "$SANDBOX/pf-fe.out"
expect "it emits the frontend branch"   grep -qx 'FRONTEND_BRANCH=main' "$SANDBOX/pf-fe.out"
expect "it emits the MODULE KEY, not a path (nothing hardcodes react)" \
  grep -qx 'FRONTEND_TEMPLATE=react' "$SANDBOX/pf-fe.out"
expect "it emits the module's subtree path" grep -qx 'FRONTEND_MODULE_PATH=template/react' "$SANDBOX/pf-fe.out"
# mount: is optional in the manifest and the DEFAULT is materialized here, once, so
# no later reader can default it differently.
expect "an omitted mount: defaults to web/ at pre-flight" grep -qx 'FRONTEND_MOUNT=web/' "$SANDBOX/pf-fe.out"
refute "a component WITH a block is not also reported as a bootstrap candidate" \
  grep -q '^FRONTEND_BOOTSTRAP=' "$SANDBOX/pf-fe.out"
for k in FRONTEND_REPO FRONTEND_SHA FRONTEND_BRANCH FRONTEND_TEMPLATE FRONTEND_MODULE_PATH FRONTEND_MOUNT; do
  expect "$k reaches \$RUN/context.env (the consent step runs hours later)" \
    grep -q "^$k=" .kairos/migration/state/context.env
done

# A non-default mount is recorded as given — the default is omitted, not written.
yq -i '.frontend.mount = "apps/ui/"' .kairos/manifest.yaml
git commit -qam "non-default mount"
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-fe-mount.out" 2> /dev/null
expect "a declared mount is emitted verbatim" grep -qx 'FRONTEND_MOUNT=apps/ui/' "$SANDBOX/pf-fe-mount.out"

# web/ present, no block: a pre-existing component whose baseline was never
# recorded. A CANDIDATE for Phase 2's bootstrap, and nothing more.
FEB=$SANDBOX/fe-boot
mkdir -p "$FEB" && cd "$FEB" && git init -q -b main
mkdir -p .kairos web/src && echo 'x' > web/src/main.ts && echo '{}' > web/package.json
cat > .kairos/manifest.yaml <<EOF
name: bootcomp
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
EOF
git add -A && git commit -qm fe-boot
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-feboot.out" 2> "$SANDBOX/pf-feboot.log"
expect "pre-flight exits 0 on a web/-but-no-block component" test $? -eq 0
expect "it reports the bootstrap candidate" grep -qx 'FRONTEND_BOOTSTRAP=web/' "$SANDBOX/pf-feboot.out"
expect "the candidate reaches the anchor" \
  grep -qx 'FRONTEND_BOOTSTRAP=web/' .kairos/migration/state/context.env
refute "no block means no recorded fields are invented" \
  grep -q '^FRONTEND_REPO=' "$SANDBOX/pf-feboot.out"

# Neither: total silence. This is the assertion a stray unconditional echo breaks.
FEN=$SANDBOX/fe-none
mkdir -p "$FEN" && cd "$FEN" && git init -q -b main
mkdir -p .kairos
cat > .kairos/manifest.yaml <<EOF
name: backendonly
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
EOF
git add -A && git commit -qm fe-none
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-fenone.out" 2> "$SANDBOX/pf-fenone.log"
expect "pre-flight exits 0 on a backend-only component" test $? -eq 0
refute "a component with no web/ and no block emits no FRONTEND_ line at all" \
  grep -q 'FRONTEND_' "$SANDBOX/pf-fenone.out"
refute "and records none either" \
  grep -q 'FRONTEND_' .kairos/migration/state/context.env

# The template's own backend `web/` shell (Dockerfile, configs/, entrypoint/, no
# package.json) is not a frontend: silence, exactly as with no web/ at all.
# reproduced pre-fix: FRONTEND_BOOTSTRAP=web/ on this tree, so every template-born
# backend-only component was asked about a frontend it does not have.
FES=$SANDBOX/fe-shell
mkdir -p "$FES" && cd "$FES" && git init -q -b main
mkdir -p .kairos web/configs web/entrypoint
printf 'FROM golang:1.25-alpine\n' > web/Dockerfile
printf 'x = 1\n' > web/configs/config.toml
printf 'package main\n' > web/entrypoint/main.go
cat > .kairos/manifest.yaml <<EOF
name: shellonly
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
EOF
git add -A && git commit -qm fe-shell
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-feshell.out" 2> "$SANDBOX/pf-feshell.log"
expect "pre-flight exits 0 on a component with only the template web/ shell" test $? -eq 0
refute "a web/ without package.json is not a bootstrap candidate" \
  grep -q 'FRONTEND_' "$SANDBOX/pf-feshell.out"
refute "and nothing frontend-shaped reaches the anchor" \
  grep -q 'FRONTEND_' .kairos/migration/state/context.env
cd "$COMP"
fi

if t "pre-flight.sh treats the two in_progress keys as ONE live migration"; then
# Every value an in_progress block carries — which branch, which target, which
# rollback SHA — has exactly one answer per component. So a frontend block must
# refuse a fresh run exactly as a template block does (a live frontend run owns
# $RUN just as hard), the refusal must SAY which source is live (continue and abort
# both act on one source's block, and inferring it from the branch name is the
# guess this line removes), and a manifest carrying both must be refused rather
# than silently resolved to one of them.
FEL=$SANDBOX/fe-live
mkdir -p "$FEL" && cd "$FEL" && git init -q -b main
mkdir -p .kairos
cat > .kairos/manifest.yaml <<EOF
name: felive
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
frontend:
  repo: file://$TPL
  path: template/react
  template: react
  branch: main
  sha: 2222222222222222222222222222222222222222
  in_progress:
    target_sha: 3333333333333333333333333333333333333333
    branch: topic/tester/frontend-update-333
    previous_branch: main
    previous_sha: 4444444444444444444444444444444444444444
EOF
git add -A && git commit -qm fe-live
mkdir -p .kairos/migration/state && touch .kairos/migration/PLAN.md

MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-felive.out" 2> "$SANDBOX/pf-felive.log"
PF_FELIVE_RC=$?
if [[ "$PF_FELIVE_RC" -ne 0 ]]; then
  pass "a fresh run over a live FRONTEND migration is refused"
else
  fail "a fresh run over a live FRONTEND migration was accepted (only .template was being read)"
fi
expect "the refusal names the live source" grep -qF 'a frontend migration to' "$SANDBOX/pf-felive.log"
expect "the refusal names the frontend target" \
  grep -qF '3333333333333333333333333333333333333333' "$SANDBOX/pf-felive.log"
expect "the live source is emitted machine-readably" \
  grep -qx 'IN_PROGRESS_SOURCE=frontend' "$SANDBOX/pf-felive.out"
expect "a live frontend run's PLAN.md survives the refused fresh run" test -f .kairos/migration/PLAN.md
expect "and its state dir survives too" test -d .kairos/migration/state
# Continue is the sanctioned way past it, for a frontend run as for a template one.
MODE=continue TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-felive2.out" 2> "$SANDBOX/pf-felive2.log"
expect "continue mode passes over a live frontend migration" test $? -eq 0
expect "continue preserved the frontend run's PLAN.md" test -f .kairos/migration/PLAN.md

# Both keys live: unanswerable, so refused. Unproducible through the scripts
# (in-progress.sh ACTION=set refuses it), which is why the refusal names the
# hand-edit shapes rather than a workflow.
yq -i '.template.in_progress = {"target_sha": "5555555555555555555555555555555555555555", "previous_branch": "main", "previous_sha": "6666666666666666666666666666666666666666"}' .kairos/manifest.yaml
git commit -qam "two live blocks"
MODE=fresh TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > "$SANDBOX/pf-feboth.out" 2> "$SANDBOX/pf-feboth.log"
PF_FEBOTH_RC=$?
if [[ "$PF_FEBOTH_RC" -ne 0 ]]; then
  pass "a manifest carrying BOTH in_progress blocks is refused"
else
  fail "a manifest carrying BOTH in_progress blocks was accepted"
fi
expect "the two-block refusal names both keys" \
  bash -c "grep -qF 'template.in_progress and frontend.in_progress' '$SANDBOX/pf-feboth.log'"
# MODE=continue must not wave it through either: continue picks ONE source's block.
MODE=continue TEMPLATE_PATH=$TPL PHASE_KEY=$PK_PREFLIGHT "$SKILL_DIR/scripts/pre-flight.sh" \
  > /dev/null 2> "$SANDBOX/pf-feboth2.log"
PF_FEBOTH2_RC=$?
if [[ "$PF_FEBOTH2_RC" -ne 0 ]]; then
  pass "continue mode refuses the two-block state as well"
else
  fail "continue mode accepted the two-block state (it must pick exactly one source)"
fi
cd "$COMP"
fi

if t "pre-flight.sh normalizes --frontend-path to the enclosing git toplevel"; then
# --frontend-path canonically points at the frontend MONOREPO ROOT: the git history,
# .kairos-updates/config.yaml and the per-module upgrade-files all live there, and the
# module subtree is not a git repo of its own. A path INSIDE the checkout is the
# natural thing to type ("the react template is over here"), so it is accepted and
# normalized — the two spellings must resolve identically. A path in no git work tree
# is refused outright: there is no history to migrate against, and a silent fallback
# to the remote is exactly what the flag exists to avoid.
FEREPO=$SANDBOX/fe-repo
mkdir -p "$FEREPO/template/react/src" "$FEREPO/template/vue/src" "$FEREPO/.kairos-updates"
printf 'modules:\n  react:\n    kind: template\n    path: template/react\n' > "$FEREPO/.kairos-updates/config.yaml"
echo 'export const a = 1' > "$FEREPO/template/react/src/main.ts"
echo 'export const b = 1' > "$FEREPO/template/vue/src/main.ts"
# Physical path: pre-flight normalizes via `git rev-parse --show-toplevel`, which
# prints the physical path, and $SANDBOX sits under a symlinked /var on macOS.
FEREPO=$(cd "$FEREPO" && pwd -P)
git -C "$FEREPO" init -q -b main
git -C "$FEREPO" add -A && git -C "$FEREPO" commit -qm fe-repo-base
git -C "$FEREPO" checkout -q -b feat/fe-draft

FEC=$SANDBOX/fe-path-comp
mkdir -p "$FEC/.kairos" && cd "$FEC" && git init -q -b main
cat > .kairos/manifest.yaml <<EOF
name: fepathcomp
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
frontend:
  repo: file://$FEREPO
  path: template/react
  template: react
  branch: main
  sha: 2222222222222222222222222222222222222222
EOF
git add -A && git commit -qm fe-path-comp

MODE=fresh TEMPLATE_PATH=$TPL FRONTEND_PATH=$FEREPO PHASE_KEY=$PK_PREFLIGHT \
  "$SKILL_DIR/scripts/pre-flight.sh" > "$SANDBOX/pf-fpr.out" 2> "$SANDBOX/pf-fpr.log"
expect "pre-flight exits 0 with --frontend-path at the monorepo root" test $? -eq 0
expect "the root path is emitted as-is" grep -qx "FRONTEND_PATH=$FEREPO" "$SANDBOX/pf-fpr.out"
expect "the local checkout's branch is emitted (Phase 2's rule 2)" \
  grep -qx 'FRONTEND_LOCAL_BRANCH=feat/fe-draft' "$SANDBOX/pf-fpr.out"
expect "both reach the anchor" \
  bash -c "grep -qx 'FRONTEND_PATH=$FEREPO' .kairos/migration/state/context.env && grep -qx 'FRONTEND_LOCAL_BRANCH=feat/fe-draft' .kairos/migration/state/context.env"

# The SAME repo, addressed by its module subtree: must resolve identically.
MODE=fresh TEMPLATE_PATH=$TPL FRONTEND_PATH=$FEREPO/template/react PHASE_KEY=$PK_PREFLIGHT \
  "$SKILL_DIR/scripts/pre-flight.sh" > "$SANDBOX/pf-fps.out" 2> "$SANDBOX/pf-fps.log"
expect "pre-flight exits 0 with --frontend-path at the module subtree" test $? -eq 0
expect "the subtree path normalizes to the same toplevel" \
  grep -qx "FRONTEND_PATH=$FEREPO" "$SANDBOX/pf-fps.out"
expect "the normalization is stated, not silent" \
  bash -c "grep -qF 'normalized to the enclosing git toplevel' '$SANDBOX/pf-fps.log'"
refute "pointing at the manifest's OWN module warns about nothing" \
  grep -q 'WARNING: --frontend-path' "$SANDBOX/pf-fps.log"

# A subtree that is not the module this component was built from: the one mistake
# normalization would otherwise hide.
MODE=fresh TEMPLATE_PATH=$TPL FRONTEND_PATH=$FEREPO/template/vue PHASE_KEY=$PK_PREFLIGHT \
  "$SKILL_DIR/scripts/pre-flight.sh" > "$SANDBOX/pf-fpv.out" 2> "$SANDBOX/pf-fpv.log"
expect "a mismatched subtree still exits 0 (advisory, not fatal)" test $? -eq 0
expect "the mismatch is surfaced" \
  bash -c "grep -qF \"pointed at the subtree 'template/vue'\" '$SANDBOX/pf-fpv.log'"
expect "and it names the module the manifest actually selects" \
  bash -c "grep -F 'WARNING: --frontend-path' '$SANDBOX/pf-fpv.log' | grep -qF 'template/react'"
expect "the run still uses the normalized toplevel" \
  grep -qx "FRONTEND_PATH=$FEREPO" "$SANDBOX/pf-fpv.out"

# Not a git work tree at all — refused, never degraded to the remote.
FENG=$SANDBOX/fe-not-git
mkdir -p "$FENG/template/react"
MODE=fresh TEMPLATE_PATH=$TPL FRONTEND_PATH=$FENG PHASE_KEY=$PK_PREFLIGHT \
  "$SKILL_DIR/scripts/pre-flight.sh" > "$SANDBOX/pf-fpn.out" 2> "$SANDBOX/pf-fpn.log"
PF_FPN_RC=$?
if [[ "$PF_FPN_RC" -ne 0 ]]; then
  pass "a --frontend-path outside any git work tree is refused"
else
  fail "a --frontend-path outside any git work tree was accepted"
fi
expect "the refusal explains that the subtree is not a repo of its own" \
  bash -c "grep -qF 'not inside a git work tree' '$SANDBOX/pf-fpn.log'"
refute "the refused run recorded no FRONTEND_PATH" \
  bash -c "grep -q '^FRONTEND_PATH=' .kairos/migration/state/context.env 2>/dev/null && ! grep -qx 'FRONTEND_PATH=$FEREPO' .kairos/migration/state/context.env"
cd "$COMP"
fi

if t "build-manifest.sh collects ONLY the run's module upgrade-files over a configured source's range"; then
# A configured source repo files each module's upgrade-files at the REPO ROOT under the
# module name, outside the subtree it mounts. The fixture puts a SOLID upgrade-file
# inside the react run's BASE..TARGET range on purpose: collecting it would manufacture
# a migration step for a template this component was never built from — and the planner
# has no way to tell that from a real one.
setup_frontend_fixture

FMC=$SANDBOX/fe-mod-comp
mkdir -p "$FMC/.kairos" && cd "$FMC" && git init -q -b main
printf 'name: femodcomp\ntemplate:\n  repo: file://%s\n  sha: %s\n  branch: main\n' \
  "$TPL" "$BASE" > .kairos/manifest.yaml
git add -A && git commit -qm fe-mod-comp
add_frontend_to_component "$FMC"

# The synthetic base/target pair the classifier diffs: the module subtree at each end,
# mapped onto the mount. Built directly here — this block is about WHICH upgrade-files
# the history walks collect, so the two sides only have to be a well-formed pair.
FMS=$SANDBOX/fe-mod-synth
mkdir -p "$FMS" && cd "$FMS" && git init -q -b main
rm -rf web && mkdir -p web
git -C "$FRONTEND_REPO_DIR" archive "$FRONTEND_BASE_SHA:template/react" | tar -x -C web
git add -A && git commit -qm "synthetic base" && git tag -f kairos-base
rm -rf web && mkdir -p web
git -C "$FRONTEND_REPO_DIR" archive "$FRONTEND_TARGET_SHA:template/react" | tar -x -C web
git add -A && git commit -qm "synthetic target" && git tag -f kairos-target

cd "$FMC"
FM_RUN=$FMC/.kairos/migration/state; mkdir -p "$FM_RUN"
RUN=$FM_RUN CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_BASE_SHA TARGET=$FRONTEND_TARGET_SHA \
  SYNTH=$FMS MODULE=react PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" \
  > /dev/null 2> "$SANDBOX/fm-bm.log"
expect "the module-scoped classification exits 0" test $? -eq 0
expect "the run's own module upgrade-file is collected" \
  grep -qx '\.kairos-updates/react/20260115T000000-app-export-renamed\.md' "$FM_RUN/upgrades-added.txt"
refute "the sibling module's in-range upgrade-file is NOT collected" \
  grep -q solid "$FM_RUN/upgrades-added.txt"
expect "its body is snapshotted under its basename, exactly as a template one is" \
  grep -q AppRoot "$FM_RUN/upgrades/20260115T000000-app-export-renamed.md"
refute "and the sibling's body is never snapshotted into the shared dir" \
  test -f "$FM_RUN/upgrades/20260110T000000-solid-app-export-renamed.md"
refute "the sibling module never reaches the amended list either" \
  grep -q solid "$FM_RUN/upgrades-modified.txt"
expect "the scoping is stated, not silent" \
  bash -c "grep -qF 'scoped to .kairos-updates/react/' '$SANDBOX/fm-bm.log'"
refute "MODULE=react does not collect the library-kind file (that's collect-lib.sh's job)" \
  grep -q net-rest-delete-renamed "$FM_RUN/upgrades-added.txt"

# collect-lib.sh always collects kind:library files over the same BASE..TARGET,
# irrespective of which template MODULE the classification walked.
printf 'RUN_SOURCE=frontend\n' > "$FM_RUN/context.env"
RUN=$FM_RUN CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_BASE_SHA TARGET=$FRONTEND_TARGET_SHA \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/collect-lib.sh" \
  > /dev/null 2> "$SANDBOX/fm-cl.log"
expect "collect-lib.sh on a react-scoped run exits 0" test $? -eq 0
expect "the library-kind upgrade-file is collected irrespective of MODULE=react" \
  grep -qx '\.kairos-updates/lib/20260116T000000-net-rest-delete-renamed.md' "$FM_RUN/lib-upgrades-added.txt"
expect "lib provenance is the module name, not a flat lib source id" \
  grep -q $'^[0-9a-f]\\{40\\}\tlib\t.kairos-updates/lib/20260116T000000-net-rest-delete-renamed.md$' "$FM_RUN/lib-upgrades-added.tsv"
expect "LIB_MODULES=present is recorded on a frontend run that declared a library module" \
  grep -qx 'LIB_MODULES=present' "$FM_RUN/context.env"
expect "the lib body is snapshotted under its basename into the shared upgrades dir" \
  grep -q '@ifs-kairos/net/rest' "$FM_RUN/upgrades/20260116T000000-net-rest-delete-renamed.md"
refute "collect-lib.sh does not pull the sibling TEMPLATE module's file" \
  grep -q solid "$FM_RUN/lib-upgrades-added.txt"

# collect-lib.sh takes no MODULE, so a solid-scoped classification plus collect-lib
# still sees the same lib file — the proof that collection is template-independent.
FM_SOLID=$SANDBOX/fe-mod-run-solid; mkdir -p "$FM_SOLID"
RUN=$FM_SOLID CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_BASE_SHA TARGET=$FRONTEND_TARGET_SHA \
  SYNTH=$FMS MODULE=solid PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" \
  > /dev/null 2> "$SANDBOX/fm-bm-solid.log"
expect "the solid-scoped classification exits 0" test $? -eq 0
printf 'RUN_SOURCE=frontend\n' > "$FM_SOLID/context.env"
RUN=$FM_SOLID CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_BASE_SHA TARGET=$FRONTEND_TARGET_SHA \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/collect-lib.sh" \
  > /dev/null 2> "$SANDBOX/fm-cl-solid.log"
expect "collect-lib.sh on a solid-scoped run still collects the lib file" \
  grep -qx '\.kairos-updates/lib/20260116T000000-net-rest-delete-renamed.md' "$FM_SOLID/lib-upgrades-added.txt"

# The control that makes the exclusion above mean something: the SAME range, unscoped,
# does see the sibling's file. Without this, an exclusion caused by a wrong range would
# read as a passing test.
FM_RUN2=$SANDBOX/fe-mod-run-unscoped; mkdir -p "$FM_RUN2"
RUN=$FM_RUN2 CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_BASE_SHA TARGET=$FRONTEND_TARGET_SHA \
  SYNTH=$FMS PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" \
  > /dev/null 2> "$SANDBOX/fm-bm2.log"
expect "the unscoped control run exits 0" test $? -eq 0
expect "unscoped, the sibling module's file IS in range (so the range is not what excluded it)" \
  grep -q solid-app-export-renamed "$FM_RUN2/upgrades-added.txt"
cd "$COMP"

fi

if t "an empty MODULE leaves template upgrade-file collection byte-identical"; then
# The parameterization's other half: the template path did not move. Same fixture, same
# range, same synthetic pair, both spellings of "no module" — the artifacts have to be
# identical, not merely similar.
cd "$COMP"
MP_A=$SANDBOX/modparity-a; MP_B=$SANDBOX/modparity-b
mkdir -p "$MP_A" "$MP_B"
RUN=$MP_A CACHE=$TPL BASE=$BASE TARGET=$TARGET PHASE_KEY=$PK_MATERIALIZE \
  "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/mp-mat.log"
expect "the parity fixture materializes" test $? -eq 0
RUN=$MP_A CACHE=$TPL BASE=$BASE TARGET=$TARGET SYNTH=$MP_A/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" > /dev/null 2> "$SANDBOX/mp-a.log"
expect "classification with no MODULE in the environment at all exits 0" test $? -eq 0
RUN=$MP_B CACHE=$TPL BASE=$BASE TARGET=$TARGET SYNTH=$MP_A/synthetic MODULE= \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" > /dev/null 2> "$SANDBOX/mp-b.log"
expect "classification with MODULE= empty exits 0" test $? -eq 0
for mp_art in upgrades-added.txt upgrades-added.tsv upgrades-modified.txt legacy-upgrade-commits.txt; do
  expect "MODULE= empty leaves $mp_art identical to the unscoped run" \
    diff -q "$MP_A/$mp_art" "$MP_B/$mp_art"
done
expect "and the snapshotted bodies are identical too" \
  diff -r -q "$MP_A/upgrades" "$MP_B/upgrades"
expect "the template range really did carry upgrade-files (the parity is not over two empty sets)" \
  test -s "$MP_A/upgrades-added.txt"
refute "an empty MODULE claims no module scope" grep -q 'scoped to' "$SANDBOX/mp-b.log"
cd "$COMP"

fi

if t "pre-flight.sh: RUN_SOURCE=frontend accepts the CHAINED re-entry on a finished run's branch"; then
# The chained frontend run's legitimate state (PRD story 12: one PR carries both runs).
# Phase 8 cleared template.in_progress, the consent step got a yes, and the fresh-mode
# Phase 1 re-entry therefore stands on the FINISHED template run's migration branch with
# no live block — the same SHAPE as the Phase-4 crash window and the opposite meaning.
# RUN_SOURCE is what tells them apart, so all three readings are asserted here: refused
# without it (as before), accepted with it, and STILL refused when a block is live.
# A LOCAL frontend source: a frontend run now establishes its own mirror at
# pre-flight (check 8.6), because Phase 2's SHA validation, the bootstrap scoring and
# Phase 3's module-scoped history walk all need it before Phase 2.5 exists — so the
# recorded repo has to be a repo that can actually be cloned, exactly as
# `template.repo` does.
CHFE=$SANDBOX/pf-chained-frontend
mkdir -p "$CHFE/template/react/src"
( cd "$CHFE" && git init -q -b main \
  && printf '{ "name": "<YOUR_BC_NAME>" }\n' > template/react/package.json \
  && printf 'export const App = 1\n' > template/react/src/App.tsx \
  && git add -A && git commit -qm "frontend baseline" ) >/dev/null 2>&1
CHFE_SHA=$(git -C "$CHFE" rev-parse HEAD)
CH=$SANDBOX/pf-chained
mkdir -p "$CH/.kairos" && cd "$CH" && git init -q -b main
cat > .kairos/manifest.yaml <<EOF
name: chaincomp
template:
  repo: file://$TPL
  sha: $TARGET
  branch: main
frontend:
  repo: file://$CHFE
  path: template/react
  template: react
  branch: main
  sha: $CHFE_SHA
EOF
mkdir -p web/src && echo 'export const x = 1' > web/src/main.ts
git add -A && git commit -qm "finished template run"
# The branch the finished template run created, still checked out — exactly where the
# consent step's "yes" leaves the user.
git checkout -q -b topic/tester/template-update-abc1234

pf_ch() { # pf_ch <logfile> <extra env...> — fresh-mode pre-flight, status returned
  local log="$1"; shift
  env MODE=fresh TEMPLATE_PATH="$TPL" PHASE_KEY="$PK_PREFLIGHT" "$@" \
    "$SKILL_DIR/scripts/pre-flight.sh" > "$log.out" 2> "$log"
}

# 1. Without the env: refused exactly as before — and the refusal now names the env
#    rather than leaving "delete the branch" as the only reading.
pf_ch "$SANDBOX/pf-ch-noenv.log"
if [[ $? -ne 0 ]]; then
  pass "no RUN_SOURCE: a block-less migration-shaped branch is still refused"
else
  fail "no RUN_SOURCE: a block-less migration-shaped branch is still refused"
fi
expect "the refusal is still the crash-window message" \
  grep -qF 'records no migration in progress' "$SANDBOX/pf-ch-noenv.log"
expect "and it names RUN_SOURCE=frontend as the other reading" \
  grep -qF 'RUN_SOURCE=frontend' "$SANDBOX/pf-ch-noenv.log"
refute "nothing was recorded by the refused run" test -f .kairos/migration/state/context.env

# 2. With RUN_SOURCE=frontend: accepted, said out loud, and recorded on the anchor.
pf_ch "$SANDBOX/pf-ch-fe.log" RUN_SOURCE=frontend
PF_CH_RC=$?
if [[ "$PF_CH_RC" -eq 0 ]]; then
  pass "RUN_SOURCE=frontend: the chained re-entry is accepted (exit 0)"
else
  fail "RUN_SOURCE=frontend: the chained re-entry is accepted (rc=$PF_CH_RC, log: $(tail -2 "$SANDBOX/pf-ch-fe.log" | tr '\n' ' '))"
fi
expect "the acceptance is an INFO naming the chained case, not silence" \
  bash -c "grep -F 'INFO:' '$SANDBOX/pf-ch-fe.log' | grep -qF 'chained'"
expect "the run's source reaches the anchor (Phase 8's advance guard reads it)" \
  grep -qx 'RUN_SOURCE=frontend' .kairos/migration/state/context.env
refute "no FAIL line was printed" grep -q '^FAIL:' "$SANDBOX/pf-ch-fe.log"
# Check 8.6 rode along on that same accepted run: the frontend MIRROR is what the
# phases after this one read instead of the template one.
expect "the frontend mirror was established in the run's own state dir" \
  test -f .kairos/migration/state/frontend/HEAD
expect "and its path reached the anchor as FRONTEND_CACHE" \
  grep -qx 'FRONTEND_CACHE=.kairos/migration/state/frontend' .kairos/migration/state/context.env
expect "it is a mirror of the recorded frontend source, so this run's SHAs resolve in it" \
  bash -c "git -C .kairos/migration/state/frontend cat-file -e '$CHFE_SHA^{commit}'"

# 3. RUN_SOURCE=template is the DEFAULT spelled out: the refusal is unchanged, so the
#    acceptance above is the frontend arm and not a weakened check.
rm -rf .kairos/migration
pf_ch "$SANDBOX/pf-ch-tpl.log" RUN_SOURCE=template
if [[ $? -ne 0 ]]; then
  pass "RUN_SOURCE=template: refused exactly as an unset value is"
else
  fail "RUN_SOURCE=template: refused exactly as an unset value is"
fi
expect "with the same message" \
  grep -qF 'records no migration in progress' "$SANDBOX/pf-ch-tpl.log"

# 4. An unknown value is a hard fail, never a silent fall back to template: falling
#    back would restore the refusal on the very run the caller was declaring, and the
#    remedy it prints ("delete this branch") is destructive for that state.
pf_ch "$SANDBOX/pf-ch-typo.log" RUN_SOURCE=frontEnd
if [[ $? -ne 0 ]]; then
  pass "an unknown RUN_SOURCE is refused rather than treated as template"
else
  fail "an unknown RUN_SOURCE is refused rather than treated as template"
fi
expect "the refusal names the bad value and the accepted ones" \
  bash -c "grep -qF 'frontEnd' '$SANDBOX/pf-ch-typo.log' \
        && grep -qF \"'template' or 'frontend'\" '$SANDBOX/pf-ch-typo.log'"

# 5. A LIVE block still refuses under the same env, under EITHER source key: chaining
#    SEQUENCES the two runs, it does not relax "one migration at a time".
for live in template frontend; do
  yq -i ".$live.in_progress = {\"target_sha\": \"$TARGET\", \"branch\": \"topic/tester/template-update-abc1234\", \"previous_branch\": \"main\", \"previous_sha\": \"$(git rev-parse HEAD)\"}" .kairos/manifest.yaml
  git commit -qam "live $live block"
  pf_ch "$SANDBOX/pf-ch-live-$live.log" RUN_SOURCE=frontend
  if [[ $? -ne 0 ]]; then
    pass "a live $live.in_progress still refuses a fresh frontend run on that branch"
  else
    fail "a live $live.in_progress still refuses a fresh frontend run on that branch"
  fi
  expect "$live: the refusal is the live-migration one, not the crash-window one" \
    grep -qF 'and a migration is in progress' "$SANDBOX/pf-ch-live-$live.log"
  refute "$live: the live-run refusal never reads as the chained case" \
    bash -c "grep -qF 'chained' '$SANDBOX/pf-ch-live-$live.log'"
  yq -i "del(.$live.in_progress)" .kairos/manifest.yaml
  git commit -qam "clear $live block"
done

# 6. And a live block off the migration branch is still refused too — that arm is about
#    who owns $RUN, not about where the user is standing.
git checkout -q main
yq -i ".template.in_progress = {\"target_sha\": \"$TARGET\", \"branch\": \"topic/tester/template-update-abc1234\", \"previous_branch\": \"main\"}" .kairos/manifest.yaml
git commit -qam "live block, standing elsewhere"
pf_ch "$SANDBOX/pf-ch-live-elsewhere.log" RUN_SOURCE=frontend
if [[ $? -ne 0 ]]; then
  pass "a live block refuses a fresh frontend run from an unrelated branch as well"
else
  fail "a live block refuses a fresh frontend run from an unrelated branch as well"
fi
cd "$COMP"
fi

if t "pre-flight.sh check 0b: the Kairos CLI probe is NOT APPLICABLE on a frontend run"; then
# PRD story 32: a frontend run materializes from the module subtree plus the skill's own
# replacement map, so it invokes no CLI — and must not be blocked by one. The sharp test
# points KAIROS_BIN at a binary that does not exist: the template run must still hard
# stop on it (the dependency is real there), and the frontend run must not care.
CB=$SANDBOX/pf-cli-na
mkdir -p "$CB/.kairos" && cd "$CB" && git init -q -b main
# A recorded frontend source, because a frontend run also establishes its own mirror
# here (check 8.6) — this block is about the CLI probe, so the source is given rather
# than left to fail for an unrelated reason. `$CHFE` is the local frontend fixture the
# chained-re-entry block above built.
printf 'name: clicomp\ntemplate:\n  repo: file://%s\n  sha: %s\n  branch: main\nfrontend:\n  repo: file://%s\n  path: template/react\n  template: react\n  branch: main\n  sha: %s\n' \
  "$TPL" "$BASE" "$CHFE" "$CHFE_SHA" > .kairos/manifest.yaml
git add -A && git commit -qm cli-comp

pf_cli() { # pf_cli <logfile> <extra env...>
  local log="$1"; shift
  env MODE=fresh TEMPLATE_PATH="$TPL" PHASE_KEY="$PK_PREFLIGHT" "$@" \
    "$SKILL_DIR/scripts/pre-flight.sh" > "$log.out" 2> "$log"
}

pf_cli "$SANDBOX/pf-cli-tpl-missing.log" KAIROS_BIN=no-such-kairos-binary
if [[ $? -ne 0 ]]; then
  pass "a template run still hard-stops on a missing Kairos CLI"
else
  fail "a template run still hard-stops on a missing Kairos CLI"
fi
expect "with the update-nga-local-dev message" \
  grep -qF 'not found on PATH' "$SANDBOX/pf-cli-tpl-missing.log"

pf_cli "$SANDBOX/pf-cli-fe-missing.log" RUN_SOURCE=frontend KAIROS_BIN=no-such-kairos-binary
PF_CLI_FE_RC=$?
if [[ "$PF_CLI_FE_RC" -eq 0 ]]; then
  pass "a frontend run with NO Kairos CLI at all completes pre-flight (exit 0)"
else
  fail "a frontend run with NO Kairos CLI at all completes pre-flight (rc=$PF_CLI_FE_RC, log: $(tail -2 "$SANDBOX/pf-cli-fe-missing.log" | tr '\n' ' '))"
fi
expect "the skip is stated as not applicable" \
  bash -c "grep -F 'INFO:' '$SANDBOX/pf-cli-fe-missing.log' | grep -qF 'not applicable'"
refute "and it is not reported as a supported-CLI probe" \
  grep -qF 'supports migration materialization' "$SANDBOX/pf-cli-fe-missing.log"
# An old CLI is the other half of the probe: also not applicable, not merely tolerated.
pf_cli "$SANDBOX/pf-cli-fe-old.log" RUN_SOURCE=frontend KAIROS_MIN_VERSION=99.0.0
if [[ $? -eq 0 ]]; then
  pass "a version floor no CLI can meet does not stop a frontend run either"
else
  fail "a version floor no CLI can meet does not stop a frontend run either"
fi
pf_cli "$SANDBOX/pf-cli-tpl-old.log" KAIROS_MIN_VERSION=99.0.0
if [[ $? -ne 0 ]]; then
  pass "the same floor still stops a template run (the probe is unchanged there)"
else
  fail "the same floor still stops a template run (the probe is unchanged there)"
fi
expect "naming the floor" grep -qF '99.0.0' "$SANDBOX/pf-cli-tpl-old.log"

# The template arm's own output is byte-identical to what it always was: the probe ran
# and said so, and no not-applicable line appears anywhere near it.
pf_cli "$SANDBOX/pf-cli-tpl-ok.log"
if [[ $? -eq 0 ]]; then
  pass "a template run with a good CLI still passes"
else
  fail "a template run with a good CLI still passes"
fi
expect "and still reports the probe" \
  grep -qF 'supports migration materialization' "$SANDBOX/pf-cli-tpl-ok.log"
refute "a template run claims nothing about not-applicable" \
  grep -qF 'not applicable' "$SANDBOX/pf-cli-tpl-ok.log"
refute "a template run records no RUN_SOURCE it was never given" \
  grep -q '^RUN_SOURCE=' .kairos/migration/state/context.env
cd "$COMP"
fi

if t "pre-flight.sh check 8.6: a frontend run establishes and reuses its own mirror, and the sweep spares it"; then
# S1/S2/S5. Three consumers need the frontend mirror BEFORE Phase 2.5 exists — Phase 2's
# SHA validation, the bootstrap scoring, Phase 3's module-scoped history walk — and all
# three used to be pointed at $CACHE, the TEMPLATE mirror, where a frontend SHA resolves
# to nothing. And the fresh sweep deleted $RUN/frontend, so every reuse/refresh arm
# (here and in materialize-frontend.sh) was unreachable.
FEM=$SANDBOX/pf-fe-mirror
FEMSRC=$SANDBOX/pf-fe-mirror-src
mkdir -p "$FEMSRC/template/react/src"
( cd "$FEMSRC" && git init -q -b main \
  && printf '{ "name": "<YOUR_BC_NAME>" }\n' > template/react/package.json \
  && git add -A && git commit -qm "frontend baseline" ) >/dev/null 2>&1
FEM_SHA=$(git -C "$FEMSRC" rev-parse HEAD)
mkdir -p "$FEM/.kairos" && cd "$FEM" && git init -q -b main
cat > .kairos/manifest.yaml <<EOF
name: femirror
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
frontend:
  repo: file://$FEMSRC
  path: template/react
  template: react
  branch: main
  sha: $FEM_SHA
EOF
mkdir -p web/src && printf 'export const x = 1\n' > web/src/main.ts && echo '{}' > web/package.json
git add -A && git commit -qm femirror

pf_fe() { # pf_fe <logfile> <extra env...>
  local log="$1"; shift
  env MODE=fresh TEMPLATE_PATH="$TPL" PHASE_KEY="$PK_PREFLIGHT" "$@" \
    "$SKILL_DIR/scripts/pre-flight.sh" > "$log.out" 2> "$log"
}

# 1. A TEMPLATE run pays nothing and says nothing: the frontend source is not its source.
pf_fe "$SANDBOX/pf-fem-tpl.log"
expect "a template run still passes pre-flight" test $? -eq 0
refute "a template run clones no frontend mirror" test -e .kairos/migration/state/frontend
refute "and emits no FRONTEND_CACHE line" \
  grep -q '^FRONTEND_CACHE=' "$SANDBOX/pf-fem-tpl.log.out"
refute "nor records the key" \
  grep -q '^FRONTEND_CACHE=' .kairos/migration/state/context.env

# 2. A FRONTEND run establishes it, emits it, and records it.
pf_fe "$SANDBOX/pf-fem-fe.log" RUN_SOURCE=frontend
PF_FEM_RC=$?
if [[ "$PF_FEM_RC" -eq 0 ]]; then
  pass "a frontend run passes pre-flight and establishes the mirror"
else
  fail "a frontend run passes pre-flight (rc=$PF_FEM_RC: $(tail -2 "$SANDBOX/pf-fem-fe.log" | tr '\n' ' '))"
fi
expect "the mirror is a git dir inside the run state" test -f .kairos/migration/state/frontend/HEAD
expect "the frontend baseline SHA resolves in it (this is what Phase 2 validates against)" \
  bash -c "git -C .kairos/migration/state/frontend cat-file -e '$FEM_SHA^{commit}'"
expect "FRONTEND_CACHE is on stdout" \
  grep -qx 'FRONTEND_CACHE=.kairos/migration/state/frontend' "$SANDBOX/pf-fem-fe.log.out"
expect "and on the anchor" \
  grep -qx 'FRONTEND_CACHE=.kairos/migration/state/frontend' .kairos/migration/state/context.env

# 3. The fresh sweep SPARES it — and still sweeps everything else.
printf 'stale\n' > .kairos/migration/state/qa-ledger.tsv
FEM_MIRROR_ID=$(git -C .kairos/migration/state/frontend rev-parse HEAD 2>/dev/null || echo "")
pf_fe "$SANDBOX/pf-fem-again.log" RUN_SOURCE=frontend
expect "the second fresh frontend run passes" test $? -eq 0
expect "the mirror survived the sweep" test -f .kairos/migration/state/frontend/HEAD
expect "and it was refreshed in place rather than re-cloned" \
  grep -qF 'refreshed existing frontend mirror' "$SANDBOX/pf-fem-again.log"
refute "while the ordinary stale state was swept" test -f .kairos/migration/state/qa-ledger.tsv

# 4. A mirror of a DIFFERENT origin is never trusted — the same rule check 7 applies.
OTHER=$SANDBOX/pf-fe-other-src
mkdir -p "$OTHER" && ( cd "$OTHER" && git init -q -b main \
  && printf 'other\n' > other.txt && git add -A && git commit -qm other ) >/dev/null 2>&1
git -C .kairos/migration/state/frontend remote set-url origin "file://$OTHER" >/dev/null 2>&1
pf_fe "$SANDBOX/pf-fem-origin.log" RUN_SOURCE=frontend
expect "a wrong-origin mirror still leaves pre-flight passing" test $? -eq 0
expect "because it was re-cloned rather than reused" \
  bash -c "test \"\$(git -C .kairos/migration/state/frontend config --get remote.origin.url)\" = 'file://$FEMSRC'"
refute "no refresh was claimed for the wrong-origin mirror" \
  grep -qF 'refreshed existing frontend mirror' "$SANDBOX/pf-fem-origin.log"

# 5. No origin at all on a frontend run is a hard stop naming all three sources — the
#    bootstrap case's remedy is the FRONTEND_REPO env, so the message has to name it.
FENO=$SANDBOX/pf-fe-noorigin
mkdir -p "$FENO/.kairos" && cd "$FENO" && git init -q -b main
printf 'name: fenoorigin\ntemplate:\n  repo: file://%s\n  sha: %s\n  branch: main\n' \
  "$TPL" "$BASE" > .kairos/manifest.yaml
mkdir -p web && printf 'x\n' > web/x.ts && echo '{}' > web/package.json
git add -A && git commit -qm fenoorigin
pf_fe "$SANDBOX/pf-fem-noorigin.log" RUN_SOURCE=frontend
if [[ $? -ne 0 ]]; then
  pass "a frontend run with no frontend source is refused"
else
  fail "a frontend run with no frontend source was accepted (the mirror would be missing)"
fi
expect "the refusal names all three ways to supply it" \
  bash -c "grep -qF -- '--frontend-path' '$SANDBOX/pf-fem-noorigin.log' \
        && grep -qF 'frontend.repo' '$SANDBOX/pf-fem-noorigin.log' \
        && grep -qF 'FRONTEND_REPO' '$SANDBOX/pf-fem-noorigin.log'"
# The bootstrap case: no block, so the env fills the gap — and the value it filled is
# recorded, because Phase 2's bootstrap writer needs it.
pf_fe "$SANDBOX/pf-fem-boot.log" RUN_SOURCE=frontend FRONTEND_REPO="file://$FEMSRC"
PF_BOOT_RC=$?
if [[ "$PF_BOOT_RC" -eq 0 ]]; then
  pass "with FRONTEND_REPO the bootstrap case establishes the mirror"
else
  fail "with FRONTEND_REPO the bootstrap case establishes the mirror (rc=$PF_BOOT_RC: $(tail -2 "$SANDBOX/pf-fem-boot.log" | tr '\n' ' '))"
fi
expect "the mirror exists" test -f .kairos/migration/state/frontend/HEAD
expect "the env-supplied repo is recorded on the anchor" \
  grep -qx "FRONTEND_REPO=file://$FEMSRC" .kairos/migration/state/context.env
expect "and the bootstrap candidate is still reported" \
  grep -qx 'FRONTEND_BOOTSTRAP=web/' .kairos/migration/state/context.env
cd "$COMP"
fi

if t "pre-flight.sh MODE=continue fails closed when RUN_SOURCE contradicts the live block"; then
# S7: continue mode skips every check-3 refusal by design, so a caller-supplied
# RUN_SOURCE naming the other source was recorded onto the anchor (check 9,
# last-write-wins) and the resume took the wrong arm — wrong target chain, wrong
# upgrade-file directory, wrong gate cwd — until Phase 8's advance cross-check.
CS=$SANDBOX/pf-continue-source
mkdir -p "$CS/.kairos" && cd "$CS" && git init -q -b main
cat > .kairos/manifest.yaml <<EOF
name: contsrc
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
  in_progress:
    target_sha: "$TARGET"
    branch: topic/tester/template-update-abc1234
    previous_branch: main
    previous_sha: "$(git rev-parse --verify HEAD 2>/dev/null || echo 1111111111111111111111111111111111111111)"
EOF
git add -A && git commit -qm contsrc
git checkout -q -b topic/tester/template-update-abc1234
pf_cs() { local log="$1"; shift
  env MODE=continue TEMPLATE_PATH="$TPL" PHASE_KEY="$PK_PREFLIGHT" "$@" \
    "$SKILL_DIR/scripts/pre-flight.sh" > "$log.out" 2> "$log"; }

pf_cs "$SANDBOX/pf-cs-bad.log" RUN_SOURCE=frontend
if [[ $? -ne 0 ]]; then
  pass "a continue declaring frontend over a live TEMPLATE block is refused"
else
  fail "a continue declaring frontend over a live template block was accepted"
fi
expect "the refusal names both readings" \
  bash -c "grep -qF 'RUN_SOURCE=frontend' '$SANDBOX/pf-cs-bad.log' \
        && grep -qF 'template.in_progress' '$SANDBOX/pf-cs-bad.log'"
expect "and says the live block IS the run's source" \
  grep -qF "the run's source" "$SANDBOX/pf-cs-bad.log"
refute "nothing was recorded by the refused resume" \
  bash -c "grep -q '^RUN_SOURCE=' .kairos/migration/state/context.env 2>/dev/null"

# The two accepted shapes: no declaration at all (continue derives it from the block),
# and the matching one.
pf_cs "$SANDBOX/pf-cs-unset.log"
expect "a continue with no RUN_SOURCE is accepted, as it always was" test $? -eq 0
expect "and it still reports which source owns the live run" \
  grep -qx 'IN_PROGRESS_SOURCE=template' "$SANDBOX/pf-cs-unset.log.out"
pf_cs "$SANDBOX/pf-cs-ok.log" RUN_SOURCE=template
expect "a continue whose RUN_SOURCE matches the live block is accepted" test $? -eq 0
expect "and records it" grep -qx 'RUN_SOURCE=template' .kairos/migration/state/context.env
cd "$COMP"
fi

if t "build-manifest.sh refuses a MODULE the source's config.yaml does not declare"; then
# S6: UPG_DIR=".kairos-updates/$MODULE/" was unvalidated, so a stale or mis-cased key
# ('React') scoped every history walk to a directory that does not exist: zero
# upgrade-files collected, exit 0, "success" — and a plan missing every migration step
# the range actually carried. The source repo already declares the answer.
#
# The frontend fixture built earlier in this suite is reused as-is: re-running
# setup_frontend_fixture over the same directory re-inits it, its no-change commits
# fail, and FRONTEND_BASE_SHA then equals the tip — collapsing the range this block is
# about to nothing.
MVC=$SANDBOX/fe-modval-comp
mkdir -p "$MVC/.kairos" && cd "$MVC" && git init -q -b main
printf 'name: modvalcomp\ntemplate:\n  repo: file://%s\n  sha: %s\n  branch: main\n' \
  "$TPL" "$BASE" > .kairos/manifest.yaml
git add -A && git commit -qm modvalcomp
add_frontend_to_component "$MVC"

MVS=$SANDBOX/fe-modval-synth
mkdir -p "$MVS" && cd "$MVS" && git init -q -b main
rm -rf web && mkdir -p web
git -C "$FRONTEND_REPO_DIR" archive "$FRONTEND_BASE_SHA:template/react" | tar -x -C web
git add -A && git commit -qm "synthetic base" && git tag -f kairos-base
rm -rf web && mkdir -p web
git -C "$FRONTEND_REPO_DIR" archive "$FRONTEND_TARGET_SHA:template/react" | tar -x -C web
git add -A && git commit -qm "synthetic target" && git tag -f kairos-target

cd "$MVC"
MV_RUN=$MVC/.kairos/migration/state; mkdir -p "$MV_RUN"
bm_mod() { # bm_mod <module> <run-dir> <log>
  RUN="$2" CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_BASE_SHA TARGET=$FRONTEND_TARGET_SHA \
    SYNTH=$MVS MODULE="$1" PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" \
    > /dev/null 2> "$3"
}
bm_mod React "$MV_RUN" "$SANDBOX/bm-mod-bad.log"
BM_BAD_RC=$?
if [[ "$BM_BAD_RC" -ne 0 ]]; then
  pass "a mis-cased module key is a refusal, not a silent empty collection"
else
  fail "a mis-cased module key was accepted (rc=0) — every upgrade-file would be dropped"
fi
expect "the refusal names the bad key and what the source actually declares" \
  bash -c "grep -qF \"MODULE='React'\" '$SANDBOX/bm-mod-bad.log' \
        && grep -qF 'react' '$SANDBOX/bm-mod-bad.log' \
        && grep -qF 'solid' '$SANDBOX/bm-mod-bad.log'"
expect "and it says what the consequence would have been" \
  grep -qF 'report success' "$SANDBOX/bm-mod-bad.log"

# A DECLARED module still works — and one with zero upgrade-files in range stays a
# SUCCESS: "nothing to migrate" is an answer, not an error.
MV_RUN2=$SANDBOX/fe-modval-run-ok; mkdir -p "$MV_RUN2"
bm_mod react "$MV_RUN2" "$SANDBOX/bm-mod-ok.log"
expect "the declared module classifies cleanly" test $? -eq 0
expect "and collects its own upgrade-file" \
  grep -q 'app-export-renamed' "$MV_RUN2/upgrades-added.txt"
MV_RUN3=$SANDBOX/fe-modval-run-empty; mkdir -p "$MV_RUN3"
RUN="$MV_RUN3" CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_TARGET_SHA TARGET=$FRONTEND_TARGET_SHA \
  SYNTH=$MVS MODULE=solid PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" \
  > /dev/null 2> "$SANDBOX/bm-mod-empty.log"
expect "a declared module with zero upgrade-files in range still exits 0" test $? -eq 0
expect "with an empty collection, which is the honest answer" \
  bash -c "test ! -s '$MV_RUN3/upgrades-added.txt'"

# No config.yaml at TARGET: nothing to validate against, so the passed key stands
# exactly as it did before — that is every source repo that does not self-describe.
MV_RUN4=$SANDBOX/fe-modval-run-nocfg; mkdir -p "$MV_RUN4"
RUN="$MV_RUN4" CACHE=$TPL BASE=$BASE TARGET=$TARGET SYNTH=$MVS MODULE=anything \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" \
  > /dev/null 2> "$SANDBOX/bm-mod-nocfg.log"
expect "an unvalidatable key is not an invalid one (the template repo has no config.yaml)" \
  test $? -eq 0
cd "$COMP"
fi

if t "build-manifest.sh frontend-floor extraction tolerates CRLF / trailing whitespace"; then
# Regression: snap_upgrade's `git show` does no LF normalization, so a
# CRLF-authored upgrade-file body keeps its trailing \r in the snapshot; that \r
# (or plain trailing spaces after the sha, LF endings otherwise) rode past the
# extraction's leading-whitespace-only sed and defeated the $-anchored
# validators ($ cannot match past a stray byte) — silently DROPPING an
# otherwise well-formed requires-frontend: floor instead of flagging it
# malformed. Its own tiny template so this cannot perturb the shared fixture's
# frontend-floors count already asserted above.
FC_TPL=$SANDBOX/fecrlf-tpl
mkdir -p "$FC_TPL/.kairos-updates" && cd "$FC_TPL" && git init -q -b main
printf 'base\n' > plain.txt
git add -A && git commit -qm fc-base
FC_BASE=$(git rev-parse HEAD)
# CRLF case: module@sha form, the \r lands right after the sha on its own line.
printf '# floor A\r\n\r\nrequires-frontend: react@ab11ab11ab11ab11ab11ab11ab11ab11ab11ab11\r\n' \
  > .kairos-updates/20260601T000000-crlf-floor.md
# Trailing-whitespace case: bare-sha form (module defaults to react), plain LF
# endings but trailing spaces survive after the sha.
printf '# floor B\n\nrequires-frontend: cd22cd22cd22cd22cd22cd22cd22cd22cd22cd22   \n' \
  > .kairos-updates/20260602T000000-trailing-space-floor.md
git add -A && git commit -qm fc-target
FC_TARGET=$(git rev-parse HEAD)

FC_COMP=$SANDBOX/fecrlf-comp
mkdir -p "$FC_COMP/.kairos" && cd "$FC_COMP" && git init -q -b main
printf 'module example.com/custom/feccomp\n' > go.mod
cat > .kairos/manifest.yaml <<EOF
name: feccomp
template:
  repo: file://$FC_TPL
  sha: $FC_BASE
  branch: main
EOF
git add -A && git commit -qm fc-comp
FC_RUN=$FC_COMP/.kairos/migration/state; mkdir -p "$FC_RUN"
RUN=$FC_RUN CACHE=$FC_TPL BASE=$FC_BASE TARGET=$FC_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" \
  > "$SANDBOX/fc-mat.out" 2> "$SANDBOX/fc-mat.log"
expect "materialize.sh exits 0 over the CRLF/trailing-whitespace floor fixture" test $? -eq 0

RUN=$FC_RUN CACHE=$FC_TPL BASE=$FC_BASE TARGET=$FC_TARGET SYNTH=$FC_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/fc-bm.log"
expect "build-manifest.sh exits 0 over the CRLF/trailing-whitespace floor fixture" test $? -eq 0

expect "frontend-floors.tsv has both rows (CRLF and trailing-whitespace floors both survive)" \
  bash -c "test \$(wc -l < '$FC_RUN/frontend-floors.tsv') -eq 2"
expect "the CRLF-terminated module@sha floor's module is extracted with no \\r riding it" \
  bash -c "awk -F'\t' '\$1==\".kairos-updates/20260601T000000-crlf-floor.md\"{print \$2}' '$FC_RUN/frontend-floors.tsv' | grep -qx react"
expect "the CRLF-terminated module@sha floor's sha is extracted with no \\r riding it" \
  bash -c "awk -F'\t' '\$1==\".kairos-updates/20260601T000000-crlf-floor.md\"{print \$3}' '$FC_RUN/frontend-floors.tsv' | grep -qx ab11ab11ab11ab11ab11ab11ab11ab11ab11ab11"
expect "the trailing-whitespace bare-sha floor defaults its module to react" \
  bash -c "awk -F'\t' '\$1==\".kairos-updates/20260602T000000-trailing-space-floor.md\"{print \$2}' '$FC_RUN/frontend-floors.tsv' | grep -qx react"
expect "the trailing-whitespace bare-sha floor's sha has no trailing spaces riding it" \
  bash -c "awk -F'\t' '\$1==\".kairos-updates/20260602T000000-trailing-space-floor.md\"{print \$3}' '$FC_RUN/frontend-floors.tsv' | grep -qx cd22cd22cd22cd22cd22cd22cd22cd22cd22cd22"
cd "$COMP"
fi

if t "build-manifest.sh frontend-floor extraction: multiple floors per file, and the basename-collision guard"; then
# Two hardening regressions in the requires-frontend extraction pass:
#  (1) MULTIPLE floors in one upgrade-file body — every requires-frontend: line
#      must become its own row; the extraction used to keep only the first
#      (grep -m1), silently dropping the rest.
#  (2) BASENAME COLLISION — snapshots are keyed by basename, so two crossed
#      upgrade-files sharing one (in different .kairos-updates/ subdirs, both
#      reachable by the recursive walk) land in ONE snapshot; the last writer
#      wins. Reading a floor from the winner's body and pinning it to the OTHER
#      path would misattribute the floor (spurious manifest debt) or drop it.
#      The guard reads the floor only when the on-disk snapshot actually came
#      from $path; otherwise it skips LOUDLY. This pins: no floor is ever
#      attributed to a path whose own body did not declare it.
FM_TPL=$SANDBOX/femulti-tpl
mkdir -p "$FM_TPL/.kairos-updates" && cd "$FM_TPL" && git init -q -b main
printf 'base\n' > plain.txt
git add -A && git commit -qm fm-base
FM_BASE=$(git rev-parse HEAD)
# (1) one file, TWO floors (distinct modules + shas)
printf '# multi\n\nrequires-frontend: react@%s\nrequires-frontend: solid@%s\n' \
  1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 \
  > .kairos-updates/20260701T000000-multi.md
# (2) same basename dup.md in two subdirs — dir-a DECLARES a floor, dir-b does not
mkdir -p .kairos-updates/dir-a .kairos-updates/dir-b
printf '# dup a\n\nrequires-frontend: react@%s\n' 3333333333333333333333333333333333333333 \
  > .kairos-updates/dir-a/dup.md
printf '# dup b\n\nintent: unrelated\n' > .kairos-updates/dir-b/dup.md
git add -A && git commit -qm fm-target
FM_TARGET=$(git rev-parse HEAD)

FM_COMP=$SANDBOX/femulti-comp
mkdir -p "$FM_COMP/.kairos" && cd "$FM_COMP" && git init -q -b main
printf 'module example.com/custom/femcomp\n' > go.mod
cat > .kairos/manifest.yaml <<EOF
name: femcomp
template:
  repo: file://$FM_TPL
  sha: $FM_BASE
  branch: main
EOF
git add -A && git commit -qm fm-comp
FM_RUN=$FM_COMP/.kairos/migration/state; mkdir -p "$FM_RUN"
RUN=$FM_RUN CACHE=$FM_TPL BASE=$FM_BASE TARGET=$FM_TARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" \
  > "$SANDBOX/fm-mat.out" 2> "$SANDBOX/fm-mat.log"
expect "materialize.sh exits 0 over the multi-floor/collision fixture" test $? -eq 0
RUN=$FM_RUN CACHE=$FM_TPL BASE=$FM_BASE TARGET=$FM_TARGET SYNTH=$FM_RUN/synthetic \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" 2> "$SANDBOX/fm-bm.log"
expect "build-manifest.sh exits 0 over the multi-floor/collision fixture" test $? -eq 0

# (1) both floors from the one file are recorded, in order
expect "the multi-floor file yields exactly two rows" \
  bash -c "test \$(awk -F'\t' '\$1==\".kairos-updates/20260701T000000-multi.md\"' '$FM_RUN/frontend-floors.tsv' | wc -l) -eq 2"
expect "the first floor (react) is recorded" \
  bash -c "awk -F'\t' '\$1==\".kairos-updates/20260701T000000-multi.md\" && \$2==\"react\"{print \$3}' '$FM_RUN/frontend-floors.tsv' | grep -qx 1111111111111111111111111111111111111111"
expect "the second floor (solid) is recorded, not dropped" \
  bash -c "awk -F'\t' '\$1==\".kairos-updates/20260701T000000-multi.md\" && \$2==\"solid\"{print \$3}' '$FM_RUN/frontend-floors.tsv' | grep -qx 2222222222222222222222222222222222222222"

# (2) the collision guard fired, and NO floor is misattributed to dir-b (which
# declared none). The floor-bearer (dir-a) either gets its own correct row (if it
# won the snapshot) or is skipped loudly (if it lost) — never pinned to dir-b.
expect "the extraction guard reports the basename collision" \
  grep -qF 'skipping requires-frontend extraction' "$SANDBOX/fm-bm.log"
expect "dir-b/dup.md (no floor of its own) is never given a floor row" \
  bash -c "test \$(awk -F'\t' '\$1==\".kairos-updates/dir-b/dup.md\"' '$FM_RUN/frontend-floors.tsv' | wc -l) -eq 0"
expect "any dir-a/dup.md row carries only its OWN declared sha (never a wrong one)" \
  bash -c "! awk -F'\t' '\$1==\".kairos-updates/dir-a/dup.md\" && \$3!=\"3333333333333333333333333333333333333333\"' '$FM_RUN/frontend-floors.tsv' | grep -q ."
cd "$COMP"
fi

if t "facades: pre-flight probes 'component facade create', defaults the facade template, materialize uses it"; then
# A facade (manifest template.kind, else the .init.mk facade check:
# MASTERDATA_INCLUDE_NO_CDC set, or GENERATE_MODULES without sql/all) is born from `kairos component facade create` over
# kairos-component-facade-template. reproduced pre-fix: pre-flight probed only
# `component create`, a facade bootstrap had no template default, and materialize
# ran `component create` over the facade tree — the facade module path was never
# rewritten and the component kind was never checked against the template's.
# The template's .init.mk and go.mod are the real committed facade-template
# files (kairos-component-facade-template 041ee24, tests/fixtures/): no
# MASTERDATA_INCLUDE_NO_CDC line, `GENERATE_MODULES := masterdata json`.
# reproduced pre-fix: a hand-written .init.mk carrying the marker let every
# check here pass while the real facade template failed materialize's kind check.
FFIX=$SKILL_DIR/tests/fixtures/facade-template-041ee24
FTPL=$SANDBOX/facade-tpl
mkdir -p "$FTPL" && cd "$FTPL" && git init -q -b main
cp "$FFIX/init.mk" .init.mk
cp "$FFIX/go.mod.txt" go.mod
mkdir -p pkg/schema
printf 'package schema\n\n// import "bitbucket.org/ifs-pd/kairos-component-facade-template/pkg/schema"\nconst V = 1\n' > pkg/schema/schema.go
git add -A && git commit -qm facade-base
FBASE=$(git rev-parse HEAD)
printf 'package schema\n\n// import "bitbucket.org/ifs-pd/kairos-component-facade-template/pkg/schema"\nconst V = 2\n' > pkg/schema/schema.go
git add -A && git commit -qm facade-target
FTARGET=$(git rev-parse HEAD)

FC=$SANDBOX/facades/myfacade
mkdir -p "$FC" && cd "$FC" && git init -q -b main
cp "$FFIX/init.mk" .init.mk   # what `component facade create` copies over
printf 'module bitbucket.org/ifs-pd/myfacade\n\ngo 1.21\n' > go.mod
printf '.kairos/migration/state/\n' > .gitignore
git add -A && git commit -qm facade-comp

# --- pre-flight: the facade subcommand is what gets probed --------------------
: > "$SANDBOX/fc-calls.log"
MODE=fresh TEMPLATE_PATH=$FTPL FAKE_KAIROS_CALL_LOG=$SANDBOX/fc-calls.log PHASE_KEY=$PK_PREFLIGHT \
  "$SKILL_DIR/scripts/pre-flight.sh" > "$SANDBOX/fc-pf.out" 2> "$SANDBOX/fc-pf.log"
expect "pre-flight passes on a facade with a facade template" test $? -eq 0
expect "pre-flight reports the facade kind" grep -qx 'COMPONENT_KIND=facade' "$SANDBOX/fc-pf.out"
expect "pre-flight probes 'component facade create --help'" \
  grep -q '^component facade create --help' "$SANDBOX/fc-calls.log"

FAKE_KAIROS_NO_FACADE=1 MODE=fresh TEMPLATE_PATH=$FTPL PHASE_KEY=$PK_PREFLIGHT \
  "$SKILL_DIR/scripts/pre-flight.sh" > /dev/null 2> "$SANDBOX/fc-pf-old.log"
if [[ $? -ne 0 ]]; then pass "a CLI without 'component facade' fails a facade pre-flight"; else fail "a CLI without 'component facade' passed a facade pre-flight"; fi
expect "the refusal names the facade subcommand and its CLI floor" \
  grep -q "component facade create.*0\.3\.35" "$SANDBOX/fc-pf-old.log"

# --- bootstrap with no URL: the facade template is the default ----------------
# The clone itself cannot reach Bitbucket from the sandbox; GIT_SSH_COMMAND=false
# makes it fail fast. The default is what is asserted.
GIT_SSH_COMMAND=false MODE=fresh PHASE_KEY=$PK_PREFLIGHT \
  "$SKILL_DIR/scripts/pre-flight.sh" > /dev/null 2> "$SANDBOX/fc-pf-default.log"
expect "a facade bootstrap with no TEMPLATE_REPO defaults to the facade template" \
  grep -qF 'defaulting to git@ssh.bitbucket.org:ifs-pd/kairos-component-facade-template.git' "$SANDBOX/fc-pf-default.log"

# --- the wrong kind's template repo is refused before any clone ---------------
MODE=fresh TEMPLATE_REPO=git@bitbucket.org:ifs-pd/kairos-component-template.git PHASE_KEY=$PK_PREFLIGHT \
  "$SKILL_DIR/scripts/pre-flight.sh" > /dev/null 2> "$SANDBOX/fc-pf-wrong.log"
if [[ $? -ne 0 ]]; then pass "a facade pointed at kairos-component-template is refused"; else fail "a facade pointed at kairos-component-template passed pre-flight"; fi
expect "the refusal names the facade template to use instead" \
  grep -q 'kairos-component-facade-template' "$SANDBOX/fc-pf-wrong.log"

NFC=$SANDBOX/facades/notfacade
mkdir -p "$NFC" && cd "$NFC" && git init -q -b main
printf 'ifeq ($(INFRA_DIR),)\n%%:\nendif\n' > .init.mk
printf 'module bitbucket.org/ifs-pd/notfacade\n\ngo 1.21\n' > go.mod
git add -A && git commit -qm comp
MODE=fresh TEMPLATE_REPO=git@ssh.bitbucket.org:ifs-pd/kairos-component-facade-template.git PHASE_KEY=$PK_PREFLIGHT \
  "$SKILL_DIR/scripts/pre-flight.sh" > "$SANDBOX/fc-pf-nf.out" 2> "$SANDBOX/fc-pf-nf.log"
if [[ $? -ne 0 ]]; then pass "a proper component pointed at the facade template is refused"; else fail "a proper component pointed at the facade template passed pre-flight"; fi
refute "a proper component reports no COMPONENT_KIND line" grep -q '^COMPONENT_KIND=' "$SANDBOX/fc-pf-nf.out"

# --- materialize: `component facade create`, no --no-frontend ------------------
cd "$FC"
: > "$SANDBOX/fc-mat-calls.log"
RUN=$SANDBOX/fc-run CACHE=$FTPL BASE=$FBASE TARGET=$FTARGET FAKE_KAIROS_CALL_LOG=$SANDBOX/fc-mat-calls.log \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > "$SANDBOX/fc-mat.out" 2> "$SANDBOX/fc-mat.log"
expect "materialize.sh exits 0 on a facade" test $? -eq 0
expect "both sides went through 'component facade create'" \
  bash -c "test \$(grep -c '^component facade create myfacade ' '$SANDBOX/fc-mat-calls.log') -eq 2"
refute "no side was materialized with 'component create'" \
  grep -q '^component create ' "$SANDBOX/fc-mat-calls.log"
refute "facade create is never passed --no-frontend (a click usage error on the real CLI)" \
  grep -q -- '--no-frontend' "$SANDBOX/fc-mat-calls.log"
expect "the facade template's module path is rewritten to the component's" \
  bash -c "git -C '$SANDBOX/fc-run/synthetic' show kairos-target:go.mod | grep -qx 'module bitbucket.org/ifs-pd/myfacade'"
refute "no facade-template module path survives" \
  bash -c "git -C '$SANDBOX/fc-run/synthetic' grep -q 'kairos-component-facade-template' kairos-target"
expect "materialization.txt records the facade kind" \
  grep -q '^component_kind: *facade' "$SANDBOX/fc-run/materialization.txt"

# --- a facade against the component template stops before any create ----------
: > "$SANDBOX/fc-mm-calls.log"
RUN=$SANDBOX/fc-run-mm CACHE=$TPL BASE=$BASE TARGET=$TARGET FAKE_KAIROS_CALL_LOG=$SANDBOX/fc-mm-calls.log \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/fc-mm.log"
if [[ $? -ne 0 ]]; then pass "a facade materialized against the component template is refused"; else fail "a facade materialized against the component template succeeded"; fi
expect "the refusal says the template is not the facade template" \
  grep -q 'not the facade template' "$SANDBOX/fc-mm.log"
refute "no CLI create ran for the mismatched side" \
  grep -q 'create myfacade' "$SANDBOX/fc-mm-calls.log"

# --- and a proper component against the facade template likewise ---------------
cd "$NFC"
RUN=$SANDBOX/fc-run-nf CACHE=$FTPL BASE=$FBASE TARGET=$FTARGET \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/fc-nf.log"
if [[ $? -ne 0 ]]; then pass "a proper component materialized against the facade template is refused"; else fail "a proper component materialized against the facade template succeeded"; fi
expect "that refusal names the facade template" grep -q 'is the facade template' "$SANDBOX/fc-nf.log"

# --- manifest template.kind: facade decides when .init.mk carries no marker ------
MKC=$SANDBOX/facades/mkfacade
mkdir -p "$MKC/.kairos" && cd "$MKC" && git init -q -b main
printf 'module bitbucket.org/ifs-pd/mkfacade\n\ngo 1.21\n' > go.mod
printf 'name: mkfacade\ntemplate:\n  repo: file://%s\n  sha: %s\n  branch: main\n  kind: facade\n' "$FTPL" "$FBASE" > .kairos/manifest.yaml
git add -A && git commit -qm mk
: > "$SANDBOX/fc-mk-calls.log"
RUN=$SANDBOX/fc-run-mk CACHE=$FTPL BASE=$FBASE TARGET=$FTARGET FAKE_KAIROS_CALL_LOG=$SANDBOX/fc-mk-calls.log \
  PHASE_KEY=$PK_MATERIALIZE "$SKILL_DIR/scripts/materialize.sh" > /dev/null 2> "$SANDBOX/fc-mk.log"
expect "a manifest template.kind: facade materializes without the .init.mk marker" test $? -eq 0
expect "and it used 'component facade create'" grep -q '^component facade create mkfacade ' "$SANDBOX/fc-mk-calls.log"
cd "$COMP"
fi

finish_suite
