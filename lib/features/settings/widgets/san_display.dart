/// A move as the reader wants to see it.
///
/// Storage, comparison and the PGN all keep the letter (`Nf3`); only the
/// pixels change. Every move list goes through [displaySan] so the piece
/// notation preference means one thing everywhere, and nothing that is
/// parsed back — the move box, a copied PGN — ever sees a glyph.
library;

import 'package:provider/provider.dart';
import 'package:chess_auto_prep/features/settings/controllers/board_display_settings.dart';
import 'package:chess_auto_prep/features/settings/models/board_display_configuration.dart';

import 'package:flutter/widgets.dart';

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

bool _usesFigurines(BuildContext context) =>
    (context.watch<BoardDisplaySettings?>()?.committed ??
            BoardDisplayConfiguration())
        .pieceNotation ==
    PieceNotation.figurines;

/// [san] under the piece-notation preference in effect for [context].
String displaySan(BuildContext context, String san) =>
    _usesFigurines(context) ? figurineSan(san) : san;

/// Every move of [sanMoves] through [displaySan].
List<String> displaySanList(BuildContext context, List<String> sanMoves) =>
    _usesFigurines(context)
    ? [for (final san in sanMoves) figurineSan(san)]
    : sanMoves;
