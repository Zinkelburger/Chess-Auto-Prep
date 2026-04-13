/// Transposition table for the tree build phase.
///
/// Maps FEN strings to canonical [BuildTreeNode] instances and tracks
/// transposition leaves.  Replaces the C code's hand-rolled hash table
/// and circular equivalence ring with Dart's standard [HashMap].
library;

import '../../models/build_tree_node.dart';

class FenMap {
  final Map<String, BuildTreeNode> _canonical = {};
  final Map<String, List<BuildTreeNode>> _equivalents = {};

  /// Look up the canonical (first-expanded) node for a FEN.
  BuildTreeNode? getCanonical(String fen) => _canonical[fen];

  bool contains(String fen) => _canonical.containsKey(fen);

  /// Register a node as the canonical expansion for its FEN.
  /// No-op if the FEN is already registered.
  void putCanonical(String fen, BuildTreeNode node) {
    _canonical.putIfAbsent(fen, () => node);
  }

  /// Register a transposition leaf — a node that reached an already-expanded
  /// FEN via a different move order.
  void addTransposition(String fen, BuildTreeNode node) {
    (_equivalents[fen] ??= []).add(node);
  }

  /// Get all transposition leaves for a FEN (excludes the canonical node).
  List<BuildTreeNode> getTranspositions(String fen) =>
      _equivalents[fen] ?? const [];

  /// Get the canonical node plus all transposition leaves for a FEN.
  List<BuildTreeNode> getAllEquivalents(String fen) {
    final canonical = _canonical[fen];
    final transpositions = _equivalents[fen] ?? const <BuildTreeNode>[];
    if (canonical == null) return transpositions;
    return [canonical, ...transpositions];
  }

  int get size => _canonical.length;

  /// Walk a tree and register all nodes.  Canonical nodes are the first
  /// expansion of each FEN; childless duplicates become transposition leaves.
  void populate(BuildTreeNode node) {
    if (node.fen.isNotEmpty) {
      if (!contains(node.fen)) {
        putCanonical(node.fen, node);
      } else if (node.children.isEmpty) {
        addTransposition(node.fen, node);
      }
    }
    for (final child in node.children) {
      populate(child);
    }
  }

  void clear() {
    _canonical.clear();
    _equivalents.clear();
  }
}
