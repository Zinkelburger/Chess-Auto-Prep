/// SharedPreferences IO for per-file PGN slice configs, extracted from
/// `PgnViewerController` (MAINTAINABILITY_PLAN WS-C / runbook A3).
///
/// Holds only the load/save/clear of the JSON-encoded [SliceConfig] keyed by
/// PGN path. The controller keeps `applySlice`/`resetFilters`/`removeSliceChip`
/// (which mutate `filteredGames`) and delegates the storage here.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/pgn_filter_models.dart';

class SlicePersistence {
  SlicePersistence._();

  static const _prefix = 'pgn_slice:';

  /// Persist [config] for [path]; an empty config clears the saved entry.
  static Future<void> save(String path, SliceConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    if (config.isEmpty) {
      await prefs.remove('$_prefix$path');
    } else {
      await prefs.setString('$_prefix$path', config.toJsonString());
    }
  }

  /// Remove any saved slice for [path].
  static Future<void> clear(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$path');
  }

  /// Load a saved slice for [path], or null if none/empty.
  static Future<SliceConfig?> load(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('$_prefix$path');
    if (json == null) return null;
    final config = SliceConfig.fromJsonString(json);
    return config.isEmpty ? null : config;
  }
}
