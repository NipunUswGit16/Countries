# yaml-dupkeys.awk — detect duplicate mapping keys in a YAML file.
#
# WHY this exists: a 3-way merge can happily duplicate a whole YAML block (two
# `resources:` keys in one mapping, say). The file still parses, `yq` silently
# keeps the last value, no build and no test notices — and Kubernetes rejects
# the manifest at deploy time, long after the migration was declared done.
# Neither yq nor helm will tell us; this scanner does.
#
# Usage:   awk -f yaml-dupkeys.awk <one-yaml-file>
#          (POSIX awk — runs under macOS stock /usr/bin/awk. No gawk
#           extensions: no gensub, no asort, no true multidim arrays.)
#
# OUTPUT CONTRACT — stdout, one finding per line, three TAB-separated fields:
#     <key><TAB><first-line-number><TAB><duplicate-line-number>
#   `key` is the NORMALIZED key (surrounding matching quotes stripped), so
#   `"x": 1` and `x: 2` report as `x`. Line numbers are 1-based. One line per
#   duplicate occurrence: a key appearing three times yields two findings, both
#   pointing back at the same first line. NO OUTPUT = no duplicates found.
#   Exit status is always 0 — findings are on stdout, not in the status.
#
# DESIGN RULE: false positives are unacceptable, false negatives are fine.
# A spurious finding blocks a migration on a non-problem; a missed one only
# leaves us where we already were. So wherever this scanner cannot confidently
# interpret a construct it DROPS TRACKING for the affected mapping block (and
# everything nested under it) rather than guess. Tracking resumes at the next
# key it does understand.
#
# HOW IT DECIDES two keys are siblings: a key is identified by
# (indent column, generation, name). Every generation counter for a column is
# bumped whenever that column's mapping is known to have closed:
#   - a key appears at a shallower column  -> everything deeper closed
#   - a `- ` sequence indicator at column d -> everything deeper than d closed,
#     which is exactly what makes `- name: a` / `- name: b` two separate
#     mappings rather than a duplicate
#   - a document marker                    -> everything closed
#   - a bail-out                           -> that column and deeper dropped
#
# DELIBERATE BAIL-OUTS (each one is a possible false negative, never a false
# positive). "drop" = bump the generation for that column and every deeper
# column, so nothing recorded before is comparable to anything recorded after.
#
#   1. Block scalars. A value whose last token is `|`, `>`, `|-`, `|+`, `>-`,
#      `>+`, `|2`, `|-2`, `>2-` … opens opaque text: every following line
#      indented deeper than the OWNING KEY is skipped wholesale, so `key: value`
#      lines inside a shell script or a config blob are never parsed as YAML.
#      (Last-token matching is deliberate so `key: &anchor |` is caught too. It
#      also means a plain scalar that happens to end in `|` — `cmd: echo |` —
#      is misread as a block scalar. That only loses coverage, never adds a
#      false positive.)
#   2. Flow collections. A value starting with `{` or `[` is opaque; we never
#      descend into it, so `a: {b: 1, b: 2}` is not reported.
#   3. Multi-line flow collections. If a flow value's brackets do not balance
#      on its own line, the rest of the FILE is abandoned (exit). Tracking a
#      flow across lines is not worth the false-positive risk. Findings already
#      printed stand — they were decided before the ambiguity.
#   4. Tabs in indentation. Illegal YAML anyway and indentation becomes
#      meaningless to us: the rest of the file is abandoned (exit).
#   5. Any non-blank, non-comment line that is not `key:` / `"key":` / `'key':`
#      after sequence indicators are stripped — plain-scalar continuation
#      lines, `? explicit keys`, `*aliases`, bare `%YAML` directives, a lone
#      `[`, a scalar sequence item — drops the column it sits at and deeper.
#   6. Plain keys starting with an indicator character (`? * & ! | > # % @ , :`
#      backtick, brackets, braces, `-`) are not interpreted; they drop instead.
#   7. Unterminated quoted keys drop.
#   8. `<<:` merge keys are parsed but never recorded — they may legitimately
#      repeat in one mapping.
#   9. `---` and `...` at column 0 reset ALL state: a new document shares no
#      mapping with the previous one.
#  10. Comments: whole-line comments are ignored, and a trailing ` #` comment is
#      cut only when the `#` is outside quotes AND preceded by whitespace — so
#      `url: "http://h/#frag"` and `tag: a#b` keep their `#`.
#  11. Only *mapping* keys are compared. Sequence items, scalars and anything
#      inside them are not.

BEGIN { TAB = sprintf("\t"); in_block = 0; block_owner = 0; max_col = 0 }

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

# Generation of a column, forced numeric (unset reads as "").
function g(c) { return gen[c] + 0 }

# Everything nested deeper than column c has ended.
function close_deeper(c,   i) { for (i = c + 1; i <= max_col; i++) gen[i] = g(i) + 1 }

# Bail-out: stop comparing anything at column c or deeper.
function drop_from(c,   i) { for (i = c; i <= max_col; i++) gen[i] = g(i) + 1 }

function reset_all(   i) {
  for (i = 0; i <= max_col; i++) gen[i] = g(i) + 1
  in_block = 0
}

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
      # single-quoted: '' is an escaped quote, anything else ends the scalar
      if (c == "'") { if (substr(t, i + 1, 1) == "'") i++; else q = "" }
    }
  }
  return t
}

function last_token(t,   parts, n) {
  n = split(t, parts, " ")
  return (n > 0) ? parts[n] : ""
}

# `|`, `>` with optional indent digits and/or chomping indicator, in either order.
function is_block_scalar(v,   tok) {
  tok = last_token(v)
  return (tok ~ /^[|>][0-9]*[-+]?$/ || tok ~ /^[|>][-+]?[0-9]*$/)
}

# Net bracket depth of a flow value, ignoring brackets inside quotes.
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
    if (i > n) return                       # bail-out 7: unterminated quote
    i++                                     # step past the closing quote
    while (substr(s, i, 1) == " ") i++      # YAML tolerates `"a" : 1`
    if (substr(s, i, 1) != ":") return
    ch = substr(s, i + 1, 1)
    if (ch != "" && ch != " " && ch != TAB) return
    K_key = inner; K_rest = ltrim(substr(s, i + 2)); K_ok = 1
    return
  }

  # bail-out 6: plain scalars opening with an indicator character
  if (index("?*&!|>#%@`,[]{}:", c) > 0) return

  # The key ends at the first `:` that is followed by whitespace or EOL — a `:`
  # inside a plain scalar (`url: http://x`) is not a key separator.
  i = 1
  while (i <= n) {
    if (substr(s, i, 1) == ":") {
      ch = substr(s, i + 1, 1)
      if (ch == "" || ch == " " || ch == TAB) break
    }
    i++
  }
  if (i > n) return                         # bail-out 5: not a mapping entry
  K_key = rtrim(substr(s, 1, i - 1))
  if (K_key == "") return
  K_rest = ltrim(substr(s, i + 2))
  K_ok = 1
}

{
  line = $0
  sub(/\r$/, "", line)

  # --- block scalar body: opaque, anything deeper than the owner is skipped ---
  if (in_block) {
    if (line ~ /^[ \t]*$/) next                 # blank lines stay inside
    bi = 0
    while (substr(line, bi + 1, 1) == " ") bi++
    if (bi > block_owner) next
    in_block = 0                                # dedent ends the scalar
  }

  if (line ~ /^[ \t]*$/) next
  if (line ~ /^[ ]*#/) next                     # whole-line comment

  # bail-out 4: tab indentation makes columns meaningless
  ind = 0
  while (substr(line, ind + 1, 1) == " ") ind++
  if (substr(line, ind + 1, 1) == TAB) exit

  # bail-out 9: document boundaries reset everything
  if (line == "---" || line == "..." ||
      substr(line, 1, 4) == "--- " || substr(line, 1, 4) == "---" TAB ||
      substr(line, 1, 4) == "... " || substr(line, 1, 4) == "..." TAB) {
    reset_all(); next
  }

  line = rtrim(strip_comment(line))
  if (line == "") next

  s = substr(line, ind + 1)
  col = ind

  # --- sequence indicators: each `- ` opens a fresh mapping for that item ---
  while (1) {
    if (s == "-") { close_deeper(col); s = ""; break }
    if (match(s, /^- +/)) {
      close_deeper(col)                         # this dash ends deeper blocks…
      col += RLENGTH                            # …and the item mapping starts here
      s = substr(s, RLENGTH + 1)
      continue
    }
    break
  }
  if (s == "") next
  if (col > max_col) max_col = col

  parse_key(s)
  if (!K_ok) { drop_from(col); next }           # bail-outs 5/6/7

  close_deeper(col)

  if (K_key != "<<") {                          # bail-out 8: merge keys repeat
    slot = col SUBSEP g(col) SUBSEP K_key
    if (slot in first_line)
      printf "%s\t%d\t%d\n", K_key, first_line[slot], NR
    else
      first_line[slot] = NR
  }

  if (K_rest == "") next

  if (is_block_scalar(K_rest)) { in_block = 1; block_owner = col; next }

  c0 = substr(K_rest, 1, 1)
  if (c0 == "{" || c0 == "[") {
    # bail-out 2/3: flow collections are opaque; a multi-line one ends the scan
    if (flow_balance(K_rest) != 0) exit
  }
}
