# Features Directory

This directory contains feature modules - self-contained units of business
functionality.

## Feature Structure

Each feature should be a folder containing all related code:

```
features/
└── user-management/
    ├── user.types.ts          # TypeScript types/interfaces
    ├── UserList.tsx            # React components
    ├── UserList.module.css     # Component styles
    ├── UserForm.tsx
    ├── UserForm.module.css
    ├── useUsers.ts             # Data fetching hook (TanStack Query)
    ├── useCreateUser.ts        # Mutation hook
    └── user.store.ts           # Local state (Zustand) - if needed
```

## Naming Conventions

| Type       | Convention                        | Example               |
| ---------- | --------------------------------- | --------------------- |
| Folder     | kebab-case                        | `user-management/`    |
| Components | PascalCase                        | `UserList.tsx`        |
| Hooks      | camelCase with `use` prefix       | `useUsers.ts`         |
| Types      | camelCase with `.types.ts` suffix | `user.types.ts`       |
| Store      | camelCase with `.store.ts` suffix | `user.store.ts`       |
| Styles     | Match component name              | `UserList.module.css` |

## Patterns to Follow

### Data Fetching (TanStack Query)

```tsx
// useUsers.ts
import { useQuery } from '@tanstack/react-query';
import { get } from '@ifs-kairos/net/rest';
import { useApiBaseUrl } from '@ifs-kairos/react/api';

export function useUsers() {
  const apiBaseUrl = useApiBaseUrl();

  return useQuery({
    queryKey: ['users'],
    queryFn: async () => {
      const response = await get(`${apiBaseUrl}/users`).execute();
      return response.data;
    },
  });
}
```

### Mutations (TanStack Query)

```tsx
// useCreateUser.ts
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { post } from '@ifs-kairos/net/rest';

export function useCreateUser() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (data) => {
      // POST request
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['users'] });
    },
  });
}
```

### Local State (Zustand)

```tsx
// feature.store.ts
import { create } from 'zustand';

interface FeatureState {
  value: number;
  setValue: (value: number) => void;
}

export const useFeatureStore = create<FeatureState>((set) => ({
  value: 0,
  setValue: (value) => set({ value }),
}));
```

## AI Assistant Instructions

When creating new features:

1. **Create a new folder** under `features/` for each distinct feature
2. **Follow the naming conventions** listed above
3. **Use TanStack Query** for all API interactions (queries and mutations)
4. **Use Zustand** only for client-side state that doesn't come from the server
5. **Keep components focused** - split into smaller components if needed
6. **Co-locate styles** - CSS file next to the component it styles
7. **Export from index.ts** if the feature has many exports (optional)
