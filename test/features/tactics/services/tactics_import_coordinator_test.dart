/// The tactics-import coordinator's own decisions: what it puts in the
/// app-wide job list, what the banner says when a run ends, what happens to a
/// second run started on top of a first, what a pause does, and what a
/// teardown mid-run must *not* do.
///
/// No engine is started. Every run here either finds nothing to analyze (its
/// games are already marked reviewed) or fails in the fetch — `flutter test`
/// answers every socket with an empty 400, which is exactly the "Lichess is
/// unreachable" path.
@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/features/games/services/games_window.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_database.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_import_coordinator.dart';
import 'package:chess_auto_prep/services/game_store/game_store.dart';
import 'package:chess_auto_prep/services/game_store/game_store_service.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/utils/app_messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/generation/engine_fakes.dart' show FakeMaiaEvaluator;

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

String lichessGame(String id) =>
    '''
[Event "Rated blitz game"]
[Site "https://lichess.org/$id"]
[UTCDate "2025.06.01"]
[UTCTime "12:00:00"]
[White "userA"]
[Black "userB"]
[Result "1-0"]
[TimeControl "180+2"]

1. e4 e5 2. Nf3 Nc6 1-0''';

const _reviewed = TacticsImportParams(
  username: 'userA',
  depth: 8,
  cores: 1,
  maxGames: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tactics_coordinator');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    GameStoreService.setTestInstance(GameStoreService());
    MaiaFactory.testOverride = FakeMaiaEvaluator(const {});
  });

  tearDown(() async {
    MaiaFactory.testOverride = null;
    GameStoreService.instance.close();
    await tempDir.delete(recursive: true);
  });

  /// A coordinator on its own database and its own copy of the games window,
  /// so nothing here touches app-wide singletons the other tests share.
  TacticsImportCoordinator makeCoordinator() => TacticsImportCoordinator(
    database: TacticsDatabase(),
    windowSettings: GamesWindowSettings.forTest(),
  );

  /// Mark [ids] reviewed, so a run over those games has nothing to analyze and
  /// never reaches the engine.
  Future<void> markReviewed(List<String> ids) =>
      StorageFactory.instance.saveAnalyzedGameIds(ids);

  Future<int> storedGameCount() async {
    final store = await GameStoreService.instance.open();
    return store.count(GameCollections.tactics);
  }

  RepertoireJob runningJob() =>
      JobManager.instance.currentTacticsImportJob ??
      (throw StateError('no tactics import job is registered'));

  // ────────────────────────────────────────────────────────────────────────
  group('starting a run', () {
    test('an empty username is refused before any job is registered', () async {
      final coordinator = makeCoordinator();

      await expectLater(
        coordinator.import(
          source: TacticsImportSource.lichess,
          params: const TacticsImportParams(username: ''),
        ),
        throwsA(isA<TacticsImportUsernameRequired>()),
      );

      expect(coordinator.isImporting, isFalse);
      expect(coordinator.activeImport, isNull);
      expect(JobManager.instance.currentTacticsImportJob, isNull);
      coordinator.dispose();
    });

    test(
      'a second run while one is in flight is refused, not queued',
      () async {
        await markReviewed(['lichess_aaaaaaaa']);
        final coordinator = makeCoordinator();

        final first = coordinator.import(
          source: TacticsImportSource.lichess,
          params: _reviewed,
          pgnContent: lichessGame('aaaaaaaa'),
        );
        expect(coordinator.isImporting, isTrue);
        final firstJob = runningJob();

        final second = await coordinator.import(
          source: TacticsImportSource.lichess,
          params: _reviewed,
          pgnContent: lichessGame('aaaaaaaa'),
        );

        expect(second, isFalse);
        expect(
          identical(runningJob(), firstJob),
          isTrue,
          reason: 'the refused run must not register a job of its own',
        );

        expect(await first, isTrue);
        coordinator.dispose();
      },
    );

    test('the job is labelled with the account and offers a pause', () async {
      await markReviewed(['lichess_aaaaaaaa']);
      final coordinator = makeCoordinator();

      final run = coordinator.import(
        source: TacticsImportSource.lichess,
        params: _reviewed,
        pgnContent: lichessGame('aaaaaaaa'),
      );

      final job = runningJob();
      expect(job.label, 'Review games — userA');
      expect(job.type, JobType.tacticsImport);
      expect(job.status, JobStatus.running);
      expect(
        job.resumable,
        isTrue,
        reason: 'stopping a review parks it; the work is already persisted',
      );
      expect(job.onCancel, isNotNull);

      await run;
      expect(job.status, JobStatus.completed);
      coordinator.dispose();
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('how a finished run reports itself', () {
    test('nothing but already-reviewed games says so', () async {
      await markReviewed(['lichess_aaaaaaaa']);
      final coordinator = makeCoordinator();

      final ok = await coordinator.import(
        source: TacticsImportSource.lichess,
        params: _reviewed,
        pgnContent: lichessGame('aaaaaaaa'),
      );

      expect(ok, isTrue);
      expect(coordinator.importStatus, AppMessages.gamesAlreadyAnalyzed);
      expect(coordinator.newPositionsFound, 0);
      expect(coordinator.gamesReviewed, 0);
      expect(coordinator.isImporting, isFalse);
      expect(coordinator.isCancelling, isFalse);
      expect(coordinator.activeImport, isNull);
      coordinator.dispose();
    });

    test(
      'an empty resume queue says no new blunders, not "caught up"',
      () async {
        // Nothing stored at all is a different sentence from "the games I have
        // were all reviewed already".
        final coordinator = makeCoordinator();

        final run = coordinator.resumeAnalysis(
          lichessUsername: 'userA',
          chesscomUsername: null,
          depth: 8,
          cores: 1,
        );
        final job = runningJob();
        expect(job.label, 'Analyze stored games');

        await run;

        expect(coordinator.importStatus, AppMessages.noNewBlunders);
        expect(job.status, JobStatus.completed);
        expect(coordinator.isImporting, isFalse);
        expect(coordinator.progressFraction, 0);
        coordinator.dispose();
      },
    );

    test('a failed fetch marks the job failed and rethrows', () async {
      // No pgnContent, so the run goes to Lichess — which the test binding
      // answers with an empty 400.
      final coordinator = makeCoordinator();

      final run = coordinator.import(
        source: TacticsImportSource.lichess,
        params: _reviewed,
      );
      final job = runningJob();

      await expectLater(
        run,
        throwsA(
          isA<Exception>().having((e) => '$e', 'message', contains('Lichess')),
        ),
      );

      expect(job.status, JobStatus.failed);
      expect(job.error, isNotNull);
      expect(coordinator.isImporting, isFalse);
      expect(coordinator.activeImport, isNull);
      expect(
        coordinator.importStatus,
        isNot(AppMessages.gamesAlreadyAnalyzed),
        reason: 'a failure must not leave a success line on the banner',
      );
      expect(coordinator.importStatus, isNot(AppMessages.noNewBlunders));
      coordinator.dispose();
    });

    test('dismissImportStatus clears the banner', () async {
      await markReviewed(['lichess_aaaaaaaa']);
      final coordinator = makeCoordinator();
      await coordinator.import(
        source: TacticsImportSource.lichess,
        params: _reviewed,
        pgnContent: lichessGame('aaaaaaaa'),
      );
      expect(coordinator.importStatus, isNotNull);

      coordinator.dismissImportStatus();
      expect(coordinator.importStatus, isNull);
      coordinator.dispose();
    });

    test('resumeAnalysis is refused while an import is running', () async {
      await markReviewed(['lichess_aaaaaaaa']);
      final coordinator = makeCoordinator();

      final run = coordinator.import(
        source: TacticsImportSource.lichess,
        params: _reviewed,
        pgnContent: lichessGame('aaaaaaaa'),
      );
      final job = runningJob();

      await coordinator.resumeAnalysis(
        lichessUsername: 'userA',
        chesscomUsername: null,
        depth: 8,
        cores: 1,
      );

      expect(
        identical(runningJob(), job),
        isTrue,
        reason: 'the refused resume must not register a second job',
      );
      expect(await run, isTrue);
      coordinator.dispose();
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('pausing', () {
    test('a pause with nothing running does nothing at all', () {
      final coordinator = makeCoordinator();

      coordinator.cancelImport();

      expect(coordinator.isCancelling, isFalse);
      expect(coordinator.importStatus, isNull);
      coordinator.dispose();
    });

    test('a pause click puts the run into the winding-down state', () async {
      await markReviewed(['lichess_aaaaaaaa']);
      final coordinator = makeCoordinator();

      final run = coordinator.import(
        source: TacticsImportSource.lichess,
        params: _reviewed,
        pgnContent: lichessGame('aaaaaaaa'),
      );

      coordinator.cancelImport();
      expect(coordinator.isCancelling, isTrue);
      expect(coordinator.importStatus, 'Pausing…');
      expect(runningJob().progress.message, 'Pausing…');

      await run;
      expect(
        coordinator.isCancelling,
        isFalse,
        reason: 'the flag is cleared when the run has wound down',
      );
      coordinator.dispose();
    });

    test('a pause clicked before the fetch starts is honoured', () async {
      // Regression. `import()` publishes the job and sets `isImporting`
      // synchronously — the Pause button is live from that moment — but then
      // awaited `TacticsImportService.initialize()` (a disk load and an
      // off-isolate decode) before reaching the entry point that reset
      // `_cancelled`. A pause raised in that window was wiped, and the run
      // went on to report success, so auto-fetch advanced its last-fetch
      // timestamp past games the user had asked it to stop on.
      //
      // The second half was worse: `isCancelling` stayed true for the rest
      // of the run, so `cancelImport()` returned early on every later click
      // and the run became uncancellable, with the banner frozen on
      // "Pausing…" while work continued.
      //
      // `TacticsImportService.beginRun()` now opens the run before the
      // coordinator's first `await`, so there is no window to lose it in.
      await markReviewed(['lichess_aaaaaaaa']);
      final coordinator = makeCoordinator();

      final run = coordinator.import(
        source: TacticsImportSource.lichess,
        params: _reviewed,
        pgnContent: lichessGame('aaaaaaaa'),
      );

      coordinator.cancelImport();
      expect(coordinator.activeImport, isNotNull);
      expect(coordinator.activeImport!.wasCancelled, isTrue);

      final ok = await run;

      expect(ok, isFalse, reason: 'a paused run must not report success');
      expect(
        coordinator.importStatus,
        isNull,
        reason: 'no success banner for a run the user stopped',
      );
      expect(
        coordinator.isCancelling,
        isFalse,
        reason: 'a stuck isCancelling made every later pause a no-op',
      );
      expect(coordinator.isImporting, isFalse);
      coordinator.dispose();
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('pruning the stored-game archive', () {
    test(
      'a prune requested mid-run is deferred, and the run prunes on exit',
      () async {
        // The running import is appending to the same archive; pruning under it
        // would delete rows it is still walking.
        await StorageFactory.instance.saveImportedPgns(lichessGame('aaaaaaaa'));
        await markReviewed(['lichess_aaaaaaaa']);
        final coordinator = makeCoordinator();
        expect(await storedGameCount(), 1);

        final run = coordinator.import(
          source: TacticsImportSource.lichess,
          params: _reviewed,
          pgnContent: lichessGame('aaaaaaaa'),
        );
        expect(coordinator.isImporting, isTrue);

        await coordinator.pruneStoredGames();
        expect(
          await storedGameCount(),
          1,
          reason: 'pruning must be a no-op while an import is running',
        );

        await run;
        expect(
          await storedGameCount(),
          0,
          reason: 'the reviewed game leaves the queue when the run winds down',
        );
        coordinator.dispose();
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────────
  group('teardown while a run is in flight', () {
    test('disposing mid-run does not notify or throw', () async {
      // The run's `finally` calls notifyListeners() and awaits a prune long
      // after the provider that owned this coordinator is gone. Without
      // SafeChangeNotifier that trips the used-after-dispose assertion.
      await markReviewed(['lichess_aaaaaaaa']);
      final coordinator = makeCoordinator();

      var notifications = 0;
      coordinator.addListener(() => notifications++);

      final run = coordinator.import(
        source: TacticsImportSource.lichess,
        params: _reviewed,
        pgnContent: lichessGame('aaaaaaaa'),
      );
      final duringRun = notifications;
      expect(duringRun, greaterThan(0), reason: 'the start did notify');

      coordinator.dispose();
      expect(coordinator.isDisposed, isTrue);

      expect(await run, isTrue, reason: 'the run still finishes cleanly');
      expect(
        notifications,
        duringRun,
        reason: 'nothing is notified after dispose',
      );
    });

    test(
      'disposing mid-run still lets the run release its bookkeeping',
      () async {
        await markReviewed(['lichess_aaaaaaaa']);
        final coordinator = makeCoordinator();

        final run = coordinator.import(
          source: TacticsImportSource.lichess,
          params: _reviewed,
          pgnContent: lichessGame('aaaaaaaa'),
        );
        final job = runningJob();
        coordinator.dispose();
        await run;

        expect(job.status, JobStatus.completed);
        expect(coordinator.isImporting, isFalse);
        expect(coordinator.activeImport, isNull);
        expect(JobManager.instance.currentTacticsImportJob, isNull);
      },
    );

    test('a pause after dispose is still safe', () async {
      final coordinator = makeCoordinator();
      coordinator.dispose();

      expect(coordinator.cancelImport, returnsNormally);
      expect(coordinator.dismissImportStatus, returnsNormally);
    });
  });
}
