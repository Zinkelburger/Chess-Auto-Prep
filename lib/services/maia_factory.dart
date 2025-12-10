import 'maia_stub.dart'
    if (dart.library.io) 'maia_native.dart'
    if (dart.library.html) 'maia_web.dart' as platform;

/// Abstract interface for Maia evaluation
abstract class MaiaEvaluator {
  Future<void> initialize();
  Future<Map<String, double>> evaluate(String fen, int elo);
  void dispose();
}

/// Factory for creating the appropriate Maia evaluator based on platform
class MaiaFactory {
  static MaiaEvaluator? _instance;
  
  /// Get the Maia evaluator for the current platform
  /// Returns null if Maia is not available on this platform
  static MaiaEvaluator? get instance {
    _instance ??= platform.createMaiaEvaluator();
    return _instance;
  }
  
  /// Check if Maia is available on this platform
  static bool get isAvailable => platform.isMaiaAvailable;
}


