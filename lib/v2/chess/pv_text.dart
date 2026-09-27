import 'package:dartchess/dartchess.dart';

import 'fen.dart';
import 'pgn/tree_edit.dart' show positionOf;

/// One move of an engine line as it is shown: numbered SAN, the UCI it
/// came from, and the position it leaves behind.
final class PvMove {
  const PvMove({
    required this.label,
    required this.san,
    required this.uci,
    required this.after,
  });

  /// `5.` before a White move, `5...` before a Black move that opens the
  /// line, nothing before any other Black move.
  final String label;
  final String san;
  final String uci;

  /// The position once this move is played.
  final Fen after;

  /// `5. Nf3`, `5... Nf6`, `O-O`.
  String get text => label.isEmpty ? san : '$label $san';
}

/// A line of UCI moves as numbered SAN from [start]. Stops at the first
/// move that is not legal, which happens when a line was computed for
/// another position. A FEN that is not a position at all has no line, the
/// same lenient reading [Fen] itself gives one.
List<PvMove> pvMoves(Fen start, List<String> uciMoves) {
  final from = positionOf(start);
  if (from == null) return const [];
  var position = from;
  final moves = <PvMove>[];
  for (final uci in uciMoves) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    final (next, san) = position.makeSan(move);
    moves.add(
      PvMove(
        label: _label(position, first: moves.isEmpty),
        san: san,
        uci: uci,
        after: Fen(next.fen),
      ),
    );
    position = next;
  }
  return moves;
}

/// The same line as one string: `5... Nf6 6. Nc3 O-O`.
String pvText(Fen start, List<String> uciMoves) =>
    pvMoves(start, uciMoves).map((move) => move.text).join(' ');

String _label(Position before, {required bool first}) {
  if (before.turn == Side.white) return '${before.fullmoves}.';
  return first ? '${before.fullmoves}...' : '';
}
