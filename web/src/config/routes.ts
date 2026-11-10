import { type RoutesConfig } from '@ifs-kairos/react/route';
import { AppShell } from '@ifs-kairos/react/shell';
import { Home } from '../pages/Home';

// Get basename from Vite's base config (import.meta.env.BASE_URL)
// This ensures router paths match the deployment subpath (e.g., /template-react/)
const basename = import.meta.env.BASE_URL.replace(/\/$/, '') || '/';

/**
 * Application Routes Configuration
 *
 * Define all application routes here. Each route can have:
 * - component: The React component to render
 * - children: Nested routes (rendered inside parent component)
 *
 * The basename is automatically derived from Vite's base config,
 * ensuring routes work correctly when deployed to a subpath.
 *
 * Authentication is enforced by the auth-gateway: unauthenticated API calls
 * return 401, which triggers a redirect to the gateway login (configured in
 * main.tsx), so no client-side route guard is required.
 */
export const routes: RoutesConfig = {
  basename,
  routes: {
    '/*': {
      component: AppShell,
      children: {
        '': { component: Home }
      },
    },
  },
};
