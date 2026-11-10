#!/usr/bin/env bash
# fake-kairos.sh — a stand-in for the Kairos CLI, placed on PATH as `kairos` by
# tests/lib.sh (sourced by every *.test.sh suite).
#
# WHY this seam: materialize.sh builds the merge sides by invoking
# `kairos component create`. The process boundary is the HIGHEST seam available —
# it is exactly where the real CLI sits — so testing here keeps the suite
# hermetic: no real CLI install, no goproxy, no network, no Go toolchain.
#
# This shim is a CONTRACT TEST as much as a fixture. It hard-fails (exit 3) if
# materialize.sh ever stops passing the flags/env that keep creation
# non-interactive and side-effect-free, so a regression there surfaces as a loud
# test failure rather than as a migration that hangs waiting for a prompt.
#
# It deliberately reproduces the real CLI's substitution behavior, including the
# extension whitelist — that whitelist is why the skill's own substitution used to
# drift, so the fixture must exercise it rather than paper over it.
#
# Env knobs (set by the harness):
#   FAKE_KAIROS_VERSION   version to report (default 0.3.12)
#   FAKE_KAIROS_STALE     non-empty => behave like a pre-0.3.12 CLI: report 0.3.10
#                         and advertise none of the new flags. Used to prove
#                         pre-flight fails loudly instead of proceeding.
#   FAKE_KAIROS_CALL_LOG  path to append one line of arguments per invocation.
#                         Lets a test count invocations — the only way to observe
#                         pre-flight's throwaway warm-up call.
#   FAKE_KAIROS_NO_FACADE non-empty => behave like a pre-0.3.35 CLI: no
#                         `component facade` group (usage error, exit 2).
#   FAKE_KAIROS_FAIL_ONCE path to a state file. While it does not exist, the FIRST
#                         `component create` leaves a PARTIAL tree behind and exits
#                         1 with the real CLI's mid-invocation error; the file is
#                         created so every later call succeeds. Reproduces the
#                         production race materialize.sh retries through.
set -u

VERSION=${FAKE_KAIROS_VERSION:-0.3.12}
[[ -n "${FAKE_KAIROS_STALE:-}" ]] && VERSION=0.3.10

[[ -n "${FAKE_KAIROS_CALL_LOG:-}" ]] && echo "$*" >> "$FAKE_KAIROS_CALL_LOG"

if [[ "${1:-}" = "--version" ]]; then
  echo "kairos, version $VERSION"
  exit 0
fi

# `component facade create` (CLI >= 0.3.35) is the same flow over the facade
# template: no frontend step, no --no-frontend flag, and the facade template's
# module path is the one rewritten.
FACADE=0
if [[ "${1:-}" = "component" ]] && [[ "${2:-}" = "facade" ]] && [[ "${3:-}" = "create" ]]; then
  [[ -z "${FAKE_KAIROS_NO_FACADE:-}" ]] \
    || { echo "Error: No such command 'facade'." >&2; exit 2; }
  FACADE=1
  set -- component "${@:3}"   # drop `facade`: the rest parses like `component create`
  if [[ "${3:-}" = "--help" ]]; then
    echo "Usage: kairos component facade create [OPTIONS] COMPONENT_NAME [TARGET_DIRECTORY]"
    echo "Options:"
    echo "  --template-path DIR  Local folder to use as the facade template"
    echo "  --no-repository      Skip git repository initialization"
    echo "  --no-skills          Skip skills pack installation"
    echo "  --no-tidy            Skip running go mod tidy on the created facade"
    exit 0
  fi
fi

[[ "${1:-}" = "component" ]] && [[ "${2:-}" = "create" ]] \
  || { echo "fake kairos: only 'component create' and 'component facade create' are implemented (got: $*)" >&2; exit 2; }

if [[ "${3:-}" = "--help" ]]; then
  echo "Usage: kairos component create [OPTIONS] COMPONENT_NAME [TARGET_DIRECTORY]"
  echo "Options:"
  echo "  --template-path DIR  Local folder to use as the component template"
  echo "  --no-repository      Skip git repository initialization"
  echo "  --no-skills          Skip skills pack installation"
  if [[ -z "${FAKE_KAIROS_STALE:-}" ]]; then
    echo "  --no-tidy            Skip running go mod tidy on the created component"
    echo "  --no-frontend        Skip frontend template setup (no web/ directory)"
  fi
  exit 0
fi

# Options and positionals may interleave in ANY order: the real CLI (click) and
# this shim's own usage string above both spell it `create [OPTIONS]
# COMPONENT_NAME [TARGET_DIRECTORY]`, so a caller that puts a flag before the name
# is well-formed and must not be rejected. The old fixed `NAME=$3; TARGET_DIR=$4`
# hard-required positionals-first and turned every flag-first call into an exit 2.
shift 2   # drop the `component create` verb pair
NAME="" TARGET_DIR="" SAW_TARGET=0
TEMPLATE_PATH=""
SAW_NO_REPO=0 SAW_NO_SKILLS=0 SAW_NO_TIDY=0 SAW_NO_FRONTEND=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --template-path) TEMPLATE_PATH=$2; shift 2 ;;
    --no-repository) SAW_NO_REPO=1; shift ;;
    --no-skills)     SAW_NO_SKILLS=1; shift ;;
    --no-tidy)       SAW_NO_TIDY=1; shift ;;
    --no-frontend)
      [[ "$FACADE" -eq 0 ]] || { echo "Error: No such option: --no-frontend" >&2; exit 2; }
      SAW_NO_FRONTEND=1; shift ;;
    --*) echo "fake kairos: unexpected flag '$1'" >&2; exit 2 ;;
    *)
      if [[ -z "$NAME" ]]; then NAME=$1
      elif [[ "$SAW_TARGET" -eq 0 ]]; then TARGET_DIR=$1; SAW_TARGET=1
      else echo "fake kairos: unexpected extra positional '$1'" >&2; exit 2
      fi
      shift ;;
  esac
done
[[ -n "$NAME" ]]        || { echo "fake kairos: COMPONENT_NAME missing" >&2; exit 2; }
[[ "$SAW_TARGET" -eq 1 ]] || { echo "fake kairos: TARGET_DIRECTORY missing" >&2; exit 2; }

# --- contract assertions ------------------------------------------------------
# Each of these, if violated, would make a REAL migration hang or mutate state:
# an unset name-validation escape hatch re-prompts on names containing 'kairos';
# a missing --no-frontend triggers the interactive frontend picker and a network
# clone; a missing --no-tidy pulls in goproxy and the Go toolchain.
[[ -n "${KAIROS_SKIP_NAME_VALIDATION:-}" ]] \
  || { echo "fake kairos: KAIROS_SKIP_NAME_VALIDATION not set — a real CLI would re-prompt for names containing 'kairos'/'nga'" >&2; exit 3; }
[[ "$SAW_NO_TIDY" -eq 1 ]] \
  || { echo "fake kairos: --no-tidy missing — a real CLI would require goproxy and the Go toolchain" >&2; exit 3; }
[[ "$FACADE" -eq 1 ]] || [[ "$SAW_NO_FRONTEND" -eq 1 ]] \
  || { echo "fake kairos: --no-frontend missing — a real CLI would prompt and clone the frontend template" >&2; exit 3; }
[[ "$SAW_NO_REPO" -eq 1 ]] \
  || { echo "fake kairos: --no-repository missing — a real CLI would git-init and commit" >&2; exit 3; }
[[ "$SAW_NO_SKILLS" -eq 1 ]] \
  || { echo "fake kairos: --no-skills missing — a real CLI would clone the skills pack" >&2; exit 3; }
[[ -n "$TEMPLATE_PATH" ]] && [[ -d "$TEMPLATE_PATH" ]] \
  || { echo "fake kairos: --template-path missing or not a directory: '$TEMPLATE_PATH'" >&2; exit 2; }

# --- materialize --------------------------------------------------------------
OUT="$TARGET_DIR/$NAME"
mkdir -p "$OUT"

# Fail-once: abort AFTER writing into $OUT, because the debris is the point — a
# retry that reused this directory would carry PARTIAL-ABORTED.txt into the
# materialized tree. The error text is the one the real CLI produced when its
# install changed under a running invocation.
if [[ -n "${FAKE_KAIROS_FAIL_ONCE:-}" ]] && [[ ! -f "$FAKE_KAIROS_FAIL_ONCE" ]]; then
  : > "$FAKE_KAIROS_FAIL_ONCE"
  echo "aborted mid-create" > "$OUT/PARTIAL-ABORTED.txt"
  echo "TypeError: component_create() missing 1 required positional argument: 'component_name'" >&2
  exit 1
fi

( cd "$TEMPLATE_PATH" && find . -mindepth 1 -maxdepth 1 ! -name .git -exec cp -R {} "$OUT/" \; )

# Content substitution — the real CLI's map, applied ONLY inside its extension
# whitelist. Reproduced faithfully so the fixture exercises the same blind spots
# the real CLI has.
esc_pat() { printf '%s' "$1" | sed -e 's/[][\.*^$/]/\\&/g'; }
esc_rep() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's|/|\\/|g' -e 's/&/\\&/g'; }
N=$(esc_rep "$NAME")
SED_SCRIPT=$(printf 's/%s/%s/g\n' "$(esc_pat '<YOUR_BC_NAME>')" "$N"
             printf 's/%s/%s/g\n' "$(esc_pat '<YOUR_COMPONENT_NAME>')" "$N"
             printf 's/%s/%s/g\n' "$(esc_pat 'YOUR_COMPONENT_NAME')" "$N"
             TPL_MOD=bitbucket.org/ifs-pd/kairos-component-template
             [[ "$FACADE" -eq 1 ]] && TPL_MOD=bitbucket.org/ifs-pd/kairos-component-facade-template
             printf 's/%s/%s/g\n' "$(esc_pat "$TPL_MOD")" \
                                  "$(esc_rep "bitbucket.org/ifs-pd/$NAME")")

find "$OUT" -type f -print | while IFS= read -r f; do
  base=${f##*/}
  # Path().suffix semantics, the real CLI's own test: a dotfile with no stem has NO
  # suffix (Path('.env').suffix == ''), so `.env` is outside the extension whitelist
  # and create leaves it verbatim. Kept identical to scripts/lib/frontend-substitute.sh
  # — the contract test diffs the two, so a divergence here is a false verdict either
  # way (`.env.local` still has the `.local` suffix).
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
  sed "$SED_SCRIPT" "$f" > "$f.subst" 2>/dev/null && mv "$f.subst" "$f" || rm -f "$f.subst"
done

# Filename substitution, deepest-first so renaming a parent can't invalidate
# paths still queued underneath it.
find "$OUT" -depth -name '*YOUR_BC_NAME*' -o -depth -name '*YOUR_COMPONENT_NAME*' \
     -o -depth -name '*your_bc_name*' -o -depth -name '*your_component_name*' \
  | while IFS= read -r p; do
      d=${p%/*}; b=${p##*/}
      nb=$(printf '%s' "$b" \
             | sed -e "s/YOUR_BC_NAME/$N/g" -e "s/YOUR_COMPONENT_NAME/$N/g" \
                   -e "s/your_bc_name/$N/g" -e "s/your_component_name/$N/g")
      [[ "$b" != "$nb" ]] && mv "$p" "$d/$nb"
    done

[[ "$FACADE" -eq 1 ]] && echo "INFO: fake kairos (facade create) materialized '$NAME' from $TEMPLATE_PATH into $OUT"
echo "INFO: fake kairos materialized '$NAME' from $TEMPLATE_PATH into $OUT"
exit 0
