import '../../chess/pgn/move_label.dart';
import '../../chess/training/drill.dart';
import '../../chess/training/line_order.dart';
import '../../chess/training/schedule.dart';
import '../../chess/training/sitting.dart';
import '../../storage/training_store.dart';
import 'lesson.dart';
import 'trainer.dart';

/// The trainer's typed states in the words the tab shows.

String progressProblem(Object failure, {required String doing}) =>
    switch (failure) {
      ProgressConflict() =>
        'Training progress changed in another session. Reload before saving.',
      ProgressUnreadable(:final file, :final line) =>
        'Could not $doing: line $line of $file is not a row the trainer can '
            'read. Nothing was changed.',
      ProgressFailed(:final detail) => 'Could not $doing: $detail',
      _ => 'Could not $doing.',
    };

String emptyReason(NothingToTrain why) => switch (why) {
  NothingToTrain.noChapter => 'Open a repertoire chapter to train it.',
  NothingToTrain.studyChapter =>
    'Study chapters are not trained here. Open a repertoire chapter.',
};

/// The move a lesson is about, numbered as a book prints it: `5.Nf3`.
String numbered(Drill drill) => numberedMoves([drill.line.moves[drill.ply]]);

/// The one line that says what the lesson wants now.
String prompt(Lesson lesson) {
  final drill = lesson.drill;
  return switch (drill.stage) {
    Showing() => 'Remember ${numbered(drill)}',
    Missed() || Corrected() => 'Play ${numbered(drill)}',
    Asking() when drill.pass == Pass.replay =>
      'Replay — ${drill.replaying.length} left',
    Asking() => 'Your move',
    Answered() => drill.line.isYours(drill.ply) ? 'Correct' : 'Their move',
    Finished(:final clean) =>
      clean ? 'Line complete!' : 'Line complete — with mistakes.',
  };
}

String orderName(LineOrder order) => switch (order) {
  LineOrder.training => 'Training order',
  LineOrder.course => 'Course order',
  LineOrder.likely => 'Most likely first',
};

/// Why a sitting ended, in the old app's words.
String sittingOver(SittingKind kind) => switch (kind) {
  SittingKind.learn => "That is this sitting's new lines — nicely done.",
  SittingKind.review => 'Review session done.',
  SittingKind.line => 'Line done.',
};

String statusWord(LineStatus status, Review? review, DateTime now) =>
    switch (status) {
      LineStatus.untrained => 'Untrained',
      LineStatus.due => 'Due now',
      LineStatus.learned => 'Learned · in ${_days(review, now)}',
      LineStatus.excluded => 'Excluded',
      LineStatus.game => 'Game',
    };

String _days(Review? review, DateTime now) {
  final due = review?.due;
  if (due == null) return 'a while';
  return spanWords(due.difference(now).inMinutes / Duration.minutesPerDay);
}

/// A number of days as a button has room for: `now`, `1d`, `3w`, `4mo`.
String spanWords(double days) {
  if (days < 1 / 24) return 'now';
  if (days < 1) return '${(days * 24).round()}h';
  if (days < 14) return '${days.round()}d';
  if (days < 60) return '${(days / 7).round()}w';
  return '${(days / 30).round()}mo';
}

/// A rating button's label: the rating and what it schedules.
String ratingLabel(Rating rating, Review review) {
  final name = '${rating.name[0].toUpperCase()}${rating.name.substring(1)}';
  return '$name · ${spanWords(intervalFor(review, rating))}';
}
