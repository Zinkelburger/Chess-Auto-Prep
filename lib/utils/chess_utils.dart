/// Shared chess move-conversion and formatting utilities.
///
/// Centralises UCI ↔ SAN helpers that were duplicated in
/// [UnifiedEnginePane] and [RepertoireScreen].
library;

import 'package:chess/chess.dart' as chess;

/// Convert a UCI move string (e.g. `e2e4`) to SAN notation given [fen].
///
/// Returns the original [uci] string if the move cannot be resolved.
String uciToSan(String fen, String uci) {
  try {
    final game = chess.Chess.fromFEN(fen);
    final from = uci.substring(0, 2);
    final to = uci.substring(2, 4);
    String? promotion;
    if (uci.length > 4) promotion = uci.substring(4);

    final legalMoves = game.moves({'verbose': true});
    final match = legalMoves.firstWhere(
      (m) =>
          m['from'] == from &&
          m['to'] == to &&
          (promotion == null || m['promotion'] == promotion),
      orElse: () => <String, dynamic>{},
    );

    return match.isNotEmpty ? match['san'] as String : uci;
  } catch (_) {
    return uci;
  }
}

/// Format a PV continuation (skip the first move) as SAN text.
///
/// Returns at most [maxMoves] SAN tokens joined by spaces.
String formatContinuation(String fen, List<String> fullPv, {int maxMoves = 6}) {
  if (fullPv.length <= 1) return '';

  final game = chess.Chess.fromFEN(fen);
  final sanMoves = <String>[];

  for (int i = 0; i < fullPv.length && sanMoves.length < maxMoves; i++) {
    final uci = fullPv[i];
    if (uci.length < 4) continue;

    final from = uci.substring(0, 2);
    final to = uci.substring(2, 4);
    String? promotion;
    if (uci.length > 4) promotion = uci.substring(4);

    final moveMap = <String, String>{'from': from, 'to': to};
    if (promotion != null) moveMap['promotion'] = promotion;

    final legalMoves = game.moves({'verbose': true});
    final matchingMove = legalMoves.firstWhere(
      (m) =>
          m['from'] == from &&
          m['to'] == to &&
          (promotion == null || m['promotion'] == promotion),
      orElse: () => <String, dynamic>{},
    );

    if (matchingMove.isNotEmpty && game.move(moveMap)) {
      if (i >= 1) {
        sanMoves.add(matchingMove['san'] as String);
      }
    } else {
      break;
    }
  }

  return sanMoves.join(' ');
}

/// Play a UCI move on [baseFen] and return the resulting FEN, or `null`
/// if the move is illegal.
String? playUciMove(String baseFen, String uci) {
  try {
    final game = chess.Chess.fromFEN(baseFen);
    final from = uci.substring(0, 2);
    final to = uci.substring(2, 4);
    String? promotion;
    if (uci.length > 4) promotion = uci.substring(4);
    if (game.move({'from': from, 'to': to, 'promotion': promotion})) {
      return game.fen;
    }
  } catch (_) {}
  return null;
}

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
