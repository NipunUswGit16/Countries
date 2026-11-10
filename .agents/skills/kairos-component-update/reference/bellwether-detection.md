# Bellwether detection (bootstrap)

When `.kairos/manifest.yaml` is absent, the component pre-dates this feature. Walk the template's commit history and score each candidate commit by how many bellwether files in the component match the template's version byte-for-byte (after line-ending normalization).

This runs ONCE per component, ever — the result is persisted in `.kairos/manifest.yaml` and the `bootstrapped: true` flag stays for the component's life.

Scoring is in `scripts/bellwether-detect.sh` — run it, don't retype it. It emits `$RUN/bellwether-scores.txt` (`<matches> <total> <sha>`, best first), `$RUN/bellwether-top.txt` (top 5 annotated with commit subjects, ready to present), and prints `N_BELLWETHERS=<count>` (size of the full bellwether set, for context — the gating below uses each candidate's own `total`, which can be smaller when a bellwether doesn't exist at that SHA or in the component).

On a template-arm run, when bellwether signal is too weak or too uniform to locate a baseline, the same script falls back to a **wide scan** over every file shared with the component and emits `$RUN/widescan-scores.txt`, `$RUN/widescan-top.txt`, and `$RUN/bellwether-suggestions.txt` (see [The wide-signal fallback](#the-wide-signal-fallback)). Read `WIDESCAN=` from stdout to know which scores to gate on. The frontend arm has no wide scan and always reports `skipped` — see [Frontend arm](#frontend-arm-mount-vs-module-subtree).

## Contract

| | |
|---|---|
| Env in | `PHASE_KEY` (required — stated in `phases/2-resolve-target.md`; the script refuses to run without it), `CACHE`, `RUN`; optional `TEMPLATE_BRANCH` (default `main`), `COMPONENT_NAME` (default manifest `name:`, else cwd basename), `MODULE` (config.yaml module key — selects tier 1's bellwethers), `MODULE_PATH` (that module's subtree; defaults to the module's config.yaml `path`), `MOUNT` (the component dir the module is mounted at — present switches to the frontend arm, absent is template scoring) |
| Cwd | component root |
| Stdout | `N_BELLWETHERS=<count>`, `WIDESCAN=ran\|skipped`, `N_WIDESCAN_FILES=<count>` |
| Stderr | ranked top candidates, and an explicit warning when the signal is flat |
| Out | `bellwether-scores.txt`, `bellwether-top.txt`, and — when the wide scan runs — `widescan-scores.txt`, `widescan-top.txt`, `bellwether-suggestions.txt`, plus its stamped blob cache `widescan-blobcache.tsv` / `.widescan-blobcache-stamp` (internal; nothing reads it downstream, and deleting it only costs the next run a re-read) |
| Exit | 0 = scored (a weak or flat result is still exit 0 — judge it from the artifacts, not the status); non-zero = a hard stop, each with a `FAIL:` line to relay. On every arm, before any scoring: a missing `PHASE_KEY`, an unset `CACHE`/`RUN`, or a `MOUNT` that is not a directory. The frontend arm adds four more, all guarding against scoring raw, unsubstituted subtrees (see below): `MOUNT` set with no resolvable `MODULE_PATH`; the substitution helper `lib/frontend-substitute.sh` missing; that helper failing to source; or it sourcing without defining `apply_create_substitution`. An eighth, also frontend-only, fires later, per candidate rather than up front: a failed create-time substitution on a candidate subtree |

**`TEMPLATE_BRANCH` must carry the branch the run RESOLVED, not be left to its default.** It selects the history walked, the tip `bellwethers.txt` is read from, and the file set the wide scan compares — so a run targeting a non-`main` branch that omits it detects its baseline from `main`, writes that SHA as the component's founding baseline, and every future migration of that component diffs from a commit this run never targeted. The confidence gating below cannot see the error: the wrong branch answers just as confidently as the right one. Phase 2 resolves that ref as `$BOOT_REF` **from the run-context anchor** — `TARGET_REF` (the invocation's ref, recorded by Phase 2's first block) else `TEMPLATE_LOCAL_BRANCH` else `main` — and hands it to this script and to the manifest writer both. Never derive it from `$TARGET_REFSPEC` or `$TEMPLATE_BRANCH`: those are argument values extracted from the user's message, not shell variables, so a block referencing them is empty at runtime and falls through to `main` — the original defect, wearing the fix's clothes.

## Bellwether file set — three tiers

**Source-defined, with a hardcoded fallback.** Resolution order, first non-empty list wins, every tier read at the tip of the targeted branch:

1. **`.kairos-updates/config.yaml` → `modules.<MODULE>.bellwethers`.** A source repo that self-describes owns its list, per module. Reached only when `MODULE` is set (the manifest's `frontend.template` key); the same entry also supplies the module's subtree `path`, which **outranks** a passed `MODULE_PATH` (a `WARN` names both — `materialize-frontend.sh` resolves it the same way, and the scored subtree must be the subtree the merge will use). Needs `yq` — without it the script says so and falls through instead of guessing.
2. **`.kairos-updates/bellwethers.txt`.** The legacy flat list (one path per line, `#` comments allowed). Neither `kairos-component-template` nor the facade template ships one on any branch, so template runs use tier 3. A repo with no config.yaml lands here, unchanged. **Skipped when `MODULE` names a module the config.yaml declares but which lists no bellwethers**: this list is repo-root-relative while a configured module's paths are subtree-relative, so on the frontend arm its entries would be addressed under `MODULE_PATH`, resolve nowhere, and report "no signal" — silently, because a non-empty list also suppressed tier 3's frontend-shaped warning. That case goes straight to tier 3 with an explicit `WARN` naming the fix (declare the module's bellwethers).
3. **The v1 fallback set:** `renovate.json`, `tools.go`, `bitbucket-pipelines.yml`, `.editorconfig`, `UPGRADE.md` (legacy root path — useful tie-breaker for very old baselines). The facade template carries the first three too, so tier 3 alone cannot tell a facade from a component: the template repo must already be the right kind (pre-flight check 7 refuses the other kind's repo by name).

Nothing in the chain knows a module name: `MODULE` is a key the manifest recorded, so a second template-kind module in the same repo needs no change here. Tier 3 is *component-template-shaped*, so a frontend source that falls through to it matches nothing at all — the script warns and names the fix (declare the module's bellwethers in config.yaml), because otherwise "no signal" reads as a hard-to-detect component rather than as a source repo that never declared anything.

Guidance for authors picking bellwethers: choose files rarely customized and containing no placeholders (matching is byte-for-byte, and pre-substitution on a template run — the frontend arm below is the one place the source side IS substituted). **Never** include `README.md` (always customized) or `AGENTS.md` (sometimes customized). Paths are repo-root-relative on a template run and **module-subtree-relative** in a configured repo — never mount-prefixed. A bellwether renamed in history counts as a no-match for that bellwether (graceful degradation — the scored algorithm absorbs the loss without special-casing renames); on the frontend arm, so does a bellwether whose *filename* carries a placeholder token, since the mount carries the substituted name (the script warns and names it).

## Algorithm

Candidate commits are those that touched at least one bellwether on the targeted branch (capped at the 500 most recent, so scoring stays bounded on long histories). For each, count bellwethers that exist in BOTH the template at that SHA and the component, and how many match byte-for-byte after CRLF normalization. Confidence = `matches / total`; candidates are ranked by that **ratio** (a perfect 3/3 outranks 4/5), ties broken by higher total, then recency. Ratio ties at the top surface to the user.

## Frontend arm (mount vs module subtree)

`MOUNT` present switches what is compared: the component's mount (`web/`) against the module subtree (`MODULE_PATH`), instead of the repo root against the component root. `CACHE` on this arm is the **frontend** mirror (`FRONTEND_CACHE`), never the template one. Each bellwether addresses `<MODULE_PATH>/<path>` on the source side and `<MOUNT>/<path>` on the component side, and candidate commits are those that touched one of those subtree paths. Ranking, gating and artifacts are identical to the template arm — the two arms feed one ranking pipeline, so they cannot rank differently.

**The source side is substituted before comparison, with the CLI's own replacement map** (`scripts/lib/frontend-substitute.sh`, its single owner — the same map materialize uses). The mount is a create-time copy: it already carries the component's own name where the subtree carries `<YOUR_BC_NAME>`. Scoring raw subtrees does not merely lower the scores, it **flattens** them — every substituted file mismatches at *every* candidate commit, so the true create commit ranks no better than any other and a wrong baseline is presented confidently. Substitute the subtree side, then score. The asymmetry is load-bearing and pinned by a test.

**The module is confirmed together with the commit.** With several template-kind modules declared, run this script once per module and let the single confirmation cover module *and* commit; with one module it collapses to the template flow and that module is the default answer. The confirmed key is what `frontend.template` records, and every later run resolves the subtree, the upgrade-file directory and the bellwethers from it.

**No wide scan on this arm.** It would have to materialize and substitute a whole subtree per candidate commit — prohibitive where the template arm hashes each unique blob once. The script prints `WIDESCAN=skipped` and empties the wide-scan artifacts first, so a chained run can never serve the template run's scan as this run's. Weak or flat frontend signal therefore routes through the ordinary regime-2 / regime-3 gating below (present the top candidates, then ask). Declaring the module's bellwethers in config.yaml is what makes this arm cheap and accurate — that is what tier 1 is for.

The frontend-arm **invocation block** — the one that reads `FRONTEND_CACHE`/`FRONTEND_MOUNT`/`FRONTEND_MODULE_PATH` off the anchor, resolves `FE_REF` through the frontend target chain, and passes `CACHE=$FRONTEND_CACHE MOUNT=…` to `bellwether-detect.sh` — lives in `phases/2-resolve-target.md`'s frontend Bootstrap section, its single home. This section is the rationale behind it; run it from there, not by retyping it here.

## The wide-signal fallback

When bellwethers can't locate a baseline, the script scores every file shared between the template tip and the component instead, and takes the peak. **It decides this itself** — you don't choose. Read `WIDESCAN=` from stdout to know which artifacts to gate on:

| `WIDESCAN=` | Gate on |
|---|---|
| `skipped` | `bellwether-scores.txt` / `bellwether-top.txt` |
| `ran` | `widescan-scores.txt` / `widescan-top.txt`, plus `bellwether-suggestions.txt` |

Three things to know when it runs:

- **A high bellwether score alongside `WIDESCAN=ran` is not a contradiction — don't override it.** Candidate commits are only those that *touched* a bellwether, so a template whose bellwethers rarely change can yield one candidate scoring a perfect `total/total`. That is the absence of evidence, not confidence, and the script requires the scan to have actually ruled some commit out before trusting it.
- **A flat wide scan is reported on stderr** (no matches, or a tie for first). Fall through to asking the user; do not present a weak peak as confident.
- **`bellwether-suggestions.txt`** is ready-to-ship `.kairos-updates/bellwethers.txt` content — the shared files that genuinely discriminated between commits. Put it in the Phase 8 Template feedback section; it turns the next component's detection from a guess into a lookup.

Matching is substitution-aware and LF-normalized, and cost scales with unique blobs rather than files × commits (cached across runs). That substitution is an approximation used only for scoring — merged content always comes from `materialize.sh`. Mechanics in the script header.

## Confidence gating

Three regimes based on the top candidate's own `matches / total`. When the wide scan ran, apply the same gating to its scores instead:

1. **Auto-confirm**: `matches ≥ total - 1` AND `total ≥ 3` (fewer than 3 comparable bellwethers makes one match too weak to auto-confirm) AND no ratio tie at the top AND the scan discriminated (≥2 distinct ratios) → one prompt:

   > Detected baseline: `<SHA>` (`<commit subject>`)
   > Confidence: 4/5 bellwethers match
   > Proceed?

   Any clear yes accepts.

2. **Top-3 selection**: confidence below auto-confirm OR a tie at the top → show the top 3 from `bellwether-top.txt` with match counts:

   > Could not auto-detect baseline confidently. Top candidates:
   > 1. `<SHA1>` (`<subject>`) — 3/5 bellwethers
   > 2. `<SHA2>` (`<subject>`) — 3/5 bellwethers
   > 3. `<SHA3>` (`<subject>`) — 2/5 bellwethers
   > Pick one, or specify a different SHA.

   Present wide-scan candidates the same way when `WIDESCAN=ran`, labelled as *shared files* rather than bellwethers (`412/430 files match`), and say which scan produced them — the counts mean different things and the user is choosing between them.

3. **Manual fallback**: the top candidate matched at most one bellwether, or the wide scan also came back flat →

   > Could not detect a baseline. Possible reasons: too much customization, very old template, or this isn't a Kairos component.
   > Manual fix: create `.kairos/manifest.yaml` by hand with `template.sha` set to your best guess, then re-run.

## Output

Once a baseline is chosen, write `.kairos/manifest.yaml` with `scripts/in-progress.sh`, its format owner — there is no YAML here to transcribe. The **manifest-write block** (`ACTION=bootstrap`, resolving `NAME` through `resolve-component-name.sh` and `BOOT_REF` through the target chain) lives in `phases/2-resolve-target.md` — the template bootstrap arm for a template run, the frontend Bootstrap arm for a frontend run. This section is the rationale behind its fields:

- `NAME` — `pkg/schema/globals.go` `const ComponentName`, via `scripts/resolve-component-name.sh`. That constant is the template's well-known identity after create-time substitution. If the script fails (file missing, still a `YOUR_COMPONENT_NAME` placeholder, unparseable), **ask the user and wait**. Do not guess from the git repo name, directory basename, `go.mod` last segment, or Chart.yaml `name:` (`bundle-<name>`) — those often carry a prefix the component does not.
- `REPO` — ask if origin isn't obvious. Default: if pre-flight printed `COMPONENT_KIND=facade` (manifest-less, so `.init.mk` sets `MASTERDATA_INCLUDE_NO_CDC`, or sets `GENERATE_MODULES` without `sql` or `all`), the facade template `git@ssh.bitbucket.org:ifs-pd/kairos-component-facade-template.git` (pre-flight's default when no URL was given); otherwise `git@ssh.bitbucket.org:ifs-pd/kairos-component-template.git`. The script also writes `template.kind` (`facade` or `component`) from the same check.
- `BASE_SHA` — the detected baseline, full 40-character SHA.
- `BRANCH` — the branch the baseline was DETECTED on, i.e. the same `$BOOT_REF` Phase 2 handed this script as `TEMPLATE_BRANCH`. It is **required**: the writer refuses an empty or absent one instead of defaulting to `main`. Rule 4 of Phase 2's target chain reads it back on the next migration, so a wrong value points that run at a history the baseline never came from — and the shape it arrives in is not "omitted" but "interpolated from an empty `$BOOT_REF`", which a default would silently convert into the wrong answer. When `$BOOT_REF` is a bare SHA or tag, record the branch that ref lives on (ask if it isn't obvious).

The script supplies `created_at`, `cli_version` and — critically — `bootstrapped: true`, and refuses to overwrite an existing manifest. Values go through `yq`'s `strenv()`, which types them as strings whatever their spelling — so a branch named `1.0` and an all-digit SHA survive the round trip (quoted only where YAML needs it), while `bootstrapped` stays a real boolean; the script re-checks the written tags and refuses the write if any came out mistyped.

The `bootstrapped: true` flag is load-bearing:

- **Planner** treats clean-merges with suspicion and proposes revert tasks for suspected re-introductions.
- **Executor** verifies each upgrade-file's `before` pattern exists before applying.

Do not omit it.
