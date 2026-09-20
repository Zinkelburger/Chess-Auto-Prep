import 'package:dartchess/dartchess.dart';

import 'fen.dart';

/// A line of UCI moves as numbered SAN from [start]: `5... Nf6 6. Nc3 O-O`.
/// Stops at the first move that is not legal, which happens when a line
/// was computed for another position. A FEN that is not a position at all
/// has no line, the same lenient reading [Fen] itself gives one.
String pvText(Fen start, List<String> uciMoves) {
  final from = _positionOf(start);
  if (from == null) return '';
  var position = from;
  final words = <String>[];
  for (final uci in uciMoves) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    final (next, san) = position.makeSan(move);
    words.add(_numbered(position, san, first: words.isEmpty));
    position = next;
  }
  return words.join(' ');
}

Position? _positionOf(Fen fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen.value));
  } on Exception {
    return null;
  }
}

String _numbered(Position before, String san, {required bool first}) {
  if (before.turn == Side.white) return '${before.fullmoves}. $san';
  return first ? '${before.fullmoves}... $san' : san;
}
