import 'dart:async';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/training/drill.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/chess/training/training_line.dart';
import 'package:chess_auto_prep/chess/training/training_options.dart';
import 'package:chess_auto_prep/features/trainer/lesson.dart';
import 'package:chess_auto_prep/features/trainer/progress.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/training_progress.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_progress.dart';

/// Two lines for White: the Ruy Lopez and the Italian.
const _chapter = '''
// Color: White

[Event "Ruy"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *

[Event "Italian"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 *
''';

const _source = '/repertoires/KID/Main.pgn';
final _now = DateTime.utc(2026, 9, 22, 12);

/// The moves the user plays in each line.
const _ruy = ['e2e4', 'g1f3', 'f1b5'];
const _italian = ['e2e4', 'g1f3', 'f1c4'];

void main() {
  late _GatedProgress files;
  late List<TrainingLine> lines;
  late TrainingProgress progress;

  setUp(() {
    files = _GatedProgress();
    lines = trainingLines(
      parseChapter(name: 'Main', text: _chapter),
      source: _source,
    );
  });

  /// A sitting of [kind] over [of], each line due for review unless [fresh].
  Lesson sitting(
    FakeAsync async,
    SittingKind kind,
    List<TrainingLine> of, {
    bool fresh = false,
    bool rateReviews = true,
  }) {
    if (!fresh) {
      for (final line in lines) {
        files.inner.reviews[line.key] = Review(
          key: line.key,
          lineName: line.name,
          intervalDays: 4,
          lastRating: 'good',
          due: _now.subtract(const Duration(hours: 1)),
        );
      }
    }
    late ProgressRead read;
    unawaited(files.read({_source}).then((r) => read = r));
    async.flushMicrotasks();
    progress = TrainingProgress(
      files: files,
      loaded: read as ProgressLoaded,
      time: (now: () => _now, jitter: () => 0),
    );
    addTearDown(progress.dispose);
    final lesson = Lesson(
      kind: kind,
      lines: of,
      progress: progress,
      options: TrainingOptions(rateReviews: rateReviews),
    );
    addTearDown(lesson.dispose);
    return lesson;
  }

  void play(FakeAsync async, Lesson lesson, List<String> moves) {
    for (final uci in moves) {
      lesson.play(uci);
      async.elapse(const Duration(seconds: 2));
    }
  }

  test('the board takes a move only while one is asked for', () {
    fakeAsync((async) {
      final lesson = sitting(async, SittingKind.learn, lines, fresh: true);
      expect(lesson.drill.stage, isA<Showing>());
      expect(lesson.claim.onMove, isNull, reason: 'a move being shown');

      lesson.next();
      expect(lesson.drill.stage, isA<Asking>());
      expect(lesson.claim.onMove, isNotNull);

      lesson.suspend();
      expect(lesson.claim.onMove, isNull, reason: 'away on a detour');
      lesson.resume();
      expect(lesson.claim.onMove, isNotNull);
    });
  });

  test('going on is only for a move being shown', () {
    fakeAsync((async) {
      final lesson = sitting(async, SittingKind.learn, lines, fresh: true);
      lesson.next();
      final asking = lesson.drill;
      lesson.next();
      expect(lesson.drill, same(asking));
      expect(lesson.drill.stage, isA<Asking>());
    });
  });

  test('a sitting away on a detour does not skip, exclude or restart', () {
    fakeAsync((async) {
      final lesson = sitting(async, SittingKind.review, lines);
      play(async, lesson, _ruy.take(1).toList());
      final shown = lesson.drill.shown;
      lesson.suspend();

      lesson.skip();
      expect(lesson.line.key, lines.first.key);
      lesson.restart();
      expect(lesson.drill.shown, shown);
      unawaited(lesson.exclude());
      async.flushMicrotasks();
      expect(lesson.line.key, lines.first.key);
      expect(files.inner.reviewChanges, isEmpty);
      expect(lesson.left, 1);
    });
  });

  test('a rating that did not save is not tried again while away', () {
    fakeAsync((async) {
      final lesson = sitting(async, SittingKind.review, lines);
      play(async, lesson, _ruy);
      files.inner.nextWrite = const ProgressFailed('disk full');
      lesson.rate(Rating.good);
      async.flushMicrotasks();
      expect(lesson.state, isA<LineNotSaved>());

      lesson.suspend();
      lesson.retry();
      async.flushMicrotasks();
      expect(lesson.state, isA<LineNotSaved>());
      expect(files.inner.reviewChanges, isEmpty);

      lesson.resume();
      lesson.retry();
      async.flushMicrotasks();
      expect(files.inner.reviewChanges, hasLength(1));
      expect(lesson.line.key, lines.last.key);
    });
  });

  test('a graded line whose save failed waits for Retry, even after a '
      'detour', () {
    fakeAsync((async) {
      final lesson = sitting(
        async,
        SittingKind.review,
        lines,
        rateReviews: false,
      );
      files.inner.nextWrite = const ProgressFailed('disk full');
      play(async, lesson, _ruy);
      async.flushMicrotasks();
      expect(lesson.state, isA<LineNotSaved>());

      lesson.suspend();
      lesson.resume();
      async.elapse(const Duration(seconds: 5));
      expect(lesson.state, isA<LineNotSaved>());
      expect(files.inner.reviewChanges, isEmpty);
      expect(lesson.line.key, lines.first.key);
    });
  });

  test('a sitting that is over stays over', () {
    fakeAsync((async) {
      final lesson = sitting(async, SittingKind.line, [lines.first]);
      play(async, lesson, _ruy);
      lesson.rate(Rating.good);
      async.flushMicrotasks();
      expect(lesson.state, isA<SittingOver>());

      lesson.restart();
      expect(lesson.state, isA<SittingOver>());
    });
  });

  test('an exclusion that did not save is said, and the next one that does '
      'clears it', () {
    fakeAsync((async) {
      final lesson = sitting(async, SittingKind.review, lines);
      files.inner.nextWrite = const ProgressFailed('disk full');
      unawaited(lesson.exclude());
      async.flushMicrotasks();
      expect(lesson.notExcluded, isA<ProgressFailed>());
      expect(lesson.line.key, lines.last.key, reason: 'the sitting goes on');

      unawaited(lesson.exclude());
      async.flushMicrotasks();
      expect(lesson.notExcluded, isNull);
    });
  });

  group('a line rated Again', () {
    test('comes round once more in a review', () {
      fakeAsync((async) {
        final lesson = sitting(async, SittingKind.review, [lines.first]);
        play(async, lesson, _ruy);
        lesson.rate(Rating.again);
        async.flushMicrotasks();
        expect(lesson.state, isA<Drilling>());
        expect(lesson.line.key, lines.first.key);
      });
    });

    test('ends a sitting of that one line', () {
      fakeAsync((async) {
        final lesson = sitting(async, SittingKind.line, [lines.first]);
        play(async, lesson, _ruy);
        lesson.rate(Rating.again);
        async.flushMicrotasks();
        expect(lesson.state, isA<SittingOver>());
      });
    });
  });

  test('a rating that lands while away moves on once, on return', () {
    fakeAsync((async) {
      final lesson = sitting(async, SittingKind.review, lines);
      play(async, lesson, _ruy);
      final gate = files.gate = Completer<void>();
      lesson.rate(Rating.good);
      async.flushMicrotasks();
      expect(lesson.state, isA<SavingLine>());

      lesson.suspend();
      gate.complete();
      async.flushMicrotasks();
      expect(files.inner.reviewChanges, hasLength(1));
      expect(lesson.line.key, lines.first.key, reason: 'held until return');

      lesson.resume();
      expect(lesson.line.key, lines.last.key);
      play(async, lesson, _italian.take(1).toList());

      lesson.suspend();
      lesson.resume();
      expect(lesson.line.key, lines.last.key);
      expect(lesson.state, isA<Drilling>());
    });
  });
}

/// [ScriptedProgress] whose writes wait for [gate] while it is set.
final class _GatedProgress implements ProgressFiles {
  final inner = ScriptedProgress();
  Completer<void>? gate;

  @override
  Future<ProgressAdmission> enqueueWrite({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    required ProgressOperation operation,
  }) => inner.enqueueWrite(
    reviews: reviews,
    streaks: streaks,
    history: history,
    operation: operation,
  );

  @override
  Future<ProgressAdmission> enqueueAttempt(
    Attempt attempt, {
    required ProgressOperation operation,
  }) => inner.enqueueAttempt(attempt, operation: operation);

  @override
  Future<ProgressWrite> commit(ProgressOperation operation) =>
      inner.commit(operation);

  @override
  Future<ProgressRead> read(
    Set<String> sources, {
    Map<String, Revision>? observed,
  }) => inner.read(sources, observed: observed);

  @override
  Future<ProgressWrite> write({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    ProgressOperation? operation,
  }) async {
    if (gate case final waiting?) {
      gate = null;
      await waiting.future;
    }
    return inner.write(
      reviews: reviews,
      streaks: streaks,
      history: history,
      operation: operation,
    );
  }

  @override
  Future<ProgressWrite> logAttempt(
    Attempt attempt, {
    ProgressOperation? operation,
  }) => inner.logAttempt(attempt, operation: operation);
}
