#!/usr/bin/env bash
# codev-check.test.sh — tests for scripts/codev-check.sh
# TEST_FILTER refused (single sequential fixture).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in codev-check.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite

if t "codev-check.sh — local-path replaces on the common prefix (Phase 3.5)"; then
CDV=$SANDBOX/codev
mkdir -p "$CDV" && cd "$CDV"
CDV_COMMON=bitbucket.org/ifs-pd/kairos-component-common
# (1) single-line local-path replace on the common prefix → printed
cat > single.mod <<EOF
module example.com/mycomp

go 1.26

require $CDV_COMMON/toolkit v1.0.0

replace $CDV_COMMON/toolkit => ../local/toolkit
EOF
CDV_SINGLE=$(COMMON_REPO_PATH=$CDV_COMMON "$SKILL_DIR/scripts/codev-check.sh" "$CDV/single.mod")
expect "single-line local-path replace is reported" \
  bash -c "echo \"$CDV_SINGLE\" | grep -q 'toolkit => \.\./local/toolkit'"

# (2) block-form replace (…) — the raison d'être for `go mod edit -json` over grep:
# the inner line carries no `replace` keyword, so a grep would miss it.
cat > block.mod <<EOF
module example.com/mycomp

go 1.26

require $CDV_COMMON/api v1.0.0

replace (
    $CDV_COMMON/api => ./vendor/api
)
EOF
CDV_BLOCK=$(COMMON_REPO_PATH=$CDV_COMMON "$SKILL_DIR/scripts/codev-check.sh" "$CDV/block.mod")
expect "block-form replace (…) is seen (go mod edit -json, not grep)" \
  bash -c "echo \"$CDV_BLOCK\" | grep -q 'api => \./vendor/api'"

# (3) a versioned replace on the prefix is NOT co-dev (not a local path) → no output
cat > versioned.mod <<EOF
module example.com/mycomp

go 1.26

require $CDV_COMMON/api v1.0.0

replace $CDV_COMMON/api => $CDV_COMMON/api v1.0.1
EOF
CDV_VER=$(COMMON_REPO_PATH=$CDV_COMMON "$SKILL_DIR/scripts/codev-check.sh" "$CDV/versioned.mod")
expect "a versioned replace is not treated as co-dev (empty output)" test -z "$CDV_VER"

# (4) no replaces at all → empty output, exit 0
cat > plain.mod <<EOF
module example.com/mycomp

go 1.26

require $CDV_COMMON/api v1.0.0
EOF
CDV_PLAIN=$(COMMON_REPO_PATH=$CDV_COMMON "$SKILL_DIR/scripts/codev-check.sh" "$CDV/plain.mod"); CDV_PLAIN_RC=$?
expect "no replaces → empty output" test -z "$CDV_PLAIN"
expect "no replaces → exit 0 (absence is not an error)" test "$CDV_PLAIN_RC" -eq 0

# (5) a local-path replace on a DIFFERENT prefix is ignored
cat > other.mod <<EOF
module example.com/mycomp

go 1.26

require example.com/other v1.0.0

replace example.com/other => ../other
EOF
CDV_OTHER=$(COMMON_REPO_PATH=$CDV_COMMON "$SKILL_DIR/scripts/codev-check.sh" "$CDV/other.mod")
expect "a local-path replace off the common prefix is ignored" test -z "$CDV_OTHER"

# (6) GOMOD env var works as an alternative to the positional arg
CDV_ENV=$(GOMOD="$CDV/single.mod" COMMON_REPO_PATH=$CDV_COMMON "$SKILL_DIR/scripts/codev-check.sh")
expect "GOMOD env is honored when no positional arg is given" \
  bash -c "echo \"$CDV_ENV\" | grep -q 'toolkit'"

# (7) guardrails: missing file and unset prefix both hard-fail
COMMON_REPO_PATH=$CDV_COMMON "$SKILL_DIR/scripts/codev-check.sh" "$CDV/nope.mod" > /dev/null 2>&1
expect "missing go.mod exits 2" test $? -eq 2
GOMOD="$CDV/single.mod" "$SKILL_DIR/scripts/codev-check.sh" > /dev/null 2>&1
expect "unset COMMON_REPO_PATH exits non-zero" test $? -ne 0

# (7b) the prefix is a PATH, not a pattern. `common.lib` unescaped matches
# `commonXlib`, so a local-path replace on an unrelated module read as a co-dev
# signal — and Phase 3.5's wrong-target tripwire fires on exactly that signal.
cat > nearmiss.mod <<'EOF'
module example.com/mycomp

go 1.26

require example.com/ifs-pd/commonXlib/api v1.0.0

replace example.com/ifs-pd/commonXlib/api => ../api
EOF
CDV_NEAR=$(COMMON_REPO_PATH=example.com/ifs-pd/common.lib \
  "$SKILL_DIR/scripts/codev-check.sh" "$CDV/nearmiss.mod")
expect "a regex metacharacter in the prefix does not match a near-miss module path" \
  test -z "$CDV_NEAR"
CDV_EXACT=$(COMMON_REPO_PATH=example.com/ifs-pd/commonXlib \
  "$SKILL_DIR/scripts/codev-check.sh" "$CDV/nearmiss.mod")
expect "the same go.mod still matches on its literal prefix (the escape is not over-tight)" \
  bash -c "echo \"$CDV_EXACT\" | grep -q 'api => \.\./api'"

# (8) fail-closed: a go.mod the go tool cannot parse must NOT read as "no
# replaces". `yq` exits 0 on empty stdin, so without pipefail this whole case
# came back empty at exit 0 — silently disarming the wrong-target tripwire.
cat > malformed.mod <<'EOF'
this is not a valid go.mod
replace ( unterminated
EOF
COMMON_REPO_PATH=$CDV_COMMON "$SKILL_DIR/scripts/codev-check.sh" "$CDV/malformed.mod" \
  > "$SANDBOX/cdv-bad.out" 2> "$SANDBOX/cdv-bad.err"
CDV_BAD_RC=$?
expect "a malformed go.mod exits 2 (could not parse ≠ no matches)" test "$CDV_BAD_RC" -eq 2
expect "a malformed go.mod produces no stdout" test ! -s "$SANDBOX/cdv-bad.out"
expect "the parse failure is announced as FAIL:" grep -q '^FAIL:' "$SANDBOX/cdv-bad.err"

# (9) no `go` on PATH is the same bad-input case, at the same exit code. PATH is
# narrowed to an empty dir for this one call; bash and the script are invoked by
# absolute path so the shebang lookup does not need PATH either.
CDV_NOGO_PATH=$SANDBOX/nogo-path; mkdir -p "$CDV_NOGO_PATH"
CDV_BASH=$(command -v bash)
env PATH="$CDV_NOGO_PATH" COMMON_REPO_PATH="$CDV_COMMON" \
  "$CDV_BASH" "$SKILL_DIR/scripts/codev-check.sh" "$CDV/single.mod" \
  > "$SANDBOX/cdv-nogo.out" 2> "$SANDBOX/cdv-nogo.err"
CDV_NOGO_RC=$?
expect "'go' absent from PATH exits 2" test "$CDV_NOGO_RC" -eq 2
expect "'go' absent produces no stdout" test ! -s "$SANDBOX/cdv-nogo.out"
expect "the missing-go failure names the tool, not a shell diagnostic" \
  grep -q "^FAIL: 'go' not found" "$SANDBOX/cdv-nogo.err"

# (10) an ABSOLUTE new path is the same co-dev signal as a relative one:
# `go mod edit -replace mod=$(pwd)/../common` — the natural CLI spelling — writes
# an absolute path, and a filter that only matched ./ and ../ read it as "no
# co-development" and disarmed the wrong-target tripwire over it.
cat > absolute.mod <<EOF
module example.com/mycomp

go 1.26

require $CDV_COMMON/toolkit v1.0.0

replace $CDV_COMMON/toolkit => /home/dev/kairos-component-common/toolkit
EOF
CDV_ABS=$(COMMON_REPO_PATH=$CDV_COMMON "$SKILL_DIR/scripts/codev-check.sh" "$CDV/absolute.mod")
expect "an absolute-path replace on the common prefix is reported (co-dev signal)" \
  bash -c "echo \"$CDV_ABS\" | grep -q 'toolkit => /home/dev'"
fi

finish_suite
