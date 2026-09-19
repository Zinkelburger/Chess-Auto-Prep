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
  assert.ok(start.every((r) => r.length === 4), 'Move, Ahead, Even, Behind');
  assert.equal(await page.$eval('#bdb-mover-A', (n) => n.textContent), 'Move: Player A');
  assert.ok(await page.evaluate(() => document.documentElement.scrollHeight <= innerHeight), 'fits without scrolling');
  assert.match(start[0][2], /^[+−]?\d+\.\d\d$/, 'Even is in pawns');
  assert.equal(await page.$eval('#bdb-missing', (n) => n.hidden), true);
  assert.equal(await page.$$eval('.bdb-square img', (imgs) => imgs.length), 64);
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
  assert.equal(await page.$$eval('.bdb-ghost', (g) => g.length), 0);
  await page.keyboard.press('ArrowLeft');
  await page.waitForFunction(() => document.querySelector('#bdb-mover-A').textContent === 'Move: Player A');

  // A move with no stored analysis (the first rare move no earlier run
  // uploaded): the tables still list its replies.
  let missing = false;
  for (const san of ['a3', 'h3', 'b3', 'g3', 'Na3', 'Nh3', 'a4', 'h4', 'f3', 'b4', 'g4']) {
    const row = await page.$$eval('#bdb-moves-A tr', (trs, want) => trs.findIndex((tr) => tr.cells[0].textContent === want), san);
    assert.ok(row >= 0, san);
    await page.click(`#bdb-moves-A tr:nth-child(${row + 1})`);
    await page.waitForFunction(() => document.querySelector('#bdb-mover-A').textContent === 'Move: Player B');
    missing = !(await page.$eval('#bdb-missing', (n) => n.hidden));
    if (missing) break;
    await page.click('#bdb-prev');
    await page.waitForFunction(() => document.querySelector('#bdb-mover-A').textContent === 'Move: Player A');
  }
  assert.ok(missing, 'every candidate is already in the book');
  // The move is marked on its board and listed in that board's history only.
  assert.equal(await page.$$eval('#bdb-board-A .last', (s) => s.length), 2);
  assert.equal(await page.$$eval('#bdb-history-B button', (b) => b.length), 0);
  assert.equal((await rows('A'))[0][2], '—');
  await page.screenshot({ path: path.join(output, 'bughousedb-missing.png') });

  // Analyse it here and upload.
  await page.click('#bdb-analyse');
  // Done means the page reloaded the position as stored, computed in a browser.
  await page.waitForFunction(() => (document.querySelector('#bdb-missing').hidden
      && /browser/.test(document.querySelector('#bdb-source').textContent))
    || document.querySelector('#bdb-status').dataset.error === 'true', { timeout: 15 * 60_000, polling: 1000 });
  const status = await page.$eval('#bdb-status', (n) => n.textContent);
  assert.match(await page.$eval('#bdb-source', (n) => n.textContent), /browser/, status);
  assert.notEqual((await rows('B'))[0][2], '—');
  await page.hover('#bdb-moves-B tr:first-child');
  await page.screenshot({ path: path.join(output, 'bughousedb-analysed.png') });

  // Back to the start with the keyboard; the move stays in the history to step forward to.
  await page.keyboard.press('ArrowLeft');
  await page.waitForFunction(() => document.querySelector('#bdb-history-A button.future'));
  await page.keyboard.press('ArrowRight');
  await page.waitForFunction(() => document.querySelector('#bdb-history-A button[aria-current="true"]'));
  assert.deepEqual(errors, []);
  console.log('BughouseDB browser passed:', status);
} finally {
  await browser.close();
}
