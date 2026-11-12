import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/engines/fixed_depth.dart';
import 'package:chess_auto_prep/storage/eval_cache.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_engine.dart';

void main() {
  const start = Chess.initial;
  final afterE4 = start.play(NormalMove.fromUci('e2e4'));

  test(
    'asks for one fixed-depth search and takes its last best line',
    () async {
      final engine = ScriptedEngine();
      final evaluator = FixedDepthEvaluator(engine, depth: 12);
      final asked = evaluator.evaluate(start);
      await pumpEventQueue();
      expect(engine.current.depth, 12);
      expect(engine.current.multiPv, 1);
      engine.current
        ..emit(line(depth: 5, score: const Centipawns(10)))
        ..emit(line(depth: 12, multiPv: 2, score: const Centipawns(99)))
        ..emit(line(depth: 12, score: const Centipawns(30)))
        ..end();
      expect(
        await asked,
        isA<Evaluated>()
            .having((e) => e.eval.cp, 'cp', 30)
            .having((e) => e.depth, 'depth', 12),
      );
    },
  );

  test('a mate is the packed score the search saturates on', () async {
    final engine = ScriptedEngine();
    final evaluator = FixedDepthEvaluator(engine, depth: 12);
    final asked = evaluator.evaluate(start);
    await pumpEventQueue();
    engine.current
      ..emit(line(depth: 12, score: const MateIn(3)))
      ..end();
    expect(await asked, isA<Evaluated>().having((e) => e.eval.cp, 'cp', 9997));
    expect(packedCp(const MateIn(-2)).cp, -9998);
  });

  test(
    'a search that ends with no line is an unavailable evaluation',
    () async {
      final engine = ScriptedEngine();
      final evaluator = FixedDepthEvaluator(engine, depth: 12);
      final asked = evaluator.evaluate(start);
      await pumpEventQueue();
      engine.current.end();
      expect(await asked, isA<EvaluationUnavailable>());
    },
  );

  test('a search cut short below its depth is unavailable, not a verdict '
      '(the engine quit mid-search)', () async {
    final engine = ScriptedEngine();
    final evaluator = FixedDepthEvaluator(engine, depth: 14);
    final asked = evaluator.evaluate(start);
    await pumpEventQueue();
    engine.current.emit(line(depth: 5, score: const Centipawns(80)));
    await engine.quit();
    expect(await asked, isA<EvaluationUnavailable>());
  });

  test(
    'a shallow mate and a finished game are verdicts all the same',
    () async {
      final engine = ScriptedEngine();
      final evaluator = FixedDepthEvaluator(engine, depth: 14);
      final mate = evaluator.evaluate(start);
      await pumpEventQueue();
      engine.current
        ..emit(line(depth: 3, score: const MateIn(2)))
        ..end();
      expect(
        await mate,
        isA<Evaluated>()
            .having((e) => e.eval.cp, 'cp', 9998)
            .having((e) => e.depth, 'depth', 3),
      );

      final over = evaluator.evaluate(start);
      await pumpEventQueue();
      engine.current
        ..emit(line(depth: 0, pv: const []))
        ..end();
      expect(await over, isA<Evaluated>().having((e) => e.eval.cp, 'cp', 0));
    },
  );

  group('with the cache in front', () {
    test('a kept verdict is answered without the engine, from the side to '
        'move', () async {
      final (:cache, :engine, :evaluator) = cachedAtDepth14();
      cache.write(Fen(afterE4.fen).position, cpWhite: 35, depth: 14);
      final answer = await evaluator.evaluate(afterE4);
      expect(
        answer,
        isA<Evaluated>()
            .having((e) => e.eval, 'eval', const Eval(-35))
            .having((e) => e.depth, 'depth', 14),
      );
      expect(engine.searches, isEmpty);
    });

    test('the engine\'s verdict is written back from White\'s side', () async {
      final (:cache, :engine, :evaluator) = cachedAtDepth14();
      final asked = evaluator.evaluate(afterE4);
      await pumpEventQueue();
      engine.current
        ..emit(line(depth: 14, score: const Centipawns(-20)))
        ..end();
      await asked;
      expect(cache.read(Fen(afterE4.fen).position, minDepth: 14), 20);
    });

    test('a search cut short is not written to the cache', () async {
      final (:cache, :engine, :evaluator) = cachedAtDepth14();
      final asked = evaluator.evaluate(start);
      await pumpEventQueue();
      engine.current.emit(line(depth: 5, score: const Centipawns(80)));
      await engine.quit();
      expect(await asked, isA<EvaluationUnavailable>());
      expect(cache.read(Fen(start.fen).position, minDepth: 0), isNull);
    });

    test('a verdict too shallow for this run is asked again', () async {
      final (:cache, :engine, :evaluator) = cachedAtDepth14();
      cache.write(Fen(start.fen).position, cpWhite: 35, depth: 8);
      final asked = evaluator.evaluate(start);
      await pumpEventQueue();
      expect(engine.searches, hasLength(1));
      engine.current.end();
      expect(await asked, isA<EvaluationUnavailable>());
    });
  });

  group('the engine\'s best lines', () {
    Future<List<({String uci, int cp})>?> ranked(
      Position position,
      int count,
      List<EngineLine> lines,
    ) async {
      final engine = ScriptedEngine();
      final asked = fixedDepthLines(engine, position, count: count, depth: 12);
      await pumpEventQueue();
      for (final line in lines) {
        engine.current.emit(line);
      }
      engine.current.end();
      return asked;
    }

    test('come best first, each its first move and its score', () async {
      expect(
        await ranked(start, 2, [
          line(
            depth: 12,
            multiPv: 2,
            score: const Centipawns(20),
            pv: ['d2d4', 'd7d5'],
          ),
          line(depth: 12, score: const Centipawns(30), pv: ['e2e4', 'e7e5']),
        ]),
        [(uci: 'e2e4', cp: 30), (uci: 'd2d4', cp: 20)],
      );
    });

    test('are no ranking when one owed is short of the depth, unless it is '
        'a mate, or has no move', () async {
      final best = line(depth: 12, score: const Centipawns(30), pv: ['e2e4']);
      expect(
        await ranked(start, 2, [
          best,
          line(depth: 11, multiPv: 2, pv: ['d2d4']),
        ]),
        isNull,
      );
      expect(
        await ranked(start, 2, [
          best,
          line(depth: 3, multiPv: 2, score: const MateIn(2), pv: ['d2d4']),
        ]),
        hasLength(2),
      );
      expect(
        await ranked(start, 2, [
          best,
          line(depth: 12, multiPv: 2, pv: const []),
        ]),
        isNull,
      );
    });

    test('need only as many as the position has moves', () async {
      final oneMove = Position.setupPosition(
        Rule.chess,
        Setup.parseFen('7k/8/8/8/8/8/6q1/7K w - - 0 1'),
      );
      expect(
        await ranked(oneMove, 3, [
          line(depth: 12, score: const Centipawns(-900), pv: ['h1g2']),
        ]),
        [(uci: 'h1g2', cp: -900)],
      );
    });
  });
}

/// A depth-14 engine behind an empty in-memory cache, closed when the test
/// ends.
({EvalCache cache, ScriptedEngine engine, CachedEvaluator evaluator})
cachedAtDepth14() {
  final cache = EvalCache.inMemory();
  addTearDown(cache.close);
  final engine = ScriptedEngine();
  return (
    cache: cache,
    engine: engine,
    evaluator: CachedEvaluator(
      FixedDepthEvaluator(engine, depth: 14),
      cache,
      depth: 14,
    ),
  );
}
