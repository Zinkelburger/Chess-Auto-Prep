// GenerationArtifactStore: the files beside a repertoire, read and written
// through an in-memory storage so no disk is touched.

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_artifacts.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/course/course_composer.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_storage.dart';

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

  late MemoryStorage storage;
  late GenerationArtifactStore store;
  setUp(() {
    storage = MemoryStorage();
    store = GenerationArtifactStore(storage: () => storage);
  });

  test('artifact paths hang off the repertoire file name', () {
    expect(GenerationArtifactStore.treePathFor('/r/x.pgn'), '/r/x_tree.json');
    expect(
      GenerationArtifactStore.partialTreePathFor('/r/x.pgn'),
      '/r/x_partial_tree.json',
    );
    expect(
      GenerationArtifactStore.probesPathFor('/r/x.pgn'),
      '/r/x_expectimax.json',
    );
    expect(
      GenerationArtifactStore.modelGamesPathFor('/r/x.pgn'),
      '/r/x_model_games.pgn',
    );
  });

  test('a written tree reads back as the database main tree', () async {
    final json = await store.writeTree(_tree(kStandardStartFen), '/r/x.pgn');

    expect(json, isNotNull);
    expect(storage.files['/r/x_tree.json'], json);
    final saved = await store.readDatabase('/r/x.pgn');
    expect(saved.tree?.root.fen, kStandardStartFen);
    expect(saved.tree?.totalNodes, 2);
    expect(saved.probes, isEmpty);
  });

  test('a failed tree write is swallowed and reported as null', () async {
    storage.failWrites = true;
    expect(await store.writeTree(_tree(kStandardStartFen), '/r/x.pgn'), isNull);
  });

  test('partial trees are written compactly and deleted quietly', () async {
    await store.writePartialTree(_tree(kStandardStartFen), '/r/x.pgn');
    final text = storage.files['/r/x_partial_tree.json']!;
    expect(text, isNot(contains('\n  ')), reason: 'compact encoding');
    expect(deserializeTree(text).totalNodes, 2);

    await store.deletePartialTree('/r/x.pgn');
    expect(storage.files, isEmpty);
    // Deleting what is not there is not an error.
    await store.deletePartialTree('/r/x.pgn');
  });

  test('a corrupt probe file does not hide a good tree', () async {
    await store.writeTree(_tree(kStandardStartFen), '/r/x.pgn');
    storage.files['/r/x_expectimax.json'] = 'not json';

    final saved = await store.readDatabase('/r/x.pgn');

    expect(saved.tree, isNotNull);
    expect(saved.probes, isEmpty);
  });

  group('writeDatabase', () {
    test('writes probes and, when asked, the main tree', () async {
      await store.writeDatabase(
        '/r/x.pgn',
        probeTrees: [_tree(_afterE4)],
        mainTree: _tree(kStandardStartFen),
      );

      final saved = await store.readDatabase('/r/x.pgn');
      expect(saved.tree?.root.fen, kStandardStartFen);
      expect(saved.probes.single.root.fen, _afterE4);
    });

    test('removes the probe file when there are no probes left', () async {
      storage.files['/r/x_expectimax.json'] = 'stale';
      await store.writeDatabase('/r/x.pgn', probeTrees: const []);
      expect(storage.files.containsKey('/r/x_expectimax.json'), isFalse);
    });

    test('rethrows a failed write so nobody reports a save', () async {
      storage.failWrites = true;
      await expectLater(
        store.writeDatabase('/r/x.pgn', probeTrees: [_tree(_afterE4)]),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('writeModelGames', () {
    const empty = ComposedCourse(title: 't', entries: [], outline: []);
    const withGames = ComposedCourse(
      title: 't',
      entries: [],
      outline: [],
      modelGamePgns: [
        '[Event "a"]\n\n1. e4 1-0\n',
        '[Event "b"]\n\n1. d4 1-0\n',
      ],
    );

    test('writes the companion collection and returns its path', () async {
      final path = await store.writeModelGames(withGames, '/r/x.pgn');
      expect(path, '/r/x_model_games.pgn');
      expect(storage.files[path], withGames.modelGamesPgn());
    });

    test('a course without model games removes a stale companion', () async {
      storage.files['/r/x_model_games.pgn'] = 'old';
      expect(await store.writeModelGames(empty, '/r/x.pgn'), isNull);
      expect(storage.files, isEmpty);
    });

    test('a failed write is reported as nothing written', () async {
      storage.failWrites = true;
      expect(await store.writeModelGames(withGames, '/r/x.pgn'), isNull);
    });
  });
}
