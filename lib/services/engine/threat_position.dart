import 'package:dartchess/dartchess.dart';

/// The opponent's turn after a hypothetical pass. A pass cannot evade check,
/// and en passant expires rather than being inherited by the wrong side.
String? threatPositionFen(String fen) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    if (position.isCheck || position.isGameOver) return null;
    return position
        .copyWith(
          turn: position.turn.opposite,
          epSquare: null,
          halfmoves: position.halfmoves + 1,
          fullmoves: position.fullmoves + (position.turn == Side.black ? 1 : 0),
        )
        .fen;
  } on Exception {
    return null;
  }
}
