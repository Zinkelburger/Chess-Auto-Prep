// What a cursor move costs on screen: the session tells only what follows
// the cursor, the move list redraws the move it left and the move it
// reached, and the outline redraws no row unless the cursor changed line.
// A widget that was not rebuilt is the very same object after the move, so
// the tests compare the widgets on screen before and after, by identity.
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/library/chapter_outline.dart';
import 'package:chess_auto_prep/v2/features/library/outline_panel.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/move_tree_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/big_chapter.dart';
import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/session_fixture.dart';

const twoLines = '''
// Book
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 e6 3. Nc3 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 2. c4 *
''';

/// The widgets of type [T] under [of], in the order they are on screen.
List<T> shown<T extends Widget>(WidgetTester tester, Type of) => tester
    .widgetList<T>(
      find.descendant(of: find.byType(of), matching: find.byType(T)),
    )
    .toList();

/// How many of [after] are not the very object [before] held at that place.
int rebuilt(List<Widget> before, List<Widget> after) {
  expect(after, hasLength(before.length), reason: 'the same rows are shown');
  return [
    for (final (i, widget) in after.indexed)
      if (!identical(widget, before[i])) i,
  ].length;
}

Future<LibraryFixture> openBook(String text) => openLibrary(
  [
    folder('KID', ['Main']),
  ],
  text: text,
  open: ref('KID', 'Main'),
);

Future<void> pumpBoth(
  WidgetTester tester,
  LibraryFixture fixture,
  ChapterOutline outline,
) async {
  await tester.binding.setSurfaceSize(const Size(900, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(
        body: Row(
          children: [
            SizedBox(
              width: outlineColumnWidth,
              child: OutlinePanel(
                outline: outline,
                library: fixture.library,
                session: fixture.session,
                onOpen: (_) {},
              ),
            ),
            Expanded(child: MoveTreeView(session: fixture.session)),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('a cursor move is told to the cursor and not to the document', () async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    final session = fixture.session;
    var document = 0;
    var cursor = 0;
    var either = 0;
    session.addListener(() => document++);
    session.cursorListenable.addListener(() => cursor++);
    session.anyChange.addListener(() => either++);

    session.forward();
    session.forward();
    session.back();
    expect((document, cursor, either), (0, 3, 3));
    expect(session.cursorListenable.value, NodePath.of([0]));

    session.setComment(session.cursor, 'The Queen\'s pawn');
    expect((document, cursor), (1, 3), reason: 'an edit moves no cursor');

    session.playMove('c7c5');
    expect(session.currentMove?.san, 'c5');
    expect(document, 2, reason: 'a new move is an edit');
    expect(cursor, 4, reason: 'and the cursor follows it');
  });

  test('a cursor listener reads the move it was told about', () async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    final session = fixture.session;
    final seen = <String?>[];
    session.cursorListenable.addListener(
      () => seen.add(session.currentMove?.san),
    );
    session.goTo(NodePath.of([0, 1, 0]));
    session.playMove('e7e6');
    expect(seen, ['c4', 'e6'], reason: 'the chapter holds e6 when told');
  });

  testWidgets('walking the moves redraws the move left and the move '
      'reached, not the list', (tester) async {
    final fixture = await openBook(twoLines);
    final outline = ChapterOutline(
      library: fixture.library,
      session: fixture.session,
      debounce: Duration.zero,
    );
    addTearDown(() {
      outline.dispose();
      fixture.dispose();
    });
    await pumpBoth(tester, fixture, outline);
    final session = fixture.session;

    var before = shown<Text>(tester, MoveTreeView);
    session.forward();
    await tester.pump();
    expect(rebuilt(before, shown<Text>(tester, MoveTreeView)), 1);

    for (var step = 0; step < 3; step++) {
      before = shown<Text>(tester, MoveTreeView);
      session.forward();
      await tester.pump();
      expect(rebuilt(before, shown<Text>(tester, MoveTreeView)), 2);
    }
    expect(session.currentMove?.san, 'e6');

    session.setComment(session.cursor, 'Solid');
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(MoveTreeView),
        matching: find.text('Solid'),
      ),
      findsOneWidget,
      reason: 'an edit is another tree, and the list shows it',
    );
  });

  testWidgets('the outline redraws no row while the cursor stays on a line, '
      'and two rows when it changes line', (tester) async {
    final fixture = await openBook(twoLines);
    final outline = ChapterOutline(
      library: fixture.library,
      session: fixture.session,
      debounce: Duration.zero,
    );
    addTearDown(() {
      outline.dispose();
      fixture.dispose();
    });
    await pumpBoth(tester, fixture, outline);
    final session = fixture.session;
    var told = 0;
    outline.addListener(() => told++);

    session.goTo(NodePath.of([0, 0]));
    await tester.pump();
    var before = shown<LineRow>(tester, OutlinePanel);
    session.forward();
    session.forward();
    await tester.pump();
    expect(outline.currentLine.value, 0);
    expect(rebuilt(before, shown<LineRow>(tester, OutlinePanel)), 0);
    expect(told, 0, reason: 'nothing the outline lists changed');

    before = shown<LineRow>(tester, OutlinePanel);
    session.goTo(NodePath.of([0, 1]));
    await tester.pump();
    expect(outline.currentLine.value, 1);
    final after = shown<LineRow>(tester, OutlinePanel);
    expect(rebuilt(before, after), 2);
    expect([for (final row in after) row.current], [false, true]);
    expect(told, 0);
  });

  testWidgets('a book of lines builds the rows on screen and walks cheaply', (
    tester,
  ) async {
    const games = 120;
    final text = bigChapter(games: games);
    expect(
      text.length,
      lessThan(64 * 1024),
      reason: 'read on the test isolate',
    );
    final fixture = await openBook(text);
    final outline = ChapterOutline(
      library: fixture.library,
      session: fixture.session,
      debounce: Duration.zero,
    );
    addTearDown(() {
      outline.dispose();
      fixture.dispose();
    });
    await pumpBoth(tester, fixture, outline);
    final session = fixture.session;
    expect(outline.lines, hasLength(games));
    expect(
      shown<LineRow>(tester, OutlinePanel).length,
      lessThan(games ~/ 2),
      reason: 'only the rows in view are built',
    );

    session.goTo(NodePath.of([0, 0]));
    await tester.pump();
    while (session.currentMove?.children.isNotEmpty ?? false) {
      final moves = shown<Text>(tester, MoveTreeView);
      final rows = shown<LineRow>(tester, OutlinePanel);
      session.forward();
      await tester.pump();
      expect(rebuilt(moves, shown<Text>(tester, MoveTreeView)), 2);
      expect(
        rebuilt(rows, shown<LineRow>(tester, OutlinePanel)),
        0,
        reason: 'the main line stays the first line',
      );
    }
    expect(outline.currentLine.value, 0);
    session.toStart();
    await tester.pump();
    expect(outline.currentLine.value, isNull);
  });
}
