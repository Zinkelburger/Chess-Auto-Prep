import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/updates/services/app_update_service.dart';
import 'package:chess_auto_prep/features/updates/services/update_installer.dart';
import 'package:chess_auto_prep/features/updates/services/update_release.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Installer extends UpdateInstaller {
  int schedules = 0;
  @override
  Future<InstallKind> detect() async => InstallKind.linuxDeb;
  @override
  Future<File> schedule(
    File payload,
    UpdateRelease release,
    InstallKind kind,
  ) async {
    schedules++;
    return File('${payload.parent.path}/armed')..writeAsStringSync('1');
  }
}

Map<String, dynamic> metadata({
  String tag = 'v1.17.0',
  String? hash,
  int? size,
}) => {
  'draft': false,
  'prerelease': false,
  'tag_name': tag,
  'body': 'Release notes',
  'assets': [
    {
      'name': 'chess-auto-prep-$tag-linux-amd64.deb',
      'state': 'uploaded',
      'size': size ?? 3,
      'digest': hash ?? 'sha256:${sha256.convert([1, 2, 3])}',
      'browser_download_url':
          'https://github.com/Zinkelburger/Chess-Auto-Prep/releases/download/$tag/chess-auto-prep-$tag-linux-amd64.deb',
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('update-tests-');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'numeric version ordering excludes old, prerelease and draft releases',
    () {
      expect(
        UpdateRelease.parse(
          metadata(tag: 'v1.9.0'),
          '1.16.1',
          InstallKind.linuxDeb,
        ),
        isNull,
      );
      expect(
        UpdateRelease.parse(
          metadata(tag: 'v1.16.1'),
          '1.16.1',
          InstallKind.linuxDeb,
        ),
        isNull,
      );
      expect(
        UpdateRelease.parse(
          metadata()..['prerelease'] = true,
          '1.16.1',
          InstallKind.linuxDeb,
        ),
        isNull,
      );
      expect(
        UpdateRelease.parse(
          metadata()..['draft'] = true,
          '1.16.1',
          InstallKind.linuxDeb,
        ),
        isNull,
      );
      expect(
        UpdateRelease.parse(metadata(), '1.16.1', InstallKind.linuxDeb)!.tag,
        'v1.17.0',
      );
    },
  );

  test('missing digest, wrong platform and untrusted URL fail closed', () {
    expect(
      () => UpdateRelease.parse(
        metadata(hash: ''),
        '1.16.1',
        InstallKind.linuxDeb,
      ),
      throwsFormatException,
    );
    expect(
      () => UpdateRelease.parse(
        metadata(),
        '1.16.1',
        InstallKind.windowsInstaller,
      ),
      throwsFormatException,
    );
    final data = metadata();
    (data['assets'] as List).single['browser_download_url'] =
        'https://example.com/update';
    expect(
      () => UpdateRelease.parse(data, '1.16.1', InstallKind.linuxDeb),
      throwsFormatException,
    );
  });

  AppUpdateService service({
    List<int> bytes = const [1, 2, 3],
    Installer? installer,
    void Function()? onRequest,
  }) => AppUpdateService(
    version: () async => '1.16.1',
    directory: () async => dir,
    installer: installer ?? Installer(),
    client: MockClient((request) async {
      onRequest?.call();
      return request.url.host == 'api.github.com'
          ? http.Response(jsonEncode(metadata()), 200)
          : http.Response.bytes(bytes, 200);
    }),
  );

  test(
    'verified auto-download can be scheduled exactly once and cancelled',
    () async {
      final installer = Installer();
      final updates = service(installer: installer);
      addTearDown(updates.dispose);
      await updates.check();
      expect(updates.phase, UpdatePhase.ready);
      expect(
        dir
            .listSync(recursive: true)
            .whereType<File>()
            .single
            .readAsBytesSync(),
        [1, 2, 3],
      );
      await Future.wait([updates.scheduleInstall(), updates.scheduleInstall()]);
      expect(installer.schedules, 1);
      expect(updates.phase, UpdatePhase.scheduled);
      await updates.cancelInstall();
      expect(updates.phase, UpdatePhase.ready);
      expect(dir.listSync(recursive: true).whereType<File>().length, 1);
    },
  );

  test('the same verified payload is reused after an app restart', () async {
    var requests = 0;
    var updates = service(onRequest: () => requests++);
    await updates.check();
    updates.dispose();
    updates = service(onRequest: () => requests++);
    addTearDown(updates.dispose);
    await updates.check();
    expect(updates.phase, UpdatePhase.ready);
    expect(requests, 3); // two release checks, only one payload transfer
  });

  test(
    'missing releases and offline/rate-limited checks stay recoverable',
    () async {
      for (final code in [404, 403, 500]) {
        final updates = AppUpdateService(
          version: () async => '1.16.1',
          directory: () async => dir,
          installer: Installer(),
          client: MockClient((_) async => http.Response('', code)),
        );
        await updates.check();
        expect(
          updates.phase,
          code == 404 ? UpdatePhase.idle : UpdatePhase.failed,
        );
        expect(updates.release, isNull);
        updates.dispose();
      }
    },
  );

  test(
    'corrupt and truncated downloads are removed, never installable',
    () async {
      for (final bytes in [
        [3, 2, 1],
        [1, 2],
        [1, 2, 3, 4],
      ]) {
        final updates = service(bytes: bytes);
        await updates.check();
        expect(updates.phase, UpdatePhase.failed);
        expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
        updates.dispose();
      }
    },
  );

  test(
    'automatic checks are daily; disabling download still announces releases',
    () async {
      var requests = 0;
      final updates = service(onRequest: () => requests++);
      addTearDown(updates.dispose);
      await updates.setAutomaticDownload(false);
      await updates.check(automatic: true);
      expect(updates.phase, UpdatePhase.available);
      await updates.check(automatic: true);
      expect(requests, 1);
      await updates.setAutomaticChecks(false);
      final reloaded = service(onRequest: () => requests++);
      addTearDown(reloaded.dispose);
      await reloaded.initialize();
      expect(reloaded.automaticChecks, isFalse);
      expect(reloaded.automaticDownload, isFalse);
      await reloaded.check(automatic: true);
      expect(requests, 1);
      await reloaded.check();
      expect(requests, 2);
    },
  );
}
