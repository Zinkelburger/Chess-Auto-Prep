import 'package:dartchess/dartchess.dart' show Position;

import 'mainline_book.dart' show PlayedMove, legalPractice;
import 'sources.dart';

/// What the games of a database say the opponent plays at [position], as
/// the search's policy: each legal reply weighted by the games that played
/// it, with how many games that is in all.
///
/// The weights are counts, not shares: [Policy.sharesOver] turns them into
/// shares of one at the position, so a database's counts and a model's
/// probabilities are on the same footing wherever each is used. A move that
/// is not legal here takes no weight, and the two spellings of castling are
/// one move.
///
/// Example: `e7e5` in 60 games, `c7c5` in 30 and an illegal `a1a1` in 10
/// give weights `{e7e5: 60, c7c5: 30}` over 90 games, which the search
/// reads as two thirds and one third.
({Policy policy, int games}) playedPolicy(
  Position position,
  List<PlayedMove> practice,
) {
  final legal = legalPractice(position, practice);
  return (
    policy: Policy({for (final move in legal) move.uci: move.games.toDouble()}),
    games: legal.fold(0, (sum, move) => sum + move.games),
  );
}
