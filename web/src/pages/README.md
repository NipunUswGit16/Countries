# Pages Directory

This directory contains top-level page components that are mapped to routes.

## Purpose

Pages are the entry points for each route in the application. They should:

- **Compose features** - Import and arrange feature components
- **Stay thin** - Minimal logic, delegate to features
- **Handle layout** - Page-specific layout and structure

## Structure

```
pages/
├── Home.tsx       # Main landing page
├── Home.module.css # Page-specific styles (optional)
└── README.md
```

## Example Page

```tsx
// Dashboard.tsx
import { SomeFeature } from '../features/some-feature/SomeFeature';
import { AnotherFeature } from '../features/another/AnotherFeature';
import styles from './Dashboard.module.css';

export function Dashboard() {
  return (
    <div className={styles.page}>
      <h1>Dashboard</h1>
      <SomeFeature />
      <AnotherFeature />
    </div>
  );
}
```

## Adding a New Page

1. Create the page component in `pages/`
2. Add the route in `config/routes.ts` (see `config/README.md`)
3. Optionally add a menu item in `config/app.config.ts`

## AI Assistant Instructions

- **Keep pages simple** - They should mainly compose features, not contain
  business logic
- **Business logic belongs in `features/`** - If you're writing complex logic,
  it probably belongs in a feature module
- **One page per route** - Each distinct route should have its own page
  component
- **Co-locate styles** - Create a matching `.module.css` file for page-specific
  styling
