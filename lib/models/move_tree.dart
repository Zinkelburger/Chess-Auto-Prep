/// Lichess/En-Croissant-style move tree with path-based cursor.
///
/// [MoveTree] is the single source of truth for the editable PGN in the
/// repertoire builder.  [TreePath] is a list of child indices that locates
/// any node without keeping mutable pointers.  Every [MoveNode] caches its
/// post-move FEN so position derivation is O(1).
library;

import 'package:dartchess/dartchess.dart';

import '../constants/chess_constants.dart';
import '../utils/pgn_comment_utils.dart' show toggleQualityNag;
import 'move_tree_node_view.dart';

// ---------------------------------------------------------------------------
// TreePath
// ---------------------------------------------------------------------------

/// A cursor into a [MoveTree].
///
/// Each element is a child index at successive depths.
/// `[]` = starting position (before any move).
/// `[0]` = first root child (mainline first move).
/// `[0, 1]` = mainline first move → second child (first variation).
///
/// Wraps a `List<int>` with value semantics for equality/hashCode.
class TreePath {
  final List<int> _indices;

  const TreePath(List<int> indices) : _indices = indices;

  /// Empty path — starting position.
  static const TreePath empty = TreePath([]);

  /// Copy from an existing iterable.
  factory TreePath.from(Iterable<int> source) =>
      TreePath(List<int>.unmodifiable(source));

  /// Number of plies deep.
  int get length => _indices.length;
  bool get isEmpty => _indices.isEmpty;
  bool get isNotEmpty => _indices.isNotEmpty;

  /// Access a child index at depth [i].
  int operator [](int i) => _indices[i];

  /// Parent path (one ply back).  Returns [empty] when already at root.
  TreePath get parent =>
      _indices.isEmpty ? empty : TreePath(_indices.sublist(0, length - 1));

  /// Extend this path with a child index.
  TreePath child(int index) => TreePath([..._indices, index]);

  /// Path truncated to [n] elements.
  TreePath take(int n) => n >= length ? this : TreePath(_indices.sublist(0, n));

  /// Last element.
  int get last => _indices.last;

  /// Whether every element is 0 (mainline).
  bool get isMainline => _indices.every((i) => i == 0);

  /// Whether [other] is a descendant of (or equal to) this path.
  bool isAncestorOf(TreePath other) {
    if (other.length < length) return false;
    for (int i = 0; i < length; i++) {
      if (_indices[i] != other[i]) return false;
    }
    return true;
  }

  /// Iterate over indices.
  Iterable<int> get indices => _indices;

  /// Convert to a plain list (e.g. for serialization).
  List<int> toList() => List<int>.from(_indices);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TreePath) return false;
    if (length != other.length) return false;
    for (int i = 0; i < length; i++) {
      if (_indices[i] != other._indices[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_indices);

  @override
  String toString() => 'TreePath(${_indices.join(', ')})';
}

// ---------------------------------------------------------------------------
// MoveNode
// ---------------------------------------------------------------------------

/// A single move in the editable PGN tree.
///
/// [children] order matters: index 0 is always the mainline continuation,
/// index 1+ are variations (same convention as dartchess and Lichess).
class MoveNode implements MoveTreeNodeView {
  @override
  final String san;

  /// Board FEN *after* this move was played.
  final String fen;

  String? comment;
  List<int>? nags;

  /// Stable identity for this node within a session. Used by the analysis
  /// viewer to locate / delete a specific node without keeping a pointer.
  final int id;

  /// `true` = user-added (ephemeral) analysis move; `false` = from PGN/repertoire.
  /// Mutable: amend mode promotes a scratch line to saved when the user
  /// extends or annotates it (a saved edit under an ephemeral ancestor would
  /// otherwise be silently dropped by the serializer).
  bool isEphemeral;

  /// Ordered children.  `[0]` = mainline, `[1..]` = variations.
  final List<MoveNode> children;

  static int _nextId = 0;

  MoveNode({
    required this.san,
    required this.fen,
    this.comment,
    this.nags,
    this.isEphemeral = false,
    List<MoveNode>? children,
  }) : id = _nextId++,
       children = children ?? [];

  /// First child matching [san], or `null`.
  MoveNode? findChild(String san) {
    for (final child in children) {
      if (child.san == san) return child;
    }
    return null;
  }

  /// Append a child move (or return an existing one with the same SAN).
  /// Returns the node plus whether it is the mainline continuation (`[0]`).
  (MoveNode node, bool isMainLine) addChild(
    String san,
    String fen, {
    bool isEphemeral = true,
  }) {
    final existing = findChild(san);
    if (existing != null) {
      return (existing, children.indexOf(existing) == 0);
    }
    final newNode = MoveNode(san: san, fen: fen, isEphemeral: isEphemeral);
    children.add(newNode);
    return (newNode, children.length == 1);
  }

  // ── MoveTreeNodeView ──
  @override
  String get fenAfter => fen;
  @override
  List<MoveTreeNodeView> get orderedChildren => children;

  @override
  String toString() => 'MoveNode($san, children=${children.length})';
}

// ---------------------------------------------------------------------------
// MoveTree
// ---------------------------------------------------------------------------

/// An editable tree of chess moves with PGN round-trip.
///
/// Owns the data; navigation state (the cursor) lives in the controller.
class MoveTree {
  /// FEN of the position *before* any root move.
  String startingFen;

  /// Root-level siblings (typically one first move, but PGN allows multiple).
  final List<MoveNode> roots;

  MoveTree({String? startingFen, List<MoveNode>? roots})
    : startingFen = startingFen ?? kStandardStartFen,
      roots = roots ?? [];

  /// Deep copy whose nodes carry freshly minted ids.
  ///
  /// A tree received from another isolate (e.g. parsed via `compute`) holds
  /// ids minted by that isolate's own counter, which can collide with ids
  /// of nodes created here; adopt such a tree only through this copy.
  MoveTree copyWithFreshIds() => MoveTree(
    startingFen: startingFen,
    roots: roots.map(_copyNodeWithFreshId).toList(),
  );

  static MoveNode _copyNodeWithFreshId(MoveNode node) => MoveNode(
    san: node.san,
    fen: node.fen,
    comment: node.comment,
    nags: node.nags,
    isEphemeral: node.isEphemeral,
    children: node.children.map(_copyNodeWithFreshId).toList(),
  );

  // ── Lookup ──────────────────────────────────────────────────────────

  /// Children list that *contains* the node at [path].
  /// For a single-element path, that's [roots].
  /// Returns `null` when the path is out of range.
  List<MoveNode>? _siblingsAt(TreePath path) {
    if (path.isEmpty) return null;
    var siblings = roots;
    for (int i = 0; i < path.length - 1; i++) {
      if (path[i] < 0 || path[i] >= siblings.length) return null;
      siblings = siblings[path[i]].children;
    }
    if (path.last < 0 || path.last >= siblings.length) return null;
    return siblings;
  }

  /// Node at [path], or `null` if the path is empty or out of range.
  MoveNode? nodeAt(TreePath path) {
    final siblings = _siblingsAt(path);
    if (siblings == null) return null;
    return siblings[path.last];
  }

  /// Ordered list of nodes from root to [path] (inclusive).
  List<MoveNode> nodeListAt(TreePath path) {
    final result = <MoveNode>[];
    var siblings = roots;
    for (final idx in path.indices) {
      if (idx < 0 || idx >= siblings.length) break;
      result.add(siblings[idx]);
      siblings = siblings[idx].children;
    }
    return result;
  }

  /// FEN at [path].  Empty path → [startingFen].
  String fenAt(TreePath path) {
    if (path.isEmpty) return startingFen;
    final node = nodeAt(path);
    return node?.fen ?? startingFen;
  }

  /// SAN sequence from root to [path].
  List<String> sanSequenceAt(TreePath path) =>
      nodeListAt(path).map((n) => n.san).toList();

  /// Walk mainline (`children[0]`) to the leaf, starting from [path].
  TreePath mainlineEndFrom(TreePath path) {
    var current = path;
    var siblings = path.isEmpty ? roots : (nodeAt(path)?.children ?? []);
    if (path.isEmpty && roots.isEmpty) return TreePath.empty;
    if (path.isEmpty) {
      current = const TreePath([0]);
      siblings = roots[0].children;
    }
    while (siblings.isNotEmpty) {
      current = current.child(0);
      siblings = siblings[0].children;
    }
    return current;
  }

  /// Whether the tree has any moves.
  bool get isEmpty => roots.isEmpty;
  bool get isNotEmpty => roots.isNotEmpty;

  /// Collect all FENs in the tree (position part only, first 4 fields).
  /// Useful for transposition detection.
  Set<String> collectFenPrefixes() {
    final fens = <String>{};
    void walk(List<MoveNode> nodes) {
      for (final node in nodes) {
        fens.add(node.fen.split(' ').take(4).join(' '));
        walk(node.children);
      }
    }

    walk(roots);
    return fens;
  }

  /// Whether [path] points to a valid node.
  bool isValidPath(TreePath path) {
    if (path.isEmpty) return true;
    return nodeAt(path) != null;
  }

  // ── Mutation ────────────────────────────────────────────────────────

  /// Add a move after position [parentPath].
  ///
  /// If a child with the same SAN already exists, returns the path to it
  /// (no duplicate).  Otherwise appends a new child and returns its path.
  /// Returns `null` if the SAN is illegal at the parent position.
  TreePath? addMove(TreePath parentPath, String san) {
    final parentFen = fenAt(parentPath);
    final pos = _positionFromFen(parentFen);
    if (pos == null) return null;
    final move = pos.parseSan(san);
    if (move == null) return null;
    final newPos = pos.play(move);

    final siblings = parentPath.isEmpty ? roots : nodeAt(parentPath)?.children;
    if (siblings == null) return null;

    // Check for existing child with same SAN.
    for (int i = 0; i < siblings.length; i++) {
      if (siblings[i].san == san) {
        return parentPath.child(i);
      }
    }

    siblings.add(MoveNode(san: san, fen: newPos.fen));
    return parentPath.child(siblings.length - 1);
  }

  /// Delete the subtree rooted at [path].
  void deleteAt(TreePath path) {
    if (path.isEmpty) {
      roots.clear();
      return;
    }
    final parentSiblings = path.length == 1
        ? roots
        : nodeAt(path.parent)?.children;
    if (parentSiblings == null) return;
    if (path.last >= 0 && path.last < parentSiblings.length) {
      parentSiblings.removeAt(path.last);
    }
  }

  /// Promote the variation at [path] to mainline (index 0) among its siblings.
  void promoteVariation(TreePath path) {
    if (path.isEmpty) return;
    final siblings = path.length == 1 ? roots : nodeAt(path.parent)?.children;
    if (siblings == null || path.last <= 0 || path.last >= siblings.length) {
      return;
    }
    final node = siblings.removeAt(path.last);
    siblings.insert(0, node);
  }

  /// Set comment on the node at [path].
  void setComment(TreePath path, String? comment) {
    final node = nodeAt(path);
    if (node != null) {
      node.comment = comment;
    }
  }

  /// Toggle a move-quality NAG on the node at [path].
  ///
  /// The six move-quality glyphs (ids 1–6) are mutually exclusive — setting
  /// one clears the others — matching Lichess/ChessBase behaviour. Toggling
  /// the glyph already present removes it. Non-quality NAGs are left intact.
  void toggleNag(TreePath path, int nagId) {
    final node = nodeAt(path);
    if (node == null) return;
    final next = toggleQualityNag(node.nags, nagId);
    node.nags = next.isEmpty ? null : next;
  }

  // ── PGN round-trip ─────────────────────────────────────────────────

  /// Parse a PGN string into a [MoveTree].
  factory MoveTree.fromPgn(String pgn, {String? startingFen}) {
    if (pgn.trim().isEmpty) {
      return MoveTree(startingFen: startingFen);
    }

    try {
      final game = PgnGame.parsePgn(pgn);

      final fenHeader = game.headers['FEN'];
      final effectiveFen = startingFen ?? fenHeader ?? kStandardStartFen;

      final rootPos = _positionFromFen(effectiveFen) ?? Chess.initial;
      final roots = _convertDartchessNodes(game.moves.children, rootPos);

      return MoveTree(startingFen: effectiveFen, roots: roots);
    } catch (_) {
      return MoveTree(startingFen: startingFen);
    }
  }

  /// Build a [MoveTree] from a flat SAN list (no variations).
  factory MoveTree.fromMoves(List<String> moves, {String? startingFen}) {
    final fen = startingFen ?? kStandardStartFen;
    var pos = _positionFromFen(fen) ?? Chess.initial;
    final tree = MoveTree(startingFen: fen);
    var siblings = tree.roots;

    for (final san in moves) {
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
      final node = MoveNode(san: san, fen: pos.fen);
      siblings.add(node);
      siblings = node.children;
    }
    return tree;
  }

  /// Serialize this tree to PGN move text (no headers).
  String toPgnMoveText() {
    if (roots.isEmpty) return '';
    final buffer = StringBuffer();
    final (startMoveNumber, startIsWhite) = moveNumberFromFen(startingFen);
    _writeNodes(
      buffer,
      roots,
      startMoveNumber,
      startIsWhite,
      isFirstMove: true,
    );
    return buffer.toString().trim();
  }

  /// Serialize to full PGN including headers.
  String toPgn({String? event, String? white, String? black, String? result}) {
    final headers = <String>[];
    headers.add('[Event "${event ?? "?"}"]');
    headers.add(
      '[Date "${DateTime.now().toIso8601String().split('T').first}"]',
    );
    headers.add('[White "${white ?? "?"}"]');
    headers.add('[Black "${black ?? "?"}"]');
    headers.add('[Result "${result ?? "*"}"]');
    if (startingFen != kStandardStartFen) {
      headers.add('[FEN "$startingFen"]');
      headers.add('[SetUp "1"]');
    }

    final moveText = toPgnMoveText();
    return [...headers, '', moveText].join('\n');
  }

  // ── Private helpers ────────────────────────────────────────────────

  static Position? _positionFromFen(String fen) {
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return null;
    }
  }

  static List<MoveNode> _convertDartchessNodes(
    List<PgnChildNode<PgnNodeData>> nodes,
    Position parentPosition,
  ) {
    final result = <MoveNode>[];
    for (final node in nodes) {
      final san = node.data.san;
      final move = parentPosition.parseSan(san);
      if (move == null) continue;
      final afterPos = parentPosition.play(move);
      final comment = node.data.comments?.join(' ');
      final nags = node.data.nags?.toList();
      result.add(
        MoveNode(
          san: san,
          fen: afterPos.fen,
          comment: (comment != null && comment.trim().isNotEmpty)
              ? comment.trim()
              : null,
          nags: nags,
          children: _convertDartchessNodes(node.children, afterPos),
        ),
      );
    }
    return result;
  }

  /// Extract move number and side-to-move from a FEN string.
  static (int moveNumber, bool isWhite) moveNumberFromFen(String fen) {
    final parts = fen.split(' ');
    final isWhite = parts.length >= 2 ? parts[1] == 'w' : true;
    final moveNumber = parts.length >= 6 ? (int.tryParse(parts[5]) ?? 1) : 1;
    return (moveNumber, isWhite);
  }

  static void _writeNodes(
    StringBuffer buffer,
    List<MoveNode> siblings,
    int moveNumber,
    bool isWhite, {
    bool isFirstMove = false,
  }) {
    if (siblings.isEmpty) return;

    final main = siblings[0];

    if (isWhite) {
      buffer.write('$moveNumber. ');
    } else if (isFirstMove) {
      buffer.write('$moveNumber... ');
    }

    buffer.write('${main.san} ');
    _writeNags(buffer, main);
    if (main.comment != null && main.comment!.isNotEmpty) {
      buffer.write('{${_sanitizeComment(main.comment!)}} ');
    }

    for (int i = 1; i < siblings.length; i++) {
      buffer.write('(');
      if (isWhite) {
        buffer.write('$moveNumber. ');
      } else {
        buffer.write('$moveNumber... ');
      }

      final variant = siblings[i];
      buffer.write('${variant.san} ');
      _writeNags(buffer, variant);
      if (variant.comment != null && variant.comment!.isNotEmpty) {
        buffer.write('{${_sanitizeComment(variant.comment!)}} ');
      }

      _writeNodes(
        buffer,
        variant.children,
        isWhite ? moveNumber : moveNumber + 1,
        !isWhite,
      );

      buffer.write(') ');
    }

    _writeNodes(
      buffer,
      main.children,
      isWhite ? moveNumber : moveNumber + 1,
      !isWhite,
    );
  }

  /// Write `$N` NAG tokens (PGN standard) so annotations survive a round-trip.
  static void _writeNags(StringBuffer buffer, MoveNode node) {
    final nags = node.nags;
    if (nags == null) return;
    for (final nag in nags) {
      buffer.write('\$$nag ');
    }
  }

  static String _sanitizeComment(String comment) =>
      comment.replaceAll('{', '').replaceAll('}', '');
}
