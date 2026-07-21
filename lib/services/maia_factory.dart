import 'package:flutter/foundation.dart';

import 'maia_stub.dart' if (dart.library.io) 'maia_native.dart' as platform;

import 'maia_service.dart';

/// Abstract interface for Maia evaluation
abstract class MaiaEvaluator {
  Future<void> initialize();
  Future<MaiaResult> evaluate(String fen, int elo);
  void dispose();
}

/// Factory for creating the appropriate Maia evaluator based on platform
class MaiaFactory {
  static MaiaEvaluator? _instance;
  static MaiaEvaluator? _testOverride;

  /// Replace the evaluator in unit tests; set null to restore platform
  /// behavior.  While set, [isAvailable] is true, so the Maia-dependent
  /// expansion paths run deterministically on any platform.
  @visibleForTesting
  static set testOverride(MaiaEvaluator? evaluator) {
    _testOverride = evaluator;
  }

  /// Get the Maia evaluator for the current platform
  /// Returns null if Maia is not available on this platform
  static MaiaEvaluator? get instance {
    if (_testOverride != null) return _testOverride;
    _instance ??= platform.createMaiaEvaluator();
    return _instance;
  }

  /// Check if Maia is available on this platform
  static bool get isAvailable =>
      _testOverride != null || platform.isMaiaAvailable;
}
