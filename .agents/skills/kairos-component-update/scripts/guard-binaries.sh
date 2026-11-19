#!/usr/bin/env bash
# guard-binaries.sh — refuse run-created binary blobs into migration history.
# The counterpart to clean-artifacts.sh: that one removes IGNORED build output
# from the WORKING TREE at close-out; this one stops NON-ignored binary blobs
# from being COMMITTED in the first place, where clean-artifacts can never reach
# them ("it can neither dirty a tracked file nor un-commit anything").
#
# WHY this exists: the per-task checkpoint in phases/7-execution.md is a blunt
# `git add -A`. A build or test run (the Phase 4.5 baseline, the Phase 5/7 gates)
# drops go binaries and `*.test` files into the tree; if the component's
# .gitignore does not already cover them, `git add -A` sweeps them into the
# commit. They are then TRACKED — clean-artifacts (ignored-only) never sees them,
# gate.sh's marker scan skips them (binary, `-I`), and the run's default keeps the
# per-task commits (the squash is opt-in, `--squash-on-finish`). So they ride into
# history and get pushed. This guard is the layer that catches them at the commit.
#
#   MODE=staged  (Phase 7, after `git add -A`, before the commit)
#       Inspect the STAGED set (`git diff --cached`, i.e. index vs HEAD). Flag
#       every binary blob whose path is ABSENT at BASE — a file that did not exist
#       before the migration. The caller must NOT commit on a non-zero exit.
#
#   MODE=range   (Phase 8 close-out backstop)
#       Inspect every binary blob ADDED by any commit in BASE..HEAD (not the net
#       endpoint diff). Same flag. A safety net for legacy or resumed runs whose
#       earlier commits predate this guard, or any commit made outside the Phase 7
#       tripwire. Per-commit (`git log --diff-filter=A`), NOT a net `diff BASE HEAD`,
#       precisely so a binary added in one checkpoint commit and removed in a later
#       one — absent at both endpoints yet still living in the intermediate commit
#       object that the default (checkpoints kept) pushes — is not invisible to the
#       one layer whose whole job is "anything the per-commit tripwire never saw".
#
# WHY "binary" and not "any build output": git's own binary classification
# (numstat prints `-\t-` for a blob it treats as binary) is the heavyweight-blob
# boundary — a compiled go binary, a `*.test`, a coverage `.prof`. A TEXT build
# artifact (a coverage.txt) is out of scope here on purpose: it is the .gitignore
# / clean-artifacts boundary, and a text file in history is not the megabyte-blob
# problem a push of a compiled binary is.
#
# WHY absent-at-BASE and not "every staged binary": a binary already tracked at
# the migration base is the component's own committed asset (an image, a testdata
# fixture) — a task that legitimately touches it must not be blocked. Only a
# binary that first APPEARS during the run is suspect. In `staged` mode the diff
# is already vs HEAD, so a template asset adopted at the structural commit is not
# even listed; the BASE check is what additionally lets a pre-existing tracked
# binary be modified. In `range` mode the add-scan DOES surface such a structural
# asset (added over the range), so `range` also excludes anything
# present at SAFE_EXTRA (the structural commit) — a template binary the
# `binary-for-user` classifier already surfaced at Phase 3 is not re-flagged here.
#
# WHY report-only (never rm, never `git rm`): a genuinely new binary asset a task
# added ON PURPOSE is rare but real, and the safe disposition is the user's, not
# this script's. On a hit the caller STOPS and surfaces the list with options —
# gitignore it and re-commit (build output), or record it in ALLOW and re-commit
# (a real asset) — the same surface-and-decide shape as every other Phase 7
# checkpoint. Deleting here would be the clean-artifacts mistake in reverse.
#
# Env in:  MODE       staged | range          (required)
#          BASE       <commit-ish>            (required, non-empty) — the migration
#                     base, PREV_SHA. An EMPTY BASE is refused, not defaulted: with
#                     it, `git cat-file -e "$BASE:$path"` becomes `... ":$path"`,
#                     the INDEX entry, which exists for every staged path, so every
#                     check would pass vacuously and the guard would silently
#                     disable itself. The call site reads it through a `${VAR:?}`
#                     guard for the same reason; this is the second line of defence.
#          SAFE_EXTRA <commit-ish>            (optional) — an extra tree that also
#                     counts as "pre-existing"; a binary present there is never
#                     flagged. Pass STRUCTURAL_SHA in `range` mode. Empty = none.
#          ALLOW      <file>                  (optional) — a newline-list of paths
#                     the user has explicitly approved to commit; never flagged.
#                     Absent or empty = nothing approved.
#          RUN        <dir>                   (required in `range`, unused in
#                     `staged`) — the run-state dir. In `range` the flagged list is
#                     also written to $RUN/committed-binaries.txt (empty = clean),
#                     the finalize log's persistent artifact.
# Stdout:  on a hit (exit 3): a one-line header, then one flagged path per line,
#          byte-sorted. Clean and bad-input paths print nothing to stdout.
# Exit:    0  clean — no run-created binary blob in scope
#          2  bad input (MODE/BASE unset or bad, BASE/SAFE_EXTRA unresolvable,
#             cwd is not a git work-tree)
#          3  found — one or more run-created binary blobs; list on stdout
set -u

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "FAIL: not inside a git work-tree" >&2; exit 2; }

# ALLOW / RUN may be caller-relative paths; resolve them BEFORE the cd to root
# below, or a relative one would be looked up under the wrong directory — ALLOW
# would silently miss every approved path (re-flagging cleared assets), and the
# range-mode artifact would land in the wrong place. An ALLOW that does not exist
# yet is fine — the loop's `-f` check handles it.
if [[ -n "${ALLOW:-}" ]]; then
  case "$ALLOW" in /*) : ;; *) ALLOW="$(pwd)/$ALLOW" ;; esac
fi
if [[ -n "${RUN:-}" ]] && [[ -d "$RUN" ]]; then
  RUN=$(cd -- "$RUN" && pwd)
fi

# Pin cwd to the work-tree root so `git diff --numstat` emits ROOT-relative paths
# and the `git ls-tree -- <path>` / `git ls-files -- <path>` membership checks
# below (which resolve a pathspec against cwd) agree with them. A frontend run's
# Phase 7 commits at the mount (web/), where an un-pinned scan would emit
# mount-relative paths and the root-relative lookups would all read "absent" —
# flagging every staged binary. A Kairos component is its own repo, so the
# toplevel IS the component root: this only ever normalizes cwd.
cd "$(git rev-parse --show-toplevel)" \
  || { echo "FAIL: cannot cd to the work-tree root" >&2; exit 2; }

[[ -n "${BASE:-}" ]] || { echo "FAIL: BASE not set (the migration base / PREV_SHA)" >&2; exit 2; }
git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null \
  || { echo "FAIL: BASE '$BASE' does not resolve to a commit" >&2; exit 2; }

if [[ -n "${SAFE_EXTRA:-}" ]]; then
  git rev-parse --verify --quiet "${SAFE_EXTRA}^{commit}" >/dev/null \
    || { echo "FAIL: SAFE_EXTRA '$SAFE_EXTRA' does not resolve to a commit" >&2; exit 2; }
fi

# The binary-blob path set of the diff for this MODE. `--no-renames` keeps the
# path field a single plain path (a rename would print `{old => new}` and break
# the split); build output is never a rename, so nothing real is lost. numstat
# prints `-\t-\t<path>` for a blob git treats as binary — `$3` under `-F'\t'` is
# that path. core.quotePath=false so a non-ASCII path is emitted literally rather
# than octal-escaped into a name that would never match the `git ls-tree` lookups
# below. Byte-sorted
# so the output (and the tests) are stable. A path bearing an embedded newline or
# TAB is ambiguous in this line form — accepted for the same reason
# clean-artifacts.sh accepts a newline: build output never carries one.
#
# FAIL-CLOSED: the `git … | awk | sort` runs under pipefail in a subshell so a git
# failure (corrupt index, bad range) propagates instead of being masked by the
# tail command's exit 0 — without it a broken `git diff` would yield an EMPTY set
# and the guard would report "clean" over a tree it never actually scanned.
binary_paths() {
  ( set -o pipefail
    case "$MODE" in
      staged) git -c core.quotePath=false diff --cached --no-renames --numstat -- . ;;
      # range: `git log --diff-filter=A` walks EVERY commit in the range and lists
      # the binaries each one ADDED, so an add-then-remove within the range is caught
      # from the commit that added it (a net `diff BASE HEAD` would miss it — absent
      # at both endpoints). --format= suppresses the commit headers, leaving only
      # numstat rows for the same `-\t-` binary filter. Adds only, so there are no
      # deletions to distinguish downstream. sort -u folds a path added by more than
      # one commit (removed then re-added) to a single row.
      range)  git -c core.quotePath=false log --no-renames --numstat --diff-filter=A --format= "$BASE"..HEAD -- . ;;
    esac \
      | awk -F'\t' '$1=="-" && $2=="-" { print $3 }' \
      | LC_ALL=C sort -u )
}

case "${MODE:-}" in
  staged|range) ;;
  *) echo "FAIL: MODE must be 'staged' or 'range' (got '${MODE:-}')" >&2; exit 2 ;;
esac

PATHS=$(binary_paths) || { echo "FAIL: could not list the diff (git error)" >&2; exit 2; }

# in_tree <commit-ish> <path> — true iff <path> is an entry in that commit's tree.
# `git ls-tree -- <path>` prints one line if present, nothing if absent, and is an
# EXACT tree lookup — deliberately NOT `git cat-file -e "<rev>:<path>"`, whose
# extended-SHA form silently falls back to the INDEX blob when the path is missing
# from the tree (git 2.50 confirmed), which would make every newly-staged binary
# read as "already at BASE" and disable the guard. `-z`-free: paths are compared,
# not re-split.
in_tree() { [[ -n "$(git ls-tree "$1" -- "$2" 2>/dev/null)" ]]; }

FOUND=""
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  # A binary DELETION also prints `-\t-` in numstat (an artifact being REMOVED —
  # the good case) and must never be flagged. In `staged` mode the surviving set is
  # the index (`git ls-files` lists a staged add, omits a staged delete), so filter
  # on it. `range` mode needs NO such filter: binary_paths already restricts it to
  # adds (--diff-filter=A), so there is no deletion to skip — and a path absent at
  # HEAD is an intermediate-only add (added in one checkpoint, removed in a later
  # one), which is exactly what this backstop must flag, not skip. A HEAD-membership
  # test here would re-hide that blob, reintroducing the miss.
  case "$MODE" in
    staged) [[ -n "$(git ls-files -- "$path" 2>/dev/null)" ]] || continue ;;
  esac
  # Pre-existing at the migration base (a tracked component asset) — never a hit.
  in_tree "$BASE" "$path" && continue
  # Present in the SAFE_EXTRA tree (the structural commit) — a template asset the
  # binary-for-user classifier already surfaced; not run-created output.
  if [[ -n "${SAFE_EXTRA:-}" ]]; then
    in_tree "$SAFE_EXTRA" "$path" && continue
  fi
  # User-approved for commit — a real new binary asset they chose to keep.
  if [[ -n "${ALLOW:-}" ]] && [[ -f "$ALLOW" ]] && grep -qxF -- "$path" "$ALLOW"; then
    continue
  fi
  FOUND="$FOUND$path
"
done <<EOF
$PATHS
EOF

# In `range` mode the flagged list is also a persistent artifact for the finalize
# log — this script is its format owner, written the house way (temp-then-mv in
# the same dir so the install is an atomic same-filesystem rename). RUN is the
# run-state dir, required in `range`, unused in `staged` (the tripwire's output is
# consumed inline at the commit, never persisted). Empty file = a clean range, the
# positive-evidence artifact.
if [[ "$MODE" = range ]]; then
  [[ -n "${RUN:-}" ]] && [[ -d "$RUN" ]] \
    || { echo "FAIL: MODE=range needs RUN set to an existing run-state dir" >&2; exit 2; }
  printf '%s' "$FOUND" > "$RUN/committed-binaries.txt" \
    || { echo "FAIL: could not write $RUN/committed-binaries.txt" >&2; exit 2; }
fi

if [[ -n "$FOUND" ]]; then
  echo "run-created binary blob(s) about to enter migration history (MODE=$MODE):"
  printf '%s' "$FOUND"
  exit 3
fi
exit 0
