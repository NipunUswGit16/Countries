---
name: kairos-database-model
description: Reference model for Kairos PostgreSQL architecture — schema-per-tenant-within-database-per-component, automatic tenant scoping via `ctx.DatabaseSession()`, the 2-column `id`/`data JSONB` storage pattern, why JSONB was chosen and when to break out normalized read models, ETag-based optimistic concurrency, package-level constant table names per repository, and the `entities.EntityBase` contract. Use when reasoning about tenancy, session scoping, JSONB trade-offs, optimistic concurrency, why tenant filters are not needed in WHERE clauses, or when the user says "how does tenancy work", "why JSONB", "schema per tenant", "ETag", "read model", or similar architecture/model questions.
---

# Kairos Database Model

A **reference skill**. This captures the conceptual model behind Kairos persistence. Task recipes (creating entities, writing repositories, wiring services) live in their own task skills. Use this when you need to understand *why* the architecture is structured a certain way, or when debugging tenancy/session/concurrency issues.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Tenancy topology

Kairos runs **database-per-component, schema-per-tenant**:

```text
PostgreSQL instance
└── component-X-database
    ├── public                       # component-level shared tables
    ├── <tenant-id-a>                # per-tenant schema (schema name = tenant ID, verbatim)
    │   ├── orders                   #   each tenant gets a complete set of tables
    │   ├── customers
    │   └── event_outbox
    ├── <tenant-id-b>
    │   ├── orders
    │   └── ...
    └── <tenant-id-c>
        └── ...
```

The schema name is the tenant ID **verbatim** — no `tenant_` prefix, no lowercasing, no dash-stripping. A typical tenant ID is a UUID like `11111111-1111-1111-1111-1111111111ab`, and that exact string is the schema name (the framework and migration tooling quote it so dashes are valid identifier characters).

### Why schema-per-tenant, not row-level tenancy?

- **Strict isolation at the DB level** — a mis-scoped query cannot accidentally cross tenants because the schema name is part of the session's `search_path`.
- **Per-tenant migrations and maintenance** — schemas can be dropped, backed up, or migrated independently.
- **Query simplicity** — no `WHERE tenant_id = ?` noise in every query; the query plans are cleaner.
- **Predictable performance** — one tenant's data growth does not slow another tenant's indexes.

Trade-off: more schemas to manage, more migrations to apply. Mitigated by generated SQL (`make generate`) and `make db-run`, which applies every file under `sql/` to a tenant schema locally.

## Session auto-scoping — the invariant

Every session obtained via `ctx.DatabaseSession()` is **already scoped to the caller's tenant** before any repository sees it. The framework:

1. Reads the tenant ID from the incoming request's auth context (API) or CloudEvent metadata (event handler).
2. Uses the tenant ID directly as the schema name — no prefix, no transformation.
3. Sets the session's `search_path` so unqualified table references resolve to the tenant schema.

**Implications:**

- `SELECT * FROM orders` inside a repository hits `<tenant-id>.orders` automatically.
- You **do not** add `WHERE tenant_id = ?` filters. They are redundant and a strong code smell — they usually mask a missing or stale session scope.
- You **do not** compose schema names manually. If you find yourself building `<tenant-id>.orders` strings, you have bypassed the session scoping.

### RED FLAG: raw connections

If a repository uses a raw `pgx.Conn` or a pool directly instead of the `interfaces.Session` passed in, tenant scoping is lost. Every repository in `internal/repositories/` must accept `interfaces.Session` and only that session.

## The 2-column storage pattern

The canonical shape of an entity table in Kairos is:

```sql
CREATE TABLE <table_name> (
    id   UUID PRIMARY KEY,
    data JSONB NOT NULL
);
CREATE INDEX ON <table_name> USING GIN (data);
```

- `id` — UUIDv7, monotonically time-sortable, from `entities.NewId()`.
- `data` — JSONB containing the full serialized entity (including `EntityBase` fields).

By default there are no other columns. Querying is by `data->>'fieldName'` or JSONB path operators, accelerated by the GIN index. Additional columns are permitted **only** as a narrow performance escape hatch — see [When to add extra columns beyond `id` and `data`](#when-to-add-extra-columns-beyond-id-and-data) below.

### Naming conventions — non-negotiable

- **Table names**: `snake_case`, pluralized (e.g. `todos`, `user_profiles`, `order_items`).
- **JSONB field names**: `camelCase` (e.g. `taskId`, `createdAt`, `principalId`). **Never** `snake_case` inside `data`.
- **Column names** (on the rare occasions you add one beyond `id`/`data` — see below): `snake_case`.

Worked example:

```sql
CREATE TABLE user_profiles (
    id UUID PRIMARY KEY,
    data JSONB NOT NULL
);

INSERT INTO user_profiles (id, data) VALUES (
    gen_random_uuid(),
    '{"firstName": "John", "lastName": "Doe", "createdAt": "2024-01-01T00:00:00Z"}'
);

SELECT data->>'firstName'
FROM   user_profiles
WHERE  data->>'userId' = '123';
```

The Go struct's `json:"..."` tags are the source of truth for JSONB field names; the generator reads them verbatim. A stray `json:"user_id"` tag silently corrupts the convention — tags must be `camelCase`.

### Splitting fat aggregates into child tables

JSONB works well as long as a row's `data` document stays bounded in size. When an aggregate embeds a collection that can grow unboundedly (e.g. an `orders` document embedding all of its order items), do **not** keep the collection inside `data` — every update rewrites the entire document, contention concentrates on one row, and the aggregate boundary becomes meaningless. Extract the collection into a separate table:

- The child table follows the same 2-column pattern: `id UUID PRIMARY KEY`, `data JSONB NOT NULL` (e.g. `order_items`).
- The relationship is expressed as a `camelCase` foreign-key field **inside the child's `data`** document, holding the parent's `id` value — e.g. `"orderId": "<parent id UUID>"`. The parent's `id` column is always the primary key and the only thing children reference.
- **Never** add a raw UUID foreign-key column on the child table. The FK lives in `data`, like every other field.
- Treat each table as its own aggregate root with its own repository in `internal/repositories/`.

Rule of thumb: if the embedded collection can realistically reach dozens of entries or more, split it. If it is bounded and small (a handful of fixed sub-fields), keep it inline in `data`.

### Human-facing identifiers (order numbers, SKUs, codes)

The `id` column is a UUIDv7 and is **not** meant to be displayed to users. When you need a human-readable identifier (an order number like `ORD-2026-00042`, a SKU, a short code, etc.):

- Store it as a `camelCase` field inside `data` — e.g. `"orderNumber": "ORD-2026-00042"`.
- **Never** repurpose the `id` column for it, and **never** add a separate human-id column on the table.
- If uniqueness must be enforced, add a unique index on the JSONB expression. How depends on the generator (read its version as in `kairos-sql-lifecycle` § Which kairos-gen runs):
  - **kairos-gen v0.1.x:** a directive on the entity struct:

    ```go
    // +kairos:sql:index:orders_order_number_uniq UNIQUE BTREE ((data->>'orderNumber'))
    ```

  - **v0.0.x:** that directive is silently dropped, so duplicates get in. Write the index in `sql/3.custom/` instead:

    ```sql
    CREATE UNIQUE INDEX IF NOT EXISTS orders_order_number_uniq
    ON orders ((data->>'orderNumber'));
    ```

- Children still reference the parent by the parent's `id` (the UUID), not by its human-facing identifier. The human ID is a display/search concern; the UUID is the relational key.

### When to add extra columns beyond `id` and `data`

The default 2-column layout covers the vast majority of cases. Add an extra column **only** when a field must appear in a `WHERE` clause that runs at scale *and* a GIN index on `data` (or a targeted expression index on `data->>'field'`) is provably insufficient. In that case:

- Declare it with `+kairos:sql:column:` on the entity. The column name is `snake_case`.
- Where the value lives depends on whether the component has generated bulk loaders:
  - **`internal/integration-api/loaders/generated` exists:** the generated loader writes the promoted field into the column and strips it from `data`, unless the entity carries `+kairos:sql:loader:duplicate:<col>`. For bulk-loaded rows the column is the only copy, so the repository must read it back into the struct.
  - **It doesn't exist:** no loaders, so `data` keeps the field and stays the source of truth. The column is a copy the repository keeps in sync on every write.

  The mechanics are in `kairos-create-repository` § Promoted columns.
- The extra column is a performance optimization, not a modeling tool.

Do **not** add columns speculatively, and do **not** use extra columns as a substitute for splitting a fat aggregate. If you're reaching for a second column because `data` is getting unwieldy, the answer is usually "split the aggregate", not "add columns".

### Why JSONB (not normalized columns)?

- **Schema flexibility** — adding/removing fields on a domain entity does not require an ALTER TABLE migration. The Go struct is the schema of record.
- **Version compatibility** — two versions of a service with slightly different structs can share the same table; each reads/writes the fields it knows.
- **Entity atomicity** — the whole aggregate round-trips as one row, so writes are atomic without spanning multiple tables.
- **Rapid iteration** — the same generator (`kairos-gen`) that ships the struct also ships the SQL; no drift.

### Trade-offs

- JSONB queries are less intuitive than normalized SQL (`data->>'customerId'` vs. `customer_id`).
- Storage overhead per row (keys repeat inside every `data`).
- Reporting/analytics across aggregates is awkward — JSONB does not play nicely with JOIN-heavy analytical queries.

### When to break out a read model

If you need:

- High-volume reporting with joins and aggregations.
- A denormalized view for a specific read pattern (dashboard, feed, search).
- External tooling (BI, ETL) that expects relational columns.

Build it as a **separate read model** — a new table with normalized columns, populated by an event handler that reacts to domain events. **Do not** denormalize the primary aggregate table; that entangles read concerns with the write model and defeats the JSONB advantage.

## Table names

Table names in Kairos are **not configurable**. Each repository declares its table name as a package-level constant named after the entity (e.g. `const ordersTableName = "orders"`) and references that constant directly in queries. A bare `tableName` collides once a second repository exists in the package; see `kairos-create-repository`.

By convention the table name follows the entity type name in pluralized snake_case (`Order` → `orders`, `UserProfile` → `user_profiles`), matching what `kairos-gen` emits for the generated SQL — see `kairos-create-domain-entity` for the override directive when a different name is needed, and `kairos-create-repository` for how the constant is declared and used in queries.

## `entities.EntityBase` — the aggregate root contract

Every domain entity in `internal/domain/` embeds `entities.EntityBase[entities.EntityId]`. This contract provides:

| Field | Purpose |
|---|---|
| `Id` | UUIDv7 — time-sortable, unique |
| `ETag` | XID — changes on every update |
| `CreatedAt` | Set once, immutable |
| `UpdatedAt` | Refreshed by `ForUpdate()` |

### Optimistic concurrency via ETag

ETag enables **optimistic concurrency control**:

1. Read: caller receives the entity + its current ETag.
2. Write: caller sends the ETag back with the update.
3. Repository compares the stored ETag to the caller's; if mismatched, the update is rejected as a concurrency conflict.
4. On success, `entity.ForUpdate()` generates a new ETag and refreshes `UpdatedAt` atomically.

Never mutate `ETag` or `UpdatedAt` by hand. `ForUpdate()` keeps them consistent.

### Why UUIDv7 for IDs?

- **Time-sortable** — a default `ORDER BY id` is approximately `ORDER BY creation_time`, which matches most pagination needs without an extra column.
- **Monotonic** — avoids index hot-spotting that random UUIDv4 would cause.
- **Globally unique** — safe across tenants, components, and reruns.

Parse untrusted input with `entities.ParseId(s)` to validate before hitting SQL.

## pgx vs alternatives

Kairos standardizes on **pgx** (not `database/sql`, not `GORM`, not `sqlx`). Reasons:

- Native PostgreSQL protocol support — better performance, full JSONB feature access, connection-pool control.
- First-class typed parameters (including `pgx.Identifier`, UUID, JSONB codec) without reflection.
- Works cleanly with the `interfaces.Session` abstraction used across repositories and master-data mappers.

If you need an ORM-like experience, that is a signal to add a helper (e.g. generic JSONB scan), not to introduce a new library.

## Tenancy + events

Tenant scoping is enforced not only at the DB layer but at the event-bus layer: every topic is tenant-scoped by the framework. An event published by tenant A cannot be consumed by tenant B even if they both subscribe to the same logical topic. Like session scoping, this is automatic — you do not add `tenantId` filters in handlers.

## Common pitfalls

- Adding `WHERE tenant_id = ?` → redundant; masks a missing session scope.
- Building `<tenant-id>.orders` strings manually → bypasses scoping.
- Using raw `pgx.Conn` in a repository instead of the passed `interfaces.Session` → tenant scoping lost.
- Making the table name configurable (constructor parameter, `AppConfig` getter, env var) → table names are package-level constants in the repository.
- Mutating `ETag` or `UpdatedAt` directly → breaks optimistic concurrency; use `ForUpdate()`.
- Denormalizing the aggregate table for reporting → entangles read/write models; build a separate read model.
- snake_case JSON tags on domain structs → breaks the JSONB naming convention (root `AGENTS.md`).
