import 'dart:io';

import 'package:chess_auto_prep/services/storage/file_mutation_service.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late Directory documents;
  late Directory support;
  late Directory repertoires;
  late IOStorageService storage;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('io_storage_safety_test');
    documents = Directory(p.join(temp.path, 'documents'))..createSync();
    support = Directory(p.join(temp.path, 'support'))..createSync();
    repertoires = Directory(p.join(documents.path, 'repertoires'))
      ..createSync();
    storage = IOStorageService(
      documentsRoot: documents,
      supportRoot: support,
      repertoiresRoot: repertoires,
    );
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('create-only write preserves an existing file', () async {
    final file = File(p.join(documents.path, 'valuable.pgn'))
      ..writeAsStringSync('original');

    await expectLater(
      storage.writeFile(file.path, 'replacement', createOnly: true),
      throwsA(isA<FileSystemException>()),
    );

    expect(file.readAsStringSync(), 'original');
  });

  test('managed document deletion moves bytes into quarantine', () async {
    final file = File(p.join(documents.path, 'valuable.pgn'))
      ..writeAsStringSync('original');

    await storage.deleteFile(file.path);

    expect(file.existsSync(), isFalse);
    final trash = Directory(
      p.join(documents.path, '.chess_auto_prep_trash', 'files'),
    );
    final quarantined = trash.listSync().whereType<File>().single;
    expect(quarantined.readAsStringSync(), 'original');
  });

  test(
    'repertoire deletion moves its complete tree into document trash',
    () async {
      final repertoire = Directory(p.join(repertoires.path, 'French'))
        ..createSync();
      File(p.join(repertoire.path, 'Main.pgn')).writeAsStringSync('original');

      await storage.deleteRepertoireDirectory(repertoire.path);

      expect(repertoire.existsSync(), isFalse);
      final trash = Directory(
        p.join(documents.path, '.chess_auto_prep_trash', 'repertoires'),
      );
      final quarantined = trash.listSync().whereType<Directory>().single;
      expect(
        File(p.join(quarantined.path, 'Main.pgn')).readAsStringSync(),
        'original',
      );
    },
  );

  test('external deletion is refused and preserves the file', () async {
    final outside = File(p.join(temp.path, 'outside.pgn'))
      ..writeAsStringSync('outside');

    await expectLater(
      storage.deleteFile(outside.path),
      throwsA(isA<UnsafeFileMutation>()),
    );

    expect(outside.readAsStringSync(), 'outside');
  });

  test('rename refuses to overwrite an existing file', () async {
    final source = File(p.join(documents.path, 'source.pgn'))
      ..writeAsStringSync('source');
    final destination = File(p.join(documents.path, 'destination.pgn'))
      ..writeAsStringSync('destination');

    await expectLater(
      storage.renameFile(source.path, destination.path),
      throwsA(isA<FileSystemException>()),
    );

    expect(source.readAsStringSync(), 'source');
    expect(destination.readAsStringSync(), 'destination');
  });

  test(
    'generated paths reject traversal and platform-reserved names',
    () async {
      await expectLater(
        storage.repertoireDirectoryPath('../escape'),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        storage.studyFilePath('CON'),
        throwsA(isA<ArgumentError>()),
      );
      expect(File(p.join(temp.path, 'escape')).existsSync(), isFalse);
    },
  );
}
