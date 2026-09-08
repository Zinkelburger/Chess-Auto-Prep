import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:chess_auto_prep/services/eval/lichess_eval_import.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_store.dart';
import 'package:chess_auto_prep/services/master_games/position_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String line(
  String fen, {
  required int cp,
  int depth = 30,
  String move = 'a1a2',
}) =>
    '{"fen":"$fen","evals":[{"pvs":[{"cp":$cp,"line":"$move h8h7"}],'
    '"knodes":10,"depth":$depth}]}';

/// Distinct legal-looking FENs; [count] can exceed one index block.
List<String> fens(int count) => [
  for (var i = 0; i < count; i++) '8/8/8/8/8/8/${i ~/ 8}p${i % 8}/K6k w - -',
];

/// [bytes] cut into pieces of [size], the last one shorter.
List<List<int>> chunked(List<int> bytes, int size) => [
  for (var at = 0; at < bytes.length; at += size)
    bytes.sublist(at, at + size > bytes.length ? bytes.length : at + size),
];

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lichess_import_resume');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Runs the importer over [chunks] into [into], returning every progress
  /// report.  [control] lets a caller cancel; [onProgress] sees each report.
  Future<List<LichessImportProgress>> import(
    Stream<List<int>> Function(LichessImportControl control) chunks, {
    Directory? into,
    LichessImportControl? control,
    int checkpointEvery = 1000000,
    String? sourceLastModified,
    void Function(LichessImportProgress)? onProgress,
  }) async {
    final receive = ReceivePort();
    final progress = <LichessImportProgress>[];
    final ctl = control ?? LichessImportControl();
    final collecting = receive.listen((message) {
      if (message is LichessImportProgress) {
        progress.add(message);
        onProgress?.call(message);
      }
    });
    await importLichessEvals(
      LichessImportRequest(
        archivePath: 'ignored.zst',
        storeDirectory: (into ?? tmp).path,
        sendPort: receive.sendPort,
        sourceLastModified: sourceLastModified,
        checkpointEvery: checkpointEvery,
      ),
      ctl,
      openStream: (_) => chunks(ctl),
    );
    // Reports are delivered asynchronously; let the queue drain.
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await collecting.cancel();
    receive.close();
    return progress;
  }

  Future<void> expectStoreHolds(
    Directory dir,
    List<String> positions,
    int Function(int index) cpOf,
  ) async {
    final store = await LichessEvalStore.open(dir.path);
    expect(store, isNotNull, reason: 'the build must be complete');
    expect(store!.records, positions.length);
    for (var i = 0; i < positions.length; i++) {
      final hit = await store.lookup(positionKey(positions[i]));
      expect(hit, isNotNull, reason: positions[i]);
      expect(hit!.cp, cpOf(i), reason: positions[i]);
    }
    await store.close();
  }

  test('chunk boundaries anywhere in a line change nothing', () async {
    final positions = fens(30);
    final jsonl = [
      for (var i = 0; i < positions.length; i++) line(positions[i], cp: i),
    ].join('\n');
    // No trailing newline: the last line must still be read.
    final bytes = jsonl.codeUnits;

    for (final size in [1, 7, 100, bytes.length]) {
      final dir = await Directory(p.join(tmp.path, 'by$size')).create();
      await import((_) => Stream.fromIterable(chunked(bytes, size)), into: dir);
      await expectStoreHolds(dir, positions, (i) => i);
    }
  });

  test(
    'rows spilled after the last checkpoint are dropped on resume',
    () async {
      final positions = fens(400);
      final chunks = [
        for (var i = 0; i < positions.length; i++)
          '${line(positions[i], cp: i)}\n'.codeUnits,
      ];

      // The flag goes up after chunk 151 is handed over and is seen once
      // line 152 has been parsed, so the manifest checkpoints at 152 — past
      // the regular checkpoint boundary at 100.
      Stream<List<int>> cancelling(LichessImportControl control) async* {
        for (var i = 0; i < chunks.length; i++) {
          yield chunks[i];
          if (i == 150) control.cancelled = true;
        }
      }

      final reports = await import(cancelling, checkpointEvery: 100);
      expect(reports.last.phase, LichessImportPhase.scanning);
      expect(reports.last.linesRead, 152);
      final paths = LichessEvalStorePaths(tmp.path);
      final manifest = (await readManifest(paths))!;
      expect(manifest.complete, isFalse);
      expect(manifest.linesRead, 152);
      expect(manifest.records, 152);

      // A crash after the checkpoint leaves bucket bytes the manifest does not
      // know about.  Fake that with a junk record on every bucket file; the
      // resumed writer must truncate them away, not sort them into the store.
      final buckets = Directory(paths.bucketDirectory);
      var junked = 0;
      await for (final entity in buckets.list()) {
        if (entity is! File || p.basename(entity.path) == 'lengths.bin') {
          continue;
        }
        await entity.writeAsBytes(
          Uint8List.fromList(List<int>.filled(kRecordBytes, 0xEE)),
          mode: FileMode.append,
        );
        junked++;
      }
      expect(junked, kBucketCount);

      final resumed = await import(
        (_) => Stream.fromIterable(chunks),
        checkpointEvery: 100,
      );
      expect(resumed.last.phase, LichessImportPhase.done);
      expect(resumed.last.linesRead, positions.length);
      expect(resumed.last.rowsWritten, positions.length);
      await expectStoreHolds(tmp, positions, (i) => i);

      // The junk key (0xEEEE…) is not in the store.
      final store = (await LichessEvalStore.open(tmp.path))!;
      expect(await store.lookup(-0x1111111111111112), isNull);
      await store.close();
      expect(await buckets.exists(), isFalse, reason: 'scratch is cleaned up');
    },
  );

  test('a lost lengths file restarts the scan from the first line', () async {
    final positions = fens(120);
    final chunks = [
      for (var i = 0; i < positions.length; i++)
        '${line(positions[i], cp: i)}\n'.codeUnits,
    ];
    Stream<List<int>> cancelling(LichessImportControl control) async* {
      for (var i = 0; i < chunks.length; i++) {
        yield chunks[i];
        if (i == 60) control.cancelled = true;
      }
    }

    await import(cancelling, checkpointEvery: 50);
    final paths = LichessEvalStorePaths(tmp.path);
    expect((await readManifest(paths))!.linesRead, 62);
    await File(p.join(paths.bucketDirectory, 'lengths.bin')).delete();

    final reports = await import(
      (_) => Stream.fromIterable(chunks),
      checkpointEvery: 50,
    );

    expect(reports.last.phase, LichessImportPhase.done);
    // Without bucket lengths nothing can be trusted, so no line is skipped —
    // and the truncated buckets mean nothing is doubled either.
    expect(reports.last.linesRead, positions.length);
    await expectStoreHolds(tmp, positions, (i) => i);
  });

  test('a build cancelled while merging is finished by the next run', () async {
    final positions = fens(2500);
    final chunks = [
      for (var i = 0; i < positions.length; i++)
        '${line(positions[i], cp: i - 1250)}\n'.codeUnits,
    ];
    final control = LichessImportControl();
    var sawMerging = false;
    final first = await import(
      (_) => Stream.fromIterable(chunks),
      control: control,
      onProgress: (report) {
        if (report.phase == LichessImportPhase.merging) {
          sawMerging = true;
          control.cancelled = true;
        }
      },
    );
    expect(sawMerging, isTrue);
    expect(first.last.phase, LichessImportPhase.merging);
    expect(first.last.bucketsMerged, lessThan(kBucketCount));
    expect(await LichessEvalStore.open(tmp.path), isNull, reason: 'unfinished');
    final paths = LichessEvalStorePaths(tmp.path);
    expect(await Directory(paths.bucketDirectory).exists(), isTrue);

    final second = await import((_) => Stream.fromIterable(chunks));

    expect(second.last.phase, LichessImportPhase.done);
    expect(second.last.bucketsMerged, kBucketCount);
    await expectStoreHolds(tmp, positions, (i) => i - 1250);
  });

  test('progress counters never step backwards during a run', () async {
    final positions = fens(300);
    // Every position twice, so the scan writes more rows than survive.
    final chunks = [
      for (var i = 0; i < positions.length; i++)
        '${line(positions[i], cp: i, depth: 20)}\n'.codeUnits,
      for (var i = 0; i < positions.length; i++)
        '${line(positions[i], cp: i + 1000, depth: 40)}\n'.codeUnits,
    ];
    final reports = await import(
      (_) => Stream.fromIterable(chunks),
      checkpointEvery: 50,
    );

    var lines = -1;
    var merged = -1;
    var scanRows = 0;
    for (final r in reports) {
      expect(r.linesRead, greaterThanOrEqualTo(lines), reason: '${r.phase}');
      expect(r.bucketsMerged, greaterThanOrEqualTo(merged));
      lines = r.linesRead;
      merged = r.bucketsMerged;
      if (r.phase == LichessImportPhase.scanning) scanRows = r.rowsWritten;
    }
    final done = reports.last;
    expect(done.phase, LichessImportPhase.done);
    expect(done.linesRead, positions.length * 2);
    // `rowsWritten` counts raw rows while scanning and surviving records at
    // the end, so it is the one number that legitimately drops.
    expect(scanRows, positions.length * 2);
    expect(done.rowsWritten, positions.length);
    await expectStoreHolds(tmp, positions, (i) => i + 1000);
  });
}
