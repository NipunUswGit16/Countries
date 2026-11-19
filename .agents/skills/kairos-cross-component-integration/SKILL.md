---
name: kairos-cross-component-integration
description: Integrates this component with another Kairos component (peer service in the same NGA platform — not a third-party API) by importing its pkg/schema package, adding a Go module dependency, wiring handlers for its events/commands/responses, and running make generate so kairos-gen records the subscriptions (event topics, master-data topics, command targets). Use when consuming events from another Kairos component, sending commands across components, integrating with a peer Kairos service, or when the user says "consume event from X", "send command to Y", "integrate with another component", or "talk to component Z".
---

# Integrate With Another Kairos Component

Cross-component communication in Kairos is done via typed message contracts exported from each component's `pkg/schema/` package. Referencing another component's event types, or registering its master data, is what makes `kairos-gen` subscribe to its Kafka topics on the next `make generate`. Commands and responses add no subscription.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## When to use

- Your component needs to **send a command** to another component (e.g. `order-service` → `payment-service`).
- Your component needs to **consume events** published by another component.
- Your component needs to **reply** to commands sent from another component (or handle responses to commands it sent).
- Your component needs to **subscribe to master data** from another component.

## Step 1: Add the dependency

```bash
go get bitbucket.org/ifs-pd/payment-service/pkg/schema@latest
go get bitbucket.org/ifs-pd/inventory-service/pkg/schema@latest
```

This adds the module to `go.mod`. Pin to a specific version (not `@latest`) for production branches.

`go get` can raise this component's own libraries (minimal version selection): todo-demo's `pkg/schema`, for example, requires `kairos-component-common/common` v1.4.3. So read the versions before and after:

```bash
go list -m -f '{{.Path}} {{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/common bitbucket.org/ifs-pd/kairos-component-common/event-handler
```

- **Nothing changed:** continue.
- **`common` crossed v1.4.0, or `event-handler` crossed v1.2.44 or v1.2.46:** stop. These change the master-data header, the master-data registry key and handler failure semantics. Tell the author that this component needs a library update first (`kairos-component-update`), or pick a peer schema version that requires the current `common`.
- **Any other change:** re-run every version check you made earlier in the task, then continue.

## Step 2: Import the external schema

In the handler file, import with an alias to avoid collisions with your own `schema` package:

```go
import (
    paymentschema "bitbucket.org/ifs-pd/payment-service/pkg/schema"
    inventoryschema "bitbucket.org/ifs-pd/inventory-service/pkg/schema"
)
```

## Step 3: Pattern A — Send a command to another component

Use the aliased external schema as the typed payload, then follow skill `kairos-send-command` for the full `Send` vs `Publish` rules, partition-key choice, and error handling. The only thing unique to the cross-component case is the import alias:

```go
cmd := commands.New(
    orderId, // partition key
    &paymentschema.ProcessPaymentCommandV1{
        OrderId:    orderId,
        Amount:     totalAmount,
        CustomerId: customerId,
    },
)
```

What `make generate` does with it: if `chart(s)/resources/component-config.json` exists, the target component is recorded in `commandTargetComponents`; otherwise a foreign command produces no generated output. Commands never appear in `topic-config.json`.

### Variant: sending a command to your own component

It's also valid — though probably not as common — to `Send` a command whose schema your **own** component owns. The usual reason is to push work off the synchronous request path: the sender constructs the command and returns immediately — through its service (`s.messenger.Send`) when the component has a messenger, else with `ctx.Sender().Send(cmd)` where the component already sends (see `kairos-send-command` for which code may send); the command then comes back through Kafka and is processed by your own command handler asynchronously, with the framework's idempotency and ordering guarantees.

Mechanically this case is **not** cross-component integration and nothing in this skill applies — no import alias, no `go get`, no external topic subscription. The schema and handler are created together as described in `kairos-create-command`, and the dispatch is the plain local template in `kairos-send-command`. The only thing to keep in mind is that this is a deliberate "leave the request and come back via Kafka" hop, so use it only when async semantics are actually desired (durability, retry, decoupling) — not as a substitute for an in-process service call.

## Step 3: Pattern B — Handle an event from another component

Write the handler exactly as described in skill `kairos-create-event-handler` (file location, signature, idempotency semantics, service/DB wiring, registration wrapper). The only thing unique to the cross-component case is that the typed parameter comes from the aliased external schema:

```go
import (
    inventoryschema "bitbucket.org/ifs-pd/inventory-service/pkg/schema"

    "bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/request"
)

func ProductStockUpdatedEvent(
    event *inventoryschema.ProductStockUpdatedEventV1,
    ctx request.Context,
) error {
    // ... see kairos-create-event-handler for the body
}
```

What `make generate` does with it: the reference to the foreign event type adds the producer's topic (`inventory-service`) to `topic-config.json`, provided the referencing file is scanned (§ Step 5).

## Step 3: Pattern C — Handle a response to a command you sent

See skill `kairos-create-command-response-handler`. The only cross-component-specific bit is that the response type comes from the aliased external schema. `make generate` adds nothing for it: the reply arrives on this component's own topic.

## Step 3: Pattern D — Consume master data published by another component

In `internal/event-handler/handlers.go`, register a master data mapper on the external entity type. See skill `kairos-register-masterdata-mapper`. What adds the individual-topic subscription depends on kairos-gen (pinned: `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen`; no `cmd/kairos-gen` line in `go.mod`: `kairos-gen --version`, `(devel)` or a failure is unknown):

- ≥ v0.1.0: only the `eh.Sync(eventhandler.MasterData[*T]())` registration.
- < v0.1.0 or unknown: any reference to a foreign `pkg/schema` type that is not an event, command or response, registered or not. Reference foreign helper types (enums, DTOs) only through the event, command or response that carries them.

## Step 4: Register the handler

In `internal/event-handler/handlers.go` (inside `InitHandlers`):

```go
import (
    eventhandler "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/events"
)

eh.Add(eventhandler.EventHandler(events.ProductStockUpdatedEvent))
```

Use the correct wrapper:

| Wrapper | For |
|---|---|
| `eventhandler.EventHandler(...)` | Events |
| `eventhandler.CommandHandler(...)` | Commands |
| `eventhandler.CommandResponseHandler(...)` | Command responses |
| `eh.Sync(eventhandler.MasterData[*T]())` | Master data |

## Step 5: Regenerate topic config

```bash
make generate
```

This runs `kairos-gen`, which scans for references to foreign schema types and rewrites `chart(s)/resources/topic-config.json` (chart folder is `chart/` in newer templates, `charts/` in older ones), plus `component-config.json` where that file exists. Which files are scanned depends on `kairos-component-common/toolkit` in `go.mod` (`go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/toolkit`):

- ≥ v1.0.49: every `cmd/<app>/` plus all of `internal/`.
- < v1.0.49: only `internal/event-handler`, `cmd/event-handler` and `cmd/client-api`, so keep the foreign type reference in an event-handler file.

See skill `kairos-topic-subscriptions` § *Which packages get scanned*.

For events grouped by component:

```json
{
  "tenantInputTopics": [
    {
      "inputTopic": "inventory-service",
      "types": ["inventory-service.product-stock-updated.1"]
    }
  ]
}
```

For master data (individual topics):

```json
{
  "tenantInputTopics": [
    {
      "inputTopic": "product-service.product.1",
      "types": ["product-service.product.1"]
    }
  ]
}
```

See skill `kairos-topic-subscriptions` for the full `topic-config.json` format, detection patterns, and troubleshooting (topic not appearing, wrong component name, duplicates).

## Step 6: Commit the generated files

`chart(s)/resources/topic-config.json`, and `component-config.json` if it exists, **must** be committed alongside the code change. The CI pipeline re-runs generation and will fail if the committed file drifts from what the code implies.

## Required elements checklist

- [ ] `go get` the external component's `pkg/schema`
- [ ] Aliased import for the external schema
- [ ] Handler uses the external type as its typed parameter (for events/commands/responses)
- [ ] Handler registered in `handlers.go` with the correct wrapper
- [ ] `make generate` run
- [ ] `common` / `event-handler` versions compared before and after `go get`
- [ ] `chart(s)/resources/topic-config.json` (and `component-config.json` if present) diff reviewed and committed
- [ ] For master data: `eh.Sync(eventhandler.MasterData[*otherschema.XEntityV1]())`

## Saga / choreography

Cross-component flows in Kairos are typically **choreographed** rather than orchestrated — components react to each other's events without a central coordinator. The same mechanics in Step 3 apply on each side:

```go
// Component A: the service that created the order publishes (kairos-publish-event)
if err := s.messenger.Publish(events.New(order.Id.String(), &schema.OrderCreatedEventV1{...})); err != nil {
    return fmt.Errorf("publish OrderCreatedEventV1: %w", err)
}

// Component B: the handler hands the event to its own service, which mutates and publishes
func OrderCreatedEvent(event *orderschema.OrderCreatedEventV1, ctx request.Context) error {
    logger := ctx.Logger()
    logger.Info().
        Str("order_id", event.OrderId).
        Msg("OrderCreatedEvent received")

    db := ctx.DatabaseSession()
    if db == nil {
        return fmt.Errorf("failed to get database session")
    }
    inventoryService := ctx.ServicesFactory().CreateInventoryService(ctx, db)
    if err := inventoryService.ReserveForOrder(ctx.Context(), event.OrderId, event.Lines); err != nil {
        return err
    }

    logger.Info().
        Str("order_id", event.OrderId).
        Msg("OrderCreatedEvent finished")
    return nil
}
```

Where the component has no `internal/services/outbound_messenger.go`, publish where it already publishes (see `kairos-publish-event`).

## Common mistakes (RED FLAGS)

- Adding the handler but forgetting `make generate` → topic isn't subscribed, messages never arrive.
- Letting `go get <peer>/pkg/schema` silently lift `common` or `event-handler` (§ Step 1).
- Using your own `schema.` prefix for an external schema import (collides with your package).
- Registering with the wrong wrapper (`EventHandler` vs `CommandHandler` vs `CommandResponseHandler`).
- Hand-editing `chart(s)/resources/topic-config.json` — your edits will be overwritten.
