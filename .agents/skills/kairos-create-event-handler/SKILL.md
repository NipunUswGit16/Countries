---
name: kairos-create-event-handler
description: Creates an event handler in internal/event-handler/events/ that reacts to a Kairos *EventV1. Two cases — both use this skill: (a) consuming an event **from another component** (import its pkg/schema), and (b) **local self-subscription** to events your own component emits (e.g. to maintain a read model, denormalized index, or trigger follow-up work). Use when adding a new event handler, subscribing to an external event stream, hooking up a read model from your own events, or when the user says "handle this event", "react to an event", "subscribe to an event", "consume events from component X", or "build a read model from our own events". Do NOT use this for emitting events — those need a schema (see kairos-create-event), not a handler.
---

# Create a Kairos Event Handler

An event handler reacts to something that has already happened. It receives the **typed event directly** (the framework unwraps the CloudEvent and validates the payload for you). Idempotency is handled by the framework, not by your code — see [Idempotency](#idempotency) below.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## File location & naming

- **Location**: `internal/event-handler/events/{entity}.go`
- **Function name**: the event schema type name with the `V{N}` suffix removed — e.g. schema `ExampleCreatedEventV1` → handler `ExampleCreatedEvent`. Same mechanical rule used for command and command-response handlers. The schema may be local (`pkg/schema/`) or imported from another component.

## Template

```go
package events

import (
	"bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/request"
	"bitbucket.org/ifs-pd/kairos-component-template/pkg/schema"
)

func ExampleCreatedEvent(
	event *schema.ExampleCreatedEventV1,
	ctx request.Context,
) error {
	logger := ctx.Logger()
	logger.Info().Msg("ExampleCreatedEvent called")

	// The event is already validated by the framework.
	logger.Info().
		Str("example_name", event.Name).
		Str("custom_field", event.CustomField).
		Msg("Processing example created event")

	// Typical reactions, all of which go through a service (see the next
	// template). The service publishes any *EventV1 and runs any cross-component
	// Send for saga starters — the handler stays thin.
	//
	// - update a read model
	// - update a local cache
	// - mutate a local aggregate (saga step → service publishes the resulting *EventV1)
	// - trigger follow-up work in another component (saga starter → service issues the Send)

	return nil
}
```

## Template with service + database

```go
func ExampleCreatedEvent(
	event *schema.ExampleCreatedEventV1,
	ctx request.Context,
) error {
	db := ctx.DatabaseSession()
	if db == nil {
		return fmt.Errorf("failed to get database session")
	}

	readModelService := ctx.ServicesFactory().CreateReadModelService(ctx, db)

	ctxTimeout, cancel := context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)
	defer cancel()

	return readModelService.ApplyExampleCreated(ctxTimeout, event)
}
```

## Registration

Register in `internal/event-handler/handlers.go`:

```go
eh.Add(eventhandler.EventHandler(events.ExampleCreatedEvent))
```

## Required elements checklist

- [ ] Function is in `internal/event-handler/events/`
- [ ] Signature: `func Name(event *schema.XEventV1, ctx request.Context) error`
- [ ] Database session obtained with **nil check** if needed
- [ ] Services via `ctx.ServicesFactory()` — no direct repository construction
- [ ] Timeouts via `context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)`
- [ ] Registered with `eventhandler.EventHandler(...)` in `handlers.go`
- [ ] Checked `event-handler` in `go.mod`: on < v1.2.46 every fallible call comes before the first write or publish
- [ ] If the handler mutates domain state (saga step), the mutation goes through a service that publishes the corresponding `*EventV1` via `OutboundMessenger` with a **full event-carried-state payload** for the new aggregate (not a passthrough of fields from the inbound event). **No `ctx.Sender().Publish(...)` in the handler body** when a messenger exists — see § *Saga steps: an event handler that mutates state* and `kairos-create-event` § *Event-carried state transfer*.

## Idempotency

**You do not need to make the handler idempotent.** Kairos handles this for you.

Event delivery is at-least-once, but the framework records every consumed message ID in the `idempotency` table **inside the same database transaction** as your handler's writes. If the same event is redelivered, the framework recognizes the message ID and silently skips the handler — your code is never called twice for the same message.

What a returned error does depends on `kairos-component-common/event-handler` in `go.mod` (`go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/event-handler`):

| event-handler | Returned error |
|---|---|
| ≥ v1.2.46 | Rolls back the handler's writes, its outbox rows and the idempotency row; the message is retried. Return an error to retry. |
| < v1.2.46 | Does **not** roll back. Partial writes and published events persist, the idempotency row commits, and the message is never re-run. Validate and make every call that can fail **before the first write or publish**. The lasting fix is event-handler ≥ v1.2.46, but that tag also requires common ≥ v1.4.2, eventsender v0.1.1 and Go 1.27.2 — crossing common v1.4.0 and event-handler v1.2.44, which change behaviour — so adopt it through `kairos-component-update`, not a bare `go get`. Suggest it to the author without blocking on it, and re-run the version checks after it. |

See `kairos-messaging-model` § *Handler failure semantics*.

This works as long as:

- The `+kairos:sql:lib:bitbucket.org/ifs-pd/kairos-component-common/event-handler` directive in `cmd/event-handler/main.go` is intact (it provisions the `idempotency` table).
- Your handler's writes go through `ctx.DatabaseSession()` — i.e. they participate in the framework's transaction. Side effects performed *outside* that transaction (raw HTTP calls, direct Kafka publishes bypassing the outbox, writes to other databases) are **not** covered and must be made idempotent by hand.

## Cross-component events

When the handler's typed parameter is a schema imported from another component (`otherschema "bitbucket.org/ifs-pd/other-component/pkg/schema"`), the reference to that event type makes the next `make generate` add the producer's topic to `chart(s)/resources/topic-config.json` (folder is `chart/` in newer templates, `charts/` in older ones) — no manual topic configuration needed. The referencing file must be in the scan set, which depends on the toolkit version: see `kairos-topic-subscriptions` § *Which packages get scanned*. An event from this component's own `pkg/schema` is not external and adds no `topic-config.json` entry.

## Saga steps: an event handler that mutates state

If `internal/services/outbound_messenger.go` exists, the service publishes and the handler never calls `Publish` or `Send`. If it doesn't, keep the component's layout: the handler publishes with `ctx.Sender().Publish` after the service call returns and returns its error (`kairos-publish-event` § *Publish where the component already publishes*). Don't create `internal/services/` in this task.

Event handlers are a third inbound path that can reach a state-mutating service method (alongside API endpoints and command handlers). A typical case: this component subscribes to `OrderPlacedEventV1` from `order-service` and, in response, creates a local `Invoice` aggregate (saga step).

The handler stays thin — same as API endpoints and command handlers:

```go
func OrderPlacedEvent(
	event *otherschema.OrderPlacedEventV1,
	ctx request.Context,
) error {
	db := ctx.DatabaseSession()
	if db == nil {
		return fmt.Errorf("failed to get database session")
	}

	invoiceService := ctx.ServicesFactory().CreateInvoiceService(ctx, db)

	ctxTimeout, cancel := context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)
	defer cancel()

	// The service mutates state AND publishes InvoiceCreatedEventV1 via
	// OutboundMessenger inside the same transaction. No ctx.Sender().Publish(...)
	// call belongs here — see kairos-create-service.
	if _, err := invoiceService.CreateFromOrder(ctxTimeout, event); err != nil {
		return fmt.Errorf("create invoice from order: %w", err)
	}
	return nil
}
```

The incoming event does **not** substitute for the outgoing event:

- The incoming `OrderPlacedEventV1` is owned by `order-service` and carries *its* state; it cannot describe an `Invoice`.
- Future subscribers interested in invoices subscribe to `InvoiceCreatedEventV1`, not to `OrderPlacedEventV1`.
- `InvoiceCreatedEventV1` is emitted by `InvoiceService` via `OutboundMessenger` — exactly the same as when a different inbound path triggers an invoice creation.
- The outgoing `InvoiceCreatedEventV1` payload carries **full event-carried state** for the new invoice (id, totals, line items, status, timestamps), not just the order id. Subscribers to invoices must be able to react without calling back to this component. See `kairos-create-event` § *Event-carried state transfer*. Forwarding only fields from the inbound `OrderPlacedEventV1` is wrong — those describe an order, not an invoice.

The only event-handler case that legitimately skips emit is a **read-model handler** that maintains a local derived view of an event you already published or subscribed to — there is no new domain fact, only a denormalized projection. See `kairos-messaging-model` § *Domain events are the default contract* → "Legitimate 'no event' cases". Read-model handlers typically don't even need a service — they go straight to a repository that updates the projection table.

The transactional outbox covers `OutboundMessenger.Publish` from inside a service called by this handler, so the publish is atomic with the service's write to the same `ctx.DatabaseSession()`.

## After finishing

Run `make generate`. For a foreign event it adds the producer's topic to `topic-config.json` (and to `inputTopics` in `component-config.json` where that file exists); for an event from this component's own `pkg/schema` it adds nothing. Commit what changed.

## Common mistakes (RED FLAGS)

- Treating the parameter as a CloudEvent — it's the typed payload directly.
- Hand-rolling idempotency checks (`ON CONFLICT`, existence checks, dedup tables) — the framework already deduplicates by message ID via the `idempotency` table within the handler's transaction.
- Performing side effects outside `ctx.DatabaseSession()` (external HTTP, raw Kafka, second DB) — these are **not** covered by the framework's idempotency and must be guarded by hand.
- `ctx.Sender().Publish(...)` or `ctx.Sender().Send(...)` in the handler body when a messenger exists — both belong inside the service (see `kairos-create-service`). The handler stays a thin pass-through.
- Missing database session nil check.
- Registering with `CommandHandler` instead of `EventHandler` (these are distinct wrappers).
- With a messenger: saga-step handler mutates state (e.g. creates an `Invoice`) by going through a service that *doesn't* publish — that's a service defect. Fix it at the service, not by adding `Publish` in the handler.
- On event-handler < v1.2.46: a check that can fail placed after the first write or publish — the partial work commits.
- Saga-step service publishes the new aggregate's event but the payload is just the inbound event's fields, or just an `id` — violates event-carried state transfer. The new aggregate's event must describe the new aggregate's full state. See `kairos-create-event` § *Event-carried state transfer*.
