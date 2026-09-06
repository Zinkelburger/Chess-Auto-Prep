/// One function makes a repertoire on disk, so the Create dialog and the
/// My-repertoires panel cannot write two different headers.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chess_auto_prep/services/repertoire_creation.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
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
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (createOnly && File(path).existsSync()) {
      throw const FileSystemException('file exists');
    }
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
      gameCount: 1,
      createdAt: DateTime(2026, 8, 21),
      storage: storage,
    );

    expect(created.gameCount, 1);
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

  test('a course export is split into one chapter file per title', () async {
    // Real file storage: the split reads the chapter back and writes the
    // new ones beside it.
    final io = IOStorageService(
      documentsRoot: dir,
      supportRoot: dir,
      repertoiresRoot: dir,
    );
    String game(String chapter, String title, String moves) =>
        '[Event "?"]\n[White "$chapter"]\n[Black "$title"]\n'
        '[Result "*"]\n\n$moves *\n\n';
    final created = await createRepertoire(
      name: 'Course',
      color: 'White',
      chapterName: 'Course',
      pgnContent:
          '${game('1) Caro-Kann', 'Main #1', '1. e4 c6 2. d4 d5 3. Nc3')}'
          '${game('1) Caro-Kann', 'Main #2', '1. e4 c6 2. d4 d5 3. Nc3 dxe4')}'
          '${game('2) French', 'Winawer', '1. e4 e6 2. d4 d5 3. Nc3 Bb4')}',
      storage: io,
    );

    expect(created.gameCount, 3);
    expect(created.chapterPaths.map(p.basename), [
      '1) Caro-Kann.pgn',
      '2) French.pgn',
    ]);
    expect(created.chapterPath, endsWith('1) Caro-Kann.pgn'));
    expect(
      File(p.join(created.directoryPath, 'Course.pgn')).existsSync(),
      isFalse,
      reason: 'every line had a chapter, so the source file is gone',
    );
    final caro = File(created.chapterPath).readAsStringSync();
    expect(caro, contains('// Color: White'));
    expect(caro, contains('// Chapter: 1) Caro-Kann'));
    expect(caro, contains('[Event "Main #1"]'), reason: 'the title is pinned');
    expect('1. e4 c6'.allMatches(caro).length, 2);
  });

  test('a study\'s variations are written as lines of their own', () async {
    final created = await createRepertoire(
      name: 'Study',
      color: 'Black',
      pgnContent:
          '[Event "Chapter 1"]\n[Result "*"]\n\n'
          '1. e4 c6 2. d4 d5 3. e5 (3. Nc3 dxe4) 3... Bf5 *\n',
      gameCount: 1,
      storage: storage,
    );

    expect(created.gameCount, 2, reason: 'the count after expansion');
    final text = File(created.chapterPath).readAsStringSync();
    expect(text, startsWith('// Main\n// Color: Black\n'));
    expect(text, isNot(contains('(')));
    expect('[Event "'.allMatches(text).length, 2);
    expect(text, contains('[Event "Chapter 1 — 3.Nc3"]'));
  });
}
