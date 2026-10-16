// Drives the built /bughouse page in headless Chrome with the real engine:
// npm run build && node scripts/test-bughouse-browser.mjs. Screenshots land
// in build/bughouse-web/ at the repository root.
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
// Served with public/_headers, as Cloudflare serves it.
const { origin, close } = await serveDist(frontend);
// Chrome's singleton socket path must stay short; the job runner's TMPDIR is too long.
const chromeTmp = await fs.mkdtemp(path.join(os.homedir(), '.cache', 'bht-'));
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome', headless: true,
  // WebGPU in headless Chrome needs these; without a GPU the page falls back to the CPU.
  args: ['--disable-dev-shm-usage', '--enable-unsafe-webgpu', '--enable-features=Vulkan', '--use-angle=vulkan', '--ignore-gpu-blocklist'],
  env: { ...process.env, TMPDIR: chromeTmp },
});
const fen = (page) => page.$eval('#ch-fen', (el) => el.value);
const square = async (page, key) => {
  const box = await page.$eval('#ch-board', (el) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width }; });
  const file = key.charCodeAt(0) - 97, rank = Number(key[1]) - 1, s = box.w / 8;
  return { x: box.x + (file + 0.5) * s, y: box.y + (7 - rank + 0.5) * s };
};
const click = async (page, key) => { const p = await square(page, key); await page.mouse.click(p.x, p.y); };
// Chessground reports moves and clicks on a 1 ms timer, so wait for their effect.
const until = (page, selector, pattern) => page.waitForFunction(
  (sel, src) => new RegExp(src).test(document.querySelector(sel)[sel === '#ch-fen' || sel === '#ch-pgn' ? 'value' : 'textContent']),
  { timeout: 5000 }, selector, pattern.source);
const evaluated = (page) => page.waitForFunction(() => /^[+\-#]?\d/.test(document.querySelector('#ch-pearl').textContent) && document.querySelectorAll('.ch-pv').length > 0, { timeout: 180_000 });
const text = (page, selector) => page.$eval(selector, (el) => el.textContent);
const url = (position) => `${origin}/bughouse/?fen=${encodeURIComponent(position)}`;
const sitDone = (page) => page.waitForFunction(() => {
  const rows = document.querySelectorAll('#bs-sit .bs-sit-row');
  return rows.length === 6 && ![...rows].some((r) => r.querySelector('.ch-spinner'));
}, { timeout: 180_000 });
const HOLE = 'r2q1rk1/pp3p1p/2n2Bp1/8/8/8/PPP2PPP/R2Q1RK1[] w - - 0 1';

try {
  const page = await browser.newPage();
  page.setDefaultTimeout(30_000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.setViewport({ width: 1440, height: 900 });
  // Small sit searches keep the check quick on a two-CPU runner.
  await page.goto(`${origin}/bughouse/`);
  // BUGHOUSE_BACKEND=cpu checks the CPU path on a machine that has WebGPU.
  await page.evaluate((backend) => {
    localStorage.clear();
    localStorage.setItem('bughouse-analysis-v3', JSON.stringify({ sitNodes: 100 }));
    if (backend) localStorage.setItem('bughouse-engine-backend', backend);
  }, process.env.BUGHOUSE_BACKEND ?? '');
  await page.goto(url('r1bqkb1r/pppp1ppp/2n2n2/4p3/4P3/2N2N2/PPPP1PPP/R1BQKB1R[] w KQkq - 4 4'));
  assert.equal(await page.evaluate(() => crossOriginIsolated), true, 'the page is cross-origin isolated');

  // The engine starts and evaluates, with no net to download; the sit panel fills.
  await evaluated(page);
  assert.equal(await page.$('#ch-gauge'), null, 'no evaluation bar beside the board');
  assert.equal(await page.$('.ch-moves-empty'), null, 'an empty move list has no hint');
  await sitDone(page);
  console.log('sit panel:', (await page.$$eval('#bs-sit .bs-sit-row', (rows) => rows.map((r) => r.textContent))).join(' | '));
  const before = await page.$eval('#ch-pearl', (el) => el.textContent);
  console.log('eval without hands:', before, await page.$eval('#ch-engine-info', (el) => el.textContent));
  await page.screenshot({ path: path.join(output, 'analysis.png') });

  // + under Black's knight: the hand, the FEN and the eval follow.
  await page.click('#ch-hand-top .ch-step[data-role="knight"][data-step="more"]');
  assert.match(await fen(page), /\[n\] w/);
  assert.equal(await page.$eval('#ch-hand-top .zh-slot[data-role="knight"]', (el) => el.dataset.nb), '1');
  await page.waitForFunction((b) => {
    const t = document.querySelector('#ch-pearl').textContent;
    // Searched for a while, or to its end on a slow CPU.
    const searched = parseInt(document.querySelector('#ch-engine-info').textContent.replace(/,/g, ''), 10) >= 100 || document.querySelector('#ch-bar').style.width === '100%';
    return /^[+\-#]?\d/.test(t) && t !== b && searched;
  }, { timeout: 120_000 }, before);
  const after = await page.$eval('#ch-pearl', (el) => el.textContent);
  console.log('eval with a knight in Black’s hand:', after);
  // Hivemind's winning chance, as centipawns: a knight in hand is worth a few tenths here.
  assert.ok(Number(after) < Number(before) - 0.2, 'a knight for Black is clearly good for Black');
  assert.match(await page.$eval('#ch-moves', (el) => el.textContent), /Hands edited at the start: \+n/);

  // − takes it back; − at zero is disabled.
  await page.click('#ch-hand-top .ch-step[data-role="knight"][data-step="fewer"]');
  assert.match(await fen(page), /\[\] w/);
  assert.equal(await page.$eval('#ch-hand-top .ch-step[data-role="knight"][data-step="fewer"]', (el) => el.disabled), true);

  // Moves by clicking squares, then a drop from the hand by click-and-square.
  await click(page, 'd2'); await click(page, 'd4');
  await until(page, '#ch-fen', / b /); // d4 is on the board before Black answers
  await click(page, 'e5'); await click(page, 'd4');
  await until(page, '#ch-fen', /\[\] w/); // exd4: the pawn went to Black's partner, not Black's hand
  await page.click('#ch-hand-bottom .ch-step[data-role="knight"][data-step="more"]'); // White +N
  await page.click('#ch-hand-bottom .zh-slot[data-role="knight"]');
  await click(page, 'd5');
  await until(page, '#ch-moves', /N@d5/);
  assert.match(await page.$eval('#ch-moves', (el) => el.textContent), /\+N/, 'the edit is marked in the moves');
  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('ArrowLeft');
  assert.match(await fen(page), /\[\] b/, 'back before exd4');
  await page.keyboard.press('ArrowDown');
  assert.match(await fen(page), /\/3N4\/.*\[\] b/, 'last move: after N@d5');

  // PGN shows the line.
  assert.match(await page.$eval('#ch-pgn', (el) => el.value), /4\. d4 exd4 \{ Hands edited: \+N \} 5\. N@d5/);
  await evaluated(page);
  await page.screenshot({ path: path.join(output, 'analysis-line.png') });

  // Lichess's analysis tools. Hovering an engine move shows its position on a small board.
  await page.waitForFunction(() => document.querySelectorAll('#ch-pvs .ch-pv-move').length > 2);
  // The engine redraws its lines as it searches, so aim at a move until the pointer lands on one.
  for (let i = 0; i < 20 && await page.$eval('#ch-pv-board', (el) => el.hidden); i++) {
    const pvMove = await page.$$eval('#ch-pvs .ch-pv-move', (es) => { const r = es[1].getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; });
    await page.mouse.move(5, 5);
    await page.mouse.move(pvMove[0], pvMove[1]);
    await new Promise((r) => setTimeout(r, 100));
  }
  await page.waitForFunction(() => !document.querySelector('#ch-pv-board').hidden && document.querySelector('#ch-pv-board cg-board'));
  await page.mouse.move(5, 5);
  // Show threat (X): the other side's best move, from the flipped position.
  await page.keyboard.press('x');
  await until(page, '#ch-engine-name', /Show threat/);
  await page.keyboard.press('x');
  await until(page, '#ch-engine-name', /Hivemind/);
  // Right-click a move: Lichess's menu, Copy PGN puts the line on the clipboard.
  await page.browserContext().overridePermissions(origin, ['clipboard-read', 'clipboard-write', 'clipboard-sanitized-write']);
  await page.bringToFront();
  // Measured and clicked in one go: the move list redraws as the engine reports.
  const box = await page.$$eval('#ch-moves .ch-move', (moves) => { const r = moves[1].getBoundingClientRect(); return { x: r.x, y: r.y }; });
  await page.mouse.click(box.x + 4, box.y + 4, { button: 'right' });
  assert.deepEqual(await page.$$eval('.ch-menu button', (bs) => bs.map((b) => b.textContent)), ['Force variation', 'Copy main line PGN', 'Delete from here']);
  assert.equal(await page.$$eval('.ch-menu button svg path', (ps) => ps.length), 3); // Lichess's glyph on each item
  await page.screenshot({ path: path.join(output, 'move-menu.png') });
  await page.click('.ch-menu button:nth-of-type(2)'); // a real click: the clipboard needs a user gesture
  await until(page, '#ch-toast', /PGN copied/);
  assert.match(await page.evaluate(() => navigator.clipboard.readText()), /4\. d4 exd4 \{ Hands edited: \+N \} 5\. N@d5/);
  // ☰ menu (H) with Lichess's switches; inline notation.
  await page.keyboard.press('h');
  await page.waitForSelector('#ch-action-menu:not([hidden]) .ch-menu-switch');
  await page.$$eval('.ch-menu-switch', (rows) => rows.find((r) => r.textContent.includes('Inline notation')).querySelector('input').click());
  await page.keyboard.press('Escape');
  assert.equal(await page.$eval('#ch-moves', (el) => el.classList.contains('ch-moves-inline')), true);
  await page.keyboard.down('Shift'); await page.keyboard.press('I'); await page.keyboard.up('Shift');
  assert.equal(await page.$eval('#ch-moves', (el) => el.classList.contains('ch-moves-inline')), false);
  // Keyboard help (?).
  await page.keyboard.down('Shift'); await page.keyboard.press('?'); await page.keyboard.up('Shift');
  assert.equal(await page.$eval('dialog.ch-help', (d) => d.open), true);
  await page.keyboard.press('Escape');
  // A reload comes back to the same moves and position.
  const kept = await fen(page);
  await new Promise((r) => setTimeout(r, 500));
  await page.reload();
  await page.waitForSelector('#ch-moves .ch-move');
  assert.equal(await fen(page), kept);
  assert.match(await page.$eval('#ch-moves', (el) => el.textContent), /N@d5/);
  // A plain /bughouse, as from the site's menu, is a clean board; the analysis is still there behind its link.
  await page.goto(`${origin}/bughouse/`);
  await page.waitForSelector('#ch-fen');
  assert.equal(await fen(page), 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1', 'the menu link opens a clean board');
  assert.equal(await page.$$eval('#ch-moves .ch-move', (els) => els.length), 0);
  await page.goto(url(kept));
  await page.waitForSelector('#ch-moves .ch-move');
  assert.equal(await fen(page), kept, 'the link to the saved position reopens the analysis');
  // Practice with computer: White is the player (board not flipped); after a White move the engine answers.
  await page.keyboard.press('ArrowLeft');
  await until(page, '#ch-fen', / w /);
  await page.click('#ch-practice-toggle');
  await until(page, '#ch-practice', /Your turn/);
  const beforeBb5 = await fen(page);
  await click(page, 'f1'); await click(page, 'b5');
  await until(page, '#ch-moves', /Bb5/);
  // The engine's answer: White to move again, in a new position.
  await page.waitForFunction((b) => { const f = document.querySelector('#ch-fen').value; return / w /.test(f) && f !== b; }, { timeout: 120_000 }, beforeBb5);
  await until(page, '#ch-practice', /Your turn/);
  await page.screenshot({ path: path.join(output, 'practice.png') });
  await page.click('#ch-practice-toggle');
  assert.equal(await page.$eval('#ch-practice', (el) => el.hidden), true);
  // Back to N@d5: Bb5 and the reply are a variation now.
  await page.keyboard.press('ArrowLeft'); await page.keyboard.press('ArrowLeft'); await page.keyboard.press('ArrowRight');
  await until(page, '#ch-fen', /\/3N4\/.*\[\] b/);

  // Board editor: its own page, as lila's /editor, opened on the analysed position.
  const fields = (f) => f.split(' ').slice(0, 3).join(' ');
  const analysed = await fen(page);
  const moveCount = await page.$$eval('#ch-moves .ch-move', (els) => els.length);
  await Promise.all([page.waitForNavigation(), page.click('#ch-edit')]);
  assert.match(page.url(), /\/bughouse\/editor\/\?fen=/);
  assert.equal(await page.$eval('#ch', (el) => el.dataset.mode), 'editor');
  assert.equal(fields(await fen(page)), fields(analysed), 'the editor opens on the analysed position');
  // A white queen painted on h5, a black pawn removed and a queen added to Black's hand.
  await page.waitForSelector('#ch-spare-bottom .ch-spare-piece');
  const queen = await page.$('#ch-spare-bottom .ch-spare-piece:nth-child(3)');
  await queen.click();
  await new Promise((r) => setTimeout(r, 200));
  await click(page, 'h5');
  await until(page, '#ch-fen', /\/3N3Q\//); // the queen is on h5
  await page.click('#ch-spare-top .ch-trash');
  await click(page, 'a7');
  await until(page, '#ch-fen', /^r1bqkb1r\/1ppp/); // the a7 pawn is gone
  await page.click('#ch-hand-top .ch-step[data-role="queen"][data-step="more"]'); // Black +Q
  const edited = await fen(page);
  assert.match(edited, /\[[^\]]*q[^\]]*\]/);
  assert.equal(new URL(page.url()).searchParams.get('fen'), edited, 'the URL follows every edit');
  assert.equal(await page.$eval('#ch-url', (el) => el.value), page.url());
  await page.screenshot({ path: path.join(output, 'editor.png') });
  // A reload keeps the edits; Back is the analysis with its moves, Forward the edits again.
  await page.reload();
  await page.waitForSelector('#ch-spare-bottom .ch-spare-piece');
  assert.equal(await fen(page), edited, 'a reload keeps the edits');
  await page.goBack();
  await page.waitForSelector('#ch-moves .ch-move');
  assert.equal(await fen(page), analysed, 'Back returns to the analysis');
  assert.equal(await page.$$eval('#ch-moves .ch-move', (els) => els.length), moveCount, 'with its moves');
  await page.goForward();
  await page.waitForSelector('#ch-spare-bottom .ch-spare-piece');
  assert.equal(await fen(page), edited);
  // Black to play, then "Analysis board" opens the position fresh, turned as in the editor (lila's ?color=).
  await page.click('#ch-turn button[data-turn="black"]');
  await Promise.all([page.waitForNavigation(), page.click('#ch-editor-analyse')]);
  assert.equal(await page.$eval('#ch', (el) => el.dataset.mode), 'analysis');
  assert.match(await fen(page), / b /);
  assert.equal(await page.$$eval('#ch-moves .ch-move', (els) => els.length), 0, 'a new analysis');
  assert.match(page.url(), /&color=white$/);
  assert.equal(await page.$eval('#ch-board', (el) => el.classList.contains('orientation-white')), true, 'White stays below');
  await evaluated(page);

  // The g7 hole: a knight would mate, and its row is marked as mating.
  await page.goto(url(HOLE));
  await sitDone(page);
  console.log('hole:', (await page.$$eval('#bs-sit .bs-sit-row', (rows) => rows.map((r) => r.textContent))).join(' | '));
  assert.deepEqual(await page.$$eval('#bs-sit th', (ths) => ths.map((th) => th.textContent)), ['Option', 'Eval', 'Best move']);
  assert.deepEqual(await page.$$eval('#bs-sit .bs-sit-label', (ls) => ls.map((l) => l.textContent)), ['Move now', 'Pawn', 'Knight', 'Bishop', 'Rook', 'Queen'], 'piece rows carry no +');
  assert.match(await text(page, '#bs-sit .bs-sit-row[data-role="knight"].bs-sit-mates'), /#1.*N@h6/);
  // Hovering a row draws its move solid, in place of the engine's pale arrows.
  await page.hover('#bs-sit .bs-sit-row[data-role="knight"]');
  await page.waitForSelector('cg-container svg g[cgHash$=",h6,blue"]', { timeout: 5_000 });
  assert.equal(await page.$('cg-container svg g[cgHash*="paleBlue"]'), null, 'engine arrows give way to the hovered row');
  await page.screenshot({ path: path.join(output, 'sit-for-knight.png') });
  // Clicking the knight row gives White the knight; the engine then mates.
  await page.click('#bs-sit .bs-sit-row[data-role="knight"]');
  assert.match(await fen(page), /\[N\] w/);
  await page.waitForFunction(() => document.querySelector('#ch-pearl').textContent.startsWith('#'), { timeout: 120_000 });

  // A laptop screen: the move list keeps its rows and the sit panel all six.
  await page.setViewport({ width: 1366, height: 768 });
  await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  // At least three rows of moves in view, without scrolling the panel.
  const visible = await page.$eval('#ch-moves', (el) => {
    const moves = el.getBoundingClientRect(), tools = document.querySelector('#ch-tools').getBoundingClientRect();
    return Math.min(moves.bottom, tools.bottom) - moves.top;
  });
  assert.ok(visible >= 70, `the move list is in view at 1366×768 (${Math.round(visible)} px)`);
  assert.equal(await page.$$eval('#bs-sit .bs-sit-row', (rows) => rows.filter((r) => r.getBoundingClientRect().height > 20).length), 6);
  await page.screenshot({ path: path.join(output, 'laptop-1366x768.png') });

  // The gear: lila's sliders. ∞ search time is infinite analysis, which carries on from the first search's tree after the sit rows.
  await page.setViewport({ width: 1440, height: 900 });
  const slide = (selector, value, event = 'input') => page.$eval(selector, (el, [v, ev]) => {
    el.value = String(v);
    el.dispatchEvent(new Event(ev, { bubbles: true }));
  }, [value, event]);
  await page.click('#ch-gear');
  const rows = () => page.$$eval('#ch-settings .ch-setting', (rs) => rs.filter((r) => !r.hidden).map((r) => r.querySelector('label').textContent));
  const backend = await text(page, '#ch-engine-name');
  console.log('gear rows on', backend, '→', (await rows()).join(', '));
  assert.deepEqual((await rows()).filter((r) => r !== 'Hardware' && r !== 'Threads'), ['Search time', 'Multiple lines', 'Sit search']);
  assert.equal((await rows()).includes('Threads'), !backend.includes('GPU'), 'threads only for the CPU path');
  assert.equal(await text(page, '#ch-settings .ch-setting:first-child .ch-setting-value'), '10s');
  await page.screenshot({ path: path.join(output, 'gear.png') });
  await page.keyboard.press('Escape');
  assert.equal(await page.$eval('#ch-settings', (el) => el.hidden), true, 'Esc closes the gear');
  await page.click('#ch-gear');
  await slide('#ch-set-search', 12); // ∞
  assert.equal(await text(page, '#ch-settings .ch-setting:first-child .ch-setting-value'), '∞');
  await page.mouse.click(300, 300); // on the board: a click elsewhere closes it
  assert.equal(await page.$eval('#ch-settings', (el) => el.hidden), true, 'a click elsewhere closes the gear');
  await page.goto(url('r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R[] w KQkq - 4 4'));
  await evaluated(page);
  await sitDone(page);
  const positions = async () => parseInt((await text(page, '#ch-engine-info')).replace(/,/g, ''), 10);
  const first = await positions();
  await page.waitForFunction((n) => parseInt(document.querySelector('#ch-engine-info').textContent.replace(/,/g, ''), 10) > n, { timeout: 5_000 }, first);
  console.log('infinite analysis resumed past', first, 'positions:', await text(page, '#ch-engine-info'));
  await page.click('#ch-gear');
  await slide('#ch-set-search', 4); // back to 10 s
  // On the CPU, Threads starts a new engine with that many threads.
  if (!backend.includes('GPU')) {
    const max = Number(await page.$eval('#ch-set-threads', (el) => el.max));
    const want = Math.max(1, Math.min(max, 2));
    await slide('#ch-set-threads', want, 'change');
    await until(page, '#ch-engine-name', new RegExp(`CPU × ${want}$`));
    await evaluated(page);
  }
  await page.keyboard.press('Escape');

  // A phone: board, hands with + and −, engine and sit panel.
  await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  await page.goto(url('r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R[] w KQkq - 4 4'));
  await evaluated(page);
  await sitDone(page);
  await page.screenshot({ path: path.join(output, 'mobile.png'), fullPage: true });
  // A phone widens its layout viewport to fit wide content, so measure against
  // the device width, not innerWidth.
  for (const width of [390, 360, 320]) {
    await page.setViewport({ width, height: 740, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
    // Chessground follows its new size one animation frame after the resize.
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const [wide, culprit] = await page.evaluate((width) => {
      const over = [...document.querySelectorAll('body *')].filter((el) => el.getBoundingClientRect().right > width + 1 && !el.closest('.nav-links'));
      return [document.documentElement.scrollWidth, over.slice(0, 3).map((el) => `${el.tagName}.${el.className}#${el.id}`).join(', ')];
    }, width);
    assert.ok(wide <= width, `no sideways scroll on a ${width} px phone (page is ${wide} px: ${culprit})`);
  }

  assert.deepEqual(errors.filter((e) => !e.includes('favicon')), []);

  // A fresh browser on a phone asks before the first download.
  const phone = await browser.createBrowserContext();
  const fresh = await phone.newPage();
  fresh.setDefaultTimeout(30_000);
  await fresh.setViewport({ width: 390, height: 844, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  await fresh.goto(url(HOLE));
  await fresh.waitForSelector('#ch-engine-action:not([hidden])');
  assert.equal(await fresh.$eval('#ch-engine-action', (b) => b.textContent), 'Download');
  assert.match(await fresh.$eval('#ch-engine-info', (el) => el.textContent), /MB, once/);
  assert.equal(await fresh.$$eval('#bs-sit .ch-spinner', (s) => s.length), 0, 'no spinners while the engine waits');
  await fresh.click('#ch-engine-action');
  await evaluated(fresh);
  await phone.close();

  // A failed download says so, with one button to try again; the sit rows stop spinning.
  const broken = await browser.createBrowserContext();
  const desk = await broken.newPage();
  desk.setDefaultTimeout(30_000);
  await desk.setViewport({ width: 1440, height: 900 });
  let block = true;
  await desk.setRequestInterception(true);
  desk.on('request', (req) => (block && req.url().includes('/bughouse-engine/model-') ? req.abort() : req.continue()));
  await desk.goto(url(HOLE));
  await desk.waitForSelector('#ch-engine-action:not([hidden])', { timeout: 60_000 });
  assert.equal(await desk.$eval('#ch-engine-action', (b) => b.textContent), 'Try again');
  assert.match(await desk.$eval('#ch-engine-info', (el) => el.textContent), /download failed/);
  assert.equal(await desk.$$eval('#bs-sit .ch-spinner', (s) => s.length), 0, 'no endless spinners after a failure');
  await desk.screenshot({ path: path.join(output, 'download-failed.png') });
  block = false;
  await desk.click('#ch-engine-action');
  await evaluated(desk);
  await sitDone(desk);
  await broken.close();
  console.log('bughouse browser: ok');
} finally {
  await browser.close();
  close();
  await fs.rm(chromeTmp, { recursive: true, force: true });
}
