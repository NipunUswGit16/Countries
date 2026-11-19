# Source Directory Structure

This is a Kairos React application template. The folder structure follows a
clear separation of concerns.

## Folder Overview

| Folder      | Purpose                                      | Modifiable? |
| ----------- | -------------------------------------------- | ----------- |
| `config/`   | Application configuration (menus, routes)    | Yes         |
| `features/` | Feature modules (business logic, components) | Yes         |
| `lib/`      | Internal libraries for sharing/reuse         | Yes         |
| `pages/`    | Top-level page components                    | Yes         |
| `styles/`   | Global styles                                | Yes         |

## Application Bootstrap

The application is wired together in `main.tsx`, which sets up the following
provider hierarchy:

```
QueryClientProvider → ApiProvider → AppConfigProvider → NotificationsProvider → App
```

- **`main.tsx`** - Entry point. Initializes providers, imports global styles and
  theming.
- **`App.tsx`** - Initializes routing from `config/routes.ts`.

## Quick Reference

- **Adding a new feature**: Create a folder in `features/` - see
  `features/README.md`
- **Adding a new page**: Create component in `pages/`, add route in
  `config/routes.ts`
- **Configuring menus**: Edit `config/app.config.ts`
- **Global styles**: Add to `styles/`

Each folder contains its own README.md with more detailed guidance.

## Key Libraries and Tooling

- **Vite** - Build tool and dev server
- **React Router** - Routing
- **TanStack Query** - Server state management (API calls)
- **Zustand** - Client state management
- **@ifs-kairos/\*** - Shared Kairos infrastructure libraries

## Styling Approach

This project uses **co-located CSS files** for component styling.

- Regular React components use CSS Modules only (`*.module.css`).
- Shadow DOM components use plain CSS only (`*.shadow.css`, constructable
  stylesheets, or `<style>` in the shadow root).
- Global styles are only allowed in `globals.css`, `layout.css`, and `reset.css`
  (do not use in component styles).
- Keep use of inline style objects to a minimum. Apply where it makes sense, for
  example in one-off computed values like runtime transforms in drag-and-drop
  functionality.
- Use camelCase class names in CSS Modules and kebab-case class names in plain
  CSS.
- Never use CSS-in-JS, Tailwind, SASS/Less, and PostCSS abstraction layers
  beyond autoprefixing.

## Testing and Code Quality

- **Vitest** - Unit testing framework. Run tests with `pnpm test`.
- **ESLint** - Linting. Run with `pnpm lint`.
- **Prettier** - Code formatting. Run with `pnpm format`.
- **Type check** - Run with `pnpm typecheck`.

A custom render function that wraps components with the app's providers is
available in `test-utils.tsx`. Use `renderApp()` from this file instead of
`render()` from testing-library directly.

## AI Assistant Instructions

When working with this codebase:

1. **Follow the feature folder pattern** - See `features/README.md` for the
   expected structure.
2. **Check `@ifs-kairos/*` packages before building infrastructure** - The
   `@ifs-kairos/react` and other `@ifs-kairos/*` packages expose hooks and helpers (e.g.
   `useAppConfig`, `useApiBaseUrl`, `redirectToLogin`). Use these when applicable rather
   than reimplementing the same functionality.
3. **Keep pages thin** - Business logic belongs in feature modules, not pages.
4. **Keep code simple** - Do not over-engineer. Keep code as simple and concise
   as possible, prioritizing readability and maintainability for both humans and
   AI.
5. **Prefer own code before libraries** - Do not add library dependencies for
   simple things that can be written in a few lines of code, e.g. string
   padding, basic date formatting, simple array utilities.
6. **Use co-located CSS Modules** - Co‑locate styles with their component.
   Regular React components: use CSS Modules only (`*.module.css`). Shadow DOM
   components: use plain CSS only (`*.shadow.css`, constructable stylesheets, or
   `<style>` in shadow root). Globals: only in
   `styles/{globals.css, layout.css, reset.css}` (reset, tokens, root variables,
   typography) - no component styles. Forbidden everywhere: CSS‑in‑JS
   (styled‑components, Emotion, JSS, Stitches), Tailwind, SASS/Less, PostCSS
   abstractions beyond autoprefixing, and any inline style objects except
   one‑off computed values (e.g., transforms). Do not introduce any other
   styling method.
