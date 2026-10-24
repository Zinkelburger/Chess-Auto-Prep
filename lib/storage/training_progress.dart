import '../chess/training/records.dart';
import '../chess/training/schedule.dart';
import 'document_ref.dart';
import 'training_snapshot.dart';

/// A row as read and as it is to be written; `before` is null for a row the
/// file did not have.
typedef Change<T> = ({T? before, T after});

/// Where one move's streak lives: its line and its ply.
typedef StreakKey = ({LineKey line, int ply});

sealed class ProgressRead {
  const ProgressRead();
}

final class ProgressLoaded extends ProgressRead {
  const ProgressLoaded({
    required this.reviews,
    required this.streaks,
    required this.mistakes,
    this.sources = const {},
    this.snapshot,
  });

  final TrainingReadSet? snapshot;
  final Map<String, Revision> sources;
  final Map<LineKey, Review> reviews;
  final Map<StreakKey, MoveStreak> streaks;

  /// Wrong answers, oldest first.
  final List<Attempt> mistakes;
}

sealed class ProgressWrite {
  const ProgressWrite();
}

final class ProgressWritten extends ProgressWrite {
  const ProgressWritten();
}

/// The source document changed identity/version, or another session changed
/// a row this write would have replaced. Nothing new is published.
final class ProgressConflict extends ProgressWrite {
  const ProgressConflict();
}

/// A file holds something that is not its rows; nothing was written to any.
final class ProgressUnreadable implements ProgressRead, ProgressWrite {
  const ProgressUnreadable(this.file, this.line, {this.wholeFile = false});

  final String file;
  final int line;

  /// Whether the file holds no rows at all. A write refused by such a file
  /// stays queued, to land once it is repaired; one refused by a single
  /// unreadable row it replaces is settled for good.
  final bool wholeFile;
}

final class ProgressFailed implements ProgressRead, ProgressWrite {
  const ProgressFailed(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

sealed class ProgressAdmission {
  const ProgressAdmission();
}

final class ProgressEnqueued extends ProgressAdmission {
  const ProgressEnqueued();
}

final class ProgressRejected extends ProgressAdmission {
  const ProgressRejected(this.result);
  final ProgressWrite result;
}
