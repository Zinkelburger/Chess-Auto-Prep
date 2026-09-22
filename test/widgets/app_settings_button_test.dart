import 'package:chess_auto_prep/app/runtime_settings.dart';
import '../support/runtime_settings.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/screens/settings_screen.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
import 'package:chess_auto_prep/widgets/app_overflow_menu.dart';
import 'package:chess_auto_prep/widgets/app_settings_button.dart';
import 'package:chess_auto_prep/widgets/settings/settings_navigation.dart';
import 'package:flutter/material.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

RuntimeSettings? _settings;
RuntimeSettings get settings => _settings ??= testRuntimeSettings();
void main() {
  setUp(() {
    _settings = null;
    addTearDown(() => _settings?.dispose());
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(unavailableModes.clear);

  Future<AppState> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    addTearDown(app.dispose);
    await pumpRuntimeWidget(
      tester,
      settings,
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
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

  testWidgets('hover switches from Actions to views without selecting a view', (
    tester,
  ) async {
    final app = await pumpHost(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 100));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Actions')));
    await tester.pumpAndSettle();
    expect(find.text('An action'), findsOneWidget);

    await mouse.moveTo(
      tester.getCenter(find.byKey(AppModeSwitcher.switcherKey)),
    );
    await tester.pumpAndSettle();
    expect(find.text('An action'), findsNothing);
    expect(find.text('Repertoire trainer'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(app.currentMode, AppMode.tactics);
    await tester.tap(find.byKey(AppModeSwitcher.switcherKey));
    await tester.pumpAndSettle();
    expect(find.text('Repertoire trainer'), findsOneWidget);
    await tester.tap(find.text('Repertoire trainer'));
    await tester.pumpAndSettle();
    expect(app.currentMode, AppMode.repertoireTrainer);
    expect(find.byType(MenuItemButton), findsNothing);

    await mouse.moveTo(const Offset(10, 100));
    await mouse.moveTo(
      tester.getCenter(find.byKey(AppModeSwitcher.switcherKey)),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    app.setRepertoireGenerating(true);
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(10, 100));
    await mouse.moveTo(
      tester.getCenter(find.byKey(AppModeSwitcher.switcherKey)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
      expect(find.text('VIEWS'), findsNothing);
      expect(find.text('GLOBAL'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('settings-view-repertoireTrainer')),
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SettingsScreen)), same(settingsState));
      expect(app.currentMode, AppMode.tactics);
      final registry = ViewSettingsRegistry.forApp(app);
      expect(registry.requestedModes, contains(AppMode.repertoireTrainer));
      var inactiveClosed = 0;
      registry.register(
        AppMode.repertoireTrainer,
        Object(),
        (_) => const Text('Training preferences'),
        () => inactiveClosed++,
      );
      await tester.pumpAndSettle();
      expect(find.text('Training preferences'), findsOneWidget);
      await tester.tap(find.byTooltip('Close settings (Esc)'));
      await tester.pumpAndSettle();
      expect(app.currentMode, AppMode.tactics);
      expect(inactiveClosed, 0);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Preferences for Tactics'), findsOneWidget);
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
      expect(tester.widget<ListTile>(target).enabled, isTrue);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(find.text('VIEWS'), findsNothing);
      expect(app.currentMode, AppMode.tactics);
      expect(tester.takeException(), isNull);
    },
  );
}
