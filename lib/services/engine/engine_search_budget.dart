import 'dart:async';
import 'dart:collection';

import '../../models/engine_settings.dart';

/// Cancellation is control flow, not an engine failure.
class EngineSearchCancelled extends StateError {
  EngineSearchCancelled() : super('Engine search cancelled');
}

class EngineSearchCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

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
  static final instance = EngineSearchBudget(
    capacity: () => EngineSettings.instance.cores,
  );
  EngineSearchBudget({required this.capacity});
  final int Function() capacity;
  final Queue<_WaitingSearch> _waiting = Queue();
  int _used = 0;
  int get activeThreads => _used;

  Future<EngineSearchAllocation> acquire(
    int requested,
    EngineSearchCancellation cancellation,
  ) {
    if (cancellation.isCancelled) return Future.error(EngineSearchCancelled());
    final waiting = _WaitingSearch(requested < 1 ? 1 : requested, cancellation);
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
    while (_waiting.isNotEmpty) {
      final waiting = _waiting.first;
      if (waiting.cancellation.isCancelled) {
        _waiting.removeFirst().result.completeError(EngineSearchCancelled());
        continue;
      }
      final limit = capacity().clamp(1, EngineSettings.systemCores);
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

class EngineSearchAllocation {
  EngineSearchAllocation._(this.threads, this._onRelease);
  final int threads;
  void Function()? _onRelease;
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
