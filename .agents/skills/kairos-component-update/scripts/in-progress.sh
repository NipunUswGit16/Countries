#!/usr/bin/env bash
# in-progress.sh — the format owner for `.kairos/manifest.yaml`. Runs from the
# component work-tree root. Five WRITE actions, one per write the skill makes to
# that file, each with its own key requirement — plus two READs (live-source, list-floors):
#
#   ACTION       writes / reads                            PHASE_KEY
#   set          the whole <src>.in_progress block         Phase 4  (m6dh2pjx)
#   clear        deletes the in_progress KEY               none — see below
#   advance      <src>.sha (+ <src>.branch)                Phase 8  (vk3rq8hd)
#   bootstrap    the source's founding block, once         Phase 2  (k3wq8vfr)
#   record-floor appends one frontend.outstanding_floors   Phase 8  (vk3rq8hd)
#                element {upgrade_file,module,sha}
#   live-source  PRINTS template|frontend|none — which     none — a pure read
#                source's in_progress block is live
#   list-floors  PRINTS frontend.outstanding_floors as      none — a pure read
#                upgrade_file<TAB>module<TAB>sha rows
#
# `<src>` is SOURCE — `template` (the default) or `frontend`. ONE env var selects
# the manifest key prefix every action reads and writes; nothing else about an
# action changes with it, which is the point: a frontend migration is a second RUN
# of the same machinery, not a second machinery. SOURCE=template is the
# pre-frontend behavior verbatim, down to the bytes bootstrap writes.
#
# WHY `set` refuses when the OTHER source has a block: exactly one migration is
# live at a time. Both blocks are read as live by pre-flight, continue and abort,
# and each of those three answers a question that has no meaning for two — which
# branch to check out, which run to resume, which SHA to roll back to. Two live
# blocks is not a degraded state, it is an unanswerable one, and the cheapest place
# to make it unproducible is the one script that can write either.
#
# The FILENAME is deliberately unchanged now that the remit is the whole manifest:
# a rename to manifest.sh would touch three call sites, the test suite, four docs
# and the phase-key inventory for no behavioral gain.
#
# WHY this script exists at all: the block is the skill's central interlock and
# five readers depend on it — pre-flight parses it fail-closed, refuses ANY fresh
# run while it exists (from any branch, with no override flag), and suppresses
# the state sweep so continue keeps PLAN.md and $RUN; reference/abort.md reads
# previous_branch/branch/previous_sha as its only rollback point; and
# reference/continue.md treats the block's existence AS the entry condition. Until
# this script, nothing wrote it: Phase 4 and Phase 8 showed a YAML shape in prose
# and a model hand-edited a COMMITTED file, twice per run, every run. It was the
# one load-bearing file with no format owner, and the only one the artifact-writer
# coverage lint could not see, because that lint is scoped to $RUN/ paths — while
# this file is committed, cross-phase, and unrecoverable by a re-run.
#
# WHY it is not merely tidiness — the deadlock. mikefarah/yq scores an EMPTY
# mapping as a value, so `.template.in_progress // ""` reads `in_progress: {}` as
# a LIVE migration while `in_progress:` (null) reads as none. A block that reads
# live but carries no previous_branch is unreachable from every direction:
# pre-flight refuses every fresh run and names abort as the remedy, abort's own
# read used to hard-fail on the missing previous_branch, and "checkout manually"
# does not clear the block — so the next fresh run is refused again. The way in
# was the SUCCESS path, not a crash: Phase 8 said "remove the template.in_progress
# block", and a model that empties the mapping instead of deleting the key leaves
# that state behind on a migration that completed cleanly. Phase 4 produced the
# same state by writing the key before its children. Both are single-token
# omissions in prose-driven YAML edits.
#
# WHY `set` refuses a partial block rather than warning: that is the whole point.
# The deadlock state has to be unproducible, not merely discouraged — so
# TARGET_SHA, PREV_BRANCH and PREV_SHA are all required, refused when empty, and
# a refusal writes NOTHING (the manifest is byte-identical afterwards).
#
# WHY BRANCH is optional and its key OMITTED rather than written empty: under
# --no-branch Phase 4 deliberately records no `branch:`, because abort's delete
# would otherwise target the checked-out branch. Omitting keeps the on-disk shape
# identical to what the phase file has always documented.
#
# WHY temp-file + mv rather than `yq -i`: this is the skill's first write to a
# COMMITTED file, and a half-written manifest is precisely the failure being
# designed out. The temp file sits in the manifest's own directory so the mv is a
# same-filesystem rename — a crash at any point leaves either the old file or the
# new one, never a truncated in-between. (mikefarah/yq is already a hard
# pre-flight dependency with a build check, so nothing new is asked of the
# environment.)
#
# WHY the key requirement is PER ACTION, and why `clear` carries none. Guards
# protect a phase's ENTRY POINT, and each action has different callers. `set` is
# Phase 4's write with one caller; `advance` is Phase 8's with one caller;
# `bootstrap` is Phase 2's with one caller — all three take their phase's key.
# `clear` has two callers in non-equivalent contexts: phases/8-finalize.md — whose
# guarded entry point is gate.sh under LABEL=final, not this script — and
# reference/abort.md, a reference document that holds no phase key at all. Guarding
# clear on any key would brick abort, which is the ONE remedy for a component
# already carrying a bad block. `clear` must not appear in the PHASE_KEY inventory
# tests/skill-lint.test.sh audits. Do not "fix" this by adding a key.
#
# WHY `clear`'s scope still stops at the block, now that `advance` exists: BECAUSE
# ABORT SHARES `clear`. Abort calls it while rolling a migration BACK, and an
# action that also moved template.sha would finalize the migration it is undoing.
# That is the reason — not that the advance belongs in prose.
#
# (This header used to argue the opposite: that Phase 8's baseline advance should
# stay in the phase file because it is the run's DELIVERABLE, decided by the phase
# rather than part of the interlock. That does not follow from clear's narrowness,
# and it was wrong on its own terms. The advance is the write the NEXT migration
# reads as BASE; a write that looks fine and is wrong — a dropped `bootstrapped:`,
# a `yq -i` that reflows the file, a short SHA — poisons every future run's
# baseline, and nothing reads it again until that run. Being the deliverable is an
# argument FOR a checked writer. `advance` is that writer: separate action, one
# call site, its own key.)
#
# WHY `live-source` is a script action and not four hand-written derivations.
# Phase 8 has to answer "which source's in_progress block is live" at four points
# (the silenced-test range, the block re-read, the advance, and the finalize
# commit), and it used to answer it with a copy of `SRC=template; case "$(yq -r
# '.frontend | has("in_progress")' …)" in true) SRC=frontend ;; esac` at each. A
# mechanical read repeated in prose is exactly what this script exists to end:
# four copies drift independently, and one that reads the wrong key advances or
# commits the wrong source's baseline. The read is keyless because it writes
# nothing — like `clear`, and unlike the four keyed writers. It fails CLOSED on an
# unreadable manifest (same rule `clear` and `set` apply), so "no live block" and
# "I could not tell" never collapse to the same answer.
#
# WHY `record-floor` is a keyed write action and not a hand-append. §6.4 of the
# frontend-compatibility-floor PRD: when a crossed template upgrade-file declares a
# `requires-frontend` floor the component's frontend.sha does NOT contain, and the
# user declines the frontend run, the debt is recorded so the NEXT run re-surfaces
# it. That debt is a LIST — `frontend.outstanding_floors`, each element the three
# columns of `$RUN/frontend-floors.tsv` ({upgrade_file, module, sha}) — because
# several crossed floors may be outstanding at once. It is a Phase-8 write with one
# caller (the SOURCE=template consent epilogue), so it takes Phase 8's key like
# `advance`, and it goes through the same rewrite()/strenv() temp+read-back+mv
# discipline every other manifest write does: a floor recorded on trust, mistyped or
# duplicated, is re-read only on a future run. Idempotent by upgrade_file+module+sha:
# a re-declined floor already present is not appended twice. It refuses to CREATE the
# frontend block — recording under `.frontend` on a component with no frontend block
# would leave `frontend: {outstanding_floors: …}`, a partial block with no baseline,
# so it fails closed instead. The guard (shared by `set`/`advance`) tests `.frontend`
# for a REAL mapping, not mere key presence, so an absent key AND a bare `frontend:`
# null/scalar placeholder both read as "no block" — the Phase 8 callers only reach it
# when a real frontend block exists, and this refuses every other shape even so.
#
# WHY auto-clear lives inside `advance`'s SOURCE=frontend arm and nowhere else.
# `frontend.sha` moves in exactly one place — a frontend advance — and a floor is
# satisfied the instant the new baseline CONTAINS its commit. So each recorded
# `frontend.outstanding_floors` element is ancestry-tested against the new
# TARGET_SHA (`git -C "$FRONTEND_CACHE" merge-base --is-ancestor <element.sha>
# <TARGET_SHA>`) and the contained ones are del()'d in the SAME rewrite() as the sha
# advance — one temp+mv, so the file never lands with an advanced sha and a stale
# floor still recorded. A SOURCE=template advance NEVER touches floors: they live
# under the frontend block, and the template baseline moving says nothing about the
# frontend one. Best-effort by design: with no usable FRONTEND_CACHE the ancestry
# test cannot run, so the notes are LEFT (a floor is never falsely cleared — the same
# "I could not check is never it is satisfied" rule the Phase 8 gate applies). A
# non-git-resolvable floor sha errors the merge-base (rc != 0) and is likewise left.
#
# Env in:  ACTION      set | clear | advance | bootstrap | record-floor | live-source | list-floors  (required)
#          SOURCE      template (default) | frontend — the manifest key prefix.
#                      An unknown value is refused, never defaulted: a typo'd
#                      SOURCE that fell back to `template` would move the TEMPLATE
#                      baseline on a frontend run. So is a SET-but-EMPTY one —
#                      unset defaults, empty means the caller's interpolation
#                      resolved to nothing (see the `${SOURCE-template}` note).
#          PHASE_KEY   per the table at the top. NOT read by clear.
#          TARGET_SHA  set: required, refused when empty or whitespace-only
#                      advance: required, refused unless a full 40-hex SHA
#          PREV_BRANCH set: required, refused when empty or whitespace-only
#          PREV_SHA    set: required, refused when empty or whitespace-only
#          BRANCH      set: optional — the `branch:` key is OMITTED when unset
#                      or empty, never written empty
#                      advance: optional — template.branch is written ONLY when
#                      a branch was explicitly targeted
#                      bootstrap: REQUIRED, refused when empty or whitespace-only
#                      — see WHY bootstrap's BRANCH is not defaultable, below
#          NAME        bootstrap: the component name. When pkg/schema/globals.go
#                      declares a real (non-placeholder) const ComponentName,
#                      NAME is taken from it if omitted, and a caller-supplied
#                      NAME that disagrees is refused. When the file is absent
#                      or unreadable, NAME is required from the caller — Phase 2
#                      asks the user; this script never guesses from Chart.yaml,
#                      go.mod, or the directory basename.
#          REPO        bootstrap: required — the template's upstream URL. An old
#                      Bitbucket SSH host is recorded as ssh.bitbucket.org
#          BASE_SHA    bootstrap: required, a full 40-hex SHA — the DETECTED
#                      baseline (named apart from TARGET_SHA on purpose: bootstrap
#                      records where the component already is, advance moves it)
#          CLI_VERSION bootstrap: optional, defaults to `skill-v1`
#                      (SOURCE=template only — the frontend block records no CLI
#                      version; no CLI materializes a frontend run at all)
#          MODULE      bootstrap SOURCE=frontend: required — the source repo's
#                      config.yaml module key this component was built from, which
#                      lands as `frontend.template`. Nothing here knows `react`.
#          MODULE_PATH bootstrap SOURCE=frontend: required — that module's subtree
#                      path inside the source repo, which lands as `frontend.path`
#                      (env-named apart from `path` because PATH is not ours)
#          MOUNT       bootstrap SOURCE=frontend: optional — where the module is
#                      mounted in the component. The key is OMITTED when unset or
#                      `web/`, because `web/` is the documented default and a
#                      written-out default is a value a later reader has to
#                      distinguish from a deliberate choice.
#          FLOOR_FILE  record-floor: required — the crossed upgrade-file that
#                      declared the floor. The EXACT path string as it appears in
#                      `$RUN/upgrades-added.txt` / `upgrades-modified.txt` and in
#                      `$RUN/frontend-floors.tsv`'s column 1 (identity must match).
#          FLOOR_MODULE record-floor: required — the frontend-template module the
#                      floor is expressed in (frontend-floors.tsv column 2).
#          FLOOR_SHA   record-floor: required — the floor commit the frontend
#                      baseline must contain (frontend-floors.tsv column 3).
#          FRONTEND_CACHE advance SOURCE=frontend: optional — a frontend mirror the
#                      auto-clear ancestry test runs in (`git -C … merge-base
#                      --is-ancestor`). Read the way the rest of Phase 8's frontend
#                      arm learns it (the run-context anchor's FRONTEND_CACHE). Absent
#                      or unusable → the clear is skipped, floors LEFT (best-effort).
#          Values are SPACE-collapsed and trimmed before the emptiness check, so a
#          value made of spaces is as empty as an unset one and cannot make the
#          block writable. (Branch names and SHAs carry no internal whitespace.)
#          A newline, carriage return or tab in ANY value is REFUSED, not folded:
#          collapse() used to translate all three into blanks, so `NAME=$'a\nb'`
#          landed as `a b` and a CRLF-authored `BRANCH=main\r` as `main` — a value
#          silently different from the one the caller passed, written into the
#          component's founding manifest where nothing reads it again for months.
#          record-context.sh refuses exactly these three characters in the
#          run-context anchor for the same reason; every value here is a name, a
#          URL, a branch or a SHA, and none carries one legitimately.
#
# WHY bootstrap's BRANCH is REQUIRED and no longer defaults to `main`: it records
# the branch the baseline was DETECTED on, and rule 4 of Phase 2's target chain
# reads `template.branch` back on the NEXT migration of this component. A default
# was therefore a guess about history — right for main, silently wrong for every
# other branch, and invisible until a future run diffs from a commit this run never
# targeted. The shape it actually arrived in was not "omitted" either: the caller is
# a phase-doc block interpolating `BRANCH="$BOOT_REF"`, so a resolution that failed
# to reach the call passed an EMPTY value — which a `[ -n ] || BRANCH=main` default
# turned into the wrong answer rather than a stop. Both callers (phases/2-resolve-
# target.md and reference/bellwether-detection.md) resolve the ref off the
# run-context anchor and pass it; a missing or empty BRANCH here means that
# resolution broke, which is a stop, not a default.
# Effect:  set   — replaces the WHOLE block, so re-running over a partial one
#                  yields a complete one and leaves no stale key behind. This is
#                  reference/continue.md's "redo the in_progress write" path, and
#                  a supported call, not an accident. Every key the call wrote
#                  (target_sha, previous_branch, previous_sha, and branch when
#                  given) is read back off the bytes about to land before the mv
#                  — the same discipline advance and bootstrap apply, and not
#                  optional here either: continue.md's lost-anchor recovery arm
#                  reads target_sha back on a later run, with nothing to compare
#                  it against but this write.
#          clear — deletes the KEY (`del(.template.in_progress)`) and verifies its
#                  absence before writing. Emptying the mapping is the bug; a
#                  clear that cannot leave `{}` behind is the fix. Clearing an
#                  absent block is a no-op that does not rewrite the file.
#          set SOURCE=frontend additionally requires the frontend BLOCK to exist
#                  already (bootstrap or `component create` wrote it). yq would
#                  otherwise create the parent key on the way and leave a live block
#                  with no repo/module/mount/sha — which advance's own has() guard
#                  then accepts. See the arm's comment.
#          advance — writes template.sha (and template.branch when BRANCH is
#                  given) as a SINGLE rewrite — one temp file, both assignments,
#                  one verified mv — not two independent temp+mv rewrites. Both
#                  values are read back off the same pre-mv bytes before either
#                  can reach the file, so a crash has no window in which the
#                  branch has advanced but the sha has not (or vice versa): the
#                  mv that lands one lands both. It touches NOTHING else:
#                  bootstrapped:, name:, created_at:, cli_version:, template.repo
#                  and any unknown key survive verbatim, comments and key order
#                  included. The SHA lands QUOTED — an all-digit 40-character SHA
#                  is a valid YAML integer, and an unquoted one would be re-read as
#                  a number by the next migration.
#          bootstrap SOURCE=frontend — ADDS the `frontend:` block to the
#                  component's EXISTING manifest (repo, path, template, branch,
#                  [mount], sha, bootstrapped: true) and refuses when one is
#                  already there. It is not the founding write the template arm is:
#                  the manifest exists, the component is already provenanced, and
#                  what is missing is one source's baseline. Same read-back
#                  discipline — every caller-supplied value re-read off the bytes
#                  about to land, `!!str` on the strings, `!!bool` on
#                  `bootstrapped` — for the same reason: nothing reads a founding
#                  baseline again until the next migration diffs from it.
#          bootstrap — writes the initial manifest and REFUSES to overwrite an
#                  existing one. It also writes template.kind (`facade` when
#                  the .init.mk facade check holds, else `component`), the
#                  key the CLI stamps from 0.3.35; advance never touches it. Every value goes in through `strenv()` like
#                  `set`'s and `advance`'s do, so it lands QUOTED wherever a plain
#                  scalar would re-read as a number, a timestamp or a bool: a
#                  branch named `1.0` and an all-digit 40-hex SHA are both valid
#                  YAML floats. `bootstrapped: true` is the one deliberate
#                  non-string — it is load-bearing as a BOOLEAN for the component's
#                  whole life (planner and executor both change behavior on it) —
#                  and it is written by the script rather than transcribed from a
#                  doc because one dropped line removes that caution silently.
#                  Before the file lands, the bytes are re-read: every
#                  caller-supplied VALUE (name, template.repo, template.sha,
#                  template.branch) must come back exactly as passed in, and the
#                  TYPES must be `!!str` for the strings and `!!bool` for
#                  `bootstrapped`. Values and types are separate checks because
#                  neither sees the other's failure — `name: ""` is a valid
#                  `!!str`, and a `!!float` SHA can still read back as text.
# Stdout:  set   — "set"
#          clear — "cleared" if a block was removed, "unchanged" if there was none
#          advance   — "advanced". Also rewrites <src>.repo when it names the old
#                      Bitbucket SSH host (git@bitbucket.org: / ssh://git@bitbucket.org/)
#                      to ssh.bitbucket.org, in the same rewrite (lib/bitbucket-url.sh)
#          bootstrap — "bootstrapped"
#          record-floor — "recorded" if the element was appended, "unchanged" if an
#                      element with the same upgrade_file+module+sha was already there
#          Effect:  record-floor — appends ONE {upgrade_file, module, sha} element to
#                      the frontend.outstanding_floors LIST via one rewrite(),
#                      creating the list on first use. Idempotent (a duplicate is a
#                      no-op that does not rewrite the file). Refuses when the manifest
#                      carries no frontend block — see the WHY above.
#                    advance SOURCE=frontend — additionally auto-clears every recorded
#                      outstanding floor the NEW baseline contains, del()'d in the same
#                      rewrite() as the sha advance (see the WHY above). SOURCE=template
#                      advance leaves frontend.outstanding_floors untouched.
#          live-source — "template", "frontend" or "none" (frontend wins when both
#                      carry a block; the mutual-exclusion guard makes that shape
#                      unproducible in practice, so it never has to be adjudicated)
#          list-floors — zero or more `upgrade_file<TAB>module<TAB>sha` lines, one per
#                      frontend.outstanding_floors element (empty print = no debt). The
#                      three columns match $RUN/frontend-floors.tsv so Phase 8 can union
#                      them into the floor check's input and re-surface cross-run debt.
# Exit:    0 done
#          1 PHASE_KEY missing/wrong (every action except clear, live-source and
#            list-floors; record-floor carries Phase 8's key, the same as advance)
#          2 bad input, missing/unparseable manifest, or an unwritable manifest
set -u

MANIFEST=.kairos/manifest.yaml
ACTION="${ACTION:-}"
# `${SOURCE-template}`, NOT `${SOURCE:-template}`: an UNSET variable defaults (every
# pre-frontend caller passes none), but a variable set to the EMPTY STRING is refused
# below. The callers interpolate — `SOURCE=$RUN_SOURCE` off the run-context anchor,
# `SOURCE=$SRC` off the manifest — so an empty value is not a caller choosing the
# default, it is a resolution that never reached the call. Defaulted, that lands on
# `template` and moves the TEMPLATE baseline for a frontend run: the same class of
# silent-wrong-answer bootstrap's BRANCH refuses to default.
SOURCE="${SOURCE-template}"

# Phase-load guard, PER ACTION (see the WHY above). It fires before ACTION is
# validated, so a keyless, envless invocation reads as the missed Phase 4 load it
# almost always is — the same stop every other keyed script gives.
case "$ACTION" in
  clear) ;;                                             # keyless by design
  live-source) ;;                                       # a pure read — keyless
  list-floors) ;;                                       # a pure read — keyless
  advance|record-floor)
    [[ "${PHASE_KEY:-}" = "vk3rq8hd" ]] \
      || { echo "FAIL: load phases/8-finalize.md first" >&2; exit 1; } ;;
  bootstrap)
    [[ "${PHASE_KEY:-}" = "k3wq8vfr" ]] \
      || { echo "FAIL: load phases/2-resolve-target.md first" >&2; exit 1; } ;;
  *)
    [[ "${PHASE_KEY:-}" = "m6dh2pjx" ]] \
      || { echo "FAIL: load phases/4-migration-branch.md first" >&2; exit 1; } ;;
esac

fail() { echo "FAIL: $*" >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
[[ -r "$HERE/lib/bitbucket-url.sh" ]] \
  || fail "missing $HERE/lib/bitbucket-url.sh — it owns canonical_ssh_url"
# shellcheck source=lib/bitbucket-url.sh
. "$HERE/lib/bitbucket-url.sh" \
  || fail "could not source $HERE/lib/bitbucket-url.sh"
[[ -r "$HERE/lib/component-kind.sh" ]] \
  || fail "missing $HERE/lib/component-kind.sh — it owns component_kind"
# shellcheck source=lib/component-kind.sh
. "$HERE/lib/component-kind.sh" \
  || fail "could not source $HERE/lib/component-kind.sh"

# SOURCE resolves to the manifest key prefix ($P) and its counterpart ($OTHER).
# Validated against a closed set here, once, so every expression below can
# interpolate $P without quoting a caller-supplied string into a yq path.
case "$SOURCE" in
  template) OTHER=frontend ;;
  frontend) OTHER=template ;;
  "") fail "SOURCE is set but EMPTY (want template|frontend). An unset SOURCE defaults to template; an empty one means the caller's interpolation — SOURCE=\$RUN_SOURCE off the anchor, SOURCE=\$SRC off the manifest — resolved to nothing. Fix it there: defaulted to template, this call would move the TEMPLATE baseline on a frontend run." ;;
  *) fail "unknown SOURCE '$SOURCE' (want template|frontend) — refused rather than defaulted: a typo that fell back to 'template' would move the TEMPLATE baseline on a frontend run" ;;
esac
P=".$SOURCE"

# Newline / CR / tab are REFUSED, never folded (see header). This runs BEFORE
# collapse(), which is what used to hide them, and before ACTION dispatch, so every
# arm gets the same rule. Indirect expansion rather than eval: a value carrying `"`
# or `$` must not be re-parsed on its way to a refusal.
NL='
'
for v in TARGET_SHA PREV_BRANCH PREV_SHA BRANCH NAME REPO BASE_SHA CLI_VERSION \
         MODULE MODULE_PATH MOUNT FLOOR_FILE FLOOR_MODULE FLOOR_SHA; do
  case "${!v:-}" in
    *"$NL"*)  fail "$v contains a newline — refused, not folded to a space: every value here is a name, URL, branch or SHA, and a folded value is not the value you passed" ;;
    *$'\r'*)  fail "$v contains a carriage return — refused, not folded: it would ride invisibly into the manifest (this is the shape a CRLF-authored value arrives in)" ;;
    *$'\t'*)  fail "$v contains a tab — refused, not folded: it would ride invisibly into the manifest" ;;
  esac
done

# Collapse runs of SPACES and trim, BEFORE the emptiness check (see header). The
# three control characters are already refused above, so nothing is folded here.
collapse() { printf '%s' "$1" | awk '{ $1 = $1; print }'; }

# preserve_mode <tmp> <dest> — give <tmp> the mode the committed <dest> should carry
# before it is mv'd into place. mktemp forces 0600, and a bare mv would stamp that
# private mode onto a manifest that travels in git and is read by every shared checkout
# and CI job. There is no `chmod --reference` on macOS, so <dest>'s own mode is read
# explicitly when it already exists (BSD `stat -f %Lp`, GNU `stat -c %a`), and derived
# from the umask (`0666 & ~umask`, what a `>` redirect would have produced) when it does
# not — the bootstrap case, which creates the founding manifest. Best-effort: a chmod
# failure leaves 0600, exactly the pre-fix behaviour, never a lost write.
#
# GNU stat FIRST, then BSD. `stat -f` is a format flag on BSD/macOS but `--file-system`
# on GNU/Linux (where `'%Lp'` is read as a bogus filename): the BSD-first order returned a
# filesystem dump under CI's Linux, chmod rejected it, and the mode silently stayed 0600.
# The octal guard drops any non-octal reading so garbage can never reach chmod.
preserve_mode() {
  local m=""
  if [[ -e "$2" ]]; then
    m=$(stat -c '%a' "$2" 2>/dev/null || stat -f '%Lp' "$2" 2>/dev/null) || m=""
    case "$m" in *[!0-7]*|'') m="" ;; esac
  fi
  [[ -n "$m" ]] || m=$(printf '%o' "$(( 0666 & ~0$(umask) ))")
  chmod "$m" "$1" 2>/dev/null || true
}

# rewrite <yq-expr> [<assert-expr> <assert-want>]... — apply the expression to a
# temp file in the manifest's own directory, verify the result THERE against
# EVERY assert/want pair given, and only then rename it over the manifest.
# Verifying before the mv is what makes a bad write unable to reach the file at
# all. Multiple pairs exist so a caller that writes several keys in one
# expression (ACTION=set writes four) can read every one of them back off the
# bytes about to land — a key the caller wrote but never re-reads is written on
# trust, which is exactly the gap a bad `yq` expression or an environment mix-up
# hides in.
rewrite() {
  TMP=$(mktemp "$(dirname "$MANIFEST")/.manifest.yaml.XXXXXX") \
    || fail "cannot create a temp file next to $MANIFEST"
  trap 'rm -f "$TMP"' EXIT
  yq "$1" "$MANIFEST" > "$TMP" \
    || fail "yq could not rewrite $MANIFEST (unreadable manifest, or a bad expression)"
  shift
  while [[ "$#" -gt 0 ]]; do
    [[ "$#" -ge 2 ]] || fail "rewrite() called with an odd assert/want argument — internal error"
    [[ "$(yq -r "$1" "$TMP" 2>/dev/null)" = "$2" ]] \
      || fail "the rewritten block failed its own check ($1 was not $2) — refusing to write $MANIFEST"
    shift 2
  done
  preserve_mode "$TMP" "$MANIFEST"
  mv "$TMP" "$MANIFEST" || fail "could not write $MANIFEST"
  trap - EXIT
}

case "$ACTION" in
  set)
    TARGET_SHA=$(collapse "${TARGET_SHA:-}")
    PREV_BRANCH=$(collapse "${PREV_BRANCH:-}")
    PREV_SHA=$(collapse "${PREV_SHA:-}")
    BRANCH=$(collapse "${BRANCH:-}")

    [[ -f "$MANIFEST" ]] || fail "no $MANIFEST in $(pwd) — run from the component work-tree root"
    [[ -n "$TARGET_SHA" ]]  || fail "TARGET_SHA required (the target the migration is heading to)"
    [[ -n "$PREV_BRANCH" ]] || fail "PREV_BRANCH required (abort's checkout target — a block without it is unrecoverable)"
    [[ -n "$PREV_SHA" ]]    || fail "PREV_SHA required (abort's rollback point and Phase 8's squash base)"

    # A non-template `set` needs its SOURCE BLOCK to already exist — the same rule
    # `advance` enforces, one phase earlier and for a sharper reason. `set` writes
    # `frontend.in_progress`, and yq CREATES the parent key on the way: on a component
    # with no frontend block at all that leaves `frontend: {in_progress: …}` — a live
    # frontend run with no repo, no module, no mount, no baseline. That shape then
    # SATISFIES advance's own `has("frontend")` guard at Phase 8, so the baseline lands
    # in a block bootstrap never wrote and every later reader treats as recorded
    # provenance. Refused here, naming the step that is actually missing.
    if [[ "$SOURCE" != template ]]; then
      # A REAL mapping, not mere key presence: a bare `$SOURCE:` (null/scalar
      # placeholder) satisfies has() but is not a recorded source, so tag=='!!map'
      # is the honest test — an absent key and a null key both read as "no block".
      SRC_TAG=$(yq -r ".[\"$SOURCE\"] | tag" "$MANIFEST" 2>/dev/null) \
        || fail "cannot parse $MANIFEST (yq error) — refusing to reason about the $SOURCE block from an unreadable manifest."
      [[ "$SRC_TAG" = '!!map' ]] \
        || fail "$MANIFEST has no $SOURCE block — a $SOURCE run cannot record an in-progress block before its baseline exists. Writing one would create '$SOURCE: {in_progress: …}': a live run with no repo, no module, no mount and no sha, which Phase 8's advance then accepts as a recorded source. Bootstrap it first (Phase 2's $SOURCE arm: ACTION=bootstrap SOURCE=$SOURCE)."
    fi

    # Exactly one live migration (see the WHY at the top). Fail CLOSED on an
    # unparseable manifest, the same disposition clear applies: "the other source
    # has no block" and "I could not tell" must never be the same answer.
    OTHER_HAS=$(yq -r ".$OTHER"' | has("in_progress")' "$MANIFEST" 2>/dev/null) \
      || fail "cannot parse $MANIFEST (yq error) — refusing to reason about the other source's in-progress block from an unreadable manifest."
    [[ "$OTHER_HAS" = false ]] \
      || fail "$MANIFEST already carries a $OTHER.in_progress block — exactly one migration is live at a time, and pre-flight, continue and abort each ask a question two live blocks cannot answer. Finish or abort the $OTHER run before starting a $SOURCE one."

    # strenv, not interpolation: a value carrying YAML metacharacters is data.
    export TARGET_SHA PREV_BRANCH PREV_SHA BRANCH
    if [[ -n "$BRANCH" ]]; then
      EXPR="$P"'.in_progress = {"target_sha": strenv(TARGET_SHA), "branch": strenv(BRANCH), "previous_branch": strenv(PREV_BRANCH), "previous_sha": strenv(PREV_SHA)}'
    else
      EXPR="$P"'.in_progress = {"target_sha": strenv(TARGET_SHA), "previous_branch": strenv(PREV_BRANCH), "previous_sha": strenv(PREV_SHA)}'
    fi
    # Every key this action wrote is re-read off the bytes about to land, not
    # just previous_branch (the one whose ABSENCE produces the pre-flight
    # deadlock). target_sha is exactly as load-bearing the other direction:
    # reference/continue.md's lost-anchor recovery arm reads it back to resume a
    # migration, so a wrong-but-non-empty value would be adopted silently rather
    # than refused — the same class of failure the deadlock check exists to
    # catch, just on a different key. branch is only asserted when given, since
    # it is the one key `set` may legitimately omit.
    if [[ -n "$BRANCH" ]]; then
      rewrite "$EXPR" \
        "$P.in_progress.target_sha // \"\"" "$TARGET_SHA" \
        "$P.in_progress.branch // \"\"" "$BRANCH" \
        "$P.in_progress.previous_branch // \"\"" "$PREV_BRANCH" \
        "$P.in_progress.previous_sha // \"\"" "$PREV_SHA"
    else
      rewrite "$EXPR" \
        "$P.in_progress.target_sha // \"\"" "$TARGET_SHA" \
        "$P.in_progress.previous_branch // \"\"" "$PREV_BRANCH" \
        "$P.in_progress.previous_sha // \"\"" "$PREV_SHA"
    fi
    echo "set"
    ;;
  clear)
    [[ -f "$MANIFEST" ]] || fail "no $MANIFEST in $(pwd) — run from the component work-tree root"

    # Fail CLOSED on a manifest yq cannot read, the same rule pre-flight applies:
    # "there is no block" and "I could not tell" must never be the same answer
    # about the file five readers treat as the migration interlock.
    HAS=$(yq -r "$P"' | has("in_progress")' "$MANIFEST" 2>/dev/null) \
      || fail "cannot parse $MANIFEST (yq error) — refusing to reason about the in-progress block from an unreadable manifest."

    # Already absent: a no-op, per abort.md's "If there's no in_progress block,
    # abort is a no-op". It must not rewrite the file either — a gratuitous yq
    # round-trip on a TRACKED file dirties the tree that pre-flight check 1
    # demands be clean, blocking the user's next run over a call that changed
    # nothing.
    if [[ "$HAS" != "true" ]]; then
      echo "unchanged"
      exit 0
    fi

    # has(), not a value read: it is the only check that tells a deleted key
    # apart from one left empty or null — which is the entire failure mode.
    rewrite "del($P.in_progress)" "$P"' | has("in_progress")' false
    echo "cleared"
    ;;
  live-source)
    [[ -f "$MANIFEST" ]] || fail "no $MANIFEST in $(pwd) — run from the component work-tree root"
    # has(), fail CLOSED on a manifest yq cannot read — the same rule clear and set
    # apply. "no live block" and "I could not tell" must never be the same answer
    # about the file five readers treat as the migration interlock. SOURCE is
    # irrelevant here (this read asks about BOTH sources), so the prefix computed
    # above is unused.
    FE_LIVE=$(yq -r '.frontend | has("in_progress")' "$MANIFEST" 2>/dev/null) \
      || fail "cannot parse $MANIFEST (yq error) — refusing to name the live source from an unreadable manifest."
    TPL_LIVE=$(yq -r '.template | has("in_progress")' "$MANIFEST" 2>/dev/null) \
      || fail "cannot parse $MANIFEST (yq error) — refusing to name the live source from an unreadable manifest."
    # frontend wins when both carry a block — matching the hand-written derivation
    # this action replaces (it tested frontend first and fell back to template).
    # Two live blocks is the unproducible state `set` refuses to create, so the tie
    # is never actually reached; picking frontend keeps the answer stable if it is.
    if [[ "$FE_LIVE" = true ]]; then echo frontend
    elif [[ "$TPL_LIVE" = true ]]; then echo template
    else echo none
    fi
    ;;
  list-floors)
    [[ -f "$MANIFEST" ]] || fail "no $MANIFEST in $(pwd) — run from the component work-tree root"
    # THE READER for the cross-run debt record-floor writes. A pure read (keyless):
    # PRINT frontend.outstanding_floors as `upgrade_file<TAB>module<TAB>sha` rows — the
    # exact three columns $RUN/frontend-floors.tsv carries and frontend-floor-check.sh
    # consumes — so a LATER run's Phase 8 can UNION this persisted debt with the floors
    # freshly crossed over its own BASE..TARGET and re-surface a floor whose upgrade-file
    # has since fallen out of range. Without this the debt was WRITE-ONLY: record-floor
    # and the advance auto-clear both touch outstanding_floors, but nothing read it, so
    # the contract in this header, state-files.md and 8-finalize.md ("the next run
    # re-surfaces it") had no implementation. SOURCE is irrelevant — floors live under the
    # frontend block regardless — so the prefix computed above is unused. Fail CLOSED on an
    # unreadable manifest: a swallowed parse error would print nothing and read as "no
    # debt", silently dropping it — the exact loss the persistence exists to prevent. An
    # absent frontend block or empty list is a clean empty print, exit 0 (no debt to raise).
    yq -r '.frontend.outstanding_floors // [] | .[] | [.upgrade_file, .module, .sha] | @tsv' "$MANIFEST" 2>/dev/null \
      || fail "cannot parse $MANIFEST (yq error) — refusing to list outstanding floors from an unreadable manifest."
    ;;
  advance)
    TARGET_SHA=$(collapse "${TARGET_SHA:-}")
    BRANCH=$(collapse "${BRANCH:-}")

    [[ -f "$MANIFEST" ]] || fail "no $MANIFEST in $(pwd) — run from the component work-tree root"
    # A FULL 40-hex SHA, not a ref and not an abbreviation. A short SHA is the
    # dangerous input: it looks right in the file and usually still resolves, until
    # a future run compares it against a full SHA and mis-reads its own baseline.
    printf '%s' "$TARGET_SHA" | grep -qE '^[0-9a-f]{40}$' \
      || fail "TARGET_SHA must be a full 40-character hex SHA (got '${TARGET_SHA}') — the baseline the NEXT migration reads as BASE"

    # A frontend advance moves a block bootstrap or create wrote; it must never
    # CREATE one. Without this, an advance on a component whose frontend was never
    # provenanced would leave `frontend: {sha: …}` — a baseline with no repo, no
    # module and no mount, which every later reader treats as a recorded source.
    if [[ "$SOURCE" != template ]]; then
      # A REAL mapping, not mere key presence (see the set-guard note): a null
      # `$SOURCE:` placeholder satisfies has() but is not a recorded baseline.
      SRC_TAG=$(yq -r ".[\"$SOURCE\"] | tag" "$MANIFEST" 2>/dev/null) \
        || fail "cannot parse $MANIFEST (yq error) — refusing to advance a baseline in an unreadable manifest."
      [[ "$SRC_TAG" = '!!map' ]] \
        || fail "$MANIFEST has no $SOURCE block — advance MOVES a recorded baseline, it does not found one. Bootstrap the block first (ACTION=bootstrap SOURCE=$SOURCE)."
    fi

    export TARGET_SHA BRANCH
    # Auto-clear satisfied frontend floors — SOURCE=frontend ONLY (see the WHY at
    # the top). This is the only place frontend.sha moves, and a recorded outstanding
    # floor is satisfied the instant the NEW baseline contains its commit. Each
    # element's sha is ancestry-tested against TARGET_SHA in the frontend mirror, and
    # the contained ones are folded into the SAME rewrite() as the sha advance below,
    # so the file never lands with an advanced sha and a stale floor still recorded.
    # A SOURCE=template advance builds NO selector, so the template arm is byte-for-
    # byte the pre-floor behaviour. Best-effort: an absent or unusable FRONTEND_CACHE,
    # or a non-git-resolvable floor sha (merge-base errors), leaves the floor in place
    # — a floor is never falsely cleared.
    CLEAR_SEL=""
    if [[ "$SOURCE" = frontend ]]; then
      FE_CACHE="${FRONTEND_CACHE:-}"
      if [[ -n "$FE_CACHE" ]] && git -C "$FE_CACHE" rev-parse --git-dir >/dev/null 2>&1; then
        while IFS= read -r fsha; do
          [[ -n "$fsha" ]] || continue
          # Only a git-resolvable object can be an ancestor; a garbage value makes
          # merge-base exit non-zero and is treated as not-contained → left in place.
          git -C "$FE_CACHE" merge-base --is-ancestor "$fsha" "$TARGET_SHA" 2>/dev/null \
            || continue
          # Interpolated into the yq selector, so restrict to the hex a git object id
          # is — a resolvable sha carries no yq metacharacter, but never trust the
          # manifest's bytes to a constructed expression without the check.
          case "$fsha" in
            *[!0-9a-fA-F]*) : ;;
            *) CLEAR_SEL="${CLEAR_SEL:+$CLEAR_SEL or }.sha == \"$fsha\"" ;;
          esac
        done < <(yq -r "$P"'.outstanding_floors // [] | .[].sha' "$MANIFEST" 2>/dev/null)
      fi
    fi
    if [[ -n "$CLEAR_SEL" ]]; then
      DEL="del($P.outstanding_floors[] | select($CLEAR_SEL)) | "
    else
      DEL=""
    fi

    # ONE rewrite, not two: template.branch and template.sha used to be written
    # as separate temp+mv rewrites, so a crash between them could land the
    # branch advanced with the OLD sha still on disk — self-healing on the next
    # run (advance is idempotent), but a real window with no reader accounting
    # for it. Folding both assignments into a single yq expression, verified
    # against the same temp file, means the mv that lands one lands both — the
    # same temp+mv+read-back discipline `rewrite()` already gives every other
    # action, just with two assert/want pairs instead of one. When BRANCH is
    # unset, template.branch is omitted from the expression entirely (not
    # merely asserted-away), so it is left untouched exactly as before. The floor
    # auto-clear ($DEL, frontend arm only) rides in the SAME expression, so the
    # contained floors and the advanced sha land in one mv or neither.
    EXPR="$P.sha = strenv(TARGET_SHA)"
    ASSERTS=("$P.sha // \"\"" "$TARGET_SHA")
    if [[ -n "$BRANCH" ]]; then
      EXPR="$P.branch = strenv(BRANCH) | $EXPR"
      ASSERTS=("$P.branch // \"\"" "$BRANCH" "${ASSERTS[@]}")
    fi
    # A repo recorded on the old Bitbucket SSH host (which no longer serves SSH) is
    # moved to ssh.bitbucket.org in the same rewrite, so it rides the baseline
    # commit. Pre-flight already cloned from the mapped URL. Any other value —
    # including HTTPS and an already-current URL — is left exactly as written.
    REPO_NOW=$(yq -r "$P.repo // \"\"" "$MANIFEST" 2>/dev/null) \
      || fail "cannot parse $MANIFEST (yq error) — refusing to advance a baseline in an unreadable manifest."
    CANON_REPO=$(canonical_ssh_url "$REPO_NOW")
    if [[ "$CANON_REPO" != "$REPO_NOW" ]]; then
      export CANON_REPO
      EXPR="$P.repo = strenv(CANON_REPO) | $EXPR"
      ASSERTS+=("$P.repo // \"\"" "$CANON_REPO")
    fi
    rewrite "${DEL}$EXPR" "${ASSERTS[@]}"
    echo "advanced"
    ;;
  record-floor)
    FLOOR_FILE=$(collapse "${FLOOR_FILE:-}")
    FLOOR_MODULE=$(collapse "${FLOOR_MODULE:-}")
    FLOOR_SHA=$(collapse "${FLOOR_SHA:-}")

    [[ -f "$MANIFEST" ]] || fail "no $MANIFEST in $(pwd) — run from the component work-tree root"
    [[ -n "$FLOOR_FILE" ]]   || fail "FLOOR_FILE required (the crossed upgrade-file that declared the floor — its exact path as it appears in \$RUN/frontend-floors.tsv column 1)"
    [[ -n "$FLOOR_MODULE" ]] || fail "FLOOR_MODULE required (the frontend-template module the floor is expressed in)"
    [[ -n "$FLOOR_SHA" ]]    || fail "FLOOR_SHA required (the floor commit the frontend baseline must contain)"

    # record-floor writes frontend.outstanding_floors regardless of SOURCE, so it
    # must never CREATE the frontend block: `.frontend.outstanding_floors += …` on a
    # component with no frontend block would leave `frontend: {outstanding_floors: …}`
    # — a block with no repo, no module and no sha that every later reader treats as
    # recorded provenance. The Phase 8 callers only reach this when a frontend block
    # exists; this refuses the shape rather than trusting them. The guard tests for a
    # REAL mapping (tag=='!!map'), not mere key presence, so a bare `frontend:`
    # null/scalar placeholder is refused too — has() would wave it through. Fail
    # CLOSED on an unreadable manifest, the same rule every other read here applies.
    FE_TAG=$(yq -r '.frontend | tag' "$MANIFEST" 2>/dev/null) \
      || fail "cannot parse $MANIFEST (yq error) — refusing to record a floor in an unreadable manifest."
    [[ "$FE_TAG" = '!!map' ]] \
      || fail "$MANIFEST has no frontend block — an outstanding frontend floor is recorded under the frontend block, and recording one before that block exists would create 'frontend: {outstanding_floors: …}': a block with no repo, no module and no sha that Phase 8's advance then accepts as a recorded source. Only record a floor on a component that already carries a frontend block."

    # Idempotent by upgrade_file+module+sha: a re-declined floor already present is
    # not appended twice, and a duplicate is a no-op that does NOT rewrite the file —
    # a gratuitous round-trip would dirty the tree pre-flight demands be clean.
    export FLOOR_FILE FLOOR_MODULE FLOOR_SHA
    DUP=$(yq -r '[.frontend.outstanding_floors // [] | .[] | select(.upgrade_file == strenv(FLOOR_FILE) and .module == strenv(FLOOR_MODULE) and .sha == strenv(FLOOR_SHA))] | length' "$MANIFEST" 2>/dev/null) \
      || fail "cannot parse $MANIFEST (yq error) — refusing to record a floor in an unreadable manifest."
    if [[ "$DUP" != 0 ]]; then
      echo "unchanged"
      exit 0
    fi

    # One atomic rewrite. `+=` appends and materializes the list on first use; the
    # frontend block is guaranteed present by the guard above, so the parent is never
    # created here. The element is read back off the bytes about to land — the same
    # discipline every other write applies to a value nothing re-reads until a future
    # run — asserting exactly one matching element now exists.
    rewrite '.frontend.outstanding_floors += [{"upgrade_file": strenv(FLOOR_FILE), "module": strenv(FLOOR_MODULE), "sha": strenv(FLOOR_SHA)}]' \
      '[.frontend.outstanding_floors // [] | .[] | select(.upgrade_file == strenv(FLOOR_FILE) and .module == strenv(FLOOR_MODULE) and .sha == strenv(FLOOR_SHA))] | length' 1
    echo "recorded"
    ;;
  bootstrap)
    NAME=$(collapse "${NAME:-}")
    REPO=$(canonical_ssh_url "$(collapse "${REPO:-}")")
    BASE_SHA=$(collapse "${BASE_SHA:-}")
    BRANCH=$(collapse "${BRANCH:-}")
    CLI_VERSION=$(collapse "${CLI_VERSION:-skill-v1}")
    MODULE=$(collapse "${MODULE:-}")
    MODULE_PATH=$(collapse "${MODULE_PATH:-}")
    MOUNT=$(collapse "${MOUNT:-}")

    # A non-template source ADDS its founding block to an existing manifest — see
    # the Effect note in the header. The template arm below is untouched by this.
    if [[ "$SOURCE" != template ]]; then
      [[ -f "$MANIFEST" ]] \
        || fail "no $MANIFEST in $(pwd) — a $SOURCE bootstrap ADDS a block to the component's existing manifest; it does not found one. Run from the component work-tree root, and bootstrap the template baseline first."
      SRC_HAS=$(yq -r "has(\"$SOURCE\")" "$MANIFEST" 2>/dev/null) \
        || fail "cannot parse $MANIFEST (yq error) — refusing to add a $SOURCE block to an unreadable manifest."
      [[ "$SRC_HAS" = false ]] \
        || fail "$MANIFEST already carries a $SOURCE block — bootstrap runs once per source; use ACTION=advance to move the baseline"
      [[ -n "$REPO" ]]        || fail "REPO required (the $SOURCE source's upstream URL)"
      [[ -n "$MODULE" ]]      || fail "MODULE required — the source repo's config.yaml module key this component was built from. It lands as $SOURCE.template and selects the subtree, the upgrade-file directory and the bellwethers on every future run; nothing here defaults it, because nothing here knows which modules that repo declares."
      [[ -n "$MODULE_PATH" ]] || fail "MODULE_PATH required — the module's subtree path inside the source repo (lands as $SOURCE.path)"
      [[ -n "$BRANCH" ]]      || fail "BRANCH required — the branch the baseline was DETECTED on, read back as the next run's default target. Not defaultable, for the same reason the template arm's is not."
      printf '%s' "$BASE_SHA" | grep -qE '^[0-9a-f]{40}$' \
        || fail "BASE_SHA must be a full 40-character hex SHA (got '${BASE_SHA}') — the detected baseline"

      # `web/` is the documented default mount, so it is OMITTED rather than
      # written: a key that only ever repeats the default forces every later
      # reader to tell a deliberate `web/` apart from an incidental one.
      export REPO MODULE MODULE_PATH BASE_SHA BRANCH MOUNT
      if [[ -n "$MOUNT" ]] && [[ "$MOUNT" != "web/" ]]; then
        FE_EXPR="$P"' = {"repo": strenv(REPO), "path": strenv(MODULE_PATH), "template": strenv(MODULE), "branch": strenv(BRANCH), "mount": strenv(MOUNT), "sha": strenv(BASE_SHA), "bootstrapped": true}'
      else
        FE_EXPR="$P"' = {"repo": strenv(REPO), "path": strenv(MODULE_PATH), "template": strenv(MODULE), "branch": strenv(BRANCH), "sha": strenv(BASE_SHA), "bootstrapped": true}'
      fi
      # Values AND types, every caller-supplied key, off the bytes about to land —
      # the same two independent checks the template arm makes, and for the same
      # reason: `template: ""` is a valid !!str, and a !!float SHA still reads back
      # as text. `bootstrapped` is the one deliberate !!bool.
      FE_ASSERTS=(
        "$P.repo // \"\""     "$REPO"
        "$P.path // \"\""     "$MODULE_PATH"
        "$P.template // \"\"" "$MODULE"
        "$P.branch // \"\""   "$BRANCH"
        "$P.sha // \"\""      "$BASE_SHA"
        "$P.repo | tag"       '!!str'
        "$P.path | tag"       '!!str'
        "$P.template | tag"   '!!str'
        "$P.branch | tag"     '!!str'
        "$P.sha | tag"        '!!str'
        "$P.bootstrapped | tag" '!!bool'
        "$P.bootstrapped"     'true'
      )
      if [[ -n "$MOUNT" ]] && [[ "$MOUNT" != "web/" ]]; then
        FE_ASSERTS+=( "$P.mount // \"\"" "$MOUNT" "$P.mount | tag" '!!str' )
      else
        FE_ASSERTS+=( "$P | has(\"mount\")" false )
      fi
      rewrite "$FE_EXPR" "${FE_ASSERTS[@]}"
      echo "bootstrapped"
      exit 0
    fi

    # Refuse to overwrite: bootstrap runs ONCE per component, ever, and a manifest
    # that already exists is a recorded history this call would erase.
    [[ -e "$MANIFEST" ]] \
      && fail "$MANIFEST already exists — bootstrap runs once per component; use ACTION=advance to move the baseline"
    # Component identity is pkg/schema/globals.go const ComponentName when that
    # file carries a real (non-placeholder) assignment. A caller that passed the
    # checkout directory against a real constant is refused. When the file is
    # absent, still a placeholder, or unparseable: NAME must come from the user
    # (Phase 2 asks). This script never guesses from Chart.yaml, go.mod, or the
    # directory basename.
    if [[ -f pkg/schema/globals.go ]]; then
      IP_SCRIPTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      resolved=$(PHASE_KEY="${PHASE_KEY}" bash "$IP_SCRIPTS/resolve-component-name.sh") || resolved=""
      if [[ -n "$resolved" ]]; then
        if [[ -z "$NAME" ]]; then
          NAME=$resolved
        elif [[ "$NAME" != "$resolved" ]]; then
          fail "NAME='$NAME' does not match pkg/schema/globals.go ComponentName='$resolved' — the schema constant is the component identity, not the git repo or directory name. Re-run with NAME=$resolved"
        fi
      fi
    fi
    [[ -n "$NAME" ]] || fail "NAME required — pkg/schema/globals.go has no usable const ComponentName. Ask the user; do not guess from the directory name, Chart.yaml, or go.mod."
    [[ -n "$REPO" ]] || fail "REPO required (the template's upstream URL)"
    printf '%s' "$BASE_SHA" | grep -qE '^[0-9a-f]{40}$' \
      || fail "BASE_SHA must be a full 40-character hex SHA (got '${BASE_SHA}') — the detected baseline"
    # No default (see WHY bootstrap's BRANCH is REQUIRED in the header): rule 4 of
    # Phase 2's target chain reads this value back as the NEXT migration's default
    # history, so guessing `main` here is guessing about the component's past.
    [[ -n "$BRANCH" ]] \
      || fail "BRANCH required — the branch the baseline was DETECTED on. It is not defaultable: rule 4 of Phase 2's target chain reads template.branch back on the NEXT migration of this component, so a guessed 'main' points that run at a history this baseline never came from. Phase 2 resolves the ref as \$BOOT_REF off the run-context anchor and passes it here; an empty BRANCH means that resolution never reached this call — fix it there rather than defaulting."

    # template.kind, the key the Kairos CLI (>= 0.3.35) stamps on every manifest
    # and `kairos component promote` reads. No manifest exists yet, so the kind
    # comes from the .init.mk facade check (lib/component-kind.sh).
    KIND=$(component_kind .)
    mkdir -p "$(dirname "$MANIFEST")" || fail "cannot create $(dirname "$MANIFEST")"
    CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    TMP=$(mktemp "$(dirname "$MANIFEST")/.manifest.yaml.XXXXXX") \
      || fail "cannot create a temp file next to $MANIFEST"
    trap 'rm -f "$TMP"' EXIT
    # strenv for EVERY value, the same discipline `set` and `advance` use: yq quotes
    # each one wherever a plain scalar would re-read as something other than a
    # string, and a value carrying YAML metacharacters stays data rather than
    # syntax. printf'ing these unquoted made the component's FOUNDING manifest the
    # one most likely to be mistyped — an all-digit 40-hex SHA is a valid YAML
    # float, a template branch named `1.0` likewise, and `created_at` a timestamp —
    # so any consumer that re-emits a value instead of echoing its raw token got
    # 1.2345678901234568e+39 as its baseline, or `1` as its branch.
    # bootstrapped: true is the one deliberate non-string. It is load-bearing as a
    # BOOLEAN — planner and executor both change behavior on it for the component's
    # whole life — and it is written here rather than transcribed from a doc
    # precisely because a single dropped line silently removes that caution.
    export NAME REPO BASE_SHA BRANCH CREATED_AT CLI_VERSION KIND
    yq -n '{"name": strenv(NAME), "template": {"repo": strenv(REPO), "sha": strenv(BASE_SHA), "branch": strenv(BRANCH), "kind": strenv(KIND)}, "created_at": strenv(CREATED_AT), "cli_version": strenv(CLI_VERSION), "bootstrapped": true}' \
      > "$TMP" || fail "yq could not write the initial manifest to $TMP"
    [[ "$(yq -r '.template.sha // ""' "$TMP" 2>/dev/null)" = "$BASE_SHA" ]] \
      || fail "the bootstrapped manifest failed its own check (template.sha was not $BASE_SHA) — refusing to write $MANIFEST"
    # The other three CALLER-SUPPLIED values, read back the same way. The check
    # covered template.sha alone, so the two keys that also come straight from the
    # caller — and the one that names the component for the rest of its life — were
    # written on trust: any construction that dropped or mangled them (a mistyped
    # strenv key, a value swallowed as YAML syntax) produced a manifest that reads
    # fine and describes a different component or a different upstream. The type
    # loop below cannot see that; `name: ""` is a perfectly good !!str.
    [[ "$(yq -r '.name // ""' "$TMP" 2>/dev/null)" = "$NAME" ]] \
      || fail "the bootstrapped manifest failed its own check (name was not '$NAME') — refusing to write $MANIFEST"
    [[ "$(yq -r '.template.repo // ""' "$TMP" 2>/dev/null)" = "$REPO" ]] \
      || fail "the bootstrapped manifest failed its own check (template.repo was not '$REPO') — refusing to write $MANIFEST"
    [[ "$(yq -r '.template.branch // ""' "$TMP" 2>/dev/null)" = "$BRANCH" ]] \
      || fail "the bootstrapped manifest failed its own check (template.branch was not '$BRANCH') — refusing to write $MANIFEST"
    [[ "$(yq -r '.bootstrapped // ""' "$TMP" 2>/dev/null)" = "true" ]] \
      || fail "the bootstrapped manifest failed its own check (bootstrapped was not true) — refusing to write $MANIFEST"
    [[ "$(yq -r '.template.kind // ""' "$TMP" 2>/dev/null)" = "$KIND" ]] \
      || fail "the bootstrapped manifest failed its own check (template.kind was not '$KIND') — refusing to write $MANIFEST"
    # The TYPE is re-read off the bytes about to land, not just the text: a value
    # whose text round-trips while its tag says !!float is exactly the failure this
    # write path had, and it is invisible to a value-only check.
    for k in .template.sha .template.branch; do
      [[ "$(yq -r "$k | tag" "$TMP" 2>/dev/null)" = '!!str' ]] \
        || fail "the bootstrapped manifest failed its own check ($k is not a YAML string) — refusing to write $MANIFEST"
    done
    # And the one key that must NOT be a string. The value check above reads
    # `.bootstrapped` as text, where `true` and `"true"` are indistinguishable — so
    # it passes over exactly the mistype that matters: planner and executor branch
    # on this key as a BOOLEAN for the component's whole life, and any consumer that
    # re-emits it (`yq -o=json`) gets a quoted string from a manifest that reads
    # fine. Same reasoning as the !!str loop, opposite direction.
    [[ "$(yq -r '.bootstrapped | tag' "$TMP" 2>/dev/null)" = '!!bool' ]] \
      || fail "the bootstrapped manifest failed its own check (.bootstrapped is not a YAML boolean — planner and executor read it as one for the component's whole life) — refusing to write $MANIFEST"
    preserve_mode "$TMP" "$MANIFEST"
    mv "$TMP" "$MANIFEST" || fail "could not write $MANIFEST"
    trap - EXIT
    echo "bootstrapped"
    ;;
  "") fail "ACTION required (set|clear|advance|bootstrap|record-floor|live-source|list-floors)" ;;
  *)  fail "unknown ACTION '$ACTION' (want set|clear|advance|bootstrap|record-floor|live-source|list-floors)" ;;
esac
