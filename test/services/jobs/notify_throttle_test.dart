import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/jobs/notify_throttle.dart';

void main() {
  test('the first call notifies at once, a burst folds into one trailing', () {
    fakeAsync((async) {
      var notified = 0;
      final throttle = NotifyThrottle(
        () => notified++,
        interval: const Duration(milliseconds: 100),
      );

      throttle();
      expect(notified, 1);

      for (var i = 0; i < 20; i++) {
        async.elapse(const Duration(milliseconds: 2));
        throttle();
      }
      expect(notified, 1, reason: 'inside the interval nothing lands');

      async.elapse(const Duration(milliseconds: 100));
      expect(notified, 2, reason: 'one trailing notification for the burst');

      async.elapse(const Duration(seconds: 1));
      expect(notified, 2);
      throttle.dispose();
    });
  });

  test('flush lands immediately and cancels the pending trailing call', () {
    fakeAsync((async) {
      var notified = 0;
      final throttle = NotifyThrottle(
        () => notified++,
        interval: const Duration(milliseconds: 100),
      );
      throttle();
      async.elapse(const Duration(milliseconds: 10));
      throttle(); // scheduled trailing
      throttle.flush();
      expect(notified, 2);
      async.elapse(const Duration(seconds: 1));
      expect(notified, 2, reason: 'the trailing call was cancelled');
      throttle.dispose();
    });
  });

  test('dispose drops a pending notification', () {
    fakeAsync((async) {
      var notified = 0;
      final throttle = NotifyThrottle(() => notified++);
      throttle();
      async.elapse(const Duration(milliseconds: 10));
      throttle();
      throttle.dispose();
      async.elapse(const Duration(seconds: 1));
      expect(notified, 1);
    });
  });
}
