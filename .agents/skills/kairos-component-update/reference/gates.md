# Gates

Three gate labels run per migration: the **postmerge gate** — the post-merge
sanity pass (`LABEL=postmerge`, Phase 5, before planning), the **midplan gate**
(`LABEL=midplan`, Phase 7 — the build / tests / YAML / producer / replace checks
re-run over the current tree on the cadence `phases/7-execution.md` owns; the
`postmerge`-only ask-user compare and the `postmerge`/`final` census row do not
recur here) and the **final gate**
(`LABEL=final`, Phase 8, before the baseline advances). All three are one
script — `scripts/gate.sh` — differing only by `LABEL`. This doc is the single
home of the per-check rationale; the card-reading interpretation contract lives
in `reference/gate-cards.md`.

The governing idea: *a marker-free merge is not a correct merge, and a green check
is not evidence unless the check actually ran.*

## Contents

**This doc is reference, not a runbook — Read a section when a card is puzzling,
don't Load the whole file.** Exactly two sections carry a contract a phase must
follow verbatim, marked **[load-worthy]** below: *The positional
`$RUN/test-command.txt` contract* and *The census row*. Everything else is
per-check rationale a diligent run never has to read end to end.

- **The gate card (`scripts/gate.sh`)** — env/exit contract, check order (the
  card-reading interpretation contract — what `PASS` / `FAIL` / `INCOMPLETE` /
  `NEEDS-INPUT` mean and what you do with each — is its own doc:
  `reference/gate-cards.md`)
- **The gate cwd, and the frontend arm** — where each gate runs, and the two-layer final gate on a `frontend` run
- **The YAML gate** (`yaml-gate.sh`) — discovery, then layer 1 (parse), layer 2 (duplicate mapping keys), layer 3 (best-effort Helm render), layer 4 (structural shape / buried top-level key)
- **Producer idempotence** (`producer-idempotence.sh`)
- **The positional `$RUN/test-command.txt` contract** **[load-worthy]** — written by `write-test-commands.sh`, read by line number
- **Zero-evidence guard on discovered commands**
- **Go multi-module sweep** (`run-check-modules.sh`)
- **Local-path `replace` directives**
- **Ask-user enactment coverage** (`postmerge` only)
- **The census row** **[load-worthy]** (`census-diff.sh` — `postmerge` informational relay,
  `final` FAIL semantics)
- **`verify-script:` discrepancies**

## The gate card (`scripts/gate.sh`)

| | |
|---|---|
| Env in | `PHASE_KEY` (required — stated in `phases/5-structural.md` / `phases/7-execution.md` / `phases/8-finalize.md`; any of the three proves a load), `LABEL` (`postmerge` \| `midplan` \| `final`, required), `RUN` (required), `SYNTH` (optional, two consumers — the YAML shape layer's oracle, unset → that layer skips; and the `postmerge` `ask-user` row's classification-tree oracle, unset → that binding is unverifiable and the row degrades to `INCOMPLETE`, not merely a skipped YAML layer) |
| Cwd | the run's gate cwd — the component root on a template run, `$FRONTEND_MOUNT` on a frontend run (a committed git tree either way; see *The gate cwd, and the frontend arm*) |
| Out | the verdict card, TSV to stdout and to `$RUN/gate-<LABEL>.tsv`: `check <TAB> status <TAB> detail <TAB> evidence`, one row per check, then a final `AGGREGATE <TAB> <status>` line. Any previous card for this label is removed first, so an interrupted run leaves no card rather than a stale `AGGREGATE PASS` — and a card whose check-row count is not the label's own (7 `postmerge` / 5 `midplan` / 6 `final`) is refused as `gate-internal` rather than aggregated over the survivors, so a row lost to a failed work-file write cannot yield an `AGGREGATE PASS` either. Beneath the card each check writes its own artifacts: the label-stamped ones (`build-<LABEL>.*`, `test-<LABEL>.*`, `yaml-gate-<LABEL>.*`, `producer-idempotence-<LABEL>.tsv`, and at `final` the marker candidate list `.gate-marker-files.<LABEL>`) and one set of **unlabelled** names shared by all three labels (`producer-build.*`), whose on-disk contents therefore belong to the label that ran last — `reference/state-files.md` indexes them all. The producer verdict is stamped with the label precisely so it can be read back by name: `followup-completeness.sh` keys Phase 6's plan-blocking follow-ups off the `postmerge` verdict specifically (see `reference/gate-cards.md`) |
| Exit | 0 = `AGGREGATE PASS`; 1 = anything else |

It sequences, in order, reusing the existing check scripts unchanged: **build**
(`run-check-modules.sh CHECK=build`, line 3 of `test-command.txt`), **tests vs
baseline** (`run-check-modules.sh CHECK=test` + `comm -13` against
`test-baseline.failures.txt`), **yaml** (`yaml-gate.sh`, honoring
`yaml-gate-ack.tsv`), **producer-idempotence** (`producer-idempotence.sh`), then
the label-specific checks: **conflict-markers** (`final` only — a marker grep
over the set git tracks or would track, minus `.kairos/`, `vendor/` and
`node_modules/`, including the bare-`=======` separator; ignored build output is
out of scope by construction, and a committed dependency tree is excluded by
path — `vendor/` and `node_modules/` are dropped exactly as `yaml-gate.sh` and
`run-check-modules.sh` drop them, but the marker scan excludes **all** of
`.kairos/` where `yaml-gate.sh` excludes only its state dir),
**replace-directives** (`postmerge`/`midplan` — local-path `replace` directives
whose target resolves outside the component root, across *every* `go.mod` under it, parsed with `go mod edit -json`
or, where that is unavailable, a block-aware fallback),
**ask-user** (`postmerge` only — the enactment-coverage compare), and **census**
(`postmerge` and `final` only, never `midplan` — the test-population diff run by
`census-diff.sh`, fed by the sibling `$RUN/census-command.txt` recipe over the
same suite run the test check already makes; detail below).
The raw artifacts
(`.gz` logs, excerpts, per-module TSVs, `yaml-gate-<LABEL>.tsv`,
`producer-idempotence-<LABEL>.tsv`) are written exactly as before — the card adds
pointers, it replaces nothing.

### The `PHASE_KEY` proof-of-load

Every keyed script refuses to run until it is handed the `PHASE_KEY` of the
phase that drives it — the proof that the phase *file* was actually loaded
rather than a phase improvised from the SKILL.md phase index. Two properties
make it work, and they are the same across `gate.sh`, `structural-merge.sh`,
`apply-ask-user.sh`, `log-spawn.sh` and the rest:

- **A phase's key is stated only in that phase file** — never copied into
  SKILL.md or another phase — and the script embeds the same literal, so the
  file and the guard cannot drift. A missing or wrong key is a hard stop
  (`FAIL: load phases/<n>-….md first`), not a degraded run.
- **A phase's own scripts require *that specific* key.** `structural-merge.sh`
  and `apply-ask-user.sh` accept only Phase 5's `p2enxd25`; `log-spawn.sh` under
  `PHASE=7` accepts only Phase 7's `e9tr6bjs`; `in-progress.sh ACTION=advance`
  accepts only Phase 8's `vk3rq8hd`.

`gate.sh` is the one deliberate weakening: it accepts **any** of the three
phase-file keys (`p2enxd25` / `e9tr6bjs` / `vk3rq8hd`), because the same gate
runs at three labels from three phases. So a gate key proves only that *some*
phase file is loaded, not *which* — which is why every phase that also drives a
key-specific script proves itself through that script's *specific* key: Phase 5
via `structural-merge.sh`, Phase 7 via `log-spawn.sh`, and Phase 8 via
`in-progress.sh advance` (whose `vk3rq8hd` gates the run's one irreversible act,
advancing the baseline).

### Reading the card

**The card-reading contract lives in its own doc: `reference/gate-cards.md`.**
What `PASS` / `FAIL` / `INCOMPLETE` / `NEEDS-INPUT` mean, the relay-verbatim
rule, the INCOMPLETE relay rule and its mechanical backstop, the NEEDS-INPUT
disposition, the aggregate rule, and the all-`INCOMPLETE`-still-exits-0 contract
are all there — a small doc the gate-bearing phases point straight at. This
file keeps the check order (above) and the per-check mechanics (below).

**The marker scan runs at `final` only, and its absence is silent.** A card with
no `conflict-markers` row has not scanned for markers — it has not *skipped* the
scan either, so there is no `INCOMPLETE` row to relay and nothing in the card
says the question was never asked. Read `postmerge` and `midplan` accordingly: a
`PASS` aggregate there is **not** evidence the tree is marker-free, and quoting
it as such is the one misreading this label split can cause. What covers the
interval: the resolver verifies its own assigned paths before handing back
(`agents/conflict-resolver.md`), Phase 7 greps the files each task touched, and
`structural-merge.sh` refuses to re-run while a file listed in
`$RUN/conflicts.txt` still carries live markers. Whole-tree assurance arrives
once, at Phase 8.

**Conflict-marker caveat** (`final` label): the `^={7}$` pattern may match a
Markdown setext h1 underline — inspect any hit to confirm it is a stray
separator, not intentional heading markup, before treating the row's file list
as defects. Three shape choices in the pattern keep it from false-failing on
prose (`scripts/gate.sh` owns the exact regex): the labeled markers
(`<<<<<<<`, `|||||||`, `>>>>>>>`) match only with a trailing space, so a
seven-character run inside running text is not flagged; the bare `=======`
separator tolerates an optional trailing CR, so a CRLF-checkout tree still
matches; and the grep runs `-I`, skipping binary files whose bytes happen to
line up with a marker — a conflict marker is text by construction, and a binary
hit has no acknowledgment path.

**Fail-closed by construction.** The script may only emit `PASS` on positive
evidence — the underlying check's status artifact exists, parses, and reads a
recognized value. Every unanticipated state maps to `FAIL: gate-internal`, so a
false PASS requires two independent defects at once; single script bugs manifest
as false FAILs, which are visible and safe.

**A failed listing is not an empty listing.** Any check that builds its candidate
set by asking git or the filesystem captures that command's exit status
explicitly — the marker scan's `git ls-files`, the replace check's `find` for
`go.mod` files. A listing that *failed* (cwd is not a repo, index corrupt, a
subtree `find` could not walk) is `FAIL: gate-internal` — for the marker scan,
naming git's first stderr line — because the scan never ran over a set nobody
knows. A listing that *succeeded* and is empty keeps its `PASS`-with-evidence
semantics: an empty or fully-ignored tree, or a component carrying no `go.mod` at
all, is a real, clean state. The same rule holds in `yaml-gate.sh`, where a failed
listing is a `parse` fail row and exit 1.

## The gate cwd, and the frontend arm

The **cwd is the parameter, not the script.** On a template run every gate runs
at the component root, exactly as the card's *Cwd* row reads. On a **frontend**
run (`RUN_SOURCE=frontend`) every gate — `postmerge`, `midplan` and `final`
alike — runs at `$FRONTEND_MOUNT` instead, invoked as
`( cd "$MOUNT" && … gate.sh )` (`phases/4.5-test-baseline.md`,
`phases/5-structural.md`, `phases/7-execution.md`, `phases/8-finalize.md` carry
the runnable blocks — this section does not duplicate them). Nothing about
`gate.sh` changes: it discovers, sweeps and tallies relative to wherever it is
run, so pointing it at the mount is the whole of what makes it a frontend gate.
The contract is also enforced: `yaml-gate.sh` derives the sanctioned mount from
`$RUN/context.env`'s `FRONTEND_MOUNT` and refuses (a parse-layer fail row) any
other non-toplevel cwd in discovery mode — an accidental subdir invocation
certifies the wrong subtree clean, and a wrong cwd looks precisely like a tree
with nothing to find.
`$SYNTH` on those blocks is the **frontend** run's own materialized pair (the
substituted module BASE/TARGET), never the template's — the same distinction
Phase 2.5's frontend arm draws.

**The final gate on a frontend run is two layers, in order.** *Layer 1* is the
same `gate.sh` at `LABEL=final`, run inside the mount — the mount's own build,
tests, yaml, producer and marker checks. *Layer 2*, run **only after layer 1
passes**, is the component-root **build, and only the build**
(`run-check-modules.sh CHECK=build`): `web/` can break the Go side without a
single Go file changing — `web/entrypoint`'s embed and generated assets compile
into the component root's build, which the multi-module sweep already reaches —
so the root build is the layer that catches it. Layer 2 is read against Phase
4.5's frontend root-build baseline (`build-baseline-root`): a build already red
then is pre-existing rot to report, one that was green then and fails now is the
hard stop this layer exists for. Both layers must pass before `frontend.sha`
advances.

**The Go test suite never gates the frontend baseline.** Layer 2 is `CHECK=build`
by construction; `CHECK=test` at the component root is the Go suite, baselined
against a different cwd and a different source, and letting an unrelated Go test
failure block a frontend adoption would make the frontend baseline hostage to
work it has nothing to do with. Layer 1's `INCOMPLETE` rows follow Phase 4.5's
frontend reading rather than this doc's default: a layer with nothing to do under
the mount (no YAML, no generator, no chart) is relayed as **not applicable**, not
as incomplete semantic coverage.

## The YAML gate

`scripts/yaml-gate.sh`. Catches the class where a merge produces a file that is
valid YAML and wrong — a duplicated block, a swallowed one, or one **re-parented**
so a previously top-level block now nests under a sibling and is silently inert.
Nothing else in the pipeline sees it: there are no conflict markers, YAML isn't
compiled, and tests don't load charts. It surfaces at deploy time instead.

| | |
|---|---|
| Env in | `RUN` (required), `LABEL` (`postmerge` default / `midplan` / `final`), optional `FILES`, `CHART_DIR` (a trailing slash is normalized off), `SYNTH` (materialized target tree — layer 4's oracle), `TARGET_TAG` (default `kairos-target`), `ACK` (buried-key acknowledgments, default `$RUN/yaml-gate-ack.tsv`), `SKILL_DIR` (optional — the skill root, under which the awk libs live at `scripts/lib/`; the script looks in its own `lib/` first and only falls back to `$SKILL_DIR/scripts/lib/`, `SKILL_DIR` itself defaulting to the script's own parent, so only a relocated skill tree needs it) |
| Cwd | component root |
| Out | `$RUN/yaml-gate-<LABEL>.tsv` (`severity <TAB> file <TAB> kind <TAB> detail`), `$RUN/yaml-gate-<LABEL>.txt` |
| Exit | 0 = passed; 1 = a `parse`, `duplicate-key`, `helm-render`, or `buried-key` **failure**, or a failed `git ls-files` discovery (recorded as a `parse` fail row) |

Severities are `fail` and `skip`; kinds are `parse`, `duplicate-key`,
`helm-render`, `buried-key`. A `skip` never fails the gate — but it is not a pass
either (see *Skip escalation*, below).

**No single layer is the semantic layer.** The helm render (layer 3) catches a
template dereferencing a block the merge nilled out; the shape layer (layer 4)
catches a block the merge re-parented. Neither alone is complete, and the render
skips whenever the environment can't fetch a pinned dependency — which is why the
deterministic shape layer exists alongside it, not instead of it.

**Discovery** unions tracked files with untracked-but-not-ignored ones, then
drops `.git/`, `node_modules/`, `vendor/` and the `.kairos/migration/state/`
scratch dir, and skips chart `templates/` (Go templates — layer 3's job, not
YAML). This matters: a template YAML that landed in *this* merge is untracked at
the post-merge gate, and a tracked-only scan would be blind to exactly the files
the gate exists to check. Note the `.kairos/` scope differs from the final gate's
marker scan, which drops the directory wholesale — here only the state dir is
excluded, because a component may legitimately ship YAML elsewhere under
`.kairos/`.

The `postmerge`, `midplan` and `final` labels share this **one** discovery
implementation — `LABEL` only names the output artifacts, never what gets scanned —
so on the same clean tree every label sees the same file set. A YAML file that was
never part of any
structural diff is still discovered at the `final` label. If a run ever reports the
final gate scanning fewer files than the post-merge gate, the cause is
environmental (a working-directory difference, or ignore rules that changed
between the two points), not a second code path — and never a supplied `FILES`
list, which `gate.sh` scrubs (with `CHART_DIR`, `ACK` and `TARGET_TAG`) on every
label so the card is a function of `RUN`/`SYNTH`/`LABEL`/tree alone. A `FILES`
list narrows discovery only on a direct `yaml-gate.sh` call, never through the
gate — check the environmental causes before assuming discovery forked.

### Layer 1 — parse

`yq` must accept every plain YAML file.

**Helm chart `templates/` are excluded**, because they are Go templates, not YAML:
`{{- if .Values.x }}` is a parse error by construction. Including them produced a
parse failure on every file of every real component. They are covered by layer 3
instead.

### Layer 2 — duplicate mapping keys

`lib/yaml-dupkeys.awk`, POSIX awk (runs under macOS stock `/usr/bin/awk`), no new
dependency. `yq` silently keeps the last value for a duplicated key, so it cannot
be used for this.

**Design rule: false positives are unacceptable, false negatives are fine.** A
spurious finding blocks a migration on a non-problem; a missed one only leaves us
where we already were. So wherever the scanner cannot confidently interpret a
construct it drops tracking for that mapping block rather than guess. It correctly
ignores block scalars (`|`, `>` and their indicator forms), comments, flow
collections, `<<:` merge keys, and sibling sequence items — two `-` list items
each carrying `name:` are separate mappings, not a duplicate. Quoted and unquoted
spellings of the same key *are* treated as duplicates.

Because chart templates are excluded from this layer, the scanner is **re-run over
helm's rendered output** when layer 3 succeeds. That keeps the duplicate-key
guarantee over chart templates — where a duplicated `resources:` block is the
motivating example — at the point where the conditionals are resolved and the
content really is YAML.

### Layer 3 — best-effort Helm render

Catches one shape of "valid YAML, broken semantics": a merge that nils out a block
another template dereferences renders as a nil-pointer error and nothing else
notices. It is **not** the only semantic layer — layer 4 catches re-parenting on a
clean merge and does so deterministically, without a render.

Chart auto-detection searches for a directory containing `Chart.yaml`, excluding
`*/charts/*` (vendored subcharts render as part of their parent). Components put
the chart at `chart/` or `charts/` depending on template vintage, hence a search
rather than a hardcoded path.

Three outcomes, and the distinction is the point:

| Situation | Verdict |
|---|---|
| `helm` not on PATH | `skip` — reported, gate still passes |
| unfetchable pinned dependency, missing repo definition, no credentials, network failure | `skip` with the reason |
| helm ran and the chart is genuinely broken | `fail` |

`helm dependency update` is never run — that reaches the network. An environment
gap is an honest skip, never a silent pass and never a hard block. But a skip must
be **relayed as a skip**: for burial *inside* a chart template (Go templates,
excluded from layers 1, 2 and 4), the render is the only cover, so a skipped render
means the migration shipped without that check.

### Layer 4 — structural shape (buried top-level key)

Deterministic, works on clean merges, independent of the render. Its oracle is the
**materialized target tree** (`$SYNTH`, tag `kairos-target`) — already
placeholder-substituted and LF-normalized in Phase 2.5, so a path in it is a
component path. The invariant, in full:

> For every declarative config file present in both the target tree and the
> working tree: a key that is a **top-level** mapping key in the target file must
> not appear in the working tree **only** as a nested key beneath a different
> top-level mapping.

This shape is what keeps the layer inside the gate's design rule (false positives
are unacceptable):

- **Burial fails; absence does not.** A key simply missing from the working tree
  is a legitimate component choice (config it doesn't use, or deliberately
  removed). Only *present-but-demoted* is the defect.
- **Renames pass automatically.** A key the template renamed is top-level in the
  target and, after a correct merge, top-level in the working tree; the old
  spelling is not in the target and is never examined. A hardcoded key list would
  instead false-fail the very migration that adopts the new name — worse than the
  gap it was meant to close.
- **One direction only.** A key the working tree keeps top-level and the target
  nests is ambiguous (component customization) and is not examined.
- **Ambiguous frames are dropped, not guessed.** A multi-document stream, a
  sequence or flow-collection root, a `<<:` merge at the root, or tab indentation
  has no single unambiguous top-level frame; `lib/yaml-toplevel.awk` emits `AMBIG`
  and the file is dropped, the same care `lib/yaml-dupkeys.awk` takes. (An anchor
  or alias is not itself an ambiguous frame — it rides the value side of an
  ordinary key and does not trip the bail-out.)

Scope is the plain-YAML surface only — the same discovery set as layers 1–2, which
already excludes chart `templates/` (Go templates). So burial *inside* a chart
template stays covered only by the render (layer 3); this layer does not close that
sub-case, and that boundary is deliberate.

**Deliberate demotion is the residual false positive, and is overridable.** A
component may legitimately fold a top-level block under an environment/profile key
of its own — that is *present-but-demoted*, so the invariant flags it. A
`buried-key` finding is therefore **acknowledgeable**: a row in `$ACK`
(`file <TAB> key <TAB> reason`) turns that finding into a `skip` (acknowledged
exception) instead of a hard `fail`, reusing the skip-escalation vocabulary. An
un-overridable fail on a legitimate restructure would itself be a false positive.

**No target tree → skip, not pass.** When `$SYNTH` is unset or the target tag is
missing (an explicitly supplied file list, or a resumed run whose state dir was
swept), the layer has no oracle: it records a `skip` with the reason and that skip
escalates like any other. It is a semantic layer, so its absence is a coverage
gap.

## Producer idempotence

`scripts/producer-idempotence.sh`. Runs the tree's own producers and asserts they
leave tracked state clean. It subsumes two merge-correctness defects as one check:
a stale committed generated artifact (running the regeneration command modifies a
tracked file), and a producer whose output is tracked rather than ignored (running
the build emits an un-ignored file).

| | |
|---|---|
| Env in | `RUN` (required), optional `LABEL` (the gate label — threads into the TSV's name so each label keeps its own verdict; unset keeps the bare name for direct invocation), optional `BUILD_CMD` / `REGEN_CMD` (override `$RUN/test-command.txt` lines 3 / 4) |
| Cwd | component root (a committed git tree) |
| Out | `$RUN/producer-idempotence-<LABEL>.tsv` (`producer <TAB> verdict <TAB> detail`; `$RUN/producer-idempotence.tsv` when `LABEL` is unset); `$RUN/producer-build.*` — the build producer's sweep artifacts (see below) |
| Exit | 0 = every producer `clean`, `skip` or `producer-failed`; 1 = a `dirty-tracked` or `untracked-output` finding, or the check could not run at all |

Verdicts: `clean`, `dirty-tracked` (a tracked artifact moved → regenerate; acceptance
is that a second run produces no diff), `untracked-output` (an un-ignored file → untrack
and add an ignore rule), `producer-failed` (the producer exited non-zero), `skip`.
`gate.sh` recognizes all five: `producer-failed` is a finding row (a clean `FAIL`
naming the producer), never `gate-internal`.

A `dirty-tracked` row from `make generate` means a stale artifact only when kairos-gen
is pinned (`grep -q 'kairos-component-common/cmd/kairos-gen' go.mod`). Without the pin,
the toolkit version decides (Phase 4.5 logged which case applies to `$RUN/learnings.md`).
On toolkit ≥ v1.0.49, generate runs only the `go tool` pin, never PATH, so it fails: a
`producer-failed` row on `make generate` is the missing pin (the `pin-kairos-gen-go-tool`
task), not a merge defect and not drift. On toolkit < v1.0.49, generate runs the PATH
binary (`kairos-gen --version`); a moved `sql/1.gen/` or `topic-config.json` may then be
generator drift, not a merge defect. Say which when relaying the row.

**Detection is by the tree's reaction to its own commands** — no knowledge of which
artifacts a template generates, which symbols a generator emits, or where a runtime
puts its binaries. The producers are the build already discovered in Phase 4.5 and a
regeneration command discovered the same convention-ordered way (a declared regen
target where the component has one, else nothing), both read positionally from
`test-command.txt`. Where no regeneration command exists the build half still runs.

**Scope: the build producer is swept across modules, the regeneration producer is
root-scoped.** The build half runs through `run-check-modules.sh`
(`CHECK=build`, `OUT=$RUN/producer-build`) — the same multi-module sweep every other
build path in the skill uses — so a sibling `go.mod` is audited too. That is the
motivating case, not a hypothetical one: `go build ./...` in a module carrying a
single main package writes that binary *into* the module directory, which is exactly
the `untracked-output` verdict this check exists to produce, in exactly the
`web/entrypoint` shape the sweep section below names. A non-`go` command and a
single-root component delegate verbatim to `run-check.sh`, so every verdict derived
from their output is unchanged. The regeneration half stays at the component root:
Phase 4.5 discovers that command root-scoped by construction, so there is no
per-module command to sweep.

The sweep's own artifacts land at `$RUN/producer-build.*` (aggregated log, per-module
logs and excerpts, `producer-build.modules.tsv`). `$RUN` is the state dir pre-flight
puts in `.git/info/exclude`, so they never enter the `git status` delta below.

**A producer blocked by an ENVIRONMENT gap skips; it does not fail** (any other
non-zero exit is `producer-failed`, below). A generator may reach
the network (module or tool fetches) — the same environment gap the helm render
handles as a skip. The skip carries its reason and escalates as incomplete coverage;
it is never rounded up to a pass and never a hard block. Under the sweep that reason
is read from the aggregated log rather than from a single captured run, and the skip
names the module(s) that did not come back `OK`.

**The check restores anything it touched** — it reverts a dirtied tracked file to HEAD
and removes an emitted un-ignored file — so auditing idempotence never itself dirties
the state being audited. It runs at every gate label (postmerge, midplan and
final), each over a committed tree. The restore is bounded by the before/after `git status` delta and nothing else:
the sweep widened the paths that can appear in it to every module's output, so a
pre-existing untracked file in a sibling module is outside the delta and survives.

**A producer that exits non-zero still classifies and restores.** Leave-as-found
holds even when the producer doesn't: the after-snapshot is still taken, dirtied
tracked files are still reverted and emitted un-ignored files still removed, so
half-emitted debris never rides into the next commit. The verdict is
`producer-failed`, carrying the producer's exit code and the tail of its output, and
`gate.sh` maps it to `FAIL` — never `clean`, never `PASS`. A failed run's delta is
debris, not evidence, so it is reported inside that row rather than as a
`dirty-tracked` / `untracked-output` finding drawn from a run that never finished.

## The positional `$RUN/test-command.txt` contract

Written by Phase 4.5; read by Phases 5, 7, and 8. This section is the contract's
one home — the phase files reference it rather than restating it.

`$RUN/test-command.txt` is **positional** — line 1 test command, line 2 extractor, line 3 build command, line 4 regeneration command — read by line number by `gate.sh` at all three labels, by `producer-idempotence.sh` (lines 3–4), and by the planner, which copies the commands into `PLAN.md`'s `## Test Baseline` section. **The executor never reads this file** — its test and build commands come from that PLAN.md section (`phases/7-execution.md`, `agents/executor.md`), so a discovered command only reaches execution by way of the plan. **Append rejections after line 4**, never above it, as `# rejected: <cmd> — <reason>`. If a positional line has no command, the literal `no tests detected` / `no build check` / `no regen command` goes on that line so line numbers never shift, and the user is told the affected gate is weaker than usual here.

**`scripts/write-test-commands.sh` is the format owner, and this section is its documentation — never write or append to the file yourself.** Pass the four positional values (`TEST_CMD`, `EXTRACTOR`, `BUILD_CMD`, `REGEN_CMD`) — plus `CENSUS`, which the same call routes to `census-command.txt`, written on every command-write call and carrying the literal `no census extractor` when the value is empty — and it places them: an empty value becomes its literal placeholder (`no tests detected` / `no build check` / `no regen command`) — **except line 2**, which is left *empty* when there is no test command, because a literal there would be eval'd as an extractor, while an empty line 2 under a real line 1 is exactly the `gate-internal` FAIL it should be; a value carrying a newline or tab is collapsed first (a two-line pipeline would otherwise push every line below it down), and a `TEST_CMD` with no `EXTRACTOR` is refused at write time because that pair is already a `gate-internal` FAIL at every label. Rejections go through the same script (`REJECT` + `REASON`), which places them strictly below line 4 — creating the four placeholder lines first when discovery rejects a candidate before choosing one — and drops an exact duplicate, so a re-entered Phase 4.5 is byte-identical rather than restacked.

On a **frontend run** the call passes `MOUNT` (the frontend mount, e.g. `web/`) instead of the test/build values: lines 1 and 3 are *discovered* from `$MOUNT/package.json` by the script itself — the default watch-mode `test` script never exits, so discovery rejects it with a `# rejected:` line rather than recording a command that would hang every gate — and passing `TEST_CMD`/`BUILD_CMD` alongside `MOUNT` is refused at write time. The recorded commands are the ones to run with cwd at the mount (`phases/4.5-test-baseline.md` owns the arm; the script header carries the full discovery order).

## Zero-evidence guard on discovered commands

A discovered command can exit 0 having done no work — `make vet` on macOS compiles
zero packages and exits 0. That vacuous green becomes the Phase 4.5 baseline and
every later gate inherits it, appearing to pass forever while checking nothing.

So a candidate must produce **evidence of work** or be discarded for the next one in
the preference order:

- **test command** — the suite must demonstrably have **run**, which is what
  `$OUT.status` records: `OK` (ran green) or `FAIL` with a non-empty failure set.
  Do **not** read this as "at least one extracted test ID" — the extractor
  extracts *failures* only, so a fully green suite legitimately yields zero IDs,
  and a literal ID count would discard every healthy component's command. What
  disqualifies a candidate is the absence of work, not the absence of failures:
  `EXTRACTOR_MISMATCH` (the extractor and the output disagree), `SKIP` (no module
  ran a check at all), and an `OK` over output matching the do-nothing patterns.
  Same rule, stated at the call site: `phases/4.5-test-baseline.md`.
- **build command** — output must not match a known do-nothing pattern
  (`No directories changed`, `no packages to build`, `nothing to be done`, zero
  targets reported).

Rejections are recorded next to the chosen command in `$RUN/test-command.txt`
(`# rejected: <cmd> — <reason>`) so the gates can be audited afterwards. If every
candidate is vacuous, record "no tests detected" / "no build check" honestly and
tell the user the gates are weaker than usual for this component — a stated gap is
useful; a fake pass is not.

## Go multi-module sweep

`scripts/run-check-modules.sh`. The gate records one build command and one test
command and runs each across every module under the component root, not just at
the root. `go build ./...` compiles only the module it runs in and nothing else
— so a component carrying sibling `go.mod` modules needs this sweep, or a break
the merge lands in a non-root module stays invisible until a manual build
afterwards.

| | |
|---|---|
| Env in | `CMD` (required), `OUT` (required), `PHASE_KEY` (**required only when `basename(OUT)` is exactly `test-baseline`** — the Phase 4.5 baseline call site, whose key is stated in `phases/4.5-test-baseline.md`; every other stem, including the gate's `build-<label>` / `test-<label>` and Phase 7's `test-task-<id>`, needs none), `CHECK` (`build` default / `test`), optional `EXTRACTOR`, `EXCERPT_MAX`, optional `CENSUS` |
| Files in | `$RUN/census-command.txt` — not read by this script; `gate.sh` reads that one line and passes it in as `CENSUS` (the census section below) |
| Out | run-check.sh's artifact set at `$OUT`, aggregated; `$OUT.modules.tsv` (`module <TAB> verdict <TAB> detail`); `$OUT.<slug>.*` per module; **only when `CENSUS` is set**, `$OUT.population.txt` / `.skips.txt` / `.census.status` (`OK` \| `MISMATCH` \| `ABSENT` \| `FAILED`) |
| Exit | 0 = every module that ran passed; 1 = any `FAIL` or `EXTRACTOR_MISMATCH` |

**It applies to `go` commands only.** The first word of `CMD` that isn't a leading
`VAR=value` assignment must be exactly `go`. `make test` may well run go
underneath, but `cd pkg/schema && make test` has no Makefile to run, so a
non-`go` command has no defined per-module meaning — and speculative polyglot
module discovery buys nothing. A non-`go` command, and a Go component whose only
module is the root, delegate verbatim to `run-check.sh` and produce artifacts
byte-identical to a direct call. Nothing changes for those components.

**Discovery** is every `go.mod` under the component root except `vendor/`
(dependency modules), `.kairos/` (the migration's own scratch trees — building the
synthetic merge sides would be nonsense), `node_modules/`, `testdata/` (fixture
modules, not build surface) and `.git/`. The gate's replace-directive check
discovers its candidates with the same five exclusions, so the modules that get
built are the modules that get audited.

**The build gate runs in every module. The test gate skips a module with no
`*_test.go`**, recording the reason in `$OUT.modules.tsv`. `go test` in a
test-free module exits 0 having run nothing — the vacuous green the zero-evidence
guard exists to reject — and skipping is both cleaner and honest about what ran.
Test files are credited to the *longest* matching module prefix, so the root is
never credited with `pkg/schema`'s tests: a separate module's tests genuinely do
not run under the root's `./...`.

`test-command.txt` stays the discovered command **template** (positional: line 1
test, line 2 extractor, line 3 build, line 4 regeneration command). The sweep
lives in the runner, so nothing downstream has to parse a per-module command out
of a recorded string.

**Per-module reportability is the point** — "the build failed" is not actionable,
"`web/entrypoint` failed to compile" is. Hence three things: a per-module verdict
row in `$OUT.modules.tsv`, a per-module `$OUT.<slug>.excerpt.txt`, and failure IDs
from a non-root module prefixed `<module>:` in the aggregated
`$OUT.failures.txt`. Root IDs stay verbatim, which keeps a single-module
component's failure set unchanged and keeps the `comm -13` baseline comparison
line-for-line valid.

That comparison is also why the **Phase 4.5 baseline goes through the same
wrapper**: a root-only baseline against a swept gate run would report every
pre-existing sibling-module failure as a merge regression.

Aggregate `$OUT.status` is `EXTRACTOR_MISMATCH` if any module reported it, else
`FAIL` if any module failed, else `OK` — with one more value: `SKIP`, when a test
sweep found no module carrying tests at all. That is zero evidence, and calling
it `OK` would be the vacuous green in a new costume.

**`CENSUS` rides the same sweep**, handed to every module verbatim, and the
per-module populations and skips are unioned under the same `<module>:` prefixing
rule the failure set uses (root ids verbatim), so a disappearance downstream stays
attributable. Aggregate `$OUT.census.status` is `FAILED` if any module's census
recipe errored (non-zero exit — the recipe cannot be trusted, so the population is
discarded), else `MISMATCH` if any module reported it, else `OK` if at least one
module produced a census — including an all-green
sweep that censused an empty set, which is `OK` over an empty population, **not**
`ABSENT` — else `ABSENT`, meaning no module produced one at all (every module was
`SKIP`ped). With `CENSUS` unset, not one census byte is written and any stale
census artifact is cleared.

## Local-path `replace` directives

A `replace` in `go.mod` pointing outside the component is co-development state. It
requires a sibling checkout that exists only on one machine, so it breaks CI —
silently, because it builds fine locally.

A target that resolves **inside** the component root passes silently. Every
template-born `go.mod` carries `replace …/pkg/schema => ./pkg/schema`, and CI
resolves it from the same checkout. The target is resolved against the directory
of the `go.mod` that carries it, so `web/entrypoint`'s `../../pkg/schema` is in-repo
too. A `..` that climbs above the root (`../x`, `./pkg/../../x`) is outside it.

This is **detect-and-ask**, never auto-dropped: a template author co-developing
`kairos-component-common` locally has a legitimate reason to keep it. Show the
directives, ask keep or drop, and record the decision — including, when kept, that
CI will break. Auto-dropping would destroy deliberate state; auto-keeping would
ship a broken pipeline.

**Scope: every `go.mod` under the component root**, discovered the way
`run-check-modules.sh` discovers its modules and with the same exclusions
(`.git/`, `.kairos/`, `vendor/`, `node_modules/`, `testdata/`), so the modules that
get built are the modules that get audited. A sibling module (`pkg/schema`,
`web/entrypoint`) breaks CI on an inherited local replace exactly as the root does.
A component with **no** `go.mod` anywhere is a `PASS` whose detail says so; a
component with no *root* `go.mod` is still scanned through its nested modules.

**Parse, not grep.** A block-form group carries the `replace` keyword only on its
opening line —

```text
replace (
	example.com/common => ../kairos-component-common
)
```

— so a line-form `grep '^…replace.*=>'` sees none of the inner directives, and a
co-developed component is exactly where several replaces accumulate and get
grouped. The check uses `go mod edit -json` (the primitive `codev-check.sh` ships
for the same reason) and, where `go` is not on `PATH` or cannot parse a file — a
`go` directive above the installed toolchain, which a template bump routinely
produces — a **block-aware fallback** that tracks group state instead of matching a
keyword per line.

`go mod edit -json` is the authority. The fallback is a line scanner with that
group state machine added, **not** a second implementation of go's `modfile`
parser; its exact coverage — comment stripping, whitespace/CRLF trimming, the
quoted token spellings `go.mod` permits — is `codev-check.sh`'s to own, and
shapes outside that it does not see. Which parse produced a row is therefore
always stated in its detail (`parsed via go mod edit -json`, `…via the
block-aware fallback`, or the mixed count), so degrading to the narrower parse is
disclosed rather than silently substituted. A `go.mod` neither method could read
is `FAIL: gate-internal` naming the file — never a `PASS` claiming more than was
checked. Relative-path targets that escape the root and **absolute-path**
targets (`/…`) are findings; an absolute path is one even when it points into
this checkout, because it names one machine's directory. The absolute arm is deliberate, not incidental:
`go mod edit -replace mod=$(pwd)/../common` — the natural CLI spelling — writes an
absolute new path, which breaks CI exactly as `../` does, and a filter matching
only `./`/`../` issued an affirmative `PASS` over it. A module path can never
begin with `/` (its first element must be a domain), so a leading `/` on the
new-path side is always a filesystem path, never a module. Only a **versioned**
`replace` is not a finding — it is not co-development state, quoted or not.

## Ask-user enactment coverage (`postmerge` only)

The `ask-user` row compares the classified ask-user set — the three ask-user
buckets (`binary-for-user`, `added-heavyweight-ask-user`,
`deleted-heavyweight-ask-user`) across `classification.tsv` + `binaries.txt`,
union de-duplicated by path, the same union `apply-ask-user.sh` enacts from —
against `$RUN/ask-user-applied.tsv`. Zero classified items is a `PASS` with
evidence, not an `INCOMPLETE` (mirroring the marker check's
empty-candidate-list precedent). A missing or unparseable applied file while
classified items exist is `gate-internal`, fail-closed.

**The classification's synthetic-tree binding is re-verified before the tally** —
`$RUN/classification-trees.tsv` against the `kairos-base` / `kairos-target` trees
in `$SYNTH`, the same binding `structural-merge.sh` refuses on — because coverage
computed from a classification derived against *other* trees audits a set nobody
enacted. `apply-ask-user.sh` makes that same refusal at enactment time, so a
drifted binding stops the ask-user rows from being enacted at all rather than
being reported once the tree is already written; this row stays the post-hoc
catch, for a `$SYNTH` that moved after the enactment. Three outcomes, since
`$SYNTH` is optional here: verified (the row keeps
its `PASS`, and the evidence column records the binding as checked); drift, or a
missing/unreadable binding file (a `FAIL` carrying the re-run-Phase-3-then-redo-Phase-5
remedy); or **unverifiable** — `$SYNTH` unset, or no longer a synthetic repo —
which degrades both clean arms to `INCOMPLETE`, including the zero-classified
one. That degradation is neither a block (the contract makes `$SYNTH` optional,
and failing finalize over a directory an operator legitimately cleaned up would
be the false positive this script forbids) nor a silent pass (the tally is then
computed from a classification nothing can check).

It runs at `postmerge` only: a plan task may legitimately revert an applied
item, and a row flagging that would be a false positive — the coverage question
is only well-posed immediately after Phase 5. The row is deliberately redundant
with `apply-ask-user.sh`'s own fail-closed decision check: the script catches a
half-answered batch; only this row catches step 4b being skipped entirely.
Removing either one restores a live failure mode.

## The census row

`scripts/census-diff.sh`, run by `gate.sh` at `LABEL=postmerge` and `LABEL=final`
only — never at `midplan`. It closes a blind spot none of the checks above can:
every one of them compares *failure* sets, so a test that stopped existing —
deleted, `t.Skip`ped, excluded by a build tag, or silently dropped because its
package stopped compiling into the test binary — passes every one of them by
construction. The census records which tests **ran** at each epoch and diffs the
populations instead.

**The recipe lives in a sibling file, never a fifth positional line.** The
positional `$RUN/test-command.txt` contract (above) is closed at line 4 —
everything below it is the rejection audit trail — so the census extractor rides
`$RUN/census-command.txt`, one line, written by `write-test-commands.sh` in the
same call that records the four positional commands. `gate.sh` reads that one
line and passes it as `CENSUS` to the *same* single suite run the test check
already makes through `run-check-modules.sh`: population and skip artifacts
(`test-<label>.population.txt`, `test-<label>.skips.txt`,
`test-<label>.census.status`) land as a free rider on that one pipe, for
`postmerge` and `final` alike. There is never a second suite run to obtain them.

**At `final`.** Two executor-era findings, each a top-level test ID:
*disappeared* (present in the `postmerge` population, absent from the `final`
population **and** skips — deleted, or no longer compiled in) and
*newly-skipped* (verdict-bearing at `postmerge`, a skip at `final` — silenced at
runtime). `FAIL` if either set is non-empty — a real finding, dispositioned
exactly like any other gate `FAIL` (the Phase 8 stop-or-accept valve applies; no
new bureaucracy). The disappearance/newly-skipped row and the clean `PASS` row
both carry the count of tests *added* since `postmerge` alongside the findings,
so a rename reads as a rename — one disappearance plus a positive addition count
— rather than a bare deletion. (The one exception is the total-loss row below:
when the `final` epoch censused nothing at all, the mass-disappearance rationale
is its detail, without an addition count.) Template-era change
(`postmerge` vs baseline population counts) is a **detail line on the row, never
its status**: the planner already saw it at the `postmerge` gate below;
resurfacing a template deletion as a `final` finding would train a rubber stamp.
`PASS` only on positive evidence, same as every other row in this doc: both sets
empty, with the population sizes compared named in the evidence column.

**Total loss is a `FAIL`, and only the *transition* is.** A `final` epoch that
ran and censused an **empty** population where the base epoch had ids is a
`FAIL` whose row says so in words (`mass test disappearance: … no
verdict-bearing test ran at final`), not an `INCOMPLETE`. This is the one case
the census exists for and the only row in this doc that can see it: every other
check compares *failure* sets, and a component with no tests left produces no
failures at all — delete every test and the build row and the tests row both go
green. The FAIL is dispositioned like any other (Phase 8's stop-or-accept valve
applies), so a deliberate mass removal is still user-acceptable — it just has to
be said out loud. What keeps the rule from firing on a component that never had
tests is the distinction below: **empty is not absent.** A base epoch that also
censused empty means nothing was ever there to lose → `PASS`. And because a
census recipe that silently stopped matching produces an empty population too,
the FAIL row names that alternative explanation for the reader to rule out.

**At `postmerge`.** Always `INCOMPLETE` — there is no `final` epoch yet to diff
against, so the row can never be a finding at this label. Its detail line
carries the template-era count instead (`template-era (baseline→postmerge): N
removed, M added`), an informational relay for the planner: tests the template's own merge
removed are planning input, not a Phase 8 surprise. `phases/5-structural.md`'s
postmerge gate relays this row exactly as it relays any other
`INCOMPLETE` row — into the migration log, never as clean.

**Never `PASS` on a census that could not be produced honestly.** These states
collapse to `INCOMPLETE`, never a finding and never green: the census is
unavailable (`census-command.txt` carries no real extractor, so no population
artifacts exist for the epochs that need them), an epoch needed for the diff
reports `MISMATCH` (the runner already deleted that epoch's population and
skips — a half-true population is worse than none) or `FAILED` (the recipe
itself errored — a missing tool, a wrong flag, a non-zero exit — so
`run-check.sh` recorded `census.status=FAILED` and discarded the population;
an errored recipe can no more ground a diff than a `MISMATCH` can, and because
a broken-from-the-start recipe errors at *every* epoch this is what stops an
empty↔empty false `PASS` — distinct from a recipe that merely stopped matching
but exited 0, which stays `OK` over an empty population), there is no populated
base epoch to diff the `final` population against, or the tests check itself
refused at this label (missing or malformed `test-command.txt`, `no tests
detected`, missing/unreadable baseline) — the gate sweeps the current label's
census triplet before dispatching that check, so a refusal leaves no epoch
artifacts behind and the census can never grade a suite run that did not
happen in this invocation. "The question could not be
asked" must never read as "nothing disappeared." Each `INCOMPLETE` reason names
the epoch it belongs to — when both base epochs are unusable the row carries
both reasons, each under its own epoch's name, so it points at the artifact that
actually failed.

**Empty is not absent.** An epoch whose `census.status` reads `OK` and whose
population file exists but holds nothing *ran and censused nothing* —
`run-check-modules.sh` writes exactly that for a legitimately test-free module
set (all helpers, every module green). That is a different fact from "no census
recorded", and the two are graded differently: at `final`, censused-empty
against a populated base is the mass-disappearance `FAIL` above; censused-empty
against a base that was also empty is a `PASS`; a census that is absent
altogether is `INCOMPLETE`. As a diff *base*, an empty epoch is unusable either
way — there is no id to compare a later epoch against — so attribution degrades
to the next epoch or the row reads `INCOMPLETE`.

**The degraded diff is labeled unattributed.** When the `postmerge` census is
absent — a run resumed across this feature's adoption, or an `INCOMPLETE`
postmerge-gate test row — `census-diff.sh` degrades to a single `baseline`→`final`
comparison instead of refusing outright. Its findings are explicitly labeled
**unattributed**: template noise and executor guilt are both possible causes and
the row does not have enough epochs on hand to tell them apart, so it says so
rather than pointing a finger either way — template noise must never read as
executor guilt.

## `verify-script:` discrepancies

`verify-script:` one-liners are written by template authors and are sometimes simply
wrong — a grep that cannot match, a path that moved — which makes the skill report a
correctly-applied upgrade-file as never applied.

The asymmetry: **a passing script is trusted outright; only a failing script is
cross-examined.** Only failures cost anything to get wrong.

On failure, re-check by judgment against the upgrade-file's `verify:` prose and the
actual tree:

- judgment agrees the change is absent → a real failure, handle normally.
- judgment finds the change correctly applied → trust judgment, treat it as
  verified, tell the user the script was overridden, and record the contradiction
  in the Phase 8 **Template feedback** section.

That last step is what gets the script fixed upstream. Left unreported, it
misreports on every component that migrates through that upgrade-file.
