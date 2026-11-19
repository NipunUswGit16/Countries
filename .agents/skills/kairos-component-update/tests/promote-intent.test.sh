#!/usr/bin/env bash
# promote-intent.test.sh — tests for scripts/promote-intent.sh
# TEST_FILTER supported (blocks are independent; each builds its own intent file).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

PIS="$SKILL_DIR/scripts/promote-intent.sh"
ICS="$SKILL_DIR/scripts/intent-check.sh"

if t "promote-intent.sh append — the two-line shape round-trips through intent-check.sh"; then
# This block PINS the interface:
#   env in : INTENT (path, default .kairos/intent.md), ENTRY (the fact), optional
#            GUARD, optional DATE (default today, UTC). ACTION defaults to append.
#   effect : ONE entry appended in the exact shape intent-check.sh parses —
#            `- <date>: <fact>` plus, when GUARD is set, an indented
#            `guard: <test>` beneath it.
#   WHY a writer: this file is machine-parsed CROSS-RUN and was prose-written in
#   three places (Phase 8's promotion, Phase 5's re-confirm, abort's salvage).
#   intent-check.sh already ships an intent-unparseable.md output BECAUSE the file
#   arrives malformed, and names an orphaned column-0 `guard:` — which silently
#   de-guards the entry above it — as the worst case. Detection was standing in for
#   a writer that makes the shape impossible.
#   The round-trip through the real parser is the assertion that matters: writer and
#   parser asserted against each other, not against a hand-built fixture.
PI=$SANDBOX/pi-append
mkdir -p "$PI"
INT="$PI/intent.md"

INTENT=$INT ENTRY='web/ is deliberately absent — the team removed the web UI' \
  GUARD='test ! -e web/' DATE=2026-08-06 bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: an append exits 0"; else fail "promote-intent: an append exits 0 (rc=$rc)"; fi
expect "promote-intent: the intent file is created when absent" test -f "$INT"
if [[ "$(sed -n 1p "$INT")" = '- 2026-08-06: web/ is deliberately absent — the team removed the web UI' ]]; then
  pass "promote-intent: the bullet is '- <date>: <fact>' at column 0"
else
  fail "promote-intent: the bullet is '- <date>: <fact>' at column 0 (got '$(sed -n 1p "$INT")')"
fi
expect "promote-intent: the guard is an INDENTED continuation line (never column 0)" \
  bash -c "sed -n 2p '$INT' | grep -qE '^[[:space:]]+guard: test ! -e web/\$'"

# The parser of record must read it as ONE active entry with a live guard.
PIR=$SANDBOX/pi-append-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-append.out" 2>/dev/null )
expect "promote-intent: intent-check.sh reports exactly one ACTIVE entry" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-append.out"
expect "promote-intent: intent-check.sh reports nothing unparseable" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-append.out"
expect "promote-intent: intent-check.sh reports nothing quarantined (the guard passed)" \
  grep -qx 'QUARANTINED=0' "$SANDBOX/pi-append.out"
expect "promote-intent: the entry reaches intent-active.md verbatim" \
  grep -qF -- '- 2026-08-06: web/ is deliberately absent' "$PIR/intent-active.md"

# A FAILING guard must quarantine — proof the guard line is genuinely attached to
# the entry, not merely present in the file.
mkdir -p "$PI/web"
PIR2=$SANDBOX/pi-append-run2
( cd "$PI" && RUN=$PIR2 INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-append2.out" 2>/dev/null )
expect "promote-intent: the written guard is attached to its entry (a failing guard quarantines it)" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-append2.out"
rmdir "$PI/web"

fi

if t "promote-intent.sh append — a guardless entry is guardless, not unparseable"; then
# This block PINS the interface:
#   GUARD unset writes the bullet ALONE. Guardless entries are legitimate — a fact
#   with no tree-checkable shape keeps the resolver-side contradiction rule as its
#   backstop — so the writer must not invent a guard, and the parser must not report
#   the entry as a finding.
PI=$SANDBOX/pi-guardless
mkdir -p "$PI"
INT="$PI/intent.md"
INTENT=$INT ENTRY='the team owns deployment; never touch chart/values-prod.yaml' DATE=2026-08-07 \
  bash "$PIS" >/dev/null 2>&1
if [[ "$(wc -l < "$INT" | tr -d ' ')" = 1 ]]; then pass "promote-intent: a guardless entry costs exactly one line"; else fail "promote-intent: a guardless entry costs exactly one line"; fi
refute "promote-intent: no guard line is invented" grep -q 'guard:' "$INT"
PIR=$SANDBOX/pi-guardless-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-guardless.out" 2>/dev/null )
expect "promote-intent: a guardless entry is ACTIVE" grep -qx 'ACTIVE=1' "$SANDBOX/pi-guardless.out"
expect "promote-intent: a guardless entry is not reported unparseable" grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-guardless.out"

fi

if t "promote-intent.sh append — newlines in either field collapse, so one entry costs one entry"; then
# This block PINS the interface:
#   ENTRY and GUARD are collapsed (newlines/CRs/tabs to single spaces, then trimmed)
#   before they reach the file — the same collapse() reason the three ledger writers
#   carry, sharpened by this file's grammar: a newline inside ENTRY would put its
#   tail at COLUMN 0, where the parser reads it as structure (silently promoted
#   prose) — or, if that tail happened to start with `guard:`, as an ORPHANED guard,
#   which de-guards the entry above it. That is the worst case intent-check.sh names.
PI=$SANDBOX/pi-collapse
mkdir -p "$PI"
INT="$PI/intent.md"
INTENT=$INT ENTRY="$(printf 'web/ is absent\nguard: true')" GUARD="$(printf 'test ! -e\tweb/')" \
  DATE=2026-08-08 bash "$PIS" >/dev/null 2>&1
if [[ "$(wc -l < "$INT" | tr -d ' ')" = 2 ]]; then pass "promote-intent: a newline-bearing ENTRY still costs one entry (2 lines with a guard)"; else fail "promote-intent: a newline-bearing ENTRY still costs one entry (got $(wc -l < "$INT") lines)"; fi
refute "promote-intent: nothing lands at column 0 except the bullet" \
  bash -c "grep -nE '^[^-[:space:]]' '$INT' | grep -q ."
if [[ "$(sed -n 1p "$INT")" = '- 2026-08-08: web/ is absent guard: true' ]]; then
  pass "promote-intent: the newline inside ENTRY collapsed to a space (no orphaned guard)"
else
  fail "promote-intent: the newline inside ENTRY collapsed to a space (got '$(sed -n 1p "$INT")')"
fi
if [[ "$(sed -n 2p "$INT")" = '  guard: test ! -e web/' ]]; then
  pass "promote-intent: the tab inside GUARD collapsed to a space"
else
  fail "promote-intent: the tab inside GUARD collapsed to a space (got '$(sed -n 2p "$INT")')"
fi
PIR=$SANDBOX/pi-collapse-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-collapse.out" 2>/dev/null )
expect "promote-intent: the collapsed entry is still one parseable ACTIVE entry" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-collapse.out"
expect "promote-intent: the collapsed entry produces no orphaned-guard finding" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-collapse.out"

fi

if t "promote-intent.sh append — an identical entry is idempotent"; then
# This block PINS the interface:
#   Re-appending an identical entry is a no-op. Phase 8's promotion, Phase 5's
#   re-confirm and abort's salvage can all run over the same fact in one component's
#   life (abort salvages, the next run promotes), and a stacked duplicate would
#   double every guard evaluation and every resolver's reading of the same fact.
PI=$SANDBOX/pi-idem
mkdir -p "$PI"
INT="$PI/intent.md"
for _ in 1 2 3; do
  INTENT=$INT ENTRY='web/ is deliberately absent' GUARD='test ! -e web/' DATE=2026-08-09 \
    bash "$PIS" >/dev/null 2>&1
done
if [[ "$(grep -c 'web/ is deliberately absent' "$INT")" = 1 ]]; then pass "promote-intent: three identical appends leave one entry"; else fail "promote-intent: three identical appends leave one entry (got $(grep -c 'web/ is deliberately absent' "$INT"))"; fi
if [[ "$(wc -l < "$INT" | tr -d ' ')" = 2 ]]; then pass "promote-intent: the idempotent file is still bullet + guard"; else fail "promote-intent: the idempotent file is still bullet + guard"; fi

# Idempotence is on the FACT, not on the date. WHY: the same fact legitimately
# arrives on a LATER day — a run that crosses UTC midnight (Phase 5 re-confirms on
# day A, Phase 8 promotes on day B), or an abort salvaged and re-promoted the next
# run. With date-scoped dedup that appended a SECOND entry for one fact, and two
# entries for one fact make every later retire/update refuse ("2 entries … refusing
# to guess which one") — the fact could then never be retired. The existing entry
# wins as-is: its date is when the fact was first recorded.
INTENT=$INT ENTRY='web/ is deliberately absent' GUARD='test ! -e web/' DATE=2026-09-01 \
  bash "$PIS" > "$SANDBOX/pi-idem.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-idem.out")" = unchanged ]]; then
  pass "promote-intent: the same fact under a DIFFERENT date is 'unchanged'"
else
  fail "promote-intent: the same fact under a DIFFERENT date is 'unchanged' (rc=$rc, said '$(cat "$SANDBOX/pi-idem.out")')"
fi
if [[ "$(grep -c 'web/ is deliberately absent' "$INT")" = 1 ]]; then
  pass "promote-intent: a re-dated fact leaves exactly one entry"
else
  fail "promote-intent: a re-dated fact leaves exactly one entry (got $(grep -c 'web/ is deliberately absent' "$INT"))"
fi
if [[ "$(sed -n 1p "$INT")" = '- 2026-08-09: web/ is deliberately absent' ]]; then
  pass "promote-intent: the EXISTING date wins (re-dating is what ACTION=update is for)"
else
  fail "promote-intent: the EXISTING date wins (got '$(sed -n 1p "$INT")')"
fi
# The point of all of it: the fact stays retirable. A dated duplicate is what made
# retire refuse.
INTENT=$INT ACTION=retire MATCH='web/ is deliberately absent' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: the de-duplicated fact is still retirable"; else fail "promote-intent: the de-duplicated fact is still retirable (rc=$rc)"; fi
refute "promote-intent: the retire left no trace of the fact" grep -q 'web/ is deliberately absent' "$INT"

fi

if t "promote-intent.sh append — an existing file's content is never disturbed"; then
# This block PINS the interface:
#   The file carries legitimate structure — headings, prose, blank lines, thematic
#   breaks — that the parser passes through. An append must not reflow or reorder
#   any of it.
PI=$SANDBOX/pi-existing
mkdir -p "$PI"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
# Standing intent

Facts about this component that outlive a single migration.

- 2026-01-01: the API is versioned in path, never in a header
  guard: test -f intent.md
EOF
cp "$INT" "$SANDBOX/pi-existing.orig"
INTENT=$INT ENTRY='vendor/ is committed on purpose' DATE=2026-08-10 bash "$PIS" >/dev/null 2>&1
expect "promote-intent: every pre-existing line survives verbatim" \
  bash -c "head -n \$(wc -l < '$SANDBOX/pi-existing.orig') '$INT' | cmp -s - '$SANDBOX/pi-existing.orig'"
expect "promote-intent: the new entry is the last line" \
  bash -c "test \"\$(tail -1 '$INT')\" = '- 2026-08-10: vendor/ is committed on purpose'"
PIR=$SANDBOX/pi-existing-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-existing.out" 2>/dev/null )
expect "promote-intent: both entries parse (ACTIVE=2)" grep -qx 'ACTIVE=2' "$SANDBOX/pi-existing.out"
expect "promote-intent: the heading and prose stay structure, not findings" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-existing.out"

fi

if t "promote-intent.sh retire — removes the bullet AND its guard, never leaving an orphan"; then
# This block PINS the interface:
#   ACTION=retire, env in MATCH (the fact of the entry to remove). It deletes the
#   bullet AND every continuation line beneath it — which is the orphaned-guard
#   failure in reverse: a prose retire that deletes only the bullet leaves a
#   column-0 `guard:` behind, and intent-check.sh then de-guards whatever entry
#   happens to sit above it. Retiring a fact that is not there is refused, not
#   silently ignored: "I retired it" and "there was nothing to retire" must not be
#   the same answer about a committed file.
PI=$SANDBOX/pi-retire
mkdir -p "$PI"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
# Standing intent

- 2026-01-01: the API is versioned in path
  guard: test -f intent.md
- 2026-02-02: web/ is deliberately absent
  guard: test ! -e web/
- 2026-03-03: vendor/ is committed on purpose
EOF

INTENT=$INT ACTION=retire MATCH='web/ is deliberately absent' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: retire exits 0"; else fail "promote-intent: retire exits 0 (rc=$rc)"; fi
refute "promote-intent: retire removed the bullet" grep -q 'web/ is deliberately absent' "$INT"
refute "promote-intent: retire removed the entry's guard with it (no orphan left)" \
  grep -q 'guard: test ! -e web/' "$INT"
expect "promote-intent: retire left the entry above it intact" grep -q 'the API is versioned in path' "$INT"
expect "promote-intent: retire left that entry's own guard intact" grep -q 'guard: test -f intent.md' "$INT"
expect "promote-intent: retire left the entry below it intact" grep -q 'vendor/ is committed on purpose' "$INT"
expect "promote-intent: retire left the file's structure intact" grep -q '^# Standing intent' "$INT"

# The parser must see no orphaned guard and one fewer entry.
PIR=$SANDBOX/pi-retire-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-retire.out" 2>/dev/null )
expect "promote-intent: after retire, two entries remain ACTIVE" grep -qx 'ACTIVE=2' "$SANDBOX/pi-retire.out"
expect "promote-intent: after retire, nothing is unparseable (no orphaned guard)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-retire.out"

# Retiring something absent is refused and changes nothing.
cp "$INT" "$SANDBOX/pi-retire.snap"
INTENT=$INT ACTION=retire MATCH='never recorded this' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: retiring an entry that is not there is refused"; else fail "promote-intent: retiring an entry that is not there is refused (rc=$rc)"; fi
expect "promote-intent: the refused retire left the file byte-identical" cmp -s "$SANDBOX/pi-retire.snap" "$INT"

fi

if t "promote-intent.sh update — rewrites the fact, refreshes the date, keeps or replaces the guard"; then
# This block PINS the interface:
#   ACTION=update, env in MATCH (the fact to find) and ENTRY (the new fact),
#   optional GUARD (replace) / DROP_GUARD=1 (remove) / neither (keep). DATE is
#   refreshed by default — an updated fact is a fact re-confirmed today, and the
#   date is what the next run's reader judges staleness by.
PI=$SANDBOX/pi-update
mkdir -p "$PI"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
- 2026-01-01: web/ is deliberately absent
  guard: test ! -e web/
- 2026-02-02: vendor/ is committed on purpose
EOF

# Keep the guard: only the fact and the date move.
INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ was replaced by the standalone UI repo' DATE=2026-08-11 bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: update exits 0"; else fail "promote-intent: update exits 0 (rc=$rc)"; fi
if [[ "$(sed -n 1p "$INT")" = '- 2026-08-11: web/ was replaced by the standalone UI repo' ]]; then
  pass "promote-intent: update rewrote the fact and refreshed the date in place"
else
  fail "promote-intent: update rewrote the fact and refreshed the date (got '$(sed -n 1p "$INT")')"
fi
if [[ "$(sed -n 2p "$INT")" = '  guard: test ! -e web/' ]]; then
  pass "promote-intent: update KEPT the existing guard when none was given"
else
  fail "promote-intent: update KEPT the existing guard when none was given (got '$(sed -n 2p "$INT")')"
fi
expect "promote-intent: update left the other entry alone" grep -q '2026-02-02: vendor/ is committed on purpose' "$INT"
if [[ "$(grep -c 'standalone UI repo' "$INT")" = 1 ]]; then pass "promote-intent: update replaced in place rather than appending a second entry"; else fail "promote-intent: update replaced in place rather than appending a second entry"; fi

# Replace the guard.
INTENT=$INT ACTION=update MATCH='web/ was replaced by the standalone UI repo' \
  ENTRY='web/ was replaced by the standalone UI repo' GUARD='test ! -d web' DATE=2026-08-12 \
  bash "$PIS" >/dev/null 2>&1
if [[ "$(sed -n 2p "$INT")" = '  guard: test ! -d web' ]]; then pass "promote-intent: update REPLACED the guard when GUARD was given"; else fail "promote-intent: update REPLACED the guard when GUARD was given (got '$(sed -n 2p "$INT")')"; fi
if [[ "$(grep -c 'guard:' "$INT")" = 1 ]]; then pass "promote-intent: replacing a guard leaves exactly one guard line"; else fail "promote-intent: replacing a guard leaves exactly one guard line"; fi

# Drop the guard — the fact survives, guardless, with no orphan left behind.
INTENT=$INT ACTION=update MATCH='web/ was replaced by the standalone UI repo' \
  ENTRY='web/ was replaced by the standalone UI repo' DROP_GUARD=1 DATE=2026-08-13 \
  bash "$PIS" >/dev/null 2>&1
refute "promote-intent: DROP_GUARD=1 removed the guard line" grep -q 'guard:' "$INT"
expect "promote-intent: DROP_GUARD=1 kept the fact" grep -q 'standalone UI repo' "$INT"

PIR=$SANDBOX/pi-update-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-update.out" 2>/dev/null )
expect "promote-intent: the updated file still parses as two entries" grep -qx 'ACTIVE=2' "$SANDBOX/pi-update.out"
expect "promote-intent: the updated file has nothing unparseable" grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-update.out"

# Updating something absent is refused and changes nothing.
cp "$INT" "$SANDBOX/pi-update.snap"
INTENT=$INT ACTION=update MATCH='never recorded this' ENTRY='something else' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: updating an entry that is not there is refused"; else fail "promote-intent: updating an entry that is not there is refused (rc=$rc)"; fi
expect "promote-intent: the refused update left the file byte-identical" cmp -s "$SANDBOX/pi-update.snap" "$INT"

fi

if t "promote-intent.sh retire/update — a PRE-EXISTING orphaned column-0 guard is repairable, not a permanent block"; then
# This block PINS the interface:
#   a legacy column-0 `guard:` never BLOCKS a retire or an update, and the entry that
#   OWNS it is where it gets resolved — swept there when that entry already carries
#   guards of its own, so a component carrying the shape is repaired THROUGH the
#   writer, with no hand edit.
#   WHY it must not block: install()'s post-write invariant used to refuse to land a
#   file carrying ANY column-0 guard — one legacy orphan blocked retire and update of
#   every unrelated well-formed entry, while append (which appends in place) could not
#   remove it either. The file became append-only and un-repairable by its own format
#   owner, and intent-check.sh's quarantine -> Phase 5 re-confirm ->
#   `promote-intent.sh retire` loop dead-ended on it. Files predating this writer, or
#   hand-edited ones, really do carry the shape.
#   WHY the un-blocking is protection and not a sweep when the caller named a DIFFERENT
#   entry: the "a column-0 guard is unowned by definition, so deleting it destroys
#   nothing" argument is true of the LINE and false of the ENTRY ABOVE IT, which
#   intent-check.sh excludes BECAUSE of that line. Deleting it from under a foreign
#   entry promotes that entry into the active view — see the two cross-entry blocks
#   above. Acting on the OWNER is what resolves it.
PI=$SANDBOX/pi-orphan
mkdir -p "$PI/retire" "$PI/update"
for d in retire update; do
  cat > "$PI/$d/intent.md" <<'EOF'
# Standing intent

- 2026-01-01: the API is versioned in path
  guard: test -f intent.md
guard: test ! -e web/
- 2026-03-03: vendor/ is committed on purpose
  guard: test -f intent.md
EOF
done

# (1) Retiring an UNRELATED entry succeeds despite the orphan, and removes only it.
INT="$PI/retire/intent.md"
INTENT=$INT ACTION=retire MATCH='vendor/ is committed on purpose' \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-orphan-retire.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: a legacy orphan does not block retiring an unrelated entry"; else fail "promote-intent: a legacy orphan does not block retiring an unrelated entry (rc=$rc)"; fi
refute "promote-intent: the retired entry is gone" grep -q 'vendor/ is committed on purpose' "$INT"
expect "promote-intent: the unrelated well-formed entry survives the retire" \
  grep -q '^- 2026-01-01: the API is versioned in path$' "$INT"
expect "promote-intent: that entry's OWNED (indented) guard survives it too" \
  grep -q '^  guard: test -f intent.md$' "$INT"
expect "promote-intent: the file's structure survives" grep -q '^# Standing intent' "$INT"
# The orphan belongs to the entry ABOVE it, which the caller never named — so it is
# LEFT, and that entry stays excluded for its own re-confirm rather than being promoted
# into the active view by a retire aimed somewhere else.
expect "promote-intent: the orphan of the entry the caller did NOT name is left in place" \
  grep -qx -- 'guard: test ! -e web/' "$INT"
refute "promote-intent: and nothing was reported swept — no committed line was deleted" \
  grep -q 'NOTE: swept' "$SANDBOX/pi-orphan-retire.err"
PIR=$SANDBOX/pi-orphan-retire-run
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-orphan-retire.out" 2>/dev/null )
refute "promote-intent: the un-named orphan's owner was NOT promoted into the active view" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-orphan-retire.out"
expect "promote-intent: it is still excluded — bullet plus orphan, awaiting its own re-confirm" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/pi-orphan-retire.out"

# (2) Acting on the OWNER is what removes the orphan. That entry already carries an
# indented guard, so adoption is refused (see (3)) and the line is SWEPT — a DELETE of
# a committed line the caller did not name, which is why it is announced. Silence would
# make this writer the second thing that quietly edits the file; the NOTE is what keeps
# the repair auditable in the run's own transcript.
INTENT=$INT ACTION=update MATCH='the API is versioned in path' \
  ENTRY='the API is versioned in path' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-orphan-repair.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: the orphan's OWNER can be updated, which is the repair"; else fail "promote-intent: the orphan's OWNER can be updated, which is the repair (rc=$rc)"; fi
expect "promote-intent: the sweep is ANNOUNCED on stderr, naming the guard TEXT that went" \
  grep -qF "NOTE: swept the orphaned column-0 guard 'test ! -e web/'" "$SANDBOX/pi-orphan-repair.err"
# The text alone is not enough to put the line back: which entry OWNED it is what says
# where it belonged, and a count said neither. The NOTE names the owner as the entry
# intent-check.sh ATTACHES the line to, because that reading — not adjacency — is what
# the verdict was decided on.
expect "promote-intent: and the NOTE names the entry it was attached to" \
  grep -qF "attaches it to the entry '- 2026-01-01: the API is versioned in path'" "$SANDBOX/pi-orphan-repair.err"
refute "promote-intent: no column-0 guard remains after the owner's own update" grep -qE '^guard:' "$INT"
PIR=$SANDBOX/pi-orphan-repair-run
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-orphan-repair.out" 2>/dev/null )
expect "promote-intent: after the sweep, intent-check.sh reports nothing unparseable" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-orphan-repair.out"
expect "promote-intent: after the sweep, the surviving entry is ACTIVE" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-orphan-repair.out"

# (3) Updating the entry sitting DIRECTLY ABOVE the orphan — the one intent-check.sh
# excludes alongside it — is exactly the Phase 5 re-confirm move, and must work.
INT="$PI/update/intent.md"
INTENT=$INT ACTION=update MATCH='the API is versioned in path' \
  ENTRY='the API is versioned in path, never in a header' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: the entry directly above an orphan can be updated"; else fail "promote-intent: the entry directly above an orphan can be updated (rc=$rc)"; fi
expect "promote-intent: the update rewrote the fact and refreshed the date" \
  grep -q '^- 2026-08-11: the API is versioned in path, never in a header$' "$INT"
expect "promote-intent: the update KEPT the entry's own guard" \
  grep -q '^  guard: test -f intent.md$' "$INT"
expect "promote-intent: the update left the entry below the orphan alone" \
  grep -q '^- 2026-03-03: vendor/ is committed on purpose$' "$INT"
refute "promote-intent: no column-0 guard remains after the update" grep -qE '^guard:' "$INT"
# ADOPTION MUST NOT FIRE HERE. The matched entry already owns an indented guard, so
# the orphan below it is a second, unrelated line — adopting it would silently
# staple a guard the user never attached to this fact onto it. Adoption is scoped to
# the one shape where it is a repair: an entry with NO guard of its own.
refute "promote-intent: the orphan is NOT adopted when the entry already owns a guard" \
  grep -qF 'test ! -e web/' "$INT"
if [[ "$(grep -c 'guard:' "$INT")" = 2 ]]; then pass "promote-intent: the file still carries exactly its two owned guards"; else fail "promote-intent: the file still carries exactly its two owned guards (got $(grep -c 'guard:' "$INT"))"; fi
PIR=$SANDBOX/pi-orphan-update-run
( cd "$PI/update" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-orphan-update.out" 2>/dev/null )
expect "promote-intent: the updated file has nothing unparseable" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-orphan-update.out"
expect "promote-intent: both entries are ACTIVE again" \
  grep -qx 'ACTIVE=2' "$SANDBOX/pi-orphan-update.out"

fi

if t "promote-intent.sh retire/update — a guard behind a WHITESPACE-VARIANT indent is an orphan too (intent-check.sh parity)"; then
# Finding 4. promote-intent.sh's reading model claims to mirror intent-check.sh's
# "clause for clause", but its m_class only ever recognised a `guard:` behind a SPACE
# or a TAB. A `guard:` hidden behind an NBSP / VT / FF indent — the routine
# browser/Confluence paste artifact intent-check.sh's hidden_guard exists for — was
# read as a plain CLOSER, not the orphan intent-check.sh routes it to. Two confirmed
# consequences over the one committed intent file:
#   * a RETIRE of the entry the orphan is attributed to left the stray line behind,
#     where the NEXT vet re-attached it to a BYSTANDER entry and excluded it;
#   * an UPDATE of that guardless entry reported "updated", exit 0, while the orphan
#     survived — so the entry the repair was called on stayed UNPARSEABLE.
# Asserted through the real parser (intent-check.sh) on BOTH sides, never a hand-built
# expectation. NBSP (2-byte UTF-8) is the fixture indent; the fix covers VT/FF too.
NBSP=$(printf '\302\240')
PIW=$SANDBOX/pi-wsv
mkdir -p "$PIW/retire" "$PIW/update"

# --- RETIRE: carry the ws-variant orphan out with its entry, never strand a bystander -
# alpha is well-formed and ACTIVE; beta's guard is NBSP-indented, so intent-check.sh
# reads it as an orphan and excludes beta. Retiring beta must take that orphan with it —
# the buggy reading left it behind, and the next vet then stranded it onto alpha.
INT="$PIW/retire/intent.md"
{ printf '# Standing intent\n\n'
  printf -- '- 2026-01-01: alpha versioned in path\n'
  printf '  guard: test -f intent.md\n'
  printf -- '- 2026-03-03: beta committed on purpose\n'
  printf '%sguard: test ! -e web/\n' "$NBSP"; } > "$INT"
PIR=$SANDBOX/pi-wsv-retire-before
( cd "$PIW/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-wsv-retire-before.out" 2>/dev/null )
expect "wsv retire: baseline — alpha ACTIVE, beta excluded by its NBSP orphan" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-wsv-retire-before.out"
expect "wsv retire: baseline — the NBSP-indented guard reports unparseable" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/pi-wsv-retire-before.out"
INTENT=$INT ACTION=retire MATCH='beta committed on purpose' \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-wsv-retire.err"; rc=$?
expect "wsv retire: exits 0" test "$rc" -eq 0
refute "wsv retire: the retired bullet is gone" grep -q 'beta committed on purpose' "$INT"
refute "wsv retire: the NBSP orphan was carried out with beta, not left behind" \
  grep -qF 'test ! -e web/' "$INT"
# The real check: re-vet. alpha must STILL be ACTIVE — the orphan must not strand onto it.
PIR=$SANDBOX/pi-wsv-retire-after
( cd "$PIW/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-wsv-retire-after.out" 2>/dev/null )
expect "wsv retire: after retire, alpha is STILL ACTIVE (no bystander stranded)" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-wsv-retire-after.out"
expect "wsv retire: after retire, nothing is unparseable (the orphan went with beta)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-wsv-retire-after.out"

# --- UPDATE: the keep path REFUSES a hidden guard; a STATED guard set is the way through
# alpha's ONLY guard is NBSP-indented, so intent-check.sh reports that LINE and excludes
# alpha. The keep path (neither GUARD nor DROP_GUARD) would have to RE-STATE that guard
# set, and neither answer is faithful: dropping the line deletes a committed assertion,
# and ADOPTING it — re-emitting the text past `guard:` as a plain indented guard, which
# this block used to pin — is a FALSE SUCCESS whenever an invisible byte sits past the
# colon as well. Proven with the adoption in place: `<NBSP>guard: test -e we<NBSP>b`
# re-emitted a guard STILL out of grammar (`path 'we b'`), so the entry stayed
# UNPARSEABLE while the run printed "updated" and exited 0. So the keep path refuses,
# naming the line, and GUARD= / DROP_GUARD=1 / retire — each of which STATES the guard
# set — sweep the line with a NOTE. (The empty-`guard:`-value refusal is the same rule
# reached through the value instead of the indent.)
INT="$PIW/update/intent.md"
mk_wsv_update() {
  { printf '# Standing intent\n\n'
    printf -- '- 2026-01-01: alpha versioned in path\n'
    printf '%sguard: test -f intent.md\n' "$NBSP"; } > "$INT"
}
mk_wsv_update
PIR=$SANDBOX/pi-wsv-update-before
( cd "$PIW/update" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-wsv-update-before.out" 2>/dev/null )
expect "wsv update: baseline — alpha excluded by its NBSP-hidden guard" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/pi-wsv-update-before.out"
cp "$INT" "$SANDBOX/pi-wsv-update-keep.before"
INTENT=$INT ACTION=update MATCH='alpha versioned in path' \
  ENTRY='alpha versioned in path' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-wsv-update-keep.out" 2> "$SANDBOX/pi-wsv-update-keep.err"; rc=$?
expect "wsv update keep path: refused (exit 2), never a guessed rewrite" test "$rc" -eq 2
expect "wsv update keep path: nothing was written — the file is byte-identical" \
  cmp -s "$INT" "$SANDBOX/pi-wsv-update-keep.before"
refute "wsv update keep path: no success word on stdout" \
  grep -q 'updated' "$SANDBOX/pi-wsv-update-keep.out"
expect "wsv update keep path: the refusal names the LINE" \
  grep -q 'line 4 of' "$SANDBOX/pi-wsv-update-keep.err"
expect "wsv update keep path: the refusal quotes the assertion, so nothing is lost" \
  grep -qF "test -f intent.md" "$SANDBOX/pi-wsv-update-keep.err"
expect "wsv update keep path: the refusal names all three ways through" \
  bash -c "grep -q 'GUARD=' '$SANDBOX/pi-wsv-update-keep.err' \
        && grep -q 'DROP_GUARD=1' '$SANDBOX/pi-wsv-update-keep.err' \
        && grep -q 'retire' '$SANDBOX/pi-wsv-update-keep.err'"
# The way through: GUARD= states the guard set, so the hidden line is swept and NAMED.
INTENT=$INT ACTION=update MATCH='alpha versioned in path' \
  ENTRY='alpha versioned in path' GUARD='test -f intent.md' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-wsv-update.err"; rc=$?
expect "wsv update with GUARD=: exits 0" test "$rc" -eq 0
expect "wsv update with GUARD=: the guard is re-stated as a plain indented line" \
  grep -qx '  guard: test -f intent.md' "$INT"
refute "wsv update with GUARD=: no NBSP-indented guard survives" \
  grep -qF "$(printf '%sguard:' "$NBSP")" "$INT"
expect "wsv update with GUARD=: the swept hidden line is announced with its text" \
  bash -c "grep 'NOTE:' '$SANDBOX/pi-wsv-update.err' | grep -qF 'test -f intent.md'"
PIR=$SANDBOX/pi-wsv-update-after
( cd "$PIW/update" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-wsv-update-after.out" 2>/dev/null )
expect "wsv update with GUARD=: after the repair alpha is ACTIVE — not a false success" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-wsv-update-after.out"
expect "wsv update with GUARD=: after the repair nothing is unparseable" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-wsv-update-after.out"
# DROP_GUARD=1 is the other stated intent, and it must not need the assertion retyped.
mk_wsv_update
INTENT=$INT ACTION=update MATCH='alpha versioned in path' \
  ENTRY='alpha versioned in path' DROP_GUARD=1 DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-wsv-drop.err"; rc=$?
expect "wsv update with DROP_GUARD=1: exits 0" test "$rc" -eq 0
refute "wsv update with DROP_GUARD=1: the hidden guard line is gone" \
  grep -qF 'test -f intent.md' "$INT"
expect "wsv update with DROP_GUARD=1: the deletion is announced" \
  grep -qi 'NOTE:.*swept' "$SANDBOX/pi-wsv-drop.err"
PIR=$SANDBOX/pi-wsv-drop-after
( cd "$PIW/update" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-wsv-drop-after.out" 2>/dev/null )
expect "wsv update with DROP_GUARD=1: the guardless fact vets ACTIVE, nothing unparseable" \
  bash -c "grep -qx 'ACTIVE=1' '$SANDBOX/pi-wsv-drop-after.out' \
        && grep -qx 'UNPARSEABLE=0' '$SANDBOX/pi-wsv-drop-after.out'"
# The FALSE SUCCESS the refusal replaces, asserted directly: an invisible byte PAST the
# colon means no re-emission of that text can be in grammar, so no rewrite may claim it.
INT2="$PIW/update/intent2.md"
{ printf -- '- 2026-01-02: beta needs web\n'
  printf '%sguard: test -e we%sb\n' "$NBSP" "$NBSP"; } > "$INT2"
cp "$INT2" "$SANDBOX/pi-wsv-false.before"
INTENT=$INT2 ACTION=update MATCH='beta needs web' ENTRY='beta needs web' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-wsv-false.out" 2>/dev/null; rc=$?
expect "wsv update: an invisible byte past the colon is refused, never 'updated'" test "$rc" -eq 2
expect "wsv update: nothing was written for it either" \
  cmp -s "$INT2" "$SANDBOX/pi-wsv-false.before"

fi

if t "promote-intent.sh — a guard hidden behind ANY non-grammar indent is never silently rewritten, in EVERY locale"; then
# The WRITER half of the hidden-guard finding, and it was a silent DELETION. m_class read
# a `guard:` behind a whitespace-variant indent as the column-0 orphan intent-check.sh
# routes it to — but only when the line did not START with a space or a tab. So
# `<SP><NBSP>guard:` reached the INDENTED branch instead, where m_trim's `[[:space:]]`
# folds an NBSP under a UTF-8 locale and NOT under C: to this writer under LC_ALL=C the
# line was CONTINUATION PROSE. `update` absorbed it into the extent of the entry and the
# keep path re-emitted the bullet ALONE — a committed `guard:` line DELETED, "updated" on
# stdout, exit 0, no NOTE. And a lead the six-byte list never named (U+200B, U+3000) was a
# plain CLOSER, so an `update` reported success while the entry stayed UNPARSEABLE.
# Now every non-grammar lead is one class (`hidden`), the keep path REFUSES it, and retire
# takes it with the entry. Asserted per shape under BOTH locales, with the file compared
# byte for byte before and after every refusal.
PIH=$SANDBOX/pi-hidden
mkdir -p "$PIH"
PIH_ZWSP=$(printf '\342\200\213')     # U+200B — outside the old byte list
PIH_IDEO=$(printf '\343\200\200')     # U+3000 — outside the old byte list
PIH_NBSP=$(printf ' \302\240')        # SPACE + NBSP — inside it, and past the branch
PIH_N=0
for PFX in "$PIH_ZWSP" "$PIH_IDEO" "$PIH_NBSP"; do
  PIH_N=$((PIH_N + 1))
  for L in C en_US.UTF-8; do
    SAFE=$(printf '%s' "$L" | tr -c 'A-Za-z0-9' '_')
    TAG="shape $PIH_N/LC_ALL=$L"
    D="$PIH/$PIH_N-$SAFE"
    mkdir -p "$D"
    INT="$D/intent.md"
    { printf -- '- 2025-11-01: bystander fact\n'
      printf '  guard: test -f intent.md\n'
      printf -- '- 2026-01-01: hidden-guard fact\n'
      printf '%sguard: test -e never-created\n' "$PFX"; } > "$INT"
    cp "$INT" "$D/before.md"
    # Baseline through the parser of record: the entry is EXCLUDED, so no rewrite may
    # promote it into the active view by dropping the line it was excluded for.
    ( cd "$D" && LC_ALL=$L RUN=$D/vet0 INTENT=intent.md bash "$ICS" > "$D/vet0.out" 2>/dev/null )
    expect "$TAG: baseline — the bystander is ACTIVE and the hidden-guard entry is not" \
      bash -c "grep -qx 'ACTIVE=1' '$D/vet0.out' && grep -qx 'UNPARSEABLE=2' '$D/vet0.out'"
    # THE FINDING: the keep path must refuse, and must not touch a byte.
    # Run from inside the fixture dir with a RELATIVE intent path, so the two locales'
    # messages are comparable byte for byte (an absolute path carries the fixture name).
    ( cd "$D" && LC_ALL=$L INTENT=intent.md ACTION=update MATCH='hidden-guard fact' \
      ENTRY='hidden-guard fact' DATE=2026-08-12 \
      bash "$PIS" > "$D/keep.out" 2> "$D/keep.err" ); rc=$?
    expect "$TAG: update keep path is REFUSED (exit 2)" test "$rc" -eq 2
    expect "$TAG: the file is byte-identical — nothing written" cmp -s "$INT" "$D/before.md"
    expect "$TAG: the committed guard line is still on disk (was silently DELETED)" \
      grep -qF 'test -e never-created' "$INT"
    refute "$TAG: stdout never claims success" grep -q 'updated' "$D/keep.out"
    expect "$TAG: the refusal names the line and the plain-spaces repair" \
      bash -c "grep -q 'line 4 of' '$D/keep.err' && grep -qi 'plain spaces' '$D/keep.err'"
    # The way through, and the bystander must survive it: retire takes the hidden line with
    # the entry, so the next vet cannot read it against the entry ABOVE and exclude that.
    ( cd "$D" && LC_ALL=$L INTENT=intent.md ACTION=retire MATCH='hidden-guard fact' \
      bash "$PIS" > "$D/retire.out" 2> "$D/retire.err" ); rc=$?
    expect "$TAG: retire exits 0 and says so" \
      bash -c "test '$rc' -eq 0 && grep -qx 'retired' '$D/retire.out'"
    refute "$TAG: the retired bullet is gone" grep -q 'hidden-guard fact' "$INT"
    refute "$TAG: the hidden guard line went with it, not left to strand" \
      grep -qF 'test -e never-created' "$INT"
    expect "$TAG: the deletion is announced with the assertion it carried" \
      bash -c "grep 'NOTE:' '$D/retire.err' | grep -qF 'test -e never-created'"
    ( cd "$D" && LC_ALL=$L RUN=$D/vet1 INTENT=intent.md bash "$ICS" > "$D/vet1.out" 2>/dev/null )
    expect "$TAG: after the retire the bystander is STILL ACTIVE and nothing is unparseable" \
      bash -c "grep -qx 'ACTIVE=1' '$D/vet1.out' && grep -qx 'UNPARSEABLE=0' '$D/vet1.out'"
  done
  # The two locales must not merely both work — they must produce the SAME bytes, since the
  # divergence being closed was one committed file bucketing two ways on two machines.
  # bash prints its own `setlocale` warning when the box has no en_US.UTF-8 (the Ubuntu
  # image ships none): that is the environment talking, not the writer, so it is filtered
  # out before the two refusals are compared byte for byte.
  grep -v setlocale "$PIH/$PIH_N-C/keep.err" > "$PIH/$PIH_N.ref" || true
  grep -v setlocale "$PIH/$PIH_N-en_US_UTF_8/keep.err" > "$PIH/$PIH_N.cmp" || true
  expect "shape $PIH_N: the refusal is byte-identical under C and en_US.UTF-8" \
    cmp -s "$PIH/$PIH_N.ref" "$PIH/$PIH_N.cmp"
  expect "shape $PIH_N: the retired file is byte-identical under C and en_US.UTF-8" \
    cmp -s "$PIH/$PIH_N-C/intent.md" "$PIH/$PIH_N-en_US_UTF_8/intent.md"
done
# An APPEND of a fact already recorded on such an entry must not answer "unchanged" either:
# the fact IS recorded and vets NOTHING, and the second entry would poison it permanently.
INT="$PIH/append.md"
{ printf -- '- 2026-01-01: hidden-guard fact\n'
  printf '%sguard: test -e never-created\n' "$PIH_ZWSP"; } > "$INT"
cp "$INT" "$PIH/append.before"
INTENT=$INT ENTRY='hidden-guard fact' DATE=2026-08-12 \
  bash "$PIS" > "$PIH/append.out" 2> "$PIH/append.err"; rc=$?
expect "append onto a hidden-guard entry is refused (exit 2), never 'unchanged'" test "$rc" -eq 2
refute "append onto a hidden-guard entry writes nothing" grep -q 'unchanged\|appended' "$PIH/append.out"
expect "append onto a hidden-guard entry leaves the file byte-identical" \
  cmp -s "$INT" "$PIH/append.before"

fi

if t "promote-intent.sh retire/update — the sweep never de-guards ANOTHER entry"; then
# This block PINS the interface:
#   an orphan run sitting directly under a DIFFERENT guardless entry SURVIVES the
#   rewrite. That entry stays UNPARSEABLE, for its own re-confirm.
#   WHY: the sweep was FILE-GLOBAL (`/^guard:/ { next }` in both rewrites) while
#   adoption — the repair that hands an orphan back to its entry — is scoped to the
#   MATCHED entry. So acting on entry ONE deleted entry TWO's orphan, and because that
#   orphan was TWO's ONLY reason for exclusion, TWO flipped from UNPARSEABLE (excluded,
#   steering nothing) to ACTIVE with its author's assertion deleted. That is the exact
#   fail-OPEN the adoption path exists to prevent, one entry over — and the global
#   sweep's stated safety argument ("it deletes a line that was steering nothing") is
#   true of the orphan and FALSE of the entry above it, which intent-check.sh excludes
#   BECAUSE of the orphan.
#   The parser of record is the assertion that settles it: the loss is invisible in the
#   writer's own output (exit 0, "updated"/"retired", and TWO's bullet still on disk).
# web/ EXISTS here, so entry TWO's guard is one that FAILS — the direction that makes
# a silent de-guard consequential rather than cosmetic.
PI=$SANDBOX/pi-cross-entry
mkdir -p "$PI/update/web" "$PI/retire/web"
for d in update retire; do
  cat > "$PI/$d/intent.md" <<'EOF'
# Standing intent

- 2026-01-01: entry ONE — the API is versioned in path
guard: test -f intent.md
- 2026-02-02: entry TWO — web/ is deliberately absent
guard: test ! -e web/
EOF
done

# Both entries start EXCLUDED: two bullets and two orphans, nothing active.
PIR=$SANDBOX/pi-cross-before
( cd "$PI/update" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-cross-before.out" 2>/dev/null )
expect "promote-intent: the two-entry fixture starts with NOTHING active" \
  grep -qx 'ACTIVE=0' "$SANDBOX/pi-cross-before.out"
expect "promote-intent: and all four lines unparseable" \
  grep -qx 'UNPARSEABLE=4' "$SANDBOX/pi-cross-before.out"

# --- the UPDATE arm: entry ONE adopts its own orphan, entry TWO keeps its own -------
INT="$PI/update/intent.md"
INTENT=$INT ACTION=update MATCH='entry ONE — the API is versioned in path' \
  ENTRY='entry ONE — re-confirmed' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-cross-update.out" 2> "$SANDBOX/pi-cross-update.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-cross-update.out")" = updated ]]; then
  pass "promote-intent: updating ONE over an unrelated orphan still says 'updated'"
else
  fail "promote-intent: updating ONE over an unrelated orphan says 'updated' (rc=$rc, said '$(cat "$SANDBOX/pi-cross-update.out")')"
fi
expect "promote-intent: entry ONE adopted its OWN orphan" \
  grep -qx -- '  guard: test -f intent.md' "$INT"
expect "promote-intent: entry TWO's orphan is still on disk, still at column 0" \
  grep -qx -- 'guard: test ! -e web/' "$INT"
refute "promote-intent: nothing was reported as swept — no line was deleted" \
  grep -q 'NOTE: swept' "$SANDBOX/pi-cross-update.err"
PIR=$SANDBOX/pi-cross-update-run
( cd "$PI/update" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-cross-update-ics.out" 2>/dev/null )
expect "promote-intent: only the re-confirmed entry ONE is ACTIVE" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-cross-update-ics.out"
# The load-bearing assertion: entry TWO must still be EXCLUDED. A global sweep left it
# ACTIVE=2 here, guardless, with its failing assertion gone.
expect "promote-intent: entry TWO is still UNPARSEABLE, awaiting its own re-confirm" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/pi-cross-update-ics.out"
refute "promote-intent: entry TWO did NOT ride into the active view de-guarded" \
  grep -qx 'ACTIVE=2' "$SANDBOX/pi-cross-update-ics.out"
# The two views intent-check.sh writes for the phase to read from are where a resolver
# and Phase 5's re-confirm table actually get their rows, so they are what settle it.
expect "promote-intent: entry TWO is listed in intent-unparseable.md, for re-confirm" \
  grep -qxF -- '- 2026-02-02: entry TWO — web/ is deliberately absent' "$PIR/intent-unparseable.md"
refute "promote-intent: and entry TWO steers nothing — it is NOT in intent-active.md" \
  grep -qF 'entry TWO' "$PIR/intent-active.md"

# --- the RETIRE arm: same, and ONE's own orphan goes with the entry -----------------
INT="$PI/retire/intent.md"
INTENT=$INT ACTION=retire MATCH='entry ONE — the API is versioned in path' \
  bash "$PIS" > "$SANDBOX/pi-cross-retire.out" 2> "$SANDBOX/pi-cross-retire.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-cross-retire.out")" = retired ]]; then
  pass "promote-intent: retiring ONE over an unrelated orphan still says 'retired'"
else
  fail "promote-intent: retiring ONE over an unrelated orphan says 'retired' (rc=$rc, said '$(cat "$SANDBOX/pi-cross-retire.out")')"
fi
refute "promote-intent: entry ONE is gone" grep -q 'entry ONE' "$INT"
# The retired entry's OWN orphan must go with it: leaving it behind slides it up
# against whatever precedes and de-guards THAT entry instead.
refute "promote-intent: ONE's own orphan went with the entry" \
  grep -qF 'test -f intent.md' "$INT"
expect "promote-intent: the sweep NOTE names ONE's guard text and the bullet it sat under" \
  grep -qF "swept the orphaned column-0 guard 'test -f intent.md'" "$SANDBOX/pi-cross-retire.err"
expect "promote-intent: entry TWO's orphan survives the retire, still at column 0" \
  grep -qx -- 'guard: test ! -e web/' "$INT"
refute "promote-intent: TWO's guard is not reported as swept either" \
  grep -qF 'test ! -e web/' "$SANDBOX/pi-cross-retire.err"
PIR=$SANDBOX/pi-cross-retire-run
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-cross-retire-ics.out" 2>/dev/null )
expect "promote-intent: after the retire, entry TWO is STILL excluded" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/pi-cross-retire-ics.out"
refute "promote-intent: the retire did not promote entry TWO into the active view" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-cross-retire-ics.out"
expect "promote-intent: nothing is active after retiring the only re-confirmable entry" \
  grep -qx 'ACTIVE=0' "$SANDBOX/pi-cross-retire-ics.out"

# The loop still CLOSES: `update` on entry TWO is what adopts its guard back, and the
# entry then quarantines on it (web/ exists) rather than going ACTIVE unguarded. Without
# this the fix would have traded a fail-OPEN for a dead end — the shape the sweep was
# introduced to escape.
INTENT=$INT ACTION=update MATCH='entry TWO — web/ is deliberately absent' \
  ENTRY='entry TWO — web/ is deliberately absent' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-cross-adopt.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: entry TWO can still be repaired through the writer"; else fail "promote-intent: entry TWO can still be repaired through the writer (rc=$rc)"; fi
expect "promote-intent: TWO's guard came back INDENTED, so it is live" \
  grep -qx -- '  guard: test ! -e web/' "$INT"
refute "promote-intent: no column-0 guard is left in the file" grep -qE '^guard:' "$INT"
PIR=$SANDBOX/pi-cross-adopt-run
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-cross-adopt-ics.out" 2>/dev/null )
expect "promote-intent: the repaired entry TWO quarantines on its failing guard" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-cross-adopt-ics.out"
expect "promote-intent: and the file is well-formed again" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-cross-adopt-ics.out"

fi

if t "promote-intent.sh retire/update — a FOREIGN orphan is spared even when its owner is already guarded"; then
# This block PINS the interface:
#   an orphan is protected by WHOSE it is, not by whether its owner happens to look
#   guardless. EVERY column-0 `guard:` run sitting under an entry OTHER than the
#   matched one survives the rewrite — including one under an entry that already owns
#   an INDENTED guard.
#   WHY: the entry-scoped sweep's first form protected a foreign orphan only while its
#   owner was GUARDLESS, which reads the protection as "that entry has nothing left
#   without this line". That is not the reason. A column-0 guard makes its owner
#   UNPARSEABLE whether or not the owner also carries an indented one, so deleting it
#   PROMOTES that foreign entry into the active view — vetted by only the guards that
#   happened to be indented. Here entry TWO's indented guard PASSES and its column-0
#   guard FAILS, so the deletion turned an excluded entry into an ACTIVE fact with its
#   author's failing assertion gone: the same cross-entry fail-OPEN as the file-global
#   sweep, one condition deeper, and just as invisible in the writer's output (exit 0,
#   "retired"/"updated", TWO's bullet still on disk).
#   A foreign entry is never the caller's to repair. It stays UNPARSEABLE — a named row
#   in Phase 5's re-confirm table — and acting on THAT entry is where its orphan is
#   resolved: adopted when it is guardless, swept with a NOTE when it is not.
# web/ EXISTS here, so `test -d web` (TWO's indented guard) PASSES and `test ! -e web`
# (TWO's column-0 guard) FAILS — the direction that makes the de-guard consequential.
PI=$SANDBOX/pi-foreign-guarded
mkdir -p "$PI/update/web" "$PI/retire/web"
for d in update retire; do
  cat > "$PI/$d/intent.md" <<'EOF'
# Standing intent

- 2026-01-01: entry ONE — the API is versioned in path
guard: test -f intent.md
- 2026-02-02: entry TWO — web/ is present on purpose
  guard: test -d web
guard: test ! -e web
EOF
done

# Both entries start EXCLUDED — TWO too, despite owning a well-formed indented guard,
# because its column-0 line makes the entry unparseable.
PIR=$SANDBOX/pi-foreign-before
( cd "$PI/update" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-foreign-before.out" 2>/dev/null )
expect "promote-intent: the already-guarded-owner fixture starts with NOTHING active" \
  grep -qx 'ACTIVE=0' "$SANDBOX/pi-foreign-before.out"
expect "promote-intent: entry TWO starts UNPARSEABLE even though it owns an indented guard" \
  grep -qxF -- '- 2026-02-02: entry TWO — web/ is present on purpose' "$PIR/intent-unparseable.md"

# --- the UPDATE arm: ONE adopts its own orphan, TWO's is not the caller's to touch ---
INT="$PI/update/intent.md"
INTENT=$INT ACTION=update MATCH='entry ONE — the API is versioned in path' \
  ENTRY='entry ONE — re-confirmed' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-foreign-update.out" 2> "$SANDBOX/pi-foreign-update.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-foreign-update.out")" = updated ]]; then
  pass "promote-intent: updating ONE over an already-guarded owner's orphan says 'updated'"
else
  fail "promote-intent: updating ONE over an already-guarded owner's orphan says 'updated' (rc=$rc, said '$(cat "$SANDBOX/pi-foreign-update.out")')"
fi
expect "promote-intent: entry ONE adopted its OWN orphan" \
  grep -qx -- '  guard: test -f intent.md' "$INT"
expect "promote-intent: entry TWO's column-0 guard is still on disk, still at column 0" \
  grep -qx -- 'guard: test ! -e web' "$INT"
refute "promote-intent: TWO's guard was not reported swept — nothing of TWO's was deleted" \
  grep -qF 'test ! -e web' "$SANDBOX/pi-foreign-update.err"
PIR=$SANDBOX/pi-foreign-update-run
( cd "$PI/update" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-foreign-update-ics.out" 2>/dev/null )
expect "promote-intent: only the re-confirmed entry ONE is ACTIVE after the update" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-foreign-update-ics.out"
# The load-bearing assertion: the guardless-owner-only protection left TWO ACTIVE=2
# here, vetted by its PASSING indented guard alone, with the failing one deleted.
refute "promote-intent: entry TWO did NOT ride into the active view on its passing guard alone" \
  grep -qx 'ACTIVE=2' "$SANDBOX/pi-foreign-update-ics.out"
refute "promote-intent: and entry TWO steers nothing — it is NOT in intent-active.md" \
  grep -qF 'entry TWO' "$PIR/intent-active.md"
expect "promote-intent: entry TWO is still listed for its OWN re-confirm" \
  grep -qxF -- '- 2026-02-02: entry TWO — web/ is present on purpose' "$PIR/intent-unparseable.md"

# --- the RETIRE arm: same, and ONE's own orphan still goes with the entry ------------
INT="$PI/retire/intent.md"
INTENT=$INT ACTION=retire MATCH='entry ONE — the API is versioned in path' \
  bash "$PIS" > "$SANDBOX/pi-foreign-retire.out" 2> "$SANDBOX/pi-foreign-retire.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-foreign-retire.out")" = retired ]]; then
  pass "promote-intent: retiring ONE over an already-guarded owner's orphan says 'retired'"
else
  fail "promote-intent: retiring ONE over an already-guarded owner's orphan says 'retired' (rc=$rc, said '$(cat "$SANDBOX/pi-foreign-retire.out")')"
fi
refute "promote-intent: entry ONE is gone" grep -q 'entry ONE' "$INT"
refute "promote-intent: ONE's own orphan went with the entry it sat under" \
  grep -qF 'test -f intent.md' "$INT"
expect "promote-intent: entry TWO's column-0 guard survives the retire, still at column 0" \
  grep -qx -- 'guard: test ! -e web' "$INT"
expect "promote-intent: TWO's OWN indented guard is untouched too" \
  grep -qx -- '  guard: test -d web' "$INT"
refute "promote-intent: TWO's guard is not reported as swept either" \
  grep -qF 'test ! -e web' "$SANDBOX/pi-foreign-retire.err"
PIR=$SANDBOX/pi-foreign-retire-run
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-foreign-retire-ics.out" 2>/dev/null )
expect "promote-intent: nothing is active after retiring the only other entry" \
  grep -qx 'ACTIVE=0' "$SANDBOX/pi-foreign-retire-ics.out"
refute "promote-intent: the retire did not promote entry TWO into the active view" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-foreign-retire-ics.out"
refute "promote-intent: entry TWO is not quarantining either — it is still excluded" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-foreign-retire-ics.out"

# The loop still CLOSES on TWO's own terms: acting on TWO is what resolves TWO's
# orphan. TWO already owns an indented guard, so adoption stays refused (stapling an
# unrelated line onto a fact is the de-guarding wearing the opposite mask) — the line
# is swept, and the NOTE names the assertion and the bullet so the caller who NAMED
# this entry can put it back. Without this the fix would trade a fail-OPEN for a dead
# end, the shape the sweep was introduced to escape.
INTENT=$INT ACTION=update MATCH='entry TWO — web/ is present on purpose' \
  ENTRY='entry TWO — web/ is present on purpose' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-foreign-repair.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: entry TWO can still be repaired through the writer"; else fail "promote-intent: entry TWO can still be repaired through the writer (rc=$rc)"; fi
expect "promote-intent: TWO's own repair sweeps TWO's orphan, and the NOTE names the guard TEXT" \
  grep -qF "swept the orphaned column-0 guard 'test ! -e web'" "$SANDBOX/pi-foreign-repair.err"
expect "promote-intent: and the NOTE names the entry it was attached to" \
  grep -qF "attaches it to the entry '- 2026-02-02: entry TWO — web/ is present on purpose'" "$SANDBOX/pi-foreign-repair.err"
refute "promote-intent: no column-0 guard is left in the repaired file" grep -qE '^guard:' "$INT"
PIR=$SANDBOX/pi-foreign-repair-run
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-foreign-repair-ics.out" 2>/dev/null )
expect "promote-intent: the repaired file is well-formed again" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-foreign-repair-ics.out"

fi

if t "promote-intent.sh retire/update — a foreign orphan is spared ACROSS an entry-closer, per intent-check.sh's attachment rule"; then
# This block PINS the interface:
#   ownership is read the way intent-check.sh ATTACHES a column-0 `guard:` line, and
#   that reach is NOT contiguity. A blank line, a `---`, column-0 prose or a
#   wrong-style bullet between a foreign entry and its column-0 guard leaves the line
#   that entry's guard — so the rewrite must LEAVE it, and that entry must stay
#   UNPARSEABLE for its own re-confirm.
#   WHY: the first entry-scoped sweep read ownership as the bullet's CONTIGUOUS
#   indented block, so any of those separators reset the owner to "none" and the
#   verdict to `sweep` ("owned by no entry at all"). intent-check.sh's rule is
#   strictly WIDER: a blank line does not close an entry at all (blanks are HELD open,
#   so the entry is still the OPEN one), and an entry that already went ACTIVE is
#   RETRACTED when an orphan turns up below it however much structure sits between —
#   that retraction is the silent-de-guarding case its header names. So the line this
#   writer called ownerless is, to the parser of record, the foreign entry's guard,
#   and sweeping it flipped that entry from UNPARSEABLE (excluded, steering nothing)
#   to ACTIVE with its author's assertion deleted: the same cross-entry fail-OPEN as
#   the file-global sweep, arriving through the ownership MODEL instead of the scope.
#   Every verdict below is the REAL intent-check.sh's, run on the fixture. The two
#   readings disagreeing IS the defect, so a hand-assumed verdict would just be the
#   bug's own assumption written down again.
# web/ EXISTS in every arm, so entry TWO's guard is one that FAILS — the direction
# that makes a de-guard consequential rather than cosmetic.
PI=$SANDBOX/pi-closer
mkdir -p "$PI"
for v in blank dashes prose star; do mkdir -p "$PI/$v/web" "$PI/$v-retire/web"; done

# The four entry-closers, each between entry TWO's bullet and its column-0 guard.
# `- 2026-01-01: ONE` keeps its OWN adjacent orphan so the matched entry still has
# something to adopt: the assertion is about TWO's line, not about ONE losing its.
write_closer_fixture() {   # <dir> <closer-lines-file-content marker>
  case "$2" in
    blank)  CLOSER='' ;;
    dashes) CLOSER='---' ;;
    prose)  CLOSER='Ownership of the web UI moved to another team.' ;;
    star)   CLOSER='* a wrong-style bullet nobody fixed' ;;
  esac
  {
    printf '%s\n' '# Standing intent'
    printf '\n'
    printf '%s\n' '- 2026-01-01: entry ONE — the API is versioned in path'
    printf '%s\n' 'guard: test -f intent.md'
    printf '%s\n' '- 2026-02-02: entry TWO — web/ is deliberately absent'
    printf '%s\n' "$CLOSER"
    printf '%s\n' 'guard: test ! -e web/'
  } > "$1/intent.md"
}

for v in blank dashes prose star; do
  write_closer_fixture "$PI/$v" "$v"
  write_closer_fixture "$PI/$v-retire" "$v"

  # GROUND TRUTH, from intent-check.sh itself: the closer does not un-own TWO's
  # guard — TWO is excluded BY it, exactly as ONE is by its own adjacent orphan.
  PIR=$SANDBOX/pi-closer-$v-before
  ( cd "$PI/$v" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-$v-before.out" 2>/dev/null )
  expect "promote-intent: [$v closer] intent-check.sh starts the fixture with NOTHING active" \
    grep -qx 'ACTIVE=0' "$SANDBOX/pi-closer-$v-before.out"
  expect "promote-intent: [$v closer] intent-check.sh attaches the separated guard to entry TWO — TWO is excluded by it" \
    grep -qxF -- '- 2026-02-02: entry TWO — web/ is deliberately absent' "$PIR/intent-unparseable.md"

  # --- the UPDATE arm ---------------------------------------------------------------
  INT="$PI/$v/intent.md"
  INTENT=$INT ACTION=update MATCH='entry ONE — the API is versioned in path' \
    ENTRY='entry ONE — re-confirmed' DATE=2026-08-11 \
    bash "$PIS" > "$SANDBOX/pi-closer-$v-up.out" 2> "$SANDBOX/pi-closer-$v-up.err"; rc=$?
  if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-closer-$v-up.out")" = updated ]]; then
    pass "promote-intent: [$v closer] updating ONE still says 'updated'"
  else
    fail "promote-intent: [$v closer] updating ONE still says 'updated' (rc=$rc, said '$(cat "$SANDBOX/pi-closer-$v-up.out")')"
  fi
  expect "promote-intent: [$v closer] entry ONE adopted its OWN adjacent orphan" \
    grep -qx -- '  guard: test -f intent.md' "$INT"
  expect "promote-intent: [$v closer] entry TWO's guard is still on disk, still at column 0" \
    grep -qx -- 'guard: test ! -e web/' "$INT"
  refute "promote-intent: [$v closer] and nothing of TWO's was reported swept" \
    grep -qF 'test ! -e web/' "$SANDBOX/pi-closer-$v-up.err"
  if [[ "$(sed -n 6p "$INT")" = "$CLOSER" ]]; then
    pass "promote-intent: [$v closer] the closer line itself survives verbatim, in place"
  else
    fail "promote-intent: [$v closer] the closer line itself survives verbatim, in place (line 6 is '$(sed -n 6p "$INT")')"
  fi
  PIR=$SANDBOX/pi-closer-$v-after
  ( cd "$PI/$v" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-$v-after.out" 2>/dev/null )
  expect "promote-intent: [$v closer] only the re-confirmed entry ONE is ACTIVE" \
    grep -qx 'ACTIVE=1' "$SANDBOX/pi-closer-$v-after.out"
  # The load-bearing assertion: the contiguous-block ownership model left this at
  # ACTIVE=2, TWO guardless with its FAILING assertion deleted.
  refute "promote-intent: [$v closer] entry TWO did NOT ride into the active view de-guarded" \
    grep -qx 'ACTIVE=2' "$SANDBOX/pi-closer-$v-after.out"
  refute "promote-intent: [$v closer] entry TWO steers nothing — it is NOT in intent-active.md" \
    grep -qF 'entry TWO' "$PIR/intent-active.md"
  expect "promote-intent: [$v closer] entry TWO is still listed for its OWN re-confirm" \
    grep -qxF -- '- 2026-02-02: entry TWO — web/ is deliberately absent' "$PIR/intent-unparseable.md"

  # --- the RETIRE arm (the other rewrite, same map) ---------------------------------
  INT="$PI/$v-retire/intent.md"
  INTENT=$INT ACTION=retire MATCH='entry ONE — the API is versioned in path' \
    bash "$PIS" > "$SANDBOX/pi-closer-$v-ret.out" 2> "$SANDBOX/pi-closer-$v-ret.err"; rc=$?
  if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-closer-$v-ret.out")" = retired ]]; then
    pass "promote-intent: [$v closer] retiring ONE still says 'retired'"
  else
    fail "promote-intent: [$v closer] retiring ONE still says 'retired' (rc=$rc, said '$(cat "$SANDBOX/pi-closer-$v-ret.out")')"
  fi
  refute "promote-intent: [$v closer] entry ONE and its own orphan are gone" \
    grep -qF 'test -f intent.md' "$INT"
  expect "promote-intent: [$v closer] entry TWO's guard survives the retire, still at column 0" \
    grep -qx -- 'guard: test ! -e web/' "$INT"
  PIR=$SANDBOX/pi-closer-$v-ret-run
  ( cd "$PI/$v-retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-$v-ret-ics.out" 2>/dev/null )
  expect "promote-intent: [$v closer] after the retire, entry TWO is STILL excluded" \
    grep -qx 'ACTIVE=0' "$SANDBOX/pi-closer-$v-ret-ics.out"
  refute "promote-intent: [$v closer] the retire did not promote entry TWO into the active view" \
    grep -qx 'ACTIVE=1' "$SANDBOX/pi-closer-$v-ret-ics.out"

  # The loop still CLOSES on TWO's own terms: TWO is guardless, and its guard is
  # ADJACENT to nothing — the closer sits between them — so acting on TWO sweeps the
  # line with a NOTE naming it, and TWO can then be re-guarded explicitly. What must
  # never happen is a THIRD party's rewrite doing it silently.
  INTENT=$INT ACTION=update MATCH='entry TWO — web/ is deliberately absent' \
    ENTRY='entry TWO — web/ is deliberately absent' GUARD='test ! -e web/' DATE=2026-08-11 \
    bash "$PIS" >/dev/null 2> "$SANDBOX/pi-closer-$v-repair.err"; rc=$?
  if [[ "$rc" -eq 0 ]]; then pass "promote-intent: [$v closer] entry TWO is still repairable through the writer"; else fail "promote-intent: [$v closer] entry TWO is still repairable through the writer (rc=$rc)"; fi
  expect "promote-intent: [$v closer] TWO's own repair re-attaches its guard INDENTED" \
    grep -qx -- '  guard: test ! -e web/' "$INT"
  refute "promote-intent: [$v closer] no column-0 guard is left after TWO's own repair" \
    grep -qE '^guard:' "$INT"
  expect "promote-intent: [$v closer] TWO's own repair ANNOUNCED the swept line" \
    grep -qF "NOTE: swept the orphaned column-0 guard 'test ! -e web/'" "$SANDBOX/pi-closer-$v-repair.err"
  PIR=$SANDBOX/pi-closer-$v-repair-run
  ( cd "$PI/$v-retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-$v-repair-ics.out" 2>/dev/null )
  expect "promote-intent: [$v closer] the repaired entry TWO quarantines on its failing guard" \
    grep -qx 'QUARANTINED=1' "$SANDBOX/pi-closer-$v-repair-ics.out"
  # A wrong-style bullet is itself an unparseable LINE and the one shape this writer
  # cannot express (no fact for MATCH to name), so it stays for Phase 5's hand delete.
  # Every other closer is valid structure, so the repaired file is clean.
  case "$v" in star) EXP_UNPARSE=1 ;; *) EXP_UNPARSE=0 ;; esac
  expect "promote-intent: [$v closer] no ENTRY is unparseable after TWO's repair (UNPARSEABLE=$EXP_UNPARSE)" \
    grep -qx "UNPARSEABLE=$EXP_UNPARSE" "$SANDBOX/pi-closer-$v-repair-ics.out"
done

fi

if t "promote-intent.sh retire/update — an UNDATED '- ' bullet owns its orphan too, and a guard above every bullet is still swept"; then
# This block PINS the interface:
#   the two ends of the widened ownership rule, both pinned to intent-check.sh.
#   (1) intent-check.sh opens an entry on ANY column-0 `- ` line — the date is not part
#       of its entry grammar — so an undated bullet OWNS the column-0 guard beneath it
#       and is excluded by it. This writer only ever MATCHES dated bullets, so an
#       undated one is always a FOREIGN entry: its orphan is protected, or the sweep
#       promotes a bullet the caller never named into the active view.
#   (2) The other end must stay open: a column-0 guard with NO `- ` line above it
#       anywhere is one intent-check.sh reports ALONE — no entry is excluded by it — so
#       it is still SWEPT. Protecting that one too would put the file back in the
#       append-only, un-repairable state install()'s global refusal created.
PI=$SANDBOX/pi-own-edges
mkdir -p "$PI/undated/web" "$PI/nobullet"

cat > "$PI/undated/intent.md" <<'EOF'
- 2026-01-01: entry ONE — the API is versioned in path
guard: test -f intent.md
- an undated plain bullet nobody dated
guard: test ! -e web/
EOF
PIR=$SANDBOX/pi-undated-before
( cd "$PI/undated" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-undated-before.out" 2>/dev/null )
expect "promote-intent: intent-check.sh treats the UNDATED bullet as an entry and excludes it" \
  grep -qxF -- '- an undated plain bullet nobody dated' "$PIR/intent-unparseable.md"
INT="$PI/undated/intent.md"
INTENT=$INT ACTION=update MATCH='entry ONE — the API is versioned in path' \
  ENTRY='entry ONE — re-confirmed' DATE=2026-08-11 bash "$PIS" >/dev/null 2> "$SANDBOX/pi-undated.err"
expect "promote-intent: the undated bullet's orphan is LEFT — it is not this caller's to repair" \
  grep -qx -- 'guard: test ! -e web/' "$INT"
refute "promote-intent: and it is not reported as swept" \
  grep -qF 'test ! -e web/' "$SANDBOX/pi-undated.err"
PIR=$SANDBOX/pi-undated-after
( cd "$PI/undated" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-undated-after.out" 2>/dev/null )
refute "promote-intent: the undated bullet did NOT ride into the active view de-guarded" \
  grep -qF 'an undated plain bullet' "$PIR/intent-active.md"

cat > "$PI/nobullet/intent.md" <<'EOF'
# Standing intent

guard: test -f intent.md

- 2026-01-01: entry ONE — the API is versioned in path
  guard: test -f intent.md
EOF
PIR=$SANDBOX/pi-nobullet-before
( cd "$PI/nobullet" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-nobullet-before.out" 2>/dev/null )
expect "promote-intent: intent-check.sh reports a guard above every bullet ALONE — no entry is excluded" \
  grep -qx 'UNPARSEABLE=1' "$SANDBOX/pi-nobullet-before.out"
expect "promote-intent: and the entry BELOW it is active, so nothing is waiting on it" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-nobullet-before.out"
INT="$PI/nobullet/intent.md"
INTENT=$INT ACTION=update MATCH='entry ONE — the API is versioned in path' \
  ENTRY='entry ONE — re-confirmed' DATE=2026-08-11 bash "$PIS" >/dev/null 2> "$SANDBOX/pi-nobullet.err"
refute "promote-intent: the truly ownerless guard is still SWEPT (the file stays repairable)" \
  grep -qE '^guard:' "$INT"
expect "promote-intent: and the sweep is announced, naming the guard TEXT that went" \
  grep -qF "NOTE: swept the orphaned column-0 guard 'test -f intent.md'" "$SANDBOX/pi-nobullet.err"
expect "promote-intent: and the NOTE says no entry precedes it, so nothing was de-guarded" \
  grep -qF 'no entry precedes it in the file' "$SANDBOX/pi-nobullet.err"
PIR=$SANDBOX/pi-nobullet-after
( cd "$PI/nobullet" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-nobullet-after.out" 2>/dev/null )
expect "promote-intent: the repaired file is well-formed" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-nobullet-after.out"

fi

if t "promote-intent.sh — a BACKSLASH in the fact defeats neither dedup nor retire"; then
# This block PINS the interface:
#   the fact is matched as BYTES, everywhere. WHY: the lookup feeds the fact to awk,
#   and `awk -v w=<value>` ESCAPE-PROCESSES what it is given — `\t` becomes a literal
#   tab, `\d` becomes `d` — so a fact carrying a backslash never compared equal to
#   the bytes actually in the file. Both ends broke: dedup failed OPEN (every
#   re-append stacked another entry) and find_entry then saw zero-or-many matches and
#   refused every later retire and update. One re-append on the SAME day poisoned the
#   fact permanently — the exact end-state the fact-scoped dedup exists to prevent.
#   Facts quote real trees ("logs use \t as the separator", "C:\opt\app is vendored"),
#   so backslashes are not hypothetical. ENVIRON[] is the byte-exact channel.
PI=$SANDBOX/pi-backslash
mkdir -p "$PI"
INT="$PI/intent.md"
BS='logs use \t as the separator'
for _ in 1 2 3; do
  INTENT=$INT ENTRY="$BS" GUARD='test -f intent.md' DATE=2026-08-09 bash "$PIS" >/dev/null 2>&1
done
if [[ "$(grep -cF -- "$BS" "$INT")" = 1 ]]; then pass "promote-intent: three identical appends of a backslash-bearing fact leave ONE entry"; else fail "promote-intent: three identical appends of a backslash-bearing fact leave ONE entry (got $(grep -cF -- "$BS" "$INT"))"; fi
if [[ "$(wc -l < "$INT" | tr -d ' ')" = 2 ]]; then pass "promote-intent: that entry is still bullet + guard"; else fail "promote-intent: that entry is still bullet + guard (got $(wc -l < "$INT" | tr -d ' ') lines)"; fi
expect "promote-intent: the backslash reached the file verbatim (no escape processing on the way in)" \
  grep -qxF -- "- 2026-08-09: $BS" "$INT"

# The poisoning test: the fact must still be findable by the writer that wrote it.
INTENT=$INT ACTION=update MATCH="$BS" ENTRY='logs use \t as the separator (still true)' \
  DATE=2026-08-10 bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: a backslash-bearing fact can be updated"; else fail "promote-intent: a backslash-bearing fact can be updated (rc=$rc)"; fi
INTENT=$INT ACTION=retire MATCH='logs use \t as the separator (still true)' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: a backslash-bearing fact can be retired"; else fail "promote-intent: a backslash-bearing fact can be retired (rc=$rc)"; fi
refute "promote-intent: the retire left no trace of the backslash-bearing fact" grep -qF -- 'logs use' "$INT"

# A Windows-shaped path is the same defect wearing different clothes: `\o` and `\a`
# are not escapes awk keeps, so the fact came back mangled rather than merely re-escaped.
INTENT=$INT ENTRY='C:\opt\app is vendored on purpose' DATE=2026-08-09 bash "$PIS" >/dev/null 2>&1
INTENT=$INT ENTRY='C:\opt\app is vendored on purpose' DATE=2026-08-09 bash "$PIS" >/dev/null 2>&1
if [[ "$(grep -cF -- 'C:\opt\app' "$INT")" = 1 ]]; then pass "promote-intent: a backslashed Windows path dedups too"; else fail "promote-intent: a backslashed Windows path dedups too (got $(grep -cF -- 'C:\opt\app' "$INT"))"; fi

fi

if t "promote-intent.sh update — the orphaned guard below a guardless entry is ADOPTED, not destroyed"; then
# This block PINS the interface:
#   ACTION=update with neither GUARD nor DROP_GUARD, on an entry that owns NO guard
#   and is immediately followed by a column-0 `guard:` line, ADOPTS that line as the
#   entry's own indented guard.
#   WHY: bullet-then-column-0-guard IS the legacy malformation — it is what a prose
#   append that forgot the indent leaves behind, and the shape the Phase 5 re-confirm
#   is handed. A blind sweep would delete the user's assertion, print "updated", and
#   say nothing; the fact would then steer resolutions for the component's life with
#   no guard, which is precisely the failure intent-check.sh's unparseable bucket
#   exists to report. Adoption re-attaches the guard the author meant to write, which
#   is the only reading of that shape that loses nothing.
PI=$SANDBOX/pi-adopt
mkdir -p "$PI"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
# Standing intent

- 2026-01-01: web/ is deliberately absent
guard: test ! -e web/
EOF

INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ is deliberately absent — the team removed the web UI' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-adopt.out" 2> "$SANDBOX/pi-adopt.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-adopt.out")" = updated ]]; then
  pass "promote-intent: the update over an orphan-carrying entry succeeds and still says 'updated'"
else
  fail "promote-intent: the update over an orphan-carrying entry succeeds (rc=$rc, said '$(cat "$SANDBOX/pi-adopt.out")')"
fi
expect "promote-intent: the adoption is ANNOUNCED on stderr, naming how many lines it took" \
  grep -q 'NOTE: adopted the 1 orphaned column-0 guard line' "$SANDBOX/pi-adopt.err"
expect "promote-intent: the fact was rewritten and re-dated" \
  grep -qx -- '- 2026-08-11: web/ is deliberately absent — the team removed the web UI' "$INT"
expect "promote-intent: the orphan came back as the entry's INDENTED guard" \
  grep -qx -- '  guard: test ! -e web/' "$INT"
refute "promote-intent: no column-0 guard survives the adoption" grep -qE '^guard:' "$INT"
if [[ "$(grep -c 'guard:' "$INT")" = 1 ]]; then pass "promote-intent: the guard was moved, not duplicated"; else fail "promote-intent: the guard was moved, not duplicated (got $(grep -c 'guard:' "$INT"))"; fi
expect "promote-intent: the file's structure survives" grep -q '^# Standing intent' "$INT"

# The parser of record is the assertion that matters: the entry is ACTIVE, nothing
# is unparseable, and the guard is GENUINELY attached — a failing guard quarantines
# the entry rather than passing through as decoration.
PIR=$SANDBOX/pi-adopt-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-adopt-ics.out" 2>/dev/null )
expect "promote-intent: after adoption, intent-check.sh reports nothing unparseable" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-adopt-ics.out"
expect "promote-intent: after adoption, the entry is ACTIVE" grep -qx 'ACTIVE=1' "$SANDBOX/pi-adopt-ics.out"
mkdir -p "$PI/web"
PIR2=$SANDBOX/pi-adopt-run2
( cd "$PI" && RUN=$PIR2 INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-adopt-ics2.out" 2>/dev/null )
expect "promote-intent: the adopted guard is genuinely attached (a failing guard quarantines the entry)" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-adopt-ics2.out"
rmdir "$PI/web"

fi

if t "promote-intent.sh update — a line stranded UNDER an orphan reparents as an EXTRA guard (fail-safe)"; then
# This block PINS the interface for a pathological shape:
#   `- fact` / column-0 `guard: A` / INDENTED `guard: B`. Today the indented line is
#   inert — intent-check.sh sees no open entry at that point and files it as
#   structure — but any rewrite that removes the column-0 line necessarily moves it
#   up against the entry, where it becomes a live guard the user never explicitly
#   attached. There is no reading of this shape that reconstructs intent, so the
#   choice is which way to be WRONG: `A` is adopted and `B` REPARENTS, giving the
#   entry BOTH guards, and intent-check.sh requires ALL guards to pass.
#   That direction is fail-safe on purpose — the worst case is an entry quarantined
#   into Phase 5's re-confirm table, a question the user answers, never a fact that
#   steers resolutions with an assertion nobody is running.
PI=$SANDBOX/pi-reparent
mkdir -p "$PI/web"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
- 2026-01-01: web/ is deliberately absent
guard: test -f intent.md
  guard: test ! -e web/
EOF

INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ is deliberately absent — re-confirmed' DATE=2026-08-11 bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: the pathological shape updates rather than refusing"; else fail "promote-intent: the pathological shape updates rather than refusing (rc=$rc)"; fi
if [[ "$(wc -l < "$INT" | tr -d ' ')" = 3 ]]; then pass "promote-intent: the result is bullet + adopted guard + reparented guard"; else fail "promote-intent: the result is bullet + adopted guard + reparented guard (got $(wc -l < "$INT" | tr -d ' ') lines)"; fi
expect "promote-intent: the adopted guard is line 2" bash -c "test \"\$(sed -n 2p '$INT')\" = '  guard: test -f intent.md'"
expect "promote-intent: the stranded line is line 3, still indented" bash -c "test \"\$(sed -n 3p '$INT')\" = '  guard: test ! -e web/'"
refute "promote-intent: no column-0 guard survives" grep -qE '^guard:' "$INT"

# The fail-safe direction, asserted through the parser: web/ EXISTS in this fixture,
# so the reparented guard FAILS and the entry is quarantined — a re-confirm question,
# not a silently de-guarded fact.
PIR=$SANDBOX/pi-reparent-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-reparent.out" 2>/dev/null )
expect "promote-intent: the reparented guard is live — the entry quarantines" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-reparent.out"
expect "promote-intent: quarantine, not an unparseable finding (the file is well-formed now)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-reparent.out"
refute "promote-intent: the entry does NOT ride into the active view unguarded" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-reparent.out"

fi

if t "promote-intent.sh update — EVERY guard the entry carries survives a keep-the-guard update"; then
# This block PINS the interface:
#   ACTION=update with neither GUARD nor DROP_GUARD keeps ALL of the entry's guards,
#   in file order — not only the first.
#   WHY the shape is reachable: intent-check.sh's grammar allows several `guard:`
#   lines on one entry and requires ALL of them to pass, and this writer's OWN
#   documented repair produces a two-guard entry — the adopt-plus-reparent update in
#   the block above, which Phase 5's re-confirm is the caller of. So a multi-guard
#   entry arrives through documented steps, not only from a hand edit.
#   WHY it matters: the keep path recovered the FIRST guard while the rewrite deleted
#   the whole entry and re-emitted exactly one guard line, so every guard after the
#   first was dropped — stdout "updated", exit 0, no NOTE. That fails OPEN in the one
#   direction this format must never fail in: the entry that used to QUARANTINE on the
#   dropped assertion rides into the active view instead, and the fact steers
#   resolutions with an assertion nobody runs. The parser of record is the assertion
#   that matters here, exactly because the loss is invisible in the writer's output.
PI=$SANDBOX/pi-carry
mkdir -p "$PI"
INT="$PI/intent.md"
# The two-guard entry is built THROUGH the documented repair, not hand-written, so
# this block also pins that the repair's own output round-trips through the writer.
cat > "$INT" <<'EOF'
# Standing intent

- 2026-01-01: web/ is deliberately absent
guard: test -f intent.md
  guard: test ! -e web/
EOF
INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ is deliberately absent' DATE=2026-08-10 bash "$PIS" >/dev/null 2>&1
if [[ "$(grep -c 'guard:' "$INT")" = 2 ]]; then pass "promote-intent: the documented repair leaves a TWO-guard entry"; else fail "promote-intent: the documented repair leaves a TWO-guard entry (got $(grep -c 'guard:' "$INT"))"; fi

# The keep path: a new fact, neither GUARD nor DROP_GUARD.
INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ is deliberately absent — re-confirmed' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-carry.out" 2> "$SANDBOX/pi-carry.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-carry.out")" = updated ]]; then
  pass "promote-intent: the keep-the-guard update over a two-guard entry says 'updated'"
else
  fail "promote-intent: the keep-the-guard update over a two-guard entry says 'updated' (rc=$rc, said '$(cat "$SANDBOX/pi-carry.out")')"
fi
expect "promote-intent: the fact was rewritten and re-dated" \
  grep -qx -- '- 2026-08-11: web/ is deliberately absent — re-confirmed' "$INT"
expect "promote-intent: the entry's FIRST guard is kept, indented, in place" \
  bash -c "test \"\$(sed -n 4p '$INT')\" = '  guard: test -f intent.md'"
expect "promote-intent: the entry's SECOND guard is kept too, in file order" \
  bash -c "test \"\$(sed -n 5p '$INT')\" = '  guard: test ! -e web/'"
if [[ "$(grep -c 'guard:' "$INT")" = 2 ]]; then pass "promote-intent: the update carried both guards, not one"; else fail "promote-intent: the update carried both guards, not one (got $(grep -c 'guard:' "$INT"))"; fi
refute "promote-intent: no column-0 guard was produced by carrying two" grep -qE '^guard:' "$INT"
expect "promote-intent: the file's structure survives" grep -q '^# Standing intent' "$INT"

# The parser of record, with web/ PRESENT so the carried second guard FAILS. The
# entry must quarantine — the dropped-guard bug showed up here as a silent ACTIVE.
mkdir -p "$PI/web"
PIR=$SANDBOX/pi-carry-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-carry-ics.out" 2>/dev/null )
expect "promote-intent: the carried second guard is live — the entry quarantines" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-carry-ics.out"
expect "promote-intent: the carried file is well-formed (nothing unparseable)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-carry-ics.out"
refute "promote-intent: the entry does NOT ride into the active view on the surviving first guard" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-carry-ics.out"
rmdir "$PI/web"

fi

if t "promote-intent.sh update — a THREE-guard entry keeps all three, in order"; then
# This block PINS the interface:
#   "carry every guard" is not "carry two" — the count is whatever the entry has, and
#   the ORDER is the file's. WHY order is asserted: intent-check.sh names the failing
#   guard on its QUARANTINED: line, and Phase 5's re-confirm table quotes it back to
#   the user, so a reordered guard set turns a re-confirm question into a question
#   about a different assertion than the one the author wrote.
PI=$SANDBOX/pi-carry3
mkdir -p "$PI/sub"
INT="$PI/intent.md"
printf 'alpha\n' > "$PI/marker.txt"
cat > "$INT" <<'EOF'
- 2026-01-01: the three shapes behind this fact all still hold
  guard: test -f intent.md
  guard: test -d sub
  guard: grep -q alpha marker.txt
EOF
PIR=$SANDBOX/pi-carry3-run-before
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-carry3-before.out" 2>/dev/null )
expect "promote-intent: the three-guard fixture starts ACTIVE (all three guards in grammar and passing)" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-carry3-before.out"

INTENT=$INT ACTION=update MATCH='the three shapes behind this fact all still hold' \
  ENTRY='the three shapes behind this fact still hold — re-confirmed' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: the three-guard entry updates"; else fail "promote-intent: the three-guard entry updates (rc=$rc)"; fi
if [[ "$(grep -c 'guard:' "$INT")" = 3 ]]; then pass "promote-intent: all THREE guards survive the update"; else fail "promote-intent: all THREE guards survive the update (got $(grep -c 'guard:' "$INT"))"; fi
expect "promote-intent: guard 1 is still guard 1" \
  bash -c "test \"\$(sed -n 2p '$INT')\" = '  guard: test -f intent.md'"
expect "promote-intent: guard 2 is still guard 2" \
  bash -c "test \"\$(sed -n 3p '$INT')\" = '  guard: test -d sub'"
expect "promote-intent: guard 3 is still guard 3" \
  bash -c "test \"\$(sed -n 4p '$INT')\" = '  guard: grep -q alpha marker.txt'"
PIR=$SANDBOX/pi-carry3-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-carry3.out" 2>/dev/null )
expect "promote-intent: the re-confirmed three-guard entry is ACTIVE again" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-carry3.out"
expect "promote-intent: nothing about three guards is unparseable" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-carry3.out"
# Proof the carried guards are genuinely attached and not decoration: break the
# THIRD one and the entry quarantines on it.
printf 'beta\n' > "$PI/marker.txt"
PIR2=$SANDBOX/pi-carry3-run2
( cd "$PI" && RUN=$PIR2 INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-carry3b.out" 2>/dev/null )
expect "promote-intent: breaking the THIRD carried guard quarantines the entry" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-carry3b.out"

fi

if t "promote-intent.sh update — an explicit GUARD replaces EVERY guard, and the NOTE names how many"; then
# This block PINS the interface:
#   GUARD= on a multi-guard entry replaces ALL of its guards with the one given, and
#   says so on stderr.
#   WHY replacement is allowed: the caller NAMED a guard, so there is nothing to
#   infer — same precedence the adoption path already gives an explicit GUARD or
#   DROP_GUARD.
#   WHY it is ANNOUNCED: the caller named ONE guard and TWO committed assertions went,
#   which is the same class of unnamed edit as the orphan sweep and the adoption, and
#   intent-check.sh requires ALL guards to pass — so the entry's vetting genuinely
#   weakens. Exit status and stdout stay 0/"updated" so no caller has to parse for it;
#   the NOTE is what puts the loss in the run's transcript.
PI=$SANDBOX/pi-replace
mkdir -p "$PI"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
- 2026-01-01: web/ is deliberately absent
  guard: test -f intent.md
  guard: test ! -e web/
EOF

INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ is deliberately absent' GUARD='test ! -d web' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-replace.out" 2> "$SANDBOX/pi-replace.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-replace.out")" = updated ]]; then
  pass "promote-intent: replacing a two-guard entry's guards still says 'updated' on stdout"
else
  fail "promote-intent: replacing a two-guard entry's guards still says 'updated' (rc=$rc, said '$(cat "$SANDBOX/pi-replace.out")')"
fi
if [[ "$(grep -c 'guard:' "$INT")" = 1 ]]; then pass "promote-intent: the given GUARD is the entry's only guard afterwards"; else fail "promote-intent: the given GUARD is the entry's only guard afterwards (got $(grep -c 'guard:' "$INT"))"; fi
expect "promote-intent: and it is the guard that was given" \
  bash -c "test \"\$(sed -n 2p '$INT')\" = '  guard: test ! -d web'"
expect "promote-intent: the replacement is ANNOUNCED on stderr, naming HOW MANY guards went" \
  grep -qE 'NOTE:.*2 guard' "$SANDBOX/pi-replace.err"
expect "promote-intent: the NOTE names the guards it replaced, so the transcript can restore them" \
  grep -qF 'test ! -e web/' "$SANDBOX/pi-replace.err"

# Scope: replacing the guard of a SINGLE-guard entry is the documented everyday move
# and stays silent — a NOTE on every replacement would be noise the reader learns to
# skip, and skipped notes are how the multi-guard loss stayed invisible.
INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ is deliberately absent' GUARD='test ! -e web/' DATE=2026-08-12 \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-replace2.err"
refute "promote-intent: replacing the guard of a one-guard entry prints no NOTE" \
  grep -q 'NOTE:' "$SANDBOX/pi-replace2.err"
PIR=$SANDBOX/pi-replace-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-replace-ics.out" 2>/dev/null )
expect "promote-intent: the replaced entry is ACTIVE" grep -qx 'ACTIVE=1' "$SANDBOX/pi-replace-ics.out"
expect "promote-intent: the replaced entry is well-formed" grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-replace-ics.out"

fi

if t "promote-intent.sh update — DROP_GUARD=1 removes EVERY guard, not just the first"; then
# This block PINS the interface:
#   DROP_GUARD=1 leaves the fact guardless whatever number of guards it carried. The
#   caller asked for the entry to stop being guarded, so no NOTE: unlike the sweep,
#   the adoption and a multi-guard replacement, nothing here happens that the caller
#   did not name. The fence is against a "drop the guard" that drops one of three and
#   leaves an entry the caller believes is guardless still quarantining.
PI=$SANDBOX/pi-drop3
mkdir -p "$PI/sub"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
- 2026-01-01: nothing in the grammar can attest this fact any more
  guard: test -f intent.md
  guard: test -d sub
  guard: test ! -e web/
EOF
INTENT=$INT ACTION=update MATCH='nothing in the grammar can attest this fact any more' \
  ENTRY='nothing in the grammar can attest this fact any more' DROP_GUARD=1 DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: DROP_GUARD=1 on a three-guard entry exits 0"; else fail "promote-intent: DROP_GUARD=1 on a three-guard entry exits 0 (rc=$rc)"; fi
refute "promote-intent: not one of the three guards survives DROP_GUARD=1" grep -q 'guard:' "$INT"
expect "promote-intent: the fact survives, guardless" \
  grep -qx -- '- 2026-08-11: nothing in the grammar can attest this fact any more' "$INT"
PIR=$SANDBOX/pi-drop3-run
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-drop3.out" 2>/dev/null )
expect "promote-intent: the de-guarded entry is ACTIVE" grep -qx 'ACTIVE=1' "$SANDBOX/pi-drop3.out"
expect "promote-intent: the de-guarded entry is not a finding" grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-drop3.out"

fi

if t "promote-intent.sh append — a fact recorded with SEVERAL guards is not 'unchanged' for one of them"; then
# This block PINS the interface:
#   append's dedup compares the recorded entry's WHOLE guard set against GUARD, so a
#   fact the file carries with two guards is not a duplicate of the same fact with
#   one — it is a guard change, which is ACTION=update.
#   WHY it must not answer "unchanged": append writes at most one guard, so it can
#   never express a multi-guard entry; reading only the first guard made it answer
#   "already recorded, nothing to do" about an entry carrying an assertion the caller
#   never mentioned, and the caller walked away believing the file says what it
#   passed. The refusal costs the file nothing — neither branch writes — and it names
#   the action that CAN express the change. Same reasoning as the different-single-
#   guard refusal below.
PI=$SANDBOX/pi-append-multi
mkdir -p "$PI"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
- 2026-01-01: web/ is deliberately absent
  guard: test -f intent.md
  guard: test ! -e web/
EOF
cp "$INT" "$SANDBOX/pi-append-multi.snap"
INTENT=$INT ENTRY='web/ is deliberately absent' GUARD='test -f intent.md' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-append-multi.out" 2> "$SANDBOX/pi-append-multi.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'ACTION=update' "$SANDBOX/pi-append-multi.err"; then
  pass "promote-intent: naming ONE guard for a fact recorded with two is refused, naming update"
else
  fail "promote-intent: naming ONE guard for a fact recorded with two is refused, naming update (rc=$rc, said '$(cat "$SANDBOX/pi-append-multi.out")')"
fi
expect "promote-intent: the refusal names BOTH recorded guards" \
  grep -qF 'test -f intent.md | test ! -e web/' "$SANDBOX/pi-append-multi.err"
expect "promote-intent: the refused append left the two-guard entry byte-identical" \
  cmp -s "$SANDBOX/pi-append-multi.snap" "$INT"

fi

if t "promote-intent.sh update — a RUN of orphans under a guardless entry is adopted whole"; then
# This block PINS the interface:
#   adoption takes EVERY column-0 `guard:` line the guardless matched entry OWNS — the
#   whole run, not its first line, and (in the second half of this block) not only the
#   adjacent ones.
#   WHY the shape is reachable: an entry carrying SEVERAL guards is produced by this
#   writer's own documented repair, and the orphan shape is what a prose append that
#   forgot the indent leaves — forgetting it for a two-guard entry is one author making
#   one mistake once, not two unrelated accidents.
#   WHY it matters: this is the guard-dropping fail-OPEN wearing the adoption path's
#   clothes. Before the update the entry is EXCLUDED (its orphans make it
#   UNPARSEABLE, so nothing it says steers anything); adopting one line and letting
#   the sweep delete the other promotes it to ACTIVE on the assertion that happened to
#   be FIRST, while the deleted one — here the FAILING one — never runs again. The
#   fixture is built so the second guard is the one that fails, which is why the
#   parser of record, not the file's shape, is the assertion that settles it.
PI=$SANDBOX/pi-adopt-run-of-orphans
mkdir -p "$PI/web"     # so `test ! -e web/` — the SECOND orphan — FAILS
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
# Standing intent

- 2026-01-01: web/ is deliberately absent
guard: test -f intent.md
guard: test ! -e web/
EOF

# Before: the orphans exclude the entry entirely — it steers nothing.
PIR0=$SANDBOX/pi-adopt-run-before
( cd "$PI" && RUN=$PIR0 INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-adopt-run0.out" 2>/dev/null )
expect "promote-intent: the run-of-orphans fixture starts with NOTHING active" \
  grep -qx 'ACTIVE=0' "$SANDBOX/pi-adopt-run0.out"

INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ is deliberately absent — re-confirmed' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-adopt-run.out" 2> "$SANDBOX/pi-adopt-run.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-adopt-run.out")" = updated ]]; then
  pass "promote-intent: adopting a run of orphans still says 'updated'"
else
  fail "promote-intent: adopting a run of orphans still says 'updated' (rc=$rc, said '$(cat "$SANDBOX/pi-adopt-run.out")')"
fi
if [[ "$(grep -c 'guard:' "$INT")" = 2 ]]; then pass "promote-intent: BOTH orphans came back as guards, not one"; else fail "promote-intent: BOTH orphans came back as guards, not one (got $(grep -c 'guard:' "$INT"))"; fi
expect "promote-intent: the first orphan is the entry's first indented guard" \
  bash -c "test \"\$(sed -n 4p '$INT')\" = '  guard: test -f intent.md'"
expect "promote-intent: the second orphan is the entry's second indented guard, in file order" \
  bash -c "test \"\$(sed -n 5p '$INT')\" = '  guard: test ! -e web/'"
refute "promote-intent: no column-0 guard survives adopting a run" grep -qE '^guard:' "$INT"
expect "promote-intent: the NOTE counts the whole run, so the transcript shows nothing went missing" \
  grep -q 'NOTE: adopted the 2 orphaned column-0 guard line' "$SANDBOX/pi-adopt-run.err"
# Nothing was swept: every orphan MOVED. A "swept 1" here would be the deletion.
refute "promote-intent: adopting the run swept nothing (no orphan was deleted)" \
  grep -q 'NOTE: swept' "$SANDBOX/pi-adopt-run.err"
expect "promote-intent: the file's structure survives" grep -q '^# Standing intent' "$INT"

# The parser of record. The second adopted guard FAILS in this fixture, so the entry
# must QUARANTINE. Adopting only the first would have shown up here as a silent
# ACTIVE=1 — the entry promoted out of the unparseable bucket on a passing assertion
# while the failing one was deleted.
PIR=$SANDBOX/pi-adopt-run-after
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-adopt-run1.out" 2>/dev/null )
expect "promote-intent: the second adopted guard is live — the entry quarantines" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-adopt-run1.out"
expect "promote-intent: the repaired file is well-formed (nothing unparseable)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-adopt-run1.out"
refute "promote-intent: the entry does NOT ride into the active view on the first orphan alone" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-adopt-run1.out"

# ADOPTION IS SCOPED BY OWNERSHIP, exactly like the sweep — so a NON-ADJACENT orphan of
# the matched entry is adopted too, blank line and all. This block used to pin the
# opposite (adoption took only the CONTIGUOUS run, so the detached one was swept with a
# NOTE), and that asymmetry was itself a fail-OPEN wearing the repair's clothes: a blank
# line does not close an entry for intent-check.sh (blanks are HELD), so the line below is
# the matched entry's guard to the parser of record, and `update` — the documented repair
# for exactly this shape — DELETED the assertion it was called to restore, promoting the
# entry from UNPARSEABLE to ACTIVE vetted only by the orphan that happened to be
# adjacent. One reading model, one scope: every orphan the matched entry OWNS comes back
# as its indented guard, and nothing of the caller's own entry is deleted behind its back.
PI2=$SANDBOX/pi-adopt-run-scope
mkdir -p "$PI2"
INT2="$PI2/intent.md"
cat > "$INT2" <<'EOF'
- 2026-01-01: a fact
guard: test -f intent.md

guard: test -d sub
EOF
INTENT=$INT2 ACTION=update MATCH='a fact' ENTRY='a fact — re-confirmed' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-adopt-scope.err"
if [[ "$(grep -c 'guard:' "$INT2")" = 2 ]]; then pass "promote-intent: BOTH owned orphans are adopted — the blank line does not stop adoption any more than it stops ownership"; else fail "promote-intent: BOTH owned orphans are adopted across the blank line (got $(grep -c 'guard:' "$INT2") guards)"; fi
expect "promote-intent: the adjacent orphan is the entry's first indented guard" \
  bash -c "test \"\$(sed -n 2p '$INT2')\" = '  guard: test -f intent.md'"
expect "promote-intent: the DETACHED orphan is the second, in file order" \
  bash -c "test \"\$(sed -n 3p '$INT2')\" = '  guard: test -d sub'"
refute "promote-intent: no column-0 guard survives adopting across the blank" \
  grep -qE '^guard:' "$INT2"
refute "promote-intent: nothing was reported swept — the detached line MOVED, it was not deleted" \
  grep -q 'NOTE: swept' "$SANDBOX/pi-adopt-scope.err"
expect "promote-intent: the adoption NOTE counts BOTH owned orphans" \
  grep -q 'NOTE: adopted the 2 orphaned column-0 guard line' "$SANDBOX/pi-adopt-scope.err"
# The parser of record settles it: `sub` does not exist in this fixture, so the DETACHED
# orphan is the FAILING assertion — the one the old sweep deleted. The entry must
# quarantine on it rather than ride into the active view on the adjacent one alone.
PIR2=$SANDBOX/pi-adopt-scope-run
( cd "$PI2" && RUN=$PIR2 INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-adopt-scope-ics.out" 2>/dev/null )
expect "promote-intent: the adopted DETACHED guard is live — the entry quarantines on it" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-adopt-scope-ics.out"
expect "promote-intent: and the repaired file is well-formed" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-adopt-scope-ics.out"
refute "promote-intent: the entry does NOT go ACTIVE with the detached assertion deleted" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-adopt-scope-ics.out"

fi

if t "promote-intent.sh update — a DROP_GUARD spelling that is not 1/0/empty is refused"; then
# This block PINS the interface:
#   DROP_GUARD accepts 1, 0 and empty. Any other value is a REFUSAL, not a false.
#   WHY: the switch is read by comparing with 1, so `DROP_GUARD=true` / `yes` / `Y`
#   silently took the KEEP path — exit 0, "updated", every guard still attached — and
#   the caller who asked for a guardless fact walked away believing it had one while
#   the entry went on quarantining on a guard nobody meant to keep. The refusal is the
#   same answer this writer gives every other ambiguity, and it costs the file nothing
#   because it fires before any rewrite.
PI=$SANDBOX/pi-dropguard-spelling
mkdir -p "$PI"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
- 2026-01-01: a fact
  guard: test -f intent.md
EOF
cp "$INT" "$SANDBOX/pi-dropguard.snap"
INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact' DROP_GUARD=true DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-dropguard.out" 2> "$SANDBOX/pi-dropguard.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: DROP_GUARD=true is refused, not read as false"; else fail "promote-intent: DROP_GUARD=true is refused, not read as false (rc=$rc, said '$(cat "$SANDBOX/pi-dropguard.out")')"; fi
expect "promote-intent: the refusal names the value it would not guess at" \
  grep -qF "'true'" "$SANDBOX/pi-dropguard.err"
expect "promote-intent: the refused update wrote nothing" cmp -s "$SANDBOX/pi-dropguard.snap" "$INT"
# 0 and unset are the documented ways to say "keep", and both still work.
INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact' DROP_GUARD=0 DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: DROP_GUARD=0 is accepted as 'keep'"; else fail "promote-intent: DROP_GUARD=0 is accepted as 'keep' (rc=$rc)"; fi
expect "promote-intent: DROP_GUARD=0 kept the guard" grep -qx -- '  guard: test -f intent.md' "$INT"

fi

if t "promote-intent.sh retire/update — a UTF-8 BOM does not hide entry #1 from the reading layer"; then
# This block PINS the interface:
#   the writer reads every line the way intent-check.sh does, BOM strip included — so a
#   `<BOM>- ` first line IS an entry: the OWNER of the column-0 guard beneath it, and a
#   fact a MATCH can name.
#   WHY it is a fail-OPEN and not an encoding nicety: intent-check.sh strips a leading BOM
#   before the first line is parsed (its UTF-8 BOM paragraph), while this writer tested
#   the RAW bytes with `/^- /`. On any file a Windows editor had saved, entry ONE was
#   therefore invisible AS AN OWNER, its column-0 guard read as "owned by no entry at all"
#   — the one verdict that means SWEEP — and a retire or update aimed at the OTHER entry
#   deleted it. Entry ONE then flipped from UNPARSEABLE (excluded, steering nothing) to
#   ACTIVE with its author's FAILING assertion gone: the cross-entry fail-OPEN again,
#   reached through three bytes of encoding. The same blindness made the BOM'd entry
#   unreachable by MATCH, so it could not be repaired through its own writer either.
#   Every verdict below is the real intent-check.sh's, run on the fixture.
# web/ EXISTS in both arms, so entry ONE's guard is one that FAILS.
PI=$SANDBOX/pi-bom
mkdir -p "$PI/retire/web" "$PI/adopt/web"
for d in retire adopt; do
  {
    printf '\357\273\277'
    printf '%s\n' '- 2026-01-01: entry ONE — web/ is deliberately absent'
    printf '%s\n' 'guard: test ! -e web/'
    printf '%s\n' '- 2026-02-02: entry TWO — vendor/ is committed on purpose'
    printf '%s\n' '  guard: test -f intent.md'
  } > "$PI/$d/intent.md"
done

# GROUND TRUTH: intent-check.sh strips the BOM, so entry ONE is a bullet and the line
# below it is ONE's orphan — ONE is excluded, entry TWO is active on its own guard.
PIR=$SANDBOX/pi-bom-before
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-bom-before.out" 2>/dev/null )
expect "promote-intent: intent-check.sh reads the BOM'd first line as an ENTRY and excludes it (bullet + orphan)" \
  grep -qx 'UNPARSEABLE=2' "$SANDBOX/pi-bom-before.out"
expect "promote-intent: and only entry TWO is active in the BOM'd fixture" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-bom-before.out"

# --- retiring the OTHER entry must not touch the BOM'd entry's guard -----------------
INT="$PI/retire/intent.md"
INTENT=$INT ACTION=retire MATCH='entry TWO — vendor/ is committed on purpose' \
  bash "$PIS" > "$SANDBOX/pi-bom-retire.out" 2> "$SANDBOX/pi-bom-retire.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-bom-retire.out")" = retired ]]; then
  pass "promote-intent: retiring TWO in a BOM'd file says 'retired'"
else
  fail "promote-intent: retiring TWO in a BOM'd file says 'retired' (rc=$rc, said '$(cat "$SANDBOX/pi-bom-retire.out")')"
fi
expect "promote-intent: the BOM'd entry's guard is PROTECTED — it belongs to an entry the caller never named" \
  grep -qx -- 'guard: test ! -e web/' "$INT"
refute "promote-intent: and nothing was reported swept (no committed line was deleted)" \
  grep -q 'NOTE: swept' "$SANDBOX/pi-bom-retire.err"
PIR=$SANDBOX/pi-bom-retire-run
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-bom-retire-ics.out" 2>/dev/null )
# The load-bearing assertion: the BOM'd entry must still be EXCLUDED. Reading `/^- /` on
# the raw bytes left this at ACTIVE=1 — the BOM'd fact steering resolutions with its
# failing assertion deleted.
expect "promote-intent: after the retire the BOM'd entry is STILL excluded" \
  grep -qx 'ACTIVE=0' "$SANDBOX/pi-bom-retire-ics.out"
refute "promote-intent: the BOM'd entry did NOT ride into the active view de-guarded" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-bom-retire-ics.out"
refute "promote-intent: and it steers nothing — it is not in intent-active.md" \
  grep -qF 'entry ONE' "$PIR/intent-active.md"

# --- and the BOM'd entry is itself reachable through the writer, which is its repair --
INT="$PI/adopt/intent.md"
INTENT=$INT ACTION=update MATCH='entry ONE — web/ is deliberately absent' \
  ENTRY='entry ONE — web/ is deliberately absent' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-bom-update.out" 2> "$SANDBOX/pi-bom-update.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-bom-update.out")" = updated ]]; then
  pass "promote-intent: the BOM'd entry can be MATCHED and updated (it was unreachable before)"
else
  fail "promote-intent: the BOM'd entry can be MATCHED and updated (rc=$rc, said '$(cat "$SANDBOX/pi-bom-update.out")')"
fi
expect "promote-intent: its own orphan is ADOPTED as its indented guard" \
  grep -qx -- '  guard: test ! -e web/' "$INT"
expect "promote-intent: the rewritten bullet is a plain column-0 bullet (the BOM went with the line it was on)" \
  grep -qxF -- '- 2026-08-11: entry ONE — web/ is deliberately absent' "$INT"
refute "promote-intent: no column-0 guard survives the BOM'd entry's own repair" \
  grep -qE '^guard:' "$INT"
PIR=$SANDBOX/pi-bom-adopt-run
( cd "$PI/adopt" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-bom-adopt-ics.out" 2>/dev/null )
expect "promote-intent: the repaired BOM'd entry quarantines on its adopted failing guard" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-bom-adopt-ics.out"
expect "promote-intent: and the repaired file is well-formed" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-bom-adopt-ics.out"

fi

if t "promote-intent.sh retire — an entry whose guards continue past a BLANK line goes WHOLE, never transplanted"; then
# This block PINS the interface:
#   the entry's EXTENT is intent-check.sh's: the bullet plus every following indented
#   continuation line ACROSS blank lines (its BLANKS_HELD rule). A retire deletes that
#   whole extent.
#   WHY: the writer's extent stopped at the first blank line while the parser of record
#   holds blanks OPEN, so a retire deleted the bullet and part of its continuation and
#   STRANDED the rest. Those indented guard lines then re-attached to the PRECEDING entry
#   in intent-check.sh's reading — a bystander the caller never named acquired an
#   assertion its author never wrote, and here that assertion FAILS, so the innocent entry
#   went from ACTIVE to QUARANTINED on a transplanted guard. Same root as the writer never
#   seeing a blank-separated guard at all (below): one reading model, or none.
# web/ EXISTS, so the blank-separated guard is one that FAILS.
PI=$SANDBOX/pi-held-blank
mkdir -p "$PI/web"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
- 2026-01-01: entry ZERO — the API is versioned in path
  guard: test -f intent.md
- 2026-02-02: entry ONE — retire me

  guard: test ! -e web/
- 2026-03-03: entry TWO — vendor/ is committed on purpose
EOF

# GROUND TRUTH: the blank-separated guard is entry ONE's, and ONE's alone — ONE
# quarantines on it while ZERO and TWO are active.
PIR=$SANDBOX/pi-held-before
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-held-before.out" 2>/dev/null )
expect "promote-intent: intent-check.sh attaches the blank-separated guard to entry ONE" \
  grep -qxF -- '- 2026-02-02: entry ONE — retire me' "$PIR/intent-quarantined.md"
expect "promote-intent: and the bystander entry ZERO starts ACTIVE" \
  grep -qxF -- '- 2026-01-01: entry ZERO — the API is versioned in path' "$PIR/intent-active.md"

INTENT=$INT ACTION=retire MATCH='entry ONE — retire me' \
  bash "$PIS" > "$SANDBOX/pi-held-retire.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-held-retire.out")" = retired ]]; then
  pass "promote-intent: retiring an entry with a blank-separated guard says 'retired'"
else
  fail "promote-intent: retiring an entry with a blank-separated guard says 'retired' (rc=$rc, said '$(cat "$SANDBOX/pi-held-retire.out")')"
fi
refute "promote-intent: the blank-separated guard went WITH the entry (nothing stranded)" \
  grep -qF 'test ! -e web/' "$INT"
refute "promote-intent: the retired bullet is gone" grep -qF 'entry ONE' "$INT"
if [[ "$(grep -c 'guard:' "$INT")" = 1 ]]; then pass "promote-intent: exactly the bystander's own guard is left in the file"; else fail "promote-intent: exactly the bystander's own guard is left in the file (got $(grep -c 'guard:' "$INT"))"; fi
PIR=$SANDBOX/pi-held-after
( cd "$PI" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-held-after.out" 2>/dev/null )
# The load-bearing assertion, from the parser of record: the bystander must be untouched.
# The stranded-guard retire showed up here as QUARANTINED=1 — entry ZERO, on an assertion
# transplanted from the entry that was retired.
expect "promote-intent: nothing quarantines after the retire — no guard was transplanted onto a bystander" \
  grep -qx 'QUARANTINED=0' "$SANDBOX/pi-held-after.out"
expect "promote-intent: the two surviving entries are both ACTIVE" \
  grep -qx 'ACTIVE=2' "$SANDBOX/pi-held-after.out"
expect "promote-intent: and the file is well-formed (nothing stranded at any indent)" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-held-after.out"
expect "promote-intent: the bystander is still in the active view, on its OWN guard alone" \
  grep -qxF -- '- 2026-01-01: entry ZERO — the API is versioned in path' "$PIR/intent-active.md"

fi

if t "promote-intent.sh update — GUARD and DROP_GUARD see a BLANK-separated guard too"; then
# This block PINS the interface:
#   the guard resolution reads the entry's guards through the same extent rule, so a guard
#   held open across a blank line is one of the entry's guards for every path — replaced
#   by GUARD, removed by DROP_GUARD, and re-emitted ADJACENT to the bullet when kept.
#   WHY: with the writer's extent stopping at the blank, the rewrite replaced only the
#   bullet and left the gap and the guard below it — where they re-attached to the NEW
#   bullet. So `DROP_GUARD=1` reported "updated" over an entry that was STILL guarded (the
#   caller walked away believing the fact was guardless while it went on quarantining),
#   and `GUARD=` ADDED a guard rather than replacing one, leaving the entry vetted by both
#   the new assertion and the one the caller had just overridden.
# web/ EXISTS, so the pre-existing blank-separated guard is one that FAILS.
PI=$SANDBOX/pi-held-resolve
for d in drop replace keep; do mkdir -p "$PI/$d/web"; done
for d in drop replace keep; do
  cat > "$PI/$d/intent.md" <<'EOF'
- 2026-01-01: a fact whose guard sits past a blank line

  guard: test ! -e web/
EOF
done

# --- DROP_GUARD=1 ------------------------------------------------------------------
INT="$PI/drop/intent.md"
INTENT=$INT ACTION=update MATCH='a fact whose guard sits past a blank line' \
  ENTRY='a fact whose guard sits past a blank line' DROP_GUARD=1 DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: DROP_GUARD=1 over a blank-separated guard exits 0"; else fail "promote-intent: DROP_GUARD=1 over a blank-separated guard exits 0 (rc=$rc)"; fi
refute "promote-intent: DROP_GUARD=1 removed the blank-separated guard as well" grep -q 'guard:' "$INT"
PIR=$SANDBOX/pi-held-drop-run
( cd "$PI/drop" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-held-drop.out" 2>/dev/null )
expect "promote-intent: the de-guarded fact is ACTIVE, as the caller was told" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-held-drop.out"
refute "promote-intent: it is NOT still quarantining on the guard the caller dropped" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-held-drop.out"

# --- GUARD= ------------------------------------------------------------------------
INT="$PI/replace/intent.md"
INTENT=$INT ACTION=update MATCH='a fact whose guard sits past a blank line' \
  ENTRY='a fact whose guard sits past a blank line' GUARD='test -f intent.md' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: GUARD= over a blank-separated guard exits 0"; else fail "promote-intent: GUARD= over a blank-separated guard exits 0 (rc=$rc)"; fi
if [[ "$(grep -c 'guard:' "$INT")" = 1 ]]; then pass "promote-intent: GUARD= REPLACED the blank-separated guard rather than adding to it"; else fail "promote-intent: GUARD= REPLACED the blank-separated guard rather than adding to it (got $(grep -c 'guard:' "$INT"))"; fi
expect "promote-intent: and the guard on the entry is the one that was given" \
  grep -qx -- '  guard: test -f intent.md' "$INT"
PIR=$SANDBOX/pi-held-replace-run
( cd "$PI/replace" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-held-replace.out" 2>/dev/null )
expect "promote-intent: the re-guarded entry is ACTIVE on the replacement alone" \
  grep -qx 'ACTIVE=1' "$SANDBOX/pi-held-replace.out"

# --- neither: the guard is KEPT, and comes back adjacent to the bullet ---------------
INT="$PI/keep/intent.md"
INTENT=$INT ACTION=update MATCH='a fact whose guard sits past a blank line' \
  ENTRY='a fact whose guard sits past a blank line — re-confirmed' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: the keep path over a blank-separated guard exits 0"; else fail "promote-intent: the keep path over a blank-separated guard exits 0 (rc=$rc)"; fi
expect "promote-intent: the kept guard is re-emitted as the line after the bullet" \
  bash -c "test \"\$(sed -n 2p '$INT')\" = '  guard: test ! -e web/'"
if [[ "$(grep -c 'guard:' "$INT")" = 1 ]]; then pass "promote-intent: kept once, not duplicated"; else fail "promote-intent: kept once, not duplicated (got $(grep -c 'guard:' "$INT"))"; fi
PIR=$SANDBOX/pi-held-keep-run
( cd "$PI/keep" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-held-keep.out" 2>/dev/null )
expect "promote-intent: the kept guard is live — the entry quarantines on it" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-held-keep.out"
expect "promote-intent: and the rewritten entry is well-formed" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-held-keep.out"

fi

if t "promote-intent.sh — a CRLF checkout is the SAME file: dedup, retire and update all read it"; then
# This block PINS the interface:
#   one trailing carriage return is stripped from every line before any COMPARISON, the
#   same strip intent-check.sh applies before parsing — so a Windows clone's intent file
#   holds the same facts and the same guards as an LF one. Lines the rewrite does not
#   touch keep their bytes.
#   WHY the append direction is the dangerous one: the fact comparison took the bullet
#   tail INCLUDING the CR, so retire and update failed CLOSED (a MATCH never matched:
#   annoying, safe) while append's dedup failed OPEN — "appended", exit 0, a SECOND entry
#   for a fact the file already carried. Two entries for one fact is exactly the poisoning
#   the fact-scoped dedup exists to prevent: find_entry refuses ambiguity, so from then on
#   the fact could never be retired or updated again by its own format owner.
PI=$SANDBOX/pi-crlf
mkdir -p "$PI/append" "$PI/rewrite/web"
printf -- '- 2026-01-01: web/ is deliberately absent\r\n  guard: test ! -e web/\r\n' \
  > "$PI/append/intent.md"
cp "$PI/append/intent.md" "$SANDBOX/pi-crlf-append.snap"
INT="$PI/append/intent.md"
INTENT=$INT ENTRY='web/ is deliberately absent' GUARD='test ! -e web/' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-crlf-append.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-crlf-append.out")" = unchanged ]]; then
  pass "promote-intent: re-appending a fact recorded in a CRLF file is 'unchanged'"
else
  fail "promote-intent: re-appending a fact recorded in a CRLF file is 'unchanged' (rc=$rc, said '$(cat "$SANDBOX/pi-crlf-append.out")')"
fi
expect "promote-intent: and the CRLF file is byte-identical — no duplicate was stacked" \
  cmp -s "$SANDBOX/pi-crlf-append.snap" "$INT"
# The poisoning test: one duplicate would make every later retire refuse as ambiguous.
INTENT=$INT ACTION=retire MATCH='web/ is deliberately absent' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: the fact in the CRLF file is still retirable (no ambiguity was created)"; else fail "promote-intent: the fact in the CRLF file is still retirable (rc=$rc)"; fi

# --- the rewrites: a CRLF entry can be retired and updated, and untouched lines keep
# --- their bytes.
printf -- '- 2026-01-01: entry ONE — retire me\r\n  guard: test -f intent.md\r\n- 2026-02-02: entry TWO — web/ is deliberately absent\r\n  guard: test ! -e web/\r\n' \
  > "$PI/rewrite/intent.md"
INT="$PI/rewrite/intent.md"
INTENT=$INT ACTION=retire MATCH='entry ONE — retire me' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: a CRLF entry can be retired at all"; else fail "promote-intent: a CRLF entry can be retired at all (rc=$rc)"; fi
refute "promote-intent: the retired CRLF entry is gone, guard and all" \
  grep -qF 'test -f intent.md' "$INT"
if [[ "$(LC_ALL=C tr -dc '\r' < "$INT" | wc -c | tr -d ' ')" = 2 ]]; then
  pass "promote-intent: the surviving CRLF lines keep their carriage returns (verbatim means verbatim)"
else
  fail "promote-intent: the surviving CRLF lines keep their carriage returns (got $(LC_ALL=C tr -dc '\r' < "$INT" | wc -c | tr -d ' ') CR bytes, want 2)"
fi
INTENT=$INT ACTION=update MATCH='entry TWO — web/ is deliberately absent' \
  ENTRY='entry TWO — web/ is deliberately absent' DATE=2026-08-11 bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: a CRLF entry can be updated"; else fail "promote-intent: a CRLF entry can be updated (rc=$rc)"; fi
expect "promote-intent: its kept guard is re-emitted WITHOUT the carriage return, so it is in grammar" \
  grep -qx -- '  guard: test ! -e web/' "$INT"
PIR=$SANDBOX/pi-crlf-run
( cd "$PI/rewrite" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-crlf.out" 2>/dev/null )
expect "promote-intent: the kept guard is live after the CRLF update — the entry quarantines" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-crlf.out"
expect "promote-intent: and nothing in the rewritten CRLF file is unparseable" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-crlf.out"

fi

if t "promote-intent.sh — a \`guard:\` line that states NO assertion is refused, never silently dropped"; then
# This block PINS the interface:
#   guard-ness is the `guard:` PREFIX, not the value — intent-check.sh's rule, stated in
#   its header: a `guard:` line with nothing after the colon is a guard the author meant
#   to state and did not, so the ENTRY is UNPARSEABLE rather than guardless. This writer
#   cannot re-emit that line without deciding what the author meant, so the keep path
#   REFUSES and names the two ways to state the intent.
#   WHY refusing rather than writing: reading the value first and keeping it only when
#   non-empty made the empty guard invisible, so a keep-the-guard update deleted the line
#   with the rest of the entry and re-emitted a bullet ALONE — "updated", exit 0, no NOTE,
#   and the entry left the unparseable bucket for the ACTIVE view with the assertion its
#   author started to write now gone. That is the fail-OPEN this file exists to prevent,
#   so the ambiguity fails CLOSED instead.
PI=$SANDBOX/pi-empty-guard
mkdir -p "$PI/keep" "$PI/orphan" "$PI/state" "$PI/drop" "$PI/retire" "$PI/append"
for d in keep orphan state drop retire append; do
  case "$d" in
    orphan) printf -- '- 2026-01-01: a fact\nguard:\n' > "$PI/$d/intent.md" ;;
    *)      printf -- '- 2026-01-01: a fact\n  guard:\n' > "$PI/$d/intent.md" ;;
  esac
done

# GROUND TRUTH: the entry is UNPARSEABLE for the empty guard, not active-and-guardless.
PIR=$SANDBOX/pi-empty-before
( cd "$PI/keep" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-empty-before.out" 2>/dev/null )
expect "promote-intent: intent-check.sh reports the empty-guard entry UNPARSEABLE, never guardless" \
  grep -qxF -- '- 2026-01-01: a fact' "$PIR/intent-unparseable.md"
refute "promote-intent: and it steers nothing — it is not in the active view" \
  grep -qF 'a fact' "$PIR/intent-active.md"

INT="$PI/keep/intent.md"
cp "$INT" "$SANDBOX/pi-empty.snap"
INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact — re-confirmed' DATE=2026-08-11 \
  bash "$PIS" > "$SANDBOX/pi-empty-keep.out" 2> "$SANDBOX/pi-empty-keep.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: the keep path over an empty guard is REFUSED"; else fail "promote-intent: the keep path over an empty guard is REFUSED (rc=$rc, said '$(cat "$SANDBOX/pi-empty-keep.out")')"; fi
expect "promote-intent: the refusal names both ways to state the intent" \
  bash -c "grep -qF 'GUARD=' '$SANDBOX/pi-empty-keep.err' && grep -qF 'DROP_GUARD=1' '$SANDBOX/pi-empty-keep.err'"
expect "promote-intent: and the refused update wrote nothing" cmp -s "$SANDBOX/pi-empty.snap" "$INT"

# The same refusal for a column-0 empty guard the matched entry OWNS: adoption cannot
# re-attach an assertion nobody stated either.
INT="$PI/orphan/intent.md"
cp "$INT" "$SANDBOX/pi-empty-orphan.snap"
INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact — re-confirmed' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: adopting an owned column-0 guard that states nothing is refused too"; else fail "promote-intent: adopting an owned column-0 guard that states nothing is refused too (rc=$rc)"; fi
expect "promote-intent: and that refusal wrote nothing either" cmp -s "$SANDBOX/pi-empty-orphan.snap" "$INT"

# The three exits the refusal names, all of which state the intent explicitly.
INT="$PI/state/intent.md"
INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact' GUARD='test -f intent.md' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: stating the guard with GUARD= repairs the entry"; else fail "promote-intent: stating the guard with GUARD= repairs the entry (rc=$rc)"; fi
if [[ "$(grep -c 'guard:' "$INT")" = 1 ]]; then pass "promote-intent: the repaired entry carries exactly the guard that was stated"; else fail "promote-intent: the repaired entry carries exactly the guard that was stated (got $(grep -c 'guard:' "$INT"))"; fi
PIR=$SANDBOX/pi-empty-state-run
( cd "$PI/state" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-empty-state.out" 2>/dev/null )
expect "promote-intent: and it is well-formed afterwards" grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-empty-state.out"

INT="$PI/drop/intent.md"
INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact' DROP_GUARD=1 DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: DROP_GUARD=1 removes the empty guard line"; else fail "promote-intent: DROP_GUARD=1 removes the empty guard line (rc=$rc)"; fi
refute "promote-intent: no guard line survives DROP_GUARD=1" grep -q 'guard:' "$INT"

INT="$PI/retire/intent.md"
INTENT=$INT ACTION=retire MATCH='a fact' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: retire takes the entry and its empty guard together"; else fail "promote-intent: retire takes the entry and its empty guard together (rc=$rc)"; fi
refute "promote-intent: the retired entry left no trace" grep -q 'a fact\|guard:' "$INT"

# append cannot express the recorded set either, so it refuses and names the action that can.
INT="$PI/append/intent.md"
cp "$INT" "$SANDBOX/pi-empty-append.snap"
INTENT=$INT ENTRY='a fact' DATE=2026-08-11 bash "$PIS" >/dev/null 2> "$SANDBOX/pi-empty-append.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'ACTION=update' "$SANDBOX/pi-empty-append.err"; then
  pass "promote-intent: re-appending a fact whose entry carries an empty guard is refused, naming update"
else
  fail "promote-intent: re-appending a fact whose entry carries an empty guard is refused, naming update (rc=$rc)"
fi
expect "promote-intent: and that refusal left the file byte-identical" \
  cmp -s "$SANDBOX/pi-empty-append.snap" "$INT"

fi

if t "promote-intent.sh — a file intent-check.sh refuses WHOLE (a NUL byte, a conflict marker) is not written"; then
# This block PINS the interface:
#   the two whole-file refusals intent-check.sh makes before it parses a single line — a
#   NUL byte anywhere, and a git conflict marker — are refusals HERE too, for every
#   action.
#   WHY: they are the reading model's outermost rule, and the writer diverging on them is
#   the same class of divergence as any other. In a NUL-carrying file the line reader
#   cannot see the bytes past the NUL, so no entry it edits means what it appears to say
#   and nothing it copies out is verbatim; in a conflict-marked file every fact is present
#   TWICE, interleaved, so a MATCH lands on one side of a merge the writer cannot know is
#   the wanted one. The parser of record vets NOTHING in either file — it names the file
#   and stops — so a writer that edits it anyway is editing a file whose facts are not
#   readable, on behalf of a caller who was told the edit landed. The repair is the same
#   in both cases and it is not this script's: remove the NUL bytes, resolve the merge.
PI=$SANDBOX/pi-file-refusal
mkdir -p "$PI/nul" "$PI/conflict"
printf -- '- 2026-01-01: a fact\n  guard: test -e intent.md\000; touch W\n' > "$PI/nul/intent.md"
{
  printf '%s\n' '- 2026-01-01: a fact'
  printf '%s\n' '<<<<<<< HEAD'
  printf '%s\n' '  guard: test -f intent.md'
  printf '%s\n' '======='
  printf '%s\n' '  guard: test -f other.md'
  printf '%s\n' '>>>>>>> theirs'
} > "$PI/conflict/intent.md"

for v in nul conflict; do
  # The needle is the REASON and not the file name — `grep -i nul` alone was satisfied
  # by the fixture's own path in the "no entry carries that fact" refusal the NUL-blind
  # reader happened to produce, which is the wrong refusal for the right file.
  case "$v" in
    nul)      NEEDLE='NUL byte' ;;
    conflict) NEEDLE='conflict marker' ;;
  esac
  # GROUND TRUTH: intent-check.sh refuses the whole file as ONE finding and vets nothing.
  PIR=$SANDBOX/pi-refusal-$v-ics
  ( cd "$PI/$v" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-refusal-$v.out" 2>/dev/null )
  expect "promote-intent: [$v] intent-check.sh vets nothing in this file" \
    grep -qx 'ACTIVE=0' "$SANDBOX/pi-refusal-$v.out"
  expect "promote-intent: [$v] and refuses it as one whole-file finding" \
    grep -qx 'UNPARSEABLE=1' "$SANDBOX/pi-refusal-$v.out"

  INT="$PI/$v/intent.md"
  cp "$INT" "$SANDBOX/pi-refusal-$v.snap"
  INTENT=$INT ACTION=retire MATCH='a fact' bash "$PIS" >/dev/null 2> "$SANDBOX/pi-refusal-$v-ret.err"; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "promote-intent: [$v] retire refuses the file"; else fail "promote-intent: [$v] retire refuses the file (rc=$rc)"; fi
  expect "promote-intent: [$v] the refusal names WHY the file cannot be read" \
    grep -qiF "$NEEDLE" "$SANDBOX/pi-refusal-$v-ret.err"
  expect "promote-intent: [$v] and the retire wrote nothing" cmp -s "$SANDBOX/pi-refusal-$v.snap" "$INT"

  INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact — re-confirmed' bash "$PIS" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "promote-intent: [$v] update refuses the file"; else fail "promote-intent: [$v] update refuses the file (rc=$rc)"; fi
  INTENT=$INT ENTRY='a brand new fact' DATE=2026-08-11 bash "$PIS" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "promote-intent: [$v] append refuses the file too (an appended fact would not be vetted either)"; else fail "promote-intent: [$v] append refuses the file too (rc=$rc)"; fi
  expect "promote-intent: [$v] nothing was written by any of the three actions" \
    cmp -s "$SANDBOX/pi-refusal-$v.snap" "$INT"
done

fi

if t "promote-intent.sh — bad input is refused before anything is written"; then
PI=$SANDBOX/pi-bad
mkdir -p "$PI"
INT="$PI/intent.md"
printf -- '- 2026-01-01: a fact\n' > "$INT"
cp "$INT" "$SANDBOX/pi-bad.snap"

INTENT=$INT bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: append with no ENTRY is refused"; else fail "promote-intent: append with no ENTRY is refused"; fi
INTENT=$INT ENTRY='   ' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: a whitespace-only ENTRY is as empty as an unset one"; else fail "promote-intent: a whitespace-only ENTRY is as empty as an unset one"; fi
INTENT=$INT ACTION=retire bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: retire with no MATCH is refused"; else fail "promote-intent: retire with no MATCH is refused"; fi
INTENT=$INT ACTION=update MATCH='a fact' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: update with no ENTRY is refused"; else fail "promote-intent: update with no ENTRY is refused"; fi
INTENT=$INT ACTION=frobnicate ENTRY='x' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: an unknown ACTION is refused"; else fail "promote-intent: an unknown ACTION is refused"; fi
expect "promote-intent: no refusal wrote anything" cmp -s "$SANDBOX/pi-bad.snap" "$INT"

# Appending the same fact with a DIFFERENT guard is an update, not an append —
# guessing which guard wins is the silent de-guarding this writer prevents.
INTENT=$INT ENTRY='a fact' GUARD='test -f x' DATE=2026-01-01 bash "$PIS" >/dev/null 2> "$SANDBOX/pi-bad.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'ACTION=update' "$SANDBOX/pi-bad.err"; then
  pass "promote-intent: re-appending one fact with a different guard is refused, naming update"
else
  fail "promote-intent: re-appending one fact with a different guard is refused, naming update (rc=$rc)"
fi
expect "promote-intent: that refusal wrote nothing either" cmp -s "$SANDBOX/pi-bad.snap" "$INT"

fi

if t "promote-intent.sh append — a file whose LAST LINE carries no terminator is not spliced onto"; then
# This block PINS the interface:
#   append probes the file's last BYTE and emits the missing newline before its bullet, so
#   the new entry is a line of its own whatever class the unterminated final line belongs
#   to (bullet, indented guard, column-0 orphan, prose) — and every byte the file already
#   carried survives.
#   WHY: intent-check.sh's line reader deliberately takes a final UNTERMINATED line as a
#   line (`read … || [ -n "$line" ]`), so the writer reads one too or the two disagree on
#   the file's last fact. printf-appending without the probe SPLICED the bullet onto that
#   line: onto a trailing indented `guard:` it made ONE out-of-grammar guard line and NO
#   new entry — exit 0, "appended", the fact the caller was told was recorded is not an
#   entry at all and the entry above it left the active view UNPARSEABLE; onto a trailing
#   bullet it fused two facts into one unreadable line, making BOTH unreachable by MATCH.
PI=$SANDBOX/pi-noeol
for v in guard bullet orphan prose; do mkdir -p "$PI/$v"; done
printf -- '- 2026-01-01: a recorded fact\n  guard: test -f intent.md' > "$PI/guard/intent.md"
printf -- '- 2026-01-01: a recorded fact' > "$PI/bullet/intent.md"
printf -- '- 2026-01-01: a recorded fact\nguard: test -f intent.md' > "$PI/orphan/intent.md"
printf -- '- 2026-01-01: a recorded fact\n## a heading with no newline' > "$PI/prose/intent.md"

for v in guard bullet orphan prose; do
  INT="$PI/$v/intent.md"
  LAST=$(tail -n 1 "$INT")
  SNAP=$SANDBOX/pi-noeol-$v.snap
  cp "$INT" "$SNAP"
  # GROUND TRUTH: what the parser of record makes of the file BEFORE the append. The
  # appended fact is guardless, so a faithful append moves ACTIVE by exactly one and
  # leaves every other verdict where it was.
  PIR=$SANDBOX/pi-noeol-$v-before
  ( cd "$PI/$v" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-noeol-$v-before.out" 2>/dev/null )
  A_BEFORE=$(sed -n 's/^ACTIVE=//p' "$SANDBOX/pi-noeol-$v-before.out")
  U_BEFORE=$(sed -n 's/^UNPARSEABLE=//p' "$SANDBOX/pi-noeol-$v-before.out")

  INTENT=$INT ENTRY='a brand new fact' DATE=2026-08-11 bash "$PIS" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 0 ]]; then pass "promote-intent: [$v, no trailing newline] the append exits 0"; else fail "promote-intent: [$v, no trailing newline] the append exits 0 (rc=$rc)"; fi
  expect "promote-intent: [$v, no trailing newline] the file's existing bytes are untouched" \
    bash -c "head -c \"\$(wc -c < '$SNAP' | tr -d ' ')\" '$INT' | cmp -s - '$SNAP'"
  expect "promote-intent: [$v, no trailing newline] the unterminated line is still a WHOLE line of its own" \
    grep -qxF -- "$LAST" "$INT"
  expect "promote-intent: [$v, no trailing newline] the new bullet is a column-0 line of its own" \
    grep -qxF -- '- 2026-08-11: a brand new fact' "$INT"

  PIR=$SANDBOX/pi-noeol-$v-after
  ( cd "$PI/$v" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-noeol-$v-after.out" 2>/dev/null )
  expect "promote-intent: [$v, no trailing newline] the appended fact reaches the active view" \
    grep -qxF -- '- 2026-08-11: a brand new fact' "$PIR/intent-active.md"
  expect "promote-intent: [$v, no trailing newline] it is ONE new active entry, no more" \
    grep -qx "ACTIVE=$((A_BEFORE + 1))" "$SANDBOX/pi-noeol-$v-after.out"
  expect "promote-intent: [$v, no trailing newline] and no verdict on what was already there changed" \
    grep -qx "UNPARSEABLE=$U_BEFORE" "$SANDBOX/pi-noeol-$v-after.out"
  # The appended fact must also be REACHABLE by its own writer afterwards — a spliced
  # bullet is not an entry, so MATCH could never name it again.
  INTENT=$INT ACTION=update MATCH='a brand new fact' ENTRY='a brand new fact — re-confirmed' \
    DATE=2026-08-12 bash "$PIS" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 0 ]]; then pass "promote-intent: [$v, no trailing newline] the appended fact is reachable by MATCH"; else fail "promote-intent: [$v, no trailing newline] the appended fact is reachable by MATCH (rc=$rc)"; fi
done

# The probe must not fire on a file that already ends in a newline, nor on a new file:
# an extra blank line there is a byte the caller never asked for.
PI2=$SANDBOX/pi-noeol-terminated
mkdir -p "$PI2"
printf -- '- 2026-01-01: a recorded fact\n' > "$PI2/intent.md"
INTENT=$PI2/intent.md ENTRY='a brand new fact' DATE=2026-08-11 bash "$PIS" >/dev/null 2>&1
if [[ "$(wc -l < "$PI2/intent.md" | tr -d ' ')" = 2 ]]; then pass "promote-intent: a terminated file gains exactly the new bullet, no blank line"; else fail "promote-intent: a terminated file gains exactly the new bullet, no blank line (got $(wc -l < "$PI2/intent.md" | tr -d ' ') lines)"; fi
refute "promote-intent: and no empty line was introduced" grep -qx '' "$PI2/intent.md"
rm -f "$PI2/intent.md"
INTENT=$PI2/intent.md ENTRY='the first fact of a new file' DATE=2026-08-11 bash "$PIS" >/dev/null 2>&1
if [[ "$(wc -l < "$PI2/intent.md" | tr -d ' ')" = 1 ]]; then pass "promote-intent: a file created by the append starts with its bullet, not with a blank line"; else fail "promote-intent: a file created by the append starts with its bullet (got $(wc -l < "$PI2/intent.md" | tr -d ' ') lines)"; fi

fi

if t "promote-intent.sh update — GUARD together with DROP_GUARD=1 is contradictory input, and refused"; then
# This block PINS the interface:
#   GUARD=<assertion> and DROP_GUARD=1 in the same call are REFUSED (exit 2, naming both),
#   and nothing is written. Either alone still does what it says.
#   WHY: the guard resolution tested DROP_GUARD first and never looked at GUARD, so the
#   pair exited 0 saying "updated" with the entry written GUARDLESS and no NOTE — a caller
#   who NAMED the assertion the fact should carry walked away believing the fact is
#   vetted, while it steers every later resolution with no guard running. That is the
#   file's central failure mode reached through the argument list, and the two flags state
#   OPPOSITE intents, so there is nothing to infer: the pair is rejected whole, the same
#   way record-context.sh rejects a partial record rather than recording half of it.
PI=$SANDBOX/pi-contradiction
for v in both drop replace zero append; do mkdir -p "$PI/$v"; done
for v in both drop replace zero append; do
  printf -- '- 2026-01-01: a fact\n  guard: test -f intent.md\n' > "$PI/$v/intent.md"
done

INT="$PI/both/intent.md"
cp "$INT" "$SANDBOX/pi-contradiction.snap"
INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact' GUARD='test -e go.mod' DROP_GUARD=1 \
  DATE=2026-08-11 bash "$PIS" > "$SANDBOX/pi-contra.out" 2> "$SANDBOX/pi-contra.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: GUARD with DROP_GUARD=1 is refused"; else fail "promote-intent: GUARD with DROP_GUARD=1 is refused (rc=$rc, said '$(cat "$SANDBOX/pi-contra.out")')"; fi
expect "promote-intent: the refusal names BOTH flags it will not choose between" \
  bash -c "grep -qF 'GUARD' '$SANDBOX/pi-contra.err' && grep -qF 'DROP_GUARD=1' '$SANDBOX/pi-contra.err'"
expect "promote-intent: the refusal quotes the guard the caller named" \
  grep -qF 'test -e go.mod' "$SANDBOX/pi-contra.err"
expect "promote-intent: and the contradictory call wrote nothing" \
  cmp -s "$SANDBOX/pi-contradiction.snap" "$INT"
refute "promote-intent: the entry was NOT left guardless behind the caller's back" \
  bash -c "grep -qF 'a fact' '$INT' && ! grep -q 'guard:' '$INT'"
# The same pair on an append (where DROP_GUARD has no meaning at all) is refused too:
# a caller who wrote both did not mean either, whichever action carried them.
INT="$PI/append/intent.md"
cp "$INT" "$SANDBOX/pi-contradiction-append.snap"
INTENT=$INT ENTRY='a brand new fact' GUARD='test -e go.mod' DROP_GUARD=1 DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: append with both flags is refused too"; else fail "promote-intent: append with both flags is refused too (rc=$rc)"; fi
expect "promote-intent: and that refusal wrote nothing either" \
  cmp -s "$SANDBOX/pi-contradiction-append.snap" "$INT"

# Neither flag loses its own meaning: each alone still does exactly what it says.
INT="$PI/drop/intent.md"
INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact' DROP_GUARD=1 DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: DROP_GUARD=1 ALONE still removes the guard"; else fail "promote-intent: DROP_GUARD=1 ALONE still removes the guard (rc=$rc)"; fi
refute "promote-intent: no guard survives DROP_GUARD=1 alone" grep -q 'guard:' "$INT"
INT="$PI/replace/intent.md"
INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact' GUARD='test -e go.mod' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: GUARD= ALONE still replaces the guard"; else fail "promote-intent: GUARD= ALONE still replaces the guard (rc=$rc)"; fi
expect "promote-intent: with exactly the assertion that was named" grep -qx -- '  guard: test -e go.mod' "$INT"
# DROP_GUARD=0 is the KEEP spelling, not a second way to say "drop": pairing it with
# GUARD states one intent, so it is not the contradiction and is not refused.
INT="$PI/zero/intent.md"
INTENT=$INT ACTION=update MATCH='a fact' ENTRY='a fact' GUARD='test -e go.mod' DROP_GUARD=0 \
  DATE=2026-08-11 bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: GUARD with DROP_GUARD=0 is one intent, and is honoured"; else fail "promote-intent: GUARD with DROP_GUARD=0 is one intent, and is honoured (rc=$rc)"; fi
expect "promote-intent: DROP_GUARD=0 kept the replacement guard the caller named" \
  grep -qx -- '  guard: test -e go.mod' "$INT"

fi

if t "promote-intent.sh — an INDENTED guard a CLOSER separated from the entry is the entry's too"; then
# This block PINS the interface:
#   an indented `guard:` line that sits where NO entry is open — a heading, a `---`, column-0
#   prose between it and the bullet — is attributed by intent-check.sh to the entry it
#   follows, which it RETRACTS. So it is that entry's line for a rewrite: retire takes it,
#   update sweeps it under an explicit GUARD/DROP_GUARD and ADOPTS it when the matched entry
#   is guardless and neither was given — every removal or move announced by a NOTE.
#   WHY: the extent rule stops at a closer (correctly — the parser closes the entry there)
#   and orphan_map only ever saw the COLUMN-0 spelling, so this line was invisible to both.
#   `retire` deleted the bullet and STRANDED it, where it re-attached to the entry ABOVE and
#   flipped that bystander from ACTIVE to UNPARSEABLE — exit 0, "retired", no NOTE, the
#   author's fact silently de-guarded one entry over. Under DROP_GUARD=1 the same blindness
#   reported a guardless fact that the parser still excludes for the line left behind.
PI=$SANDBOX/pi-closer-guard
for v in retire keep drop replace first foreign bystander; do mkdir -p "$PI/$v"; done
for v in retire keep drop replace; do
  cat > "$PI/$v/intent.md" <<'EOF'
- 2026-01-01: entry ZERO — the bystander
- 2026-02-02: entry ONE — the matched entry
# a heading, which CLOSES entry ONE
  guard: test -e MISSING
EOF
done

# GROUND TRUTH, from the parser of record: the closer-separated guard is reported as an
# ORPHAN and it RETRACTS entry ONE, while the bystander ZERO is ACTIVE.
PIR=$SANDBOX/pi-closer-before
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-before.out" 2>/dev/null )
expect "promote-intent: intent-check.sh retracts entry ONE for the closer-separated guard" \
  grep -qxF -- '- 2026-02-02: entry ONE — the matched entry' "$PIR/intent-unparseable.md"
expect "promote-intent: and the bystander entry ZERO starts ACTIVE" \
  grep -qxF -- '- 2026-01-01: entry ZERO — the bystander' "$PIR/intent-active.md"

# --- retire: the line goes WITH the entry, and the bystander is left alone -------------
INT="$PI/retire/intent.md"
INTENT=$INT ACTION=retire MATCH='entry ONE — the matched entry' \
  bash "$PIS" > "$SANDBOX/pi-closer-retire.out" 2> "$SANDBOX/pi-closer-retire.err"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-closer-retire.out")" = retired ]]; then
  pass "promote-intent: retiring an entry with a closer-separated guard says 'retired'"
else
  fail "promote-intent: retiring an entry with a closer-separated guard says 'retired' (rc=$rc, said '$(cat "$SANDBOX/pi-closer-retire.out")')"
fi
refute "promote-intent: the closer-separated guard went WITH the entry (nothing stranded)" \
  grep -qF 'test -e MISSING' "$INT"
refute "promote-intent: the retired bullet is gone" grep -qF 'entry ONE — the matched entry' "$INT"
expect "promote-intent: the closer itself is structure and survives" grep -qxF '# a heading, which CLOSES entry ONE' "$INT"
expect "promote-intent: the deletion is announced with the guard TEXT and its line" \
  bash -c "grep -qF 'test -e MISSING' '$SANDBOX/pi-closer-retire.err' && grep -qF 'line 4' '$SANDBOX/pi-closer-retire.err'"
PIR=$SANDBOX/pi-closer-retire-run
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-retire-ics.out" 2>/dev/null )
# The load-bearing assertion: the bystander must not have been flipped out of the active
# view by a guard transplanted onto it.
expect "promote-intent: the bystander is STILL ACTIVE after the retire" \
  grep -qxF -- '- 2026-01-01: entry ZERO — the bystander' "$PIR/intent-active.md"
expect "promote-intent: and the file is well-formed — nothing stranded at any indent" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-closer-retire-ics.out"

# --- update, keep path: the orphan is ADOPTED as the guardless entry's own guard --------
INT="$PI/keep/intent.md"
INTENT=$INT ACTION=update MATCH='entry ONE — the matched entry' \
  ENTRY='entry ONE — re-confirmed' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-closer-keep.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: the keep path over a closer-separated guard exits 0"; else fail "promote-intent: the keep path over a closer-separated guard exits 0 (rc=$rc)"; fi
expect "promote-intent: the adopted guard is re-emitted DIRECTLY under the new bullet" \
  bash -c "test \"\$(sed -n 3p '$INT')\" = '  guard: test -e MISSING'"
if [[ "$(grep -c 'guard:' "$INT")" = 1 ]]; then pass "promote-intent: adopted once, not duplicated"; else fail "promote-intent: adopted once, not duplicated (got $(grep -c 'guard:' "$INT"))"; fi
expect "promote-intent: the adoption is announced as a MOVE, not as a deletion" \
  grep -q 'NOTE: adopted the 1 orphaned indented guard line' "$SANDBOX/pi-closer-keep.err"
PIR=$SANDBOX/pi-closer-keep-run
( cd "$PI/keep" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-keep-ics.out" 2>/dev/null )
expect "promote-intent: the adopted guard is LIVE — the entry quarantines on it" \
  grep -qx 'QUARANTINED=1' "$SANDBOX/pi-closer-keep-ics.out"
expect "promote-intent: and nothing is left unparseable" grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-closer-keep-ics.out"
expect "promote-intent: the bystander is untouched by the update too" \
  grep -qxF -- '- 2026-01-01: entry ZERO — the bystander' "$PIR/intent-active.md"

# --- update, DROP_GUARD=1: a guardless fact is really guardless -------------------------
INT="$PI/drop/intent.md"
INTENT=$INT ACTION=update MATCH='entry ONE — the matched entry' \
  ENTRY='entry ONE — nothing attests this any more' DROP_GUARD=1 DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-closer-drop.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: DROP_GUARD=1 over a closer-separated guard exits 0"; else fail "promote-intent: DROP_GUARD=1 over a closer-separated guard exits 0 (rc=$rc)"; fi
refute "promote-intent: DROP_GUARD=1 removed the closer-separated guard as well" grep -q 'guard:' "$INT"
expect "promote-intent: the removal is announced" grep -qF 'test -e MISSING' "$SANDBOX/pi-closer-drop.err"
PIR=$SANDBOX/pi-closer-drop-run
( cd "$PI/drop" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-drop-ics.out" 2>/dev/null )
expect "promote-intent: the de-guarded fact is ACTIVE, as the caller was told" \
  grep -qx 'ACTIVE=2' "$SANDBOX/pi-closer-drop-ics.out"
expect "promote-intent: and the entry is no longer excluded for a line left behind" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-closer-drop-ics.out"

# --- update, GUARD=: the caller's guard set is the entry's whole guard set --------------
INT="$PI/replace/intent.md"
INTENT=$INT ACTION=update MATCH='entry ONE — the matched entry' \
  ENTRY='entry ONE — re-guarded' GUARD='test -f intent.md' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: GUARD= over a closer-separated guard exits 0"; else fail "promote-intent: GUARD= over a closer-separated guard exits 0 (rc=$rc)"; fi
if [[ "$(grep -c 'guard:' "$INT")" = 1 ]]; then pass "promote-intent: GUARD= left exactly the assertion it named"; else fail "promote-intent: GUARD= left exactly the assertion it named (got $(grep -c 'guard:' "$INT"))"; fi
refute "promote-intent: the superseded closer-separated guard did not survive alongside it" \
  grep -qF 'test -e MISSING' "$INT"
PIR=$SANDBOX/pi-closer-replace-run
( cd "$PI/replace" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-replace-ics.out" 2>/dev/null )
expect "promote-intent: the re-guarded entry is ACTIVE on the replacement alone" \
  grep -qx 'ACTIVE=2' "$SANDBOX/pi-closer-replace-ics.out"

# --- both spellings at once: adopted TOGETHER, in FILE ORDER -----------------------------
# One author forgetting the indent once can leave both shapes under one entry, and
# intent-check.sh names the FAILING guard on its QUARANTINED: line — which Phase 5 quotes
# back — so the order the guards come back in is part of the answer.
PI3=$SANDBOX/pi-closer-mixed
mkdir -p "$PI3/adopt" "$PI3/retire"
for d in adopt retire; do
  cat > "$PI3/$d/intent.md" <<'EOF'
- 2026-01-01: a fact carrying one mistake in two spellings
# a heading, which closes the entry
  guard: test -e A_MISSING
guard: test -e B_MISSING
EOF
done
INT="$PI3/adopt/intent.md"
INTENT=$INT ACTION=update MATCH='a fact carrying one mistake in two spellings' \
  ENTRY='a fact carrying one mistake in two spellings' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-closer-mixed.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: an entry owning BOTH orphan spellings updates"; else fail "promote-intent: an entry owning BOTH orphan spellings updates (rc=$rc)"; fi
expect "promote-intent: the detached guard (earlier in the file) is adopted FIRST" \
  bash -c "test \"\$(sed -n 2p '$INT')\" = '  guard: test -e A_MISSING'"
expect "promote-intent: the column-0 guard (later in the file) is adopted SECOND" \
  bash -c "test \"\$(sed -n 3p '$INT')\" = '  guard: test -e B_MISSING'"
expect "promote-intent: each spelling is announced in its own NOTE" \
  bash -c "grep -q 'adopted the 1 orphaned column-0 guard line' '$SANDBOX/pi-closer-mixed.err' && grep -q 'adopted the 1 orphaned indented guard line' '$SANDBOX/pi-closer-mixed.err'"
PIR=$SANDBOX/pi-closer-mixed-run
( cd "$PI3/adopt" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-mixed.out" 2>/dev/null )
expect "promote-intent: the repaired entry is well-formed, quarantining on its adopted guards" \
  bash -c "grep -qx 'UNPARSEABLE=0' '$SANDBOX/pi-closer-mixed.out' && grep -qx 'QUARANTINED=1' '$SANDBOX/pi-closer-mixed.out'"
INT="$PI3/retire/intent.md"
INTENT=$INT ACTION=retire MATCH='a fact carrying one mistake in two spellings' \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: retiring it takes both spellings with it"; else fail "promote-intent: retiring it takes both spellings with it (rc=$rc)"; fi
refute "promote-intent: no guard line of either spelling is left behind" grep -q 'guard:' "$INT"

# --- no entry precedes the matched one: the line is owned by nobody, and still goes ------
cat > "$PI/first/intent.md" <<'EOF'
- 2026-02-02: the only entry
# a heading, which CLOSES it
  guard: test -e MISSING
EOF
INT="$PI/first/intent.md"
INTENT=$INT ACTION=retire MATCH='the only entry' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: retiring the FIRST entry takes its closer-separated guard too"; else fail "promote-intent: retiring the FIRST entry takes its closer-separated guard too (rc=$rc)"; fi
refute "promote-intent: nothing of the entry is left behind" grep -q 'guard:\|the only entry' "$INT"

# --- the shape whose attribution the parser decides at RUNTIME: refused -----------------
# A column-0 orphan already excluded entry ONE before it was ever flushed, so the parser's
# retraction target when it reaches the INDENTED orphan is the entry BEFORE it — ZERO — and
# only when ZERO vetted ACTIVE. Which of the two readings holds cannot be known without
# running ZERO's guards, and they want OPPOSITE edits: taking the line promotes ZERO from
# UNPARSEABLE to ACTIVE, leaving it re-parents the line onto ZERO as a LIVE guard its author
# never wrote. So the writer refuses instead of guessing.
cat > "$PI/foreign/intent.md" <<'EOF'
- 2026-01-01: entry ZERO — the bystander
- 2026-02-02: entry ONE — the matched entry
guard: test -e MISSING_A
# a heading
  guard: test -e MISSING_B
EOF
INT="$PI/foreign/intent.md"
cp "$INT" "$SANDBOX/pi-closer-foreign.snap"
PIR=$SANDBOX/pi-closer-foreign-before
( cd "$PI/foreign" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-foreign.out" 2>/dev/null )
expect "promote-intent: GROUND TRUTH — the indented orphan retracts the BYSTANDER here, not the matched entry" \
  grep -qxF -- '- 2026-01-01: entry ZERO — the bystander' "$PIR/intent-unparseable.md"
INTENT=$INT ACTION=retire MATCH='entry ONE — the matched entry' \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-closer-foreign-ret.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: a retire whose faithfulness depends on guard results is REFUSED"; else fail "promote-intent: a retire whose faithfulness depends on guard results is REFUSED (rc=$rc)"; fi
expect "promote-intent: the refusal names the line it will not decide about" \
  bash -c "grep -qF 'line 5' '$SANDBOX/pi-closer-foreign-ret.err' && grep -qF 'test -e MISSING_B' '$SANDBOX/pi-closer-foreign-ret.err'"
expect "promote-intent: and names the OTHER entry intent-check.sh may attribute it to" \
  grep -qF 'entry ZERO — the bystander' "$SANDBOX/pi-closer-foreign-ret.err"
INTENT=$INT ACTION=update MATCH='entry ONE — the matched entry' ENTRY='entry ONE — re-confirmed' \
  DATE=2026-08-11 bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: the same update is refused for the same reason"; else fail "promote-intent: the same update is refused for the same reason (rc=$rc)"; fi
expect "promote-intent: neither refusal wrote anything" cmp -s "$SANDBOX/pi-closer-foreign.snap" "$INT"

# --- scope: a closer-separated guard of ANOTHER entry is never the caller's to touch -----
cat > "$PI/bystander/intent.md" <<'EOF'
- 2026-01-01: entry ZERO — retire me
- 2026-02-02: entry ONE — keeps its own orphan
# a heading
  guard: test -e MISSING
- 2026-03-03: entry TWO — untouched
EOF
INT="$PI/bystander/intent.md"
INTENT=$INT ACTION=retire MATCH='entry ZERO — retire me' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: retiring an entry BEFORE a foreign closer-separated guard exits 0"; else fail "promote-intent: retiring an entry BEFORE a foreign closer-separated guard exits 0 (rc=$rc)"; fi
expect "promote-intent: entry ONE's closer-separated guard is left exactly where it was" \
  grep -qx -- '  guard: test -e MISSING' "$INT"
PIR=$SANDBOX/pi-closer-bystander-run
( cd "$PI/bystander" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-closer-bystander.out" 2>/dev/null )
expect "promote-intent: entry ONE is NOT promoted into the active view by someone else's retire" \
  grep -qxF -- '- 2026-02-02: entry ONE — keeps its own orphan' "$PIR/intent-unparseable.md"
expect "promote-intent: and the unrelated entry TWO is still active" \
  grep -qxF -- '- 2026-03-03: entry TWO — untouched' "$PIR/intent-active.md"

fi

if t "promote-intent.sh — the FACT comparison is collapsed on both sides, like every field in"; then
# This block PINS the interface:
#   ENTRY/MATCH are collapsed (trimmed, whitespace squeezed) on the way in, so the file's
#   bullet tail is compared the SAME way: a recorded fact carrying a trailing space, a
#   double space or a tab is the same fact, reachable by retire/update and recognised by
#   append's dedup. Lines the rewrite does not touch keep their bytes verbatim.
#   WHY: comparing the tail VERBATIM against a collapsed MATCH failed in both directions at
#   once — retire/update could never name such an entry ("no entry carries the fact"), while
#   append's dedup compared the same two values and "found nothing", stacking a SECOND,
#   visually identical entry for one fact. That duplicate then poisons the fact for good:
#   find_entry refuses ambiguity, so no later retire or update can touch either copy.
#   And where collapsing makes two DIFFERENT entries equal, the ambiguity is REFUSED with
#   both named rather than resolved by picking the first.
PI=$SANDBOX/pi-collapse
for v in trail dedup interior tab ambig; do mkdir -p "$PI/$v"; done

# --- a trailing space does not hide a fact from its own writer --------------------------
{
  printf -- '- 2026-01-01: a recorded fact \n'
  printf -- '%s\n' 'some prose with a trailing space   '
  printf -- '- 2026-02-02: another fact\n'
} > "$PI/trail/intent.md"
INT="$PI/trail/intent.md"
INTENT=$INT ACTION=retire MATCH='a recorded fact' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: a fact recorded with a trailing space is retirable"; else fail "promote-intent: a fact recorded with a trailing space is retirable (rc=$rc)"; fi
refute "promote-intent: the entry really went" grep -qF 'a recorded fact' "$INT"
expect "promote-intent: an untouched line keeps its own trailing whitespace, byte for byte" \
  grep -qxF -- 'some prose with a trailing space   ' "$INT"
expect "promote-intent: and the unrelated entry survives" grep -qxF -- '- 2026-02-02: another fact' "$INT"

# --- and does not hide it from the dedup either: no visually identical duplicate ---------
printf -- '- 2026-01-01: a recorded fact \n' > "$PI/dedup/intent.md"
INT="$PI/dedup/intent.md"
INTENT=$INT ENTRY='a recorded fact' DATE=2026-08-11 bash "$PIS" > "$SANDBOX/pi-collapse-dedup.out" 2>&1; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-collapse-dedup.out")" = unchanged ]]; then
  pass "promote-intent: re-appending the fact is 'unchanged', not a second entry"
else
  fail "promote-intent: re-appending the fact is 'unchanged', not a second entry (rc=$rc, said '$(cat "$SANDBOX/pi-collapse-dedup.out")')"
fi
if [[ "$(wc -l < "$INT" | tr -d ' ')" = 1 ]]; then pass "promote-intent: the file still carries exactly one entry"; else fail "promote-intent: the file still carries exactly one entry (got $(wc -l < "$INT" | tr -d ' ') lines)"; fi

# --- an interior double space, and a tab, are the same fact too --------------------------
printf -- '- 2026-01-01: a  recorded  fact\n' > "$PI/interior/intent.md"
INT="$PI/interior/intent.md"
INTENT=$INT ACTION=update MATCH='a recorded fact' ENTRY='a recorded fact' DATE=2026-08-11 \
  bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: a fact recorded with a double space is updatable"; else fail "promote-intent: a fact recorded with a double space is updatable (rc=$rc)"; fi
expect "promote-intent: and the rewritten bullet is the collapsed form" \
  grep -qx -- '- 2026-08-11: a recorded fact' "$INT"
printf -- '- 2026-01-01: a\trecorded fact\n' > "$PI/tab/intent.md"
INT="$PI/tab/intent.md"
INTENT=$INT ACTION=retire MATCH='a recorded fact' bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: a fact recorded with a tab is retirable"; else fail "promote-intent: a fact recorded with a tab is retirable (rc=$rc)"; fi

# --- two entries the collapse makes equal: refused, with both named ---------------------
{
  printf -- '- 2026-01-01: a recorded fact \n'
  printf -- '%s\n' '## a heading'
  printf -- '- 2026-02-02: a recorded fact\n'
} > "$PI/ambig/intent.md"
INT="$PI/ambig/intent.md"
cp "$INT" "$SANDBOX/pi-collapse-ambig.snap"
INTENT=$INT ACTION=retire MATCH='a recorded fact' bash "$PIS" >/dev/null 2> "$SANDBOX/pi-collapse-ambig.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: two entries one collapsed fact matches is an AMBIGUITY, refused"; else fail "promote-intent: two entries one collapsed fact matches is an AMBIGUITY, refused (rc=$rc)"; fi
expect "promote-intent: the refusal names BOTH entries by line" \
  bash -c "grep -qF 'line 1' '$SANDBOX/pi-collapse-ambig.err' && grep -qF 'line 3' '$SANDBOX/pi-collapse-ambig.err'"
INTENT=$INT ENTRY='a recorded fact' DATE=2026-08-11 bash "$PIS" > "$SANDBOX/pi-collapse-ambig2.out" 2> "$SANDBOX/pi-collapse-ambig2.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: an append against the same ambiguity is refused, not called 'unchanged'"; else fail "promote-intent: an append against the same ambiguity is refused, not called 'unchanged' (rc=$rc, said '$(cat "$SANDBOX/pi-collapse-ambig2.out")')"; fi
expect "promote-intent: that refusal names both entries too" \
  bash -c "grep -qF 'line 1' '$SANDBOX/pi-collapse-ambig2.err' && grep -qF 'line 3' '$SANDBOX/pi-collapse-ambig2.err'"
expect "promote-intent: neither refusal wrote anything" cmp -s "$SANDBOX/pi-collapse-ambig.snap" "$INT"

fi

if t "promote-intent.sh — a RUN of two column-0 orphans: the parser's attachment is not the nearest bullet"; then
# This block PINS the interface:
#   the entry a column-0 `guard:` is attached to is intent-check.sh's ATTRIBUTION, walked
#   the way that parser walks it — the open entry when one is open, otherwise the
#   RETRACTION target it kept from the last entry that vetted ACTIVE — and NOT the nearest
#   preceding bullet. Where the two readings differ, the action is REFUSED: the attribution
#   is decided by guard results only the parser can evaluate, and the two readings want
#   opposite edits. Every sweep NOTE states the attachment the PARSER made, so a transcript
#   sends whoever restores the line to the entry that really lost it.
#   WHY: two column-0 orphans in a row are attributed to DIFFERENT entries — the first to
#   the entry still open above it (which it excludes), the second to the entry BEFORE that
#   one (which it RETRACTS out of the active view, the entry above it being excluded
#   already). Reading both as the nearest bullet's made them both the matched entry's, so a
#   retire/update of that entry DELETED the bystander's effective guard and flipped it from
#   UNPARSEABLE (excluded, steering nothing) to ACTIVE — the cross-entry fail-OPEN, reached
#   through the second orphan of a run — while the sweep NOTE named the wrong entry, sending
#   the restore to a bullet the line was never attached to.
PI=$SANDBOX/pi-retract
for v in retire update note; do mkdir -p "$PI/$v"; done
for v in retire update; do
  cat > "$PI/$v/intent.md" <<'EOF'
- 2026-01-01: entry ZERO — the bystander
- 2026-02-02: entry ONE — the matched entry
guard: test -e A_PRESENT
guard: test -e B_PRESENT
EOF
done

# GROUND TRUTH, from the parser of record — the two readings disagreeing IS the defect, so
# a hand-assumed verdict would only write the bug's own assumption down again.
PIR=$SANDBOX/pi-retract-before
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-retract-before.out" 2>/dev/null )
expect "promote-intent: GROUND TRUTH — the FIRST orphan excludes the entry open above it (ONE)" \
  grep -qxF -- '- 2026-02-02: entry ONE — the matched entry' "$PIR/intent-unparseable.md"
expect "promote-intent: GROUND TRUTH — the SECOND orphan retracts the BYSTANDER ZERO, not ONE" \
  grep -qxF -- '- 2026-01-01: entry ZERO — the bystander' "$PIR/intent-unparseable.md"
expect "promote-intent: so the fixture starts with NOTHING active" \
  grep -qx 'ACTIVE=0' "$SANDBOX/pi-retract-before.out"

# --- the RETIRE arm: refused, because taking the second orphan de-guards the bystander ---
INT="$PI/retire/intent.md"
cp "$INT" "$SANDBOX/pi-retract-retire.snap"
INTENT=$INT ACTION=retire MATCH='entry ONE — the matched entry' \
  bash "$PIS" > "$SANDBOX/pi-retract-retire.out" 2> "$SANDBOX/pi-retract-retire.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: a retire whose second orphan the parser attached elsewhere is REFUSED"; else fail "promote-intent: a retire whose second orphan the parser attached elsewhere is REFUSED (rc=$rc, said '$(cat "$SANDBOX/pi-retract-retire.out")')"; fi
expect "promote-intent: the refusal names the LINE it will not decide about, and its assertion" \
  bash -c "grep -qF 'line 4' '$SANDBOX/pi-retract-retire.err' && grep -qF 'test -e B_PRESENT' '$SANDBOX/pi-retract-retire.err'"
expect "promote-intent: and names the OTHER entry intent-check.sh attached it to" \
  grep -qF 'entry ZERO — the bystander' "$SANDBOX/pi-retract-retire.err"
expect "promote-intent: the refused retire wrote nothing" \
  cmp -s "$SANDBOX/pi-retract-retire.snap" "$INT"
PIR=$SANDBOX/pi-retract-retire-run
( cd "$PI/retire" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-retract-retire-ics.out" 2>/dev/null )
# The load-bearing assertion: the nearest-bullet reading swept BOTH lines here, and the
# bystander — excluded only because the second one retracted it — rode into the active view.
expect "promote-intent: the bystander is STILL excluded (it was never promoted)" \
  grep -qxF -- '- 2026-01-01: entry ZERO — the bystander' "$PIR/intent-unparseable.md"
refute "promote-intent: and it steers nothing — it is NOT in intent-active.md" \
  grep -qF 'entry ZERO' "$PIR/intent-active.md"

# --- the UPDATE arm: the same shape, refused for the same reason -------------------------
INT="$PI/update/intent.md"
cp "$INT" "$SANDBOX/pi-retract-update.snap"
INTENT=$INT ACTION=update MATCH='entry ONE — the matched entry' \
  ENTRY='entry ONE — re-confirmed' DATE=2026-08-12 \
  bash "$PIS" > "$SANDBOX/pi-retract-update.out" 2> "$SANDBOX/pi-retract-update.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: the update over the same run of orphans is REFUSED too"; else fail "promote-intent: the update over the same run of orphans is REFUSED too (rc=$rc, said '$(cat "$SANDBOX/pi-retract-update.out")')"; fi
expect "promote-intent: that refusal names the line and the entry as well" \
  bash -c "grep -qF 'line 4' '$SANDBOX/pi-retract-update.err' && grep -qF 'entry ZERO — the bystander' '$SANDBOX/pi-retract-update.err'"
expect "promote-intent: the refused update wrote nothing" \
  cmp -s "$SANDBOX/pi-retract-update.snap" "$INT"
PIR=$SANDBOX/pi-retract-update-run
( cd "$PI/update" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-retract-update-ics.out" 2>/dev/null )
# The adoption path read both orphans as the matched entry's, so the second one MOVED onto
# the matched entry and the bystander went ACTIVE with the assertion that excluded it gone.
refute "promote-intent: the bystander did NOT ride into the active view de-guarded" \
  grep -qF 'entry ZERO' "$PIR/intent-active.md"
expect "promote-intent: nothing is active after the refusal — the file is as it was" \
  grep -qx 'ACTIVE=0' "$SANDBOX/pi-retract-update-ics.out"

# --- the NOTE states the PARSER's attachment, including "no entry at all" ----------------
# Both orphans here are the matched entry's OWN run — the first is attributed to it, the
# second to NO entry (the first already excluded it, so there was nothing left to retract) —
# so the caller may sweep both. What the NOTE must not do is claim the parser attached the
# second one to the entry: whoever restores it would put it back under a bullet the parser
# never read it against.
cat > "$PI/note/intent.md" <<'EOF'
- 2026-02-02: the only entry
guard: test -e A_MISSING
guard: test -e B_MISSING
EOF
PIR=$SANDBOX/pi-retract-note-before
( cd "$PI/note" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-retract-note-before.out" 2>/dev/null )
expect "promote-intent: GROUND TRUTH — the entry is excluded ONCE, by the first orphan" \
  bash -c "test \"\$(grep -cxF -- '- 2026-02-02: the only entry' '$PIR/intent-unparseable.md')\" = 1"
expect "promote-intent: GROUND TRUTH — the second orphan is reported ALONE (it retracted nothing)" \
  grep -qx 'UNPARSEABLE=3' "$SANDBOX/pi-retract-note-before.out"
INT="$PI/note/intent.md"
INTENT=$INT ACTION=update MATCH='the only entry' ENTRY='the only entry' DROP_GUARD=1 \
  DATE=2026-08-12 bash "$PIS" >/dev/null 2> "$SANDBOX/pi-retract-note.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "promote-intent: sweeping a run of the matched entry's own orphans exits 0"; else fail "promote-intent: sweeping a run of the matched entry's own orphans exits 0 (rc=$rc)"; fi
refute "promote-intent: both lines of the run really went" grep -qE '^guard:' "$INT"
grep -F 'test -e A_MISSING' "$SANDBOX/pi-retract-note.err" > "$SANDBOX/pi-retract-note-first.txt" || true
grep -F 'test -e B_MISSING' "$SANDBOX/pi-retract-note.err" > "$SANDBOX/pi-retract-note-second.txt" || true
expect "promote-intent: the FIRST line's NOTE names the entry the parser attached it to" \
  grep -qF "attaches it to the entry '- 2026-02-02: the only entry'" "$SANDBOX/pi-retract-note-first.txt"
refute "promote-intent: the SECOND line's NOTE does NOT claim an attachment the parser never made" \
  grep -qF 'attaches it to the entry' "$SANDBOX/pi-retract-note-second.txt"
expect "promote-intent: it says the parser attributed that line to NO entry" \
  grep -qiF 'no entry' "$SANDBOX/pi-retract-note-second.txt"
expect "promote-intent: and still names the entry whose run it sat in, so it can be put back" \
  grep -qF -- '- 2026-02-02: the only entry' "$SANDBOX/pi-retract-note-second.txt"

fi

if t "promote-intent.sh — a flag the ACTION cannot express is refused, not silently ignored"; then
# This block PINS the interface:
#   DROP_GUARD on an `append`, and GUARD on a `retire`, are REFUSED (exit 2, nothing
#   written). Neither action can express either flag — append writes the guard it was
#   given and has nothing to drop; retire deletes the entry and everything under it — so a
#   caller who passed one stated an intent the run did not carry out, and was told
#   "appended"/"retired" as though it had. Same answer this writer already gives the
#   GUARD-with-DROP_GUARD=1 contradiction: refuse the pair whole rather than pick.
PI=$SANDBOX/pi-unexpressible
for v in append retire ok; do mkdir -p "$PI/$v"; done
for v in append retire ok; do
  printf -- '- 2026-01-01: a fact\n  guard: test -f intent.md\n' > "$PI/$v/intent.md"
done

INT="$PI/append/intent.md"
cp "$INT" "$SANDBOX/pi-unexpressible-append.snap"
INTENT=$INT ENTRY='a brand new fact' DROP_GUARD=1 DATE=2026-08-12 \
  bash "$PIS" > "$SANDBOX/pi-unexp-append.out" 2> "$SANDBOX/pi-unexp-append.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: DROP_GUARD on an append is refused"; else fail "promote-intent: DROP_GUARD on an append is refused (rc=$rc, said '$(cat "$SANDBOX/pi-unexp-append.out")')"; fi
expect "promote-intent: the refusal names the flag and the action that cannot express it" \
  bash -c "grep -qF 'DROP_GUARD' '$SANDBOX/pi-unexp-append.err' && grep -qF 'append' '$SANDBOX/pi-unexp-append.err'"
expect "promote-intent: and nothing was appended" \
  cmp -s "$SANDBOX/pi-unexpressible-append.snap" "$INT"

INT="$PI/retire/intent.md"
cp "$INT" "$SANDBOX/pi-unexpressible-retire.snap"
INTENT=$INT ACTION=retire MATCH='a fact' GUARD='test -e go.mod' \
  bash "$PIS" > "$SANDBOX/pi-unexp-retire.out" 2> "$SANDBOX/pi-unexp-retire.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: GUARD on a retire is refused"; else fail "promote-intent: GUARD on a retire is refused (rc=$rc, said '$(cat "$SANDBOX/pi-unexp-retire.out")')"; fi
expect "promote-intent: that refusal names the flag and the action too" \
  bash -c "grep -qF 'GUARD' '$SANDBOX/pi-unexp-retire.err' && grep -qF 'retire' '$SANDBOX/pi-unexp-retire.err'"
expect "promote-intent: and the entry is still there — nothing was retired" \
  cmp -s "$SANDBOX/pi-unexpressible-retire.snap" "$INT"

# DROP_GUARD=0 is the KEEP spelling and states nothing an append contradicts, so it is not
# the refusal: only a flag the action cannot carry out is.
INT="$PI/ok/intent.md"
INTENT=$INT ENTRY='a brand new fact' DROP_GUARD=0 DATE=2026-08-12 \
  bash "$PIS" > "$SANDBOX/pi-unexp-ok.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-unexp-ok.out")" = appended ]]; then
  pass "promote-intent: DROP_GUARD=0 on an append is not the refusal"
else
  fail "promote-intent: DROP_GUARD=0 on an append is not the refusal (rc=$rc, said '$(cat "$SANDBOX/pi-unexp-ok.out")')"
fi

fi

if t "promote-intent.sh — a DATE outside the reader's YYYY-MM-DD shape is refused, not written"; then
# This block PINS the interface:
#   DATE must be exactly `YYYY-MM-DD` (four digits, two, two, dash-separated) once the
#   default is applied. Any other spelling is a REFUSAL (exit 2, naming the value and the
#   shape, nothing written); an explicit well-formed date and an unset DATE both still work.
#   WHY: the date is the one field the READER parses back out of the bullet, and on that
#   side the shape is LITERAL — fact_lines, and intent-check.sh's own fact lookup, find the
#   fact only PAST a `YYYY-MM-DD: ` prefix. Accepting any string wrote a bullet and exited 0
#   saying "appended", after which NOTHING could name the fact: retire and update answered
#   "no entry carries the fact" about a line that plainly reads like one, and append's dedup
#   — blind in exactly the same way — stacked a SECOND visually identical entry the next
#   time the fact was promoted, the permanent ambiguity find_entry then refuses forever.
#   intent-check.sh meanwhile reads the line as a perfectly parseable ACTIVE entry (the date
#   is not part of its ENTRY grammar), so no quarantine and no Phase 5 re-confirm ever
#   surfaced it, and the one sanctioned hand edit — scoped to a line reported UNPARSEABLE —
#   did not cover it either: a committed ledger poisoned in a shape only a hand edit could
#   reach. The refusal has to fire before any write, so it costs the file nothing.
PI=$SANDBOX/pi-date-shape
for v in refuse fresh explicit default legacy; do mkdir -p "$PI/$v"; done
for v in refuse explicit default legacy; do
  printf -- '- 2026-01-01: a recorded fact\n  guard: test -f intent.md\n' > "$PI/$v/intent.md"
done

# GROUND TRUTH, from the parser of record and from this writer's own lookup: a bullet dated
# `2026-8-1` (as a hand edit or a pre-fix run left it) hides in plain sight — the parser
# calls the file well-formed and the entry ACTIVE, while MATCH cannot name the fact at all,
# so no action of this writer's can ever repair it. That is what the refusal prevents.
printf -- '- 2026-8-1: a legacy fact nothing can name\n' >> "$PI/legacy/intent.md"
PIR=$SANDBOX/pi-date-legacy-run
( cd "$PI/legacy" && RUN=$PIR INTENT=intent.md bash "$ICS" > "$SANDBOX/pi-date-legacy.out" 2>/dev/null )
expect "promote-intent: intent-check.sh reports a malformed-date bullet as a parseable ACTIVE entry" \
  grep -qx 'ACTIVE=2' "$SANDBOX/pi-date-legacy.out"
expect "promote-intent: so the quarantine loop never reports it unparseable — nothing surfaces it" \
  grep -qx 'UNPARSEABLE=0' "$SANDBOX/pi-date-legacy.out"
INTENT=$PI/legacy/intent.md ACTION=retire MATCH='a legacy fact nothing can name' \
  bash "$PIS" >/dev/null 2> "$SANDBOX/pi-date-legacy.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: and MATCH cannot name that fact — the entry is unreachable by its own writer"; else fail "promote-intent: and MATCH cannot name that fact — the entry is unreachable by its own writer (rc=$rc)"; fi
expect "promote-intent: the lookup answers 'no entry carries the fact' about a line that reads like one" \
  grep -qF 'no entry in' "$SANDBOX/pi-date-legacy.err"

# --- the REFUSAL: exit 2, the value and the shape named, and not one byte written --------
INT="$PI/refuse/intent.md"
cp "$INT" "$SANDBOX/pi-date-shape.snap"
INTENT=$INT ENTRY='a brand new fact' DATE=2026-8-1 \
  bash "$PIS" > "$SANDBOX/pi-date-refuse.out" 2> "$SANDBOX/pi-date-refuse.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: DATE=2026-8-1 is refused"; else fail "promote-intent: DATE=2026-8-1 is refused (rc=$rc, said '$(cat "$SANDBOX/pi-date-refuse.out")')"; fi
expect "promote-intent: the refusal names the value it will not write" \
  grep -qF "'2026-8-1'" "$SANDBOX/pi-date-refuse.err"
expect "promote-intent: and names the shape the reader requires" \
  grep -qF 'YYYY-MM-DD' "$SANDBOX/pi-date-refuse.err"
expect "promote-intent: the refused append wrote nothing" cmp -s "$SANDBOX/pi-date-shape.snap" "$INT"
refute "promote-intent: no malformed bullet reached the committed ledger" grep -q '2026-8-1' "$INT"
# Every other spelling the reader cannot read is refused for the same reason — including a
# two-digit year and a single-digit day, which look like dates to a human and to nothing else.
for bad in 26-08-01 2026-08-1 2026-8-01 08-01-2026 20260801 today; do
  INTENT=$INT ENTRY='a brand new fact' DATE="$bad" bash "$PIS" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "promote-intent: DATE='$bad' is refused too"; else fail "promote-intent: DATE='$bad' is refused too (rc=$rc)"; fi
done
expect "promote-intent: and none of those refusals touched the file" cmp -s "$SANDBOX/pi-date-shape.snap" "$INT"
# The refusal fires before the file is even created, so it cannot leave a stub behind.
INTENT=$PI/fresh/intent.md ENTRY='a brand new fact' DATE=2026-8-1 bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: the refusal fires on a file that does not exist yet"; else fail "promote-intent: the refusal fires on a file that does not exist yet (rc=$rc)"; fi
refute "promote-intent: and no intent file was created by it" test -e "$PI/fresh/intent.md"
# A retire ignores DATE entirely, and is refused on the same malformed value rather than
# running with a value the caller clearly did not mean.
INTENT=$INT ACTION=retire MATCH='a recorded fact' DATE=2026-8-1 bash "$PIS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: a malformed DATE is refused whatever the ACTION"; else fail "promote-intent: a malformed DATE is refused whatever the ACTION (rc=$rc)"; fi
expect "promote-intent: and that refusal retired nothing" cmp -s "$SANDBOX/pi-date-shape.snap" "$INT"

# --- an EXPLICIT well-formed DATE still writes, and stays reachable ----------------------
INT="$PI/explicit/intent.md"
INTENT=$INT ENTRY='a brand new fact' DATE=2026-08-01 \
  bash "$PIS" > "$SANDBOX/pi-date-ok.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-date-ok.out")" = appended ]]; then
  pass "promote-intent: a zero-padded explicit DATE is still accepted"
else
  fail "promote-intent: a zero-padded explicit DATE is still accepted (rc=$rc, said '$(cat "$SANDBOX/pi-date-ok.out")')"
fi
expect "promote-intent: with the bullet dated exactly as it was given" \
  grep -qx -- '- 2026-08-01: a brand new fact' "$INT"
INTENT=$INT ENTRY='a brand new fact' DATE=2026-09-02 \
  bash "$PIS" > "$SANDBOX/pi-date-dedup.out" 2>/dev/null
if [[ "$(cat "$SANDBOX/pi-date-dedup.out")" = unchanged ]]; then
  pass "promote-intent: and the dedup can see it — a re-append is 'unchanged', not a duplicate"
else
  fail "promote-intent: and the dedup can see it — a re-append is 'unchanged', not a duplicate (said '$(cat "$SANDBOX/pi-date-dedup.out")')"
fi
INTENT=$INT ACTION=retire MATCH='a brand new fact' \
  bash "$PIS" > "$SANDBOX/pi-date-retire.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-date-retire.out")" = retired ]]; then
  pass "promote-intent: and MATCH can name it — the fact is reachable by its own writer"
else
  fail "promote-intent: and MATCH can name it — the fact is reachable by its own writer (rc=$rc, said '$(cat "$SANDBOX/pi-date-retire.out")')"
fi

# --- the DEFAULT (DATE unset) still works, and satisfies the shape it is checked against --
INT="$PI/default/intent.md"
TODAY=$(date -u +%Y-%m-%d)
( unset DATE; INTENT=$INT ENTRY='a fact dated by default' bash "$PIS" ) \
  > "$SANDBOX/pi-date-default.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-date-default.out")" = appended ]]; then
  pass "promote-intent: an unset DATE still defaults to today (UTC) and appends"
else
  fail "promote-intent: an unset DATE still defaults to today (UTC) and appends (rc=$rc, said '$(cat "$SANDBOX/pi-date-default.out")')"
fi
expect "promote-intent: the defaulted bullet carries today's UTC date in the reader's shape" \
  grep -qx -- "- $TODAY: a fact dated by default" "$INT"
( unset DATE; INTENT=$INT ACTION=retire MATCH='a fact dated by default' bash "$PIS" ) \
  > "$SANDBOX/pi-date-default-retire.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-date-default-retire.out")" = retired ]]; then
  pass "promote-intent: and a defaulted-date entry is reachable by MATCH too"
else
  fail "promote-intent: and a defaulted-date entry is reachable by MATCH too (rc=$rc, said '$(cat "$SANDBOX/pi-date-default-retire.out")')"
fi

fi

if t "promote-intent.sh update — landing ENTRY on a fact ANOTHER entry carries is refused (the dup door)"; then
# append refuses to record a fact twice (fact_lines dedup) — but update used to
# create the same duplicate past that door: MATCH resolves uniquely, ENTRY is
# never checked against the rest of the file, and after the rewrite two entries
# carry one fact. That poisons the fact PERMANENTLY: find_entry refuses
# ambiguity, so update, retire and append all exit 2 on it from then on, and the
# file parses cleanly so the sanctioned hand-edit exception does not apply.
# Reachable straight from Phase 5's re-confirm when canonicalizing two
# near-identical facts into one wording.
PDU=$SANDBOX/pi-dup-update
mkdir -p "$PDU"
INT="$PDU/intent.md"
printf -- '- 2026-01-01: web/ is deliberately absent\n- 2026-01-02: the web UI was removed by the team\n' > "$INT"
cp "$INT" "$SANDBOX/pi-dup.snap"
INTENT=$INT ACTION=update MATCH='the web UI was removed by the team' \
  ENTRY='web/ is deliberately absent' \
  bash "$PIS" > "$SANDBOX/pi-dup.out" 2> "$SANDBOX/pi-dup.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: an update that would duplicate another entry's fact is refused"; else fail "promote-intent: an update that would duplicate another entry's fact is refused (rc=$rc, said '$(cat "$SANDBOX/pi-dup.out")')"; fi
expect "promote-intent: the refusal names the other entry carrying the fact" \
  grep -q 'already carries the new fact on another entry' "$SANDBOX/pi-dup.err"
expect "promote-intent: not one byte was rewritten on the refusal" \
  cmp -s "$INT" "$SANDBOX/pi-dup.snap"
# The re-affirm case stays allowed: ENTRY == MATCH hits only the matched entry
# itself, and refreshing the date is exactly what ACTION=update is for.
INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ is deliberately absent' \
  bash "$PIS" > "$SANDBOX/pi-dup-reaffirm.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-dup-reaffirm.out")" = updated ]]; then
  pass "promote-intent: re-affirming an entry with its own fact still updates"
else
  fail "promote-intent: re-affirming an entry with its own fact still updates (rc=$rc, said '$(cat "$SANDBOX/pi-dup-reaffirm.out")')"
fi
fi

if t "promote-intent.sh — the forgot-the-indent shape is a REFUSAL for append and the keep-path update"; then
# An entry that OWNS an orphaned `guard:` (column-0, under its bullet) is one
# intent-check.sh reports UNPARSEABLE — the fact is recorded and vets nothing.
# Two doors used to read that shape wrong:
#   append — its dedup walked only the entry's EXTENT, so the orphan was
#   invisible: "unchanged" (exit 0) for a fact whose entry steers nothing, and
#   with GUARD set the conflict message quoted the recorded guard as '<none>',
#   sending the caller to the wrong repair.
#   update, keep path — an entry with a STATED indented guard AND an orphaned
#   bare `guard:` sailed past the adoption block's empty-assertion check: the
#   sweep took the orphan, the NOTE quoted an empty assertion (unrestorable),
#   and the entry left the unparseable bucket vetted only by the guards that
#   happened to be indented.
PFI=$SANDBOX/pi-forgot-indent
mkdir -p "$PFI"
# --- append on an entry owning an orphaned (stated) guard ---------------------
INT="$PFI/append.md"
printf -- '- 2026-01-01: the event handler is unused\nguard: test -e internal/event-handler\n' > "$INT"
cp "$INT" "$SANDBOX/pi-fi-append.snap"
INTENT=$INT ENTRY='the event handler is unused' \
  bash "$PIS" > "$SANDBOX/pi-fi-append.out" 2> "$SANDBOX/pi-fi-append.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: append on a fact whose entry owns an orphaned guard is refused, never 'unchanged'"; else fail "promote-intent: append on a fact whose entry owns an orphaned guard is refused, never 'unchanged' (rc=$rc, said '$(cat "$SANDBOX/pi-fi-append.out")')"; fi
expect "promote-intent: the refusal names the orphan and routes to ACTION=update" \
  bash -c "grep -q 'orphaned' '$SANDBOX/pi-fi-append.err' && grep -q 'ACTION=update' '$SANDBOX/pi-fi-append.err'"
expect "promote-intent: nothing was written on the append refusal" \
  cmp -s "$INT" "$SANDBOX/pi-fi-append.snap"
# --- keep-path update on an entry with a stated guard AND a bare orphan -------
INT="$PFI/keep.md"
printf -- '- 2026-01-02: web/ is deliberately absent\n  guard: test ! -e web\nguard:\n' > "$INT"
cp "$INT" "$SANDBOX/pi-fi-keep.snap"
INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ is deliberately absent' \
  bash "$PIS" > "$SANDBOX/pi-fi-keep.out" 2> "$SANDBOX/pi-fi-keep.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: the keep path refuses to sweep an orphan stating no assertion"; else fail "promote-intent: the keep path refuses to sweep an orphan stating no assertion (rc=$rc, said '$(cat "$SANDBOX/pi-fi-keep.out")')"; fi
expect "promote-intent: the refusal names the repair (GUARD= or DROP_GUARD=1)" \
  bash -c "grep -q 'GUARD=' '$SANDBOX/pi-fi-keep.err' && grep -q 'DROP_GUARD=1' '$SANDBOX/pi-fi-keep.err'"
expect "promote-intent: nothing was written on the keep-path refusal" \
  cmp -s "$INT" "$SANDBOX/pi-fi-keep.snap"
# The stated-intent ways through still work: GUARD= replaces the set (orphan
# swept with a NOTE), and on a guardless entry the orphans are ADOPTED back.
INTENT=$INT ACTION=update MATCH='web/ is deliberately absent' \
  ENTRY='web/ is deliberately absent' GUARD='test ! -e web' \
  bash "$PIS" > "$SANDBOX/pi-fi-repair.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(cat "$SANDBOX/pi-fi-repair.out")" = updated ]]; then
  pass "promote-intent: an explicit GUARD= still repairs the same entry"
else
  fail "promote-intent: an explicit GUARD= still repairs the same entry (rc=$rc, said '$(cat "$SANDBOX/pi-fi-repair.out")')"
fi
refute "promote-intent: the bare orphan is gone after the stated repair" \
  grep -qx 'guard:' "$INT"
fi

if t "promote-intent.sh — retire and update preserve the committed file's mode (never drop to 0600)"; then
# This block PINS the interface:
#   retire/update rewrite through mktemp+mv. mktemp forces 0600, and a bare mv would stamp
#   that private mode onto .kairos/intent.md — a COMMITTED file that travels in git and is
#   read by every shared checkout and CI job. install() carries the existing file's OWN mode
#   across before the mv (there is no `chmod --reference` on macOS), so a 0644 ledger stays
#   0644 and a genuinely private 0600 one is left 0600 rather than widened.
# GNU `stat -c` FIRST, then BSD `stat -f` — mirror the scripts' order. On GNU/Linux
# `stat -f` means --file-system and would return a filesystem dump, not the mode.
fmode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
PI=$SANDBOX/pi-mode
mkdir -p "$PI"

INT="$PI/update.md"
printf -- '- 2026-08-01: a fact to update\n  guard: test -e go.mod\n' > "$INT"
chmod 644 "$INT"
INTENT=$INT ACTION=update MATCH='a fact to update' ENTRY='a fact to update' \
  GUARD='test -e README.md' DATE=2026-08-12 bash "$PIS" >/dev/null 2>&1
if [[ "$(fmode "$INT")" = 644 ]]; then pass "promote-intent: an update leaves a 0644 ledger at 0644 (not 0600)"; else fail "promote-intent: an update leaves a 0644 ledger at 0644 (got $(fmode "$INT"))"; fi

INT="$PI/retire.md"
printf -- '- 2026-08-01: fact one\n- 2026-08-02: fact two\n' > "$INT"
chmod 644 "$INT"
INTENT=$INT ACTION=retire MATCH='fact one' bash "$PIS" >/dev/null 2>&1
if [[ "$(fmode "$INT")" = 644 ]]; then pass "promote-intent: a retire leaves a 0644 ledger at 0644 (not 0600)"; else fail "promote-intent: a retire leaves a 0644 ledger at 0644 (got $(fmode "$INT"))"; fi

INT="$PI/private.md"
printf -- '- 2026-08-01: fact one\n- 2026-08-02: fact two\n' > "$INT"
chmod 600 "$INT"
INTENT=$INT ACTION=retire MATCH='fact one' bash "$PIS" >/dev/null 2>&1
if [[ "$(fmode "$INT")" = 600 ]]; then pass "promote-intent: a private 0600 ledger stays 0600 (its own mode carried, not clobbered to 0644)"; else fail "promote-intent: a private 0600 ledger stays 0600 (got $(fmode "$INT"))"; fi
fi

if t "promote-intent.sh append — a fact on an entry owning a RUNTIME-verdict orphan is refused with the re-indent message, not the ACTION=update loop"; then
# This block PINS the interface:
#   when append finds the fact already recorded on an entry whose orphaned `guard:` the
#   parser attributes at RUNTIME (the SECOND orphan of a run reaches PAST the entry above it
#   to an earlier one), the generic "repair with ACTION=update" advice is WRONG:
#   require_attributable refuses a runtime row on that very path, so following the advice
#   loops. The append path now intercepts the runtime row with the same message
#   require_attributable gives — re-indent the line, or settle that entry first — a repair
#   that actually terminates.
PI=$SANDBOX/pi-append-runtime
mkdir -p "$PI"
INT="$PI/intent.md"
cat > "$INT" <<'EOF'
- 2026-01-01: entry ZERO
- 2026-02-02: entry ONE
guard: test -e A
guard: test -e B
EOF
INTENT=$INT ACTION=append ENTRY='entry ONE' DATE=2026-02-02 \
  bash "$PIS" > "$SANDBOX/pi-ar.out" 2> "$SANDBOX/pi-ar.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "promote-intent: the append is refused (the fact is already recorded on a broken entry)"; else fail "promote-intent: the append is refused (rc=$rc, said '$(cat "$SANDBOX/pi-ar.out")')"; fi
expect "promote-intent: the refusal names the RUNTIME line and its assertion (line 4 / test -e B)" \
  bash -c "grep -qF 'line 4' '$SANDBOX/pi-ar.err' && grep -qF 'test -e B' '$SANDBOX/pi-ar.err'"
expect "promote-intent: it tells the caller to re-indent / settle the entry (a repair that terminates)" \
  grep -qi 'Re-indent that line' "$SANDBOX/pi-ar.err"
refute "promote-intent: it does NOT send the caller round the ACTION=update refusal loop" \
  grep -qF 'Repair that entry with ACTION=update' "$SANDBOX/pi-ar.err"
expect "promote-intent: the refused append wrote nothing new (still two bullets)" \
  bash -c "test \"\$(grep -c '^- ' '$INT')\" -eq 2"
fi

finish_suite
