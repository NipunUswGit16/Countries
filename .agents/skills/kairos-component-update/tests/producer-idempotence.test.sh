#!/usr/bin/env bash
# producer-idempotence.test.sh — tests for scripts/producer-idempotence.sh
# TEST_FILTER refused (single sequential fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in producer-idempotence.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "producer-idempotence.sh — the tree's own producers leave state clean"; then
# Detection is by the tree's reaction to its own commands, so it needs no
# knowledge of which artifacts a template generates. A COMMITTED tree; the check
# restores anything a producer touches.
PI=$SANDBOX/producer-idem
PIRUN=$SANDBOX/producer-idem-run           # run dir OUTSIDE the repo, or it shows as untracked
mkdir -p "$PI" "$PIRUN" && cd "$PI" && git init -q -b main
echo "generated v1" > generated.txt
printf 'package main\n' > main.go
git add -A && git commit -qm init
PIS="$SKILL_DIR/scripts/producer-idempotence.sh"

# clean producers -> exit 0, no finding
RUN=$PIRUN BUILD_CMD="true" REGEN_CMD="true" "$PIS" > "$SANDBOX/pi-clean.out" 2>&1
expect "idempotent producers pass (exit 0)" test $? -eq 0
expect "clean producers recorded as clean" \
  bash -c "awk -F'\t' '\$2==\"clean\"' '$PIRUN/producer-idempotence.tsv' | grep -q ."

# a producer that DIRTIES a tracked file -> triggered follow-up, and restored
RUN=$PIRUN BUILD_CMD="true" REGEN_CMD="echo regen-v2 > generated.txt" "$PIS" > "$SANDBOX/pi-dirty.out" 2>&1
PI_DIRTY_RC=$?
if [[ "$PI_DIRTY_RC" -ne 0 ]]; then pass "a producer that dirties a tracked artifact fails (stale generated output)"; else fail "stale generated output passed producer idempotence"; fi
expect "dirty-tracked verdict names the artifact" \
  bash -c "awk -F'\t' '\$2==\"dirty-tracked\"{print \$3}' '$PIRUN/producer-idempotence.tsv' | grep -q generated.txt"
expect "the check restored the tracked file it dirtied" \
  bash -c "test \"\$(cat '$PI/generated.txt')\" = 'generated v1'"
refute "the check left the working tree dirty" \
  bash -c "cd '$PI' && git status --porcelain | grep -q ."

# a producer that EMITS an un-ignored file -> triggered follow-up, and cleaned up
RUN=$PIRUN BUILD_CMD="echo compiled > runtime.bin" REGEN_CMD="no regen command" "$PIS" > "$SANDBOX/pi-out.out" 2>&1
PI_OUT_RC=$?
if [[ "$PI_OUT_RC" -ne 0 ]]; then pass "a producer that emits an un-ignored file fails (should be ignored)"; else fail "un-ignored producer output passed"; fi
expect "untracked-output verdict names the emitted file" \
  bash -c "awk -F'\t' '\$2==\"untracked-output\"{print \$3}' '$PIRUN/producer-idempotence.tsv' | grep -q runtime.bin"
expect "the check removed the un-ignored file it detected" test ! -e "$PI/runtime.bin"

# an un-ignored file that is ALREADY gitignored is not a finding
echo "ignored.bin" > .gitignore && git add .gitignore && git commit -qm ignore
RUN=$PIRUN BUILD_CMD="echo x > ignored.bin" REGEN_CMD="no regen command" "$PIS" > "$SANDBOX/pi-ign.out" 2>&1
expect "output that is already gitignored is not a finding (exit 0)" test $? -eq 0
rm -f ignored.bin

# a producer that cannot run in the environment -> skip with a reason, never a pass.
# The fixture fails in a CHILD process (`sh -c`), the way a real producer does: the
# build producer is eval'd by run-check.sh now, so a bare `exit 1` in the recorded
# command would terminate the runner before it wrote the log the reason is read from.
RUN=$PIRUN BUILD_CMD="sh -c \"echo 'dial tcp: no such host' >&2; exit 1\"" REGEN_CMD="no regen command" "$PIS" > "$SANDBOX/pi-skip.out" 2>&1
expect "an environment-blocked producer skips rather than fails (exit 0)" test $? -eq 0
expect "the environment skip carries a reason" \
  bash -c "awk -F'\t' '\$2==\"skip\"{print \$3}' '$PIRUN/producer-idempotence.tsv' | grep -qi 'environment'"
refute "an environment skip is not recorded as a pass/clean" \
  bash -c "awk -F'\t' '\$1==\"build\" && \$2==\"clean\"' '$PIRUN/producer-idempotence.tsv' | grep -q ."

# reads the build/regen producers positionally from test-command.txt when unset
printf 'go test ./...\ngrep FAIL\ntrue\necho regen-from-line4 > generated.txt\n' > "$PIRUN/test-command.txt"
RUN=$PIRUN "$PIS" > "$SANDBOX/pi-file.out" 2>&1
PI_FILE_RC=$?
if [[ "$PI_FILE_RC" -ne 0 ]]; then pass "producers read positionally from test-command.txt (line 3 build, line 4 regen)"; else fail "test-command.txt positional producers not honored"; fi
expect "line-4 regen command detected as the regenerate producer" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && \$2==\"dirty-tracked\"' '$PIRUN/producer-idempotence.tsv' | grep -q ."

# a producer that emits an un-ignored DIRECTORY -> finding, and the directory is
# cleaned up. git porcelain reports a wholly-untracked directory as `?? gen-out/`
# (trailing slash, no per-file lines); `rm -f` cannot remove it. Regression: the
# leftover directory used to survive the restore and ride into the next commit.
rm -f "$PIRUN/test-command.txt"
RUN=$PIRUN BUILD_CMD="no build check" REGEN_CMD="mkdir -p gen-out && echo x > gen-out/f.txt" "$PIS" > "$SANDBOX/pi-dir.out" 2>&1
PI_DIR_RC=$?
if [[ "$PI_DIR_RC" -ne 0 ]]; then pass "a producer that emits an un-ignored directory fails"; else fail "un-ignored directory output passed producer idempotence"; fi
expect "untracked-output verdict names the emitted directory" \
  bash -c "awk -F'\t' '\$2==\"untracked-output\"{print \$3}' '$PIRUN/producer-idempotence.tsv' | grep -q gen-out"
expect "the check removed the un-ignored directory it emitted" test ! -e "$PI/gen-out"
refute "the check left the working tree dirty after removing the directory" \
  bash -c "cd '$PI' && git status --porcelain | grep -q ."
cd "$SANDBOX"

fi

if t "producer-idempotence.sh — the build producer is swept across Go modules"; then
# The build producer goes through run-check-modules.sh, so a sibling `go.mod`
# module is entered too. `go build ./...` in a module with a single main package
# writes that binary INTO the module directory — the untracked-output verdict this
# check exists to produce, in the sibling-module shape a root-only eval never saw.
#
# `go` here is a shim on PATH: the sweep only applies when CMD's first non-assignment
# word is exactly `go`, and the suite must stay hermetic. It emits a binary named
# after the module directory in each dir listed in FAKE_GO_EMIT, and fails with a
# network diagnostic in each dir listed in FAKE_GO_NET.
GOBIN_DIR=$SANDBOX/gobin
mkdir -p "$GOBIN_DIR"
cat > "$GOBIN_DIR/go" <<'FAKEGO'
#!/usr/bin/env bash
[ "${1:-}" = build ] || exit 0
d=${PWD##*/}
case " ${FAKE_GO_NET:-} " in
  *" $d "*) echo "go: module lookup disabled: dial tcp: lookup proxy.golang.org: no such host" >&2; exit 1 ;;
esac
case " ${FAKE_GO_EMIT:-} " in
  *" $d "*) printf 'compiled\n' > "$d" ;;
esac
exit 0
FAKEGO
chmod +x "$GOBIN_DIR/go"

PIS="$SKILL_DIR/scripts/producer-idempotence.sh"

# --- multi-module component: root + web/entrypoint ---------------------------
MM=$SANDBOX/multimod
MMRUN=$SANDBOX/multimod-run                # run dir OUTSIDE the repo
mkdir -p "$MM/web/entrypoint" "$MMRUN" && cd "$MM" && git init -q -b main
printf 'module example.com/mm\n\ngo 1.26\n' > go.mod
printf 'package main\n\nfunc main() {}\n' > main.go
printf 'module example.com/mm/web/entrypoint\n\ngo 1.26\n' > web/entrypoint/go.mod
printf 'package main\n\nfunc main() {}\n' > web/entrypoint/main.go
git add -A && git commit -qm init

# Pre-existing untracked files, present in BOTH snapshots and therefore outside
# the delta. The sweep widened the set of paths `rm -rf` can reach — including
# untracked entries inside a sibling module, which is where the second one sits;
# the before/after delta is the whole of what bounds the removal.
echo "not the producer's" > survivor.txt
echo "sibling bystander" > web/entrypoint/survivor.txt

PATH="$GOBIN_DIR:$PATH" FAKE_GO_EMIT="entrypoint" \
  RUN=$MMRUN BUILD_CMD="go build ./..." REGEN_CMD="no regen command" \
  "$PIS" > "$SANDBOX/pi-sweep.out" 2>&1
PI_SWEEP_RC=$?
if [[ "$PI_SWEEP_RC" -ne 0 ]]; then pass "a sibling module emitting an un-ignored binary fails the check"; else fail "sibling-module un-ignored output passed producer idempotence"; fi
expect "untracked-output verdict names the sibling module's binary" \
  bash -c "awk -F'\t' '\$1==\"build\" && \$2==\"untracked-output\"{print \$3}' '$MMRUN/producer-idempotence.tsv' | grep -q 'web/entrypoint/entrypoint'"
expect "the check removed the sibling module's emitted binary" test ! -e "$MM/web/entrypoint/entrypoint"
expect "a pre-existing untracked file outside the delta survives untouched" \
  bash -c "test \"\$(cat '$MM/survivor.txt')\" = \"not the producer's\""
expect "a pre-existing untracked file inside the swept sibling module survives untouched" \
  bash -c "test \"\$(cat '$MM/web/entrypoint/survivor.txt')\" = 'sibling bystander'"
expect "the sweep left its per-module report beside the aggregated log" \
  bash -c "grep -q 'web/entrypoint' '$MMRUN/producer-build.modules.tsv'"
rm -f survivor.txt web/entrypoint/survivor.txt

# --- env gap in a sibling module still skips, with its reason ----------------
# The reason now comes out of the sweep's AGGREGATED log, not eval's capture.
PATH="$GOBIN_DIR:$PATH" FAKE_GO_NET="entrypoint" \
  RUN=$MMRUN BUILD_CMD="go build ./..." REGEN_CMD="no regen command" \
  "$PIS" > "$SANDBOX/pi-sweep-net.out" 2>&1
expect "a network-blocked sibling module skips rather than fails (exit 0)" test $? -eq 0
expect "the sibling-module skip carries its environment reason" \
  bash -c "awk -F'\t' '\$1==\"build\" && \$2==\"skip\"{print \$3}' '$MMRUN/producer-idempotence.tsv' | grep -q 'no such host'"
expect "the sibling-module skip names the module that failed" \
  bash -c "awk -F'\t' '\$1==\"build\" && \$2==\"skip\"{print \$3}' '$MMRUN/producer-idempotence.tsv' | grep -q 'web/entrypoint'"
refute "an environment skip in a sibling module is not recorded as clean" \
  bash -c "awk -F'\t' '\$1==\"build\" && \$2==\"clean\"' '$MMRUN/producer-idempotence.tsv' | grep -q ."
refute "the sweep left the working tree dirty" \
  bash -c "cd '$MM' && git status --porcelain | grep -q ."

# --- single-root component: artifacts byte-identical to the root-only run ----
SR=$SANDBOX/singleroot
SRRUN=$SANDBOX/singleroot-run
mkdir -p "$SR" "$SRRUN" && cd "$SR" && git init -q -b main
printf 'module example.com/sr\n\ngo 1.26\n' > go.mod
printf 'package main\n\nfunc main() {}\n' > main.go
git add -A && git commit -qm init
PATH="$GOBIN_DIR:$PATH" RUN=$SRRUN BUILD_CMD="go build ./..." REGEN_CMD="no regen command" \
  "$PIS" > "$SANDBOX/pi-single.out" 2>&1
expect "a single-root component's go build is clean (exit 0)" test $? -eq 0
printf 'build\tclean\tproducer left tracked state clean\n' > "$SANDBOX/pi-single.want"
expect "a single-root component's producer-idempotence.tsv is byte-identical to the root-only run" \
  cmp -s "$SRRUN/producer-idempotence.tsv" "$SANDBOX/pi-single.want"
refute "a single-root component leaves no sweep report (it delegates to run-check.sh)" \
  test -f "$SRRUN/producer-build.modules.tsv"
cd "$SANDBOX"

fi

if t "producer-idempotence.sh — a producer that exits non-zero is still restored"; then
# Leave-as-found holds even when the producer doesn't. A non-zero exit used to skip
# BOTH classification and restore, so whatever a half-run `make generate` emitted
# before dying rode into the next `git add -A`. Now the delta is restored anyway and
# the row is `producer-failed` (gate.sh maps that to FAIL) carrying the exit code
# and the TAIL of the producer's output — the cause is where it died, not where it
# started, and the 300-char detail budget is spent from the wrong end otherwise.
PF=$SANDBOX/producer-failed
PFRUN=$SANDBOX/producer-failed-run
mkdir -p "$PF" "$PFRUN" && cd "$PF" && git init -q -b main
echo "generated v1" > generated.txt
git add -A && git commit -qm init
PIS="$SKILL_DIR/scripts/producer-idempotence.sh"

cat > "$SANDBOX/failing-regen.sh" <<'FAILREGEN'
#!/usr/bin/env sh
# >300 chars of preamble, so a detail built from the HEAD of the output loses the
# diagnostic the reader needs.
i=1
while [ "$i" -le 40 ]; do echo "generating module fragment number $i of 40 ..."; i=$((i+1)); done
echo half-emitted > debris.txt
echo regen-v2 > generated.txt
echo "generator: template parse error at line nine" >&2
exit 3
FAILREGEN
chmod +x "$SANDBOX/failing-regen.sh"

RUN=$PFRUN BUILD_CMD="no build check" REGEN_CMD="$SANDBOX/failing-regen.sh" \
  "$PIS" > "$SANDBOX/pi-failed.out" 2>&1
expect "a failed producer is the build/test gate's finding, not this check's (exit 0)" test $? -eq 0
expect "a failed producer is recorded as producer-failed" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && \$2==\"producer-failed\"' '$PFRUN/producer-idempotence.tsv' | grep -q ."
expect "the producer-failed row carries the producer's exit code" \
  bash -c "awk -F'\t' '\$2==\"producer-failed\"{print \$3}' '$PFRUN/producer-idempotence.tsv' | grep -q 'exited 3'"
expect "the producer-failed row carries the producer's LAST output lines" \
  bash -c "awk -F'\t' '\$2==\"producer-failed\"{print \$3}' '$PFRUN/producer-idempotence.tsv' | grep -q 'template parse error'"
expect "the check removed the un-ignored file the failed producer emitted" test ! -e "$PF/debris.txt"
expect "the check restored the tracked file the failed producer dirtied" \
  bash -c "test \"\$(cat '$PF/generated.txt')\" = 'generated v1'"
refute "a failed producer leaves the working tree dirty" \
  bash -c "cd '$PF' && git status --porcelain | grep -q ."
refute "a failed producer is not recorded as clean or skip" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && (\$2==\"clean\" || \$2==\"skip\")' '$PFRUN/producer-idempotence.tsv' | grep -q ."
cd "$SANDBOX"

fi

if t "producer-idempotence.sh — the before/after delta is locale-pinned"; then
# The snapshots are written under `LC_ALL=C sort`; comparing them with an unpinned
# `comm` walks them under the ambient collation. Reproduced on macOS under
# en_US.UTF-8: C orders `A-b.txt < Ab.txt < a_b.txt`, en_US orders
# `a_b.txt < A-b.txt < Ab.txt`, so comm loses alignment at the producer's inserted
# line and emits `a_b.txt` — present in BOTH snapshots — as new. The `??` handler
# then attributes a pre-existing untracked file to the producer and `rm -rf`s the
# user's work. Same pin as handoff-structural.sh and gate.sh's compare_sets.
LOC=$SANDBOX/producer-locale
LOCRUN=$SANDBOX/producer-locale-run
mkdir -p "$LOC" "$LOCRUN" && cd "$LOC" && git init -q -b main
echo seed > seed.txt
git add -A && git commit -qm init
echo "not the producer's" > A-b.txt        # collation-sensitive names, C-sorted
echo "the user's work"    > a_b.txt        # sorts BEFORE both under en_US.UTF-8

LC_ALL=en_US.UTF-8 RUN=$LOCRUN BUILD_CMD="no build check" REGEN_CMD="echo emitted > Ab.txt" \
  "$PIS" > "$SANDBOX/pi-locale.out" 2>&1
PI_LOC_RC=$?
if [[ "$PI_LOC_RC" -ne 0 ]]; then pass "the producer's own un-ignored output is still a finding under en_US.UTF-8"; else fail "un-ignored output missed under en_US.UTF-8"; fi
expect "the pre-existing untracked file survives the locale-crossed delta" \
  bash -c "test \"\$(cat '$LOC/a_b.txt')\" = \"the user's work\""
expect "its collation neighbour survives too" \
  bash -c "test \"\$(cat '$LOC/A-b.txt')\" = \"not the producer's\""
refute "a pre-existing untracked file is not attributed to the producer" \
  bash -c "awk -F'\t' '\$2==\"untracked-output\"{print \$3}' '$LOCRUN/producer-idempotence.tsv' | grep -q 'a_b.txt'"
expect "the file the producer really emitted is named and removed" \
  bash -c "awk -F'\t' '\$2==\"untracked-output\"{print \$3}' '$LOCRUN/producer-idempotence.tsv' | grep -q 'Ab.txt' && test ! -e '$LOC/Ab.txt'"
rm -f A-b.txt a_b.txt
cd "$SANDBOX"

fi

if t "producer-idempotence.sh — env-gap detection matches whole HTTP/auth tokens, not bare substrings"; then
# is_env_gap used to match a bare "401"/"403" substring ANYWHERE in a producer's
# output, so a Go compile error naming a line number (`x.go:401:`) or a test
# duration (`403ms`) downgraded a real BLOCKING failure to a skip — the finding
# vanished into an "incomplete coverage" skip instead of failing the gate.
# Detection now requires the whole token paired with an HTTP/auth status phrase
# ("401 Unauthorized", "HTTP 403", "status 401", …), never a bare numeric run.
EG=$SANDBOX/env-gap
EGRUN=$SANDBOX/env-gap-run          # run dir OUTSIDE the repo
mkdir -p "$EG" "$EGRUN" && cd "$EG" && git init -q -b main
echo seed > seed.txt
git add -A && git commit -qm init
PIS="$SKILL_DIR/scripts/producer-idempotence.sh"

# --- a Go compile error naming line 401 is a real BLOCKING failure -----------
RUN=$EGRUN BUILD_CMD="no build check" \
  REGEN_CMD="sh -c \"echo 'main.go:401: undefined: foo' >&2; exit 1\"" \
  "$PIS" > "$SANDBOX/pi-lineno.out" 2>&1
expect "a compile error naming line 401 is recorded producer-failed (blocking)" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && \$2==\"producer-failed\"' '$EGRUN/producer-idempotence.tsv' | grep -q ."
refute "a compile error naming line 401 is NOT downgraded to an environment skip" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && \$2==\"skip\"' '$EGRUN/producer-idempotence.tsv' | grep -q ."

# --- genuine HTTP/auth failures still skip as an environment gap -------------
RUN=$EGRUN BUILD_CMD="no build check" \
  REGEN_CMD="sh -c \"echo 'fetch failed: 401 Unauthorized' >&2; exit 1\"" \
  "$PIS" > "$SANDBOX/pi-401.out" 2>&1
expect "a genuine '401 Unauthorized' is still detected as an environment skip" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && \$2==\"skip\"' '$EGRUN/producer-idempotence.tsv' | grep -q ."

RUN=$EGRUN BUILD_CMD="no build check" \
  REGEN_CMD="sh -c \"echo 'server responded HTTP 403' >&2; exit 1\"" \
  "$PIS" > "$SANDBOX/pi-403.out" 2>&1
expect "a genuine 'HTTP 403' is still detected as an environment skip" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && \$2==\"skip\"' '$EGRUN/producer-idempotence.tsv' | grep -q ."

# --- numeric tokens that are not HTTP/auth codes never trigger a skip --------
RUN=$EGRUN BUILD_CMD="no build check" \
  REGEN_CMD="sh -c \"echo 'processed batch 1401 of items' >&2; exit 1\"" \
  "$PIS" > "$SANDBOX/pi-1401.out" 2>&1
expect "a '1401' token is recorded producer-failed, not an environment skip" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && \$2==\"producer-failed\"' '$EGRUN/producer-idempotence.tsv' | grep -q ."
refute "a '1401' token does not trigger an environment skip" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && \$2==\"skip\"' '$EGRUN/producer-idempotence.tsv' | grep -q ."

RUN=$EGRUN BUILD_CMD="no build check" \
  REGEN_CMD="sh -c \"echo 'finished in 403ms' >&2; exit 1\"" \
  "$PIS" > "$SANDBOX/pi-403ms.out" 2>&1
expect "a '403ms' duration is recorded producer-failed, not an environment skip" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && \$2==\"producer-failed\"' '$EGRUN/producer-idempotence.tsv' | grep -q ."
refute "a '403ms' duration does not trigger an environment skip" \
  bash -c "awk -F'\t' '\$1==\"regenerate\" && \$2==\"skip\"' '$EGRUN/producer-idempotence.tsv' | grep -q ."
cd "$SANDBOX"

fi

if t "producer-idempotence.sh — env-gap detection: raw-byte input, case-exact keywords, whole-token codes"; then
# The full is_env_gap contract, one assertion per producer-output shape. Three
# defect classes are pinned here at once, because a fix for any one of them has
# already re-opened another:
#
#   * KEYWORD ARM, case-exact AND specific. Lowercasing the input before the glob
#     arm turns post-merge compile/test output into an environment skip:
#     `undefined: CredentialStore` and `Certificate has expired` both match
#     *credential* / *certificate* once folded. The arm therefore matches the
#     producer's BYTES as printed — the lowercase-only patterns keep catching a
#     tool's own lowercase diagnostic, and Go/test identifiers in CamelCase stay
#     blocking. Independently, the not-found patterns must be the specific forms a
#     missing tool or unfetchable module prints; a bare *"not found"* /
#     *"cannot find"* glob swallowed a panic message or a testify assertion the
#     same way the numeric arm swallowed a line number.
#   * NO LOCALE DEPENDENCE. Producer output is not guaranteed UTF-8 (a compiler
#     echoing a source byte, a linker dumping a symbol). `tr '[:upper:]'
#     '[:lower:]'` on BSD tr TRUNCATES at the first invalid byte, so everything
#     after it — including the "401 Unauthorized" that decides the verdict —
#     vanishes, and the verdict flips with LC_ALL. Detection reads raw bytes;
#     `LC_ALL=C grep -Eiq` handles case without rewriting the input, so the byte
#     cases below must give the SAME verdict under C and en_US.UTF-8, with
#     nothing leaking to stderr.
#   * WHOLE-TOKEN 401/403. A bare *401*/*403* glob matches line numbers and
#     durations (the C5 defect, block above); over-tightening instead loses the
#     real registry/proxy shapes a credential-less maintainer actually sees, and
#     leaves them with a hard gate FAIL and no skip route. Both directions are
#     asserted case by case.
EG2=$SANDBOX/env-gap-shapes
EG2RUN=$SANDBOX/env-gap-shapes-run     # run dir OUTSIDE the repo
mkdir -p "$EG2" "$EG2RUN" && cd "$EG2" && git init -q -b main
echo seed > seed.txt
git add -A && git commit -qm init
PIS="$SKILL_DIR/scripts/producer-idempotence.sh"

# The producer prints $EG_TEXT verbatim (bytes preserved, invalid ones included)
# and exits non-zero, touching nothing — so the recorded verdict is exactly
# is_env_gap's classification of that output.
cat > "$SANDBOX/eg-emit.sh" <<'EGEMIT'
#!/usr/bin/env sh
printf '%s\n' "$EG_TEXT" >&2
exit 1
EGEMIT
chmod +x "$SANDBOX/eg-emit.sh"

eg_verdict() { # eg_verdict <locale> <want-verdict> <producer-output> <desc>
  local loc="$1" want="$2" text="$3" desc="$4" got
  ( cd "$EG2" && EG_TEXT="$text" LC_ALL="$loc" RUN=$EG2RUN BUILD_CMD="no build check" \
      REGEN_CMD="$SANDBOX/eg-emit.sh" "$PIS" ) > "$SANDBOX/eg-last.err" 2>&1
  got=$(awk -F'\t' '$1=="regenerate"{print $2}' "$EG2RUN/producer-idempotence.tsv")
  if [[ "$got" = "$want" ]]; then pass "$desc → $want"
  else fail "$desc → got '${got:-<none>}', want '$want'"; fi
}

# --- keyword arm: matches the producer's bytes, never a case-folded copy -------
eg_verdict C producer-failed 'undefined: CredentialStore' \
  "a CamelCase identifier containing 'Credential' is a compile failure"
eg_verdict C producer-failed 'Error: Certificate has expired' \
  "a capitalised 'Certificate' in a test assertion is a real failure"
eg_verdict C producer-failed 'assert failed: user Not Found' \
  "a capitalised 'Not Found' in a test assertion is a real failure"
eg_verdict C skip 'x509: certificate signed by unknown authority' \
  "a tool's own lowercase 'certificate' diagnostic still skips"
eg_verdict C skip 'remote: Unauthorized' \
  "a capital-U 'Unauthorized' from git still skips"
eg_verdict C skip 'error: unauthorized (token expired)' \
  "a lowercase 'unauthorized' still skips"

# --- keyword arm: the not-found forms are SPECIFIC, never a bare keyword -------
# A bare *"not found"* / *"cannot find"* glob matched ordinary Go/test output — a
# panic message, a testify assertion, any diagnostic naming a missing value — and
# downgraded it to a skip. Only the forms a MISSING TOOL or an unfetchable module
# actually prints are listed: `command not found` (the shell), `executable file
# not found` (Go's os/exec, docker), `cannot find module` (the module resolver).
eg_verdict C producer-failed 'panic: value not found' \
  "a panic naming a value 'not found' is a real failure"
eg_verdict C producer-failed 'assert: item not found in cache' \
  "a test assertion saying an item is 'not found' is a real failure"
eg_verdict C producer-failed 'undefined: NotFoundError' \
  "an identifier named NotFoundError is a compile failure"
eg_verdict C skip 'bash: kubectl: command not found' \
  "a missing tool's 'command not found' still skips"
eg_verdict C skip 'exec: "helm": executable file not found in $PATH' \
  "Go's exec 'executable file not found in \$PATH' skips"
eg_verdict C skip 'go: cannot find module providing package example.com/x' \
  "the module resolver's 'cannot find module providing package' skips"
# `cannot find package "x" in any of:` is deliberately NOT an env gap: in module
# mode the go tool prints it when the package is absent from the tree it was told
# to build — a deleted directory or a wrong import path, i.e. exactly the
# post-merge defect this check must block on. Its network-caused instances always
# carry the transport diagnostic (`dial tcp`, `no such host`, `i/o timeout`,
# proxy/TLS) in the same output, which the arms above already skip on, so leaving
# it blocking costs a credential-less maintainer nothing.
eg_verdict C producer-failed 'main.go:7:2: cannot find package "example.com/x" in any of:' \
  "'cannot find package' is a missing-source compile error, not an env gap"

# --- numeric arm: the shapes a credential-less environment really prints -------
eg_verdict C skip 'fatal: unable to access: The requested URL returned error: 401' \
  "curl --fail's 'returned error: 401' skips"
eg_verdict C skip 'curl: (22) The requested URL returned error: 403' \
  "curl's (22) 'returned error: 403' skips"
eg_verdict C skip 'npm ERR! code E401' \
  "npm's 'code E401' skips"
eg_verdict C skip '{"status":401,"message":"denied"}' \
  "a JSON body carrying \"status\":401 skips"
eg_verdict C skip 'registry rejected the token: status = 401' \
  "'status = 401' skips"
eg_verdict C skip 'oci pull failed, response code: 401' \
  "'response code: 401' skips"
eg_verdict C skip 'unexpected response: 403' \
  "'unexpected response: 403' skips"
eg_verdict C skip 'Error 403: forbidden' \
  "'Error 403: forbidden' skips"
eg_verdict C skip 'gitlab returned 403 for the token' \
  "'returned 403' skips"
eg_verdict C skip '403 Forbidden' \
  "a bare '403 Forbidden' skips"
eg_verdict C skip 'unexpected status code 401 from registry' \
  "'status code 401' skips"
eg_verdict C skip '401' \
  "a bare 401 alone on a line skips"
eg_verdict C skip '   403   ' \
  "a bare 403 alone on a whitespace-padded line skips"

# --- numeric arm: a digit run that is not an HTTP status never skips -----------
eg_verdict C producer-failed 'internal/api/status.go:401:2: undefined: Foo' \
  "an auth-named source file's line number is still a compile failure"
eg_verdict C producer-failed 'error code 4013 while linking' \
  "a 4-digit code beginning 401 is not a 401"
eg_verdict C producer-failed 'test took 0.403s to complete' \
  "a fractional duration containing 403 is not a 403"
eg_verdict C producer-failed 'emitted 4013 records' \
  "a longer number containing 401 is not a 401"
eg_verdict C producer-failed 'FILE401.go:12: parse error' \
  "an E401-shaped token inside a longer word is not npm's code E401"
eg_verdict C producer-failed '--- FAIL: TestStatus403 (0.02s)' \
  "a test name ending in Status403 is a real test failure"

# --- keyword arm: the keyword must be its own WORD, in keyword context ---------
# The keyword globs used to be bare substrings, so a real compile/test failure
# whose output merely CONTAINED one of them — inside a file PATH or a longer
# identifier — was downgraded to a skip, the same false-green class as the bare
# numeric glob above. Two shapes decide it now:
#   * a Go compiler/vet DIAGNOSTIC line (`<path>.go:<line>[:<col>]:`) is a
#     producer failure whatever words it carries — those lines are removed before
#     the keyword arm looks at anything;
#   * a keyword sitting inside a path-or-filename token (one containing `/`, or
#     carrying a `.<letter>` extension) or welded into a longer identifier is not
#     keyword context at all.
# The transport arm is deliberately exempt from the first rule (see is_env_gap):
# a module fetch reports its network/TLS failure ON the importing file's
# diagnostic line, and that is a genuine gap.
eg_verdict C producer-failed 'internal/certificate.go:10:2: undefined: Foo' \
  "a compile error in a file named certificate.go is a real failure"
eg_verdict C producer-failed 'crypto/x509parse.go:5:1: syntax error' \
  "a syntax error in a file named x509parse.go is a real failure"
eg_verdict C producer-failed 'api/unauthorized/handler.go:3:9: undefined: Bar' \
  "a compile error under a directory named unauthorized/ is a real failure"
eg_verdict C producer-failed 'auth/credentials.go:7:4: cannot use x' \
  "a type error in a file named credentials.go is a real failure"
eg_verdict C producer-failed 'open missing.go: No such file or directory' \
  "a missing .go source file in the component tree is a real failure"
eg_verdict C producer-failed 'certificate.go:12:1: expected declaration' \
  "a diagnostic for a keyword-named file with no directory is a real failure"
eg_verdict C producer-failed 'ERROR in module api/unauthorized: build failed' \
  "a keyword inside a path token is not keyword context (no .go: diagnostic)"
eg_verdict C producer-failed 'undefined: x509parse' \
  "a keyword welded into a longer identifier is not keyword context"
eg_verdict C producer-failed 'vet: internal/tls/certificate_test.go:9:2: unused' \
  "a vet diagnostic naming a certificate_test.go file is a real failure"

# --- keyword arm: the genuine environment gaps still skip ----------------------
eg_verdict C skip 'tls: bad certificate' \
  "crypto/tls's 'bad certificate' still skips"
eg_verdict C skip 'error: certificate has expired' \
  "a lowercase 'certificate has expired' still skips"
eg_verdict C skip 'Error response from daemon: unauthorized: incorrect username or password' \
  "a registry's 'unauthorized: incorrect username' still skips"
eg_verdict C skip 'Unable to locate credentials' \
  "a missing-credentials diagnostic still skips"
eg_verdict C skip 'dial tcp 10.0.0.1:443: connect: connection refused' \
  "'connect: connection refused' still skips"
eg_verdict C skip '/usr/bin/env: node: No such file or directory' \
  "a missing TOOL's 'No such file or directory' still skips"
# A module fetch reports its transport failure ON the importing file's diagnostic
# line. Dropping every `.go:<line>:` line before the keyword arm would lose these,
# so the transport markers (`dial tcp`, `no such host`, Go's `x509: ` prefix, …)
# are matched across the WHOLE output, diagnostic lines included.
eg_verdict C skip 'main.go:5:2: example.com/x@v1.0.0: Get "https://proxy.golang.org/x": x509: certificate signed by unknown authority' \
  "a module fetch's TLS failure on a diagnostic line still skips"
eg_verdict C skip 'main.go:5:2: example.com/x@v1.0.0: dial tcp: lookup proxy.golang.org: no such host' \
  "a module fetch's DNS failure on a diagnostic line still skips"
EG_MIXED=$(printf 'internal/api/handler.go:12:2: could not import example.com/x\ngo: module lookup disabled: dial tcp: lookup proxy.golang.org: no such host')
eg_verdict C skip "$EG_MIXED" \
  "a diagnostic line beside a transport line skips on the transport line"

# --- non-UTF-8 producer output: same verdict under C and en_US.UTF-8 -----------
# `printf '\377'` is not valid UTF-8. Everything the verdict depends on sits
# AFTER it, which is exactly what a truncating lowercase pass destroys.
EG_BAD_NUM=$(printf 'go: writing cache: \377\376 unreadable bytes\n401 Unauthorized')
EG_BAD_KEY=$(printf 'link step emitted \377 raw symbol bytes\nunauthorized: token rejected')
EG_BAD_FAIL=$(printf 'link step emitted \377 raw symbol bytes\nmain.go:401: undefined: foo')
# en_US.UTF-8 is the locale that reproduces it on macOS; C.UTF-8 is there because
# the Ubuntu image carries no en_US.UTF-8 (only C / C.utf8 / POSIX), so without it
# the container would only ever run the byte cases under C and the Docker seam
# could not see a multibyte-locale regression at all. A platform missing either
# name falls back to C — the verdict must be the same one anyway.
for loc in C en_US.UTF-8 C.UTF-8; do
  eg_verdict "$loc" skip "$EG_BAD_NUM" \
    "a '401 Unauthorized' after a non-UTF-8 byte skips (LC_ALL=$loc)"
  eg_verdict "$loc" skip "$EG_BAD_KEY" \
    "an 'unauthorized' after a non-UTF-8 byte skips (LC_ALL=$loc)"
  eg_verdict "$loc" producer-failed "$EG_BAD_FAIL" \
    "a compile error after a non-UTF-8 byte still fails (LC_ALL=$loc)"
done
refute "classifying non-UTF-8 output leaks no byte-sequence error to the log" \
  grep -qi 'illegal byte sequence\|invalid byte sequence' "$SANDBOX/eg-last.err"
cd "$SANDBOX"

fi

if t "producer-idempotence.sh — LABEL names the verdict artifact, one file per gate label"; then
# The verdict is read back at Phase 6 (followup-completeness.sh) for the POSTMERGE
# label specifically, and it used to land in one unlabelled file every gate label
# truncated and rewrote — so a midplan gate silently redefined which producer
# acknowledgments the plan owed. LABEL is how gate.sh keeps each label's verdict
# separate; unset (a direct invocation outside a gate) keeps the base name, which is
# what the rest of this suite exercises.
PIL=$SANDBOX/producer-label; PILRUN=$SANDBOX/producer-label-run
mkdir -p "$PIL" "$PILRUN" && cd "$PIL" && git init -q -b main
echo "generated v1" > generated.txt
git add -A && git commit -qm init
PIS="$SKILL_DIR/scripts/producer-idempotence.sh"

LABEL=postmerge RUN=$PILRUN BUILD_CMD="true" REGEN_CMD="echo regen-v2 > generated.txt" \
  "$PIS" > "$SANDBOX/pil-pm.out" 2>&1
expect "LABEL=postmerge writes producer-idempotence-postmerge.tsv" \
  bash -c "awk -F'\t' '\$2==\"dirty-tracked\"' '$PILRUN/producer-idempotence-postmerge.tsv' | grep -q ."
refute "LABEL=postmerge does not write the unlabelled artifact" \
  test -f "$PILRUN/producer-idempotence.tsv"

LABEL=midplan RUN=$PILRUN BUILD_CMD="true" REGEN_CMD="true" \
  "$PIS" > "$SANDBOX/pil-mp.out" 2>&1
expect "LABEL=midplan writes its own file" \
  bash -c "awk -F'\t' '\$2==\"clean\"' '$PILRUN/producer-idempotence-midplan.tsv' | grep -q ."
expect "a later label's run leaves the postmerge verdict intact" \
  bash -c "awk -F'\t' '\$2==\"dirty-tracked\"' '$PILRUN/producer-idempotence-postmerge.tsv' | grep -q ."

# Truncated up front, per label: a re-run with nothing to audit must not leave the
# previous run's verdict standing (present-and-empty is the "ran, audited nothing"
# state followup-completeness.sh distinguishes from absent).
LABEL=postmerge RUN=$PILRUN BUILD_CMD="no build check" REGEN_CMD="no regen command" \
  "$PIS" > "$SANDBOX/pil-pm2.out" 2>&1
expect "a re-run under the same label truncates that label's file" \
  bash -c "test ! -s '$PILRUN/producer-idempotence-postmerge.tsv'"
expect "the truncated file still EXISTS (ran-and-audited-nothing, not absent)" \
  test -f "$PILRUN/producer-idempotence-postmerge.tsv"

# Unset LABEL keeps the base name — direct invocation, no gate.
RUN=$PILRUN BUILD_CMD="true" REGEN_CMD="true" "$PIS" > "$SANDBOX/pil-none.out" 2>&1
expect "an unlabelled invocation still writes producer-idempotence.tsv" \
  bash -c "awk -F'\t' '\$2==\"clean\"' '$PILRUN/producer-idempotence.tsv' | grep -q ."
cd "$SANDBOX"

fi

finish_suite
