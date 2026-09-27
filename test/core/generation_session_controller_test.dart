import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../support/runtime_settings.dart';
import '../support/generation_artifacts_fixture.dart';
import '../support/generation_publication_fixture.dart';
// GenerationSessionController drives engines and isolates for real runs, so
// these tests cover only what is unit-testable without an engine: initial
// state, the generated-tree bundle lifecycle, resume-refusal plumbing in
// startBuild, progress updates with notify throttling, the idle guards on
// the control surface, and dispose safety.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/core/generation_session_types.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/jobs/generation_phase.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/services/master_games/master_games_service.dart';
import 'package:chess_auto_prep/services/master_games/twic_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fenAfterE4 =
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

class _FailingExitLifecycle implements EngineLifecycle {
  _FailingExitLifecycle({this.failPause = false});
  final bool failPause;
  void Function()? onEnter;
  int entries = 0;
  int exits = 0;
  @override
  Future<void> enterGeneration(int threads) async {
    entries++;
    onEnter?.call();
  }

  @override
  Future<void> exitGeneration() async {
    exits++;
    if (!failPause) throw StateError('engine release failed');
  }

  @override
  Future<void> pauseGeneration() async {
    if (failPause) throw StateError('engine pause failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BuildTree _smallTree({
  String rootFen = kStandardStartFen,
  Map<String, dynamic> configSnapshot = const {},
}) {
  final root = BuildTreeNode(
    fen: rootFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: 0,
  )..engineEvalCp = 20;

  final e4 = BuildTreeNode(
    fen: _fenAfterE4,
    moveSan: 'e4',
    moveUci: 'e2e4',
    ply: 1,
    isWhiteToMove: false,
    nodeId: 1,
    parent: root,
  )..engineEvalCp = 25;
  root.children.add(e4);

  return BuildTree(root: root, configSnapshot: configSnapshot)
    ..computeMetadata();
}

RuntimeSettings? _engineFixtureSettings;
EngineRuntime get engines =>
    testEngines(_engineFixtureSettings ??= testRuntimeSettings());
void main() {
  setUp(() {
    _engineFixtureSettings = null;
    addTearDown(() => _engineFixtureSettings?.dispose());
  });
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initial state is idle with no tree and clean progress', () {
    final controller = GenerationSessionController(
      databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
      jobs: JobManager(),
      enginePool: engines.pool,
      engineLifecycle: engines.lifecycle,
      artifacts: generationArtifactsFixture(),
      publication: generationPublicationFixture(),
    );

    expect(controller.isGenerating, isFalse);
    expect(controller.isPaused, isFalse);
    expect(controller.isCancelling, isFalse);
    expect(controller.canPause, isFalse);
    expect(controller.isSnapshotExporting, isFalse);
    expect(controller.snapshotStatus, isNull);
    expect(controller.current, isNull);
    expect(controller.generatedTree, isNull);
    expect(controller.generatedTreeConfig, isNull);
    expect(controller.generatedTreeFenMap, isNull);
    expect(controller.currentJob, isNull);
    expect(controller.lastConfig, isNull);
    expect(controller.lastError, isNull);
    expect(controller.lastRunSummary, isEmpty);
    expect(controller.progress.phase, GenerationPhase.idle);
    expect(controller.progress.status, isEmpty);
    expect(controller.progress.nodes, 0);
    expect(controller.progress.lines, 0);

    controller.dispose();
  });

  group('generated tree lifecycle', () {
    test('onTreeBuilt publishes the bundle and notifies', () {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );
      var notified = 0;
      controller.addListener(() => notified++);

      final tree = _smallTree();
      controller.onTreeBuilt(tree);

      expect(controller.current, isNotNull);
      expect(controller.generatedTree, same(tree));
      expect(controller.generatedTreeFenMap, isNotNull);
      expect(controller.current!.tree.root.fen, kStandardStartFen);
      expect(notified, 1);

      controller.dispose();
    });

    test('onTreeBuilt reads play_as_white from the config snapshot', () {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );

      controller.onTreeBuilt(
        _smallTree(configSnapshot: {'play_as_white': false}),
      );

      expect(controller.current!.playAsWhite, isFalse);
      controller.dispose();
    });

    test('clearTree drops the bundle and notifies', () {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );
      controller.onTreeBuilt(_smallTree());
      var notified = 0;
      controller.addListener(() => notified++);

      controller.clearTree();

      expect(controller.current, isNull);
      expect(controller.generatedTree, isNull);
      expect(notified, 1);
      controller.dispose();
    });
  });

  group('startBuild resume refusal', () {
    test(
      'a legacy partial tree from another position refuses cleanly',
      () async {
        final controller = GenerationSessionController(
          databases:
              (_engineFixtureSettings ??= testRuntimeSettings()).databases,
          jobs: JobManager(),
          enginePool: engines.pool,
          engineLifecycle: engines.lifecycle,
          artifacts: generationArtifactsFixture(),
          publication: generationPublicationFixture(),
        );
        var notified = 0;
        controller.addListener(() => notified++);

        // The paused tree was built from the e4 position (with no recorded
        // move prefix), but the caller is resuming from the standard start.
        final request = GenerationRequest(
          jobLabel: 'Test generation',
          config: const TreeBuildConfig(
            startFen: kStandardStartFen,
            playAsWhite: true,
          ),
          repertoireFilePath: '/nonexistent/rep.pgn',
          buildRootFen: kStandardStartFen,
          lineMovePrefix: const [],
          repertoireStartFen: kStandardStartFen,
          onPublished: (_) {},
          existingTree: _smallTree(rootFen: _fenAfterE4),
        );

        await controller.startBuild(request);

        expect(controller.lastError, contains('Cannot resume'));
        expect(controller.lastRunSummary, contains('Cannot resume'));
        expect(controller.isGenerating, isFalse, reason: 'run never started');
        expect(controller.progress.phase, GenerationPhase.idle);
        expect(notified, 1);
        controller.dispose();
      },
    );
  });

  for (final disposed in [false, true]) {
    test(
      'registered run ${disposed ? 'disposes' : 'cancels'} without a screen owner',
      () async {
        final jobs = JobManager();
        final entered = Completer<void>();
        final release = Completer<void>();
        final artifacts = MemoryGenerationArtifacts()
          ..beforeRead = (_) async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          };
        final controller = GenerationSessionController(
          databases:
              (_engineFixtureSettings ??= testRuntimeSettings()).databases,
          jobs: jobs,
          enginePool: engines.pool,
          engineLifecycle: engines.lifecycle,
          artifacts: GenerationArtifacts(artifacts),
          publication: generationPublicationFixture(),
        );
        final tree = _smallTree(rootFen: _fenAfterE4)..startMoves = 'e4';
        final request = GenerationRequest(
          jobLabel: 'Captured chapter',
          config: const TreeBuildConfig(
            startFen: _fenAfterE4,
            playAsWhite: true,
            downloadMasterGamesIfMissing: false,
          ),
          repertoireFilePath: '/captured.pgn',
          buildRootFen: kStandardStartFen,
          lineMovePrefix: const [],
          repertoireStartFen: kStandardStartFen,
          existingTree: tree,
          onPublished: (_) => fail('cancelled run published'),
        );
        var notifications = 0;
        // The cancel case has no controller observer at all. The disposal case
        // also proves the very first observer sees a fully configured job.
        if (disposed) {
          controller.addListener(() {
            notifications++;
            final job = controller.currentJob!;
            expect(job.status, JobStatus.running);
            expect(job.label, 'Captured chapter');
            expect(job.subtreeFen, _fenAfterE4);
            expect(job.configSnapshot, request.config.toJson());
          });
        }
        final run = controller.startBuild(request);
        final job = jobs.jobs.single;
        expect(controller.currentJob, same(job));
        expect(job.status, JobStatus.running);
        await controller.startBuild(request);
        expect(
          jobs.jobs,
          hasLength(1),
          reason: 'busy admission must not create another job',
        );
        await entered.future;
        final beforeDisposal = notifications;
        if (disposed) {
          controller.dispose();
        } else {
          controller.cancelBuild();
        }
        release.complete();
        await run;
        expect(job.status, JobStatus.cancelled);
        expect(job.progress.message, isNotEmpty);
        final terminalMessage = job.progress.message;
        expect(controller.currentJob, isNull);
        expect(controller.progress.nodes, 0);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(job.progress.message, terminalMessage);
        if (disposed) {
          expect(notifications, beforeDisposal);
        } else {
          controller.dispose();
        }
      },
    );
  }

  group('progress plumbing', () {
    test('progress.update stores every field it is given', () {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );

      controller.progress.update(
        nodes: 42,
        depth: 5,
        maxPlyConfig: 18,
        unexploredAtDepth: 7,
        totalAtDepth: 12,
        lines: 3,
        nodesPerMinute: 60.5,
        elapsedMs: 1234,
      );

      expect(controller.progress.nodes, 42);
      expect(controller.progress.depth, 5);
      expect(controller.progress.maxPlyConfig, 18);
      expect(controller.progress.unexploredAtDepth, 7);
      expect(controller.progress.totalAtDepth, 12);
      expect(controller.progress.lines, 3);
      expect(controller.progress.nodesPerMinute, 60.5);
      expect(controller.progress.elapsedMs, 1234);
      controller.dispose();
    });

    test('rapid updates coalesce into a throttled trailing notify', () async {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );
      var notified = 0;
      controller.addListener(() => notified++);

      controller.progress.update(nodes: 1);
      expect(notified, 1, reason: 'first update notifies immediately');

      controller.progress.update(nodes: 2);
      expect(controller.progress.nodes, 2, reason: 'state updates instantly');
      expect(notified, 1, reason: 'second notify is deferred');

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(notified, 2, reason: 'trailing timer flushed the notify');
      controller.dispose();
    });
  });

  group('idle guards', () {
    test('pause/resume/cancel/finishNow are no-ops when idle', () {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );
      var notified = 0;
      controller.addListener(() => notified++);

      controller.pauseBuild();
      controller.resumeBuild();
      controller.cancelBuild();

      expect(controller.isPaused, isFalse);
      expect(controller.isCancelling, isFalse);
      expect(controller.isGenerating, isFalse);
      expect(notified, 0, reason: 'guarded methods return before notifying');

      controller.finishNow();
      expect(controller.isGenerating, isFalse);
      controller.dispose();
    });

    test('exportSnapshot refuses without an active build', () async {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );

      final (ok, message) = await controller.exportSnapshot(
        repertoireName: 'Snap',
        verify: false,
      );

      expect(ok, isFalse);
      expect(message, 'No active build to export from.');
      controller.dispose();
    });

    test('snapshotNameSuggestion falls back when no run is active', () {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );
      expect(controller.snapshotNameSuggestion(), 'Generated d0 snapshot');
      controller.dispose();
    });
  });

  group('dispose safety', () {
    for (final failPause in [false, true]) {
      test(
        'engine ${failPause ? 'pause' : 'cleanup'} failure settles the job and releases run ownership',
        () async {
          final lifecycle = _FailingExitLifecycle(failPause: failPause);
          final jobs = JobManager();
          final controller = GenerationSessionController(
            databases:
                (_engineFixtureSettings ??= testRuntimeSettings()).databases,
            jobs: jobs,
            enginePool: engines.pool,
            artifacts: generationArtifactsFixture(),
            publication: generationPublicationFixture(),
            engineLifecycle: lifecycle,
          );
          lifecycle.onEnter = failPause
              ? controller.pauseBuild
              : controller.cancelBuild;
          final request = GenerationRequest(
            jobLabel: 'Test generation',
            config: const TreeBuildConfig(
              startFen: kStandardStartFen,
              playAsWhite: true,
              maxPly: 1,
              downloadMasterGamesIfMissing: false,
            ),
            repertoireFilePath: '/test.pgn',
            buildRootFen: kStandardStartFen,
            lineMovePrefix: const [],
            repertoireStartFen: kStandardStartFen,
            existingTree: _smallTree(),
            onPublished: (_) => fail('Cancelled run published lines'),
          );
          await controller.startBuild(request);
          expect(controller.isGenerating, isFalse);
          expect(controller.currentJob, isNull);
          expect(controller.activeConfig, isNull);
          expect(
            controller.lastError,
            contains(
              failPause ? 'engine pause failed' : 'engine release failed',
            ),
          );
          final job = jobs.jobs.single;
          expect(job.status, JobStatus.failed);
          await controller.startBuild(request);
          expect(lifecycle.entries, 2);
          expect(lifecycle.exits, 2);
          controller.dispose();
          job.dispose();
        },
      );
    }

    test('dispose cancels the pending throttle timer', () async {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );
      var notified = 0;
      controller.addListener(() => notified++);

      controller.progress.update(nodes: 1); // immediate notify
      controller.progress.update(nodes: 2); // schedules the trailing timer
      expect(notified, 1);

      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(notified, 1, reason: 'no notify after dispose');
    });

    test('late progress updates after dispose are swallowed', () async {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );
      controller.dispose();

      // A straggling build callback landing after teardown must not throw:
      // SafeChangeNotifier drops the notification.
      controller.progress.update(nodes: 99);
      expect(controller.progress.nodes, 99);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
  });

  group('master-games download phase', () {
    late Directory tmp;
    // Held open so the download never finishes on its own: every test here
    // is about what happens *while* the run is parked on it.
    late Completer<void> hold;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('genmg');
      hold = Completer<void>();
    });
    tearDown(() async {
      if (!hold.isCompleted) hold.complete();
      await tmp.delete(recursive: true);
    });

    Uint8List zipOf(int issue) {
      final pgn =
          '[Event "Issue $issue"]\n[White "A,A"]\n[Black "B,B"]\n'
          '[Result "1-0"]\n\n1. e4 e5 1-0\n';
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('twic$issue.pgn', utf8.encode(pgn)));
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    /// Answers HEADs immediately (so the issue probe, which starts near
    /// today's estimated issue, finishes) but parks every zip body on
    /// [hold].
    http.Client stalling() => MockClient((request) async {
      final m = RegExp(r'twic(\d+)g\.zip$').firstMatch(request.url.path);
      final issue = m == null ? null : int.parse(m.group(1)!);
      if (issue == null ||
          issue < 1650 ||
          issue > twicIssueEstimateFor(DateTime.now())) {
        return http.Response('', 404);
      }
      if (request.method == 'HEAD') return http.Response('', 200);
      await hold.future;
      return http.Response.bytes(zipOf(issue), 200);
    });

    Future<MasterGamesService> emptyService() async {
      final svc = MasterGamesService(
        clientFactory: () => TwicClient(httpClient: stalling()),
        dbPathProvider: () async => '${tmp.path}/master_games.db',
      );
      addTearDown(svc.dispose);
      await svc.load();
      await svc.setStartIssue(1650);
      return svc;
    }

    GenerationRequest requestWith({required bool download}) =>
        GenerationRequest(
          jobLabel: 'Test generation',
          config: TreeBuildConfig(
            startFen: kStandardStartFen,
            playAsWhite: true,
            downloadMasterGamesIfMissing: download,
            buildMode: BuildMode.maiaDbExplore,
          ),
          repertoireFilePath: '${tmp.path}/rep.pgn',
          buildRootFen: kStandardStartFen,
          lineMovePrefix: const [],
          repertoireStartFen: kStandardStartFen,
          onPublished: (_) {},
        );

    /// Lets the pipeline run until [ready], without a real clock.
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 200 && !ready(); i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('an empty database parks the run before the engine is claimed, '
        'and cancelling there is felt at once', () async {
      final svc = await emptyService();
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      )..masterGames = () => svc;

      final run = controller.startBuild(requestWith(download: true));
      await until(() => controller.isAwaitingMasterGames);

      expect(controller.isGenerating, isTrue);
      expect(controller.progress.phase, GenerationPhase.downloadingMasterGames);
      expect(controller.canPause, isFalse, reason: 'nothing to pause yet');
      expect(svc.isSyncing, isTrue);
      // The service's own line is mirrored into the build status.
      await until(() => controller.progress.status.contains('TWIC'));
      expect(controller.progress.status, contains('TWIC'));

      controller.cancelBuild();
      await run;

      expect(controller.isGenerating, isFalse);
      expect(controller.lastRunSummary, contains('Cancelled'));
      expect(controller.generatedTree, isNull, reason: 'never got to build');
      controller.dispose();
    });

    test('"start now without them" stops the wait and the download it '
        'started', () async {
      final svc = await emptyService();
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      )..masterGames = () => svc;

      final run = controller.startBuild(requestWith(download: true));
      await until(() => controller.isAwaitingMasterGames);

      // Both calls land before the parked await resumes, so the run ends
      // here instead of going on to claim an engine this test has no use
      // for; the point is that the skip released the wait.
      controller.skipMasterGamesDownload();
      controller.cancelBuild();
      expect(controller.isAwaitingMasterGames, isFalse);

      await run;
      expect(controller.isGenerating, isFalse);
      // Ours to cancel, since this run started it.
      // Cancellation finishes the issue already in flight. Release the fake
      // response and await the actual completion contract, not a scheduler race.
      hold.complete();
      await svc.syncCompletion.timeout(const Duration(seconds: 5));
      expect(svc.isSyncing, isFalse);
      controller.dispose();
    });

    test('dispose releases a parked run and forbids another run', () async {
      final svc = await emptyService();
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      )..masterGames = () => svc;
      final request = requestWith(download: true);
      final run = controller.startBuild(request);
      await until(() => controller.isAwaitingMasterGames);
      expect(controller.isAwaitingMasterGames, isTrue);
      controller.dispose();
      await run.timeout(const Duration(seconds: 5));
      expect(controller.isGenerating, isFalse);
      expect(controller.generatedTree, isNull);
      await controller.startBuild(request);
      expect(controller.isGenerating, isFalse);
      hold.complete();
      await svc.syncCompletion.timeout(const Duration(seconds: 5));
    });

    test(
      'Stockfish expectimax skips master downloads even when a legacy preset enables them',
      () async {
        final svc = await emptyService();
        final controller = GenerationSessionController(
          databases:
              (_engineFixtureSettings ??= testRuntimeSettings()).databases,
          jobs: JobManager(),
          enginePool: engines.pool,
          engineLifecycle: engines.lifecycle,
          artifacts: generationArtifactsFixture(),
          publication: generationPublicationFixture(),
        )..masterGames = () => svc;

        // Refused for an unrelated reason (a resume from another position), so
        // the pipeline stops before the engine — what matters is that it did
        // not stop on the download first.
        final request = GenerationRequest(
          jobLabel: 'Test generation',
          config: const TreeBuildConfig(
            startFen: kStandardStartFen,
            playAsWhite: true,
            downloadMasterGamesIfMissing: true,
          ),
          repertoireFilePath: '${tmp.path}/rep.pgn',
          buildRootFen: kStandardStartFen,
          lineMovePrefix: const [],
          repertoireStartFen: kStandardStartFen,
          onPublished: (_) {},
          existingTree: _smallTree(rootFen: _fenAfterE4),
        );
        await controller.startBuild(request);

        expect(controller.lastError, contains('Cannot resume'));
        expect(controller.isAwaitingMasterGames, isFalse);
        expect(svc.isSyncing, isFalse, reason: 'no download was started');
        controller.dispose();
      },
    );
  });
}
