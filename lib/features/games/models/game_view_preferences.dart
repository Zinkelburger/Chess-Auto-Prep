import 'package:shared_preferences/shared_preferences.dart';

/// Explicit display choices survive game changes; playback itself never does.
class GameViewPreferences {
  final bool playback;
  final bool engine;
  final bool graph;
  final double speed;
  final bool autoNext;

  const GameViewPreferences({
    this.playback = false,
    this.engine = false,
    this.graph = true,
    this.speed = 1,
    this.autoNext = false,
  });

  GameViewPreferences copyWith({
    bool? playback,
    bool? engine,
    bool? graph,
    double? speed,
    bool? autoNext,
  }) => GameViewPreferences(
    playback: playback ?? this.playback,
    engine: engine ?? this.engine,
    graph: graph ?? this.graph,
    speed: speed ?? this.speed,
    autoNext: autoNext ?? this.autoNext,
  );

  static Future<GameViewPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    final speed = prefs.getDouble('game_view.speed') ?? 1;
    return GameViewPreferences(
      playback: prefs.getBool('game_view.playback') ?? false,
      engine: prefs.getBool('game_view.engine') ?? false,
      graph: prefs.getBool('game_view.graph') ?? true,
      speed: speed.isFinite && speed >= 0.5 && speed <= 10 ? speed : 1,
      autoNext: prefs.getBool('game_view.auto_next') ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('game_view.playback', playback);
    await prefs.setBool('game_view.engine', engine);
    await prefs.setBool('game_view.graph', graph);
    await prefs.setDouble('game_view.speed', speed);
    await prefs.setBool('game_view.auto_next', autoNext);
  }
}
