/// Bounded diagnostic: scripts/ci.sh test tools/bench/study_document_bench.dart
/// Defaults to the synthetic native-test course. STUDY_BENCH_PGN can select a
/// disposable fixture; STUDY_BENCH_UPSTREAM=1 measures the unadapted parser.
/// This diagnostic never writes the source.
import 'dart:io';
import 'dart:isolate';
import '../../test/support/large_study_fixture.dart';
import 'package:dartchess/dartchess.dart' show Chess, PgnGame;
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_text.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:chess_auto_prep/chess_core/moves/move_tree_snapshot.dart';
import 'package:chess_auto_prep/features/documents/models/move_text_layout.dart';
import 'package:chess_auto_prep/features/studies/models/study_document.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/move_tree_pgn.dart';

T measure<T>(String label, T Function() body) {
  final watch = Stopwatch()..start();
  final value = body();
  watch.stop();
  // ignore: avoid_print
  print(
    '$label: ${watch.elapsedMicroseconds} us; RSS ${ProcessInfo.currentRss}',
  );
  return value;
}

void main() {
  test('study decoding stage diagnostics', () async {
    final path = Platform.environment['STUDY_BENCH_PGN'];
    final content = measure(
      'fixture/read',
      () => path == null ? largeStudyPgn() : File(path).readAsStringSync(),
    );
    final games = measure('split', () => splitPgnIntoGames(content));
    measure('headers', () => extractHeaders(games.first));
    final parsed = measure(
      'PGN syntax',
      () => Platform.environment['STUDY_BENCH_UPSTREAM'] == '1'
          ? PgnGame.parsePgn(games.first)
          : parsePgnGame(games.first),
    );
    final roots = measure(
      'position replay',
      () => MoveTreePgnCodec.nodesFromDartchess(
        parsed.moves.children,
        Chess.initial,
      ),
    );
    final tree = MoveTree(roots: roots);
    final adopted = measure('fresh IDs', tree.copyWithFreshIds);
    final projected = measure(
      'projection',
      () => MoveTreeSnapshot.capture(adopted),
    );
    measure('row index', () => MoveTextLayout.capture(projected));
    measure('serialize', tree.toPgnMoveText);
    final watch = Stopwatch()..start();
    final worker = await Isolate.run(
      () => StudyDocument.fromPgn(content, name: 'Benchmark'),
    );
    watch.stop();
    // ignore: avoid_print
    print(
      'worker parse + receive: ${watch.elapsedMicroseconds} us; chapters ${worker.chapters.length}; RSS ${ProcessInfo.currentRss}',
    );
    expect(roots, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
