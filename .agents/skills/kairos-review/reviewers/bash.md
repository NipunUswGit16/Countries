# Bash / Shell Reviewer Rules

Apply only to `.sh`, `.bash` files, and scripts with a shell shebang (`#!/bin/bash`, `#!/bin/sh`, `#!/usr/bin/env bash`). Report only demonstrably real bugs or production risks.

**Each bullet below is an anti-pattern. Flag any code in the diff that matches.** The section header is the category for the finding.

## SAFETY_FLAGS

- Script missing `set -e` (or `set -o errexit`) — any failing command is silently ignored and the script continues; partial state changes can leave the system broken
- Script missing `set -u` (or `set -o nounset`) — unset variables expand to empty string silently; `rm -rf $DIR/` becomes `rm -rf /` if `DIR` is unset
- Script missing `set -o pipefail` — the exit code of a pipeline is the last command's exit code; earlier failures in `cmd1 | cmd2` are silently swallowed
- `set -e` used without understanding that it does not apply inside `if`, `while`, `||`, `&&` conditions — false sense of safety

## QUOTING

- Unquoted variable in a command: `rm $FILE` instead of `rm "$FILE"` — word splitting and glob expansion on the value; breaks on paths with spaces or special characters
- Unquoted variable in a test: `[ $VAR = "value" ]` instead of `[ "$VAR" = "value" ]` — syntax error when `VAR` is empty or contains spaces
- Unquoted command substitution: `for f in $(ls ...)` — word splitting on filenames with spaces; use `while IFS= read -r` or a glob instead
- Array expansion without quotes: `${arr[*]}` instead of `"${arr[@]}"` — word splits array elements

## INJECTION

- User input or environment variable interpolated directly into an `eval` expression — arbitrary command execution
- Variable interpolated into a `find -exec` or `xargs` command without `-0` / null delimiter — filenames with spaces or special characters cause incorrect execution or injection
- `curl | bash` or `wget | sh` pattern — executes remote content without verification
- Variable used in a heredoc without quoting the delimiter (`<<EOF` vs `<<'EOF'`) — variable and command substitution occurs inside the heredoc when it may not be intended

## ERROR_HANDLING

- Command output redirected to a file without checking the command's exit code — silent partial writes on failure
- `trap` not set for `ERR` or `EXIT` in scripts that create temporary files or hold locks — cleanup does not run on failure
- Temporary file created with a predictable name (`/tmp/myapp.tmp`) — race condition and potential symlink attack; use `mktemp`
- Script exits without cleaning up background jobs — orphan processes remain after the script ends; use `trap 'kill $(jobs -p)' EXIT`

## PORTABILITY

- `bash`-specific syntax (`[[`, arrays, `$'...'`, process substitution) in a script with `#!/bin/sh` shebang — fails on systems where `/bin/sh` is dash or another POSIX shell
- `echo -e` used for escape sequences — not portable; use `printf` instead
- `which` used to check for a command — not POSIX; use `command -v`
- Relying on GNU-specific flags (`grep -P`, `sed -i ''`, `date -d`) without checking for macOS/BSD compatibility

## RESOURCE_HANDLING

- Script opens a file descriptor or starts a background process and never explicitly closes/waits for it — file descriptor leak or zombie process
- `while read` loop without `IFS= read -r` — leading/trailing whitespace stripped from each line; backslashes interpreted
- Large command output stored in a variable — for very large outputs, this can exhaust memory; pipe to a file instead
