/// Errors that mean "the engine was told to stop / went away".
///
/// [EvalWorker.stop], [StockfishPool.stopAll], worker disposal and an
/// unexpected process exit all surface as one of these. Callers that already
/// requested cancellation treat them as a clean unwind, not a failed run.
///
/// Every subtype is still a [StateError] so existing `on StateError` handlers
/// and `throwsStateError` expectations keep working.
library;

/// Base type for interrupts; check with `is` or [isEngineInterrupt].
abstract class EngineInterruptError extends StateError {
  EngineInterruptError(super.message);
}

/// [StockfishPool.stopAll] rejected a pending `acquire`.
class EnginePoolStoppedError extends EngineInterruptError {
  EnginePoolStoppedError() : super('Pool stopped');
}

/// The worker was disposed while a request was queued or in flight.
class EngineWorkerDisposedError extends EngineInterruptError {
  EngineWorkerDisposedError() : super('Worker disposed');
}

/// The engine process ended on its own (crash, kill or EOF).
class EngineProcessExitedError extends EngineInterruptError {
  EngineProcessExitedError([this.exitCode])
    : super(
        exitCode == null
            ? 'Stockfish process exited'
            : 'Stockfish process exited ($exitCode)',
      );

  /// The process exit code when the transport observed one.
  final int? exitCode;
}

bool isEngineInterrupt(Object error) => error is EngineInterruptError;
