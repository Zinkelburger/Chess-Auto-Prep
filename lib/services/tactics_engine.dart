import 'package:dartchess/dartchess.dart';
import '../models/tactics_position.dart';
import 'tactics_database.dart';

/// Engine for checking tactical solutions - Flutter port of Python's TacticsEngine
class TacticsEngine {
  /// Check if a move (in UCI format) is correct for the given position
  /// Returns TacticsResult.correct, .partial, or .incorrect
  TacticsResult checkMove(TacticsPosition position, String moveUci) {
    try {
      final chess = Chess.fromSetup(Setup.parseFen(position.fen));

      // Parse the UCI move
      final move = Move.fromUci(moveUci);
      if (move == null) {
        return TacticsResult.incorrect;
      }

      // Check if the move is legal
      if (!chess.isLegal(move)) {
        return TacticsResult.incorrect;
      }

      // Convert the move to SAN for comparison
      final moveSan = chess.toSan(move);

      // Check if move matches the correct line
      if (position.correctLine.isEmpty) {
        return TacticsResult.incorrect;
      }

      // Match against first move in correct line (the expected move)
      final expectedMove = position.correctLine[0];
      if (_movesMatch(moveSan, expectedMove)) {
        return TacticsResult.correct;
      }

      // Check if it's in the correct line but not the best move (partial credit)
      for (final correctMove in position.correctLine) {
        if (_movesMatch(moveSan, correctMove)) {
          return TacticsResult.partial;
        }
      }

      return TacticsResult.incorrect;
    } catch (e) {
      print('Error checking move: $e');
      return TacticsResult.incorrect;
    }
  }

  /// Compare two moves in SAN notation, ignoring annotations (+, #, !, ?)
  bool _movesMatch(String move1, String move2) {
    // Remove annotations
    final clean1 = _cleanSanMove(move1);
    final clean2 = _cleanSanMove(move2);

    return clean1.toLowerCase() == clean2.toLowerCase();
  }

  /// Clean SAN move by removing annotations
  String _cleanSanMove(String san) {
    return san.replaceAll(RegExp(r'[+#!?]+'), '');
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
