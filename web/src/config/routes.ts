import { type RoutesConfig } from '@ifs-kairos/react/route';
import { AppShell } from '@ifs-kairos/react/shell';

import { Home } from '../pages/Home';
import { CountriesPage } from '../pages/CountriesPage';

// Get basename from Vite's base config (import.meta.env.BASE_URL)
// This ensures router paths match the deployment subpath.
const basename =
  import.meta.env.BASE_URL.replace(/\/$/, '') || '/';

export const routes: RoutesConfig = {
  basename,
  routes: {
    '/*': {
      component: AppShell,
      children: {
        '': {
          component: Home,
        },

        '/countries': {
          component: CountriesPage,
        },
      },
    },
  },
};