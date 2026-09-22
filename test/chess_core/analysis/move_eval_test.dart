/// The per-move verdict model: winning-chance loss, thresholds and the NAG
/// a verdict contributes to a move.
library;

import 'package:chess_auto_prep/chess_core/analysis/move_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const _e4 = MoveEval(
  ply: 1,
  san: 'e4',
  fenBefore: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
  fenAfter: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
  scoreCp: 30,
  winningChance: 0.05,
  depth: 12,
);

void main() {
  group('winningChanceLoss', () {
    test('is what the mover gave away, never a gain', () {
      expect(
        winningChanceLoss(isWhiteMove: true, before: 0.4, after: 0.1),
        closeTo(0.3, 1e-9),
      );
      expect(
        winningChanceLoss(isWhiteMove: false, before: 0.4, after: 0.1),
        0.0,
        reason: 'White losing ground is a gain for Black',
      );
      expect(
        winningChanceLoss(isWhiteMove: false, before: -0.2, after: 0.5),
        closeTo(0.7, 1e-9),
      );
    });
  });

  group('classifyMove', () {
    test('thresholds are inclusive', () {
      expect(classifyMove(0.30), MoveClassification.blunder);
      expect(classifyMove(0.20), MoveClassification.mistake);
      expect(classifyMove(0.10), MoveClassification.inaccuracy);
      expect(classifyMove(0.099), MoveClassification.normal);
    });

    test('a rare sound move is interesting, a rare bad move is still bad', () {
      expect(classifyMove(0.0, maiaProb: 0.01), MoveClassification.interesting);
      expect(classifyMove(0.0, maiaProb: 0.05), MoveClassification.normal);
      expect(classifyMove(0.25, maiaProb: 0.01), MoveClassification.mistake);
    });
  });

  group('MoveEval', () {
    test('copyWith changes only what it is given', () {
      final marked = _e4.copyWith(
        classification: MoveClassification.inaccuracy,
      );
      expect(marked.classification, MoveClassification.inaccuracy);
      expect(marked.bestLine, isEmpty);
      expect(marked.scoreCp, 30);
      final lined = marked.copyWith(bestLine: const ['d4']);
      expect(lined.bestLine, ['d4']);
      expect(lined.classification, MoveClassification.inaccuracy);
    });

    test('needsBestLine is a classified, non-mating move without a line', () {
      expect(_e4.needsBestLine, isFalse);
      expect(
        _e4.copyWith(classification: MoveClassification.mistake).needsBestLine,
        isTrue,
      );
      expect(
        _e4
            .copyWith(
              classification: MoveClassification.mistake,
              bestLine: const ['d4'],
            )
            .needsBestLine,
        isFalse,
      );
    });

    test('a mating move displays as # with a saturated cp', () {
      const mate = MoveEval(
        ply: 4,
        san: 'Qh4#',
        fenBefore:
            'rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq g3 0 2',
        fenAfter:
            'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3',
        winningChance: -1.0,
        deliversCheckmate: true,
      );
      expect(mate.evalDisplay, '#');
      expect(mate.effectiveCp, isNegative);
      expect(mate.isWhiteMove, isFalse);
      expect(mate.needsBestLine, isFalse);
    });
  });

  group('MoveClassification', () {
    test('annotateNags adds the verdict glyph only when none is present', () {
      expect(MoveClassification.blunder.annotateNags(null), [4]);
      expect(MoveClassification.mistake.annotateNags([14]), [2, 14]);
      expect(MoveClassification.blunder.annotateNags([1]), [
        1,
      ], reason: 'an author glyph is never replaced');
      expect(MoveClassification.normal.annotateNags([14]), [14]);
    });
  });
}
