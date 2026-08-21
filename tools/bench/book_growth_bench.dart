// Simulate the book table growing over many TWIC issues using one real
// issue: positions at ply > 6 get an issue-specific salt so "deep" positions
// are unique per issue (as they are in reality), while the opening positions
// keep aggregating.  Reports per-issue upsert time as the table grows.
//   BENCH_ARGS="<pgn> <issues> <mode>" flutter test tools/bench/book_growth_bench.dart
// mode: default | tuned
import 'dart:io' as io;

import 'package:chess_auto_prep/services/generation/pgn_freq_parser.dart'
    show isResultToken, splitPgnGames, tokenToSan, tokenizeMovetext;
import 'package:chess_auto_prep/services/master_games/position_key.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('book growth', () {
    final args = io.Platform.environment['BENCH_ARGS']!.split(' ');
    final pgn = io.File(args[0]).readAsStringSync();
    final issues = int.parse(args[1]);
    final mode = args.length > 2 ? args[2] : 'default';
    final path = '${io.Directory.systemTemp.path}/bench_book_${io.pid}.db';

    // Pre-replay once: list of (key, uci, ply) per game.
    final games = splitPgnGames(pgn);
    final replayed = <List<(int, String, int)>>[];
    for (final g in games) {
      final sans = <String>[];
      for (final t in tokenizeMovetext(g.movetext)) {
        if (isResultToken(t)) break;
        final s = tokenToSan(t);
        if (s != null) sans.add(s);
      }
      Position pos = Chess.initial;
      final out = <(int, String, int)>[];
      final limit = sans.length < 30 ? sans.length : 30;
      for (var i = 0; i < limit; i++) {
        final m = pos.parseSan(sans[i]);
        if (m == null) break;
        out.add((positionKey(pos.fen), m.uci, i));
        pos = pos.play(m);
      }
      replayed.add(out);
    }

    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA temp_store = MEMORY');
    if (mode == 'tuned') {
      db.execute('PRAGMA cache_size = -524288'); // 512 MB
      db.execute('PRAGMA synchronous = OFF');
    }
    db.execute('''
      CREATE TABLE book(
        pos INTEGER NOT NULL, move TEXT NOT NULL, ply INTEGER NOT NULL,
        games INTEGER NOT NULL, white_wins INTEGER NOT NULL,
        draws INTEGER NOT NULL, black_wins INTEGER NOT NULL,
        elo_sum INTEGER NOT NULL, elo_n INTEGER NOT NULL,
        max_elo INTEGER NOT NULL, last_year INTEGER NOT NULL,
        top_game INTEGER NOT NULL, recent_game INTEGER NOT NULL,
        PRIMARY KEY(pos, move)) WITHOUT ROWID;
    ''');
    final up = db.prepare('''
      INSERT INTO book(pos, move, ply, games, white_wins, draws, black_wins,
                       elo_sum, elo_n, max_elo, last_year, top_game, recent_game)
      VALUES(?,?,?,1,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(pos, move) DO UPDATE SET
        games = games + 1, white_wins = white_wins + excluded.white_wins,
        draws = draws + excluded.draws, black_wins = black_wins + excluded.black_wins,
        elo_sum = elo_sum + excluded.elo_sum, elo_n = elo_n + excluded.elo_n,
        top_game = CASE WHEN excluded.max_elo > max_elo THEN excluded.top_game ELSE top_game END,
        max_elo = MAX(max_elo, excluded.max_elo),
        recent_game = CASE WHEN excluded.last_year >= last_year THEN excluded.recent_game ELSE recent_game END,
        last_year = MAX(last_year, excluded.last_year), ply = MIN(ply, excluded.ply)
    ''');

    final batch = mode == 'tuned' ? 10 : 1;
    final total = Stopwatch()..start();
    for (var issue = 0; issue < issues; issue++) {
      final sw = Stopwatch()..start();
      if (issue % batch == 0) db.execute('BEGIN');
      // Salt: deep positions unique per issue.  FNV-mix the issue number in.
      final salt = (issue + 1) * 1099511628211;
      var gid = issue * 10000;
      for (final g in replayed) {
        gid++;
        for (final (key, uci, ply) in g) {
          final k = ply > 6 ? key ^ salt : key;
          up.execute([k, uci, ply, 1, 0, 0, 5000, 2, 2600, 2025, gid, gid]);
        }
      }
      if (issue % batch == batch - 1 || issue == issues - 1) {
        db.execute('COMMIT');
      }
      if (issue % 5 == 4 || issue == issues - 1) {
        final rows = db.select('SELECT COUNT(*) FROM book').first.columnAt(0);
        final mb =
            (db.select('PRAGMA page_count').first.columnAt(0) as int) *
            4096 /
            1e6;
        final wal = io.File('$path-wal');
        final walMb = wal.existsSync() ? wal.lengthSync() / 1e6 : 0;
        print(
          'issue ${issue + 1}: ${sw.elapsedMilliseconds} ms | rows=$rows '
          '| db=${mb.toStringAsFixed(0)} MB | wal=${walMb.toStringAsFixed(0)} MB '
          '| total ${total.elapsed.inSeconds}s',
        );
      }
    }
    up.dispose();
    db.close();
    for (final f in [path, '$path-wal', '$path-shm']) {
      final ff = io.File(f);
      if (ff.existsSync()) ff.deleteSync();
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}
