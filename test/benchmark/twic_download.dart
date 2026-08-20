/// Headless TWIC downloader.
///
/// Fills the app's master-games database from the command line, for the
/// hours-long first download that nobody wants to sit in front of.  Named
/// without a `_test` suffix so a bare `flutter test` (and CI) never runs it;
/// `flutter test` is only the runner, because the importer wants the Flutter
/// VM's sqlite.
///
/// Does exactly what `MasterGamesService.sync` does — probe the newest issue,
/// walk from the start issue, skip what `twic_issues` already has — minus the
/// UI, the job tile and SharedPreferences.  Interrupting it is safe: each
/// issue is one transaction, so the next run picks up where this one stopped.
///
///   flutter test test/benchmark/twic_download.dart \
///     --dart-define=DB=$HOME/.local/share/com.example.chess_auto_prep/master_games.db \
///     --dart-define=YEARS=5
library;

import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/services/master_games/twic_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _db = String.fromEnvironment('DB');
const _years = int.fromEnvironment('YEARS', defaultValue: 5);

/// Explicit first issue; 0 means "derive it from YEARS".
const _startIssue = int.fromEnvironment('START_ISSUE', defaultValue: 0);

/// Stop after this many issues (0 = every one up to the newest published).
const _maxIssues = int.fromEnvironment('MAX_ISSUES', defaultValue: 0);

void _say(String s) =>
    stdout.writeln('[twic] ${DateTime.now().toIso8601String()} $s');

void main() {
  test('download TWIC', () async {
    if (_db.isEmpty) fail('DB dart-define is required');
    final client = TwicClient();
    final db = MasterGamesDb.open(_db, forImport: true);
    try {
      final start = _startIssue > 0 ? _startIssue : twicIssueYearsBack(_years);
      final have = db.importedIssues();
      final probeFrom = have.isEmpty
          ? twicIssueEstimateFor(DateTime.now()) - 2
          : have.reduce((a, b) => a > b ? a : b) + 1;
      final latest = await client.latestIssue(
        from: probeFrom < start ? start : probeFrom,
      );
      if (latest == null) fail('could not reach theweekinchess.com');
      var todo = [
        for (var n = start; n <= latest; n++)
          if (!have.contains(n)) n,
      ];
      if (_maxIssues > 0 && todo.length > _maxIssues) {
        todo = todo.sublist(0, _maxIssues);
      }
      _say(
        'start=$start latest=$latest todo=${todo.length} '
        '(${have.length} already imported)',
      );

      var games = 0;
      var failed = 0;
      final wall = Stopwatch()..start();
      // Download and import are pipelined the same way the service does it:
      // issue N+1 is fetched while issue N imports.
      Future<String?> fetch(int n) async {
        try {
          return await client.fetchIssuePgn(n);
        } catch (e) {
          _say('issue $n download failed: $e');
          return null;
        }
      }

      var pending = todo.isEmpty
          ? Future<String?>.value(null)
          : fetch(todo.first);
      for (var i = 0; i < todo.length; i++) {
        final issue = todo[i];
        final pgn = await pending;
        if (i + 1 < todo.length) pending = fetch(todo[i + 1]);
        if (pgn == null) {
          failed++;
          continue;
        }
        final result = importPgnIntoMasterGames(
          MasterGamesImportRequest(dbPath: _db, pgnText: pgn, twicIssue: issue),
        );
        games += result.gamesImported;
        final done = i + 1;
        final rate = wall.elapsed.inSeconds / done;
        _say(
          'issue $issue: +${result.gamesImported} games '
          '($done/${todo.length}, $games total, '
          '${(rate * (todo.length - done) / 60).toStringAsFixed(0)} min left)',
        );
      }
      unawaited(pending.catchError((_) => null));
      final stats = db.stats();
      _say(
        'done: $games games added, $failed issues failed, '
        'db now ${stats.games} games / ${stats.issues} issues '
        '(${(stats.fileBytes / 1e9).toStringAsFixed(2)} GB)',
      );
    } finally {
      db.close();
      client.close();
    }
  }, timeout: const Timeout(Duration(hours: 12)));
}
