import '../../support/runtime_settings.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:provider/provider.dart';
import 'package:chess_auto_prep/widgets/analysis/stockfish_settings_dialog.dart';
import 'package:chess_auto_prep/widgets/engine/inline_engine_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

RuntimeSettings? _runtimeSettings;
RuntimeSettings get runtimeSettings =>
    _runtimeSettings ??= testRuntimeSettings();
void main() {
  setUp(() {
    _runtimeSettings = null;
    addTearDown(() => _runtimeSettings?.dispose());
  });
  testWidgets('engine shortcut edits shared settings and returns to its host', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final engine = runtimeSettings.engine;
    final bulk = runtimeSettings.bulk;
    engine.depth = 12;
    await bulk.setDepth(18);
    await pumpRuntimeWidget(
      tester,
      runtimeSettings,
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: InlineEngineSettings()),
        ),
      ),
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
    expect(find.byKey(const Key('engine-bulk-depth')), findsOneWidget);
    await tester.tap(find.byTooltip('Close settings (Esc)'));
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
    await tester.tap(find.byTooltip('Close settings (Esc)'));
    await tester.pumpAndSettle();
    expect(engine.depth, 20, reason: 'closing the popup commits typed input');
    expect(tester.takeException(), isNull);
  });
}
