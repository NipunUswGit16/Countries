# Client API

The REST surface (Go Fiber). This API is to be used exclusively by the frontend. Handlers are thin: parse input, delegate to a service via `ServicesFactory`, format the response. Outbound commands and events use typed schemas from `pkg/schema/`. Domain-event publishing happens **inside the service** via `OutboundMessenger`, not in the handler — see `kairos-create-service`.

For the canonical patterns — handler signature `func(request.Context) error`, the API-variant `request.Context` surface (`DatabaseSession()` returns `(session, error)` — check it; `Logger`, `Tracer`, `Sender`, `ServicesFactory`, `TenantId`, `CorrelationId`, etc.), `commonapi.{Success,Empty,Error}Response` helpers, `commonapi.RequestBody[T]` for parse+validate, and route registration via `api.Handler(...)` in `routes.go` — invoke:

- `kairos-create-api-endpoint` — single endpoint
- `kairos-create-paginated-endpoint` — list endpoint with `domain.PaginationFilter` / `dto.PaginatedResponse[T]` (`internal/dto`)
- `kairos-test-api-endpoint` — HTTP-level tests via `apitest.New`
- `kairos-test-functional-client-api` — functional (end-to-end) verification of externally observable API behavior via a Kairos CLI-created component; use when behavior is new or changed and lacks functional coverage — see root `AGENTS.md` § *Functional verification*

Schema versioning rules (V1 / V2 / `// Deprecated:` / parallel publish) live in `../../pkg/schema/AGENTS.md`. **If uncertain whether a change is breaking, ask the user.**
