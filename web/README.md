# Kairos Component React Template

This is a React application template for the Kairos application platform. It
comes pre-configured with the development toolchain, shared Kairos
infrastructure packages, and a minimal app shell: a welcome **Home** page,
configuration for menus and routing, and an empty **`src/features/`** tree
(documented in `src/features/README.md`) where you add bounded-context code.

## Prerequisites

- **Node.js** — `>=24.16.0` (see `package.json` `engines`)
- **pnpm** — This project uses **pnpm** as its package manager. Do not use npm
  or yarn. All commands in this README and across the project assume pnpm. If
  you don't have pnpm installed:

  ```bash
  npm install -g pnpm
  ```

## Getting Started

### 1. Install dependencies

```bash
pnpm install
```

### 2. Deploy to the Kairos cluster

Authentication requires the application to run inside the Kairos cluster. From
the root of your bounded context (the parent directory, not this template
directory), run:

```bash
make deploy
```

The `pnpm dev` command starts a local Vite dev server (default port **5173**)
which can be useful for rapid UI iteration.

To sign in on the local Vite server instead of the in-cluster app, deploy
with the toolkit flag:

```bash
make deploy AUTH_REDIRECT=LOCAL
```

That points the auth-gateway OAuth callback at
`http://localhost:5173/auth/v1/callback`. It *replaces* the `local.pac`
callback, so in-cluster login will not work until you redeploy *without* the
`AUTH_REDIRECT=LOCAL` flag.

When `KAIROS_BASE_PATH` is set, Vite proxies `API_BASE_PATH` and `AUTH_BASE_PATH`
from `.env` to the cluster ingress.

### 3. Customize the template

A good starting point is the `src/config/` directory. The recommended order:

1. **Edit `src/config/app.config.ts`** — Configure the header title, navigation
   menus, profile menu, and toolbar buttons. This file defines the application
   shell and is the single source of truth for navigation structure.
2. **Edit `src/config/response.config.ts`** — **Application response
   configuration** for `@ifs-kairos/response` (server-response catalog,
   `customResponseRules` for HTTP status triggers, and optional
   `clientResponseRule` for global **`window` `error`** only). Bootstrap
   runs from `main.tsx` **before** `createRoot` — see `src/config/README.md`.
3. **Edit `src/config/routes.ts`** — Register your application pages and set up
   routing.
4. **Add features** — Create feature modules under `src/features/` following
   `src/features/README.md`, import them from your pages, and wire new routes as
   needed.
5. **Adjust seed data** — Replace or trim `src/config/notifications.config.ts`
   when you connect a real notification source.

Auth-gateway integration is configured from `src/main.tsx` using
`@ifs-kairos/auth` (`authBasePath` from `window.__ENV__.AUTH_BASE_PATH`). The
gateway owns the OAuth flow and session cookies; the app redirects users to
gateway login when API calls return HTTP 401.

Runtime env lives in [`public/env.js`](public/env.js). Copy [`.env.example`](.env.example)
to `.env` for local `pnpm dev`; Helm substitutes the same keys at deploy time:

- `API_BASE_PATH` (default `api/v1`) — used by `getBaseApiPathSegments()` and the Vite API proxy
- `AUTH_BASE_PATH` (default `auth/v1`) — passed to `configureAuth({ authBasePath })` and the Vite auth proxy

## Available Scripts

| Command               | Description                                               |
| --------------------- | --------------------------------------------------------- |
| `make deploy`         | Build and deploy to the Kairos cluster (run from BC root) |
| `pnpm dev`            | Start the local Vite dev server (API/auth via cluster proxy; use `AUTH_REDIRECT=LOCAL` for localhost OAuth) |
| `pnpm build`          | Create a production build                                 |
| `pnpm preview`        | Preview the production build locally                      |
| `pnpm test`           | Run Vitest in **watch** mode (`pnpm test:watch`)          |
| `pnpm test:ci`        | Run Vitest once (typical for CI)                          |
| `pnpm test:coverage`  | Run unit tests with coverage report                       |
| `pnpm lint`           | Run ESLint                                                |
| `pnpm typecheck`      | Run TypeScript type checking                              |
| `pnpm format`         | Format code with Prettier                                 |

## Project Structure

```
template/react/
├── index.html                  # HTML entry point
├── package.json                # Dependencies and scripts
├── tsconfig.json               # TypeScript configuration
├── vite.config.ts              # Vite build and dev server configuration
├── vitest.config.ts            # Vitest test configuration
├── vitest-setup.ts             # Vitest setup (test environment bootstrap)
├── eslint.config.js            # ESLint configuration
├── .prettierrc                 # Prettier configuration
├── .prettierignore             # Prettier ignore patterns
├── .npmrc                      # npm/pnpm registry configuration
├── .gitignore                  # Git ignore patterns
├── public/                     # Static assets (e.g. env.js, Helix icons for dev)
└── src/
    ├── main.tsx                # Application entry and provider setup
    ├── App.tsx                 # Root component (initializes routing)
    ├── App.test.tsx            # Smoke test for the app shell
    ├── test-utils.tsx          # Test utilities with provider wrappers
    ├── config/                 # Application configuration (start here)
    │   ├── app.config.ts       # Header, menus, toolbar buttons
    │   ├── response.config.ts  # Application response rules (@ifs-kairos/response)
    │   ├── notifications.config.ts # Initial notification seed data
    │   └── routes.ts           # Route definitions
    ├── features/               # Feature modules (add your BC code here)
    ├── pages/                  # Top-level page components
    │   ├── Home.tsx
    │   └── Home.module.css
    ├── lib/                    # Shared internal libraries
    └── styles/                 # Global styles (reset, layout)
```

Each major folder under `src/` has a `README.md` with more detail on structure
and conventions.

## Kairos Core Dependencies

This template depends on several `@ifs-kairos/*` packages that provide shared
infrastructure for the Kairos platform. Check these packages before building
your own infrastructure — they likely already provide what you need.

| Package                      | Purpose                                                                                                                                        |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `@ifs-kairos/react`          | React-specific framework: app layout, routing, app config provider/hook, notifications provider/hook, API provider                            |
| `@ifs-kairos/auth`           | Auth-gateway redirect helpers and base path configuration                                                                                       |
| `@ifs-kairos/response`       | Framework-agnostic response orchestration: bootstrap + HTTP / client dispatch, plus a server-response catalog for 2xx envelopes; no UI — app registers listeners (see `src/config/response.config.ts`) |
| `@ifs-kairos/api`            | API URL utilities for building service endpoints                                                                                               |
| `@ifs-kairos/net`            | HTTP client (`get`, `post`, etc.); every HTTP response integrates with `@ifs-kairos/response` when orchestration is bootstrapped                 |
| `@ifs-kairos/theming`        | Design system themes, CSS variables, and icon sets                                                                                             |
| `@ifs-kairos/ffw-components` | Shared web components                                                                                                                        |

### Key hooks and utilities from `@ifs-kairos`

- `useAppConfig()` — Access and update the application configuration at runtime
  (button badges, etc.)
- `useNotifications()` — Access and manage notifications (add, remove, mark
  read, open drawer) with automatic header badge sync
- `useApiBaseUrl()` — Get the API base URL for data fetching
- `AppShell` — The application shell component with header, sidebar, and
  content area. Handles built-in menu actions (sign-out, notifications, theme,
  language, routing) and propagates unhandled menu item clicks to the `onMenuItemClicked`
  callback in `app.config.ts`
- `NotificationsProvider` — Provided via **`KairosProvider`**; wires notification state
- `initRoutes()` — Initialize routing from a route configuration object
- `redirectToLogin()` — Redirect to the auth-gateway login endpoint after an
  unauthorized API response

## Application Architecture

### Provider hierarchy

Call **`initializeResponseOrchestration`** from **`@ifs-kairos/response`** in
**`main.tsx`** **before** **`createRoot(...).render`** (and before
**`KairosProvider`**) so HTTP responses and global client errors use
**`src/config/response.config.ts`**. **`@ifs-kairos/react`** does not expose this
config through **`KairosProvider`** or hooks in v1 — see **`src/config/README.md`**.

After the root mounts, the tree is:

```
QueryClientProvider → KairosProvider → App
```

- **QueryClientProvider** — TanStack Query client for server state management
- **KairosProvider** — Bundles app configuration (including runtime updates),
  notifications, API base URL, and related Kairos React context used by the shell
- **App** — Root component that initializes routing from `src/config/routes.ts`

Tests use the same **`QueryClientProvider` → `KairosProvider`** pairing via
`src/test-utils.tsx` (with a minimal config; see that file if tests need
notification seed data or other options).

### Menu Item Click Handling

The `AppShell` component handles menu item clicks from the header, sidebar
menu, and app switcher. It processes these built-in actions automatically:

- **`sign-out`** — Logs the user out
- **`notifications-button`** — Opens the notification drawer
- **Theme items** — Switches the application theme (items with `data.theme`)
- **Language items** — Switches the application locale (items with `data.locale`); reloads so config evaluated at load time picks up the new language
- **Route items** — Navigates to the specified route (items with `data.route`)

Any menu item click that doesn't match one of these built-in actions is
forwarded to the optional `onMenuItemClicked` callback in `app.config.ts`. Use
this to handle custom items like app switcher entries, help buttons, chat
buttons, or profile actions:

```typescript
// In src/config/app.config.ts
export const appConfig: AppConfig = {
  onMenuItemClicked: (detail) => {
    switch (detail.id) {
      case 'help':
        window.open('/docs', '_blank');
        break;
      case 'ifs-zero':
        window.location.href = '/ifs-zero';
        break;
    }
  },
  // ... rest of config
};
```

### Routing

Routes are defined declaratively in `src/config/routes.ts`. Pages are children
of the `AppShell` route, which provides the application shell (header, sidebar,
content area). Authentication is enforced by the auth-gateway: unauthenticated
API calls return HTTP 401, which triggers the login redirect configured in
`main.tsx`.

### Styling

This project uses **co-located CSS Modules** for component styling. See
`src/README.md` for the full styling guide. Key rules:

- Components use CSS Modules (`*.module.css`)
- Global styles live only in `src/styles/`
- Theme variables are provided by `@ifs-kairos/theming` — do not redefine them
- CSS-in-JS, Tailwind, SASS, and other CSS abstraction layers are not permitted

### UI components

UI components are **IFS Helix Web Components** (`@ifs-ds/helix-web-components`),
loaded with the Helix theme manager and base registration in `main.tsx`.

### Testing

Tests use **Vitest** with **jsdom** and **React Testing Library**. A custom
`renderApp()` function in `src/test-utils.tsx` wraps components with the same
provider stack as the app — use it instead of `render()` from Testing Library
directly.

### Test coverage

The template includes coverage support via
[`@vitest/coverage-v8`](https://vitest.dev/guide/coverage). Run coverage with:
`pnpm test:coverage`

## Key Technology Stack

Libraries in **`package.json`** match what the Kairos stack and typical features
use: the template **uses** React, Vite, TanStack Query, and the Kairos providers
out of the box; **React Hook Form**, **Zod**, and **Zustand** are installed for
use when you build forms and client state in feature code.

| Technology                                                                | Role                                |
| ------------------------------------------------------------------------- | ----------------------------------- |
| [React 19](https://react.dev/)                                            | UI framework                        |
| [Vite](https://vite.dev/)                                                 | Build tool and dev server           |
| [TypeScript](https://www.typescriptlang.org/)                             | Type safety                         |
| [React Router](https://reactrouter.com/)                                  | Client-side routing                 |
| [TanStack Query](https://tanstack.com/query)                              | Server state management (API calls) |
| [Zustand](https://zustand.docs.pmnd.rs/)                                  | Client-side state (for your features)|
| [React Hook Form](https://react-hook-form.com/) + [Zod](https://zod.dev/) | Form handling and validation        |
| [@ifs-ds/helix-web-components]()                                          | Helix web components UI             |
| [Vitest](https://vitest.dev/)                                             | Unit testing                        |
| [ESLint](https://eslint.org/)                                             | Linting                             |
| [Prettier](https://prettier.io/)                                          | Code formatting                     |

## Further Reading

- Root **`CONTEXT.md`** (monorepo) — glossary for error orchestration terms
  (**trigger**, **application error configuration**, **error orchestration
  bootstrap**, **client error**, v1 boundaries).
- `src/README.md` — Source layout, bootstrap flow, styling approach, and coding
  conventions
- `src/config/README.md` — Application configuration and routing guide
- `src/features/README.md` — Feature module structure and patterns
- `src/pages/README.md` — Page component guidelines
- `src/styles/README.md` — Global styles and CSS variable guidelines
- `src/lib/README.md` — Library directory usage
