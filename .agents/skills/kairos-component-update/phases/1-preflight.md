## Phase 1: Pre-flight

PHASE_KEY: zsdjxztv
(Proof-of-load: this phase's entry script refuses to run without `PHASE_KEY=zsdjxztv` in its environment. The key is stated only in this file — never copy it into SKILL.md or another phase.)

Run the pre-flight script (checks in `reference/pre-flight.md`):

```bash
# anchor-exempt: this is the run's FIRST tool call — it establishes the anchor
# (pre-flight writes $RUN/context.env as its last check, after the fresh-mode
# sweep). There is nothing to re-read yet; every later block opens by reading it.
export RUN=.kairos/migration/state     # fixed path — one migration per repo at a time
# The values below are literals substituted from the invocation — nothing on
# disk can supply them yet (the anchor does not exist until this call writes it),
# and an unset variable here is not an error, it is an empty string: with an empty
# SKILL_DIR the very first command becomes `/scripts/pre-flight.sh: not found`.
SKILL_DIR="<absolute path to this skill's directory — you loaded SKILL.md from it>"
TEMPLATE_PATH="<the --template-path argument, or empty when not given>"
FRONTEND_PATH="<the --frontend-path argument, or empty when not given>"
# Bootstrap-only — leave both empty on every run except a bootstrap (no
# .kairos/manifest.yaml yet, so no template.repo / frontend.repo to fall back to)
# that also lacks the matching --*-path above. See the bootstrap notes below for
# when each is actually required.
TEMPLATE_REPO="<template repo URL, or empty — required on a bootstrap without --template-path>"
FRONTEND_REPO="<frontend repo URL, or empty — required on a bootstrapped frontend run without --frontend-path>"
# RUN_SOURCE says WHICH source this invocation migrates. Empty (or `template`) for a
# template run — the default and what every invocation meant before the second source
# existed. `frontend` for a frontend-only invocation and for the chained frontend
# re-entry after a template run finished (phases/8-finalize.md → Frontend-run consent):
# it is what makes check 0b skip the Kairos CLI probe and check 3 accept the finished
# run's migration branch. This block parses the invocation, so this is where it is set.
RUN_SOURCE=""                          # empty = template run; `frontend` for the two cases named above
PF=$(PHASE_KEY=zsdjxztv MODE=fresh RUN_SOURCE="$RUN_SOURCE" TEMPLATE_PATH="$TEMPLATE_PATH" FRONTEND_PATH="$FRONTEND_PATH" TEMPLATE_REPO="$TEMPLATE_REPO" FRONTEND_REPO="$FRONTEND_REPO" "$SKILL_DIR/scripts/pre-flight.sh"); PF_RC=$?
# Consume the captured status BEFORE any sed extraction: a non-zero exit is a hard
# stop (see below), and reading keys off a failed run's stdout would export empty
# CACHE/TEMPLATE_LOCAL_BRANCH values and let the block finish 0 on a refusal.
[ "$PF_RC" -eq 0 ] || { echo "FAIL: pre-flight.sh exited $PF_RC — relay its FAIL message above; do not proceed, do not write any state" >&2; exit 1; }
CACHE=$(printf '%s\n' "$PF" | sed -n 's/^CACHE=//p')
TEMPLATE_LOCAL_BRANCH=$(printf '%s\n' "$PF" | sed -n 's/^TEMPLATE_LOCAL_BRANCH=//p')   # empty unless --template-path
IN_PROGRESS_SOURCE=$(printf '%s\n' "$PF" | sed -n 's/^IN_PROGRESS_SOURCE=//p')          # empty unless a live block exists
```

`RUN` is set here (not Phase 3) because Phase 2's bellwether detection needs it; both `RUN` and `CACHE` are fixed paths the script also echoes on success. Capture `TEMPLATE_LOCAL_BRANCH` too — Phase 2's target default chain prefers it. **Relay any pre-flight `WARNING:` lines to the user** (a dirty local template means uncommitted content is invisible to the run); they are non-fatal, only a non-zero exit stops the migration.

Two more facts about the entry call itself, before the frontend-specific keys below:

- `MODE=continue` when continuing; otherwise `fresh`. **On a resume, do not run the code block above as written** — it takes `SKILL_DIR`/`TEMPLATE_PATH`/`FRONTEND_PATH` as literals substituted from the invocation, which a resumed session no longer has (that block is `anchor-exempt` precisely because it is the run's first call; a resume takes the same values from the anchor). `reference/continue.md` step 2 carries the anchor-sourced replacement block for this same call; load this phase for its key, then run that block instead.
- If `.kairos/manifest.yaml` is absent (bootstrap), **determine the template repo URL now** (origin remote, the user, or the canonical default). The default depends on the kind: if `.init.mk` sets `MASTERDATA_INCLUDE_NO_CDC`, or sets `GENERATE_MODULES` without `sql` or `all` (committed facades have `GENERATE_MODULES := masterdata json`; regular components leave it unset), this is a facade and the template is `git@ssh.bitbucket.org:ifs-pd/kairos-component-facade-template.git` — leave the slot empty and pre-flight defaults to it (and prints `TEMPLATE_REPO=`); Phase 2's manifest write takes the same URL. Otherwise the template is `git@ssh.bitbucket.org:ifs-pd/kairos-component-template.git`. Check 4 itself does nothing but print an INFO line — it enforces nothing about the URL — but check 7, the clone step later in this same script (checks 5 and 6 sit between them), reads `TEMPLATE_REPO` as the clone origin whenever `TEMPLATE_PATH` is unset and hard-fails right here, before Phase 2, when neither resolves: `--template-path` supplies a local origin and check 7 passes without a URL at all; otherwise fill in the `TEMPLATE_REPO=` slot in the code block above or the run stops before it ever reaches Phase 2. Phase 2's bootstrap manifest write (`in-progress.sh ACTION=bootstrap` refuses an empty `REPO`) then makes the same requirement durable in the manifest, but check 7 already refused it first — so have the URL settled now, not "before Phase 2 discovers its absence".

**The frontend source is the second thing this script reports on**, and it reports nothing at all when the component has none (no `frontend:` block and no `web/package.json`; the template's own `web/` shell has no `package.json`) — that silence is the contract for backend-only components, so do not go looking for the keys or prompt about `web/` when they are absent. When they are present, check 8.5's lines are all recorded in `$RUN/context.env` for the later phases and the frontend-run consent step, so read them from there rather than from this block's stdout:

- `FRONTEND_REPO` / `FRONTEND_SHA` / `FRONTEND_BRANCH` / `FRONTEND_TEMPLATE` / `FRONTEND_MODULE_PATH` / `FRONTEND_MOUNT` — the recorded `frontend:` block, emitted **only when one exists**. `FRONTEND_TEMPLATE` is the *module key* into the source repo's `.kairos-updates/config.yaml`; `FRONTEND_MOUNT` is defaulted to `web/` here when the recorded block omits it — but that is not the only place the default is applied. On a **bootstrap** there is no block yet, so this script emits nothing for `FRONTEND_MOUNT` at all; Phase 2.5's `materialize-frontend.sh` establishes the same `web/` default itself once the block exists, so don't read silence here as "unmounted" on that path.
- `FRONTEND_BOOTSTRAP` — `web/package.json` is present but no block was ever recorded: a frontend run would bootstrap its baseline in Phase 2. A candidate, not a decision.
- `FRONTEND_CACHE` — **only on a frontend run** (`RUN_SOURCE=frontend`): the mirror clone of the frontend source, established here by check 8.6 because Phase 2's SHA validation, the frontend bootstrap's scoring and Phase 3's module-scoped history walk all need it and none of them can build it. Those phases read it off the anchor instead of `CACHE`, which is the *template* mirror. Two consequences worth relaying: a frontend run **needs a reachable frontend source** and hard-stops without one (a template run clones nothing frontend-shaped and is unaffected), and on a **bootstrap** — `web/` present, no `frontend:` block, so no recorded `frontend.repo` — the origin resolves in this order: `FRONTEND_PATH` first (a local checkout given on this call always wins), then the manifest's `frontend.repo` (never populated on a bootstrap), then the `FRONTEND_REPO=` slot above. So the slot only needs filling when `--frontend-path` wasn't given either — the same fallback role `TEMPLATE_REPO` plays for the template on a component bootstrap.
- `FRONTEND_PATH` / `FRONTEND_LOCAL_BRANCH` — only under `--frontend-path`. The path is **normalized** to the enclosing git toplevel, so relay the `INFO:` line when the user pointed at a subtree, and relay the `WARNING:` when the subtree they pointed at is not the module their manifest selects — that one means the run is about to migrate against a different module than they were looking at.

- Non-zero exit → fail loudly, relay the script's FAIL message, do not proceed, do not write any state.
- **Each of check 3's refusals below has a next step you own, and they are different messages** — read which one you got before acting, because their remedies are not interchangeable. Full mechanics (exactly which branch/block shape triggers which message) are in `reference/pre-flight.md` check 3; these are the next steps, in the order the script actually checks them:
  - **"carries BOTH template.in_progress and frontend.in_progress"** — checked first, regardless of branch: the two-live-blocks state, which no reader can resolve (each block answers "which branch / which target / which rollback SHA" differently). It is unproducible through the scripts — `in-progress.sh ACTION=set` refuses to write one source's block while the other's exists — so arriving here means a hand-edit or a conflicted-merge restore. Show both blocks, work out with the user which run is real, and roll the stale one back through `reference/abort.md` against **that** source before anything else.
  - **"already on … and a migration is in progress. Run with continue/abort or switch branches first."** — the branch-glob arm: check 3 tests the current branch against `topic/*/template-update-*` (and `topic/*/frontend-update-*`), so *any* migration-shaped branch with a live block takes this arm, including one left by an unrelated older run. Its wording ends in a next step this skill's own rule forbids you from taking blindly: **do not switch branches**. Offer continue/abort — the recorded block is what continue and abort act on, and it is still there whatever branch the user happens to be standing on. Switching branches to get past a refusal is never yours to do. **This is the one that pre-empts "a … migration to … is in progress" below**: standing on a migration-shaped branch with the block still present, the script exits here and never reaches that later check — so if you are on such a branch, this message (not the one below) is what you get.
  - **"already on migration branch …, but .kairos/manifest.yaml records no migration in progress"** — the block-less shape, and it has **two** readings the script cannot tell apart on its own. Phase 4 crashed between `checkout -b` and the manifest write (the message's remedy: the user deletes the branch), **or** this is a frontend run chaining onto a *finished* template run's branch, which is a legitimate state — Phase 8 cleared the block on purpose and the frontend run keeps the branch so one PR carries both. `RUN_SOURCE=frontend` is what declares the second reading, and under it the script accepts the branch with an INFO line instead of refusing. So if you got this refusal on a frontend run, the fix is to pass the env — not to delete the branch the template run's commits are sitting on. Mutually exclusive with the arm above by construction (a branch either has a live block or doesn't), so this one is never what that arm pre-empts.
  - **"a … migration to … is in progress"** — checked last of the three, and only reached when the branch itself wasn't the problem: a fresh run refused because the live run owns `$RUN`, wherever the user happens to be standing. The message names the live run's **source** (`template` or `frontend`), and so does the `IN_PROGRESS_SOURCE=` line: continue and abort both act on that source's block, so relay which one it is. Offer continue (`reference/continue.md`) or abort (`reference/abort.md`) and let the user pick — never work around it, and never re-run with a different branch checked out.

**The Kairos CLI is a hard dependency of a TEMPLATE run, checked here.** Pre-flight requires it at **>= 0.3.12** and separately probes `component create --help` for `--no-tidy` / `--no-frontend` (on a facade, `component facade create --help`, CLI >= 0.3.35), because Phase 2.5 builds the merge sides with it. Failure is a hard stop: relay the "update nga-local-dev" message verbatim and **do not work around it** — there is no fallback path, and an old CLI is meant to stop the run here rather than corrupt it halfway through.

**On a frontend run (`RUN_SOURCE=frontend`) that probe is not applicable and is skipped** — `materialize-frontend.sh` extracts the module subtree at each SHA and applies the create-time replacement map itself, so no CLI is invoked. You get one INFO line saying so; relay it as a fact about the run, not as a degraded state. The same env is what makes check 3 accept the finished template run's migration branch, so a chained or frontend-only invocation passes it once, in the block above, and both behaviours follow.

**Also clone the `kairos-component-common` repo** (the shared Go libraries the component consumes) alongside the template, so Phase 3.5 can collect its consumer-facing upgrade-files. **Template runs only — on a frontend run (`RUN_SOURCE=frontend`) skip this whole step**: common is a Go-library dependency of the component, not of a frontend module, and Phase 3.5 is idle on that arm, so the absent `COMMON_*` keys ARE the record it reads (recording `COMMON_MODULES=present` here would arm Phase 6's `plan-completeness.sh` against a collection that correctly never runs, and the run would deadlock there). The script enforces the same arm itself — under `RUN_SOURCE=frontend` on the anchor it exits 0 with one INFO line and records nothing — so a mistaken call is harmless, but the correct move is not to make it. `scripts/clone-common.sh` owns the mechanics — the canonical module-path prefix, the mirror clone, and the clean degrade on a failed clone (its header says why a broken cache must never be left behind — and why a failed clone still records that common modules exist):

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# The exit status is checked BEFORE the keys are read: the script exits 1 on a
# missing or unreadable go.mod (this is a Go component migration — go.mod must
# exist), and a swallowed failure here would leave all three keys empty, which
# downstream reads as a settled "no common modules" answer instead of a failure.
CC=$(RUN=$RUN "$SKILL_DIR/scripts/clone-common.sh") \
  || { echo "FAIL: clone-common.sh refused — read its FAIL line above; do not proceed with empty COMMON_* keys" >&2; exit 1; }
export COMMON_REPO_PATH=$(printf '%s\n' "$CC" | sed -n 's/^COMMON_REPO_PATH=//p')
export COMMON_MODULES=$(printf '%s\n' "$CC" | sed -n 's/^COMMON_MODULES=//p')
COMMON_CACHE=$(printf '%s\n' "$CC" | sed -n 's/^COMMON_CACHE=//p')
if [ -n "$COMMON_CACHE" ]; then export COMMON_CACHE; else unset COMMON_CACHE; fi
```

A non-zero exit is a hard stop for the phase — relay the script's `FAIL:` line and stop; a failed *clone* still exits 0 (the clean degrade described above), so an actual refusal means the component itself is malformed. Relay any `WARN:` line it printed. `COMMON_REPO_PATH` and `COMMON_MODULES` are recorded in `$RUN/context.env` on **every** path; `COMMON_CACHE` only when the mirror is usable, so its absence there is never the record of anything. The two keys answer two different questions and Phase 3.5 branches on both — `phases/3.5-collect-common.md`'s branch table owns what each combination means; don't re-derive it here.

Pre-flight itself records `CACHE`, `SKILL_DIR`, `TEMPLATE_PATH` (when a local template was given), `TEMPLATE_LOCAL_BRANCH`, `RUN_SOURCE` (when the invocation declared one — Phase 2's own write of the same key re-states it idempotently), every `FRONTEND_*` key check 8.5 established, and `FRONTEND_CACHE` from check 8.6 on a frontend run, into `$RUN/context.env` — Phase 3.5's wrong-target tripwire reads `TEMPLATE_PATH` from there, never from conversation memory, and every later phase code block reads `SKILL_DIR` from there to locate the scripts (SKILL.md → Run-context anchor). This is the run's first write to the anchor, and it is why every block after this one can open by reading it.

**Phase exit — Phase 1.5 runs NEXT, after this phase and before Phase 2**: load `phases/1.5-model-resolution.md`. The ordering is load-bearing: pre-flight's fresh-mode sweep would delete a `$RUN/model.txt` written any earlier.
