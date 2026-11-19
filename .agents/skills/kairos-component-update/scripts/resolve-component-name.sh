#!/usr/bin/env bash
# resolve-component-name.sh — the component identity used when bootstrapping
# `.kairos/manifest.yaml` `name:`.
#
# WHY this script exists: Phase 2's bootstrap used to interpolate
# NAME="<component-name>" from prose that said "the directory basename unless
# the user says otherwise". The git repo / checkout directory is often a
# different identifier (repo `kairos-todo-demo` vs component `todo-demo`), and
# that wrong NAME was then substituted into every `<YOUR_COMPONENT_NAME>` token
# for the rest of the migration. The template's well-known identity is
# `pkg/schema/globals.go` `const ComponentName` — the same string every
# command/event returns from `ComponentName()`, and what create-time
# substitution writes over `YOUR_COMPONENT_NAME`.
#
# WHY it does not look anywhere else: Chart.yaml (`bundle-<name>`), go.mod's last
# segment, imageRepository, and the directory basename all disagree with
# schema.ComponentName often enough to be guesses (repo `kairos-todo-demo` vs
# component `todo-demo`). A guess written into the founding manifest poisons
# every later substitution. Missing file, placeholder, or unparseable
# assignment is therefore a stop; the caller asks the user and passes NAME=.
#
# Env in:  PHASE_KEY  required — proof-of-load key stated in phases/2-resolve-target.md
# Cwd:     component work-tree root
# Stdout:  the ComponentName string, one line, no decoration
# Stderr:  INFO naming the source; WARN when the directory basename disagrees
# Exit:    0 done
#          1 PHASE_KEY missing/wrong
#          2 no/unreadable globals.go, placeholder still in place, or unparseable
set -u

[[ "${PHASE_KEY:-}" = "k3wq8vfr" ]] \
  || { echo "FAIL: load phases/2-resolve-target.md first" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 2; }

GLOBALS=pkg/schema/globals.go
[[ -f "$GLOBALS" ]] \
  || fail "no $GLOBALS — that file is the template's component identity (const ComponentName). Ask the user; never use the directory basename."

# First assignment only. Comments and later mentions (tests, docs) must not win.
line=$(grep -E '^[[:space:]]*const[[:space:]]+ComponentName[[:space:]]*=' "$GLOBALS" | head -1) \
  || true
[[ -n "${line:-}" ]] \
  || fail "$GLOBALS has no 'const ComponentName =' assignment"

name=$(printf '%s\n' "$line" | sed -n 's/.*const[[:space:]]*ComponentName[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')
[[ -n "$name" ]] \
  || fail "$GLOBALS ComponentName is not a double-quoted string"

case "$name" in
  YOUR_COMPONENT_NAME|"<YOUR_COMPONENT_NAME>")
    fail "$GLOBALS still holds the template placeholder '$name' — this is not a created component. Ask the user for the component name; never use the directory basename." ;;
esac

dir=$(basename "$(pwd)")
echo "INFO: component name '$name' from $GLOBALS" >&2
if [[ "$name" != "$dir" ]]; then
  echo "WARN: directory basename is '$dir' — using schema.ComponentName, not the repo/directory name" >&2
fi
printf '%s\n' "$name"
