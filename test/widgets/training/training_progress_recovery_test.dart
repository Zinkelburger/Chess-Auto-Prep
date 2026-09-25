import '../../support/training_source_fixture.dart';
import 'package:chess_auto_prep/features/training/models/training_source_context.dart';
import 'dart:async';

import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_board_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/training/controllers/training_session_controller.dart';
import 'package:chess_auto_prep/features/training/controllers/training_settings_controller.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/features/training/repositories/training_answers.dart';
import 'package:chess_auto_prep/features/training/repositories/training_review_repository.dart';
import 'package:chess_auto_prep/features/training/repositories/training_source_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/widgets/training/repertoire_selector_panel.dart';
import 'package:chess_auto_prep/widgets/training/trainer_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../services/training/training_fakes.dart';
import '../../support/training_settings.dart';

class _Reviews extends FakeReviewService {
  Completer<void>? gate;
  bool fail = false;
  int attempted = 0;
  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    required TrainingSourceContext source,
    String? repertoireId,
  }) async {
    attempted++;
    await gate?.future;
    if (fail) throw StateError('disk unavailable');
    await super.saveAll(entries, repertoireId: repertoireId, source: source);
  }
}

class _Headers implements TrainingHeaderRepository {
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<bool> updateManyLineReviewHeaders(
    String path,
    Map<String, RepertoireReviewEntry> entries, {
    required TrainingSourceContext source,
  }) async {
    await gate?.future;
    if (fail) throw StateError('header unavailable');
    return true;
  }
}

class _Source implements TrainingSourceRepository {
  _Source(this.reviews);
  final _Reviews reviews;
  bool fail = false;
  final reads = <String>[];
  @override
  Future<LoadedTrainingSource?> load(
    RepertoireMetadata source, {
    required bool isStudy,
    required bool? colorOverrideIsWhite,
    required bool Function() isStale,
    void Function(String)? onStatus,
  }) async {
    reads.add(source.filePath);
    if (fail) throw StateError('source unreadable');
    return LoadedTrainingSource(
      sources: scriptedTrainingSources([source.filePath]),
      lines: [
        fakeLine('A', ['e4']),
      ],
      reviewByLine: {
        for (final entry in reviews.entries)
          if (entry.repertoireId == source.filePath) entry.lineId: entry,
      },
      moveProgress: {},
      otherRepertoires: [],
      isFolder: false,
    );
  }

  @override
  Future<Map<String, double>> playabilityFromTree(
    String path,
    List<RepertoireLine> lines, {
    required bool Function() isStale,
  }) async => {};
}

class _Answers implements TrainingAnswers {
  @override
  Future<bool?> boolAnswerFor(
    String questionId, {
    String subject = '*',
  }) async => null;
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
  lastModified: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Reviews reviews;
  late _Headers headers;
  late _Source source;
  late TrainingSettingsController settings;
  late TrainingSessionController session;
  bool disposed = false;
  setUp(() async {
    disposed = false;
    reviews = _Reviews();
    headers = _Headers();
    source = _Source(reviews);
    settings = TrainingSettingsController(MemoryTrainingSettings());
    await settings.ensureLoaded();
    session = TrainingSessionController(
      session: RepertoireBoardController(),
      headers: headers,
      source: source,
      configuration: settings,
      reviewService: reviews,
      askedQuestions: _Answers(),
    );
    session.setStudySource(_meta('/a.pgn'));
    await session.loadRepertoire();
  });
  tearDown(() {
    if (!disposed) session.dispose();
    settings.dispose();
  });

  test(
    'failed bulk stays blocked through failed reload and never silently retries writes',
    () async {
      reviews.fail = true;
      await expectLater(session.applyLearnedSelection({'A'}), throwsStateError);
      expect(session.reviewMap, isEmpty);
      expect(session.progressNeedsReload, isTrue);
      reviews.fail = false;
      await expectLater(session.applyLearnedSelection({'A'}), throwsStateError);
      expect(reviews.entries, isEmpty);
      expect(reviews.attempted, 1);
      session.startLearnSession();
      expect(session.currentLine, isNull);
      await session.setLineExcluded(session.lines.first, true);
      session.updateMoveProgress(session.lines.first, 0, wasCorrect: true);
      expect(session.moveProgressMap, isEmpty);
      expect(reviews.attempted, 1);
      source.fail = true;
      await session.retryFailure();
      expect(session.progressNeedsReload, isTrue);
      expect(session.error, contains('source unreadable'));
      source.fail = false;
      await session.retryFailure();
      expect(session.progressNeedsReload, isFalse);
      expect(session.error, isNull);
      expect(session.reviewMap, isEmpty);
      expect(
        reviews.attempted,
        1,
        reason: 'recovery only reads saved progress',
      );
      await session.applyLearnedSelection({'A'});
      expect(reviews.entries.single.lineId, 'A');
    },
  );

  test(
    'source reload waits for admitted bulk and reads its committed schedule',
    () async {
      reviews.gate = Completer<void>();
      final saving = session.applyLearnedSelection({'A'});
      await Future<void>.delayed(Duration.zero);
      session.startLearnSession();
      expect(session.currentLine, isNull);
      final loading = session.loadRepertoire();
      await Future<void>.delayed(Duration.zero);
      expect(source.reads, ['/a.pgn']);
      expect(session.isLoading, isTrue);
      reviews.gate!.complete();
      expect(await saving, 1);
      await loading;
      expect(source.reads, ['/a.pgn', '/a.pgn']);
      expect(session.reviewMap['A']?.isNew, isFalse);
      expect(session.progressNeedsReload, isFalse);
    },
  );

  test(
    'exclusion failure is retained rather than an unhandled UI future',
    () async {
      reviews.fail = true;
      await session.setLineExcluded(session.lines.first, true);
      expect(session.reviewMap, isEmpty);
      expect(session.progressNeedsReload, isTrue);
      expect(session.error, contains('disk unavailable'));
      reviews.fail = false;
      await session.retryFailure();
      expect(session.progressNeedsReload, isFalse);
      expect(reviews.attempted, 1);
    },
  );

  for (final fail in [false, true]) {
    test(
      'A B A supersession suppresses old bulk ${fail ? 'failure' : 'publication'}',
      () async {
        reviews.gate = Completer<void>();
        reviews.fail = fail;
        final saving = session.applyLearnedSelection({'A'});
        final observed = fail ? expectLater(saving, throwsStateError) : saving;
        await Future<void>.delayed(Duration.zero);
        session.setStudySource(_meta('/b.pgn'));
        final b = session.loadRepertoire();
        session.setStudySource(_meta('/a.pgn'));
        final a = session.loadRepertoire();
        reviews.gate!.complete();
        await observed;
        await Future.wait([a, b]);
        expect(session.repertoireId, '/a.pgn');
        expect(session.error, isNull);
        expect(session.progressNeedsReload, isFalse);
        expect(source.reads, ['/a.pgn', '/a.pgn']);
        expect(session.reviewMap.isEmpty, fail);
      },
    );
  }

  for (final fail in [false, true]) {
    test(
      'dispose during bulk ${fail ? 'failure' : 'success'} suppresses publication',
      () async {
        reviews.gate = Completer<void>();
        reviews.fail = fail;
        int notifications = 0;
        session.addListener(() => notifications++);
        final saving = session.applyLearnedSelection({'A'});
        final observed = fail ? expectLater(saving, throwsStateError) : saving;
        await Future<void>.delayed(Duration.zero);
        session.dispose();
        disposed = true;
        final atDisposal = notifications;
        reviews.gate!.complete();
        await observed;
        expect(notifications, atDisposal);
        expect(session.reviewMap, isEmpty);
      },
    );
  }

  for (final spaced in [false, true]) {
    for (final stopWhilePending in [false, true]) {
      test(
        'abandoning ${stopWhilePending ? 'pending' : 'failed'} ${spaced ? 'rating' : 'completion'} requires reload when it fails',
        () async {
          if (spaced) {
            session.setRepetitionMode(RepetitionMode.spaced);
            session.settings = session.settings..showRatingButtons = false;
          }
          reviews.fail = true;
          if (stopWhilePending) reviews.gate = Completer<void>();
          session.currentLine = session.lines.first;
          session.completeLine();
          await Future<void>.delayed(Duration.zero);
          session.stopSession();
          reviews.gate?.complete();
          await session.progress.settleOutcomes();
          await Future<void>.delayed(Duration.zero);
          expect(session.progressNeedsReload, isTrue);
          await expectLater(
            session.applyLearnedSelection({'A'}),
            throwsStateError,
          );
          expect(reviews.attempted, 1);
          reviews.fail = false;
          await session.retryFailure();
          expect(session.reviewMap.values.single.passCount, 1);
          expect(reviews.history, hasLength(1));
          expect(session.progressNeedsReload, isFalse);
          expect(reviews.attempted, 2);
        },
      );
    }
  }

  test(
    'successful completion abandoned while pending does not require recovery',
    () async {
      reviews.gate = Completer<void>();
      session.currentLine = session.lines.first;
      session.completeLine();
      await Future<void>.delayed(Duration.zero);
      session.stopSession();
      reviews.gate!.complete();
      await session.progress.settleOutcomes();
      await Future<void>.delayed(Duration.zero);
      expect(session.progressNeedsReload, isFalse);
      expect(session.error, isNull);
      expect(reviews.entries.single.passCount, 1);
    },
  );

  test(
    'old same-path header callback cannot overwrite current source error',
    () async {
      await session.progress.recordRating(
        session.lines.first,
        ReviewRating.good,
        attempt: Object(),
        hadMistake: false,
      );
      headers.gate = Completer<void>();
      headers.fail = true;
      final flush = session.progress.flushHeaders();
      session.setStudySource(_meta('/b.pgn'));
      session.setStudySource(_meta('/a.pgn'));
      source.fail = true;
      final loading = session.loadRepertoire();
      await Future<void>.delayed(Duration.zero);
      expect(session.isLoading, isTrue);
      headers.gate!.complete();
      await flush;
      await loading;
      expect(session.error, contains('headers remain unconfirmed'));
      headers.fail = false;
      await session.retryFailure();
      expect(session.error, contains('source unreadable'));
    },
  );

  test(
    'source selection and failed load reject retained training commands',
    () async {
      final original = session.lines.single;
      session.setStudySource(_meta('/b.pgn'));
      Future<void> rejectOldCommands() async {
        session.startLearnSession();
        session.startLine(original);
        session.updateMoveProgress(original, 0, wasCorrect: true);
        await session.setLineExcluded(original, true);
        await expectLater(
          session.applyLearnedSelection({'A'}),
          throwsStateError,
        );
        expect(session.currentLine, isNull);
        expect(session.moveProgressMap, isEmpty);
        expect(reviews.attempted, 0);
      }

      await rejectOldCommands();
      source.fail = true;
      await session.loadRepertoire();
      await rejectOldCommands();
      source.fail = false;
      await session.loadRepertoire();
      session.startLine(original);
      session.updateMoveProgress(original, 0, wasCorrect: true);
      expect(session.currentLine, isNull);
      expect(session.moveProgressMap, isEmpty);
      session.setStudySource(_meta('/a.pgn'));
      await session.loadRepertoire();
      session.startLine(original);
      session.updateMoveProgress(original, 0, wasCorrect: true);
      expect(session.currentLine, isNull);
      expect(session.moveProgressMap, isEmpty);
      session.startLine(session.lines.single);
      expect(session.currentLine, same(session.lines.single));
    },
  );

  test('retained line exclusion rejects replacement source and ABA', () async {
    final original = session.lines.single;
    session.setStudySource(_meta('/b.pgn'));
    await session.loadRepertoire();
    await session.setLineExcluded(original, true);
    expect(reviews.attempted, 0);
    expect(session.reviewMap, isEmpty);
    session.setStudySource(_meta('/a.pgn'));
    await session.loadRepertoire();
    await session.setLineExcluded(original, true);
    expect(reviews.attempted, 0);
    await session.setLineExcluded(session.lines.single, true);
    expect(reviews.attempted, 1);
    expect(session.reviewMap['A']!.excluded, isTrue);
  });

  for (final replacement in ['B', 'ABA', 'reload']) {
    testWidgets('checkbox draft rejects $replacement before a frame', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: TrainerBrowser(session: session)),
        ),
      );
      await tester.tap(find.text('Mark lines I know'));
      await tester.pump();
      await tester.tap(find.text('Line A'));
      await tester.pump();
      final save = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed!;
      await tester.runAsync(() async {
        if (replacement != 'reload') {
          session.setStudySource(_meta('/b.pgn'));
          await session.loadRepertoire();
          if (replacement == 'ABA') session.setStudySource(_meta('/a.pgn'));
        }
        await session.loadRepertoire();
      });
      save();
      await tester.pump();
      expect(reviews.attempted, 0);
      expect(session.reviewMap, isEmpty);
      expect(find.text('Save'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'bulk failure leaves browser for localized durable reload, and failed reload stays actionable',
    (tester) async {
      reviews.fail = true;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (_, _) =>
                  session.error != null ||
                      session.progressNeedsReload ||
                      session.isLoading
                  ? RepertoireSelectorPanel(
                      isLoading: session.isLoading,
                      error: session.error,
                      progressNeedsReload: session.progressNeedsReload,
                      hasLines: true,
                      canStartTraining: false,
                      onSelectRepertoire: () {},
                      onRetry: () => unawaited(session.retryFailure()),
                    )
                  : TrainerBrowser(session: session),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Mark lines I know'));
      await tester.pump();
      await tester.tap(find.text('Line A'));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('Reload saved progress'), findsOneWidget);
      expect(find.textContaining('may be partly saved'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Save'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(reviews.attempted, 1);
      source.fail = true;
      await tester.runAsync(() async {
        await tester.tap(find.text('Reload saved progress'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('Reload saved progress'), findsOneWidget);
      expect(reviews.attempted, 1);
      source.fail = false;
      reviews.fail = false;
      await tester.runAsync(() async {
        await tester.tap(find.text('Reload saved progress'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('Mark lines I know'), findsOneWidget);
      expect(find.text('Untrained'), findsOneWidget);
      expect(reviews.attempted, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
