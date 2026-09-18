import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/features/settings/controllers/engine_settings.dart';
import 'package:chess_auto_prep/features/settings/models/engine_configuration.dart';
import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:chess_auto_prep/widgets/analysis/stockfish_settings_dialog.dart';
import '../support/runtime_settings.dart';

void main() {
  testWidgets(
    'two settings surfaces show pending edits, committed fields and retry',
    (tester) async {
      final storage = MemorySettingsSection(EngineConfiguration());
      final fallback = testRuntimeSettings();
      final runtime = RuntimeSettings(
        engine: EngineSettings(storage),
        bulk: fallback.bulk,
        display: fallback.display,
        databases: fallback.databases,
      );
      addTearDown(runtime.dispose);
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpRuntimeWidget(
        tester,
        runtime,
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: StockfishSettingsBody()),
                Expanded(child: StockfishSettingsBody()),
              ],
            ),
          ),
        ),
      );
      Finder field(String key, int index) => find.descendant(
        of: find.byKey(Key(key)).at(index),
        matching: find.byType(TextField),
      );
      final gate = Completer<void>();
      storage.writeGate = gate.future;
      await tester.enterText(field('engine-board-depth', 0), '22');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(field('engine-lines', 1), '6');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(runtime.engine.state.phase, SettingsPhase.saving);
      expect(runtime.engine.committed.depth, 15);
      expect(find.text('Saving preferences…'), findsNWidgets(2));
      gate.complete();
      await tester.pumpAndSettle();
      expect(runtime.engine.depth, 22);
      expect(runtime.engine.multiPv, 6);
      expect(
        tester
            .widget<TextField>(field('engine-board-depth', 1))
            .controller!
            .text,
        '22',
      );
      storage.failure = StateError('storage unavailable');
      await tester.enterText(field('engine-board-depth', 0), '25');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(runtime.engine.depth, 22);
      expect(runtime.engine.editing.depth, 25);
      expect(find.text('Retry'), findsNWidgets(2));
      storage.failure = null;
      await tester.tap(find.text('Retry').first);
      await tester.pumpAndSettle();
      expect(runtime.engine.depth, 25);
      expect(find.text('Retry'), findsNothing);
      expect(
        find.text('Saved engine changes apply to the next search or job.'),
        findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
