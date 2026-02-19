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

/// Parse a promotion character ('q','r','b','n') into a [Role].
Role? parsePromotionRole(String char) => switch (char.toLowerCase()) {
  'q' => Role.queen,
  'r' => Role.rook,
  'b' => Role.bishop,
  'n' => Role.knight,
  _ => null,
};

// ── Number formatting helpers ────────────────────────────────────────────

/// Format a large integer with k/M suffixes.
String formatCount(int count) {
  if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
  if (count >= 1000) return '${(count / 1000).toStringAsFixed(0)}k';
  return count.toString();
}

/// Format a node count with k/M suffixes (one decimal for M).
String formatNodes(int nodes) {
  if (nodes >= 1000000) return '${(nodes / 1000000).toStringAsFixed(1)}M';
  if (nodes >= 1000) return '${(nodes / 1000).toStringAsFixed(1)}k';
  return nodes.toString();
}

/// Format NPS with k/M suffixes.
String formatNps(int nps) {
  if (nps >= 1000000) return '${(nps / 1000000).toStringAsFixed(1)}M';
  if (nps >= 1000) return '${(nps / 1000).toStringAsFixed(0)}k';
  return nps.toString();
}

/// Format megabytes with GB conversion for large values.
String formatRam(int mb) {
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  return '$mb MB';
}
