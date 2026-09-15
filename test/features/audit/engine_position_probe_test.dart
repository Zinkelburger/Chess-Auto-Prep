/// [EnginePositionProbe]: the engine questions the audit and the hunt share,
/// with the eval cache in the loop — SAN resolution and ordering of a
/// discovery, the line → cache → engine fallback for a move's eval with its
/// hit/miss accounting, and the White-normalised sign of a verification.
library;

import 'package:chess_auto_prep/features/audit/services/engine_position_probe.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show fenAfterMoves;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/generation/engine_fakes.dart';
import '../../support/hunt_harness.dart';

const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
final _afterE4 = fenAfterMoves(_start, const ['e4'], 0);
final _afterE4E5 = fenAfterMoves(_start, const ['e4', 'e5'], 1);

void main() {
  late FakeStockfishPool pool;
  late EnginePositionProbe probe;

  setUpAll(initTestSqlite);

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await clearEvalCache();
    pool = FakeStockfishPool();
    probe = EnginePositionProbe(pool: pool, evalCache: EvalCache.instance);
    await probe.init();
  });

  group('discover', () {
    test(
      'resolves lines to SAN in engine order and drops the unplayable',
      () async {
        pool.discoveryByFen[_start] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 30, pv: ['e2e4']),
            discoveryLine(pvNumber: 2, cpWhite: 25, pv: ['e2e5']), // illegal
            discoveryLine(pvNumber: 3, cpWhite: 20, pv: ['d2d4']),
          ],
          depth: 14,
        );

        final lines = await probe.discover(_start, depth: 14, multiPv: 3);

        expect(lines.map((l) => l.san), ['e4', 'd4']);
        expect(lines.map((l) => l.uci), ['e2e4', 'd2d4']);
        expect(lines.map((l) => l.whiteCp), [30, 20]);
        expect(pool.discoverMultiPvCalls, [3]);
        expect(probe.stats.lookups, 0, reason: 'not counted unless asked');
      },
    );

    test(
      'caches the best line\'s eval and counts a lookup on request',
      () async {
        pool.discoveryByFen[_start] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 30, pv: ['e2e4']),
          ],
          depth: 14,
        );

        await probe.discover(
          _start,
          depth: 14,
          multiPv: 1,
          countAsLookup: true,
        );

        expect(probe.stats.misses, 1);
        expect(probe.stats.hits, 0);
        await EvalCache.instance.flush();
        expect(
          await EvalCache.instance.getEvalCpWhite(_start, minDepth: 14),
          30,
        );
      },
    );

    test('an empty discovery is an empty list', () async {
      pool.discoveryByFen[_start] = const DiscoveryResult(depth: 14);

      expect(await probe.discover(_start, depth: 14, multiPv: 3), isEmpty);
    });
  });

  group('evalAfterMove', () {
    final lines = [
      const DiscoveredCandidate(uci: 'e2e4', san: 'e4', whiteCp: 30),
    ];

    test('a move the discovery searched needs no engine call', () async {
      final cp = await probe.evalAfterMove(
        _start,
        'e2e4',
        lines: lines,
        depth: 14,
      );

      expect(cp, 30);
      expect(pool.evalCalls, isEmpty);
      expect(probe.stats.lookups, 0);
    });

    test('an off-line move is searched once, then served from cache', () async {
      // Black to move after 1.e4: +20 for Black is -20 for White.
      pool.stmCpByFen[_afterE4] = 20;

      final first = await probe.evalAfterMove(
        _start,
        'e2e4',
        lines: const [],
        depth: 14,
      );
      final second = await probe.evalAfterMove(
        _start,
        'e2e4',
        lines: const [],
        depth: 14,
      );

      expect(first, -20);
      expect(second, -20);
      expect(pool.evalCalls, [_afterE4]);
      expect(probe.stats.misses, 1);
      expect(probe.stats.hits, 1);
    });

    test('an unplayable move is null and counts nothing', () async {
      final cp = await probe.evalAfterMove(
        _start,
        'e2e5',
        lines: const [],
        depth: 14,
      );

      expect(cp, isNull);
      expect(probe.stats.lookups, 0);
    });
  });

  group('verify', () {
    test(
      'flips a side-to-move score to White\'s view and keeps the PV',
      () async {
        pool.stmCpByFen[_afterE4] = 55;
        pool.pvByFen[_afterE4] = ['e7e5', 'g1f3'];

        final verified = await probe.verify(_afterE4, depth: 20);

        expect(verified.whiteCp, -55);
        expect(verified.pv, ['e7e5', 'g1f3']);
        await EvalCache.instance.flush();
        expect(
          await EvalCache.instance.getEvalCpWhite(_afterE4, minDepth: 20),
          -55,
        );
      },
    );

    test('a forced mate is folded into the score', () async {
      pool.stmMateByFen[_afterE4E5] = 3;

      final verified = await probe.verify(_afterE4E5, depth: 20);

      expect(verified.whiteCp, greaterThan(9000));
    });
  });

  test('stats reset to zero', () async {
    pool.stmCpByFen[_afterE4] = 0;
    await probe.evalAfterMove(_start, 'e2e4', lines: const [], depth: 14);
    expect(probe.stats.lookups, 1);

    probe.stats.reset();

    expect(probe.stats.hits, 0);
    expect(probe.stats.misses, 0);
  });
}
