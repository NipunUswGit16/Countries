#!/usr/bin/env bash
# bellwether-detect.sh — score template commits by how many bellwether files in
# the component match byte-for-byte (after CRLF normalization). Used ONCE per
# component, at bootstrap, to detect the template baseline SHA.
#
# The bellwether list is SOURCE-defined, resolved in three tiers at the tip of the
# targeted branch: (1) .kairos-updates/config.yaml's modules.<MODULE>.bellwethers,
# when the source repo self-describes and MODULE names one of its modules; (2) the
# legacy flat .kairos-updates/bellwethers.txt (one path per line, # comments
# allowed); (3) a hardcoded v1 fallback set. Repos with no config.yaml — the
# component template, common — take tier 2 or tier 3 exactly as before. A module
# DECLARED in config.yaml with no bellwethers skips tier 2 (that list is repo-root
# relative; a configured module's paths are subtree-relative) and lands on tier 3 with
# a warning naming the fix.
#
# MODULE_PATH follows the SAME precedence as materialize-frontend.sh's: the config at
# the resolved commit wins over the passed/manifest value, with a WARN on disagreement.
# The two must not drift — the scored subtree and the merged subtree have to be the
# same tree.
#
# MOUNT switches scoring to the FRONTEND arm: the component's mount (web/) is scored
# against the module subtree, and THE SUBTREE SIDE IS SUBSTITUTED FIRST with the
# CLI's create-time replacement map (scripts/lib/frontend-substitute.sh). The mount
# already carries the component's own name where the subtree carries a placeholder,
# so scoring raw subtrees mismatches every substituted file at EVERY candidate
# commit and the true create commit ranks no better than any other. That asymmetry
# is the whole point: substitute, then score.
#
# When bellwether scoring does NOT auto-confirm (the common bootstrap failure:
# the template ships no bellwethers.txt, the fallback set ties five ways, and the
# top-3 shown to the developer carries no information), a WIDE-SIGNAL FALLBACK
# scan runs: every file present in both the template tip and the component is
# compared across candidate commits, substitution-aware, and the peak match count
# picks the baseline. It also emits a ready-to-ship bellwethers.txt suggestion so
# the next component's detection is cheap and accurate.
#
# Env in:  PHASE_KEY  required — proof-of-load key stated in phases/2-resolve-target.md
#          CACHE  RUN            (cwd = component root)
#          TEMPLATE_BRANCH       optional, default main — the branch the run
#                                RESOLVED, for a frontend source as for a template
#          COMPONENT_NAME        optional — substitution (frontend scoring, wide
#                                scan); default manifest `name:`, else cwd basename
#          MODULE                optional — config.yaml module key (the manifest's
#                                `frontend.template`). Selects tier 1's bellwethers
#          MODULE_PATH           optional — that module's subtree path in the source
#                                repo. The FALLBACK, not the authority: the module's
#                                config.yaml `path` at $BRANCH wins (WARN on
#                                disagreement), matching materialize-frontend.sh
#          MOUNT                 optional — the component dir the module is mounted
#                                at (e.g. web/). Present = the frontend scoring arm;
#                                absent = template scoring, byte-identical to before
# Out (in $RUN):
#   bellwether-scores.txt      "<matches> <total> <sha>" sorted best-first
#   bellwether-top.txt         top 5 annotated with commit subjects
#   widescan-scores.txt        same shape as bellwether-scores.txt (empty if skipped)
#   widescan-top.txt           same shape as bellwether-top.txt   (empty if skipped)
#   bellwether-suggestions.txt one path per line, ready to paste into
#                              .kairos-updates/bellwethers.txt  (empty if skipped)
# Stdout:  N_BELLWETHERS=<count>
#          WIDESCAN=ran|skipped
#          N_WIDESCAN_FILES=<shared files scanned; 0 when skipped>
set -u

# Phase-load guard: this key is stated ONLY in phases/2-resolve-target.md, so an
# orchestrator that skipped loading that file cannot know it. The guard turns a
# skipped load into a stop instead of a phase improvised from stub knowledge.
[[ "${PHASE_KEY:-}" = "k3wq8vfr" ]] \
  || { echo "FAIL: load phases/2-resolve-target.md first" >&2; exit 1; }

for v in CACHE RUN; do
  [[ -n "$(eval echo "\${$v:-}")" ]] || { echo "FAIL: $v not set" >&2; exit 1; }
done
mkdir -p "$RUN"
BRANCH=${TEMPLATE_BRANCH:-main}
MODULE=${MODULE:-}
MODULE_PATH=${MODULE_PATH:-}
MOUNT=${MOUNT:-}
MOUNT=${MOUNT%/}                # `web/` and `web` address the same tree
[[ -z "$MOUNT" ]] || [[ -d "$MOUNT" ]] || {
  echo "FAIL: MOUNT=$MOUNT is not a directory under $(pwd) — the frontend arm scores the" >&2
  echo "      component's mount, and an absent one scores every candidate 0/0, i.e. reports" >&2
  echo "      'no signal' for a component whose baseline is perfectly detectable." >&2
  exit 1
}

# Component name for the substitution maps: BOTH the frontend scoring arm below and
# the wide scan at the bottom need it. Manifest `name:` is the truth; the cwd
# basename is the last resort, because at bootstrap there may be no manifest yet.
COMP_NAME=${COMPONENT_NAME:-}
if [[ -z "$COMP_NAME" ]] && command -v yq >/dev/null 2>&1; then
  COMP_NAME=$(yq -r '.name // ""' .kairos/manifest.yaml 2>/dev/null || echo "")
fi
[[ -n "$COMP_NAME" ]] || COMP_NAME=$(basename "$(pwd)")

CFG=.kairos-updates/config.yaml
BELLWETHERS=()
# Tier 1 — the source repo self-describes. Nothing here knows a module name: MODULE
# is the manifest's `frontend.template` key, and the entry it selects supplies the
# bellwethers AND (unless the caller passed one) the subtree path. A second module in
# the same repo therefore needs no change to this script.
# CFG_MODULE_DECLARED records that the config.yaml at $BRANCH DECLARES an entry for
# $MODULE — the fact tier 2 keys off below, and deliberately narrower than "a config
# exists": a module the config does not declare at all is not a configured module, and
# it must keep falling through to the legacy list exactly as before.
CFG_MODULE_DECLARED=0
if [[ -n "$MODULE" ]] && git -C "$CACHE" cat-file -e "$BRANCH:$CFG" 2>/dev/null; then
  if command -v yq >/dev/null 2>&1; then
    CFG_HAS_MODULE=$(git -C "$CACHE" show "$BRANCH:$CFG" \
                       | MOD="$MODULE" yq -r '.modules | has(strenv(MOD))' - 2>/dev/null || echo "")
    [[ "$CFG_HAS_MODULE" != true ]] || CFG_MODULE_DECLARED=1
    while IFS= read -r line; do
      line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [[ -n "$line" ]] && BELLWETHERS+=("$line")
    done < <(git -C "$CACHE" show "$BRANCH:$CFG" \
               | MOD="$MODULE" yq -r '.modules[strenv(MOD)].bellwethers[]' - 2>/dev/null)
    # The SUBTREE, on the same precedence rule materialize-frontend.sh applies and for
    # the same reason: the path is the SOURCE's fact, so the config at the resolved
    # branch WINS over whatever the caller passed (a component manifest's frontend.path
    # goes stale the instant upstream relocates the module). The two scripts have to
    # agree about which subtree a component was built from — one giving the env
    # precedence and the other the config is how the SCORED subtree and the MERGED
    # subtree come to be different trees. A disagreement is said out loud, never
    # silently preferred.
    CFG_MODULE_PATH=$(git -C "$CACHE" show "$BRANCH:$CFG" \
                        | MOD="$MODULE" yq -r '.modules[strenv(MOD)].path // ""' - 2>/dev/null || echo "")
    case "$CFG_MODULE_PATH" in null) CFG_MODULE_PATH="" ;; esac
    CFG_MODULE_PATH=${CFG_MODULE_PATH%/}
    if [[ -n "$CFG_MODULE_PATH" ]]; then
      if [[ -n "$MODULE_PATH" ]] && [[ "$MODULE_PATH" != "$CFG_MODULE_PATH" ]]; then
        echo "WARN: $CFG at $BRANCH puts module '$MODULE' at '$CFG_MODULE_PATH', but this run was" \
             "given '$MODULE_PATH' (MODULE_PATH, or the component manifest's frontend.path)." \
             "Scoring against the SOURCE's value '$CFG_MODULE_PATH' — it is the authority, and" \
             "materialize resolves it the same way, so scoring the other one would score a" \
             "different subtree than the merge will use. Update .kairos/manifest.yaml's" \
             "frontend.path to match." >&2
      fi
      MODULE_PATH=$CFG_MODULE_PATH
    fi
    if [[ "${#BELLWETHERS[@]}" -gt 0 ]]; then
      echo "INFO: using config.yaml bellwethers for module '$MODULE' (${#BELLWETHERS[@]})" >&2
    else
      echo "INFO: $CFG at $BRANCH declares no bellwethers for module '$MODULE' — falling through" >&2
    fi
  else
    echo "WARN: $CFG exists at $BRANCH but yq is not installed, so module '$MODULE' bellwethers" \
         "cannot be read — falling through to the legacy list" >&2
  fi
fi
# Tier 2 — the legacy flat list, which is what the component template and common ship.
# SKIPPED when the config DECLARES $MODULE (CFG_MODULE_DECLARED): that
# list is REPO-ROOT-relative, while a configured repo's paths are module-subtree-relative
# — so on the frontend arm its entries get addressed as $MODULE_PATH/<path>, resolve to
# nothing at every candidate commit, and the run reports "no signal" for a component
# whose baseline is perfectly detectable. Worse, it did so SILENTLY: a non-empty tier-2
# list also suppressed tier 3's frontend-shaped warning, so the one message naming the
# fix never printed. A configured module with no declared bellwethers therefore goes
# straight to the module-relative fallback set, with that warning.
if [[ "${#BELLWETHERS[@]}" -eq 0 ]] && [[ "$CFG_MODULE_DECLARED" -eq 1 ]]; then
  echo "WARN: module '$MODULE' is declared in $CFG at $BRANCH but lists no bellwethers, so the" \
       "legacy repo-root .kairos-updates/bellwethers.txt is SKIPPED — its paths are repo-root" \
       "relative and a configured module's are subtree-relative, so reading it here would score" \
       "paths that exist nowhere and report 'no signal'. Falling through to the fallback set." \
       "Declare bellwethers for '$MODULE' in $CFG (tier 1) — that is what makes this detection" \
       "accurate without touching the skill." >&2
fi
if [[ "${#BELLWETHERS[@]}" -eq 0 ]] && [[ "$CFG_MODULE_DECLARED" -eq 0 ]] \
   && git -C "$CACHE" cat-file -e "$BRANCH:.kairos-updates/bellwethers.txt" 2>/dev/null; then
  while IFS= read -r line; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -n "$line" ]] && BELLWETHERS+=("$line")
  done < <(git -C "$CACHE" show "$BRANCH:.kairos-updates/bellwethers.txt")
  echo "INFO: using template-defined bellwethers (${#BELLWETHERS[@]})" >&2
fi
if [[ "${#BELLWETHERS[@]}" -eq 0 ]]; then
  # v1 fallback. Deliberately excludes README.md / AGENTS.md (always customized).
  BELLWETHERS=(renovate.json tools.go bitbucket-pipelines.yml .editorconfig UPGRADE.md)
  echo "INFO: using fallback bellwether set (${#BELLWETHERS[@]})" >&2
  # Tier 3 is component-template-shaped. On a frontend-shaped source it matches
  # nothing at all, and "no signal" then looks like a hard-to-detect component
  # rather than a source repo that simply never declared its bellwethers.
  [[ -z "$MOUNT" ]] || echo "WARN: this source is frontend-shaped but fell through to the v1 fallback set" \
    "— expect no signal. Declare bellwethers for module '${MODULE:-<unset>}' in $CFG (tier 1)" \
    "to make this detection accurate without touching the skill." >&2
fi

# Candidate commits = those that touched at least one bellwether. Capped at the
# 500 most recent so scoring stays bounded on long source histories. Both arms write
# the same `<matches> <total> <sha>` rows, and the ONE ranking pipeline below turns
# them into bellwether-scores.txt — so the two arms can never rank differently.
BW_RAW="$RUN/.bellwether-raw.txt"
: > "$BW_RAW"

if [[ -n "$MOUNT" ]]; then
  # --- frontend arm: mount vs module subtree, substitution-aware ---------------
  # Bellwether paths are MODULE-SUBTREE-RELATIVE (the authoring contract — never
  # `web/`-prefixed), so each one addresses $MODULE_PATH/<path> on the source side
  # and $MOUNT/<path> on the component side. The staged source side goes through the
  # CLI's own replacement map before comparison; see the header for why a raw
  # subtree cannot rank the true create commit first.
  [[ -n "$MODULE_PATH" ]] || {
    echo "FAIL: MOUNT is set but no MODULE_PATH — neither the env nor $CFG at $BRANCH gives" >&2
    echo "      module '${MODULE:-<unset>}' a subtree path, so there is nothing to score against." >&2
    exit 1
  }
  HERE=$(cd "$(dirname "$0")" && pwd)
  [[ -r "$HERE/lib/frontend-substitute.sh" ]] || {
    echo "FAIL: missing $HERE/lib/frontend-substitute.sh — it owns the create-time replacement" >&2
    echo "      map, and scoring raw subtrees ranks the true create commit no better than any" >&2
    echo "      other, which is a WRONG baseline presented confidently." >&2
    exit 1
  }
  # shellcheck source=lib/frontend-substitute.sh
  . "$HERE/lib/frontend-substitute.sh" \
    || { echo "FAIL: could not source $HERE/lib/frontend-substitute.sh" >&2; exit 1; }
  command -v apply_create_substitution >/dev/null 2>&1 \
    || { echo "FAIL: lib/frontend-substitute.sh defined no apply_create_substitution — refusing to score raw subtrees" >&2; exit 1; }

  CAND_PATHS=()
  for f in "${BELLWETHERS[@]}"; do CAND_PATHS+=("$MODULE_PATH/$f"); done
  CANDIDATES=$(git -C "$CACHE" log -500 --pretty=format:%H "$BRANCH" -- "${CAND_PATHS[@]}")
  N_CAND=$(printf '%s\n' $CANDIDATES | grep -c . || true)

  # Staged per candidate commit, because substitution is a whole-tree operation
  # (filename tokens included) and the helper takes a directory, not a stream.
  STAGE="$RUN/.bwstage"
  STAGED="$RUN/.bwstaged.txt"
  RENAMED_AWAY=0
  for SHA in $CANDIDATES; do
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    : > "$STAGED"
    for f in "${BELLWETHERS[@]}"; do
      # Only count files that exist in BOTH the module subtree at SHA and the mount.
      [[ -f "$MOUNT/$f" ]] || continue
      git -C "$CACHE" cat-file -e "$SHA:$MODULE_PATH/$f" 2>/dev/null || continue
      # Fail closed, never `|| continue`: an absent blob (the check above) is a
      # graceful no-count, but a failed mkdir is a disk/permission fault. Left
      # unchecked, the `> "$STAGE/$f"` redirect below can't create the file and
      # its own `|| continue` swallows it — the bellwether silently drops out of
      # STAGED, shrinking `total` (the scoring denominator) as if the file were
      # simply absent at this SHA. That skews the ratio ranking with no diagnostic.
      mkdir -p "$STAGE/$(dirname "$f")" \
        || { echo "FAIL: could not create staging dir for '$f' under $STAGE" >&2; exit 1; }
      git -C "$CACHE" cat-file blob "$SHA:$MODULE_PATH/$f" > "$STAGE/$f" 2>/dev/null || continue
      printf '%s\n' "$f" >> "$STAGED"
    done
    [[ -s "$STAGED" ]] || continue
    apply_create_substitution "$STAGE" "$COMP_NAME" >/dev/null \
      || { echo "FAIL: the create-time substitution failed on the subtree staged at $SHA" >&2; exit 1; }
    matches=0; total=0
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      total=$((total + 1))
      # A bellwether whose FILENAME carries a placeholder token is renamed by the map
      # (exactly as the CLI renamed it in the mount), so the staged path is gone:
      # counted as a no-match, the same graceful degradation a renamed bellwether
      # already gets. Declare bellwethers with literal names.
      [[ -f "$STAGE/$f" ]] || { RENAMED_AWAY=1; continue; }
      if diff -q <(tr -d '\r' < "$STAGE/$f") <(tr -d '\r' < "$MOUNT/$f") > /dev/null 2>&1; then
        matches=$((matches + 1))
      fi
    done < "$STAGED"
    [[ "$total" -gt 0 ]] && printf '%d %d %s\n' "$matches" "$total" "$SHA" >> "$BW_RAW"
  done
  rm -rf "$STAGE"; rm -f "$STAGED"
  [[ "$RENAMED_AWAY" -eq 0 ]] || echo "WARN: a bellwether FILENAME carries a placeholder token — the mount carries the" \
    "substituted name, so it can never match; declare literal names in $CFG" >&2
  echo "INFO: frontend scoring: mount '$MOUNT' vs subtree '$MODULE_PATH' over $N_CAND candidate" \
       "commit(s), create-time substitution applied to the subtree side" >&2
else
  CANDIDATES=$(git -C "$CACHE" log -500 --pretty=format:%H "$BRANCH" -- "${BELLWETHERS[@]}")
  for SHA in $CANDIDATES; do
    matches=0; total=0
    for f in "${BELLWETHERS[@]}"; do
      # Only count files that exist in BOTH the template at SHA and the component.
      if git -C "$CACHE" cat-file -e "$SHA:$f" 2>/dev/null && [[ -f "$f" ]]; then
        total=$((total + 1))
        if diff -q <(git -C "$CACHE" show "$SHA:$f" 2>/dev/null | tr -d '\r') <(tr -d '\r' < "$f") > /dev/null 2>&1; then
          matches=$((matches + 1))
        fi
      fi
    done
    [[ "$total" -gt 0 ]] && printf '%d %d %s\n' "$matches" "$total" "$SHA" >> "$BW_RAW"
  done
fi

awk '{ printf "%d %s\n", ($1 * 10000) / $2, $0 }' "$BW_RAW" \
  | sort -s -k1,1nr -k3,3nr \
  | cut -d' ' -f2- > "$RUN/bellwether-scores.txt"
rm -f "$BW_RAW"
# Ranked by confidence RATIO (matches/total, scaled to an integer to stay
# locale-safe), ties broken by higher total, then recency (stable sort keeps
# git-log order). Raw match count alone would rank 4/5 above a perfect 3/3.

head -5 "$RUN/bellwether-scores.txt" | while read -r m t sha; do
  echo "$m/$t $sha $(git -C "$CACHE" log -1 --pretty=%s "$sha")"
done > "$RUN/bellwether-top.txt"

echo "OK: scores in $RUN/bellwether-scores.txt, top candidates:" >&2
cat "$RUN/bellwether-top.txt" >&2
echo "N_BELLWETHERS=${#BELLWETHERS[@]}"

# =============================================================================
# Wide-signal fallback
# =============================================================================
# Trigger: the wide scan runs unless bellwether scoring is both CONFIDENT and
# DISCRIMINATING.
#
#   confident      — regime 1 of reference/bellwether-detection.md:
#                    matches >= total - 1 AND total >= 3 AND no ratio tie at the top.
#   discriminating — the scan actually told candidate commits apart: at least two
#                    distinct ratios appear among the scored candidates.
#
# The discrimination test is NOT redundant, and omitting it reproduces the exact
# production failure this fallback exists to fix. Candidate commits are only
# those that TOUCHED a bellwether, so a template whose bellwethers almost never
# change yields a tiny candidate set — in the degenerate case exactly one commit,
# which then scores a "confident" total/total and pins the baseline to the last
# commit that happened to touch a bellwether, arbitrarily far from the truth. A
# lone perfect score is not evidence; it is the absence of evidence. Requiring
# two distinct ratios means some commit was actually ruled OUT.
#
# Computed HERE, not by the orchestrator, so the script is self-triggering and
# the two definitions of "confident" can never drift apart.
: > "$RUN/widescan-scores.txt"
: > "$RUN/widescan-top.txt"
: > "$RUN/bellwether-suggestions.txt"

# THE WIDE SCAN IS A TEMPLATE-ARM FALLBACK. In the frontend arm it is not
# applicable: every comparison there has to be create-substituted and mount-mapped,
# which means materializing a whole subtree per candidate commit — prohibitive over
# 500 commits, where the template arm gets away with hashing each unique blob once.
# A configured source repo declares its module's bellwethers in config.yaml, which is
# exactly what tier 1 exists for, so weak signal here routes through the ordinary
# regime-2 / regime-3 gating (top-3 selection, then ask) instead of a scan that
# cannot be made honest cheaply. The three artifacts above are truncated FIRST, so a
# chained run can never serve the template run's wide-scan files as this run's.
if [[ -n "$MOUNT" ]]; then
  echo "INFO: frontend arm — no wide scan. Gate on the bellwether scores; if they are weak," \
       "present the top candidates or ask (reference/bellwether-detection.md)." >&2
  echo "WIDESCAN=skipped"
  echo "N_WIDESCAN_FILES=0"
  exit 0
fi

ratio_of() { echo $(( ($1 * 10000) / $2 )); }   # integer, locale-safe (as above)

AUTO_CONFIRM=0
if [[ -s "$RUN/bellwether-scores.txt" ]]; then
  # shellcheck disable=SC2046
  set -- $(head -1 "$RUN/bellwether-scores.txt"); BW_M=$1; BW_T=$2
  BW_R1=$(ratio_of "$BW_M" "$BW_T")
  BW_R2=-1
  BW_L2=$(sed -n 2p "$RUN/bellwether-scores.txt")
  if [[ -n "$BW_L2" ]]; then
    # shellcheck disable=SC2086
    set -- $BW_L2; BW_R2=$(ratio_of "$1" "$2")
  fi
  BW_DISTINCT=$(awk '{ printf "%d\n", ($1 * 10000) / $2 }' "$RUN/bellwether-scores.txt" \
                  | sort -u | grep -c .)
  if [[ "$BW_M" -ge $((BW_T - 1)) ]] && [[ "$BW_T" -ge 3 ]] \
     && [[ "$BW_R1" -ne "$BW_R2" ]] && [[ "$BW_DISTINCT" -ge 2 ]]; then
    AUTO_CONFIRM=1
  fi
fi

if [[ "$AUTO_CONFIRM" -eq 1 ]]; then
  echo "INFO: bellwethers auto-confirm ($BW_M/$BW_T, $BW_DISTINCT distinct scores) — wide scan not needed" >&2
  echo "WIDESCAN=skipped"
  echo "N_WIDESCAN_FILES=0"
  exit 0
fi
if [[ "${BW_DISTINCT:-0}" -lt 2 ]] && [[ -s "$RUN/bellwether-scores.txt" ]]; then
  echo "INFO: bellwethers could not tell candidates apart (${BW_DISTINCT:-0} distinct score);" \
       "their signal is structurally uninformative here — running wide scan" >&2
else
  echo "INFO: bellwether signal is not auto-confirming — running wide scan" >&2
fi

WS="$RUN/.widescan"
rm -rf "$WS"; mkdir -p "$WS"

# --- substitution map (SIMILARITY SCORING ONLY) --------------------------------
# Template blobs carry placeholder tokens; the component carries real values, so
# a raw comparison would mismatch every substituted file. This is a deliberately
# lightweight approximation of what `kairos component create` does — it is used
# ONLY to decide "does this template blob look like this component file", never
# to produce content that lands anywhere. Approximate is fine: a token form we
# miss costs one file's worth of signal out of hundreds, and the real
# materialization still goes through the CLI (see materialize.sh).
# COMP_NAME is resolved once at the top of the script — both arms need it.
COMP_MODULE=$(awk '$1 == "module" { print $2; exit }' go.mod 2>/dev/null || echo "")
# The template's own module path, read off its go.mod at the scored tip: the
# facade template is `…/kairos-component-facade-template`, and a hard-coded
# component-template path left every facade import unsubstituted.
TPL_MODULE=$(git -C "$CACHE" show "$BRANCH:go.mod" 2>/dev/null | awk '$1 == "module" { print $2; exit }')
[[ -n "$TPL_MODULE" ]] || TPL_MODULE=bitbucket.org/ifs-pd/kairos-component-template

esc()     { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's|/|\\/|g' -e 's/&/\\&/g'; }
esc_pat() { printf '%s' "$1" | sed -e 's/[][\.*^$/]/\\&/g'; }

SUBST="$WS/subst.sed"
{
  # Bracketed forms first — the bare form would otherwise leave a stray "<name>".
  printf 's/%s/%s/g\n' "$(esc_pat '<YOUR_COMPONENT_NAME>')" "$(esc "$COMP_NAME")"
  printf 's/%s/%s/g\n' "$(esc_pat '<YOUR_BC_NAME>')"        "$(esc "$COMP_NAME")"
  printf 's/%s/%s/g\n' "$(esc_pat 'YOUR_COMPONENT_NAME')"   "$(esc "$COMP_NAME")"
  [[ -n "$COMP_MODULE" ]] && \
    printf 's/%s/%s/g\n' "$(esc_pat "$TPL_MODULE")" "$(esc "$COMP_MODULE")"
} > "$SUBST"

# --- shared file set: present in BOTH template tip and component ---------------
# The ls-tree stream is NUL-delimited (read -r -d '') so a path can never be
# confused with a record boundary — but SHARED is re-emitted NEWLINE-delimited,
# because both consumers below (the COMPH hashing loop and the per-commit
# stream-join awk keyed on `want[$0]`) read it line-wise. A path carrying a
# newline would otherwise land as two half-lines: two junk comp[] keys, an
# inflated N_WIDESCAN_FILES, and `git hash-object < <half-path>` noise on stderr.
# So it is dropped HERE with a diagnostic — the SAME choice the per-commit stream
# loop below makes for a TAB/newline path — rather than mis-emitted. (A TAB is
# dropped too: SHARED is single-column so a TAB is harmless in it, but keeping the
# two exclusion sets identical is what makes the want[]/stream join total.)
SHARED="$WS/shared.txt"
SHARED_BAD="$WS/shared-badnames.txt"; : > "$SHARED_BAD"
while IFS= read -r -d '' p; do
  case "$p" in
    *$'\t'*|*$'\n'*) printf '%q\n' "$p" >> "$SHARED_BAD"; continue ;;
  esac
  [[ -f "$p" ]] && printf '%s\n' "$p"
done < <(git -C "$CACHE" ls-tree -r -z --name-only "$BRANCH") > "$SHARED"
if [[ -s "$SHARED_BAD" ]]; then
  echo "WARN: wide scan skipped component path(s) whose name carries a TAB or newline (no score row can be attached for them):" >&2
  sed 's/^/        /' "$SHARED_BAD" >&2
fi
N_WIDESCAN_FILES=$(grep -c . "$SHARED" || true)

if [[ "${N_WIDESCAN_FILES:-0}" -eq 0 ]]; then
  echo "WARN: wide scan found no files shared between template tip and component" >&2
  echo "WIDESCAN=ran"
  echo "N_WIDESCAN_FILES=0"
  exit 0
fi

# --- component side: hash each shared file once (LF-normalized) ----------------
COMPH="$WS/comp-hashes.tsv"
while IFS= read -r p; do
  # `git hash-object` rather than shasum/sha1sum: git is already a hard
  # dependency of this skill, whereas shasum is a perl script absent from
  # minimal Linux images and sha1sum is absent from macOS. Any stable content
  # hash works here — these values are only ever compared against each other.
  h=$(tr -d '\r' < "$p" | git hash-object --stdin)
  printf 'C\t%s\t%s\n' "$p" "$h"
done < "$SHARED" > "$COMPH"

# --- candidate commits: same 500-most-recent cap as the bellwether scan --------
WCANDS=$(git -C "$CACHE" log -500 --pretty=format:%H "$BRANCH")
N_WIDESCAN_COMMITS=$(printf '%s\n' "$WCANDS" | grep -c . || true)

# --- (sha, blob, path) stream --------------------------------------------------
# One `ls-tree` per commit gives every shared path's blob SHA at that commit
# without ever reading a blob. Blob content is touched only in the dedup pass
# below, so cost scales with UNIQUE blobs, not files x commits.
#
# NUL-delimited in, via `read -r -d ''` — NOT `tr '\0' '\n'` piped straight into
# awk. -z is the only reason a path can never be confused with a record
# boundary; `tr` throws that guarantee away by turning the true NUL terminator
# into the very byte a path may already carry (a component file with a literal
# newline in its name), which then reads to awk as two bogus half-records
# instead of one real one. The SHARED-file loop above reads the equivalent
# `--name-only -z` stream the safe way; this loop now matches it. A path that
# itself carries a TAB or newline still can't ride this script's TAB-delimited
# rows either way, so — same choice build-manifest.sh's z_name_status makes —
# it is dropped with a diagnostic rather than silently misaligning a
# neighboring row.
STREAM="$WS/stream.tsv"
: > "$STREAM"
BADNAMES="$WS/widescan-badnames.txt"; : > "$BADNAMES"
ONE="$WS/.ls-tree-one.tsv"
for SHA in $WCANDS; do
  : > "$ONE"
  while IFS= read -r -d '' entry; do
    meta=${entry%%$'\t'*}
    path=${entry#*$'\t'}
    case "$path" in
      *$'\t'*|*$'\n'*) printf '%q\n' "$path" >> "$BADNAMES"; continue ;;
    esac
    type=${meta#* }; type=${type%% *}
    [[ "$type" = blob ]] || continue
    obj=${meta##* }
    printf '%s\t%s\n' "$obj" "$path" >> "$ONE"
  done < <(git -C "$CACHE" ls-tree -r -z "$SHA")
  awk -F'\t' -v sha="$SHA" '
      NR == FNR { want[$0] = 1; next }
      ($2 in want) { print "S\t" sha "\t" $1 "\t" $2 }
    ' "$SHARED" "$ONE" >> "$STREAM"
done
rm -f "$ONE"
if [[ -s "$BADNAMES" ]]; then
  echo "WARN: wide scan skipped path(s) whose name carries a TAB or newline (no score row can be attached for them):" >&2
  sed 's/^/        /' "$BADNAMES" >&2
fi

# --- substituted-blob-hash cache, keyed by git blob SHA ------------------------
# Persisted across runs and invalidated whenever the substitution map changes
# (its own hash is the stamp) — a blob SHA identifies content exactly, so the
# same blob can never need re-substituting under an unchanged map.
BLOBCACHE="$RUN/widescan-blobcache.tsv"
BCSTAMP="$RUN/.widescan-blobcache-stamp"
SUBST_SIG=$(git hash-object --stdin < "$SUBST")
if [[ ! -f "$BLOBCACHE" ]] || [[ ! -f "$BCSTAMP" ]] || [[ "$(cat "$BCSTAMP")" != "$SUBST_SIG" ]]; then
  : > "$BLOBCACHE"; printf '%s' "$SUBST_SIG" > "$BCSTAMP"
fi
awk -F'\t' '{ print $3 }' "$STREAM" | sort -u > "$WS/blobs.txt"
# Load the cache with getline in BEGIN, NOT the usual `NR == FNR` two-file idiom.
# On the very first run the cache file is EMPTY, and with an empty first file FNR
# never advances for it, so NR == FNR stays true for every record of the SECOND
# file — the idiom then swallows the entire blob list as "already cached", hashes
# nothing, and every commit scores 0. Silent, total, and only visible as a
# uniformly zero score. getline is immune to the file being empty.
awk -v cache="$BLOBCACHE" '
    BEGIN { while ((getline line < cache) > 0) { split(line, a, "\t"); have[a[1]] = 1 } }
    !($0 in have)
  ' "$WS/blobs.txt" > "$WS/blobs-new.txt"
while IFS= read -r b; do
  h=$(git -C "$CACHE" cat-file blob "$b" | tr -d '\r' | LC_ALL=C sed -f "$SUBST" | git hash-object --stdin)
  printf '%s\t%s\n' "$b" "$h"
done < "$WS/blobs-new.txt" >> "$BLOBCACHE"

# --- score every candidate commit in one pass ----------------------------------
MATCHED="$WS/matched.tsv"      # sha <TAB> path, for paths that matched
FILESTAT="$WS/filestat.tsv"    # path <TAB> times-matched <TAB> times-present
: > "$MATCHED"; : > "$FILESTAT"
cat "$COMPH" \
    <(awk -F'\t' '{ printf "B\t%s\t%s\n", $1, $2 }' "$BLOBCACHE") \
    "$STREAM" \
  | awk -F'\t' -v matched="$MATCHED" -v filestat="$FILESTAT" '
      $1 == "C" { comp[$2] = $3; next }
      $1 == "B" { bh[$2]   = $3; next }
      $1 == "S" {
        sha = $2; blob = $3; p = $4
        if (!(sha in seen)) { seen[sha] = 1; order[++n] = sha }
        tot[sha]++; present[p]++
        if (comp[p] != "" && bh[blob] == comp[p]) {
          mm[sha]++; fm[p]++; print sha "\t" p > matched
        }
      }
      END {
        # git-log order is preserved so the stable sort below still means recency
        for (i = 1; i <= n; i++) { s = order[i]; printf "%d %d %s\n", mm[s] + 0, tot[s], s }
        for (p in present) print p "\t" (fm[p] + 0) "\t" present[p] > filestat
      }
    ' > "$WS/raw-scores.txt"

# Identical ranking rule to the bellwether scan: ratio, then total, then recency.
awk '{ printf "%d %s\n", ($1 * 10000) / $2, $0 }' "$WS/raw-scores.txt" \
  | sort -s -k1,1nr -k3,3nr \
  | cut -d' ' -f2- > "$RUN/widescan-scores.txt"

head -5 "$RUN/widescan-scores.txt" | while read -r m t sha; do
  echo "$m/$t $sha $(git -C "$CACHE" log -1 --pretty=%s "$sha")"
done > "$RUN/widescan-top.txt"

# --- bellwether suggestions ----------------------------------------------------
# A file only carries signal if it matched at the peak commit AND failed to match
# at some other scored commit. Files identical across all of history (present
# everywhere, matched everywhere) are exactly the useless five-way-tie
# bellwethers this fallback exists to replace, so they are excluded.
PEAK=""; WM=0; WT=0
if [[ -s "$RUN/widescan-scores.txt" ]]; then
  # shellcheck disable=SC2046
  set -- $(head -1 "$RUN/widescan-scores.txt"); WM=$1; WT=$2; PEAK=$3
fi

if [[ -n "$PEAK" ]] && [[ "$WM" -gt 0 ]]; then
  awk -F'\t' -v peak="$PEAK" '
      FILENAME == ARGV[1] { if ($1 == peak) atpeak[$2] = 1; next }
      { p = $1; matches = $2 + 0; present = $3 + 0
        if ((p in atpeak) && matches > 0 && present - matches > 0)
          printf "%d\t%d\t%s\n", present - matches, matches, p }
    ' "$MATCHED" "$FILESTAT" \
    | sort -t$'\t' -k1,1nr -k2,2nr > "$WS/sug-ranked.tsv"

  n=0
  while IFS=$'\t' read -r _nonmatch _matches p; do
    [[ "$n" -ge 15 ]] && break
    # Bellwether matching is byte-for-byte PRE-substitution (see the reference
    # doc), so a file carrying placeholder tokens could never match as a
    # bellwether however discriminating it looks here. Same reason README.md /
    # AGENTS.md are excluded: the doc forbids them outright.
    case "${p##*/}" in README.md|AGENTS.md) continue ;; esac
    if git -C "$CACHE" cat-file blob "$PEAK:$p" 2>/dev/null \
       | LC_ALL=C grep -qF -e 'YOUR_COMPONENT_NAME' -e 'YOUR_BC_NAME' -e "$TPL_MODULE"; then
      continue
    fi
    printf '%s\n' "$p"; n=$((n + 1))
  done < "$WS/sug-ranked.tsv" > "$RUN/bellwether-suggestions.txt"
fi

# --- report --------------------------------------------------------------------
echo "INFO: wide scan: $N_WIDESCAN_FILES shared files x $N_WIDESCAN_COMMITS commits;" \
     "$(grep -c . "$WS/blobs.txt" || true) unique blobs," \
     "$(grep -c . "$WS/blobs-new.txt" || true) hashed this run" >&2
echo "OK: wide-scan scores in $RUN/widescan-scores.txt, top candidates:" >&2
cat "$RUN/widescan-top.txt" >&2

WS_R1=-1; WS_R2=-2
[[ "$WT" -gt 0 ]] && WS_R1=$(ratio_of "$WM" "$WT")
WS_L2=$(sed -n 2p "$RUN/widescan-scores.txt")
if [[ -n "$WS_L2" ]]; then
  # shellcheck disable=SC2086
  set -- $WS_L2; WS_R2=$(ratio_of "$1" "$2")
fi
if [[ "$WM" -eq 0 ]]; then
  echo "WARN: wide scan found NO clear peak (no shared file matched any commit) —" \
       "treat as no signal and ask the user" >&2
elif [[ "$WS_R1" -eq "$WS_R2" ]]; then
  echo "WARN: wide scan signal is FLAT (top two commits tie at $WM/$WT) —" \
       "do not present this as confident; ask the user" >&2
fi
if [[ -s "$RUN/bellwether-suggestions.txt" ]]; then
  echo "INFO: $(grep -c . "$RUN/bellwether-suggestions.txt") discriminating files suggested" \
       "for .kairos-updates/bellwethers.txt in $RUN/bellwether-suggestions.txt" >&2
else
  echo "INFO: no discriminating files found — no bellwether suggestions" >&2
fi

echo "WIDESCAN=ran"
echo "N_WIDESCAN_FILES=$N_WIDESCAN_FILES"
