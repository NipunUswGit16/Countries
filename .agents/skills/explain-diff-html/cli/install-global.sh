#!/usr/bin/env bash
# Put explain-diff on PATH (XDG). Safe to re-run; retargets the symlink.
# Does not install the skill into ~/.claude or ~/.cursor — only the CLI.
set -euo pipefail

CLI_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="$CLI_DIR/explain-diff"
SKILL_DIR="$(cd "$CLI_DIR/.." && pwd)"
BIN_DIR="${EXPLAIN_DIFF_BIN_DIR:-$HOME/.local/bin}"
ARCHIVE="${EXPLAIN_DIFF_DIR:-$HOME/.local/share/explain-diff}"

if [[ ! -f "$CLI" ]]; then
  echo "error: CLI missing at $CLI" >&2
  exit 1
fi
if [[ ! -f "$SKILL_DIR/ask/serve.py" ]]; then
  echo "error: skill root looks wrong: $SKILL_DIR (no ask/serve.py)" >&2
  exit 1
fi

chmod +x "$CLI"
mkdir -p "$BIN_DIR" "$ARCHIVE"
ln -sfn "$CLI" "$BIN_DIR/explain-diff"
printf '%s\n' "$SKILL_DIR" > "$ARCHIVE/skill-root"

echo "linked:  $BIN_DIR/explain-diff -> $CLI"
echo "archive: $ARCHIVE"
echo "skill:   $SKILL_DIR"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "warning: $BIN_DIR is not on PATH — add it to use \`explain-diff\` in a new shell" >&2
    ;;
esac
