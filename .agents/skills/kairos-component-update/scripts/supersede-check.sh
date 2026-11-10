#!/usr/bin/env bash
# supersede-check.sh — supersede gate, run beside plan-completeness.sh and
# followup-completeness.sh before PLAN.md is committed (phases/6-planning.md).
#
# It recomputes the retired set itself — the per-collector edge files plus
# PLAN.md's `apply` set, closed transitively — and fails the run when an
# in-range slug retired by an APPLIED superseder from an ADDED list is not
# dispositioned in one of the two sanctioned ways. This is the mechanical half
# of the supersede design: the author declares the relationship, the planner
# defers the superseded slug until the superseder is dispositioned, and this
# gate proves the final plan honored it — a forgotten deferral or a missed
# retirement is a loud, named failure here rather than a silent ship or a
# false Phase-8 gate failure.
#
# WHY a separate script and not more logic in plan-completeness.sh: that gate's
# parser reads only the slug column and is kept single-purpose. This one needs
# the disposition AND the reason of every row plus a graph closure over the
# edges — a different shape of read.
#
# Env in:  RUN   migration state dir (required)
#          PLAN  path to PLAN.md (required)
# Reads:   $RUN/upgrades-added.txt         template witness (Phase 3)
#          $RUN/upgrades-modified.txt      template amended list, if present
#          $RUN/supersede-edges.tsv        template edges (build-manifest.sh)
#          $RUN/common-upgrades-added.txt  common witness (Phase 3.5), if present
#          $RUN/common-upgrades-modified.txt
#          $RUN/common-supersede-edges.tsv common edges (collect-common.sh)
#          $RUN/lib-upgrades-added.txt     lib witness (Phase 3 frontend arm), if present
#          $RUN/lib-upgrades-modified.txt
#          $RUN/lib-supersede-edges.tsv    lib edges (collect-lib.sh)
#          $PLAN                            the plan under review
#
#   Edge row: module <TAB> superseder-stem <TAB> superseded-stem <TAB> superseder-list
#             where superseder-list is `added` or `modified`. Only `added`-list
#             edges are enforced; `modified`-list edges are advisory (the planner
#             surfaces them in Q&A) and excluded here — a shipped amendment must
#             not mechanically retire another file.
#
#   Same-source rule, re-checked here: an edge is enforced only when its TARGET
#   stem is in the declaring source's own collected lists (that source's added ∪
#   modified witness). The collectors cannot see each other's lists, so a
#   `supersedes:` naming a stem another source shipped leaves the collector as
#   an "out of range" row — informational by contract — yet PLAN.md is the union
#   of all sources and carries that stem. Enforcing on stem alone would let one
#   repo's declaration retire another repo's migration with a skip that rides
#   without per-item confirmation. Such a row is WARNed and ignored, which is the
#   no-op reference/upgrade-files.md promises.
#
# Stderr:  the violating slug(s) on failure; an OK line on success — silence is
#          not a result a caller can read.
# Exit:    0  every retired slug is dispositioned skip-with-link or apply-with-override
#          1  a retired slug lacks its disposition, or a `deferred` placeholder survived
#          2  the gate could not run and must not answer "clean": an edge file is
#             ABSENT while its added-list witness is present (the collector never
#             ran, or $RUN was swept — re-run the collecting phase and come back),
#             or an input could not be read / a temp file could not be made.
#
# Every read is CHECKED under `set -u`: this gate's failure mode on a silently
# empty intermediate (an unparsed PLAN.md → zero present slugs → every retired
# target "out of range") is an OK line over an unhonored edge.
set -u

: "${RUN:?FAIL: RUN not set}"
: "${PLAN:?FAIL: PLAN not set}"

[[ -f "$PLAN" ]] || { echo "FAIL: plan not found: $PLAN" >&2; exit 1; }

# --- edge-file presence, before any closure ------------------------------------
# "An absent edge file where its added-list witness exists" is the same missing
# input plan-completeness.sh guards: the collector for that source never ran, or
# the state dir was swept. The gate must not pass over it. The witness is written
# unconditionally by the collector (empty when the range added no upgrade-files),
# so present-and-empty is distinguishable from absent.
check_edges_present() { # <added-list> <edge-file> <phase-hint>
  [[ -f "$RUN/$1" ]] || return 0        # no witness for this source — nothing to demand
  [[ -f "$RUN/$2" ]] && return 0
  echo "FAIL: $RUN/$1 is present but $RUN/$2 is absent — $3 never ran here, or the state dir was swept. This gate cannot pass over a missing edge file: re-run that phase, then re-run this gate." >&2
  exit 2
}
check_edges_present upgrades-added.txt        supersede-edges.tsv        "template edge emission (build-manifest.sh, Phase 3)"
check_edges_present common-upgrades-added.txt common-supersede-edges.tsv "common edge emission (collect-common.sh, Phase 3.5)"
check_edges_present lib-upgrades-added.txt    lib-supersede-edges.tsv    "library edge emission (collect-lib.sh, Phase 3 frontend arm)"

# --- temp files ---------------------------------------------------------------
EDGES=$(mktemp "${TMPDIR:-/tmp}/supersede-edges.XXXXXX") \
  || { echo "FAIL: could not create a temp file under ${TMPDIR:-/tmp} — the gate cannot run (this is not a pass)." >&2; exit 2; }
DISP=$(mktemp "${TMPDIR:-/tmp}/supersede-disp.XXXXXX") \
  || { rm -f "$EDGES"; echo "FAIL: could not create a temp file under ${TMPDIR:-/tmp} — the gate cannot run (this is not a pass)." >&2; exit 2; }
STEMS=$(mktemp "${TMPDIR:-/tmp}/supersede-stems.XXXXXX") \
  || { rm -f "$EDGES" "$DISP"; echo "FAIL: could not create a temp file under ${TMPDIR:-/tmp} — the gate cannot run (this is not a pass)." >&2; exit 2; }
trap 'rm -f "$EDGES" "$DISP" "$STEMS"' EXIT

# --- parse PLAN.md's disposition table into slug <TAB> disposition <TAB> reason -
# Only the `## Upgrade-file Dispositions` section; a `| `slug` | disp | reason |`
# row. The disposition keyword is lowercased for matching; the reason is kept
# verbatim (it carries the `superseded by <stem>` / `override:` grammar).
# Parsed BEFORE the edges so the same-source filter below can tell "target is in
# the plan from another source" (WARN) from "target is nowhere" (silent).
awk '
  /^## Upgrade-file Dispositions/ { insec = 1; next }
  insec && /^## / { insec = 0 }
  insec && /^\| *`/ {
    # Cell-split by the FIRST two pipes only: the reason is the rest of the row,
    # so a `|` (or an escaped `\|`) inside a free-text reason cannot truncate it
    # into a false UNRETIRED. The row-terminating pipe is stripped first.
    line = $0
    sub(/^\|[ \t]*/, "", line); sub(/[ \t]*\|[ \t]*$/, "", line)
    i = index(line, "|"); slug = substr(line, 1, i - 1); rest = substr(line, i + 1)
    j = index(rest, "|")
    if (j > 0) { disp = substr(rest, 1, j - 1); reason = substr(rest, j + 1) } else { disp = rest; reason = "" }
    gsub(/`/, "", slug); gsub(/^[ \t]+|[ \t]+$/, "", slug)
    gsub(/^[ \t]+|[ \t]+$/, "", disp)
    gsub(/`/, "", reason); gsub(/^[ \t]+|[ \t]+$/, "", reason)
    if (slug == "" || slug == "Upgrade-file") next
    dl = tolower(disp)
    print slug "\t" dl "\t" reason
  }
' "$PLAN" > "$DISP" \
  || { echo "FAIL: could not parse the disposition table of $PLAN — the gate cannot run (this is not a pass). Check that the plan is readable and ${TMPDIR:-/tmp} is writable." >&2; exit 2; }

# A plan with NO parsed disposition rows while a witness list names upgrade-files
# is not "nothing retired" — it is a table this parser could not find (heading
# renamed, section missing, rows not in the `| \`slug\` | … |` shape). Zero present
# slugs would make every retired target look out of range and pass. That is
# plan-completeness.sh's failure to name in full; here it is a refusal, so this
# gate does not depend on the other having run first.
if [[ ! -s "$DISP" ]]; then
  for w in upgrades-added.txt common-upgrades-added.txt lib-upgrades-added.txt; do
    if [[ -f "$RUN/$w" ]] && grep -q . "$RUN/$w"; then
      echo "FAIL: $PLAN has no parseable \`## Upgrade-file Dispositions\` rows while $RUN/$w names upgrade-files — the gate cannot run (this is not a pass). Restore the table (heading and \`| \`slug\` | disposition | reason |\` rows), then re-run this gate." >&2
      exit 2
    fi
  done
fi

# --- collect the enforceable edges (added-list only, same-source targets only) --
# Row: module <TAB> superseder <TAB> superseded <TAB> list. Emit `superseder <TAB>
# superseded` for `added`-list rows whose target this SAME source collected;
# `modified`-list edges are advisory and handled by the planner, never enforced
# here. The per-source collected set is the stems of that source's added ∪
# modified witness lists (path per line; stem = basename minus `.md`, taken with
# parameter expansion so a leading-dash basename can never reach a command as an
# option). An absent modified list is optional and contributes nothing.
: > "$EDGES" || { echo "FAIL: cannot write $EDGES — the gate cannot run (this is not a pass)." >&2; exit 2; }
collect_edges() { # <source-label> <added-list> <modified-list> <edge-file>
  local label="$1" added="$2" modified="$3" ef="$4" l p b
  [[ -f "$RUN/$ef" ]] || return 0
  : > "$STEMS" || { echo "FAIL: cannot write $STEMS — the gate cannot run (this is not a pass)." >&2; exit 2; }
  for l in "$added" "$modified"; do
    [[ -f "$RUN/$l" ]] || continue
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      b=${p##*/}; printf '%s\n' "${b%.md}"
    done < "$RUN/$l" >> "$STEMS" \
      || { echo "FAIL: could not read $RUN/$l — the gate cannot run (this is not a pass)." >&2; exit 2; }
  done
  awk -F'\t' -v label="$label" -v stems="$STEMS" -v plan="$DISP" '
    FILENAME == stems { have[$1] = 1; next }
    FILENAME == plan  { inplan[$1] = 1; next }
    NF >= 4 && $4 == "added" && $2 != "" && $3 != "" {
      if (!($3 in have)) {
        if ($3 in inplan)
          print "WARN: " $2 " (" label ") supersedes " $3 ", a stem the " label " source never collected — a cross-source supersede is a no-op; edge ignored, " $3 " is dispositioned on its own merits" > "/dev/stderr"
        next                                   # out of range for this source: informational
      }
      print $2 "\t" $3
    }
  ' "$STEMS" "$DISP" "$RUN/$ef" >> "$EDGES" \
    || { echo "FAIL: could not read $RUN/$ef — the gate cannot run (this is not a pass)." >&2; exit 2; }
}
# Stem-collision WARN: PLAN.md keys every source's files on the bare stem, so a
# basename two sources both shipped collapses to ONE plan row — and the
# same-source filter above then reads it as collected by both, so either source's
# edge could retire it. Rare (template stems are timestamp-prefixed; common/lib
# live under module dirs) but silent, so it is named here rather than left to
# be discovered from a wrong skip. Advisory: the gate's verdict is unchanged.
stem_collisions() {
  local src l p b
  for src in template:upgrades-added.txt:upgrades-modified.txt \
             common:common-upgrades-added.txt:common-upgrades-modified.txt \
             lib:lib-upgrades-added.txt:lib-upgrades-modified.txt; do
    IFS=: read -r label added modified <<< "$src"
    for l in "$added" "$modified"; do
      [[ -f "$RUN/$l" ]] || continue
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        b=${p##*/}; printf '%s\t%s\n' "${b%.md}" "$label"
      done < "$RUN/$l"
    done
  done | sort -u | awk -F'\t' '
    { n[$1]++; srcs[$1] = srcs[$1] (srcs[$1] == "" ? "" : ",") $2 }
    END { for (st in n) if (n[st] > 1)
      print "WARN: stem " st " was collected by more than one source (" srcs[st] ") — PLAN.md keys on the bare stem, so these collapse to one row and a supersede edge from either source can retire it; check the row by hand" > "/dev/stderr" }
  '
}
stem_collisions

collect_edges template upgrades-added.txt        upgrades-modified.txt        supersede-edges.tsv
collect_edges common   common-upgrades-added.txt common-upgrades-modified.txt common-supersede-edges.tsv
collect_edges lib      lib-upgrades-added.txt    lib-upgrades-modified.txt    lib-supersede-edges.tsv

# --- closure + enforcement -----------------------------------------------------
# A single awk: read dispositions first (present/applied/reason), then edges
# (adjacency + retirers), compute the retired closure by fixpoint from the
# applied set, and check every in-range retired slug.
FAILS=$(awk -F'\t' '
  FNR == NR {
    slug = $1; present[slug] = 1; disp[slug] = $2; reason[slug] = $3
    # A `deferred` placeholder must never survive to the gate — it means the
    # planner queued the superseded slug and never resolved it. Match by prefix
    # (mirroring the `^apply` test below): the disposition cell is the literal
    # word `deferred`, optionally trailed by a `(waits on <stem>)` note.
    if ($2 ~ /^deferred/) deferred[slug] = 1
    # "applied" for closure = any apply disposition, incl. `apply (tombstone)`
    # and an override apply. A tombstone counts for edge-firing though it lands
    # no Phase 7 task.
    if ($2 ~ /^apply/) applied[slug] = 1
    next
  }
  {
    S = $1; T = $2
    ei = ++ne; from[ei] = S; to[ei] = T
    # record every declared superseder of T, for reason-matching and messages
    retirers[T] = retirers[T] (retirers[T] == "" ? "" : " ") S
  }
  END {
    # Fixpoint: a superseder is "active" if it is applied or itself retired via
    # supersede. Reachability from the applied set over the edge list; a
    # decline-skip / not-applicable-skip node is neither applied nor retired, so
    # its chain is dead — exactly the PRD rule.
    changed = 1
    while (changed) {
      changed = 0
      for (i = 1; i <= ne; i++) {
        S = from[i]; T = to[i]
        if ((applied[S] || retired[S]) && !retired[T]) { retired[T] = 1; changed = 1 }
      }
    }
    rc = 0
    # deferred placeholders — any surviving one is a failure
    for (s in deferred) { print "DEFERRED: " s; rc = 1 }
    # every in-range (present in plan) retired slug must be skip-with-link or
    # apply-with-override
    for (s in retired) {
      if (!retired[s]) continue          # awk auto-vivifies keys merely referenced
                                         # in the fixpoint; skip those non-entries
      if (!present[s]) continue          # out of range — informational, not enforced
      ok = 0
      # `skip` by PREFIX, like `^apply` below: the planner writes parenthesised
      # cells for the sibling shapes (`skip (superseded — undeclared)`), so a
      # `skip (superseded)` with a correct linked reason must not false-red.
      if (disp[s] ~ /^skip/) {
        m = split(retirers[s], rs, " ")
        for (j = 1; j <= m; j++) {
          # Bounded match, not a substring test: "superseded by X" must not be
          # satisfied by a reason naming X2 (stem chars are [A-Za-z0-9._-], so
          # the stem must end at a character outside that set or at EOL).
          pat = rs[j]; gsub(/[.]/, "[.]", pat)
          if (reason[s] ~ ("superseded by " pat "([^A-Za-z0-9._-]|$)")) { ok = 1; break }
        }
      } else if (disp[s] ~ /^apply/ && reason[s] ~ /^override:/) {
        ok = 1
      }
      if (!ok) { print "UNRETIRED: " s " (retired by: " retirers[s] "; disposition: " disp[s] ")"; rc = 1 }
    }
    exit rc
  }
' "$DISP" "$EDGES"
) || {
  # awk exits 1 from END with the named violations on stdout; any other failure
  # (rc 2: unreadable input, a broken temp) names nothing, and an empty list must
  # not be presented as "violations" — nor, worse, be read as a pass.
  if [[ -z "$FAILS" ]]; then
    echo "FAIL: the supersede closure could not be computed — the gate cannot run (this is not a pass)." >&2
    exit 2
  fi
  echo "FAIL: the plan does not honor its supersede edges:" >&2
  printf '%s\n' "$FAILS" >&2
  exit 1
}

echo "OK: every superseded slug is dispositioned in $PLAN" >&2
