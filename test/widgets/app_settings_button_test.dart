import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/screens/settings_screen.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
import 'package:chess_auto_prep/widgets/app_overflow_menu.dart';
import 'package:chess_auto_prep/widgets/app_settings_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(unavailableModes.clear);

  Future<AppState> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    addTearDown(app.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Consumer<AppState>(
            builder: (context, app, _) => Scaffold(
              appBar: AppBar(
                actions: [
                  AppOverflowMenu(
                    entries: [AppMenuEntry(label: 'An action', onRun: () {})],
                  ),
                  const AppModeSwitcher(),
                  // Mimics MainScreen's lazy mounting: a requested view's gear does
                  // not exist until after the mode change has rebuilt the host.
                  AppSettingsButton(
                    key: ValueKey(app.currentMode),
                    mode: app.currentMode,
                    contentBuilder: (_) => Center(
                      child: Text('Preferences for ${app.currentMode.label}'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets(
    'gear opens current view; global navigation reaches an unmounted view',
    (tester) async {
      final app = await pumpHost(tester);
      expect(
        tester.getCenter(find.text('Actions')).dx,
        lessThan(tester.getCenter(find.byType(AppModeSwitcher)).dx),
      );
      expect(
        tester.getCenter(find.byType(AppModeSwitcher)).dx,
        lessThan(tester.getCenter(find.byTooltip('Settings')).dx),
      );
      expect(find.byIcon(Icons.more_vert), findsNothing);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Preferences for Tactics'), findsOneWidget);
      expect(find.text('Your chess usernames'), findsNothing);
      final settingsState = tester.state(find.byType(SettingsScreen));
      expect(find.text('VIEWS'), findsOneWidget);
      expect(find.text('GLOBAL'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('settings-view-repertoireTrainer')),
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SettingsScreen)), same(settingsState));
      expect(app.currentMode, AppMode.repertoireTrainer);
      expect(app.settingsMode, isNull);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Preferences for Repertoire trainer'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      // Reopening still starts in the current view, not the last global tab.
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Preferences for Repertoire trainer'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings navigation respects unavailable views and generation lock',
    (tester) async {
      final app = await pumpHost(tester);
      unavailableModes.add(AppMode.bughouse);
      app.openViewSettings(AppMode.bughouse);
      expect(app.currentMode, AppMode.tactics);
      expect(app.settingsMode, isNull);
      app.setRepertoireGenerating(true);
      app.openViewSettings(AppMode.repertoireTrainer);
      expect(app.currentMode, AppMode.tactics);
      expect(app.settingsMode, isNull);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-view-bughouse')),
        findsNothing,
      );
      final target = find.byKey(
        const ValueKey('settings-view-repertoireTrainer'),
      );
      expect(tester.widget<ListTile>(target).enabled, isFalse);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(find.text('VIEWS'), findsOneWidget);
      expect(app.currentMode, AppMode.tactics);
      expect(tester.takeException(), isNull);
    },
  );
}
