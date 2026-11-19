---
name: kairos-create-api-endpoint
description: Creates a REST API endpoint — in internal/api/endpoints/v1/ for the client API, or internal/integration-api/endpoints/v1/ for the integration API — using Fiber, the request.Context abstraction, ServicesFactory, and standardized request/response helpers. Registers the route in the matching routes.go. Use when adding a REST endpoint, BFF API, integration API endpoint, HTTP handler, or when the user says "add endpoint", "new route", or "create API endpoint".
---

# Create a Kairos API Endpoint

A Kairos API endpoint is a thin handler: it parses the request, delegates to a service via `ServicesFactory`, and returns a standardized response. If `internal/services/outbound_messenger.go` exists, domain-event publishing lives inside the service (`kairos-create-service` — `OutboundMessenger`), so a state-mutating endpoint contains **no** `ctx.Sender().Publish(...)` call. Otherwise publish with `ctx.Sender()` where the component already does and return its error (see `kairos-publish-event`); the template upgrade-file `20260724T113527-consolidate-outbound-messenger.md` adopts the messenger, and this task does not create `internal/services/`. It runs on the Fiber framework but handlers never see `*fiber.Ctx` directly — they use the unified `request.Context`.

For paginated list endpoints, use `kairos-create-paginated-endpoint` instead.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Step 0 — pick the target runtime

A component can expose **two** Fiber-based REST runtimes, each a separate binary with its own `internal/` tree. Everything in this skill applies identically to both — the only differences are the directory paths and the `request` package the handler imports.

| | Client API | Integration API |
|---|---|---|
| **Audience** | The component's own frontend (BFF) | Other systems — bulk load and machine-to-machine integration |
| Binary | `cmd/client-api` | `cmd/integration-api` |
| Handlers | `internal/api/endpoints/v1/` | `internal/integration-api/endpoints/v1/` |
| Route registration | `internal/api/routes.go` | `internal/integration-api/routes.go` |
| `request` package | `internal/api/request` | `internal/integration-api/request` |
| `ServicesFactory` | `internal/api/request/services_factory.go` | `internal/integration-api/request/services_factory.go` |
| `AppConfig` | `internal/api/config/` | `internal/integration-api/config/` |
| DTO packages | `internal/api/dto/`, plus `internal/dto/` if it exists | `internal/dto/` if it exists, else `internal/api/dto/` ([§ Where to declare the request type](#where-to-declare-the-request-type)) |
| Test helper | `api/test` → `apitest.New` | `api/test/integration` → `integrationapitest.New` |

**If the user didn't say which, ask** — the audience is the deciding factor, and putting a frontend endpoint on the integration API (or vice versa) exposes it to the wrong consumers. Two signals worth checking first: an endpoint that the web app under `web/` will call is client API; anything about bulk loading belongs to the integration API, and is very likely a *loader* rather than a hand-written endpoint (see `kairos-create-loader` before scaffolding anything).

If `cmd/integration-api/main.go` exists, both runtimes are available: ask which one, as above. Otherwise the component has only the client API, so use it. If the author wants an integration endpoint, stop and tell them the integration-API runtime is absent; it is optional, and this task does not build it.

The rest of this skill uses the **client API** paths. For an integration-API endpoint, substitute `internal/api/` → `internal/integration-api/` throughout; nothing else changes.

## File location & naming

- **Handler file**: `internal/api/endpoints/v1/{entity}.go` — `package endpoints`.
- **Function name**: `{Action}{Entity}` — e.g. `CreateExampleModel`, `GetExampleModelById`.
- **Route registration**: `internal/api/routes.go`.

The integration-API tree ships without an `endpoints/` directory (the template's `internal/integration-api/routes.go` registers an empty `/v1` group). Create `internal/integration-api/endpoints/v1/` when adding the first hand-written endpoint there — same `package endpoints`, same layout.

## Handler signature

```go
func HandlerName(ctx request.Context) error
```

Where `request.Context = apicontext.Context[ServicesFactory, config.AppConfig]`, defined in `internal/api/request/context.go` (client API) or `internal/integration-api/request/context.go` (integration API). Both alias the same generic `apicontext.Context`, so the handler body, the context surface, and the request/response helpers are identical across runtimes — only the instantiating type arguments differ.

## Request and response helpers

The template parses the body and writes every response through methods on `ctx`. Which spelling the component has depends on `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/api`:

- **≥ v1.2.37:** write the template as shown.
- **< v1.2.37:** the methods don't exist. Write each call in the package-function form, which takes `ctx` as its first argument:

  | Template | api < v1.2.37 |
  |---|---|
  | `ctx.ParseBody[T]()` | `commonapi.RequestBody[T](ctx)` |
  | `ctx.SuccessResponse(data, msg)` | `commonapi.SuccessResponse(ctx, data, msg)` |
  | `ctx.EmptySuccessResponse(msg)` | `commonapi.EmptySuccessResponse(ctx, msg)` |
  | `ctx.ErrorResponse(status, msg, err)` | `commonapi.ErrorResponse(ctx, status, msg, err)` |

  Status codes, response bytes, and swag annotations are identical. Nothing else in the template changes.

On ≥ v1.2.37 the package functions still exist as deprecated wrappers, so handlers already written that way keep working: don't rewrite them in an endpoint task. Either way the handler file imports `commonapi` for the `@Success` envelope types; the `var _ = commonapi.ResponseBody{}` line keeps that import used when no helper call references the package.

## Template

```go
package endpoints

import (
	"context"
	"errors"

	"github.com/gofiber/fiber/v2"

	commonapi "bitbucket.org/ifs-pd/kairos-component-common/api"
	apierrors "bitbucket.org/ifs-pd/kairos-component-common/api/errors"
	"bitbucket.org/ifs-pd/kairos-component-common/common/entities"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/api/request"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/domain"
)

var _ = apierrors.ErrRequestErrorResponse{} // keep failure schema visible to swag --parseDependency
var _ = commonapi.ResponseBody{}            // keep success envelope visible to swag --parseDependency

// errInternal is the only error text a 5xx response carries; the real error is logged.
var errInternal = errors.New("internal error")

// CreateExampleRequest is the request body. ParseBody[T] calls Validate
// because the type has Validate(context.Context) error on a value receiver
// (the commonapi.Validatable shape). `validate:` struct tags are never read;
// check fields here.
type CreateExampleRequest struct {
	Name        string   `json:"name"`
	CustomField string   `json:"customField"`
	CustomList  []string `json:"customList"`
}

func (r CreateExampleRequest) Validate(ctx context.Context) error {
	if r.Name == "" || len(r.Name) > 200 {
		return errors.New("name is required and must be at most 200 characters")
	}
	if len(r.CustomField) > 1000 {
		return errors.New("customField must be at most 1000 characters")
	}
	return nil
}

// CreateExampleModel handles POST /api/v1/example
//
// @Summary      Create example
// @Tags         example
// @Accept       json
// @Produce      json
// @Param        body  body  CreateExampleRequest  true  "Create example request"
// @Success      200   {object}  commonapi.ResponseBody{data=domain.ExampleModel}
// @Failure      400   {object}  apierrors.ErrRequestErrorResponse
// @Failure      500   {object}  apierrors.ErrRequestErrorResponse
// @Router       /v1/example [post]
// @Security     BearerAuth
func CreateExampleModel(ctx request.Context) error {
	logger := ctx.Logger()

	// 1. Parse + validate request body (400 on failure; see "Returning the
	// parse error" below).
	requestBody, err := ctx.ParseBody[CreateExampleRequest]()
	if err != nil {
		return err
	}

	// 2. Build the domain model.
	example := domain.ExampleModel{
		EntityBase:  entities.NewEntityBase(entities.NewId(), entities.NewETag()),
		Name:        requestBody.Name,
		CustomField: requestBody.CustomField,
		CustomList:  requestBody.CustomList,
	}

	// 3. Tenant-scoped database session — API variant returns (session, error).
	db, err := ctx.DatabaseSession()
	if err != nil {
		logger.Error().Err(err).Msg("Failed to get database session")
		return ctx.ErrorResponse(fiber.StatusInternalServerError, "Failed to get database session", errInternal)
	}
	defer db.Close()

	exampleService := ctx.ServicesFactory().CreateExampleService(ctx, db)

	// 4. Execute business logic with a configured timeout. With a messenger,
	// the service mutates state AND publishes the *EventV1 inside the same
	// transaction (outbox-atomic); no ctx.Sender().Publish(...) belongs here.
	ctxTimeout, cancel := context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)
	defer cancel()

	createdExample, err := exampleService.CreateExample(ctxTimeout, example)
	if err != nil {
		logger.Error().Err(err).Msg("Failed to create example")
		return ctx.ErrorResponse(fiber.StatusInternalServerError, "Failed to create example", errInternal)
	}

	return ctx.SuccessResponse(createdExample, "Example created successfully")
}
```

### The domain-change timeout

Step 4 reads `ctx.Config().DomainChangeTimeout`. Check the target runtime's config: `grep -l 'type AppConfig' internal/api/config/*.go | xargs grep -l DomainChangeTimeout | grep -q .` (`internal/integration-api/config/*.go` for the integration API). The first grep finds the file that declares `AppConfig`, whatever its name.

- **Succeeds:** use the snippet as written.
- **Fails:** the snippet doesn't compile. In this same task, add the field with skill `kairos-configure-appconfig`, exactly as the template declares it: `DomainChangeTimeout time.Duration` with tags `mapstructure:"domain_change_timeout" default:"10s"`.

### Request type and 5xx errors

The request type is named (not declared inside the handler) so `@Param body` can reference it. `Validate` takes `context.Context` and has a value receiver; with any other signature `ParseBody[T]` (or `RequestBody[T]`) never calls it. Import `apierrors "bitbucket.org/ifs-pd/kairos-component-common/api/errors"` when annotating `@Failure` with `ErrRequestErrorResponse`.

On a 5xx path, log the full error and pass a generic error (`errInternal`) to `ErrorResponse`: its text goes into the response body, so pgx or service errors would leak to the caller. Don't pass `nil`: `ErrorResponse` calls `err.Error()` and panics. 4xx paths may pass a caller-facing error (`errors.New("id is required")`).

### Returning the parse error

Depends on `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/api`:

- **≥ v1.2.32:** `return err`, from `ctx.ParseBody[T]()` or `commonapi.RequestBody[T](ctx)` alike. The error unwraps to a `*fiber.Error`, so the caller gets 400.
- **< v1.2.32:** returning it gives 500. Render it instead: `return commonapi.ErrorResponse(ctx, fiber.StatusBadRequest, "Invalid request body", err)`.

### What comes after the service call?

The template above is the default — service call, then response. The service mutated state, published its event(s), and ran any saga-starter `Send` to other components, all internally. For endpoints that *don't* fit this shape (no local state — pure cross-component triggers, async self-`Send` patterns), see `kairos-messaging-model` § *Default pattern for HTTP writes* — that section enumerates the remaining variants and the HTTP status code each returns.

### Where to declare the request type

The example above declares `CreateExampleRequest` in the handler file because it is single-use and small. Shared or large types go in a DTO package, which depends on the layout:

- **`internal/dto/pagination.go` exists:** `internal/dto/` is the neutral package that both entry layers and the services import; it imports nothing from `internal/`. Client-API-only types go in `internal/api/dto/`; types both runtimes use go in `internal/dto/`. An integration-API endpoint never imports `internal/api/dto` (entry layers don't import each other), so its own types stay in its handler file or go in `internal/dto/`. A file that imports both packages aliases the one it uses less, e.g. `shareddto "…/internal/dto"`.
- **Missing:** `internal/api/dto/` is the only DTO package, and integration-API endpoints import it too. The template upgrade-file `20261019T104600-pagination-types-moved.md` (`kairos-component-update`) adds `internal/dto/`; don't create it inside this task.

Either way, don't create a DTO package per runtime (`internal/integration-api/dto/`): it duplicates the pagination wrappers.

## Standardized responses

```go
return ctx.SuccessResponse(result, "Example created successfully")     // 200 with body
return ctx.EmptySuccessResponse("Command sent successfully")           // 200 no body
return ctx.ErrorResponse(fiber.StatusNotFound, "Example not found", errors.New("example not found")) // 4xx: caller-facing error
return ctx.ErrorResponse(fiber.StatusInternalServerError, "Failed to create example", errInternal) // 5xx: generic error, log the real one

// Common status codes:
//   fiber.StatusBadRequest   (400)
//   fiber.StatusNotFound     (404)
//   fiber.StatusConflict     (409)
```

On api < v1.2.37 write these as `commonapi.<Name>(ctx, …)` ([§ Request and response helpers](#request-and-response-helpers)). Never return `fiber.NewError(...)` or `c.Status(...).JSON(...)` directly — use the helpers above. The one exception is a response envelope (`messageId`/`messageParams`) the web app turns into a translated toast: see skill `response-library-go-endpoint`.

Wire envelopes (for OpenAPI / clients):

| Helper | Envelope type |
|---|---|
| `SuccessResponse` | `commonapi.ResponseBody` (`success`, `message`, `data`) |
| `EmptySuccessResponse` | `commonapi.EmptyResponseBody` (`success`, `message`) |
| `ErrorResponse` | `apierrors.ErrRequestErrorResponse` (`success=false`, …) |

Swag does **not** infer these from the helper call — every handler must declare them:

```go
// @Success 200 {object} commonapi.ResponseBody{data=domain.ExampleModel}
// @Success 200 {object} commonapi.EmptyResponseBody
// @Failure 400 {object} apierrors.ErrRequestErrorResponse
// @Failure 500 {object} apierrors.ErrRequestErrorResponse
```

`@Router` paths are relative to `@BasePath` (`/api` on the integration API). Integration-API handlers are scanned into `pkg/openapi/` via `make generate-openapi` when `internal/integration-api/openapi.go` is present. Client-API OpenAPI is out of scope for that target today.

## Route registration

Register in `internal/api/routes.go` (client API) — or `internal/integration-api/routes.go` for the integration API, which has the same `InitRoutes(router fiber.Router)` entry point and is called from `cmd/integration-api/main.go`:

```go
import (
    "bitbucket.org/ifs-pd/kairos-component-common/api"
    endpoints "bitbucket.org/ifs-pd/kairos-component-template/internal/api/endpoints/v1"
    "github.com/gofiber/fiber/v2"
)

func InitRoutes(router fiber.Router) {
    v1Group := router.Group("/v1")
    exampleRoutes := v1Group.Group("/example")

    exampleRoutes.Post("/", api.Handler(endpoints.CreateExampleModel))
    exampleRoutes.Get("/", api.Handler(endpoints.GetAllExampleModels))
    exampleRoutes.Get("/:id", api.Handler(endpoints.GetExampleModelById))
}
```

`api.Handler(...)` (from `kairos-component-common/api`) adapts `func(request.Context) error` into Fiber's handler signature. It is generic over the context's type arguments, so **both** runtimes use this same helper — there is no integration-specific wrapper. Handlers must always be wrapped this way.

Route registration belongs in `routes.go`, never in `cmd/*/main.go`. On the integration API, don't add routes to `internal/integration-api/loaders.go` either — that file is only for loader registration.

## Request context surface

| Method | Purpose |
|---|---|
| `ctx.Logger()` | Structured logger (correlation ID auto-included) |
| `ctx.Tracer()` | OpenTelemetry tracer |
| `ctx.DatabaseSession()` | Tenant-scoped PostgreSQL session — returns `(session, error)` in the API variant |
| `ctx.Config()` | Typed `*AppConfig` |
| `ctx.ServicesFactory()` | Factory for services |
| `ctx.Sender()` | Message sender (`Send` / `Publish` / `SendCommandResponse`) |
| `ctx.Context()` | Underlying `context.Context` for timeouts/cancellation |
| `ctx.ParseBody[T]()` | Decode + `Validate` the body; api ≥ v1.2.37 ([§ Request and response helpers](#request-and-response-helpers)) |
| `ctx.SuccessResponse(...)` / `ctx.EmptySuccessResponse(...)` / `ctx.ErrorResponse(...)` | Standard envelopes; api ≥ v1.2.37 (same section) |
| `ctx.TenantId()` | Current tenant ID |
| `ctx.ComponentName()` | This component's name |
| `ctx.CorrelationId()` | Request correlation ID |

## Required elements checklist

- [ ] Target runtime resolved deliberately (client API vs integration API) — asked the user if the audience wasn't stated.
- [ ] Handler in `internal/api/endpoints/v1/` (or `internal/integration-api/endpoints/v1/`), signature `func Name(ctx request.Context) error`, importing that runtime's own `request` package.
- [ ] Request body is a named type with `func (r T) Validate(ctx context.Context) error`, parsed via `ctx.ParseBody[T]()` (`commonapi.RequestBody[T](ctx)` on api < v1.2.37).
- [ ] Every 5xx path logs the error and passes `errInternal` (never the raw error, never `nil`) to `ErrorResponse`.
- [ ] Database session obtained via `ctx.DatabaseSession()` — both return values checked, `defer db.Close()` called.
- [ ] Service obtained via `ctx.ServicesFactory()` — no direct repository construction in the handler.
- [ ] Business logic runs under `context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)`; the field exists in that runtime's `AppConfig` file, or was added in this task with `kairos-configure-appconfig`.
- [ ] Responses go through `ctx.SuccessResponse` / `EmptySuccessResponse` / `ErrorResponse` (the `commonapi.*` functions on api < v1.2.37).
- [ ] Swag annotations on the handler: `@Summary`, `@Router`, `@Success` using `commonapi.ResponseBody{data=...}` or `commonapi.EmptyResponseBody`, `@Failure` using `apierrors.ErrRequestErrorResponse`, and `@Security BearerAuth` when the route is JWT-guarded.
- [ ] Route registered in that runtime's `routes.go`, wrapped in `api.Handler(...)`.
- [ ] If a new service is introduced, `ServicesFactory` is updated in **every runtime that calls it** — `internal/api/request/`, `internal/event-handler/request/`, and/or `internal/integration-api/request/` (see `kairos-create-service`). If `internal/services/outbound_messenger.go` exists, the factory wraps `ctx.Sender()` with `services.NewSenderAdapter(...)`; otherwise it passes what the component's existing factories pass.
- [ ] If `internal/services/outbound_messenger.go` exists: **no `ctx.Sender().Publish(...)` call in the handler body.** The service publishes via `OutboundMessenger` before returning; a publish in an endpoint means the service is wrong, not the endpoint. Otherwise publish where the component already does and return the error.
- [ ] Cross-component saga starters (`Send` to another component triggered by a local mutation) also live in the service, not the handler. The handler should only `Send` directly when the endpoint has *no* local state to mutate (Row 3 in `kairos-messaging-model` § *Default pattern for HTTP writes*) or is dispatching a self-`Send` (Row 4).

## Common mistakes (RED FLAGS)

- Calling `ctx.DatabaseSession()` as if it returns only a session (the API variant returns `(session, error)` — the event-handler variant is the one that returns just a session).
- Forgetting `defer db.Close()`.
- Business logic inside the handler instead of in a service.
- Returning `fiber.NewError(...)` or `c.Status(...).JSON(...)` instead of the standardized helpers.
- Registering the route without wrapping in `api.Handler(...)`.
- Putting the handler on the wrong runtime — a frontend-facing endpoint on the integration API, or a bulk/machine-to-machine one on the client API. Ask when the audience is unstated.
- Importing the *other* runtime's `request` package (e.g. `internal/api/request` from an integration-API handler). The type won't match what that runtime's `api.Handler(...)` instantiates.
- Hand-writing an integration-API endpoint to bulk-load an entity — that's what the generated loaders are for. See `kairos-create-loader`.
- Hardcoded timeouts instead of `ctx.Config().DomainChangeTimeout`.
- Hardcoded values or secrets.
- Passing the raw error to `ErrorResponse` on a 5xx path (leaks pgx/service text), or passing `nil` (panics).
- `validate:"..."` struct tags on the request type — nothing reads them; validate in `Validate(ctx)`.
- Direct PostgreSQL queries bypassing the tenant-scoped session.
- `ctx.Sender().Publish(...)` in the handler after a service call — this duplicates whatever the service already published. Move the publish into the service if it isn't there yet; never duplicate it at the call site.
- Service method that mutates state but doesn't publish internally — that's a service defect (see `kairos-create-service`), not something the handler should paper over.
- Publishing an event with only `{ id: "..." }` instead of full state — violates event-carried state transfer; forces subscribers to call back. Fix it at the service.
