/// Opening tree models - Represents a tree of moves from analyzed games
/// Similar to openingtree.com's move explorer functionality
library;

import 'dart:collection';
import '../chess_core/moves/opening_graph.dart';

import 'package:dartchess/dartchess.dart';

import '../constants/chess_constants.dart';
import '../utils/chess_utils.dart'
    show isNullMoveSan, playSanOrNullMove, tryParseFen;
import '../utils/fen_utils.dart';
import '../utils/movetext_builder.dart';
import 'legal_destination_cache.dart';
import 'opening_tree_transfer.dart';

/// How win/draw/loss stats should be colored when displayed.
///
/// The PGN-viewer tree counts `wins` from White's perspective. Green/red only
/// makes sense when we know whose games these are — otherwise color like
/// lichess: white / grey / black segments.
enum WdlPerspective {
  /// `wins` belong to the protagonist playing White → green = wins.
  playerIsWhite,

  /// The protagonist plays Black → green = `losses` (Black's wins).
  playerIsBlack,

  /// No known protagonist: neutral white/grey/black coloring.
  whiteBlack,
}

/// One position on one move-order path, with the results of the games that
/// reached it that way.  Transpositions are separate nodes; see
/// [PositionGroup] for the FEN-keyed view.
class OpeningTreeNode implements OpeningNodeView {
  /// The move that led to this node (SAN notation, e.g. "e4", "Nf3")
  /// Empty string for root node
  @override
  final String move;

  /// The FEN position after this move was played
  @override
  final String fen;

  /// Statistics for games where this move was played
  @override
  int gamesPlayed;
  @override
  int wins;
  @override
  int losses;
  @override
  int draws;

  /// Child nodes (next moves from this position)
  /// Key: move in SAN notation
  /// Value: the resulting node
  @override
  final Map<String, OpeningTreeNode> children;

  /// Parent node (for navigation back up the tree)
  @override
  OpeningTreeNode? parent;

  OpeningTreeNode({
    required this.move,
    required this.fen,
    this.gamesPlayed = 0,
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    Map<String, OpeningTreeNode>? children,
    this.parent,
  }) : children = children ?? {};

  /// Calculate win rate (0.0 to 1.0).
  ///
  /// USER-perspective: [wins]/[losses] are counted for the tree's
  /// protagonist (the user/repertoire side the tree was built for), not for
  /// White. Contrast with `BuildTreeNode.whiteWinRate`, which is always
  /// White's score.
  @override
  double get winRate {
    if (gamesPlayed == 0) return 0.0;
    return (wins + 0.5 * draws) / gamesPlayed;
  }

  /// Win rate as percentage
  @override
  double get winRatePercent => winRate * 100;

  List<OpeningTreeNode>? _sortedChildrenCache;

  /// Get sorted list of children by number of games played (descending).
  /// Cached and invalidated when children or stats change.
  @override
  List<OpeningTreeNode> get sortedChildren =>
      _sortedChildrenCache ??= children.values.toList()
        ..sort((a, b) => b.gamesPlayed.compareTo(a.gamesPlayed));

  void _invalidateSortCache() => _sortedChildrenCache = null;

  /// Whether any of the counted games have a real result (not just `*`).
  @override
  bool get hasWdl => wins + losses + draws > 0;

  /// Update statistics with a game result.
  /// Result should be from the player's perspective (1.0 = win, 0.5 = draw, 0.0 = loss).
  /// Pass null for unfinished / course lines (`*`) so they count toward
  /// frequency without painting a fake 50% draw bar.
  ///
  /// **Important:** Directly mutating [gamesPlayed], [wins], [losses], or
  /// [draws] bypasses cache invalidation. Always use this method or call
  /// [_invalidateSortCache] on the parent after manual mutation.
  void updateStats(double? result) {
    gamesPlayed++;
    if (result != null) {
      if (result >= 0.9) {
        wins++;
      } else if (result <= 0.1) {
        losses++;
      } else {
        draws++;
      }
    }
    parent?._invalidateSortCache();
  }

  /// Add or get a child node for a move
  OpeningTreeNode getOrCreateChild(String movesan, String resultingFen) =>
      children.putIfAbsent(movesan, () {
        _invalidateSortCache();
        return OpeningTreeNode(move: movesan, fen: resultingFen, parent: this);
      });

  /// Whether the move leading to this node was played by White. [fen] is the
  /// position *after* the move, so the mover is the side that is no longer to
  /// move. FEN-derived (rather than ply parity) so custom start positions and
  /// transposed paths stay correct.
  @override
  bool get moverWasWhite => !isWhiteToMove(fen);

  /// How likely the protagonist (the player whose games built this tree,
  /// playing White when [protagonistIsWhite]) is to reach this node's
  /// position, assuming the viewer plays down this exact path themselves.
  /// See [ReachEstimate].
  @override
  ReachEstimate reachEstimate({required bool protagonistIsWhite}) {
    var probability = 1.0;
    var decisionPoints = 0;
    var node = this;
    while (true) {
      final parent = node.parent;
      if (parent == null) break;
      if (node.moverWasWhite == protagonistIsWhite && parent.gamesPlayed > 0) {
        probability *= node.gamesPlayed / parent.gamesPlayed;
        if (node.gamesPlayed < parent.gamesPlayed) decisionPoints++;
      }
      node = parent;
    }
    return ReachEstimate(probability, decisionPoints);
  }

  /// Get path from root to this node (list of moves)
  @override
  List<String> getMovePath() {
    final path = <String>[];
    OpeningTreeNode? current = this;

    while (current != null && current.move.isNotEmpty) {
      path.add(current.move);
      current = current.parent;
    }

    return path.reversed.toList();
  }

  /// How many nodes this subtree holds down to [maxPly] plies below here.
  ///
  /// The denominator of a long walk's progress bar, so it counts exactly what
  /// the walk will visit: a node at [maxPly] is counted, its children are not.
  /// Breadth-first and iterative because a deep repertoire will blow the
  /// stack on recursion.
  @override
  int countDescendants({required int maxPly}) {
    var count = 0;
    final queue = Queue<(OpeningTreeNode, int)>()..add((this, 0));
    while (queue.isNotEmpty) {
      final (node, ply) = queue.removeFirst();
      if (ply > maxPly) continue;
      count++;
      for (final child in node.children.values) {
        queue.add((child, ply + 1));
      }
    }
    return count;
  }

  /// Get the full move path as a string (e.g. "1.e4 e5 2.Nf3 Nc6")
  @override
  String getMovePathString() {
    final moves = getMovePath();
    if (moves.isEmpty) return 'Starting position';
    return buildNumberedMovetext(moves, compact: true);
  }

  @override
  String toString() {
    return 'OpeningTreeNode(move: $move, games: $gamesPlayed, children: ${children.length})';
  }
}

/// A transposition-aware view of one position: every tree node that reaches
/// the same position (same normalized FEN) via a different move order, with
/// statistics summed across them.
///
/// The tree itself is path-based, so a position reached by transposition is
/// split across several [OpeningTreeNode]s. Summing here is what makes tree
/// counts agree with the FEN-keyed position statistics shown elsewhere
/// (e.g. the FEN list in player analysis).
class PositionGroup implements OpeningPositionView {
  /// The nodes sharing this position. Never empty.
  @override
  final List<OpeningTreeNode> nodes;

  /// SAN to display for this group when it differs from [primaryNode.move]
  /// — used for one-ply transpositions, where the destination was reached
  /// by a different move in the database.
  final String? displayMove;

  /// True when this continuation was not actually played from the parent
  /// FEN, but is a legal move that lands on a FEN the tree already has.
  @override
  final bool viaTransposition;

  PositionGroup(this.nodes, {this.displayMove, this.viaTransposition = false})
    : assert(nodes.isNotEmpty);

  /// The node reached by the most games — the representative concrete path
  /// used where a single node is required (navigation cursor, move-path
  /// display, coverage checks).
  @override
  late final OpeningTreeNode primaryNode = nodes.reduce(
    (a, b) => b.gamesPlayed > a.gamesPlayed ? b : a,
  );

  /// Full FEN of the position (from [primaryNode]).
  @override
  String get fen => primaryNode.fen;

  /// SAN of the move leading here. Continuation groups built by [children]
  /// share one SAN; for an arbitrary position group this is the primary
  /// node's last move. One-ply transpositions pass [displayMove] so the
  /// row shows the SAN from *this* position, not the database's move order.
  @override
  String get move => displayMove ?? primaryNode.move;

  // A group is a snapshot built for one read (a row, a header, a sort), so
  // its sums are computed once on first use rather than re-folded on every
  // access — a sort comparator alone reads [gamesPlayed] O(n log n) times.
  @override
  late final int gamesPlayed = nodes.fold(0, (sum, n) => sum + n.gamesPlayed);
  @override
  late final int wins = nodes.fold(0, (sum, n) => sum + n.wins);
  @override
  late final int losses = nodes.fold(0, (sum, n) => sum + n.losses);
  @override
  late final int draws = nodes.fold(0, (sum, n) => sum + n.draws);

  /// Whether any path into this group has a scored result.
  @override
  bool get hasWdl => wins + losses + draws > 0;

  /// Win rate across all paths (user perspective, like
  /// [OpeningTreeNode.winRate]).
  @override
  double get winRate {
    final games = gamesPlayed;
    if (games == 0) return 0.0;
    return (wins + 0.5 * draws) / games;
  }

  @override
  double get winRatePercent => winRate * 100;

  /// Reach estimate summed across every path (transposition) into this
  /// position — the paths are disjoint, so their probabilities add. Decision
  /// points are reported for the most-played path ([primaryNode]).
  @override
  ReachEstimate reachEstimate({required bool protagonistIsWhite}) {
    var probability = 0.0;
    for (final node in nodes) {
      probability += node
          .reachEstimate(protagonistIsWhite: protagonistIsWhite)
          .probability;
    }
    return ReachEstimate(
      probability.clamp(0.0, 1.0),
      primaryNode
          .reachEstimate(protagonistIsWhite: protagonistIsWhite)
          .decisionPoints,
    );
  }

  /// Continuations from this position, merged across all [nodes] (grouped by
  /// SAN) and sorted by games played, descending.
  @override
  late final List<PositionGroup> children = _groupChildren();

  List<PositionGroup> _groupChildren() {
    final bySan = <String, List<OpeningTreeNode>>{};
    for (final node in nodes) {
      for (final child in node.children.values) {
        (bySan[child.move] ??= []).add(child);
      }
    }
    return bySan.values.map(PositionGroup.new).toList()
      ..sort((a, b) => b.gamesPlayed.compareTo(a.gamesPlayed));
  }
}

/// Opening tree - contains the root node and provides navigation
class OpeningTree implements OpeningGraph {
  @override
  final OpeningTreeNode root;
  @override
  OpeningTreeNode currentNode;

  /// Collection viewers retain disconnected setup chapters as separate roots.
  /// Other consumers keep their existing single-root repertoire layout.
  final bool preserveSetupRoots;
  @override
  final List<OpeningTreeNode> setupRoots = [];
  @override
  OpeningTreeNode cursorRoot;

  /// FEN to node mapping for quick lookup
  @override
  final Map<String, List<OpeningTreeNode>> fenToNodes = {};

  /// SAN path the cursor actually walked (click order / board history),
  /// which can differ from [currentNode.getMovePath] after a transposition.
  List<String> _walkedSans = [];

  /// Set when the cursor is at a legal position the tree never reached.
  /// Continuations from here are one-ply transpositions into known FENs.
  String? _offBookFen;

  final LegalDestinationCache _legalDestinations = LegalDestinationCache();

  OpeningTree({OpeningTreeNode? root, bool preserveSetupRoots = false})
    : this._(
        root ?? OpeningTreeNode(move: '', fen: kStandardStartFen),
        preserveSetupRoots,
      );

  OpeningTree._(this.root, this.preserveSetupRoots)
    : currentNode = root,
      cursorRoot = root {
    indexNode(root);
  }

  OpeningTreeNode addSetupRoot(String fen) {
    final node = OpeningTreeNode(move: '', fen: fen);
    setupRoots.add(node);
    indexNode(node);
    return node;
  }

  /// FEN the cursor is sitting on — the off-book board when the walked
  /// path left the database, otherwise [currentNode.fen].
  @override
  String get currentFen => _offBookFen ?? currentNode.fen;

  /// Whether [currentFen] occurs in the tree (any move order).
  @override
  bool get inBook => _nodesAt(currentFen) != null;

  /// SAN path shown in the header: the walk that produced [currentFen].
  @override
  List<String> get currentMovePath => List<String>.of(_walkedSans);

  @override
  bool get canGoBack => _walkedSans.isNotEmpty;

  @override
  String get currentMovePathString => _walkedSans.isEmpty
      ? 'Starting position'
      : buildNumberedMovetext(
          _walkedSans,
          compact: true,
          startMoveNumber: fullMoveNumber(cursorRoot.fen),
          whiteToMoveFirst: isWhiteToMove(cursorRoot.fen),
        );

  /// Continuations from [currentFen]: moves actually played there, plus
  /// legal moves that land on a FEN the tree already has (one-ply
  /// transpositions). So after 1.d4 c5 2.e3, ...Nf6 appears if the
  /// database only has 1.d4 Nf6 2.e3 c5.
  @override
  List<PositionGroup> get continuations => continuationsAt(currentFen);

  /// See [continuations].
  ///
  /// The one-ply transposition scan only serialises a SAN for moves whose
  /// destination is actually in the book; the legal-move list itself is
  /// memoised per FEN, so a widget rebuild costs one map lookup per legal
  /// move rather than a move generation per legal move.
  @override
  List<PositionGroup> continuationsAt(String fen) {
    final bySan = <String, PositionGroup>{};
    final nodes = _nodesAt(fen);
    if (nodes != null) {
      for (final child in PositionGroup(nodes).children) {
        bySan[child.move] = child;
      }
    }
    final legal = _legalDestinations.lookup(fen);
    if (legal != null) {
      for (final dest in legal.destinations) {
        final destNodes = _nodesAt(dest.fen);
        if (destNodes == null) continue;
        final (_, san) = legal.position.makeSanUnchecked(dest.move);
        if (bySan.containsKey(san)) continue;
        bySan[san] = PositionGroup(
          destNodes,
          displayMove: san,
          viaTransposition: true,
        );
      }
    }
    return bySan.values.toList()
      ..sort((a, b) => b.gamesPlayed.compareTo(a.gamesPlayed));
  }

  /// Navigate to a child node by move.
  ///
  /// Transposition-aware: if the current path never continued with [move]
  /// but another path reaching the same position did, the cursor jumps to
  /// that path's child. If [move] itself was never played from here but
  /// lands on a known FEN (one-ply transposition), the cursor snaps there.
  bool makeMove(String move) {
    if (_offBookFen == null) {
      final child = _childByTransposition(currentNode, move);
      if (child != null) {
        currentNode = child;
        _walkedSans.add(move);
        return true;
      }
    }
    final target = _childByPlaying(currentFen, move);
    if (target == null) return false;
    currentNode = target;
    _offBookFen = null;
    _walkedSans.add(move);
    return true;
  }

  /// Navigate back along the walked path (the user's move order, not
  /// necessarily [currentNode.parent]'s book path).
  bool goBack() {
    if (_walkedSans.isEmpty) {
      final parent = currentNode.parent;
      if (parent == null) return false;
      currentNode = parent;
      return true;
    }
    final prefix = _walkedSans.sublist(0, _walkedSans.length - 1);
    syncToMoveHistory(prefix, startFen: cursorRoot.fen);
    return true;
  }

  /// Reset to the default root, or a specified chapter start position.
  void reset({String? startFen}) {
    final starts = startFen == null ? null : _nodesAt(startFen);
    cursorRoot = starts == null ? root : PositionGroup(starts).primaryNode;
    currentNode = cursorRoot;
    _walkedSans = [];
    _offBookFen = null;
  }

  /// Navigate to a position by FEN. When several paths (transpositions)
  /// reach it, the cursor lands on the most-played one.
  bool navigateToFen(String fen) {
    final nodes = _nodesAt(fen);
    if (nodes == null) return false;
    currentNode = PositionGroup(nodes).primaryNode;
    _offBookFen = null;
    _walkedSans = currentNode.getMovePath();
    var top = currentNode;
    while (true) {
      final parent = top.parent;
      if (parent == null) break;
      top = parent;
    }
    cursorRoot = top;
    return true;
  }

  /// Transposition-aware view of [node]'s position: the node itself plus any
  /// nodes reaching the same position via other move orders.
  PositionGroup groupFor(OpeningTreeNode node) {
    final indexed = _nodesAt(node.fen);
    if (indexed == null) return PositionGroup([node]);
    return PositionGroup(indexed.contains(node) ? indexed : [node, ...indexed]);
  }

  /// Transposition-aware view of the current position (FEN, not path).
  @override
  PositionGroup get currentGroup {
    final indexed = _nodesAt(currentFen);
    if (indexed != null) return PositionGroup(indexed);
    return PositionGroup([OpeningTreeNode(move: '', fen: currentFen)]);
  }

  /// Add a FEN to node mapping (idempotent — a node is indexed once even
  /// when re-visited by later games, so [PositionGroup] sums stay correct).
  void indexNode(OpeningTreeNode node) {
    final nodes = fenToNodes[normalizeFen(node.fen)] ??= [];
    if (!nodes.contains(node)) nodes.add(node);
  }

  /// The nodes indexed under [fen]'s position, or null when there are none.
  List<OpeningTreeNode>? _nodesAt(String fen) {
    final nodes = fenToNodes[normalizeFen(fen)];
    return nodes == null || nodes.isEmpty ? null : nodes;
  }

  /// Get total number of games in the tree (games at root)
  @override
  int get totalGames =>
      root.gamesPlayed +
      setupRoots.fold<int>(0, (total, node) => total + node.gamesPlayed);

  /// Get current depth in the tree (walked plies, including off-book).
  @override
  int get currentDepth => _walkedSans.length;

  /// Whether [san] is already a child of any node at [fen].
  @override
  bool hasMove(String fen, String san) {
    final key = normalizeFen(fen);
    final nodes = fenToNodes[key];
    if (nodes != null) {
      for (final node in nodes) {
        if (node.children.containsKey(san)) return true;
      }
    }
    return normalizeFen(root.fen) == key && root.children.containsKey(san);
  }

  /// Whether playing [san] from [fen] lands on a position this tree already
  /// covers — i.e. the move transposes into known territory rather than
  /// leaving it.
  ///
  /// [fenToNodes] is keyed by [normalizeFen], so this is a single map lookup.
  /// Returns `false` when [fen] is unparsable or [san] is illegal in it.
  @override
  bool doesMoveTranspose(String fen, String san) {
    // Best-effort; an unparsable position simply isn't a transposition.
    final next = _fenAfter(fen, san);
    return next != null && fenToNodes.containsKey(normalizeFen(next));
  }

  /// Whether [san] is a child along [pathFromRoot] (path-aware repertoire check).
  ///
  /// Read-only: does not move the cursor.  Callers ask this once per candidate
  /// row, and the previous implementation reset and re-walked the shared
  /// cursor every time.
  @override
  bool hasMoveOnPath(List<String> pathFromRoot, String san) =>
      nodeAtPath(pathFromRoot)?.children.containsKey(san) ?? false;

  /// The node reached by walking [sans] from the root with the same
  /// transposition rules as [makeMove], or null when the path leaves the
  /// tree.  Pure: the cursor is untouched.
  @override
  OpeningTreeNode? nodeAtPath(List<String> sans) {
    var node = root;
    for (final san in sans) {
      final next =
          _childByTransposition(node, san) ?? _childByPlaying(node.fen, san);
      if (next == null) return null;
      node = next;
    }
    return node;
  }

  /// [node]'s child for [san], or the child of any node sharing its position.
  OpeningTreeNode? _childByTransposition(OpeningTreeNode node, String san) {
    final direct = node.children[san];
    if (direct != null) return direct;
    for (final twin in _nodesAt(node.fen) ?? const <OpeningTreeNode>[]) {
      final child = twin.children[san];
      if (child != null) return child;
    }
    return null;
  }

  /// The most-played node on the position [san] lands on from [fen], when
  /// that position is in the book by another move order (a one-ply
  /// transposition).  Null when [fen] is unparsable, [san] is illegal or
  /// the move leaves the book.
  OpeningTreeNode? _childByPlaying(String fen, String san) {
    final next = _fenAfter(fen, san);
    if (next == null) return null;
    final destNodes = _nodesAt(next);
    return destNodes == null ? null : PositionGroup(destNodes).primaryNode;
  }

  /// FEN after playing [san] from [fen], or null when either is invalid.
  String? _fenAfter(String fen, String san) {
    final legal = _legalDestinations.lookup(fen);
    if (legal == null) return null;
    return playSanOrNullMove(legal.position, san)?.fen;
  }

  /// Append a single line of moves to the tree without rebuilding.
  /// Each move is walked node-by-node; new nodes are created as needed.
  void appendLine(List<String> moves) {
    appendLineFromFen(kStandardStartFen, moves);
  }

  /// Append moves starting from [startFen] (supports custom setup positions).
  void appendLineFromFen(String startFen, List<String> moves) {
    if (moves.isEmpty) return;

    Position position;
    OpeningTreeNode node;

    final nodesAtFen = _nodesAt(startFen);
    if (nodesAtFen != null) {
      node = PositionGroup(nodesAtFen).primaryNode;
      position = Chess.fromSetup(Setup.parseFen(node.fen));
    } else if (normalizeFen(startFen) == normalizeFen(kStandardStartFen)) {
      position = Chess.initial;
      node = root;
    } else {
      position = Chess.fromSetup(Setup.parseFen(startFen));
      node = root;
    }

    node.updateStats(null);

    for (final san in moves) {
      if (isNullMoveSan(san)) {
        final next = playSanOrNullMove(position, san);
        if (next == null) break;
        position = next;
        continue;
      }
      final move = position.parseSan(san);
      if (move == null) break;
      position = position.play(move);
      node = advance(node, san, position);
      node.updateStats(null);
    }
  }

  /// Step from [node] along [san] to the child for [positionAfter], creating
  /// and indexing it on first visit.
  ///
  /// This is the one way a walk should grow the tree: the FEN is serialised
  /// only for a *new* node, and [indexNode]'s membership scan runs only then.
  /// Doing both on every ply of every game — which the previous walkers did —
  /// was the dominant cost of loading a large collection.
  OpeningTreeNode advance(
    OpeningTreeNode node,
    String san,
    Position positionAfter,
  ) {
    final existing = node.children[san];
    if (existing != null) return existing;
    final child = node.getOrCreateChild(san, positionAfter.fen);
    indexNode(child);
    return child;
  }

  /// Put the cursor on the position reached by [sans], given the FEN after
  /// each ply ([fensAfter], same length).  The transposition-aware twin of
  /// [syncToMoveHistory] for callers that already hold the FENs — the
  /// repertoire editor stores one on every node — so the cursor moves without
  /// replaying the line through dartchess.
  ///
  /// Returns true when the final position is in the tree.
  bool syncToFens(List<String> sans, List<String> fensAfter) {
    assert(sans.length == fensAfter.length);
    reset();
    if (sans.isEmpty) return true;

    var lastOnBook = root;
    for (var i = 0; i < sans.length; i++) {
      _walkedSans.add(sans[i]);
      lastOnBook = _snapCursor(lastOnBook, sans[i], fensAfter[i]);
    }
    return inBook;
  }

  /// Walk [moves] from the root by playing them on the board, snapping the
  /// cursor to the tree whenever the resulting FEN is known.
  ///
  /// Unlike a SAN-prefix walk, this follows transpositions: 1.d4 c5 2.e3 Nf6
  /// lands on the same node as 1.d4 Nf6 2.e3 c5. Intermediate positions that
  /// are not in the tree leave the cursor off-book (so [continuations] can
  /// still offer one-ply transpositions) without aborting the rest of the
  /// line. Returns true when every move was legal *and* the final FEN is in
  /// the tree. An illegal SAN stops at the last legal ply.
  bool syncToMoveHistory(List<String> moves, {String? startFen}) {
    reset(startFen: startFen);
    if (moves.isEmpty) return true;

    final start = tryParseFen(cursorRoot.fen);
    if (start == null) return false;

    var position = start;
    var lastOnBook = cursorRoot;
    for (final san in moves) {
      final next = playSanOrNullMove(position, san);
      if (next == null) {
        currentNode = lastOnBook;
        return false;
      }
      position = next;
      _walkedSans.add(san);
      lastOnBook = _snapCursor(lastOnBook, san, position.fen);
    }
    return inBook;
  }

  /// One ply of a cursor sync: land on the most-played node for [fenAfter]
  /// when the tree has it; otherwise fall back to [lastOnBook]'s child for
  /// [san] (trees built with hand-written FENs, or a different en-passant
  /// convention, can miss the index while the child exists); otherwise stay
  /// on [lastOnBook] with the cursor off-book at [fenAfter].
  ///
  /// Returns the node the cursor is anchored to afterwards.
  OpeningTreeNode _snapCursor(
    OpeningTreeNode lastOnBook,
    String san,
    String fenAfter,
  ) {
    final destNodes = _nodesAt(fenAfter);
    final onBook = destNodes != null
        ? PositionGroup(destNodes).primaryNode
        : _childByTransposition(lastOnBook, san);
    if (onBook != null) {
      currentNode = onBook;
      _offBookFen = null;
      return onBook;
    }
    currentNode = lastOnBook;
    _offBookFen = fenAfter;
    return lastOnBook;
  }

  // ── Serialisation for isolate transfer ──────────────────────────────

  /// The tree as a JSON-compatible map with no object references, for
  /// sending across an isolate boundary.  See [OpeningTreeTransfer].
  Map<String, dynamic> toTransferJson() => OpeningTreeTransfer.encode(this);

  /// Reconstruct an [OpeningTree] from the flat map produced by
  /// [toTransferJson].
  factory OpeningTree.fromTransferJson(Map<String, dynamic> json) =>
      OpeningTreeTransfer.decode(json);
}
