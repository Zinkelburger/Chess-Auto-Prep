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
}
