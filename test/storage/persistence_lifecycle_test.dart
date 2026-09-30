import 'package:chess_auto_prep/storage/document_ref.dart';
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/app/exit_guard.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/training/training_line.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/features/trainer/progress.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:chess_auto_prep/storage/book_file.dart';
import 'package:chess_auto_prep/storage/book_snapshot.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/settings.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/books.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart';
import '../support/session_fixture.dart';
import '../support/window_fixture.dart';
import '../support/scripted_progress.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'close flushes edits made by a command that was already running',
    () async {
      final pending = PendingWrites();
      final fixture = await openSession(
        blackChapter,
        delay: const Duration(days: 1),
      );
      addTearDown(fixture.dispose);
      final finish = Completer<void>();
      unawaited(
        pending.track(
          Object(),
          finish.future.then((_) {
            fixture.session.setComment(
              NodePath.of([0]),
              'Written while closing',
            );
          }),
          label: 'Import',
        ),
      );
      final guard = ExitGuard(
        saver: fixture.saver,
        question: ScriptedDraftQuestion(),
        settleFeatures: pending.settle,
      );
      final closing = guard.mayClose();
      await pumpEventQueue();
      finish.complete();
      expect(await closing, isTrue);
      expect(fixture.onDisk, contains('Written while closing'));
    },
  );

  test(
    'queued training updates stay durable after a scope owner is disposed',
    () async {
      final pending = PendingWrites();
      final disk = _HeldProgress();
      final progress = TrainingProgress(
        files: disk,
        loaded: const ProgressLoaded(reviews: {}, streaks: {}, mistakes: []),
        time: (now: () => DateTime.utc(2026), jitter: () => 0),
        pendingWrites: pending,
      );
      final lines = trainingLines(
        parseChapter(name: 'Main', text: blackChapter),
        source: '/repertoires/KID/Main.pgn',
      );
      unawaited(progress.mark(lines, known: true));
      unawaited(progress.mark(lines, known: false));
      progress.dispose();
      var settled = false;
      final closing = pending.settle().then((failure) {
        settled = true;
        return failure;
      });
      await pumpEventQueue();
      expect(settled, isFalse);
      disk.release.complete();
      expect(await closing, isNull);
      expect(disk.delegate.history, hasLength(lines.length * 2));
      expect(
        disk.delegate.reviews.values.every((review) => review.due == null),
        isTrue,
      );
    },
  );

  test(
    'close waits for queued book changes even after the owner is disposed',
    () async {
      final pending = PendingWrites();
      final disk = _HeldBooks();
      final books = Books(
        store: disk,
        root: '/repertoires',
        pendingWrites: pending,
      );
      await books.load();
      books.create('First');
      books.create('Second');
      books.dispose();
      final session = await openSession(blackChapter);
      addTearDown(session.dispose);
      final question = ScriptedDraftQuestion();
      final guard = ExitGuard(
        saver: session.saver,
        question: question,
        settleFeatures: pending.settle,
      );
      var closed = false;
      final closing = guard.mayClose().then((value) => closed = value);
      await pumpEventQueue();
      expect(closed, isFalse);
      disk.release.complete();
      await closing;
      expect(closed, isTrue);
      expect(disk.books.books.map((b) => b.name), ['First', 'Second']);
    },
  );

  test(
    'failed feature persistence asks before closing and a retry clears it',
    () async {
      final pending = PendingWrites();
      final owner = Object();
      await pending.track(
        owner,
        Future.value(false),
        label: 'Training',
        obligation: owner,
        problem: (saved) => saved ? null : 'Progress was not saved',
      );
      final session = await openSession(blackChapter);
      addTearDown(session.dispose);
      final question = ScriptedDraftQuestion()
        ..answer = DraftChoice.keepWaiting;
      final guard = ExitGuard(
        saver: session.saver,
        question: question,
        settleFeatures: pending.settle,
      );
      expect(await guard.mayClose(), isFalse);
      expect(question.asked.single, contains('Progress was not saved'));
      await pending.track(
        owner,
        Future.value(true),
        label: 'Training',
        obligation: owner,
      );
      expect(await guard.mayClose(), isTrue);
    },
  );

  group('a training write that failed', () {
    late PendingWrites pending;
    late ScriptedProgress disk;
    late TrainingProgress progress;
    late TrainingLine line;
    late TrainingLine other;

    setUp(() {
      pending = PendingWrites();
      disk = ScriptedProgress()..nextWrite = const ProgressFailed('locked');
      progress = TrainingProgress(
        files: disk,
        loaded: const ProgressLoaded(reviews: {}, streaks: {}, mistakes: []),
        time: (now: () => DateTime.utc(2026), jitter: () => 0),
        pendingWrites: pending,
      );
      addTearDown(progress.dispose);
      final lines = trainingLines(
        parseChapter(name: 'Main', text: blackChapter),
        source: '/repertoires/KID/Main.pgn',
      );
      line = lines.first;
      other = lines.last;
    });

    test('is no longer asked about once a retry saved it', () async {
      expect(
        await progress.finished(line, Rating.good, clean: true),
        isA<ProgressFailed>(),
      );
      expect(await progress.retry(line), isA<ProgressWritten>());
      expect(await pending.settle(), isNull);
    });

    test('is not kept by an answer logged before the retry', () async {
      expect(
        await progress.finished(line, Rating.good, clean: true),
        isA<ProgressFailed>(),
      );
      final answer = await progress.answered(line, (
        ply: 0,
        fen: line.start,
        played: 'e2e4',
        expected: 'e2e4',
        correct: true,
        phase: AttemptPhase.drilling,
      ));
      expect(answer, isA<ProgressWritten>());
      expect(await progress.retry(line), isA<ProgressWritten>());
      expect(await pending.settle(), isNull);
    });

    test('is asked about while no retry saved it', () async {
      expect(
        await progress.finished(line, Rating.good, clean: true),
        isA<ProgressFailed>(),
      );
      expect(await pending.settle(), contains('Training progress'));
    });

    test('to exclude a line is not cleared by rating another', () async {
      expect(
        await progress.setExcluded(line, excluded: true),
        isA<ProgressFailed>(),
      );
      expect(
        await progress.finished(other, Rating.good, clean: true),
        isA<ProgressWritten>(),
      );
      expect(await pending.settle(), contains('could not be excluded'));
      expect(
        await progress.setExcluded(line, excluded: true),
        isA<ProgressWritten>(),
      );
      expect(await pending.settle(), isNull);
    });

    test('to mark lines is not cleared by a later retry', () async {
      expect(await progress.mark([line], known: true), isA<ProgressFailed>());
      expect(await progress.retry(other), isA<ProgressWritten>());
      expect(
        await progress.finished(other, Rating.good, clean: true),
        isA<ProgressWritten>(),
      );
      expect(await pending.settle(), contains('could not be marked'));
    });

    test('to mark lines is cleared once the same mark lands', () async {
      expect(await progress.mark([line], known: true), isA<ProgressFailed>());
      expect(await progress.mark([line], known: true), isA<ProgressWritten>());
      expect(disk.reviews[line.key]?.lastRating, Rating.good.name);
      expect(await pending.settle(), isNull);
    });
  });

  test(
    'concurrent book instances cannot overwrite a newer whole file',
    () async {
      final root = await Directory.systemTemp.createTemp('books-contention-');
      addTearDown(() => root.delete(recursive: true));
      final first = BookFile(
        root,
        recovery: RecoveryGate(
          documents: Directory(p.join(root.path, 'Documents')),
          support: root,
        ),
      );
      final second = BookFile(
        root,
        recovery: RecoveryGate(
          documents: Directory(p.join(root.path, 'Documents')),
          support: root,
        ),
      );
      await Future.wait([first.read(), second.read()]);
      const a = BookList(
        books: [Book(id: 'a', name: 'A')],
      );
      const b = BookList(
        books: [Book(id: 'b', name: 'B')],
      );
      final results = await Future.wait([
        first.write(a).then((_) => true, onError: (Object _) => false),
        second.write(b).then((_) => true, onError: (Object _) => false),
      ]);
      expect(results.where((saved) => saved), hasLength(1));
      final disk = await BookFile(
        root,
        recovery: RecoveryGate(
          documents: Directory(p.join(root.path, 'Documents')),
          support: root,
        ),
      ).read();
      expect(disk.books.single.id, results.first ? 'a' : 'b');
      await second.read();
      await second.write(b);
      expect(
        (await BookFile(
          root,
          recovery: RecoveryGate(
            documents: Directory(p.join(root.path, 'Documents')),
            support: root,
          ),
        ).read()).books.single.id,
        'b',
      );
    },
  );

  test(
    'two settings instances both keep saving; the last write wins',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'settings-contention-',
      );
      addTearDown(() => root.delete(recursive: true));
      final a = SettingsStore(support: root);
      final b = SettingsStore(support: root);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await Future.wait([a.load(), b.load()]);
      await a.update(a.value.copyWith(engineCores: 4));
      await b.update(b.value.copyWith(engineLines: 7));
      expect(b.problem, isNull);
      final disk = Settings.fromJson(
        await File(p.join(root.path, 'settings.json')).readAsString(),
      );
      expect(disk.engineLines, 7);
    },
  );
}

final class _HeldBooks implements BookStore {
  final release = Completer<void>();
  BookList books = BookList.empty;
  @override
  Future<BookList> read() async => books;
  @override
  Future<BookSnapshot> snapshot() async => BookSnapshot(value: await read());

  @override
  Future<BookSnapshot> write(BookList value) async {
    await release.future;
    books = value;
    return BookSnapshot(value: value);
  }
}

final class _HeldProgress implements ProgressFiles {
  final release = Completer<void>();
  final delegate = ScriptedProgress();
  @override
  Future<ProgressRead> read(
    Set<String> sources, {
    Map<String, Revision>? observed,
  }) => delegate.read(sources, observed: observed);
  @override
  Future<ProgressAdmission> enqueueWrite({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    required ProgressOperation operation,
  }) => delegate.enqueueWrite(
    reviews: reviews,
    streaks: streaks,
    history: history,
    operation: operation,
  );
  @override
  Future<ProgressAdmission> enqueueAttempt(
    Attempt attempt, {
    required ProgressOperation operation,
  }) => delegate.enqueueAttempt(attempt, operation: operation);
  @override
  Future<ProgressWrite> commit(ProgressOperation operation) async {
    await release.future;
    return delegate.commit(operation);
  }

  @override
  Future<ProgressWrite> logAttempt(
    Attempt attempt, {
    ProgressOperation? operation,
  }) => delegate.logAttempt(attempt, operation: operation);
  @override
  Future<ProgressWrite> write({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
    ProgressOperation? operation,
  }) async {
    await release.future;
    return delegate.write(
      reviews: reviews,
      streaks: streaks,
      history: history,
      operation: operation,
    );
  }
}
