# Client API

A REST API service that provides endpoints for clients and external integrations within the component.

## Overview

The client API is built on the Go Fiber framework and serves as the primary interface for external clients. It handles HTTP requests, validates input, executes business logic through services, and can send commands to the event system.

## Request Flow

```
HTTP Request
    ↓
Middleware Stack (authentication, tenant resolution, transaction, etc.)
    ↓
Endpoint Handler (validates input, calls services)
    ↓
ServicesFactory (creates services with dependencies)
    ↓
Service Layer (business logic, database operations)
    ↓
Response (success/error)
```

## Endpoint Function Signature

All API endpoints must implement this signature:

```go
func EndpointName(ctx request.Context) error
```

Return `nil` for successful processing or use the `api` package helpers for responses.

## Request Context

The `request.Context` is a type alias that provides access to all request-scoped dependencies:

```go
type Context = apicontext.Context[ServicesFactory, config.AppConfig]
```

### Available Methods

**Core Dependencies:**
- `ctx.DatabaseSession()`: PostgreSQL database session (tenant-scoped, returns error)
- `ctx.TenantSchema()`: PostgreSQL schema name for tenant
- `ctx.PublicSchema()`: PostgreSQL public schema name
- `ctx.Logger()`: Structured logger (zerolog)
- `ctx.Config()`: Application configuration
- `ctx.Context()`: Standard Go context for timeouts/cancellation
- `ctx.ServicesFactory()`: Factory for creating domain services

**Messaging:**
- `ctx.Sender()`: Publish events or send commands

**Tracing & Monitoring:**
- `ctx.Tracer()`: OpenTelemetry tracer for distributed tracing

**Tenant & Request Info:**
- `ctx.TenantId()`: Current tenant ID
- `ctx.ComponentName()`: Component name
- `ctx.CorrelationId()`: Request correlation ID

**HTTP Utilities:**
- `ctx.Params(key)`: Path parameters
- `ctx.Query(key, defaultValue)`: Query parameters
- `ctx.QueryInt(key, defaultValue)`: Query parameters as integers

## ServicesFactory Pattern

The `ServicesFactory` creates domain services with the right dependencies injected from the request context. Each service gets one factory method that takes the request context and the (already tenant-scoped) database session, builds the matching repository, and returns the service.

**Location:** `internal/api/request/services_factory.go`

```go
type ServicesFactory struct{}

func (f ServicesFactory) CreateOrderService(
    ctx Context,
    session interfaces.Session,
) *services.OrderService {
    tableName := ctx.Config().GetOrderTableName()
    repo := repositories.NewOrderRepository(session, tableName)
    return services.NewOrderService(repo, ctx.Logger())
}
```

The example above uses a hypothetical `Order` aggregate purely as a placeholder. For the actual procedure for adding a service and wiring it through the factory, invoke the `kairos-create-service` skill — the factory has a mirrored copy in `internal/event-handler/request/services_factory.go` that must stay in sync, and the skill enforces that.

## Middleware Stack

The API comes pre-configured with middleware from `kairos-component-common/api`:

1. **Authentication**: JWT validation and user context
2. **Tenant Resolution**: Extracts and validates tenant information
3. **Correlation ID**: Tracks requests across services
4. **Transaction Management**: PostgreSQL transaction boundaries
5. **Logging**: Request/response logging with structured data
6. **Tracing**: OpenTelemetry distributed tracing
7. **Error Handling**: Standardized error responses
8. **CORS**: Cross-origin resource sharing

## Response Helpers

The `commonapi` package (aliased from `kairos-component-common/api`) provides standardized response functions:

```go
commonapi.SuccessResponse(ctx, data, "Success message")
commonapi.EmptySuccessResponse(ctx, "Success message")
commonapi.ErrorResponse(ctx, fiber.StatusCode, "Error message", err)
```

## Endpoint Shapes

Two shapes cover the vast majority of API endpoints. Both use a hypothetical `Order` aggregate below — the skills listed are authoritative on how to actually implement them.

### Synchronous (direct database operation)

The endpoint validates the request, gets a database session, calls a service via the `ServicesFactory`, and returns the result. The transaction is owned by middleware.

```go
func CreateOrder(ctx request.Context) error {
    req, err := commonapi.RequestBody[dto.CreateOrderRequest](ctx)
    if err != nil {
        return err
    }

    db, err := ctx.DatabaseSession()
    if err != nil {
        return commonapi.ErrorResponse(ctx, fiber.StatusInternalServerError, "Failed to get database session", err)
    }
    defer db.Close()

    service := ctx.ServicesFactory().CreateOrderService(ctx, db)

    result, err := service.Create(ctx.Context(), req.ToDomain())
    if err != nil {
        return commonapi.ErrorResponse(ctx, fiber.StatusInternalServerError, "Failed to create order", err)
    }

    return commonapi.SuccessResponse(ctx, result, "Order created")
}
```

For paginated list endpoints, see the `kairos-create-paginated-endpoint` skill — pagination uses the standard `domain.PaginationFilter` (`internal/domain`) and `dto.PaginatedResponse[T]` (`internal/dto`) wrappers.

### Asynchronous (send a command)

The endpoint accepts the request, builds a typed `*CommandV1` from `pkg/schema/`, and dispatches it via `ctx.Sender().Send(...)`. The work is performed by a command handler in the event-handler runtime.

```go
func CreateOrderAsync(ctx request.Context) error {
    req, err := commonapi.RequestBody[dto.CreateOrderRequest](ctx)
    if err != nil {
        return err
    }

    cmd := commands.New(req.PartitionKey(), &schema.CreateOrderCommandV1{
        OrderNumber: req.OrderNumber,
    })

    if _, err := ctx.Sender().Send(cmd); err != nil {
        return err
    }

    return commonapi.EmptySuccessResponse(ctx, "Command sent")
}
```

For the rules around `Send` vs `Publish` vs `SendCommandResponse`, partition-key choice, and the double-validation contract, see the `kairos-messaging-model` reference skill and the `kairos-send-command` task skill.

## Key Concepts

### Tenant Isolation
All database operations are automatically scoped to the tenant from the request context. The PostgreSQL session is pre-configured with the correct schema.

### Transaction Management
Database transactions are managed by middleware. All operations within an endpoint execute in the same transaction, which commits on success or rolls back on error.

### Error Handling
Return errors from endpoints and let the framework handle the response formatting. Use specific HTTP status codes for different error types.
