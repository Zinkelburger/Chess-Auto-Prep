import 'dart:isolate';

import 'package:chess_auto_prep/services/generation/course/master_improvements.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
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

    test('improvement notes reach the written lines', () {
      // Probing needs the engine and happens after extraction, so the notes
      // arrive at the writer separately.  A build that finds an improvement
      // and then writes a PGN that never mentions it is the note going
      // nowhere — the overnight harness did exactly that.
      const cited = MasterGame(
        id: 1,
        twicIssue: 1600,
        event: 'Tata Steel',
        site: 'Wijk aan Zee',
        date: '2025.01.20',
        round: '3',
        white: 'Giri,A',
        black: 'Caruana,F',
        result: '1/2-1/2',
        whiteElo: 2740,
        blackElo: 2800,
        whiteFideId: null,
        blackFideId: null,
        eco: 'C65',
        plyCount: 4,
        movetext: '1. e4 e5 2. Nf3 Nc6',
      );
      // Extraction needs a tree that selection has already run over.
      final selected = deserializeTree(
        runSnapshotExport(_request(stopAfterSelection: true)).selectedTreeJson!,
      );

      String write({ImprovementMap improvements = const {}}) =>
          extractSnapshotLines(
            tree: selected,
            config: _config,
            fenMap: StandardTree().toFenMap(),
            prefix: const [],
            repertoireStartFen: _startFen,
            improvements: improvements,
          ).join('\n\n');

      expect(write(), isNot(contains('improves on')));

      const improvement = MasterImprovement(
        ourSan: 'e4',
        masterSan: 'd4',
        gainCp: 35,
        masterGames: 40,
        game: cited,
        continuation: ['d5'],
      );

      // Keyed by the position our move is played from — here, the root.
      final withNotes = write(improvements: {_startFen: improvement});

      expect(withNotes, contains('e4 improves on d4'));
      expect(withNotes, contains(improvement.note));
    });

    test('runs in a background isolate', () async {
      final request = _request();
      final result = await Isolate.run(() => runSnapshotExport(request));
      expect(result.pgnEntries, isNotEmpty);
    });
  });
}
