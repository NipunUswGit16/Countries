#!/usr/bin/env bash
# frontend-pin-compare.sh — on a FRONTEND run, compare the Kairos (`@ifs-kairos/*`)
# and Helix (`@ifs-ds/*`) dependency specifiers the frontend template pins AT TARGET
# against the same keys in the component's CURRENT mount manifest, and write one
# verdict row per template-pinned package (`equal` | `behind` | `ahead`).
#
# WHY THIS EXISTS — the gap neither the 3-way merge nor Model-A lib collection covers:
# the frontend template's `package.json` is a `kind: template` file, 3-way merged into
# the component's mount. The merge only replays the template delta in BASE..TARGET, so
# a pin bump that landed BEFORE the run's frontend BASE never opens `package.json` at
# all — the component keeps its older `@ifs-kairos/*` pins after a "green" merge. Model-A
# `kind: library` collection (collect-lib.sh) walks the same SHA range and never parses
# npm versions, so it plans no bump either. The observed cost of the silent skew is real
# (notes-demo): `ffw-components` 0.9.x still pulls Web Awesome and crashes jsdom on
# `ElementInternals.setValidity`; `auth` 0.9.x rejects a fresh `configureAuth({ authBasePath })`
# literal with TS2561. This check is the ONLY thing that reads the two manifests side by
# side and turns a behind pin into a planned, committed, re-verified bump task.
#
# WHY IT IS THE FRONTEND ANALOGUE OF collect-common's skip-downgrade, NOT a new idea:
# common collection reads the component's live `go.mod` require against the template's
# pin and lands `skip-downgrade` when the component is at/ahead of the template. This is
# the same shape for npm: read the component's live specifier against the template's, and
# an `ahead` verdict (a beta/co-dev pin newer than the template — todo-demo's
# `0.11.0-beta.*` is the wild example) is a skip-downgrade the executor must NOT write.
# A component must never be silently downgraded to the template's pin.
#
# WHY ONLY TEMPLATE-PINNED KEYS PRODUCE A ROW: the compare iterates the KEYS THE TEMPLATE
# PINS, filtered to the two owned scopes. A `@ifs-kairos/*` the component added itself and
# the template does not pin (an editor, an SSE client, an app-specific tool) is never in
# that iteration, so it is never a row and never "behind the template" — it is simply left
# alone. A template-pinned key the component LACKS is `behind` (a dropped dependency the
# template expects), so a bump/add task carries it rather than the run staying silent.
#
# WHY "resolved minimum", not string compare: npm specifiers carry a range operator.
# `^0.9.1` and `0.10.1` are ordered by their resolved MINIMUM (`0.9.1` < `0.10.1` →
# behind); `^0.10.1` vs `0.10.1` share a minimum → equal (no bump for a caret that already
# floats over the pin); `0.11.0-beta.615` vs `0.10.1` is ahead (a higher base still wins a
# prerelease compare). A component specifier that is NOT a plain semver (a `link:` /
# `file:` / `workspace:` co-dev pin) is treated as `ahead` — never overwrite a deliberate
# local override with the template's release pin. This is the same protectiveness the Go
# arm gives a local `replace`.
#
# WHY IT LEAVES THE REST OF THE PIPELINE UNTOUCHED (PRD invariants): it does NOT change
# BASE detection, the 3-way merge, bellwether scoring (package.json is never hashed as a
# whole-file baseline), or `kind: library` Model-A collection (still a SHA range, still no
# npm parsing). It reads two manifests and writes one TSV. The planner (Phase 6) turns a
# `behind` row into a bump task and an `ahead` row into a recorded skip-downgrade.
#
# Env in:
#   PHASE_KEY          required — same key as build-manifest.sh / collect-lib.sh
#                      (phases/3-classify.md); this runs in the frontend arm of Phase 3,
#                      immediately after collect-lib.sh.
#   RUN                required — migration state dir; output goes here.
#   RUN_SOURCE         read from $RUN/context.env — ONLY `frontend` proceeds. A template
#                      run (or a call with no RUN_SOURCE) idles, exits 0, and records
#                      NOTHING (absence of PIN_COMPARE is the template-run record, the
#                      same contract collect-lib.sh's LIB_MODULES uses).
#   MOUNT              optional — the frontend mount subdir (e.g. `web/`). Default: the
#                      anchor's FRONTEND_MOUNT, else `web/`. Both manifests are read at
#                      `<mount>/package.json` — the component's from cwd, the template's
#                      from the synthetic TARGET tree.
#   TEMPLATE_MANIFEST  optional — explicit path to the template-at-TARGET mount
#                      package.json. When unset it is extracted from the synthetic repo
#                      (SYNTH) at `kairos-target:<mount>package.json`. Set is the test
#                      seam AND an override; the default is the real-run path.
#   COMPONENT_MANIFEST optional — explicit path to the component's mount package.json.
#                      Default: `<mount>package.json` relative to cwd (the component root).
#   SYNTH              optional — the synthetic repo materialize-frontend.sh built (tags
#                      kairos-base / kairos-target). Default $RUN/synthetic. Only used to
#                      extract TEMPLATE_MANIFEST when it is not passed explicitly.
# Out (in $RUN):
#   pin-compare.tsv    package <TAB> verdict <TAB> component-spec <TAB> template-spec,
#                      ONE row per template-pinned Kairos/Helix package, SORTED by package
#                      for a stable artifact. verdict ∈ equal | behind | ahead. A component
#                      that pins none of them yields an empty (present) file. Component
#                      key absent → component-spec is `-` and the verdict is `behind`.
#   PIN_COMPARE=present|none   on $RUN/context.env — `present` once the TSV is written on
#                      a frontend run (even all-equal); `none` when the template pins no
#                      comparable Kairos/Helix key at all (nothing for the planner to do).
# Stdout:  one `PIN_COMPARE: behind=<n> ahead=<n> equal=<n> (total <n>)` summary line for
#          the phase to relay, then any `BEHIND`/`AHEAD` detail lines (TAB-separated,
#          `<verdict-upper> <TAB> package <TAB> component-spec <TAB> template-spec`).
# Exit:    0 on success (including all-equal / empty). 1 only when an input is broken — a
#          missing/unreadable/unparseable template manifest is a hard error (never read as
#          "the template pins nothing", the same lesson extract-template-gomod.sh carries).
set -u

fail() { echo "FAIL: $*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)

: "${RUN:?FAIL: RUN not set}"

# Phase-load guard: this key is stated only in phases/3-classify.md (shared with
# build-manifest.sh and collect-lib.sh — this script is the third member of that
# frontend-arm unit). An orchestrator that skipped loading that phase cannot know it.
[[ "${PHASE_KEY:-}" = "i82l699l" ]] || fail "load phases/3-classify.md first"

TAB=$(printf '\t')

# --- arm guard (mirrors collect-lib.sh) --------------------------------------
# A template run (or a call with no RUN_SOURCE) records NOTHING — absence of
# PIN_COMPARE is the template-run record; writing a verdict here would be a
# frontend answer forced onto a run that never touched a package.json.
RUN_SOURCE=""
[[ -f "$RUN/context.env" ]] \
  && RUN_SOURCE=$(sed -n 's/^RUN_SOURCE=//p' "$RUN/context.env" | tail -1 | tr -d '\r')
if [[ "$RUN_SOURCE" != frontend ]]; then
  echo "INFO: not applicable — frontend-pin-compare.sh runs only on a frontend run (RUN_SOURCE=frontend); this invocation is ${RUN_SOURCE:-<unset>}. Recorded nothing (PIN_COMPARE stays absent, which is the template-run record)." >&2
  exit 0
fi

# --- resolve the mount and both manifests ------------------------------------
MOUNT=${MOUNT:-}
if [[ -z "$MOUNT" ]] && [[ -f "$RUN/context.env" ]]; then
  MOUNT=$(sed -n 's/^FRONTEND_MOUNT=//p' "$RUN/context.env" | tail -1 | tr -d '\r')
fi
MOUNT=${MOUNT:-web/}
case "$MOUNT" in */) ;; *) MOUNT="$MOUNT/" ;; esac   # normalize to a trailing slash

COMPONENT_MANIFEST=${COMPONENT_MANIFEST:-${MOUNT}package.json}

# The template side comes from the synthetic TARGET tree unless handed a path. Never a
# bare redirect: `git show > file` creates the file before git runs, so a bad ref/path
# leaves a zero-byte manifest that the parser below would read as "pins nothing" — the
# exact silent-skip extract-template-gomod.sh was hardened against. Capture to a variable,
# verify it parses as JSON with a dependencies shape, and only then treat it as the pins.
TEMPLATE_MANIFEST=${TEMPLATE_MANIFEST:-}
SYNTH=${SYNTH:-$RUN/synthetic}
TPL_TMP=""
cleanup() { [[ -n "$TPL_TMP" ]] && rm -f "$TPL_TMP"; }
trap cleanup EXIT
if [[ -z "$TEMPLATE_MANIFEST" ]]; then
  [[ -d "$SYNTH" ]] || fail "no TEMPLATE_MANIFEST and no synthetic repo at SYNTH=$SYNTH — the template-at-TARGET mount manifest is the left side of the compare; re-run phases/2.5-materialize.md (frontend arm) or pass TEMPLATE_MANIFEST"
  TPL_TMP=$(mktemp "${TMPDIR:-/tmp}/pin-compare-tpl.XXXXXX")
  git -C "$SYNTH" show "kairos-target:${MOUNT}package.json" > "$TPL_TMP" 2>/dev/null \
    || fail "could not read kairos-target:${MOUNT}package.json from the synthetic repo ($SYNTH) — the TARGET mount has no package.json, or MOUNT ($MOUNT) is wrong"
  TEMPLATE_MANIFEST=$TPL_TMP
fi

[[ -r "$TEMPLATE_MANIFEST" ]] || fail "template manifest not readable: $TEMPLATE_MANIFEST"
# Shape guard: `go mod edit -json` is collect-common's validator; ours is `yq`'s own
# parse. An unparseable manifest is a hard error, never an empty pin set.
yq -p=json -e '.' < "$TEMPLATE_MANIFEST" >/dev/null 2>&1 \
  || fail "template manifest is not parseable JSON: $TEMPLATE_MANIFEST"

if [[ ! -r "$COMPONENT_MANIFEST" ]]; then
  # A frontend run whose mount has no package.json cannot be compared. This is not the
  # broken-input case (the component simply has no manifest yet — a not-yet-bootstrapped
  # mount); record `none` and idle rather than fail, since there are no component pins to
  # measure against. The bootstrap itself is Phase 5's job.
  echo "INFO: component mount manifest not found ($COMPONENT_MANIFEST) — nothing to compare; recording PIN_COMPARE=none." >&2
  : > "$RUN/pin-compare.tsv"
  echo "PIN_COMPARE=none"
  RUN="$RUN" "$HERE/record-context.sh" "PIN_COMPARE=none"
  echo "PIN_COMPARE: behind=0 ahead=0 equal=0 (total 0)"
  exit 0
fi
yq -p=json -e '.' < "$COMPONENT_MANIFEST" >/dev/null 2>&1 \
  || fail "component manifest is not parseable JSON: $COMPONENT_MANIFEST"

# --- npm specifier compare ---------------------------------------------------
# The resolved MINIMUM of a specifier: strip a leading range operator (^ ~ >= <= > < =)
# and an optional leading v, then take the token up to the first space (a compound range's
# first bound is its minimum). "" for a specifier with no semver-looking core.
npm_min() { # npm_min <specifier>
  printf '%s' "$1" \
    | sed -E 's/^[[:space:]]+//; s/^[v^~]//; s/^(>=|<=|>|<|=)//; s/[[:space:]].*$//'
}
is_semver() { case "$1" in [0-9]*.[0-9]*) return 0 ;; *) return 1 ;; esac; }

# is $1 >= $2 ? (npm semver, no leading v). Pre-release aware, identical in spirit to
# collect-common.sh's semver_ge: sort -V orders a `-suffix` AFTER its release, which is
# backwards for semver precedence, so equal bases are settled by "release beats
# pre-release" and only differing bases (or two pre-releases of one base) defer to sort -V.
semver_ge() {
  [[ "$1" = "$2" ]] && return 0
  local a="$1" b="$2" abase bbase
  abase=${a%%-*}
  bbase=${b%%-*}
  if [[ "$abase" != "$bbase" ]]; then
    [[ "$(printf '%s\n%s\n' "$abase" "$bbase" | sort -V | tail -1)" = "$abase" ]]
  elif [[ "$a" = "$abase" ]]; then
    return 0   # a is the release, b (differing) is a pre-release of it
  elif [[ "$b" = "$bbase" ]]; then
    return 1   # b is the release, a is a pre-release of it
  else
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]]
  fi
}
semver_gt() { [[ "$1" != "$2" ]] && semver_ge "$1" "$2"; }

# verdict <component-spec> <template-spec> — echoes equal|behind|ahead, OR nothing (empty)
# when the package must be SKIPPED (a template specifier with no comparable version).
verdict() {
  local cspec="$1" tspec="$2" cmin tmin
  tmin=$(npm_min "$tspec")
  is_semver "$tmin" || { printf ''; return 0; }   # template pin uncomparable → skip row
  if [[ "$cspec" = "-" ]]; then printf 'behind'; return 0; fi   # component lacks the key
  cmin=$(npm_min "$cspec")
  # A non-semver component pin (link:/file:/workspace:/a URL) is a deliberate local
  # override — treat as ahead so the executor never overwrites it with the template pin.
  is_semver "$cmin" || { printf 'ahead'; return 0; }
  if [[ "$cmin" = "$tmin" ]]; then printf 'equal'
  elif semver_gt "$cmin" "$tmin"; then printf 'ahead'
  else printf 'behind'
  fi
}

# name<TAB>spec for every dependencies+devDependencies entry, dependencies winning a
# duplicate (matches write-test-commands.sh's merge order).
deps_of() { # deps_of <manifest>
  # @tsv (not `.key + "\t" + …`) — yq's string escapes are version-fragile: mikefarah
  # yq <=4.44 emits `"\t"` as a literal backslash-t, only >=4.5x as a real tab, so the
  # concat form silently produced un-splittable rows under BB's pinned yq. @tsv writes a
  # real tab in every version.
  yq -p=json -r '((.devDependencies // {}) * (.dependencies // {})) | to_entries | .[] | [.key, (.value | tostring)] | @tsv' < "$1"
}
# Is this an owned scope — a Kairos or Helix package the compare governs?
is_owned() { case "$1" in @ifs-kairos/*|@ifs-ds/*) return 0 ;; *) return 1 ;; esac; }

# Component specs into a `name<TAB>spec` lookup file (owned scopes only). A plain file,
# not a bash associative array — the rest of this skill's scripts run on bash 3.2 (macOS
# default), which has none, and the compare must stay portable to that shell.
COMP_FILE=$(mktemp "${TMPDIR:-/tmp}/pin-compare-comp.XXXXXX")
ROWS=$(mktemp "${TMPDIR:-/tmp}/pin-compare-rows.XXXXXX")
cleanup_all() { cleanup; rm -f "$COMP_FILE" "$ROWS"; }
trap cleanup_all EXIT
while IFS="$TAB" read -r name spec; do
  [[ -n "$name" ]] || continue
  is_owned "$name" || continue
  printf '%s\t%s\n' "$name" "$spec" >> "$COMP_FILE"
done < <(deps_of "$COMPONENT_MANIFEST")

# Iterate the TEMPLATE's owned keys — those are the only packages compared. Emit rows to a
# temp file first so we can sort into the stable artifact and tally in one pass.
TPL_KEYS=0
while IFS="$TAB" read -r name tspec; do
  [[ -n "$name" ]] || continue
  is_owned "$name" || continue
  TPL_KEYS=$((TPL_KEYS+1))
  cspec=$(awk -F'\t' -v n="$name" '$1==n { print $2; exit }' "$COMP_FILE")
  [[ -n "$cspec" ]] || cspec="-"                  # not pinned by the component → absent
  v=$(verdict "$cspec" "$tspec")
  [[ -n "$v" ]] || continue                       # skipped (uncomparable template pin)
  printf '%s\t%s\t%s\t%s\n' "$name" "$v" "$cspec" "$tspec" >> "$ROWS"
done < <(deps_of "$TEMPLATE_MANIFEST")

# The template pins no comparable Kairos/Helix key at all → nothing for the planner.
if [[ "$TPL_KEYS" -eq 0 ]]; then
  : > "$RUN/pin-compare.tsv"
  echo "PIN_COMPARE=none"
  RUN="$RUN" "$HERE/record-context.sh" "PIN_COMPARE=none"
  echo "PIN_COMPARE: behind=0 ahead=0 equal=0 (total 0)"
  exit 0
fi

LC_ALL=C sort -t"$TAB" -k1,1 "$ROWS" > "$RUN/pin-compare.tsv"

BEHIND=$(awk -F'\t' '$2=="behind"' "$RUN/pin-compare.tsv" | wc -l | tr -d ' ')
AHEAD=$(awk -F'\t' '$2=="ahead"'  "$RUN/pin-compare.tsv" | wc -l | tr -d ' ')
EQUAL=$(awk -F'\t' '$2=="equal"'  "$RUN/pin-compare.tsv" | wc -l | tr -d ' ')
TOTAL=$(wc -l < "$RUN/pin-compare.tsv" | tr -d ' ')

echo "PIN_COMPARE=present"
RUN="$RUN" "$HERE/record-context.sh" "PIN_COMPARE=present"

printf 'PIN_COMPARE: behind=%s ahead=%s equal=%s (total %s)\n' "$BEHIND" "$AHEAD" "$EQUAL" "$TOTAL"
# Detail lines for the phase to relay (behind first, then ahead — equal is silent).
awk -F'\t' '$2=="behind"{ printf "BEHIND\t%s\t%s\t%s\n",$1,$3,$4 }' "$RUN/pin-compare.tsv"
awk -F'\t' '$2=="ahead"{  printf "AHEAD\t%s\t%s\t%s\n", $1,$3,$4 }' "$RUN/pin-compare.tsv"
exit 0
