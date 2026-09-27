import 'dart:async';
import 'dart:isolate';

import '../chess/game_filter.dart';
import '../chess/pgn/game_text.dart';

/// A filter over one immutable header snapshot. Regex evaluation must never
/// run on the UI isolate: even a short header can cause exponential work.
/// Cancellation and the deadline kill the isolate, including one still being
/// spawned. Only headers cross the boundary, not the games' move trees.
final class FilterRun {
  FilterRun.start(
    List<List<PgnHeader>> headers,
    GameFilter filter, {
    Duration timeout = const Duration(seconds: 2),
  }) {
    _timer = Timer(timeout, () {
      _fail(TimeoutException('Filtering exceeded its time limit.'));
    });
    unawaited(_spawn(headers, filter));
  }

  final _done = Completer<List<bool>?>();
  ReceivePort? _port;
  Isolate? _isolate;
  Timer? _timer;

  /// Null means cancelled; failures, including timeout, complete with error.
  Future<List<bool>?> get result => _done.future;

  void cancel() {
    if (_done.isCompleted) return;
    _close();
    _done.complete(null);
  }

  Future<void> _spawn(List<List<PgnHeader>> headers, GameFilter filter) async {
    final port = _port = ReceivePort();
    port.listen((message) {
      switch (message) {
        case List<bool> passes:
          _close();
          if (!_done.isCompleted) _done.complete(passes);
        case [Object error, Object? stack]:
          _fail(StateError('$error\n$stack'));
        default:
          _fail(StateError('The filter worker exited without an answer.'));
      }
    });
    try {
      final isolate = await Isolate.spawn(
        _filterHeaders,
        (port.sendPort, headers, filter),
        onError: port.sendPort,
        onExit: port.sendPort,
        debugName: 'PGN filter',
      );
      _isolate = isolate;
      if (_done.isCompleted) isolate.kill(priority: Isolate.immediate);
    } on Object catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_done.isCompleted) return;
    _close();
    _done.completeError(error, stack);
  }

  void _close() {
    _timer?.cancel();
    _port?.close();
    _isolate?.kill(priority: Isolate.immediate);
  }
}

void _filterHeaders((SendPort, List<List<PgnHeader>>, GameFilter) job) {
  final (port, headers, filter) = job;
  Isolate.exit(port, [
    for (final tags in headers) filter.keeps((name) => tagValue(tags, name)),
  ]);
}
