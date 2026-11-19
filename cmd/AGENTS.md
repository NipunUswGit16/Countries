# Command Entry Points

This directory holds the `main()` entry points for the component's runtime binaries — `client-api/main.go`, `event-handler/main.go`, and `integration-api/main.go` (plus `db-script-runner/` and `dataloader/`, which ship only Dockerfiles). The files here are **wiring only**: they load config, build loggers and factories, start the runtime framework, and hand control off. Business logic, domain types, message schemas, and hand-written SQL never live in `cmd/`.

The set of directories here is load-bearing beyond the build: the toolkit treats every `cmd/<app>/` that contains a `main.go` as an app, and derives from that list which packages `kairos-gen` scans. The presence of `main.go` is the signal — a directory under `cmd/` without one (like `db-script-runner` or `dataloader`) is not an app and is not scanned. Adding or renaming an app changes what gets generated — see `kairos-topic-subscriptions`.

## ⚠️ Mandatory `+kairos:sql:lib:` directives — DO NOT DELETE

Two comment directives in this directory are **required** — removing or renaming either silently drops the corresponding migration:

- `cmd/client-api/main.go` or `cmd/integration-api/main.go` → `// +kairos:sql:lib:bitbucket.org/ifs-pd/nga-event-outbox/pkg/eventsender` — provisions `event_outbox` for the transactional outbox (atomic commit of domain change + event emission).
- `cmd/event-handler/main.go` → `// +kairos:sql:lib:bitbucket.org/ifs-pd/kairos-component-common/event-handler` — provisions `idempotency` for at-least-once event-handler dedup.

For the directive pipeline and the full `+kairos:sql:` directive set, invoke `kairos-sql-lifecycle`.

## What belongs in `cmd/`

- Framework bootstrap (`api.New(...)`, `eventhandler.New(...)`).
- Config loading (`config.Load[AppConfig](...)`).
- Logger/tracer initialization.
- The required `+kairos:sql:lib:` directives above.

## What does NOT belong in `cmd/`

- Business logic of any kind.
- Repository or service construction outside `ServicesFactory`.
- Domain types.
- Message schemas.
- Hand-written SQL.
- Loader registration (`api.LoaderRegistry(...).Register(...)`) — the loaders live in `internal/integration-api/loaders/` and their registration is done in `internal/integration-api/loaders.go`.
- Route registration (`routes.Register(...)`) — the route *handlers* live in `internal/api/endpoints/v1/` and their registration is done in `internal/api/routes.go` or `internal/integration-api/routes.go`.
- Registering handlers (`eh.Add(...)`, `eh.Sync(...)`) — the handler *functions* themselves live in `internal/event-handler/` and their registration is done in `internal/event-handler/handlers.go`.
