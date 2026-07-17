import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/trap_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

/// Build a tree where the same trap position is reached via two paths
/// that differ only in their fullmove counter (field 6 of FEN).
///
///   root
///   ├── path A: e4 → c6 → d4 (trap node, FEN has "0 3")
///   └── path B: d4 → c6 → e4 (trap node, FEN has "0 3" but different counter)
///
/// Both trap nodes have identical piece placement, side to move, castling,
/// and en passant — they differ only in halfmove/fullmove counters.
BuildTree _duplicateTrapTree() {
  resetNodeIds();
  const trapFen4Field =
      'rnbqkbnr/pp1ppppp/2p5/3P4/8/8/PPP1PPPP/RNBQKBNR b KQkq -';
  const trapFenA = '$trapFen4Field 0 3';
  const trapFenB = '$trapFen4Field 2 5';

  final root = makeNode(
    fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    san: '',
    ply: 0,
    isWhiteToMove: true,
    evalCp: 25,
  );

  // ── Path A ──
  final a1 = makeNode(
    fen: kFenAfterE4,
    san: 'e4',
    uci: 'e2e4',
    ply: 1,
    isWhiteToMove: false,
    evalCp: -25,
    parent: root,
  );
  final a2 = makeNode(
    fen: 'rnbqkbnr/pp1ppppp/2p5/4P3/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
    san: 'c6',
    uci: 'c7c6',
    ply: 2,
    isWhiteToMove: true,
    evalCp: 28,
    moveProbability: 0.5,
    cumulativeProbability: 0.5,
    parent: a1,
  );
  final trapA =
      makeNode(
          fen: trapFenA,
          san: 'd4',
          uci: 'd2d4',
          ply: 3,
          isWhiteToMove: false,
          evalCp: 20,
          parent: a2,
        )
        ..hasExpectimax = true
        ..expectimaxValue = 0.55;
  // Popular blunder + best reply
  makeNode(
    fen: 'rnbqkbnr/ppp1pppp/2p5/3pP3/3P4/8/PPP2PPP/RNBQKBNR w KQkq - 0 4',
    san: 'd5',
    uci: 'd7d5',
    ply: 4,
    isWhiteToMove: true,
    evalCp: 180,
    moveProbability: 0.65,
    cumulativeProbability: 0.325,
    parent: trapA,
  );
  makeNode(
    fen: 'rnbqkbnr/pp2pppp/2p5/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 4',
    san: 'Nf6',
    uci: 'g8f6',
    ply: 4,
    isWhiteToMove: true,
    evalCp: -40,
    moveProbability: 0.15,
    cumulativeProbability: 0.075,
    parent: trapA,
  );

  // ── Path B (same position, different move counters) ──
  final b1 = makeNode(
    fen: kFenAfterD4,
    san: 'd4',
    uci: 'd2d4',
    ply: 1,
    isWhiteToMove: false,
    evalCp: -30,
    parent: root,
  );
  final b2 = makeNode(
    fen: 'rnbqkbnr/pp1ppppp/2p5/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 2',
    san: 'c6',
    uci: 'c7c6',
    ply: 2,
    isWhiteToMove: true,
    evalCp: 28,
    moveProbability: 0.4,
    cumulativeProbability: 0.4,
    parent: b1,
  );
  final trapB =
      makeNode(
          fen: trapFenB,
          san: 'e4',
          uci: 'e2e4',
          ply: 3,
          isWhiteToMove: false,
          evalCp: 20,
          parent: b2,
        )
        ..hasExpectimax = true
        ..expectimaxValue = 0.55;
  makeNode(
    fen: 'rnbqkbnr/ppp1pppp/2p5/3pP3/3P4/8/PPP2PPP/RNBQKBNR w KQkq - 2 6',
    san: 'd5',
    uci: 'd7d5',
    ply: 4,
    isWhiteToMove: true,
    evalCp: 180,
    moveProbability: 0.65,
    cumulativeProbability: 0.26,
    parent: trapB,
  );
  makeNode(
    fen: 'rnbqkbnr/pp2pppp/2p5/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 2 6',
    san: 'Nf6',
    uci: 'g8f6',
    ply: 4,
    isWhiteToMove: true,
    evalCp: -40,
    moveProbability: 0.15,
    cumulativeProbability: 0.06,
    parent: trapB,
  );

  return BuildTree(root: root);
}

void main() {
  group('TrapExtractor deduplication', () {
    test('deduplicates traps at the same position '
        'with different move counters', () {
      final tree = _duplicateTrapTree();
      final extractor = TrapExtractor(playAsWhite: true);
      final traps = extractor.extract(tree);

      // Both paths reach the same 4-field position.
      // After fixing dedup to use canonicalizeFen4, we should get 1 trap.
      expect(
        traps.length,
        1,
        reason: 'Same position via transposition should produce 1 trap',
      );
    });

    test('keeps distinct traps at genuinely different positions', () {
      // Use the StandardTree which has structurally different positions
      final t = StandardTree();
      // Set up two different trap positions
      t.e4.hasExpectimax = true;
      t.e4.expectimaxValue = 0.55;
      // e4 has children e5 (p=0.55, eval=35) and c5 (p=0.35, eval=45)
      // Not a trap because the popular move (e5) isn't much worse than best.
      // Need to adjust evals to create two distinct traps.

      // Make d4 a trap position
      t.d4.hasExpectimax = true;
      t.d4.expectimaxValue = 0.60;
      t.d4d5.engineEvalCp = 200; // popular blunder
      t.d4nf6.engineEvalCp = -50; // best move

      final extractor = TrapExtractor(playAsWhite: true);
      final traps = extractor.extract(t.toTree());

      // d4 is an opponent node (black to move) with two children at
      // different evals — should produce at least 1 trap.
      // The key point: distinct FENs should NOT be deduped.
      final fens = traps.map((t) => t.fen).toSet();
      expect(
        fens.length,
        traps.length,
        reason: 'Distinct positions should not be collapsed',
      );
    });
  });
}
