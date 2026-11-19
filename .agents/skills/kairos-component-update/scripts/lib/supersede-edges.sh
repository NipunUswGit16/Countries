#!/usr/bin/env bash
# lib/supersede-edges.sh — shared `supersedes:` edge emission for the three
# upgrade-file collectors (build-manifest.sh, collect-common.sh, collect-lib.sh).
# Sourced, never executed. Parsing the field and classifying each declared edge
# is identical across the sources; only the artifacts that feed it differ, so the
# logic lives here once and each collector builds the two input files from its own
# lists.
#
# supersede_emit <order_file> <list_file> <snap_dir> <edge_out>
#
#   order_file : "module <TAB> stem" — every ADDED upgrade-file, in apply
#                (commit) order. Line order within a module IS the apply order,
#                which is what the direction rule reads.
#   list_file  : "module <TAB> stem <TAB> kind" — every collected upgrade-file
#                (added ∪ modified); kind is `added` or `modified`. This is the
#                complete module map used to tell same-module from cross-module.
#   snap_dir   : holds each file's snapshot body at <stem>.md (the newest-in-range
#                body the collector already captured).
#   edge_out   : enforceable/informational rows are APPENDED here (the caller
#                truncates first). Row: module <TAB> superseder <TAB> superseded
#                <TAB> kind.
#
# Classification of each declared target T of a superseder S in module M:
#   - T == S                      → WARN (self-supersede), no row.
#   - T in a DIFFERENT module     → WARN (cross-module / cross-source no-op), no
#                                    row. The four sources have incomparable
#                                    ranges and separate collectors; a cross edge
#                                    would let one repo disable another's migration.
#   - T after S in M's apply order → WARN (forward edge), no row. A valid edge
#                                    points backwards, which also makes an
#                                    in-range supersede cycle impossible.
#   - T before S in M's apply order → emit (backward, enforceable).
#   - T not collected at all       → emit (out of range / never shipped —
#                                    informational; the gate ignores a target that
#                                    is absent from the plan, and distinguishing
#                                    out-of-range from never-shipped would need a
#                                    full-history walk the consumer does not do).
#   - S or T present but not in the ADDED apply order (a modified-list file) →
#                                    emit (advisory; the gate excludes modified-
#                                    list superseders from enforcement anyway).
#
#   - T is not a <timestamp>-<slug>  → WARN (malformed token: comma-joined list,
#                                    path, prose), no row.
#
# Only the HEADER is scanned: `supersedes:` lines after the first `## ` heading
# (the free-form body) are never declarations.
#
# All WARNs are non-fatal: a bad declaration is a dropped edge, never a corrupted
# collection.
#
# Return: 0 on success. Non-zero when the emission ITSELF failed (a temp file or
# the classification pass) — and then <edge_out> is REMOVED, not left behind: the
# caller truncated it before the call, so a failed pass would otherwise leave a
# present-and-empty (or partial) edge file that reads downstream as "no edges in
# range" — the exact false clean this feature exists to prevent. Absent, it trips
# supersede-check.sh's present-witness / absent-edge-file refusal (exit 2) instead.
# Callers must treat a non-zero return as a collection failure.
#
# The module column MUST be non-empty in both input files: an empty module is
# indistinguishable from "not collected anywhere", which would defeat the
# same-module / forward-edge classification, and a leading empty tab field would
# be collapsed by the tab-IFS read. Plain template runs pass the literal
# `template`; every other source already carries a real module name.
supersede_emit() {
  local order="$1" list="$2" snap="$3" out="$4"
  local decls; decls=$(mktemp "${TMPDIR:-/tmp}/supersede-decls.XXXXXX") \
    || { rm -f "$out"; echo "FAIL: supersede_emit could not create a temp file under ${TMPDIR:-/tmp}; removed $out rather than leave an empty edge file that reads as 'no supersedes in range'" >&2; return 1; }

  # Stage 1 — expand each file's `supersedes:` line(s) into one (S, target) row.
  # Mirror the requires-frontend extraction hygiene: strip CR and trailing space
  # (git show does no LF normalization), read EVERY supersedes: line, split on
  # whitespace, and normalize a stray `.md` off a token.
  # HEADER ONLY: the scan stops at the first `## ` heading (the `## Details` body
  # is free-form prose the executor reads, never a field block), so a column-0
  # "supersedes: …" sentence inside the body cannot manufacture an edge — and an
  # edge is a skip that rides without per-item confirmation, so a false one is
  # exactly the silent retirement this feature must not produce.
  # A token that is not a <timestamp>-<slug> stem (a comma-joined list, a path)
  # is WARNed and dropped rather than emitted as an "out of range" row: that row
  # would read as a legitimately-absent target and the author's real intent
  # would be lost without a trace.
  local mod stem kind body line tok
  while IFS=$'\t' read -r mod stem kind; do
    [[ -n "$stem" ]] || continue
    body="$snap/$stem.md"
    [[ -f "$body" ]] || continue
    awk '/^## / { exit } /^supersedes:/' "$body" 2>/dev/null | while IFS= read -r line; do
      line=$(printf '%s' "$line" | tr -d '\r' | sed -E 's/^supersedes:[[:space:]]*//; s/[[:space:]]+$//')
      for tok in $line; do
        tok=${tok%.md}
        [[ -n "$tok" ]] || continue
        case "$tok" in
          [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]-*)
            if printf '%s' "$tok" | grep -qE '^[0-9]{8}T[0-9]{6}-[A-Za-z0-9._-]+$'; then
              printf '%s\t%s\t%s\t%s\n' "$mod" "$stem" "$kind" "$tok"
              continue
            fi ;;
        esac
        echo "WARN: $stem declares supersedes: '$tok', which is not a <timestamp>-<slug> stem (space-separated bare stems, no path, no comma) — ignored, no edge recorded" >&2
      done
    done
  done < "$list" > "$decls"

  # Stage 2 — build the module map + apply-order index, then classify each target.
  awk -F'\t' -v order="$order" -v list="$list" -v out="$out" '
    FILENAME == order { pos[$1 SUBSEP $2] = ++ocount[$1]; next }
    # Membership is per module+stem, not stem-only: an identical basename in two
    # modules must not collapse to a single first-seen module, or a legit
    # same-module backward edge gets misread as cross-module and dropped.
    FILENAME == list  { seen[$2] = 1; inmod[$1 SUBSEP $2] = 1; next }
    # decls: mod=$1 S=$2 kind=$3 T=$4
    {
      M = $1; S = $2; kind = $3; T = $4
      if (T == S) { print "WARN: supersedes: names the file itself (" S ") — ignored" > "/dev/stderr"; next }
      if (!(T in seen)) {                          # not collected anywhere → out of range
        print M "\t" S "\t" T "\t" kind >> out; next
      }
      if (!((M SUBSEP T) in inmod)) {              # seen, but not in M → cross-module no-op
        print "WARN: " S " supersedes " T " across modules — ignored; supersede is same-source, same-module only" > "/dev/stderr"; next
      }
      sk = (M SUBSEP S) in pos
      tk = (M SUBSEP T) in pos
      if (sk && tk) {
        if (pos[M SUBSEP T] < pos[M SUBSEP S]) { print M "\t" S "\t" T "\t" kind >> out; next }
        if (pos[M SUBSEP T] > pos[M SUBSEP S]) { print "WARN: " S " supersedes " T " which lands LATER in apply order (forward edge) — ignored" > "/dev/stderr"; next }
        next                                       # equal position: same file, already handled
      }
      # S or T is a modified-list file with no apply-order slot → advisory edge
      print M "\t" S "\t" T "\t" kind >> out
    }
  ' "$order" "$list" "$decls"
  local rc=$?
  rm -f "$decls"
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$out"
    echo "FAIL: supersede edge classification failed (awk rc=$rc) while writing $out — removed the partial edge file rather than leave one that reads as 'no supersedes in range'" >&2
    return 1
  fi
  return 0
}
