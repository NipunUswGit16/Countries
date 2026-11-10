#!/usr/bin/env bash
# resolve-models.sh — compute the per-run model resolution for kairos-component-update.
# Mechanizes Decision A (model selection) so two runs on the same machine cannot
# resolve differently. Decision B (per-task routing from PLAN.md Flag) lives in
# phases/7-execution.md — this script only pins the three tier slugs.
#
# ASYMMETRIC rule (derive capability, never cost): per tier, discard offered
# models below the tier's capability bar; if any INCLUDED model survives, take
# the strongest included one (strength there is free); otherwise everything left
# is metered (unknown cost class counts as metered) and the pick is TIER-MATCHED
# — the lowest capability rank clearing the bar, strongest within that rank.
# Never apply "strongest in class" to metered — that would resolve executor to
# the strongest offered model. strong= deliberately never selects a premium tier
# above the standard flagship (ceiling).
#
# BUDGET postures (never persisted — property of this migration's risk):
#   frugal    — no metered model except unrecoverable-judgment roles (strong
#               stays even when metered); coder collapses into executor.
#   balanced  — asymmetric rule as above (default).
#   thorough  — same selection as balanced (monotonic); Phase 7 runs every
#               verifier on strong — does not promote the executor tier.
#
# ~/.kairos/models.yaml holds ANSWERS not resolutions — cost_overrides,
# capability_overrides, plan_confirmed. No resolved slugs, no cache: re-resolve
# from catalog + overrides + OFFERED every run.
#
# In :  OFFERED   newline-separated model slugs, verbatim from the harness's tool
#                 surface (env var, or stdin when unset). One opaque slug per
#                 line — a display name with SINGLE interior spaces survives; never
#                 word-split. A TRAILING CR is trimmed (a CRLF paste is a typo, not a
#                 different slug), but any control byte INSIDE a slug — or a RUN of
#                 two-plus interior spaces, which log-spawn.sh would collapse so the
#                 pin could never match — is refused (exit 1) rather than guessed at.
#                 See the WHY below.
#       BUDGET    frugal|balanced|thorough (default balanced). Never persisted.
#       RUN       run-state dir; $RUN/model.txt is (re)written.
#       PHASE_KEY proof-of-load key stated in phases/1.5-model-resolution.md. The
#                 pins are only half the contract — the resolve-then-SURFACE
#                 sequence, the stderr-diagnostic handling, and the mid-run
#                 correction path all live in that phase file, and improvising
#                 them from SKILL.md's summary is what the guard stops.
#       STRONG_MODEL / CODER_MODEL / EXECUTOR_MODEL   explicit overrides — beat
#                 every derivation. SKILL.md's Argument extraction maps
#                 --strong-model / --coder-model / --executor-model onto these.
#                 SLUG-SHAPED or refused (exit 1): surrounding whitespace and a
#                 trailing CR are trimmed off, then the value must be non-empty and
#                 contain only letters, digits and . _ - : / — no whitespace, '=',
#                 backslash or control character. Unlike an OFFERED line, an
#                 override may NOT be a display name with spaces (see WHY below).
#       KAIROS_UPDATE_STRONG_MODEL / KAIROS_UPDATE_CODER_MODEL /
#       KAIROS_UPDATE_EXECUTOR_MODEL   standing-configuration equivalents of the
#                 three overrides. Precedence is flag > env > derivation: an env
#                 var is a machine-level default and must LOSE to a per-run flag,
#                 so it only fills a tier whose flag var is unset or empty.
#       HOME_CONFIG  answers file (default ~/.kairos/models.yaml). Answers only —
#                 cost_overrides / capability_overrides; no resolved slugs, no cache.
#       CATALOG   family catalog (default ../reference/model-families.yaml).
# Out:  $RUN/model.txt   strong= / coder= / executor= / budget=  — written ONLY on
#                 exit 0, as EXACTLY four keyed lines with no empty value (checked
#                 before it is installed). Every non-zero exit from a resolution
#                 ATTEMPT removes it (including a stale file from an earlier
#                 resolution): a failed resolution must not leave pins that
#                 log-spawn.sh would keep enforcing, or that Phase 8 would report as
#                 this run's. TWO exits touch nothing, because neither ever started
#                 resolving: the PHASE_KEY refusal (this file was not loaded), and a
#                 `*_MODEL` override-shape refusal (ov_check, fired before BUDGET,
#                 the catalog, or OFFERED are read) — an existing model.txt predates
#                 either check and is not theirs to void. Every OTHER non-zero exit
#                 represents an attempt that actually started (BUDGET/catalog/OFFERED
#                 accepted, the awk core ran) and removes the file. When removal
#                 itself fails (read-only $RUN) the exit code is still the
#                 resolution's own and a WARNING names every file left behind —
#                 silence there would leave the stale pins in force with nothing on
#                 stderr to say so.
#       stderr    one explanation line per tier naming which rule fired, plus
#                 UNRANKED: / UNCLASSIFIED: / WARNING: diagnostics. Never blocks.
# Exit: 0 resolved; 1 OFFERED empty, OFFERED unset on an interactive stdin (there
#       is no list to read — refuse rather than block on a read that never
#       returns), bad BUDGET/catalog, an OFFERED line carrying a control byte or a
#       run of two-plus interior spaces inside the slug, a *_MODEL override value
#       that is not slug-shaped, or a $RUN that cannot be written (the pins
#       resolved; there is nowhere to install them) —
#       every exit-1 cause is the invocation or its filesystem, fixable without
#       touching ~/.kairos/models.yaml, and the message names which one it is;
#       2 malformed ~/.kairos/models.yaml
#       value (cost_overrides / capability_overrides) — that file, not the
#       invocation; 4 no tier could be resolved — nothing ranked (no offered slug
#       matches any family) AND at least one tier has no explicit override: the
#       caller falls back to capability judgment plus explicit --*-model overrides
#       for the tiers the message names (named budget-aware: under frugal, coder
#       collapses into executor, so only executor is ever named for that pair);
#       5 an invariant violation, not an input error — a tier resolved to an empty
#       slug with families ranked, or the pin file came out of the awk core in any
#       shape but four keyed non-empty lines. Neither is written.
#
# WHY overrides are applied BEFORE the nothing-ranked check: exit 4's own message
# prescribes re-running with --*-model overrides. When the ranked-emptiness check
# ran first, that re-run exited 4 again no matter what the caller passed, so the
# documented recovery was impossible and an unrankable harness deadlocked the run.
# WHY the degrade pool does not re-apply the premium ceiling: with only premium
# models offered, the ceiling filtered the degrade pool to nothing and strong=
# resolved to the EMPTY string at exit 0 — and log-spawn.sh records a dispatch
# whose tier pin is empty UNCHECKED, so the pin contract was silently unenforced
# for exactly the judgment roles the ceiling exists to protect. The ceiling still
# binds whenever any within-ceiling model is ranked; only when every ranked model
# is premium does it yield, loudly, to a real slug.
# WHY override values are shape-checked, and why an override may not carry spaces
# when an OFFERED line may: an OFFERED line is only ever CLASSIFIED, but an override
# is copied straight into model.txt — it is a writer, not just a pin. Two confirmed
# failures came from trusting it: STRONG_MODEL=' ' passed the empty-pin guard (which
# only compared against "") and wrote `strong= `, which log-spawn.sh reads as a real
# pin and then refuses every strong dispatch against — the run bricked at the first
# dispatch instead of at resolution; and STRONG_MODEL='a\nexecutor=EVIL' (literal
# backslash-n) became TWO lines, because awk -v expands escapes, forging an
# `executor=` pin above the real one that log-spawn.sh's first-match read then
# preferred. A real newline killed awk itself with exit 2 — colliding with exit 2's
# meaning (a malformed ~/.kairos/models.yaml value) and sending the operator to edit
# the wrong file. All three are invocation errors, so all three now exit 1 from the
# shell before the awk core sees the value. The shape check on the finished pin file
# is the belt to that braces: whatever the cause, only four keyed non-empty lines
# may ever be installed as model.txt.
# WHY a control byte INSIDE an OFFERED slug is refused when a trailing one is trimmed:
# trim() takes the trailing CR because a CRLF paste means the same slug. A CR in the
# middle does not — it is normally a CR-only paste whose whole list arrived as ONE
# line — and it used to sail through every gate: `strong=a\rb` satisfies the four-line
# shape check (awk `.` matches CR) while log-spawn.sh collapses the CR before
# comparing, so the pin could never match and every dispatch on that tier failed
# closed on a byte nobody can see. Guessing where the slug ends would invent a model
# name; refusing (exit 1) and NAMING the byte and the line is the only honest move.
# WHY an unwritable $RUN no longer decides the exit code: the awk core's temp file
# was created inside $RUN, so the redirection failed before awk ran and the script
# exited 1 — the "your invocation is wrong" row — whatever the resolution would have
# said. An operator was sent to re-check flags for a permissions problem, and never
# saw exit 4's judgment fallback or exit 2's "fix the answers file". $RUN's
# writability is now probed first and the resolution runs into a temp outside it, so
# the exit code is the resolution's own. The one case with no true code to report is
# a resolution that SUCCEEDS with nowhere to install: that exits 1 naming the
# directory, because exiting 0 would leave the caller reading a superseded model.txt
# as this run's pins.
set -euo pipefail

[[ "${PHASE_KEY:-}" = "q4vn7xtd" ]] \
  || { echo "FAIL: load phases/1.5-model-resolution.md first" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CATALOG="${CATALOG:-$SCRIPT_DIR/../reference/model-families.yaml}"
BUDGET="${BUDGET:-balanced}"
RUN="${RUN:?RUN dir required}"
HOME_CONFIG="${HOME_CONFIG:-$HOME/.kairos/models.yaml}"

# Flag > env > derivation. The ':' default-assignment only fires when the flag
# var is unset or empty, so a per-run --*-model always beats the standing
# KAIROS_UPDATE_*_MODEL configuration; an unset pair leaves the tier to derive.
: "${STRONG_MODEL:=${KAIROS_UPDATE_STRONG_MODEL:-}}"
: "${CODER_MODEL:=${KAIROS_UPDATE_CODER_MODEL:-}}"
: "${EXECUTOR_MODEL:=${KAIROS_UPDATE_EXECUTOR_MODEL:-}}"

# Every non-zero exit from here on goes through this: a failed resolution leaves
# NO pins on disk, not even ones an earlier resolution wrote. A mid-run correction
# re-runs this script into the same $RUN, so a surviving stale model.txt would keep
# log-spawn.sh enforcing pins this run has already rejected.
#
# EXCEPTION: ov_check below (an override-shape refusal) does NOT call this — see
# ov_fail just under it. An override-shape refusal fires before BUDGET, the
# catalog, or OFFERED are even looked at, so no resolution attempt has started;
# an existing $RUN/model.txt (most commonly the mid-run correction procedure
# echoing the run's OWN surviving pins straight back as overrides) is still this
# run's valid truth, not something this refusal gets to void.
fail_resolution() { # fail_resolution <exit-code> [message...]
  local rc=$1; shift
  [[ $# -eq 0 ]] || printf '%s\n' "$@" >&2
  # `|| :` so an unremovable path (read-only $RUN) cannot replace the real exit
  # code with rm's under `set -e` — the caller must see WHY resolution failed.
  rm -f "$RUN/model.txt" "$RUN/model.txt.tmp" 2>/dev/null || :
  # ...but swallowing that failure silently is its own bug: the pins the removal
  # was supposed to void stay on disk, and log-spawn.sh keeps enforcing them for
  # the rest of the run with nothing on stderr to say they are void. Name what
  # survived and keep the real exit code.
  local f left=""
  for f in "$RUN/model.txt" "$RUN/model.txt.tmp"; do
    if [[ -e "$f" ]]; then left="$left${left:+, }$f"; fi
  done
  [[ -z "$left" ]] || echo "WARNING: could not remove $left — this resolution FAILED, so any pins in that file are STALE and must not be enforced. Fix the permissions on $RUN (or delete the file by hand) before re-running or dispatching." >&2
  exit "$rc"
}

# ── override values are shape-checked BEFORE awk sees them ────────────────────
# An override is the only input copied verbatim into model.txt, and awk -v expands
# backslash escapes, so an unshaped value can forge a whole extra pin line (see the
# WHY block in the header). Trim surrounding whitespace and a trailing CR (a CRLF
# paste is a fixable typo, not an invalid slug), then demand a slug shape.
#
# ov_fail (not fail_resolution) is deliberate: this check runs before BUDGET, the
# catalog, or OFFERED are read at all, so no resolution attempt has begun yet —
# there is nothing here for THIS invocation to have "failed". An existing
# $RUN/model.txt predates this call and is not this refusal's to void; the mid-run
# correction procedure (phases/1.5-model-resolution.md) depends on that, since it
# re-feeds the run's own surviving pins back as overrides and a shape refusal on
# one tier must not brick the other two pins the run still needs for dispatch.
ov_fail() { # ov_fail [message...] — exit 1 WITHOUT touching $RUN/model.txt
  [[ $# -eq 0 ]] || printf '%s\n' "$@" >&2
  exit 1
}
ov_check() { # ov_check <label> <value> — sets OV to the trimmed value, or exits 1
  local label=$1 v=$2
  v=${v%$'\r'}
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  [[ -n "$v" ]] || ov_fail \
    "ERROR: $label is set but empty or whitespace-only — pass a model slug, or leave it unset to derive that tier"
  case $v in
    *[!A-Za-z0-9._:/-]*) ov_fail \
      "ERROR: $label is not a model slug: '$v'" \
      "       allowed: letters, digits and . _ - : / — no whitespace, '=', backslash or control character." \
      "       (An offered model whose DISPLAY NAME contains spaces cannot be passed as an override; it can still be derived from OFFERED.)" ;;
  esac
  OV=$v
}
if [[ -n "${STRONG_MODEL:-}" ]]; then
  ov_check "STRONG_MODEL (--strong-model / KAIROS_UPDATE_STRONG_MODEL)" "$STRONG_MODEL"
  STRONG_MODEL=$OV
fi
if [[ -n "${CODER_MODEL:-}" ]]; then
  ov_check "CODER_MODEL (--coder-model / KAIROS_UPDATE_CODER_MODEL)" "$CODER_MODEL"
  CODER_MODEL=$OV
fi
if [[ -n "${EXECUTOR_MODEL:-}" ]]; then
  ov_check "EXECUTOR_MODEL (--executor-model / KAIROS_UPDATE_EXECUTOR_MODEL)" "$EXECUTOR_MODEL"
  EXECUTOR_MODEL=$OV
fi

case "$BUDGET" in
  frugal|balanced|thorough) ;;
  *) fail_resolution 1 "ERROR: BUDGET must be frugal|balanced|thorough (got: $BUDGET)" ;;
esac
[[ -f "$CATALOG" ]] || fail_resolution 1 "ERROR: catalog not found: $CATALOG"
# OFFERED unset means the list arrives on stdin. An interactive stdin carries no
# list, so the read below would block forever instead of failing.
if [[ -z "${OFFERED:-}" ]] && [[ -t 0 ]]; then
  fail_resolution 1 "ERROR: OFFERED unset and stdin is a terminal — set OFFERED or redirect the offered-model list into stdin"
fi
mkdir -p "$RUN"

# ── where the temp file goes, and why it is not unconditionally $RUN ──────────
# Every write this script makes lands in $RUN, and the FIRST of them used to be the
# awk core's `> "$RUN/model.txt.tmp"`. On an unwritable $RUN (wrong ownership, a
# read-only mount) that redirection failed before awk ever ran, so EVERY shape of
# input exited 1 — the "your invocation is wrong" row — for a filesystem problem,
# and the resolution's own outcome (exit 4's judgment fallback, exit 2's "fix the
# answers file") was never computed at all. Probe with a file the directory must let
# us CREATE — which is exactly what installing model.txt needs, and is NOT implied by
# being able to truncate a leftover model.txt.tmp — and resolve into a temp OUTSIDE
# $RUN when it cannot. The resolution then runs to completion and reports its true
# exit code; only the install is lost, and that is reported on its own terms below.
probe="$RUN/.model-write-probe.$$"
if ( : > "$probe" ) 2>/dev/null; then    # subshell: bash's own redirection error
  rm -f "$probe"                         # is emitted before a plain `2>/dev/null`
  run_writable=1                         # applies, and must not reach the operator
  tmp_out="$RUN/model.txt.tmp"
else
  run_writable=0
  tmp_out=$(mktemp "${TMPDIR:-/tmp}/kairos-model-resolution.XXXXXX") || fail_resolution 1 \
    "ERROR: the run-state dir is not writable ($RUN) and no temp file could be created under ${TMPDIR:-/tmp} either — fix one of the two and re-run"
  trap 'rm -f "$tmp_out"' EXIT
fi

# One prefixed stream so the awk core sees catalog, answers, and OFFERED in order.
# Each source is prefixed with awk, not sed: awk's `print` always TERMINATES the
# record it emits, so a source file whose final line lacks a trailing newline cannot
# fuse that line onto the first line of the next source. BSD/macOS sed preserved a
# missing terminator, which fused ~/.kairos/models.yaml's last line onto the first
# OFFERED slug when the file was hand-edited without a final newline (a documented
# Phase 1.5 path) — silently swallowing the strongest offered model, or turning a
# valid cost_overrides line into a bogus exit-2 "fix your answers file". The awk
# reformulation is byte-for-byte identical to the sed one on any properly terminated
# source (print of $0 does not interpret the line), so the happy path is unchanged.
feed() {
  awk '{print "CATALOG " $0}' "$CATALOG"
  [[ -f "$HOME_CONFIG" ]] && awk '{print "CONFIG " $0}' "$HOME_CONFIG"
  if [[ -n "${OFFERED:-}" ]]; then
    printf '%s\n' "$OFFERED" | awk '{print "OFFERED " $0}'
  else
    awk '{print "OFFERED " $0}'
  fi
}

if feed | awk \
    -v budget="$BUDGET" \
    -v ov_strong="${STRONG_MODEL:-}" \
    -v ov_coder="${CODER_MODEL:-}" \
    -v ov_exec="${EXECUTOR_MODEL:-}" '
# A trailing CR is trimmed with the whitespace: an OFFERED list pasted from a CRLF
# source used to carry the CR into the pin (strong=slug\r), which fails closed at
# every dispatch with nothing on stderr pointing at the invisible byte.
function trim(s)   { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function stripc(s) { sub(/#.*/, "", s); return s }
# Control bytes are matched through a literal table rather than [[:cntrl:]] or an
# octal-escaped range: character classes and \nnn escapes are the two corners where
# BSD awk, mawk and gawk disagree, and this gate must behave identically on all three.
BEGIN {
  for (i = 1; i <= 31; i++) { c = sprintf("%c", i); CTRL = CTRL c; ORD[c] = i }
  c = sprintf("%c", 127); CTRL = CTRL c; ORD[c] = 127
}
function ctrlpos(s,   i, n) {          # 1-based position of the first control byte, else 0
  n = length(s)
  for (i = 1; i <= n; i++) if (index(CTRL, substr(s, i, 1))) return i
  return 0
}
function ctrlname(c) {
  if (ORD[c] == 13) return "carriage return (CR, 0x0D)"
  if (ORD[c] == 9)  return "tab (0x09)"
  return sprintf("control byte 0x%02X", ORD[c])
}
function vis(s,   i, n, c, out) {       # the line with its invisible bytes spelled out
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    out = out (index(CTRL, c) ? sprintf("\\x%02X", ORD[c]) : c)
  }
  return out
}
function rank_num(v) {
  if (v == "cheap") return 1; if (v == "coder") return 2
  if (v == "strong") return 3; if (v == "premium") return 4
  return 0
}
function diag(m) { print m > "/dev/stderr" }
function err(m)  { print "ERROR: " m > "/dev/stderr" }
function parse_list(s, arr,   n, i) {         # "key: [a, b, c]" -> arr
  gsub(/^[^\[]*\[|\].*$/, "", s)
  n = split(s, arr, /,/)
  for (i = 1; i <= n; i++) arr[i] = trim(arr[i])
  return n
}

/^CATALOG / {
  line = stripc(substr($0, 9))
  if (line ~ /^families:/)       { sect = "families"; next }
  if (line ~ /^plan:/)           { sect = "plan"; next }
  if (line ~ /^weak_suffixes:/)  { nweak  = parse_list(line, weak);  sect = ""; next }
  if (line ~ /^speed_suffixes:/) { nspeed = parse_list(line, speed); sect = ""; next }
  if (line ~ /^[^ \t]/ && line != "") { sect = ""; next }
  if (sect == "families" && line ~ /^[ \t]+[^ \t]+:/) {
    key = line; sub(/:.*/, "", key); key = trim(key)
    val = line; sub(/^[^:]*:/, "", val); val = trim(val)
    r = rank_num(val)
    if (r == 0) { err("catalog: family " key " has invalid rank: " val); fatal = 1; exit 1 }
    famrank[key] = r
  } else if (sect == "plan") {
    if (line ~ /included:/) { n = parse_list(line, t); for (i = 1; i <= n; i++) plancost[t[i]] = "included" }
    else if (line ~ /metered:/) { n = parse_list(line, t); for (i = 1; i <= n; i++) plancost[t[i]] = "metered" }
  }
  next
}
/^CONFIG / {
  line = stripc(substr($0, 8))
  if (line ~ /^cost_overrides:/)       { csect = "cost"; next }
  if (line ~ /^capability_overrides:/) { csect = "cap"; next }
  if (line ~ /^[^ \t]/ && line != "")  { csect = ""; next }
  if (csect != "" && line ~ /^[ \t]+[^ \t]+:/) {
    # Family classification matches a catalog/override key as a substring of the
    # LOWERCASED slug, so an override key is normalized to lowercase here — an
    # answers-file entry like `capability_overrides: MyFam: coder` would otherwise
    # rank a key that no lowercased slug can ever match, and sit silently inert.
    key = line; sub(/:.*/, "", key); key = tolower(trim(key))
    val = line; sub(/^[^:]*:/, "", val); val = trim(val)
    if (csect == "cost") {
      if (val != "included" && val != "metered") {
        err("cost_overrides." key ": " val " is not included|metered"); fatal = 2; exit 2
      }
      costov[key] = val
    } else {
      r = rank_num(val)
      if (r == 0) {
        err("capability_overrides." key ": " val " is not one of cheap|coder|strong|premium"); fatal = 2; exit 2
      }
      famrank[key] = r                 # a confirmed answer ranks the family
    }
  }
  next
}
/^OFFERED / {
  noff++
  s = trim(substr($0, 9))
  if (s == "") next
  # trim() takes a TRAILING CR (a CRLF paste is a typo, not a different slug), but a
  # control byte INSIDE a slug is not a typo the script may guess at: it is copied
  # verbatim into the pin, `strong=a\rb` satisfies the four-line shape gate (awk `.`
  # matches CR), and log-spawn.sh collapses the CR before comparing — so the pin can
  # never match and every dispatch on that tier fails closed on an invisible byte.
  p = ctrlpos(s)
  if (p > 0) {
    err("OFFERED line " noff " carries an invisible " ctrlname(substr(s, p, 1)) " inside the slug, at character " p ": " vis(s))
    diag("       An offered slug is copied verbatim into $RUN/model.txt, and a pin carrying a control byte can never match at dispatch (log-spawn.sh collapses it first) — every dispatch on that tier would fail closed on a byte nobody can see.")
    diag("       A CR in the MIDDLE of a line usually means the list was pasted with CR-only line endings and arrived as ONE line: re-copy it from your tool surface, one slug per real newline. (A trailing CR from a CRLF paste is trimmed and is fine.)")
    fatal = 1; exit 1
  }
  # A RUN of two-plus interior spaces can never survive to match at dispatch. The
  # slug is copied verbatim into the pin, but log-spawn.sh COLLAPSES whitespace runs
  # to a single space before comparing (a single interior space, as in a display
  # name, survives on both sides and is fine — only a run of two-plus differs). A
  # multi-space pin therefore fails closed on every dispatch of its tier, and it
  # cannot be corrected with an override either: the override shape gate forbids any
  # whitespace. Refuse it here, where the byte can still be pointed at. (Interior
  # tabs are already refused above as control bytes; leading/trailing whitespace was
  # already trimmed; so any survivor is an interior multi-space run.)
  if (index(s, "  ")) {
    err("OFFERED line " noff " carries a run of two or more spaces inside the slug: " s)
    diag("       An offered slug is copied verbatim into $RUN/model.txt, but log-spawn.sh collapses interior whitespace runs to a single space before it checks the pin — a multi-space pin can never match, and it cannot be passed as an override either (the shape gate forbids whitespace). Re-copy the slug from your tool surface with single spaces, or pick a slug whose display name has none.")
    fatal = 1; exit 1
  }
  slugs[++nslugs] = s
  next
}

# ── strength ordering: rank → speed-sibling (base wins) → weak-sibling same-base (tier-dependent) → version → weak-vs-non-weak cross-suffix (tier-dependent) → alphabetical ──
function stripsfx(s, arr, n,   i) {            # trailing -<suffix> from arr[1..n], else s
  for (i = 1; i <= n; i++)
    if (s ~ ("-" arr[i] "$")) return substr(s, 1, length(s) - length(arr[i]) - 1)
  return s
}
function isweak(s,   i) {                       # does s carry a trailing weak suffix?
  for (i = 1; i <= nweak; i++) if (s ~ ("-" weak[i] "$")) return 1
  return 0
}
function isbuilddate(x) {                       # trailing Anthropic build-date group:
  return (x ~ /^20[0-9][0-9][0-9][0-9][0-9][0-9]$/) # exactly 8 digits, plausible YYYYMMDD (leading "20")
}
function versegs(s,   lc, rest, n, A, i, out) { # numeric segments after the family match
  lc = tolower(s)
  rest = substr(lc, index(lc, famof[s]) + length(famof[s]))
  gsub(/[^0-9]+/, " ", rest)
  n = split(trim(rest), A, " ")
  # A trailing build-date (e.g. -20250805) is a date suffix, not a version segment:
  # drop it here so it can never outrank a real version. vercmp() consults it only as
  # a lowest-priority tiebreaker (see verdate). Guarded by n>1 so a bare date-only
  # slug keeps its one segment rather than collapsing to empty.
  if (n > 1 && isbuilddate(A[n])) n--
  out = ""
  for (i = 1; i <= n; i++) out = (i == 1) ? A[i] : out " " A[i]
  return out
}
function verdate(s,   lc, rest, n, A) {         # trailing build-date group, or "" if none
  lc = tolower(s)
  rest = substr(lc, index(lc, famof[s]) + length(famof[s]))
  gsub(/[^0-9]+/, " ", rest)
  n = split(trim(rest), A, " ")
  if (n > 1 && isbuilddate(A[n])) return A[n]
  return ""
}
function vercmp(a, b,   A, B, na, nb, i, mx, da, db) { # L-to-R; a missing segment loses
  na = split(versegs(a), A, " "); nb = split(versegs(b), B, " ")
  mx = na > nb ? na : nb
  for (i = 1; i <= mx; i++) {
    if (i > na) return -1
    if (i > nb) return 1
    if (A[i] + 0 > B[i] + 0) return 1
    if (A[i] + 0 < B[i] + 0) return -1
  }
  # Real version segments tie: break by build-date (newer = stronger). Undated slugs
  # yield "" (numeric 0) on both sides and stay equal — behavior unchanged.
  da = verdate(a); db = verdate(b)
  if (da + 0 > db + 0) return 1
  if (da + 0 < db + 0) return -1
  return 0
}
function stronger(a, b, tier,   sa, sb, v, wa, wb) {
  if (rankof[a] != rankof[b]) return rankof[a] > rankof[b] ? a : b
  if (famof[a] == famof[b]) {
    # The two sibling rules below pair a suffixed slug against its EXACT base
    # (same string once the suffix is stripped). A cross-suffix pair (e.g.
    # -flash vs -pro) matches neither, so it falls to vercmp; the weak-vs-non-weak
    # tiebreak after vercmp then demotes the distilled half even though the
    # stripped bases differ, leaving only a genuine same-weakness tie to reach the
    # alphabetical last resort.
    sa = stripsfx(a, speed, nspeed); sb = stripsfx(b, speed, nspeed)
    if (sa == sb && a != b)                    # speed siblings: same intelligence, costlier serving
      return (a == sa) ? a : b                 # every tier: base wins (Fast is a latency purchase)
    sa = stripsfx(a, weak, nweak); sb = stripsfx(b, weak, nweak)
    if (sa == sb && a != b) {                  # weak siblings (same base): distilled / smaller
      if (tier == "executor") return (a != sa) ? a : b   # volume tier: suffixed wins
      return (a == sa) ? a : b                           # quality tiers: base wins
    }
    v = vercmp(a, b)
    if (v > 0) return a
    if (v < 0) return b
    # Same family, versions tie: a weak-suffixed slug is still the distilled half
    # of a cross-suffix pair (e.g. -flash vs -pro), so it loses to a non-weak
    # sibling on the quality tiers and wins on executor — decided here, before the
    # alphabetical last resort would otherwise pin the weaker half just because it
    # sorts earlier (the confirmed bug: a -flash slug outranked its non-weak sibling).
    wa = isweak(a); wb = isweak(b)
    if (wa != wb) {
      if (tier == "executor") return wa ? a : b          # volume tier: the weak half
      return wa ? b : a                                  # quality tiers: the base
    }
  }
  return (a < b) ? a : b                       # alphabetical, earlier wins
}
function strongest(tier, arr, n,   i, best) {
  best = arr[1]
  for (i = 2; i <= n; i++) best = stronger(best, arr[i], tier)
  return best
}
function tiermatched(tier, arr, n,   i, minr, nw, within) {
  minr = 99
  for (i = 1; i <= n; i++) if (rankof[arr[i]] < minr) minr = rankof[arr[i]]
  nw = 0
  for (i = 1; i <= n; i++) if (rankof[arr[i]] == minr) within[++nw] = arr[i]
  return strongest(tier, within, nw)
}

# ── the asymmetric cost rule, per tier ──
function resolve(tier, bar, ov,   i, s, nc, ni, cands, inc, np, pool, pick) {
  # An explicit override is read FIRST — before any check on what ranked — so a
  # harness whose slugs match no family is recoverable by passing overrides.
  if (ov != "") { diag(tier "=" ov "  [explicit override — beats every derivation]"); return ov }
  if (nranked == 0) {                                    # no ordering to derive from
    err("cannot derive " tier " — nothing ranked and no explicit " toupper(tier) "_MODEL override (--" tier "-model)")
    return ""
  }
  nc = 0; ni = 0
  for (i = 1; i <= nranked; i++) {
    s = ranked[i]
    if (rankof[s] < bar) continue
    if (tier == "strong" && rankof[s] >= 4) continue     # premium ceiling
    cands[++nc] = s
    if (costof[s] == "included") inc[++ni] = s
  }
  if (nc == 0) {                                         # empty tier: degrade, warn
    np = 0
    for (i = 1; i <= nranked; i++) {
      s = ranked[i]
      if (tier == "strong" && rankof[s] >= 4) continue
      pool[++np] = s
    }
    if (np == 0) {
      # Every ranked model is premium, so the ceiling has nothing to fall back to.
      # It yields rather than resolving the tier to the empty string: an empty pin
      # is unenforceable at dispatch (log-spawn.sh records it unchecked), which is
      # strictly worse than a warned premium pin the user can see and override.
      for (i = 1; i <= nranked; i++) pool[++np] = ranked[i]
      pick = strongest(tier, pool, np)
      diag("WARNING: every ranked offered model is premium — the " tier " ceiling cannot be honored; pinning the strongest offered: " pick " (premium spend — override with --" tier "-model to change it)")
      return pick
    }
    pick = strongest(tier, pool, np)
    diag("WARNING: nothing offered clears the " tier " bar — degrading to strongest ranked offered: " pick)
    return pick
  }
  if (budget == "frugal" && tier != "strong") {          # strong roles are exempt
    if (ni > 0) {
      pick = strongest(tier, inc, ni)
      diag(tier "=" pick "  [frugal: strongest included model clearing the bar]")
    } else {
      pick = tiermatched(tier, cands, nc)
      diag(tier "=" pick "  [frugal: no included model offered — cheapest metered tier; this is NOT free]")
    }
    return pick
  }
  if (ni > 0) {
    pick = strongest(tier, inc, ni)
    diag(tier "=" pick "  [strongest included model clearing the " tier " bar — strength here is free]")
  } else {
    pick = tiermatched(tier, cands, nc)
    diag(tier "=" pick "  [all candidates metered — tier-matched: lowest rank clearing the bar]")
  }
  return pick
}

END {
  if (fatal) exit fatal
  if (nslugs == 0) { err("OFFERED is empty"); exit 1 }

  # classify: longest case-insensitive substring match wins; ties break alphabetically
  nranked = 0
  for (i = 1; i <= nslugs; i++) {
    s = slugs[i]; lc = tolower(s); best = ""
    for (f in famrank)
      if (index(lc, f) && (length(f) > length(best) || (length(f) == length(best) && f < best)))
        best = f
    if (best == "") {
      diag("UNRANKED: " s " matches no catalog family — excluded from auto-selection (a confirmed capability_overrides tier makes it eligible)")
    } else {
      ranked[++nranked] = s; famof[s] = best; rankof[s] = famrank[best]
    }
  }
  # Nothing ranked is NOT decided here: explicit overrides are read first (each
  # per-tier resolve() call), and three of them are a complete resolution. Only the
  # empty-pin check below can turn this into a non-zero exit.
  if (nranked == 0)
    diag("WARNING: nothing ranked — no offered slug matches any catalog family; only explicit --*-model overrides can pin a tier this run")

  # cost class: override > plan default > unknown-therefore-metered (reported once per family)
  for (i = 1; i <= nranked; i++) {
    s = ranked[i]; f = famof[s]
    c = (f in costov) ? costov[f] : (f in plancost) ? plancost[f] : "unknown"
    if (c == "unknown") {
      c = "metered"
      if (!(f in reported)) {
        reported[f] = 1
        diag("UNCLASSIFIED: family " f " has no cost class — treating as metered (answer once to override)")
      }
    }
    costof[s] = c
  }

  strongpick = resolve("strong", 3, ov_strong)
  execpick   = resolve("executor", 1, ov_exec)
  if (budget == "frugal" && ov_coder == "") {
    coderpick = execpick
    if (coderpick != "")
      diag("coder=" coderpick "  [frugal: <CODER_MODEL> collapses into <EXECUTOR_MODEL>]")
  } else {
    coderpick = resolve("coder", 2, ov_coder)
  }
  # The posture notes below quote strongpick, so they are skipped when it is empty
  # — the empty-pin refusal is the only thing that should speak in that case.
  if (budget == "thorough" && strongpick != "")
    diag("note: thorough — every Phase 7 verifier runs on " strongpick)
  if (budget == "frugal" && strongpick != "") {
    diag("note: frugal — conflict-resolver and flagged/bootstrapped-task verifiers stay on " strongpick " even if metered (unrecoverable-judgment exemption)")
    # Same-rank pin question (story 3): only the user knows which same-rank
    # version their plan prices lower — the script never ranks by price.
    if (ov_strong == "" && costof[strongpick] == "metered") {
      alts = ""
      for (i = 1; i <= nranked; i++) {
        s = ranked[i]
        if (s != strongpick && rankof[s] == rankof[strongpick])
          alts = alts (alts == "" ? "" : ", ") s
      }
      if (alts != "")
        diag("CHOICE: judgment roles will run on " strongpick " (metered); same-rank alternatives offered: " alts " — ask the user which to pin (answer becomes --strong-model); proceed with " strongpick " if unanswered")
    }
  }

  # ── no pin may be empty ──────────────────────────────────────────────────────
  # An empty pin is worse than no pins at all: log-spawn.sh reads a missing/empty
  # tier line as the legacy shape it must record UNCHECKED, so every dispatch on
  # that tier goes unenforced for the whole run. Refuse instead of printing — the shell
  # wrapper below writes model.txt only when this block did not exit.
  # The tiers NAMED are the ones an override would actually be consumed for, which
  # is budget-aware: under frugal with no CODER_MODEL, coder IS the executor pick
  # (the collapse above), so naming coder would prescribe an override that silently
  # defeats the collapse. A message must never instruct a change in resolution
  # semantics — naming executor alone is both sufficient and truthful. (collapsed
  # implies coderpick == execpick, so executor is already named whenever coder is
  # empty here; the emptiness test itself stays over all three tiers.)
  collapsed = (budget == "frugal" && ov_coder == "")
  anyempty = (strongpick == "" || coderpick == "" || execpick == "")
  missing = ""
  if (strongpick == "")                 missing = missing (missing == "" ? "" : ", ") "strong"
  if (coderpick  == "" && !collapsed)   missing = missing (missing == "" ? "" : ", ") "coder"
  if (execpick   == "")                 missing = missing (missing == "" ? "" : ", ") "executor"
  if (anyempty) {
    if (nranked == 0) {
      err("nothing ranked — no offered slug matches any catalog family, and no explicit override was given for: " missing)
      diag("       remedy: re-run with an explicit --<tier>-model (or KAIROS_UPDATE_<TIER>_MODEL) for each of: " missing " — picked by capability judgment from the offered list. Better, add a confirmed capability_overrides entry for the offered families so the next run derives instead of judging.")
      exit 4
    }
    err("resolved an empty pin for: " missing " — refusing to write model.txt, because an empty pin cannot be enforced at dispatch. Re-run with an explicit override for those tiers, and report this: with families ranked, no tier should ever resolve empty")
    exit 5
  }

  print "strong=" strongpick
  print "coder=" coderpick
  print "executor=" execpick
  print "budget=" budget
}
' > "$tmp_out"; then
  # ── output-shape gate: only four keyed non-empty lines may become model.txt ──
  # Belt to the override validation's braces. model.txt is a machine contract —
  # log-spawn.sh takes the FIRST match per tier — so an extra, duplicated or
  # valueless line is not a cosmetic problem, it is a pin nobody chose. Whatever
  # produced it (a future edit to the awk core, an input path nobody validated),
  # refusing to install it is strictly better than installing it and warning.
  if awk '
      /^(strong|coder|executor|budget)=.+$/ { k = $0; sub(/=.*/, "", k)
                                              if (seen[k]++) exit 1
                                              n++; next }
      { exit 1 }
      END { exit (n == 4 && NR == 4) ? 0 : 1 }
    ' "$tmp_out"; then
    # Resolved cleanly, but an unwritable $RUN has nowhere to put the pins. Exiting 0
    # here would be the worst of the options: model.txt's whole contract is that it
    # holds THIS run's pins, so a success claim over a superseded file hands the next
    # dispatch someone else's. Fail instead — naming the directory, so the operator
    # is not sent to the "your flags are wrong" row for a permissions problem.
    if [[ "$run_writable" = 0 ]]; then
      fail_resolution 1 \
        "ERROR: the resolution SUCCEEDED but its pins cannot be installed — the run-state dir is not writable: $RUN" \
        "       Nothing about the invocation is wrong: the four pins resolved cleanly (see the per-tier lines above), there is simply nowhere to write them." \
        "       Fix the permissions on $RUN (or point RUN at a writable dir) and re-run. Never hand-write model.txt."
    fi
    mv "$tmp_out" "$RUN/model.txt"
  else
    echo "ERROR: the resolver produced a malformed pin file — expected exactly four lines (strong= / coder= / executor= / budget=, each once, none empty). Refusing to install it as \$RUN/model.txt; report this as a skill bug." >&2
    sed -n 's/^/       got: /p' "$tmp_out" >&2 || :
    fail_resolution 5
  fi
else
  # The awk core refused (bad catalog rank, malformed answer, or an unresolvable
  # tier). fail_resolution clears the partial temp AND any stale model.txt.
  rc=$?
  fail_resolution "$rc"
fi
