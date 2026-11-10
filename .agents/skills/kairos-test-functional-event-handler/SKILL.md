---
name: kairos-test-functional-event-handler
description: Authors Godog/Cucumber functional tests for a Kairos Event Handler using the nga-testing/functional library/framework, Postgres via testcontainers, JSON files under testdata per scenario, CloudEvent publication over HTTP, and optional mock outbound HTTP dependencies. Use when adding or extending black-box Event Handler scenarios, BDD feature files, component functional tests, or when the user says "functional event handler test", "godog event handler", "event handler feature file", or "testdata-driven event handler test". Do not use for isolated command/event handler unit tests that stay in-process without this stack.
---

# Functional Test a Kairos Event Handler

This skill covers **component-level** functional tests: an in-process Event Handler behind HTTP, real Postgres in a container, inbound CloudEvents driven from JSON, and optional assertions on outbound HTTP recorded by mock dependencies.

Follow **`kairos-database-model`** for JSONB field naming in DB JSON files (camelCase under `data`).

## When To Use

- Exercising the Event Handler through its HTTP intake (CloudEvents POST to `/api/{eventType}`) with tenant isolation and persistence.
- Keeping scenarios readable in Gherkin while driving fixtures, inbound events, and expected DB state from `testdata/*.json`.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

If `go list -m bitbucket.org/ifs-pd/nga-testing/functional >/dev/null 2>&1` fails, run `go get bitbucket.org/ifs-pd/nga-testing/functional@v1.0.1`, then re-run any version checks you made earlier (the `go get` can move other pins). If it succeeds, skip this step.

## Test Layout

Each suite is one package under `test/functional/<suite>/` in the root module, for example `test/functional/eventhandler/`. `make test-functional` runs every package under `./test/...`, and `make test-unit` skips any path containing `/test/`, so the location alone selects the suite. Do not add a build tag.

Per suite directory:

- `features/*.feature` — scenarios (names must normalize cleanly; see below).
- `testdata/` — one set of JSON files per scenario name.
- `<suite>_test.go` — the Godog `TestSuite` entry point.
- `step_test.go` — `ScenarioInitializer` and step registration.
- `setup_test.go` — the builders: event-handler factory and dependency properties.

Import paths (module is `bitbucket.org/ifs-pd/nga-testing/functional`):

- `ngagodog "bitbucket.org/ifs-pd/nga-testing/functional/godog"`
- `godogeventhandler "bitbucket.org/ifs-pd/nga-testing/functional/godog/eventhandler"`
- `"bitbucket.org/ifs-pd/nga-testing/functional/testctx"`
- `"bitbucket.org/ifs-pd/nga-testing/functional/testctx/eventhandler"`
- `"bitbucket.org/ifs-pd/nga-testing/functional/testctx/dependency/postgres"`
- `"bitbucket.org/ifs-pd/nga-testing/functional/testctx/dependency/httpservice"` (when using mock outbound HTTP)

## Feature Files

- Pick scenario names that normalize to stable filenames (letters, numbers, underscores; spaces become underscores; other punctuation is stripped). Normalization matches `testctx.NormalizedScenarioName`.
- Use **exact step text** that matches the regexes you register in Go (see below). Typical flow: Postgres up → Event Handler running → seed DB → publish CloudEvent (from testdata) → assert Postgres (→ optional outbound HTTP assertion) → terminate after scenario.

Example feature fragment:

```gherkin
Feature: Process inbound domain event

  Scenario: Handler persists state after event
    Given Postgres is running
    And the Event Handler is running
    And a seeded Postgres database
    When a "ignored-label-from-gherkin" event is published
    Then the Event Handler processes the event and updates Postgres accordingly
```

The string captured in the `When` step is **not** used by the default `StepPublishEvent` implementation: the CloudEvent is loaded entirely from `testdata/{scenario}.event.json`. Keep the step wording aligned with your registered regex anyway so scenarios stay consistent.

## JSON Test Data

For normalized scenario name `handler_persists_state_after_event`:

| File | Purpose |
|------|---------|
| `testdata/handler_persists_state_after_event.db.initial.json` | Postgres seed state |
| `testdata/handler_persists_state_after_event.db.expected.json` | Expected Postgres state after processing |
| `testdata/handler_persists_state_after_event.event.json` | CloudEvent JSON (supports `{tenantId}` replacement in the raw file) |
| `testdata/handler_persists_state_after_event.http.{service_name}.mocks.json` | Optional mock responses and expected outbound HTTP trace for a named `httpservice` dependency |

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

**CloudEvent file** (`*.event.json`): must unmarshal into `github.com/cloudevents/sdk-go/v2/event.Event` after `{tenantId}` substitution.

- **`type`** — required; must be non-empty. The harness posts to `http://localhost:{serverPort}/api/{type}`.
- **`source`** — required for publishing. The harness extracts the tenant ID as the substring **after the last `.`** in `source`. That value must equal the scenario tenant ID after substitution, e.g. use a placeholder so the suffix matches: `"source": "my.component.{tenantId}"`.
- **`data`** — non-empty JSON payload; becomes the HTTP body (the harness requires non-empty event data).

Minimal example (adjust `type` to your routed CloudEvent type):

```json
{
  "specversion": "1.0",
  "id": "00000000-0000-0000-0000-000000000001",
  "source": "my.component.{tenantId}",
  "type": "my-component.my-domain-event.1",
  "datacontenttype": "application/json",
  "data": {
    "orderId": "018c5c6e-9d4f-7b3a-9f2e-1a2b3c4d5e6f",
    "status": "processing"
  }
}
```

For commands that carry the `ifscommandid` extension, include it in the JSON so it is mapped to HTTP (`Ce-Ifscommandid`) on publish.

## Godog Suite Wiring

`InitEventHandlerTestSuite` registers Postgres and wires suite lifecycle; pass extra dependencies (e.g. mock HTTP) as variadic providers:

```go
var opts godog.Options

func init() {
	opts = ngagodog.DefaultGodogOptions()
	godog.BindCommandLineFlags("godog.", &opts)
}

func TestEventHandler(t *testing.T) {
	var depCtx *testctx.DependencyContext
	opts.TestingT = t

	suiteCtx, cancel := ngagodog.SuiteContext()
	defer cancel()
	opts.DefaultContext = suiteCtx

	s := godog.TestSuite{
		Name: "Event Handler",
		TestSuiteInitializer: func(gCtx *godog.TestSuiteContext) {
			godogeventhandler.InitEventHandlerTestSuite(gCtx, &depCtx)
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

Capture `scenarioName` in `Before` from the scenario, build `EventHandlerTestContextSettings` with `NewEventHandlerTestContextSettings(newEventHandler, depClientProps())` (see [§ Builders](#builders)), then call `Setup()` and register steps.

Reuse helpers from `godog/eventhandler`: suite init, Postgres ping/run handler/seed/publish/assert DB/terminate. For outbound HTTP, use `godog/eventhandler.StepAssertTrackedHTTPRequests`, which delegates to `godog/httpservice.AssertTrackedHTTPRequestsStep`.

```go
func initScenario(ctx *godog.ScenarioContext, depCtx *testctx.DependencyContext) {
	var testCtx *eventhandler.EventHandlerTestContext
	var scenarioName string

	ctx.Before(func(ctx context.Context, sc *godog.Scenario) (context.Context, error) {
		scenarioName = testctx.NormalizedScenarioName(sc.Name)
		settings := eventhandler.NewEventHandlerTestContextSettings(
			newEventHandler,
			depClientProps(),
		)
		testCtx = eventhandler.NewEventHandlerTestContext(scenarioName, depCtx, settings)
		testCtx.Setup()
		testCtx.Log()
		return ctx, nil
	})

	ctx.Given(`^Postgres is running$`, godogeventhandler.StepPingPostgres(&testCtx))
	ctx.Given(`^the Event Handler is running$`, godogeventhandler.StepRunEventHandler(&testCtx))
	ctx.Given(`^a seeded Postgres database$`, godogeventhandler.StepSeedPostgresDatabase(&testCtx, &scenarioName))
	ctx.When(
		`^a "([^"]*)" (?:event|command) is published$`,
		godogeventhandler.StepPublishEvent(&testCtx, &scenarioName),
	)
	ctx.Then(
		`^the Event Handler processes the (?:event|command) and updates Postgres accordingly$`,
		godogeventhandler.StepAssertPostgresDatabaseState(&testCtx, &scenarioName),
	)
	ctx.After(godogeventhandler.StepTerminate(&testCtx))
}
```

`StepPublishEvent` reads `testdata/{scenario}.event.json`, applies `{tenantId}` replacement via `TenantEventFromFile`, and posts to the running handler.

## Dynamic Assertions

Generated UUIDs and timestamps must not be asserted as exact strings unless values are fixed in test data. For **Postgres** expected state, attach rules via `postgres.NewAssertionRules` with `postgres.NewDataAssertionRule`, `postgres.NewIDAssertionRule`, etc., keyed by the Postgres locator format used by the harness (`table:…column:…jsonFieldPath:…`). Pass via `postgres.PropKeyAssertionRules` in the map returned from your `DependencyClientPropertiesProvider` for `postgres.DependencyPostgres`.

## Builders

`setup_test.go` holds the builders. `newEventHandler` builds the handler the way `cmd/event-handler/main.go` does, using the component's own `request`, `config` and handler packages (`eventhandler` is `kairos-component-common/event-handler`, `config` its `config` package, `internalconfig` the component's `internal/event-handler/config`):

```go
func newEventHandler(serviceID string) (any, error) {
	servicesFactory := &request.ServicesFactory{}
	deps, err := common.CreateDefaultDependencies[
		request.ServicesFactory,
		config.Config,
		*config.Config,
		internalconfig.AppConfig,
	](serviceID, servicesFactory)
	if err != nil {
		return nil, err
	}
	eh := eventhandler.NewWithDependencies(deps)
	internaleventhandler.InitHandlers(eh)
	return eh, nil
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
```

Events and commands the handler sends land in `event_outbox`, so list that table in `db.expected.json` and give its generated fields rules too.

### Failure scenarios

There is no Event-Handler-specific HTTP response assertion helper: `StepPublishEvent` returns an error on any non-2xx. To test a message the handler rejects, register your own `When` step that calls `testCtx.PublishEvent(ctx, ev)` and expects the error, then assert Postgres. What `db.expected.json` holds depends on `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/event-handler`:

- **≥ v1.2.46:** the transaction rolls back, so the expected state equals `db.initial.json`.
- **< v1.2.46:** the handler's partial writes, its `event_outbox` rows and the `idempotency` row are committed, and the message is never retried. Write the expected state for that, and add a `#` comment above the scenario saying it pins the pre-v1.2.46 behaviour. The lasting fix is event-handler ≥ v1.2.46, but that tag also requires common ≥ v1.4.2, eventsender v0.1.1 and Go 1.27.2, crossing common v1.4.0 and event-handler v1.2.44, which change behaviour. Suggest adopting it through `kairos-component-update`, not a bare `go get`; don't block on it or do it inside this task, and re-run the version checks after it.

## Optional Mock HTTP Dependencies

When the Event Handler calls an outbound HTTP service during processing:

1. Define a `testctx.DependencyName` constant (e.g. `partner_service`).
2. Register `httpservice.NewHTTPServiceDependency(name, provider)` as an extra argument to `InitEventHandlerTestSuite`.
3. Include that name in `depClientProps` (often with an empty property map) so the scenario resolves a client.
4. Add `testdata/{normalized_scenario}.http.{name}.mocks.json` with top-level `"mocks"` (request/response pairs) and `"expected"` (requests the mock must receive). The `service_name` segment **must equal** the dependency name string.
5. Inject the mock base URL when constructing the handler under test (e.g. from `(*httpservice.Client).BaseURL()` resolved via `testCtx.DependencyClient(name)` inside your `NewEventHandlerFunc` closure).
6. Register a `Then` step that calls `godogeventhandler.StepAssertTrackedHTTPRequests(&testCtx, &scenarioName, name)`.

Custom rules for mock routing or tracked-request assertions are set in Go on `httpservice.HTTPMockSpec.Rules` inside your `HTTPMockSpecProvider`; they are never read from JSON.

## Verification

- `make test-functional` runs every suite; `go test ./test/functional/<suite>/` runs one.
- Ensure Docker is available for the Postgres testcontainer unless your CI already provides it.

## Required Checklist

- [ ] Feature scenario name normalizes to the intended `testdata/` prefix.
- [ ] Core JSON files exist for each scenario: initial DB, expected DB, and `event.json` (unless a scenario intentionally omits a step that requires a file).
- [ ] `ctx.Before` sets `scenarioName` with `testctx.NormalizedScenarioName(sc.Name)` before any step uses it.
- [ ] `ctx.After` uses `godogeventhandler.StepTerminate(&testCtx)`.
- [ ] CloudEvent `type` matches the HTTP route your handler exposes; `source` suffix matches tenant ID after `{tenantId}` substitution.
- [ ] JSONB field names under `data` use camelCase.
- [ ] Dynamic fields covered by Postgres assertion rules where needed.

## Common Mistakes

- `source` without a `.<tenantId>` suffix — publish fails tenant extraction.
- Empty `data` on the CloudEvent — publish fails before assertions run.
- Mismatch between the `When` regex and the wording used in scenarios.
- A build tag on the suite, or a suite outside `test/functional/`: `make test-functional` no longer finds it.
- Forgetting to register an extra dependency name in `depClientProps`, causing `DependencyClient` to be nil when building the handler or asserting tracked HTTP.
- Putting assertion rules only in JSON — `HTTPMockSpec.Rules` must be attached in Go.
- Using snake_case inside `data` blobs — breaks parity with production Kairos JSONB.
