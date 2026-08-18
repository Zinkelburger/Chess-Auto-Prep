/// Board previews for the games list.
///
/// Each row shows the position the game ended in — the thing that makes a list
/// of games recognisable at a glance, the way Lichess's game list does. Getting
/// there means replaying the mainline, which is cheap per game but not free
/// across twenty of them on the frame that builds the list, so it runs in a
/// batch through `compute` alongside the SAN extraction.
///
/// Pure and top-level for exactly that reason: no engine, no IO, no widgets.
library;

import 'package:dartchess/dartchess.dart';

import '../../../utils/chess_utils.dart' show playSanOrNullMove;

/// FEN of the position after the last mainline move of each game.
///
/// Null for a game whose moves don't replay from the standard start (a
/// from-position game, or a movetext this parser can't follow) — the row then
/// shows a placeholder instead of a wrong board.
List<String?> finalFensBatch(List<List<String>> gameSans) => [
  for (final sans in gameSans) finalFen(sans),
];

/// FEN after playing [sans] from the initial position, or null if a move is
/// illegal there. Stops at the first unplayable move rather than throwing: a
/// truncated replay still shows a real position from the game.
String? finalFen(List<String> sans) {
  if (sans.isEmpty) return Chess.initial.fen;
  Position pos = Chess.initial;
  var played = 0;
  for (final san in sans) {
    final next = playSanOrNullMove(pos, san);
    if (next == null) break;
    pos = next;
    played++;
  }
  if (played == 0) return null;
  return pos.fen;
}
