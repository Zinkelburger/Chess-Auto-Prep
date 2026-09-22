import 'package:chess_auto_prep/v2/chess/pgn/repertoire_import.dart';
import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/library/library_writes.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';

void main() {
  final kid = folder('KID', ['Classical', 'Main']);
  late LibraryFixture fixture;
  late LibraryWrites writes;

  Future<void> start({ChapterRef? open}) async {
    fixture = await openLibrary([kid], open: open);
    addTearDown(fixture.dispose);
    writes = LibraryWrites(
      files: fixture.files,
      documents: fixture.store,
      session: fixture.session,
      saver: fixture.saver,
      root: '/repertoires',
    );
  }

  test('a chapter renamed while open takes the workspace with it', () async {
    final main = kid.chapters.last;
    await start(open: main);
    final result = await writes.relocate(
      main,
      const DocumentRef('/repertoires/KID/Najdorf.pgn'),
    );
    expect(result, isA<LibraryDone>());
    expect(fixture.session.source?.path, '/repertoires/KID/Najdorf.pgn');
    expect(fixture.textAt('/repertoires/KID/Najdorf.pgn'), isNotNull);
    expect(fixture.textAt(main.path), isNull);
  });

  test('a chapter deleted while open closes the workspace', () async {
    final main = kid.chapters.last;
    await start(open: main);
    expect(await writes.remove(main), isA<LibraryDone>());
    expect(fixture.session.source, isNull);
    expect(fixture.store.deleted.keys, [main]);
  });

  test('a chapter that is no longer on disk is stale, not written', () async {
    await start();
    final gone = kid.chapters.first;
    fixture.store.documents.remove(gone);
    expect(await writes.remove(gone), isA<LibraryStale>());
    expect(fixture.store.deleted, isEmpty);
  });

  test('a folder whose chapter refuses stops there and stays', () async {
    await start();
    fixture.store.deletes.add(const IoFailure('disk full'));
    final result = await writes.deleteFolder(kid);
    expect(result, isA<LibraryStoppedAt>());
    expect((result as LibraryStoppedAt).chapter, 'Classical');
    expect(fixture.textAt(kid.chapters.last.path), isNotNull);
  });

  test('an import lands whole under the folder it is given', () async {
    await start();
    final result = await writes.importText(
      '[Event "Open"]\n\n1. e4 e5 (1... c5) *\n',
      folder: 'Open games',
    );
    final added = result as LibraryAdded;
    expect(added.chapters, 1);
    expect(added.lines, 2);
    expect(p.dirname(added.first.path), '/repertoires/Open games');
    expect(
      fixture.store.documents.keys.where(
        (ref) => ref.path.contains('.import-'),
      ),
      isEmpty,
      reason: 'nothing is left in staging',
    );
  });

  test('text with no moves writes nothing', () async {
    await start();
    final before = fixture.store.documents.length;
    expect(
      await writes.importText('just words', folder: 'Nothing'),
      isA<LibraryNothingToImport>(),
    );
    expect(fixture.store.documents.length, before);
  });

  test('chapter titles that clash get numbered file names', () {
    const chapter = ImportedChapter(title: 'Najdorf', text: '', lines: 1);
    const untitled = ImportedChapter(title: '', text: '', lines: 1);
    expect(chapterFileNames([chapter, chapter, untitled]), [
      'Najdorf',
      'Najdorf (2)',
      'Chapter 3',
    ]);
  });
}
