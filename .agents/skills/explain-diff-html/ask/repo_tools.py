"""Read-only repo tools for the local (Ollama) Ask backend.

The Cursor backend gets its filesystem access from the SDK's local agent. A
local model has no such harness, so this module provides the smallest useful
equivalent: list a directory, read a file, grep for a pattern — and nothing
else. There is deliberately no write, move, delete or execute tool.

Every path is resolved and then checked to still live inside the repo root, so
`..`, absolute paths and symlinks that point outside all fail closed. The caps
exist because a local model that reads a 40 MB file will blow its own context
long before anything else notices.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

MAX_FILE_BYTES = 120_000
MAX_LIST_ENTRIES = 300
MAX_GREP_HITS = 60
MAX_GREP_FILES = 4_000
MAX_GREP_BYTES = 2_000_000
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "dist", "build", "__pycache__"}


class ToolError(Exception):
    """Returned to the model as an error string rather than raised to the user."""


def _safe_path(repo_root: Path, raw: str) -> Path:
    """Resolve `raw` under repo_root, refusing anything that escapes it."""
    if raw is None:
        raise ToolError("path is required")
    text = str(raw).strip()
    if not text:
        raise ToolError("path is required")

    root = repo_root.resolve()
    candidate = Path(text)
    # An absolute path is only honoured when it is already inside the root;
    # otherwise treat it as relative so "/etc/passwd" becomes root/etc/passwd
    # and then fails the containment check below.
    target = candidate if candidate.is_absolute() else root / candidate
    resolved = target.resolve()

    try:
        resolved.relative_to(root)
    except ValueError:
        raise ToolError(f"path escapes the repo root: {text}") from None
    return resolved


def _rel(repo_root: Path, path: Path) -> str:
    try:
        return str(path.relative_to(repo_root.resolve()))
    except ValueError:
        return str(path)


def read_file(repo_root: Path, path: str, start_line: Any = None, end_line: Any = None) -> str:
    target = _safe_path(repo_root, path)
    if target.is_dir():
        raise ToolError(f"{_rel(repo_root, target)} is a directory; use list_dir")
    if not target.is_file():
        raise ToolError(f"no such file: {_rel(repo_root, target)}")

    raw = target.read_bytes()[: MAX_FILE_BYTES + 1]
    truncated = len(raw) > MAX_FILE_BYTES
    raw = raw[:MAX_FILE_BYTES]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise ToolError(f"{_rel(repo_root, target)} is not UTF-8 text") from None

    lines = text.split("\n")
    lo = int(start_line) if str(start_line or "").strip().isdigit() else 1
    hi = int(end_line) if str(end_line or "").strip().isdigit() else len(lines)
    lo = max(1, lo)
    hi = min(len(lines), max(lo, hi))
    body = "\n".join(f"{n:>5}  {lines[n - 1]}" for n in range(lo, hi + 1))

    header = f"{_rel(repo_root, target)} (lines {lo}-{hi} of {len(lines)})"
    if truncated:
        header += " [truncated]"
    return f"{header}\n{body}"


def list_dir(repo_root: Path, path: str = ".") -> str:
    target = _safe_path(repo_root, path or ".")
    if not target.is_dir():
        raise ToolError(f"not a directory: {_rel(repo_root, target)}")

    entries: list[str] = []
    for child in sorted(target.iterdir(), key=lambda p: (p.is_file(), p.name)):
        if child.name in SKIP_DIRS:
            continue
        if child.is_dir():
            entries.append(f"{child.name}/")
        else:
            try:
                size = child.stat().st_size
            except OSError:
                size = 0
            entries.append(f"{child.name}  ({size} B)")
        if len(entries) >= MAX_LIST_ENTRIES:
            entries.append("… (truncated)")
            break
    listing = "\n".join(entries) or "(empty)"
    return f"{_rel(repo_root, target)}/\n{listing}"


def grep(repo_root: Path, pattern: str, path: str = ".", glob: str = "") -> str:
    if not str(pattern or "").strip():
        raise ToolError("pattern is required")
    try:
        rx = re.compile(pattern)
    except re.error as exc:
        raise ToolError(f"bad regex: {exc}") from None

    base = _safe_path(repo_root, path or ".")
    suffix = (glob or "").strip().lstrip("*")
    hits: list[str] = []
    scanned = 0
    budget = MAX_GREP_BYTES

    files = [base] if base.is_file() else sorted(base.rglob("*"))
    for candidate in files:
        if len(hits) >= MAX_GREP_HITS or scanned >= MAX_GREP_FILES or budget <= 0:
            break
        if candidate.is_dir():
            continue
        if any(part in SKIP_DIRS for part in candidate.parts):
            continue
        if suffix and not candidate.name.endswith(suffix):
            continue
        try:
            size = candidate.stat().st_size
        except OSError:
            continue
        if size > MAX_FILE_BYTES:
            continue
        scanned += 1
        budget -= size
        try:
            text = candidate.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(text.split("\n"), 1):
            if rx.search(line):
                hits.append(f"{_rel(repo_root, candidate)}:{n}: {line.strip()[:200]}")
                if len(hits) >= MAX_GREP_HITS:
                    hits.append("… (more matches not shown)")
                    break
    return "\n".join(hits) if hits else f"no matches for {pattern!r}"


# Schema advertised to the model. Kept in Ollama/OpenAI function-calling shape.
TOOL_SCHEMA: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": (
                "Read a UTF-8 text file from the repository being explained. "
                "Returns the content with line numbers."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path relative to the repo root"},
                    "start_line": {"type": "integer", "description": "First line (1-based)"},
                    "end_line": {"type": "integer", "description": "Last line (inclusive)"},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_dir",
            "description": "List the entries of a directory in the repository.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Directory relative to the repo root"},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "grep",
            "description": "Search the repository for a regular expression. Returns file:line matches.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Python regular expression"},
                    "path": {"type": "string", "description": "Directory or file to search under"},
                    "glob": {"type": "string", "description": "Filter by file suffix, e.g. '.go'"},
                },
                "required": ["pattern"],
            },
        },
    },
]

DISPATCH = {"read_file": read_file, "list_dir": list_dir, "grep": grep}


def run_tool(repo_root: Path, name: str, args: dict[str, Any]) -> str:
    """Execute one tool call, returning either its output or an error string."""
    fn = DISPATCH.get(name)
    if fn is None:
        return f"error: unknown tool {name!r}"
    if not isinstance(args, dict):
        return "error: arguments must be an object"
    try:
        return fn(repo_root, **args)  # type: ignore[arg-type]
    except ToolError as exc:
        return f"error: {exc}"
    except TypeError as exc:
        return f"error: bad arguments for {name}: {exc}"
    except OSError as exc:
        return f"error: {exc}"
