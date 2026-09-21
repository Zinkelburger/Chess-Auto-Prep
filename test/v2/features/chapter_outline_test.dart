// The outline is the chapters of the repertoire on the board and the lines
// of the chapter on it. What it answers has to follow the document and the
// library rather than a copy of either.
import 'package:chess_auto_prep/v2/features/library/chapter_outline.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';

const twoLines = '''
// Book
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 e6 3. cxd5 exd5 4. Nc3 Nf6 5. Bg5 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 *
''';

void main() {
  late LibraryFixture fixture;
  late ChapterOutline outline;
  final main = ref('KID', 'Main');

  Future<void> open({Duration debounce = Duration.zero}) async {
    fixture = await openLibrary(
      [
        folder('KID', ['Main', 'Sidelines']),
        folder('benko', ['Main']),
      ],
      text: twoLines,
      open: main,
    );
    outline = ChapterOutline(
      library: fixture.library,
      session: fixture.session,
      debounce: debounce,
    );
    addTearDown(() {
      outline.dispose();
      fixture.dispose();
    });
  }

  test('lists the chapters of the repertoire the board is in', () async {
    await open();

    expect(outline.chapters.map((chapter) => chapter.name), [
      'Main',
      'Sidelines',
    ]);
    expect(outline.chapters.first.open, isTrue);
    expect(outline.chapters.first.lines, 2);
    expect(outline.chapters.last.lines, isNull);
  });

  test('names each line and shows its first moves', () async {
    await open();

    expect(outline.lines.map((line) => line.name), ["Queen's", 'Indian']);
    expect(
      outline.lines.first.moves,
      '1.d4 d5 2.c4 e6 3.cxd5 exd5 4.Nc3 Nf6 …',
    );
    expect(outline.lines.last.moves, '1.d4 Nf6');
  });

  test('a line with no name of its own is numbered', () async {
    fixture = await openLibrary(
      [
        folder('KID', ['Main']),
      ],
      text: unnamedLine,
      open: main,
    );
    outline = ChapterOutline(
      library: fixture.library,
      session: fixture.session,
    );
    addTearDown(() {
      outline.dispose();
      fixture.dispose();
    });

    expect(outline.lines.single.name, 'Line 1');
  });

  test('a line points at its own last move', () async {
    await open();

    final indian = outline.lines.last;
    fixture.session.goTo(indian.at);

    expect(fixture.session.currentMove!.san, 'Nf6');
  });

  test('the line holding the cursor is the current one', () async {
    await open();
    final tree = fixture.session.tree!;

    fixture.session.goTo(pathOfSans(tree, ['d4', 'd5', 'c4'])!);
    expect(outline.currentLine, 0);

    fixture.session.goTo(pathOfSans(tree, ['d4', 'Nf6'])!);
    expect(outline.currentLine, 1);
  });

  test('at the start of the chapter no line is the current one', () async {
    await open();

    expect(outline.currentLine, isNull);
  });

  test(
    'the search waits, then keeps the lines and chapters it matches',
    () async {
      await open(debounce: const Duration(milliseconds: 200));

      outline.search('indian');
      expect(outline.query, 'indian');
      expect(outline.lines, hasLength(2), reason: 'it has not waited yet');

      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(outline.lines.map((line) => line.name), ['Indian']);
      expect(outline.chapters.map((chapter) => chapter.name), ['Main']);
    },
  );

  test('the search matches a move deeper than the row shows', () async {
    await open();

    outline.search('bg5');
    await pumpEventQueue();

    expect(outline.lines.map((line) => line.name), ["Queen's"]);
  });

  test('a search that matches nothing leaves nothing', () async {
    await open();

    outline.search('benoni');
    await pumpEventQueue();

    expect(outline.chapters, isEmpty);
    expect(outline.lines, isEmpty);
  });

  test('a chapter matches by its own name whatever its lines say', () async {
    await open();

    outline.search('sidelines');
    await pumpEventQueue();

    expect(outline.chapters.map((chapter) => chapter.name), ['Sidelines']);
    expect(outline.lines, isEmpty);
  });

  test('it follows the document when a line is taken out', () async {
    await open();

    fixture.session.deleteLine(1);
    await pumpEventQueue();

    expect(outline.lines.map((line) => line.name), ["Queen's"]);
    expect(outline.chapters.first.lines, 1);
  });

  test('with the chapter closed there is nothing to list', () async {
    await open();

    fixture.session.closed();

    expect(outline.repertoire, isNull);
    expect(outline.chapters, isEmpty);
    expect(outline.lines, isEmpty);
  });
}

const unnamedLine = '''
// Book
// Color: White

[Event ""]
[Result "*"]

1. e4 *
''';
