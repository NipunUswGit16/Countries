---
name: using-helix-skills
description: Primary skill for using Helix Web Components (hx-*) from @ifs-ds/helix-web-components when building, enhancing, or refactoring UI. Use when creating screens, forms, buttons, inputs, grids, dialogs, layouts, or any visual interface in this application. Includes references for further reading and lookup of installation and setup guide, component API and documentation, styling, and workflows.
---

# Using Helix Skills

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Reference documentation

**Read this first** before implementing or answering questions about Helix UI components:

Primary reference: `web/node_modules/@ifs-ds/helix-web-components/dist/skills/using-helix-components/SKILL.md`

Covers installation, imports, registration, core concepts, styling, component priority, workflows, and common mistakes. Use the topic lookup below for quick navigation to specific sections in the primary reference.

| Topic | What to read | Lookup location (section in Primary reference) |
|-------|--------------|------------------------------------------------|
| **Introduction** | What Helix Web Components are | Introduction |
| **Installation and setup** | Installing Helix with necessary peer dependencies, importing themes, design tokens, and web components / registering custom elements | Installation and setup |
| **Core concepts** | Attributes, properties, events, methods, slots, CSS parts | Core concepts |
| **Component styling** | How to use props, `data-size`, `data-theme`, tokens, `::part()`, slots, etc. to style Helix components | Component styling |
| **Component priority order** | How to decide the priority of different Helix and native HTML components when composing UI | Component priority order |
| **Component documentation** | Per-component API, examples, accessibility | Component documentation |
| **Workflows** | Steps to follow when creating new UI, enhancing existing UI, or refactoring code to use Helix components | Workflows |
| **Common mistakes** | Common mistakes to avoid when using Helix components | Common mistakes (RED FLAGS) |

## List of Helix UI components

- List available components: Lookup in the **components** folder of the @ifs-ds/helix-web-components package to find available components
- Per-component API docs: `web/node_modules/@ifs-ds/helix-web-components/dist/skills/using-helix-components/references/components/<name>.md` (strip the `hx-` prefix from the tag, e.g. `hx-button` → `button.md`)
- Refer to **Component documentation** in the primary reference for lookup rules

## UI workflow (summary)

1. Confirm Helix setup (imports and web component registration is properly done in an entry file. For example, in `src/main.jsx`)
2. Break the design into UI intents; map each to a Helix component
   - Lookup in the **components** folder of the @ifs-ds/helix-web-components package to find available components
   - Refer to **Component documentation** in the primary reference for instructions on how to decide what component to use based on user input or context
   - Refer to **Component priority order** in the primary reference for instructions on how to use composite, primitive, or native HTML components when composing UI
3. Read each component's documentation before writing markup
4. Use the props, attributes, events, slots, etc. following the component's API. Do not guess or invent props, attributes, events, slots, etc. that are not defined in the component's API when using Helix components in the application
5. Compose with closing tags; wire `hx-*` events in React with lowercase `onhx-<event>` props (for example `onhx-grid-update`, `onhx-submit`), not `onHx-…`; the handler type is `(e: Event)`, read `(e as CustomEvent).detail`
6. Use design tokens for all potential styling opportunities in the code and markup written. Avoid hardcoded values when a matching token exists (see Styling section below for more details)
7. Verify: components registered, theme/tokens loaded once, app builds

For detailed step-by-step workflows (create, enhance, refactor), read **Workflows** in the primary reference.

## Styling

### Prioritize design tokens over fixed CSS values

**Always prefer design tokens before writing literal CSS values** (hex colors, pixel spacing, font sizes, border radii). Tokens from `@ifs-ds/helix-design-tokens` are the single source of truth and keep custom UI consistent with Helix components and across light/dark themes.

**Do:**

- Use `var(--token-name, fallback)` in CSS and inline styles
- Look up the exact token name in the token CSS files before using it
- Match the token category to the property (spacing tokens for gap/padding, theme tokens for color, etc.)

```css
.page-header {
  display: flex;
  gap: var(--space-control-gap-md, 8px);
  padding: var(--space-layout-padding-md, 10px);
  color: var(--color-theme-brand-foreground-primary-on-strong, #ffffff);
}
```

```jsx
<div style={{ padding: 'var(--space-layout-padding-md, 10px)' }}>...</div>
```

**Do not:**

- Hardcode colors (`#336699`), spacing (`16px`), or font sizes when a token that matches with the context exists
- Invent token names — confirm the exact token names from the **Token lookup locations** defined below
- Override Helix shadow-DOM internals with arbitrary CSS selectors

**Token lookup locations:**

- `web/node_modules/@ifs-ds/helix-design-tokens/dist/css/variables.css` — light theme tokens
- `web/node_modules/@ifs-ds/helix-design-tokens/dist/css/variables.dark.css` — dark theme overrides
- `web/node_modules/@ifs-ds/helix-design-tokens/dist/css/variables.size.css` — density/size tokens

For full styling guidance (theming, `::part()`, slots), see **Component styling** in the primary reference.

### Sizing (density) setup

To enable density/size support for the entire application, set the `data-size` attribute on a high level element like `<html>` or `<body>`. For example below code will apply the `md` size by default to all Helix components in the application.

```html
<html data-size="md">
  <body>
    <div id="root">
      <App />
    </div>
  </body>
</html>
```

Values for `data-size` are `xs`, `sm`, `md`, `lg`. `md` is the default value.

For changing the size of a specific component, use the `data-size` attribute on the component. For example:

```html
<hx-button data-size="sm">Small button</hx-button>
```

This will override the default size set on a higher level element (if any).

## Common use cases

### 1. Visualize tabular data (read-only or interactive)

There are mainly two components available for visualizing tabular data: `<hx-list>` and `<hx-data-grid>`.

Use `<hx-list>` component when you want to display tabular data in a row-oriented layout optimized for list-style navigation rather than cell-by-cell grid focus. It supports functionalities like row-selection, sorting, grouping, pagination, filtering, show/hide columns, and row-level create/update/delete. It uses row keyboard navigation and responsive column prioritization so less important columns drop off as the container narrows.

Use `<hx-data-grid>` component when you want to display tabular data with cell-level interaction. It supports functionalities like row-selection, sorting, grouping, pagination, filtering, show/hide columns, resizing columns, pinning columns, virtual scrolling and inline row/cell editing. Keyboard navigation allows focusing on cells and rows.

refer to the `list` and `data-grid` components documentation for further details on how to use them based on the use case and data model.

**Example 1:** <hx-list> usage:

```tsx
import { useEffect, useRef } from 'react';
import type { GridColumn, GridSourceItem } from '@ifs-ds/helix-web-components';

export function BasicList() {
  const ref = useRef<
    HTMLElement & { items: GridSourceItem[]; columns: GridColumn[]; rowKey: string }
  >(null);

  useEffect(() => {
    if (!ref.current) return;
    ref.current.rowKey = 'id';
    ref.current.columns = [
      { key: 'name', title: 'Name', sortable: true },
      { key: 'email', title: 'Email' },
    ];
    ref.current.items = [
      { id: 1, name: 'John Doe', email: 'john@example.com' },
      { id: 2, name: 'Jane Smith', email: 'jane@example.com' },
    ];
  }, []);

  return <hx-list ref={ref} />;
}
```

**Example 2:** <hx-data-grid> usage. `main.tsx` registers `@ifs-ds/helix-web-components/base`, which does not include data-grid: if `main.tsx` lacks `import '@ifs-ds/helix-web-components/data-grid';`, add it once. Date-picker, date-time-picker, time-picker and chart need their own sub-path import the same way:

```tsx
import { useEffect, useRef } from 'react';
import type {
  GridColumn,
  GridCudConfig,
  GridSourceItem,
} from '@ifs-ds/helix-web-components';

export function EditableGrid() {
  const ref = useRef<
    HTMLElement & {
      items: GridSourceItem[];
      columns: GridColumn[];
      rowKey: string;
      cud: GridCudConfig;
    }
  >(null);

  useEffect(() => {
    if (!ref.current) return;
    ref.current.rowKey = 'id';
    ref.current.columns = [
      { key: 'name', title: 'Name', editable: true, type: 'string' },
      { key: 'email', title: 'Email', editable: true, type: 'string' },
    ];
    ref.current.items = [{ id: 1, name: 'John', email: 'john@example.com' }];
    ref.current.cud = {
      update: { variant: 'cell', presentation: 'contextual' },
    };
  }, []);

  return (
    <hx-data-grid
      ref={ref}
      onhx-grid-update={(e: Event) => {
        console.log('Updated values:', (e as CustomEvent).detail?.values);
      }}
    />
  );
}
```

### 2. Create a form

Forms can be created using the `<hx-form>` component. It renders a configurable form from a `FormLayoutItem[]` layout: leaf fields, flex field groups (`fieldset`), or collapsible `hx-details` sections. Supports usual form functionalities like input validation, form submission and reset.

Although, the primitive input controls available in the helix library (such as `<hx-input>`, `<hx-date-picker>`, `<hx-checkbox>`, `<hx-radio>`, `<hx-chips>`, `<hx-slider>`, `<hx-select>`, `<hx-textarea>`, and `<hx-combobox>`) can be used directly inside an HTML <form>, it is highly recommended to use the `<hx-form>` component to create forms for all possible use cases.

refer to the form components documentation for more details on how to use them based on the use case.

**Example:** <hx-form> usage:

```tsx
import { useEffect, useRef } from 'react';
import type { HelixFormComponent } from '@ifs-ds/helix-web-components';

export function LoginForm() {
  const ref = useRef<HelixFormComponent>(null);

  useEffect(() => {
    if (!ref.current) return;
    ref.current.fields = [
      {
        type: 'string',
        name: 'email',
        label: 'Email',
        required: true,
        control: { type: 'input', variant: 'email', placeholder: 'user@example.com' },
      },
      {
        type: 'string',
        name: 'password',
        label: 'Password',
        required: true,
        control: { type: 'input', variant: 'password' },
      },
      { type: 'boolean', name: 'rememberMe', label: 'Remember me' },
    ];
    ref.current.primaryActions = [
      {
        type: 'submit',
        label: 'Login',
        onClick: (formData) => console.log('Submitted:', formData),
      },
    ];
    ref.current.secondaryActions = [
      { type: 'cancel', label: 'Cancel', onClick: () => console.log('Cancelled') },
    ];
  }, []);

  return (
    <hx-form
      ref={ref}
      onhx-submit={(e: Event) => console.log((e as CustomEvent).detail)}
    />
  );
}
```

### 3. Display popup messages

Popup messages can be displayed using the `<hx-message-box>` component.It supports optional type icons (info, warning, error, success), a consistent body layout, and an actions footer slot. Use it for alerts, confirmations, and status messages.

refer to the message box components documentation for more details on how to use them based on the use case.

```tsx
import { useRef } from 'react';
import type { HelixMessageBoxComponent } from '@ifs-ds/helix-web-components';

export function ShowMessageBox() {
  const ref = useRef<HelixMessageBoxComponent & HTMLElement>(null);

  const openConfirm = () => ref.current?.show();

  return (
    <>
      <hx-button onClick={openConfirm}>Delete</hx-button>
      <hx-message-box ref={ref} title="Confirm" type="warning" aria-label="Confirm delete">
        <p>Proceed with deletion?</p>
        <div slot="actions">
          <hx-button variant="danger" onClick={() => ref.current?.hide()}>
            Yes
          </hx-button>
          <hx-button variant="secondary" data-dialog="close">
            No
          </hx-button>
        </div>
      </hx-message-box>
    </>
  );
}
```
