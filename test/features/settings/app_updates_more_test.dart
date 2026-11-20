// The updater's guards: nothing is checked or downloaded again while a
// download runs, the daily check is an automatic one that offers what it
// finds, a copy updated by hand never queues an install, and Install
// pressed during a download is let go of once the helper is armed.
import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:chess_auto_prep/features/settings/app_updates.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/storage/update_install.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_releases.dart';

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory root;
  late SettingsStore settings;
  late ScriptedReleases releases;

  setUp(() {
    root = Directory.systemTemp.createTempSync('app-updates-more-');
    settings = SettingsStore();
    releases = ScriptedReleases();
  });
  tearDown(() {
    settings.dispose();
    root.deleteSync(recursive: true);
  });

  Future<AppUpdates> started({
    bool automatic = false,
    UpdateInstaller? installer,
    DateTime Function() now = DateTime.now,
    Duration poll = const Duration(hours: 1),
  }) async {
    final updates = scriptedUpdates(
      root,
      releases: releases,
      settings: settings,
      installer: installer,
      automatic: automatic,
      now: now,
      poll: poll,
    );
    addTearDown(updates.dispose);
    await updates.start();
    return updates;
  }

  test('while a download runs, nothing is checked or fetched again', () async {
    final held = StreamController<List<int>>();
    releases.held = held.stream;
    final updates = await started();
    await updates.check();
    final downloading = updates.download();
    await _until(() => releases.downloads == 1);
    expect(updates.status, isA<UpdateDownloading>());
    await updates.check();
    await updates.download();
    expect(releases.checks, 1);
    expect(releases.downloads, 1);
    held.add(releaseBytes);
    await held.close();
    await downloading;
  });

  test('a download starts at nothing done, and bytes after Cancel do not '
      'bring it back', () async {
    final held = StreamController<List<int>>();
    releases.held = held.stream;
    final updates = await started();
    await updates.check();
    final downloading = updates.download();
    expect((updates.status as UpdateDownloading).fraction, 0);
    await _until(() => releases.downloads == 1);
    updates.cancelDownload();
    held.add([1, 2]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(updates.status, isNot(isA<UpdateDownloading>()));
    await held.close();
    await downloading;
    expect(updates.status, isA<UpdateOffered>());
  });

  test('late download headers after Cancel leave a retry intact', () async {
    final updates = await started();
    await updates.check();
    final headers = releases.holdDownload = Completer<void>();
    final first = updates.install();
    await _until(() => releases.downloads == 1);
    updates.cancelDownload();
    expect(updates.status, isA<UpdateOffered>());
    expect(updates.installWhenReady, isFalse);

    releases.holdDownload = null;
    await updates.download();
    final retried = updates.status;
    expect(retried, isA<UpdateDownloaded>());
    headers.complete();
    await first;
    expect(updates.status, same(retried));
  });

  test('the daily check offers what it finds', () async {
    final updates = await started(
      automatic: true,
      poll: const Duration(milliseconds: 10),
    );
    await _until(() => releases.checks == 1);
    await _until(() => updates.prompt != null);
    expect(updates.prompt!.tag, 'v1.17.0');
  });

  test('a copy updated by hand never queues an install', () async {
    final flatpak = UpdateInstaller(
      readHelper: (_) async => '',
      executable: '/app/bin/chess_auto_prep',
      environment: const {'FLATPAK_ID': 'com.example.chess_auto_prep'},
      abi: Abi.linuxX64,
    );
    final updates = await started(installer: flatpak);
    await updates.check();
    await updates.install();
    expect(updates.installWhenReady, isFalse);
  });

  test(
    'Install pressed during a download is let go of once installed',
    () async {
      final held = StreamController<List<int>>();
      releases.held = held.stream;
      final updates = await started();
      await updates.check();
      final downloading = updates.download();
      await _until(() => releases.downloads == 1);
      unawaited(updates.install());
      expect(updates.installWhenReady, isTrue);
      held.add(releaseBytes);
      await held.close();
      await downloading;
      await _until(() => updates.status is UpdateArmed);
      expect(updates.installWhenReady, isFalse);
    },
  );
}
