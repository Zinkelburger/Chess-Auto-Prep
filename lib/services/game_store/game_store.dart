/// Your own games, in a database: every game the app downloads or imports
/// (Player Analysis downloads, the home games library, the tactics archive)
/// parsed once into `app_games.db` with indexed headers, the verbatim PGN,
/// and a position index for the opening — so "games of X as White in 2024",
/// "the game behind this tactic", or "my games reaching this position" are
/// indexed lookups, not a re-parse of a flat file.
///
/// Games are grouped into *collections*, one per store that used to be a
/// file: `tactics` (the archive behind the tactics trainer),
/// `analysis:<playerKey>` (a Player Analysis download) and
/// `library:<platform>_<user>` (the home games library).  Within a
/// collection a game is identified by its [StoredGame.key] — the `[GameId]`
/// the tactics importer injects, or the library's URL/players-date key — so
/// re-imports are idempotent.
///
/// Separate from `master_games.db` on purpose: the master database is a
/// downloadable cache that can be dropped and rebuilt; these are the user's
/// games.  Same engine (`package:sqlite3`, WAL), same position key
/// ([positionKey]), so the two can be queried side by side.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart';
import 'package:sqlite3/sqlite3.dart';

import '../games_library/game_filter.dart' show GameSpeed, classifySpeed;
import '../generation/pgn_freq_parser.dart'
    show isResultToken, tokenToSan, tokenizeMovetext;
import '../master_games/position_key.dart';
import '../pgn_parsing_service.dart' show extractHeaders, splitPgnIntoGames;
import '../storage/app_paths.dart';
import '../game_identity.dart';

/// Plies indexed into `positions` per game — the opening, where position
/// lookups are useful; deeper positions are unique to one game anyway.
const int kStoreIndexMaxPly = 30;

/// Collection names.
abstract final class GameCollections {
  static const String tactics = 'tactics';
  static String analysis(String playerKey) => 'analysis:$playerKey';
  static String library(String platformName, String usernameKey) =>
      'library:${platformName}_$usernameKey';
}

/// A stored game with its parsed headers.
class StoredGame {
  final int id;
  final String collection;
  final String key;
  final String white;
  final String black;
  final String result;
  final String date;
  final DateTime? playedAt;
  final GameSpeed speed;
  final int? whiteElo;
  final int? blackElo;
  final String eco;
  final Map<String, String> headers;
  final String pgn;

  const StoredGame({
    required this.id,
    required this.collection,
    required this.key,
    required this.white,
    required this.black,
    required this.result,
    required this.date,
    required this.playedAt,
    required this.speed,
    required this.whiteElo,
    required this.blackElo,
    required this.eco,
    required this.headers,
    required this.pgn,
  });
}

/// Header-only view of a stored game, for passes that never need the
/// movetext (counts, pruning, routing by platform).
class StoredGameSummary {
  final int id;
  final String key;
  final DateTime? playedAt;
  final Map<String, String> headers;

  const StoredGameSummary({
    required this.id,
    required this.key,
    required this.playedAt,
    required this.headers,
  });

  /// The headers rendered back as PGN tag lines — what regex-based helpers
  /// written against raw PGN text expect.
  String get headerBlock => [
    for (final e in headers.entries)
      '[${e.key} "${e.value.replaceAll('"', r'\"')}"]',
  ].join('\n');
}

/// Identity of one PGN chunk inside a collection.  Callers may supply their
/// own; the default is the `[GameId]` header when present, else the game
/// URL (`Link`/`Site`), else players + date + time, else a content hash —
/// so every chunk has a stable key and a re-import never duplicates.
typedef GameKeyOf = String Function(Map<String, String> headers, String pgn);

String defaultGameKey(Map<String, String> headers, String pgn) =>
    canonicalGameKey(headers, pgn);

class GameStoreImportResult {
  final int inserted;
  final int updated;
  final int skipped;
  const GameStoreImportResult({
    required this.inserted,
    required this.updated,
    required this.skipped,
  });
  int get total => inserted + updated;
}

/// Arguments for [importPgnIntoGameStore] (isolate entry point).
class GameStoreImportRequest {
  final String dbPath;
  final String collection;
  final String pgnText;
  final bool replace;
  final bool keepExisting;
  const GameStoreImportRequest({
    required this.dbPath,
    required this.collection,
    required this.pgnText,
    this.replace = false,
    this.keepExisting = false,
  });
}

/// Import with a private connection — safe to run via `Isolate.run` so a
/// few thousand downloaded games never parse on the UI isolate.  Uses
/// [defaultGameKey]; callers needing a custom key import on the UI side.
GameStoreImportResult importPgnIntoGameStore(GameStoreImportRequest r) {
  final store = GameStore.open(r.dbPath);
  try {
    return store.importPgn(
      r.pgnText,
      collection: r.collection,
      replace: r.replace,
      keepExisting: r.keepExisting,
    );
  } finally {
    store.close();
  }
}

class GameStore {
  final Database _db;
  final String path;

  GameStore._(this._db, this.path);

  factory GameStore.open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA foreign_keys = ON');
    // The UI connection and an importer isolate may write concurrently;
    // wait for the lock instead of failing.
    db.execute('PRAGMA busy_timeout = 10000');
    _migrate(db);
    return GameStore._(db, path);
  }

  /// `<support>/app_games.db`.
  static Future<String> defaultPath() async {
    final dir = await AppPaths.supportDirectory();
    return '${dir.path}${Platform.pathSeparator}app_games.db';
  }

  void close() => _db.close();

  Database get raw => _db;

  static const int _schemaVersion = 2;

  static void _migrate(Database db) {
    final v = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (v >= _schemaVersion) return;
    db.execute('''
      CREATE TABLE IF NOT EXISTS games(
        id INTEGER PRIMARY KEY,
        collection TEXT NOT NULL,
        game_key TEXT NOT NULL,
        white TEXT NOT NULL DEFAULT '',
        black TEXT NOT NULL DEFAULT '',
        result TEXT NOT NULL DEFAULT '*',
        date TEXT NOT NULL DEFAULT '',
        played_at INTEGER,
        speed TEXT NOT NULL DEFAULT 'unknown',
        white_elo INTEGER,
        black_elo INTEGER,
        eco TEXT NOT NULL DEFAULT '',
        headers_json TEXT NOT NULL,
        pgn TEXT NOT NULL,
        imported_at INTEGER NOT NULL,
        UNIQUE(collection, game_key)
      );
      CREATE INDEX IF NOT EXISTS games_coll_date
        ON games(collection, played_at DESC);
      CREATE INDEX IF NOT EXISTS games_white ON games(white COLLATE NOCASE);
      CREATE INDEX IF NOT EXISTS games_black ON games(black COLLATE NOCASE);

      CREATE TABLE IF NOT EXISTS positions(
        pos INTEGER NOT NULL,
        game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
        ply INTEGER NOT NULL,
        PRIMARY KEY(pos, game_id)
      ) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS positions_game ON positions(game_id);

      CREATE TABLE IF NOT EXISTS collections(
        collection TEXT PRIMARY KEY,
        updated_at INTEGER NOT NULL,
        meta_json TEXT NOT NULL DEFAULT '{}'
      );
    ''');
    db.execute(
      'CREATE TABLE IF NOT EXISTS game_trash (collection TEXT NOT NULL, game_key TEXT NOT NULL, pgn TEXT NOT NULL, deleted_at INTEGER NOT NULL)',
    );
    // Rekey under one transaction without deleting any row or its positions.
    // A temporary namespace avoids unique-key swaps during migration.
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT id, collection, headers_json, pgn FROM games',
      );
      for (final row in rows) {
        db.execute('UPDATE games SET game_key = ? WHERE id = ?', [
          'migration-v2:${row['id']}',
          row['id'],
        ]);
      }
      final used = <String>{};
      for (final row in rows) {
        final h = (jsonDecode(row['headers_json'] as String) as Map)
            .cast<String, String>();
        var key = canonicalGameKey(h, row['pgn'] as String);
        if (!used.add('${row['collection']}|$key')) {
          key = '$key:preserved-${row['id']}';
        }
        db.execute('UPDATE games SET game_key = ? WHERE id = ?', [
          key,
          row['id'],
        ]);
      }
      db.execute('PRAGMA user_version = $_schemaVersion');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ── Writes ─────────────────────────────────────────────────────────────

  /// Parse a multi-game PGN and upsert every game into [collection].
  /// Existing keys are updated (the PGN may carry new annotations) unless
  /// [keepExisting] is set, which makes the call append-only.  With
  /// [replace] the collection is cleared first.
  GameStoreImportResult importPgn(
    String multiGamePgn, {
    required String collection,
    GameKeyOf keyOf = defaultGameKey,
    bool replace = false,
    bool keepExisting = false,
  }) {
    final chunks = multiGamePgn.trim().isEmpty
        ? const <String>[]
        : splitPgnIntoGames(multiGamePgn);
    return importChunks(
      chunks,
      collection: collection,
      keyOf: keyOf,
      replace: replace,
      keepExisting: keepExisting,
    );
  }

  /// [importPgn] for already-split single-game chunks.
  GameStoreImportResult importChunks(
    List<String> chunks, {
    required String collection,
    GameKeyOf keyOf = defaultGameKey,
    bool replace = false,
    bool keepExisting = false,
  }) {
    var inserted = 0;
    var updated = 0;
    var skipped = 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    final find = _db.prepare(
      'SELECT id FROM games WHERE collection = ? AND game_key = ?',
    );
    final insert = _db.prepare(
      'INSERT INTO games(collection, game_key, white, black, result, date, '
      'played_at, speed, white_elo, black_elo, eco, headers_json, pgn, '
      'imported_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
    );
    final update = _db.prepare(
      'UPDATE games SET white=?, black=?, result=?, date=?, played_at=?, '
      'speed=?, white_elo=?, black_elo=?, eco=?, headers_json=?, pgn=?, '
      'imported_at=? WHERE id = ?',
    );
    final clearPositions = _db.prepare(
      'DELETE FROM positions WHERE game_id = ?',
    );
    final insertPosition = _db.prepare(
      'INSERT OR IGNORE INTO positions(pos, game_id, ply) VALUES(?,?,?)',
    );

    // IMMEDIATE, not deferred: this transaction reads (`find`) before it
    // writes, and a deferred transaction that upgrades from read to write
    // gets SQLITE_BUSY *without* the busy handler running — SQLite refuses
    // to retry a lock upgrade because that is how deadlocks happen.  Taking
    // the write lock up front is what makes `busy_timeout` apply.
    _db.execute('BEGIN IMMEDIATE');
    try {
      if (replace) deleteCollection(collection);
      for (final raw in chunks) {
        final chunk = raw.trim();
        if (chunk.isEmpty) continue;
        final headers = extractHeaders(chunk);
        final key = keyOf(headers, chunk);
        final existing = find.select([collection, key]);
        if (existing.isNotEmpty && keepExisting) {
          skipped++;
          continue;
        }
        final playedAt = _playedAt(headers);
        final cols = [
          headers['White'] ?? '',
          headers['Black'] ?? '',
          _result(headers['Result']),
          headers['UTCDate'] ?? headers['Date'] ?? '',
          playedAt?.millisecondsSinceEpoch,
          classifySpeed(headers['TimeControl']).name,
          int.tryParse(headers['WhiteElo'] ?? ''),
          int.tryParse(headers['BlackElo'] ?? ''),
          headers['ECO'] ?? '',
          jsonEncode(headers),
          chunk,
          now,
        ];
        final int gameId;
        if (existing.isEmpty) {
          insert.execute([collection, key, ...cols]);
          gameId = _db.lastInsertRowId;
          inserted++;
        } else {
          gameId = existing.first.columnAt(0) as int;
          update.execute([...cols, gameId]);
          clearPositions.execute([gameId]);
          updated++;
        }
        for (final (ply, fen) in _openingPositions(chunk, headers)) {
          insertPosition.execute([positionKey(fen), gameId, ply]);
        }
      }
      _db.execute(
        'INSERT INTO collections(collection, updated_at) VALUES(?, ?) '
        'ON CONFLICT(collection) DO UPDATE SET updated_at = excluded.updated_at',
        [collection, now],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      find.close();
      insert.close();
      update.close();
      clearPositions.close();
      insertPosition.close();
    }
    return GameStoreImportResult(
      inserted: inserted,
      updated: updated,
      skipped: skipped,
    );
  }

  /// Remove the games with [keys] from [collection]; returns how many.
  int deleteKeys(String collection, Iterable<String> keys) {
    var n = 0;
    final stmt = _db.prepare(
      'DELETE FROM games WHERE collection = ? AND game_key = ?',
    );
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final k in keys) {
        _db.execute(
          'INSERT INTO game_trash(collection, game_key, pgn, deleted_at) SELECT collection, game_key, pgn, ? FROM games WHERE collection = ? AND game_key = ?',
          [DateTime.now().millisecondsSinceEpoch, collection, k],
        );
        stmt.execute([collection, k]);
        n += _db.updatedRows;
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      stmt.close();
    }
    return n;
  }

  int deleteCollection(String collection) {
    _db.execute('DELETE FROM games WHERE collection = ?', [collection]);
    final n = _db.updatedRows;
    _db.execute('DELETE FROM collections WHERE collection = ?', [collection]);
    return n;
  }

  // ── Reads ──────────────────────────────────────────────────────────────

  int count(String collection) =>
      _db
              .select('SELECT COUNT(*) FROM games WHERE collection = ?', [
                collection,
              ])
              .first
              .columnAt(0)
          as int;

  int get totalGames =>
      _db.select('SELECT COUNT(*) FROM games').first.columnAt(0) as int;

  /// Collections with their game counts, largest first.
  Map<String, int> collectionCounts() => {
    for (final r in _db.select(
      'SELECT collection, COUNT(*) FROM games GROUP BY collection '
      'ORDER BY 2 DESC',
    ))
      r.columnAt(0) as String: r.columnAt(1) as int,
  };

  String? collectionFingerprint(String collection) {
    final rows = _db.select(
      'SELECT meta_json FROM collections WHERE collection = ?',
      [collection],
    );
    if (rows.isEmpty) return null;
    final value = jsonDecode(rows.first['meta_json'] as String);
    return value is Map ? value['corpusFingerprint'] as String? : null;
  }

  void setCollectionFingerprint(String collection, String fingerprint) {
    _db.execute('UPDATE collections SET meta_json = ? WHERE collection = ?', [
      jsonEncode({'corpusFingerprint': fingerprint}),
      collection,
    ]);
  }

  DateTime? collectionUpdatedAt(String collection) {
    final rows = _db.select(
      'SELECT updated_at FROM collections WHERE collection = ?',
      [collection],
    );
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(rows.first.columnAt(0) as int);
  }

  StoredGame? byKey(String collection, String key) {
    final rows = _db.select(
      'SELECT $_cols FROM games WHERE collection = ? AND game_key = ?',
      [collection, key],
    );
    return rows.isEmpty ? null : _game(rows.first);
  }

  StoredGame? byId(int id) {
    final rows = _db.select('SELECT $_cols FROM games WHERE id = ?', [id]);
    return rows.isEmpty ? null : _game(rows.first);
  }

  /// Games in [collection], in import order (oldest import first) unless
  /// [newestFirst], optionally only those played on/after [since].
  List<StoredGame> list(
    String collection, {
    bool newestFirst = false,
    DateTime? since,
    int? limit,
  }) {
    final rows = _db.select(
      'SELECT $_cols FROM games WHERE collection = ? '
      '${since == null ? '' : 'AND (played_at IS NULL OR played_at >= ?) '}'
      'ORDER BY ${newestFirst ? 'played_at DESC, id DESC' : 'id ASC'} '
      '${limit == null ? '' : 'LIMIT ?'}',
      [collection, if (since != null) since.millisecondsSinceEpoch, ?limit],
    );
    return [for (final r in rows) _game(r)];
  }

  /// Header-only rows of [collection], import order.
  List<StoredGameSummary> summaries(String collection) {
    final rows = _db.select(
      'SELECT id, game_key, played_at, headers_json FROM games '
      'WHERE collection = ? ORDER BY id ASC',
      [collection],
    );
    return [
      for (final r in rows)
        StoredGameSummary(
          id: r.columnAt(0) as int,
          key: r.columnAt(1) as String,
          playedAt: _ms(r.columnAt(2) as int?),
          headers: _headers(r.columnAt(3) as String),
        ),
    ];
  }

  /// Games that reached the position [fen] within the first
  /// [kStoreIndexMaxPly] plies, newest first; all collections unless
  /// [collection] is given.
  List<StoredGame> gamesAt(String fen, {String? collection, int limit = 100}) {
    final rows = _db.select(
      'SELECT $_cols FROM games g JOIN positions p ON p.game_id = g.id '
      'WHERE p.pos = ? ${collection == null ? '' : 'AND g.collection = ? '}'
      'ORDER BY g.played_at DESC, g.id DESC LIMIT ?',
      [positionKey(fen), ?collection, limit],
    );
    return [for (final r in rows) _game(r)];
  }

  /// Games where [name] (case-insensitive prefix) played either colour,
  /// newest first.
  List<StoredGame> byPlayer(
    String name, {
    String? collection,
    int limit = 200,
  }) {
    final q = '${name.trim()}%';
    final rows = _db.select(
      'SELECT $_cols FROM games WHERE (white LIKE ? COLLATE NOCASE '
      'OR black LIKE ? COLLATE NOCASE) '
      '${collection == null ? '' : 'AND collection = ? '}'
      'ORDER BY played_at DESC, id DESC LIMIT ?',
      [q, q, ?collection, limit],
    );
    return [for (final r in rows) _game(r)];
  }

  /// The whole collection as one PGN text, import order — for the few
  /// callers that still want a file's worth of games.
  String exportPgn(String collection) =>
      list(collection).map((g) => g.pgn).join('\n\n');

  static const _cols =
      'id, collection, game_key, white, black, result, date, played_at, '
      'speed, white_elo, black_elo, eco, headers_json, pgn';

  static StoredGame _game(Row r) => StoredGame(
    id: r.columnAt(0) as int,
    collection: r.columnAt(1) as String,
    key: r.columnAt(2) as String,
    white: r.columnAt(3) as String,
    black: r.columnAt(4) as String,
    result: r.columnAt(5) as String,
    date: r.columnAt(6) as String,
    playedAt: _ms(r.columnAt(7) as int?),
    speed: GameSpeed.values.firstWhere(
      (s) => s.name == r.columnAt(8),
      orElse: () => GameSpeed.unknown,
    ),
    whiteElo: r.columnAt(9) as int?,
    blackElo: r.columnAt(10) as int?,
    eco: r.columnAt(11) as String,
    headers: _headers(r.columnAt(12) as String),
    pgn: r.columnAt(13) as String,
  );

  static DateTime? _ms(int? v) =>
      v == null ? null : DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);

  static Map<String, String> _headers(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return const {};
    return {for (final e in decoded.entries) e.key.toString(): '${e.value}'};
  }
}

String _result(String? r) => switch (r) {
  '1-0' || '0-1' || '1/2-1/2' => r!,
  _ => '*',
};

// Hoisted: `_playedAt` runs once per imported game.
final RegExp _pgnDateRe = RegExp(r'^(\d{4})\.(\d{2})\.(\d{2})');
final RegExp _pgnTimeRe = RegExp(r'^(\d{2}):(\d{2})(?::(\d{2}))?');

/// `UTCDate`/`Date` + `UTCTime`/`Time` as a UTC instant, or null.
DateTime? _playedAt(Map<String, String> h) {
  final d = h['UTCDate'] ?? h['Date'];
  if (d == null) return null;
  final m = _pgnDateRe.firstMatch(d);
  if (m == null) return null;
  final t = h['UTCTime'] ?? h['Time'] ?? '';
  final tm = _pgnTimeRe.firstMatch(t);
  try {
    return DateTime.utc(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      tm == null ? 0 : int.parse(tm.group(1)!),
      tm == null ? 0 : int.parse(tm.group(2)!),
      tm?.group(3) == null ? 0 : int.parse(tm!.group(3)!),
    );
  } catch (_) {
    return null;
  }
}

/// (ply, FEN before the move) for the first [kStoreIndexMaxPly] plies of a
/// single-game PGN chunk.  Honours a `[FEN]` start position; stops quietly
/// at the first unparsable move.
Iterable<(int, String)> _openingPositions(
  String chunk,
  Map<String, String> headers,
) sync* {
  final lines = chunk.split('\n');
  var i = 0;
  while (i < lines.length) {
    final t = lines[i].trim();
    if (t.isEmpty || _headerLine.hasMatch(t)) {
      i++;
    } else {
      break;
    }
  }
  final movetext = lines.sublist(i).join(' ');
  final sans = <String>[];
  for (final tok in tokenizeMovetext(movetext)) {
    if (isResultToken(tok)) break;
    final san = tokenToSan(tok);
    if (san != null) sans.add(san);
    if (sans.length >= kStoreIndexMaxPly) break;
  }
  Position pos;
  final startFen = headers['FEN'];
  if (startFen != null && startFen.trim().isNotEmpty) {
    try {
      pos = Chess.fromSetup(Setup.parseFen(startFen.trim()));
    } catch (_) {
      return;
    }
  } else {
    pos = Chess.initial;
  }
  for (var ply = 0; ply < sans.length; ply++) {
    final Move? m;
    try {
      m = pos.parseSan(sans[ply]);
    } catch (_) {
      return;
    }
    if (m == null) return;
    yield (ply, pos.fen);
    pos = pos.play(m);
  }
}

final RegExp _headerLine = RegExp(r'^\[\w+\s+"');
