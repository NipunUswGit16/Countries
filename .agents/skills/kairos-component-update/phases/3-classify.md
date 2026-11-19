## Phase 3: Classify the template changes

PHASE_KEY: i82l699l
(Proof-of-load: this phase's entry script refuses to run without `PHASE_KEY=i82l699l` in its environment. The key is stated only in this file — never copy it into SKILL.md or another phase.)

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); SYNTH=$(ctx SYNTH); CACHE=$(ctx CACHE); BASE=$(ctx BASE); TARGET=$(ctx TARGET)
# Arm guard, mirroring the frontend block below: a frontend run pasted into this
# block would classify frontend SHAs against the TEMPLATE mirror — `CACHE` is
# non-empty on a frontend run too, so an empty-value check would not catch the
# swap. `build-manifest.sh` does eventually hard-fail on it (its upgrade-file
# walk over `$BASE..$TARGET` in `$CACHE` errors on SHAs the template mirror
# doesn't know), but only after the classification diff already ran, and with
# git's own error rather than a message naming the actual mistake — this guard
# catches it immediately and says what went wrong.
# Bare read, not `ctx`: this guard only needs to catch the one dangerous value
# (`frontend`) and isn't otherwise consumed here — SYNTH/CACHE/BASE/TARGET
# already went through `ctx` above — so an absent or not-yet-recorded value
# safely falls through to "not frontend" without an extra FAIL line for a key
# this block doesn't depend on.
RUN_SOURCE=$(sed -n 's/^RUN_SOURCE=//p' "$RUN/context.env")
[ "$RUN_SOURCE" = frontend ] \
  && { echo "FAIL: this is the template block but RUN_SOURCE=frontend — run the frontend arm below" >&2; exit 1; }
export SYNTH CACHE BASE TARGET RUN
PHASE_KEY=i82l699l "$SKILL_DIR/scripts/build-manifest.sh"
```

Every one of those five comes off the run-context anchor, not from the Phase 1 / Phase 2 / Phase 2.5 tool calls that established them (SKILL.md → Run-context anchor). Classification is the phase where trusting conversation memory is cheapest to get wrong and dearest to detect — but not because an *empty* value slips through: `build-manifest.sh` hard-fails immediately if `SYNTH`, `CACHE`, `BASE`, `TARGET` or `RUN` is unset. What the anchor read actually guards against is a **stale but non-empty** value — a `$SYNTH` left over from an earlier materialize call, or a `$BASE`/`$TARGET` recalled from a superseded resolution. That passes the non-empty check just as cleanly as a correct one, and the classifier then diffs the wrong tree and produces a small, plausible, wrong bucket set instead of an error — and Phase 5 then merges it.

**Frontend run (`RUN_SOURCE=frontend`): same phase, two different inputs.** Classification is source-*parameterized*, not source-aware. It runs on the two synthetic trees `materialize-frontend.sh` built, which are already **mount-mapped and create-substituted** — so a row's path is the component path exactly as on a template run, and every bucket, the rename re-pairing, the raw-bytes refusal and the tree binding mean precisely what they mean below. The mechanics are unchanged; what changes is that the `CACHE` the script gets is the **frontend mirror** (`FRONTEND_CACHE` on the anchor, established by pre-flight check 8.6 — **never `CACHE`**, the template mirror, in which none of this run's SHAs resolve and none of this module's upgrade-files exist) and that upgrade-file collection is scoped to the run's module directory (`reference/upgrade-files.md` → *A third source*), so a **sibling** module's breaking change landing in the same range never becomes a step in this plan. Nothing here hardcodes a module name — it comes off the anchor:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); SYNTH=$(ctx SYNTH); BASE=$(ctx BASE); TARGET=$(ctx TARGET)
RUN_SOURCE=$(ctx RUN_SOURCE)
# FRONTEND_TEMPLATE and FRONTEND_CACHE are legitimately absent on a template run
# (SKILL.md → Run-context anchor), and for FRONTEND_TEMPLATE empty is exactly what keeps
# collection at `.kairos-updates/` there — so both are read bare, not through `ctx`.
FRONTEND_TEMPLATE=$(sed -n 's/^FRONTEND_TEMPLATE=//p' "$RUN/context.env")
FRONTEND_CACHE=$(sed -n 's/^FRONTEND_CACHE=//p' "$RUN/context.env")
# Arm guard, two distinct failures with two distinct remedies:
#  - RUN_SOURCE != frontend: a template run pasted into this block would classify with
#    no module scope and collect every module's upgrade-files, reading as a bigger
#    migration rather than as a mistake. Remedy: run the template block above.
#  - RUN_SOURCE = frontend but FRONTEND_TEMPLATE empty: the anchor lost (or never
#    recorded) the module. Do NOT run the template block — re-record FRONTEND_TEMPLATE
#    from the manifest's frontend.template (or its live frontend.in_progress block),
#    or re-run pre-flight MODE=continue, which records it from the manifest.
[ "$RUN_SOURCE" = frontend ] \
  || { echo "FAIL: this is the frontend arm but RUN_SOURCE=$RUN_SOURCE — run the template block above" >&2; exit 1; }
[ -n "$FRONTEND_TEMPLATE" ] \
  || { echo "FAIL: frontend run but FRONTEND_TEMPLATE is empty on the anchor — re-record it from the manifest's frontend.template (or its live frontend.in_progress block), or re-run pre-flight MODE=continue, then re-enter this arm" >&2; exit 1; }
# The history the walks read is the FRONTEND source's. An empty key here is a lost
# anchor, and falling back to the template mirror is the one wrong answer that still
# exits 0 (zero upgrade-files, "success"), so it stops instead.
CACHE=$FRONTEND_CACHE
: "${CACHE:?FAIL: FRONTEND_CACHE missing from the anchor — pre-flight check 8.6 establishes the frontend mirror on a frontend run; classifying against the TEMPLATE mirror resolves none of this run's SHAs and collects none of this module's upgrade-files}"
export SYNTH CACHE BASE TARGET RUN
MODULE=$FRONTEND_TEMPLATE PHASE_KEY=i82l699l "$SKILL_DIR/scripts/build-manifest.sh"
# Atomic re-run unit with the classification above: SNAP_SOURCES is truncated
# whole at the top of build-manifest.sh, so lib's source rows survive a Phase 3
# redo only because collect-lib.sh re-runs immediately after and re-appends them.
# Never stamp, cache, or skip collect-lib.sh relative to build-manifest.sh —
# any Phase 3 redo (including Phase 5's no-binding remedy) re-runs both.
PHASE_KEY=i82l699l "$SKILL_DIR/scripts/collect-lib.sh"
# Frontend pin-compare — the third member of this atomic frontend-arm unit. It reads the
# Kairos (`@ifs-kairos/*`) and Helix (`@ifs-ds/*`) specifiers the template pins in the
# synthetic TARGET tree's mount `package.json` against the component's CURRENT mount
# manifest, and writes one verdict row per template-pinned package into
# `$RUN/pin-compare.tsv` (`equal` / `behind` / `ahead`). It closes the gap the 3-way merge
# and Model-A lib collection cannot: a pin bump that landed BEFORE this run's frontend BASE
# never opens `package.json` in the merge, and lib collection never parses npm versions —
# so a component silently stays behind after a "green" run (notes-demo stayed on 0.9.1).
# SYNTH is exported above; MOUNT and RUN_SOURCE it reads off the anchor itself.
PHASE_KEY=i82l699l "$SKILL_DIR/scripts/frontend-pin-compare.sh"
```

`build-manifest.sh` **validates `MODULE` against the source's `.kairos-updates/config.yaml` at TARGET** when that file exists and refuses an undeclared key: scoping the walks to `.kairos-updates/<module>/` when no such directory exists collects nothing and still exits 0, which reads as "this range carried no migration steps". A declared module with genuinely zero upgrade-files in range stays a success.

**Library-module collection (`kind: library`) is not a sibling of the template-kind walk.** `collect-lib.sh` enumerates `kind: library` modules from the source `config.yaml` at TARGET and walks `.kairos-updates/<module>/` over the same `BASE..TARGET`, **irrespective of which template the component mounts**. Lib is a dependency, never merged; its upgrade-files are consumer-facing executor transforms, snapshotted into the shared `$RUN/upgrades/` with provenance `<libmodule>:.kairos-updates/<libmodule>/…`. It writes `lib-upgrades-added.{txt,tsv}` / `lib-upgrades-modified.txt` and records `LIB_MODULES=present|none` on the anchor (absent by design on a template run). "No lib files in range" is an empty-but-present list under `present`, never a missing file. It also writes `lib-supersede-edges.tsv` (the `supersedes:` edges for `kind: library` modules, same schema and direction rule as the template's `supersede-edges.tsv`), truncated up front so a `LIB_MODULES=none` run still leaves it present-and-empty for `supersede-check.sh`.

**Pin-compare (`frontend-pin-compare.sh`) is a compare, not a collection, and it changes nothing else in this pipeline.** It leaves BASE detection, the 3-way merge, bellwether scoring (`package.json` is never hashed as a whole-file baseline), and `kind: library` Model-A collection (still a SHA range, no npm parsing) exactly as they were. It reads two manifests and writes `$RUN/pin-compare.tsv` — `package <TAB> verdict <TAB> component-spec <TAB> template-spec`, one row per template-pinned Kairos/Helix package, sorted by package — and records `PIN_COMPARE=present|none` on the anchor. Verdicts are by **resolved minimum** of the npm specifier: `^0.9.1` vs `0.10.1` is `behind`, `^0.10.1` vs `0.10.1` is `equal`, `0.11.0-beta.615` vs `0.10.1` is `ahead`. A template-pinned key the component **lacks** is `behind` (a dropped dependency, component-spec `-`); a `@ifs-kairos/*` the component added that the template does **not** pin is left alone (no row — it is not "behind the template"); a non-semver component pin (a `link:` / `file:` / `workspace:` co-dev override) is `ahead` so the executor never overwrites it. The planner (Phase 6) turns a `behind` row into a single bump task and an `ahead` row into a recorded skip-downgrade; `equal` produces nothing. Like `collect-lib.sh`, it **idles on a template run** — `PIN_COMPARE` absent is the template-run record. Full mechanics in the script header; the artifact and anchor key are indexed in `reference/state-files.md`.

`$RUN` (`.kairos/migration/state`) is gitignored scratch — it also holds the per-component template clone (`$RUN/template`, `$CACHE`). The one committed migration artifact — `PLAN.md` — lives beside it at `.kairos/migration/PLAN.md` (Phase 6), so it survives a swept state dir. Full layout: `reference/structural-merge.md`.

The script diffs the two synthetic commits, skips `.kairos-updates/` entries, and classifies every changed file into `$RUN/classification.tsv` (columns: bucket, status, template path, destination path, old template path for template-side renames, component path for a detected component-side move, tag). Because the trees are pre-substituted, template path and destination path now carry the same value. It also writes `$RUN/summary.txt` (bucket tallies) and an executable `$RUN/query.sh <bucket> [column]` — read those instead of `classification.tsv` itself (SKILL.md → Artifact discipline).

Alongside them it writes `$RUN/classification-trees.tsv` (`side <TAB> tree-oid`), the identities of the two synthetic trees these rows were derived from. Phase 5's merge re-verifies it against `$SYNTH` and refuses on a mismatch, so **re-materializing `$SYNTH` after this phase means re-running this phase** before Phase 5 — the rows are only valid against the trees they were diffed from.

Buckets (full criteria: `reference/structural-merge.md`):

- `merge-pipeline` — changed in template, present in component; clean-vs-conflict is decided in Phase 5, not here
- `added-mechanical` — new file, absent in component, light addition
- `added-heavyweight-ask-user` — new top-level dir at component root with >3 files, or any new `cmd/<name>/` (any size)
- `deleted-by-template-mechanical` — template removed it, component still has the unmodified file, and the deletion is scattered (doesn't empty a directory)
- `deleted-heavyweight-ask-user` — template empties a whole subtree (≥3 tracked files) — batched user checkpoint, mirroring `added-heavyweight-ask-user`; emptied dirs listed in `$RUN/deleted-heavyweight-dirs.txt`
- `noop-already-deleted` — both sides deleted it; nothing to do
- `modify-delete-for-ai` — one side modified, the other deleted (either direction, including "component deleted a file the template modified" — must never be silently resurrected). If git detects a likely component-side *move*, the best-guess new path is attached in `component_path` to inform the decision — never auto-merged (see `reference/structural-merge.md` → Component-side rename detection). Binaries never land here: a customized binary the template deleted goes to `binary-for-user` instead, and so does a rename-plus-mods whose local copy is binary (`reference/structural-merge.md`)
- `renamed-mechanical` — pure rename, component hadn't customized the file
- `renamed-with-mods-for-ai` — rename + content change; needs intent inference
- `binary-for-user` — binary file; never auto-merge, never send to AI. A template-*deleted* binary rides the same bucket with status `D`, `theirs` meaning adopt the deletion
- `unknown-status` — a git status the classifier doesn't route (safety valve); inspect manually in Phase 5

**Paths are raw bytes, and two of them cannot ride the format.** Every row carries the file's real name — the diff *and* the upgrade-file discovery walks are read with `-z`, because `core.quotepath=off` only covers bytes ≥ 0x80 and a `"` or `\` in a filename would otherwise arrive C-quoted and either reach Phase 5 as a path that exists nowhere or drop an upgrade-file from the migration without a trace. A name containing a **TAB or a newline** cannot be represented in a TAB-delimited row at all, so the script **hard-fails naming the file**: the remedy is to rename it in the template (or the component) and redo Phase 2.5 + this phase — repeating this phase alone reproduces the refusal, and no classification is left behind for Phase 5.

**Rename re-pairing.** When git fails to pair a file inside a directory-wide rename, it splits into a fake delete + add and loses its merge base. The script recovers those (rules in `reference/structural-merge.md`), tags them `paired-by-dir-rename` in column 7, and lists them in `$RUN/dir-rename-pairs.tsv` — **eyeball the pairings**; they are inferred, not certain.

Placeholder substitution happened one phase earlier, in Phase 2.5, and who did it depends on the source: on a template run it's the Kairos CLI's own `component create` (`materialize.sh`); on a frontend run it's this skill's own pinned replacement map (`scripts/lib/frontend-substitute.sh`, sourced by `materialize-frontend.sh`) — there is no CLI create step for a frontend mount. Either way, `$RUN/surviving-tokens.tsv` from Phase 2.5 is the feedback channel for tokens that substitution missed.

It also produces the upgrade-file lists: `upgrades-added.txt`, `upgrades-modified.txt` (amended since the baseline — the fix may matter even if the upgrade was already applied), and `legacy-upgrade-commits.txt`.

**Read `$RUN/snapshot-refusals.tsv` if it is non-empty** (`slug <TAB> source <TAB> reason`; this phase replaces only its own rows on a re-run and leaves Phase 3.5's / collect-lib's module-prefixed ones standing). Two distinct reasons land here, with different remedies. Most rows are a body the script could not read at all — `git show` failed on it (a pruned or corrupted object in the mirror) — those slugs are still in the lists above, and re-running this phase reads the same object and fails the same way, so the remedy is to re-fetch the template mirror, or carry the row forward and tell the planner to disposition that slug explicitly against an unreadable body. A row whose reason names `mv failed` is different: the body WAS read, but writing it into `$RUN/upgrades` failed — check that the directory is writable and has space, then re-run this phase, which does clear it (unlike the unreadable-object case). A **zero-byte** snapshot is not on this list and is not a failure — an upgrade-file committed empty is served as an empty body (`reference/upgrade-files.md`).

**Scope signal — advisory, and it supersedes Phase 2's.** The merge-pipeline count is known now (template changes overlapping files this component customized) — the actual driver of merge cost that Phase 2's commit count could only proxy for.

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN "$SKILL_DIR/scripts/scope-overlap-check.sh"
```

- `ADVISORY:` on stdout = overlap exceeds the threshold (default 30; tune with `THRESHOLD=<n>` if the project's norm differs).
- **Relay it in one line and keep going** — say the run is large and what that costs (more conflicts in Phase 5, a longer plan, a bigger review), in plain language rather than bucket names. **Do not turn it into a question.**
- The only scope lever left is a smaller `TARGET`, which defers the remainder to a second migration run; a component being updated *to a specific template SHA* (a release tag, a feature-branch tip) frequently cannot take that trade at all, so asking manufactures a choice with one real answer. Scope was already settled when `TARGET` was chosen (Phase 2) — a user who wants a smaller step can still say so there.
- Exit 2 means either `$RUN/summary.txt` is missing or unreadable — `build-manifest.sh` didn't do its job — or its merge-pipeline count is present but non-numeric (corruption). Either way, fix that before continuing.
