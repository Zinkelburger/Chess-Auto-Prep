import 'dart:async';

import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';

EditScope games(Set<int> rewritten) =>
    GamesEdited(GamesWritten(rewritten: rewritten));

Set<int> rewrittenBy(EditScope scope) =>
    (scope as GamesEdited).written.rewritten;

/// The receipt a save from [before] to [after] would bring back.
Receipt saved(String before, String after) => Receipt(
  committed: scriptedRevision(after),
  before: before,
  beforeRevision: scriptedRevision(before),
);

void main() {
  // SaveClock
  const second = Duration(seconds: 1);

  test('the draft goes out when the clock runs out, and every edit restarts '
      'it', () {
    fakeAsync((async) {
      final clock = SaveClock(delay: second);
      var writes = 0;
      Future<void> write() async => writes++;
      clock.edited(write);
      expect(clock.isWaiting, isTrue);
      async.elapse(const Duration(milliseconds: 700));
      expect(writes, 0);
      clock.edited(write);
      async.elapse(const Duration(milliseconds: 700));
      expect(writes, 0, reason: 'the second edit restarted the wait');
      async.elapse(const Duration(milliseconds: 400));
      expect(writes, 1);
      expect(clock.isWaiting, isFalse);
    });
  });

  test('no delay is no clock: the draft goes out on the next turn', () {
    fakeAsync((async) {
      final clock = SaveClock(delay: Duration.zero);
      var writes = 0;
      clock.edited(() async => writes++);
      expect(writes, 0);
      async.flushMicrotasks();
      expect(writes, 1);
    });
  });

  test('flush ends the wait now and answers only when the write has '
      'landed', () {
    fakeAsync((async) {
      final clock = SaveClock(delay: second);
      final landing = Completer<void>();
      var started = false;
      clock.edited(() {
        started = true;
        return landing.future;
      });
      var flushed = false;
      clock.flush().then((_) => flushed = true);
      async.flushMicrotasks();
      expect(started, isTrue, reason: 'the wait was cut short');
      expect(flushed, isFalse, reason: 'the write is still going');
      landing.complete();
      async.flushMicrotasks();
      expect(flushed, isTrue);
    });
  });

  test('flush waits for other work handed to the clock, like an undo', () {
    fakeAsync((async) {
      final clock = SaveClock(delay: second);
      final undo = Completer<void>();
      clock.waitsFor(undo.future);
      var flushed = false;
      clock.flush().then((_) => flushed = true);
      async.flushMicrotasks();
      expect(flushed, isFalse);
      undo.complete();
      async.flushMicrotasks();
      expect(flushed, isTrue);
    });
  });

  test('a write that throws does not break the next flush', () {
    fakeAsync((async) {
      final clock = SaveClock(delay: Duration.zero);
      clock.edited(() async => throw StateError('disk'));
      async.flushMicrotasks();
      var flushed = false;
      clock.flush().then((_) => flushed = true);
      async.flushMicrotasks();
      expect(flushed, isTrue);
    });
  });

  test('hurry with nothing waiting is nothing', () {
    final clock = SaveClock(delay: second);
    clock.hurry();
    expect(clock.isWaiting, isFalse);
  });

  // SaveQueue
  test('two edits are one draft: the newest words, both their games', () {
    final queue = SaveQueue();
    expect(queue.isEmpty, isTrue);
    queue.typed('first', games({0}));
    queue.typed('second', games({1}));
    final draft = queue.take()!;
    expect(draft.text, 'second');
    expect(rewrittenBy(draft.scope), {0, 1});
    expect(queue.isEmpty, isTrue, reason: 'taking empties the queue');
  });

  test('a draft the disk refused goes back behind whatever was typed '
      'meanwhile', () {
    final queue = SaveQueue();
    queue.returned((text: 'refused', scope: games({0})));
    expect(queue.take()!.text, 'refused', reason: 'nothing newer to keep');
    queue.typed('newer', games({1}));
    queue.returned((text: 'refused', scope: games({0})));
    final draft = queue.take()!;
    expect(draft.text, 'newer', reason: 'the newer words are the draft');
    expect(rewrittenBy(draft.scope), {
      0,
      1,
    }, reason: 'but the refused write still names the games it touched');
  });

  test('clearing forgets the draft', () {
    final queue = SaveQueue()..typed('words', games({0}));
    queue.clear();
    expect(queue.isEmpty, isTrue);
    expect(queue.take(), isNull);
  });

  // UndoHistory
  test('keeps the newest receipts and no more than its depth', () {
    final history = UndoHistory();
    expect(history.isEmpty, isTrue);
    for (var i = 0; i <= UndoHistory.depth; i++) {
      history.keep(saved('v$i', 'v${i + 1}'));
    }
    expect(history.newest?.before, 'v${UndoHistory.depth}');
    // The first receipt went when the one past the depth came in.
    var steps = 0;
    while (!history.isEmpty) {
      history.tookBack(history.newest!, saved('', ''));
      steps++;
    }
    expect(steps, UndoHistory.depth);
  });

  test('taking a save back leaves the one before it undoable against the '
      'version just written', () {
    // A → B → C on disk. Undoing C restores B's bytes, but as a new write,
    // so the file's revision is not B's old one; the receipt for A → B must
    // now expect that new revision or the next undo would be refused as a
    // conflict.
    final history = UndoHistory()
      ..keep(saved('A', 'B'))
      ..keep(saved('B', 'C'));
    final restored = Receipt(
      committed: Revision('B-again'),
      before: 'C',
      beforeRevision: scriptedRevision('C'),
    );
    history.tookBack(history.newest!, restored);
    final next = history.newest!;
    expect(next.before, 'A');
    expect(next.beforeRevision, scriptedRevision('A'));
    expect(next.committed, Revision('B-again'));
  });

  test('a receipt that does not chain to the one taken back is left '
      'alone', () {
    // Something outside wrote between the two saves, so the older receipt
    // names a revision the undo did not put back; it stays as it is and
    // will be refused as the conflict it is.
    final history = UndoHistory()
      ..keep(saved('A', 'B'))
      ..keep(saved('X', 'C'));
    history.tookBack(history.newest!, saved('C', 'X'));
    expect(history.newest, isNotNull);
    expect(history.newest!.committed, scriptedRevision('B'));
  });

  test('clearing forgets everything', () {
    final history = UndoHistory()..keep(saved('A', 'B'));
    history.clear();
    expect(history.isEmpty, isTrue);
    expect(history.newest, isNull);
  });
}
