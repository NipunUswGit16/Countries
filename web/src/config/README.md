# Config Directory

This directory contains application-level configuration files. All files are
heavily documented with inline comments - refer to the source files directly for
detailed property descriptions and examples.

## Files

- **`app.config.ts`** - Defines the application shell: header title, home button
  toggle, navigation menus (left sidebar), apps menu (app switcher in the header
  for navigating between bounded contexts), profile dropdown menu, additional
  toolbar buttons with optional badge notifications, and an optional
  `onMenuItemClicked` callback for handling custom menu item clicks. Can be
  updated dynamically at runtime via the `useAppConfig()` hook (e.g. updating
  button badge counts). The `onMenuItemClicked` callback receives events for any
  menu item not handled by the built-in logic (sign-out, notifications, theme
  switching, language switching, and route navigation) — use it for custom items like app switcher
  entries, help buttons, or profile actions.
- **`routes.ts`** - Defines all application routes declaratively. Each route
  maps a URL path to a React component. Nested routes are defined as `children`
  of a parent route. The `basename` is automatically derived from Vite's
  `BASE_URL` so routes work correctly when deployed to a subpath. New pages must
  be registered here as children of the `AppShell` route. Authentication is
  enforced by the auth-gateway and the HTTP 401 redirect configured in
  `main.tsx`.
- **`i18n.ts`** - Template entry point for `@ifs-kairos/translation`. Loaded
  from `main.tsx` before render; import `t` and locale helpers from here in app
  code. See `@ifs-kairos/translation` for initialization and APIs.
- **`locales.ts`** - Locale codes and display names for this app; update when
  adding or removing languages.
- **`response.config.ts`** - **Application response configuration** for
  **`@ifs-kairos/response`**: the BC's server-response catalog (envelope
  **`message`**/**`messageId`** → translator, registered with
  **`registerServerResponses`** as a module-load side effect — ships empty in
  the template, each bounded context adds its own entries), an ordered list
  of rules in **`customResponseRules`** driven by **2xx** HTTP responses from
  **`@ifs-kairos/net`**, and an optional **`clientResponseRule`** block for
  browser-global **`window` `error`** only. Also exports **`responseConfig`**,
  the plain config object passed to `initializeResponseOrchestration` in
  `main.tsx`.

## Response orchestration (`response.config.ts` + `main.tsx`)

`@ifs-kairos/response` covers both error (`>=400`) and server-response (2xx)
orchestration through the same `customResponseRules`/`trigger` model, plus the
server-response catalog. `@ifs-kairos/net`'s `notifyHttpResponse` dispatches
every HTTP response through it.

`main.tsx` calls **`initializeResponseOrchestration(responseConfig)`**
**before** **`createRoot(...).render`** so the first HTTP response and the
first uncaught client error see the configured rules.

- `@ifs-kairos/response` does not render toasts, dialogs, or other UI. It
  runs the **action pipeline** and invokes the **`notifyUserCallbacks`** you
  set on each rule.

## AI Assistant Instructions

When modifying configuration:

1. **Adding a new page** - Add a route in `routes.ts` inside the `AppShell`
   children, then optionally add a menu item in `app.config.ts`. Follow the
   existing patterns in both files.
2. **Adding menu items** - Follow the existing patterns in `app.config.ts` for
   icons and route data. For items that should navigate within the app, include
   a `data: { route: '/path' }` property. For custom items without a route (e.g.
   app switcher entries, help), handle them in the `onMenuItemClicked` callback.
3. **Keep imports organized** - Import page components at the top of
   `routes.ts`.
4. **Changing auth settings** - Keep auth-gateway base path configuration in
   `main.tsx`; do not add frontend OIDC secrets or token storage.
5. **Customizing notifications** - Replace or remove the seed data in
   `notifications.config.ts` once you integrate a real notification source.
6. **Message/error handling rules** - Edit `response.config.ts`: add **2xx**
   server-response entries to `serverResponses`/`customResponseRules`, and
   update `clientResponseRule` for browser-global `window` `error` handling.
   It exports `responseConfig`, passed directly to
   `initializeResponseOrchestration` in `main.tsx` before `createRoot`.
