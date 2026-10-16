/// What the lab's per-board tables and the engine switch show: the scores
/// by move, a completed table's save, the engine's lines and its trouble, and
/// how a board's table orders its rows.
///
/// These are values, so they live apart from the owner that produces them and
/// a widget can be written against them alone.
library;

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../engines/hivemind_engine.dart';

/// Scores by board and move, A + B's side, with the line after each.
typedef ScoreMap = Map<(BoardNumber, String), ({TableScore score, String pv})>;

/// Where the per-board tables' numbers stand.
sealed class TableScores {
  const TableScores();

  ScoreMap get scores => const {};
}

/// Nothing yet: the book is being read.
final class ScoresWaiting extends TableScores {
  const ScoresWaiting();
}

/// The book does not have the position for this clock and the engine is
/// off: every move unscored.
final class ScoresNone extends TableScores {
  const ScoresNone();
}

/// The precomputed book has the position: every move scored at once.
final class ScoresFromBook extends TableScores {
  const ScoresFromBook(this.scores, {this.provenance = const {}});

  final Map<String, Object?> provenance;

  @override
  final ScoreMap scores;
}

/// The book does not have it, so the engine is scoring every move, the
/// likeliest first: [done] of [total] so far. It goes into the book when
/// the last is scored.
final class ScoresSearched extends TableScores {
  const ScoresSearched(this.scores, {required this.done, required this.total});

  @override
  final ScoreMap scores;
  final int done;
  final int total;

  bool get finished => done >= total;
}

/// A complete table is saved only once the book confirms its commit.
sealed class AnalysisSave {
  const AnalysisSave();
}

final class AnalysisSaving extends AnalysisSave {
  const AnalysisSaving();
}

final class AnalysisSaveDiscarded extends AnalysisSave {
  const AnalysisSaveDiscarded();
}

final class AnalysisSaved extends AnalysisSave {
  const AnalysisSaved();
}

final class AnalysisSaveFailed extends AnalysisSave {
  const AnalysisSaveFailed(this.detail);

  final String detail;
}

/// Why the engine could not answer, in the engine's own words.
sealed class EngineTrouble {
  const EngineTrouble(this.reason);

  final String reason;
}

/// It would not start.
final class EngineNotStarted extends EngineTrouble {
  const EngineNotStarted(super.reason);
}

/// A search failed: the engine went away or stopped answering.
final class SearchFailed extends EngineTrouble {
  const SearchFailed(super.reason);
}

/// What the engine switch shows: nothing while it is off; while it is on,
/// each team's best joint actions from the last pass that finished, and how
/// long the pass under way thinks for each team.
sealed class EngineLines {
  const EngineLines();
}

final class LinesOff extends EngineLines {
  const LinesOff();
}

/// On: [lines] from the last pass over [position] — empty until the first
/// ends — and [thinking], the pass under way, null once the longest has
/// finished and the engine rests until the table changes.
final class LinesOn extends EngineLines {
  const LinesOn({
    required this.position,
    this.lines = const {},
    this.zero = ZeroSource.assumed,
    this.thinking,
  });

  final TablePosition position;
  final Map<Team, TeamLines> lines;
  final ZeroSource zero;

  final HivemindBudget? thinking;
}

/// The engine is on but could not answer; it stays so until switched on
/// again.
final class LinesStopped extends EngineLines {
  const LinesStopped(this.trouble);

  final EngineTrouble trouble;
}

/// One team's side of a pass: its advantage, A + B's side, and up to three
/// joint actions with each one's score. A team with no move on either
/// board has no lines.
typedef TeamLines = ({
  TableScore advantage,
  List<({JointMove move, TableScore score})> rows,
});

/// A row of a board's table: a legal move and its score from the mover's
/// side, with the line after it.
typedef ScoredMove = ({TableMove move, TableScore score, String pv});

/// Every legal move on [board], scored ones first, best for the mover at
/// the top, then the rest by SAN.
List<ScoredMove> tableRows(
  TablePosition position,
  BoardNumber board,
  ScoreMap scores,
) {
  final mover = position.mover(board).team;
  final rows = [
    for (final move in position.legalMoves(board))
      if (scores[(board, move.uci)] case final scored?)
        (move: move, score: scored.score.forTeam(mover), pv: scored.pv)
      else
        (move: move, score: const TableScore(), pv: ''),
  ];
  rows.sort((a, b) {
    final byScore = b.score.strength.compareTo(a.score.strength);
    return byScore != 0 ? byScore : a.move.san.compareTo(b.move.san);
  });
  return rows;
}
