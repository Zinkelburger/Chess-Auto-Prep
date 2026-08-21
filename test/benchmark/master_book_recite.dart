/// Backfill classical over-the-board citations into an existing master-games
/// database.
///
/// A database imported before schema v3 has `book.top_classical_game` empty,
/// so every citation falls back to `top_game` — the highest-rated game, which
/// in a TWIC corpus is an online blitz game more often than not.  This walks
/// the classical games already stored and records them.  Nothing is
/// downloaded; the pass is idempotent and safe to interrupt.
///
/// Named without a `_test` suffix so a bare `flutter test` never runs it.
///
///   flutter test test/benchmark/master_book_recite.dart \
///     --dart-define=DB=…/master_games.db
library;

import 'dart:io';

import 'package:chess_auto_prep/services/master_games/master_book_rebuild.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:flutter_test/flutter_test.dart';

const _db = String.fromEnvironment('DB');

void _say(String s) {
  stdout.writeln('[recite] ${DateTime.now().toIso8601String()} $s');
}

void main() {
  test('backfill classical citations', () async {
    if (_db.isEmpty) fail('DB dart-define is required');

    // Read-write: this pass is the one thing that legitimately writes to the
    // database outside an import, and opening it runs the v3 migration.
    final db = MasterGamesDb.open(_db);
    final counts = classicalCitationProgress(db);
    _say(
      '${counts.total} games, ${counts.classical} classical '
      '(${(100 * counts.classical / counts.total).toStringAsFixed(1)}%)',
    );

    final before = db.raw
        .select('SELECT count(*), sum(top_classical_game != 0) FROM book')
        .first;
    _say(
      '${before.columnAt(0)} book moves, '
      '${before.columnAt(1) ?? 0} already have a classical citation',
    );

    // Re-derive from the current rules first, so sharpening the classifier
    // is a seven-minute rerun rather than a re-import.  This clears the
    // citation columns, which is what lets a demoted game give one up.
    refreshAuthorities(db);
    final after0 = classicalCitationProgress(db);
    _say('reclassified: ${after0.classical} classical games');

    final wall = Stopwatch()..start();
    var lastSaid = 0;
    final result = await rebuildClassicalCitations(
      db,
      onProgress: (scanned, total) {
        if (wall.elapsedMilliseconds - lastSaid < 30000) return;
        lastSaid = wall.elapsedMilliseconds;
        final pct = (100 * scanned / total).toStringAsFixed(1);
        _say(
          '$scanned/$total games ($pct%), '
          '${(wall.elapsedMilliseconds / 60000).toStringAsFixed(1)}min',
        );
      },
    );
    wall.stop();

    final after = db.raw
        .select('SELECT count(*), sum(top_classical_game != 0) FROM book')
        .first;
    final rows = after.columnAt(0) as int;
    final cited = (after.columnAt(1) as int?) ?? 0;
    _say(
      'done: ${result.gamesScanned} games replayed, '
      '${result.movesRecorded} citations recorded, '
      '${(wall.elapsedMilliseconds / 60000).toStringAsFixed(1)}min',
    );
    _say(
      '$cited of $rows book moves now cite a classical game '
      '(${(100 * cited / rows).toStringAsFixed(1)}%)',
    );
    db.close();
  }, timeout: const Timeout(Duration(hours: 6)));
}
