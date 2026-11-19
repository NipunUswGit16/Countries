import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { registerIcons } from '@ifs-ds/helix-web-components/base';

import './config/i18n';
import { appConfig } from './config/app.config';
import { responseConfig } from './config/response.config';
import { initializeResponseOrchestration } from '@ifs-kairos/response';
import { configure as configureAuth, redirectToLogin } from '@ifs-kairos/auth';
import { configureRest } from '@ifs-kairos/net/rest';
import { createDefaultManagers } from '@ifs-kairos/ffw-components/managers/defaults';
import { KairosProvider } from '@ifs-kairos/react/providers';

// Styling
import './styles/reset.css';
import './styles/layout.css';
import '@ifs-ds/helix-web-components/styles/theme.css';
import '@ifs-ds/helix-design-tokens/helix.css';
import '@ifs-kairos/ffw-components/base.css';

// Web components registrations
import '@ifs-kairos/ffw-components';
import '@ifs-ds/helix-web-components/base';

import App from './App.tsx';
import { hxIcons } from './config/helix-icons.config.ts';

registerIcons(hxIcons);

// If this app still had a separate `error.config.ts` (a BC mid-migration
// that hasn't consolidated its error and response rules into one file yet),
// merge both configs into a single `initializeResponseOrchestration` call
// like this instead of the single-config call below:
//
// initializeResponseOrchestration({
//   customResponseRules: [
//     ...(errorConfig.customResponseRules ?? []),
//     ...(responseConfig.customResponseRules ?? []),
//   ],
//   clientResponseRule: errorConfig.clientResponseRule ?? responseConfig.clientResponseRule,
// });
initializeResponseOrchestration(responseConfig);

// Setting the page title
document.title = appConfig.title;

const managers = createDefaultManagers();

// Configure auth-gateway with the application base path. The gateway handles
// the OAuth flow and session cookies; on a 401 the user is redirected to login.
configureAuth({ basePath: import.meta.env.BASE_URL, authBasePath: window.__ENV__.AUTH_BASE_PATH });
configureRest({ onUnauthorized: redirectToLogin });

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 1,
    },
  },
});

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <KairosProvider config={{ appConfig: { ...appConfig, managers } }}>
        <App />
      </KairosProvider>
    </QueryClientProvider>
  </StrictMode>
);
