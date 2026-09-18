import 'package:fake_async/fake_async.dart';
import 'package:chess_auto_prep/features/studies/models/import_source.dart';
import 'package:chess_auto_prep/features/studies/repositories/study_import_repository.dart';
import '../../support/scripted_document_store.dart';
import '../../support/study_fixture.dart';
import 'dart:async';
import 'package:chess_auto_prep/l10n/generated/app_localizations_en.dart';
import 'package:chess_auto_prep/features/studies/models/study_import_state.dart';
import 'dart:io';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_import_controller.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/studies/legacy_study_library_repository.dart';
import 'package:chess_auto_prep/app/study_import_jobs.dart';
import 'package:chess_auto_prep/infrastructure/studies/storage_study_import_repository.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _UnavailableLibrary extends MemoryStudyLibrary {
  @override
  Future<String> pathForName(String name) async =>
      throw const FileSystemException('directory unavailable');
}

class _ThrowingJobs implements StudyImportJobs {
  _ThrowingJobs(this.throwAtStart);
  final bool throwAtStart;
  @override
  StudyImportJob start(String name) {
    if (throwAtStart) throw StateError('job history unavailable');
    return _ThrowingJob();
  }
}

class _ThrowingJob implements StudyImportJob {
  @override
  void progress(int done, int total, StudyImportProgress progress) =>
      throw StateError('progress unavailable');
  @override
  void finish({
    required int chapters,
    required int total,
    required bool cancelled,
    StudyImportFailure? failure,
  }) => throw StateError('finish unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StorageStudyImportRepository repository;
  late MockClient client;
  final requests = <String>[];
  const game = '[Event "Cached"]\n\n1. e4 e5 *';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('study-import-owner-');
    requests.clear();
    client = MockClient((request) async {
      requests.add(request.url.path);
      return http.Response(game, 200);
    });
    final documents = NativePgnDocumentStore();
    repository = StorageStudyImportRepository(
      documents: documents,
      library: LegacyStudyLibraryRepository(
        IOStorageService(documentsRoot: root, supportRoot: root),
        documents,
      ),
      cacheDirectory: () async => Directory('${root.path}/cache'),
      authHeaders: () async => {},
      createClient: () => client,
    );
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'concurrent publications exclusively create separate complete studies',
    () async {
      final results = await Future.wait([
        repository.publish('Shared', game),
        repository.publish('Shared', '[Event "Other"]\n\n1. d4 d5 *'),
      ]);
      expect(results.map((r) => r.outcome), everyElement(isA<PgnSaved>()));
      final snapshots = results
          .map((r) => r.outcome)
          .cast<PgnSaved>()
          .map((saved) => saved.after)
          .toList();
      expect(snapshots.map((s) => s.path).toSet(), hasLength(2));
      for (final snapshot in snapshots) {
        expect(await File(snapshot.path).readAsString(), snapshot.content);
        expect(snapshot.revision.nativeIdentity, isNot('legacy-content'));
      }
    },
  );

  test(
    'repeated name collisions stop with exact submitted bytes and no overwrites',
    () async {
      final store = Store()
        ..onCreate = (_, _) async => const PgnNameCollision();
      final colliding = StorageStudyImportRepository(
        documents: store,
        library: MemoryStudyLibrary(),
        cacheDirectory: () async => root,
        authHeaders: () async => {},
      );
      final result = await colliding.publish('Occupied', game);
      expect(result.failure, StudyImportFailure.nameCollisions);
      expect(result.outcome, isA<PgnNameCollision>());
      expect(result.content, game);
      expect(result.path, '/studies/Occupied (100).pgn');
      expect(store.creates, hasLength(100));
      expect(store.saves, isEmpty);
    },
  );

  test(
    'destination resolution failure retains exact content for an explicit copy',
    () async {
      final store = Store();
      final unavailable = StorageStudyImportRepository(
        documents: store,
        library: _UnavailableLibrary(),
        cacheDirectory: () async => root,
        authHeaders: () async => {},
      );
      await unavailable.cacheGame('42', game);
      final importer = StudyImportController(
        repository: unavailable,
        documents: store,
        jobs: RepertoireStudyImportJobs(
          JobManager.instance,
          AppLocalizationsEn.new,
        ),
      );
      final result = await importer.startCollectionDownload(
        gameIds: ['42'],
        studyName: 'Retained',
      );
      expect(result.publication!.path, isEmpty);
      expect(result.publication!.outcome, isA<PgnWriteFailed>());
      expect(store.creates, isEmpty);
      final session = importer.publicationRecovery!;
      expect(session.state.content, contains('1. e4 e5 *'));
      expect(session.state.canSave, isFalse);
      expect(await session.saveCopy('/chosen.pgn'), isA<PgnSaved>());
      expect(importer.needsPublicationReview, isFalse);
      await importer.shutdown();
      importer.dispose();
    },
  );

  for (final throwAtStart in [true, false]) {
    test(
      'job projection failure cannot replace publication receipt (startup=$throwAtStart)',
      () async {
        await repository.cacheGame('42', game);
        final importer = StudyImportController(
          repository: repository,
          documents: repository.documents,
          jobs: _ThrowingJobs(throwAtStart),
        );
        final result = await importer.startCollectionDownload(
          gameIds: ['42'],
          studyName: 'Authoritative',
        );
        expect(result.failure, isNull);
        expect(result.chapters, 1);
        expect(result.publication!.outcome, isA<PgnSaved>());
        expect(importer.lastResult, same(result));
        expect(
          await File(result.studyPath!).readAsString(),
          contains('1. e4 e5 *'),
        );
        expect(
          (await Directory(File(result.studyPath!).parent.path).list().toList())
              .whereType<File>()
              .where((f) => f.path.endsWith('.pgn')),
          hasLength(1),
        );
        await importer.shutdown();
        importer.dispose();
      },
    );
  }

  test(
    'completed headerless PGN uses retained publication and exact input bytes',
    () async {
      final importer = StudyImportController(
        repository: repository,
        documents: repository.documents,
        jobs: RepertoireStudyImportJobs(
          JobManager.instance,
          AppLocalizationsEn.new,
        ),
      );
      const content = '  1. e4 e5 *\n';
      final result = await importer.publishStudy(
        name: 'Headerless',
        pgn: content,
      );
      expect(result.chapters, 1);
      expect(await File(result.studyPath!).readAsString(), content);
      expect(
        (await importer.publishStudy(name: 'Empty', pgn: '  ')).wroteAnything,
        isFalse,
      );
      await importer.shutdown();
      importer.dispose();
    },
  );

  test(
    'close cancels the injected Lichess transport backoff and all further attempts',
    () {
      fakeAsync((time) {
        var calls = 0;
        client = MockClient((request) async {
          calls++;
          expect(request.url.host, 'lichess.org');
          return http.Response('', 429);
        });
        final source = repository.openSource();
        Object? failure;
        var completed = false;
        unawaited(
          source
              .fetchLichess(const LichessStudySource(studyId: 'abcdefgh'))
              .then<void>(
                (_) => completed = true,
                onError: (Object error) {
                  failure = error;
                  completed = true;
                },
              ),
        );
        time.flushMicrotasks();
        expect(calls, 1);
        expect(completed, isFalse);
        expect(time.nonPeriodicTimerCount, greaterThan(0));
        source.close();
        time.flushMicrotasks();
        expect(completed, isTrue);
        expect(failure, isStateError);
        expect(time.nonPeriodicTimerCount, 0);
        time.elapse(const Duration(minutes: 10));
        expect(calls, 1);
      });
    },
  );

  test('cache validates IDs and preserves acknowledged content', () async {
    await repository.cacheGame('42', game);
    expect(await repository.readCachedGame('42'), game);
    await expectLater(
      repository.cacheGame('../escape', game),
      throwsArgumentError,
    );
    expect(await File('${root.path}/escape.pgn').exists(), isFalse);
  });

  test('disposing a pending source rejects late HTTP results', () async {
    final response = Completer<http.Response>();
    final requested = Completer<void>();
    client = MockClient((request) {
      requested.complete();
      return response.future;
    });
    final source = repository.openSource();
    final fetch = source.fetchGame('42');
    await requested.future;
    final rejected = expectLater(fetch, throwsStateError);
    source.close();
    await rejected;
    response.complete(http.Response(game, 200));
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'shutdown cancels HTTP and publishes only previously cached chapters',
    () async {
      await repository.cacheGame('1', game);
      final response = Completer<http.Response>();
      final requested = Completer<void>();
      client = MockClient((request) {
        requested.complete();
        return response.future;
      });
      final controller = StudyImportController(
        repository: repository,
        documents: repository.documents,
        jobs: RepertoireStudyImportJobs(
          JobManager.instance,
          AppLocalizationsEn.new,
        ),
      );
      final run = controller.startCollectionDownload(
        gameIds: ['1', '2'],
        studyName: 'Partial',
      );
      await requested.future;
      await controller.shutdown();
      final result = await run;
      expect(result.cancelled, isTrue);
      expect(result.chapters, 1);
      expect(result.publication?.outcome, isA<PgnSaved>());
      expect(await File(result.studyPath!).readAsString(), contains('e4 e5'));
      expect(await repository.readCachedGame('2'), isNull);
      controller.dispose();
      response.complete(http.Response('[Event "Late"]\n\n1. d4 *', 200));
      await Future<void>.delayed(Duration.zero);
      expect(
        await File(result.studyPath!).readAsString(),
        isNot(contains('Late')),
      );
      await expectLater(
        controller.startCollectionDownload(gameIds: ['1'], studyName: 'Closed'),
        throwsA(isA<StudyImportRejected>()),
      );
    },
  );
}
