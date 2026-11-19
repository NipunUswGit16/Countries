#!/usr/bin/env bash
# intent-check.sh — vet the component's standing-intent facts against the current
# tree BEFORE any conflict-resolver reads them (Phase 5, step 1).
#
# `.kairos/intent.md` records cross-run intent facts, one dated bullet each, with
# an optional machine-checkable guard — a tree assertion in the small grammar
# below — written at Phase 8 promotion time:
#
#   - 2026-08-06: web/ is deliberately absent — the team removed the web UI
#     guard: test ! -e web/
#
# ---------------------------------------------------------------------------
# GUARD TRUST MODEL — read this before touching the guard runner
# ---------------------------------------------------------------------------
# `.kairos/intent.md` is COMMITTED and travels with the component. Cloning a repo
# and running this skill is therefore enough to evaluate every guard the file
# carries, and whoever wrote a guard need not be whoever runs the migration (a
# contributor, a fork, a PR branch, a supply-chain edit). Guard text is UNTRUSTED
# INPUT, exactly like a filename out of `git diff`.
#
# So: guard text NEVER reaches a shell. It is not eval'd, not passed to `bash -c`,
# not word-split into a command line the shell re-parses. It is tokenized here,
# checked token-by-token against the allowlisted grammar below, and the allowlisted
# binary is invoked directly with the validated argv. Anything the grammar does not
# accept — command substitution, `;`, `|`, `&&`, redirects, env-var prefixes,
# unknown commands or flags, absolute paths, `..` escapes, globs, quoting — is
# NOT executed and NOT guessed at: it is a reported UNPARSEABLE finding and its
# entry is excluded from the active view (fail closed).
#
# WHY the grammar is this small: a guard's whole job is to assert a shape the tree
# either has or does not have. Path existence and a quiet content match cover every
# guard the skill has ever proposed, and each one is a pure read whose only output
# is a single pass/fail bit consumed by the quarantine decision. That bit is the
# entire capability surface a hostile intent file gets.
#
# THE RESIDUAL, stated precisely so nobody has to re-derive it: a guard can READ —
# test the existence of, or content-search — any file reachable from the component
# root, INCLUDING through an in-tree symlinked directory that points outside it
# (`outlink -> /etc` makes `grep -q root outlink/passwd` a well-formed in-grammar
# guard; the `..`/absolute-path rules are lexical and a symlink is not lexical).
# What a guard yields from that read is one pass/fail bit per guard, consumed only
# by the quarantine decision — so the residual is an oracle, not a disclosure
# channel: a guard cannot WRITE, cannot EXECUTE, cannot EMIT what it read, and
# cannot see its own result. Resolving the symlink instead would break the useful
# case (components legitimately symlink vendored trees) for an oracle that already
# cannot report anything but a bit, so this is accepted deliberately.
#
# The other residual is TIME, and it is aggregate: GUARD_TIMEOUT bounds ONE grep
# guard, so N grep guards bound the sweep at N × GUARD_TIMEOUT, not GUARD_TIMEOUT.
# A hostile intent file with a hundred fifo guards therefore stalls Phase 5 for
# a hundred timeouts. Bounded and visible (every one reports a QUARANTINED: line),
# so it is a nuisance rather than a hang — but it is not a per-run ceiling, and a
# per-run budget is the change to make if that ever stops being good enough.
#
# A third residual, stated honestly rather than left to be discovered: `test`
# path-existence guards are answered in-process with NO alarm wrapper (only grep
# guards get GUARD_TIMEOUT — see run_guard). That is fine for the local/tmpfs
# paths every guard has ever targeted, but it is not an unconditional "cannot
# hang": `test -e`/`-f` against a path under a hung NFS/FUSE mount blocks
# uninterruptibly in the kernel, with nothing here to kill it, and would wedge
# Phase 5 exactly the way an un-timed grep guard would. Not fixed here — wrapping
# `test` the same way `grep` is wrapped is the change to make if a hung mount
# under an intent guard is ever observed in practice.
#
# WHY out-of-grammar guards are UNPARSEABLE rather than QUARANTINED: quarantine
# means "the fact no longer matches the tree" and its re-confirm recommendation is
# re-affirm / update / retire the FACT. An unreadable guard says nothing about the
# fact — the repair is to rewrite the GUARD. Same reasoning as the orphaned-guard
# case below, and the same as collect-common.sh splitting its skip reasons: one
# recommendation column cannot serve two unrelated causes.
#
# If richer guards are ever needed, that is a design change with a consent step,
# not a loosening of this parser (PRD: "a richer guard language is a separate PRD").
#
# GUARD GRAMMAR (the complete, only accepted forms — tokens are split on spaces
# and tabs; there is no quoting, so no token may contain whitespace):
#
#   guard := [ '!' ] ( test-guard | grep-guard )
#
#   test-guard := 'test' [ '!' ] ( -e | -f | -d | -s ) <path>
#   grep-guard := 'grep' <flags> <pattern> <path>
#                 flags: -q, optionally with F (-q, -qF, -Fq, -q -F). `q` is
#                 mandatory (a guard reads its exit status, never its output);
#                 `F` makes the pattern a fixed string. Nothing else — not -r,
#                 -i, -v, -E, --quiet.
#
#   <path>    relative to the component root and inside it: no leading `/`, no
#             `..` component, and only [A-Za-z0-9._/+@-]. That charset is what
#             makes globs and quoting impossible rather than merely unsupported.
#             It is checked against an explicit LITERAL allowlist, one character at
#             a time — never a `[A-Za-z0-9…]` glob range. A range is collation-
#             dependent: `wéb` fell INSIDE `[A-Za-z…]` under en_US.UTF-8 and outside
#             it under LC_ALL=C, so the same committed intent file bucketed one way
#             on the maintainer's macOS box and the other in the Ubuntu container.
#             No escape came of it (every dangerous ASCII byte is refused in both
#             locales), but a verdict that depends on the operator's environment is
#             not a verdict — a guard either matches the documented charset or it
#             does not. Non-ASCII is now out of grammar everywhere. Do not
#             "simplify" this back into a bracket range.
#   <pattern> a basic regular expression (or a fixed string with -F), rejected if
#             it contains shell syntax — `$(`, `${`, backtick, `;`, `|`, `&`, `<`,
#             `>`, `\`, `'`, `"` — or starts with `-`. Nothing here could reach a
#             shell, but a guard a human reader cannot distinguish from a pipeline
#             is refused on sight. This is also why -E is out of grammar: ERE's
#             alternation and grouping need exactly those characters, so write two
#             entries (all guards on an entry must pass) or a plainer pattern.
#
# Entry grammar (the Phase 8 promotion step writes it; this script is the parser
# of record):
#   * an entry is a column-0 line starting with `- `, plus every following
#     indented continuation line, ACROSS blank lines (see BLANK LINES below);
#   * a continuation line matching `guard: <tree assertion>` is the entry's guard;
#     multiple guard lines are allowed and ALL must be in grammar and pass. A
#     `guard:` line with NOTHING after the colon (or only whitespace) is a guard
#     the author meant to state and did not: the ENTRY is UNPARSEABLE, never
#     guardless. Guard-ness is decided by the `guard:` prefix, not by whether a
#     value was found — reading the value first and keeping it only when non-empty
#     is what made a truncated guard fail OPEN, which is the one direction this
#     script must never fail in;
#   * column-0 lines that are not bullets (headers, blanks, prose, thematic
#     breaks like `---`) are structure, not entries — they pass through to the
#     active view untouched — EXCEPT the two unparseable shapes below.
#
# BLANK LINES between an entry and its continuation are TOLERATED, any number of
# them, and the continuation still attaches to the entry above. A blank line used to
# settle the entry, so
#
#   - 2026-08-06: web/ is deliberately absent
#                                              <- one blank line
#     guard: test ! -e web/
#
# went ACTIVE with its guard never evaluated: the entry closed at the blank, and the
# `guard:` line then arrived with no entry open, where a stray indent is structure —
# copied into intent-active.md as prose. Silent de-guarding, the exact failure the
# orphaned-guard finding exists to prevent, on a file markdown reads as ONE list
# item (an indented block after a blank line is a continuation paragraph). WHY
# unbounded rather than "one blank line": the error being removed is a guard
# silently DROPPED, and tolerating a wider gap can only ever attach more guards to
# an entry — fail closed — while a bound would restore the drop for a two-line gap.
# Held blanks travel with whatever bucket their entry lands in, verbatim and in
# place; when the next line is not an indented continuation they are released into
# the active view exactly where they stood. A column-0 `guard:` after a gap is still
# an ORPHAN: the tolerance is for indented continuations, and an unindented guard
# line belongs to no entry however close it sits.
#
# A BLANK LINE IS THE ONLY SEPARATOR TOLERATED, and every other entry-closer that
# lands between a fact and its indented guard is an ORPHANED GUARD finding (see
# ORPHANED GUARDS below), never structure. The blank-line fix above closed one
# shape of silent de-guarding; the class was wider, because ANY entry-closer does
# the same damage — a thematic break `---`, a heading, a column-0 prose line, a
# wrong-style bullet. Each settled the entry (guardless -> ACTIVE), and the
# `guard:` line then arrived with no entry open, where a stray indent was
# structure: copied into intent-active.md as prose, its assertion never evaluated,
# nothing reported. Blank lines are tolerated because markdown reads an indented
# block after one as a continuation paragraph of the same list item — the file is
# not malformed. The others genuinely close the list item, so the file IS
# ambiguous, and the repair is an edit to the file rather than a guess by the
# parser.
#
# CRLF: one trailing carriage return is stripped from every line before parsing, the
# same idiom as the family's other parsers (lib/yaml-*.awk `sub(/\r$/, "", line)`,
# materialize.sh / bellwether-detect.sh `tr -d '\r'`). A Windows clone's intent file
# is the same intent file: without the strip the \r landed inside the LAST TOKEN of
# every guard (`test -d web<CR>` fails the path charset), so with this grammar EVERY
# guard in the file was unparseable and the component's whole standing intent was
# excluded from the run — and `---<CR>` was not a thematic break either. TRAILING
# only, never a whole-file `tr -d '\r'`: an interior CR is not a line ending, and
# deleting it would splice what follows into the guard — the NUL smuggling case with
# a different byte (`guard: test -e go.mod<CR>; touch W`). An interior CR stays out
# of grammar. The verbatim contract therefore means verbatim modulo that one line
# terminator: the outputs are LF, because Phase 5 reads them back as text.
#
# Two line shapes are UNPARSEABLE findings instead of structure (a third
# unparseable cause — a guard outside the grammar — is described above and reports
# the whole ENTRY, since a guard line lives inside its entry):
#   * a bullet-like marker that is not `- ` — `* `, `+ `, `-` with no space, or
#     a tab-indented bullet outside an entry: a promotion written in the wrong
#     list style, which would otherwise ride into the active view as prose,
#     never guard-vetted (inside an entry a tab-indented bullet is a nested-list
#     continuation, still visible to resolvers — not flagged);
#   * a `guard:` line that no entry owns — an ORPHANED guard, whether it sits at
#     column 0, is indented with no entry open, or is HIDDEN behind bytes the
#     indentation grammar does not read (see HIDDEN GUARDS below). Previously the
#     column-0 spelling was silently swallowed as structure and the indented one was
#     too, leaving the fact unguarded for the rest of the component's life; now all
#     three are reported findings.
#
# ORPHANED GUARDS — the attachment rule, one rule for both spellings. An orphaned
# guard is reported, and the entry it was almost certainly meant to vet is excluded
# from the active view with it, into the same bucket:
#   * the entry is still OPEN (the guard interrupts its own lines) — exclude it;
#   * the entry already CLOSED and went ACTIVE — take it BACK OUT of the active
#     view and exclude it. This is the silent-de-guarding case: an entry-closer
#     other than a blank line (a `---`, a heading, column-0 prose, a wrong-style
#     bullet) sat between the fact and its guard, so the fact went ACTIVE with its
#     guard never evaluated while the guard line was copied out as prose. Which is
#     why the active view is buffered rather than appended: a finding this parser
#     only learns about LATER has to be able to retract what it already emitted;
#   * no entry is identifiable (start of file, or the entry above was itself
#     already excluded) — the guard is reported alone.
# Excluding the entry is UNCONDITIONAL, even when it carries guards of its own that
# all passed: a stray guard line means the file's structure is not what its author
# believed, and one extra row in Phase 5's batched re-confirm is the cheap side of
# that trade — where letting a fact steer resolutions with an assertion nobody
# evaluated is the expensive one. Both wait for the re-confirm instead.
#
# HIDDEN GUARDS — the third spelling, and the rule that decides guard-ness for EVERY
# line. A `guard:` is a guard only when what sits in FRONT of it is an indentation
# this grammar reads — plain spaces and tabs — or nothing at all. Anything else in
# front of it is a guard its author stated and this parser cannot read: an NBSP (the
# routine browser/Confluence paste artifact), a vertical tab, a form feed, a
# zero-width space (U+200B), an ideographic space (U+3000), any other invisible or
# non-ASCII byte, in any combination and behind any number of plain spaces. Such a
# line is REPORTED and the entry it was meant to vet is EXCLUDED, exactly like an
# orphan — orphan_guard is one rule for all three spellings.
#
# THE CLASSIFICATION RULE, stated so it can be checked line by line. Let LEAD be the
# line's leading run of bytes that are NOT graphic ASCII (0x21..0x7E) and REST the
# rest of the line. When REST begins `guard:`:
#   * LEAD is EMPTY          -> a column-0 orphan: no entry owns it;
#   * LEAD is all SPACE/TAB  -> the sanctioned path: the open entry's guard, or an
#                               orphan when no entry is open;
#   * LEAD is anything else  -> a HIDDEN guard: UNPARSEABLE, entry excluded.
# Every other line classifies exactly as it did before. The rule is BYTE-EXPLICIT and
# the whole script runs under a pinned LC_ALL=C (see below), so which bucket a
# committed line lands in cannot depend on the operator's locale.
#
# WHY AN ALLOWLIST OF INDENTS AND NOT A LIST OF SUSPECT BYTES. The rule used to be a
# hard-coded list of six whitespace-variant bytes — {SP, TAB, VT, FF, CR, NBSP in two
# spellings} — stripped off the front of the line, with everything else falling
# through to prose. So a `guard:` behind ANY byte the list did not name (U+200B and
# U+3000 both proved it) was STRUCTURE: the entry above went ACTIVE with its guard
# never evaluated, the guard line was copied into intent-active.md as prose, nothing
# was reported and the run exited 0 — the silent quarantine bypass this parser
# promises never to produce, and the cheapest one there is in the untrusted-
# committed-file threat model. An allowlist of the indents that ARE the grammar
# cannot be outrun that way: a byte nobody thought of now REFUSES the line instead of
# promoting it, which is the direction this script must fail in.
#
# The list's other half was worse, because it was not even stable. `<SP><NBSP>guard:`
# begins with a space, so it never reached the byte list at all — it reached the
# INDENTED branch, whose `[[:space:]]` glob counts an NBSP as space under
# en_US.UTF-8 and does not under LC_ALL=C. The same committed intent file therefore
# vetted the entry ACTIVE on one operator's box and QUARANTINED on another's: a
# security verdict on untrusted input decided by the ambient locale, which is the
# exact class the <path> paragraph above refuses, one branch over. Hence the pin.
#
# The GRAMMAR itself is unchanged — indentation is still space/tab, in step with
# promote-intent.sh's reading model (m_class) — and a hidden guard is never accepted,
# only reported. The repair is to re-indent the line with plain spaces directly under
# the entry it vets. promote-intent.sh reads the same three spellings and REFUSES the
# rewrites it cannot express over such a line rather than dropping it (see THE
# CONTRACT in its header).
#
# A NUL BYTE ANYWHERE IN THE FILE makes the WHOLE FILE one unparseable finding,
# before a single line is parsed. `read` stops at a NUL, so
# `guard: test -e go.mod<NUL>; touch W` reached the parser as the in-grammar
# `test -e go.mod`: the entry went ACTIVE and the copy landed in intent-active.md
# was NOT the file's bytes. Nothing executed — the tail after the NUL is invisible,
# not evaluated — but both halves of this script's contract broke at once: the
# active view is supposed to be VERBATIM (Phase 5 quotes it into a re-confirm
# table and promote-intent.sh matches against it), and a file the parser cannot
# see all of must fail CLOSED. WHY the whole file and not the affected entry: the
# parser cannot delimit "the affected entry" — it never sees the bytes that would
# tell it where the damage stops, so any narrower blast radius would be a guess
# about the very bytes it is blind to. A NUL in a hand-written markdown file is
# corruption or an attack, never a typo, and the repair is the same either way, so
# one finding naming the file is the whole useful report. Nothing verbatim is
# copied out of a NUL-carrying file: all three outputs stay byte-clean, because
# Phase 5 reads them back as text.
#
# GIT CONFLICT MARKERS (`<<<<<<< `, a bare `=======`, `>>>>>>> `) refuse the WHOLE
# FILE the same way, and for the same reason — the whole-file precedent is
# deliberate. A conflict-marked intent file holds TWO versions of the same facts
# interleaved, so no entry in it means what it says: the copy above `=======` is a
# fact whose guard may live below it (de-guarded, and this script runs at Phase 5
# START — long before the final gate's conflict-marker scan would ever see the
# file), and every marker line is itself an entry-closer. One reproduction had the
# `<<<<<<< HEAD` side go ACTIVE guardless while the `>>>>>>> theirs` side of the
# SAME fact quarantined — two contradictory verdicts on one fact, in one run.
# Delimiting "the affected entry" is the NUL argument again: the parser cannot know
# which side of the merge the author wants, so it refuses the file and names the
# first marker line. `=======` is matched only as a whole line, which does collide
# with a 7-character setext heading underline — write headings ATX-style (`#`), the
# way promote-intent.sh does.
#
# A UTF-8 BOM at the start of the file is STRIPPED before the first line is parsed
# (that one line only, like the CRLF strip). Left in place, the BOM bytes sat in
# front of the first `- `, so entry #1 was not a bullet at all: it went out as
# column-0 prose and its indented guard was then an orphan — de-guarding the FIRST
# fact of any file a Windows editor had saved. Stripping is preferred over reporting
# it because a BOM is invisible to whoever would have to repair the file, and the
# rest of the file parses identically with or without it. So the verbatim contract
# is verbatim modulo the line terminator and a leading BOM.
#
# The rule is deliberately this narrow: legitimate prose, headings, blank lines
# and thematic breaks are valid structure in this file, and a looser rule would
# flag them. Unparseable lines get their own bucket rather than being folded
# into the quarantine one for the same reason collect-common.sh splits its skip
# reasons: collapsing unrelated causes hides WHY, and forces one recommendation
# column to serve two unrelated causes. Unparseable lines are excluded from
# intent-active.md so they cannot steer a resolution; Phase 5's batched
# re-confirm table absorbs them as extra rows.
#
# Each guard runs against the current tree (cwd = component root, which is why
# paths are relative and must stay inside it). An entry whose
# guard fails is QUARANTINED: the fact describes a state the tree no longer shows,
# so it must not steer any resolution until the user re-confirms it (re-affirm /
# update / retire — one batched question in Phase 5). Guardless entries have no
# tree-checkable shape; they pass through untouched and keep the contradiction
# rule as their backstop (a resolver that sees an entry contradicting the tree
# returns needs-input, never silently applies or drops it).
#
# Everything downstream in the run reads $RUN/intent-active.md — the guard-vetted
# view — never .kairos/intent.md directly; that is what makes the quarantine an
# exclusion instead of a suggestion.
#
# Env in:  ACTION         vet (default) | parse-only. See PARSE-ONLY MODE below;
#                         it is a maintainer/test entry point, not a run step, so
#                         it is deliberately absent from SKILL.md and the phases.
#          RUN            run-state dir (required for ACTION=vet, and an UNSET RUN
#                         is an env error like any other — EXIT 2, not the `${RUN:?}`
#                         shell default of 1, which would collide with parse-only's
#                         grammar-finding exit 1). It must be
#                         creatable and WRITABLE: a vet that cannot write its
#                         verdict has not vetted anything, so an unusable $RUN
#                         EXITS 2 before parsing instead of running to completion.
#                         It used to print counts and findings while every `: >`
#                         failed as shell noise — exit 0, and not one of the three
#                         output files on disk, which Phase 5 reads back as "this
#                         component has no standing intent".
#          INTENT         intent file path (default: .kairos/intent.md). ABSENT is
#                         legitimate — a component with no intent file has no
#                         standing facts, and the vet is empty. A path that EXISTS
#                         and cannot be read as a regular file (permission denied,
#                         a directory, a fifo, a dangling symlink) EXITS 2: `[ -f ]`
#                         is false for all of them, so each one vetted as ABSENT —
#                         ACTIVE=0, three empty outputs, exit 0 — silently dropping
#                         every standing fact the component carries. "No facts" and
#                         "I could not look" must never be the same answer.
#          GUARD_TIMEOUT  seconds each grep guard may run (default: 10, range
#                         1..3600); one that exceeds it counts as FAILED — the entry
#                         is quarantined, as it is for any other non-answer
#                         (unreadable target, missing perl). Only a real 0/1 answer
#                         is invertible by a leading `!`; "unknown" is never
#                         laundered into a pass. Guards are tree assertions; one
#                         that needs longer is not a guard, and a hang here would
#                         block the whole run. Only grep guards are alarm-wrapped;
#                         path tests are answered in-process by the shell builtin
#                         and are NOT wrapped — normally that is instantaneous, but
#                         it is not an unconditional "cannot hang": `test -e`/`-f`
#                         on a path under a hung NFS/FUSE mount blocks
#                         uninterruptibly in the kernel, with no alarm to kill it.
#                         Known residual, not fixed here (see run_guard's comment).
#                         An out-of-range or non-numeric value EXITS 2 at startup
#                         instead of defaulting: the value reached `perl -e 'alarm
#                         shift'` unchecked, and `alarm abc` and `alarm 0` both mean
#                         NO ALARM — so a typo silently removed the only thing
#                         standing between a fifo guard and a wedged Phase 5, which
#                         is the opposite of what this variable exists for. An
#                         unset or empty value is not a typo, and keeps the default.
# Out:     $RUN/intent-active.md       entries whose guards all passed + guardless
#                                      entries, verbatim, plus non-entry structure
#          $RUN/intent-quarantined.md  entries with a failing guard, verbatim
#          $RUN/intent-unparseable.md  unparseable lines, verbatim, plus entries
#                                      whose guard is outside the grammar
#          stdout: ACTIVE=<n> / QUARANTINED=<n> / UNPARSEABLE=<n>
#          stderr: one QUARANTINED: line per quarantined entry, naming the guard;
#                  one UNPARSEABLE: line per finding, naming the reason
# Exit:    0 always when RUN is set and the env is valid (quarantine and unparseable
#          are findings, not errors); all three output files exist afterwards even
#          when the intent file is absent. 2 for an invalid ACTION or GUARD_TIMEOUT,
#          an unusable RUN dir, or an intent path that exists and cannot be read
#          (env the caller broke — nothing is vetted, and on exit 2 the three output
#          files are NOT promised: the intent-path check runs before any of them is
#          created, so an unusable path leaves nothing half-written behind).
#
# ---------------------------------------------------------------------------
# PARSE-ONLY MODE — `ACTION=parse-only`, guards on stdin, one per line
# ---------------------------------------------------------------------------
# Answers "is this text in the guard grammar?" and nothing else. No RUN, no intent
# file, no tree access, no guard evaluated, no output file written — so an
# in-grammar guard naming a missing file, or a fifo, is `ok` (the question is about
# the TEXT). Blank and whitespace-only lines carry no guard and are skipped — the
# deliberate asymmetry with the intent file, where `guard:` with an empty value is an
# author asserting a constraint and failing to state it. Each line is trimmed at both
# ends, which takes a trailing CR with it, so a caller piping CRLF lines gets the same
# verdicts as the vetting path (an interior CR is out of grammar in both).
#   stdout: one TAB-separated row per non-blank input line —
#           `ok<TAB><guard>` or `unparseable<TAB><guard><TAB><reason>`
#   exit:   0 when every line was in grammar, 1 when any was not, 2 on usage error
#
# WHY it exists: the suite's doc-example lint used to carry a SECOND grammar — a
# regex accepting any line starting `test`/`grep` — which passed `grep -qr needle
# web` and never looked at agents/. Two grammars drift, and the laxer one is the
# one that green-lights a doc example that a real run then reports UNPARSEABLE. The
# lint now pipes every `guard:` example the skill ships through THIS mode, so the
# parser below is the single source of truth for the runner and the lint alike.
set -u

# LC_ALL=C IS PINNED FOR THE WHOLE SCRIPT, and it is a correctness fix rather than
# tidiness: every bucket this parser puts a line in is a verdict about UNTRUSTED
# committed input, and the character classes a shell pattern can use are not the same
# SET OF BYTES in every locale. An NBSP is `[[:space:]]` under en_US.UTF-8 and is not
# under C, which is how `<SP><NBSP>guard:` came out ACTIVE on one operator's box and
# QUARANTINED on another's from the same file (see HIDDEN GUARDS in the header). Under
# the pin every class below is a fixed set of bytes on every machine, and the guards
# this script execs inherit it — which is what the grammar already assumes, since a
# guard's pattern and path are printable ASCII by rule.
# The pin is a SECOND belt, never a licence: the literal allowlists (PATH_CHARS,
# PRINTABLE_ASCII) stay literal, because a `[A-Za-z0-9…]` range would be one exported
# variable away from being collation-dependent again.
LC_ALL=C
export LC_ALL

ACTION="${ACTION:-vet}"
case "$ACTION" in
  vet|parse-only) ;;
  *) printf 'ERROR: ACTION=%s is not supported (vet | parse-only)\n' "$ACTION" >&2; exit 2 ;;
esac

# GUARD_TIMEOUT is validated before anything else runs — see Env in above. The digit
# test lists its characters literally for the same reason path_ok does: `[0-9]` is a
# collation range, and this verdict must not depend on the operator's locale.
GUARD_TIMEOUT="${GUARD_TIMEOUT:-10}"
case "$GUARD_TIMEOUT" in
  *[!0123456789]*|'')
    printf 'ERROR: GUARD_TIMEOUT=%s is not a positive integer (seconds, 1..3600)\n' \
      "$GUARD_TIMEOUT" >&2
    exit 2 ;;
esac
# The LENGTH gate runs before the numeric compare: an all-digit value >= 2^63
# makes `[ … -gt 3600 ]` ERROR rather than return true (rc 2 reads as false in an
# `||` chain), so the range check passed it and the value reached `alarm`, where
# it wrapped to NO alarm at all — a fifo guard then wedged the sweep forever, the
# exact failure the timeout exists to prevent. Anything longer than 4 digits is
# out of range without arithmetic ever running on it.
if [[ "${#GUARD_TIMEOUT}" -gt 4 ]] \
   || [[ "$GUARD_TIMEOUT" -lt 1 ]] || [[ "$GUARD_TIMEOUT" -gt 3600 ]]; then
  printf 'ERROR: GUARD_TIMEOUT=%s is out of range (seconds, 1..3600)\n' "$GUARD_TIMEOUT" >&2
  exit 2
fi

if [[ "$ACTION" = vet ]]; then
  # Unset RUN is an env error, EXIT 2 like every other broken-env case here — NOT
  # the `${RUN:?}` shell default of 1, which is parse-only's grammar-finding code.
  RUN="${RUN:-}"
  [[ -n "$RUN" ]] || { printf 'ERROR: RUN dir required\n' >&2; exit 2; }
else
  RUN="${RUN:-}"
fi
INTENT="${INTENT:-.kairos/intent.md}"

# --- guard grammar (see GUARD TRUST MODEL in the header) ----------------------
# guard_parse fills these; nothing else writes them. GUARD_ARGV is the validated
# argv — the guard text never travels as a string past this point.
GUARD_KIND=""     # test | grep
GUARD_ARGV=()     # argv[0] is the command
GUARD_NEG=0       # 1 when a leading `!` inverts the result
GUARD_REJECT=""   # why the guard is out of grammar (empty when in grammar)

# PATH_CHARS — the path charset as a literal string, not a glob range. Matching a
# single character against a substring of this is byte-for-byte equality in every
# locale, whereas `*[!A-Za-z0-9._/+@-]*` asks LC_COLLATE what falls between A and Z
# and gets a different answer on macOS en_US.UTF-8 than under LC_ALL=C (header:
# <path>). Keep it a literal list.
PATH_CHARS='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/+@-'

# PRINTABLE_ASCII — every byte 0x20..0x7E as a literal string, the grep-PATTERN analog
# of PATH_CHARS. A pattern is a BRE and legitimately carries regex metacharacters a path
# may not, so it gets a WIDER allowlist — but still ASCII, and still no control byte. That
# is what keeps an interior CR/VT/FF, an NBSP, or any other non-ASCII byte out of a guard
# the active view copies VERBATIM and Phase 5 quotes back to the user (a mid-line CR can
# visually overwrite terminal text). Built with printf octal escapes so no byte needs
# shell-quoting and the set is byte-identical in every locale — the same discipline BOM/CR
# get elsewhere; never a `[[:print:]]`/`[[:cntrl:]]` class or a range, both collation-
# dependent (header: <path>).
PRINTABLE_ASCII=''
_pa_d=32
while [[ "$_pa_d" -le 126 ]]; do
  printf -v _pa_c "\\$(printf '%03o' "$_pa_d")"
  PRINTABLE_ASCII="$PRINTABLE_ASCII$_pa_c"
  _pa_d=$((_pa_d + 1))
done
unset _pa_d _pa_c

# path_charset_ok <token> — 0 when every character of the token is in PATH_CHARS.
# One character at a time: in a UTF-8 locale ${s:0:1} yields a whole multibyte
# character and in C locale a single byte, and neither is ever a substring of an
# ASCII-only allowlist — so non-ASCII is refused either way, which is the point.
path_charset_ok() {
  local s=$1 c
  while [[ -n "$s" ]]; do
    c=${s:0:1}; s=${s:1}
    case "$PATH_CHARS" in
      *"$c"*) ;;                 # quoted: a glob metacharacter matches literally
      *) return 1 ;;
    esac
  done
  return 0
}

# path_ok <token> — a path the guard may look at: relative, inside the component
# tree, and spelled in a charset that leaves globbing and quoting no foothold.
path_ok() {
  case "$1" in
    '')  GUARD_REJECT="the path is empty"; return 1 ;;
    -*)  GUARD_REJECT="path '$1' starts with '-', which would read as an option"; return 1 ;;
    /*)  GUARD_REJECT="path '$1' is absolute — guards may only assert the component tree"; return 1 ;;
    ..|../*|*/..|*/../*)
         GUARD_REJECT="path '$1' escapes the component tree via '..'"; return 1 ;;
  esac
  if ! path_charset_ok "$1"; then
    GUARD_REJECT="path '$1' uses characters outside [A-Za-z0-9._/+@-] — globs, quoting and whitespace are not in the guard grammar"
    return 1
  fi
  return 0
}

# pattern_charset_ok <token> — 0 when every character of the pattern is printable
# ASCII (0x20..0x7E). The grep-pattern analog of path_charset_ok, one character at a
# time and for the identical locale reason: ${s:0:1} yields a whole multibyte character
# in a UTF-8 locale and a single byte in C, and neither a control byte nor any non-ASCII
# byte is ever a substring of an ASCII-only allowlist — so both are refused either way.
pattern_charset_ok() {
  local s=$1 c
  while [[ -n "$s" ]]; do
    c=${s:0:1}; s=${s:1}
    case "$PRINTABLE_ASCII" in
      *"$c"*) ;;                 # quoted: a glob metacharacter matches literally
      *) return 1 ;;
    esac
  done
  return 0
}

# pattern_ok <token> — a grep pattern. It can never reach a shell (grep is exec'd
# with this as argv), but a pattern indistinguishable from a shell command is
# refused anyway: a reviewer of .kairos/intent.md must be able to tell at a glance
# that a guard line cannot run anything. It must also be printable ASCII: a header
# claim in three places (CRLF, the path charset, the NUL/marker whole-file refusals)
# is that an interior CR and any non-ASCII byte are out of grammar, and this is where
# a PATTERN carrying one is caught — otherwise the raw byte rides a passing guard into
# the active view intent-active.md, verbatim, and Phase 5 quotes it to the user.
pattern_ok() {
  case "$1" in
    '')  GUARD_REJECT="the grep pattern is empty"; return 1 ;;
    -*)  GUARD_REJECT="pattern '$1' starts with '-', which would read as an option"; return 1 ;;
    *'$('*|*'${'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'\'*|*"'"*|*'"'*)
         GUARD_REJECT="pattern '$1' contains shell syntax — guards are not shell, and a guard that looks like one is refused"; return 1 ;;
  esac
  if ! pattern_charset_ok "$1"; then
    GUARD_REJECT="pattern '$1' carries a control or non-ASCII byte (an interior CR/VT/FF, an NBSP, or any byte outside printable ASCII) — out of grammar, so it cannot ride a passing guard into the active view verbatim where Phase 5 quotes it back to you"
    return 1
  fi
  return 0
}

# guard_parse <guard-text> — 0 and GUARD_* set when the guard is in grammar;
# 1 and GUARD_REJECT set otherwise. Tokenizing here (never by the shell) is the
# whole security boundary: an unknown token can only ever be rejected, never run.
guard_parse() {
  GUARD_KIND=""; GUARD_ARGV=(); GUARD_NEG=0; GUARD_REJECT=""
  # The length cap runs FIRST, because the per-character loops below
  # (path_charset_ok, the grep-flag walk) re-slice the token with ${s:0:1} and are
  # QUADRATIC — parsing, so GUARD_TIMEOUT does not bound them: a single mangled
  # 30KB guard line (a bad paste) cost ~30 seconds, and a 1MB one extrapolates to
  # hours, wedging Phase 5 before any guard runs. No in-grammar guard needs
  # anything near 4096 characters, so past it the verdict is already known.
  if [[ "${#1}" -gt 4096 ]]; then
    GUARD_REJECT="the guard is ${#1} characters long — no in-grammar guard needs more than 4096, and an unbounded token would wedge the parser before any guard runs"
    return 1
  fi
  local toks=() n i j flags="" f c
  IFS=$' \t' read -r -a toks <<< "$1"
  n=${#toks[@]}
  if [[ "$n" -eq 0 ]]; then GUARD_REJECT="the guard is empty"; return 1; fi
  i=0
  if [[ "${toks[0]}" = '!' ]]; then GUARD_NEG=1; i=1; fi
  if [[ "$i" -ge "$n" ]]; then GUARD_REJECT="'!' with no assertion after it"; return 1; fi

  case "${toks[$i]}" in
    test)
      GUARD_KIND=test
      GUARD_ARGV=(test)
      j=$((i + 1))
      if [[ "$j" -lt "$n" ]] && [[ "${toks[$j]}" = '!' ]]; then
        GUARD_ARGV+=('!'); j=$((j + 1))
      fi
      if [[ "$((n - j))" -ne 2 ]]; then
        GUARD_REJECT="'test' takes exactly [!] -e|-f|-d|-s <relative-path>"
        return 1
      fi
      case "${toks[$j]}" in
        -e|-f|-d|-s) ;;
        *) GUARD_REJECT="'${toks[$j]}' is not an allowed test operator (only -e -f -d -s)"; return 1 ;;
      esac
      path_ok "${toks[$((j + 1))]}" || return 1
      GUARD_ARGV+=("${toks[$j]}" "${toks[$((j + 1))]}")
      ;;
    grep)
      GUARD_KIND=grep
      j=$((i + 1))
      while [[ "$j" -lt "$n" ]]; do
        case "${toks[$j]}" in
          -*) f=${toks[$j]#-}
              if [[ -z "$f" ]]; then GUARD_REJECT="bare '-' is not a grep flag"; return 1; fi
              while [[ -n "$f" ]]; do
                c=${f:0:1}; f=${f:1}
                case "$c" in
                  q|F) flags="$flags$c" ;;
                  *) GUARD_REJECT="grep flag '-$c' is not in the guard grammar (only -q, optionally with F)"; return 1 ;;
                esac
              done
              j=$((j + 1)) ;;
          *)  break ;;
        esac
      done
      case "$flags" in
        *q*) ;;
        *) GUARD_REJECT="a grep guard must be quiet: 'grep -q <pattern> <relative-path>'"; return 1 ;;
      esac
      if [[ "$((n - j))" -ne 2 ]]; then
        GUARD_REJECT="'grep' takes exactly -q[F] <pattern> <relative-path>"
        return 1
      fi
      pattern_ok "${toks[$j]}"      || return 1
      path_ok    "${toks[$((j + 1))]}" || return 1
      GUARD_ARGV=(grep)
      case "$flags" in *F*) GUARD_ARGV+=(-F) ;; esac
      # -e keeps the pattern out of the option namespace even if the charset rules
      # above are ever relaxed.
      GUARD_ARGV+=(-q -e "${toks[$j]}" "${toks[$((j + 1))]}")
      ;;
    *)
      GUARD_REJECT="'${toks[$i]}' is not an allowed guard command (only 'test' and 'grep -q')"
      return 1 ;;
  esac
  return 0
}

# run_guard — evaluate the guard guard_parse just accepted: 0 = the tree still
# shows what the fact claims. Called only after a successful parse, so GUARD_ARGV
# is populated and holds nothing but validated tokens.
#
# Path tests go through the shell's own `test` builtin on those tokens: no fork, no
# /bin/test dependency, and no alarm wrapper — in the overwhelmingly common case
# (local/tmpfs paths) that is effectively instantaneous, but it is a KNOWN RESIDUAL,
# not a guarantee: a `test -e`/`-f` against a path under a hung NFS/FUSE mount
# blocks uninterruptibly in the kernel, and nothing here can alarm it loose (see
# THE RESIDUAL block near the top of this file). grep can block too (a huge file, a
# fifo, a stalled network mount), so it keeps the wall-clock limit — perl's alarm
# is the portable timeout on macOS (no coreutils timeout(1)); exceeding it kills
# the guard and reads as failure, so a hanging guard quarantines its entry instead
# of blocking Phase 5 forever. `exec @ARGV` with a multi-element list never goes
# through a shell, which is what makes the direct invocation direct.
run_guard() {
  local rc
  if [[ "$GUARD_KIND" = test ]]; then
    if test "${GUARD_ARGV[@]:1}"; then rc=0; else rc=1; fi
  else
    # The rc=$? step keeps bash from exec-flattening the subshell, so the
    # subshell (stderr on /dev/null) is what reaps the SIGALRM-killed guard and
    # the script's own stderr never shows an "Alarm clock" job notice.
    ( perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' \
        "$GUARD_TIMEOUT" "${GUARD_ARGV[@]}" </dev/null >/dev/null 2>&1; rc=$?; exit "$rc" ) 2>/dev/null
    rc=$?
  fi
  # Only 0 and 1 are ANSWERS. Anything else means the assertion never ran to a
  # verdict: grep's 2 (unreadable target), the SIGALRM kill on GUARD_TIMEOUT, 127
  # for a missing perl. "Unknown" must fail closed, and `!` unknown is still
  # unknown — without this, the same hang that quarantines an entry would ACTIVATE
  # it the moment its guard was written with a leading `!`.
  if [[ "$rc" -ne 0 ]] && [[ "$rc" -ne 1 ]]; then return 1; fi
  if [[ "$GUARD_NEG" = 1 ]]; then
    if [[ "$rc" -eq 0 ]]; then rc=1; else rc=0; fi
  fi
  return "$rc"
}

# --- ACTION=parse-only (see PARSE-ONLY MODE in the header) --------------------
# Exits here: guard_parse is the only thing consulted, so nothing below this block
# — no tree access, no output file, no guard evaluation — can run in this mode.
if [[ "$ACTION" = parse-only ]]; then
  PARSE_BAD=0
  while IFS= read -r pline || [[ -n "$pline" ]]; do
    # Trim both ends; a blank or whitespace-only line carries no guard at all.
    pline="${pline#"${pline%%[![:space:]]*}"}"
    pline="${pline%"${pline##*[![:space:]]}"}"
    [[ -n "$pline" ]] || continue
    if guard_parse "$pline"; then
      printf 'ok\t%s\n' "$pline"
    else
      PARSE_BAD=1
      printf 'unparseable\t%s\t%s\n' "$pline" "$GUARD_REJECT"
    fi
  done
  exit "$PARSE_BAD"
fi

# --- the vet's environment: a readable intent path and a writable run dir --------
# Both are HARD errors (exit 2), not findings, and both are settled before a byte is
# written — see Env in / Exit in the header for why neither may round to an empty
# vet. The intent path is checked FIRST so that an unusable one leaves no
# half-written output behind at all.
#
# `-e || -L` covers the dangling symlink, which `-e` alone reads as absent: a
# symlink at the intent path pointing nowhere is a broken environment, not a
# component without standing intent.
if [[ -e "$INTENT" ]] || [[ -L "$INTENT" ]]; then
  INTENT_WHY=""
  if [[ -d "$INTENT" ]]; then
    INTENT_WHY="it is a directory"
  elif [[ ! -f "$INTENT" ]]; then
    INTENT_WHY="it is not a regular file (a fifo, socket, device, or a symlink pointing nowhere)"
  elif [[ ! -r "$INTENT" ]]; then
    INTENT_WHY="it is not readable (permission denied)"
  fi
  if [[ -n "$INTENT_WHY" ]]; then
    printf 'ERROR: intent file %s exists but cannot be read: %s. Every standing fact would vet as absent, so nothing was vetted — fix the path or its permissions (removing it entirely is the legitimate "no standing intent") and re-run.\n' \
      "$INTENT" "$INTENT_WHY" >&2
    exit 2
  fi
fi

mkdir -p "$RUN" 2>/dev/null || true
ACTIVE_OUT="$RUN/intent-active.md"
QUAR_OUT="$RUN/intent-quarantined.md"
UNPARSE_OUT="$RUN/intent-unparseable.md"
if [[ ! -d "$RUN" ]]; then
  printf 'ERROR: run dir %s is not a directory and could not be created — nothing was vetted\n' \
    "$RUN" >&2
  exit 2
fi
for f in "$ACTIVE_OUT" "$QUAR_OUT" "$UNPARSE_OUT"; do
  # The braces matter: `: > "$f" 2>/dev/null` applies its redirections left to right,
  # so the failing one reports before stderr is silenced and the raw "Permission
  # denied" shows up next to the message that explains it.
  { : > "$f"; } 2>/dev/null || {
    printf 'ERROR: cannot write %s (run dir %s is not writable) — nothing was vetted\n' \
      "$f" "$RUN" >&2
    exit 2
  }
done

ACTIVE_N=0
QUAR_N=0
UNPARSE_N=0
TAB=$(printf '\t')
# SPTAB — the indentation grammar as a two-byte literal, for the bracket set in
# hidden_guard. A literal set and not a range, for the reason PATH_CHARS carries.
SPTAB=" $TAB"

# die_write <file> — the fail-CLOSED handler for a bucket append that did not land.
# The buckets are the findings Phase 5 reads back, so a short write (ENOSPC, or a $RUN
# removed after the startup probe) that left the counts saying more than the file holds
# would under-report the findings and still exit 0 — the same "counts printed, file not
# on disk" fail-open the ACTIVE_OUT write and the `: >` truncation probe both refuse.
# Only the error branch is factored: the `>> "$QUAR_OUT"`/`>> "$UNPARSE_OUT"` redirect
# stays inline through its named variable at each site, so it reads (and is auditable)
# as a direct write to the artifact its owner declares.
die_write() {
  printf 'ERROR: could not write %s (run dir %s became unwritable mid-vet) — the finding counts would overstate what landed on disk; fix disk space or permissions on %s and re-run\n' \
    "$1" "$RUN" "$RUN" >&2
  exit 2
}

unparseable() {  # unparseable <line> <reason> — record a finding, keep going
  UNPARSE_N=$((UNPARSE_N + 1))
  printf '%s\n' "$1" >> "$UNPARSE_OUT" || die_write "$UNPARSE_OUT"
  printf 'UNPARSEABLE: %s (%s)\n' "$1" "$2" >&2
}

# ACTIVE_BUF — the active view, held in memory and written once at the end. The
# other two buckets are appended as they are found; this one cannot be, because an
# orphaned guard RETRACTS an entry already emitted (see ORPHANED GUARDS in the
# header): the parser only learns the entry was de-guarded when it reaches a line
# BELOW it.
ACTIVE_BUF=()
emit_active() { ACTIVE_BUF+=("$1"); }

# Buffered current entry.
entry_lines=()
entry_guards=()

# LAST_ENTRY_* — the most recently flushed entry, IF it went active: where its lines
# sit in ACTIVE_BUF, and the lines themselves. Cleared as soon as an entry lands in
# any other bucket (nothing to retract — it is already excluded) and after a
# retraction (so two orphaned guards in a row cannot strand it twice).
LAST_ENTRY_ACTIVE=0
LAST_ENTRY_START=0
LAST_ENTRY_LINES=()

# retract_last_entry — splice the last active entry's lines back out of the active
# view. Structure lines that followed it (the `---` or heading that closed it) are
# NOT retracted: they are structure whatever happens to the entry.
retract_last_entry() {
  local i=0 n=${#ACTIVE_BUF[@]} end keep=()
  end=$((LAST_ENTRY_START + ${#LAST_ENTRY_LINES[@]}))
  while [[ "$i" -lt "$n" ]]; do
    if [[ "$i" -lt "$LAST_ENTRY_START" ]] || [[ "$i" -ge "$end" ]]; then
      keep+=("${ACTIVE_BUF[$i]}")
    fi
    i=$((i + 1))
  done
  ACTIVE_BUF=(${keep[@]+"${keep[@]}"})
  ACTIVE_N=$((ACTIVE_N - 1))
}

# orphan_guard <line> <reason> — a `guard:` line no entry owns, at column 0 or
# indented. Reports the guard AND excludes the entry it was meant to vet, per the
# attachment rule in the header. One function for both spellings on purpose: the
# damage and the repair are identical, so the two must not drift.
orphan_guard() {
  local eline
  if [[ "${#entry_lines[@]}" -gt 0 ]]; then
    UNPARSE_N=$((UNPARSE_N + 1))
    for eline in "${entry_lines[@]}"; do printf '%s\n' "$eline" >> "$UNPARSE_OUT" || die_write "$UNPARSE_OUT"; done
    printf 'UNPARSEABLE: %s (entry precedes an orphaned guard — the guard never ran, so the entry is excluded until re-confirmed)\n' "${entry_lines[0]}" >&2
    entry_lines=()
    entry_guards=()
  elif [[ "$LAST_ENTRY_ACTIVE" = 1 ]]; then
    # The de-guarded entry is already in the active view: take it back out.
    retract_last_entry
    UNPARSE_N=$((UNPARSE_N + 1))
    for eline in "${LAST_ENTRY_LINES[@]}"; do printf '%s\n' "$eline" >> "$UNPARSE_OUT" || die_write "$UNPARSE_OUT"; done
    printf 'UNPARSEABLE: %s (entry precedes an orphaned guard — the guard never ran, so the entry is excluded until re-confirmed)\n' "${LAST_ENTRY_LINES[0]}" >&2
    LAST_ENTRY_ACTIVE=0
    LAST_ENTRY_LINES=()
  fi
  # A gap before an orphaned guard is structure: the guard is an orphan either way,
  # so nothing attaches to it.
  release_blanks
  unparseable "$1" "$2"
}

# BLANKS_HELD — blank lines seen while an entry is still open (see BLANK LINES in
# the header). They are HELD rather than settling the entry: an indented
# continuation after the gap still belongs to the entry above, and if anything else
# follows they are released into the active view exactly where they stood.
BLANKS_HELD=0
release_blanks() {
  while [[ "$BLANKS_HELD" -gt 0 ]]; do
    emit_active ""
    BLANKS_HELD=$((BLANKS_HELD - 1))
  done
}

flush_entry() {
  if [[ "${#entry_lines[@]}" -eq 0 ]]; then release_blanks; return 0; fi
  local verdict=active failed_guard="" bad_guard="" reject="" g
  # Pass 1 — every guard must be READABLE before any guard is evaluated. One
  # unreadable guard means the entry cannot be vetted at all, so the verdict must
  # not depend on which guard the author happened to list first (and nothing runs
  # for an entry we are about to exclude anyway).
  for g in ${entry_guards[@]+"${entry_guards[@]}"}; do
    if ! guard_parse "$g"; then
      verdict=unparseable
      bad_guard="$g"
      reject="$GUARD_REJECT"
      break
    fi
  done
  # Pass 2 — evaluate. ALL guards must pass for the entry to stay active.
  if [[ "$verdict" = active ]]; then
    for g in ${entry_guards[@]+"${entry_guards[@]}"}; do
      guard_parse "$g"
      if ! run_guard; then
        verdict=quarantined
        failed_guard="$g"
        break
      fi
    done
  fi
  local line
  if [[ "$verdict" = active ]]; then
    ACTIVE_N=$((ACTIVE_N + 1))
    # Remember where this entry lands: an orphaned guard below it retracts it.
    LAST_ENTRY_START=${#ACTIVE_BUF[@]}
    LAST_ENTRY_LINES=("${entry_lines[@]}")
    LAST_ENTRY_ACTIVE=1
    for line in "${entry_lines[@]}"; do emit_active "$line"; done
  elif [[ "$verdict" = quarantined ]]; then
    LAST_ENTRY_ACTIVE=0   # already excluded: nothing for an orphan to retract
    QUAR_N=$((QUAR_N + 1))
    for line in "${entry_lines[@]}"; do printf '%s\n' "$line" >> "$QUAR_OUT" || die_write "$QUAR_OUT"; done
    printf 'QUARANTINED: %s (guard failed: %s)\n' "${entry_lines[0]}" "$failed_guard" >&2
  else
    LAST_ENTRY_ACTIVE=0   # already excluded: nothing for an orphan to retract
    UNPARSE_N=$((UNPARSE_N + 1))
    for line in "${entry_lines[@]}"; do printf '%s\n' "$line" >> "$UNPARSE_OUT" || die_write "$UNPARSE_OUT"; done
    printf 'UNPARSEABLE: %s (guard outside the allowed grammar — '\''%s'\'': %s; the guard never ran, so the entry is excluded until re-confirmed)\n' \
      "${entry_lines[0]}" "$bad_guard" "$reject" >&2
  fi
  entry_lines=()
  entry_guards=()
  release_blanks
}

# nul_count <file> — how many NUL bytes the file carries. Byte-count difference
# rather than grep: no portable grep flag reports a NUL match on both BSD and GNU
# userlands, whereas `tr -d` and `wc -c` behave identically on both under LC_ALL=C.
nul_count() {
  local total stripped
  total=$(( $(wc -c < "$1") ))
  stripped=$(( $(LC_ALL=C tr -d '\000' < "$1" | wc -c) ))
  printf '%s\n' "$((total - stripped))"
}

# conflict_marker <file> — `<line-number>:<line>` for the first git conflict marker
# in the file, or nothing. `=======` matches only as a WHOLE line (trailing
# whitespace and a CR tolerated, so a CRLF checkout reads the same); the start and
# end markers carry a label, hence the mandatory space. LC_ALL=C keeps the classes
# byte-wise. See GIT CONFLICT MARKERS in the header.
conflict_marker() {
  LC_ALL=C grep -n -m1 -E '^(<<<<<<< |=======[[:space:]]*$|>>>>>>> )' "$1" 2>/dev/null || true
}

# BOM — the UTF-8 byte-order mark, built with printf's octal escapes rather than
# `$'\xef…'` so bash 3.2 and 5 agree on the bytes. Stripped from the FIRST line
# only (see the UTF-8 BOM paragraph in the header).
BOM=$(printf '\357\273\277')

# hidden_guard <line> — 0 when the line's first GRAPHIC content is `guard:` and the
# bytes in front of it are NOT an indentation this grammar reads. That is the whole of
# the HIDDEN GUARDS rule in the header, and it is the only place it is implemented:
#
#   LEAD = the leading run of bytes that are not graphic ASCII (0x21..0x7E)
#   REST = the remainder
#   hidden  <=>  REST begins `guard:`  AND  LEAD is non-empty  AND  LEAD carries a
#                byte that is neither a space nor a tab
#
# So a column-0 `guard:` (LEAD empty) and a plainly indented one (LEAD all space/tab)
# are NOT hidden — they are the two spellings the case statement below already reads —
# and everything else in front of a `guard:` is. Detection only: nothing here ever
# ACCEPTS a line, the indentation grammar stays space/tab (promote-intent.sh's
# m_class must stay in step with this parser), and a hidden guard is routed to
# orphan_guard, never evaluated.
#
# WHY this shape and not a byte list. Its predecessor stripped a hard-coded six-byte
# whitespace-variant prefix and let every other byte fall through to prose, which
# missed U+200B and U+3000 outright (header: HIDDEN GUARDS). It was also SUPERLINEAR
# and unbounded: `"$(printf '\v')"*` inside the loop forked three subshells per byte
# stripped, at classification time — BEFORE guard_parse's 4096-char cap and outside
# GUARD_TIMEOUT — so one 30KB mis-indented line cost ~38 seconds and a megabyte of
# them wedged Phase 5 before a single guard ran. Two parameter expansions replace the
# loop: `%%` scans the lead once (the `*` tail of `[[:graph:]]*` cannot backtrack) and
# `#` removes it by its own bytes, so a multibyte NBSP goes by its bytes whatever the
# locale calls one character, and no subshell is forked at all.
hidden_guard() {
  local lead rest
  lead=${1%%[[:graph:]]*}          # nothing graphic in the line: LEAD is the line
  [[ -n "$lead" ]] || return 1       # column-0 `guard:` — the case statement has it
  case "$lead" in
    *[!"$SPTAB"]*) ;;              # a byte the indentation grammar does not read
    *) return 1 ;;                 # plain space/tab: the sanctioned indented path
  esac
  rest=${1#"$lead"}
  case "$rest" in 'guard:'*) return 0 ;; esac
  return 1
}

# Whole-file refusals, decided before a single line is parsed: a file the parser
# cannot see all of (NUL), or one that holds two interleaved versions of the same
# facts (conflict markers), fails CLOSED as ONE finding naming the file. Nothing
# verbatim is copied out of either, so all three outputs stay byte-clean.
FILE_REFUSAL=""
if [[ -f "$INTENT" ]]; then
  NULS=$(nul_count "$INTENT")
  if [[ "$NULS" -gt 0 ]]; then
    FILE_REFUSAL="it carries $NULS NUL byte(s), which the line parser cannot read past — no entry can be vetted and no line can be copied verbatim, so the entire file is excluded until the NUL bytes are removed"
  else
    MARKER=$(conflict_marker "$INTENT")
    if [[ -n "$MARKER" ]]; then
      FILE_REFUSAL="it carries git conflict markers (line ${MARKER%%:*}: '${MARKER#*:}') — an unresolved merge holds two versions of the same facts interleaved, so an entry can be split from its guard and no entry in it can be vetted; resolve the conflict and re-run"
    fi
  fi
fi

if [[ -n "$FILE_REFUSAL" ]]; then
  unparseable "$INTENT: the whole file" "$FILE_REFUSAL"
elif [[ -f "$INTENT" ]]; then
  FIRST_LINE=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    # One trailing CR off each line — a CRLF checkout is the same file (see CRLF in
    # the header). Trailing ONLY, and never a whole-file `tr -d '\r'`: an interior CR
    # is not a line ending, and splicing what follows it into the guard would be the
    # NUL smuggling case again.
    line=${line%$'\r'}
    if [[ "$FIRST_LINE" = 1 ]]; then
      FIRST_LINE=0
      line=${line#"$BOM"}   # a leading BOM must not stop entry #1 being a bullet
    fi
    # HIDDEN GUARDS come FIRST, before any other classification (see the header): a
    # line whose first graphic content is `guard:` behind bytes the indentation
    # grammar does not read is not prose and not structure, whichever branch below
    # would otherwise have taken it. Both branches that USED to take one failed open:
    # a lead the six-byte list did not name (U+200B, U+3000) fell through the column-0
    # catch-all as structure, and a lead that merely STARTED with a space
    # (`<SP><NBSP>guard:`) landed in the indented branch, where a `[[:space:]]` glob
    # decided guard-ness differently in a UTF-8 locale than under C. Routing the whole
    # class here — reported, entry excluded, one rule for all of it — is what makes
    # the verdict fail closed and makes it the same verdict on every machine.
    if hidden_guard "$line"; then
      orphan_guard "$line" "orphaned guard: it is indented with bytes the grammar does not read as indentation — a whitespace variant (NBSP, vertical tab, form feed, stray CR) or another invisible/non-ASCII byte (U+200B, U+3000, …), possibly behind plain spaces — so no entry owns it and its assertion never ran; re-indent it with plain spaces directly under the entry it vets"
      continue
    fi
    # A CommonMark thematic break may SPACE OUT its dashes (`- - -`, `-  -  -`). It
    # begins with `- `, so the bullet arm below would take it and parse a phantom
    # `- -` fact — an extra ACTIVE entry, and worse: when the break sits between an
    # entry and its indented guard, `flush_entry` strands the entry GUARDLESS and the
    # guard then attaches to the phantom — a silent de-guard, the exact failure the
    # orphaned-guard machinery exists to prevent. Only the dash form reaches the
    # bullet arm (`***`/`___` fall through the column-0 catch-all as structure
    # already), so intercept it here and treat it as structure, exactly like the bare
    # `---` arm below — `flush_entry` first, because a break closes the open entry
    # (whose guard stays with it). promote-intent.sh's m_class classes the same shape
    # as a `closer` for the same reason, so the reader and the writer still agree.
    if [[ "$line" =~ ^(-[[:blank:]]*){3,}$ ]]; then
      flush_entry
      emit_active "$line"
      continue
    fi
    case "$line" in
      '- '*)                       # a new entry begins; settle the previous one
        flush_entry
        entry_lines=("$line")
        ;;
      'guard:'*)                   # orphaned guard at column 0: no entry owns it
        # The guard was almost certainly meant to vet the entry it follows, whether
        # that entry is still open or was already closed by a line between them —
        # orphan_guard applies the one attachment rule for both.
        orphan_guard "$line" "orphaned guard: no entry owns it (an entry's guard is an INDENTED continuation of it)"
        ;;
      '* '*|'+ '*)                 # bullet-like marker that is not '- '
        flush_entry
        unparseable "$line" "bullet marker is not '- '"
        ;;
      '-'*)                        # '-' with no space (thematic breaks exempt)
        flush_entry
        # Trailing whitespace tolerated on a thematic break: `--- ` is the same
        # valid markdown structure as `---`, and reporting it "bullet marker '-'
        # without a following space" both misnames the line and invites a
        # sanctioned-looking hand-delete of a structural line. promote-intent.sh
        # reads either spelling as a closer, so the two parsers agree.
        if [[ "$line" =~ ^---+[[:space:]]*$ ]]; then
          emit_active "$line"                      # ---, ----, "--- ", …: structure
        else
          unparseable "$line" "bullet marker '-' without a following space"
        fi
        ;;
      '')                          # blank line: held while an entry is open
        if [[ "${#entry_lines[@]}" -gt 0 ]]; then
          BLANKS_HELD=$((BLANKS_HELD + 1))
        else
          emit_active ""
        fi
        ;;
      ' '*|"$TAB"*)                # indented: continuation of the current entry
        stripped="${line#"${line%%[![:space:]]*}"}"
        if [[ "${#entry_lines[@]}" -gt 0 ]]; then
          # A gap before a continuation belongs to the ENTRY, verbatim and in place.
          while [[ "$BLANKS_HELD" -gt 0 ]]; do
            entry_lines+=("")
            BLANKS_HELD=$((BLANKS_HELD - 1))
          done
          entry_lines+=("$line")
          # Guard-ness is decided LEXICALLY, before the value is read: a `guard:`
          # line whose value is empty or whitespace-only is a guard the author
          # meant to state and did not, so it enters as the empty string and
          # guard_parse refuses it ("the guard is empty") — the entry is
          # UNPARSEABLE, not guardless. Extracting the value first and keeping it
          # only when non-empty is what made a truncated guard fail OPEN.
          case "$stripped" in
            'guard:'*)
              g=${stripped#guard:}
              g="${g#"${g%%[![:space:]]*}"}"   # trim both ends: the tokenizer
              g="${g%"${g##*[![:space:]]}"}"   # splits on space/tab anyway
              entry_guards+=("$g")
              ;;
          esac
        else
          # Stray indent outside an entry is structure — except an ORPHANED GUARD
          # (some entry-closer separated it from the entry above; only a blank line
          # may) or a tab-indented bullet, a promotion in the wrong list style.
          case "$stripped" in
            'guard:'*)
              orphan_guard "$line" "orphaned guard: no entry owns it (only a blank line may separate an entry from its indented guard)"
              ;;
            *)
              case "$line" in
                "$TAB"*)
                  case "$stripped" in
                    '- '*|'* '*|'+ '*)
                      unparseable "$line" "tab-indented bullet: entries start at column 0 with '- '"
                      ;;
                    *) emit_active "$line" ;;
                  esac
                  ;;
                *) emit_active "$line" ;;
              esac
              ;;
          esac
        fi
        ;;
      *)                           # column-0 non-bullet: structure, ends any entry
        # A `guard:` hiding behind bytes that are not the indentation grammar never
        # reaches here: hidden_guard intercepts the whole class above, for every
        # possible lead rather than a list of six bytes (header: HIDDEN GUARDS). What
        # is left in this branch is genuine structure — a heading, prose, a table row.
        flush_entry
        emit_active "$line"
        ;;
    esac
  done < "$INTENT"
  flush_entry
fi

# The active view is written ONCE, here: retraction (see ORPHANED GUARDS) means the
# buffer is only final at EOF. The file itself was created above, so it exists —
# empty — even when nothing at all vetted active.
#
# CHECKED, because this is the run's LAST write and everything downstream reads
# only this file: ENOSPC, or a $RUN removed after the startup writability probe,
# leaves intent-active.md empty or truncated while the counts below print and the
# script exits 0 — "counts printed, file not on disk", the same class the header
# records as fixed elsewhere, relocated to the final write.
if [[ "${#ACTIVE_BUF[@]}" -gt 0 ]]; then
  printf '%s\n' "${ACTIVE_BUF[@]}" > "$ACTIVE_OUT" || {
    printf 'ERROR: could not write %s — the active view is missing or truncated; fix disk space or permissions on %s and re-run\n' "$ACTIVE_OUT" "$RUN" >&2
    exit 2
  }
fi

echo "ACTIVE=$ACTIVE_N"
echo "QUARANTINED=$QUAR_N"
echo "UNPARSEABLE=$UNPARSE_N"
