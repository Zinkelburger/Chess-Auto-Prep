/// What a planning question shows and what comes pre-ticked.
///
/// The sources return the moves worth showing; this lays what the planner
/// already knows about the user over them ([PlanKnowledge]: their chapters,
/// their games), adds the moves the user played that no source listed, orders
/// them and picks the defaults — one move at our own turn, every reply worth
/// setting up at the opponent's.
library;

import '../models/plan_models.dart';
import '../services/plan_knowledge.dart';

/// The rows of a question and the ones that start ticked.
typedef AssembledCandidates = ({
  List<PlanCandidate> candidates,
  Set<String> preselected,
});

class PlanCandidateAssembler {
  const PlanCandidateAssembler({
    required this.knowledge,
    required this.walksOwnGames,
    required this.chapterShare,
  });

  final PlanKnowledge knowledge;

  /// Whether the walk is of the user's own games ([PlanBasis.ownGames]).
  final bool walksOwnGames;

  /// Walking the book: an opponent reply at or above this share is ticked.
  final double chapterShare;

  /// Walking the book, the user's most-played move at their own turn is the
  /// default only once they have played here this often and this
  /// consistently.
  static const int ownPretickMinGames = 5;
  static const double ownPretickMinShare = 0.4;

  AssembledCandidates assemble(
    List<PlanCandidate> sourced, {
    required String fen,
    required bool ourMove,
    required int ownFloor,
  }) {
    var candidates = _overlayKnowledge(sourced, fen, ourMove);
    if (walksOwnGames) candidates = _ownGamesFirst(candidates, fen);
    return (
      candidates: candidates,
      preselected: ourMove
          ? _preselectOurMove(candidates, fen)
          : _preselectReplies(candidates, fen, ownFloor),
    );
  }

  List<PlanCandidate> _overlayKnowledge(
    List<PlanCandidate> candidates,
    String fen,
    bool ourMove,
  ) {
    final chapterMoves = ourMove
        ? knowledge.chapterMovesAt(fen)
        : const <String>{};
    OwnMoveShare? ownShareOf(String san) => ourMove
        ? knowledge.ownMoveAt(fen, san)
        : knowledge.ownReplyAt(fen, san);

    final out = <PlanCandidate>[];
    final seen = <String>{};
    for (final c in candidates) {
      final own = ownShareOf(c.san);
      out.add(
        c.copyWith(
          inChapters: chapterMoves.contains(c.san),
          ownShare: own?.share,
          ownGames: own?.games,
        ),
      );
      seen.add(c.san);
    }
    // A move the user plays that the sources did not list still deserves a row.
    for (final san in chapterMoves) {
      if (seen.add(san)) {
        final own = knowledge.ownMoveAt(fen, san);
        out.add(
          PlanCandidate(
            san: san,
            inChapters: true,
            ownShare: own?.share,
            ownGames: own?.games,
          ),
        );
      }
    }
    // Likewise anything that actually happened in their games (an offbeat
    // move of theirs, a reply Maia rates below its cut-off).
    for (final san in knowledge.ownCountsAt(fen).keys) {
      if (seen.add(san)) {
        final own = ownShareOf(san);
        out.add(
          PlanCandidate(san: san, ownShare: own?.share, ownGames: own?.games),
        );
      }
    }
    return out;
  }

  /// What the user actually played comes first, most often on top; the moves
  /// they never tried follow in the sources' order.
  List<PlanCandidate> _ownGamesFirst(
    List<PlanCandidate> candidates,
    String fen,
  ) {
    final ownCounts = knowledge.ownCountsAt(fen);
    final indexed = candidates.indexed.toList()
      ..sort((a, b) {
        final ca = ownCounts[a.$2.san] ?? 0;
        final cb = ownCounts[b.$2.san] ?? 0;
        if (ca != cb) return cb.compareTo(ca);
        return a.$1.compareTo(b.$1);
      });
    return [for (final (_, c) in indexed) c];
  }

  /// One move at our own turn: the chapter's move if it has one, else the
  /// user's most-played move here, else nothing.
  Set<String> _preselectOurMove(List<PlanCandidate> candidates, String fen) {
    final inChapters = candidates.where((c) => c.inChapters);
    if (inChapters.isNotEmpty) return {inChapters.first.san};
    final own = walksOwnGames
        // Walking their games: the move they played most is the default.
        ? candidates.where((c) => (c.ownGames ?? 0) > 0)
        // Their own most-played move, when they have played here enough.
        : candidates.where(
            (c) =>
                (c.ownGames ?? 0) >= ownPretickMinGames &&
                (c.ownShare ?? 0) >= ownPretickMinShare,
          );
    return {if (own.isNotEmpty) own.first.san};
  }

  /// Every reply worth setting up: met often enough in the user's games, or
  /// common enough in the book.
  Set<String> _preselectReplies(
    List<PlanCandidate> candidates,
    String fen,
    int ownFloor,
  ) {
    if (walksOwnGames) {
      final ownCounts = knowledge.ownCountsAt(fen);
      return {
        for (final c in candidates)
          if ((ownCounts[c.san] ?? 0) >= ownFloor) c.san,
      };
    }
    return {
      for (final c in candidates)
        if ((c.share ?? 0) >= chapterShare) c.san,
    };
  }
}
