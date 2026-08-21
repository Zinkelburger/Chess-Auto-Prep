/// Move-notation and display-card construction for the repertoire trainer.
///
/// Extracted from `TrainingSessionController`, where these lived as the
/// `_MoveDisplayMixin` part-mixin. Every one of them is a pure function of the
/// line and a move index, so none of them needs the controller — or a mixin.
library;

import 'package:dartchess/dartchess.dart';

import '../../models/repertoire_line.dart';
import '../../utils/movetext_builder.dart';

/// Full move number of the move at [moveIndex] within [line].
///
/// Lines can start from any position, so the count is anchored to the line's
/// own starting fullmove rather than to move 1, and which side moves first
/// shifts where the increment falls.
int fullMoveNumberIn(RepertoireLine? line, int moveIndex) {
  if (line == null) return 1;
  final startFullmoves = line.startPosition.fullmoves;
  final startIsWhite = line.startPosition.turn == Side.white;
  return startIsWhite
      ? startFullmoves + (moveIndex ~/ 2)
      : startFullmoves + ((moveIndex + 1) ~/ 2);
}

/// Whether the move at [moveIndex] within [line] is White's.
bool isWhiteMoveIn(RepertoireLine? line, int moveIndex) {
  if (line == null) return true;
  final startIsWhite = line.startPosition.turn == Side.white;
  return startIsWhite ? moveIndex.isEven : moveIndex.isOdd;
}

/// Build the display card for the move at [moveIndex] within [line].
///
/// An absent line yields a blank card rather than throwing: the trainer builds
/// display state during transitions, when the next line may not be loaded yet.
MoveDisplayInfo buildMoveDisplay(
  RepertoireLine? line,
  int moveIndex, {
  bool isOpponent = false,
}) {
  if (line == null) {
    return MoveDisplayInfo(
      moveIndex: moveIndex,
      san: '',
      fullMoveNumber: 1,
      isWhiteMove: true,
      isOpponentMove: isOpponent,
      comment: null,
    );
  }
  return MoveDisplayInfo(
    moveIndex: moveIndex,
    san: line.moves[moveIndex],
    fullMoveNumber: fullMoveNumberIn(line, moveIndex),
    isWhiteMove: isWhiteMoveIn(line, moveIndex),
    isOpponentMove: isOpponent,
    comment: line.comments[moveIndex.toString()],
  );
}

/// Information about a move to display in the Chessable-style panel.
class MoveDisplayInfo {
  final int moveIndex;
  final String san;
  final int fullMoveNumber;
  final bool isWhiteMove;
  final bool isOpponentMove;
  final String? comment;

  const MoveDisplayInfo({
    required this.moveIndex,
    required this.san,
    required this.fullMoveNumber,
    required this.isWhiteMove,
    required this.isOpponentMove,
    this.comment,
  });

  /// Formatted notation like "1. e4" or "1... e5"
  String get notation =>
      formatNumberedMove(san, moveNumber: fullMoveNumber, isWhite: isWhiteMove);

  /// Label like "Black's move 1... e5" or "White's move 2. Nf3"
  String get moveLabel {
    final side = isWhiteMove ? "White's" : "Black's";
    return '$side move $notation';
  }

  /// Label for "Your move" display.
  String get yourMoveLabel => 'Your move $notation';
}
