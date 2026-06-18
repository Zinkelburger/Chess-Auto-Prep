// WS-C: tests for the extracted AutoPlayEngine (timer-driven playback logic).

import 'package:chess_auto_prep/core/pgn/auto_play_engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scriptable board: each goForward advances along [fens] until the end,
/// after which currentFen stops changing (mimicking "no more moves").
class _FakeBoard {
  _FakeBoard(this.fens);
  final List<String> fens;
  int idx = 0;
  String? get currentFen => idx < fens.length ? fens[idx] : fens.last;
  void goForward() {
    if (idx < fens.length - 1) idx++;
  }
}

AutoPlayEngine _engine(
  _FakeBoard board, {
  bool hasNext = false,
  void Function()? onNext,
}) {
  return AutoPlayEngine(
    isActive: () => true,
    currentFen: () => board.currentFen,
    goForward: board.goForward,
    hasNextGame: () => hasNext,
    nextGame: onNext ?? () {},
    onChanged: () {},
    // Synchronous post-frame so the "did it advance?" check runs inline.
    schedulePostFrame: (cb) => cb(),
  );
}

void main() {
  group('AutoPlayEngine', () {
    test('start/stop toggle isPlaying', () {
      final e = _engine(_FakeBoard(['a', 'b', 'c']));
      expect(e.isPlaying, isFalse);
      e.start();
      expect(e.isPlaying, isTrue);
      e.stop();
      expect(e.isPlaying, isFalse);
    });

    test('advances through moves on each tick then stops at the end', () {
      fakeAsync((async) {
        final board = _FakeBoard(['a', 'b', 'c']);
        final e = _engine(board)..delaySec = 1.0;
        e.start();
        // First tick is 300ms, subsequent are delaySec.
        async.elapse(const Duration(milliseconds: 300)); // a -> b
        expect(board.currentFen, 'b');
        async.elapse(const Duration(seconds: 1)); // b -> c
        expect(board.currentFen, 'c');
        async.elapse(const Duration(seconds: 1)); // c -> c (no move) => stop
        expect(e.isPlaying, isFalse);
      });
    });

    test('rolls over to next game when autoNextGame and a game exists', () {
      fakeAsync((async) {
        var nextCalled = 0;
        final board = _FakeBoard(['a', 'b']); // ends after 1 advance
        final e = _engine(board, hasNext: true, onNext: () => nextCalled++)
          ..autoNextGame = true
          ..delaySec = 1.0;
        e.start();
        async.elapse(const Duration(milliseconds: 300)); // a -> b
        async.elapse(const Duration(seconds: 1)); // b -> b => next game
        expect(nextCalled, 1);
        e.stop();
      });
    });

    test('setSpeed updates delay', () {
      final e = _engine(_FakeBoard(['a']));
      e.setSpeed(2.5);
      expect(e.delaySec, 2.5);
    });

    test('dispose cancels the timer (no further ticks)', () {
      fakeAsync((async) {
        final board = _FakeBoard(['a', 'b', 'c']);
        final e = _engine(board);
        e.start();
        e.dispose();
        async.elapse(const Duration(seconds: 5));
        expect(board.currentFen, 'a', reason: 'no ticks after dispose');
      });
    });
  });
}
