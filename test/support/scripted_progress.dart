import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/storage/training_store.dart';

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

  final _queued = <ProgressOperation, Future<ProgressWrite> Function()>{};
  final _committed = <ProgressOperation>{};

  @override
  Future<ProgressAdmission> enqueueWrite({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    required ProgressOperation operation,
  }) async {
    final keptReviews = List<Change<Review>>.unmodifiable(reviews);
    final keptStreaks = List<Change<MoveStreak>>.unmodifiable(streaks);
    final keptHistory = List<HistoryRow>.unmodifiable(history);
    _queued.putIfAbsent(
      operation,
      () =>
          () => write(
            reviews: keptReviews,
            streaks: keptStreaks,
            history: keptHistory,
            operation: operation,
          ),
    );
    return const ProgressEnqueued();
  }

  @override
  Future<ProgressAdmission> enqueueAttempt(
    Attempt attempt, {
    required ProgressOperation operation,
  }) async {
    _queued.putIfAbsent(
      operation,
      () =>
          () => logAttempt(attempt, operation: operation),
    );
    return const ProgressEnqueued();
  }

  @override
  Future<ProgressWrite> commit(ProgressOperation operation) async {
    if (_committed.contains(operation)) return const ProgressWritten();
    // A write answered with what the test scripted was never taken, as the
    // store answers for a change it did not accept.
    final queued = _queued[operation];
    if (queued == null) {
      return const ProgressFailed('This training change was not accepted.');
    }
    final result = await queued();
    if (result is ProgressWritten) _committed.add(operation);
    return result;
  }

  @override
  Future<ProgressRead> read(
    Set<String> sources, {
    Map<String, Revision>? observed,
  }) async {
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
    ProgressOperation? operation,
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
  Future<ProgressWrite> logAttempt(
    Attempt attempt, {
    ProgressOperation? operation,
  }) async {
    if (logAs case final failure?) return failure;
    attempts.add(attempt);
    return const ProgressWritten();
  }
}
