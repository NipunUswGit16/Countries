---
name: kairos-test-functional-client-api
description: Authors Godog/Cucumber functional tests for a Kairos Client API using the nga-testing/functional library/framework, Postgres via testcontainers, JSON files under testdata per scenario, and optional mock outbound HTTP dependencies. Use when adding or extending black-box Client API scenarios, BDD feature files, component functional tests, or when the user says "functional test", "godog", "feature file", or "testdata-driven API test". Do not use for isolated Fiber handler tests; those stay in-process without this stack.
---

# Functional Test a Kairos Client API

This skill covers **component-level** functional tests: real HTTP against an in-process Client API, real Postgres in a container, and scenario data in JSON files. It complements smaller in-process API tests that use `apitest` without `nga-testing/functional`.

Follow **`kairos-database-model`** for JSONB field naming in DB JSON files (camelCase under `data`).

## When To Use

- Exercising the Client API through HTTP with proper tenant authorization, migrations, and persistence.
- Keeping scenarios readable in Gherkin while driving fixtures and expectations from `testdata/*.json`.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

If `go list -m bitbucket.org/ifs-pd/nga-testing/functional >/dev/null 2>&1` fails, run `go get bitbucket.org/ifs-pd/nga-testing/functional@v1.0.1`, then re-run any version checks you made earlier (the `go get` can move other pins). If it succeeds, skip this step.

## Test Layout

Each suite is one package under `test/functional/<suite>/` in the root module, for example `test/functional/clientapi/`. `make test-functional` runs every package under `./test/...`, and `make test-unit` skips any path containing `/test/`, so the location alone selects the suite. Do not add a build tag.

Per suite directory:

- `features/*.feature` — scenarios (names must normalize cleanly; see below).
- `testdata/` — one set of JSON files per scenario name.
- `<suite>_test.go` — the Godog `TestSuite` entry point.
- `step_test.go` — `ScenarioInitializer` and step registration.
- `setup_test.go` — the builders: API factory, dependency properties, assertion rules.

Import paths (module is `bitbucket.org/ifs-pd/nga-testing/functional`):

- `ngagodog "bitbucket.org/ifs-pd/nga-testing/functional/godog"`
- `godogclientapi "bitbucket.org/ifs-pd/nga-testing/functional/godog/clientapi"`
- `"bitbucket.org/ifs-pd/nga-testing/functional/testctx"`
- `"bitbucket.org/ifs-pd/nga-testing/functional/testctx/clientapi"`
- `"bitbucket.org/ifs-pd/nga-testing/functional/testctx/dependency/postgres"`
- `"bitbucket.org/ifs-pd/nga-testing/functional/testctx/dependency/httpservice"` (when using mock outbound HTTP)

## Feature Files

- Pick scenario names that normalize to stable filenames (letters, numbers, underscores; spaces become underscores; other punctuation is stripped). Normalization matches `testctx.NormalizedScenarioName`.
- Use **exact step text** that matches the regexes you register in Go (see below). Typical flow: Postgres up → API running → seed DB → send HTTP request → assert status → assert body → assert DB (→ optional outbound HTTP assertion) → terminate after scenario.

Example feature fragment:

```gherkin
Feature: Create resource via API

  Scenario: Create succeeds and persists
    Given Postgres is running
    And the Client API is running
    And a seeded Postgres database
    When I send a POST request to "/api/v1/orders"
    Then the response status code should be 200
    And the response body should match the expected response
    And Postgres should match the expected state
```

The method and path in the `When` step are **not** used by the default step implementation; the request is loaded from `testdata`. Write the real path anyway, so the scenario reads like the request it sends.

## JSON Test Data

For normalized scenario name `create_succeeds_and_persists`:

| File | Purpose |
|------|---------|
| `testdata/create_succeeds_and_persists.db.initial.json` | Postgres seed state |
| `testdata/create_succeeds_and_persists.db.expected.json` | Expected Postgres state after the scenario |
| `testdata/create_succeeds_and_persists.http.request.json` | Inbound HTTP request to the Client API |
| `testdata/create_succeeds_and_persists.http.response.json` | Expected HTTP response (body must be a JSON object for deep comparison) |

**DB JSON shape** — table names as keys, each an array of rows with `id` (UUID string) and `data` (object):

```json
{
  "orders": [
    {
      "id": "018c5c6e-9d4f-7b3a-9f2e-1a2b3c4d5e6f",
      "data": {
        "id": "018c5c6e-9d4f-7b3a-9f2e-1a2b3c4d5e6f",
        "customerName": "ACME",
        "createdAt": "2024-01-01T00:00:00Z",
        "updatedAt": "2024-01-01T00:00:00Z"
      }
    }
  ]
}
```

**HTTP request file** (`*.http.request.json`). `path` is the full route, including the `/api` prefix the router mounts:

```json
{
  "method": "POST",
  "path": "/api/v1/orders",
  "headers": {
    "Content-Type": "application/json"
  },
  "body": {
    "customerName": "ACME"
  }
}
```

**HTTP response file must use camelCase** for `statusCode`:

```json
{
  "statusCode": 200,
  "headers": {
    "Content-Type": "application/json"
  },
  "body": {
    "success": true,
    "data": {
      "id": "018c5c6e-9d4f-7b3a-9f2e-1a2b3c4d5e6f",
      "customerName": "ACME"
    }
  }
}
```

## Godog Suite Wiring

`InitClientAPITestSuite` registers Postgres and wires suite lifecycle; pass extra dependencies (e.g. mock HTTP) as variadic providers:

```go
var opts godog.Options

func init() {
    opts = ngagodog.DefaultGodogOptions()
    godog.BindCommandLineFlags("godog.", &opts)
}

func TestClientAPI(t *testing.T) {
    var depCtx *testctx.DependencyContext
    opts.TestingT = t

    suiteCtx, cancel := ngagodog.SuiteContext()
    defer cancel()
    opts.DefaultContext = suiteCtx

    s := godog.TestSuite{
        Name: "Client API",
        TestSuiteInitializer: func(gCtx *godog.TestSuiteContext) {
            godogclientapi.InitClientAPITestSuite(gCtx, &depCtx)
        },
        ScenarioInitializer: func(ctx *godog.ScenarioContext) {
            initScenario(ctx, depCtx)
        },
        Options: &opts,
    }
    if s.Run() != 0 {
        t.Fail()
    }
}
```

## Scenario Step Wiring

Capture `scenarioName` in `Before` from the scenario, build `ClientAPITestContextSettings` from the three builders in `setup_test.go` (see [§ Builders](#builders)), then call `Setup()` and register steps.

Reuse the helpers from `godog/clientapi` (suite init, Postgres/API/seed/send/assert/terminate) and, for outbound HTTP, `godog/clientapi.StepAssertTrackedHTTPRequests`, which delegates to `godog/httpservice.AssertTrackedHTTPRequestsStep`.

```go
func initScenario(ctx *godog.ScenarioContext, depCtx *testctx.DependencyContext) {
    var testCtx *clientapi.ClientAPITestContext
    var scenarioName string

    ctx.Before(func(ctx context.Context, sc *godog.Scenario) (context.Context, error) {
        scenarioName = testctx.NormalizedScenarioName(sc.Name)
        settings := clientapi.NewClientAPITestContextSettings(
            newApiClient,
            depClientProps(),
            httpRespAssertionRules(),
        )
        testCtx = clientapi.NewClientAPITestContext(scenarioName, depCtx, settings)
        testCtx.Setup()
        testCtx.Log()
        return ctx, nil
    })

    ctx.Given(`^Postgres is running$`, godogclientapi.StepPingPostgres(&testCtx))
    ctx.Given(`^the Client API is running$`, godogclientapi.StepRunClientAPI(&testCtx))
    ctx.Given(`^a seeded Postgres database$`, godogclientapi.StepSeedPostgresDB(&testCtx, &scenarioName))
    ctx.When(
        `^I send a (POST|GET|PUT|PATCH|DELETE) request to "([^"]*)"$`,
        godogclientapi.StepSendHTTPRequest(&testCtx, &scenarioName),
    )
    ctx.Then(`^the response status code should be (\d+)$`, godogclientapi.StepAssertHTTPResponseStatusCode(&testCtx))
    ctx.Then(`^the response body should match the expected response$`, godogclientapi.StepAssertHTTPResponseBody(&testCtx, &scenarioName))
    ctx.Then(`^Postgres should match the expected state$`, godogclientapi.StepAssertPostgresDBState(&testCtx, &scenarioName))
    ctx.After(godogclientapi.StepTerminate(&testCtx))
}
```

Non-JSON error bodies: register `StepAssertHTTPResponseBodyContainsText` with a matching `Then` step when needed.

`StepSendHTTPRequest` reads `testdata/{scenario}.http.request.json` and performs the call against the running API (including Bearer token when the context has one).

## Dynamic Assertions

Generated UUIDs and timestamps must not be asserted as exact strings unless values are fixed in test data. Events published in the request land in `event_outbox`, so list that table in `db.expected.json` and give its generated fields rules too. Attach rules in two places:

1. **Postgres** — `postgres.NewAssertionRules` with `postgres.NewDataAssertionRule`, `postgres.NewIDAssertionRule`, etc., keyed by Postgres locator format (`table:…column:…jsonFieldPath:…`). Pass via `postgres.PropKeyAssertionRules` in the map returned from your `DependencyClientPropertiesProvider` for `postgres.DependencyPostgres`.

2. **HTTP response body** — `clientapi.NewHTTPResponseAssertionRules` / `clientapi.NewHTTPResponseDataAssertionRule` with `testctx.AssertUUIDPresent`, `testctx.AssertTimeRFC3339Present`, etc. Pass the provider into `NewClientAPITestContextSettings`.

## Builders

`setup_test.go` holds three builders. `newApiClient` builds the API the way `cmd/client-api/main.go` does, using the component's own `request`, `config` and route packages:

```go
func newApiClient(serviceID string) any {
    servicesFactory := &request.ServicesFactory{}
    apiInstance, _ := api.New[request.ServicesFactory, config.AppConfig](serviceID, servicesFactory)
    internalapi.InitRoutes(apiInstance.ApiRouter())
    return apiInstance
}

func depClientProps() testctx.DependencyClientPropertiesProvider {
    return func(_ string) map[testctx.DependencyName]testctx.DependencyClientProperties {
        return map[testctx.DependencyName]testctx.DependencyClientProperties{
            postgres.DependencyPostgres: {
                postgres.PropKeyAssertionRules: postgres.NewAssertionRules(
                    postgres.NewIDAssertionRule("orders", testctx.AssertUUIDPresent),
                    postgres.NewDataAssertionRule("orders", "createdAt", testctx.AssertTimeRFC3339Present),
                    postgres.NewIDAssertionRule("event_outbox", testctx.AssertUUIDPresent),
                ),
            },
        }
    }
}

func httpRespAssertionRules() testctx.AssertionRuleProvider {
    return clientapi.NewHTTPResponseAssertionRules(
        clientapi.NewHTTPResponseDataAssertionRule("id", testctx.AssertUUIDPresent),
        clientapi.NewHTTPResponseDataAssertionRule("createdAt", testctx.AssertTimeRFC3339Present),
    )
}
```

## Optional Mock HTTP Dependencies

When the Client API calls an outbound HTTP service:

1. Define a `testctx.DependencyName` constant (e.g. `partner_service`).
2. Register `httpservice.NewHTTPServiceDependency(name, provider)` as an extra argument to `InitClientAPITestSuite`.
3. Include that name in `depClientProps` (often with an empty property map).
4. Add `testdata/{normalized_scenario}.http.{name}.mocks.json` with top-level `"mocks"` (request/response pairs) and `"expected"` (requests the mock must receive). The `service_name` segment **must equal** the dependency name string.
5. Inject the mock base URL when constructing the API under test (e.g. from `(*httpservice.Client).BaseURL()` resolved via `testCtx.DependencyClient(name)` inside your `NewClientAPIFunc` closure).
6. Register a `Then` step that calls `godogclientapi.StepAssertTrackedHTTPRequests(&testCtx, &scenarioName, name)`.

Custom rules for mock routing or tracked-request assertions are set in Go on `httpservice.HTTPMockSpec.Rules` inside your `HTTPMockSpecProvider`; they are never read from JSON.

## Verification

- `make test-functional` runs every suite; `go test ./test/functional/<suite>/` runs one.
- Ensure Docker is available for the Postgres testcontainer unless your CI already provides it.

## Required Checklist

- [ ] Feature scenario name normalizes to the intended `testdata/` prefix.
- [ ] All four core JSON files exist for each scenario (initial DB, expected DB, HTTP request, HTTP response) unless a scenario is intentionally partial (then do not register steps that require missing files).
- [ ] `ctx.Before` sets `scenarioName` with `testctx.NormalizedScenarioName(sc.Name)` before any step uses it.
- [ ] `ctx.After` uses `godogclientapi.StepTerminate(&testCtx)`.
- [ ] HTTP response expected `body` is a JSON object when using `StepAssertHTTPResponseBody`.
- [ ] JSONB field names under `data` use camelCase.
- [ ] Dynamic fields covered by Postgres and/or HTTP assertion rules.

## Common Mistakes

- Mismatch between feature `When` regex and the method words used in scenarios.
- A build tag on the suite, or a suite outside `test/functional/`: `make test-functional` no longer finds it.
- Forgetting to register an extra dependency name in `depClientProps`, causing `DependencyClient` to be nil when building the service.
- Putting assertion rules only in JSON — `HTTPMockSpec.Rules` must be attached in Go.
- Using snake_case inside `data` blobs — breaks parity with production Kairos JSONB.
