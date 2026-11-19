# Event Handler

An API that is invoked by the sidecar event adapter to react to CloudEvents.

## Overview

The event handler processes CloudEvents from Kafka, executes business logic through services, and can publish new events or send commands. It uses standard Go error handling.

## Processing Flow

```
CloudEvent (Kafka)
    ↓
Event Adapter Sidecar
    ↓
HTTP POST to Event Handler
    ↓
Middleware Stack (correlation, tenant resolution, idempotency, etc.)
    ↓
Handler Routing (based on CloudEvent type)
    ↓
Typed Handler (command or event handler)
    ↓
ServicesFactory (creates services with dependencies)
    ↓
Service Layer (business logic, database operations)
    ↓
Publish Events/Send Commands (optional)
    ↓
HTTP Response (200 OK or 500 Error)
```

## Handler Function Signatures

### Command Handler (fire-and-forget)
```go
func HandlerName(
    command *schema.CommandType,
    ctx request.Context,
) (eventhandler.NilCommandResponse, error)
```

### Command Handler (with response)
```go
func HandlerName(
    command *schema.CommandType,
    ctx request.Context,
) (*schema.CommandResponseType, error)
```

### Event Handler
```go
func HandlerName(
    event *schema.EventType,
    ctx request.Context,
) error
```

Return `nil` error for success or a non-nil `error` for failures (results in HTTP 500).

## Handler Registration

Handlers are registered in `internal/event-handler/handlers.go`. Each `Add` call wraps a typed handler function in the matching `eventhandler.*Handler(...)` wrapper so the framework can route incoming CloudEvents by type.

```go
eh.Add(
    eventhandler.CommandHandler(commands.CreateOrderCommand),
    eventhandler.EventHandler(events.OrderCreatedEvent),
)
```

Forgetting to register a handler here is the most common reason an incoming message appears to be ignored. After adding or removing entries, run `make generate` so `chart/resources/topic-config.json` is rewritten with the right subscriptions — see the `kairos-sql-lifecycle` reference skill.

## Request Context

The `request.Context` is a type alias that provides access to all request-scoped dependencies:

```go
type Context = ehcontext.Context[ServicesFactory, config.AppConfig]
```

### Available Methods

**Core Dependencies:**
- `ctx.DatabaseSession()`: PostgreSQL database session (tenant-scoped, may be nil)
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

**Event & Request Info:**
- `ctx.TenantId()`: Current tenant ID
- `ctx.ComponentName()`: Component name
- `ctx.CorrelationId()`: Request correlation ID
- `ctx.PartitionKey()`: Partition key from the CloudEvent

## ServicesFactory Pattern

The `ServicesFactory` creates domain services with the right dependencies injected from the request context. Each service gets one factory method that takes the request context and the (already tenant-scoped) database session, builds the matching repository, and returns the service.

**Location:** `internal/event-handler/request/services_factory.go`

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

The example above uses a hypothetical `Order` aggregate purely as a placeholder. The factory has a mirrored copy in `internal/api/request/services_factory.go`; both must stay in sync. Use the `kairos-create-service` skill — it enforces the two-mirror rule.

**Important:** unlike the API variant, `ctx.DatabaseSession()` here returns a value with no error — the handler is responsible for nil-checking it before passing it to the factory method.

## Middleware Stack

The event handler comes pre-configured with middleware from `kairos-component-common/event-handler`:

1. **Correlation ID**: Extracts correlation ID from CloudEvent extension
2. **Tenant Resolution**: Extracts and validates tenant information
3. **Command/Event Routing**: Routes to appropriate handler based on CloudEvent type
4. **Idempotency**: Prevents duplicate message processing
5. **Transaction Management**: PostgreSQL transaction boundaries
6. **Logging**: Request/response logging with structured data
7. **Tracing**: OpenTelemetry distributed tracing

## Message Schema

All commands and events are defined in `pkg/schema/` and implement interfaces from `kairos-component-common/common/messaging`.

**Key requirements:**
- Implement `Validate(ctx context.Context) error`
- Implement `ComponentName() string`
- Use `nga-common/validation` for field validation

## Sending Messages

The three send methods are not interchangeable. The `kairos-messaging-model` reference skill is the source of truth on which to use; the table below is a cheatsheet only.

### Events (broadcast a fact, past tense)
```go
event := events.New(partitionKey, &schema.OrderCreatedEventV1{...})
err := ctx.Sender().Publish(event)
```

### Commands (directed request, imperative)
```go
cmd := commands.New(partitionKey, &schema.CreateOrderCommandV1{...})
_, err := ctx.Sender().Send(cmd)
```

### Command responses (reply to an incoming command you handled)
```go
response := commands.NewResponse(partitionKey, &schema.CreateOrderCommandResponseV1{...})
err := ctx.Sender().SendCommandResponse(response)
```

For the partition-key contract and ordering guarantees, see `kairos-messaging-model`. For the full task workflow of adding each kind of message, see `kairos-create-event`, `kairos-create-command`, `kairos-create-command-response`, and the matching publish/send skills.

## Handler Shapes

Two shapes cover the vast majority of event-handler entries. Both use a hypothetical `Order` aggregate below — invoke the listed skills for the actual procedures.

### Command handler that publishes a follow-up event

```go
func CreateOrderCommand(
    command *schema.CreateOrderCommandV1,
    ctx request.Context,
) (eventhandler.NilCommandResponse, error) {
    db := ctx.DatabaseSession()
    if db == nil {
        return nil, fmt.Errorf("failed to get database session")
    }

    orderService := ctx.ServicesFactory().CreateOrderService(ctx, db)

    result, err := orderService.Create(ctx.Context(), command.ToDomain())
    if err != nil {
        return nil, fmt.Errorf("failed to create order: %w", err)
    }

    event := events.New(result.Id.String(), &schema.OrderCreatedEventV1{
        OrderId:     result.Id.String(),
        OrderNumber: result.OrderNumber,
    })
    if err := ctx.Sender().Publish(event); err != nil {
        return nil, fmt.Errorf("failed to publish event: %w", err)
    }

    return nil, nil
}
```

For command handlers that return a typed response instead of `NilCommandResponse`, see `kairos-create-command-response` (defining the response schema) and `kairos-create-command` (returning it from the handler).

### Event handler reacting to another component's event

```go
func OrderShippedEvent(event *schema.OrderShippedEventV1, ctx request.Context) error {
    ctx.Logger().Info().
        Str("orderId", event.OrderId).
        Msg("processing OrderShipped")

    return nil
}
```

When the event being consumed comes from another Kairos component, see `kairos-cross-component-integration` and `kairos-create-event-handler` — they cover importing the other component's `pkg/schema/`, registering the handler, and regenerating `topic-config.json` so the subscription is actually wired.

## Key Concepts

### Tenant Isolation
All database operations are automatically scoped to the tenant from the CloudEvent context. The PostgreSQL session is pre-configured with the correct schema.

### Idempotency
The middleware tracks processed CloudEvent IDs to prevent duplicate processing. Handlers should be idempotent when possible.

### Transaction Management
Database transactions are managed by middleware. All operations within a handler execute in the same transaction, which commits on success or rolls back on error.

### Error Handling
Return errors from handlers and let the framework handle logging and HTTP responses. The event adapter will retry failed messages based on Kafka configuration.
