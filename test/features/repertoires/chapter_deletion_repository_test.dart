import 'dart:io';
import 'package:document_file_io/document_file_io.dart';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory fixture;
  late Directory docs;
  late Directory support;
  late File chapter;
  late IOStorageService storage;
  late LegacyRepertoireCatalogRepository catalog;
  const content = '// Color: Black\n\n1. e4 c5 *';
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('chapter-delete-policy-');
    docs = Directory(p.join(fixture.path, 'documents'))..createSync();
    support = Directory(p.join(fixture.path, 'support'))..createSync();
    chapter = File(p.join(docs.path, 'Main.pgn'))..writeAsStringSync(content);
    storage = IOStorageService(
      documentsRoot: docs,
      supportRoot: support,
      repertoiresRoot: docs,
    );
    catalog = LegacyRepertoireCatalogRepository(
      storage,
      documents: NativePgnDocumentStore(),
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));
  Future<PgnSnapshot> capture() async =>
      (await catalog.prepareChapterDeletion(chapter.path) as PgnOpened)
          .snapshot;

  test(
    'direct child of managed root is captured and retained exactly',
    () async {
      final before = await capture();
      final result = await catalog.deleteChapter(before) as PgnQuarantined;
      expect(chapter.existsSync(), isFalse);
      expect(
        result.retained.revision.nativeIdentity,
        before.revision.nativeIdentity,
      );
      expect(File(result.retained.path).readAsStringSync(), content);
      expect(File(result.recoveryPath).readAsStringSync(), content);
      expect(p.isWithin(docs.path, result.retained.path), isTrue);
    },
  );

  test(
    'configured root alias is trusted without changing snapshot identity',
    () async {
      final alias = Link(p.join(fixture.path, 'configured-documents'))
        ..createSync(docs.path);
      storage = IOStorageService(
        documentsRoot: Directory(alias.path),
        supportRoot: support,
        repertoiresRoot: Directory(alias.path),
      );
      catalog = LegacyRepertoireCatalogRepository(
        storage,
        documents: NativePgnDocumentStore(),
      );
      final before =
          (await catalog.prepareChapterDeletion(p.join(alias.path, 'Main.pgn'))
                  as PgnOpened)
              .snapshot;
      expect(before.path, chapter.path);
      final result = await catalog.deleteChapter(before) as PgnQuarantined;
      expect(result.before, same(before));
      expect(
        result.retained.revision.nativeIdentity,
        before.revision.nativeIdentity,
      );
    },
  );

  for (final escapes in [false, true]) {
    test(
      'rejects an untrusted parent alias ${escapes ? 'outside' : 'inside'} managed root',
      () async {
        final target = Directory(
          p.join(escapes ? fixture.path : docs.path, 'target'),
        )..createSync();
        final file = File(p.join(target.path, 'Other.pgn'))
          ..writeAsStringSync(content);
        final alias = Link(p.join(docs.path, 'alias'))..createSync(target.path);
        final result = await catalog.prepareChapterDeletion(
          p.join(alias.path, 'Other.pgn'),
        );
        expect(result, isA<PgnReadFailed>());
        expect(file.readAsStringSync(), content);
        expect(
          Directory(p.join(target.path, '.cap-pgn-history')).existsSync(),
          isFalse,
        );
      },
    );
  }

  test(
    'outside managed roots is rejected while generic document quarantine stays available',
    () async {
      final outside = File(p.join(fixture.path, 'External.pgn'))
        ..writeAsStringSync(content);
      final documents = NativePgnDocumentStore();
      final before = (await documents.open(outside.path) as PgnOpened).snapshot;
      expect(
        await catalog.prepareChapterDeletion(outside.path),
        isA<PgnReadFailed>(),
      );
      expect(await catalog.deleteChapter(before), isA<PgnQuarantineFailed>());
      expect(
        await documents.quarantine(before, allowedRoot: docs.path),
        isA<PgnQuarantineFailed>(),
      );
      expect(outside.readAsStringSync(), content);
      expect(await documents.quarantine(before), isA<PgnQuarantined>());
    },
  );

  test(
    'unsupported host refuses capture and direct removal before mutation',
    () async {
      final before = await capture();
      catalog = LegacyRepertoireCatalogRepository(
        storage,
        documents: LegacyPgnDocumentStore(storage),
      );
      final read =
          await catalog.prepareChapterDeletion(chapter.path) as PgnReadFailed;
      final result = await catalog.deleteChapter(before) as PgnQuarantineFailed;
      expect(read.error, isA<UnsupportedError>());
      expect(result.error, isA<UnsupportedError>());
      expect(chapter.readAsStringSync(), content);
    },
  );

  test('absent documents root does not block owned support file', () async {
    chapter = File(p.join(support.path, 'Owned.pgn'))
      ..writeAsStringSync(content);
    storage = IOStorageService(
      documentsRoot: Directory(p.join(fixture.path, 'absent-documents')),
      supportRoot: support,
    );
    catalog = LegacyRepertoireCatalogRepository(
      storage,
      documents: NativePgnDocumentStore(
        guardOperation: storage.guardDocumentOperation,
      ),
    );
    final before = await capture();
    expect(await catalog.deleteChapter(before), isA<PgnQuarantined>());
  });

  test('missing and unreadable are not confirmation authority', () async {
    chapter.deleteSync();
    expect(
      await catalog.prepareChapterDeletion(chapter.path),
      isA<PgnMissing>(),
    );
    chapter.writeAsStringSync(content);
    catalog = LegacyRepertoireCatalogRepository(
      storage,
      documents: NativePgnDocumentStore(
        observe: (_) async => throw const FileSystemException('read denied'),
      ),
    );
    expect(
      await catalog.prepareChapterDeletion(chapter.path),
      isA<PgnReadFailed>(),
    );
    expect(chapter.readAsStringSync(), content);
  });

  for (final sameText in [false, true]) {
    test(
      'captured deletion rejects ${sameText ? 'equal-text' : 'changed'} replacement',
      () async {
        final before = await capture();
        final previous = chapter.renameSync(p.join(docs.path, 'before.pgn'));
        chapter.writeAsStringSync(sameText ? content : '1. d4 d5 *');
        expect(
          await catalog.deleteChapter(before),
          isA<PgnQuarantineConflict>(),
        );
        expect(previous.readAsStringSync(), content);
        expect(chapter.readAsStringSync(), sameText ? content : '1. d4 d5 *');
      },
    );
  }

  test(
    'post-move uncertainty retains candidate paths without replay',
    () async {
      var flushes = 0;
      catalog = LegacyRepertoireCatalogRepository(
        storage,
        documents: NativePgnDocumentStore(
          flushDirectory: (path) async {
            if (path == docs.path) {
              flushes++;
              throw const FileSystemException('lost acknowledgement');
            }
            await syncDirectory(path);
          },
        ),
      );
      final before = await capture();
      final result =
          await catalog.deleteChapter(before) as PgnQuarantineUncertain;
      expect(flushes, 1);
      expect(chapter.existsSync(), isFalse);
      expect(result.before, same(before));
      expect(File(result.quarantinePath).readAsStringSync(), content);
      expect(File(result.recoveryPath).readAsStringSync(), content);
    },
  );
}
