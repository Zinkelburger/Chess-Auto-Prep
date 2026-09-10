import 'dart:async';

abstract class EngineConnection {
  Stream<String> get stdout;
  Future<void> waitForReady();
  void sendCommand(String command);
  void dispose();

  /// Completes when the underlying engine exits or is deliberately disposed.
  /// Consumers record their own disposed state to distinguish shutdown from
  /// an unexpected exit before deciding whether to replace the worker.
  Future<void> get done;
}
