---
name: response-library-go-endpoint
description: Make a Go Client API endpoint in a Kairos component emit a response envelope (`{"messageId", "messageParams"}`) that the web app's `@ifs-kairos/response` turns into a translated toast. Use when the user asks for an endpoint to return a specific translated/parameterized status message, or a success/error response envelope. Pair with the `response-library` skill for the frontend catalog entry.
---

# Response envelope — Go endpoint

Most endpoints keep using the component's generic helpers
(`ctx.SuccessResponse` / `ctx.ErrorResponse`, or `commonapi.SuccessResponse` /
`commonapi.ErrorResponse` on `kairos-component-common/api` < v1.2.37). Use the envelope
**only** for endpoints the developer names that need a specific translated,
parameterized message. If they haven't named endpoints, ask — don't convert
handlers wholesale.

The envelope is read by the web app, so the endpoint is on the client API
(`internal/api/`); integration-API endpoints don't use it. Build the handler
with skill `kairos-create-api-endpoint` (request type, DB session, service call,
timeout, 5xx error handling); only the success and business-rule responses
change. Those are the exception to its "responses go through the standard
helpers" rule.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Steps

1. **Message ID** — a Go `const` next to the handler, `SCREAMING_SNAKE_CASE`
   (`ORDER_CREATED`). Never a magic string. The frontend catalog key must
   match it exactly.
2. **Handler** — write the body directly; no envelope helper exists in
   `kairos-component-common` yet (don't add one in this task):
   - success: `ctx.Status(fiber.StatusOK).JSON(fiber.Map{...})`
   - business-rule rejection: `fiber.StatusUnprocessableEntity` (422) with the
     same shape.
   Unexpected failures (DB session, service errors) stay on
   `ctx.ErrorResponse` (or `commonapi.ErrorResponse` on api < v1.2.37) with
   `errInternal`, as in `kairos-create-api-endpoint`.
   For swag, annotate the envelope outcomes as
   `@Success 200 {object} map[string]interface{}` and
   `@Failure 422 {object} map[string]interface{}` instead of
   `commonapi.ResponseBody`.
3. **Route** — register it in `internal/api/routes.go` wrapped in
   `api.Handler(...)` (`kairos-create-api-endpoint` § Route registration).
4. **Test** — write it with skill `kairos-test-api-endpoint`, and assert
   `body["messageId"]` and `body["messageParams"]`, not just the status code.
5. **Frontend** — add the catalog entry, locale keys and (for non-2xx) a
   status-scoped rule via the `response-library` skill.

## Templates

```go
// OrderCreatedMessageId is the Kairos response-envelope message id. The web
// app registers a translator for it in `serverResponses`.
const OrderCreatedMessageId = "ORDER_CREATED"

// ... after persisting, instead of ctx.SuccessResponse / commonapi.SuccessResponse:
return ctx.Status(fiber.StatusOK).JSON(fiber.Map{
	"messageId": OrderCreatedMessageId,
	"messageParams": fiber.Map{
		"OrderId": created.Id.String(),
	},
})
```

Error outcome:

```go
const OrderCreateFailedMessageId = "ORDER_CREATE_FAILED"

return ctx.Status(fiber.StatusUnprocessableEntity).JSON(fiber.Map{
	"messageId":     OrderCreateFailedMessageId,
	"messageParams": fiber.Map{"Name": req.Name},
})
```

`messageParams` keys must match the `{{Name}}` slots in the frontend's
default/translated text (case-sensitive).

Body assertions, inside a `kairos-test-api-endpoint` test:

```go
var body map[string]any
require.NoError(t, json.NewDecoder(resp.Body).Decode(&body))
assert.Equal(t, OrderCreatedMessageId, body["messageId"])
params, ok := body["messageParams"].(map[string]any)
require.True(t, ok, "messageParams should be an object")
assert.Equal(t, "42", params["OrderId"])
```

## Don't

- Don't nest the envelope under `data` or use `code` instead of `messageId`;
  the frontend only recognizes top-level `messageId`/`message` +
  `messageParams`.
- Don't change `SuccessResponse`/`ErrorResponse` call sites (either spelling)
  for endpoints that weren't named.

## Checklist

- [ ] Go const matches the frontend catalog key exactly.
- [ ] Handler test asserts `messageId` and `messageParams`.
- [ ] Non-2xx outcome has a matching frontend rule (see `response-library`).
