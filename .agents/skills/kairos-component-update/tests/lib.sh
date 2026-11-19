#!/usr/bin/env bash
# lib.sh — shared harness for kairos-component-update test suites.
# Sourced by every *.test.sh. Provides assertions, fake-kairos bootstrap,
# phase-key helpers, and the named merge/common fixture builders (lifted from
# the former megafile without behavior changes).
#
# Per-test filter: `TEST_FILTER=<substring> bash tests/<suite>.test.sh` runs
# only matching `t "..."` blocks. Suites with shared sequential fixtures refuse
# TEST_FILTER at suite start (see each suite header).
#
# Output is QUIET by default: a green run prints only the terminal `passed: n/m`
# (plus any suite-emitted `skip:` lines — run-tests.sh counts those from output,
# so they must always print). A failure prints its `test:` header and the FAIL
# line, so a red run is self-locating without the green noise. Set VERBOSE=1 for
# the full ok:/test: stream. WHY quiet is the default: the common reader of a
# suite run is an agent or a scrollback, and hundreds of `ok:` lines carry zero
# information at real cost — the failures and the count are the content.
#
# Iterating on one block: TEST_FILTER='<substring>' VERBOSE=1 bash tests/<suite>.test.sh
# Before handing off:     tests/run-tests.sh --affected   (suites for changed files)
# Release / close-out:    tests/run-tests.sh              (full roster)

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_DIR=$(cd "$TESTS_DIR/.." && pwd)

TESTS=0; FAILURES=0
CURRENT_TEST=""
FAIL_HEADER_SHOWN=""

pass() { TESTS=$((TESTS+1)); [[ -z "${VERBOSE:-}" ]] || echo "  ok: $*"; }
fail() {
  TESTS=$((TESTS+1)); FAILURES=$((FAILURES+1))
  # In quiet mode a bare FAIL line loses its block context — print the `test:`
  # header once per failing block, so the red run reads like the verbose one
  # minus the green lines.
  if [[ -z "${VERBOSE:-}" ]] && [[ "$CURRENT_TEST" != "$FAIL_HEADER_SHOWN" ]]; then
    echo "test: $CURRENT_TEST"; FAIL_HEADER_SHOWN=$CURRENT_TEST
  fi
  echo "  FAIL: $*"
}
expect() { # expect <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
refute() { # refute <desc> <cmd...>  — passes when the command FAILS
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}
bucket_is() { # bucket_is <dest> <want-bucket>
  local got
  got=$(awk -F'\t' -v d="$1" '$4 == d { print $1 }' "$RUN/classification.tsv")
  if [[ "$got" = "$2" ]]; then pass "bucket $1 = $2"; else fail "bucket $1 = ${got:-<none>} (want $2)"; fi
}
col_is() { # col_is <dest> <col> <want> <desc>
  local got
  got=$(awk -F'\t' -v d="$1" -v c="$2" '$4 == d { print $c }' "$RUN/classification.tsv")
  if [[ "$got" = "$3" ]]; then pass "$4"; else fail "$4 (got '${got:-<none>}', want '$3')"; fi
}

t() {  # t "description" — begin a test block; skip if filter doesn't match
  CURRENT_TEST="$1"
  [[ -z "${TEST_FILTER:-}" ]] || case "$1" in *"$TEST_FILTER"*) ;; *) return 1 ;; esac
  [[ -z "${VERBOSE:-}" ]] || echo "test: $1"
  return 0
}

# Phase-load keys — each keyed entry script refuses to run without the PHASE_KEY
# stated in its phase file (SKILL.md's index deliberately carries none). The suite
# reads them the way an orchestrator does: from the phase file itself, so a key
# rotation never breaks the tests.
phase_key() { sed -n 's/^PHASE_KEY: //p' "$SKILL_DIR/phases/$1" | head -1; }

# seed_model_pins <run-dir> [strong] [coder] [executor] [budget] — write the
# $RUN/model.txt resolve-models.sh would have written. log-spawn.sh refuses a
# dispatch whose model is not the pin for its declared tier, and refuses outright
# when the file is absent, so every suite that logs a spawn needs the pins on
# disk. Defaults match the slugs the spawn suites already use.
seed_model_pins() {
  mkdir -p "$1"
  printf 'strong=%s\ncoder=%s\nexecutor=%s\nbudget=%s\n' \
    "${2:-opus-x}" "${3:-sonnet-x}" "${4:-haiku-x}" "${5:-balanced}" > "$1/model.txt"
}

bootstrap_suite() {
  SANDBOX=$(mktemp -d)
  trap 'rm -rf "$SANDBOX"' EXIT

  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
         GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

  # Isolate every fixture repo from the box's ambient git config. The suites build
  # throwaway repos and run the scripts against them, and a global/system config the
  # maintainer happens to carry otherwise leaks in: core.hooksPath runs arbitrary
  # hooks on the fixtures' own commits (turns suggest-branch.test.sh red — its
  # in-repo `git commit` never lands), and core.autocrlf=true silently strips the CR
  # the CRLF fixture commits on purpose (changing what the merge sees). Left
  # ambient, a Mac box and a CI container execute against different git semantics.
  # GIT_CONFIG_GLOBAL points at an empty controlled file (identity comes from the
  # GIT_AUTHOR_*/GIT_COMMITTER_* env above, which outranks config) and
  # GIT_CONFIG_NOSYSTEM drops /etc/gitconfig. A suite that deliberately injects a
  # hostile global to prove a SCRIPT defends itself (merge-path's ignore/filter
  # fixture) sets GIT_CONFIG_GLOBAL inline before its migration call, which still
  # wins over this export.
  : > "$SANDBOX/gitconfig-global"
  export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig-global"
  export GIT_CONFIG_NOSYSTEM=1

  # The fake Kairos CLI goes on PATH ahead of anything real. materialize.sh invokes
  # `kairos component create`; this is the process boundary the real CLI occupies,
  # which keeps the suite hermetic. The shim also asserts the flag/env contract.
  mkdir -p "$SANDBOX/bin"
  cp "$SKILL_DIR/tests/fake-kairos.sh" "$SANDBOX/bin/kairos"
  chmod +x "$SANDBOX/bin/kairos"
  export PATH="$SANDBOX/bin:$PATH"

  PK_PREFLIGHT=$(phase_key 1-preflight.md)
  PK_RESOLVE=$(phase_key 2-resolve-target.md)
  PK_MODELS=$(phase_key 1.5-model-resolution.md)
  PK_MATERIALIZE=$(phase_key 2.5-materialize.md)
  PK_CLASSIFY=$(phase_key 3-classify.md)
  PK_COMMON=$(phase_key 3.5-collect-common.md)
  PK_BASELINE=$(phase_key 4.5-test-baseline.md)
  PK_STRUCTURAL=$(phase_key 5-structural.md)
  PK_PLANNING=$(phase_key 6-planning.md)
  PK_EXECUTION=$(phase_key 7-execution.md)
  PK_FINALIZE=$(phase_key 8-finalize.md)
}

finish_suite() {
  echo
  echo "passed: $((TESTS - FAILURES))/$TESTS"
  if [[ "$FAILURES" -gt 0 ]]; then
    echo "logs: $SANDBOX (removed on exit — rerun with 'trap - EXIT' to keep)"
    trap - EXIT   # keep the sandbox around for inspection on failure
    echo "sandbox kept at: $SANDBOX"
    exit 1
  fi
}

setup_merge_fixture() {
echo "fixture: template repo"
TPL=$SANDBOX/template
mkdir -p "$TPL" && cd "$TPL"
git init -q -b main

# --- baseline commit ---
mkdir -p YOUR_COMPONENT_NAME .kairos-updates/ legacy oldpkg
cat > kept.txt <<'EOF'
line one
line two shared
line three
line four
line five
EOF
cat > clean.txt <<'EOF'
alpha
beta
gamma
delta
epsilon
EOF
# Line-ending fixture: LF in the template, CRLF in the component. Differing only
# in line endings must merge CLEANLY, not conflict on every line.
cat > crlf.txt <<'EOF'
crlf line one
crlf line two
crlf line three
crlf line four
crlf line five
EOF
echo "constant" > gone-unmodified.txt
echo "original" > gone-customized.txt
echo "will change" > modified-but-locally-deleted.txt
seq 1 12 | sed 's/^/rename-src line /'    > rename-src.txt
seq 1 12 | sed 's/^/rename-custom line /' > rename-custom-src.txt
seq 1 12 | sed 's/^/rename-mods line /'   > rename-mods-src.txt
seq 1 20 | sed 's/^/moved line /'         > moved-src.txt   # component relocates this; template later edits it
seq 1 20 | sed 's/^/tokmoved line /' > YOUR_COMPONENT_NAME/moved-tok-src.txt   # placeholder in PATH; component relocates it
printf 'name: <YOUR_COMPONENT_NAME>\nkey: value\n' > YOUR_COMPONENT_NAME/config.txt
printf 'BIN\0DATA v1\n' > logo.bin
# Wholesale-deleted subtree fixture (3 files, all removed in TARGET).
for f in x y z; do echo "legacy $f" > "legacy/$f.txt"; done
# Directory-rename fixture: a.go/b.go/c.go rename cleanly and corroborate the
# oldpkg -> newpkg mapping; big.go is rewritten so heavily git cannot pair it.
for f in a b c; do seq 1 8 | sed "s/^/pkg $f line /" > "oldpkg/$f.go"; done
seq 1 20 | sed 's/^/alpha original line /' > oldpkg/big.go
# An existing runtime under cmd/; a NEW cmd/<name>/ appears only at TARGET below.
mkdir -p cmd/existing && printf 'package main\n\nfunc main() {}\n' > cmd/existing/main.go
# Module-path fixture: the template's own module, and a file importing it.
printf 'module bitbucket.org/ifs-pd/kairos-component-template\n\ngo 1.26\n' > go.mod
printf 'package main\n\nimport "bitbucket.org/ifs-pd/kairos-component-template/pkg/foo"\n\nvar _ = foo.Thing\nvar keep = 1\n' > importer.go
# A token the CLI does NOT substitute — must surface as template feedback.
printf 'module_path: <YOUR_MODULE_PATH>\n' > tokened.txt
echo "# upgrade 1" > .kairos-updates/20260101T000000-first.md
git add -A && git commit -qm "baseline"
BASE=$(git rev-parse HEAD)

# --- intermediate commit ---
# Adds an upgrade-file whose timestamp (20260301) is LATER than the one the
# target commit adds (20260102), but which LANDS FIRST. Apply order must follow
# commit order (third, then second) — NOT timestamp/alphabetical order (second,
# then third). This is the regression guard for build-manifest.sh using
# `git log --reverse ... | awk '!seen'` instead of `sort -u`.
echo "# upgrade 3" > .kairos-updates/20260301T000000-third.md
# Prune-at-tip fixture: this file is added here but DELETED in the target commit
# below. Its body lives only in git history, never in the TARGET tree — a naive
# `git show TARGET:path` would read nothing. build-manifest must snapshot it from
# the addition commit. The distinctive body is what the assertion looks for.
printf '# pruned upgrade\nbody-that-must-survive-pruning\n' \
  > .kairos-updates/20260201T000000-pruned.md
git add -A && git commit -qm "intermediate upgrade"

# --- target commit ---
cat > kept.txt <<'EOF'
line one
line two from template
line three
line four
line five
EOF
cat > clean.txt <<'EOF'
alpha
beta
gamma-improved
delta
epsilon
EOF
sed 's/crlf line three/crlf line three IMPROVED/' crlf.txt > t && mv t crlf.txt
echo "changed" > modified-but-locally-deleted.txt
git rm -q gone-unmodified.txt gone-customized.txt
git rm -q legacy/x.txt legacy/y.txt legacy/z.txt
git mv rename-src.txt rename-dst.txt
git mv rename-custom-src.txt rename-custom-dst.txt
git mv rename-mods-src.txt rename-mods-dst.txt
sed 's/rename-mods line 6/rename-mods line six CHANGED/' rename-mods-dst.txt > t && mv t rename-mods-dst.txt
sed 's/moved line 10/moved line ten CHANGED/' moved-src.txt > t && mv t moved-src.txt   # M at original path
sed 's/tokmoved line 10/tokmoved line ten CHANGED/' YOUR_COMPONENT_NAME/moved-tok-src.txt > t && mv t YOUR_COMPONENT_NAME/moved-tok-src.txt
printf 'name: <YOUR_COMPONENT_NAME>\nkey: value\nextra: <YOUR_COMPONENT_NAME>-setting\n' > YOUR_COMPONENT_NAME/config.txt
printf 'BIN\0DATA v2\n' > logo.bin
printf 'hello <YOUR_COMPONENT_NAME>\n' > newfile.txt
mkdir bigdir && for f in a b c d; do echo "$f" > "bigdir/$f.txt"; done
# NEW runtime: a lone main.go under the already-existing cmd/ must still be a
# heavyweight addition. The >3-file rule and a top-level `cmd` grouping would both
# miss it — this guards the cmd/<name> special-case in build-manifest.sh.
mkdir -p cmd/worker && printf 'package main\n\nfunc main() {}\n' > cmd/worker/main.go
# Directory rename: 3 clean renames corroborate oldpkg -> newpkg; big.go is
# rewritten with zero shared lines so git reports delete+add, not a rename.
mkdir newpkg && for f in a b c; do git mv "oldpkg/$f.go" "newpkg/$f.go"; done
git rm -q oldpkg/big.go
seq 1 20 | sed 's/^/zulu rewritten line /' > newpkg/big.go
sed 's/var keep = 1/var keep = 2/' importer.go > t && mv t importer.go
# Frontend compatibility floor fixture: this upgrade-file's body carries a
# requires-frontend: field (module@40-hex-sha) so merge-path.test.sh can assert
# build-manifest.sh's Phase-3 extraction populates frontend-floors.tsv with the
# right row, while the other upgrade-files (no such field) contribute none.
# `supersedes:` names the third upgrade-file (which LANDED FIRST, in the
# intermediate commit): merge-path.test.sh asserts build-manifest.sh emits the
# backward edge into supersede-edges.tsv, and that the direction rule accepts it.
printf '# upgrade 2\n\nrequires-frontend: react@1234567890abcdef1234567890abcdef12345678\nsupersedes: 20260301T000000-third\n' \
  > .kairos-updates/20260102T000000-second.md
git rm -q .kairos-updates/20260201T000000-pruned.md   # prune-at-tip
printf '# tokens\n<YOUR_COMPONENT_NAME>\n<YOUR_MODULE_PATH>\n' > .kairos-updates/placeholders.txt
git add -A && git commit -qm "target"
TARGET=$(git rev-parse HEAD)

# =============================================================================
echo "fixture: component (seeded from baseline, with customizations)"
COMP=$SANDBOX/mycomp
mkdir -p "$COMP" && cd "$COMP"
git init -q -b main
mkdir -p .kairos mycomp legacy oldpkg
echo ".kairos/migration/state/" > .gitignore
cat > kept.txt <<'EOF'
line one
line two customized locally
line three
line four
line five
EOF
git -C "$TPL" show "$BASE:clean.txt" > clean.txt
# CRLF version of the baseline content — content-identical, endings differ.
git -C "$TPL" show "$BASE:crlf.txt" | sed 's/$/\r/' > crlf.txt
echo "constant" > gone-unmodified.txt
printf 'original\ncustom addition\n' > gone-customized.txt
# modified-but-locally-deleted.txt deliberately absent (component deleted it)
git -C "$TPL" show "$BASE:rename-src.txt" > rename-src.txt
{ git -C "$TPL" show "$BASE:rename-custom-src.txt"; echo "my custom line"; } > rename-custom-src.txt
git -C "$TPL" show "$BASE:rename-mods-src.txt" > rename-mods-src.txt
mkdir -p relocated                                                    # component MOVED moved-src.txt here, unchanged
git -C "$TPL" show "$BASE:moved-src.txt" > relocated/moved-dst.txt
mkdir -p mycomp/relocated                                             # component MOVED the tokenized-path file here
git -C "$TPL" show "$BASE:YOUR_COMPONENT_NAME/moved-tok-src.txt" > mycomp/relocated/moved-tok.txt
printf 'name: mycomp\nkey: value\n' > mycomp/config.txt
git -C "$TPL" show "$BASE:logo.bin" > logo.bin
cp logo.bin "$SANDBOX/logo.bin.orig"
for f in x y z; do echo "legacy $f" > "legacy/$f.txt"; done         # unmodified -> mechanical deletions
for f in a b c; do git -C "$TPL" show "$BASE:oldpkg/$f.go" > "oldpkg/$f.go"; done
{ git -C "$TPL" show "$BASE:oldpkg/big.go"; echo "my big customization"; } > oldpkg/big.go
mkdir -p cmd/existing && git -C "$TPL" show "$BASE:cmd/existing/main.go" > cmd/existing/main.go   # component already has a cmd/ runtime → cmd/ exists locally
# The component's module path deliberately does NOT follow the CLI's
# bitbucket.org/ifs-pd/<name> convention, so the corrective substitution must fire.
printf 'module example.com/custom/mycomp\n\ngo 1.26\n' > go.mod
printf 'package main\n\nimport "example.com/custom/mycomp/pkg/foo"\n\nvar _ = foo.Thing\nvar keep = 1\n' > importer.go
printf 'module_path: <YOUR_MODULE_PATH>\n' > tokened.txt
cat > .kairos/manifest.yaml <<EOF
name: mycomp
template:
  repo: file://$TPL
  sha: $BASE
  branch: main
EOF
git add -A && git commit -qm "component baseline"

}

setup_common_fixture() {
echo "fixture: common repo (multi-module tags + .kairos-updates/<module>/ files)"
CMN=$SANDBOX/common
mkdir -p "$CMN" && cd "$CMN"
git init -q -b main
mkdir -p .kairos-updates/api .kairos-updates/common .kairos-updates/event-handler
cuf() { # cuf <module> <filename-stem> <marker>
  cat > ".kairos-updates/$1/$2.md" <<UF
# $3

intent: consumer must migrate call-sites after $3.

before: OldSymbol_$3
after:  NewSymbol_$3

verify-script: ! grep -rn 'OldSymbol_$3' --include='*.go' .

## Details
body-$3
UF
}
echo "legacy root upgrade notes" > UPGRADE.md
git add -A && git commit -qm "c0 init"
git tag api/v1.2.30; git tag common/v1.3.20; git tag event-handler/v1.2.30
cuf api 20260101T000000-api-first api-first
git add -A && git commit -qm "c1 api-first"; git tag api/v1.2.40
C1_SHA=$(git rev-parse --short=12 HEAD)   # for the pseudo-version-resolves fixture
cuf common 20260102T000000-common-first common-first
git add -A && git commit -qm "c2 common-first"; git tag common/v1.3.22
cuf api 20260103T000000-api-second api-second
cuf api 20260103T000001-api-pruned api-pruned
git add -A && git commit -qm "c3 api-second + api-pruned"; git tag api/v1.2.50
git rm -q .kairos-updates/api/20260103T000001-api-pruned.md   # prune-at-tip
git commit -qm "c4 prune api-pruned"; git tag api/v1.3.0
cuf common 20260105T000000-common-second common-second
git add -A && git commit -qm "c5 common-second"; git tag common/v1.3.25

}

# Content-substitution helpers shared by add_frontend_to_component — the same
# escaping fake-kairos.sh uses so a component name with regex-special or
# sed-special characters doesn't corrupt the CLI's token replacement.
_esc_pat() { printf '%s' "$1" | sed -e 's/[][\.*^$/]/\\&/g'; }
_esc_rep() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's|/|\\/|g' -e 's/&/\\&/g'; }

setup_frontend_fixture() {
# Builds $SANDBOX/frontend — a kairos-frontend-shaped monorepo with a
# .kairos-updates/config.yaml declaring TWO template-kind modules, react
# (template/react) and solid (template/solid), each with its own bellwethers,
# so module-selection tests can prove one module's run never sees the other's
# upgrade-files, PLUS a kind: library module `lib` (path: lib) whose
# upgrade-files collect-lib.sh gathers on every frontend run irrespective of
# which template is mounted. Three commits (baseline -> intermediate -> target):
# the intermediate commit adds a solid-only in-range upgrade-file; the target
# commit makes a breaking change to template/react (renames the `App` export,
# bumps the dev-server port) with its matching upgrade-file added in the SAME
# commit, subtree-relative per the authoring contract, and a lib upgrade-file
# in the same range (different basename — snapshots are keyed by basename).
# Exports: FRONTEND_REPO_DIR, FRONTEND_BASE_SHA, FRONTEND_INTERMEDIATE_SHA,
#          FRONTEND_TARGET_SHA.
echo "fixture: frontend repo"
FRONTEND_REPO_DIR=$SANDBOX/frontend
mkdir -p "$FRONTEND_REPO_DIR" && cd "$FRONTEND_REPO_DIR"
git init -q -b main

# --- baseline commit ---
mkdir -p .kairos-updates/react .kairos-updates/solid .kairos-updates/lib \
         template/react/src template/solid/src lib/net

cat > .kairos-updates/config.yaml <<'EOF'
modules:
  react:
    kind: template
    path: template/react
    bellwethers:
      - vite.config.ts
      - tsconfig.json
      - eslint.config.js
  solid:
    kind: template
    path: template/solid
    bellwethers:
      - vite.config.ts
      - package.json
  lib:
    kind: library
    path: lib
EOF

cat > template/react/package.json <<'EOF'
{
  "name": "<YOUR_BC_NAME>",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "test": "pnpm test:watch",
    "test:watch": "vitest",
    "test:ci": "vitest run",
    "build": "vite build",
    "typecheck": "tsc -b"
  }
}
EOF

cat > template/react/vite.config.ts <<'EOF'
// vite config for <YOUR_COMPONENT_NAME>
import { defineConfig } from 'vite'

export default defineConfig({
  server: { port: 5173 },
})
EOF

cat > template/react/tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "strict": true,
    "composite": true
  },
  "include": ["src"]
}
EOF

cat > template/react/eslint.config.js <<'EOF'
export default [
  { ignores: ['dist/**'] },
]
EOF

cat > template/react/index.html <<'EOF'
<!doctype html>
<html>
  <head>
    <meta charset="UTF-8" />
    <title><YOUR_COMPONENT_NAME></title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
EOF

cat > template/react/src/main.tsx <<'EOF'
import { App } from './App'

App()
EOF

cat > template/react/src/App.tsx <<'EOF'
export function App() {
  return '<YOUR_COMPONENT_NAME> app'
}
EOF

# Binary, symlink and exec-bit shapes — the assets a real frontend template ships
# and the shapes install_side must never corrupt. The binary carries BOTH a NUL
# (what is_binary_file keys on) and \r bytes (what the text arm's CRLF-strip
# would silently eat — the corruption this fixture exists to catch). All three
# are deliberately token-free and unchanged across the range: they prove
# byte/mode fidelity, not substitution or classification.
mkdir -p template/react/src/assets template/react/scripts
printf 'PNG\0\r\nBINARY-V1\r\n\0tail' > template/react/src/assets/logo.png
printf '#!/bin/sh\necho dev server helper\n' > template/react/scripts/dev.sh
chmod +x template/react/scripts/dev.sh
ln -s ./App.tsx template/react/src/App.link.tsx

cat > template/solid/package.json <<'EOF'
{
  "name": "<YOUR_BC_NAME>",
  "private": true,
  "version": "0.0.0",
  "scripts": {
    "test": "pnpm test:watch",
    "test:watch": "vitest",
    "test:ci": "vitest run",
    "build": "vite build"
  }
}
EOF

cat > template/solid/vite.config.ts <<'EOF'
// vite config for <YOUR_COMPONENT_NAME> (solid)
export default { plugins: [] }
EOF

cat > template/solid/src/index.tsx <<'EOF'
export const App = () => '<YOUR_COMPONENT_NAME> solid app'
EOF

# Published library subtree — never merged into the component. Present from
# baseline so a kind:library declaration is a real path, not an empty one.
printf 'export function del() { return fetch("/x") }\n' > lib/net/rest.ts

git add -A && git commit -qm "baseline"
FRONTEND_BASE_SHA=$(git rev-parse HEAD)

# --- intermediate commit ---
# A solid-only rename + its upgrade-file, in-range but filed under the solid
# module directory — a react run must never collect this one.
sed 's/export const App =/export const AppRoot =/' template/solid/src/index.tsx > t && mv t template/solid/src/index.tsx
cat > .kairos-updates/solid/20260110T000000-solid-app-export-renamed.md <<'EOF'
# solid: App export renamed to AppRoot

intent: the solid module's exported App was renamed upstream; consumers of
        the solid template must follow.

before: export const App
after:  export const AppRoot

verify-script: ! grep -q 'export const App ' src/index.tsx

## Details
Cosmetic rename mirroring the react module's later rename; unrelated to
react and must never be collected by a react-module run.
EOF
git add -A && git commit -qm "intermediate: solid App export renamed"
FRONTEND_INTERMEDIATE_SHA=$(git rev-parse HEAD)

# --- target commit ---
# Breaking change to template/react: rename the App export and bump the dev
# server port, with the matching upgrade-file added in the SAME commit.
sed 's/export function App/export function AppRoot/' template/react/src/App.tsx > t && mv t template/react/src/App.tsx
sed -e 's/{ App }/{ AppRoot }/' -e 's/App()/AppRoot()/' template/react/src/main.tsx > t && mv t template/react/src/main.tsx
sed 's/port: 5173/port: 5174/' template/react/vite.config.ts > t && mv t template/react/vite.config.ts

cat > .kairos-updates/react/20260115T000000-app-export-renamed.md <<'EOF'
# App export renamed to AppRoot

intent: App was renamed to AppRoot upstream to avoid shadowing the DOM App
        component; call-sites importing App must follow or the build breaks.

before: export function App
after:  export function AppRoot

verify-script: ! grep -q 'export function App(' src/App.tsx

## Details
Update `src/App.tsx`'s export and every `import { App }` site inside the
mount to `AppRoot`. Paths above are relative to the template subtree (never
`web/`) — the executor runs this with cwd at the mount.
EOF

cat > .kairos-updates/lib/20260116T000000-net-rest-delete-renamed.md <<'EOF'
# net/rest delete renamed to remove

intent: @ifs-kairos/net/rest `delete` was renamed to `remove`; call-sites
        importing `delete` must follow.

before: import { delete as del } from '@ifs-kairos/net/rest'
after:  import { remove as del } from '@ifs-kairos/net/rest'

verify-script: ! grep -rq "delete as del" src && grep -rq "remove as del" src

## Details
Rename the imported symbol at every `@ifs-kairos/net/rest` call-site under
src/. Consumer-facing — this file never describes lib/ internals.
EOF
git add -A && git commit -qm "target: rename App export, bump dev port"
FRONTEND_TARGET_SHA=$(git rev-parse HEAD)

}

add_frontend_to_component() { # add_frontend_to_component <comp-dir> [with-manifest-block]
# Grafts a frontend mount onto a component fixture built by setup_merge_fixture
# (COMP): web/ = template/react at FRONTEND_BASE_SHA with the CLI's content
# and filename substitution applied (component name read from the component's
# own manifest name:), followed by one local customization committed on top.
# Pass a non-empty second arg to also append a `frontend:` block to
# .kairos/manifest.yaml; omit it for the bootstrap-scenario component (web/
# present, no block). Requires setup_frontend_fixture to have run first.
local comp="$1" with_block="${2:-}"
local name
name=$(sed -n 's/^name: //p' "$comp/.kairos/manifest.yaml" | head -1)

cd "$comp"
mkdir -p web
git -C "$FRONTEND_REPO_DIR" archive "$FRONTEND_BASE_SHA:template/react" | tar -x -C web

# Content substitution — same extension whitelist and token map fake-kairos.sh
# reproduces from the real CLI (component create), applied here directly
# because a frontend run must not require the Kairos CLI.
local N sedscript
N=$(_esc_rep "$name")
sedscript=$(printf 's/%s/%s/g\n' "$(_esc_pat '<YOUR_BC_NAME>')" "$N"
            printf 's/%s/%s/g\n' "$(_esc_pat '<YOUR_COMPONENT_NAME>')" "$N"
            printf 's/%s/%s/g\n' "$(_esc_pat 'YOUR_COMPONENT_NAME')" "$N"
            printf 's/%s/%s/g\n' "$(_esc_pat 'bitbucket.org/ifs-pd/kairos-component-template')" \
                                 "$(_esc_rep "bitbucket.org/ifs-pd/$name")")

find web -type f -print | while IFS= read -r f; do
  base=${f##*/}
  # Path().suffix semantics, as in scripts/lib/frontend-substitute.sh and
  # tests/fake-kairos.sh: a dotfile with no stem has NO suffix, so `.env` is outside the
  # whitelist and create leaves it verbatim. A fixture mount that substituted it would
  # diverge from every materialized side and read as a local edit.
  ext=""
  case "$base" in
    .*) case "${base#.}" in *.*) ext=".${base##*.}" ;; esac ;;
    *.*) ext=".${base##*.}" ;;
  esac
  keep=0
  case "$(printf '%s' "$ext" | tr 'A-Z' 'a-z')" in
    .json|.yaml|.yml|.go|.txt|.ini|.md|.dockerfile|.env|.mk|.ts|.tsx|.conf|.html) keep=1 ;;
  esac
  case "$base" in Makefile|Dockerfile|.gitignore|go.mod|go.sum|renovate.config.js) keep=1 ;;
  esac
  [[ "$keep" -eq 1 ]] || continue
  sed "$sedscript" "$f" > "$f.subst" 2>/dev/null && mv "$f.subst" "$f" || rm -f "$f.subst"
done

find web -depth -name '*YOUR_BC_NAME*' -o -depth -name '*YOUR_COMPONENT_NAME*' \
     -o -depth -name '*your_bc_name*' -o -depth -name '*your_component_name*' \
  | while IFS= read -r p; do
      d=${p%/*}; b=${p##*/}
      nb=$(printf '%s' "$b" \
             | sed -e "s/YOUR_BC_NAME/$name/g" -e "s/YOUR_COMPONENT_NAME/$name/g" \
                   -e "s/your_bc_name/$name/g" -e "s/your_component_name/$name/g")
      [[ "$b" != "$nb" ]] && mv "$p" "$d/$nb"
    done

if [[ -n "$with_block" ]]; then
  cat >> .kairos/manifest.yaml <<EOF
frontend:
  repo: file://$FRONTEND_REPO_DIR
  path: template/react
  template: react
  branch: main
  sha: $FRONTEND_BASE_SHA
EOF
fi

git add -A && git commit -qm "web: materialize react template at frontend baseline"

# --- one local customization on top ---
printf '\n// local customization\n' >> web/src/App.tsx
printf 'export const CUSTOM = true\n' > web/src/custom.ts
git add -A && git commit -qm "web: local customization"

}
