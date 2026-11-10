# Model resolution — how and why

`scripts/resolve-models.sh` mechanizes Decision A (which model fills each of
the three tiers for this run) so two runs on the same machine never resolve
differently just because a human eyeballed the list twice. Decision B
(per-task routing from the plan's `Flag`) is a separate, later decision —
it lives in `phases/7-execution.md`, not here.

This doc is the "why" behind that script and behind the Model selection /
Spawn accounting mechanics in SKILL.md. Read the script's own header first —
it's the at-hand summary; this is the fuller rationale for when the summary
isn't enough.

## Contents

- The asymmetric rule: derive capability, never cost
- Sibling variants: two suffix kinds, two rules
- BUDGET postures
- Why pins are per-run, never persisted
- `~/.kairos/models.yaml` — answers, not resolutions
- Shortfalls: what degrades, what refuses
- Exit codes and their causes
- Override env vars
- Spawn accounting: why `requested_model` is its own column

## The asymmetric rule: derive capability, never cost

The script picks each tier's model by **capability first, cost second** —
never the other way around. Per tier:

1. Discard offered models below the tier's capability bar.
2. If any surviving model is plan-`included` (free under the subscription),
   take the **strongest included** one — strength is free there, so there's
   no reason to economize.
3. Otherwise every surviving candidate is metered (an unknown cost class
   counts as metered, never as included), and the pick is **tier-matched** —
   the lowest capability rank that still clears the bar, and the strongest
   model within that rank.

The asymmetry matters most at step 3: the rule deliberately does **not**
apply "strongest in class" once everything is metered. If it did, the
executor tier — which fires many times per run — would silently resolve to
whatever premium model happens to be offered, and a routine task would rack
up premium-tier cost with no one having decided that. Tier-matching keeps
metered spend proportional to the tier's job.

`strong=` has its own ceiling on top of this: it is capped at the standard
flagship rank and never promoted into a premium tier above it, even when a
premium model is offered and even when it's included. Judgment roles get the
best *standard* model, not the best model that exists — a premium tier is a
deliberate purchase, not a default. It yields in exactly one case: when
*every* ranked offered model is premium there is nothing within the ceiling
to pin, and a loudly warned premium pin beats an empty one (see Shortfalls
below).

## Sibling variants: two suffix kinds, two rules

Some catalog families ship the same model at two points. The suffixes are
**not interchangeable** — Cursor's `-fast` is not Gemini's `-flash`.
`stronger()` in `scripts/resolve-models.sh` treats same-family siblings
specially, and which half wins depends on **which list** the suffix is on.

**`speed_suffixes` (`-fast`)** — Cursor Fast: the same weights served with
more capacity. Same intelligence, lower latency, **higher** token cost
(~6× on Composer 2.5). The suffix does **not** demote capability (a lone
`-fast` slug still ranks with its family). When both halves are offered,
**every tier prefers the base**. Fast is a latency purchase, and the
volume executor would drain the included pool ~6× faster if it quietly
took it. Want Fast anyway? `--executor-model` (or the standing env var).

A resolution where `executor=<model>` sits next to `coder=<model>` even
though `<model>-fast` was offered is therefore **correct**, not a
mismatch to "fix" with an override.

**`weak_suffixes` (`-mini`, `-lite`, `-flash`)** — a distilled / smaller
sibling that trades capability for cost. The suffix list is family-agnostic:
it applies to any family a slug classifies into, catalogued or ranked via a
`capability_overrides` answer. Of the three, only `-mini` is exercised by a
currently-catalogued family (`gpt-5` ships `gpt-5-mini`); `-lite` and `-flash`
are recognized for families the catalog does not yet rank — they are not dead,
just unexercised by today's `reference/model-families.yaml`. The rule **flips
by tier**:

- The **quality tiers** (`strong`, `coder`) prefer the **base** (non-weak)
  sibling. Those tiers exist for capability, and the suffixed variant trades
  some of it away — the tier should not quietly take the weaker half of a
  pair it was never asked to.
- The **executor** tier prefers the **weak-suffixed** sibling instead. It
  fires many times per run, so the cheaper/lighter variant is the better
  fit for that tier's job — this is the rule working as designed, not a
  bug.

This holds whether the pair shares an exact base (`gpt-5` vs `gpt-5-mini`) or
is a cross-suffix pair at the same version (`<fam>-flash` vs `<fam>-pro`): the
weak-suffixed candidate loses to a non-weak same-family sibling on the quality
tiers and wins on `executor`. (The cross-suffix case is decided *after* the
version compare below, so a genuinely newer distilled slug still beats an older
non-weak one — the demotion is only a same-version tiebreak.) A resolution
where `executor=<model>-mini` sits next to `coder=<model>` from the very same
family is therefore **correct** for a weak suffix.

### How ties break — what "strongest" means

"Strongest" is not one scalar. `stronger()` decides a pair by trying these in
order, first rule to fire winning:

1. **Capability rank** — the family's `cheap` < `coder` < `strong` < `premium`
   position; a higher rank wins outright.
2. **Same-family siblings** — within one family, the speed-suffix rule (base
   wins every tier) then the weak-suffix rules above.
3. **Version** — higher numeric version segments, compared left to right; a
   missing segment loses to a present one. A trailing Anthropic build-date
   (`-YYYYMMDD`) is **not** a version segment — it is consulted only as the
   lowest-priority tiebreaker between two otherwise-equal versions (newer date
   = stronger), so a real minor-version bump can never be outranked by a date.
4. **Alphabetical (ASCII), earliest wins** — the true last resort, reached only
   by two same-rank slugs with no comparable version and no sibling relation,
   most often a same-rank *cross-family* pair (`gpt-5` beats `sonnet-4.5` for
   no reason but that `g` sorts before `s`). This is arbitrary, not a capability
   judgment; when it decides a tier you care about, pin that tier with an
   explicit `--*-model` override rather than trusting the sort order.

## BUDGET postures

`BUDGET` is a per-run risk posture, not a saved preference:

- **`frugal`** — the same **per-tier selection** as `balanced`. This surprises
  people: the asymmetric rule *already* takes the strongest *included* model
  that clears each bar, so there is nothing more for frugal to prefer — the
  selection code path is identical, only the stderr wording differs. What
  frugal actually changes is the tier **count** and how loudly it reports
  metered spend. The collapse: `coder` collapses into `executor` — one fewer
  tier to reason about, one fewer metered surface — **unless an explicit
  `--coder-model` (or standing `KAIROS_UPDATE_CODER_MODEL`) pins it, which
  suppresses the collapse** and gives frugal three distinct tiers again. The
  exemption: `strong` is never subject to any frugal thrift and stays on its
  resolved pick even when that pick is metered, because judgment mistakes are
  unrecoverable. The fallback (shared with balanced): if **no** included model
  clears a tier's bar, frugal does not block and does not degrade below the
  bar — it takes the tier-matched *metered* pick and says so on stderr
  (`[frugal: no included model offered — cheapest metered tier; this is NOT
  free]`). Frugal is a preference, not a guarantee of zero metered spend; the
  diagnostic is the only signal, so read stderr before assuming a frugal run
  cost nothing. Frugal also emits a one-off `CHOICE:` line when the strong
  pick is metered and same-rank alternatives were offered — only the user
  knows which same-rank version their plan prices lower, so the script asks
  rather than guessing (answer it by pinning `--strong-model`).
- **`balanced`** (default) — the asymmetric rule above, unmodified.
- **`thorough`** — the same tier *selection* as `balanced` (thorough doesn't
  change which model wins a tier); what changes is Phase 7's behavior —
  every verifier runs on `strong` regardless of its own tier. Thorough
  spends more by running more things on the strong tier, not by promoting
  the executor tier's resolved model.

Postures are strictly about how much a *given* run is willing to spend, so
they are never written to `~/.kairos/models.yaml` or `.kairos/manifest.yaml`
— persisting a posture would let one migration's risk tolerance leak into
the next one's default, which is exactly the coupling per-run pins are
designed to avoid (see below).

## Why pins are per-run, never persisted

`$RUN/model.txt` — the four pins `strong=` / `coder=` / `executor=` /
`budget=` — is regenerated by re-running the script, never cached and never
copied into `.kairos/manifest.yaml`. Three things change between runs that a
persisted pin would paper over:

- the harness's offered-model list itself (`OFFERED`) can differ run to run,
- the developer's `~/.kairos/models.yaml` answers can be updated between
  runs, and
- the budget posture is explicitly a property of *this* migration's risk,
  not a durable fact about the developer or the component.

Re-resolving from catalog + answers + `OFFERED` every time is what keeps the
three pins honest. If a mismatch ever needs correcting mid-run — the resolved
pick isn't what the user wants — do **not** just re-run the script bare. A bare
re-run re-derives all three tiers from `BUDGET`, silently redrawing the tiers
the user did *not* ask to change (and, because the posture is never persisted,
defaulting a `frugal` run back to `balanced` so `coder=` and `budget=` flip).
The correct procedure — feed `BUDGET` and every *uncorrected* tier back as an
explicit override so only the corrected tier moves, with the one carve-out for
a `coder=` pin the frugal collapse produced — is the **Mid-run correction**
step in `phases/1.5-model-resolution.md`; follow it rather than the bare re-run.
Persist a correction beyond the run by writing `cost_overrides` /
`capability_overrides` into `~/.kairos/models.yaml` before that re-resolution,
and note the correction in `.kairos/migration-log.md`. (`plan_confirmed` is a
separate stamp the orchestrator's own Phase 1.5 step writes and checks — the
resolver never reads it, so stamping it needs no re-run; see below.) Nothing
about a mid-run correction is allowed to outlive `$RUN` except the answer
written to the home-config file. A correction that fails to resolve leaves
**no** pins: the re-resolution removes the previous `model.txt` rather than
leaving the superseded pins in force, so the next dispatch is refused until the
correction actually resolves.

## `~/.kairos/models.yaml` — answers, not resolutions

This file holds **answers** a human confirmed, never a resolved slug and
never a cache. Two of them are read by `resolve-models.sh` itself and
actually change a resolution:

- `cost_overrides` — "this family is actually included/metered, contrary to
  the catalog's default plan."
- `capability_overrides` — "this family is actually cheap/coder/strong/
  premium," including ranking families the catalog doesn't know about yet.

Keys in both maps are **case-insensitive**: a family is matched as a substring
of the *lowercased* offered slug, so `resolve-models.sh` normalizes each
override key to lowercase at read time. Write `gpt-5` or `GPT-5` — either ranks
the same family; a key that could once sit silently inert because its case
never matched any slug no longer can.

A third key lives in the same file but is **not** one the resolver consumes:
`plan_confirmed`, a stamp meaning the IFS-plan assumption has been shown to
this developer once. `resolve-models.sh`'s `CONFIG` parser only recognizes
`cost_overrides:` and `capability_overrides:` sections — any other top-level
key, `plan_confirmed` included, is fed through and skipped without effect on
resolution. Reading and stamping it is the **orchestrator's own** job, done
in `phases/1.5-model-resolution.md`'s Phase 1.5 step (state the assumption
once, on first run, then stamp it) — not a resolver input.

Nothing in this file is a resolved `strong=`/`coder=`/`executor=` value and
nothing here is a cache of a prior resolution — every run re-derives the
three pins from catalog + `cost_overrides`/`capability_overrides` + the
current `OFFERED` list. That's what makes the answers file safe to hand-edit
or share across machines: it can only shift *inputs* to the rule, never
short-circuit it.

## Shortfalls: what degrades, what refuses

Two invariants shape every recovery below, and they are the script's, not
prose: **a pin is never empty**, and **`$RUN/model.txt` exists only after an
exit 0**. Every non-zero exit from a resolution *attempt* removes the file
when it is removable — including a stale one an earlier resolution wrote, so
a failed mid-run re-resolution cannot leave `log-spawn.sh` enforcing pins this
run already rejected. Two exits touch nothing, because neither ever started
resolving: the phase-key refusal, and a `*_MODEL` override-shape refusal (the
override is checked before `BUDGET`, the catalog, or `OFFERED` are read at
all). That second exemption matters for the mid-run correction procedure
(`phases/1.5-model-resolution.md`), which re-feeds a run's own surviving pins
back as overrides — a rejected override there is not this run's failure to
resolve, it is an instruction the caller should not have sent (a display-name
pin can't be an override; the phase file has the carve-out), and the run's
actual pins must survive it untouched. When removal itself fails — a read-only
`$RUN`, say — the exit code is still the *resolution's own* and a `WARNING:`
names every file left behind: **treat surviving pins as stale**, fix the
permissions (or delete the file by hand), and do not dispatch against them.
That the code survives is not free: an unwritable `$RUN` is detected before
the resolution starts and the work is done in a temp file *outside* it, so a
permissions problem cannot masquerade as exit 1's "your invocation is wrong"
and hide the exit 4 / exit 2 the run would really have produced. The one case
a read-only `$RUN` has no resolution failure to report is a resolution that
*succeeds* with nowhere to install: that is exit **1**, naming the directory.
It cannot be exit 0 — `model.txt`'s whole contract is that it holds **this**
run's pins, so claiming success over a superseded file would hand the next
dispatch someone else's. An empty pin would
be worse than no file at all: `log-spawn.sh` reads a missing or empty tier
line as the legacy shape it must record *unchecked*, so every dispatch on
that tier would go unenforced for the whole run. The same reasoning is why the
finished file is shape-checked before it is installed: exactly four keyed,
non-empty lines, each key once. `log-spawn.sh` takes the *first* match per
tier, so a duplicated or valueless line is a pin nobody chose — refused
(exit 5), never installed with a warning.

Three shortfalls, three different answers:

- **A tier's bar is unmet but other families ranked** — the tier degrades to
  the strongest ranked offered model, `WARNING: nothing offered clears the
  <tier> bar — degrading to …`, exit **0**. Resolution stands; the warning is
  the record.
- **Every ranked model is premium** — only the `strong` tier can hit this
  (it is the only tier with a ceiling). The ceiling has nothing left to fall
  back to, so it yields rather than resolving the tier to nothing:
  `WARNING: every ranked offered model is premium — the strong ceiling cannot
  be honored; pinning the strongest offered: …`, exit **0**. The ceiling
  still binds whenever *any* within-ceiling model is ranked — including in
  the degrade above, where a below-bar standard model is preferred over
  promoting `strong` into a premium tier.
- **Nothing ranked at all** — no offered slug matched any catalog family, so
  there is no ordering to derive from. Explicit overrides are read *before*
  this is decided, so three overrides (two under `frugal`, where `coder`
  collapses into `executor`) are a complete resolution and still exit **0**.
  Only the tiers left without an override make it a refusal: exit **4**,
  naming exactly those tiers — and naming them **budget-aware**. Under
  `frugal` with no `--coder-model`, `coder` *is* the `executor` pick, so the
  message names `executor` alone: passing `--coder-model` because a message
  listed it would silently defeat the collapse, and no message here may
  prescribe an override that changes resolution semantics.

### The stderr diagnostics, by prefix

Every line the script writes to stderr is non-blocking — it never changes the
exit code by itself. Beyond the per-tier explanation lines (`<tier>=<slug> [why
this rule fired]`) and the `WARNING:` / `CHOICE:` lines above, three prefixes
report *classification*:

- `UNRANKED: <slug> …` — the offered slug matched no catalog family, so it is
  excluded from auto-selection. One line per offending slug. A confirmed
  `capability_overrides` entry for its family makes it eligible next run.
- `UNCLASSIFIED: family <f> …` — the family is ranked but has no cost class
  (absent from `plan:` and unanswered in `cost_overrides`), so it is treated as
  metered. Emitted once per family. A `cost_overrides` answer silences it.
- `WARNING: nothing ranked …` — *no* offered slug matched any family. This is
  only a warning, not the exit: overrides are read first, so three of them (two
  under `frugal`) still resolve the run at exit 0. It becomes exit **4** only
  when a tier is left with neither a ranking nor an override.

Phase 1.5 owns what to *do* with each (research and propose a `capability_-`
/`cost_overrides` answer for the first two; the judgment fallback for the
third); this list is only what each prefix means.

## Exit codes and their causes

The per-exit recovery — what the orchestrator actually *does* — lives once, in
`phases/1.5-model-resolution.md`'s branch table; this table is the "why" (the
cause each code names), never a second copy of the "what to do".

| Exit | Cause |
| --- | --- |
| 0 | resolved — exactly four pins, none empty, in `$RUN/model.txt` |
| 1 | `OFFERED` empty, `OFFERED` unset on an interactive stdin, bad `BUDGET`, catalog missing or carrying an invalid family rank, missing `PHASE_KEY`, an **`OFFERED` line carrying a control byte — or a run of two-plus interior spaces — inside the slug** (stderr names the byte/run and quotes the line with it spelled out), **a `*_MODEL` override value that is not slug-shaped** (empty/whitespace-only after trimming, or carrying whitespace, `=`, a backslash or a control character), **or a `$RUN` that cannot be written** (the pins resolved; there is nowhere to install them — stderr names the directory). Nothing in `~/.kairos/models.yaml` is ever the cause, and the message always names which one fired |
| 2 | malformed `cost_overrides` / `capability_overrides` value — **this code means the answers file, never the invocation** |
| 4 | nothing ranked **and** at least one tier has no explicit override — the one state that sanctions the judgment fallback (the tiers it names are what resolution consumes; under `frugal` that is never `coder`) |
| 5 | a tier resolved empty although families ranked, or the finished pin file was not exactly four keyed non-empty lines — an invariant violation, not an input error: no `model.txt` is written and it is reported as a bug |

## Override env vars

`STRONG_MODEL` / `CODER_MODEL` / `EXECUTOR_MODEL` are the script's env-var
inputs; they are the direct equivalents of the `--strong-model` /
`--coder-model` / `--executor-model` CLI flags SKILL.md's Argument
extraction maps onto them. An override — from either surface — beats every
derivation for that tier; the script doesn't apply the asymmetric rule or
the budget posture to an overridden tier at all, it just echoes the override
back with a diagnostic saying so.

Because an override is *echoed into* `$RUN/model.txt` rather than merely
classified, its value is shape-checked first, and a bad one is an exit **1**
(the invocation is wrong) rather than anything the answers file can fix.
Surrounding whitespace and a trailing CR are trimmed off — a CRLF paste is a
typo, not a different slug — and what remains must be non-empty and built only
from letters, digits and `.` `_` `-` `:` `/`. That last rule is deliberately
stricter than `OFFERED`: an offered slug may be a display name with *single*
interior spaces and still be derived into a pin, but the same name cannot be
passed as an override — an override is copied into the pin file, so a value
carrying whitespace, `=`, a backslash (`awk -v` expands escapes) or a control
character can write a line nobody chose rather than merely name a model. The
script header records the two dispatch-time failures that bought that rule.

This is also the one exit-1 cause that does **not** wipe an existing
`$RUN/model.txt` (see Shortfalls above): the shape check runs before `BUDGET`,
the catalog, or `OFFERED` are read, so no resolution attempt has started and
there are no stale pins of *this* attempt's to clear — only the run's real,
still-valid ones, most often the mid-run correction procedure's own surviving
pins being echoed back and rejected on the one tier that was a display name.

The one discipline both surfaces share is **control bytes**. An `OFFERED` line
loses a *trailing* CR — a CRLF paste names the same model — but a control byte
*inside* a slug is an exit **1** on either surface, because the slug is copied
into the pin verbatim: `strong=a<CR>b` satisfies the four-line shape check
(awk's `.` matches CR) while `log-spawn.sh` collapses the CR before comparing,
so the pin can never match and every dispatch on that tier fails closed on an
invisible byte. A mid-line CR almost always means the list was pasted with
CR-only line endings and arrived as one line; the script refuses rather than
guessing where the slug ends, and names both the byte and the offending line.

The same collapse is why an `OFFERED` slug carrying a **run of two-plus
interior spaces** (`cursor-grok␠␠4.5`) is also an exit **1**: `log-spawn.sh`
collapses that run to a single space before checking the pin, but the pin was
written verbatim, so the two never match — and the shape gate forbids passing
the value as an override to escape it. A *single* interior space survives on
both sides and is fine (a genuine display name); only a multi-space run is
refused, at resolution time, where the offending line can still be named.

`KAIROS_UPDATE_STRONG_MODEL` / `KAIROS_UPDATE_CODER_MODEL` /
`KAIROS_UPDATE_EXECUTOR_MODEL` are the standing-configuration form of the
same three overrides — set them in a shell profile to pin a machine's tiers
once. Precedence is **flag > env > derivation**: a `KAIROS_UPDATE_*_MODEL`
value fills a tier only when that tier's flag is absent (unset or empty), so
a per-run `--*-model` always wins over a durable default, and a tier with
neither still derives. Nothing about them is persisted anywhere else — they
are read at resolve time and never written to `~/.kairos/models.yaml` or
`.kairos/manifest.yaml`.

## Spawn accounting: why `requested_model` is its own column

`scripts/log-spawn.sh` enforces the tier pins — it refuses a dispatch without
the dispatching phase's `PHASE_KEY`, refuses when `$RUN/model.txt` is absent,
and refuses any dispatch whose `MODEL` is not the pin for the `TIER` it
declares. But it is a **recorder**, not a gate in front of the dispatch: it
fires *after* the subagent has already run, so it **bounds** the damage rather
than preventing it. A hallucinated slug or a skipped model resolution is not
stopped before it runs — it is caught at the first dispatch that used it, which
stops the run there. Re-dispatch on the pin and the row lands then. This is why
SKILL.md's Spawn accounting calls the pins a checked contract enforced *at
record time*, not a pre-dispatch guard.

`scripts/log-spawn.sh` names its model column `requested_model`, not
`model`, because the value it records is what the orchestrator **asked**
the harness to run — not necessarily what the harness actually ran. A
runtime can silently substitute a model (a hallucinated slug that doesn't
exist, an org allowlist rejecting the requested tier, …), and outside of the
one first-dispatch probe row, requested and actual are not guaranteed to
match. Naming the column for what it verifiably is (a request) rather than
what it might imply (a fact) keeps the ledger honest, and is also why the
Phase 8 summary (`scripts/spawn-summary.sh`) labels its counts *requested*
rather than claiming to know what really ran.

### The first-dispatch actual-model probe

The **first dispatch of the run** — whichever fires first, a Phase 5
conflict-resolver or a Phase 7 executor — carries one extra sentence in its
prompt asking the subagent to report the model it believes it is. Record that
reply in `ACTUAL_MODEL`, which `log-spawn.sh` lands in the row's
`actual_model` column (`spawns.tsv` column 7); every other row leaves that
column empty. At Phase 8, `scripts/spawn-summary.sh` reads that column and, when
a probed row's requested and actual slugs differ, emits exactly one
non-blocking line:

```text
MISMATCH: requested=<requested_model> actual=<actual_model> (phase <phase>, item <item>)
```

That is the whole surfacing — a hallucinated slug or an org-allowlist fallback
caught for the cost of one sentence in one prompt. It is advisory: the run is
not failed over it, because `ACTUAL_MODEL` is the probe's honest self-report,
not a pin to enforce.

Only the first dispatch is probed, and that is deliberate: a silent
substitution is a property of the run's environment (a bad pin, an allowlist,
a runtime quirk), so catching it once on the first row that used a model is
where it is cheapest to catch and most likely to be systemic — the remaining
rows carry `requested_model` alone. `ACTUAL_MODEL` is never validated against
the tier pins the way `MODEL` is: the probe must report honestly, so
`log-spawn.sh` records whatever the subagent said and lets the mismatch line,
not a refusal, carry the signal. Both dispatched role files
(`agents/conflict-resolver.md`, `agents/executor.md`) carve the probe an
explicit exception to their otherwise-exclusive return-shape templates, so a
subagent following its template still returns the one line this check reads.
