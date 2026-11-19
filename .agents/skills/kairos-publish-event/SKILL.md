---
name: kairos-publish-event
description: Publishes a domain event (typed *EventV1 from pkg/schema/) from the service method that made the change, through the OutboundMessenger (s.messenger.Publish), returning the error so the outbox row rolls back with the transaction; falls back to ctx.Sender().Publish where a component has no messenger. Covers Publish vs Send and choosing the partition key. Use when emitting a domain event (past tense), broadcasting that something happened, or when the user says "publish an event", "emit event", or "broadcast".
---

# Publish a Kairos Event

Events are **broadcast** to all subscribers — fan-out to 0..N consumers. Publish a past-tense `*EventV1` with `Publish`. Never use `Send` (that's for commands). For the full theory of `Publish` vs `Send` vs `SendCommandResponse`, see reference skill `kairos-messaging-model`.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Prerequisites

- A `*schema.XEventV1` type exists. If not, first use skill `kairos-create-event`.

## Where to publish from

| Check | Follow |
|---|---|
| `internal/services/outbound_messenger.go` exists | [§ Publish from the service](#publish-from-the-service) |
| Missing | [§ Publish where the component already publishes](#publish-where-the-component-already-publishes) |

### Publish from the service

The service method that makes the domain change publishes, after its last write, and returns the error. Endpoints and handlers call the service and never publish themselves. The `ServicesFactory` passes `services.NewSenderAdapter(ctx.Sender())` as the messenger (see skill `kairos-create-service`).

```go
import (
    "context"
    "fmt"

    "bitbucket.org/ifs-pd/kairos-component-common/common/messaging/events"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/domain"
    "bitbucket.org/ifs-pd/kairos-component-template/pkg/schema"
)

func (s *ExampleService) CreateExample(ctx context.Context, example domain.Example) (domain.Example, error) {
    created, err := s.repo.Create(ctx, example)
    if err != nil {
        return domain.Example{}, err
    }

    event := events.New(
        created.Id.String(), // partition key
        &schema.ExampleCreatedEventV1{
            Name:        created.Name,
            CustomField: created.CustomField,
            CreatedAt:   created.CreatedAt,
            UpdatedAt:   created.UpdatedAt,
        },
    )
    if err := s.messenger.Publish(event); err != nil {
        return domain.Example{}, fmt.Errorf("publish ExampleCreatedEventV1: %w", err)
    }
    return created, nil
}
```

### Publish where the component already publishes

The component has no messenger. Keep its layout: publish with `ctx.Sender().Publish(event)` in the endpoint or handler where it already publishes, after the service or repository call returns, and return the error. Build the event exactly as above.

```go
if err := ctx.Sender().Publish(event); err != nil {
    return fmt.Errorf("publish ExampleCreatedEventV1: %w", err)
}
```

Don't create `internal/services/` inside this task. Tell the author that a template update adopts the messenger (skill `kairos-component-update`, upgrade-file `20260724T113527-consolidate-outbound-messenger.md`).

## Choosing a partition key

The first argument to `events.New(...)` is the Kafka partition key. Default to the **aggregate ID** (`entity.Id.String()`) so events for the same aggregate stay ordered on a single partition. For tenant-wide ordering or cross-aggregate correlation, pick deliberately — see `kairos-messaging-model`. Never pass an empty string.

## Failure handling

`Publish` writes a row to the `event_outbox` table on the current transaction; nothing reaches Kafka until that transaction commits. **Return the error** — never log and continue.

- **API request** (client or integration API): a returned error, or any non-2xx response, rolls back the request transaction, the outbox row with it. Same in every library version.
- **Event or command handler**: depends on `kairos-component-common/event-handler` in `go.mod` (`go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/event-handler`).
  - ≥ v1.2.46: the outbox row rolls back with the handler's writes and the message is retried.
  - < v1.2.46: a returned error still **commits** the outbox row, so subscribers see an event for a failed operation, and the message is not retried. Publish only after the last step that can fail. The lasting fix is event-handler ≥ v1.2.46, but that tag also requires common ≥ v1.4.2, eventsender v0.1.1 and Go 1.27.2 — crossing common v1.4.0 and event-handler v1.2.44, which change behaviour — so adopt it through `kairos-component-update`, not a bare `go get`. Suggest it to the author without blocking on it, and re-run the version checks after it. See `kairos-messaging-model` § *Handler failure semantics*.
- **Integration-API bulk load** (`/load`, loaders): only when `internal/integration-api/loaders` exists and `kairos-component-common/api` ≥ v1.2.32 in `go.mod`. That path runs with no ambient transaction, so `Publish` fails with `missing session in context`. Don't publish from a loader. Otherwise this case doesn't apply.

The `event_outbox` table comes from the `+kairos:sql:lib:bitbucket.org/ifs-pd/nga-event-outbox/pkg/eventsender` directive in `cmd/client-api/main.go`, and also in `cmd/integration-api/main.go` if that file exists.

## Master data is not published from code

There is no publish call for master data. Owned master data is produced by CDC (Debezium) off the owned `id, data` table, but only where `chart/templates/debezium/` exists; otherwise see `kairos-create-masterdata-entity` § Publishing master data. `sender.SendMasterDataChange` was removed in `kairos-component-common/common` v1.4.0; before that it exists only on the concrete sender, not on `ctx.Sender()`, so there is no call to write in either case. `events.NewMasterDataEvent` / `messaging.MasterDataEvent` exist only for the **consuming** side.

## Required elements checklist

- [ ] `Publish(...)` — **not** `Send`
- [ ] Published from the service through the messenger, or (no messenger) where the component already publishes
- [ ] Payload is a `*schema.XEventV1` (past tense, event)
- [ ] `events.New(partitionKey, payload)` wraps the payload
- [ ] Partition key is deterministic and appropriate (aggregate ID in most cases)
- [ ] The `Publish` error is returned

## Common mistakes (RED FLAGS)

- Calling `Send()` for an event (use `Publish`).
- `Publish` outside a service when `internal/services/outbound_messenger.go` exists.
- A swallowed `Publish` error (logged and ignored) — the domain change commits without its event.
- Empty partition key → random partition assignment, breaks ordering.
- Creating `internal/services/` by hand to publish in a component that has no messenger.
