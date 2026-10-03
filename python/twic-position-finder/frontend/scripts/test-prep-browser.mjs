import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';
const frontend = fileURLToPath(new URL('..', import.meta.url));
const root = path.resolve(frontend, '../../..');
const output = path.join(root, 'build/prep-web');
await fs.mkdir(output, { recursive: true });
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp' };
const server = http.createServer(async (req, res) => {
  try { let file = path.join(frontend, 'dist', decodeURIComponent(new URL(req.url, 'http://localhost').pathname)); if ((await fs.stat(file)).isDirectory()) file = path.join(file, 'index.html'); res.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream'); res.end(await fs.readFile(file)); }
  catch { res.writeHead(404); res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome', headless: true, args: ['--disable-dev-shm-usage'] });
try {
  const page = await browser.newPage(); page.setDefaultTimeout(30000);
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  page.on('dialog', dialog => dialog.accept());
  await page.setViewport({ width: 1440, height: 1100 });
  await page.setRequestInterception(true);
  page.on('request', req => req.url().startsWith(origin) || req.url().startsWith('data:') || req.url().startsWith('blob:') ? req.continue() : req.abort());
  const fill = async (selector, text) => page.$eval(selector, (el, value) => { el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })); }, text);
  const text = selector => page.$eval(selector, el => el.textContent);
  const saved = () => page.waitForFunction(() => document.querySelector('#save-status').textContent === 'Saved in this browser.');
  const importPgn = async pgn => { await page.$eval('#import-panel', el => el.open = true); await fill('#pgn-text', pgn); await page.click('#import-pgn'); await saved(); };
  const idle = () => page.waitForFunction(() => !document.querySelector('#start-search').disabled, { timeout: 180000 });
  const pgn = '[Event "Browser fixture"]\n[White "Alice"]\n[Black "Bob"]\n1.e4 {King pawn} e5 2.Nf3 (2.Bc4 Nc6) Nc6 *\n\n[Event "Second"]\n1.d4 d5 *';
  await page.goto(origin + '/pgn/');
  await page.waitForFunction(() => !document.querySelector('#save-status').textContent.includes('Loading'));
  await importPgn(pgn);
  assert.equal(await page.$$eval('#game-list button', nodes => nodes.length), 2);
  assert.ok((await text('#move-tree')).includes('Bc4'));
  await page.click('#move-tree [data-node="4"]');
  assert.match(await page.$eval('#prep-board', el => el.getAttribute('aria-label')), /2B1P3/);
  await fill('#move-input', 'Nf6'); await page.click('#move-form button'); await saved();
  const accepted = await page.$eval('#prep-board', el => el.getAttribute('aria-label'));
  await page.reload(); await page.waitForFunction(() => document.querySelector('#save-status').textContent.includes('Restored'));
  assert.equal(await page.$eval('#prep-board', el => el.getAttribute('aria-label')), accepted, 'appended variation cursor survives PGN serialization order');
  await page.$eval('#import-panel', el => el.open = true); await fill('#pgn-text', '1. e9'); await page.click('#import-pgn');
  await page.waitForFunction(() => !document.querySelector('#prep-error').hidden);
  assert.equal(await page.$eval('#prep-board', el => el.getAttribute('aria-label')), accepted, 'bad import retains accepted game');
  await importPgn(pgn);
  // Capture an export through the native download mechanism and inspect its bytes.
  const session = await page.createCDPSession();
  await session.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: output });
  await page.click('#export-pgn');
  let exported;
  for (let i = 0; i < 100; i++) { try { exported = await fs.readFile(path.join(output, 'chess-auto-prep.pgn'), 'utf8'); break; } catch { await new Promise(r => setTimeout(r, 50)); } }
  assert.ok(exported.includes('Bc4')); assert.ok(exported.includes('King pawn'));
  await page.screenshot({ path: path.join(output, 'pgn-desktop.png'), fullPage: true });
  await page.setViewport({ width: 390, height: 844 });
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), JSON.stringify(await page.evaluate(() => [...document.querySelectorAll('body *')].filter(e => e.getBoundingClientRect().right > innerWidth + 1).slice(0, 12).map(e => [e.tagName, e.id, e.className, e.getBoundingClientRect().right]))));
  await page.screenshot({ path: path.join(output, 'pgn-mobile.png'), fullPage: true });
  await page.setViewport({ width: 1440, height: 1100 });
  console.log('PGN imports, variations, edits, durable restoration, invalid-import recovery, export and phone layout passed.');

  await page.goto(origin + '/expectimax/');
  await page.waitForFunction(() => document.querySelector('#save-status').textContent.includes('Restored'));
  // Black is the modelled opponent at the root; three plies also exercise maximizing turns.
  await importPgn('[FEN "7k/6pp/8/8/8/8/6PP/7K b - - 0 1"]\n*');
  await fill('#search-plies', '2'); await fill('#search-depth', '6'); await fill('#search-nodes', '100');
  await page.click('#start-search'); await idle();
  assert.equal(await page.$eval('#prep-error', el => el.hidden), true, await text('#prep-error'));
  assert.match(await text('#search-status'), /Complete/);
  assert.ok(await page.$$eval('.prep-results-table tbody tr', rows => rows.length > 0));
  const shares = await page.$$eval('.prep-results-table tbody tr', rows => rows.map(row => Number(row.cells[3].textContent.replace('%',''))));
  assert.ok(Math.abs(shares.reduce((a,b) => a+b,0) - 100) < .3, 'Maia reply shares sum to 100');
  await saved();
  await page.screenshot({ path: path.join(output, 'expectimax-desktop.png'), fullPage: true });
  await page.setViewport({ width: 390, height: 844 });
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), JSON.stringify(await page.evaluate(() => [...document.querySelectorAll('body *')].filter(e => e.getBoundingClientRect().right > innerWidth + 1).slice(0, 12).map(e => [e.tagName, e.id, e.className, e.getBoundingClientRect().right]))));
  await page.screenshot({ path: path.join(output, 'expectimax-mobile.png'), fullPage: true });
  await page.setViewport({ width: 1440, height: 1100 });
  await page.reload(); await page.waitForFunction(() => document.querySelector('.prep-results-table'));
  assert.match(await text('#search-status'), /Complete/);
  await fill('#search-plies', '4'); await fill('#search-nodes', '50'); await page.click('#start-search'); await idle();
  assert.match(await text('#search-status'), /budget/);
  await fill('#search-nodes', '100'); await page.click('#resume-search'); await idle();
  assert.match(await text('#search-status'), /budget|Complete/);
  await fill('#search-plies', '8'); await fill('#search-depth', '14'); await page.click('#start-search');
  await page.waitForFunction(() => !document.querySelector('#stop-search').disabled); await page.click('#stop-search'); await idle();
  await fill('#search-depth', '6'); await page.click('#analyse-position'); await idle();
  assert.match(await text('#position-score'), /depth 6/);
  // The same initialized model and engines work with the connection removed.
  await page.setOfflineMode(true); await fill('#search-plies', '1'); await page.click('#start-search'); await idle();
  assert.equal(await page.$eval('#prep-error', el => el.hidden), true, await text('#prep-error'));
  await page.setOfflineMode(false);
  console.log('Real Stockfish + Maia expectimax, saved results, budget/resume, stop/retry and offline inference passed.');

  await page.goto(origin + '/tactics/');
  const local = path.join(output, 'tactics-fixture.pgn');
  await fs.writeFile(local, '[White "Alice"]\n[Black "Bob"]\n1. e4 e5 2. Qh5 Nc6 3. Qxe5+ Nxe5 *');
  await (await page.$('#tactics-pgn')).uploadFile(local);
  await page.waitForFunction(() => document.querySelector('#tactics-pgn-name').textContent.includes('tactics-fixture'));
  await page.$eval('details.advanced', el => el.open = true);
  await fill('#f-depth', '8'); await fill('#f-workers', '1'); await page.click('#btn-start');
  await page.waitForFunction(() => !document.querySelector('#view-train').hidden, { timeout: 120000 });
  await page.click('#btn-solution'); assert.equal(await page.$eval('#tr-line', el => el.hidden), false);
  assert.ok((await page.$eval('#tr-analyse-link', el => el.getAttribute('href'))).startsWith('/pgn/?fen='));
  await page.waitForFunction(() => document.querySelector('#tactics-save').textContent.includes('saved'));
  await page.screenshot({ path: path.join(output, 'tactics-desktop.png'), fullPage: true });
  await page.setViewport({ width: 390, height: 844 });
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), JSON.stringify(await page.evaluate(() => [...document.querySelectorAll('body *')].filter(e => e.getBoundingClientRect().right > innerWidth + 1).slice(0, 12).map(e => [e.tagName, e.id, e.className, e.getBoundingClientRect().right]))));
  await page.screenshot({ path: path.join(output, 'tactics-mobile.png'), fullPage: true });
  await page.reload(); await page.waitForFunction(() => !document.querySelector('#resume-tactics').hidden);
  await page.click('#resume-tactics'); assert.equal(await page.$eval('#view-train', el => el.hidden), false);
  console.log('PGN tactics mining with real Stockfish, solution, local viewer link and persisted training passed.');
  assert.deepEqual(errors, [], 'no browser exceptions');
  console.log(`Screenshots: ${output}`);
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
