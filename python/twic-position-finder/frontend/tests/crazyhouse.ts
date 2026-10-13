import assert from 'node:assert/strict';
import {
  MAX_IN_HAND, START_FEN, Tree, adjustHand, boardDests, dropSquares, handEdit, handLetters, readFen, sanLine,
} from '../src/crazyhouse/tree';

const ITALIAN = 'r1bqkb1r/pppp1ppp/2n2n2/4p3/4P3/2N2N2/PPPP1PPP/R1BQKB1R[] w KQkq - 4 4';

// Hands far beyond what a game can reach are accepted, as Fairy-Stockfish accepts them.
const loaded = readFen('r1bqkb1r/pppp1ppp/2n2n2/4p3/4P3/2N2N2/PPPP1PPP/R1BQKB1R[QQQqqqnnn] w KQkq - 4 4');
assert.ok(loaded.ok, 'three extra queens a side is a position');
assert.equal(readFen('8/8/8/8/8/8/8/8[] w - - 0 1').ok, false, 'no kings is refused');
assert.equal(readFen('nonsense').ok, false);
assert.match((readFen('4k3/8/8/8/8/8/8/4K3[Kk] w - - 0 1') as { error: string }).error, /king/i);

// + and − on a hand: one at a time, never below zero, capped at the NNUE's 16.
let fen = adjustHand(ITALIAN, 'black', 'pawn', 1)!;
assert.equal(handLetters(fen), 'p');
assert.equal(adjustHand(ITALIAN, 'black', 'pawn', -1), null, 'no pawn to take away');
for (let i = 1; i < MAX_IN_HAND; i++) fen = adjustHand(fen, 'black', 'pawn', 1)!;
assert.equal(handLetters(fen), 'p'.repeat(16));
assert.equal(adjustHand(fen, 'black', 'pawn', 1), null, 'a 17th pawn would not be seen by the net');
// The 64-piece limit (board plus hands).
let full = '4k3/8/8/8/8/8/8/4K3[] w - - 0 1';
for (const role of ['queen', 'rook', 'bishop', 'knight'] as const)
  for (const color of ['white', 'black'] as const)
    for (let i = 0; i < 8 && full; i++) full = adjustHand(full, color, role, 1) ?? full;
assert.equal(readFen(full).ok, true);
assert.equal(handLetters(full).length, 62);
assert.equal(adjustHand(full, 'white', 'pawn', 1), null, '65 pieces is refused');

// Drops and moves with chessground's castling form.
const dropFen = adjustHand(ITALIAN, 'white', 'knight', 1)!;
assert.ok(dropSquares(dropFen, 'knight').includes('d5'));
assert.deepEqual(dropSquares(dropFen, 'pawn'), [], 'nothing to drop');
const castle = new Tree('r3k2r/8/8/8/8/8/8/R3K2R[] w KQkq - 0 1');
assert.ok(boardDests(castle.root.fen).get('e1')!.includes('g1'));
const castled = castle.play(castle.root.id, 'e1g1')!;
assert.equal(castled.san, 'O-O');
assert.equal(castle.play(castle.root.id, 'e1h1'), castled, 'both castling forms are one move');

// A hand edit is carried through later moves; a drop that no longer has its piece is cut.
const tree = new Tree(ITALIAN);
const a = tree.play(tree.root.id, 'd2d4')!;
const b = tree.play(a.id, 'e5d4')!;
assert.ok(tree.adjustHand(b.id, 'white', 'knight', 1));
const drop = tree.play(b.id, 'N@d5')!;
assert.equal(drop.san, 'N@d5');
const reply = tree.play(drop.id, 'f6d5')!;
assert.equal(handEdit(tree.expectedFen(b.id), b.fen), '+N');
assert.equal(handEdit(tree.expectedFen(drop.id), drop.fen), '', 'the move after an edit is not an edit');
assert.equal(handLetters(reply.fen), 'np');

// An earlier edit keeps the later one: Black gets a pawn at the start, White still gets the knight.
assert.ok(tree.adjustHand(tree.root.id, 'black', 'pawn', 1));
assert.equal(tree.get(reply.id), reply, 'the line survives');
assert.equal(handLetters(reply.fen), 'npp');
assert.equal(handEdit(tree.loadedFen, tree.root.fen), '+p');

// Taking the knight away again cuts the drop that needed it.
assert.ok(tree.adjustHand(b.id, 'white', 'knight', -1));
assert.equal(tree.get(drop.id), undefined);
assert.deepEqual(b.children, []);
assert.equal(handEdit(tree.expectedFen(b.id), b.fen), '');

// Navigation helpers, promotion of a variation, deletion.
const t2 = new Tree();
const e4 = t2.play(t2.root.id, 'e2e4')!;
const d4 = t2.play(t2.root.id, 'd2d4')!;
t2.play(d4.id, 'd7d5');
assert.ok(t2.isMainline(e4.id));
t2.promote(d4.id);
assert.equal(t2.root.children[0], d4);
assert.equal(t2.lineEnd(t2.root.id).san, 'd5');
assert.equal(t2.delete(d4.id), t2.root);
assert.deepEqual(t2.root.children, [e4]);

// SAN of engine lines, castling as the engine writes it.
assert.deepEqual(sanLine(START_FEN, ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6', 'e1g1']), ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Nf6', 'O-O']);
assert.deepEqual(sanLine(dropFen, ['N@d5', 'f6d5']), ['N@d5', 'Nxd5']);
assert.deepEqual(sanLine(START_FEN, ['e2e5']), [], 'stops at an illegal move');

// PGN out and back in, variations and drops included.
const game = new Tree();
let n = game.root;
for (const uci of ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6', 'f3g5', 'd7d5', 'e4d5', 'f6d5', 'g5f7', 'e8f7', 'P@e6'])
  n = game.play(n.id, uci)!;
game.play(game.root.children[0].id, 'c7c5');
const pgn = game.pgn();
assert.match(pgn, /\[Variant "Crazyhouse"\]/);
assert.match(pgn, /1\. e4 e5 \( 1\.\.\. c5 \) 2\. Nf3/);
assert.match(pgn, /P@e6/);
const back = Tree.fromPgn(pgn)!;
assert.equal(back.lineEnd(back.root.id).fen, n.fen);
assert.equal(back.root.children[0].children.length, 2);
assert.equal(Tree.fromPgn('[Event "x"]\n\n*'), null, 'no moves');
const fromFen = Tree.fromPgn(`[FEN "${ITALIAN}"]\n\n4. d4 *`)!;
assert.equal(fromFen.root.children[0].san, 'd4');

console.log('crazyhouse tree: ok');
