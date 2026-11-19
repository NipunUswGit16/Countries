# z-log-name-only.sh — convert a `git log --name-only -z` stream into
# `sha <TAB> path` rows. Sourceable helper. build-manifest.sh, collect-common.sh
# and collect-lib.sh keep this definition in one place (PRD story 42); each walk
# stays in its caller. Usage:
#   . "$HERE/lib/z-log-name-only.sh"
#   z_log_name_only <badfile> [<strayfile>]  < stream  > rows
#
# RAW PATH BYTES via -z. `core.quotepath=off` is NOT enough and never was: it
# governs bytes >= 0x80 only, so an upgrade-file named `we"ird.md` or
# `back\slash.md` still arrived C-quoted and vanished from every collection
# walk. `-z` emits them verbatim, so they are COLLECTED, not refused.
#
# Parsing the -z stream: with `--pretty=format:'commit %H'` git glues the header
# to the commit's FIRST path in one record ("commit <sha>\n<path>"), emits the
# remaining paths as records of their own, and separates commits with an EMPTY
# record. The header cannot itself contain a newline, so splitting a header
# record at its FIRST newline is unambiguous.
#
# A RECORD THIS PARSER CANNOT ATTRIBUTE TO A COMMIT IS A REFUSAL, never a
# skipped line. The proven case is ambient `log.showSignature=true`: git writes
# the verifier's output to log's STDOUT ahead of the first record, so the
# record the header should have opened matches NEITHER arm and every migration
# step silently skipped. Every walk now passes --no-show-signature; this arm is
# defense in depth, and it is loud, because the failure it guards is invisible
# by construction.
#
# <strayfile> is OPTIONAL and defaults to <badfile>: collect-common.sh passes
# one argument and refuses on the badfile alone. Defaulting keeps a stray
# record a LOUD refusal there too — under a slightly less precise message —
# instead of making a one-arg call site a breaking change.
#
# TABCH / NLCH default here so a caller that has not set them still parses;
# a caller that already set them (build-manifest.sh, collect-common.sh) is
# unchanged.

TABCH=${TABCH:-$'\t'}
NLCH=${NLCH:-$'\n'}

z_log_name_only() { # z_log_name_only <badfile> [<strayfile>]  (stream on stdin, rows on stdout)
  local bad="$1" stray="${2:-$1}" rec sha="" p
  while IFS= read -r -d '' rec; do
    [[ -n "$rec" ]] || continue
    case "$rec" in
      "commit "[0-9a-f]*)
        p="${rec#*$NLCH}"
        if [[ "$p" = "$rec" ]]; then sha="${rec#commit }"; continue; fi   # header, no paths
        sha="${rec%%$NLCH*}"; sha="${sha#commit }" ;;
      *) p="$rec" ;;
    esac
    if [[ -z "$sha" ]]; then
      printf '%q\n' "$rec" >> "$stray"
      continue
    fi
    [[ -n "$p" ]] || continue
    case "$p" in
      *"$TABCH"*|*"$NLCH"*)
        printf '%q\n' "$p" >> "$bad"
        continue ;;
    esac
    printf '%s\t%s\n' "$sha" "$p"
  done
}
