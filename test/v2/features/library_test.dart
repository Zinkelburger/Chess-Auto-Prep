import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_files.dart';

void main() {
  late ScriptedFiles files;
  late Library library;
  final main = ref('KID', 'Main');

  setUp(() {
    files = ScriptedFiles(
      listing: Chapters([main]),
      texts: {main.path: const ChapterText(blackChapter)},
    );
    library = Library(files);
  });

  tearDown(() => library.dispose());

  test('refresh lists the chapters', () async {
    final done = library.refresh();
    expect(library.state, isA<LibraryLoading>());
    files.releaseNext();
    await done;
    expect((library.state as LibraryReady).chapters, [main]);
  });

  test('an overtaken refresh never replaces a newer one', () async {
    final first = library.refresh();
    files.listing = const Chapters([]);
    final second = library.refresh();
    files.releaseLast(); // the second refresh answers first
    await second;
    expect((library.state as LibraryReady).chapters, isEmpty);
    files.listing = Chapters([main]);
    files.releaseNext(); // the stale first answer arrives late
    await first;
    expect((library.state as LibraryReady).chapters, isEmpty);
  });

  test('an unreadable folder is a sentence, not an exception', () async {
    files.listing = const ChaptersUnreadable('Permission denied');
    final done = library.refresh();
    files.releaseNext();
    await done;
    expect(
      (library.state as LibraryFailed).reason,
      'Could not read the repertoires folder: Permission denied',
    );
  });

  test('open parses the chapter', () async {
    final opening = library.open(main);
    files.releaseNext();
    final result = await opening as Opened;
    expect(result.chapter.name, 'Main');
    expect(result.chapter.gameCount, 2);
  });

  test('open says when the file is gone or unreadable', () async {
    files.texts = {};
    var opening = library.open(main);
    files.releaseNext();
    expect((await opening as OpenFailed).reason, 'Main is no longer on disk');
    files.texts = {main.path: const ChapterUnreadable('Input/output error')};
    opening = library.open(main);
    files.releaseNext();
    expect(
      (await opening as OpenFailed).reason,
      'Could not read Main: Input/output error',
    );
  });

  test('a refresh finishing after dispose stays quiet', () async {
    final done = library.refresh();
    library.dispose();
    files.releaseNext();
    await done;
    library = Library(files); // so tearDown disposes a live one
  });
}
