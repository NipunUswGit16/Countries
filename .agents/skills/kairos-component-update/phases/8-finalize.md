## Phase 8: Finalize

PHASE_KEY: vk3rq8hd
(Proof-of-load: this phase has two keyed calls — `gate.sh` (accepts any of the three phase-file keys) and `in-progress.sh ACTION=advance` (requires *this* phase's own `vk3rq8hd`, no other). Pass `vk3rq8hd` to both. The mechanism, and why the key stays only in this file, are in `reference/gates.md`.)

**Work steps 1–6 in order — the order is load-bearing.** The spawn cross-check reads `PLAN.md`, so it must run before the commit that removes it; every write of the run must land before the commit that carries it, and that commit must land before the optional squash, or the squash is incomplete.

### 1. Final gate (required — do not advance the baseline without it)

Every task verified itself, but nothing has verified the *final tree* — a stray conflict marker the resolver missed, or two individually-green tasks that interact badly, would ship silently. Run the final gate over the final tree — it sequences build, tests-vs-baseline, the YAML gate, producer idempotence, and the conflict-marker scan over everything git tracks or would track (including the bare-`=======` separator; ignored build output is out of scope by construction), reading the commands and extractor from `$RUN/test-command.txt` (positional contract and card format: `reference/gates.md`; the full interpretation contract: `reference/gate-cards.md`):

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); SYNTH=$(ctx SYNTH)
LABEL=final RUN=$RUN SYNTH=$SYNTH PHASE_KEY=vk3rq8hd "$SKILL_DIR/scripts/gate.sh"
```

The preamble takes `$SYNTH` off the anchor, so a compacted session needs nothing from conversation here; if the tree it names is gone, re-run the run's materializer first (`phases/2.5-materialize.md` dispatches by `RUN_SOURCE` — Phase 5 states the rule, including why the stamped trees make the re-run cheap) rather than letting the gate degrade a semantic layer you could restore for one cheap call.

**Relay the verdict card verbatim** — every row plus the `AGGREGATE` line; do not re-derive verdicts from the raw artifacts (the card carries the evidence and pointers). **For any non-`PASS` row, read `reference/gate-cards.md`'s interpretation contract before acting** — the load-and-act exception that says what each status means. A non-`PASS` aggregate → surface it and stop. Do NOT finalize a migration that fails its own gate; the fix is decided by the user, and it takes one of two sanctioned routes. An **inline amend** stays here — amend the commit, then re-run the gate. A **new task** — a fix task, or any other plan change — is never an in-place edit of the approved plan (patching `PLAN.md` is on SKILL.md's NEVER list): stop cleanly and have the user say `continue`, and Continue mode's plan-revision arm re-enters Phase 6, revises with both gates re-cleared, and resumes at Phase 7 (`reference/continue.md`), which finalizes again through this gate. Relay every `INCOMPLETE` row into the finalize log entry as **incomplete semantic coverage**, naming the layer that did not run and why — never as "clean".

**Read the `census` row like any other.** A disappeared or newly-skipped
top-level test is a real finding — `FAIL`, dispositioned exactly like any other
gate `FAIL` above (inline fix and re-run, or a task for the record) — and so is
total loss: a `final` population censused **empty** where the base epoch had
ids reads `FAIL` (`mass test disappearance`), not `INCOMPLETE`. An
`INCOMPLETE` row here means the census was unavailable, an epoch needed for
the diff was `MISMATCH`, or there was no populated base epoch to diff against —
relay it into the finalize log entry as incomplete semantic coverage, never as
clean, exactly like the rule above (`reference/gates.md` → *The census row*).
A **degraded** diff is not `INCOMPLETE`: when the `postmerge` census was
unusable but a `baseline` one survived, `census-diff.sh` still grades the row
`PASS` or `FAIL` from a `baseline`→`final` comparison and labels its findings
**unattributed** (with one base epoch, template noise and executor guilt are
indistinguishable). Relay such a `FAIL` with that `unattributed` label intact —
never as an executor regression — and disposition it like any other `FAIL`.

**On a frontend run (`RUN_SOURCE=frontend`) the final gate is two layers, in this order: the mount's checks, and then the component-root BUILD.** The mount's checks are the same `gate.sh` at the same label — the cwd *is* the parameter, so nothing about the script changes. The second layer exists because `web/` can break the Go side without a single Go file changing: the component root's build reaches `web/entrypoint` (its embed, its generated assets), and the existing multi-module sweep already covers it. It is the **build only**. The Go **test** suite must never gate the frontend baseline: those tests were baselined against a different cwd and a different source, and letting an unrelated Go test failure block a frontend adoption makes the frontend baseline hostage to work it has nothing to do with:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); SYNTH=$(ctx SYNTH); RUN_SOURCE=$(ctx RUN_SOURCE)
# RUN_SOURCE first, THEN the MOUNT guard: a template run reaching this frontend block
# must die on the accurate "take the template path instead" message, not on a
# misleading "FRONTEND_MOUNT missing" — a template run legitimately has no mount.
[ "$RUN_SOURCE" = frontend ] \
  || { echo "FAIL: this is the frontend section but RUN_SOURCE=$RUN_SOURCE — take the template path instead" >&2; exit 1; }
# Bare read: every FRONTEND_* key is legitimately absent (SKILL.md → Run-context
# anchor) — but not on a frontend run, where an empty mount would gate the wrong tree.
MOUNT=$(sed -n 's/^FRONTEND_MOUNT=//p' "$RUN/context.env")
: "${MOUNT:?FAIL: FRONTEND_MOUNT missing from the run-context anchor — stop; do not advance a frontend baseline on a gate that ran at the component root}"
RUN_ABS=$(cd "$RUN" && pwd -P)       # $RUN is relative; layer 1 runs inside the mount
SYNTH_ABS=$(cd "$SYNTH" && pwd -P)   # so is $SYNTH (materialize records it as $RUN/synthetic) — unabsolutized it resolves under the mount and the gate degrades its $SYNTH-bound rows
# Layer 1 — the mount's checks. $SYNTH is this FRONTEND run's own materialized pair
# (the substituted module BASE/TARGET), not the template's.
( cd "$MOUNT" && LABEL=final RUN="$RUN_ABS" SYNTH="$SYNTH_ABS" PHASE_KEY=vk3rq8hd "$SKILL_DIR/scripts/gate.sh" )
```

**Layer 2 — the component-root build, only after layer 1 passes, and only the build.** It is not re-sequenced here: run it exactly as `phases/4.5-test-baseline.md` → *Frontend run* runs its root-build baseline — same runner (which is what keeps the multi-module sweep reaching `web/entrypoint`), same discovered command, `CHECK=build`, empty extractor, from the component root — with the output stem `build-final-root` instead of `build-baseline-root`. Load that section for the invocation rather than re-deriving it here, and never turn it into a test check: `CHECK=test` at the component root is the Go suite, and the Go suite does not gate the frontend baseline.

Read it against the `.status` artifact Phase 4.5's frontend arm wrote for the same command on the pre-merge tree: a build that was **already** failing then is pre-existing rot to report, not a regression this run caused — and a build that passed then and fails now is a hard stop, the `web/`-broke-the-Go-side case this layer exists to catch. **Both layers must pass before step 5 advances `frontend.sha`.** Layer 1's own INCOMPLETE rows follow Phase 4.5's frontend reading: a layer with nothing to do under the mount (no YAML, no generator, no chart) is relayed as *not applicable*, not as incomplete semantic coverage.

**Beside the gate — the silenced-test scan.** Every gate above compares *failure sets*, so a test the run silenced or bent to pass never shows up as a regression. Run the scan here too, over the whole migration range, and relay its findings alongside the verdict card — a standalone, report-only artifact, never a row inside `gate.sh`:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# PREV_SHA: the anchor first, then the manifest — bare form rather than `ctx`,
# because an anchor without the key is a recoverable case here, not a failure. The
# fallback is `in_progress.previous_sha`, the same source step 5 re-anchors from; the
# block is still on disk at this step (step 5's `clear` deletes it later), so a
# legacy or resumed run whose anchor predates PREV_SHA still gets its whole-migration
# range instead of an avoidable skip.
PREV_SHA=$(sed -n 's/^PREV_SHA=//p' "$RUN/context.env")
# The block's key is source-prefixed and only THIS run's block exists, so read the
# prefix from the live block via the script that owns the manifest — a literal
# `.template.` here would read an absent key on every frontend run and turn a
# recoverable SHA into an avoidable skip.
SRC=$(ACTION=live-source "$SKILL_DIR/scripts/in-progress.sh")   # template|frontend|none
[ -n "$PREV_SHA" ] || PREV_SHA=$(yq -r ".${SRC}.in_progress.previous_sha // \"\"" .kairos/manifest.yaml)
RUN=$RUN PREV_SHA=$PREV_SHA "$SKILL_DIR/scripts/silenced-tests.sh"   # → $RUN/silenced-tests.tsv
```

Relay `$RUN/silenced-tests.tsv` verbatim, one line per finding (`file`, `line`, `construct`) — and let the user disposition **each one** before the baseline advances in step 5: a newly-silenced test is real content, not noise to skim past. **Zero findings is a positive-evidence artifact**, naming the file count the scan covered — the same "ran and found nothing" reading the gate card gives a clean row. **A non-zero exit is a skip that escalates** — but before accepting one, check that `PREV_SHA` really is unavailable: the anchor first, then the manifest's `in_progress.previous_sha`, which the block above already does. The range is this scan's only input, so a skip logged while a recoverable SHA sat in the manifest is an avoidable coverage gap on a legacy or resumed run. **Only when neither source has it** — or the SHA it does have no longer resolves to a commit — is this a real skip, and then it is treated exactly like an absent `$SYNTH` elsewhere in this skill: surface it in the finalize log entry as incomplete semantic coverage, and never let its absence read as "no tests were silenced."

**Beside the gate — the committed-binary backstop.** The Phase 7 tripwire refuses a run-created binary blob into each checkpoint as it is committed, but a legacy or resumed run may carry commits made before that guard existed, or a commit made outside it. Scan the whole migration range for a binary blob that appeared during the run — the safety net for anything the per-commit tripwire never saw — and relay its findings beside the verdict card, a standalone report-only artifact, never a row inside `gate.sh`. It runs **before** step 6's optional squash, since without `--squash-on-finish` (the default) every checkpoint commit is what gets pushed:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# PREV_SHA the same recoverable way the silenced-test scan reads it (anchor, then
# the still-present in_progress block) — the migration base the range starts at.
PREV_SHA=$(sed -n 's/^PREV_SHA=//p' "$RUN/context.env")
SRC=$(ACTION=live-source "$SKILL_DIR/scripts/in-progress.sh")   # template|frontend|none
[ -n "$PREV_SHA" ] || PREV_SHA=$(yq -r ".${SRC}.in_progress.previous_sha // \"\"" .kairos/manifest.yaml)
# STRUCTURAL_SHA as the safe-extra tree: a binary the template added and the
# binary-for-user classifier already surfaced at Phase 3 lives at the structural
# commit, so it is not run-created output and must not be re-flagged here. A bare
# read is fine — an absent key just means no extra exclusions.
STRUCTURAL_SHA=$(sed -n 's/^STRUCTURAL_SHA=//p' "$RUN/context.env")
# The script writes the flagged list to $RUN/committed-binaries.txt itself (it is
# that artifact's format owner). Capture its exit code directly — do NOT pipe it,
# a pipe would report the downstream command's exit and MASK the guard's exit 3,
# the one signal that says "stop".
RUN=$RUN MODE=range BASE=$PREV_SHA SAFE_EXTRA=$STRUCTURAL_SHA ALLOW="$RUN/committed-binaries-ok.txt" \
  "$SKILL_DIR/scripts/guard-binaries.sh"; rc=$?
cat "$RUN/committed-binaries.txt" 2>/dev/null; echo "guard-binaries exit: $rc"
```

**Exit 3 (paths listed) is a hard stop, not a report-and-continue** — a committed binary is already in history and will be pushed. Do not advance the baseline: surface the paths and have the user rewrite the offending commit(s) to drop them (or, for a genuine asset, approve it in `$RUN/committed-binaries-ok.txt`), then re-run the finalize gate. **A clean exit (0) is a positive-evidence artifact** — the range carries no run-created binary. **A non-zero from bad input** (an unresolvable `PREV_SHA`) is the same skip-that-escalates as an absent `$SYNTH`: surface it in the finalize log as incomplete coverage, never as clean.

**Beside the gate — the template-parity scan.** Every gate layer above is *delta-scoped*, so none of them can see a template file the component simply does not *have* — a merge-dropped file that still compiles, or the larger class, **pre-existing drift** that never appears in a `BASE..TARGET` diff at all. The whole-tree parity scan is the only layer that catches those (why it works this way — target-tree basis, presence-only, the guard subtraction — is the script's header). Run it here, over the final tree, and relay its findings beside the verdict card — a standalone, report-only artifact, never a row inside `gate.sh`:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); SYNTH=$(ctx SYNTH)
RUN=$RUN SYNTH=$SYNTH "$SKILL_DIR/scripts/template-parity.sh"   # → $RUN/template-parity.tsv
```

It compares `$SYNTH`'s `kairos-target` — the tree `kairos component create` produces at TARGET, so COMPONENT_NAME and the module path are already substituted and the template-authoring files a real component never carries are already stripped — against the component's **tracked** tree, and reports only template paths **absent** from the component (a present-but-modified file is the merge's job, covered above). Each row is one of three, all derived from the trees with no hardcoded names: **`relocated`** — the exact bytes live at another path (an unfollowed rename whose body the component kept; strong, oid-exact); **`rename?`** — a same-dir, same-extension component-only sibling exists (a rename that also changed the body; a hint to confirm); **`absent`** — no counterpart at all. Deliberate absences the user already dispositioned are subtracted automatically via their `intent.md` absence guard (`reference/intent-guard.md`), so a component that permanently drops a file is asked **once**, then never again.

Relay `$RUN/template-parity.tsv` verbatim and let the user disposition **each row** — the decision itself is step 4's, using the same intent machinery. **Zero findings is a positive-evidence artifact** (the trees agree), the same clean-row reading the gate card gives. **A non-zero exit is a skip that escalates** — an absent `$SYNTH` or a missing `kairos-target` tag — treated exactly like an absent `$SYNTH` elsewhere: re-run the run's materializer (`phases/2.5-materialize.md` dispatches by `RUN_SOURCE` — Phase 5 states the rule) rather than letting the scan silently read as "nothing is missing", and if it still cannot run, surface it in the finalize log as incomplete semantic coverage, never as clean.

**On a frontend run the parity basis is the frontend module's substituted, mount-mapped TARGET subtree, which the block builds by passing explicit `FE_*` values.** The frontend arm's question is "what does the frontend template ship that this component's mount does not have", so its basis is the module's TARGET subtree read from the frontend mirror (`FE_CACHE` at `FE_TARGET`, subtree `FE_MODULE_PATH`), **substituted** with the CLI's create-time replacement map and **mapped** onto the mount — both halves are load-bearing: the raw subtree carries `<YOUR_BC_NAME>` where the mount carries the component's own name, and it is rooted at the module path where the mount is rooted at `web/`, so an unsubstituted or unmapped basis would report nearly every mount file as absent. It reads that subtree from the frontend source rather than from `$SYNTH`'s `kairos-target` — the `--no-frontend`-strips-`web/` reason that rules out `$SYNTH` on the *template* arm does **not** hold here (a frontend run's `$SYNTH` holds the mount content, `phases/2.5-materialize.md`); the scan takes the `FE_*` path so it can derive and name its own basis (module, commit, mount) from the mirror for provenance. `MOUNT` selects the arm and nothing else about the script changes (statuses, guard subtraction, presence-only, tracked-tree-only are shared code):

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); TARGET=$(ctx TARGET)
# Bare reads: every FRONTEND_* key is legitimately absent (SKILL.md → Run-context
# anchor). FRONTEND_CACHE is the run's frontend mirror; when the anchor has no key
# for it, the conventional per-run location is the fallback (a chain, by design —
# like Phase 2's BOOT_REF).
MOUNT=$(sed -n 's/^FRONTEND_MOUNT=//p' "$RUN/context.env")
: "${MOUNT:?FAIL: FRONTEND_MOUNT missing from the run-context anchor — stop; the parity scan cannot map the frontend basis onto an empty mount, and a mount-less run would read as 'nothing is missing'}"
# FRONTEND_MODULE_PATH off the anchor is the subtree materialize RESOLVED and recorded
# (config at the range's ends outranks the manifest), so the parity basis is the subtree
# this run actually merged. Reading the manifest here instead would compare the mount
# against a DIFFERENT module after an upstream relocation and report the delta between
# two subtrees as component drift.
FE_MODULE_PATH=$(sed -n 's/^FRONTEND_MODULE_PATH=//p' "$RUN/context.env")
FE_CACHE=$(sed -n 's/^FRONTEND_CACHE=//p' "$RUN/context.env"); [ -n "$FE_CACHE" ] || FE_CACHE=$RUN/frontend
RUN=$RUN MOUNT="$MOUNT" FE_CACHE="$FE_CACHE" FE_TARGET="$TARGET" FE_MODULE_PATH="$FE_MODULE_PATH" \
  "$SKILL_DIR/scripts/template-parity.sh"   # → $RUN/template-parity.tsv
```

It substitutes that subtree with the same create-time replacement map the merge sides used (`scripts/lib/frontend-substitute.sh`, component name from the manifest) — without it every token-bearing file would read as drifted — and keeps the substituted basis at `$RUN/frontend-parity-target/` so a `restore` disposition can copy a file straight out of it. If the run already materialized that tree, pass it as `FE_TARGET_TREE=<dir>` instead and nothing is re-extracted — but then step 4's frontend restore must copy out of **that** directory, because `$RUN/frontend-parity-target/` is written only when the script extracts the basis itself. The artifact names its basis (module, commit, mount) in the summary line, and every row is reported at its **mount** path. A missing basis is the same skip-that-escalates as an absent `$SYNTH`: exit 2, no artifact, never a silent "nothing is missing".

Two AI-judgment checks the script cannot run — do them yourself before advancing, and treat a failure of either exactly like a gate failure (surface it and stop):

1. **Re-verify every applied upgrade-file** (see `reference/upgrade-files.md` for field semantics). For each upgrade-file marked `apply` in PLAN.md: if it defines `verify-script:`, run it and check exit code; if it defines only `verify:` prose, use it as AI-driven instructions to confirm the change is still present in the final tree; if neither, use best judgment. This turns "the executor believes it applied `20260214T101500-rename-foo-to-bar`" into evidence. The Phase 7 rule applies here too: a **failing** script is cross-checked against the `verify:` prose by judgment before it is believed, and any contradiction goes to Template feedback. An `apply (tombstone)` file re-verifies **nothing** — it changed no tree — so it is exempt from this step.

   **Undeclared supersede — surface and confirm, never auto-flip.** When an applied file's `verify-script:` fails and a *later applied* file's changes plausibly explain the failure (the later file reversed the earlier — an undeclared supersede the author never marked with `supersedes:`), the gate **stays failing**. Present the evidence — which later file, which change, why it reads as a reversal — and let **only the user's confirmation** flip the earlier file's disposition to `skip (superseded — confirmed at final gate)`. Auto-flipping would turn an exit-code gate into a heuristic exactly where a wrong "all green" is most expensive, so never do it. **Flip mechanics** (PLAN.md is frozen at approval, so this is a recorded plan revision, not a silent edit): edit the disposition row in place, append the user's confirmation to `$RUN/qa-ledger.tsv` like every other planning answer (so a resume never re-asks it), and name the flip in the `.kairos/migration-log.md` finalize summary — which keeps check #2's "every disposition row has an outcome" coherent, the flipped row's outcome being the confirmed skip. Raise a **Template-feedback** item telling the author to add `supersedes:` so the next migration retires it mechanically.

   **On a frontend run (`RUN_SOURCE=frontend`) each `before:`/`verify-script:` is module-subtree-relative and must run with cwd at the mount** (`reference/upgrade-files.md` assigns this rule to the executor *and* this re-verification) — the same `( cd "$MOUNT" && … )` form Phase 7's executor uses, behind the same hard guard, because a script run from the component root false-fails as "pattern not found", which is indistinguishable from a change that never landed:

   ```bash
   RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
   RUN_SOURCE=$(ctx RUN_SOURCE)
   if [ "$RUN_SOURCE" = frontend ]; then
     # Bare read (FRONTEND_MOUNT is legitimately absent on a template run), then a
     # hard stop now that it IS a frontend run: an empty mount would run every
     # subtree-relative verify-script: at the component root, where it false-fails.
     MOUNT=$(sed -n 's/^FRONTEND_MOUNT=//p' "$RUN/context.env")
     : "${MOUNT:?FAIL: FRONTEND_MOUNT missing from the run-context anchor — stop; a frontend upgrade-file's verify-script: must not run at the component root}"
     ( cd "$MOUNT" && <the upgrade-file's verify-script:> )   # per apply-marked upgrade-file
   else
     <the upgrade-file's verify-script:>                      # template run: the component root
   fi
   ```

2. Cross-check completeness: every PLAN.md task has a commit (or a documented, user-approved skip), and every row of the Upgrade-file Dispositions table has an outcome.

### 2. Write the finalize summary and Template feedback

Append a finalize summary to `.kairos/migration-log.md` (counts, durations, anything flagged) — **now, before any commit**, so step 5 carries it into history instead of leaving the run's deliverable dirty in the tree. The spawn numbers are folded in by step 3. **Check-first on a resume**: a partial Phase 8 that died before step 5's commit may have already written this summary and its Template feedback (they land here before any commit — `reference/continue.md`'s pre-advance arm resumes Phase 8 from the top), so if a finalize summary for this target is already present, update it in place rather than appending a second copy.

**On a frontend run, fold the pin-compare result into the summary** so the next template-feedback section reads as a table rather than a jsdom mystery. When `$RUN/pin-compare.tsv` is non-empty, summarize the `behind` and `ahead` rows (`package`, `component-spec`, `template-spec`) — the `behind` set is the pins this run bumped (or the user declined), the `ahead` set is the skip-downgrades the run deliberately left alone. An all-`equal` (or `PIN_COMPARE=none`) run needs one line saying the mount pins were already current. This is the operator-visible record that the merge alone could not have produced.

End the entry with a **Template feedback** section. This migration is the only place that data exists; written down, it's exactly what the template author needs to make the next component's migration cheaper. Include:

- which files conflicted most, and which upgrade-file intents needed user Q&A;
- **surviving placeholder tokens** from `$RUN/surviving-tokens.tsv` — tokens the CLI doesn't substitute, i.e. unregistered placeholders the template should either register or stop using;
- **`verify-script:` discrepancies** — every case where a script said "not applied" and judgment found otherwise, with the script's text. These are upstream bugs and will misreport on every component until fixed;
- **suggested `bellwethers.txt`** — if bootstrap ran the wide scan, paste `$RUN/bellwether-suggestions.txt` as ready-to-ship `.kairos-updates/bellwethers.txt` content. This is what turns the next component's baseline detection from a guess into a lookup;
- **whether the template ships a `.gitattributes`** — if `$RUN/normalized-ours.txt` was non-empty, the line-ending drift originated upstream and one `.gitattributes` in the template prevents it for every future component;
- **YAML gate findings**, including a duplicate key that was already present before the migration (report it; do not fix pre-existing defects).

Tell the user it's there and worth sending upstream.

### 3. Fold in the spawn summary (before PLAN.md is removed)

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN "$SKILL_DIR/scripts/spawn-summary.sh"
```

`.kairos/migration/PLAN.md` still exists at this point, which is the whole reason this step precedes step 5: the script derives its expected task count from the plan, and against an absent plan every cross-check below compares to zero and can never fire.

Fold the output into the entry step 2 just wrote: the per-tier spawn tally (every tier listed, including any at zero), the escalation count and the retry count, two conflict-resolver facts (dispatches, and resolution rows logged), and one executor cross-check — plus the run's budget posture read from the `budget=` line of `$RUN/model.txt` (the script does not print it). The summary labels its counts *requested*, not run.

The conflict-resolver numbers are printed side by side and **not** compared: Phase 5 batches ~10 items per dispatch and each dispatch logs one row per resolved region, so dispatches and resolution rows are different units — a 60-item merge reporting `6 dispatches, 90 resolutions logged` is a normal run, not a discrepancy. Read each against its own yardstick: the dispatch count against the batching rule, the resolution count against the merge's size.

The executor line is the one real comparison — `logged N of ~M expected`, where `M` is the `PLAN.md` task count and `N` counts **first attempts only**: retries and escalations are excluded and printed on their own lines above, and needs-input relays are excluded from `N` too but get **no** line of their own — they still land in the per-tier totals, which count every row regardless of outcome; only `N` drops them (a needs-input task logs its relay row and, after the answer, its `ok` first-attempt row, which is the one `N` counts). The units match there, one first-attempt dispatch per planned task, so on a **dispatch run** `N < M` means tasks went undispatched or unlogged: investigate it against step 1's completeness cross-check before folding the numbers in, rather than recording it as a footnote on the numbers.

**On a role-switch run there is no comparison to make.** A role-switch executor runs in-conversation, dispatches nothing, and `log-spawn.sh` refuses a session-model row — so a clean role-switch run logs `N=0` (the summary prints a note saying exactly this), and `N < M` (indeed `N=0`) is the **expected** shape, never a skipped-task signal. Do not route it into the undispatched-task investigation above. Task completeness on a role-switch run is judged by step 1's completeness cross-check **alone** — every `PLAN.md` task has a commit (or a documented, user-approved skip) — not by this count.

### 4. Promote standing intent (user-confirmed, never automatic)

Review the run's `$RUN/qa-ledger.tsv` and propose which rows encode **standing** intent — facts about the component ("`web/` is deliberately absent", "the event handler is unused"), not one-off choices for this migration ("take the template's logo.png"). Ask ONE batched question — a table of `proposed entry | proposed guard | promote?` — and the user confirms per row; nothing is promoted without that confirmation. For each confirmed row, append the entry with `scripts/promote-intent.sh` — the file's format owner. **Never edit `.kairos/intent.md` by hand**: the bullet and its indented `guard:` are one unit, and a guard that lands at column 0 silently de-guards whatever entry sits above it for the component's life.

**The template-parity findings (step 1) are dispositioned here too**, in the same batched question — each row of `$RUN/template-parity.tsv` gets one of three answers, and the answer, not the finding, is what this step records. Present them as a table with a **`suggested`** column you fill from the row's status (the rule is below), so the user **confirms the defaults and overrides only the surprising rows** rather than forming an opinion on every path cold — the disposition cost then scales with the number of *unexpected* rows, not the total, which is what keeps a large first-run backlog from turning into rubber-stamping. When the set is small — a handful — skip the table and offer to walk the rows **one at a time** instead: the round-trips are cheap when there are few, and per-row focus buys more than batching does. The three answers:

- **Restore** — the component should carry this template file. Copy it out of the already-substituted target tree and stage it for step 5's commit (or give it its own `chore: restore <path> from template` commit when the set is large enough to want isolated provenance — and re-run step 1's gate if a restored file is code the build or tests reach):

  ```bash
  RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
  SYNTH=$(ctx SYNTH)
  git -C "$SYNTH" show "kairos-target:<path>" > "<path>" && git add "<path>"
  ```

  On a **frontend** run the same restore comes out of the basis the parity scan kept (`$RUN/frontend-parity-target/`, or the `FE_TARGET_TREE` directory if step 1 passed one) — already substituted, but rooted at the **module subtree** while the rows are reported at their **mount** paths: strip the mount prefix from the row's path to index into the basis, and write to the row's path as given:

  ```bash
  RUN=.kairos/migration/state
  # anchor-exempt: no cross-phase value is consumed — the basis path is fixed by
  # template-parity.sh's own contract and the row supplies the rest.
  cp "$RUN/frontend-parity-target/<path relative to the mount>" "<path from the row>" \
    && git add "<path from the row>"
  ```

- **Keep divergent** — the absence (or the component's own naming, for a `relocated`/`rename?` row) is deliberate. Promote a standing-intent entry with an **absence guard**, exactly as `sql/README.md` is already recorded — this is what makes `template-parity.sh` subtract the path on every future run instead of re-asking:

  ```bash
  RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
  SKILL_DIR=$(ctx SKILL_DIR)
  ENTRY="<path> is deliberately absent — <why>" GUARD="test ! -e <path>" "$SKILL_DIR/scripts/promote-intent.sh"
  ```

- **Defer** — undecided. Record it in the finalize log so it is not silently forgotten, and it re-surfaces next run.

**The `suggested` default follows the row's status**, because the status already carries most of the signal — the point is to spend the user's attention on the rows where the default is *wrong*, not on every row:

- **`relocated`** (oid-exact — the bytes are present under another name) → default **keep divergent**. A component that kept the content verbatim under its own name almost always did so on purpose; the guard asserts the template path's absence.
- **`rename?`** (a same-dir/ext sibling, body diverged) → default **confirm**, no pre-filled answer. The heuristic is deliberately weak, so this is exactly where per-row attention should concentrate.
- **`absent`** (no counterpart) → default **restore** when it is code the build or tests reach, **keep divergent / defer** otherwise. That "does the build reach it" judgment is one the script cannot make but you can — which is why the default lives here, in your reading of the row, not in the `.tsv`.

A `relocated` or `rename?` row is usually one of two things: an unfollowed template rename (restore the template's name, or move the component's file to it) or a naming the component chose on purpose (keep divergent, with the guard asserting the template path's absence). Present the row's `detail` — it names the component-side counterpart — and let the user pick. **The first migration after this scan ships will surface a component's whole backlog of long-standing drift at once**; that is a one-time disposition cost, and every *keep-divergent* answer makes its path silent forever after, so it does not recur.

`promote-intent.sh` creates the file when absent, dates the entry today unless you pass `DATE`, and is idempotent on an identical entry (abort's salvage may already have recorded the same fact). `GUARD` is optional — omit it when nothing in the tree can attest the fact. The script is keyless, like the other writers subagents and reference docs call.

Propose the `guard:` alongside each entry — a tree assertion in the closed grammar (`reference/intent-guard.md`) — whenever the fact has a tree-checkable shape; omit it when nothing in the grammar can attest the fact (guardless entries fall back to the resolver-side contradiction rule). The guards are what turn staleness into a mechanical pre-Phase-5 check on every future run instead of something a resolver must notice. Stage the file (`git add .kairos/intent.md`) so step 5's commit carries it.

**A guard is not shell, and the grammar is closed** — `.kairos/intent.md` is committed, so a guard you write here is evaluated by everyone who clones the component and runs this skill. The accepted forms (`test [!] -e|-f|-d|-s <path>` / `grep -q[F] <pattern> <path>`, either optionally `!`-inverted), the path/pattern constraints, the multiple-guards-are-an-AND rule, and the `GUARD_TIMEOUT` bound are all in `reference/intent-guard.md → The closed guard grammar`. **Propose no guard rather than one outside the grammar** — a future run reports an out-of-grammar guard `UNPARSEABLE` and excludes its entry until someone re-confirms it.

**A kill between this step's `git add` and step 5's commit is recoverable.** The restored files and a staged `.kairos/intent.md` sit in the index with the baseline not yet advanced — a shape `reference/continue.md`'s dirty-tree triage names explicitly (structural commit present, every task committed, `<src>.sha` still `BASE`, staged additions). Its arm unstages the re-derivable restores so pre-flight's clean-tree check passes, then resumes Phase 8 from the top, which re-runs this step and re-stages before step 5 commits — so nothing here is lost to a crash in that window.

### 5. Advance the baseline — the commit that carries the run's last writes

**First**, re-read the in-progress block before removing it — and re-anchor what you read, in this same call:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# if-form, not `&&`: a legitimately empty PREV_SHA (an in-progress block
# recorded before Phase 4's anchor existed) must not exit this whole block 1 —
# that reads as a failed step, not the no-op it is (same if-form-not-`&&`
# rationale as phases/4-migration-branch.md's `.gitignore`-add block).
SRC=$(ACTION=live-source "$SKILL_DIR/scripts/in-progress.sh")   # template|frontend|none
PREV_SHA=$(yq -r ".${SRC}.in_progress.previous_sha // \"\"" .kairos/manifest.yaml)
if [ -n "$PREV_SHA" ]; then
  RUN=$RUN "$SKILL_DIR/scripts/record-context.sh" PREV_SHA=$PREV_SHA
fi
```

The re-anchor is what makes step 6's squash possible at all. `clear` below deletes the block this value lives in, and step 6 runs in a **later tool call** — a fresh shell where `$PREV_SHA` is empty, with `git reset --soft` (no argument) then resetting to `HEAD`: a squash that reports success, changes nothing, and cannot be retried, because the plan removal and the baseline advance have already been committed. The upsert is idempotent against Phase 4's own write of the same SHA, and it is the only way a run recorded before the anchor existed gets a value there.

**Then** advance the baseline with the same script's `advance` action — the run's deliverable is the write the *next* migration reads as BASE, so it goes through a contract that verifies its own read-back, never an improvised `yq` line. **It runs BEFORE the `clear` below, and that order is a recovery contract, not a preference**: the two are separate tool calls, so a crash falls between them. Advance-then-clear leaves the block present with `template.sha` already at the target — a state Continue mode can still enter (it requires the block) and finish, which is why `reference/continue.md` carries an arm for exactly that shape. Clear-then-advance strands the run instead: the block is gone, so continue is unreachable and abort reads "nothing to roll back" despite N migration commits, while `template.sha` still says BASE — and the next fresh run re-migrates BASE→TARGET over a tree already at TARGET.

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); TARGET=$(ctx TARGET)
# if-form, not `[BRANCH="<branch>"]`: the bracketed notation is not bash (rc=127 —
# the advance silently never runs, and `clear` below would finish a run whose
# baseline never moved). Two arms: BRANCH is passed only when a branch was
# explicitly targeted for THIS run's source, never as an empty string.
#
# WHICH branch — PER SOURCE, matching the `$SRC` computed just below: the branch THIS
# RUN explicitly targeted for its own source. On a template run that is what
# `--template-branch` (or a positional refspec that named a branch) named, and the
# script writes it into `template.branch`; on a frontend run it is what
# `--frontend-branch` named, written into `frontend.branch`. NEVER the migration branch
# (the natural misreading: it is the branch you are standing on), and never a SHA or a
# tag, however the target was resolved. The script writes this value into `<$SRC>.branch`
# unvalidated, and that key is what rule 4 of Phase 2's default chain reads for that
# source on every FUTURE migration — so a migration-branch name pins the component to a
# ref that will not exist, and a SHA pins it to a frozen commit that can never advance. A
# run that targeted its source's default `main` targeted no branch explicitly: leave
# BRANCH empty and `<$SRC>.branch` is left exactly as it was.
BRANCH="<the branch this run explicitly targeted for its source — else empty>"
# SOURCE selects WHICH baseline advances. The live block names the run's source and
# `clear` has not run yet, so the manifest still answers it — read through the script
# that owns it, never a guess, and never inherited from an earlier tool call's shell.
SRC=$(ACTION=live-source "$SKILL_DIR/scripts/in-progress.sh")   # template|frontend|none
# Defense in depth, and the one place it is cheap: the manifest and the anchor answer
# "which source is this run" independently, so a DISAGREEMENT means the gates that just
# passed ran for the other source — a frontend baseline about to advance on a root Go
# suite, or the reverse. Both are silent corruption of the value the NEXT migration
# reads as BASE, so this refuses instead of picking one.
#
# Bare read, not `ctx`: the guard must not report a failure for the one case it
# deliberately tolerates — a run recorded before RUN_SOURCE existed on the anchor has
# no key, and absence is not a contradiction. Only a PRESENT value is checked.
RUN_SOURCE=$(sed -n 's/^RUN_SOURCE=//p' "$RUN/context.env")
if [ -n "$RUN_SOURCE" ] && [ "$SRC" != "$RUN_SOURCE" ]; then
  echo "FAIL: the live in-progress block makes this a '$SRC' run but the anchor records RUN_SOURCE=$RUN_SOURCE — do not advance any baseline. One of the two is wrong, which means this run's gates ran against the other source's cwd and suite. Stop, work out which source the commits on this branch belong to, and fix the disagreement before finalizing." >&2
  exit 1
fi
# FRONTEND_CACHE is what the advance's frontend arm needs to auto-clear a recorded
# outstanding_floors element the new baseline now CONTAINS: it ancestry-tests each floor sha
# against TARGET_SHA in that mirror. Absent, the clear cannot run and every floor is LEFT
# (best-effort), so a floor the frontend run just satisfied would persist as false debt the
# next run re-surfaces. Read it off the anchor and pass it; a template run ignores it (its
# advance never touches floors), so passing it unconditionally is safe.
FRONTEND_CACHE=$(sed -n 's/^FRONTEND_CACHE=//p' "$RUN/context.env")
if [ -n "$BRANCH" ]; then
  SOURCE=$SRC ACTION=advance PHASE_KEY=vk3rq8hd TARGET_SHA="$TARGET" BRANCH="$BRANCH" \
    FRONTEND_CACHE="$FRONTEND_CACHE" "$SKILL_DIR/scripts/in-progress.sh"   # prints "advanced"
else
  SOURCE=$SRC ACTION=advance PHASE_KEY=vk3rq8hd TARGET_SHA="$TARGET" \
    FRONTEND_CACHE="$FRONTEND_CACHE" "$SKILL_DIR/scripts/in-progress.sh"   # prints "advanced"
fi
```

The `SRC` / `RUN_SOURCE` disagreement is a **stop, not a warning**: `advance` is the run's one irreversible deliverable (the next migration reads it as BASE), and there is no reading of a mismatch under which advancing is right. It cannot fire on a healthy run — Phase 2 anchors `RUN_SOURCE` and Phase 4 wrote the block for the same source — so if it fires, something wrote one of the two behind the run's back.

`TARGET_SHA` must be the full 40-character SHA (a short one is refused: it looks right in the file and usually still resolves, until a future run compares it to a full SHA). Pass `BRANCH` only when a branch was explicitly targeted this run for its own source (`--template-branch` → `template.branch`, `--frontend-branch` → `frontend.branch`), spelled as above — otherwise `<$SRC>.branch` is left exactly as it was. Everything else in the manifest survives verbatim: `bootstrapped:`, `name:`, `created_at:`, `cli_version:`, comments, key order, and any key this skill does not know about. `<$SRC>.repo` survives too, with one exception the script makes in the same write: a repo recorded on the old Bitbucket SSH host (`git@bitbucket.org:` / `ssh://git@bitbucket.org/`), which no longer serves SSH, is recorded as `ssh.bitbucket.org` — the URL pre-flight already cloned from.

**Only then** remove the in-progress block with the script that owns it — **never by hand**, and **inside the same tool call as the commit below**, never as a block of its own. The clear is the one write that makes Continue mode unreachable (mode detection keys on the block's existence), so the moment between it and the commit must not be a conversation gap a session can die in: fused into one shell invocation, the exposed window shrinks to a process crash — and even that residue converges, because the baseline is already advanced, so once the user commits the dirty manifest the next fresh run exits early at Phase 2 as up-to-date instead of re-migrating.

It deletes the *key*, and verifies its absence before writing. Emptying the mapping instead — the single-token slip a hand-edit invites — leaves `in_progress: {}`, which pre-flight scores as a **live migration** on a run that just succeeded, and every future fresh run of this component is refused. The script is keyless on purpose (`reference/abort.md` calls the same action and holds no phase key), so pass no `PHASE_KEY`.

`clear` and `advance` are two actions of one script, kept apart because **`clear` is also abort's** — and abort must not advance a baseline it is rolling back. That is the reason for the split; it is not that the advance belongs in prose.

**Do not add an upgrade-file ledger to the manifest.** Upgrade-file dispositions belong in `.kairos/migration-log.md` (human-readable) and nowhere else — the applicable set is derived live from the BASE→TARGET git range, so an applied upgrade-file falls out of scope on its own once the baseline advances. A *skipped* one falls out too and is never resurfaced; that's the accepted no-bookkeeping tradeoff, and the reason it was skipped is the log's job to capture.

The plan has served its purpose — remove it in the same commit so it doesn't linger as stale committed state (its content is already summarized in `.kairos/migration-log.md`). This one commit carries **every remaining write of the run**: the manifest edit, the plan removal, the promoted `.kairos/intent.md` if step 4 staged one, and `.kairos/migration-log.md` — which is Phase 8's own summary *and* the final task's Phase 7 entry, the one entry no later `git add -A` picks up (see `phases/7-execution.md`).

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR); TARGET=$(ctx TARGET)
SRC=$(ACTION=live-source "$SKILL_DIR/scripts/in-progress.sh")   # template|frontend|none
SOURCE=$SRC env -u PHASE_KEY ACTION=clear "$SKILL_DIR/scripts/in-progress.sh"   # prints "cleared" or "unchanged"
git rm -q .kairos/migration/PLAN.md
git add .kairos/manifest.yaml .kairos/migration-log.md
git commit -m "chore: advance $SRC baseline to ${TARGET:0:7}"   # $SRC is template|frontend, computed above
```

After this commit the tree is clean. If `git status` still shows migration writes, something above was skipped — fix it and amend rather than leaving the run's deliverable uncommitted.

### 6. Optional squash (`--squash-on-finish`) — last, so it contains everything

**Read the flag from `$RUN/context.env`, not from conversation memory** — Phase 2 anchored it there (`phases/2-resolve-target.md`), and this step can run hours and a compaction (or a fresh session) after the invocation that set it:

```bash
RUN=.kairos/migration/state
SQUASH_ON_FINISH=$(sed -n 's/^SQUASH_ON_FINISH=//p' "$RUN/context.env")
```

(`record-context.sh` upserts, so the key appears on at most one line — no need to take a last-write. Absence is the record of "the flag was not given", so this one is read with the bare form, not `ctx`.)

Absent or empty means the flag was not given: skip this step. Runs only after step 5, which is what makes the single commit whole — and it takes **both** of its values off the anchor, because step 5's shell is gone (works in both branch modes):

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
PREV_SHA=$(ctx PREV_SHA); TARGET=$(ctx TARGET)
# `ctx` only REPORTS a missing key — it exits 0, so the assignment above succeeds
# with an empty value even under set -e, and `git reset --soft` with no argument is
# a SUCCESSFUL reset to HEAD. The guard turns that into a stop: `${VAR:?}` aborts a
# non-interactive shell before the reset runs. It is belt and braces with the prose
# below on purpose — this is the run's one irreversible-looking no-op.
: "${PREV_SHA:?FAIL: PREV_SHA missing from the run-context anchor — stop; do not reset, the squash is not retriable}"
git reset --soft $PREV_SHA
# RUN_SOURCE names the squash subject's source. Step 5 already cleared the in-progress
# block, so the manifest can no longer answer the run's source (the derivation step 5
# used is gone) — the anchor is the only surviving witness, and pre-flight's sweep has
# not run. Bare read with a fallback to `template`, and it is not a wrong-source guess:
# RUN_SOURCE arrived with frontend support, so an anchor carrying no key is a legacy
# pre-frontend run, which is a template run by definition (SKILL.md → Run-context
# anchor sanctions a locally-justified bare read; a present RUN_SOURCE is used verbatim).
RUN_SOURCE=$(sed -n 's/^RUN_SOURCE=//p' "$RUN/context.env"); [ -n "$RUN_SOURCE" ] || RUN_SOURCE=template
git commit -m "chore: migrate to $RUN_SOURCE ${TARGET:0:7}"
```

A `FAIL: PREV_SHA missing` from the preamble means the anchor lost it and step 5's re-anchor did not run: **do not reset** — and the `: "${PREV_SHA:?…}"` line above makes sure the block cannot, whatever you do next. The block is already cleared, so the value is only recoverable from the pre-migration reflog or the user — say so and skip the squash. `git reset --soft` with an empty argument silently resets to `HEAD`, which is exactly the no-op this step must never report as a squash.

Reset to the SHA, never to `previous_branch`: a branch ref may have moved since Phase 4 captured it (under `--no-branch` it moved with every migration commit; even a side branch's base can advance). If `previous_sha` is empty — an in-progress block recorded before Phase 4 captured it — skip the squash and tell the user why, rather than resetting to a ref that may not mark the migration's start.

**A session that dies between step 5's commit and this step leaves the squash reachable only by hand.** The block is already cleared, so Continue mode cannot be entered (mode detection keys on the block's existence), and a fresh run's pre-flight sweeps `$RUN` — taking `PREV_SHA` and `SQUASH_ON_FINISH` with it — then exits early as already up to date. Nothing committed is at risk; the loss is cosmetic (N migration commits instead of one). If the user comes back wanting the squash, run this step by hand **before any fresh run**: both keys survive on the anchor until that sweep. After a sweep, the start SHA lives only in the reflog or the user's memory — offer those, or leave the history unsquashed and say so.

### Close out

**Remove the build/test artifacts this run produced.** The baseline, the Phase 5/7 gates and step 1's final gate all ran tests and builds, any of which may have dropped go binaries, `.test` files, coverage output or `dist/`/`target/` dirs into the work-tree. Remove exactly the ignored paths that appeared since Phase 4.5's snapshot — pre-existing `node_modules/`, `vendor/`, `bin/` and the run state under `.kairos/` are left untouched (`reference/state-files.md` → `pre-test-ignored.txt`; the delta and protected-set rules are in the script header). Runs after step 5's commit, and only touches gitignored paths, so it can neither dirty a tracked file nor un-commit anything:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
RUN=$RUN ACTION=clean "$SKILL_DIR/scripts/clean-artifacts.sh"
```

Relay its summary line. A `SKIP` (no Phase 4.5 snapshot — a legacy or pre-baseline run) is not a failure: it means run-created artifacts can't be told from pre-existing ones, so nothing is removed — say so, and mention the user can clear any stray build output by hand.

Leave `.kairos/migration/state/` in place for post-mortem inspection — it's gitignored, so it never pollutes history. The next fresh migration sweeps it at pre-flight (see `reference/pre-flight.md`).

Tell the user the migration is complete, and that they must merge and/or push themselves — you never push.

## Frontend-run consent — the last thing in the invocation

**Both exits of a template run pass through here.** This one, after Close out — and Phase 2's early exit, "Already up to date at `$TARGET`". That second path is the one that matters most: a no-op template pass is exactly when `web/` is forgotten, and the user is standing right there. The early exit ends the **template run**, not the invocation; it continues here. A **frontend** run does not: there is nothing left to chain, and a second ask would be the re-ask this step exists to prevent — so the code block below **halts a frontend run before any rule runs** (the `RUN_SOURCE=frontend` early-return guard), rather than trusting the rules to fall through silently. It is a mechanical stop, not a prose intention.

Read the run's identity and the frontend facts off the anchor — the intent is a value from the *invocation*, hours and a compaction ago, and it is the difference between asking and not asking:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
RUN_SOURCE=$(ctx RUN_SOURCE)
# Frontend-run guard — the CODE stop the prose above describes, not left to prose.
# This whole section is a TEMPLATE-run epilogue that decides whether to chain a
# frontend run. A frontend run IS that chained run: nothing is left to chain, and a
# second consent ask here is precisely the re-ask this step exists to prevent. So a
# frontend run is a SILENT no-op — stop here, ask nothing, print nothing to the user
# (the >&2 line is orchestrator-only). None of the six rules below run for it.
if [ "$RUN_SOURCE" = frontend ]; then
  echo "frontend run — consent section is a no-op; the invocation is complete" >&2
  return 0 2>/dev/null || exit 0
fi
# Bare reads: every FRONTEND_* key is legitimately absent (SKILL.md → Run-context
# anchor), and here absence IS the answer — but FRONTEND_INTENT is recorded on
# EVERY run (Phase 2 records it unconditionally, "unsaid" being a real value), so
# the no-frontend-source state is "no `frontend:` block and no `web/package.json` — equivalently,
# no FRONTEND_* key on the anchor other than FRONTEND_INTENT", not "no keys at all".
FRONTEND_INTENT=$(sed -n 's/^FRONTEND_INTENT=//p' "$RUN/context.env")
FRONTEND_SHA=$(sed -n 's/^FRONTEND_SHA=//p' "$RUN/context.env")
FRONTEND_MOUNT=$(sed -n 's/^FRONTEND_MOUNT=//p' "$RUN/context.env")
FRONTEND_REPO=$(sed -n 's/^FRONTEND_REPO=//p' "$RUN/context.env")
FRONTEND_BRANCH=$(sed -n 's/^FRONTEND_BRANCH=//p' "$RUN/context.env")
FRONTEND_BOOTSTRAP=$(sed -n 's/^FRONTEND_BOOTSTRAP=//p' "$RUN/context.env")
echo "source=$RUN_SOURCE intent=${FRONTEND_INTENT:-<unrecorded>} sha=${FRONTEND_SHA:-<none>} mount=${FRONTEND_MOUNT:-<none>} bootstrap=${FRONTEND_BOOTSTRAP:-<none>}"
```

**Frontend compatibility floor — did the adopted template change require a newer `web/`?** A template upgrade-file may declare a `requires-frontend: <module>@<sha>` floor: adopting it assumes the component's `web/` already **contains** a given frontend-template commit (an ancestry test, not a version comparison). Phase 3's `build-manifest.sh` wrote every such floor crossed over this run's `BASE..TARGET` into `$RUN/frontend-floors.tsv` — one TAB-separated `upgrade-file<TAB>module<TAB>floor-sha` row per crossed floor. **An empty file is the common case** (no floor in range), and then everything below is inert: the six rules read exactly as they did before this field existed.

`scripts/frontend-floor-check.sh` resolves the component's own `frontend.sha` against every floor whose module matches the component's `frontend.template`, and prints one `FLOOR_STATE=<none|satisfied|unmet|unverified>` line followed by one `UNMET<TAB>file<TAB>module<TAB>sha` detail line per missing floor. It clones the frontend mirror **only when a matching floor exists** (bounded cost, paid only when needed) and **always exits 0** — the floor is advisory, never a gate. Read it off the anchor with the same bare reads the block just above uses:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
# Bare reads: every FRONTEND_* key is legitimately absent on a backend-only component
# (SKILL.md → Run-context anchor). An empty FRONTEND_TEMPLATE means no row can bind, so
# the check returns FLOOR_STATE=none and clones nothing.
FRONTEND_TEMPLATE=$(sed -n 's/^FRONTEND_TEMPLATE=//p' "$RUN/context.env")
FRONTEND_SHA=$(sed -n 's/^FRONTEND_SHA=//p' "$RUN/context.env")
FRONTEND_REPO=$(sed -n 's/^FRONTEND_REPO=//p' "$RUN/context.env")
FRONTEND_CACHE=$(sed -n 's/^FRONTEND_CACHE=//p' "$RUN/context.env")
# Re-surface CROSS-RUN debt. The check reads ONE floors table, and $RUN/frontend-floors.tsv
# holds only the floors THIS run crossed over its own BASE..TARGET. A floor the user declined
# on an earlier run lives in frontend.outstanding_floors, but once this run's BASE advanced
# PAST its upgrade-file it is no longer in range and the check would never see it again — the
# debt silently forgotten. So union the persisted debt (in-progress.sh ACTION=list-floors, the
# reader that prints it as the same file<TAB>module<TAB>sha columns) with this run's table and
# hand the check the UNION, so a still-unmet declined floor re-surfaces. sort -u de-dups a
# floor that is BOTH persisted and back in range. list-floors fails closed on an unreadable
# manifest — surface that rather than silently dropping the debt it guards.
FLOORS_UNION=$(mktemp "${TMPDIR:-/tmp}/frontend-floors-union.XXXXXX")
cat "$RUN/frontend-floors.tsv" 2>/dev/null >> "$FLOORS_UNION" || true
ACTION=list-floors "$SKILL_DIR/scripts/in-progress.sh" >> "$FLOORS_UNION" \
  || echo "FAIL: could not read persisted frontend floors (in-progress.sh list-floors) — cross-run floor debt cannot be re-surfaced; fix the manifest before finalizing" >&2
LC_ALL=C sort -u "$FLOORS_UNION" -o "$FLOORS_UNION"
FLOOR_OUT=$(RUN=$RUN FLOORS_TSV="$FLOORS_UNION" \
  FRONTEND_TEMPLATE="$FRONTEND_TEMPLATE" FRONTEND_SHA="$FRONTEND_SHA" \
  FRONTEND_REPO="$FRONTEND_REPO" FRONTEND_CACHE="$FRONTEND_CACHE" \
  "$SKILL_DIR/scripts/frontend-floor-check.sh")
FLOOR_STATE=$(printf '%s\n' "$FLOOR_OUT" | sed -n 's/^FLOOR_STATE=//p')
# The UNMET detail lines name each missing floor — file, module, sha — and feed the
# record-floor calls the rules below make.
printf '%s\n' "$FLOOR_OUT" | grep '^UNMET	' || true
echo "floor_state=${FLOOR_STATE:-none}"
```

**`FLOOR_STATE` is a modifier on the rules below, not a new rule slot.** It changes only framing, and in a few places breaks today's silence — it NEVER changes which of the six rules fires and NEVER adds a question, so the *four of the six end in no question* count below is unchanged: a warning line is a **statement, not a question**.

- **`none` / `satisfied`** → behave **exactly as today**, with no new line and no new noise. `none` is no matching floor in range — the empty-file common case, or the component's module doesn't match any floor's (a `react@…` floor never binds a non-`react` component, so it is skipped, never a spurious requirement). `satisfied` is `frontend.sha` already contains **every** matching floor.
- **`unmet`** → the adopted template change requires a newer `web/`, and the component is now inconsistent. Rules 2 / 5 / 6 add ONE warning line (rule 2) or reframe their existing ask from *optional* to *required* (rules 5 / 6), and **record the debt** (below) so a later run re-surfaces it.
- **`unverified`** → the mirror was unavailable, `frontend.sha` was empty, or it could not be resolved. Use **advisory** wording everywhere — "required, but I could not verify your current `web/` baseline" — the same shape as rule 3's "I could not check" is never "it is current". It **never suppresses** the frontend consent, and it is recorded like `unmet` (the debt is real; only the verification failed).

**Recording the debt — `in-progress.sh ACTION=record-floor`.** On an `unmet`/`unverified` state **when a `frontend:` block exists** (rules 2 / 5 / 6), append one `frontend.outstanding_floors` element per missing floor, so a later run whose `frontend.sha` comes to contain the floor clears the note automatically (the `advance` action's frontend arm does the clearing). It is idempotent — an element already present (same `upgrade_file`+`module`+`sha`) is not re-appended. **The floor rows come from two sources, keyed on `FLOOR_STATE`, because the check prints `UNMET` detail lines ONLY for `unmet`** — an `unverified` state prints none (the mirror was unavailable or `frontend.sha` could not be resolved; only the *verification* failed, the floors' identity is intact). So driving `record-floor` off the printed `UNMET` lines alone is a silent no-op for `unverified` and the debt is forgotten once BASE advances. Source the rows by state: `unmet` off the printed `UNMET` lines, `unverified` off the **matching rows of `$RUN/frontend-floors.tsv`** — the rows whose column-2 module equals `FRONTEND_TEMPLATE`, the same match the check itself makes — where file/module/sha are all present:

```bash
RUN=.kairos/migration/state; ctx() { sed -n "s/^$1=//p" "$RUN/context.env" | tail -1 | grep . || echo "FAIL: $1 missing from $RUN/context.env" >&2; }
SKILL_DIR=$(ctx SKILL_DIR)
TAB=$(printf '\t')
# FRONTEND_TEMPLATE off the anchor — the module the matching rows carry (the check's own key).
FRONTEND_TEMPLATE=$(sed -n 's/^FRONTEND_TEMPLATE=//p' "$RUN/context.env")
# The floor rows to record, one `file<TAB>module<TAB>sha` per line, sourced by state:
#   unmet      → the UNMET detail lines the check printed ($FLOOR_OUT), leading column stripped
#   unverified → the check printed NONE (only verification failed), but identity is known: take
#                the matching TSV rows straight (column-2 module == ours; mirrors the check's own
#                `awk -F'\t' 'NF>=3 && $2==m'`). Without this the unverified debt is never recorded.
if [ "$FLOOR_STATE" = unmet ]; then
  FLOOR_ROWS=$(printf '%s\n' "$FLOOR_OUT" | sed -n "s/^UNMET$TAB//p")
else   # unverified
  FLOOR_ROWS=$(awk -F'\t' -v m="$FRONTEND_TEMPLATE" 'NF>=3 && $2==m' "$RUN/frontend-floors.tsv")
fi
# One record-floor call per row; the three TAB fields ARE the three args.
printf '%s\n' "$FLOOR_ROWS" | while IFS="$TAB" read -r FLOOR_FILE FLOOR_MODULE FLOOR_SHA; do
  [ -n "$FLOOR_FILE" ] || continue   # skip the blank line an empty FLOOR_ROWS yields
  FLOOR_FILE="$FLOOR_FILE" FLOOR_MODULE="$FLOOR_MODULE" FLOOR_SHA="$FLOOR_SHA" \
    ACTION=record-floor PHASE_KEY=vk3rq8hd "$SKILL_DIR/scripts/in-progress.sh"
done
```

**Rule 1's no-`frontend:`-block arm cannot record** — there is no `frontend:` block to hold an `outstanding_floors` element, so a floor declared in range for a component with no frontend source **only warns**; its trigger is a **non-empty `$RUN/frontend-floors.tsv`**, not `FLOOR_STATE` (which is `none` there, since an absent module binds nothing).

**HARD invariant.** An unmet floor **NEVER aborts the already-merged template run** — the template merge is committed by the time this epilogue runs, so a floor is a post-merge consistency signal, not a gate — and it **NEVER auto-starts the frontend run without consent**, except where consent already exists (intent `both` / `frontend-only`, rule 4, which start regardless). Every `unmet`/`unverified` path either warns-and-records or reframes an ask that was already going to be asked; none starts a run the user did not authorize.

**This is not the upgrade-file ledger.** The "Do not add an upgrade-file ledger to the manifest" rule (step 5) forbids persisting applied/skipped upgrade-file dispositions because those are **recomputable live from the `BASE→TARGET` git range** and fall out of scope on their own once the baseline advances. An `outstanding_frontend_floor` note is a **different class of fact**: it depends on the component's `frontend.sha` — an *independently-controlled* baseline that this template run does not move and **cannot** recompute from its own range — so it must be carried across runs until that separate baseline satisfies it. Recording it is not reintroducing the ledger.

Then apply the rules in this order — **the first that matches decides**, and four of the six end in no question at all. **The order is the rule**, and it encodes one principle: **said before inferred**. Rule 1 is the precondition (no frontend source → nothing any later rule can act on); rules 2 and 4 settle what the user explicitly said; only then do rules 5 and 6 infer from the component's state, since every such inference is a guess about an intent that was not stated. Rule 3 ("already at the target") sits ahead of rule 4 because telling the user their frontend is current is cheaper than a run that would exit at its own Phase 2. Do not float a bootstrap ask ahead of the explicit-intent rules: it would ask a template-only invocation about `web/` (which must stay silent) and re-ask an explicit "both" (which must not be asked at all):

1. **No `web/package.json` and no `frontend:` block** (a `web/` without `package.json` is the template's backend shell, not a frontend) (no `FRONTEND_*` key on the anchor other than `FRONTEND_INTENT`, which every run records) → there is no frontend source to update. Split on what the user said: if the intent did not ask for a frontend update (`unsaid` or `template-only`), stay **silent** — zero new prompts, and no "no frontend source detected" line either: a backend-only component must not pay a single line for machinery it has nothing to do with. But if the user explicitly asked for one (`frontend-only` or `both`), answer their question with **one line — "nothing to update: this component has no frontend source"** — they asked, and silence would read as the ask being dropped, not as there being nothing to do. **Floor modifier:** when `$RUN/frontend-floors.tsv` is non-empty, a crossed template change assumes a frontend this component does not have — surface it with exactly ONE warning line: on the silent arm break the silence with only that line, and on the explicit arm append it to the "nothing to update" line. This arm **cannot record** the debt — there is no `frontend:` block to hold an `outstanding_floors` element — so it only warns; do not block.
2. **Intent `template-only`** → **skip silently.** No ask, no "by the way" — and note this fires *whatever* the component's frontend state is: a legacy component with a `web/` directory and no recorded SHA still gets silence, because "just the template" is an answer to the question this step would otherwise ask. **Floor modifier:** when `FLOOR_STATE` is `unmet`/`unverified`, break the silence with exactly ONE warning line — the template change you adopted requires a newer `web/` and the component is now inconsistent (advisory wording for `unverified`: "required, but I could not verify your current `web/` baseline") — still start **no** run (they said template-only), and record each `UNMET` floor with `ACTION=record-floor` (above) so the next run re-surfaces it. A warning is a statement, not a question: rule 2 still ends in no ask.
3. **`FRONTEND_SHA` already equals the frontend target** → **say it is current; do not ask,** and start no run — **but consult `FLOOR_STATE` first: when it is `unmet`, do NOT declare current.** Resolve the target the way Phase 2's frontend chain resolves it (`--frontend-branch` / positional ref, else the `--frontend-path` checkout's branch, else `frontend.branch`, else `main`) against the frontend source — the run's mirror if this invocation has one, otherwise one `git ls-remote "$FRONTEND_REPO" <that ref>`. If it cannot be resolved at all (offline, no access), **say so and fall through** to the rules below — "I could not check" is never "it is current". Ahead of rule 4 on purpose: a frontend-only invocation whose frontend is already at the target has nothing to run, and telling the user that is cheaper than a run that exits at its own Phase 2. **Floor modifier:** `frontend.sha == target` does **not** prove the floor commit is contained — the target may be the tip of a *forked* `frontend.branch` whose lineage never carried the floor, so `merge-base --is-ancestor` (and thus `FLOOR_STATE`) can read `unmet` even when the SHAs match (the old parenthetical claiming unmet was unreachable here — that sha==target means `satisfied` — was wrong: it holds only on a linear lineage). When `FLOOR_STATE` is `unmet`, an equal SHA is a divergent-lineage false "current" — exactly the false-current §3 forbids — so do **not** say current and do **not** stop: **fall through to the required-framing rules (5/6)** (or rule 4, if an explicit intent starts the run regardless), which reframe the ask as required. Only `unmet` forces the fall-through; for every other `FLOOR_STATE` (`satisfied` — the linear case where sha==target really does contain the floor — as well as `none`) this rule declares current exactly as before.
4. **Intent `frontend-only` or `both`** → **do not re-ask; start the run.** They already said it; re-asking is friction that invites reversing a decision already made. (`frontend-only` skipped the template run entirely, so this is where its one run starts.) With **no recorded SHA**, proceeding *implies* the bootstrap — the consent to update `web/` is the consent to establish its baseline (PRD stories 18 and 25) — and nothing is assumed by that: the frontend run's Phase 2 still scores the mount, shows the top matches, and takes **one** confirmation covering module and commit before it merges anything.
5. **No recorded SHA but `web/package.json` is present** (`FRONTEND_BOOTSTRAP`), and the intent said nothing → **ask**, and a yes *implies* the bootstrap, exactly as in rule 4. Do not bootstrap in order to answer the question — the ask comes first, and a "no" must cost the user nothing. **Floor modifier:** frame that ask as **required**, not optional, whenever `$RUN/frontend-floors.tsv` is **non-empty** — keyed on the raw TSV like rule 1's no-block arm, **not** on `FLOOR_STATE`, because there is no recorded `frontend.sha` here to test ancestry against, so a matching floor can only ever read `unverified` (a `frontend:` block with an empty SHA) while the legacy story-7 case (a `web/` with no `frontend:` block, so an empty `FRONTEND_TEMPLATE` that no floor row can bind) reads `none` — keying required-framing on `unmet` would never fire for *either*, and story 7 is exactly the legacy no-block case. Containment cannot be proven without a recorded module and SHA, so the wording is always **advisory** ("required, but I could not verify your current `web/` baseline"). Record the debt (`ACTION=record-floor`, above, on anything short of a clear yes) **only when a `frontend:` block exists** — the `unverified` arm records off the matching TSV rows; the legacy no-`frontend:`-block path **cannot record** (there is no block to hold an `outstanding_floors` element and `record-floor` fails closed), so it frames-as-required and **warns only, with no record**, re-surfacing next run solely because the floor stays crossed in range. A yes still implies the bootstrap and a no still costs nothing.
6. **Intent `unsaid`** (with a recorded but stale SHA — rule 5 already took the no-SHA case) → **ask, and start only on a CLEAR yes.** "yes" / "do it" / "update web too" is a yes. A question back ("what would that change?"), a "maybe later", a conditional, or silence is **not**: answer what was asked, and if the reply is still not a clear yes, **do not start the run**. Unclear costs one more invocation; a wrongly-started second migration costs the user's branch. **Floor modifier:** when `FLOOR_STATE` is `unmet`, frame that ask as **required** rather than optional (advisory wording for `unverified`: "required, but I could not verify your current `web/` baseline"); the CLEAR-yes bar is unchanged, and on anything short of a clear yes record each `UNMET` floor (`ACTION=record-floor`, above) so it re-surfaces. Consent is still needed to start a fresh run on the branch — the requirement reframes the ask, it never removes it.

**Starting one means starting a FRESH run, not continuing this one.** A run is one source, one `BASE..TARGET`, one plan, one gate cwd, one SHA advanced — so the frontend run reuses **none** of this run's state: not the test baseline, not the synthetic trees, not `PLAN.md`, not the classification or the ledger. It re-enters the phase order at **`phases/2-resolve-target.md` → *Frontend run***, with `RUN_SOURCE=frontend` anchored by that phase's first block, after a fresh-mode Phase 1 (which sweeps the finished run's state) and Phase 1.5's pins; it runs through to its own Phase 8, where step 5 advances `frontend.sha` and nothing else. What it *does* inherit is the **migration branch**: by default the frontend run continues on the branch this run created, so one PR carries both. That does not depend on carrying the name across the sweep — `scripts/suggest-branch.sh` prints a given `MIGRATION_BRANCH` back unchanged **and**, when the anchor no longer has one (which is the normal state after the fresh re-entry's sweep), prints the migration-shaped branch already checked out. A frontend-only run started from an ordinary branch gets its own `topic/<user>/frontend-update-<short-sha>`.

Two facts about that re-entry belong to the frontend source and not the template one: the run needs **no Kairos CLI** (nothing is materialized through `component create`), and standing on the template run's migration branch with **no** live in-progress block is the *chained* case — not the block-less crash window a migration-shaped branch normally means.

**Both of those are one env you pass on the re-entry: `RUN_SOURCE=frontend` on Phase 1's fresh pre-flight call** (`phases/1-preflight.md`; `reference/pre-flight.md` checks 0b and 3). Without it that pre-flight skips nothing and refuses the branch you are standing on, telling the user to delete the branch the template run's commits are on — so pass it, and pass it on the fresh Phase 1 call, not later. A **frontend-only** invocation passes the same env for the same two reasons, whether or not it happens to be standing on an old migration branch. Pre-flight records it on the anchor, and Phase 2's frontend arm re-states it there as the run's identity.

**`RUN_SOURCE=frontend` is not the only thing the re-entry must carry.** The fresh Phase 1 **sweeps** the finished template run's `$RUN` (`context.env`, `model.txt`) by design, so every invocation flag now lives only in this session's memory of the original invocation — re-supply each on the re-entry exactly as the user gave it, or it silently reverts to a default:

- **`--frontend-path <dir>`** — without it the frontend leg resolves its source from the manifest's `frontend.repo` and migrates against **upstream** instead of the author's local checkout — the hazard `reference/continue.md` spells out for a dropped `--template-path` on a resume.
- **`--no-branch`** — a template run started under `--no-branch` left no migration branch and its commits sit on the branch you are standing on; re-supply it so the frontend leg takes Phase 4's `--no-branch` path (create nothing, record no branch) instead of cutting a fresh `topic/<user>/frontend-update-<sha>` — two branches where the user asked for one (`phases/4-migration-branch.md`).
- **`--squash-on-finish`** — read off the anchor at step 6; lost, the frontend leg's squash silently skips.
- **`--budget` and the three model overrides** (`--strong-model` / `--coder-model` / `--executor-model`, or their `KAIROS_UPDATE_*` env) — Phase 1.5 re-resolves models on the re-entry, so a lost `--budget` reverts to `balanced` and lost overrides re-derive, changing verifier tiering for every frontend task.

Each lands where its phase reads it — `--frontend-path` at pre-flight, `--budget` and the model flags at Phase 1.5, `--squash-on-finish` and `--no-branch` where Phase 2/4/8 consume them — so re-supply them the same way the original invocation carried them, not as one env on a single call.

Say which rule fired and what happens next in one line, so the user can see that the machinery decided rather than guessed — except in the silent cases (rule 2, and rule 1's `unsaid`/`template-only` arm), where saying anything is the failure. Rule 1's explicit-ask arm is not silent: its "nothing to update" line is that one line. **A crossed floor is the one thing that speaks in the otherwise-silent cases:** rule 2 and rule 1's silent arm each emit their ONE warning line when a floor applies, and that warning line then IS the line to say — still not a question, so the count is unchanged.
