import 'package:flutter/foundation.dart';
import 'engine_connection.dart';
import 'stockfish_package_connection.dart';
import 'process_connection_factory.dart';

/// Native implementation - uses FFI Stockfish package or bundled binary
bool get isStockfishAvailable => true;

Future<EngineConnection?> createStockfishConnection() async {
  if (defaultTargetPlatform == TargetPlatform.android || 
      defaultTargetPlatform == TargetPlatform.iOS) {
    // Use package:stockfish for Mobile (FFI)
    print('Using Stockfish Package (FFI) for mobile');
    return StockfishPackageConnection();
  } else {
    // Use bundled binary for Desktop
    print('Using Stockfish Process (Bundled Binary) for desktop');
    return ProcessConnection.create();
  }
}






