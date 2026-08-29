import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'eval_test_helpers.dart';

/// The eval cache keys on the canonical 4-field FEN, remembers misses, and
/// coalesces writes into batches.  These pin the contract the build pipeline
/// relies on: a transposition with different clocks hits, a read after a
/// write sees it, and `flush()` makes everything durable.
void main() {
  const afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
  const afterE4OtherClocks =
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 5 12';
  const afterD4 = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1';

  setUpAll(() async {
    await initEvalTestSqlite();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await EvalCache.instance.init();
    await EvalCache.instance.clear();
  });

  test('a transposition with different clocks is the same entry', () async {
    final cache = EvalCache.instance;
    await cache.putEvalCpWhite(afterE4, 30, 20);

    expect(await cache.getEvalCpWhite(afterE4OtherClocks), 30);
    expect(await cache.getEvalCpWhite(afterE4OtherClocks, minDepth: 21), null);
    expect(await cache.count(), 1);
  });

  test('a shallower eval never overwrites a deeper one', () async {
    final cache = EvalCache.instance;
    await cache.putEvalCpWhite(afterE4, 30, 20);
    await cache.putEvalCpWhite(afterE4OtherClocks, -99, 10);

    expect(await cache.getEvalCpWhite(afterE4), 30);
    expect(await cache.count(), 1);
  });

  test(
    'a fire-and-forget put is visible immediately and durable soon',
    () async {
      final cache = EvalCache.instance;
      cache.putEvalCpWhiteSoon(afterD4, 12, 18);

      expect(await cache.getEvalCpWhite(afterD4), 12);
      await cache.flush();
      expect(await cache.count(), 1);
    },
  );

  test('a miss is remembered until a put arrives', () async {
    final cache = EvalCache.instance;
    expect(await cache.getEvalCpWhite(afterD4), isNull);
    expect(await cache.getEvalCpWhite(afterD4), isNull);

    await cache.putEvalCpWhite(afterD4, 5, 15);
    expect(await cache.getEvalCpWhite(afterD4), 5);
  });

  test('clear drops pending writes as well as rows', () async {
    final cache = EvalCache.instance;
    cache.putEvalCpWhiteSoon(afterD4, 5, 15);
    await cache.clear();
    await cache.flush();

    expect(await cache.count(), 0);
    expect(await cache.getEvalCpWhite(afterD4), isNull);
  });

  test('a shallow mirror entry does not mask a deeper row on disk', () async {
    final cache = EvalCache.instance;
    // A previous session left a deep eval on disk.
    await cache.putEvalCpWhite(afterE4, 30, 25);
    await cache.flush();
    cache.forgetMemoryMirror();

    // This session installs a shallow one for the same position: the mirror
    // takes it, while the upsert's depth guard keeps the deeper row on disk.
    // The two now disagree, and a deep read must consult the disk.
    await cache.putEvalCpWhite(afterE4, 12, 14);
    await cache.flush();

    expect(await cache.getEvalCpWhite(afterE4, minDepth: 20), 30);
    // …and the mirror heals, so the next deep read costs no query.
    expect(await cache.getEvalCpWhite(afterE4, minDepth: 20), 30);
    expect(await cache.count(), 1);
  });

  test('a remembered miss still answers a deep read without a query', () async {
    final cache = EvalCache.instance;
    expect(await cache.getEvalCpWhite(afterD4, minDepth: 30), isNull);
    expect(await cache.getEvalCpWhite(afterD4, minDepth: 30), isNull);
    expect(await cache.count(), 0);
  });

  test('a fire-and-forget Maia put is visible before the batch', () async {
    final maia = MaiaCache.instance;
    maia.putSoon(afterD4, 1500, {'d7d5': 0.7}, 0.5);

    // Read with no flush in between.  `MaiaService.evaluate` returns on this
    // path, so it must not pay the batch timer the awaited `put` waits on:
    // the mirror has to be filled synchronously by the put itself.
    expect((await maia.get(afterD4, 1500))?.policy['d7d5'], 0.7);

    await EvalCache.instance.flush();
    expect((await maia.get(afterD4, 1500))?.winProb, 0.5);
  });

  test('the Maia cache shares the canonical key', () async {
    final maia = MaiaCache.instance;
    await maia.put(afterE4, 1500, {'e7e5': 0.6, 'c7c5': 0.4}, 0.45);

    final hit = await maia.get(afterE4OtherClocks, 1500);
    expect(hit, isNotNull);
    expect(hit!.policy['e7e5'], 0.6);
    expect(hit.winProb, 0.45);
    expect(await maia.get(afterE4, 1900), isNull);
  });
}
