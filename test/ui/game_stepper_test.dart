// `‹ [n] of N ›`: the steps either side, the number typed to jump, and the
// width below which the steps give way.
import 'package:chess_auto_prep/ui/app_icons.dart';
import 'package:chess_auto_prep/ui/game_stepper.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<int> asked;
  setUp(() => asked = []);

  Future<void> show(
    WidgetTester tester, {
    required int? at,
    int total = 5,
    double width = 400,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: GameStepper(at: at, total: total, onShow: asked.add),
          ),
        ),
      ),
    ),
  );

  Finder step(IconData icon) => find.widgetWithIcon(IconButton, icon);
  VoidCallback? press(WidgetTester tester, IconData icon) =>
      tester.widget<IconButton>(step(icon)).onPressed;
  String box(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('the steps ask for the game either side', (tester) async {
    await show(tester, at: 2);
    expect(box(tester), '3');
    await tester.tap(step(AppIcons.previous));
    await tester.tap(step(AppIcons.next));
    expect(asked, [1, 3]);
  });

  testWidgets('with none of the games showing, the steps go to the last and '
      'the first', (tester) async {
    await show(tester, at: null);
    expect(box(tester), '');
    await tester.tap(step(AppIcons.previous));
    await tester.tap(step(AppIcons.next));
    expect(asked, [4, 0]);
    await show(tester, at: null, total: 1);
    await tester.tap(step(AppIcons.previous));
    await tester.tap(step(AppIcons.next));
    expect(asked, [4, 0, 0, 0]);
  });

  testWidgets('a step past either end is off, and both are with no games', (
    tester,
  ) async {
    await show(tester, at: 0);
    expect(press(tester, AppIcons.previous), isNull);
    expect(press(tester, AppIcons.next), isNotNull);
    await show(tester, at: 1);
    expect(press(tester, AppIcons.previous), isNotNull);
    await show(tester, at: 4);
    expect(press(tester, AppIcons.next), isNull);
    expect(press(tester, AppIcons.previous), isNotNull);
    await show(tester, at: null, total: 0);
    expect(press(tester, AppIcons.previous), isNull);
    expect(press(tester, AppIcons.next), isNull);
  });

  testWidgets('a number typed jumps there; one the file does not have puts '
      'the box back', (tester) async {
    await show(tester, at: 2);
    for (final typed in ['1', '5', '0', '6']) {
      await tester.enterText(find.byType(TextField), typed);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }
    expect(asked, [0, 4]);
    expect(box(tester), '3');
  });

  testWidgets('the box follows the game showing, but not while it is typed '
      'in', (tester) async {
    await show(tester, at: 2);
    await show(tester, at: 3);
    expect(box(tester), '4');
    await tester.enterText(find.byType(TextField), '1');
    await show(tester, at: 0);
    expect(box(tester), '1');
  });

  testWidgets('the steps show from the width that fits them whole', (
    tester,
  ) async {
    // Literal, not read from the stepper: it is what is being checked.
    const fits =
        2 * (IconSize.menu + 2 * Space.s) +
        gameNumberWidth +
        Space.s +
        Space.xl;
    await show(tester, at: 2, width: fits);
    expect(step(AppIcons.next), findsOneWidget);
    await show(tester, at: 2, width: fits - 1);
    expect(step(AppIcons.next), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });
}
