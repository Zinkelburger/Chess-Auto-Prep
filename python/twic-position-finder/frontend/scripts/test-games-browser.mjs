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
// The noted move with the most lines in the collection (the hardest note card to lay out),
// the first move after a wait anywhere, and the first game's first noted move.
const rich = games.flatMap((g) => g.moves.filter((m) => m.note).map((m) => ({ g, m }))).sort((a, b) => b.m.lines.length - a.m.lines.length)[0];
const waited = games.flatMap((g) => g.moves.filter((m) => m.waited).map((m) => ({ g, m })))[0];
const noted = game.moves.find((m) => m.note);
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

    // The first noted move by deep link: its note shows and the move is current in the list.
    await open(page, first.id, noted.i);
    await page.waitForFunction((i) => document.querySelector(`.bg-mv[data-i="${i}"]`)?.classList.contains('active'), {}, noted.i);
    assert.equal(await text(page, '#bg-note .bg-note-text'), noted.note.trim());
    if (noted.glyph) assert.equal(await text(page, '#bg-note .bg-note-head .bg-glyph'), noted.glyph);

    // The richest note card: all its lines, scores as mates where `mate` is set, and the list keeps room.
    await open(page, rich.g.id, rich.m.i);
    assert.equal(await page.$$eval('#bg-note .bg-line', (els) => els.length), rich.m.lines.length);
    const scores = await page.$$eval('#bg-note .bg-line-eval', (els) => els.map((e) => e.textContent));
    rich.m.lines.forEach((l, k) => { if (l.mate !== null) assert.match(scores[k], /mates in \d+/, `${l.id} reads as a mate`); });
    const listH = await page.$eval('#bg-moves', (el) => el.getBoundingClientRect().height);
    assert.ok(listH >= 200, `${label}: the move list keeps its height beside a long note (${listH}px)`);
    assert.deepEqual(await overflowing(page), [], `${label}: nothing in the panel sticks out sideways`);
    assert.match(await page.$eval('#bg-analysis', (a) => a.href), /\/bughouse\?fen=.+&fen2=/);
    await shot(page, `${label}-note`);

    // Into a variation: only its board changes, the bar says so, and Escape comes back.
    const lineIndex = rich.m.lines.length - 1;
    const line = rich.m.lines[lineIndex];
    const still = line.board === 'A' ? 'B' : 'A';
    const stillAnchor = line.from === 'before' ? rich.m.i - 1 : rich.m.i;
    const ply = line.moves.length - 1;
    await page.$eval(`#bg-note .bg-line-move[data-line="${lineIndex}"][data-ply="${ply}"]`, (el) => el.scrollIntoView({ block: 'center' }));
    const stillBefore = line.from === 'after' ? await pieces(page, still) : null;
    await page.click(`#bg-note .bg-line-move[data-line="${lineIndex}"][data-ply="${ply}"]`);
    await page.waitForSelector('#bg-var-bar:not([hidden])');
    assert.match(await text(page, '#bg-var-text'), new RegExp(`board ${line.board}`));
    assert.equal(await page.$eval(`#bg-var-tag-${line.board}`, (el) => el.hidden), false);
    assert.ok(await page.$eval('#bg-note', (box) => {
      const t = box.querySelector('.bg-line-move.active').getBoundingClientRect(), b = box.getBoundingClientRect();
      return t.top >= b.top - 1 && t.bottom <= b.bottom + 1;
    }), `${label}: the line being walked stays in view in the note card`);
    if (stillBefore !== null) assert.equal(await pieces(page, still), stillBefore, 'the other board did not move');
    assert.equal(await page.$eval('#bg-analysis', (a) => new URL(a.href).searchParams.get('fen')), line.moves[ply].fen, 'the analysis link opens the variation');
    assert.equal(await page.$eval('#bg-analysis', (a) => new URL(a.href).searchParams.get('fen2')), stillAnchor >= 0 ? rich.g.moves[stillAnchor].fen[still] : rich.g.start[still]);
    if (label === 'phone') await page.$eval('#bg-var-bar', (el) => el.scrollIntoView({ block: 'start' }));
    await shot(page, `${label}-variation`);
    await page.keyboard.press('Escape');
    await page.waitForSelector('#bg-var-bar', { hidden: true });

    // Keys: → steps and the hash follows; N jumps to the next note; End shows the result; Home.
    if (rich.m.i < rich.g.moves.length - 1) {
      await page.keyboard.press('ArrowRight');
      await atHash(page, `#${rich.g.id}:${rich.m.i + 1}`);
    }
    const here = Math.min(rich.m.i + 1, rich.g.moves.length - 1);
    const nextNote = rich.g.moves.find((m) => m.i > here && m.note);
    if (nextNote) {
      await page.keyboard.press('n');
      await atHash(page, `#${rich.g.id}:${nextNote.i}`);
    }
    await page.keyboard.press('End');
    await atHash(page, `#${rich.g.id}:${rich.g.moves.length - 1}`);
    assert.match(await text(page, '#bg-note'), new RegExp(escape(rich.g.result.text.slice(0, 20))));
    const last = rich.g.moves.at(-1);
    if (last.note) assert.equal(await text(page, '#bg-note .bg-note-text'), last.note.trim());
    for (const b of ['A', 'B']) assert.match(await text(page, `#bg-eval-${b}`), /^([+−]?\d+\.\d|0\.0|[<>][+−]20|#-?\d+|)$/, `board ${b}'s score reads as a score`);
    await shot(page, `${label}-last`);
    await page.keyboard.press('Home');
    await atHash(page, `#${rich.g.id}`);

    // A move after a wait says so in words, and the list row shows it.
    if (waited) {
      await open(page, waited.g.id, waited.m.i);
      assert.match(await text(page, '#bg-note .bg-note-wait'), /^Before this move, [AB]-(White|Black) (sat|waited) \d/);
      assert.match(await page.$eval(`.bg-mv[data-i="${waited.m.i}"]`, (el) => el.textContent), /sat \d/);
    }
    // Clicking a move in the list goes there.
    await open(page, first.id);
    await page.click(`.bg-mv[data-i="${noted.i}"]`);
    await atHash(page, `#${first.id}:${noted.i}`);
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
      assert.equal(focus, noted.board, 'it searches the board the move was played on');
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
      await page.waitForFunction((n) => decodeURIComponent(location.hash).endsWith(`:${n}`), {}, noted.i + 1);
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
    console.log(`${label}: list, game, notes, ${rich.m.lines.length} lines, variation, last move, keys, flip and errors checked`);
  }
} finally {
  await browser.close();
  close();
  await fs.rm(chromeTmp, { recursive: true, force: true });
}
console.log(`screenshots in ${output}`);
