import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/backup_history.dart';
import 'package:chess_auto_prep/storage/backups.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture disk;
  setUp(() async => disk = await StoreFixture.create());
  tearDown(() => disk.dispose());

  test('a new chapter has empty history without creating an archive', () async {
    final ref = disk.ref('repertoires/Main/Main.pgn');
    await disk.put(ref, oneGame('1. e4'));
    final history = BackupHistory(disk.store.recovery);
    expect(await history.versions(ref), isEmpty);
    expect(await history.prune(ref), 0);
    expect(await disk.backupFolder(ref).exists(), isFalse);
  });

  test(
    'history previews verified saved bytes and refuses a corrupted copy',
    () async {
      final ref = disk.ref('repertoires/Main/Main.pgn');
      final old = oneGame('1. e4');
      final revision = await disk.put(ref, old);
      await disk.edit(ref, oneGame('1. d4'), revision);
      final history = BackupHistory(disk.store.recovery);
      final version = (await history.versions(ref)).single;
      expect(await history.text(ref, version), old);
      await File(
        p.join(disk.backupFolder(ref).path, version.file),
      ).writeAsString('changed');
      await expectLater(history.text(ref, version), throwsFormatException);
      expect(await File(ref.path).readAsString(), oneGame('1. d4'));
    },
  );

  test(
    'explicit retention preserves newest 100, recent versions and originals',
    () async {
      final ref = disk.ref('repertoires/Main/Main.pgn');
      await disk.put(ref, oneGame('1. e4'));
      final folder = disk.backupFolder(ref);
      await folder.create(recursive: true);
      final versions = [
        for (var i = 0; i < 105; i++)
          BackupVersion(
            file: 'version-$i.pgn',
            time: DateTime.utc(2020).add(Duration(days: i)),
            size: 1,
            hash: 'a' * 64,
          ),
      ];
      for (final v in versions) {
        await File(p.join(folder.path, v.file)).writeAsString('x');
      }
      await File(p.join(folder.path, 'index.json')).writeAsString(
        jsonEncode({
          'versions': [for (final v in versions) v.toJson()],
        }),
      );
      final history = BackupHistory(disk.store.recovery);
      expect(await history.prune(ref), 5);
      final remaining = await history.versions(ref);
      expect(remaining, hasLength(100));
      // Retention must not bless an altered backup by re-hashing its bytes.
      await expectLater(
        history.text(ref, remaining.first),
        throwsFormatException,
      );
      expect(await File(ref.path).readAsString(), oneGame('1. e4'));
    },
  );
}
