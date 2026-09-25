/// Centralized repertoire session state shared across board, PGN, engine, and tree.
///
/// Coordinates document loading/writing with a pure [RepertoireBoardController].
/// UI components read immutable board projections through this notifier.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../../chess_core/moves/move_navigation.dart';
import '../../../chess_core/moves/move_tree_snapshot.dart';
import '../../../chess_core/moves/tree_path.dart';
import '../../../chess_core/pgn/repertoire_headers.dart';
import '../../../chess_core/pgn/repertoire_line_expansion.dart';
import '../../../chess_core/pgn/repertoire_pgn_text.dart';
import '../../../constants/chess_constants.dart';
import '../../../models/move_tree.dart';
import '../../../models/opening_tree.dart';
import '../../../models/repertoire_line.dart';
import '../../../utils/safe_change_notifier.dart';
import '../../../utils/san_token_utils.dart';
import '../models/loaded_repertoire.dart';
import '../models/repertoire_authoring.dart';
import '../models/repertoire_metadata.dart';
import '../repositories/repertoire_decoder.dart';
import '../repositories/repertoire_document_repository.dart';
import 'repertoire_board_controller.dart';
import 'repertoire_line_edits.dart';
import 'repertoire_writer.dart';

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
  final RepertoireAuthoring _authoring = const RepertoireAuthoring();

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

  bool _boardFlipped = false;
  bool get boardFlipped => _boardFlipped;
  void setBoardFlipped(bool value) {
    if (_boardFlipped == value) return;
    _boardFlipped = value;
    _notifyStructureChanged();
  }

  bool _needsColorSelection = false;
  bool get needsColorSelection => _needsColorSelection;

  /// Root position move string (e.g. "1. d4 d5 2. c4") persisted in the PGN.
  String _rootMoves = '';
  String get rootMoves => _rootMoves;

  final RepertoireBoardController _board = RepertoireBoardController();
  @override
  MoveTreeSnapshot get tree => _board.tree;
  @override
  TreePath get path => _board.path;
  List<String> get moveHistory => _board.moveHistory;
  List<String> get currentMoveSequence => moveHistory;
  int get currentMoveIndex => _board.currentMoveIndex;
  String get fen => _board.fen;
  Position get position => _board.position;
  String? get startingFen => _board.startingFen;
  List<String> get rootMoveSans => cleanSanTokens(_rootMoves);
  String get rootFen => _board.rootFen(_rootMoves);
  bool get isAtRootPosition => _board.isAtRootPosition(_rootMoves);
  Set<String> recentMoveTrail({int lastN = 1}) =>
      _board.recentMoveTrail(lastN: lastN);

  int _structureVersion = 0;
  int get structureVersion => _structureVersion;
  void _notifyStructureChanged() {
    _structureVersion++;
    notifyListeners();
  }

  /// The pure owner finishes the command before the host exposes its state.
  void _changeBoard(void Function() action) {
    final revision = _board.revision;
    final structure = _board.structureVersion;
    action();
    if (_board.revision == revision) return;
    _syncOpeningTree();
    if (_board.structureVersion != structure) {
      _notifyStructureChanged();
    } else {
      notifyListeners();
    }
  }

  void _syncOpeningTree() =>
      _openingTree?.syncToFens(_board.moveHistory, _board.cursorFens);

  @override
  void jump(TreePath target) => _changeBoard(() => _board.jump(target));
  void playMove(String san) => _changeBoard(() => _board.playMove(san));
  void playMoveAtTreePath(TreePath path, String san) =>
      _changeBoard(() => _board.playMoveAtTreePath(path, san));
  void userSelectedTreeMove(String san) => playMove(san);
  void navigateToLineMove(List<String> moves, {int? targetIndex}) =>
      _changeBoard(
        () => _board.navigateToLineMove(moves, targetIndex: targetIndex),
      );
  void applyLineFromCurrent(List<String> moves, int index) =>
      _changeBoard(() => _board.applyLineFromCurrent(moves, index));
  void jumpToMoveIndex(int index) =>
      _changeBoard(() => _board.jumpToMoveIndex(index));

  void loadMoveHistory(List<String> moves) {
    _annotatedLineLabel = null;
    _changeBoard(() => _board.loadMoveHistory(moves));
  }

  void clearMoveHistory() {
    _annotatedLineLabel = null;
    _changeBoard(_board.clearMoveHistory);
  }

  bool setPositionFromFen(String fen) {
    var accepted = false;
    _changeBoard(() {
      accepted = _board.setPositionFromFen(fen);
      if (accepted) {
        _selectedPgnLine = null;
        _annotatedLineLabel = null;
      }
    });
    return accepted;
  }

  bool setPositionFromMoveHistory({
    required String fen,
    required List<String> moves,
    String? startingFen,
  }) {
    var accepted = false;
    _changeBoard(() {
      accepted = _board.setPositionFromMoveHistory(
        fen: fen,
        moves: moves,
        startingFen: startingFen,
      );
      if (accepted) {
        _selectedPgnLine = null;
        _annotatedLineLabel = null;
      }
    });
    return accepted;
  }

  void loadPgnLine(RepertoireLine line) {
    _selectedPgnLine = line;
    _annotatedLineLabel = null;
    _changeBoard(() => _board.loadPgnLine(line));
  }

  void loadMoveSequence(List<String> moves) {
    _selectedPgnLine = null;
    _annotatedLineLabel = null;
    _changeBoard(() => _board.loadMoveSequence(moves));
  }

  String? _annotatedLineLabel;
  String? get annotatedLineLabel => _annotatedLineLabel;
  void loadAnnotatedTree(MoveTree tree, {TreePath? cursor, String? label}) {
    _selectedPgnLine = null;
    _annotatedLineLabel = label;
    _changeBoard(() => _board.loadAnnotatedTree(tree, cursor: cursor));
  }

  void syncFromMoveIndex(int index, List<String> moves) =>
      _changeBoard(() => _board.syncFromMoveIndex(index, moves));

  void deleteAtPath(TreePath target) {
    final generation = _loadGeneration;
    _changeBoard(() {
      final edit = _board.deleteAtPath(target);
      if (edit == null) return;
      writer.recordDraftUndo(
        isCurrent: () =>
            _loadGeneration == generation && _board.canRestore(edit),
        restore: () => _changeBoard(() {
          _board.restore(edit);
        }),
      );
    });
  }

  void promoteVariation(TreePath target) =>
      _changeBoard(() => _board.promoteVariation(target));
  void makeMainLine(TreePath target) =>
      _changeBoard(() => _board.makeMainLine(target));
  void setCommentAtPath(TreePath target, String? comment) =>
      _changeBoard(() => _board.setCommentAtPath(target, comment));
  void toggleNagAtPath(TreePath target, int nag) =>
      _changeBoard(() => _board.toggleNagAtPath(target, nag));

  void _navigateToRootPosition() {
    _board.navigateToRootPosition(_rootMoves);
    _syncOpeningTree();
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
    _board.clearMoveHistory();
    _syncOpeningTree();
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
  late final RepertoireLineEdits _lineEdits = RepertoireLineEdits(documents);
  RepertoireLineEditContext _lineContext = RepertoireLineEditContext('', {});
  List<RepertoireLineDraft> get pendingLineDrafts => _lineEdits.drafts;

  /// The editor supplies its debounce flusher, or null once it is saved.
  /// Keeping this callback separate from persistence lets core await pending
  /// edits without depending on a widget or its lifecycle.
  void setPendingLineSave(VoidCallback? flush) => _pendingLineSave = flush;

  /// Await pending document edits without consuming a failure on a close retry.
  Future<void> flushDocumentForClose() async {
    Object observed;
    do {
      observed = (_lineEdits.revision, writer.revision, _pendingLineSave);
      await Future.wait([_flushPendingLineSaves(), writer.flush()]);
    } while (observed != (_lineEdits.revision, writer.revision, _pendingLineSave));
  }
  Object get closeRevision => (
    _repertoireFilePath,
    _loadGeneration,
    _lineEdits.revision,
    writer.revision,
    _pendingLineSave,
    _board.closeRevision,
    _boardFlipped,
  );

  Future<void> _flushPendingLineSaves() async {
    final flush = _pendingLineSave;
    _pendingLineSave = null;
    flush?.call();
    await _lineEdits.flush();
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
    final context = _lineContext;
    _lineEdits.bind(context, lineId, selected.fullPgn);
    return (newPgn) => _updateLineContent(
      newPgn,
      filePath: filePath,
      lineId: lineId,
      generation: generation,
      editContext: context,
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
    required RepertoireLineEditContext editContext,
  }) async {
    String? success;
    try {
      success = await _lineEdits.save(editContext, lineId, newPgn);
    } catch (_) {
      _notifyStructureChanged();
      rethrow;
    }
    if (success == null) {
      _notifyStructureChanged();
      return false;
    }
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
  Future<void> setRepertoire(RepertoireMetadata repertoire) =>
      _loadRepertoire(repertoire);

  Future<void> loadRepertoire() async {
    final repertoire = _currentRepertoire;
    if (repertoire != null) await _loadRepertoire(repertoire);
  }

  /// (Re)loads the PGN content for the current repertoire.
  Future<void> _loadRepertoire(RepertoireMetadata repertoire) async {
    final generation = ++_loadGeneration;
    final filePath = repertoire.filePath;
    final changedChapter = _currentRepertoire?.filePath != filePath;
    var flushed = false;
    writer.clearUndoStack();
    _loadError = null;
    _setLoading(true);

    try {
      // Flush before reading, not when the widget receives the replacement
      // tree. A same-file reload or a quick A → B → A must read saved edits.
      await _flushPendingLineSaves();
      if (generation != _loadGeneration) return;
      flushed = true;
      _currentRepertoire = repertoire;
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
      if (changedChapter) _boardFlipped = !_isRepertoireWhite;
      _resetTree();
      _navigateToRootPosition();
    } catch (e) {
      if (generation != _loadGeneration) return;
      _loadError = 'Failed to load repertoire: $e';
      debugPrint(_loadError);
      if (flushed) {
        _applyLoaded(LoadedRepertoire.missing);
        _resetTree();
      }
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
  void _applyLoaded(LoadedRepertoire loaded) {
    _lineContext = RepertoireLineEditContext(_repertoireFilePath ?? '', {
      for (final line in loaded.lines) line.id: line.fullPgn,
    });
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
    _board.reset();
    _syncOpeningTree();
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
      startingFen: startingFen ?? kStandardStartFen,
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

  @override
  void dispose() {
    _loadGeneration++;
    writer.clearUndoStack();
    _pendingLineSave = null;
    _isLoading = false;
    for (final waiter in _loadCompleters) {
      waiter.complete();
    }
    _loadCompleters.clear();
    super.dispose();
  }
}
