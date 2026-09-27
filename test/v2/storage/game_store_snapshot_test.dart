import 'dart:io';

import 'package:chess_auto_prep/v2/storage/game_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'game_store_test.dart' show create, insert;

void main() {
  late Directory root;
  late String path;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('archive-snapshot-');
    path = p.join(root.path, 'app_games.db');
  });
  tearDown(() => root.delete(recursive: true));

  Future<StoredGamesSource> capture() async =>
      (await SqliteGameStore(path).read({'tactics'})).source!;

  test(
    'WAL changes in selected rows invalidate; other collections do not',
    () async {
      final writer = create(path)..execute('PRAGMA wal_autocheckpoint = 0');
      addTearDown(writer.close);
      final source = await capture();
      insert(writer, 'analysis:other', 'extra', '1. a4 *');
      expect(await source.isCurrent(), isTrue);
      writer.execute(
        "UPDATE games SET pgn = '1. b4 *' WHERE collection = 'tactics' AND game_key = 'old'",
      );
      expect(await source.isCurrent(), isFalse);
      expect(await (await capture()).isCurrent(), isTrue);
    },
  );

  test(
    'collection inputs and native results are immutable snapshots',
    () async {
      create(path).close();
      final names = {'tactics'};
      final reading = SqliteGameStore(path).read(names);
      names.clear();
      final read = await reading as StoredGamesFound;
      expect(read.games.map((game) => game.key), ['new', 'old']);
      expect(read.source!.collections, ['tactics']);
      expect(() => read.source!.collections.clear(), throwsUnsupportedError);
      expect(() => read.games.clear(), throwsUnsupportedError);
    },
  );

  test('a non-file archive is unavailable rather than empty', () async {
    await Directory(path).create();
    expect(
      await SqliteGameStore(path).read({'tactics'}),
      isA<StoredGamesUnreadable>(),
    );
  });

  test(
    'absence, deletion, and schema changes cannot certify old rows',
    () async {
      final absent = await capture();
      expect(absent.fingerprint, isNull);
      expect(await absent.isCurrent(), isTrue);
      final writer = create(path);
      expect(await absent.isCurrent(), isFalse);
      final old = await capture();
      writer.execute('PRAGMA user_version = ${gameStoreSchemaVersion + 1}');
      await expectLater(old.isCurrent(), throwsA(isA<FileSystemException>()));
      writer.close();
      await File(path).delete();
      expect(await old.isCurrent(), isFalse);
    },
  );

  test('empty table and absent table remain different schema inputs', () async {
    final writer = sqlite3.open(path);
    addTearDown(writer.close);
    final absentTable = await capture();
    writer.execute(
      'CREATE TABLE games(id INTEGER, collection TEXT, game_key TEXT, pgn TEXT, played_at INTEGER)',
    );
    expect(await absentTable.isCurrent(), isFalse);
    expect(await (await capture()).isCurrent(), isTrue);
  });

  test(
    'identical logical replacement is valid without a physical identity claim',
    () async {
      create(path).close();
      final source = await capture();
      final replacement = p.join(root.path, 'replacement.db');
      create(replacement).close();
      await File(replacement).rename(path);
      expect(await source.isCurrent(), isTrue);
    },
  );

  test(
    'configured parent alias cannot silently retarget an identical archive',
    () async {
      final first = await Directory(p.join(root.path, 'first')).create();
      final second = await Directory(p.join(root.path, 'second')).create();
      create(p.join(first.path, 'app_games.db')).close();
      create(p.join(second.path, 'app_games.db')).close();
      final alias = Link(p.join(root.path, 'alias'));
      await alias.create(first.path);
      path = p.join(alias.path, 'app_games.db');
      final source = await capture();
      await alias.delete();
      await alias.create(second.path);
      expect(await source.isCurrent(), isFalse);
    },
    skip: Platform.isWindows,
  );
}
