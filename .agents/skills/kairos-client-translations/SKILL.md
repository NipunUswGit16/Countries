---
name: kairos-client-translations
description: Set up or extend i18n in Kairos React client apps. If translation files and i18n config are missing, bootstrap react-i18next and locale files from the template/react pattern, then make user-facing strings translatable and run i18next-cli extract. Reuse keys already defined in the i18next "framework" namespace instead of redefining defaultValues. Use when the user asks to translate, internationalize, localize, i18n, or add translations to a component, page, feature, or project.
---

# Kairos Client Translations

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Purpose

Set up i18n when missing, or extend an existing setup. Convert hardcoded,
user-facing text in a React file (or a whole page/feature/bounded context) into
translatable strings so a developer can localize their bounded context. The skill:

- Bootstraps the Kairos `template/react` i18n stack when not yet present.
- Reuses already defined translations in the i18next `framework` namespace for
  common UI (no defaultValues, no `ns:`).
- Replaces remaining plain text with `t('key', 'Default text')`.
- Replaces text that contains inline markup or interpolation with `<Trans>`.
- Adds every supporting piece of code needed (imports, `useTranslation()` hook, or
  the module-level `t` import) so the file compiles and renders.
- Runs `i18next-cli` to extract the new keys into the locale JSON files.

## Translation stack (template/react pattern)

- `react-i18next`: `useTranslation()` hook, `t()`, `<Trans>` component.
- `@ifs-kairos/translation`: bootstrap + locale switching, re-exported through
  `src/config/i18n.ts` (exports `t`, `i18n`, `switchLocale`, ...).
- `i18next-cli`: extracts default strings into `src/locales/{{language}}/translation.json`.
  Config lives in `i18next.config.ts`. Locales live in `src/config/locales.ts`
  (the first entry, `en`, is the primary language that receives the default text).

If i18n is already wired in `main.tsx`, do not duplicate initialization. Only add
or adjust config when files are missing or incomplete.

`@ifs-kairos/translation` initializes i18next with
`defaultNS: ['translation', 'framework']`. `t('key')` looks in `translation`
first, then falls back to `framework` when the key is missing there. Do not pass
`{ ns: 'framework' }` — that skips the default lookup order.

## Reuse the `framework` namespace

Reuse already defined translations in the `framework` namespace of i18next,
having many of the common items already translated. With that, there's no need
to redefine defaultValues for these `t()` functions. Instead, use the `t()` but
make it default using the `framework` namespace (but not by defining a specific
`ns:` as it will fallback to and use `framework` when nothing is found in
`translation`).

Before assigning a new key, print the catalog bundled in the installed
`@ifs-kairos/translation`. The package ships no `locales/` folder; the catalog is
compiled into `dist/index.js` and not exported, so read it through i18next. Run
this from the app root (`web/`):

```bash
node --input-type=module -e "
import { initKairosI18n } from '@ifs-kairos/translation';
const { i18n } = initKairosI18n({ supportedLocales: ['en'], translationModules: {} }, { type: '3rdParty', init() {} });
console.log(JSON.stringify(i18n.getResourceBundle('en', 'framework') ?? {}));
"
```

The installed catalog is the source of truth.

If the same meaning already exists there, call `t('existing.framework.key')`
with **no** second-argument default and **no** `ns`. Do not copy that key into
`src/locales/*/translation.json` — extraction would shadow the already-localized
framework string.

```tsx
// Correct — falls back to framework
t('app.profile.signOut')
t('app.toolbar.notifications')

// Wrong — defaultValue + extract writes the key into translation.json and shadows framework
t('app.profile.signOut', 'Sign Out')

// Wrong — explicit ns skips translation-then-framework default lookup
t('app.profile.signOut', { ns: 'framework' })

// Wrong — a new app key that duplicates a framework string
t('app.menu.signOut', 'Sign Out')
```

Common framework keys (confirm against the installed catalog; it may grow):

- `app.menu.home`, `app.menu.pages`
- `app.profile.viewProfile`, `app.profile.theme`, `app.profile.language`,
  `app.profile.signOut`
- `app.themes.light`, `app.themes.dark`
- `app.toolbar.notifications`
- `app.notifications.close`, `app.notifications.empty`

## Workflow

Copy this checklist and track progress:

```text
Task Progress:
- [ ] Step 0: Ensure i18n is set up
- [ ] Step 1: Identify target file(s) / scope
- [ ] Step 2: Find all translatable text
- [ ] Step 3: Choose t() vs <Trans> per string
- [ ] Step 4: Assign keys (reuse framework catalog first)
- [ ] Step 5: Apply edits + add imports/hooks
- [ ] Step 6: Run extraction
- [ ] Step 7: Validate
```

### Step 0: Ensure i18n is set up

Work from the React app root (the folder that contains or should contain
`i18next.config.ts` — not a monorepo root unless that is the app root).

Check whether translation infrastructure already exists. If any of the following
are missing, create them following the Kairos `template/react` pattern (read
equivalent files from that template when available; paths are relative to the app
root):

- `i18next.config.ts`
- `src/config/i18n.ts` — re-export from `@ifs-kairos/translation` where applicable
- `src/config/locales.ts`
- `src/locales/en/translation.json` (start with `{}`; other locales as needed)
- i18n imported and initialized in `main.tsx` before the app renders

Install dependencies if missing: `react-i18next`, `i18next`, `@ifs-kairos/translation`,
and `i18next-cli` (dev). Use the project's package manager.

After bootstrap, confirm the app still builds before continuing to string replacement.

### Step 1: Identify scope

If the user names a file, translate that file. If they name a page, feature folder,
or "bounded context", translate every `.tsx`/`.ts` file under it that renders or
returns user-facing text (components, `*.config.ts` with labels, etc.).

### Step 2: Find all translatable text

Translate text a user reads on screen:

- JSX text nodes: `<h2>Temperature</h2>`, `<p>...</p>`, `<li>...</li>`.
- User-facing string attributes/props: `label`, `description`, `placeholder`,
  `title`, `alt`, `aria-label`, and Helix props like `description=` on
  `<hx-callout>`.
- String literals used as UI text in config/constants (e.g. menu `label`s in
  `app.config.ts`, form field `label`s, option labels).
- Strings built with interpolation that a user sees (e.g. error/success messages).

Do NOT translate:

- Code identifiers, prop/event names, CSS class names, `data-*` / test ids, route
  paths, icon names, enum values used as keys, console logs.
- Pure values/units that are not words (`°C`, numbers). Keep units out of the key;
  interpolate the number and append the unit, or include the unit in the default text
  only when it is part of the sentence.
- Text already wrapped in `t()` or `<Trans>`, unless that call duplicates a
  `framework` key with a defaultValue or `{ ns: 'framework' }` — rewrite those
  to `t('framework.key')` with no default and no `ns`.

### Step 3: Choose `t()` vs `<Trans>`

Use `t('key')` with **no** default when the key already exists in the `framework`
namespace (see [Reuse the `framework` namespace](#reuse-the-framework-namespace)).

Use `t('key', 'Default text')` for plain app-specific text with no inline markup
and no matching framework key:

```tsx
<h2>{t('temperature.heading.title', 'Temperature')}</h2>
```

Use `<Trans>` when the string contains inline JSX/markup (`<code>`, `<strong>`,
links, etc.) or mixes elements with interpolated values, so the markup stays inside
one translatable sentence:

```tsx
<Trans
  i18nKey="temperature.paragraph.description"
  defaults="Live values come from <code>useTemperatureStore()</code>. Reset history with the clear action."
  components={{ code: <code /> }}
/>
```

For interpolation, pass `values`:

```tsx
<Trans
  i18nKey="home.callout.tokenInfo"
  defaults="Your token starts with <code>{{tokenPrefix}}</code>."
  values={{ tokenPrefix }}
  components={{ code: <code /> }}
/>
```

For a plain interpolated string (no markup), prefer `t()` with values:

```tsx
t('example.error.create', 'Error: {{message}}', { message })
```

Number-only / unit values stay as expressions; do not put `{currentTemperature.toFixed(1)}°C` inside a key.

### Step 4: Assign keys

- Nested dot-notation, lowercase, grouped by page/feature: `<scope>.<group>.<name>`.
  Examples: `temperature.heading.title`, `temperature.readings.current`,
  `home.paragraph.description`.
- Use `heading`, `paragraph`, `label`, `button`, `callout`, `error` style groups to
  match existing keys in `src/locales/en/translation.json`.
- Reuse an existing key if the exact text already exists; never create duplicates.
- Prefer a matching `framework` key over creating an app key. Do not invent
  `app.menu.*` / `app.profile.*` / `app.toolbar.*` keys that already live in
  `framework`.
- For **new app keys only**, the default text passed to `t()`/`defaults` MUST be
  the original English copy so extraction populates `en` correctly.
- Never pass a defaultValue (or `<Trans defaults>`) for a `framework` key.

### Step 5: Apply edits + add supporting code

In a React component:

1. Add the hook at the top of the component body:
   `const { t } = useTranslation();`
2. Add/extend the import:
   `import { Trans, useTranslation } from 'react-i18next';`
   (import `Trans` only if used).
3. Replace each identified string with `t(...)` or `<Trans>`. Use `t('framework.key')`
   with no default when the catalog already has it.

In a non-component module (e.g. `*.config.ts`, constants, store):

1. Import the app `t`: `import { t } from '../config/i18n';`
   (adjust the relative path to reach `src/config/i18n.ts`).
2. Replace string literals with `t('key')` for framework keys, or
   `t('key', 'Default text')` for new app keys.
   Note: these run at module load, so the locale is applied on reload (the
   template's locale switch reloads the page).

Do not narrate edits in code comments. Keep existing formatting/quote style.

### Step 6: Run extraction

From the app root (the folder with `i18next.config.ts`):

```bash
pnpm exec i18next-cli extract
```

This writes default text into `src/locales/en/translation.json` and adds the new
keys (empty) to the other locales (e.g. `sv`) for translators to fill in. Use the
project package manager if preferred (e.g. `pnpm exec i18next-cli extract`).

Framework keys must not stay in `translation.json`: a copy there shadows the
localized framework string, and a key left empty (as in the non-primary locales)
renders raw. Give every framework key a `t('key')` call with no default (Step 2),
then after every extraction remove from each locale file every key that exists
in the installed framework catalog:

```bash
FW=$(node --input-type=module -e "
import { initKairosI18n } from '@ifs-kairos/translation';
const { i18n } = initKairosI18n({ supportedLocales: ['en'], translationModules: {} }, { type: '3rdParty', init() {} });
console.log(JSON.stringify(i18n.getResourceBundle('en', 'framework') ?? {}));
") || FW=
if [ -z "$FW" ] || [ "$FW" = "{}" ]; then
  echo "framework catalog not readable; locale files unchanged" >&2
else
  for f in src/locales/*/translation.json; do
    jq --argjson fw "$FW" 'delpaths([$fw | paths(scalars)])
      | walk(if type == "object" then with_entries(select(.value != {})) else . end)' \
      "$f" > "$f.tmp" && mv "$f.tmp" "$f" \
      || { rm -f "$f.tmp"; echo "cleanup failed: $f" >&2; }
  done
fi
```

If it prints an error, fix the cause (run from the app root; install
dependencies) and run it again. A failed file is left as it was.

### Step 7: Validate

- `pnpm typecheck` (or `tsc -b`) passes; no unused `Trans`/`t` imports.
- Every identified user-facing string now uses `t()` or `<Trans>`.
- Framework keys are `t('key')` only — no defaultValue, no `{ ns: 'framework' }`.
- New **app** keys exist in `src/locales/en/translation.json` with the correct
  default text. Framework keys do **not** appear there.
- `<Trans>` markup tags each have a matching entry in `components`.
- No keys were duplicated; interpolation values are passed via `values`/3rd arg.

## Quick example

Before:

```tsx
export function Temperature() {
  return (
    <section>
      <h2>Temperature</h2>
      <p>
        Reset the recorded history from the <code>store</code>.
      </p>
      <hx-button type="submit" variant="primary">Clear</hx-button>
    </section>
  );
}
```

After:

```tsx
import { Trans, useTranslation } from 'react-i18next';

export function Temperature() {
  const { t } = useTranslation();
  return (
    <section>
      <h2>{t('temperature.heading.title', 'Temperature')}</h2>
      <p>
        <Trans
          i18nKey="temperature.paragraph.reset"
          defaults="Reset the recorded history from the <code>store</code>."
          components={{ code: <code /> }}
        />
      </p>
      <hx-button type="submit" variant="primary">
        {t('temperature.button.clear', 'Clear')}
      </hx-button>
    </section>
  );
}
```

Framework strings (profile, theme, language, sign-out, notifications, …) omit
the default:

```tsx
label: t('app.profile.signOut')
```

Then run `pnpm exec i18next-cli extract` and the framework-key cleanup from Step 6.
