import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/pgn_import_dialog.dart';

const _pgn = '[Event "Advance"]\n[Result "*"]\n\n1. e4 c6 2. d4 d5 3. e5 *';

Future<PgnImportResult?> _open(WidgetTester tester) async {
  PgnImportResult? captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async =>
                  captured = await showPgnImportDialog(context),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  group('PGN import dialog', () {
    testWidgets('offers the file and the paste box in the same window', (
      tester,
    ) async {
      await _open(tester);

      expect(find.text('Import PGN'), findsOneWidget);
      expect(find.text('Choose a .pgn file…'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('the paste box starts empty, with no sample PGN in it', (
      tester,
    ) async {
      await _open(tester);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration?.hintText, isNull);
    });

    testWidgets('Import stays dead until there are lines to import', (
      tester,
    ) async {
      await _open(tester);

      Finder importButton() => find.widgetWithText(FilledButton, 'Import');
      expect(tester.widget<FilledButton>(importButton()).onPressed, isNull);

      await tester.enterText(find.byType(TextField), _pgn);
      await tester.pump();
      expect(find.text('1 line ready to import'), findsOneWidget);
      expect(tester.widget<FilledButton>(importButton()).onPressed, isNotNull);

      // Back to empty: the count and the button go with it.
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(find.textContaining('ready to import'), findsNothing);
      expect(tester.widget<FilledButton>(importButton()).onPressed, isNull);
    });

    testWidgets('Clear empties a box the user wants to start over in', (
      tester,
    ) async {
      await _open(tester);

      await tester.enterText(find.byType(TextField), _pgn);
      await tester.pump();

      await tester.tap(find.widgetWithText(TextButton, 'Clear'));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      expect(find.textContaining('ready to import'), findsNothing);
    });

    testWidgets('pasted text comes back with no file name attached', (
      tester,
    ) async {
      PgnImportResult? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async =>
                      captured = await showPgnImportDialog(context),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), _pgn);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.gameCount, 1);
      expect(captured!.fileName, isNull);
      expect(captured!.pgnContent, contains('1. e4 c6'));
    });

    testWidgets('the X closes without importing', (tester) async {
      final result = await _open(tester);
      expect(result, isNull);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(find.text('Import PGN'), findsNothing);
    });
  });
}
