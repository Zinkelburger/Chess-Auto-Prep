import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/trap_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

/// The extractor trusts the trap score Phase 2 already stored on a node when
/// that score cannot clear its bar — but only when it discounts findability
/// the same way, since an undiscounted analysis can score higher.
void main() {
  const trapFen =
      'rnbqkbnr/pp1ppppp/2p5/3P4/8/8/PPP1PPPP/RNBQKBNR b KQkq - 0 3';

  BuildTree treeWithTrap() {
    final root = BuildTreeNode(
      fen: kStandardStartFen,
      moveSan: '',
      moveUci: '',
      ply: 0,
      isWhiteToMove: true,
      nodeId: 1,
    );
    final trap =
        BuildTreeNode(
            fen: trapFen,
            moveSan: 'd4',
            moveUci: 'd2d4',
            ply: 3,
            isWhiteToMove: false,
            nodeId: 2,
            parent: root,
          )
          ..engineEvalCp = 20
          ..hasExpectimax = true
          ..expectimaxValue = 0.55;
    root.children.add(trap);
    trap.children.add(
      BuildTreeNode(
        fen: 'rnbqkbnr/ppp1pppp/2p5/3pP3/3P4/8/PPP2PPP/RNBQKBNR w KQkq - 0 4',
        moveSan: 'd5',
        moveUci: 'd7d5',
        ply: 4,
        isWhiteToMove: true,
        nodeId: 3,
        parent: trap,
        moveProbability: 0.65,
        cumulativeProbability: 0.65,
      )..engineEvalCp = 180,
    );
    trap.children.add(
      BuildTreeNode(
        fen: 'rnbqkbnr/pp2pppp/2p5/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 4',
        moveSan: 'Nf6',
        moveUci: 'g8f6',
        ply: 4,
        isWhiteToMove: true,
        nodeId: 4,
        parent: trap,
        moveProbability: 0.15,
        cumulativeProbability: 0.15,
      )..engineEvalCp = -40,
    );
    return BuildTree(root: root, totalNodes: 4);
  }

  test('an unscored node is analysed as before', () {
    final traps = TrapExtractor(
      playAsWhite: true,
      findabilityPRef: 0.3,
    ).extract(treeWithTrap());
    expect(traps.map((t) => t.fen), [trapFen]);
  });

  test('a stored score under the bar skips the node when discounting', () {
    final tree = treeWithTrap();
    tree.root.children.single.trapScore = 0.01;
    final traps = TrapExtractor(
      playAsWhite: true,
      findabilityPRef: 0.3,
    ).extract(tree);
    expect(traps, isEmpty);
  });

  test('without a findability discount the stored score is not trusted', () {
    final tree = treeWithTrap();
    tree.root.children.single.trapScore = 0.01;
    final traps = TrapExtractor(playAsWhite: true).extract(tree);
    expect(traps.map((t) => t.fen), [trapFen]);
  });

  test('a stored score over the bar still runs the full analysis', () {
    final tree = treeWithTrap();
    tree.root.children.single.trapScore = 0.9;
    final traps = TrapExtractor(
      playAsWhite: true,
      findabilityPRef: 0.3,
    ).extract(tree);
    expect(traps.single.trickSurplus, greaterThan(0));
  });
}
