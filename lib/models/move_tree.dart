/// Lichess/En-Croissant-style move tree with path-based cursor.
///
/// [MoveTree] is the single source of truth for the editable PGN in the
/// repertoire builder.  [TreePath] is a list of child indices that locates
/// any node without keeping mutable pointers.  Every [MoveNode] caches its
/// post-move FEN so position derivation is O(1).
library;

import 'package:dartchess/dartchess.dart';

import '../constants/chess_constants.dart';
import '../utils/chess_utils.dart' show playSanOrNullMove, tryParseFen;
import '../utils/fen_utils.dart';
import '../chess_core/pgn/pgn_parser.dart';
import '../chess_core/pgn/quality_nags.dart';
import '../chess_core/moves/move_tree_view.dart';
import '../chess_core/moves/tree_path.dart';
import 'move_tree_pgn.dart';

// ---------------------------------------------------------------------------
// MoveNode
// ---------------------------------------------------------------------------

/// A single move in the editable PGN tree.
///
/// [children] order matters: index 0 is always the mainline continuation,
/// index 1+ are variations (same convention as dartchess and Lichess).
class MoveNode implements MoveNodeView {
  @override
  final String san;

  /// Board FEN *after* this move was played.
  @override
  final String fen;

  /// The position [fen] describes, parsed at most once.
  ///
  /// Nodes created by playing a move keep the [Position] they were derived
  /// from; nodes that arrive with only a FEN (a deserialised tree, a
  /// hand-built test fixture) parse it lazily on first use.  Either way a
  /// second read is free, so navigation, legal-move lookups and move
  /// derivation never re-parse a FEN the tree already holds.
  ///
  /// Substitutes the initial board when [fen] does not parse, so display code
  /// always has *a* board to draw.  Anything that derives new state from it —
  /// playing a further move, deriving a child FEN — must use
  /// [positionOrNull] instead and refuse, or a corrupt FEN silently produces
  /// moves belonging to a completely different position.
  @override
  Position get position => positionOrNull ?? Chess.initial;

  /// [position] without the substitution: null when [fen] does not parse.
  @override
  Position? get positionOrNull => _position ??= tryParseFen(fen);
  Position? _position;

  @override
  String? comment;

  /// Comment written *before* this move rather than after it — PGN's
  /// "starting comment", which is where a study's prose introduction to a
  /// variation lives (`( { why this line } 1. c4 c5 )`). Kept separate from
  /// [comment] because the two land in different places on the way back out,
  /// and folding one into the other moves the reader's note onto the wrong
  /// side of the move. Dropping it — which this model used to do — deleted
  /// that note from the file on the next autosave.
  @override
  String? startingComment;

  @override
  List<int>? nags;

  /// Stable identity for this node within a session. Used by the analysis
  /// viewer to locate / delete a specific node without keeping a pointer.
  @override
  final int id;

  /// `true` = user-added (ephemeral) analysis move; `false` = from PGN/repertoire.
  /// Mutable: amend mode promotes a scratch line to saved when the user
  /// extends or annotates it (a saved edit under an ephemeral ancestor would
  /// otherwise be silently dropped by the serializer).
  @override
  bool isEphemeral;

  /// Ordered children.  `[0]` = mainline, `[1..]` = variations.
  @override
  final List<MoveNode> children;

  static int _nextId = 0;

  MoveNode({
    required this.san,
    required this.fen,
    Position? position,
    this.comment,
    this.startingComment,
    this.nags,
    this.isEphemeral = false,
    List<MoveNode>? children,
  }) : // A private named initializing formal is not legal Dart.
       // ignore: prefer_initializing_formals
       _position = position,
       id = _nextId++,
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
  List<MoveNodeView> get orderedChildren => children;

  @override
  String toString() => 'MoveNode($san, children=${children.length})';
}

// ---------------------------------------------------------------------------
// MoveTree
// ---------------------------------------------------------------------------

/// An editable tree of chess moves with PGN round-trip.
///
/// Owns the data; navigation state (the cursor) lives in the controller.
class MoveTree extends MoveTreeView {
  /// FEN of the position *before* any root move.
  @override
  String get startingFen => _startingFen;
  set startingFen(String value) {
    if (value == _startingFen) return;
    _startingFen = value;
    _startingPosition = null;
    _bumpVersion();
  }

  String _startingFen;
  Position? _startingPosition;

  /// The position *before* any root move, parsed at most once per
  /// [startingFen].
  @override
  Position get startingPosition => startingPositionOrNull ?? Chess.initial;

  /// [startingPosition] without the fallback: null when [startingFen] does
  /// not parse.
  @override
  Position? get startingPositionOrNull =>
      _startingPosition ??= tryParseFen(_startingFen);

  /// Root-level siblings (typically one first move, but PGN allows multiple).
  @override
  final List<MoveNode> roots;

  /// Comment on the starting position — the `{…}` block a PGN carries before
  /// its first move.  Lichess writes a chapter's introduction (and any shapes
  /// drawn on the start position) here, so dropping it loses the one comment
  /// a study chapter is most likely to have.  Empty is stored as null.
  @override
  String? get rootComment => _rootComment;
  set rootComment(String? value) {
    final normalized = (value == null || value.trim().isEmpty) ? null : value;
    if (normalized == _rootComment) return;
    _rootComment = normalized;
    _bumpVersion();
  }

  String? _rootComment;

  /// Incremented on every structural or annotation change made through this
  /// class.  Views that cache work derived from the tree (the editor's
  /// rendered movetext, a flattened outline) key that cache on the version
  /// rather than rebuilding whenever the cursor moves.  Mutating [roots] or
  /// a node's `children` directly bypasses it — call [markMutated] after.
  @override
  int get version => _version;
  int _version = 0;

  void _bumpVersion() => _version++;

  /// Record an out-of-band mutation (see [version]).
  void markMutated() => _bumpVersion();

  MoveTree({String? startingFen, List<MoveNode>? roots, String? rootComment})
    : _startingFen = startingFen ?? kStandardStartFen,
      roots = roots ?? [],
      _rootComment = (rootComment == null || rootComment.trim().isEmpty)
          ? null
          : rootComment;

  /// Deep copy whose nodes carry freshly minted ids.
  ///
  /// A tree received from another isolate (e.g. parsed via `compute`) holds
  /// ids minted by that isolate's own counter, which can collide with ids
  /// of nodes created here; adopt such a tree only through this copy.
  MoveTree copyWithFreshIds() {
    final copy = MoveTree(startingFen: startingFen, rootComment: rootComment);
    final pending = [for (final node in roots.reversed) (node, copy.roots)];
    while (pending.isNotEmpty) {
      final (node, output) = pending.removeLast();
      final next = MoveNode(
        san: node.san,
        fen: node.fen,
        position: node._position,
        comment: node.comment,
        startingComment: node.startingComment,
        nags: node.nags == null ? null : List.of(node.nags!),
        isEphemeral: node.isEphemeral,
      );
      output.add(next);
      for (final child in node.children.reversed) {
        pending.add((child, next.children));
      }
    }
    return copy;
  }

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
  @override
  MoveNode? nodeAt(TreePath path) {
    final siblings = _siblingsAt(path);
    if (siblings == null) return null;
    return siblings[path.last];
  }

  /// Ordered list of nodes from root to [path] (inclusive).
  @override
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

  // ── Mutation ────────────────────────────────────────────────────────

  /// Add a move after position [parentPath].
  ///
  /// If a child with the same SAN already exists, returns the path to it
  /// (no duplicate) — that check comes first, so a SAN already in the tree is
  /// answered without a legality test.  Otherwise appends a new child and
  /// returns its path.  Returns `null` when the parent path is unknown, its
  /// FEN does not parse, or the SAN is illegal there.
  TreePath? addMove(TreePath parentPath, String san) {
    final siblings = parentPath.isEmpty ? roots : nodeAt(parentPath)?.children;
    if (siblings == null) return null;

    // Check for existing child with same SAN.
    for (int i = 0; i < siblings.length; i++) {
      if (siblings[i].san == san) {
        return parentPath.child(i);
      }
    }

    // Refuse rather than substitute: a node whose FEN does not parse must not
    // grow a child built by playing [san] from the *initial* board.
    final parent = positionOrNullAt(parentPath);
    if (parent == null) return null;
    final next = playSanOrNullMove(parent, san);
    if (next == null) return null;

    siblings.add(MoveNode(san: san, fen: next.fen, position: next));
    _bumpVersion();
    return parentPath.child(siblings.length - 1);
  }

  /// Delete the subtree rooted at [path].
  void deleteAt(TreePath path) {
    if (path.isEmpty) {
      roots.clear();
      _bumpVersion();
      return;
    }
    final parentSiblings = path.length == 1
        ? roots
        : nodeAt(path.parent)?.children;
    if (parentSiblings == null) return;
    if (path.last >= 0 && path.last < parentSiblings.length) {
      parentSiblings.removeAt(path.last);
      _bumpVersion();
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
    _bumpVersion();
  }

  /// Set comment on the node at [path]; the empty path is [rootComment].
  void setComment(TreePath path, String? comment) {
    if (path.isEmpty) {
      rootComment = comment;
      return;
    }
    final node = nodeAt(path);
    if (node != null && node.comment != comment) {
      node.comment = comment;
      _bumpVersion();
    }
  }

  /// Drop every comment (shapes and markers live in comments, so they go
  /// too) and every glyph, keeping the moves — Lichess's "Clear all comments,
  /// glyphs and drawn shapes".
  void clearAnnotations() {
    void walk(List<MoveNode> nodes) {
      for (final node in nodes) {
        node.comment = null;
        node.startingComment = null;
        node.nags = null;
        walk(node.children);
      }
    }

    walk(roots);
    _rootComment = null;
    _bumpVersion();
  }

  /// Delete every sideline, keeping only the mainline and its annotations —
  /// Lichess's "Clear variations".
  void clearVariations() {
    var siblings = roots;
    while (siblings.isNotEmpty) {
      if (siblings.length > 1) siblings.removeRange(1, siblings.length);
      siblings = siblings.first.children;
    }
    _bumpVersion();
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
    _bumpVersion();
  }

  // ── PGN round-trip ─────────────────────────────────────────────────

  /// Parse a PGN string into a [MoveTree].
  factory MoveTree.fromPgn(String pgn, {String? startingFen}) {
    if (pgn.trim().isEmpty) {
      return MoveTree(startingFen: startingFen);
    }

    try {
      final game = parsePgnGame(pgn);
      final effectiveFen =
          startingFen ?? game.headers['FEN'] ?? kStandardStartFen;
      final rootPos = tryParseFen(effectiveFen) ?? Chess.initial;
      return MoveTree(
        startingFen: effectiveFen,
        roots: MoveTreePgnCodec.nodesFromDartchess(
          game.moves.children,
          rootPos,
        ),
        rootComment: MoveTreePgnCodec.joinComments(game.comments),
      );
    } catch (_) {
      // dartchess has no single parse-error type: malformed movetext can
      // surface as a FormatException, a RangeError or a StateError.  An
      // unparsable game is an empty tree, which is what every caller wants.
      return MoveTree(startingFen: startingFen);
    }
  }

  /// Build a [MoveTree] from a flat SAN list (no variations).
  factory MoveTree.fromMoves(List<String> moves, {String? startingFen}) {
    final fen = startingFen ?? kStandardStartFen;
    var pos = tryParseFen(fen) ?? Chess.initial;
    final tree = MoveTree(startingFen: fen);
    var siblings = tree.roots;

    for (final san in moves) {
      final next = playSanOrNullMove(pos, san);
      if (next == null) break;
      pos = next;
      final node = MoveNode(san: san, fen: pos.fen, position: pos);
      siblings.add(node);
      siblings = node.children;
    }
    return tree;
  }

  /// Extract move number and side-to-move from a FEN string.
  static (int moveNumber, bool isWhite) moveNumberFromFen(String fen) =>
      (fullMoveNumber(fen), isWhiteToMove(fen));
}
