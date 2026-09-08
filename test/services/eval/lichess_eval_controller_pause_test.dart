import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:chess_auto_prep/services/eval/lichess_eval_controller.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_source.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_store.dart';
import 'package:chess_auto_prep/services/master_games/position_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A zstd frame of raw blocks, so the archive can be far larger than the
/// 128 KB one raw block holds.  Same layout as `raw_zstd_frame.dart`, with
/// the content spread over as many blocks as it needs.
Uint8List rawZstdFrameOf(List<int> content) {
  const blockBytes = 100 * 1024;
  final out = BytesBuilder()
    ..add([0x28, 0xB5, 0x2F, 0xFD, 0xA0])
    ..add(
      (ByteData(
        4,
      )..setUint32(0, content.length, Endian.little)).buffer.asUint8List(),
    );
  var at = 0;
  do {
    final end = min(at + blockBytes, content.length);
    final last = end == content.length ? 1 : 0;
    final header = ((end - at) << 3) | last;
    out
      ..add([header & 0xff, (header >> 8) & 0xff, (header >> 16) & 0xff])
      ..add(content.sublist(at, end));
    at = end;
  } while (at < content.length);
  return out.takeBytes();
}

String evalLine(String fen, int cp, int depth) =>
    '{"fen":"$fen","evals":[{"pvs":[{"cp":$cp,"line":"a1a2 h8h7"}],'
    '"knodes":1,"depth":$depth}]}';

/// Serves the archive with byte-range support, and can misbehave on demand.
class _FakeLichess {
  _FakeLichess(this.payload);

  final Uint8List payload;
  late final HttpServer _server;
  final List<String?> ranges = [];

  bool ignoreRanges = false;
  final List<int> failNextWith = [];
  int? chunkBytes;

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
      var start = 0;
      if (range != null && !ignoreRanges) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        response.statusCode = HttpStatus.partialContent;
      }
      final body = payload.sublist(start);
      final size = chunkBytes;
      if (size == null) {
        response.add(body);
      } else {
        for (var at = 0; at < body.length; at += size) {
          response.add(body.sublist(at, min(at + size, body.length)));
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
      await response.close();
    });
  }

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/eval.zst');

  Future<void> stop() => _server.close(force: true);
}

void main() {
  // The test binding otherwise answers every socket with an empty 400.
  setUpAll(() => HttpOverrides.global = null);

  // Enough lines that the import isolate is genuinely mid-scan when a cancel
  // reaches it, and enough bytes to pause a trickled download part-way.
  const positions = 12000;
  final fens = [
    for (var i = 0; i < positions; i++)
      '8/8/8/8/${i ~/ 64}p${i % 64 ~/ 8}/8/${i % 8}p/K6k w - -',
  ];

  late Directory tmp;
  late _FakeLichess server;
  late Uint8List archive;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('lichess_ctrl_pause');
    final jsonl = [
      for (var i = 0; i < positions; i++) evalLine(fens[i], i - 6000, 30),
    ].join('\n');
    archive = rawZstdFrameOf('$jsonl\n'.codeUnits);
    server = _FakeLichess(archive);
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  LichessEvalController controller() => LichessEvalController(
    source: LichessEvalSource(
      client: MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response(
            '',
            200,
            headers: {
              'content-length': '${archive.length}',
              'last-modified': 'Sun, 02 Aug 2026 21:49:50 GMT',
            },
          );
        }
        return http.Response(
          '<section id="evals"><strong>$positions</strong> chess positions '
          'evaluated with Stockfish. This file was last updated on '
          '2026-08-02.</section>',
          200,
        );
      }),
    ),
    urlBuilder: () => server.url,
  );

  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> expectCompleteStore(LichessEvalController c) async {
    expect(c.phase, LichessEvalPhase.complete);
    expect(c.isReady, isTrue);
    expect(c.storedPositions, positions);
    final store = (await LichessEvalStore.open(c.storeDirectory!))!;
    expect(store.records, positions);
    for (final i in [0, 1, 4095, 4096, 11999]) {
      final hit = await store.lookup(positionKey(fens[i]));
      expect(hit, isNotNull, reason: fens[i]);
      expect(hit!.cp, i - 6000);
    }
    await store.close();
  }

  test('pausing during the import parks it; the next start finishes', () async {
    final c = controller();
    final info = await c.refreshSource();
    await c.prepare(info: info, parentDir: tmp.path);

    final run = c.start();
    await waitUntil(() => c.phase == LichessEvalPhase.importing);
    await c.pause();
    await run;

    // A cancelled import is a pause, not a failure: the isolate exits on
    // purpose, without a `done` report, and that must not read as a crash.
    expect(c.error, isNull);
    expect(c.phase, LichessEvalPhase.paused);
    expect(c.isBusy, isFalse);
    expect(c.isReady, isFalse);
    final manifest = await readManifest(c.storePaths!);
    expect(manifest?.complete, isNot(isTrue));

    await c.start();

    expect(server.ranges, [null], reason: 'the finished archive is reused');
    await expectCompleteStore(c);
    c.dispose();
  });

  test('a mirror that ignores the range restarts the archive', () async {
    final c = controller();
    final info = await c.refreshSource();
    await c.prepare(info: info, parentDir: tmp.path);
    final partial = File(c.archivePath!);
    await partial.writeAsBytes(archive.sublist(0, 4000));
    server.ignoreRanges = true;

    await c.start();

    expect(server.ranges, ['bytes=4000-']);
    expect(await partial.length(), archive.length);
    expect(await partial.readAsBytes(), archive, reason: 'no spliced prefix');
    expect(c.archiveBytesDone, archive.length);
    await expectCompleteStore(c);
    c.dispose();
  });

  test('a server error fails the download and a later start resumes', () async {
    final c = controller();
    final info = await c.refreshSource();
    await c.prepare(info: info, parentDir: tmp.path);
    await File(c.archivePath!).writeAsBytes(archive.sublist(0, 4000));
    server.failNextWith.add(HttpStatus.serviceUnavailable);

    await c.start();

    expect(c.phase, LichessEvalPhase.failed);
    expect(c.error, contains('503'));
    expect(c.isBusy, isFalse);
    expect(await File(c.archivePath!).length(), 4000, reason: 'kept');

    await c.start();

    expect(c.error, isNull);
    expect(server.ranges, ['bytes=4000-', 'bytes=4000-']);
    await expectCompleteStore(c);
    c.dispose();
  });

  test('pausing during the download keeps what was fetched', () async {
    server.chunkBytes = 64 * 1024;
    final c = controller();
    final info = await c.refreshSource();
    await c.prepare(info: info, parentDir: tmp.path);

    final run = c.start();
    await waitUntil(() => c.archiveBytesDone >= 64 * 1024);
    await c.pause();
    await run;

    expect(c.phase, LichessEvalPhase.paused);
    expect(c.error, isNull);
    final kept = await File(c.archivePath!).length();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(archive.length));
    expect(c.archiveBytesDone, kept);
    expect(c.eta, isNull, reason: 'no rate while parked');

    server.chunkBytes = null;
    await c.start();

    expect(server.ranges.length, 2);
    expect(server.ranges.last, 'bytes=$kept-');
    expect(await File(c.archivePath!).readAsBytes(), archive);
    await expectCompleteStore(c);
    c.dispose();
  });
}
