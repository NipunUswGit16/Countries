---
name: kairos-create-loader
description: Creates a hand-maintained custom loader for the integration API's bulk-load endpoint (POST /api/core/v1/load), disabling kairos-gen's automatic generation for that entity via "+kairos:sql:loader:disable" and wiring manual registration into internal/integration-api/loaders.go. Use when the user wants a custom loader, needs to customize how an entity is bulk-loaded, mentions the load endpoint, "create loader", "custom loader", or "+kairos:sql:loader:disable".
---

# Create a Kairos Custom Loader

A **loader** teaches the integration API's bulk-load endpoint (`POST /api/core/v1/load`, see skill `kairos-database-model` for the storage model it writes into) how to parse, validate, and upsert one entity type. `kairos-gen` already generates and registers loaders automatically for every entity discovered under `internal/domain/` and `pkg/schema/` — **this skill is not that path**. It exists for the one case `kairos-gen` can't handle itself: an entity whose loading behavior needs something the directive system can't express, so it must be permanently ejected from generation and hand-maintained.

If nothing below applies, don't use this skill — say so and point at the automatic path instead.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

- If `internal/integration-api/loaders.go` or the directory `internal/integration-api/loaders/generated` is missing, stop. This component has no integration API or no loader generation, so there is no generated loader to eject from. Tell the author the integration API is an optional runtime; no upgrade-file adds it today. Don't build it inside this task.
- If `go.mod` has no `cmd/kairos-gen` line, stop. Loaders come only from kairos-gen v0.1.x run through `go tool`. Point the author at the kairos-component-common upgrade-file `toolkit/20260818T133759-pin-kairos-gen-go-tool.md` (applied by `kairos-component-update`), then re-run these checks.
- Both present: continue.

## Step 0 — confirm there's a real reason to hand-maintain this loader

Interview the user before writing anything:

1. **Is there a genuine custom-behavior need?** Promoted columns alone are not one: the generated loader already writes each `+kairos:sql:column:` column (auto-matched by field name, or via the directives below) and strips the field from `data`. If there is no other need, the generated loader covers it with zero maintenance. Explain this and stop — don't scaffold a disabled loader for no benefit (unless the user insists).
2. **Is the requested customization actually a directive?** Check whether it maps onto one of these — if so, ask the user whether they'd rather use the directive instead of ejecting from generation:
   - `+kairos:sql:loader:column-expr:<col>:<Go expression>` — map a column from a Go expression over the entity's fields ({FieldName} is replaced with the field accessor).
   - `+kairos:sql:loader:column-sql:<col>:<SQL expression>` — shape the `VALUES`-slot SQL for a column ({value} is replaced with the column value).
   - `+kairos:sql:loader:duplicate:<col>` — keep a promoted field in the JSONB `data` blob too, instead of stripping it.

   These live on the entity struct and need no ejection — `kairos-gen` still generates and registers the loader. Only fall through to a hand-written loader for things directives genuinely can't express (custom validation, non-standard upsert semantics, cross-field business rules).
3. **Is the customization actually validation?** Kairos has dedicated hooks for that, invoked by the loading pipeline independently of the loader file: `Validate(ctx context.Context) error` (`types.Validator`) or `LoadValidate(ctx context.Context) error` (`types.LoaderValidator`, load-only, higher precedence). Ask the user whether the validation belongs on the entity (via one of these) rather than inside the loader's `PrepareForUpsert` — that's the documented mechanism and it applies to *any* load, not just this loader's code path.

Only proceed past this step once there's a concrete reason that requires a hand-maintained loader.

## Step 1 — resolve the entity (or entities)

Discovery must match what `kairos-gen` itself considers a loader target — same rules as skill `kairos-create-domain-entity` / `kairos-sql-lifecycle`:

- Scan `internal/domain/*.go` for structs embedding `entities.EntityBase[T]`.
- Scan `pkg/schema/**/*.go` for structs embedding `entities.MasterDataEntityBase[T]` (owned master data — these get loaders too, just like domain entities).
- Exclude a master-data struct that is **twin-shadowed** by a domain `EntityBase` struct of the same base name (version-suffix stripped) — the twin owns the table and the loader, not the master-data struct. See "Twin entities" in skill `kairos-sql-lifecycle`.
- Exclude anything imported from outside the current module — `kairos-gen` never generates loaders for external types either.

If the user named one entity, resolve it directly. If they named a scope ("all entities", a directory, several names), scan and **present the matched list back with one line per entity** (has promoted columns? has an existing `+kairos:sql:loader:disable`?) and get explicit confirmation before generating anything — each entity still needs to individually pass Step 0.

## Step 2 — get the real template, don't improvise one

`kairos-gen`'s custom-loader shape lives in `cmd/kairos-gen/internal/generate/templates/custom_loader.go.tmpl` inside `kairos-component-common`. Fetch the version actually in use, in this order:

1. Get the pinned version — the one `make generate` runs through `go tool` (a `kairos-gen` on `PATH` is ignored): `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen`.
2. Read the template from the Go module cache at that version:

   ```bash
   go mod download bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen@<version>
   cat "$(go env GOMODCACHE)/bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen@<version>/internal/generate/templates/custom_loader.go.tmpl"
   ```

3. If that fails (offline, proxy blocked), fall back to fetching the same path directly from Bitbucket. The repository tags the module as `cmd/kairos-gen/<version>` (e.g. `cmd/kairos-gen/v0.1.6`):

   ```bash
   git archive --remote=git@bitbucket.org:ifs-pd/kairos-component-common.git cmd/kairos-gen/<version> \
     cmd/kairos-gen/internal/generate/templates/custom_loader.go.tmpl | tar -xO
   ```

Never hand-copy a static version of this template into this skill — read the live one every time so it can't drift from what `kairos-gen` actually produces.

## Step 3 — write the loader file

- **Location**: `internal/integration-api/loaders/{entity}_loader.go` — the package `loaders`, a **sibling** of the generated `internal/integration-api/loaders/generated/` package, not inside it.
- **Do not carry over** the fetched file's `// Code generated by kairos-gen. DO NOT EDIT.` header — this file is now hand-maintained.
- Fill the template's placeholders by reasoning over the entity struct, exactly matching `kairos-gen`'s own column-mapping rules (see "Column mapping" in `cmd/kairos-gen/README.md#loader-generation`):
  1. `+kairos:sql:loader:column-sql:` directive → shapes the `VALUES`-slot expression.
  2. `+kairos:sql:loader:column-expr:` directive → Go expression over `{Field}` placeholders.
  3. Otherwise, auto-match: the entity field whose snake_cased Go name equals the column name.
  4. A promoted column backed by exactly one field is **stripped** from the JSONB `data` blob (via a shadow-field marshaling struct) unless `+kairos:sql:loader:duplicate:<col>` says otherwise.
- Then apply the actual customization surfaced in Step 0 — extra validation call, custom business rule in `PrepareForUpsert`, non-standard `GetBatchUpsertQueryParts`/`BuildUpsertArgs`, etc. — this is the whole reason the file is hand-maintained; don't leave it as a no-op copy of what generation would have produced.
- If the entity has **no** promoted columns (Step 0 already confirmed a real customization need beyond columns), the query parts are simply the two-column shape (`Columns: "id, data"`, `ValuesClause: "($1, $2::jsonb)"`, `ArgsPerRow: 2`) — same as `loader.StandardEntityLoader`, just with your custom logic layered into `ParseEntity`/`PrepareForUpsert`.

## Step 4 — disable generation on the entity

Add the directive **immediately above** the struct declaration, no blank line in between (see the sql-lifecycle troubleshooting note in skill `kairos-sql-lifecycle` — a directive separated from the struct by a blank line is silently ignored):

```go
// +kairos:sql:loader:disable
type Category struct {
    entities.EntityBase[entities.EntityId] `json:",inline"`
    // ...
}
```

This only disables **loader** generation — SQL generation for the entity's table is untouched (`+kairos:sql:ignore` is the separate, unrelated directive for that).

## Step 5 — wire manual registration

Edit `internal/integration-api/loaders.go` (package `api`, **not** the generated package) to import the `loaders` package and register the custom loader alongside the generated ones:

```go
package api

import (
    integrationapi "bitbucket.org/ifs-pd/kairos-component-common/api/integration"
    "bitbucket.org/ifs-pd/<component>/internal/integration-api/loaders"
    "bitbucket.org/ifs-pd/<component>/internal/integration-api/loaders/generated"
)

func RegisterLoaders(apiInstance integrationapi.LoaderRegistryProvider) {
    registry := apiInstance.LoaderRegistry()

    generated.RegisterLoaders(registry)
    registry.Register(loaders.NewCategoryLoader())
}
```

Registering after `generated.RegisterLoaders` is not required by the registry (order doesn't matter), but keep custom registrations visually grouped below the generated ones for readability. `Register` panics at startup in three cases:

- it runs after `Freeze()` (the integration API's `Start`);
- the loader's `EntityType()` is already registered — usually because the entity is still in `generated/register.go` (directive missing or `make generate` not re-run);
- the loader's `GetBatchUpsertQueryParts` is inconsistent: `ArgsPerRow` differs from the distinct `$N` count in `ValuesClause`, the placeholders are not exactly `$1..$ArgsPerRow`, or an `ON CONFLICT … DO UPDATE` suffix has an empty `ConflictPredicate` while `Columns` has no `data` column.

## Step 6 — verify

```bash
make generate   # confirm the entity dropped out of loaders/generated/register.go and no file regenerates it
go build ./...  # confirm loaders.go and the new file compile
```

Fail loudly — show the actual error — rather than leaving a broken tree. A common failure here is the entity still showing up in `register.go`: it means the directive wasn't attached (check placement) or `make generate` was run before the directive was saved.

## Re-running on an entity that already has a custom loader

If `internal/integration-api/loaders/{entity}_loader.go` already exists and the entity already carries `+kairos:sql:loader:disable`, treat this as **adding more customization to an existing loader**, not a fresh scaffold:

- Read the current file and confirm the directive and `loaders.go` registration are already correct (fix them if not — don't assume a hand-edited file always kept them in sync).
- Apply only the newly-interviewed change; don't regenerate the boilerplate from scratch and clobber prior customizations.

## Required elements checklist

- [ ] Step 0 interview happened and produced a concrete reason a directive/generic path couldn't satisfy
- [ ] Entity resolved via the same discovery rules `kairos-gen` uses (domain + owned master data, twin/external exclusions applied)
- [ ] Template fetched live from `kairos-component-common` at the version actually in use — not hand-copied into this skill
- [ ] File lives at `internal/integration-api/loaders/{entity}_loader.go`, package `loaders`, no `DO NOT EDIT` header
- [ ] Column mapping (directive → auto-match → strip-unless-duplicate) replicated faithfully for any promoted columns
- [ ] The actual customization is implemented, not just a no-op copy of the generated shape
- [ ] `+kairos:sql:loader:disable` directive immediately above the struct, no blank line
- [ ] `registry.Register(loaders.NewXxxLoader())` added to `internal/integration-api/loaders.go`
- [ ] `make generate` confirms the entity no longer appears in `loaders/generated/register.go`
- [ ] `go build ./...` passes

## Common mistakes (RED FLAGS)

- Scaffolding a disabled custom loader for an entity with no promoted columns and no real customization — the generic path already handles it for free.
- Ejecting from generation for something `+kairos:sql:loader:column-expr:`/`column-sql:`/`duplicate:` could have expressed without disabling anything.
- Putting validation logic in the loader's `PrepareForUpsert` instead of `Validate`/`LoadValidate` on the entity — the latter is invoked by the pipeline regardless of which loader handles the entity; the former only runs for this one file.
- Leaving the `// Code generated by kairos-gen. DO NOT EDIT.` header on the copied file — it's hand-maintained now.
- Placing the disable directive with a blank line before the struct — `kairos-gen` only attaches directives that are part of the struct's doc-comment block, so it's silently ignored and generation keeps overwriting the file you just wrote.
- Registering the custom loader via `loader.Register[T, TId](...)` — that's the generic path; a custom loader is registered with `registry.Register(NewXxxLoader())` (the loader instance implements `types.EntityLoader` itself).
- Forgetting `make generate` after adding the directive — the old generated file (or the entity's line in `register.go`) lingers and now conflicts with the hand-written one.
- Hand-copying today's `custom_loader.go.tmpl` contents instead of fetching it live at generation time — the next `kairos-gen` version bump silently drifts from what gets produced here.

## See also

- Skill `kairos-create-domain-entity` — for writing the entity struct itself and its `+kairos:sql:` directives.
- Skill `kairos-sql-lifecycle` — the full `+kairos:sql:*` / `+kairos:masterdata:*` directive reference, twin-entity rules, and directive-placement troubleshooting.
- Skill `kairos-database-model` — the `id`/`data JSONB` storage pattern and ETag-based optimistic concurrency this loader's upsert relies on.
- Skill `kairos-create-masterdata-entity` — for defining the `MasterDataEntityBase` struct itself, if the target is owned master data rather than a domain entity.
- [kairos-gen README — Loader Generation](https://bitbucket.org/ifs-pd/kairos-component-common/src/main/cmd/kairos-gen/README.md#loader-generation) and [Integration API README](https://bitbucket.org/ifs-pd/kairos-component-common/src/main/api/integration/README.md#registering-loaders) — the upstream source for everything above.
