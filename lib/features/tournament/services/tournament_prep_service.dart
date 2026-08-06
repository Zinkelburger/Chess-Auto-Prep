/// Turn an entry list into a study plan.
///
/// The point of this layer is arithmetic, not analysis. Forty per-opponent
/// clash reports are unusable: nobody studies forty people the night before a
/// tournament. But positions repeat across a field, and each one can be scored
/// by how likely it is to actually appear on your board:
///
///     score(position) = Σ over opponents  P(pair) × P(reach) × P(they play it)
///
/// Ranking by that collapses the field into the handful of lines worth
/// knowing, and tells you which opponents each line buys you.
library;

import 'dart:io' as io;

import 'package:flutter/foundation.dart';

import '../../../models/opening_tree.dart';
import '../../../services/opening_tree_builder.dart';
import '../../../services/pgn_parsing_service.dart' as pgn;
import '../models/opponent_probability.dart';
import '../models/roster_entry.dart';
import 'clash_service.dart';
import 'event_simulator.dart';

/// One opponent's stake in a prep position.
class PrepOpponentRef {
  final String playerId;
  final String playerName;

  /// P(face this opponent at all, with the relevant color).
  final double pairingProb;

  /// How often they play the uncovered move here.
  final double moveShare;

  /// P(reach this position along our repertoire).
  final double reachProbability;

  const PrepOpponentRef({
    required this.playerId,
    required this.playerName,
    required this.pairingProb,
    required this.moveShare,
    required this.reachProbability,
  });

  /// This opponent's contribution to the position's total score.
  double get contribution => pairingProb * reachProbability * moveShare;

  Map<String, dynamic> toMap() => {
    'player_id': playerId,
    'player_name': playerName,
    'pairing_prob': pairingProb,
    'move_share': moveShare,
    'reach_probability': reachProbability,
    'contribution': contribution,
  };
}

/// A position worth preparing, pooled across everyone who can steer into it.
class PrepPosition {
  final String fen;
  final List<String> movePath;
  final String missingMove;

  /// Which of our repertoires this gap is in.
  final bool weAreWhite;

  /// Whether the move transposes back into covered territory.
  final bool transposes;

  /// Opponents who reach it, ranked by contribution.
  final List<PrepOpponentRef> opponents;

  const PrepPosition({
    required this.fen,
    required this.movePath,
    required this.missingMove,
    required this.weAreWhite,
    required this.transposes,
    required this.opponents,
  });

  /// Σ of every opponent's contribution — the ranking key.
  double get score => opponents.fold<double>(0, (s, o) => s + o.contribution);

  /// How many entrants this one line covers.
  int get opponentCount => opponents.length;

  String get line => movePath.isEmpty ? '(start)' : movePath.join(' ');

  /// The line including the move we have no answer to.
  String get lineWithMove =>
      movePath.isEmpty ? missingMove : '${movePath.join(' ')} $missingMove';

  Map<String, dynamic> toMap() => {
    'line': line,
    'line_with_move': lineWithMove,
    'move_path': movePath,
    'fen': fen,
    'missing_move': missingMove,
    'we_are_white': weAreWhite,
    'transposes': transposes,
    'score': score,
    'opponent_count': opponentCount,
    'opponents': opponents.map((o) => o.toMap()).toList(),
  };
}

/// The full prep plan for an event.
class TournamentPrepReport {
  final String eventName;

  /// Positions ranked by [PrepPosition.score], descending.
  final List<PrepPosition> positions;

  /// Per-opponent detail, for drilling into one person.
  final List<ClashReport> clashReports;

  final SimulationResult simulation;
  final List<String> warnings;
  final Duration elapsed;

  const TournamentPrepReport({
    required this.eventName,
    required this.positions,
    required this.clashReports,
    required this.simulation,
    required this.elapsed,
    this.warnings = const [],
  });

  /// The smallest set of lines covering [coverage] of the total score mass —
  /// "learn these N and you have handled 80% of what you'll actually face".
  List<PrepPosition> topByCoverage(double coverage) {
    final total = positions.fold<double>(0, (s, p) => s + p.score);
    if (total <= 0) return const [];
    final target = total * coverage;
    final out = <PrepPosition>[];
    var acc = 0.0;
    for (final p in positions) {
      out.add(p);
      acc += p.score;
      if (acc >= target) break;
    }
    return out;
  }

  Map<String, dynamic> toMap() => {
    'event_name': eventName,
    'elapsed_ms': elapsed.inMilliseconds,
    'positions': positions.map((p) => p.toMap()).toList(),
    'clash_reports': clashReports.map((c) => c.toMap()).toList(),
    'simulation': simulation.toMap(),
    if (warnings.isNotEmpty) 'warnings': warnings,
  };
}

/// Progress across a whole-tournament run.
class PrepProgress {
  final int opponentsDone;
  final int opponentsTotal;
  final String currentPlayer;
  final String detail;

  const PrepProgress({
    required this.opponentsDone,
    required this.opponentsTotal,
    required this.currentPlayer,
    this.detail = '',
  });

  double get fraction =>
      opponentsTotal == 0 ? 0 : opponentsDone / opponentsTotal;
}

class TournamentPrepService {
  final ClashService _clash;

  TournamentPrepService({ClashService? clash})
    : _clash = clash ?? ClashService();

  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _clash.cancel();
  }

  /// Build an [OpeningTree] from repertoire PGN files.
  ///
  /// A repertoire PGN is theory written from our side, so every game in it
  /// counts regardless of headers — hence no username filter.
  static Future<OpeningTree> buildRepertoireTree({
    required List<String> pgnPaths,
    required bool isWhite,
  }) async {
    final games = <String>[];
    for (final path in pgnPaths) {
      try {
        games.addAll(pgn.splitPgnIntoGames(await io.File(path).readAsString()));
      } catch (e) {
        if (kDebugMode) debugPrint('[Prep] unreadable repertoire $path: $e');
      }
    }
    return OpeningTreeBuilder.buildTree(
      pgnList: games,
      username: '',
      userIsWhite: isWhite,
      strictPlayerMatching: false,
      maxDepth: 40,
    );
  }

  /// Run clash for every plausible opponent and pool the results.
  ///
  /// Opponents below [minPairingProb] are skipped outright — clashing someone
  /// you have a 1% chance of meeting costs a full game download for nothing.
  Future<TournamentPrepReport> prepareEvent({
    required Roster roster,
    required OpeningTree? whiteRepertoire,
    required OpeningTree? blackRepertoire,
    ClashConfig clashConfig = const ClashConfig(),
    SimulationConfig simConfig = const SimulationConfig(),
    double minPairingProb = 0.05,
    int? maxOpponents,
    void Function(PrepProgress)? onProgress,
  }) async {
    _cancelled = false;
    final stopwatch = Stopwatch()..start();
    final warnings = <String>[];

    final simulation = EventSimulator.run(roster, config: simConfig);
    warnings.addAll(simulation.notes);

    if (whiteRepertoire == null && blackRepertoire == null) {
      warnings.add('No repertoire supplied — there is nothing to clash.');
      return TournamentPrepReport(
        eventName: roster.eventName,
        positions: const [],
        clashReports: const [],
        simulation: simulation,
        elapsed: stopwatch.elapsed,
        warnings: warnings,
      );
    }

    final byId = {for (final e in roster.entries) e.id: e};

    var candidates = simulation.opponents
        .where((o) => o.probAny >= minPairingProb)
        .toList();

    if (maxOpponents != null && candidates.length > maxOpponents) {
      warnings.add(
        'Limited to the ${maxOpponents} most likely opponents; '
        '${candidates.length - maxOpponents} lower-probability entrants were '
        'not clashed.',
      );
      candidates = candidates.take(maxOpponents).toList();
    }

    final reports = <ClashReport>[];
    final positions = <String, _PositionAccumulator>{};

    for (var i = 0; i < candidates.length; i++) {
      if (_cancelled) {
        warnings.add('Cancelled after ${reports.length} opponents.');
        break;
      }

      final prob = candidates[i];
      final entry = byId[prob.playerId];
      if (entry == null) continue;

      onProgress?.call(
        PrepProgress(
          opponentsDone: i,
          opponentsTotal: candidates.length,
          currentPlayer: entry.name,
        ),
      );

      if (!(entry.identity?.hasAccount ?? false)) {
        warnings.add(
          '${entry.name}: no online account resolved '
          '(${(prob.probAny * 100).toStringAsFixed(0)}% chance you face them).',
        );
        continue;
      }

      // Prep each color separately, and only when that color is actually
      // reachable — no point clashing our White book against someone we will
      // certainly meet with Black.
      for (final weAreWhite in const [true, false]) {
        final colorProb = weAreWhite ? prob.probAsWhite : prob.probAsBlack;
        if (colorProb < minPairingProb) continue;

        final tree = weAreWhite ? whiteRepertoire : blackRepertoire;
        if (tree == null) continue;

        final report = await _clash.run(
          opponent: entry,
          repertoire: tree,
          weAreWhite: weAreWhite,
          config: clashConfig,
          onProgress: (p) => onProgress?.call(
            PrepProgress(
              opponentsDone: i,
              opponentsTotal: candidates.length,
              currentPlayer: entry.name,
              detail: p.detail,
            ),
          ),
        );
        reports.add(report);
        warnings.addAll(report.warnings.map((w) => '${entry.name}: $w'));

        for (final gap in report.gaps) {
          // Pool on the position and the move, not the move order — two paths
          // into the same FEN are one thing to study.
          final key = '${gap.fen}|${gap.missingMove}|$weAreWhite';
          positions
              .putIfAbsent(
                key,
                () => _PositionAccumulator(
                  fen: gap.fen,
                  movePath: gap.movePath,
                  missingMove: gap.missingMove,
                  weAreWhite: weAreWhite,
                  transposes: gap.transposes,
                ),
              )
              .refs
              .add(
                PrepOpponentRef(
                  playerId: entry.id,
                  playerName: entry.name,
                  pairingProb: colorProb,
                  moveShare: gap.moveShare,
                  reachProbability: gap.reachProbability,
                ),
              );
        }
      }
    }

    final ranked = positions.values.map((a) {
      final refs = [...a.refs]
        ..sort((x, y) => y.contribution.compareTo(x.contribution));
      return PrepPosition(
        fen: a.fen,
        movePath: a.movePath,
        missingMove: a.missingMove,
        weAreWhite: a.weAreWhite,
        transposes: a.transposes,
        opponents: refs,
      );
    }).toList()..sort((a, b) => b.score.compareTo(a.score));

    onProgress?.call(
      PrepProgress(
        opponentsDone: candidates.length,
        opponentsTotal: candidates.length,
        currentPlayer: '',
        detail: 'Done',
      ),
    );

    return TournamentPrepReport(
      eventName: roster.eventName,
      positions: ranked,
      clashReports: reports,
      simulation: simulation,
      elapsed: stopwatch.elapsed,
      warnings: warnings,
    );
  }
}

class _PositionAccumulator {
  final String fen;
  final List<String> movePath;
  final String missingMove;
  final bool weAreWhite;
  final bool transposes;
  final List<PrepOpponentRef> refs = [];

  _PositionAccumulator({
    required this.fen,
    required this.movePath,
    required this.missingMove,
    required this.weAreWhite,
    required this.transposes,
  });
}
