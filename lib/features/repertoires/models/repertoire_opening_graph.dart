import 'dart:collection';

import '../../../chess_core/moves/opening_graph.dart';
import '../../../models/opening_tree.dart';

/// Query projection over the session's private graph. Neither node references
/// nor nested collections grant mutation or cursor control to a consumer.
/// Queries track this graph's current state; a load creates a new projection.
class RepertoireOpeningGraph implements OpeningGraph {
  RepertoireOpeningGraph(this._tree);
  final OpeningTree _tree;
  final _nodes = <OpeningTreeNode, _NodeView>{};
  _NodeView _node(OpeningTreeNode node) =>
      _nodes.putIfAbsent(node, () => _NodeView(node, this));
  OpeningPositionView _group(PositionGroup group) => _PositionView(group, this);
  @override
  OpeningNodeView get root => _node(_tree.root);
  @override
  OpeningNodeView get currentNode => _node(_tree.currentNode);
  @override
  OpeningNodeView get cursorRoot => _node(_tree.cursorRoot);
  @override
  late final Map<String, List<OpeningNodeView>> fenToNodes = _NodeIndex(
    _tree.fenToNodes,
    _node,
  );
  @override
  List<OpeningNodeView> get setupRoots =>
      List.unmodifiable(_tree.setupRoots.map(_node));
  @override
  String get currentFen => _tree.currentFen;
  @override
  bool get inBook => _tree.inBook;
  @override
  List<String> get currentMovePath => List.unmodifiable(_tree.currentMovePath);
  @override
  String get currentMovePathString => _tree.currentMovePathString;
  @override
  bool get canGoBack => _tree.canGoBack;
  @override
  int get currentDepth => _tree.currentDepth;
  @override
  int get totalGames => _tree.totalGames;
  @override
  OpeningPositionView get currentGroup => _group(_tree.currentGroup);
  @override
  List<OpeningPositionView> get continuations => continuationsAt(currentFen);
  @override
  List<OpeningPositionView> continuationsAt(String fen) =>
      List.unmodifiable(_tree.continuationsAt(fen).map(_group));
  @override
  bool hasMove(String fen, String san) => _tree.hasMove(fen, san);
  @override
  bool hasMoveOnPath(List<String> path, String san) =>
      _tree.hasMoveOnPath(path, san);
  @override
  bool doesMoveTranspose(String fen, String san) =>
      _tree.doesMoveTranspose(fen, san);
  @override
  OpeningNodeView? nodeAtPath(List<String> sans) {
    final node = _tree.nodeAtPath(sans);
    return node == null ? null : _node(node);
  }
}

class _NodeIndex extends MapBase<String, List<OpeningNodeView>> {
  _NodeIndex(this._source, this._wrap);
  final Map<String, List<OpeningTreeNode>> _source;
  final OpeningNodeView Function(OpeningTreeNode) _wrap;
  @override
  List<OpeningNodeView>? operator [](Object? key) {
    final nodes = _source[key];
    return nodes == null ? null : List.unmodifiable(nodes.map(_wrap));
  }

  @override
  Iterable<String> get keys => _source.keys;
  @override
  void operator []=(String key, List<OpeningNodeView> value) =>
      throw UnsupportedError('Read-only graph');
  @override
  void clear() => throw UnsupportedError('Read-only graph');
  @override
  List<OpeningNodeView>? remove(Object? key) =>
      throw UnsupportedError('Read-only graph');
}

class _NodeView implements OpeningNodeView {
  _NodeView(this._node, this._graph);
  final OpeningTreeNode _node;
  final RepertoireOpeningGraph _graph;
  @override
  String get move => _node.move;
  @override
  String get fen => _node.fen;
  @override
  int get gamesPlayed => _node.gamesPlayed;
  @override
  int get wins => _node.wins;
  @override
  int get losses => _node.losses;
  @override
  int get draws => _node.draws;
  @override
  Map<String, OpeningNodeView> get children => Map.unmodifiable({
    for (final entry in _node.children.entries)
      entry.key: _graph._node(entry.value),
  });
  @override
  OpeningNodeView? get parent =>
      _node.parent == null ? null : _graph._node(_node.parent!);
  @override
  List<OpeningNodeView> get sortedChildren =>
      List.unmodifiable(_node.sortedChildren.map(_graph._node));
  @override
  double get winRate => _node.winRate;
  @override
  double get winRatePercent => _node.winRatePercent;
  @override
  bool get hasWdl => _node.hasWdl;
  @override
  bool get moverWasWhite => _node.moverWasWhite;
  @override
  ReachEstimate reachEstimate({required bool protagonistIsWhite}) =>
      _node.reachEstimate(protagonistIsWhite: protagonistIsWhite);
  @override
  List<String> getMovePath() => List.unmodifiable(_node.getMovePath());
  @override
  String getMovePathString() => _node.getMovePathString();
  @override
  int countDescendants({required int maxPly}) =>
      _node.countDescendants(maxPly: maxPly);
}

class _PositionView implements OpeningPositionView {
  _PositionView(this._group, this._graph);
  final PositionGroup _group;
  final RepertoireOpeningGraph _graph;
  @override
  List<OpeningNodeView> get nodes =>
      List.unmodifiable(_group.nodes.map(_graph._node));
  @override
  OpeningNodeView get primaryNode => _graph._node(_group.primaryNode);
  @override
  String get fen => _group.fen;
  @override
  String get move => _group.move;
  @override
  bool get viaTransposition => _group.viaTransposition;
  @override
  int get gamesPlayed => _group.gamesPlayed;
  @override
  int get wins => _group.wins;
  @override
  int get losses => _group.losses;
  @override
  int get draws => _group.draws;
  @override
  bool get hasWdl => _group.hasWdl;
  @override
  double get winRate => _group.winRate;
  @override
  double get winRatePercent => _group.winRatePercent;
  @override
  List<OpeningPositionView> get children =>
      List.unmodifiable(_group.children.map(_graph._group));
  @override
  ReachEstimate reachEstimate({required bool protagonistIsWhite}) =>
      _group.reachEstimate(protagonistIsWhite: protagonistIsWhite);
}
