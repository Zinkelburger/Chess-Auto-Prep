/// Value types of the generation session: the few derived facts they carry.
library;

import 'package:chess_auto_prep/core/generation_session_types.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/line_pruner.dart';
import 'package:flutter_test/flutter_test.dart';

const _line = ExtractedLine(
  movesSan: ['e4', 'e5'],
  movesUci: ['e2e4', 'e7e5'],
  probability: 0.5,
);

void main() {
  group('GenerationRequest', () {
    test('lineKey is the space-joined SAN sequence', () {
      expect(GenerationRequest.lineKey(['e4', 'e5', 'Nf3']), 'e4 e5 Nf3');
      expect(GenerationRequest.lineKey(const []), '');
      // The key distinguishes move orders: that is its whole job.
      expect(
        GenerationRequest.lineKey(['e4', 'e5']),
        isNot(GenerationRequest.lineKey(['e5', 'e4'])),
      );
    });

    test('a fresh build has no tree, no known lines, and exports', () {
      const request = GenerationRequest(
        config: TreeBuildConfig(startFen: 'x', playAsWhite: true),
        repertoireFilePath: '/r.pgn',
        buildRootFen: 'x',
        lineMovePrefix: [],
        repertoireStartFen: 'x',
        onLinesSaved: _ignore,
      );
      expect(request.existingTree, isNull);
      expect(request.existingLineKeys, isEmpty);
      expect(request.expectimaxOnly, isFalse);
    });
  });

  group('ExtractedLines', () {
    test('wasPruned compares against the pre-pruning count', () {
      const kept = ExtractedLines(
        lines: [_line, _line],
        rawCount: 2,
        trapsOnlyNote: '',
      );
      const pruned = ExtractedLines(
        lines: [_line],
        rawCount: 2,
        trapsOnlyNote: '',
      );
      expect(kept.wasPruned, isFalse);
      expect(pruned.wasPruned, isTrue);
      expect(kept.truncated, isFalse);
      expect(kept.folds, isEmpty);
    });

    test('foldedCount sums sidelines over every host', () {
      const fold = FoldedLine(line: _line, divergePly: 1, hostRank: 0);
      const lines = ExtractedLines(
        lines: [_line],
        rawCount: 4,
        trapsOnlyNote: '',
        folds: {
          'e4 e5': [fold, fold],
          'd4 d5': [fold],
        },
      );
      expect(lines.foldedCount, 3);
      expect(
        const ExtractedLines(
          lines: [],
          rawCount: 0,
          trapsOnlyNote: '',
        ).foldedCount,
        0,
      );
    });
  });

  test('ExpectimaxProbeTarget keeps its optional move and threads', () {
    const target = ExpectimaxProbeTarget(
      repertoireFilePath: '/r.pgn',
      repertoireStartFen: 'x',
      movesFromStart: ['e4'],
      plies: 4,
      playAsWhite: true,
    );
    expect(target.moveSan, isNull);
    expect(target.engineThreads, isNull);
  });
}

void _ignore(List<GeneratedLineExport> _) {}
