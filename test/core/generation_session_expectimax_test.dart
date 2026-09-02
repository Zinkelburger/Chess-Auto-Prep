// The expectimax database on GenerationSessionController: loading what a
// repertoire saved, refusing a probe it cannot place, and keeping a
// probe-origin main tree when a full build arrives.

import 'package:chess_auto_prep/constants/chess_constants.dart';
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

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<String?> readFile(String path) async => files[path];

  @override
  Future<void> writeFile(String path, String content) async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryStorage storage;
  setUp(() {
    storage = _MemoryStorage();
    StorageFactory.instanceForTest = storage;
  });
  tearDown(() => StorageFactory.instanceForTest = null);

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
