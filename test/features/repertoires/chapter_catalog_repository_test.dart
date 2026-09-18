import 'dart:io';

import 'package:chess_auto_prep/chess_core/pgn/repertoire_pgn_text.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Storage extends IOStorageService {
  _Storage(Directory root)
    : super(documentsRoot: root, supportRoot: root, repertoiresRoot: root);
  bool failReads = false;
  @override
  Future<String?> readFile(String path) {
    if (failReads) throw const FileSystemException('unreadable source');
    return super.readFile(path);
  }
}

void main() {
  late Directory root;
  late _Storage storage;
  late LegacyRepertoireCatalogRepository catalog;
  setUp(() {
    root = Directory.systemTemp.createTempSync('chapter-catalog-');
    storage = _Storage(root);
    catalog = LegacyRepertoireCatalogRepository(
      storage,
      documents: NativePgnDocumentStore(),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('pure chapter header preserves course, color and exact date format', () {
    expect(
      chapterHeader(
        name: 'Caro',
        isWhite: false,
        createdAt: DateTime(2026, 7, 27, 15, 4, 5),
        courseChapter: 'Advance',
      ),
      '// Caro\n// Color: Black\n// Chapter: Advance\n// Created on 2026-07-27 15:04:05\n\n',
    );
  });

  test(
    'exclusive native create acknowledges path and persisted color',
    () async {
      final result = await catalog.createChapter(
        folderPath: root.path,
        name: 'Caro',
        isWhite: false,
      );
      final saved = result as PgnSaved;
      expect(saved.after.path, p.join(root.path, 'Caro.pgn'));
      expect(File(saved.after.path).readAsStringSync(), saved.after.content);
      expect(saved.after.content, contains('// Color: Black'));
      expect(saved.after.revision.nativeIdentity, isNotEmpty);
      expect(
        (await catalog.listChapters(root.path)).single.filePath,
        saved.after.path,
      );
    },
  );

  test(
    'picker creation inherits folder color; empty folder defaults White',
    () async {
      final first =
          await catalog.createChapter(folderPath: root.path, name: 'First')
              as PgnSaved;
      expect(first.after.content, contains('// Color: White'));
      File(first.after.path).writeAsStringSync('// Color: Black\n');
      final second =
          await catalog.createChapter(folderPath: root.path, name: 'Second')
              as PgnSaved;
      expect(second.after.content, contains('// Color: Black'));
    },
  );

  test(
    'creation rejects case-insensitive and trimmed duplicate names',
    () async {
      File(p.join(root.path, 'Main.pgn')).writeAsStringSync('original');
      final result = await catalog.createChapter(
        folderPath: root.path,
        name: ' main',
        isWhite: true,
      );
      expect(result, isA<PgnNameCollision>());
      expect(
        File(p.join(root.path, 'Main.pgn')).readAsStringSync(),
        'original',
      );
      expect(File(p.join(root.path, 'main.pgn')).existsSync(), isFalse);
    },
  );

  test('unreadable inherited color fails before creating a file', () async {
    File(
      p.join(root.path, 'Existing.pgn'),
    ).writeAsStringSync('// Color: Black\n');
    storage.failReads = true;
    expect(
      await catalog.createChapter(folderPath: root.path, name: 'New'),
      isA<PgnWriteFailed>(),
    );
    expect(File(p.join(root.path, 'New.pgn')).existsSync(), isFalse);
  });

  test(
    'competing native creation after absence observation never overwrites',
    () async {
      final path = p.join(root.path, 'Main.pgn');
      var observations = 0;
      catalog = LegacyRepertoireCatalogRepository(
        storage,
        documents: NativePgnDocumentStore(
          observe: (candidate) async {
            final observed = await observeFile(candidate);
            if (candidate == path && ++observations == 2) {
              File(path).writeAsStringSync('competing writer');
            }
            return observed;
          },
        ),
      );
      expect(
        await catalog.createChapter(
          folderPath: root.path,
          name: 'Main',
          isWhite: true,
        ),
        isA<PgnNameCollision>(),
      );
      expect(File(path).readAsStringSync(), 'competing writer');
    },
  );

  test(
    'post-install uncertainty retains observed identity without replay',
    () async {
      var flushes = 0;
      catalog = LegacyRepertoireCatalogRepository(
        storage,
        documents: NativePgnDocumentStore(
          flushDirectory: (_) async {
            flushes++;
            throw const FileSystemException('directory acknowledgement lost');
          },
        ),
      );
      final result =
          await catalog.createChapter(
                folderPath: root.path,
                name: 'Maybe',
                isWhite: false,
              )
              as PgnWriteUncertain;
      expect(flushes, 1);
      expect(result.observed!.path, p.join(root.path, 'Maybe.pgn'));
      expect(result.installedRevision, isNotNull);
      expect(
        File(result.observed!.path).readAsStringSync(),
        result.observed!.content,
      );
      expect(result.observed!.content, contains('// Color: Black'));
    },
  );

  test('course sections group existing course headers without replay', () async {
    final path = p.join(root.path, 'Course.pgn');
    File(path).writeAsStringSync(
      [
        for (final section in ['One', 'One', 'Two', 'Two'])
          '[Event "Course"]\n[White "$section"]\n[Black "Line"]\n\n1. e4 e5 *\n',
      ].join('\n'),
    );
    final sections = await catalog.chapterSections(path);
    expect(sections.map((s) => s.name), ['One', 'Two']);
    expect(sections.map((s) => s.lineCount), [2, 2]);
  });
}
