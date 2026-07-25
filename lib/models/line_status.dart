/// One vocabulary for "where is this line in the training cycle".
///
/// The trainer used to call an unseen line "New" in one place, "unseen" in
/// another and "not started" in a third. Everything user-facing now goes
/// through [LineStatus] so the browser, the counts and the queue agree.
library;

import 'repertoire_line.dart';
import 'repertoire_review_entry.dart';

enum LineStatus {
  /// Never trained — what a Learn run works through.
  untrained,

  /// Trained before and scheduled for today (or overdue) — what a Review
  /// run works through.
  due,

  /// Trained and not due yet.
  learned,
}

extension LineStatusLabel on LineStatus {
  /// Noun shown on a line row. Deliberately not "New": a line the user
  /// imported months ago isn't new, it just hasn't been trained.
  String get label => switch (this) {
    LineStatus.untrained => 'Untrained',
    LineStatus.due => 'Due',
    LineStatus.learned => 'Learned',
  };

  /// Verb for the button that starts this line.
  String get actionLabel => switch (this) {
    LineStatus.untrained => 'Learn',
    LineStatus.due => 'Review',
    LineStatus.learned => 'Practice',
  };
}

LineStatus lineStatusOf(RepertoireReviewEntry? entry) {
  if (entry == null || entry.isNew) return LineStatus.untrained;
  return entry.isDue ? LineStatus.due : LineStatus.learned;
}

/// How many lines of a set sit in each [LineStatus].
class LineCounts {
  final int untrained;
  final int due;
  final int learned;

  const LineCounts({this.untrained = 0, this.due = 0, this.learned = 0});

  int get total => untrained + due + learned;
  bool get isEmpty => total == 0;

  /// Share of the set that is trained and not due (0–1) — the progress bar.
  double get learnedFraction => total == 0 ? 0 : learned / total;

  LineCounts operator +(LineCounts other) => LineCounts(
    untrained: untrained + other.untrained,
    due: due + other.due,
    learned: learned + other.learned,
  );
}

LineCounts countLines(
  Iterable<RepertoireLine> lines,
  Map<String, RepertoireReviewEntry> reviewMap,
) {
  int untrained = 0;
  int due = 0;
  int learned = 0;
  for (final line in lines) {
    switch (lineStatusOf(reviewMap[line.id])) {
      case LineStatus.untrained:
        untrained++;
      case LineStatus.due:
        due++;
      case LineStatus.learned:
        learned++;
    }
  }
  return LineCounts(untrained: untrained, due: due, learned: learned);
}
