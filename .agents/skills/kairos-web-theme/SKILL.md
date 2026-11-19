---
name: kairos-web-theme
description: Use when required to work on Kairos frontend theme setup, design tokens, dark mode, or active theme handling.
---

# Kairos Frontend Theme

Use this skill to manage frontend theme in Kairos application.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Exports

The package `@ifs-ds/helix-design-tokens` exports following:

- `@ifs-ds/helix-design-tokens/variables.css`
- `@ifs-ds/helix-design-tokens/variables.dark.css`
- `@ifs-ds/helix-design-tokens/variables.size.css`
- `@ifs-ds/helix-design-tokens/typography.css`
- `@ifs-ds/helix-design-tokens/compatibility.css`
- `@ifs-ds/helix-design-tokens/helix.css`
- `@ifs-ds/helix-design-tokens` (runtime theme manager API)

## Usage

- `variables.css` provides the default (light) token variables at `:root` (base + light theme + default `md` size).
- `variables.dark.css` provides dark-theme overrides under `[data-theme="dark"]`.
- `variables.size.css` provides density overrides under `[data-size="md"]`, `[data-size="xs"]`, `[data-size="sm"]`, and `[data-size="lg"]`. `md` is also baked into `:root` via `variables.css` as the default scale, so omitting the attribute yields the same result; the scoped `[data-size="md"]` block lets you reset back to `md` inside an ancestor that sets a different size.
- `typography.css` provides Inter and Fira Code font-face declarations and references bundled font files under `./fonts/`.
- `compatibility.css` is a compatibility layer stylesheet for consumer-specific fallback and compatibility additions.
- `helix.css` is a convenience entrypoint that imports `variables.css`, `variables.dark.css`, `variables.size.css`, `typography.css`, and `compatibility.css`.

## Set or get theme

`main.tsx` calls `restoreTheme()` once before rendering; it applies the persisted theme (or the default) so a reload keeps the user's choice. Change the theme with `persistTheme(theme)`, which stores the choice and applies it. Do not call `themeManager.initTheme`: it re-applies the system preference over the saved choice. Subscribe with `themeManager.onThemeChange` when a component must react to theme changes.

```tsx
import { useEffect } from 'react';
import { themeManager, type ThemeName } from '@ifs-ds/helix-design-tokens';
import { persistTheme } from '@ifs-kairos/react/theme';

export function Component() {
  useEffect(() => {
    // onThemeChange returns the unsubscribe function
    return themeManager.onThemeChange((theme: ThemeName) => {
      console.log('Theme changed to', theme);
    });
  }, []);

  return <button onClick={() => persistTheme('dark')}>Switch theme</button>;
}
```

## Bad practice (RED FLAGS!)

- **Do not** import theme CSS in component files — it is loaded once in `main.tsx`.
