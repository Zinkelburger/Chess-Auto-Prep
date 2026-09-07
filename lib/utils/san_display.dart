/// A move as the reader wants to see it.
///
/// Storage, comparison and the PGN all keep the letter (`Nf3`); only the
/// pixels change. Every move list goes through [displaySan] so the piece
/// notation preference means one thing everywhere, and nothing that is
/// parsed back — the move box, a copied PGN — ever sees a glyph.
library;

import 'package:flutter/widgets.dart';

import '../models/board_display_settings.dart';

/// White figurines for both sides, the way printed chess books do it.
const Map<String, String> _figurines = {
  'K': '♔',
  'Q': '♕',
  'R': '♖',
  'B': '♗',
  'N': '♘',
};

/// `Nf3` → `♘f3`, `exd8=Q+` → `exd8=♕+`, `O-O` unchanged.
///
/// Only the two places SAN puts a piece letter are touched: the first
/// character, and the letter after a promotion `=`. Castling has no piece
/// letter and stays as written; so does anything that is not a move.
String figurineSan(String san) {
  if (san.isEmpty) return san;
  var out = san;
  final head = _figurines[out[0]];
  if (head != null) out = head + out.substring(1);
  final eq = out.indexOf('=');
  if (eq != -1 && eq + 1 < out.length) {
    final promo = _figurines[out[eq + 1]];
    if (promo != null) {
      out = out.substring(0, eq + 1) + promo + out.substring(eq + 2);
    }
  }
  return out;
}

/// [san] under the piece-notation preference in effect for [context].
String displaySan(BuildContext context, String san) =>
    BoardDisplaySettings.of(context).pieceNotation == PieceNotation.figurines
    ? figurineSan(san)
    : san;

/// Every move of [sanMoves] through [displaySan].
List<String> displaySanList(BuildContext context, List<String> sanMoves) =>
    BoardDisplaySettings.of(context).pieceNotation == PieceNotation.figurines
    ? [for (final san in sanMoves) figurineSan(san)]
    : sanMoves;
