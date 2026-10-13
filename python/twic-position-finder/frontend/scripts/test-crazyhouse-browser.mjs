// Drives the built /crazyhouse page in headless Chrome with the real engine:
// npm run build && node scripts/test-crazyhouse-browser.mjs. Screenshots land
// in build/crazyhouse-web/ at the repository root.
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';

const frontend = fileURLToPath(new URL('..', import.meta.url));
const output = path.resolve(frontend, '../../../build/crazyhouse-web');
await fs.mkdir(output, { recursive: true });
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm', '.json': 'application/json', '.svg': 'image/svg+xml', '.bin': 'application/octet-stream' };
// The same isolation headers as public/_headers.
const server = http.createServer(async (req, res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    let file = path.join(frontend, 'dist', pathname);
    if ((await fs.stat(file)).isDirectory()) file = path.join(file, 'index.html');
    if (pathname.startsWith('/crazyhouse')) {
      res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
      res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    }
    res.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream');
    res.end(await fs.readFile(file));
  } catch { res.writeHead(404); res.end(); }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
// Chrome's singleton socket path must stay short; the job runner's TMPDIR is too long.
const chromeTmp = await fs.mkdtemp(path.join(os.homedir(), '.cache', 'chc-'));
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome', headless: true,
  args: ['--disable-dev-shm-usage'], env: { ...process.env, TMPDIR: chromeTmp },
});
const fen = (page) => page.$eval('#ch-fen', (el) => el.value);
const square = async (page, key) => {
  const box = await page.$eval('#ch-board', (el) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width }; });
  const file = key.charCodeAt(0) - 97, rank = Number(key[1]) - 1, s = box.w / 8;
  return { x: box.x + (file + 0.5) * s, y: box.y + (7 - rank + 0.5) * s };
};
const click = async (page, key) => { const p = await square(page, key); await page.mouse.click(p.x, p.y); };
const evaluated = (page) => page.waitForFunction(() => /^[+\-#]?\d/.test(document.querySelector('#ch-pearl').textContent) && document.querySelectorAll('.ch-pv').length > 0, { timeout: 180_000 });

try {
  const page = await browser.newPage();
  page.setDefaultTimeout(30_000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.setViewport({ width: 1440, height: 900 });
  await page.goto(`${origin}/crazyhouse/?fen=${encodeURIComponent('r1bqkb1r/pppp1ppp/2n2n2/4p3/4P3/2N2N2/PPPP1PPP/R1BQKB1R[] w KQkq - 4 4')}`);
  assert.equal(await page.evaluate(() => crossOriginIsolated), true, 'the page is cross-origin isolated');

  // The engine downloads its net, starts and evaluates.
  await evaluated(page);
  const before = await page.$eval('#ch-pearl', (el) => el.textContent);
  console.log('eval without hands:', before, await page.$eval('#ch-engine-info', (el) => el.textContent));
  await page.screenshot({ path: path.join(output, 'analysis.png') });

  // + under Black's knight: the hand, the FEN and the eval follow.
  await page.click('#ch-hand-top .ch-adjust-pair:nth-child(2) .ch-step:last-child');
  assert.match(await fen(page), /\[n\] w/);
  assert.equal(await page.$eval('#ch-hand-top .zh-slot[data-role="knight"]', (el) => el.dataset.nb), '1');
  await page.waitForFunction((b) => {
    const t = document.querySelector('#ch-pearl').textContent;
    return /^[+\-#]?\d/.test(t) && t !== b && document.querySelector('#ch-engine-info').textContent.startsWith('Depth 1');
  }, { timeout: 120_000 }, before);
  const after = await page.$eval('#ch-pearl', (el) => el.textContent);
  console.log('eval with a knight in Black’s hand:', after);
  assert.ok(Number(after) < Number(before) - 1, 'a knight for Black is worth more than a pawn');
  assert.match(await page.$eval('#ch-moves', (el) => el.textContent), /Hands edited at the start: \+n/);

  // − takes it back; − at zero is disabled.
  await page.click('#ch-hand-top .ch-adjust-pair:nth-child(2) .ch-step:first-child');
  assert.match(await fen(page), /\[\] w/);
  assert.equal(await page.$eval('#ch-hand-top .ch-adjust-pair:nth-child(2) .ch-step:first-child', (el) => el.disabled), true);

  // Moves by clicking squares, then a drop from the hand by click-and-square.
  await click(page, 'd2'); await click(page, 'd4');
  await click(page, 'e5'); await click(page, 'd4');
  assert.match(await fen(page), /\[p\] w/, 'exd4 put a pawn in Black’s hand');
  await page.click('#ch-hand-bottom .ch-adjust-pair:nth-child(2) .ch-step:last-child'); // White +N
  await page.click('#ch-hand-bottom .zh-slot[data-role="knight"]');
  await click(page, 'd5');
  assert.match(await page.$eval('#ch-moves', (el) => el.textContent), /N@d5/);
  assert.match(await page.$eval('#ch-moves', (el) => el.textContent), /\+N/, 'the edit is marked in the moves');
  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('ArrowLeft');
  assert.match(await fen(page), /\[\] b/, 'back before exd4');
  await page.keyboard.press('ArrowDown');
  assert.match(await fen(page), /\/3N4\/.*\[p\] b/, 'last move: after N@d5');

  // PGN shows the line.
  assert.match(await page.$eval('#ch-pgn', (el) => el.value), /4\. d4 exd4 \{ Hands edited: \+N \} 5\. N@d5/);
  await evaluated(page);
  await page.screenshot({ path: path.join(output, 'analysis-line.png') });

  // Board editor: a white queen painted on h5 and a black pawn removed, then analysed.
  await page.click('#ch-edit');
  assert.equal(await page.$eval('#ch', (el) => el.dataset.mode), 'editor');
  await page.waitForSelector('#ch-spare-bottom:not([hidden]) .ch-spare-piece');
  const queen = await page.$('#ch-spare-bottom .ch-spare-piece:nth-child(3)');
  await queen.click();
  await new Promise((r) => setTimeout(r, 200));
  await click(page, 'h5');
  assert.match(await fen(page), /\/3N3Q\//, 'the queen is on h5');
  await page.click('#ch-spare-top .ch-trash');
  await click(page, 'a7');
  assert.doesNotMatch(await fen(page), /^r1bqkb1r\/pppp/);
  await page.click('#ch-hand-top .ch-adjust-pair:nth-child(5) .ch-step:last-child'); // Black +Q in the editor
  assert.match(await fen(page), /\[[^\]]*q[^\]]*\]/);
  await page.screenshot({ path: path.join(output, 'editor.png') });
  await page.click('#ch-turn button[data-turn="black"]');
  await page.click('#ch-editor-apply');
  assert.equal(await page.$eval('#ch', (el) => el.dataset.mode), 'analysis');
  assert.match(await fen(page), / b /);
  await evaluated(page);

  // Narrow screen.
  await page.setViewport({ width: 420, height: 900 });
  await new Promise((r) => setTimeout(r, 300));
  await page.screenshot({ path: path.join(output, 'narrow.png'), fullPage: true });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'no sideways scroll');

  assert.deepEqual(errors.filter((e) => !e.includes('favicon')), []);
  console.log('crazyhouse browser: ok');
} finally {
  await browser.close();
  server.close();
  await fs.rm(chromeTmp, { recursive: true, force: true });
}
