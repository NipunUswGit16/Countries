# Structural merge

Per-file 3-way merge between baseline-template, target-template, and the component's current file. Mechanical merges land without the AI. Conflicts go to the conflict-resolver agent. The whole step is ONE commit.

Three scripts implement the mechanics — run them, don't retype them:

- `scripts/materialize.sh` (Phase 2.5) — builds the BASE and TARGET trees with `kairos component create` and commits them into a synthetic repo. See `materialization.md`.
- `scripts/build-manifest.sh` (Phase 3) — diffs the two synthetic commits and classifies every changed file into `$RUN/classification.tsv`, plus `$RUN/classification-trees.tsv` (`side <TAB> tree-oid`), the identities of the two synthetic trees those rows were derived from.
- `scripts/structural-merge.sh` (Phase 5) — executes the mechanical buckets and the 3-way merges, recording results.

This doc is the rationale and the contract between them.

## Why 3-way (not diff/apply)

A 3-way merge with diff3 markers gives the resolver enough context (ours / base / theirs) to reason about intent. "Apply template's new version" loses what the user customized. "Diff the template change and apply it to the component" can't handle cases where the user already modified the same region.

## Substitution happens before this step, not in it

The template uses placeholder tokens in content and paths; the component has real values. For the merge to align, both template sides must be in "component shape" first — otherwise the engine sees placeholder vs real value as a difference and conflicts everywhere.

That shaping is **no longer done here**. `materialize.sh` has the Kairos CLI build both sides, so blobs and paths arrive already substituted — substitution is the CLI's job now, never this skill's; see `materialization.md` for why.

What that means for this step:

- A synthetic-repo path **is** a component path. `template_path` and `dest` in `classification.tsv` carry the same value.
- Base and theirs blobs are read from `$SYNTH` at tags `kairos-base` / `kairos-target`.
- **We still do NOT reverse-substitute the user's file.** That would corrupt any user code legitimately mentioning the component name (a comment, a string literal, a local variable).
- Unsubstituted tokens surface as `$RUN/surviving-tokens.tsv` — template feedback, not an error.

## Line endings: always LF

All three merge inputs are normalized to LF before merging, and merged output is always written LF.

Otherwise a file differing only in line endings conflicts on **every line**, drowning the real hunks.

There is deliberately **no preserve-ours mode and no `.gitattributes` awareness** — don't add one. The cost is a one-time large diff on formerly-CRLF files: `$RUN/normalized-ours.txt` names them, and the orchestrator **must declare that list** in the structural-merge log entry so it reads as policy rather than damage. Binaries are detected first and never normalized.

Only files that go through the merge are normalized; files the template didn't touch keep their endings.

## Classification (build-manifest.sh)

Classification only uses what is knowable *without* merging — diff status plus local file state. Whether a text merge is clean or conflicted is a **result** discovered in Phase 5, not a prediction here.

| Template diff | Local state | Bucket |
|---|---|---|
| `A` added | absent locally | `added-mechanical` (or `added-heavyweight-ask-user`, below) |
| `A` added | exists locally | `merge-pipeline` (3-way with empty base) |
| `M` modified | exists locally | `merge-pipeline` |
| `M` modified | **absent locally** | `modify-delete-for-ai` — the component deleted/moved it; the merge must never silently resurrect it. If git finds a likely move target it's attached in the `component_path` column to inform the decision (see [Component-side rename detection](#component-side-rename-detection)); decide whether the template's change needs porting to wherever the code went. |
| `D` deleted | absent locally | `noop-already-deleted` |
| `D` deleted | present, unmodified vs baseline | `deleted-by-template-mechanical`, or `deleted-heavyweight-ask-user` (below) |
| `D` deleted | present, customized **text** | `modify-delete-for-ai` |
| `D` deleted | present, customized **binary** | `binary-for-user`, *delete-flavored* — `theirs` means adopt the deletion (below) |
| `RP` re-paired rename | present at either path | `merge-pipeline`, tagged `paired-by-dir-rename` (below) |
| `RP` re-paired rename | absent at both paths | `modify-delete-for-ai` — or `binary-for-user` when the template side is binary |
| `R100` pure rename | uncustomized | `renamed-mechanical` |
| `R100` pure rename | customized | `merge-pipeline` — merged at the NEW path (base = old template path), old location removed after |
| `R100` pure rename | both paths absent | `modify-delete-for-ai` |
| `R<100` rename + content change | ours side is text | `renamed-with-mods-for-ai` |
| `R<100` rename + content change | ours side is binary | `binary-for-user` |
| binary (either side) | any, except an **unmodified** file the template deleted | `binary-for-user` — never auto-merge, never send to AI |

Not a row this table can express: a git status `build-manifest.sh` doesn't otherwise route lands in `unknown-status`, its safety valve. It never enters `structural-merge.sh`'s pipeline (below); Phase 5 inspects the row and decides manually (`phases/3-classify.md`, `phases/5-structural.md`).

**A binary never reaches a for-AI bucket, on any arm.** `A`, `M` and `R*` probe `binaries-template.txt` first, so a binary row wins over the rename score or the local state — a renamed-and-modified binary is a user decision, never a `renamed-with-mods-for-ai` dispatch to an agent that cannot read it. A **renamed** binary row carries the pre-rename path so the one decision stays enactable: `apply-ask-user.sh` writes the target blob at the new path *and* removes the old copy on `theirs`, and leaves the tree untouched on `ours`.

The reason a binary has to be caught at *classification* time is that **a for-AI or ask-user bucket never enters `structural-merge.sh`'s pipeline at all** — the merge-time safety net below only ever sees `merge-pipeline` files. So each for-AI branch that could carry a binary runs its own probe up front: the customized `D` branch, the absent-at-both `RP` branch, and the `R<100` (rename + content change) branch. The invariant they enforce is the point here; the mechanics are the scripts':

- The customized **`D`** row is **delete-flavored** — the template no longer carries a blob at that path, so `theirs` means *adopt the deletion* and `ours` keeps the component's binary byte-for-byte. That is what the table's *delete-flavored* rows mean.
- The per-branch probe order, the `status`-column encoding of the delete flavor (no fourth ask-user bucket), and `apply-ask-user.sh`'s **inverted** blob check for the delete-flavored rows (the path must be *absent* at `kairos-target`, or a `theirs` would delete a live file) all live in `build-manifest.sh`'s and `apply-ask-user.sh`'s headers. This doc states the contract they keep, not their line-by-line logic.

The **unmodified** deleted binary deliberately stays `deleted-by-template-mechanical`. It is neither auto-merged nor sent to an agent — its content is byte-identical to the baseline, so the delete loses nothing — and routing it to the user would additionally break the wholesale-deletion checkpoint, which only counts `deleted-by-template-mechanical` rows: one binary inside an emptied directory would make that subtree look merely thinned and the batched confirmation would vanish for the whole run. "Unmodified" is decided **byte-exactly** for a binary, not through the CRLF-normalizing text comparison, which could otherwise call two different blobs equal and delete a customized binary without asking.

(Rows only the *ours* side makes binary inside `merge-pipeline` — including `RP` re-pairings — are caught one layer later, by the merge-time safety net below, which records the same pair.)

"Unmodified vs baseline" is checked against the materialized baseline blob, line-endings normalized — except for a binary, which is compared byte-exactly (above).

Heavyweight **addition** re-bucketing: additions under a NEW top-level dir with >3 files, or any NEW `cmd/<name>/`, become `added-heavyweight-ask-user`. `cmd/<name>` is grouped and existence-checked at the second level and qualifies regardless of file count: in Go/Kairos a directory under `cmd/` is a runtime entrypoint, so a new one is a high-stakes "the template added a new runtime" decision worth surfacing even as a lone `main.go` — and since `cmd/` already exists in every component, a top-level grouping would otherwise bury it.

`.kairos-updates/` entries are skipped entirely — template-tooling-only, never copied into components.

## Heavyweight deletions

A directory the template empties **wholesale** — every tracked file under it deleted, at least 3 of them — is re-bucketed to `deleted-heavyweight-ask-user` and presented as one batched confirmation table (directory, file count, recommendation), mirroring heavyweight additions. Emptied directories are listed in `$RUN/deleted-heavyweight-dirs.txt`.

Only **maximal** subtrees are reported: if `a/b` and `a/b/c` are both emptied, ask once about `a/b`.

Scattered single-file deletions deliberately stay `deleted-by-template-mechanical`. Prompting on those too would train the user to rubber-stamp the one prompt that matters.

"Every tracked file under it" is decided by listing the directory NUL-delimited (`git ls-files -z`), so **no filename byte — quote, backslash, or non-ASCII — can make it look merely thinned** and silently drop the checkpoint for the whole run.

## Directory-rename auto-pairing

When a directory is renamed, git drops any file whose content changed too much to clear its similarity threshold. That file splits into a fake delete + fake add, and the add **loses its merge base** — so heavy template change arrives as a wholesale overwrite instead of reviewable conflicts.

The classifier recovers it: if ≥3 renames git *did* detect share one old-dir → new-dir mapping, an unpaired delete + add differing only by that mapping and with an **identical basename** is the same file, and becomes one `merge-pipeline` row carrying the old path as its base.

It's still an inference, so rows are tagged `paired-by-dir-rename` (column 7) and listed in `$RUN/dir-rename-pairs.tsv` — **eyeball the pairings** before running the merge.

If a pairing is wrong, edit `classification.tsv` before `structural-merge.sh` runs: split the row back into an `added-mechanical` row for the new path and a `deleted-by-template-mechanical` (or `modify-delete-for-ai`, if the component customized it) row for the old one, and say so in the log. Do not "fix" it after merging. Leave `classification-trees.tsv` alone — row edits keep the binding valid. Only the `added-mechanical` row is vetted against the target tree (below): its new path must exist there *as a regular file* or the merge refuses it before it touches anything. The `deleted-by-template-mechanical` row for the old path is exempt from that same vetting **by definition** — its entire classification is that the path does *not* exist in the target tree (the template deleted it), so checking it for target-tree presence would be backwards; `modify-delete-for-ai` is likewise never vetted here, being an ask-user/for-AI bucket `apply-ask-user.sh` handles.

Expect a *conflict*, not a clean merge; that's the point. A conflict with a real base is reviewable, an overwrite with no base is not. A paired row that clean-merges is fine but worth a glance — it means the two files were more similar than git's threshold suggested.

## Component-side rename detection

A path-only classifier is blind to one case: the component MOVED a template-managed file and customized it (e.g. the template's `internal/foo.go` now lives at `pkg/foo.go`). When the template later modifies the *original* path, the naive rule sees "absent locally" and drops it to `modify-delete-for-ai` — a human puzzle ("the template changed a file you don't have; where did it go?") — even though the answer is often knowable.

So `build-manifest.sh` asks git. The materialized baseline is already component-shaped, so it only has to copy that tree's blobs into the component's own object store to make them addressable (`git hash-object` into a temp index, `git write-tree`), then run rename detection against the component's `HEAD`:

```bash
git -c core.quotepath=off diff --find-renames=50% --name-status -z $BASELINE_TREE HEAD
```

Each `R<score>\told\tnew` row becomes a `component-rename-map.tsv` entry: `old (template baseline path)` → `new (component path)` + similarity score.

The blob copy is NUL-delimited end to end (`ls-tree -z` → `update-index -z`), because git's default C-quoting (`"caf\303\251.go"`) made the follow-up blob read fail and left an **empty** baseline blob — so a non-ASCII file's move could never be paired, silently. Non-ASCII paths carry their real spelling through the map.

**This is enrichment, not a merge decision.** When a `modify-delete-for-ai` row has a move candidate, the classifier attaches the guessed component path in the `component_path` column — so the conflict-resolver / planner starts from "closest match is `pkg/foo.go`" instead of searching blind. It does **not** auto-merge the template's change onto the guessed file:

- Rename detection is a content-similarity heuristic. An orphaned template file can pair with an *unrelated* component file that happens to be >50% similar (boilerplate configs, license headers). Auto-merging onto that file would silently corrupt it — and because a clean auto-merge lands in `clean-merged.txt`, not `resolutions.tsv`, the planner (which reviews conflicts and coverage-blind files) would never see it. Enrichment keeps the human/AI in the loop for exactly the decision the heuristic can't be trusted to make.
- The candidate is advisory. The AI confirms it against the actual code before porting anything; the move stays in the for-AI bucket either way.

Notes and limits:

- **Writes loose objects.** Building the baseline tree writes loose objects into the component repo (`git hash-object -w`). They are unreferenced and harmless — a later `git gc` collects them — and every real run already writes far more into the migration state dir.
- **Silent no-op on large repos.** The diff treats every user-only file as an add and every unmatched template file as a delete; past git's rename limit (~1000 unmatched paths) git disables rename detection and the map comes back empty. The map is best-effort — an empty map just means no candidates are attached, and classification falls through to its pre-existing behavior.
- The floor is git's own `--find-renames=50%`; below that git reports nothing.

## Binary detection

Two layers:

1. **Template side**: `git diff --numstat` prints `-` for binary blobs — `build-manifest.sh` routes those to `binary-for-user` up front on `A`, `M`, `R*`, the customized `D` branch and the absent-at-both `RP` branch alike (a `-M -z` rename record is keyed by its NEW path, which is the path the classifier probes; a *deleted* binary is printed too, which is what lets the `D` arm read this list).
2. **Local safety net**: `structural-merge.sh` checks all three blobs for a NUL byte in the first 8KB before merging and diverts hits to `$RUN/binaries.txt`. (A `tr`-based length comparison, deliberately not `grep -q $'\x00'` — shell arguments can't carry NUL, so that grep pattern silently becomes empty and matches everything.)

Layer 2 only covers what layer 2 can see: **the buckets that enter the merge pipeline**. `build-manifest.sh` therefore runs the same NUL-byte probe itself on the two for-AI branches that never do — the customized `D` branch and the `R<100` branch — so a file the *component* turned binary is a user decision there rather than a resolver dispatch. The two probes are kept substantively identical; a change to one is owed to the other.

`binaries.txt` is one path per line, **plus an optional second TAB field naming the pre-rename path**. The diversion happens *before* `merge_one` completes a rename, so a rename-flavored row (an `R100` whose local copy is customized, or a `paired-by-dir-rename` row) that recorded only the new path left the old copy in the tree with nothing describing it: a `theirs` answer then wrote the blob at the new path and the structural commit carried both. Readers take the path from field 1 — a non-rename row is byte-identical to what it always was — and `apply-ask-user.sh` is the one that reads field 2 and enacts it.

## Merge execution results (structural-merge.sh)

For each `merge-pipeline` file: `git merge-file --diff3` on (ours, base, theirs) — all three LF-normalized, base and theirs read from `$SYNTH` — with labels carrying the template SHAs. Exit 0 → `clean-merged.txt`; 1–127 (conflict count) → `conflicts.txt` with markers left in the file; ≥128 → `merge-errors.txt` — where a rename-flavored row (the error fired before the rename completed, so the component's copy still sits at the old path and nothing exists at the new one) appends the pre-rename old path as a second TAB field, same shape as `binaries.txt`: readers take the path from field 1, and the second field is what stops the old copy from riding into the structural commit as a duplicate no artifact names. Mechanical buckets record to `added.txt` / `deleted.txt` / `renamed.txt`, and any file whose working-tree copy was CRLF→LF rewritten to `normalized-ours.txt`.

## Refusals: the classification must match the trees being merged

Three hard stops, all **before** any list is truncated, before a previous attempt's resolver verdicts are cleared, and before any file is touched — so a refused run is indistinguishable from not having run:

- **Binding mismatch.** `structural-merge.sh` re-verifies `$RUN/classification-trees.tsv` against the `kairos-base` / `kairos-target` trees in `$SYNTH`. A mismatch is a hard stop naming, per side, the oid the classification was derived from and the one `$SYNTH` holds now; a missing binding file is the same stop with nothing to compare. The stamp is trustworthy because `build-manifest.sh` resolves the two tags to tree oids **once**, at the top of the run, and both the diff every row comes from and the stamp use those same oids — a second read of the tags would let a re-materialization between them stamp trees the rows were never derived from, which is precisely the drift this check exists to catch, arriving pre-certified. Either way: **re-run Phase 3 classification, then redo Phase 5.** Re-materializing `$SYNTH` after Phase 3 (a corrected `BASE`, a moved `TARGET`, `FORCE_MATERIALIZE`) invalidates every row, so nothing may be merged against it. Identical re-materialized content is *not* a drift — the binding is on tree oids, i.e. content. Hand-editing individual rows (a wrong pairing, below) does not disturb it. The postmerge gate re-verifies the same binding before it tallies ask-user coverage: a mismatch there is a `FAIL` with the same remedy, and a binding it cannot check at all (no `$SYNTH` any more) degrades that row to `INCOMPLETE` rather than blocking.
- **Stale conflict markers from a previous run.** Before touching the output lists, `structural-merge.sh` re-checks every file its own `$RUN/conflicts.txt` listed last time; if any of them still carries live diff3 markers (`<<<<<<<`, `=======`, `>>>>>>>`), it refuses rather than re-running the merge — reading that still-marked file back in as "ours" would nest a fresh set of markers inside the old ones, corrupting the file. **The remedy is a tree reset, not another Phase 3/5 cycle — and it is the *path-scoped* reset, never the blanket form**: `git checkout -- . ':(exclude).kairos/migration-log.md' ':(exclude).kairos/intent.md' ':(exclude).kairos/manifest.yaml'` then `git clean -fd -e .kairos/intent.md`, then redo Phase 5. The exclusions are load-bearing and are the exact three `reference/continue.md` owns: at this point the tree legitimately carries an uncommitted migration-log entry — it rides the next commit by design — and a dirty `.kairos/intent.md`, whether **tracked-modified** (Phase 5 step 1's standing-intent re-confirmation, which the checkout exclusion protects) or a **first-ever untracked** file (user-confirmed standing intent, which the `clean -e` protects); the manifest exclusion carries over from the shared form. A blanket `git checkout -- . && git clean -fd` destroys the log entry and the intent, which nothing can regenerate. Looping through Phase 3 → Phase 5 again cannot clear this refusal — the stale markers live in the working tree, not in the classification.
- **Unwritable rows.** Every row the script would *write* — `added-mechanical`, `renamed-mechanical`, `merge-pipeline` — is vetted against the target tree before the enactment loop starts, and **all** bad rows are named in one refusal (the remedy is a single Phase 3 redo for the whole set, so a first-bad-row-only stop would hide how much is stale). Five shapes, each described as what it is rather than as a missing file: the path is **absent** at `kairos-target`; it is a **tree or gitlink** there, not a file; it is a blob in an **unsupported mode** — `120000`, a symlink, where `git show` prints the link *text* and the blob write path would land a regular file whose content is a path like `/etc/passwd`; the row carries **no `template_path` or no destination** to write to; or a **`renamed-mechanical` row carries no pre-rename old path** (column 5) — that enactment always writes the new-path blob, but the old-path removal and the `renamed.txt` record both depend on that column, so an empty one would write the file while recording the move nowhere, invisible to abort's debris pass and to any post-mortem (likeliest cause: a hand-edited rename pairing, see below). What is *not* a cause any more: a filename carrying a `"`, a `\` or a non-ASCII byte. Classification rows carry raw path bytes (Phase 3 reads the diff with `-z`), so a legal-but-awkward filename no longer arrives C-quoted and gets refused here as "absent from the target tree" — a refusal whose stated remedy, re-running Phase 3, reproduced itself forever. A name with a TAB or newline is refused in Phase 3 instead, where the remedy is to rename the file upstream. `deleted-by-template-mechanical` is out of scope by construction (those paths cannot exist at the target, by the same definitional exemption as the hand-split above), and the ask-user buckets are vetted by `apply-ask-user.sh` instead. Base-side absence stays legitimate (an added file has an empty base); theirs-side absence never is — every bucket the script enacts was classified *because* the target tree carries the path. (The swallowed-absence incident behind this vetting is in the script's header.) The same check stays inside the enactment loop as a backstop; if it ever fires there the tree *is* half-migrated, and that message says so (restore the tree, then Phase 3 → Phase 5).

None of the three is recoverable by re-running Phase 5 alone: the binding mismatch and the unwritable-rows refusal both need Phase 3 re-run against the current `$SYNTH`; the stale-marker refusal needs the tree reset above instead.

## Resolution log

One row per resolved region, written through `scripts/log-resolution.sh` — the
ledger's format owner, which owns the columns, the collapse rule, and the closed
verdict vocabulary. Nobody hand-appends a row: five scripts parse this file by
column, and a tab or newline in the free-text reason shifts every column after it.
The clause-by-clause mechanics — why `region` is appended rather than inserted, how
a pre-column three-field row is normalized on read rather than refused, and the
shard/aggregate append-reset-collect lifecycle — are `log-resolution.sh`'s own
header; this section states only the contract other docs and scripts rely on.

**Schema: `file <TAB> verdict <TAB> reason <TAB> region`.** `region` is a 1-based
ordinal of the conflict region's position within the file, counted top to bottom
over the file as the merge produced it — independent of the order the resolver
worked the regions in (`agents/conflict-resolver.md` states the contract to its
side, including the re-spawn case after a needs-input). A reasoning-bucket row (no
regions by construction) carries the literal `-`.

**Why an ordinal, not a line range.** Line numbers shift as the resolver replaces
each region in turn, so a recorded range would be stale the moment the file's next
region is resolved. An ordinal is stable and independently verifiable: a reader
re-derives the same file's regions from the same three sides and counts them the
same way, so the tree — not the resolver's memory of it — is what locates the hunk.
`scripts/dropped-template-changes.sh` is that reader for `ours` rows, re-deriving
every such file's regions from the same three sides this script merged; its own
header covers why re-derivation beats recording the hunk, and the CRLF
normalization it must repeat before re-deriving (`$RUN/normalized-ours.txt` names
which files that touched).

Rows land in a **shard** per dispatch (`$RUN/resolutions.<slug>.tsv`, plus the
reserved `role-switch` slug for in-conversation work); `ACTION=collect` rebuilds the
derived aggregate `$RUN/resolutions.tsv` from them, and `ACTION=reset` clears a
shard (and always the aggregate) ahead of a re-dispatch. The shards are the durable
record — `log-resolution.sh`'s header covers `reset`/`collect` and the
`resolutions.legacy.tsv` migration path in full.

The four tally readers (`handoff-structural.sh`, `spawn-summary.sh`,
`followup-completeness.sh`'s `kept-delete` derivation, and
`dropped-template-changes.sh`, filtered to `ours` rows) each read the shards **and**
the aggregate, de-duplicated on the row normalized to four fields first, so an
uncollected ledger is never reported as zero resolutions — `log-resolution.sh` is
the ledger's fifth consumer overall, and the format owner the other four keep a
`norm()` copy in step with (a skill-lint test holds the copies identical).

**A redo of Phase 5 discards the whole ledger — by design.** Once its two refusals
above pass, `structural-merge.sh` removes `$RUN/resolutions.tsv` and every
`resolutions.<slug>.tsv` shard (`role-switch` and `legacy` included) before it
touches a file: a verdict describes a conflict hunk in a tree the redo is about to
replace, and inheriting one would let a stale decision ride into a merge nobody
made it about. The refusal paths do *not* clear it — a refused run leaves the
previous attempt's shards exactly as they were, which is what makes a refusal
indistinguishable from not having run. What survives a redo is not the verdicts but
the **answers** behind them: `$RUN/qa-ledger.tsv` survives, so a needs-input answer
recorded there (`log-intent.sh`) still steers the re-dispatched resolvers, while one
that only ever existed in a `reason` column is gone.

The `ours|theirs|merged|user` vocabulary covers conflict regions; the reasoning-bucket
assignments the conflict-resolver also logs here extend it with `ported | kept-delete |
kept-customization | renamed-merged` (defined in `agents/conflict-resolver.md`) — the
closed set `log-resolution.sh` accepts, and nothing else.

`needs-input` is deliberately **not** part of that vocabulary and is never passed to
`log-resolution.sh` (it refuses it, exit 2). Genuine ambiguity never becomes a row here at
all: the resolver returns it as a *result* — file, region, and its best guess — which the
orchestrator relays to the user and re-spawns the resolver with the decision. The answer,
once given, is recorded through `log-intent.sh` into `$RUN/qa-ledger.tsv`, not into this
ledger. So the planner finds two different things in two different places: logged verdicts
(`ours`/`merged`/the bucket verdicts) in `resolutions.tsv`, and ambiguous items — what was
asked and how it was answered — in `qa-ledger.tsv`. It does not find `needs-input` rows
here, because there are none to find.

This exists because the resolver's default is "user customizations win" — so every `ours` verdict is a **dropped** template change. The planner reads this file and turns dropped changes into reviewable questions ("template wanted X here; your customization won; adopt X anyway?") instead of letting them vanish silently.

## What goes in the commit

Everything the structural step produced, including conflict-resolved files. **One commit** — the resolutions are part of it, not a separate commit. Splitting them would create a half-done partial state that isn't a useful rollback target.

The state directory never enters history — Phase 4 guarantees `.kairos/migration/state/` is gitignored before the first commit. `PLAN.md` lives alongside it at `.kairos/migration/PLAN.md` and *is* committed (it's the executor's contract and the one artifact continue can't lose). Commit message format is in `phases/5-structural.md` (step 8).

## NOT in scope here

- Applying upgrade-files — planner defines them as tasks, executor implements them in Phase 7.
- Reverting clean-merges that look like re-introductions — planner proposes those as revert tasks.

## Verifying the merged result

A clean `git merge-file` (exit 0, no markers) is a *textual* success, not a semantic one — two individually-clean hunks can combine into broken syntax or incoherent logic. Marker-absence is not correctness.

The orchestrator's **postmerge gate** (`phases/5-structural.md`, mechanics in `gates.md`) catches this: it re-runs the test command against the merged tree and compares the normalized failure set against `test-baseline.failures.txt` from Phase 4.5 (failure sets, not raw output). Regressions surface to the user before planning — fixed inline (amending the structural commit) or handed to the planner as a fix task. If no test command exists, the gate falls back to build/compile/typecheck. The resolver does not run this — it only guarantees markers are gone. Semantic verification of the whole tree is the orchestrator's job, once, after the structural commit.

Build and tests still miss one class entirely: YAML that is syntactically valid and semantically wrong. A merge can duplicate a mapping block or swallow one; nothing compiles YAML, and tests don't load charts. So the same gate also runs the **YAML gate** (`scripts/yaml-gate.sh`) — parse, duplicate-key detection at every nesting level, and a best-effort Helm render, which is the only layer that catches a swallowed block that something else references. See `gates.md`.
