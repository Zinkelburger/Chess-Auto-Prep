import 'package:dartchess/dartchess.dart';

import '../fen.dart';

Map<String, Object?> tournamentObject(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : const {};
int tournamentInt(Map<String, Object?> data, String key, int fallback) =>
    (data[key] as num?)?.toInt() ?? fallback;

Map<String, Object?> tournamentSnapshot(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable(
      value.map((key, value) => MapEntry(key, _freeze(value))),
    );
Object? _freeze(Object? value) => switch (value) {
  Map() => tournamentSnapshot(Map<String, Object?>.from(value)),
  List() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};

/// Keep unknown fields when reading the shared registry/configuration. An
/// engine in a saved tournament is a snapshot, never a registry reference.
final class TournamentEngine {
  TournamentEngine(Map<String, Object?> data) : json = tournamentSnapshot(data);
  final Map<String, Object?> json;
  static TournamentEngine bundled([String name = 'Stockfish']) =>
      TournamentEngine({
        'id': 'bundled-stockfish',
        'name': name,
        'hashMb': 128,
        'threads': 1,
        'ponder': false,
      });
  String get id => json['id'] as String? ?? 'bundled-stockfish';
  String get name => json['name'] as String? ?? 'Engine';
  String? get executable => json['executablePath'] as String?;
  int get threads => tournamentInt(json, 'threads', 1);
  int get memory => tournamentInt(json, 'hashMb', 128);
  List<String> get arguments =>
      (json['arguments'] as List? ?? const []).cast<String>();
  Map<String, String> get options => {
    'Threads': '$threads',
    'Hash': '$memory',
    'Ponder': 'false',
    for (final entry in tournamentObject(json['options']).entries)
      if (!{'Threads', 'Hash', 'Ponder'}.contains(entry.key))
        entry.key: '${entry.value}',
  };
}

typedef Pairing = ({int index, int round, int white, int black});

final class TournamentConfig {
  TournamentConfig(Map<String, Object?> data)
    : json = tournamentSnapshot(data),
      engines = List.unmodifiable([
        for (final e in data['engines'] as List? ?? const [])
          TournamentEngine(tournamentObject(e)),
      ]);
  final Map<String, Object?> json;
  final List<TournamentEngine> engines;
  String get name => json['name'] as String? ?? 'Engine match';
  Fen get root => Fen(json['startFen'] as String? ?? Fen.initial.value);
  int get gamesPerPairing => tournamentInt(json, 'gamesPerPairing', 10);
  int get concurrency => tournamentInt(json, 'concurrency', 1);
  bool get alternate => json['alternateColors'] != false;
  bool get annotate => json['annotateMoves'] == true;
  Map<String, Object?> get time => tournamentObject(json['timeControl']);
  Map<String, Object?> get adjudication =>
      tournamentObject(json['adjudication']);
  int get maxMoves => tournamentInt(adjudication, 'maxMoves', 300);
  String get kind => time['kind'] as String? ?? 'movetime';
  int timeNumber(String key, int fallback) =>
      tournamentInt(time, key, fallback);

  String? get problem {
    if (name.trim().isEmpty) return 'Name the tournament.';
    if (engines.length < 2 || engines.length > 32) return 'Pick 2–32 engines.';
    if (gamesPerPairing < 1 || gamesPerPairing > 1000)
      return 'Use 1–1000 games per pairing.';
    if (gameCount > 100000) return 'Limit a run to 100000 games.';
    if (concurrency < 1 || concurrency > 64)
      return 'Use 1–64 simultaneous games.';
    if (maxMoves < 1 || maxMoves > 10000) return 'Use 1–10000 moves per game.';
    for (final engine in engines) {
      if (engine.threads < 1 ||
          engine.threads > 1024 ||
          engine.memory < 1 ||
          engine.memory > 65536)
        return 'Use 1–1024 cores and 1–65536 MB per engine.';
      if (engine.options.entries.any(
        (e) => '${e.key}${e.value}'.contains(RegExp(r'[\r\n]')),
      ))
        return 'Engine options must be single lines.';
    }
    if (!{'movetime', 'incremental', 'fixedDepth', 'fixedNodes'}.contains(kind))
      return 'Choose a supported time control.';
    final key = switch (kind) {
      'incremental' => 'baseMs',
      'fixedDepth' => 'depth',
      'fixedNodes' => 'nodes',
      _ => 'movetimeMs',
    };
    if (timeNumber(key, 1) <= 0 || timeNumber('incrementMs', 0) < 0)
      return 'Time and search limits must be positive.';
    try {
      Chess.fromSetup(Setup.parseFen(root.value));
    } on Object {
      return 'Use a legal starting FEN.';
    }
    return null;
  }

  /// `Blitz · 60 s + 0.6 s`: the time control as a run's header states it.
  String get timeLabel {
    final described = describeTime(time);
    final preset = tournamentTimePresets
        .where((p) => describeTime(p.time) == described)
        .firstOrNull;
    return preset == null || preset.label == described
        ? described
        : '${preset.label} · $described';
  }

  /// `Round robin · 10 games per pairing`.
  String get formatLabel =>
      '${json['format'] == 'gauntlet' ? 'Gauntlet' : 'Round robin'} · '
      '$gamesPerPairing ${gamesPerPairing == 1 ? 'game' : 'games'} per pairing';

  int get gameCount =>
      (json['format'] == 'gauntlet'
          ? engines.length - 1
          : engines.length * (engines.length - 1) ~/ 2) *
      gamesPerPairing;
  List<Pairing> get schedule {
    final pairs = <(int, int)>[];
    for (var a = 0; a < engines.length - 1; a++) {
      for (var b = a + 1; b < engines.length; b++) {
        if (json['format'] != 'gauntlet' || a == 0) pairs.add((a, b));
      }
    }
    final games = <Pairing>[];
    for (var round = 0; round < gamesPerPairing; round++) {
      for (final pair in pairs) {
        final reverse = alternate && round.isOdd;
        games.add((
          index: games.length,
          round: round + 1,
          white: reverse ? pair.$2 : pair.$1,
          black: reverse ? pair.$1 : pair.$2,
        ));
      }
    }
    return games;
  }
}

bool legalOpeningMove(String? uci) {
  final move = uci == null ? null : Move.parse(uci);
  return move != null &&
      Chess.fromSetup(Setup.parseFen(Fen.initial.value)).isLegal(move);
}

/// One-click time controls for a new run, the old app's list. Clocks are
/// scaled for engines: an engine's blitz is a minute, not three. Sudden
/// death leaves `movesPerSession` out: v1 reads a 0 as a 0-move period.
const tournamentTimePresets = <({String label, Map<String, Object?> time})>[
  (label: '1 s / move', time: {'kind': 'movetime', 'movetimeMs': 1000}),
  (label: '2 s / move', time: {'kind': 'movetime', 'movetimeMs': 2000}),
  (label: '5 s / move', time: {'kind': 'movetime', 'movetimeMs': 5000}),
  (
    label: 'Bullet',
    time: {'kind': 'incremental', 'baseMs': 10000, 'incrementMs': 100},
  ),
  (
    label: 'Blitz',
    time: {'kind': 'incremental', 'baseMs': 60000, 'incrementMs': 600},
  ),
  (
    label: 'Rapid',
    time: {'kind': 'incremental', 'baseMs': 300000, 'incrementMs': 3000},
  ),
  (
    label: 'Classical',
    time: {
      'kind': 'incremental',
      'baseMs': 600000,
      'incrementMs': 10000,
      'movesPerSession': 40,
    },
  ),
  (label: 'Depth 12', time: {'kind': 'fixedDepth', 'depth': 12}),
  (label: '1M nodes', time: {'kind': 'fixedNodes', 'nodes': 1000000}),
];

/// A saved `timeControl` object in words, with the same defaults a run
/// plays by: `2 s / move`, `60 s + 0.6 s`, `40 moves in 600 s + 10 s`,
/// `Depth 12`, `1M nodes`. Two objects that read the same play the same.
String describeTime(Map<String, Object?> time) {
  int number(String key, int fallback) => tournamentInt(time, key, fallback);
  return switch (time['kind'] ?? 'movetime') {
    'incremental' => [
      if (number('movesPerSession', 0) case final moves when moves > 0)
        '$moves moves in',
      '${_seconds(number('baseMs', 60000))} s +',
      '${_seconds(number('incrementMs', 600))} s',
    ].join(' '),
    'fixedDepth' => 'Depth ${number('depth', 12)}',
    'fixedNodes' => '${_count(number('nodes', 1000000))} nodes',
    _ => '${_seconds(number('movetimeMs', 2000))} s / move',
  };
}

/// Milliseconds as seconds without a trailing `.0`: 600 → `0.6`, 2000 → `2`.
String _seconds(int ms) => ms % 1000 == 0 ? '${ms ~/ 1000}' : '${ms / 1000}';

/// 1000000 → `1M`, 5000 → `5k`, 1234 → `1234`.
String _count(int n) => n % 1000000 == 0
    ? '${n ~/ 1000000}M'
    : n % 1000 == 0
    ? '${n ~/ 1000}k'
    : '$n';
