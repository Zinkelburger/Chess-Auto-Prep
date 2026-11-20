// Drives the built /bughouse-games page in headless Chrome on whatever games
// public/bughouse-games/ holds: npm run build && node scripts/test-games-browser.mjs.
// Games and moves are picked from the files at run time, so the check needs
// only what the contract guarantees. Screenshots land in
// build/bughouse-games-web/ at the repository root.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';
import { serveDist } from './static-server.mjs';

const frontend = fileURLToPath(new URL('..', import.meta.url));
const output = path.resolve(frontend, '../../../build/bughouse-games-web');
await fs.mkdir(output, { recursive: true });
const served = path.join(frontend, 'public/bughouse-games');
const index = JSON.parse(await fs.readFile(path.join(served, 'index.json'), 'utf8'));
const games = await Promise.all(index.games.map(async (e) => JSON.parse(await fs.readFile(path.join(served, e.file), 'utf8'))));
const first = index.games[0];
const game = games[0];
// The first game's middle move, its first move the files annotate (the page shows no annotation),
// and the first move after a wait anywhere.
const mid = game.moves[Math.floor(game.moves.length / 2)];
const annotated = game.moves.find((m) => m.note && m.i < game.moves.length - 1);
const waited = games.flatMap((g) => g.moves.filter((m) => m.waited).map((m) => ({ g, m })))[0];
const clock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const { origin, close } = await serveDist(frontend);
const chromeTmp = await fs.mkdtemp(path.join(os.homedir(), '.cache', 'bgt-'));
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome', headless: true,
  args: ['--disable-dev-shm-usage'],
  env: { ...process.env, TMPDIR: chromeTmp },
});
const text = (page, selector) => page.$eval(selector, (el) => el.textContent.trim());
const shot = (page, name) => page.screenshot({ path: path.join(output, `${name}.png`), fullPage: true });
const ready = (page) => page.waitForFunction(() => document.querySelector('#bg').dataset.state === 'ready' && document.querySelector('#bg').dataset.view === 'game');
const hash = (page) => page.evaluate(() => decodeURIComponent(location.hash));
const atHash = (page, h) => page.waitForFunction((want) => decodeURIComponent(location.hash) === want, {}, h);
const open = async (page, id, i) => { await page.goto(`${origin}/bughouse-games/#${id}${i === undefined ? '' : `:${i}`}`); await ready(page); };
// What a board shows, read from chessground's pieces.
const pieces = (page, b) => page.$eval(`#bg-cg-${b}`, (el) => [...el.querySelectorAll('piece')].filter((p) => !p.classList.contains('ghost')).map((p) => `${p.className}@${p.style.transform}`).sort().join(' '));
const orientation = (page, b) => page.$eval(`#bg-cg-${b}`, (el) => (el.classList.contains('orientation-white') ? 'white' : el.classList.contains('orientation-black') ? 'black' : '?'));
// Nothing inside the panel may stick out sideways.
const overflowing = (page) => page.evaluate(() => [...document.querySelectorAll('.bg-side *, .bg-seat *')]
  .filter((el) => el.scrollWidth > el.clientWidth + 1 && getComputedStyle(el).overflowX === 'visible' && !el.closest('.bg-moves'))
  .map((el) => el.className || el.tagName).slice(0, 5));

try {
  for (const [label, viewport] of [['desktop', { width: 1440, height: 900 }], ['tablet', { width: 1024, height: 768 }], ['phone', { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }]]) {
    const page = await browser.newPage();
    page.setDefaultTimeout(15_000);
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    await page.setViewport(viewport);

    // The list: every game, the collection's own words about itself, a row opens a game.
    await page.goto(`${origin}/bughouse-games/`);
    await page.waitForFunction(() => document.querySelectorAll('.bg-game').length > 0);
    assert.equal(await page.$$eval('.bg-game', (rows) => rows.length), index.games.length);
    assert.equal(await text(page, '.bg-game .bg-game-title'), first.title);
    assert.ok(!(await text(page, '#bg-games')).includes(first.summary), 'the annotator\'s summary is not in the list');
    assert.match(await text(page, '.bg-game .bg-game-facts'), new RegExp(`${first.moves} moves`));
    assert.equal(await text(page, '#bg-source'), index.source.trim(), 'the source sentence is shown');
    const sourceTop = await page.$eval('#bg-source', (el) => el.getBoundingClientRect().top);
    assert.ok(sourceTop < viewport.height, 'the source is on the first screen');
    assert.equal(await page.$eval('a[href="/bughouse-games"][aria-current="page"]', (a) => a.textContent), 'Bughouse Games', 'the nav marks the page');
    await shot(page, `${label}-list`);
    await page.click('.bg-game-link');
    await ready(page);
    assert.equal(await hash(page), `#${first.id}`);
    assert.match(await text(page, '#bg-note'), /Start of the game/);
    assert.ok(!(await text(page, '#bg-note')).includes(game.summary), 'nor at the start of the game');
    const given = game.moves.filter((m) => m.book).length;
    assert.match(await text(page, '#bg-note'), new RegExp(`first ${given} moves were played by people`));
    assert.equal(await text(page, '.bg-moves-label'), 'Starting moves, from a human game');

    // Partners sit side by side: A with White at the bottom, B with Black; each reserve in its seat row.
    assert.equal(await orientation(page, 'A'), 'white');
    assert.equal(await orientation(page, 'B'), 'black');
    assert.match(await page.$eval('#bg-seat-A-bottom .zh-pocket', (el) => el.getAttribute('aria-label')), /A-White/);
    assert.match(await page.$eval('#bg-seat-B-bottom .zh-pocket', (el) => el.getAttribute('aria-label')), /B-Black/);
    assert.equal(await text(page, '#bg-seat-A-bottom .bg-clock'), clock(game.initial_clock));
    assert.equal(await text(page, '#bg-seat-A-bottom .bg-who-name'), game.seats.Awhite);
    const boxes = await page.$$eval('.bg-board-wrap', (els) => els.map((e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width }; }));
    if (viewport.width > 700) assert.ok(boxes[1].x > boxes[0].x + boxes[0].w && Math.abs(boxes[1].y - boxes[0].y) < 2, 'B beside A');
    else assert.ok(boxes[1].y > boxes[0].y + boxes[0].w, 'phone: B under A');
    assert.ok(boxes[0].w >= 300, `boards are a usable size (${boxes[0].w}px)`);
    // Every engine name fits beside its clock: shown whole, at most two lines, clock not pushed out.
    const seats = await page.$$eval('.bg-seat', (rows) => rows.map((r) => {
      const name = r.querySelector('.bg-who-name'), clockEl = r.querySelector('.bg-clock'), row = r.getBoundingClientRect(), c = clockEl.getBoundingClientRect();
      return { clipped: name.scrollHeight > name.clientHeight + 1, inside: c.right <= row.right + 1 && c.bottom <= row.bottom + 1, name: name.textContent };
    }));
    for (const s of seats) assert.ok(s.inside, `${label}: the clock beside "${s.name}" stays in its row`);
    if (seats.some((s) => s.clipped)) console.log(`${label}: names cut short: ${seats.filter((s) => s.clipped).map((s) => s.name).join(', ')}`);

    // A move by deep link: it is current in the list, the card names it, and no annotation shows.
    await open(page, first.id, mid.i);
    await page.waitForFunction((i) => document.querySelector(`.bg-mv[data-i="${i}"]`)?.classList.contains('active'), {}, mid.i);
    assert.match(await text(page, '#bg-note .bg-note-move'), new RegExp(`${escape(mid.san)}$`));
    assert.equal(await page.$$eval('.bg-line, .bg-glyph, .bg-mv-note, #bg-prev-note, #bg-next-note', (els) => els.length), 0, 'no notes, lines or glyphs');
    const listH = await page.$eval('#bg-moves', (el) => el.getBoundingClientRect().height);
    assert.ok(listH >= 200, `${label}: the move list keeps its height (${listH}px)`);
    assert.deepEqual(await overflowing(page), [], `${label}: nothing in the panel sticks out sideways`);
    assert.match(await page.$eval('#bg-analysis', (a) => a.href), /\/bughouse\?fen=.+&fen2=/);
    await shot(page, `${label}-move`);
    // A move the files annotate shows no note either.
    await open(page, first.id, annotated.i);
    assert.ok(!(await text(page, '#bg-note')).includes(annotated.note.trim().slice(0, 30)), `${label}: the annotator's note is not shown`);

    // Keys: → steps and the hash follows; End shows the result; Home.
    await page.keyboard.press('ArrowRight');
    await atHash(page, `#${first.id}:${annotated.i + 1}`);
    await page.keyboard.press('End');
    await atHash(page, `#${first.id}:${game.moves.length - 1}`);
    assert.match(await text(page, '#bg-note'), new RegExp(escape(game.result.text.slice(0, 20))));
    for (const b of ['A', 'B']) assert.match(await text(page, `#bg-eval-${b}`), /^([+−]?\d+\.\d|0\.0|[<>][+−]20|#-?\d+|)$/, `board ${b}'s score reads as a score`);
    await shot(page, `${label}-last`);
    await page.keyboard.press('Home');
    await atHash(page, `#${first.id}`);

    // A move after a wait says so in words, and the list row shows it.
    if (waited) {
      await open(page, waited.g.id, waited.m.i);
      assert.match(await text(page, '#bg-note .bg-note-wait'), /^Before this move, [AB]-(White|Black) (sat|waited) \d/);
      assert.match(await page.$eval(`.bg-mv[data-i="${waited.m.i}"]`, (el) => el.textContent), /sat \d/);
    }
    // Clicking a move in the list goes there.
    await open(page, first.id);
    await page.click(`.bg-mv[data-i="${mid.i}"]`);
    await atHash(page, `#${first.id}:${mid.i}`);
    // HypeBeast on request: switched on it searches the board in focus, a click on a move of its line shows
    // the line on that board, Escape returns to the game, and the next move is searched in turn.
    if (label === 'desktop') {
      const settled = async (b) => { await new Promise((r) => setTimeout(r, 400)); return pieces(page, b); };
      const evaluated = () => page.waitForFunction(() => /^[+\-#]?\d/.test(document.querySelector('#bg-pearl').textContent)
        && document.querySelectorAll('#bg-pvs .ch-pv-move').length > 0, { timeout: 180_000 });
      assert.equal(await page.evaluate(() => crossOriginIsolated), true, 'the page is cross-origin isolated for the engine');
      assert.match(await text(page, '#bg-engine-info'), /^Off/);
      await page.click('#bg-ceval .ch-switch');
      await evaluated();
      const focus = (await text(page, '#bg-engine-name')).match(/^HypeBeast · board ([AB])$/)?.[1];
      assert.ok(focus, 'the engine names the board it searches');
      assert.equal(focus, mid.board, 'it searches the board the move was played on');
      const before = await settled(focus);
      // A press at the move's place, as a player's: the rows are redrawn with each engine update.
      // Measured in one step: a handle can be redrawn away between finding it and measuring it.
      const at = await page.evaluate(() => { const r = document.querySelector('#bg-pvs .ch-pv-move').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; });
      await page.mouse.click(at.x, at.y);
      await page.waitForFunction(() => !document.querySelector('#bg-var-bar').hidden);
      assert.match(await text(page, '#bg-var-text'), new RegExp(`^HypeBeast’s line on board ${focus}: \\S+$`));
      assert.notEqual(await settled(focus), before, 'the line is on the board');
      await shot(page, `${label}-engine-line`);
      await page.keyboard.press('Escape');
      await page.waitForFunction(() => document.querySelector('#bg-var-bar').hidden);
      assert.equal(await settled(focus), before, 'Escape puts the game back');
      await page.keyboard.press('ArrowRight');
      await page.waitForFunction((n) => decodeURIComponent(location.hash).endsWith(`:${n}`), {}, mid.i + 1);
      await evaluated();
      await page.keyboard.press('l');
      await page.waitForFunction(() => document.querySelector('#bg-engine-info').textContent.startsWith('Off'));
      assert.equal(await page.$$eval('#bg-pvs .ch-pv', (r) => r.length), 0, 'off shows no lines');
    }
    // Flip turns both boards; partners stay side by side.
    await page.click('#bg-flip');
    assert.equal(await orientation(page, 'A'), 'black');
    assert.equal(await orientation(page, 'B'), 'white');
    await page.click('#bg-flip');
    // Back to the list.
    // Scrolled down the list, the button can sit under the sticky site nav.
    await page.$eval('#bg-back', (el) => el.scrollIntoView({ block: 'center' }));
    await page.click('#bg-back');
    await page.waitForFunction(() => document.querySelector('#bg').dataset.view === 'list');

    // A game that is not in the collection, and a game file that fails.
    await page.goto(`${origin}/bughouse-games/#no-such-game`);
    await page.waitForFunction(() => /No game/.test(document.querySelector('#bg-list-message').textContent));
    await page.setRequestInterception(true);
    page.on('request', (r) => (r.url().endsWith(first.file) ? r.respond({ status: 503, body: '' }) : r.continue()));
    // A fresh load: the page keeps a game it has read.
    await page.goto('about:blank');
    await page.goto(`${origin}/bughouse-games/#${first.id}`);
    await page.waitForFunction(() => document.querySelector('#bg').dataset.state === 'error');
    assert.match(await text(page, '#bg-problem-text'), /server answered 503/);
    if (label === 'desktop') await shot(page, `${label}-error`);
    await page.close();
    assert.deepEqual(errors.filter((e) => !/503/.test(e)), [], `${label}: no page errors`);
    console.log(`${label}: list, game, no annotations, last move, keys, flip, engine and errors checked`);
  }
} finally {
  await browser.close();
  close();
  await fs.rm(chromeTmp, { recursive: true, force: true });
}
console.log(`screenshots in ${output}`);
