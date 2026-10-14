// @ts-check
import { defineConfig } from 'astro/config';

// https://astro.build/config
// The bughouse board needs cross-origin isolation for its threaded engine;
// public/_headers sets the same headers for these paths on Cloudflare.
/** @type {import('vite').Plugin} */
const crossOriginIsolated = {
  name: 'bughouse-cross-origin-isolation',
  configureServer(server) {
    server.middlewares.use((req, res, next) => {
      const path = req.url?.split('?')[0] ?? '';
      if (path === '/bughouse' || path.startsWith('/bughouse/') || path.startsWith('/bughouse-engine/')) {
        res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
        res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
      } else if (!req.headers.accept?.includes('text/html')) {
        // Scripts and other files: the engine worker must be isolated to start
        // from the isolated page. The headers change nothing for other pages.
        res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
        res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
      }
      next();
    });
  },
};

export default defineConfig({
  output: 'static',
  vite: {
    plugins: [crossOriginIsolated],
    define: {
      'import.meta.env.PUBLIC_API_URL': JSON.stringify(
        process.env.PUBLIC_API_URL || 'https://api.chessautoprep.com'
      ),
      'import.meta.env.PUBLIC_TURNSTILE_SITE_KEY': JSON.stringify(
        process.env.PUBLIC_TURNSTILE_SITE_KEY || ''
      ),
    },
  },
});
