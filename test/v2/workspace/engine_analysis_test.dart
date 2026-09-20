import 'dart:async';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_engine.dart';

void main() {
  late DocumentSession session;
  late ScriptedEngine engine;
  late EngineAnalysis analysis;
  var notifications = 0;
  const tick = Duration(milliseconds: 200);

  setUp(() {
    session = DocumentSession()
      ..open(parseChapter(name: 'Main', text: blackChapter));
    notifications = 0;
  });

  /// Starts the engine inside [async]'s clock. The engine is made here too:
  /// a future completed from another zone would not run its callbacks on
  /// the fake microtask queue.
  void running(FakeAsync async, {EngineStart? start}) {
    engine = ScriptedEngine();
    analysis = EngineAnalysis(session, () async => start ?? Started(engine))
      ..addListener(() => notifications++);
    unawaited(analysis.enable());
    async.flushMicrotasks();
  }

  test('follows the cursor and publishes lines every 200 ms', () {
    fakeAsync((async) {
      running(async);
      expect(analysis.state, isA<EngineRunning>());
      expect(engine.current.fen, session.fen);
      engine.current.emit(line(multiPv: 1, score: const Centipawns(30)));
      engine.current.emit(line(multiPv: 2, score: const Centipawns(10)));
      async.flushMicrotasks();
      expect(analysis.snapshot, isNull, reason: 'not before the tick');
      final before = notifications;
      async.elapse(tick);
      expect(notifications, before + 1);
      final lines = analysis.snapshot!.lines;
      expect(lines.map((l) => l.multiPv), [1, 2]);
      // Black to move: the engine's +0.30 is -0.30 for White.
      expect(lines.first.score, const Centipawns(-30));
      engine.current.emit(line(multiPv: 1, depth: 12));
      async.flushMicrotasks();
      expect(analysis.snapshot!.best.depth, 10, reason: 'still the old tick');
      async.elapse(tick);
      expect(analysis.snapshot!.best.depth, 12);
      expect(analysis.snapshot!.lines, hasLength(2), reason: 'slot 2 kept');
    });
  });

  test('a cursor move starts a new search; old lines never land', () {
    fakeAsync((async) {
      running(async);
      final old = engine.current;
      session.forward();
      expect(old.stopped, isTrue);
      expect(engine.searches, hasLength(2));
      expect(engine.current.fen, session.fen);
      old.emit(line(score: const Centipawns(99))); // still finishing
      engine.current.emit(line(score: const Centipawns(1)));
      async.elapse(tick);
      old.end();
      async.flushMicrotasks();
      expect(analysis.snapshot!.fen, session.fen);
      expect(analysis.snapshot!.best.score, const Centipawns(1));
    });
  });

  test('the end of a search publishes at once', () {
    fakeAsync((async) {
      running(async);
      engine.current.emit(line(score: const MateIn(0)));
      engine.current.end();
      async.flushMicrotasks();
      expect(analysis.snapshot!.best.score, const MateIn(0));
    });
  });

  test('nothing is searched until a chapter is open', () {
    fakeAsync((async) {
      session = DocumentSession();
      running(async);
      expect(engine.searches, isEmpty);
      session.open(parseChapter(name: 'Main', text: blackChapter));
      expect(engine.searches, hasLength(1));
    });
  });

  test('disable quits the engine and clears the pane', () {
    fakeAsync((async) {
      running(async);
      engine.current.emit(line());
      async.elapse(tick);
      unawaited(analysis.disable());
      async.flushMicrotasks();
      expect(engine.quitCalled, isTrue);
      expect(analysis.state, isA<EngineOff>());
      expect(analysis.snapshot, isNull);
      expect(analysis.enabled, isFalse);
    });
  });

  test('turning off while starting quits the engine when it arrives', () {
    fakeAsync((async) {
      engine = ScriptedEngine();
      analysis = EngineAnalysis(
        session,
        () => Future.delayed(const Duration(seconds: 1), () => Started(engine)),
      );
      unawaited(analysis.enable());
      expect(analysis.state, isA<EngineStarting>());
      unawaited(analysis.disable());
      async.elapse(const Duration(seconds: 1));
      expect(analysis.state, isA<EngineOff>());
      expect(engine.quitCalled, isTrue);
      expect(engine.searches, isEmpty);
    });
  });

  test('a launch failure is shown and can be retried', () {
    fakeAsync((async) {
      running(async, start: const StartFailed('No Stockfish in this build'));
      expect(
        (analysis.state as EngineFailed).reason,
        'No Stockfish in this build',
      );
      expect(analysis.enabled, isFalse);
    });
  });

  test('an engine that dies is reported, not silently gone', () {
    fakeAsync((async) {
      running(async);
      engine.crash();
      async.flushMicrotasks();
      expect(
        (analysis.state as EngineFailed).reason,
        'Scripted 1 stopped unexpectedly',
      );
      session.forward();
      expect(
        engine.searches,
        hasLength(1),
        reason: 'no search on a dead engine',
      );
    });
  });

  test('dispose stops following and quits', () {
    fakeAsync((async) {
      running(async);
      analysis.dispose();
      expect(engine.quitCalled, isTrue);
      session.forward();
      expect(engine.searches, hasLength(1));
    });
  });
}
