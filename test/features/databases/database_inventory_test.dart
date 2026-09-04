import 'dart:io';

import 'package:chess_auto_prep/features/databases/services/database_inventory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The inventory exists because every panel used to measure the one file it
/// knew the name of, and the sum of those numbers was smaller than the
/// directory they all sat in. These tests pin the two halves of the fix: a
/// store is its sidecars too, and a file no store claims is reported rather
/// than silently carried.

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('inventory-test'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String name, int bytes) =>
      File(p.join(root.path, name)).writeAsBytesSync(List.filled(bytes, 0));

  test('a store counts its SQLite sidecars, not just the database', () async {
    write('master_games.db', 1000);
    write('master_games.db-wal', 500);
    write('master_games.db-shm', 100);

    final inventory = await readDatabaseInventory(supportDirectory: root.path);
    final master = inventory[StoreLabels.masterGames];

    expect(master, isNotNull);
    expect(master!.bytes, 1600);
    expect(master.paths, hasLength(3));
  });

  test('a store with no files on disk is not reported at all', () async {
    write('app_games.db', 10);

    final inventory = await readDatabaseInventory(supportDirectory: root.path);

    expect(inventory[StoreLabels.yourGames], isNotNull);
    expect(inventory[StoreLabels.masterGames], isNull);
    expect(inventory[StoreLabels.evalCache], isNull);
  });

  test(
    'an upgrade backup is a leftover, and its size is reclaimable',
    () async {
      write('master_games.db', 100);
      write('master_games.db.pre-v3.bak', 900);

      final inventory = await readDatabaseInventory(
        supportDirectory: root.path,
      );

      expect(inventory.strays, hasLength(1));
      expect(inventory.strays.single.name, 'master_games.db.pre-v3.bak');
      expect(inventory.strayBytes, 900);
      // The number the page leads with has to cover both, or it repeats the
      // bug: 100 bytes reported against 1000 bytes on disk.
      expect(inventory.totalBytes, 1000);
    },
  );

  test(
    'settings and unrecognised files are never offered for deletion',
    () async {
      write('shared_preferences.json', 50);
      write('something_we_have_never_heard_of', 50);

      final inventory = await readDatabaseInventory(
        supportDirectory: root.path,
      );

      expect(inventory.strays, isEmpty);
    },
  );

  test('a claimed sidecar is not also counted as a leftover', () async {
    write('eval_cache.db', 10);
    write('eval_cache.db-wal', 10);

    final inventory = await readDatabaseInventory(supportDirectory: root.path);

    expect(inventory[StoreLabels.evalCache]!.bytes, 20);
    expect(inventory.strays, isEmpty);
  });

  test('leftovers are listed largest first', () async {
    write('a.bak', 10);
    write('b.bak', 900);
    write('c.tmp', 100);

    final inventory = await readDatabaseInventory(supportDirectory: root.path);

    expect(inventory.strays.map((s) => s.name), ['b.bak', 'c.tmp', 'a.bak']);
  });

  test(
    'removing a leftover quarantines it; anything else is refused',
    () async {
      write('master_games.db.pre-v3.bak', 900);
      write('shared_preferences.json', 50);

      final inventory = await readDatabaseInventory(
        supportDirectory: root.path,
      );
      expect(await deleteStrayFile(inventory.strays.single), isTrue);

      // The guard is on the *name*, so a hand-made StrayFile pointing at
      // something the scan would never have offered is still refused.
      final forged = StrayFile(
        path: p.join(root.path, 'shared_preferences.json'),
        bytes: 50,
      );
      expect(await deleteStrayFile(forged), isFalse);
      expect(File(forged.path).existsSync(), isTrue);

      final after = await readDatabaseInventory(supportDirectory: root.path);
      expect(after.strays, isEmpty);
      expect(after.strayBytes, 0);
    },
  );

  test('a quarantined file still counts against the disk', () async {
    write('master_games.db.pre-v3.bak', 900);

    final before = await readDatabaseInventory(supportDirectory: root.path);
    expect(before.totalBytes, 900);
    await deleteStrayFile(before.strays.single);

    // Removal is a rename into `.trash`, so the bytes have not gone anywhere.
    // The page leads with this total; dropping the file from the count here
    // would make it report 900 bytes freed that the filesystem still holds.
    final after = await readDatabaseInventory(supportDirectory: root.path);
    expect(after.quarantineBytes, 900);
    expect(after.totalBytes, 900);
  });

  test('emptying the quarantine frees it for real', () async {
    write('a.bak', 400);
    write('b.tmp', 100);

    final before = await readDatabaseInventory(supportDirectory: root.path);
    for (final stray in before.strays) {
      await deleteStrayFile(stray);
    }

    expect(await emptyQuarantine(root.path), 500);

    final after = await readDatabaseInventory(supportDirectory: root.path);
    expect(after.quarantineBytes, 0);
    expect(after.totalBytes, 0);
    expect(Directory(quarantineDirFor(root.path)).existsSync(), isFalse);
  });

  test('emptying nothing is not an error', () async {
    expect(await emptyQuarantine(root.path), 0);
  });

  test(
    'a missing support directory measures to nothing rather than throwing',
    () async {
      final gone = p.join(root.path, 'not-here');

      final inventory = await readDatabaseInventory(supportDirectory: gone);

      expect(inventory.stores, isEmpty);
      expect(inventory.strays, isEmpty);
      expect(inventory.directories, isEmpty);
      expect(inventory.totalBytes, 0);
    },
  );

  test('a store configured onto another drive is measured there', () async {
    final elsewhere = Directory(p.join(root.path, 'ssd', 'lichess-evals'))
      ..createSync(recursive: true);
    File(
      p.join(elsewhere.path, 'shard-0'),
    ).writeAsBytesSync(List.filled(700, 0));
    File(
      p.join(elsewhere.path, 'shard-1'),
    ).writeAsBytesSync(List.filled(300, 0));

    final inventory = await readDatabaseInventory(
      supportDirectory: root.path,
      lichessEvalsPath: elsewhere.path,
    );

    expect(inventory[StoreLabels.lichessEvals]!.bytes, 1000);
    expect(inventory.directories, contains(elsewhere.path));
  });
}
