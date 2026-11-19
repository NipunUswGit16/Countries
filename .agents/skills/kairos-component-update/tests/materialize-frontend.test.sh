#!/usr/bin/env bash
# materialize-frontend.test.sh — tests for scripts/materialize-frontend.sh, the
# FRONTEND arm of Phase 2.5.
#
# The load-bearing test here is the CONTRACT test: the fixture CLI
# (tests/fake-kairos.sh) reproduces the real `kairos component create`
# substitution algorithm, so diffing its output against this script's TARGET side
# under the mount pins scripts/lib/frontend-substitute.sh ≡ the CLI. A frontend
# run may not invoke the CLI (PRD story 32), which is exactly why the equivalence
# has to be asserted somewhere — the run itself can no longer prove it.
#
# TEST_FILTER refused (blocks share one sequential frontend fixture + $RUN chain).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [[ -n "${TEST_FILTER:-}" ]]; then
  echo "error: TEST_FILTER is not supported in materialize-frontend.test.sh (shared sequential fixtures)" >&2
  exit 2
fi

bootstrap_suite
setup_frontend_fixture

MF=$SKILL_DIR/scripts/materialize-frontend.sh
NAME=kairos-notes-demo
COMP=$SANDBOX/comp
RUNREL=.kairos/migration/state
mkdir -p "$COMP/$RUNREL"
cat > "$COMP/.kairos/manifest.yaml" <<EOF
name: $NAME
template:
  repo: git@bitbucket.org:ifs-pd/kairos-component-template.git
  sha: 1111111111111111111111111111111111111111
frontend:
  repo: file://$FRONTEND_REPO_DIR
  path: template/react
  template: react
  branch: main
  sha: $FRONTEND_BASE_SHA
EOF

# mf <extra env...> — one invocation from the component root, with the phase key
# and the frontend range this suite is about. Stdout/stderr are captured for the
# assertions that read them.
mf() {
  ( cd "$COMP" && env PHASE_KEY="$PK_MATERIALIZE" RUN="$RUNREL" \
      BASE="$FRONTEND_BASE_SHA" TARGET="$FRONTEND_TARGET_SHA" \
      FRONTEND_PATH="$FRONTEND_REPO_DIR" "$@" "$MF" )
}
# side_tree <tag> <outdir> — extract one committed side out of the synthetic repo,
# so BASE is asserted from the commit rather than from whatever the working tree
# happens to hold after the last install.
side_tree() {
  rm -rf "$2"; mkdir -p "$2"
  git -C "$COMP/$RUNREL/synthetic" archive "$1" > "$SANDBOX/side.tar" \
    && tar -xf "$SANDBOX/side.tar" -C "$2"
}

if t "materialize-frontend.sh — phase-load guard"; then
( cd "$COMP" && env -u PHASE_KEY RUN="$RUNREL" BASE="$FRONTEND_BASE_SHA" \
    TARGET="$FRONTEND_TARGET_SHA" FRONTEND_PATH="$FRONTEND_REPO_DIR" "$MF" ) \
  > /dev/null 2> "$SANDBOX/mf-nokey.log"
MF_NOKEY_RC=$?
if [[ "$MF_NOKEY_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/2.5-materialize.md first' "$SANDBOX/mf-nokey.log"; then
  pass "without PHASE_KEY is refused: load phases/2.5-materialize.md first"
else
  fail "without PHASE_KEY is refused: load phases/2.5-materialize.md first (rc=$MF_NOKEY_RC)"
fi
mf PHASE_KEY=not-the-key > /dev/null 2> "$SANDBOX/mf-wrongkey.log"
MF_WRONG_RC=$?
if [[ "$MF_WRONG_RC" -ne 0 ]] && grep -qF 'FAIL: load phases/2.5-materialize.md first' "$SANDBOX/mf-wrongkey.log"; then
  pass "with a wrong PHASE_KEY is refused: load phases/2.5-materialize.md first"
else
  fail "with a wrong PHASE_KEY is refused: load phases/2.5-materialize.md first (rc=$MF_WRONG_RC)"
fi
refute "the refused run wrote no synthetic repo" test -d "$COMP/$RUNREL/synthetic"
fi

if t "materialize-frontend.sh — the run: output contract Phase 3 and Phase 5 read"; then
mf MODULE_PATH=template/react > "$SANDBOX/mf.out" 2> "$SANDBOX/mf.log"
MF_RC=$?
if [[ "$MF_RC" -eq 0 ]]; then pass "materializes the frontend range (exit 0)"; else
  fail "materializes the frontend range (rc=$MF_RC): $(tail -3 "$SANDBOX/mf.log" | tr '\n' ' ')"; fi
SYNTH_LINE=$(sed -n 's/^SYNTH=//p' "$SANDBOX/mf.out")
if [[ "$SYNTH_LINE" = "$RUNREL/synthetic" ]]; then
  pass "stdout carries SYNTH=\$RUN/synthetic — the template arm's line, unchanged"
else
  fail "stdout carries SYNTH=\$RUN/synthetic (got '${SYNTH_LINE:-<none>}')"
fi
expect "the synthetic repo tags kairos-base" \
  git -C "$COMP/$RUNREL/synthetic" rev-parse -q --verify kairos-base
expect "the synthetic repo tags kairos-target" \
  git -C "$COMP/$RUNREL/synthetic" rev-parse -q --verify kairos-target
expect "SYNTH/BASE/TARGET are recorded on the run-context anchor" \
  bash -c "grep -qx 'SYNTH=$RUNREL/synthetic' '$COMP/$RUNREL/context.env' \
        && grep -qx 'BASE=$FRONTEND_BASE_SHA' '$COMP/$RUNREL/context.env' \
        && grep -qx 'TARGET=$FRONTEND_TARGET_SHA' '$COMP/$RUNREL/context.env'"
expect "materialization.txt records the frontend source, module and mount" \
  bash -c "grep -q '^source: *frontend' '$COMP/$RUNREL/materialization.txt' \
        && grep -q '^module_path: *template/react' '$COMP/$RUNREL/materialization.txt' \
        && grep -q '^mount: *web/' '$COMP/$RUNREL/materialization.txt'"
expect "materialization.txt states that no Kairos CLI was involved" \
  grep -q '^cli: *none' "$COMP/$RUNREL/materialization.txt"
expect "the frontend mirror was cloned into the run's own state dir" \
  test -f "$COMP/$RUNREL/frontend/HEAD"
expect "surviving-tokens.tsv exists and is empty (the map substituted everything)" \
  bash -c "test -f '$COMP/$RUNREL/surviving-tokens.tsv' && test ! -s '$COMP/$RUNREL/surviving-tokens.tsv'"
expect "the scratch extraction dir is removed on success" \
  test ! -d "$COMP/$RUNREL/mat-frontend"
fi

if t "materialize-frontend.sh — binary, symlink and exec-bit fidelity through install_side"; then
# The corruption this block exists to catch: install_side's text arm strips \r
# (tr -d '\r') and rewrites content — routed at a binary by a broken
# is_binary_file, that CRLF-strip ships a corrupted icon/font on every real
# migration while every text-only assertion stays green. The fixture's
# logo.png carries NUL and \r bytes on purpose (tests/lib.sh); byte-compare
# both committed sides against the source blob itself.
FSYN=$COMP/$RUNREL/synthetic
expect "the fixture binary still carries its \\r canary (guards the fixture, not the script)" \
  bash -c "git -C '$FRONTEND_REPO_DIR' show '$FRONTEND_BASE_SHA:template/react/src/assets/logo.png' | LC_ALL=C od -c | grep -q '\\\\r'"
expect "the binary is byte-identical to the source blob on the BASE side" \
  bash -c "git -C '$FSYN' show kairos-base:web/src/assets/logo.png \
    | cmp -s - <(git -C '$FRONTEND_REPO_DIR' show '$FRONTEND_BASE_SHA:template/react/src/assets/logo.png')"
expect "the binary is byte-identical to the source blob on the TARGET side" \
  bash -c "git -C '$FSYN' show kairos-target:web/src/assets/logo.png \
    | cmp -s - <(git -C '$FRONTEND_REPO_DIR' show '$FRONTEND_TARGET_SHA:template/react/src/assets/logo.png')"
expect "the symlink survives as a mode-120000 link with its link text intact" \
  bash -c "git -C '$FSYN' ls-tree kairos-target -- web/src/App.link.tsx | grep -q '^120000 ' \
        && [ \"\$(git -C '$FSYN' show kairos-target:web/src/App.link.tsx)\" = './App.tsx' ]"
expect "the execute bit survives as mode 100755" \
  bash -c "git -C '$FSYN' ls-tree kairos-target -- web/scripts/dev.sh | grep -q '^100755 '"
fi

if t "CONTRACT: the TARGET side under the mount is byte-identical to the CLI's create output"; then
# The pinned test of the PRD's create-equivalence contract. The fake CLI is the
# stand-in for `kairos component create` everywhere else in this suite family and
# reproduces its content map, extension whitelist and filename map; if
# scripts/lib/frontend-substitute.sh ever drifts from it (or from the real CLI's
# token lists), this diff is the failure.
git -C "$FRONTEND_REPO_DIR" worktree add --detach --force "$SANDBOX/fe-wt" "$FRONTEND_TARGET_SHA" >/dev/null 2>&1
KAIROS_SKIP_NAME_VALIDATION=1 kairos component create "$NAME" "$SANDBOX/cli-out" \
  --template-path "$SANDBOX/fe-wt/template/react" \
  --no-repository --no-skills --no-tidy --no-frontend > "$SANDBOX/cli.log" 2>&1
CLI_RC=$?
if [[ "$CLI_RC" -eq 0 ]] && [[ -d "$SANDBOX/cli-out/$NAME" ]]; then
  pass "the fixture CLI produced a substituted tree from the same subtree at TARGET"
else
  fail "the fixture CLI produced a substituted tree (rc=$CLI_RC): $(tail -2 "$SANDBOX/cli.log" | tr '\n' ' ')"
fi
side_tree kairos-target "$SANDBOX/side-target"
# Non-vacuity FIRST: `diff -r` over two directories that both went empty exits 0,
# and this whole block would then certify the map it never compared.
CLI_N=$(find "$SANDBOX/cli-out/$NAME" -type f | grep -c .)
if [[ "${CLI_N:-0}" -ge 5 ]]; then
  pass "the contract diff has something to compare ($CLI_N file(s) in the CLI tree)"
else
  fail "the contract diff has something to compare (got ${CLI_N:-0} file(s), want >=5 — the fixture subtree emptied out)"
fi
if diff -r "$SANDBOX/cli-out/$NAME" "$SANDBOX/side-target/web" > "$SANDBOX/contract.diff" 2>&1; then
  pass "helper ≡ CLI: the materialized TARGET mount matches create's output file-for-file"
else
  fail "helper ≡ CLI drift under the mount: $(head -5 "$SANDBOX/contract.diff" | tr '\n' ' ')"
fi
git -C "$FRONTEND_REPO_DIR" worktree remove --force "$SANDBOX/fe-wt" >/dev/null 2>&1 || true
fi

if t "CONTRACT: every entry in the replacement map is exercised against the CLI"; then
# The block above diffs the SHIPPED fixture module, which only ever carries the two
# BRACKETED tokens — so on its own it cannot see a drifted bare-token rule, a
# drifted filename rule, or a widened extension whitelist. (Verified: deleting the
# bare-`YOUR_COMPONENT_NAME` rule from the helper left that diff green.) This block
# adds a module built to exercise EVERY entry in the map plus the whitelist's blind
# spot, so the equivalence claim covers the map rather than one file of it.
MC=$SANDBOX/frontend/template/mapcover
mkdir -p "$MC/src"
cat > "$MC/package.json" <<'EOF'
{
  "name": "<YOUR_BC_NAME>",
  "displayName": "<YOUR_COMPONENT_NAME>",
  "bareToken": "YOUR_COMPONENT_NAME",
  "goModule": "bitbucket.org/ifs-pd/kairos-component-template/web/entrypoint"
}
EOF
# A non-whitelisted extension: the CLI substitutes nothing here, and neither may
# the helper — this is the blind spot the whole "never reimplement the map" rule
# exists to preserve, so it is asserted rather than left to chance.
printf '/* YOUR_COMPONENT_NAME and <YOUR_BC_NAME> stay verbatim */\n' > "$MC/src/theme.css"
printf 'export const NAME = "<YOUR_COMPONENT_NAME>"\n' > "$MC/src/YOUR_COMPONENT_NAME.config.ts"
printf 'export const ALT = "YOUR_COMPONENT_NAME"\n' > "$MC/src/your_bc_name.ts"
git -C "$SANDBOX/frontend" add -A >/dev/null
git -C "$SANDBOX/frontend" commit -qm "fixture: map-coverage module" >/dev/null
MC_SHA=$(git -C "$SANDBOX/frontend" rev-parse HEAD)

git -C "$FRONTEND_REPO_DIR" worktree add --detach --force "$SANDBOX/mc-wt" "$MC_SHA" >/dev/null 2>&1
KAIROS_SKIP_NAME_VALIDATION=1 kairos component create "$NAME" "$SANDBOX/mc-cli" \
  --template-path "$SANDBOX/mc-wt/template/mapcover" \
  --no-repository --no-skills --no-tidy --no-frontend > "$SANDBOX/mc-cli.log" 2>&1
MC_CLI_RC=$?
if [[ "$MC_CLI_RC" -eq 0 ]] && [[ -d "$SANDBOX/mc-cli/$NAME" ]]; then
  pass "the fixture CLI substituted the map-coverage module"
else
  fail "the fixture CLI substituted the map-coverage module (rc=$MC_CLI_RC)"
fi
# MODULE names the module this side is: the map-coverage module is not in the source's
# config.yaml, so the passed MODULE_PATH is what resolves (the config's `react` entry
# must not redirect a run that is explicitly about another module).
mf MODULE=mapcover MODULE_PATH=template/mapcover BASE="$MC_SHA" TARGET="$MC_SHA" \
  > /dev/null 2> "$SANDBOX/mf-mc.log"
MC_RC=$?
if [[ "$MC_RC" -eq 0 ]]; then pass "materialize-frontend.sh materialized the map-coverage module"; else
  fail "materialize-frontend.sh materialized the map-coverage module (rc=$MC_RC): $(tail -3 "$SANDBOX/mf-mc.log" | tr '\n' ' ')"; fi
side_tree kairos-target "$SANDBOX/side-mc"
MC_N=$(find "$SANDBOX/mc-cli/$NAME" -type f | grep -c .)
if [[ "${MC_N:-0}" -ge 4 ]]; then
  pass "the map-coverage diff has something to compare ($MC_N file(s))"
else
  fail "the map-coverage diff has something to compare (got ${MC_N:-0}, want >=4)"
fi
if diff -r "$SANDBOX/mc-cli/$NAME" "$SANDBOX/side-mc/web" > "$SANDBOX/mc.diff" 2>&1; then
  pass "helper ≡ CLI across the whole map (bracketed + bare tokens, module path, filenames, whitelist)"
else
  fail "helper ≡ CLI drift on the map-coverage module: $(head -5 "$SANDBOX/mc.diff" | tr '\n' ' ')"
fi
# And the individual rules, so a failure says WHICH rule drifted rather than only
# that two trees differ.
MCD=$SANDBOX/side-mc/web
expect "the bare YOUR_COMPONENT_NAME token is substituted inside the whitelist" \
  bash -c "grep -q '\"bareToken\": \"$NAME\"' '$MCD/package.json'"
expect "the template's Go module path is rewritten to the component's" \
  bash -c "grep -q 'bitbucket.org/ifs-pd/$NAME/web/entrypoint' '$MCD/package.json'"
expect "filename tokens are substituted (upper and lower forms)" \
  bash -c "test -f '$MCD/src/$NAME.config.ts' && test -f '$MCD/src/$NAME.ts'"
expect "a non-whitelisted extension is left verbatim, exactly as the CLI leaves it" \
  bash -c "grep -q 'YOUR_COMPONENT_NAME and <YOUR_BC_NAME> stay verbatim' '$MCD/src/theme.css'"
git -C "$FRONTEND_REPO_DIR" worktree remove --force "$SANDBOX/mc-wt" >/dev/null 2>&1 || true
# Re-materialize the react range: the blocks below read the shipped module's sides.
mf MODULE_PATH=template/react > /dev/null 2> "$SANDBOX/mf-again.log" \
  || fail "could not re-materialize the react range after the map-coverage block"
fi

if t "both sides are create-equivalent: no placeholder token survives, package name is the component"; then
side_tree kairos-base "$SANDBOX/side-base"
for side in base target; do
  D=$SANDBOX/side-$side
  LEFT=$(grep -rlE '<YOUR_|YOUR_COMPONENT_NAME|your_bc_name|your_component_name' "$D" 2>/dev/null | tr '\n' ' ')
  if [[ -z "$LEFT" ]]; then
    pass "$side side carries no <YOUR_ / YOUR_COMPONENT_NAME / your_bc_name token"
  else
    fail "$side side still carries create-time placeholders in: $LEFT"
  fi
  PKGNAME=$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' "$D/web/package.json" | head -1)
  if [[ "$PKGNAME" = "$NAME" ]]; then
    pass "$side side's web/package.json name is the component name"
  else
    fail "$side side's web/package.json name is the component name (got '${PKGNAME:-<none>}')"
  fi
done
# The range's breaking change must be visible ACROSS the two sides, or the sides
# are create-equivalent copies of the same commit and the merge has nothing to do.
expect "BASE exports App and TARGET exports AppRoot (the sides really differ)" \
  bash -c "grep -q 'export function App(' '$SANDBOX/side-base/web/src/App.tsx' \
        && grep -q 'export function AppRoot(' '$SANDBOX/side-target/web/src/App.tsx'"
fi

if t "tree shape: everything under the mount, the other module and .kairos-updates absent"; then
for side in base target; do
  D=$SANDBOX/side-$side
  OUTSIDE=$( ( cd "$D" && find . -mindepth 1 -maxdepth 1 ! -name web -print ) | tr '\n' ' ')
  if [[ -z "$OUTSIDE" ]]; then
    pass "$side side contains web/ and nothing outside it"
  else
    fail "$side side has paths outside the mount: $OUTSIDE"
  fi
  refute "$side side carries no .kairos-updates (upgrade-files live at the source repo root)" \
    bash -c "find '$D' -name .kairos-updates -print | grep -q ."
  refute "$side side carries nothing from the sibling solid module" \
    bash -c "grep -rq 'solid app' '$D' 2>/dev/null || find '$D' -path '*solid*' -print | grep -q ."
done
fi

if t "the reuse stamp short-circuits an unchanged re-run"; then
mf MODULE_PATH=template/react > "$SANDBOX/mf-reuse.out" 2> "$SANDBOX/mf-reuse.log"
MF_RE_RC=$?
if [[ "$MF_RE_RC" -eq 0 ]] && grep -q '^SYNTH=' "$SANDBOX/mf-reuse.out" \
   && grep -qF 'reusing materialized frontend trees' "$SANDBOX/mf-reuse.log"; then
  pass "an unchanged re-run reuses the trees and still prints SYNTH="
else
  fail "an unchanged re-run reuses the trees and still prints SYNTH= (rc=$MF_RE_RC)"
fi
fi

if t "a non-default MOUNT maps the same subtree elsewhere"; then
mf MODULE_PATH=template/react MOUNT=ui/ > "$SANDBOX/mf-ui.out" 2> "$SANDBOX/mf-ui.log"
MF_UI_RC=$?
if [[ "$MF_UI_RC" -eq 0 ]]; then pass "MOUNT=ui/ materializes (exit 0)"; else
  fail "MOUNT=ui/ materializes (rc=$MF_UI_RC): $(tail -3 "$SANDBOX/mf-ui.log" | tr '\n' ' ')"; fi
side_tree kairos-target "$SANDBOX/side-ui"
expect "the subtree lands under ui/, not web/" \
  bash -c "test -f '$SANDBOX/side-ui/ui/package.json' && test ! -e '$SANDBOX/side-ui/web'"
UI_OUTSIDE=$( ( cd "$SANDBOX/side-ui" && find . -mindepth 1 -maxdepth 1 ! -name ui -print ) | tr '\n' ' ')
if [[ -z "$UI_OUTSIDE" ]]; then
  pass "nothing outside the non-default mount"
else
  fail "paths outside the non-default mount: $UI_OUTSIDE"
fi
expect "materialization.txt records the non-default mount" \
  grep -q '^mount: *ui/' "$COMP/$RUNREL/materialization.txt"
# The stamp carries the mount, so the ui/ run above must NOT have been served the
# web/ trees from the previous block's stamp.
refute "the mount change was not short-circuited by the previous run's stamp" \
  grep -qF 'reusing materialized frontend trees' "$SANDBOX/mf-ui.log"
fi

if t "MODULE_PATH: the source's config.yaml at TARGET outranks the manifest, with a WARN"; then
# The relocation case (Finding 5). Upstream moves a module and updates its own
# config.yaml; every existing component's `frontend.path` is stale the same instant.
# A manifest-only resolution extracts the OLD path and dies with "not a directory at
# the target commit" — which reads as a wrong SHA or a wrong module, the two things it
# is not. So the SOURCE's value wins, and the disagreement is said out loud.
MV=$SANDBOX/frontend/template/react-v2
mkdir -p "$MV"
cp -R "$SANDBOX/frontend/template/react/." "$MV/"
printf 'export const RELOCATED = true\n' > "$MV/src/relocated.ts"
MOD_CFG=$SANDBOX/frontend/.kairos-updates/config.yaml
yq -i '.modules.react.path = "template/react-v2"' "$MOD_CFG"
git -C "$SANDBOX/frontend" add -A >/dev/null
git -C "$SANDBOX/frontend" commit -qm "fixture: relocate the react module to template/react-v2" >/dev/null
RELOC_SHA=$(git -C "$SANDBOX/frontend" rev-parse HEAD)

# MODULE_PATH is passed as the STALE value on purpose — this is exactly what a
# component manifest written before the relocation carries.
mf MODULE=react MODULE_PATH=template/react BASE="$RELOC_SHA" TARGET="$RELOC_SHA" \
  > "$SANDBOX/mf-reloc.out" 2> "$SANDBOX/mf-reloc.log"
MF_RELOC_RC=$?
if [[ "$MF_RELOC_RC" -eq 0 ]]; then pass "the relocated module materializes (exit 0)"; else
  fail "the relocated module materializes (rc=$MF_RELOC_RC): $(tail -3 "$SANDBOX/mf-reloc.log" | tr '\n' ' ')"; fi
expect "the config's path is what was materialized, not the stale manifest one" \
  grep -q '^module_path: *template/react-v2' "$COMP/$RUNREL/materialization.txt"
expect "the disagreement is a WARN naming both values" \
  bash -c "grep -F 'WARN:' '$SANDBOX/mf-reloc.log' | grep -qF 'template/react-v2' \
        && grep -F 'WARN:' '$SANDBOX/mf-reloc.log' | grep -qF 'template/react'"
side_tree kairos-target "$SANDBOX/side-reloc"
expect "the mount really carries the relocated subtree's content" \
  test -f "$SANDBOX/side-reloc/web/src/relocated.ts"
# The module KEY defaults from the component manifest (`frontend.template: react`), so
# a run that passes no MODULE at all resolves the same way — that default is what makes
# the config read reachable on a real run, where only Phase 2.5 passes the key through.
mf MODULE_PATH=template/react BASE="$RELOC_SHA" TARGET="$RELOC_SHA" \
  > /dev/null 2> "$SANDBOX/mf-nomod.log"
MF_NOMOD_RC=$?
if [[ "$MF_NOMOD_RC" -eq 0 ]]; then pass "with no MODULE passed, the manifest's frontend.template supplies the key (exit 0)"; else
  fail "with no MODULE passed, the manifest's frontend.template supplies the key (rc=$MF_NOMOD_RC)"; fi
expect "and the config still wins over the stale passed path" \
  grep -q '^module_path: *template/react-v2$' "$COMP/$RUNREL/materialization.txt"
expect "the disagreement is still reported" grep -qF 'WARN:' "$SANDBOX/mf-nomod.log"
fi

if t "MODULE_PATH: no config.yaml at TARGET falls back to the passed/manifest value"; then
# Every source repo that does not self-describe, and every frontend repo older than
# the config. The fallback must be SILENT — an INFO/WARN here would make the ordinary
# case look like a problem — and it must not be a hard stop.
git -C "$SANDBOX/frontend" rm -q .kairos-updates/config.yaml >/dev/null
git -C "$SANDBOX/frontend" commit -qm "fixture: a source repo with no config.yaml" >/dev/null
NOCFG_SHA=$(git -C "$SANDBOX/frontend" rev-parse HEAD)
mf MODULE=react MODULE_PATH=template/react BASE="$NOCFG_SHA" TARGET="$NOCFG_SHA" \
  > /dev/null 2> "$SANDBOX/mf-nocfg.log"
MF_NOCFG_RC=$?
if [[ "$MF_NOCFG_RC" -eq 0 ]]; then pass "a TARGET with no config.yaml still materializes (exit 0)"; else
  fail "a TARGET with no config.yaml still materializes (rc=$MF_NOCFG_RC): $(tail -3 "$SANDBOX/mf-nocfg.log" | tr '\n' ' ')"; fi
expect "the passed module path is what was used" \
  grep -q '^module_path: *template/react$' "$COMP/$RUNREL/materialization.txt"
refute "the ordinary fallback is silent — no WARN" grep -qF 'WARN:' "$SANDBOX/mf-nocfg.log"
refute "and it claims no config resolution" \
  bash -c "grep -qF 'resolved from the source' '$SANDBOX/mf-nocfg.log'"
# A module the config never declared behaves the same way: fall back, do not refuse.
mf MODULE=no-such-module MODULE_PATH=template/react BASE="$FRONTEND_BASE_SHA" \
  TARGET="$FRONTEND_TARGET_SHA" > /dev/null 2> "$SANDBOX/mf-unknownmod.log"
MF_UNK_RC=$?
if [[ "$MF_UNK_RC" -eq 0 ]]; then pass "an unknown MODULE key falls back rather than refusing"; else
  fail "an unknown MODULE key falls back rather than refusing (rc=$MF_UNK_RC)"; fi
expect "and it used the passed path" \
  grep -q '^module_path: *template/react$' "$COMP/$RUNREL/materialization.txt"
fi

if t "the TEMPLATE arm resolves no module config (the fork stays on one side)"; then
# Static, and deliberately so: the resolution is a FRONTEND-arm concern (the config
# lives in a configured source repo, and the template arm has no module at all). If it
# ever leaks into materialize.sh, the template arm's create-based contract acquires a
# dependency on a file the component template does not ship.
refute "scripts/materialize.sh reads no .kairos-updates/config.yaml" \
  grep -qF '.kairos-updates/config.yaml' "$SKILL_DIR/scripts/materialize.sh"
refute "scripts/materialize.sh resolves no MODULE key" \
  grep -qE '^MODULE=|modules\[strenv' "$SKILL_DIR/scripts/materialize.sh"
fi

if t "failure modes fail loudly"; then
mfail() { # mfail <desc> <needle> <env...>
  local desc="$1" needle="$2"; shift 2
  mf "$@" > /dev/null 2> "$SANDBOX/mf-fail.log"
  local rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q '^FAIL:' "$SANDBOX/mf-fail.log" \
     && grep -qF "$needle" "$SANDBOX/mf-fail.log"; then
    pass "$desc"
  else
    fail "$desc (rc=$rc, log: $(tail -2 "$SANDBOX/mf-fail.log" | tr '\n' ' '))"
  fi
}
mfail "a BASE SHA that resolves to nothing is refused" "does not resolve to a commit" \
  MODULE_PATH=template/react BASE=0123456789abcdef0123456789abcdef01234567
mfail "a TARGET SHA that resolves to nothing is refused" "does not resolve to a commit" \
  MODULE_PATH=template/react TARGET=0123456789abcdef0123456789abcdef01234567
# MODULE=vue is a module the source's config never declared, so nothing redirects the
# passed path: the run really does look for template/vue at both sides and refuses.
mfail "a module path absent at a side is refused, naming the module" "is not a directory at the" \
  MODULE=vue MODULE_PATH=template/vue
mfail "an absolute MOUNT is refused" "MOUNT must be a relative path" \
  MODULE_PATH=template/react MOUNT=/web
mfail "a MOUNT of .git is refused" "MOUNT must be a relative path" \
  MODULE_PATH=template/react MOUNT=.git
mfail "a MODULE_PATH escaping the source repo is refused" "MODULE_PATH must be a relative path" \
  MODULE_PATH=../template/react
# No mirror and no origin: the run cannot invent the frontend source.
( cd "$COMP" && env PHASE_KEY="$PK_MATERIALIZE" RUN="$RUNREL" BASE="$FRONTEND_BASE_SHA" \
    TARGET="$FRONTEND_TARGET_SHA" MODULE_PATH=template/react \
    FRONTEND_CACHE="$SANDBOX/no-such-mirror" "$MF" ) > /dev/null 2> "$SANDBOX/mf-noorigin.log"
MF_NO_RC=$?
if [[ "$MF_NO_RC" -ne 0 ]] && grep -qF 'no frontend mirror' "$SANDBOX/mf-noorigin.log"; then
  pass "no mirror and no origin is refused, naming both env keys"
else
  fail "no mirror and no origin is refused (rc=$MF_NO_RC)"
fi
fi

if t "MODULE_PATH is resolved PER SIDE: a module relocated INSIDE the range materializes both ends"; then
# C1: resolving only at TARGET demands the NEW path at BASE too, where the module still
# sat at the old one — so the run refused with "module path is not a directory at the
# base commit" and the one range that carries a relocation became the only range that
# could not adopt it. Each side is resolved against its own commit instead.
FEREPO=$SANDBOX/frontend
mkdir -p "$FEREPO/.kairos-updates"
# BASE commit: the module lives at template/react-a, and the config says so.
rm -rf "$FEREPO/template/react-a"; mkdir -p "$FEREPO/template/react-a"
cp -R "$FEREPO/template/react/." "$FEREPO/template/react-a/"
printf 'export const BASE_ONLY = true\n' > "$FEREPO/template/react-a/src/base-only.ts"
printf 'modules:\n  react:\n    kind: template\n    path: template/react-a\n' \
  > "$FEREPO/.kairos-updates/config.yaml"
git -C "$FEREPO" add -A >/dev/null
git -C "$FEREPO" commit -qm "fixture: module at template/react-a" >/dev/null
MV_BASE=$(git -C "$FEREPO" rev-parse HEAD)
# TARGET commit: upstream MOVES it to template/react-b and updates its own config.
rm -rf "$FEREPO/template/react-b"; mkdir -p "$FEREPO/template/react-b"
cp -R "$FEREPO/template/react-a/." "$FEREPO/template/react-b/"
rm -f "$FEREPO/template/react-b/src/base-only.ts"
printf 'export const TARGET_ONLY = true\n' > "$FEREPO/template/react-b/src/target-only.ts"
git -C "$FEREPO" rm -rq template/react-a >/dev/null
printf 'modules:\n  react:\n    kind: template\n    path: template/react-b\n' \
  > "$FEREPO/.kairos-updates/config.yaml"
git -C "$FEREPO" add -A >/dev/null
git -C "$FEREPO" commit -qm "fixture: module MOVED to template/react-b" >/dev/null
MV_TARGET=$(git -C "$FEREPO" rev-parse HEAD)

# The manifest's path is stale at BOTH ends — which is the ordinary state of a component
# whose module upstream ever moved.
mf MODULE=react MODULE_PATH=template/react BASE="$MV_BASE" TARGET="$MV_TARGET" \
  > "$SANDBOX/mf-move.out" 2> "$SANDBOX/mf-move.log"
MF_MOVE_RC=$?
if [[ "$MF_MOVE_RC" -eq 0 ]]; then
  pass "an in-range relocation materializes instead of refusing at the base side"
else
  fail "an in-range relocation materializes (rc=$MF_MOVE_RC): $(tail -3 "$SANDBOX/mf-move.log" | tr '\n' ' ')"
fi
expect "the report's module_path is the TARGET side's" \
  grep -q '^module_path: *template/react-b$' "$COMP/$RUNREL/materialization.txt"
expect "and it records the BASE side's separately, so the range is legible" \
  grep -q '^base_module_path: *template/react-a' "$COMP/$RUNREL/materialization.txt"
expect "the move is a WARN naming both paths" \
  bash -c "grep -F 'WARN:' '$SANDBOX/mf-move.log' | grep -qF 'MOVED inside this range' \
        && grep -F 'WARN:' '$SANDBOX/mf-move.log' | grep -qF 'template/react-a' \
        && grep -F 'WARN:' '$SANDBOX/mf-move.log' | grep -qF 'template/react-b'"
expect "and it says the two sides still land on one mount (adds/deletes, not a rename)" \
  bash -c "grep -F 'WARN:' '$SANDBOX/mf-move.log' | grep -qF 'adds/deletes'"
side_tree kairos-base "$SANDBOX/side-mv-base"
side_tree kairos-target "$SANDBOX/side-mv-target"
expect "the BASE side really came from the OLD path" \
  test -f "$SANDBOX/side-mv-base/web/src/base-only.ts"
expect "the TARGET side really came from the NEW path" \
  test -f "$SANDBOX/side-mv-target/web/src/target-only.ts"
refute "and neither side carries the other's marker" \
  bash -c "test -e '$SANDBOX/side-mv-base/web/src/target-only.ts' \
        || test -e '$SANDBOX/side-mv-target/web/src/base-only.ts'"
fi

if t "the RESOLVED module path, mirror and mount are written back onto the run-context anchor"; then
# C2: Phase 8's parity basis reads FRONTEND_MODULE_PATH off the anchor. With only the
# manifest's value there, an upstream relocation made the parity basis a DIFFERENT
# subtree than the merge used, and the delta between two modules was reported as this
# component's drift. The script that resolves the path is the one that records it.
CTXF=$COMP/$RUNREL/context.env
expect "FRONTEND_MODULE_PATH is the resolved TARGET-side subtree, not the manifest's" \
  grep -qx 'FRONTEND_MODULE_PATH=template/react-b' "$CTXF"
refute "the stale manifest value is not what landed" \
  grep -qx 'FRONTEND_MODULE_PATH=template/react' "$CTXF"
expect "FRONTEND_CACHE names the mirror this run actually read" \
  grep -qx "FRONTEND_CACHE=$RUNREL/frontend" "$CTXF"
expect "FRONTEND_MOUNT is recorded in the same spelling pre-flight uses" \
  grep -qx 'FRONTEND_MOUNT=web/' "$CTXF"
expect "and the three template-arm keys are still there beside them" \
  bash -c "grep -qx 'SYNTH=$RUNREL/synthetic' '$CTXF' && grep -q '^BASE=' '$CTXF' && grep -q '^TARGET=' '$CTXF'"
# A non-default mount is recorded as such — the key is a fact about this run, not a
# restatement of the default.
mf MODULE=react MODULE_PATH=template/react-b MOUNT=ui/ BASE="$MV_TARGET" TARGET="$MV_TARGET" \
  > /dev/null 2> "$SANDBOX/mf-anchor-ui.log"
expect "a non-default mount lands on the anchor" grep -qx 'FRONTEND_MOUNT=ui/' "$CTXF"
fi

if t "CONTRACT: a dotfile whose whole name is an extension (.env) is left verbatim on BOTH sides"; then
# C4: the whitelist is tested with Python's Path().suffix in the real CLI, where
# Path('.env').suffix is '' — so `.env` is NOT a whitelisted-extension file and create
# never rewrites it. Deriving the extension as ".${base##*.}" made `.env` look like one
# and substituted a file the CLI leaves alone: a divergence the merge then reads as a
# local edit on every side. Asserted against the fixture CLI, on both sides of the map.
DE=$SANDBOX/frontend/template/dotenv
mkdir -p "$DE/src"
printf '{\n  "name": "<YOUR_BC_NAME>"\n}\n' > "$DE/package.json"
printf 'VITE_APP=<YOUR_COMPONENT_NAME>\nVITE_BARE=YOUR_COMPONENT_NAME\n' > "$DE/.env"
printf 'VITE_APP=<YOUR_COMPONENT_NAME>\n' > "$DE/.env.local"
printf 'export const X = "<YOUR_COMPONENT_NAME>"\n' > "$DE/src/x.ts"
git -C "$SANDBOX/frontend" add -A >/dev/null
git -C "$SANDBOX/frontend" commit -qm "fixture: dotfile-extension module" >/dev/null
DE_SHA=$(git -C "$SANDBOX/frontend" rev-parse HEAD)

git -C "$FRONTEND_REPO_DIR" worktree add --detach --force "$SANDBOX/de-wt" "$DE_SHA" >/dev/null 2>&1
KAIROS_SKIP_NAME_VALIDATION=1 kairos component create "$NAME" "$SANDBOX/de-cli" \
  --template-path "$SANDBOX/de-wt/template/dotenv" \
  --no-repository --no-skills --no-tidy --no-frontend > "$SANDBOX/de-cli.log" 2>&1
DE_CLI_RC=$?
if [[ "$DE_CLI_RC" -eq 0 ]] && [[ -d "$SANDBOX/de-cli/$NAME" ]]; then
  pass "the fixture CLI produced the dotfile module"
else
  fail "the fixture CLI produced the dotfile module (rc=$DE_CLI_RC)"
fi
mf MODULE=dotenv MODULE_PATH=template/dotenv BASE="$DE_SHA" TARGET="$DE_SHA" \
  > /dev/null 2> "$SANDBOX/mf-de.log"
MF_DE_RC=$?
if [[ "$MF_DE_RC" -eq 0 ]]; then pass "materialize-frontend.sh materialized it"; else
  fail "materialize-frontend.sh materialized it (rc=$MF_DE_RC): $(tail -3 "$SANDBOX/mf-de.log" | tr '\n' ' ')"; fi
side_tree kairos-target "$SANDBOX/side-de"
DE_OUT=$SANDBOX/side-de/web
# The CLI is the authority; the diff is the contract. Both must agree about .env.
if diff -r "$SANDBOX/de-cli/$NAME" "$DE_OUT" > "$SANDBOX/de.diff" 2>&1; then
  pass "helper ≡ CLI on a module carrying .env / .env.local"
else
  fail "helper ≡ CLI drift on the dotfile module: $(head -5 "$SANDBOX/de.diff" | tr '\n' ' ')"
fi
expect "the CLI itself leaves .env verbatim (the fixture is not vacuous)" \
  bash -c "grep -q 'VITE_APP=<YOUR_COMPONENT_NAME>' '$SANDBOX/de-cli/$NAME/.env'"
expect ".env stays verbatim on the materialized side too — it has NO extension" \
  bash -c "grep -q 'VITE_APP=<YOUR_COMPONENT_NAME>' '$DE_OUT/.env' \
        && grep -q 'VITE_BARE=YOUR_COMPONENT_NAME' '$DE_OUT/.env'"
expect ".env.local DOES have a suffix (.local), which is not whitelisted either" \
  bash -c "grep -q 'VITE_APP=<YOUR_COMPONENT_NAME>' '$DE_OUT/.env.local'"
expect "and a whitelisted extension in the same tree was still substituted" \
  bash -c "grep -q '\"name\": \"$NAME\"' '$DE_OUT/package.json' \
        && grep -q '\"$NAME\"' '$DE_OUT/src/x.ts'"
git -C "$FRONTEND_REPO_DIR" worktree remove --force "$SANDBOX/de-wt" >/dev/null 2>&1 || true
fi

if t "apply_create_substitution: a failed filename rename is reported (WARN + count), not silently dropped"; then
# UNIT test of the helper itself (not through materialize-frontend.sh): a
# read-only parent directory makes the FILENAME-pass mv fail (EACCES) while
# leaving find's traversal (read+execute, still granted) unaffected. Root
# bypasses the mode bits entirely, so this arm is unexercised there — same
# skip convention as record-context.test.sh's failed-append arm.
if [[ "$(id -u)" -eq 0 ]]; then
  pass "rename-failure case skipped (running as root, chmod 0555 stays writable)"
  pass "rename-failure WARN message skipped (running as root)"
  pass "rename-failure summary count skipped (running as root)"
  pass "rename-failure placeholder-survives check skipped (running as root)"
else
RENDIR=$SANDBOX/fsub-rename
mkdir -p "$RENDIR"
# .foo is not a whitelisted extension, so the CONTENT pass (which needs to write
# a new file in this same directory) skips this file outright — isolating the
# assertion to the FILENAME pass's mv, the thing this test is about.
echo 'placeholder' > "$RENDIR/YOUR_COMPONENT_NAME.foo"
chmod 0555 "$RENDIR"
( . "$SKILL_DIR/scripts/lib/frontend-substitute.sh"; apply_create_substitution "$RENDIR" "$NAME" ) \
  > "$SANDBOX/fsub-rename.out" 2> "$SANDBOX/fsub-rename.log"
FSUB_RC=$?
chmod 0755 "$RENDIR"
expect "apply_create_substitution still returns 0 (per-file skip, not an argument error)" \
  test "$FSUB_RC" -eq 0
expect "the failed rename is reported as a WARN naming the path" \
  grep -qF "WARN: apply_create_substitution: rename failed, left under placeholder name: $RENDIR/YOUR_COMPONENT_NAME.foo" \
  "$SANDBOX/fsub-rename.log"
expect "a trailing summary counts exactly one skipped rename" \
  grep -qx "WARN: apply_create_substitution: 1 filename rename(s) skipped (placeholder names left in place — see WARN lines above)" \
  "$SANDBOX/fsub-rename.log"
refute "the file was NOT silently left renamed under a name nobody warned about" \
  test -e "$RENDIR/$NAME.foo"
expect "the placeholder-named file itself survives untouched" \
  test -e "$RENDIR/YOUR_COMPONENT_NAME.foo"
fi
fi

if t "materialize-frontend.sh — refuses to rm -rf a caller-supplied FRONTEND_CACHE that is a working checkout (SC1 containment)"; then
# FRONTEND_CACHE is a caller-supplied env value. A non-bare working checkout has
# no top-level HEAD, so it falls to the establish branch, whose rm -rf would have
# deleted it and replaced it with a bare mirror — no prompt. pre-flight.sh ASSIGNS
# FRONTEND_CACHE=$RUN/frontend and ignores inbound values, making its identical
# rm -rf unreachable; this script accepts the value and must contain it itself.
SC1_RUN=$SANDBOX/sc1-run; mkdir -p "$SC1_RUN"
VICTIM=$SANDBOX/fe-victim
mkdir -p "$VICTIM" \
  && ( cd "$VICTIM" && git init -q -b main && echo precious > precious.txt \
        && git add -A && git -c user.email=t@t -c user.name=t commit -qm v )
( cd "$COMP" && env PHASE_KEY="$PK_MATERIALIZE" RUN="$SC1_RUN" \
    BASE="$FRONTEND_BASE_SHA" TARGET="$FRONTEND_TARGET_SHA" \
    FRONTEND_PATH="$FRONTEND_REPO_DIR" MODULE_PATH=template/react \
    FRONTEND_CACHE="$VICTIM" "$MF" ) > /dev/null 2> "$SANDBOX/mf-victim.log"
VIC_RC=$?
expect "the run refuses (exit non-zero) rather than deleting the checkout" \
  test "$VIC_RC" -ne 0
expect "the refusal explains it will not rm -rf a caller-supplied path" \
  grep -qF "refusing to 'rm -rf'" "$SANDBOX/mf-victim.log"
expect "the working checkout's file is left intact" test -f "$VICTIM/precious.txt"
expect "the working checkout's git dir survives" test -d "$VICTIM/.git"
fi

if t "materialize-frontend.sh — a byte-different but same-path origin reuses the mirror (origins_match, not a full re-clone)"; then
# pre-flight check 7's rule is origins_match, which NORMALIZES local paths before
# comparing; a byte comparison re-clones the whole monorepo when the same repo is
# named once relative/trailing-slash and once absolute. The mirror below records
# the origin with no trailing slash; the run passes it WITH one — same repo, and
# the reuse-refresh path must fire.
OM_RUN=$SANDBOX/om-run; mkdir -p "$OM_RUN"
OM_MIRROR=$SANDBOX/om-mirror
git clone --mirror "$FRONTEND_REPO_DIR" "$OM_MIRROR" >/dev/null 2>&1
( cd "$COMP" && env PHASE_KEY="$PK_MATERIALIZE" RUN="$OM_RUN" \
    BASE="$FRONTEND_BASE_SHA" TARGET="$FRONTEND_TARGET_SHA" \
    FRONTEND_PATH="$FRONTEND_REPO_DIR/" MODULE_PATH=template/react \
    FRONTEND_CACHE="$OM_MIRROR" "$MF" ) > /dev/null 2> "$SANDBOX/mf-om.log"
expect "a trailing-slash spelling of the same origin REUSES the mirror, not re-clones" \
  grep -qF 'refreshed existing frontend mirror' "$SANDBOX/mf-om.log"
fi

finish_suite
