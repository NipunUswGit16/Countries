---
name: kairos-test-service
description: Writes unit tests for a Kairos service using nga-common mocks for PostgreSQL, a fake OutboundMessenger for asserting domain-event publishing, testify for assertions, and the Arrange-Act-Assert pattern. Services own publish, so domain-event assertions live at the service-test layer (not in handler tests). Covers mock session setup, JSONB scan-via-Run patterns, and OutboundMessenger expectations. Use when testing a service, adding service unit tests, asserting that a service publishes its events, mocking PostgreSQL for tests, or when the user says "test this service", "write service tests", or "unit test".
---

# Test a Kairos Service

Kairos services are tested with the nga-common mock package (`bitbucket.org/ifs-pd/nga-common/postgres/client/mocks`), the template-provided fake `OutboundMessenger` (from `internal/services/test/fake`), `testify` (assertions + mocks), and a no-op logger. Services are generally tested together with their real repository plus a mocked session — this covers more surface than mocking the repository interface. Since services own domain-event publishing (`kairos-create-service` § *Service responsibility for domain events*), **service tests are the layer that asserts the right events were emitted with the right event-carried-state payloads.** Handler tests (apitest, eventhandlertest) no longer carry that responsibility.

Use the Arrange-Act-Assert pattern and one behaviour per test function (table-driven only when scenarios differ only in input data).

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Standard imports

```go
import (
    "context"
    "testing"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
    "github.com/stretchr/testify/mock"

    "bitbucket.org/ifs-pd/kairos-component-common/common/entities"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/services/test/fake"
    "bitbucket.org/ifs-pd/nga-common/logging"
    "bitbucket.org/ifs-pd/nga-common/postgres/client/mocks"
)
```

The mock types from `nga-common/postgres/client/mocks` satisfy `interfaces.Session`/`interfaces.ClosableSession` and are built on `testify/mock`. Use them directly — never `pgxmock`.

Key mock constructors:

- `mocks.NewMockSession()` — implements `interfaces.ClosableSession` (used in service+repo tests)
- `mocks.NewMockRow()` — for `QueryRow` / `Scan` expectations
- `mocks.NewMockRows()` — for `Query` / multi-row expectations
- `mocks.NewMockExecResult()` — for `Exec` result (`RowsAffected`, etc.)

Test file lives next to its source as `{source}_test.go`; test functions are `Test{Subject}{Scenario}` (e.g. `TestCreateExampleSuccess`, `TestGetByIDNotFound`) — no underscores in the function name.

## Faking `OutboundMessenger`

Services receive a `services.OutboundMessenger` and use it to publish events (and run saga-starter `Send` calls). Pick the fake by what the component has, in this order:

1. `test -f internal/services/test/fake/outbound_messenger.go` → use `fake.NewFakeMessenger()` / `fake.NewNopMessenger()` from it.
2. Otherwise, `grep -rln 'fakeMessenger' --include=*_test.go internal/services` finds files → reuse that inline fake (`messenger := &fakeMessenger{}`); don't add a second one.
3. Neither, but `grep -rln 'messaging.Command) (string, error)' --include=*.go internal` finds a hand-rolled messenger (e.g. `internal/services/messenger.go`; `kairos-create-service` second row) → the services take that interface; write a small fake of it in the test package.
4. None of the above, and `test -f internal/services/outbound_messenger.go` → create `internal/services/test/fake/outbound_messenger.go` verbatim from the snippet below.
5. None of the above, and no `internal/services/outbound_messenger.go` → the component's services take no messenger, so there is nothing to fake. Test the service without one, and assert publishing in the handler tests where the component publishes. Don't create the messenger or the fake package inside this task; the template upgrade-file `20260724T113527-consolidate-outbound-messenger.md` (skill `kairos-component-update`) adopts them.

The shared fake records everything published or sent:

```go
package fake

import (
    "bitbucket.org/ifs-pd/kairos-component-common/common/messaging"
    "bitbucket.org/ifs-pd/kairos-component-template/internal/services"
    "github.com/rs/xid"
)

// nopMessenger discards all outbound messages. Use in tests that do not assert publishing.
type nopMessenger struct{}

func (nopMessenger) Publish(messaging.Event) error          { return nil }
func (nopMessenger) Send(messaging.Command) (string, error) { return "", nil }

// NewNopMessenger creates a new nop messenger.
func NewNopMessenger() services.OutboundMessenger {
    return nopMessenger{}
}

// Messenger records calls to OutboundMessenger.Publish / Send so a test
// can inspect what the service emitted. Reset between tests by constructing
// a new instance.
type Messenger struct {
    Published  []messaging.Event
    Sent       []messaging.Command
    PublishErr error // optional — set to make Publish return an error
    SendErr    error // optional — set to make Send return an error
}

func (f *Messenger) Publish(e messaging.Event) error {
    f.Published = append(f.Published, e)
    return f.PublishErr
}

func (f *Messenger) Send(c messaging.Command) (string, error) {
    id := xid.New().String()
    f.Sent = append(f.Sent, c)
    return id, f.SendErr
}

var _ services.OutboundMessenger = (*Messenger)(nil)

// NewFakeMessenger creates a new fake messenger.
func NewFakeMessenger() *Messenger {
    return &Messenger{}
}
```

Replace the module path `bitbucket.org/ifs-pd/kairos-component-template` with the component's own (first line of `go.mod`).

In tests, construct a fresh recorder in each `Arrange` block (`messenger := fake.NewFakeMessenger()`) — never share the instance across tests. Use `fake.NewNopMessenger()` when a test needs a service but does not assert on outbound messages.

## Service + repository test (nga-common mocks + fake messenger)

```go
func TestExampleServiceCreateExampleSuccess(t *testing.T) {
    // Arrange
    mockSession := mocks.NewMockSession()
    messenger := fake.NewFakeMessenger()
    logger := logging.Nop()
    repo := repositories.NewExampleRepository(mockSession)
    service := services.NewExampleService(repo, messenger, logger)

    ctx := context.Background()
    // The caller (the endpoint) sets the id, ETag and audit fields; the service persists what it gets.
    example := domain.ExampleModel{
        EntityBase: entities.NewEntityBase(entities.NewId(), entities.NewETag()),
        Name:       "Test Example",
    }

    mockExecResult := mocks.NewMockExecResult()
    mockSession.On("Exec", ctx, mock.Anything, mock.Anything, mock.Anything).
        Return(mockExecResult, nil)

    // Act
    result, err := service.CreateExample(ctx, example)

    // Assert — domain side
    require.NoError(t, err)
    assert.Equal(t, "Test Example", result.Name)
    assert.NotZero(t, result.CreatedAt)
    assert.NotEmpty(t, result.Id)

    // Assert — event side (this is the layer that owns event assertions)
    require.Len(t, messenger.Published, 1, "expected exactly one event")
    payload, ok := messenger.Published[0].GetPayload().(*schema.ExampleCreatedEventV1)
    require.True(t, ok, "expected ExampleCreatedEventV1")
    assert.Equal(t, "Test Example", payload.Name)
    assert.Equal(t, result.Id.String(), payload.Id, "event-carried state carries the persisted aggregate id")
    assert.Equal(t, result.Id.String(), messenger.Published[0].GetPartitionKey(), "partition key = aggregate id")
    assert.Empty(t, messenger.Sent, "no saga-starter Send expected for plain create")

    mockSession.AssertExpectations(t)
}
```

Two things this test covers that handler tests cannot:

1. **The right event was constructed** — `ExampleCreatedEventV1`, not some neighbouring schema.
2. **The payload follows event-carried state** — `Name` and `Id` are populated from the persisted aggregate, not from raw input.

For tests where the publish itself fails (verifying the service rolls back / surfaces the error), set `messenger.PublishErr = errors.New("...")` before calling the service method.

## Mocking QueryRow + Scan (JSONB read pattern)

Use `mock.Run` to populate the pointer arguments that `Scan` writes into:

```go
func TestExampleServiceGetByIDSuccess(t *testing.T) {
    mockSession := mocks.NewMockSession()
    messenger := fake.NewFakeMessenger() // read-only operation, but the constructor still requires it
    logger := logging.Nop()
    repo := repositories.NewExampleRepository(mockSession)
    service := services.NewExampleService(repo, messenger, logger)

    ctx := context.Background()
    entityID := entities.NewId()
    entityData := domain.ExampleModel{
        EntityBase: entities.NewEntityBase(entityID, entities.NewETag()),
        Name:       "Test",
    }
    jsonData, _ := json.Marshal(entityData)

    mockRow := mocks.NewMockRow()
    mockRow.On("Scan", mock.Anything, mock.Anything).
        Run(func(args mock.Arguments) {
            *args.Get(0).(*string) = entityID.String()
            *args.Get(1).(*string) = string(jsonData)
        }).Return(nil)

    mockSession.On("QueryRow", ctx, mock.Anything, mock.Anything).Return(mockRow)

    result, err := service.GetExampleById(ctx, entityID.String())

    require.NoError(t, err)
    assert.Equal(t, "Test", result.Name)
    assert.Empty(t, messenger.Published, "read-only operation must not publish events")
    mockSession.AssertExpectations(t)
    mockRow.AssertExpectations(t)
}
```

## Mocking multi-row Query (paginated results)

```go
mockRows := mocks.NewMockRows()
mockRows.On("Next").Return(true).Once()
mockRows.On("Next").Return(false)
mockRows.On("Scan", mock.Anything, mock.Anything).
    Run(func(args mock.Arguments) {
        *args.Get(0).(*string) = entityID.String()
        *args.Get(1).(*string) = string(jsonData)
    }).Return(nil).Once()
mockRows.On("Close").Return()
mockRows.On("Err").Return(nil)

mockSession.On("Query", ctx, mock.Anything, mock.Anything, mock.Anything, mock.Anything).
    Return(mockRows, nil)
```

## Mocking RowsAffected (Delete pattern)

```go
mockExecResult := mocks.NewMockExecResult()
mockExecResult.On("RowsAffected").Return(int64(1))
mockSession.On("Exec", ctx, mock.Anything, mock.Anything).Return(mockExecResult, nil)
```

## Mocking a service at the interface level

When you need to mock a service (e.g. in a handler test), define a `testify/mock`-based mock:

```go
type MockExampleService struct {
    mock.Mock
}

func (m *MockExampleService) CreateExample(ctx context.Context, example domain.ExampleModel) (domain.ExampleModel, error) {
    args := m.Called(ctx, example)
    return args.Get(0).(domain.ExampleModel), args.Error(1)
}

func TestSomething(t *testing.T) {
    mockService := &MockExampleService{}

    mockService.On(
        "CreateExample",
        mock.Anything,
        mock.MatchedBy(func(e domain.ExampleModel) bool { return e.Name == "Test" }),
    ).Return(domain.ExampleModel{Name: "Test"}, nil)

    result, err := mockService.CreateExample(context.Background(), domain.ExampleModel{Name: "Test"})

    require.NoError(t, err)
    assert.Equal(t, "Test", result.Name)
    mockService.AssertExpectations(t)
}
```

## Table-driven tests

For pure functions with many scenarios:

```go
func TestValidateOrder(t *testing.T) {
    tests := []struct {
        name    string
        order   domain.Order
        wantErr bool
        errMsg  string
    }{
        {"valid order", domain.Order{CustomerName: "John", TotalAmount: 100}, false, ""},
        {"empty customer", domain.Order{CustomerName: "", TotalAmount: 100}, true, "customer name is required"},
        {"negative amount", domain.Order{CustomerName: "John", TotalAmount: -10}, true, "amount must be positive"},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            err := ValidateOrder(tt.order)
            if tt.wantErr {
                require.Error(t, err)
                assert.Contains(t, err.Error(), tt.errMsg)
            } else {
                require.NoError(t, err)
            }
        })
    }
}
```

Rule of thumb: one test per **function + behaviour**; use table-driven only when the scenarios differ only in input data.

## Required elements checklist

- [ ] Test file next to source: `{source}_test.go`
- [ ] Uses `require` for fail-fast preconditions and `assert` for inspections
- [ ] `mocks.NewMockSession()` from `bitbucket.org/ifs-pd/nga-common/postgres/client/mocks`
- [ ] Fresh fake messenger per test (`messenger := fake.NewFakeMessenger()`) — never shared
- [ ] Every `mockSession.On(...)` matched with `mockSession.AssertExpectations(t)` at the end
- [ ] JSONB scan expectations use `mock.Run(func(args mock.Arguments){...})` to write into pointer args
- [ ] Logger uses `logging.Nop()`
- [ ] One behaviour per test function
- [ ] Error paths tested, not just the happy path
- [ ] **For every state-mutating method, the test asserts the expected event(s) were published**: count via `len(messenger.Published)`, type via `payload, ok := e.GetPayload().(*schema.XEventV1)`, payload fields against the persisted aggregate (event-carried state), partition key (`e.GetPartitionKey()`) against the expected key. This is the layer that owns event assertions now — handler tests do not.
- [ ] For read-only methods, `assert.Empty(t, messenger.Published)` confirms no spurious events.

## Common mistakes (RED FLAGS)

- Missing `mockSession.AssertExpectations(t)` (and matching calls on `mockRow`/`mockRows`) — silently skipped expectations.
- Over-loose `mock.Anything` where a specific value should be asserted.
- Testing the happy path only — error paths are where bugs hide.
- Relying on whole-struct equality instead of asserting individual fields (timestamps and generated IDs defeat equality).
- Sharing mocks (or the fake messenger) across tests — always construct fresh per test.
- Asserting only that *some* event was published (`len(messenger.Published) >= 1`) without checking the concrete type and payload — the whole point of moving publish into the service is to verify the right event and event-carried-state shape here.
- Forgetting to assert `messenger.Published` is empty in read-only tests — a leaked publish in a Get/List method is a real defect.
