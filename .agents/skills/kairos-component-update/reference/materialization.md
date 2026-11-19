# Materialization (Phase 2.5)

The merge never reads the template's own blobs. It reads two trees built by
`kairos component create` — from BASE and from TARGET — committed into a
throwaway synthetic git repo. `scripts/materialize.sh` does this; run it, don't
retype it. This doc is the rationale and the contract.

## Why the CLI builds the merge sides

Components are **born** from `kairos component create`. That command decides what a
placeholder is, what it becomes, and which files are eligible for substitution at
all — including a Go module-path rewrite, token forms beyond the registered ones,
and an extension whitelist outside which nothing is substituted.

**Never reimplement any of that here** — a substitution map drifted from the CLI
once and shipped files importing the template's own module path. Materializing
both sides through the CLI makes the parity structural, not maintained — don't
add one back; full rationale is in `materialize.sh`'s header.

The accepted corollary: a migration is impossible without an up-to-date Kairos CLI.
`pre-flight.sh` enforces that (`pre-flight.md` check 0b) before any state is
written.

## Mechanism

For each side (BASE, TARGET):

1. `git worktree add --detach` from the template mirror at that SHA. A worktree is
   exactly what a developer would hand to `--template-path`, so the CLI takes its
   normal creation path. No network.
2. Invoke:

   ```text
   KAIROS_SKIP_NAME_VALIDATION=1 kairos component create <name> <outdir> \
     --template-path <worktree> --no-repository --no-skills --no-tidy --no-frontend
   ```

   Every flag prevents a side effect that would break a non-interactive run:

   | Flag / env | Without it |
   |---|---|
   | `KAIROS_SKIP_NAME_VALIDATION` | names containing `kairos`/`nga` (e.g. `kairos-notes-demo`) trigger an **interactive re-prompt** and hang the migration |
   | `--no-frontend` | interactive frontend-template picker + a network clone into `web/` |
   | `--no-tidy` | requires goproxy, the Go toolchain, and module resolution |
   | `--no-repository` | `git init` + an initial commit inside the throwaway tree |
   | `--no-skills` | clones the skills pack |

   **Facades.** If the component is a facade (`.kairos/manifest.yaml`
   `template.kind: facade`, else `.init.mk` sets `MASTERDATA_INCLUDE_NO_CDC`, or sets `GENERATE_MODULES` without `sql` or `all`),
   the call is `kairos component facade create` with the same flags minus
   `--no-frontend`: facade create has no frontend step and rejects that flag. It
   rewrites the facade template's module path, which `component create` would
   miss. Otherwise the call is `component create` as above. Before either call,
   the template worktree's kind, read from its `go.mod` module line
   (`bitbucket.org/ifs-pd/kairos-component-facade-template` or
   `…/kairos-component-template`), must agree with the component's kind;
   a mismatch stops the run naming the template repo to use, because a facade
   merged against kairos-component-template gains runtimes it must not have.

   **A failed create is retried once, deliberately.** The retry **clears the
   output directory first**: the aborted attempt leaves a half-created tree, and
   a create layered over that debris would poison the merge base. The first
   attempt's log is preserved at `$RUN/materialize-<side>.attempt1.log`, and the
   retry is announced on stderr. A second failure is a real failure and stops the
   migration.

   Pre-flight's CLI warm-up (`pre-flight.md` check 0b) targets the same class of
   race but can only narrow the window — the CLI offers no way to force a pending
   update to settle. **This retry, not the warm-up, is the load-bearing
   defense.**

3. Install the resulting tree into `$RUN/synthetic`, commit, and tag
   `kairos-base` / `kairos-target`. Installing TARGET first clears whatever
   BASE's install left in the working tree (everything except `.git` and the
   reuse stamp), so a deletion between the two sides shows up as a deletion in
   the diff rather than as leftover content from the other side. **That clear
   is a checked hard stop**, like every other side-effecting step here: a
   partial clear (a locked file, a permission change mid-run) would let the
   other side's files ride into this side's tree and silently corrupt the
   classification diff, so a failure here stops the script instead of
   installing on top of it.

On the way in, each file is:

- **LF-normalized** (text files only; binaries are copied byte-exact). Doing it
  here means the BASE..TARGET diff is itself line-ending-proof, so a template that
  flipped a file's endings doesn't present as a whole-file change to the classifier.
- **corrected for the module path**, if needed — see below.
- **stripped of `.kairos-updates/`**, which is template tooling and never part of
  a component. Upgrade-file discovery reads real template *history* from `$CACHE`,
  not from these two trees, so dropping it costs nothing.

## The corrective module-path substitution

The CLI assumes the component's module path follows `bitbucket.org/ifs-pd/<name>`.
Not every component does. So after materializing, each side's **own root `go.mod`
is the authority**: if it disagrees with the component's root `go.mod`, that one
path is substituted across the whole side.

The *decision* is made per side, not once globally, so a template that changed its
own module path between BASE and TARGET is still corrected correctly on both:
each side is rewritten exactly when its own root `go.mod` disagrees with the
component's.

**The report line is narrower than the decision — read it as such.**
`$RUN/materialization.txt`'s `corrective_module_substitution:` is derived from the
**BASE side's** comparison alone: it reads `none (CLI convention matches the
component)` whenever BASE agreed with the component, even if the TARGET side
disagreed and *was* rewritten; and when BASE disagreed it names both sides in one
string, which asserts a target-side substitution that may not have happened. The
per-side truth is on the two raw lines above it — `base_module:` and
`target_module:` — each compared against `component_module:`. Compare those three
yourself when the answer matters (a co-developed template mid-module-path-move is
where they diverge); never quote the summary line as a per-side report.

## Surviving tokens are feedback, not errors

After materialization both trees are scanned for anything still shaped like a
placeholder (`<UPPER_SNAKE>`), and hits go to `$RUN/surviving-tokens.tsv` as
`side <TAB> path <TAB> token`.

A token nothing substitutes is the **template author's** bug — either it should be
registered or it should stop being used. It is deliberately not an error here:
failing the migration over an upstream typo would be unhelpful, while saying
nothing would leave it to show up as unexplained merge noise. It goes in the Phase
8 Template feedback section instead.

## Contract

| | |
|---|---|
| Env in | `PHASE_KEY` (required — stated in `phases/2.5-materialize.md`; the script refuses to run without it), `CACHE`, `BASE`, `TARGET`, `RUN`; optional `COMPONENT_NAME` (default manifest `name:`, else cwd basename), `KAIROS_BIN` (default `kairos`), `FORCE_MATERIALIZE` |
| Cwd | component root |
| Stdout | `SYNTH=<path>` |
| Out | `$RUN/synthetic/` (tags `kairos-base`, `kairos-target`), `materialization.txt`, `surviving-tokens.tsv`, `materialize-{base,target}.log`, plus `materialize-<side>.attempt1.log` when a create was retried; also writes `SYNTH`/`BASE`/`TARGET` into the run-context anchor (`$RUN/context.env`) on both a fresh materialization and a stamped reuse |
| Exit | 0 = both sides materialized (possibly on a retry); non-zero = a hard stop at any of: two failed creates for one side (the CLI's own log tail is relayed), a file that could not be installed into `$SYNTH` (an unwritable destination, an unsupported path shape), or a failed clear of `$SYNTH`'s working tree between installing BASE and installing TARGET (a partial clear would let the other side's files ride into this side's tree) |

**Reuse.** A stamp of `(BASE, TARGET, component name, component module path)` is
written to `$SYNTH/.materialize-stamp`, inside the synthetic repo itself. An
unchanged re-run reuses the trees instead of paying two CLI invocations again —
which is what makes Continue mode cheap.
`FORCE_MATERIALIZE=1` overrides it.

## Consequences downstream

Because paths and content arrive already substituted:

- A synthetic-repo path **is** a component path. `classification.tsv`'s
  `template_path` and `dest` columns carry the same value.
- `build-manifest.sh` and `structural-merge.sh` perform **no substitution**.
- A classification is only valid against the trees it was diffed from, so
  **re-materializing after Phase 3 means re-running Phase 3**: `build-manifest.sh`
  stamps the two tree oids into `$RUN/classification-trees.tsv` and
  `structural-merge.sh` refuses to merge against anything else. Re-materializing
  to the *same* content (the stamped-reuse path) is not a drift — the binding is
  on tree oids.

## The frontend fork (`RUN_SOURCE=frontend`)

A frontend run materializes with `scripts/materialize-frontend.sh` instead. Same
contract — `$RUN/synthetic`, tags `kairos-base` / `kairos-target`, `SYNTH=` on
stdout, `materialization.txt`, `surviving-tokens.tsv` — so Phase 3 and Phase 5 run
unchanged. Only the builder differs, and it differs for reasons worth stating,
because both obvious shortcuts are wrong:

- **Not the CLI, and not `component create` without `--no-frontend`.** `create`
  clones the frontend template at **branch HEAD**. HEAD is neither this run's BASE
  nor its TARGET, and no CLI command materializes the subtree at an arbitrary SHA —
  so the command that guarantees parity on the template arm cannot express a
  frontend range at all. Dropping `--no-frontend` would also reintroduce the
  interactive template picker and a network clone. And a frontend run **must not
  require the Kairos CLI** (PRD story 32): being blocked by a tool only the other
  arm uses is exactly the coupling this fork removes. `git` + coreutils only; no
  `KAIROS_BIN`, no CLI version probe, no `cli:` version line in
  `materialization.txt`.
- **Not "plain git trees" either.** `create` copies the subtree verbatim and *then*
  walks the whole created component — `web/` included — applying its content and
  filename replacement map. A component's mount therefore holds the component's own
  name where the subtree holds `<YOUR_BC_NAME>`. Sides built from the raw subtree
  would conflict against the component's `web/` on **every** substituted file
  (`package.json`, the vite config, `index.html`), and the merge would read as a
  wholesale rewrite of the app. The old "verbatim copy, no substitution" belief was
  simply false.

So both sides are **create-equivalent**: extract the module subtree at the SHA
(`git archive <sha>:<module-path>` — the subtree as a tree-ish, so entries come out
relative to the module root), lay it under the mount, then apply the map.

### Mechanism

For each side (BASE, TARGET):

1. Extract **that side's own** `<module-path>` at that SHA out of the frontend mirror
   (`$RUN/frontend`, a `--mirror` clone of the source repo established by pre-flight
   check 8.6 and passed in as `FRONTEND_CACHE` — a local `--frontend-path` checkout is
   the clone origin, exactly as `--template-path` is for the template mirror; an
   existing mirror of the same origin is refreshed, one of a different origin is
   re-cloned rather than trusted).
2. Lay it under the mount inside an otherwise empty tree, so the side contains
   `<mount>/**` **and nothing else**. Every other component path is legitimately
   absent from both sides: the classifier produces no row for it, and the template
   run's own baseline is untouched by a frontend run.
3. Apply the replacement map (below) to that tree.
4. Install into `$RUN/synthetic`, commit, tag — the same install as the template
   arm, with the same LF normalization, the same by-link-text symlink handling, the
   same checked hard stops, and the same checked clear between the two sides. The
   corrective module-path substitution has no counterpart here: a frontend module
   subtree carries no `go.mod`, and the CLI's `bitbucket.org/ifs-pd/…` rewrite is
   already one entry of the map.

Hard stops (all loud, all before or instead of a half-built side): a SHA that does
not resolve in the mirror, a module path that is not a directory at one of the two
SHAs, an empty extracted subtree (an empty side would classify the component's whole
mount as removed upstream), a mount or module path that is absolute or escapes with
`..`, a subtree carrying `.kairos-updates`, and a failed replacement map.

`.kairos-updates/` is **structurally** absent rather than filtered: frontend
upgrade-files live at the source-repo root under the module name
(`.kairos-updates/<module>/`), outside the subtree the CLI copies into the mount.
The script asserts that instead of assuming it — a repo that ever moved its
upgrade-files into a module subtree would otherwise ship template tooling into a
component's mount.

### The replacement-map contract, and where it is pinned

The map lives in **one** place, `scripts/lib/frontend-substitute.sh`
(`apply_create_substitution <tree> <component-name>`): the content token map, the
extension whitelist it applies inside, and the filename token map — pinned to
`nga-local-dev`'s `cli/entities/component/create.py`. Nothing else may open-code a
substitution; that drift is what the template arm's header is a monument to.

Because the CLI is no longer in the loop, the equivalence has to be asserted
somewhere else, and that somewhere is `tests/materialize-frontend.test.sh`: it runs
the fixture CLI (`tests/fake-kairos.sh`, which reproduces the real algorithm
including the whitelist) over the same subtree at TARGET and diffs its output
against the materialized mount, file for file. Two modules are diffed — the shipped
fixture module, and one built to carry every entry of the map (bracketed *and* bare
tokens, the template module path, upper- and lower-case filename tokens, plus a
non-whitelisted extension that must stay verbatim), because the first module alone
exercises only the bracketed tokens and left a deleted bare-token rule green. **If
the real CLI's token lists change, the helper, the fixture CLI and that test move
together.**

Surviving `<UPPER_SNAKE>` tokens are collected the same way and mean the same thing
one level up: a token nothing substitutes is the **frontend-template** author's bug,
carried to Phase 8 as feedback, never an error.

### Contract

| | |
|---|---|
| Env in | `PHASE_KEY` (the phase-2.5 key — one phase file owns both arms), `RUN`, `BASE`, `TARGET`; `MODULE` (the config.yaml module key; default: manifest `frontend.template`), `MODULE_PATH` (fallback subtree; default: manifest `frontend.path`), `MOUNT` (default: manifest `frontend.mount`, else `web/`), `COMPONENT_NAME` (default manifest `name:`, else cwd basename), `FRONTEND_CACHE` (default `$RUN/frontend`), `FRONTEND_PATH` / `FRONTEND_REPO` (the clone origin), `FORCE_MATERIALIZE` |
| Cwd | component root |
| Stdout | `SYNTH=<path>` |
| Out | `$RUN/synthetic/` (tags `kairos-base`, `kairos-target`), `materialization.txt`, `surviving-tokens.tsv`, the frontend mirror; no per-side logs (there is no CLI to log). Also writes `SYNTH`/`BASE`/`TARGET` plus its own resolved `FRONTEND_MODULE_PATH`/`FRONTEND_CACHE`/`FRONTEND_MOUNT` into the run-context anchor — the three `FRONTEND_*` keys are this script's alone, so later phases read the subtree this run actually merged rather than re-resolving it off the manifest |
| Exit | 0 = both sides materialized; non-zero = one of the hard stops above, each with a `FAIL:` line to relay verbatim |

**Reuse.** Stamped like the template arm's, on `(source, BASE, TARGET, component
name, both resolved module paths, mount)` — the source is in the stamp so a chained frontend run
can never mistake the template run's synthetic repo for its own, and a mount or
module change re-materializes instead of serving the previous answer.
`FORCE_MATERIALIZE=1` overrides it.

**`MODULE_PATH` is resolved by this script, from the source, PER SIDE.** The order is
`.kairos-updates/config.yaml` **at that side's commit in the frontend mirror** —
`modules.<MODULE>.path`, where `MODULE` is the manifest's `frontend.template` key —
then the passed `MODULE_PATH`, then the manifest's own `frontend.path`. Per side,
because a module relocated *inside* `BASE..TARGET` sits at two different paths: resolved
only at TARGET, the new path is then demanded at BASE too and the run refuses with
"module path is not a directory at the base commit" — making the one range that carries
the relocation the only range that cannot adopt it. When the two sides differ, a second
`WARN` says so and names both; both sides still land on the same mount, so the
classification shows content changes plus adds/deletes for files the two subtrees do not
share, never a rename of the mount. The config
outranks the manifest because the subtree path is the **source's** fact: when upstream
relocates a module, every existing component's recorded `path` is stale the moment it
lands, and a manifest-only resolution fails at extraction with "module path is not a
directory at the target commit" — which reads as a wrong SHA or a wrong module, the
two things it is not. A **disagreement** between the two is a `WARN` naming both
values and saying the source's won (the stale one is in a file later phases still
read, so it is worth fixing). Resolution is deliberately tolerant: no config, no
module key, no entry for it, or no `yq` and the passed/manifest value simply stands —
that is every source repo that does not self-describe. The read is the same one
`bellwether-detect.sh`'s tier 1 performs, with the same variable names, so the two
scripts cannot drift into disagreeing about which subtree a component was built from.
Nothing about `react` is known to either, so a second template-kind module needs no
change here.
