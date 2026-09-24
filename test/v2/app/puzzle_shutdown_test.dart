import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:chess_auto_prep/v2/app/app.dart';
import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_queue.dart';
import 'package:chess_auto_prep/v2/features/tactics/puzzle_trainer.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/tactics_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final solved in [false, true]) {
    test(
      'shutdown suspends puzzle ${solved ? 'advance' : 'reply'} while engines stop',
      () {
        fakeAsync((async) {
          final w = WindowFixture();
          // The opponent's reply finishes this answer, so an uncancelled timer
          // would create a training write after shutdown drained the saver.
          final text = tacticsSet.replaceFirst('Nf3 Nc6', 'Nf3');
          w.store.documents[tacticsRef] = Opened(text, scriptedRevision(text));
          unawaited(
            w.settings.update(
              w.settings.value.copyWith(puzzles: const PuzzleFilter(days: 14)),
            ),
          );
          unawaited(w.tactics.load());
          async.flushMicrotasks();
          unawaited(w.trainer.start());
          async.flushMicrotasks();
          w.trainer.play('e7e5');
          if (solved) async.elapse(replyDelay);
          final up = w.trainer.up;
          final cursor = w.session.cursor;
          final engines = Completer<void>();
          var stopping = false;
          AppExitResponse? response;
          final exit = AppExit(
            guard: w.parts.exit,
            prepare: w.parts.prepareToClose,
            stopEngines: () {
              stopping = true;
              return engines.future;
            },
            closeLog: () async {},
          );
          unawaited(exit.leave().then((value) => response = value));
          async.elapse(Duration.zero);
          expect(stopping, isTrue);
          final saved = (w.store.documents[tacticsRef]! as Opened).text;
          async.elapse(const Duration(seconds: 10));
          expect(response, isNull);
          expect(w.trainer.up, same(up));
          expect(w.session.cursor, cursor);
          expect(w.session.game, 1);
          expect((w.store.documents[tacticsRef]! as Opened).text, saved);
          engines.complete();
          async.flushMicrotasks();
          expect(response, AppExitResponse.exit);
          w.dispose();
          exit.closing.dispose();
        });
      },
    );
  }

  for (final solved in [false, true]) {
    test(
      'cancelled close resumes the same pending ${solved ? 'advance' : 'reply'}',
      () {
        fakeAsync((async) {
          final w = WindowFixture();
          final text = tacticsSet.replaceFirst('Nf3 Nc6', 'Nf3');
          w.store.documents[tacticsRef] = Opened(text, scriptedRevision(text));
          unawaited(
            w.settings.update(
              w.settings.value.copyWith(puzzles: const PuzzleFilter(days: 14)),
            ),
          );
          unawaited(w.tactics.load());
          async.flushMicrotasks();
          unawaited(w.trainer.start());
          async.flushMicrotasks();
          w.trainer.play('e7e5');
          if (solved) async.elapse(replyDelay);
          final up = w.trainer.up;
          final pending = Completer<String?>();
          AppExitResponse? response;
          final exit = AppExit(
            guard: ExitGuard(
              saver: w.saver,
              question: w.question,
              wait: const Duration(minutes: 1),
              settleFeatures: () => pending.future,
            ),
            prepare: w.parts.prepareToClose,
            onCancelled: w.parts.resumeAfterClose,
            stopEngines: () async => fail('Cancellation must not stop engines'),
            closeLog: () async {},
          );
          unawaited(exit.leave().then((value) => response = value));
          async.elapse(const Duration(seconds: 10));
          expect(w.trainer.up, same(up));
          expect(response, isNull);
          pending.complete('Keep this write for retry');
          async.flushMicrotasks();
          expect(response, AppExitResponse.cancel);
          expect(w.trainer.up, same(up));
          async.elapse(solved ? advanceDelay : replyDelay);
          if (solved) {
            expect(w.session.game, 0);
            expect(w.session.cursor, const NodePath.root());
          } else {
            expect(w.session.game, 1);
            expect(w.session.cursor, NodePath.of([0, 0]));
            expect(w.trainer.up?.finished, isTrue);
          }
          w.dispose();
          exit.closing.dispose();
        });
      },
    );
  }

  test(
    'resume cannot apply an old reply to a replacement puzzle or disposed owner',
    () {
      fakeAsync((async) {
        final w = WindowFixture();
        unawaited(w.tactics.load());
        async.flushMicrotasks();
        unawaited(w.trainer.start());
        async.flushMicrotasks();
        w.trainer.play('e7e5');
        w.parts.prepareToClose();
        w.session.showGame(0);
        final replacement = w.trainer.up;
        w.parts.resumeAfterClose();
        async.elapse(replyDelay);
        expect(w.trainer.up, same(replacement));
        expect(w.session.game, 0);
        expect(w.session.cursor, const NodePath.root());
        w.trainer.suspend();
        final trainer = w.trainer;
        w.dispose();
        trainer.resume();
        async.elapse(advanceDelay);
      });
    },
  );
}
