/// A bughouse match: Hivemind against Hivemind from one opening, game after
/// game, to ask what the line is worth.
///
/// A participant is a team — the pair A + B or C + D — and differs from the
/// other only in how hard it thinks, because there is one engine. A game's
/// `1-0` is a win for the pair holding White on board 1, as BPGN reads it,
/// so a match exported here scores like a FICS game.
///
/// The record is the old app's `match.json` exactly (version 1): both apps
/// list, read and write the same runs under `Documents/bughouse_matches/`.
library;

import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' show Side;

import 'hivemind.dart';
import 'table.dart';
import 'table_line.dart';
import 'table_setup.dart';

/// How hard a team thinks about each joint action: a node count, which
/// replays, or milliseconds, which is what a player has.
typedef MatchBudget = ({int? nodes, int? movetimeMs});

typedef MatchTeam = ({String name, MatchBudget budget});

/// How far the games may differ: for the first [plies] joint actions a team
/// plays a move drawn from the engine's own top [lines], among those within
/// [window] of the best in Q. Without it a ten-game match is one game ten
/// times — the search does not wobble enough at these budgets to change its
/// answer — and with it every divergence is a move the engine ranked.
typedef MatchVariety = ({int plies, double window, int lines});

const defaultVariety = (plies: 8, window: 0.05, lines: 3);

/// Two teams thinking 800 nodes a move: the same engine against itself,
/// which is the ordinary way to ask what a line is worth.
const List<MatchTeam> defaultTeams = [
  (name: 'Hivemind A', budget: (nodes: 800, movetimeMs: null)),
  (name: 'Hivemind B', budget: (nodes: 800, movetimeMs: null)),
];

final class MatchConfig {
  const MatchConfig({
    required this.name,
    required this.startDualFen,
    required this.seed,
    this.openingLabel = '',
    this.teams = defaultTeams,
    this.games = 10,
    this.alternateSeats = true,
    this.clock = ClockCase.even,
    this.maxPlies = 240,
    this.hashMb = 256,
    this.batchSize = 8,
    this.variety = defaultVariety,
  });

  final String name;

  /// Every game starts here: `<board 1>|<board 2>`.
  final String startDualFen;
  final String openingLabel;

  /// Team 0 holds White on board 1 in the first game.
  final List<MatchTeam> teams;
  final int games;

  /// Swaps which team holds White on board 1 every other game. Off, every
  /// `1-0` is a win for the same side of the line: the opening question.
  final bool alternateSeats;

  /// Who may sit, for the whole match: the one clock bit the engine reads.
  final ClockCase clock;

  /// Half-moves across both boards before a game is filed as a draw.
  final int maxPlies;
  final int hashMb;
  final int batchSize;
  final MatchVariety variety;

  /// The sampler's seed: game `n` samples with `seed + n`, so a stopped
  /// match resumes as it would have gone on.
  final int seed;

  /// The start, or null when the stored FEN does not read.
  TablePosition? get start => switch (readDualFen(startDualFen)) {
    SetupReady(:final position) => position,
    SetupRefused() => null,
  };

  /// The same match sampled with [seed].
  MatchConfig withSeed(int seed) => MatchConfig(
    name: name,
    startDualFen: startDualFen,
    openingLabel: openingLabel,
    teams: teams,
    games: games,
    alternateSeats: alternateSeats,
    clock: clock,
    maxPlies: maxPlies,
    hashMb: hashMb,
    batchSize: batchSize,
    variety: variety,
    seed: seed,
  );

  /// Which team holds White on board 1 in game [index] (0-based).
  (int white, int black) seatsFor(int index) =>
      alternateSeats && index.isOdd ? (1, 0) : (0, 1);

  Map<String, Object?> toJson() => {
    'name': name,
    'startDualFen': startDualFen,
    'openingLabel': openingLabel,
    'participants': [
      for (final team in teams)
        {'name': team.name, 'budget': _budgetJson(team.budget)},
    ],
    'games': games,
    'alternateSeats': alternateSeats,
    'timeStance': _stanceOf(clock),
    'maxPlies': maxPlies,
    'hashMb': hashMb,
    'batchSize': batchSize,
    'variety': {
      'plies': variety.plies,
      'window': variety.window,
      'lines': variety.lines,
    },
    'seed': seed,
  };

  static MatchConfig fromJson(Map<String, Object?> json) {
    final teams = [
      for (final team in _list(json['participants']))
        if (team is Map<String, Object?>)
          (
            name: team['name'] as String? ?? 'Hivemind',
            budget: _budgetOf(team['budget']),
          ),
    ];
    final variety = json['variety'];
    return MatchConfig(
      name: json['name'] as String? ?? 'Bughouse match',
      startDualFen: json['startDualFen'] as String? ?? '',
      openingLabel: json['openingLabel'] as String? ?? '',
      teams: teams.length == 2 ? teams : defaultTeams,
      games: _int(json['games']) ?? 10,
      alternateSeats: json['alternateSeats'] as bool? ?? true,
      clock: _clockOf(json['timeStance']),
      maxPlies: _int(json['maxPlies']) ?? 240,
      hashMb: _int(json['hashMb']) ?? 256,
      batchSize: _int(json['batchSize']) ?? 8,
      variety: variety is Map<String, Object?>
          ? (
              plies: _int(variety['plies']) ?? defaultVariety.plies,
              window:
                  (variety['window'] as num?)?.toDouble() ??
                  defaultVariety.window,
              lines: _int(variety['lines']) ?? defaultVariety.lines,
            )
          : defaultVariety,
      seed: _int(json['seed']) ?? 0,
    );
  }
}

Map<String, Object?> _budgetJson(MatchBudget budget) => {
  if (budget.nodes != null) 'nodes': budget.nodes,
  if (budget.movetimeMs != null) 'movetimeMs': budget.movetimeMs,
};

MatchBudget _budgetOf(Object? json) {
  if (json is! Map<String, Object?>) return (nodes: 800, movetimeMs: null);
  final nodes = _int(json['nodes']);
  if (nodes != null) return (nodes: nodes, movetimeMs: null);
  return (nodes: null, movetimeMs: _int(json['movetimeMs']) ?? 1000);
}

/// The old app names the clock by where A + B stands: ahead, level, behind.
String _stanceOf(ClockCase clock) => switch (clock) {
  ClockCase.abMaySit => 'ahead',
  ClockCase.even => 'level',
  ClockCase.cdMaySit => 'behind',
};

ClockCase _clockOf(Object? stance) => switch (stance) {
  'ahead' => ClockCase.abMaySit,
  'behind' => ClockCase.cdMaySit,
  _ => ClockCase.even,
};

int? _int(Object? value) => (value as num?)?.toInt();

List<Object?> _list(Object? value) => value is List ? value : const [];

enum MatchResult {
  whiteWins('1-0'),
  blackWins('0-1'),
  draw('1/2-1/2'),
  unfinished('*');

  const MatchResult(this.token);

  /// As PGN and BPGN write it.
  final String token;
}

/// Why a game stopped, by the old app's names, every one of them, so a
/// record written by either app reads back as it was.
enum MatchEnding {
  checkmate('Checkmate', 'normal'),
  stalemate('Stalemate', 'normal'),
  insufficientMaterial('Insufficient material', 'normal'),
  fiftyMoveRule('Fifty-move rule', 'normal'),
  threefoldRepetition('Threefold repetition', 'normal'),
  drawAdjudication('Adjudicated draw', 'adjudication'),
  resignAdjudication('Adjudicated win', 'adjudication'),
  maxMoves('Move limit', 'adjudication'),
  timeForfeit('Time forfeit', 'time forfeit'),
  illegalMove('Illegal move', 'rules infraction'),
  engineFailure('Engine failure', 'abandoned'),
  aborted('Aborted', 'unterminated'),
  mutualSitting('Both teams sat', 'adjudication');

  const MatchEnding(this.label, this.termination);

  final String label;

  /// The BPGN `Termination` tag.
  final String termination;
}

/// One played game: every half-move in the order played, board digit first
/// as the engine speaks it — `1e2e4`, `2P@f7` — which is the game; the rest
/// is read off it.
typedef MatchGame = ({
  int number,
  int whiteIndex,
  int blackIndex,
  String whiteName,
  String blackName,
  MatchResult result,
  MatchEnding ending,
  String detail,
  List<String> moves,
  DateTime startedAt,
  int durationMs,
});

Map<String, Object?> gameJson(MatchGame game) => {
  'number': game.number,
  'whiteIndex': game.whiteIndex,
  'blackIndex': game.blackIndex,
  'whiteName': game.whiteName,
  'blackName': game.blackName,
  'result': game.result.name,
  'termination': game.ending.name,
  'detail': game.detail,
  'moves': game.moves,
  'startedAt': game.startedAt.toIso8601String(),
  'durationMs': game.durationMs,
};

MatchGame gameOf(Map<String, Object?> json) => (
  number: _int(json['number']) ?? 1,
  whiteIndex: _int(json['whiteIndex']) ?? 0,
  blackIndex: _int(json['blackIndex']) ?? 1,
  whiteName: json['whiteName'] as String? ?? 'A + B',
  blackName: json['blackName'] as String? ?? 'C + D',
  result:
      MatchResult.values.where((r) => r.name == json['result']).firstOrNull ??
      MatchResult.unfinished,
  ending:
      MatchEnding.values
          .where((e) => e.name == json['termination'])
          .firstOrNull ??
      MatchEnding.aborted,
  detail: json['detail'] as String? ?? '',
  moves: [for (final move in _list(json['moves'])) '$move'],
  startedAt:
      DateTime.tryParse(json['startedAt'] as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0),
  durationMs: _int(json['durationMs']) ?? 0,
);

enum MatchStatus {
  pending('Not started'),
  running('Running'),
  completed('Completed'),
  cancelled('Stopped'),
  failed('Failed');

  const MatchStatus(this.label);

  final String label;
}

/// A match as it lives on disk, in `<id>/match.json`.
final class StoredMatch {
  const StoredMatch({
    required this.id,
    required this.config,
    required this.createdAt,
    required this.status,
    this.games = const [],
    this.finishedAt,
    this.error,
  });

  /// Its folder's name.
  final String id;
  final MatchConfig config;
  final DateTime createdAt;
  final DateTime? finishedAt;
  final MatchStatus status;
  final List<MatchGame> games;
  final String? error;

  /// A stopped or failed match with games still to play.
  bool get resumable =>
      (status == MatchStatus.cancelled || status == MatchStatus.failed) &&
      games.length < config.games;

  StoredMatch copyWith({
    MatchStatus? status,
    List<MatchGame>? games,
    DateTime? finishedAt,
    String? error,
    bool clearError = false,
  }) => StoredMatch(
    id: id,
    config: config,
    createdAt: createdAt,
    status: status ?? this.status,
    games: games ?? this.games,
    finishedAt: finishedAt ?? this.finishedAt,
    error: clearError ? null : error ?? this.error,
  );

  /// How the pair holding White on board 1 did, whoever that was: the
  /// line's score, the number the match is for. With seats swapping, the
  /// teams' own crosstable would cancel the opening out; this does not.
  MatchScore get openingScore {
    var wins = 0, draws = 0, losses = 0, unfinished = 0, byLimit = 0;
    for (final game in games) {
      switch (game.result) {
        case MatchResult.whiteWins:
          wins++;
        case MatchResult.blackWins:
          losses++;
        case MatchResult.draw:
          draws++;
          if (game.ending != MatchEnding.checkmate) byLimit++;
        case MatchResult.unfinished:
          unfinished++;
      }
    }
    return (
      wins: wins,
      draws: draws,
      losses: losses,
      unfinished: unfinished,
      adjudicated: byLimit,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
    'status': status.name,
    if (error != null) 'error': error,
    'config': config.toJson(),
    'games': [for (final game in games) gameJson(game)],
  };

  static StoredMatch fromJson(Map<String, Object?> json) {
    final config = json['config'];
    return StoredMatch(
      id: json['id'] as String? ?? '',
      config: MatchConfig.fromJson(
        config is Map<String, Object?> ? config : const {},
      ),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
      // A run cut off by a crash or a quit is stopped, not still running.
      status: switch (json['status']) {
        'running' || null => MatchStatus.cancelled,
        final name =>
          MatchStatus.values.where((s) => s.name == name).firstOrNull ??
              MatchStatus.cancelled,
      },
      error: json['error'] as String?,
      games: [
        for (final game in _list(json['games']))
          if (game is Map<String, Object?>) gameOf(game),
      ],
    );
  }
}

typedef MatchScore = ({
  int wins,
  int draws,
  int losses,
  int unfinished,
  int adjudicated,
});

extension MatchScoreText on MatchScore {
  int get played => wins + draws + losses;

  double get points => wins + draws / 2;

  /// `5½/10`, the way a match score is written.
  String get text {
    if (played == 0) return 'No games yet';
    final whole = points.floor();
    final half = points - whole >= 0.5;
    final written = half ? (whole == 0 ? '½' : '$whole½') : '$whole';
    return '$written/$played';
  }

  /// A conservative 95% range for the share of the points (Hoeffding): the
  /// games are not independent — self-play repeats itself — so it is wide.
  double? get margin => played == 0
      ? null
      : math.min(1.0, math.sqrt(math.log(40) / (2 * played)));
}

/// [moves] (`1e2e4`, `2P@f7`) replayed from [start] as a line with every move
/// on the boards, as far as they play: a record from another start keeps as
/// much of itself as fits.
TableLine replayGame(TablePosition start, List<String> moves) {
  var line = TableLine(start);
  var position = start;
  for (final token in moves) {
    if (token.length < 3) break;
    final board = token[0] == '2' ? BoardNumber.two : BoardNumber.one;
    final played = lineMove(position, board, token.substring(1));
    if (played == null) break;
    line = line.played(played.move);
    position = played.after;
  }
  return line;
}

/// Who won when [team] had no legal joint action: the other team, as BPGN
/// scores it from the pair holding White on board 1.
MatchResult lossFor(Team team) =>
    team == Team.ab ? MatchResult.blackWins : MatchResult.whiteWins;

/// The whole match as BPGN, the format `tools/bughouse_db/bpgn.py` indexes.
String matchBpgn(StoredMatch match) => [
  for (final game in match.games) '${gameBpgn(match.config, game)}\n',
].join();

/// One game in BPGN. Partners sit on opposite colours, so the team holding
/// White on board 1 is `WhiteA` and `BlackB`. The movetext is in the order
/// played: `1A. e4 1B. d4 1a. e5`, the letter's case the mover's colour.
String gameBpgn(MatchConfig config, MatchGame game) {
  final start = config.start;
  final out = StringBuffer()
    ..writeln('[Event "${_quoted(config.name)}"]')
    ..writeln('[Site "Chess Auto Prep"]')
    ..writeln('[Date "${_date(game.startedAt)}"]')
    ..writeln('[Round "${game.number}"]')
    ..writeln('[WhiteA "${_quoted(game.whiteName)}"]')
    ..writeln('[BlackA "${_quoted(game.blackName)}"]')
    ..writeln('[WhiteB "${_quoted(game.blackName)}"]')
    ..writeln('[BlackB "${_quoted(game.whiteName)}"]')
    ..writeln('[Result "${game.result.token}"]')
    ..writeln('[Termination "${game.ending.termination}"]');
  if (config.openingLabel.isNotEmpty) {
    out.writeln('[Opening "${_quoted(config.openingLabel)}"]');
  }
  if (start != null && start.dualFen != TablePosition.initial.dualFen) {
    // Not a BPGN tag, but a game from a set-up table cannot be replayed
    // without it, and readers pass over tags they do not know.
    out.writeln('[SetUpDualFEN "${start.dualFen}"]');
  }
  out.writeln();
  if (start != null) out.writeln(_movetext(replayGame(start, game.moves)));
  out.writeln(game.result.token);
  return out.toString();
}

String _movetext(TableLine line) {
  final tokens = [
    for (final move in line.moves)
      '${move.number}${_letter(move.board, move.side)}. ${move.san}',
  ];
  final lines = <String>[];
  var current = '';
  for (final token in tokens) {
    if (current.isNotEmpty && current.length + token.length + 1 > 80) {
      lines.add(current);
      current = '';
    }
    current = current.isEmpty ? token : '$current $token';
  }
  if (current.isNotEmpty) lines.add(current);
  return lines.join('\n');
}

String _letter(BoardNumber board, Side side) {
  final letter = board == BoardNumber.one ? 'A' : 'B';
  return side == Side.white ? letter : letter.toLowerCase();
}

String _date(DateTime when) =>
    '${when.year}.${'${when.month}'.padLeft(2, '0')}.'
    '${'${when.day}'.padLeft(2, '0')}';

String _quoted(String value) => value.replaceAll('"', "'");
