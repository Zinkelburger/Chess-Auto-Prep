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
  assert.equal(await page.$$eval('.bb-square', (squares) => squares.length), 128);
  assert.equal(await page.$$eval('.bb-square img', (pieces) => pieces.length), 64);
  const square = (board, sq) => `#bh-board-${board} [data-square="${sq}"]`;
  async function move(board, from, to) {
    await page.click(square(board, from));
    await page.click(square(board, to));
    await ready();
  }
  const pawnC = '[aria-label="Player C: 1 pawn in reserve"]';
  await move('A', 'e2', 'e4');
  await move('A', 'd7', 'd5');
  await move('A', 'e4', 'd5');
  await move('B', 'e2', 'e4');
  assert.equal(await page.$eval(pawnC, (button) => button.disabled), false);
  await page.click(pawnC);
  await page.click(square('B', 'e6'));
  await ready();
  assert.match(await page.$eval(square('B', 'e6'), (button) => button.getAttribute('aria-label')), /black pawn/);
  assert.equal(await page.$(pawnC), null);
  // Each board steps on its own: board 2 back one returns the pawn; board 1 keeps its moves.
  await page.click('#bh-prev-B'); await ready();
  assert.ok(await page.$(pawnC));
  assert.equal(await page.$$eval('#bh-history-A button:not(.future)', (b) => b.length), 3);
  // Board 1 cannot step back past the capture while board 2 still uses the pawn.
  await page.click('#bh-next-B'); await ready();
  await page.click('#bh-prev-A'); await ready();
  assert.match(await page.$eval('#bh-fen-error-A', (n) => n.textContent), /Can’t step there/);
  assert.equal(await page.$$eval('#bh-history-A button.future', (b) => b.length), 0);
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
  assert.match(await page.$eval('#bh-result', (node) => node.textContent), /A \+ C: [+−]?\d+\.\d\d|Mate/);
  await page.hover('.bh-table tbody tr');
  assert.ok(await page.$('.bb-arrow line, .bb-arrow circle'), 'hovering a suggestion draws it');
  await page.screenshot({ path: path.join(output, 'bughouse-desktop.png') });
  await page.click('.bh-table tbody tr'); await ready();
  assert.ok(await page.$$eval('.bb-history button', (b) => b.length) > 0);

  // A position that doesn't parse is refused before it reaches the boards.
  await page.$eval('#bh-fen-B', (input) => { input.value = 'invalid fen'; });
  await page.click('.bb-set');
  assert.match(await page.$eval('#bh-fen-error-B', (n) => n.textContent), /ranks/);

  const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  await page.$eval('#bh-fen-A', (input) => { input.value = '7k/P7/8/8/8/8/8/7K w - - 0 1'; });
  await page.$eval('#bh-fen-B', (input, value) => { input.value = value; }, start);
  for (const id of ['#bh-reserve-A-white', '#bh-reserve-A-black', '#bh-reserve-B-white', '#bh-reserve-B-black']) await page.$eval(id, (input) => { input.value = ''; });
  await page.click('.bb-set'); await ready();
  await page.click(square('A', 'a7')); await page.click(square('A', 'a8'));
  assert.equal(await page.$$eval('#bh-promotion-options button', (buttons) => buttons.length), 4);
  await page.$$eval('#bh-promotion-options button', (buttons) => buttons.find((button) => button.textContent === 'knight').click());
  await ready();
  assert.match(await page.$eval(square('A', 'a8'), (button) => button.getAttribute('aria-label')), /white knight/);

  // Stop interrupts a real long search and leaves the worker reusable.
  await page.click('#bh-reset'); await ready();
  await page.click('#bh-analyse-form input[value="30000"] + span');
  await page.click('#bh-analyse');
  await page.waitForFunction(() => document.querySelector('#bh-status').textContent.includes('searching for our team'));
  await page.click('#bh-stop'); await ready();
  assert.match(await page.$eval('#bh-status', (node) => node.textContent), /cancelled/);
  await page.click('#bh-analyse-form input[value="3000"] + span');
  console.log('Cancellation and recovery passed.');

  // Once loaded, moves and actual neural searches work with ALL networking off.
  await page.setOfflineMode(true);
  await move('A', 'e2', 'e4');
  await move('B', 'd2', 'd4');
  console.log('Offline moves played:', page.url());
  await page.click('#bh-analyse-form input[value="black"] + span');
  await page.locator('#bh-analyse').click();
  await analysisReady();
  await page.screenshot({ path: path.join(output, 'bughouse-offline.png') });
  await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 1 });
  await page.evaluate(() => scrollTo(0, 0));
  await page.screenshot({ path: path.join(output, 'bughouse-mobile.png'), fullPage: true });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Mobile page overflows horizontally');
  assert.deepEqual(errors, []);
  assert.deepEqual(apiRequests, [], 'Static Bughouse must never call an API or POST a position');
  console.log('STATIC browser passed: 128 squares, captures, partner drops, per-board steps, flip, download retry, real WASM + ONNX analysis/play, invalid FEN, underpromotion, Stop/recovery, offline analysis, phone layout. No API requests.');
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
