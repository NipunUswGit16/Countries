"""Assemble a self-contained HTML page from a content spec."""

from __future__ import annotations

import html
import json
import os
import secrets
from pathlib import Path
from typing import Any

from assets import fill, load_ask_loader_js, load_prism_js, template
from blocks import render_section
from changeset import render_changeset
from context import RenderContext
from quiz import render_quiz
from strings import ui_strings


def _diff_runtime_js(ui: dict[str, str]) -> str:
    labels = json.dumps({"gap": ui.get("diff_gap", "unchanged lines skipped")})
    return template("diff.js").replace("__DIFF_UI__", labels)


def render_page(spec: dict[str, Any], seed: int | None = None, ctx: RenderContext | None = None) -> str:
    if seed is None:
        seed = int(spec.get("seed", secrets.randbits(32)))
    if ctx is None:
        repo_root = spec.get("repo_root")
        lang = spec.get("lang")
        ctx = RenderContext(
            repo_root=Path(repo_root).resolve() if repo_root else None,
            editor_scheme=spec.get("editor_scheme", "cursor"),
            ui=ui_strings(lang),
        )
    title = spec.get("title", "Explanation")
    summary = spec.get("summary", "")
    meta = spec.get("meta", "")
    footer = spec.get("footer", "")
    sections = spec.get("sections", [])
    quiz = spec.get("quiz", [])

    toc_html = "".join(
        f'<li><a href="#{html.escape(s.get("id", ""))}">{html.escape(s.get("title", ""))}</a></li>'
        for s in sections
    )
    ui = ctx.ui or ui_strings("en")
    if quiz:
        toc_html += f'<li><a href="#quiz">{html.escape(ui["quiz"])}</a></li>'

    sections_html = "".join(render_section(s, ctx) for s in sections)
    changeset_html = render_changeset(spec, ctx)
    if changeset_html:
        file_count = changeset_html.count('<li class="cs-row')
        sidebar_tab_files = (
            '<button type="button" role="tab" class="sb-tab" data-tab="files" '
            f'aria-selected="false" title="{html.escape(ui["changeset"])}">'
            f'{html.escape(ui["changeset_short"])}'
            f'<span class="sb-count">{file_count}</span></button>'
        )
        sidebar_panel_files = (
            '<div class="sb-panel" role="tabpanel" data-panel="files">'
            f"{changeset_html}</div>"
        )
        sidebar_rail_files = (
            '<button type="button" class="sb-rail-btn" data-open-tab="files" '
            f'title="{html.escape(ui["changeset"])}">'
            f'<span aria-hidden="true">◆</span>'
            f'<span class="sr-only">{html.escape(ui["changeset"])}</span></button>'
        )
    else:
        sidebar_tab_files = sidebar_panel_files = sidebar_rail_files = ""
    quiz_html, quiz_js = render_quiz(quiz, seed, ui)

    repo_root_str = str(ctx.repo_root) if ctx.repo_root else ""
    meta_obj = {
        "title": title,
        "repo_root": repo_root_str,
        "lang": ui.get("html_lang", "en"),
        "ask_port": int(os.environ.get("EXPLAIN_DIFF_PORT", "7432")),
        "service": "explain-diff",
    }
    archive_name = spec.get("archive_name") or ""
    if archive_name:
        meta_obj["archive_name"] = archive_name

    page_js = fill(template("page.js"), {"quiz_js": quiz_js})
    page_js = page_js.replace("/* PRISM_BUNDLE */", load_prism_js(), 1)
    page_js = page_js.replace("/* DIFF_RUNTIME */", _diff_runtime_js(ui), 1)
    page_js = page_js.replace("/* CHROME_RUNTIME */", template("chrome.js"), 1)

    page = fill(
        template("page.html"),
        {
            "html_lang": html.escape(ui["html_lang"]),
            "ui_contents": html.escape(ui["contents"]),
            "ui_toc_aria": html.escape(ui["toc_aria"]),
            "ui_quiz": html.escape(ui["quiz"]),
            "ui_quiz_intro": html.escape(ui["quiz_intro"]),
            "ui_theme": html.escape(ui["theme"]),
            "ui_theme_aria": html.escape(ui["theme_aria"]),
            "ui_theme_kanagawa": html.escape(ui["theme_kanagawa"]),
            "ui_theme_dark": html.escape(ui["theme_dark"]),
            "ui_theme_light": html.escape(ui["theme_light"]),
            "ui_width": html.escape(ui["width"]),
            "ui_width_aria": html.escape(ui["width_aria"]),
            "ui_sidebar_toggle": html.escape(ui["sidebar_toggle"]),
            "ui_sidebar_collapse": html.escape(ui["sidebar_collapse"]),
            "title": html.escape(title),
            "title_html": html.escape(title),
            "summary_html": html.escape(summary),
            "meta_html": html.escape(meta),
            "meta_json": json.dumps(meta_obj, ensure_ascii=True).replace("<", "\\u003c"),
            "footer_html": html.escape(footer),
            "toc_html": toc_html,
            "sections_html": sections_html,
            "sidebar_tab_files": sidebar_tab_files,
            "sidebar_panel_files": sidebar_panel_files,
            "sidebar_rail_files": sidebar_rail_files,
            "quiz_html": quiz_html,
        },
    )
    page = page.replace("/* BOOT_JS */", template("boot.js"), 1)
    page = page.replace("/* PAGE_CSS */", template("page.css"), 1)
    page = page.replace("/* PAGE_JS */", page_js, 1)
    return page.replace("/* ASK_LOADER */", load_ask_loader_js(), 1)
