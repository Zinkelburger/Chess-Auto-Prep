/// Pure document-session owner for Builder loading, edits and chapter identity.
/// Board navigation and Flutter notifications belong to the composing host.
library;

import '../../documents/models/pgn_document.dart';

import '../../../chess_core/pgn/repertoire_headers.dart';
import '../../../chess_core/pgn/repertoire_line_expansion.dart';
import '../../../chess_core/pgn/repertoire_pgn_text.dart';
import '../../../constants/chess_constants.dart';
import '../../../models/opening_tree.dart';
import '../../../chess_core/moves/opening_graph.dart';
import '../models/repertoire_opening_graph.dart';
import '../../../models/repertoire_line.dart';
import '../models/loaded_repertoire.dart';
import '../models/repertoire_authoring.dart';
import '../models/repertoire_metadata.dart';
import '../repositories/repertoire_decoder.dart';
import '../repositories/repertoire_document_repository.dart';

String? _readContent(PgnOpenResult result) => switch (result) {
  PgnOpened(:final snapshot) => snapshot.content,
  PgnMissing() => null,
  PgnReadFailed(:final error) => throw error,
};

/// One not-yet-started line write. Replacements share its completion and retain
/// only the latest PGN; active writes are never modified.
class _PendingLineSave {
  _PendingLineSave(this.content);
  String content;
  late final Future<bool> result;
}

class RepertoireDocumentSession {
  RepertoireDocumentSession({
    required this.documents,
    required this.decoder,
    required this.onChanged,
    required this.onLoadStarted,
    required this.onResetBoard,
    required this.onClearSelectionAndTree,
    required this.onNavigate,
    required this.onNavigateToRoot,
    required this.startingFen,
    required this.currentMoveSequence,
  });

  final RepertoireDocumentRepository documents;
  final RepertoireDecoder decoder;
  final void Function() onChanged;
  final void Function() onLoadStarted;
  final void Function() onResetBoard;
  final void Function() onClearSelectionAndTree;
  final void Function(List<String>) onNavigate;
  final void Function() onNavigateToRoot;
  final String? Function() startingFen;
  final List<String> Function() currentMoveSequence;

  /// Pure PGN-authoring collaborator (game/line construction).
  final RepertoireAuthoring _authoring = const RepertoireAuthoring();

  RepertoireMetadata? _currentRepertoire;
  RepertoireMetadata? get currentRepertoire => _currentRepertoire;

  String? _repertoirePgn;
  String? get repertoirePgn => _repertoirePgn;
  PgnRevision? _sourceRevision;
  PgnRevision? get sourceRevision => _sourceRevision;

  OpeningTree? _openingTree;
  OpeningGraph? _openingGraph;
  OpeningGraph? get openingGraph => _openingGraph;

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
  void dismissLoadError() {
    if (_disposed || _loadError == null) return;
    _loadError = null;
    onChanged();
  }

  bool _isRepertoireWhite = true;
  bool get isRepertoireWhite => _isRepertoireWhite;

  bool _needsColorSelection = false;
  bool get needsColorSelection => _needsColorSelection;

  /// Root position move string (e.g. "1. d4 d5 2. c4") persisted in the PGN.
  String _rootMoves = '';
  String get rootMoves => _rootMoves;

  /// The loaded repertoire's file, or null when there is no repertoire or
  /// it has no file to write to.
  String? get _repertoireFilePath {
    final path = _currentRepertoire?.filePath;
    return path == null || path.isEmpty ? null : path;
  }

  // ── PGN line management ──────────────────────────────────────────

  RepertoireLine? _selectedPgnLine;
  RepertoireLine? get selectedPgnLine => _selectedPgnLine;

  void clearSelectedPgnLine() {
    _selectedPgnLine = null;
    onChanged();
  }

  Future<bool> renameLine(RepertoireLine line, String title) async {
    final filePath = _repertoireFilePath;
    if (_disposed || filePath == null) return false;
    final original = line.fullPgn;
    final generation = _loadGeneration;
    final result = await runDocumentMutation(
      () => documents.updateLineContent(
        filePath,
        line.id,
        withEventTitle(original, title),
        expectedContent: original,
      ),
    );
    if (result == null) return false;
    if (isCurrent(generation)) await loadRepertoire();
    return true;
  }

  /// Deletes a line from the repertoire file and reloads.
  Future<bool> deleteLine(RepertoireLine line) async {
    final filePath = _repertoireFilePath;
    if (_disposed || filePath == null) return false;

    final generation = _loadGeneration;
    final success = await runDocumentMutation(
      () => documents.deleteLine(
        filePath,
        line.id,
        expectedContent: line.fullPgn,
      ),
    );
    if (!success) return false;
    if (!isCurrent(generation) || _currentRepertoire?.filePath != filePath) {
      return true;
    }

    if (_selectedPgnLine?.id == line.id) onClearSelectionAndTree();

    await loadRepertoire();
    return true;
  }

  /// Deletes several lines in one pass and reloads once.
  ///
  /// Returns null for rejected admission. An acknowledged removal includes
  /// remaining lines only after its own successful, still-current refresh.
  /// Lines with no recorded file position are skipped rather than guessed.
  Future<
    ({
      int removed,
      int? refreshedGeneration,
      List<RepertoireLine>? remainingLines,
    })?
  >
  deleteLines(
    Iterable<RepertoireLine> lines, {
    required int expectedGeneration,
  }) async {
    final repertoire = _currentRepertoire;
    final filePath = _repertoireFilePath;
    if (!isCurrent(expectedGeneration) ||
        _isLoading ||
        _loadError != null ||
        _repertoirePgn == null ||
        repertoire == null ||
        filePath == null) {
      return null;
    }

    final indexes = {
      for (final line in lines)
        if (line.gameIndex >= 0) line.gameIndex: line.fullPgn,
    };
    if (indexes.isEmpty) {
      return (removed: 0, refreshedGeneration: null, remainingLines: _lines);
    }

    final removed = await runDocumentMutation(
      () => documents.deleteLinesAt(filePath, indexes),
    );
    if (removed > 0 && isCurrent(expectedGeneration)) onClearSelectionAndTree();
    if (!isCurrent(expectedGeneration)) {
      return (
        removed: removed,
        refreshedGeneration: null,
        remainingLines: null,
      );
    }
    // A nonempty request returning zero can mean the source disappeared.
    // Only this exact successful load can renew the caller's admission.
    final refreshed = await _loadRepertoire(repertoire);
    final applied = refreshed != null && isCurrent(refreshed);
    return (
      removed: removed,
      refreshedGeneration: applied ? refreshed : null,
      remainingLines: applied ? _lines : null,
    );
  }

  Future<void> _lineSaveTail = Future.value();
  final Map<(String, String, int), _PendingLineSave> _pendingLineSaves = {};
  Object? _lineSaveFailure;
  int _lineSaveRevision = 0;

  Future<T> runDocumentMutation<T>(Future<T> Function() action) {
    // A command is an ordering barrier: later edits cannot replace work queued
    // before that command, even when their captured line destination matches.
    _pendingLineSaves.clear();
    final result = _lineSaveTail.then((_) {
      if (_disposed) throw StateError('The document session is closed.');
      if (_lineSaveFailure != null) {
        throw StateError(
          'Could not save pending line edits: $_lineSaveFailure',
        );
      }
      return action();
    });
    _lineSaveTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Await pending document edits without consuming a failure on a close retry.
  Future<void> flushDocumentForClose() => _flushPendingLineSaves();
  Object get closeRevision =>
      (_repertoireFilePath, _loadGeneration, _lineSaveTail, _lineSaveFailure);

  Future<void> _flushPendingLineSaves() async {
    await _lineSaveTail;
    final failure = _lineSaveFailure;
    if (failure != null) {
      throw StateError('Could not save pending line edits: $failure');
    }
  }

  /// Capture a save destination before an editor edit can outlive its chapter. A completed save may update the open chapter only if the
  /// same load generation is still displayed.
  Future<bool> Function(String)? get selectedLineSaver {
    final selected = _selectedPgnLine;
    final filePath = _repertoireFilePath;
    if (_disposed || _isLoading || selected == null || filePath == null) {
      return null;
    }
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
    if (_disposed) {
      return Future.error(StateError('The document session is closed.'));
    }
    final key = (filePath, lineId, generation);
    final pending = _pendingLineSaves[key];
    if (pending != null) {
      pending.content = newPgn;
      return pending.result;
    }
    final request = _PendingLineSave(newPgn);
    _pendingLineSaves[key] = request;
    request.result = _lineSaveTail.then((_) {
      if (identical(_pendingLineSaves[key], request)) {
        _pendingLineSaves.remove(key);
      }
      return _persistLineContent(
        request.content,
        filePath: filePath,
        lineId: lineId,
        generation: generation,
        originals: originals,
      );
    });
    _lineSaveTail = request.result.then<void>(
      (saved) {
        _lineSaveRevision++;
        _lineSaveFailure = saved ? null : 'The original line is unavailable.';
      },
      onError: (Object error, StackTrace _) {
        _lineSaveRevision++;
        _lineSaveFailure = error;
      },
    );
    return request.result;
  }

  Future<bool> _persistLineContent(
    String newPgn, {
    required String filePath,
    required String lineId,
    required int generation,
    required Map<String, String> originals,
  }) async {
    final previousLine = originals[lineId]!;
    final saved = await documents.updateLineContent(
      filePath,
      lineId,
      newPgn,
      expectedContent: previousLine,
    );
    if (saved == null) return false;
    // The file is already committed. Even a failed presentation refresh must
    // keep a retained editor callback bound to the acknowledged game.
    originals[lineId] = saved.linePgn;
    if (!isCurrent(generation) || _currentRepertoire?.filePath != filePath) {
      return true;
    }

    final previousBaseline = _repertoirePgn;
    try {
      final loaded = await decoder.build(
        saved.documentPgn,
        fallbackIsWhite: _isRepertoireWhite,
      );
      if (!isCurrent(generation) || _currentRepertoire?.filePath != filePath) {
        return true;
      }
      // Another document action may finish while decoding. Its source receipt
      // already includes this save; do not replace it with an older snapshot.
      if (_repertoirePgn != previousBaseline) return true;
      final selectedId = _selectedPgnLine?.id;
      final selectedWasSaved =
          selectedId == lineId ||
          _selectedPgnLine?.fullPgn.trim() == previousLine.trim();
      // Derive everything before replacing the session. This also incorporates
      // external changes to other games that the line transaction preserved.
      final acknowledgedLines = _lineOriginals;
      _applyLoaded(loaded);
      _sourceRevision = saved.snapshot?.revision;
      // Existing editor callbacks share these acknowledgements. Keep their
      // target preconditions across a refresh (including move-derived ids).
      for (final line in loaded.lines) {
        acknowledgedLines.putIfAbsent(line.id, () => line.fullPgn);
      }
      _lineOriginals = acknowledgedLines;
      _currentRepertoire = _currentRepertoire!.copyWith(
        gameCount: loaded.lines.length,
      );
      _selectedPgnLine = null;
      for (final line in loaded.lines) {
        if (selectedWasSaved
            ? line.gameIndex == saved.lineIndex
            : line.id == selectedId) {
          _selectedPgnLine = line;
        }
      }
      _loadError = null;
    } catch (error) {
      if (!isCurrent(generation)) return true;
      _loadError = 'Line was saved, but refresh failed: $error';
      onChanged();
      rethrow;
    }
    onChanged();
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

    if (notify) onChanged();
  }

  /// Capture the destination session before a generator leaves its config UI.
  /// Re-read after draining editor saves: an edit committed after publication
  /// must not be replaced in memory with the earlier generation receipt.
  Future<void> Function(PgnSnapshot) get publishedDocumentReceiver {
    final expectedGeneration = _loadGeneration;
    final path = _repertoireFilePath;
    return (saved) async {
      if (!isCurrent(expectedGeneration) ||
          _isLoading ||
          path == null ||
          saved.path != path) {
        return;
      }
      final generation = ++_loadGeneration;
      final position = List<String>.of(currentMoveSequence());
      final selectedId = _selectedPgnLine?.id;
      _requestedRepertoire = _currentRepertoire;
      onLoadStarted();
      _loadError = null;
      _setLoading(true);
      try {
        await _flushPendingLineSaves();
        if (!isCurrent(generation)) return;
        final current = await documents.read(path);
        if (!isCurrent(generation)) return;
        final content = _readContent(current);
        if (content == null) {
          throw StateError('The published chapter is no longer available.');
        }
        final loaded = await decoder.build(
          content,
          fallbackIsWhite: _isRepertoireWhite,
        );
        if (!isCurrent(generation)) return;
        _applyLoaded(loaded);
        _currentRepertoire = _currentRepertoire!.copyWith(
          gameCount: loaded.lines.length,
        );
        _selectedPgnLine = null;
        for (final line in loaded.lines) {
          if (line.id == selectedId) _selectedPgnLine = line;
        }
        onNavigate(position);
      } catch (error) {
        if (!isCurrent(generation)) return;
        _loadError = 'Generated PGN was saved, but refresh failed: $error';
        rethrow;
      } finally {
        if (isCurrent(generation)) _setLoading(false);
      }
    };
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
      final startFen = startingFen() ?? kStandardStartFen;
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
      _sourceRevision = null;
    }

    final startFen = startingFen() ?? kStandardStartFen;
    _openingTree?.appendLineFromFen(startFen, [...prefix, newMove]);

    final lineIndex = _authoring.findLineIndexForPrefix(
      _repertoireLines,
      prefix,
    );
    if (lineIndex != null) {
      final next = List.of(_repertoireLines);
      next[lineIndex] = _authoring.extendLine(next[lineIndex], newMove);
      _repertoireLines = next;
      onChanged();
      return;
    }

    final fullPath = [...prefix, newMove];
    final pgnForLine = updatedPgnContent != null
        ? _authoring.extractLastGamePgn(updatedPgnContent)
        : buildMinimalGamePgn(
            fullPath,
            startingFen: startingFen(),
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
  int get loadGeneration => _loadGeneration;

  /// Sets a new repertoire and triggers loading.
  Future<void> setRepertoire(RepertoireMetadata repertoire) async {
    await _loadRepertoire(repertoire);
  }

  /// (Re)loads the PGN content for the current repertoire.
  Future<void> loadRepertoire() async {
    final repertoire = _requestedRepertoire ?? _currentRepertoire;
    if (repertoire != null) await _loadRepertoire(repertoire);
  }

  RepertoireMetadata? _requestedRepertoire;

  Future<int?> _loadRepertoire(RepertoireMetadata repertoire) async {
    if (_disposed) return null;
    _requestedRepertoire = repertoire;
    final generation = ++_loadGeneration;
    final filePath = repertoire.filePath;
    onLoadStarted();
    _loadError = null;
    _setLoading(true);

    var appliedLoad = false;
    try {
      // Flush before reading, not when the widget receives the replacement
      // tree. A same-file reload or a quick A → B → A must read saved edits.
      await _flushPendingLineSaves();
      if (!isCurrent(generation)) return null;
      final read = await documents.read(filePath);
      if (!isCurrent(generation)) return null;

      final content = _readContent(read);
      if (content == null) {
        _currentRepertoire = repertoire;
        _applyLoaded(LoadedRepertoire.missing);
        _resetTree();
        return null;
      }

      final loaded = await decoder.build(
        content,
        fallbackIsWhite: _isRepertoireWhite,
      );
      if (!isCurrent(generation)) return null;

      _currentRepertoire = repertoire;
      _applyLoaded(loaded);
      _sourceRevision = (read as PgnOpened).snapshot.revision;
      _resetTree();
      onNavigateToRoot();
      appliedLoad = true;
    } catch (e) {
      if (!isCurrent(generation)) return null;
      _requestedRepertoire = _currentRepertoire ?? repertoire;
      _loadError = 'Failed to load repertoire: $e';
    } finally {
      if (isCurrent(generation)) {
        _setLoading(false);
      }
    }
    return appliedLoad && isCurrent(generation) ? generation : null;
  }

  /// Restores repertoire state from a PGN snapshot (used by undo).
  ///
  /// Claims a load generation, so an in-flight [loadRepertoire] cannot land
  /// its half of a different repertoire on top of the restored one.
  Future<void> restoreRepertoireFromPgn(
    String pgnContent, {
    List<String>? syncPath,
  }) async {
    if (_disposed) return;
    final generation = ++_loadGeneration;
    _requestedRepertoire = _currentRepertoire;
    try {
      final loaded = await decoder.build(
        pgnContent.isEmpty ? null : pgnContent,
        fallbackIsWhite: _isRepertoireWhite,
      );
      if (!isCurrent(generation)) return;

      // Unlike a load this keeps the editable move tree: undo reverts the
      // saved PGN, not the nodes the user has navigated into.
      _applyLoaded(loaded);
      if (syncPath != null) {
        onNavigate(syncPath);
      } else {
        onNavigateToRoot();
      }
      onChanged();
    } finally {
      // The superseded load cannot clear its loading state after this restore.
      if (isCurrent(generation) && _isLoading) {
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
    _sourceRevision = null;
    _lineOriginals = {for (final line in loaded.lines) line.id: line.fullPgn};
    _repertoirePgn = loaded.pgn;
    // Ownership crosses the decoder boundary once; retaining/mutating a
    // decoder result cannot change the active session behind its revision.
    final source = loaded.openingTree;
    _openingTree = source == null
        ? null
        : OpeningTree.fromTransferJson(source.toTransferJson());
    _openingGraph = _openingTree == null
        ? null
        : RepertoireOpeningGraph(_openingTree!);
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
    _selectedPgnLine = null;
    onResetBoard();
  }

  /// Writes the color header to the PGN file and reloads.
  Future<void> setRepertoireColor(bool isWhite) async {
    if (_disposed || _currentRepertoire == null) return;
    final filePath = _currentRepertoire!.filePath;
    final generation = _loadGeneration;

    final colorLabel = isWhite ? 'White' : 'Black';
    await runDocumentMutation(() async {
      final existing = _readContent(await documents.read(filePath));
      if (existing == null) {
        throw StateError('The selected chapter is unavailable.');
      }
      final updated = upsertMetadataComment(existing, '// Color:', colorLabel);
      await documents.replace(filePath, updated, expectedContent: existing);
    });
    if (!isCurrent(generation) || _currentRepertoire?.filePath != filePath) {
      return;
    }
    _needsColorSelection = false;
    await loadRepertoire();
  }

  /// Sets the current move sequence as the root position and persists it.
  Future<void> setRootPosition() async {
    if (_disposed || _currentRepertoire == null) return;
    final filePath = _currentRepertoire!.filePath;
    final generation = _loadGeneration;

    final moveText = _authoring.numberedMovetext(
      currentMoveSequence(),
      startingFen: startingFen() ?? kStandardStartFen,
    );
    await runDocumentMutation(() async {
      final existing = _readContent(await documents.read(filePath));
      if (existing == null) {
        throw StateError('The selected chapter is unavailable.');
      }
      final updated = upsertMetadataComment(existing, '// Root:', moveText);
      await documents.replace(filePath, updated, expectedContent: existing);
    });
    if (!isCurrent(generation) || _currentRepertoire?.filePath != filePath) {
      return;
    }
    _rootMoves = moveText;
    onChanged();
  }

  /// An explicit copy preserves the editable tree and never replaces its
  /// original game. This independent destination can resolve a failed source
  /// save, so it waits for the queue without requiring that source to recover.
  Future<PgnWriteResult> appendDraftTo(String filePath, String pgn) {
    _pendingLineSaves.clear();
    final result = _lineSaveTail.then((_) {
      if (_disposed) throw StateError('The document session is closed.');
      return documents.appendPgn(filePath, pgn);
    });
    _lineSaveTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Called only after the corresponding failed draft was durably copied to
  /// the user's explicit destination. Newer failed edits remain unresolved.
  void resolveCopiedLineFailure(int revision) {
    if (revision == _lineSaveRevision) _lineSaveFailure = null;
  }

  int get lineSaveRevision => _lineSaveRevision;

  /// Imports PGN content into the current repertoire file.
  Future<int> importPgnContent(String pgnContent) async {
    if (_disposed || _currentRepertoire == null) return 0;

    final filePath = _currentRepertoire!.filePath;
    final generation = _loadGeneration;

    // One game per line, the same way a new repertoire is seeded: a pasted
    // study's variations become lines of their own, or the trainer and this
    // screen's line list would never see them.
    final expanded = expandVariationsIntoLines(pgnContent);
    final gameCount = expanded.gameCount;

    await runDocumentMutation(() async {
      final existing = _readContent(await documents.read(filePath));
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
    });

    if (isCurrent(generation) && _currentRepertoire?.filePath == filePath) {
      await loadRepertoire();
    }

    return gameCount > 0 ? gameCount : 1;
  }

  /// A newer workspace edit supersedes a pending read without resetting the
  /// current document or board. Already-started writes retain their own queue.
  void cancelPendingLoad() {
    if (_disposed || !_isLoading) return;
    _loadGeneration++;
    _requestedRepertoire = _currentRepertoire;
    _setLoading(false);
  }

  void _setLoading(bool loading) {
    if (_disposed) return;
    _isLoading = loading;
    onChanged();
  }

  bool _disposed = false;
  bool isCurrent(int generation) => !_disposed && generation == _loadGeneration;

  void selectLine(RepertoireLine? line) => _selectedPgnLine = line;
  void syncOpeningTree(List<String> moves, List<String> fens) =>
      _openingTree?.syncToFens(moves, fens);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loadGeneration++;
    _isLoading = false;
  }
}
