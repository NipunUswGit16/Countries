---
name: kairos-web-auth
description: Wires or adjusts auth-gateway authentication in Kairos frontend apps (`@ifs-kairos/auth`). Use when the user mentions frontend auth, auth-gateway, authBasePath, AUTH_BASE_PATH, login, logout, 401 redirects, Callback routes, ProtectedRoute, useAuth access tokens, bearer headers, or temp-auth / temporary-auth / initializeAuth in a Kairos web app.
---

# Kairos Web Auth

Use this skill to wire or adjust auth-gateway authentication in a Kairos frontend
app. The auth libraries are framework agnostic and can be used from React,
Angular, Next.js, plain TypeScript, and other frontend runtimes.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

- If `chart/templates/client-api/auth-gateway-config.yaml` (or
  `charts/templates/client-api/auth-gateway-config.yaml`) does not exist, the
  backend has no auth-gateway. Stop and run `kairos-auth-gateway-migration`
  first, then come back. Otherwise continue.
- If `@ifs-kairos/react` in `web/package.json` is missing or below 0.10.0 (the
  version check in `using-kairos-web-skills`), or `web/src/main.tsx` still
  imports `@ifs-kairos/react/temporary-auth`, the app is on temp-auth and below
  the supported frontend. Stop and tell the author to update the frontend with
  `kairos-component-update`. Do not hand-migrate it.

## Required companion skills

- Invoke `using-kairos-web-skills` first for frontend routing.
- Invoke `kairos-web-call-api` when touching REST hooks.
- Invoke `kairos-web-create-route` when touching React route config such as
  `web/src/config/routes.ts`.

## Target model

Auth-gateway owns login, logout, OAuth callback handling, session cookies, and
401 redirects. Frontend code configures gateway redirects once at bootstrap and
then calls APIs without bearer-token headers.

```ts
import { configure as configureAuth, redirectToLogin } from '@ifs-kairos/auth';
import { configureRest } from '@ifs-kairos/net/rest';

configureAuth({
  basePath: import.meta.env.BASE_URL,
  authBasePath: window.__ENV__.AUTH_BASE_PATH,
});
configureRest({ onUnauthorized: redirectToLogin });
```

For non-Vite apps, pass the framework's equivalent deployed base path. For
Next.js, run this browser-only during client bootstrap, not during server render.

## Auth base path

The gateway lives at `<basePath>/<authBasePath>/login`. Which `authBasePath`
applies depends on the chart. Run:

```bash
grep -q '"subPath" "/client"' chart*/templates/client-api/ingress.yaml
```

| client-api ingress has `"subPath" "/client"` | Gateway path | `AUTH_BASE_PATH` |
|---|---|---|
| yes | `client/auth/v1` | required (`client/auth/v1`, from the chart's web env) |
| no | `auth/v1` | must be `auth/v1`. With `kairos-components-common` ≥ 0.6.0 (the dependency version in `chart*/Chart.yaml`) the chart never emits it empty: it defaults to `client/auth/v1` (and `API_BASE_PATH` to `client/api/v1`), a path nothing serves without the subPath. Set `web.authBasePath: auth/v1` and `web.apiBasePath: api/v1` in the chart values. Below 0.6.0 the chart emits no `AUTH_BASE_PATH`, so the library default `auth/v1` applies. |

Then check the auth library: `jq -r '.dependencies["@ifs-kairos/auth"]' web/package.json`.

| `@ifs-kairos/auth` | Configure |
|---|---|
| ≥ 0.11.0 | `authBasePath: window.__ENV__.AUTH_BASE_PATH`, as in the target model. Keep it even when the env value is empty. |
| 0.10.x | `authBasePath` does not exist (TS2561). With the `/client` subPath, pass `loginPath: 'client/auth/v1/login'` and `logoutPath: 'client/auth/v1/logout'`; without it, omit all three. |

`AUTH_BASE_PATH` in `web/public/env.js` comes from the chart's web deployment.
Do not add it by hand to an app on 0.10.x, whose `env.js` still carries
`API_BASE_URL`.

## Check the wiring

If `web/src/main.tsx` does not call `configureAuth`, add the target-model
bootstrap there: import `configure as configureAuth` and `redirectToLogin` from
`@ifs-kairos/auth` and `configureRest` from `@ifs-kairos/net/rest`, then call
both before rendering or before the first API call.

1. Routes (when the framework has client-side routing):
   - For Vite React apps, keep the route `basename` derived from
     `import.meta.env.BASE_URL`.
   - Do not add a frontend `/callback` route for auth.
   - Do not add client-side `protected: true` route guards.
2. API hooks:
   - Continue using `@ifs-kairos/net/rest` and `useApiBaseUrl()`.
   - Do not add bearer-token headers or token-based query gating.
3. Logout:
   - Prefer the built-in `sign-out` action when the app uses a Kairos framework
     layout that provides one.
   - If custom logout code is required, use `redirectToLogout` from
     `@ifs-kairos/auth`; do not recreate logout URLs by hand.
4. Do not add frontend OIDC client secrets, token endpoints, or token storage.

## Example React API hook

```ts
import { useQuery } from '@tanstack/react-query';
import { type Response } from '@ifs-kairos/api';
import { get } from '@ifs-kairos/net/rest';
import { useApiBaseUrl } from '@ifs-kairos/react/api';

export function useExamples() {
  const apiBaseUrl = useApiBaseUrl();

  return useQuery({
    queryKey: ['examples'],
    queryFn: async () => {
      const response = await get<Response<Paginated<Example[]>>>(
        `${apiBaseUrl}/example`
      ).execute();

      return response.data;
    },
  });
}
```

## Verification

Run these after wiring:

```bash
pnpm -C web typecheck
pnpm -C web lint
pnpm -C web test:ci
```

Search for leftover temp-auth code:

```bash
rg "temporary-auth|temp-auth|initializeAuth|useAuth|accessToken|getHeaders|Callback|protected:" web
```

Any remaining match must be unrelated to authentication.

## Red flags

- Adding bearer tokens, local token storage, or `Authorization` headers in the
  frontend.
- Adding a `/callback` route or `protected: true` route guards to the SPA.
- Passing `authBasePath` to `@ifs-kairos/auth` below 0.11.0.
- Calling `window.location` directly for login/logout instead of
  `@ifs-kairos/auth` helpers.
- Changing Helm auth-gateway sidecar or ingress templates from this frontend
  auth skill; use the platform chart guidance for backend deployment work.
