#!/usr/bin/env bash
# next-upgrade-file.sh — serves exactly ONE upgrade-file body for a caller-named
# slug. Stateless: no cursor, no hidden queue position — the caller names the
# slug it wants and receives that snapshot body.
#
# EXIT CODES ARE THE CONTRACT, one per cause (reference/upgrade-files.md carries
# the table). A single overloaded 2 could not tell the caller which of four things
# went wrong, and they have four different remedies — one of which no re-run can
# clear. A slug whose capture was REFUSED (the producer's `git show` failed) will
# be refused identically on every re-run, so telling it apart from "not
# snapshotted yet" is what keeps the caller off a loop.
#
# A ZERO-BYTE body is NOT a failure here. The producers distinguish a failed read
# (non-zero `git show`) from a legitimately empty file (`git show` succeeded, the
# blob is 0 bytes) — see snap_upgrade in build-manifest.sh / collect-common.sh —
# so a 0-byte snapshot on disk means the committed upgrade-file is empty. That is
# served, with an explicit `EMPTY:` line, because the alternative made a
# genuinely-empty upgrade-file permanently unmigratable: the slug stays in the
# list, the planner cannot fetch it, and the completeness gate blocks on it
# forever.
#
# Env in:  RUN    migration state dir (required)
#          SLUG   basename without .md (required)
#          LIST   ordered list of upgrade-file paths (default:
#                 $RUN/upgrades-added.txt) — used to verify the slug is in scope
# Cwd:     irrelevant
# Reads:   $RUN/upgrades/<slug>.md        the snapshotted body (see build-manifest.sh)
#          $RUN/snapshot-refusals.tsv     optional; slug <TAB> source <TAB> reason,
#                                         written by the producers when a body could
#                                         not be read at all
# Stdout (on success): `SLUG: <slug>`, then `EMPTY: …` if the body is zero bytes,
#          then a blank line, then the upgrade-file body
# Exit:    0   body served (possibly an empty one, announced by the EMPTY: line)
#          2   bad input: RUN or SLUG unset, or LIST missing
#          3   the slug is not in LIST — out of scope for this list
#          4   in scope, but no snapshot exists for it (this phase never ran, or
#              the state dir was swept) — re-run the collecting phase
#          5   in scope, but its capture was REFUSED and no body survives: the
#              recorded reason is relayed, and the remedy depends on it — an
#              unreadable object (git show failed) reproduces on every re-run
#              until the source repo/mirror is repaired; a write failure (mv
#              failed) is different and clears once $RUN/upgrades is writable
#              again. Either way, disposition the slug explicitly as a fallback.
set -u

# Explicit guards (not `${VAR:?}`, which exits 1): the header promises exit 2
# for every bad-input case.
[[ -n "${RUN:-}" ]]  || { echo "FAIL: RUN not set" >&2; exit 2; }
[[ -n "${SLUG:-}" ]] || { echo "FAIL: SLUG not set" >&2; exit 2; }
LIST="${LIST:-$RUN/upgrades-added.txt}"

[[ -f "$LIST" ]] || { echo "FAIL: list file not found: $LIST" >&2; exit 2; }

in_list=0
# `|| [ -n "$entry" ]`: a FINAL line with no trailing newline is a line like any
# other (see intent-check.sh ~:947) — without it, a LIST file whose last byte is
# the final slug (no terminating newline) drops that entry from the read loop and
# a valid, in-scope slug wrongly falls through to exit 3 "out of scope".
while IFS= read -r entry || [[ -n "$entry" ]]; do
  [[ -n "$entry" ]] || continue
  base=$(basename "$entry")
  base=${base%.md}
  if [[ "$base" = "$SLUG" ]]; then
    in_list=1
    break
  fi
done < "$LIST"
if [[ "$in_list" -eq 0 ]]; then
  echo "FAIL: slug not in list: $SLUG ($(basename "$LIST")) — out of scope for this list" >&2
  exit 3
fi

# Was this slug's capture refused? Read once: it decides the message for an absent
# body (exit 5, not 4) and adds a staleness warning to a body that survived.
REFUSALS="$RUN/snapshot-refusals.tsv"
REFUSED_WHY=""
if [[ -f "$REFUSALS" ]]; then
  REFUSED_WHY=$(S="$SLUG" awk -F'\t' '$1 == ENVIRON["S"] { print $3; exit }' "$REFUSALS")
fi

BODY_FILE="$RUN/upgrades/$SLUG.md"
if [[ ! -f "$BODY_FILE" ]]; then
  if [[ -n "$REFUSED_WHY" ]]; then
    echo "FAIL: upgrade-file body for '$SLUG' could not be captured: $REFUSED_WHY" >&2
    echo "      Recorded in $REFUSALS. The remedy depends on the reason above:" >&2
    case "$REFUSED_WHY" in
      *"mv failed"*)
        echo "      this is a write failure, not an unreadable object — fix \$RUN/upgrades's" >&2
        echo "      writability/space and re-run the collecting phase; it clears on retry." >&2
        ;;
      *)
        echo "      re-running the collecting phase reads the same object and fails the same" >&2
        echo "      way: repair the source repo/mirror (re-fetch it) instead." >&2
        ;;
    esac
    echo "      Or disposition this slug explicitly in PLAN.md naming the unreadable body." >&2
    exit 5
  fi
  echo "FAIL: upgrade-file body not snapshotted: $BODY_FILE" >&2
  echo "      The slug is in scope but nothing captured it — the collecting phase never" >&2
  echo "      ran against this \$RUN, or the state dir was swept. Re-run it (Phase 3 for" >&2
  echo "      template upgrade-files, Phase 3.5 for common ones), then ask again." >&2
  exit 4
fi

# A body that survived a refused RE-capture is still the right thing to serve (the
# producer kept it on purpose), but the caller is told it predates this run's
# failed read rather than discovering it later.
[[ -n "$REFUSED_WHY" ]] && \
  echo "WARN: this run's re-capture of '$SLUG' was refused ($REFUSED_WHY) — serving the body captured by an earlier run" >&2

echo "SLUG: $SLUG"
[[ -s "$BODY_FILE" ]] || \
  echo "EMPTY: this upgrade-file is zero bytes as committed — there is nothing to apply; disposition it as such"
echo
cat "$BODY_FILE"
