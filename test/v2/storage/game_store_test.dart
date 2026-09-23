import 'dart:io';

import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/storage/game_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// The old app's `games` table, as its schema version 2 creates it.
const _gamesTable = '''
  CREATE TABLE games(
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
''';

/// One row of [db]'s games: [pgn] in [collection], played at [playedAt].
void insert(
  Database db,
  String collection,
  String key,
  Object pgn, {
  int? playedAt,
}) => db.execute(
  'INSERT INTO games(collection, game_key, headers_json, pgn, played_at, '
  'imported_at) VALUES(?, ?, ?, ?, ?, 0)',
  [collection, key, '{}', pgn, playedAt],
);

/// A database at [path] in the old app's shape, in [journal] mode, with
/// three games: two in `tactics`, one in a library collection.
Database create(String path, {String journal = 'WAL'}) {
  final db = sqlite3.open(path)
    ..execute('PRAGMA journal_mode = $journal')
    ..execute(_gamesTable)
    ..execute('PRAGMA user_version = $gameStoreSchemaVersion');
  insert(db, 'tactics', 'old', '1. d4 d5 *', playedAt: 1);
  insert(db, 'tactics', 'new', '1. e4 e5 *', playedAt: 2);
  insert(db, 'library:lichess_bob', 'lib', '1. c4 *', playedAt: 3);
  return db;
}

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('app_games');
    path = p.join(dir.path, 'app_games.db');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  List<String> keys(StoredGamesRead read) => [
    for (final game in (read as StoredGamesFound).games) game.key,
  ];

  test('no file is no database, not an empty one', () async {
    expect(
      await SqliteGameStore(path).read({'tactics'}),
      isA<StoredGamesAbsent>(),
    );
  });

  test('the games of the collections asked for, newest first, and no '
      'others', () async {
    create(path).close();
    final store = SqliteGameStore(path);
    expect(keys(await store.read({'tactics'})), ['new', 'old']);
    expect(keys(await store.read({'tactics', 'library:lichess_bob'})), [
      'lib',
      'new',
      'old',
    ]);
    expect(keys(await store.read({'analysis:nobody'})), isEmpty);
    expect(keys(await store.read({})), isEmpty);
  });

  test('reading while the old app is writing sees what it committed', () async {
    final writer = create(path);
    addTearDown(writer.close);
    writer.execute('BEGIN IMMEDIATE');
    insert(writer, 'tactics', 'uncommitted', '1. f4 *', playedAt: 9);
    final read = await SqliteGameStore(path).read({'tactics'});
    expect(keys(read), ['new', 'old']);
    writer.execute('COMMIT');
    expect(keys(await SqliteGameStore(path).read({'tactics'})), [
      'uncommitted',
      'new',
      'old',
    ]);
  });

  test('a database a writer holds whole past the wait is unreadable, and '
      'says so', () async {
    final writer = create(path, journal: 'DELETE');
    addTearDown(writer.close);
    writer.execute('BEGIN EXCLUSIVE');
    insert(writer, 'tactics', 'held', '1. g4 *');
    final read = await SqliteGameStore(
      path,
      wait: const Duration(milliseconds: 50),
    ).read({'tactics'});
    expect(read, isA<StoredGamesUnreadable>());
    expect((read as StoredGamesUnreadable).detail, contains('locked'));
    writer.execute('ROLLBACK');
  });

  test('a file that is not a database is unreadable, not empty', () async {
    File(path).writeAsStringSync('this is not SQLite ' * 100);
    final read = await SqliteGameStore(path).read({'tactics'});
    expect(read, isA<StoredGamesUnreadable>());
  });

  test('a database a newer app wrote is not read', () async {
    create(path)
      ..execute('PRAGMA user_version = ${gameStoreSchemaVersion + 1}')
      ..close();
    final read = await SqliteGameStore(path).read({'tactics'});
    expect((read as StoredGamesUnreadable).detail, contains('newer'));
  });

  test('a database without the games table has no games', () async {
    sqlite3.open(path)
      ..execute('CREATE TABLE other(x)')
      ..close();
    expect(keys(await SqliteGameStore(path).read({'tactics'})), isEmpty);
  });

  test('rows without PGN text are skipped and counted', () async {
    final db = create(path);
    insert(db, 'tactics', 'blank', '   ', playedAt: 5);
    insert(db, 'tactics', 'blob', [1, 2, 3], playedAt: 6);
    db.close();
    final read = await SqliteGameStore(path).read({'tactics'});
    expect(keys(read), ['new', 'old']);
    expect((read as StoredGamesFound).skipped, 2);
  });

  test('collections are named as the old app names them', () {
    expect(
      GameCollections.library(GameSite.lichess, 'Bob'),
      'library:lichess_bob',
    );
    expect(
      GameCollections.library(GameSite.chesscom, 'a.b'),
      'library:chesscom_a_b',
    );
    expect(GameCollections.analysis(GameSite.lichess, 'Bob'), [
      'analysis:player-'
          '9e00eb108b4eea18c5ce6dfbb2773be3a24695e72e3114c2e7c5ecb6f2972a48',
      'analysis:lichess_bob',
    ]);
  });
}
