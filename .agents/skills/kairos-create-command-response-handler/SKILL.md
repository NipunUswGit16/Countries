---
name: kairos-create-command-response-handler
description: Creates a command response handler in internal/event-handler/responses/ that processes replies **YOUR component received after sending a command to ANOTHER component**. Import the other component's *CommandResponseV1 schema; this handler is the issuer side of a request-reply pattern. Use when handling a reply from a previously-sent cross-component command, implementing the issuer side of request-reply, or when the user says "handle command response", "process reply", or "receive command response". Do NOT use this for responses your own component produces — those are defined as schemas (see kairos-create-command-response) and returned from your command handler (see kairos-create-command).
---

# Create a Kairos Command Response Handler

This handler processes replies to commands **this component previously sent** to another component. It completes the request-reply pattern on the issuer side.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## File location & naming

- **Location**: `internal/event-handler/responses/{entity}.go`
- **Function name**: the response schema type name with the `V{N}` suffix removed — e.g. response `ProcessPaymentCommandResponseV1` → handler `ProcessPaymentCommandResponse`. Same mechanical rule used for command and event handlers.

## Template

```go
package responses

import (
	"fmt"

	"bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/request"
	// Import the external component's schema if handling a reply to a command
	// sent to another component:
	paymentschema "bitbucket.org/ifs-pd/payment-service/pkg/schema"
)

func ProcessPaymentCommandResponse(
	response *paymentschema.ProcessPaymentCommandResponseV1,
	ctx request.Context,
) error {
	logger := ctx.Logger()
	logger.Info().
		Str("command_id", ctx.CommandId()).
		Bool("success", response.Success).
		Msg("ProcessPaymentCommandResponse received")

	db := ctx.DatabaseSession()
	if db == nil {
		return fmt.Errorf("failed to get database session")
	}

	orderService := ctx.ServicesFactory().CreateOrderService(ctx, db)

	// ctx.CommandId() is the Ce-Id that Send returned when the command went out;
	// the service stored it then and looks the in-flight request up by it now.
	// On success it advances the order (and publishes); on failure it marks the
	// order failed or compensates (and publishes).
	if err := orderService.HandlePaymentResponse(ctx.Context(), ctx.CommandId(), response); err != nil {
		return err
	}

	logger.Info().
		Str("command_id", ctx.CommandId()).
		Msg("ProcessPaymentCommandResponse finished")
	return nil
}
```

The service decides what success and failure mean and publishes any follow-up event. If `internal/services/outbound_messenger.go` doesn't exist (and there is no hand-rolled messenger), the handler publishes where the component already does — see `kairos-publish-event`.

A returned error rolls back and retries only on `kairos-component-common/event-handler` ≥ v1.2.46 in `go.mod` (`go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/event-handler`). Below that it commits the partial work and the reply is not redelivered, so the service makes every call that can fail before its first write or publish. See `kairos-messaging-model` § *Handler failure semantics*.

## Registration

Register in `internal/event-handler/handlers.go` using `CommandResponseHandler` (distinct from both `EventHandler` and `CommandHandler`):

```go
import (
    eventhandler "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/responses"
)

eh.Add(eventhandler.CommandResponseHandler(responses.ProcessPaymentCommandResponse))
```

## Required elements checklist

- [ ] Function is in `internal/event-handler/responses/`
- [ ] Signature: `func Name(response *schema.XCommandResponseV1, ctx request.Context) error`
- [ ] Typed parameter references the correct (often external) response schema
- [ ] Service via `ctx.ServicesFactory()`; the in-flight request is found by `ctx.CommandId()`
- [ ] Both success (`response.Success == true`) and failure paths handled
- [ ] Idempotent (responses can be redelivered)
- [ ] Registered with `eventhandler.CommandResponseHandler(...)` — **not** `EventHandler`

## Correlation

`Send` returns the command's Ce-Id; the service that sent it stores that id with the in-flight request (see `kairos-send-command`). When the reply arrives, `ctx.CommandId()` returns the same id, so look the request up by it. A correlation field in the response payload (e.g. `OrderId`) is a useful extra, not a substitute.

## Synchronous-like pattern

There is **no out-of-the-box mechanism** for an API handler to send a command and block on the reply. Doing so requires you to build correlation tracking and a signaller (e.g. a channel keyed by message ID populated from this response handler). Prefer an event-driven reaction unless a synchronous interaction is genuinely required.

## After finishing

Run `make generate` and commit what changed. For a response handler it adds nothing to `topic-config.json`: replies arrive on this component's own topic, and the command target is already recorded in `component-config.json` `commandTargetComponents` (where that file exists) by the code that sends the command.

## Common mistakes (RED FLAGS)

- Registering with `EventHandler` or `CommandHandler` — responses need `CommandResponseHandler`.
- Ignoring the failure branch — the issuer must react to failures.
- Discarding the Ce-Id at send time, so `ctx.CommandId()` matches nothing.
- Non-idempotent handler that double-applies on redelivery.
- Blocking the handler while waiting on something external — responses must be processed promptly.
