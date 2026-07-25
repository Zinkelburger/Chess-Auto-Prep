/// Named setting profiles for the Generate tab.
///
/// A profile is a whole [TreeBuildConfig] saved under a name, so the user
/// can keep "my anti-London prep" or "quick sanity build" and reapply it
/// verbatim.  There are deliberately no bundled "style" or "effort"
/// presets that rewrite several knobs behind the user's back — every knob
/// on the form is its own control.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'generation_config.dart';

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
