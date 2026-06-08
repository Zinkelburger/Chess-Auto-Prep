import 'package:dartchess/dartchess.dart';
import '../models/tactics_position.dart';
import 'engine/eval_worker.dart';
import 'maia_factory.dart';
import 'maia_service.dart';
import 'tactics_database.dart';

/// Engine for checking tactical solutions - Flutter port of Python's TacticsEngine
class TacticsEngine {
  /// Max plies stored from Stockfish PV for solution display (not training length).
  static const int maxSolutionPvPlies = 12;

  /// Max user moves in a trainable tactic line.
  static const int maxTrainableUserMoves = 5;

  /// Max total plies in a Maia-guided trainable line (3 user + 2 opponent + 1).
  static const int maxMaiaLinePly = 6;

  /// Minimum Maia probability for an opponent reply to be considered "obvious".
  static const double maiaMinExtendProb = 0.85;

  /// Stockfish depth used when Maia's top move disagrees with the PV.
  static const int maiaDisagreeDepth = 14;

  /// True when [san] is a capture, check, or mate symbol in SAN.
  static bool isTacticalSan(String san) {
    return san.contains('x') || san.contains('+') || san.contains('#');
  }

  /// Convert a SAN move to UCI given the current board [pos].
  ///
  /// Returns `null` if the SAN is unparseable or illegal.
  static String? _sanToUci(Position pos, String san) {
    final move = pos.parseSan(san);
    if (move == null) return null;
    return move.uci;
  }

  /// Build the trainable line using Maia opponent-probability checks.
  ///
  /// When [maia] is provided, opponent replies are extended only when Maia
  /// predicts a single reply with >= [maiaMinExtendProb] probability:
  ///
  /// * **Agreement** (Maia top move matches PV): continue extending from PV.
  /// * **Disagreement** (Maia top move differs from PV): include Maia's move,
  ///   run a fresh Stockfish eval at [maiaDisagreeDepth] via [worker] to find
  ///   the user's best reply, then stop.
  /// * **Low confidence** (top move < threshold): stop — single-move tactic.
  ///
  /// Falls back to the old tactical-SAN heuristic when [maia] is `null`.
  static Future<List<String>> buildTrainableLine(
    List<String> pvSan, {
    int maxUserMoves = maxTrainableUserMoves,
    MaiaEvaluator? maia,
    EvalWorker? worker,
    int maiaElo = 2200,
    String? startFen,
  }) async {
    if (pvSan.isEmpty) return const [];

    if (maia == null || startFen == null) {
      return _buildTrainableLineFallback(pvSan, maxUserMoves: maxUserMoves);
    }

    final line = <String>[pvSan[0]];
    Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(startFen));
    } catch (_) {
      return _buildTrainableLineFallback(pvSan, maxUserMoves: maxUserMoves);
    }

    // Play the first user move
    final firstMove = pos.parseSan(pvSan[0]);
    if (firstMove == null) return line;
    pos = pos.play(firstMove);

    // Walk PV in (opponent, user) pairs
    var pvIdx = 1;
    while (line.length < maxMaiaLinePly && pvIdx < pvSan.length) {
      // --- Opponent ply: check Maia probability ---
      final MaiaResult maiaResult;
      try {
        maiaResult = await maia.evaluate(pos.fen, maiaElo);
      } catch (_) {
        break;
      }

      if (maiaResult.policy.isEmpty) break;
      final topMoveUci = maiaResult.policy.keys.first;
      final topProb = maiaResult.policy.values.first;

      if (topProb < maiaMinExtendProb) break;

      final pvOppUci = _sanToUci(pos, pvSan[pvIdx]);
      final agree = pvOppUci != null && pvOppUci == topMoveUci;

      if (agree) {
        // PV and Maia agree — extend from PV
        line.add(pvSan[pvIdx]);
        final oppMove = pos.parseSan(pvSan[pvIdx]);
        if (oppMove == null) break;
        pos = pos.play(oppMove);
        pvIdx++;

        // Next user move from PV
        if (pvIdx >= pvSan.length || line.length >= maxMaiaLinePly) break;
        line.add(pvSan[pvIdx]);
        final userMove = pos.parseSan(pvSan[pvIdx]);
        if (userMove == null) break;
        pos = pos.play(userMove);
        pvIdx++;
      } else {
        // Maia disagrees — play Maia's move, get fresh SF eval for user reply
        final maiaOppMove = Move.parse(topMoveUci);
        if (maiaOppMove == null) break;

        String maiaSan;
        try {
          final (newPos, san) = pos.makeSan(maiaOppMove);
          maiaSan = san;
          pos = newPos;
        } catch (_) {
          break;
        }
        line.add(maiaSan);

        if (worker == null || line.length >= maxMaiaLinePly) break;

        try {
          final sfResult =
              await worker.evaluateFen(pos.fen, maiaDisagreeDepth);
          if (sfResult.pv.isNotEmpty) {
            final bestUci = sfResult.pv.first;
            final bestMove = Move.parse(bestUci);
            if (bestMove != null) {
              try {
                final (_, san) = pos.makeSan(bestMove);
                line.add(san);
              } catch (_) {
                // Could not format — skip
              }
            }
          }
        } catch (_) {
          // SF eval failed — keep the line as-is
        }
        break; // Always stop after a disagreement branch
      }
    }

    return line;
  }

  /// Original heuristic: extend only through captures/checks/mates.
  static List<String> _buildTrainableLineFallback(
    List<String> pvSan, {
    int maxUserMoves = maxTrainableUserMoves,
  }) {
    if (pvSan.isEmpty) return const [];

    final correctLine = <String>[pvSan[0]];
    var userMoveCount = 1;
    var i = 0;

    while (userMoveCount < maxUserMoves) {
      final currentUserSan = pvSan[i];
      if (!isTacticalSan(currentUserSan)) break;
      if (i + 2 >= pvSan.length) break;
      final nextUserSan = pvSan[i + 2];
      if (!isTacticalSan(nextUserSan)) break;
      correctLine.add(pvSan[i + 1]);
      correctLine.add(nextUserSan);
      userMoveCount++;
      i += 2;
    }

    return correctLine;
  }
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

  /// Line shown in **Show Solution** (full PV when stored, else trainable line).
  List<String> solutionLineToSan(
    TacticsPosition position, {
    int maxMoves = maxSolutionPvPlies,
  }) {
    final moves = position.solutionPv.isNotEmpty
        ? position.solutionPv
        : position.correctLine;
    return lineToSan(position.fen, moves, maxMoves: maxMoves);
  }

  /// SAN moves for [moves] played from [fen] (UCI or SAN tokens).
  List<String> lineToSan(
    String fen,
    List<String> moves, {
    int maxMoves = maxSolutionPvPlies,
  }) {
    if (moves.isEmpty) return const [];

    try {
      Position pos = Chess.fromSetup(Setup.parseFen(fen));
      final result = <String>[];

      for (final raw in moves) {
        if (result.length >= maxMoves) break;
        final token = raw.trim();
        if (token.isEmpty) continue;

        final Move? move;
        if (_looksLikeUci(token)) {
          move = Move.parse(token);
        } else {
          move = pos.parseSan(token);
        }
        if (move == null) break;

        try {
          final (newPos, san) = pos.makeSan(move);
          result.add(san);
          pos = newPos;
        } catch (_) {
          break;
        }
      }

      return result;
    } catch (_) {
      return const [];
    }
  }

  /// SAN for [position.correctLine] only (training validation line).
  List<String> correctLineToSan(
    TacticsPosition position, {
    int maxMoves = maxTrainableUserMoves * 2,
  }) =>
      lineToSan(position.fen, position.correctLine, maxMoves: maxMoves);

  /// Full solution text for display.
  ///
  /// When [fromIndex] is past the end (e.g. after the user solved the line),
  /// returns the complete line so "Show Solution" never goes blank.
  String getSolution(TacticsPosition position, {int fromIndex = 0}) {
    if (position.correctLine.isEmpty) {
      return 'No solution available';
    }

    final san = solutionLineToSan(position);
    if (san.isNotEmpty) {
      if (fromIndex >= san.length) return san.join(' ');
      return san.sublist(fromIndex).join(' ');
    }

    if (fromIndex >= position.correctLine.length) {
      return position.correctLine.join(' ');
    }

    return position.correctLine.sublist(fromIndex).join(' ');
  }
}
