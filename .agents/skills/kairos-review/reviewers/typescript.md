# TypeScript Reviewer Rules

Apply only to `.ts` and `.tsx` files. Report only demonstrably real bugs or production risks.

**Each bullet below is an anti-pattern. Flag any code in the diff that matches.** The section header is the category for the finding.

## ANY_ABUSE

- `any` used to silence a type error without explanation — removes all type safety downstream
- `as SomeType` cast without a preceding type guard or runtime check — if the value is not that type at runtime, silent corruption follows
- `as unknown as T` double cast — bypasses the type system entirely; always a red flag
- `@ts-ignore` or `@ts-expect-error` without an explanatory comment — hides real errors
- Function parameter or return typed as `any` — infects callers with `any`
- `Object` or `{}` used as a type when `unknown` or a specific interface is meant

## UNHANDLED_PROMISE

- `async` function called without `await` — result is a floating Promise; rejections are silently swallowed
- `.then()` chain without a `.catch()` or rejection handler — unhandled rejection crashes Node or is silently ignored in browsers
- `Promise.all` / `Promise.allSettled` called without `await` or `.then()` — fires and is forgotten
- `async` function passed to `forEach` — `forEach` does not await; all iterations run concurrently without coordination and errors are lost
- `new Promise(async (resolve, reject) => ...)` — async executors swallow rejections after the first `await` because the `Promise` constructor ignores the executor's returned promise; use a normal (non-async) executor or refactor to a plain async function

## NULL_SAFETY

- Non-null assertion `!` used on a value that could genuinely be null/undefined (e.g. DOM query results, optional chaining results, array access)
- Optional chaining `?.` result used directly without a null check — e.g. `obj?.value.field` where `.value` could be undefined
- Array index access without bounds check: `arr[0].field` where `arr` might be empty
- `JSON.parse` result used without null/undefined check
- Function parameter typed as optional but used without a default or guard

## TYPE_NARROWING

- `if (typeof x === 'string')` pattern missing for union types — incorrect branch taken at runtime
- Switch over a discriminated union without a `default: assertNever(x)` exhaustiveness check — new union members silently fall through
- `instanceof` check used on a plain object (not a class instance) — always false
- Type predicate function (`x is T`) that does not actually verify all required fields — false positives

## RUNTIME_MISMATCH

- External API response, `JSON.parse` result, or `process.env` value typed as a specific interface without runtime validation — if the shape changes, silent wrong-type access follows
- `process.env.SOME_VAR` used without checking for `undefined` — env vars are always `string | undefined`
- `localStorage.getItem` result used without null check — returns `null` when the key is absent
- Date parsing with `new Date(str)` without validating the result is not `Invalid Date`
- `parseInt` / `parseFloat` result used without checking for `NaN`

## ASYNC_MISUSE

- `async` function that never `await`s anything — unnecessary overhead; should be synchronous
- Sequential `await` inside a loop where the iterations are independent — should use `Promise.all` for parallelism
- `await` used on a non-Promise value — no error, but signals a misunderstanding of the code
- `try/catch` around an `async` call without `await` — the catch never fires; errors escape

## MODULE_AND_IMPORTS

- Circular import between modules — can cause `undefined` values at module initialisation time
- Side-effect import (`import './setup'`) in a module that is itself imported conditionally — execution order is non-deterministic
- Dynamic `require()` in an ES module context — may fail depending on bundler/runtime
