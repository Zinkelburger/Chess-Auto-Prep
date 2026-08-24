/// The starting-position controls in the new-tournament dialog: edit the
/// board visually, and copy the FEN you ended up with.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/widgets/new_tournament_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _engines = [
  EngineSpec(id: 'a', name: 'Alpha', executablePath: '/bin/a'),
  EngineSpec(id: 'b', name: 'Beta', executablePath: '/bin/b'),
];

const _boardFen =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

/// Records what the app puts on the clipboard.
List<String> _captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

Future<void> _openDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      // `showAppSnackBar` sets an explicit width, which Material asserts is
      // only legal for a floating snackbar — as the real app's theme says.
      theme: ThemeData(
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showNewTournamentDialog(
                context,
                engines: _engines,
                boardFen: _boardFen,
                onManageEngines: () {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Copy puts the FEN in play on the clipboard', (tester) async {
    final copied = _captureClipboard(tester);
    await _openDialog(tester);

    await tester.tap(find.text('Current board position'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, [_boardFen]);
  });

  testWidgets('Edit board… opens the editor and applies its position', (
    tester,
  ) async {
    await _openDialog(tester);

    await tester.tap(find.text('Edit board…'));
    await tester.pumpAndSettle();
    expect(find.text('Set up position'), findsOneWidget);

    await tester.tap(find.text('Use this position'));
    await tester.pumpAndSettle();

    // Back in the setup dialog, with the editor's position in the FEN field.
    expect(find.text('Set up position'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      kStandardStartFen,
    );
  });
}
