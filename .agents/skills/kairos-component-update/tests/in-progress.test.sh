#!/usr/bin/env bash
# in-progress.test.sh — tests for scripts/in-progress.sh
# TEST_FILTER supported (blocks are independent; each builds its own manifest).
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

bootstrap_suite

IPS="$SKILL_DIR/scripts/in-progress.sh"
PK_BRANCH=$(phase_key 4-migration-branch.md)

# ip_fixture <dir> — a component dir carrying a pre-migration manifest.
ip_fixture() {
  rm -rf "$1"; mkdir -p "$1/.kairos"
  cat > "$1/.kairos/manifest.yaml" <<'EOF'
name: mycomp
template:
  repo: file:///srv/template.git
  sha: 1111111111111111111111111111111111111111
  branch: main
EOF
}

if t "in-progress.sh advance — writes the baseline and touches nothing else"; then
# This block PINS the interface:
#   ACTION=advance, env in TARGET_SHA (required) and BRANCH (optional), carrying
#   Phase 8's key. It writes template.sha — and template.branch only when BRANCH is
#   explicitly given — and verifies the read-back before the bytes land.
#   WHY it is a script at all: this is the run's DELIVERABLE, the file the NEXT
#   migration reads as BASE. Phase 8 stated the two assignments in prose with no
#   command, and the model improvised a yq line. A write that looks fine and is
#   wrong (a dropped `bootstrapped:`, a reflowed file, a short SHA) poisons every
#   future run's baseline, and nothing reads it again until the next migration.
#   Being the deliverable is an argument FOR a checked writer, not against one.
IP=$SANDBOX/ip-advance
ip_fixture "$IP"

( cd "$IP" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=4444444444444444444444444444444444444444 \
    bash "$IPS" ) > "$SANDBOX/ip-adv.out" 2> "$SANDBOX/ip-adv.err"; rc=$?
expect "advance exits 0" test "$rc" -eq 0
expect "advance writes template.sha" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 4444444444444444444444444444444444444444"
expect "advance leaves template.branch untouched when BRANCH is not given" \
  bash -c "test \"\$(yq -r '.template.branch' '$IP/.kairos/manifest.yaml')\" = main"
expect "advance leaves template.repo intact" \
  bash -c "test \"\$(yq -r '.template.repo' '$IP/.kairos/manifest.yaml')\" = file:///srv/template.git"
expect "advance leaves the component name intact" \
  bash -c "test \"\$(yq -r '.name' '$IP/.kairos/manifest.yaml')\" = mycomp"

# BRANCH, when explicitly targeted, is written too.
( cd "$IP" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=5555555555555555555555555555555555555555 BRANCH=feat/x bash "$IPS" ) >/dev/null 2>&1
expect "advance writes template.branch when BRANCH is given" \
  bash -c "test \"\$(yq -r '.template.branch' '$IP/.kairos/manifest.yaml')\" = feat/x"
expect "advance still writes template.sha alongside the branch" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 5555555555555555555555555555555555555555"

fi

if t "in-progress.sh advance — moves a repo on the old Bitbucket SSH host to ssh.bitbucket.org"; then
# Bitbucket serves SSH only on ssh.bitbucket.org after 2026-11-12. Pre-flight clones
# from the mapped URL; advance writes the same mapping back in the SAME rewrite as the
# sha, so it rides the baseline commit. HTTPS (still served by bitbucket.org), other
# hosts and an already-current URL are left exactly as written.
for case_ in \
  'git@bitbucket.org:ifs-pd/kairos-component-template.git|git@ssh.bitbucket.org:ifs-pd/kairos-component-template.git' \
  'ssh://git@bitbucket.org/ifs-pd/kairos-component-template.git|ssh://git@ssh.bitbucket.org/ifs-pd/kairos-component-template.git' \
  'git@ssh.bitbucket.org:ifs-pd/kairos-component-template.git|git@ssh.bitbucket.org:ifs-pd/kairos-component-template.git' \
  'https://bitbucket.org/ifs-pd/kairos-component-template.git|https://bitbucket.org/ifs-pd/kairos-component-template.git'; do
  from=${case_%%|*}; want=${case_#*|}
  IP=$SANDBOX/ip-advance-repo
  ip_fixture "$IP"
  REPO_FROM=$from yq -i '.template.repo = strenv(REPO_FROM)' "$IP/.kairos/manifest.yaml"
  ( cd "$IP" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
      TARGET_SHA=4444444444444444444444444444444444444444 bash "$IPS" ) >/dev/null 2>&1; rc=$?
  expect "advance exits 0 for template.repo=$from" test "$rc" -eq 0
  expect "advance records template.repo=$want for $from" \
    bash -c "test \"\$(yq -r '.template.repo' '$IP/.kairos/manifest.yaml')\" = '$want'"
  expect "advance still writes template.sha alongside the repo ($from)" \
    bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 4444444444444444444444444444444444444444"
done

# SOURCE=frontend moves frontend.repo, and never the template's.
IP=$SANDBOX/ip-advance-fe-repo
ip_fixture "$IP"
yq -i '.template.repo = "git@bitbucket.org:ifs-pd/kairos-component-template.git" |
       .frontend = {"repo": "git@bitbucket.org:ifs-pd/kairos-frontend.git", "path": "template/react",
                    "template": "react", "branch": "main", "sha": "2222222222222222222222222222222222222222"}' \
  "$IP/.kairos/manifest.yaml"
( cd "$IP" && ACTION=advance SOURCE=frontend PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=6666666666666666666666666666666666666666 bash "$IPS" ) >/dev/null 2>&1
expect "a frontend advance records frontend.repo on ssh.bitbucket.org" \
  bash -c "test \"\$(yq -r '.frontend.repo' '$IP/.kairos/manifest.yaml')\" = git@ssh.bitbucket.org:ifs-pd/kairos-frontend.git"
expect "a frontend advance leaves template.repo as written" \
  bash -c "test \"\$(yq -r '.template.repo' '$IP/.kairos/manifest.yaml')\" = git@bitbucket.org:ifs-pd/kairos-component-template.git"
fi

if t "in-progress.sh advance — refuses anything that is not a full SHA, and writes nothing"; then
# This block PINS the interface:
#   A short SHA, a ref name, or an empty value is refused and the manifest is
#   byte-identical afterwards. A short SHA is the dangerous one: it LOOKS right in
#   the file and every later `git rev-parse` against it may still resolve — until a
#   future run compares it to a full SHA and mis-reads the baseline.
IP=$SANDBOX/ip-adv-bad
ip_fixture "$IP"
cp "$IP/.kairos/manifest.yaml" "$SANDBOX/ip-adv-bad.orig"

for bad in "" "   " "4444444" "main" "4444444444444444444444444444444444444444x" "zzzz444444444444444444444444444444444444"; do
  ( cd "$IP" && ACTION=advance PHASE_KEY=$PK_FINALIZE TARGET_SHA="$bad" bash "$IPS" ) >/dev/null 2>&1; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    pass "advance refuses TARGET_SHA='$bad'"
  else
    fail "advance refuses TARGET_SHA='$bad' (rc=$rc)"
  fi
done
expect "a refused advance leaves the manifest byte-identical" \
  cmp -s "$SANDBOX/ip-adv-bad.orig" "$IP/.kairos/manifest.yaml"

fi

if t "in-progress.sh advance — preserves comments, key order and unknown keys"; then
# This block PINS the interface — and it is the hazard the script exists for.
#   A bootstrapped component's manifest carries `bootstrapped: true`, human
#   comments, and whatever key order it was written in. A `yq -i` that reflows the
#   file, or an improvised rewrite that drops a key it did not know about, poisons
#   the NEXT migration's baseline silently: the run that broke it has already ended.
IP=$SANDBOX/ip-adv-preserve
rm -rf "$IP"; mkdir -p "$IP/.kairos"
cat > "$IP/.kairos/manifest.yaml" <<'EOF'
# this component was bootstrapped by bellwether detection
bootstrapped: true
cli_version: skill-v1
name: mycomp
created_at: 2026-01-01T00:00:00Z
template:
  sha: 1111111111111111111111111111111111111111
  repo: file:///srv/template.git
  branch: main
future_key: keep-me
EOF

( cd "$IP" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=6666666666666666666666666666666666666666 bash "$IPS" ) >/dev/null 2>&1
M="$IP/.kairos/manifest.yaml"
expect "advance kept bootstrapped: true" bash -c "test \"\$(yq -r '.bootstrapped' '$M')\" = true"
expect "advance kept cli_version" bash -c "test \"\$(yq -r '.cli_version' '$M')\" = skill-v1"
expect "advance kept created_at" bash -c "test \"\$(yq -r '.created_at' '$M')\" = 2026-01-01T00:00:00Z"
expect "advance kept an unknown top-level key" bash -c "test \"\$(yq -r '.future_key' '$M')\" = keep-me"
expect "advance kept the human comment" grep -qF '# this component was bootstrapped by bellwether detection' "$M"
expect "advance kept the original top-level key order (bootstrapped first)" \
  bash -c "test \"\$(grep -m1 -E '^[a-z_]+:' '$M')\" = 'bootstrapped: true'"
expect "advance kept the template block's own key order (sha still before repo)" \
  bash -c "test \"\$(grep -oE '^  (sha|repo|branch):' '$M' | head -1)\" = '  sha:'"
# The rewritten SHA is QUOTED on purpose: an all-digit 40-character SHA is a valid
# YAML integer, and an unquoted one would be re-read as a number by the next
# migration. Quoting is the value surviving, not the file being reflowed.
expect "advance's SHA round-trips through yq as a string" \
  bash -c "test \"\$(yq -r '.template.sha' '$M')\" = 6666666666666666666666666666666666666666"

fi

if t "in-progress.sh advance — carries Phase 8's key, and clear still carries none"; then
# This block PINS the interface:
#   advance has exactly ONE call site and that site is a guarded phase, so unlike
#   clear it takes a key — Phase 8's. clear stays keyless BECAUSE ABORT SHARES IT,
#   and abort must not advance a baseline it is rolling back. That is why the two
#   are separate actions of one script rather than one widened action.
IP=$SANDBOX/ip-adv-key
ip_fixture "$IP"

( cd "$IP" && env -u PHASE_KEY ACTION=advance TARGET_SHA=7777777777777777777777777777777777777777 \
    bash "$IPS" ) >/dev/null 2> "$SANDBOX/ip-adv-nokey.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/8-finalize.md first' "$SANDBOX/ip-adv-nokey.err"; then
  pass "advance without PHASE_KEY exits non-zero: load phases/8-finalize.md first"
else
  fail "advance without PHASE_KEY exits non-zero: load phases/8-finalize.md first (rc=$rc)"
fi
( cd "$IP" && ACTION=advance PHASE_KEY=$PK_BRANCH TARGET_SHA=7777777777777777777777777777777777777777 \
    bash "$IPS" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "advance rejects Phase 4's key (the key is Phase 8's)"; else fail "advance rejects Phase 4's key (rc=$rc)"; fi
expect "the refused advance did not move template.sha" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 1111111111111111111111111111111111111111"

# clear is still keyless, and still leaves the baseline alone — abort's guarantee.
( cd "$IP" && ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=2222222222222222222222222222222222222222 \
    PREV_BRANCH=main PREV_SHA=3333333333333333333333333333333333333333 bash "$IPS" ) >/dev/null 2>&1
( cd "$IP" && env -u PHASE_KEY ACTION=clear bash "$IPS" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "clear still runs keyless after advance was added"; else fail "clear still runs keyless after advance was added (rc=$rc)"; fi
expect "clear still does not advance the baseline" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 1111111111111111111111111111111111111111"

fi

if t "in-progress.sh advance — branch and sha land in a SINGLE mv, not two"; then
# Regression for the atomicity gap: template.branch and template.sha used to be
# written as two INDEPENDENT temp+mv rewrites. A crash between the two mv's left
# the branch advanced with the OLD sha still on disk until the next run
# self-healed it — a real window, undocumented. The fix folds both assignments
# into ONE yq expression, verified against ONE temp file, landed by ONE mv.
#
# Proven by MUTATION, the same pattern the other PATH-shim tests in this suite
# use: a `mv` shim ahead of the real one on PATH counts its own invocations and
# REFUSES the second one, simulating a crash in the exact window the two-rewrite
# code used to open. Against the old two-mv code this shim would let the first
# mv (branch) land and then fail the second (sha) — exactly the inconsistent
# state being fixed. Against the fixed single-mv code, advance needs only ONE
# mv no matter how many fields change, so the shim's refusal never fires and
# the whole call still succeeds.
REALMV=$(command -v mv)
IP=$SANDBOX/ip-adv-atomic
ip_fixture "$IP"
mkdir -p "$SANDBOX/mvfail-adv"
COUNT_FILE="$SANDBOX/mvfail-adv/count"
rm -f "$COUNT_FILE"
cat > "$SANDBOX/mvfail-adv/mv" <<EOF
#!/usr/bin/env bash
N=\$(( \$(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$N" > "$COUNT_FILE"
if [ "\$N" -gt 1 ]; then
  echo "SIMULATED CRASH: refusing mv #\$N — advance must need only ONE" >&2
  exit 1
fi
exec "$REALMV" "\$@"
EOF
chmod +x "$SANDBOX/mvfail-adv/mv"

( cd "$IP" && PATH="$SANDBOX/mvfail-adv:$PATH" ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=cccccccccccccccccccccccccccccccccccccccc BRANCH=feat/atomic \
    bash "$IPS" ) > "$SANDBOX/ip-adv-atomic.out" 2> "$SANDBOX/ip-adv-atomic.err"; rc=$?
expect "advance (branch+sha) exits 0 under a mv shim that only tolerates ONE call" \
  test "$rc" -eq 0
expect "advance printed \"advanced\"" grep -qx 'advanced' "$SANDBOX/ip-adv-atomic.out"
expect "the mv shim was invoked exactly once for the whole advance call" \
  bash -c "test \"\$(cat '$COUNT_FILE')\" = 1"
expect "template.branch landed" \
  bash -c "test \"\$(yq -r '.template.branch' '$IP/.kairos/manifest.yaml')\" = feat/atomic"
expect "template.sha landed alongside it, in the same single mv" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = cccccccccccccccccccccccccccccccccccccccc"

fi

if t "in-progress.sh advance — mixed-change matrix: branch-only, sha-only, both, neither"; then
# Today's semantics (preserved, not changed by the atomicity fix): advance
# ASSIGNS whichever field(s) the call targets, unconditionally — it never
# compares against the old value first. template.branch is written only when
# BRANCH is given at all (its ABSENCE, not its being unchanged, is what leaves
# it untouched); template.sha is always written, since TARGET_SHA is always
# required. So "branch given but equal to the current value" still assigns it
# (a no-op value, still an mv), and "neither value actually changes" still
# prints "advanced" — there is no "unchanged" outcome for this action, unlike
# clear.
IP=$SANDBOX/ip-adv-matrix
ip_fixture "$IP"   # starts at sha=1111...1111, branch=main

# sha-only: BRANCH omitted entirely -> branch untouched (already the sha-only
# case pinned by the first advance block above; re-asserted here as row 1 of
# the matrix for a single point of reference).
( cd "$IP" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=2222222222222222222222222222222222222222 bash "$IPS" \
  ) > "$SANDBOX/ip-adv-matrix-1.out" 2>/dev/null
expect "sha-only: prints advanced" grep -qx 'advanced' "$SANDBOX/ip-adv-matrix-1.out"
expect "sha-only: sha moved" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 2222222222222222222222222222222222222222"
expect "sha-only: branch untouched" \
  bash -c "test \"\$(yq -r '.template.branch' '$IP/.kairos/manifest.yaml')\" = main"

# branch-only (in effect): BRANCH given and DIFFERENT, but TARGET_SHA given as
# the value already on disk — sha is reassigned to the same value it already
# had (advance has no equality check), branch moves.
( cd "$IP" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=2222222222222222222222222222222222222222 BRANCH=feat/branch-only bash "$IPS" \
  ) > "$SANDBOX/ip-adv-matrix-2.out" 2>/dev/null
expect "branch-only: prints advanced" grep -qx 'advanced' "$SANDBOX/ip-adv-matrix-2.out"
expect "branch-only: branch moved" \
  bash -c "test \"\$(yq -r '.template.branch' '$IP/.kairos/manifest.yaml')\" = feat/branch-only"
expect "branch-only: sha (re-assigned to its own value) is still correct" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 2222222222222222222222222222222222222222"

# both change.
( cd "$IP" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=3333333333333333333333333333333333333333 BRANCH=feat/both bash "$IPS" \
  ) > "$SANDBOX/ip-adv-matrix-3.out" 2>/dev/null
expect "both: prints advanced" grep -qx 'advanced' "$SANDBOX/ip-adv-matrix-3.out"
expect "both: branch moved" \
  bash -c "test \"\$(yq -r '.template.branch' '$IP/.kairos/manifest.yaml')\" = feat/both"
expect "both: sha moved" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 3333333333333333333333333333333333333333"

# neither actually changes: BRANCH given equal to what's already on disk, and
# TARGET_SHA given equal to what's already on disk too.
( cd "$IP" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=3333333333333333333333333333333333333333 BRANCH=feat/both bash "$IPS" \
  ) > "$SANDBOX/ip-adv-matrix-4.out" 2>/dev/null; rc=$?
expect "neither: still exits 0 (advance has no equality check to fail)" test "$rc" -eq 0
expect "neither: still prints advanced, not unchanged" \
  grep -qx 'advanced' "$SANDBOX/ip-adv-matrix-4.out"
expect "neither: branch is still correct" \
  bash -c "test \"\$(yq -r '.template.branch' '$IP/.kairos/manifest.yaml')\" = feat/both"
expect "neither: sha is still correct" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 3333333333333333333333333333333333333333"

fi

if t "in-progress.sh bootstrap — writes the initial manifest, once, with bootstrapped: true"; then
# This block PINS the interface:
#   ACTION=bootstrap, env in NAME, REPO, BASE_SHA (the detected baseline) and
#   BRANCH (the branch the baseline was DETECTED on — required, see the block
#   below), plus optional CLI_VERSION, carrying Phase 2's key. It writes the
#   initial manifest and REFUSES to overwrite an existing one — bootstrap runs once
#   per component, ever, and a manifest that already exists is recorded history.
#   `bootstrapped: true` is load-bearing (planner and executor both change
#   behavior on it) and was previously transcribed by a model from a YAML block in
#   reference/bellwether-detection.md; one dropped line silently removed that
#   caution for the component's whole life.
IP=$SANDBOX/ip-boot
rm -rf "$IP"; mkdir -p "$IP"

( cd "$IP" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=mycomp REPO=file:///srv/template.git \
    BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) > "$SANDBOX/ip-boot.out" 2>&1; rc=$?
expect "bootstrap exits 0" test "$rc" -eq 0
M="$IP/.kairos/manifest.yaml"
expect "bootstrap creates .kairos/manifest.yaml" test -f "$M"
expect "bootstrap writes name" bash -c "test \"\$(yq -r '.name' '$M')\" = mycomp"
expect "bootstrap writes template.repo" bash -c "test \"\$(yq -r '.template.repo' '$M')\" = file:///srv/template.git"
expect "bootstrap writes the detected baseline as template.sha" \
  bash -c "test \"\$(yq -r '.template.sha' '$M')\" = 8888888888888888888888888888888888888888"
expect "bootstrap records the BRANCH it was handed as template.branch" \
  bash -c "test \"\$(yq -r '.template.branch' '$M')\" = main"
expect "bootstrap writes bootstrapped: true" bash -c "test \"\$(yq -r '.bootstrapped' '$M')\" = true"
expect "bootstrap writes cli_version" bash -c "test \"\$(yq -r '.cli_version' '$M')\" = skill-v1"
expect "bootstrap writes an ISO-8601 created_at" \
  bash -c "yq -r '.created_at' '$M' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'"

# Refuses to overwrite — and the existing file is untouched.
cp "$M" "$SANDBOX/ip-boot.orig"
( cd "$IP" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=other REPO=file:///srv/other.git \
    BASE_SHA=9999999999999999999999999999999999999999 BRANCH=main bash "$IPS" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "bootstrap refuses to overwrite an existing manifest"; else fail "bootstrap refuses to overwrite an existing manifest (rc=$rc)"; fi
expect "the refused bootstrap left the manifest byte-identical" cmp -s "$SANDBOX/ip-boot.orig" "$M"

# The baseline written by bootstrap is the same one advance later moves — one
# contract creating it and moving it, which is the whole point of sharing a script.
( cd "$IP" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash "$IPS" ) >/dev/null 2>&1
expect "advance moves the baseline bootstrap wrote" \
  bash -c "test \"\$(yq -r '.template.sha' '$M')\" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect "advance kept bootstrap's bootstrapped: true" bash -c "test \"\$(yq -r '.bootstrapped' '$M')\" = true"
expect "bootstrap wrote template.kind: component (no facade marker in .init.mk)" \
  bash -c "test \"\$(yq -r '.template.kind' '$M')\" = component"
expect "advance kept template.kind" \
  bash -c "test \"\$(yq -r '.template.kind' '$M')\" = component"

# A facade (MASTERDATA_INCLUDE_NO_CDC set in .init.mk) is stamped `facade`, the
# kind the CLI writes from 0.3.35 and `kairos component promote` reads.
# reproduced pre-fix: no template.kind at all, so promote could misread a
# bootstrapped facade as a component.
IPF=$SANDBOX/ip-boot-facade
rm -rf "$IPF"; mkdir -p "$IPF"
printf 'ifeq ($(INFRA_DIR),)\n%%:\nelse\n  MASTERDATA_INCLUDE_NO_CDC := 1\nendif\n' > "$IPF/.init.mk"
( cd "$IPF" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=myfacade REPO=file:///srv/facade.git \
    BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) >/dev/null 2>&1; rc=$?
expect "a facade bootstrap exits 0" test "$rc" -eq 0
expect "a facade bootstrap writes template.kind: facade" \
  bash -c "test \"\$(yq -r '.template.kind' '$IPF/.kairos/manifest.yaml')\" = facade"

# The toolkit declares the variable EMPTY (`?=`) for every other component; an
# empty assignment is not the marker.
IPE=$SANDBOX/ip-boot-empty-marker
rm -rf "$IPE"; mkdir -p "$IPE"
printf 'MASTERDATA_INCLUDE_NO_CDC ?=\n# MASTERDATA_INCLUDE_NO_CDC := 1\n' > "$IPE/.init.mk"
( cd "$IPE" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=mycomp REPO=file:///srv/t.git \
    BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) >/dev/null 2>&1
expect "an empty or commented-out marker is not a facade" \
  bash -c "test \"\$(yq -r '.template.kind' '$IPE/.kairos/manifest.yaml')\" = component"

# Committed facades carry no MASTERDATA_INCLUDE_NO_CDC line: the facade template
# sets `GENERATE_MODULES := masterdata json` instead (real 041ee24 .init.mk in
# tests/fixtures/). reproduced pre-fix: such a facade was stamped `component`.
boot_kind() { # boot_kind <dir> → prints the template.kind bootstrap wrote
  ( cd "$1" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=k REPO=file:///srv/t.git \
      BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) >/dev/null 2>&1
  yq -r '.template.kind' "$1/.kairos/manifest.yaml" 2>/dev/null
}
IPR=$SANDBOX/ip-boot-real-facade
rm -rf "$IPR"; mkdir -p "$IPR"
cp "$SKILL_DIR/tests/fixtures/facade-template-041ee24/init.mk" "$IPR/.init.mk"
k=$(boot_kind "$IPR")
expect "a real facade-template .init.mk (no marker, GENERATE_MODULES := masterdata json) is a facade" \
  test "$k" = facade
for gm in 'masterdata sql json' 'all' 'masterdata  all'; do
  IPG=$SANDBOX/ip-boot-gm
  rm -rf "$IPG"; mkdir -p "$IPG"
  printf 'else\n  GENERATE_MODULES := %s\nendif\n' "$gm" > "$IPG/.init.mk"
  k=$(boot_kind "$IPG")
  expect "GENERATE_MODULES := $gm (has sql or all) is not a facade" test "$k" = component
done

fi

if t "in-progress.sh bootstrap — refuses incomplete input and carries Phase 2's key"; then
IPB=$SANDBOX/ip-boot-bad
boot_call() { rm -rf "$IPB"; mkdir -p "$IPB"; ( cd "$IPB" && env "$@" bash "$IPS" ) >/dev/null 2>&1; }

boot_call ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=file:///srv/t.git BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "bootstrap refuses a missing NAME"; else fail "bootstrap refuses a missing NAME"; fi
refute "the NAME refusal wrote no manifest" test -e "$IPB/.kairos/manifest.yaml"
boot_call ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=mycomp BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "bootstrap refuses a missing REPO"; else fail "bootstrap refuses a missing REPO"; fi
boot_call ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=mycomp REPO=file:///srv/t.git BASE_SHA=8888888 BRANCH=main; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "bootstrap refuses a short BASE_SHA"; else fail "bootstrap refuses a short BASE_SHA"; fi
boot_call ACTION=bootstrap PHASE_KEY=$PK_FINALIZE NAME=mycomp REPO=file:///srv/t.git BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "bootstrap rejects Phase 8's key (the key is Phase 2's)"; else fail "bootstrap rejects Phase 8's key"; fi

# BRANCH is REQUIRED, and an EMPTY one is refused exactly like an unset one.
# Story 32's remaining half: `BRANCH` records the branch the baseline was DETECTED
# on, and rule 4 of Phase 2's target chain reads it back on the NEXT migration. A
# default of `main` made every non-main bootstrap silently wrong — and the shape it
# actually arrives in is not "omitted" but "set from an empty variable", because the
# caller is a phase-doc block interpolating `$BOOT_REF` out of the run-context
# anchor. Both are the same defect, so both are refused: a value that cannot be
# defaulted correctly must not be defaulted at all.
IPBR=$SANDBOX/ip-boot-branch-req
# The caller's assignments come AFTER the fixed ones so they win; `-u` cannot ride
# in through "$@" at all (env requires its options before the first operand, and
# `env A=1 -u B cmd` reads `-u` as the COMMAND — an accidental non-zero exit that
# would have made the unset case pass without the script doing anything).
br_call() { rm -rf "$IPBR"; mkdir -p "$IPBR"; ( cd "$IPBR" && env ACTION=bootstrap PHASE_KEY=$PK_RESOLVE \
    NAME=mycomp REPO=file:///srv/t.git BASE_SHA=8888888888888888888888888888888888888888 "$@" bash "$IPS" ) \
    >/dev/null 2> "$SANDBOX/ip-boot-branch.err"; }
rm -rf "$IPBR"; mkdir -p "$IPBR"
( cd "$IPBR" && env -u BRANCH ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=mycomp \
    REPO=file:///srv/t.git BASE_SHA=8888888888888888888888888888888888888888 bash "$IPS" ) \
  >/dev/null 2> "$SANDBOX/ip-boot-branch.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "bootstrap refuses an UNSET BRANCH (no silent main default)"; else fail "bootstrap refuses an UNSET BRANCH (rc=$rc)"; fi
refute "the unset-BRANCH refusal wrote no manifest" test -e "$IPBR/.kairos/manifest.yaml"
expect "the unset-BRANCH refusal names BRANCH" grep -qF 'BRANCH' "$SANDBOX/ip-boot-branch.err"
expect "the unset-BRANCH refusal says why (the next migration reads it back)" \
  grep -qiE 'detect|next migration|rule 4' "$SANDBOX/ip-boot-branch.err"
br_call BRANCH=; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "bootstrap refuses an EMPTY BRANCH (the \$BOOT_REF-interpolated shape)"; else fail "bootstrap refuses an EMPTY BRANCH (rc=$rc)"; fi
refute "the empty-BRANCH refusal wrote no manifest" test -e "$IPBR/.kairos/manifest.yaml"
br_call "BRANCH=   "; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "bootstrap refuses a whitespace-only BRANCH"; else fail "bootstrap refuses a whitespace-only BRANCH (rc=$rc)"; fi

# Newline / CR / tab in a value are REFUSED, not folded to spaces. collapse() used
# to translate all three into blanks, so `NAME=$'a\nb'` became `a b` and a
# CRLF-authored `BRANCH=main\r` became `main` — a value silently different from the
# one the caller passed, recorded into the component's founding manifest. Same
# philosophy record-context.sh applies to the run-context anchor.
for ctl in nl cr tab; do
  case $ctl in
    nl)  bad="a
b" ;;
    cr)  bad="a"$'\r'"b" ;;
    tab) bad="a"$'\t'"b" ;;
  esac
  br_call BRANCH=main NAME="$bad"; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "bootstrap refuses a $ctl in NAME (never folded to a space)"; else fail "bootstrap refuses a $ctl in NAME (rc=$rc)"; fi
  refute "the $ctl-in-NAME refusal wrote no manifest" test -e "$IPBR/.kairos/manifest.yaml"
  br_call BRANCH="$bad"; rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "bootstrap refuses a $ctl in BRANCH"; else fail "bootstrap refuses a $ctl in BRANCH (rc=$rc)"; fi
done
# Non-vacuity: internal SPACES are still legal and still collapse/trim — the reject
# is narrow, and a component name with a space in it must still bootstrap.
br_call BRANCH=main NAME='  my comp  '; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "an internally-spaced NAME still bootstraps (the ctl reject is narrow)"; else fail "an internally-spaced NAME still bootstraps (rc=$rc)"; fi
expect "the spaced NAME is trimmed and collapsed, as it always was" \
  bash -c "test \"\$(yq -r '.name' '$IPBR/.kairos/manifest.yaml')\" = 'my comp'"

rm -rf "$IPB"; mkdir -p "$IPB"
( cd "$IPB" && env -u PHASE_KEY ACTION=bootstrap NAME=mycomp REPO=file:///srv/t.git \
    BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) >/dev/null 2> "$SANDBOX/ip-boot-nokey.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/2-resolve-target.md first' "$SANDBOX/ip-boot-nokey.err"; then
  pass "bootstrap without PHASE_KEY exits non-zero: load phases/2-resolve-target.md first"
else
  fail "bootstrap without PHASE_KEY exits non-zero: load phases/2-resolve-target.md first (rc=$rc)"
fi

fi

if t "in-progress.sh bootstrap — NAME comes from pkg/schema/globals.go, never the directory basename"; then
# The previous default was the checkout directory. Repo kairos-todo-demo vs
# schema.ComponentName todo-demo is the real shape; writing the directory into
# the founding manifest poisons every later substitution. The resolver is the
# source of NAME when the file exists; a disagreeing caller is refused.
IPN=$SANDBOX/kairos-todo-demo
rm -rf "$IPN"; mkdir -p "$IPN/pkg/schema"
printf 'package schema\n\nconst ComponentName = "todo-demo"\n' > "$IPN/pkg/schema/globals.go"

( cd "$IPN" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=file:///srv/template.git \
    BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) \
  > "$SANDBOX/ip-name-omit.out" 2> "$SANDBOX/ip-name-omit.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "omitted NAME bootstraps from schema.ComponentName"; else fail "omitted NAME bootstraps from schema.ComponentName (rc=$rc)"; fi
expect "the founding name is todo-demo, not the directory kairos-todo-demo" \
  bash -c "test \"\$(yq -r '.name' '$IPN/.kairos/manifest.yaml')\" = todo-demo"

rm -rf "$IPN"; mkdir -p "$IPN/pkg/schema"
printf 'package schema\n\nconst ComponentName = "todo-demo"\n' > "$IPN/pkg/schema/globals.go"
( cd "$IPN" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=kairos-todo-demo \
    REPO=file:///srv/template.git BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) \
  >/dev/null 2> "$SANDBOX/ip-name-mismatch.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "a NAME that disagrees with schema.ComponentName is refused"; else fail "a NAME that disagrees with schema.ComponentName is refused (rc=$rc)"; fi
expect "the mismatch refusal names both values" \
  bash -c "grep -qF \"NAME='kairos-todo-demo'\" '$SANDBOX/ip-name-mismatch.err' && grep -qF \"ComponentName='todo-demo'\" '$SANDBOX/ip-name-mismatch.err'"
refute "the mismatch refusal wrote no manifest" test -e "$IPN/.kairos/manifest.yaml"

rm -rf "$IPN"; mkdir -p "$IPN/pkg/schema"
printf 'package schema\n\nconst ComponentName = "todo-demo"\n' > "$IPN/pkg/schema/globals.go"
( cd "$IPN" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=todo-demo \
    REPO=file:///srv/template.git BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) \
  >/dev/null 2> "$SANDBOX/ip-name-match.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "a NAME that matches schema.ComponentName is accepted"; else fail "a NAME that matches schema.ComponentName is accepted (rc=$rc)"; fi
expect "the matching NAME lands as todo-demo" \
  bash -c "test \"\$(yq -r '.name' '$IPN/.kairos/manifest.yaml')\" = todo-demo"

# Placeholder / missing constant: the script does not guess. A user-supplied
# NAME is accepted; an omitted NAME is refused with an ask, not a Chart.yaml or
# directory fallback.
rm -rf "$IPN"; mkdir -p "$IPN/pkg/schema"
printf 'package schema\n\nconst ComponentName = "YOUR_COMPONENT_NAME"\n' > "$IPN/pkg/schema/globals.go"
( cd "$IPN" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=orders \
    REPO=file:///srv/template.git BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) \
  >/dev/null 2> "$SANDBOX/ip-name-ph.err"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "a placeholder ComponentName accepts a user-supplied NAME"; else fail "a placeholder ComponentName accepts a user-supplied NAME (rc=$rc)"; fi
expect "the user-supplied NAME lands when the constant is still a placeholder" \
  bash -c "test \"\$(yq -r '.name' '$IPN/.kairos/manifest.yaml')\" = orders"

rm -rf "$IPN"; mkdir -p "$IPN/pkg/schema"
printf 'package schema\n\nconst ComponentName = "YOUR_COMPONENT_NAME"\n' > "$IPN/pkg/schema/globals.go"
( cd "$IPN" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE \
    REPO=file:///srv/template.git BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) \
  >/dev/null 2> "$SANDBOX/ip-name-ph-omit.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "a placeholder ComponentName with no NAME is refused"; else fail "a placeholder ComponentName with no NAME is refused (rc=$rc)"; fi
expect "the omitted-NAME refusal asks the user and forbids guessing" \
  bash -c "grep -qF 'Ask the user' '$SANDBOX/ip-name-ph-omit.err' && grep -qF 'Chart.yaml' '$SANDBOX/ip-name-ph-omit.err'"
refute "the placeholder omitted-NAME refusal wrote no manifest" test -e "$IPN/.kairos/manifest.yaml"
fi

if t "in-progress.sh bootstrap — YAML values are typed as strings, like every other write path"; then
# B4. `set` and `advance` write through `strenv()` precisely so a value carrying
# YAML metacharacters stays DATA — and the advance block above pins the reason: an
# all-digit 40-character SHA is a valid YAML number. Bootstrap, the write that
# CREATES the file, was the one path that printf'd its values unquoted, so the
# component's founding manifest was the one most likely to be mistyped:
#   * a 40-digit SHA parses as !!float, and any consumer that re-emits the value
#     rather than reading its raw token gets 1.2345678901234568e+39 — a baseline no
#     git command will ever resolve;
#   * a template branch named `1.0` parses as !!float and re-emits as `1`;
#   * `created_at:` parses as !!timestamp.
# The fix is the discipline the other two actions already use, not a quoting rule
# invented here. `bootstrapped:` is the deliberate exception — it must stay a real
# boolean, because planner and executor read it as one.
IPQ=$SANDBOX/ip-boot-quote
rm -rf "$IPQ"; mkdir -p "$IPQ"
DIGIT_SHA=1234567890123456789012345678901234567890
( cd "$IPQ" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=mycomp REPO=file:///srv/template.git \
    BASE_SHA=$DIGIT_SHA BRANCH=1.0 CLI_VERSION=2.0 bash "$IPS" ) \
  > "$SANDBOX/ip-bootq.out" 2> "$SANDBOX/ip-bootq.err"; rc=$?
expect "bootstrap with an all-digit SHA and a 1.0 branch exits 0" test "$rc" -eq 0
M="$IPQ/.kairos/manifest.yaml"
tag_is() { # tag_is <path-expr> <want-tag>
  local got; got=$(yq "$1 | tag" "$M" 2>/dev/null)
  if [[ "$got" = "$2" ]]; then pass "$1 is typed $2"; else fail "$1 is typed $2 (got '${got:-<none>}')"; fi
}
tag_is '.template.sha' '!!str'
tag_is '.template.branch' '!!str'
tag_is '.created_at' '!!str'
tag_is '.cli_version' '!!str'
tag_is '.name' '!!str'
tag_is '.template.repo' '!!str'
# The one value that must NOT be quoted into a string: planner and executor read
# `bootstrapped` as a boolean for the component's whole life.
tag_is '.bootstrapped' '!!bool'
# The damage a mistyped value actually does: anything that re-emits the value
# instead of echoing its raw token loses it.
expect "the all-digit SHA survives a JSON re-emit (no float rounding)" \
  bash -c "test \"\$(yq -o=json '.template.sha' '$M')\" = '\"$DIGIT_SHA\"'"
expect "the 1.0 branch survives a JSON re-emit (not the number 1)" \
  bash -c "test \"\$(yq -o=json '.template.branch' '$M')\" = '\"1.0\"'"
# And the plain read-back still works, so quoting is the value surviving rather
# than the file becoming something else.
expect "template.sha reads back as the SHA that was passed in" \
  bash -c "test \"\$(yq -r '.template.sha' '$M')\" = $DIGIT_SHA"
expect "template.branch reads back as 1.0" \
  bash -c "test \"\$(yq -r '.template.branch' '$M')\" = 1.0"
expect "cli_version reads back as 2.0" \
  bash -c "test \"\$(yq -r '.cli_version' '$M')\" = 2.0"
expect "bootstrapped is still true" bash -c "test \"\$(yq -r '.bootstrapped' '$M')\" = true"
# The manifest bootstrap writes must be a manifest the OTHER actions can operate
# on — the round trip the next migration actually performs.
( cd "$IPQ" && ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=$DIGIT_SHA \
    PREV_BRANCH=1.0 PREV_SHA=$DIGIT_SHA bash "$IPS" ) >/dev/null 2>&1
expect "set on a bootstrapped manifest still records previous_branch" \
  bash -c "test \"\$(yq -r '.template.in_progress.previous_branch' '$M')\" = 1.0"
expect "and the bootstrapped values are untouched by it" \
  bash -c "test \"\$(yq -r '.template.branch' '$M')\" = 1.0 && test \"\$(yq -r '.template.sha' '$M')\" = $DIGIT_SHA"
expect "the manifest is still valid YAML after both writes" \
  bash -c "yq -e '.' '$M' >/dev/null 2>&1"
# A value carrying YAML metacharacters is data, not syntax — the reason strenv
# exists at all. `#` after a space starts a comment in an unquoted scalar.
IPQ2=$SANDBOX/ip-boot-quote2
rm -rf "$IPQ2"; mkdir -p "$IPQ2"
( cd "$IPQ2" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME='my: comp #1' \
    REPO='file:///srv/t.git' BASE_SHA=8888888888888888888888888888888888888888 \
    BRANCH=main bash "$IPS" ) >/dev/null 2>&1; rc=$?
expect "bootstrap with a metacharacter-carrying NAME exits 0" test "$rc" -eq 0
expect "the metacharacter NAME round-trips verbatim (data, not syntax)" \
  bash -c "test \"\$(yq -r '.name' '$IPQ2/.kairos/manifest.yaml')\" = 'my: comp #1'"

# The pre-mv self-check reads these VALUES back before the file lands, so an
# exit 0 on the hostile fixtures above is the check ACCEPTING them, not skipping
# them: `my: comp #1` (a metacharacter NAME) and the `1.0` branch both survive it.
# A YAML 1.1 bool-word branch is the third shape — `on`, `off`, `yes`, `no` are
# branch names a template can legitimately carry, and the value read-back has to
# agree with the caller on all of them.
IPQ3=$SANDBOX/ip-boot-quote3
rm -rf "$IPQ3"; mkdir -p "$IPQ3"
( cd "$IPQ3" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME='my: comp #1' \
    REPO='file:///srv/t.git?ref=a#b' BASE_SHA=8888888888888888888888888888888888888888 \
    BRANCH=on bash "$IPS" ) >/dev/null 2> "$SANDBOX/ip-bootq3.err"; rc=$?
expect "bootstrap with a bool-word branch ('on') exits 0 — the value check accepts it" \
  test "$rc" -eq 0
expect "the bool-word branch round-trips as the string it was passed as" \
  bash -c "test \"\$(yq -r '.template.branch' '$IPQ3/.kairos/manifest.yaml')\" = on"
expect "the bool-word branch is typed !!str, not !!bool" \
  bash -c "test \"\$(yq '.template.branch | tag' '$IPQ3/.kairos/manifest.yaml')\" = '!!str'"
expect "a metacharacter-carrying REPO round-trips verbatim too" \
  bash -c "test \"\$(yq -r '.template.repo' '$IPQ3/.kairos/manifest.yaml')\" = 'file:///srv/t.git?ref=a#b'"
refute "no self-check refusal was printed for any of the hostile values" \
  grep -q 'failed its own check' "$SANDBOX/ip-bootq3.err"

fi

if t "in-progress.sh bootstrap — the pre-write self-check covers the caller-supplied VALUES"; then
# The self-check read back `.template.sha`'s value, the `!!str` TYPE of sha and
# branch, and `bootstrapped`'s value and type — and nothing at all about the
# values of NAME, REPO and BRANCH. Those three are the rest of what the caller
# passed: the component's name for its whole life, the upstream every future
# migration fetches from, and the branch rule 4 of Phase 2's target chain reads
# back on the NEXT migration. A construction that dropped or mangled one of them
# produced a manifest that parses, types correctly and is quietly about a
# different component.
#
# Proven load-bearing by MUTATION, the same way the `!!bool` check above is: a
# `yq` shim ahead of the real one on PATH corrupts one value in the output of the
# initial `yq -n` and leaves every other call alone. The first mutation is the one
# no type check can see — an EMPTY name is a perfectly good `!!str`.
IPV=$SANDBOX/ip-boot-val
rm -rf "$IPV"; mkdir -p "$IPV/bin"
REAL_YQ=$(command -v yq)
mk_val_shim() { # mk_val_shim <sed-expr> — mistype ONLY the initial `yq -n` construction
  cat > "$IPV/bin/yq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "-n" ]; then
    "$REAL_YQ" "\$@" | sed '$1'
    exit \${PIPESTATUS[0]}
  fi
done
exec "$REAL_YQ" "\$@"
EOF
  chmod +x "$IPV/bin/yq"
}
val_case() { # val_case <label> <sed-expr> <grep-key>
  local label="$1" expr="$2" key="$3" dir="$IPV/comp-$1"
  mk_val_shim "$expr"
  rm -rf "$dir"; mkdir -p "$dir"
  # Sanity: the shim really does corrupt the construction, or this proves nothing.
  ( cd "$IPV" && PATH="$IPV/bin:$PATH" yq -n '{"name": "mycomp", "template": {"repo": "file:///srv/t.git", "branch": "main"}}' ) \
    > "$SANDBOX/ip-val-$label.shim" 2>/dev/null
  ( cd "$dir" && PATH="$IPV/bin:$PATH" ACTION=bootstrap PHASE_KEY=$PK_RESOLVE \
      NAME=mycomp REPO=file:///srv/t.git BRANCH=main \
      BASE_SHA=8888888888888888888888888888888888888888 bash "$IPS" ) \
    >/dev/null 2> "$SANDBOX/ip-val-$label.err"; local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    pass "a mangled $key is refused before the manifest lands"
  else
    fail "a mangled $key is refused before the manifest lands (rc=$rc)"
  fi
  refute "the mangled-$key refusal wrote no manifest" test -e "$dir/.kairos/manifest.yaml"
  expect "the mangled-$key refusal names the key" \
    grep -qF "$key" "$SANDBOX/ip-val-$label.err"
  refute "no temp manifest is left behind by the mangled-$key refusal" \
    bash -c "ls '$dir/.kairos'/.manifest.yaml.* >/dev/null 2>&1"
}
val_case name 's/^name: mycomp$/name: ""/' name
expect "the name shim really empties the value (self-test of the injection)" \
  grep -qF 'name: ""' "$SANDBOX/ip-val-name.shim"
expect "an EMPTY name is still a valid !!str — only the VALUE check sees it" \
  bash -c "test \"\$(yq '.name | tag' '$SANDBOX/ip-val-name.shim')\" = '!!str'"
val_case repo 's|repo: file:///srv/t.git$|repo: file:///srv/other.git|' template.repo
val_case branch 's/branch: main$/branch: other/' template.branch

# Non-vacuity: with the shim gone, the identical call bootstraps.
IPVOK=$IPV/comp-clean
rm -rf "$IPVOK"; mkdir -p "$IPVOK"
( cd "$IPVOK" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=mycomp REPO=file:///srv/t.git \
    BRANCH=main BASE_SHA=8888888888888888888888888888888888888888 bash "$IPS" ) >/dev/null 2>&1; rc=$?
expect "the same call without the shim still bootstraps (the check is not a blanket refusal)" \
  test "$rc" -eq 0
expect "and it wrote the values the caller passed" \
  bash -c "test \"\$(yq -r '.name' '$IPVOK/.kairos/manifest.yaml')\" = mycomp \
        && test \"\$(yq -r '.template.repo' '$IPVOK/.kairos/manifest.yaml')\" = file:///srv/t.git \
        && test \"\$(yq -r '.template.branch' '$IPVOK/.kairos/manifest.yaml')\" = main"

fi

if t "in-progress.sh bootstrap — the pre-write type self-check covers bootstrapped as a BOOLEAN"; then
# The self-check re-read the TYPE of `.template.sha` and `.template.branch` off the
# bytes about to land, but only the VALUE of `.bootstrapped` — and the value check
# cannot tell `true` from `"true"`. That is the one key whose type is load-bearing
# for the component's whole life: planner and executor branch on it as a boolean,
# and any consumer that re-emits it (`yq -o=json`) gets a string. So the type is
# re-read too, and this test proves it by making the write produce the wrong type.
#
# The injection is a `yq` shim ahead of the real one on PATH that quotes
# `bootstrapped` in the output of `yq -n` — precisely the mistype a `strenv()`
# slip would produce — and leaves every other yq call alone. Pre-fix the script
# writes that manifest and reports success.
IPT=$SANDBOX/ip-boot-tag
rm -rf "$IPT"; mkdir -p "$IPT/bin" "$IPT/comp"
REAL_YQ=$(command -v yq)
cat > "$IPT/bin/yq" <<EOF
#!/usr/bin/env bash
# Mistype ONLY the initial \`yq -n\` construction; pass every other call through.
for a in "\$@"; do
  if [ "\$a" = "-n" ]; then
    "$REAL_YQ" "\$@" | sed 's/^bootstrapped: true\$/bootstrapped: "true"/'
    exit \${PIPESTATUS[0]}
  fi
done
exec "$REAL_YQ" "\$@"
EOF
chmod +x "$IPT/bin/yq"
( cd "$IPT/comp" && PATH="$IPT/bin:$PATH" ACTION=bootstrap PHASE_KEY=$PK_RESOLVE \
    NAME=mycomp REPO=file:///srv/t.git BRANCH=main \
    BASE_SHA=8888888888888888888888888888888888888888 bash "$IPS" ) \
  > "$SANDBOX/ip-boot-tag.out" 2> "$SANDBOX/ip-boot-tag.err"; rc=$?
# Sanity: the shim really does mistype (otherwise this test proves nothing).
( cd "$IPT" && PATH="$IPT/bin:$PATH" yq -n '{"bootstrapped": true}' ) > "$SANDBOX/ip-tag-shim.yaml" 2>/dev/null
expect "the shim really mistypes bootstrapped (self-test of the injection)" \
  grep -qF 'bootstrapped: "true"' "$SANDBOX/ip-tag-shim.yaml"
if [[ "$rc" -ne 0 ]]; then
  pass "bootstrap refuses a manifest whose bootstrapped is not a YAML boolean"
else
  fail "bootstrap refuses a manifest whose bootstrapped is not a YAML boolean (rc=$rc)"
fi
refute "the refused mistyped bootstrap wrote no manifest" test -e "$IPT/comp/.kairos/manifest.yaml"
expect "the refusal names bootstrapped and the type" \
  bash -c "grep -qF 'bootstrapped' '$SANDBOX/ip-boot-tag.err' && grep -qiE 'boolean|!!bool' '$SANDBOX/ip-boot-tag.err'"
refute "no temp manifest is left behind by the refusal" \
  bash -c "ls '$IPT/comp/.kairos'/.manifest.yaml.* >/dev/null 2>&1"

fi

if t "bootstrap baseline detection walks the RESOLVED template branch, not main"; then
# Story 32. bellwether-detect.sh takes the branch to walk from `TEMPLATE_BRANCH`
# and defaults it to `main` — and the Phase 2 bootstrap block invoked it with only
# CACHE/RUN/PHASE_KEY. So a run started with `--template-branch <x>` (or from a
# local clone checked out on a feature branch) detected its baseline from MAIN's
# history and then wrote that SHA as the component's founding baseline: every
# future migration of that component computes its diff from a commit the run never
# targeted. It is not even a visibly weak answer — the fixture below is
# confidently wrong on both branches, with a different SHA on each.
#
# The counting is orchestrator prose, so the fix is a phase-doc contract and it is
# pinned as one (same shape as the PREV_SHA block below). The defect itself is
# demonstrated on real history first: what the detector answers is decided by the
# branch it is handed.
BB=$SANDBOX/boot-branch
rm -rf "$BB"; mkdir -p "$BB/tpl" "$BB/comp" "$BB/run-main" "$BB/run-branch"
cd "$BB/tpl"
git init -q -b main
mkdir -p .kairos-updates
printf 'b1.txt\nb2.txt\nb3.txt\nb4.txt\n' > .kairos-updates/bellwethers.txt
for b in b1 b2 b3 b4; do printf '%s v1\n' "$b" > "$b.txt"; done
git add -A && git commit -qm "c1 baseline"
BB_C1=$(git rev-parse HEAD)
printf 'b1 v3\n' > b1.txt                       # main moves b1 to the same v3 the
git commit -qam "c2 on main"                    # component carries: 3/4 on main
BB_C2=$(git rev-parse HEAD)
git checkout -q -b feat/x "$BB_C1"
printf 'b1 v3\n' > b1.txt
printf 'b2 v2\n' > b2.txt                       # the branch is the real baseline: 4/4
git commit -qam "c3 on feat/x"
BB_C3=$(git rev-parse HEAD)
git checkout -q main

cd "$BB/comp"
printf 'b1 v3\n' > b1.txt
printf 'b2 v2\n' > b2.txt
printf 'b3 v1\n' > b3.txt
printf 'b4 v1\n' > b4.txt

# The pre-fix invocation: no TEMPLATE_BRANCH, so the detector's documented default
# (main) applies and the branch the run targets is nowhere in the answer.
CACHE=$BB/tpl RUN=$BB/run-main PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/bellwether-detect.sh" > "$SANDBOX/bb-main.out" 2> "$SANDBOX/bb-main.log"
expect "detection with no branch passed exits 0 (it looks like a clean answer)" test $? -eq 0
BB_TOP_MAIN=$(head -1 "$BB/run-main/bellwether-scores.txt" | awk '{ print $3 }')
BB_SCORE_MAIN=$(head -1 "$BB/run-main/bellwether-scores.txt" | awk '{ print $1 "/" $2 }')
if [[ "$BB_TOP_MAIN" = "$BB_C2" ]]; then
  pass "unpassed branch detects a MAIN commit as the baseline ($BB_SCORE_MAIN — confidently wrong)"
else
  fail "unpassed branch detects a MAIN commit as the baseline (got $BB_TOP_MAIN, want $BB_C2)"
fi
refute "the branch's true baseline is not even a candidate on main's history" \
  grep -qF "$BB_C3" "$BB/run-main/bellwether-scores.txt"

# The same call with the resolved branch handed through.
CACHE=$BB/tpl RUN=$BB/run-branch TEMPLATE_BRANCH=feat/x PHASE_KEY=$PK_RESOLVE \
  "$SKILL_DIR/scripts/bellwether-detect.sh" > "$SANDBOX/bb-branch.out" 2> "$SANDBOX/bb-branch.log"
expect "detection with the resolved branch exits 0" test $? -eq 0
BB_TOP_BRANCH=$(head -1 "$BB/run-branch/bellwether-scores.txt" | awk '{ print $3 }')
BB_SCORE_BRANCH=$(head -1 "$BB/run-branch/bellwether-scores.txt" | awk '{ print $1 "/" $2 }')
if [[ "$BB_TOP_BRANCH" = "$BB_C3" ]]; then
  pass "the resolved branch detects the branch's own baseline ($BB_SCORE_BRANCH)"
else
  fail "the resolved branch detects the branch's own baseline (got $BB_TOP_BRANCH, want $BB_C3)"
fi
if [[ "$BB_TOP_MAIN" != "$BB_TOP_BRANCH" ]]; then
  pass "the two runs write DIFFERENT baselines — the branch handed in decides it"
else
  fail "the two runs write DIFFERENT baselines (both answered $BB_TOP_MAIN)"
fi
cd "$SANDBOX"

# The contract: Phase 2's bootstrap block must resolve the branch and hand it to
# BOTH scripts — the detector (which history to walk) and the manifest writer
# (which branch to record, so the next run's rule-4 default is that same history).
#
# And it must resolve it from the ANCHOR. The first fix derived
# `BOOT_REF=${TARGET_REFSPEC:-${TEMPLATE_BRANCH:-…}}` from two LIVE SHELL
# VARIABLES: TARGET_REFSPEC and TEMPLATE_BRANCH are conversationally-extracted
# argument values, not anchor keys, and each phase code block runs in a fresh shell
# — so both were empty at runtime and `--template-branch feat/x` still detected from
# main and recorded `branch: main`. The exact failure the fix claimed to remove.
# The user-given ref therefore reaches the anchor FIRST (its own block, before any
# detection), and every consumer reads it back from there.
RT=$SKILL_DIR/phases/2-resolve-target.md
expect "the bootstrap block derives BOOT_REF from anchor-read keys only" \
  grep -qF 'BOOT_REF=${TARGET_REF:-${TEMPLATE_LOCAL_BRANCH:-main}}' "$RT"
refute "BOOT_REF no longer falls back through the dead live variable TARGET_REFSPEC" \
  bash -c "grep -F 'BOOT_REF=' '$RT' | grep -q 'TARGET_REFSPEC'"
refute "BOOT_REF no longer falls back through the dead live variable TEMPLATE_BRANCH" \
  bash -c "grep -F 'BOOT_REF=' '$RT' | grep -qE '[{:-]TEMPLATE_BRANCH'"
expect "phase 2 records the invocation's ref into the anchor as TARGET_REF" \
  bash -c "grep -F 'record-context.sh' '$RT' | grep -q 'TARGET_REF='"
expect "the detector invocation is handed that resolved ref" \
  bash -c "grep -F 'scripts/bellwether-detect.sh' '$RT' | grep -q 'TEMPLATE_BRANCH=\"\$BOOT_REF\"'"
expect "the bootstrap write records the same ref as template.branch" \
  bash -c "grep -qF 'BRANCH=\"\$BOOT_REF\"' '$RT'"
# ORDER, on real line numbers: the recording of TARGET_REF must precede the
# bootstrap block that consumes it, or the anchor is written after it was read.
REC_LINE=$(grep -n 'record-context.sh.*TARGET_REF=' "$RT" | head -1 | cut -d: -f1)
BOOT_REF_LINE=$(grep -n 'BOOT_REF=${TARGET_REF' "$RT" | head -1 | cut -d: -f1)
if [[ -n "$REC_LINE" ]] && [[ -n "$BOOT_REF_LINE" ]] && [[ "$REC_LINE" -lt "$BOOT_REF_LINE" ]]; then
  pass "TARGET_REF is recorded into the anchor BEFORE the bootstrap block reads it (record=$REC_LINE, read=$BOOT_REF_LINE)"
else
  fail "TARGET_REF must be recorded before the bootstrap block reads it (record=${REC_LINE:-<none>}, read=${BOOT_REF_LINE:-<none>})"
fi
# Both inputs come off the anchor with the BARE form (empty is a legitimate answer
# for each — no refspec given, no --template-path), read before the derivation.
for k in TARGET_REF TEMPLATE_LOCAL_BRANCH; do
  KL=$(grep -n "^ *$k=\$(sed -n 's/^$k=//p'" "$RT" | head -1 | cut -d: -f1)
  if [[ -n "$KL" ]] && [[ -n "$BOOT_REF_LINE" ]] && [[ "$KL" -lt "$BOOT_REF_LINE" ]]; then
    pass "$k is read off the anchor (bare form) before BOOT_REF is derived"
  else
    fail "$k is read off the anchor (bare form) before BOOT_REF is derived (read=${KL:-<none>} boot-ref=${BOOT_REF_LINE:-<none>})"
  fi
done
expect "the block says WHY at the call site (the detector defaults to main)" \
  bash -c "grep -B12 -F 'BOOT_REF=\${TARGET_REF' '$RT' | grep -qi 'defaults to main'"
expect "the detector's contract doc names the caller's duty to pass the resolved branch" \
  bash -c "grep -qi 'resolved' '$SKILL_DIR/reference/bellwether-detection.md' && grep -qF 'TEMPLATE_BRANCH' '$SKILL_DIR/reference/bellwether-detection.md'"

# reference/bellwether-detection.md used to carry a STANDALONE runnable copy of the
# bootstrap invocation, and the two copies drifted (observed live: the ASK line and
# the COMPONENT_NAME timing differed). The fix removed every runnable block from the
# doc: phases/2 is the single home (its anchor discipline is pinned against $RT
# above), and the reference keeps rationale plus delegation pointers only. These
# pins hold that shape — a runnable block reappearing here is the regression.
BWD=$SKILL_DIR/reference/bellwether-detection.md
refute "the detection doc carries no fenced runnable block (single home is phases/2)" \
  grep -q '^```' "$BWD"
expect "the detection doc delegates the manifest-write block to phases/2" \
  bash -c "grep -F 'ACTION=bootstrap' '$BWD' | grep -qF 'phases/2-resolve-target.md'"
expect "the detection doc delegates the frontend-arm invocation block to phases/2" \
  bash -c "grep -F 'invocation block' '$BWD' | grep -qF 'phases/2-resolve-target.md'"
refute "the detection doc no longer promises BRANCH defaults to main when omitted" \
  bash -c "grep -F 'BRANCH' '$BWD' | grep -qi 'defaults to .main. when omitted'"
expect "the detection doc says BRANCH is required and the writer refuses without it" \
  bash -c "grep -F 'BRANCH' '$BWD' | grep -qiE 'required|refuses'"

fi

if t "in-progress.sh set — writes the complete block"; then
IP=$SANDBOX/ip-set
ip_fixture "$IP"

( cd "$IP" && ACTION=set PHASE_KEY=$PK_BRANCH \
    TARGET_SHA=2222222222222222222222222222222222222222 \
    BRANCH=topic/tester/template-update-2222222 \
    PREV_BRANCH=main \
    PREV_SHA=3333333333333333333333333333333333333333 \
    bash "$IPS" ) > "$SANDBOX/ip-set.out" 2> "$SANDBOX/ip-set.err"; rc=$?
expect "set exits 0" test "$rc" -eq 0
expect "set writes target_sha" \
  bash -c "test \"\$(yq -r '.template.in_progress.target_sha' '$IP/.kairos/manifest.yaml')\" = 2222222222222222222222222222222222222222"
expect "set writes branch" \
  bash -c "test \"\$(yq -r '.template.in_progress.branch' '$IP/.kairos/manifest.yaml')\" = topic/tester/template-update-2222222"
expect "set writes previous_branch" \
  bash -c "test \"\$(yq -r '.template.in_progress.previous_branch' '$IP/.kairos/manifest.yaml')\" = main"
expect "set writes previous_sha" \
  bash -c "test \"\$(yq -r '.template.in_progress.previous_sha' '$IP/.kairos/manifest.yaml')\" = 3333333333333333333333333333333333333333"
expect "set leaves the rest of the manifest intact (template.sha)" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 1111111111111111111111111111111111111111"
expect "set leaves the component name intact" \
  bash -c "test \"\$(yq -r '.name' '$IP/.kairos/manifest.yaml')\" = mycomp"

fi

if t "in-progress.sh set — every key it wrote is read back, not just previous_branch"; then
# FINDING (verified, mutation-checked): ACTION=set writes target_sha (reference/
# continue.md's lost-anchor recovery arm depends on it), but rewrite() used to
# verify the read-back for previous_branch alone — the key whose ABSENCE
# produces the pre-flight deadlock. A wrong-but-non-empty target_sha (or
# previous_sha, or branch) would be adopted silently by a resume: the manifest
# parses fine and describes a different target.
#
# Proven by MUTATION, the same pattern the bootstrap value-checks use: a `yq`
# shim ahead of the real one on PATH intercepts ONLY the call that builds the
# whole in_progress mapping (matched on the literal expression prefix) and
# corrupts one emitted key, leaving every other yq call — including the
# read-back itself — untouched. Each case is its own component dir so the
# fixture stays independent.
REAL_YQ=$(command -v yq)
set_case() { # set_case <label> <key> <before-line> <after-line>
  local label="$1" key="$2" before="$3" after="$4" dir="$SANDBOX/ip-set-$1"
  ip_fixture "$dir"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/yq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *'.template.in_progress = {'*)
      "$REAL_YQ" "\$@" | sed 's#$before#$after#'
      exit \${PIPESTATUS[0]}
      ;;
  esac
done
exec "$REAL_YQ" "\$@"
EOF
  chmod +x "$dir/bin/yq"

  # Sanity: the shim really does corrupt the write it targets, or this proves
  # nothing.
  ( cd "$dir" && PATH="$dir/bin:$PATH" \
      TARGET_SHA=2222222222222222222222222222222222222222 \
      BRANCH=topic/tester/set-mutate PREV_BRANCH=main \
      PREV_SHA=3333333333333333333333333333333333333333 \
      yq '.template.in_progress = {"target_sha": strenv(TARGET_SHA), "branch": strenv(BRANCH), "previous_branch": strenv(PREV_BRANCH), "previous_sha": strenv(PREV_SHA)}' \
      .kairos/manifest.yaml ) > "$SANDBOX/ip-set-$label.shim" 2>/dev/null
  expect "the $key shim really mutates the write (self-test of the injection)" \
    grep -qF "$after" "$SANDBOX/ip-set-$label.shim"

  ( cd "$dir" && PATH="$dir/bin:$PATH" ACTION=set PHASE_KEY=$PK_BRANCH \
      TARGET_SHA=2222222222222222222222222222222222222222 \
      BRANCH=topic/tester/set-mutate \
      PREV_BRANCH=main PREV_SHA=3333333333333333333333333333333333333333 \
      bash "$IPS" ) > "$SANDBOX/ip-set-$label.out" 2> "$SANDBOX/ip-set-$label.err"
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    pass "set refuses a mangled $key (its read-back is verified)"
  else
    fail "set refuses a mangled $key (its read-back is verified) (rc=$rc)"
  fi
  expect "the mangled-$key refusal names $key" grep -qF "$key" "$SANDBOX/ip-set-$label.err"
  refute "the mangled-$key refusal left no in_progress key behind" \
    bash -c "yq -e '.template | has(\"in_progress\")' '$dir/.kairos/manifest.yaml' >/dev/null 2>&1"
  refute "no temp manifest is left behind by the mangled-$key refusal" \
    bash -c "ls '$dir/.kairos'/.manifest.yaml.* >/dev/null 2>&1"
}

set_case target_sha target_sha \
  'target_sha: "2222222222222222222222222222222222222222"' \
  'target_sha: "0000000000000000000000000000000000000000"'
set_case previous_sha previous_sha \
  'previous_sha: "3333333333333333333333333333333333333333"' \
  'previous_sha: "0000000000000000000000000000000000000000"'
set_case branch branch \
  'branch: topic/tester/set-mutate' \
  'branch: topic/tester/other'

fi

if t "in-progress.sh set — the block is unwritable while incomplete"; then
# The whole point of the script: the deadlock state (a block that reads as live
# but carries no previous_branch) cannot be produced. Every required value is
# refused individually, empty is refused the same as unset, and a refusal writes
# NOTHING — the manifest is byte-identical afterwards, so a rejected call can
# never leave a half-block behind.
IP=$SANDBOX/ip-partial
ip_fixture "$IP"
cp "$IP/.kairos/manifest.yaml" "$SANDBOX/ip-partial.orig"

ip_set() { ( cd "$IP" && env ACTION=set PHASE_KEY=$PK_BRANCH "$@" bash "$IPS" ); }

for v in TARGET_SHA PREV_BRANCH PREV_SHA; do
  # Unset: the other two are supplied, so only the missing one can be the cause.
  args=""
  [[ "$v" = TARGET_SHA ]]  || args="$args TARGET_SHA=aaaa"
  [[ "$v" = PREV_BRANCH ]] || args="$args PREV_BRANCH=main"
  [[ "$v" = PREV_SHA ]]    || args="$args PREV_SHA=bbbb"
  # shellcheck disable=SC2086
  if ip_set $args > /dev/null 2> "$SANDBOX/ip-miss-$v.err"; then
    fail "set with $v unset exits non-zero"
  else
    pass "set with $v unset exits non-zero"
  fi
  expect "the $v refusal names $v" grep -qF "$v" "$SANDBOX/ip-miss-$v.err"
  # shellcheck disable=SC2086
  if ip_set $args "$v=" > /dev/null 2>&1; then
    fail "set with an EMPTY $v exits non-zero"
  else
    pass "set with an EMPTY $v exits non-zero"
  fi
  # Whitespace-only is as empty as unset — a value made of spaces must not make
  # the block writable.
  # shellcheck disable=SC2086
  if ip_set $args "$v=   " > /dev/null 2>&1; then
    fail "set with a whitespace-only $v exits non-zero"
  else
    pass "set with a whitespace-only $v exits non-zero"
  fi
done

expect "every refused set left the manifest BYTE-IDENTICAL (no partial block)" \
  cmp -s "$SANDBOX/ip-partial.orig" "$IP/.kairos/manifest.yaml"
refute "no refused set produced an in_progress key at all" \
  bash -c "yq -e '.template | has(\"in_progress\")' '$IP/.kairos/manifest.yaml' >/dev/null 2>&1"
refute "no temp file was left beside the manifest" \
  bash -c "ls '$IP/.kairos'/.manifest.yaml.* >/dev/null 2>&1"

fi

if t "in-progress.sh set — BRANCH is optional and its key is OMITTED when unset"; then
# Under --no-branch Phase 4 deliberately records no `branch:`, because abort's
# delete would otherwise target the checked-out branch. The key must be ABSENT,
# not present-and-empty: abort reads it with `// ""`, so an empty string and an
# absent key behave the same there — but a written-empty key is a shape the
# phase file has never documented, and `[ -n "$BRANCH" ]` is not the only reader
# this block will ever have.
IP=$SANDBOX/ip-nobranch
ip_fixture "$IP"
( cd "$IP" && env -u BRANCH ACTION=set PHASE_KEY=$PK_BRANCH \
    TARGET_SHA=4444 PREV_BRANCH=main PREV_SHA=5555 bash "$IPS" ) >/dev/null 2>&1
expect "set with BRANCH unset exits 0" test $? -eq 0
refute "the branch key is ABSENT, not written empty" \
  bash -c "yq -e '.template.in_progress | has(\"branch\")' '$IP/.kairos/manifest.yaml' >/dev/null 2>&1"
expect "the three required keys are still written" \
  bash -c "test \"\$(yq -r '.template.in_progress | keys | join(\",\")' '$IP/.kairos/manifest.yaml')\" = 'target_sha,previous_branch,previous_sha'"

fi

if t "in-progress.sh set — re-run safe: a partial block is overwritten complete"; then
# continue.md's "redo the in_progress write if needed" path: a crash between the
# manifest write and the scaffolding commit leaves whatever Phase 4 got as far
# as. Re-running set must yield a COMPLETE block, and must not leave a stale key
# from the previous shape behind.
IP=$SANDBOX/ip-redo
ip_fixture "$IP"
yq -i '.template.in_progress = {"branch": "topic/tester/half-written"}' "$IP/.kairos/manifest.yaml"
expect "the fixture starts as a PARTIAL block (the deadlock shape)" \
  bash -c "test \"\$(yq -r '.template.in_progress.previous_branch // \"\"' '$IP/.kairos/manifest.yaml')\" = ''"

( cd "$IP" && env -u BRANCH ACTION=set PHASE_KEY=$PK_BRANCH \
    TARGET_SHA=6666 PREV_BRANCH=main PREV_SHA=7777 bash "$IPS" ) >/dev/null 2>&1
expect "the redo exits 0" test $? -eq 0
expect "the redone block carries previous_branch" \
  bash -c "test \"\$(yq -r '.template.in_progress.previous_branch' '$IP/.kairos/manifest.yaml')\" = main"
refute "the stale branch: key from the partial block is GONE (whole-block write)" \
  bash -c "yq -e '.template.in_progress | has(\"branch\")' '$IP/.kairos/manifest.yaml' >/dev/null 2>&1"

fi

if t "in-progress.sh clear — deletes the KEY, never empties the mapping"; then
# THE assertion this script exists for. Phase 8 step 5 says "remove the
# template.in_progress block"; a model that empties the mapping instead of
# deleting the key leaves `in_progress: {}` behind, which pre-flight's
# `// ""` read scores as a LIVE migration — on a migration that finished
# successfully. `has("in_progress")` is the only check that distinguishes a
# deleted key from an empty or null-valued one, so it is what we assert.
IP=$SANDBOX/ip-clear
for shape in full empty null; do
  ip_fixture "$IP"
  case "$shape" in
    full)  yq -i '.template.in_progress = {"target_sha": "8888", "branch": "topic/t/u", "previous_branch": "main", "previous_sha": "9999"}' "$IP/.kairos/manifest.yaml" ;;
    empty) yq -i '.template.in_progress = {}' "$IP/.kairos/manifest.yaml" ;;
    null)  yq -i '.template.in_progress = null' "$IP/.kairos/manifest.yaml" ;;
  esac
  expect "the $shape-block fixture is present before clear" \
    bash -c "yq -e '.template | has(\"in_progress\")' '$IP/.kairos/manifest.yaml' >/dev/null 2>&1"

  ( cd "$IP" && env -u PHASE_KEY ACTION=clear bash "$IPS" ) \
    > "$SANDBOX/ip-clear-$shape.out" 2> "$SANDBOX/ip-clear-$shape.err"; rc=$?
  expect "clear on a $shape block exits 0" test "$rc" -eq 0
  refute "clear on a $shape block leaves NO in_progress key (not {}, not null)" \
    bash -c "yq -e '.template | has(\"in_progress\")' '$IP/.kairos/manifest.yaml' >/dev/null 2>&1"
  expect "clear on a $shape block reports 'cleared'" \
    grep -qx 'cleared' "$SANDBOX/ip-clear-$shape.out"
done

# Scope stops at the block: clear must never advance the baseline, or abort —
# which calls the same script while rolling a migration BACK — would finalize it.
expect "clear left template.sha untouched (it does not advance the baseline)" \
  bash -c "test \"\$(yq -r '.template.sha' '$IP/.kairos/manifest.yaml')\" = 1111111111111111111111111111111111111111"
expect "clear preserved template.repo" \
  bash -c "test \"\$(yq -r '.template.repo' '$IP/.kairos/manifest.yaml')\" = file:///srv/template.git"
expect "clear preserved template.branch" \
  bash -c "test \"\$(yq -r '.template.branch' '$IP/.kairos/manifest.yaml')\" = main"
expect "clear preserved the component name" \
  bash -c "test \"\$(yq -r '.name' '$IP/.kairos/manifest.yaml')\" = mycomp"

fi

if t "in-progress.sh clear — idempotent no-op on a manifest with no block"; then
# abort.md's "If there's no in_progress block, abort is a no-op" contract. A
# no-op must not rewrite the manifest either: a gratuitous yq round-trip on a
# tracked file would dirty the working tree that pre-flight check 1 demands be
# clean, blocking the user's next run over a call that changed nothing.
IP=$SANDBOX/ip-noop
ip_fixture "$IP"
cp "$IP/.kairos/manifest.yaml" "$SANDBOX/ip-noop.orig"
( cd "$IP" && env -u PHASE_KEY ACTION=clear bash "$IPS" ) \
  > "$SANDBOX/ip-noop.out" 2>&1; rc=$?
expect "clear with no block exits 0" test "$rc" -eq 0
expect "clear with no block reports 'unchanged'" grep -qx 'unchanged' "$SANDBOX/ip-noop.out"
expect "clear with no block left the manifest BYTE-IDENTICAL" \
  cmp -s "$SANDBOX/ip-noop.orig" "$IP/.kairos/manifest.yaml"

fi

if t "in-progress.sh clear — KEYLESS by design, and set is not"; then
# Two callers in non-equivalent contexts: phases/8-finalize.md (whose guarded
# entry point is gate.sh under LABEL=final, not this script) and
# reference/abort.md — a reference document that holds no phase key at all.
# Guarding clear on Phase 4's key would brick abort, which is the ONE remedy for
# a component already carrying a bad block. So clear must not appear in the
# PHASE_KEY inventory skill-lint.test.sh audits.
IP=$SANDBOX/ip-keyless
ip_fixture "$IP"
yq -i '.template.in_progress = {}' "$IP/.kairos/manifest.yaml"
( cd "$IP" && env -u PHASE_KEY ACTION=clear bash "$IPS" ) > /dev/null 2> "$SANDBOX/ip-keyless.err"; rc=$?
expect "clear runs with NO PHASE_KEY in the environment" test "$rc" -eq 0
refute "clear never asks for a phase file to be loaded" \
  grep -q 'load phases/' "$SANDBOX/ip-keyless.err"
( cd "$IP" && ACTION=clear PHASE_KEY=not-the-key bash "$IPS" ) > /dev/null 2>&1
expect "clear ignores a WRONG PHASE_KEY too (it is not gated on one)" test $? -eq 0

# set, by contrast, IS Phase 4's write and is gated on Phase 4's key.
( cd "$IP" && env -u PHASE_KEY ACTION=set TARGET_SHA=a PREV_BRANCH=main PREV_SHA=b bash "$IPS" ) \
  > /dev/null 2> "$SANDBOX/ip-setnokey.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/4-migration-branch.md first' "$SANDBOX/ip-setnokey.err"; then
  pass "set without PHASE_KEY is refused: load phases/4-migration-branch.md first"
else
  fail "set without PHASE_KEY is refused: load phases/4-migration-branch.md first (rc=$rc)"
fi

fi

if t "in-progress.sh — the yq semantics the deadlock rests on"; then
# Pinned explicitly because the REASON a VALUE read cannot decide presence lives in
# mikefarah/yq's `// ""` behaviour and nowhere in this repo. Two roundings, and only
# one of them is survivable: an empty mapping is a VALUE, so `{}` comes back
# non-empty — but a NULL-valued key rounds to "", which is byte-identical to what a
# DELETED key returns. That second rounding is why neither this script nor
# pre-flight may read the value to decide whether a migration is live: `in_progress:`
# with nothing under it (a hand-edit, or a conflicted-merge restore of the committed
# manifest — the two sources reference/abort.md names) would read as "no migration"
# and let a fresh run sweep a LIVE run's state. Both readers use
# `.template | has("in_progress")` instead — "the only check that tells a deleted key
# apart from one left empty or null", as this script's clear action puts it. These
# assertions pin the rounding that makes has() mandatory AND that has() is not
# subject to it. If pre-flight's yq build check ever loosens, this is the block to
# re-check.
IP=$SANDBOX/ip-yq
IPYQ=$IP/.kairos/manifest.yaml
ip_fixture "$IP"
yq -i '.template.in_progress = {}' "$IPYQ"
expect "an EMPTY mapping survives '// \"\"' — the value read happens to see this one" \
  bash -c "test -n \"\$(yq -r '.template.in_progress // \"\"' '$IPYQ')\""
expect "and has() reports the empty mapping PRESENT (a live migration)" \
  bash -c "test \"\$(yq -r '.template | has(\"in_progress\")' '$IPYQ')\" = true"
ip_fixture "$IP"
yq -i '.template.in_progress = null' "$IPYQ"
expect "a NULL-valued key rounds to '' under '// \"\"' — indistinguishable from deleted" \
  bash -c "test -z \"\$(yq -r '.template.in_progress // \"\"' '$IPYQ')\""
expect "has() is NOT subject to that rounding: a null-valued key is PRESENT" \
  bash -c "test \"\$(yq -r '.template | has(\"in_progress\")' '$IPYQ')\" = true"
ip_fixture "$IP"
yq -i 'del(.template.in_progress)' "$IPYQ"
expect "a DELETED key is the only shape has() reports as absent" \
  bash -c "test \"\$(yq -r '.template | has(\"in_progress\")' '$IPYQ')\" = false"
expect "and an absent template.in_progress with no template block at all reads false too" \
  bash -c "printf 'name: x\n' > '$IP/.kairos/bare.yaml'; test \"\$(yq -r '.template | has(\"in_progress\")' '$IP/.kairos/bare.yaml')\" = false"

fi

if t "continue-mode task counting is anchored on previous_sha, not the branch ref"; then
# C7. Continue mode infers the resume phase by counting the `migrate(Txx):`
# commits, and it counted them over `$PREV_BRANCH..HEAD`. Under `--no-branch` the
# migration commits land on the user's OWN branch — so previous_branch IS the
# checked-out branch, its ref moved with every migration commit, and the range is
# empty. Every commit of the run becomes invisible at once: zero tasks, no plan
# commit, no structural commit, so the resume re-enters Phase 5 and redoes the
# structural merge over a tree that already carries K task commits.
#
# The fixture below is the reproduction: the same history counted both ways. The
# anchor is `previous_sha` — written on EVERY path by this script's `set` action
# and recorded into $RUN/context.env by Phase 4 — because a SHA cannot move. This
# is the same reason abort resets to previous_sha and Phase 8 squashes to it.
NB=$SANDBOX/nobranch && rm -rf "$NB" && mkdir -p "$NB/.kairos"
cd "$NB"
git init -q -b main
printf 'name: mycomp\ntemplate:\n  repo: file:///srv/t.git\n  sha: %040d\n  branch: main\n' 1 \
  > .kairos/manifest.yaml
echo one > src.txt
git add -A && git commit -qm "component work"
NB_PREV_SHA=$(git rev-parse HEAD)
NB_PREV_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Phase 4 under --no-branch: no checkout -b, BRANCH deliberately unset so the
# block omits `branch:` (which is how three readers infer --no-branch at all).
ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=$(printf '%040d' 2) \
  PREV_BRANCH=$NB_PREV_BRANCH PREV_SHA=$NB_PREV_SHA bash "$IPS" >/dev/null
expect "the --no-branch block records previous_sha" \
  bash -c "test \"\$(yq -r '.template.in_progress.previous_sha' '$NB/.kairos/manifest.yaml')\" = $NB_PREV_SHA"
refute "the --no-branch block carries no branch: key (this is what marks the mode)" \
  bash -c "yq -e '.template.in_progress | has(\"branch\")' '$NB/.kairos/manifest.yaml' >/dev/null 2>&1"

# The run so far: scaffolding, structural, plan, and TWO task commits — all on the
# user's own branch, exactly as --no-branch prescribes.
git add -A && git commit -qm "chore: begin migration to 0000000"
echo two >> src.txt && git commit -qam "chore: structural merge to 0000000"
mkdir -p .kairos/migration && echo plan > .kairos/migration/PLAN.md
git add -A && git commit -qm "chore: migration plan for 0000000"
echo t1 >> src.txt && git commit -qam "migrate(T01): first"
echo t2 >> src.txt && git commit -qam "migrate(T02): second"

count_tasks() { git log --oneline "$1..HEAD" | grep -c 'migrate(T[0-9]\{1,\}):' || true; }
NB_BY_BRANCH=$(count_tasks "$NB_PREV_BRANCH")
NB_BY_SHA=$(count_tasks "$NB_PREV_SHA")
# The defect, demonstrated on real history rather than asserted in prose.
if [[ "$NB_BY_BRANCH" -eq 0 ]]; then
  pass "the branch-anchored range is EMPTY under --no-branch (0 tasks counted from 2)"
else
  fail "the branch-anchored range is EMPTY under --no-branch (got $NB_BY_BRANCH)"
fi
if [[ "$NB_BY_SHA" -eq 2 ]]; then
  pass "the previous_sha-anchored range counts both task commits (resume at task 3)"
else
  fail "the previous_sha-anchored range counts both task commits (got $NB_BY_SHA)"
fi
# ...and the structural commit, whose absence is what re-enters Phase 5.
expect "previous_sha also makes the structural commit visible to the resume" \
  bash -c "git -C '$NB' log --oneline '$NB_PREV_SHA..HEAD' | grep -q 'structural merge'"
refute "the branch ref hides the structural commit (the wrong-phase re-entry)" \
  bash -c "git -C '$NB' log --oneline '$NB_PREV_BRANCH..HEAD' | grep -q 'structural merge'"
cd "$SANDBOX"

# The counting itself is orchestrator prose, so the contract is pinned on the doc
# — the same way the previous_branch chain always has been (merge-path.test.sh).
CD=$SKILL_DIR/reference/continue.md
expect "continue.md counts task commits against \$PREV_SHA" \
  grep -qF 'git log --oneline $PREV_SHA..HEAD' "$CD"
# The branch-anchored range may still be NAMED (the doc explains why it is wrong),
# but never as the command: what must be gone is `git log … $PREV_BRANCH..HEAD`.
refute "continue.md no longer counts task commits against the branch ref" \
  grep -qE 'git log[^`]*\$PREV_BRANCH\.\.HEAD' "$CD"
expect "continue.md takes PREV_SHA from the run-context anchor" \
  bash -c "grep -F 'PREV_SHA=' '$CD' | grep -q 'ctx PREV_SHA'"
expect "continue.md says why the SHA and not the branch (--no-branch)" \
  bash -c "grep -A10 -F 'git log --oneline \$PREV_SHA..HEAD' '$CD' | grep -qF -- '--no-branch'"

fi

if t "in-progress.sh — bad input is refused, and a missing manifest is not silent"; then
IP=$SANDBOX/ip-bad
ip_fixture "$IP"
refute "an unknown ACTION is refused" \
  bash -c "cd '$IP' && ACTION=purge PHASE_KEY=$PK_BRANCH bash '$IPS' >/dev/null 2>&1"
refute "an ACTION of nothing (with the key in hand) is refused" \
  bash -c "cd '$IP' && env -u ACTION PHASE_KEY=$PK_BRANCH bash '$IPS' >/dev/null 2>&1"
# A wrong cwd must never read as "nothing to clear" — that is fail-open on the
# exact interlock this script owns.
IPX=$SANDBOX/ip-nomanifest && rm -rf "$IPX" && mkdir -p "$IPX"
refute "clear in a directory with no manifest is refused, not reported as a no-op" \
  bash -c "cd '$IPX' && env -u PHASE_KEY ACTION=clear bash '$IPS' >/dev/null 2>&1"
refute "set in a directory with no manifest is refused" \
  bash -c "cd '$IPX' && ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=a PREV_BRANCH=m PREV_SHA=b bash '$IPS' >/dev/null 2>&1"
# Fail CLOSED on a manifest yq cannot read — the same rule pre-flight applies.
IPC=$SANDBOX/ip-corrupt && rm -rf "$IPC" && mkdir -p "$IPC/.kairos"
printf 'template:\n  in_progress: [unclosed\n' > "$IPC/.kairos/manifest.yaml"
refute "clear on an UNPARSEABLE manifest is refused (fail closed)" \
  bash -c "cd '$IPC' && env -u PHASE_KEY ACTION=clear bash '$IPS' >/dev/null 2>&1"
expect "the refused clear left the corrupt manifest untouched" \
  grep -qF 'in_progress: [unclosed' "$IPC/.kairos/manifest.yaml"

fi

if t "in-progress.sh SOURCE selects the manifest key, and refuses anything else"; then
# ONE env var parameterizes every action, because a frontend migration is a second
# RUN of the same machinery — not a second machinery. The default is `template`, so
# every pre-frontend caller keeps working unchanged; an UNKNOWN value is refused
# rather than defaulted, because a typo'd SOURCE that fell back to `template` would
# move the TEMPLATE baseline on a frontend run — a wrong baseline that nothing
# re-examines until the next migration diffs from it.
IPS_SRC=$SANDBOX/ip-source
ip_fixture "$IPS_SRC"
( cd "$IPS_SRC" && ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=aaa PREV_BRANCH=main PREV_SHA=bbb \
    bash "$IPS" ) >/dev/null 2>&1
expect "SOURCE unset writes template.in_progress (the default is the old behavior)" \
  bash -c "test \"\$(yq -r '.template.in_progress.target_sha' '$IPS_SRC/.kairos/manifest.yaml')\" = aaa"
expect "and writes nothing under .frontend" \
  bash -c "test \"\$(yq -r 'has(\"frontend\")' '$IPS_SRC/.kairos/manifest.yaml')\" = false"
for bad in Frontend web '' template2; do
  refute "SOURCE='$bad' is refused, not defaulted (clear)" \
    bash -c "cd '$IPS_SRC' && SOURCE='$bad' env -u PHASE_KEY ACTION=clear bash '$IPS' >/dev/null 2>&1"
done
( cd "$IPS_SRC" && SOURCE=bogus env -u PHASE_KEY ACTION=clear bash "$IPS" ) \
  > /dev/null 2> "$SANDBOX/ip-badsrc.log"
expect "the refusal names the closed set" grep -qF 'want template|frontend' "$SANDBOX/ip-badsrc.log"
expect "the refused call left the template block intact" \
  bash -c "test \"\$(yq -r '.template.in_progress.target_sha' '$IPS_SRC/.kairos/manifest.yaml')\" = aaa"
fi

if t "in-progress.sh set refuses while the OTHER source has a live block"; then
# Exactly one live migration per component. Both blocks are read as live by
# pre-flight, continue and abort, and each of those three answers a question that
# has no meaning for two — which branch to check out, which run to resume, which
# SHA to roll back to. So the state is made UNPRODUCIBLE at the one script that
# could write either, not merely discouraged, and a refusal writes NOTHING.
IPMX=$SANDBOX/ip-mutex
ip_fixture "$IPMX"
fe_boot() { ( cd "$IPMX" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE \
    REPO=git@bb:ifs-pd/kairos-frontend.git MODULE=react MODULE_PATH=template/react \
    BRANCH=main BASE_SHA=2222222222222222222222222222222222222222 bash "$IPS" ); }
fe_boot >/dev/null 2>&1

# Frontend live, template asked for: refused.
( cd "$IPMX" && SOURCE=frontend ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=fe-target \
    PREV_BRANCH=main PREV_SHA=aaa bash "$IPS" ) >/dev/null 2>&1
expect "the frontend block is live" \
  bash -c "test \"\$(yq -r '.frontend.in_progress.target_sha' '$IPMX/.kairos/manifest.yaml')\" = fe-target"
( cd "$IPMX" && ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=tpl-target \
    PREV_BRANCH=main PREV_SHA=bbb bash "$IPS" ) > /dev/null 2> "$SANDBOX/ip-mx1.log"
IP_MX1_RC=$?
if [[ "$IP_MX1_RC" -ne 0 ]]; then
  pass "a template set is refused while frontend.in_progress exists"
else
  fail "a template set was written while frontend.in_progress exists (two live migrations)"
fi
expect "the refusal names the other source's block" \
  grep -qF 'already carries a frontend.in_progress block' "$SANDBOX/ip-mx1.log"
expect "the refusal says exactly one migration is live at a time" \
  grep -qF 'exactly one migration is live at a time' "$SANDBOX/ip-mx1.log"
expect "the refused set wrote NOTHING under .template" \
  bash -c "test \"\$(yq -r '.template | has(\"in_progress\")' '$IPMX/.kairos/manifest.yaml')\" = false"

# And the mirror direction, once the frontend block is cleared and a template one set.
( cd "$IPMX" && SOURCE=frontend env -u PHASE_KEY ACTION=clear bash "$IPS" ) >/dev/null 2>&1
( cd "$IPMX" && ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=tpl-target \
    PREV_BRANCH=main PREV_SHA=bbb bash "$IPS" ) >/dev/null 2>&1
expect "clearing the frontend block unblocks the template set" \
  bash -c "test \"\$(yq -r '.template.in_progress.target_sha' '$IPMX/.kairos/manifest.yaml')\" = tpl-target"
( cd "$IPMX" && SOURCE=frontend ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=fe2 \
    PREV_BRANCH=main PREV_SHA=ccc bash "$IPS" ) > /dev/null 2> "$SANDBOX/ip-mx2.log"
IP_MX2_RC=$?
if [[ "$IP_MX2_RC" -ne 0 ]]; then
  pass "a frontend set is refused while template.in_progress exists"
else
  fail "a frontend set was written while template.in_progress exists (two live migrations)"
fi
expect "that refusal names the template block" \
  grep -qF 'already carries a template.in_progress block' "$SANDBOX/ip-mx2.log"
expect "and it wrote nothing under .frontend" \
  bash -c "test \"\$(yq -r '.frontend | has(\"in_progress\")' '$IPMX/.kairos/manifest.yaml')\" = false"

# clear is per-source: clearing one must not touch the other's block.
( cd "$IPMX" && env -u PHASE_KEY ACTION=clear bash "$IPS" ) >/dev/null 2>&1
expect "clear SOURCE=template removed only the template block" \
  bash -c "test \"\$(yq -r '.template | has(\"in_progress\")' '$IPMX/.kairos/manifest.yaml')\" = false"
expect "and left the frontend baseline recorded" \
  bash -c "test \"\$(yq -r '.frontend.sha' '$IPMX/.kairos/manifest.yaml')\" = 2222222222222222222222222222222222222222"
fi

if t "in-progress.sh bootstrap SOURCE=frontend adds the frontend block to an EXISTING manifest"; then
# The frontend arm is NOT the founding write the template arm is: the manifest
# exists, the component is already provenanced, and what is missing is one source's
# baseline. Same read-back discipline either way — every caller-supplied value
# re-read off the bytes about to land, `!!str` on the strings, `!!bool` on
# `bootstrapped` — because nothing reads a founding baseline again until the next
# migration diffs from it.
IPFB=$SANDBOX/ip-fe-boot
ip_fixture "$IPFB"
( cd "$IPFB" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE \
    REPO=git@bitbucket.org:ifs-pd/kairos-frontend.git MODULE=react MODULE_PATH=template/react \
    BRANCH=main BASE_SHA=2222222222222222222222222222222222222222 \
    bash "$IPS" ) > "$SANDBOX/ip-feb.out" 2> "$SANDBOX/ip-feb.err"; rc=$?
expect "frontend bootstrap exits 0" test "$rc" -eq 0
expect "it prints bootstrapped" grep -qx bootstrapped "$SANDBOX/ip-feb.out"
M=$IPFB/.kairos/manifest.yaml
# The REPO passed names the old Bitbucket SSH host; bootstrap records the current one.
expect "frontend.repo lands, on the current Bitbucket SSH host" \
  bash -c "test \"\$(yq -r '.frontend.repo' '$M')\" = git@ssh.bitbucket.org:ifs-pd/kairos-frontend.git"
expect "frontend.path lands"     bash -c "test \"\$(yq -r '.frontend.path' '$M')\" = template/react"
expect "frontend.template lands the MODULE KEY" bash -c "test \"\$(yq -r '.frontend.template' '$M')\" = react"
expect "frontend.branch lands"   bash -c "test \"\$(yq -r '.frontend.branch' '$M')\" = main"
expect "frontend.sha lands"      bash -c "test \"\$(yq -r '.frontend.sha' '$M')\" = 2222222222222222222222222222222222222222"
# bootstrapped is load-bearing as a BOOLEAN, and it is written by the script rather
# than transcribed from a doc because one dropped line removes the caution silently.
expect "frontend.bootstrapped is a YAML boolean, not a string" \
  bash -c "test \"\$(yq -r '.frontend.bootstrapped | tag' '$M')\" = '!!bool'"
# An all-digit 40-hex SHA is a valid YAML float; a branch named 1.0 likewise.
expect "the SHA is a YAML string" bash -c "test \"\$(yq -r '.frontend.sha | tag' '$M')\" = '!!str'"
# web/ is the documented default mount, so the key is OMITTED — a key that only
# repeats the default forces every later reader to tell a deliberate web/ apart
# from an incidental one.
expect "an unset MOUNT omits the key entirely" \
  bash -c "test \"\$(yq -r '.frontend | has(\"mount\")' '$M')\" = false"
expect "the template block is untouched" \
  bash -c "test \"\$(yq -r '.template.sha' '$M')\" = 1111111111111111111111111111111111111111"
expect "and the component name survives" bash -c "test \"\$(yq -r '.name' '$M')\" = mycomp"

# MOUNT=web/ is the same as omitting it; anything else is recorded verbatim.
IPFB2=$SANDBOX/ip-fe-boot2
ip_fixture "$IPFB2"
( cd "$IPFB2" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=r MODULE=react \
    MODULE_PATH=template/react BRANCH=main MOUNT=web/ \
    BASE_SHA=2222222222222222222222222222222222222222 bash "$IPS" ) >/dev/null 2>&1
expect "an explicit MOUNT=web/ is still omitted (it is the default)" \
  bash -c "test \"\$(yq -r '.frontend | has(\"mount\")' '$IPFB2/.kairos/manifest.yaml')\" = false"
IPFB3=$SANDBOX/ip-fe-boot3
ip_fixture "$IPFB3"
( cd "$IPFB3" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=r MODULE=react \
    MODULE_PATH=template/react BRANCH=main MOUNT=apps/ui/ \
    BASE_SHA=2222222222222222222222222222222222222222 bash "$IPS" ) >/dev/null 2>&1
expect "a non-default MOUNT is recorded verbatim" \
  bash -c "test \"\$(yq -r '.frontend.mount' '$IPFB3/.kairos/manifest.yaml')\" = apps/ui/"

# Every value the block cannot be guessed from is REQUIRED. MODULE especially: it
# selects the subtree, the upgrade-file directory and the bellwethers on every
# future run, and nothing in the skill knows which modules the source repo declares.
fb() { IPFBX=$SANDBOX/ip-fe-bx; ip_fixture "$IPFBX"; ( cd "$IPFBX" && env SOURCE=frontend \
  ACTION=bootstrap PHASE_KEY=$PK_RESOLVE "$@" bash "$IPS" >/dev/null 2>&1 ); }
for miss in MODULE MODULE_PATH BRANCH REPO; do
  ARGS=(REPO=r MODULE=react MODULE_PATH=template/react BRANCH=main BASE_SHA=2222222222222222222222222222222222222222)
  OUT=()
  for a in "${ARGS[@]}"; do case "$a" in "$miss"=*) ;; *) OUT+=("$a") ;; esac; done
  if fb "${OUT[@]}"; then
    fail "a missing $miss is refused"
  else
    pass "a missing $miss is refused"
  fi
done
if fb REPO=r MODULE=react MODULE_PATH=template/react BRANCH=main BASE_SHA=2222222; then
  fail "a short BASE_SHA is refused"
else
  pass "a short BASE_SHA is refused"
fi

# Runs ONCE per source, and only over a manifest that already exists.
( cd "$IPFB" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=r MODULE=react \
    MODULE_PATH=template/react BRANCH=main BASE_SHA=3333333333333333333333333333333333333333 \
    bash "$IPS" ) > /dev/null 2> "$SANDBOX/ip-feb2.log"
IP_FEB2_RC=$?
if [[ "$IP_FEB2_RC" -ne 0 ]]; then
  pass "a second frontend bootstrap is refused"
else
  fail "a second frontend bootstrap overwrote a recorded baseline"
fi
expect "the refused re-bootstrap left the recorded baseline alone" \
  bash -c "test \"\$(yq -r '.frontend.sha' '$M')\" = 2222222222222222222222222222222222222222"
IPFN=$SANDBOX/ip-fe-nomanifest; rm -rf "$IPFN"; mkdir -p "$IPFN"
refute "a frontend bootstrap with no manifest at all is refused (it ADDS a block)" \
  bash -c "cd '$IPFN' && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=r MODULE=react MODULE_PATH=p BRANCH=main BASE_SHA=2222222222222222222222222222222222222222 bash '$IPS' >/dev/null 2>&1"
fi

if t "in-progress.sh advance moves ONE source's baseline and leaves the other's alone"; then
# The advance is the run's deliverable — the write the NEXT migration reads as BASE.
# A chained invocation advances two baselines in two runs, and each must be able to
# land without disturbing the other: that is what makes "abort restores THIS run's
# start" survivable after the first run finished.
IPADV=$SANDBOX/ip-fe-advance
ip_fixture "$IPADV"
( cd "$IPADV" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=r MODULE=react \
    MODULE_PATH=template/react BRANCH=main BASE_SHA=2222222222222222222222222222222222222222 \
    bash "$IPS" ) >/dev/null 2>&1
MA=$IPADV/.kairos/manifest.yaml
( cd "$IPADV" && SOURCE=frontend ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=7777777777777777777777777777777777777777 bash "$IPS" ) >/dev/null 2>&1
expect "the frontend baseline advanced" \
  bash -c "test \"\$(yq -r '.frontend.sha' '$MA')\" = 7777777777777777777777777777777777777777"
expect "the TEMPLATE baseline is untouched by a frontend advance" \
  bash -c "test \"\$(yq -r '.template.sha' '$MA')\" = 1111111111111111111111111111111111111111"
expect "frontend.branch is left alone when BRANCH is not given" \
  bash -c "test \"\$(yq -r '.frontend.branch' '$MA')\" = main"
( cd "$IPADV" && SOURCE=frontend ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=8888888888888888888888888888888888888888 BRANCH=feat/fe bash "$IPS" ) >/dev/null 2>&1
expect "an explicitly targeted frontend branch is recorded" \
  bash -c "test \"\$(yq -r '.frontend.branch' '$MA')\" = feat/fe"
expect "the template branch is still untouched" \
  bash -c "test \"\$(yq -r '.template.branch' '$MA')\" = main"
( cd "$IPADV" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=9999999999999999999999999999999999999999 bash "$IPS" ) >/dev/null 2>&1
expect "a template advance then moves only the template baseline" \
  bash -c "test \"\$(yq -r '.template.sha' '$MA')\" = 9999999999999999999999999999999999999999"
expect "leaving the advanced frontend baseline in place" \
  bash -c "test \"\$(yq -r '.frontend.sha' '$MA')\" = 8888888888888888888888888888888888888888"
# advance MOVES a recorded baseline; it must never FOUND one. Without this, an
# advance on a component whose frontend was never provenanced leaves
# `frontend: {sha: …}` — a baseline with no repo, no module and no mount that every
# later reader treats as a recorded source.
IPNB=$SANDBOX/ip-fe-noblock
ip_fixture "$IPNB"
( cd "$IPNB" && SOURCE=frontend ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=7777777777777777777777777777777777777777 bash "$IPS" ) \
    > /dev/null 2> "$SANDBOX/ip-adv-nb.log"
IP_NB_RC=$?
if [[ "$IP_NB_RC" -ne 0 ]]; then
  pass "a frontend advance with no frontend block is refused"
else
  fail "a frontend advance FOUNDED a partial frontend block"
fi
expect "the refusal points at bootstrap" grep -qF 'ACTION=bootstrap SOURCE=frontend' "$SANDBOX/ip-adv-nb.log"
expect "and nothing was written" \
  bash -c "test \"\$(yq -r 'has(\"frontend\")' '$IPNB/.kairos/manifest.yaml')\" = false"
fi

if t "in-progress.sh set SOURCE=frontend requires the frontend BLOCK to pre-exist"; then
# S4: `set` writes <src>.in_progress, and yq CREATES the parent key on the way. On a
# component with no frontend block that leaves `frontend: {in_progress: …}` — a live
# frontend run with no repo, no module, no mount, no baseline — and that shape then
# SATISFIES advance's own has("frontend") guard at Phase 8, so the baseline lands in a
# block bootstrap never wrote and every later reader treats as recorded provenance.
IPSF=$SANDBOX/ip-set-frontend
ip_fixture "$IPSF"
( cd "$IPSF" && SOURCE=frontend ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=fe-target \
    PREV_BRANCH=main PREV_SHA=aaa bash "$IPS" ) > /dev/null 2> "$SANDBOX/ip-sf.log"
IP_SF_RC=$?
if [[ "$IP_SF_RC" -ne 0 ]]; then
  pass "a frontend set on a component with no frontend block is refused"
else
  fail "a frontend set on a component with no frontend block was WRITTEN (rc=$IP_SF_RC)"
fi
expect "the refusal names the missing block" \
  grep -qF 'has no frontend block' "$SANDBOX/ip-sf.log"
expect "and points at bootstrap as the step that is actually missing" \
  grep -qF 'ACTION=bootstrap SOURCE=frontend' "$SANDBOX/ip-sf.log"
expect "the refused set created NO frontend key at all" \
  bash -c "test \"\$(yq -r 'has(\"frontend\")' '$IPSF/.kairos/manifest.yaml')\" = false"
# The downstream consequence the guard exists for: with the block half-created, a Phase 8
# advance would have accepted it. Prove the advance guard is the one that used to be
# satisfied — bootstrap first, and both calls then work.
( cd "$IPSF" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=r MODULE=react \
    MODULE_PATH=template/react BRANCH=main \
    BASE_SHA=2222222222222222222222222222222222222222 bash "$IPS" ) >/dev/null 2>&1
( cd "$IPSF" && SOURCE=frontend ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=fe-target \
    PREV_BRANCH=main PREV_SHA=aaa bash "$IPS" ) > /dev/null 2> "$SANDBOX/ip-sf2.log"
IP_SF2_RC=$?
if [[ "$IP_SF2_RC" -eq 0 ]]; then
  pass "after bootstrap, the same frontend set succeeds"
else
  fail "after bootstrap, the same frontend set succeeds (rc=$IP_SF2_RC: $(tail -1 "$SANDBOX/ip-sf2.log"))"
fi
expect "and the block it wrote sits under the bootstrapped frontend source" \
  bash -c "test \"\$(yq -r '.frontend.in_progress.target_sha' '$IPSF/.kairos/manifest.yaml')\" = fe-target"
# A TEMPLATE set is untouched by the guard: the template block is the manifest's
# founding shape and `set` has always been able to write into it.
IPST=$SANDBOX/ip-set-template
ip_fixture "$IPST"
( cd "$IPST" && ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=tpl-target \
    PREV_BRANCH=main PREV_SHA=bbb bash "$IPS" ) >/dev/null 2>&1
expect "a template set on the same fixture still writes its block" \
  bash -c "test \"\$(yq -r '.template.in_progress.target_sha' '$IPST/.kairos/manifest.yaml')\" = tpl-target"
fi

if t "in-progress.sh live-source — names the live source, keyless, fail-closed"; then
# This block PINS the interface:
#   ACTION=live-source is a pure READ — keyless like clear — that PRINTS
#   template|frontend|none for whichever source's in_progress block is live. It
#   exists so Phase 8's four "which source is live" derivations (the silenced-test
#   range, the block re-read, the advance, the finalize commit) run one owned read
#   instead of a hand-written `SRC=template; case … .frontend | has("in_progress")
#   … esac` copied four times — four copies drift, and one that reads the wrong key
#   advances or commits the wrong source's baseline.
IPLS=$SANDBOX/ip-live-source

# template block live → template.
ip_fixture "$IPLS"
( cd "$IPLS" && ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=aaa PREV_BRANCH=main PREV_SHA=bbb \
    bash "$IPS" ) >/dev/null 2>&1
out=$( cd "$IPLS" && ACTION=live-source bash "$IPS" 2>/dev/null ); rc=$?
expect "template.in_progress live → prints 'template'" test "$out" = template
expect "and exits 0" test "$rc" -eq 0

# no in_progress block at all → none.
ip_fixture "$IPLS"
out=$( cd "$IPLS" && ACTION=live-source bash "$IPS" 2>/dev/null )
expect "no in_progress block → prints 'none'" test "$out" = none

# frontend block live → frontend.
ip_fixture "$IPLS"
( cd "$IPLS" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE \
    REPO=git@bb:ifs-pd/kairos-frontend.git MODULE=react MODULE_PATH=template/react \
    BRANCH=main BASE_SHA=2222222222222222222222222222222222222222 bash "$IPS" ) >/dev/null 2>&1
( cd "$IPLS" && SOURCE=frontend ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=fe-target \
    PREV_BRANCH=main PREV_SHA=aaa bash "$IPS" ) >/dev/null 2>&1
out=$( cd "$IPLS" && ACTION=live-source bash "$IPS" 2>/dev/null )
expect "frontend.in_progress live → prints 'frontend'" test "$out" = frontend

# keyless: no PHASE_KEY needed, like clear.
out=$( cd "$IPLS" && env -u PHASE_KEY ACTION=live-source bash "$IPS" 2>/dev/null ); rc=$?
expect "live-source runs keyless (no PHASE_KEY), like clear" test "$rc" -eq 0
expect "and still prints the live source" test "$out" = frontend

# frontend wins the (unproducible) both-live tie — matches the hand-written
# derivation it replaces, which tested frontend first. `set` refuses to create this
# shape, so it is hand-crafted here purely to pin the tie-break.
cat > "$IPLS/.kairos/manifest.yaml" <<'EOF'
name: mycomp
template:
  repo: file:///srv/template.git
  sha: 1111111111111111111111111111111111111111
  branch: main
  in_progress:
    target_sha: tpl
    previous_branch: main
    previous_sha: p
frontend:
  repo: r
  path: template/react
  template: react
  branch: main
  sha: 2222222222222222222222222222222222222222
  bootstrapped: true
  in_progress:
    target_sha: fe
    previous_branch: main
    previous_sha: p
EOF
out=$( cd "$IPLS" && ACTION=live-source bash "$IPS" 2>/dev/null )
expect "both blocks live → frontend wins the tie (stable, matches the old derivation)" \
  test "$out" = frontend

# fail CLOSED on an unreadable manifest — "no live block" and "I could not tell"
# must never collapse to the same answer.
printf 'template:\n  in_progress: [unclosed\n' > "$IPLS/.kairos/manifest.yaml"
out=$( cd "$IPLS" && ACTION=live-source bash "$IPS" 2>/dev/null ); rc=$?
if [[ "$rc" -ne 0 ]]; then pass "live-source on an UNPARSEABLE manifest is refused (fail closed)"; else fail "live-source on an UNPARSEABLE manifest is refused (rc=$rc, out='$out')"; fi
refute "the corrupt-manifest refusal did not print a source" test -n "$out"

# missing manifest is a refusal, never a silent 'none'.
IPLSX=$SANDBOX/ip-live-source-nomanifest; rm -rf "$IPLSX"; mkdir -p "$IPLSX"
refute "live-source with no manifest is refused, not reported as 'none'" \
  bash -c "cd '$IPLSX' && ACTION=live-source bash '$IPS' >/dev/null 2>&1"

# and the four Phase 8 call sites really drive the action rather than re-deriving it.
expect "phases/8-finalize.md reads the live source through ACTION=live-source" \
  grep -qF 'ACTION=live-source' "$SKILL_DIR/phases/8-finalize.md"
refute "phases/8-finalize.md no longer hand-writes the SRC derivation" \
  grep -qF "case \"\$(yq -r '.frontend | has(\"in_progress\")'" "$SKILL_DIR/phases/8-finalize.md"
fi

if t "in-progress.sh record-floor — appends one element, idempotent, siblings untouched"; then
# This block PINS the interface:
#   ACTION=record-floor, env FLOOR_FILE/FLOOR_MODULE/FLOOR_SHA, carrying Phase 8's
#   key (the same as advance). Appends ONE {upgrade_file, module, sha} element to the
#   frontend.outstanding_floors LIST via one atomic rewrite. §6.4 of the
#   frontend-compatibility-floor PRD: an unmet template floor the user declined is
#   recorded so the NEXT run re-surfaces it. Idempotent by upgrade_file+module+sha: a
#   second record of the same floor is a no-op ("unchanged"), never a duplicate.
IPRF=$SANDBOX/ip-record-floor
ip_fixture "$IPRF"
# A frontend block must exist first — record-floor refuses to CREATE one.
( cd "$IPRF" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=r MODULE=react \
    MODULE_PATH=template/react BRANCH=main BASE_SHA=2222222222222222222222222222222222222222 \
    bash "$IPS" ) >/dev/null 2>&1
M=$IPRF/.kairos/manifest.yaml

( cd "$IPRF" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE \
    FLOOR_FILE=.kairos-updates/20260811-auth.md FLOOR_MODULE=react \
    FLOOR_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash "$IPS" ) > "$SANDBOX/ip-rf.out" 2>&1; rc=$?
expect "record-floor exits 0" test "$rc" -eq 0
expect "record-floor prints recorded" grep -qx 'recorded' "$SANDBOX/ip-rf.out"
expect "the element's upgrade_file landed" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors[0].upgrade_file' '$M')\" = .kairos-updates/20260811-auth.md"
expect "the element's module landed" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors[0].module' '$M')\" = react"
expect "the element's sha landed" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors[0].sha' '$M')\" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect "exactly one element so far" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors | length' '$M')\" = 1"

# Idempotent: recording the SAME floor again is a no-op that does not rewrite the
# file (a gratuitous round-trip would dirty the tree pre-flight demands be clean).
cp "$M" "$SANDBOX/ip-rf.before-dup"
( cd "$IPRF" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE \
    FLOOR_FILE=.kairos-updates/20260811-auth.md FLOOR_MODULE=react \
    FLOOR_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash "$IPS" ) > "$SANDBOX/ip-rf-dup.out" 2>&1; rc=$?
expect "a duplicate record exits 0" test "$rc" -eq 0
expect "a duplicate record prints unchanged" grep -qx 'unchanged' "$SANDBOX/ip-rf-dup.out"
expect "still exactly one element after the duplicate" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors | length' '$M')\" = 1"
expect "the duplicate left the manifest byte-identical" cmp -s "$SANDBOX/ip-rf.before-dup" "$M"

# A DIFFERENT floor (different sha) appends a second element; the first is untouched.
( cd "$IPRF" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE \
    FLOOR_FILE=.kairos-updates/20260901-nginx.md FLOOR_MODULE=react \
    FLOOR_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb bash "$IPS" ) >/dev/null 2>&1
expect "a distinct floor appends a second element" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors | length' '$M')\" = 2"
expect "the first (sibling) element is untouched by the append" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors[0].sha' '$M')\" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect "the second element carries the new sha" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors[1].sha' '$M')\" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# The founding frontend provenance and the template block are untouched by recording.
expect "the frontend baseline sha is untouched by record-floor" \
  bash -c "test \"\$(yq -r '.frontend.sha' '$M')\" = 2222222222222222222222222222222222222222"
expect "the template block is untouched by record-floor" \
  bash -c "test \"\$(yq -r '.template.sha' '$M')\" = 1111111111111111111111111111111111111111"

# Carries Phase 8's key: refused without it, and refused on Phase 4's key.
( cd "$IPRF" && env -u PHASE_KEY ACTION=record-floor \
    FLOOR_FILE=x FLOOR_MODULE=react FLOOR_SHA=cccc bash "$IPS" ) >/dev/null 2> "$SANDBOX/ip-rf-nokey.err"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF 'FAIL: load phases/8-finalize.md first' "$SANDBOX/ip-rf-nokey.err"; then
  pass "record-floor without PHASE_KEY exits non-zero: load phases/8-finalize.md first"
else
  fail "record-floor without PHASE_KEY exits non-zero: load phases/8-finalize.md first (rc=$rc)"
fi
( cd "$IPRF" && ACTION=record-floor PHASE_KEY=$PK_BRANCH \
    FLOOR_FILE=x FLOOR_MODULE=react FLOOR_SHA=cccc bash "$IPS" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "record-floor rejects Phase 4's key (the key is Phase 8's)"; else fail "record-floor rejects Phase 4's key (rc=$rc)"; fi

# Each of the three FLOOR_* is required (an unset one defaults empty and is refused).
( cd "$IPRF" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE FLOOR_MODULE=react FLOOR_SHA=cccc bash "$IPS" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "record-floor refuses a missing FLOOR_FILE"; else fail "record-floor refuses a missing FLOOR_FILE (rc=$rc)"; fi
( cd "$IPRF" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE FLOOR_FILE=x FLOOR_SHA=cccc bash "$IPS" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "record-floor refuses a missing FLOOR_MODULE"; else fail "record-floor refuses a missing FLOOR_MODULE (rc=$rc)"; fi
( cd "$IPRF" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE FLOOR_FILE=x FLOOR_MODULE=react bash "$IPS" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "record-floor refuses a missing FLOOR_SHA"; else fail "record-floor refuses a missing FLOOR_SHA (rc=$rc)"; fi

# Refuses to CREATE a frontend block — a component with no frontend block cannot
# record a floor (that would leave frontend: {outstanding_floors: …}, a partial
# block advance's has("frontend") guard accepts as recorded provenance).
IPRFN=$SANDBOX/ip-record-floor-noblock
ip_fixture "$IPRFN"
( cd "$IPRFN" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE \
    FLOOR_FILE=x FLOOR_MODULE=react FLOOR_SHA=cccc bash "$IPS" ) >/dev/null 2> "$SANDBOX/ip-rfn.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "record-floor on a component with no frontend block is refused"; else fail "record-floor FOUNDED a partial frontend block (rc=$rc)"; fi
expect "the refusal names the missing frontend block" grep -qF 'has no frontend block' "$SANDBOX/ip-rfn.err"
expect "and no frontend key was created" \
  bash -c "test \"\$(yq -r 'has(\"frontend\")' '$IPRFN/.kairos/manifest.yaml')\" = false"

# A bare `frontend:` NULL placeholder is not a recorded source: has() waves it
# through, but the guard tests for a REAL mapping (tag=='!!map'), so record-floor
# still refuses rather than appending outstanding_floors under a block with no
# baseline. (A null key is never produced by any writer; this pins the guard's
# honesty regardless.)
IPRFZ=$SANDBOX/ip-record-floor-nullblock
ip_fixture "$IPRFZ"
printf '\nfrontend:\n' >> "$IPRFZ/.kairos/manifest.yaml"
expect "precondition: has(frontend) is true for a null placeholder" \
  bash -c "test \"\$(yq -r 'has(\"frontend\")' '$IPRFZ/.kairos/manifest.yaml')\" = true"
( cd "$IPRFZ" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE \
    FLOOR_FILE=x FLOOR_MODULE=react FLOOR_SHA=cccc bash "$IPS" ) >/dev/null 2> "$SANDBOX/ip-rfz.err"; rc=$?
if [[ "$rc" -ne 0 ]]; then pass "record-floor refuses a null frontend: placeholder (tag != !!map)"; else fail "record-floor appended under a null frontend placeholder (rc=$rc)"; fi
expect "the null-block refusal names the missing frontend block" grep -qF 'has no frontend block' "$SANDBOX/ip-rfz.err"
expect "record-floor did not materialize outstanding_floors under the null placeholder" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors // \"none\"' '$IPRFZ/.kairos/manifest.yaml')\" = none"

fi

if t "in-progress.sh list-floors — reads back the persisted debt as file<TAB>module<TAB>sha (keyless, fail-closed)"; then
# This block PINS the interface: list-floors is THE READER that makes record-floor's debt
# cross-run. A keyless pure read that prints frontend.outstanding_floors as the same three
# columns $RUN/frontend-floors.tsv carries, so Phase 8 can union it into the floor check and
# re-surface a declined floor whose upgrade-file has fallen out of BASE..TARGET range. Before
# this, the debt was WRITE-ONLY: record-floor wrote it and advance cleared it, but nothing
# read it, so the "next run re-surfaces it" contract had no implementation.
IPLF=$SANDBOX/ip-list-floors
ip_fixture "$IPLF"
( cd "$IPLF" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=r MODULE=react \
    MODULE_PATH=template/react BRANCH=main BASE_SHA=2222222222222222222222222222222222222222 \
    bash "$IPS" ) >/dev/null 2>&1
M=$IPLF/.kairos/manifest.yaml
TAB=$(printf '\t')

# No floors yet → a clean empty print, exit 0 (no debt is not an error).
out=$( cd "$IPLF" && ACTION=list-floors bash "$IPS" 2>/dev/null ); rc=$?
expect "with no floors recorded, list-floors prints nothing" test -z "$out"
expect "and exits 0 (empty is not a failure)" test "$rc" -eq 0

# Record two floors, then read them back.
( cd "$IPLF" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE \
    FLOOR_FILE=.kairos-updates/20260811-auth.md FLOOR_MODULE=react \
    FLOOR_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash "$IPS" ) >/dev/null 2>&1
( cd "$IPLF" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE \
    FLOOR_FILE=.kairos-updates/20260901-nginx.md FLOOR_MODULE=react \
    FLOOR_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb bash "$IPS" ) >/dev/null 2>&1
( cd "$IPLF" && ACTION=list-floors bash "$IPS" ) > "$SANDBOX/ip-lf.out" 2>/dev/null; rc=$?
expect "list-floors exits 0" test "$rc" -eq 0
expect "keyless: it needs no PHASE_KEY" \
  bash -c "cd '$IPLF' && env -u PHASE_KEY ACTION=list-floors bash '$IPS' >/dev/null 2>&1"
expect "row 1 is the first floor as file<TAB>module<TAB>sha (the frontend-floors.tsv columns)" \
  grep -qxF ".kairos-updates/20260811-auth.md${TAB}react${TAB}aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$SANDBOX/ip-lf.out"
expect "row 2 is the second floor" \
  grep -qxF ".kairos-updates/20260901-nginx.md${TAB}react${TAB}bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$SANDBOX/ip-lf.out"
expect "exactly two rows, nothing invented" bash -c "test \$(grep -c . '$SANDBOX/ip-lf.out') -eq 2"

# A component with NO frontend block at all → empty print, exit 0 (nothing to surface).
IPLFN=$SANDBOX/ip-list-floors-noblock
ip_fixture "$IPLFN"
out=$( cd "$IPLFN" && ACTION=list-floors bash "$IPS" 2>/dev/null ); rc=$?
expect "no frontend block → empty print" test -z "$out"
expect "no frontend block → exit 0" test "$rc" -eq 0

# Fail CLOSED on an unreadable manifest — a swallowed parse error would print nothing and
# read as "no debt", silently dropping it (the loss the persistence exists to prevent).
printf 'frontend:\n  outstanding_floors: [unclosed\n' > "$M"
( cd "$IPLF" && ACTION=list-floors bash "$IPS" ) >/dev/null 2> "$SANDBOX/ip-lf-bad.err"; rc=$?
expect "an unreadable manifest exits non-zero (fail-closed, never a silent empty)" test "$rc" -ne 0
expect "and names the refusal" grep -qiF 'refusing to list outstanding floors' "$SANDBOX/ip-lf-bad.err"
fi

if t "in-progress.sh advance SOURCE=frontend — auto-clears contained floors, leaves the rest"; then
# This block PINS the interface:
#   A frontend advance is the ONLY place frontend.sha moves, and a recorded
#   outstanding floor is satisfied the instant the new baseline CONTAINS its commit
#   — an ancestry test (git merge-base --is-ancestor <floor-sha> <TARGET_SHA> in
#   FRONTEND_CACHE), not a comparison. Contained floors are del()'d in the SAME
#   rewrite() as the sha advance; a still-uncontained floor (divergent lineage) is
#   LEFT. A SOURCE=template advance NEVER touches floors. Best-effort: no usable
#   FRONTEND_CACHE → floors left untouched, never falsely cleared.
FEG=$SANDBOX/fe-floor-git
rm -rf "$FEG"; mkdir -p "$FEG"
( cd "$FEG" && git init -q -b main && git config user.email t@t && git config user.name t
  echo one > f && git add -A && git commit -qm c1
  echo two > f && git commit -qam c2 ) >/dev/null 2>&1
FE_C1=$( cd "$FEG" && git rev-parse HEAD~1 )   # an ancestor of the tip
FE_C2=$( cd "$FEG" && git rev-parse HEAD )     # the tip we advance to
# A divergent commit that is NOT an ancestor of the tip.
( cd "$FEG" && git checkout -q -b side HEAD~1 && echo three > g && git add -A && git commit -qm d1
  git checkout -q main ) >/dev/null 2>&1
FE_D1=$( cd "$FEG" && git rev-parse side )

IPAC=$SANDBOX/ip-fe-autoclear
ip_fixture "$IPAC"
( cd "$IPAC" && SOURCE=frontend ACTION=bootstrap PHASE_KEY=$PK_RESOLVE REPO=r MODULE=react \
    MODULE_PATH=template/react BRANCH=main BASE_SHA=$FE_C1 bash "$IPS" ) >/dev/null 2>&1
M=$IPAC/.kairos/manifest.yaml
# Seed two floors: one contained by the target (FE_C1, an ancestor of FE_C2) and one
# NOT contained (FE_D1, on a divergent branch).
( cd "$IPAC" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE FLOOR_FILE=a.md FLOOR_MODULE=react FLOOR_SHA=$FE_C1 bash "$IPS" ) >/dev/null 2>&1
( cd "$IPAC" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE FLOOR_FILE=b.md FLOOR_MODULE=react FLOOR_SHA=$FE_D1 bash "$IPS" ) >/dev/null 2>&1
expect "two floors seeded" bash -c "test \"\$(yq -r '.frontend.outstanding_floors | length' '$M')\" = 2"

( cd "$IPAC" && SOURCE=frontend ACTION=advance PHASE_KEY=$PK_FINALIZE \
    FRONTEND_CACHE=$FEG TARGET_SHA=$FE_C2 bash "$IPS" ) > "$SANDBOX/ip-ac.out" 2>&1; rc=$?
expect "the frontend advance exits 0" test "$rc" -eq 0
expect "the frontend baseline advanced to the new sha" \
  bash -c "test \"\$(yq -r '.frontend.sha' '$M')\" = $FE_C2"
expect "the contained floor (an ancestor of the new baseline) was cleared" \
  bash -c "test \"\$(yq -r '[.frontend.outstanding_floors[] | select(.sha == \"$FE_C1\")] | length' '$M')\" = 0"
expect "the still-uncontained floor (divergent lineage) was LEFT" \
  bash -c "test \"\$(yq -r '[.frontend.outstanding_floors[] | select(.sha == \"$FE_D1\")] | length' '$M')\" = 1"
expect "exactly one floor remains after the auto-clear" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors | length' '$M')\" = 1"

# A SOURCE=template advance NEVER touches floors, even with a FRONTEND_CACHE in env.
( cd "$IPAC" && ACTION=advance PHASE_KEY=$PK_FINALIZE FRONTEND_CACHE=$FEG \
    TARGET_SHA=9999999999999999999999999999999999999999 bash "$IPS" ) >/dev/null 2>&1
expect "a template advance leaves the outstanding frontend floor in place" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors | length' '$M')\" = 1"
expect "and the template baseline moved" \
  bash -c "test \"\$(yq -r '.template.sha' '$M')\" = 9999999999999999999999999999999999999999"

# Best-effort: re-seed a CONTAINED floor, then advance frontend with NO FRONTEND_CACHE
# — the ancestry test cannot run, so even the contained floor is LEFT (never falsely
# cleared: "I could not check" is never "it is satisfied").
( cd "$IPAC" && ACTION=record-floor PHASE_KEY=$PK_FINALIZE FLOOR_FILE=a.md FLOOR_MODULE=react FLOOR_SHA=$FE_C1 bash "$IPS" ) >/dev/null 2>&1
expect "two floors again (one contained, one not)" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors | length' '$M')\" = 2"
( cd "$IPAC" && SOURCE=frontend ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=$FE_C2 bash "$IPS" ) >/dev/null 2>&1
expect "with no FRONTEND_CACHE even the contained floor is left (best-effort)" \
  bash -c "test \"\$(yq -r '.frontend.outstanding_floors | length' '$M')\" = 2"

fi

if t "in-progress.sh — every write preserves the committed manifest's mode (never drops to 0600)"; then
# This block PINS the interface:
#   bootstrap creates the founding manifest and set/advance rewrite it, all through
#   mktemp+mv. mktemp forces 0600, and a bare mv would stamp that private mode onto
#   .kairos/manifest.yaml — a COMMITTED file that travels in git and is read by every
#   shared checkout and CI job. preserve_mode carries the existing file's OWN mode across
#   (there is no `chmod --reference` on macOS), and for the founding write, where no file
#   yet exists, it derives the mode from the umask exactly as a `>` redirect would — so a
#   fresh manifest is world-readable, not 0600.
# GNU `stat -c` FIRST, then BSD `stat -f` — mirror the scripts' order. On GNU/Linux
# `stat -f` means --file-system and would return a filesystem dump, not the mode.
fmode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
IPM=$SANDBOX/ip-mode
rm -rf "$IPM"; mkdir -p "$IPM"
M="$IPM/.kairos/manifest.yaml"

( umask 022; cd "$IPM" && ACTION=bootstrap PHASE_KEY=$PK_RESOLVE NAME=mycomp REPO=file:///srv/t.git \
    BASE_SHA=8888888888888888888888888888888888888888 BRANCH=main bash "$IPS" ) >/dev/null 2>&1
if [[ "$(fmode "$M")" = 644 ]]; then pass "in-progress: bootstrap creates the manifest with the umask default (0644), not mktemp's 0600"; else fail "in-progress: bootstrap creates the manifest 0644 under umask 022 (got $(fmode "$M"))"; fi

chmod 644 "$M"
( cd "$IPM" && ACTION=set PHASE_KEY=$PK_BRANCH TARGET_SHA=9999999999999999999999999999999999999999 \
    PREV_BRANCH=main PREV_SHA=8888888888888888888888888888888888888888 bash "$IPS" ) >/dev/null 2>&1
if [[ "$(fmode "$M")" = 644 ]]; then pass "in-progress: a set (rewrite) leaves a 0644 manifest at 0644 (not 0600)"; else fail "in-progress: a set leaves a 0644 manifest at 0644 (got $(fmode "$M"))"; fi

( cd "$IPM" && ACTION=advance PHASE_KEY=$PK_FINALIZE \
    TARGET_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash "$IPS" ) >/dev/null 2>&1
if [[ "$(fmode "$M")" = 644 ]]; then pass "in-progress: an advance (rewrite) leaves a 0644 manifest at 0644 (not 0600)"; else fail "in-progress: an advance leaves a 0644 manifest at 0644 (got $(fmode "$M"))"; fi
fi

finish_suite
