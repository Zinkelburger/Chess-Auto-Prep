import 'dart:io';

import 'package:chess_auto_prep/v2/storage/recovery_files.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late Directory folder;
  late File file;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('recovery-volume-');
    folder = await Directory(p.join(temporary.path, 'Source')).create();
    file = await File(
      p.join(folder.path, 'Main.pgn'),
    ).writeAsString('retained bytes');
  });
  tearDown(() => temporary.delete(recursive: true));

  test('native volumes accompany successful observations only', () async {
    final observedFolder = await observeDirectory(folder.path);
    final observedFile = await observeFile(file.path);
    expect(observedFolder.volume, isNotNull);
    expect(observedFile.volume, observedFolder.volume);
    expect((await observeFile(p.join(folder.path, 'missing'))).volume, isNull);
    expect((await observeDirectory(file.path)).volume, isNull);
    expect(NativeFileObservation(status: 1, error: 0).volume, isNull);
  });

  for (final directory in [false, true]) {
    for (final nested in [false, true]) {
      test(
        'same-volume admission is read-only: folder=$directory nested=$nested',
        () async {
          final destination = p.joinAll([
            temporary.path,
            if (nested) 'not-created',
            'Target',
          ]);
          await requireSameFileSystem(
            directory ? folder.path : file.path,
            destination,
            directory: directory,
          );
          expect(await file.readAsString(), 'retained bytes');
          expect(
            await FileSystemEntity.type(destination),
            FileSystemEntityType.notFound,
          );
          if (nested)
            expect(await Directory(p.dirname(destination)).exists(), isFalse);
        },
      );
    }
    test(
      'a different volume refuses before any namespace mutation: folder=$directory',
      () async {
        Directory other;
        try {
          other = await Directory('/dev/shm').createTemp('cap-volume-');
        } on FileSystemException {
          markTestSkipped('A disposable /dev/shm directory is unavailable.');
          return;
        }
        addTearDown(() => other.delete(recursive: true));
        if ((await observeDirectory(other.path)).volume ==
            (await observeDirectory(folder.path)).volume) {
          markTestSkipped('Temporary roots are on the same native volume.');
          return;
        }
        final to = p.join(other.path, 'not-created', 'Target');
        await expectLater(
          requireSameFileSystem(
            directory ? folder.path : file.path,
            to,
            directory: directory,
          ),
          throwsA(isA<RecoveryRequired>()),
        );
        expect(await file.readAsString(), 'retained bytes');
        expect(await other.list().isEmpty, isTrue);
      },
      skip: !Platform.isLinux
          ? 'Uses two disposable Linux filesystem locations.'
          : false,
    );
  }

  test('missing source and wrong native source kind are refused', () async {
    final to = p.join(temporary.path, 'Target');
    for (final source in [p.join(temporary.path, 'missing'), file.path]) {
      await expectLater(
        requireSameFileSystem(source, to, directory: true),
        throwsA(isA<RecoveryRequired>()),
      );
    }
    await expectLater(
      requireSameFileSystem(folder.path, to, directory: false),
      throwsA(isA<RecoveryRequired>()),
    );
  });

  test('an existing non-directory destination ancestor is refused', () async {
    await expectLater(
      requireSameFileSystem(
        folder.path,
        p.join(file.path, 'nested', 'Target'),
        directory: true,
      ),
      throwsA(isA<RecoveryRequired>()),
    );
    expect(await file.readAsString(), 'retained bytes');
  });

  test('a linked destination parent is refused rather than resolved', () async {
    final alias = p.join(temporary.path, 'alias');
    await Link(alias).create(folder.path);
    await expectLater(
      requireSameFileSystem(
        file.path,
        p.join(alias, 'Target'),
        directory: false,
      ),
      throwsA(isA<RecoveryRequired>()),
    );
    expect(await file.readAsString(), 'retained bytes');
  }, skip: Platform.isWindows ? 'Symlink privilege is not assumed.' : false);
}
