/// Centralized repertoire session state shared across board, PGN, engine, and tree.
///
/// Owns a [MoveTree] and a [TreePath] cursor as the single source of truth.
/// All UI components derive their chess position from this class.
/// Navigation funnels through [jump] — there is no secondary state to sync.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../constants/chess_constants.dart';
import '../constants/engine_defaults.dart';
import '../models/move_tree.dart';
import '../models/opening_tree.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../models/repertoire_line.dart';
import '../models/repertoire_metadata.dart';
import '../services/games_repertoire/draft_repertoire_writer.dart';
import '../services/opening_tree_builder.dart';
import '../services/repertoire_service.dart';
import '../services/storage/storage_factory.dart';
import '../utils/fen_utils.dart';
import '../utils/movetext_builder.dart';
import '../utils/san_token_utils.dart';
import 'move_navigation.dart';
import 'repertoire_authoring.dart';
import 'repertoire_writer.dart';
import '../utils/safe_change_notifier.dart';
import '../utils/chess_utils.dart';

part 'repertoire_controller_persistence.dart';

// ---------------------------------------------------------------------------
// Isolate-safe top-level helper for parsing repertoire lines (used by compute)
// ---------------------------------------------------------------------------

List<RepertoireLine> _parseRepertoireInIsolate(
  ({String pgn, String color}) args,
) {
  final service = RepertoireService();
  return service.parseRepertoirePgn(args.pgn, trainingColor: args.color);
}

/// Manages repertoire state and acts as the single source of truth.
/// All UI components should derive their chess position from this class.
class RepertoireController
    with
        ChangeNotifier,
        MoveNavigation,
        SafeChangeNotifier,
        _RepertoirePersistence {
  @override
  late final RepertoireWriter writer = RepertoireWriter(this);

  /// Pure PGN-authoring collaborator (game/line construction).
  @override
  final RepertoireAuthoring _authoring = RepertoireAuthoring();

  @override
  RepertoireMetadata? _currentRepertoire;
  RepertoireMetadata? get currentRepertoire => _currentRepertoire;

  @override
  String? _repertoirePgn;
  String? get repertoirePgn => _repertoirePgn;

  @override
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
  @override
  List<RepertoireLine> get _repertoireLines => _lines;
  @override
  set _repertoireLines(List<RepertoireLine> value) {
    _lines = List.unmodifiable(value);
  }

  List<RepertoireLine> get repertoireLines => _lines;

  @override
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  @override
  String? _loadError;
  String? get loadError => _loadError;

  @override
  bool _isRepertoireWhite = true;
  bool get isRepertoireWhite => _isRepertoireWhite;

  bool _needsColorSelection = false;
  bool get needsColorSelection => _needsColorSelection;

  /// Root position move string (e.g. "1. d4 d5 2. c4") persisted in the PGN.
  String _rootMoves = '';
  String get rootMoves => _rootMoves;

  // ── Tree + path (single source of truth) ─────────────────────────

  /// The editable PGN move tree.
  MoveTree _tree = MoveTree();
  @override
  MoveTree get tree => _tree;

  TreePath _cursor = TreePath.empty;

  /// Cursor into [_tree].  Empty = starting position.
  ///
  /// Assigning this always re-syncs [_openingTree], so no caller can move the
  /// cursor and leave the opening-tree view pointing somewhere else.  Every
  /// assignment below sets [_tree] first, which the sync reads.
  TreePath get _path => _cursor;
  @override
  set _path(TreePath value) {
    _cursor = value;
    _syncOpeningTree();
  }

  @override
  TreePath get path => _cursor;

  // ── Derived state (backward-compatible getters) ──────────────────

  /// SAN sequence from root to cursor (replaces old _moveHistory getter).
  List<String> get moveHistory => _tree.sanSequenceAt(_path);

  /// Alias — always identical to [moveHistory] now.
  @override
  List<String> get currentMoveSequence => moveHistory;

  /// Ply index (replaces old _currentMoveIndex).
  int get currentMoveIndex => _path.length - 1;

  /// Board FEN at cursor.  O(1) — stored on each [MoveNode].
  String get fen => _tree.fenAt(_path);

  /// Derived position (lazy; most callers only need [fen]).
  Position get position => tryParseFen(fen) ?? Chess.initial;

  /// From/to squares of the last two half-moves at the cursor — the subtle
  /// Chessable-style recent-move trail for [ChessBoardWidget]. Empty at the
  /// starting position.
  Set<String> get recentMoveSquares {
    final len = _path.length;
    if (len == 0) return const {};
    final baseIdx = len >= 2 ? len - 2 : 0;
    try {
      final base = Chess.fromSetup(
        Setup.parseFen(_tree.fenAt(_path.take(baseIdx))),
      );
      return recentMoveTrailSquares(
        base,
        _tree.sanSequenceAt(_path).sublist(baseIdx),
      );
    } catch (_) {
      return const {};
    }
  }

  /// Starting FEN if different from standard position.
  String? get startingFen {
    final f = _tree.startingFen;
    return f == kStandardStartFen ? null : f;
  }

  /// SAN moves of the saved root position (empty when no root is saved).
  List<String> get rootMoveSans => _parsePgnMoveText(_rootMoves);

  /// FEN of the saved root position — the tree's starting position when no
  /// root is saved.
  String get rootFen {
    Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(_tree.startingFen));
    } catch (_) {
      pos = Chess.initial;
    }
    for (final san in rootMoveSans) {
      final next = playSanOrNullMove(pos, san);
      if (next == null) break;
      pos = next;
    }
    return pos.fen;
  }

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
    notifyListeners();
  }

  // ── Move entry ───────────────────────────────────────────────────

  /// Play a move from the current cursor position.
  ///
  /// If the SAN already exists as a child, jumps to it (no duplicate).
  /// Otherwise adds a new node and jumps.  Replaces the old
  /// the old `userPlayedMove*` wrappers and most uses of
  /// `userSelectedTreeMove`.
  void playMove(String sanMove) {
    final newPath = _tree.addMove(_path, sanMove);
    if (newPath != null) jump(newPath);
  }

  /// Play a move from an explicit tree position (for opening-tree clicks
  /// where the base is the tree widget's current node, not the controller
  /// cursor).  Equivalent to old `userSelectedTreeMove`.
  void playMoveAtTreePath(TreePath basePath, String sanMove) {
    final newPath = _tree.addMove(basePath, sanMove);
    if (newPath != null) jump(newPath);
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
  @override
  void navigateToLineMove(List<String> fullPath, {int? targetIndex}) {
    _ensureMovesInTree(fullPath);
    final tp = _pathForMoveSequence(fullPath);
    if (targetIndex != null && targetIndex >= 0 && targetIndex < tp.length) {
      jump(tp.take(targetIndex + 1));
    } else {
      jump(tp);
    }
  }

  /// Append [lineMoves] from the current position and jump to [lineMoveIndex].
  void applyLineFromCurrent(List<String> lineMoves, int lineMoveIndex) {
    if (lineMoves.isEmpty) return;
    final base = currentMoveSequence;
    final full = [...base, ...lineMoves];
    _ensureMovesInTree(full);
    final clamped = lineMoveIndex.clamp(0, lineMoves.length - 1);
    final tp = _pathForMoveSequence(full);
    jump(tp.take(base.length + clamped + 1));
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
    notifyListeners();
  }

  /// Clear the current line.
  void clearMoveHistory() {
    _annotatedLineLabel = null;
    _tree = MoveTree(startingFen: _tree.startingFen);
    _path = TreePath.empty;
    notifyListeners();
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
      notifyListeners();
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
      notifyListeners();
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
    notifyListeners();
  }

  /// Load a raw move sequence onto the board.
  void loadMoveSequence(List<String> moves) {
    _selectedPgnLine = null;
    _annotatedLineLabel = null;
    _tree = MoveTree.fromMoves(moves, startingFen: _tree.startingFen);
    _path = _tree.mainlineEndFrom(TreePath.empty);
    notifyListeners();
  }

  /// Human-readable label for the loaded annotated line (e.g. "Trap #45").
  /// Null whenever the tree came from a repertoire line or free navigation.
  String? _annotatedLineLabel;
  String? get annotatedLineLabel => _annotatedLineLabel;

  /// Load a pre-built tree (e.g. an annotated trap line) and place the
  /// cursor at [cursor], falling back to the mainline end when invalid.
  /// [label] is surfaced as the PGN pane title while the tree is shown.
  void loadAnnotatedTree(MoveTree tree, {TreePath? cursor, String? label}) {
    _selectedPgnLine = null;
    _annotatedLineLabel = label;
    _tree = tree;
    _path = cursor != null && tree.isValidPath(cursor)
        ? cursor
        : tree.mainlineEndFrom(TreePath.empty);
    notifyListeners();
  }

  /// Syncs the game state from the PGN editor (still needed during transition).
  void syncFromMoveIndex(int moveIndex, List<String> moves) {
    _ensureMovesInTree(moves);
    final tp = _pathForMoveSequence(moves);
    final target = moveIndex < 0
        ? TreePath.empty
        : tp.take((moveIndex + 1).clamp(0, tp.length));
    _path = target;
    notifyListeners();
  }

  // ── Tree mutation (for PGN editor actions) ───────────────────────

  /// Delete the subtree at [path] and adjust cursor.
  /// Pushes an undo snapshot so the deletion can be reverted with Ctrl+Z.
  void deleteAtPath(TreePath target) {
    if (!_tree.isValidPath(target)) return;

    final previousPgn = _repertoirePgn ?? '';
    final movePath = _tree.sanSequenceAt(target);
    writer.pushUndo(
      UndoOperation(
        previousPgn: previousPgn,
        treePathBeforeAdd: movePath.isEmpty
            ? []
            : movePath.sublist(0, movePath.length - 1),
        moveAdded: movePath.isNotEmpty ? movePath.last : '',
      ),
    );

    final newCursor = target.parent;
    _tree.deleteAt(target);
    _path = _tree.isValidPath(newCursor) ? newCursor : TreePath.empty;
    notifyListeners();
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
    _tree.promoteVariation(target);
    _path = _pathForMoveSequence(cursorSans);
    notifyListeners();
  }

  /// Union of every repertoire line's mainline moves as a single [MoveTree] —
  /// the "whole repertoire" view that draft diffing and merge planning need.
  /// (The working [tree] is only the currently loaded line, so it must never
  /// be used as a merge or comparison target.)
  MoveTree buildRepertoireMoveTree() {
    final out = MoveTree(startingFen: _tree.startingFen);
    for (final line in _repertoireLines) {
      var path = TreePath.empty;
      for (final san in line.moves) {
        final next = out.addMove(path, san);
        if (next == null) break;
        path = next;
      }
    }
    return out;
  }

  /// Append draft [lines] (SAN sequences from the repertoire root) to the
  /// repertoire file as titled PGN entries and reload. Lines ending on an
  /// opponent move are marked as gaps (title + final-move comment — see
  /// `draftLinesToPgnGames`) and counted in `needAnswer`. Returns zero counts
  /// when there is nothing to add or no file is loaded.
  Future<({int added, int needAnswer})> appendDraftLines(
    List<List<String>> lines, {
    required String sourceLabel,
  }) async {
    const nothing = (added: 0, needAnswer: 0);
    if (lines.isEmpty || _currentRepertoire == null) return nothing;

    final label = sourceLabel.replaceAll('"', '').trim();
    final source = label.isEmpty ? 'my games' : label;
    final content = draftLinesToPgnGames(
      lines,
      isWhite: _isRepertoireWhite,
      titlePrefix: 'From my games ($source)',
      startIndex: _repertoireLines.length,
    );
    if (content.isEmpty) return nothing;

    final added = await importPgnContent(content);
    if (added == 0) return nothing;
    final gaps = lines
        .where((l) => !lineEndsWithMyMove(l, isWhite: _isRepertoireWhite))
        .length;
    return (added: added, needAnswer: gaps);
  }

  /// Recursively promote a variation so it becomes the main line
  /// from the root down to [target].
  void makeMainLine(TreePath target) {
    if (target.isEmpty) return;
    final indices = target.toList();
    for (int depth = 0; depth < indices.length; depth++) {
      if (indices[depth] != 0) {
        final pathAtDepth = TreePath(indices.sublist(0, depth + 1));
        _tree.promoteVariation(pathAtDepth);
        indices[depth] = 0;
      }
    }
    _path = _pathForMoveSequence(moveHistory);
    notifyListeners();
  }

  /// Update comment on the node at [target].
  void setCommentAtPath(TreePath target, String? comment) {
    _tree.setComment(target, comment);
    notifyListeners();
  }

  /// Toggle a move-quality NAG glyph on the node at [target].
  void toggleNagAtPath(TreePath target, int nagId) {
    _tree.toggleNag(target, nagId);
    notifyListeners();
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

  /// Sync the opening tree to match current move sequence.
  void _syncOpeningTree() {
    if (_openingTree != null) {
      _openingTree!.syncToMoveHistory(currentMoveSequence);
    }
  }

  /// Ensure a SAN sequence exists in the tree (adding nodes as needed).
  void _ensureMovesInTree(List<String> moves) {
    var parentPath = TreePath.empty;
    for (final san in moves) {
      final result = _tree.addMove(parentPath, san);
      if (result == null) break;
      parentPath = result;
    }
  }

  /// Get the TreePath for a SAN sequence, assuming it exists in the tree.
  TreePath _pathForMoveSequence(List<String> moves) {
    final indices = <int>[];
    var siblings = _tree.roots;
    for (final san in moves) {
      var found = false;
      for (int i = 0; i < siblings.length; i++) {
        if (siblings[i].san == san) {
          indices.add(i);
          siblings = siblings[i].children;
          found = true;
          break;
        }
      }
      if (!found) break;
    }
    return TreePath(indices);
  }

  /// Parses a PGN move text string into SAN moves.
  List<String> _parsePgnMoveText(String movesStr) => cleanSanTokens(movesStr);

  /// If a root position is set, navigate to it so the tree starts there.
  @override
  void _navigateToRootPosition() {
    if (_rootMoves.isEmpty) return;
    final sanMoves = _parsePgnMoveText(_rootMoves);
    if (sanMoves.isEmpty) return;
    _ensureMovesInTree(sanMoves);
    _path = _pathForMoveSequence(sanMoves);
  }

  /// Converts a SAN move list to PGN move text.
  ///
  /// Move numbering starts from the tree's starting position, so
  /// black-to-move / mid-game roots get correct `N...` numbering instead of
  /// the old (wrong) assumption of White to move at move 1.
  @override
  String _movesToPgnMoveText(List<String> moves) {
    if (moves.isEmpty) return '';
    var startMoveNumber = 1;
    var whiteToMoveFirst = true;
    try {
      final setup = Setup.parseFen(_tree.startingFen);
      startMoveNumber = setup.fullmoves;
      whiteToMoveFirst = setup.turn == Side.white;
    } catch (_) {
      // Unparsable starting FEN — fall back to standard-start numbering.
    }
    return buildNumberedMovetext(
      moves,
      startMoveNumber: startMoveNumber,
      whiteToMoveFirst: whiteToMoveFirst,
    );
  }

  // ── PGN line management ──────────────────────────────────────────

  RepertoireLine? _selectedPgnLine;
  RepertoireLine? get selectedPgnLine => _selectedPgnLine;

  void clearSelectedPgnLine() {
    _selectedPgnLine = null;
    notifyListeners();
  }

  /// Deletes a line from the repertoire file and reloads.
  Future<bool> deleteLine(RepertoireLine line) async {
    if (_currentRepertoire == null) return false;
    final filePath = _currentRepertoire!.filePath;
    if (filePath.isEmpty) return false;

    final service = RepertoireService();
    final success = await service.deleteLine(filePath, line.id);
    if (!success) return false;

    if (_selectedPgnLine?.id == line.id) {
      _selectedPgnLine = null;
      _annotatedLineLabel = null;
      _tree = MoveTree(startingFen: _tree.startingFen);
      _path = TreePath.empty;
    }

    await loadRepertoire();
    return true;
  }

  /// Persist edits made to the currently selected line.
  Future<bool> updateSelectedLineContent(String newPgn) async {
    if (_selectedPgnLine == null || _currentRepertoire == null) return false;
    final filePath = _currentRepertoire!.filePath;
    if (filePath.isEmpty) return false;

    final lineId = _selectedPgnLine!.id;
    final service = RepertoireService();
    final success = await service.updateLineContent(filePath, lineId, newPgn);
    if (!success) return false;

    final idx = _repertoireLines.indexWhere((l) => l.id == lineId);
    if (idx != -1) {
      final old = _repertoireLines[idx];
      final parsed = PgnGame.parsePgn(newPgn);
      final newMoves = parsed.moves.mainline().map((n) => n.san).toList();
      final comments = <String, String>{};
      final moveNodes = parsed.moves.mainline().toList();
      for (int i = 0; i < moveNodes.length; i++) {
        final node = moveNodes[i];
        if (node.comments != null && node.comments!.isNotEmpty) {
          final c = node.comments!.join(' ').trim();
          if (c.isNotEmpty) comments[i.toString()] = c;
        }
      }
      // Swap in a fresh list: consumers (lines browser) rebuild their
      // display/search indexes only when the list identity changes.
      final updated = List.of(_repertoireLines);
      updated[idx] = RepertoireLine(
        id: old.id,
        name: old.name,
        moves: newMoves,
        color: old.color,
        startPosition: service.extractStartPositionFromPgn(newPgn),
        fullPgn: newPgn,
        comments: comments,
        headers: Map<String, String>.from(parsed.headers),
        importance: old.importance,
        chapter: old.chapter,
        isModelGame: old.isModelGame,
      );
      _repertoireLines = updated;
      _selectedPgnLine = updated[idx];
    }

    notifyListeners();
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

    if (notify) notifyListeners();
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
    notifyListeners();
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
      notifyListeners();
      return;
    }

    final fullPath = [...prefix, newMove];
    final pgnForLine = updatedPgnContent != null
        ? _authoring.extractLastGamePgn(updatedPgnContent)
        : RepertoireService().buildMinimalGamePgn(
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
}
