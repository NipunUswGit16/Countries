# Migration Guide: Component Architecture Update

This document explains the architectural changes introduced in the new component architecture and how to migrate existing code. This applies to any project based on the kairos-component-template.

## Overview

The new architecture introduces several key improvements:

- **Terminology Change**: "Bounded Context" terminology replaced with "Component"
- **Unified Context Pattern**: Single context type for both API and Event Handler with all dependencies
- **Services Factory Pattern**: Factory-based dependency injection replacing service registration functions
- **Strongly-Typed Messaging**: Type-safe command and event schemas replacing map-based payloads
- **Simplified Initialization**: Streamlined component setup with fewer parameters
- **Helper Functions**: Convenience functions for common patterns (request parsing, responses)

---

## Terminology: Bounded Context → Component

**What Changed:** All references to "bounded context" or "BC" have been renamed to "component".

**Before:**
```go
const boundedContextName = "countries"
const serviceId = boundedContextName + "_CLIENT_API"
```

**After:**
```go
const componentName = "countries"
const serviceId = componentName + "_CLIENT_API"
```

**Migration:** Search and replace "boundedContext" → "component" and "BC" → "COMPONENT" in constant names.

---

## Dependencies

**What Changed:** New messaging library added to common module.

**Required Additions to go.mod:**
```go
require (
    bitbucket.org/ifs-pd/kairos-component-common/common v0.0.0-00010101000000-000000000000
    bitbucket.org/ifs-pd/nga-common/validation v0.0.2
)
```

Run `go mod tidy` after adding.

---

## Client API Initialization

**What Changed:**
- Simplified initialization signature
- Services factory passed as parameter
- Removed explicit shutdown call

**Before:**
```go
import (
    commonapi "bitbucket.org/ifs-pd/kairos-component-common/api"
    "your-project/internal/api/config"
)

func main() {
    apiInstance, _ := commonapi.New[config.AppConfig](
        boundedContextName,
        serviceId,
        commonapi.ClientAPI,
        nil,
    )
    defer apiInstance.Shutdown()
    router := apiInstance.ApiRouter()

    // Register routes
    api.InitRoutes(router)

    apiInstance.Start() // blocking call
    apiInstance.Logger().Info().Msg("app stopped")
}
```

**After:**
```go
import (
    commonapi "bitbucket.org/ifs-pd/kairos-component-common/api"
    "your-project/internal/api/config"
    "your-project/internal/api/request"
)

func main() {
    apiInstance, _ := commonapi.New[request.ServicesFactory, config.AppConfig](
        serviceId,
        &request.ServicesFactory{},
    )
    router := apiInstance.ApiRouter()

    // Register routes
    api.InitRoutes(router)

    apiInstance.Start() // blocking call
    apiInstance.Logger().Info().Msg("app stopped")
}
```

**Key Changes:**
- Add `ServicesFactory` type parameter
- Remove `boundedContextName` and `commonapi.ClientAPI` parameters
- Pass factory instance: `&request.ServicesFactory{}`
- Remove explicit `defer apiInstance.Shutdown()` (handled internally)

---

## Event Handler Initialization

**What Changed:**
- Simplified initialization using `New()` instead of `NewEventHandler()`
- Handler registration using `Add()` with `Handler()` wrapper
- Removed explicit shutdown

**Before:**
```go
import (
    eventhandler "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
    "your-project/internal/event-handler/commands"
    "your-project/internal/event-handler/config"
    "your-project/internal/event-handler/events"
)

func main() {
    eventHandler := eventhandler.NewEventHandler[config.AppConfig, *config.AppConfig](
        boundedContextName,
        serviceId,
        nil,
    )
    defer eventHandler.Shutdown()

    eventHandler.RegisterCommand("order.create", commands.CreateOrderCommand)
    eventHandler.RegisterEvent("order.created", events.OrderCreatedEvent)

    eventHandler.Start() // blocking call
    eventHandler.Logger().Info().Msg("app stopped")
}
```

**After:**
```go
import (
    eventhandler "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
    "your-project/internal/event-handler/commands"
    "your-project/internal/event-handler/config"
    "your-project/internal/event-handler/events"
    "your-project/internal/event-handler/request"
)

func main() {
    eventHandler := eventhandler.New[request.ServicesFactory, config.AppConfig](
        serviceId,
        &request.ServicesFactory{},
    )

    eventHandler.Add(eventhandler.CommandHandler(commands.CreateOrderCommand))
    eventHandler.Add(eventhandler.EventHandler(events.OrderCreatedEvent))

    eventHandler.Start() // blocking call
    eventHandler.Logger().Info().Msg("app stopped")
}
```

**Key Changes:**
- `NewEventHandler()` → `New()`
- Add `ServicesFactory` type parameter
- Remove `boundedContextName` parameter
- `RegisterCommand()`/`RegisterEvent()` → `Add(eventhandler.CommandHandler())` / `Add(eventhandler.EventHandler())`
- Remove explicit `defer eventHandler.Shutdown()`

---

## Request Context Abstraction

**What Changed:** Introduced unified context type that provides access to all request-scoped dependencies.

### For API

**Create: `internal/api/request/context.go`**
```go
package request

import (
    apicontext "bitbucket.org/ifs-pd/kairos-component-common/api/context"
    "your-project/internal/api/config"
)

// Context is an alias to the API request context.
type Context = apicontext.Context[ServicesFactory, config.AppConfig]
```

### For Event Handler

**Create: `internal/event-handler/request/context.go`**
```go
package request

import (
    ehcontext "bitbucket.org/ifs-pd/kairos-component-common/event-handler/context"
    "your-project/internal/event-handler/config"
)

// Context is an alias to the event handler request context.
type Context = ehcontext.Context[ServicesFactory, config.AppConfig]
```

**Purpose:** This type alias provides a strongly-typed context specific to your project, giving access to configuration, services factory, logger, database, tracer, sender, etc.

---

## Services Factory Pattern

**What Changed:** Replaced package-level service registration functions with a factory struct with methods. Factory receives context and extracts dependencies from it.

### For API: `internal/api/request/services_factory.go`

**Before (old serviceregistrations approach):**
```go
package serviceregistrations

import (
    "your-project/internal/api/config"
    "your-project/internal/services"
    "bitbucket.org/ifs-pd/nga-common/logging"
    imongo "bitbucket.org/ifs-pd/nga-common/mongo/testable/interfaces"
)

func CreateOrderService(
    database imongo.Database,
    appConfig *config.AppConfig,
    logger logging.Logger,
) *services.OrderService {
    orderCollectionName := appConfig.GetOrderCollectionName()
    orderCollection := database.Collection(orderCollectionName)
    return services.NewOrderService(orderCollection, logger)
}

func CreateSenderService(
    sender eventSenderInterface.EventSender,
    appConfig *config.AppConfig,
    logger logging.Logger,
) *services.EventSenderService {
    return services.NewEventSenderService(sender, logger)
}
```

**After:**
```go
package request

import (
    "your-project/internal/repositories"
    "your-project/internal/services"
    "bitbucket.org/ifs-pd/nga-common/postgres/client/interfaces"
)

type ServicesFactory struct{}

func (f ServicesFactory) CreateOrderService(
    ctx Context,
    session interfaces.Session,
) *services.OrderService {
    tableName := ctx.Config().GetOrderTableName()
    repo := repositories.NewOrderRepository(session, tableName)
    return services.NewOrderService(repo, ctx.Logger())
}

// Add more service creation methods as needed
```

### For Event Handler: `internal/event-handler/request/services_factory.go`

**After:**
```go
package request

import (
    "your-project/internal/repositories"
    "your-project/internal/services"
    "bitbucket.org/ifs-pd/nga-common/postgres/client/interfaces"
)

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

**Key Changes:**
- Package functions → struct methods
- Multiple parameters → `Context` + `interfaces.Session` parameters
- Extract dependencies from context: `ctx.Config()`, `ctx.Logger()`
- Factory creates repository with session and table name, passes to service constructor
- Remove `CreateSenderService` - use `ctx.Sender()` directly

---

## Removing EventSenderService

**What Changed:** The sender service wrapper is no longer needed. Access sender directly through context.

**Action:** Delete these files if they exist:
- `internal/services/sender.go`
- `internal/services/sender_test.go`

**Old Pattern (now removed):**
```go
type EventSenderService struct {
    sender interfaces.EventSender
    logger logging.Logger
}

func (s *EventSenderService) SendEvent(ctx context.Context, event EventRequest) error {
    // ... wrapper logic
}
```

**New Pattern:**
```go
// Just use the sender directly from context
ctx.Sender().Send(message)
```

---

## Typed Message Schemas

**What Changed:** Commands and events are now strongly-typed structs instead of maps with string keys.

### Create Schema Package Constants

**Create: `pkg/schema/globals.go`**
```go
package schema

const ComponentName = "countries"
```

### Command Schema Example

**Create: `pkg/schema/your-command-v1.go`**
```go
package schema

import (
    "context"
    "bitbucket.org/ifs-pd/kairos-component-common/common/messaging/commands"
    "bitbucket.org/ifs-pd/nga-common/validation"
    "bitbucket.org/ifs-pd/nga-common/validation/check"
    "bitbucket.org/ifs-pd/nga-common/validation/runner"
)

var _ messaging.Command = (*commands.CommandMessage[*YourCommandV1])(nil)
var _ messaging.MessagePayload = &YourCommandV1{}

// YourCommandV1 represents your command payload
type YourCommandV1 struct {
    Field1 string   `json:"field1"`
    Field2 int      `json:"field2"`
}

var yourValidator = validation.New(func(c *YourCommandV1, r *runner.Runner[*YourCommandV1]) {
    check.StringField(r, "Field1", c.Field1).
        NotEmpty("field1 cannot be empty")
})

// Validate validates the command
func (c *YourCommandV1) Validate(ctx context.Context) error {
    return messaging.Validate(ctx, yourValidator, c)
}

// ComponentName returns the component name
func (c *YourCommandV1) ComponentName() string {
    return ComponentName
}
```

### Event Schema Example

**Create: `pkg/schema/your-event-v1.go`**
```go
package schema

import (
    "context"
    "time"
    "bitbucket.org/ifs-pd/kairos-component-common/common/messaging/events"
    "bitbucket.org/ifs-pd/nga-common/validation"
    "bitbucket.org/ifs-pd/nga-common/validation/check"
    "bitbucket.org/ifs-pd/nga-common/validation/runner"
)

var _ messaging.Event = (*events.EventMessage[*YourEventV1])(nil)
var _ messaging.MessagePayload = &YourEventV1{}

// YourEventV1 represents your event payload
type YourEventV1 struct {
    Field1    string    `json:"field1"`
    Field2    int       `json:"field2"`
    CreatedAt time.Time `json:"createdAt"`
}

var yourEventValidator = validation.New(func(e *YourEventV1, r *runner.Runner[*YourEventV1]) {
    check.StringField(r, "Field1", e.Field1).
        NotEmpty("field1 cannot be empty")
})

// Validate validates the event
func (e *YourEventV1) Validate(ctx context.Context) error {
    return messaging.Validate(ctx, yourEventValidator, e)
}

// ComponentName returns the component name
func (e *YourEventV1) ComponentName() string {
    return ComponentName
}
```

**Schema Patterns:**
- Commands and events are plain structs (no embedded base types)
- Implement `messaging.MessagePayload` interface with `Validate()` and `ComponentName()` methods
- Use type assertions to ensure the wrapper types implement the correct interfaces
- Create messages using `commands.New(partitionKey, payload)` or `events.New(partitionKey, payload)`
- Implement `Validate()` method using the validation library
- Implement `ComponentName()` to return your component constant

---

## API Endpoints

**What Changed:**
- Handler signature: `func(*fiber.Ctx)` → `func(request.Context)`
- Use helper functions for parsing and responses
- Access dependencies through context

**Before:**
```go
package endpoints

import (
    "context"
    "time"
    commonapi "bitbucket.org/ifs-pd/kairos-component-common/api"
    "your-project/internal/api/config"
    "your-project/internal/api/serviceregistrations"
    "your-project/internal/dto"
    "github.com/gofiber/fiber/v2"
)

func CreateModel(c *fiber.Ctx) error {
    logger := commonapi.GetRequestLogger(c)
    database := commonapi.GetRequestDatabaseWithTenant(c)
    appConfig := commonapi.GetConfig[config.AppConfig](c)

    orderService := serviceregistrations.CreateOrderService(database, appConfig, logger)

    var req dto.ModelCreateRequest
    if err := c.BodyParser(&req); err != nil {
        logger.Error().Err(err).Msg("Failed to parse request body")
        return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
            "success": false,
            "message": "Invalid request body",
            "error":   err.Error(),
        })
    }

    if err := req.Validate(); err != nil {
        logger.Error().Err(err).Msg("Failed to validate request body")
        return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
            "success": false,
            "message": "Failed to validate request body",
            "error":   err.Error(),
        })
    }

    ctx, cancel := context.WithTimeout(c.UserContext(), 10*time.Second)
    defer cancel()

    model := req.ToDomain()
    created, err := orderService.Create(ctx, model)
    if err != nil {
        logger.Error().Err(err).Msg("Failed to create model")
        return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
            "success": false,
            "message": "Failed to create model",
            "error":   err.Error(),
        })
    }

    response := dto.NewModelResponse(created)
    return c.Status(fiber.StatusCreated).JSON(fiber.Map{
        "success": true,
        "message": "Model created successfully",
        "data":    response,
    })
}
```

**After:**
```go
package endpoints

import (
    "context"
    "time"
    "bitbucket.org/ifs-pd/kairos-component-common/api"
    "your-project/internal/api/request"
    "your-project/internal/api/dto"
    "github.com/gofiber/fiber/v2"
)

func CreateModel(ctx request.Context) error {
    logger := ctx.Logger()

    req, err := api.RequestBody[dto.ModelCreateRequest](ctx)
    if err != nil {
        return err
    }

    db, err := ctx.DatabaseSession()
    if err != nil {
        return api.ErrorResponse(ctx, fiber.StatusInternalServerError, "Failed to get database session", err)
    }
    defer db.Close()

    orderService := ctx.ServicesFactory().CreateOrderService(ctx, db)

    ctxTimeout, cancel := context.WithTimeout(ctx.Context(), 10*time.Second)
    defer cancel()

    model := req.ToDomain()
    created, err := orderService.Create(ctxTimeout, model)
    if err != nil {
        logger.Error().Err(err).Msg("Failed to create model")
        return api.ErrorResponse(ctx, fiber.StatusInternalServerError, "Failed to create model", err)
    }

    response := dto.NewModelResponse(created)
    return api.SuccessResponse(ctx, response, "Model created successfully")
}
```

**Key Changes:**
- Signature: `func(c *fiber.Ctx)` → `func(ctx request.Context)`
- Get dependencies from context: `ctx.Logger()`, `ctx.ServicesFactory()`, `ctx.Context()`
- Use `api.RequestBody[T]()` - handles parsing and validation automatically
- Use `api.SuccessResponse()` and `api.ErrorResponse()` instead of manual JSON
- No need to extract individual dependencies from fiber context

---

## Sending Commands/Events from Endpoints

**What Changed:** Use typed schemas with sender instead of map-based payloads with service wrapper.

**Before:**
```go
func SendCommand(c *fiber.Ctx) error {
    logger := commonapi.GetRequestLogger(c)
    sender := commonapi.GetRequestSender(c)
    appConfig := commonapi.GetConfig[config.AppConfig](c)

    var req dto.Request
    if err := c.BodyParser(&req); err != nil {
        // ... error handling
    }

    senderService := serviceregistrations.CreateSenderService(sender, appConfig, logger)

    request := services.EventRequest{
        PartitionKey: "key",
        EventType:    "component.action",
        Version:      1,
        Payload: map[string]interface{}{
            "field1": req.Field1,
            "field2": req.Field2,
        },
    }

    err := senderService.SendCommand(c.UserContext(), request)
    if err != nil {
        logger.Error().Err(err).Msg("Failed to send command")
        return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
            "success": false,
            "error":   err.Error(),
        })
    }

    return c.Status(fiber.StatusAccepted).JSON(fiber.Map{
        "success": true,
        "message": "Command sent successfully",
    })
}
```

**After:**
```go
func SendCommand(ctx request.Context) error {
    logger := ctx.Logger()

    req, err := api.RequestBody[dto.Request](ctx)
    if err != nil {
        return err
    }

    cmd := commands.New(
        "key",
        &schema.YourCommandV1{
            Field1: req.Field1,
            Field2: req.Field2,
        })

    _, err = ctx.Sender().Send(cmd)
    if err != nil {
        return err
    }

    return api.EmptySuccessResponse(ctx, "Command sent successfully")
}
```

**Key Changes:**
- Create typed command using schema constructor
- Use `ctx.Sender().Send(cmd)` directly (no service wrapper, returns `(string, error)`)
- Use `api.EmptySuccessResponse()` for 202 Accepted responses

---

## Command Handlers

**What Changed:** Handler receives typed command instead of raw CloudEvent. No manual unmarshaling or validation needed.

**Before:**
```go
package commands

import (
    "context"
    "encoding/json"
    "fmt"
    "bitbucket.org/ifs-pd/kairos-component-common/api"
    "your-project/internal/dto"
    "your-project/internal/event-handler/config"
    "your-project/internal/event-handler/serviceregistrations"
    "your-project/internal/services"
    "github.com/cloudevents/sdk-go/v2/event"
)

func HandleCreateCommand(
    event *event.Event,
    ctx *api.BcRequestCtx[config.AppConfig, *config.AppConfig],
) error {
    logger := ctx.Logger

    var req dto.Request
    if err := json.Unmarshal(event.Data(), &req); err != nil {
        logger.Error().Err(err).Msg("Failed to parse request body")
        return fmt.Errorf("failed to parse request body: %w", err)
    }

    if err := req.Validate(); err != nil {
        logger.Error().Err(err).Msg("Failed to validate request body")
        return fmt.Errorf("failed to validate request body: %w", err)
    }

    database := ctx.GetDatabaseWithTenant()
    if database == nil {
        logger.Error().Msg("Failed to get database")
        return fmt.Errorf("failed to get mongo client")
    }

    model := req.ToDomain()

    service := serviceregistrations.CreateService(database, ctx.Config, logger)

    ctxTimeout, cancel := context.WithTimeout(ctx.Context(), ctx.Config.DomainChangeTimeout)
    defer cancel()

    created, err := service.Create(ctxTimeout, model)
    if err != nil {
        logger.Error().Err(err).Msg("Failed to create")
        return fmt.Errorf("failed to create: %w", err)
    }

    senderService := serviceregistrations.CreateSenderService(ctx.Sender, ctx.Config, logger)

    request := services.EventRequest{
        PartitionKey: "key",
        EventType:    "model.created",
        Version:      1,
        Payload: map[string]interface{}{
            "id":         created.ID,
            "field1":     created.Field1,
            "created_at": created.CreatedAt,
        },
    }

    err = senderService.SendEvent(ctx.Context(), request)
    if err != nil {
        logger.Error().Err(err).Msg("Failed to send event")
        return fmt.Errorf("failed to send event: %w", err)
    }

    return nil
}
```

**After:**
```go
package commands

import (
    "context"
    "fmt"
    "bitbucket.org/ifs-pd/kairos-component-common/common/messaging/events"
    eventhandler "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
    "your-project/internal/domain"
    "your-project/internal/event-handler/request"
    "your-project/pkg/schema"
)

func HandleCreateCommand(
    command *schema.YourCommandV1,
    ctx request.Context,
) (eventhandler.NilCommandResponse, error) {
    logger := ctx.Logger()

    db := ctx.DatabaseSession()
    if db == nil {
        return nil, fmt.Errorf("failed to get database session")
    }

    model := domain.Model{
        Field1: command.Field1,
        Field2: command.Field2,
    }

    service := ctx.ServicesFactory().CreateService(ctx, db)

    ctxTimeout, cancel := context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)
    defer cancel()

    created, err := service.Create(ctxTimeout, model)
    if err != nil {
        logger.Error().Err(err).Msg("Failed to create")
        return nil, fmt.Errorf("failed to create: %w", err)
    }

    event := events.New(
        created.Id.String(),
        &schema.YourEventV1{
            Field1:    created.Field1,
            CreatedAt: created.CreatedAt,
        })

    err = ctx.Sender().Publish(event)
    if err != nil {
        logger.Error().Err(err).Msg("Failed to publish event")
        return nil, fmt.Errorf("failed to publish event: %w", err)
    }

    return nil, nil
}
```

**Key Changes:**
- Signature: Receive typed `*schema.YourCommandV1` instead of `*event.Event`
- Return `(eventhandler.NilCommandResponse, error)` instead of just `error`
- Receive typed `request.Context` instead of `*api.BcRequestCtx`
- No manual JSON unmarshaling - command is already typed
- No manual validation - handled by framework
- Access context methods: `ctx.Logger()`, `ctx.ServicesFactory()`, `ctx.Config()`
- Create typed event instead of map payload
- Use `ctx.Sender().Publish(event)` for events (use `Send(command)` for commands)

---

## Event Handlers

**What Changed:** Same pattern as command handlers - receive typed event.

**Before:**
```go
func HandleEvent(
    event *event.Event,
    ctx *api.BcRequestCtx[config.AppConfig, *config.AppConfig],
) error {
    logger := ctx.Logger

    var data YourEventData
    if err := json.Unmarshal(event.Data(), &data); err != nil {
        return fmt.Errorf("failed to unmarshal: %w", err)
    }

    // Process event using data...

    return nil
}
```

**After:**
```go
func HandleEvent(
    event *schema.YourEventV1,
    ctx request.Context,
) error {
    logger := ctx.Logger()

    // Process event directly using event.Field1, event.Field2, etc.
    logger.Info().Str("field1", event.Field1).Msg("Processing event")

    return nil
}
```

**Key Changes:**
- Receive typed event: `*schema.YourEventV1`
- No manual unmarshaling - event is already typed
- Access fields directly: `event.Field1`, `event.Field2`, etc.

---

## Route Registration

**What Changed:** All route handlers must be wrapped with `api.Handler()` to convert context.

**Before:**
```go
package api

import (
    "your-project/internal/api/endpoints/v1"
    "github.com/gofiber/fiber/v2"
)

func InitRoutes(router fiber.Router) {
    v1Group := router.Group("/v1")

    v1Group.Post("/models", endpoints.CreateModel)
    v1Group.Get("/models/:id", endpoints.GetModel)
    v1Group.Put("/models/:id", endpoints.UpdateModel)
    v1Group.Delete("/models/:id", endpoints.DeleteModel)
}
```

**After:**
```go
package api

import (
    "bitbucket.org/ifs-pd/kairos-component-common/api"
    "your-project/internal/api/endpoints/v1"
    "github.com/gofiber/fiber/v2"
)

func InitRoutes(router fiber.Router) {
    v1Group := router.Group("/v1")

    v1Group.Post("/models", api.Handler(endpoints.CreateModel))
    v1Group.Get("/models/:id", api.Handler(endpoints.GetModel))
    v1Group.Put("/models/:id", api.Handler(endpoints.UpdateModel))
    v1Group.Delete("/models/:id", api.Handler(endpoints.DeleteModel))
}
```

**Key Changes:**
- Import: `"bitbucket.org/ifs-pd/kairos-component-common/api"`
- Wrap each handler: `api.Handler(endpoints.YourHandler)`
- This adapter converts `fiber.Ctx` to strongly-typed `request.Context`

---

## Cleanup: Files to Remove

After migration, delete these old patterns:

- **Service Registrations:** `internal/api/serviceregistrations/` (entire package)
- **Service Registrations:** `internal/event-handler/serviceregistrations/` (entire package)
- **Sender Service:** `internal/services/sender.go` and `internal/services/sender_test.go`

---

## Context Methods Reference

The new `request.Context` provides unified access to dependencies:

### Configuration
```go
ctx.Config()                  // Get app config (*YourConfig)
```

### Database
```go
ctx.TenantSchema()            // Get tenant-specific schema
ctx.PublicSchema()               // Get public schema (not tenant specific)
```

### Logging & Tracing
```go
ctx.Logger()                  // Get request logger
ctx.Tracer()                  // Get OpenTelemetry tracer
ctx.Context()                 // Get Go context for tracing/cancellation
ctx.CorrelationId()           // Get request correlation ID
```

### Messaging
```go
ctx.Sender()                  // Get message sender (commands/events)
```

### Services & Metadata
```go
ctx.ServicesFactory()         // Get services factory (*YourServicesFactory)
ctx.ComponentName()           // Get component name
ctx.TenantId()                // Get tenant ID
```

### API Context Only (via embedded fiber.Ctx)
```go
ctx.GetToken()                   // Get JWT token
ctx.Params(key)                  // Get route parameter
ctx.Query(key)                   // Get query parameter
ctx.Status(code)                 // Set response status
// ... all fiber.Ctx methods available
```

---

## Entity Base Types (New Feature)

**What's New:** The common library now provides base types for domain entities with built-in support for optimistic concurrency control via ETags.

### Available Types

**EntityId** - UUID v7-based identifiers (monotonically increasing, time-sortable):
```go
type EntityId uuid.UUID

// Create new ID
id := entities.NewId()

// Parse from string
id, err := entities.ParseId("018c5c6e-9d4f-7b3a-9f2e-1a2b3c4d5e6f")

// Convert to string
idString := id.String()
```

**EntityETag** - XID-based tags for optimistic concurrency control:
```go
type EntityETag xid.ID

// Create new ETag
etag := entities.NewETag()

// Parse from string
etag, err := entities.ParseETag("c1234567890abcde")

// Convert to string
etagString := etag.String()
```

**EntityBase Struct:**
```go
type EntityBase struct {
    Id        EntityId    `json:"id"`
    ETag      EntityETag  `json:"etag"`
    CreatedAt time.Time   `json:"createdAt"`
    UpdatedAt time.Time   `json:"updatedAt"`
}

// Create new entity base
base := entities.NewEntityBase(entities.NewId(), entities.NewETag())

// Update ETag and UpdatedAt when modifying entity
base = base.ForUpdate()

// Access fields
id := base.Id
etag := base.ETag
```

### Usage Example

```go
package domain

import (
    "bitbucket.org/ifs-pd/kairos-component-common/common/entities"
)

// Order embeds EntityBase to get Id and ETag fields
type Order struct {
    entities.EntityBase[entities.EntityId] `json:",inline"`
    CustomerId  string  `json:"customerId"`
    TotalAmount float64 `json:"totalAmount"`
    Status      string  `json:"status"`
}

// Create a new order
func NewOrder(customerId string, totalAmount float64) *Order {
    return &Order{
        EntityBase:  entities.NewEntityBase(entities.NewId(), entities.NewETag()), // Auto-generates Id and ETag
        CustomerId:  customerId,
        TotalAmount: totalAmount,
        Status:      "pending",
    }
}

// Update an order
func (o *Order) Update(totalAmount float64) {
    o.EntityBase = o.EntityBase.ForUpdate() // Generates new ETag and updates UpdatedAt
    o.TotalAmount = totalAmount
}
```

### Migration from bson.ObjectID

**Before (using bson.ObjectID):**
```go
import "go.mongodb.org/mongo-driver/v2/bson"

type Order struct {
    ID   bson.ObjectID `json:"id" bson:"_id"`
    Name string        `json:"name" bson:"name"`
}

// Creating
order := Order{
    ID:   bson.NewObjectID(),
    Name: "ORD-001",
}

// Parsing ID from string
objectID, err := bson.ObjectIDFromHex(idString)
```

**After (using EntityBase):**
```go
import "bitbucket.org/ifs-pd/kairos-component-common/common/entities"

type Order struct {
    entities.EntityBase[entities.EntityId] `json:",inline"`
    Name string `json:"name"`
}

// Creating
order := Order{
    EntityBase: entities.NewEntityBase(entities.NewId(), entities.NewETag()),
    Name:       "ORD-001",
}

// Updating (with new ETag)
order.EntityBase = order.EntityBase.ForUpdate()
order.Name = "ORD-001-UPDATED"

// Parsing ID from string
id, err := entities.ParseId(idString)
```

**Benefits:**
- **Monotonically increasing IDs** - UUID v7 is time-ordered for better database performance
- **Built-in optimistic concurrency** - ETags prevent conflicting updates
- **Type safety** - Distinct types for ID vs ETag
- **JSONB compatible** - Works seamlessly with PostgreSQL JSONB storage

**Migration Steps:**
1. Replace old ID types with `entities.EntityBase[entities.EntityId]` embedding
2. Use `entities.NewEntityBase(entities.NewId(), entities.NewETag())` when creating new entities
3. Call `.ForUpdate()` before modifying entities
4. Replace old ID parsing with `entities.ParseId()`
5. Access ID via `.Id` field (e.g., `order.Id.String()`)

---

## Sender Interface Changes (Breaking Change)

**What Changed:** The sender interface has been split into two methods for clearer semantics:
- **`Publish(event Event)`** - For broadcasting events to subscribers
- **`Send(command Command)`** - For sending commands to specific components

### Before (Main Branch)
```go
// Single method for both events and commands
sender := ctx.Sender()
err := sender.Send(myMessage) // Generic for everything
```

### After (Current Version)
```go
sender := ctx.Sender()

// Use Publish for events (broadcast)
err := sender.Publish(myEvent)

// Use Send for commands (directed, returns messageId + error)
_, err := sender.Send(myCommand)
```

### Migration Steps

1. **Identify your message types:**
   - **Events**: Past tense, broadcast to multiple subscribers
     - Examples: `OrderCreatedEventV1`, `UserRegisteredEventV1`, `PaymentProcessedEventV1`
   - **Commands**: Imperative, directed to specific component
     - Examples: `CreateOrderCommandV1`, `ProcessPaymentCommandV1`

2. **Update sender calls:**

**Event Publishing:**
```go
event := events.New(
    order.Id.String(),
    &schema.OrderCreatedEventV1{
        OrderNumber: order.OrderNumber,
        CustomField: order.CustomField,
    })
err := ctx.Sender().Publish(event)
```

**Command Sending:**
```go
command := commands.New(
    partitionKey,
    &schema.CreateOrderCommandV1{
        OrderNumber: "ORD-001",
        CustomField: "value",
    })
_, err := ctx.Sender().Send(command)
```

3. **Update test code:**
```go
// Before
sentEvents := testCtx.FakeSender.GetSentEvents()

// After - both Publish() and Send() append to same list
sentMessages := testCtx.FakeSender.SentMessages()
```

**Benefits:**
- **Clearer intent** - Code explicitly shows whether broadcasting or directing
- **Better semantics** - Matches CQRS/event-driven architecture patterns
- **Easier to understand** - New developers immediately know the message purpose

**Migration:** This is required if you use the sender interface. Search your codebase for `sender.Send(` and replace with `Publish(` for events.

---

## Helper Functions

### Request Parsing (API)
```go
// Parses body and validates automatically
req, err := api.RequestBody[YourRequestType](ctx)
if err != nil {
    return err  // Returns proper error response automatically
}
```

### Response Helpers (API)
```go
// Success response with data
return api.SuccessResponse(ctx, data, "Success message")

// Error response
return api.ErrorResponse(ctx, fiber.StatusBadRequest, "Error message", err)

// Empty success (for 202 Accepted)
return api.EmptySuccessResponse(ctx, "Command sent successfully")
```

---

## Testing Your Migration

After completing the migration:

1. **Run tests:**
   ```bash
   go test ./...
   ```

2. **Build the application:**
   ```bash
   make build
   ```

3. **Verify API endpoints:**
   - Test request parsing and validation
   - Verify response formatting
   - Check error handling

4. **Verify event handlers:**
   - Test command processing
   - Verify event publishing
   - Check context propagation

---

## Benefits

The new architecture provides:

1. **Type Safety**: Strongly-typed commands and events prevent runtime errors
2. **Cleaner Code**: Less boilerplate, more readable
3. **Better Testability**: Factory pattern makes mocking easier
4. **Consistency**: Unified context handling across API and event handlers
5. **Better Validation**: Validation errors are clearer and consistent
6. **Simplified Dependencies**: Single context parameter instead of multiple parameters
7. **Framework Evolution**: Better aligned with common patterns across components

---

## Troubleshooting

### Issue: "Cannot find package request"
**Solution:** Ensure you've created `internal/api/request/context.go` and `services_factory.go` (and equivalent for event-handler)

### Issue: "Type mismatch in handler function"
**Solution:** Update handler signatures from `func(*fiber.Ctx)` to `func(request.Context)` and wrap routes with `api.Handler()`

### Issue: "Cannot use sender.Send with map"
**Solution:** Create typed schema structs in `pkg/schema/` instead of using maps

### Issue: "Missing GetServicesFactory method"
**Solution:** Ensure you're using the new context type, not the old one. Check your imports.

### Issue: "Validation not working"
**Solution:** Ensure your DTO `Validate()` methods are called. The new `api.RequestBody()` handles this automatically.
