/// Shared recognition of "the engine was told to stop / died" errors.
///
/// [EvalWorker.stop], [StockfishPool.stopAll], and unexpected process exit
/// all surface as [StateError] with one of these messages. Callers that
/// already requested cancellation should treat them as a clean unwind, not
/// a failed run.
library;

bool isEngineInterrupt(Object error) {
  if (error is! StateError) return false;
  final message = error.message;
  return message == 'Eval stopped' ||
      message == 'Discovery stopped' ||
      message == 'Cancelled by new eval' ||
      message == 'Pool stopped' ||
      message == 'Worker disposed' ||
      message.startsWith('Stockfish process exited');
}
