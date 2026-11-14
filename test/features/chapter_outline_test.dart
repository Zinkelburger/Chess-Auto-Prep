// The outline is the chapters of the repertoire on the board and the lines
// of the chapter on it. What it answers has to follow the document and the
// library rather than a copy of either.
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/features/library/chapter_outline.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/workspace/document/chapter_commands.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

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

  test('At this position keeps the lines through the board, transpositions '
      'included, and follows the cursor', () async {
    fixture = await openLibrary(
      [
        folder('KID', ['Main']),
      ],
      text: transposing,
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
    var told = 0;
    outline.addListener(() => told++);
    fixture.session.cursor.goTo(outline.lines.first.at);
    outline.showAtPosition(true);
    expect(outline.lines.map((line) => line.name), ['Indian', 'English']);
    fixture.session.cursor.back();
    expect(outline.lines.map((line) => line.name), ['Indian']);
    fixture.session.cursor.back();
    expect(outline.lines.map((line) => line.name), ['Indian', 'Other']);
    final before = told;
    fixture.session.cursor.forward();
    fixture.session.cursor.back();
    expect(told, before + 2);
    outline.showAtPosition(false);
    expect(outline.lines, hasLength(3));
  });

  test('names each line and shows its first moves', () async {
    await open();

    expect(outline.lines.map((line) => line.name), ["Queen's", 'Indian']);
    expect(
      outline.lines.first.moves,
      '1.d4 d5 2.c4 e6 3.cxd5 exd5 4.Nc3 Nf6 …',
    );
  });

  test('a line is shown from where it leaves the line above it', () async {
    await open();

    expect(outline.lines.last.moves, '…1...Nf6');
  });

  test('a line is shown from where it leaves every line above it, and a '
      'repeated line still shows its last move', () async {
    fixture = await openLibrary(
      [
        folder('KID', ['Main']),
      ],
      text: '''
// Color: White

[Event "A"]

1. e4 e5 2. Nf3 Nc6 *

[Event "B"]

1. d4 d5 *

[Event "C"]

1. e4 e5 2. Nf3 Nf6 *

[Event "D"]

1. e4 e5 *
''',
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
    expect(outline.lines.map((line) => line.moves).toList(), [
      '1.e4 e5 2.Nf3 Nc6',
      '1.d4 d5',
      '…2...Nf6',
      '…1...e5',
    ]);
  });

  test('a name every line repeats is left off the row', () async {
    fixture = await openLibrary(
      [
        folder('KID', ['Main']),
      ],
      text: sameName,
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

    expect(outline.lines.map((line) => line.shared), [true, true]);
    expect(outline.lines.first.name, 'Book: Repertoire for White');
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
    fixture.session.cursor.goTo(indian.at);

    expect(fixture.session.cursor.currentMove!.san, 'Nf6');
  });

  test('the line holding the cursor is the current one', () async {
    await open();
    final tree = fixture.session.tree!;

    fixture.session.cursor.goTo(pathOfSans(tree, ['d4', 'd5', 'c4'])!);
    expect(
      [outline.isCurrent(0).value, outline.isCurrent(1).value],
      [true, false],
    );

    fixture.session.cursor.goTo(pathOfSans(tree, ['d4', 'Nf6'])!);
    expect(
      [outline.isCurrent(0).value, outline.isCurrent(1).value],
      [false, true],
    );
  });

  test('at the start of the chapter no line is the current one', () async {
    await open();

    expect(
      [outline.isCurrent(0).value, outline.isCurrent(1).value],
      [false, false],
    );
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
      expect(outline.chapters.map((chapter) => chapter.name), [
        'Main',
        'Sidelines',
      ]);
    },
  );

  test('the search matches a move deeper than the row shows', () async {
    await open();

    outline.search('bg5');
    await pumpEventQueue();

    expect(outline.lines.map((line) => line.name), ["Queen's"]);
  });

  test('a re-listing after a save keeps the closed chapters a search found, '
      'and reads only those whose file changed', () async {
    await open();
    final folders = [
      folder('KID', ['Main', 'Sidelines']),
      folder('benko', ['Main']),
    ];
    final sidelines = ref('KID', 'Sidelines');
    void listed(Revision sidelinesAt) => fixture.files.listing = Repertoires(
      folders,
      revisions: {
        for (final f in folders)
          for (final c in f.chapters)
            c.path: c == sidelines ? sidelinesAt : scriptedRevision(twoLines),
      },
    );
    listed(scriptedRevision(twoLines));
    await fixture.library.refresh();
    outline.search('bg5');
    await pumpEventQueue();
    expect(outline.chapters.map((c) => c.name), ['Main', 'Sidelines']);
    final opens = fixture.store.opens;
    listed(scriptedRevision(twoLines));
    await fixture.library.refresh();
    expect(outline.chapters.map((c) => c.name), ['Main', 'Sidelines']);
    await pumpEventQueue();
    expect(outline.chapters.map((c) => c.name), ['Main', 'Sidelines']);
    expect(fixture.store.opens, opens, reason: 'nothing was read again');
    listed(scriptedRevision('$twoLines\n'));
    await fixture.library.refresh();
    await pumpEventQueue();
    expect(fixture.store.opens, greaterThan(opens));
    expect(outline.chapters.map((c) => c.name), ['Main', 'Sidelines']);
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

  test('a line that is gone has no name to rename', () async {
    await open();

    expect(outline.nameOf(1), 'Indian');
    deleteLine(fixture.session, 1);
    await pumpEventQueue();

    expect(outline.nameOf(1), isNull);
  });

  test('it follows the document when a line is taken out', () async {
    await open();

    deleteLine(fixture.session, 1);
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

const sameName = '''
// Book
// Color: White

[Event "Book: Repertoire for White"]
[Result "*"]

1. d4 d5 *

[Event "Book: Repertoire for White"]
[Result "*"]

1. d4 Nf6 *
''';

const unnamedLine = '''
// Book
// Color: White

[Event ""]
[Result "*"]

1. e4 *
''';

const transposing = '''
// Book
// Color: White

[Event "Indian"]
[Result "*"]

1. d4 Nf6 2. c4 e6 *

[Event "English"]
[Result "*"]

1. c4 e6 2. d4 Nf6 *

[Event "Other"]
[Result "*"]

1. d4 Nf6 2. Nf3 *
''';
