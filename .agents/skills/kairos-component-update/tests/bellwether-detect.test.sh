#!/usr/bin/env bash
# bellwether-detect.test.sh — tests for scripts/bellwether-detect.sh
# TEST_FILTER refused (blocks share sequential template fixtures).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in bellwether-detect.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite
PK_RESOLVE=$(phase_key 2-resolve-target.md)

if t "bellwether-detect.sh ranks by confidence ratio"; then
TPL2=$SANDBOX/template2
mkdir -p "$TPL2" && cd "$TPL2"
git init -q -b main
mkdir -p .kairos-updates
printf 'b1 v1\ncontent\n' > b1.txt
printf 'b2 v1\ncontent\n' > b2.txt
printf 'b3 v1\ncontent\n' > b3.txt
git add -A && git commit -qm "c1"
C1=$(git rev-parse HEAD)
printf 'b1 v2\ncontent\n' > b1.txt
printf 'b4 v1\ncontent\n' > b4.txt
printf 'b1.txt\nb2.txt\nb3.txt\nb4.txt\n' > .kairos-updates/bellwethers.txt
git add -A && git commit -qm "c2"
C2=$(git rev-parse HEAD)

COMP2=$SANDBOX/comp2
mkdir -p "$COMP2" && cd "$COMP2"
git -C "$TPL2" show "$C1:b1.txt" > b1.txt
git -C "$TPL2" show "$C1:b2.txt" > b2.txt
git -C "$TPL2" show "$C1:b3.txt" > b3.txt
git -C "$TPL2" show "$C2:b4.txt" > b4.txt   # matches c2, but c1 is 3/3 vs c2's 3/4

RUN2=$SANDBOX/run2

# Phase-load guard: refused without the Phase 2 key, before any state is written.
CACHE=$TPL2 RUN=$RUN2 TEMPLATE_BRANCH=main "$SKILL_DIR/scripts/bellwether-detect.sh" \
  > /dev/null 2> "$SANDBOX/bw-nokey.log"
BW_NOKEY_RC=$?
if [[ "$BW_NOKEY_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/2-resolve-target.md first' "$SANDBOX/bw-nokey.log"; then
  pass "without PHASE_KEY is refused: load phases/2-resolve-target.md first"
else
  fail "without PHASE_KEY is refused: load phases/2-resolve-target.md first (rc=$BW_NOKEY_RC)"
fi
refute "the refused run wrote no state dir" test -d "$RUN2"
CACHE=$TPL2 RUN=$RUN2 TEMPLATE_BRANCH=main PHASE_KEY=not-the-key \
  "$SKILL_DIR/scripts/bellwether-detect.sh" > /dev/null 2> "$SANDBOX/bw-wrongkey.log"
BW_WRONG_RC=$?
if [[ "$BW_WRONG_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/2-resolve-target.md first' "$SANDBOX/bw-wrongkey.log"; then
  pass "with a wrong PHASE_KEY is refused: load phases/2-resolve-target.md first"
else
  fail "with a wrong PHASE_KEY is refused: load phases/2-resolve-target.md first (rc=$BW_WRONG_RC)"
fi

CACHE=$TPL2 RUN=$RUN2 TEMPLATE_BRANCH=main PHASE_KEY=$PK_RESOLVE "$SKILL_DIR/scripts/bellwether-detect.sh" \
  > "$SANDBOX/bw.out" 2> "$SANDBOX/bw.log"
expect "bellwether-detect exits 0"      test $? -eq 0
expect "prints N_BELLWETHERS=4"         grep -qx 'N_BELLWETHERS=4' "$SANDBOX/bw.out"
TOP_SHA=$(head -1 "$RUN2/bellwether-scores.txt" | awk '{ print $3 }')
if [[ "$TOP_SHA" = "$C1" ]]; then
  pass "perfect 3/3 outranks 3/4 (ratio, not raw matches)"
else
  fail "top candidate is $TOP_SHA (want $C1 — 3/3 should beat 3/4)"
fi
expect "top-5 file annotated"           grep -q 'c1' "$RUN2/bellwether-top.txt"
expect "strong bellwether signal skips the wide scan" \
  grep -qx 'WIDESCAN=skipped' "$SANDBOX/bw.out"

# =============================================================================
fi

if t "bellwether-detect.sh falls back to a wide scan when bellwethers can't discriminate"; then
# The production failure: the bellwethers are identical across all of history, so
# they cannot tell any two commits apart. A lone perfect score is the ABSENCE of
# evidence, and taking it at face value pins the baseline to whatever commit last
# touched a bellwether.
TPL3=$SANDBOX/template3
mkdir -p "$TPL3/.kairos-updates" && cd "$TPL3"
git init -q -b main
for b in b1 b2 b3 b4; do echo "never changes" > "$b.txt"; done
printf 'b1.txt\nb2.txt\nb3.txt\nb4.txt\n' > .kairos-updates/bellwethers.txt
echo "v1" > src1.go
echo "v1" > src2.go
printf 'name: <YOUR_COMPONENT_NAME>\n' > cfg.yaml
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n' > go.mod
# A path with an embedded TAB — legal in git, present in every candidate commit
# (never touched again after w1). The wide scan's per-commit `ls-tree -r -z`
# read used to go through `tr '\0' '\n'` before awk, which turns this path's own
# TAB-adjacent NUL-vs-data ambiguity moot but its raw bytes still can't ride the
# scan's own TAB-delimited stream row — it must be dropped with a diagnostic
# rather than silently misaligning the row for the NEXT real file in the walk.
printf 'never changes\n' > $'weird\ttab.txt'
# A path with an embedded NEWLINE, present in BOTH the template tip and the
# component (unlike the TAB path above, which is template-only) so it reaches the
# COMPONENT-side `shared.txt` loop. The ls-tree stream is NUL-delimited, but the
# shared list is re-emitted newline-delimited — so a raw newline path would split
# into two half-lines (`nlfile`, then `half.txt`), inflating N_WIDESCAN_FILES and
# feeding the COMPH hashing loop two junk keys. It must be dropped, not split.
printf 'shared everywhere\n' > $'nlfile\nhalf.txt'
git add -A && git commit -qm "w1"
echo "v2" > src1.go; git commit -qam "w2"; W2=$(git rev-parse HEAD)
echo "v2" > src2.go; git commit -qam "w3"

COMP3=$SANDBOX/comp3
mkdir -p "$COMP3" && cd "$COMP3"
for b in b1 b2 b3 b4; do echo "never changes" > "$b.txt"; done
echo "v2" > src1.go
echo "v1" > src2.go                              # this pair is only true at W2
printf 'name: mycomp3\r\n' > cfg.yaml            # CRLF + a substituted value
printf 'module bitbucket.org/ifs-pd/mycomp3\n' > go.mod
printf 'shared everywhere\n' > $'nlfile\nhalf.txt'   # newline path shared with the template

RUN3=$SANDBOX/run3; mkdir -p "$RUN3"
CACHE=$TPL3 RUN=$RUN3 TEMPLATE_BRANCH=main COMPONENT_NAME=mycomp3 PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/bellwether-detect.sh" > "$SANDBOX/bw3.out" 2> "$SANDBOX/bw3.log"
expect "wide-scan run exits 0" test $? -eq 0
expect "non-discriminating bellwethers trigger the wide scan" \
  grep -qx 'WIDESCAN=ran' "$SANDBOX/bw3.out"
WS_TOP=$(head -1 "$RUN3/widescan-scores.txt" | awk '{ print $3 }')
if [[ "$WS_TOP" = "$W2" ]]; then
  pass "wide scan peaks at the true baseline the bellwethers missed"
else
  fail "wide-scan peak is $WS_TOP (want $W2)"
fi
expect "substitution-aware: a tokenized file still matches" \
  bash -c "grep -q 'cfg.yaml' '$RUN3/.widescan/matched.tsv'"
expect "CRLF component file still matches its LF template blob" \
  bash -c "awk -F'\t' '\$2==\"cfg.yaml\"' '$RUN3/.widescan/matched.tsv' | grep -q ."
expect "suggests the files that actually discriminated" \
  bash -c "grep -qx 'src1.go' '$RUN3/bellwether-suggestions.txt'"
refute "does not suggest files identical across all history" \
  grep -qx 'b1.txt' "$RUN3/bellwether-suggestions.txt"
# The TAB-named path present in every candidate commit must not corrupt the
# wide-scan stream for its neighbors: WS_TOP above already proves the real
# result survived it intact, and it is reported rather than silently dropped.
expect "the TAB-named path is called out on stderr, not silently dropped" \
  bash -c "grep -qF 'carries a TAB or newline' '$SANDBOX/bw3.log'"
refute "the TAB-named path itself never reaches a stream/score row" \
  bash -c "grep -q 'weird' '$RUN3/.widescan/matched.tsv' 2>/dev/null"

# The COMPONENT-side shared-set loop must drop a newline-named path the SAME way
# rather than re-emit it newline-delimited: without the guard, the ls-tree stream's
# NUL-safety is thrown away here and the path splits into two half-lines. The tail
# half (`half.txt`) would then land as its own bogus entry in shared.txt (and as a
# junk comp[] key). Its presence there is the exact defect, so refute it.
refute "a newline path's orphan tail half never lands as a bogus shared entry" \
  bash -c "grep -qx 'half.txt' '$RUN3/.widescan/shared.txt'"
expect "the component-side newline path is called out on stderr, not split silently" \
  bash -c "grep -qF 'component path(s) whose name carries a TAB or newline' '$SANDBOX/bw3.log'"

fi

if t "bellwether-detect.sh substitutes the scored template's own module path (facade template)"; then
# The wide scan's module-path substitution was hard-coded to
# kairos-component-template, so every facade-template file that names its module
# (go.mod, imports) mismatched the facade component and scored nothing.
# reproduced pre-fix: imp.go absent from matched.tsv on this fixture.
TPLF=$SANDBOX/template-facade
mkdir -p "$TPLF/.kairos-updates" && cd "$TPLF"
git init -q -b main
for b in b1 b2; do echo "never changes" > "$b.txt"; done
printf 'b1.txt\nb2.txt\n' > .kairos-updates/bellwethers.txt
printf 'module bitbucket.org/ifs-pd/kairos-component-facade-template\n' > go.mod
printf 'package x\n\nimport _ "bitbucket.org/ifs-pd/kairos-component-facade-template/pkg/schema"\n// v1\n' > imp.go
git add -A && git commit -qm f1
printf 'package x\n\nimport _ "bitbucket.org/ifs-pd/kairos-component-facade-template/pkg/schema"\n// v2\n' > imp.go
git commit -qam f2; F2=$(git rev-parse HEAD)
printf 'package x\n\nimport _ "bitbucket.org/ifs-pd/kairos-component-facade-template/pkg/schema"\n// v3\n' > imp.go
git commit -qam f3

COMPF=$SANDBOX/comp-facade
mkdir -p "$COMPF" && cd "$COMPF"
for b in b1 b2; do echo "never changes" > "$b.txt"; done
printf 'module bitbucket.org/ifs-pd/myfacade\n' > go.mod
printf 'package x\n\nimport _ "bitbucket.org/ifs-pd/myfacade/pkg/schema"\n// v2\n' > imp.go
RUNF=$SANDBOX/run-facade; mkdir -p "$RUNF"
CACHE=$TPLF RUN=$RUNF TEMPLATE_BRANCH=main COMPONENT_NAME=myfacade PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/bellwether-detect.sh" > "$SANDBOX/bwf.out" 2> "$SANDBOX/bwf.log"
expect "facade wide-scan run exits 0" test $? -eq 0
expect "the facade import file matches once the facade module path is substituted" \
  bash -c "awk -F'\t' '\$2==\"imp.go\"' '$RUNF/.widescan/matched.tsv' | grep -q ."
WSF_TOP=$(head -1 "$RUNF/widescan-scores.txt" | awk '{ print $3 }')
if [[ "$WSF_TOP" = "$F2" ]]; then
  pass "the facade wide scan peaks at the true baseline"
else
  fail "facade wide-scan peak is $WSF_TOP (want $F2)"
fi
fi

if t "bellwether-detect.sh resolves the bellwether list in three tiers"; then
# config.yaml -> legacy .kairos-updates/bellwethers.txt -> the v1 fallback set, every
# tier read at the tip of the TARGETED branch. The order is what lets a configured
# source repo own its own list PER MODULE while a repo with no config.yaml keeps
# exactly the behavior it had before there was a tier 1 at all.
TPL4=$SANDBOX/template4
mkdir -p "$TPL4/.kairos-updates" && cd "$TPL4"
git init -q -b main
printf 'modules:\n  webby:\n    kind: template\n    path: template/webby\n    bellwethers:\n      - c1.txt\n      - c2.txt\n' \
  > .kairos-updates/config.yaml
printf 'b1.txt\n# a comment line\nb2.txt\nb3.txt\n' > .kairos-updates/bellwethers.txt
for f in b1 b2 b3 c1 c2; do printf '%s v1\n' "$f" > "$f.txt"; done
git add -A && git commit -qm "t4-c1"
# Same history, tip WITHOUT the legacy list: the only thing that changes is which
# tier answers.
git checkout -q -b noleg
git rm -q .kairos-updates/bellwethers.txt
git commit -qm "t4-drop-legacy"

COMP4=$SANDBOX/comp4
mkdir -p "$COMP4" && cd "$COMP4"
for f in b1 b2 b3 c1 c2; do printf '%s v1\n' "$f" > "$f.txt"; done
RUN4=$SANDBOX/run4

CACHE=$TPL4 RUN=$RUN4 TEMPLATE_BRANCH=main MODULE=webby PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/bellwether-detect.sh" > "$SANDBOX/bw4-cfg.out" 2> "$SANDBOX/bw4-cfg.log"
expect "the tier-1 (config.yaml) run exits 0" test $? -eq 0
expect "config.yaml's module list wins over the legacy file (2, not 3)" \
  grep -qx 'N_BELLWETHERS=2' "$SANDBOX/bw4-cfg.out"
expect "and it says which module's list answered" \
  bash -c "grep -qF \"config.yaml bellwethers for module 'webby'\" '$SANDBOX/bw4-cfg.log'"

CACHE=$TPL4 RUN=$RUN4 TEMPLATE_BRANCH=main PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/bellwether-detect.sh" > "$SANDBOX/bw4-leg.out" 2> "$SANDBOX/bw4-leg.log"
expect "MODULE unset never reaches tier 1, even with a config.yaml present (3)" \
  grep -qx 'N_BELLWETHERS=3' "$SANDBOX/bw4-leg.out"
# A module the config does not declare must FALL THROUGH, not score an empty list —
# an empty list scores every candidate 0/0 and reports "no signal" for a component
# whose baseline the legacy list can still find.
CACHE=$TPL4 RUN=$RUN4 TEMPLATE_BRANCH=main MODULE=nosuch PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/bellwether-detect.sh" > "$SANDBOX/bw4-und.out" 2> "$SANDBOX/bw4-und.log"
expect "an undeclared module falls through to the legacy list (3)" \
  grep -qx 'N_BELLWETHERS=3' "$SANDBOX/bw4-und.out"
expect "and the fall-through is stated" \
  bash -c "grep -qF 'declares no bellwethers for module' '$SANDBOX/bw4-und.log'"

CACHE=$TPL4 RUN=$RUN4 TEMPLATE_BRANCH=noleg PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/bellwether-detect.sh" > "$SANDBOX/bw4-fb.out" 2> "$SANDBOX/bw4-fb.log"
expect "no module list and no legacy file lands on the v1 fallback set (5)" \
  grep -qx 'N_BELLWETHERS=5' "$SANDBOX/bw4-fb.out"
refute "the frontend-shaped-source warning stays silent on a template-arm run" \
  grep -q 'frontend-shaped' "$SANDBOX/bw4-fb.log"

fi

if t "bellwether-detect.sh scores a frontend mount against the module subtree, substituting the subtree side first"; then
# The frontend arm's whole contract. The mount is a create-time copy, so it already
# carries the component's own name where the subtree carries a placeholder: the
# subtree side has to go through the CLI's replacement map before comparison, or
# every substituted file mismatches at EVERY candidate commit and the true create
# commit ranks no better than any other.
setup_frontend_fixture

FEB=$SANDBOX/fe-bw-comp
mkdir -p "$FEB/.kairos" && cd "$FEB" && git init -q -b main
printf 'name: febwcomp\ntemplate:\n  repo: file://%s\n  sha: %s\n  branch: main\n' \
  "$SANDBOX/nonexistent-template" "$FRONTEND_BASE_SHA" > .kairos/manifest.yaml
git add -A && git commit -qm fe-bw-comp
add_frontend_to_component "$FEB"
cd "$FEB"
FEB_RUN=$FEB/.kairos/migration/state; mkdir -p "$FEB_RUN"

# MODULE_PATH deliberately NOT passed: it must default from the module's config entry,
# because nothing in the skill may hardcode a module's subtree.
CACHE=$FRONTEND_REPO_DIR RUN=$FEB_RUN TEMPLATE_BRANCH=main MODULE=react MOUNT=web/ \
  PHASE_KEY=$PK_RESOLVE "$SKILL_DIR/scripts/bellwether-detect.sh" \
  > "$SANDBOX/fbw.out" 2> "$SANDBOX/fbw.log"
expect "the frontend arm exits 0" test $? -eq 0
expect "the module's config.yaml bellwethers answered (3)" \
  grep -qx 'N_BELLWETHERS=3' "$SANDBOX/fbw.out"
expect "MODULE_PATH defaulted from the module's config.yaml entry" \
  bash -c "grep -qF \"subtree 'template/react'\" '$SANDBOX/fbw.log'"
FBW_TOP=$(head -1 "$FEB_RUN/bellwether-scores.txt" | awk '{ print $3 }')
if [[ "$FBW_TOP" = "$FRONTEND_BASE_SHA" ]]; then
  pass "the true create commit ranks first once the subtree side is substituted"
else
  fail "top candidate is $FBW_TOP (want the create commit $FRONTEND_BASE_SHA)"
fi
expect "it ranks first on a PERFECT score, not on a tiebreak" \
  bash -c "head -1 '$FEB_RUN/bellwether-scores.txt' | grep -qx '3 3 $FRONTEND_BASE_SHA'"
expect "no wide scan on this arm" grep -qx 'WIDESCAN=skipped' "$SANDBOX/fbw.out"
expect "and the skip is stated, not passed off as strong bellwether signal" \
  bash -c "grep -qF 'frontend arm — no wide scan' '$SANDBOX/fbw.log'"
expect "the skipped scan's artifacts are emptied, so a chained run cannot serve them" \
  bash -c "test -f '$FEB_RUN/widescan-scores.txt' && ! test -s '$FEB_RUN/widescan-scores.txt'"

# The asymmetry, made falsifiable. A RAW (unsubstituted) mount is what an
# implementation that skipped the replacement map would effectively be comparing
# against: the token-bearing bellwether mismatches everywhere, the other two match
# everywhere, the top two tie, and the tie falls to recency — i.e. to the WRONG commit,
# reported with the same confidence as the right one.
mkdir -p rawweb
git -C "$FRONTEND_REPO_DIR" archive "$FRONTEND_BASE_SHA:template/react" | tar -x -C rawweb
FEB_RAW=$SANDBOX/fe-bw-run-raw
CACHE=$FRONTEND_REPO_DIR RUN=$FEB_RAW TEMPLATE_BRANCH=main MODULE=react MOUNT=rawweb \
  PHASE_KEY=$PK_RESOLVE "$SKILL_DIR/scripts/bellwether-detect.sh" \
  > "$SANDBOX/fbwraw.out" 2> "$SANDBOX/fbwraw.log"
expect "the raw-mount control run exits 0" test $? -eq 0
RAW_TOP=$(head -1 "$FEB_RAW/bellwether-scores.txt" | awk '{ print $3 }')
if [[ "$RAW_TOP" = "$FRONTEND_TARGET_SHA" ]]; then
  pass "against a raw mount the create commit does NOT come first (the tie falls to recency)"
else
  fail "raw-mount top candidate is $RAW_TOP (want $FRONTEND_TARGET_SHA — substitution is what ranks the create commit first)"
fi
refute "no candidate reaches a perfect score against a raw mount" \
  grep -qx "3 3 $FRONTEND_BASE_SHA" "$FEB_RAW/bellwether-scores.txt"

# An absent mount would score every candidate 0/0 and read as "this component is
# undetectable" — refused instead, before any of that is written.
CACHE=$FRONTEND_REPO_DIR RUN=$SANDBOX/fe-bw-run-nomount TEMPLATE_BRANCH=main MODULE=react \
  MOUNT=nosuchweb PHASE_KEY=$PK_RESOLVE "$SKILL_DIR/scripts/bellwether-detect.sh" \
  > "$SANDBOX/fbwnm.out" 2> "$SANDBOX/fbwnm.log"
FBW_NM_RC=$?
if [[ "$FBW_NM_RC" -ne 0 ]]; then
  pass "an absent MOUNT is refused, not scored as no signal"
else
  fail "an absent MOUNT was accepted (rc=0)"
fi
expect "the refusal names the directory it looked for" \
  grep -qF 'MOUNT=nosuchweb' "$SANDBOX/fbwnm.log"

fi

if t "bellwether-detect.sh: config MODULE_PATH outranks the passed one, and a declared module with no bellwethers skips the legacy list"; then
# Two alignments (C3, S11) on the same fixture: a configured source repo where the
# module's config entry is the authority for the SUBTREE, and where a declared module
# that lists no bellwethers must not fall into the repo-root legacy list.
TPL5=$SANDBOX/template5
mkdir -p "$TPL5/.kairos-updates" "$TPL5/template/newhome/src" && cd "$TPL5"
git init -q -b main
# `withbw` declares bellwethers AND a path; `nobw` declares only a path.
printf 'modules:\n  withbw:\n    kind: template\n    path: template/newhome\n    bellwethers:\n      - keep.txt\n  nobw:\n    kind: template\n    path: template/newhome\n' \
  > .kairos-updates/config.yaml
printf 'r1.txt\nr2.txt\n' > .kairos-updates/bellwethers.txt
printf 'root one\n' > r1.txt
printf 'root two\n' > r2.txt
printf 'keep v1\n' > template/newhome/keep.txt
printf 'src v1\n' > template/newhome/src/index.ts
git add -A && git commit -qm t5-c1
T5_C1=$(git rev-parse HEAD)

# A mount that IS the module subtree at that commit — so the tier-1 run can actually
# score, and the MODULE_PATH the run scores against is observable in the INFO line.
COMP5=$SANDBOX/comp5
mkdir -p "$COMP5/web/src" && cd "$COMP5"
printf 'keep v1\n' > web/keep.txt
printf 'src v1\n' > web/src/index.ts
printf 'root one\n' > r1.txt
printf 'root two\n' > r2.txt

# (C3) The passed MODULE_PATH is STALE — exactly what a component manifest carries
# after upstream relocates the module. The config's value has to win, because
# materialize-frontend.sh resolves it that way: scoring one subtree while the merge
# uses another is the drift this alignment removes.
RUN5=$SANDBOX/run5
CACHE=$TPL5 RUN=$RUN5 TEMPLATE_BRANCH=main MODULE=withbw MODULE_PATH=template/oldhome \
  MOUNT=web/ PHASE_KEY=$PK_RESOLVE "$SKILL_DIR/scripts/bellwether-detect.sh" \
  > "$SANDBOX/bw5-cfgpath.out" 2> "$SANDBOX/bw5-cfgpath.log"
BW5_RC=$?
if [[ "$BW5_RC" -eq 0 ]]; then
  pass "the run scores against the config's subtree rather than dying on the stale one"
else
  fail "the run scores against the config's subtree (rc=$BW5_RC: $(tail -2 "$SANDBOX/bw5-cfgpath.log" | tr '\n' ' '))"
fi
expect "the scored subtree is the config's, not the passed one" \
  bash -c "grep -qF \"subtree 'template/newhome'\" '$SANDBOX/bw5-cfgpath.log'"
expect "the disagreement is a WARN naming both values" \
  bash -c "grep -F 'WARN:' '$SANDBOX/bw5-cfgpath.log' | grep -qF 'template/newhome' \
        && grep -F 'WARN:' '$SANDBOX/bw5-cfgpath.log' | grep -qF 'template/oldhome'"
expect "and it scored the mount for real (the create-shaped commit is a candidate)" \
  bash -c "grep -q '$T5_C1' '$RUN5/bellwether-scores.txt'"
# Agreement stays SILENT — a WARN on the ordinary case is noise.
RUN5B=$SANDBOX/run5b
CACHE=$TPL5 RUN=$RUN5B TEMPLATE_BRANCH=main MODULE=withbw MODULE_PATH=template/newhome \
  MOUNT=web/ PHASE_KEY=$PK_RESOLVE "$SKILL_DIR/scripts/bellwether-detect.sh" \
  > /dev/null 2> "$SANDBOX/bw5-agree.log"
refute "no WARN when the passed path already agrees with the config" \
  grep -qF 'WARN:' "$SANDBOX/bw5-agree.log"

# (S11) `nobw` is DECLARED but lists no bellwethers. The legacy repo-root list must not
# answer for it: its paths are repo-root relative, so on this arm they get addressed
# under the subtree, resolve nowhere, and the run reports "no signal" for a component
# whose baseline is perfectly detectable — silently, because a non-empty tier-2 list
# also suppressed tier 3's frontend-shaped warning.
RUN5C=$SANDBOX/run5c
CACHE=$TPL5 RUN=$RUN5C TEMPLATE_BRANCH=main MODULE=nobw MOUNT=web/ \
  PHASE_KEY=$PK_RESOLVE "$SKILL_DIR/scripts/bellwether-detect.sh" \
  > "$SANDBOX/bw5-nobw.out" 2> "$SANDBOX/bw5-nobw.log"
expect "the run still exits 0 (weak signal is judged from the artifacts, not the status)" test $? -eq 0
expect "the legacy list did NOT answer — the fallback set did (5, not 2)" \
  grep -qx 'N_BELLWETHERS=5' "$SANDBOX/bw5-nobw.out"
expect "the skip is explicit and names the reason" \
  bash -c "grep -F 'WARN:' '$SANDBOX/bw5-nobw.log' | grep -qF 'is SKIPPED'"
expect "and it advises declaring the module's bellwethers in config.yaml" \
  bash -c "grep -F 'WARN:' '$SANDBOX/bw5-nobw.log' | grep -qF 'Declare bellwethers'"
expect "tier 3's frontend-shaped warning now reaches the reader too" \
  grep -qF 'frontend-shaped' "$SANDBOX/bw5-nobw.log"
# A module the config does NOT declare is a different case and keeps the legacy list —
# pinned here as well, because the two are one line apart in the script.
RUN5D=$SANDBOX/run5d
CACHE=$TPL5 RUN=$RUN5D TEMPLATE_BRANCH=main MODULE=undeclared PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/bellwether-detect.sh" > "$SANDBOX/bw5-und.out" 2> "$SANDBOX/bw5-und.log"
expect "an UNDECLARED module still falls through to the legacy list (2)" \
  grep -qx 'N_BELLWETHERS=2' "$SANDBOX/bw5-und.out"
refute "and no skip warning is printed for it" \
  bash -c "grep -F 'WARN:' '$SANDBOX/bw5-und.log' | grep -qF 'is SKIPPED'"
fi

if t "bellwether-detect.sh (frontend arm) fails closed when a staging dir cannot be created"; then
# The per-candidate staging mkdir is the frontend scan arm's one write into $RUN.
# A failed mkdir is a disk/permission fault, NOT the graceful no-count an absent
# blob gets: left unchecked, the blob redirect right below can't create its file,
# its own `|| continue` swallows that, and the bellwether silently drops out of
# STAGED — shrinking `total`, the scoring denominator, as if the file were simply
# absent at this commit. So it must FAIL LOUD instead of skewing the ratio ranking.
# A read-only $RUN makes the staging mkdir fail the same way disk-full/permission
# would, while every other input stays valid.
BWMK_CACHE=$SANDBOX/bwmk-cache
mkdir -p "$BWMK_CACHE/.kairos-updates" "$BWMK_CACHE/template/react" && cd "$BWMK_CACHE"
git init -q -b main
cat > .kairos-updates/config.yaml <<'EOF'
modules:
  react:
    kind: template
    path: template/react
    bellwethers:
      - vite.config.ts
      - tsconfig.json
EOF
printf 'export default { port: 5173 }\n' > template/react/vite.config.ts
printf '{ "strict": true }\n' > template/react/tsconfig.json
git add -A && git commit -qm base
printf 'export default { port: 5174 }\n' > template/react/vite.config.ts
git add -A && git commit -qm target

BWMK_COMP=$SANDBOX/bwmk-comp
mkdir -p "$BWMK_COMP/web" && cd "$BWMK_COMP"
printf 'export default { port: 5173 }\n' > web/vite.config.ts
printf '{ "strict": true }\n' > web/tsconfig.json
BWMK_RUN=$BWMK_COMP/run; mkdir -p "$BWMK_RUN"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 555 stays writable) — the uncreatable-staging-dir arm is not exercised: 2 assertions (non-zero refusal, diagnostic names the staging dir)"
else
  chmod 555 "$BWMK_RUN"        # read-only: the staging mkdir under it must fail
  CACHE=$BWMK_CACHE RUN=$BWMK_RUN TEMPLATE_BRANCH=main MODULE=react MOUNT=web/ \
    COMPONENT_NAME=bwmkcomp PHASE_KEY=$PK_RESOLVE \
    "$SKILL_DIR/scripts/bellwether-detect.sh" > "$SANDBOX/bwmk.out" 2> "$SANDBOX/bwmk.log"
  BWMK_RC=$?
  chmod 755 "$BWMK_RUN"        # restore so the sandbox can be cleaned up
  if [[ "$BWMK_RC" -ne 0 ]]; then pass "an uncreatable staging dir is refused non-zero"; else fail "an uncreatable staging dir was NOT refused (rc=$BWMK_RC)"; fi
  expect "the failure names the staging dir it could not create (not a silent no-count)" \
    grep -qF 'could not create staging dir' "$SANDBOX/bwmk.log"
fi
fi

finish_suite
