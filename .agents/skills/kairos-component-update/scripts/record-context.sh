#!/usr/bin/env bash
# record-context.sh — upsert KEY=VALUE pairs into $RUN/context.env, the
# run-context anchor every phase start re-reads.
#
# WHY: orchestrator conversation memory is the least durable component in a
# many-hour run — in-session compaction can evict any value that lives only in
# chat, and the model then "remembers" a plausible wrong SHA or path with full
# confidence. $RUN/context.env is what a compacted session re-reads instead:
# the scripts that learn a value record it themselves (pre-flight, clone-common,
# materialize), and the orchestrator records the conversationally-derived ones
# (TARGET_REF, MIGRATION_BRANCH, ...) the moment a phase establishes them.
#
# The CANONICAL KEY LIST lives in SKILL.md -> Run-context anchor (restated in full
# by reference/continue.md, with a lint holding the two in correspondence). This
# script deliberately does not enforce it: it is the format owner for the FILE, not
# the vocabulary — a keyed writer would have to be edited for every new key, and a
# refused key would strand the phase that needed it. SKILL_DIR is on that list and
# recorded by pre-flight.sh, since every phase code block locates these scripts
# through it after a compaction.
#
# WHY keyless — no PHASE_KEY guard, DELIBERATELY: this script is called from
# inside pre-flight.sh, clone-common.sh and materialize.sh, which do not (and
# must not) forward their own phases' keys — a guard here would brick every one
# of those callers. Same rationale log-learning.sh documents for itself: it is
# not a phase entry point and must not appear in the key inventory
# tests/skill-lint.test.sh audits. Do not "fix" this by adding a key.
#
# Usage:   RUN=<dir> record-context.sh KEY=VALUE [KEY=VALUE ...]
# Env in:  RUN  migration state dir (required; created if missing)
# Args:    one or more KEY=VALUE pairs. KEY must match [A-Z][A-Z0-9_]*; the
#          value must be a single line and carry no carriage return or tab (the
#          file is one KEY=VALUE per line, and the two invisible characters would
#          ride into the value every reader takes from it), and must not begin or
#          end with a space (same damage, one degree more visible — internal
#          spaces are legal, and so is an empty value). Any invalid pair
#          rejects the WHOLE call before anything is written: a partially
#          recorded call would be a context file that half-lies.
# Effect:  each pair replaces an existing KEY=... line in $RUN/context.env,
#          else appends (upsert — last write wins). The file is written via a
#          temp file + mv in the same directory, so a crash mid-write never
#          leaves a half-written context.env. Idempotent.
# CONCURRENCY: this read-modify-write is NOT safe against two concurrent callers
#          — each reads the same starting $CTX, so whichever's mv lands second
#          silently wins and the other's upserted pairs are gone, with no error
#          from either invocation. Not guarded, by design-assumption rather than
#          oversight: every caller in this skill (pre-flight.sh, clone-common.sh,
#          materialize.sh, and the orchestrator itself) is invoked serially —
#          one phase's code block runs to completion before the next starts —
#          so there is exactly one writer at a time in every run this script
#          ships in. If a future caller ever dispatches parallel writers against
#          the same $RUN/context.env, this script needs a lock (e.g. flock or a
#          mkdir-based mutex) before that caller lands, not after.
# WHY every step of the read-modify-write is CHECKED (and not just the crash
#          story above): a crash and a failed WRITE are not the same hazard. A
#          crash never reaches the final mv, so the old file survives — but a
#          full disk, a filesystem quota, an ENOSPC or a read error fails one
#          `cat`, `grep` or `>>` and, with `set -u` and no `-e`, the loop carries
#          straight on and the final mv COMMITS the damage. That was observed:
#          the initial `cat "$CTX" > "$TMP"` half-copied, so keys recorded by
#          earlier phases were silently gone; a truncated append glued two pairs
#          into one row; and the script exited 0 either way. context.env is the
#          anchor a compacted session re-reads INSTEAD of conversation memory, so
#          a silently thinned one is worse than none: nothing downstream can tell
#          a key that was never recorded from one this call dropped. Any failed
#          step is therefore exit 2 naming the operation, with $CTX untouched.
# Stdout:  nothing
# Exit:    0 recorded; 2 bad input (RUN unset, no pairs, malformed pair)
set -u

# Explicit guard (not `${VAR:?}`, which exits 1): the header promises exit 2
# for every bad-input case, matching codev-check.sh's convention.
[[ -n "${RUN:-}" ]] || { echo "FAIL: RUN not set" >&2; exit 2; }
[[ "$#" -ge 1 ]] || { echo "FAIL: no KEY=VALUE pairs given" >&2; exit 2; }

# Validate EVERY pair before writing anything — reject-all-or-record-all.
#
# Newline, carriage return and tab are all refused, and for one reason: every reader of
# this file is `sed -n 's/^KEY=//p'` consumed as a shell word (SKILL.md's phase-start
# idiom, plan-completeness.sh, wrong-target-check.sh). A newline splits the record; a
# CR or a tab rides INVISIBLY into the value, so a recorded SHA, ref or path that looks
# correct on screen matches nothing and fails every later `test -d` / `git rev-parse`
# with nothing to blame — and a tab is additionally the field separator of the TSV
# ledgers these values get carried into. A CRLF-authored value (trailing CR) is the
# shape this actually arrives in. log-spawn.sh and log-resolution.sh collapse exactly
# these three characters in their own ledgers; here the pair is refused instead,
# because a silently-trimmed value is still a value nobody asked to record.
NL='
'
for pair in "$@"; do
  case "$pair" in
    *"$NL"*) echo "FAIL: value for '${pair%%=*}' contains a newline — context.env is one KEY=VALUE per line" >&2; exit 2 ;;
    *$'\r'*) echo "FAIL: value for '${pair%%=*}' contains a carriage return — it would ride invisibly into the value every reader takes from this file" >&2; exit 2 ;;
    *$'\t'*) echo "FAIL: value for '${pair%%=*}' contains a tab — it would ride invisibly into the value, and a tab is the field separator of the ledgers these values reach" >&2; exit 2 ;;
    *=*) : ;;
    *)   echo "FAIL: not a KEY=VALUE pair: '$pair'" >&2; exit 2 ;;
  esac
  # Leading/trailing whitespace is the CR's visible cousin and does the same damage:
  # `TARGET=abc123 ` fails every `git rev-parse`, ` /tmp/tpl` fails every `test -d`,
  # and `COMMON_MODULES=present ` stops equalling `present` in plan-completeness.sh's
  # gate — with nothing on screen to blame in any of the three. Refused rather than
  # trimmed, on the same reasoning as the CR and the tab: a silently-corrected value
  # is still a value nobody asked to record. INTERNAL spaces stay legal — a path or a
  # component name can carry one — and an EMPTY value stays legal, because for
  # SQUASH_ON_FINISH and friends the empty record is itself the answer.
  case "${pair#*=}" in
    " "*|*" ") echo "FAIL: value for '${pair%%=*}' has leading or trailing whitespace — refused, not trimmed: it rides invisibly into every reader's shell word (internal spaces are fine)" >&2; exit 2 ;;
  esac
  printf '%s' "${pair%%=*}" | LC_ALL=C grep -qE '^[A-Z][A-Z0-9_]*$' \
    || { echo "FAIL: key must match [A-Z][A-Z0-9_]* (got '${pair%%=*}')" >&2; exit 2; }
done

mkdir -p "$RUN" || { echo "FAIL: cannot create $RUN" >&2; exit 2; }
CTX="$RUN/context.env"

# The temp file lives in the SAME directory as context.env so the final mv is a
# same-filesystem rename — a crash at any point leaves either the old file or
# the new one, never a truncated in-between. Write FAILURES are the other half of
# that promise and are checked step by step below (see the header): a crash never
# reaches the final mv, but a failed write does, and the mv then commits it.
TMP=$(mktemp "$RUN/.context.env.XXXXXX") \
  || { echo "FAIL: cannot create a temp file in $RUN" >&2; exit 2; }
trap 'rm -f "$TMP" "$TMP.filter"' EXIT

# The seed copy is the ONE step that carries every previously-recorded key, so an
# unchecked partial `cat` is the worst of the failures: the upserted pairs still
# land, the final mv still succeeds, and the run continues over a context.env
# missing SKILL_DIR / TEMPLATE_PATH / TARGET with nothing to blame.
if [[ -f "$CTX" ]]; then
  cat "$CTX" > "$TMP" \
    || { echo "FAIL: could not copy the existing $CTX into $TMP — refusing to install a context.env built from a partial read of it (every key recorded by an earlier phase could be silently gone). $CTX is unchanged; free space in $RUN and re-run." >&2; exit 2; }
fi

for pair in "$@"; do
  key=${pair%%=*}
  # KEY is [A-Z][A-Z0-9_]* by the validation above — no regex metacharacters.
  # grep -v exits 1 when it filters every line out; that is an empty result, not
  # an error. Exit >=2 is: it means grep could not READ $TMP or could not WRITE
  # the filtered copy, and an unconditional `|| true` swallowed the two together
  # — the loop then mv'd a truncated (or empty) .filter over $TMP and the final
  # mv installed it as context.env, dropping every key the filter never copied.
  # So the two are told apart by the status, not merged into "non-zero is fine".
  LC_ALL=C grep -v "^${key}=" "$TMP" > "$TMP.filter"
  GREP_RC=$?
  [[ "$GREP_RC" -le 1 ]] \
    || { echo "FAIL: could not filter '$key' out of $TMP (grep exit $GREP_RC — a read/write error, not 'no match'): the filtered copy would be incomplete and would drop keys recorded earlier. $CTX is unchanged." >&2; exit 2; }
  mv "$TMP.filter" "$TMP" || { echo "FAIL: could not update $TMP while upserting '$key'" >&2; exit 2; }
  printf '%s\n' "$pair" >> "$TMP" \
    || { echo "FAIL: could not append '$key' to $TMP — a partial append glues two pairs into one unreadable row, and the upsert of '$key' is missing either way. $CTX is unchanged." >&2; exit 2; }
done

mv "$TMP" "$CTX" || { echo "FAIL: could not write $CTX" >&2; exit 2; }
trap - EXIT
