# Integration API

The REST surface (Go Fiber) for **other systems** — bulk load and machine-to-machine integration. The frontend-facing surface is the separate client API in `../api/`; keep endpoints on the side that matches their audience. This is a distinct binary (`cmd/integration-api`) with its own `request`, `config`, and `ServicesFactory`, and it does not import the client API's.

Bulk loading is handled by generated loaders, not hand-written endpoints — reach for `kairos-create-loader` before adding a route here.

Handlers are thin: parse input, delegate to a service via `ServicesFactory`, format the response. Outbound commands and events use typed schemas from `pkg/schema/`. Domain-event publishing happens **inside the service** via `OutboundMessenger`, not in the handler — see `kairos-create-service`.

For the canonical patterns — handler signature `func(request.Context) error`, the API-variant `request.Context` surface (`DatabaseSession()` returns `(session, error)` — check it; `Logger`, `Tracer`, `Sender`, `ServicesFactory`, `TenantId`, `CorrelationId`, etc.), `commonapi.{Success,Empty,Error}Response` helpers, `commonapi.RequestBody[T]` for parse+validate, and route registration via `api.Handler(...)` in `routes.go` — invoke:

- `kairos-create-api-endpoint` — single endpoint
- `kairos-create-paginated-endpoint` — list endpoint with `domain.PaginationFilter` / `dto.PaginatedResponse[T]` (`internal/dto`)
- `kairos-create-loader` — create a new loader and register it in the loader registry
- `kairos-test-api-endpoint` — HTTP-level tests via `apitest.New`

Schema versioning rules (V1 / V2 / `// Deprecated:` / parallel publish) live in `../../pkg/schema/AGENTS.md`. **If uncertain whether a change is breaking, ask the user.**
