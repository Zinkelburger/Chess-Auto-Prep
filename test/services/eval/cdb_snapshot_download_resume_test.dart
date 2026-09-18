import 'dart:async';
import 'package:chess_auto_prep/features/settings/controllers/eval_database_settings.dart';
import 'package:chess_auto_prep/features/settings/models/eval_database_configuration.dart';
import '../../support/runtime_settings.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chess_auto_prep/services/eval/cdb_snapshot_catalog.dart';
import 'package:chess_auto_prep/services/eval/cdb_snapshot_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Serves several snapshot files by repo path, with knobs for the ways a real
/// mirror misbehaves: ignoring ranges, answering an error once, or trickling
/// bytes slowly enough to be paused mid-file.
class _Mirror {
  _Mirror(this.payloads);

  final Map<String, List<int>> payloads;
  late final HttpServer _server;

  /// `Range` header of every request, in arrival order (null = none).
  final List<String?> ranges = [];

  /// Answer every request with 200 and the whole file, range or not.
  bool ignoreRanges = false;

  /// Status codes to answer the next requests with, consumed one per request.
  final List<int> failNextWith = [];

  /// When set, bodies are sent in pieces of this size with [chunkDelay] between.
  int? chunkBytes;
  Duration chunkDelay = const Duration(milliseconds: 30);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      // Small writes sit in HttpResponse's own buffer until close unless
      // this is off, which would deliver a trickled body all at once.
      final response = request.response..bufferOutput = false;
      if (failNextWith.isNotEmpty) {
        response.statusCode = failNextWith.removeAt(0);
        await response.close();
        return;
      }
      final payload = payloads[request.uri.path.substring(1)];
      if (payload == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      var start = 0;
      if (range != null && !ignoreRanges) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${payload.length - 1}/${payload.length}',
        );
      }
      final body = payload.sublist(start);
      final size = chunkBytes;
      if (size == null) {
        response.add(body);
      } else {
        for (var at = 0; at < body.length; at += size) {
          response.add(body.sublist(at, min(at + size, body.length)));
          await response.flush();
          await Future<void>.delayed(chunkDelay);
        }
      }
      await response.close();
    });
  }

  Uri urlFor(String repoPath) =>
      Uri.parse('http://127.0.0.1:${_server.port}/$repoPath');

  Future<void> stop() => _server.close(force: true);
}

void main() {
  // The test binding otherwise answers every socket with an empty 400.
  setUpAll(() => HttpOverrides.global = null);

  const id = 'chess-20260702';
  const mainPath = '$id/data/000001.sst';
  const fileBytes = 4096;

  late MemorySettingsSection<EvalDatabaseConfiguration> settingsStorage;
  late EvalDatabaseSettings settings;
  late Directory tmp;
  late _Mirror mirror;
  late List<int> payload;

  List<int> bytesFor(int seed, int length) {
    final rng = Random(seed);
    return List<int>.generate(length, (_) => rng.nextInt(256));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settingsStorage = MemorySettingsSection(EvalDatabaseConfiguration());
    settings = EvalDatabaseSettings(settingsStorage);
    await settings.ensureLoaded();
    tmp = await Directory.systemTemp.createTemp('cdb_download_resume');
    payload = bytesFor(7, fileBytes);
    mirror = _Mirror({mainPath: payload});
    await mirror.start();
  });

  tearDown(() async {
    settings.dispose();
    await mirror.stop();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  const single = CdbSnapshot(
    id: id,
    files: [CdbSnapshotFile(path: mainPath, bytes: fileBytes)],
  );

  CdbSnapshotDownloadController controller({int concurrency = 1}) =>
      CdbSnapshotDownloadController(
        settings: settings,
        concurrency: concurrency,
        urlBuilder: mirror.urlFor,
      );

  File local(String repoPath) => File(p.join(tmp.path, repoPath));

  Future<void> writePartial(String repoPath, List<int> bytes) async {
    final file = local(repoPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('a mirror that ignores the range restarts the file from zero', () async {
    await writePartial(mainPath, payload.sublist(0, 1500));
    mirror.ignoreRanges = true;

    final c = controller();
    await c.prepare(snapshot: single, parentDir: tmp.path);
    expect(c.bytesDone, 1500);

    await c.start();

    // Refused once, then fetched whole on the retry — never appended.
    expect(mirror.ranges, ['bytes=1500-', null]);
    expect(await local(mainPath).readAsBytes(), payload);
    expect(c.phase, CdbDownloadPhase.complete);
    expect(c.bytesDone, fileBytes, reason: 'the discarded prefix is uncounted');
    expect(c.filesDone, 1);
    c.dispose();
  });

  test('a transient server error on resume keeps the partial file', () async {
    // Hugging Face answers 5xx now and then.  A partial multi-GB file must
    // survive that: retry the same range, do not throw the bytes away.
    await writePartial(mainPath, payload.sublist(0, 1500));
    mirror.failNextWith.add(HttpStatus.serviceUnavailable);

    final c = controller();
    await c.prepare(snapshot: single, parentDir: tmp.path);
    await c.start();

    expect(c.phase, CdbDownloadPhase.complete);
    expect(await local(mainPath).readAsBytes(), payload);
    expect(mirror.ranges, [
      'bytes=1500-',
      'bytes=1500-',
    ], reason: 'the second attempt should resume, not start over');
    c.dispose();
  });

  test('a server error on a fresh file is retried, not fatal', () async {
    mirror.failNextWith.add(HttpStatus.badGateway);

    final c = controller();
    await c.prepare(snapshot: single, parentDir: tmp.path);
    await c.start();

    expect(c.phase, CdbDownloadPhase.complete);
    expect(c.error, isNull);
    expect(mirror.ranges, [null, null]);
    expect(await local(mainPath).readAsBytes(), payload);
    c.dispose();
  });

  test('pausing mid-file keeps the bytes and resumes from them', () async {
    mirror
      ..chunkBytes = 256
      ..chunkDelay = const Duration(milliseconds: 40);

    final c = controller();
    await c.prepare(snapshot: single, parentDir: tmp.path);
    final run = c.start();
    await waitUntil(() => c.bytesDone >= 512);
    await c.pause();
    await run;

    expect(c.phase, CdbDownloadPhase.paused);
    expect(c.isRunning, isFalse);
    expect(c.canResume, isTrue);
    expect(c.filesDone, 0);
    final kept = await local(mainPath).length();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(fileBytes));
    expect(c.bytesDone, kept, reason: 'progress matches what hit the disk');
    expect(c.activeFiles, isEmpty);

    mirror.chunkBytes = null;
    await c.start();

    expect(c.phase, CdbDownloadPhase.complete);
    expect(mirror.ranges.length, 2);
    expect(mirror.ranges.last, 'bytes=$kept-');
    expect(await local(mainPath).readAsBytes(), payload);
    expect(c.bytesDone, fileBytes);
    expect(c.filesDone, 1);
    c.dispose();
  });

  test('deletion drains transfer and rejects another preparation', () async {
    mirror
      ..chunkBytes = 256
      ..chunkDelay = const Duration(milliseconds: 40);
    final c = controller();
    await c.prepare(snapshot: single, parentDir: tmp.path);
    final run = c.start();
    await waitUntil(() => c.bytesDone >= 512);

    final deletion = c.deleteFiles();
    await expectLater(
      c.prepare(snapshot: single, parentDir: tmp.path),
      throwsStateError,
    );
    await deletion;
    await run;

    expect(await local(mainPath).exists(), isFalse);
    expect(c.snapshot, isNull);
    expect(c.phase, CdbDownloadPhase.idle);
    expect(settings.committed.enableCdbDirect, isFalse);
    expect(settingsStorage.writes, isEmpty);
    await c.close();
    c.dispose();
  });

  test('close drains active transfer without activating settings', () async {
    mirror
      ..chunkBytes = 256
      ..chunkDelay = const Duration(milliseconds: 40);
    final c = controller();
    await c.prepare(snapshot: single, parentDir: tmp.path);
    final run = c.start();
    await waitUntil(() => c.bytesDone >= 512);

    final closing = c.close();
    expect(identical(closing, c.close()), isTrue);
    c.dispose();
    await closing;
    await run;

    final kept = await local(mainPath).length();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(fileBytes));
    expect(settingsStorage.writes, isEmpty);
    await expectLater(
      c.prepare(snapshot: single, parentDir: tmp.path),
      throwsStateError,
    );
  });

  test(
    'completed artifact stays busy until admitted activation settles',
    () async {
      final c = controller();
      await c.prepare(snapshot: single, parentDir: tmp.path);
      final activation = Completer<void>();
      settingsStorage.writeGate = activation.future;
      final run = c.start();
      expect(c.isRunning, isTrue, reason: 'admitted before first await');
      await waitUntil(() => settingsStorage.writes.isNotEmpty);
      expect(c.phase, CdbDownloadPhase.complete);
      expect(c.isRunning, isTrue);

      final closing = c.close();
      expect(c.isRunning, isTrue, reason: 'close drains the admitted save');
      activation.complete();
      await closing;
      await run;
      expect(c.isRunning, isFalse);
      expect(settings.committed.enableCdbDirect, isTrue);
      c.dispose();
    },
  );

  test('several files share the workers and every one lands intact', () async {
    const paths = [
      '$id/data/000001.sst',
      '$id/data/000002.sst',
      '$id/data/000003.sst',
      '$id/data/CURRENT',
    ];
    final sizes = [fileBytes, 3000, 5000, 16];
    final contents = {
      for (var i = 0; i < paths.length; i++) paths[i]: bytesFor(i, sizes[i]),
    };
    mirror.payloads
      ..clear()
      ..addAll(contents);
    final snapshot = CdbSnapshot(
      id: id,
      files: [
        for (var i = 0; i < paths.length; i++)
          CdbSnapshotFile(path: paths[i], bytes: sizes[i]),
      ],
    );
    // One finished, one half done, two absent.
    await writePartial(paths[0], contents[paths[0]]!);
    await writePartial(paths[1], contents[paths[1]]!.sublist(0, 1000));

    final c = controller(concurrency: 2);
    await c.prepare(snapshot: snapshot, parentDir: tmp.path);
    expect(c.filesDone, 1);
    expect(c.bytesDone, fileBytes + 1000);

    await c.start();

    expect(c.phase, CdbDownloadPhase.complete);
    expect(c.filesDone, paths.length);
    expect(c.bytesDone, c.bytesTotal);
    for (final path in paths) {
      expect(await local(path).readAsBytes(), contents[path], reason: path);
    }
    expect(mirror.ranges, hasLength(3), reason: 'the finished file is skipped');
    expect(mirror.ranges, contains('bytes=1000-'));
    expect(await c.check(), isEmpty);
    c.dispose();
  });

  test('check() flags a missing file and parks a completed download', () async {
    final c = controller();
    await c.prepare(snapshot: single, parentDir: tmp.path);
    await c.start();
    expect(c.phase, CdbDownloadPhase.complete);

    await local(mainPath).delete();
    final problems = await c.check();

    expect(problems.single.isMissing, isTrue);
    expect(problems.single.actualBytes, -1);
    expect(c.phase, CdbDownloadPhase.paused, reason: 'no longer complete');
    expect(c.bytesDone, 0);
    expect(c.filesDone, 0);
    c.dispose();
  });

  test('loadSaved re-attaches to a parked download without fetching', () async {
    SharedPreferences.setMockInitialValues({
      'eval.cdb_download.parent_dir': tmp.path,
      'eval.cdb_download.snapshot_id': id,
    });
    await writePartial(mainPath, payload.sublist(0, 700));
    final catalog = CdbSnapshotCatalog(
      client: MockClient((request) async {
        expect(request.url.path, contains('/tree/main/$id/data'));
        return http.Response(
          jsonEncode([
            {'type': 'file', 'path': mainPath, 'size': fileBytes},
          ]),
          200,
        );
      }),
    );

    final c = CdbSnapshotDownloadController(
      settings: settings,
      catalog: catalog,
      concurrency: 1,
      urlBuilder: mirror.urlFor,
    );
    await c.loadSaved();

    expect(c.snapshot?.id, id);
    expect(c.parentDir, tmp.path);
    expect(c.phase, CdbDownloadPhase.paused);
    expect(c.bytesDone, 700);
    expect(c.bytesTotal, fileBytes);
    expect(c.canResume, isTrue);
    expect(mirror.ranges, isEmpty, reason: 'loading must never transfer');
    expect(c.dataDirectory, p.join(tmp.path, id, 'data'));
    c.dispose();
  });

  test(
    'forget drains a pending restore without reattaching its snapshot',
    () async {
      SharedPreferences.setMockInitialValues({
        'eval.cdb_download.parent_dir': tmp.path,
        'eval.cdb_download.snapshot_id': id,
      });
      await writePartial(mainPath, payload.sublist(0, 700));
      final requested = Completer<void>();
      final response = Completer<http.Response>();
      final c = CdbSnapshotDownloadController(
        settings: settings,
        catalog: CdbSnapshotCatalog(
          client: MockClient((_) {
            requested.complete();
            return response.future;
          }),
        ),
        urlBuilder: mirror.urlFor,
      );
      final restoring = c.loadSaved();
      await requested.future;
      final forgetting = c.forget();
      response.complete(
        http.Response(
          jsonEncode([
            {'type': 'file', 'path': mainPath, 'size': fileBytes},
          ]),
          200,
        ),
      );
      await restoring;
      await forgetting;
      expect(c.snapshot, isNull);
      expect(c.parentDir, isNull);
      expect(c.phase, CdbDownloadPhase.idle);
      expect(settingsStorage.writes, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'eval.cdb_download.snapshot_id',
        ),
        isNull,
      );
      await c.close();
      c.dispose();
    },
  );

  test('loadSaved ignores a saved download whose folder is gone', () async {
    SharedPreferences.setMockInitialValues({
      'eval.cdb_download.parent_dir': p.join(tmp.path, 'missing'),
      'eval.cdb_download.snapshot_id': id,
    });
    final c = CdbSnapshotDownloadController(
      settings: settings,
      catalog: CdbSnapshotCatalog(
        client: MockClient((_) async => fail('must not consult the mirror')),
      ),
      urlBuilder: mirror.urlFor,
    );
    await c.loadSaved();
    expect(c.phase, CdbDownloadPhase.idle);
    expect(c.snapshot, isNull);
    c.dispose();
  });
}
