@TestOn('linux')
library;

import 'dart:io';

import 'package:chess_auto_prep/storage/atomic_write.dart';
import 'package:chess_auto_prep/storage/recovery_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Matcher _recovery(String detail) =>
    throwsA(isA<RecoveryRequired>().having((e) => e.detail, 'detail', detail));

void main() {
  late Directory root;
  setUp(() async {
    root = (await Directory.systemTemp.createTemp('recovery-files-')).absolute;
  });
  tearDown(() => root.delete(recursive: true));

  test('only normalized absolute paths are admitted', () async {
    final real = await Directory(p.join(root.path, 'a')).create();
    for (final path in ['${real.path}/../a', '${real.path}\u0000']) {
      await expectLater(
        requireSameFileSystem(path, real.path, directory: true),
        _recovery('Filesystem admission needs normalized absolute paths.'),
        reason: path,
      );
    }
  });

  group('a staged copy a stopped write left', () {
    late String target;
    setUp(() => target = p.join(root.path, 'Main.pgn'));

    test('is removed when it is a file', () async {
      File(temporaryPathFor(target)).writeAsStringSync('half');
      await discardLeftoverStage(target);
      expect(
        FileSystemEntity.typeSync(temporaryPathFor(target), followLinks: false),
        FileSystemEntityType.notFound,
      );
    });

    test('is removed as a link, leaving what it points at', () async {
      final other = File(p.join(root.path, 'other.pgn'))
        ..writeAsStringSync('x');
      Link(temporaryPathFor(target)).createSync(other.path);
      await discardLeftoverStage(target);
      expect(
        FileSystemEntity.typeSync(temporaryPathFor(target), followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(other.readAsStringSync(), 'x');
    });
  });

  test('the journal limit is what the native reader allocates', () {
    expect(journalByteLimit, 512 * 1024 * 1024);
  });

  test('a dangling link where a root should be is not taken for a folder '
      'still to be made', () {
    final link = Link(p.join(root.path, 'Support'))
      ..createSync(p.join(root.path, 'gone'));
    expect(
      () => canonicalRecoveryRoot(Directory(link.path)),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('a metadata folder under a file has no ancestry to flush', () {
    final file = File(p.join(root.path, 'file'))..writeAsStringSync('');
    expect(
      () => recoveryMetadataBoundary(Directory(p.join(file.path, 'a', 'b'))),
      throwsA(isA<RecoveryRequired>()),
    );
  });

  test('a byte-order mark is exactly its three bytes', () {
    expect(hasByteOrderMark([0xef, 0xbb, 0xbf]), isTrue);
    for (final bytes in [
      [0xee, 0xbb, 0xbf],
      [0xef, 0xba, 0xbf],
      [0xef, 0xbb, 0xbe],
      [0xef, 0xbb],
    ]) {
      expect(hasByteOrderMark(bytes), isFalse, reason: '$bytes');
    }
  });
}
