import 'engine_connection.dart';

/// Stub implementation - should never be called
bool get isStockfishAvailable => false;

Future<EngineConnection?> createStockfishConnection() async {
  throw UnsupportedError('Stockfish not available on this platform');
}











