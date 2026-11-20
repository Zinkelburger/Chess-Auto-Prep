import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { readBoard } from '../src/bughouse/setup';
import { GameStore, LINE_KINDS, gameHash, isContractError, parseGame, parseHash, parseIndex, type Game } from '../src/bughouse-games/games';
import { START, analysisLink, clocksAt, end, evalOn, focusBoard, goTo, lastMoveOn, shown, step } from '../src/bughouse-games/view';
import {
  WAIT_CODES, formatClock, formatEval, lengthLine, mateWords, playersLine, resultLine, seatLabel, seconds, startWords, waitPhrase,
} from '../src/bughouse-games/words';

// ── The served collection follows the contract ─────────────────────────
// Only what the contract guarantees is checked here, so any collection the
// builder writes passes; exact expectations use the small game further down.
const dir = path.resolve(process.cwd(), 'public/bughouse-games');
const warnings: string[] = [];
const index = parseIndex(JSON.parse(readFileSync(path.join(dir, 'index.json'), 'utf8')), (m) => warnings.push(m));
assert.equal(index.skipped, 0, `every index entry follows the contract: ${warnings.join('; ')}`);
assert.ok(index.games.length > 0, 'the collection has games');
assert.ok(index.source.trim(), 'the index says what these games are');
const files = new Set(readdirSync(dir));
const games: Game[] = index.games.map((entry) => {
  assert.ok(files.has(entry.file), `${entry.file} is served`);
  const bytes = readFileSync(path.join(dir, entry.file));
  assert.equal(entry.file, `${entry.id}-${createHash('sha256').update(bytes).digest('hex').slice(0, 10)}.json`, 'the file name carries its content hash');
  const game = parseGame(JSON.parse(bytes.toString('utf8')), (m) => warnings.push(`${entry.id}: ${m}`));
  assert.equal(game.id, entry.id);
  assert.equal(game.moves.length, entry.moves, `${entry.id}: the index counts its half-moves`);
  assert.equal(game.moves.filter((m) => m.note).length, entry.notes, `${entry.id}: the index counts its notes`);
  assert.equal(game.result.winner, entry.winner);
  for (const m of game.moves) {
    // Every FEN is one readBoard reads, reserves included.
    for (const b of ['A', 'B'] as const) assert.ok(Object.keys(readBoard(m.fen[b]).pieces).length >= 2, `${entry.id} move ${m.i}: board ${b} has kings`);
    if (m.book) assert.equal(m.eval, null, `${entry.id} move ${m.i}: a book move has no eval`);
    for (const line of m.lines) {
      // An unknown kind would still show (as "Line"); here it means the builder and the page drifted apart.
      assert.ok(LINE_KINDS.includes(line.kind as never), `${entry.id} move ${m.i}: line kind ${line.kind} has a phrase`);
      for (const c of line.assume) assert.ok(readBoard(line.start).pockets[c === c.toUpperCase() ? 'white' : 'black'].includes(c), `${entry.id} ${line.id}: an assumed piece is in the start reserve`);
    }
    if (m.waited) assert.ok(WAIT_CODES.includes(m.waited.why), `${entry.id} move ${m.i}: wait code ${m.waited.why} has a phrase`);
  }
  return game;
});
assert.deepEqual(warnings, [], 'no line was dropped');

// ── A small game with every kind of thing the contract allows ──────────────
// True positions (replayed with the arena referee); notes, glyphs and lines invented.
const S = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
const A1 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 1';
const A2 = 'rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR[] w KQkq - 0 2';
const A3 = 'rnbqkbnr/ppp1pppp/8/3P4/8/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 2';
const B1 = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR[] b KQkq - 0 1';
const B2 = 'rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR[] w KQkq - 1 2';
const B3 = 'rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR[p] w KQkq - 1 2';
const B4 = 'rnbqkb1r/pppppppp/5n2/8/2PP4/8/PP2PPPP/RNBQKBNR[p] b KQkq - 0 2';
const clocks = (a: number, b: number, c: number, d: number) => ({ Awhite: a, Ablack: b, Bwhite: c, Bblack: d });
const move = (i: number, board: 'A' | 'B', seat: string, num: number, uci: string, san: string, fen: { A: string; B: string }, extra: Record<string, unknown> = {}) => ({
  i, board, seat, num, uci, san, fen, t: null, clocks: null, eval: null, mate: null, book: false, waited: null, glyph: null, note: null, lines: [], ...extra,
});
const SMALL = {
  version: 1, id: 'small', title: 'Small', summary: 'Six moves.', event: 'Test', date: '2026-11-19',
  seats: { Awhite: 'HypeBeast 1.1.1 (500k)', Ablack: 'HypeBeast 1.1.0', Bwhite: 'HypeBeast 1.1.0', Bblack: 'HypeBeast 1.1.1 (pre-release build)' },
  teams: [['Awhite', 'Bblack'], ['Ablack', 'Bwhite']],
  result: { winner: 0, how: 'checkmate', board: 'B', text: 'Black on board B mates; the team of A-White and B-Black wins.' },
  initial_clock: 120, start: { A: S, B: S },
  moves: [
    move(0, 'A', 'Awhite', 1, 'e2e4', 'e4', { A: A1, B: S }, { book: true }),
    move(1, 'B', 'Bwhite', 1, 'd2d4', 'd4', { A: A1, B: B1 }, { book: true }),
    move(2, 'A', 'Ablack', 1, 'd7d5', 'd5', { A: A2, B: B1 }, {
      t: 3.1, clocks: clocks(118, 117, 118, 118), eval: -20, glyph: '!?', note: 'Black strikes in the centre at once.',
      lines: [
        { id: 'm2-a', kind: 'instead', from: 'before', board: 'A', start: A1, assume: '', eval: 15, mate: null, note: null,
          moves: [{ uci: 'e7e5', san: 'e5', fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR[] w KQkq - 0 2' }, { uci: 'g1f3', san: 'Nf3', fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R[] b KQkq - 1 2' }] },
        { id: 'm2-b', kind: 'played', from: 'after', board: 'A', start: A2, assume: '', eval: -10, mate: null, note: 'The pawn is taken back.',
          moves: [{ uci: 'e4d5', san: 'exd5', fen: 'rnbqkbnr/ppp1pppp/8/3P4/8/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 2' }, { uci: 'd8d5', san: 'Qxd5', fen: 'rnb1kbnr/ppp1pppp/8/3q4/8/8/PPPP1PPP/RNBQKBNR[] w KQkq - 0 3' }] },
        { id: 'm2-c', kind: 'threat', from: 'after', board: 'A', start: 'rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 2', assume: '', eval: -60, mate: null, note: null,
          moves: [{ uci: 'd5e4', san: 'dxe4', fen: 'rnbqkbnr/ppp1pppp/8/8/4p3/8/PPPP1PPP/RNBQKBNR[] w KQkq - 0 3' }] },
        { id: 'm2-d', kind: 'arrives', from: 'before', board: 'A', start: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR[n] b KQkq - 0 1', assume: 'n', eval: null, mate: -4, note: null,
          moves: [{ uci: 'N@f3', san: 'N@f3+', fen: 'rnbqkbnr/pppppppp/8/8/4P3/5n2/PPPP1PPP/RNBQKBNR[] w KQkq - 1 2' }, { uci: 'g2f3', san: 'gxf3', fen: 'rnbqkbnr/pppppppp/8/8/4P3/5P2/PPPP1P1P/RNBQKBNR[] b KQkq - 0 2' }] },
      ],
    }),
    move(3, 'B', 'Bblack', 1, 'g8f6', 'Nf6', { A: A2, B: B2 }, { t: 6.0, clocks: clocks(118, 117, 117, 113.8), eval: 30, waited: { seconds: 4.2, why: 'wait_delivery' } }),
    move(4, 'A', 'Awhite', 2, 'e4d5', 'exd5', { A: A3, B: B3 }, { t: 7.5, clocks: clocks(116.5, 117, 117, 113.8), eval: 3820, glyph: '?', note: 'Takes, and the pawn goes to board B.' }),
    move(5, 'B', 'Bwhite', 2, 'c2c4', 'c4', { A: A3, B: B4 }, { t: 9.0, clocks: clocks(116.5, 117, 115.5, 113.8), mate: 3, glyph: '!!', note: 'The last move.' }),
  ],
};
const small = parseGame(SMALL);
const raw = () => JSON.parse(JSON.stringify(SMALL)) as Record<string, unknown> & { moves: Record<string, unknown>[] };

// ── Contract checks: what is refused, what is dropped ──────────────────
const refuses = (mutate: (g: ReturnType<typeof raw>) => void, pattern: RegExp) => {
  const g = raw();
  mutate(g);
  assert.throws(() => parseGame(g), (e: unknown) => isContractError(e) && pattern.test((e as Error).message));
};
refuses((g) => { g.version = 2; }, /game\.version/);
refuses((g) => { g.moves[3].i = 4; }, /moves\[3\]\.i/);
refuses((g) => { g.moves[0].seat = 'Bwhite'; }, /does not sit at board/);
refuses((g) => { (g.moves[1].fen as Record<string, string>).A = 'not a fen'; }, /moves\[1\]\.fen\.A/);
refuses((g) => { g.moves[2].glyph = '!!!'; }, /glyph/);
refuses((g) => { g.teams = [['Awhite', 'Bblack'], ['Awhite', 'Bwhite']]; }, /exactly one team/);
refuses((g) => { delete g.moves[0].book; }, /book/);
refuses((g) => { g.moves[5].clocks = { Awhite: 1, Ablack: 2, Bwhite: 3 }; }, /clocks\.Bblack/);
// A broken line is dropped with a warning; the game still opens.
{
  const g = raw();
  (g.moves[2].lines as Record<string, unknown>[])[0].from = 'sideways';
  const dropped: string[] = [];
  const parsed = parseGame(g, (m) => dropped.push(m));
  assert.equal(parsed.moves[2].lines.length, 3);
  assert.match(dropped[0], /moves\[2\]\.lines\[0\]\.from/);
}
// Nulls the contract allows, and no lines key at all.
{
  const g = raw();
  Object.assign(g.moves[4], { t: null, clocks: null, eval: null, mate: null });
  delete g.moves[4].lines;
  assert.equal(parseGame(g).moves[4].lines.length, 0);
}
// The index: a broken entry is left out and counted, a repeated id too.
{
  const entry = { id: 'small', file: 'small-0123456789.json', title: 'T', summary: 'S', event: 'E', date: 'D', seats: SMALL.seats, winner: 0, how: 'checkmate', moves: 6, notes: 3 };
  const broken = { version: 1, generated: '', source: 's', games: [entry, { ...entry, id: 'x y' }, entry, { ...entry, id: 'ok', file: '../secret.json' }] };
  const said: string[] = [];
  const parsed = parseIndex(broken, (m) => said.push(m));
  assert.equal(parsed.games.length, 1);
  assert.equal(parsed.skipped, 3);
  assert.equal(said.length, 3);
  assert.throws(() => parseIndex({ version: 2, games: [] }), /index\.version/);
}

// ── The store: fetch errors and retries, a file holding another game ────────
{
  const entry = { id: 'small', file: 'small.json', title: '', summary: '', event: '', date: '', seats: small.seats, winner: 0 as const, how: '', moves: 6, notes: 3 };
  let calls = 0;
  const store = new GameStore('/g', async (url) => {
    calls += 1;
    if (url.endsWith('index.json')) return { version: 1, generated: '', source: 's', games: [entry, { ...entry, id: 'other', file: 'small.json' }] };
    if (calls === 2) throw new Error('503 for ' + url);
    return raw();
  }, () => {});
  const idx = await store.loadIndex();
  await assert.rejects(store.get(idx.games[0]), /503/);
  assert.equal((await store.get(idx.games[0])).id, 'small', 'a failed read is retried');
  await assert.rejects(store.get(idx.games[1]), (e: unknown) => isContractError(e), 'a file holding another game is refused');
}

// ── Deep links ─────────────────────────────────────────────────────────
assert.deepEqual(parseHash('#selfplay-g45'), { id: 'selfplay-g45', move: null });
assert.deepEqual(parseHash('#selfplay-g45:57'), { id: 'selfplay-g45', move: 57 });
assert.deepEqual(parseHash('#v7%3A3'), { id: 'v7', move: 3 });
assert.equal(parseHash(''), null);
assert.equal(parseHash('#'), null);
assert.equal(parseHash('#bad id'), null);
assert.equal(parseHash('#id:-1'), null);
assert.equal(parseHash('#id:3:4'), null);
assert.equal(parseHash('#%E0%A4%A'), null, 'a broken escape is no link');
assert.equal(gameHash('g1', -1), '#g1');
assert.equal(gameHash('g1', 12), '#g1:12');
for (const g of index.games) assert.deepEqual(parseHash(gameHash(g.id, 9)), { id: g.id, move: 9 }, `${g.id} round-trips as a link`);

// ── Navigation, on the small game ────────────────────────────────────────
assert.deepEqual(shown(small, START).fen, small.start);
assert.deepEqual(step(small, START, -1), START, 'nothing before the start');
assert.deepEqual(step(small, START, 1), goTo(small, 0));
assert.deepEqual(step(small, end(small), 1), end(small), 'nothing after the end');
assert.equal(goTo(small, 10_000).move, 5, 'a deep link past the end opens the last move');
assert.equal(lastMoveOn(small, 5, 'A'), 4);
assert.equal(lastMoveOn(small, 0, 'B'), -1);
{
  const v = shown(small, goTo(small, 3));
  assert.deepEqual(v.fen, { A: A2, B: B2 });
  assert.deepEqual(v.last, { A: 'd7d5', B: 'g8f6' }, 'each board shows its own last move');
}
// Clocks: the starting time until the first recorded clocks; then the last recorded.
for (const v of Object.values(clocksAt(small, goTo(small, 1)))) assert.equal(v, 120);
assert.deepEqual(clocksAt(small, goTo(small, 3)), SMALL.moves[3].clocks);
// Scores: the last given on each board at or before the cursor; a mate wins.
assert.equal(evalOn(small, goTo(small, 3), 'A')!.eval, -20);
assert.equal(evalOn(small, goTo(small, 5), 'B')!.mate, 3);
assert.equal(evalOn(small, goTo(small, 5), 'A')!.eval, 3820);
// The board in focus is the current move's, A at the start.
assert.equal(focusBoard(small, START), 'A');
assert.equal(focusBoard(small, goTo(small, 3)), small.moves[3].board);
// The analysis link puts the board in focus first.
{
  const link = new URL(analysisLink(small, goTo(small, 3)), 'https://x');
  assert.equal(link.pathname, '/bughouse');
  assert.equal(link.searchParams.get('fen'), B2);
  assert.equal(link.searchParams.get('fen2'), A2);
}

// ── Words ──────────────────────────────────────────────────────────────
assert.equal(seatLabel('Awhite'), 'A-White');
assert.equal(seatLabel('Bblack'), 'B-Black');
assert.equal(formatEval(235, null), '+2.4');
assert.equal(formatEval(-40, null), '−0.4');
assert.equal(formatEval(0, null), '0.0');
assert.equal(formatEval(-4, null), '0.0');
assert.equal(formatEval(null, 3), '#3');
assert.equal(formatEval(500, -2), '#-2', 'a mate wins over the centipawns');
assert.equal(formatEval(null, null), '–');
assert.equal(formatClock(101.5), '1:41');
assert.equal(formatClock(9.44), '0:09.4');
assert.equal(formatClock(-3), '0:00.0');
assert.equal(formatClock(120), '2:00');
assert.equal(seconds(6.5), '6.5 s');
assert.equal(seconds(2.0), '2 s');
assert.equal(waitPhrase({ seconds: 6.5, why: 'partner_mate' }), 'sat 6.5 s while the partner mates, so no new piece reaches the other board');
assert.equal(waitPhrase({ seconds: 2.5, why: 'mated' }), 'sat 2.5 s rather than move into mate, while the partner plays on');
assert.equal(waitPhrase({ seconds: 1, why: 'something_new' }), 'waited 1 s', 'an unknown code falls back to "waited"');
for (const code of WAIT_CODES) assert.ok(waitPhrase({ seconds: 1, why: code }).startsWith('sat 1 s '), code);
assert.equal(resultLine(1, 'checkmate'), 'A-Black and B-White win by checkmate');
assert.equal(resultLine(null, 'repetition'), 'Draw by repetition');
assert.equal(resultLine(0, 'time_forfeit'), 'A-White and B-Black win by time forfeit');
assert.equal(playersLine({ Awhite: 'X', Bblack: 'X', Ablack: 'Y', Bwhite: 'Y' }), 'X against Y');
assert.equal(playersLine({ Awhite: 'X', Bblack: 'Z', Ablack: 'Y', Bwhite: 'Y' }), 'X and Z against Y');
assert.equal(lengthLine(57), '57 moves');
assert.equal(lengthLine(1), '1 move');
assert.equal(startWords(16), 'The first 16 moves were played by people in a rated game and set the position. The engines choose every move after them.');
assert.equal(startWords(1), 'The first 1 move was played by people in a rated game and set the position. The engines choose every move after it.');

assert.equal(formatEval(3820, null, true), '>+20', 'a huge score is capped for display');
assert.equal(formatEval(-13073, null, true), '<−20');
assert.equal(formatEval(1999, null, true), '+20.0');
assert.equal(formatEval(3820, null), '+38.2', 'uncapped for the exact value on hover');
assert.equal(formatEval(3820, 2, true), '#2', 'a mate is never capped away');
assert.equal(mateWords(3), 'White mates in 3');
assert.equal(mateWords(-1), 'Black mates in 1');

const all = games.flatMap((g) => g.moves);
console.log(`games: ${games.length} games, ${all.length} moves, ${all.reduce((n, m) => n + m.lines.length, 0)} lines checked`);
