import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/traps/models/trap_reply.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/trap_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

const _trapFen =
    'rnbqkbnr/pp1ppppp/2p5/3P4/8/8/PPP1PPPP/RNBQKBNR b KQkq - 0 3';

BuildTree _trapFixtureTree() {
  final root = BuildTreeNode(
    fen: kStandardStartFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: 0,
  )..engineEvalCp = 25;

  final e4 = BuildTreeNode(
    fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
    moveSan: 'e4',
    moveUci: 'e2e4',
    ply: 1,
    isWhiteToMove: false,
    nodeId: 1,
    parent: root,
    moveProbability: 1.0,
    cumulativeProbability: 1.0,
  )..engineEvalCp = 30;
  root.children.add(e4);

  final c6 = BuildTreeNode(
    fen: 'rnbqkbnr/pp1ppppp/2p5/4P3/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
    moveSan: 'c6',
    moveUci: 'c7c6',
    ply: 2,
    isWhiteToMove: true,
    nodeId: 2,
    parent: e4,
    moveProbability: 1.0,
    cumulativeProbability: 1.0,
  )..engineEvalCp = 28;
  e4.children.add(c6);

  final trapNode = BuildTreeNode(
    fen: _trapFen,
    moveSan: 'd4',
    moveUci: 'd2d4',
    ply: 3,
    isWhiteToMove: false,
    nodeId: 3,
    parent: c6,
    moveProbability: 1.0,
    cumulativeProbability: 1.0,
  )
    ..engineEvalCp = 20
    ..openingName = 'Caro-Kann Defense'
    ..hasExpectimax = true
    ..expectimaxValue = 0.55;
  c6.children.add(trapNode);

  final popularReply = BuildTreeNode(
    fen: 'rnbqkbnr/ppp1pppp/2p5/3pP3/3P4/8/PPP2PPP/RNBQKBNR w KQkq - 0 4',
    moveSan: 'd5',
    moveUci: 'd7d5',
    ply: 4,
    isWhiteToMove: true,
    nodeId: 4,
    parent: trapNode,
    moveProbability: 0.65,
    cumulativeProbability: 0.65,
  )..engineEvalCp = 180;
  trapNode.children.add(popularReply);

  final bestReply = BuildTreeNode(
    fen: 'rnbqkbnr/pp2pppp/2p5/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 4',
    moveSan: 'Nf6',
    moveUci: 'g8f6',
    ply: 4,
    isWhiteToMove: true,
    nodeId: 5,
    parent: trapNode,
    moveProbability: 0.15,
    cumulativeProbability: 0.15,
  )..engineEvalCp = -40;
  trapNode.children.add(bestReply);

  return BuildTree(root: root);
}

void main() {
  group('TrapExtractor', () {
    test('populates fen, openingName, positionEvalCp, and allReplies', () {
      final tree = _trapFixtureTree();
      final extractor = TrapExtractor(playAsWhite: true);
      final traps = extractor.extract(tree);

      expect(traps, isNotEmpty);

      final trap = traps.firstWhere((t) => t.popularMove == 'd5');
      expect(trap.fen, _trapFen);
      expect(trap.openingName, 'Caro-Kann Defense');
      expect(trap.positionEvalCp, -20);
      expect(trap.allReplies, isNotNull);
      expect(trap.allReplies!.length, 2);

      final popular = trap.allReplies!.first;
      expect(popular.san, 'd5');
      expect(popular.probability, closeTo(0.65, 0.001));
      expect(popular.evalAfterCp, 180);
      expect(popular.classification, TrapReplyClass.blunder);

      final best = trap.allReplies!.last;
      expect(best.san, 'Nf6');
      expect(best.classification, TrapReplyClass.good);
    });
  });
}
