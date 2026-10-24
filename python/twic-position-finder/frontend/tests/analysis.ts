import assert from 'node:assert/strict';
import {
  MAX_IN_HAND, START_FEN, Tree, adjustHand, boardDests, dropSquares, handEdit, handLetters, playLine, readFen, sanLine, threatFen,
  outcomeOf, positionOf, readMove,
} from '../src/analysis/tree';
import { liveGlyph, povDiff, verdict, winningChances } from '../src/analysis/judge';

const ITALIAN = 'r1bqkb1r/pppp1ppp/2n2n2/4p3/4P3/2N2N2/PPPP1PPP/R1BQKB1R[] w KQkq - 4 4';

// Hands far beyond what a game can reach are accepted, as Fairy-Stockfish accepts them.
const loaded = readFen('r1bqkb1r/pppp1ppp/2n2n2/4p3/4P3/2N2N2/PPPP1PPP/R1BQKB1R[QQQqqqnnn] w KQkq - 4 4');
assert.ok(loaded.ok, 'three extra queens a side is a position');
assert.equal(readFen('8/8/8/8/8/8/8/8[] w - - 0 1').ok, false, 'no kings is refused');
assert.equal(readFen('nonsense').ok, false);
assert.match((readFen('4k3/8/8/8/8/8/8/4K3[Kk] w - - 0 1') as { error: string }).error, /king/i);

// + and − on a hand: one at a time, never below zero, capped at 16.
let fen = adjustHand(ITALIAN, 'black', 'pawn', 1)!;
assert.equal(handLetters(fen), 'p');
assert.equal(adjustHand(ITALIAN, 'black', 'pawn', -1), null, 'no pawn to take away');
for (let i = 1; i < MAX_IN_HAND; i++) fen = adjustHand(fen, 'black', 'pawn', 1)!;
assert.equal(handLetters(fen), 'p'.repeat(16));
assert.equal(adjustHand(fen, 'black', 'pawn', 1), null, 'no 17th pawn');
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

// Crazyhouse rules, as the engine plays them: a capture goes to the capturer's hand.
const captures = new Tree('rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR[] w KQkq d6 0 2');
const exd5 = captures.play(captures.root.id, 'e4d5')!;
assert.equal(handLetters(exd5.fen), 'P', 'exd5 banks the pawn');
assert.ok(captures.adjustHand(exd5.id, 'black', 'knight', 1));
const nf6 = captures.play(exd5.id, 'N@f6')!;
assert.equal(handLetters(nf6.fen), 'P', 'a drop spends the piece');
assert.equal(captures.expectedFen(nf6.id), nf6.fen);
assert.ok(captures.play(nf6.id, 'P@e4'), 'the captured pawn can be dropped');
assert.ok(!captures.play(nf6.id, 'N@e4'), 'no knight in hand, no knight drop');
// A check a drop could block is mate when the hand is empty, as the engine plays it.
assert.equal(outcomeOf('4R1k1/5ppp/8/8/8/8/5PPP/6K1[] b - - 0 1'), 'Checkmate');
assert.ok(readMove(positionOf('4R1k1/5ppp/8/8/8/8/5PPP/6K1[n] b - - 0 1'), 'N@f8'), 'with a knight in hand it blocks');

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
assert.equal(handLetters(reply.fen), 'np', 'both captures went to Black’s hand');

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
t2.promote(d4.id, true);
assert.equal(t2.root.children[0], d4);
assert.equal(t2.lineEnd(t2.root.id).san, 'd5');
assert.equal(t2.delete(d4.id), t2.root);
assert.deepEqual(t2.root.children, [e4]);

// SAN of engine lines, castling as the engine writes it.
assert.deepEqual(sanLine(START_FEN, ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6', 'e1g1']), ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Nf6', 'O-O']);
assert.deepEqual(sanLine(dropFen, ['N@d5', 'f6d5']), ['N@d5', 'Nxd5']);
assert.deepEqual(sanLine(START_FEN, ['e2e5']), [], 'stops at an illegal move');

// PGN out and back in, variations and drops included.
const game = new Tree('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[P] w KQkq - 0 1');
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

// Promote variation goes up one fork; Make main line goes all the way (lila's promoteAt).
const t3 = new Tree();
const t3e4 = t3.play(t3.root.id, 'e2e4')!;
const t3e5 = t3.play(t3e4.id, 'e7e5')!;
const t3c5 = t3.play(t3e4.id, 'c7c5')!;
const t3d4 = t3.play(t3.root.id, 'd2d4')!;
const t3d5 = t3.play(t3d4.id, 'd7d5')!;
const t3f5 = t3.play(t3d4.id, 'g8f6')!;
assert.equal(t3.isMainline(t3f5.id), false);
t3.promote(t3f5.id, false);
assert.equal(t3d4.children[0], t3f5, 'one step: Nf6 heads its fork');
assert.equal(t3.root.children[0], t3e4, 'the fork above is untouched');
t3.promote(t3f5.id, false);
assert.equal(t3.root.children[0], t3d4, 'the next step reaches the root fork');
assert.ok(t3.isMainline(t3f5.id));
t3.promote(t3c5.id, true);
assert.ok(t3.isMainline(t3c5.id), 'make main line');
assert.equal(t3e4.children[0], t3c5);
void t3e5; void t3d5;

// Force variation: a main-line move shown as a variation; promoting it undoes that.
t3.setForceVariation(t3c5.id, true);
assert.equal(t3.isMainline(t3c5.id), false);
assert.equal(t3.mainChild(t3e4), undefined);
t3.promote(t3c5.id, false);
assert.equal(t3c5.forceVariation, undefined);
assert.ok(t3.isMainline(t3c5.id));

// Copy main line / variation PGN: the path to the move and what follows.
const copyMain = t3.copyLine(t3e4.id, false);
assert.match(copyMain.pgn, /\n1\. e4 c5 \*\n$/, 'the main line, no variations');
assert.ok(copyMain.ids.has(t3c5.id) && !copyMain.ids.has(t3e5.id));
const copyVar = t3.copyLine(t3d4.id, true);
assert.match(copyVar.pgn, /1\. d4 Nf6 \( 1\.\.\. d5 \) \*/, 'a variation keeps its sub-variations');

// Branch navigation, as Lichess's shift+arrows.
assert.equal(t3.previousBranch(t3c5.id), t3e4);
assert.equal(t3.nextBranch(t3.root.id), t3e4, 'stops at the next fork');
assert.equal(t3.nextBranch(t3.root.id, 1), t3d4);
assert.equal(t3.stepLine(t3c5.id, 'next'), t3e5);
assert.equal(t3.stepLine(t3e5.id, 'next'), t3c5, 'wraps around');

// Folding variations.
assert.ok(t3.someCollapsible(false));
t3.setCollapsedAll(true);
assert.ok(t3.root.collapsed && t3e4.collapsed && !t3.someCollapsible(false));
t3.setCollapsedAll(false);
assert.ok(!t3.someCollapsible(true));

// Saved and restored with hand edits, forced variations and the current move.
const saved = new Tree(ITALIAN);
const s1 = saved.play(saved.root.id, 'd2d4')!;
saved.adjustHand(s1.id, 'black', 'knight', 1);
const s2 = saved.play(s1.id, 'N@g4')!;
saved.play(s1.id, 'e5d4');
saved.setForceVariation(s2.id, true);
const back2 = Tree.restore(JSON.parse(JSON.stringify(saved.save(s2.id))))!;
assert.equal(back2.current.fen, s2.fen);
assert.equal(back2.current.san, 'N@g4');
assert.equal(back2.tree.pgn(), saved.pgn());
assert.equal(back2.current.forceVariation, true);
assert.equal(Tree.restore({ loadedFen: 'nonsense', root: { uci: '', children: [] }, current: [] }), null);

// PGN round trip keeps hand edits made between moves.
const edited = Tree.fromPgn(saved.pgn())!;
const e1 = edited.root.children[0];
assert.equal(handEdit(edited.expectedFen(e1.id), e1.fen), '+n');
assert.equal(edited.lineEnd(edited.root.id).fen, saved.lineEnd(saved.root.id).fen);

// Lines with positions, and the threat position.
const line = playLine(START_FEN, ['e2e4', 'e7e5', 'x']);
assert.deepEqual(line.map((m) => m.san), ['e4', 'e5']);
assert.match(line[1].fen, /^rnbqkbnr\/pppp1ppp/);
assert.equal(threatFen('rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR[] b KQkq e3 0 1'), 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR[] w KQkq - 0 1');

// Lichess's winning chances and judgements.
assert.equal(winningChances({ cp: 0 }), 0);
assert.ok(winningChances({ mate: 3 }) > winningChances({ cp: 1000 }) - 0.01);
assert.ok(Math.abs(povDiff('white', { cp: 100 }, { cp: -100 }) + povDiff('black', { cp: 100 }, { cp: -100 })) < 1e-9);
assert.equal(liveGlyph('white', { cp: 30 }, { cp: 10 }), undefined);
assert.equal(liveGlyph('white', { cp: 30 }, { cp: -400 })?.symbol, '??');
assert.equal(liveGlyph('black', { cp: -30 }, { cp: 60 })?.symbol, '?!');
assert.equal(verdict('white', { cp: 50 }, { cp: 45 }), 'goodMove');
assert.equal(verdict('black', { cp: 0 }, { cp: 900 }), 'blunder');

console.log('bughouse analysis tree: ok');
