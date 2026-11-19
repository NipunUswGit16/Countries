"""Render context: editor deeplinks and per-file anchors."""

from __future__ import annotations

import html
import re
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote

from strings import ui_strings

FILE_REF_RE = re.compile(
    r"<code>(?P<path>[\w./-]+\.(?:go|sql|ya?ml|json|sh|md|txt|properties))</code>"
    r"(?:\s*\(~lines?\s*(?P<line>\d+)(?:[–\-](?P<end_line>\d+))?\))?",
    re.IGNORECASE,
)


@dataclass
class RenderContext:
    """Paths and editor scheme used to build cursor:// / vscode:// links."""

    repo_root: Path | None = None
    editor_scheme: str = "cursor"
    ui: dict[str, str] | None = None
    # path -> anchor id of the block that covers it. Filled while rendering
    # sections, which happens before the changeset list is built, so a file row
    # can link straight to the passage that explains it. A `diff` block always
    # wins over a `code` block for the same path: it is the richer treatment.
    file_anchors: dict[str, str] = field(default_factory=dict)
    _diff_paths: set[str] = field(default_factory=set)
    _seq: list[int] = field(default_factory=lambda: [0])

    def __post_init__(self) -> None:
        if self.ui is None:
            self.ui = ui_strings("en")

    def next_block_id(self, prefix: str) -> str:
        self._seq[0] += 1
        return f"{prefix}-{self._seq[0]}"

    def register_anchor(self, file_path: str, anchor: str, *, is_diff: bool) -> None:
        if not file_path:
            return
        if is_diff:
            if file_path not in self._diff_paths:
                self.file_anchors[file_path] = anchor
                self._diff_paths.add(file_path)
            return
        if file_path not in self.file_anchors:
            self.file_anchors[file_path] = anchor

    def resolve_path(self, file_path: str) -> Path | None:
        if not file_path:
            return None
        candidate = Path(file_path)
        if candidate.is_absolute():
            return candidate.resolve()
        if self.repo_root is not None:
            return (self.repo_root / candidate).resolve()
        return None

    def editor_uri(
        self,
        file_path: str,
        line: int | None = None,
        column: int | None = None,
    ) -> str | None:
        resolved = self.resolve_path(file_path)
        if resolved is None:
            return None
        posix = resolved.as_posix()
        uri = f"{self.editor_scheme}://file{quote(posix, safe='/:')}"
        if line is not None:
            uri += f":{line}"
            if column is not None:
                uri += f":{column}"
        return uri

    def file_link_html(
        self,
        file_path: str,
        line: int | None = None,
        end_line: int | None = None,
        column: int | None = None,
        label: str | None = None,
    ) -> str:
        uri = self.editor_uri(file_path, line=line, column=column)
        if uri is None:
            return html.escape(label or file_path)
        display = label or file_location_label(file_path, line, end_line)
        return (
            f'<a class="editor-link" href="{html.escape(uri, quote=True)}" '
            f'title="{html.escape(self.ui["open_in_cursor"])}">{html.escape(display)}</a>'
        )


def file_location_label(file_path: str, line: int | None, end_line: int | None) -> str:
    if line is not None and end_line is not None and end_line != line:
        return f"{file_path}:{line}–{end_line}"
    if line is not None:
        return f"{file_path}:{line}"
    return file_path


def linkify_html_file_refs(content: str, ctx: RenderContext) -> str:
    if ctx.repo_root is None:
        return content

    def repl(match: re.Match[str]) -> str:
        path = match.group("path")
        line = int(match.group("line")) if match.group("line") else None
        end_line = int(match.group("end_line")) if match.group("end_line") else None
        if ctx.resolve_path(path) is None:
            return match.group(0)
        return ctx.file_link_html(path, line=line, end_line=end_line)

    return FILE_REF_RE.sub(repl, content)
