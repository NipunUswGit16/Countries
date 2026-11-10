---
name: using-explain-diff
description: Use FIRST when the user wants an interactive HTML explanation of a diff, branch, PR, or code change, or to install, uninstall, browse, or serve the machine-wide explain-diff CLI / Ask sidecar — before writing HTML, before inventing a renderer, before any other skill. Routes to explain-diff-html. Triggered by "explain this diff", "explain this PR", "explain this change", "explain-diff", "install explain-diff", "uninstall explain-diff", "browse explanations", "explain-diff serve", or Ask sidecar.
---

# Using Explain Diff

This is the **entry-point skill** for the explain-diff pack. Implementation lives in `explain-diff-html` (JSON content spec + `render/render.py`, plus the machine-wide CLI and Ask sidecar). **Do not hand-write an HTML explanation, invent a renderer, or guess the CLI layout.**

## The Rule

**Before explaining a change, installing/uninstalling the CLI, browsing the archive, or starting the Ask sidecar, you MUST invoke `explain-diff-html`.** This applies to:

- Interactive HTML explanations of a diff, branch, PR, or user-supplied change — regardless of how the request was framed (raw prompt, planning skill, review follow-up).
- Installing or uninstalling the machine-wide `explain-diff` CLI (`~/.local/bin/explain-diff`).
- Browsing previously generated pages in `~/.local/share/explain-diff` (or `$EXPLAIN_DIFF_DIR`).
- Starting or troubleshooting `explain-diff serve` / the in-page Ask panel.

If you think there is even a 1% chance `explain-diff-html` applies, you MUST invoke it. **This is non-negotiable.** Following the skill is cheaper than rediscovering the archive path, the spec shape, or the CLI install scripts.

## Routing table

Match the user's intent, then invoke that skill before doing anything else.

| Intent | Skill |
|---|---|
| "Explain this diff / PR / change / branch as interactive HTML" | `explain-diff-html` |
| "Install / uninstall the explain-diff CLI" | `explain-diff-html` |
| "Browse / list / open generated HTML explanations" | `explain-diff-html` |
| "Start Ask sidecar / `explain-diff serve`" | `explain-diff-html` |

Kairos implementation, scaffolding, or review work is **not** this skill — use `using-kairos-skills` (or `using-kairos-web-skills` for `web/*`). This skill only covers the explanation page and the CLI/sidecar around it.

## Interaction with general-purpose agent frameworks

Generic planning/execution frameworks (BMAD, superpowers, etc.) tell you **how** to structure the work. This skill tells you **what** to invoke for an explain-diff request. **Use both.** If a plan says "write an HTML file" or "summarize the diff in markdown" instead of invoking `explain-diff-html`, the plan is incomplete — re-plan.

When delegating to subagents, pass an explicit instruction: *"You MUST read and follow the `explain-diff-html` skill before doing anything."*

## Mandatory workflow

1. **Identify intent** from the routing table.
2. **Invoke `explain-diff-html`** before writing files or running ad-hoc commands. Announce it ("Using `explain-diff-html` to render the PR explanation").
3. **Follow that skill exactly.** JSON spec + `render.py`. Never hand-written page HTML/CSS/JS. Archive under `~/.local/share/explain-diff/` (or `$EXPLAIN_DIFF_DIR`), never `/tmp`.
4. **CLI.** `kairos skills update` copies the skill; it does **not** put `explain-diff` on `PATH`. After a successful render, or whenever the user asks to install/uninstall/browse: if `command -v explain-diff` fails, ask whether to install machine-wide. Yes → the install script in `explain-diff-html`. Uninstall → the uninstall script there.

## Red flags — these thoughts mean STOP

| Thought | What to do instead |
|---|---|
| "I'll just write an HTML file / dump the diff into markdown" | Invoke `explain-diff-html` and build a JSON spec. |
| "I know how to render a nice page" | The renderer, archive path, quiz shuffle, and Ask loader are the contract. Follow the skill. |
| "I'll put the output in `/tmp` or the repo" | Always `~/.local/share/explain-diff/` (or `$EXPLAIN_DIFF_DIR`). |
| "I'll add another row to `using-kairos-skills` for the CLI" | This skill is the router. `explain-diff-html` is the implementation. |
| "I'll create another skill for install/browse/serve" | Already covered here + `explain-diff-html`. |
| "The plan I produced earlier didn't mention `explain-diff-html`" | Re-plan with the skill folded in. |

## What "following the skill" looks like

Treat the `explain-diff-html` checklist as a TODO list. Don't declare the task done until the page is rendered, the browser tab opened (unless the user asked `--no-open`), and the CLI install question has been asked once if `explain-diff` is not on `PATH`.
