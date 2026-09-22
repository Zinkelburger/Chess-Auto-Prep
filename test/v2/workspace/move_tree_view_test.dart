import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/move_tree_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_fixture.dart';

/// A chapter whose introduction and whose first move both carry the tokens
/// an engine pass leaves behind.
const annotatedChapter = '''
// Color: White

[Event "Annotated"]
[Result "*"]

{Play the Exchange. [%eval 0.21]} 1. d4 ({A sideline. [%eval 0.05]} 1. c4 e5) 1... d5 {[%clk 0:29:41] Our move.} *
''';

Future<void> pumpTree(WidgetTester tester, SessionFixture fixture) async {
  await tester.binding.setSurfaceSize(const Size(400, 600));
  await tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(body: MoveTreeView(session: fixture.session)),
    ),
  );
  await tester.pump();
}

/// Two lines from 1. d4, the second of them a branch at the first move.
const twoLines = '''
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 *
''';

void main() {
  testWidgets('a move offers what can be done to it, and does it', (
    tester,
  ) async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);

    await tester.longPress(find.textContaining('Nf6'));
    await tester.pumpAndSettle();
    expect(find.text('Promote variation'), findsOneWidget);
    expect(find.text('Delete from here'), findsOneWidget);
    await tester.tap(find.text('Make main line'));
    await tester.pumpAndSettle();

    expect(fixture.session.tree!.children.first.children.first.san, 'Nf6');
    expect(
      fixture.onDisk.indexOf('[Event "Indian"]'),
      lessThan(fixture.onDisk.indexOf('[Event "Queen\'s"]')),
    );
  });

  testWidgets('deleting from a move takes it off the screen and offers it '
      'back', (tester) async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);

    await tester.longPress(find.textContaining('c4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from here'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(MoveTreeView),
        matching: find.textContaining('c4'),
      ),
      findsNothing,
    );
    expect(fixture.onDisk, contains('1. d4 d5 *'));
    expect(find.text('Deleted the moves from c4.'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(fixture.onDisk, twoLines);
  });

  testWidgets('shows the introduction without its machine tokens', (
    tester,
  ) async {
    final fixture = await openSession(annotatedChapter);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);

    expect(find.text('Play the Exchange.'), findsOneWidget);
    expect(find.text('Our move.'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data ?? '').contains('[%'),
      ),
      findsNothing,
      reason: 'engine tokens belong to the move, not to the reader',
    );
  });

  testWidgets('reads a note the file wrote before a move before it', (
    tester,
  ) async {
    final fixture = await openSession(annotatedChapter);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);

    final note = tester.getTopLeft(find.text('A sideline.'));
    final move = tester.getTopLeft(find.textContaining('c4'));
    expect(note.dy, lessThan(move.dy), reason: 'read before it');
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data ?? '').contains('[%'),
      ),
      findsNothing,
    );
  });
}
