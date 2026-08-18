/// Transposition table for the tree build phase.
///
/// Maps canonical 4-field FEN keys to [BuildTreeNode] instances and tracks
/// transposition leaves.  Replaces the C code's hand-rolled hash table
/// and circular equivalence ring with Dart's standard [HashMap].
library;

import '../../models/build_tree_node.dart';
import '../eval/eval_canonicalize.dart';

/// Strip halfmove/fullmove counters; keep piece placement, side to move,
/// castling rights, and en passant square (matches C `fen_map_canonicalize_key`).
String canonicalizeFen(String fen) => canonicalizeFen4(fen);

class FenMap {
  final Map<String, BuildTreeNode> _canonical = {};
  final Map<String, List<BuildTreeNode>> _equivalents = {};
  bool _frozen = false;

  String _key(String fen) => canonicalizeFen(fen);

  void _assertMutable() {
    if (_frozen) {
      throw StateError(
        'FenMap is frozen — GeneratedRepertoire treats it as immutable',
      );
    }
  }

  /// Prevent further mutation. Called once the generated bundle is published
  /// so views cannot desync the transposition table.
  void freeze() => _frozen = true;

  bool get isFrozen => _frozen;

  /// Look up the canonical (first-expanded) node for a FEN.
  BuildTreeNode? getCanonical(String fen) => _canonical[_key(fen)];

  bool contains(String fen) => _canonical.containsKey(_key(fen));

  /// Register a node as the canonical expansion for its FEN.
  /// No-op if the FEN is already registered.
  void putCanonical(String fen, BuildTreeNode node) {
    _assertMutable();
    _canonical.putIfAbsent(_key(fen), () => node);
  }

  /// Register a transposition leaf — a node that reached an already-expanded
  /// FEN via a different move order.  Idempotent: re-registering the same
  /// node (e.g. [populate] running again over a partially built tree) does
  /// not grow the equivalence list.
  void addTransposition(String fen, BuildTreeNode node) {
    _assertMutable();
    final list = _equivalents[_key(fen)] ??= [];
    for (final existing in list) {
      if (identical(existing, node)) return;
    }
    list.add(node);
  }

  /// Get all transposition leaves for a FEN (excludes the canonical node).
  List<BuildTreeNode> getTranspositions(String fen) =>
      _equivalents[_key(fen)] ?? const [];

  /// Get the canonical node plus all transposition leaves for a FEN.
  List<BuildTreeNode> getAllEquivalents(String fen) {
    final key = _key(fen);
    final canonical = _canonical[key];
    final transpositions = _equivalents[key] ?? const <BuildTreeNode>[];
    if (canonical == null) return transpositions;
    return [canonical, ...transpositions];
  }

  int get size => _canonical.length;

  /// Walk a tree and register all nodes.  Canonical nodes are the first
  /// expansion of each FEN; childless duplicates become transposition
  /// leaves.  Idempotent: safe to call repeatedly on a growing tree (the
  /// on-the-fly service re-populates during progressive deepening).
  void populate(BuildTreeNode node) {
    _assertMutable();
    if (node.fen.isNotEmpty) {
      final canonical = getCanonical(node.fen);
      if (canonical == null) {
        putCanonical(node.fen, node);
      } else if (!identical(canonical, node) && node.children.isEmpty) {
        addTransposition(node.fen, node);
      }
    }
    for (final child in node.children) {
      populate(child);
    }
  }

  void clear() {
    _assertMutable();
    _canonical.clear();
    _equivalents.clear();
  }
}

/// Follow a transposition link if [node] is a childless leaf whose FEN
/// has a canonical expansion with children elsewhere in the tree.
BuildTreeNode resolveTransposition(BuildTreeNode node, FenMap? fenMap) {
  if (node.children.isNotEmpty || fenMap == null) return node;
  final canonical = fenMap.getCanonical(node.fen);
  if (canonical != null && canonical != node && canonical.children.isNotEmpty) {
    return canonical;
  }
  return node;
}

/// Path-scoped cycle: following a transposition leaf onto a FEN already on
/// [visited] would recurse forever. Selector and line extractor share this
/// check — do not invent a third.
bool isTranspositionCycle(
  BuildTreeNode node,
  BuildTreeNode resolved,
  Set<String> visited,
) {
  if (identical(resolved, node)) return false;
  return visited.contains(canonicalizeFen4(resolved.fen));
}

/// Record [resolved] on the current path. Pair with [leaveFenPath] after
/// the recursive work (path-scoped walks). The verifier uses
/// [enterPositionOnce] instead — each FEN is verified at most once.
String enterFenPath(BuildTreeNode resolved, Set<String> visited) {
  final key = canonicalizeFen4(resolved.fen);
  visited.add(key);
  return key;
}

void leaveFenPath(String key, Set<String> visited) => visited.remove(key);

/// Global visit: true the first time this canonical FEN is seen.
bool enterPositionOnce(BuildTreeNode resolved, Set<String> visited) =>
    visited.add(canonicalizeFen4(resolved.fen));
