import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoire/widgets/add_chapter_dialog.dart';

/// Opens the dialog and records what it returns.
Future<List<String?>> _open(
  WidgetTester tester, {
  Iterable<String> existing = const [],
}) async {
  final results = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
              await showAddChapterDialog(context, existingNames: existing),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  testWidgets('returns the trimmed name', (tester) async {
    final results = await _open(tester);

    await tester.enterText(find.byType(TextField), '  Kings Gambit  ');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(results, ['Kings Gambit']);
  });

  testWidgets('cancelling returns nothing', (tester) async {
    final results = await _open(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(results, [null]);
  });

  testWidgets('an empty name is refused inline, not by closing', (
    tester,
  ) async {
    final results = await _open(tester);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Please enter a name'), findsOneWidget);
    expect(results, isEmpty, reason: 'dialog should still be open');
  });

  testWidgets('a duplicate name is refused, case-insensitively', (
    tester,
  ) async {
    final results = await _open(tester, existing: ['Main Line']);

    await tester.enterText(find.byType(TextField), 'main line');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('A chapter named "main line" exists'), findsOneWidget);
    expect(results, isEmpty);

    // Typing clears the error so the field is not permanently red.
    await tester.enterText(find.byType(TextField), 'Main Line 2');
    await tester.pumpAndSettle();
    expect(find.text('A chapter named "main line" exists'), findsNothing);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(results, ['Main Line 2']);
  });

  testWidgets('submitting from the keyboard works like Create', (tester) async {
    final results = await _open(tester);

    await tester.enterText(find.byType(TextField), 'Sideline');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(results, ['Sideline']);
  });
}
