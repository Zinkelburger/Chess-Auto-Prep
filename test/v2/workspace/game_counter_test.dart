import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/game_counter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/viewer_fixture.dart';

void main() {
  late ViewerFixture fixture;

  setUp(() async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
  });

  tearDown(() => fixture.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: navRowHeight,
            child: GameCounter(session: fixture.session),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('walks the games and stops at the ends', (tester) async {
    await pump(tester);
    expect(find.text('of 3'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_left),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Next game (↓)'));
    await tester.pump();
    expect(fixture.session.game, 1);
    await tester.tap(find.byTooltip('Next game (↓)'));
    await tester.pump();
    expect(fixture.session.game, 2);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_right),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('a number typed in jumps there, and the box follows', (
    tester,
  ) async {
    await pump(tester);
    final box = find.byType(TextField);
    expect(tester.widget<TextField>(box).controller?.text, '1');
    await tester.enterText(box, '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(fixture.session.game, 2);
    fixture.session.showGame(0);
    await tester.pump();
    expect(tester.widget<TextField>(box).controller?.text, '1');
  });

  testWidgets('a number the file does not have goes nowhere', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), '40');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(fixture.session.game, 0);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '1',
    );
  });
}
