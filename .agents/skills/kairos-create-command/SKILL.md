---
name: kairos-create-command
description: Creates a new Kairos command end-to-end — the *CommandV1 schema in pkg/schema/ (with validation, compile-time interface checks, and ComponentName routing) AND the matching command handler in internal/event-handler/commands/ that receives the typed command, orchestrates a service via ServicesFactory, and either replies with a typed *CommandResponseV1, publishes follow-up events, or runs fire-and-forget. Commands always route to the component that owns the schema, so schema + handler live together in the same component. Use when adding a new imperative *CommandV1 your component will receive and process, when defining a new operation for other components to trigger, or when the user says "create a command", "add a command schema", "new command", "handle a command", "process a command", or "react to a command".
---

# Create a Kairos Command (schema + handler)

Commands are imperative messages that request an action be performed by a component. In Kairos they always route to the component that **owns the schema** (via `ComponentName()`), which means the schema file in `pkg/schema/` and the handler in `internal/event-handler/commands/` are always created together in the same component. This skill covers both.

They are **payload structs**, not full messages — the framework wraps a payload in `CommandMessage`, adds CloudEvent metadata, and routes it. Handlers receive the typed payload directly (the framework unwraps and validates before invoking). For the broader messaging model (Send vs Publish, partition keys, ordering, double validation, at-least-once delivery), see skill `kairos-messaging-model`.

---

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Part 1 — The schema (`pkg/schema/`)

### File location & naming

- **Location**: `pkg/schema/{entity-name}-{action}-command-v{version}.go`
- **Type name**: `{Action}{Entity}CommandV{Version}` (imperative verb first)
- **No consecutive capitals** (`HttpRequest…`, not `HTTPRequest…`). The `ce_type` depends on `kairos-component-common/common` in `go.mod`: on ≥ v1.4.0 `HTTPRequest` becomes `http-request-…`, on < v1.4.0 `h-t-t-p-request-…`. Bumping common across v1.4.0 changes the `ce_type` and topic of an existing acronym-named message, which breaks its consumers — treat that bump like a rename.

| ✅ Good | ❌ Bad |
|---|---|
| `CreateOrderCommandV1` | `OrderCreatedCommandV1` (past tense → that's an event) |
| `UpdateProductCommandV1` | `CreateOrderV1` (missing `Command`) |
| `DeleteCustomerCommandV2` | `OrderCreateCommandV1` (entity-first) |

### Template

**Field tags below are shown in swag form. Whether they shape `pkg/json-schema/` depends on the kairos-gen version — see § JSON Schema field annotations; below v0.1.0 put the same constraints on `+kairos:schema:*` comment lines instead.**

```go
package schema

import (
	"context"

	"bitbucket.org/ifs-pd/kairos-component-common/common/messaging"
	"bitbucket.org/ifs-pd/kairos-component-common/common/messaging/commands"
	"bitbucket.org/ifs-pd/nga-common/validation"
	"bitbucket.org/ifs-pd/nga-common/validation/check"
	"bitbucket.org/ifs-pd/nga-common/validation/runner"
)

// Compile-time interface assertions — these will fail to build if the struct
// doesn't satisfy the messaging contracts. Keep them.
var _ messaging.Command = (*commands.CommandMessage[*CreateExampleCommandV1])(nil)
var _ messaging.MessagePayload = &CreateExampleCommandV1{}

// CreateExampleCommandV1 creates an example model.
type CreateExampleCommandV1 struct {
	Id          string   `json:"id" validate:"required"`
	Name        string   `json:"name" validate:"required,min=1,max=100"`
	CustomField string   `json:"customField,omitempty" validate:"max=200"`
	CustomList  []string `json:"customList,omitempty" validate:"max=50,unique"`
}

var createValidator = validation.New(func(c *CreateExampleCommandV1, r *runner.Runner[*CreateExampleCommandV1]) {
	check.StringField(r, "Name", c.Name).
		NotEmpty("name cannot be empty").
		MaxLength(100, "name must be at most 100 characters")

	check.StringField(r, "CustomField", c.CustomField).
		MaxLength(200, "custom_field must be at most 200 characters")
})

func (c *CreateExampleCommandV1) Validate(ctx context.Context) error {
	return messaging.Validate(ctx, createValidator, c)
}

func (c *CreateExampleCommandV1) ComponentName() string {
	return ComponentName
}
```

### First schema in this module

If `pkg/schema/go.mod` does not yet require `bitbucket.org/ifs-pd/kairos-component-common/common`, this is the module's first schema type and it needs `go mod tidy`. Pin `common` to the root module's version first:

1. In the component root, read the version: `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/common`.
2. In `pkg/schema/`, run `go get bitbucket.org/ifs-pd/kairos-component-common/common@<that version>`, then `go mod tidy`.

An unpinned tidy takes `common@latest`. Through the root's `replace` of `pkg/schema`, that can lift the whole component across common v1.4.0, which raises the Go floor to 1.27.2 and breaks `eventhandlertest` on event-handler < v1.2.44. Afterwards re-read `common`, `api` and `event-handler` with `go list -m` in the root and re-run any version checks. If `pkg/schema/go.mod` already requires `common`, skip this step.

### Schema checklist

- [ ] File name follows `{entity-name}-{action}-command-v{version}.go` (kebab-case).
- [ ] Type name is `{Action}{Entity}CommandV{Version}` (imperative verb first).
- [ ] Two compile-time assertions: `messaging.Command` and `messaging.MessagePayload`.
- [ ] All JSON tags are **camelCase** (root `AGENTS.md` JSONB rule).
- [ ] Read the kairos-gen version (see below) and annotated fields accordingly (swag tags on ≥ v0.1.0, else `+kairos:schema:*`).
- [ ] `Validate(ctx context.Context) error` uses `messaging.Validate`.
- [ ] `ComponentName() string` returns the `ComponentName` constant from `globals.go`.
- [ ] No constructor function — handlers construct the payload directly.

### JSON Schema field annotations

`kairos-gen` builds `pkg/json-schema/` (and AsyncAPI payloads) from field annotations.

Which annotations it reads depends on the kairos-gen version. If `go.mod` has a `cmd/kairos-gen` line, read `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen`; otherwise run `kairos-gen --version` (`(devel)` or a failure is unknown).

| kairos-gen | What to do |
|---|---|
| ≥ v0.1.0 | **Prefer swag struct tags**, whether or not `internal/integration-api/openapi.go` exists. Author with `validate` / `binding` (`required`, `optional`, `min`/`max`, `gte`/`lte`, `gt`/`lt`, `len`, `oneof`, `unique`), plus `enums`, `format`, `default`, `example` (→ draft-07 `examples` array), `swaggertype`, `swaggerignore`. Do **not** emit a parallel `+kairos:schema:*` for a constraint a tag already expresses. Use a Kairos directive only as an escape hatch (no tag maps to the keyword, or the messaging schema must diverge from Swagger). Directives always win per key when both are present. On `kairos-component-common/toolkit` ≥ v1.0.49 a field is optional unless it has `validate:"required"` or `+kairos:schema:required`; on older toolkits fields are required by default. |
| < v0.1.0 or unknown | **Use `+kairos:schema:*` comment directives only.** This generator reads no struct tags, so `validate`/`enums`/… do not shape `pkg/json-schema/`. |

`internal/integration-api/openapi.go` only decides whether `make generate` also emits `pkg/openapi/`; don't add it to change the annotation style.

**Precedence (≥ v0.1.0):** Go type inference → swag tags → `+kairos:schema:*`. Route `@Param` / `@Success` comments are never consulted.

Orthogonal to runtime `Validate()` / `messaging.Validate` — annotations shape the generated contract; `Validate()` enforces at send/receive. Full tables: `kairos-gen` README (`#kairos-schema-directives`).

### Common validation rules

```go
// Strings
check.StringField(r, "Name", c.Name).
    NotEmpty("name cannot be empty").
    MinLength(3, "name must be at least 3 characters").
    MaxLength(100, "name must be at most 100 characters").
    Matches(`^[a-zA-Z0-9-]+$`, "name must contain only alphanumeric characters and hyphens")

// Numbers (IntField / Int64Field / Float64Field)
check.IntField(r, "Age", c.Age).
    GreaterThanOrEqual(0, "age must be non-negative").
    LessThanOrEqual(150, "age must be at most 150")
    // or a single range check: .Between(0, 150, "age must be between 0 and 150")

// Slices
check.SliceField(r, "Items", c.Items).
    NotEmpty("items cannot be empty").
    MinLen(1, "at least one item is required").
    MaxLen(100, "at most 100 items allowed")

// Custom — the closure receives the instance; return an error to fail
r.Custom(func(c *CreateExampleCommandV1) error {
    if c.CustomField == "invalid" {
        return fmt.Errorf("custom_field cannot be 'invalid'")
    }
    return nil
})
```

### Versioning

V1 is the initial version — ship it without anticipating every future change. The full breaking-vs-non-breaking rules and deprecation template live in `pkg/schema/AGENTS.md` (Versioning Policy). **If uncertain whether a change is breaking, ask the user.**

---

## Part 2 — The handler (`internal/event-handler/commands/`)

### Three handler variants

| Variant | Return type | Use case |
|---|---|---|
| **Fire-and-forget** | `(eventhandler.NilCommandResponse, error)` | Issuer doesn't need a reply. |
| **Request-reply (auto-send)** | `(*schema.YourCommandResponseV1, error)` | Framework **auto-wraps** the returned struct in `CommandResponseMessage` and sends it back. |
| **Request-reply (manual)** | `(eventhandler.NilCommandResponse, error)` + explicit `ctx.Sender().SendCommandResponse(...)` | You need fine-grained control over when/how the response is sent (e.g. multiple responses). |

Rules for all three:

- Handler receives the **typed command directly** (not a CloudEvent).
- Validation is automatic before the handler is invoked.
- Return `nil` response + non-nil `error` for **infrastructure** failures; no response is sent. What the error does depends on `kairos-component-common/event-handler` in `go.mod` (`go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/event-handler`):
  - ≥ v1.2.46: the handler's writes, its outbox rows and the idempotency row roll back, and the message is retried (a fatal error goes to the DLQ).
  - < v1.2.46: a returned error **commits** the idempotency row, every write and every outbox row, and the message is never re-run. Validate and make every call that can fail **before the first write or publish**. The lasting fix is event-handler ≥ v1.2.46, but that tag also requires common ≥ v1.4.2, eventsender v0.1.1 and Go 1.27.2 — crossing common v1.4.0 and event-handler v1.2.44, which change behaviour — so adopt it through `kairos-component-update`, not a bare `go get`. Suggest it to the author without blocking on it, and re-run the version checks after it. See `kairos-messaging-model` § *Handler failure semantics*.
- In the auto-send variant, return a response with `Success: false` + `nil` error when the failure is a **domain** failure you want the issuer to see — no retry.
- **Where the publish lives.** If `internal/services/outbound_messenger.go` exists, the service publishes and the handler never calls `Publish` or `Send` — the rest of this bullet and the templates below assume that. If it doesn't, keep the component's layout: the handler publishes with `ctx.Sender().Publish` after the service call returns and returns its error (`kairos-publish-event` § *Publish where the component already publishes*); don't create `internal/services/` in this task.
- **No `ctx.Sender().Publish(...)` in the handler body** (messenger side). A command handler is just another inbound path into the same service as an API endpoint or event handler. The service publishes the domain `*EventV1`(s) internally through `OutboundMessenger`, with a **full event-carried-state payload** (the persisted aggregate's fields — not just an `id`). See `kairos-create-service` and `kairos-messaging-model` § *Event-carried state transfer*. The `*CommandResponseV1` (when there is one) is the point-to-point reply to the issuer and lives at the handler; the domain event lives at the service. The two are not substitutes for each other and they do not share a payload shape — the response is correlation-shaped (issuer-fields + success/failure), the event is aggregate-shaped (full state).

### File location & naming

- **Location**: `internal/event-handler/commands/{entity}.go`
- **Function name**: the schema type name with the `V{N}` suffix removed — e.g. schema `CreateExampleCommandV1` → handler `CreateExampleCommand`. This rule is mechanical and version-agnostic; it also applies to event handlers (`ExampleCreatedEventV1` → `ExampleCreatedEvent`).

### Template: fire-and-forget

The service publishes the domain event internally (via `OutboundMessenger`), so the handler is a thin pass-through: parse the inbound id, build the domain model, call the service, return.

```go
package commands

import (
	"context"
	"fmt"

	"bitbucket.org/ifs-pd/kairos-component-common/common/entities"
	eventhandler "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/domain"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/request"
	"bitbucket.org/ifs-pd/kairos-component-template/pkg/schema"
)

func CreateExampleCommand(
	command *schema.CreateExampleCommandV1,
	ctx request.Context,
) (eventhandler.NilCommandResponse, error) {
	logger := ctx.Logger()

	db := ctx.DatabaseSession()
	if db == nil {
		logger.Error().Msg("Failed to get database session")
		return nil, fmt.Errorf("failed to get database session")
	}

	entityId, err := entities.ParseId(command.Id)
	if err != nil {
		return nil, fmt.Errorf("invalid entity ID: %w", err)
	}

	example := domain.ExampleModel{
		EntityBase:  entities.NewEntityBase(entityId, entities.NewETag()),
		Name:        command.Name,
		CustomField: command.CustomField,
		CustomList:  command.CustomList,
	}

	exampleService := ctx.ServicesFactory().CreateExampleService(ctx, db)

	ctxTimeout, cancel := context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)
	defer cancel()

	// The service mutates state AND publishes ExampleCreatedEventV1 via
	// OutboundMessenger in the same transaction. No ctx.Sender().Publish(...)
	// call belongs here — see kairos-create-service.
	if _, err := exampleService.CreateExample(ctxTimeout, example); err != nil {
		return nil, fmt.Errorf("failed to create ExampleModel: %w", err)
	}

	logger.Info().Msg("CreateExampleCommandV1 handled")
	return nil, nil
}
```

### Template: request-reply with auto-sent response

Return a `*schema.YourCommandResponseV1` instead of `NilCommandResponse`. The framework automatically wraps it and sends it to the issuer — you do **not** call `SendCommandResponse`.

> **Reminder.** The `*CommandResponseV1` is a **point-to-point reply to the issuer only** — its payload is whatever the caller correlates against (request ids, success/failure, validation errors). The domain `*EventV1` that describes the mutation is published by the service via `OutboundMessenger`, with a **full event-carried-state payload** carrying the persisted aggregate. Two distinct messages, two distinct audiences, two distinct payload shapes: the response addresses the original caller; the event addresses everyone else. See `kairos-create-service`, `kairos-messaging-model` § *Domain events are the default contract*, and `kairos-create-event` § *Event-carried state transfer*.

```go
func CreateExampleCommand(
	command *schema.CreateExampleCommandV1,
	ctx request.Context,
) (*schema.CreateExampleCommandResponseV1, error) {
	db := ctx.DatabaseSession()
	if db == nil {
		return nil, fmt.Errorf("failed to get database session")
	}

	entityId, err := entities.ParseId(command.Id)
	if err != nil {
		// Return an error response to the issuer (nil error = framework auto-sends)
		return &schema.CreateExampleCommandResponseV1{
			ExampleId: command.Id,
			Success:   false,
			Message:   fmt.Sprintf("invalid entity ID: %v", err),
		}, nil
	}

	example := domain.ExampleModel{
		EntityBase:  entities.NewEntityBase(entityId, entities.NewETag()),
		Name:        command.Name,
		CustomField: command.CustomField,
		CustomList:  command.CustomList,
	}

	exampleService := ctx.ServicesFactory().CreateExampleService(ctx, db)

	ctxTimeout, cancel := context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)
	defer cancel()

	createdExample, err := exampleService.CreateExample(ctxTimeout, example)
	if err != nil {
		return &schema.CreateExampleCommandResponseV1{
			ExampleId: command.Id,
			Success:   false,
			Message:   err.Error(),
		}, nil
	}

	return &schema.CreateExampleCommandResponseV1{
		ExampleId: createdExample.Id.String(),
		Success:   true,
		Message:   "Example created successfully",
		CreatedAt: createdExample.CreatedAt.String(),
	}, nil
}
```

### Template: manual response (using SendCommandResponse)

Use this when you need full control — e.g. sending **multiple** responses (progressive pattern) or sending the reply at a non-trivial point in the flow.

```go
import "bitbucket.org/ifs-pd/kairos-component-common/common/messaging/commands"

func ProcessPaymentCommand(
	command *schema.ProcessPaymentCommandV1,
	ctx request.Context,
) (eventhandler.NilCommandResponse, error) {
	logger := ctx.Logger()
	logger.Info().
		Str("order_id", command.OrderId).
		Msg("ProcessPaymentCommand received")

	db := ctx.DatabaseSession()
	if db == nil {
		return nil, fmt.Errorf("failed to get database session")
	}
	paymentService := ctx.ServicesFactory().CreatePaymentService(ctx, db)

	ctxTimeout, cancel := context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)
	defer cancel()

	err := paymentService.ProcessPayment(ctxTimeout, command)

	var response *schema.ProcessPaymentCommandResponseV1
	if err != nil {
		response = &schema.ProcessPaymentCommandResponseV1{Success: false, Message: err.Error()}
	} else {
		response = &schema.ProcessPaymentCommandResponseV1{Success: true}
	}

	responseMsg := commands.NewResponse(command.OrderId, response)
	if err := ctx.Sender().SendCommandResponse(responseMsg); err != nil {
		return nil, fmt.Errorf("failed to send command response: %w", err)
	}

	logger.Info().
		Str("order_id", command.OrderId).
		Bool("success", response.Success).
		Msg("ProcessPaymentCommand finished")
	return nil, nil
}
```

### Registration

Register in `internal/event-handler/handlers.go`:

```go
eh.Add(eventhandler.CommandHandler(commands.CreateExampleCommand))
```

No event-type string is specified — routing is determined by the typed parameter in the handler's signature and the CloudEvent type in incoming metadata.

### Handler checklist

- [ ] Function in `internal/event-handler/commands/`.
- [ ] Signature: `func Name(cmd *schema.XCommandV1, ctx request.Context) (TResponse, error)`.
- [ ] `TResponse` is `eventhandler.NilCommandResponse` or `*schema.XCommandResponseV1`.
- [ ] Database session via `ctx.DatabaseSession()` with **nil check** (event-handler variant does **not** return an error).
- [ ] Service via `ctx.ServicesFactory().CreateXService(ctx, db)` — no direct repository construction.
- [ ] Timeout via `context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)`.
- [ ] Errors wrapped with `fmt.Errorf("context: %w", err)`.
- [ ] On event-handler < v1.2.46, every call that can fail comes before the first write or publish.
- [ ] **No `ctx.Sender().Publish(...)` in the handler body** when a messenger exists. Domain events for the mutation are published by the service via `OutboundMessenger`, with a full event-carried-state payload. If the service doesn't publish them, or publishes only `{ id: "..." }`, fix the **service** (see `kairos-create-service` and `kairos-create-event` § *Event-carried state transfer*) — never paper over either gap from the handler.
- [ ] With a messenger, manual `SendCommandResponse` is the *only* sender call that may appear in this file (in the manual-response variant). `Publish` and saga-starter `Send` both live in the service.
- [ ] Registered in `internal/event-handler/handlers.go` with `eventhandler.CommandHandler(...)`.

### Best practices for request-reply

1. **Always send a response** — even on error — to prevent issuer timeouts.
2. **Same partition key** as the original command (e.g. reuse `command.OrderId`) for ordering.
3. **Include correlation data** in the response (OrderId, RequestId, …).
4. **Handle both success and failure** in the response schema.
5. **Idempotency is automatic** — the framework records the message ID in the `idempotency` table inside the same transaction as your handler's writes (provisioned via `+kairos:sql:lib:` in `cmd/event-handler/main.go`), so a redelivered command is skipped before your handler runs. On event-handler < v1.2.46 that transaction commits even when the handler returns an error (see § *Three handler variants*). You only need to add manual guards for side effects performed *outside* `ctx.DatabaseSession()` (external HTTP calls, raw Kafka publishes bypassing the outbox, etc.).

---

## Common mistakes (RED FLAGS)

**Schema side:**

- Past-tense naming on a command (`OrderCreatedCommandV1` → that's an event).
- snake_case JSON tags (JSONB rule: always camelCase).
- Missing compile-time interface assertions.
- Constructor function instead of direct struct literal.
- Forgetting `ComponentName()` → message cannot be routed.

**Handler side:**

- Treating the parameter as a CloudEvent — it's the typed payload directly.
- Calling `ctx.DatabaseSession()` without nil check (event-handler variant, unlike the API variant, does **not** return `(session, error)`).
- Business logic directly in the handler instead of a service.
- Handler name does not match the schema type name (with `V{N}` removed).
- Manually calling `SendCommandResponse` after returning a typed response — this sends it **twice**.
- With a messenger: `ctx.Sender().Publish(...)` in the handler body — duplicates whatever the service already published, or papers over a service that doesn't publish. Either way the fix is in `kairos-create-service`, not here.
- Treating a returned `*CommandResponseV1` as the broadcast notification. The response goes to the issuer only; the world finds out through the service's `*EventV1`. Never substitute one for the other.

## After finishing

Run `make generate`. For a command it regenerates `pkg/json-schema/` from the new schema; it adds nothing to `topic-config.json` or `component-config.json` — a command is consumed on this component's own topic, which always exists. Commit what changed.
