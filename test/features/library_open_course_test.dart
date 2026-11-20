// A chapter of the course file open in the workspace is renamed, or loses
// its lines to another chapter of the file. The edit goes through the
// workspace, whose saver waits a second as it does in the app, and the list
// read after the change has to name what the file holds, not what it held
// a moment before.
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/features/library/library.dart';
import 'package:chess_auto_prep/features/library/library_state.dart';
import 'package:chess_auto_prep/storage/chapter_directory.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
import 'package:chess_auto_prep/workspace/document/session_results.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';

const _course = '''
// Color: White

[Event "Ruy"]
[ChapterName "Open games"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *

[Event "Alapin"]
[ChapterName "Sicilian"]

1. e4 c5 2. c3 *
''';

void main() {
  late Directory documents;
  late Directory support;
  late DocumentSaver saver;
  late DocumentSession session;
  late Library library;

  List<ChapterRef> chapters() => library.repertoires.single.chapters;

  ChapterRef chapter(String name) =>
      chapters().firstWhere((chapter) => chapter.name == name);

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('v2-open-course-');
    support = await Directory.systemTemp.createTemp('v2-open-course-support-');
    final root = p.join(documents.path, 'repertoires');
    final folder = Directory(p.join(root, 'Course'))
      ..createSync(recursive: true);
    File(p.join(folder.path, 'Course.pgn')).writeAsStringSync(_course);
    final store = PgnFileStore(documents: documents, support: support);
    saver = DocumentSaver(store);
    session = DocumentSession(store, saver);
    final files = ChapterDirectory(Directory(root), recovery: store.recovery);
    library = libraryOver(files, store, session, saver, root: root);
    await library.refresh();
    await session.open(chapter('Sicilian'));
  });

  tearDown(() async {
    library.dispose();
    session.dispose();
    saver.dispose();
    await documents.delete(recursive: true);
    await support.delete(recursive: true);
  });

  test('a copy cannot undo the original course deletion', () async {
    final surviving = chapter('Sicilian');
    final removed = chapter('Open games');
    expect(await session.showAnalysisBoard(), isTrue);
    expect(await library.deleteChapter(removed), isA<LibraryDone>());

    final file = File(surviving.path);
    final bytes = await file.readAsBytes();
    final archived = await file.rename('${file.path}.archived');
    await archived.copy(file.path);

    expect(await session.open(surviving), isA<DocumentOpened>());
    expect(session.canUndo, isFalse);
    expect(await session.undo(), isA<UndoRefused>());
    expect(await file.readAsBytes(), bytes);
  });

  test('a tab keeps its comment undo across two closed renames', () async {
    final course = chapter('Sicilian');
    final file = File(course.path);
    session.setComment(NodePath.of([0]), 'Remember this line');
    await saver.flush();
    final commented = await file.readAsString();
    expect(commented, contains('Remember this line'));
    expect(await session.showAnalysisBoard(), isTrue);
    final kept = session.takeSetAsideUndo()!;

    expect(
      await library.renameChapter(chapter('Open games'), 'Open'),
      isA<LibraryDone>(),
    );
    expect(
      await library.renameChapter(chapter('Open'), 'Open games'),
      isA<LibraryDone>(),
    );
    expect(await file.readAsString(), commented);
    expect(await session.open(course), isA<DocumentOpened>());
    expect(session.restoreUndo(kept), isTrue);
    for (var i = 0; i < 3 && session.canUndo; i++) {
      expect(await session.undo(), isA<Restored>());
    }
    expect(await file.readAsString(), _course);
  });

  test('a renamed chapter is listed under its new name at once', () async {
    expect(
      await library.renameChapter(chapter('Sicilian'), 'Anti-Sicilians'),
      isA<LibraryDone>(),
    );
    expect(chapters().map((c) => c.name), ['Open games', 'Anti-Sicilians']);
    expect(saver.settled, isTrue);
  });

  test('a chapter whose lines all moved away is gone from the list', () async {
    expect(
      await library.moveLines(games: {0}, to: chapter('Open games')),
      isA<LibraryDone>(),
    );
    // The surviving chapter keeps its name and its book identity.
    expect(chapters().map((c) => c.name), ['Open games']);
  });
}
