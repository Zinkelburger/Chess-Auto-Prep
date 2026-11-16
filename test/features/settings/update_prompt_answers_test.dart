// The update question's answers: Enter is Later, a second answer given
// at once is not taken, and a failed download's bar is empty.
import 'dart:io';

import 'package:chess_auto_prep/features/settings/app_updates.dart';
import 'package:chess_auto_prep/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/features/settings/settings_dialog.dart';
import 'package:chess_auto_prep/features/settings/update_prompt.dart';
import 'package:chess_auto_prep/features/settings/update_rows.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/storage/update_install.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_releases.dart';

void main() {
  late Directory root;
  late SettingsStore settings;
  late ScriptedReleases releases;
  late AppUpdates updates;
  final navigator = GlobalKey<NavigatorState>();

  /// How often the prompt asked the app to close, and what the app said.
  late int closes;
  late bool appCloses;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('update-prompt-');
    settings = SettingsStore();
    releases = ScriptedReleases();
    closes = 0;
    appCloses = true;
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
          closeApp: () async {
            closes++;
            return appCloses;
          },
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

  /// Lets the download, the files and the stand-in helper do their work,
  /// then draws what came of it. The tap that started them ran in the
  /// test's clock, so every file answer needs a turn of real time and a
  /// pump to go on from. The bar never settles while it waits, so nothing
  /// here pumps until settled.
  Future<void> work(WidgetTester tester) async {
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  LinearProgressIndicator bar(WidgetTester tester) =>
      tester.widget(find.byType(LinearProgressIndicator));

  testWidgets('Enter on the question answers Later, never Update now', (
    tester,
  ) async {
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    expect(find.text('Chess Auto Prep 1.17.0 is available'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Chess Auto Prep 1.17.0 is available'), findsNothing);
    expect(closes, 0);
    expect(settings.value.updates.skipped, isNull);
  });

  testWidgets('two answers at once are taken as the first', (tester) async {
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Later'));
    await tester.tap(find.text('Skip this version'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget);
    expect(settings.value.updates.skipped, isNull);
  });

  testWidgets('a download that failed shows an empty bar', (tester) async {
    releases.bytes = [5, 4, 3, 2, 1];
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update now'));
    await work(tester);
    expect(updates.status, isA<UpdateFailed>());
    expect(bar(tester).value, 0);
  });
}
