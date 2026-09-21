import 'dart:async';

import 'package:chess_auto_prep/v2/workspace/save_clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
