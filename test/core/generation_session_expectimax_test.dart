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
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/expectimax_probe.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
const _afterE4C5 =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2';

class _MemoryStorage implements StorageService {
  final Map<String, String> files = {};
  bool failWrites = false;
  Future<void> Function(String)? beforeExists;

  @override
  Future<bool> fileExists(String path) async {
    await beforeExists?.call(path);
    return files.containsKey(path);
  }

  @override
  Future<String?> readFile(String path) async => files[path];

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (failWrites) throw StateError('disk full');
    if (createOnly && files.containsKey(path)) {
      throw StateError('file exists');
    }
    files[path] = content;
  }

  @override
  Future<void> deleteFile(String path) async {
    files.remove(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

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
  GenerationRequest? request;
  @override
  Future<void> startBuild(GenerationRequest request) async {
    this.request = request;
  }
}

class _PvLifecycle extends EngineLifecycle {
  _PvLifecycle() : super.fresh();
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryStorage storage;
  setUp(() {
    storage = _MemoryStorage();
    StorageFactory.instanceForTest = storage;
  });
  tearDown(() => StorageFactory.instanceForTest = null);

  test('PV save failure reports an error instead of durable success', () async {
    storage.failWrites = true;
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
      enginePool: pool,
      engineLifecycle: _PvLifecycle(),
    );
    addTearDown(controller.dispose);
    final error = await controller.computeMovePv(_pvTarget);
    expect(error, contains('disk full'));
    expect(controller.lastRunSummary, isNot(contains('saved')));
    expect(controller.isGenerating, isFalse);
    expect(storage.files, isEmpty);
  });

  test('cancel during engine entry never starts PV discovery', () async {
    final lifecycle = _PvLifecycle()..gate = Completer<void>();
    final pool = FakeStockfishPool();
    final controller = GenerationSessionController(
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
    expect(storage.files, isEmpty);
  });

  for (final pv in [true, false]) {
    test(
      'superseded chapter load cannot launch ${pv ? 'PV' : 'tree'} against another database',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        storage.beforeExists = (path) async {
          if (path == '/r/x_tree.json') {
            entered.complete();
            await release.future;
          }
        };
        final controller = _CapturingGeneration();
        addTearDown(controller.dispose);
        final pending = pv
            ? controller.computeMovePv(_pvTarget)
            : controller.computeExpectimax(_pvTarget);
        await entered.future;
        await controller.loadSavedTreeFor('/r/other.pgn');
        release.complete();
        expect(await pending, contains('session changed'));
        expect(controller.request, isNull);
        expect(storage.files, isEmpty);
      },
    );
  }

  group('loadSavedTreeFor', () {
    test('loads the build tree and its probes', () async {
      storage.files['/r/x_tree.json'] = serializeTree(_tree(kStandardStartFen));
      storage.files['/r/x_expectimax.json'] = ExpectimaxProbeStore.encode([
        _tree(_afterE4C5, childFen: 'probe-child'),
      ]);
      final controller = GenerationSessionController();

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
      storage.files['/r/x_expectimax.json'] = ExpectimaxProbeStore.encode([
        _tree(_afterE4C5, childFen: 'probe-child'),
        _tree(_afterE4, childFen: 'other-child'),
      ]);
      final controller = GenerationSessionController();

      await controller.loadSavedTreeFor('/r/x.pgn');

      expect(controller.generatedTree?.root.fen, _afterE4C5);
      expect(controller.current!.probes.single.root.fen, _afterE4);
      controller.dispose();
    });

    test('a repertoire with nothing saved ends with no tree', () async {
      final controller = GenerationSessionController();
      controller.onTreeBuilt(_tree(kStandardStartFen));

      await controller.loadSavedTreeFor('/r/none.pgn');

      expect(controller.generatedTree, isNull);
      controller.dispose();
    });

    test('a full build keeps a probe-origin main tree as a probe', () async {
      storage.files['/r/x_expectimax.json'] = ExpectimaxProbeStore.encode([
        _tree(_afterE4C5, childFen: 'probe-child'),
      ]);
      final controller = GenerationSessionController();
      await controller.loadSavedTreeFor('/r/x.pgn');

      controller.onTreeBuilt(_tree(kStandardStartFen));

      expect(controller.generatedTree?.root.fen, kStandardStartFen);
      expect(controller.current!.probes.single.root.fen, _afterE4C5);
      controller.dispose();
    });
  });

  group('computeExpectimax', () {
    test(
      'loads existing analysis before the first position generation',
      () async {
        storage.files['/r/x_expectimax.json'] = ExpectimaxProbeStore.encode([
          _tree(_afterE4C5, childFen: 'probe-child'),
        ]);
        final controller = _CapturingGeneration();
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
        final controller = _CapturingGeneration();
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
        expect(storage.files, isEmpty);
        controller.dispose();
      },
    );
    test('refuses moves it cannot play from the start', () async {
      final controller = GenerationSessionController();

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
