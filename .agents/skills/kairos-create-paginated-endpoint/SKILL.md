---
name: kairos-create-paginated-endpoint
description: Creates a paginated list API endpoint — on either the client API or the integration API — using the PaginationFilter and PaginatedResponse[T] wrappers, converting domain models to response DTOs. Use when adding a list endpoint with page/limit/total, returning multiple rows from a collection, or when the user says "paginated endpoint", "list endpoint", or "GET all".
---

# Create a Paginated Kairos API Endpoint

Use this for list endpoints that return many rows and need `page`, `limit`, and `total` in the response envelope.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Target runtime

This works identically on both Fiber REST runtimes — the client API (`internal/api/`, `cmd/client-api`) and the integration API (`internal/integration-api/`, `cmd/integration-api`). Pick the target first; see `kairos-create-api-endpoint` § *Step 0 — pick the target runtime* for the full path mapping and how to choose. **If the user didn't say which, ask.**

The template below uses the client-API paths. For an integration-API endpoint, substitute `internal/api/endpoints/v1/` → `internal/integration-api/endpoints/v1/` and `internal/api/request` → `internal/integration-api/request`, and register in `internal/integration-api/routes.go`.

## Pagination layout

Where `PaginationFilter`, `Pagination` and `PaginatedResponse[T]` live depends on the component:

| `internal/domain/pagination.go` and `internal/dto/pagination.go` | Follow |
|---|---|
| both exist | [§ New layout](#new-layout): the template below as written |
| both missing | [§ Old layout](#old-layout) |
| only one exists | The move is half-done. Stop and ask the author to finish it. |

On either layout, don't create a DTO package per runtime (`internal/integration-api/dto/`).

### New layout

- `PaginationFilter` is `domain.PaginationFilter`.
- `Pagination` and `PaginatedResponse[T]` come from `internal/dto`, which both runtimes import.
- **Client API:** the response DTO and its converter live in `internal/api/dto`. Both packages are named `dto`, so the template aliases `internal/dto` as `shareddto`.
- **Integration API:** never import `internal/api/dto` (entry layers don't import each other). Import `internal/dto` without an alias. Declare the response DTO and its converter in `internal/dto` if both runtimes return it, otherwise in the handler package. Then drop the `dto.` / `shareddto.` qualifiers that no longer apply.

### Old layout

All three types live in the client API's `internal/api/dto`, and both runtimes import it. In the template:

- drop the `internal/domain` and `shareddto` imports;
- write `dto.PaginationFilter` and `dto.PaginatedResponse[...]`, including in the `@Success` annotation.

The template upgrade-file `20261019T104600-pagination-types-moved.md` (`kairos-component-update`) moves the types. Don't move them inside this task.

## Prerequisites

- Service exposes `GetAllExamples(ctx, filter PaginationFilter) ([]domain.X, Pagination, error)` or equivalent, with the types from the layout above (`kairos-create-service`).
- Response DTO + conversion function exist, e.g. `dto.NewExampleModelResponse(domain.ExampleModel) dto.ExampleModelResponse`.

## Template

```go
package endpoints

import (
	"errors"

	"github.com/gofiber/fiber/v2"

	commonapi "bitbucket.org/ifs-pd/kairos-component-common/api"
	apierrors "bitbucket.org/ifs-pd/kairos-component-common/api/errors"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/api/dto"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/api/request"
	"bitbucket.org/ifs-pd/kairos-component-template/internal/domain"
	shareddto "bitbucket.org/ifs-pd/kairos-component-template/internal/dto"
)

var _ = apierrors.ErrRequestErrorResponse{} // keep failure schema visible to swag --parseDependency

// errInternal is the only error text a 5xx response carries; the real error is logged.
var errInternal = errors.New("internal error")

const (
	defaultPageSize = 10
	maxPageSize     = 100
)

// GetAllExamples handles GET /api/v1/example
//
// @Summary      List examples
// @Tags         example
// @Produce      json
// @Param        page   query  int  false  "Page number (1-based)"  default(1)
// @Param        limit  query  int  false  "Page size"  default(10)  maximum(100)
// @Success      200    {object}  commonapi.ResponseBody{data=shareddto.PaginatedResponse[dto.ExampleModelResponse]}
// @Failure      500    {object}  apierrors.ErrRequestErrorResponse
// @Router       /v1/example [get]
// @Security     BearerAuth
func GetAllExamples(ctx request.Context) error {
	logger := ctx.Logger()

	db, err := ctx.DatabaseSession()
	if err != nil {
		logger.Error().Err(err).Msg("Failed to get database session")
		return ctx.ErrorResponse(fiber.StatusInternalServerError, "Failed to get database session", errInternal)
	}
	defer db.Close()

	service := ctx.ServicesFactory().CreateExampleService(ctx, db)

	// Query params come from the embedded *fiber.Ctx. Clamp, then compute Skip:
	// the repository pages with OFFSET Skip, so a filter without it returns page 1.
	page := ctx.QueryInt("page", 1)
	limit := ctx.QueryInt("limit", defaultPageSize)
	if page < 1 {
		page = 1
	}
	if limit < 1 {
		limit = defaultPageSize
	}
	if limit > maxPageSize {
		limit = maxPageSize
	}
	filter := domain.PaginationFilter{
		Page:  int64(page),
		Limit: int64(limit),
		Skip:  int64((page - 1) * limit),
	}

	results, pagination, err := service.GetAllExamples(ctx.Context(), filter)
	if err != nil {
		logger.Error().Err(err).Msg("Failed to get all examples")
		return ctx.ErrorResponse(fiber.StatusInternalServerError, "Failed to get all examples", errInternal)
	}

	responseList := make([]dto.ExampleModelResponse, len(results))
	for i, example := range results {
		responseList[i] = dto.NewExampleModelResponse(example)
	}

	response := shareddto.PaginatedResponse[dto.ExampleModelResponse]{
		Data:       responseList,
		Pagination: pagination,
	}

	return ctx.SuccessResponse(response, "Examples retrieved successfully")
}
```

`ctx.SuccessResponse` and `ctx.ErrorResponse` exist on `kairos-component-common/api` ≥ v1.2.37 in `go.mod`. Below that, write `commonapi.SuccessResponse(ctx, …)` and `commonapi.ErrorResponse(ctx, …)`; the handler file then uses its `commonapi` import without the `var _ = commonapi.ResponseBody{}` guard. See `kairos-create-api-endpoint` § *Request and response helpers*.

## Response envelope

`PaginatedResponse[T]` wraps the slice with pagination metadata:

```json
{
  "success": true,
  "message": "Examples retrieved successfully",
  "data": {
    "data": [...],
    "pagination": {
      "page": 1,
      "limit": 10,
      "total": 42
    }
  }
}
```

## Filter parsing

Read `page` and `limit` with `ctx.QueryInt(key, default)` (a non-numeric value returns the default). Never use `ctx.ParseBody[T]()` or `commonapi.RequestBody[T]` for a GET: they parse the body, not the query string. Clamp both values and set `Skip = (page-1)*limit`, as the template does. If the endpoint sorts, set `Sort` / `SortOrder` from an allow-list of field names, never from the raw query string.

On a 5xx path, log the full error and pass `errInternal` to `ErrorResponse`, never the raw error (it reaches the caller) and never `nil` (it panics). See `kairos-create-api-endpoint`.

## Required elements checklist

- [ ] Service method returns `([]domain.X, Pagination, error)`
- [ ] DTO conversion loop populates a `[]dto.XResponse`
- [ ] `PaginatedResponse[T]` used as the response envelope
- [ ] `page` / `limit` read with `ctx.QueryInt`, clamped (default + maximum page size), and `Skip` set
- [ ] Swag annotations: `@Param page/limit query`, `@Success 200 {object} commonapi.ResponseBody{data=<pkg>.PaginatedResponse[...]}`, `@Failure`, `@Router`
- [ ] Registered in the target runtime's `routes.go` (`internal/api/` or `internal/integration-api/`) via `api.Handler(...)`
- [ ] Pagination types imported per [§ Pagination layout](#pagination-layout): `internal/domain` + `internal/dto` on the new layout, `internal/api/dto` on the old one, whichever runtime hosts the endpoint

## Common mistakes (RED FLAGS)

- Returning the raw `[]domain.X` — always go through the DTO.
- Duplicating `PaginationFilter` / `PaginatedResponse[T]` into an `internal/integration-api/dto` package instead of importing the existing one (§ Pagination layout).
- On the new layout, importing `internal/api/dto` from an integration-API endpoint.
- No maximum `limit` → unbounded query.
- `Skip` left at zero → every page returns the first page.
- Parsing query params with `ctx.ParseBody[T]()` / `commonapi.RequestBody[T]`.
- Computing `total` with a separate unindexed `COUNT(*)` — prefer window-function counts where performance matters.
- Different pagination shape than `PaginatedResponse[T]`.
