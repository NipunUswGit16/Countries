import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react-swc';

export default defineConfig(({ mode }) => ({
  plugins: [react()],
  resolve: {
    conditions: mode === 'test' ? ['browser'] : [],
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['./vitest-setup.ts'],
    server: {
      deps: {
        inline: ['@ifs-ds/helix-design-tokens', '@ifs-ds/helix-web-components'],
      },
    },
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov', 'json-summary'],
      reportsDirectory: './coverage',
      include: ['src/**/*.{ts,tsx}'],
      exclude: ['**/*.test.{ts,tsx}', '**/*.spec.{ts,tsx}', '**/*.d.ts'],
    },
  },
}));
