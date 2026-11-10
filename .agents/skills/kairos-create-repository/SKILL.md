---
name: kairos-create-repository
description: Creates an interface-based PostgreSQL repository in internal/repositories/ using the 2-column id/JSONB pattern, a per-entity table-name constant quoted with pgx.Identifier, and tenant-scoped sessions. Use when adding persistence for a domain entity, writing CRUD for an aggregate, wiring a repository into ServicesFactory, or when the user says "add repository", "create repository", or "persist entity".
---

# Create a Kairos Repository

Repositories handle all PostgreSQL interaction — serialization, CRUD, queries — for a single domain aggregate. They are interface-based (for testability) and take a tenant-scoped `interfaces.Session`.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Design pattern

- **2-column tables**: every Kairos table is exactly `id UUID PRIMARY KEY` + `data JSONB NOT NULL`, regardless of the aggregate's shape.
- **Tenant-scoped session**: `interfaces.Session` is already scoped to the current tenant. You never compose tenant filters into your query yourself.
- **One table-name constant per entity**: declare it in that entity's repository file, named after the entity (`const examplesTableName = "examples"`). All repositories share package `repositories`, so a bare `tableName` collides as soon as there is a second one. Table names are *not* configurable.
- **Quote the name**: build every query with `fmt.Sprintf` and `pgx.Identifier{examplesTableName}.Sanitize()`, never by string concatenation, so reserved-word names still work.

These rules are mechanics. The *why* — schema-per-tenant isolation, automatic `search_path` scoping and the JSONB rationale — lives in skill `kairos-database-model`.

## File location & naming

- **Interface file**: `internal/repositories/{entity}_repository.go`
- **Type names**: `{Entity}RepositoryInterface` and `{Entity}Repository`

## Template

The filter type depends on the pagination layout. If `internal/domain/pagination.go` exists, use `domain.PaginationFilter` as below. Otherwise the component keeps it in the client API's package: import `internal/api/dto` and write `dto.PaginationFilter`. The template upgrade-file `20261019T104600-pagination-types-moved.md` (`kairos-component-update`) moves it; don't move it inside this task.

```go
package repositories

import (
	"context"
	"encoding/json"
	"fmt"

	"bitbucket.org/ifs-pd/kairos-component-common/common/entities"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/domain"
	"bitbucket.org/ifs-pd/nga-common/postgres/client/interfaces"
	"github.com/jackc/pgx/v5"
)

const examplesTableName = "examples"

type ExampleRepositoryInterface interface {
	GetAll(ctx context.Context, filter domain.PaginationFilter) ([]domain.ExampleModel, int64, error)
	GetByID(ctx context.Context, id string) (domain.ExampleModel, error)
	Create(ctx context.Context, example domain.ExampleModel) (domain.ExampleModel, error)
	Update(ctx context.Context, id string, example domain.ExampleModel) (domain.ExampleModel, error)
	Delete(ctx context.Context, id string) error
}

// Compile-time interface check
var _ ExampleRepositoryInterface = (*ExampleRepository)(nil)

type ExampleRepository struct {
	session interfaces.Session
}

func NewExampleRepository(session interfaces.Session) *ExampleRepository {
	return &ExampleRepository{session: session}
}

func (r *ExampleRepository) Create(ctx context.Context, example domain.ExampleModel) (domain.ExampleModel, error) {
	jsonData, err := json.Marshal(example)
	if err != nil {
		return domain.ExampleModel{}, err
	}

	query := fmt.Sprintf(`
		INSERT INTO %s (id, data)
		VALUES ($1, $2::jsonb)
		ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data
	`, pgx.Identifier{examplesTableName}.Sanitize())

	_, err = r.session.Exec(ctx, query, example.Id.String(), string(jsonData))
	if err != nil {
		return domain.ExampleModel{}, err
	}
	return example, nil
}

func (r *ExampleRepository) GetByID(ctx context.Context, id string) (domain.ExampleModel, error) {
	entityID, err := entities.ParseId(id)
	if err != nil {
		return domain.ExampleModel{}, fmt.Errorf("invalid id format: %w", err)
	}

	query := fmt.Sprintf(`SELECT id, data::text FROM %s WHERE id = $1`, pgx.Identifier{examplesTableName}.Sanitize())

	var idStr, jsonData string
	err = r.session.QueryRow(ctx, query, entityID.String()).Scan(&idStr, &jsonData)
	if err != nil {
		return domain.ExampleModel{}, err
	}

	var result domain.ExampleModel
	err = json.Unmarshal([]byte(jsonData), &result)
	return result, err
}

func (r *ExampleRepository) Update(ctx context.Context, id string, example domain.ExampleModel) (domain.ExampleModel, error) {
	entityID, err := entities.ParseId(id)
	if err != nil {
		return domain.ExampleModel{}, fmt.Errorf("invalid id format: %w", err)
	}

	expectedETag := example.ETag.String() // compiles on every common version; GetETag() needs common >= v1.4.0
	example.EntityBase = example.EntityBase.ForUpdate()

	jsonData, err := json.Marshal(example)
	if err != nil {
		return domain.ExampleModel{}, err
	}

	query := fmt.Sprintf(`
		UPDATE %s
		SET data = $1::jsonb
		WHERE id = $2 AND data->>'etag' = $3
	`, pgx.Identifier{examplesTableName}.Sanitize())

	tag, err := r.session.Exec(ctx, query, string(jsonData), entityID.String(), expectedETag)
	if err != nil {
		return domain.ExampleModel{}, err
	}
	if tag.RowsAffected() == 0 {
		return domain.ExampleModel{}, fmt.Errorf("etag mismatch for %s: concurrent update or missing row", entityID)
	}
	return example, nil
}

// Delete and GetAll follow the same shape: build the query with
// pgx.Identifier{examplesTableName}.Sanitize() and parse incoming IDs with
// entities.ParseId.
```

`github.com/jackc/pgx/v5` is already in `go.mod` (as an indirect dependency of `nga-common/postgres`); `go mod tidy` moves it to the direct block.

`entities.ParseId` and `ForUpdate()` are part of the `EntityBase` contract — see skill `kairos-create-domain-entity` for the surface (parsers, constructors). Why `ForUpdate()` is mandatory on every write and why `Update` enforces `data->>'etag' = $caller_etag` (ETag-based optimistic concurrency) is in skill `kairos-database-model`.

## Promoted columns

A `+kairos:sql:column:` directive on the entity (e.g. `// +kairos:sql:column:external_id TEXT`) adds a column next to `id` and `data`. kairos-gen only creates the column; the repository fills it. The snippets assume `ExampleModel` has a field ``ExternalId string `json:"externalId"` ``.

- **Write it** in every `INSERT` and `UPDATE`, from the entity field, in the same statement as `data`:

  ```go
  query := fmt.Sprintf(`
  	INSERT INTO %s (id, data, external_id)
  	VALUES ($1, $2::jsonb, $3)
  	ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data, external_id = EXCLUDED.external_id
  `, pgx.Identifier{examplesTableName}.Sanitize())
  _, err = r.session.Exec(ctx, query, example.Id.String(), string(jsonData), example.ExternalId)
  ```

- **Read it back** if `internal/integration-api/loaders/generated` exists. The generated bulk loader strips a promoted field from `data` (the field whose snake_case name is the column name, `ExternalId` → `external_id`), unless the entity carries `+kairos:sql:loader:duplicate:external_id`. Bulk-loaded rows then hold the value only in the column, so select it and set the field after unmarshalling `data`:

  ```go
  query := fmt.Sprintf(`SELECT data::text, external_id FROM %s WHERE id = $1`, pgx.Identifier{examplesTableName}.Sanitize())
  var jsonData string
  var externalID *string
  if err := r.session.QueryRow(ctx, query, entityID.String()).Scan(&jsonData, &externalID); err != nil {
  	return domain.ExampleModel{}, err
  }
  var result domain.ExampleModel
  if err := json.Unmarshal([]byte(jsonData), &result); err != nil {
  	return domain.ExampleModel{}, err
  }
  if externalID != nil {
  	result.ExternalId = *externalID
  }
  ```

  If that directory doesn't exist, the component has no generated loaders, `data` keeps the field, and reading from `data` is enough.

When to add a promoted column at all is in `kairos-database-model` § When to add extra columns.

## Wiring into ServicesFactory

Each runtime binary has its own `ServicesFactory`: `internal/api/request/services_factory.go` (client API), `internal/event-handler/request/services_factory.go`, and `internal/integration-api/request/services_factory.go` if that file exists. Add the factory method to every runtime that calls the service and mirror it verbatim; see skill `kairos-create-service` § *Wiring into ServicesFactory* for which runtimes to touch.

If `internal/services/outbound_messenger.go` exists, the service takes the messenger as its second argument:

```go
func (f ServicesFactory) CreateExampleService(
    ctx Context,
    session interfaces.Session,
) *services.ExampleService {
    repo := repositories.NewExampleRepository(session)
    return services.NewExampleService(repo, services.NewSenderAdapter(ctx.Sender()), ctx.Logger())
}
```

Otherwise pass what the service's constructor takes in this component (`kairos-create-service` § The `OutboundMessenger` interface decides it), for example `services.NewExampleService(repo, ctx.Logger())` when the component has no messenger.

## Required elements checklist

- [ ] One package-level table-name constant per entity, named after it (`examplesTableName`), in that entity's repository file
- [ ] Interface type `{Entity}RepositoryInterface` defined
- [ ] Concrete type `{Entity}Repository` with a `session interfaces.Session` field
- [ ] Compile-time assertion `var _ {Entity}RepositoryInterface = (*{Entity}Repository)(nil)`
- [ ] Constructor `New{Entity}Repository(session)` — no table name parameter
- [ ] Every query is built with `fmt.Sprintf` and `pgx.Identifier{<entity>TableName}.Sanitize()`, never by concatenation
- [ ] Each `+kairos:sql:column:` column is written on every insert/update, and read back when `internal/integration-api/loaders/generated` exists
- [ ] `Create` uses `INSERT ... ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data` (upsert)
- [ ] `GetByID` parses the incoming string with `entities.ParseId(...)` for validation
- [ ] `Update` enforces ETag-based optimistic concurrency: capture the caller's ETag **before** `ForUpdate()`, match `id` AND `data->>'etag'` in the `WHERE` clause, and surface `RowsAffected() == 0` as a concurrency-conflict error (not a silent no-op)
- [ ] Entity IDs passed to SQL as `.String()`
- [ ] Repository wired through the `ServicesFactory` of every runtime that calls the service (client-API, event-handler, and/or integration-API variants)
- [ ] The table-name constant matches what `kairos-gen` emits for the corresponding domain entity (or what a `+kairos:sql:table:` directive on that entity overrides it to). See skills `kairos-create-domain-entity` and `kairos-sql-lifecycle`.

## JSONB query patterns

The `@>` containment and `data->>'field'` filters below rely on the GIN index that `kairos-gen` auto-generates for every entity table (see skills `kairos-create-domain-entity` and `kairos-sql-lifecycle`). Disabling it with `+kairos:sql:index:no-auto-gin-index` will turn these queries into sequential scans.

```sql
-- Read a JSONB scalar
SELECT data->>'customerName' FROM orders WHERE id = $1;

-- Filter by a JSONB field
SELECT * FROM orders WHERE data->>'status' = 'active';

-- Containment (uses GIN index)
SELECT * FROM orders WHERE data @> '{"totalAmount": 99.99}';

-- Pagination
SELECT id, data::text FROM orders
ORDER BY id
LIMIT $1 OFFSET $2;
```

## Common mistakes (RED FLAGS)

- Making the table name configurable (constructor parameter, `AppConfig` getter, environment variable) — it must be a package-level constant in the repository. See skill `kairos-database-model`.
- A second `const tableName` in package `repositories` → redeclaration compile error. Name each constant after its entity.
- Concatenating the table name into SQL (`"... FROM " + name`) instead of `pgx.Identifier{name}.Sanitize()`.
- Adding explicit tenant filters to queries → redundant (the session handles it) and likely to bypass isolation. See skill `kairos-database-model` for the session auto-scoping invariant.
- Skipping `entities.ParseId(id)` on incoming strings → invalid UUIDs go to the database.
- Using `INSERT` without `ON CONFLICT` where upsert semantics are needed.
- `Update` that omits `data->>'etag' = $caller_etag` from the `WHERE` clause, or ignores `RowsAffected() == 0` → silent lost-update; optimistic concurrency is bypassed. See skill `kairos-database-model`.
- Capturing the caller's ETag **after** calling `ForUpdate()` → you compare against the freshly generated ETag, so the check always passes and is meaningless.
- Creating the repository without a corresponding compile-time interface assertion.
