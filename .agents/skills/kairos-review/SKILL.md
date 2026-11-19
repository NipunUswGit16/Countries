---
name: kairos-review
description: Reviews a branch or pull request. First asks whether the target is a Kairos component (uses platform-specific architecture/security checklist) or a general service (spawns role-based specialist agents). Independently asks how to access the diff — Bitbucket API (PR URL) or local repo. Triages every finding as CRITICAL / MAJOR / MINOR/NOTE, supports interactive deep-dives that always include code excerpts, and can post inline Bitbucket comments in either mode. Triggered by "review my changes", "kairos review", "check my branch", "review this PR", or a Bitbucket PR URL.
---

# Kairos Review

A unified review skill with two **modes** (rule sets) and two **access methods** (diff sources). They are independent — pick one of each.

| | Kairos mode | General mode |
|---|---|---|
| **Bitbucket API** | ✅ inline comments supported | ✅ inline comments supported |
| **Local repo** | ✅ no token needed | ✅ no token needed |

## Step 1 — Choose mode

Ask the user, exactly once, before anything else:

```text
Is this a Kairos component or a general service?
  A) Kairos component — apply Kairos architecture/security/test invariants
  B) General service  — language-aware multi-agent review
```

- **A → Kairos mode** — Step 6 will run the Kairos checklist (this file).
- **B → General mode** — Step 6 will spawn Code / Infrastructure / Security / Validator agents (see [REFERENCE.md](REFERENCE.md)).

## Step 2 — Choose access method

Always ask, regardless of mode:

```text
How should I access the diff?
  A) Bitbucket API — paste the PR URL; enables inline comment posting
  B) Local repo    — review against a local checkout; no token needed
```

The choice here is independent of the mode. Both modes work with both access methods.

## Step 3 — Credentials setup (Option A only)

Credentials live in `~/.config/kairos-review/credentials` — a host-agnostic plaintext file that works identically in Claude Code, Cursor, Codex, and WSL on Windows. The skill sources it directly, so it does not depend on any host-specific settings file (`~/.claude/settings.json`, Cursor settings, etc.).

1. Source the file (if it exists) and check the env vars:

   ```bash
   [ -f ~/.config/kairos-review/credentials ] && . ~/.config/kairos-review/credentials
   ```

   Then verify `$BITBUCKET_TOKEN` and `$BITBUCKET_EMAIL` are non-empty.
2. If **both set**: proceed.
3. If **either missing**: display the setup instructions from [SETUP.md](SETUP.md) verbatim. Once the user provides both values, write them to the credentials file with `0600` permissions:

   ```bash
   mkdir -p ~/.config/kairos-review
   umask 077
   cat > ~/.config/kairos-review/credentials <<'EOF'
   export BITBUCKET_TOKEN='<token>'
   export BITBUCKET_EMAIL='<email>'
   EOF
   chmod 600 ~/.config/kairos-review/credentials
   ```

   Then `. ~/.config/kairos-review/credentials` to load the values into the current shell. Confirm: "Credentials saved to ~/.config/kairos-review/credentials with 0600 permissions — they will be available in all future sessions across Claude Code, Cursor, and WSL."

> **Auth method**: Bitbucket's API requires HTTP Basic auth (`-u "$EMAIL:$TOKEN"`), not Bearer. See [SETUP.md](SETUP.md).

## Step 4 — Get diff source

- **Option A (Bitbucket API)**: ask "What is the Bitbucket PR URL?"
- **Option B (Local repo)**: ask:
  1. "What is the absolute path to the repo? (leave empty for the current workspace)"
  2. "What branch is the PR on? (leave empty to review the currently checked-out branch)"

## Step 5 — Fetch the diff

### Option A — Bitbucket API

See [REFERENCE.md → Diff Fetching](REFERENCE.md). Capture the PR title, source branch, and target branch from the metadata call (used in the Step S1 report header).

### Option B — Local repo

```bash
# If reviewing the current workspace and current branch
git diff main...HEAD            # committed changes since branching from main
git diff HEAD                   # uncommitted changes on top of that
git diff --name-only main...HEAD
git diff --name-only HEAD

# If reviewing a different repo / branch
git -C {repo_path} fetch origin
git -C {repo_path} diff origin/main...origin/{branch_name}
```

Read the full content of any changed file where the diff alone isn't enough to judge correctness (e.g. `handlers.go`, `services_factory.go` — to verify mirroring).

## Step 6 — Run the rule set

Branch on the mode chosen in Step 1.

- **Kairos mode** → run **Step 6K — Kairos checklist** below.
- **General mode** → run **Step 6G — General multi-agent flow** below.

Both modes converge on the **shared output** in Step S1, S2, and S3.

## Triage scheme (both modes)

Every finding is one of:

- **CRITICAL** — non-negotiable invariant violated; crash, data loss, security hole, goroutine leak, broken tenant isolation, missing generated artifacts. Must be fixed before merge.
- **MAJOR** — incorrect logic, missing error handling, wrong semantics, fragile pattern likely to bite in production. Should be fixed.
- **MINOR/NOTE** — style or convention drift, low-risk advisory remark. Worth addressing when convenient.

---

## Step 6K — Kairos checklist (Kairos mode)

For each finding, record it as `[SEVERITY] file.go:line — description`. Map severity per the layer mapping at the bottom of this section.

Run every check below in the reviewed tree (the branch under review; for a Bitbucket PR, its source branch). Do not flag something the component's layout or toolkit cannot have.

| The check in `../using-kairos-skills/reference/facade.md` | Run |
|---|---|
| yes (master-data facade: only `pkg/schema/` and `cmd/command-publisher/`, no runtimes, no `sql/`, no outbox) | F (master-data rows only: facade entities have no `Validate()` and no `var _ messaging.X` assertion), G, K (facade row only), L and N. Skip A–E, I, J and M. |
| no | The full checklist. |

### A. Architecture — Business Logic Placement

| `internal/services/outbound_messenger.go` exists | Apply in A and E |
|---|---|
| yes | Every row as written. |
| no | Publishing and sending from endpoints and handlers through `ctx.Sender()` is this component's layout. Skip the messenger rows (constructor, interface, adapter, fake) and do not flag `ctx.Sender().Publish` / `Send` in a handler. Still flag a swallowed `Publish`/`Send` error (MAJOR): the handler must return it. Add one NOTE that the template upgrade-file `20260724T113527-consolidate-outbound-messenger.md` (applied with `kairos-component-update`) moves publishing into services. Never ask for `internal/services/` to be created inside this change. |

- [ ] API endpoints and event handlers are **thin** — they parse input, call a service, return a response. No domain logic inside handlers.
- [ ] Services are created via `ctx.ServicesFactory()`, not instantiated directly in handlers.
- [ ] No direct repository calls from handlers (must go through a service).
- [ ] Service constructor signature is `New{Entity}Service(repo, messenger, logger)` and the struct holds a `services.OutboundMessenger` field (interface, not concrete type). See `kairos-create-service`.
- [ ] The `services` package defines a single `OutboundMessenger` interface with `Publish` and `Send` only — **no** `SendCommandResponse` (correlation-bound; lives at command handler). Find it with `grep -rln 'type OutboundMessenger interface' internal/services`; flag only more than one hit (two interfaces/adapters) or a widened interface.
- [ ] Each runtime's `ServicesFactory` (`internal/api/request/`, `internal/event-handler/request/`, and `internal/integration-api/request/` where that runtime exists) wraps `ctx.Sender()` into `OutboundMessenger` before injecting it — via `services.NewSenderAdapter(...)`, or the component's own adapter if `outbound_messenger.go` does not exist. One adapter per component, not one per runtime.
- [ ] A service added or changed in the diff is mirrored **verbatim** into the `ServicesFactory` of every runtime that calls it. Flag a factory method present in one runtime but missing from another that invokes the service. Do **not** flag a runtime that legitimately doesn't use it — an empty `type ServicesFactory struct{}` in `internal/integration-api/request/` is normal when no integration-API route needs a service.

### B. PostgreSQL & Tenant Safety

- [ ] Each repository declares its table name as a package-level constant and references that constant directly in queries.
- [ ] Every table name interpolated into SQL is wrapped in `pgx.Identifier{name}.Sanitize()` (e.g. `fmt.Sprintf("SELECT … FROM %s …", pgx.Identifier{todosTableName}.Sanitize())`). A raw `%s` table name or string concatenation is CRITICAL.
- [ ] Table names are **not** configurable — no `tableName` constructor parameter, no `AppConfig` getter (e.g. `GetXTableName()`), no environment variable.
- [ ] No explicit `WHERE tenant_id = ...` filter added to any query — the session is already tenant-scoped.
- [ ] No raw `pgx.Conn` or `pgx.Pool` used in repositories — must accept `interfaces.Session`.
- [ ] Every entity ID parsed from a string uses `entities.ParseId(id)` before being passed to SQL.
- [ ] All JSONB field names in `json:` struct tags are **camelCase** (e.g. `json:"createdAt"`, NOT `json:"created_at"`).
- [ ] All SQL table names are **snake_case** and pluralized (e.g. `orders`, `user_profiles`).
- [ ] Tables default to the **2-column** layout (`id UUID PRIMARY KEY`, `data JSONB NOT NULL`). Extra columns or aggregate splits are allowed only when the rules in skill `kairos-database-model` ("Splitting fat aggregates into child tables" / "When to add extra columns beyond `id` and `data`") are met — flag any deviation that does not.
- [ ] Extra columns (when justified) are **snake_case**, kept in sync with their corresponding **camelCase** JSONB field on every write.
- [ ] Human-facing identifiers (e.g. order numbers) are stored as **camelCase fields inside `data`** with a unique JSONB-expression index — never as a top-level column, and `id` is never repurposed for them.

### C. API Context (`internal/api/`, `internal/integration-api/`)

Both Fiber runtimes alias the same `apicontext.Context`, so every check below applies to client-API and integration-API handlers alike.

- [ ] `ctx.DatabaseSession()` return values are **both** checked: `db, err := ctx.DatabaseSession(); if err != nil { ... }`.
- [ ] `defer db.Close()` is called immediately after obtaining a session.
- [ ] Responses use the standard envelope helpers — `ctx.SuccessResponse` / `ctx.EmptySuccessResponse` / `ctx.ErrorResponse` (api ≥ v1.2.37), or `commonapi.SuccessResponse(ctx, …)` / `commonapi.EmptySuccessResponse(ctx, …)` / `commonapi.ErrorResponse(ctx, …)` on any version — not `fiber.NewError` or raw JSON writes. The two spellings write identical bytes; the `commonapi.*` functions are deprecated wrappers on ≥ v1.2.37, and using them is not a finding.
- [ ] Request bodies parsed via `ctx.ParseBody[T]()` (api ≥ v1.2.37) or `commonapi.RequestBody[T](ctx)` — not manual `ctx.Body()` + `json.Unmarshal`.
- [ ] Business logic runs under `context.WithTimeout(ctx.Context(), ...)`.
- [ ] 5xx paths do not return the raw error to the caller. `ctx.ErrorResponse(status, msg, err)` and `commonapi.ErrorResponse(ctx, status, msg, err)` copy `err.Error()` into the response body, so for a 5xx the handler logs the cause (`ctx.Logger().Error().Err(err).Msg(...)`) and passes a generic error (e.g. `errors.New("internal error")`), never `err` and never `nil` (`ErrorResponse` calls `err.Error()` and panics on `nil`). Passing `err` on a 4xx (validation, not found, conflict) is fine. A 5xx that returns `err` is MAJOR.

### D. Event-Handler Context (`internal/event-handler/`)

- [ ] `ctx.DatabaseSession()` return value is **nil-checked** (EH variant returns just `session`, not `(session, error)`).

### E. Messaging — Sender Method Usage

- [ ] **Mutate → event.** Every state mutation introduced by the diff publishes at least one `*EventV1` before returning — even when no subscriber exists today. With the messenger (see the table at the top of A), the service method calls `s.messenger.Publish(...)`; without it, the endpoint or handler that makes the mutation calls `ctx.Sender().Publish(...)`. Authoritative reference: `kairos-messaging-model` § *Domain events are the default contract*. Skipping the publish in this PR silently blocks every future cross-component subscriber.
- [ ] **Publish lives in the service, not the call site** (only when the messenger exists; see the table at the top of A). Inspect every API endpoint (`internal/api/endpoints/` and `internal/integration-api/endpoints/`), command handler (`internal/event-handler/commands/`), and event handler (`internal/event-handler/events/`) in the diff. **There must be no `ctx.Sender().Publish(...)` call** in any of these. Any such call is a CRITICAL: either the publish belongs in the service (move it) or it's a duplicate of what the service already published (delete it).
- [ ] **Saga starters live in the service too.** Cross-component `Send` calls triggered by a domain mutation belong in the service via `s.messenger.Send(...)`. A `ctx.Sender().Send(...)` call in a handler is only allowed when the handler does **not** route through a service (Row 3 / Row 4 of the HTTP-write decision table — pure cross-component triggers and self-`Send` patterns).
- [ ] **Event-carried state.** Every `*EventV1` constructed in a service carries the **full state** a reasonable subscriber needs to react — not just an `id`. State-transition events (`*StatusChangedEventV1`, `*AssignedEventV1`, etc.) include both the previous and the new value where applicable. Reject "id-only" payloads — they force subscribers to call back to the producer and break tenant isolation.
- [ ] Saga-step event handlers that mutate state publish the new aggregate's `*EventV1` — through the service method with the messenger, from the handler without it. The inbound event from another component does **not** substitute (it carries the *other* aggregate's state, not yours).
- [ ] With the messenger, a state-mutating command handler that returns a `*CommandResponseV1` does **not** publish the domain event itself — the service does that. The handler returns the response; the service publishes the event. Without the messenger, the handler publishes the event with `ctx.Sender().Publish` and still returns the response. Both messages, two distinct concerns.
- [ ] "No event" justifications in the diff are restricted to the legitimate cases in `kairos-messaging-model` (cache flips, master-data replica writes, derived read-model writes). Any other "no event" mutation is a CRITICAL.
- [ ] Events emitted with `Publish` (via `s.messenger.Publish` inside a service; `ctx.Sender().Publish` only in a component without the messenger) — **never** `Send`.
- [ ] Commands sent with `Send` (via `s.messenger.Send` inside a service, or `ctx.Sender().Send` for handler-only triggers) — **never** `Publish`.
- [ ] Command responses sent with `ctx.Sender().SendCommandResponse(...)` — at the handler, never inside a service. `OutboundMessenger` deliberately does not expose `SendCommandResponse`.
- [ ] No manual `SendCommandResponse` in a handler that already returns a typed `*XCommandResponseV1` (would double-send).
- [ ] Service tests assert published events — count, concrete type, full event-carried-state payload, partition key. If `internal/services/test/fake/outbound_messenger.go` exists, they use `fake.NewFakeMessenger()`. Otherwise accept the component's own fake or mock of its messenger interface (or of `messaging.Sender`); do not flag the missing template fake. Handler tests (apitest / eventhandlertest) do **not** assert domain-event publishing — that's the service test's responsibility.

### F. Message Schemas (`pkg/schema/`)

- [ ] Every `*CommandV1` type has a compile-time assertion: `var _ messaging.Command = (*commands.CommandMessage[*XCommandV1])(nil)`.
- [ ] Every `*EventV1` type has: `var _ messaging.Event = (*events.EventMessage[*XEventV1])(nil)`.
- [ ] Every `*CommandResponseV1` type has: `var _ messaging.CommandResponse = (*commands.CommandResponseMessage[*XCommandResponseV1])(nil)`.
- [ ] `Validate(ctx context.Context) error` is implemented on every schema type.
- [ ] `ComponentName() string` is implemented on every schema type and returns the package-level `ComponentName` constant.
- [ ] Command names are **imperative** (`CreateOrder`, `UpdateProfile`) — NOT past-tense.
- [ ] Event names are **past-tense** (`OrderCreated`, `ProfileUpdated`) — NOT imperative.
- [ ] Event names come from a **domain verb**, not from a field name. `IssueClosedEventV1` / `IssueAssignedEventV1` / `IssueReopenedEventV1` — not `IssueStatusChangedEventV1 { newStatus: ... }` or `IssueUpdatedEventV1 { fields: {...} }`. Generic transition events with a discriminator field are N events fused into one and force every subscriber to filter in code. See `kairos-create-event` § *Prefer specific events over generic transition events* for the narrow exception (genuinely user-configurable state machines).
- [ ] Schema file names are **kebab-case** (`order-create-command-v1.go`, `order-created-event-v1.go`).
- [ ] JSON tags inside schema structs are **camelCase**.

### G. Schema Versioning (if existing schemas were changed)

- [ ] No breaking changes (field removal, rename, type change, validation tightened, semantics shifted) were made to an existing `V{N}` schema.
- [ ] If a breaking change was genuinely needed: a new `V{N+1}` file exists, the old version has `// Deprecated:` doc comment, and both are produced/handled in parallel.
- [ ] When uncertain whether a change is breaking — **stop and ask the user**.

### I. Entity Mutation

- [ ] Mutations use `entity.ForUpdate()` to bump ETag and UpdatedAt together — ETags and timestamps are never set manually.
- [ ] Repository `Update` methods on aggregate roots enforce ETag-based optimistic concurrency: the SQL `WHERE` clause matches both `id` AND the caller-supplied ETag, and a "0 rows affected" result is surfaced as a concurrency-conflict error — never a silent no-op. (Deliberate last-write-wins paths like master-data upserts and idempotency upserts are exempt — flag them only if the intent is unclear from context.)

### J. Handler Registration

- [ ] New command handlers are registered in `internal/event-handler/handlers.go` with `eventhandler.CommandHandler(...)`.
- [ ] New event handlers are registered with `eventhandler.EventHandler(...)`.
- [ ] New command response handlers are registered with `eventhandler.CommandResponseHandler(...)`.
- [ ] New master data mappers are registered with `eh.Sync(eventhandler.MasterData[*T]())`.
- [ ] `+kairos:sql:lib:` directives are **intact** (not deleted or modified): the `nga-event-outbox/pkg/eventsender` directive in `cmd/client-api/main.go` and `cmd/integration-api/main.go` (whichever of those the component has — the current template ships both), and the `kairos-component-common/event-handler` directive in `cmd/event-handler/main.go`.

### K. Generated Files

- [ ] If `pkg/schema/`, `internal/event-handler/handlers.go`, `internal/domain/`, any scanned package, or a `+kairos:sql:` directive changed, `make generate` must have been run and its output changes must be in the diff. `<chart>` is `chart/` if it exists, else `charts/`. The scanned packages depend on the toolkit (`go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/toolkit`): from v1.0.49, every `cmd/<app>/` plus all of `internal/` (topics from the same set); below v1.0.49, a fixed list (`internal/event-handler`, `cmd/event-handler`, `cmd/client-api`, `internal/domain`, `pkg/schema`), and topics come from the same fixed list, so an `internal/api/` change needs no `topic-config.json` change. Expect only the outputs this component produces:

  | Output | Produced when |
  |---|---|
  | `<chart>/resources/topic-config.json`, `pkg/json-schema/`, `sql/1.gen/`, `sql/0.libs/`, the `jobVersion` in `<chart>/templates/db-script-runner.yaml` | Every toolkit, except a facade (see below) |
  | `<chart>/resources/component-config.json`, `pkg/asyncapi/asyncapi.yaml` | toolkit ≥ v1.0.49 |
  | `<chart>/resources/masterdata-entities.json` | toolkit ≥ v1.0.49, or `.init.mk` includes `masterdata-cdc.mk`; and `pkg/schema/` contains a `MasterDataEntityBase` type |
  | `internal/integration-api/loaders/generated/` | toolkit ≥ v1.0.49 and `cmd/integration-api/` exists |
  | `pkg/openapi/` | toolkit ≥ v1.0.49 and `internal/integration-api/openapi.go` exists |
  | Facade (see the table at the top of Step 6K) | Only `pkg/json-schema/` and `<chart>/resources/masterdata-entities.json` |

  If `.init.mk` or the `Makefile` sets `GENERATE_MODULES` to a list (not `all`), only the listed modules run. Do not flag an output the component's toolkit or layout cannot produce.
- [ ] If generated files are absent from the diff but should have changed, flag as a CRITICAL.

### L. Security

- [ ] No hardcoded secrets, tokens, passwords, or connection strings anywhere in the diff.
- [ ] Error messages returned to callers do not leak internal implementation details: no stack traces, SQL text, internal state or tenant IDs (see the 5xx row in C).
- [ ] Log messages do not leak business data. Entity IDs, correlation IDs and tenant IDs are fine in operational logs; names, emails, payloads and any other PII are not.
- [ ] The tenant comes from `ctx` only. A tenant ID read from a request body, query parameter or path is CRITICAL.
- [ ] Authentication context is propagated via `ctx` — not re-fetched from environment or global state.
- [ ] No template placeholders left uninstantiated (`<YOUR_COMPONENT_NAME>`, `<COMPONENT_NAME>`, `YOUR_COMPONENT_NAME`).

### M. Tests

- [ ] New service methods and repository methods have corresponding tests.
- [ ] Tests use `mocks.NewMockSession()` from `bitbucket.org/ifs-pd/nga-common/postgres/client/mocks` — not `pgxmock`.
- [ ] JSONB scan expectations use `mock.Run(func(args mock.Arguments){...})` to write into pointer args.
- [ ] `mockSession.AssertExpectations(t)` (and `mockRow`, `mockRows`) called at the end of each test.
- [ ] Error paths are tested, not only the happy path.
- [ ] Test function names follow `Test{Subject}{Scenario}` — no underscores in function names.
- [ ] No tests for whether a type implements an interface (compile-time `var _ X = ...` assertions do that).

### N. General Go Quality

- [ ] No `fmt.Println` / `log.Println` — structured logging via `ctx.Logger()` only.
- [ ] No unused imports, variables, or parameters that would cause lint failures.
- [ ] File names follow snake_case for Go files, kebab-case for schema files.

**Severity mapping**:

- Sections **B, C, D, E, H, J, K, L** — failures default to **CRITICAL**.
- Sections **A, F, G, I, M** — failures default to **MAJOR** unless they also break an invariant in B/C/D/E/H/J/K/L.
- Section **N** and pure style drift — **MINOR/NOTE**.

Continue to **Step S1 — Report**.

---

## Step 6G — General multi-agent flow (General mode)

### G1. Slice the diff by file type

Each file section starts with `diff --git a/path b/path`. Split into three slices:

- **Code slice** — `.go`, `.ts`, `.tsx`, `.py`, `.sh`, `.bash`, `Makefile`.
- **Infra slice** — `Dockerfile`, `.yaml`/`.yml` in `chart/` or `charts/`, `k8s/`, `deploy/`, `manifests/`, `.github/`.
- **Security slice** — full diff (security issues are cross-cutting).

Detect languages present in the code slice and infra tech in the infra slice.

### G2. Spawn agents in parallel

Always spawn:

- **Code Agent** — code slice + detected language list. See [REFERENCE.md → Code Agent](REFERENCE.md).
- **Security Agent** — full diff. See [REFERENCE.md → Security Agent](REFERENCE.md).

Spawn only if the infra slice is non-empty:

- **Infrastructure Agent** — infra slice. See [REFERENCE.md → Infrastructure Agent](REFERENCE.md).

Each agent must report findings using **CRITICAL / MAJOR / MINOR** only.

### G3. Validate

Pass all findings to the **Validator Agent** — see [REFERENCE.md → Validator](REFERENCE.md). Validator rejects clear no-ops and re-triages over-inflated severities.

Continue to **Step S1 — Report**.

---

## Shared Output

## Step S1 — Report

Display the final list as a numbered, severity-grouped report:

```text
## Review — <PR title or branch name>

### CRITICAL
[1] CRITICAL | <category> | <file>:<line> — <explanation>
[2] CRITICAL | <category> | <file>:<line> — <explanation>

### MAJOR
[3] MAJOR | <category> | <file>:<line> — <explanation>

### MINOR/NOTE
[4] MINOR | <category> | <file>:<line> — <explanation>

### Passed (Kairos mode only — actively verified)
- JSONB field naming (camelCase)
- ServicesFactory mirrored across the runtimes that use it
- Tenant isolation (no manual WHERE tenant_id)
```

Rules:

- Number every issue starting from `[1]` across all severities, so the user can refer to any issue by a single number in the deep-dive step.
- Group by severity in display order: **CRITICAL → MAJOR → MINOR/NOTE**.
- "Passed" entries are Kairos-mode only. List only categories actively verified; do not list every section.
- If there are **no CRITICAL or MAJOR findings**, say so explicitly: "No CRITICAL or MAJOR findings — changes look good to merge."

## Step S2 — Interactive deep-dive

After printing the report, prompt:

```text
Enter an issue number for a deep-dive, or 'done' to finish.
```

When the user enters a number, ALWAYS produce a response with these three sections, in this order:

1. **Offending code** — a code reference block that points to the exact lines in the file. Use the format below (no language tag, line range required):

   ```startLine:endLine:filepath
   // actual code from the file
   ```

   Read the file with the Read tool first if you do not already have the lines cached. Show 2–4 lines of surrounding context above and below the flagged line so the issue is visible in situ. (For Bitbucket-only flows where the local file is not checked out, embed the relevant diff hunk in a fenced code block tagged `diff` instead.)

2. **Why it matters** — one or two sentences explaining the concrete harm (crash, data loss, leak, broken invariant, etc.). No generic platitudes.

3. **Suggested fix** — a markdown code block (with a language tag) showing the proposed code. This is new/proposed code, so it MUST use a language-tagged fence, NOT a code reference:

   ```go
   // proposed replacement
   ```

Never answer a deep-dive request with prose alone — both the offending code reference (or diff hunk) and the suggested-fix code block are mandatory. If the issue spans multiple files, repeat sections 1 and 3 once per file.

After answering, prompt again. Loop until the user replies `done`.

## Step S3 — Post comments (only when Bitbucket API was selected)

If — and only if — the user chose **Option A (Bitbucket API)** in Step 2, ask once after the deep-dive loop ends:

```text
Post comments to this PR? (yes / no)
```

If yes, ask: "Include: (1) all issues  (2) CRITICAL + MAJOR only  (3) specific numbers"

Post each selected issue as an inline comment anchored to its file and line — see [REFERENCE.md → Posting Inline Comments](REFERENCE.md). Post in order CRITICAL → MAJOR → MINOR. This applies to Kairos mode and General mode equally.

If the user chose **Option B (Local repo)** in Step 2, skip Step S3 entirely (no PR to post to). Optionally offer to print the formatted comment text for manual copy-paste.

## Rules (apply to both modes)

- Never surface an issue without a file path and a line number from the diff.
- Agents in General mode must not report issues outside their assigned domain (e.g. Code Agent does not flag Kubernetes manifests).
- Skip the Infrastructure Agent entirely if no infra files are in the diff.
- Severity definitions (CRITICAL / MAJOR / MINOR/NOTE) are identical across modes — do not invent new tiers.
- The interactive deep-dive (Step S2) is mandatory in both modes; do not skip it even when the report is short.
- Posting inline comments (Step S3) is gated on the Bitbucket API access method, not on the mode.
