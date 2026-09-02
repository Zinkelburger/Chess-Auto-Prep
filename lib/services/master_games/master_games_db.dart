/// Local master-games database (TWIC), the ChessBase-style store the app
/// queries instead of re-parsing PGN files.
///
/// One SQLite file, `master_games.db` in the support directory, with three
/// tables:
///
///   games        one row per game: indexed headers + SAN movetext,
///                zlib-compressed with a per-database dictionary
///                ([MovetextCodec]; the dictionary lives in `meta`)
///   book         the position index, *aggregated*: one row per
///                (position, move) for plies ≤ [kBookMaxPly] with game
///                counts, results, Elo and two sample game ids (strongest,
///                most recent).  This is a local Lichess-masters explorer and
///                the source of "X improves on Y in `<game>`" citations.
///   twic_issues  which weekly issues are in, so sync is incremental.
///   meta         key/value blobs: the movetext dictionary.
///
/// Access is through `package:sqlite3` (synchronous FFI): reads from the UI
/// isolate are sub-millisecond indexed lookups, and the importer runs in its
/// own isolate with its own connection — SQLite WAL mode keeps the two from
/// blocking each other.
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../utils/pgn_utils.dart';
import '../storage/app_paths.dart';
import 'game_authority.dart';
import 'master_games_query.dart';
import 'movetext_codec.dart';
import 'position_key.dart';

/// Plies indexed into `book`.  Thirty plies (move 15) covers every opening
/// decision a repertoire makes while keeping the table a few GB for a
/// five-year corpus; deeper positions are almost all singletons.
const int kBookMaxPly = 30;

/// Per-position book lookup handed to the tree build (null = no database).
typedef BookLookup = List<BookMove> Function(String fen);

/// One aggregated `book` row: what masters played from a position.
class BookMove {
  final String uci;
  final int games;
  final int whiteWins;
  final int draws;
  final int blackWins;
  final double? averageElo;
  final int maxElo;
  final int lastYear;

  /// Game id of the highest-rated encounter with this move (for citations).
  final int topGameId;

  /// Game id of the most recent encounter with this move.
  final int recentGameId;

  /// Game id of the strongest *classical over-the-board* encounter, or 0 when
  /// only online / speed games have played this move (and 0 on a database
  /// that has not had `rebuildClassicalCitations` run over it).
  final int topClassicalGameId;

  /// The game to cite for this move.
  ///
  /// A citation is a claim about theory, so it prefers the strongest
  /// over-the-board classical game even when a higher-rated blitz game
  /// exists — and falls back to the strongest game of any kind rather than
  /// citing nothing.
  int get citeGameId =>
      topClassicalGameId != 0 ? topClassicalGameId : topGameId;

  const BookMove({
    required this.uci,
    required this.games,
    required this.whiteWins,
    required this.draws,
    required this.blackWins,
    required this.averageElo,
    required this.maxElo,
    required this.lastYear,
    required this.topGameId,
    required this.recentGameId,
    this.topClassicalGameId = 0,
  });

  /// Score for White in [0, 1].
  double get whiteScore => games == 0 ? 0.5 : (whiteWins + draws / 2) / games;
}

/// One stored game.  [movetext] is the SAN movetext as imported (move
/// numbers included, comments stripped), so it round-trips to PGN directly.
class MasterGame {
  final int id;
  final int? twicIssue;
  final String event;
  final String site;
  final String date;
  final String round;
  final String white;
  final String black;
  final String result;
  final int? whiteElo;
  final int? blackElo;
  final int? whiteFideId;
  final int? blackFideId;
  final String eco;
  final int plyCount;
  final String movetext;

  const MasterGame({
    required this.id,
    required this.twicIssue,
    required this.event,
    required this.site,
    required this.date,
    required this.round,
    required this.white,
    required this.black,
    required this.result,
    required this.whiteElo,
    required this.blackElo,
    required this.whiteFideId,
    required this.blackFideId,
    required this.eco,
    required this.plyCount,
    required this.movetext,
  });

  int? get year {
    if (date.length < 4) return null;
    return int.tryParse(date.substring(0, 4));
  }

  /// Short citation in the style annotators use: `Aronian–So, Saint Louis
  /// 2026`.  Surnames only when the header is `Surname,Initials`.
  String get citation {
    final w = _surname(white);
    final b = _surname(black);
    final where = site.trim().isEmpty ? event.trim() : site.trim();
    final y = year;
    final place = [if (where.isNotEmpty) where, if (y != null) '$y'].join(' ');
    return place.isEmpty ? '$w–$b' : '$w–$b, $place';
  }

  static String _surname(String name) {
    final comma = name.indexOf(',');
    final s = comma > 0 ? name.substring(0, comma) : name;
    return s.trim().isEmpty ? '?' : s.trim();
  }

  /// Full PGN text with the standard seven tags plus Elo/ECO when known.
  String toPgn() {
    final b = StringBuffer()
      ..writeln('[Event "${escapeHeaderValue(event)}"]')
      ..writeln('[Site "${escapeHeaderValue(site)}"]')
      ..writeln('[Date "${date.isEmpty ? '????.??.??' : date}"]')
      ..writeln('[Round "${round.isEmpty ? '?' : escapeHeaderValue(round)}"]')
      ..writeln('[White "${escapeHeaderValue(white)}"]')
      ..writeln('[Black "${escapeHeaderValue(black)}"]')
      ..writeln('[Result "$result"]');
    if (whiteElo != null) b.writeln('[WhiteElo "$whiteElo"]');
    if (blackElo != null) b.writeln('[BlackElo "$blackElo"]');
    if (eco.isNotEmpty) b.writeln('[ECO "$eco"]');
    if (twicIssue != null) b.writeln('[Source "TWIC $twicIssue"]');
    b
      ..writeln()
      ..writeln('$movetext $result')
      ..writeln();
    return b.toString();
  }
}

/// One imported weekly issue, for the browser's issue picker.
class TwicIssueSummary {
  const TwicIssueSummary({required this.issue, required this.games});
  final int issue;
  final int games;
}

/// Coverage summary for the settings/prompt UI.
class MasterGamesStats {
  final int games;
  final int issues;
  final int? firstIssue;
  final int? lastIssue;
  final int fileBytes;

  const MasterGamesStats({
    required this.games,
    required this.issues,
    required this.firstIssue,
    required this.lastIssue,
    required this.fileBytes,
  });

  bool get isEmpty => games == 0;
}

class MasterGamesDb {
  final Database _db;
  final String path;

  MasterGamesDb._(this._db, this.path);

  /// Open (creating and migrating when needed).  [readOnly] opens without
  /// creating — use it for query-only connections so a missing file is an
  /// empty database rather than a new one.
  ///
  /// [forImport] tunes the connection for bulk writes: a 256 MB page cache
  /// (the `book` index is keyed by a hash, so every upsert lands on a
  /// random page — cache misses are the whole cost) and `synchronous=OFF`.
  /// OFF means a power cut mid-import can corrupt the file; that is
  /// acceptable here because this database is a cache that is rebuilt by
  /// re-running the sync, and the import halves in wall-clock for it.
  factory MasterGamesDb.open(
    String path, {
    bool readOnly = false,
    bool forImport = false,
  }) {
    final db = sqlite3.open(
      path,
      mode: readOnly ? OpenMode.readOnly : OpenMode.readWriteCreate,
    );
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = ${forImport ? 'OFF' : 'NORMAL'}');
    db.execute('PRAGMA temp_store = MEMORY');
    db.execute('PRAGMA busy_timeout = 10000');
    // Every issue dirties pages all over `book`, so without a limit the WAL
    // grows to the size of the database between checkpoints.
    db.execute('PRAGMA journal_size_limit = 67108864');
    if (forImport) db.execute('PRAGMA cache_size = -262144');
    if (!readOnly) _migrate(db);
    return MasterGamesDb._(db, path);
  }

  /// `<support>/master_games.db`.
  static Future<String> defaultPath() async {
    final dir = await AppPaths.supportDirectory();
    return '${dir.path}${Platform.pathSeparator}master_games.db';
  }

  void close() => _db.close();

  Database get raw => _db;

  static const int _schemaVersion = 3;

  static void _migrate(Database db) {
    final v = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (v >= _schemaVersion) return;
    if (v == 1) {
      // v1 stored movetext as TEXT.  This is a rebuildable cache, so the
      // cheapest correct migration is to start over: dropping `twic_issues`
      // makes the next sync re-download everything.
      db.execute('''
        DROP TABLE IF EXISTS book;
        DROP TABLE IF EXISTS games;
        DROP TABLE IF EXISTS twic_issues;
      ''');
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS games(
        id INTEGER PRIMARY KEY,
        twic INTEGER,
        event TEXT NOT NULL DEFAULT '',
        site TEXT NOT NULL DEFAULT '',
        date TEXT NOT NULL DEFAULT '',
        round TEXT NOT NULL DEFAULT '',
        white TEXT NOT NULL DEFAULT '',
        black TEXT NOT NULL DEFAULT '',
        result TEXT NOT NULL DEFAULT '*',
        white_elo INTEGER,
        black_elo INTEGER,
        white_fide INTEGER,
        black_fide INTEGER,
        eco TEXT NOT NULL DEFAULT '',
        ply_count INTEGER NOT NULL DEFAULT 0,
        movetext BLOB NOT NULL,
        authority INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS games_twic ON games(twic);
      CREATE INDEX IF NOT EXISTS games_white ON games(white COLLATE NOCASE);
      CREATE INDEX IF NOT EXISTS games_black ON games(black COLLATE NOCASE);
      CREATE INDEX IF NOT EXISTS games_white_fide ON games(white_fide);
      CREATE INDEX IF NOT EXISTS games_black_fide ON games(black_fide);
      CREATE INDEX IF NOT EXISTS games_date ON games(date);
      CREATE INDEX IF NOT EXISTS games_eco ON games(eco);

      CREATE TABLE IF NOT EXISTS book(
        pos INTEGER NOT NULL,
        move TEXT NOT NULL,
        ply INTEGER NOT NULL,
        games INTEGER NOT NULL,
        white_wins INTEGER NOT NULL,
        draws INTEGER NOT NULL,
        black_wins INTEGER NOT NULL,
        elo_sum INTEGER NOT NULL,
        elo_n INTEGER NOT NULL,
        max_elo INTEGER NOT NULL,
        last_year INTEGER NOT NULL,
        top_game INTEGER NOT NULL,
        recent_game INTEGER NOT NULL,
        top_classical_game INTEGER NOT NULL DEFAULT 0,
        classical_max_elo INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(pos, move)
      ) WITHOUT ROWID;

      CREATE TABLE IF NOT EXISTS twic_issues(
        issue INTEGER PRIMARY KEY,
        games INTEGER NOT NULL,
        imported_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS meta(
        key TEXT PRIMARY KEY,
        value BLOB NOT NULL
      );
    ''');
    _migrateToV3(db, from: v);
    db.execute('PRAGMA user_version = $_schemaVersion');
  }

  /// v2 → v3: citation authority.
  ///
  /// A five-year TWIC import is over half online play, so `top_game` — the
  /// highest-rated game that played a move — cites a Titled Tuesday blitz
  /// game more often than not.  v3 records the strongest *classical
  /// over-the-board* game alongside it so a citation can prefer one.
  ///
  /// Unlike the v1 migration this must not drop anything: the games are hours
  /// of downloading.  The `games` column is backfilled here from headers
  /// already stored; the book columns start empty and are filled by
  /// `rebuildClassicalCitations` (master_book_rebuild.dart), which has to
  /// replay movetext and so is a deliberate maintenance pass rather than
  /// something an app launch does.
  static void _migrateToV3(Database db, {required int from}) {
    if (from >= 3) return;
    if (!_hasColumn(db, 'games', 'authority')) {
      db.execute(
        'ALTER TABLE games ADD COLUMN authority INTEGER NOT NULL DEFAULT 0',
      );
      db.execute('UPDATE games SET authority = $kAuthoritySqlExpression');
    }
    if (!_hasColumn(db, 'book', 'top_classical_game')) {
      db.execute(
        'ALTER TABLE book ADD COLUMN top_classical_game '
        'INTEGER NOT NULL DEFAULT 0',
      );
      db.execute(
        'ALTER TABLE book ADD COLUMN classical_max_elo '
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  static bool _hasColumn(Database db, String table, String column) {
    for (final r in db.select('PRAGMA table_info($table)')) {
      if (r.columnAt(1) == column) return true;
    }
    return false;
  }

  // ── Movetext codec ─────────────────────────────────────────────────────

  MovetextCodec? _codec;

  /// The codec for this database's movetext.  The dictionary is written by
  /// the first import, possibly after this connection was opened, so a
  /// missing one is looked up again next time rather than cached.
  MovetextCodec get codec {
    final c = _codec;
    if (c != null) return c;
    final dict = metaBlob(kMovetextDictKey);
    if (dict == null) return MovetextCodec.plain;
    return _codec = MovetextCodec(dict);
  }

  List<int>? metaBlob(String key) {
    final ResultSet rows;
    try {
      rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    } on SqliteException {
      return null; // read-only handle on a pre-`meta` file
    }
    if (rows.isEmpty) return null;
    return rows.first.columnAt(0) as List<int>;
  }

  void putMetaBlob(String key, List<int> value) {
    _db.execute('INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)', [
      key,
      value,
    ]);
    if (key == kMovetextDictKey) _codec = null;
  }

  // ── Reads ──────────────────────────────────────────────────────────────

  MasterGamesStats stats() {
    final g = _db.select('SELECT COUNT(*) FROM games').first.columnAt(0) as int;
    final row = _db
        .select('SELECT COUNT(*), MIN(issue), MAX(issue) FROM twic_issues')
        .first;
    final file = File(path);
    return MasterGamesStats(
      games: g,
      issues: row.columnAt(0) as int,
      firstIssue: row.columnAt(1) as int?,
      lastIssue: row.columnAt(2) as int?,
      fileBytes: file.existsSync() ? file.lengthSync() : 0,
    );
  }

  Set<int> importedIssues() => {
    for (final r in _db.select('SELECT issue FROM twic_issues'))
      r.columnAt(0) as int,
  };

  /// Master moves from [fen], most played first.
  List<BookMove> bookMoves(String fen) {
    final rows = _db.select(
      'SELECT move, games, white_wins, draws, black_wins, elo_sum, elo_n, '
      'max_elo, last_year, top_game, recent_game, top_classical_game '
      'FROM book WHERE pos = ? ORDER BY games DESC, max_elo DESC',
      [positionKey(fen)],
    );
    return [
      for (final r in rows)
        BookMove(
          uci: r.columnAt(0) as String,
          games: r.columnAt(1) as int,
          whiteWins: r.columnAt(2) as int,
          draws: r.columnAt(3) as int,
          blackWins: r.columnAt(4) as int,
          averageElo: (r.columnAt(6) as int) == 0
              ? null
              : (r.columnAt(5) as int) / (r.columnAt(6) as int),
          maxElo: r.columnAt(7) as int,
          lastYear: r.columnAt(8) as int,
          topGameId: r.columnAt(9) as int,
          recentGameId: r.columnAt(10) as int,
          topClassicalGameId: r.columnAt(11) as int,
        ),
    ];
  }

  MasterGame? game(int id) {
    final rows = _db.select('SELECT $_gameCols FROM games WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return _gameFromRow(rows.first, codec);
  }

  /// Games where [name] (case-insensitive prefix, `Surname` or
  /// `Surname,Ini`) played either colour, newest first.
  List<MasterGame> gamesByPlayer(String name, {int limit = 200}) {
    final q = '${name.trim()}%';
    final rows = _db.select(
      'SELECT $_gameCols FROM games '
      'WHERE white LIKE ? COLLATE NOCASE OR black LIKE ? COLLATE NOCASE '
      'ORDER BY date DESC LIMIT ?',
      [q, q, limit],
    );
    final c = codec;
    return [for (final r in rows) _gameFromRow(r, c)];
  }

  /// Games matching [query].
  ///
  /// Every filtered column is indexed, so this is a range scan rather than a
  /// walk over two million rows — with one exception: an event substring has
  /// no index and falls back to a scan, which is why the browser only sends
  /// one alongside something narrower.
  List<MasterGame> searchGames(MasterGamesQuery query) {
    final filter = buildMasterGamesWhere(query);
    final rows = _db.select(
      'SELECT $_gameCols FROM games'
      '${filter.where.isEmpty ? '' : ' WHERE ${filter.where}'}'
      ' ORDER BY ${masterGamesOrderBy(query.order)} LIMIT ? OFFSET ?',
      [...filter.args, query.limit, query.offset],
    );
    final c = codec;
    return [for (final r in rows) _gameFromRow(r, c)];
  }

  /// How many games [query] matches, ignoring its limit and offset.
  int countGames(MasterGamesQuery query) {
    final filter = buildMasterGamesWhere(query);
    return _db
            .select(
              'SELECT COUNT(*) FROM games'
              '${filter.where.isEmpty ? '' : ' WHERE ${filter.where}'}',
              filter.args,
            )
            .first
            .columnAt(0)
        as int;
  }

  /// The newest imported issues, newest first, with their game counts.
  List<TwicIssueSummary> recentIssues({int limit = 12}) {
    final rows = _db.select(
      'SELECT issue, games FROM twic_issues ORDER BY issue DESC LIMIT ?',
      [limit],
    );
    return [
      for (final r in rows)
        TwicIssueSummary(
          issue: r.columnAt(0) as int,
          games: r.columnAt(1) as int,
        ),
    ];
  }

  static const _gameCols =
      'id, twic, event, site, date, round, white, black, result, '
      'white_elo, black_elo, white_fide, black_fide, eco, ply_count, movetext';

  static MasterGame _gameFromRow(Row r, MovetextCodec codec) => MasterGame(
    id: r.columnAt(0) as int,
    twicIssue: r.columnAt(1) as int?,
    event: r.columnAt(2) as String,
    site: r.columnAt(3) as String,
    date: r.columnAt(4) as String,
    round: r.columnAt(5) as String,
    white: r.columnAt(6) as String,
    black: r.columnAt(7) as String,
    result: r.columnAt(8) as String,
    whiteElo: r.columnAt(9) as int?,
    blackElo: r.columnAt(10) as int?,
    whiteFideId: r.columnAt(11) as int?,
    blackFideId: r.columnAt(12) as int?,
    eco: r.columnAt(13) as String,
    plyCount: r.columnAt(14) as int,
    movetext: codec.decode(r.columnAt(15) as List<int>),
  );
}
