---
name: explain-diff-html
description: Create a rich, self-contained interactive HTML explanation of a code change, diff, branch, or pull request. Use when the user wants to understand the background, intuition, implementation, data flow, diagrams, or quiz-based reinforcement for a software change, with the result saved as a dated HTML file outside the repository. Also use when the user wants to install, uninstall, or browse the machine-wide explain-diff CLI.
---

# Explain Diff HTML

Produce a single long-form HTML page that teaches a reader how a specified code change works. Investigate the surrounding system before explaining the diff: the page should make sense to a beginner while still giving an experienced engineer a concise path to the changed behavior.

**Do not hand-write HTML/CSS/JS boilerplate.** Build a JSON content spec and render with `render/render.py`.

## Skill root

`SKILL_ROOT` is the directory that contains this `SKILL.md`. Override with `$EXPLAIN_DIFF_SKILL` if needed.

| Install | Path |
| --- | --- |
| Kairos pack (`kairos skills update`) | `<component>/.agents/skills/explain-diff-html` (also `.claude/skills/explain-diff-html`) |
| This repo | `skills/explain-diff-html` |

## Workflow

1. Identify the change and its scope. Use the current checkout, diff, branch, PR metadata, or user-supplied files as the source of truth. If the target is ambiguous, infer the most likely change from the available context and state the assumption in the page.
2. Explore relevant surrounding code, tests, configuration, callers, data models, and documentation. Trace the old and new paths far enough to explain behavior, not merely file-by-file edits. Prefer checked-in examples and tests over speculation.
3. Build the **full narrative** as a JSON content spec (see **Content spec** below). The spec carries all explanatory prose — `render.py` only adds layout, themes, highlighting, and quiz shuffle. **A thin skeleton spec produces a thin page.**
4. Render and open the page (browser opens automatically on macOS/Linux/Windows):

   ```bash
   ARCHIVE="${EXPLAIN_DIFF_DIR:-$HOME/.local/share/explain-diff}"
   mkdir -p "$ARCHIVE"
   python3 "$SKILL_ROOT/render/render.py" /tmp/my-spec.json \
     -o "$ARCHIVE/YYYY-MM-DD-explanation-<slug>.html" \
     --repo-root /absolute/path/to/workspace
   ```

   Use the current date in `YYYY-MM-DD`. **Always write under** `~/.local/share/explain-diff/` (or `$EXPLAIN_DIFF_DIR`) — never `/tmp` (macOS clears it on reboot). Spec JSON may still live in `/tmp`. Pass `--no-open` only when the user explicitly wants a file without launching the browser.
   **Always set `repo_root`** (in the spec or `--repo-root`) so file mentions become `cursor://` deeplinks.
   Browse later: `"$SKILL_ROOT/cli/explain-diff"` or `explain-diff` if the global CLI is installed. The picker reads **one machine-wide archive** — every component's pages, not just this repo.
   Optional Ask sidecar: `explain-diff serve` (or `open`) starts a localhost process and unlocks an in-page Ask panel. First launch creates `<skill>/.venv` and installs `ask/requirements.txt` if starlette/uvicorn are missing. Cursor chat needs `CURSOR_API_KEY` + `cursor-sdk` (full agent harness). Local Ollama does not — if the daemon is up, the picker lists those tags and defaults to them when the Cursor key is missing. Pages only embed a thin loader + `#explain-diff-meta`; Ask CSS/JS/DOM are served from `/ask/*` when the sidecar is up. Offline `file://` still reads the narrative; if serve is up the loader bounces `file://` → `http://127.0.0.1:7432/p/…?ask=1`. Edit Ask UI in `ask/ui/src` (TypeScript); run `npm run build` in `ask/ui` to regenerate committed `ask/static/ask.{js,css}`.
5. Validate: browser tab opened (unless `--no-open`), file exists, complete HTML, quiz works, code blocks have `white-space: pre`, Prism highlights code on load (`.token.*` spans in `<pre><code>`). Narrative/Prism stay self-contained; Ask UI is the only progressive remote load from localhost serve.
6. **Global CLI (ask once per conversation, never silently).** `kairos skills update` copies this skill into the component; it does **not** put `explain-diff` on `PATH`. After a successful render, or whenever the user asks to install/uninstall/browse the CLI: if `command -v explain-diff` fails, ask whether to install it machine-wide. Yes → `bash "$SKILL_ROOT/cli/install-global.sh"`. Uninstall → `bash "$SKILL_ROOT/cli/uninstall-global.sh"`. That symlink is `~/.local/bin/explain-diff` → this skill's `cli/explain-diff` (retarget by running install again from any component that has the pack). The archive stays `~/.local/share/explain-diff` either way. The entry-point router is `using-explain-diff`; this skill is the implementation.

## Content completeness (required)

The JSON spec must preserve the depth of a hand-written explanation. Before rendering, verify:

| Section | Must include |
|---------|----------------|
| **Background** | Mental model, tables/mappings, component cards, contracts, prior behavior |
| **Intuition** | Toy scenario with concrete values, before/after panels, flow diagram, why the bug happens |
| **Code** | Grouped walkthrough (not a raw diff dump): API contract, key functions, call chain, tests, fix directions, status callout |
| **Quiz** | Five medium-difficulty questions |

**Choosing `code` vs `diff`:** use a `code` block when the reader only needs the
resulting shape (a brand-new type, a new function, a config snippet). Use a `diff`
block when the *change itself* is the point — a modified method, a rewritten
condition, a signature that gained a parameter — because "what it looked like
before" is exactly the context the prose is trying to convey. Do not turn the
whole page into diffs: a walkthrough is still a narrative, not a patch dump.

**Minimum bar:** each of Background, Intuition, and Code should have **at least 6 content blocks** (or equivalent rich `html` section). Include all subsections (`<h3>`) the topic needs — do not collapse subsections to save tokens.

Reference full-content example: render `render/examples/spec-runonce-full.example.json`.

## Content spec (JSON)

Write `/tmp/<slug>-spec.json` (or similar). Minimal shape:

```json
{
  "title": "Issue [3]: runOnce False Rerun",
  "repo_root": "/absolute/path/to/workspace",
  "editor_scheme": "cursor",
  "summary": "One-sentence summary.",
  "meta": "What was inspected; assumptions.",
  "footer": "Generated date, validation notes.",
  "changeset": {"git_range": "main..HEAD", "note": "optional one-liner"},
  "sections": [
    {
      "id": "background",
      "title": "Background",
      "blocks": [
        {"type": "html", "content": "<p>Prose with <code>inline</code> markup.</p>"},
        {"type": "code", "language": "go", "file": "path.go", "line": 42, "end_line": 58, "code": "func main() {}", "caption": "optional"},
        {"type": "file", "path": "internal/pkg/foo.go", "line": 10, "label": "optional prose label"},
        {"type": "html", "content": "<p>Also auto-linked: <code>path.go</code> (~lines 10–20)</p>"},
        {"type": "callout", "variant": "warn", "title": "Edge case", "content": "..."},
        {"type": "table", "headers": ["A","B"], "rows": [["<code>foo</code>","plain"]], "caption": "..."},
        {"type": "panels", "panels": [{"variant": "intended", "title": "Before", "content": "..."}]},
        {"type": "flow", "steps": [{"label": "A", "sub": "detail"}], "arrows": ["data"], "caption": "..."},
        {"type": "cards", "columns": 2, "cards": [{"title": "X", "content": "..."}]},
        {"type": "diff", "language": "go", "file": "internal/pkg/foo.go", "line": 42, "unified": "@@ -42,3 +42,4 @@\n ctx\n-old\n+new\n", "caption": "optional"},
        {"type": "diff", "language": "go", "before": "old code", "after": "new code", "context": 3}
      ]
    }
  ],
  "quiz": [
    {
      "question": "...",
      "explain": "Why the correct answer is right.",
      "distractors": "Why wrong options mislead.",
      "options": [
        {"text": "...", "correct": true},
        {"text": "...", "correct": false}
      ]
    }
  ]
}
```

- **Exactly five** quiz questions.
- In `options`, mark exactly one `"correct": true`. Order does not matter — `render.py` shuffles.
- Supported `language` values for syntax highlighting: `go`, `sql`, `yaml`, `bash`, `json`, `text`.
- **File deeplinks:** with `repo_root` set, `code.file` headers and `<code>path.go</code> (~lines N–M)` in `html` blocks become `cursor://file/...:line` links. Use `line` / `end_line` / `column` on `code` blocks. Set `editor_scheme` to `vscode` if the user remaps `vscode://` to Cursor.
- Full-content reference: `render/examples/spec-runonce-full.example.json` (MAJOR [3], all subsections)
- Schema-only stub: `render/examples/spec-schema.example.json` (structure demo — **not** sufficient alone)

Alternatively, a section may use `"html": "<p>raw section HTML</p>"` instead of `blocks`.

## Diff blocks (side-by-side)

A `diff` block renders an aligned two-column view with per-line numbers, word-level
intra-line highlighting, and a **Side by side / Unified** toggle. Syntax highlighting
survives: each column is tokenised by Prism as one document and only then split per
line, so block comments and multi-line strings stay correct.

Supply the change in exactly one of two ways:

| Field | Use when |
|-------|----------|
| `unified` | You have a real patch. Paste `git diff <range> -- <file>` output. **One file per block** — hunk headers give the `⋯` gap rows their function context for free. |
| `before` + `after` | You are contrasting two versions of a snippet that has no patch (a rewritten helper, a hand-built "what it used to be"). `render.py` diffs them with `difflib`. |

Optional fields: `language`, `file` (+ `line` / `end_line` / `column`, for the editor
deeplink and the changeset anchor), `caption`, `context` (lines of unchanged context
around each change for `before`/`after`; `"all"` keeps everything; default `3`),
`word_diff` (default `true`), `view` (`"split"` — default — or `"unified"`), and
`mode` (`"new"` / `"removed"` / `"split"`, normally inferred).

- A block with no removals is auto-detected as a **new file**: it renders as one
  annotated column with a badge instead of a half-empty split.
- Narrow viewports open in unified; an explicit click on the toggle still wins.
- Getting the patch: `git diff <base>..HEAD -- <path>` and put the output in `unified`.

## Changeset header (PR-style file list)

Set the top-level `changeset` key to print a collapsible "files changed" summary —
status letter, path, `+N −M`, and a proportion bar, plus totals. It is deliberately
**a list only**; the per-file walkthrough belongs in the body, in whatever `diff` /
`code` blocks the narrative calls for.

```json
"changeset": {"git_range": "fd55f6b..HEAD", "note": "optional", "collapsed": true}
```

- `git_range` runs `git diff --numstat` / `--name-status` in `repo_root`. If git
  fails the page still renders, with a short note in place of the list.
- Or pass the rows yourself: `"files": [{"path": "a.go", "added": 12, "removed": 3, "status": "M"}]`.
- `collapsed` defaults to `true` above 12 files.

**Covered files.** A row whose path matches the `file` of some `diff` or `code`
block in the body is marked as *covered*: accent bar, `◆` marker, and a link that
jumps to that passage (which flashes on arrival) instead of out to the editor. A
`diff` block wins over a `code` block for the same path. The summary line carries an
`N explained` chip that filters the list down to those rows — the way to find the
handful of files the narrative actually discusses inside a 100-file changeset.

**This is a reason to set `file` on your blocks.** Every `diff` / `code` block that
names the file it comes from becomes a navigable destination from the changeset.

**Placement.** The changeset sits in the page rail together with the table of
contents: stacked above it in the normal layouts, and in the **Dual page** preset the
whole rail becomes a sticky left column, so the file list stays reachable while
reading. The rail drops the churn bars and the note, and moves the counts under the
path, because a 17rem column cannot fit them on one line.

## Required page structure

Rendered output always includes:

1. **Background**
2. **Intuition**
3. **Code**
4. **Quiz** (five questions)

Plus title, summary, table of contents, theme picker, and footer from the spec.

Use smooth transitions, plain language, and precise systems-oriented prose. Explain jargon on first use. Keep the page readable on phones. One continuous page (no top-level tabs).

## Diagrams and examples

Use block types (`panels`, `flow`, `cards`, `table`) — never ASCII art in the spec.

## Quiz quality rules

Treat quiz design as part of the explanation.

- **Do not rely on option order in the JSON.** `render.py` assigns balanced target slots and shuffles distractors with `secrets` — correct answers won't sit in the same position every run.
- Keep options comparable in length, grammar, and specificity.
- Make distractors plausible — tied to real misunderstandings.
- Ask about behavior, causality, contracts, edge cases, or trade-offs.
- Feedback reveals only after selection. No `title` attributes or ARIA text that expose correctness before click.

## Rendering features (handled by render.py)

- **Syntax highlighting** — vendored [Prism.js](https://prismjs.com/) (`render/vendor/*.js`) inlined into the page; Python emits escaped source in `<pre><code class="language-go">`, browser runs `Prism.highlightAll()`. Theme colors map via CSS variables on `.token.*` classes.
- **Dark / light / Kanagawa themes** — default Kanagawa (warm ink palette); `<select>` picker stores preference in `localStorage`. Light theme: warm paper/sepia. Dark: IDE-like palette.
- **Typography** — light mode uses Palatino/Charter/Georgia stack; code stays monospace.
- **Browser handoff** — after render, `render.py` opens the HTML in the system default browser (`open` on macOS). Use `--no-open` to skip.
- **Editor deeplinks** — `cursor://file/<abs-path>:<line>` on file headers and inline mentions; opens the file at that line in Cursor when clicked.
- **Diffs** — `diffview.py` turns `unified` / `before`+`after` into aligned rows (pairing, word ranges, gap rows); the page's diff runtime highlights each column and builds the DOM. Diff cells use `white-space: pre-wrap` on purpose — the CSS grid keeps both sides aligned even when a long line wraps.

## Agent constraints

- **Always run `render.py` without `--no-open`** unless the user asks not to open a tab. Do not hand the user a path and expect them to find the file.
- **Always pass `repo_root`** (workspace absolute path) so file references are clickable in Cursor.
- Escape is handled by `render.py` for `code` blocks, quiz text, and table captions. In `html`, `table` cells/headers, `callout`, `panels`, and `cards` you author safe markup directly (e.g. `<code>`).
- Do not claim behavior the inspected source does not support.
- Distinguish observed facts from interpretation in `meta` / `footer`.

## Final handoff

Confirm the browser tab opened. Return the exact absolute path as a `file://` link as backup. State what was inspected and validation limitations.
