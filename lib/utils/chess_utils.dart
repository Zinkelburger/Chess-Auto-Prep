/// Shared chess move-conversion and formatting utilities.
///
/// Centralises UCI ↔ SAN helpers that were duplicated in
/// [UnifiedEnginePane] and [RepertoireScreen].
library;

import 'package:dartchess/dartchess.dart';

/// Convert a UCI move string (e.g. `e2e4`) to SAN notation given [fen].
///
/// Returns the original [uci] string if the move cannot be resolved.
String uciToSan(String fen, String uci) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final move = Move.parse(uci);
    if (move == null) return uci;
    final (_, san) = position.makeSan(move);
    return san;
  } catch (_) {
    return uci;
  }
}

/// Format a PV continuation (skip the first move) as SAN text.
///
/// Returns at most [maxMoves] SAN tokens joined by spaces.
String formatContinuation(String fen, List<String> fullPv, {int maxMoves = 6}) {
  if (fullPv.length <= 1) return '';

  try {
    Position pos = Chess.fromSetup(Setup.parseFen(fen));
    final sanMoves = <String>[];

    for (int i = 0; i < fullPv.length && sanMoves.length < maxMoves; i++) {
      final uci = fullPv[i];
      final move = Move.parse(uci);
      if (move == null) break;

      try {
        if (i >= 1) {
          final (_, san) = pos.makeSan(move);
          sanMoves.add(san);
        }
        pos = pos.play(move);
      } catch (_) {
        break;
      }
    }

    return sanMoves.join(' ');
  } catch (_) {
    return '';
  }
}

/// Play a UCI move on [baseFen] and return the resulting FEN, or `null`
/// if the move is illegal.
String? playUciMove(String baseFen, String uci) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(baseFen));
    final move = Move.parse(uci);
    if (move == null) return null;
    final newPos = position.play(move);
    return newPos.fen;
  } catch (_) {
    return null;
  }
}

/// Parse a FEN into a [Position], returning null if invalid.
Position? tryParseFen(String fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen));
  } catch (_) {
    return null;
  }
}

/// Parse an algebraic square name (e.g. 'e4') to a dartchess [Square].
Square? parseSquare(String name) => Square.parse(name);

/// Convert a dartchess [Square] to algebraic notation (e.g. 'e4').
String toAlgebraic(Square square) => square.name;

/// Role to uppercase character for SVG asset filenames (e.g. Role.pawn → 'P').
String roleChar(Role role) => switch (role) {
      Role.pawn => 'P',
      Role.knight => 'N',
      Role.bishop => 'B',
      Role.rook => 'R',
      Role.queen => 'Q',
      Role.king => 'K',
    };

/// Format a centipawn / mate score for display (e.g. `+1.3`, `-0.5`, `#3`).
///
/// Uses one decimal place for centipawns and `#N` for mate scores.
/// Returns `'--'` when both values are null.
String formatEvalDisplay({int? scoreCp, int? scoreMate}) {
  if (scoreMate != null) return '#$scoreMate';
  if (scoreCp != null) {
    final v = scoreCp / 100.0;
    return v >= 0 ? '+${v.toStringAsFixed(1)}' : v.toStringAsFixed(1);
  }
  return '--';
}

/// Convert a UCI principal-variation list to SAN move strings.
///
/// Walks the position forward from [fen], converting up to [maxMoves]
/// UCI tokens to SAN. Returns an empty list on any parse error.
List<String> uciPvToSan(String fen, List<String> uciMoves, {int maxMoves = 8}) {
  if (uciMoves.isEmpty) return const [];
  try {
    Position pos = Chess.fromSetup(Setup.parseFen(fen));
    final san = <String>[];
    for (final uci in uciMoves.take(maxMoves)) {
      final move = Move.parse(uci);
      if (move == null) break;
      final (newPos, sanStr) = pos.makeSan(move);
      san.add(sanStr);
      pos = newPos;
    }
    return san;
  } catch (_) {
    return const [];
  }
}

/// Format a large integer with k/M suffixes, using [mDecimals] decimal places
/// at the millions threshold and [kDecimals] at the thousands threshold.
String _formatWithSuffix(int value,
    {required int mDecimals, required int kDecimals}) {
  if (value >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(mDecimals)}M';
  }
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(kDecimals)}k';
  return value.toString();
}

/// Format a large integer with k/M suffixes.
String formatCount(int count) =>
    _formatWithSuffix(count, mDecimals: 1, kDecimals: 0);

/// Format a node count with k/M suffixes (one decimal for M and k).
String formatNodes(int nodes) =>
    _formatWithSuffix(nodes, mDecimals: 1, kDecimals: 1);

/// Format NPS with k/M suffixes.
String formatNps(int nps) =>
    _formatWithSuffix(nps, mDecimals: 1, kDecimals: 0);

/// Compute the FEN after playing [sanMoves] from [startFen] up to [upToIndex].
///
/// Returns [startFen] if no moves can be parsed.
String fenAfterMoves(String startFen, List<String> sanMoves, int upToIndex) {
  try {
    Position pos = Chess.fromSetup(Setup.parseFen(startFen));
    for (int i = 0; i <= upToIndex && i < sanMoves.length; i++) {
      final move = pos.parseSan(sanMoves[i]);
      if (move == null) break;
      pos = pos.play(move);
    }
    return pos.fen;
  } catch (_) {
    return startFen;
  }
}

/// From/to squares for highlighting the last move on a mini board.
Set<String> uciHighlightSquares(String uci) {
  if (uci.length < 4) return const {};
  return {uci.substring(0, 2), uci.substring(2, 4)};
}
