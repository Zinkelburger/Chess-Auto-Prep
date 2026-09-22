import 'dart:typed_data';

import 'package:dartchess/dartchess.dart';

import '../../chess/fen.dart';
import '../../chess/generation/legal_moves.dart';
import 'maia_mirror.dart';
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
