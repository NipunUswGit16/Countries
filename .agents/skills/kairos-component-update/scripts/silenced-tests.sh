#!/usr/bin/env bash
# silenced-tests.sh — deterministic scan for newly-silenced tests across a
# migration's whole range, relayed beside the final gate at Phase 8 step 1.
#
# WHY the net RANGE diff, not per-commit diffs: a skip added in one executor
# commit and removed in a later one is absent from the final tree, and the
# question this artifact answers is "what does the final tree silence that the
# pre-migration tree did not" — the only question the baseline advance needs
# answered. Provenance (which commit added a survivor) is one `git log -S` the
# maintainer can run by hand; this scan does not chase it. `git diff
# PREV_SHA HEAD` over the whole range gives that net view directly — no
# per-commit loop, no manual re-merging of intermediate adds/removes.
#
# WHY test files are matched by FILENAME PATTERN, never by invoking a
# toolchain: the constructs below are added lines in files that already look
# like tests before any build runs, and running per-language tooling here
# would turn a zero-token deterministic scan into an agent-shaped dependency.
# A test living outside the patterns is a false negative — accepted, same
# design rule as coverage-blind.sh's sibling-test heuristic.
#
# WHY the construct list is fixed and literal, checked as SUBSTRINGS: no
# heuristics, no per-language parser. A bespoke skip helper or a build-tag
# exclusion is a false negative — accepted. A match on an added COMMENT line
# is still reported: this artifact is a human review prompt, not a gate
# verdict, so the occasional comment-level match is acceptable noise here —
# the one surface in this skill where that trade is taken, and it is taken
# knowingly.
#
# WHY every needle match is BOUNDARY-GUARDED rather than a bare substring
# test: a short construct name with no delimiters of its own collides with
# unrelated identifiers that merely contain it as an infix — "xit" inside
# Go's canonical `os.Exit(m.Run())` (a shape migrations add routinely via
# `func TestMain`), or "test.skip" inside some unrelated longer identifier
# that happens to embed it. The guard is still zero-heuristic, zero-parser
# substring matching — it only adds one check: a needle counts as a hit only
# when the character immediately before and immediately after the match is
# NOT itself an identifier character ([A-Za-z0-9_]); start/end of line always
# satisfies the guard. That is enough to tell "xit(" / "t.Skip(" / "@Ignore"
# (real constructs, always flanked by punctuation, whitespace, or line
# start/end) apart from "Exit(" / "os.Exit(" (the needle sitting inside a
# longer identifier) without hard-coding a per-construct call shape, and it
# applies uniformly to every needle in the table — no needle is special-cased
# over another.
#
# WHY some constructs are checked before their own prefix ("t.SkipNow" and
# "t.Skipf" before "t.Skip"; "pytest.mark.skipif" before "pytest.mark.skip"):
# literal-substring matching means an added `t.SkipNow(...)` line also
# contains the substring "t.Skip". Checking the longer, more specific name
# first reports the construct that was actually written, not a truncation of
# it.
#
# WHY `-c core.quotePath=false`: git's default quotes any byte >= 0x80 in a
# path as an escaped octal sequence in diff headers, which would turn a
# non-ASCII test path into unparseable noise. Turning it off makes `--- `/
# `+++ ` headers carry the literal UTF-8 path, matching what every other
# reader of the tree (and the TSV this script writes) expects to see.
#
# WHY `-c diff.noprefix=false` is pinned alongside it: the awk below always
# strips a fixed 2-char `a/`/`b/` prefix from each header (`substr(p, 3)`,
# same shape as the `oldp`/`newp` assignments). A user- or repo-level
# `diff.noprefix = true` in the invoking environment's git config turns that
# prefix off, so headers arrive as `--- foo_test.go` instead of
# `--- a/foo_test.go` — and the unconditional `substr(p, 3)` then silently
# truncates every path to its 3rd character onward (`foo_test.go` ->
# `o_test.go`), garbling every row this script writes to $RUN/silenced-tests.tsv
# without any error. Forcing the option to `false` here removes the ambient
# git config as a variable, the same reasoning as forcing `--find-renames`
# below instead of trusting `diff.renames`.
#
# WHY `--find-renames` is passed explicitly rather than relying on the
# ambient `diff.renames` config: a renamed test file that also gained a skip
# line must show up as a rename-plus-hunk (so only the real new lines are
# scanned) regardless of the invoking environment's git config. Forcing it
# keeps the scan deterministic across machines instead of depending on
# whatever `git config` happens to say.
#
# WHY this script never calls `basename`/`dirname` on an extracted path (the
# leading-dash hazard coverage-blind.sh works around): no path here is ever
# handed to a shell command as an argument. Every path is a string sliced out
# of `git diff`'s own output and manipulated entirely inside awk (split/
# substr), and the only git invocation takes two already-resolved 40-hex
# commit SHAs with no pathspec at all — there is no leading-dash operand
# anywhere in this script's own argument surface.
#
# WHY new-file line numbers are tracked from the `@@ -a,b +c,d @@` hunk
# header rather than read off `git blame`/`grep -n`: line numbers in the FINAL
# tree are exactly what a maintainer needs to jump to the finding, and they
# shift as regions are edited — the hunk header is git's own record of where
# the new content starts, updated hunk by hunk, so counting from it is exact
# without a second tool invocation per file.
#
# WHY records are written with `printf`, never `echo`: bash's builtin `echo`
# treats an argument that IS an option string (`-n`, `-e`, `-E`) as its own
# option rather than data — see coverage-blind.sh's header for the fuller
# version of this. A construct name here is a fixed literal (never attacker/
# author controlled in a way that collides with echo's flags), but the file
# PATH field is arbitrary tracked content, so the whole record goes through
# `printf '%s\t%s\t%s\n'`.
#
# Env in:  RUN       migration state dir (required)
#          PREV_SHA  the pre-migration baseline SHA, sourced by the caller
#                     from the run anchor (`$RUN/context.env`) — this script
#                     takes it as a plain env var, the same shape as RUN, and
#                     does not read context.env itself.
# Cwd:     component root (a git repo)
# Reads:   nothing on disk beyond the git history already in cwd
# Writes:  $RUN/silenced-tests.tsv   file <TAB> line <TAB> construct
#                                    one row per added, newly-silencing line;
#                                    ALWAYS written on success, including when
#                                    empty — zero findings is positive
#                                    evidence, not silence about whether the
#                                    scan ran.
# Stderr:  one summary line naming how many test files were scanned and how
#          many findings resulted (both success and — for the FAIL paths
#          below — the reason no artifact was written).
# Exit:    0  scan completed (findings, if any, are in the TSV; 0 findings is
#             success, not an error)
#          1  PREV_SHA absent/unset, or set but does not resolve to a commit,
#             or HEAD does not resolve to a commit, or the range diff itself
#             failed — a SKIP that escalates, the same contract an absent
#             $SYNTH uses elsewhere in this
#             skill. $RUN/silenced-tests.tsv is NOT written on this path, so a
#             pre-existing artifact from an earlier successful run is left
#             untouched rather than being overwritten with a false "clean".
set -u

: "${RUN:?FAIL: RUN not set}"

if [[ -z "${PREV_SHA:-}" ]]; then
  echo "FAIL: PREV_SHA not set — cannot scan PREV_SHA..HEAD without a baseline. This is a skip that escalates, never a clean report; no $RUN/silenced-tests.tsv was written." >&2
  exit 1
fi

PREV_RESOLVED=$(git rev-parse --verify --quiet "${PREV_SHA}^{commit}" 2>/dev/null) || PREV_RESOLVED=""
if [[ -z "$PREV_RESOLVED" ]]; then
  echo "FAIL: PREV_SHA '$PREV_SHA' does not resolve to a commit in this repo. This is a skip that escalates, never a clean report; no $RUN/silenced-tests.tsv was written." >&2
  exit 1
fi

HEAD_RESOLVED=$(git rev-parse --verify --quiet "HEAD^{commit}" 2>/dev/null) || HEAD_RESOLVED=""
if [[ -z "$HEAD_RESOLVED" ]]; then
  echo "FAIL: HEAD does not resolve to a commit in this repo. No $RUN/silenced-tests.tsv was written." >&2
  exit 1
fi

mkdir -p "$RUN"
OUT="$RUN/silenced-tests.tsv"

DIFF=$(mktemp "${TMPDIR:-/tmp}/silenced-tests-diff.XXXXXX")
COUNTFILE=$(mktemp "${TMPDIR:-/tmp}/silenced-tests-count.XXXXXX")
trap 'rm -f "$DIFF" "$COUNTFILE"' EXIT

# The diff's exit status is CHECKED, and the failure arm writes nothing — the same
# contract the PREV_SHA arms above hold to. Unchecked (and with stderr discarded), a
# diff that FAILED — a pruned or corrupted object, an unreadable object store — left
# an empty $DIFF, and the awk below then wrote a zero-finding $RUN/silenced-tests.tsv
# and printed `OK: scanned 0 test file(s) … 0 newly-silenced construct(s)`, exit 0: a
# false clean that also DESTROYED the artifact an earlier successful run had left.
# git's own error line is the diagnosis, so stderr is not redirected here.
if ! git -c core.quotePath=false -c diff.noprefix=false diff --no-color --no-ext-diff -U0 --find-renames \
     "$PREV_RESOLVED" "$HEAD_RESOLVED" > "$DIFF"; then
  echo "FAIL: git diff $PREV_SHA..HEAD failed (see git's error above) — the range could not be read, so nothing was scanned. This is a skip that escalates, never a clean report; no $RUN/silenced-tests.tsv was written." >&2
  exit 1
fi

awk -v countfile="$COUNTFILE" '
  function is_test_file(path,   n, parts, base) {
    n = split(path, parts, "/")
    base = parts[n]
    if (base ~ /_test\.go$/)     return 1
    if (base ~ /\.test\./)       return 1
    if (base ~ /\.spec\./)       return 1
    if (base ~ /^test_.*\.py$/)  return 1
    if (base ~ /_test\.py$/)     return 1
    return 0
  }
  function is_word_char(ch) {
    return (ch ~ /^[A-Za-z0-9_]$/)
  }
  # 1 iff `needle` occurs in `line` at a position not embedded inside a larger
  # identifier: the character immediately before and immediately after the
  # match (absent at line start/end, which always satisfies the guard) must
  # not itself be an identifier character. Scans every occurrence left to
  # right — a needle that first appears unbounded (e.g. "xit" inside "Exit")
  # keeps looking rather than stopping at the first, non-matching hit.
  function bounded_match(line, needle,    at, idx, before, after, nlen, llen) {
    nlen = length(needle); llen = length(line)
    at = 1
    while ((idx = index(substr(line, at), needle)) > 0) {
      at = at + idx - 1
      before = (at == 1) ? "" : substr(line, at - 1, 1)
      after  = (at + nlen > llen) ? "" : substr(line, at + nlen, 1)
      if (!is_word_char(before) && !is_word_char(after)) return 1
      at += 1
      if (at > llen) return 0
    }
    return 0
  }
  function classify(line,   i) {
    for (i = 1; i <= NNEEDLES; i++) {
      if (bounded_match(line, needle[i])) return needle[i]
    }
    return ""
  }
  BEGIN {
    n = 0
    # Longer/more-specific constructs are listed before a shorter construct
    # that is a literal prefix of them (see header). Order otherwise follows
    # the PRD list: Go, JS/TS, Java, Python.
    needle[++n] = "t.SkipNow"
    needle[++n] = "t.Skipf"
    needle[++n] = "t.Skip"
    needle[++n] = "it.skip"
    needle[++n] = "describe.skip"
    needle[++n] = "test.skip"
    # `.todo` — a pending-test marker whose body never runs, so it silences a test
    # exactly as `.skip` does (the doc in phases/4.5-test-baseline.md counts it).
    needle[++n] = "it.todo"
    needle[++n] = "describe.todo"
    needle[++n] = "test.todo"
    needle[++n] = "xit"
    needle[++n] = "xdescribe"
    needle[++n] = "@Disabled"
    needle[++n] = "@Ignore"
    needle[++n] = "pytest.mark.skipif"
    needle[++n] = "pytest.mark.skip"
    NNEEDLES = n
    inheader = 0
    cur = ""; curistest = 0
    scanned = 0
  }
  {
    line = $0
    if (line ~ /^diff --git /) {
      oldp = ""; newp = ""; cur = ""; curistest = 0; inheader = 1
      next
    }
    if (inheader && line ~ /^--- /) {
      p = substr(line, 5)
      oldp = (p == "/dev/null") ? "" : substr(p, 3)
      next
    }
    if (inheader && line ~ /^\+\+\+ /) {
      p = substr(line, 5)
      newp = (p == "/dev/null") ? "" : substr(p, 3)
      path = (newp != "") ? newp : oldp
      curistest = is_test_file(path)
      if (curistest && path != "" && !seen[path]++) scanned++
      cur = newp
      inheader = 0
      next
    }
    if (line ~ /^@@ /) {
      if (match(line, /\+[0-9]+/)) linecounter = substr(line, RSTART + 1, RLENGTH - 1) + 0
      next
    }
    if (cur == "" || !curistest) next
    if (line ~ /^\\/) next   # "\ No newline at end of file"
    c1 = substr(line, 1, 1)
    if (c1 == "+") {
      ln = linecounter
      linecounter++
      constr = classify(substr(line, 2))
      if (constr != "") printf "%s\t%s\t%s\n", cur, ln, constr
    } else if (c1 == " ") {
      linecounter++
    }
    # c1 == "-": a removed line consumes no new-file line number.
  }
  END {
    print scanned > countfile
  }
' "$DIFF" > "$OUT"

SCANNED=$(cat "$COUNTFILE" 2>/dev/null); SCANNED=${SCANNED:-0}
FINDINGS=$(wc -l < "$OUT" | tr -d ' ')

printf 'OK: scanned %s test file(s) in %s..HEAD, %s newly-silenced construct(s)\n' \
  "$SCANNED" "$PREV_SHA" "$FINDINGS" >&2

exit 0
