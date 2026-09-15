import 'dart:io';

import 'package:chess_auto_prep/services/storage/pgn_game_count_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _game = '[Event "x"]\n\n1. e4 e5 *\n';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('game_count_cache');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File write(String name, int games) =>
      File(p.join(tempDir.path, name))..writeAsStringSync(_game * games);

  test('counts games and serves an unchanged file from the cache', () async {
    var reads = 0;
    final cache = PgnGameCountCache(
      readFile: (file) async {
        reads++;
        return file.readAsString();
      },
    );
    final file = write('a.pgn', 3);
    final stat = await file.stat();

    expect(await cache.countFor(file, stat), 3);
    expect(await cache.countFor(file, stat), 3);
    expect(reads, 1, reason: 'same stat, no second read');
  });

  test('a changed size or mtime forces a recount', () async {
    final cache = PgnGameCountCache();
    final file = write('a.pgn', 2);
    expect(await cache.countFor(file, await file.stat()), 2);

    file.writeAsStringSync(_game * 5);
    expect(await cache.countFor(file, await file.stat()), 5);
  });

  test('a large file is counted the same way off the isolate', () async {
    final cache = PgnGameCountCache(isolateThresholdBytes: 10);
    final file = write('big.pgn', 4);
    expect(await cache.countFor(file, await file.stat()), 4);
  });

  test('a vanished file fails that count and not the next', () async {
    final cache = PgnGameCountCache();
    final gone = write('gone.pgn', 1);
    final stat = await gone.stat();
    gone.deleteSync();
    final kept = write('kept.pgn', 2);

    final failed = cache.countFor(gone, stat);
    final ok = cache.countFor(kept, await kept.stat());
    await expectLater(failed, throwsA(isA<FileSystemException>()));
    expect(await ok, 2);
  });

  test('reads are serialised, not run at once', () async {
    var inFlight = 0;
    var peak = 0;
    final cache = PgnGameCountCache(
      readFile: (file) async {
        inFlight++;
        peak = peak > inFlight ? peak : inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return file.readAsString();
      },
    );
    final files = [for (var i = 0; i < 4; i++) write('$i.pgn', i + 1)];
    final counts = await Future.wait([
      for (final file in files)
        file.stat().then((s) => cache.countFor(file, s)),
    ]);
    expect(counts, [1, 2, 3, 4]);
    expect(peak, 1);
  });
}
