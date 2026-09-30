/// Build (or extend) a master-games database from PGN files.
///
///     MASTER_IMPORT_ARGS="out.db in.pgn [more.pgn ...]" \
///       scripts/ci.sh test tools/master_import_pgn.dart
///
/// A path with a space in it needs the other form, one path per line (see
/// [importArguments]).
///
/// The importer the app's Databases mode runs on PGN files
/// (`importMasterPgn`), exposed as a script so a hand-collected corpus
/// (Lichess broadcasts, a club's archive) becomes a database in the app's
/// own format: `games` plus the position `book`, queryable with the
/// chess-prep MCP tools (`master_games`, `master_status`, `master_book`, all
/// take a `db` path). Each file is imported once: the same bytes imported
/// again add nothing, so a changed collection is rebuilt by deleting the
/// database first.
///
/// Runs under `flutter test` so it shares the bounded job runner with the
/// other checks.
library;

import 'dart:io' as io;

import 'package:chess_auto_prep/storage/master_games_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'import PGN files into a master-games database',
    timeout: Timeout.none,
    () {
      final args = importArguments(
        io.Platform.environment['MASTER_IMPORT_ARGS'] ?? '',
      );
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
        if (!io.File(path).existsSync()) fail('no such file: $path');
        final (games, without) = importMasterPgn(dbPath, path);
        imported += games;
        skipped += without;
        io.stderr.writeln(
          '$path: $games games imported, $without skipped'
          '${games + without == 0 ? ' (already imported)' : ''}',
        );
      }
      final (games, book) = withMasterGames(
        dbPath,
        (db) => (
          db.select('SELECT count(*) AS n FROM games').first['n'] as int,
          db.select('SELECT count(*) AS n FROM book').first['n'] as int,
        ),
        setAside: (copy) => io.stderr.writeln('set aside unreadable $copy'),
      );
      io.stderr.writeln(
        '$dbPath: $games games, $book book rows '
        '(+$imported this run, $skipped skipped)',
      );
    },
  );
}

/// The paths in [raw]: one per line when it has more than one line, so any
/// path works; otherwise separated by spaces, the short form for paths
/// without any.
List<String> importArguments(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const [];
  return text.contains('\n')
      ? [
          for (final line in text.split(RegExp(r'\r?\n')))
            if (line.trim().isNotEmpty) line.trim(),
        ]
      : text.split(RegExp(r'\s+'));
}
