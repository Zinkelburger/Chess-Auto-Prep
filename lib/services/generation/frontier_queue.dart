/// Build frontier for the tree builder — FIFO (classic BFS) or best-first.
///
/// Best-first mode is a binary max-heap keyed on [BuildTreeNode.searchPriority]
/// (reach probability × our-alternative discount).  Popping always returns the
/// frontier node whose subtree matters most to the final repertoire, which
/// turns the build into an anytime algorithm: at any node budget the tree is
/// concentrated on the lines opponents actually play.
///
/// Ties break toward the shallower node, then the lower node id, so expansion
/// order is deterministic for a given tree state.
library;

import 'dart:collection' show Queue;

import '../../models/build_tree_node.dart';

/// Priority used for frontier ordering.  Nodes from legacy trees (or created
/// before priorities existed) carry `searchPriority == -1`; fall back to the
/// reach probability, which is what the priority degenerates to when no
/// our-move alternative discount applies.
double effectiveSearchPriority(BuildTreeNode node) =>
    node.searchPriority >= 0.0
        ? node.searchPriority
        : node.cumulativeProbability;

class FrontierQueue {
  final bool bestFirst;

  final Queue<BuildTreeNode> _fifo = Queue<BuildTreeNode>();
  final List<BuildTreeNode> _heap = [];

  FrontierQueue({required this.bestFirst});

  bool get isNotEmpty => bestFirst ? _heap.isNotEmpty : _fifo.isNotEmpty;
  bool get isEmpty => !isNotEmpty;
  int get length => bestFirst ? _heap.length : _fifo.length;

  /// Next node to be popped (heap max / FIFO head).
  BuildTreeNode get first => bestFirst ? _heap.first : _fifo.first;

  bool contains(BuildTreeNode node) =>
      bestFirst ? _heap.contains(node) : _fifo.contains(node);

  void add(BuildTreeNode node) {
    if (!bestFirst) {
      _fifo.add(node);
      return;
    }
    _heap.add(node);
    _siftUp(_heap.length - 1);
  }

  void addAll(Iterable<BuildTreeNode> nodes) {
    for (final node in nodes) {
      add(node);
    }
  }

  BuildTreeNode removeFirst() {
    if (!bestFirst) return _fifo.removeFirst();
    final top = _heap.first;
    final last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      _heap[0] = last;
      _siftDown(0);
    }
    return top;
  }

  /// True when [a] should be popped before [b].
  static bool _before(BuildTreeNode a, BuildTreeNode b) {
    final pa = effectiveSearchPriority(a);
    final pb = effectiveSearchPriority(b);
    if (pa != pb) return pa > pb;
    if (a.ply != b.ply) return a.ply < b.ply;
    return a.nodeId < b.nodeId;
  }

  void _siftUp(int i) {
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (!_before(_heap[i], _heap[parent])) break;
      final tmp = _heap[i];
      _heap[i] = _heap[parent];
      _heap[parent] = tmp;
      i = parent;
    }
  }

  void _siftDown(int i) {
    final n = _heap.length;
    for (;;) {
      final left = 2 * i + 1;
      final right = left + 1;
      var best = i;
      if (left < n && _before(_heap[left], _heap[best])) best = left;
      if (right < n && _before(_heap[right], _heap[best])) best = right;
      if (best == i) return;
      final tmp = _heap[i];
      _heap[i] = _heap[best];
      _heap[best] = tmp;
      i = best;
    }
  }
}
