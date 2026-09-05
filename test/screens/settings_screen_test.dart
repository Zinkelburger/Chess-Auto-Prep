import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/models/eval_database_settings.dart';
import 'package:chess_auto_prep/screens/settings_screen.dart';
import 'package:chess_auto_prep/widgets/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSettings(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('navigation shows one section and preserves account edits', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(1280, 720));
    expect(find.text('Your chess usernames'), findsOneWidget);
    expect(find.text('Bulk analysis workers'), findsNothing);
    await tester.tap(find.text('Use a personal access token instead'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'unsaved-token');

    await tester.tap(find.byKey(const Key('settings-nav-2')));
    await tester.pumpAndSettle();
    expect(find.text('Bulk analysis workers'), findsOneWidget);
    expect(find.text('Your chess usernames'), findsNothing);

    await tester.tap(find.byKey(const Key('settings-nav-0')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'unsaved-token'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short window can scroll to reset and cancel safely', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(800, 360));
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-nav-4')),
      60,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('settings-nav-4')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Reset settings…'),
      180,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('settings-page-4')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    final workers = EngineSettings.instance.workers;
    await tester.tap(find.text('Reset settings…'));
    await tester.pumpAndSettle();
    expect(find.text('Reset Settings'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(EngineSettings.instance.workers, workers);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow windows expose every category and usable engine controls',
    (tester) async {
      await pumpSettings(tester, const Size(400, 640));
      for (final section in [
        'Repertoires',
        'Engine',
        'Data',
        'About',
        'Accounts',
      ]) {
        await tester.tap(find.byKey(const Key('settings-section-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(section).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: section);
        if (section == 'Engine') {
          expect(find.text('Bulk analysis workers'), findsOneWidget);
          expect(find.byType(SettingsStepperTile), findsNWidgets(2));
        }
      }
    },
  );

  testWidgets(
    'data preferences persist and the databases link returns to the app',
    (tester) async {
      final app = AppState();
      addTearDown(app.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  ),
                  child: const Text('Open settings'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-nav-3')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Years of games'), findsNothing);
      expect(find.textContaining('ChessDB data directory'), findsNothing);
      final settings = EvalDatabaseSettings.instance;
      final before = settings.chessDbApiForExpectimax;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(settings.chessDbApiForExpectimax, !before);
      await settings.setChessDbApiForExpectimax(before);
      await tester.tap(find.text('Open Databases'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(app.currentMode, AppMode.databases);
    },
  );
}
