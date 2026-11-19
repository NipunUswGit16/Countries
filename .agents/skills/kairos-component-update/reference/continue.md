# Continue

Entered when the user says continue / resume / pick up AND `.kairos/manifest.yaml` has a `template.in_progress` **or** a `frontend.in_progress` block. There is no state machine to resume from — inspect git + filesystem to figure out where things stand.

**Step 0 — which SOURCE is being resumed.** A run is one source (SKILL.md → Phase index), and the block that exists names it. At most one does: pre-flight refuses a manifest carrying both, so there is nothing to disambiguate — but there IS something to *read*, because every key below is that source's. Resolve it first, in one line, and re-derive it at the top of each block that needs it (a fresh shell per tool call):

```bash
SRC=template; case "$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml)" in true) SRC=frontend ;; esac
echo "resuming the $SRC run"
```

Pre-flight prints the same answer as an `IN_PROGRESS_SOURCE=` line, so step 2's run confirms it. Below, `<src>` means that value: `<src>.in_progress.*` is `template.in_progress.*` on a template run and `frontend.in_progress.*` on a frontend one, and `<src>.sha` is the baseline that run advances. A template resume therefore reads exactly what this document always said. **The one thing that is NOT parameterized is `$RUN`**: a run's state dir is the same fixed path either way, because only one run is ever live.

**Dirty tree first.** A crashed run leaves the tree dirty — but so does a *healthy* one, so read the shape of the dirt before touching anything. **Every migration-log entry rides the NEXT commit by design**: Phase 5 appends its structural entry after the structural commit, Phase 7 writes each task's entry after that task's commit (`phases/7-execution.md` step 6), and Phase 8 writes its summary before step 5 commits. So virtually every legitimate resume after Phase 5 arrives at a dirty tree, and the dirt is the run's own deliverable. Run `git status --porcelain -uall` and sort what it reports:

- **Modifications confined to `.kairos/migration-log.md`, possibly plus a modified or first-ever-untracked `.kairos/intent.md`** → the **normal** resume state, not a half-done task. Both `.kairos/intent.md` shapes are by-design: Phase 5 step 1's standing-intent re-confirmation and Phase 8's row-by-row promotions (`promote-intent.sh`) append to it, which shows as a *tracked-modified* file when the component has recorded intent before and as a *first-ever untracked* file when it has not. **Keep it and let it ride the next commit**, exactly as an uninterrupted run would; skip the rest of this section and go straight to the numbered steps. Resetting here destroys a pending entry nothing can regenerate — gate dispositions, user decisions, verifier verdicts — and would discard the confirmed standing intent too: `git checkout -- .` reverts a tracked-modified `intent.md` and `git clean` takes an untracked one (Phase 8's promoted standing intent, confirmed by the user row by row). This is also exactly where Phase 7's recommended checkpoint lands ("finish the current task cleanly, then say `continue` — nothing lost").
- **`.kairos/manifest.yaml` also modified, and `<src>.sha` already equals the block's `target_sha`** → the run died inside Phase 8 step 5, between the advance and the clear. Nothing to reset: take the Phase 8 arm of *Decide* below.
- **Anything else modified or untracked** → genuinely interrupted work; triage it by how far the run had got (arms below).

**Every reset this document offers is path-scoped.** A blanket `git checkout -- . && git clean -fd` is never correct here: it reverts a tracked-modified `.kairos/intent.md`, and it takes the pending log entry and a first-ever untracked `.kairos/intent.md` with the half-done work. Use this form instead — it excludes `.kairos/migration-log.md`, `.kairos/intent.md` and `.kairos/manifest.yaml` from the checkout (the same three `MODE=continue` exempts in pre-flight check 1) and keeps `.kairos/intent.md` out of the clean — and state what it discards before running it:

```bash
git checkout -- . ':(exclude).kairos/migration-log.md' ':(exclude).kairos/intent.md' ':(exclude).kairos/manifest.yaml'
git clean -fd -e .kairos/intent.md    # no -x: the gitignored state dir survives
```

The `.kairos/manifest.yaml` exclusion matters only in the two windows where the manifest is dirty by design — Phase 4's `set` before the scaffolding commit, and Phase 8 step 5's `advance` before the commit that carries it — and those windows take their own arms below (the mid-Phase-4 arm redoes the write; the Phase 8 arm resumes step 5), neither of which runs this reset; carrying the exclusion here keeps the blanket reset from ever reverting a by-design manifest edit if one of those states is reached through this form.

- Dirty, on the migration branch (`<src>.in_progress.branch` from the manifest — `template.in_progress.branch` on a template run, `frontend.in_progress.branch` on a frontend one; when the block has no `branch:` — a `--no-branch` run — the migration lives on `previous_branch`, so being on that branch counts; fallback: a `topic/*/template-update-*` or `topic/*/frontend-update-*` name — and note that a *chained* frontend run continues the template run's branch by default, so the name may say `template-update-` on a frontend run), **no structural commit yet**. First check whether Phase 4's scaffolding commit (`chore: begin migration…`) exists **on this run's own range** — `git log --oneline "$PREV_SHA..HEAD" | grep 'chore: begin migration'` (`PREV_SHA` from `$RUN/context.env`, the in-progress block's `previous_sha` as fallback), never a range-less log: on a **chained frontend run** the branch also carries the *template* leg's own `chore: begin migration` commit below `PREV_SHA`, and a range-less probe would match it and wrongly conclude this run's scaffolding commit landed. If it does NOT exist in that range, the crash was mid-Phase-4 and the dirty manifest edit is the work — do not discard it; redo the `in_progress` write if needed (see the Phase 5 arm below for the call — values from `$RUN/context.env`, never re-derived) and the scaffolding commit. Then, **if `$RUN/test-baseline.failures.txt` is missing, run Phase 4.5 (`phases/4.5-test-baseline.md`) before Phase 5** (the tree is still pre-merge, so the baseline is still valid to capture — and it is uncapturable once Phase 5 merges, after which the postmerge gate has nothing to compare against). If the scaffolding commit exists → died mid-Phase-5; the half-merged tree is disposable: run the path-scoped reset above (the state dir `.kairos/migration/state/` survives — it's gitignored, and `clean` without `-x` spares ignored files), then redo Phase 5 from the script (load `phases/5-structural.md` first).

  **That redo discards every resolver verdict the crashed attempt logged.** `structural-merge.sh` deletes `$RUN/resolutions.tsv` and **every** `resolutions.<slug>.tsv` shard — the `role-switch` and `legacy` ones included — once its refusal checks pass, because a verdict describes a conflict hunk in a tree that no longer exists. That is correct and not recoverable: the ledger is not salvage, the *answers* are. So before redoing, make sure anything the user actually decided during the dead attempt is in `$RUN/qa-ledger.tsv` (via `log-intent.sh`) — that file survives, and it is what lets the re-dispatched resolvers reach the same conclusions without re-asking. If you want the old verdicts for reference, copy the shards somewhere outside `$RUN` first; nothing downstream will read them.
- Dirty, structural commit exists, **every un-skipped `PLAN.md` task already has its `migrate(Txx):` commit**, `<src>.sha` **still `BASE`** (not advanced), and the dirt past `.kairos/migration-log.md` is **staged additions** (`git diff --cached --name-only` lists restored template files, possibly alongside a modified `.kairos/intent.md`) → the run died in **Phase 8, between step 4's parity/intent restores (`git add`) and step 5's commit** — *not* a mid-Phase-7 task. Those staged files are Phase 8 step 4's output and are re-derivable (its step 4 re-copies them from the template tree and re-stages). **Unstage them before step 2** — `git restore --staged <the staged paths>` — because pre-flight check 1 exempts only the three by-design paths and would otherwise refuse the staged index (the path-scoped reset above does not touch the index either, so it is not the tool here). Leave the files in the tree; then take steps 1–5 and the Phase 8 arm of *Decide* (`<src>.sha` still `BASE`), which re-runs Phase 8 from the top — step 4 re-asks the parity dispositions and re-stages, step 5 commits. Without this arm the next bullet mis-reads the staged restores as half-done Phase 7 work.
- Dirty, structural commit exists, **and the dirt reaches past `.kairos/migration-log.md`** (and is not the staged-restore shape just above) → died mid-task in Phase 7. Everything but the log entry is a half-done task: offer the path-scoped reset above and re-run that task, or let the user salvage manually first. The entry itself belongs to the task that already *committed*, so it is kept either way — this arm is why the reset is path-scoped and not blanket.
- Dirty, but NOT on a migration branch → may be genuine user changes. Stop and ask; never clean.

**These triage arms settle the dirt and name where the run will resume — they do not replace the numbered steps below.** An arm that ends "redo Phase 5 from the script", "re-run that task", or "take the Phase 8 arm" is naming a *destination*, not an immediate jump: every one of them still runs steps 1–5 first (anchor re-read, pre-flight `MODE=continue`, `clone-common.sh`, the model pins, and `$SYNTH`), after which the *Decide* step routes to the phase the triage identified. Resuming a phase without them re-enters it on an unre-established anchor — the compaction hazard this whole document exists to close.

Then, on a tree carrying nothing but the by-design writes above (`$RUN` is the fixed path `.kairos/migration/state`; every step below assigns it in its own preamble — an `export` would not survive to the next tool call anyway, SKILL.md → Run-context anchor):

1. **Read `$RUN/context.env` first** (SKILL.md → Run-context anchor). The canonical anchor keys, as last recorded: `BASE`, `TARGET`, `TARGET_REF`, `SYNTH`, `CACHE`, `SKILL_DIR`, `TEMPLATE_PATH`, `COMMON_REPO_PATH`, `COMMON_MODULES`, `COMMON_CACHE`, `TEMPLATE_LOCAL_BRANCH`, `MIGRATION_BRANCH`, `PREV_BRANCH`, `PREV_SHA`, `SQUASH_ON_FINISH`, `STRUCTURAL_SHA`, `RUN_SOURCE`, `FRONTEND_PATH`, `FRONTEND_LOCAL_BRANCH`, `FRONTEND_REPO`, `FRONTEND_SHA`, `FRONTEND_BRANCH`, `FRONTEND_TEMPLATE`, `FRONTEND_MODULE_PATH`, `FRONTEND_MOUNT`, `FRONTEND_CACHE`, `FRONTEND_BOOTSTRAP`, `FRONTEND_INTENT`, `LIB_MODULES`.

   That list is SKILL.md's, restated in full deliberately and held in correspondence by a lint: a resume that reads a shortened list omits values its own later steps consume. Two are consumed only at the very end and exist nowhere else by then — `SQUASH_ON_FINISH` (Phase 8 step 6) and `PREV_SHA` (step 5, after `clear` deletes the block that carries it) — so a resumed run must take both from here; the session that was given `--squash-on-finish` may be long gone. The steps below re-verify and re-record the rest as they run. `SKILL_DIR` is how every phase code block locates the scripts after a compaction.

   **If `$RUN/context.env` is gone entirely** (a swept or never-created state dir), recover the resolution from the *manifest* before running anything else — do **not** fall through to Phase 2 to re-derive it.

   Why not Phase 2: it resolves `TARGET` by `rev-parse`-ing a **ref** (rules 3–5 of its chain resolve a *branch*), and a branch that moved while this migration was in flight re-targets the resume at a commit the structural merge never used — the resume then merges, plans and executes against one tree while Phase 8 advances `<src>.sha` to a SHA nothing in this run ever merged, and the next migration diffs from a baseline the component was never brought to.

   The in-progress block survives a swept `$RUN`, and `in-progress.sh ACTION=set` wrote the target into it as `target_sha`, so the answer is on disk:

   ```bash
   # anchor-exempt: this arm exists FOR the case where the anchor is GONE — the
   # committed manifest is the only surviving record of this run's resolution, and
   # $SKILL_DIR is the one value it can still take from the skill just loaded
   # (reference/abort.md's fallback, same reason).
   RUN=.kairos/migration/state
   SKILL_DIR="<the loaded skill's directory, literally>"
   SRC=template; case "$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml)" in true) SRC=frontend ;; esac
   BASE=$(yq -r ".$SRC.sha // \"\"" .kairos/manifest.yaml)
   TARGET=$(yq -r ".$SRC.in_progress.target_sha // \"\"" .kairos/manifest.yaml)
   : "${BASE:?FAIL: the manifest records no <src>.sha — stop; there is no baseline to merge from}"
   : "${TARGET:?FAIL: the in-progress block records no target_sha — stop; do NOT re-derive the target from a ref}"
   # RUN_SOURCE is re-recorded from the SAME derivation, not left to the resume's memory:
   # `$SRC` above already IS the run's source (which `<source>.in_progress` block is
   # live is the fact that decides it), and every phase after this one — the frontend
   # materialize arm, the gate cwd, Phase 8's advance guard — reads RUN_SOURCE off the
   # anchor. Rebuilding the anchor without it leaves those reads empty on a frontend
   # resume, which is how a frontend run picks up the template arm's behaviour.
   RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" BASE=$BASE TARGET=$TARGET RUN_SOURCE=$SRC SKILL_DIR="$SKILL_DIR"
   ```

   `${VAR:?}` rather than a warning on both, for the reason the commit-count block below gives: an empty `BASE`/`TARGET` makes `$BASE..$TARGET` a plausible-looking range instead of a stop. A block **without** `target_sha` (written before the key existed, hand-edited, or restored from a conflicted merge) is the case to refuse: say the target cannot be recovered, and either take the SHA from the user explicitly or abort the migration and start it again — never re-derive it from a ref, and never guess.

   Only three values are genuinely lost with the anchor, and you ask for each: `TEMPLATE_PATH` (whether the run was launched against a local template — step 2 shows what an empty one does), `SQUASH_ON_FINISH` (or treat as unset), and `FRONTEND_INTENT` — the user's word about `web/` (`frontend-only` / `both` / `template-only` / `unsaid`), which matters only when this resume still has the Phase-8 frontend-consent step ahead of it, and where the user cannot recall it you record `unsaid`, the safe value that degrades to asking rather than silently skipping or forcing the frontend run. Everything else has a source:

   - `CACHE`, `TEMPLATE_LOCAL_BRANCH` — step 2's pre-flight call.
   - `COMMON_REPO_PATH`, `COMMON_MODULES`, `COMMON_CACHE` — step 2's `clone-common.sh` call, placed there precisely because nothing downstream re-derives them and their absence is silent rather than loud (step 2 states the mechanism).
   - `PREV_BRANCH`, `PREV_SHA` — the block's `previous_branch`/`previous_sha` (step 5's fallback).
   - `RUN_SOURCE` — which `<source>.in_progress` block is live. The lost-anchor block above derives it as `$SRC` and re-records it in the same call; a **present** anchor that merely lacks the key (a run recorded before `RUN_SOURCE` existed) is read empty by step 2 and pre-flight falls back to its `template` default — which is correct for exactly those legacy anchors, since they predate frontend runs, so no frontend resume is misrouted through the template arm by this gap. Either way it is **not** on the genuinely-lost list.
   - `STRUCTURAL_SHA` — the branch's own history (next paragraph); it is **not** in the lost list.

   **A `STRUCTURAL_SHA` the anchor *does* carry is verified, not trusted.** Phase 5's step 9 amend arms rewrite the structural commit and re-record the key in a **separate** tool call — a session that dies between the two leaves the anchor naming the replaced commit: still a resolvable object, so nothing downstream errors; no longer in the branch's history, so every downstream read silently answers about the wrong tree (Phase 5 step 9 states the exposure; Phase 7's hard guard stops an *empty* value, not a stale one). One call tells the two apart — run it on every resume whose anchor carries the key:

   ```bash
   RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
   # Bare form, not `ctx`: STRUCTURAL_SHA is legitimately absent on any resume that
   # died before Phase 5's commit landed — absence routes through the Decide arms
   # below, not to a failure report. Only a PRESENT value is checked here.
   STRUCTURAL_SHA=$(sed -n 's/^STRUCTURAL_SHA=//p' "$RUN/context.env")
   if [ -n "$STRUCTURAL_SHA" ] && ! git merge-base --is-ancestor "$STRUCTURAL_SHA" HEAD 2>/dev/null; then
     echo "STALE: STRUCTURAL_SHA $STRUCTURAL_SHA is not an ancestor of HEAD — an amend replaced the structural commit before the re-record landed" >&2
   fi
   ```

   A `STALE:` line means treat the value exactly as if it were absent: recover the real SHA from the commit subject (next paragraph) and re-record it before resuming any phase that reads it.

   **`STRUCTURAL_SHA` — absent or stale, recover it from the commit subject; never leave it empty and never keep a stale one.** Phase 7's bent-test trigger hard-guards its read, so an absent value stops that phase rather than diffing a test file against itself; a resume that shrugs at the absence just meets the stop later. The structural commit carries a **fixed subject** — `chore: structural merge to <target7>`, written by `phases/5-structural.md` step 8 and preserved by `git commit --amend` — so it is locatable on the migration branch:

   ```bash
   RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
   # Bare form, not `ctx`: this arm exists BECAUSE the anchor was swept, so PREV_SHA is
   # normally absent here and the in-progress block's `previous_sha` is the source (the
   # same fallback step 5 takes). A missing key is expected, not a failure to report.
   PREV_SHA=$(sed -n 's/^PREV_SHA=//p' "$RUN/context.env")
   SRC=template; case "$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml)" in true) SRC=frontend ;; esac
   [ -n "$PREV_SHA" ] || PREV_SHA=$(yq -r ".$SRC.in_progress.previous_sha // \"\"" .kairos/manifest.yaml)
   : "${PREV_SHA:?FAIL: no previous_sha in the anchor or the in-progress block — stop; ask the user for the migration's start SHA rather than scanning the whole history for a subject match}"
   git log --format='%H %s' "$PREV_SHA..HEAD" | grep 'chore: structural merge'
   ```

   Exactly one match, on a history nobody rewrote → re-record it and carry on:

   ```bash
   RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
   SKILL_DIR=$(ctx SKILL_DIR)
   STRUCTURAL_SHA="<the SHA of the single structural-merge commit printed above>"
   RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" STRUCTURAL_SHA="$STRUCTURAL_SHA"
   ```

   **Confirm with the user before recording whenever the history was amended or rebased, or the match count is not exactly one.** Step 9 of Phase 5 amends the structural commit on two sanctioned paths, and a rebase or hand-rewritten history can carry that subject on a commit whose tree the resolvers never saw — so show the candidate line(s) and let the user name the structural commit rather than taking the newest match. Zero matches means the structural commit never landed: record nothing, and let the *Decide* step below route the resume to Phase 5.
2. Run pre-flight with `MODE=continue` (load `phases/1-preflight.md` first — it is the phase), **but pass its inputs from the anchor, not from shell state.** That phase's own block is written for a fresh run's *first* tool call: it is `anchor-exempt` because it establishes the anchor, and it hands `TEMPLATE_PATH="$TEMPLATE_PATH"` and `"$SKILL_DIR/scripts/..."` straight out of the live shell that just parsed the invocation. A resumed session has neither. Run this block instead — same script, same phase key, both inputs re-read from `$RUN/context.env`:

   ```bash
   RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
   SKILL_DIR=$(ctx SKILL_DIR)
   # Bare form, not `ctx`: a run given no --template-path legitimately has NO
   # TEMPLATE_PATH key, and `ctx` would report that absence as a failure.
   TEMPLATE_PATH=$(sed -n 's/^TEMPLATE_PATH=//p' "$RUN/context.env")
   # Same bare form, same reason: a run given no --frontend-path has no FRONTEND_PATH
   # key, and an empty value here is exactly what "no local frontend checkout" means.
   FRONTEND_PATH=$(sed -n 's/^FRONTEND_PATH=//p' "$RUN/context.env")
   # Same bare form again: a run recorded before RUN_SOURCE existed on the anchor has no
   # key, and empty is what pre-flight reads as `template` — its own default, under which
   # check 0b RUNS the Kairos CLI probe. It is `RUN_SOURCE=frontend` that makes check 0b
   # report the probe not-applicable and skip it (the frontend arm invokes no CLI; the
   # full rule is a few paragraphs down). A frontend run always recorded the key, so this
   # bare read is empty only on a legacy template-run anchor, where `template` is right.
   RUN_SOURCE=$(sed -n 's/^RUN_SOURCE=//p' "$RUN/context.env")
   PHASE_KEY="<from phases/1-preflight.md>" MODE=continue RUN_SOURCE="$RUN_SOURCE" \
     TEMPLATE_PATH="$TEMPLATE_PATH" \
     FRONTEND_PATH="$FRONTEND_PATH" "$SKILL_DIR/scripts/pre-flight.sh"
   ```

   **Pre-flight's check 1 (clean working tree) exempts `.kairos/migration-log.md`, `.kairos/intent.md` and `.kairos/manifest.yaml` under `MODE=continue`**, so the by-design pending log entry never trips it, and neither do the two manifest-dirty resume windows (Phase 4's `set` before the scaffolding commit, Phase 8 step 5's `advance` before its commit) — without the manifest exemption those windows would be unreachable, since this pre-flight runs before their arms and this document forbids committing or stashing past it. A refusal here therefore means what it says — "working tree is dirty **beyond** …" — dirt past the three exempt paths: genuinely interrupted work the dirty-tree triage at the top of this file should have sorted, or edits that appeared after it ran. Go back and take the triage arm that matches the dirt's shape; never `commit or stash` blindly to get past the check, and never reset the exempt paths themselves — the pending entry, a first-ever `intent.md`, and a by-design manifest edit are the run's own deliverables.

   An empty `TEMPLATE_PATH` is **not** a harmless default here. Pre-flight then resolves the clone origin from the manifest's `template.repo` instead, finds the surviving `$RUN/template` mirror's `remote.origin.url` (the local path) disagreeing, and its `reclone()` `rm -rf`s that mirror and re-clones from the remote — so the resume quietly migrates against upstream content instead of the local template the run was launched with, while the anchor's own `TEMPLATE_PATH=` line survives unchanged (pre-flight only upserts keys it was given) and Phase 3.5's wrong-target tripwire keeps reading that stale line. Pre-flight re-records `CACHE`, `SKILL_DIR`, `TEMPLATE_PATH` and `TEMPLATE_LOCAL_BRANCH` on the way out, so the steps below read them from the anchor as usual.

   **On a frontend resume, `FRONTEND_PATH` is the same hazard with the same shape** — pass it back exactly as `TEMPLATE_PATH`, from the anchor's `FRONTEND_PATH=` line (pre-flight re-normalizes and re-records it, along with `FRONTEND_LOCAL_BRANCH` and the `frontend:` block's fields). Dropping it points the resume at the upstream frontend repo instead of the author's local checkout, which is the whole reason the flag exists.

   **Then re-run `clone-common.sh` in this same step — pre-flight does not record the common keys, and nothing later re-establishes them.** `COMMON_REPO_PATH`, `COMMON_MODULES` and `COMMON_CACHE` are written by a *separate* Phase 1 block (`phases/1-preflight.md`), so a resume that re-runs only pre-flight leaves all three absent — and every consumer reads that absence as a settled answer rather than a gap: Phase 3.5's re-run gate in *Decide* below fires only on `COMMON_MODULES=present`, and `plan-completeness.sh` enforces the common upgrade list only when that key equals `present`. So the entire common-library upgrade set drops out of the migration without one refusal anywhere. Run it on every resume, not just a swept-anchor one — it takes nothing from conversation state, refreshes the surviving `$RUN/common` mirror in place rather than re-cloning, and records the three keys itself:

   ```bash
   RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
   SKILL_DIR=$(ctx SKILL_DIR)
   RUN=$RUN "$SKILL_DIR/scripts/clone-common.sh"   # re-records COMMON_REPO_PATH / COMMON_MODULES / COMMON_CACHE
   ```

   Relay any `WARN:` line it printed, and read the three keys off the anchor from here on (Phase 3.5 does exactly that) — never out of this block's shell. (The frontend library upgrade set is re-established later, after `$SYNTH` — its `build-manifest.sh` classifies against `$SYNTH`, so it cannot run here.)
3. `git branch --show-current` — it **must** equal `<src>.in_progress.branch` from the manifest (authoritative). Under `--no-branch` (block with no `branch:`) compare against the block's `previous_branch` instead; pattern fallback: `topic/*/template-update-*` or `topic/*/frontend-update-*` (a chained frontend run keeps the template run's branch, so the pattern is a fallback, not an identity). **If it does not match, STOP — do not resume from the wrong branch even on a clean tree.** The migration lives on the manifest's branch; a resume issued from any other branch sails through the dirty-tree triage (the tree *is* clean) and then miscounts: step 5 counts task commits against the wrong ref, the structural commit and every task commit land on the branch you happen to be standing on, and a later abort deletes the real migration branch — the one place the merge actually is. Check out the recorded branch (`git checkout <the block's branch>`) and re-run continue; if that branch is gone, or the user meant a different one, confirm with the user which branch carries the migration before going any further. This is the clean-tree counterpart of the dirty "NOT on a migration branch → stop and ask" arm above.
4. `git cat-file -e HEAD:.kairos/migration/PLAN.md 2>/dev/null` — is the plan **committed**? Phase 6 commits the plan on approval, so a committed plan means planning is done for a plain resume (a continue entered to *change* the plan re-opens it — the plan-revision arm in *Decide* below). An *untracked* `.kairos/migration/PLAN.md` is a partial from an interrupted, unapproved planning session — not a resumable plan; discard it (`rm -f .kairos/migration/PLAN.md`) and re-plan.
5. Count the task commits **against the recorded pre-migration SHA**, never against a branch ref:

   ```bash
   RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
   PREV_SHA=$(ctx PREV_SHA)
   # `ctx` REPORTS a missing key, it does not stop the block (it exits 0, so the
   # assignment above succeeds with an empty value even under set -e). Here that
   # matters: `git log --oneline ..HEAD` is a VALID range that lists the whole
   # history, and an empty one counts zero task commits — the resume then re-enters
   # Phase 5 and redoes the structural merge over a tree that already carries it.
   # `${VAR:?}` aborts a non-interactive shell on the spot, before the git call.
   : "${PREV_SHA:?FAIL: PREV_SHA missing from the run-context anchor — stop; do not count commits against an empty range}"
   git log --oneline $PREV_SHA..HEAD
   ```

   Count only the `migrate(Txx):` commits; the scaffolding (`chore: begin…`), structural (`chore: structural merge…`), and plan (`chore: migration plan…`) commits are not tasks — but note whether the structural one is there, because step "Decide" below turns on it.

   **The SHA is load-bearing under `--no-branch`.** There the migration commits land on the user's own branch, so `previous_branch` *is* the checked-out branch and its ref moved with every one of them: `$PREV_BRANCH..HEAD` is an empty range, and the whole run goes invisible at once — zero tasks, no plan commit, no structural commit. The resume then re-enters Phase 5 and redoes the structural merge on top of a tree that already carries the merge and K task commits. A SHA cannot move, which is why abort resets to `previous_sha` and Phase 8 squashes to it as well. If the anchor has no `PREV_SHA` (a run recorded before it existed), fall back to the in-progress block's `previous_sha` for the source being resumed (`yq -r ".$SRC.in_progress.previous_sha // \"\"" .kairos/manifest.yaml`), and if that is empty too, say so and infer the phase from the commit *subjects* on the branch rather than from a count.

**Re-read the pinned models, don't re-derive them.** `$RUN/model.txt` holds the `<STRONG_MODEL>`, `<CODER_MODEL>`, and `<EXECUTOR_MODEL>` this migration resolved (`strong=<slug>` / `coder=<slug>` / `executor=<slug>`; SKILL.md → Model selection); reading it is what stops a resumed session from switching models mid-plan. Older formats degrade gracefully, and **the honoring mechanism is explicit overrides, not a plain re-run.** `resolve-models.sh` resolves all three tiers on every invocation, so re-running it to fill one missing pin re-derives the surviving ones too — the mid-plan switch this whole step exists to prevent. Feed the survivors back in as the script's own overrides, which beat every derivation (load `phases/1.5-model-resolution.md`; the script is keyed). **Pass `OFFERED` on every one of these re-runs** — the offered-model list copied verbatim from your tool surface, exactly as Phase 1.5 §1 requires — because `resolve-models.sh` refuses (exit 1) when `OFFERED` is unset and stdin is not a terminal, whichever tiers you override:

- A keyed file without a `coder=` line — one pinned before that tier existed — keeps its pins by re-running with `STRONG_MODEL=<strong>` and `EXECUTOR_MODEL=<executor>` from the file; `<CODER_MODEL>` is then the only tier derived.
- A single-line file is just the `<EXECUTOR_MODEL>`: re-run with `EXECUTOR_MODEL=<that slug>` and let the other two derive.
- A keyed file **without a `budget=` line** — one pinned before postures existed — degrades to `balanced` (the default posture; SKILL.md → Model selection), never a stricter one, so Continue mode cannot silently switch posture mid-plan. Pass `BUDGET=` explicitly — the surviving posture when the line is there, `balanced` when it is not — rather than leaning on the default.
- Every file the current script writes carries all four lines, so pass all three pins straight back. Under `frugal` the `coder=` line is either the collapse product (the executor slug) or a user's explicit `--coder-model`/`KAIROS_UPDATE_CODER_MODEL` pin (`phases/1.5-model-resolution.md` §3 distinguishes the two, because a *mid-run correction* to a different tier has to decide whether coder follows it) — but a plain resume corrects no tier, so that distinction is moot here: whichever it is, it is the coder pin this run already carries, and passing it straight back as `CODER_MODEL` reproduces exactly that value rather than inventing one. That is why the caution in `phases/1.5-model-resolution.md` about not inventing a `CODER_MODEL` under `frugal` does not apply to a pin read off the file.

If the file is missing entirely — a state dir that predates the pin, or a swept one — there is nothing to honor: derive all three again and surface the values as a fresh run does, rather than asking. Do not resume into a dispatching phase without it: `log-spawn.sh` refuses every dispatch while `model.txt` is absent.

**Re-establish `$SYNTH` before any phase that merges or classifies — through the arm this run's source belongs to.** Phases 3 and 5 read the materialized trees, and a resumed session has none in its shell state. Re-run Phase 2.5 (load `phases/2.5-materialize.md` first) and re-export `SYNTH`. **Which builder is not a detail:** a template run re-runs `materialize.sh` (`kairos component create`, both sides); a **frontend** run (`RUN_SOURCE=frontend` on the anchor, or `$SRC` from the live block) re-runs `phases/2.5-materialize.md`'s *Frontend run* arm — `materialize-frontend.sh`, module subtree onto the mount, **no Kairos CLI** — and its stamp carries the source, so it can never be served the template run's synthetic repo from a chained run. Running the template arm on a frontend resume would rebuild `$SYNTH` from the component template and hand Phase 3 and Phase 5 the wrong two trees entirely. Either arm stamps its inputs, so an unchanged run reuses the existing trees instead of paying the build again, and a swept or corrupt `$RUN/synthetic` simply rebuilds. Pre-flight's CLI probe (check 0b) sits ahead of the mode gate, so on a **template** resume it runs in continue mode too: a CLI that has gone **missing, dropped below the minimum version, or lost `--no-tidy`/`--no-frontend`** since the run started stops the resume at step 2 rather than mid-`kairos component create`. It does not detect a version *change* that still clears the bar — nothing records which CLI built the existing trees, so an upgraded-but-supported CLI passes silently and any output difference arrives with the rebuilt trees. On a **frontend** resume that probe is reported not applicable and skipped (pass `RUN_SOURCE` through, as step 2's block does): the frontend arm invokes no CLI, so a CLI that went missing mid-run is not a reason to refuse the resume.

**Then, on a frontend resume (`RUN_SOURCE=frontend` on the anchor), re-establish the frontend library upgrade set UNCONDITIONALLY — the same defense `clone-common.sh` applies to common in step 2.** `LIB_MODULES` and the lib upgrade lists are written only by `collect-lib.sh` on the Phase 3 frontend arm. **Do not gate this on `LIB_MODULES` being absent:** absence is not the only failure mode — an interruption mid-collection can leave the key `present` while the lists are empty or partial, and every consumer reads a present-but-empty state as *settled: none* (`plan-completeness.sh` enforces the lib list only when the key equals `present`), dropping the whole library-module upgrade set with no refusal anywhere. Re-running is cheap and idempotent — it collects over the frontend mirror and truncates its own lists first, exactly as a Phase 3 redo does, and `collect-lib.sh` now records `LIB_MODULES=present` only after the walk succeeds — so run it on every frontend resume, not just a key-absent one. It re-runs `build-manifest.sh` **and** `collect-lib.sh` as one unit (phases/3-classify.md), and it must run **here, after the `$SYNTH` re-establishment above**, because `build-manifest.sh` classifies against `$SYNTH` and a swept tree would otherwise fail it:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); SYNTH=$(ctx SYNTH); BASE=$(ctx BASE); TARGET=$(ctx TARGET)
RUN_SOURCE=$(ctx RUN_SOURCE)
FRONTEND_TEMPLATE=$(sed -n 's/^FRONTEND_TEMPLATE=//p' "$RUN/context.env")
FRONTEND_CACHE=$(sed -n 's/^FRONTEND_CACHE=//p' "$RUN/context.env")
if [ "$RUN_SOURCE" = frontend ]; then
  CACHE=$FRONTEND_CACHE
  : "${CACHE:?FAIL: FRONTEND_CACHE missing from the anchor}"
  export SYNTH CACHE BASE TARGET RUN
  MODULE=$FRONTEND_TEMPLATE PHASE_KEY="<from phases/3-classify.md>" "$SKILL_DIR/scripts/build-manifest.sh"
  PHASE_KEY="<from phases/3-classify.md>" "$SKILL_DIR/scripts/collect-lib.sh"
fi
```

Decide:

- No structural commit → resume at Phase 5 (`phases/5-structural.md`). **Never re-run Phase 4 on a continue**: the `in_progress` block's existence means Phase 4 already ran (continue mode requires the block), and re-running it would recapture `previous_sha` from a mid-migration HEAD — destroying abort's only rollback point. If Phase 4's scaffolding commit is missing (crashed between the manifest write and the commit), redo **only** the `in_progress` write and the scaffolding commit. Load `phases/4-migration-branch.md` for its in-progress step — the writer script is guarded on that phase's key — and run it with values read from `$RUN/context.env`, never re-derived:

  ```bash
  RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
  SKILL_DIR=$(ctx SKILL_DIR); TARGET=$(ctx TARGET); RUN_SOURCE=$(ctx RUN_SOURCE)
  PREV_BRANCH=$(ctx PREV_BRANCH); PREV_SHA=$(ctx PREV_SHA)
  MIGRATION_BRANCH=$(sed -n 's/^MIGRATION_BRANCH=//p' "$RUN/context.env")   # empty under --no-branch
  SOURCE=$RUN_SOURCE ACTION=set PHASE_KEY="<from phases/4-migration-branch.md>" \
    TARGET_SHA=$TARGET BRANCH=$MIGRATION_BRANCH PREV_BRANCH=$PREV_BRANCH PREV_SHA=$PREV_SHA \
    "$SKILL_DIR/scripts/in-progress.sh"
  ```

  `SOURCE` comes off the anchor, exactly as Phase 4's own call passes it (`SOURCE=$RUN_SOURCE ACTION=set …`): without it `in-progress.sh` defaults to `template`, and on a frontend resume its mutual-exclusion check then refuses against the live `frontend.in_progress` block — a refusal whose message misdirects toward aborting the very run being resumed.

  `PREV_BRANCH`/`PREV_SHA` were recorded in `context.env` when Phase 4 first ran, so nothing comes from a mid-migration HEAD; a `--no-branch` run has an empty `MIGRATION_BRANCH` and the script omits the `branch:` key, which is the shape that run started with. Overwriting a half-written block with a complete one is a supported call. Do **not** re-run the rest of Phase 4 — `git checkout -b` and the `PREV_SHA` capture must not happen twice. If `$RUN/test-baseline.failures.txt` is missing, run Phase 4.5 (`phases/4.5-test-baseline.md`) first (the tree is still pre-merge, so the baseline is still valid to capture).
- Structural commit landed, no committed plan → resume at Phase 6 (`phases/6-planning.md`; discard any untracked partial `PLAN.md` first). **But first, read the postmerge gate's disposition off its card — not merely its presence.** `gate.sh` writes `gate-postmerge.tsv` on *every* completed run and its last line is `AGGREGATE<TAB>PASS|FAIL|NEEDS-INPUT` (a gate killed mid-run leaves no card at all — it is removed up front). Two states send you back into **Phase 5's step 9** instead of Phase 6, because its `ask-user` coverage compare and its `replace`-directive decision run at `LABEL=postmerge` only and never recur at midplan or final: **(a) the card is absent** — the run crashed between the structural commit and the gate, so the gate never ran; **(b) the card is present but its `AGGREGATE` is not `PASS`** — the gate ran and returned FAIL / NEEDS-INPUT, and the disposition conversation (surface the FAIL rows, keep-or-drop the `replace` directives) is exactly the kind of "stop and ask" a kill or compaction interrupts. A resume cannot tell an *interrupted* non-PASS disposition from one the user already accepted, so re-surface the card's non-PASS rows and re-disposition them with the user (step 9's own handling) rather than assuming they were settled — re-confirming an already-accepted finding is a cheap re-ask; skipping an un-settled one loses that check for good. Only when the card is present **with `AGGREGATE PASS`** (or its non-PASS rows have just been re-dispositioned) is the postmerge gate satisfied. Once it is, **check `$RUN/upgrades-added.txt`: if it is absent, re-run Phase 3 (and Phase 3.5 when the anchor records `COMMON_MODULES=present`; on a frontend run Phase 3 is `build-manifest.sh` and `collect-lib.sh` as one unit) before planning** — that list is Phase 3's output and a swept state dir loses it, while the plan's completeness gate has no inputs to gate against. `plan-completeness.sh` exits 2 rather than passing over the absence, so a resume that skips this arrives at a refusal instead of a vacuous green; re-running classification is cheap and idempotent (Phase 2.5 is stamped). A frontend resume whose `LIB_MODULES` key is absent is the same missing-input shape even when `upgrades-added.txt` is present — the frontend library re-establishment block above (after `$SYNTH`) already re-ran it unconditionally, so it is settled before planning. If `$RUN/test-baseline.failures.txt` is missing, the pre-merge baseline can no longer be captured — note this and treat the post-merge test run as the baseline (degraded: merge-induced regressions can't be distinguished from pre-existing ones).
- Plan committed, at least one task commit, and the plan itself is not in question → resume at Phase 7 (`phases/7-execution.md`) at **the first plan task that has neither a `migrate(Txx):` commit nor a documented, user-approved skip** — match by task ID against `PLAN.md`, *not* by commit count. **The skip set lives in `.kairos/migration-log.md`** — Phase 7 writes a skip entry there when the user approves skipping a task (`phases/7-execution.md`, the "skip this task (and document it)" outcome), so read that file to tell a *skipped* task (leave it skipped) from an *undone* one (resume here). A task with no `migrate(Txx):` commit **and** no skip entry in the log is undone. Task count + 1 is wrong whenever a task was skipped: the skip leaves the row in the plan with no commit (Phase 8 accepts it that way — `phases/8-finalize.md` step, "or a documented, user-approved skip"), so `count < ordinal-of-next-undone-task` and a count-based resume lands on an already-committed task and re-runs it (a duplicate `migrate()` commit, or an executor failure because the change is already present). This is the same "first un-committed task" rule the plan-revision arm below uses.
- **Plan committed, but the plan needs changes** — the orchestrator stopped cleanly for a plan change (SKILL.md's NEVER list forbids patching an approved `PLAN.md` in place and names this continue as the sanctioned path), or the user's continue request says so (a verifier finding needs a fix task; a task must be added, split, or dropped) → re-enter Phase 6 (`phases/6-planning.md`) as a **plan revision**: adopt the planner role and revise `PLAN.md`, keeping completed tasks' rows **verbatim** — their `migrate(Txx):` commits are already history, and the plan must keep describing what those commits did — with changes applied only from the first un-committed task onward. Re-clear both completeness gates, get the user's approval, and commit the revised plan as its own commit (`chore: migration plan for <target7> (revised)`). The revision is sanctioned *because* it re-enters through the gates and approval — that is the entire difference from the in-place edit the NEVER list forbids. Then resume Phase 7 at the first un-committed task of the revised plan.
- All tasks committed, baseline not advanced (`<src>.sha` still BASE) → resume at Phase 8 (`phases/8-finalize.md`). **If a partial Phase 8 already ran, its finalize summary and Template feedback may already be in `.kairos/migration-log.md`** — step 2 writes them before any commit, so a crash between step 2 and step 5's commit leaves them uncommitted in the tree. Re-running Phase 8 from the top must not append a second copy: Phase 8 step 2 is check-first for exactly this resume (the post-advance Phase 8 arm below carries the same "write them now if absent" rule). Everything else Phase 8 re-runs — the final gate, the spawn fold-in, the intent/parity promotions — is idempotent.
- All tasks committed and **`<src>.sha` already equals the block's `target_sha`**, block still present → the run died inside Phase 8 step 5, in the window between the `advance` and the `clear` (step 5 advances first precisely so this window is resumable — `phases/8-finalize.md` step 5). Do **not** re-run Phase 8 from step 1: the gate, the summary and the promotion already ran. Finish step 5 instead — check that the finalize summary and its Template feedback section really landed in `.kairos/migration-log.md` (step 2 writes them before any commit; write them now if they are absent):

  ```bash
  # Both reads come from the committed manifest, not the anchor: the anchor records
  # what this run was AIMING at, and the question here is what actually landed.
  SRC=template; case "$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml)" in true) SRC=frontend ;; esac
  yq -r ".$SRC.sha // \"\"" .kairos/manifest.yaml
  yq -r ".$SRC.in_progress.target_sha // \"\"" .kairos/manifest.yaml
  ```

  **Then run step 5's `PREV_SHA` re-anchor block, before the `clear` — never after it.** Phase 8 states that re-anchor "is what makes step 6's squash possible at all" (`phases/8-finalize.md` step 5), and a resume is the one path that can skip it: `clear` deletes the in-progress block `previous_sha` lives in, step 6 runs in a later shell, and step 6's hard guard then refuses the squash outright — irrecoverably, because the value was readable in the manifest one tool call earlier and nowhere afterwards. Restated here so this arm is runnable as written:

  ```bash
  RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
  SKILL_DIR=$(ctx SKILL_DIR)
  # if-form, not `&&`: a legitimately empty PREV_SHA (a block recorded before Phase 4
  # anchored it) must not exit this block 1 — that reads as a failed step, not a no-op.
  SRC=template; case "$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml)" in true) SRC=frontend ;; esac
  PREV_SHA=$(yq -r ".$SRC.in_progress.previous_sha // \"\"" .kairos/manifest.yaml)
  if [ -n "$PREV_SHA" ]; then
    RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" PREV_SHA=$PREV_SHA
  fi
  ```

  Only then run the `clear` and step 5's commit, and then step 6's optional squash.

  (A death *after* the clear+commit but *before* step 6's squash leaves no block, so this arm — and Continue mode itself — cannot be entered; `phases/8-finalize.md` step 6 documents the by-hand recovery, which must run before a fresh run sweeps the anchor.)

Tell the user what you inferred and what you're about to do before proceeding.
