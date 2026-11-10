---
name: response-library
description: Add a translated server status message (Kairos response envelope with `messageId`/`messageParams`) to a React web app built from the Kairos template, using `@ifs-kairos/response`. Use when the user asks to register a server response, add a response/status toast for an endpoint, add HTTP-status rules (403/404/422) to `response.config.ts`, or wire the response library into the web app. For the Go endpoint that emits the envelope, use the `response-library-go-endpoint` skill.
---

# Response Library (React template)

Frontend side of the Kairos response envelope.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

Run the checks in `using-kairos-web-skills` § Before you start first; stop where they stop. Then, in the component root:

| Check | Result | Follow |
|---|---|---|
| `test -f web/src/config/response.config.ts` | succeeds | The response library is wired. Continue with [§ Ask before changing endpoints](#ask-before-changing-endpoints). |
| `test -f web/src/config/error.config.ts` | succeeds (and the first check failed) | The app predates the response library. Do [§ Existing `@ifs-kairos/error` config](#existing-ifs-kairoserror-config) first, then continue. |
| both fail | — | Stop. The frontend has neither library. Tell the author to update the frontend with `kairos-component-update`; don't wire it by hand in this task. |

A wired app has:

- `src/config/response.config.ts` — the `serverResponses` catalog, response
  rules, and usually a `clientResponseRule` for uncaught `window` errors.
- `src/main.tsx` — calls `initializeResponseOrchestration(responseConfig)`
  before render. Nothing to change there for new messages.

`@ifs-kairos/net` dispatches every HTTP response through response
orchestration; a rule fires when its `trigger` returns true. Read
`response.config.ts` first — it is the source of truth for this app.

## Ask before changing endpoints

Not every endpoint needs an envelope. Only add catalog entries for the
messages the developer names (e.g. "Order {{OrderId}} was created"). If they
haven't said which, ask. Don't invent message IDs.

## Add a server response

1. **Message ID** — `SCREAMING_SNAKE_CASE` outcome name (`ORDER_CREATED`). It
   must match the Go `MessageId` constant exactly.
2. **Catalog entry** — add to the existing `serverResponses` object in
   `src/config/response.config.ts` (don't recreate the file). Use the
   two-string `i18n.t(key, default, params)` form so the i18next extractor
   can find it, and the `status.<MESSAGE_ID>` key convention:

   ```ts
   const serverResponses = {
     ORDER_CREATED: (params) =>
       i18n.t('status.ORDER_CREATED', 'Order {{OrderId}} was created', params),
   } as const satisfies Record<string, ServerResponseResolver>;
   ```

   The catalog is registered once at module load; adding a key needs no other
   wiring. Resolvers run when the toast shows, so locale switches work.
3. **Locale files** — add the key to `src/locales/<lang>/translation.json` for
   every locale listed in `src/config/locales.ts`, nested as
   JSON (`status` → `ORDER_CREATED`).
   If `grep -q "status\.\*" web/i18next.config.ts` succeeds, `status.*` keys
   survive the extractor: run `pnpm -C web i18n:extract` if `web/package.json`
   has that script, otherwise `pnpm -C web exec i18next-cli extract`.
   If it fails, the extractor would prune the new keys: edit the JSON by hand
   and don't run it.
4. **Which rule shows it**
   - **2xx** — if `grep -q httpSuccessRule web/src/config/response.config.ts`
     succeeds, the template's `httpSuccessRule` already handles it (2xx plus a
     non-empty resolved message → `showSuccess`). Nothing more to add.
     Otherwise read `response.config.ts` for a rule that triggers on 2xx; if
     there is none, add one in the style of the non-2xx rule below, with a
     2xx `trigger` and `showSuccess`.
   - **Non-2xx** (e.g. 422 business-rule rejection) — a catalog entry alone
     does nothing. Add a `createCustomResponseRule` scoped to that status:

     ```ts
     import { showError } from '@ifs-ds/helix-web-components/base';

     const businessRuleRejectedRule = createCustomResponseRule<HttpError>({
       trigger: (response) =>
         response.status === 422 && envelopeResponse(response, '').length > 0,
       logToConsole: true,
       notifyUser: true,
       notifyUserCallbacks: [
         (response) => {
           void showError(
             envelopeResponse(response, ''),
             i18n.t('status.toast.error', 'Error'),
           );
         },
       ],
     });
     ```

     then add it to `customResponseRules` in `responseConfig`. Add the
     `status.toast.error` key to the locale files.

## HTTP-status toasts (403/404/5xx)

The template deliberately ships without them (401 is handled by
`configureAuth` + `configureRest({ onUnauthorized: redirectToLogin })` in
`main.tsx`). Ask whether the developer wants them. If yes, add one
`createCustomResponseRule` per status in the same style as above, with
BC-appropriate i18n keys and wording.

## Existing `@ifs-kairos/error` config

Applies when `web/src/config/error.config.ts` exists and
`web/src/config/response.config.ts` does not. Leave the
`error.config.ts` / `initializeErrorOrchestration` call as is and add `@ifs-kairos/response` (same version as other
`@ifs-kairos/*` deps), a `response.config.ts` and an
`initializeResponseOrchestration(responseConfig)` call before render — both
run side by side. Don't add a second `clientResponseRule` (it would double-fire
with the error config's). Consolidating into one config (the merge pattern
commented in `main.tsx`) only when asked.

## Don't

- Don't invent another envelope shape; only top-level `messageId` (or
  `message`) plus `messageParams` is recognized.
- Don't add a second notification mechanism; use Helix's `showSuccess` /
  `showError` (or `showToast`, matching what the app already uses).
- Don't convert existing handlers' responses beyond the endpoints named.

## Checklist

- [ ] Catalog key matches the Go `MessageId` constant exactly.
- [ ] Locale JSON updated for every supported locale.
- [ ] Non-2xx messages have a status-scoped rule in `customResponseRules`.
- [ ] `pnpm build` / typecheck passes; trigger the endpoint and see the toast.
