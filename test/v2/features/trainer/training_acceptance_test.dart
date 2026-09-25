import 'dart:async';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/chess/training/training_line.dart';
import 'package:chess_auto_prep/v2/features/trainer/progress.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../../support/scripted_progress.dart';

void main() {
  late _Queue files;
  late PendingWrites pending;
  late TrainingProgress progress;
  late TrainingLine line;
  var now = DateTime.utc(2026, 9, 25);
  var jitter = 0.0;

  setUp(() {
    files = _Queue();
    pending = PendingWrites();
    now = DateTime.utc(2026, 9, 25);
    jitter = 0;
    line = trainingLines(
      parseChapter(name: 'Main', text: blackChapter),
      source: '/repertoires/Main.pgn',
    ).first;
    progress = TrainingProgress(
      files: files,
      loaded: const ProgressLoaded(reviews: {}, streaks: {}, mistakes: []),
      pendingWrites: pending,
      time: (now: () => now, jitter: () => jitter),
    );
  });
  tearDown(() => progress.dispose());

  test(
    'successor enqueues final rows while predecessor publication waits',
    () async {
      final held = files.applyHold = Completer<void>();
      final first = progress.finished(line, Rating.good, clean: true);
      final acceptedAt = now = now.add(const Duration(hours: 1));
      final second = progress.finished(line, Rating.easy, clean: true);
      await pumpEventQueue();
      expect(files.queued, hasLength(2));
      final a = files.queued.first;
      final b = files.queued.last;
      expect(b.reviews.single.before, a.reviews.single.after);
      expect(b.operation.predecessorId, a.operation.id);
      expect(() => b.reviews.clear(), throwsUnsupportedError);
      expect(b.history.single.at, acceptedAt);
      expect(progress.reviews, isEmpty);
      now = now.add(const Duration(days: 7));
      jitter = 1;
      held.complete();
      expect(await first, isA<ProgressWritten>());
      expect(await second, isA<ProgressWritten>());
      expect(progress.reviews[line.key]!.intervalDays, 3.44);
      expect(files.delegate.history.map((row) => row.at), [
        a.history.single.at,
        acceptedAt,
      ]);
    },
  );

  test(
    'mark then exclude is durably queued despite failed predecessor',
    () async {
      files.failCommit = true;
      expect(await progress.mark([line], known: true), isA<ProgressFailed>());
      expect(
        await progress.setExcluded(line, excluded: true),
        isA<ProgressFailed>(),
      );
      expect(files.queued, hasLength(2));
      expect(
        files.queued.last.reviews.single.before,
        files.queued.first.reviews.single.after,
      );
      expect(progress.reviews, isEmpty);
      files.failCommit = false;
      await pending.retry(files);
      expect(progress.reviews[line.key]!.excluded, isTrue);
      expect(progress.reviews[line.key]!.lastRating, 'good');
      expect(files.delegate.history, hasLength(1));
    },
  );

  test(
    'missing predecessor admission keeps its successor for ordered retry',
    () async {
      files.rejectEnqueue = true;
      await progress.mark([line], known: true);
      files.rejectEnqueue = false;
      expect(
        await progress.setExcluded(line, excluded: true),
        isA<ProgressFailed>(),
      );
      expect(files.acceptedIds, isEmpty);
      final original = files.queued.toList();
      await progress.retry();
      expect(await pending.settle(), isNull);
      expect(
        files.acceptedIds,
        original.map((entry) => entry.operation.id).toSet(),
      );
      expect(files.queued.last.operation, original.last.operation);
      expect(files.queued.last.reviews, original.last.reviews);
      expect(files.delegate.history, hasLength(1));
      expect(progress.reviews[line.key]!.excluded, isTrue);
    },
  );

  test(
    'successive ratings freeze projected streaks before publication',
    () async {
      final held = files.applyHold = Completer<void>();
      const answer = (
        ply: 0,
        fen: Fen.initial,
        played: 'e5',
        expected: 'e5',
        correct: true,
        phase: AttemptPhase.drilling,
      );
      final a = progress.answered(line, answer);
      final first = progress.finished(line, Rating.good, clean: true);
      final b = progress.answered(line, answer);
      final second = progress.finished(line, Rating.good, clean: true);
      await pumpEventQueue();
      expect(files.queued.first.streaks.single.before, isNull);
      expect(files.queued.first.streaks.single.after.streak, 1);
      expect(
        files.queued.last.streaks.single.before,
        files.queued.first.streaks.single.after,
      );
      expect(files.queued.last.streaks.single.after.streak, 2);
      held.complete();
      await Future.wait([a, first, b, second]);
      expect(files.delegate.streaks.values.single.streak, 2);
      expect(files.delegate.history, hasLength(2));
    },
  );

  test(
    'enqueue failure retains exact rows and token across disposal and retry',
    () async {
      files.rejectEnqueue = true;
      expect(
        await progress.finished(line, Rating.good, clean: true),
        isA<ProgressFailed>(),
      );
      final accepted = files.queued.single;
      progress.dispose();
      now = now.add(const Duration(days: 7));
      jitter = 1;
      expect(await pending.settle(), contains('enqueue failed'));
      files.rejectEnqueue = false;
      await pending.retry(files);
      expect(files.queued, hasLength(2));
      expect(
        identical(files.queued.last.operation, accepted.operation),
        isTrue,
      );
      expect(files.queued.last.reviews, accepted.reviews);
      expect(files.delegate.history, accepted.history);
      expect(await pending.settle(), isNull);
      progress = TrainingProgress(
        files: files,
        loaded: const ProgressLoaded(reviews: {}, streaks: {}, mistakes: []),
        time: (now: () => now, jitter: () => jitter),
      );
    },
  );

  test('blocked successor enqueue remains a resource read barrier', () async {
    files.failCommit = true;
    await progress.mark([line], known: true);
    final held = files.enqueueHold = Completer<void>();
    final second = progress.setExcluded(line, excluded: true);
    await pumpEventQueue();
    var settled = false;
    final settling = progress.settle().then((_) => settled = true);
    await pumpEventQueue();
    expect(settled, isFalse);
    held.complete();
    await second;
    await settling;
    expect(settled, isTrue);
    expect(files.queued, hasLength(2));
  });

  test('attempt acceptance and retry adopt a mistake only once', () async {
    files.failCommit = true;
    const answer = (
      ply: 0,
      fen: Fen.initial,
      played: 'd5',
      expected: 'e5',
      correct: false,
      phase: AttemptPhase.drilling,
    );
    await progress.answered(line, answer);
    now = now.add(const Duration(seconds: 1));
    await progress.answered(line, answer);
    expect(files.attemptTokens, hasLength(2));
    expect(progress.mistakes, isEmpty);
    files.failCommit = false;
    await progress.retry();
    await progress.retry();
    expect(progress.mistakes, hasLength(2));
    expect(files.delegate.attempts, hasLength(2));
  });
}

typedef _Queued = ({
  List<Change<Review>> reviews,
  List<Change<MoveStreak>> streaks,
  List<HistoryRow> history,
  ProgressOperation operation,
});

final class _Queue implements ProgressFiles {
  final delegate = ScriptedProgress();
  final queued = <_Queued>[];
  final attemptTokens = <ProgressOperation>[];
  final acceptedIds = <String>{};
  Completer<void>? applyHold;
  Completer<void>? enqueueHold;
  bool failCommit = false;
  bool rejectEnqueue = false;

  @override
  Future<ProgressAdmission> enqueueWrite({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    required ProgressOperation operation,
  }) async {
    queued.add((
      reviews: reviews,
      streaks: streaks,
      history: history,
      operation: operation,
    ));
    await enqueueHold?.future;
    if (rejectEnqueue) {
      return const ProgressRejected(ProgressFailed('enqueue failed'));
    }
    final predecessor = operation.predecessorId;
    if (predecessor != null && !acceptedIds.contains(predecessor)) {
      return const ProgressRejected(
        ProgressFailed('predecessor is not durable'),
      );
    }
    acceptedIds.add(operation.id);
    return delegate.enqueueWrite(
      reviews: reviews,
      streaks: streaks,
      history: history,
      operation: operation,
    );
  }

  @override
  Future<ProgressAdmission> enqueueAttempt(
    Attempt attempt, {
    required ProgressOperation operation,
  }) {
    attemptTokens.add(operation);
    acceptedIds.add(operation.id);
    return delegate.enqueueAttempt(attempt, operation: operation);
  }

  @override
  Future<ProgressWrite> commit(ProgressOperation operation) async {
    await applyHold?.future;
    if (failCommit) return const ProgressFailed('publication failed');
    return delegate.commit(operation);
  }

  @override
  Future<ProgressRead> read(
    Set<String> sources, {
    Map<String, Revision>? observed,
  }) => delegate.read(sources, observed: observed);
  @override
  Future<ProgressWrite> write({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    ProgressOperation? operation,
  }) => delegate.write(
    reviews: reviews,
    streaks: streaks,
    history: history,
    operation: operation,
  );
  @override
  Future<ProgressWrite> logAttempt(
    Attempt attempt, {
    ProgressOperation? operation,
  }) => delegate.logAttempt(attempt, operation: operation);
}
