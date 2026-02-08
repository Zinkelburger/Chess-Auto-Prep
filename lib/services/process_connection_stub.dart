// Stub for Web/Non-IO environments
import 'dart:async';
import 'engine_connection.dart';

class ProcessConnection implements EngineConnection {
  static Future<ProcessConnection> create() async {
    throw UnsupportedError('Process connection not supported on this platform');
  }

  /// Not available on this platform.
  static Future<String> resolveExecutablePath() async {
    throw UnsupportedError('Process connection not supported on this platform');
  }

  @override
  Stream<String> get stdout => const Stream.empty();

  @override
  Future<void> waitForReady() async {}

  @override
  void sendCommand(String command) {}

  @override
  void dispose() {}
}
