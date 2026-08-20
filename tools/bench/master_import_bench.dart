// Benchmark: import one TWIC issue N times into a fresh DB and report
// per-phase timings + on-disk size.  Run with:
//   ~/flutter/bin/dart run tools/bench/master_import_bench.dart <pgn> [repeats]
import 'dart:convert';
import 'dart:io' as io;

import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_parser.dart'
    show isResultToken, splitPgnGames, tokenToSan, tokenizeMovetext;
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bench', () {
    final args = io.Platform.environment['BENCH_ARGS']!.split(' ');
    final pgn = io.File(args[0]).readAsStringSync();
    final repeats = args.length > 1 ? int.parse(args[1]) : 3;
    final dbPath = '${io.Directory.systemTemp.path}/bench_master_${io.pid}.db';
    for (final f in [dbPath, '$dbPath-wal', '$dbPath-shm']) {
      final ff = io.File(f);
      if (ff.existsSync()) ff.deleteSync();
    }

    // Phase timings in isolation.
    var sw = Stopwatch()..start();
    final games = splitPgnGames(pgn);
    print('split: ${games.length} games in ${sw.elapsedMilliseconds} ms');

    sw = Stopwatch()..start();
    var plies = 0;
    var bookPlies = 0;
    final sansPerGame = <List<String>>[];
    for (final g in games) {
      final sans = <String>[];
      for (final t in tokenizeMovetext(g.movetext)) {
        if (isResultToken(t)) break;
        final s = tokenToSan(t);
        if (s != null) sans.add(s);
      }
      sansPerGame.add(sans);
      plies += sans.length;
    }
    print(
      'tokenize: $plies plies in ${sw.elapsedMilliseconds} ms '
      '(${(plies / games.length).toStringAsFixed(1)} plies/game)',
    );

    sw = Stopwatch()..start();
    for (final sans in sansPerGame) {
      Position pos = Chess.initial;
      final limit = sans.length < kBookMaxPly ? sans.length : kBookMaxPly;
      for (var i = 0; i < limit; i++) {
        final m = pos.parseSan(sans[i]);
        if (m == null) break;
        pos = pos.play(m);
        pos.fen;
        bookPlies++;
      }
    }
    final replayMs = sw.elapsedMilliseconds;
    print(
      'dartchess replay ≤$kBookMaxPly: $bookPlies plies in $replayMs ms '
      '(${(bookPlies * 1000 / replayMs).round()} plies/s)',
    );

    // Full importer, repeated.
    for (var r = 0; r < repeats; r++) {
      sw = Stopwatch()..start();
      final res = importPgnIntoMasterGames(
        MasterGamesImportRequest(
          dbPath: dbPath,
          pgnText: pgn,
          twicIssue: 1000 + r,
        ),
      );
      final ms = sw.elapsedMilliseconds;
      final db = MasterGamesDb.open(dbPath);
      final book =
          db.raw.select('SELECT COUNT(*) FROM book').first.columnAt(0) as int;
      final pages = db.raw.select('PRAGMA page_count').first.columnAt(0) as int;
      final pageSize =
          db.raw.select('PRAGMA page_size').first.columnAt(0) as int;
      db.close();
      print(
        'import #${r + 1}: ${res.gamesImported} games in $ms ms '
        '(${(res.gamesImported * 1000 / ms).round()} games/s) '
        '| book rows=$book | db=${(pages * pageSize / 1e6).toStringAsFixed(1)} MB',
      );
    }

    // Size breakdown + compression.
    final db = MasterGamesDb.open(dbPath);
    final mt = db.raw.select('SELECT movetext FROM games WHERE twic = 1000');
    var raw = 0, z = 0, zd = 0;
    final dict = utf8.encode(_dict);
    final enc = io.ZLibEncoder(level: 9, raw: true);
    final encD = io.ZLibEncoder(level: 9, raw: true, dictionary: dict);
    for (final r in mt) {
      final s = utf8.encode(r.columnAt(0) as String);
      raw += s.length;
      z += enc.convert(s).length;
      zd += encD.convert(s).length;
    }
    print(
      'movetext: raw ${(raw / 1e6).toStringAsFixed(2)} MB, '
      'zlib ${(z / 1e6).toStringAsFixed(2)} MB, '
      'zlib+dict ${(zd / 1e6).toStringAsFixed(2)} MB '
      '(${(raw / games.length).round()} B/game raw)',
    );
    // sqlite3_analyze-ish: table sizes via dbstat if available
    try {
      final rows = db.raw.select(
        "SELECT name, SUM(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC",
      );
      for (final r in rows) {
        print(
          '  ${r.columnAt(0)}: ${((r.columnAt(1) as int) / 1e6).toStringAsFixed(1)} MB',
        );
      }
    } catch (e) {
      print('dbstat unavailable: $e');
    }
    db.close();
  }, timeout: const Timeout(Duration(minutes: 30)));
}

// A crude preset dictionary: common SAN tokens and move numbers.
const _dict =
    '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 7. Bb3 d6 '
    '8. c3 O-O 9. h3 1. d4 Nf6 2. c4 e6 3. Nc3 Bb4 4. Qc2 d5 5. cxd5 exd5 '
    '1. d4 d5 2. c4 c6 3. Nf3 Nf6 4. Nc3 dxc4 5. a4 Bf5 6. e3 e6 7. Bxc4 Bb4 '
    '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 7. Nb3 Be6 '
    '1. c4 e5 2. Nc3 Nf6 3. Nf3 Nc6 4. g3 d5 5. cxd5 Nxd5 6. Bg2 Nb6 7. O-O Be7 '
    'Kg1 Kg8 Kh1 Kh8 Kf1 Kf8 Ke2 Ke7 Kd2 Kd7 Rd1 Rd8 Re1 Re8 Rc1 Rc8 Rb1 Rb8 '
    'Qd2 Qd7 Qe2 Qe7 Qc2 Qc7 Qb3 Qb6 Bg5 Bg4 Bd3 Bd6 Be2 Be7 Bf4 Bf5 Nd2 Nd7 '
    'Nbd2 Nbd7 Rfd1 Rfd8 Rad1 Rad8 Rfe1 Rfe8 Rae1 Rae8 exd5 exd4 cxd4 cxd5 '
    'Bxf6 Bxf3 Nxe5 Nxd4 Nxd5 Qxd4 Rxd1 Rxe1 Rxc1 Kxf1 Kxg2 h4 h5 h6 g4 g5 g6 '
    'a3 a4 a5 b3 b4 b5 f3 f4 f5 e3 e4 e5 d3 d4 d5 c3 c4 c5 10. 11. 12. 13. 14. '
    '15. 16. 17. 18. 19. 20. 21. 22. 23. 24. 25. 26. 27. 28. 29. 30. 31. 32. '
    '33. 34. 35. 36. 37. 38. 39. 40. 41. 42. 43. 44. 45. 46. 47. 48. 49. 50. ';
