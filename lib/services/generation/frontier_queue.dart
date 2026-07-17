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
///
/// The queue is an *indexed* heap: it tracks which node ids are currently
/// enqueued and each one's heap slot.  That keeps [add] idempotent (a node
/// already in the frontier is never inserted twice) and lets a node whose
/// [BuildTreeNode.searchPriority] was rescaled while queued — the
/// transposition reach-probability bump in [propagateHigherCumP] — be
/// re-sifted in place.  Without this, that rescale-then-`add` path used to
/// leave a stale heap slot *and* a duplicate entry, and the duplicate's second
/// pop re-enqueued the node's whole child set (the resume branch), leaking
/// budget into the very alternatives Fast pruning meant to suppress.
library;

import 'dart:collection' show Queue;

import '../../models/build_tree_node.dart';

/// Priority used for frontier ordering.  Nodes from legacy trees (or created
/// before priorities existed) carry `searchPriority == -1`; fall back to the
/// reach probability, which is what the priority degenerates to when no
/// our-move alternative discount applies.
double effectiveSearchPriority(BuildTreeNode node) => node.searchPriority >= 0.0
    ? node.searchPriority
    : node.cumulativeProbability;

class FrontierQueue {
  final bool bestFirst;

  final Queue<BuildTreeNode> _fifo = Queue<BuildTreeNode>();
  final List<BuildTreeNode> _heap = [];

  /// Node ids currently in the frontier — backs an O(1) [contains] and keeps
  /// [add] idempotent in both modes.
  final Set<int> _queued = <int>{};

  /// Heap slot of each queued node id (best-first only), so a node whose key
  /// changed while queued can be re-sifted from its known position.
  final Map<int, int> _heapIndex = <int, int>{};

  FrontierQueue({required this.bestFirst});

  bool get isNotEmpty => bestFirst ? _heap.isNotEmpty : _fifo.isNotEmpty;
  bool get isEmpty => !isNotEmpty;
  int get length => bestFirst ? _heap.length : _fifo.length;

  /// Next node to be popped (heap max / FIFO head).
  BuildTreeNode get first => bestFirst ? _heap.first : _fifo.first;

  bool contains(BuildTreeNode node) => _queued.contains(node.nodeId);

  /// Enqueue [node] if absent.  If it is already queued (best-first), its
  /// [BuildTreeNode.searchPriority] may have changed in place since insertion
  /// (transposition rescale), so restore its heap order rather than inserting
  /// a duplicate.
  void add(BuildTreeNode node) {
    if (!bestFirst) {
      if (_queued.add(node.nodeId)) _fifo.add(node);
      return;
    }
    final pos = _heapIndex[node.nodeId];
    if (pos != null) {
      _resift(pos);
      return;
    }
    _queued.add(node.nodeId);
    _heap.add(node);
    _heapIndex[node.nodeId] = _heap.length - 1;
    _siftUp(_heap.length - 1);
  }

  void addAll(Iterable<BuildTreeNode> nodes) {
    for (final node in nodes) {
      add(node);
    }
  }

  BuildTreeNode removeFirst() {
    if (!bestFirst) {
      final node = _fifo.removeFirst();
      _queued.remove(node.nodeId);
      return node;
    }
    final top = _heap.first;
    _queued.remove(top.nodeId);
    _heapIndex.remove(top.nodeId);
    final last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      _heap[0] = last;
      _heapIndex[last.nodeId] = 0;
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

  void _swap(int i, int j) {
    final a = _heap[i];
    final b = _heap[j];
    _heap[i] = b;
    _heap[j] = a;
    _heapIndex[b.nodeId] = i;
    _heapIndex[a.nodeId] = j;
  }

  void _siftUp(int i) {
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (!_before(_heap[i], _heap[parent])) break;
      _swap(i, parent);
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
      _swap(i, best);
      i = best;
    }
  }

  /// Restore the heap property for the node at [i] after its key changed in
  /// place; it may need to move either up (key raised) or down.
  void _resift(int i) {
    if (i > 0 && _before(_heap[i], _heap[(i - 1) >> 1])) {
      _siftUp(i);
    } else {
      _siftDown(i);
    }
  }
}
