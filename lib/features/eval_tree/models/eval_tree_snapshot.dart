import 'dart:collection';

enum EvalTreePruneKind {
  none,
  evalTooHigh,
  evalTooLow,
}

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
  })  : startMovesSan = List.unmodifiable(startMovesSan),
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

  List<EvalTreeNodeSnapshot> childrenOf(int id) {
    final node = this.node(id);
    return [
      for (final childId in node.childIds)
        if (nodesById.containsKey(childId)) nodesById[childId]!,
    ];
  }

  EvalTreeNodeSnapshot? parentOf(int id) {
    final parentId = node(id).parentId;
    if (parentId == null) return null;
    return nodesById[parentId];
  }

  List<int> pathToRootIds(int id) {
    final path = <int>[];
    EvalTreeNodeSnapshot? current = tryNode(id);
    while (current != null) {
      path.insert(0, current.id);
      current = current.parentId == null ? null : nodesById[current.parentId];
    }
    return path;
  }

  List<String> movePathSan(int id) {
    final path = <String>[];
    for (final nodeId in pathToRootIds(id)) {
      final current = node(nodeId);
      if (current.moveSan.isNotEmpty) {
        path.add(current.moveSan);
      }
    }
    return path;
  }

  List<String> fullMovePathSan(int id) =>
      [...startMovesSan, ...movePathSan(id)];

  int? preferredChildId(int id) {
    final node = this.node(id);
    if (node.childIds.isEmpty) return null;
    return node.childIds.first;
  }
}
