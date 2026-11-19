# frontend-substitute.sh — the CLI's create-time replacement map, as a
# sourceable helper. Merge sides of a frontend run must be create-equivalent:
# `component create` copies the frontend subtree verbatim and then walks the
# WHOLE component (web/ included) applying this map, so a materialized BASE or
# TARGET tree that skipped it would conflict on every substituted file.
#
# Pinned to nga-local-dev cli/entities/component/create.py — content map +
# extension whitelist (_finish_component_from_template, target_extensions,
# target_filenames) and filename map (_apply_name_replacements). The
# materialize-frontend contract test compares this helper's output against the
# fixture CLI (tests/fake-kairos.sh), which reproduces the same algorithm; if
# the real CLI's token lists drift, fix all three together.
#
# Usage:  . "$SCRIPTS/lib/frontend-substitute.sh"
#         apply_create_substitution "$TREE_DIR" "$COMPONENT_NAME"
# Rewrites $TREE_DIR in place. Returns non-zero only on argument errors —
# unreadable individual files are skipped exactly as the CLI skips them.
# A failed rename in the filename pass (read-only parent dir, name collision)
# is the same class of per-file skip: the file is left under its placeholder
# name rather than lost, but a merge later reading that leftover name as a
# spurious add/delete pair is a real cost, so each skipped rename is reported
# on stderr (WARN, naming the path) and counted in a trailing summary line —
# still non-fatal, per this function's "argument errors only" return contract.

_fsub_esc_pat() { printf '%s' "$1" | sed -e 's/[][\.*^$/]/\\&/g'; }
_fsub_esc_rep() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's|/|\\/|g' -e 's/&/\\&/g'; }

apply_create_substitution() {
  _fsub_dir=$1
  _fsub_name=$2
  [[ -d "$_fsub_dir" ]] || { echo "FAIL: apply_create_substitution: not a directory: $_fsub_dir" >&2; return 1; }
  [[ -n "$_fsub_name" ]] || { echo "FAIL: apply_create_substitution: empty component name" >&2; return 1; }

  _fsub_n=$(_fsub_esc_rep "$_fsub_name")
  # Bracketed tokens before the bare token — '<YOUR_COMPONENT_NAME>' contains
  # 'YOUR_COMPONENT_NAME', and the CLI's dict applies in this insertion order.
  _fsub_script=$(printf 's/%s/%s/g\n' "$(_fsub_esc_pat '<YOUR_BC_NAME>')" "$_fsub_n"
                 printf 's/%s/%s/g\n' "$(_fsub_esc_pat '<YOUR_COMPONENT_NAME>')" "$_fsub_n"
                 printf 's/%s/%s/g\n' "$(_fsub_esc_pat 'YOUR_COMPONENT_NAME')" "$_fsub_n"
                 printf 's/%s/%s/g\n' "$(_fsub_esc_pat 'bitbucket.org/ifs-pd/kairos-component-template')" \
                                      "$(_fsub_esc_rep "bitbucket.org/ifs-pd/$_fsub_name")")

  find "$_fsub_dir" -type f -print | while IFS= read -r _fsub_f; do
    _fsub_base=${_fsub_f##*/}
    # The extension, with PYTHON's Path().suffix semantics, because that is what the
    # CLI tests against its whitelist: a dotfile whose whole name is the "extension"
    # has NO suffix (Path('.env').suffix == ''), so `.env` is not a whitelisted-
    # extension file and the CLI never rewrites it. Deriving it as `.${base##*.}`
    # made `.env` look like a `.env`-extension file and substituted a file the real
    # create leaves verbatim — a divergence the merge then reads as a local edit on
    # every side. `.env.local` DOES have a suffix (`.local`), which is why the test is
    # "no stem", not "starts with a dot".
    _fsub_ext=""
    case "$_fsub_base" in
      .*) case "${_fsub_base#.}" in *.*) _fsub_ext=".${_fsub_base##*.}" ;; esac ;;
      *.*) _fsub_ext=".${_fsub_base##*.}" ;;
    esac
    _fsub_keep=0
    case "$(printf '%s' "$_fsub_ext" | tr 'A-Z' 'a-z')" in
      .json|.yaml|.yml|.go|.txt|.ini|.md|.dockerfile|.env|.mk|.ts|.tsx|.conf|.html) _fsub_keep=1 ;;
    esac
    case "$_fsub_base" in Makefile|Dockerfile|.gitignore|go.mod|go.sum|renovate.config.js) _fsub_keep=1 ;; esac
    [[ "$_fsub_keep" -eq 1 ]] || continue
    sed "$_fsub_script" "$_fsub_f" > "$_fsub_f.subst" 2>/dev/null \
      && mv "$_fsub_f.subst" "$_fsub_f" || rm -f "$_fsub_f.subst"
  done

  # Filename substitution, deepest-first so renaming a parent can't invalidate
  # paths still queued underneath it.
  #
  # The list is captured to a temp file and read via `< "$_fsub_list"` (redirection,
  # not a pipe) rather than `find ... | while read; do ...; done`: a piped while
  # runs its body in a subshell, and `_fsub_skip` incremented there would vanish
  # the instant the loop ends — the exact shape that would make the failure count
  # below always read 0.
  _fsub_list=$(mktemp "${TMPDIR:-/tmp}/fsub-renames.XXXXXX") \
    || { echo "FAIL: apply_create_substitution: mktemp failed" >&2; return 1; }
  find "$_fsub_dir" -depth \( -name '*YOUR_BC_NAME*' -o -name '*YOUR_COMPONENT_NAME*' \
       -o -name '*your_bc_name*' -o -name '*your_component_name*' \) -print > "$_fsub_list"
  _fsub_skip=0
  while IFS= read -r _fsub_p; do
    _fsub_d=${_fsub_p%/*}; _fsub_b=${_fsub_p##*/}
    _fsub_nb=$(printf '%s' "$_fsub_b" \
           | sed -e "s/YOUR_BC_NAME/$_fsub_n/g" -e "s/YOUR_COMPONENT_NAME/$_fsub_n/g" \
                 -e "s/your_bc_name/$_fsub_n/g" -e "s/your_component_name/$_fsub_n/g")
    if [[ "$_fsub_b" != "$_fsub_nb" ]]; then
      if ! mv "$_fsub_p" "$_fsub_d/$_fsub_nb" 2>/dev/null; then
        _fsub_skip=$((_fsub_skip + 1))
        echo "WARN: apply_create_substitution: rename failed, left under placeholder name: $_fsub_p" >&2
      fi
    fi
  done < "$_fsub_list"
  rm -f "$_fsub_list"
  [[ "$_fsub_skip" -gt 0 ]] \
    && echo "WARN: apply_create_substitution: $_fsub_skip filename rename(s) skipped (placeholder names left in place — see WARN lines above)" >&2
  return 0
}
