import 'package:chess_auto_prep/features/settings/controllers/eval_database_settings.dart';
import 'package:chess_auto_prep/features/settings/models/eval_database_configuration.dart';
import '../../support/runtime_settings.dart';
import 'dart:io';
import 'dart:math';

import 'package:chess_auto_prep/services/eval/cdb_snapshot_catalog.dart';
import 'package:chess_auto_prep/services/eval/cdb_snapshot_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Serves one snapshot file, honouring byte ranges, and records whether the
/// client asked to resume.
class _FakeMirror {
  _FakeMirror(this.payload);

  final List<int> payload;
  late final HttpServer _server;
  final List<String?> rangeHeaders = [];

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      rangeHeaders.add(range);
      var start = 0;
      if (range != null) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${payload.length - 1}/${payload.length}',
        );
      }
      request.response.add(payload.sublist(start));
      await request.response.close();
    });
  }

  Uri urlFor(String repoPath) =>
      Uri.parse('http://127.0.0.1:${_server.port}/$repoPath');

  Future<void> stop() => _server.close(force: true);
}

void main() {
  // The test binding otherwise answers every socket with an empty 400.
  setUpAll(() => HttpOverrides.global = null);

  late MemorySettingsSection<EvalDatabaseConfiguration> settingsStorage;
  late EvalDatabaseSettings settings;
  late Directory tmp;
  late _FakeMirror mirror;
  late CdbSnapshot snapshot;
  late List<int> payload;

  const fileBytes = 4096;
  const repoPath = 'chess-20260702/data/000001.sst';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settingsStorage = MemorySettingsSection(EvalDatabaseConfiguration());
    settings = EvalDatabaseSettings(settingsStorage);
    await settings.ensureLoaded();
    tmp = await Directory.systemTemp.createTemp('cdb_download_test');
    final rng = Random(7);
    payload = List<int>.generate(fileBytes, (_) => rng.nextInt(256));
    mirror = _FakeMirror(payload);
    await mirror.start();
    snapshot = const CdbSnapshot(
      id: 'chess-20260702',
      files: [CdbSnapshotFile(path: repoPath, bytes: fileBytes)],
    );
  });

  tearDown(() async {
    settings.dispose();
    await mirror.stop();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  CdbSnapshotDownloadController newController() =>
      CdbSnapshotDownloadController(
        settings: settings,
        concurrency: 1,
        urlBuilder: mirror.urlFor,
      );

  File localFile() => File(p.join(tmp.path, repoPath));

  test('a fresh download writes the whole file', () async {
    final controller = newController();
    await controller.prepare(snapshot: snapshot, parentDir: tmp.path);
    expect(controller.bytesDone, 0);

    await controller.start();

    expect(controller.phase, CdbDownloadPhase.complete);
    expect(controller.bytesDone, fileBytes);
    expect(controller.filesDone, 1);
    expect(await localFile().readAsBytes(), payload);
    expect(mirror.rangeHeaders, [null]);
    controller.dispose();
  });

  test(
    'activation failure retains complete files and retries only settings',
    () async {
      final controller = newController();
      await controller.prepare(snapshot: snapshot, parentDir: tmp.path);
      settingsStorage.failure = StateError('settings unavailable');

      await controller.start();

      expect(controller.phase, CdbDownloadPhase.complete);
      expect(controller.error, isNull);
      expect(await localFile().readAsBytes(), payload);
      expect(settings.state.error, isNotNull);
      expect(settings.committed.enableCdbDirect, isFalse);
      expect(mirror.rangeHeaders, [null]);
      settingsStorage.failure = null;
      await settings.retry();
      expect(settings.committed.enableCdbDirect, isTrue);
      expect(settings.committed.cdbDirectPath, controller.dataDirectory);
      expect(mirror.rangeHeaders, [null]);
      await controller.close();
      controller.dispose();
    },
  );

  test(
    'invalid manual activation preserves selection and publishes failure',
    () async {
      final controller = newController();
      await settings.configureCdbDirectory('/retained/dump');
      await expectLater(
        controller.activateDirectory(tmp.path),
        throwsStateError,
      );
      expect(controller.error, contains('Missing'));
      expect(settings.committed.cdbDirectPath, '/retained/dump');
      expect(settings.committed.enableCdbDirect, isTrue);
      await controller.loadSaved();
      expect(controller.phase, CdbDownloadPhase.idle);
      expect(mirror.rangeHeaders, isEmpty);

      await File(p.join(tmp.path, 'CURRENT')).writeAsString('manifest');
      await File(p.join(tmp.path, '000001.sst')).writeAsBytes(payload);
      await controller.activateDirectory(tmp.path);
      expect(controller.error, isNull);
      expect(settings.committed.cdbDirectPath, tmp.path);
      expect(settings.committed.enableCdbDirect, isTrue);
      await controller.close();
      controller.dispose();
    },
  );

  test(
    'failed selection clear keeps files until explicit delete succeeds',
    () async {
      final controller = newController();
      await controller.prepare(snapshot: snapshot, parentDir: tmp.path);
      await controller.start();
      settingsStorage.failure = StateError('preferences unavailable');

      await expectLater(controller.deleteFiles(), throwsStateError);
      expect(await localFile().exists(), isTrue);
      expect(controller.snapshot, snapshot);
      expect(controller.error, contains('preferences unavailable'));
      expect(settings.committed.enableCdbDirect, isTrue);

      settingsStorage.failure = null;
      await controller.deleteFiles();
      expect(await localFile().exists(), isFalse);
      expect(settings.committed.cdbDirectPath, isEmpty);
      expect(settings.committed.enableCdbDirect, isFalse);
      await settings.retry();
      expect(settings.committed.enableCdbDirect, isFalse);
      await controller.close();
      controller.dispose();
    },
  );

  test('a partial file resumes with a range request', () async {
    final target = localFile();
    await target.parent.create(recursive: true);
    await target.writeAsBytes(payload.sublist(0, 1500));

    final controller = newController();
    await controller.prepare(snapshot: snapshot, parentDir: tmp.path);
    expect(controller.bytesDone, 1500, reason: 'partial bytes already count');

    await controller.start();

    expect(mirror.rangeHeaders, ['bytes=1500-']);
    expect(await target.readAsBytes(), payload);
    expect(controller.phase, CdbDownloadPhase.complete);
    controller.dispose();
  });

  test('a file longer than the manifest is fetched again from zero', () async {
    final target = localFile();
    await target.parent.create(recursive: true);
    await target.writeAsBytes([...payload, 1, 2, 3]);

    final controller = newController();
    await controller.prepare(snapshot: snapshot, parentDir: tmp.path);
    expect(controller.bytesDone, 0, reason: 'an oversized file counts nothing');

    await controller.start();

    expect(mirror.rangeHeaders, [null]);
    expect(await target.readAsBytes(), payload);
    controller.dispose();
  });

  test('an already complete file is not fetched again', () async {
    final target = localFile();
    await target.parent.create(recursive: true);
    await target.writeAsBytes(payload);

    final controller = newController();
    await controller.prepare(snapshot: snapshot, parentDir: tmp.path);
    expect(controller.phase, CdbDownloadPhase.complete);

    await controller.start();

    expect(mirror.rangeHeaders, isEmpty);
    controller.dispose();
  });

  test('check() reports files that disagree with the manifest', () async {
    final target = localFile();
    await target.parent.create(recursive: true);
    await target.writeAsBytes(payload.sublist(0, 100));

    final controller = newController();
    await controller.prepare(snapshot: snapshot, parentDir: tmp.path);
    final problems = await controller.check();

    expect(problems, hasLength(1));
    expect(problems.single.name, '000001.sst');
    expect(problems.single.expectedBytes, fileBytes);
    expect(problems.single.actualBytes, 100);
    expect(problems.single.isMissing, isFalse);
    controller.dispose();
  });

  test(
    'deleteFiles clears the snapshot directory and the saved state',
    () async {
      final controller = newController();
      await controller.prepare(snapshot: snapshot, parentDir: tmp.path);
      await controller.start();
      expect(await localFile().exists(), isTrue);

      await controller.deleteFiles();

      expect(await Directory(p.join(tmp.path, snapshot.id)).exists(), isFalse);
      expect(controller.phase, CdbDownloadPhase.idle);
      expect(controller.snapshot, isNull);
      controller.dispose();
    },
  );
}
