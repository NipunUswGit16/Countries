import fs from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';
import { defineConfig, loadEnv, type Plugin, type ProxyOptions } from 'vite';
import react from '@vitejs/plugin-react-swc';
import checker from 'vite-plugin-checker';

/**
 * In dev, serves /env.js with ${VAR} placeholders replaced from .env
 * so window.__ENV__ works without changing public/env.js (Helm still substitutes at deploy).
 */
function envJsDevPlugin(): Plugin {
  function pathname(url: string): string {
    const q = url.indexOf('?');
    return q === -1 ? url : url.slice(0, q);
  }

  return {
    name: 'env-js-dev',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use(
        (req: IncomingMessage, res: ServerResponse, next: () => void) => {
          const url = req.url ?? '';
          if (pathname(url) !== '/env.js') {
            next();
            return;
          }
          const env = loadEnv('', process.cwd(), '');
          const filePath = path.resolve(process.cwd(), 'public', 'env.js');
          let content: string;
          try {
            content = fs.readFileSync(filePath, 'utf-8');
          } catch {
            next();
            return;
          }
          const substituted = content.replace(/\$\{(\w+)\}/g, (_, name) => {
            const value = env[name];
            return value !== undefined ? value : '';
          });
          res.setHeader('Content-Type', 'application/javascript');
          res.setHeader('Cache-Control', 'no-store');
          res.end(substituted);
        },
      );
    },
  };
}

/**
 * Cache busting the env file by adding timestamp as query param.
 * Uses generateBundle (not transformIndexHtml, which is unreliable in Vite 7)
 * to rewrite the built HTML after Vite has emitted it.
 */
function cacheBustPlugin(): Plugin {
  return {
    name: 'html-cache-bust',
    apply: 'build',
    enforce: 'post',
    generateBundle(_, bundle) {
      for (const chunk of Object.values(bundle)) {
        if (
          chunk.type === 'asset' &&
          chunk.fileName.endsWith('.html') &&
          typeof chunk.source === 'string'
        ) {
          chunk.source = chunk.source.replace(
            /env\.js(["'])/,
            `env.js?v=${Date.now()}$1`,
          );
        }
      }
    },
  };
}

/**
 * Gateway logout 302s to IAM. Vite never sees IAM's later 302, so rewrite
 * post_logout_redirect_uri on the gateway Location so IAM returns to the
 * Vite origin instead of the cluster host.
 */
function rewriteIamLogoutReturnToVite(
  location: string | number | string[] | undefined,
  status: number,
  host: string | undefined,
): string | undefined {
  if (status !== 302 || typeof location !== 'string' || location === '') {
    return undefined;
  }

  let dest: URL;
  try {
    dest = new URL(location);
  } catch {
    return undefined;
  }

  if (!dest.pathname.endsWith('/oauth2/logout')) {
    return undefined;
  }

  const origin = `http://${host ?? 'localhost:5173'}`;
  dest.searchParams.set('post_logout_redirect_uri', `${origin}/`);
  return dest.toString();
}

// https://vite.dev/config/
export default defineConfig(({ command, mode }) => {
  const isBuild = command === 'build';
  const env = loadEnv(mode, process.cwd(), '');
  const toProxyPath = (p: string) => (p.startsWith('/') ? p : `/${p}`);

  // Get production base path. By default the base path matches the bounded
  // context name, but can be overridden by external build scripts if needed.
  const explicitBasePath = process.env.KAIROS_BASE_PATH;
  const productionBase = explicitBasePath || '/countries/';
  const appBasePath = explicitBasePath || '/countries';
  const devProxyTarget = 'https://local.pac.ifsdevworld.com';

  const proxyRewrite: ProxyOptions = {
    target: devProxyTarget,
    changeOrigin: true,
    secure: false,
    rewrite: (path: string) => appBasePath + path,
  };

  const proxy: Record<string, ProxyOptions> = {};

  const apiBasePath = env.API_BASE_PATH || 'api/v1';
  if (apiBasePath) {
    proxy[toProxyPath(apiBasePath)] = proxyRewrite;
  }
  const authBasePath = env.AUTH_BASE_PATH || 'auth/v1';
  if (authBasePath) {
    proxy[toProxyPath(authBasePath)] = {
      ...proxyRewrite,
      configure(proxyServer) {
        proxyServer.on('proxyRes', (proxyRes, req) => {
          const rewritten = rewriteIamLogoutReturnToVite(
            proxyRes.headers.location,
            proxyRes.statusCode ?? 0,
            req.headers.host,
          );
          if (rewritten !== undefined) {
            proxyRes.headers.location = rewritten;
          }
        });
      },
    };
  }

  return {
    // Only apply base path in production.
    base: mode === 'production' ? productionBase : '/',
    plugins: [
      react(),
      envJsDevPlugin(),
      cacheBustPlugin(),
      // In-browser type errors for the dev server only. `vite build` just
      // bundles: the checker would run a full `tsc -b` in the same process,
      // which takes several times the memory of the bundle and can get an image
      // build killed on a memory-limited build pod. Gate on `pnpm typecheck`.
      ...(command === 'serve'
        ? [
            checker({
              typescript: {
                tsconfigPath: './tsconfig.json',
                buildMode: true,
              },
            }),
          ]
        : []),
    ],
    server: {
      proxy: proxy,
    },
    optimizeDeps: {
      include: ['lit', '@lit/reactive-element', 'lit-html'],
      exclude: ['@ifs-kairos/ffw-components'],
    },
    resolve: {
      preserveSymlinks: false,
      // Dev needs all three for dedupe, build only needs lit
      dedupe: isBuild ? [] : ['lit', '@lit/reactive-element', 'lit-html'],
      // Exclude 'development' condition so @ifs-ds/helix-web-components resolves to
      // dist/index.js instead of src/index.ts (src is not published to npm)
      conditions: ['module', 'browser', 'production'],
    },
  };
});
