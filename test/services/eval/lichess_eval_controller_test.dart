import 'dart:io';
import 'dart:typed_data';

import 'package:chess_auto_prep/models/eval_database_settings.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_controller.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_source.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_store.dart';
import 'package:chess_auto_prep/services/master_games/position_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'raw_zstd_frame.dart';

String evalLine(String fen, int cp, int depth, String move) =>
    '{"fen":"$fen","evals":[{"pvs":[{"cp":$cp,"line":"$move d7d5"}],'
    '"knodes":1,"depth":$depth}]}';

/// Serves the archive, honouring byte ranges so resume can be observed.
class _FakeLichess {
  _FakeLichess(this.payload);

  final Uint8List payload;
  late final HttpServer _server;
  final List<String?> ranges = [];

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      var start = 0;
      if (range != null) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        request.response.statusCode = HttpStatus.partialContent;
      }
      request.response.add(payload.sublist(start));
      await request.response.close();
    });
  }

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/eval.zst');

  Future<void> stop() => _server.close(force: true);
}

void main() {
  // The test binding otherwise answers every socket with an empty 400.
  setUpAll(() => HttpOverrides.global = null);

  late Directory tmp;
  late _FakeLichess server;
  late Uint8List archive;

  const fens = [
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -',
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -',
    '8/8/8/8/8/8/8/K6k w - -',
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('lichess_ctrl');
    final jsonl = [
      for (var i = 0; i < fens.length; i++)
        evalLine(fens[i], 20 + i, 30 + i, 'e2e4'),
    ].join('\n');
    archive = rawZstdFrame('$jsonl\n'.codeUnits);
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
          '<section id="evals"><strong>3</strong> chess positions '
          'evaluated with Stockfish. This file was last updated on '
          '2026-08-02.</section>',
          200,
        );
      }),
    ),
    urlBuilder: () => server.url,
    spawnIsolate: false,
  );

  test('downloads, imports and turns itself on', () async {
    final c = controller();
    final info = await c.refreshSource();
    expect(info.bytes, archive.length);
    expect(info.positions, 3);

    await c.prepare(info: info, parentDir: tmp.path);
    await c.start();

    expect(c.phase, LichessEvalPhase.complete);
    expect(c.storedPositions, 3);
    expect(server.ranges, [null]);

    // The store the eval chain will read is really there and answers.
    final store = (await LichessEvalStore.open(c.storeDirectory!))!;
    final hit = (await store.lookup(positionKey(fens.first)))!;
    expect(hit.cp, 20);
    expect(hit.move, 'e2e4');
    await store.close();

    // And the setting now points at it, switched on.
    expect(EvalDatabaseSettings.instance.lichessEvalsPath, c.storeDirectory);
    expect(EvalDatabaseSettings.instance.enableLichessEvals, isTrue);
    c.dispose();
  });

  test('a half-finished download resumes rather than restarting', () async {
    final c = controller();
    final info = await c.refreshSource();
    await c.prepare(info: info, parentDir: tmp.path);

    // Leave the first few bytes on disk, as an interrupted transfer would.
    final partial = File(c.archivePath!);
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(archive.sublist(0, 6));

    await c.refreshStoreState();
    expect(c.phase, LichessEvalPhase.paused);

    await c.start();

    expect(server.ranges, ['bytes=6-']);
    expect(c.phase, LichessEvalPhase.complete);
    expect(c.storedPositions, 3);
    c.dispose();
  });

  test('a longer stale file is refetched from the start', () async {
    final c = controller();
    final info = await c.refreshSource();
    await c.prepare(info: info, parentDir: tmp.path);

    final stale = File(c.archivePath!);
    await stale.parent.create(recursive: true);
    await stale.writeAsBytes([...archive, 9, 9, 9, 9]);

    await c.start();

    expect(server.ranges, [null]);
    expect(c.phase, LichessEvalPhase.complete);
    c.dispose();
  });

  test('the archive can be deleted without losing the store', () async {
    final c = controller();
    final info = await c.refreshSource();
    await c.prepare(info: info, parentDir: tmp.path);
    await c.start();

    expect(await File(c.archivePath!).exists(), isTrue);
    await c.deleteArchive();

    expect(await File(c.archivePath!).exists(), isFalse);
    expect(c.isReady, isTrue);
    expect(await LichessEvalStore.open(c.storeDirectory!), isNotNull);
    c.dispose();
  });

  test('deleting everything clears the folder and the setting', () async {
    final c = controller();
    final info = await c.refreshSource();
    await c.prepare(info: info, parentDir: tmp.path);
    await c.start();
    final directory = c.storeDirectory!;

    await c.deleteEverything();

    expect(await Directory(directory).exists(), isFalse);
    expect(c.phase, LichessEvalPhase.idle);
    expect(c.isReady, isFalse);
    expect(EvalDatabaseSettings.instance.enableLichessEvals, isFalse);
    expect(EvalDatabaseSettings.instance.lichessEvalsPath, '');
    c.dispose();
  });

  test('the quoted cost is the peak, not the download size', () async {
    final c = controller();
    const info = LichessEvalSourceInfo(
      bytes: 21681515630,
      lastModified: null,
      positions: 394669566,
      updatedOn: null,
    );
    // Download plus store plus headroom — about 28 GB, which is what the
    // drive has to have free, unlike the 21.7 GB the download page states.
    expect(c.peakBytesFor(info), greaterThan(27000000000));
    expect(c.peakBytesFor(info), lessThan(30000000000));
    expect(c.restingBytesFor(info), lessThan(6000000000));
    c.dispose();
  });
}
