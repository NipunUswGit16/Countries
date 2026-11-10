#!/usr/bin/env bash
# record-context.test.sh — tests for scripts/record-context.sh
# TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

if t "record-context.sh — the run-context anchor (upsert into \$RUN/context.env)"; then
# Conversation memory is the least durable component of a many-hour run; the
# scripts and the orchestrator record cross-phase values here, and every phase
# start re-reads the file instead of trusting chat history.
RCS="$SKILL_DIR/scripts/record-context.sh"
RCX=$SANDBOX/record-context

RUN=$RCX bash "$RCS" FOO=bar 2> "$SANDBOX/rcx-1.log"
expect "record-context: first write exits 0" test $? -eq 0
expect "record-context: \$RUN is created if missing (mkdir -p)" test -d "$RCX"
expect "record-context: the pair is appended" grep -qx 'FOO=bar' "$RCX/context.env"

RUN=$RCX bash "$RCS" FOO=baz 2>/dev/null
expect "record-context: an existing key is replaced (upsert, last write wins)" \
  grep -qx 'FOO=baz' "$RCX/context.env"
refute "record-context: the replaced value is gone" grep -qx 'FOO=bar' "$RCX/context.env"
expect "record-context: no duplicate key line after the upsert" \
  bash -c "test \"\$(grep -c '^FOO=' '$RCX/context.env')\" = 1"

RUN=$RCX bash "$RCS" BASE=abc1234 TARGET_REF=feat/x 2>/dev/null
expect "record-context: a multi-pair call lands every pair" \
  bash -c "grep -qx 'BASE=abc1234' '$RCX/context.env' && grep -qx 'TARGET_REF=feat/x' '$RCX/context.env'"
expect "record-context: earlier keys survive later upserts" grep -qx 'FOO=baz' "$RCX/context.env"

RUN=$RCX bash "$RCS" 'EQ=a=b' 2>/dev/null
expect "record-context: only the FIRST '=' splits key from value" grep -qx 'EQ=a=b' "$RCX/context.env"

RUN=$RCX bash "$RCS" FOO=baz 2>/dev/null
expect "record-context: re-recording the same pair is idempotent (single line)" \
  bash -c "test \"\$(grep -c '^FOO=' '$RCX/context.env')\" = 1"

# Bad input is rejected atomically: exit 2, nothing written.
RCXBAD=$SANDBOX/record-context-bad
mkdir -p "$RCXBAD"
RUN=$RCXBAD bash "$RCS" 'lower=case' >/dev/null 2>&1
RCX_RC=$?
if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: a lowercase key is rejected with exit 2"; else fail "record-context: a lowercase key is rejected with exit 2 (rc=$RCX_RC)"; fi
refute "record-context: nothing is written on a rejected key" test -e "$RCXBAD/context.env"

# SQUASH_ON_FINISH — Phase 4's anchor for --squash-on-finish, consumed by Phase 8
# step 6, hours and possibly a compaction later. It needs no special handling, and
# that is what these assert: it is an ordinary upsert key, and the same
# malformed-spelling rule applies to it as to every other key.
RCSQ=$SANDBOX/rc-squash
RUN=$RCSQ bash "$RCS" SQUASH_ON_FINISH=1 >/dev/null 2>&1
expect "record-context: SQUASH_ON_FINISH is an ordinary upsert key" \
  grep -qx 'SQUASH_ON_FINISH=1' "$RCSQ/context.env"
RUN=$RCSQ bash "$RCS" squash_on_finish=1 >/dev/null 2>&1; RCX_RC=$?
if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: a lowercase SQUASH_ON_FINISH is rejected like any other key"; else fail "record-context: a lowercase SQUASH_ON_FINISH is rejected like any other key (rc=$RCX_RC)"; fi
refute "record-context: the rejected lowercase spelling wrote nothing" \
  grep -q 'squash_on_finish' "$RCSQ/context.env"
RUN=$RCXBAD bash "$RCS" GOOD=1 '1BAD=2' >/dev/null 2>&1
RCX_RC=$?
if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: one bad pair rejects the whole call (exit 2)"; else fail "record-context: one bad pair rejects the whole call (rc=$RCX_RC)"; fi
refute "record-context: the good pair in a rejected call is NOT written (all-or-nothing)" \
  test -e "$RCXBAD/context.env"
RUN=$RCXBAD bash "$RCS" 'NOVALUE' >/dev/null 2>&1
RCX_RC=$?
if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: an arg without '=' is rejected with exit 2"; else fail "record-context: an arg without '=' is rejected with exit 2 (rc=$RCX_RC)"; fi
RUN=$RCXBAD bash "$RCS" "NL=line1
line2" >/dev/null 2>&1
RCX_RC=$?
if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: an embedded newline in the value is rejected with exit 2"; else fail "record-context: an embedded newline in the value is rejected with exit 2 (rc=$RCX_RC)"; fi
refute "record-context: the newline reject wrote nothing" test -e "$RCXBAD/context.env"
# A carriage return and a tab are rejected on the same all-or-nothing terms as a
# newline. Every reader of the anchor is `sed -n 's/^KEY=//p'` piped into a shell word
# (SKILL.md's phase-start idiom, plan-completeness.sh, wrong-target-check.sh): a CR
# rides invisibly into the value, so a recorded SHA or path that LOOKS right matches
# nothing and fails every `test -d` downstream — with no character on screen to blame.
# A tab is the same class of invisible corruption, and is the field separator of the
# TSV ledgers these values get carried into. log-spawn.sh and log-resolution.sh
# collapse exactly these three characters for the same reason.
RUN=$RCXBAD bash "$RCS" "CRV=abc"$'\r'"def" > /dev/null 2> "$SANDBOX/rcx-cr.log"
RCX_RC=$?
if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: a carriage return in the value is rejected with exit 2"; else fail "record-context: a carriage return in the value is rejected with exit 2 (rc=$RCX_RC)"; fi
refute "record-context: the CR reject wrote nothing" test -e "$RCXBAD/context.env"
expect "record-context: the CR refusal names the character, not just 'invalid'" \
  grep -qi 'carriage return' "$SANDBOX/rcx-cr.log"
RUN=$RCXBAD bash "$RCS" "TABV=abc"$'\t'"def" > /dev/null 2> "$SANDBOX/rcx-tab.log"
RCX_RC=$?
if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: a tab in the value is rejected with exit 2"; else fail "record-context: a tab in the value is rejected with exit 2 (rc=$RCX_RC)"; fi
refute "record-context: the tab reject wrote nothing" test -e "$RCXBAD/context.env"
expect "record-context: the tab refusal names the character" grep -qi 'tab' "$SANDBOX/rcx-tab.log"
# A trailing CR is the shape a Windows-authored value actually arrives in, and the one
# a `grep -c .`-style check cannot see at all.
RUN=$RCXBAD bash "$RCS" "TRAILV=abc"$'\r' >/dev/null 2>&1
RCX_RC=$?
if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: a TRAILING carriage return is rejected too (the CRLF-authored value)"; else fail "record-context: a TRAILING carriage return is rejected too (rc=$RCX_RC)"; fi
# Non-vacuity: ordinary punctuation and spaces are NOT swept up by the new rejects —
# a branch name, a file path with a space and a URL must all still record.
RCOK=$SANDBOX/rc-ctlchars-ok
RUN=$RCOK bash "$RCS" 'MIGRATION_BRANCH=chore/update-template' 'TEMPLATE_PATH=/tmp/a b/tpl' \
  'COMMON_REPO_PATH=https://example.invalid/x.git?a=b' >/dev/null 2>&1
RCX_RC=$?
if [[ "$RCX_RC" -eq 0 ]]; then pass "record-context: spaces, slashes and punctuation still record (the CR/tab reject is narrow)"; else fail "record-context: spaces, slashes and punctuation still record (rc=$RCX_RC)"; fi
expect "record-context: the space-bearing path landed verbatim" \
  grep -qx 'TEMPLATE_PATH=/tmp/a b/tpl' "$RCOK/context.env"

# LEADING / TRAILING whitespace in a value is refused on the same terms. It is the
# CR's visible cousin and does the same damage: `TARGET=abc123 ` fails every
# `git rev-parse`, ` /tmp/tpl` fails every `test -d`, and `COMMON_MODULES=present `
# stops equalling `present` in plan-completeness.sh's gate — with nothing on screen
# to blame in any of the three. Internal spaces stay legal: a path or a component
# name can carry one, and trimming a value is not this script's business — refusing
# a value nobody meant to record is.
for shape in lead trail both; do
  case $shape in
    lead)  v=" abc" ;;
    trail) v="abc " ;;
    both)  v="  abc  " ;;
  esac
  RUN=$RCXBAD bash "$RCS" "PAD=$v" >/dev/null 2> "$SANDBOX/rcx-pad-$shape.log"
  RCX_RC=$?
  if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: $shape whitespace in the value is rejected with exit 2"; else fail "record-context: $shape whitespace in the value is rejected with exit 2 (rc=$RCX_RC)"; fi
  refute "record-context: the $shape-whitespace reject wrote nothing" test -e "$RCXBAD/context.env"
  expect "record-context: the $shape-whitespace refusal names the whitespace" \
    grep -qi 'whitespace' "$SANDBOX/rcx-pad-$shape.log"
done
# Non-vacuity: internal spaces are untouched by the new reject, and so is an
# empty value (an empty value is a legitimate record — see SQUASH_ON_FINISH).
RCPAD=$SANDBOX/rc-pad-ok
RUN=$RCPAD bash "$RCS" 'TEMPLATE_PATH=/tmp/a b/tpl' 'MIGRATION_BRANCH=' >/dev/null 2>&1
RCX_RC=$?
if [[ "$RCX_RC" -eq 0 ]]; then pass "record-context: internal spaces and an empty value still record (the pad reject is narrow)"; else fail "record-context: internal spaces and an empty value still record (rc=$RCX_RC)"; fi
expect "record-context: the internally-spaced value landed verbatim" \
  grep -qx 'TEMPLATE_PATH=/tmp/a b/tpl' "$RCPAD/context.env"
expect "record-context: the empty value landed as an empty record" \
  grep -qx 'MIGRATION_BRANCH=' "$RCPAD/context.env"

RUN=$RCXBAD bash "$RCS" >/dev/null 2>&1
RCX_RC=$?
if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: zero pairs is rejected with exit 2"; else fail "record-context: zero pairs is rejected with exit 2 (rc=$RCX_RC)"; fi
env -u RUN bash "$RCS" FOO=bar >/dev/null 2>&1
RCX_RC=$?
if [[ "$RCX_RC" -eq 2 ]]; then pass "record-context: a missing RUN exits 2"; else fail "record-context: a missing RUN exits 2 (rc=$RCX_RC)"; fi
refute "record-context: no temp debris is left beside context.env" \
  bash -c "ls '$RCX'/.context.env.* 2>/dev/null | grep -q ."

fi

if t "record-context.sh guards the filter mv, not just the final one"; then
# Regression: the upsert loop did `LC_ALL=C grep -v "^KEY=" "$TMP" > "$TMP.filter"`
# then `mv "$TMP.filter" "$TMP"` with NO check — the only unguarded write in an
# otherwise fully-checked upsert loop. If that mv failed, the OLD unfiltered $TMP
# (still carrying the stale "KEY=..." line) survived untouched, the loop then
# APPENDED the new "KEY=..." line onto it anyway, and the final (checked) mv
# installed that two-line, duplicate-key $TMP as context.env — a context file with
# a stale AND a fresh value for the same key, and no signal anything went wrong.
#
# Simulated via a `mv` shim ahead of PATH: it fails only when its source argument
# ends in `.filter` (exactly the filter-mv's shape) and execs the real `mv`
# otherwise, so the final `mv "$TMP" "$CTX"` — a different source name — is
# unaffected and this is a targeted simulation of the ONE unguarded write, not a
# generic "mv is broken" fixture.
REALMV=$(command -v mv)
mkdir -p "$SANDBOX/mvfail"
cat > "$SANDBOX/mvfail/mv" <<EOF
#!/usr/bin/env bash
case "\$1" in
  *.filter) exit 1 ;;
esac
exec "$REALMV" "\$@"
EOF
chmod +x "$SANDBOX/mvfail/mv"

RCF=$SANDBOX/record-context-filtermv
RUN=$RCF bash "$RCS" FOO=old >/dev/null 2>&1
PATH="$SANDBOX/mvfail:$PATH" RUN=$RCF bash "$RCS" FOO=new \
  >/dev/null 2> "$SANDBOX/rcx-filtermv.log"
RCF_RC=$?
if [[ "$RCF_RC" -eq 2 ]]; then pass "record-context: a failed filter-mv exits 2, not silently continuing"; else fail "record-context: a failed filter-mv exits 2, not silently continuing (rc=$RCF_RC)"; fi
expect "record-context: the filter-mv failure is reported as FAIL: on stderr" \
  grep -q '^FAIL:' "$SANDBOX/rcx-filtermv.log"
expect "record-context: context.env is UNCHANGED — the old value survives" \
  grep -qx 'FOO=old' "$RCF/context.env"
refute "record-context: the new value did NOT land when the filter-mv failed" \
  grep -qx 'FOO=new' "$RCF/context.env"
expect "record-context: no duplicate FOO= line was installed by the failed upsert" \
  bash -c "test \"\$(grep -c '^FOO=' '$RCF/context.env')\" = 1"
refute "record-context: no .filter debris survives the failed mv" \
  bash -c "ls '$RCF'/.context.env.*.filter 2>/dev/null | grep -q ."

# Non-vacuity, at minimum: repeated upserts of the SAME key under the ordinary
# (unshimmed) path never accumulate duplicate lines, however many times repeated.
RCREP=$SANDBOX/record-context-repeat
for v in v1 v2 v3 v4 v5; do
  RUN=$RCREP bash "$RCS" "REP=$v" >/dev/null 2>&1
done
expect "record-context: five repeated upserts of the same key leave exactly one line" \
  bash -c "test \"\$(grep -c '^REP=' '$RCREP/context.env')\" = 1"
expect "record-context: the last of the repeated upserts is the value that stuck" \
  grep -qx 'REP=v5' "$RCREP/context.env"

fi

if t "record-context.sh refuses a write FAILURE, not just a crash"; then
# Regression: the header promised "a crash at any point leaves either the old file
# or the new one, never a truncated in-between" — true for a crash (which never
# reaches the final mv) and FALSE for a failed WRITE, which the final mv then
# COMMITS. Three steps of the read-modify-write were unchecked:
#   * `[ -f "$CTX" ] && cat "$CTX" > "$TMP"`     — the seed copy of every key
#     already recorded. A partial copy silently DROPS earlier phases' keys
#     (SKILL_DIR, TEMPLATE_PATH, TARGET) while the upserted pair still lands.
#   * `grep -v ... > "$TMP.filter" || true`      — `|| true` swallowed grep's
#     exit >=2 (a read/write error) along with the intended exit 1 (no match),
#     so a truncated filter copy was mv'd over $TMP as if it were complete.
#   * `printf '%s\n' "$pair" >> "$TMP"`          — a short append glues two pairs
#     into one unreadable row.
# Proven under `ulimit -f`: exit 0, keys silently gone, a glued row installed as
# context.env. It is the anchor a compacted session re-reads INSTEAD of chat
# memory, so a thinned one is worse than none: no reader can tell a key that was
# never recorded from one this call dropped. Each arm must now exit 2 naming the
# operation, with $CTX untouched.
#
# `ulimit -f` is not portable enough for the suite, so each arm is simulated at
# the SAME step the real failure hits, one step per arm — never a blanket "writes
# are broken" fixture.
RCS="$SKILL_DIR/scripts/record-context.sh"   # set here too: TEST_FILTER may skip block 1

# Arm 1 — the seed copy: $CTX unreadable, so `cat "$CTX" > "$TMP"` fails.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the unreadable-\$CTX seed-copy arm is not exercised: 4 assertions (exit 2, FAIL naming the copy, the existing keys survive, no debris)"
else
RCC=$SANDBOX/record-context-catfail
RUN=$RCC bash "$RCS" KEPT=one ALSO=two >/dev/null 2>&1
chmod 000 "$RCC/context.env"
RUN=$RCC bash "$RCS" FRESH=three >/dev/null 2> "$SANDBOX/rcx-catfail.log"
RCC_RC=$?
chmod 644 "$RCC/context.env"
if [[ "$RCC_RC" -eq 2 ]]; then pass "record-context: an unreadable \$CTX exits 2, not a context.env built from a partial read"; else fail "record-context: an unreadable \$CTX exits 2 (rc=$RCC_RC)"; fi
expect "record-context: the refusal names the copy of the existing file" \
  grep -q '^FAIL: could not copy the existing' "$SANDBOX/rcx-catfail.log"
expect "record-context: the keys recorded by the earlier call all survive" \
  bash -c "grep -qx 'KEPT=one' '$RCC/context.env' && grep -qx 'ALSO=two' '$RCC/context.env'"
refute "record-context: the new pair did NOT land over a half-read seed copy" \
  grep -q '^FRESH=' "$RCC/context.env"
refute "record-context: no temp debris survives the refused seed copy" \
  bash -c "ls '$RCC'/.context.env.* 2>/dev/null | grep -q ."
fi

# Arm 2 — the filter: grep exit >=2 (could not read $TMP / could not write the
# filtered copy) must be told apart from exit 1 (no match). Simulated with a
# `grep` shim ahead of PATH that fails ONLY on `-v` — the filter's exact shape —
# and execs the real grep otherwise, so the key-validation `grep -qE` above is
# untouched. That the refusal below is the FILTER one and not a key-validation
# one is the proof the shim is that narrow.
REALGREP=$(command -v grep)
mkdir -p "$SANDBOX/grepfail"
cat > "$SANDBOX/grepfail/grep" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -v) exit 2 ;;
esac
exec "$REALGREP" "\$@"
EOF
chmod +x "$SANDBOX/grepfail/grep"

RCG=$SANDBOX/record-context-grepfail
RUN=$RCG bash "$RCS" FOO=old >/dev/null 2>&1
PATH="$SANDBOX/grepfail:$PATH" RUN=$RCG bash "$RCS" FOO=new \
  >/dev/null 2> "$SANDBOX/rcx-grepfail.log"
RCG_RC=$?
if [[ "$RCG_RC" -eq 2 ]]; then pass "record-context: grep exit 2 on the filter is a refusal, not 'no match'"; else fail "record-context: grep exit 2 on the filter is a refusal (rc=$RCG_RC)"; fi
expect "record-context: the refusal names the filter step and carries grep's status" \
  bash -c "grep -q '^FAIL: could not filter' '$SANDBOX/rcx-grepfail.log' \
    && grep -q 'grep exit 2' '$SANDBOX/rcx-grepfail.log'"
refute "record-context: the shim is narrow — this is NOT a key-validation refusal" \
  grep -q 'key must match' "$SANDBOX/rcx-grepfail.log"
expect "record-context: context.env is UNCHANGED — the old value survives" \
  grep -qx 'FOO=old' "$RCG/context.env"
refute "record-context: the new value did NOT land on a failed filter" \
  grep -qx 'FOO=new' "$RCG/context.env"
refute "record-context: no .filter debris survives the failed filter" \
  bash -c "ls '$RCG'/.context.env.* 2>/dev/null | grep -q ."

# Arm 3 — the append: `printf >> "$TMP"` fails. Simulated by making $TMP itself
# unwritable at the one moment the script hands its name to another process — an
# `mv` shim that performs the real filter-mv and then drops write permission on
# the destination ($TMP), so the very next statement (the append) is the failing
# one. Root skips: it bypasses the mode bits and the append would succeed.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 0400 stays writable) — the failed-append arm is not exercised: 4 assertions (exit 2, FAIL naming the append, the old value survives, no debris)"
else
RMV=$(command -v mv)
mkdir -p "$SANDBOX/appendfail"
cat > "$SANDBOX/appendfail/mv" <<EOF
#!/usr/bin/env bash
case "\$1" in
  *.filter) "$RMV" "\$@" || exit \$?; chmod 0400 "\$2"; exit 0 ;;
esac
exec "$RMV" "\$@"
EOF
chmod +x "$SANDBOX/appendfail/mv"

RCA=$SANDBOX/record-context-appendfail
RUN=$RCA bash "$RCS" FOO=old >/dev/null 2>&1
PATH="$SANDBOX/appendfail:$PATH" RUN=$RCA bash "$RCS" FOO=new \
  >/dev/null 2> "$SANDBOX/rcx-appendfail.log"
RCA_RC=$?
if [[ "$RCA_RC" -eq 2 ]]; then pass "record-context: a failed append exits 2, not silently continuing to the final mv"; else fail "record-context: a failed append exits 2 (rc=$RCA_RC)"; fi
expect "record-context: the refusal names the append" \
  grep -q '^FAIL: could not append' "$SANDBOX/rcx-appendfail.log"
expect "record-context: context.env is UNCHANGED — the old value survives" \
  grep -qx 'FOO=old' "$RCA/context.env"
refute "record-context: the failed append installed nothing" \
  grep -qx 'FOO=new' "$RCA/context.env"
refute "record-context: no temp debris survives the failed append" \
  bash -c "ls '$RCA'/.context.env.* 2>/dev/null | grep -q ."
fi

# Non-vacuity for all three arms at once: with no shim on PATH and a readable
# $CTX, the same multi-pair upsert this block keeps refusing lands completely.
RCOKW=$SANDBOX/record-context-writes-ok
RUN=$RCOKW bash "$RCS" KEPT=one >/dev/null 2>&1
RUN=$RCOKW bash "$RCS" KEPT=two FRESH=three >/dev/null 2>&1
RCOKW_RC=$?
if [[ "$RCOKW_RC" -eq 0 ]]; then pass "record-context: the unshimmed read-modify-write still exits 0 (the new checks are narrow)"; else fail "record-context: the unshimmed read-modify-write still exits 0 (rc=$RCOKW_RC)"; fi
expect "record-context: the upsert and the new key both landed" \
  bash -c "grep -qx 'KEPT=two' '$RCOKW/context.env' && grep -qx 'FRESH=three' '$RCOKW/context.env'"

fi

finish_suite
