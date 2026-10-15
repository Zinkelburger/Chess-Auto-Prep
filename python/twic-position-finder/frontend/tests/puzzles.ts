import assert from 'node:assert/strict';
import { Attempt, analysisLink, applyMove, inCheck, startPosition, type Puzzle } from '../src/bughouse-puzzles/puzzle';
import { DEFAULT_FILTER, PuzzleStore, applyFilter, facetCounts, lengthLabel, normalizeFilter, parseHash, puzzleHash, themeCounts, themeLabel, type IndexEntry, type PuzzleIndex } from '../src/bughouse-puzzles/set';

const START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';

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
  dual: `${START}|r4k1r/ppN2ppp/3Pp3/2Np4/1n1P4/4Pq2/PPPKBb1P/R2Q1Bq1[Nrnp] w - - 4 27`,
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
// "Analyse this board" opens the puzzle's board, solver to move, on the bughouse board.
assert.equal(analysisLink(puzzle), `/bughouse?fen=${encodeURIComponent(puzzle.fen)}`);
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
console.log('Bughouse puzzles and the puzzle set passed.');
