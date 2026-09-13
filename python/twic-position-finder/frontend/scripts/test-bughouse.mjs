import assert from 'node:assert/strict';
import path from 'node:path';
import puppeteer from 'puppeteer-core';

const [origin, output] = process.argv.slice(2);
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome',
  headless: true,
  args: ['--disable-dev-shm-usage'],
});
let page;
try {
  page = await browser.newPage();
  page.on('framenavigated', (frame) => { if (frame === page.mainFrame()) console.log('Page:', frame.url()); });
  await page.setViewport({ width: 1360, height: 1100, deviceScaleFactor: 1 });
  const errors = [];
  const apiRequests = [];
  page.on('request', (request) => {
    if (request.isNavigationRequest()) console.log('Navigation request:', request.url());
    if (request.method() !== 'GET' || request.url().includes('/api/bughouse/')) apiRequests.push(request.url());
  });
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto(`${origin}/bughouse/`, { waitUntil: 'networkidle0' });
  const ready = () => page.waitForFunction(() => !document.querySelector('#bh-analyse').disabled);
  const analysisReady = async () => {
    await page.waitForFunction(() => !location.pathname.startsWith('/bughouse') || document.querySelector('.bh-table') ||
      (!document.querySelector('#bh-analyse').disabled && document.querySelector('#bh-status').dataset.error === 'true'), { timeout: 120_000 });
    assert.ok(await page.$('.bh-table'), await page.$eval('#bh-status', (node) => node.textContent));
  };
  await ready();
  assert.equal(await page.$$eval('.bh-square', (squares) => squares.length), 128);
  assert.equal(await page.$$eval('.bh-square img', (pieces) => pieces.length), 64);
  const square = (board, sq) => `#bh-board-${board} [data-square="${sq}"]`;
  async function move(board, from, to) {
    await page.click(square(board, from));
    await page.click(square(board, to));
    await ready();
  }
  await move('A', 'e2', 'e4');
  await move('A', 'd7', 'd5');
  await move('A', 'e4', 'd5');
  await move('B', 'e2', 'e4');
  assert.equal(await page.$eval('[aria-label="B: black pawn reserve, 1"]', (button) => button.disabled), false);
  await page.click('[aria-label="B: black pawn reserve, 1"]');
  await page.click(square('B', 'e6'));
  await ready();
  assert.match(await page.$eval(square('B', 'e6'), (button) => button.getAttribute('aria-label')), /black pawn/);
  assert.equal(await page.$('[aria-label="B: black pawn reserve, 1"]'), null);
  await page.click('#bh-undo'); await ready();
  assert.ok(await page.$('[aria-label="B: black pawn reserve, 1"]'));
  await page.click('#bh-flip');
  assert.equal(await page.$eval('#bh-board-A button', (b) => b.dataset.square), 'h1');
  await page.click('#bh-flip');
  await page.click('#bh-reset'); await ready();

  // A failed initial model download is recoverable without refreshing.
  await page.setRequestInterception(true);
  let interrupted = false;
  const interrupt = (request) => {
    if (!interrupted && /\/model-.*\.bin$/.test(request.url())) {
      interrupted = true;
      void request.abort();
    } else void request.continue();
  };
  page.on('request', interrupt);
  await page.click('#bh-analyse');
  await ready();
  assert.ok(interrupted);
  assert.equal(await page.$eval('#bh-status', (node) => node.dataset.error), 'true');
  await page.setRequestInterception(false);
  page.off('request', interrupt);

  // Real engine, both calibrated searches, then actually play its joint move.
  await page.click('#bh-analyse');
  await analysisReady();
  console.log('Static neural analysis and board controls passed.');
  assert.ok((await page.$eval('#bh-result', (node) => node.textContent)).includes('Both teams searched'));
  await page.evaluate(() => scrollTo(0, 0));
  await page.screenshot({ path: path.join(output, 'bughouse-desktop.png'), fullPage: true });
  await page.click('.bh-table button'); await ready();
  assert.notEqual(await page.$eval('#bh-movetext-A', (node) => node.textContent), 'Starting position');

  // Pasted positions are transactional: invalid input cannot replace the board.
  await page.click('.bh-editor summary');
  await page.$eval('#bh-fen', (input) => { input.value = 'invalid fen'; });
  await page.$eval('#bh-moves', (input) => { input.value = ''; });
  await page.click('#bh-position-form button[type=submit]');
  await ready();
  assert.equal(await page.$eval('#bh-status', (node) => node.dataset.error), 'true');
  assert.notEqual(await page.$eval('#bh-movetext-A', (node) => node.textContent), 'Starting position');

  const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
  await page.$eval('#bh-fen', (input, value) => { input.value = value; }, `7k/P7/8/8/8/8/8/7K[] w - - 0 1|${start}`);
  await page.click('#bh-position-form button[type=submit]'); await ready();
  await page.click(square('A', 'a7')); await page.click(square('A', 'a8'));
  assert.equal(await page.$$eval('#bh-promotion-options button', (buttons) => buttons.length), 4);
  await page.$$eval('#bh-promotion-options button', (buttons) => buttons.find((button) => button.textContent === 'knight').click());
  await ready();
  assert.match(await page.$eval(square('A', 'a8'), (button) => button.getAttribute('aria-label')), /white knight/);

  // Stop interrupts a real long search and leaves the worker reusable.
  await page.click('#bh-reset'); await ready();
  await page.select('#bh-budget', '30000');
  await page.click('#bh-analyse');
  await page.waitForFunction(() => document.querySelector('#bh-status').textContent.includes('searching for our team'));
  await page.click('#bh-stop'); await ready();
  assert.match(await page.$eval('#bh-status', (node) => node.textContent), /cancelled/);
  await page.select('#bh-budget', '3000');
  console.log('Cancellation and recovery passed.');

  // Once loaded, moves and actual neural searches work with ALL networking off.
  await page.setOfflineMode(true);
  await page.click('#bh-example'); await ready();
  console.log('Offline example loaded:', page.url());
  await page.click('.bh-editor summary');
  await page.select('#bh-team', 'black');
  // Collapsing the editor can leave scroll anchoring under the sticky nav.
  await page.evaluate(async () => {
    scrollTo(0, 0);
    await new Promise(requestAnimationFrame);
    await new Promise(requestAnimationFrame);
  });
  await page.locator('#bh-analyse').click();
  await analysisReady();
  await page.evaluate(() => scrollTo(0, 0));
  await page.screenshot({ path: path.join(output, 'bughouse-capture-drop.png'), fullPage: true });
  await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 1 });
  await page.evaluate(() => scrollTo(0, 0));
  await page.screenshot({ path: path.join(output, 'bughouse-mobile.png'), fullPage: true });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Mobile page overflows horizontally');
  assert.deepEqual(errors, []);
  assert.deepEqual(apiRequests, [], 'Static Bughouse must never call an API or POST a position');
  console.log('STATIC browser passed: 128 squares, captures, partner drops, undo, flip, download retry, real WASM + ONNX analysis/play, invalid FEN, underpromotion, Stop/recovery, offline analysis, phone layout. No API requests.');
  console.log(`Screenshots: ${output}`);
} catch (error) {
  if (page) {
    console.error('Original failure:', error);
    console.error('Browser status:', page.url(), await page.evaluate(() => document.querySelector('#bh-status')?.textContent ?? document.body?.textContent?.slice(0, 500)));
    await page.screenshot({ path: path.join(output, 'bughouse-failure.png'), fullPage: true });
  }
  throw error;
} finally {
  await browser.close();
}
