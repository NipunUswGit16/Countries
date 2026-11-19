# Event Handler

The CloudEvent surface (Kafka). Handlers receive the **typed payload directly** — never a raw CloudEvent — delegate to a service via `ServicesFactory`, and either auto-respond with a typed `*CommandResponseV1`, return `(eventhandler.NilCommandResponse, nil)` for fire-and-forget, or return `error` to trigger a retry. Domain-event publishing happens **inside the service** via `OutboundMessenger`, not in the handler — see `kairos-create-service`.

At-least-once delivery is deduplicated automatically by the framework against the `idempotency` table — provisioned by the `+kairos:sql:lib:` directive in `cmd/event-handler/main.go` (see root `AGENTS.md` and `cmd/AGENTS.md`).

For handler signatures, registration via `eh.Add(...)` / `eh.Sync(...)` in `handlers.go`, the event-handler `request.Context` surface (`DatabaseSession()` returns just `session` — **nil-check it**; also exposes `PartitionKey()`), invoke:

- `kairos-create-event-handler` — handle a `*EventV1`
- `kairos-create-command` — define a `*CommandV1` schema **and** its handler
- `kairos-create-command-response-handler` — handle a reply your component received
- `kairos-register-masterdata-mapper` — replicate master data from another component
- `kairos-test-event-handler` — handler tests via `eventhandlertest.New`
- `kairos-test-functional-event-handler` — functional (end-to-end) verification of command, event, command-response, or master-data behavior via a Kairos CLI-created component; use when behavior is new or changed and lacks functional coverage — see root `AGENTS.md` § *Functional verification*

Schema versioning rules (V1 / V2 / `// Deprecated:` / parallel publish) live in `../../pkg/schema/AGENTS.md`. **If uncertain whether a change is breaking, ask the user.**
