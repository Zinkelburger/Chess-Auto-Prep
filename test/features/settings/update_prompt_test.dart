import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:chess_auto_prep/features/settings/app_updates.dart';
import 'package:chess_auto_prep/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/features/settings/settings_dialog.dart';
import 'package:chess_auto_prep/features/settings/update_prompt.dart';
import 'package:chess_auto_prep/features/settings/update_rows.dart';
import 'package:chess_auto_prep/net/github_releases.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/storage/update_install.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_releases.dart';

void main() {
  late Directory root;
  late SettingsStore settings;
  late ScriptedReleases releases;
  late AppUpdates updates;
  final navigator = GlobalKey<NavigatorState>();

  setUp(() async {
    root = Directory.systemTemp.createTempSync('update-prompt-');
    settings = SettingsStore();
    releases = ScriptedReleases();
    // Nothing downloads by itself here: the tests are about what is asked.
    await settings.update(
      settings.value.copyWith(
        updates: settings.value.updates.copyWith(downloadAutomatically: false),
      ),
    );
  });
  tearDown(() {
    updates.dispose();
    settings.dispose();
    root.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, {UpdateInstaller? installer}) async {
    updates = scriptedUpdates(
      root,
      releases: releases,
      settings: settings,
      installer: installer,
    );
    await tester.runAsync(updates.start);
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        navigatorKey: navigator,
        home: UpdatePrompt(
          updates: updates,
          navigator: navigator,
          child: Scaffold(
            body: SettingsDialog(
              store: settings,
              groups: () => [SettingGroup('App', updateRows(updates))],
              also: updates,
            ),
          ),
        ),
      ),
    );
  }

  /// Taps [text]; the question was raised from a real-async check, so its
  /// answer is taken in real time.
  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets('a new version is asked about once: Skip remembers it', (
    tester,
  ) async {
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    expect(find.text('Chess Auto Prep 1.17.0 is available'), findsOneWidget);
    expect(find.text('Install'), findsWidgets);
    expect(find.text('Later'), findsOneWidget);
    await tapText(tester, 'Skip this version');
    expect(find.text('Chess Auto Prep 1.17.0 is available'), findsNothing);
    expect(settings.value.updates.skipped, 'v1.17.0');
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Later closes the question and the Settings row keeps the '
      'offer', (tester) async {
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    await tapText(tester, 'Later');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Chess Auto Prep 1.17.0'), findsOneWidget);
    expect(
      find.text('Available · installs when you close the app'),
      findsOneWidget,
    );
  });

  testWidgets('Settings ▸ App shows the version, Check now and the switches', (
    tester,
  ) async {
    releases.answer = const NoRelease();
    await pump(tester);
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('1.16.1 · not checked yet'), findsOneWidget);
    expect(find.text('Check for updates automatically'), findsOneWidget);
    expect(find.text('Download updates automatically'), findsOneWidget);
    await tester.tap(find.text('Check now'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('1.16.1 · up to date · checked just now'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing, reason: 'asked, not told');

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(settings.value.updates.checkAutomatically, isFalse);
  });

  testWidgets('a copy updated by hand offers Download, not Install', (
    tester,
  ) async {
    await pump(
      tester,
      installer: UpdateInstaller(
        readHelper: (_) async => '',
        executable: '/app/bin/chess_auto_prep',
        environment: const {'FLATPAK_ID': 'x'},
        abi: Abi.linuxX64,
      ),
    );
    expect(find.text('Download updates automatically'), findsNothing);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Download'), findsOneWidget);
    await tapText(tester, 'Later');
    expect(find.text('Open releases'), findsOneWidget);
  });
}
