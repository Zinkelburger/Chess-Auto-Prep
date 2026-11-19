// Drives the built /bughouse-puzzles page in headless Chrome: the FICS set
// opens by default, Settings switches to the engine set, one engine puzzle is
// solved by playing its line on the board, progress stays with its set, and a
// deep link opens the set its id belongs to.
// npm run build && node scripts/test-puzzles-browser.mjs. Screenshots land in
// build/bughouse-web/ at the repository root.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';
import { serveDist } from './static-server.mjs';

const frontend = fileURLToPath(new URL('..', import.meta.url));
const output = path.resolve(frontend, '../../../build/bughouse-web');
await fs.mkdir(output, { recursive: true });
const { origin, close } = await serveDist(frontend);
// Chrome's singleton socket path must stay short; the job runner's TMPDIR is too long.
const chromeTmp = await fs.mkdtemp(path.join(os.homedir(), '.cache', 'bpt-'));
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome', headless: true,
  args: ['--disable-dev-shm-usage'],
  env: { ...process.env, TMPDIR: chromeTmp },
});
const text = (page, selector) => page.$eval(selector, (el) => el.textContent.trim());
const hashId = (page) => page.evaluate(() => decodeURIComponent(location.hash.slice(1)));
const ready = (page) => page.waitForFunction(() => document.querySelector('#bp').dataset.state === 'ready'
  && document.querySelector('#bp-turn-title').textContent.endsWith('to move'), { timeout: 15_000 });
const chipLabels = (page, box) => page.$$eval(`${box} label`, (ls) => ls.map((l) => ({ text: l.textContent, checked: l.querySelector('input').checked })));

/** The centre of a square, with the solver's colour at the bottom as the page draws it. */
async function square(page, key, bottom) {
  const box = await page.$eval('#bp-board', (el) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width }; });
  let file = key.charCodeAt(0) - 97, rank = Number(key[1]) - 1;
  if (bottom === 'black') { file = 7 - file; rank = 7 - rank; }
  const s = box.w / 8;
  return { x: box.x + (file + 0.5) * s, y: box.y + (7 - rank + 0.5) * s };
}

/** Play one solver move as a player would: click-click, or drag a reserve piece on. */
async function play(page, uci, bottom) {
  const to = await square(page, uci.slice(2, 4), bottom);
  if (uci[1] === '@') {
    const slot = await page.$$(`#bp-seat-bottom .zh-slot`);
    const at = 'PNBRQ'.indexOf(uci[0].toUpperCase());
    const r = await slot[at].boundingBox();
    await page.mouse.move(r.x + r.width / 2, r.y + r.height / 2);
    await page.mouse.down();
    await page.mouse.move(to.x, to.y, { steps: 8 });
    await page.mouse.up();
  } else {
    const from = await square(page, uci.slice(0, 2), bottom);
    await page.mouse.click(from.x, from.y);
    await new Promise((r) => setTimeout(r, 60));
    await page.mouse.click(to.x, to.y);
  }
}

try {
  const page = await browser.newPage();
  page.setDefaultTimeout(15_000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.setViewport({ width: 1440, height: 900 });
  await page.goto(`${origin}/bughouse-puzzles/`);
  await page.evaluate(() => localStorage.clear());
  await page.goto(`${origin}/bughouse-puzzles/`);
  await ready(page);

  // The FICS set by default, its ids all digits first.
  const humanCount = (await page.evaluate(() => fetch('/bughouse-puzzles/index.json').then((r) => r.json()))).count;
  const humanId = await hashId(page);
  assert.match(humanId, /^\d/, 'a FICS puzzle opens first');
  assert.match(await text(page, '#bp-source'), /FICS/);
  assert.equal(await text(page, '.bp-counter'), `1 / ${humanCount}`);

  // Settings: From names both sets, the FICS one chosen; the missed filter speaks of a player.
  await page.click('#bp-settings-open');
  await page.waitForFunction(() => document.querySelectorAll('#bp-set label b').length === 2, { timeout: 10_000 });
  const from = await chipLabels(page, '#bp-set');
  console.log('From:', from.map((c) => `${c.text}${c.checked ? ' (chosen)' : ''}`).join(' | '));
  assert.match(from[0].text, /^Human games\d+$/);
  assert.ok(from[0].checked);
  assert.match(from[1].text, /^Engine games\d+$/);
  assert.match(await text(page, '#bp-missed label'), /^Only ones the player missed\d+$/);

  // Engine games: the set, its source line and the missed filter's wording change together.
  await page.click('#bp-set label:nth-child(2) input');
  await page.waitForFunction(() => /engine games/.test(document.querySelector('#bp-source').textContent), { timeout: 10_000 });
  assert.match(await text(page, '#bp-missed label'), /^Only ones the engine missed\d+$/);
  await page.screenshot({ path: path.join(output, 'puzzles-engine-settings.png') });
  await page.click('#bp-settings-close');
  await ready(page);
  const engineId = await hashId(page);
  assert.match(engineId, /^e[0-9a-f]{6}-\d+-[AB]-\d+$/, 'an engine puzzle is open');

  // Solve it, then a longer one (with a drop when the set has one), by playing the line on the board.
  const engineIndex = await page.evaluate(() => fetch('/bughouse-puzzles/engine/index.json').then((r) => r.json()));
  const record = (id) => page.evaluate(async (id, index) => {
    const entry = index.puzzles.find((p) => p.id === id);
    const shard = await fetch(`/bughouse-puzzles/engine/${index.shards[entry.shard]}`).then((r) => r.json());
    return shard.puzzles.find((p) => p.id === id);
  }, id, engineIndex);
  async function solve(puzzle) {
    const bottom = puzzle.fen.split(' ')[1] === 'w' ? 'white' : 'black';
    console.log(`solving ${puzzle.id}: ${puzzle.kind}, ${puzzle.san.join(' ')} (${puzzle.white} v ${puzzle.black}, found in the game: ${puzzle.found})`);
    for (let i = 0; i < puzzle.line.length; i += 2) {
      await page.waitForFunction(() => document.querySelector('#bp-turn-title').textContent.endsWith('to move'), { timeout: 5000 });
      await play(page, puzzle.line[i], bottom);
      if (i + 1 < puzzle.line.length) await page.waitForFunction((n) => document.querySelectorAll('#bp-line .san-token').length >= n, { timeout: 5000 }, i + 2);
    }
    await page.waitForFunction(() => document.querySelector('#bp-turn-title').textContent === 'Solved!', { timeout: 5000 });
    assert.equal(await page.$$eval('#bp-line .san-token', (ts) => ts.map((t) => t.textContent).join(' ')), puzzle.san.join(' '));
  }
  await solve(await record(engineId));
  await page.screenshot({ path: path.join(output, 'puzzles-engine-solved.png') });
  const long = engineIndex.puzzles.filter((e) => e.moves >= 2 && e.id !== engineId);
  const pick = (await Promise.all(long.slice(0, 20).map((e) => record(e.id)))).sort((a, b) => Number(b.line.some((u) => u[1] === '@')) - Number(a.line.some((u) => u[1] === '@')))[0];
  assert.ok(pick, 'the engine set has a puzzle of two moves or more');
  await page.evaluate((id) => { location.hash = id; }, pick.id);
  await page.waitForFunction((id) => decodeURIComponent(location.hash.slice(1)) === id, {}, pick.id);
  await ready(page);
  await solve(pick);
  await page.screenshot({ path: path.join(output, 'puzzles-engine-solved-long.png') });
  await page.evaluate((id) => { location.hash = id; }, engineId);
  await ready(page);

  // Progress stays with its set.
  const stored = await page.evaluate(() => ({
    engine: JSON.parse(localStorage.getItem('bughouse-puzzles-engine-v1')),
    human: JSON.parse(localStorage.getItem('bughouse-puzzles-v2')),
    set: localStorage.getItem('bughouse-puzzles-set'),
  }));
  assert.equal(stored.engine.outcomes[engineId], 'win');
  assert.equal(stored.human.outcomes[engineId], undefined, 'the FICS set never sees an engine result');
  assert.equal(stored.set, 'engine');

  // Back to Human games: the FICS place comes back, then a deep link to the engine puzzle reopens its set.
  await page.click('#bp-settings-open');
  await page.click('#bp-set label:nth-child(1) input');
  await page.click('#bp-settings-close');
  await ready(page);
  assert.equal(await hashId(page), humanId, 'the FICS set reopens where it was');
  await page.goto(`${origin}/bughouse-puzzles/#${engineId}`);
  await page.reload();
  await ready(page);
  assert.equal(await hashId(page), engineId, 'the deep link opened the engine set');
  assert.match(await text(page, '#bp-source'), /engine games/);
  // Following an in-page link to a FICS id switches back.
  await page.evaluate((id) => { location.hash = id; }, humanId);
  await page.waitForFunction(() => /FICS/.test(document.querySelector('#bp-source').textContent), { timeout: 10_000 });
  await ready(page);
  assert.equal(await hashId(page), humanId);

  // A phone-width look at the engine set.
  await page.setViewport({ width: 390, height: 844 });
  await page.goto(`${origin}/bughouse-puzzles/#${engineId}`);
  await page.reload();
  await ready(page);
  await page.screenshot({ path: path.join(output, 'puzzles-engine-phone.png') });

  assert.deepEqual(errors, [], 'no page errors');
  console.log('Bughouse puzzles page passed in Chrome.');
} finally {
  await browser.close();
  close();
  await fs.rm(chromeTmp, { recursive: true, force: true });
}
