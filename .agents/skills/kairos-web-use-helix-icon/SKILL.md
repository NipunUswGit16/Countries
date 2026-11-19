---
name: kairos-web-use-helix-icon
description: Use when the user asks to add, register, import, remove, delete, replace, or rename Helix icon in the Kairos web app (`web/src/config/helix-icons.config.ts`).
---

# Kairos Web Manage Helix Icons

Use this skill to register new or update existing Helix icon registrations in the Kairos React web workspace so Helix components (for example `<hx-icon>`) can resolve it by name — remove an icon or rename/replace one in `hxIcons`.

## Purpose

- Add a new icon to `hxIcons` and ensure `web/src/main.tsx` calls `registerIcons(hxIcons)` once at app bootstrap.
- Update `hxIcons` by removing an icon entry or renaming/replacing an icon. Do not change `registerIcons` wiring in `web/src/main.tsx` unless it is broken.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

If `web/src/config/helix-icons.config.ts` does not exist, stop and tell the author. The app is on a frontend below the supported floor; see `using-kairos-web-skills`. Do not create the file by hand.

## Target files

- `web/src/config/helix-icons.config.ts`
- `web/src/main.tsx` (only if `registerIcons` wiring is missing)

## Mandatory workflow

### Add or Register an icon

1. Get the icon name from the user (kebab-case, for example `user-circle`).
2. Confirm the icon package exists under `web/node_modules/@ifs-ds/helix-icons/` (import path `@ifs-ds/helix-icons/<icon-name>`).
3. In `helix-icons.config.ts`:
   - Add import: `import userCircle from '@ifs-ds/helix-icons/user-circle';`
   - Add entry to `hxIcons`: `'user-circle': userCircle`
4. Keep object keys in kebab-case (unquoted when the name is a single word, as in `alert`) and imported variable names in camelCase. When the camelCase name is a JavaScript reserved word, suffix the binding: `import deleteIcon from '@ifs-ds/helix-icons/delete';` with key `delete: deleteIcon`.
5. Preserve existing formatting and key ordering in the file.
6. Validate registration in `web/src/main.tsx`:
   - Import `registerIcons` from `@ifs-ds/helix-web-components/base` if missing.
   - Import `hxIcons` from `./config/helix-icons.config.ts` if missing.
   - Call `registerIcons(hxIcons)` once before rendering if missing.
7. Do not add duplicate imports or duplicate `registerIcons(...)` calls.

### Remove an icon

1. Identify the icon key in `hxIcons` (kebab-case).
2. Remove the matching object entry.
3. Remove the related import if no other entry uses it.
4. Preserve existing formatting and key ordering in the file.

### Rename or replace an icon

1. Confirm the old and new icon names with the user.
2. Confirm the new icon package exists under `web/node_modules/@ifs-ds/helix-icons/` (import path `@ifs-ds/helix-icons/<new-icon-name>`).
3. Update imports:
   - Remove the old import if unused.
   - Add `import <camelCase> from '@ifs-ds/helix-icons/<new-icon-name>';`
4. Update `hxIcons`:
   - Key must be the new kebab-case icon name.
   - Value must be the camelCase import binding.
5. Avoid duplicates: do not add a key that already exists unless intentionally replacing that entry.

## Naming

- Package path: `@ifs-ds/helix-icons/<icon-name>` (kebab-case icon name)
- Import binding: camelCase derived from the icon name
  - `chat-sparkle` → `chatSparkle`
  - `panel-9` → `panel9`
  - `more-vertical` → `moreVertical`
  - `question-circle` → `questionCircle`
- Config key: kebab-case icon name (same as package segment); a reserved-word icon keeps its name as the key and gets an `Icon`-suffixed binding

## Validation checklist

- Import exists and matches the requested icon name.
- No orphaned imports remain after remove/rename.
- `hxIcons` includes the new icon key/value.
- No duplicate key in `hxIcons`.
- `web/src/main.tsx` imports `registerIcons` from `@ifs-ds/helix-web-components/base`.
- `web/src/main.tsx` imports `hxIcons` from `./config/helix-icons.config.ts`.
- `web/src/main.tsx` still imports and calls `registerIcons(hxIcons)` once — leave unchanged unless wiring is missing or broken.
- Exactly one `registerIcons(hxIcons)` call.
- File remains valid TypeScript.

## Quality gates

After edits:

```bash
pnpm -C web typecheck
pnpm -C web lint
```

## Example: add

Input icon name: `user-circle`

```ts
import userCircle from '@ifs-ds/helix-icons/user-circle';

export const hxIcons = {
  // ...existing icons
  'user-circle': userCircle,
};
```

## Example: remove

Remove `question-circle`:

```ts
// remove:
import questionCircle from '@ifs-ds/helix-icons/question-circle';
// and remove:
'question-circle': questionCircle,
```

## Example: rename

Rename `question-circle` → `help-circle`:

```ts
import helpCircle from '@ifs-ds/helix-icons/help-circle';

export const hxIcons = {
  // ...existing icons
  'help-circle': helpCircle,
};
```

## Related skills

- `kairos-web-build-ui` — broader Helix UI work in `web/`.
