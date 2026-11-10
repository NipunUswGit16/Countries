# Changelog

All notable changes to this component template.

## 10/27/2026

### Fixed

- Web: `web/configs/config.toml` served `env.js` as `public, max-age=2592000, immutable`, because the `**/*.{js,css,...}` rule matched it, though it is not fingerprinted and holds the runtime config. `index.html` got 1 day, and a missing asset that fell back to `index.html` got the immutable header too, so a browser could keep an old shell for a day and old config for a month. Now `Cache-Control: no-cache` is the default (`index.html`, `env.js`, `favicon.png`, SPA routes), and only an existing file under `assets/` named `<name>-<hash>.<ext>` is immutable. static-web-server's own cache headers are off (`cache-control-headers = false`). See `.kairos-updates/20261027T225500-web-cache-headers-revalidate-by-default.md`.

## 10/22/2026

### Fixed

- Integration API: `ENABLE_K8S_VALIDATION` is now set from the final service-account allowlist, including the dataloader's account. Before, with the dataloader enabled (the default) and `integration-api.k8sAllowedServiceAccounts` empty, the dataloader's account was in `K8S_ALLOWED_SERVICE_ACCOUNTS` but validation stayed off.

## 10/21/2026

### Changed

- `PaginationFilter` moved from `internal/api/dto` to `internal/domain`; `Pagination` and `PaginatedResponse[T]` moved to the new shared `internal/dto` package. Repositories and services no longer import the client API's `internal/api/dto`, which `internal/AGENTS.md` forbids. See `.kairos-updates/20261019T104600-pagination-types-moved.md`.
- `sql/README.md` index example uses `BTREE ((data->>'customerId'))`; the old `GIN (data->>'customerId')` form is a PostgreSQL syntax error.
- `.init.mk` runs `go mod tidy` in the root module before `go mod download` when the build toolkit is not in the module cache. A bumped toolkit version that is not yet in `go.sum` can now be fetched by `make tidy`.
- `google.golang.org/grpc` pinned to v1.83.2. v1.84.0 is affected by CVE-2026-84445 (GO-2026-6443).
- Release libraries (and the commented Veracode git-auth examples) use `KAIROS_BB_ACCESS_TOKEN` via `&configure-bitbucket-git-auth` instead of Bitbucket app passwords ([CHANGE-3222](https://developer.atlassian.com/cloud/bitbucket/changelog#CHANGE-3222)). See `.kairos-updates/20260930T111645-bitbucket-git-auth-replaced.md`.
- Dropped `kairos.env.kafka` from client-api, integration-api, and event-handler
  Deployments. Kafka is ConfigMap / Kyverno sidecar only.
- Chart helper list and README document `kairos.volumeMounts` / `kairos.volumes`
  (not inner postgres helpers or Kafka secret volumes). Auth-gateway Ingress
  path is `/<namespace>/client/(auth|api…)`.
- db-script-runner image pin uses `tag@sha256` and `COPY --chown=65532:65532` for the SQL tree.
- VS Code launch configs: local ports, `TRACING_ENABLED` + Jaeger `:30317`; removed the dead `web/app` / `npm start` frontend launch.
- `.gitignore` now ignores `.pdfbuild/`, `test/functional/.env`, stray `gen-masterdata` binaries, `docs/diagrams/`, and the legacy `charts/` path; Helm deps are `chart/charts/*.tgz` and `chart/Chart.lock` only.

### Added

- `.yamllint` and `web/.env.example`.
- `DomainChangeTimeout` (`domain_change_timeout`, default 10s) in the client-API and integration-API `AppConfig`, matching the event-handler.

#### Go mod replace support during local deployment

Now go mod replaces will be bundled in the image build process.

#### Rapidfort build and runtime images
Rapidfort build and runtime images are used for building and running the component.

**Build image:**
```dockerfile
FROM --platform=$BUILDPLATFORM ifsrapidfortcache.azurecr.io/rfcurated/golang:1.27.3-alpine3.24-rfcurated@sha256:169118cae5f8659519cceb8f5d9322645dcf771926af2c207c46c36560ce93ec AS builder

ARG GOPROXY
ENV GOPROXY=${GOPROXY}
ENV GONOSUMDB=bitbucket.org/ifs-pd/*
```

**Runtime image:**
```dockerfile
FROM ifsrapidfortcache.azurecr.io/rfcurated/debian:13-distroless-static-nonroot-rfcurated@sha256:6e0732617567e495eacc9cd02782790058fe70620916374d9cb2f31ac695b06f
```

#### Command Response Support
Asynchronous request-reply messaging pattern for event-driven architecture. Allows services to send commands and receive responses. Unlike events which are broadcast to all subscribers, command responses are sent specifically to the command issuer and include the command's correlation ID to link the response to the original request.

```go
// Sending command response
response := &schema.CreateOrderCommandResponseV1{
    Success: true,
    OrderId: "order-123",
}
responseMsg := commands.NewResponse(partitionKey, response)
ctx.Sender().SendCommandResponse(responseMsg)

// Handling command response
func HandleResponse(response *schema.CreateOrderCommandResponseV1, ctx request.Context) error {
    if response.Success {
        // Handle success
    }
    return nil
}
```

#### Master Data Mapping
Automatic replication and storage of reference data entities from other services. When master data events (relayed by the event relay service) are received, registered mappers automatically store them in local PostgreSQL tables as JSONB. Supports typed entity mapping with custom transformations.

```go
// Basic registration (uses default table name derived from entity type)
eh.Sync(eventhandler.MasterData[*masterdata.ProductEntityV1]())

// With custom table name
eh.Sync(eventhandler.MasterData[*masterdata.ProductEntityV1]().TableName("products"))

// Bulk registration
eh.Sync(
    eventhandler.MasterData[*masterdata.CustomerEntityV2](),
    eventhandler.MasterData[*masterdata.OrderEntityV1](),
    eventhandler.MasterData[*masterdata.ProductEntityV1](),
)
```

#### Entity Types
Standardized entity base types with automatic ID and ETag generation. EntityId uses UUID v7 (time-sortable and monotonically increasing), while EntityETag uses XID (compact and collision-resistant). ETags enable optimistic locking for concurrent updates.

```go
import "bitbucket.org/ifs-pd/kairos-component-common/common/entities"

type Order struct {
    entities.EntityBase[entities.EntityId]
    OrderNumber string
}

// Create new entity with UUID v7 ID and XID ETag
order := Order{
    EntityBase:  entities.NewEntityBase(entities.NewId(), entities.NewETag()),
    OrderNumber: "ORD-001",
}

// Update entity (generates new ETag)
order.EntityBase = order.EntityBase.ForUpdate()
```

#### Correlation ID Middleware
Built-in support for correlation ID tracking across services. Extracts correlation IDs from incoming requests (HTTP header `X-Correlation-ID` or CloudEvent extension `Ce-Ifscorrelationid`). If no correlation ID is present, a new one is automatically generated. The correlation ID is automatically included in all outgoing events and commands, enabling distributed tracing across the entire system. Loggers automatically include the correlation ID in all log entries. Access it via `ctx.CorrelationId()`.

```go
// Automatically extracts correlation IDs from:
// - HTTP header: X-Correlation-ID
// - CloudEvent extension: Ce-Ifscorrelationid
// Generates new ID if none present
// Includes in all outgoing messages

logger := ctx.Logger()  // Logger includes correlation ID automatically
correlationId := ctx.CorrelationId()  // Get correlation ID explicitly
```

#### Enhanced Messaging Abstractions
Improved type safety with payload-based messaging. Separates message payload (your business data) from the CloudEvents wrapper (metadata like type, source, ID). Payloads implement simple interfaces (`ComponentName()` and `Validate()`), while the library handles CloudEvents serialization automatically. Factory functions use generics for type inference, eliminating boilerplate code.

```go
// Define event
type OrderCreatedEventV1 struct {
    OrderId string `json:"orderId"`
}

func (e *OrderCreatedEventV1) ComponentName() string {
    return schema.ComponentName
}

func (e *OrderCreatedEventV1) Validate(ctx context.Context) error {
    return nil
}

// Create message
event := events.New(orderId, &OrderCreatedEventV1{OrderId: orderId})
ctx.Sender().Publish(event)
```

#### Service Dependencies Pattern
Unified dependency injection container for centralized service management. Provides a single container that holds all service dependencies (logger, sender, config, tracer, PostgreSQL client, etc.) with type-safe access through generic methods. Simplifies dependency passing and makes testing easier by allowing dependency substitution.

```go
deps := services.NewDependencies[ServicesFactory, config.BaseConfig, config.AppConfig](
    appConfigProvider,
    clientProvider,
    sender,
    baseConfigProvider,
    servicesFactory,
    ctx,
    logger,
    tracer,
    shutdownTracing,
    promRegisterer,
    ctxCancel,
)

// Access dependencies
logger := deps.GetLogger()
sender := deps.GetSender()
```

#### Enhanced Testing Infrastructure
Comprehensive test helpers for API and event handler testing. Provides fake implementations for testing (FakeSender tracks all sent messages). Simplifies writing integration tests without external dependencies. Test helpers mirror production APIs for consistency.

```go
// API testing
import "bitbucket.org/ifs-pd/kairos-component-common/api/test"

testApi := test.New("my-service", &ServicesFactory{}, &Config{})
defer testApi.Close()

// Event handler testing
import "bitbucket.org/ifs-pd/kairos-component-common/event-handler/test"

testEvtHandler := test.New("my-service", &ServicesFactory{}, &Config{})
defer testEvtHandler.Close()

// Verify sent messages
sentMessages := testEvtHandler.TestContext().FakeSender.SentMessages()
```

#### Built-in Middleware
Additional middleware for common cross-cutting concerns:
- `correlation.AddCorrelationIdMiddleware()` - Extracts/generates correlation IDs for distributed tracing
- `idempotency.AddIdempotencyMiddleware()` - Prevents duplicate message processing using PostgreSQL-based deduplication
- `tenant.AddTenantMiddleware()` - Resolves tenant context from headers/claims for multi-tenancy support
- `tracing.AddTracingMiddleware()` - Integrates OpenTelemetry for distributed tracing and observability

### Changed

#### Message Structure
Messages are now payload-based instead of embedding MessageBase.

**Before:**
```go
type OrderCreatedEventV1 struct {
    messaging.MessageBase
    OrderId string
}
```

**After:**
```go
type OrderCreatedEventV1 struct {
    OrderId string `json:"orderId"`
}
```

#### Partition Key Handling
Partition keys are now passed when creating messages, not as a method.

**Before:**
```go
func (e *OrderCreatedEventV1) GetPartitionKey() string {
    return e.OrderId
}
```

**After:**
```go
event := events.New(orderId, payload)  // Pass partition key directly
```

#### Middleware Location
Middleware moved to internal directories.

**Before:**
- `internal/api/middleware/`
- `internal/event-handler/middleware/`

**After:**
- `internal/api/internal/middleware/`
- `internal/event-handler/internal/middleware/`

### Breaking Changes

See [UPGRADE.md](https://bitbucket.org/ifs-pd/kairos-component-common/src/topic/nidees/abstractions2/UPGRADE.md) in kairos-component-common for detailed migration instructions.

### Documentation

- Added [pkg/schema/AGENTS.md](./pkg/schema/AGENTS.md) - Complete guide for creating message schemas
- Updated [internal/event-handler/AGENTS.md](./internal/event-handler/AGENTS.md) - Added master data and command response examples
- Added comprehensive validation patterns using `nga-common/validation`

