#!/usr/bin/env bash
# intent-check.test.sh — tests for scripts/intent-check.sh
# Includes intent-ledger wiring (sweep before dispatch).
# TEST_FILTER refused (blocks share sequential fixtures).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in intent-check.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "intent-check.sh — failing guards quarantine standing intent before any resolver reads it"; then
# Staleness detection must be mechanical and PRE-dispatch: an entry whose guard
# fails is excluded from resolver input ($RUN/intent-active.md) and surfaced in
# the batched re-confirm set ($RUN/intent-quarantined.md) — never silently
# applied, never silently dropped. Fixture names are invented (genericity):
# the script must key off the guard's exit code, never a recognized path.
IC=$SANDBOX/intent-check
mkdir -p "$IC/run" "$IC/frobnicator" "$IC/wibble" && cd "$IC"
cat > intent.md <<'EOF'
# Standing intent

- 2026-01-10: frobnicator/ is deliberately absent — replaced by the gearbox module
  guard: test ! -e frobnicator
- 2026-02-02: wibble/ is required and must never be dropped
  guard: test -d wibble
- 2026-03-03: the flangebox handler was retired on purpose (no tree-checkable shape)
EOF
RUN=$IC/run INTENT=$IC/intent.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ic.out" 2> "$SANDBOX/ic.log"
expect "intent-check.sh exits 0 (quarantine is a finding, not an error)" test $? -eq 0
expect "all three output files exist" \
  bash -c "test -f '$IC/run/intent-active.md' && test -f '$IC/run/intent-quarantined.md' && test -f '$IC/run/intent-unparseable.md'"

# Failing guard (fact says frobnicator/ is absent; the tree has it) → quarantined.
refute "failing-guard entry is ABSENT from resolver input (intent-active.md)" \
  grep -q 'frobnicator' "$IC/run/intent-active.md"
expect "failing-guard entry is PRESENT in the re-confirm set (intent-quarantined.md)" \
  grep -q 'frobnicator/ is deliberately absent' "$IC/run/intent-quarantined.md"
expect "the quarantined entry keeps its guard line (re-confirm shows what failed)" \
  grep -q 'guard: test ! -e frobnicator' "$IC/run/intent-quarantined.md"
expect "the quarantine is announced on stderr with the failed guard" \
  bash -c "grep -q 'QUARANTINED:' '$SANDBOX/ic.log' && grep -q 'test ! -e frobnicator' '$SANDBOX/ic.log'"

# Passing guard → active, untouched.
expect "passing-guard entry stays active" \
  grep -q 'wibble/ is required and must never be dropped' "$IC/run/intent-active.md"
expect "passing-guard entry keeps its guard line verbatim" \
  grep -q 'guard: test -d wibble' "$IC/run/intent-active.md"
refute "passing-guard entry is not in the re-confirm set" \
  grep -q 'wibble' "$IC/run/intent-quarantined.md"

# Guardless entry → passes through untouched (contradiction rule is its backstop).
expect "guardless entry passes through to resolver input untouched" \
  grep -qF -- '- 2026-03-03: the flangebox handler was retired on purpose (no tree-checkable shape)' \
    "$IC/run/intent-active.md"
refute "guardless entry is never quarantined" \
  grep -q 'flangebox' "$IC/run/intent-quarantined.md"

expect "counts: 2 active" grep -qx 'ACTIVE=2' "$SANDBOX/ic.out"
expect "counts: 1 quarantined" grep -qx 'QUARANTINED=1' "$SANDBOX/ic.out"
expect "counts: 0 unparseable (well-formed file, nothing flagged)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/ic.out"

# No .kairos/intent.md at all (most components today): clean no-op, files still
# exist so the dispatch prompt's unconditional paths always resolve.
RUN=$IC/run-none INTENT=$IC/does-not-exist.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ic-none.out" 2>&1
expect "missing intent file is a clean no-op (exit 0)" test $? -eq 0
expect "missing intent file still writes an (empty) active view" \
  test -f "$IC/run-none/intent-active.md"
expect "missing intent file still writes an (empty) unparseable bucket" \
  test -f "$IC/run-none/intent-unparseable.md"
expect "missing intent file quarantines nothing" grep -qx 'QUARANTINED=0' "$SANDBOX/ic-none.out"
expect "missing intent file flags nothing unparseable" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/ic-none.out"

# A guard that hangs must not hang Phase 5: GUARD_TIMEOUT kills it and the
# entry quarantines (fail-closed — an unfinishable assertion is not a pass).
# Guards run with the run's real tree state, so a wedged guard would otherwise
# block the whole migration with zero diagnostic output.
# The fixture must be IN GRAMMAR to exercise the timeout at all (out-of-grammar
# text is never run, so it cannot hang): a fifo with no writer is a perfectly
# well-formed relative path whose grep blocks forever on open().
mkfifo slowpipe
cat > intent-hang.md <<'EOF'
- 2026-04-04: the doohickey daemon is managed out-of-tree
  guard: grep -q needle slowpipe
EOF
HANG_T0=$(date +%s)
RUN=$IC/run-hang INTENT=$IC/intent-hang.md GUARD_TIMEOUT=2 "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ic-hang.out" 2> "$SANDBOX/ic-hang.log"
HANG_RC=$?
HANG_ELAPSED=$(( $(date +%s) - HANG_T0 ))
expect "a hanging guard still exits 0 (quarantine is a finding, not an error)" test "$HANG_RC" -eq 0
expect "a hanging guard is killed by GUARD_TIMEOUT (finished in ${HANG_ELAPSED}s, not 60)" \
  test "$HANG_ELAPSED" -lt 30
expect "the hanging-guard entry is quarantined, not active" \
  bash -c "grep -q 'doohickey' '$IC/run-hang/intent-quarantined.md' && ! grep -q 'doohickey' '$IC/run-hang/intent-active.md'"
expect "the hang quarantine is announced on stderr" grep -q 'QUARANTINED:' "$SANDBOX/ic-hang.log"
refute "no shell job-control noise leaks to stderr (Alarm clock)" \
  grep -qi 'alarm' "$SANDBOX/ic-hang.log"

# Negation must not launder a guard that never ANSWERED. A killed grep, or one
# whose target cannot be read, is not "false" — it is "unknown", and `!` unknown
# is still unknown. Without this rule the fail-closed timeout above inverts into
# fail-open the moment the same guard is written with a leading `!`.
cat > intent-neg-hang.md <<'EOF'
- 2026-04-05: the whatsit cache no longer mentions the doohickey
  guard: ! grep -q doohickey slowpipe
EOF
RUN=$IC/run-neg INTENT=$IC/intent-neg-hang.md GUARD_TIMEOUT=2 "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ic-neg.out" 2> "$SANDBOX/ic-neg.log"
expect "a NEGATED guard killed by GUARD_TIMEOUT quarantines, never activates" \
  bash -c "grep -q 'whatsit' '$IC/run-neg/intent-quarantined.md' && ! grep -q 'whatsit' '$IC/run-neg/intent-active.md'"
expect "counts: the unanswerable negated guard is QUARANTINED=1" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/ic-neg.out"
cat > intent-neg-missing.md <<'EOF'
- 2026-04-06: the gubbins log no longer mentions the doohickey
  guard: ! grep -q doohickey no-such-file.txt
EOF
RUN=$IC/run-neg2 INTENT=$IC/intent-neg-missing.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ic-neg2.out" 2> "$SANDBOX/ic-neg2.log"
expect "a NEGATED guard whose target cannot be read quarantines, never activates" \
  bash -c "grep -q 'gubbins' '$IC/run-neg2/intent-quarantined.md' && ! grep -q 'gubbins' '$IC/run-neg2/intent-active.md'"
expect "counts: the unreadable-target negated guard is QUARANTINED=1" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/ic-neg2.out"
cd "$SANDBOX"

fi

if t "intent-check.sh — a guard never reaches a shell (a committed intent file cannot execute code)"; then
# The threat model that shapes the whole guard runner: `.kairos/intent.md` is a
# COMMITTED file. Cloning a component and running the skill is enough to evaluate
# every guard in it, and the person who wrote the guard need not be the person
# running the migration — so a guard handed to a shell is arbitrary code execution
# with no consent step anywhere. Guards are parsed against a fixed grammar and the
# allowlisted binary is invoked directly; every fixture below tries to leave a
# witness file behind, and the assertion is that no witness ever exists.
IX=$SANDBOX/intent-exec
mkdir -p "$IX/run" "$IX/wibble" && cd "$IX"
cat > intent.md <<'EOF'
- 2026-01-05: the sprocket cache is rebuilt out of band
  guard: $(touch pwned-cmdsub)
- 2026-01-06: the grommet index is authoritative
  guard: test -d wibble; touch pwned-semicolon
- 2026-01-07: the flange table is generated
  guard: test -d wibble && touch pwned-andand
- 2026-01-08: the widget registry is external
  guard: test -d wibble > pwned-redirect
- 2026-01-09: the doodad list is curated by hand
  guard: `touch pwned-backtick`
EOF
RUN=$IX/run INTENT=$IX/intent.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ix.out" 2> "$SANDBOX/ix.log"
expect "an out-of-grammar guard still exits 0 (a finding, not an error)" test $? -eq 0
for w in pwned-cmdsub pwned-semicolon pwned-andand pwned-redirect pwned-backtick; do
  refute "the guard's side effect '$w' was never executed" test -e "$IX/$w"
done
for e in sprocket grommet flange widget doodad; do
  refute "the '$e' entry never reaches resolver input (its guard never ran)" \
    grep -q "$e" "$IX/run/intent-active.md"
  expect "the '$e' entry lands in intent-unparseable.md, fail-closed" \
    grep -q "$e" "$IX/run/intent-unparseable.md"
done
expect "one UNPARSEABLE: stderr line per entry with an unreadable guard (5 total)" \
  bash -c "test \"\$(grep -c '^UNPARSEABLE:' '$SANDBOX/ix.log')\" -eq 5"
expect "the stderr reason names the guard grammar, so the fix is obvious" \
  grep -qi 'grammar' "$SANDBOX/ix.log"
expect "counts: ACTIVE=0 (nothing with an unreadable guard steers a resolution)" \
  grep -qx 'ACTIVE=0' "$SANDBOX/ix.out"
expect "counts: QUARANTINED=0 (an unreadable guard is not a stale fact — different bucket)" \
  grep -qx 'QUARANTINED=0' "$SANDBOX/ix.out"
expect "counts: UNPARSEABLE=5" grep -qx 'UNPARSEABLE=5' "$SANDBOX/ix.out"
cd "$SANDBOX"

fi

if t "intent-check.sh — the allowlisted guard grammar vets in both directions"; then
# Removing the shell must not remove the vetting. Every accepted form is exercised
# here twice — once where the tree agrees with the fact (stays active) and once
# where it does not (quarantined) — because a grammar that only ever returns "in
# grammar, passing" would have kept this suite green while vetting nothing.
IG=$SANDBOX/intent-grammar
mkdir -p "$IG/run" "$IG/run-fail" "$IG/gizmo" && cd "$IG"
: > empty.txt
printf 'body\n' > plain.txt
printf 'the sprocket is calibrated\n' > haystack.txt
printf 'axb\n' > dotted.txt
cat > intent-pass.md <<'EOF'
- 2026-05-01: plain.txt is generated on every build and must exist
  guard: test -e plain.txt
- 2026-05-02: gizmo/ is required and must never be dropped
  guard: test -d gizmo
- 2026-05-03: plain.txt is a regular file, never a directory
  guard: test -f plain.txt
- 2026-05-04: the whatsit index is deliberately absent
  guard: test ! -e whatsit.txt
- 2026-05-05: negation also reads in front of the assertion
  guard: ! test -e whatsit.txt
- 2026-05-06: plain.txt is never empty
  guard: test -s plain.txt
- 2026-05-07: the sprocket calibration note lives in haystack.txt
  guard: grep -q calibrated haystack.txt
- 2026-05-08: a basic regular expression is the default pattern dialect
  guard: grep -q a.b dotted.txt
- 2026-05-09: -F makes the pattern a fixed string
  guard: ! grep -qF a.b dotted.txt
- 2026-05-10: the combined flag spelling is accepted
  guard: grep -Fq axb dotted.txt
- 2026-05-11: and the split flag spelling too
  guard: grep -q -F axb dotted.txt
- 2026-05-12: haystack.txt no longer mentions the flywheel
  guard: ! grep -q flywheel haystack.txt
- 2026-05-13: an entry may carry several guards, and all of them hold
  guard: test -e plain.txt
  guard: grep -q calibrated haystack.txt
EOF
RUN=$IG/run INTENT=$IG/intent-pass.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ig.out" 2> "$SANDBOX/ig.log"
expect "in-grammar guards exit 0" test $? -eq 0
expect "counts: ACTIVE=13 (every accepted form, holding)" grep -qx 'ACTIVE=13' "$SANDBOX/ig.out"
expect "counts: QUARANTINED=0" grep -qx 'QUARANTINED=0' "$SANDBOX/ig.out"
expect "counts: UNPARSEABLE=0 (nothing in the grammar is mistaken for malformed)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/ig.out"
for d in 01 02 03 04 05 06 07 08 09 10 11 12 13; do
  expect "the 2026-05-$d entry stays in resolver input" \
    grep -q "2026-05-$d" "$IG/run/intent-active.md"
done

# The same forms, each against a tree that contradicts the fact.
cat > intent-fail.md <<'EOF'
- 2026-06-01: the doodah manifest must exist
  guard: test -e doodah.txt
- 2026-06-02: gizmo/ is not a regular file
  guard: test -f gizmo
- 2026-06-03: gizmo/ is deliberately absent
  guard: test ! -e gizmo
- 2026-06-04: plain.txt is deliberately absent
  guard: ! test -e plain.txt
- 2026-06-05: empty.txt always carries content
  guard: test -s empty.txt
- 2026-06-06: haystack.txt mentions the flywheel
  guard: grep -q flywheel haystack.txt
- 2026-06-07: dotted.txt carries the literal a.b
  guard: grep -qF a.b dotted.txt
- 2026-06-08: haystack.txt no longer mentions the sprocket
  guard: ! grep -q sprocket haystack.txt
- 2026-06-09: one failing guard out of two is enough to quarantine
  guard: test -e plain.txt
  guard: test -e doodah.txt
EOF
RUN=$IG/run-fail INTENT=$IG/intent-fail.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/igf.out" 2> "$SANDBOX/igf.log"
expect "counts: QUARANTINED=9 (every accepted form, contradicted)" \
  grep -qx 'QUARANTINED=9' "$SANDBOX/igf.out"
expect "counts: ACTIVE=0 (a contradicted fact never reaches a resolver)" \
  grep -qx 'ACTIVE=0' "$SANDBOX/igf.out"
expect "counts: UNPARSEABLE=0 (a failing guard is not a malformed one)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/igf.out"
expect "one QUARANTINED: stderr line per contradicted entry (9 total)" \
  bash -c "test \"\$(grep -c '^QUARANTINED:' '$SANDBOX/igf.log')\" -eq 9"
for d in 01 02 03 04 05 06 07 08 09; do
  expect "the 2026-06-$d entry is quarantined, not active" \
    bash -c "grep -q '2026-06-$d' '$IG/run-fail/intent-quarantined.md' && ! grep -q '2026-06-$d' '$IG/run-fail/intent-active.md'"
done
cd "$SANDBOX"

fi

if t "intent-check.sh — anything outside the guard grammar fails closed, however innocent"; then
# Fail-closed is the whole point: the parser is not asked to judge intent, only
# membership. Most of these are harmless things a maintainer might reasonably write;
# a few are the exploit. They get the same answer, and none of them runs.
IO=$SANDBOX/intent-outside
mkdir -p "$IO/run" "$IO/web" && cd "$IO"
printf 'body\n' > file.txt
BAD=(
  'ls web/'                        # innocent: an unknown command is still unknown
  'sleep 60'                       # ran verbatim before the grammar existed
  'test -e /etc/passwd'            # absolute path — guards assert the component tree
  'test -e ../outside.txt'         # .. escape
  'test -e web/../../outside.txt'  # .. escape mid-path
  'test -e web/*'                  # a glob needs a shell to expand
  'test -x file.txt'               # operator outside the grammar
  'test -e "file.txt"'             # quoting needs a shell
  'test -e file.txt -o -e web'     # too many tokens
  'test'                           # no operands at all
  'grep -qr needle web'            # -r is deliberately out of grammar
  'grep -qi needle file.txt'       # -i likewise
  'grep -qE fee|fie file.txt'      # ERE alternation is unreadable next to a pipeline
  'grep needle file.txt'           # not quiet: a guard reads status, not output
  'grep -q needle'                 # no path
  'FOO=1 test -e file.txt'         # env-var prefix
  'test -e file.txt || true'       # shell operator
  '! ls web/'                      # negation does not launder the command
)
: > intent.md
BAD_N=0
for g in "${BAD[@]}"; do
  BAD_N=$((BAD_N + 1))
  printf -- '- 2026-07-01: out-of-grammar fixture %02d\n  guard: %s\n' "$BAD_N" "$g" >> intent.md
done
OG_T0=$(date +%s)
RUN=$IO/run INTENT=$IO/intent.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/io.out" 2> "$SANDBOX/io.log"
expect "out-of-grammar guards exit 0 (findings, not errors)" test $? -eq 0
OG_ELAPSED=$(( $(date +%s) - OG_T0 ))
expect "nothing was executed, so the 'sleep 60' fixture cost nothing (${OG_ELAPSED}s)" \
  test "$OG_ELAPSED" -lt 30
for g in "${BAD[@]}"; do
  expect "guard '$g' is refused verbatim into intent-unparseable.md" \
    grep -qF -- "  guard: $g" "$IO/run/intent-unparseable.md"
done
expect "counts: UNPARSEABLE=$BAD_N (one finding per entry, not per guard token)" \
  grep -qx "UNPARSEABLE=$BAD_N" "$SANDBOX/io.out"
expect "counts: ACTIVE=0 (no fixture reaches resolver input)" \
  grep -qx 'ACTIVE=0' "$SANDBOX/io.out"
expect "counts: QUARANTINED=0 (an unreadable guard is not a stale fact)" \
  grep -qx 'QUARANTINED=0' "$SANDBOX/io.out"
refute "no out-of-grammar entry leaks into intent-active.md" \
  grep -q 'out-of-grammar fixture' "$IO/run/intent-active.md"
expect "every finding names the offending guard and why it was refused" \
  bash -c "test \"\$(grep -c '^UNPARSEABLE:' '$SANDBOX/io.log')\" -eq $BAD_N && grep -q 'grammar' '$SANDBOX/io.log'"
cd "$SANDBOX"

fi

if t "intent-check.sh — a spaced thematic break '- - -' is structure, never a phantom entry"; then
# A CommonMark thematic break may space out its dashes ('- - -'). Because it begins
# with '- ', the bullet arm used to take it and parse a phantom '- -' fact: an extra
# ACTIVE entry that is garbage in resolver input, and — when the break sits between a
# real entry and its indented guard — one that strands the entry GUARDLESS and steals
# its guard, a silent de-guard. It must be structure, exactly like the bare '---'.
IT=$SANDBOX/intent-thematic
mkdir -p "$IT/run" "$IT/alpha" && cd "$IT"
printf '%s\n' \
  '# Standing intent' \
  '- 2026-01-01: alpha/ is required' \
  '  guard: test -d alpha' \
  '- - -' \
  '- 2026-02-02: beta is a standing fact' \
  > intent.md
RUN=$IT/run INTENT=$IT/intent.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/it.out" 2> "$SANDBOX/it.log"
expect "intent-check.sh exits 0" test $? -eq 0
# The discriminator: exactly TWO active entries (alpha, beta). With the bug the
# phantom '- -' from the break is a THIRD, guardless, ACTIVE entry.
expect "counts: ACTIVE=2 (the thematic break is not an entry)" \
  grep -qx 'ACTIVE=2' "$SANDBOX/it.out"
expect "counts: UNPARSEABLE=0 (a thematic break is not a finding)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/it.out"
expect "counts: QUARANTINED=0" grep -qx 'QUARANTINED=0' "$SANDBOX/it.out"
# Both real facts survive into resolver input; the guarded one's guard passed.
expect "the guarded entry (guard passes) is active" \
  grep -qxF -- '- 2026-01-01: alpha/ is required' "$IT/run/intent-active.md"
expect "the guardless entry is active" \
  grep -qxF -- '- 2026-02-02: beta is a standing fact' "$IT/run/intent-active.md"
cd "$SANDBOX"

fi

if t "intent-check.sh — unparseable shapes get their own bucket, excluded from resolver input"; then
# The narrow rule: exactly two column-0 shapes are findings (wrong bullet style,
# orphaned guard). Everything else — headings, blanks, prose, thematic breaks —
# stays structure. Unparseable lines never reach intent-active.md.
IU=$SANDBOX/intent-unparse
mkdir -p "$IU/run" "$IU/gadget" && cd "$IU"
TAB=$(printf '\t')
printf '%s\n' \
  '# Standing intent' \
  '' \
  'Plain prose paragraph explaining the file.' \
  '---' \
  '- 2026-01-01: gadget/ is required' \
  'guard: test -d gadget' \
  '* 2026-02-02: star-bullet promotion' \
  '+ 2026-03-03: plus-bullet promotion' \
  '-2026-04-04: hyphen with no space' \
  "${TAB}- 2026-05-05: tab-indented stray bullet" \
  '- 2026-06-06: entry with a nested tab list' \
  "${TAB}- nested tab item inside an entry" \
  > intent.md
RUN=$IU/run INTENT=$IU/intent.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/iu.out" 2> "$SANDBOX/iu.log"
expect "unparseable findings still exit 0 (findings, not errors)" test $? -eq 0

# Orphaned guard: the highest-value catch. The guard line is a finding, and the
# entry above it — the one the guard was meant to vet — is excluded from the
# active view too (its guard never ran), each reported, never silent structure.
refute "orphaned guard line is ABSENT from resolver input (intent-active.md)" \
  grep -q 'guard: test -d gadget' "$IU/run/intent-active.md"
refute "orphaned guard line is not quarantine either (different cause, different bucket)" \
  grep -q 'test -d gadget' "$IU/run/intent-quarantined.md"
expect "orphaned guard line lands verbatim in intent-unparseable.md" \
  grep -qF 'guard: test -d gadget' "$IU/run/intent-unparseable.md"
expect "orphaned guard is reported on stderr with its reason" \
  bash -c "grep 'UNPARSEABLE:' '$SANDBOX/iu.log' | grep 'test -d gadget' | grep -qi 'orphaned guard'"
refute "the entry above the orphaned guard must NOT appear in intent-active.md (guard never ran)" \
  grep -qF -- '- 2026-01-01: gadget/ is required' "$IU/run/intent-active.md"
expect "the entry above the orphaned guard lands in intent-unparseable.md, awaiting re-confirm" \
  grep -qF -- '- 2026-01-01: gadget/ is required' "$IU/run/intent-unparseable.md"
expect "the excluded entry is reported on stderr with its reason" \
  bash -c "grep 'UNPARSEABLE:' '$SANDBOX/iu.log' | grep 'gadget/ is required' | grep -qi 'orphaned guard'"

# Each wrong bullet style is a finding, excluded from the active view.
for b in '* 2026-02-02: star-bullet promotion' \
         '+ 2026-03-03: plus-bullet promotion' \
         '-2026-04-04: hyphen with no space' \
         "${TAB}- 2026-05-05: tab-indented stray bullet"; do
  expect "wrong bullet '$b' lands verbatim in intent-unparseable.md" \
    grep -qF -- "$b" "$IU/run/intent-unparseable.md"
  refute "wrong bullet '$b' is ABSENT from resolver input" \
    grep -qF -- "$b" "$IU/run/intent-active.md"
done
expect "each finding gets one UNPARSEABLE: stderr line (6 total)" \
  bash -c "test \"\$(grep -c '^UNPARSEABLE:' '$SANDBOX/iu.log')\" -eq 6"

# Count correctness: 6 findings (4 wrong bullets, the orphaned guard, and the
# entry it stranded), 1 real entry, nothing quarantined.
expect "counts: UNPARSEABLE=6" grep -qx 'UNPARSEABLE=6' "$SANDBOX/iu.out"
expect "counts: ACTIVE=1 (structure and findings are not entries)" \
  grep -qx 'ACTIVE=1' "$SANDBOX/iu.out"
expect "counts: QUARANTINED=0" grep -qx 'QUARANTINED=0' "$SANDBOX/iu.out"

# Non-regression: legitimate structure still passes through untouched.
expect "heading stays structure in the active view" \
  grep -qx '# Standing intent' "$IU/run/intent-active.md"
expect "prose paragraph stays structure in the active view" \
  grep -qx 'Plain prose paragraph explaining the file.' "$IU/run/intent-active.md"
expect "thematic break (---) stays structure, not a bullet-like marker" \
  grep -qx -- '---' "$IU/run/intent-active.md"
refute "no structure leaks into the unparseable bucket" \
  bash -c "grep -Eq '^(# Standing|Plain prose|---$)' '$IU/run/intent-unparseable.md'"
expect "a tab-indented bullet INSIDE an entry is a nested-list continuation, kept with its entry" \
  bash -c "grep -qF -- '${TAB}- nested tab item inside an entry' '$IU/run/intent-active.md' && ! grep -qF 'nested tab item' '$IU/run/intent-unparseable.md'"
cd "$SANDBOX"

fi

if t "intent-check.sh — a NUL byte cannot smuggle a truncated guard past the parser"; then
# bash `read` stops at a NUL: `guard: test -e go.mod<NUL>; touch W` used to parse as
# the in-grammar `test -e go.mod`, so the entry went ACTIVE — and the copy written to
# intent-active.md was NOT the file's bytes, breaking the "verbatim" contract the
# quarantine/re-confirm loop rests on. Nothing was executed, but a file whose bytes
# the parser cannot see is a file that cannot be vetted, so it must fail CLOSED.
IN=$SANDBOX/intent-nul
mkdir -p "$IN/run" && cd "$IN"
: > go.mod
{ printf -- '# Standing intent\n\n'
  printf -- '- 2026-08-01: go.mod is generated and must exist\n'
  printf -- '  guard: test -e go.mod'; printf '\000'; printf -- '; touch pwned-nul\n'
  printf -- '- 2026-08-02: an innocent neighbour entry\n  guard: test -e go.mod\n'
} > intent.md
NUL_TOTAL=$(( $(wc -c < intent.md) ))
NUL_STRIPPED=$(( $(LC_ALL=C tr -d '\000' < intent.md | wc -c) ))
expect "fixture self-check: the intent file really carries a NUL byte" \
  test "$NUL_TOTAL" -ne "$NUL_STRIPPED"
RUN=$IN/run INTENT=$IN/intent.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/in.out" 2> "$SANDBOX/in.log"
expect "a NUL-carrying intent file is still a finding, not an error (exit 0)" test $? -eq 0
expect "counts: ACTIVE=0 — an unreadable file vets nothing (fail closed)" \
  grep -qx 'ACTIVE=0' "$SANDBOX/in.out"
expect "counts: QUARANTINED=0 (a NUL is not a stale fact)" \
  grep -qx 'QUARANTINED=0' "$SANDBOX/in.out"
expect "counts: UNPARSEABLE=1 — the whole file is one finding" \
  grep -qx 'UNPARSEABLE=1' "$SANDBOX/in.out"
refute "the truncated guard's entry never reaches resolver input" \
  grep -q '2026-08-01' "$IN/run/intent-active.md"
refute "no NUL-file entry rides into resolver input at all" \
  grep -q '2026-08-0' "$IN/run/intent-active.md"
refute "not even the file's structure lines are laundered into the active view" \
  grep -q 'Standing intent' "$IN/run/intent-active.md"
refute "the truncated guard string never appears in intent-active.md (verbatim contract)" \
  grep -q 'test -e go.mod' "$IN/run/intent-active.md"
refute "the guard's side effect was never executed" test -e "$IN/pwned-nul"
expect "the finding names NUL bytes, so the repair is obvious" \
  bash -c "grep -q '^UNPARSEABLE:' '$SANDBOX/in.log' && grep -qi 'NUL' '$SANDBOX/in.log'"
expect "the finding is recorded in intent-unparseable.md too" \
  bash -c "grep -qi 'NUL' '$IN/run/intent-unparseable.md'"
# Every output file must be byte-clean: they are read back as text by Phase 5 and
# quoted into a re-confirm table, so a NUL must never reach them.
for f in intent-active.md intent-quarantined.md intent-unparseable.md; do
  expect "$f is byte-clean (no NUL survives into the outputs)" \
    bash -c "test \"\$(wc -c < '$IN/run/$f')\" -eq \"\$(LC_ALL=C tr -d '\\000' < '$IN/run/$f' | wc -c)\""
done
cd "$SANDBOX"

fi

if t "intent-check.sh — the path charset is locale-independent (same verdict on every machine)"; then
# `*[!A-Za-z0-9._/+@-]*` is a COLLATION range: under en_US.UTF-8 `wéb` fell inside
# it (in grammar), under LC_ALL=C outside it (unparseable). Same committed intent
# file, different bucket on macOS and in the Ubuntu container — a verdict that
# depends on the operator's environment is not a verdict. The documented charset is
# ASCII, so non-ASCII must be out of grammar EVERYWHERE.
IL=$SANDBOX/intent-locale
mkdir -p "$IL" "$IL/wéb" "$IL/web" && cd "$IL"
printf -- '- 2026-08-03: the wéb directory is required\n  guard: test -d wéb\n' > intent-nonascii.md
printf -- '- 2026-08-04: the web directory is required\n  guard: test -d web\n' > intent-ascii.md
LOC_REF=""
for L in C C.UTF-8 en_US.UTF-8 POSIX; do
  SAFE=$(printf '%s' "$L" | tr -c 'A-Za-z0-9' '_')
  LC_ALL=$L RUN=$IL/run-$SAFE INTENT=$IL/intent-nonascii.md \
    "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/il-$SAFE.out" 2> "$SANDBOX/il-$SAFE.log"
  expect "LC_ALL=$L: a non-ASCII path is OUT of grammar (documented charset is ASCII)" \
    grep -qx 'UNPARSEABLE=1' "$SANDBOX/il-$SAFE.out"
  expect "LC_ALL=$L: the non-ASCII entry never reaches resolver input" \
    grep -qx 'ACTIVE=0' "$SANDBOX/il-$SAFE.out"
  expect "LC_ALL=$L: the reason names the charset, not the locale" \
    grep -q 'A-Za-z0-9._/+@-' "$SANDBOX/il-$SAFE.log"
  if [[ -z "$LOC_REF" ]]; then LOC_REF=$SAFE; else
    expect "LC_ALL=$L verdict is byte-identical to LC_ALL=C's" \
      cmp -s "$SANDBOX/il-$LOC_REF.out" "$SANDBOX/il-$SAFE.out"
  fi
  # Positive control: pinning the charset check must not push ASCII out of grammar.
  LC_ALL=$L RUN=$IL/ok-$SAFE INTENT=$IL/intent-ascii.md \
    "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/ila-$SAFE.out" 2>&1
  expect "LC_ALL=$L: an ASCII path is still in grammar and still evaluated" \
    grep -qx 'ACTIVE=1' "$SANDBOX/ila-$SAFE.out"
done
# The charset is an allowlist of literal characters, so every ASCII byte outside it
# is refused whatever the locale says about collation.
mkdir -p "$IL/run-chars"
: > intent-chars.md
CHAR_N=0
for p in 'we b.txt' 'we[b].txt' 'we*b.txt' 'wé b' 'wéb' 'web!' 'web,txt' 'web:txt' 'we~b'; do
  CHAR_N=$((CHAR_N + 1))
  printf -- '- 2026-08-05: charset fixture %02d\n  guard: test -e %s\n' "$CHAR_N" "$p" >> intent-chars.md
done
for L in C en_US.UTF-8; do
  SAFE=$(printf '%s' "$L" | tr -c 'A-Za-z0-9' '_')
  LC_ALL=$L RUN=$IL/run-chars-$SAFE INTENT=$IL/intent-chars.md \
    "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/ilc-$SAFE.out" 2>&1
  expect "LC_ALL=$L: every off-charset path is refused (UNPARSEABLE=$CHAR_N)" \
    grep -qx "UNPARSEABLE=$CHAR_N" "$SANDBOX/ilc-$SAFE.out"
done
cd "$SANDBOX"

fi

if t "intent-check.sh — GUARD_TIMEOUT is validated at startup, never silently disabled"; then
# GUARD_TIMEOUT is the only thing standing between a fifo guard and a wedged Phase
# 5, and it reached `perl -e 'alarm shift'` unchecked: `alarm abc` and `alarm 0` both
# mean NO ALARM, so a typo in the env var silently removed the timeout the header
# promises. The env var is part of the script's contract, so an invalid value is a
# loud startup refusal, not a quiet default.
IT=$SANDBOX/intent-timeout
mkdir -p "$IT" && cd "$IT"
printf -- '- 2026-08-06: go.mod is generated\n  guard: test -e go.mod\n' > intent.md
: > go.mod
BAD_T_N=0
for bt in abc 0 -1 -5 1.5 '10s' '' ' ' '3601' '99999' '+10' '1 2' '0x10' 'e9'; do
  BAD_T_N=$((BAD_T_N + 1))
  case "$bt" in '') continue ;; esac   # empty means "unset" — the default applies
  RUN=$IT/run-bad-$BAD_T_N GUARD_TIMEOUT="$bt" INTENT=$IT/intent.md \
    "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/it-$BAD_T_N.out" 2> "$SANDBOX/it-$BAD_T_N.log"
  expect "GUARD_TIMEOUT='$bt' fails loudly at startup (exit 2)" test $? -eq 2
  expect "GUARD_TIMEOUT='$bt' says what is wrong on stderr" \
    bash -c "grep -q 'GUARD_TIMEOUT' '$SANDBOX/it-$BAD_T_N.log'"
  refute "GUARD_TIMEOUT='$bt' vets nothing — no active view is produced" \
    test -e "$IT/run-bad-$BAD_T_N/intent-active.md"
done
for gt in 1 2 10 60 3600; do
  RUN=$IT/run-ok-$gt GUARD_TIMEOUT="$gt" INTENT=$IT/intent.md \
    "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/it-ok-$gt.out" 2>&1
  expect "GUARD_TIMEOUT=$gt is accepted (exit 0)" test $? -eq 0
  expect "GUARD_TIMEOUT=$gt still vets the entry" grep -qx 'ACTIVE=1' "$SANDBOX/it-ok-$gt.out"
done
RUN=$IT/run-unset INTENT=$IT/intent.md env -u GUARD_TIMEOUT \
  "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/it-unset.out" 2>&1
expect "an unset GUARD_TIMEOUT keeps the documented default (exit 0)" test $? -eq 0
RUN=$IT/run-empty GUARD_TIMEOUT= INTENT=$IT/intent.md \
  "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/it-empty.out" 2>&1
expect "an EMPTY GUARD_TIMEOUT reads as unset, not as invalid (exit 0)" test $? -eq 0
# The whole point of validating: the alarm the header promises must actually be
# armed. A fifo guard under a VALID timeout finishes; under an invalid one the run
# refuses to start rather than hanging here forever.
mkfifo blockpipe
printf -- '- 2026-08-07: the doodad cache is external\n  guard: grep -q needle blockpipe\n' > intent-fifo.md
FIFO_T0=$(date +%s)
RUN=$IT/run-fifo GUARD_TIMEOUT=abc INTENT=$IT/intent-fifo.md \
  "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/it-fifo.out" 2> "$SANDBOX/it-fifo.log" &
FIFO_PID=$!
FIFO_WAIT=0
while kill -0 "$FIFO_PID" 2>/dev/null && [[ "$FIFO_WAIT" -lt 15 ]]; do
  sleep 1; FIFO_WAIT=$((FIFO_WAIT + 1))
done
if kill -0 "$FIFO_PID" 2>/dev/null; then
  kill -9 "$FIFO_PID" 2>/dev/null
  wait "$FIFO_PID" 2>/dev/null
  fail "an invalid GUARD_TIMEOUT must not let a fifo guard hang the run (still running after ${FIFO_WAIT}s)"
else
  wait "$FIFO_PID" 2>/dev/null
  FIFO_RC=$?
  if [[ "$FIFO_RC" -eq 2 ]]; then
    pass "an invalid GUARD_TIMEOUT refuses to start instead of hanging on a fifo guard"
  else
    fail "an invalid GUARD_TIMEOUT refuses to start instead of hanging on a fifo guard (exit $FIFO_RC, want 2)"
  fi
fi
cd "$SANDBOX"

fi

if t "intent-check.sh — ACTION=parse-only answers grammar questions without touching the tree"; then
# The doc-example lint below must judge examples with the SAME parser the runner
# uses, or it drifts into a second, laxer grammar (it did: a regex that accepted any
# line starting `test`/`grep`). parse-only exposes the parser and nothing else: no
# RUN, no intent file, no guard evaluated, no output file written.
IP=$SANDBOX/intent-parse
mkdir -p "$IP" && cd "$IP"
printf '%s\n' \
  'test -e go.mod' \
  '! grep -qF needle absent-file.txt' \
  '' \
  '   ' \
  'ls web/' \
  'test -e /etc/passwd' \
  '$(touch pwned-parse)' \
  > guards.txt
env -u RUN ACTION=parse-only "$SKILL_DIR/scripts/intent-check.sh" \
  < guards.txt > "$SANDBOX/ip.out" 2> "$SANDBOX/ip.log"
expect "parse-only exits 1 when any input line is out of grammar" test $? -eq 1
refute "parse-only needs no RUN dir (it is a pure grammar question)" \
  grep -qi 'RUN dir required' "$SANDBOX/ip.log"
expect "an in-grammar guard reports ok, tab-separated" \
  grep -qxF "$(printf 'ok\ttest -e go.mod')" "$SANDBOX/ip.out"
expect "a negated in-grammar guard reports ok" \
  grep -qxF "$(printf 'ok\t! grep -qF needle absent-file.txt')" "$SANDBOX/ip.out"
expect "an out-of-grammar guard reports unparseable with the guard and a reason" \
  bash -c "awk -F'\t' '\$1==\"unparseable\" && \$2==\"ls web/\" && \$3 != \"\"' '$SANDBOX/ip.out' | grep -q ."
expect "each out-of-grammar input gets exactly one unparseable line (3 total)" \
  bash -c "test \"\$(awk -F'\t' '\$1==\"unparseable\"' '$SANDBOX/ip.out' | wc -l)\" -eq 3"
expect "blank and whitespace-only lines carry no guard and are skipped (5 rows total)" \
  bash -c "test \"\$(grep -c . '$SANDBOX/ip.out')\" -eq 5"
refute "parse-only never executes a guard's side effect" test -e "$IP/pwned-parse"
refute "parse-only writes no active view anywhere under the cwd" \
  bash -c "find '$IP' -name 'intent-*.md' | grep -q ."
# No filesystem probes at all: the verdict is about the TEXT. An in-grammar guard
# whose target is missing is still `ok`, and a fifo target cannot stall the answer.
mkfifo parsepipe
PARSE_T0=$(date +%s)
printf '%s\n' 'grep -q needle parsepipe' 'test -e nowhere/at/all.txt' \
  | env -u RUN ACTION=parse-only "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/ip2.out" 2>&1
expect "parse-only exits 0 when every line is in grammar" test $? -eq 0
PARSE_ELAPSED=$(( $(date +%s) - PARSE_T0 ))
expect "parse-only answers a fifo-target guard instantly (${PARSE_ELAPSED}s — nothing is opened)" \
  test "$PARSE_ELAPSED" -lt 5
expect "an in-grammar guard whose target is absent is still 'ok' (grammar, not truth)" \
  grep -qxF "$(printf 'ok\ttest -e nowhere/at/all.txt')" "$SANDBOX/ip2.out"
expect "an unknown ACTION is a usage error (exit 2), not a silent vet" \
  bash -c "ACTION=frobnicate RUN='$IP/run-bad' '$SKILL_DIR/scripts/intent-check.sh' >/dev/null 2>&1; test \$? -eq 2"
# A vetting run with RUN UNSET is an env error like any other — EXIT 2, not the
# `${RUN:?}` shell default of 1. Exit 1 is parse-only's grammar-finding code, so the
# vet path must not collide with it; the RUN check fires before any intent access, so
# no INTENT is needed here.
env -u RUN "$SKILL_DIR/scripts/intent-check.sh" >/dev/null 2>"$SANDBOX/ip-norun.err"; IPNR_RC=$?
if [[ "$IPNR_RC" -eq 2 ]]; then pass "a vet with RUN unset exits 2, not the \${RUN:?} default of 1 (no collision with parse-only's exit 1)"; else fail "a vet with RUN unset exits 2 (got $IPNR_RC)"; fi
expect "the unset-RUN error names the missing RUN dir" \
  grep -qi 'RUN dir required' "$SANDBOX/ip-norun.err"
expect "the default ACTION is still the vetting run (no ACTION set, RUN honoured)" \
  bash -c "printf -- '- 2026-08-08: fact\\n' > '$IP/plain.md'; RUN='$IP/run-vet' INTENT='$IP/plain.md' '$SKILL_DIR/scripts/intent-check.sh' | grep -qx 'ACTIVE=1'"
expect "parse-only is documented in the runner's header only" \
  bash -c "grep -q 'parse-only' '$SKILL_DIR/scripts/intent-check.sh' && ! grep -rq 'parse-only' '$SKILL_DIR/SKILL.md' '$SKILL_DIR/phases' '$SKILL_DIR/reference' '$SKILL_DIR/agents'"
cd "$SANDBOX"

fi

if t "intent-check.sh — a grep pattern carrying a control or non-ASCII byte is out of grammar (vet and parse-only)"; then
# Finding 7. path_ok already gated its charset against a literal ASCII allowlist, but
# pattern_ok rejected only shell-syntax bytes — an interior CR / VT / FF, an NBSP, or any
# other non-ASCII byte in the grep PATTERN passed as in-grammar. With a negated guard the
# entry then went ACTIVE, so those raw bytes landed VERBATIM in intent-active.md, which
# Phase 5 quotes back to the user (a mid-line CR can visually overwrite terminal text);
# and parse-only — the single source of truth for the doc-example lint — green-lit the
# same guard. The fix is the existing unparseable path (reported, excluded, never
# executed), applied through the shared parser (guard_parse), so both modes inherit it.
IPC=$SANDBOX/intent-pat-charset
mkdir -p "$IPC/run" && cd "$IPC"
printf 'needle\n' > haystack.txt
CR=$(printf '\r'); NBSP=$(printf '\302\240'); VT=$(printf '\013')
# Negated guards, so the pre-fix code (grep finds no match → `!` inverts → PASS) put each
# entry into the ACTIVE view WITH its control/non-ASCII byte — the exact failure.
{ printf -- '- 2026-01-01: alpha-cr\n'
  printf '  guard: ! grep -q foo%sbar haystack.txt\n' "$CR"
  printf -- '- 2026-01-02: beta-nbsp\n'
  printf '  guard: ! grep -q foo%sbar haystack.txt\n' "$NBSP"
  printf -- '- 2026-01-03: gamma-vt\n'
  printf '  guard: ! grep -q foo%sbar haystack.txt\n' "$VT"
  printf -- '- 2026-01-04: delta-clean\n'
  printf '  guard: grep -q ne.dle haystack.txt\n'
} > intent.md
RUN=$IPC/run INTENT=$IPC/intent.md "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/ipc.out" 2> "$SANDBOX/ipc.log"
expect "charset guard: vet still exits 0 (a finding, not an error)" test $? -eq 0
for f in alpha-cr beta-nbsp gamma-vt; do
  refute "charset guard: '$f' never reaches the active view (its pattern is out of grammar)" \
    grep -q "$f" "$IPC/run/intent-active.md"
  expect "charset guard: '$f' lands in intent-unparseable.md, fail-closed" \
    grep -q "$f" "$IPC/run/intent-unparseable.md"
done
refute "charset guard: no control/non-ASCII pattern byte reaches the active view Phase 5 quotes" \
  grep -q 'foo' "$IPC/run/intent-active.md"
expect "charset guard: the clean regex pattern is unaffected — delta-clean stays ACTIVE" \
  grep -q 'delta-clean' "$IPC/run/intent-active.md"
expect "charset guard: counts — ACTIVE=1" grep -qx 'ACTIVE=1' "$SANDBOX/ipc.out"
expect "charset guard: counts — UNPARSEABLE=3" grep -qx 'UNPARSEABLE=3' "$SANDBOX/ipc.out"
expect "charset guard: the stderr reason names the grammar so the fix is obvious" \
  grep -qi 'grammar\|ASCII\|control' "$SANDBOX/ipc.log"
# parse-only sees the SAME parser — the doc-example lint cannot green-light one of these.
printf '%s\n' \
  "grep -q foo${CR}bar path.txt" \
  "grep -q foo${NBSP}bar path.txt" \
  "grep -q ne.dle path.txt" \
  | env -u RUN ACTION=parse-only "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/ipc-parse.out" 2>&1
expect "charset guard: parse-only exits 1 (a control/non-ASCII pattern is out of grammar)" test $? -eq 1
expect "charset guard: parse-only marks a control/non-ASCII pattern unparseable" \
  bash -c "test \"\$(awk -F'\t' '\$1==\"unparseable\"' '$SANDBOX/ipc-parse.out' | wc -l)\" -eq 2"
expect "charset guard: parse-only still passes the clean regex pattern" \
  grep -qxF "$(printf 'ok\tgrep -q ne.dle path.txt')" "$SANDBOX/ipc-parse.out"
cd "$SANDBOX"

fi

if t "intent-check.sh — a blank line between an entry and its guard cannot de-guard it"; then
# The de-guarding defect: a blank line is a column-0 non-bullet, so it SETTLED the
# entry (guardless -> ACTIVE) and the `guard:` line below it then arrived with no
# entry open, where a stray indent is structure — copied into the active view as
# prose and never evaluated. The fact then steers resolutions with its guard
# unevaluated, which is precisely what the quarantine bucket exists to prevent, and
# nothing anywhere reported it. Markdown reads an indented line after a blank as a
# continuation paragraph of the list item, so the file was never malformed either.
#
# The rule: one or more blank lines between an entry and an indented continuation
# are held, not settled — the continuation (and its guard) attaches to the entry
# above. Unbounded on purpose: the error this fix removes is a guard SILENTLY
# dropped, and over-attaching an indented line can only ever add guards to an
# entry (fail closed), never remove one.
IB=$SANDBOX/intent-blank
mkdir -p "$IB" "$IB/web" && cd "$IB"
printf 'body\n' > plain.txt

# 1. The reproduction: web/ exists, so `test ! -e web` FAILS — the entry must
#    quarantine. Pre-fix it was ACTIVE=1 with the guard line laundered into the
#    active view as prose.
printf -- '- 2026-09-01: web/ is deliberately absent\n\n  guard: test ! -e web\n' > blank-fail.md
RUN=$IB/run-fail INTENT=$IB/blank-fail.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ib-fail.out" 2> "$SANDBOX/ib-fail.log"
expect "a blank line before the guard still exits 0" test $? -eq 0
expect "counts: the blank-separated failing guard QUARANTINES its entry" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/ib-fail.out"
expect "counts: ACTIVE=0 — the entry does not sail through guardless" \
  grep -qx 'ACTIVE=0' "$SANDBOX/ib-fail.out"
expect "counts: UNPARSEABLE=0 (a blank line is not malformed)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/ib-fail.out"
refute "the de-guarded entry never reaches resolver input" \
  grep -q '2026-09-01' "$IB/run-fail/intent-active.md"
refute "the orphan-looking guard line is not laundered into the active view as prose" \
  grep -q 'test ! -e web' "$IB/run-fail/intent-active.md"
expect "the entry lands in the re-confirm set with its guard line" \
  bash -c "grep -qF -- '- 2026-09-01: web/ is deliberately absent' '$IB/run-fail/intent-quarantined.md' && grep -qF 'guard: test ! -e web' '$IB/run-fail/intent-quarantined.md'"
expect "the quarantine names the guard that failed" \
  bash -c "grep -q '^QUARANTINED:' '$SANDBOX/ib-fail.log' && grep -q 'test ! -e web' '$SANDBOX/ib-fail.log'"
expect "the held blank line stays with its entry, verbatim and in order" \
  bash -c "test \"\$(sed -n 2p '$IB/run-fail/intent-quarantined.md')\" = '' && test \"\$(grep -c . '$IB/run-fail/intent-quarantined.md')\" -eq 2"

# 2. The same shape with a guard that HOLDS: active, and the guard really ran
#    (the file is otherwise identical to fixture 1, whose verdict differs).
printf -- '- 2026-09-02: plain.txt is generated on every build\n\n  guard: test -e plain.txt\n' > blank-pass.md
RUN=$IB/run-pass INTENT=$IB/blank-pass.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ib-pass.out" 2>&1
expect "counts: a blank-separated PASSING guard keeps its entry active" \
  grep -qx 'ACTIVE=1' "$SANDBOX/ib-pass.out"
expect "counts: nothing is quarantined when the guard holds" \
  grep -qx 'QUARANTINED=0' "$SANDBOX/ib-pass.out"
expect "the active entry keeps the blank line and the guard line verbatim" \
  bash -c "test \"\$(sed -n 1p '$IB/run-pass/intent-active.md')\" = '- 2026-09-02: plain.txt is generated on every build' && test \"\$(sed -n 2p '$IB/run-pass/intent-active.md')\" = '' && test \"\$(sed -n 3p '$IB/run-pass/intent-active.md')\" = '  guard: test -e plain.txt'"

# 3. Several blank lines, and a second guard after another gap: every guard of the
#    entry attaches, and ALL of them must hold (one failing is enough).
printf -- '- 2026-09-03: several blank lines still keep the guards attached\n\n\n  guard: test -e plain.txt\n\n  guard: test ! -e web\n' > blank-multi.md
RUN=$IB/run-multi INTENT=$IB/blank-multi.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ib-multi.out" 2> "$SANDBOX/ib-multi.log"
expect "counts: two blank lines do not settle the entry either" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/ib-multi.out"
expect "the failing one of two blank-separated guards is the one reported" \
  grep -q 'test ! -e web' "$SANDBOX/ib-multi.log"
refute "the multi-gap entry never reaches resolver input" \
  grep -q '2026-09-03' "$IB/run-multi/intent-active.md"

# 4. An out-of-grammar guard behind a blank line is still an UNPARSEABLE entry —
#    the attachment rule feeds the same fail-closed grammar check.
printf -- '- 2026-09-04: the gizmo cache is rebuilt out of band\n\n  guard: ls web/\n' > blank-bad.md
RUN=$IB/run-bad INTENT=$IB/blank-bad.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ib-bad.out" 2>&1
expect "counts: a blank-separated out-of-grammar guard reports UNPARSEABLE=1" \
  grep -qx 'UNPARSEABLE=1' "$SANDBOX/ib-bad.out"
refute "and its entry never reaches resolver input" \
  grep -q '2026-09-04' "$IB/run-bad/intent-active.md"

# 5. Non-regression — the ordinary shapes of this file are unchanged. A blank line
#    between two entries still separates them, blanks before any entry and after
#    the last one are still structure, and a blank line followed by ordinary
#    indented prose produces the same active view it always did.
printf '%s\n' \
  '# Standing intent' \
  '' \
  '- 2026-09-05: first entry' \
  '  guard: test -e plain.txt' \
  '' \
  '- 2026-09-06: second entry' \
  '' \
  '  more prose about the second entry' \
  '' \
  'Closing paragraph.' \
  '' \
  > blank-plain.md
RUN=$IB/run-plain INTENT=$IB/blank-plain.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ib-plain.out" 2>&1
expect "counts: two entries, both active" grep -qx 'ACTIVE=2' "$SANDBOX/ib-plain.out"
expect "counts: nothing quarantined or unparseable in the ordinary file" \
  bash -c "grep -qx 'QUARANTINED=0' '$SANDBOX/ib-plain.out' && grep -qx 'UNPARSEABLE=0' '$SANDBOX/ib-plain.out'"
expect "the active view is byte-identical to the input (blank lines kept in place)" \
  cmp -s "$IB/blank-plain.md" "$IB/run-plain/intent-active.md"

# 6. A column-0 `guard:` behind a blank line is STILL an orphan — the tolerance is
#    for indented continuations, not for unindented guard lines, and the entry
#    above it is still excluded (its guard never ran).
printf -- '- 2026-09-07: the doodad index is external\n\nguard: test -e plain.txt\n' > blank-orphan.md
RUN=$IB/run-orphan INTENT=$IB/blank-orphan.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ib-orphan.out" 2> "$SANDBOX/ib-orphan.log"
expect "counts: a column-0 guard behind a blank line is still an orphaned finding" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/ib-orphan.out"
expect "the orphan report still names the cause" \
  grep -qi 'orphaned guard' "$SANDBOX/ib-orphan.log"
refute "the entry above the blank-separated orphan is still kept out of resolver input" \
  grep -q '2026-09-07' "$IB/run-orphan/intent-active.md"
cd "$SANDBOX"

fi

if t "intent-check.sh — an empty guard: value is unparseable, never guardless"; then
# A truncated guard used to fail OPEN: the guard-value extraction yielded the empty
# string, the empty string was not appended as a guard, and the entry rode into the
# active view as if it had never carried one. `guard:` with nothing after it is
# exactly the shape a bad edit, a cut-off paste or a half-written promotion leaves
# behind — the author's intent was to constrain the fact, and the file says so.
# So it joins the other unreadable-guard shapes: reported, fail closed, excluded
# until re-confirmed.
IE=$SANDBOX/intent-emptyguard
mkdir -p "$IE" && cd "$IE"
printf 'body\n' > plain.txt
TAB=$(printf '\t')
{ printf -- '- 2026-10-01: the guard was truncated to nothing\n  guard:\n'
  printf -- '- 2026-10-02: the guard value is whitespace only\n  guard:    \n'
  printf -- '- 2026-10-03: the guard value is a lone tab\n  guard:%s\n' "$TAB"
} > empty.md
RUN=$IE/run INTENT=$IE/empty.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ie.out" 2> "$SANDBOX/ie.log"
expect "an empty guard is a finding, not an error (exit 0)" test $? -eq 0
expect "counts: every empty-valued guard reports UNPARSEABLE=3" \
  grep -qx 'UNPARSEABLE=3' "$SANDBOX/ie.out"
expect "counts: ACTIVE=0 — a truncated guard never reads as guardless" \
  grep -qx 'ACTIVE=0' "$SANDBOX/ie.out"
expect "counts: QUARANTINED=0 (an unreadable guard is not a stale fact)" \
  grep -qx 'QUARANTINED=0' "$SANDBOX/ie.out"
for d in 01 02 03; do
  refute "the 2026-10-$d entry never reaches resolver input" \
    grep -q "2026-10-$d" "$IE/run/intent-active.md"
  expect "the 2026-10-$d entry lands in intent-unparseable.md, awaiting re-confirm" \
    grep -q "2026-10-$d" "$IE/run/intent-unparseable.md"
done
expect "one UNPARSEABLE: stderr line per entry (3 total)" \
  bash -c "test \"\$(grep -c '^UNPARSEABLE:' '$SANDBOX/ie.log')\" -eq 3"
expect "the reason says the guard is empty, so the repair is obvious" \
  bash -c "grep '^UNPARSEABLE:' '$SANDBOX/ie.log' | grep -qi 'guard is empty'"

# An empty guard alongside a good one is still unparseable: every guard of an entry
# must be READABLE before any of them is evaluated (the pass-1 rule), so the
# verdict cannot depend on which guard the author listed first.
printf -- '- 2026-10-04: one good guard and one truncated one\n  guard: test -e plain.txt\n  guard:\n' > mixed.md
RUN=$IE/run-mixed INTENT=$IE/mixed.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ie-mixed.out" 2>&1
expect "counts: a good guard does not rescue a truncated sibling (UNPARSEABLE=1)" \
  grep -qx 'UNPARSEABLE=1' "$SANDBOX/ie-mixed.out"
refute "the mixed-guard entry never reaches resolver input" \
  grep -q '2026-10-04' "$IE/run-mixed/intent-active.md"

# Non-regression: `guard:` with a value but no space still parses as a guard (and
# is refused on its own merits), a genuinely guardless entry is still guardless,
# and a key that merely STARTS with guard is still prose.
{ printf -- '- 2026-10-05: no space after the colon\n  guard:test -e plain.txt\n'
  printf -- '- 2026-10-06: a genuinely guardless fact (no tree-checkable shape)\n'
  printf -- '- 2026-10-07: a lookalike key is prose, not a guard\n  guardrail: test -e nowhere\n'
} > near.md
RUN=$IE/run-near INTENT=$IE/near.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ie-near.out" 2>&1
expect "counts: all three stay active — none of these is an empty guard (ACTIVE=3)" \
  grep -qx 'ACTIVE=3' "$SANDBOX/ie-near.out"
expect "'guard:test -e plain.txt' is still read as a guard and vetted (it holds)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/ie-near.out"
expect "the guardless entry still passes through untouched" \
  grep -q '2026-10-06' "$IE/run-near/intent-active.md"
expect "a 'guardrail:' continuation is prose, kept with its entry" \
  grep -q 'guardrail: test -e nowhere' "$IE/run-near/intent-active.md"

# ACTION=parse-only keeps its documented asymmetry on purpose: a blank input line
# carries no guard AT ALL (nothing was written), whereas `guard:` in an intent file
# is an author asserting a constraint and failing to state it. Same parser, two
# different questions — pinned so neither drifts into the other.
printf '%s\n' 'test -e plain.txt' '' '   ' \
  | env -u RUN ACTION=parse-only "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/ie-po.out" 2>&1
expect "parse-only still skips blank input lines (exit 0, one row)" \
  bash -c "test \"\$(grep -c . '$SANDBOX/ie-po.out')\" -eq 1"
expect "parse-only reports the empty guard text as unparseable when it IS a line" \
  bash -c "printf ' \t \n' | env -u RUN ACTION=parse-only '$SKILL_DIR/scripts/intent-check.sh' | grep -c . | grep -qx 0"
cd "$SANDBOX"

fi

if t "intent-check.sh — a CRLF checkout vets identically to its LF twin"; then
# A Windows clone (or a repo without .gitattributes) hands this parser CRLF lines,
# and the \r landed inside the LAST TOKEN of every guard: `test -d web<CR>` fails the
# path charset, so with the allowlisted grammar EVERY guard in the file became
# unparseable and the component's entire standing intent was quarantined out of the
# run — on a file that is perfectly valid on the platform that wrote it. Thematic
# breaks went the same way (`---<CR>` is not `---`).
#
# The fix is the family's own idiom (lib/yaml-*.awk: `sub(/\r$/, "", line)`;
# materialize.sh / bellwether-detect.sh `tr -d '\r'`): strip ONE trailing CR per
# line. Trailing only — an interior CR is not a line ending, and the fixture at the
# end of this block is why that distinction is load-bearing.
IR=$SANDBOX/intent-crlf
mkdir -p "$IR" "$IR/web" && cd "$IR"
printf 'body\n' > plain.txt
printf 'the sprocket is calibrated\n' > haystack.txt
printf '%s\n' \
  '# Standing intent' \
  '' \
  'Prose paragraph explaining the file.' \
  '---' \
  '- 2026-11-01: plain.txt is generated on every build' \
  '  guard: test -e plain.txt' \
  '- 2026-11-02: web/ is deliberately absent' \
  '  guard: test ! -e web' \
  '- 2026-11-03: the flywheel note was retired (no tree-checkable shape)' \
  '- 2026-11-04: several guards, all holding' \
  '  guard: test -e plain.txt' \
  '  guard: grep -q calibrated haystack.txt' \
  '* 2026-11-05: star-bullet promotion' \
  '- 2026-11-06: the gizmo cache is external' \
  '  guard: ls web/' \
  > lf.md
sed 's/$/\r/' lf.md > crlf.md
# Byte counts rather than a grep for \r: `tr -d` and `wc -c` behave identically on
# both userlands, which is the same reason nul_count in the script counts this way.
expect "fixture self-check: the CRLF twin really carries carriage returns" \
  bash -c "test \"\$(wc -c < '$IR/crlf.md')\" -ne \"\$(LC_ALL=C tr -d '\\r' < '$IR/crlf.md' | wc -c)\""
expect "fixture self-check: the LF twin carries none" \
  bash -c "test \"\$(wc -c < '$IR/lf.md')\" -eq \"\$(LC_ALL=C tr -d '\\r' < '$IR/lf.md' | wc -c)\""

RUN=$IR/run-lf INTENT=$IR/lf.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ir-lf.out" 2> "$SANDBOX/ir-lf.log"
expect "the LF twin exits 0" test $? -eq 0
RUN=$IR/run-crlf INTENT=$IR/crlf.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ir-crlf.out" 2> "$SANDBOX/ir-crlf.log"
expect "the CRLF file exits 0" test $? -eq 0

# Non-vacuity first: the LF twin must really exercise all four verdicts, or
# "identical" would be a comparison of two empty answers.
expect "the LF twin vets three entries active" grep -qx 'ACTIVE=3' "$SANDBOX/ir-lf.out"
expect "the LF twin quarantines the contradicted entry" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/ir-lf.out"
expect "the LF twin reports the star bullet and the out-of-grammar guard" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/ir-lf.out"

# The whole contract in one assertion: same verdicts, same counts, same bytes.
expect "the CRLF verdict counts are byte-identical to the LF twin's" \
  cmp -s "$SANDBOX/ir-lf.out" "$SANDBOX/ir-crlf.out"
for f in intent-active.md intent-quarantined.md intent-unparseable.md; do
  expect "$f is byte-identical between the CRLF file and its LF twin" \
    cmp -s "$IR/run-lf/$f" "$IR/run-crlf/$f"
  expect "$f carries no carriage return (the outputs are read back as text)" \
    bash -c "test \"\$(wc -c < '$IR/run-crlf/$f')\" -eq \"\$(LC_ALL=C tr -d '\\r' < '$IR/run-crlf/$f' | wc -c)\""
done
expect "the CRLF file's guards really ran (the contradicted entry quarantines)" \
  bash -c "grep -q '2026-11-02' '$IR/run-crlf/intent-quarantined.md' && ! grep -q '2026-11-02' '$IR/run-crlf/intent-active.md'"
expect "a CRLF thematic break is still structure, not a bullet-like marker" \
  grep -qx -- '---' "$IR/run-crlf/intent-active.md"
expect "the CRLF stderr findings match the LF twin's, line for line" \
  cmp -s "$SANDBOX/ir-lf.log" "$SANDBOX/ir-crlf.log"

# The distinction the fix must NOT lose: a CR in the MIDDLE of a line is not a line
# ending, and a blanket `tr -d '\r'` over the file would splice the text after it
# into the guard — the CRLF twin of the NUL smuggling attempt. It must stay out of
# grammar, and nothing may run.
{ printf -- '- 2026-11-07: an interior CR is not a line ending\n'
  printf -- '  guard: test -e plain.txt'; printf '\r'; printf -- '; touch pwned-cr\n'
} > interior.md
RUN=$IR/run-interior INTENT=$IR/interior.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ir-int.out" 2>&1
expect "counts: an interior CR keeps the guard OUT of grammar (UNPARSEABLE=1)" \
  grep -qx 'UNPARSEABLE=1' "$SANDBOX/ir-int.out"
expect "counts: and its entry never goes active" grep -qx 'ACTIVE=0' "$SANDBOX/ir-int.out"
refute "the smuggled command was never executed" test -e "$IR/pwned-cr"

# ACTION=parse-only takes guards on stdin, and a caller piping a CRLF file is the
# same hazard: the trailing CR must not turn an in-grammar guard into a finding.
printf 'test -e plain.txt\r\ngrep -q calibrated haystack.txt\r\n' \
  | env -u RUN ACTION=parse-only "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/ir-po.out" 2>&1
expect "parse-only accepts CRLF input lines (exit 0)" test $? -eq 0
expect "parse-only reports the CR-stripped guard text, not the raw bytes" \
  grep -qxF "$(printf 'ok\ttest -e plain.txt')" "$SANDBOX/ir-po.out"
printf 'test -e plain.txt\r; touch pwned-po\n' \
  | env -u RUN ACTION=parse-only "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/ir-po2.out" 2>&1
expect "parse-only still refuses a guard with an INTERIOR CR (exit 1)" test $? -eq 1
refute "parse-only executed nothing either" test -e "$IR/pwned-po"
cd "$SANDBOX"

fi

if t "intent-check.sh — only a BLANK line may separate an entry from its guard"; then
# The blank-line fix closed ONE shape of silent de-guarding; the class was wider.
# ANY other entry-closer between a fact and its indented guard settled the entry
# (guardless -> ACTIVE), and the `guard:` line then arrived with no entry open,
# where a stray indent was structure — copied into intent-active.md as prose, its
# assertion never evaluated, nothing reported anywhere. Five reproduced shapes, one
# fixture each: a thematic break, a column-0 prose line, a wrong-style bullet, a git
# conflict marker, and a UTF-8 BOM in front of the first bullet.
#
# Every fixture states a fact the tree CONTRADICTS (go.mod exists, and each guard
# asserts it is absent), so a shape that reports ACTIVE=1 is a fact steering
# resolutions on an assertion nobody ran — the failure this suite exists to catch.
ID=$SANDBOX/intent-deguard
mkdir -p "$ID" && cd "$ID"
: > go.mod
TAB=$(printf '\t')

# --- (b) a thematic break between the fact and its guard ----------------------
printf -- '- 2026-11-11: go.mod is absent by design\n---\n    guard: test ! -e go.mod\n' > brk.md
RUN=$ID/run-brk INTENT=$ID/brk.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/id-brk.out" 2> "$SANDBOX/id-brk.log"
expect "a de-guarded entry is a finding, not an error (exit 0)" test $? -eq 0
expect "counts: a '---' between fact and guard leaves NOTHING active" \
  grep -qx 'ACTIVE=0' "$SANDBOX/id-brk.out"
expect "counts: two findings — the stranded entry and its orphaned guard" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/id-brk.out"
refute "the de-guarded entry never reaches resolver input" \
  grep -q '2026-11-11' "$ID/run-brk/intent-active.md"
refute "the stranded guard line is not laundered into the active view as prose" \
  grep -q 'test ! -e go.mod' "$ID/run-brk/intent-active.md"
expect "the entry lands in intent-unparseable.md, awaiting re-confirm" \
  grep -qF -- '- 2026-11-11: go.mod is absent by design' "$ID/run-brk/intent-unparseable.md"
expect "so does the orphaned guard line, verbatim" \
  grep -qF -- '    guard: test ! -e go.mod' "$ID/run-brk/intent-unparseable.md"
expect "the guard is reported as an orphan, naming the blank-line-only rule" \
  bash -c "grep 'UNPARSEABLE:' '$SANDBOX/id-brk.log' | grep 'test ! -e go.mod' | grep -qi 'orphaned guard'"
expect "the stranded entry is reported too (one finding each, 2 total)" \
  bash -c "test \"\$(grep -c '^UNPARSEABLE:' '$SANDBOX/id-brk.log')\" -eq 2"
# Retraction is surgical: the entry comes back out of the active view, the
# structure line that closed it stays — it is structure whatever happens to the
# entry above it.
expect "the '---' itself is still structure in the active view" \
  grep -qx -- '---' "$ID/run-brk/intent-active.md"

# --- (c) a column-0 prose line / heading between fact and guard ---------------
printf -- '- 2026-11-12: go.mod is absent by design\nA paragraph about the above.\n  guard: test ! -e go.mod\n' > prose.md
RUN=$ID/run-prose INTENT=$ID/prose.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/id-prose.out" 2> "$SANDBOX/id-prose.log"
expect "counts: a column-0 prose line between fact and guard leaves nothing active" \
  grep -qx 'ACTIVE=0' "$SANDBOX/id-prose.out"
expect "counts: entry + guard are both findings" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/id-prose.out"
refute "the prose-separated entry never reaches resolver input" \
  grep -q '2026-11-12' "$ID/run-prose/intent-active.md"
expect "the prose line stays structure" \
  grep -qx 'A paragraph about the above.' "$ID/run-prose/intent-active.md"

# --- (d) a wrong-style bullet between fact and guard -------------------------
printf -- '- 2026-11-13: go.mod is absent by design\n* a star-bullet promotion\n  guard: test ! -e go.mod\n' > wrongb.md
RUN=$ID/run-wrongb INTENT=$ID/wrongb.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/id-wrongb.out" 2> "$SANDBOX/id-wrongb.log"
expect "counts: a wrong-style bullet between fact and guard leaves nothing active" \
  grep -qx 'ACTIVE=0' "$SANDBOX/id-wrongb.out"
expect "counts: three findings — the bad bullet, the stranded entry, the orphan guard" \
  grep -qx 'UNPARSEABLE=3' "$SANDBOX/id-wrongb.out"
refute "the bullet-separated entry never reaches resolver input" \
  grep -q '2026-11-13' "$ID/run-wrongb/intent-active.md"
refute "nor does the guard line" \
  grep -q 'test ! -e go.mod' "$ID/run-wrongb/intent-active.md"

# --- a column-0 guard after an already-CLOSED entry ---------------------------
# The same class at column 0: the orphan branch only excluded an entry still OPEN,
# so a `---` (or any closer) in between let the fact go ACTIVE guardless. One
# attachment rule now serves both spellings.
printf -- '- 2026-11-14: go.mod is absent by design\n---\nguard: test ! -e go.mod\n' > col0.md
RUN=$ID/run-col0 INTENT=$ID/col0.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/id-col0.out" 2> "$SANDBOX/id-col0.log"
expect "counts: a column-0 orphan strands the closed entry above it too" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/id-col0.out"
expect "counts: and nothing rides through active guardless" \
  grep -qx 'ACTIVE=0' "$SANDBOX/id-col0.out"
refute "the entry above the column-0 orphan is out of resolver input" \
  grep -q '2026-11-14' "$ID/run-col0/intent-active.md"

# --- (a) git conflict markers: the WHOLE file is refused ----------------------
# This script runs at Phase 5 START, long before the final gate's marker scan would
# ever see the file. An unresolved merge holds two versions of the same facts
# interleaved: the reproduction had the `<<<<<<< HEAD` copy go ACTIVE guardless
# while the `>>>>>>> theirs` copy of the SAME fact quarantined — two contradictory
# verdicts on one fact in one run. Same whole-file precedent as the NUL policy.
{ printf -- '<<<<<<< HEAD\n- 2026-11-15: go.mod is absent by design\n'
  printf -- '=======\n- 2026-11-15: go.mod is absent by design\n'
  printf -- '    guard: test ! -e go.mod\n>>>>>>> theirs\n'
} > conflict.md
RUN=$ID/run-conflict INTENT=$ID/conflict.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/id-conf.out" 2> "$SANDBOX/id-conf.log"
expect "a conflict-marked intent file is a finding, not an error (exit 0)" test $? -eq 0
expect "counts: the whole file is ONE finding (UNPARSEABLE=1)" \
  grep -qx 'UNPARSEABLE=1' "$SANDBOX/id-conf.out"
expect "counts: ACTIVE=0 — no side of the merge is vetted" \
  grep -qx 'ACTIVE=0' "$SANDBOX/id-conf.out"
expect "counts: QUARANTINED=0 (an unresolved merge is not a stale fact)" \
  grep -qx 'QUARANTINED=0' "$SANDBOX/id-conf.out"
refute "not one line of a conflict-marked file reaches resolver input" \
  bash -c "test -s '$ID/run-conflict/intent-active.md'"
expect "the finding names git conflict markers and the first marker line" \
  bash -c "grep '^UNPARSEABLE:' '$SANDBOX/id-conf.log' | grep -qi 'conflict marker'"
expect "the finding quotes the marker it found, so the repair is obvious" \
  grep -q '<<<<<<< HEAD' "$SANDBOX/id-conf.log"
expect "the finding is recorded in intent-unparseable.md too" \
  grep -q 'the whole file' "$ID/run-conflict/intent-unparseable.md"
# Each marker spelling on its own is enough: a half-resolved file is still two
# versions of the facts, and `=======` is matched only as a whole line.
for m in '=======' '>>>>>>> theirs'; do
  printf -- '- 2026-11-16: go.mod is absent by design\n%s\n    guard: test ! -e go.mod\n' "$m" > one-marker.md
  RUN=$ID/run-1m INTENT=$ID/one-marker.md "$SKILL_DIR/scripts/intent-check.sh" \
    > "$SANDBOX/id-1m.out" 2>&1
  expect "the marker '$m' alone refuses the file (UNPARSEABLE=1, ACTIVE=0)" \
    bash -c "grep -qx 'UNPARSEABLE=1' '$SANDBOX/id-1m.out' && grep -qx 'ACTIVE=0' '$SANDBOX/id-1m.out'"
done
# Non-regression: marker-LOOKING prose is not a marker. `=======` matches as a whole
# line only, and a fact may legitimately mention an arrow or a diff.
{ printf -- '- 2026-11-17: the ==== rule below is prose\n  guard: test -e go.mod\n'
  printf -- 'a ======= b is a comparison, not a marker\n'
  printf -- '>>> not a marker either\n'
} > nearmarker.md
RUN=$ID/run-near INTENT=$ID/nearmarker.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/id-near.out" 2>&1
expect "marker-looking prose does not refuse the file (ACTIVE=1)" \
  grep -qx 'ACTIVE=1' "$SANDBOX/id-near.out"

# --- (e) a UTF-8 BOM in front of the first bullet -----------------------------
# The BOM bytes sat before the `- `, so entry #1 was not a bullet at all: it went
# out as column-0 prose and its indented guard was an orphan — de-guarding the FIRST
# fact of every file a Windows editor had saved. The BOM is STRIPPED (one line, like
# the CR), so entry #1 parses like any other and its guard really runs.
BOM=$(printf '\357\273\277')
printf -- '%s- 2026-11-18: go.mod is absent by design\n  guard: test ! -e go.mod\n' "$BOM" > bom.md
expect "fixture self-check: the file really starts with the BOM bytes" \
  bash -c "test \"\$(head -c 3 '$ID/bom.md' | od -An -tx1 | tr -d ' \\n')\" = efbbbf"
RUN=$ID/run-bom INTENT=$ID/bom.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/id-bom.out" 2> "$SANDBOX/id-bom.log"
expect "counts: the BOM'd entry #1 is guard-vetted, and its guard FAILS (QUARANTINED=1)" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/id-bom.out"
expect "counts: ACTIVE=0 — it never rides through guardless" \
  grep -qx 'ACTIVE=0' "$SANDBOX/id-bom.out"
expect "counts: UNPARSEABLE=0 — a BOM is stripped, not reported" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/id-bom.out"
expect "the quarantine names the guard that ran" \
  bash -c "grep -q '^QUARANTINED:' '$SANDBOX/id-bom.log' && grep -q 'test ! -e go.mod' '$SANDBOX/id-bom.log'"
expect "the BOM'd bullet is recognised as an entry (bucketed with its guard)" \
  bash -c "grep -q '2026-11-18' '$ID/run-bom/intent-quarantined.md' && grep -qF 'guard: test ! -e go.mod' '$ID/run-bom/intent-quarantined.md'"
# A BOM'd file whose guard HOLDS goes active, and the outputs carry no BOM: Phase 5
# reads them back as text and promote-intent.sh matches against them.
printf -- '%s- 2026-11-19: go.mod is generated on every build\n  guard: test -e go.mod\n' "$BOM" > bom-pass.md
RUN=$ID/run-bomp INTENT=$ID/bom-pass.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/id-bomp.out" 2>&1
expect "counts: a BOM'd entry with a passing guard stays active" \
  grep -qx 'ACTIVE=1' "$SANDBOX/id-bomp.out"
expect "the active view carries NO BOM (stripped, like the trailing CR)" \
  bash -c "test \"\$(head -c 2 '$ID/run-bomp/intent-active.md')\" = '- '"
expect "the BOM'd active view is otherwise byte-identical to its BOM-less twin" \
  bash -c "printf -- '- 2026-11-19: go.mod is generated on every build\n  guard: test -e go.mod\n' | cmp -s - '$ID/run-bomp/intent-active.md'"
# A BOM is stripped from the FIRST line only — mid-file it is a byte like any other,
# and inside a guard's path it is out of grammar (the charset is ASCII-only).
printf -- '- 2026-11-20: a mid-file BOM is not a line terminator\n  guard: test -e %sgo.mod\n' "$BOM" > bom-mid.md
RUN=$ID/run-bommid INTENT=$ID/bom-mid.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/id-bommid.out" 2>&1
expect "counts: a BOM inside a guard's path is out of grammar (UNPARSEABLE=1)" \
  grep -qx 'UNPARSEABLE=1' "$SANDBOX/id-bommid.out"

# --- non-regression: the ordinary file is untouched by all of this ------------
# Same shape as the blank-line block's fixture 5, plus a `---` BETWEEN entries and a
# guard that holds: the active view must still be byte-identical to the input, which
# is what the buffered-and-retractable active view could most easily have broken.
printf '%s\n' \
  '# Standing intent' \
  '' \
  '- 2026-11-21: go.mod is generated on every build' \
  '  guard: test -e go.mod' \
  '' \
  '---' \
  '' \
  '- 2026-11-22: a guardless fact with a continuation' \
  '' \
  '  more prose about it' \
  '' \
  'Closing paragraph.' \
  > plain.md
RUN=$ID/run-plain INTENT=$ID/plain.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/id-plain.out" 2>&1
expect "counts: the ordinary file still vets two active entries, no findings" \
  bash -c "grep -qx 'ACTIVE=2' '$SANDBOX/id-plain.out' && grep -qx 'QUARANTINED=0' '$SANDBOX/id-plain.out' && grep -qx 'UNPARSEABLE=0' '$SANDBOX/id-plain.out'"
expect "the active view is byte-identical to the input (buffering changes nothing)" \
  cmp -s "$ID/plain.md" "$ID/run-plain/intent-active.md"
cd "$SANDBOX"

fi

if t "intent-check.sh — an unreadable intent path and an unwritable RUN are hard errors"; then
# `[ -f ]` is false for a chmod-000 file, a directory and a fifo alike, so each one
# vetted as ABSENT: ACTIVE=0/QUARANTINED=0/UNPARSEABLE=0, three empty outputs and
# exit 0 — every standing fact the component carries silently dropped, with the raw
# 'Permission denied' going out as shell noise nobody parses. ABSENCE is legitimate
# (no intent file = no standing facts); a path that EXISTS and cannot be read is a
# broken environment, and "no facts" must never be how this script says "I could not
# look". Same for the output side: with $RUN unwritable the vet ran to completion,
# printed counts, and left none of the three files Phase 5 reads back.
IX=$SANDBOX/intent-env
mkdir -p "$IX" && cd "$IX"
# A real, readable intent file with a real fact, for the output-side cases: they must
# refuse BEFORE parsing, with standing intent sitting right there to be vetted.
printf -- '- 2026-12-02: a standing fact the output side must not drop either\n  guard: test -e plain.md\n' > plain.md

# 1. A directory at the intent path.
mkdir -p "$IX/adir.md" "$IX/run-dir"
RUN=$IX/run-dir INTENT=$IX/adir.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ix-dir.out" 2> "$SANDBOX/ix-dir.log"
IX_DIR_RC=$?
if [[ "$IX_DIR_RC" -eq 2 ]]; then pass "a directory at the intent path exits 2"
else fail "a directory at the intent path exited $IX_DIR_RC (want 2)"; fi
expect "the error names the path and says it is a directory" \
  bash -c "grep -q '^ERROR:' '$SANDBOX/ix-dir.log' && grep -q 'adir.md' '$SANDBOX/ix-dir.log' && grep -qi 'directory' '$SANDBOX/ix-dir.log'"
refute "a hard error prints no counts (nothing was vetted)" \
  grep -qE '^(ACTIVE|QUARANTINED|UNPARSEABLE)=' "$SANDBOX/ix-dir.out"

# 2. A fifo at the intent path — `read` would block on it forever, and `[ -f ]`
#    calls it absent.
mkfifo "$IX/afifo.md"
mkdir -p "$IX/run-fifo"
RUN=$IX/run-fifo INTENT=$IX/afifo.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ix-fifo.out" 2> "$SANDBOX/ix-fifo.log"
IX_FIFO_RC=$?
if [[ "$IX_FIFO_RC" -eq 2 ]]; then pass "a fifo at the intent path exits 2"
else fail "a fifo at the intent path exited $IX_FIFO_RC (want 2)"; fi
expect "the error says it is not a regular file" \
  grep -qi 'not a regular file' "$SANDBOX/ix-fifo.log"

# 3. A symlink pointing nowhere: `-e` alone reads it as absent.
ln -sf "$IX/no-such-target.md" "$IX/dangling.md"
mkdir -p "$IX/run-dangle"
RUN=$IX/run-dangle INTENT=$IX/dangling.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ix-dangle.out" 2> "$SANDBOX/ix-dangle.log"
IX_DANGLE_RC=$?
if [[ "$IX_DANGLE_RC" -eq 2 ]]; then pass "a dangling symlink at the intent path exits 2"
else fail "a dangling symlink at the intent path exited $IX_DANGLE_RC (want 2)"; fi

# 4. An unreadable regular file — the shape that dropped a real component's facts.
printf -- '- 2026-12-01: a standing fact nobody may drop silently\n  guard: test -e go.mod\n' > locked.md
chmod 000 locked.md
mkdir -p "$IX/run-locked"
if [[ "$(id -u)" -eq 0 ]]; then
  # Root bypasses DAC, so chmod 000 stays readable and the failure path cannot be
  # exercised (BB CI and the Ubuntu container both run as root unless told not to).
  pass "unreadable-intent-file case skipped (running as root, chmod 000 stays readable)"
  pass "unreadable-intent-file message check skipped (running as root)"
  pass "unreadable-intent-file no-counts check skipped (running as root)"
else
  RUN=$IX/run-locked INTENT=$IX/locked.md "$SKILL_DIR/scripts/intent-check.sh" \
    > "$SANDBOX/ix-locked.out" 2> "$SANDBOX/ix-locked.log"
  IX_LOCKED_RC=$?
  if [[ "$IX_LOCKED_RC" -eq 2 ]]; then pass "an unreadable intent file exits 2, never an empty vet"
  else fail "an unreadable intent file exited $IX_LOCKED_RC (want 2)"; fi
  expect "the error names the path and the permission reason" \
    bash -c "grep -q 'locked.md' '$SANDBOX/ix-locked.log' && grep -qi 'permission denied' '$SANDBOX/ix-locked.log'"
  refute "an unreadable intent file reports no ACTIVE=0 (which read as 'no facts')" \
    grep -qE '^(ACTIVE|QUARANTINED|UNPARSEABLE)=' "$SANDBOX/ix-locked.out"
fi
chmod 644 locked.md 2>/dev/null || true

# 5. An unwritable $RUN — the output side of the same failure.
mkdir -p "$IX/run-ro"
chmod 500 "$IX/run-ro"
if [[ "$(id -u)" -eq 0 ]]; then
  pass "unwritable-RUN case skipped (running as root, a 0500 dir stays writable)"
  pass "unwritable-RUN message check skipped (running as root)"
  pass "unwritable-RUN no-counts check skipped (running as root)"
  pass "unwritable-RUN no-shell-noise check skipped (running as root)"
else
  RUN=$IX/run-ro INTENT=$IX/plain.md "$SKILL_DIR/scripts/intent-check.sh" \
    > "$SANDBOX/ix-ro.out" 2> "$SANDBOX/ix-ro.log"
  IX_RO_RC=$?
  if [[ "$IX_RO_RC" -eq 2 ]]; then pass "an unwritable RUN dir exits 2 before parsing"
  else fail "an unwritable RUN dir exited $IX_RO_RC (want 2)"; fi
  expect "the error names the file it could not write" \
    bash -c "grep -q '^ERROR:' '$SANDBOX/ix-ro.log' && grep -q 'intent-active.md' '$SANDBOX/ix-ro.log'"
  refute "an unwritable RUN prints no counts (they contradicted the empty dir)" \
    grep -qE '^(ACTIVE|QUARANTINED|UNPARSEABLE)=' "$SANDBOX/ix-ro.out"
  refute "the raw shell redirection noise is not left next to the message" \
    grep -q 'Permission denied' "$SANDBOX/ix-ro.log"
fi
chmod 700 "$IX/run-ro" 2>/dev/null || true

# 6. A regular FILE where $RUN should be: `mkdir -p` cannot make it a directory.
: > "$IX/run-is-a-file"
RUN=$IX/run-is-a-file INTENT=$IX/plain.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ix-file.out" 2> "$SANDBOX/ix-file.log"
IX_FILE_RC=$?
if [[ "$IX_FILE_RC" -eq 2 ]]; then pass "a regular file at \$RUN exits 2"
else fail "a regular file at \$RUN exited $IX_FILE_RC (want 2)"; fi
expect "the error names the run dir" \
  bash -c "grep -q '^ERROR:' '$SANDBOX/ix-file.log' && grep -q 'run-is-a-file' '$SANDBOX/ix-file.log'"

# 7. Non-regression: an ABSENT intent file is still a legitimate empty vet — exit 0
#    with all three outputs present. That is the case the hard errors must not
#    swallow, and the only reading of "this component has no standing intent".
mkdir -p "$IX/run-absent"
RUN=$IX/run-absent INTENT=$IX/never-existed.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ix-absent.out" 2> "$SANDBOX/ix-absent.log"
expect "an absent intent file still exits 0" test $? -eq 0
expect "counts: an absent intent file vets empty" \
  bash -c "grep -qx 'ACTIVE=0' '$SANDBOX/ix-absent.out' && grep -qx 'QUARANTINED=0' '$SANDBOX/ix-absent.out' && grep -qx 'UNPARSEABLE=0' '$SANDBOX/ix-absent.out'"
expect "all three output files exist after an empty vet" \
  bash -c "test -f '$IX/run-absent/intent-active.md' && test -f '$IX/run-absent/intent-quarantined.md' && test -f '$IX/run-absent/intent-unparseable.md'"
refute "an absent intent file is not an error" \
  grep -q '^ERROR:' "$SANDBOX/ix-absent.log"
cd "$SANDBOX"

fi

if t "intent-ledger wiring — sweep before dispatch, both paths in every resolver prompt"; then
# The prompt-template rule and the sweep-before-dispatch ordering are what close
# C3's fresh-context gap; if either drops out of the prose, the fan-out silently
# loses everything the user said.
expect "phases/5-structural.md runs scripts/intent-check.sh" \
  grep -qF 'scripts/intent-check.sh' "$SKILL_DIR/phases/5-structural.md"
expect "phase 5 dispatch prompt carries the run Q&A ledger path" \
  grep -qF '$RUN/qa-ledger.tsv' "$SKILL_DIR/phases/5-structural.md"
expect "phase 5 dispatch prompt carries the vetted standing-intent path" \
  grep -qF '$RUN/intent-active.md' "$SKILL_DIR/phases/5-structural.md"
expect "phase 5 declares a resolver prompt without the ledger paths malformed" \
  grep -qi 'malformed' "$SKILL_DIR/phases/5-structural.md"
SWEEP_LINE=$(grep -n 'intent sweep' "$SKILL_DIR/phases/5-structural.md" | head -1 | cut -d: -f1)
DISPATCH_LINE=$(grep -n 'Conflict-resolver fan-out' "$SKILL_DIR/phases/5-structural.md" | head -1 | cut -d: -f1)
if [[ -n "$SWEEP_LINE" ]] && [[ -n "$DISPATCH_LINE" ]] && [[ "$SWEEP_LINE" -lt "$DISPATCH_LINE" ]]; then
  pass "the mandatory intent sweep is a numbered step BEFORE the dispatch step"
else
  fail "the mandatory intent sweep is a numbered step BEFORE the dispatch step (sweep=$SWEEP_LINE dispatch=$DISPATCH_LINE)"
fi
expect "phase 5 routes modify-delete-for-ai rows through the resolver dispatch" \
  bash -c "grep -q 'modify-delete-for-ai' '$SKILL_DIR/phases/5-structural.md'"
# The resolver delete bookkeeping used to be a prose hand-append at this dispatch
# site — a decision→artifact seam with no gate row over it, so a forgotten append
# silently dropped a stale-reference follow-up. It is DERIVED now, from the ledger
# the verdicts already land in, and there must be exactly one path by which a delete
# becomes a follow-up: the prose step is gone, not merely documented.
refute "phase 5 no longer hand-appends resolver deletes to confirmed-deletes.txt" \
  bash -c "grep -qi 'the subagent never writes it' '$SKILL_DIR/phases/5-structural.md'"
expect "followup-completeness.sh derives kept-delete removals from the resolution ledger" \
  grep -qF 'kept-delete' "$SKILL_DIR/scripts/followup-completeness.sh"
expect "the derivation reads the per-batch shards too, not only the collected file" \
  grep -qF 'resolutions.*.tsv' "$SKILL_DIR/scripts/followup-completeness.sh"

expect "conflict-resolver consumes both intent inputs before deciding" \
  bash -c "grep -qF '\$RUN/qa-ledger.tsv' '$SKILL_DIR/agents/conflict-resolver.md' && grep -qF '\$RUN/intent-active.md' '$SKILL_DIR/agents/conflict-resolver.md'"
expect "a matching intent entry is cited verbatim in the reason column" \
  grep -qi 'cited verbatim' "$SKILL_DIR/agents/conflict-resolver.md"
expect "conflict-resolver carries the contradiction rule (tree-contradicting entry -> needs-input)" \
  bash -c "grep -qi 'contradiction rule' '$SKILL_DIR/agents/conflict-resolver.md' && grep -qi 'never silently applied' '$SKILL_DIR/agents/conflict-resolver.md'"
expect "conflict-resolver carries the never-resurrect invariant" \
  grep -qi 'never resurrected' "$SKILL_DIR/agents/conflict-resolver.md"
expect "conflict-resolver starts modify-delete porting from the component_path candidate" \
  grep -qF 'component_path' "$SKILL_DIR/agents/conflict-resolver.md"
expect "conflict-resolver carries the needs-input bias rule for the reasoning buckets" \
  grep -qi 'more readily' "$SKILL_DIR/agents/conflict-resolver.md"
for v in ported kept-delete kept-customization renamed-merged; do
  expect "conflict-resolver defines the extended verdict '$v'" \
    grep -qF -- "$v" "$SKILL_DIR/agents/conflict-resolver.md"
done

expect "SKILL.md documents the qa-ledger schema as an always-loaded invariant" \
  bash -c "grep -qF '\$RUN/qa-ledger.tsv' '$SKILL_DIR/SKILL.md' && grep -qF 'scope <TAB> question <TAB> answer <TAB> phase' '$SKILL_DIR/SKILL.md'"
expect "SKILL.md documents the committed .kairos/intent.md" \
  grep -qF '.kairos/intent.md' "$SKILL_DIR/SKILL.md"
expect "phase 6 planner reads both intent files" \
  bash -c "grep -qF '\$RUN/qa-ledger.tsv' '$SKILL_DIR/phases/6-planning.md' && grep -qF '.kairos/intent.md' '$SKILL_DIR/phases/6-planning.md'"
expect "phase 8 promotes qa-ledger rows into .kairos/intent.md, user-confirmed per row" \
  bash -c "grep -qF '\$RUN/qa-ledger.tsv' '$SKILL_DIR/phases/8-finalize.md' && grep -qF '.kairos/intent.md' '$SKILL_DIR/phases/8-finalize.md' && grep -qi 'never automatic' '$SKILL_DIR/phases/8-finalize.md'"
expect "phase 8 proposes a guard alongside each promoted entry" \
  grep -qF 'guard:' "$SKILL_DIR/phases/8-finalize.md"

# The guard trust model is a security boundary, so it is stated authoritatively in
# reference/intent-guard.md (the single doc home for the grammar), in the runner's header,
# and each site where guards are VETTED (phase 5) or AUTHORED (phase 8) points there — not
# left implicit in the parser. A doc that still calls a guard a "shell test" invites exactly
# the guard that gets the entry excluded, or worse.
expect "reference/intent-guard.md states the guard trust model" \
  bash -c "grep -qi 'guard trust model' '$SKILL_DIR/reference/intent-guard.md' && grep -qi 'untrusted input' '$SKILL_DIR/reference/intent-guard.md'"
expect "phase 5 (vetting) points at the guard grammar reference" \
  grep -qF 'reference/intent-guard.md' "$SKILL_DIR/phases/5-structural.md"
expect "reference/intent-guard.md carries the closed grammar" \
  bash -c "grep -qF 'test [!] -e|-f|-d|-s' '$SKILL_DIR/reference/intent-guard.md' && grep -qi 'never executed' '$SKILL_DIR/reference/intent-guard.md'"
expect "phase 8 (authoring) points at the guard grammar reference" \
  grep -qF 'reference/intent-guard.md' "$SKILL_DIR/phases/8-finalize.md"
expect "the guard runner's header carries the trust model and the grammar" \
  bash -c "grep -q 'GUARD TRUST MODEL' '$SKILL_DIR/scripts/intent-check.sh' && grep -q 'GUARD GRAMMAR' '$SKILL_DIR/scripts/intent-check.sh'"
expect "SKILL.md's always-loaded line says a guard is never shell" \
  bash -c "grep -qi 'never.*shell' '$SKILL_DIR/SKILL.md'"
expect "promote-intent.sh's GUARD doc points at the grammar owner" \
  bash -c "grep -qi 'grammar owner' '$SKILL_DIR/scripts/promote-intent.sh'"
# Fixed-once: the defect was one `bash -c \"\$1\"`. No executable line of the guard
# runner may hand anything to a shell again (comments describing the ban are fine).
refute "intent-check.sh has no eval / bash -c / sh -c in any executable line" \
  bash -c "grep -v '^[[:space:]]*#' '$SKILL_DIR/scripts/intent-check.sh' | grep -qE '\beval\b|bash -c|sh -c'"
# Every guard example the skill ships must itself be inside the grammar, or the docs
# teach the shape that gets excluded. This lint used to carry its OWN grammar — a
# regex that accepted any line starting `test`/`grep`, over two-space-indented
# examples in three directories — so `grep -qr needle web` (out of grammar) and
# anything under agents/ passed it. It now feeds every example through the runner's
# own parser (ACTION=parse-only), which makes the parser the single source of truth
# for the lint too: the lint cannot drift from what the runner accepts.
#
# Two extraction shapes, because the skill writes examples both ways:
#   * a guard at the start of a line, at ANY indentation, optionally behind a `#`
#     (markdown blocks and the script headers' worked examples);
#   * an inline `` `guard: …` `` in prose — markdown only, because the script
#     headers use single-letter metavariables (`guard: A`) when they discuss shapes.
# Placeholders are not examples: a guard containing `<`/`>` is a grammar
# metavariable (`guard: <tree assertion>`) and one containing `%s` is a printf
# template. Neither can appear in a real guard — the charset and pattern rules
# reject both characters — so skipping them cannot hide a bad example.
guard_examples() {  # guard_examples <md-or-sh path…> — one candidate per line
  grep -rhE '^[[:space:]]*(#[[:space:]]*)?guard:[[:space:]]' "$@" 2>/dev/null \
    | sed -E 's/^[[:space:]]*(#[[:space:]]*)?guard:[[:space:]]*//; s/[[:space:]]+$//'
}
md_guard_examples() {  # md_guard_examples <md path…> — inline prose examples
  grep -rhoE '`guard:[[:space:]][^`]+`' "$@" 2>/dev/null \
    | sed -E 's/^`guard:[[:space:]]*//; s/`$//; s/[[:space:]]+$//'
}
collect_guards() {  # collect_guards <md-path…> [--with-scripts <dir>]
  local md=() scripts=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --with-scripts) scripts=$2; shift 2 ;;
      *) md+=("$1"); shift ;;
    esac
  done
  { guard_examples "${md[@]}" ${scripts:+"$scripts"}; md_guard_examples "${md[@]}"; } \
    | grep -v '%s' | grep -v '[<>]' | grep . | sort -u
}
lint_guards() {  # lint_guards <out-file> <collect_guards args…> — findings -> file
  local out=$1; shift
  collect_guards "$@" \
    | env -u RUN ACTION=parse-only "$SKILL_DIR/scripts/intent-check.sh" \
    | awk -F'\t' '$1 == "unparseable" { print $2 " — " $3 }' > "$out"
}
DOC_PATHS=("$SKILL_DIR/SKILL.md" "$SKILL_DIR/phases" "$SKILL_DIR/reference" "$SKILL_DIR/agents")
# Non-vacuity: a lint that extracts nothing passes forever. The skill ships at least
# one worked guard example; if a refactor moves them all, this fails first.
DOC_GUARD_N=$(collect_guards "${DOC_PATHS[@]}" --with-scripts "$SKILL_DIR/scripts" | grep -c .)
expect "the lint actually finds guard examples to check (found $DOC_GUARD_N)" \
  test "$DOC_GUARD_N" -ge 1
lint_guards "$SANDBOX/lint-real.txt" "${DOC_PATHS[@]}" --with-scripts "$SKILL_DIR/scripts"
expect "every 'guard:' example the skill ships parses under the runner's own grammar" \
  bash -c "test ! -s '$SANDBOX/lint-real.txt' || { cat '$SANDBOX/lint-real.txt' >&2; false; }"
# The lint itself must be able to go red — proven on a fixture, never by breaking a
# real doc. Both extraction shapes and both directions are exercised.
LF=$SANDBOX/lint-fixture
mkdir -p "$LF/phases"
printf -- '# fixture\n\nAn entry:\n\n    guard: test -e go.mod\n\nInline: `guard: grep -qF needle go.mod` is fine.\n' \
  > "$LF/good.md"
printf -- '# fixture\n\n    guard: go build ./...\n\nInline: `guard: test -e web/ && touch x` is not.\n\t  guard: grep -qr needle web\n' \
  > "$LF/phases/bad.md"
lint_guards "$SANDBOX/lint-good.txt" "$LF/good.md"
expect "the lint passes a fixture whose examples are all in grammar" \
  test ! -s "$SANDBOX/lint-good.txt"
lint_guards "$SANDBOX/lint-bad.txt" "$LF/phases/bad.md"
expect "the lint FAILS on a deliberately out-of-grammar example (fixture, not a real doc)" \
  test -s "$SANDBOX/lint-bad.txt"
for bad in 'go build ./...' 'test -e web/ && touch x' 'grep -qr needle web'; do
  expect "the lint names the offending example '$bad'" \
    grep -qF -- "$bad" "$SANDBOX/lint-bad.txt"
done
expect "the lint reads examples at ANY indentation, tab-indented included" \
  grep -qF -- 'grep -qr needle web' "$SANDBOX/lint-bad.txt"
printf '%s\n' "${DOC_PATHS[@]}" > "$SANDBOX/lint-paths.txt"
for tree in SKILL.md phases reference agents; do
  expect "the lint's path list covers $tree (agents/ and reference/ used to be missing)" \
    grep -qF -- "$SKILL_DIR/$tree" "$SANDBOX/lint-paths.txt"
done

fi

if t "intent-check.sh — a guard indented with a WHITESPACE VARIANT is reported, never structure"; then
# NBSP (a routine browser/Confluence paste artifact), VT and FF are not in the
# indentation grammar (space/tab, in step with promote-intent.sh's reading
# model) — but a `guard:` behind one used to fall through the column-0 catch-all
# as STRUCTURE: the entry above went ACTIVE with its guard never evaluated and
# the guard line rode into intent-active.md as prose — a silent quarantine
# bypass, the cheapest one in the untrusted-committed-file threat model.
IWV=$SANDBOX/intent-wsvariant
mkdir -p "$IWV" && cd "$IWV"
IWV_NBSP=$(printf '\302\240')
{ printf -- '- 2026-11-01: unrelated fact before\n'
  printf -- '- 2026-11-02: fact whose guard is NBSP-indented\n'
  printf -- '%sguard: test -e nonexistent-by-design\n' "$IWV_NBSP"
  printf -- '- 2026-11-03: fact whose guard is VT-indented\n'
  printf -- '\vguard: test -e nonexistent-by-design\n'
  printf -- '- 2026-11-04: unrelated fact after\n'
} > wsv.md
RUN=$IWV/run INTENT=$IWV/wsv.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/iwv.out" 2> "$SANDBOX/iwv.log"
expect "a whitespace-variant guard is a finding, not an error (exit 0)" test $? -eq 0
expect "both mis-indented guards report — the entries and the guard lines (UNPARSEABLE=4)" \
  grep -qx 'UNPARSEABLE=4' "$SANDBOX/iwv.out"
for d in 02 03; do
  refute "the 2026-11-$d entry never reaches resolver input (its guard never ran)" \
    grep -q "2026-11-$d" "$IWV/run/intent-active.md"
done
refute "the guard line itself never leaks into the active view as prose" \
  grep -q 'nonexistent-by-design' "$IWV/run/intent-active.md"
expect "the unrelated entries still vet active (ACTIVE=2)" \
  grep -qx 'ACTIVE=2' "$SANDBOX/iwv.out"
expect "the reason names the whitespace variant, so the re-indent repair is obvious" \
  bash -c "grep '^UNPARSEABLE:' '$SANDBOX/iwv.log' | grep -qi 'whitespace variant'"
cd "$SANDBOX"
fi

if t "intent-check.sh — a guard behind ANY non-grammar indent is refused, in EVERY locale"; then
# The whitespace-variant rule above was a hard-coded SIX-BYTE list stripped off the front
# of the line ({SP, TAB, VT, FF, CR, NBSP}), with every other byte falling through to
# prose. Two proven bypasses, both in the untrusted-committed-file threat model:
#   * a lead the list did not name — U+200B ZERO WIDTH SPACE, U+3000 IDEOGRAPHIC SPACE —
#     fell through the column-0 catch-all as STRUCTURE: the entry above went ACTIVE
#     guardless, the `guard:` line was copied into intent-active.md as prose, NOTHING was
#     reported and the run exited 0;
#   * `<SP><NBSP>guard:` never reached the list at all (it starts with a space), so the
#     INDENTED branch classified it with a `[[:space:]]` glob — which counts an NBSP as
#     space under en_US.UTF-8 and does NOT under LC_ALL=C. The same committed file
#     therefore vetted the entry ACTIVE on one operator's box and QUARANTINED on
#     another's: a security verdict decided by the ambient locale.
# The rule is now an ALLOWLIST of the indents that ARE the grammar (space/tab, or column
# 0), so any other lead in front of a `guard:` is a finding whatever bytes it is made of,
# and the whole script runs under a pinned LC_ALL=C. Asserted for every shape under BOTH a
# C and a UTF-8 locale, byte-comparing the two verdicts.
IHG=$SANDBOX/intent-hiddenguard
mkdir -p "$IHG" && cd "$IHG"
IHG_ZWSP=$(printf '\342\200\213')     # U+200B, outside the old byte list
IHG_IDEO=$(printf '\343\200\200')     # U+3000, outside the old byte list
IHG_NBSP=$(printf '\302\240')         # U+00A0, in the list but behind a plain space
{ printf -- '- 2026-12-10: fact whose guard hides behind U+200B\n'
  printf -- '%sguard: test -e zwsp-target\n' "$IHG_ZWSP"
  printf -- '- 2026-12-11: fact whose guard hides behind U+3000\n'
  printf -- '%sguard: test -e ideo-target\n' "$IHG_IDEO"
  printf -- '- 2026-12-12: fact whose guard hides behind SPACE+NBSP\n'
  printf -- ' %sguard: test -e nbsp-target\n' "$IHG_NBSP"
  printf -- '- 2026-12-13: control fact, plainly indented guard\n'
  printf -- '  guard: test -e hidden.md\n'
} > hidden.md
IHG_REF=""
for L in C en_US.UTF-8; do
  SAFE=$(printf '%s' "$L" | tr -c 'A-Za-z0-9' '_')
  LC_ALL=$L RUN=$IHG/run-$SAFE INTENT=$IHG/hidden.md "$SKILL_DIR/scripts/intent-check.sh" \
    > "$SANDBOX/ihg-$SAFE.out" 2> "$SANDBOX/ihg-$SAFE.log"
  expect "LC_ALL=$L: a hidden guard is a finding, not an error (exit 0)" test $? -eq 0
  # 3 entries + 3 guard lines reported; the control entry is the only ACTIVE one.
  expect "LC_ALL=$L: all three hidden guards report, with their entries (UNPARSEABLE=6)" \
    grep -qx 'UNPARSEABLE=6' "$SANDBOX/ihg-$SAFE.out"
  expect "LC_ALL=$L: only the plainly-indented control entry vets ACTIVE (ACTIVE=1)" \
    grep -qx 'ACTIVE=1' "$SANDBOX/ihg-$SAFE.out"
  for d in 10 11 12; do
    refute "LC_ALL=$L: the 2026-12-$d entry never reaches resolver input" \
      grep -q "2026-12-$d" "$IHG/run-$SAFE/intent-active.md"
  done
  for tgt in zwsp-target ideo-target nbsp-target; do
    refute "LC_ALL=$L: the $tgt guard line never leaks into the active view as prose" \
      grep -q "$tgt" "$IHG/run-$SAFE/intent-active.md"
  done
  expect "LC_ALL=$L: every hidden guard line lands in intent-unparseable.md" \
    bash -c "test \"\$(grep -c 'guard:' '$IHG/run-$SAFE/intent-unparseable.md')\" -eq 3"
  expect "LC_ALL=$L: the reason names the repair (re-indent with plain spaces)" \
    bash -c "grep '^UNPARSEABLE:' '$SANDBOX/ihg-$SAFE.log' | grep -qi 'plain spaces'"
  expect "LC_ALL=$L: the control entry is still evaluated and still ACTIVE" \
    grep -qF -- '- 2026-12-13: control fact' "$IHG/run-$SAFE/intent-active.md"
  if [[ -z "$IHG_REF" ]]; then IHG_REF=$SAFE; else
    expect "LC_ALL=$L verdict is byte-identical to LC_ALL=C's (no locale-dependent bucket)" \
      cmp -s "$SANDBOX/ihg-$IHG_REF.out" "$SANDBOX/ihg-$SAFE.out"
    # A locale the box does not HAVE makes bash print its own `setlocale` warning on
    # stderr — the environment talking, not the parser (the Ubuntu image ships no
    # en_US.UTF-8) — so it is filtered out before the findings are compared.
    grep -v setlocale "$SANDBOX/ihg-$IHG_REF.log" > "$SANDBOX/ihg-ref.norm" || true
    grep -v setlocale "$SANDBOX/ihg-$SAFE.log"    > "$SANDBOX/ihg-cmp.norm" || true
    expect "LC_ALL=$L findings are byte-identical to LC_ALL=C's" \
      cmp -s "$SANDBOX/ihg-ref.norm" "$SANDBOX/ihg-cmp.norm"
  fi
done
# The classification path must stay BOUNDED, the sibling of the 30KB guard-token cap
# below. Its predecessor forked THREE subshells per byte stripped — `"$(printf '\v')"*`
# re-evaluated on every loop iteration — at classification time, i.e. BEFORE guard_parse's
# 4096-character cap and outside GUARD_TIMEOUT: a 30KB mis-indented line measured ~38s,
# per line, and a megabyte of them wedged Phase 5 before a single guard ran.
python3 -c "
open('bigindent.md','wb').write(b'- 2026-12-14: mangled paste\n' + b'\xc2\xa0'*15000 + b'guard: test -e x\n')
" 2>/dev/null || { printf -- '- 2026-12-14: mangled paste\n' > bigindent.md
  { for i in $(seq 15000); do printf '\302\240'; done; printf 'guard: test -e x\n'; } >> bigindent.md; }
IHG_S=$(date +%s)
RUN=$IHG/run-big INTENT=$IHG/bigindent.md "$SKILL_DIR/scripts/intent-check.sh" \
  > "$SANDBOX/ihg-big.out" 2> "$SANDBOX/ihg-big.log"
IHG_RC=$?; IHG_E=$(date +%s)
expect "a 30KB whitespace-variant indent is a finding (exit 0)" test "$IHG_RC" -eq 0
expect "the 30KB hidden guard reports UNPARSEABLE, never ACTIVE" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/ihg-big.out"
expect "classifying it is bounded (under 10s, was ~38s of forks per line)" \
  test $((IHG_E - IHG_S)) -lt 10
cd "$SANDBOX"
fi

if t "intent-check.sh — parser wedges and misreports closed: token cap, timeout overflow, '--- '"; then
IPW=$SANDBOX/intent-parsewedge
mkdir -p "$IPW" && cd "$IPW"
# (1) The guard-token length cap. path_charset_ok and the grep-flag walk re-slice
# the token per character (quadratic) during PARSING, so GUARD_TIMEOUT never
# bounds them: a single mangled 30KB guard line cost ~30s and 1MB extrapolates to
# hours. Past 4096 characters the verdict is already known — refused, instantly.
python3 -c "print('- 2026-11-05: mangled paste\n  guard: test -e ' + 'a'*30000)" > big.md 2>/dev/null \
  || { printf -- '- 2026-11-05: mangled paste\n  guard: test -e ' ; printf 'a%.0s' $(seq 30000); printf '\n'; } > big.md
IPW_S=$(date +%s)
RUN=$IPW/run INTENT=$IPW/big.md "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/ipw.out" 2> "$SANDBOX/ipw.log"
IPW_RC=$?; IPW_E=$(date +%s)
expect "a 30KB guard is a finding (exit 0), refused by the cap" test "$IPW_RC" -eq 0
expect "the oversized guard reports UNPARSEABLE, never ACTIVE" \
  grep -qx 'UNPARSEABLE=1' "$SANDBOX/ipw.out"
expect "the refusal names the length, so the repair is obvious" \
  bash -c "grep -q 'characters long' '$SANDBOX/ipw.log'"
expect "parsing it is bounded (under 10s, was ~30s quadratic)" \
  test $((IPW_E - IPW_S)) -lt 10
# (2) GUARD_TIMEOUT >= 2^63: all digits, so the charset gate passed it, and
# `[ … -gt 3600 ]` ERRORED (rc 2 = false in an || chain) instead of refusing —
# the value reached alarm, wrapped to NO alarm, and a fifo guard wedged forever.
printf -- '- 2026-11-06: any fact\n' > tiny.md
RUN=$IPW/run2 INTENT=$IPW/tiny.md GUARD_TIMEOUT=9223372036854775808 \
  "$SKILL_DIR/scripts/intent-check.sh" > /dev/null 2> "$SANDBOX/ipw-to.log"
expect "a 2^63 GUARD_TIMEOUT is refused up front (exit 2)" test $? -eq 2
expect "the refusal says out of range, not a shell arithmetic diagnostic" \
  grep -q 'out of range' "$SANDBOX/ipw-to.log"
# (3) '--- ' (trailing whitespace) is the same markdown thematic break as '---':
# reporting it "bullet marker '-' without a following space" misnamed the line
# and invited a sanctioned-looking hand-delete of structure. promote-intent.sh
# reads either spelling as a closer, so the parsers stay in step.
{ printf -- '- 2026-11-07: fact above a break\n'
  printf -- '--- \n'
  printf -- '- 2026-11-08: fact below it\n'
  printf -- '-notabullet\n'
} > brk.md
RUN=$IPW/run3 INTENT=$IPW/brk.md "$SKILL_DIR/scripts/intent-check.sh" > "$SANDBOX/ipw-brk.out" 2>&1
expect "'--- ' passes as structure; only the real malformation reports (UNPARSEABLE=1)" \
  grep -qx 'UNPARSEABLE=1' "$SANDBOX/ipw-brk.out"
expect "both facts around the break vet active (ACTIVE=2)" \
  grep -qx 'ACTIVE=2' "$SANDBOX/ipw-brk.out"
expect "the trailing-whitespace break is kept in the active view as structure" \
  grep -q -- '---' "$IPW/run3/intent-active.md"
cd "$SANDBOX"
fi

if t "intent-check.sh — a failed FINAL write is a stop, never counts over a missing view"; then
# The active view is the run's last write and the only file anything downstream
# reads. ENOSPC there used to leave intent-active.md empty or truncated while
# ACTIVE=<n> printed and the script exited 0 — "counts printed, file not on
# disk". The startup writability probe cannot see it: it truncates the outputs
# (which succeeds even on a full device), and only the final non-empty printf
# hits the wall. Forced deterministically with a symlink to /dev/full — Linux
# only, so this block self-skips on macOS and gets its coverage in the
# tests/ubuntu/ run.
if [[ -e /dev/full ]] && [[ -w /dev/full ]]; then
  IFW=$SANDBOX/intent-fullwrite
  mkdir -p "$IFW/run" && cd "$IFW"
  printf -- '- 2026-12-01: a fact that must land in the active view\n' > intent.md
  ln -s /dev/full "$IFW/run/intent-active.md"
  RUN=$IFW/run INTENT=$IFW/intent.md "$SKILL_DIR/scripts/intent-check.sh" \
    > "$SANDBOX/ifw.out" 2> "$SANDBOX/ifw.err"; rc=$?
  if [[ "$rc" -eq 2 ]]; then pass "a failed final write exits 2, not 0-with-counts"; else fail "a failed final write exits 2, not 0-with-counts (rc=$rc)"; fi
  expect "the error names the file and the remedy" \
    bash -c "grep -q 'could not write' '$SANDBOX/ifw.err'"
  refute "no ACTIVE= count is printed over a view that never landed" \
    grep -q '^ACTIVE=' "$SANDBOX/ifw.out"
  cd "$SANDBOX"

  # The finding buckets are appended DURING the walk (append_finding), not at the end,
  # and those appends were unchecked — a short write (ENOSPC, a $RUN that vanished after
  # the startup probe) left QUARANTINED=/UNPARSEABLE= counting more than the file held,
  # exit 0. Same /dev/full forcing, one bucket each: only the failing bucket is symlinked,
  # so its startup truncation still succeeds and only the mid-walk append hits the wall.
  IFQ=$SANDBOX/intent-fullwrite-quar
  mkdir -p "$IFQ/run" && cd "$IFQ"
  printf -- '- 2026-12-01: a fact whose guard fails\n  guard: test -e definitely-absent-file\n' > intent.md
  ln -s /dev/full "$IFQ/run/intent-quarantined.md"
  RUN=$IFQ/run INTENT=$IFQ/intent.md "$SKILL_DIR/scripts/intent-check.sh" \
    > "$SANDBOX/ifq.out" 2> "$SANDBOX/ifq.err"; rc=$?
  if [[ "$rc" -eq 2 ]]; then pass "a failed quarantine-bucket append exits 2, not 0-with-counts"; else fail "a failed quarantine-bucket append exits 2, not 0-with-counts (rc=$rc)"; fi
  expect "the quarantine-append error names the file it could not write" \
    bash -c "grep -q 'could not write' '$SANDBOX/ifq.err'"
  refute "no QUARANTINED= count is printed over a finding that never landed" \
    grep -q '^QUARANTINED=' "$SANDBOX/ifq.out"
  cd "$SANDBOX"

  IFU=$SANDBOX/intent-fullwrite-unparse
  mkdir -p "$IFU/run" && cd "$IFU"
  printf -- '* a bullet in the wrong list style\n' > intent.md
  ln -s /dev/full "$IFU/run/intent-unparseable.md"
  RUN=$IFU/run INTENT=$IFU/intent.md "$SKILL_DIR/scripts/intent-check.sh" \
    > "$SANDBOX/ifu.out" 2> "$SANDBOX/ifu.err"; rc=$?
  if [[ "$rc" -eq 2 ]]; then pass "a failed unparseable-bucket append exits 2, not 0-with-counts"; else fail "a failed unparseable-bucket append exits 2, not 0-with-counts (rc=$rc)"; fi
  expect "the unparseable-append error names the file it could not write" \
    bash -c "grep -q 'could not write' '$SANDBOX/ifu.err'"
  refute "no UNPARSEABLE= count is printed over a finding that never landed" \
    grep -q '^UNPARSEABLE=' "$SANDBOX/ifu.out"
  cd "$SANDBOX"
else
  pass "skipped: /dev/full not available on this platform (covered by the tests/ubuntu/ run)"
  pass "skipped: quarantine-bucket append fail-close (no /dev/full)"
  pass "skipped: quarantine-append error message (no /dev/full)"
  pass "skipped: quarantine-append no-counts (no /dev/full)"
  pass "skipped: unparseable-bucket append fail-close (no /dev/full)"
  pass "skipped: unparseable-append error message (no /dev/full)"
  pass "skipped: unparseable-append no-counts (no /dev/full)"
fi
fi

finish_suite
