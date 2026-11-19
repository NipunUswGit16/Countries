#!/usr/bin/env bash
# yaml-gate.test.sh — tests for scripts/yaml-gate.sh
# TEST_FILTER refused (blocks share a mutable YG sandbox).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in yaml-gate.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "yaml-gate.sh"; then
YG=$SANDBOX/yamlgate
mkdir -p "$YG/run" && cd "$YG" && git init -q -b main
printf 'a: 1\nb:\n  c: 2\n' > clean.yaml
git add -A && git commit -qm init
RUN=$YG/run LABEL=clean "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
expect "clean YAML passes the gate" test $? -eq 0

printf 'top:\n  mid:\n    inner:\n      resources: a\n      other: b\n      resources: c\n' > dup.yaml
RUN=$YG/run LABEL=dup "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then pass "duplicate key fails the gate"; else fail "duplicate key passed the gate"; fi
expect "duplicate key reported with both line numbers" \
  bash -c "grep -q 'resources (lines 4, 6)' '$YG/run/yaml-gate-dup.tsv'"
expect "untracked file is checked (post-merge blindness guard)" \
  bash -c "git -C '$YG' status --porcelain dup.yaml | grep -q '??'"
rm dup.yaml

printf 'a: 1\n  b: [unclosed\n' > broken.yaml
RUN=$YG/run LABEL=parse "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then pass "unparsable YAML fails the gate"; else fail "unparsable YAML passed the gate"; fi
expect "parse failure recorded as kind=parse" \
  bash -c "awk -F'\t' '\$3==\"parse\"' '$YG/run/yaml-gate-parse.tsv' | grep -q broken.yaml"
rm broken.yaml

# False-positive guards. A spurious duplicate-key finding blocks a migration on a
# non-problem, so these matter more than the detections.
printf 'script: |\n  resources: a\n  resources: b\nitems:\n  - name: a\n  - name: b\nflow: {x: 1, y: 2}\n' > tricky.yaml
RUN=$YG/run LABEL=tricky "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
expect "block scalars, sequence siblings and flow maps are not false positives" test $? -eq 0
rm tricky.yaml

# Helm chart templates are Go templates, NOT YAML. Parsing them would fail on
# every file of every real component.
mkdir -p chart/templates
printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' > chart/Chart.yaml
printf 'replicas: 2\nresources:\n  limits:\n    cpu: 100m\n' > chart/values.yaml
printf '{{- if .Values.replicas }}\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: c\ndata:\n  cpu: "{{ .Values.resources.limits.cpu }}"\n{{- end }}\n' > chart/templates/cm.yaml
RUN=$YG/run LABEL=chart "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
expect "Go-templated chart files do not fail the parse layer" test $? -eq 0
refute "chart templates are excluded from the parse layer" \
  bash -c "awk -F'\t' '\$3==\"parse\"' '$YG/run/yaml-gate-chart.tsv' | grep -q templates/"

# When the ONLY YAML reaching discovery is chart templates (e.g. a post-merge gate
# whose FILES list is just the merge's changed template files), filtering the
# chart's templates/ subtree removes EVERY line. A grep -v that empties its output
# exits 1, skipping the mv, so the templates leaked back and produced false `parse`
# failures on a correct merge. The filter must yield an empty list instead.
# Regression.
YGT=$SANDBOX/yamlgate-tmplonly
mkdir -p "$YGT/mychart/templates" "$YGT/run" && cd "$YGT" && git init -q -b main
printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' > mychart/Chart.yaml
printf '{{- if .Values.x }}\nkind: ConfigMap\n{{- end }}\n' > mychart/templates/cm.yaml
git add -A && git commit -qm init
CHART_DIR=mychart FILES='mychart/templates/cm.yaml' RUN="$YGT/run" LABEL=tmplonly \
  "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
YG_TMPL_RC=$?
if [[ "$YG_TMPL_RC" -eq 0 ]]; then pass "an all-templates file list filters cleanly (no leaked parse failures)"; else fail "chart templates leaked into the parse layer when they were the only YAML (gate exit $YG_TMPL_RC)"; fi
refute "no parse finding recorded for a filtered-away template" \
  bash -c "awk -F'\t' '\$3==\"parse\"' '$YGT/run/yaml-gate-tmplonly.tsv' 2>/dev/null | grep -q ."

# The chart dir may contain a regex metacharacter; the prefix match must be
# literal, or the templates/ subtree is not recognized and its Go templates reach
# the parser. A `[` makes the old unescaped grep regex a malformed bracket
# expression that fails to filter, so cm.yaml lands in the parse layer and yq
# fails on the Go template. Asserting only the parse layer here — a `[` is also an
# invalid Helm release name, so layer 3 is out of scope for this defect.
# Regression.
YGM=$SANDBOX/yamlgate-metachar
mkdir -p "$YGM/a[b/templates" "$YGM/run" && cd "$YGM" && git init -q -b main
printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' > 'a[b/Chart.yaml'
printf 'replicas: 2\n' > 'a[b/values.yaml'
printf '{{- if .Values.x }}\nkind: ConfigMap\n{{- end }}\n' > 'a[b/templates/cm.yaml'
git add -A && git commit -qm init
CHART_DIR='a[b' FILES=$'a[b/values.yaml\na[b/templates/cm.yaml' RUN="$YGM/run" LABEL=meta \
  "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
refute "a regex-metacharacter chart path still has its templates filtered from the parse layer" \
  bash -c "awk -F'\t' '\$3==\"parse\"' '$YGM/run/yaml-gate-meta.tsv' 2>/dev/null | grep -q templates/"

# The templates/ prefix used to reach awk via `-v p="$c/templates/"`. POSIX awk
# escape-processes a -v value (\t -> an actual tab, etc.), so a chart directory
# whose name contains one of those two-character sequences had `p` silently
# corrupted, the prefix filter never matched, and the chart's own Go templates
# (not valid YAML) leaked into the parse layer. A literal backslash is a legal
# Unix filename character, so this is a real path, not a contrived one.
# Regression.
YGBS=$SANDBOX/yamlgate-backslash
mkdir -p "$YGBS"'/a\tb/templates' "$YGBS/run" && cd "$YGBS" && git init -q -b main
printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' > 'a\tb/Chart.yaml'
printf 'replicas: 2\n' > 'a\tb/values.yaml'
printf '{{- if .Values.x }}\nkind: ConfigMap\n{{- end }}\n' > 'a\tb/templates/cm.yaml'
git add -A && git commit -qm init
BS_FILES=$(printf '%s\n' 'a\tb/values.yaml' 'a\tb/templates/cm.yaml')
CHART_DIR='a\tb' FILES="$BS_FILES" RUN="$YGBS/run" LABEL=bs \
  "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
refute "a backslash-bearing chart path still has its templates filtered from the parse layer" \
  bash -c "awk -F'\t' '\$3==\"parse\"' '$YGBS/run/yaml-gate-bs.tsv' 2>/dev/null | grep -q templates/"
cd "$YG"

# A YAML filename that BEGINS with `-` is a legal git path but a positional file
# operand: unanchored it reaches yq/awk as an OPTION. `yq e '.' -dash.yaml` fails
# with an un-acknowledgeable hard parse FAIL (layer 1), and `awk -f prog -dash.yaml`
# reads `-d…` as a debug switch — on BSD awk it exits 0 dumping the 44KB ENVIRON
# symbol table (env secrets included) to stdout with zero data rows, so the
# duplicate-key layer read it back as a silent clean; on GNU awk the same switch
# writes an awkvars dump into cwd instead. anchor() (`./-dash.yaml`) closes all of
# it. The two behavioral assertions below exercise this host's awk directly; the
# operand-shape assertion pins the fix host-independently (it is what proves the
# GNU-awk cwd dump is gone, which cannot be exercised on a BSD-awk host).
# Regression.
YGLD=$SANDBOX/yamlgate-leadingdash
mkdir -p "$YGLD/run" && cd "$YGLD" && git init -q -b main
printf 'a: 1\nb: 2\n' > -clean.yaml                 # layer 1: valid, must parse clean
printf 'x: 1\nx: 2\n' > -dup.yaml                   # layer 2: duplicate key, must be caught
git add -A && git commit -qm init
RUN="$YGLD/run" LABEL=ld "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
refute "a valid leading-dash YAML file is not a spurious parse FAIL (layer 1 anchored)" \
  bash -c "awk -F'\t' '\$3==\"parse\" && \$1==\"fail\"' '$YGLD/run/yaml-gate-ld.tsv' | grep -q ."
expect "a duplicate key in a leading-dash YAML file is still caught (layer 2 anchored)" \
  bash -c "awk -F'\t' '\$3==\"duplicate-key\" && \$1==\"fail\"' '$YGLD/run/yaml-gate-ld.tsv' | grep -q -- '-dup.yaml'"
expect "the parse layer hands yq an anchored operand (leading-dash cannot reach it as a flag)" \
  grep -Fq "yq e '.' \"\$(anchor \"\$f\")\"" "$SKILL_DIR/scripts/yaml-gate.sh"
expect "the duplicate-key scanner is handed an anchored operand" \
  grep -Fq 'awk -f "$DUPKEYS" "$(anchor "$1")"' "$SKILL_DIR/scripts/yaml-gate.sh"
cd "$YG"

if command -v helm >/dev/null 2>&1; then
  # The ONLY layer that catches "valid YAML, broken semantics": a merge that nils
  # out a block another template dereferences.
  printf 'replicas: 2\nresources:\n' > chart/values.yaml
  RUN=$YG/run LABEL=nil "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then pass "helm render catches a nilled-out referenced block"; else fail "nilled-out block slipped through"; fi
  expect "nil-block failure attributed to helm-render" \
    bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"helm-render\"' '$YG/run/yaml-gate-nil.tsv' | grep -q ."
else
  echo "  skip: helm not installed — render layer not exercised"
fi

# =============================================================================
fi

if t "yaml-gate.sh layer 4 — structural shape (buried top-level key)"; then
# The deploy-time hole the shape layer closes: a clean merge that nests a
# previously-top-level config block under a sibling. No markers, valid YAML, no
# duplicate keys, suite green — inert at deploy. The oracle is the migration
# TARGET's own materialized tree, so a template that renames/adds/drops a block is
# never false-failed. Every identifier below is INVENTED (not from any real
# component or template) — a check secretly keyed to a real name could not fire on
# names nobody ships, which is what the genericity containment test asserts.
SH=$SANDBOX/shape
SHSYN=$SH/synth
mkdir -p "$SHSYN" && cd "$SHSYN" && git init -q -b main
# The TARGET tree: sprocket and flangebox are SIBLINGS at top level; rename.yaml
# carries the renamed form (frobnicator); absent.yaml has two top-level keys;
# ambig.yaml is a multi-document stream (no single top-level frame).
printf 'sprocket:\n  count: 3\nflangebox:\n  size: large\n' > deploy.yaml
printf 'frobnicator:\n  mode: fast\n' > rename.yaml
printf 'wibble:\n  a: 1\nwobble:\n  b: 2\n' > absent.yaml
printf 'sprocket:\n  count: 3\n---\nflangebox:\n  size: large\n' > ambig.yaml
git add -A && git commit -qm "target"
git tag kairos-target

shape_work() { # shape_work <dir> — a fresh git working tree the gate discovers via ls-files
  rm -rf "$1"; mkdir -p "$1/run" && ( cd "$1" && git init -q -b main )
}

# --- buried: sprocket demoted under flangebox in the working tree -> FAIL -------
SHB=$SH/buried; shape_work "$SHB"
printf 'flangebox:\n  size: large\n  sprocket:\n    count: 3\n' > "$SHB/deploy.yaml"
( cd "$SHB" && git add -A && git commit -qm w >/dev/null 2>&1 )
bash -c "cd '$SHB' && SYNTH='$SHSYN' RUN='$SHB/run' LABEL=buried '$SKILL_DIR/scripts/yaml-gate.sh'" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then pass "buried top-level key fails the shape layer"; else fail "buried top-level key passed the gate"; fi
expect "buried finding recorded as kind=buried-key, severity fail" \
  bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"buried-key\"' '$SHB/run/yaml-gate-buried.tsv' | grep -q deploy.yaml"
expect "buried finding names the key and both locations" \
  bash -c "awk -F'\t' '\$3==\"buried-key\"{print \$4}' '$SHB/run/yaml-gate-buried.tsv' | grep -q sprocket && awk -F'\t' '\$3==\"buried-key\"{print \$4}' '$SHB/run/yaml-gate-buried.tsv' | grep -qi 'top-level' && awk -F'\t' '\$3==\"buried-key\"{print \$4}' '$SHB/run/yaml-gate-buried.tsv' | grep -q flangebox"

# --- correct sibling placement -> PASS -----------------------------------------
SHOK=$SH/sibling; shape_work "$SHOK"
printf 'sprocket:\n  count: 3\nflangebox:\n  size: large\n' > "$SHOK/deploy.yaml"
( cd "$SHOK" && git add -A && git commit -qm w >/dev/null 2>&1 )
bash -c "cd '$SHOK' && SYNTH='$SHSYN' RUN='$SHOK/run' LABEL=ok '$SKILL_DIR/scripts/yaml-gate.sh'" >/dev/null 2>&1
expect "correct sibling placement passes the shape layer" test $? -eq 0

# --- rename false-positive guard: target renamed the key, working adopted it ----
SHR=$SH/rename; shape_work "$SHR"
printf 'frobnicator:\n  mode: fast\n' > "$SHR/rename.yaml"
( cd "$SHR" && git add -A && git commit -qm w >/dev/null 2>&1 )
bash -c "cd '$SHR' && SYNTH='$SHSYN' RUN='$SHR/run' LABEL=ren '$SKILL_DIR/scripts/yaml-gate.sh'" >/dev/null 2>&1
expect "an adopted rename passes (old spelling absent from target, never examined)" test $? -eq 0
refute "no buried-key finding for the renamed key" \
  bash -c "awk -F'\t' '\$3==\"buried-key\" && \$1==\"fail\"' '$SHR/run/yaml-gate-ren.tsv' | grep -q ."

# --- absent key: working dropped a target top-level key entirely -> PASS --------
SHA=$SH/absent; shape_work "$SHA"
printf 'wibble:\n  a: 1\n' > "$SHA/absent.yaml"          # wobble deliberately removed
( cd "$SHA" && git add -A && git commit -qm w >/dev/null 2>&1 )
bash -c "cd '$SHA' && SYNTH='$SHSYN' RUN='$SHA/run' LABEL=abs '$SKILL_DIR/scripts/yaml-gate.sh'" >/dev/null 2>&1
expect "a key absent from the working tree entirely passes (absence != burial)" test $? -eq 0

# --- ambiguous frame (multi-document) -> dropped, no false positive -------------
SHM=$SH/ambig; shape_work "$SHM"
printf 'flangebox:\n  size: large\n  sprocket:\n    count: 3\n---\nextra: 1\n' > "$SHM/ambig.yaml"
( cd "$SHM" && git add -A && git commit -qm w >/dev/null 2>&1 )
bash -c "cd '$SHM' && SYNTH='$SHSYN' RUN='$SHM/run' LABEL=amb '$SKILL_DIR/scripts/yaml-gate.sh'" >/dev/null 2>&1
expect "an ambiguous (multi-document) config file is dropped, not false-flagged" test $? -eq 0
refute "no buried-key finding for the dropped ambiguous file" \
  bash -c "awk -F'\t' '\$3==\"buried-key\" && \$1==\"fail\"' '$SHM/run/yaml-gate-amb.tsv' | grep -q ."

# --- ambiguous frame (<<:-merged / anchored root) -> dropped, no false positive --
# Target deploy.yaml keeps sprocket top-level; this working copy demotes it under
# flangebox AND merges at the root (`<<: *base`). The root merge makes the
# top-level key set ambiguous, so the file is dropped rather than false-flagged —
# even though sprocket is present only nested. Valid YAML (the anchor is defined),
# so layer 1 passes and layer 4 is what makes the call.
SHMG=$SH/merge; shape_work "$SHMG"
printf '_base: &base\n  size: large\n<<: *base\nflangebox:\n  sprocket:\n    count: 3\n' > "$SHMG/deploy.yaml"
( cd "$SHMG" && git add -A && git commit -qm w >/dev/null 2>&1 )
bash -c "cd '$SHMG' && SYNTH='$SHSYN' RUN='$SHMG/run' LABEL=mrg '$SKILL_DIR/scripts/yaml-gate.sh'" >/dev/null 2>&1
expect "a <<:-merged/anchored root config file is dropped, not false-flagged" test $? -eq 0
refute "no buried-key finding for the dropped merge-root file" \
  bash -c "awk -F'\t' '\$3==\"buried-key\" && \$1==\"fail\"' '$SHMG/run/yaml-gate-mrg.tsv' | grep -q ."

# --- deliberate-demotion override: an acknowledged buried key does not block -----
SHACK=$SH/ack; shape_work "$SHACK"
printf 'flangebox:\n  size: large\n  sprocket:\n    count: 3\n' > "$SHACK/deploy.yaml"
( cd "$SHACK" && git add -A && git commit -qm w >/dev/null 2>&1 )
printf 'deploy.yaml\tsprocket\tintentionally folded under flangebox for this component\n' > "$SHACK/run/yaml-gate-ack.tsv"
bash -c "cd '$SHACK' && SYNTH='$SHSYN' RUN='$SHACK/run' LABEL=acked '$SKILL_DIR/scripts/yaml-gate.sh'" >/dev/null 2>&1
expect "an acknowledged buried key does not hard-block the gate" test $? -eq 0
expect "the acknowledged buried key is recorded as a skip, not a fail" \
  bash -c "awk -F'\t' '\$1==\"skip\" && \$3==\"buried-key\"' '$SHACK/run/yaml-gate-acked.tsv' | grep -q deploy.yaml"

# --- no target tree available -> SKIP with a reason, gate still passes ----------
SHNO=$SH/notree; shape_work "$SHNO"
printf 'flangebox:\n  size: large\n  sprocket:\n    count: 3\n' > "$SHNO/deploy.yaml"
( cd "$SHNO" && git add -A && git commit -qm w >/dev/null 2>&1 )
bash -c "cd '$SHNO' && unset SYNTH; RUN='$SHNO/run' LABEL=notree '$SKILL_DIR/scripts/yaml-gate.sh'" > "$SANDBOX/sh-notree.out" 2>&1
expect "no materialized target tree still passes the gate (skip, not fail)" test $? -eq 0
expect "the missing target tree is recorded as a shape skip with a reason" \
  bash -c "awk -F'\t' '\$1==\"skip\" && \$3==\"buried-key\"' '$SHNO/run/yaml-gate-notree.tsv' | grep -qi 'target tree'"
expect "a skipped shape layer does not read as full coverage in the report" \
  bash -c "grep -qi 'SKIPPED' '$SHNO/run/yaml-gate-notree.txt' && ! grep -qi '^clean' '$SHNO/run/yaml-gate-notree.txt'"

# --- buried key in a leading-dash filename -> FAIL (layer 4 operand anchored) ---
# The working-tree side reaches the scanner as `awk -f toplevel.awk <file>`, so a
# file named `-dash.yaml` was handed to awk as `-d…` (a debug switch): BSD awk
# exits 0 with an ENVIRON symtab dump and ZERO top-level rows, and a re-parented
# key reads back as "nothing buried" — the exact false clean this layer exists to
# stop (GNU awk dumps to cwd instead, equally 0-row). Its own SYNTH target tree
# carries `-dash.yaml` with sprocket at top level. anchor() (`./-dash.yaml`) makes
# the burial visible; the operand-shape assertion pins it host-independently.
# Regression.
SHLD=$SH/leadingdash-synth
mkdir -p "$SHLD" && cd "$SHLD" && git init -q -b main
printf 'sprocket:\n  count: 3\nflangebox:\n  size: large\n' > -dash.yaml
git add -A && git commit -qm target
git tag kairos-target
SHLDW=$SH/leadingdash; shape_work "$SHLDW"
printf 'flangebox:\n  size: large\n  sprocket:\n    count: 3\n' > "$SHLDW/-dash.yaml"
( cd "$SHLDW" && git add -A && git commit -qm w >/dev/null 2>&1 )
bash -c "cd '$SHLDW' && SYNTH='$SHLD' RUN='$SHLDW/run' LABEL=lddash '$SKILL_DIR/scripts/yaml-gate.sh'" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then pass "a buried key in a leading-dash file fails the shape layer"; else fail "a buried key in a leading-dash file passed the gate (unanchored awk operand)"; fi
expect "the leading-dash burial is recorded as kind=buried-key, severity fail" \
  bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"buried-key\"' '$SHLDW/run/yaml-gate-lddash.tsv' | grep -q -- '-dash.yaml'"
expect "the shape layer hands its working-tree scanner an anchored operand" \
  grep -Fq 'awk -f "$TOPLEVEL" "$(anchor "$f")"' "$SKILL_DIR/scripts/yaml-gate.sh"

cd "$SANDBOX"

# =============================================================================
fi

if t "yaml-gate.sh discovery parity — the final label sees a file outside the diff"; then
# One run reported the final gate scanning far fewer YAML files than the post-merge
# gate. The two labels share ONE discovery implementation (git ls-files UNION
# untracked-not-ignored; LABEL only names artifacts), so a tracked YAML that was
# never part of any structural diff must still be discovered at the final label on a
# clean tree. This is the regression guard: if discovery ever forks by label, this
# planted file drops out of the `final` scan and the count assertion fails.
DP=$SANDBOX/discovery-parity
mkdir -p "$DP/run" && cd "$DP" && git init -q -b main
printf 'a: 1\nb: 2\n' > in-diff.yaml
mkdir -p sub && printf 'c: 3\n' > sub/outside-diff.yaml   # a plain tracked YAML, in no diff
git add -A && git commit -qm init
RUN=$DP/run LABEL=postmerge "$SKILL_DIR/scripts/yaml-gate.sh" > /dev/null 2> "$SANDBOX/dp-pm.log"
RUN=$DP/run LABEL=final "$SKILL_DIR/scripts/yaml-gate.sh" > /dev/null 2> "$SANDBOX/dp-fin.log"
DP_PM=$(sed -n 's/.*checked \([0-9][0-9]*\) plain YAML.*/\1/p' "$SANDBOX/dp-pm.log")
DP_FIN=$(sed -n 's/.*checked \([0-9][0-9]*\) plain YAML.*/\1/p' "$SANDBOX/dp-fin.log")
if [[ "${DP_FIN:-0}" = "${DP_PM:-x}" ]] && [[ "${DP_FIN:-0}" -ge 2 ]]; then
  pass "final and post-merge labels discover the same YAML file set (postmerge=$DP_PM final=$DP_FIN)"
else
  fail "discovery diverged by label (postmerge=$DP_PM final=$DP_FIN)"
fi
cd "$SANDBOX"

# =============================================================================
fi

if t "yaml-gate.sh fail-closed discovery — a failed listing is not an empty listing"; then
# As the head of a masked pipeline, `git ls-files` failing (cwd is not a repo,
# index corrupt) is byte-identical to an empty tree: the file list comes back
# empty, every layer finds nothing, and the gate reports clean over a set it
# never built. Failed must be a parse-layer fail row with a non-zero exit;
# empty-but-successful must keep passing. Regression.
YGNR=$SANDBOX/yamlgate-nonrepo
mkdir -p "$YGNR/run" && cd "$YGNR"
printf 'a: 1\n  b: [unclosed\n' > broken.yaml
refute "the fixture cwd is genuinely outside any git repo (git ls-files must fail)" \
  git rev-parse --git-dir
RUN=$YGNR/run LABEL=nonrepo "$SKILL_DIR/scripts/yaml-gate.sh" > /dev/null 2> "$SANDBOX/yg-nonrepo.log"
YG_NR_RC=$?
if [[ "$YG_NR_RC" -ne 0 ]]; then pass "a failed file listing fails the yaml gate"; else fail "a failed file listing passed the yaml gate"; fi
expect "the failed listing is recorded as a parse-layer fail row naming git ls-files" \
  bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"parse\"' '$YGNR/run/yaml-gate-nonrepo.tsv' | grep -q 'git ls-files'"
refute "a failed listing never reports a clean gate" \
  bash -c "grep -qi '^clean' '$YGNR/run/yaml-gate-nonrepo.txt'"
refute "no file was scanned (the broken YAML sitting in the tree is never reported)" \
  bash -c "grep -q 'broken.yaml' '$YGNR/run/yaml-gate-nonrepo.tsv'"

# An EMPTY but SUCCESSFUL listing keeps its pass: a repo carrying no YAML at all
# is a real, clean state, and the distinction being drawn is failed, not empty.
YGE=$SANDBOX/yamlgate-emptylist
mkdir -p "$YGE/run" && cd "$YGE" && git init -q -b main
printf 'hello\n' > readme.txt
git add -A && git commit -qm init
RUN=$YGE/run LABEL=empty "$SKILL_DIR/scripts/yaml-gate.sh" > /dev/null 2> "$SANDBOX/yg-empty.log"
expect "an empty but successful listing still passes the gate" test $? -eq 0
refute "no fail row is invented for an empty successful listing" \
  bash -c "awk -F'\t' '\$1==\"fail\"' '$YGE/run/yaml-gate-empty.tsv' 2>/dev/null | grep -q ."
expect "the empty successful listing reports 0 files checked" \
  grep -q 'checked 0 plain YAML' "$SANDBOX/yg-empty.log"
cd "$SANDBOX"

# =============================================================================
fi

if t "yaml-gate.sh CHART_DIR — a trailing slash behaves identically to none"; then
# An operator-supplied CHART_DIR ending in "/" made the exclusion prefix
# "chart//templates/", which matches nothing: the chart's Go templates leaked
# back into the parse layer and yq failed on every one of them.
YGS=$SANDBOX/yamlgate-slash
mkdir -p "$YGS/mychart/templates" "$YGS/run" && cd "$YGS" && git init -q -b main
printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' > mychart/Chart.yaml
printf 'replicas: 2\n' > mychart/values.yaml
printf '{{- if .Values.x }}\nkind: ConfigMap\n{{- end }}\n' > mychart/templates/cm.yaml
git add -A && git commit -qm init
CHART_DIR=mychart/ RUN="$YGS/run" LABEL=slash "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
YG_SL_RC=$?
CHART_DIR=mychart RUN="$YGS/run" LABEL=noslash "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
YG_NS_RC=$?
refute "a trailing-slash CHART_DIR still excludes the chart's templates/ from the parse layer" \
  bash -c "awk -F'\t' '\$3==\"parse\"' '$YGS/run/yaml-gate-slash.tsv' 2>/dev/null | grep -q templates/"
if [[ "$YG_SL_RC" -eq "$YG_NS_RC" ]]; then
  pass "trailing-slash and plain CHART_DIR agree on the exit status (both $YG_SL_RC)"
else
  fail "trailing-slash and plain CHART_DIR disagree on the exit status ($YG_SL_RC vs $YG_NS_RC)"
fi
expect "trailing-slash and plain CHART_DIR record identical findings" \
  cmp -s "$YGS/run/yaml-gate-slash.tsv" "$YGS/run/yaml-gate-noslash.tsv"
cd "$SANDBOX"

fi

if t "yaml-gate.sh helm render — the release name is derived, not the raw chart dir basename"; then
# helm VALIDATES the release name it is handed before it renders anything, but a
# chart DIRECTORY is a Unix path: uppercase letters, underscores and leading
# dashes are all legal in it and none of them are legal in a release name. Passing
# the raw basename made helm exit non-zero with "invalid release name", which
# matches no environment keyword in the skip case below, so a perfectly healthy
# chart recorded a helm-render FAIL and blocked the migration. The release name is
# cosmetic here — nothing is installed — so it only has to be one helm accepts.
if command -v helm >/dev/null 2>&1; then
  yg_helm_clean() { # yg_helm_clean <dirname> <label> <desc>
    # Split assignments: `local` expands every word BEFORE it assigns any of
    # them, so a later word referring to an earlier one trips `set -u`.
    local d="$1" lbl="$2" desc="$3"
    local root="$SANDBOX/yamlgate-relname-$lbl"
    mkdir -p "$root/$d/templates" "$root/run"
    ( cd "$root" && git init -q -b main \
      && printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' > "$d/Chart.yaml" \
      && printf 'replicas: 2\n' > "$d/values.yaml" \
      && printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cm\n' > "$d/templates/cm.yaml" \
      && git add -A && git commit -qm init \
      && RUN="$root/run" LABEL="$lbl" "$SKILL_DIR/scripts/yaml-gate.sh" ) >/dev/null 2>&1
    refute "$desc" \
      bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"helm-render\"' '$root/run/yaml-gate-$lbl.tsv' | grep -q ."
    refute "$desc — and no row blames the release name" \
      bash -c "grep -qi 'release name' '$root/run/yaml-gate-$lbl.tsv'"
  }
  yg_helm_clean 'My_Chart' upper \
    "an uppercase/underscore chart dir renders instead of recording a helm-render FAIL"
  # Trailing dash (illegal as the last character of a release name) AND long
  # enough that the 53-character cap truncates it — mid-underscore, so the
  # truncation itself would leave a trailing dash if it were not re-trimmed.
  # (A LEADING-dash directory is deliberately not covered: `git ls-files` emits
  # such a path with no `./`, so yq and helm both read it as a flag long before
  # the release name matters — a separate defect in the same file's path
  # handling, not this one.)
  yg_helm_clean 'Chart_Directory_Whose_Name_Is_Long_Enough_To_Need_Truncating_Here-' longdash \
    "a trailing-dash, over-53-character chart dir renders instead of recording a helm-render FAIL"
  # Nothing legal survives sanitization here, so the fallback name is what helm
  # must be handed — an empty release-name argument is itself rejected.
  yg_helm_clean '___' allbad \
    "a chart dir with no legal release-name characters at all still renders"
else
  echo "  skip: helm not installed — release-name derivation not exercised"
fi
cd "$SANDBOX"

fi

if t "yaml-gate.sh helm render — a genuine \`required\` value failure is not demoted to a skip"; then
# A bare *"not found"* glob used to catch a chart author's own
# `required "value not found for x" .Values.x` render failure — a real defect a
# merge introduced (the target's values.yaml sets x; the working tree's, after
# the merge, does not) — and skip it as an environment gap instead of FAILing it.
if command -v helm >/dev/null 2>&1; then
  YGR=$SANDBOX/yamlgate-required
  mkdir -p "$YGR/chart/templates" "$YGR/run" && cd "$YGR" && git init -q -b main
  printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' > chart/Chart.yaml
  printf 'other: 1\n' > chart/values.yaml
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cm\ndata:\n  x: {{ required "value not found for x" .Values.x }}\n' \
    > chart/templates/cm.yaml
  git add -A && git commit -qm init
  RUN="$YGR/run" LABEL=required "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
  YG_REQ_RC=$?
  if [[ "$YG_REQ_RC" -ne 0 ]]; then pass "a \`required\` value failure fails the gate"; else fail "a \`required\` value failure passed the gate"; fi
  expect "it is recorded as a helm-render FAIL, not a skip" \
    bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"helm-render\"' '$YGR/run/yaml-gate-required.tsv' | grep -q ."
  refute "it is not recorded as a helm-render skip" \
    bash -c "awk -F'\t' '\$1==\"skip\" && \$3==\"helm-render\"' '$YGR/run/yaml-gate-required.tsv' | grep -q ."
  cd "$SANDBOX"
else
  echo "  skip: helm not installed — render layer not exercised"
fi
fi

if t "yaml-gate.sh detail cells survive non-UTF-8 input (oneline is locale-pinned)"; then
# Same defect class as gate.sh's build row. Every detail cell yaml-gate records is
# collapsed by oneline(), and three of its four inputs are not guaranteed valid
# UTF-8: git's stderr, a tool's parse error quoting file bytes, and the
# operator-authored acknowledgement reason exercised here (a human pastes a config
# excerpt into the ack file). BSD `tr` in a UTF-8 locale ABORTS on the first
# invalid byte and truncates the cell there, so which half of a reason the next
# reader sees depends on the ambient LC_ALL. producer-idempotence.sh's oneline()
# was pinned to LC_ALL=C for exactly this; this asserts yaml-gate.sh's copy behaves
# the same. The ack path is chosen because its bytes reach oneline() verbatim —
# helm and yq both sanitize invalid input to U+FFFD before printing it, so neither
# can produce the byte class this guards against.
YGL=$SANDBOX/yamlgate-locale
YGLSYN=$YGL/synth
mkdir -p "$YGLSYN" && cd "$YGLSYN" && git init -q -b main
printf 'sprocket:\n  count: 3\nflangebox:\n  size: large\n' > deploy.yaml
git add -A && git commit -qm target && git tag kairos-target
YGLW=$YGL/work
mkdir -p "$YGLW/run" && cd "$YGLW" && git init -q -b main
printf 'flangebox:\n  size: large\n  sprocket:\n    count: 3\n' > deploy.yaml
git add -A && git commit -qm w
# \377 is not valid UTF-8, and the substance of the reason sits AFTER it.
printf 'deploy.yaml\tsprocket\traw \377 bytes then FLANGEBOXMARK here\n' \
  > "$YGLW/run/yaml-gate-ack.tsv"
# The ASSERTION's own extraction is pinned too: the cell under test carries the
# stray byte by construction, so an unpinned awk/grep would truncate it before the
# needle and report a red yaml-gate.sh even after yaml-gate.sh is correct.
ygl_detail_has() { # ygl_detail_has <tsv> <needle>
  LC_ALL=C awk -F'\t' '$3=="buried-key"{print $4}' "$1" | LC_ALL=C grep -q -- "$2"
}
# en_US.UTF-8 reproduces this on macOS; C.UTF-8 is there because the Ubuntu image
# carries no en_US.UTF-8. A platform missing either name falls back to C — the
# detail must be the same one anyway.
for loc in C en_US.UTF-8 C.UTF-8; do
  LC_ALL=$loc SYNTH="$YGLSYN" RUN="$YGLW/run" LABEL=loc "$SKILL_DIR/scripts/yaml-gate.sh" \
    >/dev/null 2>"$SANDBOX/yg-locale.log"
  expect "the acknowledged-demotion detail survives past the non-UTF-8 byte (LC_ALL=$loc)" \
    ygl_detail_has "$YGLW/run/yaml-gate-loc.tsv" FLANGEBOXMARK
  refute "collapsing non-UTF-8 detail input leaks no byte-sequence error (LC_ALL=$loc)" \
    grep -qi 'illegal byte sequence\|invalid byte sequence' "$SANDBOX/yg-locale.log"
done
cd "$SANDBOX"

fi

if t "yaml-gate.sh fail-closed layer 1/2 — a dying duplicate-key scanner is an error, never a silent 'no findings'"; then
# Reproduces the defect directly: awk's own exit status used to be discarded
# (2>/dev/null, and the exit code of a `done < <(awk ...)` process substitution
# is never visible to the loop around it), so a scanner that never opened the
# file — a bad `awk` on PATH, an unreadable/corrupted lib/yaml-dupkeys.awk —
# read back byte-identical to "no duplicate keys found": a clean pass over a
# file nobody scanned. The gate's contract for a check that could not run is
# the same one file-discovery failure already uses (a fail row, never a silent
# empty result), so this is a regression guard for that same class, one layer
# over. The shim goes on PATH ahead of everything else — the script calls a
# bare `awk`, resolved at call time — so every awk invocation the gate makes
# fails the same way, which is fine: no chart is present, so layer 3 never
# runs, and SYNTH is unset, so layer 4 reports its own (unrelated) skip.
YGB=$SANDBOX/yamlgate-badawk
mkdir -p "$YGB/run" "$YGB/badawk-bin" && cd "$YGB" && git init -q -b main
printf 'a: 1\nb: 2\n' > clean.yaml
git add -A && git commit -qm init
cat > badawk-bin/awk <<'SH'
#!/usr/bin/env bash
echo "boom: awk is broken" >&2
exit 2
SH
chmod +x badawk-bin/awk
env PATH="$YGB/badawk-bin:$PATH" RUN="$YGB/run" LABEL=badawk "$SKILL_DIR/scripts/yaml-gate.sh" \
  > /dev/null 2> "$SANDBOX/yg-badawk.log"
YG_BA_RC=$?
if [[ "$YG_BA_RC" -ne 0 ]]; then pass "a dying duplicate-key scanner fails the yaml gate"; else fail "a dying duplicate-key scanner passed the yaml gate (silent 'no findings')"; fi
expect "the dying scanner is recorded as a duplicate-key fail row naming the scanner" \
  bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"duplicate-key\"' '$YGB/run/yaml-gate-badawk.tsv' | grep -q 'duplicate-key scanner'"
expect "the fail row carries the scanner's own exit status, not a bare 'failed'" \
  bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"duplicate-key\"{print \$4}' '$YGB/run/yaml-gate-badawk.tsv' | grep -q 'exited 2'"
refute "a dying scanner never reports 'clean' in the human-readable report" \
  bash -c "grep -qi '^clean' '$YGB/run/yaml-gate-badawk.txt'"
cd "$SANDBOX"
fi

if t "yaml-gate.sh fail-closed layer 4 — an unreadable shape scanner is an error, never a silent skip or pass"; then
# Same class, one layer over: the shape layer's two `awk -f "$TOPLEVEL" ...`
# calls used to run with stderr thrown to /dev/null and their exit status never
# inspected, so an unreadable lib/yaml-toplevel.awk (present, so the startup
# `[ -f "$TOPLEVEL" ]` guard does not catch it — only chmod 000, not absence)
# read back as "no top-level keys, nothing buried". A real component tree with
# a genuine burial would have silently passed. This points the gate at a
# SABOTAGED COPY of the whole scripts/ directory via its own path resolution
# (HERE=$(dirname "$0")) rather than mutating the real skill scripts in place.
YGS2=$SANDBOX/yamlgate-badtoplevel
mkdir -p "$YGS2/run" "$YGS2/synth" "$YGS2/work"
cp -R "$SKILL_DIR/scripts/." "$YGS2/scripts-copy/"
chmod 000 "$YGS2/scripts-copy/lib/yaml-toplevel.awk"
( cd "$YGS2/synth" && git init -q -b main \
  && printf 'sprocket:\n  count: 3\nflangebox:\n  size: large\n' > deploy.yaml \
  && git add -A && git commit -qm target && git tag kairos-target )
( cd "$YGS2/work" && git init -q -b main \
  && printf 'flangebox:\n  size: large\n  sprocket:\n    count: 3\n' > deploy.yaml \
  && git add -A && git commit -qm w )
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip: running as root (chmod 000 stays readable) — the unreadable-scanner arm is not exercised: 3 assertions (fail row naming the scanner; carries its exit status; never a shape skip)"
else
  bash -c "cd '$YGS2/work' && SYNTH='$YGS2/synth' RUN='$YGS2/run' LABEL=badtop '$YGS2/scripts-copy/yaml-gate.sh'" \
    > /dev/null 2> "$SANDBOX/yg-badtop.log"
  YG_BT_RC=$?
  if [[ "$YG_BT_RC" -ne 0 ]]; then pass "an unreadable shape scanner fails the yaml gate"; else fail "an unreadable shape scanner passed the yaml gate"; fi
  expect "the unreadable scanner is recorded as a buried-key fail row naming the scanner" \
    bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"buried-key\"' '$YGS2/run/yaml-gate-badtop.tsv' | grep -q 'shape scanner'"
  refute "an unreadable scanner is never recorded as a shape skip" \
    bash -c "awk -F'\t' '\$1==\"skip\" && \$3==\"buried-key\"' '$YGS2/run/yaml-gate-badtop.tsv' | grep -q ."
fi
chmod 644 "$YGS2/scripts-copy/lib/yaml-toplevel.awk" 2>/dev/null || true
cd "$SANDBOX"
fi

if t "yaml-gate.sh layer 4 — a backslash-carrying key name survives the ENVIRON fix"; then
# A literal backslash is legal inside a single-quoted YAML scalar (single-quote
# style has no escape processing at all), so a top-level key can genuinely
# contain one. `awk -v k="$tkey"` escape-processes its value, so the OLD code
# path compared against a MANGLED key: on this platform's awk, -v strips the
# backslash outright (`back\slash` -> `backslash`), so it could never match the
# real `back\slash` row yaml-toplevel.awk emits — a burial involving such a key
# would silently miss. ENVIRON does no such processing. This is a genericity/
# correctness check on the fixed code, not a before/after diff (the old code is
# gone), so it asserts the fix's observable effect: the burial is still caught.
SHBS=$SANDBOX/shape-backslash
SHBSSYN=$SHBS/synth
mkdir -p "$SHBSSYN" && cd "$SHBSSYN" && git init -q -b main
printf "'back\\\\slash':\n  mode: fast\nsibling:\n  x: 1\n" > deploy.yaml
git add -A && git commit -qm target && git tag kairos-target
SHBSWRK=$SHBS/work
mkdir -p "$SHBSWRK/run" && cd "$SHBSWRK" && git init -q -b main
printf "sibling:\n  x: 1\n  'back\\\\slash':\n    mode: fast\n" > deploy.yaml
git add -A && git commit -qm w
expect "the fixture genuinely carries a literal backslash in the key (pins fixture validity)" \
  bash -c "grep -qF 'back\\slash' '$SHBSWRK/deploy.yaml'"
bash -c "cd '$SHBSWRK' && SYNTH='$SHBSSYN' RUN='$SHBSWRK/run' LABEL=bs '$SKILL_DIR/scripts/yaml-gate.sh'" \
  > /dev/null 2>&1
YG_BSK_RC=$?
if [[ "$YG_BSK_RC" -ne 0 ]]; then pass "a burial of a backslash-carrying key fails the shape layer"; else fail "a burial of a backslash-carrying key passed the gate (the key comparison was mangled)"; fi
expect "the buried-key finding names the key with its backslash intact" \
  bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"buried-key\"{print \$4}' '$SHBSWRK/run/yaml-gate-bs.tsv' | grep -qF 'back\\slash'"
cd "$SANDBOX"
fi

if t "yaml-gate.sh discovery is NUL-safe — an embedded-newline path is scanned, and the count is of work done"; then
# Two defects in one shape. Discovery went through `tr '\0' '\n'`, so a tracked path
# containing a NEWLINE (legal in git — which is why every listing here is `-z`)
# became TWO lines, neither of which names a file: both were dropped by the
# `[ -f ]` test in the scan loop, so the file was never parsed or key-scanned. And
# $N_FILES was counted off the candidate list BEFORE the loop ran, so the report
# actively affirmed the coverage it had just lost ("clean — 2 YAML file(s) parsed"
# with one file scanned). The duplicate key planted in the newline-bearing file is
# what makes the drop observable, and the fixture asserts the split behaviour first
# so a still-splitting gate cannot pass this block vacuously.
YGNL=$SANDBOX/yamlgate-newline
mkdir -p "$YGNL/run" && cd "$YGNL" && git init -q -b main
printf 'a: 1\n' > plain.yaml
YGNL_F=$'two\nlines.yaml'
printf 'top:\n  resources: a\n  resources: b\n' > "$YGNL_F"
git add -A && git commit -qm init
expect "the fixture is genuinely tracked with an embedded newline (a tr-split list yields a phantom line)" \
  bash -c "cd '$YGNL' && git ls-files -z | tr '\0' '\n' | grep -qx 'lines.yaml'"
RUN=$YGNL/run LABEL=nl "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2> "$SANDBOX/yg-nl.log"
YG_NL_RC=$?
if [[ "$YG_NL_RC" -ne 0 ]]; then
  pass "a duplicate key inside an embedded-newline path fails the gate"
else
  fail "an embedded-newline path was dropped from the scan (its duplicate key was never found)"
fi
expect "the finding is recorded as a duplicate-key row" \
  bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"duplicate-key\"' '$YGNL/run/yaml-gate-nl.tsv' | grep -q resources"
expect "the file column still names the path" \
  bash -c "awk -F'\t' '{print \$2}' '$YGNL/run/yaml-gate-nl.tsv' | grep -q 'lines.yaml'"
# gate.sh counts rows by severity: a raw newline in the file column would split one
# finding into two physical rows, and the tail row would land on its
# unrecognized-severity arm — reporting gate-internal instead of the finding.
refute "no row carries a severity other than fail/skip (the path's newline is collapsed)" \
  bash -c "awk -F'\t' 'NF && \$1!=\"fail\" && \$1!=\"skip\"' '$YGNL/run/yaml-gate-nl.tsv' | grep -q ."
expect "the report counts both candidates as SCANNED, not the pre-loop list length" \
  grep -q 'checked 2 plain YAML' "$SANDBOX/yg-nl.log"
cd "$SANDBOX"
fi

if t "yaml-gate.sh — a listed candidate that is not a regular file gets its own skip row"; then
# The old loop dropped anything failing `[ -f ]` with no row and no count, while the
# report still claimed it as parsed. Absent is legitimate (the merge deleted it);
# present-but-not-a-file is a candidate nothing scanned, so it owes a row —
# INCOMPLETE at the gate, a mandatory acknowledgment at Phase 6 — never silence.
YGNF=$SANDBOX/yamlgate-notfile
mkdir -p "$YGNF/run" && cd "$YGNF" && git init -q -b main
printf 'a: 1\n' > plain.yaml
printf 'b: 2\n' > swapped.yaml
git add -A && git commit -qm init
# Still tracked (the index lists it), now a directory on disk.
rm -f swapped.yaml && mkdir swapped.yaml && printf 'c: 3\n' > swapped.yaml/inner.txt
RUN=$YGNF/run LABEL=nf "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2> "$SANDBOX/yg-nf.log"
expect "the unscannable candidate is recorded as a parse-layer skip naming it" \
  bash -c "awk -F'\t' '\$1==\"skip\" && \$3==\"parse\"' '$YGNF/run/yaml-gate-nf.tsv' | grep -q swapped.yaml"
expect "it is not counted as scanned — only the real file was parsed" \
  grep -q 'checked 1 plain YAML' "$SANDBOX/yg-nf.log"
expect "the reconciliation line accounts for every listed candidate" \
  grep -q 'not-a-file 1' "$SANDBOX/yg-nf.log"
refute "a run with an unscannable candidate never reports a clean gate" \
  bash -c "grep -qi '^clean' '$YGNF/run/yaml-gate-nf.txt'"
cd "$SANDBOX"
fi

if t "yaml-gate.sh — a vendored subchart's templates/ is excluded like the parent's"; then
# `helm dependency build` leaves the subchart vendored under chart/charts/<sub>/, and
# its templates/ tree is Go-template text like any other: it is rendered THROUGH the
# parent in layer 3, which is why the subchart's own Chart.yaml directory is dropped
# from $CHARTS. The templates/ exclusion was built only from the surviving parent
# entries, so those files reached `yq e '.'` and produced a `parse` FAIL at
# postmerge, midplan AND final — with no acknowledgment path ($ACK covers the
# buried-key layer only), i.e. a component that vendors its subcharts could not
# clear the gate at all. The subchart's plain YAML must still be scanned, which the
# scanned count below is the control for.
YGSC=$SANDBOX/yamlgate-subchart
mkdir -p "$YGSC/chart/templates" "$YGSC/chart/charts/common/templates" "$YGSC/run"
cd "$YGSC" && git init -q -b main
printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' > chart/Chart.yaml
printf 'replicas: 2\n' > chart/values.yaml
printf '{{- if .Values.replicas }}\nkind: ConfigMap\n{{- end }}\n' > chart/templates/cm.yaml
printf 'apiVersion: v2\nname: common\nversion: 1.0.0\n' > chart/charts/common/Chart.yaml
printf 'nameOverride: ""\n' > chart/charts/common/values.yaml
printf '{{- if .Values.enabled }}\nkind: Service\nmetadata:\n  name: {{ .Release.Name }}\n{{- end }}\n' \
  > chart/charts/common/templates/svc.yaml
git add -A && git commit -qm init
expect "the fixture's subchart template is genuinely not YAML (pins fixture validity)" \
  bash -c "! yq e '.' '$YGSC/chart/charts/common/templates/svc.yaml' >/dev/null 2>&1"
RUN=$YGSC/run LABEL=sub "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2> "$SANDBOX/yg-sub.log"
refute "a vendored subchart's Go templates are not a parse FAIL" \
  bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"parse\"' '$YGSC/run/yaml-gate-sub.tsv' 2>/dev/null | grep -q ."
refute "no finding at all names a templates/ path" \
  bash -c "grep -q 'templates/' '$YGSC/run/yaml-gate-sub.tsv' 2>/dev/null"
expect "both charts' plain YAML is still scanned (parent + subchart Chart.yaml and values.yaml)" \
  grep -q 'checked 4 plain YAML' "$SANDBOX/yg-sub.log"
cd "$SANDBOX"
fi

# The cwd IS the gate's parameter (reference/gates.md → The gate cwd): toplevel or
# the recorded frontend mount. An accidental subdir cwd used to scan just that
# subtree and certify it clean — the root's findings were never seen (SC2/R2,
# review 2026-08-25). The guard is discovery-only: an explicit FILES list names
# the scan set, and a non-repo cwd keeps its own pinned ls-files fail row above.
if t "wrong-cwd guard"; then
YGW=$SANDBOX/yamlgate-wrongcwd
mkdir -p "$YGW/run" "$YGW/web" && cd "$YGW" && git init -q -b main
printf 'dup: 1\ndup: 2\n' > bad.yaml
printf 'ok: 1\n' > web/ok.yaml
git add -A && git commit -qm init

( cd web && RUN="$YGW/run" LABEL=wrongcwd "$SKILL_DIR/scripts/yaml-gate.sh" ) >/dev/null 2>&1
if [[ $? -ne 0 ]]; then pass "a subdir cwd with no recorded mount is refused, never scanned to a clean verdict"; else fail "a subdir cwd scanned to exit 0 — the root's duplicate key was never seen"; fi
expect "the refusal is a parse-layer fail row naming the wrong cwd" \
  bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"parse\"' '$YGW/run/yaml-gate-wrongcwd.tsv' | grep -q 'wrong gate cwd'"
expect "the row names both sanctioned directories' roles (toplevel + mount)" \
  bash -c "grep -q 'git toplevel' '$YGW/run/yaml-gate-wrongcwd.tsv' && grep -q 'frontend mount' '$YGW/run/yaml-gate-wrongcwd.tsv'"

# The recorded frontend mount is the ONE sanctioned non-root cwd — derived from
# the same $RUN gate.sh hands down, not announced by a bypassable env.
printf 'FRONTEND_MOUNT=web\n' > "$YGW/run/context.env"
( cd web && RUN="$YGW/run" LABEL=mountcwd "$SKILL_DIR/scripts/yaml-gate.sh" ) >/dev/null 2>&1
expect "the recorded frontend mount is accepted and its clean subtree passes" test $? -eq 0
refute "the accepted mount run carries no wrong-cwd row" \
  grep -q 'wrong gate cwd' "$YGW/run/yaml-gate-mountcwd.tsv"

RUN=$YGW/run LABEL=rootcwd "$SKILL_DIR/scripts/yaml-gate.sh" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then pass "the toplevel cwd is accepted and the root duplicate key FAILS the gate"; else fail "the toplevel scan missed the root duplicate key"; fi
expect "the toplevel run's finding is the duplicate key, not a cwd refusal" \
  bash -c "awk -F'\t' '\$1==\"fail\" && \$3==\"duplicate-key\"' '$YGW/run/yaml-gate-rootcwd.tsv' | grep -q bad.yaml"

( cd web && FILES='ok.yaml' RUN="$YGW/run" LABEL=filescwd "$SKILL_DIR/scripts/yaml-gate.sh" ) >/dev/null 2>&1
expect "an explicit FILES list from a subdir is not refused — the caller names the scan set" test $? -eq 0
cd "$SANDBOX"
fi

finish_suite
