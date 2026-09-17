/// Centralized repertoire session state shared across board, PGN, engine, and tree.
///
/// Owns a [MoveTree] and a [TreePath] cursor as the single source of truth.
/// All UI components derive their chess position from this class.
/// Navigation funnels through [jump] — there is no secondary state to sync.
library;

import 'package:chess_auto_prep/chess_core/pgn/repertoire_headers.dart';
import 'package:chess_auto_prep/features/repertoires/models/loaded_repertoire.dart';

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../constants/chess_constants.dart';
import '../models/move_tree.dart';
import '../chess_core/moves/move_tree_projection_cache.dart';
import '../chess_core/moves/move_tree_snapshot.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import '../models/opening_tree.dart';
import '../models/repertoire_line.dart';
import '../features/repertoires/models/repertoire_metadata.dart';
import '../services/repertoire_line_expansion.dart';
import '../chess_core/pgn/repertoire_pgn_text.dart';
import '../features/repertoires/repositories/repertoire_document_repository.dart';
import '../features/repertoires/repositories/repertoire_decoder.dart';
import '../utils/fen_utils.dart';
import '../utils/san_token_utils.dart';
import 'move_navigation.dart';
import 'repertoire_authoring.dart';
import 'repertoire_writer.dart';
import '../utils/safe_change_notifier.dart';
import '../utils/chess_utils.dart';

/// Manages repertoire state and acts as the single source of truth.
/// All UI components should derive their chess position from this class.
class RepertoireController
    with ChangeNotifier, MoveNavigation, SafeChangeNotifier {
  RepertoireController({required this.documents, required this.decoder});

  final RepertoireDocumentRepository documents;
  final RepertoireDecoder decoder;
  late final RepertoireWriter writer = RepertoireWriter(
    this,
    documents: documents,
  );

  /// Pure PGN-authoring collaborator (game/line construction).
  final RepertoireAuthoring _authoring = RepertoireAuthoring();

  RepertoireMetadata? _currentRepertoire;
  RepertoireMetadata? get currentRepertoire => _currentRepertoire;

  String? _repertoirePgn;
  String? get repertoirePgn => _repertoirePgn;

  OpeningTree? _openingTree;
  OpeningTree? get openingTree => _openingTree;

  List<RepertoireLine> _lines = const [];

  /// The parsed lines of the loaded repertoire.
  ///
  /// Every assignment stores an unmodifiable copy, so the list can only ever
  /// be *replaced*, never edited in place.  That matters: consumers such as
  /// the lines browser and [OpeningTreeWidget] rebuild their display/search
  /// indexes only when the list *identity* changes, and an in-place `add` or
  /// `[i] =` would leave them showing stale rows.
  List<RepertoireLine> get _repertoireLines => _lines;
  set _repertoireLines(List<RepertoireLine> value) {
    _lines = List.unmodifiable(value);
  }

  List<RepertoireLine> get repertoireLines => _lines;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _loadError;
  String? get loadError => _loadError;

  bool _isRepertoireWhite = true;
  bool get isRepertoireWhite => _isRepertoireWhite;

  bool _needsColorSelection = false;
  bool get needsColorSelection => _needsColorSelection;

  /// Root position move string (e.g. "1. d4 d5 2. c4") persisted in the PGN.
  String _rootMoves = '';
  String get rootMoves => _rootMoves;

  // ── Tree + path (single source of truth) ─────────────────────────

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

  /// SAN history at the cursor.  Unmodifiable and identity-stable between
  /// cursor moves, so a widget can compare it by identity in
  /// `didUpdateWidget` and rebuild its derived state only when the cursor
  /// actually moved — the way lichess-mobile hands its UI immutable
  /// snapshots rather than fresh lists on every read.
  List<String> _moveHistory = const [];

  /// Cursor into [_tree].  Empty = starting position.
  ///
  /// Assigning this always re-syncs [_openingTree], so no caller can move the
  /// cursor and leave the opening-tree view pointing somewhere else.  Every
  /// assignment below sets [_tree] first, which the sync reads.
  TreePath get _path => _cursor;
  set _path(TreePath value) {
    _cursor = value;
    _cursorNodes = _tree.nodeListAt(value);
    _moveHistory = List.unmodifiable([for (final n in _cursorNodes) n.san]);
    _syncOpeningTree();
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
  /// recent-move trail for [ChessBoardWidget]. Empty at the starting
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
  List<String> get rootMoveSans => cleanSanTokens(_rootMoves);

  /// FEN of the saved root position — the tree's starting position when no
  /// root is saved.  Replayed once per (root moves, starting FEN) pair; it is
  /// read on every rebuild through [isAtRootPosition].
  String get rootFen {
    final cached = _rootFen;
    if (cached != null &&
        cached.rootMoves == _rootMoves &&
        cached.startingFen == _tree.startingFen) {
      return cached.fen;
    }
    var pos = _tree.startingPosition;
    for (final san in rootMoveSans) {
      final next = playSanOrNullMove(pos, san);
      if (next == null) break;
      pos = next;
    }
    final fen = pos.fen;
    _rootFen = (
      rootMoves: _rootMoves,
      startingFen: _tree.startingFen,
      fen: fen,
    );
    return fen;
  }

  ({String rootMoves, String startingFen, String fen})? _rootFen;

  /// Whether the cursor currently sits on the saved root position
  /// (move counters ignored, so transpositions count).
  bool get isAtRootPosition => normalizeFen(fen) == normalizeFen(rootFen);

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
    notifyListeners();
  }

  // ── Change classification ────────────────────────────────────────

  /// Bumped by every notification that is *not* a pure cursor move: a load,
  /// a tree replacement, an edit, a lines change, a loading-state flip.
  ///
  /// The screen rebuilds wholesale only when this changes; a cursor move
  /// reaches the zones that show the position through their own listeners.
  /// That is what keeps arrow-key navigation from rebuilding the toolbar,
  /// the bottom pane and everything else that does not show the board.
  int get structureVersion => _structureVersion;
  int _structureVersion = 0;

  void _notifyStructureChanged() {
    _structureVersion++;
    notifyListeners();
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
    _notifyStructureChanged();
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
      _notifyStructureChanged();
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
    _annotatedLineLabel = null;
    _tree = MoveTree.fromMoves(moves, startingFen: _tree.startingFen);
    _path = _tree.mainlineEndFrom(TreePath.empty);
    _notifyStructureChanged();
  }

  /// Clear the current line.
  void clearMoveHistory() {
    _annotatedLineLabel = null;
    _tree = MoveTree(startingFen: _tree.startingFen);
    _path = TreePath.empty;
    _notifyStructureChanged();
  }

  /// Set the board position from a FEN string.
  bool setPositionFromFen(String fen) {
    try {
      final trimmedFen = fen.trim();
      if (trimmedFen.isEmpty) return false;
      Chess.fromSetup(Setup.parseFen(trimmedFen));

      _tree = MoveTree(startingFen: trimmedFen);
      _path = TreePath.empty;
      _selectedPgnLine = null;
      _annotatedLineLabel = null;
      _notifyStructureChanged();
      return true;
    } catch (e) {
      debugPrint('Invalid FEN: $e');
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
      _tree = MoveTree.fromMoves(moves, startingFen: effStart);
      _path = _tree.mainlineEndFrom(TreePath.empty);
      _selectedPgnLine = null;
      _annotatedLineLabel = null;
      _notifyStructureChanged();
      return true;
    } catch (e) {
      debugPrint('Invalid move-history position: $e');
      return false;
    }
  }

  /// Loads a specific PGN line for editing.
  void loadPgnLine(RepertoireLine line) {
    _selectedPgnLine = line;
    _annotatedLineLabel = null;
    // Build from the full PGN so comments and variations survive — the same
    // comment-aware path the PGN viewer uses. Fall back to the flat SAN list
    // for lines that have no PGN text (e.g. synthesized suggestions).
    _tree = line.fullPgn.trim().isNotEmpty
        ? MoveTree.fromPgn(line.fullPgn, startingFen: line.startPosition.fen)
        : MoveTree.fromMoves(line.moves, startingFen: _tree.startingFen);
    _path = _tree.mainlineEndFrom(TreePath.empty);
    _notifyStructureChanged();
  }

  /// Load a raw move sequence onto the board.
  void loadMoveSequence(List<String> moves) {
    _selectedPgnLine = null;
    _annotatedLineLabel = null;
    _tree = MoveTree.fromMoves(moves, startingFen: _tree.startingFen);
    _path = _tree.mainlineEndFrom(TreePath.empty);
    _notifyStructureChanged();
  }

  /// Human-readable label for the loaded annotated line (e.g. "Trap #45").
  /// Null whenever the tree came from a repertoire line or free navigation.
  String? _annotatedLineLabel;
  String? get annotatedLineLabel => _annotatedLineLabel;

  /// Load a pre-built tree (e.g. an annotated trap line) and place the
  /// cursor at [cursor], falling back to the mainline end when invalid.
  /// [label] is surfaced as the PGN pane title while the tree is shown.
  /// Adoption detaches all mutable nodes/lists from the caller.
  void loadAnnotatedTree(MoveTree tree, {TreePath? cursor, String? label}) {
    _selectedPgnLine = null;
    _annotatedLineLabel = label;
    _tree = tree.copyWithFreshIds();
    _path = cursor != null && _tree.isValidPath(cursor)
        ? cursor
        : _tree.mainlineEndFrom(TreePath.empty);
    _notifyStructureChanged();
  }

  /// Syncs the game state from the PGN editor (still needed during transition).
  void syncFromMoveIndex(int moveIndex, List<String> moves) {
    _ensureMovesInTree(moves);
    final tp = _pathForMoveSequence(moves);
    final target = moveIndex < 0
        ? TreePath.empty
        : tp.take((moveIndex + 1).clamp(0, tp.length));
    _path = target;
    _notifyStructureChanged();
  }

  // ── Tree mutation (for PGN editor actions) ───────────────────────

  /// Delete the subtree at [path] and adjust cursor.
  /// Records a draft-only undo; this action does not write the chapter file.
  void deleteAtPath(TreePath target) {
    if (!_tree.isValidPath(target)) return;

    final before = _tree.toPgnMoveText();
    final startingFen = _tree.startingFen;
    final oldCursor = _path;
    final generation = _loadGeneration;
    final newCursor = target.parent;
    _treeProjection.changed(_tree, path: target.parent);
    _tree.deleteAt(target);
    _path = _tree.isValidPath(newCursor) ? newCursor : TreePath.empty;
    final after = _tree.toPgnMoveText();
    writer.recordDraftUndo(
      isCurrent: () =>
          _loadGeneration == generation && _tree.toPgnMoveText() == after,
      restore: () {
        _tree = MoveTree.fromPgn(before, startingFen: startingFen);
        _path = _tree.isValidPath(oldCursor) ? oldCursor : TreePath.empty;
        _notifyStructureChanged();
      },
    );
    _notifyStructureChanged();
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
    _notifyStructureChanged();
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
    _notifyStructureChanged();
  }

  /// Update comment on the node at [target].
  void setCommentAtPath(TreePath target, String? comment) {
    _treeProjection.changed(_tree, path: target);
    _tree.setComment(target, comment);
    _notifyStructureChanged();
  }

  /// Toggle a move-quality NAG glyph on the node at [target].
  void toggleNagAtPath(TreePath target, int nagId) {
    _treeProjection.changed(_tree, path: target);
    _tree.toggleNag(target, nagId);
    _notifyStructureChanged();
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

  /// Sync the opening tree to match the cursor.
  ///
  /// Every node on the path already holds its FEN, so the tree cursor is
  /// placed by FEN lookup rather than by replaying the line through
  /// dartchess on every jump.
  void _syncOpeningTree() {
    final tree = _openingTree;
    if (tree == null) return;
    tree.syncToFens(_moveHistory, [for (final n in _cursorNodes) n.fen]);
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
  void _navigateToRootPosition() {
    // A newly loaded repertoire always starts with fresh navigation state.
    // Without this reset, a repertoire that omits a Root comment inherits the
    // move path from whichever repertoire was loaded previously.
    //
    // Undo goes through here too, and resets the cursor on purpose: a restored
    // snapshot can hold entirely different lines from the ones on screen, so
    // the path the user was on may no longer mean anything. Both cases are
    // covered by tests in test/core/repertoire_controller_test.dart.
    _path = TreePath.empty;
    final sanMoves = rootMoveSans;
    if (sanMoves.isEmpty) return;
    _ensureMovesInTree(sanMoves);
    _path = _pathForMoveSequence(sanMoves);
  }

  /// The loaded repertoire's file, or null when there is no repertoire or
  /// it has no file to write to.
  String? get _repertoireFilePath {
    final path = _currentRepertoire?.filePath;
    return path == null || path.isEmpty ? null : path;
  }

  /// Forget the selected line and drop the editable tree.
  void _clearSelectionAndTree() {
    _selectedPgnLine = null;
    _annotatedLineLabel = null;
    _tree = MoveTree(startingFen: _tree.startingFen);
    _path = TreePath.empty;
  }

  // ── PGN line management ──────────────────────────────────────────

  RepertoireLine? _selectedPgnLine;
  RepertoireLine? get selectedPgnLine => _selectedPgnLine;

  void clearSelectedPgnLine() {
    _selectedPgnLine = null;
    _notifyStructureChanged();
  }

  /// Deletes a line from the repertoire file and reloads.
  Future<bool> deleteLine(RepertoireLine line) async {
    final filePath = _repertoireFilePath;
    if (filePath == null) return false;

    final generation = _loadGeneration;
    final success = await documents.deleteLine(
      filePath,
      line.id,
      expectedContent: line.fullPgn,
    );
    if (!success) return false;
    if (generation != _loadGeneration ||
        _currentRepertoire?.filePath != filePath) {
      return true;
    }

    if (_selectedPgnLine?.id == line.id) _clearSelectionAndTree();

    await loadRepertoire();
    return true;
  }

  /// Deletes several lines in one pass and reloads once.
  ///
  /// Returns how many were removed. Lines with no recorded position in the
  /// file are skipped rather than guessed at by id.
  Future<int> deleteLines(Iterable<RepertoireLine> lines) async {
    final filePath = _repertoireFilePath;
    if (filePath == null) return 0;

    final generation = _loadGeneration;
    final indexes = {
      for (final line in lines)
        if (line.gameIndex >= 0) line.gameIndex: line.fullPgn,
    };
    if (indexes.isEmpty) return 0;

    final removed = await documents.deleteLinesAt(filePath, indexes);
    if (removed == 0) return 0;
    if (generation != _loadGeneration ||
        _currentRepertoire?.filePath != filePath) {
      return removed;
    }

    _clearSelectionAndTree();
    await loadRepertoire();
    return removed;
  }

  VoidCallback? _pendingLineSave;
  Future<void> _lineSaveTail = Future.value();
  Object? _lineSaveFailure;

  /// The editor supplies its debounce flusher, or null once it is saved.
  /// Keeping this callback separate from persistence lets core await pending
  /// edits without depending on a widget or its lifecycle.
  void setPendingLineSave(VoidCallback? flush) => _pendingLineSave = flush;

  /// Await pending document edits without consuming a failure on a close retry.
  Future<void> flushDocumentForClose() =>
      _flushPendingLineSaves(retainFailure: true);
  Object get closeRevision => (
    _repertoireFilePath,
    _loadGeneration,
    _lineSaveTail,
    _lineSaveFailure,
    _pendingLineSave,
    _treeProjection.sessionFor(_tree),
    _tree.version,
  );

  Future<void> _flushPendingLineSaves({bool retainFailure = false}) async {
    final flush = _pendingLineSave;
    _pendingLineSave = null;
    flush?.call();
    await _lineSaveTail;
    final failure = _lineSaveFailure;
    if (!retainFailure) _lineSaveFailure = null;
    if (failure != null) {
      throw StateError('Could not save pending line edits: $failure');
    }
  }

  /// Capture a save destination before a debounced editor edit can outlive
  /// its chapter. A completed save may update the open chapter only if the
  /// same load generation is still displayed.
  Future<bool> Function(String)? get selectedLineSaver {
    final selected = _selectedPgnLine;
    final filePath = _repertoireFilePath;
    if (_isLoading || selected == null || filePath == null) return null;
    final lineId = selected.id;
    final generation = _loadGeneration;
    final originals = _lineOriginals;
    originals.putIfAbsent(lineId, () => selected.fullPgn);
    return (newPgn) => _updateLineContent(
      newPgn,
      filePath: filePath,
      lineId: lineId,
      generation: generation,
      originals: originals,
    );
  }

  /// Persist edits made to the currently selected line.
  Future<bool> updateSelectedLineContent(String newPgn) async {
    return await selectedLineSaver?.call(newPgn) ?? false;
  }

  Future<bool> _updateLineContent(
    String newPgn, {
    required String filePath,
    required String lineId,
    required int generation,
    required Map<String, String> originals,
  }) {
    final result = _lineSaveTail.then(
      (_) => _persistLineContent(
        newPgn,
        filePath: filePath,
        lineId: lineId,
        generation: generation,
        originals: originals,
      ),
    );
    _lineSaveTail = result.then<void>(
      (saved) {
        _lineSaveFailure = saved ? null : 'The original line is unavailable.';
      },
      onError: (Object error, StackTrace _) {
        _lineSaveFailure = error;
      },
    );
    return result;
  }

  Future<bool> _persistLineContent(
    String newPgn, {
    required String filePath,
    required String lineId,
    required int generation,
    required Map<String, String> originals,
  }) async {
    final success = await documents.updateLineContent(
      filePath,
      lineId,
      newPgn,
      expectedContent: originals[lineId]!,
    );
    if (success == null) return false;
    originals[lineId] = success;
    if (generation != _loadGeneration ||
        _currentRepertoire?.filePath != filePath) {
      return true;
    }

    final idx = _repertoireLines.indexWhere((l) => l.id == lineId);
    if (idx != -1) {
      // Swap in a fresh list: consumers (lines browser) rebuild their
      // display/search indexes only when the list identity changes.
      final updated = List.of(_repertoireLines);
      updated[idx] = _authoring.rebuildLine(updated[idx], success);
      _repertoireLines = updated;
      if (_selectedPgnLine?.id == lineId) {
        _selectedPgnLine = updated[idx];
      }
    }

    _notifyStructureChanged();
    return true;
  }

  /// Append a newly saved line to the in-memory tree and lines list.
  void appendNewLine(
    List<String> moves,
    String title,
    String pgnContent, {
    bool updateTree = true,
    bool notify = true,
  }) {
    final next = List.of(_repertoireLines);
    _appendLineInto(next, moves, title, pgnContent, updateTree: updateTree);
    _commitAppendedLines(next);

    if (notify) _notifyStructureChanged();
  }

  /// Append many lines with a single listener notification — generation can
  /// produce hundreds of lines and per-line notifies rebuild every listener
  /// each time.
  void appendNewLines(
    Iterable<({List<String> moves, String title, String pgn})> entries,
  ) {
    final next = List.of(_repertoireLines);
    var any = false;
    for (final e in entries) {
      _appendLineInto(next, e.moves, e.title, e.pgn, updateTree: true);
      any = true;
    }
    if (!any) return;
    _commitAppendedLines(next);
    _notifyStructureChanged();
  }

  /// Build one new line into [target] and mirror it into the opening tree.
  ///
  /// [target] is a scratch list, so a bulk append pays one list copy rather
  /// than one per entry.
  void _appendLineInto(
    List<RepertoireLine> target,
    List<String> moves,
    String title,
    String pgnContent, {
    required bool updateTree,
  }) {
    if (updateTree) {
      final startFen = startingFen ?? kStandardStartFen;
      _openingTree?.appendLineFromFen(startFen, moves);
    }

    target.add(
      _authoring.buildNewLine(
        moves: moves,
        title: title,
        pgnContent: pgnContent,
        index: target.length,
        isWhite: _isRepertoireWhite,
        existingIds: target.map((l) => l.id),
      ),
    );
  }

  /// Swap in the grown list and keep the metadata game count in step.
  void _commitAppendedLines(List<RepertoireLine> next) {
    _repertoireLines = next;
    if (_currentRepertoire != null) {
      _currentRepertoire = _currentRepertoire!.copyWith(gameCount: next.length);
    }
  }

  /// Extend an existing line after a one-click add.
  void appendMoveToExistingLine(
    List<String> prefix,
    String newMove, {
    String? updatedPgnContent,
  }) {
    if (updatedPgnContent != null) {
      _repertoirePgn = updatedPgnContent;
    }

    final startFen = startingFen ?? kStandardStartFen;
    _openingTree?.appendLineFromFen(startFen, [...prefix, newMove]);

    final lineIndex = _authoring.findLineIndexForPrefix(
      _repertoireLines,
      prefix,
    );
    if (lineIndex != null) {
      final next = List.of(_repertoireLines);
      next[lineIndex] = _authoring.extendLine(next[lineIndex], newMove);
      _repertoireLines = next;
      _notifyStructureChanged();
      return;
    }

    final fullPath = [...prefix, newMove];
    final pgnForLine = updatedPgnContent != null
        ? _authoring.extractLastGamePgn(updatedPgnContent)
        : buildMinimalGamePgn(
            fullPath,
            startingFen: startingFen,
            isWhiteRepertoire: _isRepertoireWhite,
          );
    appendNewLine(
      fullPath,
      _authoring.defaultLineTitle(fullPath),
      pgnForLine,
      updateTree: false,
    );
  }

  // ── Repertoire file lifecycle ────────────────────────────────────
  //
  // Loading is epoch-guarded: every entry point that replaces the repertoire
  // claims a generation up front, and whatever it computed is thrown away if
  // a newer claim landed while it was awaiting.  The derivation itself lives
  // in [RepertoireDecoder] precisely so the whole result can be discarded in
  // one place — see the note there.

  int _loadGeneration = 0;

  final List<Completer<void>> _loadCompleters = [];

  /// Test hook: invoked after the PGN bytes are read, before anything is
  /// derived from them, so overlapping loads can be sequenced.
  @visibleForTesting
  Future<void> Function()? debugAfterRepertoireRead;

  /// Test hook: invoked after the load is fully derived and before it is
  /// applied — the window a superseding load has to arrive in.
  @visibleForTesting
  Future<void> Function()? debugBeforeRepertoireApply;

  /// Sets a new repertoire and triggers loading.
  Future<void> setRepertoire(RepertoireMetadata repertoire) async {
    _currentRepertoire = repertoire;
    await loadRepertoire();
  }

  /// (Re)loads the PGN content for the current repertoire.
  Future<void> loadRepertoire() async {
    if (_currentRepertoire == null) return;
    final generation = ++_loadGeneration;
    final filePath = _currentRepertoire!.filePath;
    writer.clearUndoStack();
    _loadError = null;
    _setLoading(true);

    try {
      // Flush before reading, not when the widget receives the replacement
      // tree. A same-file reload or a quick A → B → A must read saved edits.
      await _flushPendingLineSaves();
      if (generation != _loadGeneration) return;
      final read = await documents.read(filePath);
      await debugAfterRepertoireRead?.call();
      if (generation != _loadGeneration) return;

      if (!read.exists) {
        _applyLoaded(LoadedRepertoire.missing);
        _resetTree();
        return;
      }

      final loaded = await decoder.build(
        read.pgn,
        fallbackIsWhite: _isRepertoireWhite,
      );
      await debugBeforeRepertoireApply?.call();
      if (generation != _loadGeneration) return;

      _applyLoaded(loaded);
      _resetTree();
      _navigateToRootPosition();
    } catch (e) {
      if (generation != _loadGeneration) return;
      _loadError = 'Failed to load repertoire: $e';
      debugPrint(_loadError);
      _applyLoaded(LoadedRepertoire.missing);
      _resetTree();
    } finally {
      if (generation == _loadGeneration) {
        _setLoading(false);
      }
    }
  }

  /// Restores repertoire state from a PGN snapshot (used by undo).
  ///
  /// Claims a load generation, so an in-flight [loadRepertoire] cannot land
  /// its half of a different repertoire on top of the restored one.
  Future<void> restoreRepertoireFromPgn(
    String pgnContent, {
    List<String>? syncPath,
  }) async {
    final generation = ++_loadGeneration;
    try {
      final loaded = await decoder.build(
        pgnContent.isEmpty ? null : pgnContent,
        fallbackIsWhite: _isRepertoireWhite,
      );
      await debugBeforeRepertoireApply?.call();
      if (generation != _loadGeneration) return;

      // Unlike a load this keeps the editable move tree: undo reverts the
      // saved PGN, not the nodes the user has navigated into.
      _applyLoaded(loaded);
      if (syncPath != null) {
        navigateToLineMove(syncPath);
      } else {
        _navigateToRootPosition();
      }
      _notifyStructureChanged();
    } finally {
      // Claiming the generation above suppressed the in-flight load's own
      // release, so this call owes any `awaitLoaded()` waiters theirs.
      if (generation == _loadGeneration && _isLoading) {
        _setLoading(false);
      }
    }
  }

  /// Swap in one [LoadedRepertoire] wholesale.
  ///
  /// [LoadedRepertoire.headers] is null when the PGN never parsed far enough
  /// to yield them (missing file, read failure, tree-build error); the current
  /// headers are then kept rather than reset to a guess.
  Map<String, String> _lineOriginals = {};

  void _applyLoaded(LoadedRepertoire loaded) {
    _lineOriginals = {for (final line in loaded.lines) line.id: line.fullPgn};
    _repertoirePgn = loaded.pgn;
    _openingTree = loaded.openingTree;
    _repertoireLines = loaded.lines;

    final headers = loaded.headers;
    if (headers != null) {
      _rootMoves = headers.rootMoves;
      _needsColorSelection = headers.needsColorSelection;
      _isRepertoireWhite = headers.isWhite;
    }
  }

  /// Drop the editable move tree and park the cursor at the start.
  void _resetTree() {
    _tree = MoveTree();
    _path = TreePath.empty;
  }

  /// Writes the color header to the PGN file and reloads.
  Future<void> setRepertoireColor(bool isWhite) async {
    if (_currentRepertoire == null) return;
    final filePath = _currentRepertoire!.filePath;
    final generation = _loadGeneration;

    final colorLabel = isWhite ? 'White' : 'Black';
    final existing = (await documents.read(filePath)).pgn;
    if (existing == null) {
      throw StateError('The selected chapter is unavailable.');
    }
    final updated = upsertMetadataComment(existing, '// Color:', colorLabel);
    await documents.replace(filePath, updated, expectedContent: existing);
    if (_loadGeneration != generation ||
        _currentRepertoire?.filePath != filePath) {
      return;
    }
    _needsColorSelection = false;
    await loadRepertoire();
  }

  /// Sets the current move sequence as the root position and persists it.
  Future<void> setRootPosition() async {
    if (_currentRepertoire == null) return;
    final filePath = _currentRepertoire!.filePath;
    final generation = _loadGeneration;

    final moveText = _authoring.numberedMovetext(
      currentMoveSequence,
      startingFen: _tree.startingFen,
    );
    final existing = (await documents.read(filePath)).pgn;
    if (existing == null) {
      throw StateError('The selected chapter is unavailable.');
    }
    final updated = upsertMetadataComment(existing, '// Root:', moveText);
    await documents.replace(filePath, updated, expectedContent: existing);
    if (_loadGeneration != generation ||
        _currentRepertoire?.filePath != filePath) {
      return;
    }
    _rootMoves = moveText;
    _notifyStructureChanged();
  }

  /// Imports PGN content into the current repertoire file.
  Future<int> importPgnContent(String pgnContent) async {
    if (_currentRepertoire == null) return 0;

    final filePath = _currentRepertoire!.filePath;
    final generation = _loadGeneration;

    // One game per line, the same way a new repertoire is seeded: a pasted
    // study's variations become lines of their own, or the trainer and this
    // screen's line list would never see them.
    final expanded = expandVariationsIntoLines(pgnContent);
    final gameCount = expanded.gameCount;

    final existing = (await documents.read(filePath)).pgn;
    if (existing == null) {
      throw StateError('The selected chapter is unavailable.');
    }
    final separator = existing.endsWith('\n\n')
        ? ''
        : existing.endsWith('\n')
        ? '\n'
        : '\n\n';
    await documents.replace(
      filePath,
      '$existing$separator${expanded.pgn}\n',
      expectedContent: existing,
    );

    if (_loadGeneration == generation &&
        _currentRepertoire?.filePath == filePath) {
      await loadRepertoire();
    }

    return gameCount > 0 ? gameCount : 1;
  }

  /// Returns a Future that completes when the current load finishes.
  /// Resolves immediately if no load is in progress.
  Future<void> awaitLoaded() {
    if (!_isLoading) return Future.value();
    final c = Completer<void>();
    _loadCompleters.add(c);
    return c.future;
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    if (!loading) {
      for (final c in _loadCompleters) {
        c.complete();
      }
      _loadCompleters.clear();
    }
    _notifyStructureChanged();
  }
}
