/// [MoveAnnotator] on its own, without an extraction walk.
///
/// The point of carving it out of [LineExtractor] was that everything it does
/// is a pure function of a node plus two policy values, so it can be checked
/// directly instead of only through a whole tree traversal.
library;

import 'package:chess_auto_prep/services/generation/export/move_annotation.dart';
import 'package:chess_auto_prep/services/generation/export/move_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../generation_test_helpers.dart';

void main() {
  const annotator = MoveAnnotator(playAsWhite: true, maxEvalLossCp: 50);

  group('leadOverAlternatives', () {
    test('is the gap to the best evaluated sibling', () {
      final t = StandardTree();
      // d4 is the better of the two in this fixture, so it leads e4.
      final lead = annotator.leadOverAlternatives(t.root, t.d4);
      expect(lead, t.d4.evalForUs(true) - t.e4.evalForUs(true));
      expect(lead, greaterThan(0));
    });

    test('an unevaluated move leads by nothing', () {
      final t = StandardTree();
      final blind = makeNode(
        fen: kFenAfterD4,
        san: 'd4',
        ply: 1,
        isWhiteToMove: false,
        parent: t.root,
      );
      expect(blind.hasEngineEval, isFalse);
      expect(annotator.leadOverAlternatives(t.root, blind), 0);
    });

    test('with no evaluated alternative the lead is the whole window', () {
      final t = StandardTree();
      final lone = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        ply: 1,
        isWhiteToMove: false,
        evalCp: -25,
      );
      final parent = makeNode(
        fen: kFenAfterD4,
        san: '',
        ply: 0,
        isWhiteToMove: true,
      );
      parent.children.add(lone);
      expect(annotator.leadOverAlternatives(parent, lone), 50);
      expect(t.root.children, isNotEmpty); // tree untouched
    });

    test('never reports a negative lead', () {
      final t = StandardTree();
      // e4 is the weaker of the two, so its "lead" clamps at zero rather
      // than going negative.
      expect(t.e4.evalForUs(true), lessThan(t.d4.evalForUs(true)));
      expect(annotator.leadOverAlternatives(t.root, t.e4), 0);
    });
  });

  group('annotateOurMove', () {
    test('a move with no evaluated sibling is not called forced', () {
      final lone = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        ply: 1,
        isWhiteToMove: false,
        evalCp: -25,
      );
      final parent = makeNode(
        fen: kFenAfterD4,
        san: '',
        ply: 0,
        isWhiteToMove: true,
      );
      parent.children.add(lone);
      // Even a huge gap: a sole child usually means unexplored, not only.
      expect(annotator.annotateOurMove(lone, 400).isOnlyMove, isFalse);
    });

    test('a big lead over an evaluated sibling is forced', () {
      final t = StandardTree();
      final a = annotator.annotateOurMove(t.d4, 400);
      expect(a.isOnlyMove, isTrue);
      expect(a.onlyMoveLeadCp, 400);
    });

    test('a lead below the window-scaled threshold is not forced', () {
      final t = StandardTree();
      // Threshold is min(100, maxEvalLossCp * 4 ~/ 5) = 40 here.
      expect(annotator.annotateOurMove(t.d4, 39).isOnlyMove, isFalse);
      expect(annotator.annotateOurMove(t.d4, 40).isOnlyMove, isTrue);
    });

    test('the threshold scales with a narrow eval window', () {
      const narrow = MoveAnnotator(playAsWhite: true, maxEvalLossCp: 20);
      final t = StandardTree();
      // min(100, 20 * 4 ~/ 5) = 16.
      expect(narrow.annotateOurMove(t.d4, 16).isOnlyMove, isTrue);
      expect(narrow.annotateOurMove(t.d4, 15).isOnlyMove, isFalse);
    });

    test('evals are reported from the repertoire side', () {
      const asBlack = MoveAnnotator(playAsWhite: false, maxEvalLossCp: 50);
      final t = StandardTree();
      expect(
        annotator.annotateOurMove(t.e4, 0).evalCp,
        -asBlack.annotateOurMove(t.e4, 0).evalCp!,
      );
    });
  });

  group('markTheoryBoundary', () {
    test('an empty list is unchanged', () {
      expect(annotator.markTheoryBoundary(const []), isEmpty);
    });

    test('preserves length and leaves the prefix alone', () {
      const input = [
        MoveAnnotation(evalCp: 10),
        MoveAnnotation(evalCp: 20),
        MoveAnnotation(evalCp: 30),
      ];
      final out = annotator.markTheoryBoundary(input);
      expect(out, hasLength(input.length));
      expect(out.first.evalCp, 10);
    });
  });
}
