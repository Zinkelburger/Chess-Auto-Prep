/// An immutable, flat view of a built tree for the eval-tree viewer: every
/// node by id with its parent and children ids, so the layout engine and the
/// explorer look nodes up in O(1) and never walk the whole tree per frame.
library;

import 'dart:collection';

enum EvalTreePruneKind { none, evalTooHigh, evalTooLow }

class EvalTreeNodeSnapshot {
  final int id;
  final int? parentId;
  final List<int> childIds;
  final String fen;
  final String moveSan;
  final String moveUci;
  final bool sideToMoveIsWhite;
  final int? evalForUsCp;
  final double moveProbability;
  final double cumulativeProbability;
  final bool isRepertoireMove;
  final double repertoireScore;
  final double? ease;
  final double? expectimaxValue;
  final double? localCpl;
  final double? trapScore;
  final double? myEase;
  final int subtreeSize;
  final int subtreePly;
  final EvalTreePruneKind pruneKind;
  final int? pruneEvalCp;
  final int totalGames;

  const EvalTreeNodeSnapshot({
    required this.id,
    required this.parentId,
    required this.childIds,
    required this.fen,
    required this.moveSan,
    required this.moveUci,
    required this.sideToMoveIsWhite,
    required this.evalForUsCp,
    required this.moveProbability,
    required this.cumulativeProbability,
    required this.isRepertoireMove,
    required this.repertoireScore,
    required this.ease,
    required this.expectimaxValue,
    required this.localCpl,
    required this.trapScore,
    required this.myEase,
    required this.subtreeSize,
    required this.subtreePly,
    required this.pruneKind,
    required this.pruneEvalCp,
    required this.totalGames,
  });

  bool get hasEngineEval => evalForUsCp != null;

  String get displayLabel => moveSan.isEmpty ? 'Start' : moveSan;
}

class EvalTreeSnapshot {
  final int rootNodeId;
  final bool playAsWhite;
  final List<String> startMovesSan;
  final Map<String, dynamic> configSnapshot;
  final UnmodifiableMapView<int, EvalTreeNodeSnapshot> nodesById;

  EvalTreeSnapshot({
    required this.rootNodeId,
    required this.playAsWhite,
    required List<String> startMovesSan,
    required Map<String, dynamic> configSnapshot,
    required Map<int, EvalTreeNodeSnapshot> nodesById,
  }) : startMovesSan = List.unmodifiable(startMovesSan),
       configSnapshot = Map.unmodifiable(configSnapshot),
       nodesById = UnmodifiableMapView(Map.unmodifiable(nodesById));

  int get nodeCount => nodesById.length;

  EvalTreeNodeSnapshot get root => node(rootNodeId);

  EvalTreeNodeSnapshot node(int id) {
    final node = nodesById[id];
    if (node == null) {
      throw StateError('EvalTreeSnapshot is missing node $id');
    }
    return node;
  }

  EvalTreeNodeSnapshot? tryNode(int id) => nodesById[id];

  bool containsNode(int id) => nodesById.containsKey(id);

  List<EvalTreeNodeSnapshot> childrenOf(int id) => [
    for (final childId in node(id).childIds) ?nodesById[childId],
  ];

  EvalTreeNodeSnapshot? parentOf(int id) {
    final parentId = node(id).parentId;
    return parentId == null ? null : nodesById[parentId];
  }

  /// Whether it is our side to move in the position at [id].
  bool isOurTurnAt(int id) => node(id).sideToMoveIsWhite == playAsWhite;

  /// Whether the move that reached [id] was ours (false at the root).
  bool isOurMove(int id) {
    final parent = parentOf(id);
    return parent != null && parent.sideToMoveIsWhite == playAsWhite;
  }

  /// Node ids from the root down to [id] (empty when [id] is unknown).
  List<int> pathToRootIds(int id) {
    final path = <int>[];
    for (var current = tryNode(id); current != null;) {
      path.add(current.id);
      final parentId = current.parentId;
      current = parentId == null ? null : nodesById[parentId];
    }
    return path.reversed.toList();
  }

  List<String> movePathSan(int id) => [
    for (final nodeId in pathToRootIds(id))
      if (node(nodeId).moveSan case final san when san.isNotEmpty) san,
  ];

  List<String> fullMovePathSan(int id) => [
    ...startMovesSan,
    ...movePathSan(id),
  ];

  /// The child to step into by default: children are pre-sorted with the
  /// repertoire move first, then by probability.
  int? preferredChildId(int id) => node(id).childIds.firstOrNull;
}
