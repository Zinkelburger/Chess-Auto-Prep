import '../fen.dart';
import 'schedule.dart';

/// How many right answers in a row make a move learned, as the old app
/// counts them. A streak stops there, so a move known for a year reads the
/// same as one known for a week.
const learnedStreak = 3;

/// One row of `repertoire_move_progress.csv`: how well one move of a line
/// is known. [ply] counts the line's moves from zero, both sides' moves.
final class MoveStreak {
  const MoveStreak({
    required this.key,
    required this.ply,
    required this.streak,
    required this.learned,
  });

  final LineKey key;
  final int ply;
  final int streak;
  final bool learned;

  @override
  bool operator ==(Object other) =>
      other is MoveStreak &&
      other.key == key &&
      other.ply == ply &&
      other.streak == streak &&
      other.learned == learned;

  @override
  int get hashCode => Object.hash(key, ply, streak, learned);
}

/// The streak of [key]'s move at [ply] after one more answer: one longer,
/// up to [learnedStreak], when it was [correct]; back to nothing when not.
MoveStreak streakAfter(
  MoveStreak? was, {
  required LineKey key,
  required int ply,
  required bool correct,
}) {
  final streak = correct ? _capped((was?.streak ?? 0) + 1) : 0;
  return MoveStreak(
    key: key,
    ply: ply,
    streak: streak,
    learned: streak >= learnedStreak,
  );
}

int _capped(int streak) => streak > learnedStreak ? learnedStreak : streak;

/// Which part of a lesson an answer was given in, as the attempt log
/// spells it.
enum AttemptPhase { learning, drilling, replaying }

/// One answer, right or wrong: a line of `repertoire_move_attempts.jsonl`.
/// Written as it is given, so a later right answer cannot hide a wrong one.
final class Attempt {
  const Attempt({
    required this.key,
    required this.ply,
    required this.fen,
    required this.played,
    required this.expected,
    required this.correct,
    required this.phase,
    required this.at,
  });

  final LineKey key;
  final int ply;

  /// The position the move was asked in.
  final Fen fen;

  /// The SAN the user played and the SAN the line plays.
  final String played;
  final String expected;

  /// Whether [played] reaches the position [expected] does, which is not
  /// the same as the two being spelled alike.
  final bool correct;
  final AttemptPhase phase;
  final DateTime at;
}

/// Why a history row was written, as `session_type` spells it.
enum HistoryKind { trainer, marked }

/// One row of `repertoire_review_history.csv`: a line was rated, or marked
/// known or unknown by hand. [rating] is empty for a line marked unknown.
final class HistoryRow {
  const HistoryRow({
    required this.key,
    required this.at,
    required this.rating,
    required this.mistake,
    required this.kind,
  });

  final LineKey key;
  final DateTime at;
  final String rating;
  final bool mistake;
  final HistoryKind kind;
}
