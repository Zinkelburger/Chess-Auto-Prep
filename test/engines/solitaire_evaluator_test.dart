import 'dart:async';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/solitaire_evaluator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_engine.dart';

const _white = ['e2e4', 'd2d4', 'c2c4', 'g1f3', 'b1c3'];
const _black = ['e7e5', 'd7d5', 'c7c5', 'g8f6', 'b8c6'];
const _afterE4 = Fen(
  'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
);

void _rank(
  ScriptedEngine engine,
  List<String> moves, {
  List<Score>? scores,
  int depth = 14,
}) {
  for (var i = 0; i < moves.length; i++) {
    engine.current.emit(
      line(
        multiPv: i + 1,
        depth: depth,
        score: scores?[i] ?? Centipawns(100 - i * 10),
        pv: [moves[i]],
      ),
    );
  }
  engine.current.end();
}

void main() {
  for (final (fen, moves) in [(Fen.initial, _white), (_afterE4, _black)]) {
    test('inclusive 50cp tolerance and crown use the mover at $fen', () async {
      final engine = ScriptedEngine();
      final evaluator = SolitaireEvaluator(() async => Started(engine));
      addTearDown(evaluator.cancel);
      final ready = evaluator.prepare(fen, moves[0]);
      await pumpEventQueue();
      expect(engine.current.fen, fen);
      expect(engine.current.multiPv, 5);
      expect(engine.current.depth, 14);
      _rank(
        engine,
        moves,
        scores: const [
          Centipawns(100),
          Centipawns(50),
          Centipawns(49),
          Centipawns(101),
          Centipawns(100),
        ],
      );
      expect(await ready, isTrue);
      for (final (move, accepted, better) in [
        (moves[1], true, false),
        (moves[2], false, false),
        (moves[3], true, true),
        (moves[4], true, false),
      ]) {
        final verdict = await evaluator.compare(fen, moves[0], move);
        expect(
          verdict,
          isA<SolitaireScored>()
              .having((v) => v.accepted, 'accepted', accepted)
              .having((v) => v.better, 'better', better)
              .having((v) => v.gameScore, 'game score', const Centipawns(100)),
        );
      }
      expect(engine.searches, hasLength(1), reason: 'the ranking is cached');
    });
  }

  test(
    'game and guess outside five get child depth 13, negated and cached',
    () async {
      final engine = ScriptedEngine();
      final evaluator = SolitaireEvaluator(() async => Started(engine));
      addTearDown(evaluator.cancel);
      final ready = evaluator.prepare(Fen.initial, 'a2a3');
      await pumpEventQueue();
      _rank(engine, _white);
      await pumpEventQueue();
      expect(engine.current.depth, 13);
      expect(engine.current.multiPv, 1);
      expect(engine.current.fen.whiteToMove, isFalse);
      expect(engine.current.fen.value, contains('P7/1PPPPPPP'));
      engine.current
        ..emit(line(depth: 13, score: const Centipawns(-25), pv: ['e7e5']))
        ..end();
      expect(await ready, isTrue);
      final verdict = evaluator.compare(Fen.initial, 'a2a3', 'h2h3');
      await pumpEventQueue();
      expect(engine.current.depth, 13);
      engine.current
        ..emit(line(depth: 13, score: const Centipawns(25), pv: ['e7e5']))
        ..end();
      expect(
        await verdict,
        isA<SolitaireScored>()
            .having((v) => v.accepted, 'accepted', true)
            .having((v) => v.better, 'better', false)
            .having((v) => v.gameScore, 'game', const Centipawns(25))
            .having((v) => v.guessScore, 'guess', const Centipawns(-25)),
      );
      await evaluator.compare(Fen.initial, 'a2a3', 'h2h3');
      expect(engine.searches, hasLength(3));
    },
  );

  test(
    'child scores for Black also negate, rather than use White viewpoint',
    () async {
      final engine = ScriptedEngine();
      final evaluator = SolitaireEvaluator(() async => Started(engine));
      addTearDown(evaluator.cancel);
      final answer = evaluator.compare(_afterE4, 'e7e5', 'a7a6');
      await pumpEventQueue();
      _rank(engine, _black);
      await pumpEventQueue();
      expect(engine.current.fen.whiteToMove, isTrue);
      engine.current
        ..emit(line(depth: 13, score: const Centipawns(-200), pv: ['d2d4']))
        ..end();
      expect(
        await answer,
        isA<SolitaireScored>()
            .having((v) => v.better, 'better', true)
            .having((v) => v.guessScore, 'Black score', const Centipawns(200)),
      );
    },
  );

  test(
    'an incomplete ranking is unavailable, including a shallow last update',
    () async {
      final engine = ScriptedEngine();
      final evaluator = SolitaireEvaluator(() async => Started(engine));
      addTearDown(evaluator.cancel);
      final answer = evaluator.compare(Fen.initial, 'e2e4', 'd2d4');
      await pumpEventQueue();
      engine.current.emit(line(depth: 14, pv: ['e2e4']));
      _rank(engine, _white, depth: 13);
      expect(await answer, isA<SolitaireUnavailable>());
    },
  );

  test(
    'incomplete child, engine errors and startup failure never judge a guess',
    () async {
      for (final fail in [false, true]) {
        final engine = ScriptedEngine();
        final evaluator = SolitaireEvaluator(() async => Started(engine));
        addTearDown(evaluator.cancel);
        final answer = evaluator.compare(Fen.initial, 'e2e4', 'a2a3');
        await pumpEventQueue();
        _rank(engine, _white);
        await pumpEventQueue();
        if (fail) {
          engine.current.fail(const EngineFailure('crashed'));
        } else {
          engine.current
            ..emit(line(depth: 12, score: const Centipawns(-999)))
            ..end();
        }
        expect(await answer, isA<SolitaireUnavailable>());
      }
      final unavailable = SolitaireEvaluator(
        () async => const StartFailed('off'),
      );
      expect(await unavailable.prepare(Fen.initial, 'e2e4'), isFalse);
      expect(
        await unavailable.compare(Fen.initial, 'e2e4', 'd2d4'),
        isA<SolitaireUnavailable>(),
      );
      await unavailable.cancel();
    },
  );

  test(
    'mate outcomes never use a centipawn tolerance or a packed cp score',
    () async {
      for (final (game, guess, accepted, better)
          in <(Score, Score, bool, bool)>[
            (const MateIn(3), const Centipawns(99999), false, false),
            (const Centipawns(99999), const MateIn(3), true, true),
            (const MateIn(-3), const Centipawns(-99999), true, true),
            (const Centipawns(-99999), const MateIn(-3), false, false),
            (const MateIn(3), const MateIn(4), false, false),
            (const MateIn(3), const MateIn(2), true, true),
            (const MateIn(-3), const MateIn(-4), true, true),
            (const MateIn(-3), const MateIn(-2), false, false),
          ]) {
        final engine = ScriptedEngine();
        final evaluator = SolitaireEvaluator(() async => Started(engine));
        final answer = evaluator.compare(Fen.initial, 'e2e4', 'd2d4');
        await pumpEventQueue();
        _rank(engine, _white, scores: [game, guess, game, game, game]);
        expect(
          await answer,
          isA<SolitaireScored>()
              .having((v) => v.accepted, 'accepted', accepted)
              .having((v) => v.better, 'better', better),
        );
        await evaluator.cancel();
      }
    },
  );

  test(
    'child mate distances include the root move for the mating side',
    () async {
      final engine = ScriptedEngine();
      final evaluator = SolitaireEvaluator(() async => Started(engine));
      addTearDown(evaluator.cancel);
      final answer = evaluator.compare(Fen.initial, 'e2e4', 'a2a3');
      await pumpEventQueue();
      _rank(engine, _white, scores: List.filled(5, const MateIn(3)));
      await pumpEventQueue();
      engine.current
        ..emit(line(depth: 3, score: const MateIn(-2), pv: ['e7e5']))
        ..end();
      expect(
        await answer,
        isA<SolitaireScored>()
            .having((v) => v.accepted, 'accepted', true)
            .having((v) => v.better, 'better', false)
            .having((v) => v.guessScore, 'distance at root', const MateIn(3)),
      );
    },
  );

  test(
    'terminal child mate and stalemate are scored without an engine search',
    () async {
      const fen = Fen('7k/5Q2/6K1/8/8/8/8/8 w - - 0 1');
      for (final (guess, score) in <(String, Score)>[
        ('f7g7', const MateIn(1)),
        ('f7e6', const Centipawns(0)),
      ]) {
        final engine = ScriptedEngine();
        final evaluator = SolitaireEvaluator(() async => Started(engine));
        final answer = evaluator.compare(fen, 'f7f6', guess);
        await pumpEventQueue();
        _rank(engine, ['f7f6', 'f7e7', 'f7d7', 'f7c7', 'f7b7']);
        expect(
          await answer,
          isA<SolitaireScored>().having((v) => v.guessScore, 'terminal', score),
        );
        expect(engine.searches, hasLength(1));
        await evaluator.cancel();
      }
    },
  );

  test('moving to a new position invalidates a pending verdict', () async {
    final engine = ScriptedEngine();
    final evaluator = SolitaireEvaluator(() async => Started(engine));
    addTearDown(evaluator.cancel);
    final old = evaluator.compare(Fen.initial, 'e2e4', 'd2d4');
    await pumpEventQueue();
    final next = evaluator.prepare(_afterE4, 'e7e5');
    _rank(engine, _white);
    expect(await old, isA<SolitaireUnavailable>());
    await pumpEventQueue();
    expect(engine.current.fen, _afterE4);
    _rank(engine, _black);
    expect(await next, isTrue);
  });

  test(
    'failed preparation retries the same position with a fresh engine',
    () async {
      final engines = [ScriptedEngine(), ScriptedEngine()];
      var launches = 0;
      final evaluator = SolitaireEvaluator(
        () async => Started(engines[launches++]),
      );
      addTearDown(evaluator.cancel);
      final first = evaluator.prepare(Fen.initial, 'e2e4');
      await pumpEventQueue();
      engines.first.current.end();
      expect(await first, isFalse);
      expect(engines.first.quitCalled, isTrue);
      final retry = evaluator.compare(Fen.initial, 'e2e4', 'd2d4');
      await pumpEventQueue();
      _rank(engines.last, _white);
      expect(await retry, isA<SolitaireScored>());
      expect(launches, 2);
    },
  );

  test(
    'a stale preparation timeout lets the next position launch afresh',
    () async {
      final engines = [ScriptedEngine(), ScriptedEngine()];
      var launches = 0;
      final evaluator = SolitaireEvaluator(
        () async => Started(engines[launches++]),
        patience: const Duration(milliseconds: 80),
      );
      addTearDown(evaluator.cancel);
      final old = evaluator.prepare(Fen.initial, 'e2e4');
      await pumpEventQueue();
      final next = evaluator.prepare(_afterE4, 'e7e5');
      expect(await old, isFalse);
      await pumpEventQueue();
      expect(launches, 2);
      _rank(engines.last, _black);
      expect(await next, isTrue);
    },
  );

  test(
    'cancellation rejects pending searches and late launches are quit',
    () async {
      final launched = Completer<EngineStart>();
      final engine = ScriptedEngine();
      final evaluator = SolitaireEvaluator(() => launched.future);
      final pending = evaluator.compare(Fen.initial, 'e2e4', 'd2d4');
      await pumpEventQueue();
      await evaluator.cancel();
      expect(await pending, isA<SolitaireUnavailable>());
      launched.complete(Started(engine));
      await pumpEventQueue();
      expect(engine.quitCalled, isTrue);
      expect(engine.searches, isEmpty);

      final running = ScriptedEngine();
      final active = SolitaireEvaluator(() async => Started(running));
      final answer = active.compare(Fen.initial, 'e2e4', 'd2d4');
      await pumpEventQueue();
      await active.cancel();
      expect(await answer, isA<SolitaireUnavailable>());
      expect(running.quitCalled, isTrue);
    },
  );

  test(
    'timeouts and hanging quit remain bounded, including late launch',
    () async {
      final engine = _Unresponsive();
      addTearDown(engine.dispose);
      final evaluator = SolitaireEvaluator(
        () async => Started(engine),
        patience: const Duration(milliseconds: 20),
        closingPatience: const Duration(milliseconds: 10),
      );
      expect(
        await evaluator.compare(Fen.initial, 'e2e4', 'd2d4'),
        isA<SolitaireUnavailable>(),
      );
      await evaluator.cancel();
      expect(engine.quitCalled, isTrue);
      final started = Completer<EngineStart>();
      final late = ScriptedEngine();
      final pending = SolitaireEvaluator(
        () => started.future,
        patience: const Duration(milliseconds: 10),
      );
      expect(await pending.prepare(Fen.initial, 'e2e4'), isFalse);
      started.complete(Started(late));
      await pumpEventQueue();
      expect(late.quitCalled, isTrue);
      expect(late.searches, isEmpty);
    },
  );
}

final class _Unresponsive implements Engine {
  bool quitCalled = false;
  final _lines = StreamController<EngineLine>();

  Future<void> dispose() async => _lines.close();
  @override
  String get name => 'Unresponsive';
  @override
  Future<EngineExit> get exited => Completer<EngineExit>().future;
  @override
  Search analyse(Fen fen, {required int multiPv, int? depth}) =>
      Search(lines: _lines.stream, stop: () => Completer<void>().future);
  @override
  Future<void> quit() {
    quitCalled = true;
    return Completer<void>().future;
  }
}
