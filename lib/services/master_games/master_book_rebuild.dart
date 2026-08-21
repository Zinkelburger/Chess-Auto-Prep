/// Backfill `book.top_classical_game` for a database imported before v3.
///
/// The book records, per (position, move), the highest-rated game that played
/// it.  In a TWIC corpus that is an online blitz game more often than not, so
/// v3 keeps a second id: the strongest classical over-the-board game, which is
/// what a citation should reach for.  New imports fill it as they go; a
/// database that already exists has to be walked once.
///
/// Only classical games are replayed — under 40% of a five-year corpus — and
/// only their first [kBookMaxPly] plies, the same window the book covers.
/// Nothing is downloaded and no existing column is rewritten, so an
/// interrupted run simply leaves the rest for the next one.
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
  });

  /// Classical games replayed.
  final int gamesScanned;

  /// Book rows that took this pass's game as their citation.
  final int movesRecorded;

  final bool cancelled;
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
/// played, keeping the highest-rated one per (position, move).
///
/// [db] must be open for writing.  [onProgress] is called every [batch] games.
Future<ClassicalCitationRebuild> rebuildClassicalCitations(
  MasterGamesDb db, {
  void Function(int scanned, int total)? onProgress,
  bool Function()? isCancelled,
  int batch = 2000,
}) async {
  final raw = db.raw;
  final codec = db.codec;
  final total = classicalCitationProgress(db).classical;

  final select = raw.prepare(
    'SELECT id, movetext, white_elo, black_elo FROM games '
    'WHERE authority = ? AND id > ? ORDER BY id LIMIT ?',
  );
  // Guarded so a weaker game never displaces a stronger one, which makes the
  // pass idempotent and safe to resume.
  final update = raw.prepare(
    'UPDATE book SET top_classical_game = ?, classical_max_elo = ? '
    'WHERE pos = ? AND move = ? '
    'AND (top_classical_game = 0 OR classical_max_elo < ?)',
  );

  var scanned = 0;
  var recorded = 0;
  var lastId = 0;
  var cancelled = false;
  try {
    while (true) {
      final rows = select.select([GameAuthority.classical.code, lastId, batch]);
      if (rows.isEmpty) break;

      raw.execute('BEGIN');
      try {
        for (final r in rows) {
          lastId = r.columnAt(0) as int;
          final maxElo = [
            (r.columnAt(2) as int?) ?? 0,
            (r.columnAt(3) as int?) ?? 0,
          ].reduce((a, b) => a > b ? a : b);

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
            update.execute([
              lastId,
              maxElo,
              positionKey(pos.fen),
              move.uci,
              maxElo,
            ]);
            if (raw.updatedRows > 0) recorded++;
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
  } finally {
    select.dispose();
    update.dispose();
  }

  return ClassicalCitationRebuild(
    gamesScanned: scanned,
    movesRecorded: recorded,
    cancelled: cancelled,
  );
}
