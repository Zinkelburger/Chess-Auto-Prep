import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'eval_test_helpers.dart';

/// The v2 → v3 migration drops and rebuilds both tables, so it is the one
/// piece of this cache that can lose a user's data outright.  These run it
/// against a real v2 database.
void main() {
  const v2Evals = '''
    CREATE TABLE evals(
      fen TEXT PRIMARY KEY,
      eval_cp_white INTEGER NOT NULL,
      depth INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''';
  const v2Maia = '''
    CREATE TABLE maia_cache(
      fen TEXT NOT NULL,
      elo INTEGER NOT NULL,
      policy_json TEXT NOT NULL,
      win_prob REAL NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (fen, elo)
    )
  ''';

  // The same position down two move orders: identical board, different clocks.
  const e4Fresh = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
  const e4Later = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 7 14';
  const d4 = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1';

  setUpAll(() async {
    await initEvalTestSqlite();
  });

  Future<Database> v2Database() async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute(v2Evals);
    await db.execute(v2Maia);
    return db;
  }

  Future<void> putEval(Database db, String fen, int cp, int depth) => db.insert(
    'evals',
    {'fen': fen, 'eval_cp_white': cp, 'depth': depth, 'created_at': 1},
  );

  Future<void> putMaia(Database db, String fen, String json, int created) =>
      db.insert('maia_cache', {
        'fen': fen,
        'elo': 1500,
        'policy_json': json,
        'win_prob': 0.5,
        'created_at': created,
      });

  test('collapses transpositions onto the canonical key', () async {
    final db = await v2Database();
    await putEval(db, e4Fresh, 30, 20);
    await putEval(db, e4Later, 31, 12);
    await putEval(db, d4, 15, 18);

    await EvalCache.rekeyToCanonical(db);

    final rows = await db.query('evals', orderBy: 'fen');
    expect(rows, hasLength(2), reason: 'the two e4 rows became one');
    final e4 = rows.firstWhere((r) => (r['fen'] as String).contains('4P3'));
    expect(e4['eval_cp_white'], 30, reason: 'the deeper row wins');
    expect(e4['depth'], 20);
    expect((e4['fen'] as String).split(' '), hasLength(4));
    await db.close();
  });

  test('the deeper row wins whichever order the rows are in', () async {
    final db = await v2Database();
    await putEval(db, e4Fresh, 12, 8);
    await putEval(db, e4Later, 99, 30);

    await EvalCache.rekeyToCanonical(db);

    final rows = await db.query('evals');
    expect(rows.single['eval_cp_white'], 99);
    expect(rows.single['depth'], 30);
    await db.close();
  });

  test('the newest Maia policy survives a collapse', () async {
    final db = await v2Database();
    await putMaia(db, e4Fresh, '{"e7e5":0.1}', 100);
    await putMaia(db, e4Later, '{"e7e5":0.9}', 200);

    await EvalCache.rekeyToCanonical(db);

    final rows = await db.query('maia_cache');
    expect(rows, hasLength(1));
    expect(rows.single['policy_json'], '{"e7e5":0.9}');
    expect(rows.single['elo'], 1500);
    await db.close();
  });

  test('the same position at two ratings stays two rows', () async {
    final db = await v2Database();
    await putMaia(db, e4Fresh, '{"e7e5":0.5}', 100);
    await db.insert('maia_cache', {
      'fen': e4Later,
      'elo': 1900,
      'policy_json': '{"c7c5":0.5}',
      'win_prob': 0.4,
      'created_at': 100,
    });

    await EvalCache.rekeyToCanonical(db);

    expect(await db.query('maia_cache'), hasLength(2));
    await db.close();
  });

  test('carries every row across more pages than one', () async {
    final db = await v2Database();
    // Two full pages and a remainder, so the paging loop's boundaries are
    // exercised rather than assumed.
    const total = 11001;
    final batch = db.batch();
    for (var i = 0; i < total; i++) {
      batch.insert('evals', {
        'fen': '8/8/8/8/8/8/8/K$i w - - 0 1',
        'eval_cp_white': i,
        'depth': 10,
        'created_at': 1,
      });
    }
    await batch.commit(noResult: true);

    await EvalCache.rekeyToCanonical(db);

    final count = (await db.rawQuery(
      'SELECT COUNT(*) AS n FROM evals',
    )).first['n'];
    expect(count, total);
    await db.close();
  });

  test('an empty v2 database migrates to empty v3 tables', () async {
    final db = await v2Database();

    await EvalCache.rekeyToCanonical(db);

    expect(await db.query('evals'), isEmpty);
    expect(await db.query('maia_cache'), isEmpty);
    // The scratch tables are gone, not left behind holding the old rows.
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final names = tables.map((r) => r['name']).toSet();
    expect(names, isNot(contains('evals_v2')));
    expect(names, isNot(contains('maia_cache_v2')));
    await db.close();
  });
}
