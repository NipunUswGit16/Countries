#!/usr/bin/env bash
# collect-lib.test.sh — tests for scripts/collect-lib.sh
# TEST_FILTER refused (blocks share sequential fixtures).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in collect-lib.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

# run_cl <run-dir> <cache> <base> <target> [run_source]
# Writes RUN_SOURCE onto the run's context.env (default frontend) and invokes
# collect-lib.sh with the Phase 3 key it shares with build-manifest.sh.
run_cl() {
  local run="$1" cache="$2" base="$3" target="$4" src="${5:-frontend}"
  mkdir -p "$run"
  printf 'RUN_SOURCE=%s\n' "$src" > "$run/context.env"
  RUN=$run CACHE=$cache BASE=$base TARGET=$target PHASE_KEY=$PK_CLASSIFY \
    "$SKILL_DIR/scripts/collect-lib.sh"
}

# A configured frontend repo: config.yaml + optional kind:library module +
# optional in-range upgrade-file. Commits baseline then (if a body is given)
# a target commit that adds the upgrade-file.
# make_fe_repo <dir>  — library module, no upgrade-file (empty range if BASE=TARGET)
# After return: FE_BASE is HEAD. Caller adds files and commits for a non-empty range.
make_fe_repo() {
  local dir="$1"
  mkdir -p "$dir/.kairos-updates/lib" "$dir/lib" "$dir/template/react"
  cd "$dir" || exit 1
  git init -q -b main
  cat > .kairos-updates/config.yaml <<'EOF'
modules:
  react:
    kind: template
    path: template/react
  lib:
    kind: library
    path: lib
EOF
  printf 'export const x = 1\n' > lib/index.ts
  printf 'export const App = 1\n' > template/react/App.ts
  git add -A && git commit -qm baseline
}

if t "collect-lib.sh idles on a template run and records nothing"; then
CL0=$SANDBOX/cl-idle
make_fe_repo "$CL0"
FE_BASE=$(git rev-parse HEAD)
RUN0=$CL0/state; mkdir -p "$RUN0"
run_cl "$RUN0" "$CL0" "$FE_BASE" "$FE_BASE" template > /dev/null 2> "$SANDBOX/cl-idle.log"
expect "a template-run invocation exits 0" test $? -eq 0
expect "the idle skip names RUN_SOURCE" grep -q 'RUN_SOURCE' "$SANDBOX/cl-idle.log"
refute "a template run never records LIB_MODULES (absence IS the template-run record)" \
  grep -q '^LIB_MODULES=' "$RUN0/context.env"
refute "a template run never writes lib-upgrades-added.txt" \
  test -f "$RUN0/lib-upgrades-added.txt"
refute "a template run never writes lib-upgrades-modified.txt" \
  test -f "$RUN0/lib-upgrades-modified.txt"
fi

if t "collect-lib.sh with no kind:library modules records LIB_MODULES=none"; then
CLN=$SANDBOX/cl-none
mkdir -p "$CLN/.kairos-updates/react" "$CLN/template/react"
cd "$CLN" || exit 1
git init -q -b main
cat > .kairos-updates/config.yaml <<'EOF'
modules:
  react:
    kind: template
    path: template/react
EOF
printf 'export const App = 1\n' > template/react/App.ts
git add -A && git commit -qm baseline
NBASE=$(git rev-parse HEAD)
printf 'export const App = 2\n' > template/react/App.ts
git add -A && git commit -qm target
NTARGET=$(git rev-parse HEAD)
RUN_NONE=$CLN/state
run_cl "$RUN_NONE" "$CLN" "$NBASE" "$NTARGET" > /dev/null 2> "$SANDBOX/cl-none.log"
expect "no-library-modules invocation exits 0" test $? -eq 0
expect "LIB_MODULES=none is recorded" grep -qx 'LIB_MODULES=none' "$RUN_NONE/context.env"
expect "the none path says so" grep -qi 'no kind:library' "$SANDBOX/cl-none.log"
fi

if t "collect-lib.sh empty range is present + empty lists, not a missing list"; then
CLE=$SANDBOX/cl-empty
make_fe_repo "$CLE"
EBASE=$(git rev-parse HEAD)
RUNE=$CLE/state
run_cl "$RUNE" "$CLE" "$EBASE" "$EBASE" > /dev/null 2> "$SANDBOX/cl-empty.log"
expect "empty-range invocation exits 0" test $? -eq 0
expect "LIB_MODULES=present when a library module is declared even if the range is empty" \
  grep -qx 'LIB_MODULES=present' "$RUNE/context.env"
expect "lib-upgrades-added.txt exists (empty-but-present is 'none in range')" \
  test -f "$RUNE/lib-upgrades-added.txt"
refute "the empty-range added list has no rows" test -s "$RUNE/lib-upgrades-added.txt"
expect "lib-upgrades-modified.txt exists" test -f "$RUNE/lib-upgrades-modified.txt"
refute "the empty-range modified list has no rows" test -s "$RUNE/lib-upgrades-modified.txt"
fi

if t "collect-lib.sh collects a library upgrade-file over BASE..TARGET with module provenance"; then
setup_frontend_fixture
CLF=$SANDBOX/cl-fe
run_cl "$CLF" "$FRONTEND_REPO_DIR" "$FRONTEND_BASE_SHA" "$FRONTEND_TARGET_SHA" \
  > /dev/null 2> "$SANDBOX/cl-fe.log"
expect "collection over the frontend fixture exits 0" test $? -eq 0
expect "LIB_MODULES=present" grep -qx 'LIB_MODULES=present' "$CLF/context.env"
expect "the lib upgrade-file is in the added list under its RAW path" \
  grep -qx '.kairos-updates/lib/20260116T000000-net-rest-delete-renamed.md' \
    "$CLF/lib-upgrades-added.txt"
expect "the provenance TSV is add-sha TAB module TAB path" \
  bash -c "awk -F'\t' '\$2==\"lib\" && \$3==\".kairos-updates/lib/20260116T000000-net-rest-delete-renamed.md\" && \$1 ~ /^[0-9a-f]{40}$/' '$CLF/lib-upgrades-added.tsv' | grep -q ."
expect "SNAP_SOURCES provenance is <module>:.kairos-updates/<module>/…" \
  grep -q $'20260116T000000-net-rest-delete-renamed.md\tlib:.kairos-updates/lib/20260116T000000-net-rest-delete-renamed.md$' \
    "$CLF/upgrade-snapshot-sources.tsv"
expect "the body is snapshotted into the shared upgrades dir" \
  grep -q '@ifs-kairos/net/rest' "$CLF/upgrades/20260116T000000-net-rest-delete-renamed.md"
refute "a template-kind file is not collected as a library upgrade-file" \
  grep -q app-export-renamed "$CLF/lib-upgrades-added.txt"
refute "the solid sibling is not collected as a library upgrade-file" \
  grep -q solid "$CLF/lib-upgrades-added.txt"
fi

if t "collect-lib.sh collects quote- and backslash-bearing names"; then
CLQ=$SANDBOX/cl-quote
make_fe_repo "$CLQ"
QBASE=$(git -C "$CLQ" rev-parse HEAD)
UQ='20260401T000000-we"ird'
UB='20260401T000000-back\slash'
printf 'intent: quote\nbody-qweird\n' > "$CLQ/.kairos-updates/lib/$UQ.md"
printf 'intent: slash\nbody-qbackslash\n' > "$CLQ/.kairos-updates/lib/$UB.md"
git -C "$CLQ" add -A && git -C "$CLQ" commit -qm quotes
QTARGET=$(git -C "$CLQ" rev-parse HEAD)
RUNQ=$CLQ/state
run_cl "$RUNQ" "$CLQ" "$QBASE" "$QTARGET" > /dev/null 2> "$SANDBOX/cl-q.log"
expect "quote-name collection exits 0" test $? -eq 0
expect "the quote-named file is collected under its RAW name" \
  grep -qxF -- ".kairos-updates/lib/$UQ.md" "$RUNQ/lib-upgrades-added.txt"
expect "the backslash-named file is collected under its RAW name" \
  grep -qxF -- ".kairos-updates/lib/$UB.md" "$RUNQ/lib-upgrades-added.txt"
refute "no C-quoted spelling reaches the added list" \
  grep -q '\\"' "$RUNQ/lib-upgrades-added.txt"
expect "the quote-named body is snapshotted" \
  grep -q body-qweird "$RUNQ/upgrades/$UQ.md"
expect "the backslash-named body is snapshotted" \
  grep -q body-qbackslash "$RUNQ/upgrades/$UB.md"
fi

if t "a TAB-bearing library upgrade-file name is a named hard stop"; then
CLT=$SANDBOX/cl-tab
make_fe_repo "$CLT"
TBASE=$(git -C "$CLT" rev-parse HEAD)
QT_NAME=$(printf '20260401T000000-tab\tname')
printf 'intent: tabbed\nbody-qtabbed\n' > "$CLT/.kairos-updates/lib/$QT_NAME.md"
git -C "$CLT" add -A && git -C "$CLT" commit -qm tabname
TTARGET=$(git -C "$CLT" rev-parse HEAD)
RUNT=$CLT/state
run_cl "$RUNT" "$CLT" "$TBASE" "$TTARGET" > /dev/null 2> "$SANDBOX/cl-tab.log"
QT_RC=$?
if [[ "$QT_RC" -ne 0 ]]; then pass "collection refuses a TAB-bearing upgrade-file name (exit $QT_RC)"; else fail "collection accepted a TAB-bearing upgrade-file name (exit 0)"; fi
expect "the refusal names the offending file" grep -q 'tab' "$SANDBOX/cl-tab.log"
expect "the refusal states the remedy: rename it upstream" \
  grep -qi 'rename' "$SANDBOX/cl-tab.log"
refute "no partial collection list is left behind to be read as complete" \
  test -s "$RUNT/lib-upgrades-added.txt"
# LIB_MODULES=present is recorded ONLY after the walk + refusal checks succeed. A walk
# that refuses (this TAB stop) must leave LIB_MODULES ABSENT — never present-with-empty-
# lists, which a frontend resume would read as "already collected: none" and drop the
# whole lib upgrade set silently. Absence is what makes continue.md re-collect.
refute "a refused walk leaves LIB_MODULES absent (not present-with-empty-lists)" \
  grep -q '^LIB_MODULES=present' "$RUNT/context.env"
fi

if t "a newline-bearing library upgrade-file name is a named hard stop"; then
CLNL=$SANDBOX/cl-nl
make_fe_repo "$CLNL"
NLBASE=$(git -C "$CLNL" rev-parse HEAD)
# A newline in a tracked name is representable in the git index; collect-lib
# must still refuse it because lib-upgrades-added.txt is a line list.
NL_NAME=$(printf '20260401T000000-new\nline')
printf 'intent: nl\nbody-nl\n' > "$CLNL/.kairos-updates/lib/$NL_NAME.md"
git -C "$CLNL" add -A && git -C "$CLNL" commit -qm nlname
NLTARGET=$(git -C "$CLNL" rev-parse HEAD)
RUNNL=$CLNL/state
run_cl "$RUNNL" "$CLNL" "$NLBASE" "$NLTARGET" > /dev/null 2> "$SANDBOX/cl-nl.log"
NL_RC=$?
if [[ "$NL_RC" -ne 0 ]]; then pass "collection refuses a newline-bearing upgrade-file name (exit $NL_RC)"; else fail "collection accepted a newline-bearing upgrade-file name (exit 0)"; fi
refute "no partial collection list is left behind after a newline refusal" \
  test -s "$RUNNL/lib-upgrades-added.txt"
fi

if t "collect-lib.sh records an amended-before-BASE file on the modified list"; then
CLM=$SANDBOX/cl-mod
make_fe_repo "$CLM"
printf 'intent: pre\nbody-pre\n' > "$CLM/.kairos-updates/lib/20260101T000000-pre.md"
git -C "$CLM" add -A && git -C "$CLM" commit -qm pre
MBASE=$(git -C "$CLM" rev-parse HEAD)
printf 'intent: pre\nbody-amended\n' > "$CLM/.kairos-updates/lib/20260101T000000-pre.md"
git -C "$CLM" add -A && git -C "$CLM" commit -qm amend
MTARGET=$(git -C "$CLM" rev-parse HEAD)
RUNM=$CLM/state
run_cl "$RUNM" "$CLM" "$MBASE" "$MTARGET" > /dev/null 2> "$SANDBOX/cl-mod.log"
expect "amended-before-BASE collection exits 0" test $? -eq 0
expect "the pre-BASE file lands on the modified list, not the added list" \
  grep -qx '.kairos-updates/lib/20260101T000000-pre.md' "$RUNM/lib-upgrades-modified.txt"
refute "the pre-BASE file is not also on the added list" \
  grep -q '20260101T000000-pre.md' "$RUNM/lib-upgrades-added.txt"
expect "the snapshot carries the AMENDED body" \
  grep -q body-amended "$RUNM/upgrades/20260101T000000-pre.md"
fi

if t "collect-lib.sh emits a supersede edge for an in-range lib declaration"; then
CLS=$SANDBOX/cl-sup
make_fe_repo "$CLS"
SBASE=$(git -C "$CLS" rev-parse HEAD)
printf 'intent: avoid X\nbefore: OldSym\nverify-script: ! grep -rn OldSym .\n\n## Details\nb\n' \
  > "$CLS/.kairos-updates/lib/20260101T000000-old.md"
git -C "$CLS" add -A && git -C "$CLS" commit -qm old
printf 'intent: X supported now\nsupersedes: 20260101T000000-old\nbefore: NewSym\nverify-script: ! grep -rn OldSym .\n\n## Details\nb\n' \
  > "$CLS/.kairos-updates/lib/20260201T000000-new.md"
git -C "$CLS" add -A && git -C "$CLS" commit -qm new
STARGET=$(git -C "$CLS" rev-parse HEAD)
RUNS=$CLS/state
run_cl "$RUNS" "$CLS" "$SBASE" "$STARGET" > /dev/null 2> "$SANDBOX/cl-sup.log"
expect "lib supersede collection exits 0" test $? -eq 0
expect "the lib edge file is always written" test -f "$RUNS/lib-supersede-edges.tsv"
expect "the backward lib edge is emitted for the lib module" \
  grep -qF "$(printf 'lib\t20260201T000000-new\t20260101T000000-old\tadded')" "$RUNS/lib-supersede-edges.tsv"
fi

if t "collect-lib.sh writes an (empty) edge file even when there are no library modules"; then
# the none path must still leave the edge file present, or supersede-check.sh's
# present-witness / absent-edge-file guard would exit 2 on a frontend run.
CLNE=$SANDBOX/cl-none-edge
mkdir -p "$CLNE/.kairos-updates/react" "$CLNE/template/react"
cd "$CLNE" || exit 1
git init -q -b main
printf 'modules:\n  react:\n    kind: template\n    path: template/react\n' > .kairos-updates/config.yaml
printf 'export const App = 1\n' > template/react/App.ts
git add -A && git commit -qm baseline
NEB=$(git rev-parse HEAD)
RUNNE=$CLNE/state
run_cl "$RUNNE" "$CLNE" "$NEB" "$NEB" > /dev/null 2> "$SANDBOX/cl-none-edge.log"
expect "a none run still writes an edge file" test -f "$RUNNE/lib-supersede-edges.tsv"
expect "the edge file is empty" test ! -s "$RUNNE/lib-supersede-edges.tsv"
fi

if t "Phase 3 redo: SNAP_SOURCES truncation is repaired by the paired collect-lib re-run; SNAP_REFUSALS keep-predicate preserves lib rows"; then
# Atomic-unit invariant (PRD §6.3): build-manifest.sh truncates SNAP_SOURCES
# whole, so lib source rows survive a redo only because collect-lib.sh re-runs
# immediately after. SNAP_REFUSALS is different: build-manifest's keep-predicate
# retains <module>:.kairos-updates/ rows.
# Reuses the frontend fixture from the collection block above (shared sequential).
RED_COMP=$SANDBOX/cl-redo-comp
mkdir -p "$RED_COMP/.kairos" && cd "$RED_COMP" && git init -q -b main
printf 'name: clredo\ntemplate:\n  repo: file://%s\n  sha: %s\n  branch: main\n' \
  "$FRONTEND_REPO_DIR" "$FRONTEND_BASE_SHA" > .kairos/manifest.yaml
git add -A && git commit -qm cl-redo-comp

RED_SYNTH=$SANDBOX/cl-redo-synth
mkdir -p "$RED_SYNTH" && cd "$RED_SYNTH" && git init -q -b main
rm -rf web && mkdir -p web
git -C "$FRONTEND_REPO_DIR" archive "$FRONTEND_BASE_SHA:template/react" | tar -x -C web
git add -A && git commit -qm "synthetic base" && git tag -f kairos-base
rm -rf web && mkdir -p web
git -C "$FRONTEND_REPO_DIR" archive "$FRONTEND_TARGET_SHA:template/react" | tar -x -C web
git add -A && git commit -qm "synthetic target" && git tag -f kairos-target

RED_RUN=$SANDBOX/cl-redo-run; mkdir -p "$RED_RUN"
printf 'RUN_SOURCE=frontend\n' > "$RED_RUN/context.env"
# Seed a lib-shaped refusal AND a template-shaped one. After build-manifest the
# lib row must survive (keep-predicate) and the template row is replaced.
printf 'lib-seed\tlib:.kairos-updates/lib/seed.md\tseeded lib refusal\n' > "$RED_RUN/snapshot-refusals.tsv"
printf 'tpl-seed\t.kairos-updates/tpl.md\tseeded template refusal\n' >> "$RED_RUN/snapshot-refusals.tsv"

cd "$RED_COMP"
RUN=$RED_RUN CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_BASE_SHA TARGET=$FRONTEND_TARGET_SHA \
  SYNTH=$RED_SYNTH MODULE=react PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" \
  > /dev/null 2> "$SANDBOX/cl-redo-bm.log"
expect "Phase 3 classification (redo fixture) exits 0" test $? -eq 0
expect "build-manifest keep-predicate preserves the seeded lib SNAP_REFUSALS row" \
  grep -q $'lib-seed\tlib:.kairos-updates/lib/seed.md\t' "$RED_RUN/snapshot-refusals.tsv"
refute "build-manifest drops the seeded template SNAP_REFUSALS row (it replaces its own)" \
  grep -q 'tpl-seed' "$RED_RUN/snapshot-refusals.tsv"
refute "build-manifest truncated SNAP_SOURCES — no lib source row yet" \
  grep -q 'lib:.kairos-updates/' "$RED_RUN/upgrade-snapshot-sources.tsv"

RUN=$RED_RUN CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_BASE_SHA TARGET=$FRONTEND_TARGET_SHA \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/collect-lib.sh" \
  > /dev/null 2> "$SANDBOX/cl-redo-cl1.log"
expect "collect-lib.sh (redo run 1) exits 0" test $? -eq 0
expect "collect-lib re-appends lib SNAP_SOURCES rows after the truncation" \
  grep -q 'lib:.kairos-updates/lib/' "$RED_RUN/upgrade-snapshot-sources.tsv"
cp "$RED_RUN/upgrade-snapshot-sources.tsv" "$SANDBOX/cl-redo-sources-1.tsv"

# Re-run the atomic unit: classification truncates SNAP_SOURCES, collect-lib
# re-appends. Lib SNAP_REFUSALS rows that collect-lib owns are pruned and
# re-created only on a real refusal; the keep-predicate proof is the bm step
# above. Here we assert SNAP_SOURCES is repaired.
RUN=$RED_RUN CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_BASE_SHA TARGET=$FRONTEND_TARGET_SHA \
  SYNTH=$RED_SYNTH MODULE=react PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/build-manifest.sh" \
  > /dev/null 2> "$SANDBOX/cl-redo-bm2.log"
expect "Phase 3 classification (redo 2) exits 0" test $? -eq 0
refute "the second classification truncated SNAP_SOURCES (lib rows gone until collect-lib)" \
  grep -q 'lib:.kairos-updates/' "$RED_RUN/upgrade-snapshot-sources.tsv"
RUN=$RED_RUN CACHE=$FRONTEND_REPO_DIR BASE=$FRONTEND_BASE_SHA TARGET=$FRONTEND_TARGET_SHA \
  PHASE_KEY=$PK_CLASSIFY "$SKILL_DIR/scripts/collect-lib.sh" \
  > /dev/null 2> "$SANDBOX/cl-redo-cl2.log"
expect "collect-lib.sh (redo run 2) exits 0" test $? -eq 0
expect "the second collect-lib re-appends the same lib SNAP_SOURCES rows" \
  grep -q 'lib:.kairos-updates/lib/' "$RED_RUN/upgrade-snapshot-sources.tsv"
expect "re-run SNAP_SOURCES lib rows match run 1 (replaced, not accumulated)" \
  bash -c "grep 'lib:.kairos-updates/' '$SANDBOX/cl-redo-sources-1.tsv' | sort > '$SANDBOX/cl-s1' ; \
           grep 'lib:.kairos-updates/' '$RED_RUN/upgrade-snapshot-sources.tsv' | sort > '$SANDBOX/cl-s2' ; \
           test -s '$SANDBOX/cl-s1' && cmp -s '$SANDBOX/cl-s1' '$SANDBOX/cl-s2'"
fi

finish_suite
