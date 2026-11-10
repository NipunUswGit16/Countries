#!/usr/bin/env bash
# run-tests.sh — aggregator for kairos-component-update test suites.
# Discovered by `make test-skills` via the */tests/run-tests.sh glob.
#
# Explicit suite list (order is for readable logs only; suites are isolated
# subprocesses except merge-path, which is one process with a shared fixture
# chain). Correctness must not depend on cross-suite ordering.
#
# merge-path-only scripts (no separate *.test.sh — alone-run is
# `bash tests/merge-path.test.sh`):
#   materialize.sh, build-manifest.sh, scope-overlap-check.sh,
#   handoff-classify.sh, structural-merge.sh
#   (plus the empty-map / no-directory-rename guard and the post-merge
#   pre-flight sweep that closes the shared chain)
#   pre-flight.sh runs in that chain too, but its invocation-level checks earn a
#   separate tests/pre-flight.test.sh (listed in SUITES), so it is NOT merge-path-only.
#
# Everything else is 1:1: scripts/<name>.sh → tests/<name>.test.sh
# (plus skill-lint.test.sh for static/packaging checks, and run-tests.test.sh, which
# tests THIS aggregator — a test-only suite with no scripts/ counterpart, like skill-lint).
#
# The list below is checked against tests/*.test.sh — both directions, plus duplicates —
# BEFORE the first suite runs: a suite on disk that nobody listed never runs, and this
# aggregator would then report `passed: n/n` over it. The merge-path grouping comment
# above is part of that contract (skill-lint.test.sh's coverage lint reads it).
#
# Alone-run any suite:  bash tests/<name>.test.sh
# Filter within a suite (where supported):
#   TEST_FILTER=<substring> bash tests/<name>.test.sh
# merge-path and other shared-fixture suites refuse TEST_FILTER.
#
# --affected: run only the suites for files currently changed (staged, unstaged
# or untracked) under the skill dir — the development loop's runner; the full
# roster stays the release/close-out check. --list prints the selection and why
# without running. The mapping mirrors the roster's own contract above:
#   scripts/<name>.sh        -> tests/<name>.test.sh, or merge-path.test.sh for
#                               the five merge-path-only scripts; EITHER WAY also
#                               skill-lint.test.sh (it lints scripts too: twin
#                               helpers, record-write hygiene, comm pinning)
#   any skill *.md           -> skill-lint.test.sh, PLUS the suites that assert on
#                               doc prose (intent-check parses every doc's `guard:`
#                               examples; in-progress + merge-path grep phase/
#                               reference text) — grep-derived, pinned in
#                               run-tests.test.sh
#   scripts/lib/<helper>     -> the suites of the scripts that consume it, grep-
#                               derived (the awk libs -> yaml-gate; frontend-
#                               substitute.sh -> its sourcing scripts' suites, a
#                               merge-path-only consumer -> merge-path.test.sh),
#                               plus skill-lint.test.sh
#   reference/model-families.yaml -> resolve-models.test.sh
#   tests/<name>.test.sh     -> that suite
#   tests/lib.sh, this file, fake-kairos.sh, tests/ubuntu/* -> FULL ROSTER
#                               (harness change invalidates per-suite selection)
#   anything unmapped        -> FULL ROSTER, and the reason is printed
# Suites print quietly by default (failures + `passed: n/m` only); VERBOSE=1
# restores the full ok:/test: stream (passed through to --ubuntu).
#
# Three invariants the aggregate itself enforces, on top of relaying suite exit
# codes — all three cover ways a run can LOOK green while carrying fewer
# assertions than it should (see the loop below for each one's history):
#   * every suite must print a terminal `passed: n/m`; its absence is a failure
#     named against that suite, whatever its exit status was;
#   * the summed totals must balance (TOTAL_PASS == TOTAL_TESTS);
#   * skipped blocks are counted per suite and surfaced in one summary line.

set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)

# --- --ubuntu: re-run this whole aggregator inside a Docker Ubuntu container ---
# The scripts ship to Ubuntu (incl. WSL2); the maintainer box is macOS (BSD
# userland, bash 3.2). This flag runs the suite on the *other* platform — GNU
# coreutils/sed/grep, bash 5, mawk — so a portability regression is caught here
# instead of in a component migration. The container image (tests/ubuntu/) carries
# the real toolchain the scripts invoke (go, mikefarah yq, helm, perl, python3).
#
# Two non-obvious requirements, both load-bearing:
#   * repo root mounted (not just the skill dir): skill-lint reaches the
#     maintainer doc at $SKILL_DIR/../../docs, i.e. the repository root.
#   * non-root user: containers default to root, and root bypasses the chmod 000 /
#     read-only-dir permission tests in gate.test.sh and merge-path.test.sh —
#     they only exercise the failure path as an ordinary user.
UBUNTU=0
AFFECTED=0
LIST_ONLY=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --ubuntu)   UBUNTU=1 ;;
    --affected) AFFECTED=1 ;;
    --list)     AFFECTED=1; LIST_ONLY=1 ;;
    *)          ARGS+=("$a") ;;
  esac
done

if [[ "$UBUNTU" = 1 ]]; then
  command -v docker >/dev/null 2>&1 \
    || { echo "run-tests.sh --ubuntu: docker not found on PATH" >&2; exit 127; }
  SELF="$TESTS_DIR/$(basename "$0")"
  IMAGE="${UBUNTU_IMAGE:-kairos-component-update-tests:ubuntu}"
  # Repo root: skill-lint reaches two levels above the skill dir. Prefer git; fall
  # back to the fixed depth (tests/ -> skill -> skills/ -> repo root).
  REPO_ROOT=$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null \
              || (cd "$TESTS_DIR/../../.." && pwd))
  REL=${SELF#"$REPO_ROOT"/}
  echo "run-tests.sh --ubuntu: building $IMAGE (cached)…" >&2
  docker build -q -t "$IMAGE" "$TESTS_DIR/ubuntu" >&2 || exit 1
  echo "run-tests.sh --ubuntu: running in $IMAGE (non-root, repo mounted read-only)…" >&2
  exec docker run --rm \
    -v "$REPO_ROOT":/repo:ro \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    ${TEST_FILTER:+-e TEST_FILTER="$TEST_FILTER"} \
    ${VERBOSE:+-e VERBOSE="$VERBOSE"} \
    "$IMAGE" \
    bash "/repo/$REL" "${ARGS[@]+"${ARGS[@]}"}"
fi

SUITES=(
  skill-lint.test.sh
  merge-path.test.sh
  pre-flight.test.sh
  yaml-gate.test.sh
  bellwether-detect.test.sh
  collect-common.test.sh
  collect-lib.test.sh
  extract-template-gomod.test.sh
  codev-check.test.sh
  wrong-target-check.test.sh
  ensure-state-ignored.test.sh
  run-check.test.sh
  run-check-modules.test.sh
  coverage-blind.test.sh
  dropped-template-changes.test.sh
  template-parity.test.sh
  materialize-frontend.test.sh
  frontend-floor-check.test.sh
  frontend-pin-compare.test.sh
  census-diff.test.sh
  silenced-tests.test.sh
  clean-artifacts.test.sh
  guard-binaries.test.sh
  handoff-structural.test.sh
  scope-check.test.sh
  next-upgrade-file.test.sh
  producer-idempotence.test.sh
  write-test-commands.test.sh
  apply-ask-user.test.sh
  gate.test.sh
  clone-common.test.sh
  suggest-branch.test.sh
  resolve-component-name.test.sh
  intent-check.test.sh
  promote-intent.test.sh
  log-intent.test.sh
  in-progress.test.sh
  plan-completeness.test.sh
  followup-completeness.test.sh
  supersede-check.test.sh
  supersede-edges.test.sh
  plan-slice.test.sh
  resolve-models.test.sh
  log-spawn.test.sh
  log-learning.test.sh
  log-resolution.test.sh
  spawn-summary.test.sh
  record-context.test.sh
  run-tests.test.sh
)

# --- the list above must match tests/*.test.sh on disk, exactly -----------------
# The roster is hardcoded (it carries a readable order and the merge-path grouping a
# glob cannot express), so a new tests/<name>.test.sh silently never runs — and this
# aggregator then prints `passed: n/n` over a suite nobody executed, which is worse
# than a red run. Checked HERE rather than in skill-lint.test.sh because this file OWNS
# the list: a drift that dropped skill-lint.test.sh itself would take that lint with it.
# Checked BEFORE the first suite because a stale roster invalidates the whole run, and
# saying so costs a second instead of a full sweep.
SL_DISK=$(cd "$TESTS_DIR" && ls -1 -- *.test.sh 2>/dev/null | LC_ALL=C sort)
if [[ -z "$SL_DISK" ]]; then
  echo "run-tests.sh: no *.test.sh found in $TESTS_DIR — the suite scan itself broke" >&2
  exit 2
fi
SL_LISTED=$(printf '%s\n' "${SUITES[@]}" | LC_ALL=C sort)
SL_DUPES=$(printf '%s\n' "$SL_LISTED" | uniq -d)
# The membership compare runs against the DE-DUPLICATED list: a name listed twice is on
# disk, and reporting it as absent there would send the reader looking for the wrong bug.
# Duplication is its own finding, below.
SL_UNIQ=$(printf '%s\n' "$SL_LISTED" | uniq)
# LC_ALL=C on BOTH sides (above and here): comm walks its inputs under ITS collation, and
# a list sorted in the ambient locale against a C-sorted disk scan reports names present
# in both as missing — the same trap skill-lint.test.sh keeps a fixed-once lint over.
SL_MISSING=$(LC_ALL=C comm -23 <(printf '%s\n' "$SL_DISK") <(printf '%s\n' "$SL_UNIQ"))
SL_EXTRA=$(LC_ALL=C comm -13 <(printf '%s\n' "$SL_DISK") <(printf '%s\n' "$SL_UNIQ"))
if [[ -n "$SL_MISSING$SL_EXTRA$SL_DUPES" ]]; then
  echo "===== FAIL: run-tests.sh's SUITES list has drifted from tests/*.test.sh =====" >&2
  [[ -z "$SL_MISSING" ]] || { echo "on disk but NOT in SUITES (it never runs):" >&2
                            printf '  %s\n' $SL_MISSING >&2; }
  [[ -z "$SL_EXTRA" ]]   || { echo "in SUITES but NOT on disk (renamed or deleted):" >&2
                            printf '  %s\n' $SL_EXTRA >&2; }
  [[ -z "$SL_DUPES" ]]   || { echo "listed more than once (its assertions get counted twice):" >&2
                            printf '  %s\n' $SL_DUPES >&2; }
  echo "fix the list (and its merge-path grouping comment above), then re-run" >&2
  exit 2
fi

# --- --affected: select suites for what actually changed -------------------------
# Runs AFTER the roster check on purpose: a stale roster invalidates any selection.
# The mapping lives in the header; an unmapped change falls back to the FULL roster
# loudly, because a wrongly-narrow selection is a green run with a hole in it.
# Selection preserves roster order. Paths from `git status --porcelain` are
# repo-root-relative; the `-- .` pathspec scopes it to the skill dir.
if [[ "$AFFECTED" = 1 ]]; then
  SKILL_ROOT=$(cd "$TESTS_DIR/.." && pwd)
  FULL_REASON=""
  if ! git -C "$SKILL_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    FULL_REASON="not inside a git repo"
  else
    # Strip the two status columns + space; unquote; take a rename's NEW path.
    CHANGED=$(git -C "$SKILL_ROOT" status --porcelain --untracked-files=all -- . \
              | sed 's/^.\{3\}//; s/^"//; s/"$//; s/.* -> //')
    if [[ -z "$CHANGED" ]]; then
      echo "run-tests.sh --affected: nothing changed under $SKILL_ROOT — nothing to run" \
           "(the full roster remains the release/close-out check)"
      exit 0
    fi
    WANT="|"   # |-delimited dedup set (bash-3.2-safe; no associative arrays)
    add() { case "$WANT" in *"|$1|"*) ;; *) WANT="$WANT$1|" ;; esac; }
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      case "$p" in
        */tests/lib.sh|*/tests/run-tests.sh|*/tests/fake-kairos.sh|*/tests/ubuntu/*)
          FULL_REASON="harness file changed: $p"; break ;;
        */tests/*.test.sh)  add "$(basename "$p")" ;;
        */scripts/lib/*)
          # A helper under scripts/lib/ has no suite of its own; its blast radius is
          # every script that names it (a sourced *.sh, or an `awk -f`'d *.awk). Derive
          # those consumers by grep rather than hardcoding one arm per helper — the awk
          # libs resolve to yaml-gate, frontend-substitute.sh to its four sourcing
          # scripts — and map each consumer to its suite (a merge-path-only consumer ->
          # merge-path.test.sh). skill-lint lints the helper's own hygiene.
          add skill-lint.test.sh
          libbase=$(basename "$p")
          for consumer in "$SKILL_ROOT"/scripts/*.sh; do
            grep -qF "$libbase" "$consumer" || continue
            cn=$(basename "$consumer" .sh)
            if [[ -f "$TESTS_DIR/$cn.test.sh" ]]; then add "$cn.test.sh"
            else add merge-path.test.sh   # a merge-path-only script (see header)
            fi
          done ;;
        */scripts/*.sh)
          n=$(basename "$p" .sh)
          if [[ -f "$TESTS_DIR/$n.test.sh" ]]; then add "$n.test.sh"
          else add merge-path.test.sh   # a merge-path-only script (see header)
          fi
          add skill-lint.test.sh ;;    # script lints: twins, record-writes, comm pinning
        */reference/model-families.yaml) add resolve-models.test.sh; add skill-lint.test.sh ;;
        *.md)
          # Doc PROSE is asserted verbatim by more than skill-lint: the guard-grammar
          # lint parses `guard:` examples from EVERY doc (intent-check), and in-progress
          # + merge-path grep phase/reference text directly, so a reword can turn them
          # red. Derived by grepping tests/*.test.sh for a non-phase_key read of a
          # phases/|reference/|agents/|SKILL.md file; re-derive (and update the pin in
          # run-tests.test.sh) when a new suite starts asserting on doc content.
          add skill-lint.test.sh
          add intent-check.test.sh
          add in-progress.test.sh
          add merge-path.test.sh ;;
        *) FULL_REASON="no suite mapping for changed file: $p"; break ;;
      esac
    done <<EOF
$CHANGED
EOF
  fi
  if [[ -n "$FULL_REASON" ]]; then
    echo "run-tests.sh --affected: $FULL_REASON — running the FULL roster" >&2
  else
    SEL=()
    for s in "${SUITES[@]}"; do
      case "$WANT" in *"|$s|"*) SEL+=("$s") ;; esac
    done
    echo "run-tests.sh --affected: ${#SEL[@]} of ${#SUITES[@]} suite(s) for" \
         "$(printf '%s\n' "$CHANGED" | grep -c .) changed file(s):"
    printf '  %s\n' "${SEL[@]+"${SEL[@]}"}"
    SUITES=("${SEL[@]+"${SEL[@]}"}")
  fi
  if [[ "$LIST_ONLY" = 1 ]]; then exit 0; fi
fi

FAILED=0
TOTAL_PASS=0
TOTAL_TESTS=0
SKIPPED=0
SKIP_BY_SUITE=""

for suite in "${SUITES[@]}"; do
  echo "===== suite: $suite ====="
  out=$(mktemp)
  bash "$TESTS_DIR/$suite" >"$out" 2>&1
  rc=$?
  cat "$out"
  # Sum assertion totals from each suite's terminal `passed: n/m` line.
  #
  # Its ABSENCE is a failure of that suite, exit status notwithstanding. Every
  # suite ends in lib.sh's finish_suite, which prints exactly one such line, so no
  # line means the suite died before finishing and every assertion it was carrying
  # silently left the run. Some of those deaths are red anyway (a `set -u` deref of
  # a fixture variable built inside a skip guard aborts with status 1, which this
  # loop already relays) — but the ones that exit 0 were invisible: a whole-suite
  # skip written as a bare `exit 0` at the top, an early return after an
  # environment probe, a `cd` guard that bails politely. Summing "nothing" for
  # those is indistinguishable from a suite that legitimately had nothing to add,
  # which is how a 31-assertion suite can leave a green aggregate 31 short.
  #
  # Tested on the CAPTURED VALUE, not on the pipeline's status: `grep … | tail -1`
  # exits 0 on a no-match (tail is the last command), so `if line=$(…)` is true
  # even when nothing matched — which is how the absence went unnoticed here.
  line=$(grep -E '^passed: [0-9]+/[0-9]+$' "$out" | tail -1)
  if [[ -n "$line" ]]; then
    n=${line#passed: }; n=${n%%/*}; m=${line#*/}
    TOTAL_PASS=$((TOTAL_PASS + n))
    TOTAL_TESTS=$((TOTAL_TESTS + m))
  else
    FAILED=1
    echo "===== FAIL: $suite printed no terminal 'passed: n/m' line (exit $rc) —"
    echo "      it never reached finish_suite, so its assertions are LOST, not zero ====="
  fi
  # Skips shrink a suite's total invisibly: the suite still prints a green
  # `passed: n/n`, just a smaller n, so a helm-less box loses yaml-gate's
  # semantic-render assertions with nothing in the aggregate saying so. There is
  # deliberately NO expected-total registry here (it would need updating on every
  # new assertion and would rot into noise) — the count is surfaced instead, so a
  # reader can tell a full run from a thin one.
  s=$(grep -c '^[[:space:]]*skip: ' "$out" || true)
  if [[ "${s:-0}" -gt 0 ]]; then
    SKIPPED=$((SKIPPED + s))
    SKIP_BY_SUITE="$SKIP_BY_SUITE $suite:$s"
  fi
  rm -f "$out"
  if [[ "$rc" -ne 0 ]]; then
    FAILED=1
    echo "===== FAIL: $suite (exit $rc) ====="
  fi
  echo
done

echo "===== aggregator ====="
echo "passed: $TOTAL_PASS/$TOTAL_TESTS"
if [[ "$SKIPPED" -gt 0 ]]; then
  echo "skipped: $SKIPPED block(s) —$SKIP_BY_SUITE (a missing tool shrinks the total, not the verdict)"
fi
# The totals must balance. A suite reporting `passed: 29/31` also exits non-zero
# today, so this is a second, independent path to the same red: it holds even for a
# suite whose exit status stops mirroring its own count.
if [[ "$TOTAL_PASS" -ne "$TOTAL_TESTS" ]]; then
  FAILED=1
  echo "===== FAIL: aggregate totals do not balance —" \
       "$((TOTAL_TESTS - TOTAL_PASS)) of $TOTAL_TESTS assertion(s) did not pass ====="
fi
if [[ "$FAILED" -ne 0 ]]; then
  exit 1
fi
