import { initReactI18next } from 'react-i18next';
import { initKairosI18n } from '@ifs-kairos/translation';
import { LOCALE_DISPLAY_NAMES, SUPPORTED_LOCALES } from './locales';

const translationModules = import.meta.glob<{
  default?: Record<string, unknown>;
}>('../locales/*/translation.json', { eager: true });

export const { t, i18n, switchLocale, persistLocaleAndReload } = initKairosI18n(
  {
    supportedLocales: SUPPORTED_LOCALES,
    localeDisplayNames: LOCALE_DISPLAY_NAMES,
    translationModules,
    dev: import.meta.env.DEV,
  },
  initReactI18next,
);
