#!/usr/bin/env node
// Tests for chessable_pgn.js: pure functions in Node, and `extractLine`
// against fixture/variation.html in a headless Chrome when one is installed.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const P = require('./chessable_pgn.js');
const here = __dirname;

let passed = 0;
function test(name, fn) {
  fn();
  passed++;
  console.log(`ok - ${name}`);
}

test('glyphs map to NAGs like the app expects', () => {
  assert.deepEqual(P.glyphToNags('⩱'), { nags: [15], rest: '' });
  assert.deepEqual(P.glyphToNags('!?'), { nags: [5], rest: '' });
  assert.deepEqual(P.glyphToNags('!!'), { nags: [3], rest: '' });
  assert.deepEqual(P.glyphToNags('?±'), { nags: [2, 16], rest: '' });
  assert.deepEqual(P.glyphToNags('+-'), { nags: [18], rest: '' });
  assert.deepEqual(P.glyphToNags(''), { nags: [], rest: '' });
  assert.deepEqual(P.glyphToNags('weird'), { nags: [], rest: 'weird' });
});

test('move labels give number and side', () => {
  assert.deepEqual(P.parseMoveLabel('12.'), { number: 12, isWhite: true });
  assert.deepEqual(P.parseMoveLabel('12...'), { number: 12, isWhite: false });
  assert.equal(P.parseMoveLabel('e4'), null);
  assert.equal(P.parseMoveLabel(null), null);
});

test('comment HTML flattens with double-space paragraphs and no braces', () => {
  const html =
    'Take on <strong hover-drawing="">c6</strong>. <br><br> Next &amp; last {x} ' +
    '<br> line.<p>Para</p>';
  assert.equal(
    P.htmlToText(html),
    'Take on c6.  Next & last {x) line.  Para',
  );
  assert.equal(P.htmlToText(''), '');
  assert.equal(P.htmlToText('&#8722; &#x2212; &nbsp;x'), '− − x');
});

test('headers escape quotes and backslashes', () => {
  assert.equal(P.escapeHeader('a "b" \\ c'), 'a \\"b\\" \\\\ c');
});

test('filenames drop path separators', () => {
  assert.equal(P.safeFilename('1) Ruy Lopez: 5.O-O / #2'), '1) Ruy Lopez- 5.O-O - #2');
  assert.equal(P.safeFilename('', 'course'), 'course');
});

test('start FEN is taken from the page only for mid-game lines', () => {
  const page =
    'x data-fen="rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2" ' +
    'y "8/8/8/8/8/8/8/8 w - - 0 1" ' +
    'z "r1bqkbnr/1pp2ppp/p1p5/4p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 5"';
  assert.equal(P.findStartFen({ number: 1, isWhite: true }, page), null);
  assert.equal(
    P.findStartFen({ number: 5, isWhite: true }, page),
    'r1bqkbnr/1pp2ppp/p1p5/4p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 5',
  );
  assert.equal(P.findStartFen({ number: 9, isWhite: false }, page), null);
});

test('movetext wraps between tokens but never inside a comment', () => {
  const long = '{' + 'word '.repeat(40).trim() + '}';
  const out = P.wrapMovetext(['1.', 'e4', long, 'e5', '*'], 20);
  assert.deepEqual(out.split('\n'), ['1. e4', long, 'e5 *']);
});

test('buildPgn writes the Chessable-export shape', () => {
  const pgn = P.buildPgn(
    { Event: 'Course', Site: 's', White: 'Chapter', Black: 'Line "A"' },
    {
      moves: [
        { number: 1, isWhite: true, san: 'e4', nags: [], comment: 'hi' },
        { number: 1, isWhite: false, san: 'e5', nags: [5], comment: '' },
        { number: 2, isWhite: true, san: 'Nf3', nags: [], comment: '' },
      ],
      leadingComment: 'intro',
      startFen: null,
    },
  );
  assert.equal(
    pgn,
    [
      '[Event "Course"]',
      '[Site "s"]',
      '[Date "????.??.??"]',
      '[Round "?"]',
      '[White "Chapter"]',
      '[Black "Line \\"A\\""]',
      '[Result "*"]',
      '',
      '{intro} 1. e4 {hi} 1... e5 $5 2. Nf3 *',
      '',
    ].join('\n'),
  );
});

test('buildPgn adds SetUp/FEN for a set-up position', () => {
  const fen = 'r1bqkbnr/1pp2ppp/p1p5/4p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 5';
  const pgn = P.buildPgn(
    {},
    {
      moves: [{ number: 5, isWhite: true, san: 'Nxe5', nags: [], comment: '' }],
      leadingComment: '',
      startFen: fen,
    },
  );
  assert.ok(pgn.includes('[SetUp "1"]\n[FEN "' + fen + '"]\n\n5. Nxe5 *'));
  const std = P.buildPgn(
    {},
    { moves: [], leadingComment: '', startFen: P.STANDARD_START },
  );
  assert.ok(!std.includes('[FEN'));
});

// ---- DOM extraction in a real browser ------------------------------------

function findChrome() {
  for (const name of ['google-chrome', 'chromium', 'chromium-browser', 'google-chrome-stable']) {
    try {
      const found = execFileSync('which', [name], { encoding: 'utf8' }).trim();
      if (found) return found;
    } catch (_) {
      // try the next name
    }
  }
  return null;
}

function runInChrome() {
  const chrome = findChrome();
  if (!chrome) {
    console.log('skip - extractLine in headless Chrome (no Chrome/Chromium found)');
    return;
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'chessable-pgn-'));
  const lib = fs.readFileSync(path.join(here, 'chessable_pgn.js'), 'utf8');
  const fixture = fs.readFileSync(path.join(here, 'fixture', 'variation.html'), 'utf8');
  const harness = `
<script>${lib}</script>
<script>
  const P = window.ChessablePgn;
  const line = P.extractLine(document.querySelector('#theOpeningMoves'),
                             document.documentElement.outerHTML);
  const pgn = P.buildPgn({
    Event: 'Ruy Lopez course',
    Site: 'https://www.chessable.com/variation/54352018/',
    White: '1) Ruy Lopez – Exchange Variation',
    Black: 'Exchange Variation 4.Bxc6 dxc6 5.Nxe5',
  }, line);
  const out = document.createElement('pre');
  out.id = 'pgn-out';
  out.textContent = JSON.stringify({ pgn, fen: line.moves[line.moves.length - 1].fen });
  document.body.appendChild(out);
</script>`;
  const page = fixture.replace('</body>', () => harness + '</body>');
  const pagePath = path.join(dir, 'page.html');
  fs.writeFileSync(pagePath, page);
  const dom = execFileSync(
    chrome,
    [
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      `--user-data-dir=${path.join(dir, 'profile')}`,
      '--dump-dom',
      `file://${pagePath}`,
    ],
    { encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'ignore'] },
  );
  const m = /<pre id="pgn-out">([\s\S]*?)<\/pre>/.exec(dom);
  assert.ok(m, 'harness output missing from dumped DOM');
  const decoded = m[1]
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
  const result = JSON.parse(decoded);
  const expected = fs.readFileSync(path.join(here, 'fixture', 'expected.pgn'), 'utf8');
  assert.equal(result.pgn, expected);
  assert.equal(
    result.fen,
    'r1b1kbnr/1pp2ppp/p1p5/4N3/3qP3/8/PPPP1PPP/RNBQK2R w KQkq - 1 6',
  );
  fs.rmSync(dir, { recursive: true, force: true });
  passed++;
  console.log('ok - extractLine + buildPgn on the fixture page in headless Chrome');
}

runInChrome();
console.log(`${passed} tests passed`);
