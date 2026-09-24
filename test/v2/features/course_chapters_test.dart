// Chapters named by tag inside one course file: opening one, editing it,
// moving lines between them, renaming and deleting one — each a write to
// the one file, with every other chapter's games kept byte for byte.
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart' as saver;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';
import '../support/scripted_store.dart';

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

  test('moving every line out keeps the surviving chapter identity', () async {
    await start(opened: sicilian);
    await fixture.library.moveLines(games: {0}, to: open);
    expect(sectionsInText(onDisk()), ['Open games']);
    expect(fixture.session.source, open);
    expect(fixture.session.chapter!.lines, hasLength(3));
  });

  /// A chapter file beside the course file, holding [text].
  ChapterRef besideTheCourse(String name, String text) {
    final chapter = ChapterRef.at('/repertoires/Course/$name.pgn');
    fixture.store.documents[chapter] = Opened(text, scriptedRevision(text));
    return chapter;
  }

  test('lines moved into a chapter file leave their chapter name', () async {
    await start(opened: sicilian);
    final plain = besideTheCourse(
      'Scotch',
      '// Scotch\n// Color: White\n\n[Event "Scotch"]\n\n1. e4 e5 2. Nf3 Nc6 '
          '3. d4 *\n',
    );
    final result = await fixture.library.moveLines(games: {0}, to: plain);
    expect(result, isA<LibraryDone>());
    final text = fixture.textAt(plain.path)!;
    expect(text, contains('[Event "Alapin"]'));
    expect(text, isNot(contains('[ChapterName')));
    expect(sectionsInText(text), [null], reason: 'still one chapter');
  });

  test('lines moved into a file of one named chapter take its name', () async {
    await start(opened: sicilian);
    final najdorf = besideTheCourse(
      'Najdorf',
      '// Color: White\n\n[Event "English Attack"]\n[ChapterName "Najdorf"]\n\n'
          '1. e4 c5 2. Nf3 d6 *\n',
    );
    final result = await fixture.library.moveLines(games: {0}, to: najdorf);
    expect(result, isA<LibraryDone>());
    final text = fixture.textAt(najdorf.path)!;
    expect(
      text.substring(text.indexOf('[Event "Alapin"]')),
      contains('[ChapterName "Najdorf"]'),
    );
    expect(sectionsInText(text), ['Najdorf'], reason: 'still one chapter');
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

  test('renaming another chapter of the open file leaves the board', () async {
    await start(opened: open);
    final result = await fixture.library.renameChapter(
      sicilian,
      'Anti-Sicilians',
    );
    expect(result, isA<LibraryDone>());
    expect(sectionsInText(onDisk()), ['Open games', 'Anti-Sicilians']);
    expect(fixture.session.source, open);
    expect(fixture.session.chapter!.lines.map((l) => l.nameAt(0)), [
      'Ruy',
      'Italian',
    ]);
  });

  test('a rename of a file opened while it was read goes through the '
      'workspace', () async {
    await start();
    fixture.store.hold = true;
    final renamed = fixture.library.renameChapter(sicilian, 'Anti-Sicilians');
    await pumpEventQueue();
    // The user opens the file while the library is reading it.
    final opening = fixture.session.open(open);
    await pumpEventQueue();
    fixture.store.hold = false;
    fixture.store.releaseLast(); // the workspace reads it first
    await opening;
    fixture.store.releaseAll();
    expect(await renamed, isA<LibraryDone>());

    // The workspace holds the revision the rename wrote, so its own next
    // save is not refused as a change made on disk.
    fixture.session.playMove('d2d4');
    await fixture.saver.flush();
    expect(fixture.saver.state, isA<saver.Saved>());
    expect(sectionsInText(onDisk()), ['Open games', 'Anti-Sicilians']);
    expect(onDisk(), contains('1. d4'));
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
    expect(chapters.map((c) => c.name), ['KID', 'Open games', 'Sicilian']);
    expect(chapters.map((c) => c.section), ['KID', 'Open games', 'Sicilian']);
  });
}
