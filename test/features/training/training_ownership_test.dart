import 'package:chess_auto_prep/features/training/models/training_history_operation.dart';
import '../../support/training_source_fixture.dart';
import 'package:chess_auto_prep/features/training/models/training_source_context.dart';
import 'package:chess_auto_prep/features/training/models/training_phase.dart';
import 'package:chess_auto_prep/features/training/models/training_configuration.dart';
import 'package:chess_auto_prep/features/training/controllers/training_settings_controller.dart';
import '../../support/training_settings.dart';
import 'dart:async';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/training/controllers/chapter_scope.dart';
import 'package:chess_auto_prep/features/training/controllers/review_progress_store.dart';
import 'package:chess_auto_prep/features/training/controllers/training_session_controller.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/features/training/repositories/training_answers.dart';
import 'package:chess_auto_prep/features/training/repositories/training_review_repository.dart';
import 'package:chess_auto_prep/features/training/repositories/training_source_repository.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/repertoire_move_progress.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/repertoire_review_history_entry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_board_controller.dart';
import '../../services/training/training_fakes.dart' show fakeLine;

class _Reviews implements TrainingReviewRepository {
  Completer<void>? saveGate;
  bool failMoves = false;
  int scheduleCalls = 0;
  int saveCalls = 0;
  final history = <RepertoireReviewHistoryEntry>[];
  final saved = <RepertoireReviewEntry>[];

  @override
  RepertoireReviewEntry applyRating(
    RepertoireReviewEntry entry,
    ReviewRating rating,
  ) {
    scheduleCalls++;
    return entry.copyWith(lastRating: rating.name, intervalDays: 1);
  }

  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    required TrainingSourceContext source,
    String? repertoireId,
  }) async {
    saveCalls++;
    await saveGate?.future;
    saved.addAll(entries.where((entry) => entry.repertoireId == repertoireId));
  }

  @override
  Future<void> saveMoveProgress(
    List<RepertoireMoveProgress> entries, {
    required TrainingSourceContext source,
    String? repertoireId,
  }) async {
    if (failMoves) throw StateError('move write unavailable');
  }

  @override
  Future<void> appendHistory(
    List<RepertoireReviewHistoryEntry> entries, {
    required TrainingSourceContext source,
    required TrainingHistoryOperation operation,
  }) async => history.addAll(entries);

  @override
  List<RepertoireLine> orderLinesForReview(
    List<RepertoireLine> lines,
    Map<String, RepertoireReviewEntry> reviewMap,
    ReviewOrder order, {
    Map<String, double>? playabilityMap,
    bool dueOnly = true,
  }) => List.of(lines);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements TrainingHeaderRepository {
  bool fail = false;
  final paths = <String>[];
  @override
  Future<bool> updateManyLineReviewHeaders(
    String sourcePath,
    Map<String, RepertoireReviewEntry> entries, {
    required TrainingSourceContext source,
  }) async {
    if (fail) throw StateError('source unavailable');
    paths.add(sourcePath);
    return true;
  }
}

class _Source implements TrainingSourceRepository {
  final pending = <String, Completer<LoadedTrainingSource?>>{};
  @override
  Future<LoadedTrainingSource?> load(
    RepertoireMetadata source, {
    required bool isStudy,
    required bool? colorOverrideIsWhite,
    required bool Function() isStale,
    void Function(String status)? onStatus,
  }) => (pending[source.filePath] = Completer()).future;
  @override
  Future<Map<String, double>> playabilityFromTree(
    String path,
    List<RepertoireLine> lines, {
    required bool Function() isStale,
  }) async => {};
}

class _Answers implements TrainingAnswers {
  Completer<bool?>? pending;
  @override
  Future<bool?> boolAnswerFor(
    String questionId, {
    String subject = '*',
  }) async => pending == null ? null : await pending!.future;
  @override
  Future<void> record(
    String questionId, {
    String subject = '*',
    required bool answer,
    String? note,
    DateTime? askedUtc,
  }) async {}
  @override
  Future<void> forget(String questionId, {String? subject}) async {}
}

RepertoireMetadata _meta(String path) => RepertoireMetadata(
  filePath: path,
  name: path,
  lastModified: DateTime.utc(2026),
);
LoadedTrainingSource _loaded(String id) => LoadedTrainingSource(
  sources: scriptedTrainingSources(['/$id.pgn']),
  lines: [
    fakeLine(id, ['e4']),
  ],
  reviewByLine: {},
  moveProgress: {},
  otherRepertoires: [],
  isFolder: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Reviews reviews;
  late _Headers headers;
  late _Source source;
  late MemoryTrainingSettings config;
  late TrainingSettingsController settingsOwner;
  late TrainingSessionController controller;
  var disposed = false;
  setUp(() {
    disposed = false;
    reviews = _Reviews();
    headers = _Headers();
    source = _Source();
    config = MemoryTrainingSettings();
    settingsOwner = TrainingSettingsController(config);
    controller = TrainingSessionController(
      session: RepertoireBoardController(),
      headers: headers,
      source: source,
      configuration: settingsOwner,
      reviewService: reviews,
      askedQuestions: _Answers(),
    )..isLoading = false;
    controller.progress.sources = scriptedTrainingSources([
      '/line.pgn',
      '/new.pgn',
      '/old.pgn',
    ]);
  });
  tearDown(() {
    if (!disposed) controller.dispose();
    settingsOwner.dispose();
  });

  test(
    'ARCH-01/STATE-01 stale source cannot publish even if adapter ignores cancellation',
    () async {
      controller.setStudySource(_meta('/old.pgn'));
      final old = controller.loadRepertoire();
      await Future<void>.delayed(Duration.zero);
      controller.setStudySource(_meta('/new.pgn'));
      final current = controller.loadRepertoire();
      await Future<void>.delayed(Duration.zero);
      source.pending['/new.pgn']!.complete(_loaded('new'));
      await current;
      source.pending['/old.pgn']!.complete(_loaded('old'));
      await old;
      expect(controller.lines.single.id, 'new');
      expect(controller.isLoading, isFalse);
    },
  );

  test(
    'STATE-01 selecting a source invalidates pending rating advancement',
    () async {
      controller.setRepertoire(_meta('/old.pgn'));
      controller.isLoading = false;
      controller.currentLine = fakeLine('old', ['e4']);
      controller.phase = TrainingPhase.finished;
      reviews.saveGate = Completer();
      final saving = controller.rateLine(ReviewRating.good);
      controller.setStudySource(_meta('/new.pgn'));
      reviews.saveGate!.complete();
      await saving;
      expect(controller.currentLine, isNull);
      expect(controller.runComplete, isFalse);
      expect(controller.sessionCorrect, 0);
      expect(reviews.history.single.repertoireId, '/old.pgn');
    },
  );

  test('STATE-01 repeated finished-line rating records one outcome', () async {
    controller.setRepertoire(_meta('/line.pgn'));
    controller.settings = controller.settings..autoNext = false;
    controller.isLoading = false;
    controller.currentLine = fakeLine('line', ['e4']);
    controller.phase = TrainingPhase.finished;
    await controller.rateLine(ReviewRating.good);
    await controller.rateLine(ReviewRating.easy);
    expect(reviews.history, hasLength(1));
    expect(controller.sessionCorrect, 1);
  });

  test(
    'DATA-06 retry resumes failed outcome without double scheduling or counts',
    () async {
      controller.setRepertoire(_meta('/line.pgn'));
      controller.settings = controller.settings..autoNext = false;
      controller.isLoading = false;
      controller.currentLine = fakeLine('line', ['e4']);
      controller.phase = TrainingPhase.finished;
      reviews.failMoves = true;
      await controller.rateLine(ReviewRating.good);
      expect(controller.error, contains('Could not save rating'));
      expect(controller.sessionCorrect, 0);
      reviews.failMoves = false;
      await controller.retryFailure();
      expect(reviews.scheduleCalls, 1);
      expect(reviews.saveCalls, 1);
      expect(reviews.history, hasLength(1));
      expect(controller.reviewMap['line']!.passCount, 1);
      expect(controller.sessionCorrect, 1);
    },
  );

  test('STATE-01 linear completion callback commits once', () async {
    controller.setStudySource(_meta('/line.pgn'));
    controller.isLoading = false;
    controller.currentLine = fakeLine('line', ['e4']);
    controller.phase = TrainingPhase.finished;
    controller.completeLine();
    controller.completeLine();
    await Future<void>.delayed(Duration.zero);
    expect(reviews.history, hasLength(1));
    expect(controller.sessionCorrect, 1);
  });

  test('linear completion waits for persistence before any advance', () async {
    controller.setStudySource(_meta('/line.pgn'));
    final first = fakeLine('first', ['e4']);
    final second = fakeLine('second', ['d4']);
    controller.lines = [first, second];
    controller.isLoading = false;
    controller.currentLine = first;
    reviews.saveGate = Completer();
    controller.completeLine();
    controller.nextLine();
    controller.skipLine();
    controller.restartLine();
    await controller.setLineExcluded(first, true);
    expect(controller.reviewMap[first.id]?.excluded, isNot(true));
    await controller.rateLine(ReviewRating.good);
    expect(controller.currentLine, same(first));
    expect(controller.sessionCorrect, 0);
    await Future<void>.delayed(Duration.zero);
    expect(reviews.saveCalls, 1);
    reviews.saveGate!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentLine, same(second));
    expect(controller.sessionCorrect, 1);
    expect(reviews.history, hasLength(1));
  });

  test(
    'failed linear completion retains the original result until retry',
    () async {
      controller.setStudySource(_meta('/line.pgn'));
      final first = fakeLine('first', ['e4']);
      final second = fakeLine('second', ['d4']);
      controller.lines = [first, second];
      controller.isLoading = false;
      controller.currentLine = first;
      reviews.failMoves = true;
      controller.completeLine();
      await Future<void>.delayed(Duration.zero);
      controller.nextLine();
      controller.skipLine();
      controller.restartLine();
      controller.completeLine();
      await controller.setLineExcluded(first, true);
      expect(controller.reviewMap[first.id]?.excluded, isNot(true));
      expect(controller.currentLine, same(first));
      expect(controller.error, contains('Could not save completion'));
      expect(controller.sessionCorrect, 0);
      reviews.failMoves = false;
      // Retry must tally the captured result, not this later presentation edit.
      controller.lineHadMistake = true;
      await controller.retryFailure();
      expect(controller.currentLine, same(second));
      expect(controller.sessionCorrect, 1);
      expect(controller.sessionIncorrect, 0);
      expect(reviews.history.single.hadMistake, isFalse);
      expect(reviews.saveCalls, 1);
    },
  );

  test(
    'restarted line queues a distinct result behind its previous save',
    () async {
      controller.setRepertoire(_meta('/line.pgn'));
      controller.settings = controller.settings
        ..showRatingButtons = false
        ..autoNext = false;
      final line = fakeLine('line', ['e4']);
      controller.isLoading = false;
      controller.currentLine = line;
      reviews.saveGate = Completer();
      controller.completeLine();
      await Future<void>.delayed(Duration.zero);
      controller.stopSession();
      controller.isLoading = false;
      controller.currentLine = line;
      controller.lineHadMistake = true;
      controller.completeLine();
      controller.completeLine();
      await Future<void>.delayed(Duration.zero);
      expect(reviews.saveCalls, 1);
      expect(controller.completionBusy, isTrue);
      expect(controller.canAdvance, isFalse);
      reviews.saveGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(reviews.history.map((entry) => entry.rating), ['good', 'again']);
      expect(reviews.history.map((entry) => entry.hadMistake), [false, true]);
      expect(reviews.saveCalls, 2);
      expect(reviews.saved.last.passCount, 1);
      expect(reviews.saved.last.failCount, 1);
      expect(controller.sessionCorrect, 0);
      expect(controller.sessionIncorrect, 1);
      expect(controller.completionCommitted, isTrue);
      expect(controller.canAdvance, isTrue);
    },
  );

  test(
    'same-source reload waits for prior save before adopting review counts',
    () async {
      controller.setRepertoire(_meta('/line.pgn'));
      controller.settings = controller.settings..autoNext = false;
      final line = fakeLine('line', ['e4']);
      controller.isLoading = false;
      controller.currentLine = line;
      controller.phase = TrainingPhase.finished;
      reviews.saveGate = Completer();
      final first = controller.rateLine(ReviewRating.good);
      await Future<void>.delayed(Duration.zero);
      final loading = controller.loadRepertoire();
      await Future<void>.delayed(Duration.zero);
      expect(source.pending, isEmpty);
      reviews.saveGate!.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(source.pending.keys, ['/line.pgn']);
      source.pending['/line.pgn']!.complete(
        LoadedTrainingSource(
          sources: scriptedTrainingSources(['/line.pgn']),
          lines: [line],
          reviewByLine: {line.id: reviews.saved.single},
          moveProgress: {},
          otherRepertoires: [],
          isFolder: false,
        ),
      );
      await loading;
      controller.isLoading = false;
      controller.currentLine = line;
      controller.phase = TrainingPhase.finished;
      controller.lineHadMistake = true;
      await controller.rateLine(ReviewRating.again);
      expect(reviews.history.map((entry) => entry.rating), ['good', 'again']);
      expect(reviews.saved.last.passCount, 1);
      expect(reviews.saved.last.failCount, 1);
      expect(controller.sessionCorrect, 0);
      expect(controller.sessionIncorrect, 1);
    },
  );

  test('automatic spaced rating needs no mounted result widget', () async {
    controller.setRepertoire(_meta('/line.pgn'));
    controller.settings = controller.settings
      ..showRatingButtons = false
      ..autoNext = false;
    controller.isLoading = false;
    controller.currentLine = fakeLine('first', ['e4']);
    controller.lineHadMistake = true;
    controller.completeLine();
    await Future<void>.delayed(Duration.zero);
    expect(reviews.scheduleCalls, 1);
    expect(reviews.history.single.rating, ReviewRating.again.name);
    expect(controller.sessionIncorrect, 1);
    controller.completeLine();
    await Future<void>.delayed(Duration.zero);
    expect(reviews.history, hasLength(1));
  });

  for (final end in ['source', 'stop', 'dispose']) {
    test(
      'pending linear completion settles original writes after $end without publishing',
      () async {
        controller.setStudySource(_meta('/old.pgn'));
        controller.isLoading = false;
        controller.currentLine = fakeLine('old', ['e4']);
        reviews.saveGate = Completer();
        controller.completeLine();
        if (end == 'source') {
          controller.setStudySource(_meta('/new.pgn'));
        } else if (end == 'stop') {
          controller.stopSession();
        } else {
          controller.dispose();
          disposed = true;
        }
        reviews.saveGate!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(reviews.history.single.repertoireId, '/old.pgn');
        expect(controller.sessionCorrect, 0);
        expect(controller.runComplete, isFalse);
        if (end != 'dispose') expect(controller.currentLine, isNull);
      },
    );
  }

  test(
    'DATA-06 linear retry resumes after a partial write and tallies once',
    () async {
      controller.setStudySource(_meta('/line.pgn'));
      controller.isLoading = false;
      controller.currentLine = fakeLine('line', ['e4']);
      controller.phase = TrainingPhase.finished;
      reviews.failMoves = true;
      controller.completeLine();
      await Future<void>.delayed(Duration.zero);
      expect(controller.error, contains('Could not save completion'));
      expect(controller.sessionCorrect, 0);
      reviews.failMoves = false;
      await controller.retryFailure();
      expect(reviews.saveCalls, 1);
      expect(reviews.history, hasLength(1));
      expect(controller.sessionCorrect, 1);
      controller.completeLine();
      await Future<void>.delayed(Duration.zero);
      expect(controller.sessionCorrect, 1);
    },
  );

  test(
    'cancelled partial outcome settles before the next source can complete',
    () async {
      controller.setRepertoire(_meta('/old.pgn'));
      controller.isLoading = false;
      controller.currentLine = fakeLine('old', ['e4']);
      controller.phase = TrainingPhase.finished;
      reviews.saveGate = Completer();
      reviews.failMoves = true;
      final saving = controller.rateLine(ReviewRating.good);
      controller.setStudySource(_meta('/new.pgn'));
      reviews.saveGate!.complete();
      await saving;
      expect(controller.error, isNull);
      expect(reviews.history, isEmpty);
      reviews.failMoves = false;
      await controller.loadRepertoire();
      expect(controller.error, contains('partly saved'));
      expect(source.pending.containsKey('/new.pgn'), isFalse);
      final loading = controller.retryFailure();
      await Future<void>.delayed(Duration.zero);
      source.pending['/new.pgn']!.complete(_loaded('new'));
      await loading;
      controller.settings = controller.settings..autoNext = false;
      controller.currentLine = controller.lines.single;
      controller.completeLine();
      await Future<void>.delayed(Duration.zero);
      expect(controller.completionCommitted, isTrue);
      expect(controller.sessionCorrect, 1);
      expect(reviews.history.map((entry) => entry.repertoireId), [
        '/old.pgn',
        '/new.pgn',
      ]);
      expect(reviews.history.map((entry) => entry.rating), ['good', '']);
      expect(reviews.scheduleCalls, 1);
      expect(controller.error, isNull);
    },
  );

  test(
    'SET-01 committed changes apply next sitting, not between auto-next lines',
    () async {
      config.value = TrainingConfiguration(
        TrainingSettings(
          moveSpeedMs: 1,
          introSpeedMs: 1,
          skipToFirstComment: false,
          newLinesPerSession: 3,
        ),
      );
      await controller.loadSettings();
      final first = fakeLine('first', ['e4']);
      final second = fakeLine('second', ['d4']);
      controller.lines = [first, second];
      controller.isLoading = false;
      controller.startLine(first);
      await settingsOwner.edit(
        trainingEdit(settingsOwner.state.committed!, (draft) {
          draft.moveSpeedMs = 900;
          draft.newLinesPerSession = 1;
        }),
      );
      expect(settingsOwner.state.committed!.toSettings().moveSpeedMs, 900);
      expect(controller.settings.moveSpeedMs, 1);
      expect(controller.settings.newLinesPerSession, 3);
      controller.startLine(second, keepRunScope: true);
      expect(controller.settings.moveSpeedMs, 1);
      controller.stopSession();
      expect(controller.settings.moveSpeedMs, 900);
      controller.startLearnSession();
      expect(controller.settings.newLinesPerSession, 1);
      expect(controller.remainingInRun, 1);
    },
  );

  test(
    'SET-01 a failed preference never becomes the active sitting configuration',
    () async {
      config.value = TrainingConfiguration(TrainingSettings(moveSpeedMs: 1));
      await controller.loadSettings();
      config.failWrites = true;
      await expectLater(
        settingsOwner.edit(
          trainingEdit(
            settingsOwner.state.committed!,
            (draft) => draft.moveSpeedMs = 900,
          ),
        ),
        throwsStateError,
      );
      controller.lines = [
        fakeLine('line', ['e4']),
      ];
      controller.startLine(controller.lines.single);
      expect(controller.settings.moveSpeedMs, 1);
      config.failWrites = false;
      await settingsOwner.retry();
      expect(controller.settings.moveSpeedMs, 1);
      controller.stopSession();
      expect(controller.settings.moveSpeedMs, 900);
    },
  );

  test(
    'STATE-01 pending chapter answer cannot affect a newly selected source',
    () async {
      final answers = _Answers()..pending = Completer();
      final scope = ChapterScope(
        askedQuestions: answers,
        saveSettings: (before, after) async {
          before.chapterGrouping = after.chapterGrouping;
        },
        settings: () => TrainingSettings(),
        lines: () => [
          fakeLine('line', ['e4'], chapter: 'Chapter 1'),
        ],
        sourceIsStudy: () => false,
      );
      final loading = scope.resolveLayout('/old.pgn', isStudy: false);
      scope.cancelPending();
      await scope.resolveLayout('/new.pgn', isStudy: true);
      answers.pending!.complete(false);
      await loading;
      expect(scope.declined, isFalse);
      expect(scope.pendingPrompt, isNull);
    },
  );

  test(
    'DATA-06 failed header mirrors retain original source and retry',
    () async {
      var path = '/old.pgn';
      final failures = <Object>[];
      final progress = ReviewProgressStore(
        reviewService: reviews,
        headers: headers,
        settings: () => TrainingSettings(),
        repertoireId: () => path,
        onError: failures.add,
      );
      progress.sources = scriptedTrainingSources(['/old.pgn']);
      addTearDown(progress.dispose);
      await progress.recordRating(
        fakeLine('old', ['e4']),
        ReviewRating.good,
        attempt: Object(),
        hadMistake: false,
      );
      headers.fail = true;
      await progress.flushHeaders();
      path = '/new.pgn';
      headers.fail = false;
      await progress.flushHeaders();
      expect(failures, hasLength(1));
      expect(headers.paths, ['/old.pgn']);
      expect(reviews.history, hasLength(1));
    },
  );
  test(
    'SET-01 failed initial settings read blocks source startup until retry',
    () async {
      config.failReads = true;
      await controller.loadSettings();
      controller.setStudySource(_meta('/line.pgn'));
      await controller.loadRepertoire();
      expect(source.pending, isEmpty);
      expect(controller.error, 'Training settings could not be loaded.');
      config.failReads = false;
      final retry = controller.retryFailure();
      await Future<void>.delayed(Duration.zero);
      source.pending['/line.pgn']!.complete(_loaded('line'));
      await retry;
      expect(controller.error, isNull);
      expect(controller.lines.single.id, 'line');
    },
  );
}
