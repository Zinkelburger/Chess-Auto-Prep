import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_run.dart';
import 'package:chess_auto_prep/v2/features/tactics/puzzle_trainer.dart';
import 'package:chess_auto_prep/v2/features/tactics/puzzle_up.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/tactics_fixture.dart';
import '../../support/window_fixture.dart';

/// A sitting of puzzles over the real session, requests and saver, with a
/// scripted store holding the set: the default queue is #1 (Black, two moves
/// to find), #0 (White, mate in one), #3 (custom).
void main() {
  late WindowFixture w;

  /// Runs [body] in fake time with a fresh window, the set read.
  void sitting(void Function(FakeAsync async) body) => fakeAsync((async) {
    w = WindowFixture();
    w.tactics.load();
    async.flushMicrotasks();
    body(async);
    w.dispose();
  });

  String setText() => (w.store.documents[tacticsRef]! as Opened).text;

  /// The text of game [index] of the set as it is on disk now.
  String gameOnDisk(int index) => setText()
      .split('[Event ')
      .where((g) => g.startsWith('"Default'))
      .toList()[index];

  void begin(FakeAsync async) {
    w.trainer.start();
    async.flushMicrotasks();
  }

  test(
    'play puts the first of the queue on the board with its answer '
    'hidden',
    () => sitting((async) {
      expect([for (final p in w.tactics.queue) p.index], [1, 0, 3]);
      begin(async);
      expect(w.session.source, tacticsRef);
      expect(w.session.game, 1);
      expect(w.trainer.up?.puzzle.index, 1);
      expect(w.session.shownTo, const NodePath.root());
      // The answer is not one arrow key away.
      w.session.forward();
      expect(w.session.cursor, const NodePath.root());
    }),
  );

  test(
    'a wrong move is said, left off the board and counts as the '
    'attempt',
    () => sitting((async) {
      begin(async);
      w.trainer.play('d7d5');
      expect(w.trainer.up?.feedback, isA<Incorrect>());
      expect((w.trainer.up!.feedback! as Incorrect).san, 'd5');
      expect(w.session.cursor, const NodePath.root());
      async.elapse(Duration.zero);
      expect(gameOnDisk(1), contains('[ReviewCount "1"]\n[SuccessCount "0"]'));
      expect(w.trainer.run?.outcomes.values, [Outcome.failed]);
    }),
  );

  test(
    'right moves walk the answer with the reply in between; solving '
    'shows it all and a solve after a miss stays a miss',
    () => sitting((async) {
      begin(async);
      w.trainer.play('d7d5');
      w.trainer.play('e7e5');
      final correct = w.trainer.up!.feedback! as Correct;
      expect((correct.found, correct.of), (1, 2));
      expect(w.trainer.up!.waiting, isTrue);
      // Nothing is taken while the reply is on its way.
      w.trainer.play('b8c6');
      expect(w.session.cursor, NodePath.of([0]));
      async.elapse(replyDelay);
      expect(w.session.cursor, NodePath.of([0, 0]));
      expect(w.session.shownTo, NodePath.of([0, 0]));
      w.trainer.play('b8c6');
      expect(w.trainer.up!.feedback, isA<Solved>());
      expect(w.trainer.up!.decided, Outcome.failed);
      expect(w.session.shownTo, isNull);
      async.elapse(Duration.zero);
      expect(gameOnDisk(1), contains('[ReviewCount "1"]\n[SuccessCount "0"]'));
    }),
  );

  test(
    'a clean solve is written as a success, and auto-advance brings the '
    'next puzzle',
    () => sitting((async) {
      begin(async);
      w.trainer.play('e7e5');
      async.elapse(replyDelay);
      w.trainer.play('b8c6');
      expect(w.trainer.up!.decided, Outcome.solved);
      async.elapse(Duration.zero);
      expect(gameOnDisk(1), contains('[ReviewCount "1"]\n[SuccessCount "1"]'));
      async.elapse(advanceDelay);
      expect(w.session.game, 0);
      expect(w.trainer.up?.puzzle.index, 0);
      expect(w.session.shownTo, const NodePath.root());
    }),
  );

  test(
    'show solution steps to the answer and writes nothing',
    () => sitting((async) {
      w.settings.update(w.settings.value.copyWith(autoAdvance: false));
      begin(async);
      w.trainer.next();
      async.flushMicrotasks();
      expect(w.session.game, 0);
      w.trainer.showSolution();
      expect((w.trainer.up!.feedback! as Revealed).rest, ['Qxf7#']);
      expect(w.session.cursor, NodePath.of([0]));
      expect(w.session.shownTo, isNull);
      async.elapse(const Duration(seconds: 10));
      expect(gameOnDisk(0), isNot(contains('ReviewCount')));
      // Walking the answer is allowed; nothing new is played into the set.
      w.trainer.play('e1d1');
      expect(w.session.cursor, NodePath.of([0]));
    }),
  );

  test(
    'reset hides the answer again and keeps the attempt',
    () => sitting((async) {
      begin(async);
      w.trainer.play('d7d5');
      w.trainer.play('e7e5');
      async.elapse(replyDelay);
      w.trainer.reset();
      expect(w.session.cursor, const NodePath.root());
      expect(w.session.shownTo, const NodePath.root());
      expect(w.trainer.up!.decided, Outcome.failed);
      expect(w.trainer.up!.feedback, isNull);
    }),
  );

  test(
    'after the last puzzle the run ends in a recap; retry plays the '
    'failed and skipped again',
    () => sitting((async) {
      w.settings.update(w.settings.value.copyWith(autoAdvance: false));
      begin(async);
      w.trainer.play('d7d5');
      w.trainer.next();
      async.flushMicrotasks();
      w.trainer.next();
      async.flushMicrotasks();
      expect(w.session.game, 3);
      w.trainer.next();
      async.flushMicrotasks();
      final recap = w.trainer.recap!;
      expect((recap.solved, recap.failed, recap.skipped), (0, 1, 2));
      expect(w.trainer.up, isNull);
      expect(w.session.shownTo, isNull);
      w.trainer.retryMistakes();
      async.flushMicrotasks();
      expect(w.trainer.run?.queue.length, 3);
      expect(w.trainer.up?.puzzle.index, 1);
    }),
  );

  test(
    'a rating is written into the puzzle\'s game',
    () => sitting((async) {
      begin(async);
      w.trainer.showSolution();
      w.trainer.rate(1);
      expect(w.trainer.up!.rating, 1);
      async.elapse(Duration.zero);
      expect(gameOnDisk(1), contains('[StarRating "1"]'));
      w.trainer.rate(0);
      async.elapse(Duration.zero);
      expect(gameOnDisk(1), isNot(contains('StarRating')));
    }),
  );

  test(
    'another document takes the puzzle off the board but not the run, '
    'and next brings the set back',
    () => sitting((async) {
      begin(async);
      w.requests.open(kidMain);
      async.flushMicrotasks();
      expect(w.session.source, kidMain);
      expect(w.trainer.up, isNull);
      expect(w.trainer.run, isNotNull);
      expect(w.session.shownTo, isNull);
      w.trainer.next();
      async.flushMicrotasks();
      expect(w.session.source, tacticsRef);
      expect(w.trainer.up?.puzzle.index, 0);
    }),
  );

  test(
    'with no puzzle up, a board move goes into the document',
    () => sitting((async) {
      w.requests.open(kidMain);
      async.flushMicrotasks();
      final before = w.session.tree;
      // Black to move at the root of this chapter, and a7a6 not in it.
      w.trainer.play('a7a6');
      expect(identical(w.session.tree, before), isFalse);
    }),
  );
}
