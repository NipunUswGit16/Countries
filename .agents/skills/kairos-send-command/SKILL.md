---
name: kairos-send-command
description: Sends a directed command (typed *CommandV1 from pkg/schema/) from the service through the OutboundMessenger (s.messenger.Send), storing the returned Ce-Id for reply correlation via ctx.CommandId(); falls back to ctx.Sender().Send where a component has no messenger, and covers the pure-forwarding endpoint exception. Covers Send vs Publish and the partition key, for local and cross-component commands. Use when sending a command to a component, requesting an action, or when the user says "send a command", "issue a command", "call another service", or "dispatch a command".
---

# Send a Kairos Command

Commands are **directed** at exactly one component — the owner of the schema. Send an imperative `*CommandV1` with `Send`. Never use `Publish` (that's for events). For the full theory of `Send` vs `Publish` vs `SendCommandResponse`, see reference skill `kairos-messaging-model`.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Prerequisites

- A `*schema.XCommandV1` type exists. If it's a local command, see skill `kairos-create-command`. If it's on another component, see skill `kairos-cross-component-integration`.

## Where to send from

| Check | Follow |
|---|---|
| `internal/services/outbound_messenger.go` exists | [§ Send from the service](#send-from-the-service) |
| Missing | [§ Send where the component already sends](#send-where-the-component-already-sends) |

### Send from the service

The service method that owns the use case sends through `s.messenger.Send`, returns the error, and stores the returned Ce-Id when a reply is expected. The `ServicesFactory` passes `services.NewSenderAdapter(ctx.Sender())` as the messenger (see skill `kairos-create-service`).

```go
import (
    "context"
    "fmt"

    "bitbucket.org/ifs-pd/kairos-component-common/common/messaging/commands"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/domain"
    paymentschema "bitbucket.org/ifs-pd/payment-service/pkg/schema"
)

func (s *OrderService) RequestPayment(ctx context.Context, order domain.Order) error {
    cmd := commands.New(
        order.Id.String(), // partition key — the target aggregate, or the originating one in a saga
        &paymentschema.ProcessPaymentCommandV1{
            OrderId:    order.Id.String(),
            Amount:     order.Total,
            CustomerId: order.CustomerId,
        },
    )

    commandId, err := s.messenger.Send(cmd)
    if err != nil {
        return fmt.Errorf("send ProcessPaymentCommandV1: %w", err)
    }

    // The reply's handler reads this Ce-Id back with ctx.CommandId().
    return s.pendingRepo.Save(ctx, domain.PendingPayment{CommandId: commandId, OrderId: order.Id.String()})
}
```

Rules for this side:

- **Command and event handlers never send directly.** They call the service, which sends.
- **API endpoints** (client API and integration API alike) send directly only for **pure forwarding**: the endpoint mutates no local state and has no aggregate to load, so there is no service to own the call (for example `POST /search/reindex`). Then `ctx.Sender().Send(cmd)` in the endpoint is correct; return its error.
- A local command (one this component owns) is built the same way with this component's `pkg/schema` type.

### Send where the component already sends

The component has no messenger. Keep its layout: send with `ctx.Sender().Send(cmd)` in the endpoint or handler where it already sends, return the error, and store the returned Ce-Id when a reply is expected. Build the command exactly as above.

```go
commandId, err := ctx.Sender().Send(cmd)
if err != nil {
    return fmt.Errorf("send ProcessPaymentCommandV1: %w", err)
}
```

Don't create `internal/services/` inside this task. Tell the author that a template update adopts the messenger (skill `kairos-component-update`, upgrade-file `20260724T113527-consolidate-outbound-messenger.md`).

In an event or command handler, a returned error rolls back the outbox row only on `kairos-component-common/event-handler` ≥ v1.2.46 in `go.mod`; below that it commits, so send only after the last step that can fail. See `kairos-messaging-model` § *Handler failure semantics*.

### When local-send is appropriate

A local `Send` routes the command back into your own component through Kafka, so it's strictly more expensive than calling the service directly. Use it only when the asynchronous semantics are themselves the point:

- **Push work off the synchronous API path.** An endpoint validates input, sends the command, and returns immediately; the actual domain change happens later in your own command handler with full idempotency and ordering guarantees.
- **Decouple a long-running step from the caller** (handler, saga step) so it can fail independently without blocking the surrounding flow.
- **Serialize work on a partition key** (e.g. per-aggregate) when the calling context can't guarantee that ordering on its own.

If none of those apply, prefer a direct service call — sending a command to yourself just to invoke local code adds a Kafka round-trip, an outbox row, and an idempotency record for no benefit.

### Cross-component commands

Import the target component's `pkg/schema` (skill `kairos-cross-component-integration` covers the module dependency). What `make generate` does with the import: if `chart/resources/component-config.json` exists, it records the target component in `commandTargetComponents`; otherwise a foreign command produces no generated output. Commands never appear in `topic-config.json` — the target owns the command topic.

## Choosing a partition key

The first argument to `commands.New(...)` is the Kafka partition key. Default to the **target aggregate ID** so all commands for the same aggregate stay ordered on a single partition. For saga steps, share the correlation ID of the originating event so the whole saga is single-threaded. Never pass an empty string. See `kairos-messaging-model` for the full reasoning.

## Required elements checklist

- [ ] `Send(...)` — **not** `Publish`
- [ ] Sent from the service through the messenger (or, with no messenger, where the component already sends); endpoints send directly only for pure forwarding
- [ ] Payload is a `*schema.XCommandV1` (imperative, command)
- [ ] `commands.New(partitionKey, payload)` wraps the payload
- [ ] Partition key is deterministic and appropriate
- [ ] For cross-component commands, the external schema import is in place
- [ ] The `Send` error is returned — never swallowed
- [ ] The returned Ce-Id is stored when a reply is expected

## Expected response

If the command has a corresponding `*CommandResponseV1` and the receiving handler uses the typed-response variant, a reply will arrive at this component. Register a response handler (skill `kairos-create-command-response-handler`); it matches the reply to the stored Ce-Id with `ctx.CommandId()`. Without a registered handler, the reply is silently dropped.

## Common mistakes (RED FLAGS)

- Calling `Publish()` for a command (use `Send`).
- Empty partition key → random partitioning, breaks ordering.
- `ctx.Sender().Send` in a command or event handler, or in an endpoint that also mutates local state, when a messenger exists.
- Discarding the Ce-Id (`_, err := ...Send(cmd)`) when a response is expected — the response handler cannot correlate.
- Synchronous waiting on the response inside the same handler without correlation tracking infrastructure.
