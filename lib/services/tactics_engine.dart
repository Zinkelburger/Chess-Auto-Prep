import '../models/tactics_position.dart';
import 'tactics_database.dart';

/// Engine for checking tactical solutions - Flutter port of Python's TacticsEngine
class TacticsEngine {
  /// Check if a move (in UCI format) is correct for the given position
  /// Returns TacticsResult.correct or .incorrect
  TacticsResult checkMove(TacticsPosition position, String moveUci) {
    try {
      // Parse target square from UCI notation (e.g., "c7" from "d8c7")
      if (moveUci.length < 4) {
        return TacticsResult.incorrect;
      }

      final targetSquare = moveUci.substring(2, 4);

      if (position.correctLine.isEmpty) {
        return TacticsResult.incorrect;
      }

      // Check against the first move (the best move)
      final bestMove = position.correctLine[0];
      if (_moveMatchesTarget(bestMove, targetSquare)) {
        return TacticsResult.correct;
      }

      return TacticsResult.incorrect;
    } catch (e) {
      return TacticsResult.incorrect;
    }
  }

  /// Check if a SAN move matches the target square
  bool _moveMatchesTarget(String sanMove, String targetSquare) {
    // Remove annotations (+, #, !, ?)
    final cleanMove = sanMove.replaceAll(RegExp(r'[+#!?]+'), '');

    // Extract target square (last 2 characters)
    if (cleanMove.length >= 2) {
      final expectedTarget = cleanMove.substring(cleanMove.length - 2);
      return targetSquare.toLowerCase() == expectedTarget.toLowerCase();
    }

    return false;
  }

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
