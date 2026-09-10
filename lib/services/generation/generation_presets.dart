/// Named setting profiles for the Generate tab.
///
/// A profile is a whole [TreeBuildConfig] saved under a name, so the user
/// can keep "my anti-London prep" or "quick sanity build" and reapply it
/// verbatim. The explicit ChessDB starter profile reproduces the method used
/// by the King's Indian book harness; its settings remain editable.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'generation_config.dart';

/// A bounded starting point for the ChessDB + master-practice workflow.
/// Independent of opening and colour; the caller supplies both at build time.
TreeBuildConfig chessDbRepertoirePreset({required bool playAsWhite}) =>
    TreeBuildConfig(
      startFen: '',
      playAsWhite: playAsWhite,
      buildMode: BuildMode.chessDbBook,
      selectionMode: SelectionMode.engineOnly,
      searchAlgorithm: SearchAlgorithm.fast,
      maxPly: 20,
      bookTailMaxPly: 34,
      maxNodes: 12000,
      timeBudgetMinutes: 120,
      minEvalCp: -250,
      maxEvalCp: 500,
      oppMaxChildren: 5,
      oppMassTarget: 0.90,
      verifyFinal: false,
      useMasterGames: true,
      enableChessDbApi: true,
      chessDbApiConcurrency: 1,
      chaptersByEco: true,
      minLinesPerChapter: 4,
    );

/// Named full-config profiles persisted in SharedPreferences.
///
/// Profiles store `TreeBuildConfig.toJson()` minus `start_fen` — the FEN
/// belongs to the position being generated from, never to a profile.
class GenerationPresetStore {
  static const String prefsKey = 'generation_config_presets_v1';

  /// Saved profiles by name, insertion order preserved.
  Future<Map<String, Map<String, dynamic>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in decoded.entries)
          if (e.value is Map<String, dynamic>)
            e.key: e.value as Map<String, dynamic>,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> save(String name, TreeBuildConfig config) async {
    final presets = await load();
    presets[name] = config.toJson()..remove('start_fen');
    await _write(presets);
  }

  Future<void> delete(String name) async {
    final presets = await load();
    presets.remove(name);
    await _write(presets);
  }

  Future<void> _write(Map<String, Map<String, dynamic>> presets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(presets));
  }
}
