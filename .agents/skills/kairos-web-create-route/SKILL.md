---
name: kairos-web-create-route
description: Use when required to create a Kairos frontend React route entry, page component, or navigation link in the web app.
---

# Create a route

Use this to skill to create a route.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Router config type definition

`RoutesConfig` is exported from `@ifs-kairos/react/route`. Its shape:

```typescript
/**
 * Definition of a single route.
 */
type RouteDefinition = {
  component: React.ComponentType<{ children?: ReactNode }>;
  children?: Record<string, RouteDefinition>;
};

/**
 * Configuration for the application routes.
 */
type RoutesConfig = {
  basename: string; // base path
  routes: Record<string, RouteDefinition>;
};
```

## Adding new route

Add new routes under the `AppLayout`. Authentication is enforced by auth-gateway through API 401 redirects, so do not add client-side protected-route flags or callback routes.

**File Location:** `./web/src/config/routes.ts`

```typescript
import { type RoutesConfig } from '@ifs-kairos/react/route';
import { AppLayout } from '@ifs-kairos/react/layout';
import { Home } from '../pages/Home';
import { ExamplePageComponent } from '../pages/ExamplePageComponent';

// Derive the router basename from Vite's base config so routes match the deployment subpath.
const basename = import.meta.env.BASE_URL.replace(/\/$/, '') || '/';

/**
 * Application Routes Configuration
 *
 * Define all application routes here. Each route can have:
 * - component: The React component to render
 * - children: Nested routes (rendered inside parent component)
 *
 * The basename is automatically derived from Vite's base config,
 * ensuring routes work correctly when deployed to a subpath.
 *
 * Authentication is enforced by the auth-gateway: unauthenticated API calls
 * return 401, which triggers a redirect to the gateway login configured in
 * main.tsx. No client-side route guard is required.
 */
export const routes: RoutesConfig = {
  basename,
  routes: {
    '/*': {
      component: AppLayout,
      children: {
        '': { component: Home },
        '/example': {
          component: ExamplePageComponent,
        },
      },
    },
  },
};
```

## Pages

Routes should navigates to `pages` which located in the `web/src/pages/` directory. The `page` is a regular React component, Top-level routed view; composes feature components.

**Conventions**
Create the page component as `src/pages/<Page>.tsx` and the css style as  `src/pages/<Page>.module.css`.

## Using route links in the template

Use `<Link>` from `react-router-dom` package for in-app navigation.

```typescript
import { Link } from "react-router-dom";

function ExamplePageComponent() {
  return (
    <Link to="/example-route">
      Click Here
    </Link>
  );
}
```

You can use `useNavigate()` for imperative navigation as well.

```typescript
import { useNavigate } from "react-router-dom";

function ExampleButton() {
  const navigate = useNavigate();

  const handler = async () => {
    // other logic...
    navigate("/example-component");
  };

  return <button onClick={handler}>Click Here</button>;
}
```

## Bad practices - RED FLAGS

- Using `<a href>` for internal navigation (Why? Full page reload, Loses SPA state, Slower UX).
- Using `window.location`.
- Calling `navigate()` during render (Why? Causes render side effects, Can create loops).
