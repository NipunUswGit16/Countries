---
name: kairos-create-event
description: Creates a new Kairos event schema in pkg/schema/ for an event **YOUR component will emit** (past-tense fact broadcast to any subscriber). Covers validation, compile-time interface checks, and ComponentName routing. Schema is owned by the emitting component; subscribers import it. Use when defining a new *EventV1 your component produces, when broadcasting that something happened, or when the user says "create an event", "add an event schema", "new event", or "publish a new kind of event". Do NOT use this for events FROM another component — those are consumed by writing a handler (see kairos-create-event-handler) against their imported schema.
---

# Create a Kairos Event

Events represent something that has already happened. They are **broadcast** to any subscriber (as opposed to commands, which are directed at a specific component). Events are **payload structs**, not full messages — the framework wraps them in `EventMessage`.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## When to emit an event

In Kairos, components integrate **only** through the event stream. There is no shared database, no cross-component RPC, no entity-pull API. If another component is ever going to react to a fact, the producer must publish it as an event.

**The rule: every meaningful domain state change emits a `*EventV1` — even if no known subscriber exists today.**

Subscribers are added asynchronously, in other components, *without* the producer's involvement (see `kairos-cross-component-integration`).

**Concretely, emit an event for:**

- Aggregate creation, update, deletion (`IssueCreatedEventV1`, `IssueUpdatedEventV1`, `IssueDeletedEventV1`).
- State transitions on an aggregate (`IssueOpenedEventV1`, `SprintClosedEventV1`).
- Domain-meaningful actions on an aggregate (`CommentAddedEventV1`, `IssueAssignedEventV1`).

**Narrow exceptions — no event:**

- Cache invalidation, in-memory bookkeeping, internal flag flips with no domain meaning.
- Master-data replica upserts (the master-data mapper writes the local copy; re-publishing would echo the source event back through the bus).
- Derived read-model writes triggered by another event (consumers should subscribe to the *source* event, not to your derived write).

If the change has a domain noun and a past-tense verb (Issue *created*, Comment *added*, Status *transitioned*), it's domain-meaningful — emit.

See `kairos-messaging-model` § *Domain events are the default contract* for the full principle and where responsibility lives.

## Event-carried state transfer

Event payloads carry the **full state** subscribers need to react. Subscribers populate their own read models from the payload; they do **not** call back to the producer for additional fields.

| ✅ Self-sufficient payload | ❌ "Just an id" payload |
|---|---|
| `IssueCreatedEventV1 { id, title, description, projectId, reporterId, assigneeId?, status, createdAt }` | `IssueCreatedEventV1 { id }` |
| `IssueAssignedEventV1 { id, projectId, assigneeId, previousAssigneeId?, assignedBy, assignedAt }` | `IssueAssignedEventV1 { id, assigneeId }` |
| `IssueClosedEventV1 { id, projectId, resolution, closedBy, closedAt }` | `IssueClosedEventV1 { id }` |
| `CommentAddedEventV1 { id, issueId, authorId, body, createdAt }` | `CommentAddedEventV1 { commentId }` |

**Why:** callbacks couple subscribers to the producer at runtime, cascade load to the producer during stream replay, and break tenant isolation (the producer would need a tenant-aware read API for peers). Event-carried state makes subscribers self-sufficient and replays cheap.

**Exception:** very large payloads (multi-megabyte attachments, blobs) — emit a reference plus a fetch endpoint. That is the only legitimate "callback" pattern.

## Prefer specific events over generic transition events

Pick the event name from the **domain verb**, not from the field that changed. An issue that moves into the assigned state is `IssueAssignedEventV1`. An issue that's closed is `IssueClosedEventV1`. An issue that's reopened is `IssueReopenedEventV1`.

A generic `IssueStatusChangedEventV1 { previousStatus, newStatus, ... }` is **N events fused into one** — every subscriber has to switch on `newStatus` in handler code to find the case it cares about, and the payload is squashed into a lowest-common-denominator shape that doesn't fit any single transition well.

**Specific events buy you:**

- **Topic-level routing.** Subscribers register a handler for `IssueClosedEventV1` and ignore everything else. A generic status-change event fans every transition out to every status subscriber — wasted dispatches, wasted idempotency rows, wasted log noise.
- **Per-event payload tailoring.** `IssueClosedEventV1` carries `resolution` and `closedBy`. `IssueAssignedEventV1` carries the new (and optional previous) assignee — useful for "you've been unassigned" notifications. A single `IssueStatusChangedEventV1` can't carry both cleanly; it ends up with nullable fields that mean different things in different states.
- **Evolution.** Adding a new transition (`IssueArchivedEventV1`, `IssueDuplicatedEventV1`) is a new schema, not a breaking change to an existing one. Subscribers that don't care keep working unchanged; subscribers that do care opt in by registering a handler.

**Default mapping: one domain verb → one event type.** Name the event after the verb the user or operator would use ("opened", "assigned", "closed", "merged", "archived"), not after the field that changed.

**Composition note — multi-field updates.** Don't over-fragment in the other direction either. If a single domain operation legitimately mutates several fields together (e.g., editing an issue's title, description, and priority in one form submission), a single `IssueDetailsEditedEventV1` carrying all of them is correct — the operation has one domain verb (*edit*), so one event. Fragmenting into per-field events would force subscribers to correlate across messages to reconstruct the operation.

**Rare exception — open-ended state sets.** If the state machine is genuinely user-configurable (a workflow engine where each tenant defines their own state names), a generic `*StateChangedEventV1` carrying the configured-state value may be unavoidable. This is rare; almost always the producer owns the state machine and the transitions are knowable up front. If you reach for the generic shape, document why in the schema's doc comment so the next reviewer doesn't undo it.

For state-transition events that *are* specific (`IssueClosedEventV1`, `IssueReopenedEventV1`, etc.), include the **previous value** alongside the new one whenever a diff matters to subscribers — e.g., `IssueAssignedEventV1.previousAssigneeId` for unassign notifications, `IssuePriorityChangedEventV1.previousPriority` for escalation rules.

## File location & naming

- **Location**: `pkg/schema/{entity-name}-{past-action}-event-v{version}.go`
- **Type name**: `{Entity}{PastAction}EventV{Version}` (past tense)
- **No consecutive capitals** (`HttpRequest…`, not `HTTPRequest…`). The `ce_type` depends on `kairos-component-common/common` in `go.mod`: on ≥ v1.4.0 `HTTPRequest` becomes `http-request-…`, on < v1.4.0 `h-t-t-p-request-…`. Bumping common across v1.4.0 changes the `ce_type` and topic of an existing acronym-named message, which breaks its consumers — treat that bump like a rename.

| ✅ Good | ❌ Bad |
|---|---|
| `OrderCreatedEventV1` | `CreateOrderEventV1` (imperative) |
| `ProductUpdatedEventV1` | `OrderCreatedV1` (missing "Event") |
| `CustomerDeletedEventV2` | `OrderCreateEventV1` (not past tense) |

## Template

**Field tags below are shown in swag form. Whether they shape `pkg/json-schema/` depends on the kairos-gen version — see § JSON Schema field annotations; below v0.1.0 put the same constraints on `+kairos:schema:*` comment lines instead.**

```go
package schema

import (
	"context"
	"time"

	"bitbucket.org/ifs-pd/kairos-component-common/common/messaging"
	"bitbucket.org/ifs-pd/kairos-component-common/common/messaging/events"
	"bitbucket.org/ifs-pd/nga-common/validation"
	"bitbucket.org/ifs-pd/nga-common/validation/check"
	"bitbucket.org/ifs-pd/nga-common/validation/runner"
)

// Compile-time interface assertions — keep both.
var _ messaging.Event = (*events.EventMessage[*ExampleCreatedEventV1])(nil)
var _ messaging.MessagePayload = &ExampleCreatedEventV1{}

// ExampleCreatedEventV1 represents an example created event.
type ExampleCreatedEventV1 struct {
	Name        string    `json:"name" validate:"required"`
	CustomField string    `json:"customField,omitempty" validate:"max=200"`
	CustomList  []string  `json:"customList,omitempty"`
	CreatedAt   time.Time `json:"createdAt" validate:"required"`
	UpdatedAt   time.Time `json:"updatedAt" validate:"required"`
}

var createdValidator = validation.New(func(e *ExampleCreatedEventV1, r *runner.Runner[*ExampleCreatedEventV1]) {
	check.StringField(r, "Name", e.Name).
		NotEmpty("name cannot be empty")
})

func (e *ExampleCreatedEventV1) Validate(ctx context.Context) error {
	return messaging.Validate(ctx, createdValidator, e)
}

func (e *ExampleCreatedEventV1) ComponentName() string {
	return ComponentName
}
```

## First schema in this module

If `pkg/schema/go.mod` does not yet require `bitbucket.org/ifs-pd/kairos-component-common/common`, this is the module's first schema type and it needs `go mod tidy`. Pin `common` to the root module's version first:

1. In the component root, read the version: `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/common`.
2. In `pkg/schema/`, run `go get bitbucket.org/ifs-pd/kairos-component-common/common@<that version>`, then `go mod tidy`.

An unpinned tidy takes `common@latest`. Through the root's `replace` of `pkg/schema`, that can lift the whole component across common v1.4.0, which raises the Go floor to 1.27.2 and breaks `eventhandlertest` on event-handler < v1.2.44. Afterwards re-read `common`, `api` and `event-handler` with `go list -m` in the root and re-run any version checks. If `pkg/schema/go.mod` already requires `common`, skip this step.

## Required elements checklist

- [ ] File name follows `{entity-name}-{past-action}-event-v{version}.go` (kebab-case)
- [ ] Type name ends in `EventV{N}` with a past-tense verb
- [ ] Compile-time assertions for `messaging.Event` and `messaging.MessagePayload`
- [ ] All JSON tags are **camelCase**
- [ ] Read the kairos-gen version (see below) and annotated fields accordingly (swag tags on ≥ v0.1.0, else `+kairos:schema:*`)
- [ ] `Validate(ctx) error` implemented (validation on events is typically minimal — events represent facts that already occurred)
- [ ] `ComponentName() string` returning the package-level `ComponentName` constant
- [ ] Payload carries **full state** a reasonable subscriber would need to react (event-carried state transfer) — not just an `id`. For state transitions, include both previous and new value where a diff matters.
- [ ] Event name comes from a **domain verb**, not from a field name. `IssueClosedEventV1`, not `IssueStatusChangedEventV1`. See § *Prefer specific events over generic transition events*.

## JSON Schema field annotations

`kairos-gen` builds `pkg/json-schema/` (and AsyncAPI payloads) from field annotations.

Which annotations it reads depends on the kairos-gen version. If `go.mod` has a `cmd/kairos-gen` line, read `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen`; otherwise run `kairos-gen --version` (`(devel)` or a failure is unknown).

| kairos-gen | What to do |
|---|---|
| ≥ v0.1.0 | **Prefer swag struct tags**, whether or not `internal/integration-api/openapi.go` exists. Author with `validate` / `binding` (`required`, `optional`, `min`/`max`, `gte`/`lte`, `gt`/`lt`, `len`, `oneof`, `unique`), plus `enums`, `format`, `default`, `example` (→ draft-07 `examples` array), `swaggertype`, `swaggerignore`. Do **not** emit a parallel `+kairos:schema:*` for a constraint a tag already expresses. Use a Kairos directive only as an escape hatch (no tag maps to the keyword, or the messaging schema must diverge from Swagger). Directives always win per key when both are present. On `kairos-component-common/toolkit` ≥ v1.0.49 a field is optional unless it has `validate:"required"` or `+kairos:schema:required`; on older toolkits fields are required by default. |
| < v0.1.0 or unknown | **Use `+kairos:schema:*` comment directives only.** This generator reads no struct tags, so `validate`/`enums`/… do not shape `pkg/json-schema/`. |

`internal/integration-api/openapi.go` only decides whether `make generate` also emits `pkg/openapi/`; don't add it to change the annotation style.

**Precedence (≥ v0.1.0):** Go type inference → swag tags → `+kairos:schema:*`. Route `@Param` / `@Success` comments are never consulted.

Orthogonal to runtime `Validate()` — annotations shape the generated contract; `Validate()` enforces at publish/receive (keep event validation minimal). Full tables: `kairos-gen` README (`#kairos-schema-directives`).

## Validation

Like commands, events are validated on both the publishing side and the receiving side. Keep validation **minimal** — events represent facts that have already occurred. Reject invalid input on the **command** that produced the event, not on the event itself.

## Versioning

V1 is the initial version — ship it without anticipating every future change. The full breaking-vs-non-breaking rules and the deprecation/parallel-publish template live in `pkg/schema/AGENTS.md` (Versioning Policy). **If uncertain whether a change is breaking, ask the user.**

## After finishing

Run `make generate`. For an event this component emits it regenerates `pkg/json-schema/` from the new schema; it adds nothing to `topic-config.json` — the event goes out on this component's own topic (`outputTopic`), and each subscriber's own `make generate` adds the subscription once it references the type. Commit what changed. To publish it, see `kairos-publish-event`.

## Common mistakes (RED FLAGS)

- Imperative naming on an event (`CreateOrderEventV1` → that's a command)
- snake_case JSON tags
- Calling `Send()` instead of `Publish()` to emit the event
- Heavy validation on events (events are facts; reject invalid **commands** instead)
- Forgetting `ComponentName()` → topic routing breaks
- "Just an id" payload — forces subscribers to call back to the producer; violates event-carried state transfer.
- Skipping the event "because nothing subscribes yet" — see *When to emit an event* above. Future subscribers pay the cost; emit now.
- Generic transition events with a discriminator field — `IssueStatusChangedEventV1 { newStatus: "closed" \| "reopened" \| ... }`, `OrderUpdatedEventV1 { fields: {...} }`. Split into specific events named after the domain verb (`IssueClosedEventV1`, `IssueReopenedEventV1`, `OrderShippedEventV1`, ...). See § *Prefer specific events over generic transition events* for the rare exception (open-ended state sets) and the multi-field-update nuance.
