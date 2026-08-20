// Import several real TWIC issues with the real importer, then report the
// shape of `book` (rows/singletons by ply) and movetext compressibility.
//   BENCH_ARGS="<pgn1> <pgn2> ..." flutter test tools/bench/book_shape_bench.dart
import 'dart:io' as io;

import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/utils/file_text_reader.dart'
    show decodeTextBytes;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('book shape', () {
    final files = io.Platform.environment['BENCH_ARGS']!.split(' ');
    final path = '${io.Directory.systemTemp.path}/bench_shape_${io.pid}.db';
    for (final f in [path, '$path-wal', '$path-shm']) {
      final ff = io.File(f);
      if (ff.existsSync()) ff.deleteSync();
    }
    final total = Stopwatch()..start();
    var n = 0;
    for (final f in files) {
      final sw = Stopwatch()..start();
      final r = importPgnIntoMasterGames(
        MasterGamesImportRequest(
          dbPath: path,
          pgnText: decodeTextBytes(io.File(f).readAsBytesSync()),
          twicIssue: ++n,
        ),
      );
      print(
        '${f.split('/').last}: ${r.gamesImported} games, ${sw.elapsedMilliseconds} ms',
      );
    }
    print('total import ${total.elapsed.inSeconds}s');
    final db = MasterGamesDb.open(path);
    final q = db.raw;
    final games =
        q.select('SELECT COUNT(*) FROM games').first.columnAt(0) as int;
    final rows = q.select('SELECT COUNT(*) FROM book').first.columnAt(0) as int;
    final plies =
        q.select('SELECT SUM(games) FROM book').first.columnAt(0) as int;
    print(
      'games=$games book rows=$rows (from $plies indexed plies, '
      '${(rows / games).toStringAsFixed(0)} rows/game)',
    );
    print('ply  rows  singletons  games>=3  share_of_rows');
    for (final r in q.select(
      '''
      SELECT ply, COUNT(*), SUM(games=1), SUM(games>=3) FROM book GROUP BY ply''',
    )) {
      final c = r.columnAt(1) as int;
      print(
        '${r.columnAt(0).toString().padLeft(3)} ${c.toString().padLeft(7)} '
        '${r.columnAt(2).toString().padLeft(7)} ${r.columnAt(3).toString().padLeft(7)}'
        '  ${(100 * c / rows).toStringAsFixed(1)}%',
      );
    }
    final s1 = q.select('SELECT SUM(games=1) FROM book').first.columnAt(0);
    print(
      'singleton rows total: $s1 (${(100 * (s1 as int) / rows).toStringAsFixed(0)}%)',
    );
    for (final r in q.select(
      "SELECT name, SUM(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC LIMIT 4",
    )) {
      print(
        '  ${r.columnAt(0)}: ${((r.columnAt(1) as int) / 1e6).toStringAsFixed(1)} MB',
      );
    }

    db.close();
    for (final f in [path, '$path-wal', '$path-shm']) {
      final ff = io.File(f);
      if (ff.existsSync()) ff.deleteSync();
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}
