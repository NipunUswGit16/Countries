# Styles Directory

This directory contains global styles that apply across the entire application.

## Files

### `reset.css`

CSS reset/normalization to ensure consistent styling across browsers (box
sizing, margins, scrollbars). Typography defaults are not set here.

### Base typography

Element defaults (html font, headings, paragraphs, lists, links, code) come from
`@ifs-kairos/ffw-components/base.css`, imported in `main.tsx` after the Helix
token CSS. They use Helix tokens and have zero specificity (`:where()`), so
component styles override them without extra effort. Do not redefine them here.

### `layout.css`

Contains CSS for a shared layout across the application.

## Guidelines

### Global vs Component Styles

| Style Type | Location          | Use Case                                                        |
| ---------- | ----------------- | --------------------------------------------------------------- |
| Global     | `styles/`         | CSS resets, base typography, application-specific CSS variables |
| Component  | Next to component | Component-specific styles                                       |

### CSS Variables

Most CSS variables related to theming (colors, spacing, typography, etc.) are
provided by the `@ifs-kairos/theming` package and should not be redefined here.
Only add CSS variables to this directory if they are truly application-specific
and not covered by the design system.

## AI Assistant Instructions

- **Prefer component-level styles** - Co-locate CSS with components (see
  `src/README.md` for the styling approach)
- **Use this directory sparingly** - Only for truly global styles
- **Do not redefine theme variables** - Colors, spacing, typography, and other
  design tokens are provided by `@ifs-kairos/theming`
- **Follow existing naming conventions** - Use kebab-case for CSS class names
