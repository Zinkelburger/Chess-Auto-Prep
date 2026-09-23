import 'dart:math' as math;

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/match.dart';
import '../../chess/bughouse/table.dart';
import '../../chess/bughouse/table_line.dart';
import '../../engines/hivemind_engine.dart';

/// Plays a match's games on one Hivemind, which plays both teams.
///
/// Bughouse has no turn: each board has its own side to move, so a team may
/// hold both moves, one or none, and a ply is a joint action over both
/// boards in which sitting is a move. The teams are asked in turn, A + B
/// first, a team with nothing to move skipped. Both halves of an action are
/// checked against the table the engine saw before either is played, so a
/// piece captured on one board never pays for a drop on the other in the
/// same action — the engine did not choose that.
///
/// A game ends when a team on move has no legal joint action (the engine
/// answers `bestmove (none)`: Hivemind's own terminal rule, which lets a
/// checked seat wait for a partner's capture), at the ply limit, after four
/// joint actions in a row that sit on every board, or when the engine fails.
final class MatchRunner {
  MatchRunner({required this.engine, required this.config, required this.now});

  final Hivemind engine;
  final MatchConfig config;
  final DateTime Function() now;
  bool _stopped = false;

  bool get stopped => _stopped;

  /// Cuts the game in flight short; [play] then answers null.
  void stop() {
    _stopped = true;
    engine.stop();
  }

  /// Game [index] (0-based) from [start]; [onMove] hears the moves so far
  /// after each joint action. Null when [stop] cut it short.
  Future<MatchGame?> play(
    int index,
    TablePosition start, {
    void Function(List<String> moves)? onMove,
  }) async {
    final began = now();
    final clock = Stopwatch()..start();
    final (white, black) = config.seatsFor(index);
    final random = math.Random(config.seed + index);
    final moves = <String>[];
    var position = start;
    var team = Team.ab;
    var sits = 0;
    _End? end;
    while (end == null) {
      if (moves.length >= config.maxPlies) {
        end = _atLimit;
        break;
      }
      if (!position.hasMove(team)) {
        team = team.other;
        continue;
      }
      final budget = config.teams[team == Team.ab ? white : black].budget;
      final sampling = moves.length < config.variety.plies;
      final answer = await engine.search((
        position: position,
        team: team,
        maySit: config.clock.maySit(team),
        mustMove: MustMove.either,
        lines: sampling ? config.variety.lines : 1,
        budget: budget.nodes != null
            ? NodeBudget(budget.nodes!)
            : TimeBudget(Duration(milliseconds: budget.movetimeMs ?? 1000)),
      ));
      if (_stopped) return null;
      final step = _step(position, team, answer, sampling, random);
      switch (step) {
        case _Ended(:final ending):
          end = ending;
        case _Played(:final after, :final played):
          position = after;
          moves.addAll(played);
          sits = played.isEmpty ? sits + 1 : 0;
          end = sits >= 4 ? _bothSat : null;
          if (played.isNotEmpty) onMove?.call(List.unmodifiable(moves));
          team = team.other;
      }
    }
    return (
      number: index + 1,
      whiteIndex: white,
      blackIndex: black,
      whiteName: config.teams[white].name,
      blackName: config.teams[black].name,
      result: end.result,
      ending: end.ending,
      detail: end.detail,
      moves: moves,
      startedAt: began,
      durationMs: clock.elapsedMilliseconds,
    );
  }

  _Step _step(
    TablePosition position,
    Team team,
    HivemindAnswer answer,
    bool sampling,
    math.Random random,
  ) {
    switch (answer) {
      case HivemindFailed(:final reason):
        return _Ended((
          result: MatchResult.unfinished,
          ending: MatchEnding.engineFailure,
          detail: reason,
        ));
      case final HivemindSearched searched:
        final action = sampling
            ? pickFromShortlist(searched, config.variety, random)
            : searched.best;
        if (action == null) {
          return _Ended((
            result: lossFor(team),
            ending: MatchEnding.checkmate,
            detail: _whereLost(position, team),
          ));
        }
        return _apply(position, team, action) ??
            _Ended((
              result: MatchResult.unfinished,
              ending: MatchEnding.engineFailure,
              detail: 'Illegal engine action: $action',
            ));
    }
  }

  /// [action] played for [team], each half checked against [position]
  /// first; null when a half is not [team]'s to play or not legal.
  static _Played? _apply(TablePosition position, Team team, JointMove action) {
    for (final board in BoardNumber.values) {
      final uci = action.on(board);
      if (uci == null) continue;
      if (position.mover(board).team != team) return null;
      if (position.play(board, uci) == null) return null;
    }
    var after = position;
    final played = <String>[];
    for (final board in BoardNumber.values) {
      final uci = action.on(board);
      if (uci == null) continue;
      final move = lineMove(after, board, uci)!;
      after = move.after;
      played.add('${board.digit}${move.move.uci}');
    }
    return _Played(after, played);
  }

  /// The board [team] lost on: the one where it is mated, else the table.
  static String _whereLost(TablePosition position, Team team) {
    for (final board in BoardNumber.values) {
      final side = position.board(board);
      if (position.mover(board).team == team &&
          side.isCheck &&
          !side.hasSomeLegalMoves) {
        return board.label.toLowerCase();
      }
    }
    return 'no legal joint action';
  }
}

/// The move to play from a search while games are to differ: the engine's
/// choice or one of its next lines within the window of the best in Q,
/// drawn at random — never a move it did not rank. A proven mate is played,
/// not sampled around.
JointMove? pickFromShortlist(
  HivemindSearched searched,
  MatchVariety variety,
  math.Random random,
) {
  final best = searched.top?.q;
  if (best == null) return searched.best;
  final top = searched.top!;
  final candidates = [
    ?(searched.best ?? top.pv.firstOrNull),
    for (final line in searched.lines.skip(1).take(variety.lines - 1))
      if (line.q case final q? when best - q <= variety.window)
        ?line.pv.firstOrNull,
  ];
  if (candidates.isEmpty) return searched.best;
  return candidates[random.nextInt(candidates.length)];
}

typedef _End = ({MatchResult result, MatchEnding ending, String detail});

const _End _atLimit = (
  result: MatchResult.draw,
  ending: MatchEnding.maxMoves,
  detail: '',
);
const _End _bothSat = (
  result: MatchResult.draw,
  ending: MatchEnding.mutualSitting,
  detail: '',
);

sealed class _Step {
  const _Step();
}

final class _Played extends _Step {
  const _Played(this.after, this.played);

  final TablePosition after;

  /// The half-moves played, board digit first; empty for a sit.
  final List<String> played;
}

final class _Ended extends _Step {
  const _Ended(this.ending);

  final _End ending;
}
