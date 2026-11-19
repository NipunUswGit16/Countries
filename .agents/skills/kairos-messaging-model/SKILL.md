---
name: kairos-messaging-model
description: Reference model for Kairos inter-component messaging — the conceptual distinction between commands, events, and command responses; the three `ctx.Sender()` methods (`Send`, `Publish`, `SendCommandResponse`) and when each is correct; partition-key semantics and ordering guarantees; double validation (sender + receiver); at-least-once delivery and the idempotency table; the `ComponentName()` routing contract. Use when reasoning about message flow, debugging "wrong method" errors, choosing partition keys, understanding delivery/ordering guarantees, or when the user says "how does Kairos messaging work", "publish vs send", "partition key", "double validation", "at-least-once", or similar theory/model questions.
---

# Kairos Messaging Model

Reference model for Kairos inter-component messaging. Consult when reasoning about *why* a pattern is shaped a certain way, choosing between sender methods, picking partition keys, or debugging ordering/routing/duplication. For the mechanical recipes, see the matching task skills.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## The three message kinds

| Kind | Semantics | Naming | CloudEvent type |
|---|---|---|---|
| **Command** (`*CommandV1`) | Imperative — *request* that another component perform an action | `{Action}{Entity}CommandV{N}` (verb first) | `{entity}.{action}.v{n}` |
| **Event** (`*EventV1`) | Past-tense fact — *something happened*, broadcast to any subscriber | `{Entity}{Pasttense}EventV{N}` (verb past) | `{entity}.{action}.v{n}` |
| **Command Response** (`*CommandResponseV1`) | Reply to a specific command | `{Action}{Entity}CommandResponseV{N}` | `{entity}.{action}.response.v{n}` |

All three are **payload structs**, not wire-level messages. The framework wraps them in `CommandMessage`, `EventMessage`, `CommandResponseMessage` respectively, adds CloudEvent metadata, serializes, and routes.

## The three sender methods — and why they are different

| Method | Purpose | Audience | Message kind |
|---|---|---|---|
| `ctx.Sender().Publish(event)` | **Broadcast** — fan out to everyone subscribed | 0..N subscribers | `*EventV1` |
| `ctx.Sender().Send(cmd)` | **Directed** — route to the owning component | Exactly 1 (the owner) | `*CommandV1` |
| `ctx.Sender().SendCommandResponse(resp)` | **Reply** — return to the original sender | Exactly 1 (the original caller) | `*CommandResponseV1` |

Using the wrong method is a frequent mistake. Commands are never `Publish`ed; events are never `Send`. The framework enforces type correctness at compile time via the interface assertions on each message type, but at *semantics* level the author must pick the right one.

### The `ComponentName()` routing contract

Every message payload implements `ComponentName() string`:

- For **commands**: the return value tells the framework **which component handles this command**. A command's schema lives in the owning component's `pkg/schema/`; other components import it to send.
- For **events**: the return value identifies **the producing component** — subscribers infer the topic from this.
- For **command responses**: identifies the **responding component**.

Changing `ComponentName()` is always a breaking change (it rewires routing).

## Partition keys and ordering guarantees

Every publish/send requires a partition key (first argument of `events.New(...)`, `commands.New(...)`, `commands.NewResponse(...)`).

**Kafka guarantee:** messages with the **same partition key** go to the same partition and are processed **in order** by a single consumer. Messages on **different partition keys** may be processed in parallel.

### Picking a partition key

| Key | When to use |
|---|---|
| Aggregate ID (e.g. `order.Id.String()`) | Default — keeps state changes for one aggregate ordered |
| Tenant ID | Strict per-tenant ordering (rare) |
| A correlation ID | Threading related events across aggregates |
| Composite key | When correlation and aggregate ordering must both be preserved |

### RED FLAG: empty partition key

An empty string partition key → random partition → **ordering broken**. If you see events for the same aggregate arriving out of order, check the partition key first.

## Double validation

Every `*CommandV1`, `*EventV1`, and `*CommandResponseV1` declares a `Validate(ctx) error` method. The framework calls it **twice**:

1. **On the sender**, before transmission. Invalid messages are rejected before they ever touch Kafka.
2. **On the receiver**, before the handler is invoked. Prevents a malformed (or maliciously hand-crafted) payload from reaching your business logic.

Implementers only write `Validate` once; the framework handles both invocations. This is why every message schema must implement it — missing `Validate` is a contract violation and the compile-time interface assertion will fail the build.

## Delivery semantics

**At-least-once** — the framework may deliver a message more than once under retry/restart conditions, but **idempotency is enforced by the framework, not by handler code**. Every consumed message ID is recorded in the `idempotency` table (provisioned automatically via the `+kairos:sql:lib:bitbucket.org/ifs-pd/kairos-component-common/event-handler` directive in `cmd/event-handler/main.go`) **inside the same database transaction** as the handler's writes. On redelivery the framework recognizes the message ID and skips the handler entirely. Whether that transaction commits when the handler fails depends on the event-handler version — see § *Handler failure semantics*.

This applies to both **event handlers** and **command handlers**. The only case where a handler must add its own idempotency guards is when it performs side effects *outside* `ctx.DatabaseSession()` — e.g. external HTTP calls, raw Kafka publishes that bypass the outbox, writes to a second database — because those do not participate in the framework's transaction.

### API side — transactional outbox

When an API endpoint changes domain state **and** dispatches one or more outbound messages — any of `Publish`, `Send`, or `SendCommandResponse` — the domain change and every outbound message must commit atomically. The `event_outbox` table (provisioned via `+kairos:sql:lib:bitbucket.org/ifs-pd/nga-event-outbox/pkg/eventsender` in `cmd/client-api/main.go`, and also in `cmd/integration-api/main.go` if that file exists) records every outbound message in the same transaction as the domain change; a background process drains the table to Kafka afterward. Without the outbox, a commit can succeed and the subsequent send can fail, leaving your DB and event stream inconsistent.

### Handler failure semantics

What a returned error does depends on `kairos-component-common/event-handler` in `go.mod` (`go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/event-handler`):

| event-handler | Handler returns an error | Handler returns a fatal error |
|---|---|---|
| ≥ v1.2.46 | The idempotency row, the handler's writes and its outbox rows roll back; the message is retried. | Rolls back; the message goes to the DLQ without retry. |
| < v1.2.46 | The idempotency row, the writes and the outbox rows **commit**. Redelivery returns `AlreadyProcessed`, so the message is never re-run. | Same: commits, then DLQ. |

On < v1.2.46, validate and make every call that can fail **before the first write or publish**, so a failure leaves nothing behind. The lasting fix is event-handler ≥ v1.2.46, but that tag also requires common ≥ v1.4.2, eventsender v0.1.1 and Go 1.27.2 — crossing common v1.4.0 and event-handler v1.2.44, which change behaviour — so adopt it through `kairos-component-update`, not a bare `go get`. Suggest it to the author without blocking on it, and re-run the version checks after it.

- **Command handler returns `(nil, error)`** (fire-and-forget) → as the table; no response is sent to the caller.
- **Command handler returns `(response, nil)`** (auto-response) → framework wraps and sends the response. Use `Success: false` + `nil` error to signal a *domain* failure to the caller without triggering a retry.

## Domain events are the default contract

Kairos is event-driven by construction. Components integrate **only** through the event stream — there is no shared database to query, no synchronous RPC to call, no entity-pull API to scrape. Other components find out what happened in this component exclusively by subscribing to the events this component publishes.

**The rule:** every meaningful domain state change emits a `*EventV1`, regardless of whether any subscriber currently exists. Future subscribers integrate silently by registering a handler in their own component (see `kairos-cross-component-integration`); the producer never finds out who is listening.

The default is **emit**. Skipping is an opt-out that requires deliberate justification (see *Legitimate "no event" cases* below).

### Where the rule lives — the service owns the publish

Domain state changes can be triggered through several inbound paths — API endpoints, command handlers, event handlers (saga steps) — but they all converge at the **service** layer. The repository is too low: it cannot tell the difference between a domain mutation, a master-data replica upsert, or a read-model write. Only the service has that context.

This section assumes `internal/services/outbound_messenger.go` exists. If it doesn't, the endpoint or handler publishes with `ctx.Sender()` in its own request or idempotency transaction — still atomic with the writes — and the "publish in a handler is a defect" red flag below does not apply. The template upgrade-file `20260724T113527-consolidate-outbound-messenger.md` (skill `kairos-component-update`) adopts the messenger.

Kairos anchors the publish at the service. Every state-mutating service method publishes its `*EventV1`(s) through a narrow `services.OutboundMessenger` interface before returning. Callers (API endpoint, command handler, saga-step event handler) do not call `ctx.Sender().Publish(...)` — the service did it. See `kairos-create-service` for the contract, the constructor signature, and the `ServicesFactory` adapter that bridges `ctx.Sender()` into `OutboundMessenger`.

**What this guarantees:**

- A single owner. The rule is mechanical: you cannot call the service without producing its events. New call sites need no judgement.
- Atomic with the mutation. `OutboundMessenger.Publish` flows through the same `interfaces.Session` the service is writing to, so the event enrolls in the outbox table in the same transaction as the domain change.
- Symmetric across paths. The HTTP-write decision table below collapses: an API endpoint, a command handler, and a saga-step event handler all look identical from the outside — they call the service, and the world finds out.
- The right payload. Because the service has the persisted aggregate in hand at the moment of publish, it can construct an **event-carried-state** payload directly from that aggregate — see § *Event-carried state transfer* below. This is the second half of "mutate → event": the right event, with the right payload, atomically with the right write.

**What stays at the call site:**

- `ctx.Sender().SendCommandResponse(...)` — correlation-bound to a specific inbound `CommandMessage`, lives in the command handler. See `kairos-create-command`.

**Saga starters** (cross-component `Send` triggered by a mutation) belong in the service too — they are domain logic and ride the same `OutboundMessenger`.

### Event-carried state transfer

Every event payload contains the **full state** subscribers need to react — not just an ID. Subscribers populate their own local read model from the event payload; they do **not** call back to the producer to fetch missing fields.

Concretely: an `IssueCreatedEventV1` carries title, status, project reference, reporter, assignee, timestamps — anything a reasonable consumer might need. An `IssueAssignedEventV1` carries the new assignee (and ideally the previous one). An `IssueClosedEventV1` carries the resolution and who closed it. An empty event with only an `id` is a red flag.

Notice these are **specific** events — named after the domain verb (assigned, closed, reopened), not after the field that changed. A generic `IssueStatusChangedEventV1 { newStatus, ... }` is N events fused into one and forces every subscriber to filter in code instead of subscribing by interest. See `kairos-create-event` § *Prefer specific events over generic transition events* for the full treatment and the rare exception (genuinely user-configurable state machines).

**Why event-carried state:** callbacks to the producer create runtime coupling between components, defeat tenant isolation (the producer would need to expose a tenant-aware read API to peers), and cascade load to the producer during event-stream replay. Event-carried state makes subscribers self-sufficient and replays cheap.

**Exception:** very large payloads (multi-megabyte attachments, embedded blobs). Emit a reference plus a tenant-scoped fetch endpoint. That is the only legitimate "callback" pattern.

### Legitimate "no event" cases

The rule has narrow exceptions — changes with no domain meaning to anyone outside this component:

- Invalidating an internal cache.
- Updating an in-memory bookkeeping flag.
- Replicating master data from another component (the master-data mapper does the upsert; re-publishing would echo the source event back through the bus).
- Writing a local read model in response to an event from another component (the read model is a local view; consumers integrate with the *source* event, not your derived write).

If the change has a domain noun and a past-tense verb — Issue *created*, Comment *added*, Status *transitioned*, Sprint *closed* — it has domain meaning. Emit. When in doubt, emit.

## Default pattern for HTTP writes

When an HTTP write reaches an API endpoint, the handler always parses + validates the body, obtains the tenant-scoped DB session via `ctx.DatabaseSession()`, and wraps work in a configured timeout. What it does *next* depends on **where the state lives**. Because the service owns the publish (see § *Domain events are the default contract* → *Where the rule lives*), the variants collapse to four:

| # | Pattern | Use when |
|---|---|---|
| 1 | **Service call.** The service mutates state, publishes its `*EventV1`(s), and runs any saga-starter `Send` to other components — all internally. | Local state changes. **The default**; matches the `kairos-create-api-endpoint` template. Covers what older docs called "service + Publish", "service + cross-Send", and "service + cross-Send + Publish" — all of those compose inside the service now. |
| 2 | **Service call only, no events.** Strictly: the change has no domain meaning to anyone outside this component (cache invalidation, in-memory bookkeeping, master-data replica writes, derived read-model writes). The service method does not call `messenger.Publish` for these. | *Rare exception.* If the change has a noun + past-tense verb (Issue *created*, Status *transitioned*), it has domain meaning and Row 1 applies — see § *Legitimate "no event" cases*. |
| 3 | **Cross-component `Send` only** (handler calls `ctx.Sender().Send(...)`). | Endpoint owns no local state; thin trigger for work owned elsewhere (`POST /search/reindex` etc.). No service call because there's no aggregate to mutate. |
| 4 | **Self-`Send` (async)** (handler calls `ctx.Sender().Send(...)` against a `*CommandV1` this component owns). | Work belongs here but the caller doesn't need to wait. Validate, dispatch the command, return 202. Your own command handler processes it later — and *that* handler calls the service, which publishes the event. |

**Defaults and red flags:**

- The publish call does **not** live in the handler (when the messenger exists — see § *Where the rule lives*). If you see `ctx.Sender().Publish(...)` in an API endpoint, command handler, or event handler, that's a defect — the service should have done it. See `kairos-create-service`.
- Don't pick Row 4 over Row 1 just to "use the framework" — see `kairos-send-command` § *When local-send is appropriate*. A self-`Send` adds a Kafka hop, an outbox row, and an idempotency record; reach for it only when the async semantics are the goal.
- Sending a command and *waiting* synchronously for its response inside the same HTTP handler is not supported out of the box. If you want that, re-read `kairos-send-command` and `kairos-create-command-response-handler` first — almost always the right answer is to model the operation event-driven instead.

### HTTP response codes per pattern

| Pattern | Typical response |
|---|---|
| 1 (service call — mutate + publish + any saga-starter Send, all inside) | `200 OK` (or `201 Created`) with the created/updated resource. Downstream effects are async via the outbox. |
| 2 (service call, no event) | `200 OK` (or `204 No Content` for purely-mutating endpoints) |
| 3 (cross-Send only) | `202 Accepted` |
| 4 (self-Send) | `202 Accepted`, typically with a correlation id or status URL |

For the mechanics of each call, see `kairos-publish-event`, `kairos-send-command`, and `kairos-cross-component-integration`. All three sender methods participate in the transactional outbox — see § *API side — transactional outbox* above. The outbox is `interfaces.Session`-scoped, so `messenger.Publish` from inside a service enrolls in exactly the same transaction as the repo write.

## Request-reply flow (commands + responses)

A `*CommandV1` flows from sender (component A) to the owning component (B), where a **command handler** in `internal/event-handler/commands/` produces the reply — either by returning a typed `*CommandResponseV1` (auto-send) or by calling `SendCommandResponse` manually. Component A consumes the reply via a **command response handler** in `internal/event-handler/responses/`. The response should carry the **same partition key** as the incoming command so ordering is preserved across the round-trip.

## Common pitfalls

- **Using `Send` for an event** → compile may succeed (generic sender), but semantics are wrong; likely misroutes or single-receiver-drops.
- **Omitting `ComponentName()`** → framework cannot route; schema is effectively orphan.
- **Missing `idempotency` table** (broken `+kairos:sql:lib:` directive in `cmd/event-handler/main.go`) → framework cannot deduplicate; duplicate processing on retry; corrupted state.
- **Side effects outside `ctx.DatabaseSession()`** (external HTTP, raw Kafka, second DB) → not covered by the framework's idempotency; must be guarded by hand.
- **Cross-aggregate partition keying** → lost ordering within an aggregate.
- **Tightening `Validate()` rules in place on a V1 schema** → breaking change for existing senders; create V2 instead (see `pkg/schema/AGENTS.md` versioning policy).
