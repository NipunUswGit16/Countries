#!/usr/bin/env python3
"""CLI: JSON content spec → self-contained HTML page."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
from pathlib import Path

import paths  # noqa: F401  # puts render/ on sys.path

from context import RenderContext
from page import render_page
from strings import ui_strings


def _serve_page_url(path: Path) -> str | None:
    """Return sidecar URL when explain-diff serve is healthy, else None."""
    import urllib.error
    import urllib.request

    host = os.environ.get("EXPLAIN_DIFF_HOST", "127.0.0.1")
    port = os.environ.get("EXPLAIN_DIFF_PORT", "7432")
    health = f"http://{host}:{port}/health"
    try:
        with urllib.request.urlopen(health, timeout=0.8) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None
    if not isinstance(data, dict) or not data.get("ok") or data.get("service") != "explain-diff":
        return None
    return f"http://{host}:{port}/p/{path.name}?ask=1"


def open_in_browser(path: Path) -> None:
    """Open via localhost Ask sidecar when available; else file://."""
    resolved = path.resolve()
    target = _serve_page_url(resolved) or resolved.as_uri()
    system = platform.system()
    try:
        if system == "Darwin":
            subprocess.run(["open", target], check=False)
        elif system == "Windows":
            subprocess.run(["cmd", "/c", "start", "", target], check=False)
        else:
            subprocess.run(["xdg-open", target], check=False)
    except OSError as exc:
        print(f"warning: could not open browser: {exc}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render explain-diff HTML from JSON spec")
    parser.add_argument("spec", type=Path, help="JSON content specification")
    parser.add_argument("-o", "--output", type=Path, required=True, help="Output HTML path")
    parser.add_argument("--seed", type=int, default=None, help="Quiz shuffle seed (random if omitted)")
    parser.add_argument(
        "--open",
        dest="open_browser",
        action="store_true",
        default=True,
        help="Open the HTML in the default browser after render (default)",
    )
    parser.add_argument(
        "--no-open",
        dest="open_browser",
        action="store_false",
        help="Skip opening the browser",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Repository root for cursor:// file deeplinks (overrides spec.repo_root)",
    )
    parser.add_argument(
        "--editor-scheme",
        default=None,
        help="Editor URI scheme: cursor (default) or vscode",
    )
    args = parser.parse_args()

    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    repo_root = args.repo_root or spec.get("repo_root")
    if repo_root is None:
        repo_root = Path.cwd()
    ctx = RenderContext(
        repo_root=Path(repo_root).resolve(),
        editor_scheme=args.editor_scheme or spec.get("editor_scheme", "cursor"),
        ui=ui_strings(spec.get("lang")),
    )
    spec = dict(spec)
    spec.setdefault("archive_name", args.output.name)
    page = render_page(spec, seed=args.seed, ctx=ctx)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(page, encoding="utf-8")
    resolved = args.output.resolve()
    print(resolved)
    if args.open_browser:
        open_in_browser(resolved)
    return 0


if __name__ == "__main__":
    sys.exit(main())
