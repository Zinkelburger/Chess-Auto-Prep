/// Build (or extend) a master-games database from PGN files.
///
///     MASTER_IMPORT_ARGS="out.db in.pgn [more.pgn ...]" \
///       scripts/ci.sh test tools/master_import_pgn.dart
///
/// The same importer the app runs on TWIC issues, exposed as a script so a
/// hand-collected corpus (Lichess broadcasts, a club's archive) becomes a
/// database in the app's own format: `games` plus the position `book`,
/// queryable with the chess-prep MCP tools (`master_games`, `master_status`,
/// `master_book`, all take a `db` path).  Games are added as user-supplied
/// PGN (no TWIC issue), so re-running on the same file adds the games again;
/// delete the database to rebuild it.
///
/// Runs under `flutter test` rather than `dart run` because the PGN parser
/// depends on Flutter foundation (same arrangement as `tools/bench/`).
library;

import 'dart:io' as io;

import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('import PGN files into a master-games database', () {
    final raw = io.Platform.environment['MASTER_IMPORT_ARGS'];
    final args = raw == null || raw.trim().isEmpty
        ? const <String>[]
        : raw.trim().split(RegExp(r'\s+'));
    if (args.length < 2) {
      fail(
        'usage: MASTER_IMPORT_ARGS="out.db in.pgn [more.pgn ...]" '
        'scripts/ci.sh test tools/master_import_pgn.dart',
      );
    }
    final dbPath = args[0];
    var imported = 0;
    var skipped = 0;
    for (final path in args.skip(1)) {
      final file = io.File(path);
      if (!file.existsSync()) fail('no such file: $path');
      final result = importPgnIntoMasterGames(
        MasterGamesImportRequest(
          dbPath: dbPath,
          pgnText: file.readAsStringSync(),
          twicIssue: null,
        ),
      );
      imported += result.gamesImported;
      skipped += result.gamesSkipped;
      io.stderr.writeln(
        '$path: ${result.gamesImported} games imported, '
        '${result.gamesSkipped} without moves skipped',
      );
    }
    final db = MasterGamesDb.open(dbPath);
    try {
      final games = db.raw
          .select('SELECT count(*) FROM games')
          .first
          .columnAt(0);
      final book = db.raw.select('SELECT count(*) FROM book').first.columnAt(0);
      io.stderr.writeln(
        '$dbPath: $games games, $book book rows '
        '(+$imported this run, $skipped skipped)',
      );
    } finally {
      db.close();
    }
  });
}
