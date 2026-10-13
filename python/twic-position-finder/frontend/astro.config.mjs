// @ts-check
import { defineConfig } from 'astro/config';

// https://astro.build/config
// Crazyhouse Analysis needs cross-origin isolation for its threaded engine;
// public/_headers sets the same headers for these paths on Cloudflare.
/** @type {import('vite').Plugin} */
const crossOriginIsolated = {
  name: 'crazyhouse-cross-origin-isolation',
  configureServer(server) {
    server.middlewares.use((req, res, next) => {
      if (req.url?.startsWith('/crazyhouse')) {
        res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
        res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
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
