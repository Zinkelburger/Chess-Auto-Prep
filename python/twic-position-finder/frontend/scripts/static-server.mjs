// Serves the built site (dist/) for the browser checks as Cloudflare Pages
// would: every rule in public/_headers whose path matches adds its headers,
// so a cross-origin isolation mistake fails here instead of in production.
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';

const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css',
  '.wasm': 'application/wasm', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp',
  '.png': 'image/png', '.bin': 'application/octet-stream',
};

/** The rules of a Cloudflare `_headers` file: a path pattern, then indented `Name: value` lines. */
function parseHeaders(text) {
  const rules = [];
  for (const line of text.split('\n')) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    if (!/^\s/.test(line)) {
      const pattern = line.trim().replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/:[A-Za-z]\w*/g, '[^/]+');
      rules.push({ match: new RegExp(`^${pattern}$`), headers: [] });
    } else if (rules.length) {
      const at = line.indexOf(':');
      rules.at(-1).headers.push([line.slice(0, at).trim(), line.slice(at + 1).trim()]);
    }
  }
  return rules;
}

/** Starts the server on a free port; resolves to its origin and a close function. */
export async function serveDist(frontend) {
  const rules = parseHeaders(await fs.readFile(path.join(frontend, 'public/_headers'), 'utf8'));
  const server = http.createServer(async (req, res) => {
    try {
      const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
      let file = path.join(frontend, 'dist', pathname);
      if ((await fs.stat(file)).isDirectory()) file = path.join(file, 'index.html');
      for (const rule of rules) if (rule.match.test(pathname)) for (const [name, value] of rule.headers) res.setHeader(name, value);
      res.setHeader('Content-Type', TYPES[path.extname(file)] || 'application/octet-stream');
      res.end(await fs.readFile(file));
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { origin: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}
