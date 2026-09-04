import 'dart:io';

import 'package:chess_auto_prep/services/storage/file_mutation_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late Directory root;
  late Directory trash;
  late FileMutationService mutations;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('file_mutation_service_test');
    root = Directory(p.join(temp.path, 'managed'))..createSync();
    trash = Directory(p.join(root.path, '.trash'));
    mutations = FileMutationService();
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('file deletion is a recoverable move', () async {
    final file = File(p.join(root.path, 'chapter.pgn'))
      ..writeAsStringSync('valuable');

    final receipt = await mutations.quarantineFile(
      file,
      allowedRoot: root,
      quarantineRoot: trash,
    );

    expect(receipt, isNotNull);
    expect(file.existsSync(), isFalse);
    expect(File(receipt!.quarantinedPath).readAsStringSync(), 'valuable');
  });

  test(
    'directory deletion moves the whole tree without traversing it',
    () async {
      final directory = Directory(p.join(root.path, 'French'))..createSync();
      File(p.join(directory.path, 'Main.pgn')).writeAsStringSync('valuable');

      final receipt = await mutations.quarantineDirectory(
        directory,
        allowedRoot: root,
        quarantineRoot: trash,
      );

      expect(directory.existsSync(), isFalse);
      expect(
        File(p.join(receipt!.quarantinedPath, 'Main.pgn')).readAsStringSync(),
        'valuable',
      );
    },
  );

  test('refuses the allowed root itself and every outside path', () async {
    await expectLater(
      mutations.quarantineDirectory(
        root,
        allowedRoot: root,
        quarantineRoot: trash,
      ),
      throwsA(isA<UnsafeFileMutation>()),
    );

    final outside = File(p.join(temp.path, 'outside.pgn'))
      ..writeAsStringSync('outside');
    await expectLater(
      mutations.quarantineFile(
        outside,
        allowedRoot: root,
        quarantineRoot: trash,
      ),
      throwsA(isA<UnsafeFileMutation>()),
    );
    expect(outside.readAsStringSync(), 'outside');
  });

  test('refuses a quarantine directory outside the managed root', () async {
    final file = File(p.join(root.path, 'chapter.pgn'))
      ..writeAsStringSync('valuable');

    await expectLater(
      mutations.quarantineFile(
        file,
        allowedRoot: root,
        quarantineRoot: Directory(p.join(temp.path, 'outside-trash')),
      ),
      throwsA(isA<UnsafeFileMutation>()),
    );
    expect(file.readAsStringSync(), 'valuable');
  });

  test('refuses symbolic-link targets', () async {
    if (Platform.isWindows) return;
    final outside = File(p.join(temp.path, 'outside.pgn'))
      ..writeAsStringSync('outside');
    final link = Link(p.join(root.path, 'linked.pgn'))
      ..createSync(outside.path);

    await expectLater(
      mutations.quarantineFile(
        File(link.path),
        allowedRoot: root,
        quarantineRoot: trash,
      ),
      throwsA(isA<UnsafeFileMutation>()),
    );
    expect(outside.readAsStringSync(), 'outside');
  });

  test('allows a managed root that is itself reached through a link', () async {
    if (Platform.isWindows) return;
    final linkedRoot = Link(p.join(temp.path, 'managed-link'))
      ..createSync(root.path);
    final file = File(p.join(linkedRoot.path, 'chapter.pgn'))
      ..writeAsStringSync('valuable');

    final receipt = await mutations.quarantineFile(
      file,
      allowedRoot: Directory(linkedRoot.path),
      quarantineRoot: Directory(p.join(linkedRoot.path, '.trash')),
    );

    expect(receipt, isNotNull);
    expect(file.existsSync(), isFalse);
    expect(File(receipt!.quarantinedPath).readAsStringSync(), 'valuable');
  });

  test('move refuses to overwrite an existing destination', () async {
    final source = File(p.join(root.path, 'source.pgn'))
      ..writeAsStringSync('source');
    final destination = File(p.join(root.path, 'destination.pgn'))
      ..writeAsStringSync('destination');

    await expectLater(
      mutations.moveFileNoReplace(source, destination, allowedRoot: root),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.readAsStringSync(), 'source');
    expect(destination.readAsStringSync(), 'destination');
  });
}
