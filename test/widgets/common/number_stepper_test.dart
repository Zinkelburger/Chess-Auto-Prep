import 'package:chess_auto_prep/widgets/common/number_stepper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, ValueNotifier<int> value) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: value,
            builder: (context, v, _) => Row(
              children: [
                NumberStepper(
                  value: v,
                  min: 1,
                  max: 16,
                  step: 1,
                  suffix: 'of 16',
                  onChanged: (n) => value.value = n,
                ),
                const SizedBox(width: 80, child: TextField(key: Key('other'))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('typing a number commits on Enter, clamped to the range', (
    tester,
  ) async {
    final value = ValueNotifier(1);
    await pump(tester, value);
    await tester.enterText(find.byType(TextField).first, '12');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(value.value, 12);

    await tester.enterText(find.byType(TextField).first, '99');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(value.value, 16);
    expect(find.text('16'), findsOneWidget);
  });

  testWidgets('a blank box commits on blur by restoring the value', (
    tester,
  ) async {
    final value = ValueNotifier(5);
    await pump(tester, value);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.tap(find.byKey(const Key('other')));
    await tester.pumpAndSettle();
    expect(value.value, 5);
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('− and + move by one and stop at the limits', (tester) async {
    final value = ValueNotifier(15);
    await pump(tester, value);
    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    expect(value.value, 16);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Less'));
    await tester.pump();
    expect(value.value, 15);
    expect(find.text('15'), findsOneWidget);
  });
}
