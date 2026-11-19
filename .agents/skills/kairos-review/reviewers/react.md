# React Reviewer Rules

Apply only to `.tsx` files (and `.jsx` if present). Report only demonstrably real bugs or production risks.

**Each bullet below is an anti-pattern. Flag any code in the diff that matches.** The section header is the category for the finding.

## EFFECT_DEPS

- `useEffect` / `useLayoutEffect` with a missing dependency — stale closure reads the initial value forever
- `useEffect` with an object or array literal in the dependency array — new reference on every render causes infinite loop
- `useCallback` / `useMemo` with an empty dependency array but referencing props or state — memoised value never updates
- `useEffect` that sets state on every render (state setter called unconditionally with a value derived from current state, or with a fresh object/array reference) — infinite render loop; gate the `setState` on a condition, move the value into a `useMemo`, or compute it during render instead
- `useEffect` missing a cleanup function when it sets up a subscription, timer, or event listener — leak on unmount

## HOOK_RULES

- Hook called conditionally (`if (x) useEffect(...)`) — violates rules of hooks; order changes between renders
- Hook called inside a loop — same violation; hook count is not stable
- Hook called from a non-component, non-custom-hook function — hooks are only valid in React function components and custom hooks
- Custom hook that does not start with `use` — React's linter cannot enforce hook rules for it

## STATE_MUTATION

- State object or array mutated directly (`state.items.push(x)` without spreading) — React does not detect the change; component does not re-render
- Previous state value used inside `setState(newValue)` without the updater form — stale state under concurrent rendering; must use `setState(prev => ...)`
- Deriving state from props in `useState` initialiser without memoisation — prop changes after mount are ignored

## RENDER_CORRECTNESS

- Key prop missing or set to array index in a list that can reorder or be filtered — React uses wrong DOM node, causes state corruption
- Key prop using a non-stable value (e.g. `Math.random()`) — component remounts on every render
- Component defined inside another component's render — new function reference every render causes full remount of the inner component
- Event handler defined inline as an arrow function and passed to a deeply nested child — new reference every render triggers unnecessary re-renders (flag only when passed to `React.memo`-wrapped children)

## CONTEXT_AND_PROVIDER

- `useContext` consuming a context whose Provider is missing in the tree — returns the default value silently; often `undefined`
- Context value is an object literal created in render — new reference every render causes all consumers to re-render
- Large context used for high-frequency updates (e.g. mouse position) — every consumer re-renders on every update; should be split or use a ref

## SUSPENSE_AND_ERROR

- `React.lazy` component used without a `<Suspense>` boundary — throws at runtime if the chunk is not yet loaded
- Error boundary missing around async data-fetching components — uncaught render errors crash the whole tree
- `throw promise` pattern (data-fetching suspense) used without a parent `<Suspense>` boundary
