// @ts-check
import { defineConfig } from 'astro/config';

// https://astro.build/config
export default defineConfig({
  output: 'static',
  vite: {
    define: {
      'import.meta.env.PUBLIC_API_URL': JSON.stringify(
        process.env.PUBLIC_API_URL || 'https://api.chessautoprep.com'
      ),
      'import.meta.env.PUBLIC_TURNSTILE_SITE_KEY': JSON.stringify(
        process.env.PUBLIC_TURNSTILE_SITE_KEY || ''
      ),
    },
    server: {
      headers: {
        'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Embedder-Policy': 'require-corp',
      },
    },
  },
});
