#!/usr/bin/env bash
# next-upgrade-file.test.sh — tests for scripts/next-upgrade-file.sh
# TEST_FILTER refused (single sequential fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in next-upgrade-file.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "next-upgrade-file.sh serves a caller-named slug (stateless)"; then
UFS=$SANDBOX/upgrade-server
mkdir -p "$UFS/upgrades"
cat > "$UFS/list.txt" <<'EOF'
.kairos-updates/20260101T000000-alpha.md
.kairos-updates/20260102T000000-beta.md
.kairos-updates/20260103T000000-gamma.md
EOF
printf '# Alpha\n\nintent: first\nbody-alpha\n' > "$UFS/upgrades/20260101T000000-alpha.md"
printf '# Beta\n\nintent: second\nbody-beta\n'  > "$UFS/upgrades/20260102T000000-beta.md"
printf '# Gamma\n\nintent: third\nbody-gamma\n' > "$UFS/upgrades/20260103T000000-gamma.md"

serve_slug() {
  RUN=$UFS LIST=$UFS/list.txt SLUG="$1" "$SKILL_DIR/scripts/next-upgrade-file.sh"
}

OUT1=$(serve_slug 20260101T000000-alpha); RC1=$?
expect "named slug exits 0" test "$RC1" -eq 0
expect "named slug prints SLUG line" bash -c "echo \"$OUT1\" | grep -qx 'SLUG: 20260101T000000-alpha'"
expect "named slug serves only that body" bash -c "echo \"$OUT1\" | grep -q body-alpha"
refute "named slug does not also serve beta" bash -c "echo \"$OUT1\" | grep -q body-beta"

OUT2=$(serve_slug 20260101T000000-alpha)
expect "re-requesting the same slug is idempotent" bash -c "echo \"$OUT2\" | grep -q body-alpha"

OUT3=$(serve_slug 20260102T000000-beta)
expect "a different slug serves independently" bash -c "echo \"$OUT3\" | grep -q body-beta"

# EXIT CODES ARE THE CONTRACT, one per cause. A single overloaded 2 meant the
# caller could not tell "you asked for a slug that is not in scope" from "the
# body was never captured" from "the capture FAILED" — three different remedies,
# and the last one is the only one a re-run cannot fix. reference/upgrade-files.md
# carries the table.
serve_slug not-in-list > "$SANDBOX/ufs-bad.out" 2> "$SANDBOX/ufs-bad.log"
UFS_BAD_RC=$?
if [[ "$UFS_BAD_RC" -eq 3 ]]; then pass "a slug outside LIST exits 3 (out of scope)"; else fail "out-of-scope slug exited $UFS_BAD_RC (want 3)"; fi
refute "unknown slug does not print a body to stdout" grep -q 'body-' "$SANDBOX/ufs-bad.out"
refute "stateless server leaves no cursor file" test -f "$UFS/list.txt.cursor"

UFS_MISS=$SANDBOX/upgrade-server-miss
mkdir -p "$UFS_MISS/upgrades"
printf '.kairos-updates/20260101T000000-alpha.md\n' > "$UFS_MISS/list.txt"
RUN=$UFS_MISS LIST=$UFS_MISS/list.txt SLUG=20260101T000000-alpha \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > "$SANDBOX/ufs-miss.out" 2> "$SANDBOX/ufs-miss.log"
UFS_MISS_RC=$?
if [[ "$UFS_MISS_RC" -eq 4 ]]; then pass "an in-scope slug with no snapshot on disk exits 4"; else fail "missing snapshot exited $UFS_MISS_RC (want 4)"; fi
refute "the never-snapshotted message does not blame a FAILED read (a different cause, exit 5)" \
  grep -qiE 'could not be captured|refus' "$SANDBOX/ufs-miss.log"
expect "the never-snapshotted message names the phase to re-run" \
  grep -qi 'collecting phase\|Phase 3' "$SANDBOX/ufs-miss.log"

# LIST= is generic by design; a common-upgrades-modified.txt is served exactly
# like any other list (in-scope) and rejects a slug that belongs to a different
# list (out-of-scope) — a dedicated assertion so a future refactor of the
# accepted LIST values can't silently narrow it.
cat > "$UFS/common-upgrades-modified.txt" <<'EOF'
.kairos-updates/api/20260104T000000-delta.md
EOF
printf '# Delta\n\nintent: fourth\nbody-delta\n' > "$UFS/upgrades/20260104T000000-delta.md"
OUT4=$(RUN=$UFS LIST=$UFS/common-upgrades-modified.txt SLUG=20260104T000000-delta "$SKILL_DIR/scripts/next-upgrade-file.sh")
expect "next-upgrade-file.sh serves a slug in-scope for a common-modified LIST" \
  bash -c "echo \"$OUT4\" | grep -q body-delta"
RUN=$UFS LIST=$UFS/common-upgrades-modified.txt SLUG=20260101T000000-alpha \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > "$SANDBOX/ufs-modlist-oos.out" 2> "$SANDBOX/ufs-modlist-oos.log"
UFS_MODLIST_RC=$?
if [[ "$UFS_MODLIST_RC" -eq 3 ]]; then pass "a slug from the added list is out-of-scope for LIST=common-upgrades-modified.txt (exit 3)"; else fail "out-of-scope-for-modified-list exited $UFS_MODLIST_RC (want 3)"; fi

# A ZERO-BYTE snapshot is a LEGITIMATE upgrade-file, served with rc 0 — this
# assertion set replaces one that pinned the opposite. The producers used to
# conflate "git show failed" with "git show succeeded and the file is empty",
# refusing both; the read end then refused the survivor too. Net effect: a
# genuinely empty upgrade-file committed in the template could never be migrated
# past — WARN forever, the slug stays in upgrades-added.txt, the planner cannot
# fetch it, plan-completeness blocks on it, and every doc said re-run the phase,
# which reproduces it. The producers now distinguish the two cases by `git show`'s
# EXIT STATUS, so a 0-byte snapshot on disk means "0 bytes as committed" and the
# only correct answer is to serve it with the emptiness stated.
UFS_EMPTY=$SANDBOX/upgrade-server-empty
mkdir -p "$UFS_EMPTY/upgrades"
printf '.kairos-updates/20260101T000000-alpha.md\n' > "$UFS_EMPTY/list.txt"
: > "$UFS_EMPTY/upgrades/20260101T000000-alpha.md"
RUN=$UFS_EMPTY LIST=$UFS_EMPTY/list.txt SLUG=20260101T000000-alpha \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > "$SANDBOX/ufs-empty.out" 2> "$SANDBOX/ufs-empty.log"
UFS_EMPTY_RC=$?
if [[ "$UFS_EMPTY_RC" -eq 0 ]]; then pass "a zero-byte snapshot is served (exit 0), not dead-ended"; else fail "a zero-byte snapshot exited $UFS_EMPTY_RC (want 0)"; fi
expect "the served empty body still carries its SLUG header" \
  grep -qx 'SLUG: 20260101T000000-alpha' "$SANDBOX/ufs-empty.out"
expect "the caller is TOLD the body is empty rather than left to infer it" \
  grep -q '^EMPTY:' "$SANDBOX/ufs-empty.out"

# The failure this used to be conflated with: the capture was REFUSED, recorded by
# the producer in $RUN/snapshot-refusals.tsv. Distinct exit code, and the recorded
# reason is relayed — re-running the phase reproduces it, so the caller has to know
# the difference.
UFS_REF=$SANDBOX/upgrade-server-refused
mkdir -p "$UFS_REF/upgrades"
printf '.kairos-updates/20260101T000000-alpha.md\n' > "$UFS_REF/list.txt"
printf '20260101T000000-alpha\t.kairos-updates/20260101T000000-alpha.md\tgit show failed (exit 128) — the body could not be read\n' \
  > "$UFS_REF/snapshot-refusals.tsv"
RUN=$UFS_REF LIST=$UFS_REF/list.txt SLUG=20260101T000000-alpha \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > "$SANDBOX/ufs-ref.out" 2> "$SANDBOX/ufs-ref.log"
UFS_REF_RC=$?
if [[ "$UFS_REF_RC" -eq 5 ]]; then pass "a refused capture exits 5, distinct from never-snapshotted"; else fail "a refused capture exited $UFS_REF_RC (want 5)"; fi
expect "the refusal relays the reason the producer recorded" \
  grep -q 'exit 128' "$SANDBOX/ufs-ref.log"
refute "a refused capture serves no body" grep -q '^SLUG:' "$SANDBOX/ufs-ref.out"

# A refused capture whose PREVIOUS good body is still on disk is still served —
# keeping the good snapshot is the whole point of the producer's refusal — but the
# caller is warned that the body predates this run's failed re-read.
UFS_STALE=$SANDBOX/upgrade-server-stale
mkdir -p "$UFS_STALE/upgrades"
printf '.kairos-updates/20260101T000000-alpha.md\n' > "$UFS_STALE/list.txt"
printf '# Alpha\n\nintent: first\nbody-alpha\n' > "$UFS_STALE/upgrades/20260101T000000-alpha.md"
printf '20260101T000000-alpha\t.kairos-updates/20260101T000000-alpha.md\tgit show failed (exit 128) — the body could not be read\n' \
  > "$UFS_STALE/snapshot-refusals.tsv"
RUN=$UFS_STALE LIST=$UFS_STALE/list.txt SLUG=20260101T000000-alpha \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > "$SANDBOX/ufs-stale.out" 2> "$SANDBOX/ufs-stale.log"
UFS_STALE_RC=$?
if [[ "$UFS_STALE_RC" -eq 0 ]]; then pass "a surviving good body is still served when this run's re-capture was refused"; else fail "a surviving good body exited $UFS_STALE_RC (want 0)"; fi
expect "the surviving body is the one served" grep -q body-alpha "$SANDBOX/ufs-stale.out"
expect "serving a survivor warns that the re-capture failed" \
  grep -qi 'refus\|failed' "$SANDBOX/ufs-stale.log"

# Bad input keeps exit 2 — it is the usage class, not a snapshot verdict.
RUN= LIST=$UFS/list.txt SLUG=20260101T000000-alpha \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > /dev/null 2> "$SANDBOX/ufs-norun.log"
if [[ $? -eq 2 ]]; then pass "an unset RUN is still the usage class (exit 2)"; else fail "an unset RUN did not exit 2"; fi
RUN=$UFS LIST=$UFS/nope.txt SLUG=x "$SKILL_DIR/scripts/next-upgrade-file.sh" > /dev/null 2> "$SANDBOX/ufs-nolist.log"
if [[ $? -eq 2 ]]; then pass "an absent LIST is still the usage class (exit 2)"; else fail "an absent LIST did not exit 2"; fi

# Regression: a LIST file whose final line has NO trailing newline must still
# have its last entry recognized as in-scope. `read` populates `entry` with
# that final line but returns exit 1 (EOF reached without a newline), so a bare
# `while IFS= read -r entry; do` drops the loop body for it entirely — the slug
# named on that line wrongly fell through to exit 3 "out of scope".
UFS_NOEOL=$SANDBOX/upgrade-server-noeol
mkdir -p "$UFS_NOEOL/upgrades"
printf '.kairos-updates/20260101T000000-alpha.md\n.kairos-updates/20260102T000000-noeol.md' \
  > "$UFS_NOEOL/list.txt"   # NO trailing newline after the last entry
printf '# NoEol\n\nintent: fifth\nbody-noeol\n' > "$UFS_NOEOL/upgrades/20260102T000000-noeol.md"
RUN=$UFS_NOEOL LIST=$UFS_NOEOL/list.txt SLUG=20260102T000000-noeol \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > "$SANDBOX/ufs-noeol.out" 2> "$SANDBOX/ufs-noeol.log"
UFS_NOEOL_RC=$?
if [[ "$UFS_NOEOL_RC" -eq 0 ]]; then pass "a slug on the unterminated final LIST line is found in-scope"; else fail "unterminated final LIST line exited $UFS_NOEOL_RC (want 0)"; fi
expect "the unterminated-line slug's body is served" grep -q body-noeol "$SANDBOX/ufs-noeol.out"

# An unset SLUG is the usage class too, its own guard (siblings RUN/LIST are
# covered above): the header promises exit 2 — never 3 (which would read as a
# real slug that is out of scope) — for every bad-input case, and SLUG has an
# explicit `[ -n ]` guard rather than `${SLUG:?}` (which would exit 1) precisely
# so this stays 2.
env -u SLUG RUN=$UFS LIST=$UFS/list.txt \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > /dev/null 2> "$SANDBOX/ufs-noslug.log"
if [[ $? -eq 2 ]]; then pass "an unset SLUG is the usage class (exit 2)"; else fail "an unset SLUG did not exit 2"; fi
expect "the unset-SLUG refusal names SLUG" grep -qF 'SLUG' "$SANDBOX/ufs-noslug.log"

# exit-4-vs-5 discrimination is keyed on the SLUG, not on the mere PRESENCE of a
# refusals file: a snapshot-refusals.tsv recording a refusal for slug alpha must
# NOT push a DIFFERENT in-scope, un-snapshotted slug (beta) onto exit 5 — beta was
# never refused, so it is a plain never-snapshotted (exit 4) and its message must
# not blame a failed read. This pins the `$1 == ENVIRON["S"]` slug join.
UFS_DISC=$SANDBOX/upgrade-server-disc
mkdir -p "$UFS_DISC/upgrades"
cat > "$UFS_DISC/list.txt" <<'EOF'
.kairos-updates/20260101T000000-alpha.md
.kairos-updates/20260102T000000-beta.md
EOF
printf '20260101T000000-alpha\t.kairos-updates/20260101T000000-alpha.md\tgit show failed (exit 128) — the body could not be read\n' \
  > "$UFS_DISC/snapshot-refusals.tsv"   # a refusal recorded for ALPHA only
RUN=$UFS_DISC LIST=$UFS_DISC/list.txt SLUG=20260102T000000-beta \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > "$SANDBOX/ufs-disc.out" 2> "$SANDBOX/ufs-disc.log"
UFS_DISC_RC=$?
if [[ "$UFS_DISC_RC" -eq 4 ]]; then pass "an un-snapshotted slug with a refusal recorded for a DIFFERENT slug exits 4, not 5"; else fail "different-slug refusal made beta exit $UFS_DISC_RC (want 4)"; fi
refute "beta's never-snapshotted message does not borrow alpha's failed-read blame" \
  grep -qiE 'could not be captured|refus|exit 128' "$SANDBOX/ufs-disc.log"
# The converse, on the SAME fixture: alpha (the refused slug) still exits 5, so the
# discrimination is a real per-slug join and not a blanket "no refusals file → 4".
RUN=$UFS_DISC LIST=$UFS_DISC/list.txt SLUG=20260101T000000-alpha \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > "$SANDBOX/ufs-disc-a.out" 2> "$SANDBOX/ufs-disc-a.log"
UFS_DISC_A_RC=$?
if [[ "$UFS_DISC_A_RC" -eq 5 ]]; then pass "the refused slug on the same fixture still exits 5"; else fail "the refused slug exited $UFS_DISC_A_RC (want 5)"; fi

fi

finish_suite
