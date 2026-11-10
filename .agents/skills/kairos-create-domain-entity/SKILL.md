---
name: kairos-create-domain-entity
description: Creates a domain entity in internal/domain/ embedding entities.EntityBase for ID/ETag/audit fields, with camelCase JSON tags and optional +kairos:sql: directives for custom SQL generation. Use when adding a domain model, defining an aggregate root, setting up optimistic concurrency, or when the user says "add domain entity", "create aggregate", or "new domain model".
---

# Create a Kairos Domain Entity

Domain entities are the Go structs that represent aggregates in your PostgreSQL database. They embed `entities.EntityBase[entities.EntityId]` to get built-in ID, ETag (for optimistic concurrency), and audit timestamps. `kairos-gen` will automatically produce a SQL migration file in `sql/1.gen/` for any entity that embeds `EntityBase` or `MasterDataEntityBase`.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## File location & naming

- **Location**: `internal/domain/{entity}.go`
- **Type name**: singular (e.g. `Order`, not `Orders`)
- **File name**: snake_case (e.g. `order.go`, `user_profile.go`)

## Template

```go
package domain

import "bitbucket.org/ifs-pd/kairos-component-common/common/entities"

type Order struct {
	entities.EntityBase[entities.EntityId] `json:",inline"`
	CustomerName string      `json:"customerName"`
	OrderItems   []OrderItem `json:"orderItems"`
	TotalAmount  float64     `json:"totalAmount"`
}

type OrderItem struct {
	ProductId string `json:"productId"`
	Quantity  int    `json:"quantity"`
}
```

## EntityBase in action

```go
// Create a new entity
order := Order{
    EntityBase:   entities.NewEntityBase(entities.NewId(), entities.NewETag()),
    CustomerName: "John Doe",
    TotalAmount:  99.99,
}

// Update an entity — generates a new ETag and refreshes UpdatedAt
order.EntityBase = order.EntityBase.ForUpdate()
order.TotalAmount = 149.99
```

### EntityBase surface

| Type / member | Purpose |
|---|---|
| `entities.EntityId` | UUID v7 (monotonic, time-sortable) |
| `entities.EntityETag` | XID for optimistic concurrency |
| `entities.EntityBase[T]` | Embeds fields `Id`, `ETag`, `CreatedAt`, `UpdatedAt` |
| `entity.Id` / `entity.Id.String()` | The ID field (typed `T`) and its string form |
| `entity.ETag` / `entity.ETag.String()` | The ETag field and its string form |
| `entity.GetId() any` | ID as `any`; type-assert or use `entity.Id` for the typed value |
| `entity.HasId() bool` | True when the ID is non-zero |
| `entity.ForUpdate()` | New base with a fresh `ETag` + `UpdatedAt`, same `Id` / `CreatedAt` |
| `entity.Base()` | Pointer to the embedded `EntityBase` |
| `entities.ParseId(s)` | Parse a string into an `EntityId` |
| `entities.ParseETag(s)` | Parse a string into an `EntityETag` |

`GetId()` returns `any` — access the ID directly via the `entity.Id` field
(e.g. `entity.Id.String()`) rather than through `GetId()`.

## Required elements checklist

- [ ] File in `internal/domain/` with snake_case name
- [ ] Struct embeds `entities.EntityBase[entities.EntityId]` with tag `json:",inline"`
- [ ] All JSON tags are **camelCase** (matches the PostgreSQL JSONB rule)
- [ ] No constructor required — construct with struct literal + `entities.NewEntityBase(...)`
- [ ] Nested types (e.g. `OrderItem`) follow the same camelCase rule
- [ ] Single-value primary key (no composite keys — see "Simple keys only" below)

## What gets generated

After running `make generate`, `kairos-gen` produces:

**`sql/1.gen/{tablename}.sql`** (pluralized snake_case table name):

```sql
CREATE TABLE IF NOT EXISTS orders (
    id   UUID PRIMARY KEY,
    data JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_orders_data_gin ON orders USING GIN (data);
```

The default table name follows Go type → pluralized snake_case: `Order` → `orders`, `UserProfile` → `user_profiles`, `OrderLineItem` → `order_line_items`.

If the type name has two or more consecutive capitals (`ExternalSKU`, `HTTPServer`), pin the name with `+kairos:sql:table:` (e.g. `// +kairos:sql:table:external_skus`). kairos-gen v0.0.x splits every capital (a letter-split name), and v0.1.x fails generation on such a name unless it is pinned. The pin gives the same table on every version, and the repository constant must match it.

For the surrounding pipeline — the full `sql/` layout (`0.libs/`, `1.gen/`, `3.custom/`), the mandatory `+kairos:sql:lib:` directives (in `cmd/client-api/main.go`, in `cmd/integration-api/main.go` if it exists, and in `cmd/event-handler/main.go`), and the "never hand-edit `1.gen/`" rule — see skill `kairos-sql-lifecycle`. This skill only covers the entity side.

## Customizing SQL generation

Use `+kairos:sql:` directives above the struct to override defaults:

```go
// +kairos:sql:table:custom_orders
// +kairos:sql:index:idx_orders_customer BTREE ((data->>'customerId'))
type Order struct {
    entities.EntityBase[entities.EntityId] `json:",inline"`
    CustomerName string  `json:"customerName"`
    TotalAmount  float64 `json:"totalAmount"`
}
```

Which directives behave as described depends on the generator version. Read it as in `kairos-sql-lifecycle` § Which kairos-gen runs: on v0.1.x every row below applies; on v0.0.x check each row against that section's table first (for example, v0.0.x drops a `UNIQUE` index silently).

| Directive | Effect |
|---|---|
| `+kairos:sql:table:tableName` | Override table name |
| `+kairos:sql:column:def` | Add a promoted column next to `id`/`data` (e.g. `external_id TEXT`). The repository must write it, and read it back if generated loaders exist: see `kairos-create-repository` § Promoted columns |
| `+kairos:sql:index:name [UNIQUE] BTREE\|GIN definition [WHERE predicate]` | Add a custom index. Wrap a single expression in double parentheses — `BTREE ((data->>'customerId'))`; single parentheses are a PostgreSQL syntax error, and `GIN` on a `->>` text expression fails (no default operator class) |
| `+kairos:sql:index:no-auto-gin-index` | Disable the default GIN index |
| `+kairos:sql:index:auto-gin-index-operator:jsonb_path_ops` | Operator class of the default GIN index on `data` (`jsonb_ops` or `jsonb_path_ops`) |
| `+kairos:sql:idtype:typeName` | Override the `id` column SQL type (emitted verbatim) |
| `+kairos:sql:ignore` | Skip SQL generation for this entity |

For the full directive set (including `+kairos:sql:lib:`, which lives on `cmd/*/main.go` rather than on an entity) and the authoritative behavior reference, see skill `kairos-sql-lifecycle`. The [kairos-gen README](https://bitbucket.org/ifs-pd/kairos-component-common/src/main/cmd/kairos-gen/README.md#sql-generation) is the upstream source.

For the **policy** of when to split a fat aggregate into a child table or add an extra column beyond `id` and `data`, see the "Splitting fat aggregates into child tables" and "When to add extra columns beyond `id` and `data`" sections in skill `kairos-database-model`. The directives above are only the mechanics.

## Simple keys only — no composite primary keys

Every entity ID is a single value. `EntityBase[T]` / `MasterDataEntityBase[T]` take exactly one type parameter, and the generated table is always `id <type> NOT NULL PRIMARY KEY`. There is no supported way to express a composite primary key. If the source system has a natural composite identity (e.g. `(company, orderNo)`), concatenate the parts into a single ID string (or hash them) and keep the individual parts as `camelCase` fields inside `data` for querying.

## Non-UUIDv7 IDs (data from IFS Applications/F1)

For data originating from IFS Applications/F1 — the only scenario in scope here — the source uses Oracle's `SYS_GUID()` as the identifier. `SYS_GUID()` is a `RAW(16)` value, transmitted as a 32-character uppercase hex string with no dashes (e.g. `A1B2C3D4E5F67890ABCDEF0123456789`). It's the same 128-bit width as a UUID but does not follow RFC 4122 version/variant bits.

**Default — preserve the exact Oracle string form (`CHAR(32)`).** The directive works the same on a domain entity; the example is master data, which lives in `pkg/schema/masterdata/` (see `kairos-create-masterdata-entity`), not in `internal/domain/`:

```go
// pkg/schema/masterdata/product.go
// +kairos:sql:idtype:CHAR(32)
type ProductV1 struct {
    entities.MasterDataEntityBase[string] `json:",inline"`
    Description string `json:"description"`
}
```

This yields `id CHAR(32) NOT NULL PRIMARY KEY` and keeps the F1-produced identifier byte-for-byte through Kairos.

## Common mistakes (RED FLAGS)

- snake_case JSON tags → breaks the JSONB naming convention.
- Forgetting `json:",inline"` on the embedded `EntityBase` → fields end up nested under a `"EntityBase"` object in JSON.
- Writing a SQL migration manually for this table — `kairos-gen` produces it. For where it goes and what not to touch, see skill `kairos-sql-lifecycle`.
- Using `entities.Id` (doesn't exist) instead of `entities.EntityId`.
- Committing without running `make generate` — downstream build will recreate the files and produce a diff. See `kairos-sql-lifecycle` for troubleshooting when generated SQL doesn't appear.
