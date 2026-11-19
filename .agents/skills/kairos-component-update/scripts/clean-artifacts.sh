#!/usr/bin/env bash
# clean-artifacts.sh — remove the build/test artifacts THIS run produced, and
# nothing else. Two actions, one per end of the run:
#
#   ACTION=snapshot  (Phase 4.5, before the first test/build ever runs)
#       Record the tree's ignored-path set as it stands BEFORE any test or build
#       has had a chance to drop output. Write-once — a second call keeps the
#       first snapshot rather than re-capturing a tree that testing has already
#       polluted (a re-run of Phase 4.5's baseline, a continue, a resume).
#
#   ACTION=clean     (Phase 8 close-out, after the final gate)
#       Re-list the ignored set and remove only the entries that appeared SINCE
#       the snapshot — the go binaries, `.test` files, coverage output, `target/`,
#       `dist/` a build or a test run left behind. Pre-existing ignored paths
#       (a node_modules/ or a bin/ the user already had) are in the snapshot, so
#       they are never in the delta and never touched.
#
# WHY the delta and not a blunt `git clean -dX`: git treats every ignored path as
# disposable, but "ignored" is not "this run made it". A component checked out
# with node_modules/, a vendored .venv/, or a bin/ from a build the developer ran
# before starting the migration must survive untouched — a clean that nukes them
# is a surprise measured in reinstall minutes, not a courtesy. The snapshot is
# what tells run-created output apart from what was already there.
#
# WHY ignored-only (not untracked-not-ignored): a tree's .gitignore is the
# component's own declaration of what is disposable build output. An untracked
# file that is NOT ignored is either source the developer forgot to add or a
# stray the skill must not silently delete — and the per-task `git add -A` commits
# (phases/7-execution.md) sweep every such path that STAYS non-ignored into a
# commit, so it is no longer untracked by Phase 8. Ignored is the safe, principled
# boundary, and it is the same boundary gate.sh's marker scan draws ("ignored
# build output is out of scope by construction").
#
# THE ONE PATH `git add -A` does NOT sweep: content that was untracked-and-NOT-
# ignored at snapshot time but becomes IGNORED during the run — a pre-existing
# `generated/` the user carried, that a template-introduced .gitignore rule
# starts matching mid-run. `git add -A` never stages an ignored path, so it stays
# untracked, and at Phase 8 it is ignored-and-present-but-absent-from-the-snapshot
# — indistinguishable, on the ignored set alone, from a run-created artifact, and
# it would be deleted (the user's own content, against this script's surface-not-
# sweep posture). So the snapshot ALSO captures the untracked-not-ignored set at
# Phase 4.5 ($RUN/pre-test-untracked.txt), and the clean pass PROTECTS any delta
# entry that pre-existed there: newly-ignored is not newly-created.
#
# PROTECTED even when run-created: `.kairos/` (the gitignored run state Phase 8
# deliberately leaves in place for post-mortem), `.git/`, and the two heavyweight
# dependency dirs `vendor/` and `node_modules/` — the same set gate.sh excludes
# from its scan, matched with gate.sh:528's exact root-and-nested spelling so a
# NESTED `web/node_modules/` (the default spelling on every frontend run, where
# the ignored dir sits under a source dir git cannot collapse away) or a
# `sub/vendor/` is protected too, not just a root-level one. A build step that ran
# `go mod vendor` or `npm install` mints these; they are left in place and
# REPORTED, never removed, because recreating them is expensive and their removal
# is never what "clean up test binaries" means.
#
# The listing collapses a fully-ignored directory to a single `dir/` entry
# (`--directory`), so a brand-new `bin/` is one delta row removed whole. The flip
# side, accepted deliberately: a NEW file dropped INTO a pre-existing ignored
# directory is hidden behind that directory's unchanged collapsed entry and is
# left alone — this script only ever removes a whole new artifact path, it never
# reaches into a directory that predates the run.
#
# Env in:  ACTION   snapshot | clean   (required)
#          RUN      migration state dir (required; must already exist)
# Keyless — DELIBERATELY, like record-context.sh / promote-intent.sh: it is
#          called from TWO phases (4.5 and 8) whose proof-of-load keys differ, so
#          no single PHASE_KEY guard could serve both, and it is housekeeping, not
#          a gated correctness step. It is not a phase entry point and does not
#          appear in tests/skill-lint.test.sh's PK_PAIRS inventory.
# Stdout:  snapshot -> "captured N ignored path(s)" | "kept existing snapshot (N path(s))"
#          clean    -> a "removed:"/"kept (protected):" report, then a summary line
# Exit:    0  done (clean is best-effort: an absent snapshot is a reported SKIP,
#              not a failure — the run already succeeded by the time this runs)
#          2  bad input (ACTION/RUN unset or bad, cwd is not a git work-tree)
set -u

[[ -n "${RUN:-}" ]]    || { echo "FAIL: RUN not set" >&2; exit 2; }
[[ -d "$RUN" ]]        || { echo "FAIL: RUN dir '$RUN' does not exist" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "FAIL: not inside a git work-tree" >&2; exit 2; }

# Resolve RUN to an absolute path, THEN pin cwd to the work-tree root, so the two
# invocations — snapshot (Phase 4.5) and clean (Phase 8) — always list and remove
# the SAME tree. `git ls-files` emits cwd-relative paths limited to cwd-and-below,
# so a snapshot and a clean run from different subdirs would diff apart and flag
# every path as run-created. A Kairos component is its own repo, so the toplevel
# IS the component root: this only ever normalizes the invocation cwd, it never
# broadens the scan. RUN is made absolute first so SNAP (and the mktemp/mv into it)
# still resolve after the cd, whatever the caller's cwd was.
RUN=$(cd -- "$RUN" && pwd) \
  || { echo "FAIL: cannot resolve RUN dir '$RUN'" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)" \
  || { echo "FAIL: cannot cd to the work-tree root" >&2; exit 2; }

SNAP="$RUN/pre-test-ignored.txt"
# The untracked-but-NOT-ignored set at snapshot time — user content that predates
# the run and, if a run-introduced .gitignore rule later matches it, would otherwise
# look run-created at Phase 8. Captured beside SNAP (see header). Absent on a run
# snapshotted before this guard existed → the clean pass degrades to the old
# ignored-only behaviour rather than erroring.
UNTRACKED_SNAP="$RUN/pre-test-untracked.txt"

# list_ignored — the tree's ignored-path set, one entry per line, fully-ignored
# directories collapsed to a single trailing-slash entry. Byte-sorted so the two
# captures (snapshot vs. clean) line up for the exact-line diff below. A path
# holding an embedded newline is ambiguous in this line-based form — accepted for
# the same reason gate.sh accepts it in its record: build output never carries
# one, and the alternative (a NUL stream) has no portable line-diff. `sort` is
# locale-pinned so an ambient-locale delta cannot reorder the two captures apart.
#
# FAIL-CLOSED: the `git … | sort` pipeline runs under `pipefail` in a subshell so
# a git failure (corrupt index, not-a-repo) propagates as a non-zero return
# instead of being masked by sort's own exit 0 — same class coverage-blind.sh:66
# guards. Without it, a broken `git ls-files` at snapshot time silently captures
# an EMPTY set, and every pre-existing ignored path (node_modules/, bin/, dist/)
# then reads as run-created and is deleted at Phase 8. The callers' `|| … exit`
# guards only bite because this returns the git failure.
list_ignored() {
  ( set -o pipefail
    git ls-files --others --ignored --exclude-standard --directory 2>/dev/null \
      | LC_ALL=C sort -u )
}

# list_untracked — the tree's untracked-but-NOT-ignored set (no --ignored), same
# --directory collapsing and byte-sort as list_ignored so a wholly-untracked
# directory reads as one `dir/` entry symmetric with the ignored side. This is the
# pre-existing-user-content set the snapshot records so the clean pass can tell a
# path that became ignored mid-run (keep it) from one the run created (remove it).
list_untracked() {
  ( set -o pipefail
    git ls-files --others --exclude-standard --directory 2>/dev/null \
      | LC_ALL=C sort -u )
}

# preexisted <entry> — was this delta entry present as untracked-not-ignored content
# at snapshot time? The two sides collapse directories independently (--directory),
# so the snapshot may hold `generated/` while the delta names the deeper
# `generated/reports/`, or the reverse, or an exact file. Protect on ANY overlap:
# entry == snapshot line,
# entry lies under a snapshot dir (dir-line is a prefix of entry), or a snapshot path
# lies under an entry dir (entry-dir is a prefix of the line). Overlap with a
# pre-existing user directory is protected on purpose — the same "never reach into a
# directory that predates the run" rule the header states. Fixed string comparisons,
# no regex. No untracked snapshot (pre-guard run) → not-preexisted, i.e. old behaviour.
preexisted() {
  local e="$1"
  [[ -f "$UNTRACKED_SNAP" ]] || return 1
  awk -v e="$e" '
    {
      s = $0
      if (s == e) { found = 1; exit }
      if (substr(s, length(s)) == "/" && substr(e, 1, length(s)) == s) { found = 1; exit }
      if (substr(e, length(e)) == "/" && substr(s, 1, length(e)) == e) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$UNTRACKED_SNAP"
}

case "${ACTION:-}" in

  snapshot)
    if [[ -f "$SNAP" ]]; then
      echo "kept existing snapshot ($(grep -c . "$SNAP" 2>/dev/null || true) path(s))"
      exit 0
    fi
    # tmp-then-mv, in $RUN so the mv is a same-filesystem rename: a crash leaves
    # either no snapshot (re-captured next call) or a complete one, never a
    # half-written set that would make the Phase 8 delta lie.
    TMP=$(mktemp "$RUN/.pre-test-ignored.XXXXXX") \
      || { echo "FAIL: cannot create a temp file in $RUN" >&2; exit 2; }
    trap 'rm -f "$TMP"' EXIT
    list_ignored > "$TMP" || { echo "FAIL: could not list ignored paths" >&2; exit 2; }
    mv "$TMP" "$SNAP"      || { echo "FAIL: could not write $SNAP" >&2; exit 2; }
    trap - EXIT
    # The untracked-not-ignored set, same tmp-then-mv discipline. Written second and
    # only on the first snapshot (this branch is guarded write-once by SNAP above), so
    # the two files stay in lockstep — a pre-existing-content list without its ignored
    # baseline, or vice versa, never lands. A failure here is non-fatal: the ignored
    # snapshot is already durable and the clean pass degrades to protecting nothing
    # extra, so warn and continue rather than abort a run that has otherwise succeeded.
    UTMP=$(mktemp "$RUN/.pre-test-untracked.XXXXXX") \
      && list_untracked > "$UTMP" \
      && mv "$UTMP" "$UNTRACKED_SNAP" \
      || { echo "WARN: could not capture the untracked-not-ignored set ($UNTRACKED_SNAP); newly-ignored user content will not be protected at clean time" >&2; rm -f "$UTMP" 2>/dev/null || true; }
    echo "captured $(grep -c . "$SNAP" 2>/dev/null || true) ignored path(s)"
    exit 0
    ;;

  clean)
    if [[ ! -f "$SNAP" ]]; then
      echo "SKIP: no pre-test snapshot at $SNAP — cannot tell run-created artifacts"
      echo "      from paths that predate the run; removing nothing. Remove any stray"
      echo "      build output (go binaries, coverage files) by hand if needed."
      exit 0
    fi
    # Delta = ignored paths present NOW but absent from the snapshot = created
    # during the run. grep -Fxv -f does the exact-full-line set difference; an
    # empty snapshot file makes every current entry a delta, which is correct
    # (nothing was ignored before the run, so everything ignored now is new).
    REMOVED=0; KEPT=0
    HAVE_REMOVED=""; HAVE_KEPT=""
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      case "$entry" in
        .kairos/*|.kairos|.git/*|*/.git/*|.git|vendor/*|*/vendor/*|vendor|node_modules/*|*/node_modules/*|node_modules)
          KEPT=$((KEPT + 1)); HAVE_KEPT="yes"
          printf '  kept (protected): %s\n' "$entry"
          continue ;;
        /*|*/../*|../*|*/..)
          # git ls-files never emits these; refuse defensively rather than rm an
          # absolute or parent-escaping path.
          KEPT=$((KEPT + 1)); HAVE_KEPT="yes"
          printf '  kept (refused, unexpected path): %s\n' "$entry"
          continue ;;
      esac
      # Newly-ignored, not newly-created: a path that was untracked-not-ignored user
      # content at snapshot time and became ignored during the run (a template-added
      # .gitignore rule) is in the delta but must NOT be removed — it is the user's own
      # content, and `git add -A` never staged it (ignored paths are skipped). Protect it.
      if preexisted "$entry"; then
        KEPT=$((KEPT + 1)); HAVE_KEPT="yes"
        printf '  kept (pre-existing user content newly ignored): %s\n' "$entry"
        continue
      fi
      [[ -e "$entry" ]] || continue   # vanished between listing and removal
      if rm -rf -- "$entry"; then
        REMOVED=$((REMOVED + 1)); HAVE_REMOVED="yes"
        printf '  removed: %s\n' "$entry"
      else
        KEPT=$((KEPT + 1)); HAVE_KEPT="yes"
        printf '  kept (rm failed): %s\n' "$entry"
      fi
    done < <(list_ignored | grep -Fxv -f "$SNAP")

    [[ -n "$HAVE_REMOVED$HAVE_KEPT" ]] || echo "  (no run-created ignored paths)"
    echo "cleaned: $REMOVED removed, $KEPT kept"
    exit 0
    ;;

  *)
    echo "FAIL: ACTION must be 'snapshot' or 'clean' (got '${ACTION:-}')" >&2
    exit 2
    ;;
esac
