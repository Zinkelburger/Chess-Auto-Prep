import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../chess/tactics/game_ids.dart';

/// The old app's games database, `app_games.db` in the support folder:
/// every game it downloads or imports, in named collections, each game's
/// verbatim PGN beside its parsed headers. Read only — the old app is its
/// one writer, and reading takes no lock a writer would wait on: the file
/// is in WAL mode, where readers and a writer do not block each other.
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
  const StoredGamesRead();
}

/// The games of the collections asked for, newest first. [skipped] rows
/// held no PGN text a game could be read from.
final class StoredGamesFound extends StoredGamesRead {
  const StoredGamesFound(this.games, {this.skipped = 0});

  final List<StoredGame> games;
  final int skipped;
}

/// There is no database: the old app has not downloaded anything here.
final class StoredGamesAbsent extends StoredGamesRead {
  const StoredGamesAbsent();
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
  Future<StoredGamesRead> read(Set<String> collections) async {
    if (!await File(path).exists()) return const StoredGamesAbsent();
    if (collections.isEmpty) return const StoredGamesFound([]);
    // Only plain values cross to the other isolate, not this object.
    final (file, names, waitMs) = (
      path,
      collections.toList(),
      wait.inMilliseconds,
    );
    return Isolate.run(() => readStoredGames(file, names, waitMs: waitMs));
  }
}

/// The games of [collections] in the database at [path], newest first:
/// [SqliteGameStore.read]'s work, run where it is called.
StoredGamesRead readStoredGames(
  String path,
  List<String> collections, {
  required int waitMs,
}) {
  final Database db;
  try {
    db = sqlite3.open(path, mode: OpenMode.readOnly);
  } on Object catch (error) {
    return StoredGamesUnreadable('$error');
  }
  try {
    db.execute('PRAGMA busy_timeout = $waitMs');
    final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version > gameStoreSchemaVersion) {
      return StoredGamesUnreadable(
        'schema version $version is newer than this app reads',
      );
    }
    final tables = db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'games'",
    );
    if (tables.isEmpty) return const StoredGamesFound([]);
    return _rows(db, collections);
  } on Object catch (error) {
    return StoredGamesUnreadable('$error');
  } finally {
    db.close();
  }
}

StoredGamesFound _rows(Database db, List<String> collections) {
  final marks = List.filled(collections.length, '?').join(', ');
  final rows = db.select(
    'SELECT collection, game_key, pgn FROM games '
    'WHERE collection IN ($marks) ORDER BY played_at DESC, id DESC',
    collections,
  );
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
  return StoredGamesFound(games, skipped: skipped);
}
