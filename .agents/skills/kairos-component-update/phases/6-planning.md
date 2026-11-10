## Phase 6: Planning

PHASE_KEY: hw5c2vnd
(Proof-of-load: `handoff-structural.sh` — the planner's entry point — refuses to run without `PHASE_KEY=hw5c2vnd` in its environment. The key is stated only in this file — never copy it into SKILL.md or another phase.)

The planner is **always an in-conversation role switch** — it drives Q&A and needs the shared context. Before loading it, compute the coverage-blind clean-merge list (files that clean-merged with no plausible test coverage — the planner eyeballs these because the postmerge gate can't) and materialize the dropped-template-change evidence — a sibling run, same spot, before the planner reads anything:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); SYNTH=$(ctx SYNTH)
RUN=$RUN "$SKILL_DIR/scripts/coverage-blind.sh"   # → $RUN/coverage-blind.txt
# STRUCTURAL_SHA is bare, not `ctx`: it is legitimately absent on a run recorded
# before Phase 5 started writing it. The HEAD fallback is valid on FIRST entry
# ONLY — there HEAD still is the structural commit, no task having committed on top
# of it yet. On the plan-revision re-entry documented below that is false: task
# commits sit on top and HEAD is task K, so the fallback would materialize evidence
# against the wrong tree. By then the key is always in the anchor anyway — Phase 5
# recorded it the moment the structural commit landed, and reference/continue.md's
# step 1 verifies a present one on every resume (re-recording only when it is absent
# or stale) — so a revision arriving WITHOUT it means a broken anchor, not a
# fallback case: stop and re-establish the SHA.
STRUCTURAL_SHA=$(sed -n 's/^STRUCTURAL_SHA=//p' "$RUN/context.env")
# The two entries differ mechanically in exactly one way: first entry has no
# committed plan, a revision is by definition entered over one. So the guard below
# fires on precisely the path the fallback is wrong for, and never on first entry.
if git cat-file -e HEAD:.kairos/migration/PLAN.md 2>/dev/null; then
  : "${STRUCTURAL_SHA:?FAIL: plan-revision re-entry with no STRUCTURAL_SHA in the anchor — stop; HEAD is task K here, not the structural commit. Recover it (reference/continue.md, lost-anchor arm) and re-run this block}"
fi
RUN=$RUN SYNTH=$SYNTH STRUCTURAL_SHA="${STRUCTURAL_SHA:-HEAD}" \
  "$SKILL_DIR/scripts/dropped-template-changes.sh"   # → $RUN/dropped-template-changes.tsv + .txt
```

`dropped-template-changes.sh` re-derives every `ours`-resolved region from the three sides and materializes the target-side text the resolver's verdict dropped — the artifact `agents/planner.md` step 1.5 actually reviews, instead of a one-line `REASON` or a structural diff that cannot contain the change by construction (an `ours` verdict contributes no hunk to the structural commit). **A non-zero exit, or any `unlocatable` / `error` row in `$RUN/dropped-template-changes.tsv`, is incomplete semantic coverage** — the same vocabulary an absent `$SYNTH` gets, and the same `INCOMPLETE` status `reference/gates.md` uses elsewhere. Name the affected files in the plan so the planner reviews them by hand or accepts the gap knowingly; never read a non-zero exit or an `unlocatable`/`error` row as "nothing was dropped" — it means the question could not be fully asked, not that the answer is no. **Carry the de-duplication caveat too**: a row logged before the ledger's `region` column existed stands for possibly several collapsed regions in one file — the script reports it `unlocatable` rather than guessing which, so its absence from the evidence is not "this file dropped nothing," it's "this file's pre-column row can't be pinpointed."

**The planner starts from the structural handoff card**, not from `git show HEAD` of the whole structural commit or from replaying this conversation — and it generates the card at the moment it reads it:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN PHASE_KEY=hw5c2vnd "$SKILL_DIR/scripts/handoff-structural.sh"
```

It prints clean/conflict/resolution counts, the postmerge-gate verdict, and pointers to `conflicts.txt` / `resolutions.tsv` / `coverage-blind.txt`. Computed at read time, so conflict rework or an inline regression fix after this point can't leave it asserting counts that no longer hold.

**Plan-revision re-entry** (`reference/continue.md`'s plan-revision arm — a committed plan exists and the user asked to change it): same role, same gates, two differences. Completed tasks' rows stay **verbatim** — their `migrate(Txx):` commits are already history, and the plan must keep describing what those commits did — with changes applied only from the first un-committed task onward; and the approval commit says what it is: `chore: migration plan for ${TARGET:0:7} (revised)`. Both completeness gates re-run against the revised plan exactly as below, so a revision that drops a dispositioned slug or follow-up is caught the same way a fresh plan would be.

Load `agents/planner.md` and adopt the planner role. The planner:

1. Reads the recorded test baseline from `$RUN/` (does NOT re-run the suite — Phase 4.5 owns it).
2. Reviews `$RUN/resolutions.tsv` — the `ours` and `merged` verdicts, plus the reasoning-bucket verdicts (`ported` / `kept-delete` / `kept-customization` / `renamed-merged`) — any verdict's reason column cites verbatim the intent entry it relied on — the upgrade-file lists (added / modified), and `$RUN/coverage-blind.txt`.
3. Reads both intent files — `$RUN/qa-ledger.tsv` (this run's answers) and `$RUN/intent-active.md` (standing facts, guard-vetted; SKILL.md → Intent ledger) — never `.kairos/intent.md` directly, so quarantined entries cannot steer the plan and plan decisions honor recorded intent. **The Q&A never re-asks what is already recorded**, and that promise is checkable against two named sources: `$RUN/ask-user-applied.tsv` (the heavyweight add/delete answers Phase 5 asked and `apply-ask-user.sh` enacted) and the resolution ledger (the modify-delete verdicts the resolver fan-out settled). The planner reviews those outcomes and raises one only where it looks wrong — `agents/planner.md` states both as review items, not as questions.
4. Engages the user in grill-me Q&A, logging each answer to `$RUN/qa-ledger.tsv` via `log-intent.sh` at answer time — and any intent fact the user volunteers unprompted is logged the same way, at the moment it is said, not only answers to questions the planner asked.
5. Writes `PLAN.md` to `.kairos/migration/PLAN.md`, including per-upgrade-file dispositions.
6. Clears the completeness gate below.
7. Waits for user approval.

**Frontend pin-compare feeds the plan directly (frontend run only).** When `$RUN/pin-compare.tsv` exists (Phase 3's frontend arm wrote it), the planner reads its verdicts as pin dispositions, **not** as upgrade-files: every `behind` package becomes ONE bump task (set the template's specifier on the component key, then regenerate the lockfile from the bumped manifest), every `ahead` package is a recorded skip-downgrade with no edit, and `equal` produces nothing. **The bump task is ordered before any upgrade-file that adds `authBasePath` to `configureAuth`** — that field needs `@ifs-kairos/auth` 0.10.0+ to typecheck (`agents/planner.md` → Inputs). This adds no completeness-gate row; the pin verdicts are self-contained in the TSV.

**Completeness gate — the plan is not presentable until it passes, and never committed without it.** Three checks, same enforcement pattern. First, every slug in the added / modified / common-library upgrade lists must carry a row in PLAN.md's `## Upgrade-file Dispositions`:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN PLAN=.kairos/migration/PLAN.md "$SKILL_DIR/scripts/plan-completeness.sh"
```

Second, every triggered **follow-up** must carry a row in PLAN.md's `## Follow-up Dispositions` — a stale reference surviving a confirmed delete or a rename, a producer that dirtied tracked state, or a semantic layer that skipped:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN PLAN=.kairos/migration/PLAN.md "$SKILL_DIR/scripts/followup-completeness.sh"
```

Third, every in-range upgrade-file **retired by an applied superseder** must be dispositioned in one of the two sanctioned ways — a `skip` whose reason names the superseder (`superseded by <stem>`), or an `apply` whose reason begins `override:`. The author's `supersedes:` declaration is the word that lets these skips ride without per-skip sign-off, each visible as its own `## Upgrade-file Dispositions` row (below and `agents/planner.md`); this gate is what proves the plan actually honored every edge, so a forgotten deferral or a missed retirement is a loud, named failure here rather than a silent ship or a false Phase-8 `verify-script:` failure. It recomputes the retired set itself from the per-collector edge files (`supersede-edges.tsv`, `common-supersede-edges.tsv`, `lib-supersede-edges.tsv`) closed transitively over PLAN.md's applied set:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN PLAN=.kairos/migration/PLAN.md "$SKILL_DIR/scripts/supersede-check.sh"
```

Each trigger is derived from an artifact the run already wrote (`confirmed-deletes.txt`, `deleted.txt`, `renamed.txt`, `dir-rename-pairs.tsv`, the resolution ledger and its per-batch shards for `kept-delete` verdicts, `producer-idempotence-postmerge.tsv`, `yaml-gate-postmerge.tsv`) rather than re-scraped from the diff, so **while those artifacts are on disk** no follow-up depends on the planner having remembered it. The producer verdict is read at the **postmerge** label by name: that is the verdict describing the tree this plan is being written for — another label's file never stands in (why the labels exist at all: `reference/gates.md`). They are all Phase 5 output (or its gates'), and nothing in Phase 3 puts them back — so the guarantee holds only for a `$RUN` that still has them, and the gate states that limit instead of degrading into judgment: with either of its witnesses absent — `clean-merged.txt`, or `producer-idempotence-postmerge.tsv` while that one is present — it refuses (exit 2, below) rather than reporting an empty catalogue. An individually absent optional list is different and stays optional — a run with no ask-user deletes has no `confirmed-deletes.txt`, and that trigger simply doesn't fire.

A rename contributes two `stale-ref:` checks: the old path itself, and **the directory the rename took away** — the shallowest ancestor of the old path that no longer holds any file after the merge. A directory that still holds files was not renamed away, so a lone file moved out of `internal/` yields no `stale-ref:internal`; and a `web/` → `frontend/` rename whose files live in `web/src/` is checked as `web`, which is what catches a surviving `COPY web/package.json`.

**Exit 2 from any of these gates is a different answer from exit 1: the gate could not run.** They refuse over missing inputs rather than passing over them, because they read artifacts an earlier phase wrote and none has anything downstream to re-derive them — `PLAN.md` is frozen at approval, so an item that drops out here drops out of the migration silently.

- **`plan-completeness.sh`** — an input list is *absent*: `$RUN/upgrades-added.txt` (Phase 3 never ran here, or the state dir was swept), or `common-upgrades-added.txt` while the anchor records `COMMON_MODULES=present` (Phase 3.5 never ran), or `lib-upgrades-added.txt` while the anchor records `LIB_MODULES=present` (the Phase 3 frontend arm's `collect-lib.sh` never ran). This is the resume shape: a session that picks up at planning with a swept `$RUN` has no upgrade lists, and a gate that skipped what it could not find would compare the plan against an empty slug set and pass. **Re-run the phase named in the message** (`phases/3-classify.md`, then `phases/3.5-collect-common.md`; on a frontend run, Phase 3 is `build-manifest.sh` **and** `collect-lib.sh` as one unit) and re-run the gate; never treat the absence as "no upgrade-files in range" — a present-but-empty list is what that looks like.
- **`followup-completeness.sh`** — either of its two witnesses is absent. `$RUN/clean-merged.txt` is Phase 5's: `structural-merge.sh` truncates it unconditionally, so present-and-empty means a merge with no clean merges and *absent* means the merge never ran against this `$RUN`. `producer-idempotence-postmerge.tsv` (under `$RUN`) is the postmerge gate's: absent while `clean-merged.txt` is present means the merge ran but its gate never did (or a pre-label `$RUN`), so the postmerge producer verdict the `skip:producer-*` triggers derive from does not exist — the refusal names the postmerge gate to re-run; another label's file never stands in. In the clean-merged case the re-run that fixes the sibling gate does **not** fix this one — Phase 3 regenerates no merge inventory, no resolution ledger, no gate TSV, so the sweep would derive nothing and report an empty catalogue. **Re-run Phase 5 (`phases/5-structural.md`) so those artifacts exist again**, then re-run the gate — and read that phase's redo warning first: a structural-merge redo discards every logged resolver verdict (`resolutions.tsv` and every shard), which costs nothing on a `$RUN` swept of them and is not free otherwise, and those rows are where this gate's `kept-delete` removals come from. Never read the silence as "no follow-ups in this migration": that case is a present-and-empty witness with no removals, and it exits **0**.
- **`supersede-check.sh`** — an edge file is *absent* while its added-list witness is present: `supersede-edges.tsv` while `upgrades-added.txt` exists (Phase 3 ran but did not emit edges — a swept or partial `$RUN`), or `common-supersede-edges.tsv` / `lib-supersede-edges.tsv` while their `*-upgrades-added.txt` witness exists. Each collector writes its edge file unconditionally (empty when the range declared no `supersedes:`), so present-and-empty is a clean pass and only a genuinely missing file trips this — including one the collector itself REMOVED because its edge emission failed (it never leaves an empty file behind a failure; that collector's own FAIL line names the cause). The gate also exits 2 when it cannot read an input or make a temp file. **Re-run the collecting phase named in the message** (the same phases as `plan-completeness.sh` above), then re-run the gate; never treat the absence as "no supersede edges in range".

Never disposition your way past any exit 2. The two completeness gates exit 1 with `MISSING: <key>` per undispositioned item on stderr, and `supersede-check.sh` exits 1 with `UNRETIRED: <slug>` / `DEFERRED: <slug>` per unhonored edge — disposition each (a follow-up may be dispositioned as a task, or as a logged skip with a reason; a skipped semantic layer **must** be acknowledged, never silently dropped) and re-run until all three exit 0.

**A slug whose body cannot be served is dispositioned, not re-run into.** `next-upgrade-file.sh` exit **5** means that body's capture was refused — `git show` failed on it, and `$RUN/snapshot-refusals.tsv` carries the recorded reason. Re-running Phase 3 / 3.5 reads the same object and fails identically, so the way past it is to repair the source (re-fetch the mirror) or to write the disposition against what is known — naming the unreadable body and the reason — which is what clears `plan-completeness.sh` for that slug. Exit **4** is the opposite case and *does* want the phase re-run (nothing ever captured it). Exit **0** with an `EMPTY:` line is a real upgrade-file that is empty as committed: disposition it as nothing-to-apply. The full table is in `reference/upgrade-files.md`. Clearing them before approval is what keeps the fix cheap: afterwards `PLAN.md` is frozen, and nothing downstream re-derives the applicable set, so an item missing here is one that drops out of the migration silently.

**A `stale-ref:` follow-up for a resolver `kept-delete` may surface where earlier runs of this component showed none.** That is not a regression — the removal was always real, and the follow-up is now derived mechanically from the resolution ledger. When it happens, note it in `.kairos/migration-log.md` (one line: the follow-up comes from a `kept-delete` verdict) so the reviewer reads a new finding as a closed gap rather than as new breakage.

When the user approves, exit the planner role and return to this orchestrator. PLAN.md is now authoritative.

**Before committing, confirm the planner's Q&A reached the ledger.** The planner records each grill answer to `$RUN/qa-ledger.tsv` at answer time (`agents/planner.md` Step 2) — its Q&A is the densest intent stream of the run, and it is the only thing a Phase 5 redo, a plan revision, or Phase 8's intent promotion can re-derive from without re-asking the user everything. So verify the ledger grew to match the questions the planner actually put to the user: if the planner asked anything, `$RUN/qa-ledger.tsv` must now carry rows whose **phase column (column 4) reads `6`** for those answers — the file stores the bare number, not a `PHASE=` literal, so grep the column, not the invocation's env-var spelling. A plan the planner reached by pure inference — no user questions — legitimately adds no rows, and that is the *only* case in which an unchanged ledger is correct. Where an answer the user gave is missing, append it now via `log-intent.sh` (Phase 5 step 5's invocation, with `PHASE=6`) before the commit below — a lost planner answer is one the next Phase 5 redo re-asks from scratch.

**Commit the approved plan immediately — its own commit, before any task runs.** On the **plan-revision re-entry** arm (above), the subject gains a `(revised)` suffix so the history says which commit is the revision — drop the suffix on a first-time plan:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
TARGET=$(ctx TARGET)
git add .kairos/migration/PLAN.md
# Two arms, not a comment to remember: the (revised) suffix is required by the
# re-entry arm above, and a block run verbatim must produce it. The discriminator
# is the same one the coverage-blind block at the top of this file uses — a plan
# already in HEAD means this is the plan-revision re-entry.
if git cat-file -e HEAD:.kairos/migration/PLAN.md 2>/dev/null; then
  git commit -m "chore: migration plan for ${TARGET:0:7} (revised)"
else
  git commit -m "chore: migration plan for ${TARGET:0:7}"
fi
```

This tracks PLAN.md from the moment it exists, which matters two ways: a mid-task-1 `git clean -fd` during continue (see `reference/continue.md`) would otherwise delete an untracked plan, and finalize's `git rm` (Phase 8) would fail if a plan with zero tasks — or one whose tasks were all skipped — never got committed by a task.
