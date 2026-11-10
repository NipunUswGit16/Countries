#!/usr/bin/env bash
# followup-completeness.sh — enforce the post-merge follow-up catalogue, the way
# plan-completeness.sh enforces upgrade-file dispositions. It converts load-bearing
# follow-ups from "the planner happened to schedule them" into mechanism: each
# TRIGGER reads an artifact the run already wrote, and every triggered row must
# carry a disposition in PLAN.md's `## Follow-up Dispositions` table or the plan
# does not pass.
#
# WHY: correctness must not depend on which revision's planner felt thorough. Two
# runs of the same migration were caught/missed on the same three classes because
# the fixup was judgment, not a gate. Each trigger below derives from disk:
#
#   stale-ref  A path removed by the merge (mechanical delete, a delete/rename the
#              user confirmed in Phase 5, or a resolver `kept-delete` verdict read
#              out of the resolution ledger) still has references elsewhere in the
#              tree. This is the POST-delete sweep — distinct from Phase 5's
#              grep-before-recommend, which decided delete-vs-keep in the first
#              place. Mandatory; the user may dispose it as a logged skip.
#   producer   A producer dirtied tracked state (producer-idempotence-postmerge.tsv):
#              regenerate, or untrack and ignore. Mandatory.
#   skip       A semantic layer reported a skip (yaml gate, producer). The run
#              shipped without that cover; the plan must acknowledge the gap.
#              Mandatory acknowledgment.
#
# The reference grep is PATH-BASED and generic — the literal removed path, plus, for
# a rename, the directory the rename took AWAY (the shallowest ancestor of the old
# path that no longer holds any file — starting at the old path ITSELF for a
# dir-rename pair, whose `$old` can be the renamed directory rather than a file
# inside it; a directory that still holds files was not
# renamed away and is never flagged, and "holds a file" means git-meaningful content,
# not anything on disk — see dir_has_content). That prefix catches package / import
# references without any language coupling, and is anchored on BOTH sides so it
# matches a path SEGMENT rather than a substring: a sibling sharing the prefix
# (`internal-api` for `internal`) does not match, and neither does a mid-word
# occurrence (`api` inside `openapi.yaml`). It never keys off a key name, symbol, or
# directory spelling baked into this script.
#
# WHY a WHOLESALE absence of Phase 5's output is exit 2 and not an empty trigger
# set — the same answer plan-completeness.sh gives for an absent upgrade list, on
# the sibling half of the same gate: every trigger below reads an artifact Phase 5
# or its gates wrote, and a Phase 3 re-run regenerates none of them. So a session
# resuming into planning against a swept (or never populated) $RUN found no
# removals, no producer verdicts and no yaml-gate rows, printed "OK: no follow-ups
# triggered" and exited 0 — a green gate over missing inputs, on the one phase
# whose artifacts it exists to read. Nothing downstream re-derives the catalogue —
# PLAN.md is frozen at approval — so a follow-up that drops out here drops out of
# the migration silently.
#
# `clean-merged.txt` is the witness because structural-merge.sh truncates it, with
# the other merge inventories, unconditionally before its enactment loop — so
# present-and-empty (a merge with no clean merges) is distinguishable from absent at
# all, which is what any such marker needs. It is also the witness coverage-blind.sh
# already keys on at the top of Phase 6; that script stopping first does not make
# this check redundant, because a gate that reads its own inputs must not delegate
# its answer to whether an earlier step of the phase was run.
#
# The split is deliberate: only the wholesale absence refuses. An INDIVIDUALLY
# absent optional list, while the witness is present, keeps its original meaning —
# a run with no ask-user deletes legitimately has no confirmed-deletes.txt, and a
# run with no conflicts legitimately has no resolution ledger.
#
# Env in:  RUN           migration state dir (required)
#          PLAN          path to PLAN.md (required)
#          BOOTSTRAPPED  optional "1" — reserved for future mandatory rows (prune
#                        of example scaffolding stays planner-judgment; see
#                        agents/planner.md)
#          YAML_LABEL    optional yaml-gate label to read skips from (default postmerge)
# Reads:   $RUN/clean-merged.txt   REQUIRED — Phase 5's witness (see WHY above)
#          $RUN/producer-idempotence-postmerge.tsv
#                                  REQUIRED once that witness is present — the
#                                  POSTMERGE producer verdict, and only that label's.
#                                  Fixed, not a $PRODUCER_LABEL knob: this gate runs
#                                  at Phase 6, where postmerge is the only producer
#                                  verdict that describes the tree the plan is being
#                                  written for (a midplan or final verdict describes
#                                  a tree later tasks produced). It used to read one
#                                  unlabelled file every label overwrote, so a plan
#                                  revised after a midplan gate derived its
#                                  postmerge-mandatory acknowledgments from midplan's
#                                  verdict — and stopped requiring them where midplan
#                                  came back clean. Absent while the witness is
#                                  present is exit 2, by the same rule as the witness
#                                  itself: the verdict was never recorded, so this
#                                  gate cannot answer, and must not answer "clean".
# Reads (all optional; absent → that trigger simply doesn't fire):
#   $RUN/confirmed-deletes.txt        ask-user deletes enacted by apply-ask-user.sh
#   $RUN/deleted.txt                  mechanical template deletions (structural-merge)
#   $RUN/resolutions.tsv              file <TAB> verdict <TAB> reason — kept-delete
#   $RUN/resolutions.*.tsv            rows are removals; the per-batch shards are read
#                                     too, so the derivation does not depend on the
#                                     collect step having run
#   $RUN/renamed.txt                  "old -> new" mechanical renames
#   $RUN/dir-rename-pairs.tsv         old <TAB> new (dir-rename re-pairings)
#   $RUN/yaml-gate-<LABEL>.tsv        severity <TAB> file <TAB> kind <TAB> detail
# Cwd:     component root (a git repo — the reference grep runs here)
# Stderr:  triggered follow-ups and any MISSING dispositions
# Exit:    0  every triggered follow-up dispositioned (or nothing triggered)
#          1  one or more triggered follow-ups lack a disposition in PLAN.md
#          2  Phase 5's witness is ABSENT — the gate cannot answer, and must not
#             answer "clean". Re-run Phase 5 (phases/5-structural.md) and come back.
set -u

: "${RUN:?FAIL: RUN not set}"
: "${PLAN:?FAIL: PLAN not set}"
[[ -f "$PLAN" ]] || { echo "FAIL: plan not found: $PLAN" >&2; exit 1; }
YAML_LABEL=${YAML_LABEL:-postmerge}

# --- input presence, before any trigger is derived ----------------------------
[[ -f "$RUN/clean-merged.txt" ]] || {
  echo "FAIL: $RUN/clean-merged.txt is absent — the structural merge never ran here, or the state dir was swept. Every trigger this gate derives reads a Phase 5 artifact, and none of them is regenerated by a Phase 3 re-run: it cannot pass over missing inputs. Re-run Phase 5 (phases/5-structural.md) — read its redo warning first — then re-run this gate." >&2
  exit 2
}
# The producer verdict is the SECOND witness, and it is the postmerge one by name.
# producer-idempotence.sh truncates its file unconditionally, so present-and-empty
# (a run with no producer command recorded) is distinguishable from absent at all —
# and absent, with the merge witness sitting right beside it, means Phase 5's
# post-merge gate never ran against this $RUN. Deriving nothing from that is the
# fail-open shape this gate exists against: a `skip:producer-*` acknowledgment is
# plan-blocking, so its absence must never be inferred from a missing file. A
# labelled file for another label does not stand in — that is the defect this
# by-name read fixes, not a fallback it should keep.
PRODUCER_TSV="$RUN/producer-idempotence-postmerge.tsv"
[[ -f "$PRODUCER_TSV" ]] || {
  echo "FAIL: $PRODUCER_TSV is absent while $RUN/clean-merged.txt is present — the structural merge ran but its POST-MERGE gate did not record a producer verdict here (a midplan or final verdict is not a substitute: it describes a later tree). This gate derives plan-blocking producer follow-ups from that file and cannot pass over its absence. Re-run the Phase 5 post-merge gate (phases/5-structural.md, LABEL=postmerge), then re-run this gate." >&2
  exit 2
}

TRIGGERS=$(mktemp "${TMPDIR:-/tmp}/followup-triggers.XXXXXX")
trap 'rm -f "$TRIGGERS"' EXIT

emit() { printf '%s\t%s\n' "$1" "$2" >> "$TRIGGERS"; }   # key <TAB> human description

# --- stale references after a removal ---------------------------------------
# A removed path that still appears (as a literal path string) anywhere in the
# tracked tree is a stale reference. Grep is fixed-string and path-scoped, so it
# does not depend on any name this script could hardcode.
# `--` before the path on BOTH greps: a path that starts with `-` is an operand, not
# a bundle of options. Without it the self-exclusion grep failed outright (BSD grep
# reads `-dash.yaml` as flags), the pipeline swallowed the error, and a stale
# reference to such a path was silently dropped instead of flagged.
refs_to() { # refs_to <path-string> — prints matching files (excludes the path itself)
  git grep -I -l -F -- "$1" -- . ':!.kairos' 2>/dev/null | grep -vxF -- "$1" || true
}
# A DIRECTORY prefix must be anchored on BOTH sides, or it is a substring match.
# Right side: the prefix has to be followed by `/` or any other non-name character
# (quote, dot, end of line) — anchoring on `/` alone would drop the Go import case,
# `"…/<removed-dir>"`, which is exactly what this trigger exists to catch, and no
# right anchor at all makes `internal` match `internal-api`, so every surviving
# sibling manufactures a follow-up.
#
# Left side: the same character class, mirrored. Without it a SHORT directory name
# matches mid-word — `api` fires inside "openapi.yaml" — and the result is a
# MANDATORY, plan-blocking stale-ref row against a document that has nothing to do
# with the rename. The class excludes alphanumerics, `_` and `-` only, so the
# boundary characters a real path reference carries all still match: line start,
# whitespace, quote, `(`, `=`, `:`, `/` (`"example.com/m/internal/foo"` — a Go
# import is the case this trigger was written for) and `.` (`./web/x`). The cost of
# admitting `.` and `/` is that `x.api/…` or `openapi/api` also match, which is the
# right trade: those ARE path segments spelled `api`, while "openapi.yaml" is not.
#
# The prefix is escaped first: it is a path going into an ERE. Mirrored bracket
# classes rather than `\b`, which neither BSD ERE nor mawk supports.
refs_to_dir() { # refs_to_dir <dir> — prints files referencing <dir> as a path segment
  local esc
  esc=$(printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g')
  git grep -I -l -E -- "(^|[^[:alnum:]_-])$esc([^[:alnum:]_-]|\$)" -- . ':!.kairos' 2>/dev/null || true
}

REMOVED=$(mktemp "${TMPDIR:-/tmp}/followup-removed.XXXXXX")
trap 'rm -f "$TRIGGERS" "$REMOVED"' EXIT
for src in confirmed-deletes.txt deleted.txt; do
  [[ -f "$RUN/$src" ]] && grep -v '^$' "$RUN/$src" >> "$REMOVED"
done
# Resolver deletions are DERIVED, not transcribed. A `kept-delete` verdict removes a
# path but reaches none of the sources above: deleted.txt is written only for the
# mechanical bucket, and a kept-delete comes out of a for-AI reasoning bucket. That
# gap used to be closed by a prose hand-append at the Phase 5 dispatch site, with no
# gate row covering it — so a forgotten append silently dropped a stale-reference
# follow-up. The verdicts are already on disk; read them.
#
# Read the SHARDS as well as the concatenated file. $RUN/resolutions.tsv is written by
# log-resolution.sh's `collect` alone, so deriving from it would trade one prose step
# for another — and reading both is also what makes this correct on the
# no-runtime-dispatch fallback (whose verdicts go to the reserved `role-switch` shard,
# published only by that collect), on a state dir whose pre-fix aggregate rows were
# materialized into the `legacy` shard, and on a run that died between the last batch
# and the collect. The union is de-duplicated below.
for led in "$RUN"/resolutions.tsv "$RUN"/resolutions.*.tsv; do
  [[ -f "$led" ]] || continue
  awk -F'\t' '$2 == "kept-delete" && $1 != "" { print $1 }' "$led" >> "$REMOVED"
done
# Rename OLD paths are removals too; the old *directory* prefix, when the rename
# crossed directories, catches import/package references a full-path grep misses.
RENAME_DIRS=$(mktemp "${TMPDIR:-/tmp}/followup-rndirs.XXXXXX")
trap 'rm -f "$TRIGGERS" "$REMOVED" "$RENAME_DIRS"' EXIT

# Does <dir> still hold anything GIT WOULD CALL CONTENT? Three things this is not,
# each for a reason:
#
#   * not the index alone (`git ls-files`): at Phase 6 the merge has removed the old
#     paths with plain `rm -f` (see structural-merge.sh), so the index still lists
#     every one of them and a renamed-away directory would look alive. Hence the
#     `[ -e ]` filter — a tracked path counts only while it is still on disk.
#   * not `[ -d ]`: `rm -f` leaves the emptied directory behind.
#   * not a raw `find` either, which is what this used to be. `find` counts
#     ANYTHING on disk, so the normal state of a JS project disarmed the trigger
#     outright: web/node_modules/ — gitignored, present on every developer machine —
#     made a renamed-away `web/` look alive, and the stale `COPY web/package.json`
#     in the Dockerfile was silently dropped from the plan. One stray .DS_Store did
#     the same. Ignored files are not content by any definition the migration cares
#     about.
#
# So: tracked files still present, PLUS untracked-but-not-ignored ones. The second
# half is deliberate — a new, uncommitted file in that directory IS work living
# there, and flagging the directory as renamed away would be wrong.
#
# CASE-SENSITIVITY. Which paths are even considered is now platform-independent:
# pathspecs match byte-exactly (verified — `:(literal)web` does not match an index
# entry `Web/…` even with core.ignorecase=true), where the old `[ -d ]` + `find`
# pair leaned on the filesystem twice and made a Web/web rename produce a different
# trigger count on macOS than on Linux. What remains filesystem-dependent is the
# `[ -e ]` probe alone: on a case-insensitive filesystem `Web/src/app.js` resolves
# while only `web/src/app.js` exists, so a surviving file under the OTHER spelling
# would read as content here and not on Linux. That is inherent — no on-disk fact
# distinguishes the two names there — and it is narrow: the state a case-only rename
# actually leaves (new paths written, old ones `rm -f`'d, which on a case-insensitive
# filesystem removes the file just written) yields the same verdict on both
# platforms, verified in the Ubuntu container and on macOS.
dir_has_content() { # dir_has_content <dir>
  local d="$1" f
  while IFS= read -r -d '' f; do
    [[ -e "$f" ]] && return 0
  done < <(git ls-files -z -- ":(literal)$d" 2>/dev/null)
  [[ -n "$(git ls-files --others --exclude-standard -z -- ":(literal)$d" 2>/dev/null)" ]] && return 0
  return 1
}

# The directory a rename took AWAY, or nothing. Walk up from the old path's
# directory and return the SHALLOWEST ancestor that no longer holds any file; stop
# at the first one that survives. Two failures this replaces, both from keying off
# `dirname(old)` alone:
#   * a single file moved OUT of a surviving directory (internal/moved.go ->
#     pkg/moved.go) named `internal`, whose anchored prefix then matched every
#     reference to anything under it — a false MANDATORY, plan-blocking follow-up
#     against a directory that is still there;
#   * a top-level directory rename whose files live deeper (web/src/app.js ->
#     frontend/src/app.js) named only `web/src`, so `web` — the directory that was
#     actually renamed away, and the prefix a `COPY web/package.json` reference
#     carries — was never checked at all.
# The shallowest gone ancestor subsumes the deeper ones: refs_to_dir's prefix
# pattern matches `web/src/...` from `web`, so one row covers the whole subtree.
#
# WHERE THE WALK STARTS is a per-source decision, hence the second argument.
# renamed.txt rows name a FILE, so the first directory worth judging is its
# parent — starting at the file itself would enter it into RENAME_DIRS whenever
# its parent survives, duplicating the removed-path row it already gets.
# dir-rename-pairs.tsv rows are the other shape: `$old` can BE the renamed-away
# directory (see reference/structural-merge.md on hand-corrected pairings), and
# starting at `dirname($old)` then judged only its PARENT — which normally
# survives, so the walk broke on the first probe and the directory the pair
# names was never anchored-checked at all. The boundary-anchored refs_to_dir
# grep (the one that stops `openapi.yaml` false-matching an `api` dir) therefore
# never applied to the one path shape dir-pairs contribute; a stale reference to
# it was left to the broader fixed-string REMOVED grep, which cannot tell
# `internal/moved` from a surviving sibling `internal/moved-v2`. `self` judges
# `$old` itself first, by the same dir_has_content criteria, before walking to
# ancestors.
#
# `dirname` is fed an ANCHORED path and its answer de-anchored again. renamed.txt
# carries raw component paths, and a leading-dash one reaches dirname as a bundle
# of options (it has no portable `--`): it printed a usage error and returned
# EMPTY, the `[ -n "$d" ]` guard below then ended the walk before its first probe,
# and the directory the rename took away was never judged at all — no row, no
# MISSING line, a green gate over a live stale reference. The `./` comes back off
# because `$d` is not an operand here: it goes into git pathspecs and into the
# `"$rd"/*` moved-within test, both of which compare against git's spelling.
renamed_away_dir() { # renamed_away_dir <old-path> [self]
  local d ad gone=""
  case "${2:-}" in
    self) d="$1" ;;
    *)
      case "$1" in /*|./*) ad="$1" ;; *) ad="./$1" ;; esac
      d=$(dirname "$ad"); d=${d#./}
      ;;
  esac
  while [[ -n "$d" ]] && [[ "$d" != "." ]] && [[ "$d" != "/" ]]; do
    dir_has_content "$d" && break
    gone="$d"
    case "$d" in */*) d="${d%/*}" ;; *) d="" ;; esac
  done
  [[ -n "$gone" ]] && printf '%s\n' "$gone"
}

add_rename() { # add_rename <old> <new> [self]
  local old="$1" new="$2" rd
  [[ -n "$old" ]] || return 0
  # $old is a removal whatever its shape — the literal-path grep must still see
  # it, or a reference to the exact old path is lost. Both appends are `printf`,
  # never `echo`: bash's builtin echo reads an argument that is EXACTLY an option
  # string (`-n`, `-e`, `-E`, any combination) as its own options, so a removed
  # path or renamed-away directory spelled that way was appended as an empty line
  # — or with `-n` in the set as nothing at all — and the empty-line guard on the
  # loops that read these files back then skipped it. The trigger vanished
  # silently: no stale-ref row, no MISSING line, "OK: no follow-ups triggered"
  # over a reference that is still live in the tree.
  printf '%s\n' "$old" >> "$REMOVED"
  rd=$(renamed_away_dir "$old" "${3:-}")
  [[ -n "$rd" ]] || return 0
  case "$new" in "$rd"/*) return 0 ;; esac   # moved within it: nothing was taken away
  printf '%s\n' "$rd" >> "$RENAME_DIRS"
}
if [[ -f "$RUN/renamed.txt" ]]; then
  while IFS= read -r ln; do
    [[ -n "$ln" ]] || continue
    add_rename "${ln%% -> *}" "${ln##* -> }"
  done < "$RUN/renamed.txt"
fi
if [[ -f "$RUN/dir-rename-pairs.tsv" ]]; then
  while IFS=$'\t' read -r old new; do
    [[ -n "${old:-}" ]] || continue
    add_rename "$old" "$new" self
  done < "$RUN/dir-rename-pairs.tsv"
fi

sort -u "$REMOVED" -o "$REMOVED" 2>/dev/null || true
sort -u "$RENAME_DIRS" -o "$RENAME_DIRS" 2>/dev/null || true

while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  if [[ -n "$(refs_to "$p")" ]]; then
    emit "stale-ref:$p" "removed path '$p' still referenced in the tree"
  fi
done < "$REMOVED"
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  if [[ -n "$(refs_to_dir "$d")" ]]; then
    emit "stale-ref:$d" "renamed-away directory '$d' still referenced in the tree"
  fi
done < "$RENAME_DIRS"

# --- producer idempotence ----------------------------------------------------
# Presence was already proven above, so there is no `[ -f ]` arm here: this read
# either happens or the gate has already refused.
while IFS=$'\t' read -r label verdict detail; do
  case "$verdict" in
    dirty-tracked|untracked-output)
      emit "producer:$label" "producer '$label' $verdict — $detail" ;;
    skip)
      emit "skip:producer-$label" "producer '$label' skipped (incomplete coverage) — $detail" ;;
  esac
done < "$PRODUCER_TSV"

# --- semantic-layer skips (yaml gate) ----------------------------------------
YG="$RUN/yaml-gate-$YAML_LABEL.tsv"
if [[ -f "$YG" ]]; then
  # One follow-up per skipped kind, not per row.
  # emit writes to $TRIGGERS by file redirect, so the pipeline subshell is fine.
  awk -F'\t' '$1=="skip"{print $3}' "$YG" | sort -u | while IFS= read -r kind; do
    [[ -n "$kind" ]] || continue
    emit "skip:yaml-$kind" "yaml gate '$kind' layer skipped (incomplete semantic coverage)"
  done
fi

sort -u "$TRIGGERS" -o "$TRIGGERS" 2>/dev/null || true

if [[ ! -s "$TRIGGERS" ]]; then
  echo "OK: no follow-ups triggered" >&2
  exit 0
fi

# --- dispositions in PLAN.md -------------------------------------------------
DISPOSITIONED=$(mktemp "${TMPDIR:-/tmp}/followup-disp.XXXXXX")
trap 'rm -f "$TRIGGERS" "$REMOVED" "$RENAME_DIRS" "$DISPOSITIONED"' EXIT
awk '
  /^## Follow-up Dispositions/ { t = 1; next }
  t && /^## / { t = 0 }
  t && /^\| `/ {
    line = $0
    sub(/^\| `/, "", line)
    sub(/`.*/, "", line)
    gsub(/^ +| +$/, "", line)
    if (line != "" && line != "Follow-up") print line
  }
' "$PLAN" | sort -u > "$DISPOSITIONED"

echo "OK: follow-ups triggered:" >&2
awk -F'\t' '{print "  - " $1 " — " $2}' "$TRIGGERS" >&2

# One MISSING line per KEY, not per trigger row. A single path can be reported by
# two derivations at once — a dir-rename pair whose `$old` is both a removed path
# and the renamed-away directory itself earns a row from each, with different
# descriptions — and both are satisfied by the same disposition, so reporting the
# key twice would only tell the operator to add a row they already added.
MISSING=0
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  # `--`: every key carries a `stale-ref:` / `producer:` / `skip:` prefix today, so
  # none can present as an option — the marker keeps that true if a future key is
  # ever the bare path.
  if ! grep -qxF -- "$key" "$DISPOSITIONED"; then
    echo "MISSING: $key" >&2
    MISSING=$((MISSING + 1))
  fi
done < <(cut -f1 "$TRIGGERS" | sort -u)

if [[ "$MISSING" -gt 0 ]]; then
  echo "FAIL: $MISSING follow-up(s) lack a disposition in $PLAN (add a row to '## Follow-up Dispositions')" >&2
  exit 1
fi
echo "OK: every triggered follow-up is dispositioned" >&2
