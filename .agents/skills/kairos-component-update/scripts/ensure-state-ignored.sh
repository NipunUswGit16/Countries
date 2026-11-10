#!/usr/bin/env bash
# ensure-state-ignored.sh — guarantee `.kairos/migration/state/` is gitignored in
# the component before anything is committed. Idempotent. Runs from the component
# work-tree root (operates on ./.gitignore).
#
# Two things happen here, in order:
#   1. Migrate a legacy broad `.kairos/migration/` ignore to the state-only pattern.
#      The broad form also hides the committed `.kairos/migration/PLAN.md`, and git
#      cannot re-include a file whose parent dir is ignored — so the broad ignore
#      must be narrowed, not merely supplemented.
#   2. Ensure `.kairos/migration/state/` itself is ignored, appending it if absent.
#
# WHY a literal grep, not `git check-ignore`: pre-flight already excluded the state
# dir locally via .git/info/exclude, so check-ignore is already satisfied and would
# skip writing the durable, committed entry every other developer needs.
#
# WHY the trailing-newline guard on append: a component .gitignore with no final
# newline would otherwise glue the new pattern onto its last line
# (e.g. `cmd/db-script-runner/Makefile.kairos/migration/state/`).
#
# Env in:  PHASE_KEY  required — proof-of-load key stated in phases/4-migration-branch.md
#          (nothing else — operates on ./.gitignore)
# Stdout:  "modified" if .gitignore was changed, "unchanged" otherwise
# Exit:    0  state dir is ignored (whether or not a change was needed)
#          1  PHASE_KEY missing/wrong, or .gitignore could not be written
#             (e.g. read-only file) — never reports "modified" in that case
set -u

# Phase-load guard: this key is stated ONLY in phases/4-migration-branch.md, so an
# orchestrator that skipped loading that file cannot know it. The guard turns a
# skipped load into a stop instead of a phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "m6dh2pjx" ]] \
  || { echo "FAIL: load phases/4-migration-branch.md first" >&2; exit 1; }

PATTERN='.kairos/migration/state/'
CHANGED=0

# 1. Migrate a legacy broad ignore to the state-only pattern. All four spellings
#    git treats as "ignore the whole .kairos/migration/ subtree" must be narrowed,
#    not just the slashless-with-trailing-slash one: a leading slash anchors to the
#    repo root (same tree, since we operate on the root .gitignore) and a missing
#    trailing slash still ignores the directory. Matching only `.kairos/migration/`
#    would leave `/.kairos/migration/` or `.kairos/migration` in place — still
#    hiding the committed PLAN.md — while the append below reports "modified".
#    (already_ignored() below already covers the leading-slash state spellings.)
if [[ -f .gitignore ]] && grep -qE '^/?\.kairos/migration/?$' .gitignore; then
  if sed -i.bak 's#^/\{0,1\}\.kairos/migration/\{0,1\}$#.kairos/migration/state/#' .gitignore; then
    rm -f .gitignore.bak
    CHANGED=1
  else
    rm -f .gitignore.bak
    echo "FAIL: could not write .gitignore (sed migration failed)" >&2
    exit 1
  fi
fi

# 2. Ensure the state-only pattern is present (with or without a trailing
#    slash, and with or without a leading slash — `/.kairos/migration/state/`
#    anchors to the repo root exactly like the slashless form here, since
#    ensure-state-ignored.sh always operates on the root .gitignore; the old
#    regex only recognized the slashless spelling, so an existing leading-
#    slash entry was invisible to it and every run re-appended a duplicate
#    while still reporting "modified" for a .gitignore that already had the
#    directory covered).
already_ignored() {
  grep -qxF '.kairos/migration/state' .gitignore 2>/dev/null \
    || grep -qxF '.kairos/migration/state/' .gitignore 2>/dev/null \
    || grep -qxF '/.kairos/migration/state' .gitignore 2>/dev/null \
    || grep -qxF '/.kairos/migration/state/' .gitignore 2>/dev/null
}
if ! already_ignored; then
  { [[ -s .gitignore ]] && [[ -n "$(tail -c1 .gitignore)" ]] && echo; echo "$PATTERN"; } >> .gitignore
  if [[ $? -eq 0 ]]; then
    CHANGED=1
  else
    echo "FAIL: could not write .gitignore (append failed)" >&2
    exit 1
  fi
fi

if [[ "$CHANGED" -eq 1 ]]; then echo "modified"; else echo "unchanged"; fi
