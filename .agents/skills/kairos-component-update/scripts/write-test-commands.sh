#!/usr/bin/env bash
# write-test-commands.sh — the format owner for $RUN/test-command.txt.
#
# WHY this script exists: the file is POSITIONAL — line 1 test command, line 2
# failure extractor, line 3 build command, line 4 regeneration command — and its
# readers read it BY LINE NUMBER. Those readers are exactly: gate.sh (at every
# label), producer-idempotence.sh (lines 3-4), and the planner, which copies the
# commands into PLAN.md's `## Test Baseline` section. The executor never reads this
# file — its test and build commands come from that PLAN.md section — so a
# discovered command only reaches execution by way of the plan. A shifted line
# silently redefines what "regression" means for the whole run. Until this script
# nothing under scripts/ wrote it; the orchestrator hand-wrote four positional
# lines from prose, which is the one thing prose is worst at — being exact twice.
#
# WHY an empty value becomes a LITERAL placeholder rather than a blank line: the
# three literals (`no tests detected` / `no build check` / `no regen command`) are
# vocabulary the readers already recognise as an honest absence and map to
# INCOMPLETE. A blank line maps to `gate-internal` FAIL and, worse, an OMITTED line
# shifts every line below it. Line 2 is the deliberate exception: with no test
# command there is no extractor, and it is left EMPTY rather than given an invented
# literal — if line 1 ever became a real command, an empty line 2 is a
# gate-internal FAIL, while a literal would be eval'd as an extractor.
#
# WHY a TEST_CMD without an EXTRACTOR is refused at write time: that combination is
# already a `gate-internal` FAIL at every gate label ("the failure set cannot be
# compared against the baseline"). Refusing here turns a confusing internal error
# hours later into a fixable message in the phase that owns the file.
#
# WHY rejections are a separate call that appends STRICTLY after line 4: the
# zero-evidence guard rejects candidates during discovery, i.e. possibly BEFORE the
# chosen command is known. A rejection comment that landed on a positional line
# would be read as a command — both gate.sh and producer-idempotence.sh carry an
# explicit arm for the drifted-comment case because that is a real failure. So the
# append path creates the four placeholder lines first when the file does not exist
# yet, and the command-write path preserves everything below line 4.
#
# WHY temp file + mv: a half-written positional file is precisely the failure being
# designed out, and the read-back check has to run on the bytes about to land.
#
# WHY A FRONTEND RUN DISCOVERS ITS OWN COMMANDS HERE rather than in prose: the
# mount's `package.json` names the one command that must NOT be recorded — the
# default `test` script is watch-mode vitest, which never exits, so a gate that ran
# it would hang the migration rather than fail it. That is a mechanical reading of a
# manifest with one wrong answer sitting first in the obvious place to look, which is
# exactly the shape prose gets wrong; so `MOUNT` hands the discovery to this script
# and the watch-mode candidate leaves a `# rejected:` line behind as evidence it was
# considered and refused. Typecheck joins the BUILD line and never stands in for the
# tests (a type check is not a test run), and the component root's `make test` is
# never even looked at on a frontend run — it does not see the mount.
#
# In :  RUN        run-state dir (required). Created if missing.
#       PHASE_KEY  proof-of-load key stated in phases/4.5-test-baseline.md.
#       MOUNT      optional — the frontend mount (e.g. `web/`), relative to cwd or
#                  absolute. Set = this is a FRONTEND run: lines 1 and 3 are
#                  DISCOVERED from `$MOUNT/package.json` and must NOT also be passed
#                  (TEST_CMD/BUILD_CMD alongside MOUNT is refused). The recorded
#                  commands are the ones to run with **cwd at the mount** — the
#                  frontend gate cwd (phases/4.5-test-baseline.md). Unset = the
#                  template path, byte-identical to before this env var existed.
#       Command-write path (REJECT unset):
#         TEST_CMD   line 1 — the discovered test command, or empty for none.
#         EXTRACTOR  line 2 — the failure-set extractor. Required when TEST_CMD is
#                    set; must be empty when it is not.
#         BUILD_CMD  line 3 — the build/typecheck command, or empty for none.
#         REGEN_CMD  line 4 — the regeneration command, or empty for none.
#         CENSUS     the census extractor, written to the SIBLING file
#                    $RUN/census-command.txt in this same call (never a fifth
#                    positional line — everything below line 4 of test-command.txt
#                    is the rejection audit trail, and a positional reader indexes
#                    by number). Empty → the literal `no census extractor`. Keeping
#                    the command-form/extractor pairing atomic under one format
#                    owner is the whole reason it rides this call.
#       Rejection-append path (REJECT set):
#         REJECT     the rejected candidate command.
#         REASON     required — why it was rejected (a reasonless rejection records
#                    nothing auditable, which is the only reason the line exists).
#       Every value is collapsed (newlines/CRs/tabs to single spaces, then trimmed)
#       before use, so a pasted trailing newline or a two-line pipeline cannot shift
#       a positional line, and a whitespace-only value is as absent as an unset one.
# Out:  $RUN/test-command.txt
#         command-write path — the four positional lines, with any existing
#           `# rejected:` lines below line 4 preserved verbatim.
#         rejection path — one appended `# rejected: <cmd> — <reason>` line.
#       $RUN/census-command.txt (command-write path only) — one line: the census
#         extractor, or the literal `no census extractor`. Its absence is the honest
#         record on a run that predates the census, degrading downstream to
#         INCOMPLETE with no compat logic.
#       Re-run safe: an identical command write is byte-identical, and an identical
#       rejection is dropped rather than stacked.
# Exit: 0 done
#       1 PHASE_KEY missing/wrong
#       2 bad input, or the file could not be written / failed its read-back —
#         including a frontend run whose mount offers no non-interactive test entry
#         at all (that is a loud failure, never a silently recorded watch-mode
#         command).
set -u

# Phase-load guard. This is Phase 4.5's FIRST script call, so it is the phase's
# proof-of-load entry point (run-check-modules.sh, called after it, carries the same
# key for the baseline invocation).
[[ "${PHASE_KEY:-}" = "u7qk3mfp" ]] \
  || { echo "FAIL: load phases/4.5-test-baseline.md first" >&2; exit 1; }

# Every failure path also drops the frontend rejection queue (the lazily-created
# mktemp below): the no-CI-entry stop fires AFTER candidates have been queued, and an
# unlinked temp file then leaks out of $RUN into $TMPDIR on every refused run — the one
# place this script writes outside the run state. `${REJQ:-}` because most fail() call
# sites run before the variable exists at all.
fail() { [[ -z "${REJQ:-}" ]] || rm -f "$REJQ"; echo "FAIL: $*" >&2; exit 2; }

# Collapse and trim BEFORE anything else (see header).
collapse() { printf '%s' "$1" | tr '\n\r\t' '   ' | awk '{ $1 = $1; print }'; }

RUN=$(collapse "${RUN:-}")
[[ -n "$RUN" ]] || fail "RUN required (the run-state dir)"
CMDFILE="$RUN/test-command.txt"

REJECT=$(collapse "${REJECT:-}")
REASON=$(collapse "${REASON:-}")
TEST_CMD=$(collapse "${TEST_CMD:-}")
EXTRACTOR=$(collapse "${EXTRACTOR:-}")
BUILD_CMD=$(collapse "${BUILD_CMD:-}")
REGEN_CMD=$(collapse "${REGEN_CMD:-}")
CENSUS=$(collapse "${CENSUS:-}")
MOUNT=$(collapse "${MOUNT:-}")

# or_literal <value> <literal> — an absent command becomes the literal placeholder
# the readers recognise as an honest absence, never a blank line.
or_literal() { if [[ -z "$1" ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# write_positional <l1> <l2> <l3> <l4> — replace lines 1-4, preserve everything
# below them, verify the read-back, and only then rename over the file.
write_positional() {
  mkdir -p "$RUN" || fail "cannot create $RUN"
  TMP=$(mktemp "$RUN/.test-command.txt.XXXXXX") \
    || fail "cannot create a temp file next to $CMDFILE"
  trap 'rm -f "$TMP"' EXIT
  printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" > "$TMP" \
    || fail "cannot write $TMP"
  # Below-line-4 content is the rejection audit trail; it survives every rewrite.
  if [[ -f "$CMDFILE" ]]; then
    tail -n +5 "$CMDFILE" >> "$TMP" || fail "cannot carry the existing rejections into $TMP"
  fi
  # Verify on the bytes about to land: the positional contract is the whole point,
  # so a file that does not read back positionally must not reach the readers.
  n=1
  for want in "$1" "$2" "$3" "$4"; do
    [[ "$(sed -n "${n}p" "$TMP")" = "$want" ]] \
      || fail "line $n did not read back as written — refusing to install $CMDFILE"
    n=$((n + 1))
  done
  mv "$TMP" "$CMDFILE" || fail "could not write $CMDFILE"
  trap - EXIT
}

# write_census — the census extractor's home is a SIBLING file, one line, written
# temp+mv like the positional file and for the same reason: a half-written recipe
# must never be read. Same read-back check on the bytes about to land. It is a
# one-liner, so it has no positional contract of its own — but the atomic install
# keeps a crash from leaving a truncated extractor a gate would eval. The
# destination is held in CENSUSFILE and the mv ends in it, the same shape
# write_positional uses for $CMDFILE.
write_census() {
  mkdir -p "$RUN" || fail "cannot create $RUN"
  CENSUSFILE="$RUN/census-command.txt"
  CTMP=$(mktemp "$RUN/.census-command.txt.XXXXXX") \
    || fail "cannot create a temp file next to $CENSUSFILE"
  printf '%s\n' "$1" > "$CTMP" || { rm -f "$CTMP"; fail "cannot write $CTMP"; }
  [[ "$(sed -n 1p "$CTMP")" = "$1" ]] \
    || { rm -f "$CTMP"; fail "census line did not read back as written — refusing to install $CENSUSFILE"; }
  mv "$CTMP" "$CENSUSFILE" || { rm -f "$CTMP"; fail "could not write $CENSUSFILE"; }
}

# append_rejection <cmd> <reason> — one `# rejected:` line, STRICTLY below line 4.
# Shared by the REJECT path and the frontend discovery below, so both leave the
# same auditable shape and neither can land a comment on a positional line.
append_rejection() {
  LINE="# rejected: $1 — $2"
  # The four positional lines must exist before anything can be appended AFTER
  # them; on a fresh run they land as placeholders.
  [[ -f "$CMDFILE" ]] || write_positional 'no tests detected' '' 'no build check' 'no regen command'
  # Drop an exact duplicate, the same rule the ledger writers apply: a re-entered
  # Phase 4.5 must not restack the discovery it already recorded.
  if ! grep -qxF "$LINE" "$CMDFILE"; then
    printf '%s\n' "$LINE" >> "$CMDFILE" || fail "could not append to $CMDFILE"
  fi
}

if [[ -n "$REJECT" ]]; then
  # --- rejection-append path -------------------------------------------------
  [[ -n "$REASON" ]] \
    || fail "REASON required alongside REJECT — a rejection with no reason records nothing auditable"
  append_rejection "$REJECT" "$REASON"
  exit 0
fi

# --- frontend discovery (MOUNT set) ------------------------------------------
# Rejections discovered here are QUEUED, not appended: they must land below line 4,
# and line 4 does not exist yet. One `cmd<TAB>reason` line per queued rejection.
# The queue file is created LAZILY, on the first queued rejection, so the template
# path (MOUNT unset) touches nothing it did not touch before. No EXIT trap on it:
# write_positional clears EXIT traps by design, so this cleans up explicitly below.
REJQ=""
queue_rejection() {
  if [[ -z "$REJQ" ]]; then
    REJQ=$(mktemp "${TMPDIR:-/tmp}/wtc-rejq.XXXXXX") \
      || fail "cannot create a temp file for the rejection queue"
  fi
  printf '%s\t%s\n' "$1" "$2" >> "$REJQ"
}

# The package manager is read off the mount, never assumed: a lockfile is the
# strongest evidence, then the `packageManager` field, and `pnpm` is the frontend
# template's own manager as the last resort. Every form is spelled `<pm> run <script>`
# — `npm test:ci` is not a command, while `npm run test:ci` is, and the `run` spelling
# is valid for all four managers, so one shape covers them.
detect_pm() {
  if   [[ -f "$MDIR/pnpm-lock.yaml" ]];    then echo pnpm
  elif [[ -f "$MDIR/yarn.lock" ]];         then echo yarn
  elif [[ -f "$MDIR/bun.lockb" ]];         then echo bun
  elif [[ -f "$MDIR/package-lock.json" ]]; then echo npm
  else
    PMF=$(yq -p=json -r '.packageManager // ""' < "$PKG" 2>/dev/null || echo "")
    case "${PMF%%@*}" in
      pnpm|yarn|npm|bun) printf '%s\n' "${PMF%%@*}" ;;
      *) echo pnpm ;;
    esac
  fi
}

# A NON-INTERACTIVE test entry: `vitest run` / `vitest … --run`, or any body carrying
# a `--ci` flag or a `CI=1|true` prefix (a jest-flavoured module is a legal template
# too). Everything else — plain `vitest`, `pnpm test:watch` — is watch-mode: it never
# exits, so it can never be a gate command.
ci_shaped() {
  printf '%s\n' "$1" | grep -Eq 'vitest([[:space:]]+[^[:space:]]+)*[[:space:]]+(run|--run)([[:space:]]|$)|(^|[[:space:]])--ci([[:space:]]|$)|(^|[[:space:]])CI=(1|true)([[:space:]]|$)'
}

if [[ -n "$MOUNT" ]]; then
  MDIR=${MOUNT%/}
  PKG="$MDIR/package.json"
  [[ -d "$MDIR" ]] \
    || fail "MOUNT=$MOUNT is not a directory (cwd is $(pwd)) — a frontend run's gates live in the mount, so the mount has to be there before its commands can be discovered."
  [[ -f "$PKG" ]] \
    || fail "MOUNT=$MOUNT carries no package.json ($PKG) — a frontend run's test entry can only come from the mount's own package manifest. Check the mount (manifest frontend.mount, default web/)."
  [[ -z "$TEST_CMD" ]] && [[ -z "$BUILD_CMD" ]] \
    || fail "MOUNT is set (frontend run), so lines 1 and 3 are DISCOVERED from $PKG — do not pass TEST_CMD/BUILD_CMD as well. Pass MOUNT alone, or drop MOUNT to record hand-discovered commands."

  # @tsv (not `.key + "\t" + …`) — yq's string escapes are version-fragile: mikefarah yq
  # <=4.44 emits `"\t"` as a literal backslash-t, only >=4.5x as a real tab, so the concat
  # form silently produced un-splittable rows under BB's pinned yq. @tsv writes a real tab.
  SCRIPTS=$(yq -p=json -r '.scripts // {} | to_entries | .[] | [.key, (.value | tostring)] | @tsv' < "$PKG" 2>/dev/null) \
    || fail "cannot parse $PKG through 'yq' (check it is the mikefarah build — a python-flavored yq rejects -p=json)"
  DEPS=$(yq -p=json -r '((.devDependencies // {}) * (.dependencies // {})) | keys | .[]' < "$PKG" 2>/dev/null || echo "")

  has_script() { printf '%s\n' "$SCRIPTS" | cut -f1 | grep -qxF "$1"; }
  body_of()    { printf '%s\n' "$SCRIPTS" | awk -F'\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }'; }

  PM=$(detect_pm)

  # --- line 1: the non-interactive CI entry, never the watch-mode default -----
  TCHOICE=""
  if has_script 'test:ci' && ci_shaped "$(body_of 'test:ci')"; then
    TCHOICE=test:ci
  else
    # Key order is package.json's own, so the choice is deterministic. Only
    # TEST-NAMED scripts are candidates: `ci_shaped` also accepts a bare `--ci` /
    # `CI=1` body, and a `lint: eslint --ci` or `e2e: playwright test --ci` script
    # picked up here would record LINT evidence as this run's test suite and advance
    # a frontend baseline on it — the same zero-test-evidence failure the loud stop
    # below exists to prevent. A test entry named nothing test-like is rare; the
    # remedy the failure message names (add a `test:ci` script) covers it.
    while IFS='	' read -r K B; do
      [[ -n "$K" ]] || continue
      case $K in *test*) ;; *) continue ;; esac
      if ci_shaped "$B"; then TCHOICE=$K; break; fi
    done <<EOF
$SCRIPTS
EOF
  fi

  # The default `test` script is rejected whenever it is watch-shaped — ALWAYS, even
  # when a CI entry was found, because "the obvious command was considered and
  # refused" is the finding worth keeping, and even when it is the only test script
  # there is (then the fallback below carries the run).
  if has_script test && ! ci_shaped "$(body_of test)"; then
    queue_rejection "$PM run test" "the mount's default 'test' script is watch-mode ('$(body_of test)'): it never exits, so a gate running it would hang the migration instead of failing it"
  fi
  if has_script 'test:ci' && ! ci_shaped "$(body_of 'test:ci')"; then
    queue_rejection "$PM run test:ci" "named test:ci but its body ('$(body_of 'test:ci')') is not a non-interactive entry: no 'vitest run'/'--run', no '--ci', no 'CI=1'"
  fi

  if [[ -n "$TCHOICE" ]]; then
    TEST_CMD="$PM run $TCHOICE"
  else
    # No script is non-interactive. Fall back to the runner directly — but only on
    # evidence the runner is actually there, and loudly otherwise: recording nothing
    # would let the frontend baseline advance on zero test evidence.
    if printf '%s\n' "$DEPS" | grep -qxF vitest || printf '%s\n' "$SCRIPTS" | grep -q vitest; then
      case "$PM" in
        npm)  TEST_CMD="npm exec -- vitest run" ;;
        yarn) TEST_CMD="yarn vitest run" ;;
        bun)  TEST_CMD="bun x vitest run" ;;
        *)    TEST_CMD="$PM exec vitest run" ;;
      esac
    else
      fail "$PKG declares no non-interactive test entry: no 'test:ci', no test-named script whose body is a 'vitest run' form, and no vitest dependency to fall back on. A frontend run cannot gate on a watch-mode script — add a 'test:ci' script to the mount (or to the frontend template) and re-run. Nothing was written."
    fi
  fi

  # --- line 2: an extractor, defaulted to the runner's own failure vocabulary --
  # Only when the caller passed none: the orchestrator may know a sharper one.
  # Beyond the per-test `FAIL`/`✗`/`×` lines, capture vitest's UNHANDLED-REJECTION /
  # unhandled-error vocabulary and its `Errors N error(s)` summary: a suite that exits
  # non-zero PURELY from an unhandled rejection prints no per-test failure line at all,
  # so a FAIL/✗/×-only extractor matched NOTHING and the gate read a genuine red run as
  # EXTRACTOR_MISMATCH — a failure set that cannot be compared, so red-on-red could not
  # be dispositioned as a pass. These extra alternations give that run a stable,
  # comparable id (the rejection header and the error-count summary), turning the
  # mismatch back into a real, diffable failure set.
  [[ -n "$EXTRACTOR" ]] || EXTRACTOR='grep -E "^[[:space:]]*(FAIL|✗|×)[[:space:]]|Unhandled (Rejection|Error)|^[[:space:]]*Errors[[:space:]]+[0-9]+ error" | sed "s/^[[:space:]]*//" | sort -u'

  # --- line 3: the mount's build; typecheck JOINS it, never replaces the tests -
  if has_script build && has_script typecheck; then
    BUILD_CMD="$PM run build && $PM run typecheck"
  elif has_script build;     then BUILD_CMD="$PM run build"
  elif has_script typecheck; then BUILD_CMD="$PM run typecheck"
  fi

  # --- line 4: only a declared generator, never an invented one ---------------
  if [[ -z "$REGEN_CMD" ]] && has_script generate; then REGEN_CMD="$PM run generate"; fi

  echo "OK: frontend commands discovered under $MDIR ($PM): test='$TEST_CMD' build='${BUILD_CMD:-<none>}' regen='${REGEN_CMD:-<none>}'" >&2
fi

# --- command-write path ------------------------------------------------------
# TEST_CMD and EXTRACTOR stand or fall together (In: header): line 2 is required
# when line 1 is a real command AND must be empty when it is not. BOTH halves are
# refused here — the second half was previously unguarded, so a lone EXTRACTOR
# would ride onto line 2 above a `no tests detected` line 1, and if line 1 ever
# became a real command it would be gated by an extractor written for nothing.
if [[ -n "$TEST_CMD" ]]; then
  [[ -n "$EXTRACTOR" ]] \
    || fail "TEST_CMD is set but EXTRACTOR is empty — line 2 must carry the failure-set extractor, or every gate reads line 1 as uncomparable (gate-internal FAIL). Record both, or record neither."
else
  [[ -z "$EXTRACTOR" ]] \
    || fail "EXTRACTOR is set but TEST_CMD is empty — line 2 would carry a failure-set extractor for a test command that does not exist. Record both, or record neither."
fi

write_positional \
  "$(or_literal "$TEST_CMD"  'no tests detected')" \
  "$EXTRACTOR" \
  "$(or_literal "$BUILD_CMD" 'no build check')" \
  "$(or_literal "$REGEN_CMD" 'no regen command')"

# The census extractor rides the SAME command-write call, into its sibling file.
write_census "$(or_literal "$CENSUS" 'no census extractor')"

# Queued discovery rejections land LAST — after line 4 exists.
if [[ -n "$REJQ" ]] && [[ -s "$REJQ" ]]; then
  while IFS='	' read -r RC RR; do
    [[ -n "$RC" ]] || continue
    append_rejection "$RC" "$RR"
  done < "$REJQ"
fi
[[ -z "$REJQ" ]] || rm -f "$REJQ"
