---
name: kairos-web-call-api
description: Use when required to make network requests such as REST API calls in the kairos web application. EventStream (SSE) is not covered by the stable libraries; see its section before adopting it.
---

# Kairos Web Call API

Use this to make REST API network calls. Any calls from the React app to a backend should be done by following the instructions in this skill.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Call the Client API only — never the Integration API

The web app talks to its component's **Client API** and nothing else. The Client API is the component's own frontend backend (BFF): it is user-facing, carries the browser's auth token, and shapes responses for the UI. The **Integration API** is a separate runtime for machine-to-machine and bulk-load traffic between systems — it is not meant to be reached from a browser and does not have the client-facing auth/BFF surface the web relies on.

- ✅ Call the Client API (served from `cmd/client-api`; endpoints in `internal/api/endpoints/v1/`). `useApiBaseUrl()` resolves to this base URL.
- ❌ Never call the Integration API (`cmd/integration-api`) from the web app — not for reads, not for bulk load, not "just this once."

If the data you need is only exposed on the Integration API, that is a backend gap: add a Client-API endpoint for it (see `kairos-create-api-endpoint`) rather than pointing the browser at the Integration API.

## Core Library

Kairos frontend application uses `@ifs-kairos/net` package to make network requests/calls. This is the go-to **framework agnostic** package place for communicating with a Kairos component backend server. It provides capabilities to handle network communication related operations.

## Features

- **Progress Streaming:** Real-time upload and download progress via async iteration.
- **Type-Safe:** Full TypeScript support with generic response types.
- **Fluent API:** Chainable builder pattern for request configuration.
- **Abort Support:** Cancel requests via AbortController or imperative abort.
- **Progress Ratios:** Automatic calculation of upload/download progress percentages (upload progress is browser-only via XHR; Node uses fetch and supports download progress only).
- **Environment-aware:** Import from `@ifs-kairos/net/rest` for REST requests. Resolves to XHR in the browser (upload and download progress) and fetch in Node (download progress only). Use `@ifs-kairos/net/rest-xhr` for browser-only XhrRequest features; use `@ifs-kairos/net/rest-fetch` for the fetch implementation explicitly.

## Package structure

- `@ifs-kairos/net` — Package root; minimal entry point.
- `@ifs-kairos/net/rest` — REST client. Import **get**, **post**, **put**, and **delete** from here. Also exports REST-related types (builders, RequestProgress, HttpError). Resolves to the right implementation for your environment (browser or Node).
- `@ifs-kairos/net/http` — HTTP-related types: HttpError, RequestOptions.
- `@ifs-kairos/net/rest-xhr` — XHR-based client for browser-only code. Use when you need XhrRequest or the XHR-specific builder types (e.g. upload progress). Not available in Node.
- `@ifs-kairos/net/rest-fetch` — Fetch-based client. Supports download progress via streamed response body; no upload progress. Use from Node or when you want to depend on the fetch implementation explicitly.

## EventStream

The stable libraries (`@ifs-kairos/net`, `@ifs-kairos/react`) have no EventStream or SSE client. `@ifs-kairos/event-stream` exists only as an experimental package (`lib-experimental/` in kairos-frontend), with unstable APIs. Do not add it on your own: ask the author before adopting it.

## Installation

```bash
pnpm add @ifs-kairos/net
```

## Usage

For more detailed code snippet and documentation, See the README at: `node_modules/@ifs-kairos/net/README.md`

## React Usage

In the Kairos React application, the network requests needs to be implemented in React way by wrapping `@ifs-kairos/net` with `@tanstack/react-query`. The `query` or `mutation` should be implemented as a hook, colocated in the feature folder.

When authentication is involved, invoke `kairos-web-auth`. Do not add bearer-token headers from frontend hooks; auth-gateway handles session cookies and login redirects through the global REST `onUnauthorized` handler.

### Hook naming convention

- Query: `useThing.ts` (eg:- `useTodo.ts`)
- Mutation: `useCreateTing.ts` (eg:- `useCreateTodo.ts`)

### Loading state & error display

Render `isLoading` with `<hx-skeleton>` or `<hx-spinner>`, and errors inside `<hx-callout variant="danger">`. `hx-card` has no `danger` variant (its variants are `accent`, `filled`, `filled-outlined`, `outlined`, `plain`).

### Example query usage

```typescript
import { useQuery, type UseQueryResult } from '@tanstack/react-query';
import { type Response } from '@ifs-kairos/api';
import { get } from '@ifs-kairos/net/rest';
import { useApiBaseUrl } from '@ifs-kairos/react/api';
import { type Example } from './example.types';

export type Paginated<T> = {
  data: T,
  pagination: {
    page: number,
    limit: number,
    total: number
  }
}

/**
 * Pagination options for fetching examples
 *
 * @param page - Page number
 * @param limit - Number of examples per page
 */
export interface UseExamplesOptions {
  page?: number;
  limit?: number;
}

/**
 * Hook for fetching examples
 *
 * @param options - Optional pagination parameters
 * @returns TanStack Query result with examples data
 *
 * @example
 * const { data, isLoading, error } = useExamples({ page: 1, limit: 20 });
 */
export function useExamples(
  options: UseExamplesOptions = {}
): UseQueryResult<Paginated<Example[]>, Error> {
  const apiBaseUrl = useApiBaseUrl();
  const { page = 1, limit = 10 } = options;

  return useQuery({
    queryKey: ['examples', { page, limit }],
    queryFn: async (): Promise<Paginated<Example[]>> => {
      const url = `${apiBaseUrl}/example`;
      const response = await get<Response<Paginated<Example[]>>>(url)
        .addParameters({ page, limit })
        .execute();
      return response.data;
    },
  });
}

```

### Example hook usage

```typescript
import { useExamples } from './useExamples';
import styles from './ExampleList.module.css';

/**
 * Example list component - displaying examples from the API
 *
 * This demonstrates:
 * - Using a custom hook (useExamples) for
 *   - fetching examples from the API
 *   - displaying examples
 *   - displaying loading state
 *   - displaying error state
 *   - refreshing examples
 * - Using a CSS module for component-local styles (ExampleList.module.css)
 */
export function ExampleList() {
  const examplesQuery = useExamples();

  return (
    <section>
      <hx-card>

        {examplesQuery.isLoading && (
          <p className={styles.loading}>
            <hx-spinner style={{ marginRight: 'var(--space-control-gap-xs)' }} />
            Loading sample data...
          </p>
        )}

        {examplesQuery.error && (
          <hx-callout
            variant="danger"
            title="Error"
            description={
              examplesQuery.error instanceof Error
                ? examplesQuery.error.message
                : 'Failed to fetch examples'
            }
          />
        )}

        {!examplesQuery.isLoading && !examplesQuery.error && (
          <table className={styles.table}>
            <thead>
              <tr>
                <th>Id</th>
                <th>Name</th>
                <th>Custom field</th>
                <th>Custom list</th>
              </tr>
            </thead>
            <tbody>
              {(examplesQuery.data?.data ?? []).map((example, index) => (
                <tr key={example.id ?? `${example.name}-${index}`}>
                  <td>{example.id ?? '-'}</td>
                  <td>{example.name}</td>
                  <td>{example.custom_field || '-'}</td>
                  <td>
                    {Array.isArray(example.custom_list) &&
                    example.custom_list.length > 0
                      ? example.custom_list
                          .map((value) => String(value))
                          .join(', ')
                      : '-'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </hx-card>
    </section>
  );
}
```

## Best Practices

- Write secure code.
- Use hooks carefully and handle the states properly.
- Usee experience matters, always handle loading and errors properly.
- Use library features where need (eg:- caching, deduplication, throttle).
- Look out for performance bottlenecks and eliminate them.
- Use auth-gateway redirects for authentication. Do not manually attach bearer
  tokens in frontend API hooks.

## Bad practices (RED FLAGS!)

- Calling the Integration API (`cmd/integration-api`) from the web app. The web calls the **Client API** only — see the section above.
- Not using Using `@ifs-kairos/net` and using `fetch` or `axios` directly.
- Not wrapping with `@tanstack/react-query`.
- Not following hook patterns.
- Importing `useAuth` from `@ifs-kairos/react/temporary-auth` or adding
  `getHeaders(accessToken)` to REST calls.
