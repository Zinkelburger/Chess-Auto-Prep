/// Coalesces bursts of [ChangeNotifier] notifications.
///
/// Background work — an audit checking five positions a second, coverage
/// walking a tree — reports progress far faster than a screen can usefully
/// repaint, and every notification rebuilds the listeners.  A throttle lets
/// the first notification of a quiet period through at once and folds the
/// rest into one trailing notification per [interval], so the display is
/// never more than an interval stale and the rebuild rate is bounded.
///
/// Same shape as `GenerationProgress`'s inline throttle, shared so every
/// progress source behaves the same way.
library;

import 'dart:async';

class NotifyThrottle {
  NotifyThrottle(
    this._notify, {
    this.interval = const Duration(milliseconds: 150),
  });

  final void Function() _notify;
  final Duration interval;

  Timer? _timer;
  DateTime? _lastNotify;

  /// Notify now if the last notification is older than [interval], else
  /// schedule one for when it will be.
  void call() {
    final last = _lastNotify;
    final since = last == null ? interval : DateTime.now().difference(last);
    if (since >= interval) {
      flush();
    } else {
      _timer ??= Timer(interval - since, flush);
    }
  }

  /// Notify immediately, cancelling a pending trailing notification.
  /// Use for state that must land at once (a run finishing, an error).
  void flush() {
    _timer?.cancel();
    _timer = null;
    _lastNotify = DateTime.now();
    _notify();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
