#!/usr/bin/env bash
# gate.test.sh — tests for scripts/gate.sh
# TEST_FILTER refused (blocks share sequential gate fixtures).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in gate.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "gate.sh — one fail-closed verdict card for both gates (verdict matrix)"; then
# The interpretation rules the phases used to restate as prose — red-on-red
# equals pass, extractor silence is never green, a skip is never clean — are
# code in gate.sh now. The matrix pins each of them; a regression here is a
# broken baseline advanced silently on a real migration.
GATE="$SKILL_DIR/scripts/gate.sh"
gate_status() { awk -F'\t' -v c="$2" '$1==c{print $2}' "$1"; }
gate_detail() { awk -F'\t' -v c="$2" '$1==c{print $3}' "$1"; }
gate_is() { # gate_is <card> <check> <want-status>
  local got; got=$(gate_status "$1" "$2")
  if [[ "$got" = "$3" ]]; then pass "gate row $2 = $3"; else fail "gate row $2 = ${got:-<none>} (want $3)"; fi
}
gate_row_present() { gate_status "$1" "$2" | grep -q .; }
gate_detail_has() { gate_detail "$1" "$2" | grep -qi -- "$3"; }

# build-manifest.sh stamps the two synthetic trees a classification was derived
# from into $RUN/classification-trees.tsv; the postmerge ask-user row re-verifies
# it, because a coverage tally computed from a classification derived against
# OTHER trees audits a set nobody enacted. Every postmerge fixture therefore
# carries the stamp its own $SYNTH implies, exactly as a real run does.
stamp_binding() { # stamp_binding <synth> <run>
  printf 'base\t%s\ntarget\t%s\n' \
    "$(git -C "$1" rev-parse 'kairos-base^{tree}')" \
    "$(git -C "$1" rev-parse 'kairos-target^{tree}')" > "$2/classification-trees.tsv"
}

GT=$SANDBOX/gate-comp; GTRUN=$SANDBOX/gate-run; GTSYN=$SANDBOX/gate-synth
mkdir -p "$GT" "$GTRUN" "$GTSYN"
( cd "$GTSYN" && git init -q -b main \
  && printf 'name: sprocket\nreplicas: 2\n' > config.yaml \
  && git add -A && git commit -qm target && git tag kairos-base && git tag kairos-target )
cd "$GT" && git init -q -b main
printf 'name: sprocket\nreplicas: 2\n' > config.yaml
git add -A && git commit -qm init
GT_EXTRACT="grep '^FAILID ' | awk '{print \$2}'"

# --- green suite => PASS, and every PASS row carries evidence ---
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GTRUN/test-command.txt"
: > "$GTRUN/test-baseline.failures.txt"
# Empty classification.tsv: the ask-user row's zero-classified PASS state.
: > "$GTRUN/classification.tsv"
stamp_binding "$GTSYN" "$GTRUN"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-green.card" 2> "$SANDBOX/gc-green.log"
expect "a green tree passes the gate (exit 0)" test $? -eq 0
gate_is "$SANDBOX/gc-green.card" AGGREGATE PASS
gate_is "$SANDBOX/gc-green.card" build PASS
gate_is "$SANDBOX/gc-green.card" tests PASS
gate_is "$SANDBOX/gc-green.card" yaml PASS
gate_is "$SANDBOX/gc-green.card" producer-idempotence PASS
gate_is "$SANDBOX/gc-green.card" replace-directives PASS
refute "no conflict-markers row under LABEL=postmerge" \
  gate_row_present "$SANDBOX/gc-green.card" conflict-markers
GC_NPASS=$(awk -F'\t' '$1!="AGGREGATE" && $2=="PASS"{n++} END{print n+0}' "$SANDBOX/gc-green.card")
GC_NOEV=$(awk -F'\t' '$1!="AGGREGATE" && $2=="PASS" && (NF<4 || $4==""){n++} END{print n+0}' "$SANDBOX/gc-green.card")
if [[ "$GC_NPASS" -ge 5 ]] && [[ "$GC_NOEV" -eq 0 ]]; then
  pass "every PASS row carries non-empty evidence ($GC_NPASS rows)"
else
  fail "every PASS row carries non-empty evidence ($GC_NOEV of $GC_NPASS PASS rows lack it)"
fi
expect "the card is also written to \$RUN/gate-<LABEL>.tsv" \
  cmp -s "$SANDBOX/gc-green.card" "$GTRUN/gate-postmerge.tsv"

# --- red-on-red equal to the baseline => PASS ---
printf 'TestAlpha\n' > "$GTRUN/test-baseline.failures.txt"
printf '%s\n' 'echo "FAILID TestAlpha"; false' "$GT_EXTRACT" 'echo compiled' 'no regen command' \
  > "$GTRUN/test-command.txt"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-red.card" 2> "$SANDBOX/gc-red.log"
expect "a suite red exactly where the baseline was red passes (exit 0)" test $? -eq 0
gate_is "$SANDBOX/gc-red.card" tests PASS
expect "the red-on-red pass says so in its detail" \
  gate_detail_has "$SANDBOX/gc-red.card" tests red-on-red
gate_is "$SANDBOX/gc-red.card" AGGREGATE PASS

# --- a new failing test ID => FAIL naming the ID ---
printf '%s\n' 'echo "FAILID TestAlpha"; echo "FAILID TestNewBeta"; false' "$GT_EXTRACT" \
  'echo compiled' 'no regen command' > "$GTRUN/test-command.txt"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-newfail.card" 2> "$SANDBOX/gc-newfail.log"
GC_NF_RC=$?
if [[ "$GC_NF_RC" -ne 0 ]]; then pass "a merge-induced regression fails the gate"; else fail "a new failing ID passed the gate"; fi
gate_is "$SANDBOX/gc-newfail.card" tests FAIL
expect "the FAIL row names the new failing test ID" \
  gate_detail_has "$SANDBOX/gc-newfail.card" tests TestNewBeta
refute "the FAIL row does not blame the baseline-red ID" \
  gate_detail_has "$SANDBOX/gc-newfail.card" tests TestAlpha
gate_is "$SANDBOX/gc-newfail.card" AGGREGATE FAIL

# --- an unreadable baseline => FAIL: gate-internal, never red-on-red PASS ---
# The baseline exists (the -f guard passes) but cannot be read: comm dying with
# empty output inside $(...) used to be indistinguishable from "no new failures"
# and rounded a real regression (TestNewBeta) up to a red-on-red PASS.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the unreadable-baseline arm is not exercised: 6 assertions (gate-internal FAIL, never red-on-red)"
else
  printf '%s\n' 'echo "FAILID TestAlpha"; echo "FAILID TestNewBeta"; false' "$GT_EXTRACT" \
    'echo compiled' 'no regen command' > "$GTRUN/test-command.txt"
  printf 'TestAlpha\n' > "$GTRUN/test-baseline.failures.txt"
  chmod 000 "$GTRUN/test-baseline.failures.txt"
  LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
    > "$SANDBOX/gc-noread.card" 2> "$SANDBOX/gc-noread.log"
  GC_NR_RC=$?
  chmod 644 "$GTRUN/test-baseline.failures.txt"
  if [[ "$GC_NR_RC" -ne 0 ]]; then pass "an unreadable baseline fails the gate"; else fail "an unreadable baseline passed the gate"; fi
  gate_is "$SANDBOX/gc-noread.card" tests FAIL
  expect "the unreadable-baseline FAIL is gate-internal" \
    gate_detail_has "$SANDBOX/gc-noread.card" tests gate-internal
  # T6: the arm is pinned by its OWN wording, not only the shared gate-internal
  # token, so a reworded arm cannot silently drift to another gate-internal cause.
  expect "the unreadable-baseline FAIL names the distinguishing cause" \
    gate_detail_has "$SANDBOX/gc-noread.card" tests "exists but is unreadable"
  refute "an unreadable baseline is never read as red-on-red" \
    gate_detail_has "$SANDBOX/gc-noread.card" tests red-on-red
  gate_is "$SANDBOX/gc-noread.card" AGGREGATE FAIL
fi

# --- a MISSING baseline => FAIL: gate-internal, worded for its own cause ---------
# Distinct from the unreadable arm above (which needs the -f guard to pass): here
# the file is absent, and the arm must say so rather than share a generic message.
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' \
  > "$GTRUN/test-command.txt"
rm -f "$GTRUN/test-baseline.failures.txt"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-nobase.card" 2> "$SANDBOX/gc-nobase.log"
if [[ $? -ne 0 ]]; then pass "a missing baseline fails the gate"; else fail "a missing baseline passed the gate"; fi
gate_is "$SANDBOX/gc-nobase.card" tests FAIL
expect "the missing-baseline FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gc-nobase.card" tests gate-internal
expect "the missing-baseline FAIL names the distinguishing cause (T6)" \
  gate_detail_has "$SANDBOX/gc-nobase.card" tests "no pre-merge baseline to compare against"
: > "$GTRUN/test-baseline.failures.txt"

# --- whitespace-defeated test-command.txt lines => FAIL: gate-internal, never a vacuous PASS ---
# A rejection comment drifted onto a positional line with a leading space, or a
# whitespace-only line, used to slip past the empty/#-comment guards and reach
# eval — where " # …" and "   " exit 0 doing nothing, manufacturing a green
# suite / clean build out of a run that never happened.
printf '%s\n' ' # rejected: go test ./...' "$GT_EXTRACT" 'echo compiled' 'no regen command' \
  > "$GTRUN/test-command.txt"
printf 'TestAlpha\n' > "$GTRUN/test-baseline.failures.txt"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-wscomment.card" 2> "$SANDBOX/gc-wscomment.log"
if [[ $? -ne 0 ]]; then pass "a space-prefixed rejection comment on line 1 fails the gate"; else fail "a space-prefixed rejection comment on line 1 passed the gate"; fi
gate_is "$SANDBOX/gc-wscomment.card" tests FAIL
expect "the drifted-comment FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gc-wscomment.card" tests gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the drifted-comment FAIL names the not-a-command cause" \
  gate_detail_has "$SANDBOX/gc-wscomment.card" tests "is not a command or the literal 'no tests detected'"
gate_is "$SANDBOX/gc-wscomment.card" AGGREGATE FAIL

printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" '   ' 'no regen command' > "$GTRUN/test-command.txt"
: > "$GTRUN/test-baseline.failures.txt"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-wsbuild.card" 2> "$SANDBOX/gc-wsbuild.log"
if [[ $? -ne 0 ]]; then pass "a whitespace-only line 3 fails the gate"; else fail "a whitespace-only line 3 passed the gate as a clean build"; fi
gate_is "$SANDBOX/gc-wsbuild.card" build FAIL
expect "the whitespace-only-build FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gc-wsbuild.card" build gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the whitespace-only-build FAIL names the not-a-command cause" \
  gate_detail_has "$SANDBOX/gc-wsbuild.card" build "is not a command or the literal 'no build check'"
gate_is "$SANDBOX/gc-wsbuild.card" AGGREGATE FAIL

# Line 4 is producer-idempotence.sh's, not gate.sh's line() — its own trim must
# stop the same class: a drifted " # …" or "   " regen line reaching eval is a
# shell no-op recorded "clean", i.e. producer-idempotence PASS with no producer
# ever run. With no other producer (line 3 non-command), the fail-safe row is
# INCOMPLETE "no producer ran" — never PASS.
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'no build check' ' # rejected: go generate ./... — dirties tree' \
  > "$GTRUN/test-command.txt"
: > "$GTRUN/test-baseline.failures.txt"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-wsregen.card" 2> "$SANDBOX/gc-wsregen.log"
gate_is "$SANDBOX/gc-wsregen.card" producer-idempotence INCOMPLETE
expect "the drifted-comment line 4 lands on the no-producer-ran fail-safe" \
  gate_detail_has "$SANDBOX/gc-wsregen.card" producer-idempotence "no producer ran"
refute "a drifted rejection comment on line 4 is never a vacuous producer PASS" \
  bash -c "awk -F'\t' '\$1==\"producer-idempotence\" && \$2==\"PASS\"' '$SANDBOX/gc-wsregen.card' | grep -q ."

printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'no build check' '   ' > "$GTRUN/test-command.txt"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-wsregen2.card" 2> "$SANDBOX/gc-wsregen2.log"
gate_is "$SANDBOX/gc-wsregen2.card" producer-idempotence INCOMPLETE
refute "a whitespace-only line 4 is never a vacuous producer PASS" \
  bash -c "awk -F'\t' '\$1==\"producer-idempotence\" && \$2==\"PASS\"' '$SANDBOX/gc-wsregen2.card' | grep -q ."

# --- EXTRACTOR_MISMATCH => FAIL, never PASS ---
printf '%s\n' 'echo boom; false' "$GT_EXTRACT" 'echo compiled' 'no regen command' \
  > "$GTRUN/test-command.txt"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-mismatch.card" 2> "$SANDBOX/gc-mismatch.log"
GC_MM_RC=$?
if [[ "$GC_MM_RC" -ne 0 ]]; then pass "extractor silence on a red suite fails the gate"; else fail "EXTRACTOR_MISMATCH passed the gate"; fi
gate_is "$SANDBOX/gc-mismatch.card" tests FAIL
expect "the mismatch FAIL blames the extractor" \
  gate_detail_has "$SANDBOX/gc-mismatch.card" tests extractor
gate_is "$SANDBOX/gc-mismatch.card" AGGREGATE FAIL

# --- no tests / no build check => INCOMPLETE, present in the card, aggregate stays PASS ---
printf '%s\n' 'no tests detected' "$GT_EXTRACT" 'no build check' 'no regen command' \
  > "$GTRUN/test-command.txt"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-notests.card" 2> "$SANDBOX/gc-notests.log"
expect "INCOMPLETE coverage never flips the aggregate to FAIL (exit 0)" test $? -eq 0
gate_is "$SANDBOX/gc-notests.card" tests INCOMPLETE
expect "the no-tests INCOMPLETE says no-tests" \
  gate_detail_has "$SANDBOX/gc-notests.card" tests no-tests
gate_is "$SANDBOX/gc-notests.card" build INCOMPLETE
gate_is "$SANDBOX/gc-notests.card" producer-idempotence INCOMPLETE
gate_is "$SANDBOX/gc-notests.card" AGGREGATE PASS

# --- a build failure names what broke ---
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" \
  'echo "compile error: main.go:3 undefined flangebox" >&2; false' 'no regen command' \
  > "$GTRUN/test-command.txt"
: > "$GTRUN/test-baseline.failures.txt"
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-build.card" 2> "$SANDBOX/gc-build.log"
GC_B_RC=$?
if [[ "$GC_B_RC" -ne 0 ]]; then pass "a broken build fails the gate"; else fail "a broken build passed the gate"; fi
gate_is "$SANDBOX/gc-build.card" build FAIL
expect "the build FAIL row carries the error, not a bare 'build failed'" \
  gate_detail_has "$SANDBOX/gc-build.card" build flangebox
gate_is "$SANDBOX/gc-build.card" AGGREGATE FAIL

# --- replace directive under LABEL=postmerge => NEEDS-INPUT, aggregate != PASS ---
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' \
  > "$GTRUN/test-command.txt"
printf 'module example.com/gatecomp\n\ngo 1.21\n\nreplace example.com/common => ../kairos-component-common\n' > go.mod
git add go.mod && git commit -qm gomod
LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gc-replace.card" 2> "$SANDBOX/gc-replace.log"
GC_R_RC=$?
if [[ "$GC_R_RC" -ne 0 ]]; then pass "an inherited local-path replace blocks a PASS aggregate"; else fail "a local-path replace directive slid through as PASS"; fi
gate_is "$SANDBOX/gc-replace.card" replace-directives NEEDS-INPUT
expect "the NEEDS-INPUT row shows the directive" \
  gate_detail_has "$SANDBOX/gc-replace.card" replace-directives kairos-component-common
gate_is "$SANDBOX/gc-replace.card" AGGREGATE NEEDS-INPUT
refute "no FAIL row was invented for the replace question" \
  bash -c "awk -F'\t' '\$2==\"FAIL\"' '$SANDBOX/gc-replace.card' | grep -q ."

# --- LABEL=final: no replace check, marker scan instead ---
LABEL=final RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-final.card" 2> "$SANDBOX/gc-final.log"
expect "a clean tree passes the final gate even with a replace directive (final does not run that check)" \
  test $? -eq 0
gate_is "$SANDBOX/gc-final.card" conflict-markers PASS
refute "no replace-directives row under LABEL=final" \
  gate_row_present "$SANDBOX/gc-final.card" replace-directives
gate_is "$SANDBOX/gc-final.card" AGGREGATE PASS

# --- markers in an untracked-but-unignored file => FAIL naming the file --------
# (incl. the bare separator). Untracked is the shape that matters: a file that
# landed in THIS merge is not tracked yet at the gate, so a tracked-only scan
# would be blind to exactly the content this check exists to inspect.
printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > conflicted.txt
refute "the marker file is genuinely untracked (a tracked-only scan would miss it)" \
  git ls-files --error-unmatch conflicted.txt
LABEL=final RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-markers.card" 2> "$SANDBOX/gc-markers.log"
GC_M_RC=$?
if [[ "$GC_M_RC" -ne 0 ]]; then pass "a surviving conflict marker fails the final gate"; else fail "conflict markers passed the final gate"; fi
gate_is "$SANDBOX/gc-markers.card" conflict-markers FAIL
expect "the marker FAIL names the file" \
  gate_detail_has "$SANDBOX/gc-markers.card" conflict-markers conflicted.txt
gate_is "$SANDBOX/gc-markers.card" AGGREGATE FAIL
rm -f conflicted.txt

# --- markers in a TRACKED file => FAIL naming the file -------------------------
printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > tracked-conflict.md
git add tracked-conflict.md && git commit -qm "tracked marker"
LABEL=final RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-tracked.card" 2> "$SANDBOX/gc-tracked.log"
GC_T_RC=$?
if [[ "$GC_T_RC" -ne 0 ]]; then pass "a marker in a tracked file fails the final gate"; else fail "a tracked marker passed the final gate"; fi
gate_is "$SANDBOX/gc-tracked.card" conflict-markers FAIL
expect "the tracked marker FAIL names the file" \
  gate_detail_has "$SANDBOX/gc-tracked.card" conflict-markers tracked-conflict.md
git rm -q -f tracked-conflict.md && git commit -qm "drop tracked marker"

# --- a marker in a GITIGNORED directory does NOT fail the final gate -----------
# The candidate set comes from git, so ignored output trees (.venv/, dist/) are
# out of scope: a marker-shaped line there is content the merge never touched,
# and it used to block finalize as a false FAIL.
printf 'dist/\n' > .gitignore
mkdir -p dist
printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > dist/build.txt
LABEL=final RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-ignored.card" 2> "$SANDBOX/gc-ignored.log"
expect "a marker in a gitignored directory does not fail the final gate (exit 0)" \
  test $? -eq 0
gate_is "$SANDBOX/gc-ignored.card" conflict-markers PASS
gate_is "$SANDBOX/gc-ignored.card" AGGREGATE PASS
rm -rf dist .gitignore

# --- markers in a COMMITTED vendor/ or node_modules/ tree => still PASS ---------
# git lists tracked paths regardless of ignore rules, so a component that commits
# its dependency tree (`go mod vendor`, a checked-in node_modules) puts every
# third-party file in the candidate set — and a Markdown setext underline in a
# vendored README is a bare `=======`, i.e. a false FAIL on content the merge
# never touched. So the two prefixes are filtered EXPLICITLY, at any depth, the
# same way yaml-gate.sh and run-check-modules.sh filter them: all three agree on
# the merge surface. Asserted on the candidate list, not just the verdict: the
# files must be absent from the SET, not merely non-matching.
mkdir -p vendor/github.com/foo node_modules/bar web/node_modules/pkg
printf 'Heading\n=======\n\nbody\n' > vendor/github.com/foo/README.md
printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > node_modules/bar/index.js
printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > web/node_modules/pkg/index.js
git add -A && git commit -qm "commit dependency trees"
expect "the vendored file is genuinely TRACKED (an ignore-based filter would not reach it)" \
  git ls-files --error-unmatch vendor/github.com/foo/README.md
LABEL=final RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-vendor.card" 2> "$SANDBOX/gc-vendor.log"
expect "a marker-shaped line in a committed vendor/ or node_modules/ tree does not fail the final gate (exit 0)" \
  test $? -eq 0
gate_is "$SANDBOX/gc-vendor.card" conflict-markers PASS
gate_is "$SANDBOX/gc-vendor.card" AGGREGATE PASS
refute "the committed vendor/ tree is filtered out of the candidate SET" \
  grep -q '^vendor/' "$GTRUN/.gate-marker-files.final"
refute "a root-level node_modules/ is filtered out of the candidate SET" \
  grep -q '^node_modules/' "$GTRUN/.gate-marker-files.final"
refute "a NESTED node_modules/ is filtered too (the (^|/) anchor, not just a prefix)" \
  grep -q '^web/node_modules/' "$GTRUN/.gate-marker-files.final"
expect "the component's own tracked files are still in the candidate set" \
  grep -q '^config\.yaml$' "$GTRUN/.gate-marker-files.final"
expect "the PASS evidence names the excluded prefixes" \
  bash -c "awk -F'\t' '\$1==\"conflict-markers\"{print \$4}' '$SANDBOX/gc-vendor.card' | grep -q 'vendor/ and node_modules/'"
git rm -q -r -f vendor node_modules web && git commit -qm "drop dependency trees"

# --- a COMMITTED BINARY whose bytes spell marker-shaped lines => still PASS -----
# Conflict markers are text-only by construction (git's own merge machinery
# never emits them into a binary blob), but the marker grep used to run without
# -I: a binary (image/font/PDF) that happens to carry a `=======` or `<<<<<<< `
# line boundary in its bytes hard-blocked finalize with no acknowledgment path
# — a false positive on a non-problem, the one thing this gate forbids. The
# fixture is deliberately OUTSIDE vendor/ and node_modules/: this is testing the
# grep -I binary skip, not the path-prefix filter exercised just above.
printf 'BIN\0DATA\n=======\nmore\0\n' > binary-conflict.bin
git add binary-conflict.bin && git commit -qm "commit a binary with marker-shaped bytes"
refute "the binary fixture is classified as binary by grep -I (pins fixture validity, independent of gate.sh)" \
  grep -IlE '^(<{7}|\|{7}|>{7}) |^={7}$' -- binary-conflict.bin
# Positive control: -a force-reads the binary as text, so the pattern must
# genuinely match its bytes. Without this, a grep that already skips binaries
# by default (no -I needed) would make the whole block pass pre- and post-fix
# alike — unfalsifiable.
expect "the marker pattern genuinely matches the fixture's bytes when force-read as text" \
  grep -alE '^(<{7}|\|{7}|>{7}) |^={7}$' -- binary-conflict.bin
LABEL=final RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-binary.card" 2> "$SANDBOX/gc-binary.log"
expect "a committed binary with marker-shaped bytes does not fail the final gate (exit 0)" \
  test $? -eq 0
gate_is "$SANDBOX/gc-binary.card" conflict-markers PASS
refute "the binary is never named as a conflict-marker finding" \
  gate_detail_has "$SANDBOX/gc-binary.card" conflict-markers binary-conflict.bin
gate_is "$SANDBOX/gc-binary.card" AGGREGATE PASS
git rm -q -f binary-conflict.bin && git commit -qm "drop binary marker fixture"

# --- a bare separator with a trailing CR (CRLF) => still FAIL naming the file ---
# GNU grep's ERE `$` anchors immediately before the line's own terminating LF,
# so a `=======\r` line (CRLF checkout, or a Windows-authored conflict) sits one
# byte short of `^={7}$` under GNU grep — only BSD grep's `$` is lenient enough
# to match it by accident, which is why this false-negative only showed up on
# Linux. The fix composes a literal, optional CR byte onto the bare-separator
# alternative (never the two-character `\r` escape, which no grep ERE
# interprets), so this must fail on every platform running this suite.
printf '<<<<<<< ours\r\nx\r\n=======\r\ny\r\n>>>>>>> theirs\r\n' > crlf-conflict.txt
git add crlf-conflict.txt && git commit -qm "commit a CRLF conflict fixture"
LABEL=final RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-crlf.card" 2> "$SANDBOX/gc-crlf.log"
GC_CRLF_RC=$?
if [[ "$GC_CRLF_RC" -ne 0 ]]; then pass "a CRLF bare separator fails the final gate"; else fail "a CRLF bare separator passed the final gate"; fi
gate_is "$SANDBOX/gc-crlf.card" conflict-markers FAIL
expect "the CRLF-separator FAIL names the file" \
  gate_detail_has "$SANDBOX/gc-crlf.card" conflict-markers crlf-conflict.txt
gate_is "$SANDBOX/gc-crlf.card" AGGREGATE FAIL
git rm -q -f crlf-conflict.txt && git commit -qm "drop CRLF conflict fixture"

# --- a longer (8-equals) setext underline, even with CRLF, is still NOT flagged -
# The bare-separator alternative matches EXACTLY 7 equals signs. Allowing an
# optional trailing CR must not loosen the count: a Markdown setext underline
# one character longer than a real separator — CRLF-terminated, the same line
# ending as the fixture above — must keep passing.
printf 'Heading\r\n========\r\n\r\nbody\r\n' > setext.md
git add setext.md && git commit -qm "commit a setext-underline fixture"
LABEL=final RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-setext.card" 2> "$SANDBOX/gc-setext.log"
expect "a longer (8-equals) CRLF setext underline still passes the final gate (exit 0)" \
  test $? -eq 0
gate_is "$SANDBOX/gc-setext.card" conflict-markers PASS
git rm -q -f setext.md && git commit -qm "drop setext-underline fixture"
cd "$SANDBOX"

# --- an empty candidate set => PASS with evidence, never gate-internal ---------
# grep with no file arguments reads stdin: an unguarded empty list hangs the
# gate. An emptied candidate set is also a real, clean state, so it owes a PASS
# row with positive evidence — not the gate-internal FAIL a missing scan gets.
GE=$SANDBOX/gate-empty; GERUN=$SANDBOX/gate-empty-run
mkdir -p "$GE" "$GERUN"
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GERUN/test-command.txt"
: > "$GERUN/test-baseline.failures.txt"
cd "$GE" && git init -q -b main
# '*' ignores the whole tree including .gitignore itself: nothing tracked,
# nothing untracked-but-unignored — zero candidates, and a marker file that no
# scan should reach.
printf '*\n' > .gitignore
printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > leftover.txt
LABEL=final RUN=$GERUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-empty.card" 2> "$SANDBOX/gc-empty.log"
gate_is "$SANDBOX/gc-empty.card" conflict-markers PASS
refute "the empty candidate set is not reported as gate-internal" \
  gate_detail_has "$SANDBOX/gc-empty.card" conflict-markers gate-internal
GC_E_EV=$(awk -F'\t' '$1=="conflict-markers"{print $4}' "$SANDBOX/gc-empty.card")
if [[ -n "$GC_E_EV" ]]; then
  pass "the empty-candidate PASS row still carries evidence"
else
  fail "the empty-candidate PASS row carries no evidence"
fi
cd "$SANDBOX"

# --- a candidate list that could not be built => gate-internal, never PASS -----
# An unwritable list is NOT an empty list: the scan never ran. Left unguarded,
# the read loop simply yields zero candidates and the check reports PASS over a
# tree it never opened — the fail-open shape this whole gate is built against.
# The list path is pre-created as a DIRECTORY so only that write fails; every
# other check still runs normally, and a real marker sits in the tree.
GB=$SANDBOX/gate-badlist; GBRUN=$SANDBOX/gate-badlist-run
mkdir -p "$GB" "$GBRUN"
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GBRUN/test-command.txt"
: > "$GBRUN/test-baseline.failures.txt"
cd "$GB" && git init -q -b main
printf 'a: 1\n' > config.yaml
git add -A && git commit -qm init
printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > conflicted.txt
mkdir -p "$GBRUN/.gate-marker-files.final"
LABEL=final RUN=$GBRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-badlist.card" 2> "$SANDBOX/gc-badlist.log"
GC_BL_RC=$?
if [[ "$GC_BL_RC" -ne 0 ]]; then pass "an unbuildable candidate list fails the final gate"; else fail "an unbuildable candidate list passed the final gate"; fi
gate_is "$SANDBOX/gc-badlist.card" conflict-markers FAIL
expect "the unbuildable-list FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gc-badlist.card" conflict-markers gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the unbuildable-list FAIL names the never-written cause" \
  gate_detail_has "$SANDBOX/gc-badlist.card" conflict-markers "could not be written or read back"
refute "a scan that never ran is never the empty-list PASS" \
  bash -c "awk -F'\t' '\$1==\"conflict-markers\" && \$2==\"PASS\"' '$SANDBOX/gc-badlist.card' | grep -q ."
gate_is "$SANDBOX/gc-badlist.card" AGGREGATE FAIL
rmdir "$GBRUN/.gate-marker-files.final"
cd "$SANDBOX"

# --- a candidate listing that FAILED => gate-internal, never a zero-candidate PASS ---
# Failed and empty are different states. As the head of a masked pipeline the
# listing's exit status is sort's and its stderr is discarded, so a `git ls-files`
# that dies (cwd is not a repo, index corrupt) is byte-identical to an empty tree
# — and the marker check PASSes having scanned zero files. Regression.
GNR=$SANDBOX/gate-nonrepo; GNRRUN=$SANDBOX/gate-nonrepo-run
mkdir -p "$GNR" "$GNRRUN"
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GNRRUN/test-command.txt"
: > "$GNRRUN/test-baseline.failures.txt"
printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > "$GNR/conflicted.txt"
cd "$GNR"
refute "the fixture cwd is genuinely outside any git repo (git ls-files must fail)" \
  git rev-parse --git-dir
LABEL=final RUN=$GNRRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-nonrepo.card" 2> "$SANDBOX/gc-nonrepo.log"
GC_NRP_RC=$?
if [[ "$GC_NRP_RC" -ne 0 ]]; then pass "a failed candidate listing fails the final gate"; else fail "a failed candidate listing passed the final gate"; fi
gate_is "$SANDBOX/gc-nonrepo.card" conflict-markers FAIL
expect "the failed-listing FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gc-nonrepo.card" conflict-markers gate-internal
expect "the failed-listing FAIL names the failing command" \
  gate_detail_has "$SANDBOX/gc-nonrepo.card" conflict-markers "git ls-files failed"
expect "the failed-listing FAIL carries git's own first stderr line" \
  gate_detail_has "$SANDBOX/gc-nonrepo.card" conflict-markers "not a git repository"
refute "a listing that FAILED is never the empty-listing PASS" \
  bash -c "awk -F'\t' '\$1==\"conflict-markers\" && \$2==\"PASS\"' '$SANDBOX/gc-nonrepo.card' | grep -q ."
gate_is "$SANDBOX/gc-nonrepo.card" AGGREGATE FAIL
cd "$SANDBOX"

# --- a candidate set whose argv exceeds ARG_MAX is still SCANNED ----------------
# The scan greps the candidate list in batches. One exec over the whole set is an
# E2BIG on any component with a committed dependency tree (thousands of paths):
# grep is never started, exits 126, and the row reads gate-internal — an
# unrecoverable FAIL on a clean tree that no user action can clear. The fixture
# sizes itself from the platform's own ARG_MAX so it is over the limit anywhere,
# and asserts that first: a fixture that fits in one exec would not catch this.
GBT=$SANDBOX/gate-bigtree; GBTRUN=$SANDBOX/gate-bigtree-run
mkdir -p "$GBT" "$GBTRUN"
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GBTRUN/test-command.txt"
: > "$GBTRUN/test-baseline.failures.txt"
cd "$GBT" && git init -q -b main
printf 'a: 1\n' > config.yaml
# ~425 argv bytes per path: a 216-char directory prefix plus a padded basename.
# 'argvfill' sorts before 'config.yaml', so the padded files lead the list.
GBT_DIR=$(printf 'argvfill/%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)
GBT_PAD=$(printf 'p%.0s' $(seq 1 200))
GBT_AMAX=$(getconf ARG_MAX 2>/dev/null); GBT_AMAX=${GBT_AMAX:-1048576}
GBT_N=$(( GBT_AMAX / 425 + 300 ))
mkdir -p "$GBT_DIR"
GBT_I=0
while [[ "$GBT_I" -lt "$GBT_N" ]]; do : > "$GBT_DIR/f$GBT_I-$GBT_PAD.txt"; GBT_I=$((GBT_I+1)); done
git add -A && git commit -qm "big tracked tree"
GBT_ARGV=$(git ls-files | wc -c | tr -d ' ')
if [[ "$GBT_ARGV" -gt "$GBT_AMAX" ]]; then
  pass "the fixture's candidate argv ($GBT_ARGV bytes) exceeds ARG_MAX ($GBT_AMAX) — one exec would be E2BIG"
else
  fail "the fixture's candidate argv ($GBT_ARGV bytes) does not exceed ARG_MAX ($GBT_AMAX) — this test cannot catch the batching regression"
fi
LABEL=final RUN=$GBTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-bigtree.card" 2> "$SANDBOX/gc-bigtree.log"
expect "a clean tree larger than ARG_MAX passes the final gate (exit 0)" test $? -eq 0
gate_is "$SANDBOX/gc-bigtree.card" conflict-markers PASS
refute "an over-ARG_MAX candidate set is never reported as gate-internal" \
  gate_detail_has "$SANDBOX/gc-bigtree.card" conflict-markers gate-internal
expect "the PASS evidence accounts for every candidate in the oversized set" \
  bash -c "awk -F'\t' '\$1==\"conflict-markers\"{print \$4}' '$SANDBOX/gc-bigtree.card' | grep -q '0 hits across $((GBT_N + 1)) candidate file(s)'"
gate_is "$SANDBOX/gc-bigtree.card" AGGREGATE PASS
# Hits must be collected from EVERY batch, not just the one that reported first.
# Lines 1 / 700 / last of the candidate list are three distinct batches at
# gate.sh's batch size of 500.
grep '^argvfill/' "$GBTRUN/.gate-marker-files.final" > "$SANDBOX/gc-bigtree.cands"
for GBT_P in 1 700 '$'; do
  GBT_F=$(sed -n "${GBT_P}p" "$SANDBOX/gc-bigtree.cands")
  printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > "$GBT_F"
done
LABEL=final RUN=$GBTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-bigtree2.card" 2> "$SANDBOX/gc-bigtree2.log"
GBT_RC=$?
if [[ "$GBT_RC" -ne 0 ]]; then pass "markers spread across batches fail the final gate"; else fail "batched markers passed the final gate"; fi
gate_is "$SANDBOX/gc-bigtree2.card" conflict-markers FAIL
expect "all three cross-batch hits are counted, not just the first batch's" \
  gate_detail_has "$SANDBOX/gc-bigtree2.card" conflict-markers "3 file(s) carry conflict markers"
gate_is "$SANDBOX/gc-bigtree2.card" AGGREGATE FAIL
# A bad rc in ONE batch must be sticky AND dominant. Only the multi-batch shape
# tests this: within a single batch, grep's rc-2 output is discarded, so there
# are no hits to lose the race to. Here batch 1 matches (line 1 still carries a
# marker) and a later batch cannot be read — the scan did not complete, so the
# row owes gate-internal, not a confident "3 files carry markers" over a set it
# only half-opened.
GBT_LOCK=$(sed -n '1200p' "$SANDBOX/gc-bigtree.cands")
chmod 000 "$GBT_LOCK"
LABEL=final RUN=$GBTRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-bigtree3.card" 2> "$SANDBOX/gc-bigtree3.log"
GBT3_RC=$?
chmod 644 "$GBT_LOCK"
if [[ "$GBT3_RC" -ne 0 ]]; then pass "an unreadable candidate in a later batch fails the final gate"; else fail "an unreadable later batch passed the final gate"; fi
gate_is "$SANDBOX/gc-bigtree3.card" conflict-markers FAIL
# BB CI runs as root: chmod 000 stays readable to root (DAC bypass), so the
# locked batch completes for real and the row is the confident "N file(s)"
# finding, never gate-internal — these two assertions only hold non-root.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the locked-later-batch arms are not exercised: 2 assertions (bad rc in one batch is gate-internal; a half-completed scan is not a named finding)"
else
  expect "a bad rc in one batch is gate-internal even though an earlier batch matched" \
    gate_detail_has "$SANDBOX/gc-bigtree3.card" conflict-markers gate-internal
  # T6: pinned by the arm's own wording, not only the shared gate-internal token.
  expect "the half-completed-scan FAIL names the grep-exited cause" \
    gate_detail_has "$SANDBOX/gc-bigtree3.card" conflict-markers "marker grep exited"
  refute "a half-completed scan is never reported as a confident named finding" \
    gate_detail_has "$SANDBOX/gc-bigtree3.card" conflict-markers "file(s) carry conflict markers"
fi
gate_is "$SANDBOX/gc-bigtree3.card" AGGREGATE FAIL
cd "$SANDBOX"

# --- an unreadable candidate within a single batch => gate-internal too ----------
# The per-batch arm that records any rc other than 0/1: without it an unreadable
# candidate reads as "no hits in this batch", i.e. a scan that never opened the
# file reported clean. (Single-batch, so the dominance ordering above is not what
# is under test here — the recording of the bad rc at all is.)
GUR=$SANDBOX/gate-unreadable; GURRUN=$SANDBOX/gate-unreadable-run
mkdir -p "$GUR" "$GURRUN"
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GURRUN/test-command.txt"
: > "$GURRUN/test-baseline.failures.txt"
cd "$GUR" && git init -q -b main
printf 'a: 1\n' > config.yaml
printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > conflicted.txt
printf 'secret\n' > locked.txt
git add -A && git commit -qm init
chmod 000 locked.txt
LABEL=final RUN=$GURRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-unread.card" 2> "$SANDBOX/gc-unread.log"
GUR_RC=$?
chmod 644 locked.txt
if [[ "$GUR_RC" -ne 0 ]]; then pass "an unreadable candidate fails the final gate"; else fail "an unreadable candidate passed the final gate"; fi
gate_is "$SANDBOX/gc-unread.card" conflict-markers FAIL
# Same root exemption as the bigtree3 case above: chmod 000 on locked.txt stays
# readable to root, so the batch completes and conflicted.txt's real marker
# surfaces as a plain named finding, not gate-internal.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the unreadable-candidate arms are not exercised: 2 assertions (a batch that could not be fully read is gate-internal; an incomplete scan is not a plain finding)"
else
  expect "a batch that could not be fully read is gate-internal, never a clean batch" \
    gate_detail_has "$SANDBOX/gc-unread.card" conflict-markers gate-internal
  # T6: pinned by the arm's own wording, not only the shared gate-internal token.
  expect "the unreadable-candidate FAIL names the grep-exited cause" \
    gate_detail_has "$SANDBOX/gc-unread.card" conflict-markers "marker grep exited"
  refute "an incomplete scan is never reported as a plain named finding" \
    gate_detail_has "$SANDBOX/gc-unread.card" conflict-markers "file(s) carry conflict markers"
fi
gate_is "$SANDBOX/gc-unread.card" AGGREGATE FAIL
cd "$SANDBOX"

# --- a candidate path with an EMBEDDED NEWLINE is scanned, never split away -------
# git tracks a path containing a newline — that is why the listing is `git ls-files
# -z` — and the candidate list used to be re-split with `tr '\0' '\n'`: such a path
# became TWO lines, NEITHER of which names a file, both dropped by the regular-file
# test, with nothing reconciling the counts. The row then printed "0 hits across N
# candidate file(s)" over a tree carrying markers in exactly the file nobody opened:
# the fail-open shape this whole check is built against. The fixture asserts the
# split behaviour first, so a still-splitting gate cannot pass this block vacuously.
GNL=$SANDBOX/gate-newline; GNLRUN=$SANDBOX/gate-newline-run
mkdir -p "$GNL" "$GNLRUN"
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GNLRUN/test-command.txt"
: > "$GNLRUN/test-baseline.failures.txt"
cd "$GNL" && git init -q -b main
printf 'a: 1\n' > config.yaml
GNL_F=$'two\nlines.txt'
printf 'clean body\n' > "$GNL_F"
git add -A && git commit -qm "commit an embedded-newline path"
expect "the fixture path is genuinely tracked with an embedded newline (a tr-split list yields a phantom line)" \
  bash -c "cd '$GNL' && git ls-files -z | tr '\0' '\n' | grep -qx 'lines.txt'"
LABEL=final RUN=$GNLRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-nlclean.card" 2> "$SANDBOX/gc-nlclean.log"
expect "a clean tree holding an embedded-newline path passes the final gate (exit 0)" \
  test $? -eq 0
gate_is "$SANDBOX/gc-nlclean.card" conflict-markers PASS
expect "the PASS evidence reconciles every listed candidate, the newline-bearing one included" \
  bash -c "awk -F'\t' '\$1==\"conflict-markers\"{print \$4}' '$SANDBOX/gc-nlclean.card' | grep -q '0 hits across 2 candidate file(s), every one of 2 listed'"
# Now put real markers in that same path: it must be scanned, and named.
printf '<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n' > "$GNL_F"
LABEL=final RUN=$GNLRUN SYNTH=$GTSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gc-newline.card" 2> "$SANDBOX/gc-newline.log"
GC_NL_RC=$?
if [[ "$GC_NL_RC" -ne 0 ]]; then
  pass "a marker in an embedded-newline path fails the final gate"
else
  fail "an embedded-newline path was dropped from the scan (its markers passed the final gate)"
fi
gate_is "$SANDBOX/gc-newline.card" conflict-markers FAIL
expect "the marker FAIL names the newline-bearing file" \
  gate_detail_has "$SANDBOX/gc-newline.card" conflict-markers "lines.txt"
refute "a dropped candidate is never the zero-hit PASS" \
  bash -c "awk -F'\t' '\$1==\"conflict-markers\" && \$2==\"PASS\"' '$SANDBOX/gc-newline.card' | grep -q ."
gate_is "$SANDBOX/gc-newline.card" AGGREGATE FAIL
cd "$SANDBOX"

# --- yaml ack row => acknowledged skip (INCOMPLETE), not a FAIL ---
GYA=$SANDBOX/gate-ack; GYARUN=$SANDBOX/gate-ack-run; GYASYN=$SANDBOX/gate-ack-synth
mkdir -p "$GYA" "$GYARUN" "$GYASYN"
( cd "$GYASYN" && git init -q -b main \
  && printf 'sprocket: 1\nother: 2\n' > deploy.yaml \
  && git add -A && git commit -qm target && git tag kairos-base && git tag kairos-target )
cd "$GYA" && git init -q -b main
printf 'other:\n  sprocket: 1\n' > deploy.yaml
git add -A && git commit -qm init
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GYARUN/test-command.txt"
: > "$GYARUN/test-baseline.failures.txt"
: > "$GYARUN/classification.tsv"
stamp_binding "$GYASYN" "$GYARUN"
LABEL=postmerge RUN=$GYARUN SYNTH=$GYASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gy-buried.card" 2> "$SANDBOX/gy-buried.log"
GY_RC=$?
if [[ "$GY_RC" -ne 0 ]]; then pass "an unacknowledged buried key fails the gate"; else fail "a buried key passed the gate"; fi
gate_is "$SANDBOX/gy-buried.card" yaml FAIL
expect "the yaml FAIL names the file" \
  gate_detail_has "$SANDBOX/gy-buried.card" yaml deploy.yaml
expect "the yaml FAIL names the buried key" \
  gate_detail_has "$SANDBOX/gy-buried.card" yaml sprocket
printf 'deploy.yaml\tsprocket\tdeliberately folded under other for this component\n' \
  > "$GYARUN/yaml-gate-ack.tsv"
LABEL=postmerge RUN=$GYARUN SYNTH=$GYASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gy-acked.card" 2> "$SANDBOX/gy-acked.log"
expect "the acknowledged demotion unblocks the gate (exit 0)" test $? -eq 0
gate_is "$SANDBOX/gy-acked.card" yaml INCOMPLETE
expect "the acknowledged skip stays visible in the card" \
  gate_detail_has "$SANDBOX/gy-acked.card" yaml acknowledged
gate_is "$SANDBOX/gy-acked.card" AGGREGATE PASS
cd "$SANDBOX"

# =============================================================================
fi

if t "gate.sh LABEL=midplan — Phase 7's midplan cadence runs the postmerge check set"; then
# Per-task gates are thin; after every fifth committed task (and each Flag-set
# task) Phase 7 re-runs the gate over the current tree as LABEL=midplan.
# Same checks as postmerge (incl. replace-directives, excl. conflict-markers);
# artifacts follow the existing gate-<LABEL>.* naming.
GM=$SANDBOX/gate-mid; GMRUN=$SANDBOX/gate-mid-run; GMSYN=$SANDBOX/gate-mid-synth
mkdir -p "$GM" "$GMRUN" "$GMSYN"
( cd "$GMSYN" && git init -q -b main \
  && printf 'a: 1\n' > config.yaml \
  && git add -A && git commit -qm target && git tag kairos-base && git tag kairos-target )
cd "$GM" && git init -q -b main
printf 'a: 1\n' > config.yaml
git add -A && git commit -qm init
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GMRUN/test-command.txt"
: > "$GMRUN/test-baseline.failures.txt"
: > "$GMRUN/classification.tsv"
stamp_binding "$GMSYN" "$GMRUN"
LABEL=midplan RUN=$GMRUN SYNTH=$GMSYN PHASE_KEY=$PK_EXECUTION "$GATE" \
  > "$SANDBOX/gm-green.card" 2> "$SANDBOX/gm-green.log"
expect "LABEL=midplan with the phase-7 key passes on a green tree (exit 0)" test $? -eq 0
gate_is "$SANDBOX/gm-green.card" AGGREGATE PASS
gate_is "$SANDBOX/gm-green.card" build PASS
gate_is "$SANDBOX/gm-green.card" tests PASS
gate_is "$SANDBOX/gm-green.card" replace-directives PASS
refute "no conflict-markers row under LABEL=midplan (that check is final-only)" \
  gate_row_present "$SANDBOX/gm-green.card" conflict-markers
expect "midplan writes its card to \$RUN/gate-midplan.tsv" \
  cmp -s "$SANDBOX/gm-green.card" "$GMRUN/gate-midplan.tsv"
expect "midplan check artifacts follow the label naming (test-midplan.status)" \
  test -f "$GMRUN/test-midplan.status"

LABEL=midplan RUN=$GMRUN SYNTH=$GMSYN "$GATE" > /dev/null 2> "$SANDBOX/gm-nokey.log"
GM_NOKEY_RC=$?
if [[ "$GM_NOKEY_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/7-execution.md first' "$SANDBOX/gm-nokey.log"; then
  pass "LABEL=midplan without PHASE_KEY is refused: load phases/7-execution.md first"
else
  fail "LABEL=midplan without PHASE_KEY is refused: load phases/7-execution.md first (rc=$GM_NOKEY_RC)"
fi
LABEL=midplan RUN=$GMRUN SYNTH=$GMSYN PHASE_KEY=not-the-key "$GATE" \
  > /dev/null 2> "$SANDBOX/gm-wrongkey.log"
GM_WRONG_RC=$?
if [[ "$GM_WRONG_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/7-execution.md first' "$SANDBOX/gm-wrongkey.log"; then
  pass "LABEL=midplan with a wrong PHASE_KEY is refused: load phases/7-execution.md first"
else
  fail "LABEL=midplan with a wrong PHASE_KEY is refused: load phases/7-execution.md first (rc=$GM_WRONG_RC)"
fi

# Existing label/key combinations must keep working exactly as before: the
# postmerge and final labels still accept their own phases' keys.
LABEL=postmerge RUN=$GMRUN SYNTH=$GMSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > /dev/null 2> "$SANDBOX/gm-pm.log"
expect "LABEL=postmerge with the phase-5 key still passes on the same tree" test $? -eq 0
LABEL=final RUN=$GMRUN SYNTH=$GMSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > /dev/null 2> "$SANDBOX/gm-fin.log"
expect "LABEL=final with the phase-8 key still passes on the same tree" test $? -eq 0
cd "$SANDBOX"

# =============================================================================
fi

if t "gate.sh replace-directives row — block form, nested modules, and the parse method"; then
# The check used to be a line-form grep over the ROOT go.mod only. Two shapes
# slipped straight through it as PASS: a block-form `replace ( … )` group, whose
# inner directives carry no `replace` keyword — the exact shape a co-developing
# author accumulates — and a replace in a sibling module, which the root-only
# grep never opened. Worse, a component with no root go.mod got a PASS ("nothing
# to check") without any nested module being looked at. reproduced pre-fix: all
# four cases below reported PASS.
GR=$SANDBOX/gate-rep; GRRUN=$SANDBOX/gate-rep-run; GRSYN=$SANDBOX/gate-rep-synth
mkdir -p "$GR" "$GRRUN" "$GRSYN"
( cd "$GRSYN" && git init -q -b main \
  && printf 'a: 1\n' > config.yaml \
  && git add -A && git commit -qm target && git tag kairos-base && git tag kairos-target )
cd "$GR" && git init -q -b main
printf 'a: 1\n' > config.yaml
git add -A && git commit -qm init
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GRRUN/test-command.txt"
: > "$GRRUN/test-baseline.failures.txt"
: > "$GRRUN/classification.tsv"
stamp_binding "$GRSYN" "$GRRUN"
gr_gate() { # gr_gate <card-basename>
  LABEL=postmerge RUN=$GRRUN SYNTH=$GRSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
    > "$SANDBOX/$1.card" 2> "$SANDBOX/$1.log"
}

# --- block-form replace ( … ) in the ROOT go.mod => NEEDS-INPUT ---------------
cat > go.mod <<'EOF'
module example.com/gatecomp

go 1.21

replace (
	example.com/common => ../kairos-component-common
)
EOF
git add -A && git commit -qm gomod-block
gr_gate gr-block
gate_is "$SANDBOX/gr-block.card" replace-directives NEEDS-INPUT
expect "the block-form row shows the directive a grep would have missed" \
  gate_detail_has "$SANDBOX/gr-block.card" replace-directives kairos-component-common
gate_is "$SANDBOX/gr-block.card" AGGREGATE NEEDS-INPUT
refute "the block-form finding is a question, not an invented FAIL" \
  bash -c "awk -F'\t' '\$2==\"FAIL\"' '$SANDBOX/gr-block.card' | grep -q ."

# --- a NESTED module's replace is seen even when the root go.mod is clean -----
printf 'module example.com/gatecomp\n\ngo 1.21\n' > go.mod
mkdir -p pkg/schema
printf 'module example.com/gatecomp/pkg/schema\n\ngo 1.21\n\nreplace example.com/common => ../../../kairos-component-common\n' \
  > pkg/schema/go.mod
git add -A && git commit -qm gomod-nested
gr_gate gr-nested
gate_is "$SANDBOX/gr-nested.card" replace-directives NEEDS-INPUT
expect "the nested-module row names the go.mod that carries the directive" \
  gate_detail_has "$SANDBOX/gr-nested.card" replace-directives 'pkg/schema/go.mod'

# --- no ROOT go.mod at all: the nested module is still scanned ----------------
# The old row's "no go.mod in this component — nothing to check" PASS claimed
# more than it had checked.
rm -f go.mod
git add -A && git commit -qm gomod-noroot
gr_gate gr-noroot
gate_is "$SANDBOX/gr-noroot.card" replace-directives NEEDS-INPUT

# --- an excluded module tree is out of scope by construction ------------------
# vendor/ carries dependency modules and .kairos/ the migration's own synthetic
# merge sides: a local replace in either is not this component's CI surface, and
# the sweep that builds the tree excludes them for the same reason.
mkdir -p vendor/example.com/dep .kairos/migration/state/synth
printf 'module example.com/dep\n\ngo 1.21\n\nreplace example.com/common => ../../../../common\n' \
  > vendor/example.com/dep/go.mod
printf 'module example.com/synth\n\ngo 1.21\n\nreplace example.com/common => ../../common\n' \
  > .kairos/migration/state/synth/go.mod
printf 'module example.com/gatecomp/pkg/schema\n\ngo 1.21\n\nrequire example.com/common v1.2.3\n\nreplace example.com/common => example.com/common v1.2.4\n' \
  > pkg/schema/go.mod
git add -A && git commit -qm gomod-excluded
gr_gate gr-excluded
gate_is "$SANDBOX/gr-excluded.card" replace-directives PASS
expect "a versioned (non-local) replace is not co-development state" \
  gate_detail_has "$SANDBOX/gr-excluded.card" replace-directives 'no local-path replace'
expect "the PASS row states how many go.mod files it parsed" \
  gate_detail_has "$SANDBOX/gr-excluded.card" replace-directives '1 go.mod file'
expect "the PASS row states which parse method produced that evidence" \
  gate_detail_has "$SANDBOX/gr-excluded.card" replace-directives 'go mod edit -json'
gate_is "$SANDBOX/gr-excluded.card" AGGREGATE PASS

# --- an IN-REPO replace target is not co-development state --------------------
# Every template-born go.mod carries `replace …/pkg/schema => ./pkg/schema` (and
# the CLI keeps in-template paths relative). The target resolves inside the
# component root, so CI resolves it too: flagging it asked NEEDS-INPUT on every
# supported component and offered a Drop that unhooks the root from its own
# pkg/schema. reproduced pre-fix: NEEDS-INPUT on this exact tree.
rm -rf vendor .kairos
printf 'module example.com/gatecomp\n\ngo 1.21\n\nrequire example.com/gatecomp/pkg/schema v0.0.0\n\nreplace example.com/gatecomp/pkg/schema => ./pkg/schema\n' > go.mod
printf 'module example.com/gatecomp/pkg/schema\n\ngo 1.21\n' > pkg/schema/go.mod
mkdir -p web/entrypoint
printf 'module example.com/gatecomp/web/entrypoint\n\ngo 1.21\n\nreplace example.com/gatecomp/pkg/schema => ../../pkg/schema\n' > web/entrypoint/go.mod
git add -A && git commit -qm gomod-inrepo
gr_gate gr-inrepo
gate_is "$SANDBOX/gr-inrepo.card" replace-directives PASS
expect "the in-repo PASS still says it found no out-of-repo local-path replace" \
  gate_detail_has "$SANDBOX/gr-inrepo.card" replace-directives 'no local-path replace'
gate_is "$SANDBOX/gr-inrepo.card" AGGREGATE PASS

# --- in-repo + out-of-repo: only the escaping target is flagged ---------------
printf 'module example.com/gatecomp\n\ngo 1.21\n\nreplace (\n\texample.com/gatecomp/pkg/schema => ./pkg/schema\n\texample.com/common => ../x\n)\n' > go.mod
git add -A && git commit -qm gomod-mixed
gr_gate gr-mixed
gate_is "$SANDBOX/gr-mixed.card" replace-directives NEEDS-INPUT
expect "the ../ target outside the component root is flagged" \
  gate_detail_has "$SANDBOX/gr-mixed.card" replace-directives '=> \.\./x'
refute "the in-repo ./pkg/schema target is not part of the question" \
  gate_detail_has "$SANDBOX/gr-mixed.card" replace-directives '=> \./pkg/schema'
expect "the count is the escaping directive alone" \
  gate_detail_has "$SANDBOX/gr-mixed.card" replace-directives '^1 inherited'

# --- a ./ spelling that climbs out of the root is still outside it ------------
printf 'module example.com/gatecomp\n\ngo 1.21\n\nreplace example.com/common => ./pkg/../../x\n' > go.mod
printf 'module example.com/gatecomp/web/entrypoint\n\ngo 1.21\n\nreplace example.com/common => ../../../x\n' > web/entrypoint/go.mod
git add -A && git commit -qm gomod-climb
gr_gate gr-climb
gate_is "$SANDBOX/gr-climb.card" replace-directives NEEDS-INPUT
expect "a ./… target whose .. escapes the root is flagged" \
  gate_detail_has "$SANDBOX/gr-climb.card" replace-directives '\./pkg/\.\./\.\./x'
expect "a nested module's ../ target that escapes the root is flagged" \
  gate_detail_has "$SANDBOX/gr-climb.card" replace-directives 'web/entrypoint/go.mod'

# --- an ABSOLUTE target is flagged even beside an in-repo one -----------------
printf 'module example.com/gatecomp\n\ngo 1.21\n\nreplace example.com/gatecomp/pkg/schema => ./pkg/schema\n\nreplace example.com/common => /home/dev/kairos-component-common\n' > go.mod
printf 'module example.com/gatecomp/web/entrypoint\n\ngo 1.21\n' > web/entrypoint/go.mod
git add -A && git commit -qm gomod-inrepo-abs
gr_gate gr-inrepo-abs
gate_is "$SANDBOX/gr-inrepo-abs.card" replace-directives NEEDS-INPUT
expect "the absolute target is flagged" \
  gate_detail_has "$SANDBOX/gr-inrepo-abs.card" replace-directives '/home/dev/kairos-component-common'
refute "the in-repo target beside it is not" \
  gate_detail_has "$SANDBOX/gr-inrepo-abs.card" replace-directives '=> \./pkg/schema'

# --- a bare `..` or `.` target is a local path too ----------------------------
# Go's modfile.IsDirectoryPath accepts `.` and `..` with no trailing slash.
# reproduced pre-fix: both parsers required `./`, `../` or `/`, so
# `replace example.com/common => ..` (outside the root) was a PASS.
printf 'module example.com/gatecomp\n\ngo 1.21\n\nreplace example.com/common => ..\n' > go.mod
git add -A && git commit -qm gomod-bare-dotdot
gr_gate gr-bare-dotdot
gate_is "$SANDBOX/gr-bare-dotdot.card" replace-directives NEEDS-INPUT
expect "a bare .. target outside the root is flagged" \
  gate_detail_has "$SANDBOX/gr-bare-dotdot.card" replace-directives 'example.com/common => \.\.'
# `..` from a nested module and `.` from the root both resolve inside the root.
printf 'module example.com/gatecomp\n\ngo 1.21\n\nreplace example.com/gatecomp/self => .\n' > go.mod
printf 'module example.com/gatecomp/web/entrypoint\n\ngo 1.21\n\nreplace example.com/gatecomp/web => ..\n' > web/entrypoint/go.mod
git add -A && git commit -qm gomod-bare-inrepo
gr_gate gr-bare-inrepo
gate_is "$SANDBOX/gr-bare-inrepo.card" replace-directives PASS
rm -rf web go.mod

# --- no go.mod anywhere: PASS, and the detail says exactly that ---------------
rm -rf pkg vendor .kairos
git add -A && git commit -qm gomod-none
gr_gate gr-none
gate_is "$SANDBOX/gr-none.card" replace-directives PASS
expect "the nothing-to-check PASS says no go.mod was found" \
  gate_detail_has "$SANDBOX/gr-none.card" replace-directives 'no go.mod under the component root'

# --- with `go` absent from PATH the block-aware fallback still catches it -----
# PATH is rebuilt without any directory carrying a `go` executable; the case is
# skipped rather than faked if that also costs the tools the gate itself needs.
GR_NOGO=""
IFS=: read -r -a GR_PDIRS <<< "$PATH"
for grd in "${GR_PDIRS[@]}"; do
  [[ -n "$grd" ]] || continue
  [[ -x "$grd/go" ]] && continue
  GR_NOGO="${GR_NOGO:+$GR_NOGO:}$grd"
done
if env PATH="$GR_NOGO" command -v go >/dev/null 2>&1 \
   || ! env PATH="$GR_NOGO" command -v git >/dev/null 2>&1 \
   || ! env PATH="$GR_NOGO" command -v awk >/dev/null 2>&1; then
  echo "  skip: 'go' cannot be hidden without losing git/awk — the block-aware fallback arms are not exercised: 15 assertions (block form, CRLF block and line form, quoted tokens, quoted versioned non-finding, quoted in-repo non-finding, bare ..)"
else
  gr_nogo_gate() { # gr_nogo_gate <card-basename> — the same gate with `go` off PATH
    env PATH="$GR_NOGO" LABEL=postmerge RUN=$GRRUN SYNTH=$GRSYN PHASE_KEY=$PK_STRUCTURAL \
      "$(command -v bash)" "$GATE" > "$SANDBOX/$1.card" 2> "$SANDBOX/$1.log"
  }
  cat > go.mod <<'EOF'
module example.com/gatecomp

go 1.21

replace (
	example.com/common => ../kairos-component-common
)
EOF
  git add -A && git commit -qm gomod-fallback
  gr_nogo_gate gr-nogo
  gate_is "$SANDBOX/gr-nogo.card" replace-directives NEEDS-INPUT
  expect "the fallback parse sees the block-form directive too" \
    gate_detail_has "$SANDBOX/gr-nogo.card" replace-directives kairos-component-common
  expect "the row discloses that the fallback parse ran, not go mod edit -json" \
    gate_detail_has "$SANDBOX/gr-nogo.card" replace-directives 'fallback'

  # --- CRLF go.mod: \r must not defeat the block-open match ---------------------
  # reproduced pre-fix: the fallback's trim stripped spaces and tabs but not \r,
  # so on a CRLF go.mod the block-open line `replace (\r` failed the $-anchored
  # match, `blk` never became 1, and every inner directive was skipped as a stray
  # line — a clean PASS over a file carrying a local-path replace. A component
  # edited on Windows is the whole population of this case.
  printf 'module example.com/gatecomp\r\n\r\ngo 1.21\r\n\r\nreplace (\r\n\texample.com/common => ../kairos-component-common\r\n)\r\n' > go.mod
  git add -A && git commit -qm gomod-fallback-crlf
  gr_nogo_gate gr-nogo-crlf
  gate_is "$SANDBOX/gr-nogo-crlf.card" replace-directives NEEDS-INPUT
  expect "the CRLF block-form directive is found by the fallback" \
    gate_detail_has "$SANDBOX/gr-nogo-crlf.card" replace-directives kairos-component-common

  # --- CRLF line form: the reported directive carries no stray \r ---------------
  # The same one-character omission also leaked the \r into the card, so the fix
  # belongs in the trim (which every arm shares) rather than in the block-open
  # regex alone: a regex-only patch leaves this row's detail carrying a control
  # character mid-TSV-field.
  printf 'module example.com/gatecomp\r\n\r\ngo 1.21\r\n\r\nreplace example.com/common => ../kairos-component-common\r\n' > go.mod
  git add -A && git commit -qm gomod-fallback-crlf-line
  gr_nogo_gate gr-nogo-crlfline
  gate_is "$SANDBOX/gr-nogo-crlfline.card" replace-directives NEEDS-INPUT
  refute "the fallback's reported directive carries no carriage return" \
    grep -q $'\r' "$SANDBOX/gr-nogo-crlfline.card"

  # --- quoted tokens: go.mod permits them, so the fallback must see them --------
  # reproduced pre-fix: the find regex required `.` immediately after `=>`, so
  # `"example.com/common" => "../kairos-component-common"` — which
  # `go mod edit -json` reports as New.Path "../kairos-component-common" — was a
  # PASS with `go` off PATH.
  printf 'module example.com/gatecomp\n\ngo 1.21\n\nreplace (\n\t"example.com/common" => "../kairos-component-common"\n)\n' > go.mod
  git add -A && git commit -qm gomod-fallback-quoted
  gr_nogo_gate gr-nogo-quoted
  gate_is "$SANDBOX/gr-nogo-quoted.card" replace-directives NEEDS-INPUT
  expect "the quoted-token directive is found by the fallback" \
    gate_detail_has "$SANDBOX/gr-nogo-quoted.card" replace-directives kairos-component-common

  # --- a quoted VERSIONED replace is still not co-development state -------------
  # The quote-tolerant find regex must not widen into a false positive: the
  # design rule here is that a spurious finding blocks a migration on a
  # non-problem.
  printf 'module example.com/gatecomp\n\ngo 1.21\n\nrequire example.com/common v1.2.3\n\nreplace (\n\t"example.com/common" => "example.com/common" v1.2.4\n)\n' > go.mod
  git add -A && git commit -qm gomod-fallback-quoted-versioned
  gr_nogo_gate gr-nogo-qver
  gate_is "$SANDBOX/gr-nogo-qver.card" replace-directives PASS
  expect "the quoted versioned replace PASS discloses the fallback parse" \
    gate_detail_has "$SANDBOX/gr-nogo-qver.card" replace-directives 'fallback'

  # --- the fallback applies the same inside-the-root rule -----------------------
  printf 'module example.com/gatecomp\n\ngo 1.21\n\nreplace (\n\t"example.com/gatecomp/pkg/schema" => "./pkg/schema"\n\texample.com/common => ../x\n)\n' > go.mod
  git add -A && git commit -qm gomod-fallback-inrepo
  gr_nogo_gate gr-nogo-inrepo
  gate_is "$SANDBOX/gr-nogo-inrepo.card" replace-directives NEEDS-INPUT
  refute "the fallback does not flag the quoted in-repo target" \
    gate_detail_has "$SANDBOX/gr-nogo-inrepo.card" replace-directives 'pkg/schema'

  # --- the fallback sees a bare `..` target, quoted or not ----------------------
  printf 'module example.com/gatecomp\n\ngo 1.21\n\nreplace (\n\texample.com/common => ..\n\t"example.com/other" => ".."\n)\n' > go.mod
  git add -A && git commit -qm gomod-fallback-bare
  gr_nogo_gate gr-nogo-bare
  gate_is "$SANDBOX/gr-nogo-bare.card" replace-directives NEEDS-INPUT
  expect "the fallback counts both bare .. targets" \
    gate_detail_has "$SANDBOX/gr-nogo-bare.card" replace-directives '^2 inherited'
fi

# --- a go.mod neither method can read is gate-internal, never a PASS ----------
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the unreadable-go.mod arm is not exercised: 2 assertions (gate-internal FAIL naming the file, never a PASS)"
else
  printf 'module example.com/gatecomp\n\ngo 1.21\n' > go.mod
  git add -A && git commit -qm gomod-plain
  chmod 000 go.mod
  gr_gate gr-unreadable
  chmod 644 go.mod
  gate_is "$SANDBOX/gr-unreadable.card" replace-directives FAIL
  expect "an unparseable go.mod is gate-internal, naming the file" \
    gate_detail_has "$SANDBOX/gr-unreadable.card" replace-directives 'gate-internal.*go.mod'
  # T6: the candidate-list-unbuildable arm also carries 'gate-internal … go.mod',
  # so pin this arm's OWN distinguishing cause — both parses failed on a listed
  # file — rather than the shared regex a reworded sibling would also satisfy.
  expect "the unparseable-go.mod FAIL names the both-parses-failed cause" \
    gate_detail_has "$SANDBOX/gr-unreadable.card" replace-directives "neither go mod edit -json nor the fallback parse could read"
fi

# --- the go.mod candidate list itself could not be built => gate-internal ------
# A failed listing (find exiting non-zero because part of the tree could not be
# walked) is NOT an empty listing: the module set is unknown, so a PASS over it
# would claim a scan nobody ran. An unreadable subdirectory under the component
# root makes find exit non-zero deterministically; root bypasses the mode bits,
# so the arm is not exercised there.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the unbuildable-candidate-list arm is not exercised: 2 assertions (gate-internal FAIL, its own cause)"
else
  mkdir -p walled-off
  chmod 000 walled-off
  gr_gate gr-badlist
  chmod 755 walled-off
  rmdir walled-off
  gate_is "$SANDBOX/gr-badlist.card" replace-directives FAIL
  expect "the unbuildable-list replace FAIL is gate-internal" \
    gate_detail_has "$SANDBOX/gr-badlist.card" replace-directives gate-internal
  expect "the unbuildable-list replace FAIL names its own cause" \
    gate_detail_has "$SANDBOX/gr-badlist.card" replace-directives "go.mod candidate list could not be built"
fi
cd "$SANDBOX"

# =============================================================================
fi

if t "gate.sh ask-user row — postmerge-only coverage of enacted ask-user decisions"; then
# The classified ask-user set (union of the three ask-user buckets across
# classification.tsv and binaries.txt, de-duped by path) must be fully covered
# by $RUN/ask-user-applied.tsv at the postmerge gate. This row is the only
# mechanism that catches Phase 5 step 4b being skipped entirely — the failure
# mode where a user's "take" evaporates between the question and the commit.
gate_evidence() { awk -F'\t' -v c="$2" '$1==c{print $4}' "$1"; }
GA=$SANDBOX/gate-ask; GARUN=$SANDBOX/gate-ask-run; GASYN=$SANDBOX/gate-ask-synth
mkdir -p "$GA" "$GARUN" "$GASYN"
( cd "$GASYN" && git init -q -b main \
  && printf 'a: 1\n' > config.yaml \
  && git add -A && git commit -qm target && git tag kairos-base && git tag kairos-target )
cd "$GA" && git init -q -b main
printf 'a: 1\n' > config.yaml
git add -A && git commit -qm init
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GARUN/test-command.txt"
: > "$GARUN/test-baseline.failures.txt"
# Three ask-user rows + one non-ask-user row (must be excluded from the set);
# binaries.txt adds one path of its own and duplicates logo.bin (de-dupe by
# path: the classified set is 4 items, never 5).
printf '%s\n' \
  $'binary-for-user\tM\tassets/logo.bin\tassets/logo.bin' \
  $'added-heavyweight-ask-user\tA\tcmd/worker/main.go\tcmd/worker/main.go' \
  $'deleted-heavyweight-ask-user\tD\tlegacy/tool.go\tlegacy/tool.go' \
  $'merge-pipeline\tM\tkept.txt\tkept.txt' \
  > "$GARUN/classification.tsv"
printf '%s\n' 'assets/logo.bin' 'extra/font.bin' > "$GARUN/binaries.txt"
stamp_binding "$GASYN" "$GARUN"

# --- full coverage => PASS with the applied-N-of-N evidence ---
printf '%s\n' \
  $'binary-for-user\tassets/logo.bin\ttheirs\twritten' \
  $'added-heavyweight-ask-user\tcmd/worker/main.go\ttake\twritten' \
  $'deleted-heavyweight-ask-user\tlegacy/tool.go\tkeep\tunchanged' \
  $'binary-for-user\textra/font.bin\tours\tunchanged' \
  > "$GARUN/ask-user-applied.tsv"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-full.card" 2> "$SANDBOX/ga-full.log"
expect "full ask-user coverage passes the postmerge gate (exit 0)" test $? -eq 0
gate_is "$SANDBOX/ga-full.card" ask-user PASS
GA_EV=$(gate_evidence "$SANDBOX/ga-full.card" ask-user)
case "$GA_EV" in
  *"applied 4 of 4 classified"*) pass "the PASS evidence reads applied 4 of 4 classified (binaries.txt path counted, duplicate de-duped)" ;;
  *) fail "the PASS evidence reads applied 4 of 4 classified (got '$GA_EV')" ;;
esac
gate_is "$SANDBOX/ga-full.card" AGGREGATE PASS

# --- a classified item with no applied row => FAIL naming it ---
# The dropped row is the binaries.txt-only path: coverage must span BOTH
# sources of the union, not classification.tsv alone.
printf '%s\n' \
  $'binary-for-user\tassets/logo.bin\ttheirs\twritten' \
  $'added-heavyweight-ask-user\tcmd/worker/main.go\ttake\twritten' \
  $'deleted-heavyweight-ask-user\tlegacy/tool.go\tkeep\tunchanged' \
  > "$GARUN/ask-user-applied.tsv"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-miss.card" 2> "$SANDBOX/ga-miss.log"
GA_M_RC=$?
if [[ "$GA_M_RC" -ne 0 ]]; then pass "a classified item with no applied row fails the gate"; else fail "a missing applied row passed the gate"; fi
gate_is "$SANDBOX/ga-miss.card" ask-user FAIL
expect "the FAIL counts the uncovered items (1 of 4)" \
  gate_detail_has "$SANDBOX/ga-miss.card" ask-user "1 of 4"
expect "the FAIL names the uncovered binaries.txt path" \
  gate_detail_has "$SANDBOX/ga-miss.card" ask-user extra/font.bin
refute "the coverage FAIL is not blamed on the gate itself" \
  gate_detail_has "$SANDBOX/ga-miss.card" ask-user gate-internal
gate_is "$SANDBOX/ga-miss.card" AGGREGATE FAIL

# --- a rename-flavored (two-field) binaries.txt row: field 1 is the coverage
# item; field 2 (the pre-rename old path) is enactment metadata for
# apply-ask-user.sh and must never become a coverage item of its own ---
printf '%s\n' 'assets/logo.bin' 'extra/font.bin' \
  $'renamed/logo2.bin\told/logo2.bin' > "$GARUN/binaries.txt"
printf '%s\n' \
  $'binary-for-user\tassets/logo.bin\ttheirs\twritten' \
  $'added-heavyweight-ask-user\tcmd/worker/main.go\ttake\twritten' \
  $'deleted-heavyweight-ask-user\tlegacy/tool.go\tkeep\tunchanged' \
  $'binary-for-user\textra/font.bin\tours\tunchanged' \
  $'binary-for-user\trenamed/logo2.bin\ttheirs\twritten' \
  > "$GARUN/ask-user-applied.tsv"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-2field.card" 2> "$SANDBOX/ga-2field.log"
expect "full coverage including a two-field binaries row passes (exit 0)" test $? -eq 0
gate_is "$SANDBOX/ga-2field.card" ask-user PASS
GA_2F_EV=$(gate_evidence "$SANDBOX/ga-2field.card" ask-user)
case "$GA_2F_EV" in
  *"applied 5 of 5 classified"*) pass "the two-field row counts once, keyed by its field-1 path (5 of 5)" ;;
  *) fail "the two-field row counts once, keyed by its field-1 path (got '$GA_2F_EV')" ;;
esac
# No applied row names old/logo2.bin and the gate PASSed above — the old path
# was never demanded. Assert the card doesn't mention it anywhere either.
refute "the pre-rename old path is not a coverage item" \
  gate_detail_has "$SANDBOX/ga-2field.card" ask-user old/logo2.bin
# Restore the one-field fixture the sub-cases below were written against.
printf '%s\n' 'assets/logo.bin' 'extra/font.bin' > "$GARUN/binaries.txt"

# --- applied file missing while classified items exist => FAIL: gate-internal ---
# This is today's bug made visible: step 4b skipped entirely, nothing enacted.
rm -f "$GARUN/ask-user-applied.tsv"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-noapplied.card" 2> "$SANDBOX/ga-noapplied.log"
GA_NA_RC=$?
if [[ "$GA_NA_RC" -ne 0 ]]; then pass "a missing applied file with classified items fails the gate"; else fail "a skipped enactment step passed the gate"; fi
gate_is "$SANDBOX/ga-noapplied.card" ask-user FAIL
expect "the missing-applied-file FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/ga-noapplied.card" ask-user gate-internal
expect "the FAIL points at apply-ask-user.sh" \
  gate_detail_has "$SANDBOX/ga-noapplied.card" ask-user apply-ask-user
gate_is "$SANDBOX/ga-noapplied.card" AGGREGATE FAIL

# --- unparseable applied rows => FAIL: gate-internal, never trusted coverage ---
printf 'binary-for-user\tassets/logo.bin\ttheirs\tGREENISH\n' > "$GARUN/ask-user-applied.tsv"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-badrow.card" 2> "$SANDBOX/ga-badrow.log"
if [[ $? -ne 0 ]]; then pass "an unrecognized outcome in an applied row fails the gate"; else fail "an unparseable applied row passed the gate"; fi
gate_is "$SANDBOX/ga-badrow.card" ask-user FAIL
expect "the unparseable-row FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/ga-badrow.card" ask-user gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the unparseable-row FAIL names the expected applied-row shape" \
  gate_detail_has "$SANDBOX/ga-badrow.card" ask-user "want bucket"

# --- the row exists at postmerge ONLY: absent at midplan and final ---
# The worst case rides along: classified items exist and NO applied file — a
# state that fails postmerge — yet midplan and final must not even ask the
# question, because a plan task may legitimately revert an applied item.
rm -f "$GARUN/ask-user-applied.tsv"
LABEL=midplan RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_EXECUTION "$GATE" \
  > "$SANDBOX/ga-mid.card" 2> "$SANDBOX/ga-mid.log"
expect "midplan passes despite the missing applied file (exit 0)" test $? -eq 0
refute "no ask-user row under LABEL=midplan" \
  gate_row_present "$SANDBOX/ga-mid.card" ask-user
LABEL=final RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/ga-fin.card" 2> "$SANDBOX/ga-fin.log"
expect "final passes despite the missing applied file (exit 0)" test $? -eq 0
refute "no ask-user row under LABEL=final" \
  gate_row_present "$SANDBOX/ga-fin.card" ask-user

# --- zero classified items => PASS with evidence, never INCOMPLETE ---
# The applied file may not even exist: with nothing classified, nothing owes a
# row — mirroring the marker check's empty-candidate-list precedent.
printf $'merge-pipeline\tM\tkept.txt\tkept.txt\n' > "$GARUN/classification.tsv"
rm -f "$GARUN/binaries.txt" "$GARUN/ask-user-applied.tsv"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-zero.card" 2> "$SANDBOX/ga-zero.log"
expect "zero classified ask-user items pass the postmerge gate (exit 0)" test $? -eq 0
gate_is "$SANDBOX/ga-zero.card" ask-user PASS
GA_Z_EV=$(gate_evidence "$SANDBOX/ga-zero.card" ask-user)
case "$GA_Z_EV" in
  *"0 of 0 classified"*) pass "the zero-classified PASS carries the 0-of-0 evidence" ;;
  *) fail "the zero-classified PASS carries the 0-of-0 evidence (got '$GA_Z_EV')" ;;
esac
refute "zero classified items is never reported gate-internal" \
  gate_detail_has "$SANDBOX/ga-zero.card" ask-user gate-internal
gate_is "$SANDBOX/ga-zero.card" AGGREGATE PASS

# --- classification.tsv itself missing => FAIL: gate-internal, fail-closed ---
# Without the classified set the coverage question cannot even be posed; the
# row must fail closed rather than read "no set" as "nothing classified".
rm -f "$GARUN/classification.tsv"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-nocls.card" 2> "$SANDBOX/ga-nocls.log"
GA_NC_RC=$?
if [[ "$GA_NC_RC" -ne 0 ]]; then pass "a missing classification.tsv fails the postmerge gate"; else fail "a missing classification.tsv passed the gate"; fi
gate_is "$SANDBOX/ga-nocls.card" ask-user FAIL
expect "the missing-classification FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/ga-nocls.card" ask-user gate-internal
expect "the FAIL points at build-manifest.sh" \
  gate_detail_has "$SANDBOX/ga-nocls.card" ask-user build-manifest
# T6: build-manifest.sh is named by the AUCT-missing arm too, so pin the OWN
# distinguishing cause — a reworded arm must not drift to that sibling unnoticed.
expect "the missing-classification FAIL names its own distinguishing cause" \
  gate_detail_has "$SANDBOX/ga-nocls.card" ask-user "classification.tsv missing or unreadable"

# --- the classification must be bound to the trees $SYNTH holds now -------------
# structural-merge.sh refuses a classification whose synthetic-tree stamp no
# longer matches $SYNTH; this row consumes the same file for its coverage tally
# and used to do so with no binding check at all — a $SYNTH re-materialized after
# Phase 3 left the gate auditing a stale set and reporting PASS on it. Restore a
# full-coverage state first, so the only variable below is the stamp.
printf '%s\n' \
  $'binary-for-user\tM\tassets/logo.bin\tassets/logo.bin' \
  $'added-heavyweight-ask-user\tA\tcmd/worker/main.go\tcmd/worker/main.go' \
  $'deleted-heavyweight-ask-user\tD\tlegacy/tool.go\tlegacy/tool.go' \
  $'merge-pipeline\tM\tkept.txt\tkept.txt' \
  > "$GARUN/classification.tsv"
printf '%s\n' 'assets/logo.bin' 'extra/font.bin' > "$GARUN/binaries.txt"
printf '%s\n' \
  $'binary-for-user\tassets/logo.bin\ttheirs\twritten' \
  $'added-heavyweight-ask-user\tcmd/worker/main.go\ttake\twritten' \
  $'deleted-heavyweight-ask-user\tlegacy/tool.go\tkeep\tunchanged' \
  $'binary-for-user\textra/font.bin\tours\tunchanged' \
  > "$GARUN/ask-user-applied.tsv"

# A stamp naming other trees (here the empty tree, a real oid no fixture tree can
# equal) is the re-materialized-$SYNTH case: refuse, don't tally.
GA_STALE_TREE=$(git -C "$GASYN" mktree </dev/null)
printf 'base\t%s\ntarget\t%s\n' "$GA_STALE_TREE" "$GA_STALE_TREE" \
  > "$GARUN/classification-trees.tsv"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-stale.card" 2> "$SANDBOX/ga-stale.log"
GA_ST_RC=$?
if [[ "$GA_ST_RC" -ne 0 ]]; then
  pass "a classification bound to other trees fails the postmerge gate"
else
  fail "a stale classification passed the postmerge gate"
fi
gate_is "$SANDBOX/ga-stale.card" ask-user FAIL
expect "the stale-binding FAIL says the classification describes other trees" \
  gate_detail_has "$SANDBOX/ga-stale.card" ask-user "derived from other synthetic trees"
GA_ST_EV=$(gate_evidence "$SANDBOX/ga-stale.card" ask-user)
case "$GA_ST_EV" in
  *classification-trees.tsv*) pass "the stale-binding FAIL points at the binding file" ;;
  *) fail "the stale-binding FAIL points at the binding file (got '$GA_ST_EV')" ;;
esac
expect "the stale-binding FAIL carries the re-run-Phase-3 remedy" \
  gate_detail_has "$SANDBOX/ga-stale.card" ask-user build-manifest
refute "a stale binding is never reported as full coverage" \
  gate_detail_has "$SANDBOX/ga-stale.card" ask-user "applied 4 of 4"
gate_is "$SANDBOX/ga-stale.card" AGGREGATE FAIL

# No stamp at all cannot be verified either — and structural-merge.sh refuses to
# run without one, so at postmerge its absence means the tally is unverifiable.
rm -f "$GARUN/classification-trees.tsv"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-nostamp.card" 2> "$SANDBOX/ga-nostamp.log"
if [[ $? -ne 0 ]]; then
  pass "an unstamped classification fails the postmerge gate"
else
  fail "an unstamped classification passed the postmerge gate"
fi
gate_is "$SANDBOX/ga-nostamp.card" ask-user FAIL
expect "the unstamped FAIL names the missing binding file" \
  gate_detail_has "$SANDBOX/ga-nostamp.card" ask-user "classification-trees.tsv"
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the unstamped FAIL names the no-binding cause" \
  gate_detail_has "$SANDBOX/ga-nostamp.card" ask-user "carries no synthetic-tree binding"

# The matching stamp leaves the row exactly as it was: full coverage still PASSes
# with its applied-N-of-N evidence.
stamp_binding "$GASYN" "$GARUN"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-bound.card" 2> "$SANDBOX/ga-bound.log"
expect "a matching stamp restores the unchanged pass (exit 0)" test $? -eq 0
gate_is "$SANDBOX/ga-bound.card" ask-user PASS
GA_B_EV=$(gate_evidence "$SANDBOX/ga-bound.card" ask-user)
case "$GA_B_EV" in
  *"applied 4 of 4 classified"*) pass "the bound PASS still carries the applied-N-of-N evidence" ;;
  *) fail "the bound PASS still carries the applied-N-of-N evidence (got '$GA_B_EV')" ;;
esac
case "$GA_B_EV" in
  *binding*) pass "the bound PASS records that the binding was verified" ;;
  *) fail "the bound PASS records that the binding was verified (got '$GA_B_EV')" ;;
esac

# $SYNTH gone (an operator cleaned it up after Phase 5) cannot be checked either
# way: incomplete coverage, never a silent PASS — and never a block, because the
# gate's own contract makes $SYNTH optional.
LABEL=postmerge RUN=$GARUN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-nosynth.card" 2> "$SANDBOX/ga-nosynth.log"
expect "an unset \$SYNTH does not block the postmerge gate (exit 0)" test $? -eq 0
gate_is "$SANDBOX/ga-nosynth.card" ask-user INCOMPLETE
expect "the unverifiable-binding row says the binding could not be checked" \
  gate_detail_has "$SANDBOX/ga-nosynth.card" ask-user "could not be verified"
GA_NS_ST=$(gate_status "$SANDBOX/ga-nosynth.card" ask-user)
if [[ "$GA_NS_ST" != PASS ]]; then
  pass "an unverifiable binding is never rounded up to PASS"
else
  fail "an unverifiable binding was rounded up to PASS"
fi

# --- an empty-first-field binaries.txt row is DROPPED, exactly as the enactor
# drops it (gate.sh's classified set mirrors apply-ask-user.sh:257's union) ------
# A row whose first TAB field is empty is malformed; apply-ask-user.sh never
# classifies it (its union is `-F'\t' NF && $1 != ""`), so the gate must not
# either — otherwise it demands an applied row for a phantom empty path and a
# fully-enacted migration fails coverage. Before gate.sh's union carried the same
# -F'\t' / $1 != "" guard, its default-FS `NF` kept the row and counted the empty
# path as a second, uncovered item.
: > "$GARUN/classification.tsv"                 # classified set comes from binaries.txt alone
printf '%s\n' 'assets/logo.bin' $'\torphan-old-path' > "$GARUN/binaries.txt"
printf '%s\n' $'binary-for-user\tassets/logo.bin\ttheirs\twritten' > "$GARUN/ask-user-applied.tsv"
stamp_binding "$GASYN" "$GARUN"
LABEL=postmerge RUN=$GARUN SYNTH=$GASYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/ga-emptyfield.card" 2> "$SANDBOX/ga-emptyfield.log"
expect "an empty-first-field binaries row does not demand an applied row (exit 0)" test $? -eq 0
gate_is "$SANDBOX/ga-emptyfield.card" ask-user PASS
GA_EF_EV=$(gate_evidence "$SANDBOX/ga-emptyfield.card" ask-user)
case "$GA_EF_EV" in
  *"applied 1 of 1 classified"*) pass "only the well-formed binaries row is a coverage item (1 of 1)" ;;
  *) fail "only the well-formed binaries row is a coverage item (got '$GA_EF_EV')" ;;
esac
refute "the empty-first-field row is never demanded as an uncovered item" \
  gate_detail_has "$SANDBOX/ga-emptyfield.card" ask-user "have no applied row"

cd "$SANDBOX"

# =============================================================================
fi

if t "gate.sh fail-closed — corrupted artifacts land on FAIL: gate-internal, never PASS"; then
# gate.sh may only emit PASS on positive parsed evidence. These stubs corrupt the
# underlying check's artifacts (missing status file, unrecognized status string,
# empty extracted failure set on a non-zero exit); each must map to
# FAIL: gate-internal — a false FAIL is visible and safe, a false PASS advances
# a broken baseline. gate.sh resolves its sibling scripts via dirname, so a copy
# beside stubbed siblings exercises the real script against corrupted inputs.
GS=$SANDBOX/gate-stubs
mkdir -p "$GS"
cp "$SKILL_DIR/scripts/gate.sh" "$GS/gate.sh"
cat > "$GS/yaml-gate.sh" <<'EOF'
#!/usr/bin/env bash
: > "$RUN/yaml-gate-$LABEL.tsv"
exit 0
EOF
cat > "$GS/producer-idempotence.sh" <<'EOF'
#!/usr/bin/env bash
# The verdict file is per gate LABEL, and gate.sh is what passes the label down —
# a stub writing the old unlabelled name would make the gate report the row
# missing.
printf 'build\tclean\tproducer left tracked state clean\n' > "$RUN/producer-idempotence-$LABEL.tsv"
exit 0
EOF
cat > "$GS/run-check-modules.sh" <<'EOF'
#!/usr/bin/env bash
MODE=$(cat "$GATE_STUB_MODE_FILE")
case "$MODE" in
  no-status)          exit 1 ;;
  weird-status)       echo GREENISH > "$OUT.status"; exit 0 ;;
  fail-empty-extract) echo FAIL > "$OUT.status"; : > "$OUT.failures.txt"; exit 1 ;;
  fail-comm-breaks)   echo FAIL > "$OUT.status"; mkdir -p "$OUT.failures.txt"; exit 1 ;;
  ok-no-failures)     echo OK > "$OUT.status"; exit 0 ;;
  ok-inconsistent)    echo OK > "$OUT.status"; printf 'TestGhost\n' > "$OUT.failures.txt"; exit 0 ;;
esac
EOF
chmod +x "$GS"/*.sh
GSC=$SANDBOX/gate-stub-comp; GSRUN=$SANDBOX/gate-stub-run
mkdir -p "$GSC" "$GSRUN"
printf '%s\n' 'run the suite' "grep '^FAILID ' | awk '{print \$2}'" 'run the build' 'no regen command' \
  > "$GSRUN/test-command.txt"
printf 'TestAlpha\n' > "$GSRUN/test-baseline.failures.txt"
: > "$GSRUN/classification.tsv"

gs_run() { # gs_run <mode> <card>
  rm -rf "$GSRUN"/build-postmerge.* "$GSRUN"/test-postmerge.*
  echo "$1" > "$GS/mode"
  ( cd "$GSC" && GATE_STUB_MODE_FILE="$GS/mode" LABEL=postmerge RUN=$GSRUN \
      PHASE_KEY=$PK_STRUCTURAL "$GS/gate.sh" ) > "$2" 2> "$2.log"
}

gs_run no-status "$SANDBOX/gs-nostatus.card"
GS_RC=$?
if [[ "$GS_RC" -ne 0 ]]; then pass "a missing status file fails the gate"; else fail "a missing status file passed the gate"; fi
gate_is "$SANDBOX/gs-nostatus.card" build FAIL
gate_is "$SANDBOX/gs-nostatus.card" tests FAIL
expect "the missing-status FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gs-nostatus.card" build gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the missing-status FAIL names the build-check cause" \
  gate_detail_has "$SANDBOX/gs-nostatus.card" build "missing after the build check ran"
expect "the missing-status FAIL names the test-check cause" \
  gate_detail_has "$SANDBOX/gs-nostatus.card" tests "missing after the test check ran"
gate_is "$SANDBOX/gs-nostatus.card" AGGREGATE FAIL

gs_run weird-status "$SANDBOX/gs-weird.card"
if [[ $? -ne 0 ]]; then pass "an unrecognized status string fails the gate"; else fail "an unrecognized status string passed the gate"; fi
gate_is "$SANDBOX/gs-weird.card" build FAIL
expect "the unrecognized-status FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gs-weird.card" build gate-internal
expect "the unrecognized-status FAIL names the stray value" \
  gate_detail_has "$SANDBOX/gs-weird.card" build GREENISH

gs_run fail-empty-extract "$SANDBOX/gs-empty.card"
if [[ $? -ne 0 ]]; then pass "an empty extracted failure set on a non-zero exit fails the gate"; else fail "extractor silence with a FAIL status passed the gate"; fi
gate_is "$SANDBOX/gs-empty.card" tests FAIL
expect "the empty-extract FAIL is gate-internal (never read as red-on-red)" \
  gate_detail_has "$SANDBOX/gs-empty.card" tests gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the empty-extract FAIL names the extractor-silence cause" \
  gate_detail_has "$SANDBOX/gs-empty.card" tests "extractor silence, not a comparable red suite"
GS_EMPTY_ST=$(gate_status "$SANDBOX/gs-empty.card" tests)
if [[ "$GS_EMPTY_ST" != PASS ]]; then
  pass "an empty comm against the baseline is never rounded up to PASS"
else
  fail "an empty comm against the baseline was rounded up to PASS"
fi

# A comm that itself dies (here: the failure-set artifact is a directory) must
# surface as gate-internal — a swallowed comm failure with empty output is
# byte-identical to "no new failures" and used to take the red-on-red PASS arm.
gs_run fail-comm-breaks "$SANDBOX/gs-commfail.card"
if [[ $? -ne 0 ]]; then pass "a failing comm comparison fails the gate"; else fail "a failing comm comparison passed the gate"; fi
gate_is "$SANDBOX/gs-commfail.card" tests FAIL
expect "the comm-failure FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gs-commfail.card" tests gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the comm-failure FAIL names the never-compared cause" \
  gate_detail_has "$SANDBOX/gs-commfail.card" tests "the failure sets were never compared"
refute "a failing comm is never read as red-on-red" \
  gate_detail_has "$SANDBOX/gs-commfail.card" tests red-on-red
GS_COMM_ST=$(gate_status "$SANDBOX/gs-commfail.card" tests)
if [[ "$GS_COMM_ST" != PASS ]]; then
  pass "a failing comm is never rounded up to PASS"
else
  fail "a failing comm was rounded up to PASS"
fi

# T6: status OK with the failure set never written — a green status wearing no
# evidence; the extractor did not run, and OK must not be taken on its word.
gs_run ok-no-failures "$SANDBOX/gs-oknofail.card"
if [[ $? -ne 0 ]]; then pass "status OK without an extracted failure set fails the gate"; else fail "status OK without an extracted failure set passed the gate"; fi
gate_is "$SANDBOX/gs-oknofail.card" tests FAIL
expect "the OK-without-failures FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gs-oknofail.card" tests gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the OK-without-failures FAIL names the extractor-never-ran cause" \
  gate_detail_has "$SANDBOX/gs-oknofail.card" tests "was never written — the extractor did not run"

# T6: status OK yet the extracted set carries an ID the baseline lacks — the
# artifacts contradict each other; a green status never outranks the evidence.
gs_run ok-inconsistent "$SANDBOX/gs-okincons.card"
if [[ $? -ne 0 ]]; then pass "status OK with failure IDs absent from the baseline fails the gate"; else fail "status OK with new failure IDs passed the gate"; fi
gate_is "$SANDBOX/gs-okincons.card" tests FAIL
expect "the OK-inconsistent FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gs-okincons.card" tests gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the OK-inconsistent FAIL names the inconsistent-artifacts cause" \
  gate_detail_has "$SANDBOX/gs-okincons.card" tests "IDs absent from the baseline — inconsistent artifacts"

# T6: the ask-user derivation failure — classification.tsv is a readable file (so
# the missing-or-unreadable arm above it stays quiet) but the union build itself
# dies mid-derivation: binaries.txt passes the -f existence check yet cannot be
# opened, the awk over it fails, and the coverage compare never ran. That must be
# a loud gate-internal FAIL, never read as "0 of 0 classified".
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the ask-user derivation-failure arm is not exercised: 3 assertions (gate-internal FAIL naming the never-derived cause)"
else
  printf 'ask-user\tM\tconfig/app.yaml\tconfig/app.yaml\n' > "$GSRUN/classification.tsv"
  : > "$GSRUN/binaries.txt"
  chmod 000 "$GSRUN/binaries.txt"
  gs_run ok-no-failures "$SANDBOX/gs-auderive.card"
  gate_is "$SANDBOX/gs-auderive.card" ask-user FAIL
  expect "the derivation FAIL is gate-internal" \
    gate_detail_has "$SANDBOX/gs-auderive.card" ask-user gate-internal
  # T6: pinned by the arm's own wording, not only the shared gate-internal token.
  expect "the derivation FAIL names the never-derived cause" \
    gate_detail_has "$SANDBOX/gs-auderive.card" ask-user "could not be derived from"
  chmod 644 "$GSRUN/binaries.txt" && rm -f "$GSRUN/binaries.txt"
  : > "$GSRUN/classification.tsv"
fi

# --- a drifted rejection comment on the extractor line is not an extractor ---
# Lines 1 and 3 already guard against " # rejected: …" drifting onto a
# positional line; line 2 needs the same guard or the comment reaches eval as
# a shell comment producing an empty (vacuously quiet) extraction.
printf '%s\n' 'echo ALLPASS' ' # rejected: grep FAIL' 'echo compiled' 'no regen command' \
  > "$GTRUN/test-command.txt"
( cd "$GT" && LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" ) \
  > "$SANDBOX/gc-drift.card" 2>/dev/null
if [[ $? -ne 0 ]]; then pass "a drifted comment on the extractor line fails the gate"; else fail "a drifted comment on the extractor line passed the gate"; fi
gate_is "$SANDBOX/gc-drift.card" tests FAIL
expect "the drifted-extractor FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gc-drift.card" tests gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the drifted-extractor FAIL names the missing-extractor cause" \
  gate_detail_has "$SANDBOX/gc-drift.card" tests "carries no extractor, or a drifted rejection comment"

# --- stale per-module artifacts from a previous run are cleared up front ---
# run-check-modules.sh reads back per-module stems ($OUT.<slug>.status …) the
# gate itself never wrote; a leftover one from an earlier invocation must not
# be able to fill a crashed module runner's gap with last time's verdict.
printf 'OK\n' > "$GTRUN/test-postmerge.ghost_module.status"
printf 'TestGhost\n' > "$GTRUN/test-postmerge.ghost_module.failures.txt"
printf 'OK\n' > "$GTRUN/build-postmerge.ghost_module.status"
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' \
  > "$GTRUN/test-command.txt"
: > "$GTRUN/test-baseline.failures.txt"
( cd "$GT" && LABEL=postmerge RUN=$GTRUN SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" ) \
  > "$SANDBOX/gc-stale-mod.card" 2>/dev/null || true
# Row-level assertions, not the aggregate: an earlier matrix case leaves a
# replace directive in this fixture's go.mod (NEEDS-INPUT by design), which is
# unrelated to the staleness rule under test.
gate_is "$SANDBOX/gc-stale-mod.card" build PASS
gate_is "$SANDBOX/gc-stale-mod.card" tests PASS
refute "stale per-module TEST artifacts are cleared before the check runs" \
  bash -c "ls '$GTRUN'/test-postmerge.ghost_module.* 2>/dev/null | grep -q ."
refute "stale per-module BUILD artifacts are cleared before the check runs" \
  bash -c "ls '$GTRUN'/build-postmerge.ghost_module.* 2>/dev/null | grep -q ."

# --- a stale verdict card never survives into a new run ---
# The card is written only on completion; a re-run interrupted mid-flight must
# leave NO card — never the previous invocation's AGGREGATE PASS describing a
# tree this run never checked. Interruption is simulated by killing the gate
# while its build check sleeps; the isolated RUN dir keeps the orphaned
# runner's late artifacts away from every other fixture.
#
# SYNCHRONIZATION is on a marker the fixture's own build command writes, not on a
# fixed sleep. The kill has to land inside a window — after gate.sh removed the stale
# card (its first act, before any check) and before it finishes and writes a new one —
# and a `sleep <n>` only GUESSES at that window: too short and a loaded box fails a
# green tree while the card is still legitimately the previous run's. `touch` in front
# of the build command's own sleep makes the window observable instead: the marker can
# only appear once run-check.sh eval'd this command, which is strictly after the
# removal. The marker lives OUTSIDE $GTINT so it cannot collide with the
# `rm -f "$BOUT".*` stale-artifact sweep that the same build check performs.
#
# The gate is launched in ITS OWN process group (`set -m`) and killed with
# `kill -- -<pgid>`, so the whole tree — gate.sh, run-check-modules.sh, run-check.sh
# and the `sleep` itself — is reaped at once. Killing only $GC_INT_PID left the
# sibling scripts and the `sleep` running as orphans, and where killing the launching
# subshell did not propagate to gate.sh the shell then blocked in `wait` for the
# full sleep — the whole point of the sleep's idle showing up as wall time. With the
# group reaped, nothing survives the kill, so the sleep is a plain liveness
# upper-bound (kept generous so that IF the group-kill ever degrades to the plain-kill
# fallback and gate.sh outlives its parent, the build is still mid-sleep — no card
# written yet — when the assertion runs) that costs no wall time in the normal path.
# 987 is distinctive so the reap can be asserted below.
GTINT=$SANDBOX/gate-run-interrupt
GTINT_STARTED=$SANDBOX/gate-run-interrupt.started
mkdir -p "$GTINT"
rm -f "$GTINT_STARTED"
printf 'stale\tPASS\tfrom a previous run\t-\nAGGREGATE\tPASS\n' > "$GTINT/gate-postmerge.tsv"
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" "touch '$GTINT_STARTED' && sleep 987" 'no regen command' \
  > "$GTINT/test-command.txt"
: > "$GTINT/test-baseline.failures.txt"
set -m
( cd "$GT" && LABEL=postmerge RUN=$GTINT SYNTH=$GTSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" ) \
  > /dev/null 2>&1 &
GC_INT_PID=$!
set +m
# Bounded poll (~20s ceiling) that also gives up the moment the gate is no longer
# running: a gate that died before reaching the build command must report that in a
# second, not hang the suite until the ceiling.
GC_INT_TRIES=0
while [[ ! -e "$GTINT_STARTED" ]] && kill -0 "$GC_INT_PID" 2>/dev/null \
      && [[ "$GC_INT_TRIES" -lt 400 ]]; do
  sleep 0.05
  GC_INT_TRIES=$((GC_INT_TRIES + 1))
done
# Non-vacuity of the interrupt: killing a gate that never got past its own argument
# validation would satisfy the assertion below for the wrong reason.
if [[ -e "$GTINT_STARTED" ]]; then
  pass "the interrupted-gate fixture reaches its build command, so the kill lands mid-flight"
else
  fail "the interrupted-gate fixture never reached its build command — the interrupt below proves nothing"
fi
kill -- -"$GC_INT_PID" 2>/dev/null || kill "$GC_INT_PID" 2>/dev/null
wait "$GC_INT_PID" 2>/dev/null
refute "an interrupted gate re-run leaves no stale card behind (removed at start)" \
  test -e "$GTINT/gate-postmerge.tsv"
# The group-kill reaped the whole tree, so no `sleep 987` (nor its parent scripts)
# lingers to tax teardown or a later `wait`: that lingering child, not the sleep's
# duration, is the idle the fixed sleep used to contribute.
sleep 0.2
# The [s]leep bracket keeps this probe from matching its own argv.
refute "the group-kill reaps the gate's whole process tree (no orphaned sleep lingers)" \
  bash -c "pgrep -f '[s]leep 987' >/dev/null 2>&1"

# =============================================================================
fi

if t "gate.sh producer verdict set — producer-failed is a finding, not gate-internal"; then
# A producer that exits non-zero still classifies and restores and records the
# verdict `producer-failed`. The gate must map that string to a clean FAIL naming
# the producer; landing it on the unrecognized-verdict arm would report
# "gate-internal" and hide what actually failed. The verdict row is fixtured
# here, so this asserts gate.sh's recognized set on its own.
GPF=$SANDBOX/gate-prodfail; GPFRUN=$SANDBOX/gate-prodfail-run; GPFS=$SANDBOX/gate-prodfail-stubs
mkdir -p "$GPF" "$GPFRUN" "$GPFS"
cp "$SKILL_DIR/scripts/gate.sh" "$GPFS/gate.sh"
cat > "$GPFS/yaml-gate.sh" <<'EOF'
#!/usr/bin/env bash
: > "$RUN/yaml-gate-$LABEL.tsv"
exit 0
EOF
cat > "$GPFS/run-check-modules.sh" <<'EOF'
#!/usr/bin/env bash
echo OK > "$OUT.status"
: > "$OUT.failures.txt"
exit 0
EOF
cat > "$GPFS/producer-idempotence.sh" <<'EOF'
#!/usr/bin/env bash
# The sentinel __nofile__ leaves the per-label verdict artifact unwritten (the
# runner died before recording) while still exiting non-zero, so gate.sh must
# read the gap as a missing file rather than last run's verdict.
V=$(cat "$GATE_PROD_VERDICT_FILE")
[ "$V" = __nofile__ ] && exit 1
printf 'build\t%s\tgo build ./... exited 2; restored 1 tracked file, removed 0 untracked\n' \
  "$V" > "$RUN/producer-idempotence-$LABEL.tsv"
exit 1
EOF
chmod +x "$GPFS"/*.sh
printf '%s\n' 'run the suite' "grep '^FAILID ' | awk '{print \$2}'" 'run the build' 'no regen command' \
  > "$GPFRUN/test-command.txt"
: > "$GPFRUN/test-baseline.failures.txt"
: > "$GPFRUN/classification.tsv"

gpf_run() { # gpf_run <verdict> <card>
  echo "$1" > "$GPFS/verdict"
  ( cd "$GPF" && GATE_PROD_VERDICT_FILE="$GPFS/verdict" LABEL=postmerge RUN=$GPFRUN \
      PHASE_KEY=$PK_STRUCTURAL "$GPFS/gate.sh" ) > "$2" 2> "$2.log"
}

gpf_run producer-failed "$SANDBOX/gp-failed.card"
GPF_RC=$?
if [[ "$GPF_RC" -ne 0 ]]; then pass "a producer-failed verdict fails the gate"; else fail "a producer-failed verdict passed the gate"; fi
gate_is "$SANDBOX/gp-failed.card" producer-idempotence FAIL
expect "the producer-failed FAIL names the verdict" \
  gate_detail_has "$SANDBOX/gp-failed.card" producer-idempotence producer-failed
expect "the producer-failed FAIL names the producer" \
  gate_detail_has "$SANDBOX/gp-failed.card" producer-idempotence build
refute "producer-failed is a recognized verdict, never gate-internal" \
  gate_detail_has "$SANDBOX/gp-failed.card" producer-idempotence gate-internal
gate_is "$SANDBOX/gp-failed.card" AGGREGATE FAIL

# The control: a verdict the script does NOT recognize still lands on
# gate-internal, so the row above is a recognized-set membership result and not
# a blanket "any non-clean verdict reads as a finding".
gpf_run GREENISH "$SANDBOX/gp-odd.card"
if [[ $? -ne 0 ]]; then pass "an unrecognized producer verdict still fails the gate"; else fail "an unrecognized producer verdict passed the gate"; fi
gate_is "$SANDBOX/gp-odd.card" producer-idempotence FAIL
expect "an unrecognized producer verdict is gate-internal" \
  gate_detail_has "$SANDBOX/gp-odd.card" producer-idempotence gate-internal
# T6: pinned by the arm's own wording, not only the shared gate-internal token.
expect "the unrecognized-verdict FAIL names its own cause" \
  gate_detail_has "$SANDBOX/gp-odd.card" producer-idempotence "unrecognized verdict"

# --- the per-label verdict artifact never landed => gate-internal --------------
# The runner exited non-zero without recording its verdict file; the gap must
# read as a missing file, worded for its own cause, never last run's verdict or a
# silent PASS. The stale artifact from the run above is cleared first so the
# absence is the only variable.
rm -f "$GPFRUN"/producer-idempotence-*.tsv
gpf_run __nofile__ "$SANDBOX/gp-nofile.card"
if [[ $? -ne 0 ]]; then pass "a missing producer verdict file fails the gate"; else fail "a missing producer verdict file passed the gate"; fi
gate_is "$SANDBOX/gp-nofile.card" producer-idempotence FAIL
expect "the missing-verdict-file FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gp-nofile.card" producer-idempotence gate-internal
expect "the missing-verdict-file FAIL names its own cause" \
  gate_detail_has "$SANDBOX/gp-nofile.card" producer-idempotence "missing after the producer check ran"

# --- a non-zero producer exit carrying only clean rows => gate-internal --------
# No finding row and no unrecognized verdict, yet the check exited non-zero: an
# inconsistent artifact set, worded for its own cause rather than folded into the
# unrecognized-verdict or missing-file arms.
gpf_run clean "$SANDBOX/gp-nofind.card"
if [[ $? -ne 0 ]]; then pass "a non-zero producer exit with no finding row fails the gate"; else fail "a non-zero producer exit with no finding row passed the gate"; fi
gate_is "$SANDBOX/gp-nofind.card" producer-idempotence FAIL
expect "the no-finding-row FAIL is gate-internal" \
  gate_detail_has "$SANDBOX/gp-nofind.card" producer-idempotence gate-internal
expect "the no-finding-row FAIL names its own cause" \
  gate_detail_has "$SANDBOX/gp-nofind.card" producer-idempotence "no finding row"

# --- the producer verdict artifact is PER LABEL -----------------------------------
# One unlabelled producer-idempotence.tsv used to serve all three labels, so
# whichever gate ran last owned it — while phases/6-planning.md derives
# plan-blocking `skip:producer-*` acknowledgments from the POSTMERGE verdict via
# followup-completeness.sh. A midplan gate therefore silently redefined what the
# plan owed (and where midplan's producer arm came back clean, stopped requiring the
# acknowledgment at all). The stub writes producer-idempotence-$LABEL.tsv, so this
# pins both halves: gate.sh passes the label down, and an earlier label's verdict
# survives a later gate.
gpf_run_label() { # gpf_run_label <label> <phase-key> <verdict> <card>
  echo "$3" > "$GPFS/verdict"
  ( cd "$GPF" && GATE_PROD_VERDICT_FILE="$GPFS/verdict" LABEL="$1" RUN=$GPFRUN \
      PHASE_KEY="$2" "$GPFS/gate.sh" ) > "$4" 2> "$4.log"
}
gpf_run_label postmerge "$PK_STRUCTURAL" producer-failed "$SANDBOX/gp-lbl-pm.card"
expect "the postmerge producer verdict lands in its own labelled artifact" \
  test -f "$GPFRUN/producer-idempotence-postmerge.tsv"
gate_is "$SANDBOX/gp-lbl-pm.card" producer-idempotence FAIL
gpf_run_label midplan "$PK_EXECUTION" dirty-tracked "$SANDBOX/gp-lbl-mp.card"
expect "the midplan producer verdict lands in its own labelled artifact" \
  test -f "$GPFRUN/producer-idempotence-midplan.tsv"
expect "the midplan gate reads its OWN label's verdict (dirty-tracked)" \
  gate_detail_has "$SANDBOX/gp-lbl-mp.card" producer-idempotence dirty-tracked
expect "a midplan gate does not overwrite the postmerge verdict Phase 6 derives follow-ups from" \
  bash -c "awk -F'\t' '\$2==\"producer-failed\"' '$GPFRUN/producer-idempotence-postmerge.tsv' | grep -q ."
refute "no gate run writes the old unlabelled artifact" \
  test -f "$GPFRUN/producer-idempotence.tsv"
cd "$SANDBOX"

fi

if t "gate.sh detail cells survive non-UTF-8 build output (oneline is locale-pinned)"; then
# A build's output is NOT guaranteed valid UTF-8 — a linker echoing raw symbol
# bytes, a compiler quoting a binary asset. gate.sh collapses that output into
# the build row's detail cell with oneline(), and BSD `tr` in a UTF-8 locale
# ABORTS on the first invalid byte ("tr: Illegal byte sequence") and truncates
# the cell there. Everything the reader needs to see is typically AFTER the
# stray byte, so the row degrades to "build failed: <two words>" and the
# migration operator is handed a verdict card whose content depends on the
# ambient LC_ALL. producer-idempotence.sh's oneline() was pinned to LC_ALL=C for
# exactly this; this asserts gate.sh's copy behaves the same. Regression.
GLC=$SANDBOX/gate-locale; GLCRUN=$SANDBOX/gate-locale-run; GLCSYN=$SANDBOX/gate-locale-synth
mkdir -p "$GLC" "$GLCRUN" "$GLCSYN"
( cd "$GLCSYN" && git init -q -b main \
  && printf 'name: sprocket\n' > config.yaml \
  && git add -A && git commit -qm target && git tag kairos-base && git tag kairos-target )
cd "$GLC" && git init -q -b main
printf 'name: sprocket\n' > config.yaml
git add -A && git commit -qm init
# \377 is not valid UTF-8, and the diagnostic the operator needs sits after it.
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" \
  'printf "linker emitted \377 raw bytes\ncompile error: undefined flangebox\n" >&2; false' \
  'no regen command' > "$GLCRUN/test-command.txt"
: > "$GLCRUN/test-baseline.failures.txt"
: > "$GLCRUN/classification.tsv"
stamp_binding "$GLCSYN" "$GLCRUN"
# The ASSERTION's own extraction is pinned too. gate_detail_has runs awk and grep
# in the suite's ambient locale, and the card cell under test contains the stray
# byte by construction — an unpinned reader would truncate the cell before the
# needle and report a red gate.sh even after gate.sh is correct.
glc_detail_has() { # glc_detail_has <card> <check> <needle>
  LC_ALL=C awk -F'\t' -v c="$2" '$1==c{print $3}' "$1" | LC_ALL=C grep -qi -- "$3"
}
# en_US.UTF-8 is the locale that reproduces this on macOS; C.UTF-8 is there
# because the Ubuntu image carries no en_US.UTF-8, so without it the container
# would never exercise a multibyte locale at all. A platform missing either name
# falls back to C — the detail must be the same one anyway.
for loc in C en_US.UTF-8 C.UTF-8; do
  LC_ALL=$loc LABEL=postmerge RUN=$GLCRUN SYNTH=$GLCSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
    > "$SANDBOX/gc-locale.card" 2> "$SANDBOX/gc-locale.log"
  gate_is "$SANDBOX/gc-locale.card" build FAIL
  expect "the build FAIL detail survives past the non-UTF-8 byte (LC_ALL=$loc)" \
    glc_detail_has "$SANDBOX/gc-locale.card" build flangebox
  refute "collapsing non-UTF-8 build output leaks no byte-sequence error (LC_ALL=$loc)" \
    grep -qi 'illegal byte sequence\|invalid byte sequence' "$SANDBOX/gc-locale.log"
done
cd "$SANDBOX"

fi

if t "gate.sh census row — executor-era diff (final), informational relay (postmerge), absent at midplan"; then
# Every check above compares FAILURE sets, so none of them can see a test that
# simply stopped running. This block drives the census row end-to-end through
# gate.sh's real wiring: a recorded census recipe — written via
# write-test-commands.sh's CENSUS field, Phase 4.5's sibling census-command.txt —
# feeds the SAME suite run gate.sh's tests check already performs (no second
# run), and census-diff.sh diffs the populations that run leaves behind.
CEN=$SANDBOX/gate-census; CENRUN=$SANDBOX/gate-census-run; CENSYN=$SANDBOX/gate-census-synth
CENWTC="$SKILL_DIR/scripts/write-test-commands.sh"
mkdir -p "$CEN" "$CENRUN" "$CENSYN"
( cd "$CENSYN" && git init -q -b main \
  && printf 'a: 1\n' > config.yaml \
  && git add -A && git commit -qm target && git tag kairos-base && git tag kairos-target )
cd "$CEN" && git init -q -b main
printf 'a: 1\n' > config.yaml
git add -A && git commit -qm init
: > "$CENRUN/test-baseline.failures.txt"
: > "$CENRUN/classification.tsv"
stamp_binding "$CENSYN" "$CENRUN"

# A census recipe over the SAME captured raw output as EXTRACTOR — the exact
# grep|awk idiom run-check.test.sh and write-test-commands.test.sh already pin for
# emitting "id<TAB>pass|fail|skip".
CEN_CENSUS='grep "^CENSUS " | awk "{print \$2\"\t\"\$3}"'
CEN_TEST_BOTH='echo "CENSUS Alpha pass"; echo "CENSUS Beta pass"'
CEN_TEST_ALPHA_ONLY='echo "CENSUS Alpha pass"'

RUN=$CENRUN PHASE_KEY=$PK_BASELINE TEST_CMD="$CEN_TEST_BOTH" EXTRACTOR="$GT_EXTRACT" \
  BUILD_CMD='echo compiled' REGEN_CMD='' CENSUS="$CEN_CENSUS" \
  "$CENWTC" >/dev/null 2>&1
expect "the census recipe lands in the sibling file" \
  grep -qF "$CEN_CENSUS" "$CENRUN/census-command.txt"

# --- LABEL=midplan: NO census row at all — census is postmerge/final only ------
LABEL=midplan RUN=$CENRUN SYNTH=$CENSYN PHASE_KEY=$PK_EXECUTION "$GATE" \
  > "$SANDBOX/cen-midplan.card" 2> "$SANDBOX/cen-midplan.log"
expect "midplan still passes with a census recipe recorded (exit 0)" test $? -eq 0
refute "no census row under LABEL=midplan — census is postmerge/final only" \
  gate_row_present "$SANDBOX/cen-midplan.card" census

# --- LABEL=postmerge: ALWAYS INCOMPLETE (informational relay), never flips AGGREGATE ---
LABEL=postmerge RUN=$CENRUN SYNTH=$CENSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/cen-postmerge.card" 2> "$SANDBOX/cen-postmerge.log"
expect "postmerge passes with a census row present but INCOMPLETE (exit 0)" test $? -eq 0
gate_is "$SANDBOX/cen-postmerge.card" census INCOMPLETE
expect "the postmerge census row reads as an informational relay" \
  gate_detail_has "$SANDBOX/cen-postmerge.card" census informational
gate_is "$SANDBOX/cen-postmerge.card" AGGREGATE PASS
# The tests check's free-rider population for this epoch now exists on disk —
# this is what the final-epoch diff below will compare against.
expect "the tests check's free-rider population now exists for the postmerge epoch" \
  test -f "$CENRUN/test-postmerge.population.txt"
WANT_POSTMERGE_POP=$(printf 'Alpha\nBeta\n')
GOT_POSTMERGE_POP=$(cat "$CENRUN/test-postmerge.population.txt" 2>/dev/null)
if [[ "$GOT_POSTMERGE_POP" = "$WANT_POSTMERGE_POP" ]]; then
  pass "the postmerge population carries both top-level ids, sorted"
else
  fail "the postmerge population = '$GOT_POSTMERGE_POP' (want '$WANT_POSTMERGE_POP')"
fi

# --- LABEL=final, nothing disappeared: census PASS, AGGREGATE PASS -------------
LABEL=final RUN=$CENRUN SYNTH=$CENSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/cen-final-pass.card" 2> "$SANDBOX/cen-final-pass.log"
expect "a final run with no disappeared test passes the gate (exit 0)" test $? -eq 0
gate_is "$SANDBOX/cen-final-pass.card" census PASS
expect "the PASS detail says nothing disappeared" \
  gate_detail_has "$SANDBOX/cen-final-pass.card" census "no test disappeared"
expect "the PASS row attributes the diff to the executor era (postmerge base usable)" \
  gate_detail_has "$SANDBOX/cen-final-pass.card" census "executor-era"
gate_is "$SANDBOX/cen-final-pass.card" AGGREGATE PASS

# --- LABEL=final, a test DISAPPEARED (present in the postmerge population, absent
# from both the final population AND the final skips): census FAIL, and that FAIL
# ALONE flips the AGGREGATE ------------------------------------------------------
# The disappearance is arranged by recording a census recipe whose final-epoch
# output simply omits the id — run-check.sh writes test-final.population.txt as a
# free rider on the SAME suite run gate.sh's tests check performs, so the
# postmerge population captured just above is untouched and only the final side
# changes.
RUN=$CENRUN PHASE_KEY=$PK_BASELINE TEST_CMD="$CEN_TEST_ALPHA_ONLY" EXTRACTOR="$GT_EXTRACT" \
  BUILD_CMD='echo compiled' REGEN_CMD='' CENSUS="$CEN_CENSUS" \
  "$CENWTC" >/dev/null 2>&1
LABEL=final RUN=$CENRUN SYNTH=$CENSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/cen-final-fail.card" 2> "$SANDBOX/cen-final-fail.log"
CEN_FF_RC=$?
if [[ "$CEN_FF_RC" -ne 0 ]]; then pass "a disappeared top-level test fails the final gate"; else fail "a disappeared top-level test passed the final gate"; fi
gate_is "$SANDBOX/cen-final-fail.card" census FAIL
expect "the FAIL names the disappeared id" \
  gate_detail_has "$SANDBOX/cen-final-fail.card" census Beta
expect "the FAIL says a test disappeared" \
  gate_detail_has "$SANDBOX/cen-final-fail.card" census disappeared
refute "the census FAIL is not blamed on the gate itself" \
  gate_detail_has "$SANDBOX/cen-final-fail.card" census gate-internal
# Every OTHER check on this same tree is still clean — the census FAIL is the ONLY
# thing standing between this tree and a PASS, and it alone flips AGGREGATE.
gate_is "$SANDBOX/cen-final-fail.card" build PASS
gate_is "$SANDBOX/cen-final-fail.card" tests PASS
gate_is "$SANDBOX/cen-final-fail.card" AGGREGATE FAIL

# --- LABEL=final, EVERY test disappeared: the suite ran, censused an EMPTY
# population, and the postmerge epoch had two ids. That transition is a census FAIL
# carrying the mass-disappearance rationale — and it is the ONE total-loss case no
# other row can see: the suite is green (nothing left to fail), so build and tests
# both PASS on a tree with no tests in it. ---------------------------------------
# Arranged the same way as the arm above — only the recorded suite command changes,
# to one that emits no CENSUS line at all, so the free-rider population for the
# final epoch is written empty while the postmerge population stays as captured.
RUN=$CENRUN PHASE_KEY=$PK_BASELINE TEST_CMD='echo ALLPASS' EXTRACTOR="$GT_EXTRACT" \
  BUILD_CMD='echo compiled' REGEN_CMD='' CENSUS="$CEN_CENSUS" \
  "$CENWTC" >/dev/null 2>&1
LABEL=final RUN=$CENRUN SYNTH=$CENSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/cen-final-mass.card" 2> "$SANDBOX/cen-final-mass.log"
CEN_MASS_RC=$?
if [[ "$CEN_MASS_RC" -ne 0 ]]; then pass "a wholesale test disappearance fails the final gate"; else fail "a wholesale test disappearance passed the final gate"; fi
expect "fixture sanity: the final epoch really was censused (status OK), it just found nothing" \
  grep -qx 'OK' "$CENRUN/test-final.census.status"
refute "fixture sanity: the final population is empty, not absent" \
  test -s "$CENRUN/test-final.population.txt"
expect "fixture sanity: the final population file exists (the run happened)" \
  test -f "$CENRUN/test-final.population.txt"
gate_is "$SANDBOX/cen-final-mass.card" census FAIL
expect "the row carries the mass-test-disappearance rationale, not a bare count" \
  gate_detail_has "$SANDBOX/cen-final-mass.card" census "mass test disappearance"
refute "the mass-disappearance FAIL is not blamed on the gate itself" \
  gate_detail_has "$SANDBOX/cen-final-mass.card" census gate-internal
# The whole point: every other row is clean, because a component with no tests left
# produces no failures for a failure-set comparison to find.
gate_is "$SANDBOX/cen-final-mass.card" build PASS
gate_is "$SANDBOX/cen-final-mass.card" tests PASS
gate_is "$SANDBOX/cen-final-mass.card" AGGREGATE FAIL

# --- LABEL=final, the recipe is recorded as the literal 'no census extractor':
# census INCOMPLETE (census unavailable), never gate-internal, never a silent
# absence of the row --------------------------------------------------------------
RUN=$CENRUN PHASE_KEY=$PK_BASELINE TEST_CMD="$CEN_TEST_ALPHA_ONLY" EXTRACTOR="$GT_EXTRACT" \
  BUILD_CMD='echo compiled' REGEN_CMD='' CENSUS='' \
  "$CENWTC" >/dev/null 2>&1
expect "an empty CENSUS is recorded as the literal 'no census extractor'" \
  grep -qx 'no census extractor' "$CENRUN/census-command.txt"
LABEL=final RUN=$CENRUN SYNTH=$CENSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/cen-final-noextractor.card" 2> "$SANDBOX/cen-final-noextractor.log"
expect "no census extractor still passes the final gate (INCOMPLETE never blocks)" test $? -eq 0
gate_is "$SANDBOX/cen-final-noextractor.card" census INCOMPLETE
expect "the row says census is unavailable, not gate-internal" \
  gate_detail_has "$SANDBOX/cen-final-noextractor.card" census unavailable
refute "a recorded 'no census extractor' is never gate-internal" \
  gate_detail_has "$SANDBOX/cen-final-noextractor.card" census gate-internal
refute "no census recipe means no population artifact for this epoch" \
  test -f "$CENRUN/test-final.population.txt"
gate_is "$SANDBOX/cen-final-noextractor.card" AGGREGATE PASS

# --- the same, with census-command.txt ABSENT entirely (a run that predates the
# census, or an operator-deleted sibling file) — identical INCOMPLETE relay ------
rm -f "$CENRUN/census-command.txt"
LABEL=final RUN=$CENRUN SYNTH=$CENSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/cen-final-noscript.card" 2> "$SANDBOX/cen-final-noscript.log"
expect "an absent census-command.txt still passes the final gate" test $? -eq 0
gate_is "$SANDBOX/cen-final-noscript.card" census INCOMPLETE
expect "an absent sibling file reads the same as the literal placeholder" \
  gate_detail_has "$SANDBOX/cen-final-noscript.card" census unavailable
gate_is "$SANDBOX/cen-final-noscript.card" AGGREGATE PASS
cd "$SANDBOX"

fi

if t "gate.sh census hygiene — a tests-check refusal arm never censuses a suite run that never happened"; then
# The regression this pins: the census artifact sweep used to live INSIDE the arm
# that actually runs the suite, while the census row (check 8) runs
# unconditionally at postmerge/final. So each of the five refusal/placeholder arms
# — no test-command.txt, the literal 'no tests detected', a malformed line 1,
# a malformed line 2, a missing or unreadable baseline — left a previous gate
# invocation's population/skips/census.status on disk for census-diff.sh to
# consume, and a resumed run whose test discovery degraded after an earlier gate
# attempt got a positive-evidence census PASS (or a false disappearance FAIL)
# built from epochs THIS run never produced. Every arm below must read
# INCOMPLETE: no suite run, no epoch.
STC=$SANDBOX/gate-stale; STRUN=$SANDBOX/gate-stale-run; STSYN=$SANDBOX/gate-stale-synth
mkdir -p "$STC" "$STRUN" "$STSYN"
( cd "$STSYN" && git init -q -b main \
  && printf 'a: 1\n' > config.yaml \
  && git add -A && git commit -qm target && git tag kairos-base && git tag kairos-target )
cd "$STC" && git init -q -b main
printf 'a: 1\n' > config.yaml
git add -A && git commit -qm init
: > "$STRUN/classification.tsv"
stamp_binding "$STSYN" "$STRUN"
# A real recorded recipe, as a resumed run carries: the degradation being
# simulated is in test DISCOVERY (line 1/2 of test-command.txt, the baseline),
# not in the census recipe.
printf '%s\n' "$CEN_CENSUS" > "$STRUN/census-command.txt"

# The simulated earlier invocation: a complete, CONSUMABLE census triplet for
# every epoch, final included. $1 is the final-epoch population, so the caller
# chooses which verdict the stale evidence would manufacture.
stale_plant() { # stale_plant <final-population-content>
  printf 'Alpha\nBeta\n' > "$STRUN/test-baseline.population.txt"
  : > "$STRUN/test-baseline.skips.txt"
  printf 'OK\n'          > "$STRUN/test-baseline.census.status"
  printf 'Alpha\nBeta\n' > "$STRUN/test-postmerge.population.txt"
  : > "$STRUN/test-postmerge.skips.txt"
  printf 'OK\n'          > "$STRUN/test-postmerge.census.status"
  printf '%s' "$1"       > "$STRUN/test-final.population.txt"
  : > "$STRUN/test-final.skips.txt"
  printf 'OK\n'          > "$STRUN/test-final.census.status"
}
# Each arm degrades exactly one input the tests check validates before it runs
# the suite; everything else stays a valid recording.
stale_arm_setup() { # stale_arm_setup <arm>
  printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' \
    > "$STRUN/test-command.txt"
  : > "$STRUN/test-baseline.failures.txt"
  case "$1" in
    nocmdfile)  rm -f "$STRUN/test-command.txt" ;;
    notests)    printf '%s\n' 'no tests detected' "$GT_EXTRACT" 'echo compiled' 'no regen command' \
                  > "$STRUN/test-command.txt" ;;
    badline1)   printf '%s\n' ' # rejected: go test ./...' "$GT_EXTRACT" 'echo compiled' 'no regen command' \
                  > "$STRUN/test-command.txt" ;;
    badline2)   printf '%s\n' 'echo ALLPASS' ' # rejected: grep FAILID' 'echo compiled' 'no regen command' \
                  > "$STRUN/test-command.txt" ;;
    nobaseline) rm -f "$STRUN/test-baseline.failures.txt" ;;
    unreadable) chmod 000 "$STRUN/test-baseline.failures.txt" ;;
  esac
}

# --- fixture sanity: the plant really is consumable evidence ---------------------
# Without this the assertions below could all pass vacuously: an UNUSABLE plant
# reads INCOMPLETE no matter what the gate does. census-diff.sh must verdict it.
stale_plant "$(printf 'Alpha\nBeta\n')"
ST_SANE_ROW=$(RUN=$STRUN LABEL=final "$SKILL_DIR/scripts/census-diff.sh" 2>/dev/null || true)
st_is_verdict() { # st_is_verdict <census row>  — PASS or FAIL, i.e. not INCOMPLETE
  printf '%s\n' "$1" | awk -F'\t' 'NR==1 && $1=="census" && ($2=="PASS" || $2=="FAIL")' | grep -q .
}
expect "fixture sanity: the pre-planted triplet is a consumable final epoch (census-diff verdicts it, so an INCOMPLETE below is the gate's doing)" \
  st_is_verdict "$ST_SANE_ROW"

# --- every refusal arm, with a stale triplet that WOULD read PASS ----------------
for starm in nocmdfile notests badline1 badline2 nobaseline; do
  stale_plant "$(printf 'Alpha\nBeta\n')"
  stale_arm_setup "$starm"
  LABEL=final RUN=$STRUN SYNTH=$STSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
    > "$SANDBOX/st-$starm.card" 2> "$SANDBOX/st-$starm.log"
  gate_is "$SANDBOX/st-$starm.card" census INCOMPLETE
  expect "[$starm] the census row says the question could not be asked" \
    gate_detail_has "$SANDBOX/st-$starm.card" census "could not be asked"
  refute "[$starm] no census PASS is manufactured from the previous invocation's epochs" \
    gate_detail_has "$SANDBOX/st-$starm.card" census "no test disappeared"
  refute "[$starm] the stale final population is gone from disk" \
    test -f "$STRUN/test-final.population.txt"
  refute "[$starm] the stale final census status is gone from disk" \
    test -f "$STRUN/test-final.census.status"
  refute "[$starm] the stale final skips file is gone from disk" \
    test -f "$STRUN/test-final.skips.txt"
  case "$starm" in
    notests) gate_is "$SANDBOX/st-$starm.card" tests INCOMPLETE ;;
    *)       gate_is "$SANDBOX/st-$starm.card" tests FAIL ;;
  esac
  # T6: each tests-row gate-internal arm is pinned by its OWN wording, not only
  # the shared gate-internal token, so a reworded arm cannot drift to a different
  # cause unnoticed.
  case "$starm" in
    nocmdfile) expect "[nocmdfile] the tests FAIL names the missing command file (T6)" \
                 gate_detail_has "$SANDBOX/st-$starm.card" tests "Phase 4.5 never recorded the discovered commands" ;;
    badline1)  expect "[badline1] the tests FAIL names the not-a-command cause (T6)" \
                 gate_detail_has "$SANDBOX/st-$starm.card" tests "is not a command or the literal 'no tests detected'" ;;
    badline2)  expect "[badline2] the tests FAIL names the missing-extractor cause (T6)" \
                 gate_detail_has "$SANDBOX/st-$starm.card" tests "carries no extractor, or a drifted rejection comment" ;;
    nobaseline) expect "[nobaseline] the tests FAIL names the missing-baseline cause (T6)" \
                 gate_detail_has "$SANDBOX/st-$starm.card" tests "no pre-merge baseline to compare against" ;;
  esac
  # The earlier epochs are legitimate inputs this run diffs against, not this
  # label's artifacts: the sweep must be label-scoped, not a $RUN-wide purge.
  expect "[$starm] the baseline epoch's population survives (only the current label is swept)" \
    test -f "$STRUN/test-baseline.population.txt"
  expect "[$starm] the postmerge epoch's population survives (only the current label is swept)" \
    test -f "$STRUN/test-postmerge.population.txt"
done

# --- the unreadable-baseline arm (the fifth refusal), same rule -----------------
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the unreadable-baseline refusal arm is not exercised: 4 assertions (census INCOMPLETE, no stale PASS, stale artifacts swept)"
else
  stale_plant "$(printf 'Alpha\nBeta\n')"
  stale_arm_setup unreadable
  LABEL=final RUN=$STRUN SYNTH=$STSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
    > "$SANDBOX/st-unreadable.card" 2> "$SANDBOX/st-unreadable.log"
  chmod 644 "$STRUN/test-baseline.failures.txt"
  gate_is "$SANDBOX/st-unreadable.card" census INCOMPLETE
  refute "[unreadable] no census PASS is manufactured from the previous invocation's epochs" \
    gate_detail_has "$SANDBOX/st-unreadable.card" census "no test disappeared"
  refute "[unreadable] the stale final population is gone from disk" \
    test -f "$STRUN/test-final.population.txt"
  gate_is "$SANDBOX/st-unreadable.card" tests FAIL
fi

# --- the other direction: a stale triplet that WOULD read FAIL -------------------
# A false census FAIL is the same defect wearing the opposite sign — the row would
# name an id nothing in this run ever looked for, and would flip the AGGREGATE of
# an otherwise-clean tree.
stale_plant "$(printf 'Alpha\n')"
stale_arm_setup notests
LABEL=final RUN=$STRUN SYNTH=$STSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/st-fabricated-fail.card" 2> "$SANDBOX/st-fabricated-fail.log"
expect "a refusal arm with stale FAIL-shaped evidence still exits 0 (INCOMPLETE never blocks)" test $? -eq 0
gate_is "$SANDBOX/st-fabricated-fail.card" census INCOMPLETE
refute "no disappearance finding is fabricated from the stale epochs" \
  gate_detail_has "$SANDBOX/st-fabricated-fail.card" census "1 disappeared"
refute "the census row names no id this run never censused" \
  gate_detail_has "$SANDBOX/st-fabricated-fail.card" census Beta
gate_is "$SANDBOX/st-fabricated-fail.card" AGGREGATE PASS

# --- LABEL=postmerge: the same rule, its own label's triplet --------------------
# At postmerge the row is INCOMPLETE either way, so the evidence is in the detail:
# the template-era relay must read "unavailable", not a borrowed count computed
# from a postmerge population this run never produced.
stale_plant "$(printf 'Alpha\nBeta\n')"
stale_arm_setup notests
LABEL=postmerge RUN=$STRUN SYNTH=$STSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/st-postmerge.card" 2> "$SANDBOX/st-postmerge.log"
gate_is "$SANDBOX/st-postmerge.card" census INCOMPLETE
expect "the postmerge relay reports the template-era context as unavailable" \
  gate_detail_has "$SANDBOX/st-postmerge.card" census "unavailable"
refute "no template-era count is relayed from the previous invocation's postmerge epoch" \
  gate_detail_has "$SANDBOX/st-postmerge.card" census "removed"
refute "the stale postmerge population is gone from disk at LABEL=postmerge" \
  test -f "$STRUN/test-postmerge.population.txt"
expect "the baseline epoch still survives at LABEL=postmerge" \
  test -f "$STRUN/test-baseline.population.txt"
cd "$SANDBOX"

fi

if t "gate.sh — a failed mktemp refuses, absolute replaces are seen, marker hits persist"; then
GH=$SANDBOX/gate-hard; GHRUN=$SANDBOX/gate-hard-run; GHSYN=$SANDBOX/gate-hard-synth
mkdir -p "$GH" "$GHRUN" "$GHSYN"
( cd "$GHSYN" && git init -q -b main \
  && printf 'a: 1\n' > config.yaml \
  && git add -A && git commit -qm target && git tag kairos-base && git tag kairos-target )
cd "$GH" && git init -q -b main
printf 'a: 1\n' > config.yaml
git add -A && git commit -qm init
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GHRUN/test-command.txt"
: > "$GHRUN/test-baseline.failures.txt"
: > "$GHRUN/classification.tsv"
stamp_binding "$GHSYN" "$GHRUN"

# --- (1) a failed mktemp is a REFUSAL, never a PASS over nothing --------------
# Reproduced pre-fix: TMPDIR pointing nowhere left every work-file variable
# EMPTY, each row() append failed silently (no set -e by design), and the
# aggregate awk — handed a null ARGV element POSIX awk SKIPS — fell through to a
# closed stdin, saw zero records, and printed AGGREGATE PASS at exit 0: the
# final gate of a multi-hour migration reporting success over a tree it never
# checked. stdin is closed here exactly to reproduce that path.
TMPDIR=/nonexistent-by-design LABEL=postmerge RUN=$GHRUN SYNTH=$GHSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  < /dev/null > "$SANDBOX/gh-mktemp.out" 2> "$SANDBOX/gh-mktemp.err"; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "gate.sh: a failed mktemp exits 1, never a silent PASS"; else fail "gate.sh: a failed mktemp exits 1, never a silent PASS (rc=$rc, stdout '$(cat "$SANDBOX/gh-mktemp.out")')"; fi
refute "gate.sh: no AGGREGATE line is printed when the work files never existed" \
  grep -q 'AGGREGATE' "$SANDBOX/gh-mktemp.out"
expect "gate.sh: the refusal names mktemp and gate-internal" \
  grep -q 'gate-internal: mktemp' "$SANDBOX/gh-mktemp.err"
refute "gate.sh: no verdict card lands on disk for a run that never ran" \
  test -f "$GHRUN/gate-postmerge.tsv"

# --- (2) an ABSOLUTE-path replace is the same CI breakage as ../ --------------
# `go mod edit -replace mod=$(pwd)/../common` — the natural CLI spelling —
# writes an absolute path; the old ./|../-only filters issued an affirmative
# PASS over it ("no local-path replace directive in N go.mod file(s)").
cat > go.mod <<'EOF'
module example.com/gatecomp

go 1.21

replace example.com/common => /home/dev/kairos-component-common
EOF
git add -A && git commit -qm gomod-absolute
LABEL=postmerge RUN=$GHRUN SYNTH=$GHSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" \
  > "$SANDBOX/gh-abs.card" 2> "$SANDBOX/gh-abs.log"
gate_is "$SANDBOX/gh-abs.card" replace-directives NEEDS-INPUT
expect "gate.sh: the absolute-path directive is named in the row" \
  gate_detail_has "$SANDBOX/gh-abs.card" replace-directives '/home/dev/kairos-component-common'

# --- (3) the conflict-markers FAIL persists its FULL hit list under $RUN ------
# The detail column is head-10-truncated and the scan's temp file is deleted by
# the EXIT trap, so "grep hit list above" cited evidence that no longer existed
# — for the one row that blocks finalize and demands per-file inspection of
# EVERY hit.
rm -f go.mod && git add -A && git commit -qm drop-gomod
{ printf '<<<<<<< ours\nleft\n=======\nright\n>>>>>>> theirs\n'; } > marked.txt
git add -A && git commit -qm plant-marker
LABEL=final RUN=$GHRUN SYNTH=$GHSYN PHASE_KEY=$PK_FINALIZE "$GATE" \
  > "$SANDBOX/gh-marker.card" 2> "$SANDBOX/gh-marker.log"
gate_is "$SANDBOX/gh-marker.card" conflict-markers FAIL
expect "gate.sh: the FAIL row cites the persisted hit list, not a deleted temp file" \
  bash -c "awk -F'\t' '\$1==\"conflict-markers\"' '$SANDBOX/gh-marker.card' | grep -q 'gate-marker-hits.final.txt'"
expect "gate.sh: the persisted hit list exists and names the marked file" \
  grep -q 'marked.txt' "$GHRUN/gate-marker-hits.final.txt"
fi

if t "gate.sh build check — the multi-module sweep rows and modules.tsv evidence"; then
# T2: none of the other fixtures starts line 3 with `go`, so run-check-modules.sh's
# sweep_applies() is always false and gate.sh's multi-module build rows (the
# across-all-modules PASS, the failing-module(s) FAIL, and the modules.tsv evidence
# each cites) are structurally unreachable in their own suite. A real two-module Go
# fixture with `go build ./...` on line 3 is the only thing that makes gate.sh take
# the sweep and read a modules.tsv back.
GMM=$SANDBOX/gate-multimod; GMMRUN=$SANDBOX/gate-multimod-run; GMMSYN=$SANDBOX/gate-multimod-synth
mkdir -p "$GMM" "$GMMSYN" "$GMMRUN"
if ! command -v go >/dev/null 2>&1; then
  echo "  skip: go not installed — gate.sh's multi-module build rows (modules.tsv evidence) are not exercised"
else
# Hermetic: std-lib only, no module fetch, no toolchain download (run-check-modules'
# own fixture rule). Two go.mod files — the root and pkg/schema — are what make
# `go build ./...` (which compiles only the module it runs in) require the sweep.
( cd "$GMMSYN" && git init -q -b main \
  && printf 'a: 1\n' > config.yaml \
  && git add -A && git commit -qm target && git tag kairos-base && git tag kairos-target )
cd "$GMM" && git init -q -b main
printf 'module example.com/gatemm\n\ngo 1.21\n' > go.mod
mkdir -p pkg/schema
printf 'module example.com/gatemm/pkg/schema\n\ngo 1.21\n' > pkg/schema/go.mod
printf 'package gatemm\n\nfunc Root() int { return 1 }\n' > root.go
printf 'package schema\n\nfunc Schema() int { return 2 }\n' > pkg/schema/lib.go
git add -A && git commit -qm init
: > "$GMMRUN/test-baseline.failures.txt"
: > "$GMMRUN/classification.tsv"
stamp_binding "$GMMSYN" "$GMMRUN"
# line 1 = a fast non-go green suite (isolates the BUILD sweep); line 3 = `go build
# ./...`, whose first word `go` is what trips sweep_applies().
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'go build ./...' 'no regen command' \
  > "$GMMRUN/test-command.txt"

# --- both modules compile: build PASS "across all modules", counted, with evidence
( cd "$GMM" && LABEL=postmerge RUN=$GMMRUN SYNTH=$GMMSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" ) \
  > "$SANDBOX/gmm-clean.card" 2> "$SANDBOX/gmm-clean.log"
gate_is "$SANDBOX/gmm-clean.card" build PASS
expect "the multi-module build PASS says it spanned all modules" \
  gate_detail_has "$SANDBOX/gmm-clean.card" build "across all modules"
GMM_EV=$(gate_evidence "$SANDBOX/gmm-clean.card" build)
case "$GMM_EV" in
  *"2 module(s)"*) pass "the build PASS evidence counts the swept modules (2 module(s))" ;;
  *) fail "the build PASS evidence counts the swept modules (got '$GMM_EV')" ;;
esac
case "$GMM_EV" in
  *modules.tsv*) pass "the build PASS evidence cites the modules.tsv sweep report" ;;
  *) fail "the build PASS evidence cites the modules.tsv sweep report (got '$GMM_EV')" ;;
esac
expect "gate.sh read back a per-run modules.tsv sweep report" \
  test -f "$GMMRUN/build-postmerge.modules.tsv"

# --- one sibling module fails to compile: build FAIL naming the module ----------
printf 'package schema\n\nfunc Schema() int { return "boom" }\n' > pkg/schema/lib.go
git add -A && git commit -qm break-schema
( cd "$GMM" && LABEL=postmerge RUN=$GMMRUN SYNTH=$GMMSYN PHASE_KEY=$PK_STRUCTURAL "$GATE" ) \
  > "$SANDBOX/gmm-broken.card" 2> "$SANDBOX/gmm-broken.log"
gate_is "$SANDBOX/gmm-broken.card" build FAIL
expect "the multi-module build FAIL uses the failing-module(s) wording" \
  gate_detail_has "$SANDBOX/gmm-broken.card" build "failing module(s)"
expect "the build FAIL names the broken sibling module" \
  gate_detail_has "$SANDBOX/gmm-broken.card" build "pkg/schema"
GMM_BEV=$(gate_evidence "$SANDBOX/gmm-broken.card" build)
case "$GMM_BEV" in
  *modules.tsv*) pass "the build FAIL evidence cites the modules.tsv sweep report" ;;
  *) fail "the build FAIL evidence cites the modules.tsv sweep report (got '$GMM_BEV')" ;;
esac
expect "the modules.tsv sweep report records pkg/schema as FAIL" \
  bash -c "awk -F'\t' '\$1==\"pkg/schema\" && \$2==\"FAIL\"' '$GMMRUN/build-postmerge.modules.tsv' | grep -q ."
expect "the modules.tsv sweep report records the root module as OK" \
  bash -c "awk -F'\t' '\$1==\".\" && \$2==\"OK\"' '$GMMRUN/build-postmerge.modules.tsv' | grep -q ."
cd "$SANDBOX"
fi
fi

if t "gate.sh — gate-internal arms are worded for their own cause; a partial card is refused"; then
# T6: gate.sh's gate-internal FAIL arms were pinned only by the shared token; the
# yaml and census arms below are re-pinned by their own distinguishing wording so a
# reworded arm cannot drift to a different cause unnoticed. And the partial-card
# refusal: a non-empty card that lost a row() append must never be aggregated —
# every label emits a fixed 7/5/6 check rows. gate.sh resolves its siblings by
# dirname, so a copy beside mode-driven stubs drives the yaml and census arms
# deterministically, with every other check held clean.
GIA=$SANDBOX/gate-arms
mkdir -p "$GIA"
cp "$SKILL_DIR/scripts/gate.sh" "$GIA/gate.sh"
cat > "$GIA/run-check-modules.sh" <<'EOF'
#!/usr/bin/env bash
echo OK > "$OUT.status"
[ "${CHECK:-}" = test ] && : > "$OUT.failures.txt"
exit 0
EOF
cat > "$GIA/producer-idempotence.sh" <<'EOF'
#!/usr/bin/env bash
printf 'build\tclean\tproducer left tracked state clean\n' > "$RUN/producer-idempotence-$LABEL.tsv"
exit 0
EOF
cat > "$GIA/yaml-gate.sh" <<'EOF'
#!/usr/bin/env bash
case "$(cat "$GIA_YAML_MODE" 2>/dev/null)" in
  missing)     exit 1 ;;                                                            # no tsv at all
  oddsev)      printf 'weird\tdeploy.yaml\tlayer\tsomething\n' > "$RUN/yaml-gate-$LABEL.tsv"; exit 0 ;;
  exit-nofail) printf 'skip\tdeploy.yaml\tlayer4\tno oracle\n'  > "$RUN/yaml-gate-$LABEL.tsv"; exit 3 ;;
  *)           : > "$RUN/yaml-gate-$LABEL.tsv"; exit 0 ;;                           # clean
esac
EOF
cat > "$GIA/census-diff.sh" <<'EOF'
#!/usr/bin/env bash
case "$(cat "$GIA_CENSUS_MODE" 2>/dev/null)" in
  garbage) printf 'not-a-census-row\twhoops\n' ;;                                   # no leading census field
  *)       printf 'census\tINCOMPLETE\ttemplate-era relay\t-\n' ;;
esac
EOF
chmod +x "$GIA"/*.sh
export GIA_YAML_MODE="$GIA/yaml.mode" GIA_CENSUS_MODE="$GIA/census.mode"
GIAC=$SANDBOX/gate-arms-comp; GIARUN=$SANDBOX/gate-arms-run
mkdir -p "$GIAC" "$GIARUN"
( cd "$GIAC" && git init -q -b main && printf 'a: 1\n' > config.yaml \
  && git add -A && git commit -qm init )
printf '%s\n' 'echo ALLPASS' "$GT_EXTRACT" 'echo compiled' 'no regen command' > "$GIARUN/test-command.txt"
: > "$GIARUN/test-baseline.failures.txt"
: > "$GIARUN/classification.tsv"
gia_run() { # gia_run <label> <phase-key> <card>
  ( cd "$GIAC" && LABEL="$1" RUN="$GIARUN" PHASE_KEY="$2" "$GIA/gate.sh" ) > "$3" 2> "$3.log"
}
echo valid > "$GIA/census.mode"

# --- yaml gate-internal arms (LABEL=midplan: no ask-user/census/conflict rows) --
echo missing > "$GIA/yaml.mode"
gia_run midplan "$PK_EXECUTION" "$SANDBOX/gia-ymissing.card"
gate_is "$SANDBOX/gia-ymissing.card" yaml FAIL
expect "the yaml missing-tsv arm names its own cause" \
  gate_detail_has "$SANDBOX/gia-ymissing.card" yaml "missing after the yaml gate ran"
echo oddsev > "$GIA/yaml.mode"
gia_run midplan "$PK_EXECUTION" "$SANDBOX/gia-yodd.card"
gate_is "$SANDBOX/gia-yodd.card" yaml FAIL
expect "the yaml unrecognized-severity arm names its own cause" \
  gate_detail_has "$SANDBOX/gia-yodd.card" yaml "unrecognized severity"
echo exit-nofail > "$GIA/yaml.mode"
gia_run midplan "$PK_EXECUTION" "$SANDBOX/gia-ynofail.card"
gate_is "$SANDBOX/gia-ynofail.card" yaml FAIL
expect "the yaml exit-without-a-fail-row arm names its own cause" \
  gate_detail_has "$SANDBOX/gia-ynofail.card" yaml "with no fail row"

# --- census gate-internal arm (LABEL=final) -------------------------------------
echo clean > "$GIA/yaml.mode"; echo garbage > "$GIA/census.mode"
gia_run final "$PK_FINALIZE" "$SANDBOX/gia-cgarbage.card"
gate_is "$SANDBOX/gia-cgarbage.card" census FAIL
expect "the census invalid-row arm names its own cause" \
  gate_detail_has "$SANDBOX/gia-cgarbage.card" census "produced no valid census row"
echo valid > "$GIA/census.mode"

# --- the row count per label is fixed (7/5/6): a clean run emits exactly that ----
echo clean > "$GIA/yaml.mode"
gia_run postmerge "$PK_STRUCTURAL" "$SANDBOX/gia-pm.card"
expect "a clean postmerge card carries exactly 7 check rows" \
  bash -c "test \"\$(awk -F'\t' '\$1!=\"AGGREGATE\"{c++} END{print c+0}' '$SANDBOX/gia-pm.card')\" = 7"
gia_run midplan "$PK_EXECUTION" "$SANDBOX/gia-mid.card"
expect "a clean midplan card carries exactly 5 check rows" \
  bash -c "test \"\$(awk -F'\t' '\$1!=\"AGGREGATE\"{c++} END{print c+0}' '$SANDBOX/gia-mid.card')\" = 5"
gia_run final "$PK_FINALIZE" "$SANDBOX/gia-fin.card"
expect "a clean final card carries exactly 6 check rows" \
  bash -c "test \"\$(awk -F'\t' '\$1!=\"AGGREGATE\"{c++} END{print c+0}' '$SANDBOX/gia-fin.card')\" = 6"

# --- a partial card (a lost row) is refused, never aggregated over the survivors -
# The lost append is simulated by turning the census check's row() emissions into
# no-ops, so a postmerge run ends with 6 rows where 7 are owed. Without the row-
# count guard this short-but-clean card would aggregate to AGGREGATE PASS.
sed 's/^\([[:space:]]*\)row census .*/\1:/' "$SKILL_DIR/scripts/gate.sh" > "$GIA/gate-short.sh"
chmod +x "$GIA/gate-short.sh"
( cd "$GIAC" && LABEL=postmerge RUN="$GIARUN" PHASE_KEY="$PK_STRUCTURAL" "$GIA/gate-short.sh" ) \
  > "$SANDBOX/gia-short.card" 2> "$SANDBOX/gia-short.log"; GIA_SHORT_RC=$?
if [[ "$GIA_SHORT_RC" -ne 0 ]]; then pass "a card that lost a check row is refused (exit non-zero)"; else fail "a partial card was aggregated (rc=$GIA_SHORT_RC)"; fi
expect "the partial-card refusal names its cause" \
  grep -q 'partial card' "$SANDBOX/gia-short.log"
expect "the refusal reports the short count against the label's own" \
  grep -q '6 check row(s), not the 7' "$SANDBOX/gia-short.log"
refute "no AGGREGATE line is emitted for a partial card" \
  grep -q 'AGGREGATE' "$SANDBOX/gia-short.card"
refute "a partial card never lands a verdict on disk" \
  test -f "$GIARUN/gate-postmerge.tsv"
cd "$SANDBOX"
fi

finish_suite
