# component-kind.sh — is this component a facade or a proper component?
# Sourceable helper. Usage:
#   . "$HERE/lib/component-kind.sh"
#   component_kind [<component-root>]      → prints `facade` or `component`
#   init_mk_is_facade <path-to-.init.mk>   → exit 0 when the facade check holds
#   template_tree_kind <tree-root>         → `facade` or `component`, by go.mod module
#   FACADE_TEMPLATE_REPO / COMPONENT_TEMPLATE_REPO — the canonical template URLs
#
# Component kind. Order: `.kairos/manifest.yaml` `template.kind` when it is
# `facade` or `component` (the Kairos CLI stamps it from 0.3.35, and
# in-progress.sh ACTION=bootstrap writes it); otherwise the facade check on
# `.init.mk`: it sets `MASTERDATA_INCLUDE_NO_CDC` to a non-empty value, or sets
# `GENERATE_MODULES` without `sql` or `all`. Committed facades carry
# `GENERATE_MODULES := masterdata json` (every facade-template commit after the
# initial one); the marker is not committed in the facade template yet. Regular
# components leave `GENERATE_MODULES` unset (toolkit default `all`). The toolkit
# declares the marker empty (`?=`), so only a non-empty assignment counts.
#
# Template tree kind (template_tree_kind): by the root go.mod module line, which
# every facade-template commit after the initial one carries and the Kairos CLI
# keys on. A fork with another module path falls back to the .init.mk check.
#
# WHY it matters: a facade is materialized from kairos-component-facade-template
# with `kairos component facade create`. `component create` over that tree
# rewrites the wrong module path, and a facade scored or merged against
# kairos-component-template gains runtimes it must not have.

FACADE_TEMPLATE_REPO=git@ssh.bitbucket.org:ifs-pd/kairos-component-facade-template.git
COMPONENT_TEMPLATE_REPO=git@ssh.bitbucket.org:ifs-pd/kairos-component-template.git
FACADE_TEMPLATE_MODULE=bitbucket.org/ifs-pd/kairos-component-facade-template
COMPONENT_TEMPLATE_MODULE=bitbucket.org/ifs-pd/kairos-component-template

init_mk_is_facade() {
  [[ -f "$1" ]] || return 1
  grep -qE '^[[:space:]]*MASTERDATA_INCLUDE_NO_CDC[[:space:]]*[:?+]?=[[:space:]]*[^[:space:]#]' "$1" && return 0
  # GENERATE_MODULES assigned a non-empty value (comment stripped) with no
  # `sql` or `all` word. The last assignment wins, as in make.
  _ck_gm=$(sed -nE 's/^[[:space:]]*GENERATE_MODULES[[:space:]]*[:?]?=([^#]*).*/\1/p' "$1" | tail -1)
  case " $(printf '%s' "$_ck_gm" | tr '\t' ' ') " in
    *[!\ ]*) ;;
    *) return 1 ;;
  esac
  case " $(printf '%s' "$_ck_gm" | tr '\t' ' ') " in
    *" sql "*|*" all "*) return 1 ;;
  esac
  return 0
}

# template_tree_kind <tree-root> → prints `facade` or `component`
template_tree_kind() {
  _ck_mod=$(sed -nE 's/^[[:space:]]*module[[:space:]]+"?([^"[:space:]]+)"?.*/\1/p' "$1/go.mod" 2>/dev/null | head -1)
  case "$_ck_mod" in
    "$FACADE_TEMPLATE_MODULE") echo facade ;;
    "$COMPONENT_TEMPLATE_MODULE") echo component ;;
    *) if init_mk_is_facade "$1/.init.mk"; then echo facade; else echo component; fi ;;
  esac
}

component_kind() {
  _ck_root=${1:-.}
  _ck_kind=""
  if [[ -f "$_ck_root/.kairos/manifest.yaml" ]]; then
    _ck_kind=$(yq -r '.template.kind // ""' "$_ck_root/.kairos/manifest.yaml" 2>/dev/null || true)
  fi
  case "$_ck_kind" in
    facade|component) printf '%s\n' "$_ck_kind" ;;
    *) if init_mk_is_facade "$_ck_root/.init.mk"; then echo facade; else echo component; fi ;;
  esac
}
