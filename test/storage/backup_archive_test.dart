// The archive of kept versions, read and tidied directly.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/backups.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late BackupArchive archive;
  final id = backupId('Course/Main.pgn');
  final otherId = backupId('Course/Other.pgn');

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('backup-archive-');
    archive = BackupArchive(Directory(p.join(temporary.path, 'backups')));
  });
  tearDown(() => temporary.delete(recursive: true));

  String hashOf(String text) => sha256.convert(utf8.encode(text)).toString();

  Future<BackupVersion> keep(String id, String text) async {
    final bytes = utf8.encode(text);
    expect(
      await archive.record(
        id: id,
        documentPath: '/Documents/$id.pgn',
        bytes: bytes,
        hash: hashOf(text),
      ),
      isA<BackupRecorded>(),
    );
    return (await archive.versions(id)).first;
  }

  String pathOf(String id, BackupVersion version) =>
      p.join(archive.folderFor(id).path, version.file);

  test('a version is read only as it was listed, name and hash', () async {
    final kept = await keep(id, 'one');
    expect(utf8.decode(await archive.readVersion(id, kept)), 'one');
    final misnamed = BackupVersion(
      file: kept.file,
      time: kept.time,
      size: kept.size,
      hash: hashOf('another'),
    );
    await expectLater(
      archive.readVersion(id, misnamed),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('a version file swapped for a link is not read through it', () async {
    final kept = await keep(id, 'one');
    final copy = File(p.join(temporary.path, 'copy.pgn'))
      ..writeAsStringSync('one');
    File(pathOf(id, kept)).deleteSync();
    Link(pathOf(id, kept)).createSync(copy.path);
    await expectLater(
      archive.readVersion(id, kept),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('a version is found by the hash of its bytes, and only by it', () async {
    await keep(id, 'one');
    await keep(id, 'two');
    expect(
      (await archive.versionWithHash(id, hashOf('one')))?.hash,
      hashOf('one'),
    );
    expect(await archive.versionWithHash(id, hashOf('three')), isNull);
  });

  group('pruning past the newest 100', () {
    Future<List<BackupVersion>> keepMany() async {
      for (var i = 0; i < 102; i++) {
        await keep(id, 'version $i');
      }
      return (await archive.versions(id)).reversed.toList();
    }

    final later = DateTime.now().toUtc().add(const Duration(days: 1));

    test('forgets a version whose file is already gone', () async {
      final oldest = await keepMany();
      File(pathOf(id, oldest[0])).deleteSync();
      expect(await archive.prune(id, olderThan: later), 2);
      expect(await archive.versions(id), hasLength(100));
    });

    test('leaves a version that is a link, and what it points at', () async {
      final oldest = await keepMany();
      final elsewhere = File(p.join(temporary.path, 'elsewhere.pgn'))
        ..writeAsStringSync('mine');
      File(pathOf(id, oldest[0])).deleteSync();
      Link(pathOf(id, oldest[0])).createSync(elsewhere.path);
      expect(await archive.prune(id, olderThan: later), 1);
      final files = {for (final v in await archive.versions(id)) v.file};
      expect(files, contains(oldest[0].file));
      expect(Link(pathOf(id, oldest[0])).existsSync(), isTrue);
      expect(elsewhere.readAsStringSync(), 'mine');
    });
  });

  group('a merge', () {
    final moved = <String>[];
    setUp(moved.clear);
    // Records the versions moved; the emptied folder is moved aside too.
    Future<void> move(String from, String to) async {
      if (FileSystemEntity.isDirectorySync(from)) {
        await Directory(from).rename(to);
        return;
      }
      moved.add(p.basename(from));
      await File(from).rename(to);
    }

    Future<void> merge() => archive.merge(
      fromId: id,
      toId: otherId,
      documentPath: '/Documents/Course/Other.pgn',
      operationId: 'move-1',
      move: move,
    );

    test('moves the older versions across and lists both', () async {
      final old = await keep(id, 'old');
      await keep(otherId, 'new');
      await merge();
      expect(moved, [old.file]);
      expect(await archive.versions(otherId), hasLength(2));
    });

    test('never moves a version onto a name already taken there', () async {
      final old = await keep(id, 'old');
      await keep(otherId, 'new');
      File(pathOf(otherId, old)).writeAsStringSync('taken');
      final dangling = await keep(id, 'older still');
      Link(pathOf(otherId, dangling)).createSync('/nowhere/at/all');
      await merge();
      expect(moved, isEmpty);
      expect(File(pathOf(otherId, old)).readAsStringSync(), 'taken');
    });
  });
}
