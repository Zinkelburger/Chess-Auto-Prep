import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/trap_score.dart';

import 'generation_test_helpers.dart';

/// Opponent-to-move parent (black to move) with two replies.
/// Child evals are side-to-move (white) perspective, so the mover's
/// (black's) eval is `-engineEvalCp`.
BuildTreeNode _opponentNode() =>
    makeNode(fen: kFenAfterE4, san: 'e4', ply: 1, isWhiteToMove: false);

void main() {
  group('analyzeTrapScore', () {
    test('null for fewer than two children', () {
      final node = _opponentNode();
      makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 30,
        moveProbability: 1.0,
        parent: node,
      );
      expect(analyzeTrapScore(node), isNull);
    });

    test('null when no child has an engine eval', () {
      final node = _opponentNode();
      makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        moveProbability: 0.6,
        parent: node,
      );
      makeNode(
        fen: kFenAfterE4C5,
        san: 'c5',
        ply: 2,
        isWhiteToMove: true,
        moveProbability: 0.4,
        parent: node,
      );
      expect(analyzeTrapScore(node), isNull);
    });

    test('null when the most popular move has no engine eval', () {
      final node = _opponentNode();
      makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        moveProbability: 0.6, // popular but uneval'd
        parent: node,
      );
      makeNode(
        fen: kFenAfterE4C5,
        san: 'c5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 30,
        moveProbability: 0.4,
        parent: node,
      );
      expect(analyzeTrapScore(node), isNull);
    });

    test('score 0.0 when the popular move is also the best move', () {
      final node = _opponentNode();
      final popularBest = makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 10, // mover eval -10: best for black
        moveProbability: 0.7,
        parent: node,
      );
      makeNode(
        fen: kFenAfterE4C5,
        san: 'c5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 150, // mover eval -150: worse
        moveProbability: 0.3,
        parent: node,
      );

      final analysis = analyzeTrapScore(node)!;
      expect(analysis.popularIsBest, isTrue);
      expect(analysis.trapScore, 0.0);
      expect(analysis.mostPopular, same(popularBest));
      expect(analysis.bestMove, same(popularBest));
    });

    test('trap = (evalDiff / 200) * highestProb below the clamp', () {
      final node = _opponentNode();
      final popular = makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 100, // mover eval -100
        moveProbability: 0.6,
        parent: node,
      );
      final best = makeNode(
        fen: kFenAfterE4C5,
        san: 'c5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 0, // mover eval 0: best
        moveProbability: 0.4,
        parent: node,
      );

      final analysis = analyzeTrapScore(node)!;
      expect(analysis.mostPopular, same(popular));
      expect(analysis.bestMove, same(best));
      expect(analysis.highestProb, closeTo(0.6, 1e-12));
      expect(analysis.bestEvalForMover, 0);
      expect(analysis.popularEvalForMover, -100);
      // evalDiff 100 → 100/200 = 0.5, × 0.6 = 0.3
      expect(analysis.trapScore, closeTo(0.3, 1e-12));
    });

    test('findability discounts a trap with an inhuman refutation', () {
      final node = _opponentNode();
      final popular = makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 100,
        moveProbability: 0.6,
        parent: node,
      );
      makeNode(
        fen: kFenAfterE4C5,
        san: 'c5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 0,
        moveProbability: 0.4,
        parent: node,
      );
      // Our punishing reply under the popular blunder: strong but rarely
      // found (Maia 1% against a 5% bar → factor 0.2).
      final refutation = makeNode(
        fen: kFenAfterE4E5Nf3,
        san: 'Nf3',
        ply: 3,
        isWhiteToMove: false,
        evalCp: -120, // our eval +120
        parent: popular,
      );
      refutation.maiaFrequency = 0.01;

      final analysis = analyzeTrapScore(node, findabilityPRef: 0.05)!;
      expect(analysis.refutation, same(refutation));
      expect(analysis.refutationFindability, closeTo(0.2, 1e-12));
      // Raw trap 0.3 (see test above) × 0.2.
      expect(analysis.trapScore, closeTo(0.06, 1e-12));

      // Without a pRef the raw formula is untouched.
      final raw = analyzeTrapScore(node)!;
      expect(raw.refutationFindability, 1.0);
      expect(raw.trapScore, closeTo(0.3, 1e-12));
    });

    test('findable refutations and missing Maia data are never demoted', () {
      final node = _opponentNode();
      final popular = makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 100,
        moveProbability: 0.6,
        parent: node,
      );
      makeNode(
        fen: kFenAfterE4C5,
        san: 'c5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 0,
        moveProbability: 0.4,
        parent: node,
      );
      final refutation = makeNode(
        fen: kFenAfterE4E5Nf3,
        san: 'Nf3',
        ply: 3,
        isWhiteToMove: false,
        evalCp: -120,
        parent: popular,
      );

      // maiaFrequency defaults to -1 (no Maia data) → factor 1.0.
      var analysis = analyzeTrapScore(node, findabilityPRef: 0.05)!;
      expect(analysis.refutationFindability, 1.0);
      expect(analysis.trapScore, closeTo(0.3, 1e-12));

      // Well above the bar → capped at 1.0, never boosted.
      refutation.maiaFrequency = 0.5;
      analysis = analyzeTrapScore(node, findabilityPRef: 0.05)!;
      expect(analysis.refutationFindability, 1.0);
      expect(analysis.trapScore, closeTo(0.3, 1e-12));
    });

    test('refutation prefers the selected repertoire move', () {
      final node = _opponentNode();
      final popular = makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 100,
        moveProbability: 0.6,
        parent: node,
      );
      makeNode(
        fen: kFenAfterE4C5,
        san: 'c5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 0,
        moveProbability: 0.4,
        parent: node,
      );
      final strongReply = makeNode(
        fen: kFenAfterE4E5Nf3,
        san: 'Nf3',
        ply: 3,
        isWhiteToMove: false,
        evalCp: -120,
        parent: popular,
      );
      strongReply.maiaFrequency = 0.01;
      final repertoireReply = makeNode(
        fen: kFenAfterE4C5Nf3,
        san: 'Bc4',
        ply: 3,
        isWhiteToMove: false,
        evalCp: -80, // weaker eval, but it is the selected move
        parent: popular,
      );
      repertoireReply
        ..isRepertoireMove = true
        ..maiaFrequency = 0.10;

      final analysis = analyzeTrapScore(node, findabilityPRef: 0.05)!;
      expect(analysis.refutation, same(repertoireReply));
      expect(analysis.refutationFindability, 1.0);
    });

    test('trap factor clamps at 1.0 for evalDiff > 200', () {
      final node = _opponentNode();
      makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 500, // mover eval -500 (popular blunder)
        moveProbability: 0.8,
        parent: node,
      );
      makeNode(
        fen: kFenAfterE4C5,
        san: 'c5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 0,
        moveProbability: 0.2,
        parent: node,
      );

      final analysis = analyzeTrapScore(node)!;
      // evalDiff 500 → clamped factor 1.0 × 0.8
      expect(analysis.trapScore, closeTo(0.8, 1e-12));
    });
  });
}
