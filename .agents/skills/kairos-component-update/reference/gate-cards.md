# Gate cards — the interpretation contract

Every gate is one script — `scripts/gate.sh` at `LABEL=postmerge` | `midplan` |
`final` — and every gate emits one **verdict card**: a TSV, one row per check,
then a final `AGGREGATE` line. This doc is the single home of *what each status
means and what you do with it* — the card-reading contract Phases 5, 7 and 8
relay from. The card's env/exit contract, the check order, and the per-check
mechanics (including the marker scan's silent absence at `postmerge`/`midplan`)
live in `reference/gates.md`; this doc is only how to read the card the gate hands
back.

## Interpretation contract — what each status means and what you do with it

**Relay the card verbatim** — every row plus the `AGGREGATE` line. Do not
re-derive verdicts from the raw artifacts and do not second-guess a row: the
rules that used to be prose ("read the status before the diff", "`FAIL` with an
empty `comm -13` is a pass", "`EXTRACTOR_MISMATCH` is never a pass", "a skip is
incomplete coverage, never clean") are computed by the script now. Statuses:

- **`PASS`** — the check ran and produced positive parsed evidence; the evidence
  column says what (counts, artifact paths) and is never empty on a `PASS` row.
  Red-on-red is a pass: a suite red exactly where the pre-merge baseline was red
  (`status=FAIL`, empty new-failure set) advances nothing broken.
- **`FAIL`** — a real finding. The detail names the failing module / test IDs /
  files (a bare "build failed" is a card bug, not a verdict). Two reason slugs
  deserve note: `extractor:` means the suite exited non-zero and the extractor
  matched nothing — the empty failure set is silence, not a clean gate; fix the
  extractor and re-run rather than proceeding on it. `gate-internal:` means the
  script hit a state it did not anticipate (missing status file, unrecognized
  status string, inconsistent artifacts) and failed closed — inspect the raw
  artifacts; this is the script erring on the safe side, never a pass.
- **`INCOMPLETE`** — the check (or a layer of it) did not run: no tests
  detected, a no-`*_test.go` sweep `SKIP`, a skipped helm render or shape layer,
  an acknowledged `buried-key` demotion, a producer that couldn't run, a listed
  conflict-marker candidate that could not be scanned (the row names it). It never
  flips the aggregate to `FAIL`, but it is never clean either: **relay every
  `INCOMPLETE` row into the migration log as incomplete semantic coverage**,
  naming the layer that did not run and why. Reserve "gate clean" for a card with
  no `INCOMPLETE` rows.

  **The mechanical backstop covers part of that set, not all of it — know which
  part.** `followup-completeness.sh` derives its `skip:` follow-ups (mandatory
  acknowledgments in PLAN.md's `## Follow-up Dispositions`, Phase 6) from exactly
  two artifacts: `producer-idempotence-postmerge.tsv` (read at that label by
  name — the verdict describing the tree the plan is written for), where a `skip`
  verdict becomes `skip:producer-<producer>`, and `yaml-gate-<LABEL>.tsv`
  (`YAML_LABEL`, default `postmerge`), where a `skip` severity becomes one
  `skip:yaml-<kind>` per kind.
  So a skipped helm render, a shape layer with no `$SYNTH`, an acknowledged
  `buried-key` demotion, a skipped producer, and a yaml path that is not a
  regular file (`skip … parse` → `skip:yaml-parse`) are backstopped. Six INCOMPLETE
  rows are **not**, because no artifact they leave behind is on that list: build
  `no build check` (line 3 of `test-command.txt`), tests `no tests detected`
  (line 1) or a sweep `SKIP` (no module carries `*_test.go`),
  producer-idempotence "no producer ran" (an empty `producer-idempotence-<LABEL>.tsv` —
  zero rows is nothing for the trigger to read, not a skip), the `postmerge`
  `ask-user` row degraded by an unverifiable classification binding, a
  conflict-marker candidate that could not be scanned, and the
  **census row** (`census-diff.sh`, mechanics in `reference/gates.md` → *The
  census row*): always `INCOMPLETE` at
  `postmerge` (no `final` epoch yet to diff against), and `INCOMPLETE` at
  `final` whenever the census is unavailable or an epoch it needs reports
  `MISMATCH`. A missing populated base epoch is *not* automatically
  `INCOMPLETE`: a `final` epoch that censused an **empty** population against a
  base epoch that also censused empty is a `PASS` — nothing was ever there to
  lose (`reference/gates.md` → *The census row*, *Empty is not absent*); the row
  only degrades to `INCOMPLETE` when there is no usable base epoch to diff a
  live `final` population against.
  `followup-completeness.sh` reads only `producer-idempotence-postmerge.tsv` and
  `yaml-gate-<LABEL>.tsv` — never a census artifact — so this row has no
  mechanical backstop whatsoever, not even the partial, skip-only coverage the
  producer and yaml rows get. For all six, relaying the row into the migration
  log by hand is the only record the coverage gap ever gets: `phases/5-structural.md`'s
  post-merge relay and `phases/8-finalize.md`'s finalize-log relay are what
  actually do that for the census row — there is no script doing it for you.
- **`NEEDS-INPUT`** — a detect-and-ask finding (inherited local-path `replace`
  directives) the script must never auto-decide. It forces the aggregate ≠
  `PASS` until you ask the user and either fix and re-run (the row turns `PASS`)
  or record the user's keep decision in the migration log and proceed with the
  aggregate as-is.

**Aggregate**: `FAIL` if any row is `FAIL`; else `NEEDS-INPUT` if any row is
`NEEDS-INPUT`; else `PASS` (`INCOMPLETE` rows notwithstanding — they are logged,
not blocking).

**A card whose every evidence row is `INCOMPLETE` still exits 0 — that is a
conscious contract, not a bug.** The gate proves what it ran, and the card is
what the orchestrator must read; `INCOMPLETE` never flips the aggregate by
design, so an all-`INCOMPLETE` card is a `PASS` that carries no positive
evidence at all. Reading it as "clean" is exactly the misreading the
relay-every-`INCOMPLETE`-row rule above exists to prevent: the `PASS` means the
aggregate was not blocked, never that any check confirmed anything.
