#!/usr/bin/env bash
# producer-idempotence.sh — run the tree's own producers and assert they leave
# tracked state clean.
#
# WHY: two merge-correctness defects share one root cause — a producer whose
# output drifted from its inputs.
#   * The merge landed generator INPUTS for a runtime the component keeps, but the
#     committed generated ARTIFACTS still hold their pre-merge content. Running the
#     regeneration command now MODIFIES a tracked file → the committed artifact was
#     stale. Disposition: a regeneration task whose acceptance is that a second run
#     produces no diff.
#   * The merge introduced a producer whose output is tracked rather than ignored,
#     so a binary rode along in the structural commit — or running the build now
#     EMITS an un-ignored file. Disposition: untrack it and add an ignore rule.
# Neither is visible to the build, the suite, or the YAML gate. Detection is by the
# tree's own reaction to its own commands, so it needs no knowledge of which
# artifacts a template generates, which symbols a generator emits, or where a
# runtime puts its binaries — the genericity the PRD requires.
#
# A producer the ENVIRONMENT blocks SKIPS, it does not fail: a generator may reach
# the network (module or tool fetches), the same environment gap the helm render
# handles as a skip. A skip escalates as incomplete coverage; it is never rounded
# up to a pass and never a hard block.
#
# The BUILD producer is SWEPT across every Go module rather than run at the
# component root only, because `go build ./...` compiles the module it runs in and
# nothing else: a root-only run never enters a sibling `go.mod` (`pkg/schema`,
# `web/entrypoint`), and a module carrying a single main package emits its binary
# INTO the module directory — which is exactly the untracked-output verdict this
# check exists to produce. It therefore goes through run-check-modules.sh, the same
# sweep every other build path in the skill uses; a non-`go` command and a
# single-root component delegate verbatim to run-check.sh, so their combined output
# and every verdict derived from it are unchanged.
#
# The REGENERATE producer stays at the component root: Phase 4.5 discovers the
# regeneration command root-scoped by construction, so there is no per-module
# command to sweep.
#
# The check runs on a COMMITTED tree (after the structural commit, and at the final
# gate). It restores anything a producer touched so the working tree is left exactly
# as found — the check must never itself dirty the state it is auditing. That holds
# even when the PRODUCER does not: a non-zero exit still takes the after-snapshot
# and still restores the delta, because a `make generate` that died half-way leaves
# debris that would otherwise ride into the next `git add -A`. Only the VERDICT
# differs — an environment gap stays a `skip`, any other non-zero exit is
# `producer-failed`, carrying the exit code and the tail of the producer's output;
# gate.sh maps that verdict to FAIL. A failed run's delta is debris, not evidence,
# so it is reported inside that row rather than as a dirty-tracked/untracked-output
# finding drawn from a run that never finished.
#
# Env in:  RUN        migration state dir (required)
#          LABEL      optional artifact suffix — "postmerge", "midplan" or "final",
#                     the gate label this run belongs to. gate.sh always sets it, so
#                     each label's verdict lands in its OWN file: the verdict is read
#                     back by phases/6-planning.md's follow-up derivation, which asks
#                     specifically about POSTMERGE, and one shared file made that
#                     question unanswerable (whichever label ran last overwrote it —
#                     a midplan gate silently redefined which acknowledgments the
#                     plan owed). Unset — a direct invocation outside a gate — keeps
#                     the base name.
#          BUILD_CMD  optional — overrides $RUN/test-command.txt line 3
#          REGEN_CMD  optional — overrides $RUN/test-command.txt line 4
# Cwd:     component root (a git repo)
# Out (in $RUN):
#   producer-idempotence.tsv   producer <TAB> verdict <TAB> detail
#     (-<LABEL> before .tsv      verdict: clean | dirty-tracked | untracked-output |
#      when LABEL is set)                 producer-failed | skip
#   producer-build.*           run-check-modules.sh's artifact set for the build
#                              producer (aggregated log, per-module logs and
#                              excerpts, producer-build.modules.tsv). $RUN is the
#                              state dir pre-flight puts in .git/info/exclude, so
#                              these never enter the git-status delta below.
# Exit:    0 = every producer clean, skipped, or producer-failed (a failed producer
#              is the build/test gate's finding, escalated from the VERDICT by
#              gate.sh — this check only owns the leave-as-found restore)
#          1 = at least one producer dirtied tracked state (a real finding), or the
#              check could not run at all (not a git tree, sweep runner missing)
set -u

: "${RUN:?FAIL: RUN not set}"
mkdir -p "$RUN"
# One file per gate label (see LABEL in the header). Two literal spellings rather
# than one composed name so each is greppable: the artifact lint that pairs a
# doc-referenced $RUN/<name> with the script that writes it matches on the literal.
if [[ -n "${LABEL:-}" ]]; then
  TSV="$RUN/producer-idempotence-$LABEL.tsv"
else
  TSV="$RUN/producer-idempotence.tsv"
fi
# Truncated up front, unconditionally: present-and-empty ("this label's producer
# check ran and audited nothing") must be distinguishable from absent ("it never
# ran"), which is the distinction followup-completeness.sh refuses on.
: > "$TSV"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "FAIL: not a git work tree" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
SWEEP="$HERE/run-check-modules.sh"
[[ -f "$SWEEP" ]] || { echo "FAIL: cannot find run-check-modules.sh beside $0" >&2; exit 1; }

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TSV"; }
# Collapses a producer's output into one detail cell. Every stage is pinned to
# LC_ALL=C because that output is not guaranteed valid UTF-8: BSD `tr` in a UTF-8
# locale ABORTS on the first invalid byte ("tr: Illegal byte sequence" onto the
# gate's stderr) and truncates the detail there, so the evidence a reader gets
# would depend on the ambient locale. Under C the whole thing is bytes: the cut
# budget is 300 bytes rather than 300 characters, which is the intended order of
# magnitude and is now the same everywhere.
oneline() { LC_ALL=C tr '\n\t' '  ' | LC_ALL=C sed 's/  */ /g; s/^ //; s/ $//' | LC_ALL=C cut -c1-300; }

CMDFILE="$RUN/test-command.txt"
# Lines are trimmed before validation (mirrors gate.sh): a whitespace-only line
# or a space-prefixed rejection comment (" # rejected: …" drifted onto line 3/4)
# must hit is_cmd's not-a-command arms below, not slip past them into eval —
# where a bare "   " or " # …" exits 0 doing nothing, leaves the git snapshot
# unchanged, and manufactures a vacuous "clean" out of a producer that never ran.
line() { { [[ -f "$CMDFILE" ]] && sed -n "${1}p" "$CMDFILE" || true; } | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# A recorded producer line may be the honest placeholder ("no build check" /
# "no regen command") or a `# rejected:` audit comment — neither is a command.
is_cmd() {
  case "$1" in
    ""|"no build check"|"no regen command"|"no tests detected"|\#*) return 1 ;;
    *) return 0 ;;
  esac
}

BUILD_CMD=${BUILD_CMD-$(line 3)}
REGEN_CMD=${REGEN_CMD-$(line 4)}

# Environment gap, not a defect: the producer reached the network, wanted a tool
# that isn't installed, or lacked credentials. Same class the helm render skips on.
#
# Four arms, and each one's shape is load-bearing. `skip` is the DANGEROUS
# direction — a real failure classified as an environment gap is a false green
# that never reaches the operator — so every arm below is written to need
# positive evidence of an environment, and anything genuinely ambiguous stays
# `producer-failed` (noisy-safe: the operator sees a FAIL and can override it; a
# silent skip is unrecoverable).
#
# TRANSPORT ARM — the markers no compiler and no test framework emits: a
# multi-word network/tooling phrase, or Go's `x509: ` error prefix (the colon is
# what makes it crypto/x509's own diagnostic rather than a path component like
# `crypto/x509parse.go`). These match ANYWHERE in the output, INCLUDING on a Go
# diagnostic line, because that is exactly where a module fetch reports itself:
# `main.go:5:2: example.com/x@v1: Get "https://…": dial tcp: … no such host`.
# The keyword arm below cannot afford that latitude; this one is specific enough
# to keep it.
#   * The not-found patterns are the SPECIFIC forms a missing tool or an
#     unfetchable module prints — `command not found` (the shell), `executable
#     file not found` (Go's os/exec, docker), `cannot find module` (the module
#     resolver, as in "cannot find module providing package …"). A bare
#     *"not found"*/*"cannot find"* glob is the same defect class as the numeric
#     one below: it matches ordinary post-merge output (`panic: value not found`,
#     `assert: item not found in cache`) and downgrades a blocking failure to a
#     skip. `cannot find package "x" in any of:` is deliberately NOT listed — in
#     module mode the go tool prints it for a package absent from the tree it was
#     told to build (a deleted directory, a wrong import path), which is exactly
#     the post-merge defect this check exists to block; a network-caused instance
#     always carries the transport diagnostic (`dial tcp`, `no such host`,
#     `i/o timeout`, proxy/TLS) that this arm already skips on.
#
# The two arms after it read the output MINUS its Go compiler/vet diagnostic
# lines (`<path>.go:<line>[:<col>]:`). A diagnostic line is the compiler talking
# about the component's own source, so it is a producer failure whatever words
# happen to sit in it — `internal/certificate.go:10:2: undefined: Foo` used to
# skip on a bare *certificate* substring, and so did four more shapes reproduced
# from real paths (`crypto/x509parse.go`, `api/unauthorized/handler.go`,
# `auth/credentials.go`, `open missing.go: No such file or directory`). Dropping
# those lines FIRST is what stops a filename from deciding a verdict.
#
# NO-SUCH-FILE ARM — `No such file` is an environment gap when the missing thing
# is a tool or a system path (`/usr/bin/env: node: No such file or directory`),
# and a producer failure when it is a source file of the component tree: a
# RELATIVE path ending in .go/.mod/.sum is the merge having deleted or moved
# something the build still wants, which must block.
#
# KEYWORD ARM — the single ambiguous words (certificate/credential/unauthorized/
# x509) skip only in keyword CONTEXT, which means all three of:
#   * not on a Go diagnostic line (dropped above);
#   * not inside a path-or-filename token — a whitespace token containing `/` or
#     carrying a `.<letter>` extension is a PATH, and a keyword in a path names a
#     file, not an environment (`api/unauthorized/handler.go`, `certificate.go`);
#   * the keyword's own WORD, not a fragment welded into a longer identifier
#     (`x509parse`, `CredentialStore`, `NotFoundError`) — the same whole-token
#     discipline the numeric arm applies to 401/403.
# Case is still EXACT, and the lowercase-only spellings are still deliberate:
# they catch a tool's own lowercase diagnostic ("x509: certificate signed by …",
# "error: unauthorized") while `Certificate has expired` from a test assertion
# stays blocking. Folding the input to lowercase first (a `tr` pass) would undo
# that AND truncate non-UTF-8 output on BSD tr; there is therefore no case
# folding of the input anywhere in this function, and where a real tool prints a
# capitalised form ("Unauthorized", "No such file"), that spelling is listed.
#
# NUMERIC ARM — 401/403 are matched as WHOLE tokens next to HTTP/auth context,
# via `LC_ALL=C grep -Eiq` on the RAW bytes: -i handles case without rewriting
# the input, and LC_ALL=C makes the match byte-safe, because producer output is
# not guaranteed valid UTF-8 (a compiler echoing a source byte, a linker dumping
# a symbol) and a multibyte-aware pass over it either truncates or errors — which
# would make the verdict depend on the ambient locale.
#   * A bare "*401*"/"*403*" glob matches a Go compile error naming a line number
#     ("x.go:401: undefined: foo"), a duration ("403ms", "0.403s") and any longer
#     number ("1401", "4013"), so the code must be a whole token: not preceded by
#     a digit or a dot, not followed by a digit or a letter.
#   * Context is required and must be ADJACENT (only quotes/space/`:`/`=`
#     between), which is what keeps `status.go:401:` and `TestStatus403` blocking
#     while `status: 401`, `status = 401`, `"status":401`, `status code 401`,
#     `response code: 401`, `returned error: 403`, `Error 403: forbidden`,
#     `returned 403`, `HTTP 403`, `HTTP/1.1 401`, `403 Forbidden` and npm's
#     `code E401` all skip. The separator is mandatory, so `TestStatus403` is not
#     `status 403`; `E401` needs npm's `code ` in front of it, so `FILE401` is not
#     a status either.
#   * A code with NO context at all counts only as a whole trimmed line — the
#     shape a curl/CI step that prints just its status code leaves — never
#     mid-line.
#   * It reads the FULL output, diagnostic lines included: a module fetch that
#     was refused prints `main.go:5:2: …: 401 Unauthorized`, and the paired
#     status phrase is already all the evidence a whole-token match needs.
# Getting this wrong in the tightening direction is not safe either: it leaves a
# maintainer without registry credentials a hard gate FAIL and no skip route.
is_env_gap() {
  # --- transport / missing-tool markers: anywhere in the output ---------------
  case "$1" in
    *"command not found"*|*"executable file not found"*|*"cannot find module"*|\
    *"no such host"*|*"connection refused"*|*"i/o timeout"*|*"dial tcp"*|\
    *"proxyconnect"*|*"TLS handshake"*|*"could not resolve"*|\
    *"network is unreachable"*|*"x509: "*)
      return 0 ;;
  esac

  # Everything the two ambiguous arms below look at, MINUS the Go compiler/vet
  # diagnostic lines. `|| true` because grep -v exits 1 when it drops them all.
  local PLAIN
  PLAIN=$(printf '%s\n' "$1" \
    | LC_ALL=C grep -Ev '(^|[[:space:]])[^[:space:]]+\.go:[0-9]+:' || true)

  # --- "No such file": a missing TOOL or system path, not a missing source ----
  if printf '%s\n' "$PLAIN" | LC_ALL=C grep -Fq 'No such file'; then
    printf '%s\n' "$PLAIN" | LC_ALL=C grep -F 'No such file' \
      | LC_ALL=C grep -Eq \
          '(^|[[:space:]])[^[:space:]/][^[:space:]]*\.(go|mod|sum)([^0-9A-Za-z]|$)' \
      || return 0
  fi

  # --- ambiguous keywords, in keyword context only ----------------------------
  # awk splits each surviving line into whitespace tokens and drops every token
  # that is a path or a filename (contains `/`, or carries a `.<letter>`
  # extension); grep then requires what is left to hold the keyword as a whole
  # word. Both stages are LC_ALL=C, like every other pass over producer output:
  # the bytes are not guaranteed valid UTF-8 and a multibyte-aware pass over them
  # either truncates or errors, which would make the verdict depend on the
  # ambient locale.
  if printf '%s\n' "$PLAIN" \
     | LC_ALL=C awk '{ for (i = 1; i <= NF; i++) if ($i !~ "/" && $i !~ "\\.[A-Za-z]") print $i }' \
     | LC_ALL=C grep -Eq \
         '(^|[^0-9A-Za-z_])(certificates?|credentials?|unauthorized|Unauthorized|x509)([^0-9A-Za-z_]|$)'
  then
    return 0
  fi

  # --- 401/403 as whole tokens next to HTTP/auth context ----------------------
  # Assembled from named parts, POSIX ERE only (no PCRE \b): TOK the code, LB/RB
  # its whole-token boundaries, Q an optional quote so a JSON/dict key matches
  # ("status":401 / 'status': 403), SEP the mandatory adjacent separator.
  local TOK='(401|403)' LB='(^|[^0-9.])' RB='([^0-9A-Za-z]|$)' \
        Q='["'"'"']?' SEP='([[:space:]]*[:=][[:space:]]*|[[:space:]]+)'
  printf '%s' "$1" | LC_ALL=C grep -Eiq \
    "${LB}${TOK}[[:space:]]*:?[[:space:]]*(unauthorized|forbidden)\
|https?(/[0-9.]+)?[[:space:]]+${TOK}${RB}\
|(status|code|error|response|returned)${Q}${SEP}e?${TOK}${RB}\
|^[[:space:]]*${TOK}[[:space:]]*\$"
}

# git status parsed from `--porcelain -z` into one "code<TAB>path<TAB>origpath"
# line per record, sorted under LC_ALL=C so a producer's delta is comm-able.
# -z (NUL-delimited) is what makes the parse exact: porcelain v1 without -z
# C-quotes paths carrying special characters and prints renames as one
# `R  old -> new` line — both of which a byte-offset `${line:3}` parse silently
# mangles, and a mangled path means the restore below MISSES a file the
# producer touched, violating the leave-the-tree-as-found contract. A
# rename/copy record carries its ORIGIN path as a second NUL-separated token;
# it lands in column 3 (empty for every other record). A path containing a
# literal tab or newline is beyond this line format — accepted.
snapshot() {
  local rec code path orig
  while IFS= read -r -d '' rec; do
    code=${rec:0:2}
    path=${rec:3}
    orig=""
    case "$code" in
      R*|C*) IFS= read -r -d '' orig || true ;;
    esac
    printf '%s\t%s\t%s\n' "$code" "$path" "$orig"
  done < <(git status --porcelain -z 2>/dev/null) | LC_ALL=C sort
}

# Runs one producer, reporting through three globals:
#   P_RC     the producer's exit status
#   P_OUT    its combined output — meaningful on the FAILURE path only, which is
#            the only path that reads it (a green build's log is worth neither the
#            decompression nor the memory)
#   P_WHERE  which module(s) did not come back OK, empty when unknown
#
# `build` goes through the multi-module sweep (see header). Its combined output is
# then the sweep's AGGREGATED log rather than eval's capture, which is what keeps
# is_env_gap working: a module that reached the network wrote its "dial tcp" into
# that log exactly as a root-only eval would have. `regenerate` — and any label
# other than build — is eval'd at the component root, unchanged.
exec_producer() { # exec_producer <label> <command>
  local label="$1" cmd="$2" stem
  P_OUT=""; P_WHERE=""
  if [[ "$label" != build ]]; then
    P_OUT=$(eval "$cmd" 2>&1); P_RC=$?
    return 0
  fi

  stem="$RUN/producer-build"
  rm -f -- "$stem".* 2>/dev/null || true   # never read a previous run's per-module artifacts
  # EXTRACTOR is scrubbed the way gate.sh scrubs BUILD_CMD/REGEN_CMD: an inherited
  # one would add a failure set and could flip the sweep's status to
  # EXTRACTOR_MISMATCH, neither of which this check has any use for.
  env -u EXTRACTOR CMD="$cmd" OUT="$stem" CHECK=build "$SWEEP" >/dev/null 2>&1
  P_RC=$?
  if [[ "$P_RC" -ne 0 ]]; then
    P_OUT=$(gzip -dc "$stem.txt.gz" 2>/dev/null || true)
    # Say so rather than emit a detail that trails off after the colon: run-check.sh
    # now subshells the recorded command so a literal `exit` can no longer kill the
    # runner before artifacts land, but an empty log stays possible (a command that
    # produced no output), and the skip must still name something the reader can go
    # look at.
    [[ -n "$P_OUT" ]] || P_OUT="(no output captured at $stem.txt.gz)"
    # Absent when the sweep did not apply (non-`go` command, or a single root
    # module) — that run is root-only by definition, so there is no module to name.
    [[ -f "$stem.modules.tsv" ]] \
      && P_WHERE=$(awk -F'\t' 'NF && $2 != "OK" { printf "%s ", $1 }' "$stem.modules.tsv" | oneline)
  fi
  return 0
}

run_producer() { # run_producer <label> <command>
  local label="$1" cmd="$2" before after delta where outcome detail
  before=$(snapshot)
  exec_producer "$label" "$cmd"
  after=$(snapshot)

  # A non-zero producer exit decides the VERDICT here and then falls through to the
  # classify-and-restore below: whatever a half-run producer emitted before dying is
  # debris the leave-as-found contract owns exactly as much as a completed run's
  # output. `outcome` empty = the producer ran.
  outcome=""; detail=""
  if [[ "$P_RC" -ne 0 ]]; then
    where=""
    [[ -n "$P_WHERE" ]] && where=" (module(s): $P_WHERE)"
    if is_env_gap "$P_OUT"; then
      outcome=skip
      detail="environment$where: $(printf '%s' "$P_OUT" | oneline)"
    else
      # A real non-zero exit is the build/test gate's problem, not idempotence's;
      # idempotence is not assessable from a failed run. Not a pass either:
      # gate.sh maps `producer-failed` to FAIL. Evidence is the output's TAIL —
      # a producer names its cause where it died, not where it started.
      outcome=producer-failed
      detail="producer exited $P_RC$where (see build/test gate): $(printf '%s' "$P_OUT" | tail -5 | oneline)"
    fi
  fi

  delta=$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^$' || true)
  if [[ -z "$delta" ]]; then
    if [[ -n "$outcome" ]]; then
      record "$label" "$outcome" "$detail"
    else
      record "$label" clean "producer left tracked state clean"
    fi
    return 0
  fi

  # Classify and restore. Untracked-new (`??`) is un-ignored output; anything else
  # is a modified/added/deleted/renamed TRACKED file, i.e. a stale committed
  # artifact. Restores are scoped to the delta paths only, so pre-existing
  # working-tree state outside the producer's footprint is never touched — the
  # sweep widened the paths that can appear here to every module's output, and
  # the before/after delta is the whole of what bounds the `rm -rf` below.
  local untracked="" tracked="" code path orig
  while IFS=$'\t' read -r code path orig; do
    [[ -n "$code" ]] || continue
    case "$code" in
      # `??` is un-ignored output. git porcelain reports a wholly-untracked
      # DIRECTORY as `?? gen-out/` (trailing slash, no per-file lines), which
      # `rm -f` cannot remove — leaving it to ride into the next `git add -A`.
      # `rm -rf` removes both a file and a directory subtree, honoring the
      # contract that the check restores anything a producer touched.
      '??') untracked="$untracked $path"; rm -rf -- "$path" 2>/dev/null || true ;;
      R*|C*)
        # A staged rename/copy: unstage both ends, drop the producer-created
        # destination, then restore each end that HEAD still tracks.
        tracked="$tracked $orig->$path"
        git reset -q -- "$orig" "$path" >/dev/null 2>&1 || true
        rm -rf -- "$path" 2>/dev/null || true
        git checkout -q -- "$orig" 2>/dev/null || true
        git checkout -q -- "$path" 2>/dev/null || true
        ;;
      *)
        # Unstage first (a no-op when nothing is staged): `checkout -- path`
        # restores from the INDEX, and a producer that staged its change would
        # otherwise have its stale content "restored" right back to the tree.
        tracked="$tracked $path"
        git reset -q -- "$path" >/dev/null 2>&1 || true
        git checkout -q -- "$path" 2>/dev/null || true
        ;;
    esac
  done <<EOF
$delta
EOF

  if [[ -n "$outcome" ]]; then
    # The producer never finished, so its delta is not an idempotence verdict —
    # it is debris, now restored. Name what was put back inside the failure row.
    record "$label" "$outcome" "$detail | restored:$(printf '%s' "$tracked $untracked" | oneline)"
    return 0
  fi

  local rc_finding=0
  if [[ -n "$tracked" ]]; then
    record "$label" dirty-tracked "modified tracked artifact(s):$(printf '%s' "$tracked" | oneline | sed 's/^/ /')"
    rc_finding=1
  fi
  if [[ -n "$untracked" ]]; then
    record "$label" untracked-output "emitted un-ignored file(s):$(printf '%s' "$untracked" | oneline | sed 's/^/ /')"
    rc_finding=1
  fi
  return $rc_finding
}

N_DIRTY=0 N_SKIP=0 N_CLEAN=0
for spec in "build:$BUILD_CMD" "regenerate:$REGEN_CMD"; do
  lbl=${spec%%:*}; cmd=${spec#*:}
  is_cmd "$cmd" || continue
  run_producer "$lbl" "$cmd" || N_DIRTY=$((N_DIRTY + 1))
done

# Tally from the TSV (a producer can log two rows — dirty-tracked AND untracked).
N_SKIP=$(awk -F'\t' '$2=="skip"{n++} END{print n+0}' "$TSV")
N_CLEAN=$(awk -F'\t' '$2=="clean"{n++} END{print n+0}' "$TSV")
N_TRACKED=$(awk -F'\t' '$2=="dirty-tracked"{n++} END{print n+0}' "$TSV")
N_UNTRACKED=$(awk -F'\t' '$2=="untracked-output"{n++} END{print n+0}' "$TSV")
N_FAILED=$(awk -F'\t' '$2=="producer-failed"{n++} END{print n+0}' "$TSV")

echo "OK: producer idempotence — clean:$N_CLEAN dirty-tracked:$N_TRACKED untracked-output:$N_UNTRACKED producer-failed:$N_FAILED skip:$N_SKIP" >&2
[[ "$N_SKIP" -gt 0 ]] && awk -F'\t' '$2=="skip"{print "  skip: " $1 " — " $3}' "$TSV" >&2
[[ "$N_FAILED" -gt 0 ]] && awk -F'\t' '$2=="producer-failed"{print "  producer-failed: " $1 " — " $3}' "$TSV" >&2
[[ $((N_TRACKED + N_UNTRACKED)) -gt 0 ]] && awk -F'\t' '$2=="dirty-tracked"||$2=="untracked-output"{print "  " $2 ": " $1 " — " $3}' "$TSV" >&2

[[ $((N_TRACKED + N_UNTRACKED)) -eq 0 ]]
