#!/usr/bin/env bash
# suggest-branch.test.sh — tests for scripts/suggest-branch.sh
# TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite
PK_BRANCH=$(phase_key 4-migration-branch.md)

if t "suggest-branch.sh — phase-load guard"; then
HOME=$SANDBOX TARGET=0123456789abcdef "$SKILL_DIR/scripts/suggest-branch.sh" \
  > /dev/null 2> "$SANDBOX/sb-nokey.log"
SB_NOKEY_RC=$?
if [[ "$SB_NOKEY_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/4-migration-branch.md first' "$SANDBOX/sb-nokey.log"; then
  pass "without PHASE_KEY is refused: load phases/4-migration-branch.md first"
else
  fail "without PHASE_KEY is refused: load phases/4-migration-branch.md first (rc=$SB_NOKEY_RC)"
fi
HOME=$SANDBOX TARGET=0123456789abcdef PHASE_KEY=not-the-key "$SKILL_DIR/scripts/suggest-branch.sh" \
  > /dev/null 2> "$SANDBOX/sb-wrongkey.log"
SB_WRONG_RC=$?
if [[ "$SB_WRONG_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/4-migration-branch.md first' "$SANDBOX/sb-wrongkey.log"; then
  pass "with a wrong PHASE_KEY is refused: load phases/4-migration-branch.md first"
else
  fail "with a wrong PHASE_KEY is refused: load phases/4-migration-branch.md first (rc=$SB_WRONG_RC)"
fi
fi

if t "suggest-branch.sh — username derivation chain"; then
mkdir -p "$SANDBOX/homes/alice"
SB=$(HOME=$SANDBOX/homes/alice TARGET=0123456789abcdef PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/suggest-branch.sh")
if [[ "$SB" = "topic/alice/template-update-0123456" ]]; then
  pass "suggestion derives from \$HOME basename and the short target SHA"
else
  fail "suggestion derives from \$HOME basename (got '$SB')"
fi
SB_LOGIN=$(id -un 2>/dev/null || whoami)
SB2=$(HOME= TARGET=0123456789abcdef PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/suggest-branch.sh")
if [[ "$SB2" = "topic/$SB_LOGIN/template-update-0123456" ]]; then
  pass "an empty \$HOME falls back to the real login name"
else
  fail "an empty \$HOME falls back to the real login name (got '$SB2')"
fi
SB3=$(HOME=/Users/Shared TARGET=0123456789abcdef PHASE_KEY=$PK_BRANCH "$SKILL_DIR/scripts/suggest-branch.sh")
if [[ "$SB3" = "topic/$SB_LOGIN/template-update-0123456" ]]; then
  pass "a generic \$HOME (/Users/Shared) falls back to the real login name"
else
  fail "a generic \$HOME falls back to the real login name (got '$SB3')"
fi
refute "a missing TARGET is refused" \
  bash -c "TARGET= PHASE_KEY=$PK_BRANCH '$SKILL_DIR/scripts/suggest-branch.sh' >/dev/null 2>&1"

fi

if t "suggest-branch.sh — a ref-invalid \$HOME basename is sanitized"; then
# A space in $HOME's basename (a real macOS home directory shape, "/Users/Jane
# Doe") is not legal in a git ref path component. Left raw, the suggestion would
# be a name `git branch`/`git checkout -b` refuses outright.
mkdir -p "$SANDBOX/homes/Jane Doe"
SB_SPACE=$(HOME="$SANDBOX/homes/Jane Doe" TARGET=0123456789abcdef PHASE_KEY=$PK_BRANCH \
  "$SKILL_DIR/scripts/suggest-branch.sh")
if [[ "$SB_SPACE" = "topic/Jane-Doe/template-update-0123456" ]]; then
  pass "a space in \$HOME's basename collapses to a single dash"
else
  fail "a space in \$HOME's basename collapses to a single dash (got '$SB_SPACE')"
fi
# A run of several ref-invalid bytes collapses to ONE dash, not one per byte.
mkdir -p "$SANDBOX/homes/a~^:b"
SB_RUN=$(HOME="$SANDBOX/homes/a~^:b" TARGET=0123456789abcdef PHASE_KEY=$PK_BRANCH \
  "$SKILL_DIR/scripts/suggest-branch.sh")
if [[ "$SB_RUN" = "topic/a-b/template-update-0123456" ]]; then
  pass "a run of ref-invalid bytes collapses to a single dash"
else
  fail "a run of ref-invalid bytes collapses to a single dash (got '$SB_RUN')"
fi
# A fully ref-invalid basename sanitizes to nothing and falls back rather than
# printing an empty "topic//..." segment.
mkdir -p "$SANDBOX/homes/..."
SB_ALLDOT=$(HOME="$SANDBOX/homes/..." TARGET=0123456789abcdef PHASE_KEY=$PK_BRANCH \
  "$SKILL_DIR/scripts/suggest-branch.sh")
case "$SB_ALLDOT" in
  topic/*/template-update-0123456)
    [[ "$SB_ALLDOT" != "topic//template-update-0123456" ]] \
      && pass "an all-dot \$HOME basename falls back instead of an empty segment" \
      || fail "an all-dot \$HOME basename falls back instead of an empty segment (got '$SB_ALLDOT')" ;;
  *) fail "an all-dot \$HOME basename falls back instead of an empty segment (got '$SB_ALLDOT')" ;;
esac
fi

if t "suggest-branch.sh — SOURCE names the run, and a chained frontend run keeps the branch"; then
# One invocation may chain two runs, and by default one PR carries both — so a
# CHAINED frontend run must not suggest a second branch off the first one's tip.
# When the template run's branch is on the anchor, the script prints it back
# VERBATIM rather than re-deriving it: the name is the user's (Phase 4 confirmed it,
# and they may have overridden the suggestion), and re-deriving from $TARGET would
# silently rename it.
SBH=$SANDBOX/homes/alice
mkdir -p "$SBH"
sb() { HOME=$SBH TARGET=0123456789abcdef PHASE_KEY=$PK_BRANCH \
  env "$@" "$SKILL_DIR/scripts/suggest-branch.sh"; }

SB_T=$(sb SOURCE=template)
if [[ "$SB_T" = "topic/alice/template-update-0123456" ]]; then
  pass "SOURCE=template is the pre-frontend name, unchanged"
else
  fail "SOURCE=template is the pre-frontend name (got '$SB_T')"
fi
SB_F=$(sb SOURCE=frontend)
if [[ "$SB_F" = "topic/alice/frontend-update-0123456" ]]; then
  pass "a frontend-only run gets its own frontend-update- name"
else
  fail "a frontend-only run gets its own frontend-update- name (got '$SB_F')"
fi
SB_C=$(sb SOURCE=frontend MIGRATION_BRANCH=topic/alice/my-own-name)
if [[ "$SB_C" = "topic/alice/my-own-name" ]]; then
  pass "a chained frontend run prints the existing migration branch verbatim"
else
  fail "a chained frontend run prints the existing migration branch verbatim (got '$SB_C')"
fi
# A template run must ignore it: its own branch is the one Phase 4 is about to
# create, so reusing an existing name would make the checkout a no-op.
SB_TI=$(sb SOURCE=template MIGRATION_BRANCH=topic/alice/my-own-name)
if [[ "$SB_TI" = "topic/alice/template-update-0123456" ]]; then
  pass "a template run ignores MIGRATION_BRANCH"
else
  fail "a template run ignores MIGRATION_BRANCH (got '$SB_TI')"
fi
# An empty MIGRATION_BRANCH is the first-run answer, not a chained one.
SB_FE=$(sb SOURCE=frontend MIGRATION_BRANCH=)
if [[ "$SB_FE" = "topic/alice/frontend-update-0123456" ]]; then
  pass "an empty MIGRATION_BRANCH falls through to the derived name"
else
  fail "an empty MIGRATION_BRANCH falls through to the derived name (got '$SB_FE')"
fi
refute "an unknown SOURCE is refused, not defaulted" \
  bash -c "HOME=$SBH TARGET=0123456789abcdef PHASE_KEY=$PK_BRANCH SOURCE=web '$SKILL_DIR/scripts/suggest-branch.sh' >/dev/null 2>&1"
# Set-but-empty: Phase 4 interpolates SOURCE=$RUN_SOURCE off the anchor, so empty is
# a lost key, and defaulting it names a frontend run's branch `template-update-…`.
refute "a set-but-EMPTY SOURCE is refused" \
  bash -c "HOME=$SBH TARGET=0123456789abcdef PHASE_KEY=$PK_BRANCH SOURCE= '$SKILL_DIR/scripts/suggest-branch.sh' >/dev/null 2>&1"
fi

if t "suggest-branch.sh — the chained frontend run heals from the branch it is standing on"; then
# S3: MIGRATION_BRANCH lives only in $RUN/context.env, and the chained frontend
# re-entry runs a FRESH pre-flight whose sweep deletes that file — so Phase 4 asks with
# no anchor value at all. Without a second source of the fact, a new
# topic/<user>/frontend-update-<sha> branch is created off the template run's tip and the
# invocation ends with two branches and two PRs, contradicting the documented default.
# The branch already checked out IS the answer in that case.
SBH=$SANDBOX/homes/alice
mkdir -p "$SBH"
SBREPO=$SANDBOX/sb-repo
mkdir -p "$SBREPO" && ( cd "$SBREPO" && git init -q -b main \
  && git commit -q --allow-empty -m init ) >/dev/null 2>&1
sbin() { # sbin <cwd> <env...> — run the script from a given cwd
  local d="$1"; shift
  ( cd "$d" && HOME=$SBH TARGET=0123456789abcdef PHASE_KEY=$PK_BRANCH env "$@" \
      "$SKILL_DIR/scripts/suggest-branch.sh" )
}
git -C "$SBREPO" checkout -q -b topic/alice/template-update-abc1234
SB_HEAL=$(sbin "$SBREPO" SOURCE=frontend 2> "$SANDBOX/sb-heal.log")
if [[ "$SB_HEAL" = "topic/alice/template-update-abc1234" ]]; then
  pass "with no MIGRATION_BRANCH, a frontend run on a template-update- branch stays on it"
else
  fail "with no MIGRATION_BRANCH, a frontend run on a template-update- branch stays on it (got '$SB_HEAL')"
fi
expect "and says so, so the user can see it was not a new branch" \
  grep -qF 'already on migration-shaped branch' "$SANDBOX/sb-heal.log"
# The other glob too: a frontend-only run resumed onto its own earlier branch.
git -C "$SBREPO" checkout -q -b topic/alice/frontend-update-9999999
SB_HEAL2=$(sbin "$SBREPO" SOURCE=frontend 2>/dev/null)
if [[ "$SB_HEAL2" = "topic/alice/frontend-update-9999999" ]]; then
  pass "a frontend-update- branch is kept as well (either suggested glob)"
else
  fail "a frontend-update- branch is kept as well (got '$SB_HEAL2')"
fi
# An explicit MIGRATION_BRANCH still WINS: it is the user-confirmed name, and the
# standing-on fallback must not override it.
SB_BOTH=$(sbin "$SBREPO" SOURCE=frontend MIGRATION_BRANCH=topic/alice/my-own-name 2>/dev/null)
if [[ "$SB_BOTH" = "topic/alice/my-own-name" ]]; then
  pass "an anchored MIGRATION_BRANCH still outranks the checked-out branch"
else
  fail "an anchored MIGRATION_BRANCH still outranks the checked-out branch (got '$SB_BOTH')"
fi
# A TEMPLATE run must not heal onto anything — its branch is the one Phase 4 is about
# to create, so reusing the current one would make the checkout a no-op.
SB_T_ON=$(sbin "$SBREPO" SOURCE=template 2>/dev/null)
if [[ "$SB_T_ON" = "topic/alice/template-update-0123456" ]]; then
  pass "a template run standing on a migration branch still derives its own name"
else
  fail "a template run standing on a migration branch still derives its own name (got '$SB_T_ON')"
fi
# NOT migration-shaped: the frontend-only case keeps the new-branch path.
git -C "$SBREPO" checkout -q -b feature/my-work
SB_NM=$(sbin "$SBREPO" SOURCE=frontend 2> "$SANDBOX/sb-nm.log")
if [[ "$SB_NM" = "topic/alice/frontend-update-0123456" ]]; then
  pass "a frontend-only run from an ordinary branch gets its own frontend-update- name"
else
  fail "a frontend-only run from an ordinary branch gets its own name (got '$SB_NM')"
fi
refute "and it says nothing about staying on a branch" \
  grep -qF 'already on migration-shaped branch' "$SANDBOX/sb-nm.log"
# Outside a git work tree there is nothing to read, and the derivation stands.
SB_NOGIT=$(sbin "$SANDBOX" SOURCE=frontend 2>/dev/null)
if [[ "$SB_NOGIT" = "topic/alice/frontend-update-0123456" ]]; then
  pass "outside a git work tree the fallback is silent and the derived name stands"
else
  fail "outside a git work tree the derived name stands (got '$SB_NOGIT')"
fi
fi

finish_suite
