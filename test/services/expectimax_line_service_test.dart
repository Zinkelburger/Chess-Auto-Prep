import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/expectimax_line_service.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';

void main() {
  late BuildTree tree;
  late TreeBuildConfig config;

  BuildTreeNode _makeNode({
    required String fen,
    required String san,
    required String uci,
    required int ply,
    required bool isWhiteToMove,
    double moveProbability = 0.0,
    int? evalCp,
    double expectimax = 0.5,
    bool hasExpectimax = true,
    bool isRepertoireMove = false,
  }) {
    final n = BuildTreeNode(
      fen: fen,
      moveSan: san,
      moveUci: uci,
      ply: ply,
      isWhiteToMove: isWhiteToMove,
      nodeId: 0,
    )
      ..moveProbability = moveProbability
      ..expectimaxValue = expectimax
      ..hasExpectimax = hasExpectimax
      ..isRepertoireMove = isRepertoireMove;
    if (evalCp != null) n.engineEvalCp = evalCp;
    return n;
  }

  setUp(() {
    config = const TreeBuildConfig(
      startFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      playAsWhite: true,
    );

    // Tree:   root (white to move)
    //         ├── e4 (V=0.62, eval=+30)
    //         │   └── c5 (prob=0.41, V=0.60, eval=-25)
    //         │       └── Nf3 (V=0.58, eval=+35)
    //         └── d4 (V=0.55, eval=+20)
    //             └── d5 (prob=0.50, V=0.52, eval=-15)
    final root = _makeNode(
      fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      san: '',
      uci: '',
      ply: 0,
      isWhiteToMove: true,
    );

    final e4 = _makeNode(
      fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
      san: 'e4',
      uci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
      expectimax: 0.62,
      evalCp: 30,
      isRepertoireMove: true,
    );

    final c5 = _makeNode(
      fen: 'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2',
      san: 'c5',
      uci: 'c7c5',
      ply: 2,
      isWhiteToMove: true,
      moveProbability: 0.41,
      expectimax: 0.60,
      evalCp: -25,
    );

    final nf3 = _makeNode(
      fen: 'rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2',
      san: 'Nf3',
      uci: 'g1f3',
      ply: 3,
      isWhiteToMove: false,
      expectimax: 0.58,
      evalCp: 35,
    );

    final d4 = _makeNode(
      fen: 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1',
      san: 'd4',
      uci: 'd2d4',
      ply: 1,
      isWhiteToMove: false,
      expectimax: 0.55,
      evalCp: 20,
    );

    final d5 = _makeNode(
      fen: 'rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq d6 0 2',
      san: 'd5',
      uci: 'd7d5',
      ply: 2,
      isWhiteToMove: true,
      moveProbability: 0.50,
      expectimax: 0.52,
      evalCp: -15,
    );

    root.children.addAll([e4, d4]);
    e4.parent = root;
    d4.parent = root;
    e4.children.add(c5);
    c5.parent = e4;
    c5.children.add(nf3);
    nf3.parent = c5;
    d4.children.add(d5);
    d5.parent = d4;

    tree = BuildTree(
      root: root,
      totalNodes: 6,
      maxPlyReached: 3,
      buildComplete: true,
      startMoves: '',
      configSnapshot: config.toJson(),
    );

    void markExplored(BuildTreeNode n) {
      n.explored = true;
      for (final c in n.children) {
        markExplored(c);
      }
    }

    markExplored(root);
  });

  group('followExpectimaxLine', () {
    test('follows best expectimax at our-move, most probable at opponent', () {
      final eca = ExpectimaxCalculator(config: config);
      final path = followExpectimaxLine(
        tree.root,
        config,
        eca,
        maxPlies: 10,
      );

      expect(path.length, 3);
      expect(path[0].moveSan, 'e4');
      expect(path[1].moveSan, 'c5');
      expect(path[2].moveSan, 'Nf3');
    });

    test('respects maxPlies limit', () {
      final eca = ExpectimaxCalculator(config: config);
      final path = followExpectimaxLine(
        tree.root,
        config,
        eca,
        maxPlies: 1,
      );

      expect(path.length, 1);
      expect(path[0].moveSan, 'e4');
    });

    test('returns empty for leaf node', () {
      final leaf = tree.root.children[0].children[0].children[0]; // Nf3
      final eca = ExpectimaxCalculator(config: config);
      final path = followExpectimaxLine(leaf, config, eca, maxPlies: 10);
      expect(path, isEmpty);
    });
  });

  group('generateExpectimaxLines', () {
    test('topLines=2 returns two sorted lines', () {
      final eca = ExpectimaxCalculator(config: config);
      final lines = generateExpectimaxLines(
        tree.root,
        config,
        eca,
        topLines: 2,
        maxPlies: 10,
      );

      expect(lines.length, 2);
      expect(lines[0].rank, 1);
      expect(lines[1].rank, 2);
      expect(lines[0].expectimaxValue, greaterThan(lines[1].expectimaxValue));
      expect(lines[0].movesSan[0], 'e4');
      expect(lines[1].movesSan[0], 'd4');
    });

    test('topLines=1 returns single line', () {
      final eca = ExpectimaxCalculator(config: config);
      final lines = generateExpectimaxLines(
        tree.root,
        config,
        eca,
        topLines: 1,
        maxPlies: 10,
      );

      expect(lines.length, 1);
      expect(lines[0].movesSan[0], 'e4');
    });

    test('opponent-move node returns top opponent replies', () {
      final e4 = tree.root.children[0];
      final e6 = _makeNode(
        fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
        san: 'e6',
        uci: 'e7e6',
        ply: 2,
        isWhiteToMove: true,
        moveProbability: 0.25,
        expectimax: 0.58,
        evalCp: -20,
      );
      e4.children.add(e6);
      e6.parent = e4;

      final eca = ExpectimaxCalculator(config: config);
      final lines = generateExpectimaxLines(
        e4,
        config,
        eca,
        topLines: 3,
        maxPlies: 10,
      );

      expect(lines.length, 2);
      expect(lines[0].movesSan[0], 'c5');
      expect(lines[1].movesSan[0], 'e6');
    });
  });

  group('ExpectimaxLine.fromPath', () {
    test('populates moveInfo with correct metadata', () {
      final eca = ExpectimaxCalculator(config: config);
      final path = followExpectimaxLine(tree.root, config, eca, maxPlies: 10);
      final line = ExpectimaxLine.fromPath(tree.root, path, config, rank: 1);

      expect(line.rank, 1);
      expect(line.depth, 3);
      expect(line.movesSan, ['e4', 'c5', 'Nf3']);
      expect(line.movesUci, ['e2e4', 'c7c5', 'g1f3']);

      // e4 is our move (white), and it's the repertoire move
      expect(line.moveInfo[0].isOurMove, true);
      expect(line.moveInfo[0].isRepertoireMove, true);

      // c5 is opponent's move
      expect(line.moveInfo[1].isOurMove, false);
      expect(line.moveInfo[1].moveProbability, 0.41);
    });
  });

  group('hasPrecomputedExpectimaxAtPly', () {
    test('false when subtree not explored to target ply', () {
      expect(
        hasPrecomputedExpectimaxAtPly(tree, tree.root.fen, 10),
        isFalse,
      );
    });

    test('true when subtree is complete to target ply', () {
      expect(
        hasPrecomputedExpectimaxAtPly(tree, tree.root.fen, 3),
        isTrue,
      );
    });
  });

  group('findNodeByFen', () {
    test('finds root', () {
      final node = findNodeByFen(tree, tree.root.fen);
      expect(node, isNotNull);
      expect(node, tree.root);
    });

    test('finds child', () {
      final node = findNodeByFen(tree, tree.root.children[0].fen);
      expect(node, isNotNull);
      expect(node!.moveSan, 'e4');
    });

    test('returns null for unknown FEN', () {
      final node = findNodeByFen(tree, 'unknown-fen');
      expect(node, isNull);
    });
  });
}
