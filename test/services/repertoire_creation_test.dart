/// One function makes a repertoire on disk, so the Create dialog and the
/// My-repertoires panel cannot write two different headers.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chess_auto_prep/services/repertoire_creation.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';

/// A temp directory standing in for the app's repertoires folder; everything
/// this function does not touch is left unimplemented.
class _TempStorage implements StorageService {
  _TempStorage(this.root);

  final String root;

  @override
  Future<String> repertoireDirectoryPath(String name) async =>
      p.join(root, name);

  @override
  String chapterFilePath(String repertoireDirPath, String chapterName) =>
      p.join(repertoireDirPath, '$chapterName.pgn');

  @override
  Future<void> writeFile(String path, String content) async {
    File(path).parent.createSync(recursive: true);
    File(path).writeAsStringSync(content);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

void main() {
  late Directory dir;
  late _TempStorage storage;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('rep_creation_test');
    storage = _TempStorage(dir.path);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('an empty repertoire is a folder with a headed Main chapter', () async {
    final created = await createRepertoire(
      name: 'Caro-Kann',
      color: 'Black',
      createdAt: DateTime(2026, 8, 21, 9, 30),
      storage: storage,
    );

    expect(created.directoryPath, p.join(dir.path, 'Caro-Kann'));
    expect(created.chapterPath, endsWith('Main.pgn'));
    expect(created.gameCount, 0);
    expect(
      File(created.chapterPath).readAsStringSync(),
      '// Main\n'
      '// Color: Black\n'
      '// Created on 2026-08-21 09:30:00\n\n',
    );
  });

  test('imported PGN lands in that chapter, under the same header', () async {
    final created = await createRepertoire(
      name: 'London',
      color: 'White',
      pgnContent: '1. d4 d5 2. Bf4 *',
      gameCount: 3,
      createdAt: DateTime(2026, 8, 21),
      storage: storage,
    );

    expect(created.gameCount, 3);
    final text = File(created.chapterPath).readAsStringSync();
    expect(text, startsWith('// Main\n// Color: White\n'));
    expect(text, endsWith('1. d4 d5 2. Bf4 *\n'));
  });

  test('the colour written is the one asked for, not guessed', () async {
    final black = await createRepertoire(
      name: 'Benko',
      color: 'Black',
      pgnContent: '1. d4 Nf6 2. c4 c5 3. d5 b5 *',
      gameCount: 1,
      storage: storage,
    );

    // The designation panel passes the section the user pressed Add in; the
    // header is what every later reader keys off.
    expect(
      File(black.chapterPath).readAsStringSync(),
      contains('// Color: Black'),
    );
  });

  test(
    'a name with no lines still reports zero, not the count given',
    () async {
      final created = await createRepertoire(
        name: 'Empty',
        color: 'White',
        gameCount: 7,
        storage: storage,
      );

      expect(created.gameCount, 0, reason: 'nothing was imported');
    },
  );
}
