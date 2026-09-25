import 'package:chess_auto_prep/v2/chess/pgn/repertoire_import.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';

void main() {
  final kid = folder('KID', ['Classical', 'Main']);
  late LibraryFixture fixture;

  Future<Library> start({ChapterRef? open}) async {
    fixture = await openLibrary([kid], open: open);
    addTearDown(fixture.dispose);
    return fixture.library;
  }

  test('a chapter renamed while open takes the workspace with it', () async {
    final main = kid.chapters.last;
    final library = await start(open: main);
    final result = await library.renameChapter(main, 'Najdorf');
    expect(result, isA<LibraryDone>());
    expect(fixture.session.source?.path, '/repertoires/KID/Najdorf.pgn');
    expect(fixture.textAt('/repertoires/KID/Najdorf.pgn'), isNotNull);
    expect(fixture.textAt(main.path), isNull);
  });

  test('a chapter deleted while open closes the workspace', () async {
    final main = kid.chapters.last;
    final library = await start(open: main);
    expect(await library.deleteChapter(main), isA<LibraryDone>());
    expect(fixture.session.source, isNull);
    expect(fixture.store.deleted.keys, [main]);
  });

  test(
    'a failed draft save prevents deletion and preserves the words',
    () async {
      final main = kid.chapters.last;
      final library = await start(open: main);
      fixture.store.saves.addAll(const [
        IoFailure('disk full'),
        IoFailure('disk full'),
      ]);
      fixture.session.playMove('e2e4');
      fixture.session.setComment(NodePath.of([0]), 'Keep these words');
      final result = await library.deleteChapter(main);
      expect(result, isA<LibraryFailure>());
      expect(fixture.store.deleted, isEmpty);
      expect(fixture.session.source, main);
      expect(
        fixture.session.chapter!.tree.nodeAt(NodePath.of([0]))!.comment,
        contains('Keep these words'),
      );
    },
  );

  test('a chapter that is no longer on disk is stale, not written', () async {
    final library = await start();
    final gone = kid.chapters.first;
    fixture.store.documents.remove(gone);
    expect(await library.deleteChapter(gone), isA<LibraryStale>());
    expect(fixture.store.deleted, isEmpty);
  });

  test('a folder whose chapter refuses stops there and stays', () async {
    final library = await start();
    fixture.store.deletes.add(const IoFailure('disk full'));
    final result = await library.deleteRepertoire(kid);
    expect(result, isA<LibraryStoppedAt>());
    expect((result as LibraryStoppedAt).chapter, 'Classical');
    expect(fixture.textAt(kid.chapters.last.path), isNotNull);
  });

  test(
    'a repertoire whose chapter went outside the app deletes on the next try',
    () async {
      final library = await start();
      final gone = kid.chapters.first;
      fixture.store.documents.remove(gone);
      expect(await library.deleteRepertoire(kid), isA<LibraryStoppedAt>());
      // The list read again no longer has the chapter; nothing of the first
      // attempt is kept to get in the way of the second.
      fixture.files.listing = Repertoires([
        folder('KID', ['Main']),
      ]);
      await library.refresh();
      final result = await library.deleteRepertoire(library.repertoires.single);
      expect(result, isA<LibraryDone>());
      expect(fixture.textAt(kid.chapters.last.path), isNull);
    },
  );

  test('a move that failed can simply be asked for again', () async {
    final library = await start();
    final chapter = kid.chapters.last;
    fixture.store.moves.add(const IoFailure('disk full'));
    expect(
      await library.renameChapter(chapter, 'Renamed'),
      isA<LibraryFailure>(),
    );
    expect(await library.renameChapter(chapter, 'Renamed'), isA<LibraryDone>());
    expect(fixture.textAt('/repertoires/KID/Renamed.pgn'), isNotNull);
  });

  test('an import lands whole under the folder it is given', () async {
    final library = await start();
    final result = await library.importText(
      '[Event "Open"]\n\n1. e4 e5 (1... c5) *\n',
      name: 'Open games',
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
    final library = await start();
    final before = fixture.store.documents.length;
    expect(
      await library.importText('just words', name: 'Nothing'),
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
