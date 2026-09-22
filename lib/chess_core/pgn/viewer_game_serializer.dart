/// Conversion from the viewer's game state back to dartchess PGN trees.
///
/// [ViewerGameController] holds a flat mainline plus a [SidelineForest]; the file
/// wants one tree where index 0 of every `children` list is the mainline
/// continuation and later indices are the alternatives. These functions do
/// that inversion of `extractPgnVariations`, dropping ephemeral (scratch)
/// nodes on the way, and build the single-line PGNs the copy/export actions
/// hand out.
library;

import 'package:dartchess/dartchess.dart';

import '../moves/move_tree_view.dart';
import 'pgn_game_copy.dart';
import 'pgn_analysis_variations.dart';
import '../moves/sideline_tree.dart';

/// Rebuild a dartchess move tree from [moveHistory] plus [sidelines]:
/// sidelines keyed at ply `p` become siblings of the mainline move at index
/// `p`. Ephemeral nodes are excluded. Stored engine-line references are
/// re-synchronised against the tree that results.
PgnNode<PgnNodeData> buildViewerPgnTree({
  required List<PgnNodeData> moveHistory,
  required SidelineForest sidelines,
}) {
  final root = PgnNode<PgnNodeData>();
  var parent = root;

  void addSidelines(int ply) {
    for (final sideline in sidelines[ply] ?? const <MoveNodeView>[]) {
      if (sideline.isEphemeral) continue;
      parent.children.add(_pgnChildFor(sideline));
    }
  }

  for (var i = 0; i < moveHistory.length; i++) {
    final mainChild = PgnChildNode<PgnNodeData>(
      copyPgnMoveData(moveHistory[i]),
    );
    parent.children.add(mainChild); // index 0 = mainline continuation
    addSidelines(i); // alternatives to moveHistory[i], sharing `parent`
    parent = mainChild;
  }
  // Sidelines branching after the final mainline move (user-added only).
  addSidelines(moveHistory.length);
  synchronizeAnalysisVariationPaths(root);
  return root;
}

PgnChildNode<PgnNodeData> _pgnChildFor(MoveNodeView node) {
  final root = PgnChildNode<PgnNodeData>(pgnNodeDataFor(node));
  final pending = [(node, root)];
  while (pending.isNotEmpty) {
    final (source, target) = pending.removeLast();
    for (final child in source.children) {
      if (child.isEphemeral) continue;
      final copied = PgnChildNode<PgnNodeData>(pgnNodeDataFor(child));
      target.children.add(copied);
      pending.add((child, copied));
    }
  }
  return root;
}

/// The move data a sideline [node] serialises as: its SAN plus a trimmed
/// comment and a copy of its NAGs, each omitted when empty.
PgnNodeData pgnNodeDataFor(MoveNodeView node) {
  final comment = node.comment?.trim();
  final nags = node.nags;
  return PgnNodeData(
    san: node.san,
    comments: comment == null || comment.isEmpty ? null : [comment],
    nags: nags == null || nags.isEmpty ? null : List<int>.of(nags),
    startingComments: node.startingComment == null
        ? null
        : [node.startingComment!],
  );
}

/// Serialize a single [line] to PGN: `[FEN]`/`[SetUp]` headers when the game
/// starts from [setupFen], then numbered movetext (comments and NAGs of the
/// source moves included).
String buildLinePgn(List<PgnNodeData> line, {String? setupFen}) {
  final headers = <String, String>{
    if (setupFen != null && setupFen.isNotEmpty) ...{
      'FEN': setupFen,
      'SetUp': '1',
    },
  };
  final root = PgnNode<PgnNodeData>();
  var parent = root;
  for (final data in line) {
    final child = PgnChildNode<PgnNodeData>(data);
    parent.children.add(child);
    parent = child;
  }
  return PgnGame<PgnNodeData>(
    headers: headers,
    moves: root,
    comments: const [],
  ).makePgn().trim();
}
