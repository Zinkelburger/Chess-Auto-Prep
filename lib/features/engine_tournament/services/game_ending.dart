import 'package:dartchess/dartchess.dart' show Side;

import '../../../models/game_outcome.dart';

/// How a game stopped: the score, the rule that stopped it, and any free
/// text the rule alone cannot carry ("Alpha played e2e5 in …").
class GameEnding {
  const GameEnding(this.result, this.termination, [this.detail = '']);

  /// The side to move loses — checkmate, a forfeit, an illegal move.
  GameEnding.lossFor(Side sideToMove, this.termination, [this.detail = ''])
    : result = sideToMove == Side.white
          ? GameResult.blackWins
          : GameResult.whiteWins;

  final GameResult result;
  final TerminationReason termination;
  final String detail;
}
