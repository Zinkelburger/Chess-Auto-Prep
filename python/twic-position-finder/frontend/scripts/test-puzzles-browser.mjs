// Drives the built /bughouse-puzzles page in headless Chrome: the FICS set
// opens by default, Settings switches to the engine set, one engine puzzle is
// solved by playing its line on the board, progress stays with its set, and a
// deep link opens the set its id belongs to. Then: the layout at twelve window
// sizes, boxes that never move while solving (three sizes), reserve taps and
// drags by touch, Space on a focused button, a solve by keyboard alone,
// contrast, touch targets, the progress grid by keyboard and reduced motion.
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
// The solver's turn, not the intro (the opponent's last move arriving, board locked), which reads the same.
const solverTurn = () => document.querySelector('#bp-turn').classList.contains('turn-turn')
  && document.querySelector('#bp-turn-title').textContent.endsWith('to move');
const ready = (page) => page.waitForFunction(() => document.querySelector('#bp').dataset.state === 'ready'
  && document.querySelector('#bp-turn').classList.contains('turn-turn')
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
  // The frozen reserves are said once while solving, in the same words as in Settings.
  const FROZEN = 'Reserves are frozen: no new pieces arrive for either side.';
  assert.equal(await text(page, '.bp-frozen'), FROZEN);
  assert.equal(await page.$$eval('.bp-side', (s) => s[0].textContent.split('Reserves are frozen').length - 1), 1, 'said once on the solving screen');
  assert.ok((await text(page, '.bp-source')).startsWith(FROZEN));
  assert.match(await page.$eval('meta[name="description"]', (m) => m.content), /Reserves are frozen: no new pieces arrive for either side\.$/);
  assert.equal(await text(page, '.bp-counter'), `1 / ${humanCount}`);

  // Settings: From names both sets, the FICS one chosen; the missed filter speaks of a player.
  await page.click('#bp-settings-open');
  await page.waitForFunction(() => document.querySelectorAll('#bp-set label b').length === 2
    && !document.querySelector('#bp-settings').getAnimations().length, { timeout: 10_000 });
  const from = await chipLabels(page, '#bp-set');
  console.log('From:', from.map((c) => `${c.text}${c.checked ? ' (chosen)' : ''}`).join(' | '));
  assert.match(from[0].text, /^Human games\d+$/);
  assert.ok(from[0].checked);
  assert.match(from[1].text, /^Engine games\d+$/);
  assert.match(await text(page, '#bp-missed label'), /^Only ones the player missed\d+$/);

  // Engine games: the set, its source line and the missed filter's wording change together.
  await page.click('#bp-set label:nth-child(2)');
  await page.waitForFunction(() => /engine games/.test(document.querySelector('#bp-source').textContent), { timeout: 10_000 });
  assert.match(await text(page, '#bp-source'), /^\d+ puzzles from [\d,]+ engine games played by HypeBeast, most of them against other builds of itself\./,
    'the engine set\'s source reads as a player would say it');
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
      await page.waitForFunction(solverTurn, { timeout: 5000 });
      await play(page, puzzle.line[i], bottom);
      if (i + 1 < puzzle.line.length) await page.waitForFunction((n) => document.querySelectorAll('#bp-line .san-token').length >= n, { timeout: 5000 }, i + 2);
    }
    await page.waitForFunction(() => document.querySelector('#bp-turn-title').textContent === 'Solved!', { timeout: 5000 });
    assert.equal(await page.$$eval('#bp-line .san-token', (ts) => ts.map((t) => t.textContent).join(' ')), puzzle.san.join(' '));
  }
  await solve(await record(engineId));
  // The game's lines appear under the buttons; Next takes the focus, without a ring for a mouse user.
  assert.ok(await page.$eval('#bp-after', (el) => getComputedStyle(el).visibility === 'visible'), 'the after-solve block shows');
  assert.match(await text(page, '#bp-game'), / – .* · engine game \d{4}$/);
  assert.match(await text(page, '#bp-found'), /^(White|Black) found it in the game\.$|^In the game (White|Black) played \S+\.$/);
  assert.deepEqual(await page.evaluate(() => [document.activeElement.id, document.activeElement.matches(':focus-visible')]), ['bp-next', false],
    'Next has the focus, with no ring after a mouse solve');
  await page.screenshot({ path: path.join(output, 'puzzles-engine-solved.png') });
  const long = engineIndex.puzzles.filter((e) => e.moves >= 2 && e.id !== engineId);
  const pick = (await Promise.all(long.slice(0, 20).map((e) => record(e.id)))).sort((a, b) => Number(b.line.some((u) => u[1] === '@')) - Number(a.line.some((u) => u[1] === '@')))[0];
  assert.ok(pick, 'the engine set has a puzzle of two moves or more');
  await page.evaluate((id) => { location.hash = id; }, pick.id);
  await page.waitForFunction((id) => decodeURIComponent(location.hash.slice(1)) === id, {}, pick.id);
  await ready(page);
  await solve(pick);
  await page.screenshot({ path: path.join(output, 'puzzles-engine-solved-long.png') });

  // Step back through the solved line: a click on the first move, then the arrow keys and the step buttons.
  // The pieces once chessground's move animation has settled.
  const boardFen = async () => {
    await new Promise((r) => setTimeout(r, 400));
    return page.evaluate(() => [...document.querySelectorAll('#bp-board piece:not(.fading):not(.ghost)')]
      .map((p) => `${p.className}@${p.style.transform}`).sort().join());
  };
  const activeMove = () => page.$$eval('#bp-line .san-token', (ts) => ts.findIndex((t) => t.classList.contains('active')));
  const solvedBoard = await boardFen();
  assert.equal(await activeMove(), pick.san.length - 1, 'the last move is the one shown');
  assert.ok(await page.$eval('#bp-forward', (b) => b.disabled), 'nothing after the last move');
  await page.click('#bp-line .san-token');
  await page.waitForFunction(() => document.querySelector('#bp-line .san-token').classList.contains('active'));
  const afterFirst = await boardFen();
  assert.notEqual(afterFirst, solvedBoard, 'the board went back to the first move');
  await page.screenshot({ path: path.join(output, 'puzzles-engine-browse.png') });
  await page.keyboard.press('ArrowLeft');
  assert.equal(await activeMove(), -1, 'the start of the puzzle has no move marked');
  assert.ok(await page.$eval('#bp-back', (b) => b.disabled), 'nothing before the start');
  await page.click('#bp-forward');
  assert.equal(await activeMove(), 0);
  assert.equal(await boardFen(), afterFirst);
  await page.keyboard.press('End');
  assert.equal(await activeMove(), pick.san.length - 1);
  assert.equal(await boardFen(), solvedBoard, 'End returns to the solved board');
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
  // Wait out the sheet's slide-in so the chip is where the click lands.
  await page.waitForFunction(() => document.querySelector('#bp-settings').open && !document.querySelector('#bp-settings').getAnimations().length);
  await page.click('#bp-set label:nth-child(1)');
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


  // ── The review fixes ──────────────────────────────────────────
  const watch = (pg) => {
    pg.setDefaultTimeout(15_000);
    pg.on('pageerror', (e) => errors.push(e.message));
    pg.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    return pg;
  };
  const MATE5 = 'e5e7cff-16-A-107'; // mate in five, Black at the bottom, drops on the way
  const PROMO = 'e135615-8-B-132'; // two drops, then an underpromotion to a rook
  const mate5 = await record(MATE5);
  const promo = await record(PROMO);
  const bottomOf = (p) => (p.fen.split(' ')[1] === 'w' ? 'white' : 'black');

  // 1. Layout: never clipped; the board, its reserves, the feedback and the buttons in the first screen.
  const DESKTOP = { '1440x900': 573, '1280x720': 429, '1024x768': 467 };
  const layoutSizes = [[1440, 900], [1280, 720], [1024, 768], [1024, 1366], [834, 1194], [820, 1180], [801, 900], [768, 1024], [600, 960], [390, 844], [360, 740], [320, 568]];
  console.log('size        board x  width  scrollW  buttons end');
  for (const [w, h] of layoutSizes) {
    await page.setViewport({ width: w, height: h });
    await page.goto(`${origin}/bughouse-puzzles/#${MATE5}`);
    await page.reload();
    await ready(page);
    await page.waitForFunction(() => document.querySelector('#bp-seat-bottom .zh-pocket'));
    const m = await page.evaluate(() => {
      const box = (el) => { const r = el.getBoundingClientRect(); return { l: r.left, r: r.right, t: r.top, b: r.bottom, w: r.width, h: r.height }; };
      const buttons = [...document.querySelectorAll('.bp-controls .btn')];
      return {
        scrollWidth: document.documentElement.scrollWidth, innerWidth, innerHeight,
        board: box(document.querySelector('#bp-board')), top: box(document.querySelector('#bp-seat-top .zh-pocket')),
        bottom: box(document.querySelector('#bp-seat-bottom .zh-pocket')), feedback: box(document.querySelector('#bp-turn')),
        side: box(document.querySelector('.bp-side')), buttons: buttons.map(box),
        clipped: buttons.filter((b) => b.scrollWidth > b.clientWidth + 1).map((b) => b.id),
      };
    });
    const label = `${w}x${h}`;
    const end = Math.max(...m.buttons.map((b) => b.b));
    console.log(`${label.padEnd(11)} ${String(Math.round(m.board.l)).padStart(7)}  ${String(Math.round(m.board.w)).padStart(5)}  ${String(m.scrollWidth).padStart(7)}  ${Math.round(end)}`);
    assert.ok(m.scrollWidth <= m.innerWidth, `${label}: no sideways scroll`);
    for (const [name, b] of [['board', m.board], ['top reserve', m.top], ['bottom reserve', m.bottom], ...m.buttons.map((b, i) => [`button ${i + 1}`, b])])
      assert.ok(b.l >= -0.5 && b.r <= m.innerWidth + 0.5, `${label}: the ${name} is inside the window (${b.l}–${b.r})`);
    assert.deepEqual(m.clipped, [], `${label}: every button's label fits`);
    if (label !== '360x740' && label !== '320x568') {
      for (const [name, b] of [['bottom reserve', m.bottom], ['feedback', m.feedback], ...m.buttons.map((b, i) => [`button ${i + 1}`, b])])
        assert.ok(b.b <= m.innerHeight, `${label}: the ${name} is in the first screen (${b.b} > ${m.innerHeight})`);
    }
    if (label === '390x844') assert.ok(end <= m.innerHeight - 12, `390x844: the buttons end 12px above the bottom (${end})`);
    if (DESKTOP[label]) {
      assert.ok(m.side.l >= m.board.r, `${label}: two columns`);
      assert.ok(Math.abs(m.board.w - DESKTOP[label]) <= 2, `${label}: the board is ${m.board.w}px, as before (${DESKTOP[label]})`);
    } else if (w > 600 && h > w) {
      // Upright tablets: stacked, the panel as wide as the board and centred with it.
      assert.ok(m.side.t >= m.board.b, `${label}: the panel is under the board`);
      assert.ok(Math.abs(m.side.w - m.board.w) <= 1 && Math.abs(m.side.l - m.board.l) <= 1, `${label}: the panel is as wide as the board`);
      assert.ok(Math.abs(m.board.l - (m.innerWidth - m.board.r)) <= 16, `${label}: the board is centred`);
    }
  }

  // 2. Nothing moves: loading, ready, a wrong move, a right move, solved and the next puzzle, at three sizes.
  const boxes = (pg) => pg.evaluate(() => Object.fromEntries(['#bp-board', '#bp-seat-top', '#bp-seat-bottom', '#bp-turn', '#bp-line', '#bp-back', '#bp-forward', '#bp-prev', '#bp-solution', '#bp-retry', '#bp-next']
    .map((sel) => { const r = document.querySelector(sel).getBoundingClientRect(); return [sel, [r.x + scrollX, r.y + scrollY, r.width, r.height]]; })));
  const sameBoxes = (a, b, moment) => {
    for (const sel of Object.keys(a))
      assert.ok(a[sel].every((v, i) => Math.abs(v - b[sel][i]) <= 1), `${moment}: ${sel} moved or changed size (${a[sel].map(Math.round)} → ${b[sel].map(Math.round)})`);
  };
  const wrongMove = mate5.legal[0].split(' ').find((u) => u[1] !== '@' && u !== mate5.line[0]);
  for (const [w, h] of [[1440, 900], [820, 1180], [390, 844]]) {
    const pg = watch(await browser.newPage());
    await pg.setViewport({ width: w, height: h });
    // Hold the set's index back a moment so the skeleton can be measured.
    await pg.setRequestInterception(true);
    pg.on('request', (req) => { if (req.url().endsWith('/engine/index.json')) setTimeout(() => req.continue(), 1200); else req.continue(); });
    await pg.goto(`${origin}/bughouse-puzzles/#${MATE5}`);
    await pg.waitForFunction(() => document.querySelector('#bp').dataset.state === 'loading');
    await pg.evaluate(() => document.fonts.ready);
    const loading = await boxes(pg);
    await ready(pg);
    await pg.waitForFunction(() => document.querySelector('#bp-seat-bottom .zh-pocket'));
    const readyBoxes = await boxes(pg);
    sameBoxes(loading, readyBoxes, `${w}x${h} skeleton → ready`);
    const readyHeight = await pg.evaluate(() => document.documentElement.scrollHeight);
    await pg.screenshot({ path: path.join(output, `puzzles-ready-${w}x${h}.png`) });
    const bottom = bottomOf(mate5);
    await play(pg, wrongMove, bottom);
    await pg.waitForFunction(() => document.querySelector('#bp-turn').classList.contains('turn-bad'));
    sameBoxes(readyBoxes, await boxes(pg), `${w}x${h} after the wrong move`);
    for (let i = 0; i < mate5.line.length; i += 2) {
      await pg.waitForFunction(solverTurn, { timeout: 5000 });
      await play(pg, mate5.line[i], bottom);
      if (i + 1 < mate5.line.length) {
        await pg.waitForFunction(() => document.querySelector('#bp-turn').classList.contains('turn-good'));
        if (i === 0) sameBoxes(readyBoxes, await boxes(pg), `${w}x${h} after a right move`);
        await pg.waitForFunction((n) => document.querySelectorAll('#bp-line .san-token').length >= n, { timeout: 5000 }, i + 2);
      }
    }
    await pg.waitForFunction(() => document.querySelector('#bp-turn-title').textContent === 'Solved after a miss');
    const solvedBoxes = await boxes(pg);
    sameBoxes(readyBoxes, solvedBoxes, `${w}x${h} solved`);
    console.log(`${w}x${h} boxes, x y w h, ready → solved:`);
    for (const sel of Object.keys(readyBoxes)) console.log(`  ${sel.padEnd(16)} ${readyBoxes[sel].map(Math.round).join(' ')} → ${solvedBoxes[sel].map(Math.round).join(' ')}`);
    assert.equal(await pg.evaluate(() => document.documentElement.scrollHeight), readyHeight, `${w}x${h}: the page is as tall solved as ready`);
    // A miss on the way is drawn neutral, not red or green (once the colour change has settled).
    await pg.waitForFunction(() => !document.querySelector('#bp-turn').getAnimations({ subtree: true }).length);
    const look = await pg.evaluate(() => {
      const box = getComputedStyle(document.querySelector('#bp-turn'));
      return [box.backgroundColor, box.borderTopColor, getComputedStyle(document.querySelector('#bp-turn-title')).color];
    });
    assert.deepEqual(look, ['rgb(39, 44, 52)', 'rgb(69, 78, 90)', 'rgb(238, 241, 245)'], 'Solved after a miss uses the plain box');
    assert.equal(await text(pg, '#bp-found'), mate5.found ? 'Black found it in the game.' : `In the game Black played ${mate5.played}.`);
    // A mouse solve on a fresh page: Next has the focus but shows no ring.
    assert.deepEqual(await pg.evaluate(() => [document.activeElement.id, getComputedStyle(document.activeElement).outlineStyle]), ['bp-next', 'none'], 'no focus ring after a mouse solve');
    // The current move stays in view in the two-line box.
    assert.ok(await pg.$eval('#bp-line', (box) => { const a = box.querySelector('.active').getBoundingClientRect(); const b = box.getBoundingClientRect(); return a.top >= b.top - 1 && a.bottom <= b.bottom + 1; }), 'the last move is in view');
    await pg.screenshot({ path: path.join(output, `puzzles-solved-${w}x${h}.png`) });
    const solvedId = await hashId(pg);
    await pg.click('#bp-next');
    await pg.waitForFunction((id) => decodeURIComponent(location.hash.slice(1)) !== id, {}, solvedId);
    await ready(pg);
    sameBoxes(readyBoxes, await boxes(pg), `${w}x${h} the next puzzle`);
    assert.ok(await pg.$eval('#bp-after', (el) => getComputedStyle(el).visibility === 'hidden'), 'the after-solve block is hidden again');
    // Settings at its Keys section.
    await pg.click('#bp-settings-open');
    await pg.waitForFunction(() => document.querySelector('#bp-settings').open && !document.querySelector('#bp-settings').getAnimations().length);
    await pg.evaluate(() => document.querySelector('.bp-keys').scrollIntoView({ block: 'center' }));
    await pg.screenshot({ path: path.join(output, `puzzles-keys-${w}x${h}.png`) });
    await pg.close();
  }

  // The keyboard: read the cursor, steer it, press keys.
  const cursorAt = (pg) => pg.$eval('.bp-cursor', (el) => (el.hidden ? null : el.dataset.square));
  async function steer(pg, target, bottom) {
    if (!(await cursorAt(pg))) await pg.keyboard.press('ArrowUp'); // the first key only shows the cursor
    const at = await cursorAt(pg);
    const flip = bottom === 'black' ? -1 : 1;
    const df = (target.charCodeAt(0) - at.charCodeAt(0)) * flip;
    const dr = (Number(target[1]) - Number(at[1])) * flip;
    for (let i = 0; i < Math.abs(df); i++) await pg.keyboard.press(df > 0 ? 'ArrowRight' : 'ArrowLeft');
    for (let i = 0; i < Math.abs(dr); i++) await pg.keyboard.press(dr > 0 ? 'ArrowUp' : 'ArrowDown');
    assert.equal(await cursorAt(pg), target, 'the cursor reached its square');
  }
  const focusedId = (pg) => pg.evaluate(() => document.activeElement?.id || document.activeElement?.className || '');
  const live = (pg) => pg.$eval('#bp-live', (el) => el.textContent);
  async function keyboardMove(pg, uci, bottom, shot) {
    if (uci[1] === '@') {
      // Tab from the board to the reserve piece, Enter picks it and hands the focus back to the board.
      for (let i = 0; i < 6 && !(await pg.evaluate((l) => document.activeElement.matches(`#bp-seat-bottom .zh-slot[data-letter="${l}"]`), uci[0])); i++) await pg.keyboard.press('Tab');
      await pg.keyboard.press('Enter');
      assert.equal(await focusedId(pg), 'bp-board', 'picking a reserve piece by keyboard moves the focus to the board');
      assert.ok(await cursorAt(pg), 'with the cursor showing');
      assert.match(await live(pg), /from the reserve, \d+ squares?$/);
      assert.equal(await pg.$eval(`#bp-seat-bottom .zh-slot[data-letter="${uci[0]}"]`, (b) => b.getAttribute('aria-pressed')), 'true');
      if (shot) await pg.screenshot({ path: shot });
      await steer(pg, uci.slice(2, 4), bottom);
      await pg.keyboard.press('Enter');
      return;
    }
    await steer(pg, uci.slice(0, 2), bottom);
    await pg.keyboard.press('Enter');
    assert.match(await live(pg), new RegExp(`^\\w+ ${uci.slice(0, 2)} picked, \\d+ moves?$`));
    if (shot) await pg.screenshot({ path: shot });
    await steer(pg, uci.slice(2, 4), bottom);
    await pg.keyboard.press('Enter');
    if (uci[4]) {
      // The promotion picker: the arrows move between the pieces, Enter confirms, focus returns to the board.
      const names = { q: 'Queen', n: 'Knight', r: 'Rook', b: 'Bishop' };
      await pg.waitForSelector('.promotion-choice');
      for (let i = 0; i < 4 && (await pg.evaluate(() => document.activeElement.getAttribute('aria-label'))) !== names[uci[4]]; i++) await pg.keyboard.press('ArrowDown');
      await pg.keyboard.press('Enter');
      await pg.waitForFunction(() => !document.querySelector('.promotion-choice'));
      assert.equal(await focusedId(pg), 'bp-board', 'the focus is back on the board after the promotion');
    }
  }

  // 6. Solving by keyboard alone, from a fresh load: Tab to the board, two drops and an underpromotion.
  {
    const pg = watch(await browser.newPage());
    await pg.setViewport({ width: 1440, height: 900 });
    await pg.goto(`${origin}/bughouse-puzzles/#${PROMO}`);
    await ready(pg);
    assert.equal(await pg.$eval('#bp-board', (b) => b.getAttribute('aria-label')), 'Puzzle board. Arrow keys move, Enter picks up and puts down.');
    assert.ok(await pg.$$eval('#bp-board svg', (ss) => ss.length > 0 && ss.every((s) => s.getAttribute('aria-hidden') === 'true')), 'the board\'s drawing layers are hidden from screen readers');
    for (let i = 0; i < 40 && (await focusedId(pg)) !== 'bp-board'; i++) await pg.keyboard.press('Tab');
    assert.equal(await focusedId(pg), 'bp-board', 'Tab reaches the board');
    assert.equal(await cursorAt(pg), null, 'no cursor before a key is pressed on the board');
    // The first key shows it on the last move's square and says what stands there.
    await pg.keyboard.press('ArrowDown');
    assert.equal(await cursorAt(pg), promo.last.slice(2, 4), 'the cursor starts on the last move\'s square');
    assert.match(await live(pg), /^[a-h][1-8], (empty|(white|black) (pawn|knight|bishop|rook|queen|king))$/);
    // It goes on blur and waits for a key again.
    await pg.keyboard.down('Shift'); await pg.keyboard.press('Tab'); await pg.keyboard.up('Shift');
    assert.equal(await cursorAt(pg), null, 'the cursor goes when the board loses the focus');
    await pg.keyboard.press('Tab');
    assert.equal(await focusedId(pg), 'bp-board');
    const bottom = bottomOf(promo);
    for (let i = 0; i < promo.line.length; i += 2) {
      await pg.waitForFunction(solverTurn, { timeout: 5000 });
      await keyboardMove(pg, promo.line[i], bottom, i === 0 ? path.join(output, 'puzzles-keyboard-1440x900.png') : null);
      if (i + 1 < promo.line.length) {
        await pg.waitForFunction((n) => document.querySelectorAll('#bp-line .san-token').length >= n, { timeout: 5000 }, i + 2);
        assert.match(await live(pg), /^(White|Black) played \S+$/, 'the reply is announced');
      }
    }
    await pg.waitForFunction(() => document.querySelector('#bp-turn-title').textContent === 'Solved!');
    assert.equal(await focusedId(pg), 'bp-board', 'the board keeps the focus when the puzzle ends');
    // The arrows belong to the cursor; Home and End still browse, and Enter does nothing on an earlier move.
    const activeIndex = () => pg.$$eval('#bp-line .san-token', (ts) => ts.findIndex((t) => t.classList.contains('active')));
    const lastIndex = await activeIndex();
    await pg.keyboard.press('ArrowLeft');
    assert.equal(await activeIndex(), lastIndex, 'ArrowLeft on the board moves the cursor, not the line');
    await pg.keyboard.press('Home');
    assert.equal(await activeIndex(), -1, 'Home still goes to the start');
    await pg.keyboard.press('Enter');
    await new Promise((r) => setTimeout(r, 300));
    assert.equal(await hashId(pg), PROMO, 'Enter does nothing while an earlier move is shown');
    await pg.keyboard.press('End');
    await pg.keyboard.press('Enter');
    await pg.waitForFunction((id) => decodeURIComponent(location.hash.slice(1)) !== id, {}, PROMO);
    await ready(pg);
    assert.equal(await focusedId(pg), 'bp-board', 'the board keeps the focus on the next puzzle');
    // Start it: the first move by keyboard.
    const nextRecord = await record(await hashId(pg));
    await keyboardMove(pg, nextRecord.line[0], bottomOf(nextRecord), null);
    await pg.waitForFunction(() => ['turn-good', 'turn-win'].some((c) => document.querySelector('#bp-turn').classList.contains(c)), { timeout: 5000 });
    // Escape puts back a picked piece.
    await pg.click('#bp-retry');
    await ready(pg);
    await pg.focus('#bp-board');
    const first = nextRecord.line[0];
    if (first[1] !== '@') {
      await steer(pg, first.slice(0, 2), bottomOf(nextRecord));
      await pg.keyboard.press('Enter');
      const shown = (sel) => pg.$$eval(sel, (s) => s.filter((q) => q.style.display !== 'none').length);
      await new Promise((r) => setTimeout(r, 100));
      assert.ok(await shown('#bp-board square.move-dest') > 0, 'the picked piece shows its moves');
      await pg.keyboard.press('Escape');
      await new Promise((r) => setTimeout(r, 100));
      assert.equal(await shown('#bp-board square.move-dest, #bp-board square.selected'), 0, 'Escape puts it back');
    }
    // A mouse press on the board takes the cursor away.
    await pg.keyboard.press('ArrowUp');
    assert.ok(await cursorAt(pg));
    const corner = await square(pg, 'a1', bottomOf(nextRecord));
    await pg.mouse.click(corner.x, corner.y);
    assert.equal(await cursorAt(pg), null, 'a mouse press removes the cursor');

    // 5a. Space on a focused Retry presses Retry and never reveals the solution.
    await pg.click('#bp-retry');
    await ready(pg);
    await pg.focus('#bp-retry');
    await pg.keyboard.press('Space');
    await new Promise((r) => setTimeout(r, 900));
    assert.ok(!(await pg.$eval('#bp-turn', (b) => b.classList.contains('turn-revealed'))), 'Space on Retry did not show the solution');
    assert.equal(await pg.$$eval('#bp-line .san-token', (ts) => ts.length), 0, 'no move of the solution was played');
    // The other shortcuts still work with a button focused; Space elsewhere shows the solution.
    await pg.focus('#bp-retry');
    await pg.keyboard.press('r');
    await ready(pg);
    await pg.evaluate(() => document.activeElement.blur());
    await pg.keyboard.press('Space');
    await pg.waitForFunction(() => document.querySelector('#bp-turn-title').textContent === 'Solution shown', { timeout: 15_000 });
    assert.equal(await focusedId(pg), 'bp-next', 'Next takes the focus when the solution has been shown');
    assert.equal(await pg.$eval('#bp-next', (b) => getComputedStyle(b).outlineStyle), 'solid', 'with its ring, after a key');

    // 5c. The keys are listed in Settings and on the buttons.
    assert.deepEqual(await pg.$$eval('#bp-prev, #bp-next, #bp-retry, #bp-solution, #bp-back, #bp-forward', (bs) => Object.fromEntries(bs.map((b) => [b.id, b.getAttribute('aria-keyshortcuts')]))),
      { 'bp-prev': 'P ArrowUp', 'bp-next': 'S ArrowDown', 'bp-retry': 'R', 'bp-solution': 'Space', 'bp-back': 'ArrowLeft', 'bp-forward': 'ArrowRight' });
    assert.ok(await pg.$$eval('#bp-prev, #bp-next, #bp-retry, #bp-solution', (bs) => bs.every((b) => b.title)), 'the tooltips stay');
    const keys = await pg.$$eval('.bp-keys dd', (ds) => ds.map((d) => d.textContent));
    for (const want of ['Next puzzle', 'Previous puzzle', 'Retry', 'Show the solution', 'Back and forward through the moves', 'First and last move', 'Put the piece back'])
      assert.ok(keys.includes(want), `the Keys list has "${want}"`);

    // 7c. The progress grid is one Tab stop: arrows, Home, End, Enter.
    await pg.click('#bp-settings-open');
    await pg.waitForFunction(() => document.querySelector('#bp-settings').open && !document.querySelector('#bp-settings').getAnimations().length);
    assert.equal(await pg.$$eval('#bp-session .session-cell', (cs) => cs.filter((c) => c.tabIndex === 0).length), 1, 'one progress cell is a Tab stop');
    await pg.focus('#bp-session .session-cell[tabindex="0"]');
    const focusedCell = () => pg.evaluate(() => [...document.querySelectorAll('#bp-session .session-cell')].indexOf(document.activeElement));
    const startCell = await focusedCell();
    await pg.keyboard.press('ArrowRight');
    assert.equal(await focusedCell(), startCell + 1, 'ArrowRight moves to the next cell');
    await pg.keyboard.press('End');
    const cellCount = await pg.$$eval('#bp-session .session-cell', (cs) => cs.length);
    assert.equal(await focusedCell(), cellCount - 1, 'End goes to the last cell');
    await pg.keyboard.press('Home');
    assert.equal(await focusedCell(), 0, 'Home goes to the first');
    await pg.keyboard.press('ArrowDown');
    assert.ok(await pg.evaluate(() => document.activeElement.offsetTop > document.querySelector('#bp-session .session-cell').offsetTop), 'ArrowDown goes down a row');
    await pg.keyboard.press('Home');
    await pg.keyboard.press('Enter');
    await pg.waitForFunction(() => document.querySelector('.bp-counter').textContent.startsWith('1 / '));
    assert.equal(await focusedCell(), 0, 'Enter opened the first puzzle and the focus stayed on the grid');
    assert.equal(await pg.$$eval('#bp-session .session-cell', (cs) => cs.filter((c) => c.tabIndex === 0).length), 1);
    await pg.keyboard.press('Escape');

    // 7a. Contrast, measured: coordinates on both squares, the reserve count, the nav's active link.
    const ratios = await pg.evaluate(() => {
      const rgb = (c) => c.match(/[\d.]+/g).slice(0, 3).map(Number);
      const lum = (c) => { const v = rgb(c).map((x) => { x /= 255; return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4; }); return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]; };
      const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
      const coords = [...document.querySelectorAll('#bp-board coord')].map((c) => getComputedStyle(c).color);
      const nb = getComputedStyle(document.querySelector('.zh-nb'));
      const nav = getComputedStyle(document.querySelector('.nav-links a.active'));
      return {
        coords: [...new Set(coords)], coordDark: Math.min(...coords.map((c) => ratio(c, 'rgb(181, 136, 99)'))), coordLight: Math.min(...coords.map((c) => ratio(c, 'rgb(240, 217, 181)'))),
        badge: ratio(nb.color, nb.backgroundColor), badgeColours: [nb.color, nb.backgroundColor], nav: ratio(nav.color, nav.backgroundColor), navColours: [nav.color, nav.backgroundColor],
      };
    });
    console.log('contrast:', JSON.stringify(ratios));
    assert.equal(ratios.coords.length, 1, 'one colour for every coordinate');
    assert.ok(ratios.coordDark >= 4.5 && ratios.coordLight >= 4.5, 'coordinates read on both squares');
    assert.ok(ratios.badge >= 4.5, 'the reserve count reads on its badge');
    assert.ok(ratios.nav >= 4.5, 'the active nav link reads');
    // The cursor ring: at least 3:1 on both square colours.
    const ring = await pg.evaluate(() => {
      const el = document.querySelector('.bp-cursor');
      const c = getComputedStyle(el).boxShadow.match(/rgb\([^)]+\)/)[0];
      const lum = (s) => { const v = s.match(/\d+/g).map(Number).map((x) => { x /= 255; return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4; }); return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]; };
      const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
      return [c, ratio(c, 'rgb(181, 136, 99)'), ratio(c, 'rgb(240, 217, 181)')];
    });
    console.log('cursor ring:', JSON.stringify(ring));
    assert.ok(ring[1] >= 3 && ring[2] >= 3, 'the cursor ring is 3:1 on both squares');
    await pg.close();
  }

  // Keyboard cursor with a piece picked, at the two smaller sizes.
  for (const [w, h] of [[820, 1180], [390, 844]]) {
    const pg = watch(await browser.newPage());
    await pg.setViewport({ width: w, height: h });
    await pg.goto(`${origin}/bughouse-puzzles/#${PROMO}`);
    await ready(pg);
    await pg.focus('#bp-board');
    await keyboardMove(pg, promo.line[0], bottomOf(promo), path.join(output, `puzzles-keyboard-${w}x${h}.png`));
    await pg.close();
  }

  // 3. Reserve pieces by touch, phone sized: tap picks, tap again puts back, tap a square drops; drags still drop.
  {
    const pg = watch(await browser.newPage());
    await pg.setViewport({ width: 390, height: 844, hasTouch: true, isMobile: true });
    await pg.goto(`${origin}/bughouse-puzzles/#${MATE5}`);
    await ready(pg);
    console.log('coarse pointer with touch emulation:', await pg.evaluate(() => matchMedia('(pointer: coarse)').matches));
    const bottom = bottomOf(mate5);
    const slotCentre = (letter) => pg.$eval(`#bp-seat-bottom .zh-slot[data-letter="${letter}"]`, (b) => { const r = b.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; });
    const pressed = (letter) => pg.$eval(`#bp-seat-bottom .zh-slot[data-letter="${letter}"]`, (b) => b.getAttribute('aria-pressed'));
    // chessground hides squares it no longer needs (display: none) rather than removing them.
    const dots = () => pg.$$eval('#bp-board square.move-dest', (s) => s.filter((q) => q.style.display !== 'none').length);
    const tap = async (pt) => { await pg.touchscreen.tap(pt.x, pt.y); await new Promise((r) => setTimeout(r, 250)); };
    const touchDrag = async (from, to) => {
      await pg.touchscreen.touchStart(from.x, from.y);
      for (let i = 1; i <= 8; i++) await pg.touchscreen.touchMove(from.x + ((to.x - from.x) * i) / 8, from.y + ((to.y - from.y) * i) / 8);
      await pg.touchscreen.touchEnd();
    };
    const letter = mate5.line[0][0];
    const targets = mate5.legal[0].split(' ').filter((u) => u.startsWith(`${letter}@`)).length;
    // Tap, then drag, in one session.
    await tap(await slotCentre(letter));
    assert.equal(await pressed(letter), 'true', 'a tap picks the reserve piece');
    assert.equal(await dots(), targets, 'with a dot on every legal square');
    await new Promise((r) => setTimeout(r, 400));
    assert.equal(await pressed(letter), 'true', 'one tap is one pick, never a pick and an unpick');
    await tap(await slotCentre(letter));
    assert.equal(await pressed(letter), 'false', 'a second tap puts it back');
    assert.equal(await dots(), 0, 'no dots once it is put back');
    const onBoard = [...mate5.fen.split(' ')[0].split('[')[0]].filter((ch) => /[a-z]/i.test(ch)).length;
    assert.equal(await pg.$$eval('#bp-board piece:not(.ghost)', (ps) => ps.length), onBoard, 'no stray piece is left on the board from the taps');
    await tap(await slotCentre(letter));
    await pg.screenshot({ path: path.join(output, 'puzzles-touch-picked-390x844.png') });
    await tap(await square(pg, mate5.line[0].slice(2, 4), bottom));
    await pg.waitForFunction(() => document.querySelector('#bp-turn').classList.contains('turn-good'));
    await pg.click('#bp-retry');
    await ready(pg);
    await touchDrag(await slotCentre(letter), await square(pg, mate5.line[0].slice(2, 4), bottom));
    await pg.waitForFunction(() => document.querySelector('#bp-turn').classList.contains('turn-good'));
    // Drag, then tap.
    await pg.click('#bp-retry');
    await ready(pg);
    await touchDrag(await slotCentre(letter), await square(pg, mate5.line[0].slice(2, 4), bottom));
    await pg.waitForFunction(() => document.querySelector('#bp-turn').classList.contains('turn-good'));
    await pg.click('#bp-retry');
    await ready(pg);
    await tap(await slotCentre(letter));
    assert.equal(await pressed(letter), 'true', 'a tap after a drag still picks');
    await tap(await square(pg, mate5.line[0].slice(2, 4), bottom));
    await pg.waitForFunction(() => document.querySelector('#bp-turn').classList.contains('turn-good'));
    // With a mouse: click-click drops.
    await pg.click('#bp-retry');
    await ready(pg);
    const c = await slotCentre(letter);
    await pg.mouse.click(c.x, c.y);
    assert.equal(await pressed(letter), 'true', 'a mouse click picks');
    const t = await square(pg, mate5.line[0].slice(2, 4), bottom);
    await pg.mouse.click(t.x, t.y);
    await pg.waitForFunction(() => document.querySelector('#bp-turn').classList.contains('turn-good'));

    // 7b. Touch targets at 390x844: 44px controls and choices, 24px progress cells.
    await pg.click('#bp-retry');
    await ready(pg);
    const small = (sel, min) => pg.$$eval(sel, (els, min) => els.filter((e) => e.offsetParent).map((e) => { const r = e.getBoundingClientRect(); return [e.id || e.className || e.textContent, Math.round(r.width), Math.round(r.height)]; })
      .filter(([, w, h]) => w < min - 0.5 || h < min - 0.5), min);
    const sizes = await pg.$$eval('#bp-settings-open, #bp-prev, #bp-back, #bp-forward', (els) => els.map((e) => [e.id, Math.round(e.getBoundingClientRect().width), Math.round(e.getBoundingClientRect().height)]));
    assert.deepEqual(await small('#bp-settings-open, #bp-prev, #bp-back, #bp-forward', 44), [], 'the gear, Previous and the step arrows are 44px');
    await pg.click('#bp-settings-open');
    await pg.waitForFunction(() => document.querySelector('#bp-settings').open && !document.querySelector('#bp-settings').getAnimations().length);
    // The FICS set has more themes than are shown at first.
    if (!(await pg.$('.bp-more-themes'))) {
      await pg.click('#bp-set label:nth-child(1)');
      await pg.waitForSelector('.bp-more-themes');
    }
    sizes.push(...await pg.$$eval('#bp-settings-close, .bp-more-themes, .bp-facet .choice, #bp-session .session-cell', (els) => {
      const one = (sel) => els.filter((e) => e.matches(sel)).map((e) => [e.id || e.className, Math.round(e.getBoundingClientRect().width), Math.round(e.getBoundingClientRect().height)]);
      const chips = one('.bp-facet .choice');
      const cells = one('#bp-session .session-cell');
      return [...one('#bp-settings-close'), ...one('.bp-more-themes'),
        ['smallest chip', Math.min(...chips.map((c) => c[1])), Math.min(...chips.map((c) => c[2]))],
        ['smallest progress cell', Math.min(...cells.map((c) => c[1])), Math.min(...cells.map((c) => c[2]))]];
    }));
    console.log('touch targets at 390x844:', JSON.stringify(sizes));
    assert.deepEqual(await small('#bp-settings-close, .bp-more-themes, .bp-facet .choice', 44), [], 'Done, more themes and every choice are 44px');
    assert.deepEqual(await small('#bp-session .session-cell', 24), [], 'progress cells are 24px');
    await pg.close();
  }

  // 7d. Reduced motion: no rise on the feedback, no piece animation, no hover scale or colour fades.
  {
    const pg = watch(await browser.newPage());
    await pg.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }]);
    await pg.setViewport({ width: 1440, height: 900 });
    await pg.goto(`${origin}/bughouse-puzzles/#${MATE5}`);
    await ready(pg);
    const bottom = bottomOf(mate5);
    await play(pg, wrongMove, bottom);
    await pg.waitForFunction(() => document.querySelector('#bp-turn').classList.contains('turn-bad'));
    assert.equal(await pg.$eval('#bp-turn .turn-text', (el) => el.getAnimations().length), 0, 'no animation runs on the verdict');
    await pg.waitForFunction(solverTurn, { timeout: 5000 });
    // Watch for chessground's animated pieces while the right move and the reply land.
    await pg.evaluate(() => {
      window.animSeen = false;
      new MutationObserver(() => { if (document.querySelector('#bp-board piece.anim')) window.animSeen = true; })
        .observe(document.querySelector('#bp-board'), { subtree: true, attributes: true, childList: true });
    });
    await play(pg, mate5.line[0], bottom);
    await pg.waitForFunction(() => document.querySelectorAll('#bp-line .san-token').length >= 2, { timeout: 5000 });
    assert.equal(await pg.evaluate(() => window.animSeen), false, 'pieces do not animate');
    assert.equal(await pg.$eval('#bp-next', (b) => getComputedStyle(b).transitionDuration), '0s', 'no colour fades on the buttons');
    await pg.click('#bp-settings-open');
    await pg.waitForFunction(() => document.querySelector('#bp-settings').open);
    await pg.hover('#bp-session .session-cell');
    assert.equal(await pg.$eval('#bp-session .session-cell', (c) => getComputedStyle(c).transform), 'none', 'no hover scale');
    await pg.close();
  }

  assert.deepEqual(errors, [], 'no page errors');
  console.log('Bughouse puzzles page passed in Chrome.');
} finally {
  await browser.close();
  close();
  await fs.rm(chromeTmp, { recursive: true, force: true });
}
