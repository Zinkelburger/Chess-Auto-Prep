/// The one "how hard does the engine look at my games" setting.
///
/// Search depth used by the game review — the pass that both counts your
/// mistakes and mines them into puzzles. It used to live in a text field inside
/// an "Engine Settings" dialog behind a gear, which is two clicks away from the
/// button whose speed it governs; it is now a stepper on the review strip, and
/// this is the value that stepper edits.
///
/// Companion knob: how many cores that pass may use, which is
/// [EngineSettings.workers] — a machine-level setting with its own owner. Depth
/// is per-workload, so it lives here.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/safe_change_notifier.dart';

class MiningSettings extends ChangeNotifier with SafeChangeNotifier {
  MiningSettings._();

  static final MiningSettings instance = MiningSettings._();

  /// Test-only: an isolated instance sharing the same prefs key.
  @visibleForTesting
  MiningSettings.forTest();

  /// Kept at the historical key so an existing install's depth carries over.
  static const prefKey = 'tactics_import.depth';

  static const int defaultDepth = 15;

  /// Below ~8 the engine mislabels quiet moves as blunders, so the review
  /// would invent mistakes; above 25 a single game takes minutes per core.
  static const int minDepth = 8;
  static const int maxDepth = 25;

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
    _depth = (prefs.getInt(prefKey) ?? defaultDepth).clamp(minDepth, maxDepth);
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
    return (prefs.getInt(prefKey) ?? defaultDepth).clamp(minDepth, maxDepth);
  }
}
