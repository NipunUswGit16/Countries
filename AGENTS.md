# AI Agent instructions for Kairos Component development

This file defines the **always-on** invariants for every Kairos component built from this template.

---

## ⚠️ CRITICAL: Use the `kairos-*` skills — DO NOT IMPROVISE FROM CODE

Kairos ships a curated set of **`kairos-*` agent skills**, distributed and installed separately from this template. They encode the platform's architecture, naming conventions, generator pipeline, security invariants, and test patterns. **They are the source of truth for "how things are done here".** This repository assumes they are installed and available to your agent runtime (via Skills, subagent types, or whatever skill mechanism your runtime supports).

**Non-negotiable rules for any agent working in this repository:**

1. **Before planning, designing, or implementing ANY change, invoke the relevant `kairos-*` skill(s) first.** This applies regardless of how the agent is operating — whether driven only by a raw prompt, by a generic planning/brainstorming/execution framework (e.g. BMAD, Superpowers, or any other skill pack), or by an in-house workflow. Those frameworks tell the agent *how* to plan or execute; the `kairos-*` skills tell it *what content* the plan must contain for this repository. Use both.
2. **Start every Kairos task by invoking the `using-kairos-skills` skill** (part of the same externally-distributed `kairos-*` skill pack). It contains the routing table from intent → specific skill. If you skip it, you will miss invariants that aren't visible from any single file (JSONB `camelCase`, ETag via `ForUpdate`, the per-runtime `ServicesFactory` mirrors, the `+kairos:sql:lib:` directives, `Send` vs `Publish` vs `SendCommandResponse`, double validation, etc.).
3. **Reading the existing code is not a substitute for reading the skill.** The code is a starting point and may have drifted; the skill is the contract. "Let me look at how it's done elsewhere" is a red flag — invoke the skill first, then look at code through that lens.
4. **When delegating to subagents, prefer the dedicated `kairos-*` subagent types** (`kairos-scaffold-feature`, `kairos-create-domain-entity`, `kairos-create-service`, `kairos-create-api-endpoint`, `kairos-create-command`, `kairos-create-event`, `kairos-create-event-handler`, `kairos-create-repository`, `kairos-test-service`, `kairos-test-api-endpoint`, `kairos-test-event-handler`, `kairos-test-functional-client-api`, `kairos-test-functional-event-handler`, `kairos-review`, `kairos-cross-component-integration`, `kairos-sql-lifecycle`, `kairos-use-cli`, etc.) over `generalPurpose`. They embed the skill content directly. If you must use `generalPurpose`, instruct it explicitly: *"You MUST read and follow the `<relevant-skill>` skill before doing anything."*

### If the `kairos-*` skills are not available

If you cannot locate the `kairos-*` skills in your runtime — including `using-kairos-skills` itself — the user has not installed the skill pack. In that case:

1. **Tell the user, once, at the start of the response.** Recommend they install the `kairos-*` skill pack (`kairos skills update`) before doing further Kairos work, and explain that without them you are working from `AGENTS.md` alone.
2. **Proceed with the task**, but treat the contract as degraded:
   - Lean on the invariants spelled out in this `AGENTS.md` (PostgreSQL naming, the `+kairos:sql:lib:` directives, the architecture rules, the security invariants, the multi-tenancy model).
   - Be more conservative than usual: prefer asking the user a clarifying question over guessing on architecture-shaped decisions (new entity? new command vs event? new handler registration? new SQL directive?), since those are exactly the spots the missing skills would have pinned down.
3. **Do not block trivial work** (typo fixes, comment edits, doc updates) on the missing skills — just proceed.

### Quick routing table — common entry points

| You are about to… | Skill to invoke first |
|---|---|
| Learn implementing master-data production | `kairos-create-masterdata-entity`; hands-on walkthrough: [`docs/cdc/debezium/ADDING-MASTERDATA-ENTITIES.md`](docs/cdc/debezium/ADDING-MASTERDATA-ENTITIES.md) |
| Plan / scaffold a full feature or vertical slice | `kairos-scaffold-feature` |
| Add a domain entity / repository / service / endpoint | the matching `kairos-create-*` skill |
| Add or handle a `*CommandV1` / `*EventV1` / `*CommandResponseV1` | the matching `kairos-create-*` or `kairos-*-handler` skill |
| Integrate with another Kairos component | `kairos-cross-component-integration` |
| Write tests | `kairos-test-service` / `kairos-test-api-endpoint` / `kairos-test-event-handler` |
| Verify externally observable runtime behavior / write functional tests | `kairos-test-functional-client-api` / `kairos-test-functional-event-handler` |
| Review a branch / PR | `kairos-review` |

This is a quick reference, not the source of truth. **Always invoke `using-kairos-skills` first** — it has the full routing table including the reference skills (`kairos-database-model`, `kairos-messaging-model`, `kairos-sql-lifecycle`, `kairos-topic-subscriptions`), `kairos-go-developer`, and `kairos-use-cli`. Multiple rows can apply to one task; invoke each relevant skill — they compose.

---

## Agent behavior

These rules govern how the agent operates *before and during* any change. They sit alongside the Kairos-specific invariants below — they don't override them. In particular, "minimal change" never means skipping a mandated layer (service, repository, `Validate()`, mirrored `ServicesFactory`, etc.); see *Non-Negotiable Architecture Rules*.

### Think before coding

Don't assume. Don't hide confusion. Surface tradeoffs.

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations of the request exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### Surgical changes

Touch only what you must. Clean up only your own mess.

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:

- Remove imports, variables, and functions that *your* changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the user's request, or to a Kairos invariant the request forced you to satisfy (e.g. mirroring `ServicesFactory`, running `make generate`).

---

## ⚠️ CRITICAL: PostgreSQL naming invariants

These are the always-on invariants every change must respect. For rationale, examples, and design guidance (splitting fat aggregates, human-facing identifiers, when to add extra columns), invoke the **`kairos-database-model`** skill.

- **Tables**: `snake_case`, pluralized (e.g. `todos`, `user_profiles`).
- **Column structure**: exactly 2 columns on every entity table — `id UUID PRIMARY KEY` (UUIDv7) and `data JSONB NOT NULL`. Extra columns are a rare, justified optimization, not the default.
- **JSONB field names**: `camelCase` (e.g. `taskId`, `createdAt`). Never `snake_case` inside `data`.
- **Child-table foreign keys**: live inside the child's `data` as a `camelCase` field holding the parent's `id` UUID. Never a raw FK column.
- **Human-readable IDs** (order numbers, SKUs): live inside `data`. Never repurpose the `id` column, never add a separate human-id column.

---

## ⚠️ CRITICAL: `+kairos:sql:lib:` directives — DO NOT DELETE

Two directives are required for SQL generation to work. Removing either one silently breaks migrations:

- `cmd/client-api/main.go` **and** `cmd/integration-api/main.go` must retain `// +kairos:sql:lib:bitbucket.org/ifs-pd/nga-event-outbox/pkg/eventsender` (provides `event_outbox`).
- `cmd/event-handler/main.go` must retain `// +kairos:sql:lib:bitbucket.org/ifs-pd/kairos-component-common/event-handler` (provides `idempotency`).

For how the directive pipeline works, the full `+kairos:sql:` directive set, and troubleshooting, invoke the **`kairos-sql-lifecycle`** skill.

---

## File naming conventions

- **Go files**: snake_case (e.g. `order_service.go`, `routes_test.go`)
- **Schema files**: kebab-case (e.g. `create-order-command-v1.go`, `order-created-event-v1.go`)
- **Test files**: `{source}_test.go`

---

## Non-Negotiable Architecture Rules

These invariants apply to every change. Breaking any of them is a code-review failure. Each one-liner is a tripwire; the canonical "why" lives in the named skill.

1. Services contain the business logic; handlers are thin and delegate via `ctx.ServicesFactory()`. (`kairos-create-service`)
2. Repositories depend only on `interfaces.Session` and a package-level `tableName` constant — never raw connections, never hardcoded names. (`kairos-create-repository`)
3. All table names in SQL must be wrapped in `pgx.Identifier{name}.Sanitize()` to prevent SQL injection.
4. All PostgreSQL queries use `ctx.DatabaseSession()` — sessions are already tenant-scoped; do **not** add `WHERE tenant_id = ?`. (`kairos-database-model`)
5. Events use `ctx.Sender().Publish(...)`, commands use `Send(...)`, command responses use `SendCommandResponse(...)` — never interchange. (`kairos-messaging-model`)
6. Commands are imperative; events are past-tense. (`kairos-create-command`, `kairos-create-event`)
7. `ServicesFactory` exists once per runtime — `internal/api/request/`, `internal/event-handler/request/`, and `internal/integration-api/request/`. A service must be exposed in every runtime that calls it, mirrored verbatim. (`kairos-create-service`)
8. `Validate()` is mandatory on every `*CommandV1`, `*EventV1`, and `*CommandResponseV1`; the framework calls it on send and receive. (`kairos-messaging-model`)
9. Mutate `ETag` + `UpdatedAt` only via `entity.ForUpdate()`. (`kairos-database-model`)
10. Validate untrusted entity-ID strings via `entities.ParseId(...)` before SQL. (`kairos-database-model`)
11. Run `make generate` after any change to `pkg/schema/` or entities that embed `EntityBase` or `MasterDataEntityBase`, handler registrations, or `+kairos:sql:` directives. Generated files in `chart/resources/topic-config.json`, `sql/0.libs/`, and `sql/1.gen/` are committed. (`kairos-sql-lifecycle`, `kairos-topic-subscriptions`)
12. `event-adapter`, `event-relay` and `event-outbox` are platform-provided infrastructure — do not modify. Customization happens only in `client-api` and `event-handler`.

---

## Security invariants

Kairos is **schema-per-tenant within database-per-component**; tenant isolation is enforced at the session level. For the full tenancy model (topology, session auto-scoping, why no `WHERE tenant_id = ?`), invoke the **`kairos-database-model`** skill. The architecture rules above already cover tenant-scoped sessions and `entities.ParseId(...)`. In addition:

- **No hardcoded secrets, tokens, or credentials** anywhere in the source tree.
- **Error messages must not leak sensitive information** — no stack-traceable internal state, no tenant IDs in user-facing errors, no SQL fragments.
- **Log messages must not leak business data.** Entity IDs (UUIDv7) are OK; names, emails, payloads, and any other PII are not. Correlation IDs and tenant IDs are OK for operational logs.
- **Authentication context is propagated via `ctx`** — never reconstruct it, never accept a tenant ID from request bodies or query params.

---

## After Completing Work

Before marking any task done, always run:

```bash
make lint   # fix all linting and formatting issues
make test   # all tests must pass; coverage ≥ 80%
```

If you touched any of:

- `pkg/schema/` (commands, events, command responses, master data entities)
- handler registrations in `internal/event-handler/handlers.go`
- `+kairos:sql:` directives in domain entities or `cmd/*/main.go`

...run `make generate` **before** `make test`. See **`kairos-sql-lifecycle`** for what `make generate` produces and what silently breaks if you skip it.

### Functional verification

For any new or changed **externally observable** behavior (HTTP APIs, dispatched commands/events, persisted effects, outbound messages), check whether functional tests already cover it. If coverage is missing, add tests using:

- **`kairos-test-functional-client-api`** — behavior exercised through the client API.
- **`kairos-test-functional-event-handler`** — behavior exercised through commands, events, command responses, or master-data handlers.

If you cannot implement a functional test from the information at hand, **ask the developer** before marking the task done. At minimum, clarify endpoint or CloudEvent/message type; tenant and auth assumptions; required seed data; expected persisted state; expected outbound messages (`Publish`/`Send`/`SendCommandResponse`); and any external dependencies or stubs.

To narrow down failing tests when debugging:

```bash
go test ./internal/services/... -v
go test ./internal/services/... -run TestServiceCreateSuccess
go tool cover -func=cover.out
go tool cover -html=cover.out
```

---

## Common Troubleshooting

| Symptom | First check |
|---|---|
| Missing tenant context | Authentication middleware wiring |
| Missing `event_outbox` or `idempotency` table | Both `+kairos:sql:lib:` directives intact (`cmd/client-api/main.go` and `cmd/integration-api/main.go`, `cmd/event-handler/main.go`) — see `kairos-sql-lifecycle` |
| Topic not appearing in `topic-config.json` | `kairos-topic-subscriptions` |
| Test failures after a refactor | Mock expectations satisfied (`ExpectationsWereMet`) |
| Linting errors | `make lint` |
