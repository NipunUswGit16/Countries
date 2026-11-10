# yaml-toplevel.awk — emit top-level vs nested mapping keys for the shape gate.
#
# WHY this exists: a 3-way merge can splice a NEW top-level block into a
# declarative config file in a position that nests an existing sibling underneath
# it. The result has no conflict markers, parses as valid YAML, carries no
# duplicate keys, and leaves the suite green — but the buried block is silently
# inert at deploy time. yq, helm, and the build never see it. The shape layer of
# yaml-gate.sh catches it by comparing the working tree against the migration
# TARGET's own materialized tree; this scanner is the parser it drives.
#
# Usage:   awk -f yaml-toplevel.awk <one-yaml-file>
#          (POSIX awk — runs under macOS stock /usr/bin/awk. No gawk extensions.)
#
# OUTPUT CONTRACT — stdout, TAB-separated:
#   TOP  <TAB> <key>                    a mapping key at document top level (col 0)
#   NEST <TAB> <key> <TAB> <ancestor>   a mapping key nested under a top-level key
#   AMBIG <TAB> <reason>                the top-level frame cannot be read; emitted
#                                       once, then the scan STOPS and nothing else
#                                       is printed. The caller drops the file.
#   `key` and `ancestor` are NORMALIZED (surrounding matching quotes stripped),
#   so `"resources":` and `resources:` report identically. Exit status is always
#   0 — findings and AMBIG are on stdout, not in the status.
#
# DESIGN RULE (inherited from lib/yaml-dupkeys.awk): false positives are
# unacceptable, false negatives are fine. The shape gate must never flag a key it
# did not actually see at top level, so:
#   - Any column-0 line the scanner cannot confidently read as a mapping key —
#     a sequence root, a flow-collection root, a `<<:` merge at root, a
#     multi-document stream, tab indentation — emits AMBIG and the file is
#     DROPPED whole. A dropped file is a missed burial, never a false one.
#   - Deeper (col > 0) constructs the scanner cannot read only cost NEST
#     coverage for that subtree — again a missed burial, never a false one.
# Because every top-level key sits at column 0 where parsing is simplest, the TOP
# set is either complete or the file is dropped: there is no path that silently
# omits a real top-level key and then reports it as buried.
#
# The bail-out set, quote handling, block-scalar skipping, flow-collection
# opacity, comment stripping, and document-marker reset all mirror
# lib/yaml-dupkeys.awk — see that file's header for the per-construct rationale.

BEGIN { TAB = sprintf("\t"); in_block = 0; block_owner = 0; seen_top = 0; cur_top = "" }

function ltrim(t,   i, n) {
  n = length(t); i = 1
  while (i <= n && (substr(t, i, 1) == " " || substr(t, i, 1) == TAB)) i++
  return substr(t, i)
}

function rtrim(t,   n, c) {
  n = length(t)
  while (n > 0) { c = substr(t, n, 1); if (c == " " || c == TAB) n--; else break }
  return substr(t, 1, n)
}

# Emit AMBIG and stop the scan — the file has no unambiguous top-level frame.
function bail(reason) { printf "AMBIG\t%s\n", reason; exit }

# Cut a trailing comment, quote-aware. Returns t unchanged if there is none.
function strip_comment(t,   i, n, c, q, prev) {
  n = length(t); q = ""
  for (i = 1; i <= n; i++) {
    c = substr(t, i, 1)
    if (q == "") {
      if (c == "\"" || c == "'") { q = c; continue }
      if (c == "#") {
        prev = (i == 1) ? " " : substr(t, i - 1, 1)
        if (prev == " " || prev == TAB) return substr(t, 1, i - 1)
      }
    } else if (q == "\"") {
      if (c == "\\") { i++; continue }
      if (c == "\"") q = ""
    } else {
      if (c == "'") { if (substr(t, i + 1, 1) == "'") i++; else q = "" }
    }
  }
  return t
}

function last_token(t,   parts, n) {
  n = split(t, parts, " ")
  return (n > 0) ? parts[n] : ""
}

function is_block_scalar(v,   tok) {
  tok = last_token(v)
  return (tok ~ /^[|>][0-9]*[-+]?$/ || tok ~ /^[|>][-+]?[0-9]*$/)
}

function flow_balance(t,   i, n, c, q, d) {
  n = length(t); q = ""; d = 0
  for (i = 1; i <= n; i++) {
    c = substr(t, i, 1)
    if (q == "") {
      if (c == "\"" || c == "'") { q = c }
      else if (c == "{" || c == "[") d++
      else if (c == "}" || c == "]") d--
    } else if (q == "\"") {
      if (c == "\\") i++
      else if (c == "\"") q = ""
    } else {
      if (c == "'") { if (substr(t, i + 1, 1) == "'") i++; else q = "" }
    }
  }
  return d
}

# Parse `key:` at the start of s. Sets K_ok / K_key (normalized) / K_rest.
function parse_key(s,   n, i, c, ch, q, inner) {
  K_ok = 0; K_key = ""; K_rest = ""
  n = length(s)
  if (n == 0) return
  c = substr(s, 1, 1)

  if (c == "\"" || c == "'") {
    q = c; i = 2; inner = ""
    while (i <= n) {
      ch = substr(s, i, 1)
      if (q == "\"") {
        if (ch == "\\") { inner = inner substr(s, i + 1, 1); i += 2; continue }
        if (ch == "\"") break
      } else {
        if (ch == "'" && substr(s, i + 1, 1) == "'") { inner = inner "'"; i += 2; continue }
        if (ch == "'") break
      }
      inner = inner ch; i++
    }
    if (i > n) return                       # unterminated quote
    i++
    while (substr(s, i, 1) == " ") i++
    if (substr(s, i, 1) != ":") return
    ch = substr(s, i + 1, 1)
    if (ch != "" && ch != " " && ch != TAB) return
    K_key = inner; K_rest = ltrim(substr(s, i + 2)); K_ok = 1
    return
  }

  # `<<` (merge key) must parse so the caller can special-case it; every other
  # indicator-led plain scalar is not a mapping key.
  if (substr(s, 1, 2) != "<<" && index("?*&!|>#%@`,[]{}:", c) > 0) return

  i = 1
  while (i <= n) {
    if (substr(s, i, 1) == ":") {
      ch = substr(s, i + 1, 1)
      if (ch == "" || ch == " " || ch == TAB) break
    }
    i++
  }
  if (i > n) return
  K_key = rtrim(substr(s, 1, i - 1))
  if (K_key == "") return
  K_rest = ltrim(substr(s, i + 2))
  K_ok = 1
}

{
  line = $0
  sub(/\r$/, "", line)

  if (in_block) {
    if (line ~ /^[ \t]*$/) next
    bi = 0
    while (substr(line, bi + 1, 1) == " ") bi++
    if (bi > block_owner) next
    in_block = 0
  }

  if (line ~ /^[ \t]*$/) next
  if (line ~ /^[ ]*#/) next

  ind = 0
  while (substr(line, ind + 1, 1) == " ") ind++
  if (substr(line, ind + 1, 1) == TAB) bail("tab indentation")

  # Document markers. A separator after any top-level key means a second document
  # shares no frame with the first — the top-level set is no longer well-defined.
  if (line == "---" || line == "..." ||
      substr(line, 1, 4) == "--- " || substr(line, 1, 4) == "---" TAB ||
      substr(line, 1, 4) == "... " || substr(line, 1, 4) == "..." TAB) {
    if (seen_top) bail("multi-document stream")
    next
  }

  line = rtrim(strip_comment(line))
  if (line == "") next

  s = substr(line, ind + 1)
  col = ind

  while (1) {
    if (s == "-") { if (col == 0) bail("sequence at root"); s = ""; break }
    if (match(s, /^- +/)) {
      if (col == 0) bail("sequence at root")
      col += RLENGTH
      s = substr(s, RLENGTH + 1)
      continue
    }
    break
  }
  if (s == "") next

  c0 = substr(s, 1, 1)
  if (col == 0 && (c0 == "{" || c0 == "[")) bail("flow-collection root")

  parse_key(s)
  if (!K_ok) {
    if (col == 0) bail("unreadable top-level line")
    next                                    # deeper: drop this line only
  }

  if (col == 0) {
    if (K_key == "<<") bail("merge key at root")
    seen_top = 1
    cur_top = K_key
    printf "TOP\t%s\n", K_key
  } else if (K_key != "<<") {
    printf "NEST\t%s\t%s\n", K_key, cur_top
  }

  if (K_rest == "") next
  if (is_block_scalar(K_rest)) { in_block = 1; block_owner = col; next }
  c0 = substr(K_rest, 1, 1)
  if (c0 == "{" || c0 == "[") { if (flow_balance(K_rest) != 0) bail("multi-line flow") }
}
