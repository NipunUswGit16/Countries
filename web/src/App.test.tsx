import { test, expect, vi } from 'vitest';
import { renderApp, screen } from './test-utils';
import App from './App';

vi.hoisted(() => {
  const store = new Map<string, string>();
  const localStorageMock: Storage = {
    getItem: (key) => store.get(key) ?? null,
    setItem: (key, value) => void store.set(key, String(value)),
    removeItem: (key) => void store.delete(key),
    clear: () => store.clear(),
    key: (index) => Array.from(store.keys())[index] ?? null,
    get length() {
      return store.size;
    },
  };
  const target = typeof window !== 'undefined' ? window : globalThis;
  Object.defineProperty(target, 'localStorage', {
    value: localStorageMock,
    configurable: true,
    writable: true,
  });
});

test('App should be rendered', () => {
  renderApp(<App />);
  expect(screen.getByRole('heading', { name: 'Welcome!' })).toBeInTheDocument();
  expect(
    screen.getByText(
      'This is the start page of the Kairos Template for your application.',
    ),
  ).toBeInTheDocument();
});
