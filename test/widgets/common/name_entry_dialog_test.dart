/// [showNameEntryDialog] — the one validated name prompt, shared by the
/// chapter and repertoire create/rename flows.
///
/// The four copies it replaced each hand-rolled the error-clearing dance and
/// each spelled the rules slightly differently. These pin the rules once.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/common/name_entry_dialog.dart';

/// Pumps a button that opens the dialog and records what it returned.
Future<void> pumpDialog(
  WidgetTester tester, {
  String initialValue = '',
  bool allowUnchanged = false,
  String? Function(String)? validate,
  required void Function(String?) onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await showNameEntryDialog(
                context,
                title: 'Rename Chapter',
                fieldLabel: 'Chapter Name',
                confirmLabel: 'Rename',
                initialValue: initialValue,
                allowUnchanged: allowUnchanged,
                validate: validate,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('returns the trimmed name on confirm', (tester) async {
    String? result;
    await pumpDialog(tester, allowUnchanged: true, onResult: (r) => result = r);

    await tester.enterText(find.byType(TextField), '  Najdorf  ');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(result, 'Najdorf');
  });

  testWidgets('returns null on cancel', (tester) async {
    String? result = 'unset';
    await pumpDialog(tester, allowUnchanged: true, onResult: (r) => result = r);

    await tester.enterText(find.byType(TextField), 'Najdorf');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('rejects an empty name without closing', (tester) async {
    String? result = 'unset';
    await pumpDialog(tester, allowUnchanged: true, onResult: (r) => result = r);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(find.text('Please enter a name'), findsOneWidget);
    expect(find.text('Rename Chapter'), findsOneWidget, reason: 'still open');
    expect(result, 'unset', reason: 'nothing returned yet');
  });

  testWidgets('shows the caller\'s rule on the field, not after closing', (
    tester,
  ) async {
    String? result = 'unset';
    await pumpDialog(
      tester,
      allowUnchanged: true,
      validate: (name) =>
          name == 'Taken' ? 'A chapter named that exists' : null,
      onResult: (r) => result = r,
    );

    await tester.enterText(find.byType(TextField), 'Taken');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(find.text('A chapter named that exists'), findsOneWidget);
    expect(result, 'unset');
  });

  testWidgets('the error clears on the next keystroke', (tester) async {
    await pumpDialog(tester, allowUnchanged: true, onResult: (_) {});

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Please enter a name'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'K');
    await tester.pumpAndSettle();
    expect(
      find.text('Please enter a name'),
      findsNothing,
      reason: 'a rejected name must not stay marked while it is being fixed',
    );
  });

  testWidgets('an unchanged rename returns null, so no file is moved', (
    tester,
  ) async {
    String? result = 'unset';
    await pumpDialog(
      tester,
      initialValue: 'Najdorf',
      onResult: (r) => result = r,
    );

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('allowUnchanged lets the create case keep its typed name', (
    tester,
  ) async {
    String? result;
    await pumpDialog(
      tester,
      initialValue: 'Najdorf',
      allowUnchanged: true,
      onResult: (r) => result = r,
    );

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(result, 'Najdorf');
  });

  testWidgets('the initial value starts selected, so a rename types over it', (
    tester,
  ) async {
    await pumpDialog(tester, initialValue: 'Najdorf', onResult: (_) {});
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.selection.baseOffset, 0);
    expect(field.controller!.selection.extentOffset, 'Najdorf'.length);
  });

  testWidgets('submitting from the keyboard confirms', (tester) async {
    String? result;
    await pumpDialog(tester, allowUnchanged: true, onResult: (r) => result = r);

    await tester.enterText(find.byType(TextField), 'Najdorf');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(result, 'Najdorf');
  });
}
