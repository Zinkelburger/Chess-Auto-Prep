import 'dart:convert';

import 'package:chess_auto_prep/chess_core/generation/expectimax_probe_codec.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/chess_core/generation/trap_line_info.dart';
import 'package:chess_auto_prep/chess_core/generation/tree_serialization.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';

BuildTree legacyRecoveryTree({bool complete = true}) {
  final root = BuildTreeNode(
    fen: kStandardStartFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: 0,
  )..engineEvalCp = 35;
  root.children.add(
    BuildTreeNode(
      fen: playUciMove(kStandardStartFen, 'e2e4')!,
      moveSan: 'e4',
      moveUci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
      nodeId: 1,
      parent: root,
    )..engineEvalCp = -32,
  );
  return BuildTree(
    root: root,
    totalNodes: 2,
    maxPlyReached: 1,
    buildComplete: complete,
    configSnapshot: {'play_as_white': true, 'max_depth': 9},
  );
}

Map<GenerationArtifactKind, String> legacyRecoveryPayloads() => {
  GenerationArtifactKind.tree: serializeTree(legacyRecoveryTree()),
  GenerationArtifactKind.probes: ExpectimaxProbeCodec.encode([
    legacyRecoveryTree(),
  ]),
  GenerationArtifactKind.partial: serializeTree(
    legacyRecoveryTree(complete: false),
  ),
  GenerationArtifactKind.traps: jsonEncode({
    'traps': [
      const TrapLineInfo(
        movesSan: ['e4', 'e5'],
        trapScore: .3,
        popularProb: .2,
        popularMove: 'f6',
        bestMove: 'Nc6',
        popularEvalCp: 180,
        bestEvalCp: 30,
        evalDiffCp: 150,
        cumulativeProb: .4,
        trickSurplus: .2,
        expectimaxValue: .6,
        wpEval: .4,
      ).toJson(),
    ],
  }),
};
