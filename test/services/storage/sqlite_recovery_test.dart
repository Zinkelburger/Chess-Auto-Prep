@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/services/game_store/game_store.dart';
import 'package:chess_auto_prep/services/game_store/game_store_service.dart';
import 'package:chess_auto_prep/services/storage/sqlite_recovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

const _pgn = '''
[Event "Rated blitz game"]
[Site "https://lichess.org/abc12345"]
[UTCDate "2025.06.01"]
[White "me"]
[Black "them"]
[Result "1-0"]
[GameId "lichess_abc12345"]

1. e4 e5 2. Nf3 Nc6 1-0''';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sqlite_recovery_test');
  });

  tearDown(() {
    GameStoreService.instance.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String dbPath() => '${tmp.path}${Platform.pathSeparator}app_games.db';

  test('a file that is not a database is moved aside and replaced', () {
    final path = dbPath();
    File(path).writeAsStringSync('this is not a database, it is a text file');

    final store = openSqlite(path, () => GameStore.open(path), label: 'test');
    addTearDown(store.close);

    // Usable, and the damaged file was kept rather than deleted.
    store.importPgn(_pgn, collection: GameCollections.tactics);
    expect(store.count(GameCollections.tactics), 1);
    final quarantined = tmp
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('.corrupt-'))
        .toList();
    expect(quarantined, hasLength(1));
    expect(quarantined.single.readAsStringSync(), contains('not a database'));
  });

  test('a healthy database is opened untouched, with nothing quarantined', () {
    final path = dbPath();
    final first = GameStore.open(path);
    first.importPgn(_pgn, collection: GameCollections.tactics);
    first.close();

    final store = openSqlite(path, () => GameStore.open(path), label: 'test');
    addTearDown(store.close);

    expect(store.count(GameCollections.tactics), 1);
    expect(tmp.listSync().where((f) => f.path.contains('.corrupt-')), isEmpty);
  });

  test('errors that are not corruption propagate instead of wiping data', () {
    // A directory that does not exist is SQLITE_CANTOPEN: environmental, and
    // starting over on a fresh file would not help.
    final path =
        '${tmp.path}${Platform.pathSeparator}nope'
        '${Platform.pathSeparator}app_games.db';
    expect(
      () => openSqlite(path, () => GameStore.open(path), label: 'test'),
      throwsA(isA<SqliteException>()),
    );
  });

  test('isCorruptDatabase only claims the codes that mean a bad file', () {
    SqliteException ex(int code) =>
        SqliteException(extendedResultCode: code, message: 'x');
    expect(isCorruptDatabase(ex(SqlError.SQLITE_CORRUPT)), isTrue);
    expect(isCorruptDatabase(ex(SqlError.SQLITE_NOTADB)), isTrue);
    expect(isCorruptDatabase(ex(SqlError.SQLITE_BUSY)), isFalse);
    expect(isCorruptDatabase(ex(SqlError.SQLITE_CANTOPEN)), isFalse);
    expect(isCorruptDatabase(ex(SqlError.SQLITE_FULL)), isFalse);
    expect(isCorruptDatabase(Exception('not a sqlite error')), isFalse);
  });

  test('a failed open is not cached: the next call retries', () async {
    // Point the service at a path inside a directory that does not exist,
    // then create it — the second open must succeed rather than replay the
    // first failure for the rest of the session.
    final missing = '${tmp.path}${Platform.pathSeparator}later';
    final path = '$missing${Platform.pathSeparator}app_games.db';
    final service = GameStoreService(dbPathProvider: () async => path);
    GameStoreService.setTestInstance(service);

    await expectLater(service.open(), throwsA(isA<SqliteException>()));

    Directory(missing).createSync(recursive: true);
    final store = await service.open();
    expect(store.count(GameCollections.tactics), 0);
    service.close();
  });
}
