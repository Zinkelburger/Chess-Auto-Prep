import 'dart:async';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../../support/scripted_files.dart';
import '../../support/scripted_progress.dart';
import '../../support/session_fixture.dart';

void main() {
  late SessionFixture session;
  late EngineAnalysis analysis;
  late Books books;
  late _HeldProgress files;
  late PendingWrites pending;
  late Trainer trainer;
  late DateTime now;
  var spread = 0.0;

  Trainer createTrainer() => Trainer(
    session: session.session,
    chapters: ScopeReader(files: ScriptedFiles(), documents: session.store),
    files: files,
    analysis: analysis,
    time: (now: () => now, jitter: () => spread),
    books: books,
    pendingWrites: pending,
  );

  setUp(() async {
    session = await openSession(blackChapter);
    analysis = EngineAnalysis(
      session.session,
      () async => const StartFailed('unused'),
    );
    books = Books(store: MemoryBooks(), root: '/repertoires');
    files = _HeldProgress();
    pending = PendingWrites();
    now = DateTime.utc(2026, 9, 24);
    spread = 0;
    trainer = createTrainer()..show();
    await pumpEventQueue();
  });

  tearDown(() {
    trainer.dispose();
    books.dispose();
    analysis.dispose();
    session.dispose();
  });

  test('both overlapping reloads wait for the same accepted rating', () async {
    final ready = trainer.state as TrainerReady;
    final line = ready.lines.first;
    final hold = files.hold = Completer<void>();
    final rating = ready.progress.finished(line, Rating.good, clean: true);
    await pumpEventQueue();
    final first = trainer.reload();
    final second = trainer.reload();
    await pumpEventQueue();
    expect(files.delegate.reads, 1);
    expect(trainer.state, isA<TrainerLoading>());
    hold.complete();
    await Future.wait([rating, first, second]);
    final loaded = trainer.state as TrainerReady;
    expect(loaded.progress.reviews[line.key]!.lastRating, 'good');
    expect(files.delegate.history, hasLength(1));
  });

  test(
    'a disposed scope rejects new commands without accepting writes',
    () async {
      final ready = trainer.state as TrainerReady;
      await trainer.reload();
      expect(
        await ready.progress.finished(
          ready.lines.first,
          Rating.good,
          clean: true,
        ),
        isA<ProgressFailed>(),
      );
      expect(
        await ready.progress.mark(ready.lines, known: true),
        isA<ProgressFailed>(),
      );
      expect(
        await ready.progress.setExcluded(ready.lines.first, excluded: true),
        isA<ProgressFailed>(),
      );
      expect(
        await ready.progress.answered(ready.lines.first, (
          ply: 0,
          fen: Fen.initial,
          played: 'd5',
          expected: 'e5',
          correct: false,
          phase: AttemptPhase.drilling,
        )),
        isA<ProgressFailed>(),
      );
      expect(files.writes, isEmpty);
      expect(files.delegate.attempts, isEmpty);
      expect(await pending.settle(), isNull);
    },
  );

  test('a replacement trainer retries the original failed rating', () async {
    final ready = trainer.state as TrainerReady;
    files.delegate.nextWrite = const ProgressFailed('disk full');
    await ready.progress.finished(ready.lines.first, Rating.good, clean: true);
    final accepted = files.writes.single;
    trainer.dispose();
    now = now.add(const Duration(days: 7));
    spread = 1;
    trainer = createTrainer()..show();
    await pumpEventQueue();
    expect(trainer.state, isA<TrainerUnsaved>());
    expect(await pending.settle(), contains('progress'));
    await trainer.retryPending();
    expect(trainer.state, isA<TrainerReady>());
    expect(await pending.settle(), isNull);
    expect(files.writes.last, accepted);
    expect(files.delegate.history, [accepted.history.single]);
  });

  test(
    'a queued rating keeps its acceptance time before the barrier',
    () async {
      final ready = trainer.state as TrainerReady;
      final line = ready.lines.first;
      final hold = files.hold = Completer<void>();
      final first = ready.progress.finished(line, Rating.good, clean: true);
      final acceptedAt = now = now.add(const Duration(hours: 1));
      final second = ready.progress.finished(line, Rating.easy, clean: true);
      now = now.add(const Duration(days: 7));
      spread = 1;
      hold.complete();
      await Future.wait([first, second]);
      expect(files.delegate.history.last.at, acceptedAt);
      expect(files.delegate.reviews[line.key]!.intervalDays, 3.44);
    },
  );

  test(
    'attempt logs remain a read barrier and can retry after replacement',
    () async {
      final ready = trainer.state as TrainerReady;
      final hold = files.logHold = Completer<void>();
      files.delegate.logAs = const ProgressFailed('log full');
      final attempt = ready.progress.answered(ready.lines.first, (
        ply: 1,
        fen: Fen.initial,
        played: 'd5',
        expected: 'e5',
        correct: false,
        phase: AttemptPhase.drilling,
      ));
      final reload = trainer.reload();
      await pumpEventQueue();
      expect(files.delegate.reads, 1);
      hold.complete();
      await Future.wait([attempt, reload]);
      expect(trainer.state, isA<TrainerUnsaved>());
      files.delegate.logAs = null;
      await trainer.retryPending();
      final loaded = trainer.state as TrainerReady;
      expect(loaded.progress.mistakes.single.played, 'd5');
      expect(files.delegate.attempts, hasLength(1));
    },
  );

  test('a bulk change waits behind the earlier failed mutation', () async {
    final ready = trainer.state as TrainerReady;
    files.delegate.nextWrite = const ProgressFailed('disk full');
    await ready.progress.mark([ready.lines.first], known: true);
    await ready.progress.setExcluded(ready.lines.last, excluded: true);
    expect(files.delegate.reviews, isEmpty);
    await trainer.reload();
    expect(trainer.state, isA<TrainerUnsaved>());
    await trainer.retryPending();
    expect(files.delegate.reviews[ready.lines.first.key]!.lastRating, 'good');
    expect(files.delegate.reviews[ready.lines.last.key]!.excluded, isTrue);
    expect(await pending.settle(), isNull);
  });
}

final class _HeldProgress implements ProgressFiles {
  final delegate = ScriptedProgress();
  Completer<void>? hold;
  Completer<void>? logHold;
  final writes =
      <
        ({
          List<Change<Review>> reviews,
          List<Change<MoveStreak>> streaks,
          List<HistoryRow> history,
          ProgressOperation? operation,
        })
      >[];

  @override
  Future<ProgressRead> read(Set<String> sources) => delegate.read(sources);

  @override
  Future<ProgressWrite> logAttempt(
    Attempt attempt, {
    ProgressOperation? operation,
  }) async {
    await logHold?.future;
    return delegate.logAttempt(attempt, operation: operation);
  }

  @override
  Future<ProgressWrite> write({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    ProgressOperation? operation,
  }) async {
    writes.add((
      reviews: reviews,
      streaks: streaks,
      history: history,
      operation: operation,
    ));
    await hold?.future;
    return delegate.write(
      reviews: reviews,
      streaks: streaks,
      history: history,
      operation: operation,
    );
  }
}
