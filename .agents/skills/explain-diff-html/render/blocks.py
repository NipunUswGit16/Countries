"""Content-block HTML (code, diff, table, flow, …)."""

from __future__ import annotations

import html
import json
from typing import Any

from assets import prism_language
from context import RenderContext, file_location_label, linkify_html_file_refs
from diffview import DiffError, build_diff_payload
from strings import ui_strings


def render_block(block: dict[str, Any], ctx: RenderContext) -> str:
    btype = block.get("type", "html")
    if btype == "html":
        return linkify_html_file_refs(block.get("content", ""), ctx)
    if btype == "file":
        path = block.get("path", "")
        line = block.get("line")
        end_line = block.get("end_line")
        column = block.get("column")
        label = block.get("label", "")
        link = ctx.file_link_html(path, line=line, end_line=end_line, column=column)
        if label:
            return f'<p class="file-ref">{link} <span class="file-label">{label}</span></p>'
        return f'<p class="file-ref">{link}</p>'
    if btype == "code":
        lang = block.get("language", "text")
        code = block.get("code", "")
        caption = block.get("caption", "")
        file_hint = block.get("file", "")
        line = block.get("line")
        end_line = block.get("end_line")
        column = block.get("column")
        header = ""
        if file_hint:
            if ctx.resolve_path(file_hint) is not None:
                header = (
                    f'<div class="code-header">{ctx.file_link_html(file_hint, line=line, end_line=end_line, column=column)}'
                    f' <span class="open-hint" title="{html.escape(ctx.ui["opens_cursor"])}">↗</span></div>'
                )
            else:
                header = f'<div class="code-header">{html.escape(file_location_label(file_hint, line, end_line))}</div>'
        cap = f"<figcaption>{html.escape(caption)}</figcaption>" if caption else ""
        prism_lang = prism_language(lang)
        lang_class = f' class="language-{html.escape(prism_lang)}"' if prism_lang else ""
        escaped_code = html.escape(code)
        block_id = ctx.next_block_id("ref")
        if file_hint:
            ctx.register_anchor(file_hint, block_id, is_diff=False)
        return (
            f'<figure class="code-figure" id="{block_id}">{header}'
            f"<pre><code{lang_class}>{escaped_code}</code></pre>{cap}</figure>"
        )
    if btype == "diff":
        return render_diff_block(block, ctx)
    if btype == "callout":
        variant = block.get("variant", "")
        cls = f"callout {variant}".strip()
        title = block.get("title", "")
        title_html = f"<strong>{html.escape(title)}</strong>" if title else ""
        body = block.get("content", "")
        return f'<div class="{html.escape(cls)}">{title_html}{body}</div>'
    if btype == "table":
        headers = block.get("headers", [])
        rows = block.get("rows", [])
        caption = block.get("caption", "")
        ths = "".join(
            f"<th>{linkify_html_file_refs(str(h), ctx)}</th>" for h in headers
        )
        trs = "".join(
            "<tr>"
            + "".join(
                f"<td>{linkify_html_file_refs(str(c), ctx)}</td>" for c in row
            )
            + "</tr>"
            for row in rows
        )
        cap = f"<caption>{html.escape(caption)}</caption>" if caption else ""
        return f'<table class="data"><thead><tr>{ths}</tr></thead><tbody>{trs}</tbody>{cap}</table>'
    if btype == "panels":
        panels = block.get("panels", [])
        inner = ""
        for p in panels:
            variant = html.escape(p.get("variant", ""))
            title = html.escape(p.get("title", ""))
            content = p.get("content", "")
            inner += f'<div class="panel {variant}"><h4>{title}</h4>{content}</div>'
        return f'<div class="panels">{inner}</div>'
    if btype == "flow":
        steps = block.get("steps", [])
        arrows = block.get("arrows", [])
        caption = block.get("caption", "")
        parts: list[str] = []
        for i, step in enumerate(steps):
            label = html.escape(step.get("label", ""))
            sub = step.get("sub", "")
            sub_html = f"<br><small>{html.escape(sub)}</small>" if sub else ""
            parts.append(f'<div class="node">{label}{sub_html}</div>')
            if i < len(arrows):
                parts.append(f'<div class="arrow">→<span>{html.escape(arrows[i])}</span></div>')
        cap = f'<p class="flow-caption">{html.escape(caption)}</p>' if caption else ""
        return f'<div class="flow" role="img">{"".join(parts)}</div>{cap}'
    if btype == "cards":
        cols = " cols2" if block.get("columns", 2) == 2 else ""
        cards = block.get("cards", [])
        inner = ""
        for c in cards:
            inner += (
                f'<div class="card"><h4>{html.escape(c.get("title", ""))}</h4>'
                f'{c.get("content", "")}</div>'
            )
        return f'<div class="cards{cols}">{inner}</div>'
    return ""


def render_diff_block(block: dict[str, Any], ctx: RenderContext) -> str:
    """Emit a diff figure; the page runtime turns the JSON payload into DOM."""
    ui = ctx.ui or ui_strings("en")
    try:
        payload = build_diff_payload(block)
    except DiffError as exc:
        return f'<p class="flow-caption">diff block: {html.escape(str(exc))}</p>'

    block_id = ctx.next_block_id("diff")
    file_hint = block.get("file", "")
    if file_hint:
        ctx.register_anchor(file_hint, block_id, is_diff=True)

    if file_hint and ctx.resolve_path(file_hint) is not None:
        header_left = (
            f"{ctx.file_link_html(file_hint, line=block.get('line'), end_line=block.get('end_line'), column=block.get('column'))}"
            f' <span class="open-hint" title="{html.escape(ui["opens_cursor"])}">↗</span>'
        )
    elif file_hint:
        header_left = html.escape(
            file_location_label(file_hint, block.get("line"), block.get("end_line"))
        )
    else:
        header_left = ""

    added = payload["stats"]["added"]
    removed = payload["stats"]["removed"]
    badges = (
        f'<span class="diff-badges"><span class="dstat add">+{added}</span>'
        f'<span class="dstat del">−{removed}</span></span>'
    )
    mode_badge = ""
    if payload["mode"] == "new":
        mode_badge = f'<span class="diff-mode-badge new">{html.escape(ui["diff_new_file"])}</span>'
    elif payload["mode"] == "removed":
        mode_badge = f'<span class="diff-mode-badge del">{html.escape(ui["diff_removed_file"])}</span>'

    toggle = ""
    if payload["mode"] == "split":
        split_on = " is-on" if payload["view"] == "split" else ""
        unified_on = " is-on" if payload["view"] == "unified" else ""
        toggle = (
            f'<div class="diff-views" role="group" aria-label="{html.escape(ui["diff_view_aria"])}">'
            f'<button type="button" class="diff-view-btn{split_on}" data-view="split">{html.escape(ui["diff_split"])}</button>'
            f'<button type="button" class="diff-view-btn{unified_on}" data-view="unified">{html.escape(ui["diff_unified"])}</button>'
            f"</div>"
        )

    caption = block.get("caption", "")
    cap = f"<figcaption>{html.escape(caption)}</figcaption>" if caption else ""
    data = json.dumps(payload, ensure_ascii=True).replace("<", "\\u003c")

    return (
        f'<figure class="diff-figure" id="{block_id}" data-view="{payload["view"]}">'
        f'<div class="diff-header"><div class="diff-header-main">{header_left}{badges}{mode_badge}</div>{toggle}</div>'
        f'<div class="diff-body" data-diff-mount></div>'
        f'<script type="application/json" class="diff-payload">{data}</script>'
        f"{cap}</figure>"
    )


def render_section(section: dict[str, Any], ctx: RenderContext) -> str:
    sid = html.escape(section.get("id", ""))
    title = html.escape(section.get("title", ""))
    if "html" in section:
        body = linkify_html_file_refs(section["html"], ctx)
    else:
        body = "".join(render_block(b, ctx) for b in section.get("blocks", []))
    return f'<section id="{sid}"><h2>{title}</h2>{body}</section>'
