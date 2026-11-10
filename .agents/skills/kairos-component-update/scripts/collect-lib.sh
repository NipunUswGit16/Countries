#!/usr/bin/env bash
# collect-lib.sh — collect kind:library upgrade-files over a frontend
# BASE..TARGET SHA range. Same-repo, SHA-range, no tree-diff.
#
# Lib is a DEPENDENCY, never merged into the component (unlike kind:template).
# Its range IS the frontend run's BASE..TARGET — Model A, no go.mod /
# package.json version parsing. Collection is by git-commit order within that
# range. An upgrade-file need only be committed somewhere in range.
#
# This script is the other half of Phase 3's frontend arm. It must never be
# independently stamped, cached, or skipped relative to build-manifest.sh:
# SNAP_SOURCES is truncated whole at the top of Phase 3, so lib's source rows
# survive a redo only because this script re-runs immediately after and
# re-appends them. Any Phase 3 redo (including Phase 5's no-binding remedy)
# re-runs both as one unit.
#
# WHY a template-run invocation records NOTHING (not even `none`): LIB_MODULES
# is the inverse of COMMON_MODULES. An eagerly-armed LIB_MODULES=present on a
# template run deadlocks Phase 6's plan-completeness.sh against a collection
# that correctly never runs. Absence of the key IS the template-run record
# (SKILL.md — legitimately absent keys).
#
# Env in:
#   PHASE_KEY  required — same key as build-manifest.sh (phases/3-classify.md),
#              because the two are one atomic re-run unit of that phase
#   RUN        output dir (required)
#   CACHE      frontend mirror (required)
#   BASE       baseline frontend SHA (required)
#   TARGET     target frontend SHA (required)
# Out (in $RUN):
#   lib-upgrades-added.txt      collected identities, per-module commit order,
#                               RAW path bytes (every walk reads -z; a TAB or
#                               newline in a name is a hard stop naming the file)
#   lib-upgrades-added.tsv      add-sha <TAB> module <TAB> path
#   lib-upgrades-modified.txt   files that existed before BASE and were amended
#                               in range (not (re)discovered as an add)
#   upgrades/<basename>.md      body, from the newest add or amend commit —
#                               shared with template collection
#   LIB_MODULES=present|none    on $RUN/context.env — present when the source
#                               config.yaml at TARGET declares ≥1 kind:library
#                               module (empty-but-present lists answer "none in
#                               range"); none when it declares zero
set -u

fail() { echo "FAIL: $*" >&2; exit 1; }

# Phase-load guard: this key is stated ONLY in phases/3-classify.md. Same key as
# build-manifest.sh — the two are one atomic re-run unit of that phase.
[[ "${PHASE_KEY:-}" = "i82l699l" ]] || fail "load phases/3-classify.md first"

for v in RUN CACHE BASE TARGET; do
  [[ -n "${!v:-}" ]] || fail "$v not set"
done

HERE=$(cd "$(dirname "$0")" && pwd)

# A template-run (or a call with no RUN_SOURCE) records NOTHING. Absence of
# LIB_MODULES is the template-run record; writing `none` here would be a
# different claim ("we looked and there were no library modules") that a
# template-run resume would then treat as settled.
RUN_SOURCE=""
[[ -f "$RUN/context.env" ]] \
  && RUN_SOURCE=$(sed -n 's/^RUN_SOURCE=//p' "$RUN/context.env" | tail -1 | tr -d '\r')
if [[ "$RUN_SOURCE" != frontend ]]; then
  echo "INFO: not applicable — collect-lib.sh runs only on a frontend run (RUN_SOURCE=frontend); this invocation is ${RUN_SOURCE:-<unset>}. Recorded nothing (LIB_MODULES stays absent, which is the template-run record)." >&2
  exit 0
fi

command -v yq >/dev/null 2>&1 || fail "required tool 'yq' not found on PATH."

[[ -r "$HERE/lib/snap-upgrade.sh" ]] \
  || fail "missing $HERE/lib/snap-upgrade.sh — it owns snap_upgrade (story 42)"
[[ -r "$HERE/lib/z-log-name-only.sh" ]] \
  || fail "missing $HERE/lib/z-log-name-only.sh — it owns z_log_name_only (story 42)"
# shellcheck source=lib/snap-upgrade.sh
. "$HERE/lib/snap-upgrade.sh" \
  || fail "could not source $HERE/lib/snap-upgrade.sh"
# shellcheck source=lib/z-log-name-only.sh
. "$HERE/lib/z-log-name-only.sh" \
  || fail "could not source $HERE/lib/z-log-name-only.sh"
command -v snap_upgrade >/dev/null 2>&1 \
  || fail "lib/snap-upgrade.sh defined no snap_upgrade"
command -v z_log_name_only >/dev/null 2>&1 \
  || fail "lib/z-log-name-only.sh defined no z_log_name_only"
[[ -r "$HERE/lib/supersede-edges.sh" ]] \
  || fail "missing $HERE/lib/supersede-edges.sh — it owns supersede_emit"
# shellcheck source=lib/supersede-edges.sh
. "$HERE/lib/supersede-edges.sh" \
  || fail "could not source $HERE/lib/supersede-edges.sh"

mkdir -p "$RUN/upgrades" \
  || fail "cannot create the snapshot dir $RUN/upgrades — is $RUN writable and is there no non-directory in the way?"
: > "$RUN/lib-upgrades-added.txt" \
  || fail "cannot truncate $RUN/lib-upgrades-added.txt — refusing to collect over a stale list (is $RUN writable?)"
: > "$RUN/lib-upgrades-added.tsv" \
  || fail "cannot truncate $RUN/lib-upgrades-added.tsv — refusing to collect over a stale list (is $RUN writable?)"
: > "$RUN/lib-upgrades-modified.txt" \
  || fail "cannot truncate $RUN/lib-upgrades-modified.txt — refusing to collect over a stale list (is $RUN writable?)"
# The supersede edge file is this collector's OWN artifact — a plain checked
# truncate is safe. Truncated HERE, alongside the added list and before the
# LIB_MODULES=none early exit below, so the edge file exists (empty) whenever its
# added-list witness does; otherwise supersede-check.sh's present-witness /
# absent-edge-file guard would exit 2 on a none run.
: > "$RUN/lib-supersede-edges.tsv" \
  || fail "cannot truncate $RUN/lib-supersede-edges.tsv — refusing to collect over a stale edge file (is $RUN writable?)"

# Enumerate kind:library modules from the source config.yaml at TARGET. A
# missing or unreadable config is "no library modules" (LIB_MODULES=none), never
# a silent collect-from-nothing: an older frontend repo that does not
# self-describe cannot declare a library module.
CFG=.kairos-updates/config.yaml
LIB_MODS=""
if git -C "$CACHE" cat-file -e "$TARGET:$CFG" 2>/dev/null; then
  # The config EXISTS at TARGET. Capture yq's OWN exit status rather than folding a
  # failure into an empty result: a wrong-flavor yq (a jq-wrapper "yq" that does not
  # speak this mikefarah expression) or a genuine YAML parse error would otherwise
  # yield "" and be reported as LIB_MODULES=none — silently dropping the whole library
  # upgrade set for a repo that DOES declare library modules. yq-said-none (valid YAML,
  # zero kind:library modules) is a legitimate none; yq-failed is a WARN that tells the
  # none apart from a real parse/read failure.
  libtmp=$(mktemp "${TMPDIR:-/tmp}/collect-lib-cfg.XXXXXX") \
    || fail "could not create a temp file to read $CFG at TARGET"
  if git -C "$CACHE" show "$TARGET:$CFG" 2>/dev/null \
       | yq -r '.modules | to_entries[] | select(.value.kind=="library") | .key' - > "$libtmp" 2>/dev/null; then
    LIB_MODS=$(cat "$libtmp")
  else
    echo "WARN: $CFG exists at TARGET but could not be read for kind:library modules — treating as none. Check that 'yq' is the mikefarah build (a jq-wrapper yq rejects this expression) and that the config is valid YAML; a real parse/read failure here silently drops the library upgrade set." >&2
  fi
  rm -f "$libtmp"
fi

if [[ -z "$(printf '%s' "$LIB_MODS" | awk 'NF')" ]]; then
  echo "LIB_MODULES=none"
  RUN="$RUN" "$HERE/record-context.sh" "LIB_MODULES=none"
  echo "INFO: no kind:library modules declared in $CFG at TARGET — nothing to collect." >&2
  exit 0
fi

# LIB_MODULES=present is NOT recorded here — it is written only AFTER the collection
# walk and its refusal checks succeed (below, before the final OK echo). Persisting
# `present` now would arm plan-completeness.sh while the upgrade lists are still empty;
# an interruption between here and the walk would then leave present+empty lists, and a
# frontend resume — reading present as "already collected" — would drop the entire lib
# upgrade set silently. `present` records the completed collection, never the intent.

# Snapshots land in the SHARED $RUN/upgrades/ dir keyed by BASENAME only.
# Re-run idempotence, shared-file variant: build-manifest.sh truncates
# SNAP_SOURCES at its Phase 3 write; this script appends. Drop only OUR rows —
# source id "<module>:.kairos-updates/…", the same shape common uses.
# The ^[^:]+:\.kairos-updates/ shape is shared by common and lib and is safe
# only because their RUN_SOURCEs are disjoint (one $RUN ledger only ever holds
# one of the two).
SNAP_SOURCES="$RUN/upgrade-snapshot-sources.tsv"
if [[ -f "$SNAP_SOURCES" ]]; then
  snaptmp=$(mktemp "${TMPDIR:-/tmp}/snap-sources.XXXXXX") \
    || fail "could not create a temp file to prune $SNAP_SOURCES"
  if ! awk -F'\t' '$2 !~ /^[^:]+:\.kairos-updates\//' "$SNAP_SOURCES" > "$snaptmp"; then
    rm -f "$snaptmp"
    fail "could not prune this run's own rows from $SNAP_SOURCES — a stale source row left here makes the basename-collision WARN fire against our own previous run."
  fi
  mv "$snaptmp" "$SNAP_SOURCES" \
    || { rm -f "$snaptmp"; fail "could not replace $SNAP_SOURCES with its pruned copy — check that $RUN is writable."; }
fi

SNAP_REFUSALS="$RUN/snapshot-refusals.tsv"
if [[ -f "$SNAP_REFUSALS" ]]; then
  reftmp=$(mktemp "${TMPDIR:-/tmp}/snap-refusals.XXXXXX") \
    || fail "could not create a temp file to prune $SNAP_REFUSALS"
  # The ^[^:]+:\.kairos-updates/ shape is shared by common and lib and is safe
  # only because their RUN_SOURCEs are disjoint (one $RUN ledger only ever holds
  # one of the two).
  if ! awk -F'\t' '$2 !~ /^[^:]+:\.kairos-updates\//' "$SNAP_REFUSALS" > "$reftmp"; then
    rm -f "$reftmp"
    fail "could not prune this run's own rows from $SNAP_REFUSALS — a stale refusal row left here makes next-upgrade-file.sh answer exit 5 for a slug this run never refused."
  fi
  mv "$reftmp" "$SNAP_REFUSALS" \
    || { rm -f "$reftmp"; fail "could not replace $SNAP_REFUSALS with its pruned copy — check that $RUN is writable."; }
else
  : > "$SNAP_REFUSALS" \
    || fail "could not create $SNAP_REFUSALS — check that $RUN is writable."
fi

TABCH=$'\t'
NLCH=$'\n'

LIB_BAD="$RUN/.lib-upgrades-badnames.txt"
: > "$LIB_BAD" || fail "cannot truncate $LIB_BAD — is $RUN writable?"
LIB_STRAY="$RUN/.lib-upgrades-strayrecords.txt"
: > "$LIB_STRAY" || fail "cannot truncate $LIB_STRAY — is $RUN writable?"
LIB_WALKFAIL="$RUN/.lib-walk-failures.txt"
: > "$LIB_WALKFAIL" || fail "cannot truncate $LIB_WALKFAIL — is $RUN writable?"

# Refusals here MUST NOT tear down classification.tsv — that coupling is why
# this walk lives in its own script instead of behind a shared signature.
lib_refuse_stray() { # lib_refuse_stray <which-walk>
  [[ -s "$LIB_STRAY" ]] || return 0
  : > "$RUN/lib-upgrades-added.txt"
  : > "$RUN/lib-upgrades-added.tsv"
  : > "$RUN/lib-upgrades-modified.txt"
  echo "FAIL: $1 emitted output this phase cannot parse — record(s) that belong to no commit:" >&2
  sed 's/^/        /' "$LIB_STRAY" >&2
  echo "      Each upgrade-file path has to be attributed to the commit that introduced it," >&2
  echo "      and these records arrived before any 'commit <sha>' header, so the walk's own" >&2
  echo "      output is carrying text that is not part of the log. Continuing would drop" >&2
  echo "      those records — i.e. skip migration steps a library module ships — and report" >&2
  echo "      success." >&2
  echo "      Most likely cause: git config that writes to 'git log' STDOUT (e.g." >&2
  echo "      log.showSignature=true against signed frontend commits). This phase already" >&2
  echo "      passes --no-show-signature, so check \`git -C $CACHE config --list\` for other" >&2
  echo "      output-injecting log.* settings, unset it for the mirror, and re-run this phase." >&2
  exit 1
}
lib_refuse_badnames() {
  [[ -s "$LIB_BAD" ]] || return 0
  : > "$RUN/lib-upgrades-added.txt"
  : > "$RUN/lib-upgrades-added.tsv"
  : > "$RUN/lib-upgrades-modified.txt"
  echo "FAIL: a library module carries upgrade-file name(s) this migration cannot represent:" >&2
  sed 's/^/        /' "$LIB_BAD" >&2
  echo "      A TAB or a newline in a filename cannot ride \$RUN/lib-upgrades-added.txt (a line" >&2
  echo "      list) or \$RUN/lib-upgrades-added.tsv (a TAB-delimited line record), and dropping" >&2
  echo "      it silently would skip a migration step a library module ships. Nothing in this" >&2
  echo "      phase can work around the name, so repeating the phase cannot clear this." >&2
  echo "      Remedy: rename the upgrade-file in the frontend source to drop the TAB/newline," >&2
  echo "      then re-run this phase (build-manifest.sh AND collect-lib.sh as one unit)." >&2
  exit 1
}
lib_refuse_walk() {
  [[ -s "$LIB_WALKFAIL" ]] || return 0
  : > "$RUN/lib-upgrades-added.txt"
  : > "$RUN/lib-upgrades-added.tsv"
  : > "$RUN/lib-upgrades-modified.txt"
  echo "FAIL: a library-module upgrade-file walk failed — refusing to report a partial upgrade set:" >&2
  while IFS="$TABCH" read -r m stage; do
    echo "        $m: $stage" >&2
  done < "$LIB_WALKFAIL"
  echo "      That walk is how this phase discovers the migration steps a library" >&2
  echo "      module ships, so continuing would report an EMPTY or PARTIAL upgrade-file" >&2
  echo "      set as success and skip those steps silently (see git's error above)." >&2
  echo "      Remedy: repair the frontend mirror (re-fetch \$CACHE), or correct BASE/TARGET," >&2
  echo "      then re-run this phase (build-manifest.sh AND collect-lib.sh as one unit)." >&2
  exit 1
}

# Per-module ADD then MODIFY, over the run's existing BASE..TARGET. No $SYNTH,
# no classification, no version-range resolver. Here-doc, not a pipe: a
# `printf | while` subshell would make `fail`/`exit` inside the loop a no-op.
: > "$RUN/.lib-modbody-all.tsv" \
  || fail "cannot truncate $RUN/.lib-modbody-all.tsv — is $RUN writable?"
while IFS= read -r module; do
  [[ -n "$module" ]] || continue
  dir=".kairos-updates/$module/"

  addz=$(mktemp "${TMPDIR:-/tmp}/collect-lib-addz.XXXXXX") \
    || fail "could not create a temp file for the $module ADD walk"
  if ! git -C "$CACHE" log --no-show-signature --reverse --topo-order --diff-filter=A --name-only -z \
      --pretty=format:'commit %H' "$BASE..$TARGET" -- "$dir" > "$addz"; then
    printf '%s%s%s\n' "$module" "$TABCH" "the add-pass walk (--diff-filter=A)" >> "$LIB_WALKFAIL"
    rm -f "$addz"
    continue
  fi
  addtsv=$(mktemp "${TMPDIR:-/tmp}/collect-lib-addtsv.XXXXXX") \
    || { rm -f "$addz"; fail "could not create a temp file for the $module ADD conversion"; }
  z_log_name_only "$LIB_BAD" "$LIB_STRAY" < "$addz" > "$addtsv"
  rm -f "$addz"
  UPG_DIR="$dir" awk -F'\t' -v mod="$module" \
        -v txt="$RUN/lib-upgrades-added.txt" -v tsv="$RUN/lib-upgrades-added.tsv" '
      BEGIN { dir = ENVIRON["UPG_DIR"] }
      substr($2, 1, length(dir)) == dir && length($2) > length(dir) {
        if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2; print $2 >> txt }
        latest[$2] = $1
      }
      END { for (i = 1; i <= n; i++) print latest[order[i]] "\t" mod "\t" order[i] >> tsv }
    ' "$addtsv" \
    || { rm -f "$addtsv"; printf '%s%s%s\n' "$module" "$TABCH" "the add-pass conversion/write (--diff-filter=A)" >> "$LIB_WALKFAIL"; continue; }
  rm -f "$addtsv"

  modz=$(mktemp "${TMPDIR:-/tmp}/collect-lib-modz.XXXXXX") \
    || fail "could not create a temp file for the $module MODIFIED-list walk"
  if ! git -C "$CACHE" log --no-show-signature --reverse --topo-order --diff-filter=M --name-only -z \
      --pretty=format:'commit %H' "$BASE..$TARGET" -- "$dir" > "$modz"; then
    printf '%s%s%s\n' "$module" "$TABCH" "the modified-list walk (--diff-filter=M)" >> "$LIB_WALKFAIL"
    rm -f "$modz"
    continue
  fi
  modtsv=$(mktemp "${TMPDIR:-/tmp}/collect-lib-modtsv.XXXXXX") \
    || { rm -f "$modz"; fail "could not create a temp file for the $module MODIFIED conversion"; }
  z_log_name_only "$LIB_BAD" "$LIB_STRAY" < "$modz" > "$modtsv"
  rm -f "$modz"
  UPG_DIR="$dir" awk -F'\t' -v added="$RUN/lib-upgrades-added.txt" \
        -v txt="$RUN/lib-upgrades-modified.txt" '
      BEGIN { dir = ENVIRON["UPG_DIR"]; while ((getline a < added) > 0) skip[a] = 1 }
      substr($2, 1, length(dir)) == dir && length($2) > length(dir) {
        if (!($2 in skip) && !seen[$2]++) print $2 >> txt
      }
    ' "$modtsv" \
    || { rm -f "$modtsv"; printf '%s%s%s\n' "$module" "$TABCH" "the modified-list conversion/write (--diff-filter=M)" >> "$LIB_WALKFAIL"; continue; }
  rm -f "$modtsv"

  # NOT --reverse: `!seen[$2]++` then keeps the NEWEST amending commit per path,
  # matching build-manifest.sh. Provenance is the library module name, not a
  # flat `lib`, so N library modules scale unchanged.
  if ! git -C "$CACHE" log --no-show-signature --topo-order --diff-filter=M --name-only -z \
      --pretty=format:'commit %H' "$BASE..$TARGET" -- "$dir" \
    > "$RUN/.lib-modbody.z"; then
    printf '%s%s%s\n' "$module" "$TABCH" "the modified-body walk (--diff-filter=M, newest-first)" >> "$LIB_WALKFAIL"
    continue
  fi
  z_log_name_only "$LIB_BAD" "$LIB_STRAY" < "$RUN/.lib-modbody.z" > "$RUN/.lib-modbody.tsv"
  rm -f "$RUN/.lib-modbody.z"
  UPG_DIR="$dir" awk -F'\t' -v mod="$module" -v out="$RUN/.lib-modbody-all.tsv" '
      BEGIN { dir = ENVIRON["UPG_DIR"] }
      substr($2, 1, length(dir)) == dir && length($2) > length(dir) {
        if (!seen[$2]++) print $1 "\t" mod "\t" $2 >> out
      }
    ' "$RUN/.lib-modbody.tsv" \
    || { printf '%s%s%s\n' "$module" "$TABCH" "the modified-body conversion (--diff-filter=M)" >> "$LIB_WALKFAIL"; rm -f "$RUN/.lib-modbody.tsv"; continue; }
  rm -f "$RUN/.lib-modbody.tsv"
done <<EOF
$LIB_MODS
EOF

lib_refuse_walk
lib_refuse_badnames
lib_refuse_stray "a library-module upgrade-file walk"

# The walk completed and every refusal check passed: the upgrade lists are now
# populated and valid, so it is finally safe to record LIB_MODULES=present. Writing it
# here (not before the walk) is the defense against a silent lib-set drop on resume: an
# interruption at any earlier point leaves LIB_MODULES ABSENT — which continue.md's
# frontend arm re-collects unconditionally — rather than present-with-empty-lists, which
# a resume would read as "already collected: none".
echo "LIB_MODULES=present"
RUN="$RUN" "$HERE/record-context.sh" "LIB_MODULES=present"

# Added-pass bodies first, then modified-pass overwrite (an M-event is newer).
# Same-source overwrite is silent by design; a basename collision with a
# template file WARNs inside snap_upgrade.
while IFS=$'\t' read -r sha module path; do
  [[ -n "${path:-}" ]] || continue
  snap_upgrade "$CACHE" "$sha:$path" "$module:$path" "$(basename "$path")" || true
done < "$RUN/lib-upgrades-added.tsv"
while IFS=$'\t' read -r sha module path; do
  [[ -n "${path:-}" ]] || continue
  snap_upgrade "$CACHE" "$sha:$path" "$module:$path" "$(basename "$path")" || true
done < "$RUN/.lib-modbody-all.tsv"
rm -f "$RUN/.lib-modbody-all.tsv"

# --- supersede edges ----------------------------------------------------------
# Same shape as collect-common: order = added list in apply order (module col2,
# path col3), list = added ∪ modified with kind. Modified-list modules come from
# the .kairos-updates/<module>/ path segment.
# Every step is CHECKED, and any failure REMOVES the edge file (the helper does
# the same for its own failures): an empty lib-supersede-edges.tsv reads as "no
# supersedes in range" to supersede-check.sh, so a silently failed build here
# would let a plan ship with a retired lib slug unskipped. Absent, the gate
# refuses (exit 2) and names this collector instead.
{
  cl_fail() { rm -f "${cl_order:-}" "${cl_list:-}" "$RUN/lib-supersede-edges.tsv"; fail "$* — lib-supersede-edges.tsv removed rather than left empty (an empty edge file reads as 'no supersedes in range'). Check that ${TMPDIR:-/tmp} and $RUN are writable, then re-run the Phase 3 frontend arm."; }
  cl_order=$(mktemp "${TMPDIR:-/tmp}/cl-order.XXXXXX") || cl_fail "could not create a temp file for the supersede apply-order list"
  cl_list=$(mktemp "${TMPDIR:-/tmp}/cl-list.XXXXXX")   || cl_fail "could not create a temp file for the supersede module map"
  awk -F'\t' '{ stem=$3; sub(/.*\//,"",stem); sub(/\.md$/,"",stem); print $2"\t"stem }' \
    "$RUN/lib-upgrades-added.tsv" > "$cl_order" || cl_fail "could not build the supersede apply-order list from lib-upgrades-added.tsv"
  awk -F'\t' '{ print $1"\t"$2"\tadded" }' "$cl_order" > "$cl_list" || cl_fail "could not build the supersede module map"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    m=${path#*.kairos-updates/}; m=${m%%/*}
    b=${path##*/}; stem=${b%.md}
    printf '%s\t%s\tmodified\n' "$m" "$stem" >> "$cl_list"
  done < "$RUN/lib-upgrades-modified.txt" || cl_fail "could not add the modified list to the supersede module map"
  supersede_emit "$cl_order" "$cl_list" "$RUN/upgrades" "$RUN/lib-supersede-edges.tsv" \
    || cl_fail "supersede edge emission failed"
  rm -f "$cl_order" "$cl_list"
}

echo "OK: lib upgrade-files collected ($RUN/lib-upgrades-added.txt)" >&2
