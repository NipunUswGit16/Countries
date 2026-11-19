# Abort

Entered when the user says abort / cancel / undo / get me back.

**Abort undoes THIS run, and only this run.** A skill invocation may chain two runs — a `template` run and then a `frontend` run (SKILL.md → Phase index) — and each has its own in-progress block, its own `previous_branch`/`previous_sha`, and its own baseline. The block that exists names the source being aborted; resolve it first and use it everywhere below:

```bash
SRC=template; case "$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml)" in true) SRC=frontend ;; esac
echo "aborting the $SRC run"
```

At most one block exists (pre-flight refuses a manifest carrying both), so there is nothing to choose between. If a damaged manifest — a hand edit, a conflicted merge restore — carries both anyway, abort still acts on **one source per pass**: the `case` line resolves to `frontend`, so clear or roll back that run first, then run this document once more for the surviving `template.in_progress` block (pre-flight keeps refusing fresh runs until both are gone). And there is something to be explicit about: **aborting a frontend run that was chained after a finished template run keeps the advanced `template.sha`.** That template run passed its own final gate and advanced its own baseline; it is history, not part of what this abort is undoing. Roll back to `<src>.in_progress.previous_sha` — the *frontend* run's start — and say out loud that the template baseline stays where the template run left it. The same holds mirrored: aborting a template run never touches `frontend.sha`. Below, `<src>` means the resolved source, and a template abort therefore does exactly what this document always did.

**Salvage standing intent first — before anything below runs.** The cleanup deletes `$RUN/qa-ledger.tsv`, so its rows must be promoted first — on **every** arm below, no exception (including the ones with no branch and no block). If the ledger (`RUN=.kairos/migration/state`) has rows, run Phase 8's promotion step now (`phases/8-finalize.md` → Promote standing intent): propose the rows that encode standing component facts as one batched, per-row-confirmed question, and append each confirmed row to `.kairos/intent.md` with `promote-intent.sh`. Never hand-edit that file — the script is its format owner (keyless so this document can call it, idempotent so a later re-promote of the same fact is a no-op).

**Where the append goes, by arm** — the only thing that varies:

- **Roll-back arm** — append **between the checkout and the scratch sweep**: after the checkout so the entries land on the restored branch, and before the sweep because the sweep deletes both `$RUN/qa-ledger.tsv` (the rows this step reads) and `$RUN/context.env` (the anchor that locates the script). Under `--no-branch` — and on a chained frontend run, whose rollback is the same reset — the append comes **after the reset** too — `git reset --hard` restores tracked files to `previous_sha`, so an `.kairos/intent.md` append (or a commit of it) made before the reset is discarded with the migration commits; the ledger itself survives the reset, because `$RUN` is untracked and only the sweep deletes it. That arm is deliberately written below as separate blocks rather than one for this reason — run as one block, the salvage finds an empty `SKILL_DIR` and a deleted ledger.
- **Either arm with no checkout** (a partial block, or no block at all) — append in place, right now.

There is no arm on which the salvage is skipped, and the arm most likely to carry a full ledger is the one with no block: an abort *before* Phase 4 has run is an abort during the phases that do all the asking (Phase 3.5's unresolvable modules, Phase 5's binaries and heavyweight subtrees). The ledger it leaves is **not** swept unremarked by the next fresh run any more — pre-flight refuses to sweep a `$RUN` carrying an unpromoted `qa-ledger.tsv` with no `previous_sha` anchored (the pre-Phase-4 window; `reference/pre-flight.md` check 6). So the no-block and clear arms below **sweep their own `$RUN` after salvaging**, which keeps `qa-ledger` presence a reliable "a run pre-flight never cleaned" signal instead of a refusal the next user has to clear by hand.

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# if-form, not `[GUARD="<test>"]` and not two alternative command lines: see below.
# Run this block once per confirmed row.
ENTRY="<the confirmed fact>"
GUARD="<the in-grammar tree assertion, or empty when the row has none>"
if [ -n "$GUARD" ]; then
  ENTRY="$ENTRY" GUARD="$GUARD" "$SKILL_DIR/scripts/promote-intent.sh"
else
  ENTRY="$ENTRY" "$SKILL_DIR/scripts/promote-intent.sh"
fi
```

**One spelling with a branch, not two lines and not an optional bracket** (`phases/8-finalize.md` → the `BRANCH=` if-form, same rule, mirrored here). `[GUARD="<test>"]` is not bash — the shell reads it as a command name, so the call fails with rc=127 and never writes the entry. Two *alternative* command lines fail the other way: a verbatim paste runs **both**, so a guarded row appends correctly and then the second call refuses with `FAIL: … already carries this fact with a different guard … use ACTION=update`, whose named remedy invites de-guarding the entry that was just written correctly — a spurious rc=2 on the one path where the ledger is about to be deleted and nothing can be re-derived. `GUARD=""` is **not** a hazard, and the `if` is not there to avoid it: the script collapses and trims every field, so an empty or whitespace-only `GUARD` is exactly equivalent to omitting it. The `if` exists so only one of the two arms ever runs. Whatever you do pass must fit the closed guard grammar `scripts/intent-check.sh` owns (`reference/intent-guard.md → The closed guard grammar`), and never shell. Nothing validates it here: an out-of-grammar guard is written as given and refused at the **next** run's vetting, which reports the entry `UNPARSEABLE` and excludes it from every resolver's input until someone re-confirms it. So propose no guard at all rather than one outside the grammar (guardless entries fall back to the resolver-side contradiction rule).

Without this, an abort discards every answer the user gave this run and the next run re-asks all of them; one-off choices are still discarded by design.

**Then offer to commit that edit, and say why — as the arm's LAST step, never before the arm below has finished.** Two steps below are why the offer cannot come earlier: the `--no-branch` reset restores tracked files to `previous_sha`, so a salvage commit made before it is discarded along with the migration commits it undoes; and the no-block arm's commit-count probe tells the mid-Phase-4 window apart from a finished migration by *zero commits since `PREV_SHA`* — a salvage commit made first turns that count to 1 and misreads the window as history. Offer `git add .kairos/intent.md && git commit -m "chore: record standing migration intent"`.

Which consequence you state depends on whether the file was already tracked, and only one of the two blocks a run. **Already tracked** (the usual case — a component that has recorded intent before): the append is an unstaged modification, so pre-flight check 1 refuses the user's next fresh run with "working tree is dirty. Commit or stash before migrating." Left unsaid, that arrives as a surprise blocking a run the user thinks is unrelated — so if the user declines, say plainly that the next migration will stop until the edit is committed or stashed. **A first-ever `.kairos/intent.md`** is *untracked*, and check 1 is a `git diff --quiet` / `git diff --cached --quiet` pair, which sees neither untracked files nor untracked directories: it does **not** refuse that run. Do not warn about a block that will not happen — the reason to commit there is that the fact is worthless uncommitted, since standing intent is read cross-run from the committed file.

Read the in-progress block from `.kairos/manifest.yaml`:

```bash
# anchor-exempt: the manifest is abort's authority, not the run-context anchor —
# a rollback point must come from the committed file, which survives a swept $RUN.
SRC=template; case "$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml)" in true) SRC=frontend ;; esac
PREV=$(yq -r ".$SRC.in_progress.previous_branch // \"\"" .kairos/manifest.yaml)
BRANCH=$(yq -r ".$SRC.in_progress.branch // \"\"" .kairos/manifest.yaml)
PREV_SHA=$(yq -r ".$SRC.in_progress.previous_sha // \"\"" .kairos/manifest.yaml)
```

`previous_branch` decides which arm runs. **No block at all** → run the salvage above (in place — no checkout happens on this arm), then check for the one state this arm's premise misses before exiting: Phase 4 creates the migration branch and anchors it **two to three tool calls before** it writes the block, so an abort landing in that window — or a fresh-session abort after a crash there — has a branch (and possibly a staged `.gitignore` edit) that no block records. The anchor is the record that exists by then — `MIGRATION_BRANCH`, `PREV_BRANCH` and `PREV_SHA` are written in the same tool call as the `checkout -b`, so they are present whenever the branch is:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
# Bare reads throughout: this arm exists BECAUSE the state is partial — an absent
# key is the answer "Phase 4 never got that far", not a failure to report.
MIGRATION_BRANCH=$(sed -n 's/^MIGRATION_BRANCH=//p' "$RUN/context.env")
PREV_BRANCH=$(sed -n 's/^PREV_BRANCH=//p' "$RUN/context.env")
PREV_SHA=$(sed -n 's/^PREV_SHA=//p' "$RUN/context.env")
CURRENT=$(git branch --show-current)
if [ -n "$MIGRATION_BRANCH" ] && [ "$MIGRATION_BRANCH" = "$CURRENT" ]; then
  # The branch alone does NOT prove the window. Phase 8 step 5's `clear` deletes the
  # block and leaves $RUN — anchor included — in place, so a migration that SUCCEEDED
  # matches every condition on this line. The commit count is what tells them apart:
  # the window is the state that has no commit of its own yet.
  N=$(git rev-list --count "$PREV_SHA..HEAD" 2>/dev/null)
  echo "on migration branch $MIGRATION_BRANCH with no in-progress block (previous branch: $PREV_BRANCH, previous sha: ${PREV_SHA:-<unrecorded>}, commits since: ${N:-<uncountable>})"
fi
```

If that fires, **read the commit count before offering anything** — two different states satisfy the branch condition, and only one of them is the window:

- **`commits since: 0`** → the genuine mid-Phase-4 window. Offer the way back — confirm with the user first, then unstage the `.gitignore` edit if `git status` shows one staged (`git restore --staged .gitignore`; the edit itself may stay — it is idempotent and the next run's Phase 4 re-stages it), `git checkout "$PREV_BRANCH"`, and — **only when `$MIGRATION_BRANCH` differs from `$PREV_BRANCH`** — `git branch -D "$MIGRATION_BRANCH"`. That delete is safe *because the count is zero*, not because the block is absent: Phase 4's scaffolding commit comes only after the block write, so a branch at `PREV_SHA` carries nothing to lose. **The `$MIGRATION_BRANCH != $PREV_BRANCH` guard is load-bearing** and mirrors the block-present arm's (below): when they are **equal** — a chained frontend run whose Phase 4 skip-create continued the finished template run's branch, or a frontend-only run started on a finished migration branch — that branch is not a fresh side branch at `PREV_SHA`; it holds the whole finished template run below `PREV_SHA`, so `PREV_SHA == HEAD` makes the count zero even though deleting it would destroy the only copy of every template commit. In that equal case offer **no** branch delete and treat the checkout as a no-op (you are already on it): salvage the ledger, say the branch stands with the finished run on it, and exit.
- **Any other count**, including an uncountable one (an unrecorded `PREV_SHA`, or one that no longer resolves) → **this is not the window, and the offer above would be destructive.** The likeliest reading is a migration that *finished*: the `clear` removed the block while N migration commits sit on the branch. Nothing in this skill ever pushes, so `git branch -D` here would destroy the only copy of every one of them. Say that plainly, name the commits (`git log --oneline "$PREV_SHA..HEAD"`), and offer **no** checkout and **no** branch deletion — there is no recorded rollback point left to check out to, and guessing one is the failure the empty-`previous_sha` arm below refuses. Leave the branch standing and hand the user the manual options instead: keep it as it is, or unwind it themselves with `git reset`/the reflog once they have confirmed which commits they mean. Salvage the ledger, say what you found, and exit.

If it does not fire, Phase 4 had not begun: no branch was created and no migration commit landed. **The manifest is not always untouched, though** — a *bootstrap* run writes it in Phase 2, before Phase 4, so check the tree before saying it is clean. A **template bootstrap creates** `.kairos/manifest.yaml` (a founding `template.sha` at the detected baseline); it is untracked, so pre-flight check 1 ignores it and the next fresh run silently **adopts** that baseline — and `in-progress.sh` refuses to re-found an existing manifest, so a wrong detection can never be re-detected. A **frontend bootstrap adds a `frontend:` block to the already-tracked manifest**, leaving it dirty, which pre-flight check 1 refuses on the next fresh run. So on this arm, after salvaging: if `.kairos/manifest.yaml` is **untracked** (this run's template bootstrap founded it), offer to `rm` it so the next run re-detects the baseline cleanly; if it is **tracked-but-modified** (a frontend bootstrap's added block), offer to revert it (`git checkout -- .kairos/manifest.yaml`). A manifest that predates this run — tracked and unmodified — is genuinely untouched; leave it.

The *only* thing this arm can otherwise lose is the Q&A ledger, which is why the salvage is not optional here. Salvage first (in place — no checkout happens on this arm), **then sweep `$RUN` yourself**: the next fresh run will not, because with no `previous_sha` anchored and a `qa-ledger.tsv` still present, pre-flight's stale-`$RUN` interlock refuses to sweep it (`reference/pre-flight.md` check 6). Use the same depth-1 sweep the rollback arm ends with (below), sparing the three mirror clones, so `qa-ledger` presence stays a reliable "a run pre-flight never cleaned" signal:

```bash
# Runs LAST on this arm, after the salvage has read $RUN/context.env and
# $RUN/qa-ledger.tsv: this deletes both. Spare the three mirror clones
# (template/common/frontend) exactly as pre-flight's fresh-mode sweep does.
if [ -d .kairos/migration ]; then
  find .kairos/migration -mindepth 1 -maxdepth 1 ! -name state -exec rm -rf {} +
  [ -d .kairos/migration/state ] \
    && find .kairos/migration/state -mindepth 1 -maxdepth 1 ! -name template ! -name common ! -name frontend -exec rm -rf {} +
fi
```

Say what you found and exit cleanly. **Block with `previous_branch`** → roll back (next section). **Block without it** — present but partial — → clear the block (the section after that); there is no recorded rollback point, and clearing is the only remedy for a state pre-flight refuses every fresh run over.

## With `previous_branch`: roll back

**Four steps, in this order, each its own block:** (1) **checkout** — and under `--no-branch`, the `git reset --hard` is *part of this same first step*, not a later one; (2) **salvage** the ledger; (3) the **untracked-debris pass**; (4) **sweep** the scratch. The sweep is the last block below and it deletes `$RUN/context.env`, `$RUN/qa-ledger.tsv` and the merge's own records along with the rest of the scratch — so a salvage placed after it reads an empty `SKILL_DIR` from a file that is gone and has no ledger left to propose from, and a debris pass placed after it has no record of what the run wrote. That is the loss the step at the top of this file exists to prevent, so each step stays its own block and the sweep stays last. Nothing here is optional: the checkout without the salvage still discards every answer the run collected, and the checkout without the debris pass leaves the template's files behind on the restored branch.

```bash
# Re-read from the manifest in THIS call: the block above ran in a different shell,
# and an empty $PREV makes `git checkout -f ""` fail while an empty $BRANCH silently
# skips the branch delete — a half-done rollback.
SRC=template; case "$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml)" in true) SRC=frontend ;; esac
PREV=$(yq -r ".$SRC.in_progress.previous_branch // \"\"" .kairos/manifest.yaml)
BRANCH=$(yq -r ".$SRC.in_progress.branch // \"\"" .kairos/manifest.yaml)
# Hard guard, not a warning: `${VAR:?}` aborts a non-interactive shell on the spot,
# so an empty PREV cannot reach the two statements below. Without it the block
# half-runs — `git checkout -f ""` fails, and the `git branch -D` line then decides
# what to delete from a $PREV nobody re-checked.
: "${PREV:?FAIL: previous_branch is empty in the manifest — stop; never guess a rollback branch}"
git checkout -f "$PREV"      # -f: a crashed Phase 5 may have left the tree dirty
# Delete only a real side branch — under --no-branch there is no `branch:` in the
# block, and an unguarded delete would target the branch just checked out. The
# if-form keeps the common --no-branch path at exit 0 (a trailing && would exit 1
# and read as the rollback failing).
if [ -n "$BRANCH" ] && [ "$BRANCH" != "$PREV" ]; then git branch -D "$BRANCH"; fi
```

**When the migration commits sit on the branch you are standing on** — either `--no-branch` (no `branch:` in the block, so they landed on the user's own branch) or a **chained frontend run** (the block's `branch:` equals its `previous_branch`, because Phase 4 continued the finished template run's branch rather than cutting a new one): the checkout above does not undo those commits, and the branch delete was correctly skipped (`BRANCH` empty, or `BRANCH` equal to `PREV`). The rollback is a reset to `previous_sha` (captured by Phase 4 on every path — the template run's tip for a chained frontend run, so this reset undoes the frontend commits and the live `frontend.in_progress` block while leaving the advanced `template.sha` untouched) — destructive on a branch the user keeps, so state exactly what it discards and run it only after the user explicitly confirms. It runs HERE, before the salvage: `git reset --hard` restores tracked files, so an `.kairos/intent.md` append made before it — and any commit of that append — would be discarded with the migration commits it undoes, while the ledger the salvage reads survives (`$RUN` is untracked; only the sweep below deletes it).

```bash
# anchor-exempt: same rule as the read block above — abort's rollback point comes
# from the committed manifest, which outlives a swept $RUN.
SRC=template; case "$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml)" in true) SRC=frontend ;; esac
PREV=$(yq -r ".$SRC.in_progress.previous_branch // \"\"" .kairos/manifest.yaml)
BRANCH=$(yq -r ".$SRC.in_progress.branch // \"\"" .kairos/manifest.yaml)
PREV_SHA=$(yq -r ".$SRC.in_progress.previous_sha // \"\"" .kairos/manifest.yaml)
# Reset ONLY the two shapes whose commits are on the checked-out branch: --no-branch
# (empty BRANCH) and a chained frontend run (BRANCH == PREV). On a real side branch the
# checkout already moved off the migration commits, and resetting PREV here would rewind
# whatever else lives on it — so gate the reset, never run it blind.
if [ -z "$BRANCH" ] || [ "$BRANCH" = "$PREV" ]; then
  # Two forms of the same stop, and both stay: the `[ -n ]` line carries the message,
  # the `${VAR:?}` expansion is what makes the abort unconditional — it fires even if
  # the guard line is edited, mis-copied, or run in a shell where `exit 1` lands in a
  # subshell rather than this one.
  [ -n "$PREV_SHA" ] || { echo "FAIL: no previous_sha recorded — stop, never guess a SHA"; exit 1; }
  : "${PREV_SHA:?FAIL: previous_sha is empty — stop; git reset --hard with no argument is a SUCCESSFUL reset to HEAD}"
  git reset --hard "$PREV_SHA"
fi
```

Re-read `previous_sha` here rather than reusing the earlier block's value: `git reset --hard ""` is a *successful* reset to `HEAD`, so an emptied variable turns the one destructive step into a silent no-op the user is told succeeded. The reset also restores `.kairos/manifest.yaml`, in-progress block gone. It removes no untracked file (exactly as the checkout does not), so the debris pass **below** covers those on this arm too. If `previous_sha` is empty (a run recorded before it existed), say so and stop — never guess a SHA.

**Now run the salvage** — the step at the top of this file, on the arm it was written for. The tree is back on `$PREV` (and, under `--no-branch`, back at `previous_sha`) so the entries land on the restored state, and the state dir is still intact: it is gitignored, so `git checkout -f` never reached it and `$RUN/qa-ledger.tsv` still holds every row the run logged. Propose the rows in one batched per-row-confirmed question, then append each confirmed one:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# Same if-form as the block at the top of this file, and for the same two reasons.
# Run this block once per confirmed row.
ENTRY="<the confirmed fact>"
GUARD="<the in-grammar tree assertion, or empty when the row has none>"
if [ -n "$GUARD" ]; then
  ENTRY="$ENTRY" GUARD="$GUARD" "$SKILL_DIR/scripts/promote-intent.sh"
else
  ENTRY="$ENTRY" "$SKILL_DIR/scripts/promote-intent.sh"
fi
```

Same if-form as the block at the top of this file, for the same reasons — full rationale there and in `phases/8-finalize.md` → the `BRANCH=` if-form.

(If the anchor is already gone here — a `$RUN` swept by something outside this run, or never created — `SKILL_DIR` is the one value abort can still take from the skill it just loaded; use that path literally and note it. Same fallback as the clear arm below.)

**Then clear the template's untracked debris — and only that.** `git checkout -f "$PREV"` restores **tracked** files. Anything the template *added* on a run that crashed before committing it — a mid-Phase-5 `added-mechanical` or `renamed-mechanical` write, a file a Phase 7 task created before its commit — git has never heard of, so the checkout leaves it sitting on the restored branch. Pre-flight's dirty check is a `git diff` / `git diff --cached` pair and sees no untracked file at all, so the debris survives unremarked into every future run and into the user's next `git add -A`.

`git clean -fd` is **not** the remedy: it would take the user's own untracked files — work they left in the tree before the migration started — and losing those is worse than the debris. Two passes instead. The first deletes only what the run's own records prove the run wrote; the second decides nothing on its own.

```bash
RUN=.kairos/migration/state
# The run's record of what IT wrote, from three artifacts: structural-merge.sh appends
# every mechanical addition to added.txt and every *mechanical* rename (the
# `renamed-mechanical` arm only — a merge-pipeline rename stays tracked in git's history,
# not here) as `old -> new` to renamed.txt, and step 4b's apply-ask-user.sh records each
# enacted write to ask-user-applied.tsv (column 4 `written`). A rename's NEW side, and a
# `theirs`/`take` blob written at a fresh path, are both additions the checkout leaves
# untracked. Absent files are not an error — a swept $RUN just makes pass 1 empty and
# hands everything to pass 2.
ADDED=$({ cat "$RUN/added.txt"; sed -n 's/^.* -> //p' "$RUN/renamed.txt"; awk -F'\t' '$4=="written"{print $2}' "$RUN/ask-user-applied.tsv"; } 2>/dev/null | sort -u)
# -uall, not the default: git collapses a wholly-untracked directory to `web/`, and a
# collapsed entry can never match a recorded file path — so the default listing would
# hide exactly the case where the template added a whole subtree.
UNTRACKED=$(git status --porcelain -uall -z | tr '\0' '\n' | sed -n 's/^?? //p' | sort -u)
# Pass 1 — the INTERSECTION, never the record alone: a path that came back tracked
# with the checkout belongs to $PREV and is the user's, whatever the record says.
comm -12 <(printf '%s\n' "$ADDED" | grep .) <(printf '%s\n' "$UNTRACKED" | grep .) \
  | while IFS= read -r p; do echo "removing $p"; rm -f -- "$p"; done
echo "--- still untracked (pass 2 — nothing below is deleted by this block) ---"
comm -13 <(printf '%s\n' "$ADDED" | grep .) <(printf '%s\n' "$UNTRACKED" | grep .)
```

Pass 1 is safe to run unattended because both halves must agree. The one path it can remove that the user cared about is one where they already had an untracked file exactly where the template added one — and the merge overwrote that file's content when it wrote it, so what is deleted there is the template's blob, not their work.

**Pass 2 is never automatic.** The records are truncated at the start of each `structural-merge.sh` run and appended as each action is enacted, so a crash *mid-merge* leaves them partial — short, never wrong — and Phase 7's additions are in no record at all. One classifier does survive until the sweep below: the target side of the synthetic repo. That repo addresses its two sides by **git tag at the repo root** — `kairos-base` and `kairos-target` — the same tags `structural-merge.sh` and `apply-ask-user.sh` read; there is **no** `target/` or `base/` subdirectory inside `$SYNTH` (a tree-path probe against one always misses, which presented *every* leftover as ambiguous and made the user adjudicate blind). So ask git whether the residue path exists on the target side, exactly as those scripts do:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
# Bare read (not ctx): a swept $RUN legitimately has no SYNTH, and that is the answer
# "the tree is gone" — the check below simply cannot run, not a failure to report.
SYNTH=$(sed -n 's/^SYNTH=//p' "$RUN/context.env")
# For a residue path $p: a hit means the template ADDED it — near-certain debris.
git -C "$SYNTH" cat-file -e "kairos-target:$p" 2>/dev/null && echo "template debris: $p"
```

If the tree is already gone (a swept `$RUN`, or `SYNTH` unset), don't re-run materialize just for this — fall back to reading the layout by hand. What no tree can tell apart is a Phase 7 executor's file versus the user's own: both are absent from the target side. So show the annotated residue to the user — target-tag hits as template debris, the rest as task-or-user work — and delete only what they confirm, path by path. The unattributable remainder is why this pass ends in a question rather than a command.

Only once the confirmed entries are in `.kairos/intent.md`, sweep the scratch — this block is the point of no return for the ledger:

```bash
# Runs LAST: this sweep deletes $RUN/context.env and $RUN/qa-ledger.tsv, so the
# salvage above cannot be folded into this block or moved after it.
# Clear the gitignored scratch (PLAN.md is on the deleted branch) but SPARE ALL
# THREE mirror clones — the template at state/template, the kairos-component-common
# mirror at state/common, and the frontend source at state/frontend — the same
# three pre-flight's fresh-mode sweep spares. Re-cloning tens of MB of git objects
# is the expensive part, and each is refreshed in place on the next run
# (reference/pre-flight.md check 6/7 for the template, check 8.6 for the frontend;
# clone-common.sh's remote update for common, which also re-clones a partial
# mirror). Two BSD-compatible depth-1 sweeps.
if [ -d .kairos/migration ]; then
  find .kairos/migration -mindepth 1 -maxdepth 1 ! -name state -exec rm -rf {} +
  [ -d .kairos/migration/state ] \
    && find .kairos/migration/state -mindepth 1 -maxdepth 1 ! -name template ! -name common ! -name frontend -exec rm -rf {} +
fi
```

Checking out the previous branch restores `.kairos/manifest.yaml` to its pre-migration state automatically (the in-progress block is gone with the file; under `--no-branch` the reset above already restored it). Now make the commit offer from the top of this file — the arm is finished, so the offer can no longer be discarded or miscounted. Done.

## Block present, `previous_branch` absent: clear the block

This block is not a migration you can roll back — it is a block that reads as **live** to `scripts/pre-flight.sh` while carrying nothing abort can act on. It gets there three ways: Phase 4 wrote the key before its children, Phase 8 emptied the mapping (`in_progress: {}`) instead of deleting the key on a migration that *succeeded*, or the manifest was hand-edited or restored from a conflicted merge. Say which is likeliest from the tree in front of you, and say the consequence in the user's terms: **this block is why a fresh run is being refused**, and clearing it is what makes the next run possible.

The salvage step at the top of this file runs here as on every other path — it is the only chance to keep the run's answers, and it does not depend on the block being complete. There is no checkout on this arm, so append the confirmed entries to `.kairos/intent.md` in place.

Confirm with the user, then:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
SRC=template; case "$(yq -r '.frontend | has("in_progress")' .kairos/manifest.yaml)" in true) SRC=frontend ;; esac
SOURCE=$SRC env -u PHASE_KEY ACTION=clear "$SKILL_DIR/scripts/in-progress.sh"   # prints "cleared" or "unchanged"
```

(If the anchor is gone too — a swept or never-created `$RUN` — `SKILL_DIR` is the one value abort can still take from the skill it just loaded; use that path literally and note it.)

**Do not check out anything and do not delete a branch.** Without `previous_branch` there is no recorded rollback point, and guessing one is the same failure the empty-`previous_sha` arm above refuses. The script leaves the rest of the manifest untouched — **every** baseline included, so no baseline is advanced by a rollback, and the *other* source's baseline is not rolled back either: clearing `frontend.in_progress` leaves `template.sha` exactly where the template run left it, and clearing `template.in_progress` leaves `frontend.sha` alone.

**Sweep `$RUN` yourself once the salvage is done** — do not rely on the next fresh run to sweep it. A partial block reaches this arm with no `previous_sha` and often with a `qa-ledger.tsv` still present, which is exactly the shape pre-flight's stale-`$RUN` interlock refuses to sweep (`reference/pre-flight.md` check 6); leaving it would close the same door on the next fresh run that clearing the block just opened. Use the same depth-1 sweep the rollback arm ends with, sparing the three mirror clones, and only **after** the salvage above has read `$RUN`:

```bash
# After the salvage (which read $RUN/context.env and $RUN/qa-ledger.tsv) and the
# clear above. Spare template/common/frontend, as pre-flight's fresh-mode sweep does.
if [ -d .kairos/migration ]; then
  find .kairos/migration -mindepth 1 -maxdepth 1 ! -name state -exec rm -rf {} +
  [ -d .kairos/migration/state ] \
    && find .kairos/migration/state -mindepth 1 -maxdepth 1 ! -name template ! -name common ! -name frontend -exec rm -rf {} +
fi
```

The manifest is a **tracked** file, so this leaves the working tree dirty — and pre-flight check 1 then refuses the next fresh run with "working tree is dirty. Commit or stash before migrating," which is the same door closing again. Offer `git add .kairos/manifest.yaml && git commit -m "chore: clear stale migration in-progress block"`; if the user declines, say plainly that the next migration will stop until the edit is committed or stashed.
