import assert from 'node:assert/strict';
import { Lines } from '../src/bughouse/lines';
import { exportBpgn, parseSession, sessionHash, START_DUAL, type SavedSession } from '../src/bughouse/session';
import { parseReserve } from '../src/bughouse/setup';
import { BrowserEngine } from '../src/bughouse/engine';
import { Attempt, applyMove, inCheck, labLink, startPosition, type Puzzle } from '../src/bughouse-puzzles/puzzle';

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
  id: '1-B-101', fen: 'r4k1r/ppN2ppp/3Pp3/2Np4/1n1P4/4Pq2/PPPKBb1P/R2Q1Bq1[Nrnp] w - - 4 27',
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
console.log('Bughouse state, BPGN export, saved links, reserve validation, worker reuse and puzzles passed.');
