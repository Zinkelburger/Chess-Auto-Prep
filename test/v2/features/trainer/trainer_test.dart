import 'dart:async';
import 'package:chess_auto_prep/v2/chess/training/training_options.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';

import 'package:chess_auto_prep/v2/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/v2/chess/training/drill.dart';
import 'package:chess_auto_prep/v2/chess/training/line_order.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/features/trainer/lesson.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_files.dart';
import '../../support/scripted_progress.dart';
import '../../support/scripted_store.dart';
import '../../support/session_fixture.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';

/// Two lines for White: the Ruy Lopez and the Italian.
const _chapter = '''
// Color: White

[Event "Ruy"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *

[Event "Italian"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 *
''';

const _other = '''
// Color: White

[Event "Queen's Gambit"]

1. d4 d5 2. c4 *
''';

final _now = DateTime.utc(2026, 9, 22, 12);

void main() {
  late SessionFixture fixture;
  late ScriptedProgress files;
  late EngineAnalysis analysis;

  setUp(() async {
    fixture = await openSession(_chapter);
    files = ScriptedProgress();
    analysis = EngineAnalysis(
      fixture.session,
      () async => const StartFailed('no engine in this test'),
    );
  });

  tearDown(() {
    analysis.dispose();
    fixture.dispose();
  });

  String source() => fixture.ref.path;

  Trainer trainerOver({ScriptedFiles? listing, SettingsStore? settings}) {
    final trainer = Trainer(
      session: fixture.session,
      settings: settings,
      chapters: ScopeReader(
        files: listing ?? ScriptedFiles(),
        documents: fixture.store,
      ),
      files: files,
      analysis: analysis,
      time: (now: () => _now, jitter: () => 0),
      books: Books(store: MemoryBooks(), root: '/repertoires'),
    );
    addTearDown(trainer.dispose);
    return trainer;
  }

  /// A trainer that has read the open chapter.
  Trainer ready(FakeAsync async, {ScriptedFiles? listing}) {
    final trainer = trainerOver(listing: listing)..show();
    async.flushMicrotasks();
    expect(trainer.state, isA<TrainerReady>());
    return trainer;
  }

  TrainerReady readyState(Trainer trainer) => trainer.state as TrainerReady;

  /// Plays [uci] and lets every timed moment after it pass.
  void play(FakeAsync async, Lesson lesson, String uci) {
    lesson.play(uci);
    async.elapse(const Duration(seconds: 2));
  }

  test(
    'Drill quizzes new lines immediately and finishes once even with Again',
    () {
      fakeAsync((async) {
        final trainer = ready(async);
        final lines = readyState(trainer).lines;
        trainer.drillLines([lines.last]);
        final lesson = trainer.lesson!;
        expect(lesson.kind, SittingKind.drill);
        expect(lesson.learning, isFalse);
        expect(lesson.drill.stage, isA<Asking>());
        expect(lesson.line.name, 'Italian');
        for (final uci in ['e2e4', 'g1f3', 'f1c4']) {
          play(async, lesson, uci);
        }
        expect(lesson.state, isA<AwaitingRating>());
        lesson.rate(Rating.again);
        async.flushMicrotasks();
        expect(lesson.state, isA<SittingOver>());
        expect(files.history.single.rating, 'again');
        expect(files.attempts, hasLength(3));
        expect(trainer.board.value, isNull);
        trainer.leave();
        expect(analysis.paused, isFalse);
      });
    },
  );

  test(
    'sitting limits and pacing are captured; excluded lines cannot be drilled',
    () {
      fakeAsync((async) {
        final settings = SettingsStore(
          initial: const Settings(
            training: TrainingOptions(
              learnLimit: 1,
              reviewLimit: 1,
              drillLimit: 1,
              replyMillis: 2000,
            ),
          ),
        );
        addTearDown(settings.dispose);
        final trainer = trainerOver(settings: settings)..show();
        async.flushMicrotasks();
        final lines = readyState(trainer).lines;
        expect(trainer.learnCount, 1);
        trainer.learn();
        expect(trainer.lesson!.left, 0);
        trainer.leave();
        trainer.drillLines(lines);
        final lesson = trainer.lesson!;
        expect(lesson.left, 0);
        settings.update(
          settings.value.copyWith(
            training: const TrainingOptions(drillLimit: 0, replyMillis: 200),
          ),
        );
        lesson.play('e2e4');
        async.elapse(const Duration(milliseconds: 700));
        expect(lesson.drill.stage, isA<Answered>());
        async.elapse(const Duration(milliseconds: 1300));
        expect(lesson.drill.stage, isA<Asking>());
        trainer.leave();
        trainer.drillLines(lines);
        expect(
          trainer.lesson!.left,
          1,
          reason: 'new sitting takes updated limit',
        );
        trainer.leave();
        readyState(trainer).progress.setExcluded(lines.first, excluded: true);
        async.flushMicrotasks();
        trainer.trainLine(lines.first);
        expect(trainer.lesson, isNull);
        trainer.drillLines(lines);
        expect(trainer.lesson!.line.key, lines.last.key);
        expect(trainer.lesson!.left, 0);
      });
    },
  );

  test('nothing is read until the tab asks', () {
    fakeAsync((async) {
      final trainer = trainerOver();
      async.flushMicrotasks();
      expect(trainer.state, isA<TrainerIdle>());
      expect(files.reads, 0);
      trainer.show();
      async.flushMicrotasks();
      final state = readyState(trainer);
      expect(state.lines.map((l) => l.name), ['Ruy', 'Italian']);
      expect(trainer.untrainedCount, 2);
      expect(trainer.dueCount, 0);
    });
  });

  test('with no chapter open there is nothing to train', () {
    fakeAsync((async) {
      fixture.session.closed();
      final trainer = trainerOver()..show();
      async.flushMicrotasks();
      expect((trainer.state as TrainerEmpty).why, NothingToTrain.noChapter);
    });
  });

  test('progress that cannot be read is said, and read again on asking', () {
    fakeAsync((async) {
      files.readAs = const ProgressUnreadable('repertoire_reviews.csv', 3);
      final trainer = trainerOver()..show();
      async.flushMicrotasks();
      expect(trainer.state, isA<TrainerFailed>());
      files.readAs = null;
      trainer.reload();
      async.flushMicrotasks();
      expect(trainer.state, isA<TrainerReady>());
    });
  });

  test('learning a new line: walked through, quizzed, rated Good for the '
      'user, written with its streaks and history', () {
    fakeAsync((async) {
      final trainer = ready(async);
      trainer.learn();
      final lesson = trainer.lesson!;
      expect(lesson.kind, SittingKind.learn);
      expect(lesson.learning, isTrue);
      expect(lesson.left, 1, reason: 'the Italian waits its turn');
      expect(
        trainer.board.value,
        isNotNull,
        reason: 'the lesson has the board',
      );
      expect(analysis.paused, isTrue, reason: 'the engine would tell');

      // The walkthrough: each move shown, then asked for.
      for (final uci in ['e2e4', 'g1f3', 'f1b5']) {
        expect(lesson.drill.stage, isA<Showing>());
        lesson.next();
        play(async, lesson, uci);
      }
      // The quiz, clean.
      expect(lesson.drill.pass, Pass.quiz);
      for (final uci in ['e2e4', 'g1f3', 'f1b5']) {
        play(async, lesson, uci);
      }
      async.flushMicrotasks();

      final key = readyState(trainer).lines.first.key;
      final review = files.reviews[key]!;
      expect((review.lastRating, review.intervalDays), ('good', 1.0));
      expect(files.history.single.kind, HistoryKind.trainer);
      expect(files.streaks.values.map((s) => s.streak), [1, 1, 1]);
      expect(files.attempts.map((a) => a.phase).toSet(), {
        AttemptPhase.learning,
        AttemptPhase.drilling,
      });
      expect(lesson.line.name, 'Italian', reason: 'the next line is up');
      expect(lesson.tally, (lines: 1, right: 3, wrong: 0));
    });
  });

  test('a reviewed line waits for the user\'s rating; a mistake is logged, '
      'replayed and counted against it', () {
    fakeAsync((async) {
      final ruy = (source: source(), id: 'line_ZTQgZTUgTmYzIE5jNiBCYj');
      files.reviews[ruy] = Review(
        key: ruy,
        lineName: 'Ruy',
        intervalDays: 4,
        lastRating: 'good',
        due: _now.subtract(const Duration(hours: 1)),
      );
      final trainer = ready(async);
      expect(readyState(trainer).lines.first.key, ruy);
      expect(trainer.dueCount, 1);
      trainer.review();
      final lesson = trainer.lesson!;
      expect(lesson.learning, isFalse);
      play(async, lesson, 'e2e4');
      play(async, lesson, 'b1c3'); // wrong: Nf3
      play(async, lesson, 'f1b5');
      expect(lesson.drill.pass, Pass.replay);
      play(async, lesson, 'g1f3');
      async.flushMicrotasks();

      expect(lesson.state, isA<AwaitingRating>());
      expect((lesson.state as AwaitingRating).clean, isFalse);
      expect(files.attempts.where((a) => !a.correct).single.played, 'Nc3');
      expect(readyState(trainer).progress.mistakes.single.expected, 'Nf3');

      lesson.rate(Rating.hard);
      async.flushMicrotasks();
      final review = files.reviews[ruy]!;
      expect((review.lastRating, review.fails), ('hard', 1));
      expect(review.intervalDays, 5);
      expect(lesson.state, isA<SittingOver>());
      expect(
        trainer.board.value,
        isNull,
        reason: 'the board is the document\'s',
      );
    });
  });

  test('a line rated Again comes round once more in the same sitting', () {
    fakeAsync((async) {
      final trainer = ready(async);
      trainer.trainLine(readyState(trainer).lines.first);
      // A single-line sitting ends with the line whatever it is rated.
      expect(trainer.lesson!.kind, SittingKind.line);
      trainer.leave();

      trainer.learn();
      final lesson = trainer.lesson!;
      for (final uci in ['e2e4', 'g1f3', 'f1b5']) {
        lesson.next();
        play(async, lesson, uci);
      }
      play(async, lesson, 'd2d4'); // wrong in the quiz
      play(async, lesson, 'g1f3');
      play(async, lesson, 'f1b5');
      play(async, lesson, 'e2e4'); // the replay
      async.flushMicrotasks();
      expect(files.reviews.values.single.lastRating, 'again');
      expect(lesson.line.name, 'Italian');
      expect(lesson.left, 1, reason: 'the Ruy is back at the end');
    });
  });

  test('a rating that could not be written is kept and tried again', () {
    fakeAsync((async) {
      final ruy = (source: source(), id: 'line_ZTQgZTUgTmYzIE5jNiBCYj');
      files.reviews[ruy] = Review(
        key: ruy,
        lineName: 'Ruy',
        intervalDays: 4,
        lastRating: 'good',
        due: _now,
      );
      final trainer = ready(async);
      trainer.review();
      final lesson = trainer.lesson!;
      for (final uci in ['e2e4', 'g1f3', 'f1b5']) {
        play(async, lesson, uci);
      }
      files.nextWrite = const ProgressFailed('disk full');
      lesson.rate(Rating.good);
      async.flushMicrotasks();
      expect(lesson.state, isA<LineNotSaved>());
      expect(files.reviews[ruy]!.intervalDays, 4, reason: 'nothing written');
      lesson.retry();
      async.flushMicrotasks();
      expect(files.reviews[ruy]!.intervalDays, 10);
      expect(lesson.state, isA<SittingOver>());
    });
  });

  test('a conflicting change stays retained across reload until retried', () {
    fakeAsync((async) {
      final trainer = ready(async);
      final progress = readyState(trainer).progress;
      files.nextWrite = const ProgressConflict();
      progress.setExcluded(readyState(trainer).lines.first, excluded: true);
      async.flushMicrotasks();
      expect(progress.stale, isTrue);
      trainer.learn();
      expect(trainer.lesson, isNull, reason: 'a stale scope is not trained');
      trainer.reload();
      async.flushMicrotasks();
      expect(trainer.state, isA<TrainerUnsaved>());
      trainer.retryPending();
      async.flushMicrotasks();
      expect(readyState(trainer).progress.stale, isFalse);
      expect(files.reviews.values.single.excluded, isTrue);
    });
  });

  test('an answer the log did not take is said, and the drill goes on', () {
    fakeAsync((async) {
      files.logAs = const ProgressFailed('read-only');
      final trainer = ready(async);
      trainer.learn();
      final lesson = trainer.lesson!..next();
      play(async, lesson, 'e2e4');
      expect(lesson.unlogged, isA<ProgressFailed>());
      expect(lesson.drill.stage, isA<Showing>());
    });
  });

  test('leaving gives the board and the engine back', () {
    fakeAsync((async) {
      final trainer = ready(async)..learn();
      expect(analysis.pausedFor, isNotNull);
      trainer.leave();
      expect(trainer.lesson, isNull);
      expect(trainer.board.value, isNull);
      expect(analysis.paused, isFalse);
      expect(files.reviews, isEmpty, reason: 'an unfinished line is unrated');
    });
  });

  test('marking lines known and excluding them', () {
    fakeAsync((async) {
      final trainer = ready(async);
      final state = readyState(trainer);
      state.progress.mark(state.lines, known: true);
      async.flushMicrotasks();
      expect(files.reviews.values.map((r) => r.intervalDays), [1, 1.5]);
      expect(files.history.map((h) => h.kind).toSet(), {HistoryKind.marked});
      expect(trainer.untrainedCount, 0);

      state.progress.setExcluded(state.lines.first, excluded: true);
      async.flushMicrotasks();
      expect(files.reviews[state.lines.first.key]!.excluded, isTrue);
    });
  });

  test('the whole repertoire: the other chapters, drafts left out', () {
    fakeAsync((async) {
      final qgd = ref('KID', 'QGD');
      const draft = ChapterRef(
        repertoire: 'KID',
        name: 'Proposed',
        path: '/repertoires/KID/Proposed.pgn',
        heading: ChapterHeading(draft: true),
      );
      fixture.store.documents[qgd] = Opened(_other, scriptedRevision(_other));
      fixture.store.documents[draft] = Opened(_other, scriptedRevision(_other));
      final listing = ScriptedFiles(
        listing: Repertoires([
          RepertoireFolder(
            name: 'KID',
            path: '/repertoires/KID',
            modified: _now,
            chapters: [fixture.ref, draft, qgd],
          ),
        ]),
      );
      final trainer = ready(async, listing: listing)
        ..setScope(TrainScope.repertoire);
      async.flushMicrotasks();
      final state = readyState(trainer);
      expect(state.chapters.map((c) => c.ref.name), ['Main', 'QGD']);
      expect(state.lines.map((l) => l.name), [
        'Ruy',
        'Italian',
        "Queen's Gambit",
      ]);
      expect(files.reads, 2);
    });
  });

  test('opening another chapter of the repertoire reads nothing again', () {
    fakeAsync((async) {
      final qgd = ref('KID', 'QGD');
      fixture.store.documents[qgd] = Opened(_other, scriptedRevision(_other));
      final listing = ScriptedFiles(
        listing: Repertoires([
          RepertoireFolder(
            name: 'KID',
            path: '/repertoires/KID',
            modified: _now,
            chapters: [fixture.ref, qgd],
          ),
        ]),
      );
      final trainer = ready(async, listing: listing)
        ..setScope(TrainScope.repertoire);
      async.flushMicrotasks();
      final before = readyState(trainer);
      unawaited(fixture.session.open(qgd));
      async.flushMicrotasks();
      expect(fixture.session.source, qgd);
      expect(files.reads, 2, reason: 'the chapter and the repertoire');
      expect(readyState(trainer).progress, same(before.progress));
      expect(readyState(trainer).lines.map((l) => l.name), [
        'Ruy',
        'Italian',
        "Queen's Gambit",
      ]);
    });
  });

  test('the lines sort as the tab asks, and a line reads up to a ply', () {
    fakeAsync((async) {
      final trainer = ready(async)..order = LineOrder.course;
      expect(trainer.order, LineOrder.course);
      final state = readyState(trainer);
      final italian = state.lines[1];
      expect(state.lineOf(italian.key), same(italian));
      final read = state.toRead(italian, ReadIn.board, ply: 2);
      expect(read.ref, fixture.ref);
      expect(read.sans, ['e4', 'e5']);
      expect(state.toRead(italian, ReadIn.moves).sans, hasLength(5));
    });
  });

  test('an edit to the open chapter changes its lines, not its progress', () {
    fakeAsync((async) {
      final trainer = ready(async);
      final before = readyState(trainer);
      fixture.session.toStart();
      fixture.session.playMove('d2d4');
      async.flushMicrotasks();
      expect(files.reads, 1);
      expect(readyState(trainer), isNot(same(before)));
      expect(readyState(trainer).progress, same(before.progress));
    });
  });

  test('a retry writes the rows the failed try worked out, not new ones', () {
    fakeAsync((async) {
      final ruy = (source: source(), id: 'line_ZTQgZTUgTmYzIE5jNiBCYj');
      files.reviews[ruy] = Review(
        key: ruy,
        lineName: 'Ruy',
        intervalDays: 10,
        lastRating: 'good',
        due: _now,
      );
      // Each spread is different, so a row worked out again would differ.
      var spread = 0.0;
      final trainer = Trainer(
        session: fixture.session,
        chapters: ScopeReader(files: ScriptedFiles(), documents: fixture.store),
        files: files,
        analysis: analysis,
        time: (now: () => _now, jitter: () => spread += 0.5),
        books: Books(store: MemoryBooks(), root: '/repertoires'),
      );
      addTearDown(trainer.dispose);
      trainer.show();
      async.flushMicrotasks();
      trainer.review();
      final lesson = trainer.lesson!;
      for (final uci in ['e2e4', 'g1f3', 'f1b5']) {
        play(async, lesson, uci);
      }
      files.nextWrite = const ProgressFailed('disk full');
      lesson.rate(Rating.good);
      async.flushMicrotasks();
      lesson.retry();
      async.flushMicrotasks();
      // 10 days × 2.5 = 25, spread by the first try's +0.5 of 1.25 days.
      expect(files.reviews[ruy]!.intervalDays, closeTo(25.625, 0.01));
    });
  });

  test('a line with none of the user\'s moves is never put in a sitting', () {
    fakeAsync((async) {
      fixture.session.closed();
      const stub = '''
// Color: Black

[Event "Stub"]

1. e4 *

[Event "Line"]

1. e4 e5 *
''';
      fixture.externalEdit(stub);
      fixture.session.open(fixture.ref);
      async.flushMicrotasks();
      final trainer = ready(async)..learn();
      expect(trainer.lesson!.left, 0);
      expect(trainer.lesson!.line.name, 'Line');
    });
  });

  test('Learn takes its lines from those with something to ask', () {
    fakeAsync((async) {
      fixture.session.closed();
      // More stubs than one sitting takes, ahead of the one real line.
      final stubs = [
        for (var i = 0; i < learnSitting + 2; i++)
          '[Event "Stub $i"]\n\n1. e4 *\n',
      ].join('\n');
      fixture.externalEdit(
        '// Color: Black\n\n$stubs\n[Event "Line"]\n\n1. e4 e5 *\n',
      );
      unawaited(fixture.session.open(fixture.ref));
      async.flushMicrotasks();
      final trainer = ready(async);
      expect(trainer.untrainedCount, 1, reason: 'the stubs ask nothing');
      trainer.learn();
      expect(trainer.lesson!.line.name, 'Line');
    });
  });

  test('a line restarted after a failed save lands that save first', () {
    fakeAsync((async) {
      final ruy = (source: source(), id: 'line_ZTQgZTUgTmYzIE5jNiBCYj');
      files.reviews[ruy] = Review(
        key: ruy,
        lineName: 'Ruy',
        intervalDays: 4,
        lastRating: 'good',
        due: _now,
      );
      final trainer = ready(async);
      trainer.review();
      final lesson = trainer.lesson!;
      for (final uci in ['e2e4', 'g1f3', 'f1b5']) {
        play(async, lesson, uci);
      }
      files.nextWrite = const ProgressFailed('disk full');
      lesson.rate(Rating.good);
      async.flushMicrotasks();
      expect(lesson.state, isA<LineNotSaved>());
      lesson.restart();
      for (final uci in ['e2e4', 'g1f3', 'f1b5']) {
        play(async, lesson, uci);
      }
      lesson.rate(Rating.easy);
      async.flushMicrotasks();
      expect(files.history.map((h) => h.rating), ['good', 'easy']);
      expect(files.reviews[ruy]!.lastRating, 'easy');
      expect(readyState(trainer).progress.stale, isFalse);
    });
  });

  test('a rating given while the last one is still unsaved is kept', () {
    fakeAsync((async) {
      final ruy = (source: source(), id: 'line_ZTQgZTUgTmYzIE5jNiBCYj');
      files.reviews[ruy] = Review(
        key: ruy,
        lineName: 'Ruy',
        intervalDays: 4,
        lastRating: 'good',
        due: _now,
      );
      final trainer = ready(async);
      trainer.review();
      final lesson = trainer.lesson!;
      for (final uci in ['e2e4', 'g1f3', 'f1b5']) {
        play(async, lesson, uci);
      }
      files.nextWrite = const ProgressFailed('disk full');
      lesson.rate(Rating.hard);
      async.flushMicrotasks();
      lesson.restart();
      for (final uci in ['e2e4', 'g1f3', 'f1b5']) {
        play(async, lesson, uci);
      }
      // The earlier rating fails again on the way to the new one.
      files.nextWrite = const ProgressFailed('disk full');
      lesson.rate(Rating.easy);
      async.flushMicrotasks();
      expect((lesson.state as LineNotSaved).rating, Rating.easy);
      lesson.retry();
      async.flushMicrotasks();
      expect(files.history.map((h) => h.rating), ['hard', 'easy']);
      expect(files.reviews[ruy]!.lastRating, 'easy');
      final [first, second] = files.reviewChanges;
      expect(second.before, first.after, reason: 'easy is rated on hard');
      expect(readyState(trainer).progress.stale, isFalse);
    });
  });

  test('the file open one game at a time, as the viewer opens it, is not '
      'trained; open whole again, it is', () {
    fakeAsync((async) {
      final trainer = ready(async)..learn();
      unawaited(fixture.session.open(fixture.ref, game: 0));
      async.flushMicrotasks();
      expect((trainer.state as TrainerEmpty).why, NothingToTrain.studyChapter);
      expect(trainer.lesson, isNull);
      unawaited(fixture.session.open(fixture.ref));
      async.flushMicrotasks();
      expect(readyState(trainer).lines.map((l) => l.name), ['Ruy', 'Italian']);
    });
  });

  test('disposing while the read barrier settles starts no later read', () {
    fakeAsync((async) {
      final trainer = Trainer(
        session: fixture.session,
        chapters: ScopeReader(files: ScriptedFiles(), documents: fixture.store),
        files: files,
        analysis: analysis,
        time: (now: () => _now, jitter: () => 0),
        books: Books(store: MemoryBooks(), root: '/repertoires'),
      )..show();
      trainer.dispose();
      async.flushMicrotasks();
      expect(files.reads, 0);
    });
  });

  test('reading the progress again ends the sitting over the old copy', () {
    fakeAsync((async) {
      final trainer = ready(async)..learn();
      expect(trainer.lesson, isNotNull);
      trainer.reload();
      async.flushMicrotasks();
      expect(trainer.lesson, isNull);
      expect(trainer.board.value, isNull);
      expect(trainer.state, isA<TrainerReady>());
    });
  });
}
