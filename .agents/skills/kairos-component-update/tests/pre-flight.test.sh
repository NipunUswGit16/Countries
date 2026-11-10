#!/usr/bin/env bash
# pre-flight.test.sh — invocation-level checks in scripts/pre-flight.sh that do
# NOT need the mutating merge chain: the git-toplevel guard (check 0a), the
# continue-mode dirty exemption (check 1), and the fresh-over-live-$RUN interlock
# (check 6). The sequence-dependent behaviors (mirror build, sweep spares,
# materialize hand-off) stay in merge-path.test.sh; these three reason from a
# single pre-flight invocation against a static tree, so they get their own suite.
#
# Each block builds its own throwaway component + template repo so nothing leaks
# between tests (no shared mutable fixture chain — TEST_FILTER is therefore fine).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

# PF_OVERRIDE lets a mutation/regression check point at a copy of the script
# under test (e.g. the pre-fix version) without touching the shipped file.
PF="${PF_OVERRIDE:-$SKILL_DIR/scripts/pre-flight.sh}"

# A minimal template repo to clone from (check 7 needs a real git repo at
# TEMPLATE_PATH; the content is irrelevant to these checks).
PFT_TPL=$SANDBOX/tpl
mkdir -p "$PFT_TPL" && ( cd "$PFT_TPL" && git init -qb main \
  && echo hi > a.txt && git add -A && git commit -qm init ) >/dev/null 2>&1

# A minimal FRONTEND source repo for the RUN_SOURCE=frontend arm (check 8.6 needs
# a clone origin; RUN_SOURCE=frontend also skips the Kairos CLI probe).
PFT_FE=$SANDBOX/fe
mkdir -p "$PFT_FE" && ( cd "$PFT_FE" && git init -qb main \
  && mkdir -p template/react && echo x > template/react/p.txt \
  && git add -A && git commit -qm init ) >/dev/null 2>&1

# new_comp <name> — a fresh component checkout with a committed manifest naming
# the template. Prints its path; leaves cwd there.
new_comp() {
  local c="$SANDBOX/$1"
  mkdir -p "$c/.kairos"
  cd "$c"
  git init -qb main >/dev/null 2>&1
  printf 'name: mycomp\ntemplate:\n  repo: file://%s\n  sha: deadbeef\n  branch: main\n' "$PFT_TPL" > .kairos/manifest.yaml
  echo file > f.txt
  git add -A && git commit -qm init >/dev/null 2>&1
  printf '%s' "$c"
}

# set_block <comp> — commit a template.in_progress block so continue mode has a
# live run to resume (branch mode, on main).
set_block() {
  printf 'name: mycomp\ntemplate:\n  repo: file://%s\n  sha: deadbeef\n  branch: main\n  in_progress:\n    target_sha: cafe1234\n    branch: main\n    previous_branch: main\n' "$PFT_TPL" > "$1/.kairos/manifest.yaml"
  git -C "$1" commit -qam block >/dev/null 2>&1
}

# seed_live_run <comp> — the on-disk shape of a run that passed pre-flight
# (context.env recorded) and reached Phase 3.5 (an unpromoted Q&A ledger) but
# NEVER reached Phase 4 (no PREV_SHA anchored, no in-progress block).
seed_live_run() {
  mkdir -p "$1/.kairos/migration/state"
  printf 'SKILL_DIR=%s\nCACHE=.kairos/migration/state/template\nBASE=b\nTARGET=t\n' \
    "$SKILL_DIR" > "$1/.kairos/migration/state/context.env"
  printf 'q1\tanswered-by-the-live-run\n' > "$1/.kairos/migration/state/qa-ledger.tsv"
  printf 'strong=live-pin\ncoder=live-pin\nexecutor=live-pin\nbudget=balanced\n' \
    > "$1/.kairos/migration/state/model.txt"
}

# ---------------------------------------------------------------------------
# SC2 — the git-toplevel guard (check 0a)
# ---------------------------------------------------------------------------
if t "check 0a refuses a run from a subdirectory (git toplevel guard)"; then
# From a subdir, check 1's pathspec-scoped dirty scan reports clean with the root
# dirty, the manifest is invisible so the live-run refusals skip, and check 6
# creates a SECOND state dir under the subdir. One toplevel comparison closes all
# three — verified here from web/sub of a component whose root is also dirty.
C=$(new_comp sc2)
cd "$C"
mkdir -p "$C/web/sub"
# Root is CLEAN on purpose: without the guard a subdir run sails through check 1
# (clean tree) and reaches check 6, which creates a SECOND state dir under the
# subdir — the hazard the refute below pins. The guard must catch it before that.
( cd "$C/web/sub" && MODE=fresh TEMPLATE_PATH=$PFT_TPL PHASE_KEY=$PK_PREFLIGHT "$PF" ) \
  > "$SANDBOX/sc2-sub.out" 2> "$SANDBOX/sc2-sub.log"
SC2_RC=$?
if [[ "$SC2_RC" -ne 0 ]]; then pass "a subdir invocation is refused"; else fail "a subdir invocation was accepted"; fi
expect "the refusal says to run from the component root" \
  grep -q 'must be run from the component root' "$SANDBOX/sc2-sub.log"
expect "the refusal names the git toplevel to cd to" \
  grep -qF "$C" "$SANDBOX/sc2-sub.log"
refute "no second state dir is created under the subdir (RUN is cwd-relative)" \
  test -e "$C/web/sub/.kairos/migration/state"
refute "the refused subdir run emits no RUN/CACHE lines" \
  grep -qE '^(RUN|CACHE)=' "$SANDBOX/sc2-sub.out"
fi

if t "check 0a passes at the component root (the guard is not vacuous)"; then
C=$(new_comp sc2ok)
cd "$C"
MODE=fresh TEMPLATE_PATH=$PFT_TPL PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > "$SANDBOX/sc2-root.out" 2> "$SANDBOX/sc2-root.log"
expect "a root invocation passes" test $? -eq 0
expect "and emits RUN" grep -q '^RUN=' "$SANDBOX/sc2-root.out"
# A first-ever fresh run on a clean component has no leftover to sweep, so the sweep
# decision line must stay silent — the announcement fires only on a real cleanup.
refute "a clean first run emits no sweep announcement" \
  grep -qi 'swept leftover migration scratch' "$SANDBOX/sc2-root.log"
fi

# ---------------------------------------------------------------------------
# Check 7 — a stale --template-path checkout is fetched before it is mirrored,
# so a BASE/TARGET released upstream since the checkout last fetched is present
# in the mirror instead of resolving to nothing in Phase 2. The mirror is cloned
# FROM the local checkout, so without the pre-fetch it inherits the stale ref set.
# ---------------------------------------------------------------------------
if t "check 7 fetches a stale --template-path checkout so the mirror carries refs released upstream since"; then
C=$(new_comp fetchcomp); cd "$C"
# origin the local checkout is cloned from; v-new is tagged AFTER the clone is taken
TORIG=$SANDBOX/tpl-origin-fetch
mkdir -p "$TORIG" && ( cd "$TORIG" && git init -qb main \
  && echo hi > a.txt && git add -A && git commit -qm init && git tag v-old ) >/dev/null 2>&1
TLOCAL=$SANDBOX/tpl-local-fetch
git clone -q "$TORIG" "$TLOCAL" >/dev/null 2>&1        # stale hereafter: v-old only
( cd "$TORIG" && echo more >> a.txt && git commit -qam more && git tag v-new ) >/dev/null 2>&1
if git -C "$TLOCAL" rev-parse -q --verify "refs/tags/v-new^{commit}" >/dev/null 2>&1; then
  fail "fixture bug: local --template-path checkout already has v-new before pre-flight"
else
  pass "fixture: local --template-path checkout is behind its remote (no v-new yet)"
fi
MODE=fresh TEMPLATE_PATH=$TLOCAL PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > "$SANDBOX/pf-fetch.out" 2> "$SANDBOX/pf-fetch.log"
expect "pre-flight with a stale --template-path exits 0" test $? -eq 0
PF_CACHE=$C/.kairos/migration/state/template
expect "the template mirror carries the tag released upstream after the local checkout (pre-fetch worked)" \
  bash -c "git -C '$PF_CACHE' rev-parse -q --verify 'refs/tags/v-new^{commit}' >/dev/null 2>&1"
expect "the pre-fetch updated the local checkout's tags (non-destructive: HEAD untouched)" \
  bash -c "git -C '$TLOCAL' rev-parse -q --verify 'refs/tags/v-new^{commit}' >/dev/null 2>&1"
expect "and the local checkout's HEAD is still its own commit, not moved by the fetch" \
  bash -c "test \"\$(git -C '$TLOCAL' rev-parse HEAD)\" = \"\$(git -C '$TORIG' rev-parse v-old)\""
fi

# ---------------------------------------------------------------------------
# Checks 7 / 8.5 / 8.6 — a manifest written before Bitbucket moved SSH to
# ssh.bitbucket.org still names bitbucket.org, which no longer serves SSH. The
# mirrors must be cloned from the current host. Offline: a sandbox insteadOf
# serves git@ssh.bitbucket.org: from local bare repos, and GIT_SSH_COMMAND=false
# makes any dial of the old host fail, so a pass proves the URL was mapped first.
# ---------------------------------------------------------------------------
BB_ROOT=$SANDBOX/bb
mkdir -p "$BB_ROOT/ifs-pd"
git clone -q --bare "$PFT_TPL" "$BB_ROOT/ifs-pd/tpl.git" >/dev/null 2>&1
git clone -q --bare "$PFT_FE" "$BB_ROOT/ifs-pd/fe.git" >/dev/null 2>&1
BB_GITCONFIG=$SANDBOX/gitconfig-bb
cp "$GIT_CONFIG_GLOBAL" "$BB_GITCONFIG" 2>/dev/null || : > "$BB_GITCONFIG"
git config --file "$BB_GITCONFIG" url."file://$BB_ROOT/".insteadOf "git@ssh.bitbucket.org:"

# new_bb_comp <name> [frontend] — a component whose manifest names the template (and
# optionally the frontend) on the OLD Bitbucket SSH host.
new_bb_comp() {
  local c="$SANDBOX/$1"
  mkdir -p "$c/.kairos"
  cd "$c"
  git init -qb main >/dev/null 2>&1
  printf 'name: mycomp\ntemplate:\n  repo: git@bitbucket.org:ifs-pd/tpl.git\n  sha: deadbeef\n  branch: main\n' > .kairos/manifest.yaml
  if [[ "${2:-}" = frontend ]]; then
    printf 'frontend:\n  repo: git@bitbucket.org:ifs-pd/fe.git\n  path: template/react\n  template: react\n  branch: main\n  sha: deadbeef\n' >> .kairos/manifest.yaml
  fi
  echo file > f.txt
  git add -A && git commit -qm init >/dev/null 2>&1
  printf '%s' "$c"
}

if t "check 7 clones a manifest's old bitbucket.org template repo from ssh.bitbucket.org"; then
C=$(new_bb_comp bbcomp); cd "$C"
GIT_CONFIG_GLOBAL=$BB_GITCONFIG GIT_SSH_COMMAND=false MODE=fresh PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > "$SANDBOX/bb.out" 2> "$SANDBOX/bb.log"
expect "pre-flight with an old-host template.repo exits 0" test $? -eq 0
expect "it says it mapped the template repo to the current host" \
  grep -qF 'cloning from git@ssh.bitbucket.org:ifs-pd/tpl.git' "$SANDBOX/bb.log"
expect "the template mirror's origin is on ssh.bitbucket.org" \
  bash -c "test \"\$(git -C '$C/.kairos/migration/state/template' config --get remote.origin.url)\" = git@ssh.bitbucket.org:ifs-pd/tpl.git"
expect "pre-flight leaves the committed manifest alone (Phase 8's advance writes it back)" \
  bash -c "test \"\$(yq -r '.template.repo' '$C/.kairos/manifest.yaml')\" = git@bitbucket.org:ifs-pd/tpl.git"
fi

if t "check 7 re-points a mirror cloned from the old host instead of re-cloning it"; then
C=$(new_bb_comp bbreuse); cd "$C"
GIT_CONFIG_GLOBAL=$BB_GITCONFIG GIT_SSH_COMMAND=false MODE=fresh PHASE_KEY=$PK_PREFLIGHT "$PF" >/dev/null 2>&1
MIRROR=$C/.kairos/migration/state/template
git -C "$MIRROR" remote set-url origin git@bitbucket.org:ifs-pd/tpl.git
touch "$MIRROR/reuse-marker"
git -C "$C" add -A >/dev/null 2>&1; git -C "$C" commit -qm "pre-flight bookkeeping" >/dev/null 2>&1
GIT_CONFIG_GLOBAL=$BB_GITCONFIG GIT_SSH_COMMAND=false MODE=fresh PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > /dev/null 2> "$SANDBOX/bb-reuse.log"
expect "the second pre-flight exits 0" test $? -eq 0
expect "the old-host mirror is refreshed, not re-cloned" \
  bash -c "grep -q 'refreshed existing template clone' '$SANDBOX/bb-reuse.log' && test -e '$MIRROR/reuse-marker'"
expect "the reused mirror now points at ssh.bitbucket.org" \
  bash -c "test \"\$(git -C '$MIRROR' config --get remote.origin.url)\" = git@ssh.bitbucket.org:ifs-pd/tpl.git"
fi

if t "checks 8.5 / 8.6 map a manifest's old bitbucket.org frontend repo to ssh.bitbucket.org"; then
C=$(new_bb_comp bbfe frontend); cd "$C"
GIT_CONFIG_GLOBAL=$BB_GITCONFIG GIT_SSH_COMMAND=false MODE=fresh RUN_SOURCE=frontend PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > "$SANDBOX/bbfe.out" 2> "$SANDBOX/bbfe.log"
expect "a frontend pre-flight with an old-host frontend.repo exits 0" test $? -eq 0
expect "FRONTEND_REPO is emitted on the current host" \
  grep -qx 'FRONTEND_REPO=git@ssh.bitbucket.org:ifs-pd/fe.git' "$SANDBOX/bbfe.out"
refute "the old-host FRONTEND_REPO is never emitted" \
  grep -qx 'FRONTEND_REPO=git@bitbucket.org:ifs-pd/fe.git' "$SANDBOX/bbfe.out"
expect "the frontend mirror's origin is on ssh.bitbucket.org" \
  bash -c "test \"\$(git -C '$C/.kairos/migration/state/frontend' config --get remote.origin.url)\" = git@ssh.bitbucket.org:ifs-pd/fe.git"
fi

# ---------------------------------------------------------------------------
# SM1 — continue mode exempts .kairos/manifest.yaml (check 1)
# ---------------------------------------------------------------------------
if t "check 1 exempts a dirty .kairos/manifest.yaml under MODE=continue"; then
# Two resume windows leave the manifest dirty by design: killed after Phase 4's
# in-progress `set` but before the scaffolding commit, and killed inside Phase 8
# step 5 between the baseline advance and its commit. continue.md forbids
# committing/stashing past this check, so an un-exempt manifest makes every triage
# arm (which runs step 2's pre-flight first) a dead end.
C=$(new_comp sm1-pass)
cd "$C"
set_block "$C"
# Dirty ONLY the manifest (advance the baseline sha in place, block still present).
printf 'name: mycomp\ntemplate:\n  repo: file://%s\n  sha: cafe1234\n  branch: main\n  in_progress:\n    target_sha: cafe1234\n    branch: main\n    previous_branch: main\n' "$PFT_TPL" > "$C/.kairos/manifest.yaml"
MODE=continue TEMPLATE_PATH=$PFT_TPL PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > /dev/null 2> "$SANDBOX/sm1-pass.log"
expect "continue mode passes with only the manifest dirty" test $? -eq 0
refute "no dirty-tree refusal for the by-design manifest edit" \
  grep -qi 'working tree is dirty' "$SANDBOX/sm1-pass.log"
fi

if t "check 1 still refuses a dirty tracked source file under MODE=continue"; then
# The exemption is exactly the four by-design paths (migration-log.md, intent.md,
# manifest.yaml, .gitignore) — anything else is still a refusal, and it points at
# continue.md's triage rather than 'commit or stash'.
C=$(new_comp sm1-beyond)
cd "$C"
set_block "$C"
echo "stray edit" >> "$C/f.txt"
MODE=continue TEMPLATE_PATH=$PFT_TPL PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > /dev/null 2> "$SANDBOX/sm1-beyond.log"
if [[ $? -ne 0 ]]; then pass "continue mode refuses dirt beyond the exempt paths"; else fail "continue mode passed with a dirty tracked source file"; fi
expect "the refusal names the boundary (dirty beyond ...)" \
  grep -q 'dirty beyond' "$SANDBOX/sm1-beyond.log"
expect "the boundary message now lists the manifest as exempt" \
  grep -q 'manifest.yaml' "$SANDBOX/sm1-beyond.log"
expect "the refusal points at continue.md's triage" \
  grep -q 'continue\.md' "$SANDBOX/sm1-beyond.log"
fi

if t "check 1 does NOT exempt the manifest under fresh mode"; then
# The exemption is continue-only: a fresh run over a dirty manifest is still the
# ordinary clean-tree refusal.
C=$(new_comp sm1-fresh)
cd "$C"
printf '\n# stray line\n' >> "$C/.kairos/manifest.yaml"
MODE=fresh TEMPLATE_PATH=$PFT_TPL PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > /dev/null 2> "$SANDBOX/sm1-fresh.log"
if [[ $? -ne 0 ]]; then pass "fresh mode refuses a dirty manifest"; else fail "fresh mode accepted a dirty manifest"; fi
expect "fresh mode keeps the commit-or-stash message" \
  grep -q 'Commit or stash' "$SANDBOX/sm1-fresh.log"
fi

# ---------------------------------------------------------------------------
# SM7 — the fresh-over-live-$RUN interlock (check 6)
# ---------------------------------------------------------------------------
if t "check 6 refuses a fresh sweep over a live pre-Phase-4 run's Q&A ledger"; then
# A second fresh invocation launched while a first run is mid-Phase-3.5: no block
# exists yet (Phase 4 writes it), so check 3 waves the run through, and the sweep
# would delete the first run's unpromoted qa-ledger — the one artifact that lives
# nowhere else. Refuse instead, and preserve the ledger.
C=$(new_comp sm7-live)
cd "$C"
seed_live_run "$C"
MODE=fresh TEMPLATE_PATH=$PFT_TPL PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > "$SANDBOX/sm7-live.out" 2> "$SANDBOX/sm7-live.log"
if [[ $? -ne 0 ]]; then pass "a fresh run over a live pre-Phase-4 ledger is refused"; else fail "a fresh run swept a live pre-Phase-4 ledger"; fi
expect "the refusal names the unpromoted Q&A ledger" \
  grep -q 'unpromoted Q&A ledger' "$SANDBOX/sm7-live.log"
expect "the refusal names the SWEEP_STALE_RUN escape hatch" \
  grep -q 'SWEEP_STALE_RUN=1' "$SANDBOX/sm7-live.log"
expect "the live run's Q&A ledger survived un-swept" \
  grep -q 'answered-by-the-live-run' "$C/.kairos/migration/state/qa-ledger.tsv"
expect "the live run's model.txt survived un-swept" \
  grep -qx 'strong=live-pin' "$C/.kairos/migration/state/model.txt"
refute "the refused run emits no RUN/CACHE lines" \
  grep -qE '^(RUN|CACHE)=' "$SANDBOX/sm7-live.out"
fi

if t "check 6 sweeps a live pre-Phase-4 ledger when SWEEP_STALE_RUN is set"; then
# The escape hatch for a genuinely stale leftover (a crash before Phase 4, or a
# rollback that already salvaged the ledger).
C=$(new_comp sm7-ack)
cd "$C"
seed_live_run "$C"
MODE=fresh SWEEP_STALE_RUN=1 TEMPLATE_PATH=$PFT_TPL PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > /dev/null 2> "$SANDBOX/sm7-ack.log"
expect "the acknowledged fresh run passes" test $? -eq 0
refute "the stale ledger was swept" test -e "$C/.kairos/migration/state/qa-ledger.tsv"
fi

if t "check 6 sweeps a FINISHED run's leftover ledger (PREV_SHA present) — no ack needed"; then
# The common case: a completed run leaves $RUN in place (8-finalize.md keeps it
# for post-mortem), and its context.env carries PREV_SHA (anchored at Phase 4,
# re-anchored at Phase 8). The next fresh migration must sweep it silently, as
# before — the interlock must not turn every ordinary re-migration into a prompt.
C=$(new_comp sm7-finished)
cd "$C"
seed_live_run "$C"
printf 'PREV_SHA=abcdef1234567890\n' >> "$C/.kairos/migration/state/context.env"
MODE=fresh TEMPLATE_PATH=$PFT_TPL PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > /dev/null 2> "$SANDBOX/sm7-finished.log"
expect "a fresh run over a finished run's leftover passes" test $? -eq 0
refute "the finished run's leftover ledger was swept" \
  test -e "$C/.kairos/migration/state/qa-ledger.tsv"
# The sweep announces its decision so the orchestrator relays ground truth instead
# of theorizing fresh-vs-resume from the state dir it can still see.
expect "the sweep announces it as a FRESH run (not a resume), naming the leftover" \
  bash -c "grep -qi 'swept leftover migration scratch' '$SANDBOX/sm7-finished.log' && grep -qi 'FRESH run' '$SANDBOX/sm7-finished.log'"
fi

if t "check 6 sweeps by design on the chained frontend re-entry (RUN_SOURCE=frontend)"; then
# The chained frontend re-entry sweeps the finished template run's $RUN on
# purpose (8-finalize.md). The interlock must exempt RUN_SOURCE=frontend even
# though the ledger is present and PREV_SHA is absent.
C=$(new_comp sm7-fe)
cd "$C"
seed_live_run "$C"
MODE=fresh RUN_SOURCE=frontend FRONTEND_PATH=$PFT_FE PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > /dev/null 2> "$SANDBOX/sm7-fe.log"
expect "a chained frontend re-entry passes" test $? -eq 0
refute "the frontend re-entry swept the stale ledger by design" \
  test -e "$C/.kairos/migration/state/qa-ledger.tsv"
fi

if t "check 6 does NOT fire on a pre-flight-only leftover (context.env, no ledger)"; then
# A $RUN that carries only what pre-flight itself recorded (no Q&A yet) has
# nothing irrecoverable to protect — a repeated fresh invocation must sweep and
# succeed. This is the shape merge-path.test.sh re-runs pre-flight over.
C=$(new_comp sm7-noledger)
cd "$C"
mkdir -p "$C/.kairos/migration/state"
printf 'CACHE=.kairos/migration/state/template\nSKILL_DIR=%s\n' "$SKILL_DIR" \
  > "$C/.kairos/migration/state/context.env"
touch "$C/.kairos/migration/state/stale-marker"
MODE=fresh TEMPLATE_PATH=$PFT_TPL PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > /dev/null 2> "$SANDBOX/sm7-noledger.log"
expect "a fresh run over a ledgerless leftover passes" test $? -eq 0
refute "the ledgerless stale marker was swept" \
  test -e "$C/.kairos/migration/state/stale-marker"
fi

if t "check 6 does NOT fire when a live BLOCK exists (check 3 owns that refusal)"; then
# With an in-progress block present the run is refused by check 3, not check 6 —
# the interlock only covers the block-less pre-Phase-4 window.
C=$(new_comp sm7-block)
cd "$C"
set_block "$C"
seed_live_run "$C"
MODE=fresh TEMPLATE_PATH=$PFT_TPL PHASE_KEY=$PK_PREFLIGHT "$PF" \
  > /dev/null 2> "$SANDBOX/sm7-block.log"
if [[ $? -ne 0 ]]; then pass "a fresh run over a live block is refused"; else fail "a fresh run over a live block was accepted"; fi
expect "the refusal is check 3's live-migration message" \
  grep -q 'a migration is in progress' "$SANDBOX/sm7-block.log"
refute "and NOT the interlock's — check 3 owns this refusal, before the sweep" \
  grep -q 'unpromoted Q&A ledger' "$SANDBOX/sm7-block.log"
expect "the live block run's ledger survived" \
  grep -q 'answered-by-the-live-run' "$C/.kairos/migration/state/qa-ledger.tsv"
fi

finish_suite
