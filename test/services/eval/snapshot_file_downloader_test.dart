import 'dart:io';

import 'package:chess_auto_prep/services/eval/cdb_snapshot_catalog.dart';
import 'package:chess_auto_prep/services/eval/snapshot_file_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Serves one payload, honouring byte ranges unless told not to.
class _Mirror {
  _Mirror(this.payload);

  final List<int> payload;
  late final HttpServer _server;
  final List<String?> ranges = [];
  bool ignoreRanges = false;
  final List<int> failNextWith = [];

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      final response = request.response;
      if (failNextWith.isNotEmpty) {
        response.statusCode = failNextWith.removeAt(0);
        await response.close();
        return;
      }
      var start = 0;
      if (range != null && !ignoreRanges) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        response.statusCode = HttpStatus.partialContent;
      }
      response.add(payload.sublist(start));
      await response.close();
    });
  }

  Uri urlFor(String repoPath) =>
      Uri.parse('http://127.0.0.1:${_server.port}/$repoPath');

  Future<void> stop() => _server.close(force: true);
}

void main() {
  setUpAll(() => HttpOverrides.global = null);

  const repoPath = 'chess-20260702/data/000001.sst';
  final payload = List<int>.generate(3000, (i) => (i * 7) & 0xff);
  final file = CdbSnapshotFile(path: repoPath, bytes: payload.length);

  late Directory tmp;
  late _Mirror mirror;
  late HttpClient http;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('snapshot_file');
    mirror = _Mirror(payload);
    await mirror.start();
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await mirror.stop();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  SnapshotFileDownloader downloader({int maxAttempts = 1}) =>
      SnapshotFileDownloader(
        http: http,
        urlFor: mirror.urlFor,
        openSink: (target, {required append}) =>
            target.openWrite(mode: append ? FileMode.append : FileMode.write),
        maxAttempts: maxAttempts,
      );

  File local() => File(p.join(tmp.path, repoPath));

  test('a fresh file is fetched whole and every byte is reported', () async {
    var reported = 0;
    final outcome = await downloader().fetch(
      file,
      tmp.path,
      shouldStop: () => false,
      onBytes: (delta) => reported += delta,
    );
    expect(outcome, SnapshotFileOutcome.complete);
    expect(await local().readAsBytes(), payload);
    expect(reported, payload.length);
    expect(mirror.ranges, [null]);
  });

  test('a partial file resumes from its length', () async {
    await local().create(recursive: true);
    await local().writeAsBytes(payload.sublist(0, 1000));

    var reported = 0;
    final outcome = await downloader().fetch(
      file,
      tmp.path,
      shouldStop: () => false,
      onBytes: (delta) => reported += delta,
    );
    expect(outcome, SnapshotFileOutcome.complete);
    expect(mirror.ranges, ['bytes=1000-']);
    expect(await local().readAsBytes(), payload);
    expect(reported, 2000, reason: 'only the missing tail is transferred');
  });

  test('a complete file is left alone without a request', () async {
    await local().create(recursive: true);
    await local().writeAsBytes(payload);
    final outcome = await downloader().fetch(
      file,
      tmp.path,
      shouldStop: () => false,
      onBytes: (_) => fail('nothing should be transferred'),
    );
    expect(outcome, SnapshotFileOutcome.complete);
    expect(mirror.ranges, isEmpty);
  });

  test('an ignored range discards the partial file and retries', () async {
    await local().create(recursive: true);
    await local().writeAsBytes(payload.sublist(0, 1000));
    mirror.ignoreRanges = true;

    var reported = 0;
    final outcome = await downloader(maxAttempts: 2).fetch(
      file,
      tmp.path,
      shouldStop: () => false,
      onBytes: (delta) => reported += delta,
    );
    expect(outcome, SnapshotFileOutcome.complete);
    expect(await local().readAsBytes(), payload);
    // -1000 for the discarded head, then the whole file again.
    expect(reported, payload.length - 1000);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a stop request before the first attempt transfers nothing', () async {
    final outcome = await downloader().fetch(
      file,
      tmp.path,
      shouldStop: () => true,
      onBytes: (_) => fail('stopped before any bytes'),
    );
    expect(outcome, SnapshotFileOutcome.stopped);
    expect(mirror.ranges, isEmpty);
  });

  test('a server error gives up after the last attempt', () async {
    mirror.failNextWith.addAll([500, 500]);
    await expectLater(
      downloader(
        maxAttempts: 2,
      ).fetch(file, tmp.path, shouldStop: () => false, onBytes: (_) {}),
      throwsA(isA<HttpException>()),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}
