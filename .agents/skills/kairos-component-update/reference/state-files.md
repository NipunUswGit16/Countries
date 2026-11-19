# Run-state files (`$RUN`)

`$RUN` is `.kairos/migration/state/` — gitignored scratch holding every per-run artifact. Load this doc when you need to know what a file is, who owns its format, or whether losing it costs anything. The script headers remain the source of truth for column layouts; this is the index.

**The index is complete for every non-dot artifact, on purpose** — every such family the run writes has a row, including the internal ones: the same-run temporaries that aren't dot-prefixed, the gates' per-label build/test stems, the scratch blob trees, and `materialize.sh`'s transient workdir `mat/`. A lint holds that automatically: every literal `$RUN/<name>` a script writes to, that doesn't begin with a dot, must appear in this file or on the lint's own declared-exemptions list (empty today — every current target is indexed) — a name built from a variable (`$MAT/…`, `$OUT.*`) is outside what a grep can find, so those families are curated here by hand instead, and "not in the index" is still never a reason to go reading a script to find out what a file is. **Dot-prefixed scratch is out of the lint's reach entirely** — the grep that drives it only matches names starting with a letter or digit — so *Internal scratch*, near the bottom, is curated by hand and on trust rather than enforced; treat a dot-prefixed name missing from that section as an omission worth reporting, not as proof the lint would have caught it. Where the index is *deliberately* thin is attribution for those scratch families — the row says whose it is and that it is disposable, not the column layout, because nothing outside the writer may read them.

**Two rules that apply to every file here.** A file's **writer script is its format owner** — never hand-append to a file that has one. And an artifact you cannot find is not an artifact that was never written: re-run its producer (they are all re-run safe) rather than reasoning from its absence.

`.kairos/migration/PLAN.md` sits *beside* the state dir, not in it, so no `$RUN`-scoped sweep touches it as a side effect — but both sweepers reach it deliberately: pre-flight's fresh-mode reset `rm -f`s it in its own deferred check 10 (`reference/pre-flight.md` check 10 carries the why — a tracked deletion must not wedge the next re-run), and abort's first pass deletes it with everything else beside the state dir (`reference/abort.md`). Do not plan on `PLAN.md` surviving an abort. `.kairos/intent.md`, `.kairos/manifest.yaml` and `.kairos/migration-log.md` are committed component files, not run state.

Two of those three are machine-parsed and therefore have format owners of their own — `in-progress.sh` for `.kairos/manifest.yaml` (five actions: `set` / `clear` / `advance` / `bootstrap` / `record-floor` — `record-floor` appends one `{upgrade_file, module, sha}` element to the `frontend.outstanding_floors` list, the cross-run debt flag re-surfaced when a crossed template floor is unmet and the frontend run is declined; a frontend `advance` auto-clears the elements its new baseline now contains) and `promote-intent.sh` for `.kairos/intent.md` (`append` / `retire` / `update`). Neither is covered by the artifact-writer lint, which is scoped to `$RUN/` paths; being committed is what put them outside it, not being exempt from the rule. Use the owner, never a hand edit — **`promote-intent.sh` carries two such exceptions, both because the owner cannot express the repair; this is the line-level one.** A line in `.kairos/intent.md` that `intent-check.sh` reports unparseable *as a line* (a `*` or `+` marker, a `-` with no following space, a tab-indented bullet) is not an entry, so `promote-intent.sh`'s `MATCH` — a lookup by the fact in a `- <date>: <fact>` bullet — can never name it. Phase 5's re-confirm step therefore deletes that one stray line by hand while appending the well-formed entry, and says so in the migration log. (The other exception is the whole-file repair for a NUL byte or an unresolved merge conflict, where the owner refuses every action on the file — see `reference/intent-guard.md`.) The orphaned column-0 `guard:` is **not** in the exception: `retire` and `update` repair it themselves, **scoped by ownership** — a column-0 `guard:` is owned by the nearest **preceding** column-0 `-` bullet, and a hand delete would silently flip its entry from `UNPARSEABLE` to `ACTIVE` de-guarded, which is the whole hazard the single-writer rule exists to prevent. The ownership rule, the adoption-vs-sweep behaviour, the second-orphan-of-a-run qualifier and the protect-vs-refuse verdict all live in `reference/intent-guard.md → Per-line unparseable findings`; their canonical, clause-by-clause statement is `promote-intent.sh`'s own header. (`.kairos/migration-log.md` is deliberately not in that class: it is the human narrative, and nothing parses it.)

## Survives a sweep

Pre-flight's fresh-mode sweep and abort's cleanup both delete everything under `$RUN` **except** these. Never clear them by hand — they are tens of MB of git objects and are refreshed in place on the next run.

| Path | What |
|---|---|
| `$RUN/template` | mirror clone of the template repo |
| `$RUN/common` | mirror clone of `kairos-component-common` |
| `$RUN/frontend` | mirror clone of the frontend source repo (frontend runs only; established and refreshed by pre-flight check 8.6, recorded on the anchor as `FRONTEND_CACHE`, and spared by the fresh-mode sweep exactly as `$RUN/template` is; addressed through `FRONTEND_CACHE`/`FE_CACHE`, never a literal path — `materialize-frontend.sh` creates or refreshes it idempotently too, for a caller that skipped pre-flight) |

## Phase 1 — pre-flight, and model resolution

| Artifact | Writer | Read by |
|---|---|---|
| `context.env` | `record-context.sh` (format owner); values recorded by `pre-flight.sh`, `clone-common.sh`, `materialize.sh`, `materialize-frontend.sh` (which writes back the *resolved* `FRONTEND_MODULE_PATH` / `FRONTEND_CACHE` / `FRONTEND_MOUNT`) and by you | **every phase start** — the run-context anchor. Re-read it here, never trust conversation memory. Also read by name by `wrong-target-check.sh` (`TEMPLATE_PATH`), `plan-completeness.sh` (`COMMON_MODULES`) and `clone-common.sh` itself (`RUN_SOURCE`, to skip the common side entirely on a frontend run) — none of the three writes it |
| `model.txt` | `resolve-models.sh` | `log-spawn.sh`, which refuses every dispatch row while it is absent and refuses a `MODEL` that is not the pin for its `TIER`; Phases 5, 7, 8 for the tier pins; `continue` re-reads it |

`context.env` is the one file whose loss is not cheap: it is what makes compaction equivalent to a resume. If it is gone, values must be re-established phase by phase. The **canonical key list lives in SKILL.md → Run-context anchor** (`reference/continue.md` restates it in full, and a lint holds the two in correspondence); `SKILL_DIR` is on it, recorded by pre-flight, because after a compaction it is what every phase code block uses to find these scripts at all.

### Anchor read modes — `ctx`, hard guards, and bare reads

SKILL.md carries the contract: every phase code block opens with the `ctx` preamble, `ctx` prints a `FAIL:` line but exits 0 (so you must read stderr and never proceed on an empty value), and the always-optional key list. This section is the "why" behind the three read modes and what each optional key's absence means.

**A hard guard aborts the block where empty is destructive.** For the few blocks where an empty value would be destructive rather than merely wrong — a squash reset, a rollback, the structural commit's subject, every frontend mount-cwd gate — the block adds a hard guard after the `ctx` reads:

```bash
: "${KEY:?FAIL: KEY missing — stop}"
```

It aborts a non-interactive shell before the next statement runs. Each phase file that carries one states it there; SKILL.md and this section only name the mechanism.

**The always-optional keys are read with a bare `sed`, because their absence is itself the answer.** A `ctx` read of one of these would report the quietest correct path as a loss, so they are read with the bare `sed -n 's/^KEY=//p' "$RUN/context.env"` instead:

- `SQUASH_ON_FINISH` — absent means the run was not invoked with `--squash-on-finish`.
- `COMMON_CACHE`, `TEMPLATE_PATH`, `TEMPLATE_LOCAL_BRANCH` — absent when the invocation supplied no local path / clone.
- `TARGET_REF` — absent means the invocation named no ref; Phase 2's default chain takes over.
- `MIGRATION_BRANCH` — absent means `--no-branch` (the manifest's `in_progress` block omits `branch:` to match).
- `COMMON_MODULES` — absent by design on a **frontend** run.
- `LIB_MODULES` — absent by design on a **template** run, the mirror image.
- `PIN_COMPARE` — absent by design on a **template** run (like `LIB_MODULES`); on a frontend run `present` once `frontend-pin-compare.sh` wrote `pin-compare.tsv`, or `none` when the template pins no comparable Kairos/Helix key.
- **every `FRONTEND_*` key** — their absence is the record of something. No `FRONTEND_*` key other than `FRONTEND_INTENT` (which every run records) means the component has no frontend source — no `frontend:` block and no `web/package.json` — the one state that must stay completely silent.

**A block may also bare-read a normally-`ctx`-read key where its absence is recoverable right there.** Keys such as `RUN_SOURCE`, `SYNTH`, `STRUCTURAL_SHA`, `PREV_SHA`, `PREV_BRANCH` are usually `ctx`-read, but a specific site may bare-read one where the absence has a local fallback, a re-derivation, or is simply not-yet-established early in the run. The block says so in a comment on the read, and it is that local justification — not the always-optional list — that sanctions the bare read.

**A block that establishes values rather than consuming them is marked `# anchor-exempt`.** Such a block records values into `context.env` instead of reading them, so it has no `ctx` preamble; it declares this with an `# anchor-exempt: <why>` comment, the `<why>` being mandatory.

## Phase 2 — baseline detection (bootstrap only)

Written only when the component has no recorded baseline. One use per component, ever.

| Artifact | Writer | Read by |
|---|---|---|
| `bellwether-scores.txt`, `bellwether-top.txt`, `bellwether-suggestions.txt` | `bellwether-detect.sh` | Phase 2, to propose a BASE |
| `widescan-scores.txt`, `widescan-top.txt` | `bellwether-detect.sh` | Phase 2 — the wider fallback scan |
| `widescan-blobcache.tsv`, `.widescan-blobcache-stamp` | `bellwether-detect.sh` | internal to the wide scan — a stamped blob cache so a re-run does not re-read every candidate commit. No downstream reader; safe to delete (the next run rebuilds it) |

## Phase 2.5 — materialization

| Artifact | Writer | Read by |
|---|---|---|
| `synthetic/` | `materialize.sh`, `materialize-frontend.sh` | **`$SYNTH`** — the throwaway repo holding both template sides under side tags. Everything downstream reads blobs from here |
| `materialization.txt` | `materialize.sh`, `materialize-frontend.sh` | Phase 2.5, relayed to the user; the frontend arm adds `source:`, `module_path:`, `mount:` and `cli: none` lines |
| `surviving-tokens.tsv` | `materialize.sh`, `materialize-frontend.sh` | Phase 3; Phase 8's feedback to the source-repo author (unsubstituted placeholders are a template bug — on a frontend run, a frontend-template bug) |
| `materialize-<side>.log`, `materialize-<side>.attempt1.log` | `materialize.sh` | the Kairos CLI's own output per side, relayed on a failure; `attempt1` exists only where a `component create` was retried (`reference/materialization.md`) |
| `mat/` | `materialize.sh` | internal working dir, addressed only through `$MAT`/`$MAT_ABS` (never a literal `$RUN/mat`) — `wt-<side>` worktrees and `out-<side>/<component>` raw CLI output; removed on success, debris otherwise. Never authoritative: everything downstream reads blobs from `synthetic/`, not here (`materialize.sh` header) |
| `mat-frontend/` | `materialize-frontend.sh` | the frontend arm's internal extraction dir (`tree-<side>` per side), separate from `mat/`; removed on success, debris otherwise |

`synthetic/` is stamped: an unchanged re-run of `materialize.sh` reuses the trees. If it is stale or gone, re-run it — `structural-merge.sh` and `apply-ask-user.sh` both hard-stop rather than merge against a missing side tag.

## Phase 3 — classification

All written by `build-manifest.sh`, all regenerated on every run.

| Artifact | Read by |
|---|---|
| `classification.tsv` | the central artifact: one row per changed file, one bucket each. Query it through `query.sh`, don't `cat` it |
| `classification-trees.tsv` | `side <TAB> tree-oid` — the two synthetic trees `classification.tsv` was derived from, **and `build-manifest.sh`'s completion stamp** (absent = the `$RUN` artifacts are a fragment). `structural-merge.sh`, `apply-ask-user.sh` and `gate.sh` (`postmerge`) each re-verify it against `$SYNTH` before touching the tree and refuse on a mismatch (re-run Phase 3) |
| `summary.txt` | bucket tallies; `scope-overlap-check.sh` keys its advisory off the merge-pipeline count |
| `query.sh` | executable, generated per run: `query.sh <bucket> [column]`. **The documented read path** for classification |
| `upgrades/` | snapshotted upgrade-file bodies, one `<slug>.md` each — served one at a time by `next-upgrade-file.sh`. Snapshots, so the plan cannot drift with the template tip. A **zero-byte** body is legitimate (the source committed an empty file); `next-upgrade-file.sh` serves it with an `EMPTY:` line, rc 0 |
| `snapshot-refusals.tsv` | `slug <TAB> source <TAB> reason` — capture refusals (a `git show` that FAILED, never an empty body). Written by `build-manifest.sh` (Phase 3), `collect-common.sh` (Phase 3.5), and `collect-lib.sh` (Phase 3 frontend arm). Each replaces only its OWN rows on a re-run (template rows a bare path; common and lib a `<module>:` prefix — the `^[^:]+:\.kairos-updates/` shape is shared by common and lib and is safe only because their `RUN_SOURCE`s are disjoint). Read by `next-upgrade-file.sh`, whose exit 5 points here |
| `upgrades-added.txt`, `upgrades-modified.txt` | the template upgrade-file lists — `plan-completeness.sh` requires a disposition for every slug in each; `next-upgrade-file.sh` also takes either as its `LIST` |
| `frontend-floors.tsv` | `<upgrade-file-path> <TAB> module <TAB> floor-sha` — one row per crossed upgrade-file that declares a `requires-frontend:` floor (column 1 is the EXACT path string as it appears in `upgrades-added.txt` / `upgrades-modified.txt`). Read by Phase 8's frontend-compatibility-floor check (`frontend-floor-check.sh`) and, on a decline, recorded into the manifest via `in-progress.sh ACTION=record-floor`. An empty file (created, no rows) = no floor in range = the common case = zero behavioural change |
| `upgrades-added.tsv` | `<add-commit-sha> <TAB> <path>` — not a `plan-completeness.sh` input. Read back only by `build-manifest.sh` itself, in the same run, to pick which commit each added upgrade-file's body snapshot comes from |
| `supersede-edges.tsv` | `module <TAB> superseder-stem <TAB> superseded-stem <TAB> kind` (`added`\|`modified`) — one row per `supersedes:` edge `build-manifest.sh` parsed from the template upgrade-files, after applying the direction rule (backward or absent only; a forward or cross-module declaration is WARNed and dropped). Read by `supersede-check.sh` (the supersede gate, Phase 6) and by the planner to defer/announce supersede skips. This collector's OWN file — never shared, so a plain truncate is safe. An empty file (created, no rows) = no supersede declared in range = the common case. A FAILED emission (temp file, list build, or the classification pass) REMOVES the file rather than leave it empty, so the gate refuses (exit 2) instead of reading an empty file as clean |
| `upgrade-snapshot-sources.tsv` | provenance for each snapshot; also appended by Phase 3.5 and by `collect-lib.sh` on the frontend arm (`build-manifest.sh` truncates this file whole, so lib rows survive a Phase 3 redo only because `collect-lib.sh` re-runs immediately after) |
| `dir-rename-pairs.tsv`, `dir-rename-maps.tsv`, `component-rename-map.tsv` | directory-rename detection; Phase 6's follow-up sweep reads the pairs |
| `deleted-heavyweight-dirs.txt` | Phase 5's batched delete question |
| `binaries-template.txt` | which template paths are binary — feeds the `binary-for-user` bucket |
| `legacy-upgrade-commits.txt` | upgrade-files predating the snapshot mechanism |
| `diff.tsv`, `diff.raw.tsv`, `deleted-list.txt`, `heavyweight-roots.txt` | internal to classification — no downstream reader |
| `classification.tsv.tmp`, `.del-cand-dirs.txt`, `.del-emptied.txt`, `.del-emptied-sorted.txt` | same-run temporaries of the re-bucketing passes (the `.tmp` is an in-place rewrite of `classification.tsv`). No reader, no value after the script returns |

`collect-lib.sh` also writes, on a frontend run only (same Phase 3 block, immediately after `build-manifest.sh` — the two are one atomic re-run unit):

| Artifact | Read by |
|---|---|
| `lib-upgrades-added.txt`, `lib-upgrades-modified.txt`, `lib-upgrades-added.tsv` | the library-module upgrade-file lists — also gated by `plan-completeness.sh` when the anchor records `LIB_MODULES=present`. Provenance TSV is `add-sha <TAB> module <TAB> path`. Bodies land in the shared `upgrades/` dir |
| `lib-supersede-edges.tsv` | `module <TAB> superseder-stem <TAB> superseded-stem <TAB> kind` — the `kind: library` supersede edges `collect-lib.sh` parsed (same schema and direction rule as `supersede-edges.tsv`). This collector's OWN file. Truncated up front alongside the lib lists — so a `LIB_MODULES=none` run still leaves it present (empty), keeping `supersede-check.sh`'s present-witness / absent-edge-file guard from a false exit 2. A FAILED emission removes it (same contract as `supersede-edges.tsv`), which is what a genuine exit 2 here means. Read by `supersede-check.sh` |

`frontend-pin-compare.sh` also writes, on a frontend run only (same Phase 3 block, the third member of the atomic re-run unit after `build-manifest.sh` and `collect-lib.sh`):

| Artifact | Read by |
|---|---|
| `pin-compare.tsv` | `package <TAB> verdict <TAB> component-spec <TAB> template-spec`, one row per template-pinned Kairos (`@ifs-kairos/*`) / Helix (`@ifs-ds/*`) package, sorted by package; verdict ∈ `equal` / `behind` / `ahead`. Read by the **planner** (Phase 6, `agents/planner.md`) — `behind` → one bump task, `ahead` → recorded skip-downgrade, `equal` → nothing — and summarized by Phase 8 finalize into `.kairos/migration-log.md`. Present-but-empty = the template pins none of them (anchor `PIN_COMPARE=none`); it is **not** an upgrade-file list and is not gated by `plan-completeness.sh` |

## Phase 3.5 — common-library collection

All written by `collect-common.sh`, with one exception noted below.

| Artifact | Read by |
|---|---|
| `template-go.mod` | written by **`extract-template-gomod.sh`** (format owner, not `collect-common.sh`) — the template's `go.mod` at `TARGET`, the version source for every module's range. Read by `codev-check.sh`, `wrong-target-check.sh` (by name), and `collect-common.sh`, which hard-requires it as `TEMPLATE_GOMOD` (the co-dev arm's `TEMPLATE_GOMOD_DIR` subtlety: `phases/3.5-collect-common.md`) |
| `common-resolution.tsv` | per-module BASE/TARGET version resolution and its verdict |
| `common-upgrades-added.txt`, `common-upgrades-modified.txt`, `common-upgrades-added.tsv` | the common upgrade-file lists — also gated by `plan-completeness.sh` |
| `common-supersede-edges.tsv` | `module <TAB> superseder-stem <TAB> superseded-stem <TAB> kind` — the common supersede edges `collect-common.sh` parsed (same schema and direction rule as `supersede-edges.tsv`). This collector's OWN file — never the whole-file-truncation-on-redo hazard the shared refusal ledger documents, because each collector writes its own edge file. A FAILED emission removes it (same contract as `supersede-edges.tsv`). Read by `supersede-check.sh` |
| `common-unresolvable.txt` | modules whose range could not be resolved — the batched skip/provide-a-ref/abort question |
| `common-legacy-upgrade-commits.txt` | pre-snapshot common upgrade-files |

Plus one hand-written input: `ref-overrides.tsv` (`module <TAB> ref`), which **you** write from the "provide a ref" answers and pass back as `REF_OVERRIDES` on a re-run of `collect-common.sh`. It is what makes that answer mechanically actionable instead of hand-collected.

## Phase 4.5 — test baseline

| Artifact | Writer | Read by |
|---|---|---|
| `test-command.txt` | `write-test-commands.sh` (format owner), positional contract in `reference/gates.md` | every gate (`gate.sh`, all labels) and `producer-idempotence.sh` directly; **not** the executor/verifier — the planner copies the four commands into `PLAN.md`'s `## Test Baseline` and that copy is what they read (`phases/7-execution.md`, `agents/executor.md`) |
| `census-command.txt` | `write-test-commands.sh`, sibling file written in the same call as `test-command.txt` — one line, the census extractor or `no census extractor` (`reference/gates.md` → *The census row*) | `gate.sh` every label (as `CENSUS`) and the Phase 4.5 baseline call of `run-check-modules.sh`; absent = predates the feature, every reader degrades to `INCOMPLETE` |
| `test-baseline.failures.txt` | `run-check.sh` / `run-check-modules.sh` | every later gate — a regression is a failure ID absent from this set |
| `test-baseline.status`, `test-baseline.txt.gz`, `test-baseline.excerpt.txt` | `run-check.sh` | gate evidence; raw output gzipped — except when the compress itself fails (disk-full, interrupted gzip), where `run-check.sh` falls back to a plain `test-baseline.txt` instead of losing the run's output |
| `test-baseline.population.txt`, `test-baseline.skips.txt`, `test-baseline.census.status` | `run-check.sh` via `run-check-modules.sh`'s sweep, only when `CENSUS` is set | `census-diff.sh`'s baseline epoch — the `final` diff's base on the degraded, unattributed path; `.census.status` is `OK`/`MISMATCH`/`ABSENT`/`FAILED` (empty-baseline-population refusal: `phases/4.5-test-baseline.md`) |
| `build-baseline-root.*` | `run-check-modules.sh` (Phase 4.5 **frontend arm**, `CHECK=build`, root cwd) | **frontend runs only** — the root build baseline the Phase 8 frontend final gate's layer 2 reads `build-final-root.*` against (`phases/4.5-test-baseline.md`, `phases/8-finalize.md`) |
| `pre-test-ignored.txt` | `clean-artifacts.sh` `ACTION=snapshot` (format owner) — the ignored-path set captured write-once at the top of Phase 4.5 (rationale: `clean-artifacts.sh` header) | `clean-artifacts.sh` `ACTION=clean` at Phase 8 — the "before" set so only run-created build artifacts are removed; absent → `SKIP`, never a blind `git clean` |

## Phase 5 — structural step

| Artifact | Writer | Read by |
|---|---|---|
| `intent-active.md` | `intent-check.sh` | **the only intent view anything may read** — guard-vetted. Never read `.kairos/intent.md` directly mid-run |
| `intent-quarantined.md`, `intent-unparseable.md` | `intent-check.sh` | the batched re-confirm question |
| `clean-merged.txt` | `structural-merge.sh` | `coverage-blind.sh`; the structural handoff card |
| `conflicts.txt` | `structural-merge.sh` | the conflict-resolver fan-out |
| `merge-errors.txt` | `structural-merge.sh` — one path per line; a rename-flavored row (the error fired before the rename completed) appends the pre-rename old path as a second TAB field, same shape as `binaries.txt` | inspected inline — the script left those working-tree files untouched. On a two-field row nothing exists at the field-1 path yet: the component's copy is still at the field-2 old path, and resolving must settle both (or the old copy rides into the structural commit as an unnamed duplicate) |
| `binaries.txt` | `structural-merge.sh` — one path per line; a rename-flavored row (binary diverted out of a rename-carrying merge row) appends a second TAB field, the pre-rename old path, so the decision stays enactable. Readers take the path from field 1; only `apply-ask-user.sh` consumes field 2 | joins the classifier's `binary-for-user` rows in the batched binary question — and in the two scripts that consume that same union: `apply-ask-user.sh` (which enacts it — a `theirs` on a two-field row also removes the old-path copy) and `gate.sh`'s `postmerge` `ask-user` row (which audits the coverage of what was enacted) |
| `normalized-ours.txt` | `structural-merge.sh` | declared as CRLF→LF policy in the structural log entry — it is policy, not damage |
| `deleted.txt`, `renamed.txt` | `structural-merge.sh` | Phase 6's follow-up sweep (`followup-completeness.sh` reads both by name) — and abort's untracked-debris pass 1 reads `renamed.txt`'s new-path sides (`reference/abort.md`), so losing it degrades abort's automated cleanup to the manual pass |
| `added.txt` | `structural-merge.sh` | the mechanical-addition record for the structural log entry — and **abort's untracked-debris pass 1 is built on it** (`reference/abort.md` intersects it with the untracked set to delete only what the run provably wrote), so it is not reader-less scratch: absent, every leftover template file falls to the manual ask-the-user pass 2. `followup-completeness.sh` reads its two siblings, not this one |
| `base/`, `target/`, `ours/` | `structural-merge.sh` | internal — the three LF-normalized merge inputs per file, extracted so `git merge-file` has real paths to work on. No reader after the merge; safe to delete (a re-run rewrites them) |
| `ask-user-decisions.tsv` | **you** — one of three declared hand-written artifacts | `apply-ask-user.sh`, which is fail-closed on an incomplete set |
| `ask-user-applied.tsv` | `apply-ask-user.sh` | the postmerge gate's `ask-user` coverage row — the only thing that catches enactment being skipped entirely — and the planner, as the recorded outcome of the heavyweight questions it must not re-ask (`agents/planner.md`) |
| `confirmed-deletes.txt` | `apply-ask-user.sh`, for enacted ask-user deletes only — including a renamed binary's pre-rename path removed by a `theirs` decision, and a template-deleted binary's own path, whose `theirs` decision *is* the deletion (outcome `deleted`, nothing written) | Phase 6's stale-reference sweep. Resolver `kept-delete` paths are **not** written here — `followup-completeness.sh` derives them from the resolution ledger instead |
| `resolutions.<slug>.tsv` → `resolutions.tsv` | `log-resolution.sh` (format owner) — `append` from each conflict-resolver into its own shard (exact-duplicate rows dropped), including the reserved `role-switch` shard for in-conversation resolution, so no writer ever targets `resolutions.tsv`; `collect` rebuilds the aggregate from the shards alone, first **materializing** any pre-existing aggregate row no shard carries into the script-owned `resolutions.legacy.tsv` shard (the transition guard for state dirs older than the reserved shard — and what makes the aggregate purely derived state); `reset` clears one shard (`SHARD=<slug>`, or the `role-switch` shard with no `SHARD`) **and always the aggregate**, materializing first so nothing is lost, then the next `collect` rebuilds it. Shards are the durable record; the aggregate is disposable. `legacy` is refused as an `append`/`reset` slug. **Schema: `file <TAB> verdict <TAB> reason <TAB> region`** — `region` is the appended 1-based ordinal of the conflict region within the file, in file order (`-` for a reasoning-bucket row, which has no regions); a row written before the column existed is normalized to `region=-` on read, warned once, never refused | the planner (`ours` rows are dropped template changes, `merged` rows are hand-woven code), `handoff-structural.sh`, `spawn-summary.sh`, and `followup-completeness.sh` — all three scripts read the shards **and** the aggregate, de-duplicated on the row *normalized to four fields first* (a collect writes the normalized twin of a legacy 3-field shard row — exact-row dedup would count the pair twice), so an uncollected ledger is never reported as zero resolutions; plus `dropped-template-changes.sh` (below), a fourth reader of the same shard-and-aggregate shape (selecting `ours` rows only) — the ledger's **fifth** consumer overall, counting `log-resolution.sh` itself as the first |
| `qa-ledger.tsv` | `log-intent.sh` (format owner) | every resolver dispatch, the planner, Phase 8 promotion. Appended **at answer time**, in any phase |
| `coverage-blind.txt` | `coverage-blind.sh` | the planner eyeballs it — clean merges no test can see; `handoff-structural.sh` also reads it, for the count on the structural handoff card |

## Phase 6 — planning

| Artifact | Writer | Read by |
|---|---|---|
| `dropped-template-changes.tsv` | `scripts/dropped-template-changes.sh` | index over the evidence below: `path <TAB> region <TAB> status <TAB> detail`, `status` one of `located` \| `unlocatable` \| `error`. The planner (Step 1.5) and `phases/6-planning.md`, which surfaces a non-zero exit or any `unlocatable`/`error` row as incomplete semantic coverage |
| `dropped-template-changes.txt` | `scripts/dropped-template-changes.sh` | the materialized target-side text of every `located` region — the artifact `agents/planner.md` step 1.5 actually reads for an `ours` verdict, in place of `git show HEAD` (which cannot contain a dropped change) or the ledger's one-line `reason` alone. Re-derives its regions from `$SYNTH`'s `kairos-base`/`kairos-target` tags and the structural commit's parent (`ours`), the same three sides `structural-merge.sh` already merged — see `reference/structural-merge.md` |

## Gates (Phases 5, 7, 8)

Gate artifacts are suffixed by label: `postmerge`, `midplan`, `final`.

| Artifact | Writer | Read by |
|---|---|---|
| `gate-<label>.tsv` | `gate.sh` | the verdict card you relay verbatim; the structural handoff card (`handoff-structural.sh` reads the `postmerge` one by name). Removed at the start of every run of its own label, so an interrupted gate leaves no card rather than a stale `AGGREGATE PASS` |
| `yaml-gate-<label>.tsv` | `yaml-gate.sh` | the gate's YAML row; `followup-completeness.sh` (its skip rows become Phase 6 follow-ups); `handoff-structural.sh` for the `postmerge` label |
| `yaml-gate-<label>.txt` | `yaml-gate.sh` | the short human-readable YAML report — the gate's `yaml` row points at it as evidence beside the TSV |
| `yaml-gate-ack.tsv` | **you** — declared hand-written | `yaml-gate.sh`, to turn a deliberate demotion into an acknowledged skip rather than a block |
| `producer-idempotence-<label>.tsv` | `producer-idempotence.sh` (the gate passes its `LABEL` down; a direct invocation with no `LABEL` writes the base name `producer-idempotence.tsv`) | the gate's producer row for that label; and Phase 6's follow-up catalogue, which reads the **`postmerge`** one **by name** (`followup-completeness.sh`) — its `dirty-tracked` / `untracked-output` / `skip` rows are the plan-blocking producer follow-ups. Its per-label truncation semantics — present-and-empty ("audited no producer") vs absent ("that label's gate never ran") — are `reference/gates.md`'s, canonical there. The consequence that matters *here*: absent at `postmerge`, with `clean-merged.txt` present, is a Phase 6 refusal (exit 2), never an empty catalogue (why the label is load-bearing: `reference/gates.md`) |
| `producer-build.*` | `producer-idempotence.sh` via `run-check-modules.sh` | the build producer's own sweep artifacts (aggregated log, per-module logs and excerpts, `producer-build.modules.tsv`) — the evidence behind a `dirty-tracked` / `untracked-output` / `producer-failed` verdict |
| `build-<label>.*`, `test-<label>.*` | `gate.sh` via `run-check-modules.sh` | the gate's build and test rows, per label (`build-postmerge.status`, `test-final.failures.txt`, …). `handoff-structural.sh` reads `test-postmerge.status` and `test-postmerge.failures.txt` by name. **Cleared at the start of each gate run** (`$OUT.*`, per-module stems included) so a crashed runner's gap reads as a missing file, never as last time's verdict |
| `test-<label>.population.txt`, `test-<label>.skips.txt`, `test-<label>.census.status` | `gate.sh` via `run-check-modules.sh` (delegating to `run-check.sh`'s `CENSUS` pipe), only when `$RUN/census-command.txt` carries a real extractor | `census-diff.sh` — the per-epoch populations it diffs to produce the `census` row (`reference/gates.md` → *The census row*). A free rider on the same suite run that produces `test-<label>.failures.txt`; no second run |
| `census-<label>.tsv` | `census-diff.sh` | the census row's findings artifact — `finding <TAB> id <TAB> era` (`finding` one of `disappeared` \| `newly-skipped`), empty on a `PASS` or `INCOMPLETE` row — the evidence behind a `FAIL` `census` row |
| `.gate-marker-files.<label>` | `gate.sh` | internal to the `final` marker scan — the candidate file list (tracked ∪ untracked-not-ignored, minus `.kairos/`, `vendor/`, `node_modules/`), left on disk so the scanned set is auditable. A list that could not be built or read back is `gate-internal`, never the empty-list `PASS` |
| `gate-marker-hits.<label>.txt` | `gate.sh`, only when the marker scan FAILs | the full grep hit list behind a `conflict-markers` FAIL row — the card's evidence column cites this path, because the detail column is truncated to the first 10 hits and the scan's own temp file is deleted on exit, while this is the one row that demands per-file inspection of **every** hit |

## Phase 7 — execution

| Artifact | Writer | Read by |
|---|---|---|
| `learnings.md` | `log-learning.sh` (format owner), called by executors | every later executor at start. Capped on purpose — it must stay skimmable. Never promoted out of the run |
| `spawns.tsv` | `log-spawn.sh` (format owner) | `spawn-summary.sh` in Phase 8. Records the model **requested**, not the model that ran |
| `test-task-<id>.*` | `run-check-modules.sh` (delegating to `run-check.sh` per module) | the per-task failure-set check's evidence, compared against `test-baseline.failures.txt`. Phase 7's own build/test-at-a-label artifacts are the midplan gate's — see *Gates*, above |

## Phase 8 — finalize

| Artifact | Writer | Read by |
|---|---|---|
| `silenced-tests.tsv` | `scripts/silenced-tests.sh` | relayed alongside the final gate's verdict card (`phases/8-finalize.md` step 1) — a standalone report, never a row inside `gate.sh`. Schema: `file <TAB> line <TAB> construct`. Zero findings is a positive-evidence artifact (the scan ran and found nothing); an absent `PREV_SHA` is a skip that escalates as incomplete coverage, never a clean report, and writes no artifact |
| `build-final-root.*` | `run-check-modules.sh` (Phase 8 frontend final gate's **layer 2**, `CHECK=build`, component-root cwd) | **frontend runs only** — the layer-2 component-root build the frontend final gate runs after layer 1 passes, read against `build-baseline-root.*` from Phase 4.5: a build green at baseline and red now is the `web/`-broke-the-Go-side hard stop the layer exists for (`phases/8-finalize.md`) |
| `committed-binaries.txt` | `scripts/guard-binaries.sh` `MODE=range` (Phase 8 backstop) | relayed beside the final gate's verdict card (`phases/8-finalize.md` step 1) — a standalone report, never a row inside `gate.sh`. One run-created binary blob path per line (present at HEAD, absent at both `PREV_SHA` and the structural commit, not in the allowlist). Empty with exit 0 is a positive-evidence artifact (the range carries no run-created binary); exit 3 with paths is a hard stop — the blob is already in history and would be pushed. Bad input (unresolvable `PREV_SHA`) is a skip that escalates as incomplete coverage |
| `template-parity.tsv` | `scripts/template-parity.sh` | relayed alongside the final gate (`phases/8-finalize.md` step 1) and dispositioned per row at step 4 — a standalone report, never a row inside `gate.sh`. Schema: `path <TAB> status <TAB> detail`, `status` one of `absent` \| `relocated` \| `rename?` — template paths (from `$SYNTH`'s `kairos-target`) absent from the component's tracked tree, minus intent-guarded deliberate absences. On a frontend run (`MOUNT` set) the basis is instead the substituted module TARGET subtree (kept at `$RUN/frontend-parity-target/`, swept with the run-state dir) and rows are reported at mount paths; `$SYNTH` is never read on that arm. Zero findings is a positive-evidence artifact (the trees agree); an absent basis (`$SYNTH`/`kairos-target` on the template arm, an unresolvable frontend target on the frontend arm) is a skip that escalates as incomplete coverage and writes no artifact |

## Internal scratch — same-run, no downstream reader

Everything here is written and deleted inside one script's own run. It is indexed for one reason: "not in the index" must never be a reason to go reading a script to find out what a file is, and a leftover from a crashed run should be identifiable on sight. **All of it is safe to delete** — the producing script rewrites or re-creates it. Nothing outside its writer reads any of it, so none of it has a format contract to keep. Almost every member is **dot-prefixed**, deliberately, so a `$RUN` listing sorts the disposable scratch apart from the durable artifacts; the one exception is `model.txt.tmp`, the pin file staged beside `model.txt`, where a `.tmp` suffix rather than a dot prefix keeps the staged file next to its target in a listing.

| Family | Writer | What |
|---|---|---|
| `.diff.z`, `.numstat.z`, `.rnmap.z` | `build-manifest.sh` | the raw NUL-delimited `git diff --name-status` / `--numstat` / rename-map streams, before conversion to the `*.tsv` artifacts above. `-z` because a path may contain anything git can store |
| `.diff-badnames.txt`, `.rnmap-badnames.txt` | `build-manifest.sh` | paths rejected by that conversion (a newline or tab in the name), reported on stderr as they are found |
| `.baseline.index` | `build-manifest.sh` | a throwaway `GIT_INDEX_FILE` used to build a tree of the baseline side for rename detection; removed immediately after `write-tree` |
| `.upgrades-badnames.txt` | `build-manifest.sh` | the shared bad-name collector for the three `.kairos-updates/` history walks below; truncated at the top of that block and inspected after each walk |
| `.upg-added.z`, `.upg-added.tsv` | `build-manifest.sh` | the added-upgrade-file history walk, before it is folded into `upgrades-added.txt` / `upgrades-added.tsv` |
| `.upg-mod.z`, `.upg-mod.tsv` | `build-manifest.sh` | the modified-upgrade-file history walk, before it is folded into `upgrades-modified.txt` |
| `.upg-modbody.z`, `.upg-modbody.tsv` | `build-manifest.sh` | the amend-history walk that picks which commit each modified upgrade-file's body snapshot comes from |
| `.common-upgrades-badnames.txt` | `collect-common.sh` | the same bad-name collector, scoped to one module's `.kairos-updates/` walk, for `common-upgrades-added.txt` / `common-upgrades-modified.txt` |
| `.del-cand-dirs.txt`, `.del-emptied.txt`, `.del-emptied-sorted.txt` | `build-manifest.sh` | the emptied-directory passes' working sets (also listed under *Phase 3*) |
| `.legacy-raw` | `collect-common.sh` | the un-deduped union of legacy root-`UPGRADE.md` commits, before it is sorted into `common-legacy-upgrade-commits.txt` |
| `.ask-user-applied.tmp` | `apply-ask-user.sh` | the applied ledger under construction, renamed onto `ask-user-applied.tsv` only once every decision has been enacted — so a crashed enactment leaves no partial ledger for the postmerge gate to score |
| `.widescan/` | `bellwether-detect.sh` | the wide scan's working directory (blob lists, per-commit score inputs). Rebuilt from scratch on every wide scan; distinct from the `widescan-*.txt` artifacts and the persistent `widescan-blobcache.tsv`, which are not scratch |
| `.bellwether-raw.txt` | `bellwether-detect.sh` | the primary scan's raw per-candidate-commit score computation buffer |
| `.bwstage`, `.bwstaged.txt` | `bellwether-detect.sh` | per-candidate-commit staging directory and its staged-file list, used only when scoring a frontend module through the substitution helper (which needs a real directory, not a stream) |
| `.common-walk-failures.txt` | `collect-common.sh` | accumulates `module <TAB> stage` rows for a git-walk failure inside the (subshelled) collection loops, so a mid-loop failure still triggers a top-level refusal instead of a silently partial list |
| `.del-removed-all.txt` | `build-manifest.sh` | the mechanical-deletion oracle set (every template-deleted path, not just the re-bucketing candidates) behind the emptied-directory checkpoint |
| `.model-write-probe.$$` | `resolve-models.sh` | a writability probe created and removed to test whether `$RUN` can be written to at all, distinct from staging `model.txt.tmp` itself |
| `.pre-test-ignored.XXXXXX` | `clean-artifacts.sh` | the `mktemp` staging twin of `pre-test-ignored.txt`, same same-filesystem-rename pattern as the family below |
| `.upgrades-strayrecords.txt` | `build-manifest.sh` | the shared stray-record collector for the three `.kairos-updates/` history walks — a loud refusal alongside `.upgrades-badnames.txt` |
| `.yaml-gate-dupkeys-out.<label>`, `.yaml-gate-dupkeys-err.<label>` | `yaml-gate.sh` | the duplicate-key scan's per-file output and stderr for layers 1-2, reconciled against every candidate scanned |
| `.yaml-shape-err.<label>` | `yaml-gate.sh` | stderr for the shape-comparison dumps (see `.yaml-shape-target`/`.yaml-shape-working` above) |
| `.helm-err` | `yaml-gate.sh` | `helm template`'s stderr for the chart currently being rendered, read back into the row's detail and then removed |
| `.yaml-gate-files.<label>`, `.yaml-gate-raw.<label>`, `.yaml-gate-lserr.<label>`, `.yaml-gate-render.<label>` | `yaml-gate.sh` | the candidate YAML file list, the raw listing it was filtered from, that listing's stderr (so a failed listing is distinguishable from an empty one), and the current chart's rendered output |
| `.yaml-shape-target.<label>`, `.yaml-shape-working.<label>` | `yaml-gate.sh` | the two normalized key-shape dumps a shape comparison diffs |
| `model.txt.tmp` | `resolve-models.sh` | the pin file being staged. Only a fully-shaped four-line file is ever renamed onto `model.txt`, and a failed resolution clears both — a stale pin file must never survive a refusal |
| `.context.env.XXXXXX`, `.template-go.mod.XXXXXX`, `.test-command.txt.XXXXXX`, `.census-command.txt.XXXXXX`, `.resolutions.XXXXXX/` | `record-context.sh`, `extract-template-gomod.sh`, `write-test-commands.sh` (both temp families), `log-resolution.sh` | `mktemp` stems placed **inside `$RUN`** on purpose, so the final `mv` onto the real artifact is a same-filesystem rename: a crash leaves either the old file or the new one, never a truncated in-between |
| `.gate-marker-files.<label>` | `gate.sh` | the marker scan's candidate list — the one exception to "no reader, safe to delete": it is left in place deliberately so the scanned set is auditable (see *Gates*) |
| `.widescan-blobcache-stamp` | `bellwether-detect.sh` | the substitution-map hash that invalidates `widescan-blobcache.tsv` (see *Phase 2*) |

## The hand-written artifacts

`ask-user-decisions.tsv`, `yaml-gate-ack.tsv`, `ref-overrides.tsv` and `committed-binaries-ok.txt` are the complete set of `$RUN` files with no writer script — the set is not spelled as a number here on purpose, because the list and the lint's allowlist must be able to be compared item for item rather than counted. That is a reviewed exemption, not an oversight: each carries a decision only the user can make, into a script that then enacts it. (`committed-binaries-ok.txt` is the allowlist the guard-binaries script reads as `ALLOW`: repo-root-relative paths, one per line, the user approved to commit — a genuine new binary asset, not build output — added at a Phase 7 or Phase 8 binary-guard stop.) A lint holds the boundary from three sides — any other doc-referenced artifact must have a *writing* script (a script that merely reads it does not count — that hole is how the positional test-command file went its whole life with no owner), an allowlist entry no doc references anymore fails as a stale declaration, and this paragraph must name exactly the allowlist's entries. Everything else has a format owner — use it, never hand-append.
