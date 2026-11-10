## Phase 7: Execution

PHASE_KEY: e9tr6bjs
(Proof-of-load: `log-spawn.sh` under `PHASE=7` refuses without `PHASE_KEY=e9tr6bjs`; the midplan `gate.sh` accepts any of the three phase-file keys — still pass `e9tr6bjs` here. The mechanism, and why the key stays only in this file, are in `reference/gates.md`.)

The executor handles ONE task and needs only `PLAN.md`, a task ID, `$RUN`, and `$SKILL_DIR` — not the conversation (its test/build commands come from PLAN.md's Test Baseline section, not from `$RUN/test-command.txt`). **Prefer running it as a subagent** where you have runtime dispatch — fresh context per task keeps the orchestrator's window from filling with every task's churn, the biggest token cost of a long migration. Where dispatch is absent, fall back to `agents/executor.md` as an in-conversation role switch. Either way, planning and Phase 7 belong in the same session — there is no hand-off to a second one unless the user asks for it or context runs short (see Context checkpoint below).

For each task in `PLAN.md` in order:

1. Spawn the executor for this task only.
   - Pass: the task ID (e.g. `T03`), the path to `PLAN.md` (`.kairos/migration/PLAN.md`), `$RUN` (`.kairos/migration/state`), and `$SKILL_DIR` — its scripts (`plan-slice.sh`, `run-check-modules.sh`, `log-learning.sh`) and `reference/upgrade-files.md` all live under it, and `agents/executor.md`'s degraded arms for its absence include one that forbids signalling a clean full check, so omitting it silently degrades every task.
   - **Spawn by path, never by pasting the role file's contents** — a fresh subagent can read `agents/executor.md` itself; pasting its body duplicates several KB into orchestrator history per task for nothing.
   - **Learnings ride `$RUN`, not the prompt.** The executor reads and appends `$RUN/learnings.md` itself (`scripts/log-learning.sh`, both the success and the failure path) — it already receives `$RUN`, so do not add the path to the spawn prompt. You may append gate-discovered facts the same way; verifiers stay read-only.
   - **The executor's model is tiered from the task's recorded `Flag`:**
     - `<CODER_MODEL>` when **Flag** is set (hand-woven | coverage-blind | complex), the component is bootstrapped (`manifest.yaml`), Phase 4.5 recorded `no tests detected` and the task touches code, or the task is a regression fix slotted from the postmerge gate.
     - `<EXECUTOR_MODEL>` when **Flag** is omitted (routine: `config change`, `no tests`, trivial `direct edit`, routine upgrade-file application).
   - Do not re-derive flagged-ness from `$RUN/resolutions.tsv` or `$RUN/coverage-blind.txt` — read the plan field.
   - Subagent form: `Agent(subagent_type: "general-purpose", model: <the task's executor tier>, prompt: "Read <absolute path to this skill>/agents/executor.md and follow it exactly. Your task: T03. PLAN.md is at .kairos/migration/PLAN.md. RUN is .kairos/migration/state. SKILL_DIR is <absolute path to this skill>.")`. Substitute the literal absolute path and value in the prompt — a fresh subagent's shell resolves an unexpanded `$SKILL_DIR` / `$RUN` to nothing (the same value-not-variable rule Phase 5's dispatch states, `phases/5-structural.md`).
   - **If this is the run's first dispatch** (no Phase 5 conflict-resolver preceded it), append the actual-model probe sentence to that same prompt (SKILL.md → Spawn accounting; mechanics in `reference/model-resolution.md`) — the probe rides the dispatch, so a first prompt without it is malformed, exactly as Phase 5 states for its own first dispatch. Step 6 records the reply.
   - Role-switch form: adopt `agents/executor.md` for this task.
2. The executor implements, runs tests, fixes its own regressions, and signals completion or failure. On role-switch completion, exit the role.
3. **Per-task verification gate (cheap, small-signal — do NOT re-read the diff; that defeats the subagent).** Verify the executor's *claims*, not its diff: it runs a cheaper model, and "tests pass, scope clean" is exactly the claim most likely to be optimistic. Run these against the working tree; each emits a few lines, never a diff:
   - **Failure-set check (conditional — don't re-run tests every task).** The executor's own full run (`agents/executor.md` step 5) already goes through `run-check-modules.sh` at `OUT="$RUN/test-task-<ID>"` — the same multi-module sweep the baseline was captured with, ID prefixes and all — so re-running here mostly re-confirms its report at real cost, in the SAME namespace `test-baseline.failures.txt` is already in. (Skip this check entirely if no test command was detected.)
     - **Re-run only on distrust of the green**: the task edited test files, the executor's report is thin or inconsistent with its diff, or the tests are known-flaky. Otherwise trust the executor's run and let the Phase 8 full-suite gate be the backstop.
     - **When you do re-run**, go through `run-check-modules.sh` (`CHECK=test`, `OUT="$RUN/test-task-<ID>"`, PLAN.md's test command as `CMD` and extractor as `EXTRACTOR`; no `PHASE_KEY` — that guard applies only to the `test-baseline` stem). This overwrites the executor's own `test-task-<ID>` artifacts with your independent run rather than trusting its self-report.
     - **Read the run's status first, then compare failure sets**: `LC_ALL=C comm -13 <(LC_ALL=C sort -u "$RUN/test-baseline.failures.txt") <(LC_ALL=C sort -u "$RUN/test-task-<ID>.failures.txt")` — anything new is a regression, and `EXTRACTOR_MISMATCH` is never a pass, same rule as Phases 5 and 8.
   - **Scope check** — `git diff --stat` against the task's declared `Files`/glob; flag any path the task didn't name.
   - **Marker/stub grep** on the touched files — conflict markers, `TODO: come back`, commented-out code left behind.
   - **Upgrade-file verification** — if the task applied one, verify it now, not just at Phase 8 (localizes failure to the task that caused it). If `verify-script:` is present, run it and check exit code. If only `verify:` prose is present, use it as AI-driven instructions to confirm the change. If neither, use best judgment.

     **A failing `verify-script:` is not proof of failure** — these are author-written one-liners and are sometimes simply wrong (a grep that can't match, a path that moved). On a **failing** script, cross-check by judgment against the `verify:` prose and the actual tree, then decide:
     - script fails **and** judgment agrees the change is absent → a real failure; handle as below.
     - script fails **but** judgment finds the change correctly applied → trust judgment, treat the task as verified, and record the contradiction (upgrade-file slug, what the script asserted, what you observed) for the Phase 8 **Template feedback** section. Tell the user you overrode the script and why. An overridden script is **not** a gate failure: the retry trigger below reads the resolved verdict, so a change that already landed correctly never spends a retry.

     A **passing** script is trusted outright — no re-check. Only failures are cross-examined, because only failures cost anything to get wrong here.

   **On a frontend run (`RUN_SOURCE=frontend`), both the acceptance suite and the upgrade-file scripts move to the mount.** Per-task acceptance is the *mount's* suite, run through the commands Phase 4.5 recorded — the root `make test` never sees the mount, so it can never stand in for it — and an upgrade-file's `before:`/`verify-script:` are **subtree-relative by contract** (`reference/upgrade-files.md`: the author writes `src/App.tsx`, never `web/src/App.tsx`), so they are executed with cwd at the MOUNT for exactly the same reason. A script run from the component root fails as "pattern not found" — a wrong cwd looks precisely like a change that was never applied, which is the one failure mode this contract exists to prevent, so check the cwd before believing a failure:

   ```bash
   RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
   SKILL_DIR=$(ctx SKILL_DIR); RUN_SOURCE=$(ctx RUN_SOURCE)
   # RUN_SOURCE first, THEN the MOUNT guard: a template run reaching this frontend
   # block must die on the accurate "take the template path instead" message, not on
   # a misleading "FRONTEND_MOUNT missing" — a template run legitimately has no mount.
   [ "$RUN_SOURCE" = frontend ] \
     || { echo "FAIL: this is the frontend section but RUN_SOURCE=$RUN_SOURCE — take the template path instead" >&2; exit 1; }
   # Bare read: every FRONTEND_* key is legitimately absent (SKILL.md → Run-context
   # anchor) — but not on a frontend run, where an empty mount would silently move
   # both the suite and the script back to the component root.
   MOUNT=$(sed -n 's/^FRONTEND_MOUNT=//p' "$RUN/context.env")
   : "${MOUNT:?FAIL: FRONTEND_MOUNT missing from the run-context anchor — stop; a frontend task cannot be accepted from the component root}"
   RUN_ABS=$(cd "$RUN" && pwd -P)   # $RUN is relative; the calls below run inside the mount
   ( cd "$MOUNT" && CHECK=test CMD="<PLAN.md's test command>" EXTRACTOR="<PLAN.md's extractor>" \
       OUT="$RUN_ABS/test-task-<ID>" "$SKILL_DIR/scripts/run-check-modules.sh" )
   ( cd "$MOUNT" && <the upgrade-file's verify-script, verbatim and subtree-relative> )
   ```

   Everything else about the gate is unchanged: the same conditional re-run rule, the same `EXTRACTOR_MISMATCH`-is-never-a-pass rule, the same failure-set comparison against `test-baseline.failures.txt` — which the frontend baseline wrote from the same cwd, so the two sets are comparable. **An upgrade-file script that hardcodes the mount (`web/…`) is an upstream bug**, not something to work around by moving the cwd: record it for the Phase 8 feedback section the same way a wrong `verify-script:` is recorded.

   All green → commit. Any check fails → treat it exactly like an executor-reported failure: spend the automatic retry below (subagent dispatch only — in the role-switch fallback there is no fresh context to spend, so surface it immediately), and only if that fails too surface it with options. Never commit silently.
4. Commit — the `git add -A` is blunt, so a binary tripwire stands between it and the commit:

   ```bash
   # anchor-exempt: the task id is this task's OWN, read from PLAN.md in this step —
   # not a cross-phase value, so it is never anchored. Substitute both angle-bracket
   # placeholders literally before running, as in every other block in this skill —
   # never spell the id as a shell variable. No shell state survives between tool
   # calls, so a `${TASK_ID}` spelling expands to nothing and commits `migrate():`,
   # a subject that neither reference/continue.md's task count nor Phase 8's executor
   # cross-check can match — and both fail silently, reporting zero tasks done.
   git add -A

   # Binary tripwire — before the commit, never after. A build or test run this task
   # performed may have dropped a compiled go binary or a `*.test` into the tree, and
   # `git add -A` just staged it. Refuse to commit it: clean-artifacts (Phase 8) is
   # ignored-only and can never un-commit a tracked blob, and the run keeps these
   # per-task commits by default (the squash is opt-in), so a committed binary rides
   # into history and gets pushed. PREV_SHA is the migration base; **read it through
   # the hard guard, never bare** — an empty base makes guard-binaries.sh skip its own
   # tree lookups and pass vacuously, exactly the STRUCTURAL_SHA failure mode below.
   RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
   PREV_SHA=$(ctx PREV_SHA)
   : "${PREV_SHA:?FAIL: PREV_SHA missing from the run-context anchor — stop; recover it (reference/continue.md, lost-anchor arm) before committing, or the binary guard runs disabled}"
   if MODE=staged BASE=$PREV_SHA ALLOW="$RUN/committed-binaries-ok.txt" "$SKILL_DIR/scripts/guard-binaries.sh"; then
     git commit -m "migrate(<task id>): <task title from PLAN.md>"
   else
     echo "STOP: run-created binary blob(s) are staged (listed above) — not committing." >&2
   fi
   ```

   A non-zero exit means the commit did **not** happen — do not commit past it. Surface the listed paths and decide with the user, then re-run this block:
   - **build output** (the common case) → add its pattern to the component `.gitignore`, `git rm --cached -- <path>` and delete the file from the tree, then re-run. `git add -A` will no longer stage it and the tripwire passes.
   - **a genuine new binary asset** the task means to keep (rare) → append its exact repo-root-relative path to `$RUN/committed-binaries-ok.txt` (one per line), then re-run. The guard exempts approved paths; the asset commits normally.

5. **Risky tasks — independent verifier (out-of-context, not an in-context re-read).**
   - Runs when: the task's `Approach` is anything other than `config change` or `no tests` — except a mechanically trivial `direct edit` (a pure rename or a dependency-version bump, no logic change), which is exempt — OR the task's **Flag** is set, OR the component is bootstrapped (then *every* task gets one) — OR the commit trips the **bent-test trigger** below, which runs the verifier even when `Approach` (`config change`, `no tests`, the trivial `direct edit` exemption) would otherwise exempt it.
   - **Bent-test trigger — one deterministic check, on every commit regardless of `Approach`:** `git diff --name-only HEAD^..HEAD` intersected against the test-file patterns (`*_test.go`; `*.test.*` / `*.spec.*`; `test_*.py` / `*_test.py`); for each match, `git cat-file -e "$STRUCTURAL_SHA:<path>"` — read `STRUCTURAL_SHA` from `$RUN/context.env` (recorded by `phases/5-structural.md` the moment the structural commit lands, and re-recorded by its step 9 after either amend arm), never re-derived from history, where a compacted session or an amended commit makes the derivation guesswork. **Read the key through the hard guard, never bare** — this is the one layer built to catch execution-era test-bending, and an empty value is what makes it pass vacuously:

     ```bash
     RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
     STRUCTURAL_SHA=$(ctx STRUCTURAL_SHA)
     # `ctx` only REPORTS a missing key — it exits 0, so an unguarded read leaves the
     # expansion EMPTY and both git calls quietly change meaning instead of failing:
     # "$STRUCTURAL_SHA:<path>" becomes ":<path>", the INDEX entry, which exists for
     # every tracked file, and the verifier's `git show <STRUCTURAL_SHA>:<path>` becomes
     # `git show :<path>` — the file's own staged content, so the verifier diffs the
     # test against itself, finds no bend, and returns PASS. `${VAR:?}` stops the phase
     # here instead; recover the SHA per reference/continue.md's lost-anchor arm.
     : "${STRUCTURAL_SHA:?FAIL: STRUCTURAL_SHA missing from the run-context anchor — stop; recover it (reference/continue.md, lost-anchor arm) before judging any test-file edit}"
     git cat-file -e "$STRUCTURAL_SHA:<path>"   # per matched test file
     ```

     A hit means this commit modified a test file that already existed at the structural commit — "pre-existing" means exactly that: present at that commit, since anything the template itself changed in a test file was already reviewed in Phases 5–6, and it is the execution-era edits nobody else re-reads. **The trigger promotes the verifier's occurrence, not its tier**: an otherwise-exempt task that trips it still gets the routine-tier verifier (`<EXECUTOR_MODEL>`) — Flag, bootstrapped, escalation, and `budget=thorough` still promote it the same as any other task. The majority of tasks touch no tests and pay nothing extra.
   - After committing, spawn a **separate** subagent to review just this one commit: `Agent(subagent_type: "general-purpose", model: <VERIFIER_MODEL>, prompt: "Find a concrete defect in commit HEAD (git show HEAD) against task <ID> in .kairos/migration/PLAN.md — your job is to refute this commit, not to confirm it. Resolve uncertainty toward reporting a possible defect, never toward PASS. Return only: PASS, or a short list of concrete defects (scope drift, half-applied change, broken logic, leftover stubs). Do not fix anything.")`. **When the bent-test trigger fired for this commit**, add one more instruction to that same prompt: for each such test file, diff it against `git show <STRUCTURAL_SHA>:<path>` — the literal SHA the guarded read above produced, substituted into the prompt, never an unexpanded variable a fresh subagent's shell would resolve to nothing — and judge whether the test was genuinely wrong before or was bent to match the new behavior — same uncertainty-resolves-to-reporting stance, applied to the test itself.
   - **`<VERIFIER_MODEL>` is tiered from the same `Flag`:** `<STRONG_MODEL>` when **Flag** is set or the component is bootstrapped; `<EXECUTOR_MODEL>` when **Flag** is omitted (routine risky task). There is no separate flag or pin for it — `--strong-model` / `--executor-model` move both tiers, and the one-line default surfaced at model resolution already told the user which models these are.
   - **Under `budget=thorough`** (the `budget=` line in `$RUN/model.txt`), every verifier runs on `<STRONG_MODEL>` regardless of Flag — that promotion is the whole difference between thorough and balanced (see `reference/model-resolution.md`).
   - On a task that was escalated to `<CODER_MODEL>` (see below), the redo's verifier is `<STRONG_MODEL>` — the task just demonstrated it isn't routine.
   - The diff lands in the verifier's context, not yours.
   - A non-PASS verdict is surfaced like any failure — decide with the user: amend the commit, add a fix task, or accept. Adding a fix task — or any other plan change — is never an in-place edit of the approved plan: stop cleanly and have the user say `continue`, and Continue mode's plan-revision arm re-enters Phase 6, revises with both gates re-cleared, and resumes here (`reference/continue.md`).
   - In the role-switch fallback, skip only the verifier **dispatch** (no independent context to spend) — the bent-test trigger's deterministic check above is orchestrator work, costs nothing, and still runs on every commit; on a hit, make the against-`$STRUCTURAL_SHA` judgment yourself in-conversation (diff the test against `git show <the guarded SHA>:<path>`, same bent-or-genuinely-wrong question) and record the outcome in the task's log entry. The cheap gate above and the Phase 8 gate carry the rest.
6. Append a task entry to `.kairos/migration-log.md` (files touched, tests run, regressions fixed, verifier verdict if run) — **after** the commit, since the entry references it. Never make a log-only commit: an intermediate entry rides the next task's `git add -A`, and the **final** task's entry is carried by Phase 8's baseline-advance commit (`phases/8-finalize.md` step 5). **Record the dispatches** with `scripts/log-spawn.sh`, one self-contained invocation each in Phase 5's shape (`RUN=` is required — `log-spawn.sh` refuses a row without it):
   - **The executor** — `RUN=$RUN PHASE=7 PHASE_KEY=e9tr6bjs ROLE=executor TIER=<the tier you named on the call> MODEL=<slug> ITEM=<task ID> OUTCOME=ok "$SKILL_DIR/scripts/log-spawn.sh"`. **This step's executor row is `OUTCOME=ok` because reaching it means the task committed** — and it is logged on *every* successful commit, **including a task that got here via the auto-retry below**: its `fail` and `retried` rows were already logged at the retry site (below), and this trailing `ok` is a distinct row that makes the committed task's ledger `[fail, retried, ok]` — exactly analogous to a needs-input task's `[needs-input, ok]`. The other members of `log-spawn.sh`'s closed set (`needs-input|fail|escalated|retried`) are each logged at their own site — `fail`/`retried` at the retry site, `escalated` at the escalation site, `needs-input` at the needs-input arm — not here; a task that never commits (surfaced to the user after a failed retry) never reaches this step and correctly keeps its `[fail, retried]` ledger with no `ok`.
   - **The verifier, if one ran** — the same line with ``ROLE=verifier TIER=<the tier of the model you actually dispatched — `strong` under Flag / bootstrapped / `budget=thorough` / escalation-redo, `executor` otherwise>`` and **`OUTCOME=ok` for a PASS verdict, `OUTCOME=fail` for any non-PASS** (the tally at the bottom of this phase counts an item's `fail`/`retried` rows regardless of role, so a non-PASS verifier's `fail` correctly contributes one *after* the commit's `ok` reset). Do **not** derive the tier from `Flag` alone, or a thorough/escalation verifier that ran on `<STRONG_MODEL>` recorded as `TIER=executor` is refused by `log-spawn.sh`'s pin check *after* it already ran.
   - **First dispatch of the run only** — record the probe's reply in `ACTUAL_MODEL`; the probe sentence itself was added at step 1, on the dispatch, not here (SKILL.md → Spawn accounting; mechanics in `reference/model-resolution.md`).
7. Next task.

**Midplan gate cadence.** Per-task gates are deliberately thin, so two individually-green tasks that interact badly would otherwise surface only at Phase 8 — an expensive end-of-run bisection on a long plan. Localize it: after every fifth committed task, and after each Flag-set task's commit, run the midplan gate over the current tree:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); SYNTH=$(ctx SYNTH); RUN_SOURCE=$(ctx RUN_SOURCE)
if [ "$RUN_SOURCE" = frontend ]; then
  # Every frontend gate runs with cwd at the MOUNT (phases/4.5-test-baseline.md →
  # Frontend run): gate.sh has no frontend flag — the cwd IS the parameter — and
  # the baseline this gate compares against was captured there. Bare read, then a
  # hard stop: an empty mount would run the mount's recorded commands at the
  # component root, against a baseline from a different cwd.
  MOUNT=$(sed -n 's/^FRONTEND_MOUNT=//p' "$RUN/context.env")
  : "${MOUNT:?FAIL: FRONTEND_MOUNT missing from the run-context anchor — stop; a frontend gate must never run at the component root}"
  RUN_ABS=$(cd "$RUN" && pwd -P)       # $RUN is relative; the gate runs inside the mount
  SYNTH_ABS=$(cd "$SYNTH" && pwd -P)   # so is $SYNTH — unabsolutized it resolves under the mount and the gate degrades its $SYNTH-bound rows
  ( cd "$MOUNT" && LABEL=midplan RUN="$RUN_ABS" SYNTH="$SYNTH_ABS" PHASE_KEY=e9tr6bjs "$SKILL_DIR/scripts/gate.sh" )
else
  LABEL=midplan RUN=$RUN SYNTH=$SYNTH PHASE_KEY=e9tr6bjs "$SKILL_DIR/scripts/gate.sh"
fi
```

The preamble takes `$SYNTH` off the anchor, so a compacted session needs nothing from conversation here; if the tree it names is gone, re-run the run's materializer first (`phases/2.5-materialize.md` dispatches by `RUN_SOURCE` — Phase 5 states the rule, including why the stamped trees make the re-run cheap) rather than letting the gate degrade a semantic layer you could restore for one cheap call.

**On resume the cadence counter is unrecoverable** — it lives only in conversation, `gate-midplan.tsv` is overwritten each run and carries no task marker. Do not restart it at zero (that skips the interval since the last gate). Instead, on the first task after a resume, run the midplan gate once unconditionally before resuming the count, then resume counting committed `migrate(Txx)` commits (`git log --format=%s <STRUCTURAL_SHA>..HEAD`, the same commits `reference/continue.md` counts) so the next fifth-task boundary is derived from history rather than memory.

**Read a non-PASS aggregate through `reference/gate-cards.md`'s interpretation contract before calling it breakage** — the same row-by-row contract Phases 5 and 8 relay from. Non-PASS is not one thing here:

- A **`FAIL`** row is breakage, and it lies in the window since the last clean gate. Handle it like a per-task gate failure (surface with options, never proceed silently), with that window as the extra datum in your report — name those tasks.
- A **`NEEDS-INPUT`** row may be a **decision the user already recorded**, not breakage at all. `gate.sh`'s replace-directive check runs at `midplan` too, so a `keep` decision the user made on an inherited local-path `replace` back in Phase 5 makes every subsequent midplan gate report `NEEDS-INPUT` for the rest of the run — same finding every time, and none of it caused by the tasks in the window. So check the row's finding against `.kairos/migration-log.md` and `$RUN/qa-ledger.tsv` first: a finding that matches a decision already recorded there is **not** breakage and the committed tasks in that window are innocent of it. Re-affirm the recorded decision (name the log entry or ledger row), and proceed with the aggregate as-is — `reference/gate-cards.md`'s `NEEDS-INPUT` disposition documents exactly that outcome for this check. Only an *unrecorded* finding is a question to put to the user.
- **`INCOMPLETE`** rows never move the aggregate; relay them into the log as incomplete semantic coverage, never as clean.

**"Like a per-task gate failure" stops short of the automatic retry below**: this gate runs after commit and its finding lies somewhere in that window of already-committed tasks, so there is no single failed attempt to re-spawn.

**Retry and escalation — one table for the trigger map, the rules beneath it for what the table can't carry.**

| Trigger | Auto-retry? | Tier | Counts toward escalation |
|---|---|---|---|
| Executor signals FAILED (step 2) | yes, once | unchanged | yes |
| Per-task gate fails (step 3) | yes, once | unchanged | yes |
| `verify-script:` failure overridden by judgment | no — not a gate failure | — | no |
| Executor signals NEEDS-INPUT | no — ask the user | unchanged on re-spawn | no |
| Verifier non-PASS (step 5) | no — commit already landed | — | yes |
| Midplan gate non-PASS | no — no single attempt to re-spawn | — | no |
| Role-switch fallback, any trigger | no — no fresh context to spend | — | yes |

Both auto-retry triggers are **pre-commit** — that is what separates them from the verifier and midplan rows, where the commit has already landed and undoing it is a human decision. Plus the two facts the table cannot carry: the retry resets the working tree to the last commit first — the same path-scoped reset Continue mode performs (see `reference/continue.md`), never a blanket one, because the *previous* task's migration-log entry is sitting uncommitted in the tree right now (it rides this task's commit by design) and a bare `git checkout -- .` would destroy it:

```bash
git checkout -- . ':(exclude).kairos/migration-log.md' ':(exclude).kairos/intent.md'
git clean -fd -e .kairos/intent.md    # no -x: the gitignored state dir survives
```

so the retry starts clean rather than atop the failed attempt's residue; and a task whose auto-retry went green and committed **resets its tally to zero** — the reset marker is the committed `OUTCOME=ok` row step 6 logs on that commit (the same mechanism as a needs-input task's trailing `ok`), so the green-retried task's ledger reads `[fail, retried, ok]` and the tally re-derivation below counts nothing after that `ok`. A later verifier non-PASS on it starts again at one; escalation is for work that resists two genuine attempts, not for work that took two tries and then passed every check.

**Automatic fresh-context retry mechanics — one attempt, fixed trigger, logged.** On an auto-retry trigger, re-spawn the executor **once** before stopping to ask the user:

- Same model tier as the original attempt, fresh subagent context. The retry **never** changes tier — tier movement stays exclusively the escalation rule's job.
- The retry prompt carries step 1's spawn inputs **plus bounded failure evidence**: the executor's failure signal, or the gate's failing rows. Never a full log or diff — the point is a better-informed fresh context, not a re-populated one.
- Record the retry dispatch with `OUTCOME=retried` via `scripts/log-spawn.sh`; the first attempt's row keeps `OUTCOME=fail`. Nothing is silent.
- Exactly one attempt, fixed trigger: per-task retry judgment is as forbidden as per-task model judgment. A second failure surfaces to the user below, unchanged.

**Bounded escalation — one step, logged, never silent.** When a task implemented on `<EXECUTOR_MODEL>` accumulates **two failed attempts** (per-task gate and verifier failures count together toward the two; the midplan gate does not, per the table — but they only *pair* when no green-committed auto-retry sat between them, since a green retry zeroes the tally first — its committed `OUTCOME=ok` row is the reset marker — per the reset-to-zero rule above: gate fail → user-driven redo → verifier non-PASS **is** the two, whereas gate fail → auto-retry green-commits → later verifier non-PASS is only **one**), and the chosen remedy is redoing the work, redo it on `<CODER_MODEL>` with the redo's verifier bumped to `<STRONG_MODEL>`, and log the escalation in `.kairos/migration-log.md` (task ID, trigger, models) — the redo's row records `OUTCOME=escalated` via `scripts/log-spawn.sh`. The trigger is unchanged and now naturally armed: original failure + failed auto-retry is the pair. Fixed trigger, fixed response: never escalate implementation past `<CODER_MODEL>`, and never switch models on any other trigger — ad-hoc per-task model judgment is exactly what the pinned tiers exist to prevent.

**The tally survives a compaction — re-derive it from `$RUN/spawns.tsv`, never from memory.** It is not conversation-only state: `scripts/log-spawn.sh`'s rows record every attempt, so a resumed or compacted run recovers it exactly. For the task's `ITEM`, count its `outcome` column — a `fail` row is a failed attempt and a `retried` row is the auto-retry's attempt (both count toward the two) — but a later `ok` or `escalated` row for that same `ITEM` is a reset marker: the `ok` is the committed row step 6 logs on any successful commit (so a green-retried task's `[fail, retried, ok]` resets on that `ok`), and `escalated` marks the escalation redo. Count only the `fail`/`retried` rows *after* the most recent such reset marker. Without this, every task restarts at zero attempts after a compaction and nothing ever escalates.

**What escalation MEANS in the role-switch fallback** (the table's last row counts it toward escalation, but the remedy above — redo on `<CODER_MODEL>`, `OUTCOME=escalated` via `log-spawn.sh` — is unimplementable there: no per-call model to name, no dispatch to record, and `log-spawn.sh` would refuse a session-model row). Escalation is instead: redo the work **in-conversation** with the verifier's findings in hand, and — consistent with SKILL.md's rule that the tier split is *advice to the user* — tell the user this task hit the escalation trigger and the session should be switched to the coder/strong model for the redo (the split is theirs to act on; the fallback cannot switch models for them). Record the escalation as a **note in the task's `.kairos/migration-log.md` entry** (task ID, trigger, that it was a role-switch redo) — **not** a ledger row, which `log-spawn.sh` would refuse.

If the executor reports failure it cannot fix and the automatic retry failed too — or, for a bootstrapped component, it needs a user decision it can't make in a subagent (see `agents/executor.md`) — **stop**. Surface the output with options: skip this task (and document it), revise the plan (stop cleanly and have the user say `continue` — Continue mode's plan-revision arm re-enters Phase 6; never edit the approved plan in place), or abort. Do not silently skip. If it needed input, collect it, **record the question and answer at answer time via `log-intent.sh`** (Phase 5 step 5's invocation, with `PHASE=7`) — the same one-line rule Phase 5's needs-input arm follows — **record the needs-input dispatch itself with `OUTCOME=needs-input` via `log-spawn.sh`** (the step 6 executor line, `OUTCOME` set to `needs-input`), so the re-spawn's committed `ok` makes the ledger `[needs-input, ok]` — and re-spawn with the answer (that is not a retry — it costs no attempt, and `needs-input` never counts toward the escalation tally). The re-spawn carries the answer in its prompt, but the ledger row is what makes the answer outlive this task: it survives compaction, feeds Phase 8's intent promotion, and stops a future run's Phase 6 or Phase 5 from re-asking what the user already settled here. The same rule covers intent the user **volunteers unprompted** — a preference stated mid-task, not in answer to any question: log it immediately via `log-intent.sh` (the same `PHASE=7` invocation) the moment it lands, since the ledger is the only thing that carries it into Phase 8's promotion (SKILL.md's every-volunteered-fact contract).

**Context checkpoint.** Task commits, `.kairos/migration/PLAN.md`, and `.kairos/migration-log.md` carry all resume state. If you're running low on context mid-plan (more likely in the role-switch fallback), finish the current task cleanly (commit + log entry), then tell the user to start a fresh session and say `continue` — Continue mode resumes at task K+1 with nothing lost.
