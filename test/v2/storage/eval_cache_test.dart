import 'dart:io';

import 'package:chess_auto_prep/v2/storage/eval_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  const fen4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';

  test('a verdict is kept and read back at any depth up to its own', () {
    final cache = EvalCache.inMemory();
    addTearDown(cache.close);
    expect(cache.read(fen4, minDepth: 1), isNull);
    cache.write(fen4, cpWhite: 35, depth: 14);
    expect(cache.read(fen4, minDepth: 14), 35);
    expect(cache.read(fen4, minDepth: 10), 35);
    expect(cache.read(fen4, minDepth: 20), isNull, reason: 'not that deep');
  });

  test('the deeper verdict wins whichever order they arrive in', () {
    final cache = EvalCache.inMemory();
    addTearDown(cache.close);
    cache.write(fen4, cpWhite: 35, depth: 14);
    cache.write(fen4, cpWhite: 10, depth: 8);
    expect(cache.read(fen4, minDepth: 8), 35);
    cache.write(fen4, cpWhite: 50, depth: 20);
    expect(cache.read(fen4, minDepth: 8), 50);
  });

  test('on disk it is the old app\'s file: its tables and its version', () {
    final dir = Directory.systemTemp.createTempSync('eval_cache');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = EvalCache.open(dir);
    expect(cache.available, isTrue);
    cache.write(fen4, cpWhite: 35, depth: 14);
    cache.close();
    final db = sqlite3.open(p.join(dir.path, 'eval_cache.db'));
    addTearDown(db.dispose);
    expect(db.select('PRAGMA user_version').first.columnAt(0), 4);
    final tables = db
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row.columnAt(0))
        .toSet();
    expect(tables, containsAll(['evals', 'maia_cache']));
    final row = db.select('SELECT eval_cp_white, depth FROM evals').single;
    expect(row.columnAt(0), 35);
    expect(row.columnAt(1), 14);
  });

  test('a file that will not open leaves a cache that answers nothing', () {
    final dir = Directory.systemTemp.createTempSync('eval_cache');
    addTearDown(() => dir.deleteSync(recursive: true));
    // A folder where the file should be.
    Directory(p.join(dir.path, 'eval_cache.db')).createSync();
    final cache = EvalCache.open(dir);
    addTearDown(cache.close);
    expect(cache.available, isFalse);
    cache.write(fen4, cpWhite: 35, depth: 14);
    expect(cache.read(fen4, minDepth: 1), isNull);
  });
}
