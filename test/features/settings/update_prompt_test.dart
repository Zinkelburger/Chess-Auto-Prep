import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:chess_auto_prep/features/settings/app_updates.dart';
import 'package:chess_auto_prep/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/features/settings/settings_dialog.dart';
import 'package:chess_auto_prep/features/settings/update_prompt.dart';
import 'package:chess_auto_prep/features/settings/update_rows.dart';
import 'package:chess_auto_prep/net/github_releases.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/storage/update_files.dart';
import 'package:chess_auto_prep/storage/update_install.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

  /// Taps [text]; the question was raised from a real-async check, so its
  /// answer is taken in real time.
  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
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

  /// Ends the stand-in helper a test left armed: it watches its marker on
  /// the test's clock.
  Future<void> disarm(WidgetTester tester) async {
    File((updates.status as UpdateArmed).armed).deleteSync();
    await tester.pump(const Duration(milliseconds: 10));
  }

  LinearProgressIndicator bar(WidgetTester tester) =>
      tester.widget(find.byType(LinearProgressIndicator));

  File reopenMarker() => File(
    p.join(p.dirname((updates.status as UpdateArmed).armed), reopenName),
  );

  testWidgets('a new version is asked about once: Skip remembers it', (
    tester,
  ) async {
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    expect(find.text('Chess Auto Prep 1.17.0 is available'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Update now'), findsOneWidget);
    expect(find.text('When I close the app'), findsOneWidget);
    await tapText(tester, 'Skip this version');
    expect(find.text('Chess Auto Prep 1.17.0 is available'), findsNothing);
    expect(settings.value.updates.skipped, 'v1.17.0');
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Update now shows the download in the question, then closes '
      'the app for a helper told to reopen it', (tester) async {
    final bytes = StreamController<List<int>>();
    releases.held = bytes.stream;
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update now'));
    await work(tester);
    expect(find.text('Updating to Chess Auto Prep 1.17.0'), findsOneWidget);
    expect(find.text('Downloading… 0%'), findsOneWidget);
    expect(bar(tester).value, 0);

    bytes.add(releaseBytes.sublist(0, 3));
    await work(tester);
    expect(find.text('Downloading… 60%'), findsOneWidget);
    expect(bar(tester).value, closeTo(0.6, 0.001));
    expect(closes, 0);

    // Escape does not take the question away while it updates.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await work(tester);
    expect(find.byType(AlertDialog), findsOneWidget);

    bytes.add(releaseBytes.sublist(3));
    await tester.runAsync(bytes.close);
    await work(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(updates.status, isA<UpdateArmed>());
    expect(closes, 1);
    expect(reopenMarker().existsSync(), isTrue);
    await disarm(tester);
  });

  testWidgets('an app the user kept open after Update now installs on a '
      'later close without reopening', (tester) async {
    appCloses = false;
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update now'));
    await work(tester);
    expect(closes, 1);
    expect(updates.status, isA<UpdateArmed>());
    expect(reopenMarker().existsSync(), isFalse);
    await disarm(tester);
  });

  testWidgets('Cancel stops the download Update now started and closes the '
      'question', (tester) async {
    final bytes = StreamController<List<int>>();
    releases.held = bytes.stream;
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update now'));
    await work(tester);
    await tester.tap(find.text('Cancel').last);
    await work(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(updates.status, isA<UpdateOffered>());
    expect(updates.installWhenReady, isFalse);
    expect(closes, 0);
    await tester.runAsync(bytes.close);
  });

  testWidgets('a download that fails says why in the question; Try again '
      'goes on', (tester) async {
    releases.bytes = [9, 9, 9, 9, 9];
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update now'));
    await work(tester);
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(
        of: dialog,
        matching: find.text(problemText(UpdateProblem.checksum)),
      ),
      findsOneWidget,
    );
    expect(closes, 0);

    releases.bytes = releaseBytes;
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('Try again')),
    );
    await work(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(closes, 1);
    await disarm(tester);
  });

  testWidgets('When I close the app arms the helper and leaves the app '
      'open', (tester) async {
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    await tapText(tester, 'When I close the app');
    await work(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(updates.status, isA<UpdateArmed>());
    expect(closes, 0);
    expect(reopenMarker().existsSync(), isFalse);
    expect(find.text('Cancel installation'), findsOneWidget);
    await disarm(tester);
  });

  testWidgets('Escape closes the question and the Settings row keeps the '
      'offer', (tester) async {
    await pump(tester);
    await tester.runAsync(() => updates.check(automatic: true));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
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
