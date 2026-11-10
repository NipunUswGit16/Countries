# snap-upgrade.sh — snapshot one upgrade-file body into $RUN/upgrades/.
# Sourceable helper. build-manifest.sh, collect-common.sh and collect-lib.sh
# keep this definition in one place (PRD story 42); each walk stays in its
# caller. Usage:
#   . "$HERE/lib/snap-upgrade.sh"
#   snap_upgrade <repo> <rev:path> <source-id> <basename>
#
# Closes over $RUN, $SNAP_SOURCES and $SNAP_REFUSALS — the caller owns those
# files and their prune/truncate policy. A failed git-show is a refusal (keep
# whatever good body is on disk, WARN, record a row, return 1); a successful
# read is a legitimate body EVEN IF EMPTY and is written as-is, because refusing
# an empty one made a genuinely zero-byte upgrade-file permanently unmigratable.
# Both call sites are `snap_upgrade … || true`: one unreadable body is a loud
# skip, not an aborted classification.

snap_upgrade() { # snap_upgrade <repo> <rev:path> <source-id> <basename>
  local repo="$1" spec="$2" src="$3" base="$4" dest="$RUN/upgrades/$4" tmp other rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/snap-upgrade.XXXXXX") || return 1
  git -C "$repo" show "$spec" > "$tmp" 2>/dev/null
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp"
    if [[ -s "$dest" ]]; then
      echo "WARN: refusing to overwrite $dest — the git read for $src failed (git show exited $rc); keeping the good snapshot" >&2
    else
      echo "WARN: no body captured for '$base' — the git read for $src failed (git show exited $rc)" >&2
    fi
    printf '%s\t%s\t%s\n' "${base%.md}" "$src" \
      "git show '$spec' failed (exited $rc) — the body could not be read" >> "$SNAP_REFUSALS"
    return 1
  fi
  if [[ -f "$dest" ]] && ! cmp -s "$tmp" "$dest"; then
    other=$(b="$base" s="$src" awk -F'\t' \
      '$1==ENVIRON["b"] && $2!=ENVIRON["s"] {print $2}' "$SNAP_SOURCES" 2>/dev/null | tail -1)
    [[ -n "$other" ]] \
      && echo "WARN: upgrade-file basename collision on '$base': snapshot from $src overwrites different content from $other" >&2
  fi
  # THE FINAL WRITE IS CHECKED, and its failure is the same refusal a failed read
  # is. It used to be a bare `mv` followed by an UNCONDITIONAL "captured" row, and
  # both call sites are `|| true`: an unwritable $RUN/upgrades (a permission
  # change, ENOSPC, a cross-device rename) therefore left the slug in
  # upgrades-added.txt with NO body, no refusal row, a sources row claiming the
  # body was captured, and exit 0. next-upgrade-file.sh then answered exit 4
  # ("never captured — re-run the phase") for a slug re-running cannot produce,
  # which is exactly the loop the exit-4/5 split exists to keep the planner out of.
  # mv's own stderr is left visible: its line names the reason (permissions, space,
  # device), the way git's does on the read path above.
  if ! mv "$tmp" "$dest"; then
    rm -f "$tmp"
    echo "WARN: no body stored for '$base' — the body was read but could not be written to $dest (mv failed); is $RUN/upgrades writable?" >&2
    printf '%s\t%s\t%s\n' "${base%.md}" "$src" \
      "the body was read but could not be written to $dest (mv failed) — check that $RUN/upgrades is writable and has space" >> "$SNAP_REFUSALS"
    return 1
  fi
  printf '%s\t%s\n' "$base" "$src" >> "$SNAP_SOURCES"
}
