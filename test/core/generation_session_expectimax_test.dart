import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/chess_core/generation/expectimax_probe_codec.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../support/runtime_settings.dart';
import '../support/generation_artifacts_fixture.dart';
import '../support/generation_publication_fixture.dart';
// The expectimax database on GenerationSessionController: loading what a
// repertoire saved, refusing a probe it cannot place, and keeping a
// probe-origin main tree when a full build arrives.

import 'dart:async';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import '../services/generation/engine_fakes.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/core/generation_session_types.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/chess_core/generation/tree_serialization.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';

const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
const _afterE4C5 =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2';

BuildTree _tree(String rootFen, {String childFen = _afterE4}) {
  final root = BuildTreeNode(
    fen: rootFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: 1,
  )..engineEvalCp = 20;
  final child = BuildTreeNode(
    fen: childFen,
    moveSan: 'x',
    moveUci: 'a1a1',
    ply: 1,
    isWhiteToMove: false,
    nodeId: 2,
    parent: root,
  )..engineEvalCp = 25;
  root.children.add(child);
  return BuildTree(root: root, totalNodes: 2)..computeMetadata();
}

class _CapturingGeneration extends GenerationSessionController {
  _CapturingGeneration(MemoryGenerationArtifacts storage)
    : super(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: GenerationArtifacts(storage),
        publication: generationPublicationFixture(),
      );
  GenerationRequest? request;
  @override
  Future<void> startBuild(GenerationRequest request) async {
    this.request = request;
  }
}

class _PvLifecycle extends EngineLifecycle {
  _PvLifecycle()
    : super(
        pool: engines.pool,
        board: engines.board,
        loadEnabled: () async => true,
        saveEnabled: (_) async {},
      );
  final entered = Completer<void>();
  Completer<void>? gate;
  @override
  Future<void> enterGeneration(int threads) async {
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
  }

  @override
  Future<void> exitGeneration() async {}
}

const _pvTarget = ExpectimaxProbeTarget(
  repertoireFilePath: '/r/x.pgn',
  repertoireStartFen: kStandardStartFen,
  movesFromStart: [],
  moveSan: 'e4',
  plies: 1,
  playAsWhite: true,
);

RuntimeSettings? _engineFixtureSettings;
EngineRuntime get engines =>
    testEngines(_engineFixtureSettings ??= testRuntimeSettings());
void main() {
  setUp(() async {
    _engineFixtureSettings = testRuntimeSettings();
    await _engineFixtureSettings!.databases.ensureLoaded();
    addTearDown(() => _engineFixtureSettings?.dispose());
  });
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryGenerationArtifacts storage;
  setUp(() {
    storage = MemoryGenerationArtifacts();
  });

  test('PV save failure reports an error instead of durable success', () async {
    storage.failure = StateError('disk full');
    final pool = FakeStockfishPool();
    pool.discoveryByFen[playUciMove(
      kStandardStartFen,
      'e2e4',
    )!] = DiscoveryResult(
      lines: [
        discoveryLine(pvNumber: 1, cpWhite: 25, pv: ['e7e5', 'g1f3']),
      ],
      depth: 14,
    );
    final controller = GenerationSessionController(
      databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
      jobs: JobManager(),
      artifacts: GenerationArtifacts(storage),
      publication: generationPublicationFixture(),
      enginePool: pool,
      engineLifecycle: _PvLifecycle(),
    );
    addTearDown(controller.dispose);
    final error = await controller.computeMovePv(_pvTarget);
    expect(error, contains('disk full'));
    expect(controller.lastRunSummary, isNot(contains('saved')));
    expect(controller.isGenerating, isFalse);
    expect(storage.saved, isEmpty);
  });

  test('cancel during engine entry never starts PV discovery', () async {
    final lifecycle = _PvLifecycle()..gate = Completer<void>();
    final pool = FakeStockfishPool();
    final controller = GenerationSessionController(
      databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
      jobs: JobManager(),
      artifacts: GenerationArtifacts(storage),
      publication: generationPublicationFixture(),
      enginePool: pool,
      engineLifecycle: lifecycle,
    );
    addTearDown(controller.dispose);
    final pending = controller.computeMovePv(_pvTarget);
    await lifecycle.entered.future;
    controller.cancelBuild();
    lifecycle.gate!.complete();
    expect(await pending, isNull);
    expect(pool.discoverMultiPvCalls, isEmpty);
    expect(controller.lastRunSummary, contains('cancelled'));
    expect(controller.lastError, isNull);
    expect(storage.saved, isEmpty);
  });

  for (final pv in [true, false]) {
    test(
      'superseded chapter load cannot launch ${pv ? 'PV' : 'tree'} against another database',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        storage.beforeRead = (path) async {
          if (path == '/r/x.pgn') {
            entered.complete();
            await release.future;
          }
        };
        final controller = _CapturingGeneration(storage);
        addTearDown(controller.dispose);
        final pending = pv
            ? controller.computeMovePv(_pvTarget)
            : controller.computeExpectimax(_pvTarget);
        await entered.future;
        await controller.loadSavedTreeFor('/r/other.pgn');
        release.complete();
        expect(await pending, contains('session changed'));
        expect(controller.request, isNull);
        expect(storage.saved, isEmpty);
      },
    );
  }

  group('loadSavedTreeFor', () {
    test('loads the build tree and its probes', () async {
      (storage.saved['/r/x.pgn'] ??= {})[GenerationArtifactKind.tree] =
          serializeTree(_tree(kStandardStartFen));
      (storage.saved['/r/x.pgn'] ??=
          {})[GenerationArtifactKind.probes] = ExpectimaxProbeCodec.encode([
        _tree(_afterE4C5, childFen: 'probe-child'),
      ]);
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: GenerationArtifacts(storage),
        publication: generationPublicationFixture(),
      );

      await controller.loadSavedTreeFor('/r/x.pgn');

      expect(controller.generatedTree?.root.fen, kStandardStartFen);
      expect(controller.current!.probes.length, 1);
      expect(
        controller.generatedTreeFenMap!.getCanonical(_afterE4C5),
        isNotNull,
      );
      controller.dispose();
    });

    test('a repertoire with only probes uses the first as its tree', () async {
      (storage.saved['/r/x.pgn'] ??=
          {})[GenerationArtifactKind.probes] = ExpectimaxProbeCodec.encode([
        _tree(_afterE4C5, childFen: 'probe-child'),
        _tree(_afterE4, childFen: 'other-child'),
      ]);
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: GenerationArtifacts(storage),
        publication: generationPublicationFixture(),
      );

      await controller.loadSavedTreeFor('/r/x.pgn');

      expect(controller.generatedTree?.root.fen, _afterE4C5);
      expect(controller.current!.probes.single.root.fen, _afterE4);
      controller.dispose();
    });

    test('a repertoire with nothing saved ends with no tree', () async {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: GenerationArtifacts(storage),
        publication: generationPublicationFixture(),
      );
      controller.onTreeBuilt(_tree(kStandardStartFen));

      await controller.loadSavedTreeFor('/r/none.pgn');

      expect(controller.generatedTree, isNull);
      controller.dispose();
    });

    test('a full build keeps a probe-origin main tree as a probe', () async {
      (storage.saved['/r/x.pgn'] ??=
          {})[GenerationArtifactKind.probes] = ExpectimaxProbeCodec.encode([
        _tree(_afterE4C5, childFen: 'probe-child'),
      ]);
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: GenerationArtifacts(storage),
        publication: generationPublicationFixture(),
      );
      await controller.loadSavedTreeFor('/r/x.pgn');

      controller.onTreeBuilt(_tree(kStandardStartFen));

      expect(controller.generatedTree?.root.fen, kStandardStartFen);
      expect(controller.current!.probes.single.root.fen, _afterE4C5);
      controller.dispose();
    });
  });

  group('computeExpectimax', () {
    test('unknown settings refuse before any artifact read or build', () async {
      final previous = _engineFixtureSettings!;
      addTearDown(previous.dispose);
      _engineFixtureSettings = testRuntimeSettings();
      var reads = 0;
      storage.beforeRead = (_) async {
        reads++;
      };
      final controller = _CapturingGeneration(storage);
      addTearDown(controller.dispose);
      expect(
        await controller.computeExpectimax(_pvTarget),
        contains('settings'),
      );
      expect(reads, 0);
      expect(controller.request, isNull);
    });

    test(
      'probe captures committed API policy before its artifact await',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        storage.beforeRead = (_) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        };
        final controller = _CapturingGeneration(storage);
        addTearDown(controller.dispose);
        final pending = controller.computeExpectimax(_pvTarget);
        await entered.future;
        await _engineFixtureSettings!.databases.setChessDbApiForExpectimax(
          true,
        );
        release.complete();
        expect(await pending, isNull);
        expect(controller.request!.config.enableChessDbApi, isFalse);
        expect(await controller.computeExpectimax(_pvTarget), isNull);
        expect(controller.request!.config.enableChessDbApi, isTrue);
      },
    );

    test(
      'loads existing analysis before the first position generation',
      () async {
        (storage.saved['/r/x.pgn'] ??=
            {})[GenerationArtifactKind.probes] = ExpectimaxProbeCodec.encode([
          _tree(_afterE4C5, childFen: 'probe-child'),
        ]);
        final controller = _CapturingGeneration(storage);
        await controller.computeExpectimax(
          const ExpectimaxProbeTarget(
            repertoireFilePath: '/r/x.pgn',
            repertoireStartFen: kStandardStartFen,
            movesFromStart: [],
            plies: 1,
            engineThreads: 1,
            playAsWhite: true,
          ),
        );
        expect(
          controller.generatedTreeFenMap!.getCanonical(_afterE4C5),
          isNotNull,
        );
        expect(controller.request!.expectimaxOnly, isTrue);
        controller.dispose();
      },
    );
    test(
      'explicit depth and cores create a database-only request at the chosen move',
      () async {
        final controller = _CapturingGeneration(storage);
        final error = await controller.computeExpectimax(
          const ExpectimaxProbeTarget(
            repertoireFilePath: '/r/x.pgn',
            repertoireStartFen: kStandardStartFen,
            movesFromStart: ['e4'],
            moveSan: 'c5',
            plies: 3,
            engineThreads: 1,
            playAsWhite: true,
          ),
        );
        expect(error, isNull);
        final request = controller.request!;
        expect(request.expectimaxOnly, isTrue);
        expect(request.config.maxPly, 3);
        expect(request.config.coverMinProb, 0);
        expect(request.config.masterDepthBonusPlies, 0);
        expect(request.config.resolvedEngineThreads, 1);
        expect(request.lineMovePrefix, ['e4', 'c5']);
        expect(request.buildRootFen, _afterE4C5.replaceFirst(' c6 ', ' - '));
        expect(request.config.verifyFinal, isFalse);
        expect(request.config.downloadMasterGamesIfMissing, isFalse);
        expect(storage.saved, isEmpty);
        controller.dispose();
      },
    );
    test('refuses moves it cannot play from the start', () async {
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: GenerationArtifacts(storage),
        publication: generationPublicationFixture(),
      );

      final error = await controller.computeExpectimax(
        const ExpectimaxProbeTarget(
          repertoireFilePath: '/r/x.pgn',
          repertoireStartFen: kStandardStartFen,
          movesFromStart: ['e4', 'Qxd8'],
          plies: 8,
          playAsWhite: true,
        ),
      );

      expect(error, contains('Could not play'));
      expect(controller.isGenerating, isFalse);
      expect(controller.isExpectimaxProbe, isFalse);
      controller.dispose();
    });
  });
}
