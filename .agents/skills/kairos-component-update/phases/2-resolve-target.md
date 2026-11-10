## Phase 2: Resolve baseline + target

PHASE_KEY: k3wq8vfr
(Proof-of-load: this phase's scripts — `bellwether-detect.sh`, `scope-check.sh`, `resolve-component-name.sh`, and `in-progress.sh ACTION=bootstrap` — refuse to run without `PHASE_KEY=k3wq8vfr` in their environment. The key is stated only in this file — never copy it into SKILL.md or another phase.)

**Anchor the run's SOURCE, and the user's frontend intent, first.** A run is one source (SKILL.md → Phase index) and everything downstream turns on which — which manifest key the baseline advance writes, which upgrade-file directory is collected, which cwd the gates run in. Both values come from the invocation and nothing on disk can re-derive them mid-run, which is exactly the anchor's remit:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# Substitute the literals. RUN_SOURCE is `template` on the default invocation and on
# the template leg of a chained one; `frontend` on a frontend-only invocation and on
# the frontend leg. FRONTEND_INTENT is what the user's sentence said about web/ —
# frontend-only | both | template-only | unsaid (SKILL.md → Argument extraction) —
# and `unsaid` is a real value, not a missing one: Phase 8's consent step ASKS on
# `unsaid` and does not ask on the other three.
RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" RUN_SOURCE="<template|frontend>" FRONTEND_INTENT="<frontend-only|both|template-only|unsaid>"
```

A `frontend` run takes the *Frontend run* section at the end of this file in place of the **template chain** below — the manifest read, the bootstrap detector, the resolve-and-validate block, and the `BASE == TARGET` early-end that follows it. The two anchor blocks immediately following (`TARGET_REF`, and `--squash-on-finish`) are **not** part of that chain: every run records them, whatever its source, so a `frontend` run executes them here and then jumps to the *Frontend run* section. Neither is the **changelog** nor the **scope-signal** block after the early-end: both sources produce the scope advisory (a declared goal of this phase), each against its own source's mirror, so a `frontend` run runs them after its own resolve-and-validate rather than dropping them on the jump. Only the template chain — the manifest read through the `BASE == TARGET` early-end — is the template source's alone.

**Anchor the ref the invocation named — first, before anything reads it.** Three things downstream need it (the bootstrap detector, the bootstrap manifest writer, and the TARGET chain below), each runs in its own tool call, and a value you extracted from the user's sentence lives only in this conversation. `$TARGET_REFSPEC` and `$TEMPLATE_BRANCH` are **not** shell variables: a block that writes them resolves them to nothing and falls silently through to `main`, which is exactly how `--template-branch feat/x` used to detect its founding baseline from `main`'s history. So the ref goes on the anchor in its own block, as a literal value:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# Rules 1 and 2 of the chain below are one anchor key because they are one fact —
# a ref the USER chose. Substitute the literal: the positional refspec if the
# invocation carried one, else the --template-branch / --frontend-branch argument
# (per the run's source; the positional wins either way).
RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" TARGET_REF="<the ref the invocation named>"
```

If the invocation named **neither**, skip that call entirely — the key's absence is the record of "the user chose no ref", and every reader below treats an empty `TARGET_REF` as that. (Do not record `TARGET_REF=` empty either — not because the script refuses it: `record-context.sh` accepts an empty value (it refuses only a space-*padded* one). Skip the call because an empty record and an absent key read the same to the bare-form readers below, so recording empty buys nothing over recording nothing.)

**Anchor `--squash-on-finish` in this same breath, if the invocation carried it** — this phase's writes are the run's first that survive pre-flight's fresh-mode sweep, and the flag is not consumed until Phase 8 step 6, on the far side of the run's longest conversation-only stretch (model Q&A, materialization, classification, Phase 3.5's batched questions). A compaction anywhere along it evicts a flag that has no anchor yet, and Phase 8 reads absence as "the flag was not given" and skips the squash silently — by design, which is exactly why the write belongs here and not hours later:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" SQUASH_ON_FINISH=1
```

Record it **only when the flag was given** — nothing is written otherwise, so the key's absence stays the record of "not given" (the `COMMON_CACHE` discipline). `--no-branch` needs no anchor here: its pre-Phase-4 loss is not silent — Phase 4's suggest-and-confirm prompt puts branch mode in front of the user, who is the flag's source — and from Phase 4 on, the `in_progress` block's missing `branch:` is the durable record.

Read `.kairos/manifest.yaml`:

- **Present** → `template.sha` is the baseline, `template.repo` the source, `template.branch` the default branch.
- **Absent** → bootstrap. Read `reference/bellwether-detection.md`, then run the detector:

  ```bash
  RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
  SKILL_DIR=$(ctx SKILL_DIR); CACHE=$(ctx CACHE)
  # Detection must walk the branch this run TARGETS. The detector defaults to main,
  # so an unpassed branch detects the baseline from main's history while the
  # migration runs against another one — and writes that SHA as the component's
  # founding baseline, which every future migration then diffs from.
  # BOTH inputs come off the ANCHOR and nothing here reads a live shell variable:
  # this block runs in its own tool call. TARGET_REF carries rules 1-2 (the block
  # above recorded it); TEMPLATE_LOCAL_BRANCH is rule 3, and it is pre-flight's.
  # Rule 4 (manifest template.branch) cannot apply — there is no manifest yet.
  # Empty is a legitimate answer for both, so both are read with the bare form.
  TARGET_REF=$(sed -n 's/^TARGET_REF=//p' "$RUN/context.env")
  TEMPLATE_LOCAL_BRANCH=$(sed -n 's/^TEMPLATE_LOCAL_BRANCH=//p' "$RUN/context.env")
  BOOT_REF=${TARGET_REF:-${TEMPLATE_LOCAL_BRANCH:-main}}
  # Say which rule fired, out loud. `main` here is a real default and a plausible
  # wrong answer, and this is the only moment it is cheap to catch.
  if   [ -n "$TARGET_REF" ];            then BOOT_WHY="rule 1/2 — the ref the invocation named"
  elif [ -n "$TEMPLATE_LOCAL_BRANCH" ]; then BOOT_WHY="rule 3 — the local --template-path clone's checked-out branch"
  else                                       BOOT_WHY="the main default — no ref given, no local clone"
  fi
  echo "BOOT_REF=$BOOT_REF ($BOOT_WHY)"
  # Resolve the component name FIRST and hand it to the detector: its wide-scan
  # fallback is the cwd basename — a different identifier more often than not, the
  # same reason the manifest writer below refuses to guess. Unresolved is passed
  # as empty (the scan still runs); treat its ranking as weaker and lean on the
  # user confirmation.
  COMP_NAME=$(PHASE_KEY=k3wq8vfr "$SKILL_DIR/scripts/resolve-component-name.sh") || COMP_NAME=""
  CACHE=$CACHE RUN=$RUN TEMPLATE_BRANCH="$BOOT_REF" COMPONENT_NAME="$COMP_NAME" PHASE_KEY=k3wq8vfr "$SKILL_DIR/scripts/bellwether-detect.sh"
  ```

  Relay `BOOT_REF` and which rule chose it along with the detector's candidates — the branch decides the answer, so the user is confirming both. Then, once a baseline is chosen, write the initial manifest with the script that owns the file — **never by hand**. It re-derives `$BOOT_REF` because it is a *later tool call* and the block above's shell is gone:

  ```bash
  RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
  SKILL_DIR=$(ctx SKILL_DIR)
  TARGET_REF=$(sed -n 's/^TARGET_REF=//p' "$RUN/context.env")
  TEMPLATE_LOCAL_BRANCH=$(sed -n 's/^TEMPLATE_LOCAL_BRANCH=//p' "$RUN/context.env")
  BOOT_REF=${TARGET_REF:-${TEMPLATE_LOCAL_BRANCH:-main}}
  COMP_NAME=$(PHASE_KEY=k3wq8vfr "$SKILL_DIR/scripts/resolve-component-name.sh") || COMP_NAME=""
  if [ -z "$COMP_NAME" ]; then
    echo "ASK: pkg/schema/globals.go has no usable const ComponentName. What is this component's name? (Not the git repo or directory name — those often differ, e.g. repo kairos-todo-demo vs component todo-demo.) Do not guess from Chart.yaml, go.mod, or the checkout path."
    # stop here, wait for the answer, then set COMP_NAME to it
  fi
  echo "bootstrap NAME=$COMP_NAME (from pkg/schema/globals.go, or the user)"
  # REPO: the URL pre-flight cloned from. A facade bootstrap with no URL given
  # used git@ssh.bitbucket.org:ifs-pd/kairos-component-facade-template.git.
  ACTION=bootstrap PHASE_KEY=k3wq8vfr NAME="$COMP_NAME" REPO="<upstream-url>" \
    BASE_SHA="<detected-baseline-sha>" BRANCH="$BOOT_REF" "$SKILL_DIR/scripts/in-progress.sh"
  ```

  If `resolve-component-name.sh` fails, **ask the user and wait**. Do not search
  `Chart.yaml`, `go.mod`, `imageRepository`, or the directory name — those are a
  different identifier more often than not. The only mechanical source is
  `pkg/schema/globals.go` `const ComponentName`; anything else is a question.

  `BRANCH` records the branch the baseline was detected on, so rule 4 of the chain below defaults the *next* migration to that same history. It is **required** — the writer refuses an empty one rather than defaulting to `main`, because an empty `$BOOT_REF` means the derivation above did not reach the call, and a guessed `main` there is a guess about the component's past that nothing re-examines. When `$BOOT_REF` is a bare SHA or tag rather than a branch name, record the branch that ref lives on instead (ask if it isn't obvious) — never leave `main` recorded against a baseline detected elsewhere.

  It writes `bootstrapped: true` itself — that flag changes planner and executor behavior for the component's whole life, and it is exactly the line a transcribed YAML block loses. It refuses to overwrite an existing manifest, and `BASE_SHA` must be a full 40-character SHA. Every value it writes is quoted as a string, so a branch named `1.0` or an all-digit SHA round-trips intact.

**Not on a resume.** If `.kairos/manifest.yaml` carries an `in_progress` block for this run's source (`template.in_progress`, or `frontend.in_progress` on a frontend run), this migration's target is already recorded as that block's `target_sha`, and the chain below must not re-derive it — it resolves a *ref*, so a branch that moved since the run started would silently re-target the migration. Take the recorded SHA (`reference/continue.md` → the lost-anchor arm, which is the only reason a resume reaches this phase at all).

Resolve and validate:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); CACHE=$(ctx CACHE)
# Not on a resume (the rule above): if this source's in_progress block already recorded
# a target_sha, that SHA IS the target — the chain below resolves a moving *ref*, so
# re-deriving it on a resumed run silently re-targets the migration. This block
# self-asserts the rule rather than trusting the reader to have branched away, the same
# way the frontend blocks below stop on a lost anchor with a `:?` guard.
RESUME_TARGET=$(yq -r '.template.in_progress.target_sha // ""' .kairos/manifest.yaml 2>/dev/null)
[ -z "$RESUME_TARGET" ] || { echo "FAIL: template.in_progress.target_sha=$RESUME_TARGET is already recorded — this is a resume; take that SHA (reference/continue.md → the lost-anchor arm), do NOT re-derive the target from a ref"; exit 1; }
# Both of the chain's non-manifest inputs come off the anchor, for the same reason:
# neither belongs to THIS tool call. Rules 1-2 are the invocation's ref, anchored by
# the block at the top of this phase; rule 3's input is pre-flight's — a lost
# TEMPLATE_LOCAL_BRANCH would fall silently through to rule 4 and resolve TARGET
# from the manifest branch instead of the branch the user pointed at. Empty is a
# legitimate answer for both (no refspec given; no --template-path), so both are
# read with the bare form, not `ctx`.
TARGET_REF=$(sed -n 's/^TARGET_REF=//p' "$RUN/context.env")
TEMPLATE_LOCAL_BRANCH=$(sed -n 's/^TEMPLATE_LOCAL_BRANCH=//p' "$RUN/context.env")

# TARGET default chain — first that applies wins:
#   1. explicit refspec argument            ┐ both anchored as TARGET_REF by this
#   2. --template-branch argument           ┘ phase's first block (positional wins)
#   3. local clone's checked-out branch     (TEMPLATE_LOCAL_BRANCH, --template-path only)
#   4. manifest template.branch
#   5. main
# The mirror clone carries every branch of the local template, so a local-branch
# ref resolves in $CACHE.
MANIFEST_BRANCH=$(yq -r '.template.branch // ""' .kairos/manifest.yaml)
TARGET_REF=${TARGET_REF:-${TEMPLATE_LOCAL_BRANCH:-${MANIFEST_BRANCH:-main}}}
TARGET=$(git -C "$CACHE" rev-parse "$TARGET_REF") \
  || { echo "FAIL: $TARGET_REF does not resolve in the template mirror $CACHE"; exit 1; }
BASE=$(yq -r '.template.sha' .kairos/manifest.yaml)

# SHA validation lives here (not pre-flight) — the SHAs aren't known until now.
git -C "$CACHE" cat-file -e "$BASE^{commit}" 2>/dev/null \
  || { echo "FAIL: baseline SHA $BASE not in template history"; exit 1; }
git -C "$CACHE" cat-file -e "$TARGET^{commit}" 2>/dev/null \
  || { echo "FAIL: target SHA $TARGET not in template history"; exit 1; }

# Anchor the resolution on disk in the SAME call that derived it (SKILL.md →
# Run-context anchor). Not a later block: these three exist only in this shell, and
# a record-context call that ran a tool call later would upsert `BASE=` — the
# anchor's own values, silently emptied, with every later phase then reading them.
# TARGET_REF is re-recorded deliberately: it arrived as the user's ref (or nothing)
# and leaves as the RESOLVED one, which is what every later phase means by the key.
RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" BASE=$BASE TARGET=$TARGET TARGET_REF=$TARGET_REF
```

**Surface which default fired, loudly, with ahead/behind vs `main`** — a wrong target is only cheap to catch here, before the expensive phases:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
CACHE=$(ctx CACHE); TARGET=$(ctx TARGET)
# two TAB-separated counts: behind, then ahead of TARGET relative to the template's
# default branch — manifest template.branch, else main. Hardcoding `main` here would
# print NOTHING on a repo whose default branch is named otherwise, silently dropping
# the advisory; an unresolvable ref is reported instead of swallowed.
REF_BRANCH=$(yq -r '.template.branch // "main"' .kairos/manifest.yaml 2>/dev/null); REF_BRANCH=${REF_BRANCH:-main}
git -C "$CACHE" rev-list --left-right --count "$REF_BRANCH...$TARGET" 2>/dev/null \
  || echo "ahead/behind unavailable — '$REF_BRANCH' does not resolve in the mirror; say so rather than omitting the advisory"
```

The resolution is already anchored — the block above recorded `BASE`, `TARGET` and `TARGET_REF` into `$RUN/context.env` as its last statement, which is why this block and every later phase can read them back rather than carrying them in conversation.

Tell the user the resolved ref (`$TARGET_REF`), which chain rule it came from, and the ahead/behind counts (or that they were unavailable — never silently omit them). When rule 3 fired (defaulted to a local feature branch), say so explicitly — `TARGET` is that branch's HEAD, not `main`. A template author who *meant* to migrate against `main` from a feature-branch checkout passes an explicit refspec or `--template-branch main` (rules 1–2 still win).

If `BASE == TARGET`, the **template run** ends early: tell the user "Already up to date at $TARGET." That ends the run, not the invocation — continue to `phases/8-finalize.md` → *Frontend-run consent*, which decides (silently, when there is no frontend source) whether a frontend run follows.

Show a short changelog:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
# The mirror is the run's OWN source's: a frontend run's BASE/TARGET are frontend SHAs
# that resolve only in FRONTEND_CACHE, never the template mirror. FRONTEND_CACHE is a
# FRONTEND_* key, so it is bare-read (SKILL.md → Run-context anchor), never through ctx.
if [ "$(ctx RUN_SOURCE)" = frontend ]; then CACHE=$(sed -n 's/^FRONTEND_CACHE=//p' "$RUN/context.env"); else CACHE=$(ctx CACHE); fi
BASE=$(ctx BASE); TARGET=$(ctx TARGET)
git -C "$CACHE" log --oneline "$BASE..$TARGET" | head -30
```

**Scope signal — advisory.** Before Phase 2.5, run:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); BASE=$(ctx BASE); TARGET=$(ctx TARGET)
# Same source-own mirror as the changelog block: scope-check.sh resolves BASE..TARGET in
# whatever mirror it is handed, so hand it the frontend mirror on a frontend run — the
# template mirror carries none of the frontend source's commits and it would exit 2
# (hard stop) on a range that is perfectly healthy. FRONTEND_CACHE is bare-read like
# every FRONTEND_* key (SKILL.md → Run-context anchor), never through ctx.
if [ "$(ctx RUN_SOURCE)" = frontend ]; then CACHE=$(sed -n 's/^FRONTEND_CACHE=//p' "$RUN/context.env"); else CACHE=$(ctx CACHE); fi
CACHE=$CACHE BASE=$BASE TARGET=$TARGET PHASE_KEY=k3wq8vfr "$SKILL_DIR/scripts/scope-check.sh"
```

`ADVISORY:` on stdout means `BASE..TARGET` exceeds the commit-count threshold (default 30 — tune with `THRESHOLD=<n>` if the project's norm differs) at which structural merging and planning get expensive. Commit count is a cheap proxy measured before anything is known about this component's customizations: relay it, and expect Phase 3's overlap signal to supersede it with the real number. **Exit 2 is a hard stop** — the range didn't resolve at all, and an unresolvable range must never read as a small one. Relay the script's FAIL message and fix `BASE`/`TARGET` before going further.

## Frontend run (`RUN_SOURCE=frontend`)

Everything above resolves the **template** source. A frontend run resolves the same two SHAs from the frontend source's keys and then rejoins the phase order unchanged — the shape is deliberately identical, and only the key prefix and the chain's inputs differ. Pre-flight (check 8.5) already recorded every input on the anchor.

**Target ref chain — first that applies wins**, mirroring the template chain rule for rule:

1. explicit refspec argument, else `--frontend-branch` — both anchored as `TARGET_REF` by this phase's block above (the positional wins)
2. `FRONTEND_LOCAL_BRANCH` — the `--frontend-path` checkout's checked-out branch. Same reasoning as rule 3 of the template chain: the strongest statement of "migrate against what I have here" is the branch that clone actually has out
3. `FRONTEND_BRANCH` — the manifest's `frontend.branch`
4. `main`

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# Bare reads throughout: every FRONTEND_* key is legitimately absent (SKILL.md →
# Run-context anchor), and for each of them empty IS the answer — no ref was named,
# no local checkout was given, no block was ever recorded.
TARGET_REF=$(sed -n 's/^TARGET_REF=//p' "$RUN/context.env")
FRONTEND_LOCAL_BRANCH=$(sed -n 's/^FRONTEND_LOCAL_BRANCH=//p' "$RUN/context.env")
FRONTEND_BRANCH=$(sed -n 's/^FRONTEND_BRANCH=//p' "$RUN/context.env")
FE_REF=${TARGET_REF:-${FRONTEND_LOCAL_BRANCH:-${FRONTEND_BRANCH:-main}}}
# Say which rule fired, out loud — `main` is a real default and a plausible wrong
# answer, and this is the only moment it is cheap to catch.
if   [ -n "$TARGET_REF" ];             then FE_WHY="rule 1 — the ref the invocation named"
elif [ -n "$FRONTEND_LOCAL_BRANCH" ];  then FE_WHY="rule 2 — the local --frontend-path checkout's checked-out branch"
elif [ -n "$FRONTEND_BRANCH" ];        then FE_WHY="rule 3 — the manifest's frontend.branch"
else                                        FE_WHY="the main default — no ref given, no local checkout, no recorded branch"
fi
echo "FE_REF=$FE_REF ($FE_WHY)"
```

`FRONTEND_SHA` is the baseline; the target is `$FE_REF` resolved in the **frontend mirror** — `FRONTEND_CACHE` on the anchor, established by pre-flight check 8.6 on every frontend run. **Not `CACHE`**: that is the *template* mirror, where a frontend SHA resolves to nothing and this validation refuses two SHAs that are both perfectly good.

**On a bootstrap run — no `frontend:` block, `FRONTEND_BOOTSTRAP` on the anchor — take the Bootstrap section below FIRST.** No frontend baseline exists yet, so the validation block cannot pass; the block routes that case itself rather than failing on an empty `BASE`. After the bootstrap's one confirmation writes the block, come back and run this validation — it reads the just-written `frontend.sha` from the manifest when the anchor has no `FRONTEND_SHA` yet.

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# Bare reads: the FRONTEND_* keys are legitimately absent on a template run. Both are
# present on a frontend run, and an EMPTY one here is a lost anchor, not an answer —
# the guard below stops the phase rather than resolving against the TEMPLATE mirror.
FE_CACHE=$(sed -n 's/^FRONTEND_CACHE=//p' "$RUN/context.env")
FRONTEND_SHA=$(sed -n 's/^FRONTEND_SHA=//p' "$RUN/context.env")
# A just-bootstrapped block is on disk before the anchor re-records it.
[ -n "$FRONTEND_SHA" ] || FRONTEND_SHA=$(yq -r '.frontend.sha // ""' .kairos/manifest.yaml)
FRONTEND_BOOTSTRAP=$(sed -n 's/^FRONTEND_BOOTSTRAP=//p' "$RUN/context.env")
if [ -z "$FRONTEND_SHA" ] && [ -n "$FRONTEND_BOOTSTRAP" ]; then
  echo "bootstrap run — no frontend baseline exists yet: run the Bootstrap section below FIRST, then re-enter this block" >&2
  exit 0
fi
: "${FE_CACHE:?FAIL: FRONTEND_CACHE missing from the anchor — pre-flight check 8.6 establishes the frontend mirror on a frontend run; re-run Phase 1 with RUN_SOURCE=frontend rather than resolving against the template mirror}"
# Not on a resume (the rule at the top of this section): if the frontend in_progress
# block already recorded a target_sha, that SHA IS the target — the FE_REF chain below
# resolves a moving *ref* (line 265), so re-deriving it on a resumed run silently
# re-targets the migration. This mirrors the template arm's RESUME_TARGET self-assertion
# (:116-122); the bootstrap exit above already returned, so a bootstrap run — which has
# no in_progress block — never reaches here with RESUME_TARGET set.
RESUME_TARGET=$(yq -r '.frontend.in_progress.target_sha // ""' .kairos/manifest.yaml 2>/dev/null)
[ -z "$RESUME_TARGET" ] || { echo "FAIL: frontend.in_progress.target_sha=$RESUME_TARGET is already recorded — this is a resume; take that SHA (reference/continue.md → the lost-anchor arm), do NOT re-derive the target from a ref"; exit 1; }
# Re-derive FE_REF rather than transcribing the block above's stdout — that block's
# shell is gone, and the chain's three inputs are all on the anchor (the template
# bootstrap re-derives BOOT_REF for the same reason).
TARGET_REF=$(sed -n 's/^TARGET_REF=//p' "$RUN/context.env")
FRONTEND_LOCAL_BRANCH=$(sed -n 's/^FRONTEND_LOCAL_BRANCH=//p' "$RUN/context.env")
FRONTEND_BRANCH=$(sed -n 's/^FRONTEND_BRANCH=//p' "$RUN/context.env")
FE_REF=${TARGET_REF:-${FRONTEND_LOCAL_BRANCH:-${FRONTEND_BRANCH:-main}}}
BASE=$FRONTEND_SHA
: "${BASE:?FAIL: no frontend baseline — neither the anchor nor the manifest carries one, and FRONTEND_BOOTSTRAP is not set either; this state should be unreachable, stop and check pre-flight check 8.5}"
TARGET=$(git -C "$FE_CACHE" rev-parse "$FE_REF") || { echo "FAIL: $FE_REF does not resolve in the frontend mirror $FE_CACHE"; exit 1; }
git -C "$FE_CACHE" cat-file -e "$BASE^{commit}" 2>/dev/null \
  || { echo "FAIL: frontend baseline SHA $BASE not in the frontend source's history"; exit 1; }
git -C "$FE_CACHE" cat-file -e "$TARGET^{commit}" 2>/dev/null \
  || { echo "FAIL: frontend target SHA $TARGET not in the frontend source's history"; exit 1; }
TARGET_REF=$FE_REF
RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" BASE=$BASE TARGET=$TARGET TARGET_REF=$TARGET_REF
```

Anchor `BASE`/`TARGET`/`TARGET_REF` in the same call that derived them (as above), and relay which rule chose the ref. **If `BASE == TARGET` the frontend is already current** — say so and stop this run; the consent step must not ask about a source that has nothing to adopt. Otherwise run the **changelog** and **scope-signal** blocks above before continuing to Phase 2.5: both pick `FRONTEND_CACHE` on this source automatically, and the scope advisory is a declared goal of this phase on either source — do not drop it on the jump into this section.

**Bootstrap — no `frontend:` block, but `web/` is there** (pre-flight recorded `FRONTEND_BOOTSTRAP`). Same confidence gating and the same **one** confirmation as the template bootstrap: score, show the top matches, confirm once. Two things are specific to this source:

- **Scoring compares the module subtree against the mount after the replacement map `component create` applies.** The mount already contains the component's own name where the template carries a placeholder, so scoring a raw subtree against it ranks every candidate equally badly and the true create commit does not come first. Substitute, then score.
- **The module is confirmed together with the commit.** When the source repo's `.kairos-updates/config.yaml` declares several template-kind modules, score each module's subtree and let the one confirmation cover module *and* commit; with a single template-kind module it collapses to today's flow and that module is the default answer. Nothing here hardcodes a module name — the confirmed key is what `frontend.template` records, and every later run resolves the subtree, the upgrade-file directory and the bellwethers from it.
- **The detector reads the FRONTEND mirror.** The invocation block below passes `CACHE=$FRONTEND_CACHE`, the mirror pre-flight check 8.6 established — the template mirror carries none of the frontend source's commits, so scoring against it finds no candidates at all and reports "no signal" for a component whose baseline is perfectly detectable.

Read `reference/bellwether-detection.md` (frontend arm) for the scoring rationale — the mount-vs-subtree comparison, the source-side substitution, and why there is no wide scan — then run the detector:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# Bare reads for TARGET_REF and every FRONTEND_* key: each is legitimately absent
# (SKILL.md → Run-context anchor) and empty IS the answer — no ref was named, no
# local checkout was given, no block was ever recorded. Pre-flight already defaulted
# FRONTEND_MOUNT to `web/` when the block omitted it, so nothing here re-defaults it.
FRONTEND_CACHE=$(sed -n 's/^FRONTEND_CACHE=//p' "$RUN/context.env")
TARGET_REF=$(sed -n 's/^TARGET_REF=//p' "$RUN/context.env")
FRONTEND_LOCAL_BRANCH=$(sed -n 's/^FRONTEND_LOCAL_BRANCH=//p' "$RUN/context.env")
FRONTEND_BRANCH=$(sed -n 's/^FRONTEND_BRANCH=//p' "$RUN/context.env")
FRONTEND_MOUNT=$(sed -n 's/^FRONTEND_MOUNT=//p' "$RUN/context.env")
FRONTEND_TEMPLATE=$(sed -n 's/^FRONTEND_TEMPLATE=//p' "$RUN/context.env")
FRONTEND_MODULE_PATH=$(sed -n 's/^FRONTEND_MODULE_PATH=//p' "$RUN/context.env")
# The frontend target chain, rule for rule as above.
FE_REF=${TARGET_REF:-${FRONTEND_LOCAL_BRANCH:-${FRONTEND_BRANCH:-main}}}
# On bootstrap there is no recorded module yet: pass the module key being SCORED
# (once per declared template-kind module) and let MODULE_PATH default from its
# config.yaml entry by leaving it empty.
# The FRONTEND mirror, not $CACHE: the template mirror carries none of the frontend
# source's commits, so scoring against it walks an empty candidate set and reports "no
# signal" for a component whose baseline is perfectly detectable. An empty key is a lost
# anchor, not an answer — pre-flight check 8.6 establishes this on every frontend run.
CACHE=$FRONTEND_CACHE
: "${CACHE:?FAIL: FRONTEND_CACHE missing from the anchor — re-run Phase 1 with RUN_SOURCE=frontend, which is what establishes the frontend mirror}"
CACHE=$CACHE RUN=$RUN TEMPLATE_BRANCH="$FE_REF" \
  MODULE="${FRONTEND_TEMPLATE:-<the module key being scored>}" \
  MODULE_PATH="$FRONTEND_MODULE_PATH" MOUNT="${FRONTEND_MOUNT:-web/}" \
  PHASE_KEY=k3wq8vfr "$SKILL_DIR/scripts/bellwether-detect.sh"
```

Apply the confidence gating in `reference/bellwether-detection.md` (regimes 1–3 — the frontend arm always reports `WIDESCAN=skipped`, so gate on `bellwether-scores.txt`) to pick the baseline, then write the block with the script that owns the manifest — **never by hand**. It adds the `frontend:` block to the existing manifest (it does not found one), refuses to overwrite a block that is already there, and writes `bootstrapped: true` itself:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# MOUNT is OMITTED when the mount is the default `web/` — the script writes the key
# only for a non-default mount, so a later reader can tell a deliberate mount from
# an incidental one. MODULE is the confirmed config.yaml key; MODULE_PATH is that
# module's subtree path inside the source repo (env-named apart from `path` because
# PATH is not ours). BRANCH is the branch the baseline was DETECTED on — the same
# non-defaultable value the template arm requires, read back as rule 3 of the chain
# above on the NEXT frontend run.
SOURCE=frontend ACTION=bootstrap PHASE_KEY=k3wq8vfr \
  REPO="<the frontend source's upstream URL>" \
  MODULE="<the confirmed config.yaml module key>" \
  MODULE_PATH="<that module's subtree path>" \
  BRANCH="<the ref the baseline was detected on>" \
  BASE_SHA="<detected-baseline-sha>" \
  "$SKILL_DIR/scripts/in-progress.sh"
```

**Record the confirmed module on the anchor, in its own call, immediately** — the `in-progress.sh` write above put it in the manifest's `frontend.template` only, and nothing else records it this run. Pre-flight records `FRONTEND_TEMPLATE` only from a *pre-existing* `frontend.template` block (empty on this first bootstrap), and Phase 3's frontend arm hard-refuses on an empty `FRONTEND_TEMPLATE` — so without this write the run deadlocks at classification:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" FRONTEND_TEMPLATE="<the confirmed config.yaml module key>"
```

Relay which module and which commit the user confirmed, and that the block is now recorded — the next frontend run of this component reads it instead of detecting anything. **Then return to the resolve-and-validate block above**: it finds the just-written `frontend.sha` in the manifest and validates baseline and target as on any other frontend run.
