import 'dart:isolate';

import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/snapshot_export.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
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

SnapshotExportRequest _request({
  bool stopAfterSelection = false,
  List<String> prefix = const [],
}) {
  final tree = StandardTree().toTree();
  return SnapshotExportRequest(
    treeJson: serializeTree(tree),
    configJson: _config.toJson(),
    prefix: prefix,
    repertoireStartFen: _startFen,
    stopAfterSelection: stopAfterSelection,
  );
}

void main() {
  group('runSnapshotExport', () {
    test('produces complete PGN entries from a serialized tree', () {
      final result = runSnapshotExport(_request());

      expect(result.selectedCount, greaterThan(0));
      expect(result.pgnEntries, isNotEmpty);
      expect(result.selectedTreeJson, isNull);
      for (final pgn in result.pgnEntries) {
        expect(pgn, contains('Generated Line'));
        expect(pgn.trim(), isNotEmpty);
      }
    });

    test('stopAfterSelection returns selected tree instead of lines', () {
      final result = runSnapshotExport(_request(stopAfterSelection: true));

      expect(result.pgnEntries, isEmpty);
      expect(result.selectedTreeJson, isNotNull);

      // The returned tree must carry the selection so extraction after
      // verification finds the repertoire moves.
      final tree = deserializeTree(result.selectedTreeJson!);
      final lines = extractSnapshotLines(
        tree: tree,
        config: _config,
        fenMap: (StandardTree().toFenMap()),
        prefix: const [],
        repertoireStartFen: _startFen,
      );
      expect(lines, isNotEmpty);
    });

    test('line prefix is prepended to exported moves', () {
      // The synthetic tree starts at the standard position, so a prefix is
      // artificial here — but the PGN movetext must still lead with it.
      final result = runSnapshotExport(_request(prefix: ['e4', 'e5']));
      expect(result.pgnEntries.first, contains('e4'));
    });

    test('runs in a background isolate', () async {
      final request = _request();
      final result = await Isolate.run(() => runSnapshotExport(request));
      expect(result.pgnEntries, isNotEmpty);
    });
  });
}
