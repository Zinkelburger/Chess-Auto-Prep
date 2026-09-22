import 'package:dartchess/dartchess.dart';

import '../../../chess_core/moves/move_tree_projection_cache.dart';
import '../../../chess_core/moves/move_tree_snapshot.dart';
import '../../../chess_core/moves/tree_path.dart';
import '../../../constants/chess_constants.dart';
import '../../../chess_core/moves/move_navigation.dart';
import '../../../models/move_tree.dart';
import '../../../models/repertoire_line.dart';
import '../../../utils/chess_utils.dart';
import '../../../utils/fen_utils.dart';
import '../../../utils/san_token_utils.dart';

/// Private mutable board state and immutable projections. No Flutter, storage,
/// document loading. Notifications publish completed commands synchronously.
class RepertoireBoardController with MoveNavigation {
  final Set<void Function()> _listeners = {};
  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _notify() {
    for (final listener in List.of(_listeners)) {
      if (_listeners.contains(listener)) listener();
    }
  }

  void dispose() => _listeners.clear();

  Object _session = Object();
  int _revision = 0;
  int _structureVersion = 0;
  int get revision => _revision;
  int get structureVersion => _structureVersion;
  Object get closeRevision =>
      (_treeProjection.sessionFor(_tree), _tree.version);

  void _markStructureChanged() {
    _structureVersion++;
    _revision++;
    _notify();
  }

  void reset() {
    final next = MoveTree();
    _session = Object();
    _tree = next;
    _path = TreePath.empty;
    _markStructureChanged();
  }

  /// The mutable draft is private; widgets only receive detached values.
  MoveTree _tree = MoveTree();
  final _treeProjection = MoveTreeProjectionCache();
  @override
  MoveTreeSnapshot get tree => _treeProjection.read(_tree);

  TreePath _cursor = TreePath.empty;

  /// The nodes from the root to the cursor, refreshed with every cursor
  /// assignment.  Everything derived from the cursor — the SAN history, the
  /// FENs, the position — reads off this list, so a navigation costs one
  /// O(depth) pointer walk and every later read is free.
  List<MoveNode> _cursorNodes = const [];
  List<String> _cursorFens = const [];
  List<String> get cursorFens => _cursorFens;

  /// SAN history at the cursor.  Unmodifiable and identity-stable between
  /// cursor moves, so a widget can compare it by identity in
  /// `didUpdateWidget` and rebuild its derived state only when the cursor
  /// actually moved — the way lichess-mobile hands its UI immutable
  /// snapshots rather than fresh lists on every read.
  List<String> _moveHistory = const [];

  /// Cursor into [_tree].  Empty = starting position.
  ///
  /// Assignment refreshes the immutable SAN/FEN path used by the host to
  /// synchronize its opening graph without replaying the game.
  TreePath get _path => _cursor;
  set _path(TreePath value) {
    _cursor = value;
    _cursorNodes = _tree.nodeListAt(value);
    _moveHistory = List.unmodifiable([for (final n in _cursorNodes) n.san]);
    _cursorFens = List.unmodifiable([for (final n in _cursorNodes) n.fen]);
  }

  @override
  TreePath get path => _cursor;

  // ── Derived state (backward-compatible getters) ──────────────────

  /// SAN sequence from root to cursor.  See [_moveHistory] for why this is
  /// one stable list rather than a fresh copy per read.
  List<String> get moveHistory => _moveHistory;

  /// Alias — always identical to [moveHistory] now.
  List<String> get currentMoveSequence => moveHistory;

  /// Ply index (replaces old _currentMoveIndex).
  int get currentMoveIndex => _path.length - 1;

  /// Board FEN at cursor.  O(1) — stored on each [MoveNode].
  String get fen =>
      _cursorNodes.isEmpty ? _tree.startingFen : _cursorNodes.last.fen;

  /// Position at the cursor.  Read off the node, which parses its FEN at
  /// most once; never re-parsed per read.
  Position get position => _cursorNodes.isEmpty
      ? _tree.startingPosition
      : _cursorNodes.last.position;

  /// From/to squares of the last [lastN] half-moves at the cursor — the
  /// recent-move trail for the board. Empty at the starting
  /// position. Defaults to the single move that produced the position; the
  /// trainer asks for 2 so your move and the reply are both marked.
  Set<String> recentMoveTrail({int lastN = 1}) {
    final len = _path.length;
    if (len == 0) return const {};
    final baseIdx = len > lastN ? len - lastN : 0;
    final base = baseIdx == 0
        ? _tree.startingPosition
        : _cursorNodes[baseIdx - 1].position;
    return recentMoveTrailSquares(
      base,
      _moveHistory.sublist(baseIdx),
      lastN: lastN,
    );
  }

  /// Starting FEN if different from standard position.
  String? get startingFen {
    final f = _tree.startingFen;
    return f == kStandardStartFen ? null : f;
  }

  /// SAN moves of the saved root position (empty when no root is saved).
  List<String> rootMoveSans(String rootMoves) => cleanSanTokens(rootMoves);

  /// FEN of the saved root position — the tree's starting position when no
  /// root is saved.  Replayed once per (root moves, starting FEN) pair; it is
  /// read on every rebuild through [isAtRootPosition].
  String rootFen(String rootMoves) {
    final cached = _rootFen;
    if (cached != null &&
        cached.rootMoves == rootMoves &&
        cached.startingFen == _tree.startingFen) {
      return cached.fen;
    }
    var pos = _tree.startingPosition;
    for (final san in rootMoveSans(rootMoves)) {
      final next = playSanOrNullMove(pos, san);
      if (next == null) break;
      pos = next;
    }
    final fen = pos.fen;
    _rootFen = (rootMoves: rootMoves, startingFen: _tree.startingFen, fen: fen);
    return fen;
  }

  ({String rootMoves, String startingFen, String fen})? _rootFen;

  /// Whether the cursor currently sits on the saved root position
  /// (move counters ignored, so transpositions count).
  bool isAtRootPosition(String rootMoves) =>
      normalizeFen(fen) == normalizeFen(rootFen(rootMoves));

  // ── Navigation (single entry point) ──────────────────────────────

  /// Jump the cursor to [target].  All navigation funnels here.
  /// (goBack / goForward / goToStart / goToEnd come from [MoveNavigation].)
  @override
  void jump(TreePath target) {
    if (_path == target) return;
    if (!_tree.isValidPath(target)) return;
    _path = target;
    // A pure cursor move: listeners that only care about structure can
    // compare [structureVersion] and skip their rebuild.
    _revision++;
    _notify();
  }

  // ── Move entry ───────────────────────────────────────────────────

  /// Play a move from the current cursor position.
  ///
  /// If the SAN already exists as a child, jumps to it (no duplicate).
  /// Otherwise adds a new node and jumps.  Replaces the old
  /// the old `userPlayedMove*` wrappers and most uses of
  /// `userSelectedTreeMove`.
  void playMove(String sanMove) => playMoveAtTreePath(_path, sanMove);

  /// Play a move from an explicit tree position (for opening-tree clicks
  /// where the base is the tree widget's current node, not the controller
  /// cursor).  Equivalent to old `userSelectedTreeMove`.
  void playMoveAtTreePath(TreePath basePath, String sanMove) {
    final versionBefore = _tree.version;
    _treeProjection.changed(_tree, path: basePath);
    final newPath = _tree.addMove(basePath, sanMove);
    if (newPath == null) return;
    if (_tree.version == versionBefore) {
      jump(newPath); // An existing move: a pure cursor move.
      return;
    }
    _path = newPath;
    _markStructureChanged();
  }

  /// Called when user selects a move in the opening tree.
  ///
  /// Plays from the repertoire cursor (the board), not the opening-tree
  /// node's book path, so a one-ply transposition keeps the user's move
  /// order (1.d4 c5 2.e3 Nf6 rather than jumping to 1.d4 Nf6 2.e3 c5).
  void userSelectedTreeMove(String sanMove) {
    playMove(sanMove);
  }

  /// Atomically navigate to a specific position within a line.
  void navigateToLineMove(List<String> fullPath, {int? targetIndex}) {
    final versionBefore = _tree.version;
    _ensureMovesInTree(fullPath);
    final tp = _pathForMoveSequence(fullPath);
    final target =
        targetIndex != null && targetIndex >= 0 && targetIndex < tp.length
        ? tp.take(targetIndex + 1)
        : tp;
    _jumpAfterLineEntry(target, versionBefore);
  }

  /// Append [lineMoves] from the current position and jump to [lineMoveIndex].
  void applyLineFromCurrent(List<String> lineMoves, int lineMoveIndex) {
    if (lineMoves.isEmpty) return;
    final base = currentMoveSequence;
    final full = [...base, ...lineMoves];
    final versionBefore = _tree.version;
    _ensureMovesInTree(full);
    final clamped = lineMoveIndex.clamp(0, lineMoves.length - 1);
    final tp = _pathForMoveSequence(full);
    _jumpAfterLineEntry(tp.take(base.length + clamped + 1), versionBefore);
  }

  void _jumpAfterLineEntry(TreePath target, int versionBefore) {
    if (_tree.version == versionBefore) {
      jump(target);
    } else {
      _path = target;
      _markStructureChanged();
    }
  }

  /// Jump to a specific move index in the history.
  void jumpToMoveIndex(int index) {
    if (index < -1) return;
    if (index == -1) {
      jump(TreePath.empty);
      return;
    }
    final clamped = index.clamp(0, _path.length - 1);
    jump(_path.take(clamped + 1));
  }

  // ── Line / sequence loading ──────────────────────────────────────

  /// Replace current history with provided moves.
  void loadMoveHistory(List<String> moves) {
    final next = MoveTree.fromMoves(moves, startingFen: _tree.startingFen);
    _session = Object();
    _tree = next;
    _path = _tree.mainlineEndFrom(TreePath.empty);
    _markStructureChanged();
  }

  /// Clear the current line.
  void clearMoveHistory() {
    final next = MoveTree(startingFen: _tree.startingFen);
    _session = Object();
    _tree = next;
    _path = TreePath.empty;
    _markStructureChanged();
  }

  /// Set the board position from a FEN string.
  bool setPositionFromFen(String fen) {
    try {
      final trimmedFen = fen.trim();
      if (trimmedFen.isEmpty) return false;
      Chess.fromSetup(Setup.parseFen(trimmedFen));

      final next = MoveTree(startingFen: trimmedFen);
      _session = Object();
      _tree = next;
      _path = TreePath.empty;
      _markStructureChanged();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Set the position from a move path, preserving history for PGN/tree sync.
  bool setPositionFromMoveHistory({
    required String fen,
    required List<String> moves,
    String? startingFen,
  }) {
    try {
      final trimmedFen = fen.trim();
      if (trimmedFen.isEmpty) return false;
      Chess.fromSetup(Setup.parseFen(trimmedFen));

      final effStart = _normalizeStartingFen(startingFen) ?? kStandardStartFen;
      Chess.fromSetup(Setup.parseFen(effStart));
      final next = MoveTree.fromMoves(moves, startingFen: effStart);
      _session = Object();
      _tree = next;
      _path = _tree.mainlineEndFrom(TreePath.empty);
      _markStructureChanged();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Loads a specific PGN line for editing.
  void loadPgnLine(RepertoireLine line) {
    // Build from the full PGN so comments and variations survive — the same
    // comment-aware path the PGN viewer uses. Fall back to the flat SAN list
    // for lines that have no PGN text (e.g. synthesized suggestions).
    final next = line.fullPgn.trim().isNotEmpty
        ? MoveTree.fromPgn(line.fullPgn, startingFen: line.startPosition.fen)
        : MoveTree.fromMoves(line.moves, startingFen: _tree.startingFen);
    _session = Object();
    _tree = next;
    _path = _tree.mainlineEndFrom(TreePath.empty);
    _markStructureChanged();
  }

  /// Load a raw move sequence onto the board.
  void loadMoveSequence(List<String> moves) {
    final next = MoveTree.fromMoves(moves, startingFen: _tree.startingFen);
    _session = Object();
    _tree = next;
    _path = _tree.mainlineEndFrom(TreePath.empty);
    _markStructureChanged();
  }

  /// Load a pre-built tree (e.g. an annotated trap line) and place the
  /// cursor at [cursor], falling back to the mainline end when invalid.
  /// Adoption detaches all mutable nodes/lists from the caller.
  void loadAnnotatedTree(MoveTree tree, {TreePath? cursor}) {
    final next = tree.copyWithFreshIds();
    _session = Object();
    _tree = next;
    _path = cursor != null && _tree.isValidPath(cursor)
        ? cursor
        : _tree.mainlineEndFrom(TreePath.empty);
    _markStructureChanged();
  }

  /// Syncs the game state from the PGN editor (still needed during transition).
  void syncFromMoveIndex(int moveIndex, List<String> moves) {
    _ensureMovesInTree(moves);
    final tp = _pathForMoveSequence(moves);
    final target = moveIndex < 0
        ? TreePath.empty
        : tp.take((moveIndex + 1).clamp(0, tp.length));
    _path = target;
    _markStructureChanged();
  }

  // ── Tree mutation (for PGN editor actions) ───────────────────────

  /// Delete a subtree and return an opaque receipt bound to this adoption.
  RepertoireDraftEdit? deleteAtPath(TreePath target) {
    if (!_tree.isValidPath(target)) return null;
    final before = _tree.toPgnMoveText();
    final startingFen = _tree.startingFen;
    final oldCursor = _path;
    _treeProjection.changed(_tree, path: target.parent);
    _tree.deleteAt(target);
    _path = target.parent;
    _markStructureChanged();
    return RepertoireDraftEdit._(
      _session,
      before,
      _tree.toPgnMoveText(),
      startingFen,
      oldCursor,
    );
  }

  bool canRestore(RepertoireDraftEdit edit) =>
      identical(edit._session, _session) &&
      _tree.toPgnMoveText() == edit._after;

  bool restore(RepertoireDraftEdit edit) {
    if (!canRestore(edit)) return false;
    _tree = MoveTree.fromPgn(edit._before, startingFen: edit._startingFen);
    _path = _tree.isValidPath(edit._cursor) ? edit._cursor : TreePath.empty;
    _markStructureChanged();
    return true;
  }

  /// Promote variation at [target] to mainline.
  ///
  /// Promotion reorders a sibling group, so *every* index-based path into that
  /// group stops meaning what it meant — not just [target]'s.  A cursor parked
  /// on an earlier sibling would silently come to point at a different move.
  /// Remember the cursor as a move sequence and re-resolve it afterwards,
  /// which is stable under any reordering.
  void promoteVariation(TreePath target) {
    final cursorSans = _tree.sanSequenceAt(_path);
    _treeProjection.changed(_tree, path: target.parent);
    _tree.promoteVariation(target);
    _path = _pathForMoveSequence(cursorSans);
    _markStructureChanged();
  }

  /// Recursively promote a variation so it becomes the main line
  /// from the root down to [target].
  void makeMainLine(TreePath target) {
    if (target.isEmpty) return;
    final indices = target.toList();
    for (int depth = 0; depth < indices.length; depth++) {
      if (indices[depth] != 0) {
        final pathAtDepth = TreePath(indices.sublist(0, depth + 1));
        _treeProjection.changed(_tree, path: pathAtDepth.parent);
        _tree.promoteVariation(pathAtDepth);
        indices[depth] = 0;
      }
    }
    _path = _pathForMoveSequence(moveHistory);
    _markStructureChanged();
  }

  /// Update comment on the node at [target].
  void setCommentAtPath(TreePath target, String? comment) {
    _treeProjection.changed(_tree, path: target);
    _tree.setComment(target, comment);
    _markStructureChanged();
  }

  /// Toggle a move-quality NAG glyph on the node at [target].
  void toggleNagAtPath(TreePath target, int nagId) {
    _treeProjection.changed(_tree, path: target);
    _tree.toggleNag(target, nagId);
    _markStructureChanged();
  }

  // ── Private helpers ──────────────────────────────────────────────

  String? _normalizeStartingFen(String? fen) {
    final trimmedFen = fen?.trim();
    if (trimmedFen == null ||
        trimmedFen.isEmpty ||
        trimmedFen == kStandardStartFen) {
      return null;
    }
    return trimmedFen;
  }

  /// Ensure a SAN sequence exists in the tree (adding nodes as needed).
  void _ensureMovesInTree(List<String> moves) {
    _treeProjection.changed(_tree, path: _tree.pathForSans(moves));
    var parentPath = TreePath.empty;
    for (final san in moves) {
      final result = _tree.addMove(parentPath, san);
      if (result == null) break;
      parentPath = result;
    }
  }

  /// Get the TreePath for a SAN sequence, assuming it exists in the tree.
  TreePath _pathForMoveSequence(List<String> moves) => _tree.pathForSans(moves);

  /// If a root position is set, navigate to it so the tree starts there.
  void navigateToRootPosition(String rootMoves) {
    // A newly loaded repertoire always starts with fresh navigation state.
    // Without this reset, a repertoire that omits a Root comment inherits the
    // move path from whichever repertoire was loaded previously.
    //
    // Undo goes through here too, and resets the cursor on purpose: a restored
    // snapshot can hold entirely different lines from the ones on screen, so
    // the path the user was on may no longer mean anything. Both cases are
    // covered by tests in test/features/repertoires/repertoire_controller_test.dart.
    final version = _tree.version;
    _path = TreePath.empty;
    final sanMoves = rootMoveSans(rootMoves);
    if (sanMoves.isEmpty) {
      _revision++;
      _notify();
      return;
    }
    _ensureMovesInTree(sanMoves);
    _path = _pathForMoveSequence(sanMoves);
    if (_tree.version != version) {
      _markStructureChanged();
    } else {
      _revision++;
      _notify();
    }
  }
}

/// Only the originating board adoption can validate and restore this receipt.
class RepertoireDraftEdit {
  const RepertoireDraftEdit._(
    this._session,
    this._before,
    this._after,
    this._startingFen,
    this._cursor,
  );
  final Object _session;
  final String _before;
  final String _after;
  final String _startingFen;
  final TreePath _cursor;
}
