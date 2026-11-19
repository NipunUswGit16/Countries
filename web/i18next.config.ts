import { defineConfig } from 'i18next-cli';
import { SUPPORTED_LOCALES } from './src/config/locales.ts';

export default defineConfig({
  locales: [...SUPPORTED_LOCALES],
  extract: {
    input: 'src/**/*.{js,jsx,ts,tsx}',
    ignore: ['src/**/*.{test,spec}.{ts,tsx}'],
    output: 'src/locales/{{language}}/{{namespace}}.json',
    // Server-message entries in response.config.ts use the two-string
    // i18n.t(key, defaultValue) form so the extractor picks them up directly;
    // preserve status.* keys that are temporarily commented out in the catalog.
    preservePatterns: ['status.*'],
  },
});

