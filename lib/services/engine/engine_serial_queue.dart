import 'dart:async';

/// Serializes protocol/lifecycle transactions without poisoning future work
/// when one transaction fails. The caller still receives the original error.
class EngineSerialQueue {
  Future<void>? _tail;
  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final settled = Completer<void>();
    // Install the tail before action can notify listeners that enqueue more work.
    _tail = settled.future;
    final result = previous == null
        ? Future<T>.sync(action)
        : previous.then((_) => action());
    unawaited(
      result.then<void>(
        (_) => settled.complete(),
        onError: (Object _, StackTrace _) => settled.complete(),
      ),
    );
    return result;
  }
}
