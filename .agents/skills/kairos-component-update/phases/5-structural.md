## Phase 5: Structural step

PHASE_KEY: p2enxd25
(Proof-of-load: `structural-merge.sh` and `apply-ask-user.sh` refuse without `PHASE_KEY=p2enxd25`; the postmerge `gate.sh` accepts any of the three phase-file keys — still pass `p2enxd25` here. The mechanism, and why the key stays only in this file, are in `reference/gates.md`.)

Work the numbered steps in order. Two orderings are load-bearing: the standing-intent check (step 1) runs before anything reads intent, and the intent sweep (step 5) lands before the first dispatch of step 6.

### 1. Vet standing intent

Before anything in this run reads the component's standing-intent facts, run their guards against the current tree:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN "$SKILL_DIR/scripts/intent-check.sh"
```

It reads `.kairos/intent.md` (cross-run intent facts; SKILL.md → Intent ledger), evaluates each entry's optional `guard:` — a tree assertion in a **closed grammar, never shell** (`reference/intent-guard.md`) — and splits the content three ways: `$RUN/intent-active.md` (guard passed, or no guard), `$RUN/intent-quarantined.md` (guard failed — the fact describes a state the tree no longer shows), and `$RUN/intent-unparseable.md` (lines the parser cannot read — a wrong-style bullet, an orphaned `guard:` at column 0 or hidden behind bytes the indentation grammar does not read, or an entry whose guard is outside the grammar — reported on stderr with a reason and excluded from the active view). Every later intent read in this run — resolver dispatches, batched-question pre-fills — uses `$RUN/intent-active.md`, never `.kairos/intent.md` directly, so a stale or unreadable entry cannot steer a resolution.

**If the whole file is refused** — `ACTIVE=0`, nothing verbatim copied out — that is a **NUL byte** or a **git conflict marker**, and it is *not* "this component has no standing intent": say so explicitly (quote the script's reason line and state that every standing fact is excluded this run), hand-repair the file's readability only, and re-run the vet before continuing. That refusal, why it fails closed, and its one sanctioned hand edit are in `reference/intent-guard.md → Whole-file refusal`.

If anything was quarantined or unparseable, ask ONE batched re-confirm question — a table of `entry | failed guard | re-affirm / update / retire | recommendation`, where each unparseable finding is an additional row whose "failed guard" column reads its `UNPARSEABLE:` reason — and apply the answers to `.kairos/intent.md` through `scripts/promote-intent.sh`, its format owner — **never by hand** (two narrow exceptions, both in `reference/intent-guard.md`: the whole-file repair and the wrong-style bullet), because an edit that leaves a `guard:` at column 0 de-guards the entry above it:

- **re-affirm** — `ACTION=update MATCH="<the fact>" ENTRY="<the same fact>" GUARD="<a guard that attests it again>"` (the date refreshes automatically). Every `GUARD=` you write must be inside the grammar, or the next run excludes the entry again; when nothing in the grammar can attest the fact, write it guardless (`DROP_GUARD=1`) and let the resolver-side contradiction rule be the backstop.
- **update** — `ACTION=update MATCH="<the old fact>" ENTRY="<the fact that is now true>"`, plus `GUARD=` to replace the guard or `DROP_GUARD=1` to remove it; omit both to keep the existing one. An entry reported unparseable for an **out-of-grammar guard** is a recognised entry, so it is repaired here: `GUARD="<an in-grammar guard>"` or `DROP_GUARD=1` — the fact is not in question, the guard is.
- **retire** — `ACTION=retire MATCH="<the fact>"`, which deletes the bullet *and* its guard together.

**An unparseable *line* is not an entry**, so neither `retire` nor `update` can name it (`MATCH` looks a fact up by its `- <date>: <fact>` bullet), and its repair depends on the shape. An **orphaned column-0 `guard:`** the script handles: a `retire`/`update` on the entry that **owns** it sweeps it — or, on a guardless `update`, has it **adopted** as that entry's own indented guard — while an orphan owned by another entry always survives whatever guards that entry already carries, its repair being an `update` on *that* entry and never a hand delete. A **wrong-style bullet** (a `*`/`+` marker, a `-` with no space, a tab-indented bullet) is the one **sanctioned hand-edit** for a line-level finding: `ACTION=append` the well-formed entry, delete that one stray line in the same edit, and say so in the migration log. The ownership/adoption/sweep rules, the protect-vs-refuse verdict, and the NBSP-hidden-indent case are all in `reference/intent-guard.md → Per-line unparseable findings`; the clause-by-clause mechanics are `scripts/promote-intent.sh`'s header.

Then re-run `intent-check.sh` so `$RUN/intent-active.md` reflects the decisions; the edit to `.kairos/intent.md` rides the structural commit below. Guardless entries pass through untouched — the contradiction rule in `agents/conflict-resolver.md` is their backstop.

### 2. Mechanical merge

Run the mechanical merge (rules in `reference/structural-merge.md`):

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); SYNTH=$(ctx SYNTH); BASE=$(ctx BASE); TARGET=$(ctx TARGET)
export SYNTH BASE TARGET RUN
PHASE_KEY=p2enxd25 "$SKILL_DIR/scripts/structural-merge.sh"
```

The script lands the mechanical buckets (`added-mechanical`, `renamed-mechanical`, `deleted-by-template-mechanical`) and runs the 3-way merge for `merge-pipeline` files, recording results in `$RUN/`: `clean-merged.txt`, `conflicts.txt`, `merge-errors.txt`, `binaries.txt`, `normalized-ours.txt`, plus the change inventories `added.txt` / `deleted.txt` / `renamed.txt` (Phase 6's follow-up sweep reads the latter two).

The preamble above is why `$SYNTH` is never "not in hand" — it comes off the anchor on every run of this step, compacted session or not. If the tree it names is gone — or the merge refuses it as not a usable synthetic repo — re-run the run's materializer first (load `phases/2.5-materialize.md`, which dispatches by `RUN_SOURCE`: `materialize.sh` on a template run, `materialize-frontend.sh` on a frontend one — the template arm on a frontend run would rebuild `$SYNTH` from the component template, the wrong trees entirely; both are stamped, so unchanged inputs reuse the trees). `structural-merge.sh` and `apply-ask-user.sh` (step 4b) both read the side tags out of `$SYNTH` and hard-stop on a stale one with that same remedy; the gate in step 9 degrades a semantic layer you could restore for one cheap call.

Two other refusals mean the classification and `$SYNTH` disagree, and **both are fixed by re-running Phase 3, not by retrying this step** (load `phases/3-classify.md`, then come back):

- `classification.tsv was derived from different synthetic trees` / `classification-trees.tsv missing` — `$SYNTH` was re-materialized (or the binding never written) after classification, so every row may name a path, status or merge base that no longer exists. (The gate in step 9 re-checks the same binding before it tallies ask-user coverage, and fails its `ask-user` row on the same mismatch — same remedy.)
- `N classification row(s) name a target-side entry this merge cannot write` — the rows it lists name a path that is absent at `kairos-target`, is a directory or gitlink there, is a symlink (mode `120000`, whose link text would land as file content), or carries no `template_path`/destination to write. **Every** bad row is in that one refusal, so one Phase 3 redo clears the whole set.

Neither refusal touched anything — not a file in the tree, not `$RUN`'s output lists, not a previous attempt's resolver verdicts; do not work around either by hand-editing rows.

**A successful re-run is the opposite: it discards every resolver verdict already logged.** Past the refusal checks the script deletes `$RUN/resolutions.tsv` and every `resolutions.<slug>.tsv` shard (`role-switch` and `legacy` included), because a verdict describes a conflict hunk in the tree this run is replacing. Step 6 must then be redone in full. So before re-running this step, check that anything the user decided during the previous attempt is recorded in `$RUN/qa-ledger.tsv` via `log-intent.sh` — that survives, and it is what stops the re-dispatched resolvers from re-asking (rationale: `reference/structural-merge.md` → Resolution log).

**Line endings are normalized to LF, always** — otherwise a file differing only in line endings conflicts on every line. `$RUN/normalized-ours.txt` names the formerly-CRLF files this touched; **declare that list in the structural-merge log entry** so the reviewer reads it as policy, not damage.

### 3. Classification handoff card

Generate the classification handoff card and work from it — it is computed when you run it, so it can never describe a state you've already moved past:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN "$SKILL_DIR/scripts/handoff-classify.sh"
```

Its stdout carries the bucket tally plus ready `query.sh` one-liners for the ask-user / for-AI buckets this phase handles. **Read that** — don't re-derive bucket state from `classification.tsv` or from earlier conversation history. `$RUN/binaries.txt`, written by `structural-merge.sh` in step 2, joins the card's `binary-for-user` rows (below).

### 4. Batched user questions (mechanical decisions)

**Batch the mechanical decisions.** Ask ONE question per category, as a table with your recommendation per row, and let the user answer in bulk ("all as recommended", "all except logo.png") — ten binaries must not become ten sequential interrupts:

- `binary-for-user` + `binaries.txt` → one question: a table of `file | keep yours / take template's | recommendation + why` for every binary. Take the **union, de-duplicated by path**, of the two sources. A binary the template also **renamed** carries its pre-rename path beside the row (column 5 of `classification.tsv`, or a second TAB field in `binaries.txt`) — show it as `old → new` in the table and keep it **one row, one decision**: `theirs` takes the template's file at the new path *and* removes your old copy; `ours` leaves the tree exactly as it is (your binary stays where it is, the new path is not created). Never split a renamed binary into a separate move question.
  - A binary the template **deleted** and you customized rides the same bucket and the same `theirs` | `ours` vocabulary, but `theirs` means **adopt the deletion** — there is no template blob left to take. Its row carries status `D` (column 2 of `classification.tsv`); phrase that row as `drop it / keep yours` and say plainly that `theirs` removes the file. These never come from `binaries.txt`.
- `added-heavyweight-ask-user` → one question: a table of `root dir | file count | take / skip / cherry-pick | recommendation` per addition (grouped by root dir).
- `deleted-heavyweight-ask-user` + `deleted-heavyweight-dirs.txt` → one question: a table of `directory | file count | delete / keep | recommendation + why` per emptied subtree. **Grep before recommending**: `delete` when it's template scaffolding the component never referenced, `keep` when anything outside it still references it.

**Pre-fill recommendations from standing intent.** Before recommending a row, check `$RUN/intent-active.md`: a standing fact that answers it becomes the recommendation, cited in the table (e.g. "intent.md 2026-08-06: web/ deliberately absent") — never re-derived and never re-asked as an open question; the user still confirms the batch.

### 4b. Enact the decisions

Write `$RUN/ask-user-decisions.tsv` from the answers — `bucket<TAB>path<TAB>decision`, **one row per classified path**: grouping (by root dir, by directory) was a presentation concern of the question only, so a cherry-pick expands to per-file `take` / `skip` rows. Decision vocabulary per bucket: `binary-for-user` → `theirs` | `ours`; `added-heavyweight-ask-user` → `take` | `skip`; `deleted-heavyweight-ask-user` → `delete` | `keep`. Then enact:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); SYNTH=$(ctx SYNTH)
export RUN SYNTH
PHASE_KEY=p2enxd25 "$SKILL_DIR/scripts/apply-ask-user.sh"
```

The script is fail-closed: an incomplete decision set (one `MISSING: <bucket>:<path>` per item), an invalid decision, or a `theirs`/`take` whose blob is absent at the target tag enacts nothing — complete or fix the TSV and re-run. On success it writes `$RUN/ask-user-applied.tsv` (no-op decisions get a row too — the postmerge gate's coverage compare reads it) and **owns the `confirmed-deletes.txt` append for enacted deletes — never append those by hand**. A renamed binary answered `theirs` is one applied row (`written`, at the new path) plus its pre-rename path in `confirmed-deletes.txt`: that is where the old copy's removal is recorded, and the only place it is. A **template-deleted** binary answered `theirs` is one applied row too, with outcome **`deleted`** and the path in `confirmed-deletes.txt` — nothing is written for it, and the script refuses the row outright if the target tag still carries that path (the classification would be contradicting the tree). Run it even when step 4 had nothing to ask: with zero classified items it exits 0 and writes an empty applied TSV; the gate's `ask-user` row passes on the empty classified set itself. Carry its applied tally (`N row(s): W written, U unchanged, D deleted`) into the structural-step migration-log entry.

**Revising an enacted answer.** A user who reverses a step-4 decision after the enactment is stating new intent, so the correction follows the same order the original took — record, then enact:

1. Append the corrected answer to the ledger via `log-intent.sh` (step 5's invocation) — a revision is a **new appended row, never an edit**, and on the same question the later row supersedes the earlier (SKILL.md → Intent ledger), so every later dispatch reads the correction.
2. Fix the row in `$RUN/ask-user-decisions.tsv`, and undo by hand what a re-run cannot: `ours`/`keep`/`skip` are no-op decisions, so a re-run never un-writes what a prior `theirs`/`take`/`delete` enacted. Route the undo by what that enactment actually did (`scripts/apply-ask-user.sh`):
   - a reversed `take`, or a reversed `theirs` on a template-**added** path → the blob landed at a path absent from HEAD, so it is untracked; remove the written path, or step 8's `git add -A` sweeps it into the commit.
   - a reversed `delete`, a template-deleted `theirs`, or a `theirs` that overwrote a customized binary **in place** → the script removed or overwrote a path HEAD still carries, so `git checkout HEAD -- <path>` restores the component's blob (HEAD holds it until step 8 commits).
   - a reversed `theirs` on a **renamed** binary needs **both**: the script wrote the target blob at the new path and removed the old copy, so `git checkout HEAD -- <the row's new path>` does not resolve (HEAD has no new path). Remove the newly-written new path — untracked, so step 8's `git add -A` would otherwise sweep it — **and** `git checkout HEAD -- <old path>` to restore the old copy.
3. Re-run `apply-ask-user.sh` (the block above) with the corrected TSV — it is re-run safe by design: it re-validates the whole decision set, **rewrites** `$RUN/ask-user-applied.tsv`, and **rebuilds** `confirmed-deletes.txt` from the corrected set, so a retracted delete drops out of Phase 6's stale-ref sweep with no hand edit of either record.

After step 8 has committed, the same correction is an amend arm: restore from the structural commit's parent instead of HEAD, re-run the script, `git add -A && git commit --amend`, and **re-record `STRUCTURAL_SHA` (step 9's block)**. Once Phase 6 has planned on top of the answer, stop instead and go through the plan-revision path (SKILL.md → What you NEVER do; `reference/continue.md`).

### 5. Pre-dispatch intent sweep (MANDATORY — before the first dispatch)

Immediately before the first dispatch of step 6 — never after it — sweep the session so far and record each item in `$RUN/qa-ledger.tsv` via its format owner (schema and append-at-answer-time rule: SKILL.md → Intent ledger):

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN PHASE=5 SCOPE="<path or module, empty if component-wide>" \
  QUESTION="<question, or 'volunteered'>" ANSWER="<what the user said>" \
  "$SKILL_DIR/scripts/log-intent.sh"   # once per item; never append by hand
```

- every intent-relevant statement the user has made anywhere in this session ("we deleted `web/` deliberately", "we don't use the event handler"), and
- every answer step 4 already collected — the binary picks and the heavyweight add/delete outcomes are intent facts too.

A volunteered intent fact — one the user states unprompted, like "we deleted `web/` deliberately" — is logged via `log-intent.sh` the moment it appears, exactly as an answer is, not held back for this sweep; the sweep is the backstop that catches anything not already recorded.

A fresh-context subagent cannot see this conversation; the ledger is the only bridge. A dispatch that fires before this sweep has recorded nothing the user actually said — that is the failure mode this step exists to close, and why it is a numbered step rather than advice.

### 6. Conflict-resolver fan-out

Three inputs ride one dispatch pipeline — each item is independent:

- `$RUN/conflicts.txt` — files left with diff3 markers by step 2 (skip if empty)
- `modify-delete-for-ai` rows — `$RUN/query.sh modify-delete-for-ai`
- `renamed-with-mods-for-ai` rows — `$RUN/query.sh renamed-with-mods-for-ai`

The reasoning buckets dispatch to the conflict-resolver exactly like conflicted files; the per-bucket invariants (never-resurrect, the `component_path` starting point, the needs-input bias) and the extended verdict vocabulary live in `agents/conflict-resolver.md`, not here.

- **Runtime subagent dispatch available** — mandatory whenever any item is pending across the three inputs: a single pending item still goes to a single subagent (fresh context is the point, not just parallelism), and with more than one you never resolve them in your own context:
  - **(a)** Dispatch the items in batches — one subagent per batch, each dispatch with its own `$RUN/resolutions.<slug>.tsv` to avoid interleaved appends. **Batch by context budget, not by a dispatch-count target — and dispatch sequentially.** Group pending items into batches of related files (same directory, same module) sized so one agent stays sharp for its whole batch: ~10 small regions, fewer when files are large. Dispatch count falls out of that — a 6-item merge is one dispatch, a 60-item merge maybe six — and batches run **one at a time by default**. Speed is the cheapest thing to spend here, and sequencing buys correctness: a needs-input answer recorded in `$RUN/qa-ledger.tsv` by an early batch is read by every later batch's dispatch, which a parallel wave can never benefit from. Parallelize only if the user asks for speed. The two failure modes this rule steers between: many per-file dispatches pay a fixed overhead each (role file + both ledgers re-read) for no correctness gain, while one agent carrying everything degrades — item 1's three-way contents still crowd its context when it judges item 30, and a mid-run failure loses the whole set's progress instead of one batch's. Before the first dispatch, tell the user the item count, batch count, and model.
  - **(b)** Prompt each subagent to read `$SKILL_DIR/agents/conflict-resolver.md` by **absolute** path — a fresh subagent's cwd is the component root, so a relative `agents/…` path resolves to nothing; and never paste the role file's contents into the prompt; the subagent can read a path itself. The prompt names, all six — **seven on the run's FIRST dispatch**, which adds the actual-model probe sentence (recorded in step (d) below, the dispatch-record step — SKILL.md → Spawn accounting):
    - **the run-state dir** — `RUN` is `.kairos/migration/state`, stated as a value, and **`SKILL_DIR`** as an absolute path. These are not optional context: the role file's mandatory step is one `log-resolution.sh` call per resolved region, invoked as `"$SKILL_DIR/scripts/log-resolution.sh"` with `RUN=` — a fresh subagent knows neither, so a prompt that omits them dispatches a resolver that cannot log the verdicts its role requires, and the planner then reviews a merge with no ledger.
    - the assignment (the conflicted path(s), or the classification row — bucket, path, and any `component_path` candidate) and its **shard slug**, i.e. the subagent's own `$RUN/resolutions.<slug>.tsv`, passed as `SHARD`.
    - **both intent inputs — `$RUN/qa-ledger.tsv` and `$RUN/intent-active.md` — unconditionally, even when one is empty, with the instruction: read both before deciding; a matching entry overrides your own inference and is cited verbatim in the reason column.**

     The six, enumerated so "missing any" is checkable against this text: **(1)** the run-state dir `RUN`, **(2)** `SKILL_DIR`, **(3)** the assignment, **(4)** its shard slug (`SHARD`), **(5)** `$RUN/qa-ledger.tsv`, **(6)** `$RUN/intent-active.md` — the FIRST dispatch adds the actual-model probe sentence as the **seventh**.

     **A resolver prompt missing any of the six is malformed: do not send it** — and on the run's first dispatch the probe sentence is the seventh, so a first prompt without it is malformed too. (Phase 7's executor spawn carries `$RUN` and `SKILL_DIR` for the same reason — see `phases/7-execution.md` step 1.)
  - **(c) Always dispatch with `model: <STRONG_MODEL>` named on the call** — never the executor's cheaper model, and never left to inherit the session model — because three-way merge intent is the highest-consequence judgment in the run.
  - **(d) Record each conflict-resolver dispatch** once its outcome is known:

     ```bash
     RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
     SKILL_DIR=$(ctx SKILL_DIR)
     RUN=$RUN PHASE=5 PHASE_KEY=p2enxd25 ROLE=conflict-resolver TIER=strong MODEL="<slug>" ITEM="<shard slug>" \
       ACTUAL_MODEL="<probe reply — first dispatch of the run only, else empty>" \
       OUTCOME="<ok|needs-input|fail>" "$SKILL_DIR/scripts/log-spawn.sh"
     ```

     **One row per dispatch, never per item.** `ITEM` is the dispatch's shard slug — unique per batch by construction, and the join key to that dispatch's `resolutions.<slug>.tsv` (a single-file dispatch may use the path instead; the slug still works). A mixed batch records its **worst** outcome — `fail` beats `needs-input` beats `ok` — because the row drives dispatch-level remedies (a `fail` is reset + re-run, a `needs-input` holds the collect barrier), and per-item rows would inflate Phase 8's dispatch tally by the batch size.

     `log-spawn.sh`'s vocabulary is five (`escalated` and `retried` too; SKILL.md → Spawn accounting), but **Phase 5 dispatches only ever produce these three**: this fan-out is pinned to `<STRONG_MODEL>` so there is no higher tier to escalate to, and the one automatic fresh-context retry is Phase 7's. A re-dispatch after a `fail` here is a deliberate re-run that records its own `ok` / `needs-input` / `fail`, not a `retried`.

     — and if this is the run's first dispatch, add the actual-model probe sentence to its prompt and record the reply in `ACTUAL_MODEL` (SKILL.md → Spawn accounting; mechanics in `reference/model-resolution.md`). A batch re-dispatched after a recorded `fail` — or after `log-spawn.sh` refused the dispatch's row outright (a wrong-model dispatch writes **no** row, not a `fail`; SKILL.md → Spawn accounting) — must supersede the earlier attempt's shard before writing again, so the retry never doubles it:

     ```bash
     RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
     SKILL_DIR=$(ctx SKILL_DIR)
     RUN=$RUN ACTION=reset SHARD="<slug>" "$SKILL_DIR/scripts/log-resolution.sh"
     ```

     `reset` also drops `$RUN/resolutions.tsv` — that is deliberate and lossless: the aggregate is rebuilt by the next `collect`, and it is the only way a supersede reaches rows a previous `collect` already published. A re-dispatched `fail` therefore stays in fail state until its re-run returns `ok`; the aggregate is not rebuilt here but by the single collect at the end (this section's collect step, (f) below), so the four consumers read no aggregate until the barrier clears and that collect runs.
  - **(e) Resolve every needs-input and every `fail` before collecting — the barrier.** A subagent hitting genuine ambiguity returns a needs-input result rather than guessing — relay it to the user, **record the question and answer at answer time via `log-intent.sh`** (Phase 5's Step 5 invocation — the pre-dispatch intent sweep), and re-spawn with the answer. A needs-input item deliberately leaves its conflict markers in place and logs **no** verdict row (`agents/conflict-resolver.md`), so it is **not yet resolved**. Drive both the needs-input items (answer + re-spawn, here) and every `fail` re-dispatch (reset + re-run, (d)) through to an `ok` outcome. **Do not run `collect` ((f)) until zero items remain in needs-input or fail state.**

     **The re-spawn prompt must state the needs-input region's `REGION` ordinal verbatim, as the returning resolver reported it, and instruct the re-spawned resolver to log its verdict under that ordinal rather than re-counting the file.** The ordinal is the region's position in the file *as first handed to the first resolver* (`agents/conflict-resolver.md` defines it that way), and the re-spawned resolver cannot re-derive it: the regions resolved before the needs-input have had their markers removed, so a mid-file region counts as `REGION=1` in the file it now sees. A wrong-but-in-range ordinal errors nowhere — `dropped-template-changes.sh` re-derives regions positionally from the original three sides and would hand the planner a different region's template text as the evidence for this verdict. Carry the ordinal even when the batch had one item.
  - **(f) Collect the shards — last, and only once the barrier of (e) has cleared.** With zero items left in needs-input or fail state, rebuild the aggregate with the ledger's format owner — never `cat` the shards by hand:

     ```bash
     RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
     SKILL_DIR=$(ctx SKILL_DIR)
     RUN=$RUN ACTION=collect EXPECT="<dispatch count>" "$SKILL_DIR/scripts/log-resolution.sh"
     ```

     It rebuilds `$RUN/resolutions.tsv` from the shards rather than appending, so re-running it after a retried batch cannot double the rows the earlier batches already logged, and `EXPECT` makes zero shards a hard failure when dispatches were expected instead of a silently empty ledger. **`EXPECT` guards only against zero shards — it does not detect a shard that returned needs-input and logged no verdict**, which is exactly why the (e) barrier, not `EXPECT`, is what keeps a premature collect from silently rebuilding `resolutions.tsv` short those verdicts (and leaving their live markers in a non-compiled file that Phase 5's Step 9 postmerge gate does not scan). The aggregate is derived state — never hand-edited, safe to delete, reproduced in full by re-running this. (A row it finds only in an aggregate written before the shards existed is moved into a `resolutions.legacy.tsv` shard, once, which is what keeps that true; `legacy` is therefore not a slug you may dispatch under.)
- **No runtime dispatch**: adopt the role in-conversation over the whole input set — `conflicts.txt` plus both bucket row lists — sequentially, logging each verdict with the same script. **The ledger's unit is the conflict REGION, not the file** — `log-resolution.sh` enforces it and `agents/conflict-resolver.md` states the same contract for the dispatched arm, so this arm follows it exactly:
  - A **conflict-region verdict** (`ours` | `theirs` | `merged` | `user`) is logged **once per region**, carrying `REGION=` — the 1-based ordinal of that region's **position in the file as the merge left it**. Count the `<<<<<<<` markers top to bottom *before you start resolving*: the ordinal is fixed by position, never by the order you work them in or by which ones you skip.
  - A file with three resolved regions costs three calls. An empty, `-`, `0` or non-numeric `REGION` on a conflict-region verdict is **refused** (exit 2) — a per-file call is not a shortcut, it is a rejected row.
  - A **reasoning-bucket verdict** (`ported` | `kept-delete` | `kept-customization` | `renamed-merged`) has no regions by construction, so it stays **once per file**, with `REGION=-`:

  ```bash
  RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
  SKILL_DIR=$(ctx SKILL_DIR)
  # conflict-region verdict — one call per REGION, in file order
  RUN=$RUN SHARD=role-switch FILE="<path>" VERDICT="<ours|theirs|merged|user>" \
    REASON="<one line>" REGION="<this region's 1-based ordinal>" \
    "$SKILL_DIR/scripts/log-resolution.sh"   # repeat per region, never per file
  # reasoning-bucket verdict — one call per file; no region exists to number
  RUN=$RUN SHARD=role-switch FILE="<path>" \
    VERDICT="<ported|kept-delete|kept-customization|renamed-merged>" \
    REASON="<one line>" REGION=- \
    "$SKILL_DIR/scripts/log-resolution.sh"   # repeat per file
  ```

  The ordinal is **positional**, not bookkeeping — its dedup-collision and positional-re-derivation semantics (why a resolution-order count stays in range yet silently names a different region's template text to the planner's `ours`-row reader) are owned by `agents/conflict-resolver.md`, the role this arm adopts, and by `scripts/dropped-template-changes.sh`'s header. Honor that definition exactly here.

  then **collect exactly as the dispatched arm does**:

  ```bash
  RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
  SKILL_DIR=$(ctx SKILL_DIR)
  RUN=$RUN ACTION=collect "$SKILL_DIR/scripts/log-resolution.sh"   # no EXPECT: nothing was dispatched
  ```

  which is what publishes `$RUN/resolutions.tsv` for its four consumers. `role-switch` is the reserved slug for in-conversation work: every resolution row, dispatched or not, goes into a shard, so `collect` (a rebuild) can never overwrite the rows this arm wrote. A re-decision for a region already logged resets first:

  ```bash
  RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
  SKILL_DIR=$(ctx SKILL_DIR)
  RUN=$RUN ACTION=reset "$SKILL_DIR/scripts/log-resolution.sh"   # no SHARD: clears this arm's shard and the aggregate
  ```

  then re-log **every** row this arm still stands behind — `reset` clears the whole shard, not one row, so each region gets its own call again, ordinals included — and **re-collect**: every `reset` drops the aggregate, so the collect is what puts it back. Same instructions, same intent inputs; only the write target is shared with the dispatched arm.

Either way — and only once the barrier has cleared, every needs-input answered and re-spawned and every `fail` re-run to `ok`, so no item is still holding its markers — the resolver has removed all markers and logged every resolution (the planner reads `resolutions.tsv` — `ours` rows are dropped template changes, `merged` rows are hand-woven code, and any verdict — bucket or conflict-region — that relied on a recorded-intent entry cites it verbatim). A needs-input item is **not** resolved until answered; the (e) barrier before collect is what guarantees its markers are gone before this commit. Then exit the role / collect the subagents.

### 7. Inline leftovers

Two buckets stay with you — they are mechanical inspection, not intent inference:

- `merge-errors.txt` → inspect each (usually encoding or filesystem issues); the script left the working-tree file untouched. A row may carry a second TAB field — the pre-rename old path, for a rename whose merge errored before the rename completed: nothing exists at the new path and the component's copy still sits at the old one, so resolve **both** sides (write the resolution at the new path *and* remove the old copy, or keep the old path deliberately) — settling only the new path leaves the old copy riding into the structural commit as a duplicate no artifact names. Resolve or ask.
- `unknown-status` → the classifier hit a git status it doesn't route (rare). Inspect the row, decide manually, document.

### 8. Commit

Stage and commit ALL of the above as ONE commit:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); BASE=$(ctx BASE); TARGET=$(ctx TARGET)
# Guard the two the commit message interpolates: an empty TARGET/BASE would bake a
# `${TARGET:0:7}`-into-nothing subject and empty Baseline/Target lines into the one
# commit whose message is this run's structural-provenance record (SKILL.md flags
# exactly this archetype). It does not cost *history* — STRUCTURAL_SHA below is still
# captured from a real commit — so this guards provenance, not the rollback point.
: "${TARGET:?FAIL: TARGET missing from the run-context anchor — stop; re-establish it before committing the structural merge}"
: "${BASE:?FAIL: BASE missing from the run-context anchor — stop; re-establish it before committing the structural merge}"
# Re-executed step 8 (a resume, or a re-run after compaction) reaches this with the
# structural commit ALREADY on HEAD. Detect that BEFORE committing: a pending
# migration-log entry would otherwise ride a *second*, duplicate structural commit,
# and the no-move check below would then misread the already-landed state as "did not
# land" and invite forcing a commit that already exists. Look at HEAD only (`git log
# -1`), never a range — on a chained frontend run the template leg's own structural
# commit sits back in history, and a range check would false-positive on it.
if git log -1 --format=%s | grep -q '^chore: structural merge to '; then
  # Already landed on a prior pass — record the anchor from HEAD, commit nothing.
  RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" STRUCTURAL_SHA=$(git rev-parse HEAD)
else
  pre=$(git rev-parse HEAD)   # the scaffolding SHA — the record below guards against anchoring this
  git add -A
  git commit -m "chore: structural merge to ${TARGET:0:7}

Baseline: ${BASE:0:7}
Target:   ${TARGET:0:7}
Clean-merged: <N>
AI-resolved: <M>
Binary user-decided: <K>
Heavyweight added: <list or 'none'>"
  # anchor-exempt: this call ESTABLISHES STRUCTURAL_SHA, captured from the commit
  # that was just made — the structural commit's own SHA, recorded the moment it
  # lands. Items 2 and 6 both read it later from the anchor: "pre-existing" (a
  # test file, a dropped template change) means present AT THIS COMMIT, and that
  # question only has a stable answer if the SHA is captured here rather than
  # derived from history at trigger time, where a compaction or an amended commit
  # makes "which commit was structural" guesswork.
  # Guard the record on the commit having landed: a refused commit (empty tree, a
  # rejecting hook) leaves HEAD at $pre, and anchoring the scaffolding SHA would
  # point Items 2 and 6 at the wrong commit. Record only once HEAD has moved.
  sha=$(git rev-parse HEAD)
  if [ "$sha" = "$pre" ]; then
    echo "FAIL: structural commit did not land — HEAD is still the scaffolding SHA; fix and re-commit before recording STRUCTURAL_SHA" >&2
  else
    RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" STRUCTURAL_SHA=$sha
  fi
fi
```

### 9. Postmerge gate

A clean merge (no conflict markers) can still produce broken code — two individually-clean hunks that together break syntax or logic. A marker-free merge is **not** a correct merge. Verify before planning by running the postmerge gate — the post-merge sanity pass — it sequences build, tests-vs-baseline, the YAML gate, producer idempotence, the replace-directive check, and — at `LABEL=postmerge` only — the `ask-user` row, which compares the classified ask-user set against `$RUN/ask-user-applied.tsv` and so catches step 4b being skipped entirely, reading the commands and extractor from `$RUN/test-command.txt` (positional contract and card format: `reference/gates.md`; the full interpretation contract: `reference/gate-cards.md`):

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
  ( cd "$MOUNT" && LABEL=postmerge RUN="$RUN_ABS" SYNTH="$SYNTH_ABS" PHASE_KEY=p2enxd25 "$SKILL_DIR/scripts/gate.sh" )
else
  LABEL=postmerge RUN=$RUN SYNTH=$SYNTH PHASE_KEY=p2enxd25 "$SKILL_DIR/scripts/gate.sh"
fi
```

The card also carries a `census` row (`reference/gates.md` → *The census row*):
at this label it is always `INCOMPLETE`, relaying the template-era population
change (baseline→postmerge) as informational input for the planner — nothing to
act on here. The executor-era disappearance diff, the one that can `FAIL` the
gate, runs only at the `final` label in Phase 8.

**The conflict-marker scan is not in this card.** `gate.sh` runs it **only at the final gate** (`LABEL=final`), so a `postmerge` — or `midplan` — `PASS` is **never** evidence that no marker survived anywhere in the tree. The absence is silent too: there is no `INCOMPLETE` row saying the scan was skipped, so nothing in the card records that the question was never asked (`reference/gates.md`). Other rows can still *trip over* a marker — a live marker in a compiled or parsed file usually breaks the build or YAML row — but that is a side effect on the files those layers happen to read, not coverage, and a clean build says nothing about the rest of the tree. What covers the interval instead: the resolver's own hand-off check over its assigned paths (`agents/conflict-resolver.md`), Phase 7's per-task marker grep on the files each task touched, and `structural-merge.sh`'s refusal to re-run while a file listed in `$RUN/conflicts.txt` still carries live markers. If you want a whole-tree answer before Phase 8, grep for it yourself — do not read it out of this card.

**Relay the verdict card verbatim** — every row plus the `AGGREGATE` line; do not re-derive verdicts from the raw artifacts (the card carries the evidence and pointers). **For any non-`PASS` row, read `reference/gate-cards.md`'s interpretation contract before acting** — it is the load-and-act exception that says what each status means and what you do with it (red-on-red, `extractor:` vs `gate-internal:`, which `INCOMPLETE` rows have no mechanical backstop). Then act on the aggregate:

- **`PASS`** → proceed. First relay every `INCOMPLETE` row into the structural-step log entry as **incomplete semantic coverage**, naming the layer that did not run and why — never as "clean" (rule and its Phase 6 backstop: `reference/gate-cards.md`).
- **`NEEDS-INPUT`** (inherited local-path `replace` directives pointing outside the component root; an in-repo `./pkg/schema` replace is never listed and is never dropped) → show the directives and ask keep or drop — never auto-drop (why: `reference/gates.md`). Drop → remove them, amend the structural commit, **re-record `STRUCTURAL_SHA` from the amended commit (block below) before the gate re-run**, then re-run the gate. Keep → record the decision (and that it will break CI) in the migration log and proceed.
- **`FAIL`** → stop. Do NOT proceed silently. Surface the card's FAIL rows (they name the failing modules / test IDs / files) and offer:
  - **(a)** you inspect and fix the merge inline, then amend the structural commit (`git commit --amend`), **re-record `STRUCTURAL_SHA` from the amended commit (block below) before the gate re-run**, and re-run the gate, or
  - **(b)** record them so the planner creates an explicit fix task in PLAN.md.

**Every amend arm above rewrites the structural commit, so re-record `STRUCTURAL_SHA` immediately after the amend and before the gate re-run** — step 8 anchored the SHA of the commit the amend just replaced:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" STRUCTURAL_SHA=$(git rev-parse HEAD)
```

Nothing downstream re-derives it: Phase 6's dropped-change evidence and Phase 7's bent-test trigger both read `STRUCTURAL_SHA` off the anchor, and the replaced commit is still a reachable object for a while — so a stale value does not error, it silently answers "was this test file present at the structural commit?" and "what did it look like there?" about a commit that is no longer in the branch's history. Phase 7's read is hard-guarded, which stops an *empty* value but cannot see a stale one; this call is the only thing that keeps it true.

A `buried-key` FAIL on a *deliberate* demotion is overridable: add a `file <TAB> key <TAB> reason` row to `$RUN/yaml-gate-ack.tsv` and re-run — it becomes an acknowledged skip (an `INCOMPLETE` row), logged, not a hard block.

Only once the aggregate is `PASS` — or the FAIL rows are explicitly acknowledged and slotted for the planner — move to Phase 6.

Append a structural-step entry to `.kairos/migration-log.md`: the gate card outcome (aggregate, plus every non-PASS row and how it was dispositioned), the `apply-ask-user.sh` applied tally from step 4b, the `$RUN/normalized-ours.txt` list as a declared CRLF→LF policy, any quarantined- or unparseable-intent re-confirms and how each was settled, the `replace`-directive decision if one was asked, and the unpinned kairos-gen version from `$RUN/learnings.md` if Phase 4.5 logged one.
