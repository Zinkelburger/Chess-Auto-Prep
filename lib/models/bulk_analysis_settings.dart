/// Shared Stockfish depth for game reviews and repertoire builds.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/safe_change_notifier.dart';

class BulkAnalysisSettings extends ChangeNotifier with SafeChangeNotifier {
  BulkAnalysisSettings._();

  static final BulkAnalysisSettings instance = BulkAnalysisSettings._();

  /// Test-only: an isolated instance sharing the same prefs key.
  @visibleForTesting
  BulkAnalysisSettings.forTest();

  static const prefKey = 'engine_settings.bulk_depth';
  static const legacyPrefKey = 'tactics_import.depth';

  static const int defaultDepth = 15;

  static const int minDepth = 1;
  static const int maxDepth = 99;

  int _depth = defaultDepth;
  bool _loaded = false;
  Future<void>? _loading;

  int get depth => _depth;
  bool get isLoaded => _loaded;

  /// Load once; concurrent callers share the in-flight read.
  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _depth =
        (prefs.getInt(prefKey) ?? prefs.getInt(legacyPrefKey) ?? defaultDepth)
            .clamp(minDepth, maxDepth);
    _loaded = true;
    _loading = null;
    notifyListeners();
  }

  Future<void> setDepth(int value) async {
    final clamped = value.clamp(minDepth, maxDepth);
    if (clamped == _depth && _loaded) return;
    _depth = clamped;
    _loaded = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(prefKey, clamped);
  }

  /// The persisted depth for callers that cannot wait for [ensureLoaded]
  /// (a background run starting before any UI touched this setting).
  static Future<int> loadSavedDepth() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(prefKey) ??
            prefs.getInt(legacyPrefKey) ??
            defaultDepth)
        .clamp(minDepth, maxDepth);
  }
}
