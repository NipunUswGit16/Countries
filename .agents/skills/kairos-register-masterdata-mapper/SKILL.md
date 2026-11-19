---
name: kairos-register-masterdata-mapper
description: Registers master data mappers via eh.Sync() in internal/event-handler/handlers.go to automatically replicate reference data from other services into local PostgreSQL tables. Use when consuming master data, replicating reference data, wiring eh.Sync for master data, or when the user says "sync master data", "register master data mapper", or "replicate reference data".
---

# Register a Kairos Master Data Mapper

Master data mappers automatically receive published master data entities and persist them into local PostgreSQL tables (upsert on receive, delete on empty payload). They eliminate the need to write repository/service code for read-only replicas of reference data.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Registration location

All master data mappers live in `internal/event-handler/handlers.go`, registered on the event handler via `eh.Sync(...)`.

## Basic registration

Use when the Go struct is available locally (imported from another component):

```go
import (
    eventhandler "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
    "bitbucket.org/ifs-pd/kairos-component-template/pkg/schema/masterdata"
)

eh.Sync(eventhandler.MasterData[*masterdata.ExampleEntityV1]())
```

The default table name is derived from the entity type: `ExampleEntityV1` → `example_entities` (pluralized snake_case, `V{N}` suffix stripped). When the name ends in an acronym (`ExternalSKUV1`) the default depends on `kairos-component-common/event-handler` in `go.mod` (`go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/event-handler`): ≥ v1.2.44 gives `external_skus`, < v1.2.44 `external_sku_s` — while kairos-gen creates `external_skus`. For any acronym in the name, set `.TableName(...)` explicitly. Other names give the same table in every version.

## With custom table name

```go
eh.Sync(
    eventhandler.MasterData[*masterdata.ExampleEntityV1]().
        TableName("examples"),
)
```

## With custom transformation

Apply business logic before storing. The mapper returns a **local domain entity** (embedding `entities.EntityBase`) — not the master-data entity itself — which is what gets persisted into the local table. Always pair a mapper with `.TableName(...)`: without it the writer inserts into the master-data entity's default table while kairos-gen generates the table for the mapper's return type (kairos-gen ≥ v0.1.11 warns about the mismatch; older versions don't).

Two spellings exist. Which one to write depends on two checks, on separate axes:

- **event-handler:** `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/event-handler`
- **kairos-gen:** if `go.mod` has a `cmd/kairos-gen` line, `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen`; otherwise run `kairos-gen --version` (`(devel)` or a failure is unknown: treat it as below the floor).

| event-handler | kairos-gen | Write |
|---|---|---|
| ≥ v1.2.49 | ≥ v0.1.11 | [`.Map(func)`](#map) |
| ≥ v1.2.49 | < v0.1.11 or unknown | [`.Mapper(eventhandler.MasterDataMapper(func))`](#mapper). `.Map` compiles, but this kairos-gen does not read it: the topic and `.TableName` are kept, the table is generated from the master-data entity instead of the mapper's return type, and the return type gets its own, unused table carrying its `+kairos:sql:` directives. When both default to the same name, `make generate` fails with a table name collision; otherwise it reports nothing. Tell the author the pin bump that unlocks `.Map` (`go get -tool bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen@v0.1.11 && go mod tidy`); don't run it in this task. |
| < v1.2.49 | any | [`.Mapper(eventhandler.MasterDataMapper(func))`](#mapper). `.Map` does not exist. |

In both spellings the function has the same signature, and kairos-gen reads the local table type from its return type. Write it as a func literal, as below. On kairos-gen ≥ v0.1.11 a top-level function in the same package also resolves; a method value (`svc.MapProduct`) or an imported function never does, and kairos-gen then generates the table for the master-data entity itself (≥ v0.1.11 prints a `kairos-gen: warning:` naming the file; older versions are silent).

### `.Map`

```go
import (
    "strings"

    ehcontext "bitbucket.org/ifs-pd/kairos-component-common/event-handler/context"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/domain"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/config"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/event-handler/request"
)

eh.Sync(
    eventhandler.MasterData[*masterdata.ProductEntityV1]().
        TableName("products").
        Map(func(
            ctx ehcontext.Context[request.ServicesFactory, config.AppConfig],
            entity *masterdata.ProductEntityV1,
        ) (*domain.Product, error) {
            return &domain.Product{
                EntityBase:  entity.ForUpdate(),
                Name:        strings.ToUpper(entity.Name),
                Description: entity.Description,
                Price:       entity.Price,
            }, nil
        }),
)
```

The entity parameter is the registered `MasterData[T]` type; another type does not compile. `.TableName`, `.Map` and `.DeletionHandler` chain in any order. On this row `.Mapper(eventhandler.MasterDataMapper(...))` is deprecated but still compiles, generates and runs: leave existing registrations as they are.

### `.Mapper`

Same imports as above.

```go
eh.Sync(
    eventhandler.MasterData[*masterdata.ProductEntityV1]().
        TableName("products").
        Mapper(
            eventhandler.MasterDataMapper(func(
                ctx ehcontext.Context[request.ServicesFactory, config.AppConfig],
                entity *masterdata.ProductEntityV1,
            ) (*domain.Product, error) {
                return &domain.Product{
                    EntityBase:  entity.ForUpdate(),
                    Name:        strings.ToUpper(entity.Name),
                    Description: entity.Description,
                    Price:       entity.Price,
                }, nil
            })),
)
```

## Reacting to a deletion

Needs `kairos-component-common/event-handler` ≥ v1.2.49 in `go.mod` (the check above). Below that the method does not exist: tell the author, and don't emulate it with a bespoke event handler. kairos-gen is not a factor: every kairos-gen ≥ v0.1.7 walks through `.DeletionHandler` and records the rest of the chain, so on kairos-gen < v0.1.11 pair it with `.Mapper(...)`, as the two-axis table says for the mapper.

`.DeletionHandler(func)` runs before the framework deletes the row: on an empty payload (the mapper does not run) and after a mapper that returns `nil`. It runs on the event's database session, so `ctx.ServicesFactory()` and `ctx.DatabaseSession()` work as in any event handler. It chains in any order with `.TableName` and the mapper, and also on a registration with no mapper.

```go
import "bitbucket.org/ifs-pd/kairos-component-common/common/entities"

eventhandler.MasterData[*masterdata.ProductEntityV1]().
    TableName("products").
    Map(func(/* as above */) (*domain.Product, error) { /* ... */ }). // or .Mapper(...)
    DeletionHandler(func(
        ctx ehcontext.Context[request.ServicesFactory, config.AppConfig],
        id entities.EntityId,
    ) (bool, error) {
        // e.g. cascade into a local read model, then let the framework delete the row
        return true, nil
    }),
```

The `id` parameter type must be the entity's `Id` field type (`entities.EntityId` for `MasterDataEntityBase[entities.EntityId]`); any other type panics at startup when the handler is attached. What the return values do is in [§ Behaviour](#behaviour).

## Bulk registration

Multiple entities in a single `eh.Sync` call. Register **at most one version per entity**, and at most one mapper per `(component, entity)`. What a second registration does depends on `kairos-component-common/event-handler` in `go.mod`:

- ≥ v1.2.44: the registry key is `<component>.<entity>`. A second registration — V1 and V2 of the same entity included — **panics at startup**, and so does an entity whose `ComponentName()` is empty.
- < v1.2.44: the key is the bare entity name. The later registration silently replaces the earlier one, even when it comes from another component, and then handles every version's messages.

To move from V1 to V2, swap the registration; don't add the second one.

```go
eh.Sync(
    eventhandler.MasterData[*masterdata.CustomerEntityV2](),
    eventhandler.MasterData[*masterdata.OrderEntityV1](),
    eventhandler.MasterData[*masterdata.ExampleEntityV1]().TableName("examples"),
)
```

## Behaviour

| Situation | Result |
|---|---|
| Entity received with non-empty payload | Upsert into table by `id` (`INSERT ... ON CONFLICT (id) DO UPDATE`) |
| Entity received with empty payload | Row deleted by `id`. With a `DeletionHandler`: it runs first; `true, nil` then deletes the row, `false, nil` leaves it |
| Mapper returns `nil, nil` | Same as an empty payload: row deleted, `DeletionHandler` runs first when attached |
| `DeletionHandler` returns an error | Row kept, bool ignored. The error keeps the class the handler gave it: a plain error is transient and the message is retried, `typederrors.ToFatal(err)` dead-letters it; see `kairos-messaging-model` § *Handler failure semantics* |
| Mapper returns `eventhandler.ErrIgnoreMasterDataEntity` | Message skipped, nothing written, `DeletionHandler` not called |
| No mapper for the received `ce_type` | The handler returns `ErrNoMapperFound` (HTTP 500). On event-handler ≥ v1.2.46 it rolls back and the adapter retries; on < v1.2.46 the idempotency row commits and the message is dropped. On ≥ v1.2.44 a component-name mismatch (the publisher's component is not the one registered) also gives this error. |

Storage format is the standard Kairos 2-column layout (`id UUID PRIMARY KEY`, `data JSONB`).

## Table creation

The underlying PostgreSQL table is created automatically by `kairos-gen` when it detects the entity type — run `make generate` after adding the registration. If `.TableName("xyz")` is used, the custom name is honoured in the generated SQL. The same run adds the entity's individual topic (`<component>.<entity-kebab>.<version>`) to `topic-config.json`; on kairos-gen ≥ v0.1.0 only this registration does that (see `kairos-topic-subscriptions` for older generators).

## Required elements checklist

- [ ] Registered in `internal/event-handler/handlers.go` inside the setup function
- [ ] Uses `eh.Sync(...)` (not `eh.Add(...)`)
- [ ] Type parameter is a pointer to the entity (`*masterdata.XEntityV1`)
- [ ] If consuming from another component, the import path of the entity points at that component's `pkg/schema/masterdata/`
- [ ] A mapper is spelled per the two-axis table in [§ With custom transformation](#with-custom-transformation), is a func literal, and is paired with `.TableName(...)`
- [ ] `make generate` run afterwards to emit topic + SQL

## Common mistakes (RED FLAGS)

- Using `eh.Add(...)` instead of `eh.Sync(...)` for master data.
- Forgetting the pointer on the type parameter.
- Writing a bespoke event handler for master data instead of using `MasterData[T]()`.
- Registering two versions of the same entity (or the same entity from two places).
- Manually writing repository/service code for a replicated read-only table.
- Not running `make generate` — the table and topic subscription won't exist.
- `.Map` on a kairos-gen below v0.1.11: it compiles, and `make generate` either fails with a table name collision or silently generates the mapped table without the local entity's directives.
- A mapper without `.TableName(...)`, or passed as a method value / imported function: the writer and the generated SQL target different tables.
- A `DeletionHandler` whose `id` parameter is not the entity's `Id` type: startup panic.
