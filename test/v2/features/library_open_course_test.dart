// A chapter of the course file open in the workspace is renamed, or loses
// its lines to another chapter of the file. The edit goes through the
// workspace, whose saver waits a second as it does in the app, and the list
// read after the change has to name what the file holds, not what it held
// a moment before.
import 'dart:io';

import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
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
    saver = DocumentSaver(store, delay: const Duration(seconds: 1));
    session = DocumentSession(store, saver);
    final files = ChapterDirectory(Directory(root));
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
    // Every game names one chapter now, so the file is one chapter again.
    expect(chapters().map((c) => c.name), ['Course']);
  });
}
