#!/usr/bin/env bash
# handoff-classify.sh — prints a read-time classification handoff card to
# stdout: bucket tallies, ready-to-run query.sh one-liners for ask-user / for-AI /
# orchestrator-inspected buckets, and pointers. Entering Phase 5, read THIS
# instead of `cat`-ing classification.tsv or re-deriving bucket state from
# earlier conversation.
#
# unknown-status gets its OWN card section, never the for-AI one: Phase 5 keeps
# it with the orchestrator as mechanical inspection (a git status the classifier
# doesn't route), and never dispatches it to a resolver — a card that filed it
# under "for-AI" would read as an instruction to dispatch it.
#
# Env in:  RUN  migration state dir (required)
# Reads (all optional — missing inputs degrade gracefully, never a hard failure):
#   $RUN/classification.tsv
#   $RUN/summary.txt
#   $RUN/query.sh
# Stdout:  the handoff card
# Exit:    0 (1 only if RUN is unset — the one hard failure; every missing INPUT
#          degrades gracefully per the Reads note above)
set -u

: "${RUN:?FAIL: RUN not set}"

bucket_count() {
  if [[ -f "$RUN/summary.txt" ]]; then
    # Sum every matching row rather than printing one line per match: a
    # summary.txt with two rows for the same bucket (a hand-edit, or a resumed
    # run whose tally got appended to rather than replaced) would otherwise
    # hand query_line() a multi-line "$n", its `-gt 0` test would error out
    # silently (2>/dev/null), and the whole bucket would vanish from the
    # handoff card instead of reporting its true total. classification.tsv's
    # own count below already aggregates the same way.
    awk -F'\t' -v b="$1" 'NF && $1 == b { n += $2 } END { print n+0 }' "$RUN/summary.txt"
    return
  fi
  if [[ -f "$RUN/classification.tsv" ]]; then
    awk -F'\t' -v b="$1" 'NF && $1 == b { n++ } END { print n+0 }' "$RUN/classification.tsv"
  fi
}

query_line() { # query_line <bucket>
  local n; n=$(bucket_count "$1")
  [[ -n "$n" ]] && [[ "$n" -gt 0 ]] 2>/dev/null || return 0
  if [[ -f "$RUN/query.sh" ]]; then
    printf '%s\t%s\t%s\n' "$1" "$n" "$RUN/query.sh $1"
  else
    printf '%s\t%s\n' "$1" "$n"
  fi
  return 0
}

{
  echo "# Classification handoff"
  echo
  echo "## Bucket tally"
  if [[ -f "$RUN/summary.txt" ]]; then
    awk -F'\t' '$1 !~ /^(component-side-moves|dir-rename-pairs|deleted-heavyweight-dirs)$/ && NF == 2' "$RUN/summary.txt"
  elif [[ -f "$RUN/classification.tsv" ]]; then
    awk -F'\t' 'NF && $1 !~ /^(component-side-moves|dir-rename-pairs|deleted-heavyweight-dirs)$/ { c[$1]++ }
      END { for (b in c) print b "\t" c[b] }' "$RUN/classification.tsv" | sort
  fi
  echo
  echo "## Ask-user buckets (batched decision)"
  for b in added-heavyweight-ask-user deleted-heavyweight-ask-user binary-for-user; do
    query_line "$b"
  done
  echo
  echo "## For-AI buckets (individual reasoning)"
  for b in modify-delete-for-ai renamed-with-mods-for-ai; do
    query_line "$b"
  done
  echo
  echo "## Orchestrator-inspected buckets (mechanical, never dispatched)"
  query_line unknown-status
  echo
  echo "## Pointers"
  [[ -f "$RUN/classification.tsv" ]] && echo "classification (post-mortem only): $RUN/classification.tsv"
  [[ -s "$RUN/deleted-heavyweight-dirs.txt" ]] && echo "deleted-heavyweight-dirs: $RUN/deleted-heavyweight-dirs.txt"
  [[ -s "$RUN/dir-rename-pairs.tsv" ]] && echo "dir-rename-pairs (inferred — eyeball them): $RUN/dir-rename-pairs.tsv"
  true
}
