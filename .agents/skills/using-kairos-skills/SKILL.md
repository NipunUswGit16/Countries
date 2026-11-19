---
name: using-kairos-skills
description: Use FIRST when planning, scaffolding, implementing, modifying, refactoring, testing, or reviewing anything in a Kairos component built from this template — before reading code, before writing a plan, before any other skill. Routes the agent to the correct kairos-* skill and forbids guessing the architecture from existing code alone. Triggered whenever the user mentions adding a feature, endpoint, command, event, response, handler, repository, service, domain entity, master data, AppConfig, migration, topic, schema, scaffold, or says "implement", "build", "plan", "design", or "review" anything in this repo.
---

# Using Kairos Skills

This is a **Kairos component repository**. It ships with a curated set of `kairos-*` skills (in `.agents/skills/`, also visible via `.claude/skills/`) that encode the platform's architecture, naming conventions, generator pipeline, security invariants, and test patterns. **Reading the existing source code is not a substitute for reading these skills.** The codebase is a starting point; the skills are the contract.

## Before you start

Run these in the component root before routing:

- **Mid-migration.** If `grep -qE '^[[:space:]]+in_progress:' .kairos/manifest.yaml 2>/dev/null` matches (a `template.in_progress` or `frontend.in_progress` block) and the request is to continue, resume, abort or cancel that update, route to `kairos-component-update`. For any other request, stop: file checks give mixed answers mid-migration. Ask the author to finish (`kairos-component-update`, continue) or abort that update first. No match, or no manifest: continue.
- **Facade.** Run the check in `reference/facade.md`. Facade: only the skills that file lists apply; every other skill stops at its own § Before you start. Tell the author the other rows do not apply, and that an application runtime belongs in a component (`kairos component promote --help`). Not a facade: route as normal.
- **kairos-gen version.** If `go.mod` has a `cmd/kairos-gen` line, the version is `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen`. Otherwise run `kairos-gen --version` and teach that version's behaviour.

While you work:

- **The ground moves.** After any `go get` or `kairos-component-update` during the task, re-run the checks the skills made earlier.
- **The component is newer than the skill.** If a version in `go.mod` is newer than any the skill names, or the code contradicts the skill, trust the code and tell the author the skill may be behind.

## ⚠️ The Rule

**Before planning, designing, or implementing anything in this repository, you MUST invoke the relevant `kairos-*` skill(s).** This applies to:

- Implementation plans, regardless of how they are produced — from a raw prompt, from a generic planning/brainstorming/execution framework (e.g. BMAD, superpowers, or any other skill pack), or from any other workflow.
- Scaffolding a new feature, component, or vertical slice.
- Adding or modifying any of: domain entity, repository, service, API endpoint, event, command, command response, event handler, command handler, command response handler, master data entity, AppConfig field, SQL migration, topic subscription.
- Writing or updating tests for any of the above.
- Reviewing a branch or PR.

If you think there is even a 1% chance a `kairos-*` skill applies, you MUST invoke it. **This is non-negotiable.** Following the skill is cheaper than discovering the convention by re-reading the code, and re-reading the code will routinely miss invariants (the JSONB camelCase rule, double validation, ETag handling via `ForUpdate`, the per-runtime `ServicesFactory` mirrors, the `+kairos:sql:lib:` directives, etc.).

## Why this overrides "let me look at the code first"

These skills exist precisely because:

- The convention is enforced by code generation (`kairos-gen` via `make generate`) — the skills tell you what to write so generation produces the right SQL and topic config.
- Several rules (e.g. JSONB field naming, partition-key choice, `Send` vs `Publish` vs `SendCommandResponse`) are not visible from any single file.
- The architecture has multi-sided invariants (the `ServicesFactory` and `AppConfig` mirrors across the client-API and event-handler runtimes, plus the integration-API runtime if `cmd/integration-api/main.go` exists; double validation on send + receive) that source code alone won't reveal.
- If you plan from the existing code you will produce a plan that omits the generator step, the handler registration, or the security checklist. The skills don't.

## Interaction with general-purpose agent frameworks

This skill is content-agnostic to whatever planning/execution framework the agent is using. The rule is the same whether you are:

- Operating from a raw user prompt with no skill pack at all.
- Using a generic process framework like BMAD, superpowers, or any other plugin that provides planning/brainstorming/execution/review skills.
- Using an in-house workflow defined elsewhere in the agent's configuration.

Those frameworks tell you **how** to plan, brainstorm, dispatch subagents, or execute. This skill (and the specific `kairos-*` skill it routes you to) tells you **what content** the plan must contain for a Kairos component. **Use both.** The generic process skill runs first to structure the work; the `kairos-*` skill runs before any concrete step that touches Kairos code, schemas, or generated artifacts.

If a generic framework's plan does not mention the relevant `kairos-*` skill(s), the plan is incomplete — re-plan with the skill folded in. Don't proceed on a plan that was produced by reading existing source code alone.

When delegating to subagents:

- Prefer the dedicated `kairos-*` subagent types (`kairos-scaffold-feature`, `kairos-create-domain-entity`, `kairos-create-service`, `kairos-create-api-endpoint`, `kairos-create-command`, `kairos-create-event`, `kairos-create-event-handler`, `kairos-create-repository`, `kairos-test-service`, `kairos-test-api-endpoint`, `kairos-test-event-handler`, `kairos-test-functional-client-api`, `kairos-test-functional-event-handler`, `kairos-review`, etc.) over `generalPurpose`. They embed the skill content directly and will not "improvise" from the existing code.
- If you must use `generalPurpose`, pass an explicit instruction in the subagent prompt: *"You MUST read and follow `.agents/skills/<relevant-skill>/SKILL.md` before doing anything."*

## Routing table — pick the right skill

Match the user's intent to the skill below, then invoke that skill before doing anything else.

### High-level / orchestration

| Intent | Skill |
|---|---|
| "Scaffold an end-to-end feature", new vertical slice, big initial component build-out | `kairos-scaffold-feature` |
| "Plan / design a Kairos feature" | `kairos-scaffold-feature` (for the structure of the plan) + the specific skills below |
| "Review my changes / this branch / this PR" | `kairos-review` |
| "Explain this diff / PR / change as interactive HTML" | `explain-diff-html` |
| "Set up local Kairos / get a token / install tools" | `kairos-use-cli` |
| "Update / migrate this component to the latest template or frontend", continue or abort such an update | `kairos-component-update` |

### Domain & persistence

| Intent | Skill |
|---|---|
| New domain model / aggregate root | `kairos-create-domain-entity` |
| New repository / persistence for an entity | `kairos-create-repository` |
| New business-logic service / move logic out of a handler | `kairos-create-service` |
| Tests for a service | `kairos-test-service` |
| Add or change an `AppConfig` field / env var / timeout | `kairos-configure-appconfig` |
| Reasoning about tenancy, JSONB, ETag, schema-per-tenant | `kairos-database-model` (reference) |
| Generated SQL, `+kairos:sql:` directives, `sql/0.libs` / `sql/1.gen` / `sql/3.custom`, missing `event_outbox` / `idempotency` table | `kairos-sql-lifecycle` (reference) |
| Kafka topic subscriptions, `chart(s)/resources/topic-config.json`, "topic not appearing", master-data topic registration | `kairos-topic-subscriptions` (reference) |
| Just "what does `make generate` do?" / general code-gen orientation | `kairos-sql-lifecycle` + `kairos-topic-subscriptions` (both halves) |

### REST API surface

| Intent | Skill |
|---|---|
| New REST endpoint / Fiber handler, on either the client API or the integration API | `kairos-create-api-endpoint` |
| New paginated list endpoint | `kairos-create-paginated-endpoint` |
| Endpoint returns a translated status message / toast (`messageId` + `messageParams` envelope) | `kairos-create-api-endpoint` + `response-library-go-endpoint` (frontend: `response-library`) |
| Tests for an API endpoint (`apitest` for client API, `integrationapitest` for integration API) | `kairos-test-api-endpoint` |
| Functional tests for client API behavior | `kairos-test-functional-client-api` |
| Custom loader for the integration API's bulk-load endpoint (`POST /api/core/v1/load`), `+kairos:sql:loader:disable` | `kairos-create-loader` |

### Messaging — schemas (what your component owns)

| Intent | Skill |
|---|---|
| New `*CommandV1` your component will receive + its handler | `kairos-create-command` |
| New `*EventV1` your component will emit | `kairos-create-event` |
| New `*CommandResponseV1` your component returns | `kairos-create-command-response` |
| New master data `*EntityV1` your component owns | `kairos-create-masterdata-entity` |

### Messaging — handlers (reacting to others)

| Intent | Skill |
|---|---|
| Handler reacting to a `*EventV1` (from another component, or a local self-subscription for read-model maintenance) | `kairos-create-event-handler` |
| Handler for a command response your component received | `kairos-create-command-response-handler` |
| Replicate / consume master data from another component | `kairos-register-masterdata-mapper` |
| Tests for any event / command / response handler | `kairos-test-event-handler` |
| Functional tests for event-handler behavior | `kairos-test-functional-event-handler` |

### Messaging — sending

| Intent | Skill |
|---|---|
| Publish an event (broadcast, past-tense) | `kairos-publish-event` |
| Send a command (directed, imperative) | `kairos-send-command` |
| Reasoning about `Send` vs `Publish` vs `SendCommandResponse`, partition keys, double validation, at-least-once | `kairos-messaging-model` (reference) |

### Cross-component

| Intent | Skill |
|---|---|
| Integrate with another Kairos component (consume its events, send it commands) | `kairos-cross-component-integration` |

### Authentication gateway

| Intent | Skill |
|---|---|
| Add, migrate, troubleshoot, or review Nexus Auth Gateway, auth-gateway sidecar injection, local OAuth login, or `/auth` and `/api` Helm routing | `kairos-auth-gateway-migration` |

### Go code style (cross-cutting)

| Intent | Skill |
|---|---|
| Idiomatic Go style, error wrapping, context/concurrency discipline, allocation/GC awareness, testability, import grouping | `kairos-go-developer` (subordinate to the structural skills above) |

`kairos-go-developer` is a **style** skill, not a structural one. It governs *how* the Go you write reads; the `kairos-*` skills above govern *what* you must write. On any conflict, the structural skill wins. Invoke `kairos-go-developer` **in addition to** the relevant structural skill(s) — never instead of them.

### Web UI

For frontend work, UI-facing features, or full app requests that include a Kairos component's `web/` app, you **SHOULD** use `using-kairos-web-skills` before doing anything.

## Mandatory workflow

For every Kairos task:

1. **Identify intent** from the user's message and the routing table above. If multiple rows match (e.g. "add a CreateOrder endpoint that publishes OrderCreatedV1"), invoke each relevant skill — they compose.
2. **Invoke the skill(s)** before reading the codebase further. Announce which skill you're using and why ("Using `kairos-create-api-endpoint` to add the POST /orders route").
3. **Go code mandate.** If the task creates or modifies any `.go` file (`internal/`, `cmd/`, `pkg/`, or `*_test.go`), you **MUST** also invoke `kairos-go-developer` in the same turn as the structural skill(s) — **before writing code**. Announce both (e.g. "Using `kairos-create-service` for the platform contract and `kairos-go-developer` for Go idioms"). This is not optional: structural skills govern *what* to write; `kairos-go-developer` governs *how*. On conflict, the structural skill wins.
4. **Follow the skill exactly.** Skills in this repo are *rigid* — they encode platform contracts, not stylistic preferences. Don't paraphrase or shortcut.
5. **Run the post-work commands** the skill specifies (typically `make generate` if schemas/handlers/SQL changed, then `make lint`, then `make test`). See `AGENTS.md` § "After Completing Work".
   If `git rev-parse --abbrev-ref HEAD` is not `main`, run `make lint ARGS=--all` and `make test ARGS=--all`: off `main` the toolkit tests only modules changed in commits, so uncommitted work exits 0 having run nothing. On `main`, plain `make lint` / `make test`.
   If `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/toolkit` is below v1.0.44 and `bash --version` reports 3.x, those targets fail off `main`: put bash 4 or later first on `PATH`, or tell the author.
6. **If you're unsure which skill applies**, default to invoking `kairos-scaffold-feature` (it links to all the others) or `kairos-review` (to check work). Don't invent your own workflow.

## Red flags — these thoughts mean STOP

| Thought | What to do instead |
|---|---|
| "Let me read the existing code first to understand the pattern" | Invoke the relevant `kairos-*` skill first — the code may already deviate. |
| "I'll grep for similar handlers and copy the structure" | Invoke `kairos-create-event-handler` / `kairos-create-command` first. |
| "This is a small change, the skill is overkill" | Invariants apply to small changes too (JSONB camelCase, ETag, double validation). |
| "I already know the Kairos pattern from training data" | The platform evolves; skills are the source of truth in this repo. |
| "The plan I produced earlier didn't mention the skills" | Re-plan with the skills. The earlier plan is stale. |
| "I can skip `make generate` because the SQL looks unchanged" | Schema/handler edits change `topic-config.json` even when SQL looks unchanged. Always re-run when the skill says so. |
| "I'll just dispatch a generalPurpose subagent" | Prefer the `kairos-*` subagent type for that task. |
| "The structural skill already has Go examples" | Still invoke `kairos-go-developer` — examples don't cover error wrapping, ctx discipline, goroutine lifecycle, or import grouping. |
| "This is just a Go style tweak, I don't need kairos-go-developer" | Any `.go` edit in this repo must follow house idioms — invoke `kairos-go-developer`. |

## What "following the skill" looks like

For every `kairos-*` skill you invoke, treat its checklist (if any) as a TODO list and tick items as you complete them. Don't declare the task done until every item is ticked **and** `make lint` and `make test` pass (with `ARGS=--all` off `main`, see step 5) (and `make generate` was run if schemas/handlers/SQL changed). This matches `AGENTS.md` § "After Completing Work".
