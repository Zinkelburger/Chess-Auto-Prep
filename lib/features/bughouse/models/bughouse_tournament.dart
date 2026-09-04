/// A bughouse match: Hivemind against Hivemind, over and over, from one
/// opening.
///
/// The engine tournament next door puts two *binaries* in a position and asks
/// which is stronger. This asks a different question with the same machinery,
/// because there is only one bughouse engine to run: **what happens after this
/// line?** You give it four plies of theory, it plays the rest out a dozen
/// times, and the score of the pair holding White on board 1 is the answer.
///
/// Three things follow from that, and they are what this file is:
///
///   * **A participant is a team, not a player.** Bughouse seats four people;
///     two of them are partners. A participant here is the pair `A + C` or
///     `B + D`, and [GameResult.whiteWins] means the pair holding White on
///     board 1 won — which is also how BPGN reads a `1-0`, so a game exported
///     from here and one downloaded from FICS score the same way.
///   * **Two identical participants are the normal case.** Self-play from a
///     fixed opening is the standard way to ask whether a line is any good.
///     Giving the two teams different budgets asks the other question — does
///     the line survive against someone thinking three times as long.
///   * **Without variety every game is the same game.** Hivemind's search is
///     not bit-exact — four workers race on batching, so the node count
///     wobbles a percent either way — but at the budgets a match uses that
///     never reaches the move: measured over six runs at 800 nodes and twelve
///     at 800 ms, the answer was identical every time. So a match of ten games
///     would be one game shown ten times. [BughouseVariety] is what stops
///     that, and it samples from the engine's *own* shortlist rather than from
///     the legal moves, so every game stays a game the engine would defend.
library;

import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';

import '../../../models/crosstable.dart';
import '../../../models/game_outcome.dart';
import 'bughouse_state.dart';

/// How hard one team thinks about each joint action.
///
/// Two ways to say it. Nodes are the steadier of the two: the same search
/// twice gave the same move in every run measured, so a seeded match usually
/// replays. *Usually*, not always — the search is not bit-exact, and a game is
/// a chain of a hundred searches, so one flip anywhere diverges the rest of
/// it. Do not promise a reproduction; expect one.
///
/// Wall-clock time is what a player actually has, and it varies with what else
/// the machine is doing. That jitter is not a source of variety worth having:
/// it only changes the move at budgets too short to have settled — around
/// 300 ms, where the answers it produces are an under-searched engine rather
/// than considered alternatives. [BughouseVariety] is the honest version.
class BughouseBudget {
  const BughouseBudget.nodes(int value) : nodes = value, movetimeMs = null;
  const BughouseBudget.movetime(int value) : movetimeMs = value, nodes = null;

  final int? nodes;
  final int? movetimeMs;

  bool get isNodes => nodes != null;

  /// The engine's default when neither is set — never, here, but the search
  /// call takes nullables.
  Duration? get movetime =>
      movetimeMs == null ? null : Duration(milliseconds: movetimeMs!);

  String get label =>
      nodes != null ? '$nodes nodes' : '${(movetimeMs! / 1000)}s per move';

  static const List<int> nodeChoices = [200, 400, 800, 1600, 3200, 6400];
  static const List<int> movetimeChoices = [500, 1000, 2000, 5000, 10000];

  Map<String, dynamic> toJson() => {
    if (nodes != null) 'nodes': nodes,
    if (movetimeMs != null) 'movetimeMs': movetimeMs,
  };

  factory BughouseBudget.fromJson(Map<String, dynamic> json) {
    final nodes = (json['nodes'] as num?)?.toInt();
    if (nodes != null) return BughouseBudget.nodes(nodes);
    return BughouseBudget.movetime(
      (json['movetimeMs'] as num?)?.toInt() ?? 1000,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BughouseBudget &&
      other.nodes == nodes &&
      other.movetimeMs == movetimeMs;

  @override
  int get hashCode => Object.hash(nodes, movetimeMs);
}

/// One team in the match: a name and how hard it thinks.
///
/// There is nothing else to vary, because there is one engine and one network.
/// `Hash` and `BatchSize` are properties of the *process*, not of a seat — the
/// two teams share one Hivemind — so they belong to the tournament, not here.
class BughouseParticipant {
  const BughouseParticipant({
    required this.name,
    this.budget = const BughouseBudget.nodes(800),
  });

  final String name;
  final BughouseBudget budget;

  BughouseParticipant copyWith({String? name, BughouseBudget? budget}) =>
      BughouseParticipant(
        name: name ?? this.name,
        budget: budget ?? this.budget,
      );

  Map<String, dynamic> toJson() => {'name': name, 'budget': budget.toJson()};

  factory BughouseParticipant.fromJson(Map<String, dynamic> json) =>
      BughouseParticipant(
        name: json['name'] as String? ?? 'Hivemind',
        budget: json['budget'] == null
            ? const BughouseBudget.nodes(800)
            : BughouseBudget.fromJson(
                Map<String, dynamic>.from(json['budget'] as Map),
              ),
      );
}

/// How much the games are allowed to differ from each other.
///
/// Left alone, a ten-game match is one game played ten times — the search
/// wobbles, but not by enough to change its answer at any budget worth
/// playing at. This is the fix, and its shape matters: for the first
/// [plies] joint actions a team plays a move drawn from the engine's own
/// MultiPV shortlist rather than the top one, restricted to lines within
/// [window] of the best in the engine's *value* — `q`, not the raw score,
/// because the raw score's tangent is far steeper away from zero than at it.
///
/// So the games diverge early and then converge on real play, and every
/// divergence is a move the engine ranked. That is what makes the output
/// theory rather than noise: `0.05` of q is about a five-percentage-point
/// swing in expected score, which is the width of a genuine choice.
class BughouseVariety {
  const BughouseVariety({this.plies = 8, this.window = 0.05, this.lines = 3});

  /// Off: every game is the engine's single best line, so the match plays one
  /// game N times. Occasionally what you want — a reference game — which is
  /// why it is a value rather than a nullable.
  static const BughouseVariety none = BughouseVariety(
    plies: 0,
    window: 0,
    lines: 1,
  );

  /// How many joint actions from the start of the playout are sampled.
  final int plies;

  /// How far below the best line, in the engine's own value, a line may be and
  /// still be picked.
  final double window;

  /// `MultiPV` for the sampled plies — how many candidates the engine reports.
  final int lines;

  bool get isOn => plies > 0 && lines > 1 && window > 0;

  static const List<int> plyChoices = [0, 4, 8, 12, 20];
  static const List<double> windowChoices = [0.02, 0.05, 0.1, 0.2];
  static const List<int> lineChoices = [2, 3, 4, 5];

  BughouseVariety copyWith({int? plies, double? window, int? lines}) =>
      BughouseVariety(
        plies: plies ?? this.plies,
        window: window ?? this.window,
        lines: lines ?? this.lines,
      );

  Map<String, dynamic> toJson() => {
    'plies': plies,
    'window': window,
    'lines': lines,
  };

  factory BughouseVariety.fromJson(Map<String, dynamic> json) =>
      BughouseVariety(
        plies: (json['plies'] as num?)?.toInt() ?? 8,
        window: (json['window'] as num?)?.toDouble() ?? 0.05,
        lines: (json['lines'] as num?)?.toInt() ?? 3,
      );
}

/// Everything needed to reproduce a match, snapshotted when it starts.
class BughouseTournamentConfig {
  BughouseTournamentConfig({
    required this.name,
    required this.startDualFen,
    this.openingLabel = '',
    this.participants = const [
      BughouseParticipant(name: 'Hivemind A'),
      BughouseParticipant(name: 'Hivemind B'),
    ],
    this.games = 10,
    this.alternateSeats = true,
    this.timeStance = BughouseTimeStance.level,
    this.maxPlies = 240,
    this.hashMb = 256,
    this.batchSize = 8,
    this.variety = const BughouseVariety(),
    int? seed,
  }) : seed = seed ?? DateTime.now().millisecondsSinceEpoch & 0x7fffffff;

  final String name;

  /// The two-board position every game starts from, `<fenA>|<fenB>`.
  final String startDualFen;

  /// The line that produced it, as the movetext panel prints it — kept for the
  /// BPGN `Opening` tag and for the row in the history list. Free text.
  final String openingLabel;

  /// The two teams, in seeding order. Team 0 holds White on board 1 in the
  /// first game.
  final List<BughouseParticipant> participants;

  final int games;

  /// Swap which participant holds White on board 1 every other game, so an
  /// even number of games gives each the same number of Whites.
  ///
  /// Turn it **off** to ask the opening question instead of the engine
  /// question: with the seats fixed, every game's `1-0` is a win for the same
  /// side of the line.
  final bool alternateSeats;

  /// Where the teams stand on the diagonal clock, for the whole match.
  ///
  /// Fixed rather than simulated, and that is a real limitation worth knowing:
  /// a played-out bughouse game has four clocks running in real time, and this
  /// model has teams taking turns. Under turn-taking every team spends the
  /// same time per action, so a simulated diagonal would never move — which
  /// would be [BughouseTimeStance.level] dressed up as arithmetic. Setting it
  /// explicitly is the honest version: it is the one bit the engine reads, and
  /// it decides whether sitting is legal.
  final BughouseTimeStance timeStance;

  /// Ply ceiling, filed as a draw. Counted in half-moves across both boards.
  final int maxPlies;

  /// Process-wide engine knobs. One Hivemind plays both teams, so these are
  /// the match's, not a participant's.
  final int hashMb;
  final int batchSize;

  final BughouseVariety variety;

  /// What makes a match repeatable: the sampler's seed. With fixed-node
  /// budgets, re-running the same config reproduces the same games exactly.
  final int seed;

  static const List<int> gameChoices = [2, 4, 6, 10, 20, 50];
  static const List<int> maxPlyChoices = [80, 160, 240, 400];

  List<String> get participantNames => [for (final p in participants) p.name];

  /// The starting position, or null when the stored FEN will not parse.
  BughouseState? get startState =>
      BughouseState.tryParseDualFen(startDualFen, timeStance: timeStance);

  BughouseTournamentConfig copyWith({
    String? name,
    String? startDualFen,
    String? openingLabel,
    List<BughouseParticipant>? participants,
    int? games,
    bool? alternateSeats,
    BughouseTimeStance? timeStance,
    int? maxPlies,
    int? hashMb,
    int? batchSize,
    BughouseVariety? variety,
    int? seed,
  }) => BughouseTournamentConfig(
    name: name ?? this.name,
    startDualFen: startDualFen ?? this.startDualFen,
    openingLabel: openingLabel ?? this.openingLabel,
    participants: participants ?? this.participants,
    games: games ?? this.games,
    alternateSeats: alternateSeats ?? this.alternateSeats,
    timeStance: timeStance ?? this.timeStance,
    maxPlies: maxPlies ?? this.maxPlies,
    hashMb: hashMb ?? this.hashMb,
    batchSize: batchSize ?? this.batchSize,
    variety: variety ?? this.variety,
    seed: seed ?? this.seed,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'startDualFen': startDualFen,
    'openingLabel': openingLabel,
    'participants': [for (final p in participants) p.toJson()],
    'games': games,
    'alternateSeats': alternateSeats,
    'timeStance': timeStance.name,
    'maxPlies': maxPlies,
    'hashMb': hashMb,
    'batchSize': batchSize,
    'variety': variety.toJson(),
    'seed': seed,
  };

  factory BughouseTournamentConfig.fromJson(Map<String, dynamic> json) =>
      BughouseTournamentConfig(
        name: json['name'] as String? ?? 'Bughouse match',
        startDualFen: json['startDualFen'] as String? ?? '',
        openingLabel: json['openingLabel'] as String? ?? '',
        participants:
            (json['participants'] as List?)
                ?.map(
                  (p) => BughouseParticipant.fromJson(
                    Map<String, dynamic>.from(p as Map),
                  ),
                )
                .toList() ??
            const [
              BughouseParticipant(name: 'Hivemind A'),
              BughouseParticipant(name: 'Hivemind B'),
            ],
        games: (json['games'] as num?)?.toInt() ?? 10,
        alternateSeats: json['alternateSeats'] as bool? ?? true,
        timeStance: BughouseTimeStance.values.firstWhere(
          (s) => s.name == json['timeStance'],
          orElse: () => BughouseTimeStance.level,
        ),
        maxPlies: (json['maxPlies'] as num?)?.toInt() ?? 240,
        hashMb: (json['hashMb'] as num?)?.toInt() ?? 256,
        batchSize: (json['batchSize'] as num?)?.toInt() ?? 8,
        variety: json['variety'] == null
            ? const BughouseVariety()
            : BughouseVariety.fromJson(
                Map<String, dynamic>.from(json['variety'] as Map),
              ),
        seed: (json['seed'] as num?)?.toInt(),
      );
}

/// One played game.
///
/// Unlike the engine tournament's record this carries its own movetext, in the
/// two forms a bughouse game has: the interleaved BPGN half-moves that replay
/// it faithfully, and the two per-board lines a reader looks at. There is no
/// separate collection file to index into, because there is no viewer that
/// opens one — a game is replayed on the lab's own two boards.
class BughouseGameRecord implements CrosstableGame {
  const BughouseGameRecord({
    required this.number,
    required this.whiteIndex,
    required this.blackIndex,
    required this.whiteName,
    required this.blackName,
    required this.result,
    required this.termination,
    required this.moves,
    required this.startedAt,
    required this.durationMs,
    this.detail = '',
  });

  /// 1-based, and its position in `games.bpgn`.
  final int number;

  /// The participant holding White on board 1, and the one holding Black.
  @override
  final int whiteIndex;
  @override
  final int blackIndex;

  final String whiteName;
  final String blackName;

  @override
  final GameResult result;
  final TerminationReason termination;

  /// Which board it ended on, and how — "board 2" for a mate over there.
  final String detail;

  /// Every half-move in the order it was played, board-prefixed the way the
  /// engine speaks: `1e2e4`, `2P@f7`. This is the game; everything else about
  /// it is derived by replaying these from the config's start position.
  final List<String> moves;

  final DateTime startedAt;
  final int durationMs;

  int get plies => moves.length;

  String get outcomeLabel =>
      detail.isEmpty ? termination.label : '${termination.label} — $detail';

  /// The round a crosstable prints. One game per round: there is one pairing,
  /// so the game number and the round are the same thing.
  int get round => number;

  Map<String, dynamic> toJson() => {
    'number': number,
    'whiteIndex': whiteIndex,
    'blackIndex': blackIndex,
    'whiteName': whiteName,
    'blackName': blackName,
    'result': result.name,
    'termination': termination.name,
    'detail': detail,
    'moves': moves,
    'startedAt': startedAt.toIso8601String(),
    'durationMs': durationMs,
  };

  factory BughouseGameRecord.fromJson(Map<String, dynamic> json) =>
      BughouseGameRecord(
        number: (json['number'] as num?)?.toInt() ?? 1,
        whiteIndex: (json['whiteIndex'] as num?)?.toInt() ?? 0,
        blackIndex: (json['blackIndex'] as num?)?.toInt() ?? 1,
        whiteName: json['whiteName'] as String? ?? 'A + C',
        blackName: json['blackName'] as String? ?? 'B + D',
        result: GameResult.values.firstWhere(
          (r) => r.name == json['result'],
          orElse: () => GameResult.unfinished,
        ),
        termination: TerminationReason.values.firstWhere(
          (t) => t.name == json['termination'],
          orElse: () => TerminationReason.aborted,
        ),
        detail: json['detail'] as String? ?? '',
        moves: [for (final m in (json['moves'] as List? ?? const [])) '$m'],
        startedAt:
            DateTime.tryParse(json['startedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      );
}

enum BughouseTournamentStatus { pending, running, completed, cancelled, failed }

extension BughouseTournamentStatusLabel on BughouseTournamentStatus {
  String get label => switch (this) {
    BughouseTournamentStatus.pending => 'Not started',
    BughouseTournamentStatus.running => 'Running',
    BughouseTournamentStatus.completed => 'Completed',
    BughouseTournamentStatus.cancelled => 'Stopped',
    BughouseTournamentStatus.failed => 'Failed',
  };

  bool get isTerminal => switch (this) {
    BughouseTournamentStatus.completed ||
    BughouseTournamentStatus.cancelled ||
    BughouseTournamentStatus.failed => true,
    _ => false,
  };
}

/// A match as it lives on disk.
class StoredBughouseTournament {
  const StoredBughouseTournament({
    required this.id,
    required this.directoryPath,
    required this.config,
    required this.createdAt,
    required this.status,
    this.games = const [],
    this.finishedAt,
    this.error,
  });

  /// Directory name under the matches root.
  final String id;
  final String directoryPath;

  final BughouseTournamentConfig config;
  final DateTime createdAt;
  final DateTime? finishedAt;
  final BughouseTournamentStatus status;
  final List<BughouseGameRecord> games;
  final String? error;

  int get gamesPlayed => games.length;
  double get progress =>
      config.games == 0 ? 0 : (gamesPlayed / config.games).clamp(0, 1);

  /// The score of the side of the *line* rather than of an engine: how the
  /// pair holding White on board 1 did, across every game.
  ///
  /// This is the number the whole feature exists to produce, and it is not the
  /// crosstable's. With [BughouseTournamentConfig.alternateSeats] on, the two
  /// participants swap seats and the crosstable measures which engine is
  /// stronger — the opening's own bias cancels out of it exactly. This does
  /// not cancel: every game contributes from White-on-board-1's side.
  ({double points, int played, int wins, int draws, int losses})
  get openingScore {
    var points = 0.0;
    var wins = 0, draws = 0, losses = 0;
    for (final game in games) {
      switch (game.result) {
        case GameResult.whiteWins:
          points += 1;
          wins++;
        case GameResult.blackWins:
          losses++;
        case GameResult.draw:
        case GameResult.unfinished:
          points += 0.5;
          draws++;
      }
    }
    return (
      points: points,
      played: games.length,
      wins: wins,
      draws: draws,
      losses: losses,
    );
  }

  /// `5½/10 for White on board 1` — the headline, written the way a match
  /// score is always written.
  String get openingScoreLabel {
    final score = openingScore;
    if (score.played == 0) return 'No games yet';
    final whole = score.points.floor();
    final half = score.points - whole >= 0.5;
    final points = half ? '$whole½' : '$whole';
    return '$points/${score.played}';
  }

  /// A rough read on whether that score means anything yet.
  ///
  /// The same two-sided interval the crosstable puts on its Elo, expressed as
  /// a score fraction, because "5½/10" invites a conclusion that ten games
  /// cannot support. Null before any game.
  double? get openingScoreMargin {
    final score = openingScore;
    if (score.played == 0) return null;
    final fraction = score.points / score.played;
    final variance =
        score.wins * math.pow(1 - fraction, 2) +
        score.losses * math.pow(0 - fraction, 2) +
        score.draws * math.pow(0.5 - fraction, 2);
    return 1.959963985 *
        math.sqrt(variance / score.played) /
        math.sqrt(score.played);
  }

  StoredBughouseTournament copyWith({
    BughouseTournamentStatus? status,
    List<BughouseGameRecord>? games,
    DateTime? finishedAt,
    Object? error = _unset,
    BughouseTournamentConfig? config,
  }) => StoredBughouseTournament(
    id: id,
    directoryPath: directoryPath,
    config: config ?? this.config,
    createdAt: createdAt,
    status: status ?? this.status,
    games: games ?? this.games,
    finishedAt: finishedAt ?? this.finishedAt,
    error: error == _unset ? this.error : error as String?,
  );

  static const Object _unset = Object();

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
    'status': status.name,
    if (error != null) 'error': error,
    'config': config.toJson(),
    'games': [for (final g in games) g.toJson()],
  };

  factory StoredBughouseTournament.fromJson(
    Map<String, dynamic> json, {
    required String directoryPath,
  }) => StoredBughouseTournament(
    id: json['id'] as String? ?? '',
    directoryPath: directoryPath,
    config: BughouseTournamentConfig.fromJson(
      Map<String, dynamic>.from(json['config'] as Map? ?? const {}),
    ),
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
    status: BughouseTournamentStatus.values.firstWhere(
      (s) => s.name == json['status'],
      // A run interrupted by a crash or a quit is stale, not still running.
      orElse: () => BughouseTournamentStatus.cancelled,
    ),
    error: json['error'] as String?,
    games:
        (json['games'] as List?)
            ?.map(
              (g) => BughouseGameRecord.fromJson(
                Map<String, dynamic>.from(g as Map),
              ),
            )
            .toList() ??
        const [],
  );
}

/// Who won, given which board was mated.
///
/// Kept here rather than in the runner because it is the one rule that ties a
/// bughouse board to a *team*, and it is easy to get backwards: a team is
/// named by the colour it holds on board 1, and it holds the opposite colour
/// on board 2. So a mate on board 2 is a loss for the team whose board-1
/// colour is the opposite of the mated side's.
GameResult resultOfMate({required BughouseBoard board, required Side mated}) {
  final losingTeam = board == BughouseBoard.a ? mated : mated.opposite;
  return losingTeam == Side.white ? GameResult.blackWins : GameResult.whiteWins;
}
