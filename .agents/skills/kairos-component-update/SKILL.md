---
name: kairos-component-update
description: Update a Kairos component to a newer template version — a 3-way structural merge against the template, apply upgrade-files, run tests per task, track provenance in .kairos/. Use when the user invokes /kairos-component-update or asks to update, migrate, or upgrade a component to the latest template, to a specific template SHA, or against a template branch — also when asked to update the component's `web/` frontend to a newer frontend-template version, or to adopt or bootstrap the template baseline for a component with no `.kairos/manifest.yaml` yet (or a `web/` with no `frontend:` block); to continue, resume, or pick up a template or frontend migration whose `.kairos/manifest.yaml` carries a `template.in_progress` or `frontend.in_progress` block; and to abort/cancel/undo such a migration at any point, whether or not that block is still present. Do NOT use to migrate a component to Nexus Auth Gateway (kairos-auth-gateway-migration) or to author upgrade-files (kairos-document-updates).
---

# kairos component update

You drive a Kairos component migration. Your role is orchestration — pre-flight, structural merge, branch management, commits, final state. Two phases delegate to specialist agents whose role files you load on demand — the **planner** (Phase 6) and the **executor** (Phase 7); structural conflicts in Phase 5 go to a third specialist, the **conflict-resolver**. How each runs:

- **Planner** — always an in-conversation role switch; it needs the shared Q&A context with the user, so it never runs as a subagent on any harness.
- **Executor and conflict-resolver** — run as subagents wherever you have **runtime subagent dispatch**: one call that takes a prompt you write and a model you choose. That capability, not the harness's name, is the only thing this skill branches on, and you answer it from your own tool surface — if you can dispatch a generic subagent with an inline prompt and a per-call model, you have it. It buys fresh context per task, a cheaper model where the volume is, and conflict resolution dispatched in context-sized batches — sequential by default, parallel only on user request (Phase 5 owns the batching rule). Where dispatch is genuinely absent, both fall back to in-conversation role switches with the same instructions.

You operate in the component's working directory (the cwd at invocation). You never push to a remote. You never modify `.kairos-updates/` (template-only; it lives in the template repo, not the component repo). You commit per task on a side branch by default.

**The mechanical steps are scripts, not prose.** Set `SKILL_DIR` to this skill's directory and run the scripts under `$SKILL_DIR/scripts/` — don't retype their logic as ad-hoc commands. The `reference/` docs explain why the scripts work as they do; the scripts are the source of truth for the mechanics.

**Shell state does not persist between tool calls** — variables, `export`s, and `cd`s are gone by the next Bash tool call. Re-set every documented env var at the top of each code block; never rely on one set in an earlier block.

## Speaking to the user

Every question, status line, and refusal you put in front of the user is for a **component owner who wants their component updated** and does **not** know this skill's internals. The phase docs and script messages below name things in the skill's own vocabulary for *your* precision — that vocabulary is for your reasoning, `$RUN`, and `.kairos/migration-log.md`, never the thing you hand the user verbatim. Whenever you surface something:

- **Lead with the decision they face and what it means for their update** — not the internal artifact behind it. ("I couldn't tell which of the `toolkit` library's update steps apply" — not "toolkit is unresolvable".)
- **Never make an internal term the price of answering.** If one is unavoidable, gloss it in the same breath (upgrade-file → "a migration step the template author wrote").
- **Offer concrete options in plain words, with a recommended default** and one clause of why.
- **When you relay a script's `FAIL`/refusal, translate it** — the script line is a precise diagnostic; the user needs the choice and the consequence, not the internal cause.

Quick translations (internal → what the user hears):

| internal | say instead |
|---|---|
| `in_progress` block / migration in progress | "this component already has an update under way" |
| continue / abort | "pick up where it left off" / "undo it, back to how things were" |
| `BASE..TARGET` | "the versions you're moving from and to" |
| upgrade-file | "a migration step the template author wrote" |
| unresolvable (common module) | "I couldn't work out which of that library's steps apply" |
| co-development / local-path replace | "this component is being built together with the shared library" |
| bellwether / bootstrap baseline | "working out which template version this component started from" |
| the (postmerge) gate | "the automated check that the update is complete and consistent" |

This changes **how** you say things, never **what** you ask or the precision the phases require — that precision stays in your reasoning and the logs. Phase docs write questions in internal terms as a *specification of the decision*, not a script to read aloud; translate every one.

## Mode detection (first thing you do)

- **Abort** — user said abort / cancel / undo / get me back. Load `reference/abort.md` and follow it; do not proceed to the phases.
- **Continue** — user said continue / resume / pick up AND `.kairos/manifest.yaml` has a `template.in_progress` **or** a `frontend.in_progress` block. Load `reference/continue.md`; it tells you which phase to resume into. **The block that exists names the run's SOURCE** — at most one exists (they are mutually exclusive live runs, and pre-flight refuses a manifest carrying both), and every step of continue and abort acts on that source's block, never on "the in-progress block" generically.
- **Fresh run** — everything else. Start at Phase 1. Leftover `.kairos/migration/state/` on disk is **not** a resume and needs no inspection or theory from you: a fresh run never destroys a live migration — pre-flight *refuses* over an `in_progress` block (check 3) or a still-live pre-Phase-4 Q&A ledger (check 6), and only sweeps **dead** scratch, which it announces. So "the user didn't say continue" is not what makes proceeding safe; pre-flight's guards are. Relay pre-flight's own sweep/refusal line — don't narrate a fresh-vs-resume story from the state dir.

`reference/abort.md` and `reference/continue.md` are the **two deliberate exceptions** to the "reference/ explains, scripts are the source of truth" rule above: they are *procedures* — the abort and continue runbooks, with step ordering that lives nowhere else — not rationale docs like the rest of `reference/`. There is no `abort.sh` / `continue.sh` for them to explain; they carry the mechanics themselves, which is why Mode detection *loads and follows* them the way a phase file is followed, rather than reading them for the "why." Everything else under `reference/` is pure rationale behind a script, with two further exceptions that are neither runbook nor rationale: `reference/model-families.yaml`, the family catalog `scripts/resolve-models.sh` reads as a runtime data input, and `reference/gate-cards.md`, an interpretation contract you load to act on gate output.

**How a `reference/` citation reads.** A bare parenthetical citation — `(reference/pre-flight.md, checks 7–8)`, `(reference/gates.md)` — is a **pointer** to where the reasoning lives; read it only when a decision actually turns on that detail. An explicit **`Load X`** or **`Read X, then …`** means read it now. The two **load-and-act exceptions** — `reference/gate-cards.md` and `reference/model-families.yaml` — announce themselves at their use sites (a gate's verdict card, a model resolution), so they are read when you act on them even where a phase cites them bare.

## Model selection

Three tier pins for the run plus the budget posture — four lines in `$RUN/model.txt`. Selection is Decision A here; per-task routing (Decision B) is in Phase 7 from the plan's `Flag`:

- **`<STRONG_MODEL>`** — judgment roles (orchestrator, planner, conflict-resolver, flagged/bootstrapped verifiers). Conflict-resolver subagents always use it.
- **`<CODER_MODEL>`** — mid coding tier for `Flag`-set / bootstrapped / no-tests-code / regression-fix executors.
- **`<EXECUTOR_MODEL>`** — cheap/fast tier for routine executors and routine verifiers (most token volume).

**Where you have runtime subagent dispatch**, orchestrator and planner run on the session model; **every dispatched subagent names its model explicitly** — never inherit the session model. **In the role-switch fallback** there is no per-call model; the split is advice to the user.

**You do not pick models by judgment — `scripts/resolve-models.sh` does**, in Phase 1.5, which writes the four pins to `$RUN/model.txt` (`strong=` / `coder=` / `executor=` / `budget=`). The pins are **strictly per-run and never persisted** to `.kairos/manifest.yaml` or `~/.kairos/models.yaml`. The resolution mechanics, the surface-them-immediately rule, and the mid-run correction path are in `phases/1.5-model-resolution.md`; why the script decides the way it does is in `reference/model-resolution.md`.

The pins are a **checked contract, not advice** — `log-spawn.sh` enforces them at record time (the mechanics are in Spawn accounting below).

## Spawn accounting

Every subagent dispatch — Phase 5 conflict-resolvers, Phase 7 executors and verifiers alike — lands one row in `$RUN/spawns.tsv`, appended by `scripts/log-spawn.sh` at its dispatch site with that phase's own `PHASE_KEY` (`phases/5-structural.md` step (d), `phases/7-execution.md` step 6, which also fix the `retried` / `escalated` outcomes to their triggers). Pass the fields as env vars and let the script own the format.

`log-spawn.sh` enforces the pins: it refuses without the dispatching phase's `PHASE_KEY`, refuses when `$RUN/model.txt` is absent, and refuses any dispatch whose `MODEL` is not the pin for the `TIER` it declares — re-dispatch on the pin and the row lands. It is a *recorder*, not a preventer, and the model column it records is named `requested_model`, not the model the harness actually ran; why each is so is in `reference/model-resolution.md`.

The **first dispatch of the run** carries an **actual-model probe** — one extra sentence asking the subagent to report the model it believes it is, recorded in `ACTUAL_MODEL`; the requested/actual comparison and every other rationale live in `reference/model-resolution.md`.

Phase 8 summarizes `$RUN/spawns.tsv` with `scripts/spawn-summary.sh`, which emits a MISMATCH line when a probed actual differs (see Phase 8).

## Intent ledger

User intent must outlive your context window — it feeds fresh-context subagents and future runs. Two files carry it, and both record the user's **answers** (intent facts about the component), never per-file **verdicts** (verdicts go stale as the tree changes; each resolver re-derives its own verdict from the current tree plus recorded intent):

- **`$RUN/qa-ledger.tsv`** — run-scoped (gitignored with the rest of `$RUN`). Schema: `scope <TAB> question <TAB> answer <TAB> phase` (scope being a path/module when the question concerns one). **Append at answer time, in whatever phase — always through `scripts/log-intent.sh`, never by hand.** What to record (every needs-input question and answer, plus every intent fact the user volunteers unprompted), the append-supersedes-edit revision rule, and the worked example are at their point of use in `phases/5-structural.md`.
- **`.kairos/intent.md`** — committed, cross-run: standing intent facts, one dated bullet each with short context and an optional `guard:` asserting the state the fact describes. A guard is **never shell**: the file is committed, so its guards are untrusted input, evaluated by `scripts/intent-check.sh` in a closed grammar — that grammar and its trust model, the orphaned-`guard:` rules, and the whole-file-refusal repair all live in `reference/intent-guard.md`. **Written only by `scripts/promote-intent.sh`, never by hand** (two narrow sanctioned exceptions, both in `reference/intent-guard.md`). Vetted at Phase 5 start by `intent-check.sh`, which also quarantines entries whose guard no longer holds.

The phase files say where each is read (Phase 5 dispatches and batched questions, Phase 6 planning, Phase 8 promotion); every conflict-resolver dispatch prompt carries both ledger paths unconditionally.

**Deliberately not `$RUN/qa-ledger.tsv`: `$RUN/learnings.md`.** Run-scoped, appended by **executors** via `scripts/log-learning.sh` and read by every later executor at start — factual observations about what the component *is* (quirks, commands, flaky suites). `qa-ledger.tsv` carries the user's answers and volunteered intent; learnings are agent-discovered claims about the component, are never promoted out of the run, and Phase 8's promotion step does not read them at all.

## Run-context anchor

Conversation memory is the least durable thing in a many-hour run — compaction can evict any value that lives only in chat. Cross-phase values therefore live in `$RUN/context.env` (one `KEY=VALUE` per line): the scripts that learn a value record it themselves (pre-flight, clone-common, materialize, materialize-frontend), and you record the conversationally-derived ones the moment a phase establishes them via `RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" KEY=VALUE ...` (upsert — last write wins). **At every phase start, re-read `$RUN/context.env` and take these from it, never from conversation memory:** `BASE`, `TARGET`, `TARGET_REF`, `SYNTH`, `CACHE`, `SKILL_DIR`, `TEMPLATE_PATH`, `COMMON_REPO_PATH`, `COMMON_MODULES`, `COMMON_CACHE`, `TEMPLATE_LOCAL_BRANCH`, `MIGRATION_BRANCH`, `PREV_BRANCH`, `PREV_SHA`, `SQUASH_ON_FINISH`, `STRUCTURAL_SHA`, `RUN_SOURCE`, `FRONTEND_PATH`, `FRONTEND_LOCAL_BRANCH`, `FRONTEND_REPO`, `FRONTEND_SHA`, `FRONTEND_BRANCH`, `FRONTEND_TEMPLATE`, `FRONTEND_MODULE_PATH`, `FRONTEND_MOUNT`, `FRONTEND_CACHE`, `FRONTEND_BOOTSTRAP`, `FRONTEND_INTENT`, `LIB_MODULES`. That list is canonical — `reference/continue.md` restates it and a lint holds the two in correspondence. `STRUCTURAL_SHA` is established at Phase 5, the moment the structural commit lands (the same way `PREV_SHA` is established at Phase 4), so it is legitimately absent from the anchor in every phase before that. If `SYNTH` names a tree that no longer exists, re-run materialize (stamped — an unchanged re-run reuses the trees). This makes in-session compaction equivalent to a resume rather than a silent source of wrong values.

**Every phase code block that consumes one of those values opens by re-reading the anchor — this line, verbatim, first:**

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
```

Then `KEY=$(ctx KEY)` for each value the block needs.

**`RUN_SOURCE` is the run's own identity on the anchor** — `template` or `frontend`, recorded by pre-flight when the invocation declares it and (re-)recorded idempotently by Phase 2's first block. It decides which manifest key the run's baseline advance writes, which upgrade-file directory it collects from, and which cwd its gates run in; it is derived from the invocation, so it is exactly the value a compaction evicts — but it is not unrecoverable: **mid-run it is derivable from the live block**, because which of `template.in_progress` / `frontend.in_progress` exists IS the run's source (`reference/continue.md`'s lost-anchor arm derives it that way and re-records it, and `phases/8-finalize.md`'s advance step cross-checks the two). What no on-disk state answers is the source of a run whose block has already been cleared. A phase that needs to know which run it is in reads it from here.

The preamble is per-block, not per-phase, because each code block runs in its own fresh shell (Shell state, above): a value from an earlier tool call is already gone. (`RUN` is assigned in the preamble rather than read: it is the fixed path `.kairos/migration/state`, so nothing about it needs remembering.)

**`ctx` does not stop anything.** It prints a `FAIL:` line when a key is missing but exits 0, so `KEY=$(ctx KEY)` assigns the empty string and the block runs on, even under `set -e`. The `FAIL:` line is a signal *to you*: read the block's stderr and never proceed on an empty value — re-establish it (or re-run the phase that records it) first. Acting on it is the discipline this whole convention rests on.

Two kinds of read sit outside that discipline, both detailed in `reference/state-files.md → Anchor read modes`: a **hard guard** (`: "${KEY:?…}"` after the reads) for the few blocks where an empty value would be destructive rather than merely wrong, and the **always-optional keys** — read with the bare `sed -n 's/^KEY=//p' "$RUN/context.env"` because their absence is itself the answer: `SQUASH_ON_FINISH`, `COMMON_CACHE`, `TEMPLATE_PATH`, `TEMPLATE_LOCAL_BRANCH`, `TARGET_REF`, `MIGRATION_BRANCH`, `COMMON_MODULES`, `LIB_MODULES`, and **every** `FRONTEND_*` key. Those are the keys that are *always* optional. What each key's absence means, the sites that carry a hard guard, the locally-justified bare read of a normally-`ctx`-read key, and the `# anchor-exempt: <why>` convention for a block that *establishes* values rather than consuming them are all in that reference section.

## When something goes wrong

The one genuinely cross-phase thing — routed to the doc that owns the actual steps:

- **A gate returns FAIL, NEEDS-INPUT, or all tasks INCOMPLETE** → **Load** `reference/gate-cards.md`, the interpretation contract for gate output (a named load-and-act exception — read it to act on any non-`PASS` card).
- **The plan needs changing** (any phase, including Phase 8's non-PASS final gate) → stop cleanly; the user says `continue`; `reference/continue.md`'s plan-revision arm re-enters Phase 6. Never edit an approved `PLAN.md` in place.
- **A subagent returns needs-input** → relay the question to the user, record the answer with `scripts/log-intent.sh`, re-dispatch.
- **`$SYNTH` names a tree that no longer exists** → re-run materialize through the arm for this `RUN_SOURCE` (`phases/2.5-materialize.md`).
- **An anchor key is lost after compaction** → `reference/continue.md`'s lost-anchor arm re-establishes it (and re-derives `RUN_SOURCE` from the live block).
- **Two live `in_progress` blocks** → pre-flight refuses; `reference/abort.md`, per source, unwinds the wrong one.
- **`log-spawn.sh` refuses the first dispatch on a pin mismatch** → re-dispatch on the pinned model; the row lands then.

## Argument extraction (from natural language)

From e.g. `/kairos-component-update abc1234 --template-branch feat/x --no-branch`, extract:

- Positional non-flag token that looks like a SHA, branch, or tag → `TARGET_REFSPEC`
- `--template-path <dir>` → clone the per-component mirror **from** a local template checkout instead of from the remote URL (useful for template authors testing draft upgrade-files). It does not replace the mirror: pre-flight still creates `$RUN/template` and every later phase reads blobs from there, so **uncommitted work in that directory is invisible to the run** — pre-flight warns about it. Its checked-out branch also becomes the strongest signal in Phase 2's branch default chain (`reference/pre-flight.md`, checks 7–8)
- `--template-branch <branch>` → target a non-main branch
- `--frontend-path <dir>` → the same thing for the **frontend** source: clone its per-component mirror from a local checkout of the frontend repo. Canonically the monorepo root; a path *inside* it is accepted and pre-flight normalizes it to the enclosing git toplevel (a path that is not in a git work tree is refused). Its checked-out branch is the strongest signal in Phase 2's *frontend* branch default chain
- `--frontend-branch <branch>` → target a non-main branch of the frontend source
- `--branch <name>` → explicit name for the migration branch created in Phase 4 (skips the prompt described there)
- `--no-branch` → run on current branch (warn explicitly first — `abort` becomes destructive on the current branch)
- `--squash-on-finish` → at Phase 8, squash all migration commits into one
- `--executor-model <model>` → overrides `<EXECUTOR_MODEL>` for Phase 7's cheap-model subagents; in the role-switch fallback there is no per-call model for it to set
- `--coder-model <model>` → overrides `<CODER_MODEL>` for Flag-set / bootstrapped / no-tests / regression-fix executor subagents; same role-switch caveat
- `--strong-model <model>` → overrides `<STRONG_MODEL>` for conflict-resolver and Flag-set / bootstrapped verifier subagents; same role-switch caveat
- `--budget frugal|balanced|thorough` → the per-run cost posture, passed to `resolve-models.sh` as `BUDGET` and pinned as the `budget=` line in `$RUN/model.txt`; default `balanced`, **never persisted**

All four are detailed under Model selection / `reference/model-resolution.md`.

**Also capture the user's frontend intent, verbatim, as one of four values** — `frontend-only` / `both` / `template-only` / `unsaid`. It is not a flag; it is what their sentence said about `web/` ("just the frontend", "update both", "also web", "template only", or nothing at all). Record it on the anchor as `FRONTEND_INTENT` in Phase 2 alongside the other invocation facts, because the step that consumes it — the frontend-run consent step after the template run finishes (`phases/8-finalize.md`, which owns what each value means) — is hours and one compaction away, and the difference between `unsaid` and `both` is the difference between asking and not asking.

Environment equivalents of the three model flags — standing configuration, not per-run: `KAIROS_UPDATE_STRONG_MODEL`, `KAIROS_UPDATE_CODER_MODEL`, `KAIROS_UPDATE_EXECUTOR_MODEL`. Precedence is **flag > env var > derivation**: a per-run flag always beats the env var, and the env var always beats what `resolve-models.sh` would derive. There is no env equivalent for `--budget`.

Defaults (arg wins over manifest wins over built-in):

- Template repo: `.kairos/manifest.yaml` → `template.repo`
- Template branch: arg > the local `--template-path` clone's checked-out branch > `template.branch` > `main` (authoritative chain: Phase 2)
- Target SHA: arg > HEAD of the resolved template branch
- Branch: arg (`--branch`) if given; otherwise in Phase 4 **suggest** the name `scripts/suggest-branch.sh` prints (`topic/<username>/<source>-update-<short-target-sha>`) and **require confirmation** (user may accept or type a different name). Never create a branch on an unconfirmed name. A frontend run **chained** after a template run keeps the branch that run created (one PR carries both) — the script prints it back when given it, **and prints the branch you are already standing on when it is migration-shaped and the anchor no longer carries the name** (the chained re-entry's fresh sweep takes `context.env` with it, which is why the second source exists); a frontend-only run from an ordinary branch gets its own `frontend-update-` name.
- Executor model: arg > `KAIROS_UPDATE_EXECUTOR_MODEL` > derived `<EXECUTOR_MODEL>` — never read from the manifest
- Coder model: arg > `KAIROS_UPDATE_CODER_MODEL` > derived `<CODER_MODEL>`
- Strong model: arg > `KAIROS_UPDATE_STRONG_MODEL` > derived `<STRONG_MODEL>`
- Budget posture: arg (`--budget`) > `balanced` — never read from or written to the manifest or `~/.kairos/models.yaml`; a per-run property

The three model tiers and the budget posture resolve through Model selection / `reference/model-resolution.md`.

Don't ask for things you can default. Surface what you defaulted so the user can correct you. Branch naming is the deliberate exception — suggest, then confirm (see Phase 4).

**Artifact discipline (keep context lean).** The scripts print bucket counts and merge tallies to stderr — read those; don't `cat` `$RUN/classification.tsv` or raw test output wholesale. Query specifics with `$RUN/query.sh <bucket> [column]` (e.g. `$RUN/query.sh modify-delete-for-ai`) rather than retyping the underlying `awk -F'\t' '$1=="modify-delete-for-ai"' "$RUN/classification.tsv"` — same result, no need to hold the awk form or the full TSV's column layout in context. `$RUN/summary.txt` has the bucket tallies on disk if you need them again without re-running the script. The full `classification.tsv` remains for post-mortem inspection, not as the documented read path. For diffs, `git show --stat HEAD` first; pull full file diffs only where you need reasoning. This matters most in the role-switch fallback, where every byte read stays in the one shared window.

## Phase index

Never execute a phase from the index; the file is the phase — load `phases/<n>-….md` before executing any of its steps.

**One invocation may chain two RUNS.** A **run** is one source, one `BASE..TARGET`, one plan, one gate cwd, one SHA advanced — the phases below are a run, not an invocation. The default invocation is a `template` run and then, when a frontend source exists and may be stale, the frontend ask (Phase 8 owns it) followed by a `frontend` run over the same phases with `RUN_SOURCE=frontend`: a fresh run state, its own baseline and target, its own plan, its own final gate, on the same migration branch by default. Not one combined plan, and never the frontend (the React app under `web/`) inside the template classification. Starting a second source while one is in progress is refused; abort restores **this** run's start, so aborting a frontend run keeps the template baseline the finished template run advanced.

- **Phase 1: Pre-flight** — load `phases/1-preflight.md`.
  Goal: verify every hard prerequisite (tools, Kairos CLI, tree state) and set up the run state, the template cache, and the common-library clone.
  Entry: fresh run start (Continue mode re-runs it in continue mode).
  Exit: every check passed — a failure stops the migration before any state is written.

- **Phase 1.5: Resolve the model pins** — load `phases/1.5-model-resolution.md`.
  Goal: resolve the three tier pins plus the budget posture, and surface them to the user before any subagent runs.
  Entry: pre-flight passed. **Never earlier** — pre-flight's fresh-mode sweep would delete pins written before it.
  Exit: the four pins written and surfaced.

- **Phase 2: Resolve baseline + target** — load `phases/2-resolve-target.md`.
  Goal: read or bootstrap the manifest, resolve and validate the baseline and target SHAs, and surface which default chose the target plus the scope advisory.
  Entry: pre-flight passed and the model pins resolved (Phase 1.5).
  Exit: baseline and target validated (early exit when already up to date).

- **Phase 2.5: Materialize the merge sides** — load `phases/2.5-materialize.md`.
  Goal: build both merge-side trees with create-equivalent substitution — the template arm via the Kairos CLI itself, the frontend arm via the pinned replacement map (no CLI).
  Entry: baseline and target resolved.
  Exit: both synthetic trees exist and the materialization reports were relayed.

- **Phase 3: Classify the template changes** — load `phases/3-classify.md`.
  Goal: diff the materialized sides, route every changed file into a bucket, and produce the upgrade-file lists.
  Entry: materialization done.
  Exit: classification artifacts written and the overlap advisory relayed.

- **Phase 3.5: Collect common-library upgrade-files** — load `phases/3.5-collect-common.md`.
  Goal: resolve each consumed common-library module's version range and collect its consumer-facing upgrade-files.
  Entry: classification done. A frontend run still loads the file — its first section records the idle layers as *not applicable*, never as incomplete. Skip the phase entirely only when Phase 1 recorded no common modules.
  Exit: every module collected, dispositioned by the user, or cleanly skipped.

- **Phase 4: Create migration branch** — load `phases/4-migration-branch.md`.
  Goal: create the confirmed migration branch, ensure migration state stays gitignored, record the in-progress block, and commit the scaffolding.
  Entry: classification (and any common collection) done.
  Exit: scaffolding commit landed on the migration branch.

- **Phase 4.5: Establish pre-merge test baseline** — load `phases/4.5-test-baseline.md`.
  Goal: capture the pre-merge test baseline and discover the test, build, and regeneration commands under the zero-evidence guard.
  Entry: migration branch created; component source still untouched.
  Exit: baseline and commands recorded (or their absence recorded honestly).

- **Phase 5: Structural step** — load `phases/5-structural.md`.
  Goal: run the mechanical merge, settle the ask-user and for-AI buckets, resolve conflicts, commit one structural commit, and pass the postmerge gate — the post-merge sanity pass.
  Entry: baseline captured.
  Exit: structural commit landed; postmerge gate clean or its findings explicitly dispositioned.

- **Phase 6: Planning** — load `phases/6-planning.md`.
  Goal: switch to the planner role, drive the Q&A, write the plan, clear the completeness gates, and commit the approved plan.
  Entry: postmerge gate cleared.
  Exit: user-approved plan committed.

- **Phase 7: Execution** — load `phases/7-execution.md`.
  Goal: execute the approved plan task by task via executors, with per-task gates, tiered verifiers, and one commit per task.
  Entry: plan committed.
  Exit: every task committed or its skip documented with the user.

- **Phase 8: Finalize** — load `phases/8-finalize.md`.
  Goal: run the final gate over the whole tree, write the finalize summary with template feedback, then advance the template baseline in the commit that carries them.
  Entry: all plan tasks done.
  Exit: baseline advanced; the user merges and pushes themselves.

## What you NEVER do

- `git push` — anywhere, ever, in any form. Promotion to a remote is the user's deliberate action.
- Modify `.kairos-updates/` in the component directory (it shouldn't exist there at all).
- Modify files outside the component directory.
- Fix pre-existing test failures (only fix regressions introduced by the current task).
- Skip pre-flight to save time.
- Advance the template baseline without the Phase 8 final gate passing (or its failures explicitly accepted by the user).
- Commit anything before verifying `.kairos/migration/state/` is gitignored (Phase 4).
- Edit `PLAN.md` after the user has approved it — if the plan needs changes, stop cleanly and have the user say `continue` (Continue mode's plan-revision arm re-enters Phase 6); never patch an approved plan in place.
