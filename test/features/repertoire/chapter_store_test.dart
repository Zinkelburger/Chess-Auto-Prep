import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chess_auto_prep/features/repertoire/services/chapter_store.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';

/// Storage backed by a real temp directory for the parts that matter here
/// (does a file exist, what got written), with the rest left unimplemented.
class _TempStorage implements StorageService {
  _TempStorage(this.root);

  final String root;
  bool failWrites = false;

  @override
  String parentPath(String filePath) => p.dirname(filePath);

  @override
  String chapterFilePath(String repertoireDirPath, String chapterName) =>
      p.join(repertoireDirPath, '$chapterName.pgn');

  @override
  Future<bool> fileExists(String path) async => File(path).existsSync();

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (failWrites) throw const FileSystemException('disk full');
    if (createOnly && File(path).existsSync()) {
      throw const FileSystemException('file exists');
    }
    File(path).writeAsStringSync(content);
  }

  @override
  Future<List<RepertoireMetadata>> listChapters(String dir) async {
    return Directory(dir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.pgn'))
        .map(
          (f) => RepertoireMetadata(
            filePath: f.path,
            name: p.basenameWithoutExtension(f.path),
            lastModified: f.lastModifiedSync(),
          ),
        )
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

void main() {
  late Directory dir;
  late String folder;
  late _TempStorage storage;
  late ChapterStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('chapter_store_test');
    folder = p.join(dir.path, 'MyRep');
    Directory(folder).createSync();
    storage = _TempStorage(dir.path);
    store = ChapterStore(storage: storage);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('create', () {
    test('writes a chapter with a colour header', () async {
      final result = await store.create(
        folderPath: folder,
        name: 'Kings Gambit',
        isWhite: true,
        now: DateTime(2026, 7, 27, 15, 4, 5),
      );

      expect(result.succeeded, isTrue);
      expect(result.chapter!.name, 'Kings Gambit');
      expect(result.chapter!.gameCount, 0);

      final written = File(result.chapter!.filePath).readAsStringSync();
      expect(
        written,
        '// Kings Gambit\n'
        '// Color: White\n'
        '// Created on 2026-07-27 15:04:05\n\n',
      );
    });

    test('records the black side too — the header is how colour survives', () {
      expect(
        ChapterStore.chapterHeader(
          name: 'Caro-Kann',
          isWhite: false,
          createdAt: DateTime(2026, 1, 1),
        ),
        contains('// Color: Black'),
      );
    });

    test(
      'refuses a name already on disk, leaving the file untouched',
      () async {
        await store.create(folderPath: folder, name: 'Main', isWhite: true);
        final before = File(p.join(folder, 'Main.pgn')).readAsStringSync();

        final result = await store.create(
          folderPath: folder,
          name: 'Main',
          isWhite: false,
        );

        expect(result.succeeded, isFalse);
        expect(result.error, 'That chapter already exists.');
        expect(File(p.join(folder, 'Main.pgn')).readAsStringSync(), before);
      },
    );

    test('reports a failed write instead of throwing', () async {
      storage.failWrites = true;

      final result = await store.create(
        folderPath: folder,
        name: 'Main',
        isWhite: true,
      );

      expect(result.succeeded, isFalse);
      expect(result.error, 'Could not create chapter.');
    });
  });

  group('folder', () {
    test('siblings are the chapters beside the active one', () async {
      await store.create(folderPath: folder, name: 'Main', isWhite: true);
      await store.create(folderPath: folder, name: 'Sideline', isWhite: true);

      final siblings = await store.listSiblings(p.join(folder, 'Main.pgn'));

      expect(siblings.map((c) => c.name).toList()..sort(), [
        'Main',
        'Sideline',
      ]);
    });

    test('folder metadata names the repertoire, not the chapter', () {
      final meta = store.folderMetadata(p.join(folder, 'Main.pgn'));
      expect(meta.name, 'MyRep');
      expect(meta.filePath, folder);
    });
  });
}
