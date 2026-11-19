#!/usr/bin/env bash
# yaml-gate.sh — catch the "merged cleanly but wrongly" class in YAML.
#
# WHY: a 3-way merge can swallow a values block or duplicate one. The result has
# no conflict markers, compiles (YAML isn't compiled), and leaves the test suite
# green — then Kubernetes rejects it, or a chart silently renders with a nil where
# a block used to be. Nothing else in this pipeline looks for that, so gate.sh
# runs this at every one of its labels: the postmerge gate (LABEL=postmerge),
# Phase 7's midplan gate (LABEL=midplan) and the final gate (LABEL=final).
#
# Four layers, each catching a different failure mode:
#   1. parse            — yq must accept every plain YAML file (deterministic)
#   2. duplicate keys   — bundled POSIX-awk scanner (deterministic, conservative)
#   3. helm render      — best effort; catches "valid YAML, broken semantics" in a
#                         chart (a template dereferences a block the merge nilled
#                         out). Skip-prone: it needs helm and fetched dependencies.
#   4. structural shape — deterministic; catches a clean merge that RE-PARENTED a
#                         block — a key that is top-level in the migration TARGET's
#                         own materialized tree but survives in the working tree
#                         ONLY nested under a different top-level mapping. Works on
#                         clean merges, needs no chart render. Its oracle is the
#                         target tree, so a template that renames/adds/removes a
#                         block is never false-failed by the migration that adopts
#                         it. No single layer is "the" semantic one: 3 covers
#                         template dereference and nilled blocks, 4 covers nesting
#                         and re-parenting, and neither alone is complete.
#
# CHART TEMPLATES ARE NOT YAML. A Helm chart's templates/ directory holds Go
# templates: `{{- if .Values.x }}` is not valid YAML and yq rightly rejects it.
# Parsing them would fail on EVERY file of EVERY real component — so templates/
# is excluded from layers 1 and 2 and covered by layer 3 instead. To keep the
# duplicate-key guarantee over chart templates (a duplicated `resources:` block
# is the motivating example, and it usually lives in a chart template), the
# duplicate-key scanner is re-run over helm's RENDERED output, where the
# conditionals are resolved and the result really is YAML.
#
# A VENDORED SUBCHART's templates/ tree is excluded on exactly the same grounds.
# `chart/charts/<sub>/templates/*.yaml` is Go-template text like any other
# template, and it is rendered through the PARENT's `helm template` in layer 3 —
# which is why the subchart's own Chart.yaml directory is dropped from $CHARTS
# below. Without the exclusion those files reached `yq e '.'` and produced a
# `parse` FAIL at every label, with no acknowledgment path ($ACK covers the
# buried-key layer only): a component that vendors its subcharts — the shape
# `helm dependency build` leaves behind — could not clear the gate at all. A
# subchart's plain YAML (its Chart.yaml, values.yaml) is still parsed and
# key-scanned; only the templates/ trees are out.
#
# Env in:  RUN         migration state dir (required)
#          LABEL       artifact suffix — "postmerge" (default), "midplan" or
#                      "final"; it names artifacts only, never what is scanned
#          FILES       optional newline-separated YAML paths; discovered if unset
#          CHART_DIR   optional explicit Helm chart dir (a trailing slash is
#                      normalized off); auto-detected if unset
#          SKILL_DIR   optional — where to find lib/*.awk
#          SYNTH       optional — synthetic repo (materialize.sh) holding the
#                      materialized TARGET tree; the shape layer's oracle. Unset or
#                      missing the target tag → shape layer reports a SKIP (it is a
#                      semantic layer, so its absence is a coverage gap, never a
#                      silent pass).
#          TARGET_TAG  optional — target tag in $SYNTH (default kairos-target)
#          ACK         optional — TSV (file <TAB> key <TAB> reason) acknowledging a
#                      buried-key finding as a deliberate demotion; a listed
#                      (file,key) with a non-empty reason is recorded as a SKIP
#                      (acknowledged) instead of a FAIL. Default $RUN/yaml-gate-ack.tsv.
# Cwd:     the run's gate cwd — the git toplevel (component root), or the
#          recorded frontend mount on a frontend run. Enforced by the cwd guard
#          below when FILES is unset (discovery mode); an explicit FILES list
#          makes the caller responsible for the cwd its paths resolve against.
# Out (in $RUN):
#   yaml-gate-<LABEL>.tsv   severity <TAB> file <TAB> kind <TAB> detail
#                           severity: fail | skip
#                           kind:     parse | duplicate-key | helm-render | buried-key
#                           A `skip` in the PARSE layer is a listed candidate that is
#                           not a regular file on disk: nothing parsed it, so it is
#                           reported as a coverage gap instead of being dropped from
#                           the tally.
#   yaml-gate-<LABEL>.txt   short human-readable report to relay to the user
# Exit:    0 = gate passed (any SKIP — helm, shape or an unscannable candidate —
#              does not fail the gate)
#          1 = at least one parse / duplicate-key / helm-render / buried-key
#              FAILURE, or file discovery itself failed (a `git ls-files` that
#              FAILS is a parse-layer fail row and exit 1 — never an empty file
#              list scanned to a clean verdict). Layers 1/2/4 are deterministic
#              (not best-effort like layer 3's helm render), so a bundled awk
#              scanner (lib/yaml-dupkeys.awk, lib/yaml-toplevel.awk) that
#              itself fails to run — a bad `awk` on PATH, an unreadable or
#              corrupted lib file — is ALSO a fail row (duplicate-key or
#              buried-key, naming the scanner and its exit status), never a
#              silent "no findings": that scanner's exit status and stderr are
#              always checked, never discarded
set -u

[[ -n "${RUN:-}" ]] || { echo "FAIL: RUN not set" >&2; exit 1; }
LABEL=${LABEL:-postmerge}
HERE=$(cd "$(dirname "$0")" && pwd)
DUPKEYS="$HERE/lib/yaml-dupkeys.awk"
[[ -f "$DUPKEYS" ]] || DUPKEYS="${SKILL_DIR:-$HERE/..}/scripts/lib/yaml-dupkeys.awk"
[[ -f "$DUPKEYS" ]] || { echo "FAIL: cannot find lib/yaml-dupkeys.awk" >&2; exit 1; }
TOPLEVEL="$HERE/lib/yaml-toplevel.awk"
[[ -f "$TOPLEVEL" ]] || TOPLEVEL="${SKILL_DIR:-$HERE/..}/scripts/lib/yaml-toplevel.awk"
[[ -f "$TOPLEVEL" ]] || { echo "FAIL: cannot find lib/yaml-toplevel.awk" >&2; exit 1; }
TARGET_TAG=${TARGET_TAG:-kairos-target}
ACK=${ACK:-$RUN/yaml-gate-ack.tsv}

TSV="$RUN/yaml-gate-$LABEL.tsv"
TXT="$RUN/yaml-gate-$LABEL.txt"
mkdir -p "$RUN"
: > "$TSV"
: > "$TXT"

# The FILE column goes through oneline() (defined below; it is only called at
# invocation time). A path may legally carry a newline or a tab — git tracks such a
# path, which is why every listing here is `-z` — and writing one raw would split
# ONE finding across two physical TSV rows: gate.sh counts rows by severity, so the
# tail row would land on its unrecognized-severity arm and the card would read
# "gate-internal" instead of naming the finding. The other three columns are
# script-authored or already collapsed by the caller.
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$(printf '%s' "$2" | oneline)" "$3" "$4" >> "$TSV"; }

# One line, no embedded tabs/newlines — these land in a TSV the orchestrator greps.
# Byte-identical to producer-idempotence.sh's and gate.sh's definitions; the three
# are bound by a skill-lint check, so edit them together or not at all. Every
# stage is pinned to LC_ALL=C because what this collapses (git's stderr, a parser
# error quoting file bytes, an operator-authored ack reason) is not guaranteed
# valid UTF-8: BSD `tr` in a UTF-8 locale ABORTS on the first invalid byte ("tr:
# Illegal byte sequence" onto the gate's stderr) and truncates the detail there,
# so the evidence the operator reads would depend on the ambient locale. Under C
# the whole thing is bytes: the cut budget is 300 bytes rather than 300
# characters, which is the intended order of magnitude and is now the same
# everywhere.
oneline() { LC_ALL=C tr '\n\t' '  ' | LC_ALL=C sed 's/  */ /g; s/^ //; s/ $//' | LC_ALL=C cut -c1-300; }

# Every YAML path this gate scans is caller- or git-supplied (git ls-files, the
# FILES env, an ACK row): a legal filename that BEGINS with `-` (`-dash.yaml`) is a
# positional file operand, but yq and awk read it as an OPTION. Unanchored it is a
# defect at every layer — `yq e '.' -dash.yaml` fails with "unknown shorthand flag"
# (an un-acknowledgeable hard parse FAIL; $ACK covers the buried-key layer only),
# and `awk -f prog.awk -dash.yaml` treats `-d…` as a debug switch: on BSD awk it
# exits 0 dumping the 44KB ENVIRON symbol table (env secrets included) into the $RUN
# scratch file with zero data rows — the duplicate-key and buried-key layers read
# that back as a silent clean. So every file operand handed to yq/awk is anchored
# through anchor() (the spelling structural-merge.sh uses everywhere): a leading-dash
# path reaches the tool as `./-dash.yaml`, a plain operand, never a flag.
anchor() { case "$1" in /*|./*) printf '%s\n' "$1" ;; *) printf './%s\n' "$1" ;; esac; }

# --- cwd guard (discovery mode only) -------------------------------------------
# The cwd IS this gate's parameter (reference/gates.md → The gate cwd): the git
# toplevel on a template run, the run's recorded frontend mount on a frontend run
# — those two and nothing else. Chart detection and file discovery below are both
# cwd-relative, so an ACCIDENTAL subdir invocation scans a subtree and certifies
# it clean while the tree above it goes unscanned — a wrong cwd looks precisely
# like a tree with nothing to find. The deliberate non-root cwd is DERIVED, not
# announced: a frontend run's anchor records FRONTEND_MOUNT (materialize-frontend.sh,
# Phase 2.5) before any gate runs, and gate.sh hands this script the same $RUN, so
# the sanctioned mount is readable right here. Refused as a parse-layer fail row —
# the same shape as a failed listing (see the header's exit contract: an
# infrastructure failure is never a silent clean verdict). Scoped to discovery
# mode: an explicit FILES list names the scan set, making the caller responsible
# for where its relative paths resolve; and scoped to inside-a-git-tree — a cwd
# outside any repo keeps its existing, pinned "git ls-files failed" fail row.
if [[ -z "${FILES:-}" ]]; then
  GIT_TOP=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$GIT_TOP" ]]; then
    CWD_P=$(pwd -P)
    TOP_P=$(cd "$GIT_TOP" 2>/dev/null && pwd -P || true)
    if [[ -n "$TOP_P" ]] && [[ "$CWD_P" != "$TOP_P" ]]; then
      FMOUNT=$(sed -n 's/^FRONTEND_MOUNT=//p' "$RUN/context.env" 2>/dev/null | tail -1)
      MOUNT_P=""
      [[ -n "$FMOUNT" ]] && MOUNT_P=$(cd "$TOP_P/$FMOUNT" 2>/dev/null && pwd -P || true)
      if [[ -z "$MOUNT_P" ]] || [[ "$CWD_P" != "$MOUNT_P" ]]; then
        record fail . parse "wrong gate cwd: $CWD_P is neither the git toplevel ($TOP_P) nor the run's recorded frontend mount (${FMOUNT:-none recorded}) — discovery is cwd-relative, so scanning here would certify a subtree clean while the tree above it goes unscanned; cd to the component root (or the frontend mount, on a frontend run) and re-run"
        printf 'refused: wrong gate cwd %s — see the parse fail row in %s\n' "$CWD_P" "$TSV" >> "$TXT"
        echo "FAIL: yaml-gate: wrong cwd $CWD_P (toplevel: $TOP_P, recorded mount: ${FMOUNT:-none})" >&2
        exit 1
      fi
    fi
  fi
fi

# --- chart detection (must precede file discovery, which excludes templates/) --
# Components put the chart at chart/ or charts/ depending on template vintage, so
# search rather than hardcode — but exclude a chart's own charts/ subdirectory,
# which holds vendored SUBcharts rendered as part of the parent, not separately.
# Because a subchart is therefore never a $CHARTS entry of its own, its templates/
# tree has to be excluded from layers 1/2/4 through the PARENT — see
# is_chart_template() below, and the vendored-subchart paragraph in the header.
if [[ -n "${CHART_DIR:-}" ]]; then
  # A trailing slash would make the templates/ prefix "chart//templates/", which
  # matches nothing — the chart's Go templates would leak into the parse layer.
  CHARTS=${CHART_DIR%/}
else
  CHARTS=$(find . -name Chart.yaml -not -path './.git/*' \
                  -not -path './.kairos/migration/state/*' \
                  -not -path '*/node_modules/*' 2>/dev/null \
             | sed 's|/Chart\.yaml$||; s|^\./||' \
             | grep -v '/charts/' | sort -u)
fi

# --- file discovery -----------------------------------------------------------
# Tracked files UNION untracked-but-not-ignored: a template YAML that just landed
# in this very merge is untracked at the post-merge gate, and skipping it would
# blind the gate to exactly the files it exists to check.
#
# A `git ls-files` that FAILS (cwd is not a repo, index corrupt) is not an empty
# tree: nothing was listed, so nothing is checked and every layer would report
# clean over a file set that was never built. So the listing runs with its exit
# status captured explicitly — never as the head of a pipeline whose status is a
# later stage's and whose stderr is discarded — and the filtering is a separate
# step over the records it wrote. A failure is a parse-layer fail row and exit 1,
# the gate's hardest verdict.
LIST="$RUN/.yaml-gate-files.$LABEL"

# is_chart_template <path> — true when the path lies in a chart's templates/ tree:
# the parent chart's own, or a VENDORED SUBCHART's (see the header). Prefix matching
# is a bash `case` with the chart dir QUOTED, which makes it literal — the chart
# directory may hold regex metacharacters (`a[b`) and backslashes (`a\tb`, a legal
# Unix filename), and both of the mechanisms this replaces mangled one of those: a
# grep -v ERE broke on the bracket, and `awk -v p=…` escape-processed the
# backslash. A quoted case pattern processes neither, and `*` spans `/`, so one
# pattern covers a subchart at any depth (`charts/a/charts/b/templates/…`).
is_chart_template() { # is_chart_template <path>
  local f="$1" c
  [[ -n "$CHARTS" ]] || return 1
  # Process substitution, not a pipe: `return` must land in this function, and the
  # loop must not be forked into a subshell (the pattern the helm loop below fixes
  # for its counters).
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    case "$f" in
      "$c"/templates/*|"$c"/charts/*/templates/*) return 0 ;;
    esac
  done < <(printf '%s\n' "$CHARTS")
  return 1
}

# The candidate set lives in an ARRAY; the on-disk $LIST is written FROM it and is
# now only the run-scoped record of what was listed (internal scratch, removed at
# the end — reference/state-files.md). It used to be the other way
# round — the list was built by `tr '\0' '\n' | grep … | sort -u` and both scan
# loops read it back — and a path containing an EMBEDDED NEWLINE (legal in git,
# which is why `-z` exists) became two lines, NEITHER of which names a file: both
# were dropped by the `[ -f ]` tests below while $N_FILES, computed from the list
# BEFORE either loop, still counted them. The report then affirmed coverage it did
# not have ("clean — 2 YAML file(s) parsed" over one file scanned), which is the
# one thing this gate may never do. So: git's NUL stream is consumed as such, the
# extension and prefix filters are bash `case` patterns over each record, and every
# count below is incremented INSIDE the loop that does the work.
YFILES=()
if [[ -n "${FILES:-}" ]]; then
  # $FILES is newline-separated by contract, so a path holding a newline cannot be
  # expressed here at all — nothing is lost by reading it line-wise. printf, not a
  # heredoc: printf does not escape-process its ARGUMENTS, so a backslash-bearing
  # path survives.
  while IFS= read -r yf; do
    [[ -n "$yf" ]] || continue
    is_chart_template "$yf" && continue
    YFILES+=("$yf")
  done < <(printf '%s\n' "$FILES")
else
  RAW="$RUN/.yaml-gate-raw.$LABEL"
  LSERR="$RUN/.yaml-gate-lserr.$LABEL"
  if ! git ls-files -z > "$RAW" 2> "$LSERR" \
     || ! git ls-files -z --others --exclude-standard >> "$RAW" 2> "$LSERR"; then
    GITERR=$(head -1 "$LSERR" 2>/dev/null | oneline)
    record fail "-" parse "git ls-files failed: ${GITERR:-<no stderr>} — the YAML file list was never built, so no file was checked"
    printf 'YAML file discovery failed:\n  git ls-files: %s\n' "${GITERR:-<no stderr>}" > "$TXT"
    rm -f "$RAW" "$LSERR"
    echo "FAIL: yaml gate ($LABEL) could not list files: ${GITERR:-git ls-files failed}" >&2
    exit 1
  fi
  while IFS= read -r -d '' yf; do
    [[ -n "$yf" ]] || continue
    case "$yf" in
      *.yaml|*.yml) : ;;
      *) continue ;;
    esac
    case "$yf" in
      .git/*|*/.git/*|node_modules/*|*/node_modules/*|vendor/*|*/vendor/*) continue ;;
      .kairos/migration/state/*) continue ;;
    esac
    is_chart_template "$yf" && continue
    YFILES+=("$yf")
  done < "$RAW"
  rm -f "$RAW" "$LSERR"
fi
# The record. Tracked and untracked-not-ignored are disjoint sets, each listed in
# git's own byte order, so dropping the `sort -u` (there is no NUL-safe sort on
# both BSD and GNU) costs neither stability nor de-duplication.
N_CAND=${#YFILES[@]}
if [[ "$N_CAND" -gt 0 ]]; then
  printf '%s\n' "${YFILES[@]}" > "$LIST"
else
  : > "$LIST"
fi

# --- layers 1 and 2 -----------------------------------------------------------
# N_SCANNED counts files this loop actually handed to yq; N_GONE and N_NOFILE
# account for the rest, so every candidate is reconciled and no count is taken
# from the list ahead of the work.
N_PARSE=0; N_DUP=0; N_SCANNED=0; N_GONE=0; N_NOFILE=0
DKOUT="$RUN/.yaml-gate-dupkeys-out.$LABEL"
DKERR="$RUN/.yaml-gate-dupkeys-err.$LABEL"
scan_dupkeys() { # scan_dupkeys <file-to-scan> <label-for-report>
  # awk's own exit status is checked and its stderr is kept, never discarded: a
  # dying scanner (a bad awk on PATH, an unreadable/corrupted $DUPKEYS) used to
  # run with stderr thrown to /dev/null and its status read only via the
  # `while ... done < <(...)` loop, which never sees the process-substitution
  # command's exit code at all — so a scanner that never opened the file read
  # back exactly like "no duplicate keys found". Layer 2 is documented as
  # deterministic, not best-effort (that's layer 3/helm's contract), so a
  # scanner that could not run gets the same treatment as a failed `git
  # ls-files`: a fail row, worded so the reader sees a scan that never ran
  # rather than a clean result, and it counts toward N_FAIL like any other
  # finding — silence from here must never be read as green.
  awk -f "$DUPKEYS" "$(anchor "$1")" > "$DKOUT" 2> "$DKERR"
  local dkrc=$?
  if [[ "$dkrc" -ne 0 ]]; then
    record fail "$2" duplicate-key "gate-internal: the duplicate-key scanner ($DUPKEYS) exited $dkrc — $(head -1 "$DKERR" | oneline) — this file was never scanned for duplicate keys, so this is not a clean result"
    N_DUP=$((N_DUP + 1))
    return
  fi
  while IFS=$'\t' read -r key first dup; do
    [[ -n "${key:-}" ]] || continue
    record fail "$2" duplicate-key "$key (lines $first, $dup)"
    N_DUP=$((N_DUP + 1))
  done < "$DKOUT"
}

for f in ${YFILES[@]+"${YFILES[@]}"}; do
  [[ -n "$f" ]] || continue
  if [[ ! -e "$f" ]]; then
    N_GONE=$((N_GONE + 1))       # deleted by the merge; nothing to check
    continue
  fi
  if [[ ! -f "$f" ]]; then
    # Listed as a YAML file, and it is something else on disk (a directory where a
    # file used to be, a device node). Nothing parsed it and nothing key-scanned
    # it, so it gets its OWN row rather than vanishing from the tally: a skip, in
    # the parse layer's vocabulary, which gate.sh reads as INCOMPLETE and
    # followup-completeness.sh turns into a mandatory acknowledgment.
    record skip "$f" parse "not a regular file on disk — never parsed or key-scanned, so this is not a clean result"
    N_NOFILE=$((N_NOFILE + 1))
    continue
  fi
  N_SCANNED=$((N_SCANNED + 1))
  if ! ERR=$(yq e '.' "$(anchor "$f")" 2>&1 >/dev/null); then
    record fail "$f" parse "$(printf '%s' "$ERR" | oneline)"
    N_PARSE=$((N_PARSE + 1))
    continue                     # a file that doesn't parse can't be key-scanned
  fi
  scan_dupkeys "$f" "$f"
done

# --- layer 3: best-effort helm render -----------------------------------------
# helm VALIDATES the release name it is handed before it renders anything
# (^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.…)*$, at most 53 characters), but a chart
# DIRECTORY is a Unix path: uppercase letters, underscores and leading dashes are
# all legal in it and none are legal in a release name. Handing helm the raw
# basename made it exit non-zero with "invalid release name" — which matches no
# environment keyword in the skip case below — so a perfectly healthy chart
# recorded a helm-render FAIL and blocked the migration on the directory's spelling.
# Nothing is installed here, so the name is cosmetic and correctness only requires
# that helm accept it; it is derived rather than passed through.
release_name() { # release_name <chart-dir> — a name helm will accept
  local n
  n=$(basename "$1" | LC_ALL=C tr 'A-Z' 'a-z' \
        | LC_ALL=C sed -e 's/[^a-z0-9]/-/g' -e 's/^-*//' -e 's/-*$//' \
        | cut -c1-53 | LC_ALL=C sed 's/-*$//')
  # An all-illegal directory name (or one that truncates to bare dashes) sanitizes
  # to nothing, and an empty release-name argument is itself rejected.
  [[ -n "$n" ]] || n=kairos-gate
  printf '%s' "$n"
}
N_HELM_FAIL=0; N_HELM_SKIP=0
if [[ -z "$CHARTS" ]]; then
  : # no chart in this component — layer 3 simply does not apply
elif ! command -v helm >/dev/null 2>&1; then
  record skip "$(printf '%s' "$CHARTS" | head -1)" helm-render "helm not on PATH"
  N_HELM_SKIP=$((N_HELM_SKIP + 1))
else
  RENDER="$RUN/.yaml-gate-render.$LABEL"
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    # No `helm dependency update` — that reaches the network. An unfetched pinned
    # dependency is an environment gap, reported as a skip, never a hard block.
    #
    # helm is invoked as a plain command, NOT inside `if HERR=$(...)`: a command
    # substitution reports the status of its LAST command, so tacking a `cat` of
    # the stderr file on the end would make every render look successful.
    if helm template "$(release_name "$c")" "$c" >"$RENDER" 2>"$RUN/.helm-err"; then
      # Rendered successfully: now the templates ARE YAML, so the duplicate-key
      # guarantee extends over them here rather than being lost with templates/.
      scan_dupkeys "$RENDER" "$c (rendered)"
      continue
    fi
    HERR=$(cat "$RUN/.helm-err" 2>/dev/null || true)
    # A bare *"not found"* glob is the same defect class producer-idempotence.sh's
    # is_env_gap documents for its own not-found handling: it matches ANY "not
    # found" substring, including a chart author's own `required "value not found
    # for x" .Values.x` template failure — which is a genuine render defect the
    # merge introduced (a value the target expects that the working values.yaml
    # no longer sets), not a missing-tool/missing-dependency environment gap. That
    # glob used to demote such a failure to a skip, so the FAIL was never seen.
    # Anchored instead to the shape helm's own dependency/chart resolver emits
    # ("chart ... not found in ... repository"/"... index") — the real
    # unfetched-dependency and unreachable-repo cases this arm exists for. When
    # unsure whether a "not found" is environment or defect, staying unmatched
    # here and falling to the FAIL arm below is the safe direction.
    case "$HERR" in
      *"found in Chart.yaml"*|*"missing in charts/"*|*dependenc*|*"no repository definition"*|\
      *chart*"not found in"*repositor*|*chart*"not found in"*index*|\
      *unauthorized*|*Unauthorized*|*401*|*403*|\
      *credential*|*"no such host"*|*"connection refused"*|*"i/o timeout"*|*"dial tcp"*)
        record skip "$c" helm-render "environment: $(printf '%s' "$HERR" | oneline)"
        N_HELM_SKIP=$((N_HELM_SKIP + 1))
        ;;
      *)
        record fail "$c" helm-render "$(printf '%s' "$HERR" | oneline)"
        N_HELM_FAIL=$((N_HELM_FAIL + 1))
        ;;
    esac
  # Process substitution, not a `<<EOF ... $CHARTS ... EOF` heredoc: this loop
  # updates N_HELM_FAIL/N_HELM_SKIP (and, via scan_dupkeys, N_DUP), which must
  # survive past the loop — a plain pipe (`printf ... | while ...`) would fork
  # the loop into a subshell and lose every one of those counters.
  done < <(printf '%s\n' "$CHARTS")
  rm -f "$RENDER" "$RUN/.helm-err"
fi

# --- layer 4: structural shape (buried top-level key) -------------------------
# Oracle: the materialized TARGET tree in $SYNTH. For every plain YAML file present
# in BOTH that tree and the working tree, a key that is TOP-LEVEL in the target
# file must not survive in the working file ONLY as a key nested beneath a
# DIFFERENT top-level mapping (a merge that re-parented it). Three properties keep
# this inside the gate's design rule (false positives are unacceptable):
#   - burial fails, absence does not — a key simply missing from the working tree
#     is a legitimate component choice; only present-but-demoted is the defect;
#   - renames pass automatically — a renamed key is top-level in the target and,
#     after a correct merge, top-level in the working tree; the old spelling is not
#     in the target and is never examined;
#   - one direction only — a key the working tree keeps top-level and the target
#     nests is ambiguous (component customization) and is not examined.
# Ambiguous top-level frames (multi-document, `<<:`-merged/anchored, flow root) are
# dropped by yaml-toplevel.awk rather than guessed. A deliberate demotion is the
# residual false positive and is overridable via $ACK.
N_SHAPE_FAIL=0; N_SHAPE_SKIP=0
if [[ -z "${SYNTH:-}" ]] || ! git -C "$SYNTH" rev-parse -q --verify "$TARGET_TAG" >/dev/null 2>&1; then
  # The target tree is the layer's only oracle. Without it the layer cannot run —
  # report a skip (it is a semantic layer, so this is a coverage gap that escalates
  # via handoff-structural.sh's skip count), never a silent pass.
  record skip "-" buried-key "no materialized target tree (\$SYNTH unset or missing $TARGET_TAG) — shape layer did not run"
  N_SHAPE_SKIP=$((N_SHAPE_SKIP + 1))
else
  SHTGT="$RUN/.yaml-shape-target.$LABEL"
  SHWRK="$RUN/.yaml-shape-working.$LABEL"
  SHERR="$RUN/.yaml-shape-err.$LABEL"
  ack_reason() { # ack_reason <file> <key> — prints the logged reason, or nothing
    [[ -f "$ACK" ]] || return 0
    # f/k travel through the ENVIRONMENT, never `awk -v`: -v assignment
    # escape-processes backslashes (and other C-style escapes), and a literal
    # backslash is legal in both a file path and a YAML key — `awk -v k="$2"`
    # would reach the program mangled and could never match its own ack row.
    # Same pattern as build-manifest.sh's rename_target().
    AR_F="$1" AR_K="$2" awk -F'\t' \
      '$1==ENVIRON["AR_F"] && $2==ENVIRON["AR_K"] && $3!="" { print $3; exit }' "$(anchor "$ACK")"
  }
  for f in ${YFILES[@]+"${YFILES[@]}"}; do
    [[ -n "$f" ]] || continue
    [[ -f "$f" ]] || continue                       # not in the working tree, or not a
                                                  # regular file — layer 1 recorded it
    git -C "$SYNTH" cat-file -e "$TARGET_TAG:$f" 2>/dev/null || continue  # not in target
    # yaml-toplevel.awk's own exit status is checked and its stderr kept, never
    # discarded: a dying scanner (bad awk on PATH, an unreadable/corrupted
    # $TOPLEVEL) used to run with stderr thrown to /dev/null and its status
    # never inspected at all, so a scan that never opened the file read back
    # identical to "no top-level keys, nothing buried" — extractor silence
    # wearing a clean result. Layer 4 is documented as deterministic, so a
    # scanner that could not run gets the same fail-row treatment as a failed
    # `git ls-files`, and it counts toward N_FAIL like any other finding.
    git -C "$SYNTH" show "$TARGET_TAG:$f" 2>/dev/null | awk -f "$TOPLEVEL" > "$SHTGT" 2> "$SHERR"
    SHTRC=$?
    if [[ "$SHTRC" -ne 0 ]]; then
      record fail "$f" buried-key "gate-internal: the shape scanner ($TOPLEVEL) exited $SHTRC on the target side — $(head -1 "$SHERR" | oneline) — this file was never scanned for buried keys, so this is not a clean result"
      N_SHAPE_FAIL=$((N_SHAPE_FAIL + 1))
      continue
    fi
    grep -q '^AMBIG' "$SHTGT" && continue         # target frame ambiguous — drop
    awk -f "$TOPLEVEL" "$(anchor "$f")" > "$SHWRK" 2> "$SHERR"
    SHWRC=$?
    if [[ "$SHWRC" -ne 0 ]]; then
      record fail "$f" buried-key "gate-internal: the shape scanner ($TOPLEVEL) exited $SHWRC on the working-tree side — $(head -1 "$SHERR" | oneline) — this file was never scanned for buried keys, so this is not a clean result"
      N_SHAPE_FAIL=$((N_SHAPE_FAIL + 1))
      continue
    fi
    grep -q '^AMBIG' "$SHWRK" && continue         # working frame ambiguous — drop
    # For each top-level key in the TARGET: buried iff it is NOT top-level in the
    # working tree but DOES appear nested there.
    while IFS=$'\t' read -r tkind tkey _; do
      [[ "$tkind" = TOP ]] || continue
      # tkey travels through the ENVIRONMENT for the same reason as ack_reason's
      # f/k above: a YAML key may legally contain a backslash, and `awk -v`
      # would escape-process it before the comparison ever runs.
      SHAPE_K="$tkey" awk -F'\t' \
        '$1=="TOP" && $2==ENVIRON["SHAPE_K"] { found=1 } END { exit !found }' "$SHWRK" && continue
      anc=$(SHAPE_K="$tkey" awk -F'\t' \
        '$1=="NEST" && $2==ENVIRON["SHAPE_K"] { print $3; exit }' "$SHWRK")
      [[ -n "$anc" ]] || continue                   # absent entirely — legitimate
      reason=$(ack_reason "$f" "$tkey")
      if [[ -n "$reason" ]]; then
        record skip "$f" buried-key "acknowledged deliberate demotion of '$tkey' (under '$anc'): $(printf '%s' "$reason" | oneline)"
        N_SHAPE_SKIP=$((N_SHAPE_SKIP + 1))
      else
        record fail "$f" buried-key "key '$tkey' is top-level in the target but survives only nested under '$anc' in the working tree"
        N_SHAPE_FAIL=$((N_SHAPE_FAIL + 1))
      fi
    done < "$SHTGT"
  done
  rm -f "$SHTGT" "$SHWRK" "$SHERR"
fi

rm -f "$LIST" "$DKOUT" "$DKERR"

# --- report -------------------------------------------------------------------
# Every number here is a count of work DONE: N_SCANNED is incremented inside the
# parse loop, never read off the candidate list, so "clean — N YAML file(s) parsed"
# can no longer name a file the gate never opened.
N_FAIL=$((N_PARSE + N_DUP + N_HELM_FAIL + N_SHAPE_FAIL))
N_SKIP_ANY=$((N_HELM_SKIP + N_SHAPE_SKIP + N_NOFILE))
{
  if [[ "$N_FAIL" -eq 0 ]] && [[ "$N_SKIP_ANY" -eq 0 ]]; then
    echo "clean — $N_SCANNED YAML file(s) parsed, no duplicate keys, no buried keys$([ -n "$CHARTS" ] && echo ", chart rendered")"
  else
    [[ "$N_PARSE" -gt 0 ]] && { echo "YAML parse failures:";  awk -F'\t' '$3=="parse"        {print "  " $2 ": " $4}' "$TSV"; }
    [[ "$N_DUP" -gt 0 ]]   && { echo "Duplicate YAML keys:";  awk -F'\t' '$3=="duplicate-key"{print "  " $2 ": " $4}' "$TSV"; }
    [[ "$N_SHAPE_FAIL" -gt 0 ]] && { echo "Buried top-level keys (config nested underneath a sibling):"; awk -F'\t' '$1=="fail" && $3=="buried-key" {print "  " $2 ": " $4}' "$TSV"; }
    [[ "$N_HELM_FAIL" -gt 0 ]] && { echo "Helm render failures:"; awk -F'\t' '$1=="fail" && $3=="helm-render" {print "  " $2 ": " $4}' "$TSV"; }
    [[ "$N_HELM_SKIP" -gt 0 ]] && { echo "Helm render SKIPPED (not a pass, not a block):"; awk -F'\t' '$1=="skip" && $3=="helm-render" {print "  " $2 ": " $4}' "$TSV"; }
    [[ "$N_SHAPE_SKIP" -gt 0 ]] && { echo "Shape layer SKIPPED / acknowledged (not full coverage):"; awk -F'\t' '$1=="skip" && $3=="buried-key" {print "  " $2 ": " $4}' "$TSV"; }
    [[ "$N_NOFILE" -gt 0 ]] && { echo "Listed YAML paths that are not regular files (never scanned, not full coverage):"; awk -F'\t' '$1=="skip" && $3=="parse" {print "  " $2 ": " $4}' "$TSV"; }
  fi
} > "$TXT"

echo "OK: yaml gate ($LABEL) checked $N_SCANNED plain YAML file(s)" >&2
echo "  parse failures:  $N_PARSE" >&2
echo "  duplicate keys:  $N_DUP" >&2
echo "  buried keys:     $N_SHAPE_FAIL" >&2
echo "  helm failures:   $N_HELM_FAIL" >&2
echo "  helm skips:      $N_HELM_SKIP" >&2
echo "  shape skips:     $N_SHAPE_SKIP" >&2
# Candidate reconciliation, so the numbers above are readable as coverage: listed,
# scanned, and the two ways a listed path holds nothing to scan.
echo "  listed:          $N_CAND (scanned $N_SCANNED, absent $N_GONE, not-a-file $N_NOFILE)" >&2
[[ "$N_FAIL" -gt 0 ]] && sed 's/^/  /' "$TXT" >&2

[[ "$N_FAIL" -eq 0 ]]
