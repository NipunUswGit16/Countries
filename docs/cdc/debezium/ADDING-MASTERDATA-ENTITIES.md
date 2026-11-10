# How to add a master-data entity

A practical, copy-paste guide for developers. It walks through adding a new
master-data entity end to end — **producing** it from a component (todo-demo)
and **consuming** it in another (notes-demo) — using the real `Priority` entity
as the worked example.

- Architecture & rationale: [`MASTERDATA-CDC-ARCHITECTURE.md`](./MASTERDATA-CDC-ARCHITECTURE.md)
- Cluster/platform setup: [`SETUP.md`](./SETUP.md)
- **Producer workflow:** `kairos-create-masterdata-entity` skill (see [`AGENTS.md`](../../AGENTS.md))
- **Mechanism / envelope:** [`MASTERDATA-CDC-MECHANISM.md`](./MASTERDATA-CDC-MECHANISM.md)

> **TL;DR** — On the producer, add a Go struct that embeds
> `entities.MasterDataEntityBase[T]` under `pkg/schema/masterdata/`, register its
> `ComponentName()`, and run `make generate`. On a consumer, **import** the
> producer's `pkg/schema` module (a local `third_party/` copy is only a temporary
> bridge until that module is published), add one
> `eh.Sync(eventhandler.MasterData[*T]())` line, and run `make generate`. No
> handler, repository, or publisher code is required.

**Related work:**

- Toolkit / kairos-gen: [§7](#7-toolkit--kairos-gen)
- **Component scaffold:** this template ships the Debezium chart templates and an empty `pkg/schema/masterdata` package (no example entity). `make generate` writes `chart/resources/masterdata-entities.json` with `"entities": []` until the first entity exists.

---

## 0. What counts as master data?

Master data is **reference data**: centrally owned, slow-changing, and referenced
by many rows across components (e.g. `Company`, `Priority`). If it is
transactional (created/updated constantly, owned by one workflow), it is a
regular domain entity, not master data.

Rules of thumb:

- One clear **owner** component (the producer). Everyone else is a read-only
  consumer that stays in sync via CDC.
- It embeds `entities.MasterDataEntityBase[entities.EntityId]` — that embedding is
  the "please capture me" signal to `make generate`.
- Its JSONB fields are **camelCase** (`createdAt`, not `created_at`); the table
  name is **snake_case plural** (`priorities`).

---

## 1. Producer side (owning component, e.g. `todo-demo`)

### 1.1 Define the entity

Create `pkg/schema/masterdata/<entity>.go`. The struct embeds
`MasterDataEntityBase`; everything else is plain fields with camelCase JSON tags.

```go
// pkg/schema/masterdata/priority.go
package masterdata

import "bitbucket.org/ifs-pd/kairos-component-common/common/entities"

// Priority is a master-data entity exposed for CDC.
//
// Master-data CDC: embeds entities.MasterDataEntityBase, so `make generate`
// picks it up and captures it to the Kafka topic `todo-demo.priority.1`. To opt
// out, add `+kairos:masterdata:no-cdc` to this doc comment. Version comes from
// the `V<n>` suffix on the type name (or `1` if absent).
type Priority struct {
	entities.MasterDataEntityBase[entities.EntityId] `json:",inline"`
	Code  string `json:"code"`
	Name  string `json:"name"`
	Rank  int    `json:"rank"`
	Color string `json:"color"`
}
```

### 1.2 Register `ComponentName()`

Add one line to `pkg/schema/masterdata/component_name.go`. This ties the entity
to the owning component (the Kafka topic prefix / `ce_source`).

```go
func (Priority) ComponentName() string { return schema.ComponentName }
```

### 1.3 Generate

```bash
make generate
```

This is the only generation step. Do not add a Makefile include, and do not
hand-edit the files below. When `pkg/schema` contains a `MasterDataEntityBase`
embedder, `make generate` writes the CDC descriptor itself (see [§7](#7-toolkit--kairos-gen)):

| Artifact | Purpose |
|---|---|
| `chart/resources/masterdata-entities.json` | Entity → table/topic/`ce_*` map; the `KafkaConnector` is rendered from this |
| `sql/1.gen/priorities.sql` | `CREATE TABLE priorities (id UUID, data JSONB)` + GIN index + `REPLICA IDENTITY FULL` |
| `pkg/json-schema/todo-demo.priority.1.json` | JSON Schema for the entity |
| `chart/templates/db-script-runner.yaml` (`$jobVersion`) | SHA over `sql/**` so the migration Job re-runs when SQL changes |

> **`REPLICA IDENTITY FULL`** is what lets Debezium include the full prior row on
> UPDATE/DELETE — don't remove it.

### 1.4 (Optional) seed rows

Add a `sql/3.custom/seed_<table>.sql` with idempotent `INSERT … ON CONFLICT DO
NOTHING` so the demo/local env has data. Files in `sql/3.custom/` are yours to
maintain (never regenerated).

### 1.5 Verify

```bash
cd pkg/schema && go build ./... && go test ./masterdata/
```

Deploy and confirm the connector emits on `todo-demo.priority.1.<tenant>`
(see [`SETUP.md`](./SETUP.md) §4).

---

## 2. Consumer side (e.g. `notes-demo`)

A consumer replicates the producer's entity into a **local read-model table**
automatically. There is no handler to write — the framework upserts on each
CloudEvent and deletes on tombstones.

### 2.1 Import the producer's schema

Consumers need the producer's Go types for `eh.Sync(eventhandler.MasterData[*T]())`.
The normal path is a published module dependency:

```go
require bitbucket.org/ifs-pd/kairos-todo-demo/pkg/schema v0.0.9 // example
```

```go
import todomasterdata "bitbucket.org/ifs-pd/kairos-todo-demo/pkg/schema/masterdata"
```

**You do not need to vendor** once the producer has tagged and published
`pkg/schema` with its `masterdata/` package.

#### Temporary bridge (unpublished schema)

While the producer PR is still in review, a local copy under `third_party/` avoids
waiting on a module tag. This is what `notes-demo` does today:

```bash
make sync-todo-demo-schema   # rsync ../kairos-todo-demo/pkg/schema -> third_party/todo-demo-schema
```

```go
replace bitbucket.org/ifs-pd/kairos-todo-demo/pkg/schema => ./third_party/todo-demo-schema
```

Remove `third_party/` and the `replace` once `kairos-todo-demo/pkg/schema` is
published with the master-data types.

### 2.2 Register the sync

Add one line inside `eh.Sync(...)` in
`internal/event-handler/handlers.go`:

```go
func InitHandlers(eh eventhandler.GenericEventHandler[...]) {
	eh.Sync(
		eventhandler.MasterData[*todomasterdata.Company](),
		eventhandler.MasterData[*todomasterdata.Priority](), // <-- new
	)
	// ... event / command handlers ...
}
```

### 2.3 Generate

```bash
make generate
```

On the consumer this updates:

| Artifact | Change |
|---|---|
| `chart/resources/topic-config.json` | Adds `{ "inputTopic": "todo-demo.priority.1", "types": ["todo-demo.priority"] }` |
| `sql/1.gen/priorities.sql` | Local read-model table (`id UUID`, `data JSONB`, GIN) — **no** `REPLICA IDENTITY FULL` (consumers don't publish) |
| `charts/templates/db-script-runner.yaml` (`$jobVersion`) | Recomputed SQL SHA |

### 2.4 Verify

```bash
go build ./...
```

Deploy; the event-relay subscribes to the new topic and the read-model table is
populated as the producer changes rows.

### 2.5 (Optional) actually use it

Replication alone needs nothing more. To *reference* the entity (e.g. put a
`priorityId` on a note and validate it), add the field to your domain model and a
service-layer lookup against the local `priorities` table — normal application
code, unrelated to CDC.

---

## 3. Removing / renaming an entity

- **Producer:** delete the struct + its `ComponentName()` line, delete any
  `sql/3.custom/seed_<table>.sql`, then `make generate`. The generated
  `sql/1.gen/<table>.sql`, JSON schema, and `masterdata-entities.json` entry are
  removed automatically.
- **Consumer:** remove the `eh.Sync(MasterData[*T]())` line, refresh the producer
  schema dependency (or `make sync-…-schema` while unpublished), then
  `make generate`. The topic-config entry and `sql/1.gen/<table>.sql` are removed.
- Renaming is a remove + add. The read-model table name follows the Go type name
  (`Priority` → `priorities`), so a rename creates a new table.

---

## 4. Conventions & gotchas

| Topic | Rule |
|---|---|
| Table name | snake_case **plural**, derived from the type name (`Priority` → `priorities`) |
| JSONB fields | **camelCase** (`createdAt`), matching Go JSON tags — never snake_case inside JSONB |
| Entity id field | `entities.EntityBase` uses `Id` (not `ID`): `p.Id.String()` |
| Generated files | Never hand-edit `sql/1.gen/`, `pkg/json-schema/`, `masterdata-entities.json`, or the `$jobVersion` — run `make generate` |
| `$jobVersion` SHA | It is `sha256` over `find sql/ -type f \| sort` (per-file hash + path, then hashed). If a migration Job doesn't re-run after a SQL change, the SHA is stale — regenerate |
| Opt out of CDC | Add `+kairos:masterdata:no-cdc` to the struct doc comment |
| Version | Derived from the `V<n>` type-name suffix (or `1` if absent). There is no version directive. |
| Cross-component schema | **Import** the producer's `pkg/schema` module. Use `third_party/` + `go.mod replace` only until that module is published |

---

## 5. The one-screen checklist

**Produce** (owner):

1. `pkg/schema/masterdata/<entity>.go` — struct embeds `MasterDataEntityBase`
2. `component_name.go` — add `func (<Entity>) ComponentName() string`
3. `make generate`
4. (optional) `sql/2.custom/seed_<table>.sql`

**Consume** (subscriber):

1. Add `require` on the producer's `pkg/schema` (or temporary `third_party/` + `replace`)
2. `handlers.go` — add `eventhandler.MasterData[*<pkg>.<Entity>]()` to `eh.Sync(...)`
3. `make generate`

---

## 6. Chart scaffold (producer) — `db-secret.yaml` and `KafkaConnector`

These live in the **component chart**, not the common library chart. They are part
of this template, not a Nexus-only experiment to relocate later.

| File | Generated? | Purpose |
|---|---|---|
| `chart/resources/masterdata-entities.json` | **Yes** — `make generate` / kairos-gen | Entity → table/topic/`ce_*` map; `KafkaConnector` reads this at render time |
| `sql/1.gen/<table>.sql` | **Yes** — kairos-gen | DDL + `REPLICA IDENTITY FULL` on producers |
| `chart/templates/debezium/kafka-connector.yaml` | **No** — static Helm template | Renders `KafkaConnector/<comp>-cdc` into `kairos-kafka-connect` when `debezium.enabled` |
| `chart/templates/debezium/db-secret.yaml` | **No** — static Helm template | Renders `ExternalSecret/<comp>-db` into `kairos-kafka-connect` when `debezium.dbSecret.enabled` (Nexus); syncs `user`/`password` from the **same Key Vault keys** as `postgres.usernameSecretName` / `postgres.passwordSecretName`. Local sets `enabled: false`; Kyverno `generate-debezium-db-secret` owns the secret |

The common chart does **not** generate these today — it cannot know your entity
set or DB secret keys. Values under `debezium:` and `postgres:` drive the
templates; the entity list comes from generated JSON.

### DB credentials — two supported patterns

The toolkit no longer has a `make deploy` post-deploy hook that copied Postgres
credentials into the Connect namespace. Provisioning is **environment-owned**:

| Environment | Who creates `Secret/<comp>-db` in `kairos-kafka-connect` |
|---|---|
| **Local k3d** | Kyverno `generate-debezium-db-secret` (`debezium.dbSecret.enabled: false`; dedicated `debezium` role, not `postgres`/`postgres`) |
| **Nexus / GitOps** | Component chart `ExternalSecret` (`db-secret.yaml`) **or** a platform-managed secret — same shape: `user` + `password` keys |

Both patterns satisfy the connector reference
`${secrets:kairos-kafka-connect/<comp>-db:user|password}`.
The component-chart `ExternalSecret` avoids duplicating secret material — it
reuses the Key Vault keys the app already uses for Postgres.

---

## 7. Toolkit / kairos-gen

`make generate` is the only step. `toolkit/mk/go.mk` invokes `kairos-gen` and,
when `pkg/schema` contains a `MasterDataEntityBase` embedder, passes
`--masterdata-output` itself. There is no `masterdata-cdc.mk` include and no
extra Makefile wiring. Do not author `chart/resources/masterdata-entities.json`
by hand — the next `make generate` overwrites it, and deletes it when no owned
master-data embedder remains.

| Flag | Default | Effect |
|---|---|---|
| `--schema-lib-path` | `pkg/schema` | Discovers owned `MasterDataEntityBase` structs (recursive) |
| `--sql-path` | `sql/` | Per-table DDL; owned master-data tables get `REPLICA IDENTITY FULL` |
| `--masterdata-output` | `chart/resources/masterdata-entities.json` (passed automatically when owned master data is present) | CDC descriptor JSON only |

`--masterdata-cdc-sql-output` and `--masterdata-scan-subdirs` are gone. Owned
master-data discovery is `--schema-lib-path`; table SQL is `--sql-path`. A
direct `kairos-gen` invocation that still passes those flags fails.
`--component-name` is required when `--masterdata-output` is set; the toolkit
supplies it from the component name.

Entities marked `+kairos:masterdata:no-cdc` are omitted from the descriptor.
Facade components that need those rows set `MASTERDATA_INCLUDE_NO_CDC` so
`make generate` also passes `--masterdata-include-no-cdc`. A regular component
leaves that unset: its Debezium connector builds `table.include.list` from
every row, and a no-cdc table has no `REPLICA IDENTITY FULL`.
