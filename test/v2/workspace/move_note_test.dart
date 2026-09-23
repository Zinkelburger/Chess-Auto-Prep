import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/move_note.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_fixture.dart';

const annotated = '''
// Color: White

[Event "Annotated"]
[Result "*"]

{Play the Exchange. [%eval 0.21]} 1. d4 d5 {[%clk 0:29:41] The solid reply.} 2. c4 \$1 {Now 2... dxc4 3. e4 is the main line.} *
''';

void main() {
  late SessionFixture fixture;

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 300));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: MoveNote(session: fixture.session)),
      ),
    );
    await tester.pump();
  }

  setUp(() async => fixture = await openSession(annotated));
  tearDown(() => fixture.dispose());

  testWidgets('the start shows the introduction, then the first move and its '
      'note, which a click plays', (tester) async {
    await pump(tester);
    expect(find.text('Play the Exchange.'), findsOneWidget);
    expect(find.textContaining('[%eval'), findsNothing);
    expect(find.textContaining('1. d4'), findsOneWidget);
    expect(find.byTooltip('Play d4 (→)'), findsOneWidget);
    await tester.tap(find.textContaining('1. d4'));
    await tester.pump();
    expect(fixture.session.currentMove!.san, 'd4');
    expect(find.byTooltip('Play d4 (→)'), findsNothing);
  });

  testWidgets('a game with no introduction still shows its first move', (
    tester,
  ) async {
    fixture.dispose();
    fixture = await openSession('''
[Event "Bare"]
[Result "*"]

1. e4 {The king's pawn.} e5 *
''');
    await pump(tester);
    expect(find.textContaining('1. e4'), findsOneWidget);
    expect(find.text("The king's pawn."), findsOneWidget);
  });

  testWidgets('a move shows its number, glyph, meaning and note', (
    tester,
  ) async {
    await pump(tester);
    fixture.session.toEnd();
    await tester.pump();
    expect(find.textContaining('2. c4!'), findsOneWidget);
    expect(find.textContaining('Good move'), findsOneWidget);
    expect(find.textContaining('main line'), findsOneWidget);
    expect(find.text('Play the Exchange.'), findsNothing);

    fixture.session.back();
    await tester.pump();
    expect(find.textContaining('1... d5'), findsOneWidget);
    expect(find.text('The solid reply.'), findsOneWidget);
    expect(find.textContaining('[%clk'), findsNothing);
  });

  testWidgets('a move written in the note plays into the game', (tester) async {
    await pump(tester);
    fixture.session.toEnd();
    await tester.pump();
    await tester.tap(find.text('3. e4'));
    await tester.pump();
    expect(fixture.session.currentMove!.san, 'e4');
    expect(fixture.session.cursor.indexes, hasLength(5));
  });
}
