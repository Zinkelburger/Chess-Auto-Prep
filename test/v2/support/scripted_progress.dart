import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';

/// Training progress held in memory, answering what the test scripts: the
/// rows a read finds, and what the next write or log says instead of
/// writing.
final class ScriptedProgress implements ProgressFiles {
  ScriptedProgress({Map<LineKey, Review> reviews = const {}, this.readAs})
    : reviews = {...reviews};

  final Map<LineKey, Review> reviews;
  final streaks = <StreakKey, MoveStreak>{};
  final history = <HistoryRow>[];

  /// Every review change a write landed, in order.
  final reviewChanges = <Change<Review>>[];
  final attempts = <Attempt>[];

  /// What [read] answers instead of the rows, when set.
  ProgressRead? readAs;

  /// What the next write answers instead of writing, once.
  ProgressWrite? nextWrite;

  /// What every log answers instead of logging, while set.
  ProgressWrite? logAs;

  var reads = 0;

  @override
  Future<ProgressRead> read(Set<String> sources) async {
    reads++;
    return readAs ??
        ProgressLoaded(
          reviews: {
            for (final r in reviews.values)
              if (sources.contains(r.key.source)) r.key: r,
          },
          streaks: {...streaks},
          mistakes: [
            for (final a in attempts)
              if (!a.correct && sources.contains(a.key.source)) a,
          ],
        );
  }

  @override
  Future<ProgressWrite> write({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
  }) async {
    final scripted = nextWrite;
    nextWrite = null;
    if (scripted != null) return scripted;
    reviewChanges.addAll(reviews);
    for (final change in reviews) {
      this.reviews[change.after.key] = change.after;
    }
    for (final change in streaks) {
      this.streaks[(line: change.after.key, ply: change.after.ply)] =
          change.after;
    }
    this.history.addAll(history);
    return const ProgressWritten();
  }

  @override
  Future<ProgressWrite> logAttempt(Attempt attempt) async {
    if (logAs case final failure?) return failure;
    attempts.add(attempt);
    return const ProgressWritten();
  }
}
