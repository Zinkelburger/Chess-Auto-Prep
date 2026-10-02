import 'package:dartchess/dartchess.dart' show Position;

import '../chess/explorer_choice.dart';
import '../chess/fen.dart';
import '../chess/generation/expectimax_options.dart';
import '../chess/generation/mainline_book.dart' show PlayedMove;
import '../chess/generation/played_policy.dart';
import '../chess/generation/sources.dart';
import '../engines/maia/move_policy.dart';
import '../net/lichess_explorer.dart';
import '../storage/master_book.dart';
import 'fill_states.dart';

// The opponents a search from the board plays against: the Maia model for
// the practical search, the masters' games for the mainline book. And what
// the engine told it that the tree does not keep.

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

/// What a database of games said when asked about one position.
sealed class PlayedLookup {
  const PlayedLookup();
}

/// The replies played there, which may be none.
final class PlayedFound extends PlayedLookup {
  const PlayedFound(this.moves);

  final List<PlayedMove> moves;
}

/// The database could not be asked; [reason] is a sentence for the screen.
final class PlayedUnavailable extends PlayedLookup {
  const PlayedUnavailable(this.reason);

  final String reason;
}

typedef PlayedAt = Future<PlayedLookup> Function(Fen fen);

/// A database of games as the search's opponent: at each position the
/// replies played there, weighted by their games.
///
/// One position has one source, and its answer says which ([RepliesFrom]).
/// Where the database has fewer than [fallbackUnder] games and there is a
/// [fallback], the fallback answers that position whole; the two are never
/// blended, and the search turns whichever answered into shares of one.
/// With no fallback the database answers wherever it has a game and the
/// search stops where it has none.
/// A database that cannot be asked stops the search: a lost connection is
/// not a reason to change the opponent.
///
/// A position is asked about once, since a run meets many positions twice.
final class DatabaseOpponent implements OpponentPolicy {
  DatabaseOpponent({
    required this.name,
    required PlayedAt played,
    this.fallback,
    this.fallbackUnder = 1,
  }) : _played = played;

  /// What the database is called, for the sentence said when it is empty.
  final String name;
  final PlayedAt _played;
  final OpponentPolicy? fallback;
  final int fallbackUnder;
  final _asked = <String, Future<PolicyResult>>{};

  @override
  Future<PolicyResult> policyFor(Position position) =>
      _asked[Fen(position.fen).position] ??= _ask(position);

  Future<PolicyResult> _ask(Position position) async {
    final lookup = await _played(Fen(position.fen));
    if (lookup is! PlayedFound) {
      return PolicyUnavailable((lookup as PlayedUnavailable).reason);
    }
    final (:policy, :games) = playedPolicy(position, lookup.moves);
    final fallback = this.fallback;
    if (fallback != null && games < fallbackUnder) {
      return switch (await fallback.policyFor(position)) {
        PolicyFound(:final policy) => PolicyFound(
          policy,
          from: RepliesFrom.maia,
        ),
        final PolicyUnavailable unavailable => unavailable,
      };
    }
    if (games == 0) {
      return PolicyUnavailable('$name has no games at this position');
    }
    return PolicyFound(policy, from: RepliesFrom.games);
  }
}

/// Lichess's explorer, narrowed as [choice] says, asked for the replies.
PlayedAt lichessPlayed(LichessExplorer explorer, ExplorerChoice choice) =>
    (fen) async => switch (await explorer.fetch(ExplorerQuery(fen, choice))) {
      ExplorerFetched(:final answer) => PlayedFound([
        for (final move in answer.moves) (uci: move.uci, games: move.games),
      ]),
      ExplorerNotFetched(:final sentence) => PlayedUnavailable(sentence),
    };

/// The master games on this machine, asked for the replies.
PlayedAt twicPlayed(MasterBook book) =>
    (fen) async => switch (await book.lookup(fen, classicalOnly: false)) {
      BookFound(:final answer) => PlayedFound([
        for (final move in answer.moves) (uci: move.uci, games: move.games),
      ]),
      BookAbsent() => const PlayedUnavailable(
        'There are no TWIC games on this computer. Get them in Databases.',
      ),
      BookUnreadable() || BookClassicalIncomplete() => const PlayedUnavailable(
        'The TWIC games on this computer could not be read.',
      ),
    };

/// The opponent [request] asks for: Maia, or a database with Maia behind
/// it where the request says so.
OpponentPolicy opponentFor(
  FillRequest request, {
  required MovePolicy maia,
  required LichessExplorer explorer,
  required MasterBook book,
}) {
  final model = MaiaOpponent(maia, elo: request.elo);
  final played = switch (request.replies) {
    ReplySource.maia => null,
    ReplySource.masters => lichessPlayed(
      explorer,
      const ExplorerChoice(source: ExplorerSource.masters),
    ),
    ReplySource.lichess => lichessPlayed(explorer, request.lichess),
    ReplySource.twic => twicPlayed(book),
  };
  if (played == null) return model;
  final under = request.fallbackUnder;
  return DatabaseOpponent(
    name: request.replies.label,
    played: played,
    fallback: under == null ? null : model,
    fallbackUnder: under ?? 1,
  );
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

/// What the engine said during one owner's searches that the tree does not
/// keep: the depth each score was reached at, and the engine's best line.
/// Only answers the evaluator actually supplied are recorded — a cached
/// score has no line — and both are session-local: a saved tree records
/// neither.
///
/// Keyed by the four-field position, since neither depends on the clocks.
///
/// A position is asked about once: a run searches the board for both sides
/// at the same time, the two meet many of the same positions, and both
/// must hold the one score for each.
final class EngineAnswers implements PositionEvaluator {
  EngineAnswers(this.evaluator, {required this.depths, required this.lines});

  final PositionEvaluator evaluator;
  final Map<String, int> depths;
  final Map<String, List<String>> lines;
  final _asked = <String, Future<EvaluationResult>>{};

  @override
  Future<EvaluationResult> evaluate(Position position) =>
      _asked[position.fen] ??= _ask(position);

  Future<EvaluationResult> _ask(Position position) async {
    final result = await evaluationOf(evaluator, position);
    if (result case Evaluated(:final depth, :final pv)) {
      final key = Fen(position.fen).position;
      if (depth != null) depths[key] = depth;
      if (pv.isNotEmpty) lines[key] = pv;
    }
    return result;
  }
}
