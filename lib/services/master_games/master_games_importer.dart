/// Imports a PGN (one TWIC issue) into the master-games database.
///
/// Pure and isolate-safe: [importPgnIntoMasterGames] opens its own SQLite
/// connection, so the sync service runs it through `Isolate.run` and the UI
/// never blocks.  One transaction per issue — an interrupted import leaves
/// the issue out of `twic_issues`, so the next sync simply redoes it.
///
/// Only the first [kBookMaxPly] plies are replayed with dartchess (the book
/// needs positions, and that is where the cost is); the full movetext is
/// stored, compressed ([MovetextCodec]), for later display and export.  The
/// first import into an empty database also builds the compression
/// dictionary from its own games and stores it in `meta`.
library;

import 'package:dartchess/dartchess.dart';

import '../generation/pgn_freq_parser.dart'
    show isResultToken, splitPgnGames, tokenToSan, tokenizeMovetext;
import 'master_games_db.dart';
import 'movetext_codec.dart';
import 'position_key.dart';

class MasterGamesImportRequest {
  final String dbPath;
  final String pgnText;

  /// TWIC issue number, or null for a user-supplied PGN.
  final int? twicIssue;

  /// Replace an already-imported issue (default: skip it).
  final bool replace;

  const MasterGamesImportRequest({
    required this.dbPath,
    required this.pgnText,
    required this.twicIssue,
    this.replace = false,
  });
}

class MasterGamesImportResult {
  final int gamesImported;
  final int gamesSkipped;
  final bool alreadyImported;

  const MasterGamesImportResult({
    required this.gamesImported,
    required this.gamesSkipped,
    this.alreadyImported = false,
  });
}

/// Import [request] synchronously.  Safe to call via `Isolate.run`.
MasterGamesImportResult importPgnIntoMasterGames(
  MasterGamesImportRequest request,
) {
  final db = MasterGamesDb.open(request.dbPath, forImport: true);
  try {
    return _import(db, request);
  } finally {
    db.close();
  }
}

/// One parsed game, ready to insert.
class _ParsedGame {
  final Map<String, String> headers;
  final List<String> sans;
  final String movetext;
  _ParsedGame(this.headers, this.sans) : movetext = _compactMovetext(sans);
}

MasterGamesImportResult _import(
  MasterGamesDb store,
  MasterGamesImportRequest req,
) {
  final db = store.raw;
  final issue = req.twicIssue;
  if (issue != null) {
    final already = db.select('SELECT 1 FROM twic_issues WHERE issue = ?', [
      issue,
    ]).isNotEmpty;
    if (already && !req.replace) {
      return const MasterGamesImportResult(
        gamesImported: 0,
        gamesSkipped: 0,
        alreadyImported: true,
      );
    }
  }

  var skipped = 0;
  final games = <_ParsedGame>[];
  for (final g in splitPgnGames(req.pgnText)) {
    final sans = <String>[];
    for (final t in tokenizeMovetext(g.movetext)) {
      if (isResultToken(t)) break;
      final san = tokenToSan(t);
      if (san != null) sans.add(san);
    }
    if (sans.isEmpty) {
      skipped++;
      continue;
    }
    games.add(_ParsedGame(g.headers, sans));
  }

  final insertGame = db.prepare(
    'INSERT INTO games(twic, event, site, date, round, white, black, result, '
    'white_elo, black_elo, white_fide, black_fide, eco, ply_count, movetext) '
    'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
  );
  final upsertBook = db.prepare('''
    INSERT INTO book(pos, move, ply, games, white_wins, draws, black_wins,
                     elo_sum, elo_n, max_elo, last_year, top_game, recent_game)
    VALUES(?,?,?,1,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(pos, move) DO UPDATE SET
      games = games + 1,
      white_wins = white_wins + excluded.white_wins,
      draws = draws + excluded.draws,
      black_wins = black_wins + excluded.black_wins,
      elo_sum = elo_sum + excluded.elo_sum,
      elo_n = elo_n + excluded.elo_n,
      top_game = CASE WHEN excluded.max_elo > max_elo
                      THEN excluded.top_game ELSE top_game END,
      max_elo = MAX(max_elo, excluded.max_elo),
      recent_game = CASE WHEN excluded.last_year >= last_year
                         THEN excluded.recent_game ELSE recent_game END,
      last_year = MAX(last_year, excluded.last_year),
      ply = MIN(ply, excluded.ply)
  ''');

  var imported = 0;
  // IMMEDIATE: the body reads (the movetext dictionary, the issue check)
  // before it writes, and a deferred transaction upgrading read->write is
  // handed SQLITE_BUSY with no busy-handler retry.  Take the write lock up
  // front so `busy_timeout` covers it.
  db.execute('BEGIN IMMEDIATE');
  try {
    // First games into this database: derive the movetext dictionary from
    // them before anything is stored with it.
    if (store.metaBlob(kMovetextDictKey) == null && games.isNotEmpty) {
      store.putMetaBlob(
        kMovetextDictKey,
        MovetextCodec.buildDictionary(games.map((g) => g.movetext)),
      );
    }
    final codec = store.codec;

    if (issue != null && req.replace) {
      // Replacing an issue: drop its games.  Book rows are left as they are
      // (re-aggregating would need a full rebuild); a replace is rare and
      // only ever re-imports the same games.
      db.execute('DELETE FROM games WHERE twic = ?', [issue]);
    }

    for (final g in games) {
      final h = g.headers;
      final sans = g.sans;

      final result = _normalizeResult(h['Result']);
      final whiteElo = _int(h['WhiteElo']);
      final blackElo = _int(h['BlackElo']);
      final year = _year(h['Date']) ?? _year(h['EventDate']) ?? 0;

      insertGame.execute([
        issue,
        h['Event'] ?? '',
        h['Site'] ?? '',
        h['Date'] ?? '',
        h['Round'] ?? '',
        h['White'] ?? '',
        h['Black'] ?? '',
        result,
        whiteElo,
        blackElo,
        _int(h['WhiteFideId']),
        _int(h['BlackFideId']),
        h['ECO'] ?? '',
        sans.length,
        codec.encode(g.movetext),
      ]);
      final gameId = db.lastInsertRowId;

      // Book: replay the opening and aggregate per (position, move).
      final ww = result == '1-0' ? 1 : 0;
      final dd = result == '1/2-1/2' ? 1 : 0;
      final bw = result == '0-1' ? 1 : 0;
      final eloSum = (whiteElo ?? 0) + (blackElo ?? 0);
      final eloN = (whiteElo == null ? 0 : 1) + (blackElo == null ? 0 : 1);
      final maxElo = [
        whiteElo ?? 0,
        blackElo ?? 0,
      ].reduce((a, b) => a > b ? a : b);

      Position pos = Chess.initial;
      final limit = sans.length < kBookMaxPly ? sans.length : kBookMaxPly;
      for (var ply = 0; ply < limit; ply++) {
        final Move move;
        try {
          final parsed = pos.parseSan(sans[ply]);
          if (parsed == null) break;
          move = parsed;
        } catch (_) {
          break; // corrupt movetext: keep what we replayed
        }
        upsertBook.execute([
          positionKey(pos.fen),
          move.uci,
          ply,
          ww,
          dd,
          bw,
          eloSum,
          eloN,
          maxElo,
          year,
          gameId,
          gameId,
        ]);
        pos = pos.play(move);
      }
      imported++;
    }

    if (issue != null) {
      db.execute(
        'INSERT OR REPLACE INTO twic_issues(issue, games, imported_at) '
        'VALUES(?,?,?)',
        [issue, imported, DateTime.now().millisecondsSinceEpoch],
      );
    }
    db.execute('COMMIT');
  } catch (e) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    insertGame.dispose();
    upsertBook.dispose();
  }
  // Fold the WAL back into the file now rather than leaving a
  // database-sized journal for the next import to trip over.  Best effort:
  // a reader mid-query makes this a partial checkpoint, which is fine.
  try {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  } catch (_) {}

  return MasterGamesImportResult(
    gamesImported: imported,
    gamesSkipped: skipped,
  );
}

String _normalizeResult(String? r) => switch (r) {
  '1-0' || '0-1' || '1/2-1/2' => r!,
  _ => '*',
};

int? _int(String? s) => s == null ? null : int.tryParse(s.trim());

int? _year(String? date) {
  if (date == null || date.length < 4) return null;
  final y = int.tryParse(date.substring(0, 4));
  return (y == null || y < 1000) ? null : y;
}

/// `1. d4 Nf6 2. c4 …` — numbered SAN, one space between tokens.
String _compactMovetext(List<String> sans) {
  final b = StringBuffer();
  for (var i = 0; i < sans.length; i++) {
    if (i.isEven) {
      if (i > 0) b.write(' ');
      b.write('${i ~/ 2 + 1}. ');
    } else {
      b.write(' ');
    }
    b.write(sans[i]);
  }
  return b.toString();
}
