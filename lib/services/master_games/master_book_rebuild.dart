/// Backfill the book's classical columns for a database imported before they
/// existed: `top_classical_game` (v3) and the classical-only counts (v4).
///
/// The book records, per (position, move), the highest-rated game that played
/// it.  In a TWIC corpus that is an online blitz game more often than not, so
/// v3 keeps a second id: the strongest classical over-the-board game, which is
/// what a citation should reach for — and v4 keeps the classical games' own
/// counts and results, so an explorer can show over-the-board practice on its
/// own.  New imports fill both as they go; a database that already exists has
/// to be walked once.
///
/// Only classical games are replayed — under 40% of a five-year corpus — and
/// only their first [kBookMaxPly] plies, the same window the book covers.
/// Nothing is downloaded.  The citation columns are only ever raised, so they
/// survive an interruption; the counts are sums, so a run that starts from
/// the beginning zeroes them first and the database reports them incomplete
/// until the walk reaches the last classical game.  A run can be continued
/// from where an earlier one stopped with [rebuildClassicalCitations]'s
/// `afterId`, which is also how the app runs it in chunks from an isolate.
library;

import 'package:dartchess/dartchess.dart';

import '../generation/pgn_freq_parser.dart'
    show isResultToken, tokenToSan, tokenizeMovetext;
import 'game_authority.dart';
import 'master_games_db.dart';
import 'position_key.dart';

class ClassicalCitationRebuild {
  const ClassicalCitationRebuild({
    required this.gamesScanned,
    required this.movesRecorded,
    required this.cancelled,
    this.lastId = 0,
    this.done = false,
  });

  /// Classical games replayed.
  final int gamesScanned;

  /// Book rows that took this pass's game as their citation.
  final int movesRecorded;

  final bool cancelled;

  /// The id of the last game replayed — pass it back as `afterId` to
  /// continue.
  final int lastId;

  /// Whether the walk reached the last classical game, which is when the
  /// counts become complete.
  final bool done;
}

/// Zero every row's classical-only counts and mark them incomplete, ahead of
/// a walk from the first game.
void resetClassicalCounts(MasterGamesDb db) {
  db.raw.execute(
    'UPDATE book SET classical_games = 0, classical_white_wins = 0, '
    'classical_draws = 0, classical_black_wins = 0 WHERE classical_games != 0',
  );
  db.classicalCountsComplete = false;
}

/// Re-derive `games.authority` from the stored headers, and clear the book's
/// citation columns so [rebuildClassicalCitations] can rewrite them.
///
/// The classifier is a heuristic over event names and will keep being
/// sharpened (`esports` was added after `kvik` and `champions` were tried and
/// rejected).  Sharpening it only means anything if a database can be brought
/// back in line without re-importing — and because a game can now be
/// *demoted* out of the classical tier, the citation it won has to be given
/// up rather than merely challenged.  Hence the reset: the rebuild's guard
/// only ever raises a citation, never lowers one.
///
/// Cheap — a pair of full-table updates over columns already in the file, no
/// movetext replayed and nothing downloaded.
int refreshAuthorities(MasterGamesDb db) {
  final raw = db.raw;
  raw.execute('UPDATE games SET authority = $kAuthoritySqlExpression');
  final changed = raw.updatedRows;
  raw.execute(
    'UPDATE book SET top_classical_game = 0, classical_max_elo = 0 '
    'WHERE top_classical_game != 0',
  );
  resetClassicalCounts(db);
  return changed;
}

/// How many classical games still need walking, and how many there are.
({int classical, int total}) classicalCitationProgress(MasterGamesDb db) {
  final row = db.raw.select('SELECT count(*), sum(authority = ?) FROM games', [
    GameAuthority.classical.code,
  ]).first;
  return (
    total: row.columnAt(0) as int? ?? 0,
    classical: row.columnAt(1) as int? ?? 0,
  );
}

/// Walk the classical games and record each as the citation for the moves it
/// played, keeping the highest-rated one per (position, move), and add each
/// to the classical-only counts of those moves.
///
/// [db] must be open for writing.  [onProgress] is called every [batch] games.
/// Starting from the beginning (`afterId == 0`) zeroes the counts first;
/// [maxGames] stops after that many games so a caller can run the walk in
/// chunks, continuing from the result's `lastId`.  The counts are marked
/// complete when the walk runs out of games.
Future<ClassicalCitationRebuild> rebuildClassicalCitations(
  MasterGamesDb db, {
  void Function(int scanned, int total)? onProgress,
  bool Function()? isCancelled,
  int batch = 2000,
  int afterId = 0,
  int? maxGames,
}) async {
  final raw = db.raw;
  final codec = db.codec;
  final total = classicalCitationProgress(db).classical;
  if (afterId == 0) resetClassicalCounts(db);

  final select = raw.prepare(
    'SELECT id, movetext, white_elo, black_elo, result FROM games '
    'WHERE authority = ? AND id > ? ORDER BY id LIMIT ?',
  );
  // Guarded so a weaker game never displaces a stronger one, which makes the
  // pass idempotent and safe to resume.
  final update = raw.prepare(
    'UPDATE book SET top_classical_game = ?, classical_max_elo = ? '
    'WHERE pos = ? AND move = ? '
    'AND (top_classical_game = 0 OR classical_max_elo < ?)',
  );
  final count = raw.prepare(
    'UPDATE book SET classical_games = classical_games + 1, '
    'classical_white_wins = classical_white_wins + ?, '
    'classical_draws = classical_draws + ?, '
    'classical_black_wins = classical_black_wins + ? '
    'WHERE pos = ? AND move = ?',
  );

  var scanned = 0;
  var recorded = 0;
  var lastId = afterId;
  var cancelled = false;
  var done = false;
  try {
    while (true) {
      final remaining = maxGames == null ? batch : maxGames - scanned;
      if (remaining <= 0) break;
      final rows = select.select([
        GameAuthority.classical.code,
        lastId,
        remaining < batch ? remaining : batch,
      ]);
      if (rows.isEmpty) {
        done = true;
        break;
      }

      raw.execute('BEGIN');
      try {
        for (final r in rows) {
          lastId = r.columnAt(0) as int;
          final maxElo = [
            (r.columnAt(2) as int?) ?? 0,
            (r.columnAt(3) as int?) ?? 0,
          ].reduce((a, b) => a > b ? a : b);
          final result = r.columnAt(4) as String;
          final ww = result == '1-0' ? 1 : 0;
          final dd = result == '1/2-1/2' ? 1 : 0;
          final bw = result == '0-1' ? 1 : 0;

          final sans = <String>[];
          for (final t in tokenizeMovetext(
            codec.decode(r.columnAt(1) as List<int>),
          )) {
            if (isResultToken(t)) break;
            final san = tokenToSan(t);
            if (san != null) sans.add(san);
            if (sans.length >= kBookMaxPly) break;
          }

          Position pos = Chess.initial;
          for (final san in sans) {
            final Move move;
            try {
              final parsed = pos.parseSan(san);
              if (parsed == null) break;
              move = parsed;
            } catch (_) {
              break; // corrupt movetext: keep what replayed
            }
            final key = positionKey(pos.fen);
            update.execute([lastId, maxElo, key, move.uci, maxElo]);
            if (raw.updatedRows > 0) recorded++;
            count.execute([ww, dd, bw, key, move.uci]);
            pos = pos.play(move);
          }
          scanned++;
        }
        raw.execute('COMMIT');
      } catch (_) {
        raw.execute('ROLLBACK');
        rethrow;
      }

      onProgress?.call(scanned, total);
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      // Let a UI isolate breathe between batches.
      await Future<void>.delayed(Duration.zero);
    }
    if (done && !cancelled) db.classicalCountsComplete = true;
  } finally {
    select.close();
    update.close();
    count.close();
  }

  return ClassicalCitationRebuild(
    gamesScanned: scanned,
    movesRecorded: recorded,
    cancelled: cancelled,
    lastId: lastId,
    done: done,
  );
}
