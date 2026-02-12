import 'dart:async';

abstract class EngineConnection {
  Stream<String> get stdout;
  Future<void> waitForReady();
  void sendCommand(String command);
  void dispose();
}
