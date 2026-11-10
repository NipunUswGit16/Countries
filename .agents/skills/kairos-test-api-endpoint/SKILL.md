---
name: kairos-test-api-endpoint
description: Writes HTTP-level tests for Kairos API endpoints using apitest.New (client API) or integrationapitest.New (integration API), constructing tenant-scoped test requests, registering routes, and asserting response status/body. Use when testing an API endpoint, writing handler HTTP tests, testing REST routes, or when the user says "test this endpoint", "write handler tests", or "apitest".
---

# Test a Kairos API Endpoint

Kairos API endpoints are tested with a test-API helper from `kairos-component-common`. It sets up a Fiber app, injects the right `ServicesFactory` and `AppConfig`, and provides a helper for constructing tenant-scoped HTTP requests. For pure business-logic tests, prefer `kairos-test-service` — faster and covers more behavioural surface.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Pick the helper that matches the runtime

Each REST runtime has its own test helper. The two expose the same `New(componentName, factory, cfg)` signature and the same `ApiRouter()` / `CreateApiRequest(...)` / `Do(...)` / `Close()` surface, so everything below applies to both — only the import and the component packages differ.

| Runtime under test | Test helper package | Component packages |
|---|---|---|
| Client API (`cmd/client-api`) | `kairos-component-common/api/test` → `apitest.New` | `internal/api/{endpoints/v1,config,request}` |
| Integration API (`cmd/integration-api`) | `kairos-component-common/api/test/integration` → `integrationapitest.New` | `internal/integration-api/{endpoints/v1,config,request}` |

If `cmd/integration-api/main.go` does not exist, the component has only the client API: use `apitest.New` and skip the integration import block below. (The integration helper ships with `kairos-component-common/api` ≥ v1.2.32.)

Use the helper belonging to the runtime that actually registers the route. The integration helper additionally wires the bulk-load routes and exposes `LoadRegistry()` for asserting against registered loaders — reach for it when the subject is a loader rather than a hand-written endpoint (see `kairos-create-loader`).

The rest of this skill uses the client-API helper; substitute per the table for integration-API endpoints.

## Standard imports

```go
import (
    "net/http"
    "strings"
    "testing"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
    "github.com/stretchr/testify/require"

    "bitbucket.org/ifs-pd/kairos-component-common/api"
    apitest "bitbucket.org/ifs-pd/kairos-component-common/api/test"
    pgmocks "bitbucket.org/ifs-pd/nga-common/postgres/client/mocks"
    endpoints "bitbucket.org/ifs-pd/kairos-component-template/internal/api/endpoints/v1"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/api/config"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/api/request"
)
```

For an integration-API endpoint, swap the helper and the three component imports:

```go
import (
    integrationapitest "bitbucket.org/ifs-pd/kairos-component-common/api/test/integration"
    endpoints "bitbucket.org/ifs-pd/kairos-component-template/internal/integration-api/endpoints/v1"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/integration-api/config"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/integration-api/request"
)
```

## Template

```go
func TestCreateExampleEndpoint(t *testing.T) {
    testApi := apitest.New(
        "test-component",
        &request.ServicesFactory{},
        &config.AppConfig{},
    )
    defer testApi.Close()

    // ApiRouter() is a plain fiber.Router: wrap handlers in api.Handler, as routes.go does.
    testApi.ApiRouter().Post("/examples", api.Handler(endpoints.CreateExampleModel))

    // The repository's INSERT goes to the mock session; stub it (see "Stub the session").
    execResult := pgmocks.NewMockExecResult()
    execResult.On("RowsAffected").Return(int64(1)).Maybe()
    testApi.TestContext().MockSession.
        On("Exec", mock.Anything, mock.Anything, mock.Anything, mock.Anything).
        Return(execResult, nil)

    body := `{"name":"Test Example","customField":"value"}`
    req, err := testApi.CreateApiRequest("test-tenant", http.MethodPost, "/examples", strings.NewReader(body), nil)
    require.NoError(t, err)
    req.Header.Set("Content-Type", "application/json")

    res, err := testApi.Do(req)
    require.NoError(t, err)

    assert.Equal(t, http.StatusOK, res.StatusCode)
}
```

## `apitest.New` signature

```go
apitest.New(componentName string, factory *SF, cfg *Cfg) *TestApi

// Integration API — same parameters, different return type:
integrationapitest.New(componentName string, factory *SF, cfg *Cfg) *TestIntegrationApi
```

- `componentName` — arbitrary label for the test component.
- `factory` — a real or fake `ServicesFactory`. The real factory works: its repositories get the harness's mock session (see "Stub the session"). For isolation, construct a fake factory type.
- `cfg` — the typed `AppConfig` for the component under test. If it has a `DomainChangeTimeout` field (`grep -l 'type AppConfig' internal/api/config/*.go | xargs grep -l DomainChangeTimeout | grep -q .`; `internal/integration-api/config/*.go` for the integration API), set it non-zero (`&config.AppConfig{DomainChangeTimeout: 5 * time.Second}`): a zero timeout expires the context before the service runs. Otherwise `&config.AppConfig{}`.

Register routes on `testApi.ApiRouter()` with the same paths as `routes.go`, wrapped in `api.Handler(...)` exactly as in `routes.go`. `ApiRouter()` returns a plain `fiber.Router`, so an unwrapped `func(request.Context) error` does not compile.

## Request construction

```go
CreateApiRequest(tenantId, method, path string, body io.Reader, claims map[string]any) (*http.Request, error)
```

- Signs a bearer token carrying the tenant (plus `claims`, which may be `nil`).
- Prefixes `path` with `/api` unless it already starts with it. Append query parameters to `path`.
- Sends `body` as is: pass `strings.NewReader(json)` or `nil`. It does **not** set `Content-Type`; set `req.Header.Set("Content-Type", "application/json")` whenever there is a body, or `ParseBody[T]` / `RequestBody[T]` fails to parse it.

## Stub the session

`TestContext().MockSession` is a testify mock. Only `SetDefaultSchema`, `Commit` and `Rollback` are pre-stubbed; any `Exec`, `QueryRow` or `Query` the endpoint's service makes without a stub panics. Stub every call the code path makes before `Do`:

| Code path | Stub |
|---|---|
| Insert succeeds (an `Exec` with exactly two SQL arguments, the template's `id`/`data` insert) | `testApi.TestContext().ResetMocks()` (stubs that `Exec` with `RowsAffected` = 1) |
| Update / delete / any other `Exec` succeeds | `MockSession.On("Exec", …)` with one `mock.Anything` for the context, one for the SQL and one per SQL argument, returning `pgmocks.NewMockExecResult()` as in the template |
| Insert fails | `MockExecError(err)` |
| Read one row | `MockQueryRowWithData(value)`, or `MockSession.On("QueryRow", …).Return(row)` with a `pgmocks.NewMockRow()` whose `Scan` fills `*id` and `*data` |
| Row not found | `MockQueryRowNotFound()` (`Scan` returns `pgx.ErrNoRows`) |
| List | `MockQueryWithData(rows)`, `MockQueryEmpty()` or `MockQueryError(err)` |
| Session unavailable | `MockDatabaseSessionError(err)` |

The helpers are methods on `TestContext()`. With `On(...)` directly, pass one `mock.Anything` for the context, one for the SQL, and one per SQL argument: the mock records them as separate arguments, and a count mismatch panics.

## Testing validation failures

```go
req, err := testApi.CreateApiRequest("test-tenant", http.MethodPost, "/examples", strings.NewReader(`{"name":""}`), nil)
require.NoError(t, err)
req.Header.Set("Content-Type", "application/json")

res, err := testApi.Do(req)
require.NoError(t, err)

assert.Equal(t, http.StatusBadRequest, res.StatusCode)
```

Assert exactly 400, never "400 or 500". It depends on `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/api`:

- **≥ v1.2.32:** a returned `RequestBody` error keeps its 400.
- **< v1.2.32:** a returned `RequestBody` error gives 500. Expect 400 only if the endpoint renders it with `ErrorResponse(ctx, fiber.StatusBadRequest, …)` (see `kairos-create-api-endpoint` § Returning the `RequestBody` error); if it returns the error, fix the endpoint rather than the assertion.

Validation runs before any database call in the template, so this test needs no session stubs. If the endpoint opens the session or queries first, stub those calls too.

## Domain-event assertions belong in service tests

State-mutating endpoints route through services, and the service is what publishes the domain `*EventV1` via `OutboundMessenger` (see `kairos-create-service` and `kairos-test-service`). Endpoint tests therefore do **not** assert on what was published — they assert the HTTP contract (status code, body shape, validation behaviour). Move event assertions to the service test, where you can verify the concrete event type, full event-carried-state payload, and partition key against the persisted aggregate.

The only outbound-message case where assertions stay at this layer is Row 3 / Row 4 of the HTTP-write decision table in `kairos-messaging-model` — endpoints that *don't* route through a service because they own no local state (cross-component triggers, async self-`Send`). For those, `testApi.TestContext().FakeSender.SentMessages()` is still the right hook:

```go
// Only for endpoints that emit a command directly (no local mutation).
sent := testApi.TestContext().FakeSender.SentMessages()
assert.Len(t, sent, 1)
```

If you find yourself wanting to assert published events here for an endpoint that *does* have a service, that's a signal the test wants to live in `kairos-test-service` instead.

## Required elements checklist

- [ ] Test file is `{source}_test.go` next to the endpoint
- [ ] Helper matches the runtime under test — `apitest.New` for client API, `integrationapitest.New` for integration API
- [ ] Test helper invoked with real `ServicesFactory` (or a test double)
- [ ] `defer testApi.Close()` to release resources
- [ ] Route registered on `testApi.ApiRouter()`, wrapped in `api.Handler(...)`
- [ ] Request built with `testApi.CreateApiRequest(tenantId, method, path, body, claims)` — **never a raw `httptest.NewRequest`** (tenant context would be missing) — plus `Content-Type: application/json` when there is a body
- [ ] Every session call on the code path stubbed (see "Stub the session")
- [ ] Both status code and response body asserted
- [ ] Error and validation paths covered, not just the happy path

## Common mistakes (RED FLAGS)

- Building a raw `*http.Request` — bypasses tenant-scope and correlation setup.
- Missing `Content-Type: application/json` — the body fails to parse and the test asserts the wrong failure.
- Unstubbed `Exec` / `QueryRow` / `Query` on `MockSession` — the test panics.
- Accepting "400 or 500" on a validation test — it hides a broken error path.
- Testing an integration-API endpoint with `apitest.New` — the generic type arguments come from that runtime's `request`/`config` packages, and the bulk-load routes won't be wired.
- Forgetting `defer testApi.Close()` — leaks resources across tests.
- Not asserting both status **and** body.
- Skipping validation tests — body parsing (`ctx.ParseBody[T]()` / `commonapi.RequestBody[T]`) is most likely to break.
- Asserting domain-event publishing at this layer when the endpoint routes through a service — write that test in `kairos-test-service`, where the concrete event type, payload, and partition key are visible. Endpoint tests stop at the HTTP contract.
