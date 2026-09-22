import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../chess/training/drill.dart';
import '../../chess/training/records.dart';
import '../../chess/training/schedule.dart';
import '../../chess/training/sitting.dart';
import '../../chess/training/training_line.dart';
import '../../storage/training_rows.dart' show asWritten;
import '../../storage/training_store.dart';

/// The clock and the dice a trainer runs on, handed in so a test can fix
/// both: the time now, and a number in −1..1 that spreads an interval.
typedef TrainerTime = ({DateTime Function() now, double Function() jitter});

/// What is recorded for the lines of one scope — their schedule, their
/// moves' streaks and the wrong answers given in them — and every change
/// to it.
///
/// Writes go out one after another, each naming what its rows held when
/// they were last read or written here. When another session changed one of
/// them, the write is refused and [stale] says the scope must be read again
/// before anything else is written.
class TrainingProgress extends ChangeNotifier {
  TrainingProgress({
    required ProgressFiles files,
    required ProgressLoaded loaded,
    required TrainerTime time,
  }) : _files = files,
       _time = time,
       _reviews = {...loaded.reviews},
       _streaks = {...loaded.streaks},
       _saved = {...loaded.streaks},
       _mistakes = [...loaded.mistakes];

  final ProgressFiles _files;
  final TrainerTime _time;
  final Map<LineKey, Review> _reviews;

  /// Each move's streak now, and as the file last had it: answers change the
  /// first at once and reach the file with the line's outcome.
  final Map<StreakKey, MoveStreak> _streaks;
  final Map<StreakKey, MoveStreak> _saved;
  final List<Attempt> _mistakes;
  Future<void> _writes = Future.value();

  /// Line outcomes a write did not finish, for [retry].
  final _unsaved = <LineKey, _Outcome>{};
  bool _stale = false;
  bool _disposed = false;

  Map<LineKey, Review> get reviews => UnmodifiableMapView(_reviews);

  /// Wrong answers in the scope, newest first.
  List<Attempt> get mistakes => _mistakes.reversed.toList();

  /// Whether another session changed the progress under this one, which
  /// must be read again before it writes anything more.
  bool get stale => _stale;

  DateTime get now => _time.now().toUtc();

  LineStatus status(TrainingLine line) =>
      statusOf(line, _reviews[line.key], now);

  /// The line's row, or the row a line never trained starts with.
  Review reviewOf(TrainingLine line) =>
      _reviews[line.key] ?? Review(key: line.key, lineName: line.name);

  /// Logs one answer and counts it towards its move's streak — unless it
  /// was given while the line was being shown, which teaches, not tests.
  Future<ProgressWrite> answered(TrainingLine line, DrillAnswer answer) async {
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
    final result = await _files.logAttempt(attempt);
    if (result is ProgressWritten && !answer.correct && !_disposed) {
      _mistakes.add(attempt);
      notifyListeners();
    }
    return result;
  }

  /// Writes a finished line's rating, with the streaks its answers changed
  /// and a history row.
  Future<ProgressWrite> finished(
    TrainingLine line,
    Rating rating, {
    required bool clean,
  }) => _serially(() => _land(_outcome(line, rating, clean: clean)));

  /// Writes again, row for row, the outcome of [line] that did not all reach
  /// the files. The files are replaced one at a time, so some of its rows may
  /// be there already; working the outcome out afresh — a new time, a new
  /// spread — would make those rows look like somebody else's.
  Future<ProgressWrite> retry(TrainingLine line) => _serially(() {
    final outcome = _unsaved[line.key];
    if (outcome == null) return Future.value(const ProgressWritten());
    return _land(outcome);
  });

  _Outcome _outcome(TrainingLine line, Rating rating, {required bool clean}) {
    final after = asWritten(
      rated(
        reviewOf(line).copyWith(lineName: line.name),
        rating,
        now: now,
        clean: clean,
        jitter: _time.jitter(),
      ),
    );
    return (
      review: (before: _reviews[line.key], after: after),
      streaks: [
        for (final MapEntry(:key, :value) in _streaks.entries)
          if (key.line == line.key && _saved[key] != value)
            (before: _saved[key], after: value),
      ],
      history: HistoryRow(
        key: line.key,
        at: now,
        rating: rating.name,
        mistake: !clean,
        kind: HistoryKind.trainer,
      ),
    );
  }

  Future<ProgressWrite> _land(_Outcome outcome) async {
    final key = outcome.review.after.key;
    final result = await _write(
      reviews: [outcome.review],
      streaks: outcome.streaks,
      history: [outcome.history],
    );
    if (result is ProgressWritten) {
      _unsaved.remove(key);
    } else {
      _unsaved[key] = outcome;
    }
    return result;
  }

  /// Takes [line] out of every queue, or puts it back.
  Future<ProgressWrite> setExcluded(
    TrainingLine line, {
    required bool excluded,
  }) => _serially(
    () => _write(
      reviews: [
        (
          before: _reviews[line.key],
          after: asWritten(reviewOf(line).copyWith(excluded: excluded)),
        ),
      ],
    ),
  );

  /// Puts the untrained lines of [lines] on the schedule as known, or — when
  /// not [known] — the trained ones back to untrained.
  Future<ProgressWrite> mark(List<TrainingLine> lines, {required bool known}) =>
      _serially(() {
        final changes = <Change<Review>>[];
        final history = <HistoryRow>[];
        for (final line in lines) {
          final status = this.status(line);
          final trained =
              status == LineStatus.due || status == LineStatus.learned;
          if (known ? status != LineStatus.untrained : !trained) continue;
          final review = reviewOf(line);
          final after = known
              ? markedKnown(review, now: now, nth: changes.length)
              : markedUnknown(review);
          changes.add((before: _reviews[line.key], after: asWritten(after)));
          history.add(
            HistoryRow(
              key: line.key,
              at: now,
              rating: known ? Rating.good.name : '',
              mistake: false,
              kind: HistoryKind.marked,
            ),
          );
        }
        if (changes.isEmpty) return Future.value(const ProgressWritten());
        return _write(reviews: changes, history: history);
      });

  Future<ProgressWrite> _write({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
  }) async {
    if (_stale) return const ProgressConflict();
    final result = await _files.write(
      reviews: reviews,
      streaks: streaks,
      history: history,
    );
    switch (result) {
      case ProgressWritten():
        for (final change in reviews) {
          _reviews[change.after.key] = change.after;
        }
        for (final change in streaks) {
          final at = (line: change.after.key, ply: change.after.ply);
          _saved[at] = change.after;
        }
      case ProgressConflict():
        _stale = true;
      case ProgressUnreadable() || ProgressFailed():
        break;
    }
    if (!_disposed) notifyListeners();
    return result;
  }

  /// Runs [write] after every write asked for before it, so each one names
  /// the rows the one before it left.
  Future<ProgressWrite> _serially(Future<ProgressWrite> Function() write) {
    final done = _writes.then((_) => write());
    _writes = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Everything one finished line writes.
typedef _Outcome = ({
  Change<Review> review,
  List<Change<MoveStreak>> streaks,
  HistoryRow history,
});
