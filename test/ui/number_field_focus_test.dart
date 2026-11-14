import 'package:chess_auto_prep/ui/app_icons.dart';
import 'package:chess_auto_prep/ui/number_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<int>> pumped(WidgetTester tester) async {
    final taken = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NumberField(
            label: 'Depth',
            value: 5,
            min: 1,
            max: 9,
            onChanged: taken.add,
          ),
        ),
      ),
    );
    return taken;
  }

  testWidgets('leaving the box takes the number typed', (tester) async {
    final taken = await pumped(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '7');
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    expect(taken, [7]);
  });

  testWidgets('the box going away takes nothing', (tester) async {
    final taken = await pumped(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '7');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(taken, isEmpty);
  });

  Future<void> show(WidgetTester tester, int value, List<int> taken) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NumberField(
              label: 'Depth',
              value: value,
              min: 1,
              max: 9,
              onChanged: taken.add,
            ),
          ),
        ),
      );

  IconButton button(WidgetTester tester, String tip) =>
      tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, switch (tip) {
          'Increase' => AppIcons.increase,
          _ => AppIcons.decrease,
        }),
      );

  testWidgets('− and + step by one', (tester) async {
    final taken = <int>[];
    await show(tester, 5, taken);
    await tester.tap(find.byTooltip('Increase Depth'));
    await tester.tap(find.byTooltip('Decrease Depth'));
    expect(taken, [6, 4]);
  });

  testWidgets('a step past the range is off', (tester) async {
    final taken = <int>[];
    await show(tester, 1, taken);
    expect(button(tester, 'Decrease').onPressed, isNull);
    expect(button(tester, 'Increase').onPressed, isNotNull);
    await show(tester, 9, taken);
    expect(button(tester, 'Increase').onPressed, isNull);
    expect(button(tester, 'Decrease').onPressed, isNotNull);
  });

  testWidgets('a new value shows in the box, unless the box is being typed '
      'in', (tester) async {
    final taken = <int>[];
    await show(tester, 5, taken);
    await show(tester, 6, taken);
    expect(find.text('6'), findsOneWidget);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '8');
    await show(tester, 3, taken);
    expect(find.text('8'), findsOneWidget);
  });
}
