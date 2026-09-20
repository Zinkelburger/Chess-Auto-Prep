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

void main() {
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
    expect(note.dy, closeTo(move.dy, 4), reason: 'on the same line');
    expect(note.dx, lessThan(move.dx), reason: 'and read before it');
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data ?? '').contains('[%'),
      ),
      findsNothing,
    );
  });
}
