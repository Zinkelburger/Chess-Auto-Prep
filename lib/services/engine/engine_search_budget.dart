import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import '../../utils/system_info.dart';
import 'engine_interrupt.dart';

/// Cancellation is control flow, not an engine failure.
class EngineSearchCancelled extends EngineInterruptError {
  EngineSearchCancelled() : super('Engine search cancelled');
}

/// A one-shot cancellation token shared by a search request and the budget
/// queue it may be waiting in.
class EngineSearchCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  /// Throws [EngineSearchCancelled] once [cancel] has been called.
  void check() {
    if (isCancelled) throw EngineSearchCancelled();
  }
}

/// App-wide admission for Stockfish search threads (idle processes cost none).
/// FIFO admission prevents a stream of new board searches jumping queued jobs.
/// A search receives up to its requested threads from the currently free cores;
/// its allocation is fixed until bestmove or process retirement. Lowering the
/// setting affects new admissions; existing searches finish at their allocation.
class EngineSearchBudget {
  EngineSearchBudget({required this.capacity});

  /// Total threads the app may spend on searches right now.
  final int Function() capacity;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().result.completeError(EngineSearchCancelled());
    }
  }

  final Queue<_WaitingSearch> _waiting = Queue();
  int _used = 0;

  /// Threads currently allocated to admitted searches.
  int get activeThreads => _used;

  /// Queue for up to [requested] threads. Completes with an allocation once
  /// cores are free, or with [EngineSearchCancelled] if [cancellation] fires
  /// first.
  Future<EngineSearchAllocation> acquire(
    int requested,
    EngineSearchCancellation cancellation,
  ) {
    if (_disposed || cancellation.isCancelled)
      return Future.error(EngineSearchCancelled());
    final waiting = _WaitingSearch(math.max(1, requested), cancellation);
    _waiting.add(waiting);
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (_waiting.remove(waiting)) {
          waiting.result.completeError(EngineSearchCancelled());
          _drain();
        }
      }),
    );
    _drain();
    return waiting.result.future;
  }

  void _drain() {
    if (_disposed) return;
    while (_waiting.isNotEmpty) {
      final waiting = _waiting.first;
      if (waiting.cancellation.isCancelled) {
        _waiting.removeFirst().result.completeError(EngineSearchCancelled());
        continue;
      }
      final limit = capacity().clamp(1, getLogicalCores());
      final available = limit - _used;
      if (available <= 0) return;
      _waiting.removeFirst();
      final threads = waiting.requested.clamp(1, available);
      _used += threads;
      waiting.result.complete(
        EngineSearchAllocation._(threads, () {
          _used -= threads;
          _drain();
        }),
      );
    }
  }
}

/// Threads granted to one search; [release] exactly once when it ends.
class EngineSearchAllocation {
  EngineSearchAllocation._(this.threads, this._onRelease);
  final int threads;
  void Function()? _onRelease;

  /// Idempotent: a second call is a no-op.
  void release() {
    final release = _onRelease;
    _onRelease = null;
    release?.call();
  }
}

class _WaitingSearch {
  _WaitingSearch(this.requested, this.cancellation);
  final int requested;
  final EngineSearchCancellation cancellation;
  final result = Completer<EngineSearchAllocation>();
}
