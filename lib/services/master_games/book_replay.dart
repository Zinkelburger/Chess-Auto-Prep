/// Turning a stored game back into the `book` rows it contributed.
///
/// The importer, the classical rebuild and the model-game picker all read a
/// game's SAN movetext, replay its opening with dartchess and key each
/// position with [positionKey].  This is the one copy of that walk, so the
/// three stay in step about where a replay stops and what a result counts as.
library;

import 'package:dartchess/dartchess.dart';

import '../generation/pgn_lexer.dart'
    show isResultToken, tokenToSan, tokenizeMovetext;
import 'master_games_db.dart';
import 'position_key.dart';

/// The SAN moves of [movetext], stopping at the result token and after
/// [maxPlies] moves when given.
List<String> movetextSans(String movetext, {int? maxPlies}) {
  final sans = <String>[];
  for (final token in tokenizeMovetext(movetext)) {
    if (isResultToken(token)) break;
    final san = tokenToSan(token);
    if (san != null) sans.add(san);
    if (maxPlies != null && sans.length >= maxPlies) break;
  }
  return sans;
}

/// One `book` row a game touched: the position it was played in, the move as
/// UCI, and the ply (0 for White's first move).
typedef BookMoveRef = ({int positionKey, String uci, int ply});

/// Replay [sans] from the initial position, one [BookMoveRef] per ply up to
/// [maxPly].  Stops at the first move dartchess cannot play — corrupt
/// movetext keeps whatever replayed before it, like Scid's own importer.
List<BookMoveRef> replayBookMoves(
  List<String> sans, {
  int maxPly = kBookMaxPly,
}) {
  final out = <BookMoveRef>[];
  Position position = Chess.initial;
  final limit = sans.length < maxPly ? sans.length : maxPly;
  for (var ply = 0; ply < limit; ply++) {
    final Move? move;
    try {
      move = position.parseSan(sans[ply]);
    } on Object {
      break; // dartchess throws on malformed SAN rather than returning null
    }
    if (move == null) break;
    out.add((positionKey: positionKey(position.fen), uci: move.uci, ply: ply));
    position = position.play(move);
  }
  return out;
}

/// A PGN result as the three counters the book keeps for it.  An unfinished
/// or unknown result counts as none of them.
typedef ResultTally = ({int whiteWins, int draws, int blackWins});

ResultTally resultTally(String result) => (
  whiteWins: result == '1-0' ? 1 : 0,
  draws: result == '1/2-1/2' ? 1 : 0,
  blackWins: result == '0-1' ? 1 : 0,
);

/// The stronger of the two ratings, 0 when neither is known.
int strongerElo(int? whiteElo, int? blackElo) {
  final white = whiteElo ?? 0;
  final black = blackElo ?? 0;
  return white > black ? white : black;
}
