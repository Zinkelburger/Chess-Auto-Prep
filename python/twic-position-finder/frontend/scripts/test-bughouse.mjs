import assert from 'node:assert/strict';
import path from 'node:path';
import puppeteer from 'puppeteer-core';

const [origin, output] = process.argv.slice(2);
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome',
  headless: true,
  args: ['--disable-dev-shm-usage'],
});
try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1360, height: 1100, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto(`${origin}/bughouse/`, { waitUntil: 'networkidle0' });
  const ready = () => page.waitForFunction(() => !document.querySelector('#bh-analyse').disabled);
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

  // Real engine, both calibrated searches, then actually play its joint move.
  await page.click('#bh-analyse');
  await page.waitForSelector('.bh-table', { timeout: 45_000 });
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

  // Busy and unavailable responses must restore usable controls.
  await page.click('#bh-reset'); await ready();
  await page.setRequestInterception(true);
  const busyResponse = (request) => request.url().endsWith('/analyse')
    ? request.respond({ status: 429, contentType: 'application/json', body: JSON.stringify({ detail: 'The engine is helping someone else. Try again shortly.' }) })
    : request.continue();
  page.on('request', busyResponse);
  await page.click('#bh-analyse'); await ready();
  assert.match(await page.$eval('#bh-status', (node) => node.textContent), /helping someone else/);
  page.off('request', busyResponse);
  await page.setRequestInterception(false);

  await page.click('#bh-example'); await ready();
  await page.click('.bh-editor summary');
  await page.select('#bh-team', 'black');
  await page.click('#bh-analyse');
  await page.waitForSelector('.bh-table', { timeout: 45_000 });
  await page.evaluate(() => scrollTo(0, 0));
  await page.screenshot({ path: path.join(output, 'bughouse-capture-drop.png'), fullPage: true });
  await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 1 });
  await page.evaluate(() => scrollTo(0, 0));
  await page.screenshot({ path: path.join(output, 'bughouse-mobile.png'), fullPage: true });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Mobile page overflows horizontally');
  assert.deepEqual(errors, []);
  console.log('Browser passed: 128 squares, captures, partner drops, undo, flip, real analysis + play, invalid FEN, underpromotion, busy recovery, mobile layout.');
  console.log(`Screenshots: ${output}`);
} finally {
  await browser.close();
}
