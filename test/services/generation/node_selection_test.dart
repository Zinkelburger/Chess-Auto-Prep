import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/generation/node_selection.dart';
import 'package:chess_auto_prep/utils/eval_constants.dart';

import 'generation_test_helpers.dart';

void main() {
  group('bestSiblingEvalCp', () {
    test('returns kWorstEvalCp when no child has an engine eval', () {
      final parent = makeNode(
          fen: kFenAfterE4E5, san: 'x', ply: 2, isWhiteToMove: true);
      makeNode(
          fen: kFenAfterE4E5Nf3,
          san: 'Nf3',
          ply: 3,
          isWhiteToMove: false,
          parent: parent);
      expect(
        bestSiblingEvalCp(parent.children, playAsWhite: true),
        kWorstEvalCp,
      );
    });

    test('returns highest eval-for-us among evaluated children', () {
      final parent = makeNode(
          fen: kFenAfterE4E5, san: 'x', ply: 2, isWhiteToMove: true);
      // Children are black-to-move nodes: evalForUs(white) = -engineEvalCp.
      makeNode(
          fen: kFenAfterE4E5Nf3,
          san: 'a',
          ply: 3,
          isWhiteToMove: false,
          evalCp: -30, // +30 for us
          parent: parent);
      makeNode(
          fen: kFenAfterE4C5Nf3,
          san: 'b',
          ply: 3,
          isWhiteToMove: false,
          evalCp: -80, // +80 for us
          parent: parent);
      makeNode(
          fen: kFenAfterD4D5C4,
          san: 'c',
          ply: 3,
          isWhiteToMove: false,
          parent: parent); // no eval — ignored
      expect(bestSiblingEvalCp(parent.children, playAsWhite: true), 80);
    });
  });

  group('pickChildByValue', () {
    test('empty children returns null', () {
      expect(
        pickChildByValue(
          const [],
          playAsWhite: true,
          maxEvalLossCp: 50,
          value: (c) => 0.0,
        ),
        isNull,
      );
    });

    test('picks highest value among children within the eval-loss window',
        () {
      final parent = makeNode(
          fen: kFenAfterE4E5, san: 'x', ply: 2, isWhiteToMove: true);
      final good = makeNode(
          fen: kFenAfterE4E5Nf3,
          san: 'good',
          ply: 3,
          isWhiteToMove: false,
          evalCp: -80, // +80 for us — the best sibling
          parent: parent);
      final close = makeNode(
          fen: kFenAfterE4C5Nf3,
          san: 'close',
          ply: 3,
          isWhiteToMove: false,
          evalCp: -50, // +50 for us — within 50cp of best
          parent: parent);
      final far = makeNode(
          fen: kFenAfterD4D5C4,
          san: 'far',
          ply: 3,
          isWhiteToMove: false,
          evalCp: 20, // -20 for us — filtered out
          parent: parent);
      good.expectimaxValue = 0.5;
      close.expectimaxValue = 0.9;
      far.expectimaxValue = 0.99; // would win without the filter

      final pick = pickChildByValue(
        parent.children,
        playAsWhite: true,
        maxEvalLossCp: 50,
        value: (c) => c.expectimaxValue,
      );
      expect(pick, same(close));
    });

    test('falls back to all children when every child is filtered out', () {
      final parent = makeNode(
          fen: kFenAfterE4E5, san: 'x', ply: 2, isWhiteToMove: true);
      // Eligibility excludes everything in the filtered pass.
      final a = makeNode(
          fen: kFenAfterE4E5Nf3,
          san: 'a',
          ply: 3,
          isWhiteToMove: false,
          evalCp: -80,
          parent: parent);
      final b = makeNode(
          fen: kFenAfterE4C5Nf3,
          san: 'b',
          ply: 3,
          isWhiteToMove: false,
          evalCp: -70,
          parent: parent);
      a.cplValue = 10.0;
      b.cplValue = 20.0;

      // eligible always false, and NOT applied to fallback → fallback scans
      // all children (the _pickByOpponentCpl historical shape).
      final pick = pickChildByValue(
        parent.children,
        playAsWhite: true,
        maxEvalLossCp: 50,
        eligible: (c) => false,
        eligibleGuardsFallback: false,
        value: (c) => c.cplValue,
      );
      expect(pick, same(b));
    });

    test('eligibility guard also applies to fallback when requested', () {
      final parent = makeNode(
          fen: kFenAfterE4E5, san: 'x', ply: 2, isWhiteToMove: true);
      final a = makeNode(
          fen: kFenAfterE4E5Nf3,
          san: 'a',
          ply: 3,
          isWhiteToMove: false,
          evalCp: -80,
          parent: parent);
      a.cplValue = 10.0;

      final pick = pickChildByValue(
        parent.children,
        playAsWhite: true,
        maxEvalLossCp: 50,
        eligible: (c) => false,
        // default eligibleGuardsFallback: true
        value: (c) => c.cplValue,
      );
      expect(pick, isNull);
    });

    test('candidate must beat minValue strictly', () {
      final parent = makeNode(
          fen: kFenAfterE4E5, san: 'x', ply: 2, isWhiteToMove: true);
      final a = makeNode(
          fen: kFenAfterE4E5Nf3,
          san: 'a',
          ply: 3,
          isWhiteToMove: false,
          evalCp: -80,
          parent: parent);
      a.cplValue = -1.0; // equals default minValue

      final pick = pickChildByValue(
        parent.children,
        playAsWhite: true,
        maxEvalLossCp: 50,
        value: (c) => c.cplValue,
      );
      expect(pick, isNull);
    });

    test('ties resolve to the first child in order', () {
      final parent = makeNode(
          fen: kFenAfterE4E5, san: 'x', ply: 2, isWhiteToMove: true);
      final first = makeNode(
          fen: kFenAfterE4E5Nf3,
          san: 'first',
          ply: 3,
          isWhiteToMove: false,
          evalCp: -50,
          parent: parent);
      final second = makeNode(
          fen: kFenAfterE4C5Nf3,
          san: 'second',
          ply: 3,
          isWhiteToMove: false,
          evalCp: -50,
          parent: parent);
      first.cplValue = 5.0;
      second.cplValue = 5.0;

      final pick = pickChildByValue(
        parent.children,
        playAsWhite: true,
        maxEvalLossCp: 50,
        value: (c) => c.cplValue,
      );
      expect(pick, same(first));
      expect(pick, isNot(same(second)));
    });
  });
}
