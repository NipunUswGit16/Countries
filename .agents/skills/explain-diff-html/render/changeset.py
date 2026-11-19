"""PR-style files-changed sidebar panel."""

from __future__ import annotations

import html
import subprocess
from pathlib import Path
from typing import Any

from context import RenderContext
from strings import ui_strings

STATUS_LABELS = {"A": "A", "M": "M", "D": "D", "R": "R", "C": "C", "T": "T"}


def git_numstat(repo_root: Path, git_range: str) -> list[dict[str, Any]] | None:
    """Read a changeset summary from git. Returns None when git fails."""

    def run(args: list[str]) -> str | None:
        try:
            result = subprocess.run(
                ["git", "-C", str(repo_root), *args],
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if result.returncode != 0:
            return None
        return result.stdout

    numstat = run(["diff", "--numstat", git_range])
    if numstat is None:
        return None
    statuses: dict[str, str] = {}
    name_status = run(["diff", "--name-status", git_range])
    if name_status:
        for line in name_status.splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                statuses[parts[-1]] = parts[0][:1]

    files: list[dict[str, Any]] = []
    for line in numstat.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        add_raw, del_raw, path = parts[0], parts[1], parts[-1]
        binary = add_raw == "-" or del_raw == "-"
        files.append(
            {
                "path": path,
                "added": 0 if binary else int(add_raw),
                "removed": 0 if binary else int(del_raw),
                "status": statuses.get(path, "M"),
                "binary": binary,
            }
        )
    return files


def render_changeset(spec: dict[str, Any], ctx: RenderContext) -> str:
    """PR-style summary of touched files: path, +/-, and a proportion bar."""
    cs = spec.get("changeset")
    if not cs:
        return ""
    if isinstance(cs, list):
        cs = {"files": cs}

    files: list[dict[str, Any]] = list(cs.get("files") or [])
    git_range = cs.get("git_range")
    if not files and git_range and ctx.repo_root is not None:
        from_git = git_numstat(ctx.repo_root, str(git_range))
        if from_git is None:
            return (
                '<section class="changeset"><p class="flow-caption">'
                f"changeset: git diff --numstat {html.escape(str(git_range))} failed"
                "</p></section>"
            )
        files = from_git
    if not files:
        return ""

    for f in files:
        f["added"] = int(f.get("added", 0) or 0)
        f["removed"] = int(f.get("removed", 0) or 0)
    files.sort(key=lambda f: (f["added"] + f["removed"]), reverse=True)

    total_add = sum(f["added"] for f in files)
    total_del = sum(f["removed"] for f in files)
    peak = max((f["added"] + f["removed"]) for f in files) or 1

    rows: list[str] = []
    ui = ctx.ui or ui_strings("en")
    for f in files:
        path = str(f.get("path", ""))
        status = STATUS_LABELS.get(str(f.get("status", "M")).upper()[:1], "M")
        churn = f["added"] + f["removed"]
        filled = max(1, round(5 * churn / peak)) if churn else 0
        add_share = round(filled * f["added"] / churn) if churn else 0
        segs = "".join(
            f'<i class="{"add" if i < add_share else ("del" if i < filled else "none")}"></i>'
            for i in range(5)
        )
        anchor = ctx.file_anchors.get(path)
        covered = " is-covered" if anchor else ""
        if anchor:
            name_html = (
                f'<a class="cs-path" href="#{html.escape(anchor)}" '
                f'title="{html.escape(ui["changeset_covered_hint"])}">{html.escape(path)}</a>'
            )
        elif ctx.resolve_path(path) is not None:
            name_html = ctx.file_link_html(path, label=path)
        else:
            name_html = f'<span class="cs-path">{html.escape(path)}</span>'
        counts = (
            f'<span class="dstat add">+{f["added"]}</span>'
            f'<span class="dstat del">−{f["removed"]}</span>'
        )
        if f.get("binary"):
            counts = '<span class="dstat">bin</span>'
        marker = f'<span class="cs-mark" aria-hidden="true">{"◆" if anchor else ""}</span>'
        rows.append(
            f'<li class="cs-row{covered}"><span class="cs-status s{status}">{status}</span>'
            f"{marker}{name_html}"
            f'<span class="cs-counts">{counts}<span class="cs-bar">{segs}</span></span></li>'
        )

    covered_count = sum(1 for f in files if ctx.file_anchors.get(str(f.get("path", ""))))
    chip = ""
    if covered_count:
        chip = (
            f'<button type="button" class="cs-chip" data-cs-filter aria-pressed="false" '
            f'title="{html.escape(ui["changeset_filter_hint"])}">'
            f'<span class="cs-mark" aria-hidden="true">◆</span>'
            f'{covered_count} {html.escape(ui["changeset_covered"])}</button>'
        )
    note = cs.get("note", "")
    note_html = f'<p class="cs-note">{html.escape(str(note))}</p>' if note else ""
    return (
        f'<div class="changeset">'
        f'<div class="cs-totals"><b>{len(files)}</b> {html.escape(ui.get("changeset_files", "files"))}'
        f'<span class="dstat add">+{total_add}</span>'
        f'<span class="dstat del">−{total_del}</span></div>'
        f"{chip}{note_html}"
        f'<ol class="cs-list">{"".join(rows)}</ol></div>'
    )
