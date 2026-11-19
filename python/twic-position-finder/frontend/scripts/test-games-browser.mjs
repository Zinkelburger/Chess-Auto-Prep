// Drives the built /bughouse-games page in headless Chrome on the games in
// public/bughouse-games/: npm run build && node scripts/test-games-browser.mjs.
// Screenshots land in build/bughouse-games-web/ at the repository root.
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
const index = JSON.parse(await fs.readFile(path.join(frontend, 'public/bughouse-games/index.json'), 'utf8'));
const first = index.games[0];
const game = JSON.parse(await fs.readFile(path.join(frontend, 'public/bughouse-games', first.file), 'utf8'));
// The first move with a note and a line that starts before it, and the first after a wait.
const annotated = game.moves.find((m) => m.note && m.lines.some((l) => l.from === 'before'));
const waited = game.moves.find((m) => m.waited);
assert.ok(annotated && waited, 'the first game has an annotated move with a line and a wait');

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
// What a board shows, read from chessground's pieces: square → piece, from the board's own orientation.
const pieces = (page, b) => page.$eval(`#bg-cg-${b}`, (el) => [...el.querySelectorAll('piece')].filter((p) => !p.classList.contains('ghost')).map((p) => `${p.className}@${p.style.transform}`).sort().join(' '));

try {
  for (const [label, viewport] of [['desktop', { width: 1440, height: 900 }], ['tablet', { width: 1024, height: 768 }], ['phone', { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }]]) {
    const page = await browser.newPage();
    page.setDefaultTimeout(15_000);
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    await page.setViewport(viewport);

    // The list: every game with its title and facts; a row opens the game.
    await page.goto(`${origin}/bughouse-games/`);
    await page.waitForFunction(() => document.querySelectorAll('.bg-game').length > 0);
    assert.equal(await page.$$eval('.bg-game', (rows) => rows.length), index.games.length);
    assert.equal(await text(page, '.bg-game .bg-game-title'), first.title);
    assert.match(await text(page, '.bg-game .bg-game-facts'), new RegExp(`${first.moves} moves`));
    assert.match(await text(page, '#bg-source'), /PLACEHOLDER/);
    assert.equal(await page.$eval('a[href="/bughouse-games"][aria-current="page"]', (a) => a.textContent), 'Bughouse Games', 'the nav marks the page');
    await shot(page, `${label}-list`);
    await page.click('.bg-game-link');
    await ready(page);
    assert.equal(await hash(page), `#${first.id}`);
    assert.match(await text(page, '#bg-note'), /Start of the game/);

    // Partners sit side by side: A with White at the bottom, B with Black; both reserves in their seat rows.
    assert.equal(await page.$eval('#bg-cg-A .cg-wrap, #bg-cg-A.cg-wrap', (el) => el.classList.contains('orientation-white')), true, 'board A: White at the bottom');
    assert.equal(await page.$eval('#bg-cg-B .cg-wrap, #bg-cg-B.cg-wrap', (el) => el.classList.contains('orientation-black')), true, 'board B: Black at the bottom');
    assert.match(await page.$eval('#bg-seat-A-bottom .zh-pocket', (el) => el.getAttribute('aria-label')), /A-White/);
    assert.match(await page.$eval('#bg-seat-B-bottom .zh-pocket', (el) => el.getAttribute('aria-label')), /B-Black/);
    assert.match(await text(page, '#bg-seat-A-bottom .bg-clock'), /^2:00$/);
    const boxes = await page.$$eval('.bg-board-wrap', (els) => els.map((e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width }; }));
    if (viewport.width > 700) assert.ok(boxes[1].x > boxes[0].x + boxes[0].w && Math.abs(boxes[1].y - boxes[0].y) < 2, 'desktop: B beside A');
    else assert.ok(boxes[1].y > boxes[0].y + boxes[0].w, 'phone: B under A');
    assert.ok(boxes[0].w >= 300, `boards are a usable size (${boxes[0].w}px)`);

    // An annotated move by deep link: its note, glyph and lines show; the move is current in the list.
    await page.goto(`${origin}/bughouse-games/#${first.id}:${annotated.i}`);
    await ready(page);
    await page.waitForFunction((i) => document.querySelector(`.bg-mv[data-i="${i}"]`)?.classList.contains('active'), {}, annotated.i);
    assert.match(await text(page, '#bg-note .bg-note-text'), new RegExp(annotated.note.slice(0, 20).replace(/[.+?()[\]]/g, '\\$&')));
    if (annotated.glyph) assert.equal(await text(page, '#bg-note .bg-note-head .bg-glyph'), annotated.glyph);
    assert.equal(await page.$$eval('#bg-note .bg-line', (els) => els.length), annotated.lines.length);
    assert.match(await page.$eval('#bg-analysis', (a) => a.href), /\/bughouse\?fen=.+&fen2=/);
    await shot(page, `${label}-note`);

    // Into a variation: only that board changes, the bar says so, and Escape comes back.
    const lineIndex = annotated.lines.findIndex((l) => l.from === 'before');
    const line = annotated.lines[lineIndex];
    const still = line.board === 'A' ? 'B' : 'A';
    const stillBefore = await pieces(page, still);
    await page.click(`#bg-note .bg-line-move[data-line="${lineIndex}"][data-ply="0"]`);
    await page.waitForSelector('#bg-var-bar:not([hidden])');
    assert.match(await text(page, '#bg-var-text'), new RegExp(`board ${line.board}`));
    assert.equal(await page.$eval(`#bg-var-tag-${line.board}`, (el) => el.hidden), false);
    assert.equal(await pieces(page, still), stillBefore, 'the other board did not move');
    assert.equal(await page.$eval('#bg-analysis', (a) => new URL(a.href).searchParams.get('fen')), line.moves[0].fen, 'the analysis link opens the variation');
    if (label === 'phone') await page.$eval('#bg-var-bar', (el) => el.scrollIntoView({ block: 'center' }));
    await shot(page, `${label}-variation`);
    await page.keyboard.press('Escape');
    await page.waitForSelector('#bg-var-bar[hidden]', { hidden: true });
    assert.equal(await page.$eval(`#bg-var-tag-${line.board}`, (el) => el.hidden), true);

    // Keys: → steps and the hash follows; N jumps to the next note; Home and End.
    await page.keyboard.press('ArrowRight');
    await page.waitForFunction((h) => decodeURIComponent(location.hash) === h, {}, `#${first.id}:${annotated.i + 1}`);
    const nextNote = game.moves.find((m) => m.i > annotated.i + 1 && m.note);
    if (nextNote) {
      await page.keyboard.press('n');
      await page.waitForFunction((h) => decodeURIComponent(location.hash) === h, {}, `#${first.id}:${nextNote.i}`);
    }
    await page.keyboard.press('End');
    await page.waitForFunction((h) => decodeURIComponent(location.hash) === h, {}, `#${first.id}:${game.moves.length - 1}`);
    assert.match(await text(page, '#bg-note'), new RegExp(game.result.text.slice(0, 15)));
    await page.keyboard.press('Home');
    await page.waitForFunction((h) => decodeURIComponent(location.hash) === h, {}, `#${first.id}`);
    // Clicking a move in the list goes there.
    await page.click(`.bg-mv[data-i="${waited.i}"]`);
    await page.waitForFunction((h) => decodeURIComponent(location.hash) === h, {}, `#${first.id}:${waited.i}`);
    assert.match(await text(page, '#bg-note .bg-note-wait'), /sat \d/);
    // Flip turns both boards; partners stay side by side.
    await page.click('#bg-flip');
    assert.equal(await page.$eval('#bg-cg-A .cg-wrap, #bg-cg-A.cg-wrap', (el) => el.classList.contains('orientation-black')), true);
    assert.equal(await page.$eval('#bg-cg-B .cg-wrap, #bg-cg-B.cg-wrap', (el) => el.classList.contains('orientation-white')), true);
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
    console.log(`${label}: list, game, note, variation, keys, flip and errors checked`);
  }
} finally {
  await browser.close();
  close();
  await fs.rm(chromeTmp, { recursive: true, force: true });
}
console.log(`screenshots in ${output}`);
