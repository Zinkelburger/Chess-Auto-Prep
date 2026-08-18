import 'dart:async';

abstract class EngineConnection {
  Stream<String> get stdout;
  Future<void> waitForReady();
  void sendCommand(String command);
  void dispose();

  /// Completes when the engine process dies unexpectedly.
  ///
  /// Does **not** complete when [dispose] is called first — that is a
  /// deliberate shutdown, not a crash. Callers that need to respawn a
  /// worker listen here.
  Future<void> get done;
}
