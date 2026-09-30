import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:chess_auto_prep/storage/disk_usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const _derived = ['master_games.db', 'eval_cache.db'];

void main() {
  late Directory support;
  late Directory documents;
  setUp(() async {
    final profile = await Directory.systemTemp.createTemp('v2 disk usage é 棋 ');
    support = await Directory(p.join(profile.path, 'Support')).create();
    documents = await Directory(p.join(profile.path, 'Documents')).create();
  });
  tearDown(() => support.parent.delete(recursive: true));

  Future<void> bytes(String path, int count) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(List.filled(count, 1));
  }

  test('measures databases with their sidecars and folders recursively; a '
      'missing store measures nothing', () async {
    final master = p.join(support.path, 'master_games.db');
    await bytes(master, 1000);
    await bytes('$master-wal', 200);
    await bytes('$master-shm', 30);
    final repertoires = p.join(documents.path, 'repertoires');
    await bytes(p.join(repertoires, 'KID', 'Main.pgn'), 500);
    await bytes(p.join(repertoires, 'Najdorf.pgn'), 70);

    final usage = await measureStorage(
      [
        (name: 'Master games', path: master, removable: true),
        (name: 'Repertoires', path: repertoires, removable: false),
        (
          name: 'Absent',
          path: p.join(support.path, 'nothing.db'),
          removable: false,
        ),
      ],
      support: support.path,
      derived: _derived,
    );
    expect(
      {for (final store in usage) store.name: store.bytes},
      {'Master games': 1230, 'Repertoires': 570, 'Absent': 0},
    );
  });

  test('only copies of derived databases are leftovers, never user data or '
      'the live files', () async {
    for (final name in [
      'master_games.db.pre-v3.bak',
      'master_games.db.unreadable-20260928T101500',
      'master_games.db.unreadable-20260928T101500-wal',
      'master_games.db',
      'master_games.db-wal',
      'app_games.db.bak',
      'books.json.bak',
      'settings.json',
    ]) {
      await bytes(p.join(support.path, name), 10);
    }
    final usage = await measureStorage(
      const [],
      support: support.path,
      derived: _derived,
    );
    expect(
      {for (final store in usage) store.name: (store.bytes, store.removable)},
      {
        'Leftover master_games.db.pre-v3.bak': (10, true),
        'Leftover master_games.db.unreadable-20260928T101500': (20, true),
      },
    );
  });

  test(
    'a missing support folder has no leftovers and does not throw',
    () async {
      final usage = await measureStorage(
        const [],
        support: p.join(support.path, 'gone'),
        derived: _derived,
      );
      expect(usage, isEmpty);
    },
  );

  test('deleting a derived database removes its sidecars and frees the '
      'space, including while another connection is closing', () async {
    final path = p.join(support.path, 'master_games.db');
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('CREATE TABLE t (x BLOB)');
    db.execute('INSERT INTO t VALUES (randomblob(100000))');
    expect(File('$path-wal').existsSync(), isTrue);
    // A reader that finishes shortly: on Windows its open handle refuses the
    // delete until it closes, and the delete must wait rather than fail.
    final reader = Isolate.run(() async {
      final other = sqlite3.open(path, mode: OpenMode.readOnly);
      other.select('SELECT count(*) FROM t');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      other.close();
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    db.close();
    await deleteDerivedFile(path);
    await reader;
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      expect(File('$path$suffix').existsSync(), isFalse, reason: suffix);
    }
    await deleteDerivedFile(path);
  });

  test('sizes read as people read them', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(812 * 1024), '812 KB');
    expect(formatBytes(1894039552), '1.8 GB');
    expect(formatBytes(3 * 1024 * 1024 * 1024 + 1), '3.0 GB');
  });
}
