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

import 'package:sqlite3/sqlite3.dart';

import '../../utils/movetext_builder.dart';
import '../generation/pgn_lexer.dart' show splitPgnGames;
import 'book_replay.dart';
import 'game_authority.dart';
import 'master_games_db.dart';
import 'movetext_codec.dart';

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

  /// Games in the PGN with no moves, which are not stored.
  final int gamesSkipped;

  /// The issue was already in the database and [MasterGamesImportRequest.replace]
  /// was not set, so nothing was read.
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

/// One parsed game with its headers decoded into the columns `games` keeps.
class _ParsedGame {
  final String event;
  final String site;
  final String date;
  final String round;
  final String white;
  final String black;

  /// `1-0`, `0-1`, `1/2-1/2` or `*`.
  final String result;
  final int? whiteElo;
  final int? blackElo;
  final int? whiteFideId;
  final int? blackFideId;
  final String eco;

  /// Year of the game (or of the event when the game's own date is missing),
  /// 0 when neither is known.
  final int year;
  final GameAuthority authority;
  final List<String> sans;

  /// `1. d4 Nf6 2. c4 …` — numbered SAN, one space between tokens.
  final String movetext;

  _ParsedGame(Map<String, String> headers, this.sans)
    : event = headers['Event'] ?? '',
      site = headers['Site'] ?? '',
      date = headers['Date'] ?? '',
      round = headers['Round'] ?? '',
      white = headers['White'] ?? '',
      black = headers['Black'] ?? '',
      result = _normalizeResult(headers['Result']),
      whiteElo = _int(headers['WhiteElo']),
      blackElo = _int(headers['BlackElo']),
      whiteFideId = _int(headers['WhiteFideId']),
      blackFideId = _int(headers['BlackFideId']),
      eco = headers['ECO'] ?? '',
      year = _year(headers['Date']) ?? _year(headers['EventDate']) ?? 0,
      authority = classifyAuthority(
        site: headers['Site'] ?? '',
        event: headers['Event'] ?? '',
      ),
      movetext = buildNumberedMovetext(sans);

  int get plyCount => sans.length;
}

/// Split [pgnText] into games with at least one move; the count of moveless
/// games comes back as `skipped`.
({List<_ParsedGame> games, int skipped}) _parseGames(String pgnText) {
  var skipped = 0;
  final games = <_ParsedGame>[];
  for (final g in splitPgnGames(pgnText)) {
    final sans = movetextSans(g.movetext);
    if (sans.isEmpty) {
      skipped++;
      continue;
    }
    games.add(_ParsedGame(g.headers, sans));
  }
  return (games: games, skipped: skipped);
}

const String _insertGameSql =
    'INSERT INTO games(twic, event, site, date, round, white, black, result, '
    'white_elo, black_elo, white_fide, black_fide, eco, ply_count, movetext, '
    'authority) '
    'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)';

const String _upsertBookSql = '''
    INSERT INTO book(pos, move, ply, games, white_wins, draws, black_wins,
                     elo_sum, elo_n, max_elo, last_year, top_game, recent_game,
                     top_classical_game, classical_max_elo,
                     classical_games, classical_white_wins, classical_draws,
                     classical_black_wins)
    VALUES(?,?,?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
      -- The classical slot tracks its own maximum: an online game arriving
      -- with a higher rating must not displace a citable one.
      top_classical_game = CASE
        WHEN excluded.top_classical_game != 0
             AND (top_classical_game = 0
                  OR excluded.classical_max_elo > classical_max_elo)
        THEN excluded.top_classical_game ELSE top_classical_game END,
      classical_max_elo = MAX(classical_max_elo, excluded.classical_max_elo),
      classical_games = classical_games + excluded.classical_games,
      classical_white_wins = classical_white_wins
                             + excluded.classical_white_wins,
      classical_draws = classical_draws + excluded.classical_draws,
      classical_black_wins = classical_black_wins
                             + excluded.classical_black_wins,
      ply = MIN(ply, excluded.ply)
  ''';

MasterGamesImportResult _import(
  MasterGamesDb store,
  MasterGamesImportRequest req,
) {
  final db = store.raw;
  final issue = req.twicIssue;
  if (issue != null && !req.replace && _isIssueImported(db, issue)) {
    return const MasterGamesImportResult(
      gamesImported: 0,
      gamesSkipped: 0,
      alreadyImported: true,
    );
  }

  final parsed = _parseGames(req.pgnText);
  final games = parsed.games;

  final insertGame = db.prepare(_insertGameSql);
  final upsertBook = db.prepare(_upsertBookSql);

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

    for (final game in games) {
      _insertGame(insertGame, game, issue: issue, codec: codec);
      _indexBook(upsertBook, game, gameId: db.lastInsertRowId);
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
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    insertGame.close();
    upsertBook.close();
  }
  // Fold the WAL back into the file now rather than leaving a
  // database-sized journal for the next import to trip over.  Best effort:
  // a reader mid-query makes this a partial checkpoint, which is fine, and a
  // checkpoint that cannot run at all costs nothing but disk space.
  try {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  } on SqliteException {
    // Deliberately ignored: see above.
  }

  return MasterGamesImportResult(
    gamesImported: imported,
    gamesSkipped: parsed.skipped,
  );
}

bool _isIssueImported(Database db, int issue) =>
    db.select('SELECT 1 FROM twic_issues WHERE issue = ?', [issue]).isNotEmpty;

void _insertGame(
  PreparedStatement insertGame,
  _ParsedGame game, {
  required int? issue,
  required MovetextCodec codec,
}) {
  insertGame.execute([
    issue,
    game.event,
    game.site,
    game.date,
    game.round,
    game.white,
    game.black,
    game.result,
    game.whiteElo,
    game.blackElo,
    game.whiteFideId,
    game.blackFideId,
    game.eco,
    game.plyCount,
    codec.encode(game.movetext),
    game.authority.code,
  ]);
}

/// Replay the opening and aggregate one `book` row per (position, move).
void _indexBook(
  PreparedStatement upsertBook,
  _ParsedGame game, {
  required int gameId,
}) {
  final tally = resultTally(game.result);
  final eloSum = (game.whiteElo ?? 0) + (game.blackElo ?? 0);
  final eloN =
      (game.whiteElo == null ? 0 : 1) + (game.blackElo == null ? 0 : 1);
  final maxElo = strongerElo(game.whiteElo, game.blackElo);
  // Only a citable game claims the classical slot and the classical-only
  // counts; everything else leaves them at 0 and falls back to `top_game`.
  final citable = game.authority.isCitable;

  for (final ref in replayBookMoves(game.sans)) {
    upsertBook.execute([
      ref.positionKey,
      ref.uci,
      ref.ply,
      tally.whiteWins,
      tally.draws,
      tally.blackWins,
      eloSum,
      eloN,
      maxElo,
      game.year,
      gameId,
      gameId,
      citable ? gameId : 0,
      citable ? maxElo : 0,
      citable ? 1 : 0,
      citable ? tally.whiteWins : 0,
      citable ? tally.draws : 0,
      citable ? tally.blackWins : 0,
    ]);
  }
}

const _decidedResults = {'1-0', '0-1', '1/2-1/2'};

String _normalizeResult(String? r) =>
    r != null && _decidedResults.contains(r) ? r : '*';

int? _int(String? s) => s == null ? null : int.tryParse(s.trim());

int? _year(String? date) {
  if (date == null || date.length < 4) return null;
  final y = int.tryParse(date.substring(0, 4));
  return (y == null || y < 1000) ? null : y;
}
