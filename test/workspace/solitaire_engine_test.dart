import 'dart:async';

import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/move_text.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/pgn/solitaire_record.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/solitaire.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_engine.dart';
import '../support/session_fixture.dart';

const _pgn = '''
[Event "Practice"]
[Result "*"]

1. e4 {Secret: next Black move is e5} e5 2. Nf3 Nc6 *
''';

void main() {
  void run(
    void Function(
      FakeAsync,
      SessionFixture,
      Solitaire,
      ScriptedEngine,
      EngineJobs,
    )
    body, {
    String pgn = _pgn,
  }) {
    fakeAsync((async) {
      late SessionFixture f;
      unawaited(openSession(pgn).then((value) => f = value));
      async.flushMicrotasks();
      final engine = ScriptedEngine();
      final analysis = EngineAnalysis(
        f.session,
        () async => const StartFailed('unused'),
      );
      final jobs = EngineJobs(analysis);
      final solitaire = Solitaire(
        f.session,
        analysis,
        jobs: jobs,
        launch: () async => Started(engine),
      );
      try {
        body(async, f, solitaire, engine, jobs);
      } finally {
        solitaire.dispose();
        async.flushMicrotasks();
        jobs.dispose();
        analysis.dispose();
        f.dispose();
      }
    });
  }

  void initialScores(FakeAsync async, ScriptedEngine engine) {
    const candidates = ['d2d4', 'e2e4', 'g1f3', 'b1c3', 'e2e3'];
    const scores = [100, 30, -20, -21, -200];
    for (var i = 0; i < candidates.length; i++) {
      engine.current.emit(
        line(
          multiPv: i + 1,
          depth: 14,
          score: Centipawns(scores[i]),
          pv: [candidates[i]],
        ),
      );
    }
    engine.current.end();
    async.flushMicrotasks();
  }

  test('good alternative at threshold advances original game, records tries '
      'and crowns better moves without editing source', () {
    run((async, f, solitaire, engine, jobs) {
      solitaire.start();
      async.flushMicrotasks();
      expect(engine.current.multiPv, 5);
      expect(engine.current.depth, 14);
      initialScores(async, engine);
      solitaire.play('b1c3'); // 51 cp worse: a retry, not an accepted move.
      async.flushMicrotasks();
      expect(solitaire.lastWrong, isTrue);
      expect(solitaire.guessed, 0);
      expect(
        solitaire.record!.isEmpty,
        isTrue,
        reason: 'the game move must not leak with a wrong attempt',
      );
      solitaire.play('g1f3'); // Exactly 50 cp worse: accepted.
      async.flushMicrotasks();
      expect(solitaire.guessed, 1);
      expect(solitaire.firstTry, 0);
      expect(f.session.currentMove?.san, 'e4');
      expect(solitaire.attempts.last.outcome, SolitaireOutcome.goodMove);
      final progress = writeMoveText(solitaire.record!, terminator: '*');
      expect(progress, contains('Nf3'));
      expect(progress, contains('Nc3'));
      expect(progress, isNot(contains('Secret')));
      expect(progress, isNot(contains('e5')));
      expect(f.onDisk, _pgn);
      expect(f.session.hasHeldEdits, isFalse);
      solitaire.stop();
      async.flushMicrotasks();
      expect(jobs.activeKind, isNull);
    });
  });

  test('better move earns badge and survives final PGN and study handoff', () {
    run((async, f, solitaire, engine, jobs) {
      solitaire.start();
      async.flushMicrotasks();
      initialScores(async, engine);
      solitaire.play('d2d4');
      async.flushMicrotasks();
      expect(solitaire.betterMove, isTrue);
      expect(solitaire.crowns, 1);
      expect(solitaire.firstTry, 1);
      async.elapse(Solitaire.replyDelay);
      solitaire.showHint();
      solitaire.reveal();
      async.elapse(Solitaire.replyDelay);
      expect(solitaire.finished, isTrue);
      expect(solitaire.reviewPgn, contains('Better than the game move'));
      expect(solitaire.reviewPgn, contains('Hint used'));
      expect(solitaire.reviewPgn, contains('Move shown'));
      expect(solitaire.reviewPgn, contains('Secret'));
      expect(solitaire.reviewDraft?.moves.children.length, 2);
      solitaire.inspect(const NodePath.root().child(1));
      expect(f.session.boardFen, solitaire.record!.children[1].fen);
      expect(f.onDisk, _pgn);
      expect(f.session.hasHeldEdits, isFalse);
      async.flushMicrotasks();
      expect(jobs.activeKind, isNull);
      expect(engine.quitCalled, isTrue);
    });
  });

  test('Give up during a pending verdict invalidates that result', () {
    run((async, f, solitaire, engine, jobs) {
      solitaire.start();
      async.flushMicrotasks();
      solitaire.play('d2d4');
      expect(solitaire.checking, isTrue);
      solitaire.reveal();
      expect(solitaire.guessed, 1);
      initialScores(async, engine);
      expect(solitaire.crowns, 0);
      expect(solitaire.attempts.single.outcome, SolitaireOutcome.revealed);
      expect(f.session.currentMove?.san, 'e4');
    });
  });

  test('stop during check discards a late verdict and releases engine job', () {
    run((async, f, solitaire, engine, jobs) {
      solitaire.start();
      async.flushMicrotasks();
      solitaire.play('d2d4');
      solitaire.stop();
      async.flushMicrotasks();
      expect(solitaire.active, isFalse);
      expect(solitaire.attempts, isEmpty);
      expect(solitaire.crowns, 0);
      expect(jobs.activeKind, isNull);
      expect(engine.quitCalled, isTrue);
      expect(f.session.shownTo, isNull);
    });
  });

  test('Black faces player, hint is blocked during automatic reply, and '
      'past-position input is not judged against current frontier', () {
    run((async, f, solitaire, engine, jobs) {
      solitaire.setSide(Side.black);
      solitaire.start();
      expect(f.session.orientation, Side.black);
      solitaire.showHint();
      expect(solitaire.hinted, 0);
      async.elapse(Solitaire.replyDelay);
      expect(solitaire.canHint, isTrue);
      f.session.goTo(const NodePath.root());
      expect(solitaire.canGuess, isFalse);
      solitaire.play('d2d4');
      expect(solitaire.attempts, isEmpty);
      solitaire.returnToGuess();
      expect(solitaire.canGuess, isTrue);
      solitaire.showHint();
      expect(solitaire.hinted, 1);
    });
  });

  test(
    'engine failure never marks an alternative wrong; game move still works',
    () {
      run((async, f, solitaire, engine, jobs) {
        solitaire.start();
        async.flushMicrotasks();
        solitaire.play('d2d4');
        engine.current.end();
        async.flushMicrotasks();
        expect(solitaire.problem, isNotNull);
        expect(solitaire.lastWrong, isFalse);
        expect(solitaire.guessed, 0);
        expect(solitaire.attempts, isEmpty);
        solitaire.play('e2e4');
        async.flushMicrotasks();
        engine.current.end();
        async.flushMicrotasks();
        expect(solitaire.guessed, 1);
        expect(f.session.currentMove?.san, 'e4');
      });
    },
  );

  test(
    'castling game move survives engine failure and a FEN PGN round trip',
    () {
      const pgn = '''
[Event "Castle from a position"]
[SetUp "1"]
[FEN "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"]
[Result "*"]

1. O-O *
''';
      run((async, f, solitaire, engine, jobs) {
        final source = f.session.tree!;
        solitaire.start();
        async.flushMicrotasks();
        solitaire.play('e1g1');
        engine.current.end();
        async.flushMicrotasks();
        expect(solitaire.finished, isTrue);
        expect(solitaire.accepted, 1);
        final exported = solitaire.reviewPgn!;
        final parsed = readGame(exported);
        expect(parsed.issues, isEmpty);
        expect(parsed.tree!.rootFen, source.rootFen);
        expect(parsed.tree!.children.single.fen, source.children.single.fen);
        expect(exported, contains('[Event "Castle from a position"]'));
        expect(exported, contains('[SetUp "1"]'));
        expect(solitaire.reviewDraft!.moves.rootFen, source.rootFen);
        expect(f.onDisk, pgn);
      }, pgn: pgn);
    },
  );
}
