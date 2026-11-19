export const SUPPORTED_LOCALES = ['en', 'sv'] as const;

export type SupportedLocale = (typeof SUPPORTED_LOCALES)[number];

export const LOCALE_DISPLAY_NAMES: Record<string, string> = {
  en: 'English',
  sv: 'Svenska',
};
