// Drives the built /bughouse-single-board page in headless Chrome with the
// real Hivemind engine: npm run build && node scripts/test-bughouse-single-browser.mjs.
// Screenshots land in build/bughouse-single-web/ at the repository root.
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';

const frontend = fileURLToPath(new URL('..', import.meta.url));
const output = path.resolve(frontend, '../../../build/bughouse-single-web');
await fs.mkdir(output, { recursive: true });
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm', '.json': 'application/json', '.svg': 'image/svg+xml', '.bin': 'application/octet-stream' };
const server = http.createServer(async (req, res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    let file = path.join(frontend, 'dist', pathname);
    if ((await fs.stat(file)).isDirectory()) file = path.join(file, 'index.html');
    res.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream');
    res.end(await fs.readFile(file));
  } catch { res.writeHead(404); res.end(); }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
// Chrome's singleton socket path must stay short; the job runner's TMPDIR is too long.
const chromeTmp = await fs.mkdtemp(path.join(os.homedir(), '.cache', 'bsb-'));
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome', headless: true,
  args: ['--disable-dev-shm-usage'], env: { ...process.env, TMPDIR: chromeTmp },
});
const ITALIAN = 'r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R[] w KQkq - 4 4';
const HOLE = 'r2q1rk1/pp3p1p/2n2Bp1/8/8/8/PPP2PPP/R2Q1RK1[] w - - 0 1';
const WAITING = '4R1k1/5ppp/8/8/8/8/5PPP/6K1[] b - - 0 1';
const url = (fen) => `${origin}/bughouse-single-board/?fen=${encodeURIComponent(fen)}`;
const fen = (page) => page.$eval('#ch-fen', (el) => el.value);
const text = (page, selector) => page.$eval(selector, (el) => el.textContent);
const evaluated = (page) => page.waitForFunction(() => /^[+\-#]?\d/.test(document.querySelector('#ch-pearl').textContent) && document.querySelectorAll('.ch-pv[data-uci]').length > 0, { timeout: 240_000 });
const sitDone = (page) => page.waitForFunction(() => {
  const rows = document.querySelectorAll('#bs-sit .bs-sit-row');
  return rows.length === 6 && ![...rows].some((r) => r.querySelector('.ch-spinner'));
}, { timeout: 400_000 });
const square = async (page, key) => {
  const box = await page.$eval('#ch-board', (el) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width }; });
  const file = key.charCodeAt(0) - 97, rank = Number(key[1]) - 1, s = box.w / 8;
  return { x: box.x + (file + 0.5) * s, y: box.y + (7 - rank + 0.5) * s };
};
const click = async (page, key) => { const p = await square(page, key); await page.mouse.click(p.x, p.y); };

try {
  const page = await browser.newPage();
  page.setDefaultTimeout(30_000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.setViewport({ width: 1440, height: 900 });
  // Small sit searches keep the check quick on a two-CPU runner.
  await page.goto(`${origin}/bughouse-single-board/`);
  await page.evaluate(() => localStorage.setItem('bughouse-single-board-v1', JSON.stringify({ sitNodes: 40, threads: 2 })));

  // Hivemind loads and evaluates; the gauge shows it; the sit panel fills.
  await page.goto(url(ITALIAN));
  await evaluated(page);
  console.log('Italian:', await text(page, '#ch-pearl'), await text(page, '#ch-engine-info'));
  assert.equal(await page.$eval('#ch-gauge', (el) => el.classList.contains('off')), false, 'the gauge shows the evaluation');
  await sitDone(page);
  console.log('sit panel:', (await page.$$eval('#bs-sit .bs-sit-row', (rows) => rows.map((r) => r.textContent))).join(' | '));
  await page.screenshot({ path: path.join(output, 'desktop.png') });

  // A capture leaves the board for the partner: no piece in the capturer's hand.
  await page.goto(url('rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR[] w KQkq d6 0 2'));
  await click(page, 'e4'); await click(page, 'd5');
  await page.waitForFunction(() => document.querySelector('#ch-fen').value.includes(' b '));
  assert.match(await fen(page), /\[\] b/, 'exd5 puts nothing in White’s hand');

  // A check a drop could block is not mate: Black waits, and the engine drops the knight it waits for.
  await page.goto(url(WAITING));
  await evaluated(page);
  assert.notEqual(await text(page, '#ch-pearl'), '#', 'not mate');
  assert.match(await text(page, '#ch-pvs'), /N@f8/);
  console.log('waiting:', await text(page, '#ch-pearl'), (await text(page, '#ch-pvs')).slice(0, 60));

  // The g7 hole: a knight, rook or queen would mate, so sit for the knight.
  await page.goto(url(HOLE));
  await sitDone(page);
  const verdict = await text(page, '.bs-sit-verdict');
  console.log('hole:', verdict);
  assert.match(verdict, /Sit for a knight/);
  // Hovering a row draws its move solid, in place of the engine's pale arrows.
  await page.hover('#bs-sit .bs-sit-row[data-role="knight"]');
  await page.waitForSelector('cg-container svg g[cgHash$=",h6,blue"]', { timeout: 5_000 });
  assert.equal(await page.$('cg-container svg g[cgHash*="paleBlue"]'), null, 'engine arrows give way to the hovered row');
  await page.screenshot({ path: path.join(output, 'sit-for-knight.png') });
  // Clicking the knight row gives White the knight; the engine then mates.
  await page.click('#bs-sit .bs-sit-row[data-role="knight"]');
  assert.match(await fen(page), /\[N\] w/);
  await page.waitForFunction(() => document.querySelector('#ch-pearl').textContent.startsWith('#'), { timeout: 120_000 });

  // A phone: board, hands with + and −, gauge, engine and sit panel.
  await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  await page.goto(url(ITALIAN));
  await evaluated(page);
  await sitDone(page);
  await page.screenshot({ path: path.join(output, 'mobile.png'), fullPage: true });
  // A phone widens its layout viewport to fit wide content, so measure against
  // the device width, not innerWidth.
  for (const width of [390, 360, 320]) {
    await page.setViewport({ width, height: 740, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
    // Chessground follows its new size one animation frame after the resize.
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const [wide, culprit] = await page.evaluate((width) => {
      const over = [...document.querySelectorAll('body *')].filter((el) => el.getBoundingClientRect().right > width + 1 && !el.closest('.nav-links'));
      return [document.documentElement.scrollWidth, over.slice(0, 3).map((el) => `${el.tagName}.${el.className}#${el.id}`).join(', ')];
    }, width);
    assert.ok(wide <= width, `no sideways scroll on a ${width} px phone (page is ${wide} px: ${culprit})`);
  }

  assert.deepEqual(errors, [], 'no page errors');
  console.log('bughouse single board browser: ok');
} finally {
  await browser.close();
  server.close();
  await fs.rm(chromeTmp, { recursive: true, force: true });
}
