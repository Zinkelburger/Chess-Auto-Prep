import 'package:flutter/foundation.dart';
import 'engine_connection.dart';
import 'stockfish_connection_stub.dart'
    if (dart.library.io) 'stockfish_connection_native.dart'
    as platform;

/// Factory for creating the appropriate Stockfish connection based on platform
class StockfishConnectionFactory {
  /// Create a Stockfish connection appropriate for the current platform
  /// Returns null if Stockfish is not available on this platform
  @visibleForTesting
  static Future<EngineConnection?> Function()? createForTest;

  static Future<EngineConnection?> create() async {
    final override = createForTest;
    if (override != null) return override();
    return platform.createStockfishConnection();
  }

  /// Check if Stockfish is available on this platform
  static bool get isAvailable => platform.isStockfishAvailable;
}
