import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { readBoard } from '../src/bughouse/setup';
import { GameStore, LINE_KINDS, gameHash, isContractError, parseGame, parseHash, parseIndex, type Game } from '../src/bughouse-games/games';
import {
  START, analysisLink, clocksAt, end, enterLine, evalOn, focusBoard, goTo, lastMoveOn, leaveLine, lineAt, noteStep, notedMoves,
  shown, step,
} from '../src/bughouse-games/view';
import {
  WAIT_CODES, assumePhrase, formatClock, formatEval, kindTitle, lengthLine, lineContext, lineTokens, moveName, playersLine,
  resultLine, seatLabel, seconds, waitPhrase,
} from '../src/bughouse-games/words';

// The served collection (placeholders until the real games replace them) follows the contract.
const dir = path.resolve(process.cwd(), 'public/bughouse-games');
const warnings: string[] = [];
const index = parseIndex(JSON.parse(readFileSync(path.join(dir, 'index.json'), 'utf8')), (m) => warnings.push(m));
assert.equal(index.skipped, 0, `every index entry follows the contract: ${warnings.join('; ')}`);
assert.ok(index.games.length > 0, 'the collection has games');
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
    if (m.book) assert.equal(m.eval, null, 'a book move has no eval');
    for (const line of m.lines) {
      assert.ok(LINE_KINDS.includes(line.kind as never), `${entry.id} move ${m.i}: a known line kind`);
      for (const c of line.assume) assert.ok(readBoard(line.start).pockets[c === c.toUpperCase() ? 'white' : 'black'].includes(c), 'an assumed piece is in the start reserve');
    }
  }
  return game;
});
assert.deepEqual(warnings, [], 'no line was dropped');
const all = games.flatMap((g) => g.moves);
const kinds = new Set(all.flatMap((m) => m.lines.map((l) => l.kind)));
for (const k of LINE_KINDS) assert.ok(kinds.has(k), `the fixtures have a ${k} line`);
assert.ok(all.some((m) => m.waited), 'the fixtures have a move after a wait');
assert.ok(all.some((m) => m.lines.some((l) => l.assume)), 'the fixtures have a line with assume');
assert.ok(all.some((m) => m.book) && all.some((m) => !m.book), 'book moves and the engines’ own');
assert.ok(index.source.startsWith('PLACEHOLDER'), 'the fixtures say they are placeholders');

// ── Contract checks: what is refused, what is dropped ──────────────────
const game = games[0];
const raw = () => JSON.parse(JSON.stringify(game)) as Record<string, unknown> & { moves: Record<string, unknown>[] };
const refuses = (mutate: (g: ReturnType<typeof raw>) => void, pattern: RegExp) => {
  const g = raw();
  mutate(g);
  assert.throws(() => parseGame(g), (e: unknown) => isContractError(e) && pattern.test((e as Error).message));
};
refuses((g) => { g.version = 2; }, /game\.version/);
refuses((g) => { g.moves[3].i = 4; }, /moves\[3\]\.i/);
refuses((g) => { g.moves[0].seat = g.moves[0].board === 'A' ? 'Bwhite' : 'Awhite'; }, /does not sit at board/);
refuses((g) => { (g.moves[1].fen as Record<string, string>).A = 'not a fen'; }, /moves\[1\]\.fen\.A/);
refuses((g) => { g.moves[2].glyph = '!!!'; }, /glyph/);
refuses((g) => { g.teams = [['Awhite', 'Bblack'], ['Awhite', 'Bwhite']]; }, /exactly one team/);
refuses((g) => { delete g.moves[0].book; }, /book/);
refuses((g) => { g.moves[5].clocks = { Awhite: 1, Ablack: 2, Bwhite: 3 }; }, /clocks\.Bblack/);
// A broken line is dropped with a warning; the game still opens.
{
  const g = raw();
  const at = g.moves.findIndex((m) => (m.lines as unknown[]).length > 0);
  const lines = g.moves[at].lines as Record<string, unknown>[];
  const before = lines.length;
  lines[0].from = 'sideways';
  const dropped: string[] = [];
  const parsed = parseGame(g, (m) => dropped.push(m));
  assert.equal(parsed.moves[at].lines.length, before - 1);
  assert.match(dropped[0], /lines\[0\]\.from/);
}
// Nulls the contract allows: no t, no clocks, no waited, no lines key.
{
  const g = raw();
  Object.assign(g.moves[20], { t: null, clocks: null, eval: null, mate: null });
  delete g.moves[20].lines;
  assert.equal(parseGame(g).moves[20].lines.length, 0);
}
// The index: a broken entry is left out and counted, a repeated id too.
{
  const entries = (JSON.parse(readFileSync(path.join(dir, 'index.json'), 'utf8')) as { games: Record<string, unknown>[] }).games;
  const broken = { version: 1, generated: '', source: 's', games: [entries[0], { ...entries[0], id: 'x y' }, entries[0], { ...entries[0], id: 'ok', file: '../secret.json' }] };
  const said: string[] = [];
  const parsed = parseIndex(broken, (m) => said.push(m));
  assert.equal(parsed.games.length, 1);
  assert.equal(parsed.skipped, 3);
  assert.equal(said.length, 3);
  assert.throws(() => parseIndex({ version: 2, games: [] }), /index\.version/);
}

// ── The store: fetch errors and retries, a file holding another game ────────
{
  let calls = 0;
  const store = new GameStore('/g', async (url) => {
    calls += 1;
    if (url.endsWith('index.json')) return JSON.parse(readFileSync(path.join(dir, 'index.json'), 'utf8'));
    if (calls === 2) throw new Error('503 for ' + url);
    return JSON.parse(readFileSync(path.join(dir, url.slice(3)), 'utf8'));
  }, () => {});
  const idx = await store.loadIndex();
  await assert.rejects(store.get(idx.games[0]), /503/);
  assert.equal((await store.get(idx.games[0])).id, idx.games[0].id, 'a failed read is retried');
  const wrong = { ...idx.games[1], file: idx.games[0].file };
  await assert.rejects(store.get(wrong), (e: unknown) => isContractError(e));
}

// ── Deep links ─────────────────────────────────────────────────────────
assert.deepEqual(parseHash('#placeholder-king-hunt'), { id: 'placeholder-king-hunt', move: null });
assert.deepEqual(parseHash('#placeholder-king-hunt:57'), { id: 'placeholder-king-hunt', move: 57 });
assert.deepEqual(parseHash('#v7%3A3'), { id: 'v7', move: 3 });
assert.equal(parseHash(''), null);
assert.equal(parseHash('#'), null);
assert.equal(parseHash('#bad id'), null);
assert.equal(parseHash('#id:-1'), null);
assert.equal(parseHash('#id:3:4'), null);
assert.equal(parseHash('#%E0%A4%A'), null, 'a broken escape is no link');
assert.equal(gameHash('g1', -1), '#g1');
assert.equal(gameHash('g1', 12), '#g1:12');
assert.deepEqual(parseHash(gameHash('g-1', 9)), { id: 'g-1', move: 9 });

// ── Navigation ─────────────────────────────────────────────────────────
const last = game.moves.length - 1;
assert.deepEqual(shown(game, START).fen, game.start);
assert.deepEqual(step(game, START, -1), START, 'nothing before the start');
let c = step(game, START, 1);
assert.equal(c.move, 0);
assert.deepEqual(shown(game, c).fen, game.moves[0].fen);
assert.equal(shown(game, c).last[game.moves[0].board], game.moves[0].uci);
assert.deepEqual(step(game, end(game), 1), end(game), 'nothing after the end');
assert.equal(goTo(game, 10_000).move, last, 'a deep link past the end opens the last move');
assert.equal(lastMoveOn(game, last, game.moves[last].board), last);
// A move's board and the other board's last move both show.
const mid = game.moves.findIndex((m, i) => i > 4 && game.moves[i - 1].board !== m.board);
const view = shown(game, goTo(game, mid));
const otherBoard = game.moves[mid].board === 'A' ? 'B' : 'A';
assert.equal(view.last[otherBoard], game.moves[mid - 1].uci);
assert.equal(view.variation, null);
// Check comes from the SAN.
const checking = game.moves.find((m) => m.san.endsWith('+'))!;
assert.equal(shown(game, goTo(game, checking.i)).check[checking.board], true);

// Variations: only the line's board moves; the other stays where the line begins.
const withLines = game.moves.find((m) => m.lines.some((l) => l.from === 'before') && m.lines.some((l) => l.from === 'after') )
  ?? game.moves.find((m) => m.lines.length)!;
const at = goTo(game, withLines.i);
for (let index = 0; index < withLines.lines.length; index++) {
  const line = withLines.lines[index];
  const inLine = enterLine(game, at, index, 0);
  const s = shown(game, inLine);
  assert.equal(s.variation, line.board);
  assert.equal(s.fen[line.board], line.moves[0].fen);
  assert.equal(s.last[line.board], line.moves[0].uci);
  const still = line.board === 'A' ? 'B' : 'A';
  const anchor = line.from === 'before' ? withLines.i - 1 : withLines.i;
  assert.equal(s.fen[still], anchor >= 0 ? game.moves[anchor].fen[still] : game.start[still], `${line.id}: the other board stands where the line begins`);
  assert.equal(lineAt(game, inLine), line);
  assert.equal(focusBoard(game, inLine), line.board);
  // Walking the line, then back out of it.
  let walk = inLine;
  for (let k = 1; k < line.moves.length; k++) walk = step(game, walk, 1);
  assert.equal(walk.line!.ply, line.moves.length - 1);
  assert.deepEqual(step(game, walk, 1), walk, 'the line ends where it ends');
  for (let k = 0; k < line.moves.length; k++) walk = step(game, walk, -1);
  assert.deepEqual(walk, at, 'back from the first line move leaves the variation');
  assert.deepEqual(leaveLine(enterLine(game, at, index, 99)), at);
  assert.equal(enterLine(game, at, index, 99).line!.ply, line.moves.length - 1, 'a ply past the end is clamped');
  // Clocks and scores in a variation are those of where it begins.
  assert.deepEqual(clocksAt(game, inLine), clocksAt(game, goTo(game, anchor)));
}
assert.deepEqual(enterLine(game, at, 99, 0), at, 'no such line: stay put');

// Clocks: the start is the initial time; a book move without clocks keeps the last known.
for (const v of Object.values(clocksAt(game, START))) assert.equal(v, game.initial_clock);
const firstTimed = game.moves.findIndex((m) => m.clocks);
assert.deepEqual(clocksAt(game, goTo(game, firstTimed)), game.moves[firstTimed].clocks);
if (firstTimed > 0) for (const v of Object.values(clocksAt(game, goTo(game, firstTimed - 1)))) assert.equal(v, game.initial_clock);

// Scores: the last given on each board at or before the cursor.
assert.equal(evalOn(game, START, 'A'), null);
const scored = game.moves.find((m) => m.eval !== null)!;
assert.equal(evalOn(game, goTo(game, scored.i), scored.board)!.eval, scored.eval);
const nextOther = game.moves.findIndex((m, i) => i > scored.i && m.board !== scored.board);
assert.equal(evalOn(game, goTo(game, nextOther), scored.board)?.move ?? -1, lastScored(game, nextOther, scored.board));
function lastScored(g: Game, upTo: number, b: 'A' | 'B') {
  for (let k = upTo; k >= 0; k--) if (g.moves[k].board === b && (g.moves[k].eval !== null || g.moves[k].mate !== null)) return k;
  return -1;
}

// Note to note.
const noted = notedMoves(game);
assert.ok(noted.length >= 2);
assert.deepEqual(noteStep(game, START, 1), { move: noted[0], line: null });
assert.deepEqual(noteStep(game, goTo(game, noted[0]), 1), { move: noted[1], line: null });
assert.deepEqual(noteStep(game, goTo(game, noted[1]), -1), { move: noted[0], line: null });
assert.equal(noteStep(game, goTo(game, noted[0]), -1), null);
assert.equal(noteStep(game, goTo(game, noted.at(-1)!), 1), null);

// The analysis link puts the board in focus first.
const link = new URL(analysisLink(game, goTo(game, mid)), 'https://x');
assert.equal(link.pathname, '/bughouse');
assert.equal(link.searchParams.get('fen'), game.moves[mid].fen[game.moves[mid].board]);
assert.equal(link.searchParams.get('fen2'), game.moves[mid].fen[otherBoard]);

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
assert.equal(waitPhrase({ seconds: 6.5, why: 'partner_mate' }), 'sat 6.5 s so the partner’s mate stands');
assert.equal(waitPhrase({ seconds: 2.5, why: 'mated' }), 'sat 2.5 s against mate, hoping for a piece to block with');
assert.equal(waitPhrase({ seconds: 1, why: 'something_new' }), 'waited 1 s', 'an unknown code falls back to "waited"');
for (const code of WAIT_CODES) assert.ok(waitPhrase({ seconds: 1, why: code }).startsWith('sat 1 s '), code);
assert.equal(assumePhrase(''), '');
assert.equal(assumePhrase('R'), 'Supposes White’s partner first delivers a rook.');
assert.equal(assumePhrase('nn'), 'Supposes Black’s partner first delivers two knights.');
assert.equal(assumePhrase('QP'), 'Supposes White’s partner first delivers a queen and a pawn.');
assert.equal(assumePhrase('Np'), 'Supposes White first receives a knight and Black a pawn from their partners.');
assert.equal(resultLine(1, 'checkmate'), 'A-Black and B-White win by checkmate');
assert.equal(resultLine(null, 'repetition'), 'Draw by repetition');
assert.equal(resultLine(0, 'time_forfeit'), 'A-White and B-Black win by time forfeit');
assert.equal(playersLine({ Awhite: 'X', Bblack: 'X', Ablack: 'Y', Bwhite: 'Y' }), 'X against Y');
assert.equal(playersLine({ Awhite: 'X', Bblack: 'Z', Ablack: 'Y', Bwhite: 'Y' }), 'X and Z against Y');
assert.equal(lengthLine(57, 13), '57 moves · 13 notes');
assert.equal(lengthLine(1, 0), '1 move · no notes');
{
  const m = game.moves.find((x) => x.lines.length)!;
  const base = m.lines[0];
  assert.equal(kindTitle({ ...base, kind: 'played' }, m), 'Expected continuation');
  assert.equal(kindTitle({ ...base, kind: 'instead' }, m), `Instead of ${m.san}`);
  assert.equal(kindTitle({ ...base, kind: 'threat' }, m), 'Threat');
  assert.equal(kindTitle({ ...base, kind: 'arrives', assume: 'R' }, m), 'If a rook arrives');
  assert.equal(kindTitle({ ...base, kind: 'novel' }, m), 'Line', 'an unknown kind is a plain line');
  const threat = { ...base, kind: 'threat', start: base.start.replace(/ [wb] /, ' b ') };
  assert.match(lineContext(threat, m), /what Black would play with a free move\.$/);
  assert.match(lineContext({ ...base, from: 'before' }, m), new RegExp(`^Before ${moveName(m).replace(/[.+?]/g, '\\$&')}, on board ${base.board}`));
}
assert.deepEqual(
  lineTokens({ id: 'x', kind: 'played', from: 'after', board: 'A', start: '8/8/8/8/8/8/8/K6k[] b - - 0 14', assume: '', eval: null, mate: null, note: null,
    moves: [{ uci: 'h1g1', san: 'Kg1', fen: '' }, { uci: 'a1b1', san: 'Kb1', fen: '' }, { uci: 'g1f1', san: 'Kf1', fen: '' }] }).map((t) => `${t.number}${t.san}`),
  ['14…Kg1', '15.Kb1', 'Kf1'],
);

console.log(`games: ${games.length} games, ${all.length} moves, ${all.reduce((n, m) => n + m.lines.length, 0)} lines checked`);
