import 'package:dartchess/dartchess.dart' show Position;

import '../chess/fen.dart';
import '../chess/generation/mainline_book.dart' show PlayedMove;
import '../chess/generation/sources.dart';
import '../engines/maia/move_policy.dart';
import '../storage/master_book.dart';

// The opponents a search from the board plays against: the Maia model for
// the practical search, the masters' games for the mainline book.

/// The Maia model as the search's opponent, at one rating.
///
/// The model answers with shares over the legal moves, most likely first,
/// which is already a policy; a position it cannot read is a position the
/// search stops at, as the algorithm requires.
final class MaiaOpponent implements OpponentPolicy {
  const MaiaOpponent(this.model, {required this.elo});

  final MovePolicy model;
  final int elo;

  @override
  Future<PolicyResult> policyFor(Position position) async =>
      switch (await model.policy(Fen(position.fen), elo)) {
        MaiaPolicy(:final shares) => PolicyFound(Policy(shares)),
        MaiaFailed(:final reason) => PolicyUnavailable(reason),
      };
}

/// The replies masters played, in the games on this machine, as the
/// mainline book follows them.
final class MastersPlayed {
  const MastersPlayed(this._book);

  final MasterBook _book;

  /// The replies masters played at [fen], most played first, over the
  /// board or not; none where the games cannot be read.
  Future<List<PlayedMove>> at(Fen fen) async => switch (await _book.lookup(
    fen,
    classicalOnly: false,
  )) {
    BookFound(:final answer) => [
      for (final move in answer.moves) (uci: move.uci, games: move.games),
    ],
    BookAbsent() || BookUnreadable() || BookClassicalIncomplete() => const [],
  };
}
