#!/usr/bin/env bash
# resolve-models.test.sh — tests for scripts/resolve-models.sh
# TEST_FILTER refused (blocks share sequential model fixtures).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in resolve-models.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "resolve-models.sh — asymmetric cost rule, family matching, budget postures"; then
# Fixture-driven, hermetic (no network, no ~/.kairos): every case drives OFFERED
# with the harness's real advertised names and a fixture HOME_CONFIG (or /dev/null
# for "no answers"). Regression guard: no assertion names a slug outside its own
# fixture's OFFERED list — only derived behavior (which offered slug won, which
# cost class, which diagnostic). The catalog is family-keyed precisely so slugs move.
RMS="$SKILL_DIR/scripts/resolve-models.sh"
# resolve-models.sh is Phase 1.5's entry point. Its key is exported once for the
# fixture body below (45 invocations, all of them legitimately inside the phase);
# the guard itself is asserted in its own block at the end of this suite.
export PHASE_KEY=$(phase_key 1.5-model-resolution.md)
# Standing configuration must not leak into the fixtures: a developer with these
# exported in a shell profile would otherwise override every derivation below.
unset KAIROS_UPDATE_STRONG_MODEL KAIROS_UPDATE_CODER_MODEL KAIROS_UPDATE_EXECUTOR_MODEL
kv_is() { # kv_is <model.txt> <key> <want> <desc>
  local got; got=$(sed -n "s/^$2=//p" "$1" | head -1)
  if [[ "$got" = "$3" ]]; then pass "$4"; else fail "$4 (got '${got:-<none>}', want '$3')"; fi
}

# --- Cursor-shaped list: the core regression this PRD exists to prevent -------
# executor and routine verifier must land on the strongest INCLUDED family
# (cursor-grok), not the cheapest included one (composer).
R=$SANDBOX/rm-cursor; E=$SANDBOX/rm-cursor.err
OFFERED=$'cursor-grok-4.5-high-fast\ncomposer-2.5\nclaude-sonnet-5\nclaude-opus-5' \
  BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "cursor: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor cursor-grok-4.5-high-fast "cursor: executor = strongest INCLUDED family, not cheapest (regression)"
refute "cursor: executor is NOT the cheapest included family (composer)" \
  grep -qx 'executor=composer-2.5' "$R/model.txt"
kv_is "$R/model.txt" coder cursor-grok-4.5-high-fast "cursor: coder = strongest included clearing the coder bar"
kv_is "$R/model.txt" strong claude-opus-5 "cursor: strong = opus (no included clears the strong bar; tier-matched metered)"
kv_is "$R/model.txt" budget balanced "cursor: budget line pinned to balanced"
expect "cursor: model.txt has exactly the four keyed lines" \
  bash -c "[ \"\$(wc -l < '$R/model.txt')\" -eq 4 ]"
expect "cursor: model.txt carries a budget= line" grep -q '^budget=' "$R/model.txt"

# --- Family matching, most-specific (longest) match wins ----------------------
# cursor-grok-4.5-high-fast must classify as cursor-grok (included), NOT be
# captured by the bare grok key (metered). If it were captured, the only included
# family left would be composer and executor would resolve to composer-2.5.
R=$SANDBOX/rm-spec; E=$SANDBOX/rm-spec.err
OFFERED=$'cursor-grok-4.5-high-fast\ngrok-4\ncomposer-2.5' \
  BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "most-specific: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor cursor-grok-4.5-high-fast "most-specific: cursor-grok classified included (bare grok did not capture it)"
# The cursor-grok slug alone is INCLUDED (its explanation line says so)...
R=$SANDBOX/rm-cg-only; E=$SANDBOX/rm-cg-only.err
OFFERED=$'cursor-grok-4.5-high-fast' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "most-specific: lone cursor-grok resolves (exit 0)" test "$rc" -eq 0
expect "most-specific: cursor-grok resolves via the INCLUDED branch (strength is free)" \
  grep -qE '^executor=.*included' "$E"
# ...while a bare grok-4 slug alone is METERED (its own family, different cost).
R=$SANDBOX/rm-grok-only; E=$SANDBOX/rm-grok-only.err
OFFERED=$'grok-4' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "most-specific: lone grok-4 resolves (exit 0)" test "$rc" -eq 0
expect "most-specific: bare grok-4 resolves via the METERED branch" \
  grep -qE '^executor=.*(metered|tier-matched)' "$E"
# Matching is case-insensitive; the original case is emitted verbatim.
R=$SANDBOX/rm-ci; E=$SANDBOX/rm-ci.err
OFFERED=$'CURSOR-GROK-4.5-HIGH-FAST\ncomposer-2.5' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "case-insensitive: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor CURSOR-GROK-4.5-HIGH-FAST "case-insensitive: an upper-case slug matches cursor-grok and is emitted verbatim"
# A display name containing spaces survives as one opaque slug, emitted verbatim.
R=$SANDBOX/rm-space; E=$SANDBOX/rm-space.err
OFFERED=$'cursor-grok 4.5 high fast\ncomposer-2.5' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "space slug: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor "cursor-grok 4.5 high fast" "space slug: survives as one opaque slug, emitted verbatim into model.txt"

# --- Variant rule scope: a lone -fast slug keeps full tier rank ---------------
# cursor-grok-4.5-high-fast, the only cursor grok, still ranks coder and beats an
# included cheap-family slug; the suffix never demotes across families.
R=$SANDBOX/rm-lonefast; E=$SANDBOX/rm-lonefast.err
OFFERED=$'cursor-grok-4.5-high-fast\ncomposer-2.5' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "lone -fast: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" coder cursor-grok-4.5-high-fast "lone -fast: keeps full coder rank despite the suffix"
kv_is "$R/model.txt" executor cursor-grok-4.5-high-fast "lone -fast: beats an included cheap-family slug at executor"

# --- Speed-suffix siblings: Cursor Fast is NOT the cheaper/weaker half --------
# Both cursor-grok-4.5-high and cursor-grok-4.5-high-fast offered + included.
# Cursor Fast is the same intelligence at higher serving cost, so every tier
# prefers the base. A lone -fast slug still keeps full rank (test above).
R=$SANDBOX/rm-variant; E=$SANDBOX/rm-variant.err
OFFERED=$'cursor-grok-4.5-high\ncursor-grok-4.5-high-fast' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "speed-variant: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor cursor-grok-4.5-high "speed-variant: executor prefers the base (Fast costs extra)"
kv_is "$R/model.txt" coder cursor-grok-4.5-high "speed-variant: coder prefers the base"
kv_is "$R/model.txt" strong cursor-grok-4.5-high "speed-variant: strong degrades to the base, not Fast"
# The Cursor product pair: composer-2.5 vs composer-2.5-fast (documented same
# intelligence, Fast ~6× token price). Cheap included family — all pins land
# on the unsuffixed slug, not the latency purchase.
R=$SANDBOX/rm-composer-fast; E=$SANDBOX/rm-composer-fast.err
OFFERED=$'composer-2.5\ncomposer-2.5-fast' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "composer-fast: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor composer-2.5 "composer-fast: executor = unsuffixed (not the 6× Fast variant)"
kv_is "$R/model.txt" coder composer-2.5 "composer-fast: coder degrades to the unsuffixed sibling"
kv_is "$R/model.txt" strong composer-2.5 "composer-fast: strong degrades to the unsuffixed sibling"

# --- Weak-suffix siblings still flip by tier (mini / lite / flash) ------------
# Distilled siblings trade capability for cost. Unlike Cursor -fast, executor
# still wants the lighter half; quality tiers still want the base.
R=$SANDBOX/rm-weakvar; E=$SANDBOX/rm-weakvar.err
OFFERED=$'gpt-5\ngpt-5-mini' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "weak-variant: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor gpt-5-mini "weak-variant: executor picks the -mini sibling (volume tier)"
kv_is "$R/model.txt" coder gpt-5 "weak-variant: coder (quality tier) prefers the base slug"
kv_is "$R/model.txt" strong gpt-5 "weak-variant: strong degrades to the base slug, not -mini"

# --- Weak-suffix demotion holds ACROSS suffixes, not only against the exact base -
# M11 regression: stronger() used to fire the weak-sibling rule ONLY when the two
# slugs stripped to the same base, so a cross-suffix same-family pair (a distilled
# -mini vs a non-weak -pro of the same version) fell through to the ALPHABETICAL
# last resort — and `gpt-5-mini` < `gpt-5-pro` handed the quality tiers the WEAKER
# half. The version ties (both gpt-5), so the weak-vs-non-weak tiebreak must decide:
# quality tiers take the non-weak -pro, the volume executor takes the distilled -mini.
R=$SANDBOX/rm-weakcross; E=$SANDBOX/rm-weakcross.err
OFFERED=$'gpt-5-mini\ngpt-5-pro' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "weak cross-suffix: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" coder gpt-5-pro "weak cross-suffix: coder takes the non-weak -pro, not the alphabetically-earlier -mini"
kv_is "$R/model.txt" executor gpt-5-mini "weak cross-suffix: executor takes the distilled -mini (volume tier)"
# Version still dominates the weak-suffix demotion: a newer distilled slug beats an
# older non-weak sibling of the SAME family (the demotion is only a same-version
# tiebreak, applied after vercmp). Both carry the gpt-5 family substring.
R=$SANDBOX/rm-weakcross-ver; E=$SANDBOX/rm-weakcross-ver.err
OFFERED=$'gpt-5-2-mini\ngpt-5-1-pro' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "weak cross-suffix: version-differing pair resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" coder gpt-5-2-mini "weak cross-suffix: a newer -mini (v2) still beats an older -pro (v1) — version outranks the demotion"

# --- Claude Code-shaped list reproduces today's haiku/sonnet/opus split -------
R=$SANDBOX/rm-claude; E=$SANDBOX/rm-claude.err
OFFERED=$'claude-haiku-4-5\nclaude-sonnet-4-5\nclaude-opus-4-1' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "claude: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor claude-haiku-4-5 "claude: executor = haiku (cheap)"
kv_is "$R/model.txt" coder claude-sonnet-4-5 "claude: coder = sonnet"
kv_is "$R/model.txt" strong claude-opus-4-1 "claude: strong = opus"

# --- Build-date suffix must never outrank a real version segment ---------------
# Regression: versegs() once turned the -YYYYMMDD build-date into a version
# segment, so claude-opus-4-1-20250805 (segments [4,1,20250805]) lost to
# claude-opus-4-20250514 ([4,20250514]) at the second segment — silently pinning
# the OLDER opus-4 on the strong tier. The date must be a lowest-priority
# tiebreaker, so the newer minor version (opus-4.1) must win.
R=$SANDBOX/rm-datever; E=$SANDBOX/rm-datever.err
OFFERED=$'claude-opus-4-1-20250805\nclaude-opus-4-20250514' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "dated version: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong claude-opus-4-1-20250805 "dated version: strong = the newer minor (opus-4.1), not the older dated opus-4"
R=$SANDBOX/rm-datever2; E=$SANDBOX/rm-datever2.err
OFFERED=$'claude-sonnet-4-5-20250929\nclaude-sonnet-4-20250514' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "dated version: sonnet resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" coder claude-sonnet-4-5-20250929 "dated version: coder = the newer minor (sonnet-4.5), not the older dated sonnet-4"

# --- The asymmetry: NO included families ⇒ executor is the LOWEST rank ---------
# clearing its bar, never the strongest metered model. A symmetric "strongest in
# the cheapest class" impl would wrongly resolve executor to opus/fable.
R=$SANDBOX/rm-asym; E=$SANDBOX/rm-asym.err
OFFERED=$'claude-haiku-5\nclaude-sonnet-5\nclaude-opus-5\nfable-1' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "asymmetry: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor claude-haiku-5 "asymmetry: executor = lowest rank clearing the bar (haiku)"
refute "asymmetry: executor is NOT the strongest metered (opus)" grep -qx 'executor=claude-opus-5' "$R/model.txt"
refute "asymmetry: executor is NOT a premium model (fable)" grep -qx 'executor=fable-1' "$R/model.txt"
kv_is "$R/model.txt" coder claude-sonnet-5 "asymmetry: coder = lowest rank clearing the coder bar (sonnet)"
kv_is "$R/model.txt" strong claude-opus-5 "asymmetry: strong = opus (premium fable barred by the ceiling)"

# --- frugal same-rank strong pin question (CHOICE) ----------------------------
# Two same-rank strong models (both opus, metered), no override ⇒ exactly one
# CHOICE line naming both.
R=$SANDBOX/rm-choice; E=$SANDBOX/rm-choice.err
OFFERED=$'claude-opus-4-1\nclaude-opus-5' BUDGET=frugal RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "frugal CHOICE: resolves (exit 0)" test "$rc" -eq 0
expect "frugal CHOICE: emits exactly one CHOICE line" bash -c "[ \"\$(grep -c '^CHOICE:' '$E')\" -eq 1 ]"
expect "frugal CHOICE: names the resolved pick" grep -q 'CHOICE:.*claude-opus-5' "$E"
expect "frugal CHOICE: names the same-rank alternative" grep -q 'CHOICE:.*claude-opus-4-1' "$E"
# Same list with STRONG_MODEL set ⇒ no CHOICE (the question is moot).
R=$SANDBOX/rm-choice-ov; E=$SANDBOX/rm-choice-ov.err
OFFERED=$'claude-opus-4-1\nclaude-opus-5' BUDGET=frugal STRONG_MODEL=claude-opus-4-1 \
  RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
refute "frugal CHOICE: an explicit STRONG_MODEL suppresses the CHOICE line" grep -q '^CHOICE:' "$E"
# balanced and thorough never ask.
for b in balanced thorough; do
  R=$SANDBOX/rm-choice-$b; E=$SANDBOX/rm-choice-$b.err
  OFFERED=$'claude-opus-4-1\nclaude-opus-5' BUDGET=$b RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"
  refute "frugal CHOICE: $b never emits a CHOICE line" grep -q '^CHOICE:' "$E"
done
# An all-included strong pick emits none (nothing metered to ask about).
CFG=$SANDBOX/cfg-opus-incl.yaml
printf 'cost_overrides:\n  opus: included\n' > "$CFG"
R=$SANDBOX/rm-choice-inc; E=$SANDBOX/rm-choice-inc.err
OFFERED=$'claude-opus-4-1\nclaude-opus-5' BUDGET=frugal RUN=$R HOME_CONFIG=$CFG bash "$RMS" 2>"$E"
refute "frugal CHOICE: an all-included strong pick emits no CHOICE line" grep -q '^CHOICE:' "$E"

# --- frugal keeps executor/coder off metered; strong resolves by capability ---
R=$SANDBOX/rm-frugal; E=$SANDBOX/rm-frugal.err
OFFERED=$'cursor-grok-4.5-high-fast\ncomposer-2.5\nclaude-sonnet-5\nclaude-opus-5' \
  BUDGET=frugal RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "frugal: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor cursor-grok-4.5-high-fast "frugal: executor stays on the included family (off metered)"
kv_is "$R/model.txt" coder cursor-grok-4.5-high-fast "frugal: coder collapses into the included executor pick (off metered)"
refute "frugal: executor is NOT a metered family (sonnet)" grep -qx 'executor=claude-sonnet-5' "$R/model.txt"
kv_is "$R/model.txt" strong claude-opus-5 "frugal: strong still resolves by capability even when metered (exempt role)"

# --- thorough == balanced byte-identically on the same fixture (monotonicity) -
RB=$SANDBOX/rm-mono-bal; RT=$SANDBOX/rm-mono-tho
ET=$SANDBOX/rm-mono-tho.err
CURSOR=$'cursor-grok-4.5-high-fast\ncomposer-2.5\nclaude-sonnet-5\nclaude-opus-5'
OFFERED="$CURSOR" BUDGET=balanced  RUN=$RB HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
OFFERED="$CURSOR" BUDGET=thorough  RUN=$RT HOME_CONFIG=/dev/null bash "$RMS" 2>"$ET"
grep -E '^(strong|coder|executor)=' "$RB/model.txt" > "$SANDBOX/mono-bal.lines"
grep -E '^(strong|coder|executor)=' "$RT/model.txt" > "$SANDBOX/mono-tho.lines"
expect "monotonicity: thorough resolves the three tiers byte-identically to balanced" \
  diff -q "$SANDBOX/mono-bal.lines" "$SANDBOX/mono-tho.lines"
kv_is "$RT/model.txt" executor cursor-grok-4.5-high-fast "monotonicity: thorough executor stays the included pick (never weaker)"
expect "thorough: moves every Phase 7 verifier to the strong tier" \
  grep -q 'every Phase 7 verifier runs on' "$ET"
kv_is "$RT/model.txt" budget thorough "thorough: budget line pinned to thorough"

# --- balanced is the default when BUDGET is unset or empty --------------------
R=$SANDBOX/rm-def-unset
OFFERED=$'claude-haiku-5\nclaude-sonnet-5\nclaude-opus-5' RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
kv_is "$R/model.txt" budget balanced "default: BUDGET unset ⇒ balanced"
R=$SANDBOX/rm-def-empty
OFFERED=$'claude-haiku-5\nclaude-sonnet-5\nclaude-opus-5' BUDGET= RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
kv_is "$R/model.txt" budget balanced "default: BUDGET empty ⇒ balanced"

# --- The premium ceiling: strong= never a premium family, in BOTH branches ----
# Metered branch: fable (premium) offered alongside opus (strong) — strong = opus.
R=$SANDBOX/rm-ceil-met; E=$SANDBOX/rm-ceil-met.err
OFFERED=$'fable-1\nclaude-opus-5' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "ceiling (metered): resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong claude-opus-5 "ceiling (metered): strong = opus, not the premium fable"
refute "ceiling (metered): strong is NOT premium (fable)" grep -qx 'strong=fable-1' "$R/model.txt"
# Included branch: make fable included via a cost override — the ceiling still holds.
CFG=$SANDBOX/cfg-fable-incl.yaml
printf 'cost_overrides:\n  fable: included\n' > "$CFG"
R=$SANDBOX/rm-ceil-inc; E=$SANDBOX/rm-ceil-inc.err
OFFERED=$'fable-1\nclaude-opus-5' BUDGET=balanced RUN=$R HOME_CONFIG=$CFG bash "$RMS" 2>"$E"; rc=$?
expect "ceiling (included): resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong claude-opus-5 "ceiling (included): strong = opus even when the premium family is included"
refute "ceiling (included): strong is NOT premium (fable)" grep -qx 'strong=fable-1' "$R/model.txt"

# --- Ordering: variant, version, date, cross-family alphabetical, tier rank ----
# Higher version wins within a family.
R=$SANDBOX/rm-ord-ver
OFFERED=$'haiku-5\nhaiku-4-5-20251001' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
kv_is "$R/model.txt" executor haiku-5 "ordering: haiku-5 beats haiku-4-5-20251001 (4 < 5 at the first segment)"
# Later date stamp wins between two otherwise-equal dated builds.
R=$SANDBOX/rm-ord-date
OFFERED=$'haiku-4-5-20251001\nhaiku-4-5-20260201' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
kv_is "$R/model.txt" executor haiku-4-5-20260201 "ordering: later date stamp wins between equal-version dated builds"
# 4.5 beats 4 (second segment); within the grok family.
R=$SANDBOX/rm-ord-dot
OFFERED=$'grok-4.5\ngrok-4' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
kv_is "$R/model.txt" coder grok-4.5 "ordering: grok-4.5 beats grok-4 (present segment beats missing)"
# Interleaved words (-high-) don't participate; higher version still wins.
R=$SANDBOX/rm-ord-high
OFFERED=$'cursor-grok-4.5-high\ncursor-grok-4.6' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
kv_is "$R/model.txt" coder cursor-grok-4.6 "ordering: -high- is skipped; cursor-grok-4.6 beats cursor-grok-4.5-high"
# Version rule never fires across families: a cross-family tie falls to alphabetical.
# gpt-5 vs grok-9 — if version fired, grok-9 (9>5) would win; alphabetical picks gpt-5.
R=$SANDBOX/rm-ord-xfam
OFFERED=$'gpt-5\ngrok-9' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
kv_is "$R/model.txt" coder gpt-5 "ordering: cross-family tie falls to alphabetical (version rule does not fire)"
# Tier rank orders across families.
R=$SANDBOX/rm-ord-rank
OFFERED=$'claude-haiku-5\nclaude-sonnet-5' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
kv_is "$R/model.txt" executor claude-haiku-5 "ordering: tier rank — executor = the cheap family"
kv_is "$R/model.txt" coder claude-sonnet-5 "ordering: tier rank — coder = the coder family"

# --- Precedence: an explicit override beats catalog derivation ----------------
# Without the override, strong would derive to opus; the override forces haiku,
# and the explanation line names it as an explicit override.
R=$SANDBOX/rm-prec; E=$SANDBOX/rm-prec.err
OFFERED=$'claude-opus-5\nclaude-haiku-5' BUDGET=balanced STRONG_MODEL=claude-haiku-5 \
  RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "precedence: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong claude-haiku-5 "precedence: the explicit override beats catalog derivation"
expect "precedence: the explanation line names the explicit override" \
  grep -qE '^strong=claude-haiku-5.*explicit override' "$E"

# --- Unknown cost: absent from plan ⇒ metered + UNCLASSIFIED, exit 0 ----------
# A fixture catalog with a family present in families: but absent from plan:.
CAT=$SANDBOX/catalog-mystery.yaml
cat > "$CAT" <<'YAML'
families:
  haiku:       cheap
  composer:    cheap
  grok:        coder
  cursor-grok: coder
  sonnet:      coder
  gpt-5:       coder
  opus:        strong
  fable:       premium
  mystery:     coder
weak_suffixes: [mini, lite, flash]
speed_suffixes: [fast]
plan:
  updated: 2026-08-03
  included: [composer, cursor-grok]
  metered:  [haiku, sonnet, opus, gpt-5, fable, grok]
YAML
R=$SANDBOX/rm-unc; E=$SANDBOX/rm-unc.err
OFFERED=$'mystery-2\nclaude-opus-5' BUDGET=balanced CATALOG=$CAT RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "unknown cost: still exits 0 (no ask-the-user block)" test "$rc" -eq 0
expect "unknown cost: emits UNCLASSIFIED naming the family" grep -qE 'UNCLASSIFIED:.*mystery' "$E"
# A cost override resolves it cleanly with no UNCLASSIFIED line.
CFG=$SANDBOX/cfg-mystery-cost.yaml
printf 'cost_overrides:\n  mystery: metered\n' > "$CFG"
R=$SANDBOX/rm-unc2; E=$SANDBOX/rm-unc2.err
OFFERED=$'mystery-2\nclaude-opus-5' BUDGET=balanced CATALOG=$CAT RUN=$R HOME_CONFIG=$CFG bash "$RMS" 2>"$E"; rc=$?
expect "unknown cost: a cost_overrides entry resolves cleanly (exit 0)" test "$rc" -eq 0
refute "unknown cost: no UNCLASSIFIED line once the cost is answered" grep -q 'UNCLASSIFIED:' "$E"

# --- Unranked: matches no family ⇒ excluded + UNRANKED, remaining resolve -----
R=$SANDBOX/rm-unr; E=$SANDBOX/rm-unr.err
OFFERED=$'brand-new-xyz\nclaude-opus-5\nclaude-haiku-5\nclaude-sonnet-5' \
  BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "unranked: resolution over the remaining ranked slugs exits 0" test "$rc" -eq 0
expect "unranked: emits UNRANKED naming the slug" grep -qE 'UNRANKED:.*brand-new-xyz' "$E"
refute "unranked: the unranked slug never lands in model.txt" grep -q 'brand-new-xyz' "$R/model.txt"
# A confirmed capability_overrides entry ranks a new family cleanly (no UNRANKED).
CFG=$SANDBOX/cfg-cap.yaml
printf 'capability_overrides:\n  newfam: coder\n' > "$CFG"
R=$SANDBOX/rm-cap; E=$SANDBOX/rm-cap.err
OFFERED=$'newfam-1\nclaude-opus-5' BUDGET=balanced RUN=$R HOME_CONFIG=$CFG bash "$RMS" 2>"$E"; rc=$?
expect "capability override: ranks the new family (exit 0)" test "$rc" -eq 0
refute "capability override: no UNRANKED line once the family is confirmed" grep -q 'UNRANKED:' "$E"
# An UPPER-CASE override key still ranks the family. Classification matches a key
# as a substring of the LOWERCASED slug, so the key is normalized to lowercase at
# read time — otherwise `NewFam: coder` would rank a key no slug can ever match and
# sit silently inert (the offered slug would report UNRANKED regardless).
CFG=$SANDBOX/cfg-cap-upper.yaml
printf 'capability_overrides:\n  NewFam: coder\n' > "$CFG"
R=$SANDBOX/rm-cap-upper; E=$SANDBOX/rm-cap-upper.err
OFFERED=$'newfam-1\nclaude-opus-5' BUDGET=balanced RUN=$R HOME_CONFIG=$CFG bash "$RMS" 2>"$E"; rc=$?
expect "capability override: an upper-case key resolves (exit 0)" test "$rc" -eq 0
refute "capability override: an upper-case override key is not silently inert (no UNRANKED)" \
  grep -q 'UNRANKED:.*newfam' "$E"
kv_is "$R/model.txt" coder newfam-1 "capability override: the upper-case-keyed family ranks and fills the coder tier"
# A capability override of premium still never wins strong= (the ceiling holds).
CFG=$SANDBOX/cfg-cap-prem.yaml
printf 'capability_overrides:\n  bigfam: premium\n' > "$CFG"
R=$SANDBOX/rm-cap-prem; E=$SANDBOX/rm-cap-prem.err
OFFERED=$'bigfam-1\nclaude-opus-5' BUDGET=balanced RUN=$R HOME_CONFIG=$CFG bash "$RMS" 2>"$E"; rc=$?
expect "capability override: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong claude-opus-5 "capability override: a premium-ranked family still never wins strong="
refute "capability override: strong is NOT the premium-overridden family" grep -qx 'strong=bigfam-1' "$R/model.txt"
# An override value outside cheap|coder|strong|premium is rejected loudly (exit 2).
CFG=$SANDBOX/cfg-cap-bad.yaml
printf 'capability_overrides:\n  foo: superhero\n' > "$CFG"
R=$SANDBOX/rm-cap-bad; E=$SANDBOX/rm-cap-bad.err
OFFERED=$'claude-opus-5' BUDGET=balanced RUN=$R HOME_CONFIG=$CFG bash "$RMS" 2>"$E"; rc=$?
expect "capability override: an out-of-range tier value exits 2" test "$rc" -eq 2

# --- Degrade vs block ---------------------------------------------------------
# Nothing clears the coder/strong bar ⇒ degrade to the strongest ranked offered
# with a WARNING; the run still exits 0.
R=$SANDBOX/rm-degrade; E=$SANDBOX/rm-degrade.err
OFFERED=$'claude-haiku-5' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "degrade: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" coder claude-haiku-5 "degrade: coder degrades to the strongest ranked offered"
expect "degrade: WARNING names the shortfall tier (coder)" grep -qE 'WARNING:.*coder' "$E"
# Nothing matches any family ⇒ exit 4 with the nothing-ranked message.
R=$SANDBOX/rm-block; E=$SANDBOX/rm-block.err
OFFERED=$'brand-new-xyz\nother-unknown' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "block: nothing ranked exits 4" test "$rc" -eq 4
expect "block: emits the distinct nothing-ranked message" grep -q 'nothing ranked' "$E"

# --- Bad input: OFFERED empty and bad BUDGET and missing catalog exit 1 -------
R=$SANDBOX/rm-empty; E=$SANDBOX/rm-empty.err
OFFERED= RUN=$R HOME_CONFIG=/dev/null bash "$RMS" </dev/null 2>"$E"; rc=$?
expect "bad input: OFFERED empty exits 1" test "$rc" -eq 1
expect "bad input: OFFERED-empty message" grep -q 'OFFERED is empty' "$E"
R=$SANDBOX/rm-budget; E=$SANDBOX/rm-budget.err
OFFERED=$'claude-opus-5' BUDGET=silly RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "bad input: bad BUDGET exits 1" test "$rc" -eq 1
expect "bad input: bad-BUDGET message" grep -q 'BUDGET must be' "$E"
R=$SANDBOX/rm-nocat; E=$SANDBOX/rm-nocat.err
OFFERED=$'claude-opus-5' CATALOG=$SANDBOX/does-not-exist.yaml RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "bad input: a missing catalog exits 1" test "$rc" -eq 1
expect "bad input: missing-catalog message" grep -q 'catalog not found' "$E"

# --- KAIROS_UPDATE_*_MODEL: flag > env > derivation ---------------------------
# The fixture list derives executor=haiku, coder=sonnet, strong=opus, so every
# env/flag value below is deliberately NOT the derived one for its tier — each
# assertion can only pass if the intended surface actually won.
TIERLIST=$'claude-haiku-5\nclaude-sonnet-5\nclaude-opus-5'
# Env alone fills all three tiers (no flag set).
R=$SANDBOX/rm-env; E=$SANDBOX/rm-env.err
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  KAIROS_UPDATE_STRONG_MODEL=claude-sonnet-5 \
  KAIROS_UPDATE_CODER_MODEL=claude-haiku-5 \
  KAIROS_UPDATE_EXECUTOR_MODEL=claude-opus-5 \
  bash "$RMS" 2>"$E"; rc=$?
expect "model env: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong   claude-sonnet-5 "model env: KAIROS_UPDATE_STRONG_MODEL fills strong= when no flag is set"
kv_is "$R/model.txt" coder    claude-haiku-5  "model env: KAIROS_UPDATE_CODER_MODEL fills coder= when no flag is set"
kv_is "$R/model.txt" executor claude-opus-5   "model env: KAIROS_UPDATE_EXECUTOR_MODEL fills executor= when no flag is set"
expect "model env: an env-filled tier is reported as an explicit override" \
  grep -qE '^strong=claude-sonnet-5.*explicit override' "$E"
# A per-run flag beats the standing env on every tier.
R=$SANDBOX/rm-envflag; E=$SANDBOX/rm-envflag.err
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  STRONG_MODEL=claude-haiku-5   KAIROS_UPDATE_STRONG_MODEL=claude-opus-5 \
  CODER_MODEL=claude-opus-5     KAIROS_UPDATE_CODER_MODEL=claude-haiku-5 \
  EXECUTOR_MODEL=claude-sonnet-5 KAIROS_UPDATE_EXECUTOR_MODEL=claude-opus-5 \
  bash "$RMS" 2>"$E"; rc=$?
expect "model env: resolves with both surfaces set (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong   claude-haiku-5  "model env: --strong-model beats KAIROS_UPDATE_STRONG_MODEL"
kv_is "$R/model.txt" coder    claude-opus-5   "model env: --coder-model beats KAIROS_UPDATE_CODER_MODEL"
kv_is "$R/model.txt" executor claude-sonnet-5 "model env: --executor-model beats KAIROS_UPDATE_EXECUTOR_MODEL"
refute "model env: the losing env value never lands in model.txt" \
  grep -qx 'strong=claude-opus-5' "$R/model.txt"
# An empty flag var is "no flag" — the env fills the tier rather than blanking it.
R=$SANDBOX/rm-envempty; E=$SANDBOX/rm-envempty.err
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  STRONG_MODEL= KAIROS_UPDATE_STRONG_MODEL=claude-haiku-5 \
  bash "$RMS" 2>"$E"; rc=$?
expect "model env: an empty flag var resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong claude-haiku-5 "model env: an empty --strong-model falls through to the env var"
# Neither surface set ⇒ plain derivation, on all three tiers.
R=$SANDBOX/rm-envnone; E=$SANDBOX/rm-envnone.err
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "model env: neither flag nor env resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong   claude-opus-5   "model env: no flag and no env ⇒ strong= derives"
kv_is "$R/model.txt" coder    claude-sonnet-5 "model env: no flag and no env ⇒ coder= derives"
kv_is "$R/model.txt" executor claude-haiku-5  "model env: no flag and no env ⇒ executor= derives"
refute "model env: a derived tier is not reported as an explicit override" \
  grep -q 'explicit override' "$E"

# --- OFFERED unset: interactive stdin refuses, redirected stdin still works ----
# The pty runner hands the child a real terminal on fd 0 (`[ -t 0 ]` true) and
# bounds it with an alarm, so a regression that re-introduces the blocking read
# fails the assertion instead of hanging the suite.
#
# Implemented with python3's stdlib `os.openpty` (not raw ioctls): the pty
# master/slave ioctl numbers differ between Darwin (TIOCPTYGRANT/…) and Linux
# (TIOCGPTN/…), so a hardcoded-hex allocator only works on the box it was written
# on. `os.openpty` allocates the pair portably on macOS and Ubuntu/WSL alike;
# python3 is already a suite dependency.
#
# Only fd 0 is pointed at the slave — stdout/stderr stay inherited, so the
# caller's `>/dev/null 2>"$E"` still captures the child's streams (pty.spawn
# would have swallowed all three into the pty). The parent holds the master open
# so a read on the slave blocks like a real terminal, and `signal.alarm` turns a
# regression that reintroduces the blocking read into a failed assertion rather
# than a hung suite.
tty_run() { # tty_run <cmd...> — run with stdin on a pty, killed after 10s
  python3 -c '
import os, signal, sys
signal.alarm(10)                       # SIGALRM (default: terminate) bounds a hang
master, slave = os.openpty()
pid = os.fork()
if pid == 0:                           # child: only stdin becomes the tty
    os.close(master)
    os.dup2(slave, 0)
    if slave > 2:
        os.close(slave)
    os.execvp(sys.argv[1], sys.argv[1:])
    os._exit(127)
os.close(slave)                        # parent keeps master open → slave reads block
_, st = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128)
' "$@"
}
R=$SANDBOX/rm-tty; E=$SANDBOX/rm-tty.err
RUN=$R HOME_CONFIG=/dev/null BUDGET=balanced tty_run bash "$RMS" >/dev/null 2>"$E"; rc=$?
expect "tty stdin: OFFERED unset on a terminal exits 1 (refuses, never blocks)" test "$rc" -eq 1
expect "tty stdin: names the refusal" grep -q 'OFFERED unset and stdin is a terminal' "$E"
refute "tty stdin: writes no model.txt" test -f "$R/model.txt"
# The documented stdin path — a redirected list with OFFERED unset — is unchanged.
printf '%s\n' 'claude-haiku-5' 'claude-sonnet-5' 'claude-opus-5' > "$SANDBOX/rm-offered.txt"
R=$SANDBOX/rm-stdin; E=$SANDBOX/rm-stdin.err
RUN=$R HOME_CONFIG=/dev/null BUDGET=balanced bash "$RMS" < "$SANDBOX/rm-offered.txt" 2>"$E"; rc=$?
expect "stdin path: a redirected OFFERED list still resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor claude-haiku-5 "stdin path: the redirected list drives resolution as before"

fi

if t "resolve-models.sh — overrides beat an unrankable harness; no tier ever pins empty"; then
# Two independently-confirmed criticals, both of which exited "successfully enough"
# to poison everything downstream:
#   * a harness whose slugs match NO catalog family exited 4 BEFORE the explicit
#     overrides were read, so the remedy that exit prescribes (re-run with
#     --*-model) could never take effect — the run was deadlocked on its own
#     recovery instruction.
#   * a premium-only OFFERED list resolved strong= to the EMPTY string at exit 0:
#     the premium ceiling was re-applied when building the degrade pool, leaving
#     nothing to pick. log-spawn.sh treats a missing/empty tier pin as the legacy
#     shape it must record UNCHECKED, so the pin contract was silently unenforced
#     for every judgment dispatch of the run.
# Both are asserted at the documented interface only: env in, exit code + the
# bytes of $RUN/model.txt out.
RMS="$SKILL_DIR/scripts/resolve-models.sh"
export PHASE_KEY=$(phase_key 1.5-model-resolution.md)
unset KAIROS_UPDATE_STRONG_MODEL KAIROS_UPDATE_CODER_MODEL KAIROS_UPDATE_EXECUTOR_MODEL
no_empty_pin() { # no_empty_pin <model.txt> <desc>
  if grep -qE '^(strong|coder|executor)=$' "$1"; then fail "$2"; else pass "$2"; fi
}

# --- Nothing ranked + explicit overrides ⇒ the overrides ARE the resolution ----
UNK=$'totally-unknown-1\nother-unknown-2'
R=$SANDBOX/rm-ovr-unranked; E=$SANDBOX/rm-ovr-unranked.err
OFFERED="$UNK" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  STRONG_MODEL=totally-unknown-1 CODER_MODEL=other-unknown-2 EXECUTOR_MODEL=other-unknown-2 \
  bash "$RMS" 2>"$E"; rc=$?
expect "unrankable+overrides: resolves (exit 0) instead of deadlocking on nothing-ranked" test "$rc" -eq 0
expect "unrankable+overrides: writes model.txt" test -f "$R/model.txt"
kv_is "$R/model.txt" strong   totally-unknown-1 "unrankable+overrides: strong= honors the override"
kv_is "$R/model.txt" coder    other-unknown-2   "unrankable+overrides: coder= honors the override"
kv_is "$R/model.txt" executor other-unknown-2   "unrankable+overrides: executor= honors the override"
kv_is "$R/model.txt" budget   balanced          "unrankable+overrides: budget line still pinned"
no_empty_pin "$R/model.txt" "unrankable+overrides: no tier pins an empty slug"
expect "unrankable+overrides: stderr still records that nothing ranked" grep -q 'nothing ranked' "$E"
# frugal needs only two overrides: coder collapses into executor.
R=$SANDBOX/rm-ovr-frugal; E=$SANDBOX/rm-ovr-frugal.err
OFFERED="$UNK" BUDGET=frugal RUN=$R HOME_CONFIG=/dev/null \
  STRONG_MODEL=totally-unknown-1 EXECUTOR_MODEL=other-unknown-2 bash "$RMS" 2>"$E"; rc=$?
expect "unrankable+overrides: frugal resolves from two overrides (coder collapses)" test "$rc" -eq 0
kv_is "$R/model.txt" coder other-unknown-2 "unrankable+overrides: frugal coder= collapses into the executor override"

# --- Nothing ranked + PARTIAL overrides ⇒ hard stop, no artifacts -------------
# The tiers that still cannot resolve are named, because "nothing ranked" alone
# does not tell the caller which --*-model values would fix the run.
R=$SANDBOX/rm-ovr-partial; E=$SANDBOX/rm-ovr-partial.err
OFFERED="$UNK" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  STRONG_MODEL=totally-unknown-1 bash "$RMS" 2>"$E"; rc=$?
expect "unrankable+partial overrides: exits non-zero" test "$rc" -ne 0
refute "unrankable+partial overrides: writes no model.txt" test -e "$R/model.txt"
refute "unrankable+partial overrides: leaves no model.txt.tmp behind" test -e "$R/model.txt.tmp"
expect "unrankable+partial overrides: the error names the unresolved coder tier" \
  grep -qE 'ERROR:.*coder' "$E"
expect "unrankable+partial overrides: the error names the unresolved executor tier" \
  grep -qE 'ERROR:.*executor' "$E"

# --- Premium-only OFFERED ⇒ strong degrades UP, never to the empty string -----
R=$SANDBOX/rm-premium; E=$SANDBOX/rm-premium.err
OFFERED=$'fable-1' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "premium-only: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong fable-1 "premium-only: strong= pins the strongest offered model, not the empty string"
no_empty_pin "$R/model.txt" "premium-only: no tier pins an empty slug"
expect "premium-only: a WARNING says the premium ceiling could not be honored" \
  grep -qE 'WARNING:.*(premium|ceiling)' "$E"
# Several premium slugs: the STRONGEST offered wins the degrade.
R=$SANDBOX/rm-premium2; E=$SANDBOX/rm-premium2.err
OFFERED=$'fable-1\nfable-2' BUDGET=frugal RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "premium-only: frugal resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong fable-2 "premium-only: the degrade takes the strongest offered premium slug"
no_empty_pin "$R/model.txt" "premium-only: frugal pins no empty slug either"
# The ceiling still binds the degrade whenever ANY within-ceiling model is offered:
# a below-bar haiku is preferred over promoting strong= into a premium tier.
R=$SANDBOX/rm-ceil-degrade; E=$SANDBOX/rm-ceil-degrade.err
OFFERED=$'claude-haiku-5\nfable-1' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "ceiling degrade: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong claude-haiku-5 "ceiling degrade: strong= stays within the ceiling when a non-premium model is offered"

# --- A failed resolution leaves no pins on disk — not even stale ones ----------
# Mid-run correction re-runs the resolver into the SAME $RUN. If a failed re-run
# left the previous model.txt in place, log-spawn.sh would keep enforcing pins the
# run has already rejected, and Phase 8 would report them as this run's.
R=$SANDBOX/rm-stale; E=$SANDBOX/rm-stale.err
OFFERED=$'claude-haiku-5\nclaude-sonnet-5\nclaude-opus-5' BUDGET=balanced RUN=$R \
  HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
expect "stale pins: the first resolution wrote model.txt" test -f "$R/model.txt"
OFFERED="$UNK" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
expect "stale pins: the failed re-resolution exits non-zero" test "$rc" -ne 0
refute "stale pins: the failed re-resolution removes the previous model.txt" test -e "$R/model.txt"

# --- Happy path: byte-identical pins to the pre-fix resolver -------------------
# Goldens, not recomputation: the two shapes the skill actually meets (a Cursor
# list and a Claude Code list) must resolve to exactly these bytes after the fix.
R=$SANDBOX/rm-golden-cursor
OFFERED=$'cursor-grok-4.5-high-fast\ncomposer-2.5\nclaude-sonnet-5\nclaude-opus-5' \
  BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
printf 'strong=%s\ncoder=%s\nexecutor=%s\nbudget=%s\n' \
  claude-opus-5 cursor-grok-4.5-high-fast cursor-grok-4.5-high-fast balanced \
  > "$SANDBOX/rm-golden-cursor.want"
expect "golden: the Cursor-shaped list resolves byte-identically to the pre-fix pins" \
  diff -q "$SANDBOX/rm-golden-cursor.want" "$R/model.txt"
R=$SANDBOX/rm-golden-claude
OFFERED=$'claude-haiku-4-5\nclaude-sonnet-4-5\nclaude-opus-4-1' \
  BUDGET=thorough RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
printf 'strong=%s\ncoder=%s\nexecutor=%s\nbudget=%s\n' \
  claude-opus-4-1 claude-sonnet-4-5 claude-haiku-4-5 thorough \
  > "$SANDBOX/rm-golden-claude.want"
expect "golden: the Claude-shaped list resolves byte-identically to the pre-fix pins" \
  diff -q "$SANDBOX/rm-golden-claude.want" "$R/model.txt"
fi

if t "resolve-models.sh — override values are shape-checked; the pin file is shape-checked before it lands"; then
# Overrides were the one input that reached the awk core unvalidated, and awk -v
# EXPANDS backslash escapes — so an override was a WRITER into model.txt, not just
# a pin. Three confirmed shapes, all of which exited 0 or exited on the wrong code:
#   * STRONG_MODEL=' '  → exit 0 with `strong= `; log-spawn.sh reads " " as a real
#     pin and refuses every strong dispatch, so the run bricked at the first
#     dispatch instead of at resolution.
#   * STRONG_MODEL='a\nexecutor=EVIL' (literal backslash-n) → exit 0 and a FIVE-line
#     model.txt carrying a forged `executor=EVIL` line ABOVE the real one;
#     log-spawn.sh takes the first match per tier, so the forgery won.
#   * STRONG_MODEL=$'a\nb' (real newline) → awk itself died (`newline in string`,
#     exit 2), colliding with exit 2's documented meaning (a malformed
#     ~/.kairos/models.yaml value) and sending the operator to edit the wrong file.
# Asserted at the documented interface: env in, exit code + the bytes of
# $RUN/model.txt out. Invalid override = exit 1 (the invocation is wrong).
RMS="$SKILL_DIR/scripts/resolve-models.sh"
export PHASE_KEY=$(phase_key 1.5-model-resolution.md)
unset KAIROS_UPDATE_STRONG_MODEL KAIROS_UPDATE_CODER_MODEL KAIROS_UPDATE_EXECUTOR_MODEL
TIERLIST=$'claude-haiku-5\nclaude-sonnet-5\nclaude-opus-5'
bad_override() { # bad_override <tag> <desc-prefix> <VAR=value>...
  local tag=$1 desc=$2; shift 2
  local R=$SANDBOX/rm-ov-$tag E=$SANDBOX/rm-ov-$tag.err rc
  rm -rf "$R"
  env OFFERED="$TIERLIST" BUDGET=balanced RUN="$R" HOME_CONFIG=/dev/null "$@" \
    bash "$RMS" >/dev/null 2>"$E"; rc=$?
  expect "$desc: exits 1 (bad invocation, not a models.yaml error)" test "$rc" -eq 1
  refute "$desc: writes no model.txt" test -e "$R/model.txt"
  refute "$desc: leaves no model.txt.tmp" test -e "$R/model.txt.tmp"
  expect "$desc: names the offending override on stderr" grep -q 'ERROR:.*MODEL' "$E"
}
bad_override blank    "override ' '"            STRONG_MODEL=' '
bad_override tab      "override tab-only"       CODER_MODEL="$(printf '\t')"
bad_override forge    "override 'a\\nexecutor=EVIL'" STRONG_MODEL='a\nexecutor=EVIL'
bad_override nl       "override with a real newline" STRONG_MODEL=$'a\nb'
bad_override eq       "override containing '='"  EXECUTOR_MODEL='a=b'
bad_override space    "override with inner spaces" STRONG_MODEL='claude opus 5'
bad_override ctrl     "override with a control char" CODER_MODEL="$(printf 'a\002b')"
bad_override env      "standing-config override ' '" KAIROS_UPDATE_CODER_MODEL=' '
# The forged line must never reach the file under ANY of the above.
refute "override forgery: no forged executor= line was written anywhere" \
  grep -rq 'executor=EVIL' "$SANDBOX/rm-ov-forge" 2>/dev/null
# awk's own diagnostic must not be what the operator sees for the newline case.
refute "override newline: the operator never sees awk's own 'newline in string'" \
  grep -qi 'newline in string' "$SANDBOX/rm-ov-nl.err"
# Legitimate slug shapes are NOT collateral damage: dots, colons, slashes,
# underscores and dashes all pass, and surrounding whitespace/CR is trimmed.
R=$SANDBOX/rm-ov-ok; E=$SANDBOX/rm-ov-ok.err
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  STRONG_MODEL='us.anthropic.claude-opus-5-v1:0' CODER_MODEL='vendor/family_2.5-fast' \
  bash "$RMS" 2>"$E"; rc=$?
expect "override shapes: a bedrock-style and a slash/underscore slug resolve (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong 'us.anthropic.claude-opus-5-v1:0' "override shapes: dots and a colon survive verbatim"
kv_is "$R/model.txt" coder  'vendor/family_2.5-fast'          "override shapes: slash and underscore survive verbatim"
R=$SANDBOX/rm-ov-trim; E=$SANDBOX/rm-ov-trim.err
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  STRONG_MODEL="$(printf ' claude-opus-5 ')" EXECUTOR_MODEL="$(printf 'claude-haiku-5\r')" \
  bash "$RMS" 2>"$E"; rc=$?
expect "override trim: surrounding space and a trailing CR resolve (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong   claude-opus-5  "override trim: surrounding whitespace is trimmed off the pin"
kv_is "$R/model.txt" executor claude-haiku-5 "override trim: a CRLF-pasted override loses its CR"

# --- FINDING 13(a): a bad-charset override refusal must NOT wipe an existing,
# valid model.txt. ov_check fires before BUDGET/the catalog/OFFERED are even
# read, so a rejected override means no resolution attempt has started — the
# prior pins (most commonly this run's OWN surviving pins, echoed straight
# back by the mid-run correction procedure in phases/1.5-model-resolution.md)
# are still this run's truth and must survive the refusal byte-identically.
R=$SANDBOX/rm-ov-preserve; E=$SANDBOX/rm-ov-preserve.err; rm -rf "$R"
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
expect "override preserves model.txt: the prior resolution wrote model.txt" test -f "$R/model.txt"
cp "$R/model.txt" "$SANDBOX/rm-ov-preserve.before"
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  STRONG_MODEL='claude opus 5' bash "$RMS" >/dev/null 2>"$E"; rc=$?
expect "override preserves model.txt: a bad-charset (spaced display-name) override still exits 1" test "$rc" -eq 1
expect "override preserves model.txt: the error still names the offending override" grep -q 'ERROR:.*STRONG_MODEL' "$E"
expect "override preserves model.txt: model.txt still exists" test -f "$R/model.txt"
expect "override preserves model.txt: model.txt is byte-identical to before the refused override" \
  diff -q "$SANDBOX/rm-ov-preserve.before" "$R/model.txt"
refute "override preserves model.txt: no model.txt.tmp is left behind by the refusal" test -e "$R/model.txt.tmp"

# --- Output shape: only four keyed non-empty lines may become model.txt ---------
# Unreachable through the documented interface once overrides are validated, so it
# is asserted against a MUTANT copy of the script whose awk core emits an extra
# forged line. The check is the belt to validation's braces: model.txt is a machine
# contract (log-spawn.sh takes the first match per tier), so a fifth line is an
# invariant violation (exit 5), never something to install and warn about.
MUT=$SANDBOX/rm-mutant.sh
sed 's|^  print "budget=" budget$|  print "budget=" budget; print "executor=EVIL"|' \
  "$RMS" > "$MUT"
expect "pin shape: the mutant really does emit a fifth line" grep -q 'executor=EVIL' "$MUT"
R=$SANDBOX/rm-shape; E=$SANDBOX/rm-shape.err; rm -rf "$R"
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  CATALOG="$SKILL_DIR/reference/model-families.yaml" bash "$MUT" >/dev/null 2>"$E"; rc=$?
expect "pin shape: a five-line pin file exits 5 (invariant violation)" test "$rc" -eq 5
refute "pin shape: the malformed pin file is never installed" test -e "$R/model.txt"
refute "pin shape: no model.txt.tmp survives the refusal" test -e "$R/model.txt.tmp"
expect "pin shape: stderr says the pin file was malformed" grep -qE 'ERROR:.*(four|malformed)' "$E"

# --- An unremovable stale model.txt is named, and does not change the exit code -
# reference/model-resolution.md promises every non-zero exit leaves no pins. With a
# read-only $RUN that promise cannot be kept, and silence was the bug: the stale
# pins stayed in force for log-spawn.sh with nothing on stderr to say so.
R=$SANDBOX/rm-ro; E=$SANDBOX/rm-ro.err; rm -rf "$R"; mkdir -p "$R"
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
expect "read-only \$RUN: the first resolution wrote model.txt" test -f "$R/model.txt"
: > "$R/model.txt.tmp"          # a leftover temp the failed re-run will truncate
chmod a-w "$R" 2>/dev/null || :
if [[ "$(id -u)" != 0 ]] && ! (touch "$R/probe" 2>/dev/null); then
  OFFERED=$'totally-unknown-1\nother-unknown-2' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
    bash "$RMS" 2>"$E"; rc=$?
  expect "read-only \$RUN: keeps the real exit code (4), not rm's" test "$rc" -eq 4
  expect "read-only \$RUN: a WARNING names the surviving model.txt" \
    grep -qE 'WARNING:.*model\.txt' "$E"
  expect "read-only \$RUN: the WARNING calls the surviving pins stale" \
    grep -qiE 'WARNING:.*stale' "$E"
  expect "read-only \$RUN: the WARNING names the surviving temp file too" \
    grep -qE 'WARNING:.*model\.txt\.tmp' "$E"
  expect "read-only \$RUN: the nothing-ranked error is still reported" \
    grep -q 'nothing ranked' "$E"
else
  echo "  skip: read-only \$RUN not enforceable for this user (root?)"
fi
chmod u+w "$R" 2>/dev/null || :

# --- read-only $RUN: the TRUE resolution outcome is reported, not the write error
# The temp file used to be created INSIDE $RUN, so an unwritable $RUN failed that
# redirection before awk ever ran: every shape of input exited 1 ("your invocation
# is wrong") for what is a filesystem problem, and the real outcome was never even
# computed. The resolution now runs into a temp outside $RUN, so the exit code is
# the one the resolution actually produced — and nothing is installed.
RO=$SANDBOX/rm-ro-true; rm -rf "$RO"; mkdir -p "$RO"
OFFERED="$TIERLIST" BUDGET=balanced RUN=$RO HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
cp "$RO/model.txt" "$SANDBOX/rm-ro-true.stale"
chmod a-w "$RO" 2>/dev/null || :
if [[ "$(id -u)" != 0 ]] && ! (touch "$RO/probe" 2>/dev/null); then
  E=$SANDBOX/rm-ro-true4.err
  OFFERED=$'totally-unknown-1\nother-unknown-2' BUDGET=balanced RUN=$RO HOME_CONFIG=/dev/null \
    bash "$RMS" 2>"$E"; rc=$?
  expect "read-only \$RUN: an exit-4-shaped input still exits 4, not 1" test "$rc" -eq 4
  expect "read-only \$RUN: the nothing-ranked outcome was still computed" grep -q 'nothing ranked' "$E"
  refute "read-only \$RUN: the operator never sees bash's raw redirection error" \
    grep -qi 'permission denied' "$E"
  expect "read-only \$RUN: the surviving pins are still called stale" grep -qiE 'WARNING:.*stale' "$E"
  refute "read-only \$RUN: no temp file is created inside an unwritable \$RUN" test -e "$RO/model.txt.tmp"
  # A malformed answers file keeps exit 2 — the code that means "fix THAT file".
  E=$SANDBOX/rm-ro-true2.err
  OFFERED="$TIERLIST" BUDGET=balanced RUN=$RO HOME_CONFIG=$SANDBOX/cfg-cap-bad.yaml \
    bash "$RMS" 2>"$E"; rc=$?
  expect "read-only \$RUN: a malformed answers file still exits 2, not 1" test "$rc" -eq 2
  # A resolution that SUCCEEDS cannot be installed: exiting 0 would leave the caller
  # reading the STALE model.txt as this run's pins, so it must fail — naming the
  # directory, not routing the operator to "your flags are wrong".
  E=$SANDBOX/rm-ro-true0.err
  OFFERED="$TIERLIST" BUDGET=balanced RUN=$RO HOME_CONFIG=/dev/null bash "$RMS" 2>"$E"; rc=$?
  expect "read-only \$RUN: a resolution that cannot be installed is never exit 0" test "$rc" -ne 0
  expect "read-only \$RUN: the failure NAMES the unwritable dir" grep -qF "$RO" "$E"
  expect "read-only \$RUN: the stale pins are left byte-identical" \
    diff -q "$SANDBOX/rm-ro-true.stale" "$RO/model.txt"
  expect "read-only \$RUN: ...and are called stale" grep -qiE 'WARNING:.*stale' "$E"
else
  echo "  skip: read-only \$RUN not enforceable for this user (root?)"
fi
chmod u+w "$RO" 2>/dev/null || :

# --- CRLF-pasted OFFERED resolves identically to its LF twin -------------------
# A Windows/WSL paste used to carry the CR straight into the pin (`strong=…^M`),
# which fails closed at every dispatch with nothing pointing at the CR.
RL=$SANDBOX/rm-lf; RC=$SANDBOX/rm-crlf
OFFERED=$'claude-haiku-5\nclaude-sonnet-5\nclaude-opus-5' \
  BUDGET=balanced RUN=$RL HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
OFFERED=$'claude-haiku-5\r\nclaude-sonnet-5\r\nclaude-opus-5\r' \
  BUDGET=balanced RUN=$RC HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null; rc=$?
expect "CRLF OFFERED: resolves (exit 0)" test "$rc" -eq 0
expect "CRLF OFFERED: pins are byte-identical to the LF twin" diff -q "$RL/model.txt" "$RC/model.txt"
refute "CRLF OFFERED: no CR survives into model.txt" grep -q "$(printf '\r')" "$RC/model.txt"

# --- an OFFERED slug carrying an EMBEDDED control byte is refused --------------
# trim() only ever removed a TRAILING CR. A CR-only paste ("model-a\rmodel-b")
# arrives as ONE line whose slug carries the CR in the middle, and it cleared every
# gate: `strong=model-a\rmodel-b` satisfies the four-line shape check (awk's `.`
# matches CR), while log-spawn.sh collapses the CR before comparing — so the pin
# could never match and every dispatch on that tier failed closed on an invisible
# byte. Refuse it at the source, naming the byte.
R=$SANDBOX/rm-cr-mid; E=$SANDBOX/rm-cr-mid.err; rm -rf "$R"
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
expect "embedded CR: the earlier resolution wrote model.txt" test -f "$R/model.txt"
OFFERED=$'claude-opus-5\rEVIL-5\nclaude-haiku-5' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  bash "$RMS" 2>"$E"; rc=$?
expect "embedded CR: a mid-slug CR exits 1" test "$rc" -eq 1
refute "embedded CR: the stale model.txt is removed per convention" test -e "$R/model.txt"
refute "embedded CR: no temp file survives the refusal" test -e "$R/model.txt.tmp"
expect "embedded CR: the error NAMES the invisible byte" \
  grep -qE 'ERROR:.*(carriage return|CR).*0x0D' "$E"
expect "embedded CR: the error quotes the offending line with the byte made visible" \
  grep -q 'claude-opus-5\\x0DEVIL-5' "$E"
refute "embedded CR: the CR-bearing slug never reaches any file" \
  grep -rq 'EVIL-5' "$R" 2>/dev/null
# Any other control byte is refused the same way, named by its hex value.
R=$SANDBOX/rm-ctrl; E=$SANDBOX/rm-ctrl.err
OFFERED="$(printf 'claude-opus\002-5\nclaude-haiku-5')" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  bash "$RMS" 2>"$E"; rc=$?
expect "embedded control byte: exits 1" test "$rc" -eq 1
expect "embedded control byte: the error names it by hex" grep -q '0x02' "$E"
refute "embedded control byte: nothing is installed" test -e "$R/model.txt"
# Not collateral damage: a display name with spaces is still one opaque slug (an
# OFFERED line is deliberately laxer than an override), and a trailing CR is still
# just a CRLF paste (trimmed, above).
R=$SANDBOX/rm-ctrl-ok
OFFERED=$'cursor-grok 4.5 high fast\nclaude-opus-5' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  bash "$RMS" 2>/dev/null; rc=$?
expect "embedded control byte: a display name with spaces still resolves (exit 0)" test "$rc" -eq 0

# --- a RUN of two-plus interior spaces in an OFFERED slug is refused -----------
# The slug is copied verbatim into the pin, but log-spawn.sh collapses interior
# whitespace runs to a single space before it checks the pin — so a multi-space pin
# can NEVER match, and it cannot be passed as an override either (the shape gate
# forbids whitespace). That deadlock is closed at the source: refuse the slug here.
# A SINGLE interior space (a real display name) survives on both sides and is fine.
R=$SANDBOX/rm-dblspace; E=$SANDBOX/rm-dblspace.err; rm -rf "$R"
OFFERED="$TIERLIST" BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null bash "$RMS" 2>/dev/null
expect "double-space slug: the earlier resolution wrote model.txt" test -f "$R/model.txt"
OFFERED=$'cursor-grok  4.5\nclaude-opus-5' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  bash "$RMS" 2>"$E"; rc=$?
expect "double-space slug: a two-space run inside the slug exits 1" test "$rc" -eq 1
expect "double-space slug: the error names the two-or-more-spaces run" \
  grep -qiE 'ERROR:.*(two or more spaces|run of).*spaces' "$E"
refute "double-space slug: the stale model.txt is removed per convention" test -e "$R/model.txt"
refute "double-space slug: no temp file survives the refusal" test -e "$R/model.txt.tmp"
# A single interior space is NOT collateral damage: it still resolves verbatim.
R=$SANDBOX/rm-1space
OFFERED=$'cursor-grok 4.5 high\nclaude-opus-5' BUDGET=balanced RUN=$R HOME_CONFIG=/dev/null \
  bash "$RMS" 2>/dev/null; rc=$?
expect "single-space slug: a single interior space still resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" executor 'cursor-grok 4.5 high' "single-space slug: a single-space display name survives verbatim into the pin"

# --- exit 4's tier list is budget-aware ---------------------------------------
# Under frugal, coder COLLAPSES into executor, so EXECUTOR_MODEL alone resolves
# both tiers. Naming `coder` here prescribed an override that silently defeats the
# collapse — a message must never instruct a change in resolution semantics.
UNK=$'totally-unknown-1\nother-unknown-2'
R=$SANDBOX/rm-frugal-partial; E=$SANDBOX/rm-frugal-partial.err
OFFERED="$UNK" BUDGET=frugal RUN=$R HOME_CONFIG=/dev/null \
  STRONG_MODEL=totally-unknown-1 bash "$RMS" 2>"$E"; rc=$?
expect "frugal exit 4: STRONG_MODEL alone still exits 4" test "$rc" -eq 4
expect "frugal exit 4: names the executor tier" grep -qE 'ERROR: nothing ranked.*executor' "$E"
refute "frugal exit 4: does NOT name coder (it collapses into executor)" \
  bash -c "grep -E 'ERROR: nothing ranked|remedy:' '$E' | grep -q coder"
# The prescribed remedy must actually resolve the run.
R=$SANDBOX/rm-frugal-fixed
OFFERED="$UNK" BUDGET=frugal RUN=$R HOME_CONFIG=/dev/null \
  STRONG_MODEL=totally-unknown-1 EXECUTOR_MODEL=other-unknown-2 bash "$RMS" 2>/dev/null; rc=$?
expect "frugal exit 4: the named override alone resolves the run (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" coder other-unknown-2 "frugal exit 4: coder still collapses into the executor override"
# balanced/thorough wording is unchanged: BOTH tiers are named there.
for b in balanced thorough; do
  R=$SANDBOX/rm-$b-partial; E=$SANDBOX/rm-$b-partial.err
  OFFERED="$UNK" BUDGET=$b RUN=$R HOME_CONFIG=/dev/null \
    STRONG_MODEL=totally-unknown-1 bash "$RMS" 2>"$E"; rc=$?
  expect "$b exit 4: STRONG_MODEL alone exits 4" test "$rc" -eq 4
  expect "$b exit 4: names coder (no collapse in this posture)" \
    grep -qE 'ERROR: nothing ranked.*coder' "$E"
  expect "$b exit 4: names executor" grep -qE 'ERROR: nothing ranked.*executor' "$E"
done
fi

if t "resolve-models.sh — an unterminated final line in HOME_CONFIG never fuses with OFFERED"; then
# Finding 1, the highest-severity defect this PRD closes. The multi-source feed
# prefixed each source with `sed`, and BSD/macOS sed does NOT append a terminator to
# a file whose FINAL line lacks a trailing newline. A hand-edited ~/.kairos/models.yaml
# missing its trailing newline (the classic hand-edit artifact, and hand-edits are a
# documented Phase 1.5 path) therefore FUSED its last CONFIG line onto the first
# OFFERED line in the awk core's input stream. Two confirmed shapes:
#   * a benign last line (plan_confirmed: true, no \n) SILENTLY SWALLOWED the first
#     — strongest — offered model: strong= pinned one capability rank low with a
#     bogus "degrading" WARNING, and log-spawn.sh then enforced the corrupted pin for
#     every judgment dispatch of the run;
#   * a cost_overrides last line (opus: included, no \n) fused into
#     `included<firstOfferedSlug>`, failed the included|metered check, and exited 2
#     ("fix your answers file") over a value the user never wrote.
# Asserted at the documented interface: a HOME_CONFIG file with NO trailing newline
# in, exit code + the bytes of $RUN/model.txt out.
RMS="$SKILL_DIR/scripts/resolve-models.sh"
export PHASE_KEY=$(phase_key 1.5-model-resolution.md)
unset KAIROS_UPDATE_STRONG_MODEL KAIROS_UPDATE_CODER_MODEL KAIROS_UPDATE_EXECUTOR_MODEL

# --- silent-swallow variant: a benign unterminated last line -------------------
# printf WITHOUT a trailing \n is the whole point of the fixture — it must stay so.
CFG=$SANDBOX/cfg-noeol-benign.yaml
printf 'plan_confirmed: true' > "$CFG"          # NO trailing newline
expect "unterminated config: the fixture genuinely lacks a final newline" \
  test -n "$(tail -c1 "$CFG")"
R=$SANDBOX/rm-noeol-benign; E=$SANDBOX/rm-noeol-benign.err
OFFERED=$'claude-opus-5\nclaude-sonnet-5\nclaude-haiku-5' \
  BUDGET=balanced RUN=$R HOME_CONFIG=$CFG bash "$RMS" 2>"$E"; rc=$?
expect "unterminated config: resolves (exit 0)" test "$rc" -eq 0
kv_is "$R/model.txt" strong   claude-opus-5   "unterminated config: the strongest offered model is NOT swallowed by the unterminated config line"
kv_is "$R/model.txt" coder    claude-sonnet-5 "unterminated config: coder still derives from the full offered list"
kv_is "$R/model.txt" executor claude-haiku-5  "unterminated config: executor still derives from the full offered list"
refute "unterminated config: no bogus 'degrading' WARNING from a truncated offered list" \
  grep -qE 'WARNING:.*degrad' "$E"

# --- loud-but-misleading variant: an unterminated cost_overrides last line -----
CFG=$SANDBOX/cfg-noeol-cost.yaml
printf 'cost_overrides:\n  opus: included' > "$CFG"   # NO trailing newline
expect "unterminated cost override: the fixture genuinely lacks a final newline" \
  test -n "$(tail -c1 "$CFG")"
R=$SANDBOX/rm-noeol-cost; E=$SANDBOX/rm-noeol-cost.err
OFFERED=$'claude-opus-5\nclaude-haiku-5' \
  BUDGET=balanced RUN=$R HOME_CONFIG=$CFG bash "$RMS" 2>"$E"; rc=$?
expect "unterminated cost override: resolves (exit 0), not a misleading exit 2" test "$rc" -eq 0
refute "unterminated cost override: no bogus 'is not included|metered' diagnostic over a fused value" \
  grep -q 'is not included|metered' "$E"
kv_is "$R/model.txt" strong claude-opus-5 "unterminated cost override: the override parses and strong= still resolves"

# --- a terminated config still behaves identically (no collateral change) ------
CFG=$SANDBOX/cfg-eol.yaml
printf 'plan_confirmed: true\n' > "$CFG"        # WITH trailing newline
R=$SANDBOX/rm-eol
OFFERED=$'claude-opus-5\nclaude-sonnet-5\nclaude-haiku-5' \
  BUDGET=balanced RUN=$R HOME_CONFIG=$CFG bash "$RMS" 2>/dev/null
kv_is "$R/model.txt" strong claude-opus-5 "terminated config: unchanged — strongest offered still wins"
fi

if t "resolve-models.sh — refuses to run without Phase 1.5's key"; then
# The model-selection seam had no enforcement at all: the script carried no key, so
# a run could resolve pins from SKILL.md's summary and skip the surface-them step
# (and the mid-run correction path) entirely. The pins are only half the contract.
RMS="$SKILL_DIR/scripts/resolve-models.sh"
RMK=$SANDBOX/rm-key
mkdir -p "$RMK"
env -u PHASE_KEY OFFERED=$'composer-2.5' BUDGET=balanced RUN=$RMK HOME_CONFIG=/dev/null \
  bash "$RMS" >/dev/null 2>"$SANDBOX/rm-nokey.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/1.5-model-resolution.md first' "$SANDBOX/rm-nokey.err"; then
  pass "resolve-models: without PHASE_KEY it exits non-zero naming phases/1.5-model-resolution.md"
else
  fail "resolve-models: without PHASE_KEY it exits non-zero naming phases/1.5-model-resolution.md (rc=$rc)"
fi
refute "resolve-models: the keyless call wrote no model.txt" test -e "$RMK/model.txt"
OFFERED=$'composer-2.5' BUDGET=balanced RUN=$RMK HOME_CONFIG=/dev/null PHASE_KEY=not-the-key \
  bash "$RMS" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "resolve-models: a wrong PHASE_KEY is refused"; else fail "resolve-models: a wrong PHASE_KEY is refused (rc=$rc)"; fi
fi

finish_suite
