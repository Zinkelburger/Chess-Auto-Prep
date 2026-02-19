import 'package:dartchess/dartchess.dart';
import '../models/tactics_position.dart';
import 'tactics_database.dart';

/// Engine for checking tactical solutions - Flutter port of Python's TacticsEngine
class TacticsEngine {
  /// Check if a move (in UCI format) is correct for the given position.
  ///
  /// Legacy single-move check — delegates to [checkMoveAtIndex] with index 0.
  TacticsResult checkMove(TacticsPosition position, String moveUci) {
    return checkMoveAtIndex(position, moveUci, position.fen, 0);
  }

  /// Check if a move (in UCI format) matches [correctLine] at [moveIndex],
  /// starting from the board state represented by [fen].
  ///
  /// Used for multi-move tactical sequences where the board has advanced
  /// past the original position FEN.
  TacticsResult checkMoveAtIndex(
    TacticsPosition position,
    String moveUci,
    String fen,
    int moveIndex,
  ) {
    try {
      if (moveUci.length < 4 || moveIndex >= position.correctLine.length) {
        return TacticsResult.incorrect;
      }

      // Build position from the *current* board state
      final pos = Chess.fromSetup(Setup.parseFen(fen));

      // Parse the played move and verify it's legal
      final move = Move.parse(moveUci);
      if (move == null) return TacticsResult.incorrect;

      String playedSan;
      try {
        final (_, san) = pos.makeSan(move);
        playedSan = san;
      } catch (_) {
        return TacticsResult.incorrect; // illegal move
      }

      final playedUci = moveUci;

      // Expected move at this index
      final bestMove = position.correctLine[moveIndex];
      final bestIsUci = _looksLikeUci(bestMove);

      if (bestIsUci) {
        final normBestUci = bestMove.toLowerCase();
        if (playedUci.toLowerCase() == normBestUci) {
          return TacticsResult.correct;
        }
      } else {
        final normPlayedSan = _normalizeSan(playedSan);
        final normBestSan = _normalizeSan(bestMove);
        if (normPlayedSan == normBestSan) {
          return TacticsResult.correct;
        }
      }

      return TacticsResult.incorrect;
    } catch (e) {
      return TacticsResult.incorrect;
    }
  }

  bool _looksLikeUci(String move) =>
      RegExp(r'^[a-h][1-8][a-h][1-8][qrbnQRBN]?$').hasMatch(move.trim());

  String _normalizeSan(String san) =>
      san.replaceAll(RegExp(r'[+#?!]+'), '').trim();

  /// Get a hint for the position at the given move index.
  String? getHint(TacticsPosition position, {int moveIndex = 0}) {
    if (moveIndex >= position.correctLine.length) {
      return null;
    }

    return 'Try: ${position.correctLine[moveIndex]}';
  }

  /// Total number of user moves in the tactic (odd-indexed moves are opponent).
  int userMoveCount(TacticsPosition position) =>
      (position.correctLine.length + 1) ~/ 2;

  /// Get the full solution for the position, optionally starting from [fromIndex].
  String getSolution(TacticsPosition position, {int fromIndex = 0}) {
    if (position.correctLine.isEmpty ||
        fromIndex >= position.correctLine.length) {
      return 'No solution available';
    }

    return position.correctLine.sublist(fromIndex).join(' ');
  }
}
