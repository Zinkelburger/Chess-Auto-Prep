import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../models/tactics_position.dart';
import '../../../services/engine/eval_worker.dart';
import '../../../services/maia/maia_factory.dart';
import '../../../services/maia/maia_service.dart';
import 'tactics_database.dart';

/// Checks moves against a puzzle's stored line, converts stored lines to SAN
/// for display, and builds the trainable line when a puzzle is mined.
class TacticsEngine {
  /// Max user moves in a trainable tactic line.
  static const int maxTrainableUserMoves = 5;

  /// Max total plies in a Maia-guided trainable line (3 user + 2 opponent + 1).
  static const int maxMaiaLinePly = 6;

  /// Minimum Maia probability for an opponent reply to be considered "obvious".
  static const double maiaMinExtendProb = 0.85;

  /// Lower threshold when the opponent's top Maia move is a capture.
  /// Recaptures are inherently predictable even when MAIA spreads probability.
  static const double maiaMinExtendProbCapture = 0.50;

  /// Stockfish depth used when Maia's top move disagrees with the PV.
  static const int maiaDisagreeDepth = 14;

  /// True when [san] is a capture, check, or mate symbol in SAN.
  static bool isTacticalSan(String san) {
    return san.contains('x') || san.contains('+') || san.contains('#');
  }

  static final _uciMoveRe = RegExp(r'^[a-h][1-8][a-h][1-8][qrbnQRBN]?$');

  /// Whether a stored line token is a UCI move (`e2e4`, `e7e8q`) rather
  /// than SAN.
  static bool looksLikeUci(String move) => _uciMoveRe.hasMatch(move.trim());

  /// True when [uci] is a capture on the given [pos] (target square occupied
  /// or en-passant).
  static bool _isCaptureUci(Position pos, String uci) {
    final move = Move.parse(uci);
    if (move is! NormalMove) return false;
    if (pos.board.pieceAt(move.to) != null) return true;
    // En-passant: pawn moving diagonally to an empty square.
    final fromPiece = pos.board.pieceAt(move.from);
    if (fromPiece != null &&
        fromPiece.role == Role.pawn &&
        move.from.file != move.to.file) {
      return true;
    }
    return false;
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
    } catch (e) {
      debugPrint('[TacticsEngine] Invalid start FEN "$startFen": $e');
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
      } catch (e) {
        debugPrint('[TacticsEngine] Maia evaluation failed: $e');
        break;
      }

      if (maiaResult.policy.isEmpty) break;
      final topEntry = maiaResult.policy.entries.reduce(
        (a, b) => a.value >= b.value ? a : b,
      );
      final topMoveUci = topEntry.key;
      final topProb = topEntry.value;

      final isCapture = _isCaptureUci(pos, topMoveUci);
      final threshold = isCapture
          ? maiaMinExtendProbCapture
          : maiaMinExtendProb;
      if (topProb < threshold) break;

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
        } catch (e) {
          debugPrint('[TacticsEngine] Failed to format Maia move: $e');
          break;
        }
        line.add(maiaSan);

        if (worker == null || line.length >= maxMaiaLinePly) break;

        try {
          final sfResult = await worker.evaluateFen(pos.fen, maiaDisagreeDepth);
          if (sfResult.pv.isNotEmpty) {
            final bestUci = sfResult.pv.first;
            final bestMove = Move.parse(bestUci);
            if (bestMove != null) {
              try {
                final (_, san) = pos.makeSan(bestMove);
                line.add(san);
              } catch (e) {
                debugPrint('[TacticsEngine] Failed to format SF best move: $e');
              }
            }
          }
        } catch (e) {
          debugPrint('[TacticsEngine] Stockfish eval failed: $e');
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

  /// Whether [moveUci] matches [position]'s stored line at [moveIndex],
  /// played from the board state [fen] (which has advanced past the puzzle's
  /// own FEN on a multi-move line).
  ///
  /// A stored UCI token is compared as UCI; a stored SAN token is compared
  /// against the played move's SAN with suffixes (`+ # ? !`) ignored. An
  /// illegal or unparseable move, or a bad [fen], is simply incorrect.
  TacticsResult checkMoveAtIndex(
    TacticsPosition position,
    String moveUci,
    String fen,
    int moveIndex,
  ) {
    if (moveUci.length < 4 || moveIndex >= position.correctLine.length) {
      return TacticsResult.incorrect;
    }
    final String playedSan;
    try {
      final pos = Chess.fromSetup(Setup.parseFen(fen));
      final move = Move.parse(moveUci);
      if (move == null) return TacticsResult.incorrect;
      final (_, san) = pos.makeSan(move);
      playedSan = san;
    } catch (e) {
      debugPrint('[TacticsEngine] Illegal move in checkMoveAtIndex: $e');
      return TacticsResult.incorrect;
    }

    final expected = position.correctLine[moveIndex];
    final matches = looksLikeUci(expected)
        ? moveUci.toLowerCase() == expected.toLowerCase()
        : _normalizeSan(playedSan) == _normalizeSan(expected);
    return matches ? TacticsResult.correct : TacticsResult.incorrect;
  }

  static final _sanSuffixRe = RegExp(r'[+#?!]+');

  String _normalizeSan(String san) => san.replaceAll(_sanSuffixRe, '').trim();

  /// Total number of user moves in the tactic (odd-indexed moves are opponent).
  int userMoveCount(TacticsPosition position) =>
      (position.correctLine.length + 1) ~/ 2;

  /// Line shown in **Show Solution** (full PV when stored, else trainable line).
  List<String> solutionLineToSan(TacticsPosition position, {int? maxMoves}) {
    final moves = position.solutionPv.isNotEmpty
        ? position.solutionPv
        : position.correctLine;
    return lineToSan(position.fen, moves, maxMoves: maxMoves);
  }

  /// SAN moves for [moves] played from [fen] (UCI or SAN tokens).
  List<String> lineToSan(String fen, List<String> moves, {int? maxMoves}) {
    if (moves.isEmpty) return const [];

    try {
      Position pos = Chess.fromSetup(Setup.parseFen(fen));
      final result = <String>[];

      for (final raw in moves) {
        if (maxMoves != null && result.length >= maxMoves) break;
        final token = raw.trim();
        if (token.isEmpty) continue;

        final move = looksLikeUci(token)
            ? Move.parse(token)
            : pos.parseSan(token);
        if (move == null) break;

        try {
          final (newPos, san) = pos.makeSan(move);
          result.add(san);
          pos = newPos;
        } catch (e) {
          debugPrint('[TacticsEngine] Failed to format move "$token": $e');
          break;
        }
      }

      return result;
    } catch (e) {
      debugPrint('[TacticsEngine] lineToSan failed for FEN "$fen": $e');
      return const [];
    }
  }

  /// SAN for [position.correctLine] only (training validation line).
  List<String> correctLineToSan(
    TacticsPosition position, {
    int maxMoves = maxTrainableUserMoves * 2,
  }) => lineToSan(position.fen, position.correctLine, maxMoves: maxMoves);

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
