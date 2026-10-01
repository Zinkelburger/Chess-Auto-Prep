import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:chess_auto_prep/features/settings/app_updates.dart';
import 'package:chess_auto_prep/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/features/settings/update_rows.dart';
import 'package:chess_auto_prep/net/github_releases.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/storage/update_files.dart';
import 'package:chess_auto_prep/storage/update_install.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/scripted_releases.dart';

void main() {
  late Directory root;
  late SettingsStore settings;
  late ScriptedReleases releases;

  setUp(() {
    root = Directory.systemTemp.createTempSync('app-updates-');
    settings = SettingsStore();
    releases = ScriptedReleases();
  });
  tearDown(() {
    settings.dispose();
    root.deleteSync(recursive: true);
  });

  List<File> downloads() => Directory(
    p.join(root.path, 'updates'),
  ).listSync(recursive: true).whereType<File>().toList();

  Future<AppUpdates> started({
    bool automatic = false,
    UpdateInstaller? installer,
    DateTime Function() now = DateTime.now,
    Duration poll = const Duration(hours: 1),
    List<Uri>? opened,
    List<String>? shown,
  }) async {
    final updates = scriptedUpdates(
      root,
      releases: releases,
      settings: settings,
      installer: installer,
      automatic: automatic,
      now: now,
      poll: poll,
      opened: opened,
      shown: shown,
    );
    addTearDown(updates.dispose);
    await updates.start();
    return updates;
  }

  test('an automatic check offers a new version once and downloads it '
      'verified', () async {
    final updates = await started();
    await updates.check(automatic: true);
    expect(updates.prompt!.tag, 'v1.17.0');
    expect(updates.status, isA<UpdateDownloaded>());
    expect(downloads().single.readAsBytesSync(), releaseBytes);
    expect(settings.value.updates.lastChecked, isNotNull);

    updates.later();
    await updates.check(automatic: true);
    expect(updates.prompt, isNull, reason: 'asked once per run');
    expect(releases.downloads, 1, reason: 'the verified file is reused');
  });

  test(
    'a download that fails verification is refused and nothing is kept',
    () async {
      releases.bytes = [5, 4, 3, 2, 1];
      final updates = await started();
      await updates.check();
      await updates.download();
      final failed = updates.status as UpdateFailed;
      expect(failed.problem, UpdateProblem.checksum);
      expect(failed.offer!.tag, 'v1.17.0');
      expect(downloads(), isEmpty);
      await updates.install();
      expect(updates.status, isA<UpdateFailed>(), reason: 'still refused');
    },
  );

  test('Install arms the helper once; cancelling keeps the download', () async {
    final updates = await started();
    await updates.check();
    await Future.wait([updates.install(), updates.install()]);
    final armed = updates.status as UpdateArmed;
    expect(File(armed.armed).existsSync(), isTrue);
    expect(releases.downloads, 1);
    await updates.cancelInstall();
    expect(updates.status, isA<UpdateDownloaded>());
    expect(File(armed.armed).existsSync(), isFalse);
  });

  test('the armed helper is told to reopen the app, and told not to '
      'again', () async {
    final updates = await started();
    await updates.check();
    await updates.setReopen(true);
    await updates.install();
    final armed = updates.status as UpdateArmed;
    final reopen = File(p.join(p.dirname(armed.armed), reopenName));
    expect(reopen.existsSync(), isFalse, reason: 'nothing was armed yet');
    await updates.setReopen(true);
    expect(reopen.existsSync(), isTrue);
    await updates.setReopen(false);
    expect(reopen.existsSync(), isFalse);
  });

  test('a helper that does not start is a failure Try again recovers '
      'from', () async {
    final helper = StandInHelper()..starts = false;
    final updates = await started(
      installer: portableInstaller(root, helper: helper),
    );
    await updates.check();
    await updates.install();
    expect(
      (updates.status as UpdateFailed).problem,
      UpdateProblem.helperNotStarted,
    );
    helper.starts = true;
    await press(updates, 'Try again');
    expect(updates.status, isA<UpdateArmed>());
    expect(releases.downloads, 1);
  });

  test('a helper that has not stopped is asked again, and its folder is '
      'never armed over', () async {
    final helper = StandInHelper();
    final updates = await started(
      installer: portableInstaller(root, helper: helper),
    );
    await updates.check();
    await updates.install();
    expect(updates.status, isA<UpdateArmed>());
    helper.stops = false;
    await updates.cancelInstall();
    expect(updates.status, isNot(isA<UpdateDownloaded>()));
    await updates.install();
    expect(helper.launches, 1, reason: 'not armed while it still runs');
    expect(updates.status, isNot(isA<UpdateArmed>()));
    await press(updates, 'Try again');
    expect(helper.launches, 1);
    expect(updates.status, isNot(isA<UpdateDownloaded>()));
    helper.stops = true;
    await press(updates, 'Try again');
    expect(updates.status, isA<UpdateDownloaded>());
  });

  test('a ready file a killed helper left is not taken for a helper that '
      'did not start', () async {
    final helper = StandInHelper()..starts = false;
    final updates = await started(
      installer: portableInstaller(root, helper: helper),
    );
    await updates.check();
    await updates.download();
    final payload = (updates.status as UpdateDownloaded).payload;
    File(p.join(payload.folder, helperReadyName)).writeAsStringSync('ready');
    await updates.install();
    expect(
      (updates.status as UpdateFailed).problem,
      UpdateProblem.helperNotStarted,
    );
  });

  test('a second check keeps the download it already has', () async {
    final updates = await started();
    await updates.check();
    await updates.download();
    final had = updates.status as UpdateDownloaded;
    await updates.check();
    expect(updates.status, isA<UpdateDownloaded>());
    expect((updates.status as UpdateDownloaded).payload.path, had.payload.path);
  });

  test('pressing Cancel twice while downloading is harmless', () async {
    final held = StreamController<List<int>>();
    releases.held = held.stream;
    final updates = await started();
    await updates.check();
    final downloading = updates.download();
    await until(() => releases.downloads == 1);
    held.add([1, 2]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    updates.cancelDownload();
    updates.cancelDownload();
    await downloading;
    expect(updates.status, isA<UpdateOffered>());
    await held.close();
  });

  test('a skipped version is neither offered nor downloaded again; a newer '
      'one is', () async {
    await settings.update(
      settings.value.copyWith(
        updates: settings.value.updates.copyWith(downloadAutomatically: true),
      ),
    );
    final first = await started();
    await first.check(automatic: true);
    first.skip(first.prompt!);
    expect(settings.value.updates.skipped, 'v1.17.0');

    final releases2 = ScriptedReleases();
    releases = releases2;
    final second = await started();
    await second.check(automatic: true);
    expect(second.prompt, isNull);
    expect(second.status, isA<UpdateOffered>(), reason: 'Settings still shows');
    expect(releases2.downloads, 0);

    releases2.answer = LatestRelease(parseRelease(releaseJson(tag: 'v1.18.0')));
    await second.check(automatic: true);
    expect(second.prompt!.tag, 'v1.18.0');
  });

  test("a failed install's report is shown at the next start only", () async {
    Directory(p.join(root.path, 'updates')).createSync();
    File(
      p.join(root.path, 'updates', 'last-error.txt'),
    ).writeAsStringSync('Update installation failed (exit 1).');
    final next = await started();
    expect(next.previousFailure, contains('exit 1'));
    final after = await started();
    expect(after.previousFailure, isNull);
  });

  test('Show log opens the attempt folder holding install.log', () async {
    final attempt = Directory(p.join(root.path, 'updates', 'v1.17.0-a'))
      ..createSync(recursive: true);
    File(p.join(root.path, 'updates', 'last-error.txt')).writeAsStringSync(
      'Update installation failed (exit 1). '
      'Details: ${p.join(attempt.path, 'install.log')}',
    );
    final shown = <String>[];
    final updates = await started(shown: shown);
    actionOf(updates, 'Show log').run!();
    expect(shown, [attempt.path]);
  });

  test('network trouble is quiet when automatic, said when asked', () async {
    releases.answer = const ReleaseCheckFailed(ReleaseProblem.unreachable);
    final updates = await started();
    await updates.check(automatic: true);
    expect(updates.status, isA<NotChecked>());
    await updates.check();
    expect((updates.status as UpdateFailed).problem, UpdateProblem.unreachable);
    releases.answer = const ReleaseCheckFailed(ReleaseProblem.rateLimited);
    await updates.check();
    expect((updates.status as UpdateFailed).problem, UpdateProblem.rateLimited);
    releases.answer = const NoRelease();
    await updates.check();
    expect(updates.status, isA<UpToDate>());
  });

  test('a copy updated by hand is sent to the release page', () async {
    final opened = <Uri>[];
    final flatpak = UpdateInstaller(
      readHelper: (_) async => '',
      executable: '/app/bin/chess_auto_prep',
      environment: const {'FLATPAK_ID': 'com.example.chess_auto_prep'},
      abi: Abi.linuxX64,
    );
    final updates = await started(installer: flatpak, opened: opened);
    await updates.check(automatic: true);
    final offer = updates.prompt!;
    expect(offer.installable, isFalse);
    expect(releases.downloads, 0);
    await updates.accept(offer);
    expect(opened.single.path, endsWith('/releases/tag/v1.17.0'));
    await updates.install();
    expect(updates.status, isA<UpdateOffered>());
  });

  test(
    'cancelling a download returns to the offer and keeps nothing',
    () async {
      final held = StreamController<List<int>>();
      releases.held = held.stream;
      await settings.update(
        settings.value.copyWith(
          updates: settings.value.updates.copyWith(
            downloadAutomatically: false,
          ),
        ),
      );
      final updates = await started();
      await updates.check(automatic: true);
      final downloading = updates.download();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      held.add([1, 2]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(updates.status, isA<UpdateDownloading>());
      updates.cancelDownload();
      await downloading;
      expect(updates.status, isA<UpdateOffered>());
      expect(downloads(), isEmpty);
      await held.close();
    },
  );

  test('Cancel before the download starts also cancels the install', () async {
    final helper = StandInHelper();
    final updates = await started(
      installer: portableInstaller(root, helper: helper),
    );
    await updates.check();
    final hold = releases.holdDownload = Completer<void>();
    final pending = updates.install();
    await until(() => releases.downloads == 1);
    expect(updates.status, isA<UpdateDownloading>());
    updates.cancelDownload();
    hold.complete();
    await pending;
    expect(updates.status, isA<UpdateOffered>());
    expect(updates.installWhenReady, isFalse);

    releases.holdDownload = null;
    await updates.check(automatic: true);
    expect(updates.status, isA<UpdateDownloaded>());
    expect(helper.launches, 0, reason: 'the install stays cancelled');
  });

  test('Cancel while a kept download is checked arms nothing', () async {
    final first = await started();
    await first.check();
    await first.download();
    expect(first.status, isA<UpdateDownloaded>());

    final helper = StandInHelper();
    final updates = await started(
      installer: portableInstaller(root, helper: helper),
    );
    await updates.check();
    final pending = updates.install();
    expect(updates.status, isA<UpdateDownloading>());
    updates.cancelDownload();
    await pending;
    expect(updates.status, isA<UpdateOffered>());
    expect(updates.installWhenReady, isFalse);
    expect(helper.launches, 0);
  });

  test('checks run after start-up and then once a day', () async {
    var now = DateTime.utc(2026, 9, 28, 12);
    final updates = await started(
      automatic: true,
      now: () => now,
      poll: const Duration(milliseconds: 10),
    );
    await until(() => releases.checks == 1);
    now = now.add(const Duration(hours: 23));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(releases.checks, 1);
    now = now.add(const Duration(hours: 2));
    await until(() => releases.checks == 2);
    await updates.setCheckAutomatically(false);
    now = now.add(const Duration(days: 2));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(releases.checks, 2);
  });

  test('nothing is published after the owner is gone', () async {
    final slow = Completer<ReleaseCheck>();
    final updates = scriptedUpdates(
      root,
      releases: _Slow(slow.future),
      settings: settings,
    );
    await updates.start();
    final checking = updates.check();
    updates.dispose();
    slow.complete(const NoRelease());
    await checking;
    expect(settings.value.updates.lastChecked, isNull);
  });
}

/// The App page's update action labelled [label].
ActionSetting actionOf(AppUpdates updates, String label) => updateRows(updates)
    .map((row) => row.control)
    .whereType<ActionSetting>()
    .singleWhere((action) => action.label == label);

/// Presses the update row's [label] action and waits until what it
/// started has settled.
Future<void> press(AppUpdates updates, String label) async {
  final action = actionOf(updates, label);
  var told = 0;
  void count() => told++;
  updates.addListener(count);
  action.run!();
  await until(
    () =>
        told > 0 &&
        switch (updates.status) {
          UpdateArming() || CheckingForUpdate() || UpdateDownloading() => false,
          _ => true,
        },
  );
  updates.removeListener(count);
}

/// Waits up to two seconds for [condition], for timers that run in real
/// time on a machine that may be busy.
Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

final class _Slow extends ScriptedReleases {
  _Slow(this.answerLater);

  final Future<ReleaseCheck> answerLater;

  @override
  Future<ReleaseCheck> latest() => answerLater;
}
