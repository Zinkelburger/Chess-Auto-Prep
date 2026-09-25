import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../chess/training/drill.dart';
import '../../chess/training/records.dart';
import '../../chess/training/schedule.dart';
import '../../chess/training/sitting.dart';
import '../../chess/training/training_line.dart';
import '../../storage/training_rows.dart' show asWritten;
import '../../storage/training_store.dart';
import '../../storage/document_ref.dart';
import '../../storage/pending_writes.dart';

/// The clock and the dice a trainer runs on, handed in so a test can fix both.
typedef TrainerTime = ({DateTime Function() now, double Function() jitter});

/// The progress displayed by one scope. The app registry owns accepted
/// mutations: it keeps them in order, including after this scope is disposed.
/// Rows are captured against the private projected result of preceding accepted
/// commands. Enqueue persists them before publication waits on predecessors;
/// displayed rows change only after the store acknowledges a commit.
class TrainingProgress extends ChangeNotifier {
  TrainingProgress({
    required this._files,
    required ProgressLoaded loaded,
    required this._time,
    PendingWrites? pendingWrites,
  }) : pendingWrites = pendingWrites ?? PendingWrites(),
       _sources = Map.of(loaded.sources),
       _reviews = {...loaded.reviews},
       _projectedReviews = {...loaded.reviews},
       _projectedSaved = {...loaded.streaks},
       _streaks = {...loaded.streaks},
       _mistakes = [...loaded.mistakes];

  final ProgressFiles _files;
  final Map<String, Revision> _sources;
  final PendingWrites pendingWrites;
  final TrainerTime _time;
  final Map<LineKey, Review> _reviews;
  final Map<LineKey, Review> _projectedReviews;
  final Map<StreakKey, MoveStreak> _projectedSaved;
  final Map<StreakKey, MoveStreak> _streaks;
  final List<Attempt> _mistakes;
  ProgressOperation? _lastAccepted;
  bool _stale = false;
  bool _disposed = false;
  bool _suspended = false;

  void suspend() => _suspended = true;
  void resume() => _suspended = false;

  /// Acknowledged own edits can refresh future commands without ending a
  /// lesson. Already accepted operations keep their original source snapshot.
  /// An equal-text external replacement never satisfies the native before.
  bool documentSaved(String path, Revision before, Revision after) {
    final source = _sources[path];
    if (source == null) return true; // A scripted adapter supplies no proof.
    if (source != before ||
        source.nativeIdentity != before.nativeIdentity ||
        after.nativeIdentity == null) {
      return false;
    }
    _sources[path] = after;
    return true;
  }

  Map<LineKey, Review> get reviews => UnmodifiableMapView(_reviews);
  List<Attempt> get mistakes => _mistakes.reversed.toList();
  bool get stale => _stale;
  DateTime get now => _time.now().toUtc();

  LineStatus status(TrainingLine line) =>
      statusOf(line, _reviews[line.key], now);

  Review reviewOf(TrainingLine line) =>
      _reviews[line.key] ?? Review(key: line.key, lineName: line.name);

  Review _projectedReview(TrainingLine line) =>
      _projectedReviews[line.key] ?? Review(key: line.key, lineName: line.name);

  /// Answers change the in-memory streak immediately; its rating captures it.
  /// Logging uses a separate operation token so an unknown append is not replayed.
  Future<ProgressWrite> answered(TrainingLine line, DrillAnswer answer) {
    if (_disposed || _suspended) {
      return Future.value(
        ProgressFailed(
          _suspended
              ? 'The training source is being saved.'
              : 'This training scope is closed.',
        ),
      );
    }
    final attempt = Attempt(
      key: line.key,
      ply: answer.ply,
      fen: answer.fen,
      played: answer.played,
      expected: answer.expected,
      correct: answer.correct,
      phase: answer.phase,
      at: now,
    );
    if (answer.phase != AttemptPhase.learning) {
      final at = (line: line.key, ply: answer.ply);
      _streaks[at] = streakAfter(
        _streaks[at],
        key: line.key,
        ply: answer.ply,
        correct: answer.correct,
      );
    }
    final operation = _operation();
    return _submit(
      () => _files.enqueueAttempt(attempt, operation: operation),
      () async {
        final result = await _files.commit(operation);
        if (result is ProgressWritten && !answer.correct) {
          _mistakes.add(attempt);
          if (!_disposed) notifyListeners();
        }
        return result;
      },
    );
  }

  /// A rating's time, spread and answered moves are fixed before any wait.
  /// Its starting review is the one preceding accepted ratings leave behind.
  Future<ProgressWrite> finished(
    TrainingLine line,
    Rating rating, {
    required bool clean,
  }) async {
    if (_disposed || _suspended) {
      return ProgressFailed(
        _suspended
            ? 'The training source is being saved.'
            : 'This training scope is closed.',
      );
    }
    final at = now;
    final spread = _time.jitter();
    final answers = Map<StreakKey, MoveStreak>.of(_streaks);
    final earlier = pendingWrites.unfinished(_files).isNotEmpty;
    final result = await _mutation(() {
      final before = _projectedReviews[line.key];
      final after = asWritten(
        rated(
          (before ?? _projectedReview(line)).copyWith(lineName: line.name),
          rating,
          now: at,
          clean: clean,
          jitter: spread,
        ),
      );
      return (
        reviews: [(before: before, after: after)],
        streaks: [
          for (final MapEntry(:key, :value) in answers.entries)
            if (key.line == line.key && _projectedSaved[key] != value)
              (before: _projectedSaved[key], after: value),
        ],
        history: [
          HistoryRow(
            key: line.key,
            at: at,
            rating: rating.name,
            mistake: !clean,
            kind: HistoryKind.trainer,
          ),
        ],
      );
    });
    // Rating another line is also a request to land its preceding accepted
    // progress. Exact tokens make this safe even after an uncertain result.
    return result is! ProgressWritten && earlier ? retry() : result;
  }

  /// A failed predecessor owns the files until reconciled, even if it logged
  /// another line's answer. Retry the queue in order rather than skipping it.
  Future<ProgressWrite> retry() async {
    await pendingWrites.retry(_files);
    final entry = pendingWrites.unfinished(_files).firstOrNull;
    return entry == null
        ? const ProgressWritten()
        : entry.result is ProgressWrite
        ? entry.result as ProgressWrite
        : ProgressFailed(entry.detail);
  }

  Future<ProgressWrite> setExcluded(
    TrainingLine line, {
    required bool excluded,
  }) => _mutation(
    () => (
      reviews: [
        (
          before: _projectedReviews[line.key],
          after: asWritten(_projectedReview(line).copyWith(excluded: excluded)),
        ),
      ],
      streaks: const [],
      history: const [],
    ),
  );

  /// The request's date is fixed now; training status follows earlier accepted
  /// changes, so mark-known followed by exclude cannot undo its own new row.
  Future<ProgressWrite> mark(List<TrainingLine> lines, {required bool known}) {
    final selected = List<TrainingLine>.of(lines);
    final at = now;
    return _mutation(() {
      final changes = <Change<Review>>[];
      final history = <HistoryRow>[];
      for (final line in selected) {
        final status = statusOf(line, _projectedReviews[line.key], at);
        final trained =
            status == LineStatus.due || status == LineStatus.learned;
        if (known ? status != LineStatus.untrained : !trained) continue;
        final review = _projectedReview(line);
        final after = known
            ? markedKnown(review, now: at, nth: changes.length)
            : markedUnknown(review);
        changes.add((
          before: _projectedReviews[line.key],
          after: asWritten(after),
        ));
        history.add(
          HistoryRow(
            key: line.key,
            at: at,
            rating: known ? Rating.good.name : '',
            mistake: false,
            kind: HistoryKind.marked,
          ),
        );
      }
      return (reviews: changes, streaks: const [], history: history);
    });
  }

  Future<ProgressWrite> _mutation(_Rows Function() prepare) {
    if (_disposed || _suspended) {
      return Future.value(
        ProgressFailed(
          _suspended
              ? 'The training source is being saved.'
              : 'This training scope is closed.',
        ),
      );
    }
    final prepared = prepare();
    final rows = (
      reviews: List<Change<Review>>.unmodifiable(prepared.reviews),
      streaks: List<Change<MoveStreak>>.unmodifiable(prepared.streaks),
      history: List<HistoryRow>.unmodifiable(prepared.history),
    );
    if (rows.reviews.isEmpty && rows.streaks.isEmpty && rows.history.isEmpty) {
      return Future.value(const ProgressWritten());
    }
    for (final change in rows.reviews) {
      _projectedReviews[change.after.key] = change.after;
    }
    for (final change in rows.streaks) {
      _projectedSaved[(line: change.after.key, ply: change.after.ply)] =
          change.after;
    }
    final operation = _operation();
    return _submit(
      () => _files.enqueueWrite(
        reviews: rows.reviews,
        streaks: rows.streaks,
        history: rows.history,
        operation: operation,
      ),
      () => _commit(rows, operation),
    );
  }

  ProgressOperation _operation() {
    final operation = ProgressOperation(
      sources: _sources,
      predecessorId: _lastAccepted?.id,
    );
    _lastAccepted = operation;
    return operation;
  }

  /// Enqueue is an independent read barrier even when this obligation cannot
  /// publish yet. A failed admission retries the same payload and operation.
  Future<ProgressWrite> _submit(
    Future<ProgressAdmission> Function() enqueue,
    Future<ProgressWrite> Function() commit,
  ) async {
    Future<ProgressAdmission> start() {
      final future = Future<ProgressAdmission>.sync(enqueue).catchError(
        (Object error) => ProgressRejected(ProgressFailed('$error')),
      );
      pendingWrites.watch(_files, future);
      return future;
    }

    final first = start();
    Future<ProgressAdmission>? admission = first;
    final result = await _accept(() async {
      final accepted = await (admission ??= start());
      if (accepted case ProgressRejected(:final result)) {
        admission = null;
        if (result is ProgressConflict) _stale = true;
        if (!_disposed) notifyListeners();
        return result;
      }
      return commit();
    }).run();
    // A blocked predecessor can prevent the work callback running at all.
    // Still settle enqueue, and make its failure retryable on the next run.
    if (await first is ProgressRejected) admission = null;
    return result;
  }

  Future<ProgressWrite> _commit(_Rows rows, ProgressOperation operation) async {
    final result = await _files.commit(operation);
    switch (result) {
      case ProgressWritten():
        _stale = false;
        for (final change in rows.reviews) {
          _reviews[change.after.key] = change.after;
        }
      case ProgressConflict():
        _stale = true;
      case ProgressUnreadable() || ProgressFailed():
        break;
    }
    if (!_disposed) notifyListeners();
    return result;
  }

  Future<void> settle() => pendingWrites.settleFor(_files);

  PendingObligation<ProgressWrite> _accept(
    Future<ProgressWrite> Function() write,
  ) => pendingWrites.accept(
    resource: _files,
    label: 'Training progress',
    blocked: () =>
        const ProgressFailed('An earlier training change has not been saved.'),
    work: () async {
      try {
        return await write();
      } on Object catch (error) {
        return ProgressFailed('$error');
      }
    },
    problem: (result) => switch (result) {
      ProgressWritten() => null,
      ProgressFailed(:final detail) => detail,
      ProgressConflict() => 'Progress changed in another session.',
      ProgressUnreadable(:final file) => 'Could not read $file.',
    },
  );

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

typedef _Rows = ({
  List<Change<Review>> reviews,
  List<Change<MoveStreak>> streaks,
  List<HistoryRow> history,
});
