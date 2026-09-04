/// Choosing a repertoire's size after the build rather than before it.
///
/// The contract the Generate tab's size control leans on: ranking a finished
/// tree is pure and repeatable, a cut names exactly which lines it drops by
/// the same identity the export wrote them under, and the drops come off the
/// end of the ranking — the lines that only answer a rarer try than one
/// already covered.
library;

import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/repertoire_slice.dart';
import 'package:chess_auto_prep/services/generation/tree_ease.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

const _config = TreeBuildConfig(
  startFen: _startFen,
  playAsWhite: true,
  selectionMode: SelectionMode.expectimax,
  minProbability: 0.01,
  minEvalCp: -9999,
  maxEvalCp: 9999,
);

/// A tree taken through the real Phase 2, so the repertoire-move flags the
/// extractor reads are the ones a build would have written.
RepertoireSlicer _slicerForStandardTree() {
  final helper = StandardTree();
  final tree = helper.toTree();
  final fenMap = helper.toFenMap();
  calculateTreeEase(tree);
  final eca = ExpectimaxCalculator(config: _config, fenMap: fenMap);
  eca.calculate(tree);
  RepertoireSelector(
    config: _config,
    ecaCalc: eca,
    fenMap: fenMap,
  ).select(tree);
  return RepertoireSlicer.forTree(tree, config: _config, fenMap: fenMap);
}

void main() {
  group('RepertoireSlicer', () {
    test('ranks every line that teaches something', () {
      final slicer = _slicerForStandardTree();
      expect(slicer.maxLines, greaterThan(0));
    });

    test('coverage grows with the cut and never exceeds 1', () {
      final slicer = _slicerForStandardTree();
      var previous = -1.0;
      for (var keep = 1; keep <= slicer.maxLines; keep++) {
        final coverage = slicer.coverageAt(keep);
        expect(coverage, greaterThanOrEqualTo(previous));
        expect(coverage, lessThanOrEqualTo(1.0));
        previous = coverage;
      }
    });

    test('the full cut drops nothing', () {
      final slicer = _slicerForStandardTree();
      final plan = slicer.plan(slicer.maxLines);
      expect(plan.droppedKeys, isEmpty);
      expect(plan.keptKeys, hasLength(slicer.maxLines));
    });

    test('kept and dropped keys partition the ranking', () {
      final slicer = _slicerForStandardTree();
      if (slicer.maxLines < 2) return;
      final plan = slicer.plan(1);
      expect(
        plan.keptKeys.intersection(plan.droppedKeys),
        isEmpty,
        reason: 'a line cannot be both kept and dropped',
      );
      expect(
        plan.keptKeys.length + plan.droppedKeys.length,
        slicer.maxLines,
        reason: 'every ranked line is accounted for',
      );
    });

    test('a smaller cut drops a superset of a larger one', () {
      final slicer = _slicerForStandardTree();
      if (slicer.maxLines < 3) return;
      final wide = slicer.plan(slicer.maxLines - 1);
      final narrow = slicer.plan(1);
      expect(
        narrow.droppedKeys.containsAll(wide.droppedKeys),
        isTrue,
        reason: 'cuts come off the end of one ranking, not a fresh order',
      );
    });

    test('never cuts to nothing', () {
      final slicer = _slicerForStandardTree();
      expect(slicer.plan(0).keptKeys, isNotEmpty);
      expect(slicer.plan(-5).keptKeys, isNotEmpty);
    });

    test('ranking the same tree twice gives the same cut', () {
      final a = _slicerForStandardTree().plan(1);
      final b = _slicerForStandardTree().plan(1);
      expect(a.keptKeys, b.keptKeys);
      expect(a.droppedKeys, b.droppedKeys);
    });

    test('a cut never offers to remove a line it does not own', () {
      final slicer = _slicerForStandardTree();
      if (slicer.maxLines < 2) return;
      final plan = slicer.plan(1);
      final dropped = plan.droppedKeys.first.split(' ');

      // A line the build wrote and this cut drops is counted...
      expect(plan.removalsFrom([dropped]), 1);

      // ...a line the user wrote by hand is not, however it is mixed in.
      const handWritten = ['e4', 'e6', 'd4', 'd5', 'Nc3', 'Bb4'];
      expect(plan.removalsFrom([handWritten]), 0);
      expect(plan.removalsFrom([dropped, handWritten]), 1);

      // Nor is a line this cut keeps.
      final keptMoves = plan.keptKeys.first.split(' ');
      expect(plan.removalsFrom([keptMoves]), 0);
    });

    test('the full cut removes nothing from anything', () {
      final slicer = _slicerForStandardTree();
      final plan = slicer.plan(slicer.maxLines);
      expect(
        plan.removalsFrom([for (final k in plan.keptKeys) k.split(' ')]),
        0,
      );
    });

    test('a line key is its SAN moves joined by spaces', () {
      // The export identifies a written line the same way
      // (GenerationRequest.lineKey), which is what lets a cut match the
      // lines already in the file instead of guessing.
      expect(RepertoireSlicer.lineKey(const ['e4', 'e5', 'Nf3']), 'e4 e5 Nf3');
    });
  });
}
