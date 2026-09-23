import '../fen.dart';

/// How a puzzle of a run went, decided by the first attempt: the answer
/// found without a wrong move, or not.
enum Outcome { solved, failed }

/// One sitting of puzzles: the order they come in, which have been on the
/// board, and how each went. A value; each step returns the next run.
///
/// Puzzles are named by their position, as the old app names them, so a run
/// survives the set's file being written by the other app in between.
final class PuzzleRun {
  const PuzzleRun({
    required this.queue,
    this.seen = const [],
    this.outcomes = const {},
    this.seconds = const {},
    this.revealed = const {},
  });

  /// Every puzzle of the run, in the order they come.
  final List<Fen> queue;

  /// The puzzles that have been on the board, in the order they came.
  final List<Fen> seen;

  final Map<Fen, Outcome> outcomes;

  /// How long each decided puzzle took.
  final Map<Fen, double> seconds;

  /// The puzzles whose answer was shown before any attempt at them. Found
  /// after that, an answer proves nothing, so none of them is ever decided:
  /// the recap counts them skipped and a retry plays them again.
  final Set<Fen> revealed;

  /// The run with [puzzle] on the board.
  PuzzleRun shown(Fen puzzle) => seen.contains(puzzle)
      ? this
      : PuzzleRun(
          queue: queue,
          seen: [...seen, puzzle],
          outcomes: outcomes,
          seconds: seconds,
          revealed: revealed,
        );

  /// The run with [puzzle] decided, unless it already was or its answer
  /// was shown first: the first attempt is the one that counts.
  PuzzleRun decided(Fen puzzle, Outcome outcome, double took) =>
      outcomes.containsKey(puzzle) || revealed.contains(puzzle)
      ? this
      : PuzzleRun(
          queue: queue,
          seen: seen,
          outcomes: {...outcomes, puzzle: outcome},
          seconds: {...seconds, puzzle: took},
          revealed: revealed,
        );

  /// The run with [puzzle]'s answer shown. One already decided keeps its
  /// outcome.
  PuzzleRun revealedAt(Fen puzzle) =>
      outcomes.containsKey(puzzle) || revealed.contains(puzzle)
      ? this
      : PuzzleRun(
          queue: queue,
          seen: seen,
          outcomes: outcomes,
          seconds: seconds,
          revealed: {...revealed, puzzle},
        );

  /// Whether an attempt at [puzzle] still counts: it is not decided and
  /// its answer has not been shown.
  bool counts(Fen puzzle) =>
      !outcomes.containsKey(puzzle) && !revealed.contains(puzzle);

  /// The puzzle after [current]: the next one already shown when the user
  /// stepped back to [current], else the next that has not been on the
  /// board, or null at the end: a run never wraps round.
  Fen? after(Fen? current) {
    final shown = current == null ? -1 : seen.indexOf(current);
    if (shown >= 0 && shown + 1 < seen.length) return seen[shown + 1];
    final from = current == null ? 0 : queue.indexOf(current) + 1;
    for (final fen in queue.skip(from)) {
      if (!seen.contains(fen)) return fen;
    }
    // A puzzle put up from the list rather than the queue has no place in
    // it; what comes after it is the first the run has not shown.
    return current != null && !queue.contains(current) ? after(null) : null;
  }

  /// What the run came to.
  Recap get recap {
    final solved = outcomes.values.where((o) => o == Outcome.solved).length;
    final failed = outcomes.length - solved;
    return Recap(
      solved: solved,
      failed: failed,
      skipped: seen.length - outcomes.length,
      seconds: seconds.values.fold(0, (sum, s) => sum + s),
      retry: [
        for (final fen in seen)
          if (outcomes[fen] != Outcome.solved) fen,
      ],
    );
  }
}

/// A finished run in figures, and the puzzles worth another go: the failed
/// and the skipped, in the order they were shown.
final class Recap {
  const Recap({
    required this.solved,
    required this.failed,
    required this.skipped,
    required this.seconds,
    required this.retry,
  });

  final int solved;
  final int failed;

  /// Shown but never attempted: skipped, or the answer revealed first.
  final int skipped;

  /// Every attempt's time added up.
  final double seconds;

  final List<Fen> retry;

  int get attempted => solved + failed;

  /// Solved over attempted, 0 to 1; null when nothing was attempted.
  double? get accuracy => attempted == 0 ? null : solved / attempted;
}
