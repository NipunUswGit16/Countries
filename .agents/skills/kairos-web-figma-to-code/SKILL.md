---
name: kairos-web-figma-to-code
description: Use when implementing a Figma frame/screen/design in the Kairos web app. Translates Figma designs into Helix-first React code with IFS design tokens via the Figma MCP. Triggers on Figma URLs, frame links, design-to-code, or "implement this design".
---

# Kairos Web Figma to Code

Use this skill to translate a Figma frame into React UI using **Helix web components** (`hx-*`) and **IFS design tokens** — not a literal port of Figma's reference output.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Prerequisites

- **Figma URL must include `node-id`** — ask the user for a frame-specific link if missing. Extract `nodeId` from the URL.
- **Figma MCP must be authenticated** — if tools fail, prompt the user to sign in to Figma through the Figma MCP settings.

## Canonical Resources (reference skills)

- `kairos-web-build-ui` — general Kairos frontend patterns (forms, file layout, quality gates)
- `using-helix-skills` — Helix components documentation, component APIs, priority order, token usage
- `kairos-web-theme` — token file layout and theming
- `kairos-web-use-helix-icon` — to register a new icon when the frame or design context indicates icons are present

## Mandatory Workflow

### Phase 1 — Gather design context from Figma

Use the **Figma MCP server**. Inspect the available tools and pick the one whose description matches each need below. Run matching calls in parallel where possible.

| What to gather | Purpose |
|----------------|---------|
| **Design context for the frame** | Primary input: screenshot, reference code, asset URLs, metadata. Indicate TypeScript and React as the target stack. Keep Code Connect enabled unless the user asks to disable it. |
| **Variable definitions on the frame** | Figma variables bound to the frame (colors, spacing, typography). |
| **Component-to-code mappings (Code Connect)** | Existing Figma → codebase mappings for components in the frame. |
| **Screenshot of the frame** | Extra visual reference if the design-context screenshot is insufficient. |
| **Motion / animation context** | Keyframes, easing, and duration when the frame includes animation. |

**Treat design-context reference code as input only** — it is generic React/HTML/CSS. Discard patterns that conflict with Kairos conventions (native `<button>`, hardcoded hex/px, Tailwind classes, etc.) and rebuild using Helix components and design tokens.

### Phase 2 — Decompose the frame into UI intents

Work top-down through the Figma layer tree:

1. **Page / screen shell** — when the figma frame is a full screen (with the shell included). Map the general shell components (header, toolbar, sidebar, breadcrumb, footer, etc.) to `AppLayout` patterns in `@ifs-kairos/react/`.
2. **Layout regions** — identify the layout regions in the figma frame (e.g. stacks, grids, split panes). Starting from the top-most region, work down the tree, creating a new region for each nested container.
3. **Loading states** — identify the loading states (e.g. skeletons, spinners, progress bars).
4. **Content blocks** — categorize the content blocks (data views, charts, forms, actions, feedback). Inventory the content blocks and their associated components (e.g. data views: tables, lists; forms: form, input fields, select, checkbox, radio, switch; actions: buttons, menus; feedback: badges, message-boxes, toasts, progress bars).
5. **Modal content** — identify the modal content in the figma frame and map it to the appropriate visual components (e.g. dialog, drawer, etc.).

### Phase 3 — Map Figma nodes to Helix components + HTML elements

For **each** UI intent, follow this resolution order:

1. **Page / screen shell** — if the shell is present already in the UI code, use the existing shell components. If the shell is not present, map the general shell components (header, toolbar, sidebar, breadcrumb, footer, etc.) to `AppLayout` patterns in `@ifs-kairos/react/`. If there are conflicts between the shell components in the figma frame and the UI code, ask the user for clarification without forcing a change into the UI code.
2. **Layout regions** — map the layout regions to the appropriate Helix components or HTML elements. if a Helix layout component that fits the layout intent is not available, use the semantic HTML elements (`<section>`, `<header>`, `<main>`) first, and then use `<div>` elements as necessary.
3. **Content blocks and modal content** — navigate through the content inventory and map the intent blocks to the appropriate Helix components. Use native HTML elements only for layout/semantics or when no suitable Helix component exists. Use the `using-helix-skills` skill for instructions on how to map the UI intents with the appropriate Helix components and to decide the **Component priority** (composite -> primitive -> native HTML) when composing UI.
4. **Component properties** — map the Figma properties to the appropriate Helix component properties. Use the component API doc to determine the allowed values for the properties. Do not guess or invent props, attributes, events, slots, etc. that are not defined in the component's API.

| Figma signal | Helix mapping |
|--------------|---------------|
| Component variant (Primary / Secondary / Danger) | `variant` prop — confirm allowed values in component doc |
| Size (S / M / L) | `data-size="xs\|sm\|md\|lg"` on component or ancestor |
| Disabled / loading state | `disabled`, skeleton components, or button loading patterns per doc |
| Label + hint + error text | `label`, `hint` props on inputs for visual hints and validation |
| Leading / trailing icon | `slot="icon"` or icon slots documented on the component |
| Selected / checked state | `checked`, `selected`, or selection APIs per component doc |

Produce a short **intent inventory** before writing code:

```text
Frame: "User Settings"
├── Page header (title + breadcrumb)     → native <header> + typography tokens
├── Settings card                        → <hx-card>
│   ├── Profile form                     → <hx-form> or <hx-input> fields
│   └── Save / Cancel                    → <hx-button variant="primary|secondary">
└── Danger zone callout                  → <hx-callout variant="danger">
```

### Phase 4 — Map Figma values to design tokens

Never copy literal values from Figma or reference code when a token exists. Confirm every token in code against the installed CSS files — do not invent names.

**Token lookup files** (installed package; confirm exact names — do not invent):

- `web/node_modules/@ifs-ds/helix-design-tokens/dist/css/variables.css` — light theme
- `web/node_modules/@ifs-ds/helix-design-tokens/dist/css/variables.dark.css` — dark overrides
- `web/node_modules/@ifs-ds/helix-design-tokens/dist/css/variables.size.css` — density
- `@ifs-ds/helix-design-tokens/typography.css` — font faces (loaded globally in `main.tsx`)

**Mapping workflow:**

1. Fetch **variable definitions** for the frame node.
2. For each Figma variable or hardcoded value (color, spacing, radius, font), look up the closest match in the token CSS files. When Figma variables mirror the token naming, map directly to the matching design token (e.g. `space/layout/gap/md` -> `--space-layout-gap-md`). When they differ, pick the **closest semantic equivalent** from list of tokens and note the choice in a brief comment only if non-obvious.
3. Prefer **semantic theme tokens** over primitives (e.g. `--color-theme-surface-foreground-default` over a raw slate hex; `--color-theme-brand-foreground-primary-on-strong` for text on a brand button).

**Helix components own most visual styling** — custom CSS is for layout (flex, grid, gap), page structure, and spacing between components. Do not override shadow-DOM internals unless explicitly instructed to do so by the user.

### Phase 5 — Structure the implementation

Follow existing Kairos feature patterns from `kairos-web-build-ui`:

Split large frames into sub-components that mirror **Figma's logical groups**, not every layer.

### Phase 6 — Generate code

```text
- [ ] Helix tags for interactive and visual primitives
- [ ] CSS Module layout using token vars for gap/padding/color
- [ ] Native events wired correctly with the appropriate event handlers
- [ ] All states from the design: default, hover/focus (via Helix), disabled, error, empty, loading
- [ ] Light and dark theme: semantic tokens auto-adapt; verify no hardcoded colors
- [ ] Assets from design context downloaded to appropriate web/src/assets/ path
- [ ] Icons via <hx-icon> or kairos-web-use-helix-icon for custom glyphs
- [ ] Motion from the Phase 1 motion context when animations are in scope
```

### Phase 7 — Verify against the design

1. Compare generated UI mentally (or run the dev server) against the Figma frame from Phase 1.
2. Check spacing rhythm — token gaps should match visual density of the frame.
3. Confirm every interactive control in Figma has a Helix counterpart (or a native HTML element when no suitable Helix component exists) with correct variant and state.
4. Run quality gates (type check, lint, test).

## Anti-patterns

- Copying Figma reference code verbatim instead of mapping to Helix components and tokens.
- Using native HTML elements when a suitable Helix component exists.
- Hardcoded colors, pixel paddings, or font sizes when a design token exists.
- Inventing component tags or props not documented in the installed Helix package.
