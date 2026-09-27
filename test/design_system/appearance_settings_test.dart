import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/app/themed_application.dart';
import 'package:chess_auto_prep/design_system/theme/workspace_theme.dart';
import 'package:chess_auto_prep/features/settings/models/app_appearance.dart';
import 'package:chess_auto_prep/features/settings/widgets/appearance_settings.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'package:chess_auto_prep/widgets/app_overflow_menu.dart';
import 'package:chess_auto_prep/widgets/info_hint.dart';
import '../support/memory_appearance_preferences.dart';

void main() {
  testWidgets(
    'large text in a narrow window keeps busy and failed controls usable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(380, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final disk = MemoryAppearancePreferences()
        ..gate = Completer<void>()
        ..writeFails = true;
      final repository = SharedPreferencesAppSettingsRepository(
        appearance: disk,
      );
      await tester.pumpWidget(
        AppDependencies(
          settings: repository,
          child: ThemedApplication(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(body: AppearanceSettings()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<AppAppearance>>(
              find.byType(SegmentedButton<AppAppearance>),
            )
            .direction,
        Axis.vertical,
      );
      await tester.tap(find.text('Light'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Saving appearance…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      disk.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not confirm'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'system brightness and explicit choices preserve navigator, text and focus',
    (tester) async {
      final disk = MemoryAppearancePreferences();
      final repository = SharedPreferencesAppSettingsRepository(
        appearance: disk,
      );
      final text = TextEditingController();
      final focus = FocusNode();
      addTearDown(text.dispose);
      addTearDown(focus.dispose);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpWidget(
        AppDependencies(
          settings: repository,
          child: ThemedApplication(
            home: Scaffold(
              body: TextField(
                key: const ValueKey('draft'),
                controller: text,
                focusNode: focus,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('draft'));
      Brightness brightness() => Theme.of(tester.element(field)).brightness;
      expect(brightness(), Brightness.dark);
      await tester.enterText(field, 'Retained document');
      final state = tester.state(field);
      final navigator = tester.state(find.byType(Navigator));
      await repository.appearance.setAppearance(AppAppearance.system);
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
      expect(
        Theme.of(tester.element(field)).extension<WorkspaceTheme>(),
        isNotNull,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.dark);
      await repository.appearance.setAppearance(AppAppearance.light);
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
      expect(tester.state(field), same(state));
      expect(tester.state(find.byType(Navigator)), same(navigator));
      expect(focus.hasFocus, isTrue);
      expect(text.text, 'Retained document');
    },
  );

  testWidgets(
    'failed choice leaves applied theme unchanged, then retries and reloads',
    (tester) async {
      final disk = MemoryAppearancePreferences()..writeFails = true;
      final repository = SharedPreferencesAppSettingsRepository(
        appearance: disk,
      );
      await tester.pumpWidget(
        AppDependencies(
          settings: repository,
          child: const ThemedApplication(
            home: Scaffold(body: AppearanceSettings()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not confirm'), findsOneWidget);
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings))).brightness,
        Brightness.dark,
      );
      disk.writeFails = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not confirm'), findsNothing);
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings))).brightness,
        Brightness.light,
      );
      disk.writeFails = true;
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reload saved choice'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<AppAppearance>>(
              find.byType(SegmentedButton<AppAppearance>),
            )
            .selected,
        {AppAppearance.light},
      );
    },
  );

  testWidgets('shared Actions menu uses resolved theme in light mode', (
    tester,
  ) async {
    final disk = MemoryAppearancePreferences()..value = AppAppearance.light;
    final repository = SharedPreferencesAppSettingsRepository(appearance: disk);
    await tester.pumpWidget(
      AppDependencies(
        settings: repository,
        child: ThemedApplication(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AppOverflowMenu(
                  entries: [
                    AppMenuEntry(
                      label: 'Selected choice',
                      hint: 'A contextual hint',
                      checked: true,
                      onRun: () {},
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final anchor = tester.widget<Text>(find.text('Actions'));
    expect(
      anchor.style!.color,
      Theme.of(tester.element(find.text('Actions'))).colorScheme.onSurface,
    );
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    final row = tester.widget<Text>(find.text('Selected choice'));
    final hintIcon = tester.widget<Icon>(
      find.descendant(of: find.byType(InfoHint), matching: find.byType(Icon)),
    );
    expect(
      hintIcon.color,
      Theme.of(
        tester.element(find.byType(InfoHint)),
      ).colorScheme.onSurfaceVariant,
    );
    expect(
      row.style!.color,
      Theme.of(
        tester.element(find.text('Selected choice')),
      ).colorScheme.onSurface,
    );
    expect(tester.takeException(), isNull);
  });
}
