#!/usr/bin/env bash
# template-parity.test.sh — tests for scripts/template-parity.sh
# Tested at the script seam: env in (RUN, SYNTH, cwd=component), exit code +
# the written $RUN/template-parity.tsv out, never internals. TEST_FILTER supported.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

TP="$SKILL_DIR/scripts/template-parity.sh"

# --- helpers -----------------------------------------------------------------
gcommit() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm "$2" --allow-empty >/dev/null 2>&1; }

# mk <dir> — build an empty SYNTH (with the kairos-target tag) and COMP git repo,
# plus a RUN dir. Callers add files with tmpl/comp below, then commit_all + run_tp.
# Sets globals SYNTH COMP RUN D.
#
# RUN lives INSIDE the component work tree at .kairos/migration/state — where a real
# run puts it — NOT a sibling of comp/. A sibling RUN meant $RUN/frontend-parity-target
# (the frontend basis) sat outside any repo, so `git hash-object --stdin-paths` resolved
# relative to cwd and the git-2.50 repo-root-resolution bug (F11) never fired in these
# fixtures. It is created (empty) before the commits and populated only at script-run
# time, so it stays untracked and never enters `git ls-files`.
mk() {
  D=$1; SYNTH=$D/synth; COMP=$D/comp; RUN=$COMP/.kairos/migration/state
  mkdir -p "$SYNTH" "$COMP" "$RUN"
  git -C "$SYNTH" init -q -b main
  git -C "$COMP"  init -q -b main
}
tmpl() { mkdir -p "$SYNTH/$(dirname "$1")"; printf '%b' "$2" > "$SYNTH/$1"; }   # tmpl <path> <content>
comp() { mkdir -p "$COMP/$(dirname "$1")";  printf '%b' "$2" > "$COMP/$1"; }    # comp <path> <content>
seal_target() { gcommit "$SYNTH" target; git -C "$SYNTH" tag -f kairos-target >/dev/null 2>&1; }
seal_comp()   { gcommit "$COMP" tree; }
run_tp() { ( cd "$COMP" && RUN="$RUN" SYNTH="$SYNTH" "$TP" ) > "$D/out" 2> "$D/err"; RC=$?; }
OUTF() { echo "$RUN/template-parity.tsv"; }
row_status() { awk -F'\t' -v p="$1" '$1==p{print $2}' "$(OUTF)"; }   # row_status <path>

# =============================================================================
if t "a template file present in the component with identical content is not a finding"; then
mk "$SANDBOX/present"
tmpl a/f.go 'package a\n'; comp a/f.go 'package a\n'
seal_target; seal_comp
run_tp
expect "exit 0" test "$RC" -eq 0
expect "artifact written" test -f "$(OUTF)"
expect "summary reports zero absent" grep -q '0 template path(s) absent' "$(OUTF)"
expect "no data row for the present file" test -z "$(row_status a/f.go)"
fi

# =============================================================================
if t "a template file present but MODIFIED is not a finding (absent-only, never present-but-changed)"; then
mk "$SANDBOX/modified"
tmpl a/f.go 'package a // template\n'; comp a/f.go 'package a // component custom\n'
seal_target; seal_comp
run_tp
expect "exit 0" test "$RC" -eq 0
expect "modified-but-present file is NOT reported" test -z "$(row_status a/f.go)"
expect "summary reports zero absent" grep -q '0 template path(s) absent' "$(OUTF)"
fi

# =============================================================================
if t "a template file with no counterpart in the component -> status absent"; then
mk "$SANDBOX/absent"
tmpl docs/event-handler.md '# EH\n'; comp README.md 'x\n'
seal_target; seal_comp
run_tp
expect "exit 0" test "$RC" -eq 0
expect "status is absent" test "$(row_status docs/event-handler.md)" = "absent"
expect "summary counts one absent" grep -q 'absent=1 relocated=0 rename?=0' "$(OUTF)"
fi

# =============================================================================
if t "an exact-content move -> status relocated, detail names the other path"; then
mk "$SANDBOX/relocated"
# template ships app_config.go; the component keeps the SAME bytes at config.go.
tmpl internal/eh/config/app_config.go 'package config\ntype AppConfig struct{}\n'
comp internal/eh/config/config.go     'package config\ntype AppConfig struct{}\n'
seal_target; seal_comp
run_tp
expect "exit 0" test "$RC" -eq 0
expect "status is relocated" test "$(row_status internal/eh/config/app_config.go)" = "relocated"
expect "detail names the component path" \
  grep -q 'identical content at: internal/eh/config/config.go' "$(OUTF)"
fi

# =============================================================================
if t "an absent template file with a same-dir/ext component-only sibling -> status rename?"; then
mk "$SANDBOX/rename"
# bodies DIFFER (a renamed file that also changed), so no oid match — the same-dir,
# same-ext component-only sibling is the hint.
tmpl internal/eh/config/app_config_test.go 'package config\nfunc TestValidateAppConfig(t *T){}\n'
comp internal/eh/config/config_test.go     'package config\nfunc TestValidateAppConfigValidConfig(t *T){}\n'
seal_target; seal_comp
run_tp
expect "exit 0" test "$RC" -eq 0
expect "status is rename?" test "$(row_status internal/eh/config/app_config_test.go)" = "rename?"
expect "detail names the sibling candidate" \
  grep -q 'same dir/ext component-only file(s): internal/eh/config/config_test.go' "$(OUTF)"
fi

# =============================================================================
if t "an intent-guarded deliberate absence is subtracted, not reported"; then
mk "$SANDBOX/guarded"
tmpl sql/README.md '# sql\n'; comp go.mod 'module x\n'
seal_target; seal_comp
# a vetted active entry whose guard asserts the path is deliberately absent
printf -- '- 2026-01-01: sql/README.md deliberately deleted\n  guard: test ! -e sql/README.md\n' \
  > "$RUN/intent-active.md"
run_tp
expect "exit 0" test "$RC" -eq 0
expect "guarded path is NOT reported" test -z "$(row_status sql/README.md)"
expect "summary reports zero absent" grep -q '0 template path(s) absent' "$(OUTF)"
expect "summary counts one guarded subtraction" grep -q '1 intent-guarded absence(s) subtracted' "$(OUTF)"
fi

# =============================================================================
if t "a non-ASCII intent-guarded absence is still subtracted (both sides compare unquoted)"; then
mk "$SANDBOX/guarded-nonascii"
# The template ships a path with a byte >= 0x80. git C-quotes such a path by default
# (`"docs/caf\303\251.md"`), but the guard in intent-active.md carries the literal
# UTF-8 spelling — so without core.quotePath=false the quoted ls-tree path never
# matches the raw guard key and the dispositioned absence cries wolf every migration.
tmpl 'docs/café.md' '# cafe\n'; comp go.mod 'module x\n'
seal_target; seal_comp
printf -- '- 2026-01-01: docs/café.md deliberately deleted\n  guard: test ! -e docs/café.md\n' \
  > "$RUN/intent-active.md"
run_tp
expect "exit 0" test "$RC" -eq 0
expect "the non-ASCII guarded path is NOT reported" test -z "$(row_status 'docs/café.md')"
expect "no C-quoted spelling of it is reported either" \
  bash -c "! grep -q 'caf.303.251' '$(OUTF)'"
expect "summary counts one guarded subtraction" grep -q '1 intent-guarded absence(s) subtracted' "$(OUTF)"
fi

# =============================================================================
if t "the subtracted count is guards that suppressed a finding, not guards merely present"; then
mk "$SANDBOX/guard-nomatch"
# template parity is clean (a/f.go present in both), and the lone absence guard
# names a path that is NOT a template finding — so it suppresses nothing.
tmpl a/f.go 'x\n'; comp a/f.go 'x\n'
seal_target; seal_comp
printf -- '- 2026-01-01: docs/gone.md deliberately absent\n  guard: test ! -e docs/gone.md\n' \
  > "$RUN/intent-active.md"
run_tp
expect "exit 0" test "$RC" -eq 0
expect "a guard present but matching no finding counts as zero subtracted" \
  grep -q '0 intent-guarded absence(s) subtracted' "$(OUTF)"
fi

# =============================================================================
if t "without intent-active.md nothing is subtracted and the summary says so"; then
mk "$SANDBOX/noguard"
tmpl sql/README.md '# sql\n'; comp go.mod 'module x\n'
seal_target; seal_comp
run_tp
expect "exit 0" test "$RC" -eq 0
expect "the path IS reported (safe under-exclusion)" test "$(row_status sql/README.md)" = "absent"
expect "summary notes no subtraction was applied" grep -q 'no intent-active.md' "$(OUTF)"
fi

# =============================================================================
if t "zero findings still writes the artifact as positive evidence"; then
mk "$SANDBOX/zero"
tmpl a/f.go 'x\n'; comp a/f.go 'x\n'
seal_target; seal_comp
run_tp
expect "exit 0" test "$RC" -eq 0
expect "artifact exists even with zero findings" test -f "$(OUTF)"
expect "it is not empty (carries the summary line)" test -s "$(OUTF)"
fi

# =============================================================================
if t "SYNTH unset -> exit 2, no artifact written"; then
mk "$SANDBOX/nosynth"
comp go.mod 'x\n'; seal_comp
( cd "$COMP" && RUN="$RUN" "$TP" ) > "$D/out" 2> "$D/err"; RC=$?
expect "exit 2 (skip that escalates)" test "$RC" -eq 2
expect "no artifact written" test ! -e "$(OUTF)"
expect "stderr explains the skip" grep -qi 'SYNTH not set' "$D/err"
fi

# =============================================================================
if t "missing kairos-target tag -> exit 2, no artifact written"; then
mk "$SANDBOX/notag"
comp go.mod 'x\n'; seal_comp
# SYNTH is a repo but carries no kairos-target tag
git -C "$SYNTH" commit -q --allow-empty -m empty >/dev/null 2>&1
run_tp
expect "exit 2 (skip that escalates)" test "$RC" -eq 2
expect "no artifact written" test ! -e "$(OUTF)"
expect "stderr names the missing tag" grep -qi 'kairos-target' "$D/err"
fi

# =============================================================================
if t "a failed git ls-tree during basis derivation is a hard skip, never an empty (false-positive) parity report"; then
mk "$SANDBOX/lstreefail"
tmpl a/f.go 'package a\n'
seal_target; seal_comp
# Shim `git` to fail only its `ls-tree` subcommand (any earlier rev-parse probe
# still succeeds against the real binary) — reproduces an unguarded ls-tree|awk
# pipeline: without the check, awk sees empty stdin and $TMPL comes out empty,
# which reads as "the target ships nothing" (zero findings, positive evidence)
# instead of the hard error a failed basis derivation actually is.
GLS=$SANDBOX/lstreefail-gitshim; mkdir -p "$GLS"
GLS_REALGIT=$(command -v git)
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do [ "$a" = ls-tree ] && { echo "fatal: shim forced ls-tree failure" >&2; exit 128; }; done\n'
  printf 'exec %s "$@"\n' "$GLS_REALGIT"
} > "$GLS/git"
chmod +x "$GLS/git"
( cd "$COMP" && PATH="$GLS:$PATH" RUN="$RUN" SYNTH="$SYNTH" "$TP" ) > "$D/out" 2> "$D/err"; RC=$?
expect "exit 2 (skip that escalates), never a clean zero-finding report" test "$RC" -eq 2
expect "no artifact written" test ! -e "$(OUTF)"
expect "stderr names git ls-tree as the failed step" grep -qi 'ls-tree' "$D/err"
fi

# =============================================================================
if t "a mid-scan death of the classify awk pass is a hard skip, not a COUNTS line parsed out of its own error text"; then
mk "$SANDBOX/awkdeath"
tmpl a/f.go 'package a\n'
seal_target; seal_comp
# Shim `awk` to fail only the classify invocation (identified by the `@@COUNTS@@`
# marker literal in its program text — the TMPL/COMP-building awk calls carry no
# such string and still run for real). Reproduces the mid-scan awk death this
# check exists for: the `@@COUNTS@@` line and awk's own stderr shared one file,
# so a died-before-END awk got its error text `read` into ABSENT/RELOCATED/... as
# if it were the real counts, silently defaulting to a clean zero-finding report.
AWS=$SANDBOX/awkdeath-awkshim; mkdir -p "$AWS"
AWS_REALAWK=$(command -v awk)
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do case "$a" in *COUNTS*) echo "FATAL: shim forced classify awk failure" >&2; exit 2 ;; esac; done\n'
  printf 'exec %s "$@"\n' "$AWS_REALAWK"
} > "$AWS/awk"
chmod +x "$AWS/awk"
( cd "$COMP" && PATH="$AWS:$PATH" RUN="$RUN" SYNTH="$SYNTH" "$TP" ) > "$D/out" 2> "$D/err"; RC=$?
expect "exit 2 (skip that escalates), never a clean zero-finding report" test "$RC" -eq 2
expect "no artifact written" test ! -e "$(OUTF)"
expect "stderr surfaces the classify pass's own failure" \
  grep -qi 'classif' "$D/err"
fi

# =============================================================================
# The FRONTEND arm (MOUNT set) — PRD "Presence / parity": compare the SUBSTITUTED
# frontend TARGET tree mapped onto the mount against the component's mount, never the
# CLI component tree that strips web/.
# =============================================================================
setup_frontend_fixture
cd "$SANDBOX"

# fe_mk <dir> — a component (name: acme) whose web/ is the react module at the
# frontend BASE, substituted the way `component create` substitutes it, plus one
# local customization — i.e. exactly the shape a real component's mount has.
fe_mk() {
  # RUN inside the component work tree (.kairos/migration/state), the faithful shape:
  # the frontend basis materialized under $RUN/frontend-parity-target then sits INSIDE
  # the repo, so `git hash-object --stdin-paths` discovers it and the F11 repo-root
  # resolution path is actually exercised by every frontend-arm test below. Empty at
  # commit time, populated only at script-run time → stays untracked, never ls-files'd.
  D=$1; COMP=$D/comp; RUN=$COMP/.kairos/migration/state
  mkdir -p "$COMP/.kairos" "$RUN"
  git -C "$COMP" init -q -b main
  printf 'name: acme\n' > "$COMP/.kairos/manifest.yaml"
  ( cd "$COMP" && git add -A && git commit -qm init >/dev/null 2>&1 )
  add_frontend_to_component "$COMP" with-block >/dev/null 2>&1
  cd "$SANDBOX"
}
# run_fe [extra env...] — the frontend arm, basis built from the fixture repo.
run_fe() {
  ( cd "$COMP" && RUN="$RUN" MOUNT=web/ FE_CACHE="$FRONTEND_REPO_DIR" \
      FE_TARGET="$FRONTEND_TARGET_SHA" FE_MODULE_PATH=template/react "$@" "$TP" \
  ) > "$D/out" 2> "$D/err"; RC=$?
}

if t "the frontend arm compares the substituted TARGET subtree against the mount: a mount at the baseline with no removals is zero findings"; then
fe_mk "$SANDBOX/fe-clean"
run_fe
expect "exit 0" test "$RC" -eq 0
expect "artifact written" test -f "$(OUTF)"
expect "zero findings — the target's files are all present in the mount (content drift is the merge's job)" \
  grep -q '0 template path(s) absent' "$(OUTF)"
expect "the artifact names its basis: the module, the commit, and the mount it was mapped onto" \
  bash -c "grep -q 'Basis: frontend module template/react' '$(OUTF)' && grep -q 'mapped onto web/' '$(OUTF)'"
expect "the substituted basis is kept on disk for a restore disposition" \
  test -f "$RUN/frontend-parity-target/package.json"
expect "the kept basis is SUBSTITUTED, not raw (no create-time placeholder survives)" \
  bash -c "! grep -q 'YOUR_BC_NAME' '$RUN/frontend-parity-target/package.json'"
fi

if t "a module file the mount does not have -> absent, and the row is MOUNT-mapped"; then
fe_mk "$SANDBOX/fe-absent"
( cd "$COMP" && git rm -q web/eslint.config.js && git commit -qm "drop eslint config" >/dev/null 2>&1 )
run_fe
expect "exit 0" test "$RC" -eq 0
expect "the row is reported at its MOUNT path, not the subtree path" \
  test "$(row_status web/eslint.config.js)" = "absent"
expect "the subtree-relative path is never a row (an unmapped basis would call every file absent)" \
  test -z "$(row_status eslint.config.js)"
expect "summary counts exactly one absent" grep -q 'absent=1 relocated=0 rename?=0' "$(OUTF)"
fi

if t "frontend arm: a mount file present on disk but hidden by a root .gitignore is 'untracked', never 'absent'"; then
# Regression (F10): the component side is `git ls-files` (tracked-only). A Go backend's
# ROOT .gitignore (*.local, .env*, dist/, …) can hide a mount file that is present on
# disk and a genuine frontend deliverable. Reporting it `absent` drove a spurious Phase 8
# `restore` that would force-add or clobber the user's own file. It must read `untracked`.
fe_mk "$SANDBOX/fe-untracked"
( cd "$COMP"
  printf 'eslint.config.js\n' >> .gitignore     # root rule now hides the mount file
  git rm --cached -q web/eslint.config.js         # untrack it, but KEEP it on disk
  git add .gitignore && git commit -qm "ignore eslint config" >/dev/null 2>&1 )
# It really is still on disk and really is git-ignored (the exact trigger shape).
expect "the mount file is present in the working tree" test -f "$COMP/web/eslint.config.js"
expect "and git ls-files no longer tracks it" \
  bash -c "! ( cd '$COMP' && git ls-files --error-unmatch web/eslint.config.js >/dev/null 2>&1 )"
run_fe
expect "exit 0" test "$RC" -eq 0
expect "the present-but-ignored mount file reads 'untracked', NOT 'absent'" \
  test "$(row_status web/eslint.config.js)" = "untracked"
refute "it is never classified absent (which would drive a spurious restore)" \
  bash -c "test \"\$(row_status web/eslint.config.js)\" = absent"
expect "the absent count is zero — nothing is actually missing" \
  grep -q 'absent=0 relocated=0 rename?=0' "$(OUTF)"
expect "the report surfaces the present-but-uncommitted file distinctly" \
  grep -q 'untracked/ignored' "$(OUTF)"
fi

if t "a token-bearing module file kept under another name -> relocated, which only matches because the basis was SUBSTITUTED"; then
# index.html carries <YOUR_COMPONENT_NAME> in the template and the component's own
# name in the mount. An oid match is byte-exact, so this row is `relocated` ONLY if
# the create-time replacement map was applied to the basis; a raw subtree basis would
# report it as rename?/absent instead. This is the substitution-awareness test.
fe_mk "$SANDBOX/fe-reloc"
( cd "$COMP" && git mv web/index.html web/app.html && git commit -qm "rename index.html" >/dev/null 2>&1 )
run_fe
expect "exit 0" test "$RC" -eq 0
expect "status is relocated" test "$(row_status web/index.html)" = "relocated"
expect "detail names the component-side path" grep -q 'identical content at: web/app.html' "$(OUTF)"
fi

if t "an absent module file with a same-dir/ext mount sibling -> rename?"; then
fe_mk "$SANDBOX/fe-rename"
( cd "$COMP" && git mv web/src/App.tsx web/src/AppRoot.tsx \
    && printf '\n// diverged further\n' >> web/src/AppRoot.tsx \
    && git add -A && git commit -qm "rename App.tsx and change it" >/dev/null 2>&1 )
run_fe
expect "exit 0" test "$RC" -eq 0
expect "status is rename?" test "$(row_status web/src/App.tsx)" = "rename?"
expect "detail names the same-dir/ext candidate" grep -q 'web/src/AppRoot.tsx' "$(OUTF)"
fi

if t "an intent-guarded deliberate absence under the mount is subtracted on the frontend arm too"; then
fe_mk "$SANDBOX/fe-guard"
( cd "$COMP" && git rm -q web/eslint.config.js && git commit -qm "drop eslint config" >/dev/null 2>&1 )
cat > "$RUN/intent-active.md" <<'EOF'
- web/eslint.config.js is deliberately absent — the team lints from the repo root
  guard: test ! -e web/eslint.config.js
EOF
run_fe
expect "exit 0" test "$RC" -eq 0
expect "the guarded absence is not reported" test -z "$(row_status web/eslint.config.js)"
expect "the summary counts it as subtracted" grep -q '1 intent-guarded absence(s) subtracted' "$(OUTF)"
fi

if t "an already-substituted basis can be supplied directly with FE_TARGET_TREE"; then
# The seam for a run whose materialize step already built the substituted target
# tree: same rows, no re-extraction, and no frontend-parity-target/ of our own.
fe_mk "$SANDBOX/fe-supplied"
( cd "$COMP" && git rm -q web/eslint.config.js && git commit -qm "drop eslint config" >/dev/null 2>&1 )
SUPPLIED=$SANDBOX/fe-supplied/tree
mkdir -p "$SUPPLIED"
git -C "$FRONTEND_REPO_DIR" archive "$FRONTEND_TARGET_SHA:template/react" | tar -x -C "$SUPPLIED"
# shellcheck source=../scripts/lib/frontend-substitute.sh
. "$SKILL_DIR/scripts/lib/frontend-substitute.sh"
apply_create_substitution "$SUPPLIED" acme >/dev/null
( cd "$COMP" && RUN="$RUN" MOUNT=web/ FE_TARGET_TREE="$SUPPLIED" "$TP" ) > "$D/out" 2> "$D/err"; RC=$?
expect "exit 0" test "$RC" -eq 0
expect "the same absent row is reported from the supplied basis" \
  test "$(row_status web/eslint.config.js)" = "absent"
expect "the artifact names the supplied tree as its basis" grep -q "Basis: the supplied substituted target tree" "$(OUTF)"
expect "no basis of our own was materialized" test ! -d "$RUN/frontend-parity-target"
fi

if t "frontend arm: a basis INSIDE the work tree hashes against the basis, not the repo root (git 2.50 --stdin-paths)"; then
# Regression (F11): git >= 2.50 `hash-object --stdin-paths` resolves each RELATIVE path
# against the repo ROOT, not cwd — so the real basis at $RUN/frontend-parity-target
# (inside the component work tree, unlike the sibling-dir fixtures above) made every
# basis-only file abort the whole scan with "could not open '<relpath>'" → SKIP, and a
# relpath that also existed at the repo root silently hashed the WRONG blob. The fix
# feeds absolute paths. This case reproduces the abort by putting $RUN — and the basis —
# INSIDE the work tree, the way a real migration does.
D=$SANDBOX/fe-hashpath; COMP=$D/comp; RUN=$COMP/.kairos/migration/state
mkdir -p "$COMP/web" "$RUN"
( cd "$COMP" && git init -q -b main >/dev/null 2>&1 )
printf 'name: acme\n' > "$COMP/.kairos/manifest.yaml"
printf '.kairos/\n' > "$COMP/.gitignore"
# The mount HAS the basis file — its relpath (marker.tsx) exists at web/, NOT at the
# component root, so pre-fix the root-relative hash lookup could not open it.
printf 'export const Marker = 1\n' > "$COMP/web/marker.tsx"
( cd "$COMP" && git add -A && git commit -qm init >/dev/null 2>&1 )
# Supplied basis INSIDE the work tree (under the gitignored $RUN, exactly where the real
# frontend-parity-target lives). Its one file's relpath does not exist at the repo root.
SUP=$RUN/supplied-basis; mkdir -p "$SUP"
printf 'export const Marker = 1\n' > "$SUP/marker.tsx"
( cd "$COMP" && RUN="$RUN" MOUNT=web/ FE_TARGET_TREE="$SUP" "$TP" ) > "$D/out" 2> "$D/err"; RC=$?
expect "the scan COMPLETES (exit 0) — it does not abort with a SKIP on a basis-only file" test "$RC" -eq 0
expect "the artifact is written, not skipped" test -f "$RUN/template-parity.tsv"
expect "the basis file present at the mount is parity-OK, never a false absent" \
  test -z "$(awk -F'\t' '$1=="web/marker.tsx"{print $2}' "$RUN/template-parity.tsv")"
expect "zero absent — the mount ships everything the basis does" \
  grep -q 'absent=0 relocated=0 rename?=0' "$RUN/template-parity.tsv"
cd "$SANDBOX"
fi

if t "a non-ASCII module file PRESENT in the mount is not reported absent (basis find is raw, ls-files must be too)"; then
# The frontend basis is walked with `find` (raw UTF-8), while the component side is
# `git ls-files -s`, which C-quotes any byte >= 0x80 by default. Left on, a file with
# a non-ASCII name present in the mount reads as `absent` on the two sides' differing
# spellings — a `restore` disposition would then overwrite the component's own copy.
# Supplied-basis path so the fixture carries the file on both sides deterministically.
fe_mk "$SANDBOX/fe-nonascii"
( cd "$COMP" && mkdir -p web/src && printf 'x' > 'web/src/café.tsx' \
  && git add -A && git commit -qm "mount carries a non-ASCII file" >/dev/null 2>&1 )
SUP=$SANDBOX/fe-nonascii/tree; mkdir -p "$SUP/src"; printf 'x' > "$SUP/src/café.tsx"
( cd "$COMP" && RUN="$RUN" MOUNT=web/ FE_TARGET_TREE="$SUP" "$TP" ) > "$D/out" 2> "$D/err"; RC=$?
expect "exit 0" test "$RC" -eq 0
expect "the present non-ASCII file is NOT reported absent" test -z "$(row_status 'web/src/café.tsx')"
expect "no C-quoted spelling of it is reported either" \
  bash -c "! grep -q 'caf.303.251' '$(OUTF)'"
expect "the basis had exactly that one file and it is present -> zero findings" \
  grep -q '0 template path(s) absent' "$(OUTF)"
fi

if t "the frontend arm skips (exit 2, no artifact) when it has no usable basis"; then
fe_mk "$SANDBOX/fe-skip"
( cd "$COMP" && RUN="$RUN" MOUNT=web/ "$TP" ) > "$D/out" 2> "$D/err"; RC=$?
expect "exit 2 with neither FE_TARGET_TREE nor the FE_CACHE trio" test "$RC" -eq 2
expect "no artifact written" test ! -f "$(OUTF)"
expect "the skip names what it needed" grep -q 'FE_TARGET_TREE or all of FE_CACHE' "$D/err"
( cd "$COMP" && RUN="$RUN" MOUNT=web/ FE_CACHE="$FRONTEND_REPO_DIR" FE_TARGET=deadbeefdeadbeef \
    FE_MODULE_PATH=template/react "$TP" ) > "$D/out" 2> "$D/err"; RC=$?
expect "an unresolvable target is exit 2" test "$RC" -eq 2
expect "still no artifact" test ! -f "$(OUTF)"
EMPTY=$SANDBOX/fe-skip/empty; mkdir -p "$EMPTY"
( cd "$COMP" && RUN="$RUN" MOUNT=web/ FE_TARGET_TREE="$EMPTY" "$TP" ) > "$D/out" 2> "$D/err"; RC=$?
expect "an EMPTY basis is exit 2, never 'nothing is missing'" test "$RC" -eq 2
expect "the empty-basis skip says so" grep -q "contains no files" "$D/err"
expect "still no artifact" test ! -f "$(OUTF)"
fi

if t "MOUNT unset or empty is the template arm, unchanged"; then
mk "$SANDBOX/fe-tmplarm"
tmpl docs/x.md '# x\n'; comp README.md 'x\n'
seal_target; seal_comp
run_tp
cp "$(OUTF)" "$SANDBOX/fe-tmplarm.snap"
( cd "$COMP" && RUN="$RUN" SYNTH="$SYNTH" MOUNT='' "$TP" ) > "$D/out" 2> "$D/err"; RC=$?
expect "exit 0" test "$RC" -eq 0
expect "an empty MOUNT takes the template arm and produces the identical artifact" \
  cmp -s "$SANDBOX/fe-tmplarm.snap" "$(OUTF)"
fi

if t "the frontend basis lists SYMLINKS too: a shipped link the mount lacks is a finding"; then
# S8: the template arm lists every blob in the target tree, 120000 (symlink) blobs
# included, so a files-only walk on the frontend arm made a shipped symlink the one
# absence this check can never report — on exactly the arm where the mount IS the
# deliverable. A symlink's blob is its LINK TEXT, which is what `git ls-files -s`
# reports for the component side, so both sides have to be hashed that way too.
( cd "$FRONTEND_REPO_DIR" \
  && ln -sfn src/App.tsx template/react/app-entry.tsx \
  && git add -A && git commit -qm "fixture: the module ships a symlink" ) >/dev/null 2>&1
FE_LINK_SHA=$(git -C "$FRONTEND_REPO_DIR" rev-parse HEAD)
expect "the fixture really committed a symlink (120000)" \
  bash -c "git -C '$FRONTEND_REPO_DIR' ls-tree '$FE_LINK_SHA' template/react/app-entry.tsx | grep -q '^120000'"

fe_mk "$SANDBOX/fe-symlink-absent"
( cd "$COMP" && RUN="$RUN" MOUNT=web/ FE_CACHE="$FRONTEND_REPO_DIR" \
    FE_TARGET="$FE_LINK_SHA" FE_MODULE_PATH=template/react "$TP" \
) > "$D/out" 2> "$D/err"; RC=$?
expect "exit 0" test "$RC" -eq 0
expect "the symlink the module ships and the mount lacks is reported at its mount path" \
  test "$(row_status web/app-entry.tsx)" = "absent"

# And the other direction: the SAME link kept under another name in the mount is
# `relocated`, which is an OID match — it can only match if both sides hashed the LINK
# TEXT. Hashing through the link would give App.tsx's content oid and this row would
# come back rename?/absent instead.
fe_mk "$SANDBOX/fe-symlink-reloc"
( cd "$COMP" && ln -sfn src/App.tsx web/alias-entry.tsx \
  && git add -A && git commit -qm "mount keeps the link under its own name" ) >/dev/null 2>&1
( cd "$COMP" && RUN="$RUN" MOUNT=web/ FE_CACHE="$FRONTEND_REPO_DIR" \
    FE_TARGET="$FE_LINK_SHA" FE_MODULE_PATH=template/react "$TP" \
) > "$D/out" 2> "$D/err"; RC=$?
expect "exit 0" test "$RC" -eq 0
if [[ "$(row_status web/app-entry.tsx)" = "relocated" ]]; then
  pass "the renamed symlink is relocated — both sides hashed the link TEXT, not the target's bytes"
else
  fail "the renamed symlink is relocated (got '$(row_status web/app-entry.tsx)' — the basis hashed through the link)"
fi
expect "and the detail names the mount path that carries it" \
  bash -c "grep -q 'web/alias-entry.tsx' '$(OUTF)'"
# Regular files still work in the same run — the two hashing passes are joined, not
# alternatives.
expect "a regular absent module file is still reported in the same scan" \
  bash -c "test -f '$(OUTF)' && grep -q 'template path(s) absent' '$(OUTF)'"
fi

if t "the frontend arm refuses when the replacement-map helper is missing, and says which file"; then
# S9: the source was unguarded, so a missing lib/ made the failure read as "the
# create-time substitution failed over this tree" — a claim about the TREE, pointing the
# reader at the wrong repo entirely.
TPBARE=$SANDBOX/tp-bare
mkdir -p "$TPBARE"
cp "$TP" "$TPBARE/template-parity.sh"
fe_mk "$SANDBOX/fe-nolib"
( cd "$COMP" && RUN="$RUN" MOUNT=web/ FE_CACHE="$FRONTEND_REPO_DIR" \
    FE_TARGET="$FRONTEND_TARGET_SHA" FE_MODULE_PATH=template/react \
    "$TPBARE/template-parity.sh" ) > "$D/out" 2> "$D/err"; RC=$?
expect "exit 2 (skip that escalates), not a bogus substitution failure" test "$RC" -eq 2
expect "no artifact written" test ! -e "$(OUTF)"
expect "the message names the missing helper by path" \
  grep -qF 'frontend-substitute.sh' "$D/err"
expect "and says it owns the create-time replacement map" \
  grep -qiF 'replacement map' "$D/err"
refute "it does not blame the tree for a substitution failure" \
  grep -qF 'the create-time substitution failed over' "$D/err"
fi

finish_suite
