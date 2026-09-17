// GenerationArtifacts: the files beside a repertoire, read and written
// through an in-memory storage so no disk is touched.

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/chess_core/generation/tree_serialization.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/generation_artifacts_fixture.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';

const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

BuildTree _tree(String rootFen) {
  final root = BuildTreeNode(
    fen: rootFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: 1,
  )..engineEvalCp = 20;
  root.children.add(
    BuildTreeNode(
      fen: _afterE4,
      moveSan: 'e4',
      moveUci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
      nodeId: 2,
      parent: root,
    )..engineEvalCp = 25,
  );
  return BuildTree(root: root, totalNodes: 2)..computeMetadata();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryGenerationArtifacts repository;
  late GenerationArtifacts store;
  setUp(() {
    repository = MemoryGenerationArtifacts();
    store = GenerationArtifacts(repository);
  });

  test(
    'async tree encoding captures the tree before the caller can edit it',
    () async {
      final tree = _tree(kStandardStartFen);
      final expected = serializeTree(tree, indent: false);
      final pending = GenerationArtifacts.encodeTreeSnapshot(
        tree,
        indent: false,
      );
      tree.root.engineEvalCp = 999;
      tree.root.children.clear();
      expect(await pending, expected);
    },
  );

  test('a complete staged bundle round-trips tree, probes and traps', () async {
    final run = await store.repository.begin('/r/x.pgn', {});
    final proposal = await store.prepareBundle(
      run,
      tree: _tree(kStandardStartFen),
      probes: [_tree(_afterE4)],
      traps: [],
    );
    expect((await store.readDatabase('/r/x.pgn')).tree, isNull);
    await store.repository.select(run, proposal);
    final saved = await store.readDatabase('/r/x.pgn');
    expect(saved.tree?.root.fen, kStandardStartFen);
    expect(saved.tree?.totalNodes, 2);
    expect(saved.probes.single.root.fen, _afterE4);
    expect(await store.readTraps('/r/x.pgn'), isEmpty);
  });

  test(
    'failed staging propagates so a completed export cannot claim a saved cache',
    () async {
      final run = await store.repository.begin('/r/x.pgn', {});
      repository.failure = StateError('disk full');
      await expectLater(
        store.prepareBundle(
          run,
          tree: _tree(kStandardStartFen),
          probes: [],
          traps: [],
        ),
        throwsStateError,
      );
    },
  );

  test(
    'partial snapshots encode compactly and discard removes only the selection',
    () async {
      final run = await store.repository.begin('/r/x.pgn', {});
      await store.writePartialTree(_tree(kStandardStartFen), run);
      final text =
          repository.saved['/r/x.pgn']![GenerationArtifactKind.partial]!;
      expect(text, isNot(contains('\n  ')));
      expect(deserializeTree(text).totalNodes, 2);
      expect((await store.readPartial('/r/x.pgn'))!.tree.totalNodes, 2);
      await store.discardPartial(
        '/r/x.pgn',
        (await store.readPartial('/r/x.pgn'))!.generationId,
      );
      expect(await store.readPartial('/r/x.pgn'), isNull);
    },
  );

  test(
    'probe-origin database round-trips without manufacturing a main tree',
    () async {
      final run = await store.repository.begin('/r/x.pgn', {});
      await store.writeDatabase(
        run,
        probeTrees: [_tree(_afterE4)],
        mainTree: null,
        traps: [],
      );
      final saved = await store.readDatabase('/r/x.pgn');
      expect(saved.tree, isNull);
      expect(saved.probes.single.root.fen, _afterE4);
    },
  );
}
