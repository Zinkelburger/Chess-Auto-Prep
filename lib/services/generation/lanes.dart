/// Bounded work-stealing lanes for the build's independent-per-item phases.
///
/// The coverage sweep, eval enrichment and the build loop itself all have
/// the same shape: a list of positions whose work does not depend on one
/// another, each costing an engine search or a database round trip.  Run
/// serially they leave every worker but one idle; run with one lane per
/// worker each lane pulls the next item the moment it finishes its own, so a
/// single slow position never stalls the rest.
library;

import 'dart:async';

/// Run [task] over [items] with at most [lanes] in flight.
///
/// Items are handed out in order; a lane that finds nothing left returns.
/// [stop] is polled before each item so a cancelled or finished run stops
/// handing out work promptly (items already in flight complete).  Errors
/// propagate after every lane has settled, exactly like `Future.wait`.
Future<void> runLanes<T>(
  List<T> items, {
  required int lanes,
  required Future<void> Function(T item) task,
  bool Function()? stop,
}) async {
  if (items.isEmpty) return;
  var next = 0;

  Future<void> lane() async {
    while (next < items.length) {
      if (stop?.call() ?? false) return;
      await task(items[next++]);
    }
  }

  final count = lanes.clamp(1, items.length);
  await Future.wait([for (var i = 0; i < count; i++) lane()]);
}

/// Wake-up signal between lanes that share a queue: a lane that finds the
/// queue empty while others are still producing waits here instead of
/// spinning or giving up.
class LaneGate {
  Completer<void> _next = Completer<void>();

  /// Completes the next time [signal] is called.
  Future<void> get changed => _next.future;

  /// Wake every lane waiting on [changed].
  void signal() {
    final waiting = _next;
    _next = Completer<void>();
    waiting.complete();
  }
}
