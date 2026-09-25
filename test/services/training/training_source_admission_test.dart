import 'dart:io';
import 'dart:async';
import 'package:chess_auto_prep/features/training/models/training_history_operation.dart';
import 'package:chess_auto_prep/features/training/controllers/review_progress_store.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/app/training_dependencies.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_board_controller.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/infrastructure/training/training_source_loader.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/services/asked_questions_store.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import '../../support/generation_artifacts_fixture.dart';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/training/models/training_source_context.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/training/training_source_admission.dart';
import 'package:chess_auto_prep/models/repertoire_move_progress.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/repertoire_review_history_entry.dart';
import 'package:chess_auto_prep/services/repertoire_file_editor.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const text = '[Event "Line"]\n[LineID "line"]\n\n1. e4 e5 *\n';
  late Directory profile;
  late Directory documents;
  late File file;
  late IOStorageService storage;
  late NativePgnDocumentStore native;
  late RepertoireReviewService reviews;
  late TrainingSourceContext source;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    profile = await Directory.systemTemp.createTemp('training-admission-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    final support = await Directory(p.join(profile.path, 'Support')).create();
    file = File(p.join(documents.path, 'chapter.pgn'));
    await file.writeAsString(text);
    storage = IOStorageService(documentsRoot: documents, supportRoot: support);
    native = NativePgnDocumentStore(
      guardOperation: storage.guardDocumentOperation,
    );
    final opened = await native.open(file.path) as PgnOpened;
    source = TrainingSourceContext(path: file.path, snapshot: opened.snapshot);
    reviews = RepertoireReviewService(storage: storage);
  });
  tearDown(() async {
    StorageFactory.instanceForTest = null;
    await profile.delete(recursive: true);
  });

  RepertoireReviewEntry entry() => RepertoireReviewEntry(
    repertoireId: file.path,
    lineId: 'line',
    lineName: 'Line',
    passCount: 1,
  );

  Future<void> attempt() => reviews.recordAttempt(
    source: source,
    repertoireId: file.path,
    lineId: 'line',
    moveIndex: 0,
    fen: 'fixture',
    playedSan: 'e4',
    expectedSan: 'e4',
    correct: true,
    phase: 'learning',
  );

  Future<void> history() => reviews.appendHistory(
    [
      RepertoireReviewHistoryEntry(
        repertoireId: file.path,
        lineId: 'line',
        timestampUtc: DateTime.utc(2026),
        rating: 'good',
        hadMistake: false,
      ),
    ],
    source: source,
    operation: TrainingHistoryOperation(),
  );

  Future<void> moves() => reviews.saveMoveProgress([
    RepertoireMoveProgress(
      repertoireId: file.path,
      lineId: 'line',
      moveIndex: 0,
      correctStreak: 1,
      learned: false,
    ),
  ], source: source);

  for (final mutation in ['move', 'identical replacement', 'reused path']) {
    for (final kind in ['rating', 'attempt', 'history', 'moves', 'headers']) {
      test('first $kind refuses source after $mutation', () async {
        if (mutation == 'identical replacement') {
          final replacement = File(p.join(documents.path, 'replacement.pgn'));
          await replacement.writeAsString(text);
          await replacement.rename(file.path);
        } else {
          await storage.renameFile(
            file.path,
            p.join(documents.path, 'moved.pgn'),
          );
          if (mutation == 'reused path') await file.writeAsString(text);
        }
        final write = switch (kind) {
          'rating' => reviews.saveAll([entry()], source: source),
          'attempt' => attempt(),
          'history' => history(),
          'moves' => moves(),
          _ =>
            RepertoireFileEditor(documents: native).updateManyLineReviewHeaders(
              file.path,
              {'line': entry()},
              source: source,
            ),
        };
        await expectLater(write, throwsA(isA<StateError>()));
        expect(await reviews.loadAll(), isEmpty);
        expect(await reviews.loadHistory(), isEmpty);
        expect(await reviews.loadMoveProgress(), isEmpty);
        expect(await reviews.loadAttempts(), isEmpty);
        if (mutation != 'move') expect(await file.readAsString(), text);
      }, skip: !Platform.isLinux);
    }
  }

  for (final failMirror in [false, true]) {
    test(
      'reload settles deferred native headers before source capture (failure=$failMirror)',
      () async {
        StorageFactory.instanceForTest = storage;
        final editor = _FailingHeaderEditor(native);
        final configuration = createTrainingSettings();
        final board = RepertoireBoardController();
        final controller = createTrainingSession(
          session: board,
          configuration: configuration,
          documents: native,
          reviewService: reviews,
          repertoireService: _HeaderRepertoire(editor),
          artifacts: generationArtifactsFixture().repository,
        );
        addTearDown(controller.dispose);
        addTearDown(board.dispose);
        addTearDown(configuration.dispose);
        controller.setRepertoire(
          RepertoireMetadata(
            filePath: file.path,
            name: 'chapter',
            lastModified: DateTime.utc(2026),
          ),
        );
        await controller.loadRepertoire();
        expect(controller.error, isNull);
        await controller.progress.recordRating(
          controller.lines.single,
          ReviewRating.good,
          attempt: Object(),
          hadMistake: false,
        );
        editor.fail = failMirror;
        await controller.loadRepertoire();
        if (failMirror) {
          expect(
            controller.error,
            isNotNull,
            reason:
                'An unresolved mirror must be visible before adopting another context',
          );
          expect((await reviews.loadHistory()), hasLength(1));
          editor.fail = false;
          await controller.retryFailure();
        }
        expect(controller.error, isNull);
        await controller.progress.flushHeaders();
        await validateTrainingSource(
          controller.progress.sourceFor(file.path),
          file.path,
        );
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'same accepted history append reconciles publication with lost acknowledgement',
    () async {
      final lost = _LostHistoryAckStorage(
        documents,
        Directory(p.join(profile.path, 'Support')),
      );
      final service = RepertoireReviewService(storage: lost);
      final operation = TrainingHistoryOperation();
      final entries = [
        RepertoireReviewHistoryEntry(
          repertoireId: file.path,
          lineId: 'line',
          timestampUtc: DateTime.utc(2026),
          rating: 'good',
          hadMistake: false,
        ),
      ];
      await expectLater(
        service.appendHistory(entries, source: source, operation: operation),
        throwsStateError,
      );
      expect(await service.loadHistory(), hasLength(1));
      final before = await File(
        p.join(documents.path, 'repertoire_review_history.csv'),
      ).readAsString();
      await service.appendHistory(
        entries,
        source: source,
        operation: operation,
      );
      await service.appendHistory(
        entries,
        source: source,
        operation: operation,
      );
      expect(
        await File(
          p.join(documents.path, 'repertoire_review_history.csv'),
        ).readAsString(),
        before,
      );
      expect(await service.loadHistory(), hasLength(1));
      await service.appendHistory(
        entries,
        source: source,
        operation: TrainingHistoryOperation(),
      );
      expect(
        await service.loadHistory(),
        hasLength(2),
        reason: 'A new accepted identical row is distinct',
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'unresolved history retry preserves a later independent append',
    () async {
      final lost = _LostHistoryAckStorage(
        documents,
        Directory(p.join(profile.path, 'Support')),
      );
      final service = RepertoireReviewService(storage: lost);
      final operation = TrainingHistoryOperation();
      RepertoireReviewHistoryEntry row(String line) =>
          RepertoireReviewHistoryEntry(
            repertoireId: file.path,
            lineId: line,
            timestampUtc: DateTime.utc(2026),
            rating: 'good',
            hadMistake: false,
          );
      final entries = [row('first')];
      await expectLater(
        service.appendHistory(entries, source: source, operation: operation),
        throwsStateError,
      );
      await expectLater(
        service.appendHistory(
          [row('changed')],
          source: source,
          operation: operation,
        ),
        throwsStateError,
      );
      await service.appendHistory(
        [row('independent')],
        source: source,
        operation: TrainingHistoryOperation(),
      );
      final csv = File(p.join(documents.path, 'repertoire_review_history.csv'));
      final preserved = await csv.readAsString();
      await expectLater(
        service.appendHistory(entries, source: source, operation: operation),
        throwsStateError,
      );
      expect(await csv.readAsString(), preserved);
      expect((await service.loadHistory()).map((entry) => entry.lineId), [
        'first',
        'independent',
      ]);
    },
    skip: !Platform.isLinux,
  );

  for (final unknown in [false, true]) {
    test(
      'automatic reload retains ${unknown ? 'unknown' : 'partial'} rating until exact retry',
      () async {
        StorageFactory.instanceForTest = storage;
        final failing = _FailingWrites(storage);
        final configuration = createTrainingSettings();
        final board = RepertoireBoardController();
        final controller = createTrainingSession(
          session: board,
          configuration: configuration,
          documents: native,
          reviewService: failing,
          artifacts: generationArtifactsFixture().repository,
        );
        addTearDown(controller.dispose);
        addTearDown(board.dispose);
        addTearDown(configuration.dispose);
        controller.setRepertoire(
          RepertoireMetadata(
            filePath: file.path,
            name: 'chapter',
            lastModified: DateTime.utc(2026),
          ),
        );
        await controller.loadRepertoire();
        final accepted = controller.progress.sourceFor(file.path);
        failing.failReviewAfter = unknown;
        failing.failHistoryBefore = !unknown;
        await expectLater(
          controller.progress.recordRating(
            controller.lines.single,
            ReviewRating.good,
            attempt: Object(),
            hadMistake: false,
          ),
          throwsStateError,
        );
        final published = await File(
          p.join(documents.path, 'repertoire_reviews.csv'),
        ).readAsString();
        await controller.loadRepertoire();
        expect(controller.error, contains('partly saved'));
        expect(
          identical(controller.progress.sourceFor(file.path), accepted),
          isTrue,
        );
        expect(await failing.loadHistory(), isEmpty);
        failing.failReviewAfter = false;
        failing.failHistoryBefore = false;
        final retained = await file.rename(
          p.join(documents.path, 'retained.pgn'),
        );
        await file.writeAsString(text);
        await controller.retryFailure();
        expect(controller.error, contains('needs recovery'));
        expect(
          identical(controller.progress.sourceFor(file.path), accepted),
          isTrue,
        );
        expect(await failing.loadHistory(), isEmpty);
        await file.delete();
        await retained.rename(file.path);
        await controller.retryFailure();
        expect(controller.error, isNull);
        expect(
          await File(
            p.join(documents.path, 'repertoire_reviews.csv'),
          ).readAsString(),
          published,
        );
        expect((await failing.loadAll()).single.passCount, 1);
        expect(await failing.loadHistory(), hasLength(1));
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'proven first-stage source rejection asks for reload without writing rows',
    () async {
      final progress = ReviewProgressStore(
        reviewService: reviews,
        headers: RepertoireFileEditor(documents: native),
        settings: () => TrainingSettings(),
        repertoireId: () => file.path,
      )..sources = {file.path: source};
      addTearDown(progress.dispose);
      final line = (await RepertoireService().parseTrainingSnapshot(
        file.path,
        text,
      )).single;
      await file.rename(p.join(documents.path, 'moved.pgn'));
      await expectLater(
        progress.recordRating(
          line,
          ReviewRating.good,
          attempt: Object(),
          hadMistake: false,
        ),
        throwsA(isA<TrainingSourceChanged>()),
      );
      expect(progress.requiresReload, isTrue);
      await progress.prepareSourceLoad();
      expect(await reviews.loadAll(), isEmpty);
      expect(await reviews.loadHistory(), isEmpty);
    },
    skip: !Platform.isLinux,
  );

  test(
    'pending rating retry follows only its own acknowledged header lineage',
    () async {
      final failing = _FailingHistory(storage);
      final progress = ReviewProgressStore(
        reviewService: failing,
        headers: RepertoireFileEditor(documents: native),
        settings: () => TrainingSettings(),
        repertoireId: () => file.path,
      )..sources = {file.path: source};
      addTearDown(progress.dispose);
      final line = (await RepertoireService().parseTrainingSnapshot(
        file.path,
        text,
      )).single;
      await progress.recordRating(
        line,
        ReviewRating.good,
        attempt: Object(),
        hadMistake: false,
      );
      final retry = Object();
      failing.fail = true;
      await expectLater(
        progress.recordRating(
          line,
          ReviewRating.good,
          attempt: retry,
          hadMistake: false,
        ),
        throwsStateError,
      );
      final before = source.snapshot.revision;
      await progress.flushHeaders();
      expect(source.snapshot.revision, isNot(before));
      failing.fail = false;
      await progress.recordRating(
        line,
        ReviewRating.good,
        attempt: retry,
        hadMistake: false,
      );
      await progress.flushHeaders();
      expect((await failing.loadAll()).single.passCount, 2);
      expect(await failing.loadHistory(), hasLength(2));
    },
    skip: !Platform.isLinux,
  );

  test(
    'training waits for an own header receipt before validating its source',
    () async {
      final held = _HeldReceiptStore(storage);
      final mirror = RepertoireFileEditor(documents: held)
          .updateManyLineReviewHeaders(file.path, {
            'line': entry(),
          }, source: source);
      await held.published.future;
      final saved = attempt().then((_) => true, onError: (Object _) => false);
      // Hold the returned receipt after the real native publication releases its
      // domain. A training call admitted here must await source acknowledgement.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      held.release.complete();
      await mirror;
      expect(await saved, isTrue);
      expect(await reviews.loadAttempts(), hasLength(1));
    },
    skip: !Platform.isLinux,
  );

  test(
    'administrative line repoint preserves original CSV migration bytes',
    () async {
      final old = '${file.path},line,Line,2.5,0,,,0,0,0,0\n';
      final csv = File(p.join(documents.path, 'repertoire_reviews.csv'));
      await csv.writeAsString(
        'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count,excluded\n$old',
      );
      final original = await csv.readAsString();
      await reviews.repointLines(
        from: file.path,
        movedLinePaths: {'line': p.join(documents.path, 'other.pgn')},
      );
      expect(await File('${csv.path}.pre-csv-v2.bak').readAsString(), original);
    },
    skip: !Platform.isLinux,
  );

  test(
    'loader cannot attach first rows to replacement while parsing',
    () async {
      final parser = _ReplacingParser(() async {
        final replacement = File(p.join(documents.path, 'replacement.pgn'));
        await replacement.writeAsString(text);
        await replacement.rename(file.path);
      });
      final loader = TrainingSourceLoader(
        repertoireService: parser,
        reviewService: reviews,
        documents: native,
        askedQuestions: AskedQuestionsStore(),
        artifacts: generationArtifactsFixture().repository,
        storage: () => storage,
      );
      await expectLater(
        loader.load(
          RepertoireMetadata(
            filePath: file.path,
            name: 'chapter',
            lastModified: DateTime.utc(2026),
          ),
          isStudy: false,
          colorOverrideIsWhite: true,
          isStale: () => false,
        ),
        throwsStateError,
      );
      expect(await reviews.loadAll(), isEmpty);
      expect(await file.readAsString(), text);
    },
    skip: !Platform.isLinux,
  );

  test(
    'source alias cannot be silently rebound to another directory',
    () async {
      final alias = Link(p.join(profile.path, 'alias'));
      await alias.create(documents.path);
      final aliasPath = p.join(alias.path, 'chapter.pgn');
      final opened = await native.open(aliasPath) as PgnOpened;
      final context = TrainingSourceContext(
        path: aliasPath,
        snapshot: opened.snapshot,
      );
      await validateTrainingSource(context, aliasPath);
      final other = await Directory(p.join(profile.path, 'other')).create();
      await File(p.join(other.path, 'chapter.pgn')).writeAsString(text);
      await alias.delete();
      await alias.create(other.path);
      await expectLater(
        validateTrainingSource(context, aliasPath),
        throwsStateError,
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'acknowledged own header mirror permits next training outcome',
    () async {
      final before = source.snapshot;
      await reviews.saveAll([entry()], source: source);
      expect(
        await RepertoireFileEditor(
          documents: native,
        ).updateManyLineReviewHeaders(file.path, {
          'line': entry(),
        }, source: source),
        isTrue,
      );
      expect(source.snapshot.revision, isNot(before.revision));
      await reviews.saveAll([entry().copyWith(passCount: 2)], source: source);
      await attempt();
      await history();
      await moves();
      expect((await reviews.loadAll()).single.passCount, 2);
      expect(await reviews.loadAttempts(), hasLength(1));
      expect(await reviews.loadHistory(), hasLength(1));
      expect(await reviews.loadMoveProgress(), hasLength(1));
    },
    skip: !Platform.isLinux,
  );

  test('fresh unrelated save does not renew a training context', () async {
    final result = await native.save(source.snapshot, text);
    expect(result, isA<PgnSaved>());
    await expectLater(attempt(), throwsA(isA<StateError>()));
  }, skip: !Platform.isLinux);

  test(
    'legacy content policy is explicit and rejects changed content',
    () async {
      final legacy = TrainingSourceContext(
        path: file.path,
        snapshot: LegacyPgnDocumentStore.snapshot(file.path, text),
      );
      await validateLegacyTrainingSource(legacy, file.path);
      await expectLater(
        validateTrainingSource(legacy, file.path),
        throwsStateError,
      );
      await expectLater(
        validateLegacyTrainingSource(source, file.path),
        throwsStateError,
      );
      final replacement = File(p.join(documents.path, 'replacement.pgn'));
      await replacement.writeAsString(text);
      await replacement.rename(file.path);
      // Compatibility limitation: same-byte replacement is indistinguishable.
      await validateLegacyTrainingSource(legacy, file.path);
      await file.writeAsString('1. d4 *');
      await expectLater(
        validateLegacyTrainingSource(legacy, file.path),
        throwsStateError,
      );
    },
    skip: !Platform.isLinux,
  );
}

class _ReplacingParser extends RepertoireService {
  _ReplacingParser(this.replace);
  final Future<void> Function() replace;

  @override
  Future<List<RepertoireLine>> parseTrainingSnapshot(
    String filePath,
    String content, {
    String? trainingColor,
    bool colorFromStartingSide = false,
    bool inferColorWhenUnknown = false,
  }) async {
    final lines = await super.parseTrainingSnapshot(
      filePath,
      content,
      trainingColor: trainingColor,
      colorFromStartingSide: colorFromStartingSide,
      inferColorWhenUnknown: inferColorWhenUnknown,
    );
    await replace();
    return lines;
  }
}

class _HeaderRepertoire extends RepertoireService {
  _HeaderRepertoire(this.editor);
  final RepertoireFileEditor editor;
  @override
  RepertoireFileEditor get files => editor;
}

class _FailingHeaderEditor extends RepertoireFileEditor {
  _FailingHeaderEditor(NativePgnDocumentStore documents)
    : super(documents: documents);
  bool fail = false;
  @override
  Future<bool> updateManyLineReviewHeaders(
    String filePath,
    Map<String, RepertoireReviewEntry> entriesByLineId, {
    required TrainingSourceContext source,
  }) {
    if (fail) {
      return Future.error(StateError('Header device temporarily unavailable'));
    }
    return super.updateManyLineReviewHeaders(
      filePath,
      entriesByLineId,
      source: source,
    );
  }
}

class _HeldReceiptStore extends NativePgnDocumentStore {
  _HeldReceiptStore(IOStorageService storage)
    : super(guardOperation: storage.guardDocumentOperation);
  final published = Completer<void>();
  final release = Completer<void>();
  @override
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content) async {
    final result = await super.save(baseline, content);
    published.complete();
    await release.future;
    return result;
  }
}

class _FailingHistory extends RepertoireReviewService {
  _FailingHistory(IOStorageService storage) : super(storage: storage);
  bool fail = false;
  @override
  Future<void> appendHistory(
    List<RepertoireReviewHistoryEntry> entries, {
    required TrainingSourceContext source,
    required TrainingHistoryOperation operation,
  }) {
    if (fail) {
      return Future.error(StateError('History device temporarily unavailable'));
    }
    return super.appendHistory(entries, source: source, operation: operation);
  }
}

class _FailingWrites extends RepertoireReviewService {
  _FailingWrites(IOStorageService storage) : super(storage: storage);
  bool failReviewAfter = false;
  bool failHistoryBefore = false;
  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    required TrainingSourceContext source,
    String? repertoireId,
  }) async {
    await super.saveAll(entries, source: source, repertoireId: repertoireId);
    if (failReviewAfter) {
      throw StateError('Review publication acknowledgement lost');
    }
  }

  @override
  Future<void> appendHistory(
    List<RepertoireReviewHistoryEntry> entries, {
    required TrainingSourceContext source,
    required TrainingHistoryOperation operation,
  }) {
    if (failHistoryBefore) {
      return Future.error(StateError('History unavailable'));
    }
    return super.appendHistory(entries, source: source, operation: operation);
  }
}

class _LostHistoryAckStorage extends IOStorageService {
  _LostHistoryAckStorage(Directory documents, Directory support)
    : super(documentsRoot: documents, supportRoot: support);
  bool loseAcknowledgement = true;
  @override
  Future<String> updateFile(
    String path,
    FutureOr<String> Function(String?) update,
  ) async {
    final result = await super.updateFile(path, update);
    if (path == 'repertoire_review_history.csv' && loseAcknowledgement) {
      loseAcknowledgement = false;
      throw StateError('Published history acknowledgement lost');
    }
    return result;
  }
}
