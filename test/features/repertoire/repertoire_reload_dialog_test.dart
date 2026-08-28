import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoire/models/repertoire_reload_summary.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_reload_dialog.dart';

Future<void> _open(
  WidgetTester tester,
  Future<RepertoireReloadSummary> Function() reload,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  showRepertoireReloadDialog(context, reload: reload),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pump();
}

void main() {
  group('reload dialog', () {
    testWidgets('holds a spinner while the file is being re-read', (
      tester,
    ) async {
      final gate = Completer<RepertoireReloadSummary>();
      await _open(tester, () => gate.future);

      expect(find.text('Checking the file on disk…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Nothing to close yet — closing mid-read would leave the reload
      // finishing behind a window that is already gone.
      expect(find.widgetWithText(FilledButton, 'Done'), findsNothing);

      gate.complete(
        const RepertoireReloadSummary(
          added: [],
          removed: [],
          edited: 0,
          total: 4,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('says so plainly when the file has not changed', (
      tester,
    ) async {
      await _open(
        tester,
        () async => const RepertoireReloadSummary(
          added: [],
          removed: [],
          edited: 0,
          total: 4,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No changes on disk'), findsOneWidget);
      expect(find.textContaining('same 4 lines'), findsOneWidget);
    });

    testWidgets('names what the file gained and lost', (tester) async {
      await _open(
        tester,
        () async => const RepertoireReloadSummary(
          added: ['Advance Variation'],
          removed: ['Exchange Variation'],
          edited: 2,
          total: 9,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('New lines found on disk'), findsOneWidget);
      expect(find.text('Advance Variation'), findsOneWidget);
      expect(find.text('Exchange Variation'), findsOneWidget);
      expect(
        find.textContaining('2 lines kept the same moves'),
        findsOneWidget,
      );
    });

    testWidgets('a failed read reports the error instead of a verdict', (
      tester,
    ) async {
      await _open(tester, () async => throw StateError('no file'));
      await tester.pumpAndSettle();

      expect(find.text('Could not read the file'), findsOneWidget);
      expect(find.text('No changes on disk'), findsNothing);
    });

    testWidgets('closes on the X once there is a result to close', (
      tester,
    ) async {
      await _open(
        tester,
        () async => const RepertoireReloadSummary(
          added: [],
          removed: [],
          edited: 0,
          total: 1,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(find.text('Checked the file on disk'), findsNothing);
    });
  });
}
