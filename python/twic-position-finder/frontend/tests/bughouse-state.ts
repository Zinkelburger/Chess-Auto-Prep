import assert from 'node:assert/strict';
import { Lines } from '../src/bughouse/lines';
import { exportBpgn, parseSession, sessionHash, START_DUAL, type SavedSession } from '../src/bughouse/session';
import { parseReserve } from '../src/bughouse/setup';
import { BrowserEngine } from '../src/bughouse/engine';
import { Attempt, applyMove, inCheck, labLink, startPosition, type Puzzle } from '../src/bughouse-puzzles/puzzle';
import { DEFAULT_FILTER, PuzzleStore, applyFilter, facetCounts, lengthLabel, normalizeFilter, parseHash, puzzleHash, themeCounts, themeLabel, type IndexEntry, type PuzzleIndex } from '../src/bughouse-puzzles/set';

const line = new Lines(START_DUAL);
line.play({ board: 'A', colour: 'white', num: 1, uci: 'e2e4', san: 'e4' });
line.play({ board: 'A', colour: 'black', num: 1, uci: 'd7d5', san: 'd5' });
line.play({ board: 'A', colour: 'white', num: 2, uci: 'e4d5', san: 'exd5' });
line.play({ board: 'B', colour: 'white', num: 1, uci: 'e2e4', san: 'e4' });
line.play({ board: 'B', colour: 'black', num: 1, uci: 'P@e6', san: 'P@e6' });
const accepted = line.snapshot();
for (let i = 0; i < 3; i++) {
  line.go('A', 2); line.restore(accepted);
  assert.equal(line.upto.A, 3);
  assert.equal(accepted.upto.A, 3, 'rejected undo must not mutate its rollback point');
}
line.moves[0].san = 'changed';
assert.equal(accepted.moves[0].san, 'e4');
line.restore(accepted);
const bpgn = exportBpgn(line);
assert.match(bpgn, /1A\. e4 1a\. d5 2A\. exd5 1B\. e4 1b\. P@e6/);
line.go('B', 1);
assert.ok(!exportBpgn(line).includes('1b. P@e6'), 'export only the played prefix visible on each board');
assert.equal(line.moves.length, 5, 'export/navigation retain the forward line');
const custom = new Lines('7k/P7/8/8/8/8/8/7K[] w - - 0 1|' + START_DUAL.split('|')[1]);
custom.play({ board: 'A', colour: 'white', num: 1, uci: 'a7a8n', san: 'a8=N' });
assert.match(exportBpgn(custom), /\[SetUp "1"\]/);
assert.match(exportBpgn(custom), /\[FEN "7k\/P7/);
assert.match(exportBpgn(custom), /1A\. a8=N/);
const saved: SavedSession = { version: 1, line: line.snapshot(), settings: { team: 'black', required: 'A', budget: '10000', clock: 'CD', flipped: true } };
assert.deepEqual(parseSession(decodeURIComponent(sessionHash(saved).slice(5))), saved);
for (const mutate of [
  (s: SavedSession) => { s.line.upto.A = 999; },
  (s: SavedSession) => { s.line.moves[0].san = '\n[Event "injected"]'; },
  (s: SavedSession) => { s.line.moves[0].uci = 'bad'; },
  (s: SavedSession) => { s.line.moves[0].num = -1; },
]) {
  const s = structuredClone(saved); mutate(s);
  assert.throws(() => parseSession(JSON.stringify(s)));
}
assert.ok('error' in parseReserve('999999999999999999999999999999N'));
assert.deepEqual(parseReserve('2N Q P'), { pieces: 'NNQP' });

// The client must reuse its worker for position edits, searches and Stop.
class FakeWorker {
  static all: FakeWorker[] = [];
  onmessage?: (event: { data: object }) => void;
  onerror?: () => void;
  messages: { id?: number; action: string }[] = [];
  terminated = false;
  constructor() { FakeWorker.all.push(this); }
  postMessage(message: { id?: number; action: string }) { this.messages.push(message); }
  terminate() { this.terminated = true; }
}
Object.assign(globalThis, { Worker: FakeWorker });
const client = new BrowserEngine(() => {});
const first = client.request('position', {});
const worker = FakeWorker.all[0];
worker.onmessage!({ data: { id: 1, result: 'position' } });
assert.equal(await first, 'position');
let partial = false;
const second = client.request('analyse', {}, () => { partial = true; });
worker.onmessage!({ data: { id: 2, partial: {} } });
assert.ok(partial);
client.cancel();
assert.equal(worker.messages.at(-1)?.action, 'cancel');
assert.equal(worker.terminated, false);
worker.onmessage!({ data: { id: 2, error: 'Analysis cancelled.' } });
await assert.rejects(second, /cancelled/);
const third = client.request('analyse', {});
worker.onmessage!({ data: { id: 3, result: 'reused' } });
assert.equal(await third, 'reused');
assert.equal(FakeWorker.all.length, 1);

// Bughouse Puzzles: reserves are frozen, so a capture never reaches a hand.
const frozen = applyMove(startPosition('rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR[Nn] w KQkq - 0 2'), 'e4d5');
assert.equal(frozen.pockets.white, 'N', 'a capture goes to the partner, not the capturer');
assert.equal(frozen.pieces.d5, 'P');
const dropped = applyMove(frozen, 'N@f6');
assert.equal(dropped.pockets.black, '', 'a drop spends the reserve piece');
assert.equal(dropped.pieces.f6, 'n');
const puzzle: Puzzle = {
  id: '1-B-101', kind: 'mate', prev: null, moves: 2, cp: null, themes: ['mateIn2', 'mate', 'drop', 'dropMate'], difficulty: 2,
  fen: 'r4k1r/ppN2ppp/3Pp3/2Np4/1n1P4/4Pq2/PPPKBb1P/R2Q1Bq1[Nrnp] w - - 4 27',
  dual: `${START_DUAL.split('|')[0]}|r4k1r/ppN2ppp/3Pp3/2Np4/1n1P4/4Pq2/PPPKBb1P/R2Q1Bq1[Nrnp] w - - 4 27`,
  board: 'B', last: 'e8f8', mate: 2, line: ['c5d7', 'f8g8', 'N@e7'], san: ['Nd7+', 'Kg8', 'N@e7#'],
  legal: ['c5d7 c5b7 N@e7', 'N@e7 N@f6'], mates: ['N@e7'], played: 'Nd7+', found: true,
  game: 1, date: '2017.12.31', tc: '120+0', white: 'W', black: 'B', welo: 1853, belo: 1666,
};
const attempt = new Attempt(puzzle);
assert.deepEqual(attempt.last, ['e8', 'f8']);
assert.equal(attempt.play('c5b7'), 'wrong');
assert.ok(attempt.failed, 'a wrong move fails the attempt');
assert.equal(attempt.ply, 0, 'a wrong move is not played');
assert.equal(attempt.play('c5d7'), 'right');
assert.ok(inCheck(attempt.pos), 'Nd7 gives check');
assert.deepEqual(attempt.legal(), [], 'the board is locked while the defender replies');
assert.equal(attempt.reply(), 'f8g8');
assert.deepEqual(attempt.legal(), ['N@e7', 'N@f6']);
assert.equal(attempt.play('n@e7'), 'solved', 'drop letters match in either case');
assert.ok(attempt.done && inCheck(attempt.pos));
assert.equal(attempt.pos.pockets.white, '', 'the mating knight came from the reserve');
const revealed = new Attempt(puzzle);
while (revealed.step()) { /* play the line out */ }
assert.ok(revealed.failed && revealed.done, 'showing the solution counts as a miss');
// The Lab's team is the colour held on board A; partners hold opposite colours.
const lab = JSON.parse(decodeURIComponent(labLink(puzzle, 'white').split('#lab=')[1])) as SavedSession;
assert.equal(lab.settings.team, 'black');
assert.equal(lab.line.root, puzzle.dual);
assert.doesNotThrow(() => parseSession(JSON.stringify(lab)), 'Bughouse Lab accepts the puzzle link');
assert.equal(new Attempt(puzzle).intro(), null, 'no prev, no intro position');

// A mate puzzle with prev: the intro shows the board before the opponent's last move, only until play starts.
const withPrev: Puzzle = { ...puzzle, prev: 'r3k2r/ppN2ppp/3Pp3/2Np4/1n1P4/4Pq2/PPPKBb1P/R2Q1Bq1[Nrnp] b - - 3 26' };
const introAttempt = new Attempt(withPrev);
const intro = introAttempt.intro()!;
assert.equal(intro.pieces.e8, 'k', 'the king is still on e8 before Kf8 animates in');
assert.equal(intro.turn, 'black');
assert.equal(introAttempt.pos.pieces.f8, 'k');
introAttempt.play('c5d7');
assert.equal(introAttempt.intro(), null, 'once a move is played the intro is over');

// An advantage puzzle accepts only the line, including the last move; mates is empty.
const tactic: Puzzle = {
  ...puzzle, id: '2-A-40', kind: 'advantage', mate: 0, moves: 2, cp: 420, themes: ['fork', 'hangingPiece'], difficulty: 1,
  mates: [], line: ['c5d7', 'f8g8', 'N@e7'], legal: ['c5d7 c5b7 N@e7', 'N@e7 N@f6'],
};
const tacticAttempt = new Attempt(tactic);
assert.deepEqual(tacticAttempt.accepted(), ['c5d7']);
assert.equal(tacticAttempt.play('c5d7'), 'right');
assert.equal(tacticAttempt.reply(), 'f8g8');
assert.deepEqual(tacticAttempt.accepted(), ['N@e7'], 'the final move of a tactic is the line, not any mate');
assert.equal(tacticAttempt.play('N@f6'), 'wrong');
assert.equal(tacticAttempt.play('N@e7'), 'solved');
assert.ok(tacticAttempt.failed);
// A mate puzzle whose last line move is missing from `mates` still accepts the line.
const lineOnly = new Attempt({ ...puzzle, mates: ['N@f6'] });
lineOnly.play('c5d7'); lineOnly.reply();
assert.deepEqual(lineOnly.accepted(), ['N@e7', 'N@f6']);

// The index: filtering, facet counts, labels and the deep link.
const entry = (id: string, kind: 'mate' | 'advantage', moves: number, difficulty: 1 | 2 | 3, themes: string[], found: boolean): IndexEntry =>
  ({ id, kind, mate: kind === 'mate' ? moves : 0, moves, themes, difficulty, side: 'w', board: 'A', found, shard: 0 });
const entries = [
  entry('m1', 'mate', 1, 1, ['mateIn1', 'mate', 'dropMate'], true),
  entry('m2', 'mate', 2, 2, ['mateIn2', 'mate', 'drop'], false),
  entry('m4', 'mate', 4, 3, ['mateIn4', 'mate'], false),
  entry('t2', 'advantage', 2, 2, ['fork', 'hangingPiece'], false),
  entry('t5', 'advantage', 5, 3, ['fork'], true),
];
assert.deepEqual(applyFilter(entries, DEFAULT_FILTER).map((e) => e.id), ['m1', 'm2', 'm4', 't2', 't5']);
assert.deepEqual(applyFilter(entries, { ...DEFAULT_FILTER, kind: 'advantage' }).map((e) => e.id), ['t2', 't5']);
assert.deepEqual(applyFilter(entries, { ...DEFAULT_FILTER, length: '4' }).map((e) => e.id), ['m4', 't5'], "'4' means four or more solver moves");
assert.deepEqual(applyFilter(entries, { ...DEFAULT_FILTER, length: '2', difficulty: 2 }).map((e) => e.id), ['m2', 't2']);
assert.deepEqual(applyFilter(entries, { ...DEFAULT_FILTER, theme: 'fork', missed: true }).map((e) => e.id), ['t2']);
assert.deepEqual([...facetCounts(entries, { ...DEFAULT_FILTER, kind: 'mate' }, 'difficulty', ['all', 1, 2, 3]).values()], [3, 1, 1, 1]);
assert.deepEqual(themeCounts(entries, { ...DEFAULT_FILTER, kind: 'advantage', theme: 'hangingPiece' }), [['fork', 2], ['hangingPiece', 1]], 'theme counts ignore the theme facet itself');
assert.equal(lengthLabel('4', 'mate'), 'Mate in 4+');
assert.equal(lengthLabel('1', 'all'), '1 move');
assert.equal(lengthLabel('3', 'advantage'), '3 moves');
assert.equal(themeLabel('mateIn3'), 'Mate in 3');
assert.equal(themeLabel('backRankMate'), 'Back-rank mate');
assert.equal(themeLabel('dropMate'), 'Drop mate');
assert.equal(themeLabel('hangingPiece'), 'Hanging piece');
assert.equal(themeLabel('attackingF2F7'), 'Attacking f2 f7');
assert.deepEqual(normalizeFilter({ kind: 'advantage', length: '9', difficulty: 3, theme: 'fork', missed: 'yes' }), { kind: 'advantage', length: 'all', difficulty: 3, theme: 'fork', missed: false });
assert.deepEqual(normalizeFilter('all'), DEFAULT_FILTER);
assert.equal(parseHash('#3675501-B-113'), '3675501-B-113');
assert.equal(parseHash(''), null);
assert.equal(parseHash('#lab=%7B%22x%22%7D'), null, 'other hashes are not puzzle ids');
assert.equal(parseHash(puzzleHash('1-B-101')), '1-B-101');

// The store loads the index once and each shard once, even when asked twice at the same time.
const fetched: string[] = [];
const index: PuzzleIndex = { version: 2, source: 'test', generated: '2026-10-09', count: 2, shards: ['s00-aaaaaaaaaa.json', 's01-bbbbbbbbbb.json'],
  puzzles: [{ ...entry(puzzle.id, 'mate', 2, 2, puzzle.themes, true), shard: 0 }, { ...entry(tactic.id, 'advantage', 2, 1, tactic.themes, false), shard: 1 }] };
const store = new PuzzleStore('/bughouse-puzzles', async (url) => {
  fetched.push(url);
  if (url.endsWith('index.json')) return index;
  if (url.endsWith(index.shards[0])) return { puzzles: [puzzle] };
  if (url.endsWith(index.shards[1])) throw new Error('503 for ' + url);
  throw new Error('404 for ' + url);
});
await store.loadIndex();
store.prefetch(index.puzzles[0]);
const [a1, a2] = await Promise.all([store.get(index.puzzles[0]), store.get(index.puzzles[0])]);
assert.equal(a1, a2);
assert.deepEqual(fetched, ['/bughouse-puzzles/index.json', '/bughouse-puzzles/s00-aaaaaaaaaa.json']);
await assert.rejects(store.get(index.puzzles[1]), /503/);
await assert.rejects(store.get(index.puzzles[1]), /503/, 'a failed shard is fetched again, not cached');
assert.equal(fetched.filter((u) => u.endsWith(index.shards[1])).length, 2);
console.log('Bughouse state, BPGN export, saved links, reserve validation, worker reuse, puzzles and the puzzle set passed.');
