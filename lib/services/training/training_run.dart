/// What one sitting of training covers, and which line comes next.
///
/// [TrainingSessionController] used to answer this inline, tangled with
/// drilling and persistence, in six methods over two fields. Pulled out
/// because it is where the subtle decisions live and none of them need a
/// board, a file or a notifier:
///
///  1. *What is in this sitting?* — the run scope, fixed when the run starts
///     so that finishing a line cannot pull a fresh one in behind it and a
///     session over a 900-line course actually ends.
///  2. *Is this line still part of it?* — which is not the same question as
///     "does it still match the intent"; see [includes].
///  3. *What comes after this one?* — queue order, wrapping around.
///  4. *Why did it end?* — hitting the sitting's own cap and running out of
///     chapter deserve different sentences.
///
/// Reads the owner's mutable state through suppliers, as [ChapterScope] does:
/// the repetition mode and the settings are reassigned when the user changes
/// them, and a cached copy would strand a run under the previous rules.
library;

import '../../models/line_status.dart';
import '../../models/repertoire_line.dart';
import '../../models/repertoire_review_entry.dart' show RepertoireReviewEntry;
import '../../models/training_settings.dart';

class TrainingRun {
  TrainingRun({
    required RepetitionMode Function() repetitionMode,
    required TrainingSettings Function() settings,
    required Map<String, RepertoireReviewEntry> Function() reviewMap,
  }) : _repetitionMode = repetitionMode,
       _settings = settings,
       _reviewMap = reviewMap;

  final RepetitionMode Function() _repetitionMode;
  final TrainingSettings Function() _settings;
  final Map<String, RepertoireReviewEntry> Function() _reviewMap;

  /// Line ids this sitting will work through, or null for an uncapped run.
  ///
  /// A line failed mid-run stays in scope until it comes back clean.
  Set<String>? _scope;

  /// Whether the sitting stopped because it hit its own cap rather than
  /// because the chapter ran out — a different sentence, and a different
  /// offer, at the end.
  bool _wasCapped = false;

  /// True while this sitting is limited to a fixed set of lines.
  bool get isCapped => _scope != null;

  /// Forget the scope: the run is over, or the user picked a specific line
  /// and so is no longer inside the set the buttons chose.
  void clear() {
    _scope = null;
    _wasCapped = false;
  }

  /// Fix the set of lines this sitting covers, from the head of [queue].
  ///
  /// Linear mode is uncapped on purpose: "every line once, in order" is what
  /// the mode *is*, and stopping it a tenth of the way through would make its
  /// "Set complete!" a lie. A cap of zero or less means the cap is off.
  void begin(List<RepertoireLine> queue, TrainingIntent intent) {
    _wasCapped = false;
    if (_repetitionMode() == RepetitionMode.linear) {
      _scope = null;
      return;
    }
    final settings = _settings();
    final cap = intent == TrainingIntent.learn
        ? settings.newLinesPerSession
        : settings.reviewsPerSession;
    if (cap <= 0) {
      _scope = null;
      return;
    }

    final picked = <String>{};
    for (final line in queue) {
      if (!matchesIntent(line, intent)) continue;
      picked.add(line.id);
      if (picked.length >= cap) break;
    }
    _wasCapped = picked.length >= cap;
    _scope = picked;
  }

  /// Whether [line] is still part of the run in progress.
  bool includes(RepertoireLine line, TrainingIntent intent) {
    // Linear mode runs every queued line once, in order — there is no
    // untrained/due split to honour.
    if (_repetitionMode() == RepetitionMode.linear) return true;
    final scope = _scope;
    if (scope == null) return matchesIntent(line, intent);
    if (!scope.contains(line.id)) return false;
    // Inside the sitting's own set, "not learned yet" is the test. Rating a
    // new line Again moves it out of *untrained*, so the strict intent match
    // would have dropped it from the run you are in the middle of — exactly
    // the line you most need to see again.
    return _statusOf(line) != LineStatus.learned;
  }

  /// Whether [line]'s own status is what [intent] is looking for, ignoring
  /// any run in progress.
  bool matchesIntent(RepertoireLine line, TrainingIntent intent) {
    final status = _statusOf(line);
    return intent == TrainingIntent.learn
        ? status == LineStatus.untrained
        : status == LineStatus.due;
  }

  LineStatus _statusOf(RepertoireLine line) =>
      lineStatusOf(_reviewMap()[line.id]);

  /// The next line matching [intent], starting after [afterLineId] in queue
  /// order and wrapping around. Null when [queue] holds no such line.
  RepertoireLine? next(
    List<RepertoireLine> queue,
    TrainingIntent intent, {
    String? afterLineId,
  }) {
    if (queue.isEmpty) return null;

    final startIndex = afterLineId == null
        ? -1
        : queue.indexWhere((l) => l.id == afterLineId);
    if (startIndex < 0) {
      for (final line in queue) {
        if (includes(line, intent)) return line;
      }
      return null;
    }
    for (int step = 1; step <= queue.length; step++) {
      final line = queue[(startIndex + step) % queue.length];
      if (includes(line, intent)) return line;
    }
    return null;
  }

  /// Lines still ahead in this run — what the Train tab counts down.
  int remaining(List<RepertoireLine> queue, TrainingIntent intent) =>
      _repetitionMode() == RepetitionMode.linear
      ? queue.length
      : queue.where((line) => includes(line, intent)).length;

  /// What to say when the run has nothing left.
  String completeMessage(TrainingIntent intent) {
    if (_repetitionMode() == RepetitionMode.linear) return 'Set complete!';
    if (_wasCapped) {
      return intent == TrainingIntent.learn
          ? 'That is this sitting\'s new lines — nicely done.'
          : 'Review session done.';
    }
    return intent == TrainingIntent.learn
        ? 'Nothing left to learn here.'
        : 'All caught up!';
  }
}
