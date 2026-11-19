---
name: using-kairos-web-skills
description: Use FIRST when planning, scaffolding, implementing, modifying, refactoring, testing, or reviewing anything in a Kairos Web located in `/web` directory — before reading code, before writing a plan, before any other skill. Routes the agent to the correct kairos-web-* skill and forbids guessing the architecture from existing code alone. Triggered whenever the user mentions adding a feature, api, react, ui, web, web components, scaffold, or says "implement", "build", "plan", "design", or "review" anything in this repo.
---

# Using Kairos Web Skills

This is a sub directory of **Kairos component repository** containing web app related code for the **Kairos component**. It ships with a curated set of `kairos-web-*` skills and (in `.agents/skills/`, also visible via `.claude/skills/`) that encode the platform's frontend architecture, naming conventions, security invariants, and test patterns. **Reading the existing source code is not a substitute for reading these skills.** The codebase is a starting point; the skills are the contract.

## Before you start

Run these in the component root. Stop at the first match and tell the author; do not scaffold or hand-patch around it.

| Check | Result | Do |
|---|---|---|
| The check in `../using-kairos-skills/reference/facade.md` | facade | A facade has no `web/`. Stop. The `kairos-web-*` skills do not apply; that file says which skills do. |
| `test -f web/package.json` | fails | `web/` is only the template shell (Dockerfile, configs, entrypoint) with no React app. Stop. The app comes from bootstrapping the frontend template with `kairos-component-update`. |
| `grep -qE '^[[:space:]]+in_progress:' .kairos/manifest.yaml` | matches (under `frontend:` or `template:`) | A migration is half done and file checks give mixed answers. Stop. Ask the author to finish it (`kairos-component-update` continue) or abort it first. A missing manifest means no migration; continue. |
| The `@ifs-kairos/react` version check below | exits 1 | `@ifs-kairos/react` is missing or below 0.10.0 (a `0.10.0-beta` counts as below). The frontend is below 0.10 (temp-auth, Helix 0.3, older theme and translation APIs). The `kairos-web-*` skills do not apply. Stop. Tell the author to update the frontend with `kairos-component-update`. Having `@ifs-kairos/auth` in `package.json` does not prove 0.10: it is published from 0.8.0 and sits next to react 0.9.x. |

The `@ifs-kairos/react` version check (exit 0 means ≥ 0.10.0):

```bash
node -e 'const v=require("./web/package.json").dependencies?.["@ifs-kairos/react"]??"";const m=v.match(/(\d+)\.(\d+)\.(\d+)(-)?/);process.exit(m&&m[1]*1e6+m[2]*1e3+m[3]*1-(m[4]?0.5:0)>=10000?0:1)'
```

All three pass: continue. If a package version in `web/package.json` is newer than any a `kairos-web-*` skill names, or the code contradicts the skill, trust the code and tell the author the skill may be behind. After a `kairos-component-update` run during the task, re-run these checks and the checks the skills made earlier.

## ⚠️ The Rule

**Before planning, designing, or implementing anything UI related in this repository, you MUST invoke the relevant `kairos-web-*` skill(s).** This applies to:

- Implementation plans, regardless of how they are produced — from a raw prompt, from a generic planning/brainstorming/execution framework (e.g. BMAD, superpowers, or any other skill pack), or from any other workflow.
- Scaffolding a new feature, component, or vertical slice.
- Adding or modifying any of: UI component, Frontend routing, Input validation, API calls, Hooks, and State Management.
- Writing or updating tests for any of the above.
- Reviewing a branch or PR.

If you think there is even a 1% chance a `kairos-web-*` skill applies, you MUST invoke it. **This is non-negotiable.** Following the skill is cheaper than discovering the convention by re-reading the code.

## Routing table — pick the right skill

Match the user's intent to the skill below, then invoke that skill before doing anything else.

| Intent | Skill |
|---|---|
| Web frontend development, UI Elements, Helix web components and React Component | `kairos-web-build-ui` (reference) |
| API calls, HTTP Request, EventSteams and Request state handling | `kairos-web-call-api` (reference) |
| Web frontend theming, Helix design tokens | `kairos-web-theme` (reference) |
| Web frontend routing, pages and routing hierarchy | `kairos-web-create-route` (reference) |
| Add, register, remove or rename a Helix icon in the web app | `kairos-web-use-helix-icon` (reference) |
| Add frontend auth-gateway auth or fix `authBasePath`, callback routes, protected routes, bearer headers, or `useAuth` access-token usage | `kairos-web-auth` |
| Implement a Figma frame or design in the web app | `kairos-web-figma-to-code` |
| Translate, localize or add i18n to web UI text | `kairos-client-translations` |
| Show a translated server status message or toast for an endpoint (`messageId` envelope, `response.config.ts`) | `response-library` (Go side: `response-library-go-endpoint`) |
| Look up a Helix component API, tokens, density | `using-helix-skills` |

## Interaction with other Kairos component areas

This skill is focused on **Kairos web (Frontend) development** which is located in `/web` directory in a **Kairos component repository**. But you might need to implement more than just frontend.

Example:

- Creating new API to use it in frontend.
- Change api contract due to frontend changes.
- Define new events to be consumed in frontend via SSE.

For such scenarios you **SHOULD** use `using-kairos-skills` before doing anything.

## Mandatory workflow

For every Kairos task:

1. **Identify intent** from the user's message and the routing table above. If multiple rows match, invoke each relevant skill — they compose.
2. **Invoke the skill(s)** before reading the codebase further. Announce which skill you're using and why ("Using `kairos-web-call-api` to call the POST /orders route").
3. **Follow the skill exactly.** Skills in this repo are *rigid* — they encode platform contracts, not stylistic preferences. Don't paraphrase or shortcut.
4. **Run the web done checks** after every change: `pnpm -C web typecheck`, `pnpm -C web lint` and `pnpm -C web test:ci`. Run the other post-work commands the skill specifies (typically `make deploy` to deploy to the local cluster). See `AGENTS.md` § "After Completing Work".
5. **If you're unsure which skill applies**, start from `kairos-web-build-ui`, which links to the others. Don't invent your own workflow.

## Red flags — these thoughts mean STOP

| Thought | What to do instead |
|---|---|
| "Let me read the existing code first to understand the pattern" | Invoke the relevant `kairos-web-*` skill first — the code may already deviate. |
| "I'll copy a similar component and adapt it" | Invoke `kairos-web-build-ui` first. |
| "This is a small change, the skill is overkill" | Invariants apply to small changes too (Helix components, design tokens, `@ifs-kairos/net`). |
| "I already know the Kairos pattern from training data" | The platform evolves; skills are the source of truth in this repo. |
| "The plan I produced earlier didn't mention the skills" | Re-plan with the skills. The earlier plan is stale. |
| "I'll just dispatch a generalPurpose subagent" | Prefer a `kairos-web-*` skill for that task. |

## What "following the skill" looks like

For every `kairos-web-*` skill you invoke, treat its checklist (if any) as a TODO list and tick items as you complete them. Don't declare the task done until every item is ticked **and** `pnpm -C web typecheck`, `pnpm -C web lint` and `pnpm -C web test:ci` pass. This matches `AGENTS.md` § "After Completing Work".
