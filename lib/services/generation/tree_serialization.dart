/// JSON serialization / deserialization for [BuildTree].
///
/// Wire format matches the C tree builder's v4 JSON format so that
/// trees are interchangeable between the Dart and C implementations.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/build_tree_node.dart';
import 'fen_map.dart';

// ── Serialization ────────────────────────────────────────────────────────

/// Encode a [BuildTree] as a JSON string matching the C v4 format.
String serializeTree(BuildTree tree) {
  final root = <String, dynamic>{
    'format': 'opening_tree',
    'version': 4,
    'total_nodes': tree.totalNodes,
    'max_depth': tree.maxDepthReached,
    'build_complete': tree.buildComplete,
    'config': tree.configSnapshot,
    if (tree.startMoves.isNotEmpty) 'start_moves': tree.startMoves,
    'tree': _nodeToJson(tree.root),
  };
  return const JsonEncoder.withIndent('  ').convert(root);
}

Map<String, dynamic> _nodeToJson(BuildTreeNode node) {
  final obj = <String, dynamic>{
    'id': node.nodeId,
    'depth': node.depth,
  };

  if (node.moveSan.isNotEmpty) obj['move_san'] = node.moveSan;
  if (node.moveUci.isNotEmpty) obj['move_uci'] = node.moveUci;

  obj['move_probability'] = node.moveProbability;
  obj['cumulative_probability'] = node.cumulativeProbability;

  if (node.fen.isNotEmpty) obj['fen'] = node.fen;

  if (node.hasEngineEval) {
    obj['engine_eval_cp'] = node.engineEvalCp!;
  }

  if (node.ease != null) {
    obj['ease'] = node.ease;
  }

  if (node.hasExpectimax) {
    obj['local_cpl'] = node.localCpl;
    obj['expectimax_value'] = node.expectimaxValue;
    obj['subtree_depth'] = node.subtreeDepth;
    obj['subtree_opp_plies'] = node.subtreeOppPlies;
  }

  if (node.trapScore >= 0.0) {
    obj['trap_score'] = node.trapScore;
  }

  if (node.maiaFrequency >= 0.0) {
    obj['maia_frequency'] = node.maiaFrequency;
  }

  if (node.totalGames > 0) {
    obj['white_wins'] = node.whiteWins;
    obj['black_wins'] = node.blackWins;
    obj['draws'] = node.draws;
    obj['total_games'] = node.totalGames;
  }

  obj['is_white_to_move'] = node.isWhiteToMove;

  if (node.explored) obj['explored'] = true;

  if (node.pruneReason != PruneReason.none) {
    obj['prune_reason'] = node.pruneReason == PruneReason.evalTooHigh
        ? 'eval_too_high'
        : 'eval_too_low';
    if (node.pruneEvalCp != null) obj['prune_eval_cp'] = node.pruneEvalCp;
  }

  if (node.isRepertoireMove) obj['is_repertoire_move'] = true;
  if (node.repertoireScore != 0.0)
    obj['repertoire_score'] = node.repertoireScore;

  if (node.children.isNotEmpty) {
    obj['children'] = node.children.map(_nodeToJson).toList();
  }

  return obj;
}

// ── Deserialization ──────────────────────────────────────────────────────

/// Decode a JSON string into a [BuildTree].
///
/// Optionally populates a [fenMap] with canonical nodes for transposition
/// resolution in post-build phases.
BuildTree deserializeTree(String jsonStr, {FenMap? fenMap}) {
  final sw = Stopwatch()..start();
  final data = jsonDecode(jsonStr) as Map<String, dynamic>;
  final jsonParseMs = sw.elapsedMilliseconds;
  final version = (data['version'] as num?)?.toInt() ?? 3;

  final configData = data['config'] as Map<String, dynamic>? ?? const {};
  final treeData = data['tree'] as Map<String, dynamic>;

  sw.reset();
  final idToNode = <int, BuildTreeNode>{};
  final root = _nodeFromJson(treeData, null, idToNode);
  final nodeBuiltMs = sw.elapsedMilliseconds;

  if (fenMap != null) {
    fenMap.populate(root);
  }

  final totalNodes =
      (data['total_nodes'] as num?)?.toInt() ?? root.countSubtree();

  final tree = BuildTree(
    root: root,
    totalNodes: totalNodes,
    maxDepthReached: (data['max_depth'] as num?)?.toInt() ?? 0,
    buildComplete: data['build_complete'] as bool? ?? true,
    startMoves: data['start_moves'] as String? ?? '',
    configSnapshot: configData,
  );

  // Populate the flat index from the map we already built during parsing,
  // then compute subtreeSize and sort children in a single pass.
  sw.reset();
  tree.nodeIndex.addAll(idToNode);
  tree.computeMetadata();
  tree.sortAllChildren();
  final metadataMs = sw.elapsedMilliseconds;

  debugPrint('[deserializeTree] jsonParse=${jsonParseMs}ms, '
      'nodeBuild=${nodeBuiltMs}ms, '
      'metadata+sort=${metadataMs}ms, '
      'version=$version, '
      'nodeIndex=${tree.nodeIndex.length} entries, '
      'totalNodes=$totalNodes');

  return tree;
}

BuildTreeNode _nodeFromJson(
  Map<String, dynamic> obj,
  BuildTreeNode? parent,
  Map<int, BuildTreeNode> idToNode,
) {
  final nodeId = (obj['id'] as num?)?.toInt() ?? 0;
  final fen = obj['fen'] as String? ?? '';
  final isWhiteToMove = obj['is_white_to_move'] as bool? ??
      (fen.isNotEmpty ? fen.split(' ')[1] == 'w' : true);

  final node = BuildTreeNode(
    fen: fen,
    moveSan: obj['move_san'] as String? ?? '',
    moveUci: obj['move_uci'] as String? ?? '',
    depth: (obj['depth'] as num?)?.toInt() ??
        (parent != null ? parent.depth + 1 : 0),
    isWhiteToMove: isWhiteToMove,
    nodeId: nodeId,
    parent: parent,
    moveProbability: (obj['move_probability'] as num?)?.toDouble() ?? 1.0,
    cumulativeProbability:
        (obj['cumulative_probability'] as num?)?.toDouble() ?? 1.0,
  );

  if (obj.containsKey('engine_eval_cp')) {
    node.engineEvalCp = (obj['engine_eval_cp'] as num).toInt();
  }

  if (obj.containsKey('ease')) {
    node.ease = (obj['ease'] as num).toDouble();
  }

  if (obj.containsKey('local_cpl') && obj.containsKey('expectimax_value')) {
    node.localCpl = (obj['local_cpl'] as num).toDouble();
    node.expectimaxValue = (obj['expectimax_value'] as num).toDouble();
    node.hasExpectimax = true;
  } else if (obj.containsKey('local_cpl') &&
      obj.containsKey('accumulated_eca')) {
    node.localCpl = (obj['local_cpl'] as num).toDouble();
  }

  if (obj.containsKey('subtree_depth')) {
    node.subtreeDepth = (obj['subtree_depth'] as num).toInt();
  }
  if (obj.containsKey('subtree_opp_plies')) {
    node.subtreeOppPlies = (obj['subtree_opp_plies'] as num).toInt();
  }

  if (obj.containsKey('trap_score')) {
    node.trapScore = (obj['trap_score'] as num).toDouble();
  }

  if (obj.containsKey('maia_frequency')) {
    node.maiaFrequency = (obj['maia_frequency'] as num).toDouble();
  }

  if (obj.containsKey('white_wins') &&
      obj.containsKey('black_wins') &&
      obj.containsKey('draws')) {
    node.setLichessStats(
      (obj['white_wins'] as num).toInt(),
      (obj['black_wins'] as num).toInt(),
      (obj['draws'] as num).toInt(),
    );
  }

  node.explored = obj['explored'] as bool? ?? false;

  if (obj.containsKey('prune_reason')) {
    final reason = obj['prune_reason'] as String;
    node.pruneReason = reason == 'eval_too_high'
        ? PruneReason.evalTooHigh
        : PruneReason.evalTooLow;
    if (obj.containsKey('prune_eval_cp')) {
      node.pruneEvalCp = (obj['prune_eval_cp'] as num).toInt();
    }
  }

  node.isRepertoireMove = obj['is_repertoire_move'] as bool? ?? false;
  if (obj.containsKey('repertoire_score')) {
    node.repertoireScore = (obj['repertoire_score'] as num).toDouble();
  } else if (node.isRepertoireMove && node.hasExpectimax) {
    // v3 trees did not persist repertoire_score; fall back to the selected V.
    node.repertoireScore = node.expectimaxValue;
  }

  idToNode[nodeId] = node;

  final children = obj['children'] as List<dynamic>?;
  if (children != null) {
    for (final childData in children) {
      final child = _nodeFromJson(
        childData as Map<String, dynamic>,
        node,
        idToNode,
      );
      node.children.add(child);
    }
    if (!node.explored && node.children.isNotEmpty) {
      node.explored = true;
    }
  }

  return node;
}
