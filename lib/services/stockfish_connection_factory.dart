import 'engine_connection.dart';
import 'stockfish_connection_stub.dart'
    if (dart.library.io) 'stockfish_connection_native.dart'
    if (dart.library.html) 'stockfish_connection_web.dart' as platform;

/// Factory for creating the appropriate Stockfish connection based on platform
class StockfishConnectionFactory {
  /// Create a Stockfish connection appropriate for the current platform
  /// Returns null if Stockfish is not available on this platform
  static Future<EngineConnection?> create() async {
    return platform.createStockfishConnection();
  }
  
  /// Check if Stockfish is available on this platform
  static bool get isAvailable => platform.isStockfishAvailable;
}










