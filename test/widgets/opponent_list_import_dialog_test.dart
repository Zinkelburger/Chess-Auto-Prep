import 'package:chess_auto_prep/widgets/opponent_list_import_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The import dialog must show what a pasted list would do *before* any
/// network call: how many opponents, which rows were skipped, and refuse to
/// import an unusable list.
void main() {
  Future<OpponentImportRequest?> pump(WidgetTester tester) async {
    OpponentImportRequest? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showDialog<OpponentImportRequest>(
                    context: context,
                    builder: (_) => const OpponentListImportDialog(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('import is disabled until a usable list is pasted', (
    tester,
  ) async {
    await pump(tester);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('a pasted list previews the count and skipped rows', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(
      find.byType(TextField).first,
      '{"event": "Spring Open", "opponents": ['
      '{"name": "Jane Doe", "chesscom": "janed", "pairing_prob": 0.4},'
      '{"name": "Bob Roe", "lichess": "bobr"},'
      '{"name": "Nobody"}]}',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Spring Open — 2 opponents'), findsOneWidget);
    expect(find.textContaining('Jane Doe (40%)'), findsOneWidget);
    expect(find.textContaining('Nobody: no chess.com'), findsOneWidget);
    expect(find.text('Import 2 opponents'), findsOneWidget);
  });

  testWidgets('bad JSON shows the parse error and keeps import disabled', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'Jane Doe, janed');
    await tester.pumpAndSettle();
    expect(find.textContaining('Not valid JSON'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('confirming returns the list, months and redownload flag', (
    tester,
  ) async {
    OpponentImportRequest? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await showDialog<OpponentImportRequest>(
                  context: context,
                  builder: (_) => const OpponentListImportDialog(),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).first,
      '[{"name": "Jane Doe", "chesscom": "janed"}]',
    );
    await tester.ensureVisible(find.byType(TextField).last);
    await tester.enterText(find.byType(TextField).last, '3');
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import 1 opponent'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.list.opponents.single.name, 'Jane Doe');
    expect(result!.monthsBack, 3);
    expect(result!.redownloadExisting, isTrue);
  });
}
