/// Calls a game on the engines' own scores, cutechess-style.
library;

import 'package:dartchess/dartchess.dart' show Side;

import '../../../models/game_outcome.dart';
import '../models/adjudication_rules.dart';
import 'game_ending.dart';

/// Tracks the score streaks that [AdjudicationRules] are defined over.
///
/// Fed once per move with the mover's own view of the position, in the
/// centipawn axis `EngineSearch.comparableCp` collapses mates onto. The draw
/// streak is counted in plies across both sides; the resign streaks per
/// side, so a two-sided rule can demand that the winner agree.
class ScoreAdjudicator {
  ScoreAdjudicator(this.rules);

  final AdjudicationRules rules;

  int _drawStreakPlies = 0;
  final Map<Side, int> _losingStreak = {Side.white: 0, Side.black: 0};
  final Map<Side, int> _winningStreak = {Side.white: 0, Side.black: 0};

  /// Record the move [mover] just made and say whether the game is over.
  ///
  /// [scoreCp] is the mover's comparable score after the move, or null when
  /// the engine reported none; a null score breaks every streak. A draw is
  /// checked before a resignation, so a dead-level game that somehow also
  /// meets the resign rule is filed as the draw it is.
  GameEnding? observe({
    required Side mover,
    required String moverName,
    required int? scoreCp,
    required bool resetsDrawCounter,
    required int fullmoves,
  }) {
    if (rules.drawEnabled) {
      final ending = _observeDraw(
        scoreCp: scoreCp,
        resetsDrawCounter: resetsDrawCounter,
        fullmoves: fullmoves,
      );
      if (ending != null) return ending;
    }
    if (rules.resignEnabled) {
      return _observeResign(mover, moverName, scoreCp);
    }
    return null;
  }

  GameEnding? _observeDraw({
    required int? scoreCp,
    required bool resetsDrawCounter,
    required int fullmoves,
  }) {
    if (resetsDrawCounter ||
        scoreCp == null ||
        scoreCp.abs() > rules.drawScoreCp) {
      _drawStreakPlies = 0;
    } else {
      _drawStreakPlies++;
    }
    if (fullmoves >= rules.drawMoveNumber &&
        _drawStreakPlies >= rules.drawMoveCount * 2) {
      return GameEnding(
        GameResult.draw,
        TerminationReason.drawAdjudication,
        'both engines under ${rules.drawScoreCp}cp for '
        '${rules.drawMoveCount} moves',
      );
    }
    return null;
  }

  GameEnding? _observeResign(Side mover, String moverName, int? scoreCp) {
    _losingStreak[mover] = scoreCp != null && scoreCp <= -rules.resignScoreCp
        ? _losingStreak[mover]! + 1
        : 0;
    _winningStreak[mover] = scoreCp != null && scoreCp >= rules.resignScoreCp
        ? _winningStreak[mover]! + 1
        : 0;
    final loserAgrees = _losingStreak[mover]! >= rules.resignMoveCount;
    final winnerAgrees =
        !rules.twoSidedResign ||
        _winningStreak[mover.opposite]! >= rules.resignMoveCount;
    if (loserAgrees && winnerAgrees) {
      return GameEnding.lossFor(
        mover,
        TerminationReason.resignAdjudication,
        '$moverName below -${rules.resignScoreCp}cp for '
        '${rules.resignMoveCount} moves',
      );
    }
    return null;
  }
}
