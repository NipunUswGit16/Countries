#!/usr/bin/env bash
# run-check-modules.sh — runs ONE discovered build/test command in EVERY Go module
# of the component instead of only the root one, reusing run-check.sh per module.
#
# WHY: `go build ./...` compiles the module it runs in and nothing else. A
# component can carry sibling `go.mod` modules — `pkg/schema`, `web/entrypoint` —
# and a template merge can land a break in one of them that a root-only gate
# never sees. It then surfaces in a manual build after the baseline advanced,
# which is exactly the failure this script exists to prevent.
#
# SCOPE: `go` commands only. A `make` / `npm` / `pytest` / `cargo` command has no
# defined per-module meaning (there is no Makefile in `pkg/schema`), and a Go
# component whose only module is the root has nothing to sweep. Both cases
# delegate verbatim to run-check.sh at the component root and produce artifacts
# byte-identical to calling run-check.sh directly.
#
# Env in:  CMD          command to run in each module (eval'd by run-check.sh)
#          OUT          output path stem — same contract as run-check.sh
#          PHASE_KEY    required ONLY when basename(OUT) is exactly
#                       `test-baseline` — the Phase 4.5 baseline call site;
#                       key stated in phases/4.5-test-baseline.md
#          CHECK        build (default) | test. `test` SKIPS a module carrying no
#                       *_test.go instead of banking its vacuous green
#          EXTRACTOR    optional; passed through to run-check.sh per module
#          CENSUS       optional; passed through to run-check.sh per module. The
#                       per-module population/skip sets are unioned exactly as the
#                       failure sets are — non-root ids prefixed "<module>:", root
#                       ids verbatim (below)
#          EXCERPT_MAX  optional; passed through (default 50)
# Cwd:     the caller's parameter, not a fixed location — the component root on
#          a template run, $FRONTEND_MOUNT on a frontend run; every frontend call
#          site cds there first (reference/gates.md: "the cwd is the parameter,
#          not the script")
# Stdin:   the sweep reads the module list on its own stdin, so every per-module
#          run-check.sh call gets stdin from /dev/null — a recorded command that
#          reads stdin can never eat the list and silently shrink the sweep
# Out:     run-check.sh's artifact set at $OUT, aggregated over modules —
#            $OUT.status        OK | FAIL | EXTRACTOR_MISMATCH | SKIP
#            $OUT.txt.gz        every module's raw log under a module header
#            $OUT.failures.txt  union of the per-module failure sets (EXTRACTOR
#                               only). A non-root module's IDs are prefixed
#                               "<module>:" so a failure names its module; root
#                               IDs stay verbatim, so a single-module component's
#                               failure set is unchanged
#            $OUT.excerpt.txt   module-labeled excerpts, failing modules only
#          plus, ONLY when CENSUS is set —
#            $OUT.population.txt  union of the per-module populations, prefixed the
#                                 same way as the failure set; DELETED on aggregate
#                                 MISMATCH so a partly-censused sweep is never read
#                                 as a smaller population
#            $OUT.skips.txt       union of the per-module skip sets, same prefixing
#            $OUT.census.status   FAILED if any module's census recipe errored;
#                                 else MISMATCH if any module reported it; else OK if
#                                 at least one module produced a census; else ABSENT
#                                 (no module did). A module skipped for having no
#                                 tests, and a module whose census is legitimately
#                                 empty, both contribute nothing but neither forces
#                                 ABSENT/MISMATCH/FAILED
#          plus per module (slug = module dir with '/' -> '_', root = "root") —
#            $OUT.<slug>.*      that module's own run-check.sh artifacts
#            $OUT.modules.tsv   module <TAB> verdict <TAB> detail
# Exit:    0 when every module that ran passed; 1 otherwise
set -u

: "${CMD:?FAIL: CMD not set}"
: "${OUT:?FAIL: OUT not set}"

# Phase-load guard, baseline call site ONLY: Phase 4.5's baseline capture is the
# one place this script is a phase entry point (OUT=$RUN/test-baseline), and its
# key is stated only in phases/4.5-test-baseline.md — a skipped load becomes a
# stop, not a baseline improvised from stub knowledge. Every other OUT —
# including gate.sh's internal build-<label>/test-<label> stems (postmerge,
# midplan, final; never `test-baseline`) — is not a phase entry point and stays
# keyless, so this guard can never break the gate.
if [[ "$(basename "$OUT")" = "test-baseline" ]]; then
  [[ "${PHASE_KEY:-}" = "u7qk3mfp" ]] \
    || { echo "FAIL: load phases/4.5-test-baseline.md first" >&2; exit 1; }
fi

CHECK=${CHECK:-build}
EXCERPT_MAX="${EXCERPT_MAX:-50}"
HERE=$(cd "$(dirname "$0")" && pwd)
RUN_CHECK="$HERE/run-check.sh"
[[ -f "$RUN_CHECK" ]] || { echo "FAIL: cannot find run-check.sh beside $0" >&2; exit 1; }

# run-check.sh is invoked from inside each module directory, so the output stem
# must be absolute or every module would write its artifacts into its own subtree.
case "$OUT" in
  /*) OUT_ABS=$OUT ;;
  *)  OUT_ABS="$(pwd)/$OUT" ;;
esac

MODLIST=$(mktemp "${TMPDIR:-/tmp}/rcm-mods.XXXXXX")
TESTMODS=$(mktemp "${TMPDIR:-/tmp}/rcm-testmods.XXXXXX")
AGG_LOG=$(mktemp "${TMPDIR:-/tmp}/rcm-log.XXXXXX")
AGG_FAIL=$(mktemp "${TMPDIR:-/tmp}/rcm-fail.XXXXXX")
AGG_EXC=$(mktemp "${TMPDIR:-/tmp}/rcm-exc.XXXXXX")
AGG_POP=$(mktemp "${TMPDIR:-/tmp}/rcm-pop.XXXXXX")
AGG_SKIP=$(mktemp "${TMPDIR:-/tmp}/rcm-skip.XXXXXX")
WALK_RAW=$(mktemp "${TMPDIR:-/tmp}/rcm-walkraw.XXXXXX")
WALK_ERR=$(mktemp "${TMPDIR:-/tmp}/rcm-walkerr.XXXXXX")
trap 'rm -f "$MODLIST" "$TESTMODS" "$AGG_LOG" "$AGG_FAIL" "$AGG_EXC" "$AGG_POP" "$AGG_SKIP" "$WALK_RAW" "$WALK_ERR"' EXIT

# A listing that FAILED is not an empty listing — gate.sh check 6's rule
# (scripts/gate.sh, "A listing that FAILED is not an empty listing"), applied here
# too: `find` exiting non-zero (an unreadable subdirectory mid-walk is the concrete
# case) means part of the tree was never walked, so the module — or, for the
# *_test.go walk below, the test-file — set is UNKNOWN, not empty. Piping find
# straight into sed/sort (as this script once did) discarded find's own exit status;
# a partially-walked tree then read as a complete, smaller sweep with a clean OK, or
# (for the *_test.go walk) as every module vacuously SKIPped for "no *_test.go".
# Route both walks through this one fail-closed helper: capture find's status before
# any further processing, keep its stderr for the diagnostic, and on failure write a
# FAIL to $OUT_ABS.status and exit non-zero rather than let the sweep proceed on a
# shrunken list it never noticed was shrunken.
walk_or_fail() { # $1 = human label ("go.mod" | "*_test.go"), $2.. = find args
  local label=$1; shift
  : > "$WALK_RAW"; : > "$WALK_ERR"
  if ! find "$@" > "$WALK_RAW" 2>"$WALK_ERR"; then
    rm -f "$OUT_ABS.modules.tsv" "$OUT_ABS.failures.txt" "$OUT_ABS.excerpt.txt" \
          "$OUT_ABS.population.txt" "$OUT_ABS.skips.txt" "$OUT_ABS.census.status"
    {
      echo "FAIL: $label discovery walk failed — the tree was not fully walked, so"
      echo "the $label set is unknown; the sweep is refused rather than run over a"
      echo "silently shrunken list. find stderr:"
      sed 's/^/  /' "$WALK_ERR"
    } > "$OUT_ABS.excerpt.txt"
    gzip -c < "$OUT_ABS.excerpt.txt" > "$OUT_ABS.txt.gz"
    echo FAIL > "$OUT_ABS.status"
    {
      echo "FAIL: $label discovery walk failed — module set unknown, sweep refused"
      sed 's/^/  /' "$WALK_ERR"
    } >&2
    exit 1
  fi
}

# --- module discovery ---------------------------------------------------------
# vendor/ carries dependency modules, .kairos/ the migration's own scratch trees
# (including the synthetic merge sides — building those would be nonsense),
# node_modules/ the frontend's dependencies, and testdata/ holds fixtures the Go
# tool itself refuses to match with `./...` — sweeping one would fail a gate on
# code `go build ./...` never compiles.
walk_or_fail go.mod . -name go.mod -type f \
     -not -path './.git/*' \
     -not -path './.kairos/*' \
     -not -path '*/vendor/*' \
     -not -path '*/node_modules/*' \
     -not -path '*/testdata/*'
sed 's|/go\.mod$||; s|^\./||' "$WALK_RAW" | sort > "$MODLIST"
N_MODULES=$(grep -c . "$MODLIST" || true)

# The first word of CMD that is not a leading VAR=value assignment must be
# exactly `go`. `make test` may well run go underneath, but `cd pkg/schema &&
# make test` has no Makefile to run — only a literal go command can be re-issued
# in another module directory.
command_is_go() {
  local w first=
  set -f                       # CMD is split on purpose; globs in it are not
  for w in $CMD; do
    case "$w" in
      *=*) continue ;;
      *)   first=$w; break ;;
    esac
  done
  set +f
  [[ "$first" = go ]]
}

sweep_applies() {
  command_is_go || return 1
  [[ "$N_MODULES" -ge 1 ]] || return 1
  # exactly one module and it IS the root: today's single-root run, byte for byte
  if [[ "$N_MODULES" -eq 1 ]] && grep -qx '\.' "$MODLIST"; then
    return 1
  fi
  return 0
}

if ! sweep_applies; then
  rm -f "$OUT_ABS.modules.tsv"     # never leave a stale sweep report beside it
  # CENSUS rides through verbatim: run-check.sh writes the census artifacts at $OUT
  # directly (or clears any stale ones when CENSUS is unset), so the single-run case
  # is byte-identical to calling run-check.sh itself.
  CMD="$CMD" OUT="$OUT_ABS" EXTRACTOR="${EXTRACTOR:-}" CENSUS="${CENSUS:-}" \
    EXCERPT_MAX="$EXCERPT_MAX" "$RUN_CHECK"
  exit $?
fi

# --- which modules carry tests ------------------------------------------------
# A nested module owns its own test files, so credit the LONGEST matching module
# prefix: `go test ./...` at the root does not run pkg/schema's tests, and
# crediting the root with them would run a test-free command there and call the
# vacuous green evidence.
owning_module() {
  local p=$1 owner=. len=0 m
  while IFS= read -r m; do
    [[ "$m" = "." ]] && continue
    case "$p" in
      "$m"/*) if [[ "${#m}" -gt "$len" ]]; then owner=$m; len=${#m}; fi ;;
    esac
  done < "$MODLIST"
  printf '%s\n' "$owner"
}

: > "$TESTMODS"
if [[ "$CHECK" = test ]]; then
  walk_or_fail '*_test.go' . -name '*_test.go' -type f \
       -not -path './.git/*' \
       -not -path './.kairos/*' \
       -not -path '*/vendor/*' \
       -not -path '*/node_modules/*' \
       -not -path '*/testdata/*'
  sed 's|^\./||' "$WALK_RAW" \
    | while IFS= read -r t; do owning_module "$t"; done \
    | sort -u > "$TESTMODS"
fi

# --- the sweep ----------------------------------------------------------------
: > "$OUT_ABS.modules.tsv"
N_OK=0; N_FAIL=0; N_MISMATCH=0; N_SKIP=0
N_CENSUS_OK=0; N_CENSUS_MISMATCH=0; N_CENSUS_FAILED=0

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT_ABS.modules.tsv"; }

while IFS= read -r m; do
  [[ -n "$m" ]] || continue
  slug=$(printf '%s' "$m" | sed 's|^\.$|root|' | tr '/' '_')
  MOUT="$OUT_ABS.$slug"

  if [[ "$CHECK" = test ]] && ! grep -qxF "$m" "$TESTMODS"; then
    record "$m" SKIP "no *_test.go in this module"
    N_SKIP=$((N_SKIP + 1))
    printf '=== module %s — SKIP (no *_test.go) ===\n' "$m" >> "$AGG_LOG"
    continue
  fi

  # `</dev/null` is load-bearing, not tidiness. This loop reads the module list on
  # ITS OWN stdin (`done < "$MODLIST"`), and run-check.sh eval's the recorded
  # command with stdin inherited — so a command whose pipeline reads stdin (xargs,
  # a bare `read`, a prompting binary) ate the remaining module lines. The loop
  # then ended after the first module, every artifact agreed, and the sweep
  # reported OK across "all modules" having checked one. The recorded command gets
  # no stdin at all, the same isolation intent-check.sh applies to its guard exec.
  ( cd "$m" && CMD="$CMD" OUT="$MOUT" EXTRACTOR="${EXTRACTOR:-}" CENSUS="${CENSUS:-}" \
      EXCERPT_MAX="$EXCERPT_MAX" "$RUN_CHECK" ) </dev/null >/dev/null 2>&1
  ST=$(cat "$MOUT.status" 2>/dev/null || true)
  [[ -n "$ST" ]] || ST=FAIL

  printf '=== module %s — %s ===\n' "$m" "$ST" >> "$AGG_LOG"
  gzip -dc "$MOUT.txt.gz" 2>/dev/null >> "$AGG_LOG"

  if [[ -n "${EXTRACTOR:-}" ]] && [[ -f "$MOUT.failures.txt" ]]; then
    if [[ "$m" = "." ]]; then
      cat "$MOUT.failures.txt" >> "$AGG_FAIL"
    else
      awk -v p="$m:" 'NF { print p $0 }' "$MOUT.failures.txt" >> "$AGG_FAIL"
    fi
  fi

  # Census union — same prefixing rule as the failure set, and the same reason: a
  # non-root module's ids must name their module so a disappearance downstream is
  # attributable, while root ids stay verbatim so a single-module component's census
  # is unchanged. A module that reported MISMATCH taints the aggregate (below); its
  # own population/skips were already deleted by run-check.sh, so nothing to union.
  if [[ -n "${CENSUS:-}" ]]; then
    CST=$(cat "$MOUT.census.status" 2>/dev/null || true)
    case "$CST" in
      FAILED)   N_CENSUS_FAILED=$((N_CENSUS_FAILED + 1)) ;;
      MISMATCH) N_CENSUS_MISMATCH=$((N_CENSUS_MISMATCH + 1)) ;;
      OK)
        N_CENSUS_OK=$((N_CENSUS_OK + 1))
        if [[ "$m" = "." ]]; then
          cat "$MOUT.population.txt" 2>/dev/null >> "$AGG_POP"
          cat "$MOUT.skips.txt"      2>/dev/null >> "$AGG_SKIP"
        else
          awk -v p="$m:" 'NF { print p $0 }' "$MOUT.population.txt" 2>/dev/null >> "$AGG_POP"
          awk -v p="$m:" 'NF { print p $0 }' "$MOUT.skips.txt"      2>/dev/null >> "$AGG_SKIP"
        fi
        ;;
    esac
  fi

  case "$ST" in
    OK)
      N_OK=$((N_OK + 1)); record "$m" OK "" ;;
    EXTRACTOR_MISMATCH)
      N_MISMATCH=$((N_MISMATCH + 1))
      record "$m" EXTRACTOR_MISMATCH "extractor matched no failures — see $MOUT.excerpt.txt" ;;
    *)
      N_FAIL=$((N_FAIL + 1))
      record "$m" FAIL "see $MOUT.excerpt.txt" ;;
  esac

  if [[ "$ST" != OK ]] && [[ -s "$MOUT.excerpt.txt" ]]; then
    printf '=== module %s — %s ===\n' "$m" "$ST" >> "$AGG_EXC"
    cat "$MOUT.excerpt.txt" >> "$AGG_EXC"
  fi
done < "$MODLIST"

# --- aggregate artifacts ------------------------------------------------------
gzip -c < "$AGG_LOG" > "$OUT_ABS.txt.gz"

if [[ -n "${EXTRACTOR:-}" ]]; then
  sort -u "$AGG_FAIL" | sed '/^$/d' > "$OUT_ABS.failures.txt"
else
  rm -f "$OUT_ABS.failures.txt"
fi

# --- aggregate census ---------------------------------------------------------
# FAILED if any module's census RECIPE errored (a broken recipe is broken in every
# module, but one is enough): the recipe cannot be trusted anywhere, so the sweep
# reports it loud and DELETES the population rather than union the survivors — exactly
# run-check.sh's per-module posture, promoted to the aggregate so census-diff never
# reads a shrunken population as this run's. Else MISMATCH if any module reported it (a
# partly-censused sweep is a MISMATCH, not a smaller population — so the
# population/skips files are DELETED, exactly as run-check.sh does per module, rather
# than presenting the OK modules' union as THE population); else OK if at least one
# module produced a census — INCLUDING an all-helpers sweep, where every module ran
# green and censused an empty set (that is OK with an empty population, not ABSENT);
# else OK with an EMPTY population when CHECK=test and every module was SKIPped for
# carrying no *_test.go (the total-testless sweep — see the branch below for why this
# is NOT ABSENT); else ABSENT — no module produced one for any other reason.
# With CENSUS unset, not one census byte is written and any stale one is cleared.
if [[ -n "${CENSUS:-}" ]]; then
  if [[ "$N_CENSUS_FAILED" -gt 0 ]]; then
    rm -f "$OUT_ABS.population.txt" "$OUT_ABS.skips.txt"
    echo FAILED > "$OUT_ABS.census.status"
  elif [[ "$N_CENSUS_MISMATCH" -gt 0 ]]; then
    rm -f "$OUT_ABS.population.txt" "$OUT_ABS.skips.txt"
    echo MISMATCH > "$OUT_ABS.census.status"
  elif [[ "$N_CENSUS_OK" -gt 0 ]]; then
    LC_ALL=C sort -u "$AGG_POP"  | sed '/^$/d' > "$OUT_ABS.population.txt"
    LC_ALL=C sort -u "$AGG_SKIP" | sed '/^$/d' > "$OUT_ABS.skips.txt"
    echo OK > "$OUT_ABS.census.status"
  elif [[ "$CHECK" = test ]] && [[ "$N_OK" -eq 0 ]] && [[ "$N_FAIL" -eq 0 ]] && [[ "$N_MISMATCH" -eq 0 ]] && [[ "$N_SKIP" -gt 0 ]]; then
    # Every module SKIPped for no *_test.go, nothing ran, nothing failed: the total-
    # testless sweep — the multi-module spelling of "the suite ran and found no tests",
    # identical to a single-root `go test ./...` over a testless tree (run-check.sh
    # censuses that OK-empty). OK with an EMPTY population so census-diff sees a
    # from-tests-to-none deletion as the mass disappearance it is, not a non-blocking
    # INCOMPLETE. ABSENT below stays for every OTHER no-census reason.
    : > "$OUT_ABS.population.txt"
    : > "$OUT_ABS.skips.txt"
    echo OK > "$OUT_ABS.census.status"
  else
    rm -f "$OUT_ABS.population.txt" "$OUT_ABS.skips.txt"
    echo ABSENT > "$OUT_ABS.census.status"
  fi
else
  rm -f "$OUT_ABS.population.txt" "$OUT_ABS.skips.txt" "$OUT_ABS.census.status"
fi

if [[ -s "$AGG_EXC" ]]; then
  cp "$AGG_EXC" "$OUT_ABS.excerpt.txt"
else
  rm -f "$OUT_ABS.excerpt.txt"
fi

N_RAN=$((N_OK + N_FAIL + N_MISMATCH))
if [[ "$N_MISMATCH" -gt 0 ]]; then
  STATUS=EXTRACTOR_MISMATCH
elif [[ "$N_FAIL" -gt 0 ]]; then
  STATUS=FAIL
elif [[ "$N_RAN" -eq 0 ]]; then
  # A test gate where no module carries tests. Calling that OK would be exactly
  # the vacuous green the gates exist to reject, so say SKIP and say why.
  STATUS=SKIP
else
  STATUS=OK
fi
echo "$STATUS" > "$OUT_ABS.status"

{
  echo "$STATUS: go multi-module $CHECK sweep over $N_MODULES module(s)"
  echo "  passed:               $N_OK"
  echo "  failed:               $N_FAIL"
  echo "  extractor mismatches: $N_MISMATCH"
  echo "  skipped (no tests):   $N_SKIP"
  awk -F'\t' '$2 != "OK" { print "  " $1 ": " $2 ($3 == "" ? "" : " — " $3) }' \
    "$OUT_ABS.modules.tsv"
  [[ "$N_RAN" -eq 0 ]] && echo "  WARN: no module carries *_test.go — this gate produced no evidence"
} >&2

[[ "$N_FAIL" -eq 0 ]] && [[ "$N_MISMATCH" -eq 0 ]]
