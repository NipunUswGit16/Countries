import type { AppConfig } from '@ifs-kairos/react/app-config';

import { t } from './i18n';

/**
 * Application Configuration
 *
 * This is the main configuration file for your application.
 * Modify these values to customize the header, menus, and toolbar buttons.
 *
 * User-visible strings use `t(key, default)` so i18next-cli can extract keys and
 * locales can override copy in `src/locales/<lang>/translation.json`.
 * Ensure `./i18n` is initialized before this module (see `main.tsx`).
 *
 * For notification badges, the NotificationsProvider automatically keeps
 * the "notifications-button" badge in sync with the unread count.
 *
 * For other button badges, use the useAppConfig() hook:
 * @example
 * const { updateButtonNotification } = useAppConfig();
 * updateButtonNotification('chat-button', 5);
 */
export const appConfig: AppConfig = {
  // Header title, not visible in mobile view.
  title: 'countries',

  // Handle menu item clicks not handled by built-in logic (sign-out, notifications, theme, routing).
  // Use this for custom menu items like app switcher items, help buttons, etc.
  onMenuItemClicked: (detail) => {
    console.log('Unhandled menu item clicked:', detail.id, detail);
  },

  // Enable/disable the home button in the header
  homeButtonEnabled: false,

  // Main navigation menu (left sidebar). Use this for navigation within the bounded context.
  menuItems: [
    {
      type: 'item',
      id: 'pages',
      label: t('app.menu.pages', 'Pages'),
      icon: 'app-generic',
      items: [
        {
          type: 'item',
          id: 'home',
          label: t('app.menu.home', 'Home'),
          icon: 'home',
          data: { route: '/' },
        },
      ],
    },
  ],

  // Apps menu (app switcher dropdown in header). Use this for navigation between bounded contexts.
  appsMenuItems: [],

  // Profile dropdown menu
  // Note: The 'theme' item's sub-items are generated dynamically from AVAILABLE_THEMES
  // Note: The 'language' item's sub-items are generated from SUPPORTED_LOCALES (locales.ts)
  profileMenuItems: [
    {
      type: 'item',
      id: 'theme',
      label: t('app.profile.theme', 'Theme'),
      icon: 'dark-theme',
    },
    {
      type: 'item',
      id: 'language',
      label: t('app.profile.language', 'Language'),
      icon: 'local-language',
    },
    {
      type: 'item',
      id: 'sign-out',
      label: t('app.profile.signOut', 'Sign Out'),
      icon: 'sign-out',
    },
  ],

  // Additional toolbar buttons in the header
  // The notifications button badge is managed automatically by NotificationsProvider.
  // Other button badges can be updated at runtime using useAppConfig().
  additionalButtons: [
    {
      type: 'item',
      id: 'notifications-button',
      label: t('app.toolbar.notifications', 'Notifications'),
      icon: 'alert-badge',
    },
  ],
};
