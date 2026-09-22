import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/sources.dart';
import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:chess_auto_prep/v2/engines/fixed_depth.dart';
import 'package:chess_auto_prep/v2/storage/eval_cache.dart';
import 'package:chess_auto_prep/v2/workspace/fill_sources.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_engine.dart';

void main() {
  final start = Chess.initial;
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
      expect(await asked, isA<Evaluated>().having((e) => e.eval.cp, 'cp', 30));
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
      expect(await mate, isA<Evaluated>().having((e) => e.eval.cp, 'cp', 9998));

      final over = evaluator.evaluate(start);
      await pumpEventQueue();
      engine.current
        ..emit(line(depth: 0, score: const Centipawns(0), pv: const []))
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
        isA<Evaluated>().having((e) => e.eval, 'eval', const Eval(-35)),
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
