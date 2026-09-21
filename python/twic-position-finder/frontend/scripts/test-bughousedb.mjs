// End-to-end check of /bughousedb against a running API that already holds
// the start position (e.g. seeded with `hivemind_book.py push`):
//   node scripts/test-bughousedb.mjs http://localhost:4321 /tmp/out
// Browses the book, then analyses one missing position in the browser and
// checks that the upload comes back as a stored position.
import assert from 'node:assert/strict';
import path from 'node:path';
import puppeteer from 'puppeteer-core';

const [origin, output] = process.argv.slice(2);
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome',
  headless: true,
  args: ['--disable-dev-shm-usage'],
  protocolTimeout: 20 * 60_000,  // the in-browser analysis takes minutes
});
try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1360, height: 1300, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  const rows = (board) => page.$$eval(`#bdb-moves-${board} tr`, (trs) => trs.map((tr) => [...tr.cells].map((c) => c.textContent)));

  await page.goto(`${origin}/bughousedb/`, { waitUntil: 'networkidle0' });
  await page.waitForFunction(() => document.querySelectorAll('#bdb-moves-A tr').length === 20);
  const start = await rows('A');
  assert.equal((await rows('B')).length, 20);
  assert.ok(start.every((r) => r.length === 5), 'Move, A > D, Equal, B > C, Both');
  assert.equal(await page.$eval('#bdb-mover-A', (n) => n.textContent), 'Move: Player A');
  assert.ok(await page.evaluate(() => document.documentElement.scrollHeight <= innerHeight), 'fits without scrolling');
  assert.match(start[0][2], /^[+−]?\d+\.\d\d$/, 'Even is in pawns');
  const shown = () => page.$eval('#bdb-missing', (n) => n.dataset.shown === 'true');
  const tableTop = () => page.$eval('#bdb-moves-A', (n) => n.getBoundingClientRect().top);
  assert.equal(await shown(), false);
  const foundTop = await tableTop();
  assert.equal(await page.$$eval('.bb-square img', (imgs) => imgs.length), 64);
  await page.screenshot({ path: path.join(output, 'bughousedb-start.png') });

  // Hover draws the move; each score keeps its line as a tooltip.
  await page.hover('#bdb-moves-A tr:first-child');
  assert.equal(await page.$$eval('#bdb-arrow-A line', (s) => s.length), 1);
  assert.ok((await page.$eval('#bdb-moves-A tr:first-child td:nth-child(3)', (n) => n.title)).length > 5);

  // Drag a piece: A e2 to e4, then step back.
  const centre = async (square) => {
    const box = await (await page.$(`#bdb-board-A [data-square="${square}"]`)).boundingBox();
    return [box.x + box.width / 2, box.y + box.height / 2];
  };
  await page.mouse.move(...await centre('e2'));
  await page.mouse.down();
  await page.mouse.move(...await centre('e3'), { steps: 4 });
  await page.mouse.move(...await centre('e4'), { steps: 4 });
  await page.mouse.up();
  await page.waitForFunction(() => document.querySelector('#bdb-mover-A').textContent === 'Move: Player B');
  assert.equal(await page.$eval('#bdb-history-A button', (b) => b.textContent), 'e4');
  assert.equal(await page.$$eval('.bb-ghost', (g) => g.length), 0);
  await page.keyboard.press('ArrowLeft');
  await page.waitForFunction(() => document.querySelector('#bdb-mover-A').textContent === 'Move: Player A');

  // Each board steps on its own; a step that would strand a drop is refused.
  const playRow = async (board, san, mover) => {
    await page.$$eval(`#bdb-moves-${board} tr`, (trs, want) => trs.find((tr) => tr.cells[0].textContent === want).click(), san);
    await page.waitForFunction((b, m) => document.querySelector(`#bdb-mover-${b}`).textContent === `Move: Player ${m}`, {}, board, mover);
  };
  await playRow('A', 'e4', 'B'); await playRow('A', 'd5', 'A'); await playRow('A', 'exd5', 'B');
  await playRow('B', 'e4', 'C');
  await page.click('#bdb-player-bottom-B .bb-pocket');  // C's pawn from the capture on board 1
  await page.click('#bdb-board-B [data-square="e6"]');
  await page.waitForFunction(() => document.querySelector('#bdb-mover-B').textContent === 'Move: Player D');
  await page.click('#bdb-prev-A');
  await page.waitForFunction(() => /Can’t step there/.test(document.querySelector('#bdb-fen-error-A').textContent));
  assert.equal(await page.$$eval('#bdb-history-A button.future', (b) => b.length), 0, 'board 1 stays put');
  await page.click('#bdb-first-B');
  await page.waitForFunction(() => document.querySelector('#bdb-mover-B').textContent === 'Move: Player D'
    && document.querySelectorAll('#bdb-history-B button.future').length === 2);
  await page.click('#bdb-prev-A');  // now allowed: nothing on board 2 needs the pawn
  await page.waitForFunction(() => document.querySelectorAll('#bdb-history-A button.future').length === 1);
  assert.equal(await page.$eval('#bdb-mover-A', (n) => n.textContent), 'Move: Player A');
  await page.click('#bdb-first-A');
  await page.waitForFunction(() => document.querySelector('#bdb-mover-A').textContent === 'Move: Player A'
    && document.querySelectorAll('#bdb-history-A button.future').length === 3);

  // A move with no stored analysis (the first rare move no earlier run
  // uploaded): the tables still list its replies.
  let missing = false;
  for (const san of ['a3', 'h3', 'b3', 'g3', 'Na3', 'Nh3', 'a4', 'h4', 'f3', 'b4', 'g4']) {
    const row = await page.$$eval('#bdb-moves-A tr', (trs, want) => trs.findIndex((tr) => tr.cells[0].textContent === want), san);
    assert.ok(row >= 0, san);
    await page.click(`#bdb-moves-A tr:nth-child(${row + 1})`);
    await page.waitForFunction(() => document.querySelector('#bdb-mover-A').textContent === 'Move: Player B');
    missing = await shown();
    if (missing) break;
    await page.click('#bdb-prev-A');
    await page.waitForFunction(() => document.querySelector('#bdb-mover-A').textContent === 'Move: Player A');
  }
  assert.ok(missing, 'every candidate is already in the book');
  // The move is marked on its board and listed in that board's history only.
  assert.equal(await page.$$eval('#bdb-board-A .last', (s) => s.length), 2);
  assert.equal(await page.$$eval('#bdb-history-B button:not(.future)', (b) => b.length), 0);
  assert.equal((await rows('A'))[0][2], '—');
  assert.equal(await tableTop(), foundTop, 'the analyse controls do not push the tables down');
  await page.screenshot({ path: path.join(output, 'bughousedb-missing.png') });

  // Analyse it here and upload.
  await page.click('#bdb-analyse');
  // Done means the page reloaded the position as stored, computed in a browser.
  await page.waitForFunction(() => (document.querySelector('#bdb-missing').dataset.shown === 'false'
      && /Added to the book/.test(document.querySelector('#bdb-status').textContent))
    || document.querySelector('#bdb-status').dataset.error === 'true', { timeout: 15 * 60_000, polling: 1000 });
  const status = await page.$eval('#bdb-status', (n) => n.textContent);
  assert.match(status, /Added to the book/);
  assert.equal(await tableTop(), foundTop);
  assert.notEqual((await rows('B'))[0][2], '—');
  await page.hover('#bdb-moves-B tr:first-child');
  await page.screenshot({ path: path.join(output, 'bughousedb-analysed.png') });

  // Back to the start with the keyboard; the move stays in the history to step forward to.
  await page.keyboard.press('ArrowLeft');
  await page.waitForFunction(() => document.querySelector('#bdb-history-A button.future'));
  await page.keyboard.press('ArrowRight');
  await page.waitForFunction(() => document.querySelector('#bdb-history-A button[aria-current="true"]'));
  // Revisited, the stored position says it came from a browser.
  await page.waitForFunction(() => /browser/.test(document.querySelector('#bdb-status').textContent));
  assert.deepEqual(errors, []);
  console.log('BughouseDB browser passed:', status);
} finally {
  await browser.close();
}
