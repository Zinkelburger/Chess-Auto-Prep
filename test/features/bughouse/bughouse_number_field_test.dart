/// The lab's typed number: commits on submit or blur, clamps into range,
/// and shows what it kept.
library;

import 'package:chess_auto_prep/features/bughouse/widgets/bughouse_number_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<int>> pump(WidgetTester tester, {int value = 256}) async {
    final committed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              BughouseNumberField(
                label: 'Memory',
                unit: 'MB',
                value: value,
                min: 16,
                max: 4096,
                onChanged: committed.add,
              ),
              const TextField(key: Key('elsewhere')),
            ],
          ),
        ),
      ),
    );
    return committed;
  }

  testWidgets('shows the value, its unit and its range', (tester) async {
    await pump(tester);
    expect(find.text('256'), findsOneWidget);
    expect(find.text('MB'), findsOneWidget);
    expect(find.text('16–4096'), findsOneWidget);
  });

  testWidgets('commits on submit, not on every keystroke', (tester) async {
    final committed = await pump(tester);
    final field = find.byType(TextField).first;
    await tester.enterText(field, '1024');
    await tester.pump();
    expect(committed, isEmpty, reason: 'typing must not restart the engine');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(committed, [1024]);
  });

  testWidgets('clamps into range and shows what it kept', (tester) async {
    final committed = await pump(tester);
    final field = find.byType(TextField).first;
    await tester.enterText(field, '5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(committed, [16]);
    expect(find.text('16'), findsOneWidget);

    await tester.enterText(field, '99999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(committed, [16, 4096]);
    expect(find.text('4096'), findsOneWidget);
  });

  testWidgets('commits when focus moves elsewhere', (tester) async {
    final committed = await pump(tester);
    await tester.enterText(find.byType(TextField).first, '512');
    await tester.pump();
    await tester.tap(find.byKey(const Key('elsewhere')));
    await tester.pump();
    expect(committed, [512]);
  });

  testWidgets('an emptied field goes back to the value it had', (tester) async {
    final committed = await pump(tester);
    final field = find.byType(TextField).first;
    await tester.enterText(field, '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(committed, isEmpty);
    expect(find.text('256'), findsOneWidget);
  });
}
