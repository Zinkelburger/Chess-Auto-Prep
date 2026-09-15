import 'dart:async';

/// A transport to one UCI engine: a process, an FFI package or a test double.
abstract class EngineConnection {
  /// Engine output, one line per event. Errors mean the transport failed.
  Stream<String> get stdout;

  /// Completes once the engine has answered the UCI handshake.
  Future<void> waitForReady();

  /// Write one UCI command; may throw synchronously when the pipe is closed.
  void sendCommand(String command);

  /// Idempotent teardown of the engine and its streams.
  void dispose();

  /// Completes when the underlying engine exits or is deliberately disposed.
  /// Consumers record their own disposed state to distinguish shutdown from
  /// an unexpected exit before deciding whether to replace the worker.
  Future<void> get done;
}
