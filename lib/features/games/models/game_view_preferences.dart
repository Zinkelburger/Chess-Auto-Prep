import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The PGN viewer's display choices. Explicit choices survive game changes;
/// playback itself never does.
@immutable
class GameViewPreferences {
  const GameViewPreferences({
    this.playback = false,
    this.engine = false,
    this.graph = false,
    this.speed = defaultSpeed,
    this.autoNext = false,
    this.autoSave = true,
    this.autoDetectOpenings = true,
    this.showOpening = false,
  });

  static const String autoDetectOpeningsKey = 'pgn_viewer.auto_detect_openings';
  static const String _playbackKey = 'game_view.playback';
  static const String _engineKey = 'game_view.engine';
  static const String _graphKey = 'game_view.graph';
  static const String _speedKey = 'game_view.speed';
  static const String _autoNextKey = 'game_view.auto_next';
  static const String _autoSaveKey = 'game_view.auto_save';
  static const String _showOpeningKey = 'pgn_viewer.show_opening';

  /// Playback speed multiplier bounds; a stored value outside them (or not a
  /// number) falls back to [defaultSpeed].
  static const double minSpeed = 0.5;
  static const double maxSpeed = 10;
  static const double defaultSpeed = 1;

  final bool playback;
  final bool engine;
  final bool graph;
  final double speed;
  final bool autoNext;
  final bool autoSave;
  final bool autoDetectOpenings;
  final bool showOpening;

  GameViewPreferences copyWith({
    bool? playback,
    bool? engine,
    bool? graph,
    double? speed,
    bool? autoNext,
    bool? autoSave,
    bool? autoDetectOpenings,
    bool? showOpening,
  }) => GameViewPreferences(
    playback: playback ?? this.playback,
    engine: engine ?? this.engine,
    graph: graph ?? this.graph,
    speed: speed ?? this.speed,
    autoNext: autoNext ?? this.autoNext,
    autoSave: autoSave ?? this.autoSave,
    autoDetectOpenings: autoDetectOpenings ?? this.autoDetectOpenings,
    showOpening: showOpening ?? this.showOpening,
  );

  static Future<GameViewPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    final speed = prefs.getDouble(_speedKey) ?? defaultSpeed;
    return GameViewPreferences(
      playback: prefs.getBool(_playbackKey) ?? false,
      engine: prefs.getBool(_engineKey) ?? false,
      graph: prefs.getBool(_graphKey) ?? false,
      speed: speed.isFinite && speed >= minSpeed && speed <= maxSpeed
          ? speed
          : defaultSpeed,
      autoNext: prefs.getBool(_autoNextKey) ?? false,
      autoSave: prefs.getBool(_autoSaveKey) ?? true,
      autoDetectOpenings: prefs.getBool(autoDetectOpeningsKey) ?? true,
      showOpening: prefs.getBool(_showOpeningKey) ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_playbackKey, playback);
    await prefs.setBool(_engineKey, engine);
    await prefs.setBool(_graphKey, graph);
    await prefs.setDouble(_speedKey, speed);
    await prefs.setBool(_autoNextKey, autoNext);
    await prefs.setBool(_autoSaveKey, autoSave);
    await prefs.setBool(autoDetectOpeningsKey, autoDetectOpenings);
    await prefs.setBool(_showOpeningKey, showOpening);
  }
}
