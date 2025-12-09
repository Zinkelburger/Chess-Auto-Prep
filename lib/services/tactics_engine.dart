import 'package:chess/chess.dart' as chess;
import '../models/tactics_position.dart';
import 'tactics_database.dart';

/// Engine for checking tactical solutions - Flutter port of Python's TacticsEngine
class TacticsEngine {
  /// Check if a move (in UCI format) is correct for the given position
  /// Returns TacticsResult.correct or .incorrect
  TacticsResult checkMove(TacticsPosition position, String moveUci) {
    try {
      if (moveUci.length < 4 || position.correctLine.isEmpty) {
        return TacticsResult.incorrect;
      }

      // Build game from FEN
      final game = chess.Chess.fromFEN(position.fen);

      // Find the played move in legal moves to get its SAN / promotion info
      final legalVerbose = game.moves({'verbose': true});
      final played = legalVerbose.firstWhere(
        (m) =>
            m['from'] == moveUci.substring(0, 2) &&
            m['to'] == moveUci.substring(2, 4) &&
            ((moveUci.length == 4 && (m['promotion'] == null || m['promotion'] == '')) ||
                (moveUci.length > 4 &&
                    (m['promotion'] == moveUci.substring(4).toLowerCase()))),
        orElse: () => <String, dynamic>{},
      );

      if (played.isEmpty) {
        return TacticsResult.incorrect; // illegal or not found
      }

      final playedSan = (played['san'] as String?) ?? '';
      final playedUci = (played['from'] as String) +
          (played['to'] as String) +
          ((played['promotion'] as String?) ?? '');

      // Best move from the line (could be SAN with annotations or UCI)
      final bestMove = position.correctLine.first;
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

  /// Get a hint for the position
  String? getHint(TacticsPosition position) {
    if (position.correctLine.isEmpty) {
      return null;
    }

    // Return the first move of the correct line as a hint
    return 'Try: ${position.correctLine[0]}';
  }

  /// Get the full solution for the position
  String getSolution(TacticsPosition position) {
    if (position.correctLine.isEmpty) {
      return 'No solution available';
    }

    return position.correctLine.join(' ');
  }
}
