#!/usr/bin/env bash
# run-check.sh — runs ONE test/build command once and writes its raw combined
# output gzip-compressed, never plain text. Records the command's status itself,
# cross-checks extractor output against the exit code, and on failure writes a
# bounded plain-text excerpt for cheap triage.
#
# Env in:  CMD        command to run (eval'd; typically a test or build command)
#          OUT        output path stem — writes "$OUT.txt.gz", "$OUT.status", and
#                      on failure "$OUT.excerpt.txt"; if EXTRACTOR is set, also
#                      "$OUT.failures.txt"; if CENSUS is set, also
#                      "$OUT.population.txt", "$OUT.skips.txt", "$OUT.census.status".
#          EXTRACTOR  optional; a command (eval'd) that the same raw output is
#                      piped through, then sorted+deduped into "$OUT.failures.txt".
#          CENSUS     optional; a command (eval'd, exactly like EXTRACTOR, over the
#                      SAME captured raw output) that emits "id <TAB> pass|fail|skip"
#                      per verdict-bearing or skipped test. Split by the runner into
#                      "$OUT.population.txt" (pass+fail ids) and "$OUT.skips.txt"
#                      (skip ids), both TOP-LEVEL only (no '/' in the id — a subtest
#                      name is data). One validity cross-check: the failure set must
#                      be a subset of the population, or the census is internally
#                      inconsistent (→ MISMATCH). See the census block below.
#          EXCERPT_MAX  max lines in "$OUT.excerpt.txt" (default 50)
# Cwd:     inherited — run from the component root, like the command it wraps.
#           CMD runs in a subshell, so its own `cd` (or `exit`) cannot reach the
#           wrapper: every artifact below is written whatever the command does.
# Out:     $OUT.txt.gz, or — only if the compress itself failed — $OUT.txt plain
#          with a diagnostic on stderr instead (evidence kept, never lost, on a
#          disk-full/interrupted gzip), $OUT.status (OK | FAIL | EXTRACTOR_MISMATCH),
#          $OUT.failures.txt (only if EXTRACTOR set), $OUT.excerpt.txt (non-zero exit),
#          and — only if CENSUS set — $OUT.population.txt, $OUT.skips.txt,
#          $OUT.census.status (OK | MISMATCH | FAILED). With CENSUS UNSET not one census byte
#          is written and any stale one is cleared: the rider is invisible, every
#          other artifact byte-identical to a pre-census run.
# Exit:    CMD's own exit code — never gzip's, EXTRACTOR's or CENSUS's
set -u

: "${CMD:?FAIL: CMD not set}"
: "${OUT:?FAIL: OUT not set}"

EXCERPT_MAX="${EXCERPT_MAX:-50}"
# OUT is a path stem the caller may point at a not-yet-created subdirectory
# (e.g. a fresh $RUN/checks/<task-id>/); every artifact below is "$OUT.*", so
# create the parent once, up front, rather than let the first write fail.
mkdir -p "$(dirname "$OUT")"
TMP=$(mktemp "${TMPDIR:-/tmp}/run-check.XXXXXX")
EXTRACTED=$(mktemp "${TMPDIR:-/tmp}/run-check-extracted.XXXXXX")
trap 'rm -f "$TMP" "$EXTRACTED"' EXIT

# The SUBSHELL is load-bearing, not decoration. A recorded command may carry a
# top-level `exit N` (a discovered `make` one-liner, a shell snippet pasted into
# test-command.txt); eval'd in THIS shell, that exit terminated run-check.sh right
# here — the code still propagated, but not one artifact below was ever written:
# no .status, no .txt.gz, no excerpt, and producer-idempotence.sh read its skip
# reason out of a log that did not exist. Run in a subshell, the same exit ends the
# COMMAND and hands its code back as rc. A `cd` inside CMD is likewise contained,
# so a relative OUT keeps resolving against the caller's cwd.
( eval "$CMD" ) > "$TMP" 2>&1
rc=$?

# Checked, not because gzip commonly fails, but because unchecked it fails
# INVISIBLY: a disk-full or interrupted compress leaves a truncated/absent
# $OUT.txt.gz sitting beside a perfectly valid $OUT.status, and every downstream
# reader (producer-idempotence.sh's `gzip -dc ... || true`) treats decompress
# failure as "no output captured" rather than "the evidence never got written" —
# indistinguishable from a genuinely silent command. rc stays CMD's own per this
# script's exit contract regardless, so on failure the raw log is kept plain
# (as $OUT.txt) rather than lost, with a loud diagnostic pointing at it.
# gzip un-negated so $? is gzip's OWN status: inside `if ! gzip; then`, $? in the
# branch is the negation's result (always 0 — the branch only runs when `! gzip`
# succeeded), so the diagnostic reported "exit 0" on a real failure, reading as
# success in the one message whose whole job is to diagnose the failure.
gzip -c < "$TMP" > "$OUT.txt.gz"
gz_rc=$?
if [[ "$gz_rc" -ne 0 ]]; then
  rm -f "$OUT.txt.gz"
  cp "$TMP" "$OUT.txt" 2>/dev/null || true
  echo "FAIL: gzip -c failed (exit $gz_rc) compressing the captured output — $OUT.txt.gz would otherwise be truncated or absent beside a status that still reads OK/FAIL normally. Raw log kept plain at $OUT.txt instead." >&2
fi

# The extractor runs exactly ONCE, into $EXTRACTED; the failure set and the
# excerpt below are both views of that single pass. Eval'ing it twice (as this
# script once did) lets a non-deterministic or expensive extractor disagree
# with itself between the two artifacts.
if [[ -n "${EXTRACTOR:-}" ]]; then
  cat "$TMP" | eval "$EXTRACTOR" > "$EXTRACTED"
  sort -u "$EXTRACTED" | sed '/^$/d' > "$OUT.failures.txt"
else
  rm -f "$OUT.failures.txt"
fi

if [[ "$rc" -eq 0 ]]; then
  echo OK > "$OUT.status"
elif [[ -n "${EXTRACTOR:-}" ]] && [[ ! -s "$OUT.failures.txt" ]]; then
  echo EXTRACTOR_MISMATCH > "$OUT.status"
  echo "FAIL: command exited $rc but EXTRACTOR matched no failures (EXTRACTOR_MISMATCH) — check EXTRACTOR or decompress $OUT.txt.gz" >&2
else
  echo FAIL > "$OUT.status"
fi

if [[ "$rc" -ne 0 ]]; then
  # The excerpt reuses the SAME extractor pass captured above — never a second
  # eval. An extractor that matched nothing falls back to the raw tail.
  if [[ -n "${EXTRACTOR:-}" ]] && grep -q . "$EXTRACTED" 2>/dev/null; then
    head -n "$EXCERPT_MAX" "$EXTRACTED" > "$OUT.excerpt.txt"
  else
    tail -n "$EXCERPT_MAX" "$TMP" > "$OUT.excerpt.txt"
  fi
else
  rm -f "$OUT.excerpt.txt"
fi

# --- census (optional) ---------------------------------------------------------
# A rider on the runner, not a fork of it: with CENSUS set, the SAME captured raw
# output ($TMP) is piped through it ONCE — the mechanics mirror EXTRACTOR exactly —
# to emit "id <TAB> pass|fail|skip" per verdict-bearing or skipped test. The runner
# splits that into a population (pass+fail) and a skip set, both filtered to
# TOP-LEVEL ids (an id containing '/' is a subtest, whose name is data; top-level
# only is the RUNNER's filter, so a recipe that forgets it still yields the right
# population). Then one validity cross-check: the failure set must be a subset of
# the population. Failing it means the two artifacts describe different runs, so the
# population and skips files are DELETED — never left half-true, because every
# downstream reader is a `comm` against another epoch and a half-true population
# reads as "these tests disappeared". Absence forces every reader through the
# INCOMPLETE path; census.status records MISMATCH so the reason is not lost.
# CENSUS's own exit code never reaches $rc — the runner's exit is still CMD's.
#
# But it MUST reach census.status. A recipe that fails outright (jq/awk absent, a
# wrong flag shape — all model-authored and realistic) exits non-zero and emits no
# rows, so an un-captured status wrote OK over an EMPTY population — indistinguishable
# from a suite that legitimately censused nothing. Since a broken-from-the-start recipe
# is broken at EVERY epoch, census-diff's empty↔empty arm then certifies PASS: the one
# layer built to catch MISSING GREEN reports clean on a component whose census never
# ran. So the recipe's own exit status is captured (`|| true` used to discard it) and
# an error exit is a distinct, loud census.status FAILED with the population
# discarded — census-diff treats FAILED as unusable/unran (INCOMPLETE, never PASS),
# exactly as it treats MISMATCH.
#
# Last-stage-only was not enough: census_rc must reflect the WHOLE pipeline. A realistic
# multi-stage recipe whose broken/wrong-flag tool is NOT last (`grep -P … | awk …` where
# grep -P exits 2 on BSD but awk exits 0; `missing_tool | cat`) exited 0 on its last
# stage and wrote OK over an empty population — the exact fail-open FAILED exists to
# catch, one stage deeper. pipefail (inherited into the eval subshell) makes any non-zero
# stage — the outer `cat`, the recipe, or a stage INSIDE the recipe's own pipeline — the
# pipe's status; it is scoped to this one pipe (restored right after) so the extractor and
# the awk splits keep last-stage semantics.
#
# But pipefail alone over-fires: the dominant census idiom is `grep … | awk …`, and grep
# exits 1 when it legitimately matched NOTHING (a helpers-only module that censused no
# tests — an OK, empty population per the PRD, judged elsewhere). Exit 1 is grep's
# no-match and is INDISTINGUISHABLE from a benign empty census, so it must stay benign;
# every breakage the census layer exists to catch exits >= 2 (a missing/absent tool 127,
# a wrong flag shape `grep -P`/`jq`/`awk` fatal 2). So FAILED fires on census_rc >= 2,
# not merely non-zero: exit 1 falls through to the normal empty-population path.
if [[ -n "${CENSUS:-}" ]]; then
  CENSUS_RAW=$(mktemp "${TMPDIR:-/tmp}/run-check-census.XXXXXX")
  CENSUS_FAIL=$(mktemp "${TMPDIR:-/tmp}/run-check-census-f.XXXXXX")
  # shellcheck disable=SC2002
  set -o pipefail
  cat "$TMP" | eval "$CENSUS" > "$CENSUS_RAW" 2>/dev/null
  census_rc=$?
  set +o pipefail
  if [[ "$census_rc" -ge 2 ]]; then
    rm -f "$OUT.population.txt" "$OUT.skips.txt"
    echo FAILED > "$OUT.census.status"
    echo "FAIL: CENSUS recipe exited $census_rc — it ran but broke (missing tool, wrong flag). census.status=FAILED with no population, rather than OK over an empty one that would read as a legitimately test-free suite. Check the recipe or decompress $OUT.txt.gz." >&2
  else
  awk -F'\t' 'NF>=2 && index($1,"/")==0 && ($2=="pass"||$2=="fail"){print $1}' "$CENSUS_RAW" \
    | LC_ALL=C sort -u | sed '/^$/d' > "$OUT.population.txt"
  awk -F'\t' 'NF>=2 && index($1,"/")==0 && $2=="skip"{print $1}' "$CENSUS_RAW" \
    | LC_ALL=C sort -u | sed '/^$/d' > "$OUT.skips.txt"
  # The subset check is only decidable when a failure set exists: an EXTRACTOR that
  # produced failing ids, at least one of them. failures ⊄ population → MISMATCH.
  #
  # It must compare in the population's ID SPACE, which is TOP-LEVEL only. A JSON
  # failure extractor emits a failing SUBTEST (TestFoo/case1) ALONGSIDE its failing
  # parent, so an un-projected failure set carries subtest ids the top-level-only
  # population can never contain — and a single failing subtest in a legitimate
  # red-on-red baseline would then MISMATCH the whole census (deleting it, reporting
  # INCOMPLETE) exactly where there is red for a disappearance to hide behind. So the
  # failure set is projected to top-level (drop '/') before the comparison: the real
  # invariant is that every TOP-LEVEL failing test — which is verdict-bearing and so
  # must be in the population — is accounted for; a subtest is not independently
  # tracked and its parent is what the check validates.
  CENSUS_STATUS=OK
  if [[ -n "${EXTRACTOR:-}" ]] && [[ -s "$OUT.failures.txt" ]]; then
    awk 'index($0,"/")==0' "$OUT.failures.txt" | LC_ALL=C sort -u | sed '/^$/d' > "$CENSUS_FAIL"
    if [[ -s "$CENSUS_FAIL" ]] && [[ -n "$(LC_ALL=C comm -23 "$CENSUS_FAIL" "$OUT.population.txt")" ]]; then
      CENSUS_STATUS=MISMATCH
    fi
  fi
  if [[ "$CENSUS_STATUS" = OK ]]; then
    echo OK > "$OUT.census.status"
  else
    rm -f "$OUT.population.txt" "$OUT.skips.txt"
    echo MISMATCH > "$OUT.census.status"
  fi
  fi
  rm -f "$CENSUS_RAW" "$CENSUS_FAIL"
else
  # The rider is invisible when unset — and a stale census artifact from an earlier
  # run must never sit beside this run's other artifacts and be read as this run's.
  rm -f "$OUT.population.txt" "$OUT.skips.txt" "$OUT.census.status"
fi

exit "$rc"
