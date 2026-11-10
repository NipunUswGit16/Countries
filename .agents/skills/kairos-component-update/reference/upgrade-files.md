# Upgrade-files

Upgrade-files live in the template at `.kairos-updates/<YYYYMMDDTHHMMSS>-<slug>.md` (a **configured** source repo files them per module instead — a `kind: template` module per [A third source](#a-third-source-configured-source-repos-template-kind-modules), a `kind: library` module per [A fourth source](#a-fourth-source-configured-source-repos-kind-library-modules)). They describe a change that can't be expressed as a plain file diff — a rename that must ripple across call-sites, a config migration, a dependency bump with code follow-up. The planner reads them (Phase 6) and turns each into a task disposition; the executor applies them (Phase 7).

**The live directory holds only the current change; git history is the archive.** Each squashed PR commit on the template's default branch carries only the upgrade-files *that PR introduced* — the author's `kairos-document-updates` skill prunes files inherited from `main` as it writes the new ones. So `.kairos-updates/` at any given commit is small, and the tip does **not** contain the full history of upgrade-files. `build-manifest.sh` reconstructs the applicable set from git history — the files *added* in `BASE..TARGET` — and reads each file's **body from the commit that introduced it** (snapshotting into `$RUN/upgrades/`), never from the `TARGET` checkout. This is why pruning at the tip is safe: a component lagging several versions behind still recovers every upgrade-file's content from history. **A failed read and an empty file are different facts.** Both writers (`build-manifest.sh`, `collect-common.sh`) run `git show` themselves and check its **exit status**, so the two cases never merge into one: a *failed* read keeps whatever good body is already on disk, `WARN`s naming the file, and records a row in `$RUN/snapshot-refusals.tsv` (`slug <TAB> source <TAB> reason`) — the run continues, so one unreadable body cannot abort classification, and the refusal is still visible downstream instead of living only in stderr. A read that *succeeds* against a zero-byte blob is a **legitimate empty upgrade-file**: it is snapshotted at 0 bytes and served as an empty body. (Refusing empty bodies outright — the first version of this guard — made a genuinely empty upgrade-file committed in the template permanently unmigratable: it stayed in the list, could never be served, and blocked the completeness gate with no exit.)

**The planner reads those snapshots one at a time**, via `scripts/next-upgrade-file.sh` (`RUN=$RUN SLUG=<basename without .md> LIST=$RUN/upgrades-added.txt scripts/next-upgrade-file.sh`) — serving is **stateless**: the caller names the slug it wants and gets exactly that body (labeled `SLUG: <basename>`), so the caller drives the iteration by reading the list itself. `LIST` is the ordered list the slug must appear in (`upgrades-added.txt`, `upgrades-modified.txt`, or a common-module list; defaults to `upgrades-added.txt`), which is what turns an out-of-scope slug into an error instead of a surprise body.

**One exit code per cause, because they have different remedies:**

| Exit | Cause | Remedy |
|---|---|---|
| `0` | body served. A zero-byte snapshot is served too, announced by an `EMPTY:` line after the `SLUG:` header | disposition it — an empty upgrade-file says there is nothing to apply |
| `2` | bad input: `RUN` or `SLUG` unset, or `LIST` missing | fix the call |
| `3` | the slug is not in `LIST` — out of scope for that list | ask against the list the slug belongs to |
| `4` | in scope, but nothing was ever snapshotted for it | re-run the collecting phase (Phase 3 for template files, Phase 3.5 for common ones) — this is the swept-`$RUN` / never-ran shape |
| `5` | in scope, but its capture was **refused**: `git show` failed, recorded in `$RUN/snapshot-refusals.tsv`, and no body survives. The recorded reason is relayed | **do not re-run the phase — it reads the same object and fails identically.** Repair the source (re-fetch the mirror/clone), or disposition the slug explicitly in PLAN.md naming the unreadable body |

A body that *did* survive an earlier capture is still served (exit 0) when this run's re-read was refused, with a `WARN` saying the body predates the failed re-read — keeping the good snapshot is the point of the writer's refusal. "One body → disposition → discard" is now the planner's discipline rather than tool-enforced state, backed by the completeness gate (`scripts/plan-completeness.sh`, run before PLAN.md is committed) that fails the run on any slug without a disposition — a check that catches a dropped upgrade-file whatever the cause, which a cursor never could.

**The list is the planner's alone.** An executor reads exactly one body — the snapshot its task's **References** names (`$RUN/upgrades/<basename>.md`) — and walks no list: per-task executors are independent, and sequencing the queue is planning work, not execution work.

This doc defines the **file format the skill relies on**. Template authors own the content; the skill only depends on the conventions below.

## Format

Markdown with a small front-matter-ish header the skill parses, followed by free-form human instructions:

```markdown
# Rename FooClient to BarClient

intent: The client class was renamed upstream; all call-sites must follow or the
        new pipeline won't wire up.

before: FooClient        # a concrete code token or snippet that MUST exist pre-apply —
                         # never prose; explanation goes in intent:/## Details
after:  BarClient        # what it becomes

verify-script: ! grep -rn '\bFooClient\b' --include='*.go' .   # exit 0 == upgrade applied

verify: Check that all usages of the old client have been replaced and that
        the new client is wired up correctly through the factory.

ask: Adopt the renamed client in this component?   # OPTIONAL — presence makes
        # application the user's choice; asked only when `before:` still matches

## Details
<free-form instructions for the executor: which files, edge cases, ordering...>
```

The machine-read fields:

- **`intent:`** — one or two lines the planner uses to decide "does this apply to this component at all?" without reading the whole file. Answers most "should we apply this?" questions on its own.
- **`before:`** — a pattern the executor greps for **before** applying (bootstrapped components especially: if it's missing, the upgrade may already be applied or may not apply here — don't apply blindly; see `agents/executor.md`). The executor greps the *component*, whose placeholder tokens are already substituted to real values — so a `before:` pattern authored with a raw token (`<YOUR_COMPONENT_NAME>` etc.) matches nothing and the upgrade silently skips. Upgrade-files are snapshotted raw (no substitution), so authors must phrase `before:`/`verify-script:` around the substituted form; the `kairos-document-updates` self-review enforces this.
- **`after:`** — informational; not machine-executed.
- **`verify-script:`** — a shell command whose **exit code is the contract**: `0` means correctly applied, non-zero means not. Run by the executor after applying (Phase 7) and re-run by the orchestrator at the Phase 8 final gate for every upgrade-file marked `apply`. Use when the check is mechanically expressible (symbol removal, rename, config key change).
- **`verify:`** — prose description of how to confirm correct application. Passed to the executor as AI-driven verification instructions at Phase 7 and reviewed by the orchestrator at Phase 8. Use when the check requires judgment a shell command cannot express (structural pattern, semantic correctness).
- **`ask:`** — *optional; when present, this upgrade-file's application is the component's **choice**.* A single yes/no question, phrased for the component developer, that the **planner** (Phase 6) puts to the user to decide apply vs skip — instead of the upgrade being adopted automatically. Absent (the common case) → the upgrade is **not** user-optional; the planner dispositions it by the usual rules. The question is only ever surfaced when the change **applies** to this component (below), and only by the planner in conversation — never by a headless Phase 7 executor.
- **`requires-frontend:`** — *optional; template upgrade-files only.* Declares a minimum frontend-template baseline this change assumes, checked against the component's recorded `frontend.sha` when the file is crossed. See [Frontend compatibility floor](#frontend-compatibility-floor-requires-frontend) below.
- **`supersedes:`** — *optional.* Declares that this file **reverses or retires** earlier shipped guidance, naming one or more filename **stems** (space-separated on one line). A component crossing **both** files in one `BASE..TARGET` range then retires the earlier one mechanically instead of applying two contradictory rules. See [Superseding prior guidance](#superseding-prior-guidance-supersedes) below.

**At least one of `verify-script:` or `verify:` is required** — *except for a tombstone* (a pure retraction: `intent:` + `supersedes:` with no `before:`/`after:`/`## Details`), where there is nothing to apply and so nothing to verify. Both can coexist when a mechanical check and a semantic check are both warranted. Any other upgrade-file with neither gives the executor no way to confirm application.

`before:` is optional but strongly encouraged — without it, an executor cannot distinguish "already applied" from "doesn't apply here."

### Optional application (`ask:`)

An `ask:` field makes application optional: the user decides whether to apply. Most upgrade-files describe a migration a component **must** perform to stay on the template; they carry no `ask:` and the planner adopts every one that applies. An `ask:` marks the exception — an upgrade whose adoption is genuinely the component's call (an opt-in convention, a new preferred-but-not-required form). The consumer contract:

- **"Applies to this component" is decided by `before:`** — the same grep the executor already runs to guard blind application. A `before:` that **matches** → the change is relevant here → the planner surfaces the `ask:` and the user's answer is the disposition (`apply` becomes a task; decline becomes a `skip` with the reason recorded). A `before:` that **does not match** → the change does not apply here → the planner dispositions it `skip` **without asking** (there is nothing to adopt). With **no `before:`** to test, applicability can't be disproved, so the planner **asks anyway**.
- **The ask lives in the planner** (Phase 6, in conversation), because deciding application is planning work and the executor runs headless. The user's answer is recorded on the intent ledger like every other planning decision, so a resume or plan revision never re-asks it.
- **Nothing else changes.** An `ask:` file the user accepts flows through Phase 7 and the Phase 8 `verify-script:` re-check exactly as any `apply` upgrade-file does; one the user declines is a normal `skip` disposition (permanent — never resurfaced, like every skip).

### Frontend compatibility floor (`requires-frontend:`)

A template upgrade-file can declare that adopting it requires a minimum frontend-template
baseline:

```yaml
requires-frontend: react@<40-hex-sha>
```

`<module>` is the frontend-template module the floor is expressed in (defaults to `react`
when omitted, but SHOULD be written explicitly) and `<sha>` is a full 40-hex commit in that
module's source repo. The field is **module-scoped**, following the same "one module, and
only one" rule this doc already states for configured-repo template modules: a `react@…`
floor only binds a component whose `frontend.template == react`; a component mounting a
different module skips the floor with a recorded note rather than treating it as a spurious
requirement.

The semantics are **ancestry, not numeric comparison** — there is no ordering over git SHAs.
"Does the component's frontend baseline meet the floor?" resolves to whether the floor commit
is an ancestor of `frontend.sha`, via `git merge-base --is-ancestor <floor-sha>
<frontend.sha>` run in the frontend mirror — never a version-number `>=`. Two lineages that
never share the floor commit resolve to "not contained" and the requirement triggers, even if
the divergent `frontend.sha` is chronologically newer.

CANON: `A frontend floor is satisfied when the component's frontend.sha contains the floor commit — an ancestry test, not a version comparison.`

More than one crossed upgrade-file may each declare a floor for the same module; the
requirement is **additive** — the component's `frontend.sha` must contain **every** declared
floor commit, not just the newest.

The check is **advisory, never a gate**: an unmet floor never aborts the (already-merged)
template run, and it never auto-starts a frontend run without consent. It is consumed at
Phase 8 — see `phases/8-finalize.md` → "Frontend-run consent" for exactly how an unmet or
unverified floor modifies the six consent rules.

## Superseding prior guidance (`supersedes:`)

Upgrade-file history is append-only: a correction to shipped guidance is a *new*
file with a later timestamp, never an edit. So when a later upgrade-file reverses
an earlier one ("don't use X" → support lands → "use X"), a component crossing
**both** files in one `BASE..TARGET` range would otherwise hit the contradiction
with only judgment to resolve it. `supersedes:` makes the retirement mechanical.

```markdown
# Adopt feature X now that support landed

intent: X is now supported; the earlier guidance forbidding it no longer applies.
supersedes: 20260312T101500-avoid-feature-x
before: ...
verify-script: ...
```

- **Value:** one or more filename **stems** (basename without `.md`), space-separated
  on one line. Stems, not paths — the stem is the identity PLAN.md and
  `.kairos/migration-log.md` already key on.
- **Scope: same source, same module only** (template→template, `api`→`api`,
  `lib`→`lib`). A declaration naming a stem outside the declaring file's own
  source+module is a **WARNed no-op** — the four sources have incomparable ranges
  and separate collectors, and a cross-repo edge would let one repo's author
  silently disable another's migration. Enforced twice: the collector drops a
  cross-module target it can see, and `supersede-check.sh` re-checks that every
  enforced target sits in the *declaring* source's own collected lists — a stem
  another source shipped (which the collector could only record as "out of
  range") is WARNed and ignored there too, never retired via the plan's union.
- **Direction rule.** A valid edge points **backwards** in apply order: the target
  must precede the superseder in the same module's collected order, or be absent
  from it entirely (out of range / never shipped — an informational note only). A
  **forward** edge (target lands later) is WARNed and ignored, which also makes an
  in-range supersede cycle impossible.
- **The edge fires only when the superseder is `apply`.** A declined `ask:` or a
  not-applicable `before:` on the new file must not silently kill a still-valid old
  rule — declining "do X" would otherwise leave the component with *no* guidance
  where "don't do X" still holds. When the superseder is not applied, the superseded
  file is dispositioned normally on its own merits.
- **Consumer mechanics.** The collectors (`build-manifest.sh` / `collect-common.sh`
  / `collect-lib.sh`) parse `supersedes:` into per-source edge files
  (`supersede-edges.tsv` etc.); the planner reads the edges before its walk and
  **defers** any in-range target until its superseder is dispositioned (invisible
  bookkeeping — the user is never shown a "deferred" state); `supersede-check.sh`
  (Phase 6, beside the two completeness gates) recomputes the retired set as the
  transitive closure over the **applied** set and fails the run unless every
  retired in-range slug is dispositioned `skip` (reason contains
  `superseded by <stem>`) or `apply` (reason begins `override:`). Only **added**-list
  edges are enforced; a `modified`-list superseder (a shipped file amended to add
  the declaration) is **advisory** — the planner surfaces it in Q&A and the user's
  answer is the disposition.
- **Transitivity.** Retired = every slug reachable via supersede edges from an
  **applied** file, propagating through slugs that are themselves supersede-retired
  (C replaces B replaces A: C applied → B and A both retired). Propagation does
  **not** pass through a decline-skip or a not-applicable-skip — those chains are
  dead at that link, so a chain of corrections never resurrects the oldest rule.

### Tombstone (retract without replacement)

A **tombstone** retracts guidance with no replacement behavior: `intent:` +
`supersedes:` and **no** `before:`/`after:`/`## Details`. For this shape only, the
"at least one of `verify-script:`/`verify:`" requirement is waived — there is
nothing to apply, so nothing to verify. Its disposition is **`apply (tombstone)`**:
it counts as `apply` for edge-firing and for `supersede-check.sh`'s closure, but it
produces **no Phase 7 task** and is **exempt from Phase 8 re-verification** (there is
no change in the tree to verify). Adding a forgotten declaration to already-shipped
guidance is done as a tombstone (a new file), never by amending the shipped file —
this PRD extends the append-only design, it does not weaken it.

## Naming and ordering

Filename: `<YYYYMMDDTHHMMSS>-<slug>.md`, where the prefix is a **UTC timestamp**
(e.g. `20260707T153012-message-base-removed.md`) and `<slug>` is a short
`<noun-verb-pp>` description. The template author's `kairos-document-updates`
skill generates it from `date -u +%Y%m%dT%H%M%S`.

- **Identity.** The filename stem (timestamp + slug) is the stable id used in PLAN.md
  dispositions and `.kairos/migration-log.md`. It never changes once committed. There is
  no applied/skipped ledger in `.kairos/manifest.yaml` — the applicable set is derived
  live from the `BASE..TARGET` range on every migration.
- **Ordering is by commit, not by timestamp.** Upgrade-files apply in the order they
  *landed* on the template's default branch — the commit order in `BASE..TARGET` —
  which `build-manifest.sh` captures at discovery (`git log --reverse`, order-preserving
  dedupe) into `upgrades-added.txt`. The timestamp prefix is only an identity and a
  human-readable hint: an author's clock can disagree with merge order (a PR authored
  earlier can merge later, a long-lived branch merges today), so timestamp order is
  *not* safe to apply in when one migration depends on another. Within a single commit,
  files sort alphabetically (≈ timestamp) as a stable tiebreak. The planner may still
  bundle or re-scope, but it preserves this order.
- **History is append-only; the working tree is not.** A shipped upgrade-file's
  *identity and committed content are permanent* — never amend a file after it has
  landed on the default branch (a correction is a *new* file with a later timestamp),
  so a component that already applied one never sees it change underneath it. But the
  file is **pruned from the working tree** once it has shipped: the next PR removes the
  upgrade-files it inherited from `main` and adds only its own. Removal from the tip is
  not a history rewrite — the addition commit still holds the body, which is where the
  consumer reads it from. Net: each squashed commit owns exactly the upgrade-files it
  introduced, and the directory never accumulates.

  The append-only rule is an authoring *convention* (enforced by
  `kairos-document-updates`), so the consumer still handles amendments as
  defense-in-depth against an author who edits a shipped file by hand: `build-manifest.sh`
  emits `upgrades-modified.txt` for files amended in `BASE..TARGET`, and the planner
  revisits an amendment to an already-applied upgrade-file as a possible correction to
  re-apply (see `agents/planner.md`). This is a safety net, not a license to amend.

A **UTC timestamp, not a sequential number**, so two parallel PRs can each add an
upgrade-file without colliding on the next integer — no cross-branch coordination,
and the next value comes from the clock rather than scanning the directory. Apply
order is recovered from git history, so the timestamp never has to be globally
monotonic.

## Why exit-code contracts

A `verify-script:` command returning non-zero at the final gate is a hard signal the migration isn't done, caught before the baseline advances — far cheaper than discovering a half-applied rename after the component ships. Keep them cheap and specific (a targeted `grep`, a single focused test, a `go vet` on one package): they run at least twice per migration, so they must be fast and side-effect-free.

When a shell command can't capture the check — the transformation is semantic, not textual — `verify:` prose gives the executor the instructions it needs to do an AI-driven confirmation. This is intentionally weaker than an exit-code gate but better than no verification at all.

## What the skill does NOT assume

- It does not execute the free-form `## Details` prose — that's for the executor/planner to read and act on.
- It does not require upgrade-files to be idempotent, but `verify-script:` should be (it runs repeatedly).
- The template carries a root `UPGRADE.md` on both branches, and `.kairos-updates/` only on `feature/integration_api`; `build-manifest.sh` walks `UPGRADE.md` on every run regardless. That file has no machine-read fields: the planner reads its commit history (`$RUN/legacy-upgrade-commits.txt`) and treats it as free-form.

## A second source: kairos-component-common upgrade-files

Upgrade-files come from **four** kinds of source, sharing this exact schema:

- **the template** — `.kairos-updates/`, collected over `BASE..TARGET` (template SHAs) by `build-manifest.sh`, as above.
- **kairos-component-common** — the shared Go libraries (`api`, `common`, `event-handler`, `toolkit`, …) the component consumes via `require` lines. Their upgrade-files live at `.kairos-updates/<module>/` in the common repo and are collected by `scripts/collect-common.sh` over each module's **version range** (`<module>/BASE..<module>/TARGET`), where BASE is the component's `go.mod` version and TARGET is the version the template pins at the migration target. These are **consumer-facing**: `before:`/`after:`/`verify-script:` describe and check the *component's* usage of the library API, and `verify-script:` greps the component (which has no common source).
- **a configured source's `kind: template` module** — see *A third source* below.
- **a configured source's `kind: library` module** — see *A fourth source* below. Collected by `scripts/collect-lib.sh` over the frontend run's existing `BASE..TARGET`, irrespective of which template the component mounts.

Common is a **dependency, not a merge**: its code lives in the Go module cache and is never copied into the component, so common contributes **upgrade-files only** — no structural merge, no separate baseline, no manifest entries. The `go.mod` version bump itself rides the existing template `go.mod` structural merge.

**Same schema, same reader.** `collect-common.sh` snapshots each collected common upgrade-file's body into the same `$RUN/upgrades/` dir `build-manifest.sh` uses, so the planner and executor read template and common upgrade-files identically. The only addition is **provenance**: `$RUN/common-upgrades-added.tsv` records `add-sha <TAB> module <TAB> path` so the planner can group by module and reason about application order. Apply order is **not** interleaved by timestamp across repos (author clocks aren't comparable across repos) — the planner is handed a per-module default grouping and decides final order. Common also has its own `$RUN/common-upgrades-modified.txt` — a common upgrade-file that existed before a module's BASE and was amended in range — mirroring the template's `upgrades-modified.txt` (see below) exactly, including how the planner revisits it as a possible correction to re-apply.

**Collection is "latest state within range", not add-only.** A common upgrade-file's version range (`<module>/BASE..<module>/TARGET`) is tag-bounded and append-only for released consumption, but a local-path `replace` or a `REF_OVERRIDES` ref (co-developing common alongside the template) walks raw, unsquashed branch history — where drafting, amending and renaming your own not-yet-merged upgrade-file is normal authoring. `collect-common.sh` collects **exactly one identity per upgrade-file, at its newest path, carrying its newest body, in its original apply slot**: an in-range rename is resolved (transitively, through rename chains) to the file's final path before ordering and dedupe, and an in-range amendment's content always overrides the snapshotted body, regardless of whether the amendment landed under the file's current name or a prior one. This is a no-op on tag-bounded, append-only history — merged upgrade-files never churn — so released collection is unaffected.

- Version resolution, replace/skip/unresolvable rules, and the per-module legacy ceiling are documented in the header of `scripts/collect-common.sh`. Modules whose range can't resolve to a clean tag are surfaced in `$RUN/common-unresolvable.txt` (per module, batched — skip / provide-ref / abort).
- Legacy: common's frozen root `UPGRADE.md` is captured (ceiling-gated) into `$RUN/common-legacy-upgrade-commits.txt`, mirroring the template's legacy mechanism.

### Co-development resolution (unreleased common)

When the template pins common from unreleased sources — a co-development scenario — three resolution rules keep a range collectable instead of silently dropping it:

- **Pseudo-version pins resolve via their embedded commit.** A pin like `v0.0.0-<ts>-<12hex>` has no tag, but the 12-hex commit it embeds usually exists in the mirror cache. `collect-common.sh` uses that commit as the range endpoint (both BASE and TARGET) and decides `collect`. Only a commit **absent** from the mirror (genuinely unpushed work) stays `unresolvable`, and its `common-unresolvable.txt` detail **names the missing commit** so the answer is "push it or pick a released ref."
- **Per-module ref-overrides (`REF_OVERRIDES`).** An optional TSV (`module <TAB> ref`) routes a listed module to `collect` against that ref resolved in the mirror cache; the range becomes `<module>/BASE..<ref>`, and the override is recorded in the decision detail for provenance. This is what makes the batched unresolvable prompt's "provide a ref" answer **mechanically actionable** — the orchestrator writes the override file and re-runs the script rather than hand-collecting. The ref only needs to be reachable in the mirror (a pushed branch), so no local common checkout is required.
- **Local common clone hygiene.** When a local-path `replace` resolves to a common clone, collection reads only committed history; an uncommitted or untracked `.kairos-updates/<module>/` tree in that clone is invisible. Collection **warns** (non-fatal, stderr) so the author commits before migrating — the mirror of the dirty-template warning. Before bounding the range, `collect-common.sh` also does a **best-effort `git fetch --tags`** on the clone (`lib/fetch-local-clone.sh`): a released BASE pin absent only because the clone is behind its remote — the routine co-dev case, where the template pins newer commons than the local checkout last pulled — then resolves without a manual `git pull`. The fetch is non-destructive (tags/remote-tracking only, never the working tree or the co-dev HEAD) and non-fatal (an offline or remoteless clone `WARN`s "could not fetch" and proceeds on local refs; only a pin still absent after the fetch stays `unresolvable`).
- **Consumer-side co-development (the component's own `go.mod` replaces common).** When the *component itself* builds a module from a local clone, that replace names only WHERE the newer upgrade-files live — the clone's committed history, with TARGET = its HEAD — never the range's lower bound. BASE is the surviving `require` pin (the replace wins over `require` for *building*, but the require line stays in `go.mod` and is a real released version), so `collect-common.sh` collects `<module>/<require> .. local-HEAD` against the clone: the exact mirror of the template-side local-path arm, resolved from the component's own go.mod dir. It stays `unresolvable` only when the replace target is not a git repo, or the require version cannot resolve in the clone — each with the reason and remedy named. A common module that is *replaced to a local dir but never `require`d* is invisible to the require-driven resolution loop, so a **post-loop orphan scan** catches it separately and lands it `unresolvable` ("no `require` line to bound the range from") rather than letting its co-developed upgrade-files drop silently — `go mod tidy` normally writes a placeholder `require` (a zero pseudo-version) that reaches the loop and lands `unresolvable` there instead, so this scan closes only the hand-written, un-tidied gap.

The batched `common-unresolvable.txt` question remains the **single funnel** for whatever none of these resolve (unpushed pseudo commits, a BASE/TARGET ref that does not resolve in the mirror, non-repo replace paths, or a consumer-side local-path replace that pins no `require` version to bound the range from — or whose clone cannot resolve that version): every listed module must be dispositioned (skip / provide a ref / abort) before the expensive phases — an odd pin must never silently drop a migration or silently block the run.

## A third source: configured source repos (template-kind modules)

A source repo that ships `.kairos-updates/config.yaml` declares named modules. A `kind: template` module is **the component-template repo in miniature, rooted at the module's `path`** — so everything above about template upgrade-files holds verbatim, with one substitution: paths are relative to the **module subtree**, not to a component root. `kairos-frontend`'s `react` module is the first one. The author side of this contract is `core-skills/kairos-document-updates/reference/upgrade-file-schema.md`; **this section is the consumer contract it mirrors**, and this doc wins if the two ever diverge.

- **Where they live.** `.kairos-updates/<module>/<timestamp>-<slug>.md`, at the **source repo root** — never inside the module's subtree, which is the tree the CLI copies into the component's mount, so a file placed there would ship into every component. Same layout as common's per-module directories, for a different reason.
- **Who collects them, and over what.** `build-manifest.sh`, exactly as for the template, with `MODULE=<the module key>` — which scopes the discovery walks *and* their parsers to `.kairos-updates/<module>/`. The range is that source's own `BASE..TARGET` commit range (this is a merge-shaped source, not a version-ranged dependency). Everything else is the template path unchanged: added-in-range in **commit** order, each body read from the commit that introduced or last amended it, the same `upgrades-added.txt` / `upgrades-added.tsv` / `upgrades-modified.txt` / `$RUN/upgrades/<basename>.md` / `snapshot-refusals.tsv` with the same meanings, read by the same planner and executor. Rename- and amend-in-range are handled to the same bar.
- **One module, and only one.** A component is built from ONE module — its manifest's `frontend.template` — and only that module's directory is walked. A sibling module's breaking change landing in the same range must **never** produce a migration step here: it documents a template this component was not built from. The pathspec scopes the walk and the parsers re-check the prefix, because a pathspec is a filter while the prefix check is the invariant.
- **`before:` and `verify-script:` are module-subtree-relative and execute with cwd at the MOUNT.** They are written `src/App.tsx`, `package.json` — never `web/…` (wrong inside the source repo) and never `template/react/…` (wrong inside the component). The same string is valid on both sides because the executor, and the Phase 8 re-verification, `cd` to the mount first. A wrong cwd surfaces as "pattern not found" — i.e. as a silently skipped upgrade rather than an error — which is why the authoring skill rejects a mount-prefixed or subtree-prefixed path outright.
- **Substituted forms, as everywhere else.** The mount's placeholder tokens were substituted at create, so a `before:` phrased around a raw token (`<YOUR_BC_NAME>`) matches nothing. Upgrade-files are snapshotted raw; authors phrase patterns around the substituted form.
- **No legacy era.** The root `UPGRADE.md` walk still runs (it is per-source, not per-repo-kind) and is expected to come back empty for a configured repo: there was no pre-`.kairos-updates/` generation of these sources to inherit.

## A fourth source: configured source repos (`kind: library` modules)

A `kind: library` module in a configured source (today `kairos-frontend`'s `lib/`, published as `@ifs-kairos/*`) is a **dependency, never merged** — the same consumer-facing contract as common, versioned like the template. **Model A:** the library's range *is* the frontend run's existing `BASE..TARGET` SHA range. There is no `package.json` version parsing and no go.mod resolver. `kind: library` is a configured-repo concept only; it does not span common (which detects modules by go.mod subfolders).

- **Where they live.** `.kairos-updates/<module>/<timestamp>-<slug>.md` at the source repo root (today `.kairos-updates/lib/`). Same layout as template-kind modules, for the same reason: the module's `path` is the published library, so a file placed inside it would describe lib internals.
- **Who collects them, and over what.** `scripts/collect-lib.sh`, invoked from the Phase 3 **frontend arm** immediately after `build-manifest.sh`. The two are an **atomic re-run unit** of Phase 3: `build-manifest.sh` truncates `$RUN/upgrade-snapshot-sources.tsv` whole, so lib's source rows survive a redo only because `collect-lib.sh` re-runs immediately after and re-appends them. Never stamp, cache, or skip `collect-lib.sh` relative to `build-manifest.sh`. Collection is over the run's existing `BASE..TARGET`, **irrespective of which template** the component mounts. Enumerate `kind: library` modules from the source `config.yaml` **at TARGET**.
- **Provenance.** Ledger rows use the real module name as source id — `<libmodule>:.kairos-updates/<libmodule>/…`, the same `<module>:` shape common uses. The prune predicate `^[^:]+:\.kairos-updates/` is shared by common and lib and is safe only because their `RUN_SOURCE`s are disjoint. Outputs: `lib-upgrades-added.{txt,tsv}` / `lib-upgrades-modified.txt`, bodies in the shared `$RUN/upgrades/`.
- **`LIB_MODULES=present|none`.** Written **only** by `collect-lib.sh` on the frontend arm — absent by design on a template run (the inverse of `COMMON_MODULES`). `present` + an empty-but-present list means "looked, none in range"; a missing list under `present` is a resume defect (`plan-completeness.sh` exit 2). `none` means the source declared zero library modules.
- **How they apply.** Never a structural merge — lib source is not copied into the component. Apply as executor transforms against the component's own `web/src` call-sites, then verify at **mount cwd** (inherited from the existing frontend gate machinery).
- **`before:` and `verify-script:` are subtree-relative (check 14) and consumer-facing.** Written `src/…`, never `web/src/…` (mount) and never `lib/…` (the library's own subtree). The executor `cd`s to the mount first. Patterns describe the *component's* usage of the lib API (`@ifs-kairos/*` import / call-site), never lib internals.

## Common-library upgrade-file collection (Phase 3.5 detail)

This section expands the mechanics the skill's Phase 3.5 body only summarizes: what each `common-resolution.tsv` decision code means and why it exists, why co-dev detection is mechanical rather than judgment-based, why the wrong-target tripwire matters, and why reading BASE live from `go.mod` is sufficient bookkeeping. (Pseudo-version resolution and provenance/rename/amendment tracking are covered above, under *Co-development resolution* and *Same schema, same reader*.)

### `common-resolution.tsv` decision codes

Per module: `module <TAB> base <TAB> target <TAB> tag_prefix <TAB> dir <TAB> decision <TAB> detail <TAB> repo`. `decision` is one of:

- **`collect`** — the range resolves to real endpoints and a mirror is available; upgrade-files in `<module>/BASE..<module>/TARGET` are collected.
- **`skip-downgrade`** — TARGET is not ahead of BASE (component already at or past the template's pin). Exists so a component that's already advanced past a version never gets asked to "handle" it — see the BASE-liveness note below.
- **`skip-absent-target`** — the template's `go.mod` at TARGET does not pin this module at all (neither a `require` nor a `replace`), so there is no TARGET version to bound a range with. Recorded as a skip, not `unresolvable`, because there's nothing actionable for the user to provide. This code is only ever a statement about a *readable* template `go.mod`: an absent, unreadable or shapeless one is a hard error (exit 1, no rows written), never this code for every module.
- **`skip-no-cache`** — the range is resolvable in principle, but `COMMON_CACHE` is unset, so there's no mirror to collect from. This is deliberately a *skip*, not `unresolvable` and not a silent "collect with an empty repo" — it's what makes a failed clone degrade to a visible, settled per-module record — Phase 3.5 still runs (it branches on `COMMON_MODULES`, not on `COMMON_CACHE`), relays the tally, and continues — rather than triggering the batched-unresolvable question. The genuinely quiet path is `COMMON_MODULES=none`, where the phase never runs at all.
- **`unresolvable`** — genuinely undecidable: an unpushed pseudo-version commit, a BASE/TARGET ref that does not resolve in the mirror, a non-repo replace path, or a consumer-side local-path `replace` the script cannot bound — the component pins no `require` version to anchor the FROM end, or the clone cannot resolve that version *even after the best-effort pre-fetch* (offline, no remote, or a genuinely unpushed pin), or the target is not a git repo (the detail names what failed and the remedy). Note a consumer-side local-path replace is *not* automatically unresolvable anymore: when the component keeps a `require` pin and the target is a git clone, it `collect`s `<require>..local-HEAD` (see *Co-development resolution* above). This is the *only* code that feeds the batched question (skip / provide-ref / abort) — every other code is a settled outcome the script decided on its own.

**Why the codes are split this finely:** collapsing `skip-downgrade`, `skip-absent-target`, and `skip-no-cache` into a single generic "skip" would either (a) hide from the operator *why* nothing was collected for a module, or (b) force all three into the batched-unresolvable prompt, asking the user to adjudicate things the script already knows the answer to (a downgrade needs no ref; an unset cache needs no ref). Splitting them keeps the batched question reserved for cases where a human answer is actually needed.

### BASE read live from go.mod

BASE is read live from the component's current `go.mod` on every run — there is no "already handled" ledger anywhere in `.kairos/`. It is read the way go resolves versions: a `replace` directive wins over the `require` (an unqualified replace always; a version-qualified one only when the required version equals its `Old.Version`), so a component pinned by replace is measured against what it actually builds with, on both ends of the range. This means a module version the component has already advanced past (from a prior migration, or a manual bump) is automatically outside the collection range and needs no bookkeeping to exclude. The alternative — tracking which common upgrade-files were already applied — would need its own persistent state and its own drift-detection; reading BASE live sidesteps that entirely by construction.

### Co-dev detection is mechanical

Co-development (the template pinning common via a local-path `replace`) is detected by `codev-check.sh`, which parses `go.mod` with `go mod edit -json` and reports the local-path replace directives on the common-module prefix — never by an operator "noticing" the situation, and deliberately never by a grep: a block-form `replace ( … )` group carries the `replace` keyword only on its opening line, so a grep sees none of the inner directives, which is exactly the shape a co-dev setup accumulates. The reason it's scripted rather than left to judgment: a co-dev setup silently changes how relative `replace` paths must be resolved (against the real template checkout, not the migration scratch dir), and a missed detection degrades quietly into a wall of per-module "not a git repo" unresolvables rather than a clear signal — exactly the kind of failure a human skim is prone to missing under time pressure.

### Wrong-target tripwire rationale

The tripwire (comparing the template working tree's common replaces against the resolved TARGET's) exists as defense-in-depth behind the Phase 2 default target-resolution chain. Its failure mode: TARGET silently defaults to `main` while the operator's actual co-development work lives on a feature branch, so the working tree shows co-dev replaces but TARGET's `go.mod` shows none. Left undetected, the migration would run for hours against the wrong target before anyone noticed — expensive to discover late and cheap to catch early, which is why it's checked immediately in Phase 3.5 rather than left to surface downstream.
