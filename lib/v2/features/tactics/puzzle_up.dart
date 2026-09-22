import '../../chess/pgn/game_tree.dart';
import '../../chess/tactics/puzzle.dart';
import '../../chess/tactics/puzzle_run.dart';

/// What the last thing the user did to the puzzle came to.
sealed class Feedback {
  const Feedback();
}

/// A right move of an answer with more to find: [found] of [of].
final class Correct extends Feedback {
  const Correct(this.found, this.of);

  final int found;
  final int of;
}

/// [san] is not the move.
final class Incorrect extends Feedback {
  const Incorrect(this.san);

  final String san;
}

final class Solved extends Feedback {
  const Solved();
}

/// The answer was shown; [rest] is what was left of it to find.
final class Revealed extends Feedback {
  const Revealed(this.rest);

  final List<String> rest;
}

/// The puzzle on the board and how far the user has got with it.
final class PuzzleUp {
  const PuzzleUp({
    required this.puzzle,
    required this.startedAt,
    this.frontier = const NodePath.root(),
    this.found = 0,
    this.feedback,
    this.waiting = false,
    this.finished = false,
    this.decided,
    this.stars,
    this.saveProblem,
  });

  /// [puzzle] at its position, the clock started [at]. A puzzle put up again
  /// keeps the attempt it had: the first one is the one that counts.
  factory PuzzleUp.start(
    Puzzle puzzle, {
    required DateTime at,
    Outcome? decided,
  }) => PuzzleUp(puzzle: puzzle, startedAt: at, decided: decided);

  final Puzzle puzzle;

  /// When the clock for this attempt started: the puzzle came up or was
  /// reset.
  final DateTime startedAt;

  /// The last move of the answer on the board; the root before the first.
  final NodePath frontier;

  /// How many moves of the answer are on the board, both sides'.
  final int found;

  final Feedback? feedback;

  /// The opponent's reply is on its way; the board takes no move meanwhile.
  final bool waiting;

  /// Solved or shown: the answer is on view and nothing more is judged.
  final bool finished;

  /// How the first attempt went, once there has been one.
  final Outcome? decided;

  /// The rating given since the puzzle came up; null for the file's own.
  final int? stars;

  /// Why the result could not be written into the set, or null.
  final String? saveProblem;

  /// The solver's moves found so far.
  int get userMovesFound => (found + 1) ~/ 2;

  int get rating => stars ?? puzzle.stats.stars;

  /// One more move of the answer on the board, at [path].
  PuzzleUp advanced(NodePath path) =>
      copyWith(frontier: path, found: found + 1);

  PuzzleUp copyWith({
    NodePath? frontier,
    int? found,
    Feedback? feedback,
    bool? waiting,
    bool? finished,
    Outcome? decided,
    int? stars,
    String? saveProblem,
  }) => PuzzleUp(
    puzzle: puzzle,
    startedAt: startedAt,
    frontier: frontier ?? this.frontier,
    found: found ?? this.found,
    feedback: feedback ?? this.feedback,
    waiting: waiting ?? this.waiting,
    finished: finished ?? this.finished,
    decided: decided ?? this.decided,
    stars: stars ?? this.stars,
    saveProblem: saveProblem ?? this.saveProblem,
  );
}
