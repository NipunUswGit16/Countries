#!/usr/bin/env bash
# coverage-blind.sh — compute the coverage-blind clean-merge list for the planner.
# A clean-merged file with no sibling/related test file is invisible to the sanity
# gate (tests only compile the code they reference), so the planner eyeballs these.
#
# The sibling-test heuristic: within the file's own directory, is there a tracked
# file whose name contains BOTH the file's stem AND "test"/"spec" (case-insensitive,
# either order)? If not, the file is coverage-blind.
#
# WHY dirname-filtered rather than a bare `git ls-files "$d"`: for a root-level
# file `d` is ".", and `git ls-files "."` lists every tracked file in the repo —
# a test anywhere (e.g. internal/domain/foo_test.go) would falsely "cover" a
# root main.go. Filtering the listing to entries whose own dirname equals `$d`
# scopes the search to the file's own directory in every case, root included.
#
# WHY the candidate's BASENAME is matched, not its path: the stem/test regex sees
# whatever it is fed, and a path carries its directories. Under a directory named
# `service`, EVERY entry in it contains "service", so any `*_test.go` sibling
# matches `service.*(test|spec)` and falsely "covers" service.go — the file then
# drops off the planner's eyeball list silently. Both sides are basenames.
#
# LEADING-DASH OPERANDS, AND WHY THE RECORD WRITE IS `printf`: clean-merged.txt is
# written by structural-merge.sh, which records raw component paths — so a file
# whose name starts with `-` arrives here. `basename`/`dirname` read such a path as
# a bundle of OPTIONS (neither has a portable `--`), print a usage error to the
# operator's stderr and return EMPTY: the stem went empty and `$d` matched no
# directory in the cached listing, so every leading-dash entry classified blind
# regardless of the siblings it actually has. They are anchored (`./`) on the way
# in instead, and `$d` is de-anchored again afterwards because it is compared
# against `git ls-files` output, which carries no `./`.
# The RECORD keeps the raw path — later readers and the operator's list must see
# one spelling — which is why it is written with `printf` and never `echo`: bash's
# builtin echo treats an argument that is EXACTLY an option string (`-n`, `-e`,
# `-E`, any combination) as its own options, so a coverage-blind file named `-n`
# was written as an empty line, or with `-n` in the set not at all. It then dropped
# off the planner's eyeball list — the one list whose whole purpose is that nothing
# clean-merged goes unlooked-at — with nothing to show it had been considered.
#
# WHY the stem is escaped before it hits grep: the stem is interpolated into an
# extended regex, so a stem carrying regex metacharacters (e.g. `foo.bar` from
# `foo.bar.go`) would match too loosely — `.` matching any char turns a near-miss
# into a false "covered". Escape the metacharacters so the stem matches literally.
#
# Env in:  RUN   migration state dir (required)
# Reads:   $RUN/clean-merged.txt
# Writes:  $RUN/coverage-blind.txt   (one path per line; empty if all covered)
# Exit:    0  list computed
#          1  $RUN/clean-merged.txt missing, or `git ls-files` failed (nothing written)
set -u

: "${RUN:?FAIL: RUN not set}"
[[ -f "$RUN/clean-merged.txt" ]] || { echo "FAIL: $RUN/clean-merged.txt not found" >&2; exit 1; }

# One `git ls-files` for the whole run, not one per entry: the per-directory
# scoping below (`d="."` for every root-level entry) makes `git ls-files -- "$d"`
# list the ENTIRE repo for every root file — O(n) full-repo git spawns for n
# root-level clean-merged entries. Cache the listing once and filter it with awk
# (already the per-entry step below) instead of re-walking the repo per entry.
ALLFILES=$(mktemp "${TMPDIR:-/tmp}/coverage-blind-files.XXXXXX")
trap 'rm -f "$ALLFILES" "$ALLFILES.err"' EXIT
# Checked: an unchecked failure here (not a git repo, a corrupt index) leaves
# $ALLFILES empty, and an empty listing "covers" nothing — every clean-merged
# file then classifies blind regardless of the sibling tests it actually has.
# That is over-reporting, not silence, but it is still a false claim about the
# tree rather than the diagnostic the real cause deserves — fail loudly instead.
# `-c core.quotePath=false`: git's default C-quotes any byte >= 0x80, so a sibling
# test file with a non-ASCII name (`café_test.go`) arrives as `"caf\303\251_test.go"`.
# Its computed dirname then no longer equals the raw `$d` from clean-merged.txt, so it
# drops out of the candidate pool and the file it covers is over-reported as
# coverage-blind. Off, git emits the literal UTF-8 bytes, matching the raw paths every
# other reader here carries — the same pin template-parity.sh and silenced-tests.sh use.
git -c core.quotePath=false ls-files > "$ALLFILES" 2>"$ALLFILES.err" \
  || { echo "FAIL: git ls-files failed — cannot compute the coverage-blind list without the tracked-file listing. stderr: $(cat "$ALLFILES.err")" >&2; rm -f "$ALLFILES.err"; exit 1; }
rm -f "$ALLFILES.err"

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  # Anchored before basename/dirname, then de-anchored for $d (see header).
  case "$f" in /*|./*) af=$f ;; *) af="./$f" ;; esac
  b=$(basename "$af"); d=$(dirname "$af"); d=${d#./}
  # A dotfile with no further extension (.env, .gitignore, .npmrc) has its
  # leading dot as the ONLY dot in the basename; `${b%.*}` treats that dot as
  # an extension separator and strips the whole name, leaving an EMPTY stem.
  # An empty stem turns the regex below into "(test|spec).*|.*(test|spec)" —
  # unanchored on the stem side, so ANY sibling containing "test"/"spec"
  # falsely "covers" every dotfile in the directory, and every dotfile
  # collapses onto the same (empty) key. Strip the leading dot first and only
  # treat what follows IT as having an extension.
  case "$b" in
    .*)
      rest=${b#.}
      if [[ "$rest" != "${rest%.*}" ]]; then stem=".${rest%.*}"; else stem="$b"; fi
      ;;
    *)
      stem=${b%.*}
      ;;
  esac
  # Escape ERE metacharacters so the stem matches as a literal substring.
  estem=$(printf '%s' "$stem" | sed 's/[][(){}.^$*+?|\\]/\\&/g')
  # Keep only entries whose own dirname is $d, and emit the BASENAME. One awk
  # over the cached full listing, not a `dirname`/`basename` fork (or a fresh
  # `git ls-files`) per entry.
  #
  # `$d` travels through the ENVIRONMENT, never `awk -v`: awk -v ESCAPE-PROCESSES
  # backslashes in the assigned string (`foo\bar` arrives inside the program as
  # `fooar`), so a directory name carrying a literal backslash byte (legal on
  # POSIX filesystems) would compare against the wrong, backslash-eaten value and
  # misclassify every file under it. ENVIRON["d"] hands awk the bytes verbatim —
  # the same reason build-manifest.sh's rename_target() and promote-intent.sh
  # route paths through ENVIRON[] instead of -v.
  d="$d" awk '{ i = match($0, "/[^/]*$"); if ((i ? substr($0, 1, i - 1) : ".") == ENVIRON["d"]) print (i ? substr($0, i + 1) : $0) }' "$ALLFILES" \
    | grep -qiE -- "(test|spec).*${estem}|${estem}.*(test|spec)" || printf '%s\n' "$f"
done < "$RUN/clean-merged.txt" > "$RUN/coverage-blind.txt"
