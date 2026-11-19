#!/usr/bin/env bash
# collect-common.test.sh — tests for scripts/collect-common.sh
# Includes the common-repo fixture (via setup_common_fixture), legacy
# UPGRADE.md capture, and consumer-facing field-contract round-trip.
# TEST_FILTER refused (blocks share sequential fixtures).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in collect-common.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "collect-common.sh idles on a frontend run and records nothing (disjointness self-guard)"; then
# Mirror of clone-common.sh's frontend guard and collect-lib.sh's RUN_SOURCE guard:
# common collection belongs to a TEMPLATE run; lib owns the frontend arm. On a
# RUN_SOURCE=frontend anchor collect-common must no-op — before its required-var loop,
# so it does not hard-fail on a TEMPLATE_GOMOD a frontend run never sets — and write
# no COMMON_* artifact.
CCFE=$SANDBOX/cc-frontend
mkdir -p "$CCFE/state"
printf 'RUN_SOURCE=frontend\n' > "$CCFE/state/context.env"
# Deliberately omit TEMPLATE_GOMOD / COMMON_REPO_PATH: the guard must fire first.
RUN=$CCFE/state PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" \
  > "$SANDBOX/cc-fe.out" 2> "$SANDBOX/cc-fe.log"; ccfe_rc=$?
expect "a frontend-run invocation exits 0 (no-op, not a required-var failure)" test "$ccfe_rc" -eq 0
expect "the idle skip names RUN_SOURCE=frontend" grep -q 'RUN_SOURCE=frontend' "$SANDBOX/cc-fe.log"
refute "a frontend run writes no common-resolution.tsv" test -f "$CCFE/state/common-resolution.tsv"
refute "a frontend run does not hard-fail on the absent TEMPLATE_GOMOD" \
  grep -q 'TEMPLATE_GOMOD not set' "$SANDBOX/cc-fe.log"
fi

if t "collect-common.sh version resolution"; then
CC=$SANDBOX/cc
mkdir -p "$CC/state" && cd "$CC"
COMMON=bitbucket.org/ifs-pd/kairos-component-common
cat > component.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.30
    $COMMON/common v1.4.0
    $COMMON/event-handler v1.2.40
    example.com/other v1.5.0
)
EOF
cat > template.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.3.0
    $COMMON/common v1.3.5
    $COMMON/event-handler v1.2.45
    $COMMON/masterdata v0.1.0
)

replace $COMMON/event-handler => $COMMON/event-handler v1.2.50
EOF
RUNC=$CC/state
RUN=$RUNC COMPONENT_GOMOD=$CC/component.mod TEMPLATE_GOMOD=$CC/template.mod \
  COMMON_REPO_PATH=$COMMON PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc.log"
expect "collect-common.sh exits 0" test $? -eq 0

# common-resolution.tsv columns: 1=module 2=base 3=target 4=tag_prefix 5=dir 6=decision 7=detail
res()    { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNC/common-resolution.tsv"; }
res_is() { local got; got=$(res "$1" "$2"); if [[ "$got" = "$3" ]]; then pass "res $1 col$2 = $3"; else fail "res $1 col$2 = ${got:-<none>} (want $3)"; fi; }
has_no_row() { if [[ -z "$(res "$1" 1)" ]]; then pass "no row for $1"; else fail "unexpected row for $1"; fi; }

res_is api 2 v1.2.30
res_is api 3 v1.3.0
res_is api 4 api
res_is api 5 .kairos-updates/api/
# This run sets NO COMMON_CACHE (resolution-only mode). A resolvable, non-downgrade
# range with no mirror to collect from is a SKIP, not a `collect` with an empty repo
# column that the collection loop silently drops — that lie was the defect. A
# downgrade is still detected without the mirror (semver), so `common` stays
# skip-downgrade. Regression.
res_is api 6 skip-no-cache
res_is common 6 skip-downgrade
res_is event-handler 3 v1.2.50
res_is event-handler 6 skip-no-cache
has_no_row other
has_no_row masterdata
# The no-cache skip must be honest end-to-end: empty repo column (col 8), nothing
# batched as unresolvable (no user prompt), and nothing actually collected.
res_is api 8 ""
refute "no-cache skip is not batched as unresolvable" \
  bash -c "grep -qE '^(api|event-handler)	' '$RUNC/common-unresolvable.txt'"
refute "no-cache skip collected nothing" \
  bash -c "grep -qE '(api|event-handler)' '$RUNC/common-upgrades-added.tsv'"

# A pseudo-version pin with NO COMMON_CACHE must ALSO degrade to a clean skip, not
# an `unresolvable` row — an unresolvable row would land in common-unresolvable.txt
# and fire the batched user prompt for a module we were never going to collect.
# Regression: no-cache pseudo pins used to be recorded unresolvable.
cat > "$CC/component-nc.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/widget v0.0.0-20260101000000-abcdef123456
)
EOF
cat > "$CC/template-nc.mod" <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/widget v1.0.0
)
EOF
RUNNC=$CC/state-nc; mkdir -p "$RUNNC"
RUN=$RUNNC COMPONENT_GOMOD=$CC/component-nc.mod TEMPLATE_GOMOD=$CC/template-nc.mod \
  COMMON_REPO_PATH=$COMMON PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-nc.log"
expect "collect-common.sh (pseudo pin, no cache) exits 0" test $? -eq 0
resnc() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNNC/common-resolution.tsv"; }
if [[ "$(resnc widget 6)" = skip-no-cache ]]; then pass "pseudo pin with no cache -> skip-no-cache (not unresolvable)"; else fail "pseudo pin with no cache decision = $(resnc widget 6)"; fi
refute "pseudo pin with no cache is not batched as unresolvable" \
  bash -c "grep -q '^widget	' '$RUNNC/common-unresolvable.txt'"
expect "no-cache pseudo skip leaves nothing for the batched prompt" \
  bash -c "! test -s '$RUNNC/common-unresolvable.txt'"

LC=$CC/local-common
mkdir -p "$LC/toolkit"
( cd "$LC" && git init -q -b main \
  && echo "module $COMMON/toolkit" > toolkit/go.mod \
  && git add -A && git commit -qm "toolkit v1.0.38" && git tag toolkit/v1.0.38 && git tag toolkit/v1.0.40 \
  && echo "// unreleased" >> toolkit/go.mod && git commit -qam "toolkit unreleased HEAD" )
TK_HEAD=$(git -C "$LC" rev-parse --short HEAD)
TK_TOP=$(git -C "$LC" rev-parse --show-toplevel)
cat > component-lp.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/toolkit v1.0.38
)
EOF
cat > template-lp.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/toolkit v1.0.39
)

replace $COMMON/toolkit => ./local-common/toolkit
EOF
RUNLP=$CC/state-lp; mkdir -p "$RUNLP"
RUN=$RUNLP COMPONENT_GOMOD=$CC/component-lp.mod TEMPLATE_GOMOD=$CC/template-lp.mod \
  TEMPLATE_GOMOD_DIR=$CC COMMON_REPO_PATH=$COMMON \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-lp.log"
expect "collect-common.sh (local-path) exits 0" test $? -eq 0
reslp()    { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNLP/common-resolution.tsv"; }
reslp_is() { local got; got=$(reslp "$1" "$2"); if [[ "$got" = "$3" ]]; then pass "local-path $1 col$2 = $3"; else fail "local-path $1 col$2 = ${got:-<none>} (want $3)"; fi; }
reslp_is toolkit 6 collect
reslp_is toolkit 3 "$TK_HEAD"
reslp_is toolkit 8 "$TK_TOP"
refute "clean local common clone emits no hygiene warning" \
  grep -qi 'uncommitted' "$SANDBOX/cc-lp.log"

# Local common clone hygiene: commit-based collection can't see uncommitted or
# untracked upgrade-files, so a dirty .kairos-updates/ tree in the resolved clone
# must warn (non-fatal) — the mirror of the dirty-template warning.
mkdir -p "$LC/.kairos-updates/toolkit"
echo "# unstaged upgrade" > "$LC/.kairos-updates/toolkit/20260401T000000-uncommitted.md"
RUNLPD=$CC/state-lp-dirty; mkdir -p "$RUNLPD"
RUN=$RUNLPD COMPONENT_GOMOD=$CC/component-lp.mod TEMPLATE_GOMOD=$CC/template-lp.mod \
  TEMPLATE_GOMOD_DIR=$CC COMMON_REPO_PATH=$COMMON \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-lp-dirty.log"
expect "collect-common.sh (dirty local common) still exits 0 (non-fatal)" test $? -eq 0
expect "dirty local common clone warns its uncommitted upgrade-files are invisible" \
  bash -c "grep -qi 'uncommitted' '$SANDBOX/cc-lp-dirty.log' && grep -qi 'toolkit' '$SANDBOX/cc-lp-dirty.log'"
rm -rf "$LC/.kairos-updates"   # restore clean for any later reuse

cat > component-lp2.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/toolkit v1.0.20
)
EOF
RUNLP2=$CC/state-lp2; mkdir -p "$RUNLP2"
RUN=$RUNLP2 COMPONENT_GOMOD=$CC/component-lp2.mod TEMPLATE_GOMOD=$CC/template-lp.mod \
  TEMPLATE_GOMOD_DIR=$CC COMMON_REPO_PATH=$COMMON \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-lp2.log"
expect "collect-common.sh (local-path, missing BASE tag) exits 0" test $? -eq 0
reslp2() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNLP2/common-resolution.tsv"; }
if [[ "$(reslp2 toolkit 6)" = unresolvable ]]; then pass "local-path missing BASE tag -> unresolvable"; else fail "local-path missing BASE tag decision = $(reslp2 toolkit 6)"; fi
expect "local-path missing BASE tag batched into common-unresolvable.txt" \
  grep -q '^toolkit	' "$RUNLP2/common-unresolvable.txt"

# A co-dev clone BEHIND its remote: the pre-fetch (collect_local_range ->
# fetch_local_clone) makes an absent released BASE tag resolvable. Regression for
# the stale-local-clone trap that used to land the module unresolvable and force a
# manual `git pull`. The clone above ($LC) has NO remote, so a fetch cannot help it
# and it must stay unresolvable — proving the fix is the fetch, not a change of rule.
UP=$CC/upstream-toolkit
mkdir -p "$UP/toolkit"
( cd "$UP" && git init -q -b main \
  && echo "module $COMMON/toolkit" > toolkit/go.mod \
  && git add -A && git commit -qm "toolkit v1.0.40" && git tag toolkit/v1.0.40 )
LCF=$CC/local-common-fetch
git clone -q "$UP" "$LCF"            # clone while origin carries only v1.0.40 (stale hereafter)
( cd "$UP" && echo "// v44" >> toolkit/go.mod \
  && git commit -qam "toolkit v1.0.44" && git tag toolkit/v1.0.44 )   # released AFTER the clone
( cd "$LCF" && git checkout -q -b codev \
  && echo "// codev" >> toolkit/go.mod && git commit -qam "toolkit co-dev HEAD" )
LCF_HEAD=$(git -C "$LCF" rev-parse --short HEAD)
if git -C "$LCF" rev-parse -q --verify "refs/tags/toolkit/v1.0.44^{commit}" >/dev/null 2>&1; then
  fail "fixture bug: co-dev clone already carries toolkit/v1.0.44 before the pre-fetch"
else
  pass "fixture: co-dev clone is behind its remote (no toolkit/v1.0.44 yet)"
fi
cat > component-fetch.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/toolkit v1.0.44
)
EOF
cat > template-fetch.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/toolkit v1.0.44
)

replace $COMMON/toolkit => ./local-common-fetch/toolkit
EOF
RUNF=$CC/state-fetch; mkdir -p "$RUNF"
RUN=$RUNF COMPONENT_GOMOD=$CC/component-fetch.mod TEMPLATE_GOMOD=$CC/template-fetch.mod \
  TEMPLATE_GOMOD_DIR=$CC COMMON_REPO_PATH=$COMMON \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-fetch.log"
expect "collect-common.sh (behind-remote co-dev clone) exits 0" test $? -eq 0
resf() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNF/common-resolution.tsv"; }
if [[ "$(resf toolkit 6)" = collect ]]; then pass "pre-fetch makes the absent BASE tag resolvable -> collect"; else fail "behind-remote decision = $(resf toolkit 6) (want collect)"; fi
if [[ "$(resf toolkit 3)" = "$LCF_HEAD" ]]; then pass "behind-remote co-dev TARGET is the clone HEAD"; else fail "behind-remote col3 = $(resf toolkit 3) (want $LCF_HEAD)"; fi
expect "the pre-fetch actually brought the released BASE tag into the co-dev clone" \
  bash -c "git -C '$LCF' rev-parse -q --verify 'refs/tags/toolkit/v1.0.44^{commit}' >/dev/null 2>&1"
refute "a successful pre-fetch emits no fetch warning" \
  grep -qi 'could not fetch' "$SANDBOX/cc-fetch.log"

# Best-effort: an UNREACHABLE remote must warn and proceed on local refs, never
# turn a healthy migration into a hard failure. BASE here exists nowhere, so the
# module still lands unresolvable (correctly) — but via a warned, exit-0 path.
LCB=$CC/local-common-badremote
git clone -q "$UP" "$LCB"
git -C "$LCB" remote set-url origin "$CC/nonexistent-remote.git"
( cd "$LCB" && git checkout -q -b codev \
  && echo "// codev" >> toolkit/go.mod && git commit -qam "toolkit co-dev HEAD" )
cat > component-badremote.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/toolkit v1.0.99
)
EOF
cat > template-badremote.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/toolkit v1.0.99
)

replace $COMMON/toolkit => ./local-common-badremote/toolkit
EOF
RUNB=$CC/state-badremote; mkdir -p "$RUNB"
RUN=$RUNB COMPONENT_GOMOD=$CC/component-badremote.mod TEMPLATE_GOMOD=$CC/template-badremote.mod \
  TEMPLATE_GOMOD_DIR=$CC COMMON_REPO_PATH=$COMMON \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-badremote.log"
expect "collect-common.sh (unreachable co-dev remote) still exits 0 (best-effort fetch)" test $? -eq 0
resb() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNB/common-resolution.tsv"; }
if [[ "$(resb toolkit 6)" = unresolvable ]]; then pass "unreachable remote + absent BASE -> unresolvable (not a hard fail)"; else fail "bad-remote decision = $(resb toolkit 6) (want unresolvable)"; fi
expect "a failed pre-fetch WARNs (names the clone) rather than dying" \
  grep -qi 'could not fetch' "$SANDBOX/cc-badremote.log"


setup_common_fixture

fi

if t "collect-common.sh — modules present but no usable cache: one skip-no-cache row per module, nothing batched"; then
# Phase 3.5's degraded path (COMMON_MODULES=present, COMMON_CACHE unset after a
# failed clone): collection runs ANYWAY and must leave a visible, settled record
# for EVERY module — one skip-no-cache row each — and an EMPTY
# common-unresolvable.txt, so the batched unresolvable question does not fire on
# a run that never had a mirror to resolve against.
cd "$CC"
cat > component-nomirror.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.30
    $COMMON/common v1.3.20
    $COMMON/event-handler v1.2.40
)
EOF
cat > template-nomirror.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.3.0
    $COMMON/common v1.3.25
    $COMMON/event-handler v1.2.45
)
EOF
RUNNM=$CC/state-nomirror; mkdir -p "$RUNNM"
RUN=$RUNNM COMPONENT_GOMOD=$CC/component-nomirror.mod TEMPLATE_GOMOD=$CC/template-nomirror.mod \
  COMMON_REPO_PATH=$COMMON PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-nm.log"
expect "collect-common.sh (present, no cache) exits 0 — degraded, not stopped" test $? -eq 0
expect "every consumed module gets a row" \
  test "$(awk -F'\t' 'NF{print $1}' "$RUNNM/common-resolution.tsv" | grep -c .)" = 3
expect "all three rows are skip-no-cache" \
  test "$(awk -F'\t' '$6=="skip-no-cache"' "$RUNNM/common-resolution.tsv" | grep -c .)" = 3
# Written-and-empty, not merely absent: an unwritten file would pass a bare
# `! test -s` for the wrong reason — the same silence-reads-as-clean shape the
# decision codes exist to avoid.
expect "common-unresolvable.txt is written and empty — the batched question must not fire" \
  bash -c "test -f '$RUNNM/common-unresolvable.txt' && ! test -s '$RUNNM/common-unresolvable.txt'"
refute "nothing is collected without a mirror" \
  bash -c "test -s '$RUNNM/common-upgrades-added.tsv'"

# =============================================================================
fi

if t "collect-common.sh surfaces unresolvable modules (not silently dropped)"; then
cd "$CC"
cat > component-un.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v0.0.0-20260101120000-abcdef123456
    $COMMON/common v1.3.20
)
EOF
cat > template-un.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.3.0
    $COMMON/common v1.9.9
)
EOF
RUNUN=$CC/state-un; mkdir -p "$RUNUN"
RUN=$RUNUN COMPONENT_GOMOD=$CC/component-un.mod TEMPLATE_GOMOD=$CC/template-un.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-un.log"
expect "collect-common.sh (unresolvable) exits 0" test $? -eq 0
resun() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNUN/common-resolution.tsv"; }
if [[ "$(resun api 6)" = unresolvable ]]; then pass "pseudo-version whose commit is ABSENT -> unresolvable"; else fail "pseudo-version decision = $(resun api 6)"; fi
expect "unresolvable pseudo detail NAMES the missing commit (push-or-repick signal)" \
  bash -c "awk -F'\t' '\$1==\"api\"' '$RUNUN/common-unresolvable.txt' | grep -q abcdef123456"
if [[ "$(resun common 6)" = unresolvable ]]; then pass "missing target tag -> unresolvable"; else fail "missing-tag decision = $(resun common 6)"; fi
expect "unresolvable api batched into common-unresolvable.txt"    grep -q '^api	' "$RUNUN/common-unresolvable.txt"
expect "unresolvable common batched into common-unresolvable.txt" grep -q '^common	' "$RUNUN/common-unresolvable.txt"

# =============================================================================
fi

if t "collect-common.sh collects each module's upgrade-files over its range"; then
cd "$CC"
cat > component-col.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.30
    $COMMON/common v1.3.20
)
EOF
cat > template-col.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.3.0
    $COMMON/common v1.3.25
)
EOF
RUNCOL=$CC/state-col; mkdir -p "$RUNCOL"
RUN=$RUNCOL COMPONENT_GOMOD=$CC/component-col.mod TEMPLATE_GOMOD=$CC/template-col.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-col.log"
expect "collect-common.sh (collection) exits 0" test $? -eq 0
modpaths() { awk -F'\t' -v m="$1" '$2==m{print $3}' "$RUNCOL/common-upgrades-added.tsv"; }
in_mod() { if modpaths "$1" | grep -q "$2"; then pass "$1 collection has $2"; else fail "$1 collection missing $2"; fi; }
not_in_mod() { if modpaths "$1" | grep -q "$2"; then fail "$1 collection leaked $2"; else pass "$1 collection excludes $2"; fi; }

in_mod api api-first
in_mod api api-second
in_mod api api-pruned
in_mod common common-first
in_mod common common-second
expect "api collection in commit order (first before second)" \
  bash -c "awk '/api-first/{f=NR} /api-second/{s=NR} END{exit !(f && s && f<s)}' '$RUNCOL/common-upgrades-added.txt'"
expect "api-first body snapshotted"  bash -c "grep -q body-api-first '$RUNCOL/upgrades/20260101T000000-api-first.md'"
expect "pruned upgrade body recovered from add commit, not the empty tip" \
  bash -c "grep -q body-api-pruned '$RUNCOL/upgrades/20260103T000001-api-pruned.md'"
not_in_mod api common-first
not_in_mod api common-second
not_in_mod common api-first
not_in_mod common api-pruned

# =============================================================================
fi

if t "collect-common.sh emits a supersede edge for an in-range declaration"; then
# Self-contained common repo: api ships `old` then `new`, where `new` supersedes
# `old`. Both are added in range, so the collector must emit one backward edge.
SUP=$SANDBOX/cmn-sup; mkdir -p "$SUP/.kairos-updates/api" && cd "$SUP"
git init -q -b main
git add -A 2>/dev/null; git commit -q --allow-empty -m c0; git tag api/v1.0.0
cat > .kairos-updates/api/20260101T000000-old.md <<'UF'
# old
intent: avoid feature X for now.
before: OldSymbol
verify-script: ! grep -rn 'OldSymbol' --include='*.go' .
## Details
body-old
UF
git add -A && git commit -qm c1; git tag api/v1.1.0
cat > .kairos-updates/api/20260201T000000-new.md <<'UF'
# new
intent: feature X is supported now; the earlier guidance no longer applies.
supersedes: 20260101T000000-old
before: NewSymbol
verify-script: ! grep -rn 'OldSymbol' --include='*.go' .
## Details
body-new
UF
git add -A && git commit -qm c2; git tag api/v1.2.0
cd "$CC"
cat > component-sup.mod <<EOF
module example.com/mycomp
go 1.26
require $COMMON/api v1.0.0
EOF
cat > template-sup.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template
go 1.26
require $COMMON/api v1.2.0
EOF
RUNSUP=$CC/state-sup; mkdir -p "$RUNSUP"
RUN=$RUNSUP COMPONENT_GOMOD=$CC/component-sup.mod TEMPLATE_GOMOD=$CC/template-sup.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$SUP \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-sup.log"
expect "collect-common.sh (supersede) exits 0" test $? -eq 0
expect "the edge file is written" test -f "$RUNSUP/common-supersede-edges.tsv"
expect "the backward edge is emitted for api" \
  grep -qF "$(printf 'api\t20260201T000000-new\t20260101T000000-old\tadded')" "$RUNSUP/common-supersede-edges.tsv"
fi

# =============================================================================

if t "collect-common.sh resolves a pseudo-version pin via its embedded commit"; then
# A template pins common by pseudo-version (pushed but untagged). The 12-hex commit
# it embeds usually exists in the mirror, so the range resolves and collects rather
# than being declared unresolvable. Here BASE is the pseudo-version at c1's commit.
cd "$CC"
cat > component-ps.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v0.0.0-20260101000000-$C1_SHA
)
EOF
cat > template-ps.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.3.0
)
EOF
RUNPS=$CC/state-ps; mkdir -p "$RUNPS"
RUN=$RUNPS COMPONENT_GOMOD=$CC/component-ps.mod TEMPLATE_GOMOD=$CC/template-ps.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-ps.log"
expect "collect-common.sh (pseudo resolves) exits 0" test $? -eq 0
resps() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNPS/common-resolution.tsv"; }
if [[ "$(resps api 6)" = collect ]]; then pass "pseudo-version whose commit exists -> collect"; else fail "pseudo-resolve decision = $(resps api 6)"; fi
psmod() { awk -F'\t' -v m="$1" '$2==m{print $3}' "$RUNPS/common-upgrades-added.tsv"; }
if psmod api | grep -q api-second; then pass "range past the pseudo commit collects the later api file"; else fail "pseudo range did not collect api-second"; fi

# semver can't order a commit-bounded range, so a pseudo BASE that is actually
# AHEAD of the target must be caught by commit ancestry, not collected as if it
# were behind. BASE = pseudo at c1 (api/v1.2.40); TARGET = api/v1.2.30 at c0, an
# ancestor of c1 -> downgrade/no-op, must skip rather than collect nothing silently.
cat > component-psd.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v0.0.0-20260101000000-$C1_SHA
)
EOF
cat > template-psd.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.2.30
)
EOF
RUNPSD=$CC/state-psd; mkdir -p "$RUNPSD"
RUN=$RUNPSD COMPONENT_GOMOD=$CC/component-psd.mod TEMPLATE_GOMOD=$CC/template-psd.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-psd.log"
expect "collect-common.sh (pseudo downgrade) exits 0" test $? -eq 0
respsd() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNPSD/common-resolution.tsv"; }
if [[ "$(respsd api 6)" = skip-downgrade ]]; then pass "pseudo BASE ahead of target -> skip-downgrade (ancestry)"; else fail "pseudo-downgrade decision = $(respsd api 6)"; fi

# =============================================================================
fi

if t "collect-common.sh recognizes all three Go pseudo-version forms"; then
# Only the no-release-tag form puts a DASH before the timestamp; the two
# tagged-base forms put a DOT. Every common module carries release tags, so a
# real co-dev pin is always a dot form — matching the dash form alone sent them
# down the tag path, where they failed tag_exists and were reported as a missing
# tag (the wrong remedy). Regression.
cd "$CC"
cat > template-forms.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.3.0
)
EOF
ps_form() { # ps_form <label> <base-version>
cat > "$CC/component-form.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api $2
)
EOF
  RUNF=$CC/state-form-$1; rm -rf "$RUNF"; mkdir -p "$RUNF"
  RUN=$RUNF COMPONENT_GOMOD=$CC/component-form.mod TEMPLATE_GOMOD=$CC/template-forms.mod \
    COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
    PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-form-$1.log"
}
form_is() { # form_is <label> <col> <want>
  local got; got=$(awk -F'\t' -v c="$2" '$1=="api"{print $c}' "$CC/state-form-$1/common-resolution.tsv")
  if [[ "$got" = "$3" ]]; then pass "$1 form col$2 = ${3:-<empty>}"; else fail "$1 form col$2 = ${got:-<none>} (want ${3:-<empty>})"; fi
}

ps_form notag "v0.0.0-20260101000000-$C1_SHA"
expect "collect-common.sh (no-tag pseudo form) exits 0" test $? -eq 0
form_is notag 6 collect
form_is notag 7 "pseudo-version resolved via embedded commit"

ps_form prerel "v1.2.41-rc1.0.20260101000000-$C1_SHA"
expect "collect-common.sh (pre-release pseudo form) exits 0" test $? -eq 0
form_is prerel 6 collect
form_is prerel 7 "pseudo-version resolved via embedded commit"

ps_form postrel "v1.2.41-0.20260101000000-$C1_SHA"
expect "collect-common.sh (post-release pseudo form) exits 0" test $? -eq 0
form_is postrel 6 collect
form_is postrel 7 "pseudo-version resolved via embedded commit"
expect "post-release pseudo form collects over its embedded commit's range" \
  grep -q api-second "$CC/state-form-postrel/common-upgrades-added.tsv"

# A released version must NOT be mistaken for a pseudo-version: it keeps the
# tag_exists path, whose collect rows carry an empty detail.
ps_form tagged v1.2.30
form_is tagged 6 collect
form_is tagged 7 ""

# Near-miss: a 13-digit timestamp is not a pseudo-version. It stays on the tag
# path, and the detail says so rather than naming an embedded commit.
ps_form nearmiss "v1.2.3-2026010100000-abcdef123456"
form_is nearmiss 6 unresolvable
expect "13-digit timestamp is not treated as a pseudo-version (tag-path detail)" \
  bash -c "awk -F'\t' '\$1==\"api\"{print \$7}' '$CC/state-form-nearmiss/common-resolution.tsv' | grep -q 'missing tag'"

# =============================================================================
fi

if t "collect-common.sh hard-fails on a component go.mod it cannot read or parse"; then
# The resolution loop is fed by a process substitution: a failing gomod_requires
# is an EMPTY loop, so a missing go.mod (or a python-flavored yq) used to finish
# "OK" with zero modules and every common migration silently dropped.
cd "$CC"
RUNBAD=$CC/state-badmod; mkdir -p "$RUNBAD"
RUN=$RUNBAD COMPONENT_GOMOD=$CC/does-not-exist.mod TEMPLATE_GOMOD=$CC/template-forms.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" >/dev/null 2> "$SANDBOX/cc-badmod.log"
expect "missing component go.mod exits 1" test $? -eq 1
expect "missing component go.mod names the path" grep -q 'does-not-exist.mod' "$SANDBOX/cc-badmod.log"
refute "missing component go.mod never reports OK" grep -q '^OK' "$SANDBOX/cc-badmod.log"

echo 'this is not a go.mod {{{' > "$CC/garbage.mod"
RUNBAD2=$CC/state-badmod2; mkdir -p "$RUNBAD2"
RUN=$RUNBAD2 COMPONENT_GOMOD=$CC/garbage.mod TEMPLATE_GOMOD=$CC/template-forms.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" >/dev/null 2> "$SANDBOX/cc-badmod2.log"
expect "unparseable component go.mod exits 1" test $? -eq 1
expect "unparseable component go.mod names the path" grep -q 'garbage.mod' "$SANDBOX/cc-badmod2.log"
refute "unparseable component go.mod writes no resolution rows" \
  bash -c "test -s '$RUNBAD2/common-resolution.tsv'"

# =============================================================================
fi

if t "collect-common.sh hard-fails on a template go.mod it cannot read or parse"; then
# The TARGET side of every range comes from the template go.mod, and it was read
# with NO guard at all: `target_version` drives two process-substitution read loops,
# and a failing `go mod edit -json` is an EMPTY loop, so an absent, unreadable or
# unparseable template go.mod resolved EVERY module to "template does not pin" —
# skip-absent-target for all of them, exit 0, a green tally, and every common-library
# migration silently dropped. The component-side guard above already existed; this is
# the same fail-open on the other input.
cd "$CC"
tmpl_bad() { # tmpl_bad <label> <template-gomod-path>
  local run=$CC/state-badtpl-$1; rm -rf "$run"; mkdir -p "$run"
  RUN=$run COMPONENT_GOMOD=$CC/component.mod TEMPLATE_GOMOD="$2" \
    COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
    PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" \
    >/dev/null 2> "$SANDBOX/cc-badtpl-$1.log"
}

tmpl_bad absent "$CC/no-such-template.mod"
expect "absent template go.mod exits 1" test $? -eq 1
expect "absent template go.mod names the path" \
  grep -q 'no-such-template.mod' "$SANDBOX/cc-badtpl-absent.log"
refute "absent template go.mod never reports OK" grep -q '^OK' "$SANDBOX/cc-badtpl-absent.log"
# The write-no-rows refute below is the discriminating assertion: the guard fails
# before common-resolution.tsv is created, so a grep for 'template does not pin' on a
# never-created file could only ever pass vacuously, while `test -s` actually goes red
# if the guard is removed and the fail-open marks every module as not-pinned.
refute "absent template go.mod writes no resolution rows" \
  bash -c "test -s '$CC/state-badtpl-absent/common-resolution.tsv'"

echo 'not a go.mod at all {{{' > "$CC/template-garbage.mod"
tmpl_bad garbage "$CC/template-garbage.mod"
expect "unparseable template go.mod exits 1" test $? -eq 1
expect "unparseable template go.mod names the path" \
  grep -q 'template-garbage.mod' "$SANDBOX/cc-badtpl-garbage.log"
refute "unparseable template go.mod writes no resolution rows" \
  bash -c "test -s '$CC/state-badtpl-garbage/common-resolution.tsv'"

# An EMPTY template go.mod parses as "no requires" — indistinguishable from a
# template that pins nothing, which is the exact silent-skip the guard exists to
# stop. It must be refused as a go.mod (no `module` line), like the extraction
# guard in extract-template-gomod.sh refuses it.
: > "$CC/template-empty.mod"
tmpl_bad empty "$CC/template-empty.mod"
expect "empty template go.mod exits 1" test $? -eq 1
# Same discrimination as the absent case: the guard fails before the resolution file
# is created, so a grep for the fail-open sentence is vacuous; `test -s` goes red if
# the guard is removed and the empty go.mod is silently treated as "pins nothing".
refute "empty template go.mod writes no resolution rows" \
  bash -c "test -s '$CC/state-badtpl-empty/common-resolution.tsv'"

# DIAGNOSIS QUALITY: three shapes that all used to answer with the wrong sentence.
# The module-line probe was a stricter grep than go's own parser, so a go.mod go
# itself accepts was rejected as shapeless; a DIRECTORY at the pointed-at path was
# reported as "not readable"; and TEMPLATE_GOMOD_DIR's default `cd $(dirname …)` ran
# BEFORE the guard, so an absent path leaked a raw shell `cd: no such file` line
# ahead of the real message. Each one sends the operator to fix the wrong thing.
printf '\tmodule bitbucket.org/ifs-pd/kairos-component-template\n\ngo 1.26\n\nrequire (\n    %s/api v1.2.50\n)\n' "$COMMON" > "$CC/template-indented.mod"
tmpl_bad indented "$CC/template-indented.mod"
CC_IND_RC=$?
if [[ "$CC_IND_RC" -eq 0 ]]; then pass "an indented 'module' line (go accepts it) is not called shapeless"; else fail "an indented module line exited $CC_IND_RC (want 0 — go parses it)"; fi
refute "and it is not reported as carrying no module line" \
  grep -qi 'no .module. line' "$SANDBOX/cc-badtpl-indented.log"

printf '\xef\xbb\xbfmodule bitbucket.org/ifs-pd/kairos-component-template\n\ngo 1.26\n\nrequire (\n    %s/api v1.2.50\n)\n' "$COMMON" > "$CC/template-bom.mod"
tmpl_bad bom "$CC/template-bom.mod"
refute "a UTF-8 BOM is never diagnosed as 'no module line' (that sends the operator to fix the wrong thing)" \
  grep -qi 'no .module. line' "$SANDBOX/cc-badtpl-bom.log"

mkdir -p "$CC/template-is-a-dir.mod"
tmpl_bad dir "$CC/template-is-a-dir.mod"
expect "a directory at TEMPLATE_GOMOD exits 1" test $? -eq 1
expect "a directory is diagnosed as a directory, not as 'not readable'" \
  grep -qi 'director' "$SANDBOX/cc-badtpl-dir.log"

# The leak needed an absent DIRECTORY, not just an absent file: the default was
# `cd $(dirname "$TEMPLATE_GOMOD")`, so a path under a directory that does not exist
# printed the shell's own complaint first and the operator read that instead.
tmpl_bad nodir "$CC/no-such-dir/template.mod"
expect "a TEMPLATE_GOMOD under a missing directory exits 1" test $? -eq 1
refute "and it leaks no raw shell cd error ahead of the real message" \
  grep -qiE 'cd:|not a directory' "$SANDBOX/cc-badtpl-nodir.log"
expect "the message it does print names the input" \
  grep -q 'no-such-dir/template.mod' "$SANDBOX/cc-badtpl-nodir.log"

if [[ "$(id -u)" -eq 0 ]]; then
  # Root bypasses chmod 000 (DAC), so the file stays readable and the assertion
  # would test nothing. Same skip-pass posture as merge-path.test.sh's
  # unwritable-destination block.
  pass "unreadable template go.mod case skipped (running as root)"
else
  cp "$CC/template.mod" "$CC/template-noread.mod" && chmod 000 "$CC/template-noread.mod"
  tmpl_bad noread "$CC/template-noread.mod"
  rc=$?
  chmod 644 "$CC/template-noread.mod" 2>/dev/null || true
  if [[ "$rc" -eq 1 ]]; then pass "unreadable template go.mod exits 1"; else fail "unreadable template go.mod exits 1 (rc=$rc)"; fi
  expect "unreadable template go.mod names the path" \
    grep -q 'template-noread.mod' "$SANDBOX/cc-badtpl-noread.log"
fi

# =============================================================================
fi

if t "collect-common.sh refuses to overwrite a good snapshot with an empty body"; then
# The twin of build-manifest.sh's snap_upgrade (merge-path.test.sh covers that
# copy): the body arrives on STDIN from `git show <sha>:<path>`, so a failing read
# is an EMPTY stdin rather than an error the pipeline can see, and `cat > tmp; mv
# tmp dest` replaced a good snapshot with a zero-byte file the planner would then
# plan from. Its own tiny common mirror, so removing an object cannot disturb the
# shared $CMN fixture the blocks around this one depend on.
B3C=$SANDBOX/cc-snapguard-common
mkdir -p "$B3C/.kairos-updates/api" && cd "$B3C" && git init -q -b main
printf 'seed\n' > seed.txt
git add -A && git commit -qm b3-c0
git tag api/v1.0.0
cat > .kairos-updates/api/20260401T000000-b3.md <<'UF'
# b3

intent: consumer must migrate call-sites.

before: OldSymbol_b3
after:  NewSymbol_b3

## Details
common-body-must-survive
UF
git add -A && git commit -qm b3-c1
git tag api/v1.0.1

B3W=$SANDBOX/cc-snapguard; mkdir -p "$B3W" && cd "$B3W"
cat > component-b3.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.0.0
)
EOF
cat > template-b3.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.0.1
)
EOF
B3RUN=$B3W/state; mkdir -p "$B3RUN"
b3_collect() {
  RUN=$B3RUN COMPONENT_GOMOD=$B3W/component-b3.mod TEMPLATE_GOMOD=$B3W/template-b3.mod \
    COMMON_REPO_PATH=$COMMON COMMON_CACHE=$B3C \
    PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" >/dev/null 2> "$1"
}
b3_collect "$SANDBOX/cc-snap1.log"
expect "snapshot-guard fixture collects (run 1)" test $? -eq 0
expect "run 1 snapshotted the common upgrade-file body" \
  grep -q common-body-must-survive "$B3RUN/upgrades/20260401T000000-b3.md"

B3BLOB=$(git -C "$B3C" rev-parse 'api/v1.0.1:.kairos-updates/api/20260401T000000-b3.md')
rm -f "$B3C/.git/objects/${B3BLOB:0:2}/${B3BLOB:2}"
refute "the fixture's common body read really does fail now" \
  git -C "$B3C" show "api/v1.0.1:.kairos-updates/api/20260401T000000-b3.md"

b3_collect "$SANDBOX/cc-snap2.log"
B3RC=$?
expect "the good common snapshot survives a failed re-read" \
  grep -q common-body-must-survive "$B3RUN/upgrades/20260401T000000-b3.md"
refute "the common snapshot was not truncated to zero bytes" \
  bash -c "test ! -s '$B3RUN/upgrades/20260401T000000-b3.md'"
expect "the refusal is loud: one line naming the file and saying it refused" \
  grep -qi 'refus.*20260401T000000-b3\|20260401T000000-b3.*refus' "$SANDBOX/cc-snap2.log"
expect "collection still completes (exit 0)" test "$B3RC" -eq 0

# The WARN is stderr-only and the call site is `|| true`, so the refusal is also a
# ROW the phase and next-upgrade-file.sh can read. Same shared-file discipline as
# upgrade-snapshot-sources.tsv: Phase 3's rows survive, ours are replaced (never
# accumulated) on a re-run.
expect "a refused common snapshot is recorded in \$RUN/snapshot-refusals.tsv" \
  bash -c "cut -f1 '$B3RUN/snapshot-refusals.tsv' | grep -qx 20260401T000000-b3"
expect "the recorded row carries the module-prefixed source" \
  bash -c "cut -f2 '$B3RUN/snapshot-refusals.tsv' | grep -q '^api:.kairos-updates/'"
printf 'tpl-slug\t.kairos-updates/20260101T000000-tpl.md\tgit show failed (exited 128)\n' \
  >> "$B3RUN/snapshot-refusals.tsv"
b3_collect "$SANDBOX/cc-snap3.log"
expect "a re-run keeps Phase 3's refusal rows" \
  bash -c "cut -f1 '$B3RUN/snapshot-refusals.tsv' | grep -qx tpl-slug"
if [[ "$(cut -f1 "$B3RUN/snapshot-refusals.tsv" | grep -cx 20260401T000000-b3)" = 1 ]]; then
  pass "a re-run replaces its own refusal row instead of accumulating one per run"
else
  fail "the refusal row accumulated across re-runs"
fi

# The two shared-sidecar prune chains (upgrade-snapshot-sources.tsv and
# snapshot-refusals.tsv) are now CHECKED stage by stage — under `set -u` alone the old
# `mktemp && awk && mv` chain just short-circuited, so a failed stage silently SKIPPED
# the prune: this run's stale refusal rows survived and next-upgrade-file.sh reads them
# to answer exit 5 for a slug this run never refused, and the temp leaked. mktemp is
# forced to fail with a nonexistent TMPDIR (the FIRST mktemp collect-common reaches is
# the prune's, and both sidecars already exist from the runs above, so the prune branch
# is taken); git tolerates the bad env TMPDIR for the resolution walks, so the run
# proceeds to the prune. The "names the prune failure" assertion also proves the stop
# is the prune and not some earlier casualty of the bad TMPDIR.
TMPDIR=/nonexistent/kairos-no-such-dir b3_collect "$SANDBOX/cc-snap-prunefail.log"
CC_PRUNE_RC=$?
if [[ "$CC_PRUNE_RC" -ne 0 ]]; then
  pass "an unprunable shared sidecar is a loud stop (exit $CC_PRUNE_RC), not a silent skip"
else
  fail "collect-common.sh exited 0 despite a failed shared-sidecar prune"
fi
expect "the diagnostic names the prune failure" \
  grep -qi 'temp file to prune' "$SANDBOX/cc-snap-prunefail.log"
cd "$CC"

# =============================================================================
fi

if t "collect-common.sh snapshots a legitimately EMPTY common upgrade-file"; then
# The twin of the template-side case (merge-path.test.sh): refusing every empty
# body conflated "git show failed" with "the committed file is 0 bytes", and the
# second one made that upgrade-file unmigratable forever — listed, unservable,
# blocking the completeness gate, with every remedy pointing back at the phase that
# reproduces it. `git show`'s exit status is what separates the two.
EMC=$SANDBOX/cc-emptybody-common
mkdir -p "$EMC/.kairos-updates/api" && cd "$EMC" && git init -q -b main
printf 'seed\n' > seed.txt
git add -A && git commit -qm em-c0
git tag api/v1.0.0
: > .kairos-updates/api/20260501T000000-emptycommon.md      # committed at zero bytes
git add -A && git commit -qm em-c1
git tag api/v1.0.1

EMW=$SANDBOX/cc-emptybody; mkdir -p "$EMW" && cd "$EMW"
printf 'module example.com/mycomp\n\ngo 1.26\n\nrequire (\n    %s/api v1.0.0\n)\n' "$COMMON" > component-em.mod
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n\ngo 1.26\n\nrequire (\n    %s/api v1.0.1\n)\n' "$COMMON" > template-em.mod
EMRUN=$EMW/state; mkdir -p "$EMRUN"
RUN=$EMRUN COMPONENT_GOMOD=$EMW/component-em.mod TEMPLATE_GOMOD=$EMW/template-em.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$EMC \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" >/dev/null 2> "$SANDBOX/cc-empty.log"
expect "the empty-common-body fixture collects (exit 0)" test $? -eq 0
expect "the empty common upgrade-file is collected into the list" \
  grep -q '20260501T000000-emptycommon.md' "$EMRUN/common-upgrades-added.txt"
expect "its zero-byte body is snapshotted rather than refused" \
  test -f "$EMRUN/upgrades/20260501T000000-emptycommon.md"
refute "the snapshot is empty because the committed file is" \
  test -s "$EMRUN/upgrades/20260501T000000-emptycommon.md"
refute "a successful read of an empty blob is not recorded as a refusal" \
  bash -c "cut -f1 '$EMRUN/snapshot-refusals.tsv' 2>/dev/null | grep -qx 20260501T000000-emptycommon"
refute "and nothing on stderr calls it a refusal" grep -qi 'refus' "$SANDBOX/cc-empty.log"
RUN=$EMRUN LIST=$EMRUN/common-upgrades-added.txt SLUG=20260501T000000-emptycommon \
  "$SKILL_DIR/scripts/next-upgrade-file.sh" > "$SANDBOX/cc-empty-serve.out" 2>&1
EM_SERVE_RC=$?
if [[ "$EM_SERVE_RC" -eq 0 ]]; then pass "the planner can read the empty common upgrade-file (exit 0)"; else fail "serving it exited $EM_SERVE_RC (want 0)"; fi
expect "the planner is told the body is empty" grep -q '^EMPTY:' "$SANDBOX/cc-empty-serve.out"
cd "$CC"

# =============================================================================
fi

if t "collect-common.sh re-run replaces its own upgrade-snapshot-sources.tsv rows and keeps Phase 3's"; then
# build-manifest.sh truncates this shared sidecar at its Phase 3 write and this
# script appends to it in Phase 3.5 — so a re-run must neither truncate (that
# discards the template rows) nor blindly append (that accumulates duplicates
# and makes the collision WARN fire against our own previous run).
cd "$CC"
RUNIDEM=$CC/state-idem; rm -rf "$RUNIDEM"; mkdir -p "$RUNIDEM"
SRCTSV=$RUNIDEM/upgrade-snapshot-sources.tsv
printf '20260101T000000-tpl.md\t.kairos-updates/20260101T000000-tpl.md\n' > "$SRCTSV"
run_idem() {
  RUN=$RUNIDEM COMPONENT_GOMOD=$CC/component-col.mod TEMPLATE_GOMOD=$CC/template-col.mod \
    COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
    PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2>> "$SANDBOX/cc-idem.log"
}
run_idem
expect "collect-common.sh (idempotence run 1) exits 0" test $? -eq 0
cp "$SRCTSV" "$CC/sources-run1.tsv"
run_idem
expect "collect-common.sh (idempotence run 2) exits 0" test $? -eq 0
expect "re-run leaves the sidecar byte-identical (own rows replaced, not accumulated)" \
  cmp -s "$CC/sources-run1.tsv" "$SRCTSV"
expect "re-run preserves the Phase 3 template row build-manifest.sh wrote" \
  grep -qxF '20260101T000000-tpl.md	.kairos-updates/20260101T000000-tpl.md' "$SRCTSV"
expect "each common snapshot of this run is recorded exactly once" \
  test "$(grep -c '^20260101T000000-api-first.md	api:' "$SRCTSV")" = 1

# =============================================================================
fi

if t "collect-common.sh honors a per-module ref-override (branch-only upgrade-files)"; then
# The batched "provide a ref" answer must be mechanically actionable: write the
# override, re-run. A common branch carrying upgrade-files that exist on no tag is
# collected against that ref, resolved in the mirror cache — no local checkout.
git -C "$CMN" checkout -q -b codev-api
mkdir -p "$CMN/.kairos-updates/api"
cat > "$CMN/.kairos-updates/api/20260301T000000-api-codev.md" <<'UF'
# api-codev

intent: consumer must migrate call-sites after api-codev.

before: OldSymbol_api-codev
after:  NewSymbol_api-codev

verify-script: ! grep -rn 'OldSymbol_api-codev' --include='*.go' .

## Details
body-api-codev
UF
git -C "$CMN" add -A && git -C "$CMN" commit -qm "codev api-codev (untagged, branch only)"
git -C "$CMN" checkout -q main   # branch ref stays; main history is untouched
cd "$CC"
cat > component-ovr.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.30
)
EOF
cat > template-ovr.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.3.0
)
EOF
printf 'api\tcodev-api\n' > "$CC/ref-overrides.tsv"
RUNOVR=$CC/state-ovr; mkdir -p "$RUNOVR"
RUN=$RUNOVR COMPONENT_GOMOD=$CC/component-ovr.mod TEMPLATE_GOMOD=$CC/template-ovr.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN REF_OVERRIDES=$CC/ref-overrides.tsv \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-ovr.log"
expect "collect-common.sh (ref-override) exits 0" test $? -eq 0
resovr() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNOVR/common-resolution.tsv"; }
if [[ "$(resovr api 6)" = collect ]]; then pass "ref-override routes the module to collect"; else fail "ref-override decision = $(resovr api 6)"; fi
if resovr api 7 | grep -qi 'override'; then pass "ref-override recorded in the decision detail (auditable provenance)"; else fail "override provenance missing from detail: $(resovr api 7)"; fi
ovrmod() { awk -F'\t' -v m="$1" '$2==m{print $3}' "$RUNOVR/common-upgrades-added.tsv"; }
if ovrmod api | grep -q api-codev; then pass "branch-only upgrade-file collected via the override"; else fail "override did not collect the branch-only api-codev file"; fi
expect "branch-only upgrade-file body snapshotted" \
  bash -c "grep -q body-api-codev '$RUNOVR/upgrades/20260301T000000-api-codev.md'"

# =============================================================================
fi

if t "collect-common.sh serves a drafted->amended->renamed upgrade-file once, at its final slug, with its amended body"; then
# The append-only authoring discipline governs MERGED history; a not-yet-merged
# co-dev branch drafts, amends and renames its OWN upgrade-file as normal
# authoring. Collection must reach the planner with the amended body and the
# final identity, never the first draft under a slug that no longer exists, and
# never twice under two slugs.
git -C "$CMN" checkout -q codev-api
cat > "$CMN/.kairos-updates/api/20260305T000000-api-draft-fields.md" <<'UF'
# api-draft-fields

Some prose draft with none of the machine-read fields yet.

body-api-draft-fields-v1
UF
git -C "$CMN" add -A && git -C "$CMN" commit -qm "draft api-draft-fields (no machine-read fields yet)"
cat > "$CMN/.kairos-updates/api/20260305T000000-api-draft-fields.md" <<'UF'
# api-draft-fields

intent: consumer must migrate call-sites after api-draft-fields.

before: OldSymbol_api-draft-fields
after:  NewSymbol_api-draft-fields

verify-script: ! grep -rn 'OldSymbol_api-draft-fields' --include='*.go' .

## Details
body-api-draft-fields-v2
UF
git -C "$CMN" commit -qam "amend api-draft-fields (add machine-read fields)"
git -C "$CMN" tag api/v1.2.31   # BASE for the "rename with the add out of range" fixture below
git -C "$CMN" mv .kairos-updates/api/20260305T000000-api-draft-fields.md .kairos-updates/api/20260312T000000-api-final-fields.md
git -C "$CMN" commit -qm "rename api-draft-fields to api-final-fields"
cat > "$CMN/.kairos-updates/api/20260315T000000-api-no-fields.md" <<'UF'
# api-no-fields

Prose only, never amended with machine-read fields.

body-api-no-fields
UF
git -C "$CMN" add -A && git -C "$CMN" commit -qm "add api-no-fields (never gets machine-read fields)"
git -C "$CMN" checkout -q main

RUNOVR2=$CC/state-ovr2; mkdir -p "$RUNOVR2"
RUN=$RUNOVR2 COMPONENT_GOMOD=$CC/component-ovr.mod TEMPLATE_GOMOD=$CC/template-ovr.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN REF_OVERRIDES=$CC/ref-overrides.tsv \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-ovr2.log"
expect "collect-common.sh (ref-override, drafted/amended/renamed) exits 0" test $? -eq 0
ovrmod2() { awk -F'\t' -v m="$1" '$2==m{print $3}' "$RUNOVR2/common-upgrades-added.tsv"; }

expect "drafted->amended->renamed file appears exactly once, at its final slug" \
  test "$(ovrmod2 api | grep -c api-final-fields)" = 1
if ovrmod2 api | grep -q api-draft-fields; then fail "the pre-rename slug is also served (double identity)"; else pass "the pre-rename slug is not also served (no double identity)"; fi
expect "served snapshot carries the AMENDED body, not the first draft" \
  bash -c "grep -q body-api-draft-fields-v2 '$RUNOVR2/upgrades/20260312T000000-api-final-fields.md'"
refute "served snapshot does not carry the stale draft body" \
  bash -c "grep -q body-api-draft-fields-v1 '$RUNOVR2/upgrades/20260312T000000-api-final-fields.md'"
expect "the final identity's snapshot carries the machine-read fields the draft lacked" \
  bash -c "grep -q '^intent:' '$RUNOVR2/upgrades/20260312T000000-api-final-fields.md'"

# Fidelity signal (US6): a body with none of intent:/before:/verify-script:/verify:
# is flagged; a well-formed one (the final identity above) is not.
expect "fidelity signal fires for a body with no machine-read fields" \
  bash -c "grep -q '20260315T000000-api-no-fields.md' '$SANDBOX/cc-ovr2.log'"
refute "fidelity signal does NOT fire for the fully-fielded final identity" \
  bash -c "grep -q '20260312T000000-api-final-fields.md' '$SANDBOX/cc-ovr2.log'"

# =============================================================================
fi

if t "collect-common.sh — a rename with the add out of range still yields the file once, at the final slug"; then
# BASE = api/v1.2.31, tagged right after the amend but before the rename: the
# add and the amend are both OUTSIDE this range, only the rename is inside.
cat > "$CC/component-ovr3.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.31
)
EOF
RUNOVR3=$CC/state-ovr3; mkdir -p "$RUNOVR3"
RUN=$RUNOVR3 COMPONENT_GOMOD=$CC/component-ovr3.mod TEMPLATE_GOMOD=$CC/template-ovr.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN REF_OVERRIDES=$CC/ref-overrides.tsv \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-ovr3.log"
expect "collect-common.sh (ref-override, BASE past the amend) exits 0" test $? -eq 0
ovrmod3() { awk -F'\t' -v m="$1" '$2==m{print $3}' "$RUNOVR3/common-upgrades-added.tsv"; }
expect "rename-only-in-range file (add and amend predate BASE) still collected once, at its final slug" \
  test "$(ovrmod3 api | grep -c api-final-fields)" = 1
if ovrmod3 api | grep -q api-draft-fields; then fail "served under the pre-rename slug"; else pass "not served under the pre-rename slug"; fi
refute "not double-listed in the modified list either (pure rename, no content change in range)" \
  bash -c "grep -q api-draft-fields '$RUNOVR3/common-upgrades-modified.txt' 2>/dev/null"

# =============================================================================
fi

if t "collect-common.sh emits common-upgrades-modified.txt for a file amended after this component's BASE"; then
# common-first was added under module "common" at tag common/v1.3.22 (fixture
# above); amend it in a later commit so the SAME module range that already
# includes its addition, when narrowed to start AT v1.3.22, sees only the
# amendment — this component "already saw" common-first, and the amendment is a
# correction, not a new file.
cd "$CMN"
cat > .kairos-updates/common/20260102T000000-common-first.md <<'UF'
# common-first

intent: consumer must migrate call-sites after common-first (corrected).

before: OldSymbol_common-first
after:  NewSymbol_common-first

verify-script: ! grep -rn 'OldSymbol_common-first' --include='*.go' .

## Details
body-common-first-amended
UF
git add -A && git commit -qm "c6 amend common-first (correction)"
git tag common/v1.3.26
cd "$CC"
cat > component-modlist.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/common v1.3.22
)
EOF
cat > template-modlist.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/common v1.3.26
)
EOF
RUNMOD=$CC/state-modlist; mkdir -p "$RUNMOD"
RUN=$RUNMOD COMPONENT_GOMOD=$CC/component-modlist.mod TEMPLATE_GOMOD=$CC/template-modlist.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-modlist.log"
expect "collect-common.sh (amended-before-BASE) exits 0" test $? -eq 0
expect "amended-before-BASE file lands in common-upgrades-modified.txt" \
  grep -q common-first "$RUNMOD/common-upgrades-modified.txt"
refute "amended-before-BASE file is NOT also in common-upgrades-added.txt" \
  grep -q common-first "$RUNMOD/common-upgrades-added.txt"
expect "modified-list snapshot carries the amended body" \
  bash -c "grep -q body-common-first-amended '$RUNMOD/upgrades/20260102T000000-common-first.md'"

# =============================================================================
fi

if t "collect-common.sh — tag-bounded append-only range is unaffected (regression lock)"; then
# The RUNCOL fixture (above) has no renames and no amendments: the R/M passes
# must find nothing, so collection output is exactly what add-only collection
# already produced — the change is self-neutralizing on released history.
expect "tag-bounded range: no common-upgrades-modified.txt entries" \
  bash -c "[ ! -s '$RUNCOL/common-upgrades-modified.txt' ]"
expect "tag-bounded range: api added count unchanged (3 files, none renamed/amended)" \
  test "$(modpaths api | grep -c .)" = 3
expect "tag-bounded range: common added count unchanged (2 files)" \
  test "$(modpaths common | grep -c .)" = 2

cd "$SANDBOX"
# =============================================================================
fi

if t "collect-common.sh reads a local-path replace whose directory contains a SPACE"; then
# The replace projection used to be SPACE-joined, so `=> "../My Code/common"` — legal
# go.mod (quoted) and routine on macOS — shifted every field right: the `-` marking
# "no version" landed in the path column, the LOCAL: arm was never entered, the module
# resolved to a nonsense TARGET, went out as skip-downgrade, and dropped every one of
# its upgrade-files at exit 0. TAB-delimited, the same row reads correctly. Regression.
cd "$CC"
LCSP="$CC/local common"
mkdir -p "$LCSP/toolkit"
( cd "$LCSP" && git init -q -b main \
  && echo "module $COMMON/toolkit" > toolkit/go.mod \
  && git add -A && git commit -qm "toolkit v1.0.38" && git tag toolkit/v1.0.38 \
  && echo "// unreleased" >> toolkit/go.mod && git commit -qam "toolkit unreleased HEAD" )
SP_HEAD=$(git -C "$LCSP" rev-parse --short HEAD)
SP_TOP=$(git -C "$LCSP" rev-parse --show-toplevel)
cat > "$CC/template-lpsp.mod" <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/toolkit v1.0.39
)

replace $COMMON/toolkit => "./local common/toolkit"
EOF
RUNSP=$CC/state-lpsp; rm -rf "$RUNSP"; mkdir -p "$RUNSP"
RUN=$RUNSP COMPONENT_GOMOD=$CC/component-lp.mod TEMPLATE_GOMOD=$CC/template-lpsp.mod \
  TEMPLATE_GOMOD_DIR=$CC COMMON_REPO_PATH=$COMMON \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-lpsp.log"
expect "collect-common.sh (space in local-path replace) exits 0" test $? -eq 0
ressp() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNSP/common-resolution.tsv"; }
if [[ "$(ressp toolkit 6)" = collect ]]; then pass "space-bearing local-path replace takes the LOCAL: arm (collect)"; else fail "space-bearing local-path decision = $(ressp toolkit 6) (want collect)"; fi
if ressp toolkit 7 | grep -q 'local-path replace'; then pass "the detail records it as a local-path replace"; else fail "detail is not a local-path replace: $(ressp toolkit 7)"; fi
if [[ "$(ressp toolkit 3)" = "$SP_HEAD" ]]; then pass "TARGET is the space-path clone's HEAD"; else fail "TARGET = $(ressp toolkit 3) (want $SP_HEAD)"; fi
if [[ "$(ressp toolkit 8)" = "$SP_TOP" ]]; then pass "the repo column is the space-bearing clone"; else fail "repo column = $(ressp toolkit 8) (want $SP_TOP)"; fi
refute "and it is NOT recorded as a downgrade (the old silent drop)" \
  bash -c "test \"\$(awk -F'\t' '\$1==\"toolkit\"{print \$6}' '$RUNSP/common-resolution.tsv')\" = skip-downgrade"

# A TAB (or a newline) in a local-path replace target is representable in go.mod
# (`=> "./a\tb"`) but NOT in a positionally-read TAB-delimited projection — the one
# shape no delimiter choice fixes. It is refused BY NAME rather than misread, the
# same call the collection walks make for a TAB in an upgrade-file name.
cat > "$CC/template-lptab.mod" <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/toolkit v1.0.39
)

replace $COMMON/toolkit => "./local\tcommon/toolkit"
EOF
RUNTB=$CC/state-lptab; rm -rf "$RUNTB"; mkdir -p "$RUNTB"
RUN=$RUNTB COMPONENT_GOMOD=$CC/component-lp.mod TEMPLATE_GOMOD=$CC/template-lptab.mod \
  TEMPLATE_GOMOD_DIR=$CC COMMON_REPO_PATH=$COMMON \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" >/dev/null 2> "$SANDBOX/cc-lptab.log"
TB_RC=$?
if [[ "$TB_RC" -eq 1 ]]; then pass "a TAB in a local-path replace target is a hard stop (exit 1)"; else fail "TAB-bearing replace target exited $TB_RC (want 1)"; fi
expect "the refusal names the replace row and the remedy" \
  bash -c "grep -qi 'replace' '$SANDBOX/cc-lptab.log' && grep -qi 'remedy' '$SANDBOX/cc-lptab.log'"
refute "a TAB-bearing replace writes no resolution rows to be read as complete" \
  bash -c "test -s '$RUNTB/common-resolution.tsv'"

# =============================================================================
fi

if t "collect-common.sh honors a version-qualified replace only for the version it names"; then
# `replace M v1.2.0 => M v1.2.5` (pinning past one bad release) applies ONLY when the
# required version is exactly v1.2.0; the projection discarded Old.Version entirely,
# so every qualified replace was applied to whatever the require said and the range
# endpoint moved to a version the replace never named. Both directions asserted.
cd "$CC"
qual_run() { # qual_run <label> <template-gomod-body-file>
  local run=$CC/state-qual-$1; rm -rf "$run"; mkdir -p "$run"
  RUN=$run COMPONENT_GOMOD=$CC/component-col.mod TEMPLATE_GOMOD="$2" \
    COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
    PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-qual-$1.log"
}
qual() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$CC/state-qual-$3/common-resolution.tsv"; }
qual_is() { # qual_is <label> <module> <col> <want>
  local got; got=$(qual "$2" "$3" "$1")
  if [[ "$got" = "$4" ]]; then pass "$1: $2 col$3 = ${4:-<empty>}"; else fail "$1: $2 col$3 = ${got:-<none>} (want $4)"; fi
}

# Old.Version does NOT match the require -> the replace is inert, the require wins.
cat > "$CC/template-qual-inert.mod" <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.3.0
    $COMMON/common v1.3.25
)

replace $COMMON/api v1.2.0 => $COMMON/api v9.9.9
EOF
qual_run inert "$CC/template-qual-inert.mod"
expect "collect-common.sh (inert qualified replace) exits 0" test $? -eq 0
qual_is inert api 3 v1.3.0
qual_is inert api 6 collect
refute "an inert qualified replace does not drag the endpoint to a version nothing pins" \
  grep -q v9.9.9 "$CC/state-qual-inert/common-resolution.tsv"

# Old.Version DOES match the require -> the replace applies, as it always did.
cat > "$CC/template-qual-live.mod" <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.2.50
    $COMMON/common v1.3.25
)

replace $COMMON/api v1.2.50 => $COMMON/api v1.3.0
EOF
qual_run live "$CC/template-qual-live.mod"
expect "collect-common.sh (live qualified replace) exits 0" test $? -eq 0
qual_is live api 3 v1.3.0
qual_is live api 6 collect

# Both forms name the module: the qualified one wins for the version it names
# (go's own precedence), so the unqualified v1.2.40 must NOT be the endpoint.
cat > "$CC/template-qual-both.mod" <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.2.50
    $COMMON/common v1.3.25
)

replace $COMMON/api => $COMMON/api v1.2.40

replace $COMMON/api v1.2.50 => $COMMON/api v1.3.0
EOF
qual_run both "$CC/template-qual-both.mod"
expect "collect-common.sh (both replace forms) exits 0" test $? -eq 0
qual_is both api 3 v1.3.0

# =============================================================================
fi

if t "collect-common.sh resolves the component's BASE through its own replace directives"; then
# BASE came from the component's `require` only, ignoring its `replace` directives —
# asymmetric with the TARGET side, which has always honored them. Both directions
# were silently wrong, and both are asserted here.
cd "$CC"
base_run() { # base_run <label> <component-gomod>
  local run=$CC/state-base-$1; rm -rf "$run"; mkdir -p "$run"
  RUN=$run COMPONENT_GOMOD="$2" TEMPLATE_GOMOD=$CC/template-col.mod \
    COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
    PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-base-$1.log"
}
basecol() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$CC/state-base-$3/common-resolution.tsv"; }
base_is() { # base_is <label> <module> <col> <want>
  local got; got=$(basecol "$2" "$3" "$1")
  if [[ "$got" = "$4" ]]; then pass "$1: $2 col$3 = ${4:-<empty>}"; else fail "$1: $2 col$3 = ${got:-<none>} (want $4)"; fi
}

# 1. Replaced DOWN: the require says v1.9.9, but the component builds v1.2.30 — the
# migrations between v1.2.30 and the template's v1.3.0 all apply. Read from the
# require alone this was skip-downgrade, dropping every one of them.
cat > "$CC/component-basedown.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.9.9
)

replace $COMMON/api => $COMMON/api v1.2.30
EOF
base_run down "$CC/component-basedown.mod"
expect "collect-common.sh (component replaced down) exits 0" test $? -eq 0
base_is down api 2 v1.2.30
base_is down api 6 collect
expect "the migrations the component really needs are collected, not dropped as a downgrade" \
  grep -q api-first "$CC/state-base-down/common-upgrades-added.tsv"

# 2. Replaced UP: the require says v1.2.30, but the component already builds v1.3.0 —
# the template's target. Read from the require alone, upgrade-files it had already
# adopted were served again as if they were new work.
cat > "$CC/component-baseup.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.30
)

replace $COMMON/api => $COMMON/api v1.3.0
EOF
base_run up "$CC/component-baseup.mod"
expect "collect-common.sh (component replaced up) exits 0" test $? -eq 0
base_is up api 2 v1.3.0
base_is up api 6 skip-downgrade
refute "nothing already-adopted is re-served" \
  bash -c "test -s '$CC/state-base-up/common-upgrades-added.tsv'"

# 3. The component's qualified replace obeys the same Old.Version rule as the
# template's: it names v1.0.0, the require is v1.2.30, so it is inert.
cat > "$CC/component-basequal.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.30
)

replace $COMMON/api v1.0.0 => $COMMON/api v1.3.0
EOF
base_run qual "$CC/component-basequal.mod"
expect "collect-common.sh (inert component qualified replace) exits 0" test $? -eq 0
base_is qual api 2 v1.2.30
base_is qual api 6 collect

# 4. Co-development on the CONSUMER side, target NOT a git repo: the component
# replaces common with a local directory that isn't a clone (here it doesn't even
# exist). There is no committed history to collect from, so it goes into the batched
# unresolvable funnel with the directory named — never a fabricated endpoint, never a
# plausible-looking skip. (A local dir that IS a git repo collects — story #5 below.)
cat > "$CC/component-baselocal.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.30
)

replace $COMMON/api => ../my-common/api
EOF
base_run local "$CC/component-baselocal.mod"
expect "collect-common.sh (component local-path replace) exits 0 — batched, not crashed" test $? -eq 0
base_is local api 6 unresolvable
expect "the unresolvable detail names the local directory the component builds from" \
  bash -c "awk -F'\t' '\$1==\"api\"' '$CC/state-base-local/common-unresolvable.txt' | grep -q 'my-common/api'"
expect "and it is batched for the orchestrator to surface" \
  grep -q '^api	' "$CC/state-base-local/common-unresolvable.txt"
refute "a non-repo local-path target cannot collect" \
  bash -c "test -s '$CC/state-base-local/common-upgrades-added.tsv'"

# 5. Consumer-side co-development that RESOLVES: the component's own go.mod replaces
# the module with a local git clone AND keeps a `require` pin. That require version is
# the FROM end; the clone's committed history is collected up to its HEAD — the exact
# mirror of the template-side local-path arm. This is the co-dev flow that used to be
# dropped as "BASE names no version"; now the require pin bounds it and the local
# upgrade-file is collected.
LCC=$CC/codev-common
mkdir -p "$LCC/api"
( cd "$LCC" && git init -q -b main \
  && echo "module $COMMON/api" > api/go.mod \
  && git add -A && git commit -qm "api v1.0.0" && git tag api/v1.0.0 \
  && mkdir -p .kairos-updates/api \
  && printf 'intent: codev\nbody-codev-collected\n' > .kairos-updates/api/20260601T000000-codev.md \
  && git add -A && git commit -qm "api unreleased co-dev upgrade-file" )
LCC_HEAD=$(git -C "$LCC" rev-parse --short HEAD)
LCC_TOP=$(git -C "$LCC" rev-parse --show-toplevel)
cat > "$CC/component-codev.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.0.0
)

replace $COMMON/api => ./codev-common/api
EOF
base_run codev "$CC/component-codev.mod"
expect "collect-common.sh (consumer co-dev, resolvable) exits 0" test $? -eq 0
base_is codev api 6 collect
base_is codev api 2 v1.0.0
base_is codev api 3 "$LCC_HEAD"
base_is codev api 8 "$LCC_TOP"
expect "the co-developed local upgrade-file is actually collected from the clone" \
  grep -q 'codev.md' "$CC/state-base-codev/common-upgrades-added.txt"
refute "consumer co-dev is not batched as unresolvable" \
  grep -q '^api	' "$CC/state-base-codev/common-unresolvable.txt"

# 5b. Same setup, but the require pin names a version the clone can't resolve: the
# FROM end can't be bounded, so it is unresolvable — with the BASE named — rather
# than silently walking an empty range.
cat > "$CC/component-codev-badbase.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.9.9
)

replace $COMMON/api => ./codev-common/api
EOF
base_run codevbad "$CC/component-codev-badbase.mod"
expect "collect-common.sh (consumer co-dev, unresolvable BASE) exits 0" test $? -eq 0
base_is codevbad api 6 unresolvable
expect "the detail names the BASE the clone could not resolve" \
  bash -c "awk -F'\t' '\$1==\"api\"' '$CC/state-base-codevbad/common-unresolvable.txt' | grep -q 'v1.9.9'"

# 5c. Dirty co-dev clone warns its uncommitted upgrade-files are invisible — the same
# hygiene warning the template-side arm emits, now reached from the consumer side too.
mkdir -p "$LCC/.kairos-updates/api"
echo "# unstaged" > "$LCC/.kairos-updates/api/20260701T000000-uncommitted.md"
base_run codevdirty "$CC/component-codev.mod"
expect "collect-common.sh (dirty consumer co-dev clone) still exits 0 (non-fatal)" test $? -eq 0
expect "dirty consumer co-dev clone warns its uncommitted upgrade-files are invisible" \
  bash -c "grep -qi 'uncommitted' '$SANDBOX/cc-base-codevdirty.log' && grep -qi 'api' '$SANDBOX/cc-base-codevdirty.log'"
rm -f "$LCC/.kairos-updates/api/20260701T000000-uncommitted.md"

# 5d. Orphan local-path replace: a common module the component replaces with a local
# directory but never `require`s. The resolution loop iterates require lines, so this
# module is invisible to it — without the post-loop orphan scan its co-developed
# upgrade-files would vanish silently, the exact drop the local-path arms exist to
# prevent. It has no require pin to bound the FROM end, so it is funneled to the
# batched unresolvable question with the remedy named. Note the local dir here IS a
# valid git clone ($LCC/api): a real BASE, not the missing target, is what's absent,
# so "resolvable clone" must not be mistaken for "collectable range".
cat > "$CC/component-codev-noreq.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/common v1.4.0
)

replace $COMMON/api => ./codev-common/api
EOF
base_run codevnoreq "$CC/component-codev-noreq.mod"
expect "collect-common.sh (consumer replace, no require) exits 0" test $? -eq 0
base_is codevnoreq api 6 unresolvable
expect "the orphan replace is batched for the orchestrator to surface" \
  grep -q '^api	' "$CC/state-base-codevnoreq/common-unresolvable.txt"
expect "the unresolvable detail names the missing-require remedy" \
  bash -c "awk -F'\t' '\$1==\"api\"' '$CC/state-base-codevnoreq/common-unresolvable.txt' | grep -qi 'require'"
refute "an orphan replace never silently collects" \
  bash -c "awk -F'\t' '\$1==\"api\" && \$6==\"collect\"' '$CC/state-base-codevnoreq/common-resolution.tsv' | grep -q ."

# =============================================================================
fi

if t "collect-common.sh resolves a pseudo-version BASE against a local-path TARGET clone"; then
# The local-path arm checked BASE with a literal `tag_exists_in <repo>
# <module>/<base>`, while every other endpoint in the script goes through range_ref.
# A pseudo-version BASE is by definition untagged, so this arm always answered
# 'unresolvable' with a remedy nobody can act on ("lacks BASE tag
# toolkit/v1.0.39-0.2026…-<sha>") — blocking exactly the co-development flow that
# the pseudo-version machinery and this arm both exist to serve. Regression.
cd "$CC"
TK_C1_12=$(git -C "$LC" rev-parse --short=12 HEAD~1)
cat > "$CC/component-lpps.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/toolkit v1.0.39-0.20260101000000-$TK_C1_12
)
EOF
RUNLPPS=$CC/state-lpps; rm -rf "$RUNLPPS"; mkdir -p "$RUNLPPS"
RUN=$RUNLPPS COMPONENT_GOMOD=$CC/component-lpps.mod TEMPLATE_GOMOD=$CC/template-lp.mod \
  TEMPLATE_GOMOD_DIR=$CC COMMON_REPO_PATH=$COMMON \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-lpps.log"
expect "collect-common.sh (pseudo BASE, local-path TARGET) exits 0" test $? -eq 0
reslpps() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNLPPS/common-resolution.tsv"; }
if [[ "$(reslpps toolkit 6)" = collect ]]; then pass "pseudo-version BASE resolves via its embedded commit in the local clone"; else fail "pseudo BASE + local-path decision = $(reslpps toolkit 6) (want collect)"; fi
if [[ "$(reslpps toolkit 3)" = "$TK_HEAD" ]]; then pass "TARGET is still the local clone's HEAD"; else fail "TARGET = $(reslpps toolkit 3) (want $TK_HEAD)"; fi
refute "it is not batched as unresolvable with an unactionable missing-tag remedy" \
  grep -q '^toolkit	' "$RUNLPPS/common-unresolvable.txt"

# The guard still fires for a BASE the local clone genuinely cannot resolve — a
# pseudo-version whose commit is in no clone at all.
cat > "$CC/component-lpps2.mod" <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/toolkit v1.0.39-0.20260101000000-abcdefabcdef
)
EOF
RUNLPPS2=$CC/state-lpps2; rm -rf "$RUNLPPS2"; mkdir -p "$RUNLPPS2"
RUN=$RUNLPPS2 COMPONENT_GOMOD=$CC/component-lpps2.mod TEMPLATE_GOMOD=$CC/template-lp.mod \
  TEMPLATE_GOMOD_DIR=$CC COMMON_REPO_PATH=$COMMON \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-lpps2.log"
expect "collect-common.sh (unresolvable pseudo BASE, local-path TARGET) exits 0" test $? -eq 0
reslpps2() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNLPPS2/common-resolution.tsv"; }
if [[ "$(reslpps2 toolkit 6)" = unresolvable ]]; then pass "a BASE commit in no clone is still unresolvable (guard intact)"; else fail "absent pseudo BASE decision = $(reslpps2 toolkit 6) (want unresolvable)"; fi
expect "and its detail names what was looked for" \
  bash -c "awk -F'\t' '\$1==\"toolkit\"{print \$7}' '$RUNLPPS2/common-resolution.tsv' | grep -q abcdefabcdef"

# =============================================================================
fi

if t "collect-common.sh hard-fails on a REF_OVERRIDES path it cannot read, and tolerates CRLF"; then
# REF_OVERRIDES is the operator's ANSWER to the batched unresolvable prompt. A
# set-but-unreadable path was silently read as "no overrides at all", so the answer
# vanished and every listed module reported the same diagnostic it had before they
# answered — a module that looked stuck no matter what they wrote.
cd "$CC"
ovr_run() { # ovr_run <label> <ref-overrides-path>
  local run=$CC/state-ovrbad-$1; rm -rf "$run"; mkdir -p "$run"
  RUN=$run COMPONENT_GOMOD=$CC/component-ovr.mod TEMPLATE_GOMOD=$CC/template-ovr.mod \
    COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN REF_OVERRIDES="$2" \
    PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" >/dev/null 2> "$SANDBOX/cc-ovrbad-$1.log"
}

ovr_run absent "$CC/no-such-overrides.tsv"
OVR_ABS_RC=$?
if [[ "$OVR_ABS_RC" -eq 1 ]]; then pass "a REF_OVERRIDES path that does not exist exits 1"; else fail "absent REF_OVERRIDES exited $OVR_ABS_RC (want 1)"; fi
expect "the refusal names the path the operator actually wrote" \
  grep -q 'no-such-overrides.tsv' "$SANDBOX/cc-ovrbad-absent.log"
refute "an unreadable REF_OVERRIDES never resolves modules as if no answer was given" \
  bash -c "test -s '$CC/state-ovrbad-absent/common-resolution.tsv'"

mkdir -p "$CC/overrides-is-a-dir"
ovr_run dir "$CC/overrides-is-a-dir"
OVR_DIR_RC=$?
if [[ "$OVR_DIR_RC" -eq 1 ]]; then pass "a directory at REF_OVERRIDES exits 1"; else fail "directory REF_OVERRIDES exited $OVR_DIR_RC (want 1)"; fi
expect "a directory is diagnosed as a directory, not as 'not readable'" \
  grep -qi 'director' "$SANDBOX/cc-ovrbad-dir.log"

if [[ "$(id -u)" -eq 0 ]]; then
  pass "unreadable REF_OVERRIDES case skipped (running as root)"
else
  printf 'api\tcodev-api\n' > "$CC/ref-overrides-noread.tsv"
  chmod 000 "$CC/ref-overrides-noread.tsv"
  ovr_run noread "$CC/ref-overrides-noread.tsv"
  OVR_NR_RC=$?
  chmod 644 "$CC/ref-overrides-noread.tsv" 2>/dev/null || true
  if [[ "$OVR_NR_RC" -eq 1 ]]; then pass "an unreadable REF_OVERRIDES exits 1"; else fail "unreadable REF_OVERRIDES exited $OVR_NR_RC (want 1)"; fi
fi

# A CRLF-authored override file yielded the ref `codev-api<CR>`, which git cannot
# resolve — and the resulting "ref override 'codev-api' not found in common mirror"
# names a ref that looks exactly right on screen (record-context.sh:68 refuses a CR
# for the same invisibility). The CR is stripped where it can only be a line ending.
printf 'api\tcodev-api\r\n' > "$CC/ref-overrides-crlf.tsv"
RUNCRLF=$CC/state-ovr-crlf; rm -rf "$RUNCRLF"; mkdir -p "$RUNCRLF"
RUN=$RUNCRLF COMPONENT_GOMOD=$CC/component-ovr.mod TEMPLATE_GOMOD=$CC/template-ovr.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN REF_OVERRIDES=$CC/ref-overrides-crlf.tsv \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-ovr-crlf.log"
expect "collect-common.sh (CRLF override file) exits 0" test $? -eq 0
rescrlf() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNCRLF/common-resolution.tsv"; }
if [[ "$(rescrlf api 6)" = collect ]]; then pass "a CRLF-authored override still routes the module to collect"; else fail "CRLF override decision = $(rescrlf api 6) (want collect)"; fi
refute "no invisible-CR 'ref override not found' diagnostic" \
  bash -c "grep -q 'not found' '$RUNCRLF/common-resolution.tsv'"
expect "the branch-only upgrade-file is collected through the CRLF override" \
  grep -q api-codev "$RUNCRLF/common-upgrades-added.tsv"

cd "$SANDBOX"
# =============================================================================
fi

echo "fixture: common repo whose api upgrade-files carry \" and \\ in their names"
# `core.quotepath=off` governs bytes >= 0x80 ONLY, so a `"` or a `\` in a filename
# still arrived C-quoted from `git log --name-only` and failed the
# `index($0, d) == 1` prefix filter on EVERY collection walk — the add pass, the
# modified-list pass, the modified body-override pass, and the rename map that
# feeds all three. The file then vanished: nothing in common-upgrades-added.txt,
# nothing in snapshot-refusals.tsv, no WARN, exit 0 — a shipped common-library
# migration step silently skipped. These are legal filenames, so they must be
# COLLECTED, not refused. Own fixture repo, so no ASCII-only block above can
# satisfy the assertions.
CQ=$SANDBOX/common-quoted
QCPRE='20260101T000000-q"pre'       # exists before BASE, amended in range
QCW='20260201T000000-we"ird'        # added in range, then amended
QCB='20260202T000000-back\slash'    # added in range, backslash
QCD='20260203T000000-q"draft'       # added in range, then RENAMED
QCF='20260204T000000-q"final'       # ... to this
mkdir -p "$CQ/.kairos-updates/api" && cd "$CQ"
git init -q -b main
printf 'intent: pre\nbody-qpre-v1\n' > ".kairos-updates/api/$QCPRE.md"
echo seed > seed.txt
git add -A && git commit -qm "q0"; git tag api/v1.0.0
printf 'intent: weird\nbody-qweird-v1\n'  > ".kairos-updates/api/$QCW.md"
printf 'intent: slash\nbody-qbackslash\n' > ".kairos-updates/api/$QCB.md"
printf 'intent: draft\nbody-qrenamed\n'   > ".kairos-updates/api/$QCD.md"
git add -A && git commit -qm "q1 add"
printf 'intent: weird\nbody-qweird-v2-amended\n' > ".kairos-updates/api/$QCW.md"
printf 'intent: pre\nbody-qpre-v2\n'            > ".kairos-updates/api/$QCPRE.md"
git add -A && git commit -qm "q2 amend"
git mv ".kairos-updates/api/$QCD.md" ".kairos-updates/api/$QCF.md"
git commit -qm "q3 rename"; git tag api/v1.1.0

if t "collect-common.sh collects quote- and backslash-bearing upgrade-file names"; then
cd "$CC"
cat > component-q.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.0.0
)
EOF
cat > template-q.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.1.0
)
EOF
RUNQ=$CC/state-q; mkdir -p "$RUNQ"
RUN=$RUNQ COMPONENT_GOMOD=$CC/component-q.mod TEMPLATE_GOMOD=$CC/template-q.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CQ \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-q.log"
expect "collect-common.sh (quoted names) exits 0" test $? -eq 0

expect "the quote-named upgrade-file is collected, under its RAW name" \
  grep -qxF -- ".kairos-updates/api/$QCW.md" "$RUNQ/common-upgrades-added.txt"
expect "the backslash-named upgrade-file is collected, under its RAW name" \
  grep -qxF -- ".kairos-updates/api/$QCB.md" "$RUNQ/common-upgrades-added.txt"
refute "no C-quoted spelling reaches the added list" \
  grep -q '\\"' "$RUNQ/common-upgrades-added.txt"
expect "the quote-named row carries its module and add-sha" \
  bash -c "P='.kairos-updates/api/$QCW.md' awk -F'\t' '\$3==ENVIRON[\"P\"] && \$2==\"api\" && \$1 ~ /^[0-9a-f]{40}$/' '$RUNQ/common-upgrades-added.tsv' | grep -q ."
expect "the quote-named body is snapshotted from its newest AMEND" \
  grep -q body-qweird-v2-amended "$RUNQ/upgrades/$QCW.md"
expect "the backslash-named body is snapshotted" \
  grep -q body-qbackslash "$RUNQ/upgrades/$QCB.md"
# The rename map is its own text-parsed walk (`--name-status`, no -z): a quoted
# path there means the pre-rename identity never resolves to its final one, so the
# file is served twice, or under a slug that no longer exists.
expect "a renamed quote-named file is collected under its FINAL identity" \
  grep -qxF -- ".kairos-updates/api/$QCF.md" "$RUNQ/common-upgrades-added.txt"
refute "and NOT also under its pre-rename identity" \
  grep -qxF -- ".kairos-updates/api/$QCD.md" "$RUNQ/common-upgrades-added.txt"
expect "the renamed file's body is snapshotted under the final slug" \
  grep -q body-qrenamed "$RUNQ/upgrades/$QCF.md"
expect "a quote-named file amended (not added) in range lands in the modified list" \
  grep -qxF -- ".kairos-updates/api/$QCPRE.md" "$RUNQ/common-upgrades-modified.txt"
expect "its snapshot carries the AMENDED body, not the pre-BASE one" \
  grep -q body-qpre-v2 "$RUNQ/upgrades/$QCPRE.md"
refute "nothing was refused — a legal filename is collected, not skipped" \
  test -s "$RUNQ/snapshot-refusals.tsv"

# =============================================================================
fi

echo "fixture: common repo with a TAB in an api upgrade-file name"
CQT=$SANDBOX/common-tabname
QT_NAME=$(printf '20260401T000000-tab\tname')
mkdir -p "$CQT/.kairos-updates/api" && cd "$CQT"
git init -q -b main
echo seed > seed.txt
git add -A && git commit -qm "qt0"; git tag api/v1.0.0
printf 'intent: tabbed\nbody-qtabbed\n' > ".kairos-updates/api/$QT_NAME.md"
git add -A && git commit -qm "qt1"; git tag api/v1.1.0

if t "a TAB-bearing common upgrade-file name is a named hard stop, not a silent skip"; then
# common-upgrades-added.txt is a line list and common-upgrades-added.tsv a
# TAB-delimited line record, so a TAB (or newline) in the name cannot ride EITHER
# and no raw-bytes plumbing makes it representable. The one behavior that is not
# acceptable is the old one: drop it and report OK, with a shipped common-library
# migration step missing from the plan.
cd "$CC"
cat > component-qt.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.0.0
)
EOF
cat > template-qt.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.1.0
)
EOF
RUNQT=$CC/state-qt; mkdir -p "$RUNQT"
RUN=$RUNQT COMPONENT_GOMOD=$CC/component-qt.mod TEMPLATE_GOMOD=$CC/template-qt.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CQT \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-qt.log"
QT_RC=$?
if [[ "$QT_RC" -ne 0 ]]; then pass "collection refuses a TAB-bearing upgrade-file name (exit $QT_RC)"; else fail "collection accepted a TAB-bearing upgrade-file name (exit 0)"; fi
expect "the refusal names the offending upgrade-file" \
  grep -q 'tab.*name' "$SANDBOX/cc-qt.log"
expect "the refusal states the remedy that works: rename it upstream" \
  bash -c "grep -qi 'rename' '$SANDBOX/cc-qt.log'"
refute "no partial collection list is left behind to be read as complete" \
  test -s "$RUNQT/common-upgrades-added.txt"

cd "$SANDBOX"
# =============================================================================
fi

echo "fixture: common repo with legacy root UPGRADE.md straddling the api ceiling"
CLEG=$SANDBOX/common-legacy
mkdir -p "$CLEG/.kairos-updates/api" && cd "$CLEG"
git init -q -b main
echo "legacy notes v0" > UPGRADE.md
git add -A && git commit -qm "L0"; git tag api/v1.2.20
L0_SHA=$(git rev-parse HEAD)
echo "legacy: rename Foo" >> UPGRADE.md
git commit -qam "L1 legacy rename"; git tag api/v1.2.25
LEG_A=$(git rev-parse HEAD)
echo "legacy: remove Bar" >> UPGRADE.md
git commit -qam "L2 legacy remove"; git tag api/v1.2.26           # == ceiling
LEG_B=$(git rev-parse HEAD)
echo "post-ceiling note" >> UPGRADE.md
git commit -qam "L3 above ceiling"; git tag api/v1.2.30
echo "another post-ceiling note" >> UPGRADE.md
git commit -qam "L4 above ceiling"; git tag api/v1.2.35

if t "legacy UPGRADE.md captured over BASE..ceiling only when BASE <= ceiling"; then
cd "$CC"
cat > component-leg.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.20
)
EOF
cat > template-leg.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.2.30
)
EOF
RUNLEG=$CC/state-leg; mkdir -p "$RUNLEG"
RUN=$RUNLEG COMPONENT_GOMOD=$CC/component-leg.mod TEMPLATE_GOMOD=$CC/template-leg.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CLEG \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-leg.log"
expect "collect-common.sh (legacy below ceiling) exits 0" test $? -eq 0
expect "legacy commit in range (v1.2.25) captured"  grep -q "$LEG_A" "$RUNLEG/common-legacy-upgrade-commits.txt"
expect "legacy commit at ceiling (v1.2.26) captured" grep -q "$LEG_B" "$RUNLEG/common-legacy-upgrade-commits.txt"
expect "above-ceiling UPGRADE.md commit NOT captured" \
  bash -c "! grep -q \"\$(git -C '$CLEG' rev-parse api/v1.2.30)\" '$RUNLEG/common-legacy-upgrade-commits.txt'"

cat > component-leg2.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.30
)
EOF
cat > template-leg2.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.2.35
)
EOF
RUNLEG2=$CC/state-leg2; mkdir -p "$RUNLEG2"
RUN=$RUNLEG2 COMPONENT_GOMOD=$CC/component-leg2.mod TEMPLATE_GOMOD=$CC/template-leg2.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CLEG \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-leg2.log"
expect "collect-common.sh (legacy above ceiling) exits 0" test $? -eq 0
expect "BASE above ceiling -> legacy UPGRADE.md ignored (empty capture)" \
  bash -c "! test -s '$RUNLEG2/common-legacy-upgrade-commits.txt'"

# =============================================================================
fi

if t "legacy UPGRADE.md captured for a pseudo-version BASE (routed through range_ref)"; then
# Regression: BASE pinned at a pseudo-version (embedding L0's commit, before
# any tag) used to build the legacy git-log range from the LITERAL tag
# "api/v0.0.0-...-<sha>", which never exists — the range failed "bad revision",
# was swallowed by `|| true`, and captured zero legacy commits, silently. Both
# endpoints must now go through range_ref like the normal walk does, so this
# resolves to L0's commit and captures the same legacy notes a tagged BASE at
# the same commit would.
cd "$CC"
L0_PSEUDO="v0.0.0-20260101000000-$(echo "$L0_SHA" | cut -c1-12)"
cat > component-legps.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api $L0_PSEUDO
)
EOF
cat > template-legps.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.2.30
)
EOF
RUNLEGPS=$CC/state-legps; mkdir -p "$RUNLEGPS"
RUN=$RUNLEGPS COMPONENT_GOMOD=$CC/component-legps.mod TEMPLATE_GOMOD=$CC/template-legps.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CLEG \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-legps.log"
expect "collect-common.sh (legacy pseudo BASE) exits 0" test $? -eq 0
reslegps() { awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c}' "$RUNLEGPS/common-resolution.tsv"; }
if [[ "$(reslegps api 6)" = collect ]]; then pass "pseudo BASE below ceiling -> collect"; else fail "pseudo-legacy decision = $(reslegps api 6)"; fi
expect "legacy commit in range (v1.2.25) captured for pseudo BASE" \
  grep -q "$LEG_A" "$RUNLEGPS/common-legacy-upgrade-commits.txt"
expect "legacy commit at ceiling (v1.2.26) captured for pseudo BASE" \
  grep -q "$LEG_B" "$RUNLEGPS/common-legacy-upgrade-commits.txt"

# =============================================================================
fi

if t "consumer-facing common upgrade-file round-trips through the field contract"; then
UF=$RUNCOL/upgrades/20260101T000000-api-first.md
expect "collected common upgrade-file has intent:"        grep -q '^intent:' "$UF"
expect "collected common upgrade-file has before:"        grep -q '^before:' "$UF"
expect "collected common upgrade-file has after:"         grep -q '^after:' "$UF"
expect "collected common upgrade-file has a verify field" bash -c "grep -qE '^(verify-script|verify):' '$UF'"
expect "collected common upgrade-file has ## Details"     grep -q '^## Details' "$UF"
mkdir -p "$CC/fake-component" && ( cd "$CC/fake-component" && echo 'package p' > main.go )
VS=$(sed -n 's/^verify-script:[[:space:]]*//p' "$UF")
( cd "$CC/fake-component" && eval "$VS" ) >/dev/null 2>&1
expect "consumer-facing verify-script exits 0 when the old symbol is absent" test $? -eq 0


fi

# =============================================================================
if t "collect-common.sh fails closed when a collection output or the snapshot dir is blocked"; then
# F11: the collection-stage output truncations and snapshot dir used to be
# fail-OPEN (unchecked `: >` / `mkdir -p`), so a stale list survived or every
# snapshot body was swallowed while the script still reported OK, exit 0 — the
# same "partial list read as complete" the resolution stage already guards.
cd "$CC"
cat > component-fc.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.2.30
    $COMMON/common v1.3.20
)
EOF
cat > template-fc.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.3.0
    $COMMON/common v1.3.25
)
EOF

# (a) An output list that cannot be truncated (a DIRECTORY sits where the file
# goes) is a hard refusal, not a silent collect over a stale list. A directory —
# not chmod — so root does not bypass it (no root-bypass caveat needed).
RUNFC=$CC/state-fc; mkdir -p "$RUNFC/common-upgrades-added.txt"
RUN=$RUNFC COMPONENT_GOMOD=$CC/component-fc.mod TEMPLATE_GOMOD=$CC/template-fc.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-fc.log"
FC_RC=$?
if [[ "$FC_RC" -ne 0 ]]; then pass "a blocked output truncation refuses (exit $FC_RC)"; else fail "a blocked output truncation was accepted (exit 0)"; fi
expect "the refusal names the un-truncatable output file" \
  grep -q 'common-upgrades-added.txt' "$SANDBOX/cc-fc.log"
refute "no green 'OK: common resolution written' on a blocked truncation" \
  grep -q 'OK: common resolution written' "$SANDBOX/cc-fc.log"

# (b) A non-directory blocking $RUN/upgrades makes mkdir fail — every snapshot body
# would otherwise be swallowed; refuse instead.
RUNMK=$CC/state-mk; mkdir -p "$RUNMK"; : > "$RUNMK/upgrades"
RUN=$RUNMK COMPONENT_GOMOD=$CC/component-fc.mod TEMPLATE_GOMOD=$CC/template-fc.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CMN \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-mk.log"
MK_RC=$?
if [[ "$MK_RC" -ne 0 ]]; then pass "a non-dir blocking the snapshot dir refuses (exit $MK_RC)"; else fail "a blocked snapshot dir was accepted (exit 0)"; fi
expect "the refusal names the snapshot dir" \
  grep -q 'upgrades' "$SANDBOX/cc-mk.log"
refute "no green 'OK: common resolution written' on a blocked snapshot dir" \
  grep -q 'OK: common resolution written' "$SANDBOX/cc-mk.log"

cd "$SANDBOX"
# =============================================================================
fi

# =============================================================================
if t "collect-common.sh refuses a corrupt mirror whose collection walk fails, rather than reporting an empty upgrade set"; then
# F11, the walk half: resolution verifies both endpoints resolve to COMMIT objects,
# so a `collect` row is written — but a mirror missing the TREE the walk must read
# fails `git log --name-only` (exit 128). That failure used to be swallowed by
# `2>/dev/null … || true`, yielding an EMPTY common-upgrades-added.txt and exit 0.
# It must now be a named refusal with the partial lists torn down.
CORRUPT=$SANDBOX/common-corrupt
mkdir -p "$CORRUPT/.kairos-updates/api" && cd "$CORRUPT"
git init -q -b main
printf '# a\nintent: x\n' > .kairos-updates/api/20260101T000000-corrupt-first.md
git add -A && git commit -qm c0 && git tag api/v1.0.0
printf '# b\nintent: y\n' > .kairos-updates/api/20260102T000000-corrupt-second.md
git add -A && git commit -qm c1 && git tag api/v1.1.0
# Drop the tip commit's tree object: `rev-parse api/v1.1.0^{commit}` still resolves
# (so resolution says `collect`), but any walk that reads the tree fails.
TIPTREE=$(git rev-parse 'api/v1.1.0^{tree}')
rm -f ".git/objects/${TIPTREE:0:2}/${TIPTREE:2}"
cd "$CC"
cat > component-cx.mod <<EOF
module example.com/mycomp

go 1.26

require (
    $COMMON/api v1.0.0
)
EOF
cat > template-cx.mod <<EOF
module bitbucket.org/ifs-pd/kairos-component-template

go 1.26

require (
    $COMMON/api v1.1.0
)
EOF
RUNCX=$CC/state-cx; mkdir -p "$RUNCX"
RUN=$RUNCX COMPONENT_GOMOD=$CC/component-cx.mod TEMPLATE_GOMOD=$CC/template-cx.mod \
  COMMON_REPO_PATH=$COMMON COMMON_CACHE=$CORRUPT \
  PHASE_KEY=$PK_COMMON "$SKILL_DIR/scripts/collect-common.sh" 2> "$SANDBOX/cc-cx.log"
CX_RC=$?
if [[ "$CX_RC" -ne 0 ]]; then pass "a failed collection walk refuses (exit $CX_RC)"; else fail "a failed collection walk was accepted (exit 0)"; fi
expect "the refusal names the module whose walk failed" \
  grep -q 'api' "$SANDBOX/cc-cx.log"
expect "the refusal names a walk stage" \
  grep -qi 'walk' "$SANDBOX/cc-cx.log"
refute "no green 'OK: common resolution written' on a failed walk" \
  grep -q 'OK: common resolution written' "$SANDBOX/cc-cx.log"
refute "no partial added list is left to be read as complete" \
  test -s "$RUNCX/common-upgrades-added.txt"

cd "$SANDBOX"
# =============================================================================
fi

finish_suite
