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

  /// Look up the canonical (expanded) node for a FEN.
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
  /// not grow the equivalence list.  Returns true when [node] was newly
  /// registered — the moment its reach should be added to the canonical.
  bool addTransposition(String fen, BuildTreeNode node) {
    _assertMutable();
    final list = _equivalents[_key(fen)] ??= [];
    for (final existing in list) {
      if (identical(existing, node)) return false;
    }
    list.add(node);
    return true;
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

  /// Walk a tree and register all nodes.  The canonical node for a FEN is an
  /// *expanded* one wherever the tree holds one; childless duplicates become
  /// transposition leaves that resolve through it.  Idempotent: safe to call
  /// repeatedly on a growing tree (a resumed build re-populates as it
  /// deepens).
  ///
  /// The expanded-wins rule is load-bearing, not a tidiness preference. This
  /// walk is a plain DFS, so "first node seen" is decided by child order, and
  /// a position reachable by two move orders is routinely met at its
  /// *unexpanded* copy first. Registering that copy as canonical stranded
  /// every line through it: [resolveTransposition] would hand back a childless
  /// node, the extractor would find no answer, and the line ended on the
  /// opponent's move with the user to play and nothing to play. The answered
  /// twin was not even recorded as an equivalent, so nothing could repair it
  /// downstream. On a 7.6k-node Benko tree that cost 52 positions and ~14% of
  /// the repertoire's reach mass.
  void populate(BuildTreeNode node) {
    _assertMutable();
    if (node.fen.isNotEmpty) {
      final canonical = getCanonical(node.fen);
      if (canonical == null) {
        putCanonical(node.fen, node);
      } else if (!identical(canonical, node)) {
        if (canonical.children.isEmpty && node.children.isNotEmpty) {
          // Promote: the expanded copy becomes canonical and the childless
          // one it displaces becomes a transposition leaf pointing at it.
          _canonical[_key(node.fen)] = node;
          _removeTransposition(node.fen, node);
          addTransposition(node.fen, canonical);
        } else if (node.children.isEmpty) {
          addTransposition(node.fen, node);
        }
      }
    }
    for (final child in node.children) {
      populate(child);
    }
  }

  /// Register every *expanded* node of a saved tree as canonical for its
  /// position, first in tree order wins.  This is what a resumed build needs
  /// from the previous session: which positions already have a subtree, so
  /// a frontier leaf reaching one of them becomes a transposition leaf
  /// instead of a second expansion.  Childless nodes are deliberately left
  /// out *of the canonical map* — a fresh build registers a position only when
  /// it processes it, and seeding an unexpanded frontier twin as canonical
  /// would make its earlier-processed sibling defer to a node that may never
  /// expand.  They are still re-registered as transposition *leaves* where
  /// they were closed as such last session; see [_registerSavedTranspositions].
  void registerExpanded(BuildTreeNode root) {
    _assertMutable();
    void walk(BuildTreeNode node) {
      if (node.children.isEmpty) return;
      if (node.fen.isNotEmpty) putCanonical(node.fen, node);
      for (final child in node.children) {
        walk(child);
      }
    }

    walk(root);
    _registerSavedTranspositions(root);
  }

  /// Second pass over a resumed tree: re-register the transposition leaves the
  /// previous session closed, so chains of transpositions keep resolving
  /// across a resume.
  ///
  /// Seeding [_canonical] alone is not enough. [addArrivalCumP] forwards a new
  /// arrival's reach through a leaf only when the leaf is a *registered*
  /// transposition, which it checks against [getTranspositions]. With that map
  /// empty on resume, the walk stopped at every saved leaf instead of
  /// forwarding into its canonical, so a canonical whose true reach now
  /// cleared `minProbability` was never re-queued, and the coverage sweep's
  /// `getTranspositions` under-counted reach and deleted holes it should have
  /// answered.
  ///
  /// Only *explored* childless nodes qualify — that is exactly what
  /// `_resolveTranspositionOrRegister` produced last session. A terminal or
  /// depth-capped leaf is canonical for its own FEN and the identity check
  /// skips it. Unexplored frontier leaves are deliberately excluded:
  /// [addArrivalCumP] does not forward their increments, because they
  /// contribute their full reach when the build finally processes them, and
  /// registering them here would count that mass twice.
  ///
  /// This adds no reach of its own. Arrival mass is only ever added by
  /// `_resolveTranspositionOrRegister`, and only when [addTransposition]
  /// reports a leaf as *newly* registered — which, after this pass, it is not.
  void _registerSavedTranspositions(BuildTreeNode root) {
    void walk(BuildTreeNode node) {
      if (node.children.isEmpty) {
        if (node.explored && node.fen.isNotEmpty) {
          final canonical = _canonical[_key(node.fen)];
          if (canonical != null && !identical(canonical, node)) {
            addTransposition(node.fen, node);
          }
        }
        return;
      }
      for (final child in node.children) {
        walk(child);
      }
    }

    walk(root);
  }

  /// Drop [node] from the equivalence list for [fen], if it is there. Used
  /// when a node registered as a transposition leaf on an earlier pass is
  /// promoted to canonical on a later one.
  void _removeTransposition(String fen, BuildTreeNode node) {
    final list = _equivalents[_key(fen)];
    if (list == null) return;
    list.removeWhere((n) => identical(n, node));
    if (list.isEmpty) _equivalents.remove(_key(fen));
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
