## Phase 4: Create migration branch

PHASE_KEY: m6dh2pjx
(Proof-of-load: this phase's scripts — `suggest-branch.sh` and `ensure-state-ignored.sh` — refuse to run without `PHASE_KEY=m6dh2pjx` in their environment. The key is stated only in this file — never copy it into SKILL.md or another phase.)

**Always confirm the branch name with the user** (unless `--branch <name>` or `--no-branch`). Derive a suggested default, present it, and wait for accept-or-override — never create a branch on an unconfirmed name.

Derive the suggestion with `scripts/suggest-branch.sh` (it resolves the username — `$HOME` basename, falling back to a real login name when that is empty or generic; see its header):

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); TARGET=$(ctx TARGET); RUN_SOURCE=$(ctx RUN_SOURCE)
# MIGRATION_BRANCH is absent on a first run and present when a template run of this
# same invocation already created one — bare read, because that absence is the record
# of "no branch exists yet". Under SOURCE=frontend the script prints it back
# unchanged: a CHAINED frontend run continues the template run's branch so one PR
# carries both. A template run ignores it. On the chained re-entry the key is usually
# GONE (the fresh pre-flight swept the anchor), which is why the script falls back to
# the migration-shaped branch already checked out — see below.
MIGRATION_BRANCH=$(sed -n 's/^MIGRATION_BRANCH=//p' "$RUN/context.env")
SUGGESTED_BRANCH=$(SOURCE=$RUN_SOURCE MIGRATION_BRANCH=$MIGRATION_BRANCH \
  TARGET=$TARGET PHASE_KEY=m6dh2pjx "$SKILL_DIR/scripts/suggest-branch.sh")
```

**When the suggestion IS the branch you are already on** — a chained frontend run — there is nothing to create: skip the ask and skip `git checkout -b` (it would fail on an existing ref), keep `PREV_BRANCH`/`PREV_SHA` as this run's own start (captured below from the current HEAD, which is the template run's tip — that tip is what aborting the *frontend* run rolls back to, and it is why the template run's commits survive that abort), and go on to the in-progress write. Say out loud that the frontend run is continuing on the template run's branch; a user who wants a separate PR asks for `--branch <name>` and gets the normal create path.

That case is **self-healing, and has to be**: the chained frontend run re-enters through a *fresh* Phase 1, whose sweep deletes `$RUN/context.env` — so `MIGRATION_BRANCH` is gone by the time this phase runs, and on its own the anchor read above would fall through to a brand-new `topic/<user>/frontend-update-<sha>` branch off the template run's tip: two branches, two PRs, contradicting the documented default (`phases/8-finalize.md` → *Frontend-run consent*, PRD story 12). So under `SOURCE=frontend` the script also reads the branch you are **standing on** and prints it back when it is migration-shaped (either suggested glob — the same shapes pre-flight check 3 accepts as the chained re-entry), with an INFO line saying so. A **frontend-only** run started from an ordinary branch matches neither source and gets its own name and the normal create path.

A template run started under **`--no-branch`** is the other chained shape: it left no migration branch and its commits sit on the branch you are standing on. That branch is **not** migration-shaped, so the standing-branch self-heal above does not fire — instead the frontend leg must re-honor `--no-branch` (re-supplied on the fresh Phase 1 re-entry alongside `RUN_SOURCE=frontend`; see `phases/8-finalize.md`), taking this phase's existing `--no-branch` path below: skip the ask, create nothing, stay on the current branch, and record no `MIGRATION_BRANCH`. `suggest-branch.sh`'s suggestion is ignored on that path (`BRANCH` stays empty), so no script change is needed — the `--no-branch` re-supply is what makes one PR carry both.

Ask: "Create migration branch as `$SUGGESTED_BRANCH`? Accept to use it, or reply with a different branch name." Use their answer (or the suggestion if they accept) as `$BRANCH`. If `--branch <name>` was given, use it without prompting. Skip the ask entirely under `--no-branch`.

**If the chosen name already exists** (`git rev-parse --verify --quiet "refs/heads/$BRANCH"` succeeds) — other than the chained-frontend case just above, where the suggestion deliberately **is** the branch you're already standing on and skip-create is the intended, self-healing path, not a collision — the `git checkout -b` below fails outright; do not proceed on the error. Relay it and re-ask for a different name (or offer to reuse the existing branch if the user confirms it is a stale migration branch they want to continue on); never auto-suffix or force-create over an existing ref.

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# anchor-exempt: PREV_BRANCH/PREV_SHA/BRANCH — this block ESTABLISHES them, and
# it must capture them from the pre-migration HEAD — which is why the last line
# anchors them in the same call, and why continue mode never re-runs this block
# (a second capture would take PREV_SHA from a mid-migration HEAD and destroy
# abort's only rollback point).
PREV_BRANCH=$(git rev-parse --abbrev-ref HEAD)
PREV_SHA=$(git rev-parse HEAD)
BRANCH="<name from --branch, or the confirmed/overridden suggestion — empty under --no-branch>"
# Three modes, decided here rather than by a note at the end of the file (a block
# executed top-down must not create a branch a later paragraph revokes):
#   create        — normal run: BRANCH is a new name.
#   skip-create   — chained frontend run: the suggestion IS the branch you are
#                   standing on, so BRANCH equals PREV_BRANCH and there is nothing
#                   to create (checkout -b would fail on the existing ref).
#   --no-branch   — BRANCH empty: no branch is created and none is recorded; the
#                   key's absence is the durable record (SKILL.md → Run-context anchor).
if [ -n "$BRANCH" ] && [ "$BRANCH" != "$PREV_BRANCH" ]; then
  git checkout -b "$BRANCH"
fi
if [ -n "$BRANCH" ]; then
  RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" MIGRATION_BRANCH=$BRANCH PREV_BRANCH=$PREV_BRANCH PREV_SHA=$PREV_SHA
else
  RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" PREV_BRANCH=$PREV_BRANCH PREV_SHA=$PREV_SHA
fi
```

**`--squash-on-finish` is anchored in Phase 2, not here, and `--no-branch` needs no anchor at all** — the compaction-window rationale for both lives with the anchoring itself, in `phases/2-resolve-target.md`; this phase only consumes the results.

**Ensure the state directory is gitignored** — `grep -qxF '.kairos/migration/state/' .gitignore` decides: present is a no-op; absent (every component born from template `main`, which does not ship the line — `feature/integration_api` and the facade template do) gets it appended. A component may also carry the legacy broad `.kairos/migration/` ignore, which would also hide the committed `PLAN.md` — and git can't re-include a file whose parent dir is ignored. Pre-flight's `.git/info/exclude` entry already keeps the state dir out of git history for this checkout; what this step adds is the durable, committed `.gitignore` entry every other developer needs, plus the legacy-broad-ignore migration. The script migrates a legacy broad ignore to the state-only pattern and appends the pattern if missing (idempotent; it matches the literal pattern rather than `git check-ignore`, which pre-flight's local exclude already satisfies — see its header):

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
STATE_IGNORE=$(PHASE_KEY=m6dh2pjx "$SKILL_DIR/scripts/ensure-state-ignored.sh")   # prints "modified" or "unchanged"
# Stage it HERE, in the call that learned the verdict: `$STATE_IGNORE` is gone by
# the next tool call, and an empty one reads as "unchanged" — so the .gitignore
# edit would silently miss the scaffolding commit and land in a later task's
# `git add -A` instead. (`git add` on an unchanged path adds nothing useful.)
# if-form, not `&&`: on the common `unchanged` path a trailing `&&` would exit
# this whole block 1, which reads as a failed step rather than the no-op it is.
if [ "$STATE_IGNORE" = modified ]; then
  git add .gitignore
fi
```

Set the in-progress block in `.kairos/manifest.yaml` (the entry trigger for abort and continue; the *granular* resume point is inferred from git + filesystem, not from this block). **Run the script — never hand-edit the manifest instead.** It owns the block's shape and refuses to write a partial one, which is the point: a block that reads as live but carries no `previous_branch` gets every future fresh run refused through a door abort cannot open (see its header):

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); TARGET=$(ctx TARGET)
PREV_BRANCH=$(ctx PREV_BRANCH); PREV_SHA=$(ctx PREV_SHA)
# MIGRATION_BRANCH is recorded only in branch mode, so empty is the --no-branch
# answer — bare read, not `ctx`, and the script then omits the `branch:` key.
BRANCH=$(sed -n 's/^MIGRATION_BRANCH=//p' "$RUN/context.env")
RUN_SOURCE=$(ctx RUN_SOURCE)
SOURCE=$RUN_SOURCE ACTION=set PHASE_KEY=m6dh2pjx \
  TARGET_SHA=$TARGET BRANCH=$BRANCH PREV_BRANCH=$PREV_BRANCH PREV_SHA=$PREV_SHA \
  "$SKILL_DIR/scripts/in-progress.sh"
```

`SOURCE` decides which key the block lands under — `template.in_progress` or `frontend.in_progress` — and the script **refuses to write one while the other exists**: exactly one migration is live per component, because every value in the block (which branch, which target, which rollback SHA) has exactly one answer. If that refusal fires, the previous run never finished: finish or abort it rather than working around the message.

`TARGET_SHA`, `PREV_BRANCH` and `PREV_SHA` are required and refused when empty — `previous_sha` is written on **EVERY path**, since it is abort's only rollback point and Phase 8's squash base. `BRANCH` is optional: leave it unset under `--no-branch` and the `branch:` key is omitted entirely rather than written empty (recording it would make abort's cleanup delete the branch being committed on).

Commit the scaffolding (`.gitignore` was already staged by the step that modified it, if it did):

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
TARGET=$(ctx TARGET)
: "${TARGET:?FAIL: TARGET missing from the run-context anchor — stop; a commit message built on an empty TARGET silently reads as 'chore: begin migration to' with nothing after it}"
git add .kairos/manifest.yaml
git commit -m "chore: begin migration to ${TARGET:0:7}"
```

Under `--no-branch` the checkout block above already created nothing and recorded no `MIGRATION_BRANCH`, and the in-progress call's bare read then leaves `BRANCH` empty, so the script omits `branch:` from the block (recording it would make abort's cleanup try to delete the checked-out branch) — `previous_branch: $PREV_BRANCH` and `previous_sha: $PREV_SHA` are still recorded, and the SHA is abort's only rollback point on the user's own branch. Warn that abort will be more disruptive.
