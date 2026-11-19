# Internal — Business Logic Layers

The conventions below apply to the **core** layers (`services/`, `repositories/`, `domain/`, `dto/`). The runtime entry layers (`api/`, `event-handler/`, `integration-api/`) have their own nested `AGENTS.md` files.

## Layer responsibilities

| Layer | Role | Imports allowed |
|---|---|---|
| `internal/domain/` | Pure data structures — aggregates, value types, `PaginationFilter` | standard lib, `entities.*` |
| `internal/dto/` | Shared response DTOs (`Pagination`, `PaginatedResponse[T]`) — importable by entry layers and services | standard lib only; nothing from `internal/` |
| `internal/repositories/` | PostgreSQL persistence only — accepts `interfaces.Session` + `tableName` | `domain`, `pgx`, `interfaces`, `nga-common` |
| `internal/services/` | Business logic, validation, orchestration | `domain`, `dto`, `repositories` (interface), `nga-common/logging` |
| `internal/api/` | HTTP boundary — delegates to services | services, `dto`, schema, Fiber |
| `internal/event-handler/` | CloudEvent boundary — delegates to services | services, `dto`, schema, event-handler lib |
| `internal/integration-api/` | Integration API boundary — delegates to services | services, `dto`, schema, Fiber |

The arrow of dependency runs **entry layers → services → repositories → domain**. `internal/dto/` sits beside this arrow: entry layers and services may import it, and it imports nothing from `internal/`. Nothing in `services/`, `repositories/`, `domain/`, or `dto/` may import from `api/`, `event-handler/`, or `integration-api/`. The entry layers must not import each other either — each is a separate binary with its own `request` and `config` packages, and the shared surface between them is `services/`, not another entry layer.

## Kairos-specific Go rules

Two layered sources cover the rules that apply here:

- **Root `AGENTS.md` § *Non-Negotiable Architecture Rules*** — the structural invariants (services own logic; repositories take `interfaces.Session` + a `tableName` constant; `ServicesFactory` mirrored across every runtime that calls the service; `entity.ForUpdate()`; `entities.ParseId(...)`; etc.).
- **`kairos-go-developer` skill** — the Go idioms (`ctx.Logger()` not `log.*`; `context.Context` as the first parameter; no package-level mutable state; `fmt.Errorf("doing X: %w", err)`; etc.).

The directory-specific rule already stated above — the inward-only dependency arrow — is the one a `kairos-*` skill cannot enforce on its own; the layer table is the contract.
