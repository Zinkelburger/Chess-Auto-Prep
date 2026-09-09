import 'package:chess_auto_prep/models/bulk_analysis_settings.dart';
import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/widgets/analysis/stockfish_settings_dialog.dart';
import 'package:chess_auto_prep/widgets/engine/inline_engine_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'popup saves board depth without exposing bulk analysis settings',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final engine = EngineSettings.instance;
      final bulk = BulkAnalysisSettings.instance;
      final boardBefore = engine.depth;
      final bulkBefore = bulk.depth;
      addTearDown(() async {
        engine.depth = boardBefore;
        await bulk.setDepth(bulkBefore);
      });
      engine.depth = 12;
      await bulk.setDepth(18);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: InlineEngineSettings())),
      );
      await tester.tap(find.byTooltip('Engine settings'));
      await tester.pumpAndSettle();
      expect(find.byType(StockfishSettingsBody), findsOneWidget);
      expect(find.text('Search'), findsNothing);
      expect(find.text('8–25'), findsNothing);
      final field = find.descendant(
        of: find.byKey(const Key('engine-board-depth')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '22');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(engine.depth, 22);
      expect(bulk.depth, 18);
      expect(find.byKey(const Key('engine-bulk-depth')), findsNothing);
      await tester.tap(find.byTooltip('Engine settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Engine settings'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '22');
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('engine-board-depth')),
          matching: find.byType(TextField),
        ),
        '20',
      );
      await tester.tapAt(const Offset(700, 500));
      await tester.pumpAndSettle();
      expect(engine.depth, 20, reason: 'closing the popup commits typed input');
      expect(tester.takeException(), isNull);
    },
  );
}
