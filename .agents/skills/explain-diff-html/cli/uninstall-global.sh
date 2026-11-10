#!/usr/bin/env bash
# Remove the machine-wide explain-diff symlink if it points at this skill (or any pack copy).
set -euo pipefail

BIN_DIR="${EXPLAIN_DIFF_BIN_DIR:-$HOME/.local/bin}"
ARCHIVE="${EXPLAIN_DIFF_DIR:-$HOME/.local/share/explain-diff}"
LINK="$BIN_DIR/explain-diff"

if [[ ! -e "$LINK" ]] && [[ ! -L "$LINK" ]]; then
  echo "nothing to remove: $LINK"
  exit 0
fi

if [[ ! -L "$LINK" ]]; then
  echo "skip (not a symlink): $LINK" >&2
  exit 1
fi

target="$(readlink "$LINK")"
case "$target" in
  /*) ;;
  *) target="$(cd "$(dirname "$LINK")" && cd "$(dirname "$target")" && pwd)/$(basename "$target")" ;;
esac

case "$target" in
  */explain-diff-html/cli/explain-diff)
    rm "$LINK"
    echo "removed: $LINK"
    ;;
  *)
    echo "skip (points elsewhere: $target): $LINK" >&2
    exit 1
    ;;
esac

if [[ -f "$ARCHIVE/skill-root" ]]; then
  rm -f "$ARCHIVE/skill-root"
fi
