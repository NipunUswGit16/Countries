---
name: kairos-test-event-handler
description: Writes tests for Kairos event handlers (commands, events, command responses) using eventhandlertest.New and SendCommand/SendEvent helpers. Asserts handler-shape concerns — registration, message dispatch, manual SendCommandResponse, auto-send response payloads, and outbound Send for handlers that don't route through a service. Domain-event publishing is asserted in service tests (kairos-test-service), not here. Use when testing a command or event handler, asserting handler control flow or response payloads, or when the user says "test event handler", "test command handler", or "eventhandlertest".
---

# Test a Kairos Event Handler

Command, event, and command-response handlers are tested with the `eventhandlertest` helper from `kairos-component-common/event-handler/test`. It builds a test context with a `FakeSender`, dispatches the message through the real framework, and lets you assert on what the handler produced.

**Which assertions live here vs. in service tests:**

| Concern | Where it's tested |
|---|---|
| Domain `*EventV1` publishing (type, payload, partition key, event-carried state) | `kairos-test-service` — the service is what called `OutboundMessenger.Publish` |
| Saga-starter `Send` (cross-component commands triggered by a domain mutation) | `kairos-test-service` — same reason; the service issues these too |
| `SendCommandResponse` (manual variant) | Here — the handler is what calls it |
| Auto-sent `*CommandResponseV1` from a request-reply handler return value | Here — assert against the framework's captured response |
| Outbound `Send` from a handler that doesn't go through a service (Row 3 of the HTTP-write decision table) | Here — `FakeSender.SentMessages()` is the only hook |
| Handler control flow (error returned, registration wrapper) | Here — see [§ Error paths](#error-paths) for what a returned error means in production |

For services in isolation, use `kairos-test-service`.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Standard imports

```go
import (
    "testing"
    "time"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
    "github.com/stretchr/testify/require"

    pgmocks "bitbucket.org/ifs-pd/nga-common/postgres/client/mocks"

    eventhandler "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
    eventhandlertest "bitbucket.org/ifs-pd/kairos-component-common/event-handler/test"

    "bitbucket.org/ifs-pd/kairos-component-common/common/entities"
    "bitbucket.org/ifs-pd/kairos-component-common/common/messaging/commands"
    "bitbucket.org/ifs-pd/kairos-component-common/common/messaging/events"

    cmds "bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/commands"
    evts "bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/events"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/config"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/request"
    "bitbucket.org/ifs-pd/kairos-component-template/pkg/schema"
)
```

## Test config and session

**Config.** If `grep -l 'type AppConfig' internal/event-handler/config/*.go | xargs grep -l DomainChangeTimeout | grep -q .` succeeds (the file that declares `AppConfig`, whatever its name), pass a non-zero timeout, `&config.AppConfig{DomainChangeTimeout: 5 * time.Second}`: handlers wrap the service call in `context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)`, and a zero value expires the context before the service runs. Otherwise pass `&config.AppConfig{}`. The templates below assume the field exists.

**Session.** `ctx.DatabaseSession()` in a handler under test returns `testEh.TestContext().MockSession`, a testify mock. Only `SetDefaultSchema`, `Commit` and `Rollback` are pre-stubbed; an `Exec`, `QueryRow` or `Query` the service makes without a stub panics. Stub every call on the code path before `SendCommand` / `SendEvent`:

```go
ms := testEh.TestContext().MockSession

execResult := pgmocks.NewMockExecResult()
execResult.On("RowsAffected").Return(int64(1)).Maybe()
ms.On("Exec", mock.Anything, mock.Anything, mock.Anything, mock.Anything).Return(execResult, nil).Once()
```

Pass one `mock.Anything` for the context, one for the SQL and one per SQL argument; a count mismatch panics. `TestContext()` also has the shortcuts `ResetMocks()` (a successful `Exec` with exactly two SQL arguments, the template's `id`/`data` insert; stub update, delete and other `Exec` calls yourself), `MockExecError(err)`, `MockQueryRowWithData(v)`, `MockQueryRowNotFound()`, `MockQueryWithData(rows)`, `MockQueryEmpty()` and `MockQueryError(err)`. The harness runs no idempotency middleware, so only the handler's own calls need stubs.

## Template: command handler (fire-and-forget)

A fire-and-forget command handler that routes through a service is asserted *here* only for handler shape: it ran, it didn't error. The `*EventV1` that the service publishes is asserted in `kairos-test-service`, not here.

```go
func TestCreateExampleCommand(t *testing.T) {
    testEh := eventhandlertest.New(
        "test-component",
        &request.ServicesFactory{},
        &config.AppConfig{DomainChangeTimeout: 5 * time.Second},
    )
    defer testEh.Close()

    testEh.Add(eventhandler.CommandHandler(cmds.CreateExampleCommand))
    // Stub the service's INSERT (see "Test config and session").
    testEh.TestContext().ResetMocks()

    commandPayload := &schema.CreateExampleCommandV1{
        Id:          entities.NewId().String(),
        Name:        "Test Example",
        CustomField: "Custom Value",
        CustomList:  []string{"item1", "item2"},
    }
    command := commands.New("test-partition-key", commandPayload)

    options := eventhandlertest.SendOptions{TenantId: "test-tenant"}
    err := testEh.SendCommand(command, options)

    require.NoError(t, err)
    // Do not assert testEh.TestContext().FakeSender.SentMessages() here for
    // ExampleCreatedEventV1 — that's the service's responsibility and is
    // asserted in kairos-test-service.
}
```

## Template: command handler (request-reply, auto-sent response)

When the handler returns a typed `*CommandResponseV1`, assert the response payload here — that *is* the handler's output. `FakeSender` also records every event the service published through the same sender, so find the response by payload type, not by index:

```go
func TestCreateExampleCommandReturnsResponse(t *testing.T) {
    testEh := eventhandlertest.New(
        "test-component",
        &request.ServicesFactory{},
        &config.AppConfig{DomainChangeTimeout: 5 * time.Second},
    )
    defer testEh.Close()

    testEh.Add(eventhandler.CommandHandler(cmds.CreateExampleCommand))
    testEh.TestContext().ResetMocks()

    command := commands.New("test-partition-key", &schema.CreateExampleCommandV1{ /* ... */ })
    err := testEh.SendCommand(command, eventhandlertest.SendOptions{TenantId: "test-tenant"})
    require.NoError(t, err)

    var resp *schema.CreateExampleCommandResponseV1
    for _, msg := range testEh.TestContext().FakeSender.SentMessages() {
        if p, ok := msg.GetPayload().(*schema.CreateExampleCommandResponseV1); ok {
            require.Nil(t, resp, "expected exactly one command response")
            resp = p
        }
    }
    require.NotNil(t, resp, "expected the auto-sent command response")
    assert.True(t, resp.Success)
}
```

Don't assert the response's key here. The framework keys the auto-sent response with the inbound `Ce-Subject` header, which the harness never sets, so the key is empty in tests.

## Template: event handler (saga step that routes through a service)

A saga-step event handler that creates/updates a local aggregate goes through a service that publishes its own `*EventV1`. The handler test verifies the handler ran cleanly; the *resulting* event is verified in the service's own test.

```go
func TestOrderPlacedEvent(t *testing.T) {
    testEh := eventhandlertest.New(
        "test-component",
        &request.ServicesFactory{},
        &config.AppConfig{DomainChangeTimeout: 5 * time.Second},
    )
    defer testEh.Close()

    testEh.Add(eventhandler.EventHandler(evts.OrderPlacedEvent))
    testEh.TestContext().ResetMocks() // plus QueryRow stubs for any reads the service makes

    event := events.New("order-123", &otherschema.OrderPlacedEventV1{ /* ... */ })

    err := testEh.SendEvent(event, eventhandlertest.SendOptions{TenantId: "test-tenant"})

    require.NoError(t, err)
    // Do not assert testEh.TestContext().FakeSender.SentMessages() for
    // InvoiceCreatedEventV1 — the InvoiceService publishes it; verify there.
}
```

## Template: event handler (read-model maintenance)

Read-model handlers update a local projection and emit nothing. Assert no outbound messages:

```go
func TestProjectCreatedReadModel(t *testing.T) {
    testEh := eventhandlertest.New( /* ... */ )
    defer testEh.Close()

    testEh.Add(eventhandler.EventHandler(evts.ProjectCreatedReadModel))

    event := events.New("project-id", &schema.ProjectCreatedEventV1{ /* ... */ })
    err := testEh.SendEvent(event, eventhandlertest.SendOptions{TenantId: "test-tenant"})

    require.NoError(t, err)
    assert.Empty(t, testEh.TestContext().FakeSender.SentMessages(),
        "read-model handler must not emit any outbound message")
}
```

## When `FakeSender.SentMessages()` *is* the right hook here

Three cases where you assert outbound messages at this layer:

1. **Auto-sent command response** — the framework wraps the handler's return value and `FakeSender` captures it. Assert the response payload (see request-reply template above).
2. **Manual `SendCommandResponse`** — the handler explicitly called the sender; assertion lives here because the call is in the handler body.
3. **Handlers with no service** — e.g. a trigger-style handler that only does `ctx.Sender().Send(...)` to another component. `FakeSender` captures it.

In all three cases, use it for **count**, **type**, **partition key** (not on the auto-sent response, see above), and **payload field** assertions. Select messages by payload type, as in the request-reply template; `require.Len(t, sent, 1)` with `sent[0]` holds only when nothing else on the path sends (no service, no publish).

## Error paths

What a returned error does in production depends on `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/event-handler`:

- **≥ v1.2.46:** the handler's writes and outbox rows roll back and the message is retried (a fatal error goes to the DLQ, also rolled back).
- **< v1.2.46:** the writes, the outbox rows and the idempotency row **commit**, and the message is never retried.

The harness can't show the difference: `SendCommand` / `SendEvent` return an error on any non-2xx in both, and `FakeSender` records sends either way. On < v1.2.46, say in the test name or a comment that the error path persists partial work, and test that the handler validates and makes its fallible calls before the first write or publish. The lasting fix is event-handler ≥ v1.2.46, but that tag also requires common ≥ v1.4.2, eventsender v0.1.1 and Go 1.27.2, crossing common v1.4.0 and event-handler v1.2.44, which change behaviour. Suggest adopting it through `kairos-component-update`, not a bare `go get`; don't block on it, and re-run the version checks after it.

## Required elements checklist

- [ ] Uses `eventhandlertest.New(...)` with the real `ServicesFactory` (or a test double), and a non-zero `DomainChangeTimeout` when the config has the field
- [ ] Every session call on the code path stubbed
- [ ] `defer testEh.Close()`
- [ ] Handler registered with the right wrapper (`CommandHandler` / `EventHandler` / `CommandResponseHandler`)
- [ ] Message built with `commands.New` or `events.New` and the correct partition key
- [ ] `SendOptions.TenantId` populated
- [ ] For handlers routing through a service: assert handler completed cleanly (`require.NoError`), and leave `*EventV1` assertions to `kairos-test-service`
- [ ] For auto-sent / manual response handlers: find the response in `FakeSender.SentMessages()` by payload type, then assert its payload
- [ ] For read-model handlers: assert `FakeSender.SentMessages()` is empty
- [ ] Error paths covered

## Common mistakes (RED FLAGS)

- Registering the handler with the wrong wrapper (e.g. `EventHandler` for a command).
- Omitting `TenantId` in `SendOptions` — tenant-scoped code will fail.
- `&config.AppConfig{}` when the config has `DomainChangeTimeout` — the zero timeout fails the service call.
- Taking `sent[0]` as the command response — the service's own event may come first.
- Unstubbed `Exec` / `QueryRow` / `Query` on `MockSession` — the test panics.
- Asserting domain `*EventV1` publishing at this layer — the service publishes those; the assertion belongs in `kairos-test-service`. Duplicating the assertion here couples handler tests to service-implementation details.
- Using raw CloudEvents instead of the typed `commands.New` / `events.New` helpers.
- Failing to assert `SentMessages()` is empty for read-model handlers — a leaked publish there is a real defect.
