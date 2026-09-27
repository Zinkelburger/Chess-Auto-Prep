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
    if (engines.length * (engines.length - 1) ~/ 2 * gamesPerPairing > 100000)
      return 'Limit a run to 100000 games.';
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
