// Chapters named by tag inside one course file: opening one, editing it,
// moving lines between them, renaming and deleting one — each a write to
// the one file, with every other chapter's games kept byte for byte.
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';

const _path = '/repertoires/Course/Course.pgn';

const _course = '''
// Color: White

[Event "Ruy"]
[ChapterName "Open games"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *

[Event "Alapin"]
[ChapterName "Sicilian"]

1. e4 c5 2. c3 *

[Event "Italian"]
[ChapterName "Open games"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 *
''';

ChapterRef _chapter(String section) => ChapterRef.at(_path, section: section);

void main() {
  late LibraryFixture fixture;
  var started = false;
  final open = _chapter('Open games');
  final sicilian = _chapter('Sicilian');

  Future<void> start({ChapterRef? opened}) async {
    started = true;
    fixture = await openLibrary(
      [
        RepertoireFolder(
          name: 'Course',
          path: '/repertoires/Course',
          modified: DateTime(2026),
          chapters: [open, sicilian],
        ),
      ],
      text: _course,
      open: opened,
    );
  }

  tearDown(() {
    if (started) fixture.dispose();
    started = false;
  });

  String onDisk() => fixture.textAt(_path)!;

  test('a chapter opens as its own games, wherever they sit', () async {
    await start(opened: open);
    final chapter = fixture.session.chapter!;
    expect(chapter.name, 'Open games');
    expect(chapter.lines.map((l) => l.nameAt(0)), ['Ruy', 'Italian']);
    expect(fixture.session.source, open);
  });

  test('a move played in a chapter is written into the one file', () async {
    await start(opened: sicilian);
    fixture.session.toEnd();
    fixture.session.playMove('d7d5');
    await pumpEventQueue();
    final text = onDisk();
    expect(text, contains('1. e4 c5 2. c3 d5 *'));
    // The other chapter's games are as they were.
    expect(text, contains('[Event "Ruy"]\n[ChapterName "Open games"]\n\n'));
    expect(sectionsInText(text), ['Open games', 'Sicilian']);
  });

  test('a new line in a chapter carries its name', () async {
    await start(opened: sicilian);
    fixture.session.playMove('d2d4');
    await pumpEventQueue();
    final text = onDisk();
    final last = text.substring(text.lastIndexOf('[Event '));
    expect(last, contains('[ChapterName "Sicilian"]'));
    expect(last, contains('1. d4'));
    expect(fixture.session.chapter!.lines, hasLength(2));
  });

  test('lines moved to another chapter of the file take its name', () async {
    await start(opened: open);
    final result = await fixture.library.moveLines(games: {1}, to: sicilian);
    expect(result, isA<LibraryDone>());
    final text = onDisk();
    expect(
      text,
      contains('[Event "Italian"]\n[ChapterName "Sicilian"]\n'),
      reason: 'the game keeps its place and changes one tag',
    );
    expect(fixture.session.chapter!.lines.map((l) => l.nameAt(0)), ['Ruy']);
  });

  test('moving every line out shows the file as one chapter', () async {
    await start(opened: sicilian);
    await fixture.library.moveLines(games: {0}, to: open);
    expect(sectionsInText(onDisk()), [null]);
    expect(fixture.session.source, ChapterRef.at(_path));
    expect(fixture.session.chapter!.lines, hasLength(3));
  });

  test('renaming a chapter rewrites its tag and nothing else', () async {
    await start(opened: sicilian);
    final result = await fixture.library.renameChapter(
      sicilian,
      'Anti-Sicilians',
    );
    expect(result, isA<LibraryDone>());
    await pumpEventQueue();
    final text = onDisk();
    expect(text, contains('[ChapterName "Anti-Sicilians"]'));
    expect(text, isNot(contains('"Sicilian"')));
    expect(fixture.session.source, _chapter('Anti-Sicilians'));
    expect(fixture.session.chapter!.name, 'Anti-Sicilians');
  });

  test('a name the file already has is refused', () async {
    await start(opened: sicilian);
    final result = await fixture.library.renameChapter(sicilian, 'Open games');
    expect(result, isA<LibraryFailure>());
    expect(onDisk(), _course);
  });

  test('deleting a chapter takes its games out of the file', () async {
    await start();
    final result = await fixture.library.deleteChapter(open);
    expect(result, isA<LibraryDone>());
    final text = onDisk();
    expect(text, isNot(contains('Ruy')));
    expect(text, isNot(contains('Italian')));
    expect(text, contains('[Event "Alapin"]\n[ChapterName "Sicilian"]\n'));
  });

  test('a chapter of a course file does not move without its file', () async {
    await start();
    final result = await fixture.library.moveChapter(
      sicilian,
      RepertoireFolder(
        name: 'Other',
        path: '/repertoires/Other',
        modified: DateTime(2026),
        chapters: const [],
      ),
    );
    expect(result, isA<LibraryFailure>());
    expect(onDisk(), _course);
  });

  test('the listing names a course file\'s chapters in file order', () async {
    final dir = await Directory.systemTemp.createTemp('course');
    addTearDown(() => dir.delete(recursive: true));
    final folder = Directory(p.join(dir.path, 'Course'))..createSync();
    File(p.join(folder.path, 'Course.pgn')).writeAsStringSync(_course);
    File(p.join(folder.path, 'Alone.pgn')).writeAsStringSync(
      '// Color: White\n\n[Event "a"]\n[ChapterName "KID"]\n\n1. d4 *\n',
    );
    final listing = await ChapterDirectory(dir).list() as Repertoires;
    final chapters = listing.folders.single.chapters;
    expect(chapters.map((c) => c.name), ['Alone', 'Open games', 'Sicilian']);
    expect(chapters.map((c) => c.section), [null, 'Open games', 'Sicilian']);
  });
}
