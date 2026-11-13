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

  _steppedWhileFocused();
}

void _steppedWhileFocused() {
  testWidgets('a step while the box has focus shows and keeps the new '
      'number', (tester) async {
    var value = 5;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => NumberField(
              label: 'Depth',
              value: value,
              min: 1,
              max: 9,
              onChanged: (n) => setState(() => value = n),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.tap(find.byTooltip('Increase Depth'));
    await tester.pump();
    await tester.tap(find.byTooltip('Increase Depth'));
    await tester.pump();
    expect(value, 7);
    expect(find.text('7'), findsOneWidget);
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    expect(value, 7);
  });
}
