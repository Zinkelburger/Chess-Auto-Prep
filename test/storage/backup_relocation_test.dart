// Kept versions follow a moved document, and never decide whether it moves.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/backups.dart';
import 'package:chess_auto_prep/storage/backup_relocation.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/recovery_files.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late Directory documents;
  late BackupArchive archive;
  late String destination;
  const operation = 'move-123';

  String idOf(String relative) => backupId(relative);
  final from = idOf('Course/Old.pgn');
  final to = idOf('Course/New.pgn');

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('backup-relocation-');
    documents = await Directory(p.join(temporary.path, 'Documents')).create();
    await Directory(p.join(documents.path, 'Course')).create();
    destination = p.join(documents.path, 'Course', 'New.pgn');
    archive = BackupArchive(Directory(p.join(temporary.path, 'backups')));
  });
  tearDown(() => temporary.delete(recursive: true));

  Future<void> keep(String id, String text) async {
    final bytes = utf8.encode(text);
    expect(
      await archive.record(
        id: id,
        documentPath: '/old/$id.pgn',
        bytes: bytes,
        hash: sha256.convert(bytes).toString(),
      ),
      isA<BackupRecorded>(),
    );
  }

  BackupMove planned() => archive.planMove(
    fromId: from,
    toId: to,
    documentPath: destination,
    operationId: operation,
  );

  // What a restarted move reads back from its journal.
  BackupMove reloaded(BackupMove plan) => BackupMove.fromJson(
    jsonDecode(jsonEncode(plan.toJson())) as Map<String, Object?>,
  );

  Future<void> apply(BackupMove plan) =>
      archive.applyMove(plan, documents: documents);

  Future<Map<String, Object?>> readIndex(String id) async =>
      jsonDecode(
            await File(
              p.join(archive.folderFor(id).path, 'index.json'),
            ).readAsString(),
          )
          as Map<String, Object?>;

  Future<List<String>> texts(String id) async => [
    await for (final file in archive.folderFor(id).list())
      if (file is File && file.path.endsWith('.pgn')) await file.readAsString(),
  ];

  test('no history to move creates nothing', () async {
    await apply(reloaded(planned()));
    expect(archive.root.existsSync(), isFalse);
  });

  test('the history moves to the new id and names the new path', () async {
    await keep(from, 'one');
    await keep(from, 'two');
    final plan = reloaded(planned());
    await apply(plan);
    expect(archive.folderFor(from).existsSync(), isFalse);
    expect(await texts(to), unorderedEquals(['one', 'two']));
    expect((await readIndex(to))['path'], destination);

    // Running it again, as a restarted move does, changes nothing.
    await apply(reloaded(plan));
    expect(await texts(to), unorderedEquals(['one', 'two']));
  });

  test('a stop after the folder moved finishes the index on restart', () async {
    await keep(from, 'one');
    await archive.folderFor(from).rename(archive.folderFor(to).path);
    await apply(reloaded(planned()));
    expect((await readIndex(to))['path'], destination);
  });

  test('a damaged or missing version never fails the move', () async {
    await keep(from, 'one');
    await keep(from, 'two');
    final versions =
        archive
            .folderFor(from)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.pgn'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    await versions.first.writeAsString('damaged');
    await versions.last.delete();
    await apply(planned());
    expect(archive.folderFor(to).existsSync(), isTrue);
    expect((await readIndex(to))['path'], destination);
  });

  test('an unreadable index is left for the archive to rebuild', () async {
    await keep(from, 'one');
    await File(
      p.join(archive.folderFor(from).path, 'index.json'),
    ).writeAsString('not json');
    await apply(planned());
    expect(await texts(to), ['one']);
    expect(await archive.newest(to), isNotNull);
  });

  test(
    'a history already under the target id becomes a deleted chapter',
    () async {
      await keep(to, 'someone else');
      await keep(from, 'mine');
      await apply(planned());

      expect(await texts(to), ['mine']);
      final listing = await listDeleted(documents) as DeletedChapters;
      final chapter = listing.chapters.single;
      expect(chapter.name, 'New');
      expect(await File(chapter.path).readAsString(), 'someone else');
      final displaced = backupId(
        p.relative(chapter.path, from: documents.path),
      );
      expect(await texts(displaced), ['someone else']);
      expect((await readIndex(displaced))['path'], chapter.path);

      // A restart does not offer it twice.
      await apply(planned());
      expect((await listDeleted(documents) as DeletedChapters).chapters, [
        isA<DeletedChapter>(),
      ]);
    },
  );

  test('a displaced history leaves Support only once its folder is flushed '
      'and the move is flushed before it returns', () async {
    await keep(to, 'someone else');
    await keep(from, 'mine');
    final course = p.join(documents.path, 'Course');
    final steps = <String>[];
    final relocation = BackupRelocation(
      archive.root,
      documents: documents,
      synchronize: (directory) async => steps.add('flush $directory'),
      move: (source, target) async {
        steps.add('move $source');
        await Directory(source).rename(target);
      },
    );
    expect(await relocation.applyMove(planned()), isTrue);
    final flushed = steps.indexOf('flush $course');
    final displaced = steps.indexWhere((step) => step.endsWith('/$to'));
    expect(flushed, isNonNegative);
    expect(displaced, greaterThan(flushed));
    expect(steps.last, endsWith('flush ${archive.root.path}'));
  }, skip: Platform.isWindows ? 'no directory flush on Windows' : false);

  // What Windows answers while antivirus or the indexer holds a kept file.
  FileSystemException refused(String path, int code) => FileSystemException(
    'Exclusive path move failed',
    path,
    OSError('', code),
  );

  test('a brief sharing violation is waited out', () async {
    await keep(from, 'one');
    var attempts = 0;
    final relocation = BackupRelocation(
      archive.root,
      documents: documents,
      windows: true,
      move: (source, target) async {
        if (attempts++ < 2) throw refused(target, 32);
        await Directory(source).rename(target);
      },
    );
    expect(await relocation.applyMove(planned()), isTrue);
    expect(attempts, 3);
    expect(archive.folderFor(from).existsSync(), isFalse);
    expect(await texts(to), ['one']);
    expect((await readIndex(to))['path'], destination);
  });

  test('a lasting failure is reported and leaves the history whole', () async {
    await keep(from, 'one');
    var attempts = 0;
    final relocation = BackupRelocation(
      archive.root,
      documents: documents,
      windows: true,
      move: (source, target) async {
        attempts++;
        throw refused(target, 2);
      },
    );
    expect(await relocation.applyMove(planned()), isFalse);
    expect(attempts, 1);
    expect(await texts(from), ['one']);
    expect(archive.folderFor(to).existsSync(), isFalse);
  });

  test('a lasting refusal is not waited out past a shared deadline', () async {
    await keep(from, 'one');
    var attempts = 0;
    final relocation = BackupRelocation(
      archive.root,
      documents: documents,
      windows: true,
      move: (source, target) async {
        attempts++;
        throw refused(target, 32);
      },
    );
    expect(
      await relocation.applyMove(planned(), retryUntil: DateTime.now()),
      isFalse,
    );
    expect(attempts, 1);
    expect(await texts(from), ['one']);
  });

  Future<List<String>> newestFirst(String id) async => [
    for (final version in await archive.versions(id))
      utf8.decode(await archive.readVersion(id, version)),
  ];

  test('an owed history merges with the versions kept since', () async {
    await keep(from, 'one');
    await keep(from, 'two');
    await keep(to, 'three');
    expect(
      await archive.applyMove(planned(), documents: documents, merge: true),
      isTrue,
    );
    expect(archive.folderFor(from).existsSync(), isFalse);
    expect(await newestFirst(to), ['three', 'two', 'one']);
    expect((await readIndex(to))['path'], destination);
    expect(
      Directory(
        p.join(documents.path, 'Course', '.cap-pgn-history'),
      ).existsSync(),
      isFalse,
    );
    expect(await archive.versions(from), isEmpty);
  });

  test('a merge stopped half way finishes the same on the next try', () async {
    await keep(from, 'one');
    await keep(from, 'two');
    await keep(to, 'three');
    var moves = 0;
    final stopped = BackupRelocation(
      archive.root,
      documents: documents,
      move: (source, target) async {
        if (moves++ > 0) throw refused(target, 2);
        await File(source).rename(target);
      },
    );
    expect(await stopped.applyMove(planned(), merge: true), isFalse);
    expect(
      await archive.applyMove(planned(), documents: documents, merge: true),
      isTrue,
    );
    expect(archive.folderFor(from).existsSync(), isFalse);
    expect(await newestFirst(to), ['three', 'two', 'one']);
  });

  test('earlier journals with a full inventory still read back', () {
    final plan = BackupMove.fromJson({
      'version': 1,
      'operationId': operation,
      'rootPath': archive.root.path,
      'rootIdentity': '1:2:3',
      'fromId': from,
      'toId': to,
      'documentPath': destination,
      'asideName': '$to.superseded-$operation',
      'source': null,
      'destination': null,
      'indexAfter': null,
    });
    expect(plan.fromId, from);
    expect(plan.toId, to);
  });

  test('a plan with invalid ids is refused', () {
    expect(
      () => archive.planMove(
        fromId: 'not-an-id',
        toId: to,
        documentPath: destination,
        operationId: operation,
      ),
      throwsA(isA<RecoveryRequired>()),
    );
  });
}
