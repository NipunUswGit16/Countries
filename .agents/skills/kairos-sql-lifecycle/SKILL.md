---
name: kairos-sql-lifecycle
description: Reference for the Kairos SQL generation pipeline — how `kairos-gen` (invoked via `make generate`) scans Go code and produces `sql/1.gen/*.sql` from `entities.EntityBase` / `entities.MasterDataEntityBase` types, and copies library SQL into `sql/0.libs/`. Covers the `sql/` directory layout (`0.libs/`, `1.gen/`, `3.custom/`), the mandatory `+kairos:sql:lib:` directives for `event_outbox` and `idempotency`, the full `+kairos:sql:` customization directive set (the `+kairos:masterdata:` set is documented in kairos-create-masterdata-entity), owned master-data / CDC table generation, and SQL troubleshooting. Use when generating or regenerating SQL, working with `+kairos:sql:` directives, reasoning about generated vs hand-written migrations, or when the user says "generate SQL", "fix migrations", or "missing event_outbox / idempotency table". For Kafka topic subscriptions / `topic-config.json`, see `kairos-topic-subscriptions`.
---

# SQL Lifecycle (kairos-gen)

Reference for the SQL half of the Kairos code generator. `kairos-gen` keeps `sql/*.sql` in sync with the Go code. Run it on demand with `make generate`; `make build-all` and CI run it too, and the pre-push hook (`make install-hooks`) rejects a push whose generated files are out of date.

> `make generate` runs `kairos-gen`, which produces both SQL migrations **and** Kafka topic-config. This skill covers the SQL half. For the topic half (`chart(s)/resources/topic-config.json`, which packages are scanned for foreign event references, master-data registrations), see `kairos-topic-subscriptions`.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Command

```bash
make generate        # regenerate SQL migrations (and topic-config.json)
make db-run          # make generate-sql, then apply every sql/**/*.sql to the local tenant schema
```

## Which kairos-gen runs

Directive behaviour depends on the generator version. Read it before you add a directive:

- If `go.mod` has a `cmd/kairos-gen` line, the version is `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen`. `make generate` runs that pin with `go tool`.
- Otherwise run `kairos-gen --version`: the toolkit runs whatever `kairos-gen` is on `PATH` (`make generate` installs one if none is found). `(devel)` is a local source build: ask the author which line it was built from, and until then use only what both columns allow.

| | v0.0.x | v0.1.x |
|---|---|---|
| Unknown `+kairos:`, `+kairos:sql:` or `+kairos:masterdata:` line | silently ignored | `make generate` fails |
| `index:<name> UNIQUE BTREE …` | the whole line is silently dropped: no index, no error | unique index |
| `+kairos:masterdata:table:` | ignored: the table keeps its default name | alias for `+kairos:sql:table:` |
| `loader:*` directives | don't exist (no loaders) | apply when `internal/integration-api/loaders/generated` exists |
| `column:` on a master-data struct or its twin | accepted | error |
| `index:auto-gin-index-operator:<class>` | value passed through unchecked | only `jsonb_ops` or `jsonb_path_ops` |
| Master-data struct with an `EntityBase` twin | no twin logic: both structs emit SQL | the twin owns the table ([Twin entities](#twin-entities)) |
| Struct name with consecutive capitals (`ExternalSKU`) | letter-split default table name | error unless `+kairos:sql:table:` pins the name |
| `migrator:*` | not a directive | not a directive: `make generate` fails |

When the component is on v0.0.x and needs a v0.1.x-only behaviour, write the SQL in `sql/3.custom/` instead, or have the author pin kairos-gen: the kairos-component-common upgrade-file `toolkit/20260818T133759-pin-kairos-gen-go-tool.md`, applied by `kairos-component-update`. After an update, read the version again. A version newer than any named here: trust its `CHANGELOG.md` over this skill and tell the author.

## What kairos-gen produces for SQL

`kairos-gen` writes one file under `sql/1.gen/` for each of:

- a struct in `internal/domain/` or `pkg/schema/` that embeds `entities.EntityBase[T]` or `entities.MasterDataEntityBase[T]`;
- a foreign master-data type this component registers with `eventhandler.MasterData[*T]()` (the local replica that the mapper writes; see `kairos-register-masterdata-mapper`).

For example:

```sql
CREATE TABLE IF NOT EXISTS orders (
    id UUID PRIMARY KEY,
    data JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_orders_data_gin ON orders USING GIN (data);
```

All generated statements are idempotent (`IF NOT EXISTS`) and safe to run repeatedly.

Owned master-data structs (embedding `MasterDataEntityBase[T]`) go through this same pipeline with a few extra rules — see [Owned master-data tables (CDC)](#owned-master-data-tables-cdc) below.

## SQL directory layout

```text
sql/
├── 0.libs/                    # SQL from external libraries (via +kairos:sql:lib: directives)
│   ├── bitbucket.org-ifs-pd-nga-event-outbox-pkg-eventsender/
│   │   ├── 1.01_event_outbox.sql … 1.05_event_outbox_unpublished_index.sql
│   │   └── outbox_cursor.sql
│   └── bitbucket.org-ifs-pd-kairos-component-common-event-handler/
│       └── idempotency.sql
├── 1.gen/                     # Generated from domain/schema entities
│   ├── orders.sql
│   └── customers.sql
└── 3.custom/                  # Hand-written migrations (never touched by kairos-gen)
    └── custom_migration.sql
```

| Directory | Managed by | Editable? |
|---|---|---|
| `0.libs/` | `kairos-gen` (copied from libraries) | ❌ do not edit |
| `1.gen/` | `kairos-gen` (regenerated each run) | ❌ do not edit |
| `3.custom/` | You | ✅ hand-written custom SQL |

The outbox files depend on the `nga-event-outbox` version: if `ls sql/0.libs/*eventsender*/1.01_event_outbox.sql` finds nothing, the library ships `event_outbox.sql` + `outbox_cursor.sql` instead. Both trees come from `make generate`; don't rename or add files by hand.

`make db-run` regenerates the SQL, then applies every `*.sql` under `sql/` — `0.libs/`, `1.gen/` and the custom directory alike — in sorted path order (see the note below).

> Directory names under `sql/` are not fixed: components use `2.custom/` today while this doc says `3.custom/`. With kairos-gen ≥ v0.1.7, its verifier (below) reads every `*.sql` under `sql/` except `1.gen/`, so either name works. With a toolkit newer than v1.0.55, `db-run` applies files in byte order (`LC_ALL=C sort`, the same order as the production sqlrunner), so numeric prefixes decide the order; older toolkits sort by locale, which can differ from production.

## `+kairos:sql:lib:` directives — ⚠️ CRITICAL

Two directives are **required** in every Kairos component. Removing them breaks SQL generation and migrations.

### `cmd/client-api/main.go` (and `cmd/integration-api/main.go` if it exists)

```go
package main

// ⚠️ WARNING: DO NOT DELETE THIS DIRECTIVE
// This directive tells kairos-gen to copy SQL files from the event-outbox library.
// Removing it will break SQL generation and migrations.
// +kairos:sql:lib:bitbucket.org/ifs-pd/nga-event-outbox/pkg/eventsender

import (
    // ... imports
)
```

Provides the `event_outbox` table used for transactional outbox event publishing.

If `cmd/integration-api/main.go` exists, the directive is in both API `main.go` files, because both runtimes write through the outbox. Otherwise it is only in `cmd/client-api/main.go`. `kairos-gen` deduplicates, so the library is copied into `sql/0.libs/` once however many `main.go` files declare it. Preserve it wherever it already appears.

### `cmd/event-handler/main.go`

```go
package main

// ⚠️ WARNING: DO NOT DELETE THIS DIRECTIVE
// This directive tells kairos-gen to copy SQL files from the event-handler library.
// Removing it will break SQL generation and migrations.
// +kairos:sql:lib:bitbucket.org/ifs-pd/kairos-component-common/event-handler

import (
    // ... imports
)
```

Provides the `idempotency` table used for at-least-once event-handler deduplication.

### How `+kairos:sql:lib:` works

1. `kairos-gen` scans the code for `+kairos:sql:lib:` directives.
2. For each directive, it resolves the module path from `go.mod`.
3. It copies every `.sql` file from the library's `sql/` directory into `sql/0.libs/<lib-folder>/`.
4. Library SQL is copied **before** entity SQL generation.

## Customizing entity SQL — `+kairos:sql:` directives

```go
// +kairos:sql:table:custom_orders
// +kairos:sql:column:created_at TIMESTAMP NOT NULL DEFAULT NOW()
// +kairos:sql:index:idx_orders_customer BTREE ((data->>'customerId'))
type Order struct {
    entities.EntityBase[entities.EntityId] `json:",inline"`
    CustomerName string  `json:"customerName"`
    TotalAmount  float64 `json:"totalAmount"`
}
```

Check each directive against [Which kairos-gen runs](#which-kairos-gen-runs) before using it.

| Directive | Effect |
|---|---|
| `+kairos:sql:table:tableName` | Override table name |
| `+kairos:sql:column:def` | Add a promoted column (see `kairos-create-repository` § Promoted columns for what the repository must write and read) |
| `+kairos:sql:index:name [UNIQUE] TYPE definition [WHERE predicate]` | Add a custom index (see below) |
| `+kairos:sql:idtype:typeName` | Override ID column type |
| `+kairos:sql:index:no-auto-gin-index` | Disable the default GIN index |
| `+kairos:sql:index:auto-gin-index-operator:jsonb_path_ops` | Operator class of the default GIN index (`jsonb_ops` or `jsonb_path_ops`) |
| `+kairos:sql:ignore` | Skip SQL generation for this entity. On owned master data with kairos-gen ≥ v0.1.7 it means only that: the struct still gets a `masterdata-entities.json` row and its hand-written table is verified (see below). With v0.1.0–v0.1.6 it also removes the struct from `masterdata-entities.json`. |
| `+kairos:sql:lib:modulePath` | Copy SQL files from an external library (on `cmd/*/main.go`, not on an entity) |

Prefer directives over hand-editing generated SQL.

### Loader directives (`+kairos:sql:loader:*`)

These shape the bulk-load loader that kairos-gen v0.1.x writes into `internal/integration-api/loaders/generated/`. If that directory doesn't exist, the component has no generated loaders and these directives don't apply: skip this section.

| Directive | Effect |
|---|---|
| `+kairos:sql:loader:disable` | No generated loader for this entity; hand-write one (`kairos-create-loader`) |
| `+kairos:sql:loader:type-name:<GoIdent>` | Loader type, file and registry entity type name, when two structs share a name |
| `+kairos:sql:loader:column-expr:<col>:<Go expr>` | Value of a promoted column, from a Go expression over `{Field}` placeholders |
| `+kairos:sql:loader:column-sql:<col>:<SQL expr>` | SQL `VALUES` expression for a column (`{value}` is the column value) |
| `+kairos:sql:loader:import:<path>[:<alias>]` | Import needed by a `column-expr` expression |
| `+kairos:sql:loader:duplicate:<col>` | Keep the promoted field in `data` too. By default the loader strips a field promoted to its own column from `data` |

### Custom index grammar

```text
+kairos:sql:index:<name> [UNIQUE] <GIN|BTREE> <definition> [WHERE <predicate>]
```

emits:

```sql
CREATE [UNIQUE ]INDEX IF NOT EXISTS <name> ON <table> USING <type> <definition>[ WHERE <predicate>];
```

- `UNIQUE` (optional, right after `<name>`) needs kairos-gen v0.1.x. v0.0.x silently drops the whole line, so there is no index and duplicates get in. On v0.0.x, write `CREATE UNIQUE INDEX IF NOT EXISTS …` in `sql/3.custom/` instead.
- `UNIQUE` requires `BTREE` — `UNIQUE` + `GIN` is a generate-time error.
- `WHERE <predicate>` (optional, trailing) makes it a **partial index**; works with both `GIN` and `BTREE`, and composes with `UNIQUE` for a partial unique index.
- `UNIQUE`/`WHERE` are matched case-insensitively and normalized to uppercase in the emitted SQL.
- Expression / `COALESCE` / `lower()` / JSONB-path indexes flow through `<definition>` verbatim. A single expression column must be **double-parenthesized** — `((expr))`. Single parentheses around an expression are a PostgreSQL syntax error. Index a `data->>'x'` expression with `BTREE`: `->>` returns text, which has no default GIN operator class, so `GIN ((data->>'x'))` fails too.

```go
// one active email, ignoring soft-deleted rows (partial UNIQUE on a JSONB expression)
// +kairos:sql:index:uq_active_email UNIQUE BTREE ((data->>'email')) WHERE data->>'deletedAt' IS NULL
//   -> CREATE UNIQUE INDEX IF NOT EXISTS uq_active_email ON <table> USING BTREE ((data->>'email')) WHERE data->>'deletedAt' IS NULL;

// COALESCE so NULLs participate in uniqueness (Postgres treats NULLs as distinct otherwise)
// +kairos:sql:index:uq_code UNIQUE BTREE ((COALESCE(data->>'code','')))

// case-insensitive expression index
// +kairos:sql:index:idx_name_ci BTREE ((lower(data->>'name')))
```

## Owned master-data tables (CDC)

A struct in your module embedding `MasterDataEntityBase[T]` (discovered under `pkg/schema`, the default `--schema-lib-path`) is an **owned master-data entity** — reference data this component publishes. It goes through the normal `1.gen/` pipeline, plus:

- Its table gets `ALTER TABLE <table> REPLICA IDENTITY FULL;` so CDC captures full row images. Publishing is CDC off this table — no `sender.Publish` code (see `kairos-create-masterdata-entity`).
- Don't put `+kairos:sql:column:` on the struct or on its `EntityBase` twin: the table must keep the `id, data` shape so it can be CDC-published (kairos-gen v0.1.x fails generation; v0.0.x accepts it, and the column breaks that shape). All other `+kairos:sql:*` directives (`table`, `idtype`, `index`, `ignore`, `loader:*`) remain valid.
- The CDC descriptor `chart(s)/resources/masterdata-entities.json`: if `test -f "$(go list -m -f '{{.Dir}}' bitbucket.org/ifs-pd/kairos-component-common/toolkit)/mk/generate.mk"` succeeds, `make generate` writes it automatically whenever `pkg/schema` has a `MasterDataEntityBase` struct. Otherwise it is written only when `Makefile` or `.init.mk` includes `masterdata-cdc.mk`; without that include you get the table but no descriptor, and nothing publishes the entity (see `kairos-create-masterdata-entity`).

### `+kairos:masterdata:` directives

The directive table (`no-cdc`, `table:`, `cdc-unverified`, and the `version:` error) lives in skill `kairos-create-masterdata-entity` § `+kairos:masterdata:` directives, so it is readable in a facade too. The rest of this section covers what those directives do to generated SQL.

### `+kairos:sql:ignore` on owned master data

> **Version gate — check before applying this section.** Read the component's kairos-gen version as in [Which kairos-gen runs](#which-kairos-gen-runs).
>
> - **≥ v0.1.7:** the rules below apply.
> - **v0.1.0–v0.1.6:** `+kairos:sql:ignore` hides the struct from `masterdata-entities.json` entirely.
> - **v0.0.x:** the struct stays in `masterdata-entities.json`, but nothing checks its hand-written table.
> - **Below v0.1.7:** there is no verifier, no `+kairos:masterdata:cdc-unverified` (do not add it) and no `--sql-validation-base-path`. To publish a hand-written table, upgrade kairos-gen first (skill `kairos-component-update`).
>
> The first toolkit release after v1.0.55 passes `--sql-validation-base-path sql/`, which requires kairos-gen ≥ v0.1.7.

`ignore` no longer hides the struct from the descriptor; `no-cdc` is the only CDC opt-out.

| `ignore` | `no-cdc` | `cdc-unverified` | Result |
|---|---|---|---|
| ✓ | – | – | no SQL or loader, **in descriptor**, hand-written SQL **verified** |
| ✓ | ✓ | – | no SQL, not in descriptor (unless `--masterdata-include-no-cdc`) |
| ✓ | – | ✓ | no SQL, in descriptor, not verified |
| – | – | ✓ | error: `cdc-unverified` requires `+kairos:sql:ignore` |
| any | ✓ | ✓ | error: contradictory directives |

With `--sql-path`, the verifier fails `make generate` unless the SQL tree (`sql/` minus `1.gen/`, or `--sql-validation-base-path`) has: (1) a `CREATE TABLE` for the table, (2) not only schema-qualified (`public.x`), (3) not `UNLOGGED`/temporary, (4) an unqualified `ALTER TABLE <table> REPLICA IDENTITY FULL`. It is a presence check: it does not follow renames, drops or columns. The error prints the lines to paste (`no-cdc`, `cdc-unverified`). Facades pass no `--sql-path`, so nothing is verified there.

Also errors, with or without `--sql-path`: a table shared with a non-twin entity, and unrelated ignored structs on one table (only versions of one entity may share).

kairos-gen writes no loader for an ignored struct. If the table must be bulk-loadable, write one with `kairos-create-loader`.

### Twin entities

kairos-gen v0.0.x has no twin logic: both structs emit SQL, so don't rely on this there. On v0.1.x: if the same logical entity exists both as a master-data struct (`ProductEntityV1`) and a domain `EntityBase` twin (`Product`, version-stripped base name matching), the **twin** owns the table and migrator and gets `REPLICA IDENTITY FULL` (unless the master-data struct is `no-cdc`); the master-data struct emits no SQL/migrator and contributes only its CDC descriptor entry pointing at the twin's table. With kairos-gen ≥ v0.1.7 this holds for an ignored master-data struct too (its twin's table gets `REPLICA IDENTITY FULL` unless `no-cdc`); to keep it unpublished add `no-cdc`.

## Troubleshooting

### Missing `event_outbox` or `idempotency` table

Check that both `+kairos:sql:lib:` directives are intact — the `eventsender` one in `cmd/client-api/main.go` (and in `cmd/integration-api/main.go` if that file exists), and the `event-handler` one in `cmd/event-handler/main.go`. These are the two most common breakages.

### Generated SQL not appearing for a new entity

1. Does the struct embed `entities.EntityBase[T]` or `entities.MasterDataEntityBase[T]`?
2. Is the struct in `internal/domain/` or `pkg/schema/`?
3. Is there a `+kairos:sql:ignore` directive accidentally on it? (With kairos-gen ≥ v0.1.7, ignored owned master data still appears in `masterdata-entities.json`.)
4. Did you run `make generate`?

For how to write the entity struct itself (file location, `EntityBase` embedding, JSON tag conventions), see skill `kairos-create-domain-entity` (or `kairos-create-masterdata-entity` for master data).

### Custom column / index not honored

Make sure the directive comment is **immediately above** the struct (no blank lines between the last directive and `type X struct`). `kairos-gen` only attaches directives that are part of the struct's doc comment block.

## Rules

- Commit `sql/0.libs/*` and `sql/1.gen/*` to version control.
- Never hand-edit files in `0.libs/` or `1.gen/` — `make generate` will overwrite them. Use a `+kairos:sql:` directive on the entity, or add hand-written SQL under `sql/3.custom/`.
- Keep `3.custom/` small — only use it when no directive can express the requirement.
