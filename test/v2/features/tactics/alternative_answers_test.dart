import 'dart:async';

import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_run.dart';
import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/tactics/puzzle_trainer.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_engine.dart';
import '../../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  late ScriptedEngine engine;
  final launches = <(int, int)>[];
  Completer<EngineStart>? pendingStart;

  void sitting(void Function(FakeAsync async) body) => fakeAsync((async) {
    engine = ScriptedEngine();
    launches.clear();
    pendingStart = null;
    w = WindowFixture(
      launchEngine: ({required cores, required memoryMb}) async {
        launches.add((cores, memoryMb));
        return pendingStart?.future ?? Started(engine);
      },
    );
    unawaited(
      w.settings.update(
        w.settings.value.copyWith(
          acceptAlternativeAnswers: true,
          autoAdvance: false,
        ),
      ),
    );
    unawaited(w.tactics.load());
    async.flushMicrotasks();
    // The custom Black puzzle asks for d5 against d4; we try e5.
    unawaited(
      w.trainer.start(first: w.tactics.puzzles.firstWhere((p) => p.index == 3)),
    );
    async.flushMicrotasks();
    body(async);
    w.dispose();
    async.flushMicrotasks();
  });

  void finish(FakeAsync async, int cp, {int depth = 14}) {
    engine.current.emit(line(depth: depth, score: Centipawns(cp)));
    engine.current.end();
    async.flushMicrotasks();
  }

  test('preference defaults off and survives settings roundtrip', () {
    expect(Settings.defaults.acceptAlternativeAnswers, isFalse);
    final settings = Settings.defaults.copyWith(acceptAlternativeAnswers: true);
    expect(Settings.fromJson(settings.toJson()), settings);
    expect(Settings.fromJson('{}').acceptAlternativeAnswers, isFalse);
  });

  test(
    'equal black answer holds board, locks input and records one success',
    () => sitting((async) {
      w.trainer.play('e7e5');
      expect(w.trainer.up!.feedback, isA<CheckingAnswer>());
      expect(w.trainer.up!.waiting, isTrue);
      expect(w.trainer.board.value!.lastMove, 'e7e5');
      expect(w.trainer.board.value!.onMove, isNull);
      w.trainer.play('d7d5');
      async.flushMicrotasks();
      expect(launches, [(1, 64)]);
      expect(engine.current.depth, 14);
      expect(engine.current.multiPv, 1);
      // Both children are scored for White. More positive is worse for Black.
      finish(async, 100);
      finish(async, 150);
      expect(w.trainer.up!.feedback, isA<AlternativeSolved>());
      expect(w.trainer.up!.decided, Outcome.solved);
      expect(w.trainer.board.value!.lastMove, 'e7e5');
      expect(engine.quitCalled, isTrue);
      expect(w.session.tree!.children.single.uci, 'd7d5');
      expect(w.session.cursor, const NodePath.root());
      expect(w.trainer.run!.outcomes.values, [Outcome.solved]);
      expect(w.tactics.at(3)!.stats.successes, 1);
      w.trainer.inspectAlternative();
      expect(w.trainer.board.value, isNull);
      expect(w.session.boardLastMove, 'e7e5');
      expect(w.session.tree!.children.single.uci, 'd7d5');
    }),
  );

  test(
    '51 cp worse for solver is wrong and restores the original board',
    () => sitting((async) {
      w.trainer.play('e7e5');
      async.flushMicrotasks();
      finish(async, 100);
      finish(async, 151);
      expect(w.trainer.up!.feedback, isA<Incorrect>());
      expect(w.trainer.up!.decided, Outcome.failed);
      expect(w.trainer.board.value, isNull);
      expect(w.trainer.up!.waiting, isFalse);
      expect(w.session.cursor, const NodePath.root());
    }),
  );

  test(
    'better than the stored move is accepted for White too',
    () => sitting((async) {
      unawaited(
        w.trainer.show(w.tactics.puzzles.firstWhere((p) => p.index == 2)),
      );
      async.flushMicrotasks();
      w.trainer.play('d2d4');
      async.flushMicrotasks();
      finish(async, 10);
      finish(async, -90);
      expect(w.trainer.up!.feedback, isA<AlternativeSolved>());
      expect(w.trainer.up!.decided, Outcome.solved);
    }),
  );

  test(
    'shallow answer is unavailable and does not grade the attempt',
    () => sitting((async) {
      w.trainer.play('e7e5');
      async.flushMicrotasks();
      finish(async, 100, depth: 13);
      expect(w.trainer.up!.feedback, isA<AnswerNotChecked>());
      expect(w.trainer.up!.decided, isNull);
      expect(w.trainer.up!.waiting, isFalse);
      expect(w.trainer.board.value, isNull);
      expect(w.trainer.run!.outcomes, isEmpty);
      expect(engine.quitCalled, isTrue);
    }),
  );

  test(
    'reset drops a delayed launch and quits it when it arrives',
    () => sitting((async) {
      pendingStart = Completer<EngineStart>();
      w.trainer.play('e7e5');
      async.flushMicrotasks();
      w.trainer.reset();
      pendingStart!.complete(Started(engine));
      async.flushMicrotasks();
      expect(engine.quitCalled, isTrue);
      expect(engine.searches, isEmpty);
      expect(w.trainer.up!.feedback, isNull);
      expect(w.trainer.up!.waiting, isFalse);
      expect(w.trainer.run!.outcomes, isEmpty);
    }),
  );

  test(
    'changing puzzles drops a comparison between its two searches',
    () => sitting((async) {
      w.trainer.play('e7e5');
      async.flushMicrotasks();
      finish(async, 0);
      expect(engine.searches, hasLength(2));
      unawaited(
        w.trainer.show(w.tactics.puzzles.firstWhere((p) => p.index == 0)),
      );
      async.flushMicrotasks();
      expect(engine.quitCalled, isTrue);
      expect(w.trainer.up!.puzzle.index, 0);
      expect(w.trainer.up!.feedback, isNull);
      expect(w.trainer.run!.outcomes, isEmpty);
      expect(w.trainer.board.value, isNull);
    }),
  );

  test(
    'close suspension cancels without grading and leaves input resumable',
    () => sitting((async) {
      w.trainer.play('e7e5');
      async.flushMicrotasks();
      w.trainer.suspend();
      async.flushMicrotasks();
      expect(engine.quitCalled, isTrue);
      expect(w.trainer.up!.waiting, isFalse);
      w.trainer.resume();
      w.trainer.play('d7d5');
      expect(w.trainer.up!.decided, Outcome.solved);
    }),
  );

  test(
    'deadline releases input and quits the stalled engine',
    () => sitting((async) {
      w.trainer.play('e7e5');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 31));
      expect(engine.quitCalled, isTrue);
      expect(w.trainer.up!.feedback, isA<AnswerNotChecked>());
      expect(w.trainer.up!.waiting, isFalse);
      expect(w.trainer.run!.outcomes, isEmpty);
    }),
  );

  test(
    'failed engine startup leaves the attempt ungraded',
    () => sitting((async) {
      pendingStart = Completer<EngineStart>()
        ..complete(const StartFailed('unavailable'));
      w.trainer.play('e7e5');
      async.flushMicrotasks();
      expect(w.trainer.up!.feedback, isA<AnswerNotChecked>());
      expect(w.trainer.up!.waiting, isFalse);
      expect(w.trainer.run!.outcomes, isEmpty);
    }),
  );

  test(
    'show solution cancels a check without turning a hint into a solve',
    () => sitting((async) {
      w.trainer.play('e7e5');
      async.flushMicrotasks();
      w.trainer.showSolution();
      async.flushMicrotasks();
      expect(engine.quitCalled, isTrue);
      expect(w.trainer.up!.feedback, isA<Revealed>());
      expect(w.trainer.run!.outcomes, isEmpty);
      expect(w.trainer.board.value, isNull);
    }),
  );

  test(
    'a later accepted move does not replace an earlier failed attempt',
    () => sitting((async) {
      unawaited(
        w.settings.update(
          w.settings.value.copyWith(acceptAlternativeAnswers: false),
        ),
      );
      async.flushMicrotasks();
      w.trainer.play('e7e5');
      expect(w.trainer.up!.decided, Outcome.failed);
      unawaited(
        w.settings.update(
          w.settings.value.copyWith(acceptAlternativeAnswers: true),
        ),
      );
      async.flushMicrotasks();
      w.trainer.play('e7e5');
      async.flushMicrotasks();
      finish(async, 0);
      finish(async, 0);
      expect(w.trainer.up!.feedback, isA<AlternativeSolved>());
      expect(w.trainer.up!.decided, Outcome.failed);
      expect(w.tactics.at(3)!.stats.reviews, 1);
      expect(w.tactics.at(3)!.stats.successes, 0);
      w.trainer.rate(4);
      expect(w.trainer.board.value!.lastMove, 'e7e5');
    }),
  );

  test(
    'enabling board analysis also inspects the accepted move',
    () => sitting((async) {
      w.trainer.play('e7e5');
      async.flushMicrotasks();
      finish(async, 0);
      finish(async, 0);
      engine = ScriptedEngine();
      unawaited(w.analysis.enable());
      async.flushMicrotasks();
      expect(w.trainer.board.value, isNull);
      expect(w.session.boardLastMove, 'e7e5');
      expect(w.analysis.position, w.session.boardFen);
      expect(engine.current.fen, w.session.boardFen);
    }),
  );

  test(
    'illegal move never starts an engine or grades the puzzle',
    () => sitting((async) {
      w.trainer.play('e7e3');
      async.flushMicrotasks();
      expect(launches, isEmpty);
      expect(w.trainer.run!.outcomes, isEmpty);
    }),
  );
}
