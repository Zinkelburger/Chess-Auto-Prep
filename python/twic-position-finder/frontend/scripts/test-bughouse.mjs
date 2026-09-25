import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs/promises';
import puppeteer from 'puppeteer-core';

const [origin, output] = process.argv.slice(2);
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome', headless: true, args: ['--disable-dev-shm-usage'] });
let page;
try {
  const context = browser.defaultBrowserContext();
  const clipboardPermission = (state) => context.setPermission(origin, { permission: { name: 'clipboard-read' }, state }, { permission: { name: 'clipboard-write', allowWithoutSanitization: false }, state });
  await clipboardPermission('granted');
  page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 720, deviceScaleFactor: 1 });
  const errors = [], forbidden = [], assets = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('request', (r) => {
    if (r.method() !== 'GET' || r.url().includes('/api/')) forbidden.push(r.url());
    if (r.url().includes('/bughouse-engine/')) assets.push(r.url());
  });
  const ready = () => page.waitForFunction(() => !document.querySelector('#bh-copy').disabled && document.querySelector('#bh-fen-A').value);
  const text = (selector) => page.$eval(selector, (e) => e.textContent);
  const fen = (board) => page.$eval(`#bh-fen-${board}`, (e) => e.value);
  const fill = (selector, value) => page.locator(selector).fill(value);
  const topClick = async (selector) => {
    await page.evaluate(() => { scrollTo(0, 0); });
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(resolve)));
    await page.click(selector);
  };
  const square = async (board, key) => page.$eval(`#bh-board-${board}`, (e, key) => {
    const b = e.querySelector('cg-board').getBoundingClientRect(), white = e.classList.contains('orientation-white');
    const file = key.charCodeAt(0) - 97, rank = Number(key[1]) - 1;
    return { x: b.x + (white ? file + .5 : 7.5 - file) * b.width / 8, y: b.y + (white ? 7.5 - rank : rank + .5) * b.height / 8 };
  }, key);
  async function clickSquare(board, key) { await page.$eval(`#bh-board-${board}`, (e) => e.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' })); await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))); const p = await square(board, key); await page.mouse.click(p.x, p.y); }
  async function move(board, from, to) { await clickSquare(board, from); await clickSquare(board, to); await ready(); }
  async function enter(board, move) {
    if (!await page.$eval('.bh-keyboard', e => e.open)) await page.click('.bh-keyboard summary');
    await page.select('#bh-move-board', board); await fill('#bh-move', move); await page.click('#bh-move-form button'); await ready();
  }
  async function pawnOn(board, squareName, colour) {
    const target = await square(board, squareName);
    await page.waitForFunction((board, colour, target) => [...document.querySelectorAll(`#bh-board-${board} piece.${colour}.pawn`)].some((e) => {
      const b = e.getBoundingClientRect(); return Math.abs(b.x + b.width / 2 - target.x) < 2 && Math.abs(b.y + b.height / 2 - target.y) < 2;
    }), {}, board, colour, target);
  }
  async function setup(a, b = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1') {
    if (await page.$eval('#bh-edit', (e) => e.getAttribute('aria-expanded')) !== 'true') await page.click('#bh-edit');
    await fill('#bh-fen-A', a); await fill('#bh-fen-B', b);
    for (const name of ['A', 'B']) for (const colour of ['white', 'black']) await fill(`#bh-reserve-${name}-${colour}`, '');
    await page.click('.bb-set'); await ready();
  }
  const analyze = async () => {
    await page.click('#bh-analyse');
    await page.waitForFunction(() => !document.querySelector('#bh-stop').hidden || document.querySelector('.bh-table'));
    await ready();
    assert.ok(await page.$('.bh-table'), await text('#bh-status'));
  };
  await page.goto(`${origin}/bughouse/`, { waitUntil: 'networkidle0' }); await ready();
  assert.equal(await page.$$eval('cg-board', (e) => e.length), 2);
  assert.equal(await page.$$eval('cg-board piece', (e) => e.length), 64);
  assert.equal(assets.some((u) => /model-.*\.bin/.test(u)), false, 'moving does not load the network');
  await move('A', 'e2', 'e4'); await move('A', 'd7', 'd5'); await move('A', 'e4', 'd5'); await enter('B', 'e4');
  const pawn = '[aria-label="Player B: 1 pawn in reserve"]';
  assert.equal(await page.$eval(pawn, (e) => e.disabled), false);
  await page.click(pawn); await clickSquare('B', 'e6'); await ready();
  await pawnOn('B', 'e6', 'black');
  console.log('Moves, cross-board capture and drop passed.');
  const captured = await fen('A');
  for (let i = 0; i < 3; i++) {
    await page.click('#bh-prev-A'); await ready();
    assert.match(await text('#bh-status'), /Position unchanged/);
    assert.equal(await fen('A'), captured);
    assert.equal(await text('#bh-history-A [aria-current="true"]'), 'exd5');
  }
  await page.click('#bh-prev-B'); await ready(); assert.ok(await page.$(pawn));
  await page.click('#bh-next-B'); await ready();
  await topClick('#bh-copy');
  await page.waitForFunction(() => document.querySelector('#bh-copy-status').textContent === 'Moves copied');
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  assert.match(copied, /1A\. e4 1a\. d5 2A\. exd5 1B\. e4 1b\. P@e6/);
  await clipboardPermission('denied');
  await topClick('#bh-copy'); await page.waitForSelector('#bh-copy-dialog[open]');
  assert.equal(await page.$eval('#bh-copy-text', (e) => e.value), copied);
  await page.click('#bh-copy-close');
  await clipboardPermission('granted');
  await topClick('#bh-share'); await page.waitForFunction(() => document.querySelector('#bh-copy-status').textContent === 'Link copied'); const link = await page.evaluate(() => navigator.clipboard.readText());
  assert.match(link, /#lab=/);
  const otherContext = await browser.createBrowserContext();
  const other = await otherContext.newPage(); await other.goto(link);
  await other.waitForFunction(() => document.querySelector('#bh-history-B').textContent.includes('P@e6'));
  assert.equal(await other.$eval('#bh-fen-A', (e) => e.value), captured);
  await otherContext.close(); await page.bringToFront();
  const cdp = await page.createCDPSession();
  await cdp.send('Page.setDownloadBehavior', { behavior: 'allow', downloadPath: output });
  await topClick('#bh-download');
  let downloaded;
  for (let i = 0; i < 30; i++) {
    try { downloaded = await fs.readFile(path.join(output, 'bughouse-analysis.bpgn'), 'utf8'); break; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
  assert.equal(downloaded, copied);
  await page.reload({ waitUntil: 'networkidle0' }); await ready();
  assert.equal(await fen('A'), captured);
  assert.equal(await text('#bh-history-B [aria-current="true"]'), 'P@e6');
  await page.click('#bh-reset'); await ready(); await page.click('#bh-undo-reset'); await ready(); assert.equal(await fen('A'), captured);

  console.log('History rollback, copy/download, shared link and saved session passed.');

  // Cancellation, Escape, all four white/black promotions, and promoted captures.
  for (const cancel of ['button', 'escape']) {
    await setup('7k/P7/8/8/8/8/8/7K w - - 0 1');
    await clickSquare('A', 'a7'); await clickSquare('A', 'a8');
    await page.waitForSelector('#bh-promotion[open]');
    if (cancel === 'button') await page.click('#bh-promotion-cancel'); else await page.keyboard.press('Escape');
    await pawnOn('A', 'a7', 'white');
    assert.match(await fen('A'), /7k\/P7/); assert.equal(await page.$$eval('#bh-history-A button', (e) => e.length), 0);
  }
  const roles = [['queen', 'Q'], ['rook', 'R'], ['bishop', 'B'], ['knight', 'N']];
  for (const colour of ['white', 'black']) for (const [, piece] of roles) {
    await setup(colour === 'white' ? '7k/P7/8/8/8/8/8/7K w - - 0 1' : '7k/8/8/8/8/8/p7/7K b - - 0 1');
    await clickSquare('A', colour === 'white' ? 'a7' : 'a2'); await clickSquare('A', colour === 'white' ? 'a8' : 'a1');
    await page.waitForSelector('#bh-promotion[open]');
    await page.click(`#bh-promotion-options button[data-promotion="${piece.toLowerCase()}"]`); await ready();
    assert.ok((await fen('A')).includes((colour === 'white' ? piece : piece.toLowerCase()) + '~'));
    assert.ok((await text('#bh-history-A')).includes('=' + piece));
  }
  await setup('1r5k/P7/8/8/8/8/8/7K w - - 0 1');
  await enter('A', 'a8=N'); await enter('A', 'Rxa8');
  assert.equal(await page.$eval('#bh-reserve-B-white', (e) => e.value), 'P');
  await setup('7k/8/8/1B6/2p5/1P6/8/7K w - - 0 1');
  await enter('A', 'Bxc4'); assert.match(await fen('A'), /2B5\/1P6/);
  await setup('7k/8/8/1B6/2p5/1P6/8/7K w - - 0 1');
  await enter('A', 'bxc4'); assert.match(await fen('A'), /1B6\/2P5/);
  await fill('#bh-fen-B', 'invalid'); await page.click('.bb-set'); assert.match(await text('#bh-fen-error-B'), /ranks/);
  await page.click('#bh-reset'); await ready();
  if (await page.$eval('#bh-edit', (e) => e.getAttribute('aria-expanded')) === 'true') await page.click('#bh-edit');

  console.log('Promotion and invalid setup passed.');

  // Interrupt the first network transfer; retry must retain the worker.
  await page.setRequestInterception(true);
  let held;
  const hold = (r) => { if (!held && /\/model-.*\.bin$/.test(r.url())) held = r; else void r.continue(); };
  page.on('request', hold);
  await page.click('#bh-analyse');
  await page.waitForFunction(() => document.querySelector('#bh-status').textContent.includes('Downloading'));
  await page.click('#bh-stop'); await ready(); assert.match(await text('#bh-status'), /cancelled/);
  if (held && !held.isInterceptResolutionHandled()) await held.abort().catch(() => {});
  page.off('request', hold); await page.setRequestInterception(false);
  await analyze();
  assert.match(await text('#bh-result'), /Waiting for opponent/);
  assert.ok(!(await text('#bh-result')).includes('D sits'));
  if (await page.$eval('.bh-keyboard', e => e.open)) await page.click('.bh-keyboard summary');
  await page.evaluate(() => scrollTo(0, 0));
  await page.screenshot({ path: path.join(output, 'bughouse-desktop.png'), fullPage: true });
  console.log('Real neural analysis and download cancellation/retry passed.');
  if (await page.$eval('.bh-keyboard', e => e.open)) await page.click('.bh-keyboard summary');
  const loadedAssets = assets.length;
  const again = Date.now(); await analyze();
  assert.ok(Date.now() - again < 2000, 'completed analysis should be reused');
  assert.match(await text('#bh-status'), /saved in this tab/);
  assert.equal(assets.length, loadedAssets, 'repeat analysis must not fetch engine/model again');
  await page.click('.bh-table tbody tr'); await ready();
  assert.equal(await page.$eval('#bh-analyse', (e) => e.disabled), true, 'unavailable team cannot start a search');
  await page.click('#bh-reset'); await ready();
  // New positions and cancellation work after all networking is disabled.
  await page.setOfflineMode(true);
  await enter('A', 'e4'); await enter('B', 'd4');
  await page.click('input[name="team"][value="black"] + span');
  await page.click('input[name="budget"][value="30000"] + span');
  await page.click('#bh-analyse'); await page.waitForFunction(() => document.querySelector('#bh-status').textContent.includes('searching for our team'));
  await page.click('#bh-stop'); await ready(); assert.match(await text('#bh-status'), /cancelled/);
  await page.click('input[name="budget"][value="3000"] + span'); await analyze();
  assert.equal(assets.length, loadedAssets);
  await page.evaluate(() => scrollTo(0, 0));
  await page.screenshot({ path: path.join(output, 'bughouse-offline.png'), fullPage: true });
  await page.setOfflineMode(false);
  // Reopening the page reinitializes memory, but uses its persistent model chunks.
  await page.reload({ waitUntil: 'networkidle0' }); await ready();
  const beforeReloadSearch = assets.filter((u) => /model-.*\.bin$/.test(u)).length;
  await analyze(); assert.equal(assets.filter((u) => /model-.*\.bin$/.test(u)).length, beforeReloadSearch);
  await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 1 });
  await page.reload({ waitUntil: 'networkidle0' }); await ready();
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'phone width');
  assert.ok(await page.$eval('#bh-analyse', (e) => e.getBoundingClientRect().bottom < innerHeight), 'Analyze must be above the fold');
  await page.screenshot({ path: path.join(output, 'bughouse-mobile.png'), fullPage: true });
  assert.deepEqual(errors, []); assert.deepEqual(forbidden, []);
  console.log('PASS: real boards, captures/drops, repeated undo, promotion/cancel/Escape/all pieces/both colours, BPGN clipboard/download, shared links, refresh/undo reset, download cancellation, actual WASM+ONNX, cached repeat search, Stop/recovery, offline new-position search, cached model after reload and phone layout.');
} catch (error) {
  if (page) { console.error('URL:', page.url()); console.error('Boards:', await page.$$eval('.bb-board', es => es.map(e => ({ classes: e.className, rect: e.getBoundingClientRect().toJSON() })))); console.error('Status:', await page.$eval('#bh-status', (e) => e.textContent).catch(() => 'unavailable')); await page.screenshot({ path: path.join(output, 'bughouse-failure.png'), fullPage: true }); }
  throw error;
} finally { await browser.close(); }
