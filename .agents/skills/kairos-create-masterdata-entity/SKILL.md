---
name: kairos-create-masterdata-entity
description: Creates a new Kairos master data entity in pkg/schema/masterdata/ for reference data replicated across services, and explains what make generate and CDC (or a facade's publisher job) do with it. Use when adding a *EntityV1 type for master data, defining reference data that other components will consume, or when the user says "create master data entity", "add reference data", or "new master data type".
---

# Create a Kairos Master Data Entity

Master data is the **authoritative, non-transactional business information that defines the core entities ("nouns") essential to running the business** — Organizations, Currencies, Products, Customers, Assets, Factories, Categories, and the like. In Kairos it lives in `pkg/schema/masterdata/`, is published by exactly one **owning component**, and is automatically replicated as a read-only copy into every subscribing component's PostgreSQL tables.

A piece of data qualifies as master data when **all four** of the following hold:

- **Critical** — it represents a fundamental concept of the business, not a transient artefact of a transaction.
- **Stable** — it changes infrequently relative to high-volume transactional data (events, commands, line items, audit records).
- **Contextualizing** — it gives meaning to transactional data; transactions reference it but do not constitute it.
- **Single authoritative owner, wide reuse** — exactly one component is the source of truth (publisher), and many loosely coupled components consume it (subscribers via `eh.Sync`). This is the publish-many-replicate model that `kairos-register-masterdata-mapper` wires up.

If your entity is high-volume, frequently mutated, owned and consumed only by your own component, or is itself a record of *something happening* (an order, an invoice, an audit entry), it is **not** master data — model it as a domain entity instead (see `kairos-create-domain-entity`).

## File location & naming

- **Location**: `pkg/schema/masterdata/{entity}.go`
- **Type name**: the name sets the topic and `ce_type`, so choose it once and never rename it. The type name minus its `V{N}` suffix, kebab-cased, is the entity segment; no suffix means version 1. `ProductEntityV1` → `<component>.product-entity.1`, `ProductV1` → `<component>.product.1`, `Priority` → `<component>.priority.1`. The `{Entity}EntityV{Version}` form is optional; it keeps master-data types recognisable next to commands and events. Follow the convention the component's existing master data uses.
- **No consecutive capitals** (`HttpRequest…`, not `HTTPRequest…`). The `ce_type` depends on `kairos-component-common/common` in `go.mod`: on ≥ v1.4.0 `HTTPRequest` becomes `http-request-…`, on < v1.4.0 `h-t-t-p-request-…`. Bumping common across v1.4.0 changes the `ce_type` and topic of an existing acronym-named entity, which breaks its subscribers — treat that bump like a rename.

## Template

**Field tags below are shown in swag form. Whether they shape `pkg/json-schema/` depends on the kairos-gen version — see § JSON Schema field annotations; below v0.1.0 put the same constraints on `+kairos:schema:*` comment lines instead.**

```go
package masterdata

import (
	"bitbucket.org/ifs-pd/kairos-component-common/common/entities"
	"bitbucket.org/ifs-pd/kairos-component-template/pkg/schema"
)

// ExampleEntityV1 is a master data entity for the example model version 1.
type ExampleEntityV1 struct {
	entities.MasterDataEntityBase[entities.EntityId]
	Name        string   `json:"name" validate:"required,min=1,max=200"`
	CustomField string   `json:"customField,omitempty" validate:"max=200"`
	CustomList  []string `json:"customList,omitempty"`
}

// NewExampleEntity creates a new example master data entity (optional helper).
func NewExampleEntity(etag entities.EntityETag, name string, customField string, customList []string) *ExampleEntityV1 {
	return &ExampleEntityV1{
		MasterDataEntityBase: entities.NewMasterDataEntityBase(entities.NewId(), etag),
		Name:                 name,
		CustomField:          customField,
		CustomList:           customList,
	}
}

func (e *ExampleEntityV1) ComponentName() string {
	return schema.ComponentName
}
```

## Required elements checklist

- [ ] File location is `pkg/schema/masterdata/`
- [ ] Type embeds `entities.MasterDataEntityBase[entities.EntityId]`
- [ ] All JSON tags are **camelCase**
- [ ] Read the kairos-gen version (see below) and annotated fields accordingly (swag tags on ≥ v0.1.0, else `+kairos:schema:*`)
- [ ] Optional: a constructor `New{Entity}(...)` that calls `entities.NewMasterDataEntityBase(entities.NewId(), etag)`
- [ ] `ComponentName() string` returning `schema.ComponentName` (the root schema package constant)

Master data entities do **not** implement `Validate` (they're reference data, not transactional messages). A constructor is optional; it is convenient because callers supply an `ETag`.

## First schema in this module

If `pkg/schema/go.mod` does not yet require `bitbucket.org/ifs-pd/kairos-component-common/common`, this is the module's first schema type and it needs `go mod tidy`. Pin `common` to the root module's version first:

1. In the component root, read the version: `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/common`.
2. In `pkg/schema/`, run `go get bitbucket.org/ifs-pd/kairos-component-common/common@<that version>`, then `go mod tidy`.

An unpinned tidy takes `common@latest`. Through the root's `replace` of `pkg/schema`, that can lift the whole component across common v1.4.0, which raises the Go floor to 1.27.2 and breaks `eventhandlertest` on event-handler < v1.2.44. Afterwards re-read `common`, `api` and `event-handler` with `go list -m` in the root and re-run any version checks. If `pkg/schema/go.mod` already requires `common`, skip this step.

## JSON Schema field annotations

Even without `Validate()`, master-data fields still feed `pkg/json-schema/` via `kairos-gen`.

Which annotations it reads depends on the kairos-gen version. If `go.mod` has a `cmd/kairos-gen` line, read `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen`; otherwise run `kairos-gen --version` (`(devel)` or a failure is unknown).

| kairos-gen | What to do |
|---|---|
| ≥ v0.1.0 | **Prefer swag struct tags**, whether or not `internal/integration-api/openapi.go` exists. Author with `validate` / `binding` (`required`, `optional`, `min`/`max`, `gte`/`lte`, `gt`/`lt`, `len`, `oneof`, `unique`), plus `enums`, `format`, `default`, `example` (→ draft-07 `examples` array), `swaggertype`, `swaggerignore`. Do **not** emit a parallel `+kairos:schema:*` for a constraint a tag already expresses. Use a Kairos directive only as an escape hatch (no tag maps to the keyword, or the messaging schema must diverge from Swagger). Directives always win per key when both are present. On `kairos-component-common/toolkit` ≥ v1.0.49 a field is optional unless it has `validate:"required"` or `+kairos:schema:required`; on older toolkits fields are required by default. |
| < v0.1.0 or unknown | **Use `+kairos:schema:*` comment directives only.** This generator reads no struct tags, so `validate`/`enums`/… do not shape `pkg/json-schema/`. |

`internal/integration-api/openapi.go` only decides whether `make generate` also emits `pkg/openapi/`; don't add it to change the annotation style.

**Precedence (≥ v0.1.0):** Go type inference → swag tags → `+kairos:schema:*`. Route `@Param` / `@Success` comments are never consulted.

Full tables: `kairos-gen` README (`#kairos-schema-directives`).

## Publishing master data (CDC)

The owning component does **not** publish master data with `sender.Publish`; you write no publish code. Who publishes depends on the component:

| Check | What publishes |
|---|---|
| Facade (the check in `../using-kairos-skills/reference/facade.md`) | The facade's `command-publisher` job sends `start-masterdata-sync` with `chart/resources/masterdata-entities.json` as the payload. `make generate` emits only that descriptor and `pkg/json-schema/` (`GENERATE_MODULES := masterdata json`): no table, no topic config, no CDC. Each entity's topic is `<component>.<entity-kebab>.<version>`. Directives: § `+kairos:masterdata:` directives below. The rest of this section does not apply. |
| `chart/templates/debezium/` exists | CDC (Debezium) off the entity's PostgreSQL table — the rest of this section. |
| `chart/templates/debezium/` missing, and `kairos-component-common/toolkit` ≥ v1.0.49 in `go.mod` or `.init.mk` includes `masterdata-cdc.mk` | `make generate` writes the table and the descriptor, but this component deploys no Debezium connector, so nothing publishes the entity yet. Tell the author. |
| `chart/templates/debezium/` missing, toolkit < v1.0.49, and no `include $(MK)/masterdata-cdc.mk` in `.init.mk` | No descriptor is generated and nothing publishes the entity; subscribers will never receive it. Stop and tell the author. CDC is adopted by a template update (skill `kairos-component-update`), not by hand. |

Because the struct embeds `MasterDataEntityBase[T]` under `pkg/schema`, `kairos-gen` treats it as an **owned master-data entity** on `make generate`, emitting its `id, data` table (set up for CDC), the CDC descriptor, and — where `chart(s)/resources/component-config.json` exists — its topic in `ownedTopics`. Owned master data adds nothing to this component's `topic-config.json` (that file lists subscriptions). `+kairos:masterdata:no-cdc` suppresses `REPLICA IDENTITY FULL` and, unless `--masterdata-include-no-cdc` is set, omits the entity from `masterdata-entities.json`. Facade components set that flag so the sync job still publishes the entity; regular components leave it off. `component-config.json` lists the topic either way. The `+kairos:masterdata:` directives are in the next section. For the generation pipeline — `REPLICA IDENTITY FULL`, twin handling, and how the descriptor is gated — see skill `kairos-sql-lifecycle` (application components).

With kairos-gen ≥ v0.1.7 (version: `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen` when `go.mod` has a `cmd/kairos-gen` line, else `kairos-gen --version`), `+kairos:sql:ignore` (hand-written table) still publishes the entity: it keeps its descriptor row and kairos-gen verifies your SQL has the table and `REPLICA IDENTITY FULL`. Add `+kairos:masterdata:cdc-unverified` when the SQL lives outside `sql/` and kairos-gen cannot check it, or `+kairos:masterdata:no-cdc` if it must not be published. With kairos-gen v0.1.0–v0.1.6, `+kairos:sql:ignore` removes the entity from `masterdata-entities.json` and `cdc-unverified` has no effect; upgrade kairos-gen to v0.1.7 to publish a hand-written table. kairos-gen v0.0.x keeps the ignored entity in `masterdata-entities.json` but verifies nothing. In every version no loader is generated for an ignored entity: if the table must be bulk-loadable, write a custom loader with skill `kairos-create-loader`.

One authoring rule follows directly from CDC: the table must stay `id, data`, so `+kairos:sql:column:` is a **hard error** on a master-data struct (or its `EntityBase` twin). Keep every field inside `data` with camelCase JSON tags. The `idtype` directive is still allowed (e.g. `CHAR(32)` for F1/Oracle `SYS_GUID()` ids — see `kairos-create-domain-entity`).

## `+kairos:masterdata:` directives

Comment directives on the master-data struct. They apply in facades and application components alike. Where a row names a kairos-gen version, read it as `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen` when `go.mod` has a `cmd/kairos-gen` line, else `kairos-gen --version`.

| Directive | Effect |
|---|---|
| `+kairos:masterdata:no-cdc` | Suppress `REPLICA IDENTITY FULL` on the generated table. Excludes the entity from `masterdata-entities.json` unless kairos-gen runs with `--masterdata-include-no-cdc` (toolkit variable `MASTERDATA_INCLUDE_NO_CDC`; facades set it so the `command-publisher` job still publishes every descriptor row). With the flag the row has the same fields as every other row. The flag does not change SQL. Where `component-config.json` exists it still lists the entity's topic. |
| `+kairos:masterdata:table:` | Backward-compat **alias** for `+kairos:sql:table:`. kairos-gen v0.0.x ignores it, so use `+kairos:sql:table:`, which works on every version. |
| `+kairos:masterdata:cdc-unverified` | **kairos-gen ≥ v0.1.7 only** (older versions silently accept it on an ignored struct and do nothing with it, so it is not a usable check of the version). Requires `+kairos:sql:ignore`. Keeps the descriptor row, skips verification of the hand-written SQL. For SQL outside `sql/`, a build-then-rename migration, or a verifier false positive. Error with `no-cdc`. Not needed in a facade: it has no `sql/` and passes no `--sql-path`, so nothing is verified. |

On kairos-gen v0.1.x, `+kairos:masterdata:version:` is an error: the version is derived from the `V<n>` struct-name suffix (or `1` if absent). v0.0.x still reads `version:N`; don't add it either way.

For `+kairos:sql:ignore` on owned master data, twin entities and the SQL verifier (application components only), see skill `kairos-sql-lifecycle` § Owned master-data tables (CDC).

## What downstream components see

Subscribers that register a mapper for `*masterdata.ExampleEntityV1` automatically get upsert-into-table behaviour with a table name derived from the type name (`ExampleEntityV1` → `example_entities`) unless overridden. Empty payloads trigger deletion. When the name ends in an acronym the default table differs by the subscriber's event-handler version, so subscribers should set `.TableName(...)` (see `kairos-register-masterdata-mapper`).

## Versioning

**Each master-data version flows to its own topic**, and subscribers opt in by registering a mapper for **one** version — registering two versions of the same entity fails on event-handler ≥ v1.2.44 and on kairos-gen ≥ v0.1.0 (see `kairos-register-masterdata-mapper`). Beyond that, the standard rules apply: V1 ships as-is; full breaking-vs-non-breaking rules and the deprecation/parallel-publish template live in `pkg/schema/AGENTS.md` (Versioning Policy). **If uncertain whether a change is breaking, ask the user.**

## After finishing

Run `make generate`. In a facade (see the table in § *Publishing master data*) it emits only `chart/resources/masterdata-entities.json` and `pkg/json-schema/`. Otherwise it emits the entity's table in `sql/1.gen/`, its descriptor row in `chart(s)/resources/masterdata-entities.json` (see the table in § *Publishing master data*), its topic in `component-config.json` `ownedTopics` where that file exists, and `pkg/json-schema/`. See `kairos-sql-lifecycle` for what the pipeline produces in an application component. Commit what changed.

## Common mistakes (RED FLAGS)

- Placing the file in `pkg/schema/` instead of `pkg/schema/masterdata/`
- Forgetting to embed `MasterDataEntityBase`
- Renaming the type after release — the name is the topic and `ce_type`
- snake_case JSON tags
- Implementing `Validate()` (master data doesn't validate; reject bad data in the command that creates it)
- Adding `+kairos:sql:column:` to a master-data struct (or its `EntityBase` twin) — hard error; the table must stay `id, data` so CDC can publish it. Keep the field inside `data`.
- Assuming `sender.Publish` is needed to publish master data — publishing is CDC-driven off the generated table (or the facade's command-publisher job); there is no publish call to write. `sender.SendMasterDataChange` was removed in common v1.4.0 and was never on `ctx.Sender()`.
