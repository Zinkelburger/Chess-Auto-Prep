/// Goal-first presets for the Generate tab.
///
/// The generation form's Layer-1 card lets the user state an intent —
/// opponent, style, effort — instead of assembling ~35 raw parameters.
/// This file holds the pure mapping logic (effort bundles, style ↔
/// selection-mode projection) plus a small SharedPreferences store for
/// named full-config profiles.  Pure logic lives here, widget-free, so it
/// is unit-testable.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'generation_config.dart';

/// How much compute to spend, as a named bundle over the five knobs that
/// dominate build time and output size.  Applying a level sets exactly
/// these fields; everything else is untouched.
enum EffortLevel { draft, standard, deep }

class EffortPreset {
  final EffortLevel level;
  final String label;

  /// Honest, qualitative duration hint — build time varies wildly with
  /// machine and position, so no fake precision.
  final String timeHint;
  final int maxPly;
  final int evalDepth;
  final int ourMultipv;
  final bool verifyFinal;
  final bool wideOpening;

  const EffortPreset({
    required this.level,
    required this.label,
    required this.timeHint,
    required this.maxPly,
    required this.evalDepth,
    required this.ourMultipv,
    required this.verifyFinal,
    required this.wideOpening,
  });

  static const draft = EffortPreset(
    level: EffortLevel.draft,
    label: 'Quick draft',
    timeHint: 'a few minutes',
    maxPly: 16,
    evalDepth: 10,
    ourMultipv: 3,
    verifyFinal: false,
    wideOpening: false,
  );

  static const standard = EffortPreset(
    level: EffortLevel.standard,
    label: 'Standard',
    timeHint: 'roughly 10–30 minutes',
    maxPly: 20,
    evalDepth: 14,
    ourMultipv: 4,
    verifyFinal: true,
    wideOpening: true,
  );

  static const deep = EffortPreset(
    level: EffortLevel.deep,
    label: 'Deep prep',
    timeHint: 'an hour or more',
    maxPly: 26,
    evalDepth: 18,
    ourMultipv: 6,
    verifyFinal: true,
    wideOpening: true,
  );

  static const all = [draft, standard, deep];

  /// The preset matching the given knob values exactly, or null when the
  /// user has customized any of them (the UI then shows no selection and a
  /// "Custom" caption instead of lying about what will run).
  static EffortPreset? detect({
    required int maxPly,
    required int evalDepth,
    required int ourMultipv,
    required bool verifyFinal,
    required bool wideOpening,
  }) {
    for (final preset in all) {
      if (preset.maxPly == maxPly &&
          preset.evalDepth == evalDepth &&
          preset.ourMultipv == ourMultipv &&
          preset.verifyFinal == verifyFinal &&
          preset.wideOpening == wideOpening) {
        return preset;
      }
    }
    return null;
  }
}

/// The Layer-1 style choice: a human-language projection of
/// ([SelectionMode], setup moves).  `playable` and `dbWinRateOnly` (and any
/// odd combination) have no card-level style — the card shows "Custom" and
/// defers to the advanced dialog.
enum RepertoireStyle { solid, practical, trappy, system }

extension RepertoireStyleInfo on RepertoireStyle {
  String get label => switch (this) {
    RepertoireStyle.solid => 'Solid',
    RepertoireStyle.practical => 'Practical',
    RepertoireStyle.trappy => 'Trappy',
    RepertoireStyle.system => 'My system',
  };

  String get description => switch (this) {
    RepertoireStyle.solid =>
      'Always the engine\'s top move — objectively strongest, '
          'sometimes harder to handle.',
    RepertoireStyle.practical =>
      'Best expected score against how opponents at your target level '
          'actually reply. Recommended.',
    RepertoireStyle.trappy =>
      'Prefers lines where opponents are most likely to go wrong, '
          'accepting small objective concessions.',
    RepertoireStyle.system =>
      'Steers toward your preferred setup moves whenever they stay sound.',
  };

  SelectionMode get selectionMode => switch (this) {
    RepertoireStyle.solid => SelectionMode.engineOnly,
    RepertoireStyle.practical => SelectionMode.expectimax,
    RepertoireStyle.trappy => SelectionMode.trappy,
    RepertoireStyle.system => SelectionMode.expectimax,
  };
}

/// The card style matching the current (selectionMode, setupMoves) pair, or
/// null for combinations the card cannot express (playable, dbWinRateOnly,
/// trappy-with-setup, …).
RepertoireStyle? detectStyle({
  required SelectionMode selectionMode,
  required String setupMoves,
}) {
  final hasSetup = setupMoves.trim().isNotEmpty;
  if (hasSetup) {
    return selectionMode == SelectionMode.expectimax
        ? RepertoireStyle.system
        : null;
  }
  return switch (selectionMode) {
    SelectionMode.expectimax => RepertoireStyle.practical,
    SelectionMode.engineOnly => RepertoireStyle.solid,
    SelectionMode.trappy => RepertoireStyle.trappy,
    _ => null,
  };
}

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
