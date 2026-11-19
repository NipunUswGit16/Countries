/* eslint-disable react-refresh/only-export-components */
import { type ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render } from '@testing-library/react';
import { KairosProvider } from '@ifs-kairos/react/providers';
import { appConfig } from './config/app.config';

function TestProviders({ children }: { children: ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
        gcTime: 0,
      },
      mutations: {
        retry: false,
      },
    },
  });

  return (
    <QueryClientProvider client={queryClient}>
      <KairosProvider config={{ appConfig }}>{children}</KairosProvider>
    </QueryClientProvider>
  );
}

export function renderApp(ui: ReactNode) {
  return render(<TestProviders>{ui}</TestProviders>);
}

export { screen } from '@testing-library/react';
