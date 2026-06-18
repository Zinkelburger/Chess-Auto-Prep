// Phase 0 safety-net / bug-repro tests for trap position identity.
//
// These pin the behavior from docs/REFACTOR_PLAN.md:
//   1. Position identity is canonical (move counters do not change a position).
//   2. The extractor and the index agree on that identity.

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/eval/eval_canonicalize.dart';
import 'package:chess_auto_prep/services/generation/trap_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

// Same board position, opponent (black) to move, but reached via different
// move orders so the half/full-move counters differ. canonicalizeFen4 strips
// those counters, so these are the *same* position.
const _posPiecesEtc = 'rnbqkbnr/pp1ppppp/2p5/3P4/8/8/PPP1PPPP/RNBQKBNR b KQkq -';
const _fenCountersA = '$_posPiecesEtc 0 3';
const _fenCountersB = '$_posPiecesEtc 2 8';

TrapLineInfo _trapAt(String fen) => TrapLineInfo(
      movesSan: const ['e4', 'c6', 'd4'],
      trapScore: 0.5,
      popularProb: 0.65,
      popularMove: 'd5',
      bestMove: 'Nf6',
      popularEvalCp: 20,
      bestEvalCp: -40,
      evalDiffCp: 60,
      cumulativeProb: 0.65,
      trickSurplus: 0.05,
      expectimaxValue: 0.55,
      wpEval: 0.50,
      fen: fen,
    );

/// Builds an opponent-to-move trap node (black to move) under [parent] whose
/// FEN uses the given counter suffix, with a popular blunder + best reply.
BuildTreeNode _attachTrap(
  BuildTreeNode parent,
  String trapFen,
  int idBase,
) {
  final trap = BuildTreeNode(
    fen: trapFen,
    moveSan: 'd4',
    moveUci: 'd2d4',
    ply: 3,
    isWhiteToMove: false,
    nodeId: idBase,
    parent: parent,
    moveProbability: 1.0,
    cumulativeProbability: 1.0,
  )
    ..engineEvalCp = 20
    ..hasExpectimax = true
    ..expectimaxValue = 0.55;
  parent.children.add(trap);

  final blunder = BuildTreeNode(
    fen: 'rnbqkbnr/ppp1pppp/2p5/3pP3/3P4/8/PPP2PPP/RNBQKBNR w KQkq - 0 4',
    moveSan: 'd5',
    moveUci: 'd7d5',
    ply: 4,
    isWhiteToMove: true,
    nodeId: idBase + 1,
    parent: trap,
    moveProbability: 0.65,
    cumulativeProbability: 0.65,
  )..engineEvalCp = 180;
  trap.children.add(blunder);

  final best = BuildTreeNode(
    fen: 'rnbqkbnr/pp2pppp/2p5/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 4',
    moveSan: 'Nf6',
    moveUci: 'g8f6',
    ply: 4,
    isWhiteToMove: true,
    nodeId: idBase + 2,
    parent: trap,
    moveProbability: 0.15,
    cumulativeProbability: 0.15,
  )..engineEvalCp = -40;
  trap.children.add(best);

  return trap;
}

void main() {
  group('trap position identity', () {
    test('index finds a trap regardless of move counters',
        () {
      final index = TrapIndexService([_trapAt(_fenCountersA)]);

      // Same position, different counters — must resolve to the same trap.
      expect(index.trapAtFen(_fenCountersA), isNotNull,
          reason: 'exact FEN should hit');
      expect(index.trapAtFen(_fenCountersB), isNotNull,
          reason: 'same position with different counters must hit');
    });

    test('canonicalizeFen4 treats the two counter variants as one position',
        () {
      expect(canonicalizeFen4(_fenCountersA), canonicalizeFen4(_fenCountersB));
    });

    test(
        'extractor dedups a transposed trap to a single entry (regression guard)',
        () {
      // root → two branches that both reach the SAME canonical trap position
      // via different move orders (different counters).
      final root = BuildTreeNode(
        fen: kStandardStartFen,
        moveSan: '',
        moveUci: '',
        ply: 0,
        isWhiteToMove: true,
        nodeId: 0,
      )..engineEvalCp = 25;

      final branchA = BuildTreeNode(
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
        moveSan: 'e4',
        moveUci: 'e2e4',
        ply: 1,
        isWhiteToMove: false,
        nodeId: 1,
        parent: root,
      )..engineEvalCp = 30;
      root.children.add(branchA);

      final branchB = BuildTreeNode(
        fen: 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1',
        moveSan: 'd4',
        moveUci: 'd2d4',
        ply: 1,
        isWhiteToMove: false,
        nodeId: 2,
        parent: root,
      )..engineEvalCp = 30;
      root.children.add(branchB);

      _attachTrap(branchA, _fenCountersA, 100);
      _attachTrap(branchB, _fenCountersB, 200);

      final traps = TrapExtractor(playAsWhite: true).extract(BuildTree(root: root));
      final atPos = traps
          .where((t) =>
              t.fen != null &&
              canonicalizeFen4(t.fen!) == canonicalizeFen4(_fenCountersA))
          .toList();

      expect(atPos.length, 1,
          reason: 'a transposed trap position must appear exactly once');
    });
  });
}
