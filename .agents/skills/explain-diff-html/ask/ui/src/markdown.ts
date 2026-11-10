import { escapeHtml } from "./strings";

const LANG_ALIASES: Record<string, string> = {
  golang: "go",
  js: "javascript",
  ts: "typescript",
  tsx: "tsx",
  jsx: "jsx",
  sh: "bash",
  shell: "bash",
  zsh: "bash",
  yml: "yaml",
  md: "markdown",
  text: "text",
  plain: "text",
  py: "python",
  rb: "ruby",
  rs: "rust",
  kt: "kotlin",
  cs: "csharp",
};

const EXT_LANG: Record<string, string> = {
  go: "go",
  js: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  ts: "typescript",
  tsx: "tsx",
  jsx: "jsx",
  py: "python",
  rb: "ruby",
  rs: "rust",
  java: "java",
  kt: "kotlin",
  cs: "csharp",
  c: "c",
  h: "c",
  cpp: "cpp",
  cc: "cpp",
  hpp: "cpp",
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  yaml: "yaml",
  yml: "yaml",
  json: "json",
  md: "markdown",
  sql: "sql",
  html: "markup",
  css: "css",
  toml: "toml",
  proto: "protobuf",
};

type FenceMeta = {
  lang: string;
  path?: string;
  startLine?: string;
  endLine?: string;
};

type Fence = FenceMeta & { code: string; open?: boolean };

function normalizeLang(lang: string): string {
  const raw = (lang || "text").toLowerCase().trim();
  return LANG_ALIASES[raw] || raw || "text";
}

function langFromPath(path: string): string {
  const base = path.split(/[\\/]/).pop() || path;
  const ext = base.includes(".") ? base.split(".").pop()!.toLowerCase() : "";
  return normalizeLang(EXT_LANG[ext] || "text");
}

/** Parse ``` meta: `go` | `99:116:path/file.go` | `path/file.go` */
export function parseFenceMeta(raw: string): FenceMeta {
  const meta = String(raw || "").trim();
  if (!meta) return { lang: "text" };

  const cite = meta.match(/^(\d+):(\d+):(.+)$/);
  if (cite) {
    const path = cite[3].trim();
    return {
      lang: langFromPath(path),
      path,
      startLine: cite[1],
      endLine: cite[2],
    };
  }

  if (meta.includes("/") || meta.includes("\\") || /\.\w{1,8}$/.test(meta)) {
    return { lang: langFromPath(meta), path: meta };
  }

  return { lang: normalizeLang(meta) };
}

export function highlightAskCode(root: ParentNode | null): void {
  if (!root) return;
  const Prism = window.Prism;
  if (!Prism) return;
  root.querySelectorAll("pre.ask-code code").forEach((block) => {
    const el = block as HTMLElement;
    const lang = (el.className.match(/language-([\w+-]+)/) || [])[1] || "text";
    // Prism no-ops quietly when grammar missing — fall back to text.
    const grammars = (Prism as unknown as { languages?: Record<string, unknown> }).languages;
    if (lang !== "text" && grammars && !grammars[lang]) {
      el.className = "language-text";
    }
    try {
      Prism.highlightElement(el);
    } catch {
      /* ignore */
    }
  });
}

function renderTable(block: string): string | null {
  const lines = block
    .trim()
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
  if (lines.length < 2) return null;
  if (!/^\|.*\|$/.test(lines[0]) || !/^\|?\s*:?-{3,}/.test(lines[1])) return null;

  const splitRow = (line: string): string[] =>
    line
      .replace(/^\|/, "")
      .replace(/\|$/, "")
      .split("|")
      .map((c) => c.trim());

  const header = splitRow(lines[0]);
  const rows = lines.slice(2).map(splitRow);
  if (!header.length) return null;

  let html = '<table class="ask-md-table"><thead><tr>';
  header.forEach((cell) => {
    html += "<th>" + inlineMd(cell) + "</th>";
  });
  html += "</tr></thead><tbody>";
  rows.forEach((row) => {
    html += "<tr>";
    header.forEach((_, i) => {
      html += "<td>" + inlineMd(row[i] || "") + "</td>";
    });
    html += "</tr>";
  });
  html += "</tbody></table>";
  return html;
}

function inlineMd(text: string): string {
  let html = escapeHtml(text);
  html = html.replace(/`([^`\n]+)`/g, '<code class="ask-inline-code">$1</code>');
  html = html.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  html = html.replace(/\*([^*\n]+)\*/g, "<em>$1</em>");
  return html;
}

function fenceHtml(f: Fence): string {
  const lang = f.lang || "text";
  const openCls = f.open ? " ask-code-open" : "";
  let cap = "";
  if (f.path || f.startLine) {
    const lines =
      f.startLine && f.endLine ? f.startLine + "\u2013" + f.endLine : "";
    cap =
      '<figcaption class="ask-code-cap">' +
      (f.path
        ? '<span class="ask-code-path">' + escapeHtml(f.path) + "</span>"
        : "") +
      (lines
        ? '<span class="ask-code-lines">' + escapeHtml(lines) + "</span>"
        : "") +
      '<span class="ask-code-lang">' +
      escapeHtml(lang) +
      "</span>" +
      "</figcaption>";
  }
  return (
    '<figure class="ask-codeblock' +
    openCls +
    '">' +
    cap +
    '<pre class="ask-code language-' +
    lang +
    '"><code class="language-' +
    lang +
    '">' +
    escapeHtml(f.code) +
    "</code></pre></figure>"
  );
}

/** Cursor often emits bare `12:34:path` citations without fences. */
function wrapBareCitations(text: string): string {
  const lines = text.split("\n");
  const out: string[] = [];
  const citeRe = /^(\d+):(\d+):(\S.+)$/;
  let i = 0;

  const looksLikeCode = (line: string): boolean => {
    if (!line) return false;
    if (/^\s/.test(line)) return true;
    if (/^[{}()[\];]/.test(line)) return true;
    if (
      /^(func|type|package|import|return|if|for|switch|case|var|const|struct|interface|select|defer|go |map|chan|class|def |async |await |export |from |using |public |private |protected )/.test(
        line,
      )
    ) {
      return true;
    }
    if (/[=<>!:]{1,2}|->|:=/.test(line) && /[(){}[\];]/.test(line)) return true;
    if (/^[a-zA-Z_][\w.]*\([^;]*\)\s*\{?\s*$/.test(line)) return true;
    return false;
  };

  while (i < lines.length) {
    const m = lines[i].match(citeRe);
    if (m && i + 1 < lines.length && looksLikeCode(lines[i + 1])) {
      const meta = lines[i];
      i += 1;
      const body: string[] = [];
      while (i < lines.length) {
        if (citeRe.test(lines[i])) break;
        if (/^#{1,3}\s/.test(lines[i])) break;
        if (/^```/.test(lines[i])) break;
        if (
          lines[i] === "" &&
          i + 1 < lines.length &&
          !looksLikeCode(lines[i + 1]) &&
          !citeRe.test(lines[i + 1])
        ) {
          break;
        }
        if (/^\d+\.\s+\S/.test(lines[i]) && !looksLikeCode(lines[i])) break;
        body.push(lines[i]);
        i += 1;
      }
      while (body.length && body[body.length - 1] === "") body.pop();
      out.push("```" + meta);
      out.push(...body);
      out.push("```");
      continue;
    }
    out.push(lines[i]);
    i += 1;
  }
  return out.join("\n");
}

/** If a fence was left open, peel trailing prose (lists/headings) back out. */
function splitOpenFenceProse(code: string): { code: string; rest: string } {
  const lines = code.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\d+\.\s+\S/.test(line)) {
      return {
        code: lines.slice(0, i).join("\n").replace(/\n+$/, ""),
        rest: lines.slice(i).join("\n"),
      };
    }
    if (/^#{1,3}\s+\S/.test(line)) {
      return {
        code: lines.slice(0, i).join("\n").replace(/\n+$/, ""),
        rest: lines.slice(i).join("\n"),
      };
    }
    if (/^\| .+\|/.test(line) && i + 1 < lines.length && /^\|?\s*:?-{3,}/.test(lines[i + 1])) {
      return {
        code: lines.slice(0, i).join("\n").replace(/\n+$/, ""),
        rest: lines.slice(i).join("\n"),
      };
    }
  }
  return { code, rest: "" };
}

function extractFences(text: string): { text: string; fences: Fence[] } {
  const fences: Fence[] = [];

  let out = text.replace(/```([^\n`]*)\n([\s\S]*?)```/g, (_m, meta: string, code: string) => {
    const parsed = parseFenceMeta(meta);
    const i = fences.length;
    fences.push({ ...parsed, code: code.replace(/\n$/, "") });
    return "\0FENCE" + i + "\0";
  });

  out = out.replace(/```([^\n`]*)\n?([\s\S]*)$/g, (m, meta: string, code: string) => {
    if (m.indexOf("```") !== m.lastIndexOf("```")) return m;
    const parsed = parseFenceMeta(meta);
    const split = splitOpenFenceProse(code);
    const i = fences.length;
    fences.push({ ...parsed, code: split.code, open: true });
    let token = "\0FENCE" + i + "\0";
    if (split.rest) token += "\n\n" + split.rest;
    return token;
  });

  return { text: out, fences };
}

export function renderMarkdown(src: string): string {
  let text = String(src || "").replace(/\r\n/g, "\n");
  text = wrapBareCitations(text);

  const extracted = extractFences(text);
  text = extracted.text;
  const fences = extracted.fences;

  const tables: string[] = [];
  text = text.replace(/(?:^|\n)((?:\|.+\|\n){2,})/g, (m, block: string) => {
    const rendered = renderTable(block);
    if (!rendered) return m;
    const i = tables.length;
    tables.push(rendered);
    return "\n\0TABLE" + i + "\0\n";
  });

  const parts = text.split(/\n{2,}/);
  const htmlParts = parts.map((para) => {
    const trimmed = para.trim();
    if (!trimmed) return "";

    const fenceOnly = trimmed.match(/^\0FENCE(\d+)\0$/);
    if (fenceOnly) return fenceHtml(fences[Number(fenceOnly[1])]);

    const tableOnly = trimmed.match(/^\0TABLE(\d+)\0$/);
    if (tableOnly) return tables[Number(tableOnly[1])];

    if (/^#{1,3}\s+/.test(trimmed)) {
      return trimmed
        .split("\n")
        .map((line) => {
          if (/^###\s+/.test(line)) {
            return '<h4 class="ask-md-h">' + inlineMd(line.replace(/^###\s+/, "")) + "</h4>";
          }
          if (/^##\s+/.test(line)) {
            return '<h3 class="ask-md-h">' + inlineMd(line.replace(/^##\s+/, "")) + "</h3>";
          }
          if (/^#\s+/.test(line)) {
            return '<h3 class="ask-md-h">' + inlineMd(line.replace(/^#\s+/, "")) + "</h3>";
          }
          return "<p>" + inlineMd(line) + "</p>";
        })
        .join("");
    }

    if (/^\d+\.\s+/m.test(trimmed)) {
      const items = trimmed
        .split("\n")
        .filter((l) => /^\d+\.\s+/.test(l.trim()))
        .map((l) => "<li>" + inlineMd(l.trim().replace(/^\d+\.\s+/, "")) + "</li>")
        .join("");
      if (items) return '<ol class="ask-md-list">' + items + "</ol>";
    }

    if (/^(-|\*)\s+/m.test(trimmed)) {
      const items = trimmed
        .split("\n")
        .filter((l) => /^(-|\*)\s+/.test(l.trim()))
        .map((l) => "<li>" + inlineMd(l.trim().replace(/^(-|\*)\s+/, "")) + "</li>")
        .join("");
      if (items) return '<ul class="ask-md-list">' + items + "</ul>";
    }

    let body = para;
    body = body.replace(/\0FENCE(\d+)\0/g, (_m, idx: string) =>
      fenceHtml(fences[Number(idx)]),
    );
    body = body.replace(/\0TABLE(\d+)\0/g, (_m, idx: string) => tables[Number(idx)]);
    body = body
      .split(/(<(?:figure|table|ul|ol|h3|h4)[\s\S]*?<\/(?:figure|table|ul|ol|h3|h4)>)/g)
      .map((chunk) => {
        if (/^<(figure|table|ul|ol|h3|h4)/.test(chunk)) return chunk;
        return inlineMd(chunk).replace(/\n/g, "<br>");
      })
      .join("");
    if (/^<(figure|table|ul|ol|h3|h4)/.test(body.trim())) return body;
    return "<p>" + body + "</p>";
  });

  return htmlParts.filter(Boolean).join("");
}
