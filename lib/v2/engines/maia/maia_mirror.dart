import '../../chess/fen.dart';

/// Maia-3 was trained on White-to-move positions only, so a Black position is
/// turned round before the network sees it and the answer is turned back.
///
/// Mirroring is its own inverse: rank r becomes rank 9-r, every piece changes
/// colour, the side to move changes, and each side's castling rights follow
/// its pieces. The move counters are left alone; the network does not read
/// them, and keeping them makes a mirror of a mirror the original text.
/// Example: `rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1`
/// becomes `rnbqkbnr/pppp1ppp/8/4p3/8/8/PPPPPPPP/RNBQKBNR w KQkq e6 0 1`.
Fen mirrorFen(Fen fen) {
  final fields = fen.value.split(' ');
  String field(int index, String fallback) =>
      index < fields.length ? fields[index] : fallback;
  final ranks = field(
    0,
    '8/8/8/8/8/8/8/8',
  ).split('/').reversed.map(_swapColours).join('/');
  final enPassant = field(3, '-');
  return Fen(
    '$ranks '
    '${field(1, 'w') == 'w' ? 'b' : 'w'} '
    '${_swapRights(field(2, '-'))} '
    '${enPassant == '-' ? '-' : mirrorSquare(enPassant)} '
    '${field(4, '0')} ${field(5, '1')}',
  );
}

/// The same move on the mirrored board: `e7e5` becomes `e2e4`, `e8g8` becomes
/// `e1g1`, and a promotion keeps the piece it promotes to.
String mirrorUci(String uci) {
  if (uci.length < 4) return uci;
  return '${mirrorSquare(uci.substring(0, 2))}'
      '${mirrorSquare(uci.substring(2, 4))}'
      '${uci.substring(4)}';
}

/// The square on the flipped board: `e3` becomes `e6`.
String mirrorSquare(String square) {
  if (square.length < 2) return square;
  final rank = int.tryParse(square[1]);
  return rank == null ? square : '${square[0]}${9 - rank}';
}

/// Upper case becomes lower and the other way round; digits stay as they are.
String _swapColours(String rank) {
  final swapped = StringBuffer();
  for (final char in rank.split('')) {
    final lower = char.toLowerCase();
    swapped.write(char == lower ? char.toUpperCase() : lower);
  }
  return swapped.toString();
}

/// `KQkq` order is kept, so the text of a twice-mirrored FEN is the original.
String _swapRights(String rights) {
  final swapped = [
    if (rights.contains('k')) 'K',
    if (rights.contains('q')) 'Q',
    if (rights.contains('K')) 'k',
    if (rights.contains('Q')) 'q',
  ].join();
  return swapped.isEmpty ? '-' : swapped;
}
