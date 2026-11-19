#!/usr/bin/env bash
# supersede-edges.test.sh — tests for scripts/lib/supersede-edges.sh, the shared
# edge-emission helper the three collectors (build-manifest.sh, collect-common.sh,
# collect-lib.sh) source to parse `supersedes:` and classify each declared edge.
#
# The helper's contract is file-based and source-agnostic:
#   supersede_emit <order_file> <list_file> <snap_dir> <edge_out>
#     order_file : "module <TAB> stem"            added files, in apply order
#     list_file  : "module <TAB> stem <TAB> kind" every collected file (added|modified)
#     snap_dir   : holds <stem>.md snapshot bodies
#     edge_out   : rows appended here — module <TAB> superseder <TAB> superseded <TAB> kind
#
# Each block builds its own inputs, so TEST_FILTER is supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite
. "$SKILL_DIR/scripts/lib/supersede-edges.sh"

# se_setup <name> — a fresh workspace; sets WS/ORDER/LIST/SNAP/EDGE globals.
se_setup() {
  WS="$SANDBOX/$1"; mkdir -p "$WS/snap"
  ORDER="$WS/order.tsv"; LIST="$WS/list.tsv"; SNAP="$WS/snap"; EDGE="$WS/edges.tsv"
  : > "$ORDER"; : > "$LIST"; : > "$EDGE"
}
# se_file <module> <stem> <kind> <supersedes-value> — register a collected file
# (adds to LIST, to ORDER when kind=added) and write its snapshot body.
se_file() {
  local mod="$1" stem="$2" kind="$3" sup="${4:-}"
  printf '%s\t%s\t%s\n' "$mod" "$stem" "$kind" >> "$LIST"
  [[ "$kind" = added ]] && printf '%s\t%s\n' "$mod" "$stem" >> "$ORDER"
  { printf '# %s\n\nintent: x\n' "$stem"
    [[ -n "$sup" ]] && printf 'supersedes: %s\n' "$sup"
    printf 'verify: y\n\n## Details\nd\n'
  } > "$SNAP/$stem.md"
  return 0
}
# edge_has <module> <superseder> <superseded> <kind>
edge_has() { grep -qF "$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")" "$EDGE"; }

# ---------------------------------------------------------------------------
if t "a backward in-range declaration emits an enforceable added-list edge"; then
se_setup backward
se_file m 20260101T000000-old added ''
se_file m 20260201T000000-new added 20260101T000000-old
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
expect "the backward edge is emitted" edge_has m 20260201T000000-new 20260101T000000-old added
expect "exactly one row emitted" test "$(wc -l < "$EDGE")" -eq 1
fi

# ---------------------------------------------------------------------------
if t "a forward edge (target lands later in apply order) is WARNed and dropped"; then
se_setup forward
se_file m 20260101T000000-early added 20260201T000000-late   # early supersedes a LATER file
se_file m 20260201T000000-late  added ''
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
refute "no forward edge is emitted" edge_has m 20260101T000000-early 20260201T000000-late added
expect "the forward edge is WARNed" grep -qi 'forward edge' "$WS/log"
expect "no rows at all" test "$(wc -l < "$EDGE")" -eq 0
fi

# ---------------------------------------------------------------------------
if t "a cross-module declaration is WARNed and drops no row"; then
se_setup crossmod
se_file api     20260101T000000-old added ''
se_file toolkit 20260201T000000-new added 20260101T000000-old   # toolkit file names an api stem
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
refute "no cross-module edge is emitted" edge_has toolkit 20260201T000000-new 20260101T000000-old added
expect "the cross-module violation is WARNed" grep -qi 'across modules' "$WS/log"
expect "no rows at all" test "$(wc -l < "$EDGE")" -eq 0
fi

# ---------------------------------------------------------------------------
if t "an out-of-range target (never collected) emits an informational row"; then
se_setup outrange
se_file m 20260201T000000-new added 20250101T000000-ancient   # ancient was never collected
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
expect "the out-of-range row is emitted" edge_has m 20260201T000000-new 20250101T000000-ancient added
refute "no cross-module WARN for an absent target" grep -qi 'across modules' "$WS/log"
fi

# ---------------------------------------------------------------------------
if t "a self-supersede is WARNed and drops no row"; then
se_setup selfref
se_file m 20260201T000000-new added 20260201T000000-new
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
expect "no rows at all" test "$(wc -l < "$EDGE")" -eq 0
expect "the self-reference is WARNed" grep -qi 'names the file itself' "$WS/log"
fi

# ---------------------------------------------------------------------------
if t "multiple space-separated stems each become an edge"; then
se_setup multistem
se_file m 20260101T000000-old1 added ''
se_file m 20260201T000000-old2 added ''
se_file m 20260301T000000-new  added '20260101T000000-old1 20260201T000000-old2'
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
expect "first stem becomes an edge"  edge_has m 20260301T000000-new 20260101T000000-old1 added
expect "second stem becomes an edge" edge_has m 20260301T000000-new 20260201T000000-old2 added
expect "exactly two rows" test "$(wc -l < "$EDGE")" -eq 2
fi

# ---------------------------------------------------------------------------
if t "same basename in two modules: the declaring module's backward edge is emitted (not dropped as cross-module)"; then
se_setup samebasename
# The identical stem exists in module b (seen first) AND module a. A stem-only
# module map would key it to b, then misread a's own backward edge as cross-module
# and drop it. Membership is per module+stem, so a's edge must survive.
se_file b 20260101T000000-shared added ''
se_file a 20260101T000000-shared added ''
se_file a 20260201T000000-new    added 20260101T000000-shared
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
expect "the same-module (a) backward edge is emitted" edge_has a 20260201T000000-new 20260101T000000-shared added
expect "exactly one row emitted" test "$(wc -l < "$EDGE")" -eq 1
refute "no cross-module WARN for a same-module target" grep -qi 'across modules' "$WS/log"
fi

# ---------------------------------------------------------------------------
if t "a modified-list superseder emits its edge with kind=modified"; then
se_setup modkind
se_file m 20260101T000000-old added ''
se_file m 20260201T000000-amended modified 20260101T000000-old
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
expect "the modified-list edge carries kind=modified" edge_has m 20260201T000000-amended 20260101T000000-old modified
fi

# ---------------------------------------------------------------------------
if t "a failed classification pass returns non-zero and REMOVES the edge file"; then
# The caller truncates the edge file before the call, so a swallowed awk failure
# would leave a present-and-empty file that reads downstream as "no supersedes in
# range" — the false clean the feature exists to prevent. The helper must return
# non-zero and take the edge file with it (absent trips the gate's exit 2).
se_setup awkfail
se_file m 20260101T000000-old added ''
se_file m 20260201T000000-new added 20260101T000000-old
EDGE="$WS/no-such-dir/edges.tsv"          # awk cannot open this for append
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
RC=$?
if [[ "$RC" -ne 0 ]]; then pass "a failed classification pass returns non-zero"; else fail "a failed classification pass should return non-zero (rc=0)"; fi
refute "no edge file is left behind" test -e "$EDGE"
expect "the failure is a FAIL line naming the edge file" grep -q "FAIL:.*edges.tsv" "$WS/log"
fi

# ---------------------------------------------------------------------------
if t "a failed temp file returns non-zero and REMOVES the (caller-truncated) edge file"; then
se_setup tmpfail
se_file m 20260101T000000-old added ''
se_file m 20260201T000000-new added 20260101T000000-old
: > "$EDGE"                                # the caller's truncate
TMPDIR="$WS/no-such-tmpdir" supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
RC=$?
if [[ "$RC" -ne 0 ]]; then pass "a failed temp file returns non-zero"; else fail "a failed temp file should return non-zero (rc=0)"; fi
refute "the caller-truncated edge file is removed, not left empty" test -e "$EDGE"
expect "the failure is a FAIL line" grep -q '^FAIL:' "$WS/log"
fi

# ---------------------------------------------------------------------------
# The header ends at the first `## ` heading. A column-0 "supersedes: …" sentence
# in the free-form body is prose, not a declaration — an edge is a skip that rides
# without per-item confirmation, so a body sentence must never manufacture one.
if t "a `supersedes:` line inside the ## Details body is NOT a declaration"; then
se_setup body-prose
se_file m 20260101T000000-old added ''
se_file m 20260201T000000-new added ''
printf 'supersedes: see 20260101T000000-old for context\n' >> "$SNAP/20260201T000000-new.md"
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
expect "no rows at all" test "$(wc -l < "$EDGE")" -eq 0
# Control: the same value in the HEADER is an edge.
se_setup body-prose-control
se_file m 20260101T000000-old added ''
se_file m 20260201T000000-new added 20260101T000000-old
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
expect "control: the header declaration is emitted" edge_has m 20260201T000000-new 20260101T000000-old added
fi

# ---------------------------------------------------------------------------
# A token that is not a bare <timestamp>-<slug> stem (comma-joined list, path) is
# WARNed and dropped — not emitted as an "out of range" row that would read as a
# legitimately-absent target.
if t "a malformed supersedes token is WARNed and dropped, never emitted as out-of-range"; then
se_setup malformed
se_file m 20260101T000000-old added ''
se_file m 20260102T000000-older added ''
se_file m 20260201T000000-new added '20260101T000000-old, 20260102T000000-older'
supersede_emit "$ORDER" "$LIST" "$SNAP" "$EDGE" 2> "$WS/log"
RC=$?
expect "emission still succeeds (rc 0)" test "$RC" -eq 0
expect "the comma-suffixed token is WARNed by value" grep -q "WARN:.*'20260101T000000-old,'" "$WS/log"
expect "the WARN says what a stem looks like" grep -qi 'not a <timestamp>-<slug> stem' "$WS/log"
refute "no row carries the comma-suffixed token" grep -q '20260101T000000-old,' "$EDGE"
expect "the well-formed second token is still an edge" edge_has m 20260201T000000-new 20260102T000000-older added
expect "exactly one row" test "$(wc -l < "$EDGE")" -eq 1
fi

finish_suite
