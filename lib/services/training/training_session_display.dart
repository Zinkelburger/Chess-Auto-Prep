part of 'training_session_controller.dart';

// ---------------------------------------------------------------------------
// MOVE DISPLAY HELPERS
// ---------------------------------------------------------------------------

/// State-coupled move-notation and display-card helpers for
/// [TrainingSessionController]. Shared fields are provided by the host class.
mixin _MoveDisplayMixin on ChangeNotifier {
  RepertoireLine? get currentLine;

  /// Compute the full move number for a given move index in the current line.
  int _fullMoveNumber(int moveIndex) {
    if (currentLine == null) return 1;
    final startFullmoves = currentLine!.startPosition.fullmoves;
    final startIsWhite = currentLine!.startPosition.turn == Side.white;
    if (startIsWhite) {
      return startFullmoves + (moveIndex ~/ 2);
    } else {
      return startFullmoves + ((moveIndex + 1) ~/ 2);
    }
  }

  /// Whether the move at [moveIndex] is White's move.
  bool _isMoveWhite(int moveIndex) {
    if (currentLine == null) return true;
    final startIsWhite = currentLine!.startPosition.turn == Side.white;
    return startIsWhite ? (moveIndex % 2 == 0) : (moveIndex % 2 == 1);
  }

  /// Format a move as "1. e4" or "1... e5".
  String formatMoveNotation(int moveIndex, String san) {
    final num = _fullMoveNumber(moveIndex);
    final isWhite = _isMoveWhite(moveIndex);
    return isWhite ? '$num. $san' : '$num... $san';
  }

  /// Build a [MoveDisplayInfo] for the given move index.
  MoveDisplayInfo _buildMoveDisplay(int moveIndex, {bool isOpponent = false}) {
    if (currentLine == null) {
      return MoveDisplayInfo(
        moveIndex: moveIndex,
        san: '',
        fullMoveNumber: 1,
        isWhiteMove: true,
        isOpponentMove: isOpponent,
        comment: null,
      );
    }
    final san = currentLine!.moves[moveIndex];
    return MoveDisplayInfo(
      moveIndex: moveIndex,
      san: san,
      fullMoveNumber: _fullMoveNumber(moveIndex),
      isWhiteMove: _isMoveWhite(moveIndex),
      isOpponentMove: isOpponent,
      comment: currentLine!.comments[moveIndex.toString()],
    );
  }
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
      isWhiteMove ? '$fullMoveNumber. $san' : '$fullMoveNumber... $san';

  /// Label like "Black's move 1... e5" or "White's move 2. Nf3"
  String get moveLabel {
    final side = isWhiteMove ? "White's" : "Black's";
    return '$side move $notation';
  }

  /// Label for "Your move" display.
  String get yourMoveLabel => 'Your move $notation';
}
