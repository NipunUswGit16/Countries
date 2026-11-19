"""Side-by-side diff model for explain-diff-html.

Parses unified-diff hunks into aligned left/right rows (pairing, word ranges,
gap rows). Combined diffs and rename headers with content are out of scope.

Everything in here is pure stdlib and side-effect free: it turns spec input into
a JSON-serialisable payload that the page's JavaScript renders. Syntax
highlighting is deliberately *not* done here — Prism tokenises each side as one
document in the browser, so multi-line constructs (block comments, raw strings)
stay correct, and the highlighted output is then split per line.
"""

from __future__ import annotations

import difflib
import re
from typing import Any, Literal, Optional, Tuple

__all__ = ["build_diff_payload", "DiffError"]


class DiffError(ValueError):
    """Raised when a diff block cannot be built from its spec input."""


# kind, old line number (1-based) or None, new line number or None, text.
# Spelled with typing.Tuple because this alias is evaluated at import time and
# render.py still runs on the system Python 3.9.
Op = Tuple[str, Optional[int], Optional[int], str]

HUNK_RE = re.compile(r"^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@(.*)$")

# Word-ish tokens for intra-line highlighting: runs of word chars, runs of
# whitespace, or a single other character. Keeps punctuation changes visible
# without exploding every line into per-character noise.
TOKEN_RE = re.compile(r"\w+|\s+|.", re.UNICODE)

# Below this line similarity, a del/add pair is shown as two separate rows
# rather than one modified row: word highlighting on unrelated lines is noise.
PAIR_SIMILARITY_FLOOR = 0.3


def _split_lines(text: str) -> list[str]:
    if text == "":
        return []
    return text.replace("\r\n", "\n").rstrip("\n").split("\n")


def parse_unified(diff: str) -> list[Op]:
    """Parse a unified diff into a flat op list.

    Recognises ``@@`` hunk headers and +/-/space body lines. Lines outside a
    hunk (``diff --git``, ``index``, ``---``, ``+++``) are skipped, so a body
    line that legitimately starts with ``---`` is preserved. A ``gap`` op is
    emitted between hunks carrying the header's trailing context.
    """
    ops: list[Op] = []
    old_line = 0
    new_line = 0
    in_hunk = False
    seen_hunk = False

    for raw in diff.replace("\r\n", "\n").split("\n"):
        hunk = HUNK_RE.match(raw)
        if hunk:
            if seen_hunk:
                ops.append(("gap", None, None, (hunk.group(5) or "").strip()))
            old_line = int(hunk.group(1))
            new_line = int(hunk.group(3))
            in_hunk = True
            seen_hunk = True
            continue
        if raw.startswith("diff "):
            in_hunk = False
            continue
        if not in_hunk:
            continue
        if raw.startswith("\\"):  # "\ No newline at end of file"
            continue
        if raw.startswith("+"):
            ops.append(("add", None, new_line, raw[1:]))
            new_line += 1
            continue
        if raw.startswith("-"):
            ops.append(("del", old_line, None, raw[1:]))
            old_line += 1
            continue
        if raw.startswith(" ") or raw == "":
            ops.append(("ctx", old_line, new_line, raw[1:] if raw else ""))
            old_line += 1
            new_line += 1
            continue
        # Anything else inside a hunk is not diff body — ignore it.

    if not seen_hunk:
        raise DiffError("unified diff has no @@ hunk header")
    return ops


def ops_from_before_after(
    before: str,
    after: str,
    context: int | None = 3,
    start_line: int = 1,
) -> list[Op]:
    """Diff two code strings into an op list, trimmed to ``context`` lines.

    ``context=None`` keeps every unchanged line (useful for short snippets
    where the whole method should stay on screen).
    """
    left = _split_lines(before)
    right = _split_lines(after)
    matcher = difflib.SequenceMatcher(a=left, b=right, autojunk=False)
    opcodes = matcher.get_opcodes()

    keep: set[int] = set()  # indices into `left` for equal runs we keep
    if context is None:
        for tag, i1, i2, _j1, _j2 in opcodes:
            if tag == "equal":
                keep.update(range(i1, i2))
    else:
        for idx, (tag, i1, i2, _j1, _j2) in enumerate(opcodes):
            if tag != "equal":
                continue
            has_prev = idx > 0
            has_next = idx < len(opcodes) - 1
            if has_prev:
                keep.update(range(i1, min(i2, i1 + context)))
            if has_next:
                keep.update(range(max(i1, i2 - context), i2))
            if not has_prev and not has_next:
                keep.update(range(i1, i2))

    ops: list[Op] = []
    pending_gap = False
    for tag, i1, i2, j1, j2 in opcodes:
        if tag == "equal":
            for offset in range(i1, i2):
                if offset not in keep:
                    pending_gap = True
                    continue
                if pending_gap:
                    ops.append(("gap", None, None, ""))
                    pending_gap = False
                ops.append(
                    (
                        "ctx",
                        start_line + offset,
                        start_line + (j1 + offset - i1),
                        left[offset],
                    )
                )
            continue
        if pending_gap:
            ops.append(("gap", None, None, ""))
            pending_gap = False
        for offset in range(i1, i2):
            ops.append(("del", start_line + offset, None, left[offset]))
        for offset in range(j1, j2):
            ops.append(("add", None, start_line + offset, right[offset]))
    return ops


def _word_ranges(old: str, new: str) -> tuple[list[list[int]], list[list[int]]]:
    """Character ranges that differ between two similar lines, per side."""
    old_tokens = TOKEN_RE.findall(old)
    new_tokens = TOKEN_RE.findall(new)
    matcher = difflib.SequenceMatcher(a=old_tokens, b=new_tokens, autojunk=False)

    old_offsets: list[int] = []
    pos = 0
    for token in old_tokens:
        old_offsets.append(pos)
        pos += len(token)
    old_offsets.append(pos)

    new_offsets: list[int] = []
    pos = 0
    for token in new_tokens:
        new_offsets.append(pos)
        pos += len(token)
    new_offsets.append(pos)

    old_ranges: list[list[int]] = []
    new_ranges: list[list[int]] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        if i2 > i1:
            old_ranges.append([old_offsets[i1], old_offsets[i2]])
        if j2 > j1:
            new_ranges.append([new_offsets[j1], new_offsets[j2]])
    return _merge_ranges(old_ranges), _merge_ranges(new_ranges)


def _merge_ranges(ranges: list[list[int]]) -> list[list[int]]:
    if not ranges:
        return []
    merged = [ranges[0]]
    for start, end in ranges[1:]:
        if start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return merged


class _Side:
    """Accumulates one column's text and hands out per-line indices."""

    def __init__(self) -> None:
        self.lines: list[str] = []

    def add(self, text: str) -> int:
        self.lines.append(text)
        return len(self.lines) - 1

    @property
    def text(self) -> str:
        return "\n".join(self.lines)


def align(ops: list[Op], word_diff: bool = True) -> dict[str, Any]:
    """Pair del/add runs into side-by-side rows.

    Within a contiguous run of removals followed by additions, the *i*-th
    removal pairs with the *i*-th addition; leftovers on either side become
    single-sided rows. A pair whose lines are too dissimilar is split back into
    two rows so word highlighting stays meaningful.
    """
    left = _Side()
    right = _Side()
    rows: list[dict[str, Any]] = []

    pending_del: list[Op] = []
    pending_add: list[Op] = []

    def flush() -> None:
        nonlocal pending_del, pending_add
        pairs = min(len(pending_del), len(pending_add))
        for idx in range(pairs):
            _, old_n, _, old_text = pending_del[idx]
            _, _, new_n, new_text = pending_add[idx]
            similar = (
                difflib.SequenceMatcher(a=old_text, b=new_text, autojunk=False).ratio()
                >= PAIR_SIMILARITY_FLOOR
            )
            if not similar:
                rows.append(
                    {"t": "del", "l": {"i": left.add(old_text), "n": old_n}}
                )
                rows.append(
                    {"t": "add", "r": {"i": right.add(new_text), "n": new_n}}
                )
                continue
            lw, rw = _word_ranges(old_text, new_text) if word_diff else ([], [])
            row: dict[str, Any] = {
                "t": "mod",
                "l": {"i": left.add(old_text), "n": old_n},
                "r": {"i": right.add(new_text), "n": new_n},
            }
            if lw:
                row["l"]["w"] = lw
            if rw:
                row["r"]["w"] = rw
            rows.append(row)
        for _, old_n, _, text in pending_del[pairs:]:
            rows.append({"t": "del", "l": {"i": left.add(text), "n": old_n}})
        for _, _, new_n, text in pending_add[pairs:]:
            rows.append({"t": "add", "r": {"i": right.add(text), "n": new_n}})
        pending_del = []
        pending_add = []

    for kind, old_n, new_n, text in ops:
        if kind == "del":
            if pending_add:  # add-then-del starts a new run
                flush()
            pending_del.append((kind, old_n, new_n, text))
            continue
        if kind == "add":
            pending_add.append((kind, old_n, new_n, text))
            continue
        flush()
        if kind == "gap":
            rows.append({"t": "gap", "label": text})
            continue
        rows.append(
            {
                "t": "ctx",
                "l": {"i": left.add(text), "n": old_n},
                "r": {"i": right.add(text), "n": new_n},
            }
        )
    flush()

    return {"rows": rows, "leftText": left.text, "rightText": right.text}


def build_diff_payload(block: dict[str, Any]) -> dict[str, Any]:
    """Turn a spec ``diff`` block into the payload consumed by the page JS.

    Input is one of:
      * ``unified``    — a unified diff string (one file per block)
      * ``before``/``after`` — two code strings, diffed here

    Returns language, both column texts, aligned rows, +/- counts and the
    display mode (``split`` normally, ``new`` when nothing was removed).
    """
    unified = block.get("unified")
    before = block.get("before")
    after = block.get("after")
    word_diff = bool(block.get("word_diff", True))

    if unified:
        ops = parse_unified(unified)
    elif before is not None or after is not None:
        raw_context = block.get("context", 3)
        context = None if raw_context in (None, "all") else int(raw_context)
        ops = ops_from_before_after(
            before or "",
            after or "",
            context=context,
            start_line=int(block.get("line", 1)),
        )
    else:
        raise DiffError("diff block needs 'unified', or 'before'/'after'")

    payload = align(ops, word_diff=word_diff)
    added = sum(1 for r in payload["rows"] if r["t"] in ("add", "mod"))
    removed = sum(1 for r in payload["rows"] if r["t"] in ("del", "mod"))

    declared = block.get("mode")
    has_left = any(r["t"] in ("ctx", "del", "mod") for r in payload["rows"])
    has_right = any(r["t"] in ("ctx", "add", "mod") for r in payload["rows"])
    if declared in ("new", "removed", "split"):
        mode: Literal["new", "removed", "split"] = declared
    elif not has_left:
        mode = "new"
    elif not has_right:
        mode = "removed"
    else:
        mode = "split"

    payload["language"] = block.get("language", "text")
    payload["stats"] = {"added": added, "removed": removed}
    payload["mode"] = mode
    payload["view"] = "unified" if block.get("view") == "unified" else "split"
    return payload
