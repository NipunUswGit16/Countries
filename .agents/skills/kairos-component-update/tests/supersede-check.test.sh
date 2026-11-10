#!/usr/bin/env bash
# supersede-check.test.sh — tests for scripts/supersede-check.sh
#
# The supersede gate runs beside plan-completeness.sh / followup-completeness.sh
# before PLAN.md is committed. It recomputes the retired set (edge files +
# PLAN.md's apply set → transitive closure) and fails the run when an in-range
# slug retired by an applied superseder is not dispositioned skip-with-link or
# apply-with-override.
#
# Each block builds its own $RUN, so TEST_FILTER is supported here (unlike the
# shared-fixture collector suites).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

SC="$SKILL_DIR/scripts/supersede-check.sh"

# mk_run <name> [stem...] — a fresh $RUN seeded so the presence checks pass by
# default: a template added-list (the witness) holding one `.kairos-updates/<stem>.md`
# path per stem given, and an empty template edge file. Prints the path.
# The witness matters: the gate enforces an edge only when its TARGET stem is in
# the declaring source's own collected lists, so a fixture that declares template
# edges must also seed the template witness with the stems those edges name.
mk_run() {
  local r="$SANDBOX/$1"; shift
  mkdir -p "$r"
  : > "$r/upgrades-added.txt"
  local st; for st in "$@"; do printf '.kairos-updates/%s.md\n' "$st" >> "$r/upgrades-added.txt"; done
  : > "$r/supersede-edges.tsv"
  printf '%s\n' "$r"
}

# plan_head / plan_row helpers keep the fixtures readable.
plan_open() { printf '## Upgrade-file Dispositions\n\n| Upgrade-file | Disposition | Task / Reason |\n|---|---|---|\n'; }
plan_row()  { printf '| `%s` | %s | %s |\n' "$1" "$2" "$3"; }

# ---------------------------------------------------------------------------
if t "supersede-check passes cleanly when there are no edges"; then
R=$(mk_run clean)
{ plan_open; plan_row 20260101T000000-alpha apply T01; } > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/clean.log"
expect "no edges → exit 0" test $? -eq 0
expect "a passing gate says so on stderr" grep -q '^OK:' "$SANDBOX/clean.log"
fi

# ---------------------------------------------------------------------------
if t "an applied superseder + plain-apply superseded slug fails (exit 1) naming the slug"; then
R=$(mk_run plain-apply 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old apply T01
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/plain-apply.log"
RC=$?
if [[ "$RC" -eq 1 ]]; then pass "plain-apply of a retired slug exits 1"; else fail "plain-apply of a retired slug should exit 1 (rc=$RC)"; fi
expect "the failure names the retired slug" grep -q '20260101T000000-old' "$SANDBOX/plain-apply.log"
refute "a failing gate never claims OK" grep -q '^OK:' "$SANDBOX/plain-apply.log"
fi

# ---------------------------------------------------------------------------
if t "a skip whose reason links the superseder passes (exit 0)"; then
R=$(mk_run skip-link 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old skip 'superseded by 20260201T000000-new'
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/skip-link.log"
expect "skip-with-link → exit 0" test $? -eq 0
fi

# ---------------------------------------------------------------------------
if t "a force-applied superseded slug with an override: reason passes (exit 0)"; then
R=$(mk_run override 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old apply 'override: still need the old rule here'
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/override.log"
expect "apply-with-override → exit 0" test $? -eq 0
fi

# ---------------------------------------------------------------------------
if t "an absent edge file whose added-list witness is present exits 2"; then
R=$(mk_run exit2)
# common witness present, but its edge file was never written by the collector
: > "$R/common-upgrades-added.txt"
rm -f "$R/common-supersede-edges.tsv"
{ plan_open; plan_row 20260101T000000-alpha apply T01; } > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" > "$SANDBOX/exit2.out" 2> "$SANDBOX/exit2.log"
RC=$?
if [[ "$RC" -eq 2 ]]; then pass "absent edge file with present witness → exit 2"; else fail "absent edge file should exit 2 (rc=$RC)"; fi
refute "the exit-2 run never claims OK" grep -q '^OK:' "$SANDBOX/exit2.log"
expect "the exit-2 failure names the missing edge file" grep -q 'common-supersede-edges.tsv' "$SANDBOX/exit2.log"
fi

# ---------------------------------------------------------------------------
if t "a surviving deferred placeholder row is a named failure (exit 1)"; then
R=$(mk_run deferred 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old deferred 'waits on 20260201T000000-new'
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/deferred.log"
RC=$?
if [[ "$RC" -eq 1 ]]; then pass "a deferred placeholder exits 1"; else fail "a deferred placeholder should exit 1 (rc=$RC)"; fi
expect "the deferred failure names the slug" grep -q '20260101T000000-old' "$SANDBOX/deferred.log"
fi

# ---------------------------------------------------------------------------
if t "a surviving 'deferred (waits on <stem>)' cell fails even when the superseder is DECLINED (exit 1)"; then
# The disposition cell carries a trailing note, so an exact `== deferred` match
# would miss it and the gate would ship a placeholder silently. The superseder is
# DECLINED here (a plain skip, edge never fires), which is exactly the case where
# an exact match would let the leftover deferral escape: the ^deferred prefix
# match must still catch it.
R=$(mk_run deferred-note 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old 'deferred (waits on 20260201T000000-new)' '—'
  plan_row 20260201T000000-new skip 'user: not adopting feature new'
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/deferred-note.log"
RC=$?
if [[ "$RC" -eq 1 ]]; then pass "a non-literal deferred cell still exits 1"; else fail "a 'deferred (waits on …)' cell should exit 1 (rc=$RC)"; fi
expect "the failure names the still-deferred slug" grep -q '20260101T000000-old' "$SANDBOX/deferred-note.log"
fi

# ---------------------------------------------------------------------------
if t "a skip whose reason wraps the stem in backticks still passes (exit 0)"; then
# A planner may write the reason as `superseded by \`<stem>\``; the gate strips
# backticks from the reason before matching, so the link is still recognized.
R=$(mk_run backtick 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old skip 'superseded by `20260201T000000-new`'
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/backtick.log"
expect "backticked-stem skip reason → exit 0" test $? -eq 0
fi

# ---------------------------------------------------------------------------
if t "a modified-list superseder is advisory — its edge is not enforced"; then
R=$(mk_run modified 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tmodified\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old apply T01
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/modified.log"
expect "modified-list edge → not enforced → exit 0" test $? -eq 0
fi

# ---------------------------------------------------------------------------
if t "a transitive chain retires the whole line (C applied → B and A both skipped)"; then
R=$(mk_run transitive 20260101T000000-a 20260201T000000-b 20260301T000000-c)
{ printf 'template\t20260301T000000-c\t20260201T000000-b\tadded\n'
  printf 'template\t20260201T000000-b\t20260101T000000-a\tadded\n'
} > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-a skip 'superseded by 20260201T000000-b'
  plan_row 20260201T000000-b skip 'superseded by 20260301T000000-c'
  plan_row 20260301T000000-c apply T03
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/transitive.log"
expect "the full retired chain skipped-with-link → exit 0" test $? -eq 0

# and if the oldest is left plain-apply, the transitive retirement is enforced
{ plan_open
  plan_row 20260101T000000-a apply T01
  plan_row 20260201T000000-b skip 'superseded by 20260301T000000-c'
  plan_row 20260301T000000-c apply T03
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/transitive-bad.log"
RC=$?
if [[ "$RC" -eq 1 ]]; then pass "an unskipped transitive tail exits 1"; else fail "transitive tail should exit 1 (rc=$RC)"; fi
expect "the transitive failure names the tail slug" grep -q '20260101T000000-a' "$SANDBOX/transitive-bad.log"
fi

# ---------------------------------------------------------------------------
if t "a declined superseder does not fire its edge (target needs no skip)"; then
R=$(mk_run broken 20260101T000000-a 20260201T000000-b)
printf 'template\t20260201T000000-b\t20260101T000000-a\tadded\n' > "$R/supersede-edges.tsv"
# B supersedes A, but B is DECLINED on its own merits (a plain skip, not a
# supersede): declining "do X" must not erase the still-valid "don't do X". The
# edge is dead at B, so A is judged normally and may apply.
{ plan_open
  plan_row 20260101T000000-a apply T01
  plan_row 20260201T000000-b skip 'user: not adopting feature B'
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/broken.log"
expect "declined superseder → edge does not fire → exit 0" test $? -eq 0
fi

# ---------------------------------------------------------------------------
if t "a transitive chain is dead at a declined link"; then
R=$(mk_run broken-mid 20260101T000000-a 20260201T000000-b 20260301T000000-c)
{ printf 'template\t20260301T000000-c\t20260201T000000-b\tadded\n'
  printf 'template\t20260201T000000-b\t20260101T000000-a\tadded\n'
} > "$R/supersede-edges.tsv"
# C declined, so B is judged on its own and here also declined; the chain never
# reaches A, which applies normally.
{ plan_open
  plan_row 20260101T000000-a apply T01
  plan_row 20260201T000000-b skip 'user: not adopting feature B'
  plan_row 20260301T000000-c skip 'user: not adopting feature C'
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/broken-mid.log"
expect "dead-at-declined-link → exit 0" test $? -eq 0
fi

# ---------------------------------------------------------------------------
if t "a tombstone superseder counts as apply for edge-firing"; then
R=$(mk_run tombstone 20260101T000000-old 20260201T000000-retract)
printf 'template\t20260201T000000-retract\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
# tombstone disposition is `apply (tombstone)` — no Phase 7 task, but it fires
# the edge, so the old rule must still be retired.
{ plan_open
  plan_row 20260101T000000-old apply T01
  plan_row '20260201T000000-retract' 'apply (tombstone)' '—'
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/tombstone-bad.log"
RC=$?
if [[ "$RC" -eq 1 ]]; then pass "tombstone fires the edge → unskipped old exits 1"; else fail "tombstone edge should fire (rc=$RC)"; fi

{ plan_open
  plan_row 20260101T000000-old skip 'superseded by 20260201T000000-retract'
  plan_row '20260201T000000-retract' 'apply (tombstone)' '—'
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/tombstone-ok.log"
expect "tombstone + skip-with-link → exit 0" test $? -eq 0
fi

# ---------------------------------------------------------------------------
if t "an out-of-range superseded target (absent from the plan) is not enforced"; then
R=$(mk_run outofrange 20260201T000000-new)
printf 'template\t20260201T000000-new\t20250101T000000-ancient\tadded\n' > "$R/supersede-edges.tsv"
# the ancient target is out of range — it never appears in the plan; the gate
# treats it as informational, not a violation.
{ plan_open; plan_row 20260201T000000-new apply T02; } > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/outofrange.log"
expect "out-of-range target → exit 0" test $? -eq 0
fi

# ---------------------------------------------------------------------------
if t "one superseder retiring two stems enforces each target independently"; then
R=$(mk_run multistem 20260101T000000-old1 20260201T000000-old2 20260301T000000-new)
{ printf 'template\t20260301T000000-new\t20260101T000000-old1\tadded\n'
  printf 'template\t20260301T000000-new\t20260201T000000-old2\tadded\n'
} > "$R/supersede-edges.tsv"
# old1 is retired properly; old2 is left plain-apply — only old2 must be named.
{ plan_open
  plan_row 20260101T000000-old1 skip 'superseded by 20260301T000000-new'
  plan_row 20260201T000000-old2 apply T02
  plan_row 20260301T000000-new apply T03
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/multistem.log"
RC=$?
if [[ "$RC" -eq 1 ]]; then pass "one unretired target of a multi-stem superseder exits 1"; else fail "multi-stem should exit 1 (rc=$RC)"; fi
expect "the failure names the unretired stem" grep -q '20260201T000000-old2' "$SANDBOX/multistem.log"
refute "the failure does not name the properly-retired stem" grep -q 'UNRETIRED: 20260101T000000-old1' "$SANDBOX/multistem.log"
fi

# ---------------------------------------------------------------------------
if t "a cross-source edge (target collected by ANOTHER source) is WARNed and not enforced"; then
# The template shipped `old`; a common module's `new` declares `supersedes: old`.
# collect-common.sh cannot see the template list, so it emits the row as "out of
# range" (informational). PLAN.md is the union of all sources and carries `old`,
# so a stem-only gate would enforce the edge and let a common author retire a
# template migration with a skip that rides without confirmation. The gate must
# re-check the target against the DECLARING source's own witness and drop it.
R=$(mk_run cross-source 20260101T000000-old)
: > "$R/common-upgrades-added.txt"
printf '.kairos-updates/api/20260201T000000-new.md\n' > "$R/common-upgrades-added.txt"
printf 'api\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/common-supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old apply T01
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/cross-source.log"
expect "cross-source edge → not enforced → exit 0" test $? -eq 0
expect "the cross-source edge is WARNed by name" grep -q 'WARN:.*20260201T000000-new.*20260101T000000-old' "$SANDBOX/cross-source.log"
expect "the WARN says it is a cross-source no-op" grep -qi 'cross-source' "$SANDBOX/cross-source.log"
expect "the gate still reports OK" grep -q '^OK:' "$SANDBOX/cross-source.log"

# Positive control: the identical edge declared by the source that DID collect
# the target (template → template) is enforced.
R=$(mk_run cross-source-ctl 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old apply T01
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/cross-source-ctl.log"
RC=$?
if [[ "$RC" -eq 1 ]]; then pass "same-source control edge is enforced (exit 1)"; else fail "same-source control edge should exit 1 (rc=$RC)"; fi
fi

# ---------------------------------------------------------------------------
if t "a target on the declaring source's MODIFIED list still counts as same-source"; then
# The target was amended (not added) in range: it is in upgrades-modified.txt,
# not upgrades-added.txt. The helper emits such an edge as advisory-with-kind-added
# and the plan carries the modified slug, so the gate must enforce it — the
# same-source check reads added ∪ modified, not added alone.
R=$(mk_run modified-target 20260201T000000-new)
printf '.kairos-updates/20260101T000000-old.md\n' > "$R/upgrades-modified.txt"
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old apply T01
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/modified-target.log"
RC=$?
if [[ "$RC" -eq 1 ]]; then pass "modified-list target is same-source → enforced (exit 1)"; else fail "modified-list target should be enforced (rc=$RC)"; fi
refute "no cross-source WARN for a modified-list target" grep -qi 'cross-source' "$SANDBOX/modified-target.log"
fi

# ---------------------------------------------------------------------------
if t "an unreadable PLAN.md is exit 2, never OK (the disposition parse is checked)"; then
# Under `set -u` alone the awk that fills the disposition file could fail and
# leave it empty: zero present slugs → every retired target "out of range" →
# OK over an unhonored edge. The parse must be checked and refuse (exit 2).
if [[ "$(id -u)" -eq 0 ]]; then
  # Root bypasses chmod 000 (DAC), so the plan stays readable and the assertion
  # would test nothing. Same skip-pass posture as collect-common.test.sh.
  pass "unreadable PLAN.md case skipped (running as root)"
else
  R=$(mk_run noread-plan 20260101T000000-old 20260201T000000-new)
  printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
  { plan_open
    plan_row 20260101T000000-old apply T01
    plan_row 20260201T000000-new apply T02
  } > "$R/PLAN.md"
  chmod 000 "$R/PLAN.md"
  RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/noread-plan.log"
  RC=$?
  chmod 644 "$R/PLAN.md"
  if [[ "$RC" -eq 2 ]]; then pass "unreadable plan → exit 2"; else fail "unreadable plan should exit 2 (rc=$RC)"; fi
  refute "an unreadable plan never claims OK" grep -q '^OK:' "$SANDBOX/noread-plan.log"
  expect "the refusal says the gate cannot run" grep -qi 'cannot run' "$SANDBOX/noread-plan.log"
fi
fi

# ---------------------------------------------------------------------------
if t "a failed temp file is exit 2, never OK (mktemp is checked)"; then
R=$(mk_run notmp 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old apply T01
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
TMPDIR="$R/no-such-tmpdir" RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/notmp.log"
RC=$?
if [[ "$RC" -eq 2 ]]; then pass "unusable TMPDIR → exit 2"; else fail "unusable TMPDIR should exit 2 (rc=$RC)"; fi
refute "a failed temp file never claims OK" grep -q '^OK:' "$SANDBOX/notmp.log"
fi

# ---------------------------------------------------------------------------
if t "the skip-reason link is a bounded stem match, not a substring test"; then
# Retirer is `new`; the reason names `new2` (a different stem that merely starts
# with the same characters). A substring test would accept it. It must not.
R=$(mk_run bounded 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-old skip 'superseded by 20260201T000000-new2'
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/bounded.log"
RC=$?
if [[ "$RC" -eq 1 ]]; then pass "a reason naming a longer stem does not satisfy the link (exit 1)"; else fail "'superseded by new2' must not satisfy retirer 'new' (rc=$RC)"; fi
expect "the failure names the slug" grep -q 'UNRETIRED: 20260101T000000-old' "$SANDBOX/bounded.log"

# Control: the exact stem followed by a trailing note still passes (boundary is
# a non-stem character or end of line, not "end of cell").
{ plan_open
  plan_row 20260101T000000-old skip 'superseded by 20260201T000000-new (edge fired)'
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/bounded-ok.log"
expect "the exact stem with a trailing note still passes (exit 0)" test $? -eq 0
fi

# ---------------------------------------------------------------------------
if t "a stem collected by two sources is WARNed by name (advisory)"; then
# The template and a common module both shipped `20260101T000000-shared`. PLAN.md
# keys on the bare stem, so the two collapse to one row; the gate names it so the
# collision is not discovered from a wrong skip. The verdict is unchanged.
R=$(mk_run collision 20260101T000000-shared 20260201T000000-new)
printf '.kairos-updates/api/20260101T000000-shared.md\n' > "$R/common-upgrades-added.txt"
: > "$R/common-supersede-edges.tsv"
{ plan_open
  plan_row 20260101T000000-shared apply T01
  plan_row 20260201T000000-new apply T02
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/collision.log"
expect "a collision alone does not fail the gate (exit 0)" test $? -eq 0
expect "the collision is WARNed by stem" grep -q 'WARN: stem 20260101T000000-shared' "$SANDBOX/collision.log"
expect "the WARN names both sources" bash -c "grep 'WARN: stem 20260101T000000-shared' '$SANDBOX/collision.log' | grep -q 'common' && grep 'WARN: stem 20260101T000000-shared' '$SANDBOX/collision.log' | grep -q 'template'"
refute "a stem in one source only is not WARNed" grep -q 'WARN: stem 20260201T000000-new' "$SANDBOX/collision.log"
fi

# ---------------------------------------------------------------------------
# `skip` is matched by PREFIX like `^apply`: the planner writes parenthesised
# cells for the sibling shapes (`skip (superseded — undeclared)`), so a declared
# retirement written `skip (superseded)` with a correct linked reason must pass.
if t "a parenthesised skip cell with a linked reason passes (prefix match)"; then
R=$(mk_run paren-skip 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260201T000000-new apply T01
  plan_row 20260101T000000-old 'skip (superseded)' 'superseded by 20260201T000000-new'
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/paren-skip.log"
expect "skip (superseded) + link → exit 0" test $? -eq 0
fi

# ---------------------------------------------------------------------------
# The reason is the REST OF THE ROW, not the fourth pipe-split cell: a `|` (or a
# markdown-escaped `\|`) inside a free-text reason must not truncate it into a
# false UNRETIRED.
if t "a pipe inside the reason column does not truncate the link"; then
R=$(mk_run pipe-reason 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
{ plan_open
  plan_row 20260201T000000-new apply T01
  plan_row 20260101T000000-old skip 'user: a \| b; superseded by 20260201T000000-new'
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/pipe-reason.log"
expect "pipe in reason, link intact → exit 0" test $? -eq 0
# Control: a raw pipe before a reason that has NO link still fails.
{ plan_open
  plan_row 20260201T000000-new apply T01
  plan_row 20260101T000000-old skip 'user: a | b'
} > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/pipe-reason-bad.log"
RC=$?
if [[ "$RC" -eq 1 ]]; then pass "control: pipe in an unlinked reason still exits 1"; else fail "control: an unlinked reason should exit 1 (rc=$RC)"; fi
fi

# ---------------------------------------------------------------------------
# Zero parsed disposition rows while a witness list names upgrade-files is a table
# the parser could not find — every retired target would look out of range and
# pass. The gate refuses (exit 2) on its own, without relying on
# plan-completeness.sh having run first.
if t "no parseable Dispositions table + a non-empty witness → exit 2, not a pass"; then
R=$(mk_run no-table 20260101T000000-old 20260201T000000-new)
printf 'template\t20260201T000000-new\t20260101T000000-old\tadded\n' > "$R/supersede-edges.tsv"
printf '## Tasks\n\nnothing here\n' > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/no-table.log"
RC=$?
if [[ "$RC" -eq 2 ]]; then pass "missing table with a witness exits 2"; else fail "missing table with a witness should exit 2 (rc=$RC)"; fi
expect "the refusal names the table and the witness" bash -c "grep -q 'Upgrade-file Dispositions' '$SANDBOX/no-table.log' && grep -q 'upgrades-added.txt' '$SANDBOX/no-table.log'"
refute "no OK line" grep -q '^OK:' "$SANDBOX/no-table.log"
# Control: an empty witness (range added nothing) with no table is a clean pass.
R=$(mk_run no-table-empty)
printf '## Tasks\n\nnothing here\n' > "$R/PLAN.md"
RUN=$R PLAN=$R/PLAN.md "$SC" 2> "$SANDBOX/no-table-empty.log"
expect "control: empty witness + no table → exit 0" test $? -eq 0
fi

finish_suite
