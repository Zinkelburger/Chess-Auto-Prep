import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/move_note.dart';
import 'package:chess_auto_prep/v2/workspace/move_tree_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_fixture.dart';
import '../support/study_fixture.dart';

/// A line the user is asked to find: the workspace shows it only as far as
/// the session says, so the answer is never an arrow key or a glance away.
void main() {
  const game = '''
[Event "Puzzle"]
[Result "*"]

{The answer is e4, then Nf3.} 1. e4 {Best by test} e5 2. Nf3 (2. f4 {The gambit}) *
''';

  test('the cursor cannot pass what is shown, and a cursor past it is '
      'brought back', () async {
    final fixture = await openSession(game);
    addTearDown(fixture.dispose);
    final session = fixture.session;
    session.goTo(NodePath.of([0, 0]));
    session.showOnlyTo(NodePath.of([0]));
    expect(session.cursor, NodePath.of([0]));
    session.forward();
    session.toEnd();
    expect(session.cursor, NodePath.of([0]));
    session.back();
    expect(session.cursor, const NodePath.root());
    session.forward();
    expect(session.cursor, NodePath.of([0]));
  });

  test('nothing is played into a document while its line is hidden', () async {
    final fixture = await openSession(game);
    addTearDown(fixture.dispose);
    final session = fixture.session;
    final before = session.tree;
    session.showOnlyTo(const NodePath.root());
    session.playMove('d2d4');
    expect(identical(session.tree, before), isTrue);
    session.showOnlyTo(null);
    session.playMove('d2d4');
    expect(identical(session.tree, before), isFalse);
  });

  test('another game of the file shows everything again', () async {
    final fixture = await openSession(twoChapterStudy);
    addTearDown(fixture.dispose);
    final session = fixture.session;
    await session.open(fixture.ref, game: 0);
    session.showOnlyTo(const NodePath.root());
    session.showGame(1);
    expect(session.shownTo, isNull);
  });

  testWidgets('the move list shows the moves found and no note or '
      'variation', (tester) async {
    final fixture = await openSession(game);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(400, 600));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: MoveTreeView(session: fixture.session)),
      ),
    );
    fixture.session.showOnlyTo(const NodePath.root());
    await tester.pump();
    expect(find.textContaining('e4'), findsNothing);
    expect(find.textContaining('answer'), findsNothing);
    fixture.session.showOnlyTo(NodePath.of([0, 0]));
    await tester.pump();
    expect(find.textContaining('e4'), findsOneWidget);
    expect(find.textContaining('e5'), findsOneWidget);
    expect(find.textContaining('Nf3'), findsNothing);
    expect(find.textContaining('Best by test'), findsNothing);
    fixture.session.showOnlyTo(null);
    await tester.pump();
    expect(find.textContaining('Best by test'), findsOneWidget);
    expect(find.textContaining('gambit'), findsOneWidget);
  });

  testWidgets('the note under the board says nothing while the line is '
      'hidden', (tester) async {
    final fixture = await openSession(game);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: MoveNote(session: fixture.session),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('answer'), findsOneWidget);
    fixture.session.showOnlyTo(const NodePath.root());
    await tester.pump();
    expect(find.textContaining('answer'), findsNothing);
  });
}
