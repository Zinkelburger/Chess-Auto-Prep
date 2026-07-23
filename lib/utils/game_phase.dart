/// Per-position game-phase classification (opening / middlegame / endgame).
///
/// Simplified from Lichess's scalachess Divider: the endgame starts when six
/// or fewer majors+minors (non-pawn, non-king pieces) remain; the middlegame
/// when ten or fewer remain or either back rank has thinned below four
/// pieces (development/castling has broken the opening structure).  Unlike
/// the Divider this classifies a single position with no game context,
/// which is all the flaw tagger needs.
library;

enum GamePhase { opening, middlegame, endgame }

const String _majorsMinors = 'QRBNqrbn';

/// Classify [fen]'s position.  Falls back to middlegame for malformed FENs
/// (most positions are middlegames; a spurious opening/endgame tag would be
/// more misleading).
GamePhase classifyGamePhase(String fen) {
  final board = fen.trim().split(' ').first;
  final ranks = board.split('/');
  if (ranks.length != 8) return GamePhase.middlegame;

  var majorsMinors = 0;
  for (final rank in ranks) {
    for (var i = 0; i < rank.length; i++) {
      if (_majorsMinors.contains(rank[i])) majorsMinors++;
    }
  }
  if (majorsMinors <= 6) return GamePhase.endgame;

  int pieceCount(String rank) {
    var count = 0;
    for (var i = 0; i < rank.length; i++) {
      final c = rank.codeUnitAt(i);
      final isDigit = c >= 0x30 && c <= 0x39;
      if (!isDigit) count++;
    }
    return count;
  }

  // ranks[0] is rank 8 (Black's back rank), ranks[7] is rank 1 (White's).
  final backrankSparse = pieceCount(ranks[0]) < 4 || pieceCount(ranks[7]) < 4;
  if (majorsMinors <= 10 || backrankSparse) return GamePhase.middlegame;
  return GamePhase.opening;
}
