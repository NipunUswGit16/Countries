#!/usr/bin/env bash
# promote-intent.sh — the format owner for `.kairos/intent.md`. Runs from the
# component work-tree root.
#
# WHY this script exists: the file is machine-parsed CROSS-RUN — it outlives every
# context that wrote it — and it was prose-written in three places: Phase 8's
# promotion, Phase 5's re-confirm, and reference/abort.md's salvage.
# `intent-check.sh` already ships an `intent-unparseable.md` output BECAUSE the file
# arrives malformed, and it names the worst case: an orphaned column-0 `guard:`,
# which silently de-guards the entry above it, so a fact whose tree assertion never
# runs goes on steering resolutions for the component's life. That is detection
# standing in for a writer that would make the shape impossible. This is the writer.
#
# THIS HEADER IS THE CANONICAL MECHANICS REFERENCE. SKILL.md's intent-ledger bullet
# and reference/state-files.md's format-owner paragraph both state the behavioral
# contract (writes go through this script, never by hand; the one sanctioned hand
# edit; Phase 5's vet-and-quarantine step) and then point HERE for the rest: the
# orphan-ownership attribution rules, the second-orphan-of-a-run qualifier, and the
# protect-vs-refuse verdict below. That split is deliberate — mechanics belong in
# the script that implements them, not in the always-loaded skill body — so an
# edit to the rule below with no matching edit up there is still a complete fix.
#
# ---------------------------------------------------------------------------
# THE CONTRACT: ONE READING MODEL, AND IT IS intent-check.sh'S
# ---------------------------------------------------------------------------
# THE RULE, in one sentence: every line is read with its trailing carriage return
# stripped and, on line 1 only, a leading UTF-8 BOM stripped, and a FINAL line with no
# terminator is a line like any other; an ENTRY is a column-0 `- ` line plus every
# following INDENTED line, with blank lines HELD open (a blank closes nothing, and
# belongs to the entry when another indented line follows); a GUARD is such an indented
# line whose text begins `guard:` — guard-ness is the prefix, not the value, and the
# INDENT is plain spaces and tabs, so a `guard:` behind anything else (an NBSP, a VT/FF, a
# stray CR, a U+200B/U+3000, alone or behind plain spaces) is a HIDDEN guard that the
# parser reports and whose entry it EXCLUDES, never a guard and never prose; a `guard:`
# at COLUMN 0 is an ORPHAN, and so is an INDENTED one where NO entry is open, and BOTH are
# attributed the same way — to the entry still OPEN above the line (which they EXCLUDE),
# whatever structure or blank line sits between it and its bullet, and otherwise to the
# entry the parser last put in the active view (which they RETRACT), and to no entry at all
# once that has happened, so the SECOND orphan of a run reaches back PAST the bullet above
# it or attaches to nothing; and a FACT is
# compared collapsed on both sides, because every field arrives here collapsed.
#
# That is intent-check.sh's model, clause for clause, and this file holds exactly ONE
# implementation of it: READ_MODEL's m_norm/m_class/m_collapse, consumed by entry_scan
# (extent + guards), orphan_rows (ATTRIBUTION — one walk, both orphan spellings),
# fact_lines (the MATCH), install()'s post-write assertion, and the `$0 = m_norm($0)`
# line at the top of both rewrites. Nothing here re-derives the model, and nothing here
# may.
#
# WHY THE DIVERGENCE IS THE WHOLE FAILURE MODE. intent-check.sh is the parser of
# record: it decides which facts steer a resolution, and it is the thing that excludes
# an entry BECAUSE of a shape. So the writer reading a line even slightly differently
# does not produce a cosmetic disagreement — it produces an edit whose consequence is
# invisible in this script's own output (exit 0, "retired"/"updated", the bullet still
# on disk) and visible only in the NEXT run's active view. Four of them were live at
# once, every one on the writer's side, and all four are the SAME failure: an entry
# that was excluded (steering nothing) is promoted into the ACTIVE view with an
# author's assertion deleted.
#   * `/^- /` on the RAW bytes made a BOM'd first line not-a-bullet, so its column-0
#     guard read as owned by NO entry — the one verdict that means SWEEP — and a
#     rewrite aimed at ANOTHER entry deleted it, de-guarding entry #1 of every file a
#     Windows editor had saved. The same blindness made that entry unreachable by
#     MATCH, so it could not be repaired through its own writer either.
#   * an extent that stopped at the first BLANK LINE while the parser HOLDS blanks
#     open: retire deleted the bullet and part of its continuation and STRANDED the
#     rest, whose indented guard lines then re-attached to the PRECEDING entry — a
#     bystander acquiring an assertion its author never wrote, and quarantining on it.
#     The same short extent hid a blank-separated guard from GUARD= (which ADDED
#     rather than replaced) and from DROP_GUARD=1 (which reported a guardless fact
#     that was still guarded).
#   * a fact comparison that kept the trailing CR: retire/update failed CLOSED on a
#     CRLF checkout (a MATCH never matched), but append's dedup failed OPEN and
#     stacked a SECOND entry for a fact the file already carried — the permanent
#     poisoning (find_entry refuses ambiguity) that the fact-scoped dedup exists to
#     prevent.
#   * ADOPTION scoped to the CONTIGUOUS run while OWNERSHIP reached across a blank:
#     the documented repair (`update` on the owner) SWEPT a non-adjacent orphan of the
#     caller's OWN entry — deleting the assertion the repair was called to restore.
#     One model, one scope: adoption now takes every orphan the parser reads against the
#     matched entry.
# Five more were found in the same layer once it existed, and they are the same failure
# again — an edit this script reports as done that the parser reads differently:
#   * ATTRIBUTION was read as the nearest preceding bullet for a column-0 orphan while the
#     parser's is a RETRACTION TARGET it carries forward — and on a RUN of two column-0
#     orphans the two part company: the first excludes the entry still open above it, the
#     second reaches PAST that entry to the last one that vetted ACTIVE. Reading both as the
#     nearest bullet's made both the matched entry's, so its retire/update deleted the
#     BYSTANDER's effective guard and flipped that entry from UNPARSEABLE to ACTIVE, while
#     the sweep NOTE named the wrong entry for the line — the transcript sending the restore
#     somewhere the line was never read against. One walk now answers it (orphan_rows).
#   * the append did not probe the file's LAST BYTE while the parser reads a final
#     UNTERMINATED line as a line. The bullet was SPLICED onto it: onto a trailing
#     indented `guard:` that produced one out-of-grammar guard and NO entry — "appended",
#     exit 0, a fact that is not a fact and an entry above it excluded for the wreckage.
#   * `GUARD=… DROP_GUARD=1` together: the resolution tested DROP_GUARD first and never
#     looked at GUARD, so the entry was written GUARDLESS, with no NOTE, for a caller who
#     had NAMED the assertion it must carry. Contradictory input is now refused whole.
#   * the extent stops at a CLOSER (as the parser does) but the parser does NOT ignore an
#     INDENTED `guard:` past it — it reports the orphan and RETRACTS the entry above. A
#     retire deleted the bullet and STRANDED that line, which then re-attached to the
#     preceding entry: the blank-line stranding again, one closer over (orphan_rows).
#   * ENTRY/MATCH arrive collapsed but the fact comparison read the file's tail VERBATIM,
#     so a fact recorded with a trailing space was unreachable by retire/update AND
#     invisible to append's dedup, which stacked a visually identical SECOND entry — the
#     CR divergence again, in whitespace the eye cannot see.
#
# WHERE THE MODEL CANNOT BE MATCHED, THE WRITER REFUSES. These shapes and inputs have no
# faithful rewrite, so they fail CLOSED with a message instead of being guessed at:
#   * a `guard:` line that states NO assertion (empty or whitespace-only value).
#     intent-check.sh decides guard-ness lexically and reports the ENTRY as
#     UNPARSEABLE — never guardless — precisely so a truncated guard cannot fail open.
#     Reading the value first and keeping it only when non-empty made the line
#     invisible here, so a keep-the-guard update deleted it with the rest of the entry
#     and re-emitted the bullet ALONE: "updated", exit 0, no NOTE, and the entry left
#     the unparseable bucket for the active view. The keep path (and append's dedup,
#     which cannot express the recorded set either) refuses; GUARD=, DROP_GUARD=1 and
#     retire all state the intent explicitly and are the way out.
#   * a HIDDEN `guard:` line — one behind bytes the indentation grammar does not read
#     (NBSP, VT, FF, a stray CR, U+200B, U+3000, any of them behind plain spaces).
#     intent-check.sh reports the LINE and excludes the entry it is read against, and
#     this writer can neither drop it (that deleted a committed assertion with exit 0 and
#     no NOTE — the same shape as the empty guard above, reached through the indent) nor
#     re-emit it (an invisible byte past the colon leaves the guard out of grammar, so the
#     entry stays excluded while the run reports success). SAME verdict, same way out:
#     the keep path and append's dedup refuse (require_no_hidden); GUARD=, DROP_GUARD=1
#     and retire state the intent and sweep the line with a NOTE. Re-indenting it with
#     plain spaces is the hand repair intent-check.sh's reason line names.
#   * a WHOLE-FILE refusal of intent-check.sh's — a NUL byte anywhere, or a git
#     conflict marker. The parser vets NOTHING in either file: it names the file and
#     stops. Past a NUL the line reader cannot see the bytes at all, so no entry means
#     what it appears to say; a conflict-marked file holds every fact TWICE,
#     interleaved, so a MATCH lands on a side of a merge this script cannot know is
#     the wanted one. Every action refuses such a file, and the repair (remove the NUL
#     bytes, resolve the merge) is not this script's to make.
#   * CONTRADICTORY INPUT: `GUARD=<assertion>` together with `DROP_GUARD=1`. One names the
#     assertion the entry must carry, the other that it must carry none, and either
#     resolution silently overrides an intent the caller stated in the same breath — the
#     one that fired wrote the entry GUARDLESS while the caller who had named the guard was
#     told "updated". There is nothing to infer from a self-contradiction, so the pair is
#     rejected whole (record-context.sh's reject-all-or-record-all, at the flag level).
#     DROP_GUARD=0 is the KEEP spelling, so `GUARD= DROP_GUARD=0` states ONE intent and is
#     honoured.
#   * an orphaned `guard:` in EITHER spelling whose attribution the parser decides AT
#     RUNTIME: it retracts the entry above only when that entry vetted ACTIVE, and when an
#     orphan had already excluded that entry the retraction reaches an EARLIER one instead.
#     Where that earlier entry is not the one being rewritten, the two readings want
#     OPPOSITE edits (take the line and it goes ACTIVE de-guarded; leave it and the rewrite
#     re-points the retraction, or the line re-parents as a live guard nobody wrote) and only
#     running its guards decides which. The action is refused, naming the line and that
#     entry; re-indenting the line under the entry it was meant to vet, or settling that
#     entry first, states what this writer cannot infer. See orphan_rows'
#     `runtime` verdict / require_attributable.
#   * a flag the ACTION cannot express: DROP_GUARD=1 on an `append` (there is no existing
#     guard to drop; the guard an append writes is GUARD's) and GUARD on a `retire` (the
#     entry and its guards are what retire deletes). Ignoring them printed "appended" /
#     "retired" to a caller who had stated an intent the run never carried out, which is the
#     contradiction above with a smaller blast radius. DROP_GUARD=0 asks for nothing and
#     DROP_GUARD=1 on a retire asks for what retire already does, so neither is refused.
#   * a fact recorded TWICE — which the collapsed comparison can find without a hand edit,
#     two entries differing only in whitespace being one fact. find_entry already refused
#     the ambiguity for retire/update; append refuses it too rather than answering
#     "unchanged" about a fact no later MATCH can name. Both name the candidates by line.
#   * a DATE outside the reader's LITERAL `YYYY-MM-DD` shape. The date is not part of the
#     ENTRY grammar — intent-check.sh opens an entry on any column-0 `- ` line — but it is
#     part of every FACT lookup: fact_lines finds the fact only PAST a `YYYY-MM-DD: `
#     prefix of exactly four, two and two digits. Accepting any string wrote a bullet that
#     exits 0 as "appended" and then belongs to no fact at all: retire and update answer
#     "no entry carries the fact" about a line that plainly reads like one, append's dedup
#     cannot see it either and stacks a second visually identical entry the next time the
#     same fact is promoted (the permanent ambiguity above, reached through the date), and
#     intent-check.sh reports the file as perfectly parseable — so neither the quarantine →
#     Phase 5 re-confirm loop nor the one sanctioned hand edit, which is scoped to a line
#     the parser reports UNPARSEABLE, ever reaches the entry. The shape is asserted AFTER
#     the default is applied, and `date -u +%Y-%m-%d` always satisfies it, so only an
#     explicit DATE can fail here.
#
# WHY the bullet and its guard are written as ONE unit: the orphan is exactly what
# you get when a prose append writes the bullet and forgets the indent, or when a
# prose retire deletes the bullet and leaves the guard. Both directions are closed
# here — append emits both lines in a SINGLE write(2) (the two-line text is built
# first and one printf writes it, so a kill cannot land the bullet without its
# guard), retire removes the bullet and every continuation line beneath it.
#
# WHY retire/update also SWEEP column-0 `guard:` lines: preventing the shape is not
# enough for a file that OUTLIVES this writer. A component whose intent.md predates
# it — or was hand-edited — can already carry an orphan, and install()'s invariant
# check refused the shape GLOBALLY: one legacy orphan blocked retire and update of
# every unrelated well-formed entry, while append (which appends in place, past
# install()) could not remove it either. The file went append-only and
# un-repairable by its own format owner, and intent-check.sh's quarantine → Phase 5
# re-confirm → `promote-intent.sh retire` loop dead-ended on it. So the writer gains
# the power to remove the one shape it refuses to leave behind, and the loop closes.
#
# WHY THE SWEEP IS ENTRY-SCOPED, not file-global. THE RULE: a rewrite sweeps only the
# orphans intent-check.sh reads against the MATCHED entry, the ones it reads against no entry
# at all inside that entry's own run, and the ones above every bullet in the file (which no
# entry is waiting on) — every orphan it reads against ANOTHER entry, or against none inside
# another entry's run, survives untouched, whatever guards that entry already carries.
# THE ATTACHMENT IS THE READING LAYER'S, which is intent-check.sh's and nothing else: the
# entry still OPEN above the line, whatever sits between them (a blank line is HELD, so it
# closes nothing), and otherwise the RETRACTION TARGET the parser carries forward — the last
# entry that vetted ACTIVE, across a `---`, a heading, prose or a wrong-style bullet, and no
# entry at all once an orphan has taken it. A NARROWER reading (this file first used a
# CONTIGUOUS block, then a `/^- /` that a BOM defeated, then the nearest preceding bullet)
# calls a foreign entry's guard the matched entry's or nobody's, sweeps it, and flips that
# entry from UNPARSEABLE to ACTIVE with its author's assertion deleted. Same cross-entry
# fail-OPEN as the file-global sweep, reached through the attribution model.
# Where the two readings could still disagree, the verdict is PROTECT wherever this rewrite
# cannot change what the parser reads the line against — the orphan stays and the foreign
# entry stays UNPARSEABLE for its own repair — and a REFUSAL wherever it can, because there
# the two readings want opposite edits and only running that entry's guards picks one.
# See orphan_rows() for the rule clause by clause against intent-check.sh's parser.
# The safety argument for a global sweep was "an OWNED guard is indented, so a column-0
# `guard:` is unowned by definition, and the sweep deletes a line that was steering
# nothing". That is true of the ORPHAN and FALSE of the ENTRY ABOVE IT: intent-check.sh
# excludes that entry too, and the orphan is the entire reason. Delete the orphan and
# the entry stops being excluded — it goes ACTIVE and steers every later resolution
# vetted only by the guards that happened to be indented, with the assertion its author
# wrote now deleted. While the sweep ran file-globally and adoption was scoped to the
# MATCHED entry, one retire or update of entry ONE did that to entry TWO: the same
# fail-OPEN the adoption path exists to prevent, one entry over.
# The scope is the ATTACHMENT and nothing else — not that entry's guardless-ness. Requiring
# the foreign entry to be guardless before sparing its orphan left the same hole one
# condition deeper: an entry carrying an indented guard AND a column-0 one is
# UNPARSEABLE just the same, and sweeping its column-0 line promoted it to ACTIVE on
# its indented guards alone, which may be exactly the ones that pass. A foreign entry
# is never the caller's to repair. It stays UNPARSEABLE, which is a named row in
# Phase 5's re-confirm table and the invitation to run `update` on IT — where adoption
# gives the guard back if the entry is guardless, and a sweep with a NOTE names the
# line if it is not (stapling it on would be silent de-guarding wearing the opposite
# mask). The MATCHED entry's own orphans are the caller's: adopted where update can adopt
# them, and otherwise deleted with the caller's explicit GUARD/DROP_GUARD or with the
# entry retire removes. install()'s assertion follows the same scope: exactly the
# protected column-0 orphans survive, no more and no fewer (the other spelling, below, is
# addressed by LINE, so it cannot be counted the same way after the lines move).
#
# THE ORPHAN HAS TWO SPELLINGS, and ONE ATTRIBUTION WALK answers both. The second is an
# INDENTED `guard:` sitting where no entry is open — a heading, a `---` or column-0 prose
# between it and its bullet — which the extent rule correctly stops short of and a column-0
# map never saw. intent-check.sh hands both to the same orphan_guard(): it reports the line
# and RETRACTS the entry, so leaving one behind after a retire strands it onto whatever entry
# then precedes it — the blank-line stranding, one closer over. So the matched entry takes
# those lines too: retire deletes them, an explicit GUARD/DROP_GUARD sweeps them (the
# caller's guard set is the entry's WHOLE guard set, or the entry stays excluded for a line
# the caller was never told about), and the keep path ADOPTS them alongside the column-0
# ones, in FILE ORDER. Two spellings with two attribution rules is what let the column-0 run
# diverge, so there is now exactly one walk of intent-check.sh's clauses for both
# (orphan_rows), and where the attribution depends on guard results the action is REFUSED
# (see the refusals above) — never guessed. Only the REACH differs, and only because the
# rewrites address the two spellings differently: column-0 rows cover the whole file (that
# spelling is swept by the m_class == "orphan" rule and counted file-wide by install()),
# while an INDENTED one past the next bullet is shielded by it — that bullet rebuilds the
# parser's state, so rewriting the matched entry cannot change what the line is read against.
#
# A THIRD PHYSICAL SPELLING — the HIDDEN guard — reads like the first and is ACTED ON
# differently, and the difference is the point. It is a `guard:` behind bytes the
# indentation grammar does not read: an NBSP (the routine browser/Confluence paste
# artifact), a VT, a FF, a stray CR, a U+200B, a U+3000 — any of them, in any combination,
# and BEHIND PLAIN SPACES too. intent-check.sh routes every one of them to the SAME
# orphan_guard() as a column-0 `guard:` (hidden_guard, an allowlist of the indents that ARE
# the grammar rather than a list of suspect bytes), so it reports the line and EXCLUDES the
# entry it is read against; m_class therefore moves the parser's state for one exactly as it
# does for a column-0 orphan, and orphan_rows attributes it through the same walk.
# WHAT DIFFERS IS WHAT THIS WRITER MAY DO ABOUT ONE, and it is the `guard:`-stating-nothing
# rule again: the paths that must RE-STATE the file's own guard set (update's keep path,
# append's dedup) REFUSE, and the paths where the caller states it — GUARD=, DROP_GUARD=1,
# retire — delete the line with a NOTE naming its text. Neither of the other two readings
# survives contact: read as a plain CLOSER (the pre-fix state for a lead of NBSP/VT/FF) the
# line survived a retire and stranded onto a bystander while an update reported success over
# an entry that stayed UNPARSEABLE; read as CONTINUATION PROSE (the pre-fix state for
# `<SP><NBSP>guard:`, which starts with a space and so never reached the byte list at all)
# `update` absorbed it into the extent and DELETED a committed `guard:` line, exit 0, no
# NOTE; and ADOPTED as a plain indented guard it is a false success whenever any invisible
# byte sits PAST the colon (`<NBSP>guard: test -e we<NBSP>b` re-emits still out of grammar,
# entry still excluded, "updated" printed).
#
# WHY update ADOPTS instead of sweeping in one case: `- fact` followed by a column-0
# `guard:` is not noise, it is the forgot-the-indent malformation itself, and it is
# the shape Phase 5's re-confirm is handed. Sweeping it would delete the author's
# assertion, print "updated" and say nothing, leaving the fact to steer resolutions
# with no guard ever running — the failure this whole file exists to prevent, now
# caused by the repair. So when update is given neither GUARD nor DROP_GUARD and the
# matched entry owns no guard of its own, EVERY orphaned `guard:` line the parser reads
# against that entry — or against no entry while sitting in that entry's run — is
# re-attached as its INDENTED guards, in file order.
# EVERY ONE, and not the adjacent run: adoption is scoped by the ATTRIBUTION, the same walk
# and the same verdict as the sweep, because anything narrower makes the repair itself the
# fail-OPEN. An un-indented MULTI-guard entry is one author making one mistake once, so
# adopting one guard while the sweep deletes the rest promotes the entry out of the
# unparseable bucket on the assertion that happened to be FIRST; and while adoption
# stopped at the first blank line, a blank — which un-owns nothing — was enough to make
# `update` DELETE an orphan of the caller's own entry, the very assertion the documented
# repair was called to restore. Every other orphan the sweep is allowed to touch still
# goes, and an entry that already owns a guard never adopts.
#
# WHY every sweep and adoption prints a NOTE on stderr: both DELETE or MOVE a
# committed line the caller never named. A format owner that edits silently is the
# second unaudited writer this file already suffered from; exit status and stdout
# stay unchanged so no caller has to parse for it, but the run's transcript records
# what happened to the file.
#
# WHY every guard travels, not the first one: intent-check.sh's grammar allows an
# entry to carry SEVERAL `guard:` lines and requires ALL of them to pass, and the
# adoption above is itself a producer of two-guard entries (see the next paragraph),
# so a multi-guard entry arrives through this skill's own documented steps. Reading
# only the first guard while the rewrite deletes the whole entry and re-emits one
# guard line silently dropped every guard after the first — "updated", exit 0, no
# NOTE. That fails OPEN, which is the one direction this file must never fail in: an
# entry that used to QUARANTINE on the dropped assertion goes ACTIVE instead, and the
# fact steers resolutions with an assertion nobody runs. So the keep path re-emits
# every guard in file order, DROP_GUARD drops them all, and an explicit GUARD —
# user-directed, so allowed — replaces them all and says how many went.
#
# The one shape with no right answer: `- fact` / column-0 `guard: A` / INDENTED
# `guard: B`. B is inert today (no entry is open where it sits), and ANY rewrite that
# removes the column-0 line moves B up against the entry, making it live. Nothing
# reconstructs the author's intent there, so the direction is chosen to be FAIL-SAFE:
# A is adopted, B reparents, the entry carries both, and intent-check.sh requires ALL
# guards to pass. The worst case is a quarantined entry — one row in Phase 5's
# re-confirm table — never a fact steering resolutions with an assertion nobody runs.
#
# WHY collapse(): the same reason the three ledger writers carry it, sharpened by
# this file's grammar. A newline inside ENTRY would put its tail at COLUMN 0, where
# the parser reads it as structure — silently promoted prose — or, if that tail
# happened to begin `guard:`, as an orphaned guard. One entry must always cost one
# entry. (Resolvers quote intent entries verbatim, so multi-line text is not
# hypothetical.)
#
# WHY it is KEYLESS: its callers are phases/8-finalize.md's promotion step,
# phases/5-structural.md's re-confirm, and reference/abort.md's salvage — and
# abort is a reference document that holds no phase key at all. A key would brick
# the salvage path, which is the one chance to keep a run's answers. Same argument
# `log-learning.sh` and `log-intent.sh` already carry. Do not "fix" this by adding
# a key.
#
# In :  ACTION      append (default) | retire | update
#       INTENT      intent file path (default `.kairos/intent.md`)
#       ENTRY       append/update: the fact (required)
#       MATCH       retire/update: the EXACT existing fact to act on (required)
#       GUARD       append: optional tree assertion attesting the state the fact
#                   describes; update: replaces EVERY guard the entry carries when
#                   set (a NOTE names how many went when it was more than one).
#                   NOT shell, and NOT validated here — intent-check.sh is the
#                   grammar owner (`test [!] -e|-f|-d|-s <relative-path>` /
#                   `grep -q[F] <pattern> <relative-path>`, either optionally
#                   `!`-inverted; see its header for the trust model). A guard
#                   outside that grammar writes fine and then excludes its entry
#                   as UNPARSEABLE on every later run, so callers must pass an
#                   in-grammar guard or none at all. GUARD together with DROP_GUARD=1
#                   is CONTRADICTORY and refused, and GUARD on a RETIRE is refused as
#                   unexpressible (see the refusals above).
#       DROP_GUARD  update: set to 1 to remove EVERY guard the entry carries. Only
#                   1, 0 and empty are accepted — any other value is refused rather
#                   than read as false, because a caller who wrote `DROP_GUARD=true`
#                   and was silently given the KEEP path walks away believing the
#                   entry is guardless while it goes on quarantining. On an APPEND,
#                   DROP_GUARD=1 is refused as unexpressible (there is no existing
#                   guard to drop). With neither GUARD nor DROP_GUARD all existing
#                   guards are kept, in file order — including every ORPHANED one the
#                   parser reads against the entry, in EITHER spelling (column-0, or
#                   indented past a closer), when the entry is otherwise guardless:
#                   those are ADOPTED in full as that entry's indented guards, merged
#                   in file order (see above). The keep path is the only one that must
#                   re-state what the file already says, so it is the one that REFUSES
#                   a `guard:` line stating no assertion.
#       DATE        optional, default today (UTC). Exactly `YYYY-MM-DD` (four digits,
#                   two, two, dash-separated) — the shape the reader parses back out of
#                   the bullet — and any other spelling is REFUSED rather than written,
#                   because a bullet dated otherwise carries no fact for MATCH or for
#                   append's dedup to find (see the refusals above). update refreshes it
#                   — an updated fact is a fact re-confirmed today, and the date is what
#                   the next run judges staleness by. append IGNORES it when the fact is
#                   already recorded: dedup is on the fact, so a re-append is
#                   "unchanged" and the existing date stands (see below).
#       Every field is collapsed and trimmed before use, so a whitespace-only value
#       is as empty as an unset one — and the FACT is compared the same way, so a fact
#       recorded with a trailing space, a double space or a tab is the same fact to
#       MATCH and to append's dedup (only the comparison collapses; the bytes on disk
#       are left alone).
# Out:  the intent file. Created when absent. All other content — headings, prose,
#       blank lines, thematic breaks, other entries — survives BYTE-VERBATIM: a line the
#       rewrite does not touch is re-emitted with its own bytes AND its own terminator, so a
#       CRLF checkout stays a CRLF checkout. The ONE byte a rewrite adds to such a line is a
#       terminator the line never had: a FINAL line with no newline at all gains an LF when
#       a rewrite re-emits it (awk's `print` supplies one), which cannot change the parser's
#       reading of it — intent-check.sh reads a final unterminated line as a line either way.
#       Three exceptions to VERBATIM: a pre-existing ORPHANED `guard:` in any of its
#       spellings — column-0, indented where no entry is open, or HIDDEN behind bytes the
#       indentation grammar does not read — that intent-check.sh reads
#       against the MATCHED entry or against no entry at all, which retire and update sweep
#       out or adopt (one it reads against ANOTHER entry is never touched — see above; a
#       HIDDEN one is only ever swept, and only on a path that STATES the guard set, since
#       the others refuse it); the
#       matched entry's own
#       EXTENT, which update re-emits as its bullet plus its
#       guards — so an indented annotation that is not a `guard:`, and a blank line HELD
#       inside the entry, do not survive the rewrite, and the re-emitted lines are LF;
#       and a MISSING final newline, which an append supplies before its bullet (that
#       line's own bytes are untouched, so the parser reads it identically either way).
#       Keep annotations in the fact itself or in surrounding prose. A leading BOM lives
#       on line 1, so it goes only when line 1 is the line being rewritten (the parser
#       strips it either way).
#       One hand edit is sanctioned and this script cannot express it: a line
#       intent-check.sh reports unparseable AS A LINE (a wrong-style bullet —
#       `*`/`+`/no-space/tab-indented) has no fact for MATCH to name, so Phase 5's
#       re-confirm deletes that one line by hand. Deleting a non-entry line cannot
#       orphan a guard, which is what keeps the exception safe.
# Stdout: "appended" | "unchanged" | "retired" | "updated"
# Stderr: one `NOTE:` line per orphan SPELLING naming how many were adopted; one PER SWEPT
#         orphan, naming its guard TEXT and, for a column-0 one, the entry intent-check.sh
#         ATTACHED it to — which is not always the bullet directly above, and is sometimes no
#         entry at all (an orphan above it had already excluded the one it sat under), which
#         the note says in those words — so the transcript is enough to put the line back;
#         and one when a GUARD replaced MORE THAN ONE guard
#         on the matched entry — each printed only when it applies; exit status unaffected
# Exit: 0 done
#       2 bad input (including a DROP_GUARD that is neither 1, 0 nor empty, GUARD
#         together with DROP_GUARD=1, a flag the ACTION cannot express — DROP_GUARD=1 on
#         an append, GUARD on a retire — and a DATE outside the reader's literal
#         `YYYY-MM-DD` shape), an unwritable file, or a MATCH that is absent /
#         ambiguous — the ambiguity naming every candidate by line, since two entries the
#         collapse makes equal are otherwise indistinguishable in a message;
#         including an append naming one guard for a fact already recorded with a
#         DIFFERENT guard set (append writes at most one guard, so a fact recorded
#         with several can never be "unchanged": that is an update), and an append onto a
#         fact the file already carries TWICE (no MATCH can name it: not "unchanged");
#         and the fail-CLOSED refusals of the reading model above — an intent file
#         intent-check.sh refuses WHOLE (a NUL byte, a git conflict marker), for every
#         action; a `guard:` line that states no assertion where the keep path or
#         append's dedup would have to re-state it; and an orphaned `guard:` in EITHER
#         spelling whose attribution the parser decides by running guards this writer cannot
#         evaluate; and a guard-like line HIDDEN behind bytes the indentation grammar
#         does not read, on the paths that would have to re-state it. Nothing is
#         written by any refusal.
set -u

# LC_ALL=C IS PINNED FOR THE WHOLE SCRIPT, for the reason intent-check.sh pins it (see
# its header) and with the same force here: this file's job is to read a committed
# ledger EXACTLY as that parser does, and a character class is not the same set of
# bytes in every locale — an NBSP is `[[:space:]]` under en_US.UTF-8 and is not under
# C, in awk as in bash. Unpinned, `<SP><NBSP>guard:` was a GUARD to an awk running in a
# UTF-8 locale and CONTINUATION PROSE to the same script under C: the reading model
# diverged from ITSELF between two boxes, which is the one thing this layer exists to
# prevent. Under the pin m_trim, m_collapse and m_class name fixed bytes everywhere.
LC_ALL=C
export LC_ALL

fail() { echo "FAIL: $*" >&2; exit 2; }
note() { echo "NOTE: $*" >&2; }

collapse() { printf '%s' "$1" | tr '\n\r\t' '   ' | awk '{ $1 = $1; print }'; }

ACTION=$(collapse "${ACTION:-append}")
INTENT="${INTENT:-.kairos/intent.md}"
ENTRY=$(collapse "${ENTRY:-}")
MATCH=$(collapse "${MATCH:-}")
GUARD=$(collapse "${GUARD:-}")
DATE=$(collapse "${DATE:-$(date -u +%Y-%m-%d)}")
DROP_GUARD=$(collapse "${DROP_GUARD:-}")

case "$ACTION" in
  append|retire|update) ;;
  *) fail "unknown ACTION '$ACTION' (want append|retire|update)" ;;
esac

# DATE is the one field the READER parses back OUT of the bullet, and on that side the
# shape is LITERAL: fact_lines (and intent-check.sh's own fact lookup, whose digit class
# this pattern mirrors so the two cannot diverge in kind) reads the fact only past a
# `YYYY-MM-DD: ` prefix of exactly four, two and two digits. Accepting any string was a
# fail-OPEN of the same family as every divergence above, one field over: `DATE=2026-8-1`
# wrote its bullet and exited 0 saying "appended", and from then on nothing could name the
# fact — retire and update answered "no entry carries the fact" about a line that plainly
# reads like one, and append's dedup, blind to it in the same way, stacked a SECOND
# visually identical entry the next time the fact was promoted. intent-check.sh meanwhile
# reports the file as perfectly parseable (the date is not part of its ENTRY grammar), so
# no quarantine and no re-confirm ever surfaced it, and the one sanctioned hand edit —
# scoped to a line reported UNPARSEABLE — did not cover it either: a permanently poisoned
# committed ledger. The assertion is made AFTER the default is applied, so the value that
# reaches the file is the value that was checked, and BEFORE any file is touched.
case "$DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) fail "DATE '$DATE' is not the shape the reader requires — exactly YYYY-MM-DD, four digits, two, two, dash-separated (2026-08-01, never 2026-8-1). intent-check.sh and this script both find a fact only past a literal 'YYYY-MM-DD: ' prefix, so a bullet dated any other way carries no fact at all: MATCH could never name it for a retire or an update, and a later append of the same fact would stack a duplicate instead of recognising it. Pass a zero-padded UTC date or leave DATE unset for today. Nothing was written" ;;
esac

# DROP_GUARD is a switch, and an unrecognised value is REFUSED rather than read as
# false. Testing it for equality with 1 means every other spelling — `true`, `yes`,
# `Y` — took the silent KEEP path: exit 0, "updated", guards still on the entry, and
# a caller who asked for a guardless fact left believing it got one while the entry
# goes on quarantining. That is the same class of invisible outcome as the dropped
# guard, so it gets the same answer this file gives every ambiguity: refuse and say so.
case "$DROP_GUARD" in
  ''|0|1) ;;
  *) fail "DROP_GUARD must be 1 (drop every guard), 0 or unset (keep them) — refusing to guess what '$DROP_GUARD' means" ;;
esac

# GUARD and DROP_GUARD=1 in one call are CONTRADICTORY INPUT, and the pair is refused
# WHOLE rather than resolved by which test the guard resolution happens to run first.
# It tested DROP_GUARD first and never looked at GUARD, so the pair exited 0 saying
# "updated" with the entry written GUARDLESS and no NOTE: a caller who NAMED the
# assertion the fact must carry walked away believing the fact is vetted while it steers
# every later resolution with nothing running — this file's central failure mode, reached
# through the argument list. Resolving it the other way is no better; the two flags state
# OPPOSITE intents, so there is nothing to infer, and the answer is the one
# record-context.sh gives a half-stated record: reject all of it and say so.
# DROP_GUARD=0 is the KEEP spelling, not a second way to say drop, so `GUARD=… DROP_GUARD=0`
# states ONE intent (replace) and is not the contradiction.
[[ "$DROP_GUARD" != 1 ]] || [[ -z "$GUARD" ]] \
  || fail "GUARD ('$GUARD') and DROP_GUARD=1 state opposite intents — one names the assertion the entry must carry, the other that it must carry none — and this writer will not pick: pass GUARD=<tree assertion> alone to replace every guard on the entry, or DROP_GUARD=1 alone to leave the fact guardless. Nothing was written"

# A flag the ACTION cannot express is refused too, for the same reason and with the same
# blast radius one step smaller: DROP_GUARD on an `append` (which writes the guard it was
# given and has nothing to drop) and GUARD on a `retire` (which deletes the entry and every
# line under it). Reading them as no-ops meant a caller who stated an intent got "appended"
# / "retired" — the run's own record of a decision the run never carried out. Only a value
# that ASKS for something the action will not do is refused: DROP_GUARD=0 is the keep
# spelling and asks for nothing, and DROP_GUARD=1 on a retire asks for exactly what retire
# already does (the guards go with the entry), so neither is a refusal.
case "$ACTION" in
  append)
    [[ "$DROP_GUARD" != 1 ]] \
      || fail "DROP_GUARD=1 means nothing to an append: the guard an append writes is the one GUARD names, and there is no existing guard to drop. Pass GUARD=<tree assertion> for a guarded fact or neither flag for a guardless one, or ACTION=update to drop the guard of a fact already recorded. Nothing was written" ;;
  retire)
    [[ -z "$GUARD" ]] \
      || fail "GUARD ('$GUARD') means nothing to a retire: the entry and every line under it — its guards included — is what retire deletes, so there is nothing left for the assertion to vet. Pass ACTION=update with GUARD=<tree assertion> to re-guard the fact, or drop GUARD to retire it. Nothing was written" ;;
esac

# ---------------------------------------------------------------------------
# THE READING LAYER — see THE CONTRACT in the header
# ---------------------------------------------------------------------------
# The two bytes-sensitive constants travel through the ENVIRONMENT, built by printf,
# and are NEVER made with awk's sprintf("%c", 239): gawk in a UTF-8 locale renders a
# %c above 127 as the MULTIBYTE encoding of that code point (0xC3 0xAF for 239) while
# BSD awk emits the raw byte, so the BOM test would pass on one operator's box and
# fail on another — the same locale-dependent verdict intent-check.sh refuses in its
# path charset. printf's octal escapes mean the same three bytes in bash 3.2 and 5.
# For the same reason m_norm() strips the BOM by `index() == 1` and `length(BOM)` rather
# than by the literal 3: gawk in a UTF-8 locale counts substr() in CHARACTERS, where the
# BOM is ONE, so `substr(l, 4)` there would have eaten two characters of the fact.
PI_CR=$(printf '\r')
PI_BOM=$(printf '\357\273\277')
# No NBSP/VT/FF constants live here any more: which indents HIDE a guard is no longer a
# list of bytes to name (which is how U+200B and U+3000 walked past both readers) but the
# complement of the indentation grammar — see m_class's `hidden` branch and
# intent-check.sh's hidden_guard, the two halves of one rule.
export PI_CR PI_BOM

# READ_MODEL — the awk half of the layer: NORMALIZE a line, then CLASSIFY it. Every awk
# program below concatenates this, so the model has exactly one implementation here.
#
# m_class returns bullet | orphan | hidden | guard | cont | blank | closer and leaves the
# line's payload in M_VAL — the fact for a bullet (the `- ` stripped), the trimmed
# assertion for any guard spelling, the line itself otherwise. The order of the tests IS
# intent-check.sh's case order, and the classes are its branches:
#   bullet  a column-0 `- ` line — ANY of them; the date is not part of the entry grammar
#   orphan  a column-0 `guard:` line — owned by no entry, wherever it sits
#   blank   the EMPTY line, and only that: a whitespace-only line is an indented
#           continuation to the parser, so it is `cont` here and does not end an entry
#   hidden  a `guard:` whose leading bytes are NOT the indentation grammar (space/tab):
#           an NBSP, a VT, a FF, a stray CR, a U+200B, a U+3000, any of them behind
#           plain spaces. intent-check.sh reports the line and EXCLUDES the entry it is
#           read against (hidden_guard -> orphan_guard), so it closes an open entry and
#           moves the parser's state exactly as a column-0 orphan does — but it is a
#           class of its own here, because what this WRITER may do about one differs
#           (see WHERE THE MODEL CANNOT BE MATCHED in the header)
#   guard   an indented line whose text begins `guard:` — guard-ness is the PREFIX, so
#           an empty value is a guard that states nothing, never no guard
#   cont    any other indented line
#   closer  everything else at column 0 (`* `/`+ ` bullets, `-` with no space, `---`,
#           headings, prose): structure, and it ENDS the open entry
#
# m_collapse() is collapse()'s awk half — byte for byte the normalisation the SHELL side
# already applied to every field on the way in (the three whitespace bytes to spaces,
# squeeze, trim). It exists so the FACT is compared COLLAPSED ON BOTH SIDES (see
# fact_lines): comparing the file's bullet tail verbatim against an already-collapsed
# MATCH/ENTRY was a divergence inside this file's own field discipline. Its class is
# exactly the three bytes collapse() maps and no more — [[:space:]] would also fold a
# vertical tab or a form feed that the shell side leaves alone, which is the same kind of
# divergence pointing the other way. Nothing on disk is collapsed by it: only the
# comparison, and only a line a rewrite re-emits is ever normalised as bytes.
READ_MODEL='
function m_norm(l,   b) {
  if (substr(l, length(l), 1) == ENVIRON["PI_CR"]) l = substr(l, 1, length(l) - 1)
  b = ENVIRON["PI_BOM"]
  if (FNR == 1 && index(l, b) == 1) l = substr(l, length(b) + 1)
  return l
}
function m_trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
# m_lead — the leading run of bytes in a line that are NOT graphic ASCII (0x21..0x7E),
# i.e. whatever sits in front of the first visible character. The awk half of
# hidden_guard in intent-check.sh. The indentation GRAMMAR is a subset of it (space and
# tab), so a lead carrying anything ELSE is an indent neither parser reads — detection
# only, never acceptance. Computed as the complement of one class rather than by stripping
# a LIST of whitespace-variant bytes, which is what let U+200B and U+3000 walk past both
# readers as prose; and under the pinned LC_ALL=C the class is a fixed set of bytes, so
# mawk, gawk and BSD awk all cut the same line in the same place.
function m_lead(l,   lead) { lead = l; sub(/[[:graph:]].*$/, "", lead); return lead }
function m_collapse(s) {          # the awk half of collapse() — see above the string
  gsub(/[ \t\r\n]+/, " ", s)
  sub(/^ /, "", s); sub(/ $/, "", s)
  return s
}
function m_class(l,   c, s, lead, rest) {
  M_VAL = l
  # A spaced CommonMark thematic break (`- - -`, `-  -  -`) begins with `- `, so the
  # bullet test below would take it and treat it as an entry — the same phantom-entry
  # trap intent-check.sh guards against, and taking it here would desync the writer
  # from the reader (which classes it as structure). A break closes the entry extent
  # exactly like the bare `---`, so it is a `closer`. Written without an interval
  # quantifier (`{3,}` is not portable across the mawk/gawk/BSD-awk set) and without a
  # trailing `[..-]` bracket (whose `-` reads ambiguously): three mandatory dashes,
  # each space/tab-separated, then any number more.
  if (l ~ /^-[ \t]*-[ \t]*-([ \t]*-)*[ \t]*$/) return "closer"
  if (substr(l, 1, 2) == "- ")     { M_VAL = substr(l, 3);         return "bullet" }
  if (substr(l, 1, 6) == "guard:") { M_VAL = m_trim(substr(l, 7)); return "orphan" }
  if (l == "") return "blank"
  # A `guard:` HIDDEN behind bytes that are not the indentation grammar. This test runs
  # BEFORE the indented branch, and that ORDER is the fix: while it ran after, a lead
  # that merely STARTED with a space (`<SP><NBSP>guard:`) never reached it — the indented
  # branch took the line, the `[[:space:]]` class in m_trim folded the NBSP in a UTF-8
  # locale and not under C, and the line was CONTINUATION PROSE to this writer. So
  # `update` absorbed it into the extent of the entry and re-emitted the bullet ALONE: a
  # committed `guard:` line DELETED, "updated" on stdout, exit 0, no NOTE — the fail-OPEN
  # this whole layer exists to prevent, one branch above where it was being looked for.
  # Now every non-grammar lead lands here, whatever bytes it is made of and whatever it
  # starts with, and the verdicts in the header decide what may be done about it.
  lead = m_lead(l)
  if (lead ~ /[^ \t]/) {
    rest = substr(l, length(lead) + 1)
    if (substr(rest, 1, 6) == "guard:") { M_VAL = m_trim(substr(rest, 7)); return "hidden" }
  }
  c = substr(l, 1, 1)
  if (c == " " || c == "\t") {
    s = m_trim(l)
    if (substr(s, 1, 6) == "guard:") { M_VAL = m_trim(substr(s, 7)); return "guard" }
    return "cont"
  }
  return "closer"
}
'

# file_gate — the reading model's OUTERMOST rule: intent-check.sh refuses a whole file
# carrying a NUL byte or a git conflict marker, before it parses a line, and vets nothing
# in it. So neither is editable here either (see THE CONTRACT). Checked once, before any
# action, and byte-wise under LC_ALL=C the same way intent-check.sh does it — no portable
# grep reports a NUL match on both userlands, but `tr -d` and `wc -c` agree everywhere.
file_gate() {
  [[ -f "$INTENT" ]] || return 0
  local nuls marker
  nuls=$(( $(wc -c < "$INTENT") - $(LC_ALL=C tr -d '\000' < "$INTENT" | wc -c) ))
  [[ "$nuls" = 0 ]] \
    || fail "$INTENT carries $nuls NUL byte(s): the line parser cannot read past one, so intent-check.sh refuses the WHOLE file and vets no fact in it — an edit here would rewrite a file whose entries do not mean what they appear to say. Remove the NUL bytes and re-run"
  marker=$(LC_ALL=C grep -n -m1 -E '^(<<<<<<< |=======[[:space:]]*$|>>>>>>> )' "$INTENT" 2>/dev/null || true)
  [[ -z "$marker" ]] \
    || fail "$INTENT carries a git conflict marker (line ${marker%%:*}: '${marker#*:}'): an unresolved merge holds two versions of every fact interleaved, so intent-check.sh refuses the WHOLE file and a MATCH here would land on one side of a merge this script cannot know is the wanted one. Resolve the conflict and re-run"
}

# fact_lines <fact> — echo the 1-based line number of every entry whose fact is
# exactly <fact>, one per line (empty when there is none). The match is on the FACT
# ALONE, deliberately date-blind: the date records WHEN the fact was first written,
# it is not part of the fact's identity, and every caller here — append's dedup and
# find_entry's lookup — asks "is this fact already recorded?", never "is this fact
# recorded under today's date?".
#
# WHY the fact travels through the ENVIRONMENT and not `awk -v`: awk ESCAPE-PROCESSES
# a -v value, so a fact carrying a backslash arrived at the comparison as different
# bytes than the ones in the file — `\t` became a tab, `\o` became `o`. It never
# matched, in BOTH directions at once: append's dedup failed OPEN and stacked a
# second entry, and find_entry then found zero-or-many and refused every later
# retire/update, poisoning the fact on the first re-append with no midnight crossing
# needed. Facts quote real trees (`logs use \t as the separator`, `C:\opt\app`), so
# this is a live shape. ENVIRON[] hands awk the bytes verbatim. Line NUMBERS may
# still travel by -v — they have no bytes to mangle.
# The bullet test is the reading layer's: a line the parser reads as an entry, with its
# CR and (on line 1) its BOM already off. Reading `/^- ` off the raw bytes made a BOM'd
# first entry invisible — unmatchable AND, worse, not the owner of its own guard.
#
# WHY the comparison is COLLAPSED on BOTH sides: ENTRY and MATCH reach here through
# collapse(), so comparing them against the file's tail VERBATIM compared two values
# normalised differently. A fact recorded with a trailing space (or a double space, or a
# tab) then failed to match in BOTH directions at once — retire/update said "no entry
# carries the fact" about an entry that plainly does, and append's dedup, asking the same
# question, said "not recorded" and stacked a SECOND, visually identical entry. From then
# on find_entry refuses the fact as ambiguous and no action can repair either copy. The
# file's BYTES are untouched by this: only the comparison is collapsed, and only a line the
# rewrite re-emits is ever normalised on disk.
fact_lines() {
  [[ -f "$INTENT" ]] || return 0
  w="$1" awk "$READ_MODEL"'
    {
      if (m_class(m_norm($0)) != "bullet") next
      v = m_collapse(M_VAL)
      if (v !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]: /) next
      if (substr(v, 13) == ENVIRON["w"]) print FNR   # past `YYYY-MM-DD: `
    }
  ' "$INTENT"
}

# entry_inline <line-numbers> — `line <n>: '<bullet>'` for each, on ONE line, for a refusal
# that has to NAME the entries it will not choose between. Line numbers and the bullets as
# the parser reads them, because two facts the collapse makes equal can be
# indistinguishable in a message that quotes only the fact.
entry_inline() {
  local out="" ln
  while IFS= read -r ln; do
    [[ -n "$ln" ]] || continue
    out="${out:+$out | }line $ln: '$(owner_bullet "$ln")'"
  done <<EOF
$1
EOF
  printf '%s' "$out"
}

# find_entry <fact> — echo the 1-based line number of the entry whose fact is
# exactly <fact>. Refuses absence and ambiguity rather than picking one: "I acted"
# and "there was nothing to act on" must not be the same answer about a committed
# file, and two entries for one fact is a state the user has to see.
#
# The ambiguity NAMES the candidates, by line and by bullet. Since the comparison is
# collapsed (fact_lines), two entries that differ only in whitespace are one fact recorded
# twice, and a message quoting the fact alone would show the user two identical strings
# and no way to tell the copies apart.
find_entry() {
  local want="$1" hits n
  hits=$(fact_lines "$want")
  n=$(printf '%s' "$hits" | grep -c . || true)
  [[ "$n" != 0 ]] || fail "no entry in $INTENT carries the fact '$want' — nothing to $ACTION"
  [[ "$n" = 1 ]] \
    || fail "$n entries in $INTENT carry the fact '$want' — refusing to guess which one to $ACTION ($(entry_inline "$hits"))"
  printf '%s' "$hits"
}

# entry_scan <line-number> — the ONE walk of an entry, through the reading layer. Emits,
# TAB-separated:
#     guard <TAB> <assertion>    one per stated guard, in FILE ORDER
#     empty                      one per `guard:` line of the entry that states nothing
#     end   <TAB> <line-number>  the last line of the entry's EXTENT (always last)
#
# THE EXTENT IS intent-check.sh'S: the bullet plus every following INDENTED line, with
# BLANK lines HELD — a blank closes nothing, and the lines after it are still the entry's.
# A short extent that stopped at the first blank is what made a retire delete the bullet
# and STRAND the guards below the gap, where the parser then re-attached them to the
# PRECEDING entry: a bystander quarantining on an assertion its author never wrote. The
# same short extent hid a blank-separated guard from GUARD= and DROP_GUARD=1, so those
# reported a replacement or a removal that had not happened.
# Only a `closer`, a new `bullet`, a column-0 `orphan` or a `hidden` guard ends the walk —
# exactly the lines that close an entry over there. The hidden one is load-bearing: while
# it read as `cont` the walk swallowed it into the extent, and the rewrite then deleted a
# committed `guard:` line while re-emitting the entry (see m_class).
entry_scan() {
  awk -v s="$1" "$READ_MODEL"'
    FNR <= s { next }
    { c = m_class(m_norm($0)) }
    c == "blank" { next }                       # HELD: it closes nothing
    c == "cont"  { e = FNR; next }
    c == "guard" {
      e = FNR
      if (M_VAL == "") print "empty"            # a guard-ness the value cannot express
      else printf "guard\t%s\n", M_VAL
      next
    }
    { exit }
    END { printf "end\t%d\n", (e ? e : s) }
  ' "$INTENT"
}

# entry_end <line-number> — the last line of the entry's extent.
entry_end() { entry_scan "$1" | awk -F'\t' '$1 == "end" { print $2 }'; }

# extent_of <line-number> — entry_end, refusing a non-numeric answer. Both rewrites hand
# the extent to awk as `-v e=<n>`, and an EMPTY value there makes `NR <= e` false on every
# line: the entry would survive its own retire while stdout still said "retired", and
# install()'s count would agree because no orphan moved either. A reading that did not
# happen must not read as "the entry ends at line nothing".
extent_of() {
  local e
  e=$(entry_end "$1")
  case "$e" in
    ''|*[!0123456789]*)
      fail "could not read the extent of the entry at line $1 of $INTENT (got '$e') — refusing to rewrite the file" ;;
  esac
  printf '%s' "$e"
}

# guards_of <line-number> — EVERY stated guard of the entry starting there, one per line in
# FILE ORDER, or nothing when it owns none. All of them, deliberately: intent-check.sh's
# grammar allows several and requires ALL to pass, so a caller that reads one guard and
# rewrites the entry deletes live assertions (see the header). Order is preserved because
# intent-check.sh names the failing guard on its QUARANTINED: line and Phase 5 quotes that
# back to the user. The value is trimmed at both ends, its trailing CR with it — the same
# trim the parser applies before tokenizing, so a CRLF checkout's guard is the same guard
# (left in, the CR sat inside the last token and put EVERY guard out of grammar).
guards_of() { entry_scan "$1" | awk -F'\t' '$1 == "guard" { print substr($0, index($0, "\t") + 1) }'; }

# unstated_guards <line-number> — how many `guard:` lines of that entry state NO assertion.
# They cannot travel in a newline-separated guard set at all (an empty line is not a
# member), and re-emitting one would be inventing an assertion, so the keep path refuses
# rather than dropping the line: intent-check.sh calls the ENTRY unparseable for it, and
# dropping it would promote that entry into the active view (see THE CONTRACT).
unstated_guards() { entry_scan "$1" | grep -c '^empty$' || true; }

# guard_count <guards> — how many guards that newline-separated set holds (0 when
# empty). `grep -c .` exits 1 on no match, which `|| true` absorbs; the count is
# still printed.
guard_count() { printf '%s' "$1" | grep -c . || true; }

# guards_inline <guards> — the same set on ONE line for a message. Guard text cannot
# contain a newline (collapse() on the way in, one line per guard in the file), so the
# separator is unambiguous, and a multi-line NOTE or FAIL would break the one-line-
# per-event shape every caller's transcript is read in.
guards_inline() { printf '%s' "$1" | awk 'NR > 1 { printf " | " } { printf "%s", $0 } END { if (NR) print "" }'; }

# orphan_rows <matched-entry-line> <extent-end> — THE ATTRIBUTION WALK, and the only place
# in this file that decides which entry an orphaned `guard:` line belongs to. One pass over
# the file, BOTH spellings, one TAB-delimited row per orphan:
#     <line-number> <TAB> col0|indented <TAB> mine|ownerless|foreign|runtime
#                   <TAB> <attributed-entry-line> <TAB> <nearest-bullet-line> <TAB> <guard-text>
# `attributed` is the entry INTENT-CHECK.SH ATTACHES the line to, and 0 when it attaches it
# to none. `nearest-bullet` is the column-0 `- ` line above it — the author's run, which is
# what adoption and a restore NOTE need when the parser attached the line to nobody.
#
# WHY ONE WALK FOR BOTH SPELLINGS. The two spellings — a column-0 `guard:`, and an INDENTED
# one sitting where no entry is open — reach intent-check.sh's SAME orphan_guard(), so they
# have one attribution rule, and this file had two: a simulation of the parser's retraction
# for the indented spelling, and "the nearest preceding bullet" for the column-0 one. On a
# RUN of two column-0 orphans the two readings part company, because the parser's do:
#   `- ZERO` / `- ONE` / `guard: A` / `guard: B`
# the parser excludes ONE for line 3 (an entry is still OPEN there, so the retraction target
# is untouched) and RETRACTS ZERO for line 4 (nothing is open any more, so the target is the
# last entry that vetted ACTIVE — ZERO). Nearest-bullet made BOTH lines ONE's, so a retire or
# update of ONE deleted line 4 — ZERO's effective guard — and ZERO flipped from UNPARSEABLE
# (excluded, steering nothing) to ACTIVE: the cross-entry fail-OPEN again, reached through
# the SECOND orphan of a run. The same misreading made the sweep NOTE name ONE for a line the
# parser had read against ZERO, so the transcript sent the restore to the wrong entry. One
# walk, one attribution, and every NOTE quotes what this walk found.
#
# THE ATTRIBUTION IS SIMULATED, NOT GUESSED — intent-check.sh's clauses, one for one:
#   * an entry that FLUSHES becomes the retraction target (its LAST_ENTRY_*). The parser
#     only KEEPS it there when the entry vetted ACTIVE, which takes running its guards
#     against the tree, so this walk keeps it and the verdicts below take the fail-CLOSED
#     side of that uncertainty;
#   * an orphan of EITHER spelling reached while no entry is open takes the target and
#     CLEARS it (retract_last_entry, then `LAST_ENTRY_ACTIVE=0`), so the next orphan in a
#     run is attributed to NO entry;
#   * an orphan reached while an entry is still OPEN excludes THAT entry and leaves the
#     target alone — which is exactly how the second orphan of a run reaches back PAST the
#     bullet directly above it;
#   * a blank line closes nothing (BLANKS_HELD), every other column-0 non-bullet line does,
#     and an entry is ANY column-0 `- ` line of the NORMALIZED line — a BOM'd first bullet
#     is one, and the date is not part of the entry grammar, so an UNDATED bullet opens an
#     entry and owns what follows it. This writer only ever MATCHES dated bullets, so an
#     undated one is always another entry's.
#
# THE VERDICTS, and each one's fail-CLOSED argument. `s` is the matched entry's line:
#   * `mine` — the parser attributes the line to the MATCHED entry, or to NO entry while the
#     matched entry is the run it sits in. The caller's own line either way: taking it is
#     faithful (the entry it excluded or retracted is the one being rewritten, or it
#     excluded nothing at all), and LEAVING it is faithful under no reading once the bullet
#     above it moves. These are the lines retire deletes and update adopts or sweeps.
#   * `ownerless` — attributed to no entry with no `- ` line above it anywhere: the parser
#     reports it ALONE and no entry is excluded by it, so it is swept and nothing is
#     promoted. Protecting it instead would put the file back in the append-only,
#     un-repairable state install()'s old global refusal created.
#   * `foreign` — attributed to ANOTHER entry (or to no entry inside another entry's run) in
#     a position this rewrite cannot move: either the attribution sits BEFORE the matched
#     entry, or it names an entry AFTER it, and in both cases the state the parser reads it
#     with is rebuilt from lines this rewrite does not touch. The line stays, that entry
#     stays UNPARSEABLE for its own re-confirm — a named row in Phase 5's table — and the
#     worst case is one extra row instead of a de-guarded fact steering resolutions. A
#     NARROWER ownership reading is what broke this twice (a CONTIGUOUS block, so a blank
#     line, a `---`, a heading, column-0 prose or a wrong-style bullet between a foreign
#     entry and its guard called the line ownerless and swept it; then a `/^- /` on the RAW
#     bytes, so a BOM did the same to entry #1), and the protection does not require that
#     foreign entry to be GUARDLESS either: the parser reports it UNPARSEABLE whether or not
#     it also owns indented guards, so sweeping its column-0 line promotes it into the
#     active view vetted by only the guards that happened to be indented.
#   * `runtime` — the attribution names an entry EARLIER than the matched one for a line
#     BELOW it, which only the retraction path can produce: the parser retracted that entry
#     only if it vetted ACTIVE, and this rewrite changes what the retraction reaches. The
#     two readings want OPPOSITE edits (take the line and that entry goes from UNPARSEABLE
#     to ACTIVE de-guarded; leave it and the rewrite re-points the retraction at another
#     entry, or re-parents the line as a live guard nobody wrote), and only running that
#     entry's guards decides which. So the ACTION IS REFUSED, naming the line and the entry
#     (require_attributable) — the same answer this file gives every self-contradiction.
#
# WHY the sweep is not FILE-GLOBAL (it was): the rewrites carried `/^guard:/ { next }`,
# which deletes every column-0 guard in the file, while adoption — the repair that gives an
# orphan back to its entry — is scoped to the MATCHED entry. So a retire or update aimed at
# entry ONE deleted entry TWO's orphan, and since the orphan is what excluded TWO, TWO
# flipped from UNPARSEABLE to ACTIVE with its assertion deleted. That is the exact fail-OPEN
# the adoption fix was made on, one entry over.
#
# THE REACH DIFFERS BY SPELLING, and only the reach. Column-0 rows cover the WHOLE file:
# the rewrites sweep that spelling with a column-0 pattern and install() counts the survivors
# file-wide, so every one of them needs a verdict. An INDENTED orphan is addressed by LINE
# NUMBER, and one past the next bullet is shielded by it — that bullet rebuilds the parser's
# state, so rewriting the matched entry cannot change what the line is read against — so
# those rows stop at the next entry, as they always did.
orphan_rows() {
  awk -v s="$1" -v e="$2" "$READ_MODEL"'
    # The verdict rule, clause for clause with the header above: `a` is the attribution
    # intent-check.sh makes, `nb` the nearest bullet above, `l` the line the orphan sits on.
    function m_verdict(a, l) {
      if (a == s)  return "mine"
      if (a == 0)  return (nb == s) ? "mine" : ((nb == 0) ? "ownerless" : "foreign")
      if (a < s && l > s) return "runtime"
      return "foreign"
    }
    function m_row(l, sp, a, t) {
      printf "%d\t%s\t%s\t%d\t%d\t%s\n", l, sp, m_verdict(a, l), a, nb, t
    }
    { c = m_class(m_norm($0)) }
    # A bullet FLUSHES the open entry (which becomes the retraction target), opens its own,
    # and is from here on the nearest bullet. `past` marks the shield for the indented rows.
    c == "bullet" { if (open) cand = open; open = FNR; nb = FNR; if (FNR > s) past = 1; next }
    c == "closer" { if (open) { cand = open; open = 0 } next }
    # A HIDDEN guard moves the state of the parser exactly as a column-0 orphan does — over
    # there both reach orphan_guard, which excludes the open entry or retracts the last
    # active one — so it takes the same clause, and only its SPELLING differs. The
    # spelling is what the verdict consumers key on: the sweep may delete a `col0` row,
    # while a `hidden` row is a line no rewrite can re-state, so the paths that would
    # have to re-state it REFUSE (require_no_hidden) and the ones that state the guard
    # set explicitly delete it by LINE with a NOTE (hidden_set).
    c == "orphan" || c == "hidden" {
      if (open) { a = open; open = 0 } else { a = cand; cand = 0 }
      m_row(FNR, (c == "orphan" ? "col0" : "hidden"), a, M_VAL)
      next
    }
    # An INDENTED `guard:` with an entry open is a guard OF that entry, not an orphan; with
    # none open it is the other spelling, and takes (and clears) the retraction target too.
    c == "guard" && !open {
      a = cand; cand = 0
      if (FNR > e && !past) m_row(FNR, "indented", a, M_VAL)
    }
  ' "$INTENT"
}

# protected_set <rows> / protected_count <rows> — the column-0 line numbers to LEAVE ALONE,
# as `,12,15,` for the rewrite awk to test with index(), and how many there are for
# install()'s post-write assertion. Line NUMBERS may travel by -v (the header's rule: they
# have no bytes for awk to escape-process).
protected_set() { printf '%s\n' "$1" | awk -F'\t' '$2 == "col0" && $3 == "foreign" { printf ",%s", $1 } END { print "," }'; }
protected_count() { printf '%s\n' "$1" | awk -F'\t' '$2 == "col0" && $3 == "foreign" { n++ } END { print n + 0 }'; }

# detached_set <rows> — the INDENTED `mine` line numbers as `,4,9,`, for the rewrites to drop
# by NUMBER: these lines are indented, so the column-0 `/^guard:/` sweep cannot see them and
# a pattern would have to guess at the indent.
detached_set() { printf '%s\n' "$1" | awk -F'\t' '$2 == "indented" && $3 == "mine" { printf ",%s", $1 } END { print "," }'; }

# hidden_set <rows> — the HIDDEN guard-like lines the matched entry is read against, as
# `,4,9,` for the rewrites to drop by NUMBER. By number for the same reason the indented
# orphans are: the column-0 `m_class == "orphan"` sweep cannot see a line whose `guard:`
# sits behind an NBSP or a U+200B, and a pattern would have to guess at the lead.
# ONLY `mine`: a hidden line the parser reads against ANOTHER entry stays for that entry's
# own re-confirm (the `foreign` argument at orphan_rows, unchanged by the spelling), and an
# `ownerless` one excludes nothing at all — the parser reports it alone.
hidden_set() { printf '%s\n' "$1" | awk -F'\t' '$2 == "hidden" && $3 == "mine" { printf ",%s", $1 } END { print "," }'; }

# hidden_notes <rows> — the NOTE body for every HIDDEN guard-like line this rewrite
# deletes, one line each, on stdout. Never a MOVE, always a deletion: adoption cannot take
# one of these (see require_no_hidden), so the note is unconditional and quotes the
# assertion, which is the only record of what the line said once it is gone.
hidden_notes() {
  printf '%s\n' "$1" | while IFS=$'\t' read -r ln sp v own nb txt; do
    [[ "$sp" = hidden ]] && [[ "$v" = mine ]] || continue
    printf '%s\n' "swept the guard-like line '$txt' (line $ln of $INTENT), whose \`guard:\` sat behind bytes the indentation grammar does not read (an NBSP, a VT/FF, a stray CR, a U+200B/U+3000 — possibly behind plain spaces): intent-check.sh reports such a line and EXCLUDES the entry it is read against, so it vetted nothing, and leaving it behind would have excluded whatever entry then precedes it. Re-add it as an INDENTED \`guard:\` line — plain spaces only — under the entry it was meant to vet."
  done
}

# require_no_hidden <rows> — refuse the whole action when the parser reads a HIDDEN
# guard-like line against the entry being rewritten. This is the same verdict, for the same
# reason, that a `guard:` line stating NO assertion gets on the same paths (see WHERE THE
# MODEL CANNOT BE MATCHED): the line is a `guard:` its author wrote and neither parser can
# read, so re-stating it is impossible in both directions. Dropping it is the fail-OPEN
# this finding was: `update` absorbed it into the extent and re-emitted the bullet alone,
# deleting a committed assertion with exit 0 and no NOTE. And ADOPTING it — re-emitting the
# text past `guard:` as a plain indented guard, which is what the column-0 orphan repair
# does — only looks safe: the invisible bytes are not confined to the LEAD, so
# `<NBSP>guard: test -e we<NBSP>b` adopts into a guard that is STILL out of grammar and the
# entry STILL excluded, with "updated" on stdout and nothing said. That is the false
# success this layer exists to prevent, so the reachable answers are the ones that state
# the intent: GUARD=<assertion>, DROP_GUARD=1, or retire — each of which sweeps the line
# and NAMES it (hidden_notes).
require_no_hidden() {
  local row ln sp v own nb txt who
  row=$(printf '%s\n' "$1" | awk -F'\t' '$2 == "hidden" && $3 == "mine" { print; exit }')
  [[ -n "$row" ]] || return 0
  IFS=$'\t' read -r ln sp v own nb txt <<EOF
$row
EOF
  # `mine` is either "attributed to the matched entry" or "attributed to no entry while
  # sitting in its run", so the entry to NAME is the attribution when there is one and the
  # run's bullet otherwise — the same distinction sweep_notes draws, and `0` is a line
  # number no `${x:-…}` default would catch (it is set, just not a line).
  who=${own:-0}
  [[ "$who" != 0 ]] || who=${nb:-0}
  fail "line $ln of $INTENT is a \`guard:\` line hidden behind bytes the indentation grammar does not read — an NBSP, a vertical tab, a form feed, a stray CR, a U+200B or U+3000, possibly behind plain spaces — and intent-check.sh reports it and EXCLUDES the entry it is read against ('$(owner_bullet "$who")'). Its assertion reads '$txt', but this writer cannot re-state a line neither parser can read: re-emitting it would launder invisible bytes into a live guard (any of them PAST \`guard:\` leave it out of grammar, so the entry stays excluded while this run reports success), and dropping it would delete a committed assertion silently. Say what the entry must carry — GUARD=<tree assertion> to replace its guard set, DROP_GUARD=1 to leave the fact guardless, or ACTION=retire to take the whole entry — or re-indent that line with PLAIN SPACES directly under the entry it vets and re-run. Nothing was written"
}

# claimed_count <rows> <spelling> — how many orphans of that spelling the matched entry
# takes (0 when none). One NOTE per spelling is printed from these.
claimed_count() { printf '%s\n' "$1" | awk -F'\t' -v sp="$2" '$2 == sp && $3 == "mine" { n++ } END { print n + 0 }'; }

# claimed_rows <rows> — `<line> <TAB> <assertion>` for every orphan the matched entry takes,
# BOTH spellings, in FILE ORDER (the walk emits in file order, so no merge is needed). The
# ADOPTION set, and it is the same set the sweep is allowed to delete — one rule, one
# reading, one scope, because anything narrower makes the repair itself the fail-OPEN. The
# text is read as "everything past the fifth TAB" rather than as $6, so an assertion carrying
# a tab is not silently truncated into a shorter guard on the way back in.
# `$2 != "hidden"` is belt: a hidden line is never adoptable (require_no_hidden refuses
# every path that would reach here with one), and the exclusion makes that structural
# rather than dependent on the order of two calls.
claimed_rows() {
  printf '%s\n' "$1" | awk -F'\t' '$3 == "mine" && $2 != "hidden" {
    s = $0; for (i = 0; i < 5; i++) s = substr(s, index(s, "\t") + 1)
    printf "%s\t%s\n", $1, s
  }'
}

# claimed_texts <claimed-rows> — the assertions alone, in that order, skipping any row whose
# guard states NOTHING: an empty assertion cannot travel in a newline-separated set, and the
# count mismatch it leaves is what the keep path refuses on (see the update path).
claimed_texts() {
  printf '%s\n' "$1" | awk -F'\t' 'NF > 1 { t = substr($0, index($0, "\t") + 1); if (t != "") print t }'
}

# require_attributable <rows> — refuse the whole action when the parser's attribution of any
# orphan is one this rewrite would decide (verdict `runtime`; see orphan_rows). Fail CLOSED
# and name the line, its assertion and the entry: the caller can re-indent it directly under
# the entry it was meant to vet (nothing but blank lines between) or settle that entry first,
# and both of those state an intent this writer cannot infer. Either spelling can reach here,
# so the message says which line it is looking at.
require_attributable() {
  local row ln sp v own nb txt shape
  row=$(printf '%s\n' "$1" | awk -F'\t' '$3 == "runtime" { print; exit }')
  [[ -n "$row" ]] || return 0
  IFS=$'\t' read -r ln sp v own nb txt <<EOF
$row
EOF
  case "$sp" in
    col0)   shape="a COLUMN-0 \`guard: $txt\`, the second orphan of a run" ;;
    hidden) shape="a \`guard: $txt\` HIDDEN behind bytes the indentation grammar does not read" ;;
    *)      shape="an INDENTED \`guard: $txt\` sitting where NO entry is open" ;;
  esac
  fail "line $ln of $INTENT is $shape, and intent-check.sh attributes it to the entry '$(owner_bullet "$own")' — which this $ACTION does not act on — whenever that entry vetted ACTIVE, and to no entry at all otherwise. Which of the two it did depends on guard results only the parser evaluates, and the two readings want opposite edits here (taking the line promotes that entry into the active view de-guarded; leaving it re-points the retraction, or re-parents the line onto an entry as a live guard nobody wrote), so this writer refuses rather than guess. Re-indent that line directly under the entry it was meant to vet — nothing but blank lines between — or settle that entry first, then re-run"
}

# detached_notes <rows> <adopted?> — the NOTE body for every INDENTED orphan this rewrite
# DELETES, one line each, on stdout. Skipped when this run ADOPTED, exactly like the
# column-0 notes: those lines MOVED, and calling a move a deletion is the opposite of true.
detached_notes() {
  [[ "$2" = 0 ]] || return 0
  printf '%s\n' "$1" | while IFS=$'\t' read -r ln sp v own nb txt; do
    [[ "$sp" = indented ]] && [[ "$v" = mine ]] || continue
    printf '%s\n' "swept the orphaned indented guard '$txt' (line $ln of $INTENT) — a closer separates it from its entry, so intent-check.sh reports it as an orphan that vetted nothing and RETRACTS the entry above it, and leaving it behind would have re-attached it to whatever entry precedes it after this $ACTION. Re-add it as an INDENTED \`guard:\` line under the entry it was meant to vet, with nothing but blank lines between them."
  done
}

# owner_bullet <line-number> — that line as the PARSER reads it, for a NOTE that quotes an
# entry back to the caller. Through the layer like everything else: the raw bytes would put
# a stray CR (or a BOM) inside a message whose whole contract is one line per event.
owner_bullet() { awk -v n="$1" "$READ_MODEL"'FNR == n { print m_norm($0); exit }' "$INTENT"; }

# sweep_notes <rows> <adopted-count> — the NOTE body for every COLUMN-0 orphan this rewrite
# DELETES, one line each, on stdout.
#
# WHY the note names the TEXT and the BULLET and not a count: both are what putting
# the line back needs. "swept 1 orphaned column-0 guard line" named neither the
# assertion that went nor the entry it sat beneath, so the transcript recorded that
# something was deleted without recording what — and the whole reason this writer
# announces its unnamed edits is that the run's transcript is the record.
#
# WHY THE BULLET IT NAMES IS THE PARSER'S ATTRIBUTION AND NOTHING ELSE (orphan_rows): the
# note exists to be acted on, and the entry that LOST the assertion is the one it has to
# name. Naming the nearest bullet instead was wrong twice over — for a line the parser had
# read against an EARLIER entry it named a bullet the line was never attached to, and for a
# line the parser attached to NO entry (an orphan above it had already excluded the run's
# entry, so there was nothing left to retract) it claimed an attachment the parser never
# made. Both send whoever restores the line to the wrong place, which is the one job this
# announcement has. So: the attributed entry when there is one, and otherwise the fact that
# there is none — with the run's bullet still named, because that is where the line SAT.
#
# The ADOPTED lines are skipped: those MOVED (re-emitted as the entry's indented guards),
# and calling that a deletion is the opposite of true. The skip is every row the matched
# entry CLAIMS when this run adopted, which is exact because adoption and the claim are the
# SAME set — while adoption took only the contiguous run, the skip had to be a LINE RANGE,
# and a matched entry could own an orphan past a blank that the rewrite genuinely deleted
# while the note called it moved: a silent deletion inside the announcement built to prevent
# silent deletions.
#
# The note does NOT offer "run update on that entry to adopt it" as the remedy, even
# though that is the repair for an orphan generally: an orphan that reaches this
# function is one adoption cannot take — attributed to no entry outside any run, or the
# MATCHED entry's in a shape adoption is refused for (just retired, re-guarded explicitly by
# the caller, or already carrying indented guards of its own). Naming a remedy that would
# not fire is worse than naming none, so the note states the hand shape instead.
sweep_notes() {
  printf '%s\n' "$1" | while IFS=$'\t' read -r ln sp v att nb txt; do
    [[ "$sp" = col0 ]] || continue
    case "$v" in mine|ownerless) ;; *) continue ;; esac
    if [[ "$2" != 0 ]] && [[ "$v" = mine ]]; then
      continue    # this line MOVED into the entry that claimed it — see the header
    fi
    if [[ "${att:-0}" != 0 ]]; then
      # The entry is named as the parser's ATTACHMENT and not as "the bullet directly
      # above": the attachment reaches back across blank lines and structure, and past the
      # bullet above when an orphan already excluded it, so a NOTE claiming adjacency would
      # send whoever restores the line to the wrong place.
      printf '%s\n' "swept the orphaned column-0 guard '$txt' (line $ln of $INTENT) — intent-check.sh attaches it to the entry '$(owner_bullet "$att")', where it vetted nothing: a column-0 guard is unowned by definition, and the shape makes that entry UNPARSEABLE. Re-add it as an INDENTED \`guard:\` line under an entry if it was meant to vet that entry's fact."
    elif [[ "${nb:-0}" != 0 ]]; then
      printf '%s\n' "swept the orphaned column-0 guard '$txt' (line $ln of $INTENT) — intent-check.sh attaches it to NO entry: an orphaned guard above it had already excluded '$(owner_bullet "$nb")', the entry whose lines it sat among, so this line retracted nothing and vetted nothing. Re-add it as an INDENTED \`guard:\` line under the entry it was meant to vet."
    else
      printf '%s\n' "swept the orphaned column-0 guard '$txt' (line $ln of $INTENT) — no entry precedes it in the file, so intent-check.sh reports it alone and it vetted nothing (a column-0 guard is unowned by definition)"
    fi
  done
}

# install <tmp> <orphans-that-must-survive> — verify the result matches what the
# rewrite promised about this file's grammar, then rename it over the intent file.
# Same temp-file discipline as in-progress.sh: a half-written committed file is the
# failure being designed out. The check stays an ASSERTION, not a repair.
#
# WHY it is a COUNT and no longer "carries no column-0 guard at all": that global form
# was only satisfiable while the sweep was global, and the global sweep is the
# cross-entry fail-OPEN described at orphan_rows(). The protected orphans are meant to
# survive, so the assertion is that EXACTLY those did — a rewrite that dropped one, or
# left an extra, no longer matches the parser's grammar the way it claimed to.
install() {
  local n imode
  # Counted through the reading layer, not `grep -cE '^guard:'`: the assertion has to see
  # the same column-0 guards the rewrite decided about, or a shape one of them reads
  # differently (a BOM'd first line) would make the check pass over a file the parser
  # still finds an orphan in — or refuse a file that is fine.
  #
  # FAIL-CLOSED on the count itself: an awk that could not run or read the temp
  # file is not "0 orphans" — with `|| true` and `${n:-0}` it was, and since the
  # expected count is 0 in the common case, an UNVERIFIED file sailed past the
  # last line of defence and was mv'd over the committed ledger. The END block
  # always prints (`n + 0`), so empty output and a non-zero exit both mean the
  # verification never happened, and neither may install.
  n=$(awk "$READ_MODEL"'{ if (m_class(m_norm($0)) == "orphan") n++ } END { print n + 0 }' "$1" 2>/dev/null) \
    || fail "could not verify the rewritten $INTENT (the orphan-count assertion did not run) — refusing to install an unverified file"
  [[ -n "$n" ]] \
    || fail "could not verify the rewritten $INTENT (the orphan-count assertion printed nothing) — refusing to install an unverified file"
  [[ "$n" = "$2" ]] \
    || fail "the rewritten $INTENT would carry $n column-0 guard line(s) where exactly $2 were meant to survive (the orphan runs owned by OTHER entries, left for their own re-confirm) — refusing to write it"
  # mktemp made $1 mode 0600; a bare mv would stamp that private mode onto the committed
  # ledger, invisible to git and unreadable by the shared checkouts and CI readers that
  # travel with it. retire/update only ever rewrite an EXISTING $INTENT (find_entry
  # required it), so carry that file's own mode across. There is no `chmod --reference`
  # on macOS, so the mode is read explicitly — GNU `stat -c %a` FIRST, then BSD
  # `stat -f %Lp`. `stat -f` is BSD's format flag but GNU's `--file-system` (reading
  # `'%Lp'` as a bogus filename): the BSD-first order returned a filesystem dump under
  # CI's Linux, chmod rejected it, and the ledger silently stayed 0600. The octal guard
  # drops any non-octal reading so garbage can never reach chmod. Best-effort throughout:
  # a failure leaves 0600, exactly the pre-fix behaviour, never a lost rewrite.
  imode=$(stat -c '%a' "$INTENT" 2>/dev/null || stat -f '%Lp' "$INTENT" 2>/dev/null) || imode=""
  case "$imode" in *[!0-7]*|'') imode="" ;; esac
  [[ -z "$imode" ]] || chmod "$imode" "$1" 2>/dev/null || true
  mv "$1" "$INTENT" || fail "could not write $INTENT"
}

D=$(dirname "$INTENT")
[[ -d "$D" ]] || mkdir -p "$D" || fail "cannot create $D"

# Before any action, including append: a file the parser refuses WHOLE is a file whose
# facts are not readable, and appending a fact to it is as pointless as rewriting one.
file_gate

case "$ACTION" in
  append)
    [[ -n "$ENTRY" ]] || fail "ENTRY required (the standing intent fact)"
    [[ -f "$INTENT" ]] || : > "$INTENT" || fail "cannot create $INTENT"
    BULLET="- $DATE: $ENTRY"

    # Idempotence, and its fail-closed twin. An already-recorded fact is a no-op:
    # Phase 8's promotion, Phase 5's re-confirm and abort's salvage can all meet the
    # same fact in one component's life, and a stacked duplicate doubles every guard
    # evaluation and every resolver's reading of it. The same fact with a DIFFERENT
    # guard is not a duplicate and not an append — it is an update, and guessing
    # which guard wins is the silent de-guarding this writer prevents.
    #
    # WHY the comparison is the whole guard SET and not the entry's first guard:
    # append writes at most one guard, so it cannot express a multi-guard entry at
    # all. Comparing only the first said "already recorded, nothing to do" about an
    # entry carrying an assertion the caller never mentioned — the caller then
    # believed the file says what it passed. Neither branch writes anything, so the
    # refusal costs the file nothing and names the action that can express the change.
    #
    # WHY the match is on the FACT, not on the whole bullet: a bullet carries its
    # date, so a date-scoped dedup only recognises a re-append made on the SAME UTC
    # day. Runs cross midnight (Phase 5 re-confirms, Phase 8 promotes hours later)
    # and an aborted run's salvage is re-promoted by a LATER run — both meet the fact
    # under a new date, and both used to stack a second entry. That duplicate then
    # poisoned the fact permanently: find_entry refuses ambiguity, so retire and
    # update could never touch it again. The existing entry wins untouched; re-dating
    # a fact deliberately is what ACTION=update is for.
    #
    # WHY an UNSTATED guard on the recorded entry is a refusal and not "unchanged": the
    # recorded set holds a `guard:` line stating nothing, which no GUARD value can be
    # equal to — the parser reports that ENTRY as UNPARSEABLE, so the fact IS recorded and
    # vets nothing. Answering "unchanged" would tell the caller the file already says what
    # it passed, about an entry steering nothing; the refusal names the action that can
    # repair it. Checked before the dedup, because fail-closed comes first.
    #
    # WHY a fact already recorded TWICE is a refusal and not a dedup hit: the fact is
    # ambiguous for every later action (find_entry refuses it), so answering "unchanged"
    # would tell the caller the file says what it passed about a state no retire or update
    # can reach. The collapse makes this reachable without a hand edit — two entries
    # differing only in whitespace are one fact recorded twice — so the refusal names both.
    HITS=$(fact_lines "$ENTRY")
    NHITS=$(printf '%s' "$HITS" | grep -c . || true)
    [[ "$NHITS" -le 1 ]] \
      || fail "$INTENT already carries this fact on $NHITS entries ($(entry_inline "$HITS")) — collapsed the way every field here is, they are ONE fact recorded twice, which no MATCH can name unambiguously. Retire or hand-resolve the copies down to one and re-run; nothing was appended"

    DUP=0
    CONFLICT=""
    UNSTATED_HIT=0
    ORPHAN_HIT=0
    while IFS= read -r n; do
      [[ -n "$n" ]] || continue
      # The recorded entry's guard set is only comparable when the parser reads it
      # WHOLE: an orphaned `guard:` this entry OWNS — the forgot-the-indent shape
      # (a column-0 guard under the bullet), or an indented one a closer detached —
      # is invisible to the extent-scoped guards_of below, and intent-check.sh
      # reports the ENTRY as UNPARSEABLE for it, so the fact is recorded and vets
      # nothing. "unchanged" would then say the file already records what was
      # passed (about an entry steering nothing), and with GUARD set the conflict
      # message below would quote the recorded guard as '<none>' and send the
      # caller to the wrong repair.
      OE=$(extent_of "$n") || exit 2
      OROWS=$(orphan_rows "$n" "$OE")
      # A HIDDEN guard-like line on the recorded entry is refused with its own message
      # before the generic orphan count below claims it: the orphan message names ADOPTION
      # as the repair, and adoption is precisely what a hidden line cannot have
      # (require_no_hidden), so it would send the caller into a refusal loop.
      require_no_hidden "$OROWS"
      # A `runtime`-verdict orphan is intercepted the SAME way, and for the SAME reason:
      # the generic message below names ACTION=update as the repair, but require_attributable
      # refuses a runtime row on that very path — so following the advice loops. Its own
      # message states the fix this writer cannot infer (re-indent the line, or settle that
      # entry first), so the count below need only weigh `mine` rows.
      require_attributable "$OROWS"
      NOWNED=$(printf '%s\n' "$OROWS" | awk -F'\t' '$3 == "mine" { c++ } END { print c + 0 }')
      if [[ "$NOWNED" != 0 ]]; then ORPHAN_HIT=1; continue; fi
      if [[ "$(unstated_guards "$n")" != 0 ]]; then UNSTATED_HIT=1; continue; fi
      g=$(guards_of "$n")
      if [[ "$g" = "$GUARD" ]]; then DUP=1; else CONFLICT="$(guards_inline "${g:-<none>}")"; fi
    done <<EOF
$HITS
EOF

    [[ "$ORPHAN_HIT" = 0 ]] \
      || fail "$INTENT already carries this fact on an entry that OWNS orphaned \`guard:\` line(s) — intent-check.sh reports that ENTRY as UNPARSEABLE for them, so the fact is recorded and vets nothing, and 'unchanged' would claim the file already says what was passed. Repair that entry with ACTION=update (guardless, it adopts the orphans back as its own indented guards; GUARD=<tree assertion> or DROP_GUARD=1 replaces or drops them); appending would leave two entries for one fact"
    [[ "$UNSTATED_HIT" = 0 ]] \
      || fail "$INTENT already carries this fact on an entry whose \`guard:\` line states no assertion — intent-check.sh decides guard-ness by the prefix and reports that ENTRY as UNPARSEABLE, so the fact is recorded and vets nothing. Repair that entry with ACTION=update (GUARD=<tree assertion> to state the guard, DROP_GUARD=1 to remove it); appending would leave two entries for one fact"
    if [[ "$DUP" = 1 ]]; then echo "unchanged"; exit 0; fi
    [[ -z "$CONFLICT" ]] \
      || fail "$INTENT already carries this fact with a different guard ('$CONFLICT') — use ACTION=update to change a guard; appending would leave two entries for one fact"

    # THE FILE'S LAST BYTE decides where the new bullet starts, and it is part of the
    # reading model: intent-check.sh's line reader takes a final UNTERMINATED line as a
    # line (`while … read -r line || [ -n "$line" ]`), so the writer must land its bullet
    # at column 0 of a NEW line even when the file does not end in one. Appending straight
    # on SPLICED the bullet onto that final line — onto a trailing indented `guard:` that
    # made ONE out-of-grammar guard line and no new entry at all (exit 0, "appended", the
    # fact unreachable by MATCH ever after and the entry above it excluded), and onto a
    # trailing bullet it fused two facts into one unreadable line. The missing newline is
    # emitted FIRST, which changes no byte of the final line and so cannot change the
    # parser's reading of it, whichever class it belongs to (bullet, guard, orphan, prose).
    # `$(tail -c 1)` is empty ONLY for a final newline: command substitution strips
    # trailing NEWLINES and nothing else, so a final space, tab or CR still reads non-empty
    # and still gets its terminator. An empty (or just-created) file needs none.
    [[ ! -s "$INTENT" ]] || [[ -z "$(tail -c 1 "$INTENT")" ]] \
      || printf '\n' >> "$INTENT" || fail "cannot append to $INTENT"
    # The bullet and its guard go in as ONE unit — literally ONE write(2), not a group
    # of two printfs sharing a redirect. A kill BETWEEN two writes would land the bullet
    # without its guard: a guardless ACTIVE entry, the exact fail-open the "one unit"
    # contract exists to prevent. The full text is built first and emitted with a single
    # printf (well under a stdio buffer, so it is one write), so no interruption can split
    # the two lines.
    APP="$BULLET"$'\n'
    [[ -z "$GUARD" ]] || APP="$APP  guard: $GUARD"$'\n'
    printf '%s' "$APP" >> "$INTENT" || fail "cannot append to $INTENT"
    echo "appended"
    ;;

  retire)
    [[ -n "$MATCH" ]] || fail "MATCH required (the exact fact of the entry to retire)"
    [[ -f "$INTENT" ]] || fail "no $INTENT — nothing to retire"
    # find_entry runs in a command substitution, so its fail() exits the SUBSHELL —
    # the refusal has to be propagated here or the rewrite runs on an empty match.
    S=$(find_entry "$MATCH") || exit 2
    E=$(extent_of "$S") || exit 2
    # The orphan verdicts — BOTH spellings, one attribution walk (orphan_rows) — and the
    # notes that name what goes, are read from the file BEFORE it is rewritten: afterwards
    # the swept lines and the bullets they sat under are gone, and the NOTE's whole job is to
    # record them. Vetted before anything is written too: an orphan whose attribution this
    # rewrite would decide refuses the whole retire rather than being guessed at.
    ROWS=$(orphan_rows "$S" "$E")
    require_attributable "$ROWS"
    DSET=$(detached_set "$ROWS")
    # A retire STATES the intent for every line under the entry — the entry and its guards
    # are what it deletes — so it is one of the three ways through a HIDDEN guard-like line
    # (require_no_hidden). It takes those lines with the entry, by number, for the reason
    # the detached orphans go: left behind, the next vet reads the line against whatever
    # entry then precedes it and EXCLUDES that bystander.
    HSET=$(hidden_set "$ROWS")
    HIDDEN_NOTES=$(hidden_notes "$ROWS")
    PROT=$(protected_set "$ROWS")
    NPROT=$(protected_count "$ROWS")
    SWEEP_NOTES=$(sweep_notes "$ROWS" 0)
    DETACHED_NOTES=$(detached_notes "$ROWS" 0)
    TMP=$(mktemp "$D/.intent.md.XXXXXX") || fail "cannot create a temp file next to $INTENT"
    trap 'rm -f "$TMP"' EXIT
    # The bullet AND its whole EXTENT go together — the reading layer's extent, so held
    # blank lines and every indented line past them go too. Deleting only the bullet is
    # what leaves the orphaned guard; deleting a SHORT extent is what STRANDED the guards
    # below a blank, which the parser then re-attached to the entry ABOVE. Any orphan the
    # file ALREADY carried that no OTHER entry is read against goes out in the SAME awk, so a
    # legacy
    # one cannot veto this retire. The retired entry's OWN orphans always go: the entry
    # they were attached to is being deleted, and leaving them behind would slide them up
    # against whatever entry precedes and silently de-guard THAT one.
    #
    # WHY one awk and not `awk … | sweep`: with only `set -u` a pipeline reports the
    # LAST command's status, so a failed read of $INTENT would be masked by a
    # successful filter, `|| fail` would not fire, and install() would happily land
    # the EMPTY result — its orphan check passes on an empty file when nothing was
    # protected. One process, one status, one `|| fail`.
    awk -v s="$S" -v e="$E" -v prot="$PROT" -v det="$DSET" -v hid="$HSET" "$READ_MODEL"'
      # THE READING LAYER, once, for every rule below: the rules decide on the NORMALIZED
      # line and every passthrough prints `raw`, so a line this rewrite does not touch
      # keeps its own bytes (its CR, a line-1 BOM) while `/^guard:/` still sees what the
      # parser sees.
      { raw = $0; $0 = m_norm($0); cls = m_class($0) }
      NR >= s && NR <= e { next }   # the entry and its whole extent
      # A DETACHED orphan of this entry: an INDENTED guard past the extent that the parser
      # attributes to it (orphan_rows). Addressed by LINE because the indent is not the
      # column-0 sweep pattern, and taken here so it cannot strand onto a bystander.
      index(det, "," NR ",") { next }
      # A HIDDEN guard-like line of this entry — by LINE too, and for the same reason
      # doubled: the lead is not the column-0 pattern AND it is not the space/tab indent.
      index(hid, "," NR ",") { next }
      # A protected orphan rides through untouched: intent-check.sh reads it against ANOTHER
      # entry, still waiting to re-confirm it (orphan_rows). Order does the exemption, so the
      # sweep rule below stays the plain unconditional statement it always was. The sweep
      # keys on m_class == "orphan", not `/^guard:/`, so a `guard:` hidden behind a
      # whitespace-variant indent (m_class routes it to the same orphan verdict) is swept
      # too — the divergence Finding 4 closed, where such a line survived as a closer.
      cls == "orphan" && index(prot, "," NR ",") { print raw; next }
      cls == "orphan"    { next }   # every other orphan (see the header)
      { print raw }
    ' "$INTENT" > "$TMP" || fail "cannot rewrite $INTENT"
    install "$TMP" "$NPROT"
    trap - EXIT
    [[ -z "$SWEEP_NOTES" ]] || printf '%s\n' "$SWEEP_NOTES" | while IFS= read -r m; do note "$m"; done
    [[ -z "$DETACHED_NOTES" ]] || printf '%s\n' "$DETACHED_NOTES" | while IFS= read -r m; do note "$m"; done
    [[ -z "$HIDDEN_NOTES" ]] || printf '%s\n' "$HIDDEN_NOTES" | while IFS= read -r m; do note "$m"; done
    echo "retired"
    ;;

  update)
    [[ -n "$MATCH" ]] || fail "MATCH required (the exact fact of the entry to update)"
    [[ -n "$ENTRY" ]] || fail "ENTRY required (the new fact)"
    [[ -f "$INTENT" ]] || fail "no $INTENT — nothing to update"
    # find_entry runs in a command substitution, so its fail() exits the SUBSHELL —
    # the refusal has to be propagated here or the rewrite runs on an empty match.
    S=$(find_entry "$MATCH") || exit 2
    E=$(extent_of "$S") || exit 2
    # THE NEW FACT is checked against the rest of the file BEFORE anything is
    # rewritten — the same door append guards with its fact_lines dedup. An update
    # that lands ENTRY while a DIFFERENT entry already carries it records one fact
    # twice past that door, and the duplicate poisons the fact permanently:
    # find_entry refuses ambiguity, so update, retire AND append all exit 2 on it
    # from then on — and the file still parses cleanly, so the sanctioned hand-edit
    # exception does not apply either. Reachable straight from Phase 5's re-confirm
    # when canonicalizing two near-identical facts into one wording. A hit on the
    # matched entry itself is the re-affirm case (ENTRY == MATCH, date refresh) and
    # stays allowed.
    EDUP=""
    while IFS= read -r n; do
      [[ -n "$n" ]] || continue
      [[ "$n" = "$S" ]] || EDUP="$n"
    done <<EOF
$(fact_lines "$ENTRY")
EOF
    [[ -z "$EDUP" ]] \
      || fail "$INTENT already carries the new fact on another entry ($(entry_inline "$EDUP")) — updating '$MATCH' to it would record one fact twice, which no MATCH could then name unambiguously (update, retire and append all refuse an ambiguous fact). Retire one of the two entries, or update to a distinct wording; nothing was rewritten"
    # The attribution walk runs BEFORE the guards are resolved, for both spellings at once:
    # adoption's set IS the set the sweep may take, so it comes out of these rows rather than
    # out of a second rule (orphan_rows). Vetted before any guard is resolved too, because an
    # orphan whose attribution this rewrite would decide refuses the update whole: with the
    # caller told the guard set it asked for is in force, a line left behind would go on
    # excluding the entry (or worse, land on a bystander) with nothing said.
    ROWS=$(orphan_rows "$S" "$E")
    require_attributable "$ROWS"
    DSET=$(detached_set "$ROWS")
    # Guard resolution: GUARD replaces ALL, DROP_GUARD removes ALL, neither keeps ALL
    # in file order — and "keeps" also includes ADOPTING every orphan the parser reads
    # against the guardless matched entry.
    #
    # WHY every guard and not the first: intent-check.sh requires ALL of an entry's
    # guards to pass, and this script's own adoption path emits two-guard entries, so
    # keeping one and re-emitting one silently deleted live assertions and turned a
    # quarantining entry into an ACTIVE one — the fail-OPEN this file exists to
    # prevent. A caller-given GUARD may still collapse a set to one line (it is
    # user-directed), but that DROPS committed assertions the caller never named, so
    # it takes a NOTE like every other unnamed edit here.
    #
    # WHY adoption: `- fact` followed by a column-0 `guard:` IS the legacy
    # malformation — it is what a prose append that forgot the indent leaves, and it
    # is the shape Phase 5's re-confirm is handed. Sweeping it here would delete the
    # user's assertion, print "updated", and say nothing; the fact would then steer
    # every later resolution with no guard running — the exact failure the unparseable
    # bucket exists to report. Re-attaching it is the only reading of that shape that
    # loses nothing. Scoped by the ATTRIBUTION and by one condition: an entry that ALREADY owns
    # an indented guard keeps its own and the orphans below it are still swept, because
    # stapling an unrelated line onto a fact would be the same silent de-guarding
    # wearing the opposite mask. An explicit GUARD or DROP_GUARD always wins — the
    # caller stated the intent, so there is nothing to infer.
    ADOPTED=0
    REPLACED=0
    OLD_GUARDS=""
    if [[ "$DROP_GUARD" = 1 ]]; then
      NEW_GUARDS=""
    elif [[ -n "$GUARD" ]]; then
      NEW_GUARDS="$GUARD"
      OLD_GUARDS=$(guards_of "$S")
      REPLACED=$(guard_count "$OLD_GUARDS")
    else
      # The KEEP path is the only one that has to RE-STATE what the file already says, so
      # it is the only one a `guard:` line stating nothing can defeat: guard-ness is the
      # prefix (intent-check.sh reports the ENTRY unparseable for it), an empty assertion
      # cannot travel in a newline-separated set, and re-emitting one would be inventing
      # the assertion. Dropping it instead is what promoted such an entry into the ACTIVE
      # view, guardless, saying nothing. GUARD= and DROP_GUARD=1 state the intent, so they
      # are the way through — and so is retire, which takes the whole entry.
      #
      # A HIDDEN guard-like line is the same refusal for the same reason, one spelling
      # over: the keep path must RE-STATE the entry's guard set, and a `guard:` behind
      # bytes neither parser reads has no faithful re-statement — dropping it deletes a
      # committed assertion (this finding), adopting it launders invisible bytes into a
      # guard that may still be out of grammar while this run reports success.
      require_no_hidden "$ROWS"
      UNSTATED=$(unstated_guards "$S")
      [[ "$UNSTATED" = 0 ]] \
        || fail "the entry '$MATCH' carries $UNSTATED \`guard:\` line(s) stating no assertion — intent-check.sh decides guard-ness by the \`guard:\` prefix and reports that ENTRY as UNPARSEABLE for it, and this writer will not decide what the author meant to assert: pass GUARD=<tree assertion> to state it, or DROP_GUARD=1 to remove it"
      NEW_GUARDS=$(guards_of "$S")
      if [[ -z "$NEW_GUARDS" ]]; then
        # Adoption's scope is the CLAIM — the same walk, the same attribution and the same
        # verdict as the sweep. Anything narrower deletes an orphan of the CALLER'S OWN entry
        # behind its back (see the header). BOTH spellings travel: a column-0 orphan the
        # parser reads against this entry and an indented one a closer detached from it are
        # the same malformation and the same repair, so they are adopted together, in file
        # order.
        AROWS=$(claimed_rows "$ROWS")
        NEW_GUARDS=$(claimed_texts "$AROWS")
        ADOPTED=$(guard_count "$NEW_GUARDS")
        NOWNED=$(printf '%s' "$AROWS" | grep -c . || true)
        [[ "$NOWNED" = "$ADOPTED" ]] \
          || fail "$((NOWNED - ADOPTED)) of the $NOWNED orphaned \`guard:\` line(s) this entry ('$MATCH') would adopt state no assertion — adopting them would mean inventing one, and dropping them would promote this entry into the active view unvetted: pass GUARD=<tree assertion> to state the guard this fact should carry, or DROP_GUARD=1 to leave it guardless"
      else
        # The SAME empty-assertion check on the sweep path, or the third sub-case
        # slips through: an entry that already owns a stated indented guard AND an
        # orphaned bare `guard:` (stating nothing). The stated guard routes this
        # update past the adoption block, the sweep takes the orphan, and the entry
        # leaves the UNPARSEABLE bucket vetted only by the guards that happened to
        # be indented — with a NOTE quoting an empty assertion, so the transcript
        # cannot restore what lifted the exclusion. An orphan WITH an assertion is
        # different: its sweep is deliberate and its NOTE carries the text back.
        AROWS=$(claimed_rows "$ROWS")
        NOWNED=$(printf '%s' "$AROWS" | grep -c . || true)
        NSTATED=$(guard_count "$(claimed_texts "$AROWS")")
        [[ "$NOWNED" = "$NSTATED" ]] \
          || fail "$((NOWNED - NSTATED)) of the $NOWNED orphaned \`guard:\` line(s) this entry ('$MATCH') owns state no assertion — sweeping them would silently promote the entry into the active view vetted only by its stated guard(s), and this writer will not decide what the author meant to assert: pass GUARD=<tree assertion> to state the full guard set this fact should carry, or DROP_GUARD=1 to leave it guardless"
      fi
    fi
    # Read before the rewrite: afterwards the swept lines, and the bullets they sat
    # under, are gone. Whether this run ADOPTED is passed on so the notes never call a
    # MOVE a deletion.
    PROT=$(protected_set "$ROWS")
    NPROT=$(protected_count "$ROWS")
    # Reachable only past require_no_hidden, i.e. only when the caller STATED the guard set
    # (GUARD= or DROP_GUARD=1). Then a hidden guard-like line of this entry is deleted and
    # named, exactly like the orphans that same statement lets the rewrite sweep.
    HSET=$(hidden_set "$ROWS")
    HIDDEN_NOTES=$(hidden_notes "$ROWS")
    SWEEP_NOTES=$(sweep_notes "$ROWS" "$ADOPTED")
    DETACHED_NOTES=$(detached_notes "$ROWS" "$ADOPTED")
    NADOPT_COL0=$(claimed_count "$ROWS" col0)
    NADOPT_DET=$(claimed_count "$ROWS" indented)
    TMP=$(mktemp "$D/.intent.md.XXXXXX") || fail "cannot create a temp file next to $INTENT"
    trap 'rm -f "$TMP"' EXIT
    # One awk for the whole rewrite — head, the new entry, tail, sweep — for the
    # reason spelled out in the retire path: a brace group's status is its LAST
    # command's, so a failed read of $INTENT in the head was already invisible to
    # `|| fail`, and installing the truncated result would commit data loss.
    # The new bullet and guard travel by ENVIRONMENT, never by -v: fact_lines' bug
    # in the other direction — awk would escape-process a backslash in the fact and
    # write bytes the user never typed.
    b="- $DATE: $ENTRY" g="$NEW_GUARDS" awk -v s="$S" -v e="$E" -v prot="$PROT" -v det="$DSET" -v hid="$HSET" "$READ_MODEL"'
      # THE READING LAYER, once, for every rule below — see the retire path: rules decide
      # on the NORMALIZED line, passthroughs print `raw`, so untouched lines keep their
      # bytes while the m_class == "orphan" sweep sees what the parser sees (a `guard:`
      # behind a whitespace-variant indent included — Finding 4).
      { raw = $0; $0 = m_norm($0); cls = m_class($0) }
      NR == s {                     # the replacement lands where the old entry was
        print ENVIRON["b"]
        # Every guard of the set, one indented line each, in the order it arrived.
        # split() on a newline is exact here: collapse() strips newlines out of GUARD,
        # and a guard read back from the file is one line by construction.
        if (ENVIRON["g"] != "") {
          n = split(ENVIRON["g"], gs, "\n")
          for (i = 1; i <= n; i++) if (gs[i] != "") print "  guard: " gs[i]
        }
      }
      NR >= s && NR <= e { next }   # the old entry and its whole extent
      # A DETACHED orphan of this entry — see the retire path. Adopted (re-emitted above) or
      # swept, it leaves this position either way, and a NOTE says which.
      index(det, "," NR ",") { next }
      # A HIDDEN guard-like line of this entry — always a deletion, never an adoption, and
      # only ever reached when the caller stated the guard set (require_no_hidden).
      index(hid, "," NR ",") { next }
      # Same exemption-by-rule-order as the retire path: a line orphan_rows marked
      # `foreign` is one intent-check.sh reads against ANOTHER entry awaiting re-confirm.
      cls == "orphan" && index(prot, "," NR ",") { print raw; next }
      cls == "orphan"    { next }   # orphans, including any just adopted above
      { print raw }
    ' "$INTENT" > "$TMP" || fail "cannot rewrite $INTENT"
    install "$TMP" "$NPROT"
    trap - EXIT
    # Two notes, one per SPELLING, because the two name different lines to whoever reads the
    # transcript: a column-0 `guard:` and an indented one a closer detached from its entry.
    { [[ "$ADOPTED" = 0 ]] || [[ "$NADOPT_COL0" = 0 ]]; } \
      || note "adopted the $NADOPT_COL0 orphaned column-0 guard line(s) of the run '$MATCH' opens — every one intent-check.sh attaches to that entry, or to no entry at all inside its run — as that entry's own indented guard(s)"
    { [[ "$ADOPTED" = 0 ]] || [[ "$NADOPT_DET" = 0 ]]; } \
      || note "adopted the $NADOPT_DET orphaned indented guard line(s) a closer had detached from '$MATCH' as that entry's own indented guard(s)"
    # Only a set of MORE than one is worth announcing: replacing the single guard of a
    # single-guard entry is the documented everyday move, and a NOTE on every one of
    # those is noise a reader learns to skip — skipped notes are how the dropped-guard
    # loss stayed invisible in the first place.
    [[ "$REPLACED" -le 1 ]] \
      || note "the GUARD given replaced ALL $REPLACED guards the entry '$MATCH' carried (was: $(guards_inline "$OLD_GUARDS")) — intent-check.sh requires every guard on an entry to pass, so the ones not restated no longer vet it"
    [[ -z "$SWEEP_NOTES" ]] || printf '%s\n' "$SWEEP_NOTES" | while IFS= read -r m; do note "$m"; done
    [[ -z "$DETACHED_NOTES" ]] || printf '%s\n' "$DETACHED_NOTES" | while IFS= read -r m; do note "$m"; done
    [[ -z "$HIDDEN_NOTES" ]] || printf '%s\n' "$HIDDEN_NOTES" | while IFS= read -r m; do note "$m"; done
    echo "updated"
    ;;
esac
