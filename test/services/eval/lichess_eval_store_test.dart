import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:chess_auto_prep/services/eval/lichess_eval_import.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_line.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_provider.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_store.dart';
import 'package:chess_auto_prep/services/master_games/position_key.dart';
import 'package:flutter_test/flutter_test.dart';

/// A JSONL line for [fen] with one eval.
String line(String fen, {int? cp, int? mate, int depth = 30, String? move}) {
  final score = mate != null ? '"mate":$mate' : '"cp":${cp ?? 0}';
  final pv = move == null ? '{$score}' : '{$score,"line":"$move d7d5"}';
  return '{"fen":"$fen","evals":[{"pvs":[$pv],"knodes":10,"depth":$depth}]}';
}

/// Enough distinct legal-looking FENs to push the store past one index block.
List<String> manyFens(int count) => [
  for (var i = 0; i < count; i++) '8/8/8/8/8/8/${i ~/ 8}p${i % 8}/K6k w - -',
];

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lichess_eval_store');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Runs the importer over [lines] with no compression in the way.
  Future<List<LichessImportProgress>> import(
    List<String> lines, {
    int checkpointEvery = 1000000,
    String? sourceLastModified,
    Directory? into,
  }) async {
    final receive = ReceivePort();
    final progress = <LichessImportProgress>[];
    final collecting = receive.listen((message) {
      if (message is LichessImportProgress) progress.add(message);
    });
    await importLichessEvals(
      LichessImportRequest(
        archivePath: 'ignored.zst',
        storeDirectory: (into ?? tmp).path,
        sendPort: receive.sendPort,
        sourceLastModified: sourceLastModified,
        checkpointEvery: checkpointEvery,
      ),
      LichessImportControl(),
      openStream: (_) =>
          Stream.fromIterable([for (final l in lines) '$l\n'.codeUnits]),
    );
    await collecting.cancel();
    receive.close();
    return progress;
  }

  test('imports, sorts and looks positions back up', () async {
    const whiteBetter =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';
    const blackMating = '8/8/8/8/2n5/k7/2p5/KB6 b - -';
    await import([
      line(whiteBetter, cp: 34, depth: 40, move: 'e7e5'),
      line(blackMating, mate: -3, depth: 44, move: 'c2c1q'),
      line('8/8/8/8/8/8/8/K6k w - -', cp: 0, depth: 12, move: 'a1a2'),
    ]);

    final store = (await LichessEvalStore.open(tmp.path))!;
    expect(store.records, 3);

    final hit = (await store.lookup(positionKey(whiteBetter)))!;
    expect(hit.cp, 34);
    expect(hit.mate, isNull);
    expect(hit.depth, 40);
    expect(hit.move, 'e7e5');

    final mate = (await store.lookup(positionKey(blackMating)))!;
    expect(mate.mate, -3);
    expect(mate.move, 'c2c1q');

    expect(await store.lookup(positionKey('8/8/8/8/8/8/8/K6q b - -')), isNull);
    await store.close();
  });

  test('records come out sorted, so every one is findable', () async {
    final fens = manyFens(3000);
    await import([
      for (var i = 0; i < fens.length; i++)
        line(fens[i], cp: i - 1500, depth: 20 + (i % 40)),
    ]);

    final store = (await LichessEvalStore.open(tmp.path))!;
    expect(store.records, fens.length);

    // Spot-check across the whole key space, including the block boundaries
    // the sparse index straddles.
    final rng = Random(11);
    for (var n = 0; n < 200; n++) {
      final i = rng.nextInt(fens.length);
      final hit = await store.lookup(positionKey(fens[i]));
      expect(hit, isNotNull, reason: fens[i]);
      expect(hit!.cp, i - 1500);
    }

    // And the file really is in ascending key order.
    final bytes = await File(
      LichessEvalStorePaths(tmp.path).dataFile,
    ).readAsBytes();
    var previous = 0;
    var first = true;
    for (
      var at = kHeaderBytes;
      at + kRecordBytes <= bytes.length;
      at += kRecordBytes
    ) {
      final key = decodeRecord(ByteData.sublistView(bytes), at).pos;
      if (!first) expect(compareKeys(previous, key) < 0, isTrue);
      previous = key;
      first = false;
    }
    await store.close();
  });

  test('a position listed twice keeps the deeper eval', () async {
    const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';
    await import([
      line(fen, cp: 10, depth: 20, move: 'e7e5'),
      line(fen, cp: 99, depth: 55, move: 'c7c5'),
      line(fen, cp: 40, depth: 33, move: 'g8f6'),
    ]);

    final store = (await LichessEvalStore.open(tmp.path))!;
    expect(store.records, 1);
    final hit = (await store.lookup(positionKey(fen)))!;
    expect(hit.depth, 55);
    expect(hit.cp, 99);
    expect(hit.move, 'c7c5');
    await store.close();
  });

  test('an interrupted scan resumes without losing or doubling rows', () async {
    final fens = manyFens(400);
    final lines = [
      for (var i = 0; i < fens.length; i++) line(fens[i], cp: i, depth: 30),
    ];

    // First pass: cancel after the first checkpoint.
    final receive = ReceivePort();
    final control = LichessImportControl();
    var seen = 0;
    final collecting = receive.listen((message) {
      if (message is LichessImportProgress) {
        seen++;
        control.cancelled = true;
      }
    });
    await importLichessEvals(
      LichessImportRequest(
        archivePath: 'ignored.zst',
        storeDirectory: tmp.path,
        sendPort: receive.sendPort,
        checkpointEvery: 100,
      ),
      control,
      openStream: (_) =>
          Stream.fromIterable([for (final l in lines) '$l\n'.codeUnits]),
    );
    await collecting.cancel();
    receive.close();
    expect(seen, greaterThan(0));
    expect(await LichessEvalStore.open(tmp.path), isNull, reason: 'unfinished');

    // Second pass over the same input finishes the job.
    await import(lines);

    final store = (await LichessEvalStore.open(tmp.path))!;
    expect(store.records, fens.length);
    for (var i = 0; i < fens.length; i += 37) {
      final hit = await store.lookup(positionKey(fens[i]));
      expect(hit, isNotNull, reason: fens[i]);
      expect(hit!.cp, i);
    }
    await store.close();
  });

  test('a newer publication discards a half-built store', () async {
    final fens = manyFens(50);
    final receive = ReceivePort();
    final control = LichessImportControl();
    final collecting = receive.listen((message) {
      if (message is LichessImportProgress) control.cancelled = true;
    });
    await importLichessEvals(
      LichessImportRequest(
        archivePath: 'ignored.zst',
        storeDirectory: tmp.path,
        sendPort: receive.sendPort,
        sourceLastModified: 'Sun, 02 Aug 2026 21:49:50 GMT',
        checkpointEvery: 10,
      ),
      control,
      openStream: (_) => Stream.fromIterable([
        for (final f in fens) '${line(f, cp: 1)}\n'.codeUnits,
      ]),
    );
    await collecting.cancel();
    receive.close();

    // The same positions republished, now with different scores.
    await import([
      for (final f in fens) line(f, cp: 7, depth: 44),
    ], sourceLastModified: 'Wed, 02 Sep 2026 10:00:00 GMT');

    final store = (await LichessEvalStore.open(tmp.path))!;
    expect(store.records, fens.length, reason: 'no leftovers from the old run');
    final hit = (await store.lookup(positionKey(fens.first)))!;
    expect(hit.cp, 7);
    await store.close();
  });

  test('the provider converts to the app\'s eval convention', () async {
    const blackToMove =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';
    const blackMating = '8/8/8/8/2n5/k7/2p5/KB6 b - -';
    await import([
      line(blackToMove, cp: 34, depth: 40, move: 'e7e5'),
      line(blackMating, mate: -3, depth: 44, move: 'c2c1q'),
    ]);

    final provider = LichessEvalProvider(directory: tmp.path);
    expect(await provider.init(), isTrue);

    // Stored White-relative +34 stays +34 white-normalized even though it is
    // Black to move — no flip, unlike the ChessDB tables.
    final hit = await provider.lookup(blackToMove, minDepth: 0);
    expect(hit.isHit, isTrue);
    expect(hit.hit!.cp, 34);
    expect(hit.hit!.bestMove, 'e7e5');

    // Black mates in 3 with Black to move: mate becomes +3 side-to-move
    // relative, and the packed cp is a large negative for White.
    final mate = await provider.lookup(blackMating, minDepth: 0);
    expect(mate.hit!.mate, 3);
    expect(mate.hit!.cp, lessThan(-9000));

    // Depth gating and misses are reported the way the chain expects.
    expect((await provider.lookup(blackToMove, minDepth: 60)).shallow, isTrue);
    final absent = await provider.lookup(
      '8/8/8/8/8/8/8/K6q b - -',
      minDepth: 0,
    );
    expect(absent.hardMiss, isTrue);

    await provider.close();
  });

  test('an unfinished or absent build opens as nothing', () async {
    expect(await LichessEvalStore.open(tmp.path), isNull);
    expect(await LichessEvalStore.open(''), isNull);
    final provider = LichessEvalProvider(directory: tmp.path);
    expect(await provider.init(), isFalse);
    expect(
      (await provider.lookup('8/8/8/8/8/8/8/K6k w - -', minDepth: 0)).isHit,
      isFalse,
    );
  });

  group('sortBucket', () {
    test('orders keys unsigned and drops shallower duplicates', () {
      final rows = [
        const LichessEvalRow(pos: 5, cp: 1, mate: null, depth: 10, move: 0),
        const LichessEvalRow(pos: -1, cp: 2, mate: null, depth: 10, move: 0),
        const LichessEvalRow(pos: 5, cp: 3, mate: null, depth: 40, move: 0),
        const LichessEvalRow(pos: 0, cp: 4, mate: null, depth: 10, move: 0),
      ];
      final raw = Uint8List(rows.length * kRecordBytes);
      final view = ByteData.sublistView(raw);
      for (var i = 0; i < rows.length; i++) {
        encodeRecord(view, i * kRecordBytes, rows[i]);
      }

      final sorted = sortBucket(raw);
      final out = ByteData.sublistView(sorted);
      final keys = [
        for (var i = 0; i * kRecordBytes < sorted.lengthInBytes; i++)
          decodeRecord(out, i * kRecordBytes),
      ];
      expect(keys.map((r) => r.pos), [0, 5, -1], reason: '-1 is the largest');
      expect(keys[1].depth, 40, reason: 'the deeper duplicate survives');
      expect(keys[1].cp, 3);
    });

    test('an empty bucket is empty', () {
      expect(sortBucket(Uint8List(0)), isEmpty);
    });
  });

  group('compareKeys', () {
    test('treats the sign bit as magnitude', () {
      expect(compareKeys(0, 1), lessThan(0));
      expect(compareKeys(-1, 0), greaterThan(0));
      expect(compareKeys(-2, -1), lessThan(0));
      expect(compareKeys(7, 7), 0);
    });

    test('bucketOf agrees with that ordering', () {
      expect(bucketOf(0), 0);
      expect(bucketOf(-1), 255);
      expect(bucketOf(1 << 56), 1);
    });
  });
}
