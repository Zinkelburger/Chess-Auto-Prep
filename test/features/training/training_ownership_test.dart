import 'dart:async';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/training/controllers/chapter_scope.dart';
import 'package:chess_auto_prep/features/training/controllers/review_progress_store.dart';
import 'package:chess_auto_prep/features/training/controllers/training_session_controller.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/features/training/repositories/training_answers.dart';
import 'package:chess_auto_prep/features/training/repositories/training_review_repository.dart';
import 'package:chess_auto_prep/features/training/repositories/training_settings_repository.dart';
import 'package:chess_auto_prep/features/training/repositories/training_source_repository.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/repertoire_move_progress.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/repertoire_review_history_entry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/repertoire_dependencies.dart';
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
    String? repertoireId,
  }) async {
    saveCalls++;
    await saveGate?.future;
    saved.addAll(entries.where((entry) => entry.repertoireId == repertoireId));
  }

  @override
  Future<void> saveMoveProgress(
    List<RepertoireMoveProgress> entries, {
    String? repertoireId,
  }) async {
    if (failMoves) throw StateError('move write unavailable');
  }

  @override
  Future<void> appendHistory(
    List<RepertoireReviewHistoryEntry> entries,
  ) async => history.addAll(entries);

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
    Map<String, RepertoireReviewEntry> entries,
  ) async {
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

class _Config implements TrainingSettingsRepository {
  Completer<TrainingSettings>? pending;
  @override
  Future<TrainingSettings> load() =>
      pending?.future ?? Future.value(TrainingSettings());
  @override
  Future<void> save(TrainingSettings settings) async {}
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
  late _Config config;
  late TrainingSessionController controller;
  setUp(() {
    reviews = _Reviews();
    headers = _Headers();
    source = _Source();
    config = _Config();
    controller = TrainingSessionController(
      session: testRepertoireController(),
      headers: headers,
      source: source,
      configuration: config,
      reviewService: reviews,
      askedQuestions: _Answers(),
    );
  });
  tearDown(() => controller.dispose());

  test(
    'ARCH-01/STATE-01 stale source cannot publish even if adapter ignores cancellation',
    () async {
      controller.setStudySource(_meta('/old.pgn'));
      final old = controller.loadRepertoire();
      controller.setStudySource(_meta('/new.pgn'));
      final current = controller.loadRepertoire();
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
      controller.currentLine = fakeLine('old', ['e4']);
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
    controller.settings.autoNext = false;
    controller.currentLine = fakeLine('line', ['e4']);
    await controller.rateLine(ReviewRating.good);
    await controller.rateLine(ReviewRating.easy);
    expect(reviews.history, hasLength(1));
    expect(controller.sessionCorrect, 1);
  });

  test(
    'DATA-06 retry resumes failed outcome without double scheduling or counts',
    () async {
      controller.setRepertoire(_meta('/line.pgn'));
      controller.settings.autoNext = false;
      controller.currentLine = fakeLine('line', ['e4']);
      reviews.failMoves = true;
      await controller.rateLine(ReviewRating.good);
      expect(controller.error, contains('Could not save rating'));
      expect(controller.sessionCorrect, 0);
      reviews.failMoves = false;
      await controller.rateLine(ReviewRating.good);
      expect(reviews.scheduleCalls, 1);
      expect(reviews.saveCalls, 1);
      expect(reviews.history, hasLength(1));
      expect(controller.reviewMap['line']!.passCount, 1);
      expect(controller.sessionCorrect, 1);
    },
  );

  test('STATE-01 linear completion callback commits once', () async {
    controller.setStudySource(_meta('/line.pgn'));
    controller.currentLine = fakeLine('line', ['e4']);
    controller.completeLine();
    controller.completeLine();
    await Future<void>.delayed(Duration.zero);
    expect(reviews.history, hasLength(1));
    expect(controller.sessionCorrect, 1);
  });

  test(
    'DATA-06 linear retry resumes after a partial write and tallies once',
    () async {
      controller.setStudySource(_meta('/line.pgn'));
      controller.currentLine = fakeLine('line', ['e4']);
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
    'STATE-01 failed old rating cannot replace new source error state',
    () async {
      controller.setRepertoire(_meta('/old.pgn'));
      controller.currentLine = fakeLine('old', ['e4']);
      reviews.saveGate = Completer();
      reviews.failMoves = true;
      final saving = controller.rateLine(ReviewRating.good);
      controller.setStudySource(_meta('/new.pgn'));
      reviews.saveGate!.complete();
      await saving;
      expect(controller.error, isNull);
    },
  );

  test('SET-01 later settings read wins over old asynchronous load', () async {
    config.pending = Completer();
    final old = controller.loadSettings();
    final oldPending = config.pending!;
    config.pending = Completer();
    final current = controller.loadSettings();
    config.pending!.complete(TrainingSettings(moveSpeedMs: 250));
    await current;
    oldPending.complete(TrainingSettings(moveSpeedMs: 1500));
    await old;
    expect(controller.settings.moveSpeedMs, 250);
  });

  test(
    'STATE-01 pending chapter answer cannot affect a newly selected source',
    () async {
      final answers = _Answers()..pending = Completer();
      final scope = ChapterScope(
        askedQuestions: answers,
        saveSettings: (_) async {},
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
      addTearDown(progress.dispose);
      await progress.recordRating(
        fakeLine('old', ['e4']),
        ReviewRating.good,
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
}
