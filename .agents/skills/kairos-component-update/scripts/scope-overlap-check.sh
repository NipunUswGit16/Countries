#!/usr/bin/env bash
# scope-overlap-check.sh — advisory post-classification scope signal. Keys on the
# count of merge-pipeline files (template changes overlapping component
# customizations) from $RUN/summary.txt — the real cost driver.
#
# Advisory, never blocking. The only remedy a block could offer is a smaller
# TARGET, which defers the rest of the range to a second migration run — and a
# component targeting a specific template SHA usually cannot take that trade at
# all. Scope belongs to whoever picks TARGET, not to a gate that re-opens the
# question once classification is already paid for.
#
# Env in:  RUN         migration state dir (required)
#          THRESHOLD   merge-pipeline count above which the run is called large
#                      (default 30)
# Stdout:  MERGE_PIPELINE=<n>, THRESHOLD=<t>, then OK: or ADVISORY:
# Exit:    0  count resolved (advisory only — never blocks on overlap)
#          2  summary.txt missing/empty, or its merge-pipeline count is malformed
#             (a well-formed summary with no merge-pipeline row means count 0, exit 0)
set -u

: "${RUN:?FAIL: RUN not set}"
THRESHOLD="${THRESHOLD:-30}"

[[ -f "$RUN/summary.txt" ]] && [[ -s "$RUN/summary.txt" ]] || {
  echo "FAIL: $RUN/summary.txt missing or empty — run build-manifest.sh first" >&2
  exit 2
}

# build-manifest tallies buckets with `uniq -c`, which never emits a line for a
# bucket with zero rows — so a healthy small migration with no merge-pipeline
# overlap yields a well-formed summary.txt that simply OMITS the merge-pipeline
# row. Read that absence as count 0, not a missing-count hard stop (exit 2 stays
# reserved for a missing/empty summary, i.e. build-manifest didn't run). A present
# but non-numeric value is genuine corruption and still exits 2.
MP=$(awk -F'\t' '$1 == "merge-pipeline" { print $2 }' "$RUN/summary.txt")
[[ -n "$MP" ]] || MP=0
case "$MP" in
  *[!0-9]*)
    echo "FAIL: merge-pipeline count malformed in $RUN/summary.txt" >&2
    exit 2
    ;;
esac

echo "MERGE_PIPELINE=$MP"
echo "THRESHOLD=$THRESHOLD"

if [[ "$MP" -gt "$THRESHOLD" ]]; then
  echo "ADVISORY: $MP merge-pipeline files exceeds the $THRESHOLD-file overlap threshold — expect more conflicts, a longer plan and a bigger review; relay it and keep going"
else
  echo "OK: $MP merge-pipeline files is within the $THRESHOLD-file overlap threshold"
fi
