---
name: kairos-create-command-response
description: Creates a new Kairos command response schema in pkg/schema/ — the reply **YOUR component returns after handling an incoming command** it owns. Covers success/failure indicators, validation, and ComponentName routing. Schema is owned by the responder (same component as the matching command handler); the sender component imports it to handle the reply. Use when adding a *CommandResponseV1 paired with a command your component handles, implementing the responder side of a request-reply pattern, or when the user says "add a command response", "create response schema", or "request-reply". Do NOT use this for responses your component receives after sending a command — those are consumed by writing a handler (see kairos-create-command-response-handler).
---

# Create a Kairos Command Response

Command responses let a component reply to a command, enabling request-reply patterns in an otherwise event-driven architecture. If the issuer does **not** need a reply, skip this skill — the command handler can publish an event instead.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## File location & naming

- **Location**: `pkg/schema/{entity-name}-{action}-command-response-v{version}.go`
- **Type name**: `{Action}{Entity}CommandResponseV{Version}` — the same name as the command it responds to, with `Response` inserted before the version number.

| Command | Response |
|---|---|
| `CreateExampleCommandV1` | `CreateExampleCommandResponseV1` |
| `ProcessPaymentCommandV1` | `ProcessPaymentCommandResponseV1` |

❌ `CreateOrderResponseV1` (missing "Command")
❌ `OrderCreatedResponseV1` (wrong verb form)

## Template

**Field tags below are shown in swag form. Whether they shape `pkg/json-schema/` depends on the kairos-gen version — see § JSON Schema field annotations; below v0.1.0 put the same constraints on `+kairos:schema:*` comment lines instead.**

```go
package schema

import (
	"context"

	"bitbucket.org/ifs-pd/kairos-component-common/common/messaging"
	"bitbucket.org/ifs-pd/kairos-component-common/common/messaging/commands"
	"bitbucket.org/ifs-pd/nga-common/validation"
	"bitbucket.org/ifs-pd/nga-common/validation/check"
	"bitbucket.org/ifs-pd/nga-common/validation/runner"
)

var _ messaging.CommandResponse = (*commands.CommandResponseMessage[*CreateExampleCommandResponseV1])(nil)
var _ messaging.MessagePayload = &CreateExampleCommandResponseV1{}

// CreateExampleCommandResponseV1 is the response for CreateExampleCommandV1.
type CreateExampleCommandResponseV1 struct {
	ExampleId string `json:"exampleId" validate:"required"`
	Success   bool   `json:"success"`
	Message   string `json:"message,omitempty"`
	CreatedAt string `json:"createdAt,omitempty"`
}

var createResponseValidator = validation.New(func(c *CreateExampleCommandResponseV1, r *runner.Runner[*CreateExampleCommandResponseV1]) {
	check.StringField(r, "ExampleId", c.ExampleId).
		NotEmpty("example_id cannot be empty")
})

func (r *CreateExampleCommandResponseV1) Validate(ctx context.Context) error {
	return messaging.Validate(ctx, createResponseValidator, r)
}

func (r *CreateExampleCommandResponseV1) ComponentName() string {
	return ComponentName
}
```

## First schema in this module

If `pkg/schema/go.mod` does not yet require `bitbucket.org/ifs-pd/kairos-component-common/common`, this is the module's first schema type and it needs `go mod tidy`. Pin `common` to the root module's version first:

1. In the component root, read the version: `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/common`.
2. In `pkg/schema/`, run `go get bitbucket.org/ifs-pd/kairos-component-common/common@<that version>`, then `go mod tidy`.

An unpinned tidy takes `common@latest`. Through the root's `replace` of `pkg/schema`, that can lift the whole component across common v1.4.0, which raises the Go floor to 1.27.2 and breaks `eventhandlertest` on event-handler < v1.2.44. Afterwards re-read `common`, `api` and `event-handler` with `go list -m` in the root and re-run any version checks. If `pkg/schema/go.mod` already requires `common`, skip this step.

## Required elements checklist

- [ ] File name follows `{entity-name}-{action}-command-response-v{version}.go`
- [ ] Type name mirrors the command with `Response` inserted before the version
- [ ] Compile-time assertions: `messaging.CommandResponse` and `messaging.MessagePayload`
- [ ] Include a `Success bool` plus an optional `Message string` (`omitempty`) for error details
- [ ] Include a correlation/reference field (e.g. `ExampleId`, `OrderId`) so the issuer can correlate the reply
- [ ] `Validate(ctx)` and `ComponentName()` implemented
- [ ] Optional fields use `omitempty`
- [ ] Read the kairos-gen version (see below) and annotated fields accordingly (swag tags on ≥ v0.1.0, else `+kairos:schema:*`)

## JSON Schema field annotations

`kairos-gen` builds `pkg/json-schema/` (and AsyncAPI payloads) from field annotations.

Which annotations it reads depends on the kairos-gen version. If `go.mod` has a `cmd/kairos-gen` line, read `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen`; otherwise run `kairos-gen --version` (`(devel)` or a failure is unknown).

| kairos-gen | What to do |
|---|---|
| ≥ v0.1.0 | **Prefer swag struct tags**, whether or not `internal/integration-api/openapi.go` exists. Author with `validate` / `binding` (`required`, `optional`, `min`/`max`, `gte`/`lte`, `gt`/`lt`, `len`, `oneof`, `unique`), plus `enums`, `format`, `default`, `example` (→ draft-07 `examples` array), `swaggertype`, `swaggerignore`. Do **not** emit a parallel `+kairos:schema:*` for a constraint a tag already expresses. Use a Kairos directive only as an escape hatch (no tag maps to the keyword, or the messaging schema must diverge from Swagger). Directives always win per key when both are present. On `kairos-component-common/toolkit` ≥ v1.0.49 a field is optional unless it has `validate:"required"` or `+kairos:schema:required`; on older toolkits fields are required by default. |
| < v0.1.0 or unknown | **Use `+kairos:schema:*` comment directives only.** This generator reads no struct tags, so `validate`/`enums`/… do not shape `pkg/json-schema/`. |

`internal/integration-api/openapi.go` only decides whether `make generate` also emits `pkg/openapi/`; don't add it to change the annotation style.

**Precedence (≥ v0.1.0):** Go type inference → swag tags → `+kairos:schema:*`. Route `@Param` / `@Success` comments are never consulted.

Orthogonal to runtime `Validate()` — annotations shape the generated contract; `Validate()` enforces at send/receive. Full tables: `kairos-gen` README (`#kairos-schema-directives`).

## Progressive response pattern

For long-running operations a handler may send multiple responses on the same correlation key (`status: "accepted" → "in_progress" → "completed"`). The schema captures the status field and any partial-result fields; the handler emits each response via `ctx.Sender().SendCommandResponse(...)`.

```go
type ProcessCommandResponseV1 struct {
    Status string `json:"status" validate:"required,oneof=accepted in_progress completed"`
    JobId  string `json:"jobId" validate:"required"`
    Result string `json:"result,omitempty"`
}
```

## Versioning

**The command request and the command response are independent APIs and version independently.** A breaking change to the request payload does not, by itself, require a new response version — a V2 command handler may still reply with the existing `*CommandResponseV1` if the response shape is unchanged. Conversely, a breaking change to the response payload requires a new `*CommandResponseV2` even if the command schema is untouched; the V1 handler keeps replying with V1 and the V2 handler replies with V2. Full breaking-vs-non-breaking rules and the deprecation template live in `pkg/schema/AGENTS.md` (Versioning Policy). **If uncertain whether a change is breaking, ask the user.**

## After finishing

Run `make generate`. For a command response it regenerates `pkg/json-schema/` from the new schema; it adds nothing to `topic-config.json` or `component-config.json` — the reply travels to the requester's own topic, and requesters subscribe to nothing for it. Commit what changed.

## Common mistakes (RED FLAGS)

- Missing `Response` in the type name (`CreateExampleResponseV1`)
- No correlation field → issuer cannot match reply to request
- Required fields without `omitempty` that are only populated on success (validation then fails on error responses)
- snake_case JSON tags
