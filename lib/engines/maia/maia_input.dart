import 'dart:typed_data';

import 'package:dartchess/dartchess.dart';

import '../../chess/fen.dart';
import '../../chess/generation/legal_moves.dart';
import 'maia_vocabulary.dart';

/// Piece letters in the order of the network's twelve channels.
const String _channels = 'PNBRQKpnbrqk';

const int _files = 8;

/// One position in the two forms the network takes it in.
final class MaiaInput {
  const MaiaInput({
    required this.tokens,
    required this.legalMask,
    required this.mirrored,
  });

  /// The board as the `[1, 64, 12]` input flattened: twelve floats per
  /// square, one of them 1.0 for the piece standing there. Square index is
  /// `rank * 8 + file` counting a1 as 0, so the first twelve floats are a1.
  final Float32List tokens;

  /// 1.0 at the vocabulary index of every legal move, 0.0 everywhere else.
  final Float32List legalMask;

  /// Whether the position had to be mirrored to put White on the move, in
  /// which case the answer's move names have to be mirrored back.
  final bool mirrored;
}

/// [fen] as the network takes it, or null when it is not a position.
///
/// The original text is parsed first, so a FEN nobody could play is refused
/// here rather than somewhere inside the mirror.
MaiaInput? encodeForMaia(Fen fen, MaiaVocabulary vocabulary) {
  final position = _positionOf(fen);
  if (position == null) return null;
  final mirrored = !fen.whiteToMove;
  if (!mirrored) {
    return MaiaInput(
      tokens: boardTokens(fen),
      legalMask: _legalMask(position, vocabulary),
      mirrored: false,
    );
  }
  final shown = mirrorFen(fen);
  final shownPosition = _positionOf(shown);
  if (shownPosition == null) return null;
  return MaiaInput(
    tokens: boardTokens(shown),
    legalMask: _legalMask(shownPosition, vocabulary),
    mirrored: true,
  );
}

/// The placement field of [fen] as the network's 768 floats.
Float32List boardTokens(Fen fen) {
  final tokens = Float32List(_files * _files * _channels.length);
  final ranks = fen.value.split(' ').first.split('/');
  final shown = ranks.length < _files ? ranks.length : _files;
  for (var i = 0; i < shown; i++) {
    // The placement field starts at rank 8, the tokens at rank 1.
    _writeRank(tokens, ranks[i], _files - 1 - i);
  }
  return tokens;
}

Position? _positionOf(Fen fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen.value));
  } on FenException {
    return null;
  } on PositionSetupException {
    return null;
  }
}

/// A move the table does not name — there is none in standard chess — is
/// left out rather than marked at somebody else's index.
Float32List _legalMask(Position position, MaiaVocabulary vocabulary) {
  final mask = Float32List(vocabulary.size);
  for (final named in legalMovesOf(position)) {
    final index = vocabulary.indexOf(named.uci);
    if (index != null) mask[index] = 1.0;
  }
  return mask;
}

void _writeRank(Float32List tokens, String text, int rank) {
  var file = 0;
  for (final char in text.split('')) {
    final empty = int.tryParse(char);
    if (empty != null) {
      file += empty;
      continue;
    }
    final channel = _channels.indexOf(char);
    if (channel >= 0 && file < _files) {
      tokens[(rank * _files + file) * _channels.length + channel] = 1.0;
    }
    file++;
  }
}

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
