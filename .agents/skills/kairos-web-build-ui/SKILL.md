---
name: kairos-web-build-ui
description: Use when you need to work on the frontend code which is located in the /web directory.
---

# Kairos Web Build UI (React + Helix + IFS Design System)

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Purpose

Generate React UI inside the `web/` workspace using **Helix web components** (`hx-*`) and **IFS design tokens**. The component library and tokens evolve, so always link to canonical sources rather than embedding lists that may go stale.

## Critical Behavioural Instructions (must follow)

- Always refer provided resources.
- Always use available special skills.
- Do not assume. Ask user for the clarifications where needed.
- Always follow Kairos rules and practices.

## Canonical Resources (always check these first)

- IFS Design System 2 (Figma tokens, layout, typography): https://www.figma.com/design/0tzS5Fp5hJgmNbWhnvTrpW/IFS-Design-System-2--v0.3-?m=auto
- Helix usage skill: Invoke `using-helix-skills` skill to get the latest information about building UI with Helix components. if the `using-helix-skills` skill cannot be found, check the `web/node_modules/@ifs-ds/helix-web-components/dist/skills/using-helix-components/SKILL.md` as an alternative reference to find the helix usage information.
- Local installed packages (source of truth for what's available right now):
  - `@ifs-ds/helix-web-components/` — registered custom elements + types
  - `@ifs-kairos/react/` — `AppLayout`, routing, providers, hooks
  - `@ifs-kairos/ffw-components/` — extra Kairos web components
  - `@ifs-kairos/api/` — API convention helpers.
  - `@ifs-kairos/error/` — framework agnostic error class.
  - `@ifs-kairos/translation` - app translation manager and helpers.

**NOTE:** If a Helix component or token isn't documented in these locations, ask the user before inventing it.

## Mandatory Workflow

1. **Install the dependencies** in web directory `pnpm -C web install`.
2. **Read the design** the user provides (Figma link, screenshot, or text spec).

3. **Inventory the Helix elements needed** (e.g. card, input, button, badge, skeleton, list, grid, form, dialog — and any other tags in the package). For each UI intent, refer to the Helix usage skill (included above as a canonical resource) to decide which Helix components to use, before choosing a tag. **It is mandatory to use Helix components; use native HTML only for layout/semantics or when no suitable `hx-*` component exists** (see component priority order in the Helix skill).
4. **Inventory the design tokens needed** (spacing, color, radius, typography). Look up CSS custom properties in `web/node_modules/@ifs-ds/helix-design-tokens/dist/css/variables.css`, `variables.dark.css` and `variables.size.css` (eg: `--space-layout-gap-sm`). Never hardcode hex/px values that have a token equivalent.
5. **Place files** following the project's existing structure (see "File layout" below).
6. **Generate code** following the patterns in this skill and the existing features under `web/src/features/` if there are any (the template ships none; otherwise use the patterns in this skill).
7. **Run quality gates**:
    - Run type check: `pnpm -C web typecheck`.
    - Run lint check: `pnpm -C web lint`.
    - Run tests: `pnpm -C web test`.

## Core Patterns

### Using Helix web components in JSX

Helix elements are custom elements used directly as JSX tags (`<hx-button>`, `<hx-card>`, `<hx-input>`, `<hx-badge>`, `<hx-skeleton>`, etc.). Types are augmented globally by `@ifs-ds/helix-web-components`, so no extra imports are needed in component files. `main.tsx` registers `@ifs-ds/helix-web-components/base` once (already done), which covers every component except data-grid, date-picker, date-time-picker, time-picker and chart. If you use one of those, add its sub-path import (for example `import '@ifs-ds/helix-web-components/data-grid';`) in `main.tsx` once.

```tsx
<hx-card>
  <h4>Title</h4>
  <hx-button variant="primary" onClick={handleClick}>
    Save
  </hx-button>
</hx-card>
```

Refer to Helix usage skill for more `helix` related agent-skills.

### Key gotchas

- **Events from web components are native `Event`**, not synthetic React events. Cast targets:
  `onhx-input={(e: Event) => setValue((e.target as HTMLInputElement).value)}`
- **Use `onhx-input`, not `onChange`**, for `hx-input`.
- **Boolean attributes**: pass real booleans (`disabled={isPending}`); Lit will reflect them.
- **Refs to web components** are `HTMLElement | null`, not the specific HTML element type.
- For variants, slots, and supported props, check the Helix component documentation using the references provided in the Helix usage skill rather than guessing.

### Forms (React Hook Form + Zod + Helix)

- Wrap each Helix input in a `<Controller>` and translate native input events to RHF's `field.onChange`.
- Show validation messages via the component's `invalid` and `invalidMessage` props (`hint` is helper text, not an error).

### Example Form

```tsx
import { useState } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { useCreateExample } from './useCreateExample';
import styles from './ExampleForm.module.css';

const createExampleSchema = z.object({
  name: z.string().min(1, 'Name is required'),
  custom_field: z.string(),
});

type CreateExampleFormValues = z.infer<typeof createExampleSchema>;

export function ExampleForm() {
  const [submitSuccess, setSubmitSuccess] = useState(false);
  const exampleCreation = useCreateExample();

  const {
    control,
    handleSubmit,
    reset,
    formState: { errors, isValid },
  } = useForm<CreateExampleFormValues>({
    resolver: zodResolver(createExampleSchema),
    defaultValues: { name: '', custom_field: '' },
    mode: 'onChange',
  });

  const onSubmit = (values: CreateExampleFormValues) => {
    setSubmitSuccess(false);
    exampleCreation.mutate(values, {
      onSuccess: () => {
        reset();
        setSubmitSuccess(true);
      },
    });
  };

  return (
    <section>
      <hx-card>
        <h4>Create a new example item</h4>
        <form onSubmit={handleSubmit(onSubmit)} className={styles.form}>
          <Controller
            name="name"
            control={control}
            render={({ field }) => (
              <hx-input
                label="Name *"
                placeholder="Enter example name"
                value={field.value ?? ''}
                onhx-input={(e: Event) =>
                  field.onChange((e.target as HTMLInputElement).value ?? '')
                }
                onhx-blur={field.onBlur}
                invalid={!!errors.name}
                invalidMessage={errors.name?.message}
              />
            )}
          />

          <Controller
            name="custom_field"
            control={control}
            render={({ field }) => (
              <hx-input
                label="Custom Field"
                placeholder="Enter custom field value"
                value={field.value ?? ''}
                onhx-input={(e: Event) =>
                  field.onChange((e.target as HTMLInputElement).value ?? '')
                }
                onhx-blur={field.onBlur}
              />
            )}
          />

          <hx-button type="submit" variant="primary" disabled={exampleCreation.isPending || !isValid}>
            {exampleCreation.isPending ? 'Creating...' : 'Create Example'}
          </hx-button>

          {exampleCreation.error && (
            <hx-callout
              variant="danger"
              title="Error"
              description={
                exampleCreation.error instanceof Error
                  ? exampleCreation.error.message
                  : 'Failed to create example'
              }
            />
          )}
          {submitSuccess && (
            <hx-callout variant="success" title="Example created successfully!" />
          )}
        </form>
      </hx-card>
    </section>
  );
}
```

## Quick Recipes

### New feature module checklist

```text
- [ ] Create web/src/features/<feature>/
- [ ] <feature>.types.ts            // Zod schemas + TS types
- [ ] use<Feature>.ts               // TanStack Query hook(s)
- [ ] useCreate<Feature>.ts         // Mutation hook(s) if needed
- [ ] <Feature>List.tsx + .module.css
- [ ] <Feature>Form.tsx  + .module.css
- [ ] <Feature>Detail.tsx (optional)
- [ ] Register route in src/config/routes.ts
- [ ] Add menu entry in src/config/app.config.ts (if user-facing)
- [ ] pnpm -C web typecheck && pnpm -C web lint
```

### Translating a Figma frame

When the user provides a Figma URL, frame link, or design screenshot to implement in `web/`, **invoke the `kairos-web-figma-to-code` skill** and follow its full workflow before generating code.

That skill covers Figma MCP context gathering, UI intent decomposition, Helix component mapping, design token translation, file structure, and design verification. Continue using this skill (`kairos-web-build-ui`) for general React + Helix patterns, forms, file layout, and quality gates.

## Anti-Patterns

- Using `@awesome.me/webawesome` / `<wa-*>` tags. The `web/README.md` may mention them historically, but this project uses Helix (`<hx-*>`). Ignore the `wa-*` references.
- Hardcoded colors, pixel paddings, font sizes when a design token exists.
- React `onChange` on Helix inputs (use `onhx-input`).
- Fetching directly inside components instead of via a `useThing` TanStack hook.
- New global CSS for one component; use a co-located `.module.css`.
- Inventing component tags or props that aren't provided in the component documentation / installed package.
