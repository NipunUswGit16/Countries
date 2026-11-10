#!/usr/bin/env bash
# codev-check.sh — print the local-path `replace` directives on the common-module
# prefix in a go.mod. Empty output = none. This is the mechanical primitive behind
# Phase 3.5's co-dev detection AND its wrong-target tripwire; the branching logic
# lives in phases/3.5-collect-common.md and wrong-target-check.sh, only this
# parse lives here.
#
# WHY `go mod edit -json` and not grep: block-form `replace (…)` groups carry the
# `replace` keyword only on the opening line, so a `grep '^…replace'` misses every
# inner directive. The JSON form flattens both single-line and block forms.
#
# A "local path" is a replacement target beginning with `./`, `../` or `/` —
# `go mod edit -replace mod=$(pwd)/../common`, the natural CLI spelling, writes an
# ABSOLUTE path and is the same co-dev signal as a relative one. A module path can
# never start with `/` (its first element must be a domain), so a leading `/` on
# the new-path side is always a filesystem checkout, never a versioned module.
#
# Env in:  COMMON_REPO_PATH   common-module import prefix, e.g. host/org/common (required)
#          GOMOD              go.mod path (optional; overridden by $1)
# Args:    $1                 go.mod path (optional; wins over $GOMOD)
# Stdout:  one "<oldpath> => <newpath>" line per local-path replace on the prefix
#          (nothing if there are none)
# Exit:    0  parsed (with or without matches)
#          2  go.mod path missing/unreadable, COMMON_REPO_PATH unset, `go` not on
#             PATH, or the parse pipeline failed (malformed go.mod, broken yq)
#
# WHY pipefail is load-bearing: `yq` exits 0 on EMPTY stdin, so without it a
# failing `go mod edit -json` (missing binary, unparseable go.mod) produced empty
# output at exit 0 — indistinguishable from "no co-development replaces", which
# silently disarms Phase 3.5's wrong-target tripwire. Silence must never read as
# a clean result.
set -u
set -o pipefail

# Explicit guard (not `${VAR:?}`, which exits 1): the header promises exit 2
# for every bad-input case, and callers distinguish "could not parse" from
# "parsed, no matches" by that code.
[[ -n "${COMMON_REPO_PATH:-}" ]] || { echo "FAIL: COMMON_REPO_PATH not set" >&2; exit 2; }
GOMOD="${1:-${GOMOD:-}}"
[[ -n "$GOMOD" ]] || { echo "FAIL: no go.mod path (arg or GOMOD)" >&2; exit 2; }
[[ -f "$GOMOD" ]] || { echo "FAIL: go.mod not found: $GOMOD" >&2; exit 2; }

# Probe `go` explicitly rather than leaning on pipefail alone: pipefail does
# surface the missing binary, but only as the shell's own "command not found".
# This is the earlier, cheaper failure and it names what to install.
command -v go >/dev/null 2>&1 \
  || { echo "FAIL: 'go' not found on PATH — cannot parse $GOMOD" >&2; exit 2; }

# The prefix is a PATH interpolated into a regex, so its metacharacters must be
# escaped or it matches too loosely — an unescaped `example.com/…` also matches a
# replace on `exampleXcom/…`, inventing a co-dev signal from an unrelated module.
# The doubled backslashes are deliberate: yq's double-quoted string eats one layer
# before the regex engine sees it (the same reason `^\\.{1,2}/` is written so).
COMMON_RE=$(printf '%s' "$COMMON_REPO_PATH" | sed 's/[][(){}.^$*+?|\\]/\\\\&/g')

# The `||` clause is what turns pipefail's status into the header's exit 2:
# pipefail reports the failing stage's own code (1 from `go mod edit`), and
# callers distinguish "could not parse" from "parsed, no matches" by the 2.
go mod edit -json "$GOMOD" \
  | yq -p=json -r '.Replace[]? | select(.Old.Path | test("^'"$COMMON_RE"'/")) | select(.New.Path | test("^(\\.{1,2}/|/)")) | .Old.Path + " => " + .New.Path' \
  || { echo "FAIL: could not parse $GOMOD (go mod edit / yq failed)" >&2; exit 2; }
