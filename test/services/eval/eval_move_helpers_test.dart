/// `evalAfterMoveCached` is what the repertoire audit and the hole hunt use
/// to ask "how bad is the position once this move is played?", and what it
/// returns is also what lands in the shared [EvalCache] that tree generation
/// reads back.
///
/// The case these pin is a forced mate. Stockfish announces one as
/// `scoreMate` with `scoreCp` left null, so code that reads `scoreCp` raw
/// scores every mate as 0.00 — which made the two sweeps that hunt for
/// losing moves blind to the moves that lose *hardest*, and wrote that 0
/// into the cache for everyone downstream.
library;

import 'package:chess_auto_prep/services/eval/eval_move_helpers.dart';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:chess_auto_prep/utils/eval_constants.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../generation/engine_fakes.dart';
import 'eval_test_helpers.dart';

void main() {
  const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  const afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

  /// Black to move and getting mated; White has just played, so the position
  /// after Black's reply is White to move.
  const blackToMove =
      'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2';
  const afterNc6 =
      'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 3';

  late FakeStockfishPool pool;

  setUpAll(() async {
    await initEvalTestSqlite();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    pool = FakeStockfishPool();
    await EvalCache.instance.init();
    await EvalCache.instance.clear();
  });

  group('centipawn scores', () {
    test('White to move after the move keeps the engine sign', () async {
      // 1.e4 leaves Black to move, so the eval after e2e4 is Black-relative
      // and has to be negated to reach White-normalized cp.
      pool.stmCpByFen[afterE4] = -30;

      final (cp, hits, misses) = await evalAfterMoveCached(
        pool,
        EvalCache.instance,
        start,
        'e2e4',
        20,
      );

      expect(cp, 30, reason: 'Black-relative -30 is White-relative +30');
      expect(hits, 0);
      expect(misses, 1);
    });

    test('Black to move after the move negates the engine sign', () async {
      pool.stmCpByFen[afterNc6] = 25;

      final (cp, _, _) = await evalAfterMoveCached(
        pool,
        EvalCache.instance,
        blackToMove,
        'b8c6',
        20,
      );

      expect(cp, 25, reason: 'White-relative already — White is to move');
    });

    test('a second call at the same depth is served from the cache', () async {
      pool.stmCpByFen[afterE4] = -30;

      await evalAfterMoveCached(pool, EvalCache.instance, start, 'e2e4', 20);
      final (cp, hits, misses) = await evalAfterMoveCached(
        pool,
        EvalCache.instance,
        start,
        'e2e4',
        20,
      );

      expect(cp, 30);
      expect(hits, 1);
      expect(misses, 0);
      expect(
        pool.evalCalls.length,
        1,
        reason: 'the engine must not be asked twice for one position',
      );
    });
  });

  group('forced mate', () {
    test('a mate for the side to move packs into a large cp', () async {
      // After 1.e4 it is Black to move; Black mating in 3 is White losing.
      pool.stmMateByFen[afterE4] = 3;

      final (cp, _, _) = await evalAfterMoveCached(
        pool,
        EvalCache.instance,
        start,
        'e2e4',
        20,
      );

      expect(cp, isNotNull);
      expect(
        isMateEval(cp!),
        isTrue,
        reason: 'a forced mate must not read as an ordinary eval',
      );
      expect(cp, -(kMateCpBase - 3), reason: 'Black mates in 3 → White -9997');
      expect(cpToMate(cp), -3);
    });

    test('a mate against the side to move packs the other way', () async {
      // Black to move and getting mated in 2 → White is winning.
      pool.stmMateByFen[afterE4] = -2;

      final (cp, _, _) = await evalAfterMoveCached(
        pool,
        EvalCache.instance,
        start,
        'e2e4',
        20,
      );

      expect(cp, kMateCpBase - 2);
      expect(cpToMate(cp!), 2);
    });

    test('White to move after the move keeps the mate sign', () async {
      // 1...Nc6 leaves White to move; White mating in 4 is White-positive.
      pool.stmMateByFen[afterNc6] = 4;

      final (cp, _, _) = await evalAfterMoveCached(
        pool,
        EvalCache.instance,
        blackToMove,
        'b8c6',
        20,
      );

      expect(cp, kMateCpBase - 4);
    });

    test('the mate is what gets cached, not a 0.00 stand-in', () async {
      pool.stmMateByFen[afterE4] = 3;

      await evalAfterMoveCached(pool, EvalCache.instance, start, 'e2e4', 20);
      await EvalCache.instance.flush();

      final cached = await EvalCache.instance.getEvalCpWhite(
        afterE4,
        minDepth: 20,
      );
      expect(cached, isNotNull);
      expect(
        cached,
        -(kMateCpBase - 3),
        reason:
            'caching 0 for a mating position poisons every later reader — '
            'the audit, the hole hunt and tree generation share this store',
      );
      expect(isMateEval(cached!), isTrue);
    });
  });

  group('unusable input', () {
    test('an illegal move yields no eval and no engine call', () async {
      final (cp, hits, misses) = await evalAfterMoveCached(
        pool,
        EvalCache.instance,
        start,
        'e2e5',
        20,
      );

      expect(cp, isNull);
      expect(hits, 0);
      expect(misses, 0);
      expect(pool.evalCalls, isEmpty);
    });

    test('an unparsable move yields no eval', () async {
      final (cp, _, _) = await evalAfterMoveCached(
        pool,
        EvalCache.instance,
        start,
        'not-a-move',
        20,
      );

      expect(cp, isNull);
    });

    test('an unparsable FEN yields no eval', () async {
      final (cp, _, _) = await evalAfterMoveCached(
        pool,
        EvalCache.instance,
        'not a fen',
        'e2e4',
        20,
      );

      expect(cp, isNull);
    });
  });
}
