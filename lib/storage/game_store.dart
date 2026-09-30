import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;

import 'recovery_files.dart';

import '../chess/tactics/game_ids.dart';

/// The old app's games database, `app_games.db` in the support folder:
/// every game it downloads or imports, in named collections, each game's
/// verbatim PGN beside its parsed headers. Read only — the old app is its
/// one writer, and reading takes no lock a writer would wait on: the old
/// app keeps the file in WAL mode, where readers and a writer do not block
/// each other. (In the rollback journal a long read would hold off a
/// commit.) A read never changes the database's bytes; after the old app
/// closed it cleanly, SQLite may leave empty `-wal` and `-shm` files beside
/// it, which is how WAL works.
///
/// Schema (the old app's `game_store_schema.dart`, version 2):
/// `games(id, collection, game_key, white, black, result, date, played_at,
/// speed, white_elo, black_elo, eco, headers_json, pgn, imported_at)`,
/// `positions(pos, game_id, ply)` for the first 30 plies, `collections`
/// and `game_trash`. Only `games` is read: the PGN is what an opening tree
/// is built from, and the position index stops at ply 30 and holds no
/// moves.

/// The version of the schema this reader knows. A file a newer app wrote
/// is not read: its columns may mean something else.
const gameStoreSchemaVersion = 2;

/// The names the old app files its collections under.
abstract final class GameCollections {
  /// The tactics archive: the user's games the old app mined for puzzles,
  /// some of which have no other copy.
  static const tactics = 'tactics';

  /// The games library's mirror of `games_library/<site>_<user>.pgn`.
  static String library(GameSite site, String username) =>
      'library:${site.name}_${_safe(username)}';

  /// Player analysis's corpus of [username]: under the key it files the
  /// player by now, and under the one older installs used.
  static List<String> analysis(GameSite site, String username) {
    final digest = sha256.convert(
      utf8.encode(jsonEncode([site.name, username.toLowerCase()])),
    );
    return [
      'analysis:player-$digest',
      'analysis:${site.name}_${_safe(username)}',
    ];
  }

  static String _safe(String username) =>
      username.toLowerCase().replaceAll(RegExp('[^a-z0-9_-]'), '_');
}

/// One game as the database keeps it.
final class StoredGame {
  const StoredGame({
    required this.collection,
    required this.key,
    required this.pgn,
  });

  final String collection;

  /// Its id within the collection: a `[GameId]`, a game address, or the
  /// players and date — whatever the old app keyed it by.
  final String key;

  final String pgn;
}

sealed class StoredGamesRead {
  const StoredGamesRead({this.source});

  /// Null only for an unavailable archive or an injected non-native reader.
  final StoredGamesSource? source;
}

/// The games of the collections asked for, newest first. [skipped] rows
/// held no PGN text a game could be read from.
final class StoredGamesFound extends StoredGamesRead {
  const StoredGamesFound(this.games, {this.skipped = 0, super.source});

  final List<StoredGame> games;
  final int skipped;
}

/// There is no database: the old app has not downloaded anything here.
final class StoredGamesAbsent extends StoredGamesRead {
  const StoredGamesAbsent({super.source});
}

/// The file is there and could not be read: busy past the wait, damaged,
/// or written by a newer app. [detail] says which, for the log.
final class StoredGamesUnreadable extends StoredGamesRead {
  const StoredGamesUnreadable(this.detail);

  final String detail;
}

/// SQLite is a real boundary: [SqliteGameStore] in the app, a scripted one
/// in tests.
abstract interface class GameStore {
  /// Every game of [collections], newest first.
  Future<StoredGamesRead> read(Set<String> collections);
}

final class SqliteGameStore implements GameStore {
  SqliteGameStore(this.path, {this.wait = const Duration(seconds: 2)});

  /// `<support>/app_games.db`.
  final String path;

  /// How long a read waits for a writer that holds the whole file.
  final Duration wait;

  /// Reads on another isolate, with a connection of its own: thousands of
  /// PGN rows are not copied out of SQLite on the isolate that draws.
  @override
  Future<StoredGamesRead> read(Set<String> collections) {
    // Snapshot caller-owned inputs before dispatching the worker.
    final file = p.normalize(p.absolute(path));
    final names = collections.toList()..sort();
    final waitMs = wait.inMilliseconds;
    return Isolate.run(() => readStoredGames(file, names, waitMs: waitMs));
  }
}

/// A logical selected-corpus proof, not a physical file-generation identity.
/// SQLite transactions supply rows (including WAL commits); database/WAL/SHM
/// bytes are never copied or hashed. An identical logical replacement is valid.
final class StoredGamesSource {
  StoredGamesSource._({
    required this.path,
    required this.canonicalPath,
    required List<String> collections,
    required this.fingerprint,
    required this.waitMs,
  }) : collections = List.unmodifiable(collections);

  final String path;
  final String canonicalPath;
  final List<String> collections;

  /// Null certifies absence, distinct from an existing empty database.
  final String? fingerprint;
  final int waitMs;

  /// Called inside the same final guard as the downloaded PGN read set.
  /// Unavailable is not an empty or unchanged archive.
  Future<bool> isCurrent() async {
    // Only the small proof crosses back: validation must not transfer a
    // second PGN corpus into the UI isolate while the recovery guard is held.
    final current = await Isolate.run(() {
      final read = readStoredGames(path, collections, waitMs: waitMs);
      if (read is StoredGamesUnreadable) {
        throw FileSystemException(read.detail, path);
      }
      return read.source!;
    });
    return current.canonicalPath == canonicalPath &&
        current.fingerprint == fingerprint &&
        _boundPath(path) == canonicalPath;
  }
}

/// Reads schema and selected games together in the worker's transaction.
StoredGamesRead readStoredGames(
  String path,
  List<String> collections, {
  required int waitMs,
}) {
  Database? db;
  try {
    final bound = _boundPath(path);
    StoredGamesSource source(String? fingerprint) {
      if (_boundPath(path) != bound) {
        throw FileSystemException('The archive path changed while read', path);
      }
      return StoredGamesSource._(
        path: path,
        canonicalPath: bound,
        collections: collections,
        fingerprint: fingerprint,
        waitMs: waitMs,
      );
    }

    final type = FileSystemEntity.typeSync(bound, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return StoredGamesAbsent(source: source(null));
    }
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('The archive is not a regular file', bound);
    }
    db = sqlite3.open(bound, mode: OpenMode.readOnly);
    db.execute('PRAGMA busy_timeout = $waitMs');
    final snapshot = _transaction(db, collections);
    return StoredGamesFound(
      snapshot.read.games,
      skipped: snapshot.read.skipped,
      source: source(snapshot.fingerprint),
    );
  } on Object catch (error) {
    return StoredGamesUnreadable('$error');
  } finally {
    // Closing also ends the read transaction on every early return.
    db?.close();
  }
}

/// Schema and rows belong to one SQLite read transaction. The caller closes
/// that connection on success, failure, or early refusal.
({StoredGamesFound read, String fingerprint}) _transaction(
  Database db,
  List<String> collections,
) {
  db.execute('BEGIN');
  final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
  if (version > gameStoreSchemaVersion) {
    throw FormatException(
      'schema version $version is newer than this app reads',
    );
  }
  final tables = db.select(
    "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'games'",
  );
  final schema = tables.isEmpty ? null : tables.single['sql'];
  final rows = tables.isEmpty || collections.isEmpty
      ? const <Row>[]
      : db.select(
          'SELECT collection, game_key, pgn FROM games '
          'WHERE collection IN (${List.filled(collections.length, '?').join(', ')}) '
          'ORDER BY played_at DESC, id DESC',
          collections,
        );
  final fingerprint = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            version,
            schema,
            for (final row in rows)
              [
                for (final key in ['collection', 'game_key', 'pgn'])
                  _value(row[key]),
              ],
          ]),
        ),
      )
      .toString();
  return (read: _rows(rows), fingerprint: fingerprint);
}

String _boundPath(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return p.normalize(File(path).resolveSymbolicLinksSync());
  }
  return p.join(
    canonicalRecoveryRoot(Directory(p.dirname(path))).path,
    p.basename(path),
  );
}

Object? _value(Object? value) => switch (value) {
  null => null,
  String() => ['text', value],
  num() => ['number', value.toString()],
  List<int>() => ['blob', base64Encode(value)],
  _ => throw const FormatException('Unsupported SQLite value'),
};

StoredGamesFound _rows(List<Row> rows) {
  final games = <StoredGame>[];
  var skipped = 0;
  for (final row in rows) {
    final (collection, key, pgn) = (
      row['collection'],
      row['game_key'],
      row['pgn'],
    );
    if (collection is String &&
        key is String &&
        pgn is String &&
        pgn.trim().isNotEmpty) {
      games.add(StoredGame(collection: collection, key: key, pgn: pgn));
    } else {
      skipped++;
    }
  }
  return StoredGamesFound(List.unmodifiable(games), skipped: skipped);
}
