import assert from 'node:assert/strict';
import { Tree, handLetters, outcomeOf, playLine, positionOf, readMove, useBughouseRules } from '../src/crazyhouse/tree';
import { centipawns, mateMoves, toResult } from '../src/bughouse-single/engine';

useBughouseRules();

// A capture leaves the board for the partner: nothing lands in the capturer's hand.
const tree = new Tree('rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR[] w KQkq d6 0 2');
const capture = tree.play(tree.root.id, 'e4d5')!;
assert.equal(handLetters(capture.fen), '', 'exd5 banks nothing');
assert.ok(tree.adjustHand(capture.id, 'black', 'knight', 1));
const drop = tree.play(capture.id, 'N@f6')!;
assert.equal(handLetters(drop.fen), '', 'a drop spends the piece');
assert.equal(tree.expectedFen(drop.id), drop.fen);

// A check a drop could block is not mate: the side waits for a pawn, or a knight on the back rank.
const waiting = '4R1k1/5ppp/8/8/8/8/5PPP/6K1[] b - - 0 1';
assert.equal(outcomeOf(waiting), 'Waiting');
assert.ok(readMove(positionOf(waiting), 'N@f8'), 'the knight it waits for blocks');
assert.equal(readMove(positionOf(waiting), 'Q@f8'), undefined, 'only the cheapest blocker');
const line = playLine(waiting, ['N@f8', 'e8f8', 'g8f8']);
assert.deepEqual(line.map((m) => m.san), ['N@f8', 'Rxf8+', 'Kxf8']);
assert.equal(handLetters(line[2].fen), '', 'the rook and knight went to the partners');
const pawnBlock = '6k1/8/8/8/8/8/5PPP/r5K1[] w - - 0 1';
assert.equal(outcomeOf(pawnBlock), 'Waiting');
assert.ok(readMove(positionOf(pawnBlock), 'P@b1') === undefined, 'no pawn on the first rank');
assert.ok(readMove(positionOf(pawnBlock), 'N@b1'));
// A knight check, or a contact check, cannot be blocked: mate.
assert.equal(outcomeOf('r4rk1/pp3p1p/2n2BpN/8/8/8/PPP2PPP/R2Q1RK1[] b - - 0 1'), 'Checkmate');
assert.equal(outcomeOf('6k1/6Q1/6K1/8/8/8/8/8[] b - - 0 1'), 'Checkmate');

// Hivemind's scores read as Lichess's.
assert.equal(centipawns(0), 0);
assert.ok(centipawns(0.5) > 290 && centipawns(0.5) < 300);
assert.equal(mateMoves(2), 1);
assert.equal(mateMoves(-3), -2);
const black = toResult('8/8/8/8/8/8/8/k6K[] b - - 0 1', {
  q: 0.5, mate: null, nodes: 100, depth: 3, elapsed_ms: 5000, offset: -0.5, done: true,
  lines: [{ q: 0.5, mate: null, visits: 60, prior: 0.2, pv: ['a1a2'] }, { q: 0.2, mate: 2, visits: 40, prior: 0.1, pv: ['a1b2'] }],
}, true, 30_000);
assert.ok(black.lines[0].cp! < 0, 'good for Black is negative');
assert.equal(black.lines[1].mate, -1, 'Black mates in one');
assert.match(black.info!, /100 positions · 20\/s/);

console.log('bughouse single board rules: ok');
