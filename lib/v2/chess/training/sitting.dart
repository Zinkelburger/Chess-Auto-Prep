import 'schedule.dart';
import 'training_line.dart';

/// Where a line stands with the user.
enum LineStatus {
  /// Never trained: learned, not reviewed.
  untrained,

  /// Trained and due now.
  due,

  /// Trained and not due yet.
  learned,

  /// Left out of every queue by the user.
  excluded,

  /// A whole game kept to be read, never drilled.
  game,
}

LineStatus statusOf(TrainingLine line, Review? review, DateTime now) {
  if (line.modelGame) return LineStatus.game;
  if (review == null) return LineStatus.untrained;
  if (review.excluded) return LineStatus.excluded;
  if (review.untrained) return LineStatus.untrained;
  return review.dueAt(now) ? LineStatus.due : LineStatus.learned;
}

/// The lines never trained, in file order: the order the author wrote them,
/// which is most likely first in a generated chapter.
List<TrainingLine> toLearn(
  List<TrainingLine> lines,
  Map<LineKey, Review> reviews,
  DateTime now,
) => [
  for (final line in lines)
    if (statusOf(line, reviews[line.key], now) == LineStatus.untrained) line,
];

/// The lines due now, the longest overdue first.
List<TrainingLine> dueNow(
  List<TrainingLine> lines,
  Map<LineKey, Review> reviews,
  DateTime now,
) {
  final due = [
    for (final line in lines)
      if (statusOf(line, reviews[line.key], now) == LineStatus.due) line,
  ];
  final never = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  DateTime dueOf(TrainingLine line) => reviews[line.key]?.due ?? never;
  // A stable sort, so lines due at once keep their file order.
  return [
    for (final (_, line)
        in (due.indexed.toList()..sort((a, b) {
          final byDue = dueOf(a.$2).compareTo(dueOf(b.$2));
          return byDue != 0 ? byDue : a.$1.compareTo(b.$1);
        })))
      line,
  ];
}

/// How many of [lines] stand where.
Map<LineStatus, int> countsOf(
  List<TrainingLine> lines,
  Map<LineKey, Review> reviews,
  DateTime now,
) {
  final counts = {for (final status in LineStatus.values) status: 0};
  for (final line in lines) {
    final status = statusOf(line, reviews[line.key], now);
    counts[status] = counts[status]! + 1;
  }
  return counts;
}
