---
name: kairos-create-service
description: Creates a business-logic service in internal/services/ that takes a repository interface, an OutboundMessenger interface, and a logger, and wires it through the ServicesFactory of every runtime that calls it (client-API, event-handler, integration-API variants). Services own domain-event publishing — every state-mutating method emits its events through OutboundMessenger before returning. Use when adding a service, moving business logic out of a handler, introducing a new domain use case, or when the user says "add service", "create service", or "refactor business logic out of handler".
---

# Create a Kairos Service

Services contain business logic, coordinate persistence, **and publish the domain events that describe their mutations**. They are the **shared** layer between API endpoints and event handlers — exactly the same service is used from both, and the publish lives inside the service so every caller automatically does the right thing.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Architectural rules

- Services depend on **interfaces**, never on concrete repositories or concrete senders (makes testing trivial).
- Services accept `context.Context` first in every method and respect timeouts.
- Services are decoupled from the **inbound** transport — no imports of Fiber, `*fiber.Ctx`, or the CloudEvents reception SDK. They work with domain types regardless of who invoked them (API endpoint or event handler).
- Outbound integrations (third-party HTTPS APIs, gRPC clients, SDKs) are legitimate, but must sit behind an interface — same pattern as repositories — so the service stays unit-testable. The Kairos outbound bus (`OutboundMessenger`) follows this same pattern.
- Services are **not** goroutines or workers — they're stateless collaborators.

## Service responsibility for domain events

State-mutating service methods are the **convergence point** for the "mutate → event" rule. Multiple inbound paths can trigger a mutation — API endpoint, command handler, saga-step event handler — but they all funnel through the same service method. Anchoring publish here is the only way to guarantee consistency across paths without scattering judgement calls into every handler.

**The service owns:**

1. **The mutation.** Validate, persist, return the persisted aggregate.
2. **The publish.** Construct and publish the corresponding `*EventV1`(s) through `OutboundMessenger`, with a full event-carried-state payload. The outbox row is written on the same session as the mutation, so they commit or roll back together, with one exception in the event handler:
   - `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/event-handler` ≥ v1.2.46: a service error returned from an event handler rolls back the writes and the outbox rows, and the message is retried.
   - < v1.2.46: a returned error **commits** the idempotency row, every write and every outbox row already written, and the message is never re-run. Validate and make every call that can fail **before the first write or publish**. The lasting fix is event-handler ≥ v1.2.46, but that tag also requires common ≥ v1.4.2, eventsender v0.1.1 and Go 1.27.2, crossing common v1.4.0 and event-handler v1.2.44, which change behaviour. Suggest adopting it through `kairos-component-update`, not a bare `go get`, without blocking on it; re-run the version checks after it.

   The API runtimes roll back on any error or non-2xx response, on every version.
3. **Any saga-starter `Send` to other components.** Cross-component commands triggered by a domain mutation are domain logic — they belong in the service too.

**The caller (API endpoint, command handler, saga-step event handler) only:**

- Parses input, picks the service method, returns the response.
- Never calls `ctx.Sender().Publish(...)` — the service did it.
- Never calls `ctx.Sender().Send(...)` for saga starters — the service did it.

`SendCommandResponse` is the one exception that stays at the command handler — it's correlation-bound to the inbound `CommandMessage`, not domain logic. See `kairos-create-command`.

## The `OutboundMessenger` interface

Services receive a narrow outbound-messaging interface, owned by the `services` package. Find out what the component has before you write the service:

| Check (component root) | Do |
|---|---|
| `test -f internal/services/outbound_messenger.go` succeeds | Use it as shown below: the service takes `OutboundMessenger`, the factories pass `services.NewSenderAdapter(ctx.Sender())`. Don't recreate the file. |
| It fails, but `grep -rln 'messaging.Command) (string, error)' --include=*.go internal` finds a hand-rolled adapter (e.g. `internal/services/messenger.go` plus an unexported `newSenderAdapter` in each `request` package) | Use that interface and constructor; don't add a second one. The template's version replaces it through the optional template upgrade-file `20260724T113527-consolidate-outbound-messenger.md` (`kairos-component-update`); mention it, don't apply it here. |
| Neither, and the author explicitly asked for a services layer (a feature, scaffold, endpoint or fix request is not that) | Create `internal/services/outbound_messenger.go` verbatim from the snippet below. Tell the author the template ships the same file through a template update (`kairos-component-update`); its upgrade-file `20260724T113527-consolidate-outbound-messenger.md` describes the pattern. |
| Neither, and any other task (a feature, a scaffold, an endpoint, a handler, a fix) | Don't create `internal/services/` or a messenger inside this task. Keep the component's layout: if `internal/services/` exists, a new service there takes `(repo, logger)`; if it doesn't, add no service and keep the logic where the component has it today. Events are published where the component already publishes them, with `ctx.Sender().Publish(...)` at the call site, returning its error. Point the author to the template update (`kairos-component-update`) and its upgrade-file `20260724T113527-consolidate-outbound-messenger.md`. |

The template's file also holds `senderAdapter` and the exported `NewSenderAdapter` constructor, which bridges the runtime `ctx.Sender()` (a `messaging.Sender`) into the interface. `ServicesFactory` calls `services.NewSenderAdapter(ctx.Sender())` — there is no per-runtime adapter file.

```go
// internal/services/outbound_messenger.go
package services

import (
	"bitbucket.org/ifs-pd/kairos-component-common/common/messaging"
)

// OutboundMessenger is the outbound-bus contract services depend on.
// ServicesFactory adapts the runtime ctx.Sender() to this interface so the
// same service works identically under the API runtime and the event-handler
// runtime.
//
// SendCommandResponse is intentionally NOT here — replying to a specific
// inbound command is correlation-bound and lives in the command handler.
type OutboundMessenger interface {
	Publish(event messaging.Event) error
	// Send a command to a component. Returns the message ID (Ce-Id) for correlation.
	Send(cmd messaging.Command) (string, error)
}

// senderAdapter adapts the runtime ctx.Sender() to the OutboundMessenger interface.
type senderAdapter struct {
	inner messaging.Sender
}

// NewSenderAdapter creates a new senderAdapter.
func NewSenderAdapter(s messaging.Sender) OutboundMessenger {
	return senderAdapter{inner: s}
}

func (a senderAdapter) Publish(e messaging.Event) error {
	return a.inner.Publish(e)
}

func (a senderAdapter) Send(c messaging.Command) (string, error) {
	return a.inner.Send(c)
}
```

## File location & naming

- **Service location**: `internal/services/{entity}_service.go`
- **Messenger interface + adapter**: `internal/services/outbound_messenger.go` when the component has it (one file per package, shared across services); see the table above
- **Type name**: `{Entity}Service`
- **Constructor**: `New{Entity}Service(repo RepoInterface, messenger OutboundMessenger, logger logging.Logger)`

## Template

The pagination imports depend on the layout. If `internal/domain/pagination.go` and `internal/dto/pagination.go` exist, import `internal/domain` and `internal/dto` as below: the filter is `domain.PaginationFilter`, the metadata `dto.Pagination`. Otherwise both types live in the client API's package: import `internal/api/dto` instead of `internal/dto` and write `dto.PaginationFilter`. The template upgrade-file `20261019T104600-pagination-types-moved.md` (`kairos-component-update`) moves them; don't move them inside this task.

```go
package services

import (
	"context"
	"fmt"

	"bitbucket.org/ifs-pd/kairos-component-common/common/messaging/events"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/domain"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/dto"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/repositories"
	"bitbucket.org/ifs-pd/kairos-component-template/pkg/schema"
	"bitbucket.org/ifs-pd/nga-common/logging"
)

type ExampleService struct {
	repo      repositories.ExampleRepositoryInterface
	messenger OutboundMessenger
	logger    logging.Logger
}

func NewExampleService(
	repo repositories.ExampleRepositoryInterface,
	messenger OutboundMessenger,
	logger logging.Logger,
) *ExampleService {
	return &ExampleService{
		repo:      repo,
		messenger: messenger,
		logger:    logger,
	}
}

// GetAllExamples — read-only, no events, no messenger use.
func (s *ExampleService) GetAllExamples(
	ctx context.Context,
	filter domain.PaginationFilter,
) ([]domain.ExampleModel, dto.Pagination, error) {
	results, total, err := s.repo.GetAll(ctx, filter)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to get all examples")
		return nil, dto.Pagination{}, err
	}

	pagination := dto.Pagination{
		Page:  filter.Page,
		Limit: filter.Limit,
		Total: total,
	}

	return results, pagination, nil
}

// CreateExample validates input, persists the aggregate, and publishes
// ExampleCreatedEventV1 with full event-carried state. Atomic: the publish
// is enrolled in the same transaction as the repo write via the outbox.
func (s *ExampleService) CreateExample(
	ctx context.Context,
	example domain.ExampleModel,
) (domain.ExampleModel, error) {
	if err := s.validateExampleData(ctx, example); err != nil {
		s.logger.Error().Err(err).Msg("Example validation failed")
		return domain.ExampleModel{}, err
	}

	created, err := s.repo.Create(ctx, example)
	if err != nil {
		return domain.ExampleModel{}, fmt.Errorf("create example: %w", err)
	}

	event := events.New(
		created.Id.String(),
		&schema.ExampleCreatedEventV1{
			Id:          created.Id.String(),
			Name:        created.Name,
			CustomField: created.CustomField,
			CustomList:  created.CustomList,
			CreatedAt:   created.CreatedAt,
			UpdatedAt:   created.UpdatedAt,
		},
	)
	if err := s.messenger.Publish(event); err != nil {
		return domain.ExampleModel{}, fmt.Errorf("publish ExampleCreatedEventV1: %w", err)
	}

	return created, nil
}
```

## Wiring into ServicesFactory

A service is only reachable from a runtime whose `ServicesFactory` exposes it. Each runtime binary has its own `request` package with its own `ServicesFactory`:

| Runtime | `ServicesFactory` file |
|---|---|
| Client API | `internal/api/request/services_factory.go` |
| Event handler | `internal/event-handler/request/services_factory.go` |
| Integration API | `internal/integration-api/request/services_factory.go` |

**Add the factory method to every runtime that calls the service, and mirror it verbatim across them.** The bodies are byte-for-byte identical; only the `Context` type resolves differently per package. Adding it to just one runtime leaves the service invisible to the others — the classic symptom is an endpoint or handler that can't find `CreateXService` on its factory.

Don't blanket-add to all three either. If `internal/integration-api/request/services_factory.go` exists, add the method there only when an integration-API route calls the service; most components leave it a bare `type ServicesFactory struct{}` until then. If it doesn't exist, the component has two runtimes and two factories.

```go
package request

import (
    "bitbucket.org/ifs-pd/kairos-component-template/internal/repositories"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/services"
    "bitbucket.org/ifs-pd/nga-common/postgres/client/interfaces"
)

type ServicesFactory struct{}

func (f ServicesFactory) CreateExampleService(
    ctx Context,
    session interfaces.Session,
) *services.ExampleService {
    repo := repositories.NewExampleRepository(session)
    return services.NewExampleService(repo, services.NewSenderAdapter(ctx.Sender()), ctx.Logger())
}
```

`services.NewSenderAdapter` (in `internal/services/outbound_messenger.go`) wraps the runtime `ctx.Sender()` — a `messaging.Sender` — into `services.OutboundMessenger`. Every runtime calls that same constructor; there is no per-runtime adapter file to add. With a hand-rolled adapter (second row of the table), call that one instead, e.g. `services.NewExampleService(repo, newSenderAdapter(ctx.Sender()), ctx.Logger())`. With no messenger (last row), `services.NewExampleService(repo, ctx.Logger())`.

## Required elements checklist

- [ ] Service in `internal/services/`
- [ ] Messenger chosen by the table in § *The `OutboundMessenger` interface*: reuse `internal/services/outbound_messenger.go` or the component's own adapter; create the file only when the author explicitly asked for a services layer
- [ ] Struct holds `repo {Entity}RepositoryInterface`, `messenger OutboundMessenger` (when the component has one), `logger logging.Logger` — **interfaces**, not concrete types
- [ ] Constructor `New{Entity}Service(repo, messenger, logger) *{Entity}Service`, or `(repo, logger)` without a messenger
- [ ] On event-handler < v1.2.46, every call that can fail comes before the first write or publish
- [ ] All public methods take `context.Context` as their first argument
- [ ] Service is wired into the `ServicesFactory` of **every runtime that calls it** (client-API, event-handler, and the integration-API one if `internal/integration-api/request/services_factory.go` exists), each passing the messenger the table chose
- [ ] Validation before persistence — domain invariants enforced here, not in handlers
- [ ] Errors logged and wrapped/propagated
- [ ] With a messenger: **every state-mutating method publishes its `*EventV1`(s) through `s.messenger.Publish(...)` before returning**, with a full event-carried-state payload (not just an `id`). See `kairos-messaging-model` § *Domain events are the default contract*.
- [ ] With a messenger: saga-starter `Send` calls (cross-component commands triggered by the mutation) live in the service via `s.messenger.Send(...)`, not in the caller. Without one, they stay where the component sends today.

## Usage from handlers

Callers (API endpoint, command handler, saga-step event handler) only call the service. With a messenger, the service publishes its events internally — no `ctx.Sender().Publish(...)` at the call site. Without one (last row of the table), the caller publishes right after the service call and returns the error.

```go
// API: db, err := ctx.DatabaseSession(); defer db.Close()
// EH:  db := ctx.DatabaseSession(); if db == nil { ... }

svc := ctx.ServicesFactory().CreateExampleService(ctx, db)
result, err := svc.CreateExample(ctx.Context(), example)
// No Publish here. The service did it.
```

## Common mistakes (RED FLAGS)

- Service depends on a concrete repository or concrete sender instead of the interfaces → untestable.
- Service imports Fiber, `*fiber.Ctx`, or the CloudEvents reception SDK → inbound-transport coupling violation. (Outbound third-party HTTP/gRPC clients are fine, but must be behind an interface — same as `OutboundMessenger`.)
- Business logic remains in the handler and the service is a pass-through.
- ServicesFactory updated in one runtime variant but not another that calls the service → service unavailable from that side.
- Service stores a `context.Context` as a field → always pass it in per-call.
- State-mutating method that **doesn't publish** the corresponding `*EventV1` — *the* recurring agent failure mode and the whole reason publish was pulled into the service. See `kairos-messaging-model` § *Domain events are the default contract*.
- Publishing only `{ id: "..." }` instead of full state — violates event-carried state transfer; forces subscribers to call back.
- Caller (handler) calling `ctx.Sender().Publish(...)` after a service call — the publish should already have happened inside the service. Duplicate publish = double event on the bus.
- `OutboundMessenger` widened to include `SendCommandResponse` — that's correlation-bound to a specific inbound command and belongs at the command handler. Keep the interface narrow.
