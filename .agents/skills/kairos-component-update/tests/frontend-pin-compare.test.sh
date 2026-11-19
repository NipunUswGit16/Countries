#!/usr/bin/env bash
# frontend-pin-compare.test.sh — tests for scripts/frontend-pin-compare.sh
#
# The compare is driven by FIXTURE PAIRS: a template-at-TARGET manifest and a component
# mount manifest, both small hand-written package.json files (Testing Decisions in the
# PRD: "fixture pair trees ... so tests do not need a full frontend mirror"). Each block
# builds its own pair, runs the compare, and asserts the emitted pin-compare.tsv and the
# operator-visible verdicts — not how the semver is parsed internally beyond a few
# specifier examples. One block exercises the real SYNTH git-tag extraction path.
#
# TEST_FILTER supported (blocks are independent — each owns its run dir and fixtures).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

PC="$SKILL_DIR/scripts/frontend-pin-compare.sh"

# write_manifest <path> <deps-json-body>
# Wraps a `"name": "spec", ...` body into a minimal package.json under `dependencies`.
write_manifest() { # write_manifest <path> <body>
  mkdir -p "$(dirname "$1")"
  printf '{\n  "name": "fixture",\n  "dependencies": {\n%s\n  }\n}\n' "$2" > "$1"
}

# run_pc <run-dir> <template-manifest> <component-manifest> [run_source]
# Seeds RUN_SOURCE (default frontend) onto the run anchor and invokes the compare with the
# Phase 3 key it shares with build-manifest.sh / collect-lib.sh.
run_pc() { # run_pc <run> <tpl> <comp> [src]
  local run="$1" tpl="$2" comp="$3" src="${4:-frontend}"
  mkdir -p "$run"
  printf 'RUN_SOURCE=%s\n' "$src" > "$run/context.env"
  RUN="$run" PHASE_KEY=$PK_CLASSIFY MOUNT="web/" \
    TEMPLATE_MANIFEST="$tpl" COMPONENT_MANIFEST="$comp" \
    "$PC"
}

# verdict_is <run> <package> <want>
verdict_is() { # verdict_is <run> <pkg> <want>
  local got
  got=$(awk -F'\t' -v p="$2" '$1==p { print $2; exit }' "$1/pin-compare.tsv")
  if [[ "$got" = "$3" ]]; then pass "verdict $2 = $3"; else fail "verdict $2 = ${got:-<none>} (want $3)"; fi
}
no_row() { # no_row <run> <pkg>
  if awk -F'\t' -v p="$2" '$1==p { found=1 } END { exit !found }' "$1/pin-compare.tsv"; then
    fail "expected NO row for $2 but found one"
  else pass "no row for $2"; fi
}

# ---------------------------------------------------------------------------

if t "a component behind the template pins every stale key as behind"; then
R=$SANDBOX/behind/state
write_manifest "$SANDBOX/behind/tpl.json" '    "@ifs-kairos/api": "0.10.1",
    "@ifs-kairos/auth": "0.10.1",
    "@ifs-ds/helix-web-components": "0.4.1"'
write_manifest "$SANDBOX/behind/comp.json" '    "@ifs-kairos/api": "0.9.1",
    "@ifs-kairos/auth": "^0.9.1",
    "@ifs-ds/helix-web-components": "0.4.0",
    "react": "19.2.7"'
run_pc "$R" "$SANDBOX/behind/tpl.json" "$SANDBOX/behind/comp.json" > "$SANDBOX/behind.out" 2>&1
expect "exit 0" test $? -eq 0
verdict_is "$R" "@ifs-kairos/api" behind
verdict_is "$R" "@ifs-kairos/auth" behind      # caret ^0.9.1 resolves-min to 0.9.1 < 0.10.1
verdict_is "$R" "@ifs-ds/helix-web-components" behind
no_row "$R" react                              # a non-owned dep is never compared
expect "summary counts three behind" grep -q 'behind=3' "$SANDBOX/behind.out"
expect "records PIN_COMPARE=present on the anchor" grep -q '^PIN_COMPARE=present' "$R/context.env"
fi

if t "an equal pin (exact match, and caret over the same minimum) produces no task"; then
R=$SANDBOX/equal/state
write_manifest "$SANDBOX/equal/tpl.json" '    "@ifs-kairos/api": "0.10.1",
    "@ifs-ds/helix-icons": "0.2.0"'
write_manifest "$SANDBOX/equal/comp.json" '    "@ifs-kairos/api": "^0.10.1",
    "@ifs-ds/helix-icons": "0.2.0"'
run_pc "$R" "$SANDBOX/equal/tpl.json" "$SANDBOX/equal/comp.json" > "$SANDBOX/equal.out" 2>&1
verdict_is "$R" "@ifs-kairos/api" equal        # ^0.10.1 floats over 0.10.1 → equal minimum
verdict_is "$R" "@ifs-ds/helix-icons" equal
expect "no behind and no ahead in the summary" grep -q 'behind=0 ahead=0 equal=2' "$SANDBOX/equal.out"
fi

if t "a beta pin newer than the template is ahead (skip-downgrade), never behind"; then
R=$SANDBOX/ahead/state
write_manifest "$SANDBOX/ahead/tpl.json" '    "@ifs-kairos/api": "0.10.1"'
write_manifest "$SANDBOX/ahead/comp.json" '    "@ifs-kairos/api": "0.11.0-beta.615"'
run_pc "$R" "$SANDBOX/ahead/tpl.json" "$SANDBOX/ahead/comp.json" > "$SANDBOX/ahead.out" 2>&1
verdict_is "$R" "@ifs-kairos/api" ahead
expect "summary counts one ahead" grep -q 'ahead=1' "$SANDBOX/ahead.out"
fi

if t "a template key the component lacks is behind, with component-spec '-'"; then
R=$SANDBOX/missing/state
write_manifest "$SANDBOX/missing/tpl.json" '    "@ifs-kairos/api": "0.10.1",
    "@ifs-kairos/translation": "0.10.1"'
write_manifest "$SANDBOX/missing/comp.json" '    "@ifs-kairos/api": "0.10.1"'
run_pc "$R" "$SANDBOX/missing/tpl.json" "$SANDBOX/missing/comp.json" >/dev/null 2>&1
verdict_is "$R" "@ifs-kairos/translation" behind
expect "the absent component key records a '-' component-spec" \
  bash -c "awk -F'\t' '\$1==\"@ifs-kairos/translation\"{exit !(\$3==\"-\")}' '$R/pin-compare.tsv'"
fi

if t "a Kairos package the template does not pin is left alone (no row, never deleted)"; then
R=$SANDBOX/extra/state
write_manifest "$SANDBOX/extra/tpl.json" '    "@ifs-kairos/api": "0.10.1"'
write_manifest "$SANDBOX/extra/comp.json" '    "@ifs-kairos/api": "0.10.1",
    "@ifs-kairos/experimental-editor": "1.2.3"'
run_pc "$R" "$SANDBOX/extra/tpl.json" "$SANDBOX/extra/comp.json" >/dev/null 2>&1
no_row "$R" "@ifs-kairos/experimental-editor"  # US 7: extra @ifs-kairos/* is not "behind"
verdict_is "$R" "@ifs-kairos/api" equal
fi

if t "a non-semver component pin (co-dev link:) is ahead, never overwritten"; then
R=$SANDBOX/link/state
write_manifest "$SANDBOX/link/tpl.json" '    "@ifs-kairos/auth": "0.10.1"'
write_manifest "$SANDBOX/link/comp.json" '    "@ifs-kairos/auth": "link:../kairos-auth"'
run_pc "$R" "$SANDBOX/link/tpl.json" "$SANDBOX/link/comp.json" >/dev/null 2>&1
verdict_is "$R" "@ifs-kairos/auth" ahead
fi

if t "tilde and >= specifiers are compared by resolved minimum"; then
R=$SANDBOX/ranges/state
write_manifest "$SANDBOX/ranges/tpl.json" '    "@ifs-kairos/api": "0.10.1",
    "@ifs-kairos/net": "0.10.1"'
write_manifest "$SANDBOX/ranges/comp.json" '    "@ifs-kairos/api": "~0.9.1",
    "@ifs-kairos/net": ">=0.10.1"'
run_pc "$R" "$SANDBOX/ranges/tpl.json" "$SANDBOX/ranges/comp.json" >/dev/null 2>&1
verdict_is "$R" "@ifs-kairos/api" behind       # ~0.9.1 → 0.9.1 < 0.10.1
verdict_is "$R" "@ifs-kairos/net" equal        # >=0.10.1 → 0.10.1 == 0.10.1
fi

if t "rows are sorted by package name for a stable artifact"; then
R=$SANDBOX/sorted/state
write_manifest "$SANDBOX/sorted/tpl.json" '    "@ifs-kairos/react": "0.10.1",
    "@ifs-kairos/api": "0.10.1",
    "@ifs-ds/helix-icons": "0.2.0"'
write_manifest "$SANDBOX/sorted/comp.json" '    "@ifs-kairos/react": "0.9.1",
    "@ifs-kairos/api": "0.9.1",
    "@ifs-ds/helix-icons": "0.1.0"'
run_pc "$R" "$SANDBOX/sorted/tpl.json" "$SANDBOX/sorted/comp.json" >/dev/null 2>&1
expect "pin-compare.tsv is byte-identical to its own LC_ALL=C sort" \
  bash -c "LC_ALL=C sort -c '$R/pin-compare.tsv'"
fi

if t "a template run idles: exits 0, records nothing, writes no TSV"; then
R=$SANDBOX/tmpl/state
write_manifest "$SANDBOX/tmpl/tpl.json" '    "@ifs-kairos/api": "0.10.1"'
write_manifest "$SANDBOX/tmpl/comp.json" '    "@ifs-kairos/api": "0.9.1"'
run_pc "$R" "$SANDBOX/tmpl/tpl.json" "$SANDBOX/tmpl/comp.json" template > "$SANDBOX/tmpl.out" 2>&1
expect "a template-run invocation exits 0" test $? -eq 0
expect "the idle skip names RUN_SOURCE" grep -q 'not applicable' "$SANDBOX/tmpl.out"
refute "a template run never writes pin-compare.tsv" test -f "$R/pin-compare.tsv"
refute "a template run never records PIN_COMPARE (absence IS the record)" \
  grep -q '^PIN_COMPARE=' "$R/context.env"
fi

if t "a template manifest that does not parse is a hard error (never 'pins nothing')"; then
R=$SANDBOX/broken/state
mkdir -p "$SANDBOX/broken"
printf '{ this is not json ' > "$SANDBOX/broken/tpl.json"
write_manifest "$SANDBOX/broken/comp.json" '    "@ifs-kairos/api": "0.9.1"'
run_pc "$R" "$SANDBOX/broken/tpl.json" "$SANDBOX/broken/comp.json" > "$SANDBOX/broken.out" 2>&1
expect "exit 1 on an unparseable template manifest" test $? -eq 1
expect "the failure names the manifest" grep -q 'not parseable JSON' "$SANDBOX/broken.out"
refute "no TSV is written on the hard error" test -f "$R/pin-compare.tsv"
fi

if t "a template that pins no owned key records PIN_COMPARE=none"; then
R=$SANDBOX/none/state
write_manifest "$SANDBOX/none/tpl.json" '    "react": "19.2.7",
    "zod": "4.4.3"'
write_manifest "$SANDBOX/none/comp.json" '    "react": "19.0.0"'
run_pc "$R" "$SANDBOX/none/tpl.json" "$SANDBOX/none/comp.json" > "$SANDBOX/none.out" 2>&1
expect "records PIN_COMPARE=none" grep -q '^PIN_COMPARE=none' "$R/context.env"
expect "the TSV is present but empty" bash -c "test -f '$R/pin-compare.tsv' && ! test -s '$R/pin-compare.tsv'"
fi

if t "a missing component mount manifest idles as PIN_COMPARE=none (not a hard error)"; then
R=$SANDBOX/nocomp/state
write_manifest "$SANDBOX/nocomp/tpl.json" '    "@ifs-kairos/api": "0.10.1"'
run_pc "$R" "$SANDBOX/nocomp/tpl.json" "$SANDBOX/nocomp/does-not-exist.json" > "$SANDBOX/nocomp.out" 2>&1
expect "exit 0 when the component has no mount manifest yet" test $? -eq 0
expect "records PIN_COMPARE=none" grep -q '^PIN_COMPARE=none' "$R/context.env"
fi

if t "the SYNTH git-tag extraction path compares the TARGET tree manifest"; then
# The real-run left side: no TEMPLATE_MANIFEST, so it is extracted from the synthetic
# repo at kairos-target:web/package.json.
S=$SANDBOX/synth/synthetic
mkdir -p "$S/web"
( cd "$S" && git init -q -b main )
write_manifest "$S/web/package.json" '    "@ifs-kairos/api": "0.9.1"'
( cd "$S" && git add -A && git commit -qm base && git tag kairos-base )
write_manifest "$S/web/package.json" '    "@ifs-kairos/api": "0.10.1"'
( cd "$S" && git add -A && git commit -qm target && git tag kairos-target )
R=$SANDBOX/synth/state; mkdir -p "$R"
printf 'RUN_SOURCE=frontend\n' > "$R/context.env"
write_manifest "$SANDBOX/synth/comp.json" '    "@ifs-kairos/api": "0.9.1"'
RUN="$R" PHASE_KEY=$PK_CLASSIFY MOUNT="web/" SYNTH="$S" \
  COMPONENT_MANIFEST="$SANDBOX/synth/comp.json" "$PC" >/dev/null 2>&1
expect "exit 0 extracting from the synthetic TARGET tree" test $? -eq 0
verdict_is "$R" "@ifs-kairos/api" behind       # component 0.9.1 vs kairos-target 0.10.1
fi

if t "the phase key is required (a stub-knowledge invocation is refused)"; then
R=$SANDBOX/key/state; mkdir -p "$R"
printf 'RUN_SOURCE=frontend\n' > "$R/context.env"
write_manifest "$SANDBOX/key/tpl.json" '    "@ifs-kairos/api": "0.10.1"'
write_manifest "$SANDBOX/key/comp.json" '    "@ifs-kairos/api": "0.9.1"'
RUN="$R" PHASE_KEY=wrongkey MOUNT="web/" \
  TEMPLATE_MANIFEST="$SANDBOX/key/tpl.json" COMPONENT_MANIFEST="$SANDBOX/key/comp.json" \
  "$PC" > "$SANDBOX/key.out" 2>&1
expect "a wrong PHASE_KEY exits 1" test $? -eq 1
expect "the refusal names the phase file" grep -q 'phases/3-classify.md' "$SANDBOX/key.out"
fi

finish_suite
