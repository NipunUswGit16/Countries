#!/usr/bin/env bash
# followup-completeness.test.sh — tests for scripts/followup-completeness.sh
# TEST_FILTER refused (single sequential fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in followup-completeness.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

# Every fixture below is a run that COMPLETED Phase 5, so its run dir carries the
# two witnesses the gate requires before it derives anything:
#   * $RUN/clean-merged.txt — structural-merge.sh truncates it unconditionally
#     (empty when nothing clean-merged);
#   * $RUN/producer-idempotence-postmerge.tsv — producer-idempotence.sh truncates it
#     unconditionally under the POSTMERGE gate label (empty when no producer ran).
# Without either the gate refuses with exit 2 instead of answering — both arms have
# their own blocks at the end of this file, and that is why these lines are not
# incidental setup.
phase5_ran() {
  mkdir -p "$1" && : > "$1/clean-merged.txt" && : > "$1/producer-idempotence-postmerge.tsv"
}

if t "followup-completeness.sh enforces the post-merge follow-up catalogue"; then
# Each trigger reads an artifact the run wrote; every triggered row must be
# dispositioned in PLAN.md or the plan does not pass. This turns load-bearing
# fixups from planner memory into mechanism.
FC=$SANDBOX/followup
FCRUN=$SANDBOX/followup-run          # run dir OUTSIDE the repo (would show untracked)
mkdir -p "$FC" "$FCRUN" && cd "$FC" && git init -q -b main
phase5_ran "$FCRUN"
# A doc that references a path the merge removed, and an import that references a
# renamed-away package directory. Identifiers are INVENTED.
printf 'The wibble config lives at legacy/sprocket.yaml — read it.\n' > README.txt
printf 'package main\n\nimport "example.com/mod/flangebox"\n' > main.go
# A SIBLING directory sharing the `wumbo` prefix, referenced as a path. `wumbo`
# renames away too; only `wumbo-api` survives in the tree, so an unanchored prefix
# grep manufactures a stale-ref follow-up for `wumbo` off its sibling's name.
printf 'config: wumbo-api/settings.yaml\n' > notes.txt
git add -A && git commit -qm init
echo "legacy/sprocket.yaml" > "$FCRUN/confirmed-deletes.txt"
printf 'flangebox/core.go -> gearbox/core.go\nwumbo/svc.go -> core/svc.go\nwumbo-api/x.go -> core/x.go\n' \
  > "$FCRUN/renamed.txt"
# A producer left a tracked artifact stale.
printf 'regenerate\tdirty-tracked\tmodified tracked artifact(s): schema.gen.go\n' > "$FCRUN/producer-idempotence-postmerge.tsv"
# A semantic layer skipped.
printf 'skip\t-\tburied-key\tno materialized target tree\n' > "$FCRUN/yaml-gate-postmerge.tsv"
FCS="$SKILL_DIR/scripts/followup-completeness.sh"

# no dispositions -> every triggered follow-up is MISSING, exit 1
cat > "$FCRUN/PLAN-empty.md" <<'EOF'
## Tasks
### T01: unrelated
EOF
RUN=$FCRUN PLAN=$FCRUN/PLAN-empty.md bash -c "cd '$FC' && RUN='$FCRUN' PLAN='$FCRUN/PLAN-empty.md' '$FCS'" > "$SANDBOX/fc-empty.out" 2> "$SANDBOX/fc-empty.log"
FC_EMPTY_RC=$?
if [[ "$FC_EMPTY_RC" -ne 0 ]]; then pass "a triggered follow-up with no disposition fails the plan"; else fail "follow-up catalogue passed with undispositioned triggers"; fi
expect "confirmed delete + surviving reference triggers a stale-ref follow-up" \
  grep -q 'MISSING: stale-ref:legacy/sprocket.yaml' "$SANDBOX/fc-empty.log"
expect "rename with a surviving reference to the old directory triggers a stale-ref follow-up" \
  grep -q 'MISSING: stale-ref:flangebox' "$SANDBOX/fc-empty.log"
expect "a stale committed generated artifact triggers a producer follow-up" \
  grep -q 'MISSING: producer:regenerate' "$SANDBOX/fc-empty.log"
expect "a skipped semantic layer triggers a skip-acknowledgment follow-up" \
  grep -q 'MISSING: skip:yaml-buried-key' "$SANDBOX/fc-empty.log"
expect "a renamed-away directory referenced as a path prefix still triggers" \
  grep -qx 'MISSING: stale-ref:wumbo-api' "$SANDBOX/fc-empty.log"
refute "a sibling sharing the prefix does not trigger the shorter directory" \
  grep -qx 'MISSING: stale-ref:wumbo' "$SANDBOX/fc-empty.log"

# a plan that disposes every triggered follow-up -> exit 0
cat > "$FCRUN/PLAN-full.md" <<'EOF'
## Follow-up Dispositions

| Follow-up | Disposition | Task / Reason |
|---|---|---|
| `stale-ref:legacy/sprocket.yaml` | task | T02 |
| `stale-ref:flangebox` | task | T03 |
| `stale-ref:wumbo-api` | task | T05 |
| `producer:regenerate` | task | T04 |
| `skip:yaml-buried-key` | acknowledged | no target tree in this environment |
EOF
RUN=$FCRUN PLAN=$FCRUN/PLAN-full.md bash -c "cd '$FC' && RUN='$FCRUN' PLAN='$FCRUN/PLAN-full.md' '$FCS'" > "$SANDBOX/fc-full.out" 2> "$SANDBOX/fc-full.log"
expect "a fully-dispositioned follow-up catalogue passes" test $? -eq 0

# a plan missing only the skip acknowledgment -> the honesty requirement has teeth
cat > "$FCRUN/PLAN-noskip.md" <<'EOF'
## Follow-up Dispositions

| Follow-up | Disposition | Task / Reason |
|---|---|---|
| `stale-ref:legacy/sprocket.yaml` | task | T02 |
| `stale-ref:flangebox` | task | T03 |
| `stale-ref:wumbo-api` | task | T05 |
| `producer:regenerate` | task | T04 |
EOF
RUN=$FCRUN PLAN=$FCRUN/PLAN-noskip.md bash -c "cd '$FC' && RUN='$FCRUN' PLAN='$FCRUN/PLAN-noskip.md' '$FCS'" > "$SANDBOX/fc-noskip.out" 2> "$SANDBOX/fc-noskip.log"
FC_NOSKIP_RC=$?
if [[ "$FC_NOSKIP_RC" -ne 0 ]]; then pass "a reported skip without acknowledgment fails the checklist"; else fail "skip without acknowledgment passed the checklist"; fi
expect "the missing acknowledgment names the skipped layer" \
  grep -q 'MISSING: skip:yaml-buried-key' "$SANDBOX/fc-noskip.log"

# nothing triggered -> clean pass (no false catalogue on a clean migration)
FCCLEAN=$SANDBOX/followup-clean; FCCLEANRUN=$SANDBOX/followup-clean-run
mkdir -p "$FCCLEAN" "$FCCLEANRUN" && ( cd "$FCCLEAN" && git init -q -b main && echo hi > a.txt && git add -A && git commit -qm i >/dev/null 2>&1 )
phase5_ran "$FCCLEANRUN"
printf 'skip\tchart\thelm-render\thelm ran\nfail\tx\tparse\tno\n' > "$FCCLEANRUN/nothing.tsv"   # not the postmerge label
bash -c "cd '$FCCLEAN' && RUN='$FCCLEANRUN' PLAN='$FCRUN/PLAN-empty.md' '$FCS'" > "$SANDBOX/fc-clean.out" 2>&1
expect "a migration with no triggers passes with no follow-up rows required" test $? -eq 0
expect "clean migration reports no follow-ups triggered" \
  grep -qi 'no follow-ups triggered' "$SANDBOX/fc-clean.out"
cd "$SANDBOX"

fi

if t "followup-completeness.sh derives removals from the resolution ledger"; then
# This block PINS the interface — and it closes a decision→artifact seam that had no
# gate row at all. A `kept-delete` verdict (the deletion wins; the template's change
# is dropped) removes a path, but reaches NONE of the four removal sources:
# deleted.txt is written only for the mechanical bucket, and confirmed-deletes.txt
# used to be hand-appended by the orchestrator at the dispatch site. A forgotten
# append silently dropped a stale-reference follow-up — the "decision collected and
# never enacted" shape, on the one instance that is mechanically derivable, because
# resolutions.tsv already carries the verdicts.
FR=$SANDBOX/fu-res; FRRUN=$SANDBOX/fu-res-run
mkdir -p "$FR" "$FRRUN" && cd "$FR" && git init -q -b main
phase5_ran "$FRRUN"
printf 'see legacy/gizmo.yaml for the wiring\n' > README.txt
printf 'and shards/only.yaml too\n' >> README.txt
printf 'plus both/ways.yaml\n' >> README.txt
printf 'and kept/custom.yaml stays\n' >> README.txt
git add -A && git commit -qm init
FCS="$SKILL_DIR/scripts/followup-completeness.sh"
LRS="$SKILL_DIR/scripts/log-resolution.sh"
cat > "$FRRUN/PLAN-empty.md" <<'EOF'
## Tasks
### T01: unrelated
EOF

# A kept-delete recorded ONLY in the concatenated ledger, with no
# confirmed-deletes.txt entry anywhere.
RUN=$FRRUN FILE=legacy/gizmo.yaml VERDICT=kept-delete REASON='deletion wins' bash "$LRS" >/dev/null 2>&1
bash -c "cd '$FR' && RUN='$FRRUN' PLAN='$FRRUN/PLAN-empty.md' '$FCS'" > /dev/null 2> "$SANDBOX/fu-res1.log"
expect "a kept-delete in resolutions.tsv yields a stale-ref follow-up with no confirmed-deletes.txt entry" \
  grep -qx 'MISSING: stale-ref:legacy/gizmo.yaml' "$SANDBOX/fu-res1.log"

# The assertion that keeps this off the prose concatenation: the same verdict
# present ONLY in a per-batch shard, with no concatenated file at all, must yield
# the follow-up too. $RUN/resolutions.tsv exists only after the orchestrator
# collects the shards — deriving from it alone would swap the deleted prose append
# for a dependency on a different prose step.
FRS=$SANDBOX/fu-shard; FRSRUN=$SANDBOX/fu-shard-run
mkdir -p "$FRS" "$FRSRUN" && ( cd "$FRS" && git init -q -b main \
  && printf 'see shards/only.yaml for the wiring\n' > README.txt && git add -A && git commit -qm init )
phase5_ran "$FRSRUN"
RUN=$FRSRUN SHARD=b1 FILE=shards/only.yaml VERDICT=kept-delete REASON='deletion wins' bash "$LRS" >/dev/null 2>&1
refute "the shard-only fixture really has no concatenated ledger" test -e "$FRSRUN/resolutions.tsv"
bash -c "cd '$FRS' && RUN='$FRSRUN' PLAN='$FRRUN/PLAN-empty.md' '$FCS'" > /dev/null 2> "$SANDBOX/fu-res2.log"
expect "a kept-delete present only in a resolutions.<slug>.tsv shard yields the follow-up too" \
  grep -qx 'MISSING: stale-ref:shards/only.yaml' "$SANDBOX/fu-res2.log"

# Union, de-duplicated: a path in both a shard and the concatenated file is ONE
# follow-up, and so is a path in both the ledger and confirmed-deletes.txt.
FRD=$SANDBOX/fu-dup; FRDRUN=$SANDBOX/fu-dup-run
mkdir -p "$FRD" "$FRDRUN" && ( cd "$FRD" && git init -q -b main \
  && printf 'plus both/ways.yaml and dual/source.yaml\n' > README.txt && git add -A && git commit -qm init )
phase5_ran "$FRDRUN"
RUN=$FRDRUN SHARD=b1 FILE=both/ways.yaml VERDICT=kept-delete REASON='deletion wins' bash "$LRS" >/dev/null 2>&1
RUN=$FRDRUN ACTION=collect bash "$LRS" >/dev/null 2>&1
RUN=$FRDRUN SHARD=b2 FILE=dual/source.yaml VERDICT=kept-delete REASON='deletion wins' bash "$LRS" >/dev/null 2>&1
RUN=$FRDRUN ACTION=collect bash "$LRS" >/dev/null 2>&1
echo "dual/source.yaml" > "$FRDRUN/confirmed-deletes.txt"
bash -c "cd '$FRD' && RUN='$FRDRUN' PLAN='$FRRUN/PLAN-empty.md' '$FCS'" > /dev/null 2> "$SANDBOX/fu-res3.log"
if [[ "$(grep -cx 'MISSING: stale-ref:both/ways.yaml' "$SANDBOX/fu-res3.log")" = 1 ]]; then
  pass "a path in both a shard and the concatenated ledger yields exactly one follow-up"
else
  fail "a path in both a shard and the concatenated ledger yields exactly one follow-up"
fi
if [[ "$(grep -cx 'MISSING: stale-ref:dual/source.yaml' "$SANDBOX/fu-res3.log")" = 1 ]]; then
  pass "a path in both the ledger and confirmed-deletes.txt yields exactly one follow-up"
else
  fail "a path in both the ledger and confirmed-deletes.txt yields exactly one follow-up"
fi

# A NON-removing verdict yields nothing: the filter is on the removal verdicts, not
# on the ledger's mere presence, or every resolved file would demand a follow-up.
FRK=$SANDBOX/fu-keep; FRKRUN=$SANDBOX/fu-keep-run
mkdir -p "$FRK" "$FRKRUN" && ( cd "$FRK" && git init -q -b main \
  && printf 'and kept/custom.yaml stays, see pkg/a.go\n' > README.txt && git add -A && git commit -qm init )
phase5_ran "$FRKRUN"
# REGION=1 satisfies the writer's required ordinal for the conflict-region verdicts
# (ours/theirs/merged/user); the bucket verdict forces it to '-'. Without it those
# rows would be refused and never written, making this a vacuous assertion.
for pair in kept/custom.yaml:kept-customization pkg/a.go:ours pkg/b.go:theirs pkg/c.go:merged pkg/d.go:user; do
  RUN=$FRKRUN SHARD=b1 FILE="${pair%%:*}" VERDICT="${pair##*:}" REASON='r' REGION=1 bash "$LRS" >/dev/null 2>&1
done
bash -c "cd '$FRK' && RUN='$FRKRUN' PLAN='$FRRUN/PLAN-empty.md' '$FCS'" > "$SANDBOX/fu-res4.out" 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "non-removing verdicts trigger no follow-up (exit 0)"; else fail "non-removing verdicts trigger no follow-up (rc=$rc)"; fi
refute "kept-customization is not treated as a removal" grep -q 'stale-ref:kept/custom.yaml' "$SANDBOX/fu-res4.out"
refute "ours/theirs/merged/user are not treated as removals" grep -q 'stale-ref:pkg/' "$SANDBOX/fu-res4.out"

cd "$SANDBOX"

fi

if t "followup-completeness.sh anchors a rename's dir check on the renamed-away directory"; then
# The dir-prefix trigger used to key off `dirname(old-path)` — the old path's
# PARENT — which is a different thing from the directory the rename took away:
#   * A single file moved OUT of a surviving directory (`internal/moved.go` ->
#     `pkg/moved.go`) named `internal` as "renamed away". `internal` is still full
#     of files, so the anchored prefix grep matched every reference to anything
#     under it and manufactured a MANDATORY, plan-blocking `stale-ref:internal`.
#   * A top-level directory rename (`web/` -> `frontend/`) whose files live one
#     level down named `web/src` and never `web` — so `COPY web/package.json` in a
#     Dockerfile, the exact reference class this trigger exists to catch, was not
#     checked at all.
# Both fixtures mirror what Phase 5 actually leaves on disk: structural-merge.sh
# removes the old paths with `rm -f`, so the INDEX still lists them and the old
# directory survives as an empty dir. Survival therefore has to be judged from the
# working tree, not from `git ls-files`.
FDN=$SANDBOX/fu-dirname; FDNRUN=$SANDBOX/fu-dirname-run
mkdir -p "$FDNRUN" "$FDN/internal/foo" && cd "$FDN" && git init -q -b main
phase5_ran "$FDNRUN"
printf 'package keep\n' > internal/keep.go
printf 'package foo\n' > internal/foo/x.go
printf 'package moved\n' > internal/moved.go
# References: one to a file under the SURVIVING `internal`, one to the genuinely
# renamed-away package dir `internal/foo` (as a Go import, no trailing slash).
printf 'wiring lives in internal/keep.go — read it\n' > doc.md
printf 'package main\n\nimport "example.com/m/internal/foo"\n' > main.go
git add -A && git commit -qm init
rm -f internal/moved.go internal/foo/x.go        # what structural-merge.sh does
FCS="$SKILL_DIR/scripts/followup-completeness.sh"
cat > "$FDNRUN/PLAN-empty.md" <<'EOF'
## Tasks
### T01: unrelated
EOF
printf 'internal/moved.go -> pkg/moved.go\ninternal/foo/x.go -> internal/bar/x.go\n' \
  > "$FDNRUN/renamed.txt"
bash -c "cd '$FDN' && RUN='$FDNRUN' PLAN='$FDNRUN/PLAN-empty.md' '$FCS'" \
  > "$SANDBOX/fu-dirname.out" 2> "$SANDBOX/fu-dirname.log"
refute "a file moved out of a SURVIVING directory does not flag that directory" \
  grep -q 'stale-ref:internal$' "$SANDBOX/fu-dirname.log"
expect "the genuinely renamed-away package directory is still flagged" \
  grep -qx 'MISSING: stale-ref:internal/foo' "$SANDBOX/fu-dirname.log"

# Top-level directory rename, files one level down: the trigger must be `web`.
FWB=$SANDBOX/fu-webdir; FWBRUN=$SANDBOX/fu-webdir-run
mkdir -p "$FWBRUN" "$FWB/web/src" && cd "$FWB" && git init -q -b main
phase5_ran "$FWBRUN"
printf 'console.log(1)\n' > web/src/app.js
printf '{"name":"x"}\n' > web/package.json
printf 'FROM node\nCOPY web/package.json ./\n' > Dockerfile
git add -A && git commit -qm init
rm -f web/src/app.js web/package.json           # renamed away by the merge
printf 'web/src/app.js -> frontend/src/app.js\n' > "$FWBRUN/renamed.txt"
bash -c "cd '$FWB' && RUN='$FWBRUN' PLAN='$FDNRUN/PLAN-empty.md' '$FCS'" \
  > "$SANDBOX/fu-webdir.out" 2> "$SANDBOX/fu-webdir.log"
expect "a top-level dir rename is checked as the renamed dir itself" \
  grep -qx 'MISSING: stale-ref:web' "$SANDBOX/fu-webdir.log"
refute "the immediate parent of the paired file is not flagged on its own" \
  grep -q 'stale-ref:web/src' "$SANDBOX/fu-webdir.log"

# A rename WITHIN one surviving directory triggers nothing: nothing was taken away.
FWI=$SANDBOX/fu-within; FWIRUN=$SANDBOX/fu-within-run
mkdir -p "$FWIRUN" "$FWI/pkg" && cd "$FWI" && git init -q -b main
phase5_ran "$FWIRUN"
printf 'package p\n' > pkg/old.go
printf 'package p\n' > pkg/stay.go
printf 'see pkg/stay.go\n' > doc.md
git add -A && git commit -qm init
rm -f pkg/old.go
printf 'pkg/old.go -> pkg/new.go\n' > "$FWIRUN/renamed.txt"
bash -c "cd '$FWI' && RUN='$FWIRUN' PLAN='$FDNRUN/PLAN-empty.md' '$FCS'" \
  > "$SANDBOX/fu-within.out" 2>&1
expect "a rename inside one surviving directory triggers no follow-up (exit 0)" test $? -eq 0
cd "$SANDBOX"

fi

if t "a dir-rename PAIR anchors its check on the paired directory itself"; then
# dir-rename-pairs.tsv is the one source whose `old` column can BE the
# renamed-away directory rather than a file inside it (a hand-corrected pairing —
# reference/structural-merge.md). The walk started at `dirname(old)`, so the only
# directory it ever judged for such a row was the PARENT; when the parent survives
# — the normal case, since a re-paired rename moves one subtree out of a directory
# full of others — the walk broke on the first probe and NOTHING went into
# RENAME_DIRS. The boundary-anchored refs_to_dir grep (the one that stops
# `openapi.yaml` false-matching an `api` dir) therefore never ran on the one path
# shape dir-pairs contribute: a stale reference to the renamed directory was left
# to the broader fixed-string removed-path grep, which cannot tell
# `internal/moved` from a surviving sibling `internal/moved-v2`.
FDP=$SANDBOX/fu-dirpair; FDPRUN=$SANDBOX/fu-dirpair-run
mkdir -p "$FDPRUN" "$FDP/internal/moved" "$FDP/internal/moved-v2" && cd "$FDP" && git init -q -b main
phase5_ran "$FDPRUN"
printf 'package keep\n' > internal/keep.go               # `internal` SURVIVES
printf 'package moved\n' > internal/moved/x.go
printf 'package movedv2\n' > internal/moved-v2/y.go      # the surviving sibling
printf 'package main\n\nimport "example.com/m/internal/moved/x"\n' > main.go
git add -A && git commit -qm init
rm -f internal/moved/x.go                                # what structural-merge.sh does
FCS="$SKILL_DIR/scripts/followup-completeness.sh"
cat > "$FDPRUN/PLAN-empty.md" <<'EOF'
## Tasks
### T01: unrelated
EOF
printf 'internal/moved\tpkg/moved\n' > "$FDPRUN/dir-rename-pairs.tsv"
bash -c "cd '$FDP' && RUN='$FDPRUN' PLAN='$FDPRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-dirpair.log"
expect "the paired directory is judged as a renamed-away dir, not just as a removed path" \
  grep -q "renamed-away directory 'internal/moved' still referenced" "$SANDBOX/fu-dirpair.log"
expect "the surviving parent is NOT flagged (the walk still stops at content)" \
  bash -c "! grep -q \"directory 'internal' still referenced\" '$SANDBOX/fu-dirpair.log'"
expect "the follow-up is still keyed on the path, so one disposition covers it" \
  grep -qx 'MISSING: stale-ref:internal/moved' "$SANDBOX/fu-dirpair.log"
if [[ "$(grep -cx 'MISSING: stale-ref:internal/moved' "$SANDBOX/fu-dirpair.log")" = 1 ]]; then
  pass "two derivations of one path yield ONE MISSING line (one key, one disposition)"
else
  fail "got $(grep -cx 'MISSING: stale-ref:internal/moved' "$SANDBOX/fu-dirpair.log") MISSING lines for one key (want 1)"
fi
# The old path itself is still a removal: the literal-path grep must keep seeing it.
printf 'and internal/moved is named here too\n' >> main.go
bash -c "cd '$FDP' && RUN='$FDPRUN' PLAN='$FDPRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-dirpair-rem.log"
expect "the paired old path is still reported as a removed path (no reference loss)" \
  grep -q "removed path 'internal/moved' still referenced" "$SANDBOX/fu-dirpair-rem.log"

# The sibling shape, isolated: the ONLY reference in the tree is to the SURVIVING
# `internal/moved-v2`. The anchored check correctly declines it. The fixed-string
# removed-path grep still matches `internal/moved` inside `internal/moved-v2` and
# manufactures the row — pinned here as the residual, so a later change to that
# grep is a deliberate one and not a surprise.
FDS2=$SANDBOX/fu-dirpair-sib; FDS2RUN=$SANDBOX/fu-dirpair-sib-run
mkdir -p "$FDS2RUN" "$FDS2/internal/moved" "$FDS2/internal/moved-v2" && cd "$FDS2" && git init -q -b main
phase5_ran "$FDS2RUN"
printf 'package keep\n' > internal/keep.go
printf 'package moved\n' > internal/moved/x.go
printf 'package movedv2\n' > internal/moved-v2/y.go
printf 'package main\n\nimport "example.com/m/internal/moved-v2/y"\n' > main.go
git add -A && git commit -qm init
rm -f internal/moved/x.go
printf 'internal/moved\tpkg/moved\n' > "$FDS2RUN/dir-rename-pairs.tsv"
bash -c "cd '$FDS2' && RUN='$FDS2RUN' PLAN='$FDPRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-dirpair-sib.log"
refute "a surviving sibling does NOT satisfy the anchored renamed-away-dir check" \
  grep -q "renamed-away directory 'internal/moved' still referenced" "$SANDBOX/fu-dirpair-sib.log"
expect "residual, pinned: the fixed-string removed-path grep still matches the sibling" \
  grep -q "removed path 'internal/moved' still referenced" "$SANDBOX/fu-dirpair-sib.log"
cd "$SANDBOX"

fi

if t "the dir-prefix trigger matches a path SEGMENT, not any substring"; then
# The prefix ERE was right-anchored only: `<dir>([^[:alnum:]_-]|$)`. With short
# directory names that is a substring match — `api` fires inside "openapi.yaml" —
# and the result is a MANDATORY, plan-blocking stale-ref follow-up against a
# document that has nothing to do with the rename. A left boundary makes the match
# start at a path-segment boundary; it deliberately still allows `/` and `.` on the
# left, because `"example.com/m/internal/foo"` and `./web/x` are exactly the
# reference shapes this trigger exists to catch.
FAP=$SANDBOX/fu-apicollide; FAPRUN=$SANDBOX/fu-apicollide-run
mkdir -p "$FAPRUN" "$FAP/api/v1" && cd "$FAP" && git init -q -b main
phase5_ran "$FAPRUN"
printf 'package handler\n' > api/v1/handler.go
printf 'the schema lives in docs/openapi.yaml — regenerate it after changes\n' > README.md
git add -A && git commit -qm init
rm -f api/v1/handler.go                       # renamed away by the merge
FCS="$SKILL_DIR/scripts/followup-completeness.sh"
cat > "$FAPRUN/PLAN-empty.md" <<'EOF'
## Tasks
### T01: unrelated
EOF
printf 'api/v1/handler.go -> internal/api/v1/handler.go\n' > "$FAPRUN/renamed.txt"
bash -c "cd '$FAP' && RUN='$FAPRUN' PLAN='$FAPRUN/PLAN-empty.md' '$FCS'" \
  > "$SANDBOX/fu-apicollide.out" 2> "$SANDBOX/fu-apicollide.log"
refute "'api' does not match inside 'openapi.yaml' (no false MANDATORY)" \
  grep -q 'stale-ref:api' "$SANDBOX/fu-apicollide.log"
expect "a run whose only candidate was that collision passes" \
  bash -c "cd '$FAP' && RUN='$FAPRUN' PLAN='$FAPRUN/PLAN-empty.md' '$FCS' >/dev/null 2>&1"

# Regression lock, same short dir: a genuine path reference still triggers.
FAG=$SANDBOX/fu-apigenuine; FAGRUN=$SANDBOX/fu-apigenuine-run
mkdir -p "$FAGRUN" "$FAG/api/v1" && cd "$FAG" && git init -q -b main
phase5_ran "$FAGRUN"
printf 'package handler\n' > api/v1/handler.go
printf 'see api/v1/handler.go for the wiring\n' > README.md
git add -A && git commit -qm init
rm -f api/v1/handler.go
printf 'api/v1/handler.go -> internal/api/v1/handler.go\n' > "$FAGRUN/renamed.txt"
bash -c "cd '$FAG' && RUN='$FAGRUN' PLAN='$FAPRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-apigenuine.log"
expect "a real 'api/...' path reference still triggers the renamed-away dir" \
  grep -qx 'MISSING: stale-ref:api' "$SANDBOX/fu-apigenuine.log"

# Regression lock, the import shape: the left boundary must allow `/`.
FIM=$SANDBOX/fu-import; FIMRUN=$SANDBOX/fu-import-run
mkdir -p "$FIMRUN" "$FIM/internal/foo" && cd "$FIM" && git init -q -b main
phase5_ran "$FIMRUN"
printf 'package foo\n' > internal/foo/x.go
printf 'package keep\n' > internal/keep.go
printf 'package main\n\nimport "example.com/m/internal/foo"\n' > main.go
git add -A && git commit -qm init
rm -f internal/foo/x.go
printf 'internal/foo/x.go -> internal/bar/x.go\n' > "$FIMRUN/renamed.txt"
bash -c "cd '$FIM' && RUN='$FIMRUN' PLAN='$FAPRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-import.log"
expect "a Go import path (dir preceded by '/') still triggers" \
  grep -qx 'MISSING: stale-ref:internal/foo' "$SANDBOX/fu-import.log"

# A removed path that begins with `-`: the self-exclusion grep read it as options,
# errored, and the pipeline swallowed that — so the reference was silently dropped.
FDA=$SANDBOX/fu-dashpath; FDARUN=$SANDBOX/fu-dashpath-run
mkdir -p "$FDARUN" "$FDA" && cd "$FDA" && git init -q -b main
phase5_ran "$FDARUN"
printf 'x\n' > -dash.yaml
printf 'the config is -dash.yaml, read it\n' > README.md
git add -A && git commit -qm init
rm -f ./-dash.yaml
printf -- '-dash.yaml\n' > "$FDARUN/confirmed-deletes.txt"
bash -c "cd '$FDA' && RUN='$FDARUN' PLAN='$FAPRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-dashpath.log"
expect "a leading-dash removed path still yields its stale-ref follow-up" \
  grep -qx 'MISSING: stale-ref:-dash.yaml' "$SANDBOX/fu-dashpath.log"
cd "$SANDBOX"

fi

if t "a renamed-away directory is judged alive by git-meaningful content only"; then
# `find` counted ANYTHING on disk, so the normal state of a JS project disarmed the
# trigger completely: web/node_modules/ (gitignored, present on every developer
# machine) made a renamed-away `web/` look alive, and the stale `COPY web/package.json`
# in the Dockerfile was dropped from the plan silently. Same for a stray .DS_Store.
# Survival is now judged from what git means by content: tracked files still on disk,
# plus untracked-but-not-ignored ones.
FNM=$SANDBOX/fu-nodemod; FNMRUN=$SANDBOX/fu-nodemod-run
mkdir -p "$FNMRUN" "$FNM/web/src" && cd "$FNM" && git init -q -b main
phase5_ran "$FNMRUN"
printf 'node_modules/\n.DS_Store\n' > .gitignore
printf 'console.log(1)\n' > web/src/app.js
printf '{"name":"x"}\n' > web/package.json
printf 'FROM node\nCOPY web/package.json ./\n' > Dockerfile
git add -A && git commit -qm init
rm -f web/src/app.js web/package.json          # renamed away by the merge
mkdir -p web/node_modules/left-pad && printf 'module.exports=1\n' > web/node_modules/left-pad/index.js
FCS="$SKILL_DIR/scripts/followup-completeness.sh"
cat > "$FNMRUN/PLAN-empty.md" <<'EOF'
## Tasks
### T01: unrelated
EOF
printf 'web/src/app.js -> frontend/src/app.js\n' > "$FNMRUN/renamed.txt"
bash -c "cd '$FNM' && RUN='$FNMRUN' PLAN='$FNMRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-nodemod.log"
expect "gitignored node_modules/ does not make a renamed-away web/ look alive" \
  grep -qx 'MISSING: stale-ref:web' "$SANDBOX/fu-nodemod.log"

# A lone ignored .DS_Store, the other everyday case.
FDS=$SANDBOX/fu-dsstore; FDSRUN=$SANDBOX/fu-dsstore-run
mkdir -p "$FDSRUN" "$FDS/web/src" && cd "$FDS" && git init -q -b main
phase5_ran "$FDSRUN"
printf '.DS_Store\n' > .gitignore
printf 'console.log(1)\n' > web/src/app.js
printf 'FROM node\nCOPY web/package.json ./\n' > Dockerfile
git add -A && git commit -qm init
rm -f web/src/app.js
printf '\0\0Bud1\n' > web/.DS_Store
printf 'web/src/app.js -> frontend/src/app.js\n' > "$FDSRUN/renamed.txt"
bash -c "cd '$FDS' && RUN='$FDSRUN' PLAN='$FNMRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-dsstore.log"
expect "a lone ignored .DS_Store does not make a renamed-away web/ look alive" \
  grep -qx 'MISSING: stale-ref:web' "$SANDBOX/fu-dsstore.log"

# The other direction, and the reason the check is not index-only: an UNTRACKED but
# not-ignored file is real new work in that directory, so the directory survives.
FUT=$SANDBOX/fu-untracked; FUTRUN=$SANDBOX/fu-untracked-run
mkdir -p "$FUTRUN" "$FUT/web/src" && cd "$FUT" && git init -q -b main
phase5_ran "$FUTRUN"
printf 'console.log(1)\n' > web/src/app.js
printf 'FROM node\nCOPY web/package.json ./\n' > Dockerfile
git add -A && git commit -qm init
rm -f web/src/app.js
printf 'still working on this\n' > web/NOTES.md      # untracked, NOT ignored
printf 'web/src/app.js -> frontend/src/app.js\n' > "$FUTRUN/renamed.txt"
bash -c "cd '$FUT' && RUN='$FUTRUN' PLAN='$FNMRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-untracked.log"
refute "an untracked, non-ignored file keeps the directory alive" \
  grep -q 'stale-ref:web' "$SANDBOX/fu-untracked.log"

# And the index is not read on its own either: Phase 5 removes old paths with
# `rm -f`, so every renamed-away file is STILL in the index. A tracked file that is
# still on disk is what suppresses the trigger.
FSV=$SANDBOX/fu-survivor; FSVRUN=$SANDBOX/fu-survivor-run
mkdir -p "$FSVRUN" "$FSV/web/src" && cd "$FSV" && git init -q -b main
phase5_ran "$FSVRUN"
printf 'console.log(1)\n' > web/src/app.js
printf '{"name":"x"}\n' > web/package.json
printf 'FROM node\nCOPY web/package.json ./\n' > Dockerfile
git add -A && git commit -qm init
rm -f web/src/app.js                                  # package.json survives
printf 'web/src/app.js -> frontend/src/app.js\n' > "$FSVRUN/renamed.txt"
bash -c "cd '$FSV' && RUN='$FSVRUN' PLAN='$FNMRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-survivor.log"
refute "a surviving tracked file suppresses the directory trigger" \
  grep -q 'stale-ref:web' "$SANDBOX/fu-survivor.log"
cd "$SANDBOX"

fi

if t "a capitalized renamed-away directory behaves the same on both filesystems"; then
# macOS is case-insensitive, Linux is not, and the old check leaned on the
# filesystem twice (`[ -d "$1" ]` plus a raw `find`), which made a Web/web rename
# produce a different trigger COUNT per platform. Survival is now judged from
# git-reported paths — byte-exact and index-derived, verified not to be softened by
# core.ignorecase — so which paths are considered no longer depends on the
# filesystem. This block is the cross-platform LOCK for that (it is asserted
# identically on macOS and in the Ubuntu container): a capitalized directory
# renamed away triggers once, under the spelling git records, and the lowercase
# spelling never appears as a second phantom row. The one class that still cannot
# agree across platforms is a CASE-ONLY rename (`Web/` -> `web/`), where the
# filesystem itself has no fact that distinguishes the two names; the script header
# says so rather than pretending otherwise.
FCS="$SKILL_DIR/scripts/followup-completeness.sh"
FWC=$SANDBOX/fu-webcase; FWCRUN=$SANDBOX/fu-webcase-run
mkdir -p "$FWCRUN" "$FWC/Web/src" && cd "$FWC" && git init -q -b main
phase5_ran "$FWCRUN"
printf 'console.log(1)\n' > Web/src/app.js
printf '{"name":"x"}\n' > Web/package.json
printf 'FROM node\nCOPY Web/package.json ./\n' > Dockerfile
printf 'entrypoint: Web/src/app.js\n' > entry.txt          # the old PATH is referenced too
printf 'and a lowercase mention of web/package.json that must NOT count\n' > notes.txt
git add -A && git commit -qm init
rm -f Web/src/app.js Web/package.json
cat > "$FWCRUN/PLAN-empty.md" <<'EOF'
## Tasks
### T01: unrelated
EOF
printf 'Web/src/app.js -> frontend/src/app.js\n' > "$FWCRUN/renamed.txt"
bash -c "cd '$FWC' && RUN='$FWCRUN' PLAN='$FWCRUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-webcase.log"
expect "the capitalized renamed-away directory triggers, spelled as git spells it" \
  grep -qx 'MISSING: stale-ref:Web' "$SANDBOX/fu-webcase.log"
refute "the lowercase spelling is not ALSO reported (that would be a second, phantom row)" \
  grep -qx 'MISSING: stale-ref:web' "$SANDBOX/fu-webcase.log"
expect "the referenced old path is reported too" \
  grep -qx 'MISSING: stale-ref:Web/src/app.js' "$SANDBOX/fu-webcase.log"
if [[ "$(grep -c '^MISSING: stale-ref:' "$SANDBOX/fu-webcase.log")" = 2 ]]; then
  pass "exactly two stale-ref rows (the old path and its renamed-away dir) on any filesystem"
else
  fail "got $(grep -c '^MISSING: stale-ref:' "$SANDBOX/fu-webcase.log") stale-ref rows (want 2 — the count that used to differ between macOS and Linux)"
fi
cd "$SANDBOX"

fi

if t "a removal whose path is an option string still triggers (records are printf, dirname is anchored)"; then
# renamed.txt is structural-merge.sh's output, which records raw component paths —
# so a rename of a path starting with `-` arrives here. Three sites of one class
# turned that into a SILENT GREEN, the failure this gate exists to prevent:
#   * `echo "$old" >> $REMOVED` and `echo "$rd" >> $RENAME_DIRS` — bash's builtin
#     echo reads an argument that is EXACTLY an option string (`-n`, `-e`, `-E`,
#     any combination) as its own options, so the removal was appended as an empty
#     line (or, with `-n`, not at all) and the empty-line guard on the read loop
#     then skipped it. No trigger, no MISSING row, no disposition demanded.
#   * `dirname "$1"` in renamed_away_dir on an unanchored leading-dash path read it
#     as options and returned EMPTY, so the walk never started and the directory
#     the rename took away was never judged at all.
# The fixture keeps a live reference to each removal, so a working gate must
# refuse. Both are the shapes only this class produces: a root file whose whole
# name is `-n`, and a renamed-away directory named `-e`.
FCS="$SKILL_DIR/scripts/followup-completeness.sh"
FDA=$SANDBOX/fu-dash; FDARUN=$SANDBOX/fu-dash-run
mkdir -p "$FDARUN" "$FDA/-e" "$FDA/pkg" && cd "$FDA" && git init -q -b main
phase5_ran "$FDARUN"
echo x > ./-n                                      # removed by the rename below
echo x > ./-e/x.go                                 # the only content of dir `-e`
printf 'the sprocket list lives at -n — read it\n' > doc.md      # live ref to the file
printf 'FROM node\nCOPY -e/ ./\n' > Dockerfile                   # live ref to the dir
git add -A -- . && git commit -qm init
rm -f -- ./-n ./-e/x.go                            # what structural-merge.sh does
cat > "$FDARUN/PLAN-empty.md" <<'EOF'
## Tasks
### T01: unrelated
EOF
printf -- '-n -> renamed-new.txt\n-e/x.go -> pkg/x.go\n' > "$FDARUN/renamed.txt"
bash -c "cd '$FDA' && RUN='$FDARUN' PLAN='$FDARUN/PLAN-empty.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-dash.log"
expect "the gate refuses rather than reporting no follow-ups" test $? -eq 1
expect "a removed path whose whole name is an option string triggers a stale-ref row" \
  grep -qx 'MISSING: stale-ref:-n' "$SANDBOX/fu-dash.log"
expect "a renamed-away directory whose whole name is an option string triggers too" \
  grep -qx 'MISSING: stale-ref:-e' "$SANDBOX/fu-dash.log"
refute "no dirname usage error leaks to stderr" \
  grep -qE 'illegal option|invalid option|usage: dirname' "$SANDBOX/fu-dash.log"
cd "$SANDBOX"

fi

if t "an absent Phase-5 witness is a refusal (exit 2), not an empty catalogue"; then
# The resume defect, on the follow-up half of the completeness gate. Every trigger
# here reads a Phase 5 / gate artifact, and a Phase 3 re-run regenerates NONE of
# them — so a session resuming into planning against a swept $RUN derived nothing,
# printed "OK: no follow-ups triggered" and exited 0. That is the same false green
# plan-completeness.sh used to print for an absent upgrade list, and it made
# phases/6-planning.md's claim that the gate "cannot silently revert to planner
# judgment" untrue on exactly the path where planner judgment is all that is left.
# Nothing downstream re-derives the catalogue (PLAN.md freezes at approval), so a
# follow-up dropped here is dropped from the migration.
FCS="$SKILL_DIR/scripts/followup-completeness.sh"
FSW=$SANDBOX/fu-swept; FSWRUN=$SANDBOX/fu-swept-run
mkdir -p "$FSWRUN" "$FSW" && cd "$FSW" && git init -q -b main
printf 'the wibble config lives at legacy/sprocket.yaml — read it.\n' > README.txt
git add -A && git commit -qm init
# What a Phase 3 re-run puts back — and nothing Phase 5 wrote. This is the state a
# resume reaches after following continue.md's re-run-classification arm.
printf '.kairos-updates/20260101T000000-first.md\n' > "$FSWRUN/upgrades-added.txt"
cat > "$FSWRUN/PLAN.md" <<'EOF'
## Follow-up Dispositions

| Follow-up | Disposition | Task / Reason |
|---|---|---|
EOF
bash -c "cd '$FSW' && RUN='$FSWRUN' PLAN='$FSWRUN/PLAN.md' '$FCS'" \
  > "$SANDBOX/fu-swept.out" 2> "$SANDBOX/fu-swept.log"
FSW_RC=$?
if [[ "$FSW_RC" -eq 2 ]]; then
  pass "a swept \$RUN with no merge inventories exits 2 (inputs missing), not 0"
else
  fail "a swept \$RUN exits 2 (inputs missing), not 0 (rc=$FSW_RC)"
fi
refute "the swept run never claims nothing was triggered" \
  grep -qi 'no follow-ups triggered' "$SANDBOX/fu-swept.log" "$SANDBOX/fu-swept.out"
refute "the swept run prints no OK line at all" grep -q '^OK:' "$SANDBOX/fu-swept.log"
expect "the refusal names the absent witness" \
  grep -q 'clean-merged.txt' "$SANDBOX/fu-swept.log"
expect "the refusal names re-running Phase 5 as the remedy" \
  bash -c "grep -qi 'phase 5' '$SANDBOX/fu-swept.log'"

# The refusal is about what the gate can ANSWER, not about whether something
# happened to trigger: a removal list that survived cannot license a verdict while
# the witness — and with it every other Phase 5 artifact — is gone, because the
# sweep would silently miss the removals recorded in the lists that did not.
FPA=$SANDBOX/fu-partial; FPARUN=$SANDBOX/fu-partial-run
mkdir -p "$FPARUN" "$FPA" && cd "$FPA" && git init -q -b main
printf 'see legacy/gizmo.yaml for the wiring\n' > README.txt
git add -A && git commit -qm init
echo "legacy/gizmo.yaml" > "$FPARUN/confirmed-deletes.txt"
cp "$FSWRUN/PLAN.md" "$FPARUN/PLAN.md"
bash -c "cd '$FPA' && RUN='$FPARUN' PLAN='$FPARUN/PLAN.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-partial.log"
FPA_RC=$?
if [[ "$FPA_RC" -eq 2 ]]; then
  pass "a removal list without the witness still refuses (exit 2)"
else
  fail "a removal list without the witness still refuses (rc=$FPA_RC, want 2)"
fi
refute "the refusal reports no MISSING rows (it is a refusal, not a partial answer)" \
  grep -q '^MISSING:' "$SANDBOX/fu-partial.log"

# The other half of the split, and the invariant the refusal must not eat: a run that
# COMPLETED Phase 5 with nothing to report has the witness present and empty, and
# every optional list legitimately absent. That is a pass, not a refusal.
FEM=$SANDBOX/fu-emptyrun; FEMRUN=$SANDBOX/fu-emptyrun-run
mkdir -p "$FEM" && cd "$FEM" && git init -q -b main
printf 'nothing was removed in this migration\n' > README.txt
git add -A && git commit -qm init
phase5_ran "$FEMRUN"
cp "$FSWRUN/PLAN.md" "$FEMRUN/PLAN.md"
bash -c "cd '$FEM' && RUN='$FEMRUN' PLAN='$FEMRUN/PLAN.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-emptyrun.log"
FEM_RC=$?
if [[ "$FEM_RC" -eq 0 ]]; then
  pass "witness present-and-empty with every optional list absent still exits 0"
else
  fail "witness present-and-empty still exits 0 (rc=$FEM_RC)"
fi
expect "the empty run still says so on stderr" \
  grep -qi 'no follow-ups triggered' "$SANDBOX/fu-emptyrun.log"

# And an INDIVIDUALLY absent optional list keeps its original meaning: the trigger
# whose input is there fires, the ones whose inputs are absent simply don't.
FON=$SANDBOX/fu-oneinput; FONRUN=$SANDBOX/fu-oneinput-run
mkdir -p "$FON" && cd "$FON" && git init -q -b main
printf 'see legacy/gizmo.yaml for the wiring\n' > README.txt
git add -A && git commit -qm init
phase5_ran "$FONRUN"
echo "legacy/gizmo.yaml" > "$FONRUN/confirmed-deletes.txt"   # deleted/renamed/yaml: absent
                                                             # (the producer verdict is the
                                                             # witness phase5_ran leaves
                                                             # present-and-empty)
cp "$FSWRUN/PLAN.md" "$FONRUN/PLAN.md"
bash -c "cd '$FON' && RUN='$FONRUN' PLAN='$FONRUN/PLAN.md' '$FCS'" \
  > /dev/null 2> "$SANDBOX/fu-oneinput.log"
FON_RC=$?
if [[ "$FON_RC" -eq 1 ]]; then
  pass "individually-absent optional lists keep today's semantics (exit 1, not 2)"
else
  fail "individually-absent optional lists keep today's semantics (rc=$FON_RC, want 1)"
fi
expect "the trigger whose input survived still fires" \
  grep -qx 'MISSING: stale-ref:legacy/gizmo.yaml' "$SANDBOX/fu-oneinput.log"
cd "$SANDBOX"

fi

if t "followup-completeness.sh reads the POSTMERGE producer verdict, and refuses when it is absent"; then
# The producer verdict used to live in ONE unlabelled file that every gate label
# truncated and rewrote, so whichever label ran last owned it. This gate derives
# plan-blocking `producer:` / `skip:producer-*` rows from it at Phase 6, which means
# a plan revised after the midplan cadence gate had run derived its
# POSTMERGE-mandatory acknowledgments from a MIDPLAN verdict — and where midplan's
# producer arm came back clean, stopped requiring them at all, with no MISSING line
# and no sign anything had changed. So the read is by name, and the postmerge file is
# a witness on the same terms as clean-merged.txt: producer-idempotence.sh truncates
# it unconditionally, so present-and-empty ("ran, audited nothing") is
# distinguishable from absent ("never ran"), and another label's file is not a
# substitute.
FPL=$SANDBOX/fu-prodlabel; FPLRUN=$SANDBOX/fu-prodlabel-run
FCS="$SKILL_DIR/scripts/followup-completeness.sh"
mkdir -p "$FPL" "$FPLRUN" && cd "$FPL" && git init -q -b main
printf 'nothing was removed in this migration\n' > README.txt
git add -A && git commit -qm init
cat > "$FPLRUN/PLAN.md" <<'EOF'
## Follow-up Dispositions

| Follow-up | Disposition | Task / Reason |
|---|---|---|
| `skip:producer-regenerate` | acknowledged | no generator reachable in this environment |
EOF
fpl_run() { bash -c "cd '$FPL' && RUN='$FPLRUN' PLAN='$FPLRUN/PLAN.md' '$FCS'" > /dev/null 2> "$1"; }

# 1. Phase 5's merge witness present, the postmerge producer verdict absent => refusal.
: > "$FPLRUN/clean-merged.txt"
rm -f "$FPLRUN/producer-idempotence-postmerge.tsv"
fpl_run "$SANDBOX/fu-prodlabel-absent.log"
FPL_RC=$?
if [[ "$FPL_RC" -eq 2 ]]; then
  pass "an absent postmerge producer verdict refuses (exit 2)"
else
  fail "an absent postmerge producer verdict refuses (rc=$FPL_RC, want 2)"
fi
expect "the refusal names the artifact it could not read" \
  grep -q 'producer-idempotence-postmerge.tsv' "$SANDBOX/fu-prodlabel-absent.log"
refute "the refusal reports no MISSING rows (it is a refusal, not a partial answer)" \
  grep -q '^MISSING:' "$SANDBOX/fu-prodlabel-absent.log"
refute "the refusal never claims an empty catalogue" \
  grep -qi 'no follow-ups triggered' "$SANDBOX/fu-prodlabel-absent.log"

# 2. A MIDPLAN verdict does not stand in for the postmerge one — the defect itself.
printf 'regenerate\tclean\tproducer left tracked state clean\n' > "$FPLRUN/producer-idempotence-midplan.tsv"
fpl_run "$SANDBOX/fu-prodlabel-midplan.log"
FPL_MP_RC=$?
if [[ "$FPL_MP_RC" -eq 2 ]]; then
  pass "a midplan producer verdict is not read as the postmerge one (still exit 2)"
else
  fail "a midplan producer verdict was accepted in place of the postmerge one (rc=$FPL_MP_RC, want 2)"
fi

# 3. The postmerge verdict's own skip row is what triggers, and it is mandatory.
printf 'regenerate\tskip\tenvironment: dial tcp: no such host\n' > "$FPLRUN/producer-idempotence-postmerge.tsv"
fpl_run "$SANDBOX/fu-prodlabel-skip.log"
FPL_SK_RC=$?
if [[ "$FPL_SK_RC" -eq 0 ]]; then
  pass "the postmerge skip row triggers the acknowledgment the plan disposes (exit 0)"
else
  fail "the postmerge skip row's disposition was not accepted (rc=$FPL_SK_RC)"
fi
expect "the triggered follow-up is the producer skip acknowledgment" \
  grep -q 'skip:producer-regenerate' "$SANDBOX/fu-prodlabel-skip.log"

# 4. And a skip row recorded under a DIFFERENT label derives nothing here.
printf 'build\tskip\tenvironment: dial tcp: no such host\n' > "$FPLRUN/producer-idempotence-final.tsv"
: > "$FPLRUN/producer-idempotence-postmerge.tsv"
fpl_run "$SANDBOX/fu-prodlabel-other.log"
FPL_OT_RC=$?
if [[ "$FPL_OT_RC" -eq 0 ]]; then
  pass "a final-label skip row derives no Phase 6 follow-up (exit 0)"
else
  fail "a final-label skip row leaked into the Phase 6 catalogue (rc=$FPL_OT_RC)"
fi
refute "no producer follow-up is derived from another label's verdict" \
  grep -qi 'producer' "$SANDBOX/fu-prodlabel-other.log"
cd "$SANDBOX"

fi

finish_suite
