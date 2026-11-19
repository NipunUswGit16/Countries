# fetch-local-clone.sh — best-effort `git fetch` of a LOCAL checkout before its
# refs are read to bound a migration range. Sourceable helper. Usage:
#   . "$HERE/lib/fetch-local-clone.sh"
#   fetch_local_clone <dir> [<label>]
#
# WHY THIS EXISTS: a range's BASE endpoint is a released tag/version the component
# pins (e.g. toolkit/v1.0.44). When the range is resolved against a user's LOCAL
# checkout — a co-developed common clone (collect-common.sh's local-path replace
# arm) or a --template-path / --frontend-path mirror ORIGIN (pre-flight.sh) — that
# checkout only carries the refs it last fetched. A pin released upstream AFTER the
# checkout last fetched is simply absent, so `base..HEAD` cannot be bounded and the
# module lands `unresolvable` (or the mirror is cloned already missing BASE) for no
# reason other than a stale local clone. Co-dev authors hit this constantly: they
# pull the common/frontend repo rarely, but the template keeps pinning newer ones.
# The remedy they reach for by hand is `git pull`; this does the safe half of it,
# automatically, at the one moment it is cheap — before the range is resolved.
#
# NON-DESTRUCTIVE, emphatically NOT `git pull`: `git fetch --tags` updates tags and
# remote-tracking refs only. It never touches the working tree and never moves the
# checked-out (co-dev) branch HEAD — which is exactly what a range collection wants:
# BASE resolvable, HEAD (the unpushed co-dev work) untouched. --prune / --prune-tags
# are deliberately NOT passed: those would delete a locally-authored co-dev tag the
# range may depend on.
#
# NON-FATAL: an offline run, a checkout with no remote, or an unreachable remote is
# not a failure of the migration. A checkout with no remote says nothing (a purely
# local co-dev repo is a supported layout); a fetch that was attempted and failed
# WARNs (git's own error is quoted so it is debuggable) and proceeds on whatever
# refs are already local — byte-identical to the pre-fetch-less behavior. The
# function ALWAYS returns 0: a fetch that could not run must never turn a healthy
# offline migration into a hard failure.
#
# IDEMPOTENT within a run: a co-dev component replaces several common modules with
# the SAME clone, so this is called once per module against one repo. The first call
# fetches; the rest are no-ops, deduped on the git toplevel. The dedup set is a
# module-global, so it survives across the per-module calls a caller makes in one
# shell (collect-common.sh's resolution loop runs in the current shell — a process
# substitution, not a pipe — so the global persists).

# Newline-delimited set of already-fetched git toplevels. A path can carry a space
# but not a newline in this codebase's fixtures, so newline is a safe separator.
_FETCH_LOCAL_CLONE_DONE=${_FETCH_LOCAL_CLONE_DONE:-}

fetch_local_clone() { # fetch_local_clone <dir> [<label>]
  local dir="$1" label="${2:-local clone}" top nl remotes err
  nl=$'\n'
  # Resolve to the git toplevel so two spellings of one clone dedupe to a single
  # fetch, and so a subtree path (a --frontend-path at template/react) fetches the
  # ENCLOSING repo. A path that is not a git repo cannot be fetched — silently done,
  # not a warning: the callers already validate "is a git repo" for their own reasons,
  # and this helper must never be the thing that fails on a non-repo.
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  [[ -n "$top" ]] || return 0
  case "$nl$_FETCH_LOCAL_CLONE_DONE$nl" in
    *"$nl$top$nl"*) return 0 ;;   # already fetched this clone this run
  esac
  _FETCH_LOCAL_CLONE_DONE="$_FETCH_LOCAL_CLONE_DONE$nl$top"
  # No remote configured → nothing upstream to fetch. Say nothing: this is a real,
  # supported co-dev layout, not a failure to fetch.
  remotes=$(git -C "$top" remote 2>/dev/null) || return 0
  [[ -n "$remotes" ]] || return 0
  # --tags so a released BASE tag arrives even when it sits on no fetched branch. No
  # remote argument: git uses the checkout's default (origin, or the current branch's
  # upstream) — the remote it actually tracks. --quiet: progress is noise, not
  # diagnosis. git's own stderr is captured, not discarded, so the WARN can name the
  # cause (unreachable origin, auth failure) instead of a bare "could not fetch".
  if err=$(git -C "$top" fetch --tags --quiet 2>&1); then
    return 0
  fi
  echo "WARNING: could not fetch $label at $top ($(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)) — proceeding with the refs already present locally. If a pinned baseline tag turns up missing below, run 'git -C $top fetch --tags' by hand and re-run." >&2
  return 0
}
