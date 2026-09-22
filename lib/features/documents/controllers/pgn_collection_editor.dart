import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../utils/safe_change_notifier.dart';
import '../../../models/pgn_game_entry.dart';
import '../../../chess_core/pgn/pgn_text.dart' show extractHeaders;
import '../../../chess_core/pgn/study_metadata.dart';
import '../../../chess_core/pgn/mainline_lexer.dart' show movetextStart;
import '../models/pgn_document.dart';
import '../models/document_save_state.dart';
import '../models/pgn_workspace_snapshot.dart';
import '../repositories/document_save_actions.dart';
import '../repositories/pgn_collection_repository.dart';

/// Owns collection edit tracking, autosave scheduling and serialized writes.
/// Suppliers follow the legacy host's current collection; each write captures
/// its games and baseline before awaiting. No widget or storage singleton owns
/// this state. Each collection owns an edit ledger retained by navigation;
/// asynchronous receipts update that ledger even while another collection is open.
/// The remaining viewer migration will make game cores private.
class PgnCollectionEditor extends ChangeNotifier
    with SafeChangeNotifier
    implements DocumentSaveActions {
  PgnCollectionEditor({
    required this.repository,
    required this.path,
    required this.games,
    required this.collectionPreamble,
    required this.selectedGame,
    required this.onContentChanged,
    required this.onSaved,
    required this.onSavedCopy,
    required this.isActive,
    this.onReclaimFocus,
    this.prepareReplacement,
  });

  /// Decode without changing the host, then return a synchronous adoption.
  final Future<void Function()> Function(
    String content,
    String? path, {
    int? expectedGames,
  })?
  prepareReplacement;
  final PgnCollectionRepository repository;
  final _changes = StreamController<DocumentSaveState>.broadcast(sync: true);
  final _retainedDrafts = <RetainedDocumentDraft>[];
  bool _reloading = false;
  bool _copying = false;
  String? _copyDestination;
  @override
  Stream<DocumentSaveState> get changes => _changes.stream;
  @override
  DocumentSaveState get state => DocumentSaveState(
    path: filePath ?? '',
    content: _session.capturedContent,
    baseline: _session.baseline,
    dirtyOverride:
        hasUnsavedChanges || (filePath == null && allGames.isNotEmpty),
    pendingEdits: hasUnsavedChanges,
    outcome: lastResult,
    readFailure: _session.readFailure,
    uncertainPath: _session.uncertainPath,
    retainedDrafts: _retainedDrafts,
    phase: _reloading
        ? DocumentSavePhase.reloading
        : (isSaving || _copying)
        ? DocumentSavePhase.saving
        : switch (lastResult) {
            PgnConflict() => DocumentSavePhase.conflict,
            PgnNameCollision() => DocumentSavePhase.collision,
            PgnWriteUncertain() => DocumentSavePhase.uncertain,
            PgnWriteFailed() => DocumentSavePhase.failed,
            _ =>
              (hasUnsavedChanges || (filePath == null && allGames.isNotEmpty))
                  ? DocumentSavePhase.dirty
                  : DocumentSavePhase.clean,
          },
  );
  @override
  void notifyListeners() {
    super.notifyListeners();
    if (!isDisposed && !_changes.isClosed) _changes.add(state);
  }

  String _serialize(Map<PgnGameEntry, String> output) =>
      '${collectionPreamble()}\n\n${output.values.join('\n\n')}\n';
  @override
  Future<PgnWriteResult?> save() async {
    if (state.busy || filePath == null) return null;
    await saveChanges();
    return lastResult;
  }

  @override
  Future<PgnOpenResult> inspectCurrent() async {
    try {
      return await repository.open(_session.uncertainPath ?? filePath ?? '');
    } catch (error) {
      return PgnReadFailed(error);
    }
  }

  @override
  void keepEditing() {
    if (state.busy || isDisposed) return;
    if (lastResult is! PgnWriteUncertain) _session.outcome = null;
    _session.errorMessage = null;
    _session.readFailure = null;
    notifyListeners();
  }

  @override
  Future<PgnWriteResult?> saveCopy(String destination) async {
    if (isDisposed || state.busy || allGames.isEmpty) return null;
    _persistDebounce?.cancel();
    _persistDebounce = null;
    final source = allGames;
    final output = snapshotForSave();
    final content = _serialize(output);
    _session.capturedContent = content;
    final previous = lastResult;
    final previousUncertainPath = _session.uncertainPath;
    _copying = true;
    _copyDestination = destination;
    notifyListeners();
    PgnWriteResult result;
    try {
      result = await repository.create(destination, content);
    } catch (error) {
      result = PgnWriteUncertain(error: error, before: null, observed: null);
    }
    if (!isDisposed && identical(source, allGames)) {
      if (result is PgnSaved) {
        // A copy establishes a different persistence identity. Older navigation
        // handles still point at the source ledger and its original baseline.
        final copied = _CollectionEdits()
          ..baseline = result.after
          ..capturedContent = content
          ..outcome = result
          ..persisted = (Map<PgnGameEntry, String>.identity()..addAll(output));
        copied.dirty.addAll(_session.dirty);
        copied.edited.addAll(_session.edited);
        copied.screenOnly.addAll(_session.screenOnly);
        _session = copied;
        onSavedCopy(result.after.path);
      } else {
        _session.outcome =
            previous is PgnWriteUncertain && result is! PgnWriteUncertain
            ? previous
            : result;
        _session.uncertainPath = result is PgnWriteUncertain
            ? destination
            : previousUncertainPath;
        _autoSaveBlocked = true;
        _session.errorMessage = _describe(lastResult!);
      }
    }
    _copying = false;
    _copyDestination = null;
    notifyListeners();
    // Late edits stay dirty. Saving the copy does not start an implicit write.
    return result;
  }

  PgnWorkspaceSnapshot captureWorkspace({
    int gameIndex = 0,
    int ply = 0,
    bool flipped = false,
  }) {
    final output = snapshotForSave();
    return PgnWorkspaceSnapshot(
      path: filePath ?? '',
      content: _serialize(output),
      dirty: state.dirty,
      persistedGames: [
        for (final game in allGames) _session.persisted[game] ?? output[game]!,
      ],
      baseline: _session.baseline,
      wholeReplacement: _session.wholeReplacement,
      uncertain: state.uncertain || _copying || isSaving,
      uncertainPath:
          _copyDestination ??
          _session.uncertainPath ??
          (isSaving ? filePath : null),
      retainedDrafts: _retainedDrafts,
      gameIndex: gameIndex,
      ply: ply,
      flipped: flipped,
    );
  }

  /// Recovery never reads a newer source revision or starts an implicit save.
  /// Decode first; preserve any displaced work before replacing this session.
  Future<void> restoreWorkspace(PgnWorkspaceSnapshot snapshot) async {
    if (isDisposed || state.busy || prepareReplacement == null) {
      throw StateError('The collection cannot be restored while busy');
    }
    _persistDebounce?.cancel();
    _persistDebounce = null;
    final source = allGames;
    final before = _serialize(snapshotForSave());
    _reloading = true;
    notifyListeners();
    try {
      final adopt = await prepareReplacement!(
        snapshot.content,
        snapshot.path.isEmpty ? null : snapshot.path,
        expectedGames: snapshot.persistedGames.length,
      );
      if (isDisposed ||
          !identical(source, allGames) ||
          before != _serialize(snapshotForSave())) {
        throw StateError('The current draft changed during recovery');
      }
      final displaced = await _retainCurrentDraft();
      if (isDisposed || !identical(source, allGames)) {
        throw StateError('The current collection changed during recovery');
      }
      adopt();
      _session.persisted = Map.identity();
      for (var i = 0; i < allGames.length; i++) {
        _session.persisted[allGames[i]] = snapshot.persistedGames[i];
      }
      _session.edited.addAll(allGames);
      _session.baseline = snapshot.baseline;
      _session.capturedContent = snapshot.content;
      _session.wholeReplacement = snapshot.wholeReplacement;
      _retainedDrafts.addAll(snapshot.retainedDrafts);
      if (displaced != null) _retainedDrafts.add(displaced);
      _autoSaveBlocked = true;
      _session.uncertainPath = snapshot.uncertainPath;
      _session.outcome = snapshot.uncertain
          ? PgnWriteUncertain(
              error: StateError('Recovered unresolved write'),
              before: snapshot.baseline,
              observed: null,
            )
          : null;
      _session.readFailure = null;
    } finally {
      _reloading = false;
      notifyListeners();
    }
  }

  @override
  Future<void> reloadPreservingDraft() async {
    if (isDisposed || state.busy || prepareReplacement == null) return;
    _persistDebounce?.cancel();
    _persistDebounce = null;
    final source = allGames;
    _reloading = true;
    _session.readFailure = null;
    notifyListeners();
    try {
      final opened = await inspectCurrent();
      if (opened is! PgnOpened) {
        _session.readFailure = opened;
        return;
      }
      final adopt = await prepareReplacement!(
        opened.snapshot.content,
        opened.snapshot.path,
      );
      if (isDisposed || !identical(source, allGames)) return;
      final retained = await _retainCurrentDraft();
      if (isDisposed || !identical(source, allGames)) return;
      if (retained != null) _retainedDrafts.add(retained);
      adopt();
      _session.baseline = opened.snapshot;
      _session.capturedContent = opened.snapshot.content;
      _autoSaveBlocked = true;
      _session.uncertainPath = null;
      _session.outcome = null;
    } catch (error) {
      _session.readFailure = PgnReadFailed(error);
    } finally {
      _reloading = false;
      notifyListeners();
    }
  }

  /// Capture after decoding and acknowledge recovery before displacing work.
  Future<RetainedDocumentDraft?> _retainCurrentDraft() async {
    if (!state.dirty && lastResult is! PgnWriteUncertain) return null;
    final source = allGames;
    final draft = RetainedDocumentDraft(
      path: filePath ?? '',
      content: _serialize(snapshotForSave()),
      baseline: _session.baseline,
    );
    final recovery = await repository.retainRecovery(draft.content);
    if (recovery == null) {
      throw StateError('Draft recovery was not acknowledged');
    }
    if (isDisposed || !identical(source, allGames)) {
      throw StateError('The collection changed during recovery');
    }
    if (_serialize(snapshotForSave()) != draft.content) {
      _retainedDrafts.add(draft);
      throw StateError(
        'The draft changed while recovery was written; try again',
      );
    }
    return draft;
  }

  @override
  Future<void> restoreDraft(int index) async {
    if (isDisposed ||
        state.busy ||
        prepareReplacement == null ||
        index < 0 ||
        index >= _retainedDrafts.length) {
      return;
    }
    _persistDebounce?.cancel();
    _persistDebounce = null;
    final draft = _retainedDrafts[index];
    final source = allGames;
    final baseline = _session.baseline;
    final currentPath = filePath;
    final outcome = lastResult;
    final uncertainPath = _session.uncertainPath;
    _reloading = true;
    _session.readFailure = null;
    notifyListeners();
    try {
      final adopt = await prepareReplacement!(draft.content, currentPath);
      if (isDisposed || !identical(source, allGames)) return;
      final displaced = await _retainCurrentDraft();
      if (isDisposed || !identical(source, allGames)) return;
      adopt();
      _retainedDrafts.removeAt(index);
      if (displaced != null) _retainedDrafts.add(displaced);
      _session.baseline = baseline;
      _session.capturedContent = draft.content;
      _session.wholeReplacement = true;
      _session.edited.addAll(allGames);
      _autoSaveBlocked = true;
      if (outcome is PgnWriteUncertain) {
        _session.outcome = outcome;
        _session.uncertainPath = uncertainPath;
      }
    } catch (error) {
      _session.readFailure = PgnReadFailed(error);
    } finally {
      _reloading = false;
      notifyListeners();
    }
  }

  final String? Function() path;
  final List<PgnGameEntry> Function() games;
  final String Function() collectionPreamble;
  final PgnGameEntry? Function() selectedGame;
  final void Function({required bool resetIndex}) onContentChanged;
  final void Function(DateTime? modified) onSaved;
  final void Function(String path) onSavedCopy;
  final bool Function() isActive;
  final VoidCallback? onReclaimFocus;
  String? get filePath => path();
  List<PgnGameEntry> get allGames => games();

  @override
  void dispose() {
    _persistDebounce?.cancel();
    _persistDebounce = null;
    unawaited(_changes.close());
    super.dispose();
  }

  String _describe(PgnWriteResult result) => switch (result) {
    PgnConflict() => 'The source game changed or is ambiguous.',
    PgnNameCollision() => 'The destination already exists.',
    PgnWriteUncertain() =>
      'The write could not be confirmed. Review the file before saving again.',
    PgnWriteFailed(:final error) => 'The write failed: $error',
    PgnSaved() => '',
  };

  Timer? _persistDebounce;
  final _contextOwner = Object();
  _CollectionEdits _session = _CollectionEdits();
  String? get errorMessage => _session.errorMessage;
  PgnWriteResult? get lastResult => _session.outcome;
  bool _autoSave = true;
  bool get autoSave => _autoSave;
  bool get _autoSaveBlocked => _session.autoSaveBlocked;
  set _autoSaveBlocked(bool value) => _session.autoSaveBlocked = value;
  bool get isSaving => _session.pendingWrites > 0;
  bool get needsSaveRecovery => _autoSaveBlocked || _retainedDrafts.isNotEmpty;

  bool get hasUnsavedChanges =>
      _session.wholeReplacement ||
      _session.dirty.isNotEmpty ||
      _session.edited.any(
        (g) =>
            (_session.screenOnly[g] ?? g.pgnText).trim() !=
            (_session.persisted[g] ?? g.pgnText).trim(),
      );

  void setAutoSave(bool value) {
    if (autoSave == value) return;
    _autoSave = value;
    _persistDebounce?.cancel();
    _persistDebounce = null;
    if (value && hasUnsavedChanges) unawaited(persistMetadata());
    notifyListeners();
  }

  Future<bool> saveChanges() async {
    if (state.busy || isDisposed || lastResult is PgnWriteUncertain) {
      return false;
    }
    _autoSaveBlocked = false;
    final submittedGames = allGames;
    await doPersistMetadata();
    return identical(submittedGames, allGames) && !hasUnsavedChanges;
  }

  /// Keep the collection available until its manual edits have been saved.
  bool canReplaceCollection() {
    if (_reloading ||
        _copying ||
        ((!autoSave || _autoSaveBlocked) && hasUnsavedChanges)) {
      _session.errorMessage =
          'Unsaved changes — save or discard them before closing or opening another PGN.';
      notifyListeners();
      return false;
    }
    return true;
  }

  void discardChanges() {
    _persistDebounce?.cancel();
    _persistDebounce = null;
    for (final g in _session.edited) {
      final original = _session.persisted[g];
      if (original == null) continue;
      g.pgnText = original;
      g.headers
        ..clear()
        ..addAll(extractHeaders(original));
      g.studyRating = int.tryParse(g.headers['StudyRating'] ?? '') ?? 0;
      g.studySummary = g.headers['StudySummary'] ?? '';
    }
    _session.wholeReplacement = false;
    _session.dirty.clear();
    _session.edited.clear();
    _session.screenOnly.clear();
    _session.errorMessage = null;
    _session.outcome = null;
    onContentChanged(resetIndex: true);
    notifyListeners();
  }

  Future<void> _metadataWrites = Future.value();

  /// An opaque live context: receipts arriving after departure still belong to
  /// these games. It is not a serialized checkpoint or a clone of game values.
  PgnCollectionEditContext captureEditContext() => PgnCollectionEditContext._(
    _contextOwner,
    filePath,
    List.unmodifiable(allGames),
    _session,
  );

  void adoptPersistedGames(
    List<PgnGameEntry> games, {
    PgnSnapshot? baseline,
    PgnCollectionEditContext? context,
  }) {
    if (context != null) {
      if (isDisposed ||
          !identical(context._owner, _contextOwner) ||
          context._path != filePath ||
          context._games.length != games.length ||
          Iterable<int>.generate(
            games.length,
          ).any((i) => !identical(context._games[i], games[i]))) {
        throw StateError('Edit context does not belong to this collection');
      }
      _session = context._edits;
      return;
    }
    _session = _CollectionEdits()
      ..baseline = baseline
      ..capturedContent = baseline?.content ?? '';
    for (final game in games) {
      _session.persisted[game] = game.pgnText;
    }
  }

  void rememberPersistedGame(PgnGameEntry game) {
    _session.persisted.putIfAbsent(game, () => game.pgnText);
    _session.edited.add(game);
  }

  void setRating(int stars) {
    final game = selectedGame();
    if (game == null) return;
    rememberPersistedGame(game);
    final ratingHeader = stars > 0 ? '$stars' : null;
    final changed =
        game.studyRating != stars ||
        game.headers['StudyRating'] != ratingHeader;
    game.studyRating = stars;
    if (ratingHeader == null) {
      game.headers.remove('StudyRating');
    } else {
      game.headers['StudyRating'] = ratingHeader;
    }
    _session.dirty.add(game);
    _session.edited.add(game);
    if (changed) onContentChanged(resetIndex: false);
    notifyListeners();
    unawaited(persistMetadata());
    onReclaimFocus?.call();
  }

  /// Perspective is a collection edit: track its original bytes and use the
  /// same conflict/recovery/save path as ratings and annotations.
  Future<void> setPerspectiveHeader(String value) async {
    if (isDisposed || allGames.isEmpty) return;
    final first = allGames.first;
    final pgn = upsertPgnHeader(first.pgnText, 'StudyPerspective', value);
    if (first.headers['StudyPerspective'] == value && first.pgnText == pgn) {
      return;
    }
    rememberPersistedGame(first);
    first.headers['StudyPerspective'] = value;
    first.pgnText = pgn;
    // Keep drill-only annotations on screen, while saving the requested
    // header against the persisted movetext rather than hiding this edit.
    if (_session.screenOnly.containsKey(first)) {
      _session.screenOnly[first] = upsertPgnHeader(
        _session.screenOnly[first]!,
        'StudyPerspective',
        value,
      );
    }
    _session.edited.add(first);
    onContentChanged(resetIndex: false);
    notifyListeners();
    await persistMetadata();
  }

  Future<void> persistMetadata() async {
    _persistDebounce?.cancel();
    _persistDebounce = null;
    if (!autoSave || _autoSaveBlocked || _reloading || _copying) return;
    _persistDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(doPersistMetadata());
    });
  }

  /// Snapshot all games for Save As, including staged metadata edits.
  Map<PgnGameEntry, String> snapshotForSave() {
    final session = _session;
    final games = allGames;
    _prepareMetadata(session);
    return {for (final g in games) g: session.screenOnly[g] ?? g.pgnText};
  }

  List<PgnGameEntry> _prepareMetadata(_CollectionEdits session) {
    final dirty = List.of(session.dirty);
    session.dirty.clear();
    // A game the user has just rated is a game they touched: write what is
    // in memory, notes and all, rather than a snapshot taken before them.
    for (final g in dirty) {
      session.screenOnly.remove(g);
    }

    if (dirty.isNotEmpty) {
      final rewritten = buildMetadataOutput([
        for (final g in dirty)
          (pgn: g.pgnText, rating: g.studyRating, summary: g.studySummary),
      ]);
      var changed = false;
      for (var i = 0; i < dirty.length; i++) {
        if (dirty[i].pgnText == rewritten[i]) continue;
        dirty[i].pgnText = rewritten[i];
        changed = true;
      }
      if (changed) {
        onContentChanged(resetIndex: false);
        notifyListeners();
      }
    }

    return dirty;
  }

  /// Write the collection back to its file: dirty games get their metadata
  /// headers regenerated, the rest are written from memory as they are.
  ///
  /// Everything the write depends on is captured before the first `await`,
  /// so [flushPendingMetadata] can call this for a collection that is about
  /// to be replaced.  The FEN index is only marked stale here — its stamp
  /// no longer matches the file — and is persisted once when the collection
  /// is closed rather than after every edit.
  Future<void> doPersistMetadata() async {
    _persistDebounce?.cancel();
    _persistDebounce = null;
    final path = filePath;
    if (path == null ||
        !isActive() ||
        _autoSaveBlocked ||
        _reloading ||
        _copying) {
      return;
    }
    final session = _session;
    final games = allGames;
    final preamble = collectionPreamble();
    final originals = session.persisted;
    final dirty = _prepareMetadata(session);
    final wholeReplacement = session.wholeReplacement;
    final baseline = session.baseline;

    final output = {
      for (final g in games) g: session.screenOnly[g] ?? g.pgnText,
    };
    session.capturedContent = '$preamble\n\n${output.values.join('\n\n')}\n';
    session.pendingWrites++;
    notifyListeners();
    final task = _metadataWrites.then((_) async {
      final edits = <String, String>{
        for (final g in games)
          if (originals[g] case final original?
              when original.trim() != output[g]!.trim())
            original: output[g]!,
      };
      if (edits.isEmpty && !wholeReplacement) return;
      PgnWriteResult result;
      try {
        result = session.autoSaveBlocked
            ? session.outcome!
            : wholeReplacement
            ? baseline == null
                  ? await repository.create(
                      path,
                      '$preamble\n\n${output.values.join('\n\n')}\n',
                    )
                  : await repository.save(
                      baseline,
                      '$preamble\n\n${output.values.join('\n\n')}\n',
                    )
            : await repository.patch(path, edits);
      } catch (error) {
        result = PgnWriteUncertain(error: error, before: null, observed: null);
      }
      session.outcome = result;
      if (result is! PgnSaved) {
        String? recovery;
        Object? recoveryError;
        try {
          recovery = await repository.retainRecovery(
            '$preamble\n\n${output.values.join('\n\n')}\n',
          );
        } catch (error) {
          recoveryError = error;
        }
        session.errorMessage = recovery != null
            ? 'Changes could not be merged with $path. A recovery copy was saved to $recovery. ${_describe(result)}'
            : 'Changes to $path are unsaved: ${_describe(result)}. Recovery save also failed: $recoveryError';
        session.autoSaveBlocked = true;
        session.dirty.addAll(dirty);
        if (result is PgnWriteUncertain) session.uncertainPath = path;
        if (identical(_session, session)) notifyListeners();
        return;
      }
      for (final g in games) {
        originals[g] = output[g]!;
      }
      // Receipts belong to this ledger even after leaving or returning to it.
      // Only derived host state needs the active-context check.
      session.baseline = result.after;
      session.wholeReplacement = false;
      session.uncertainPath = null;
      session.readFailure = null;
      session.errorMessage = null;
      if (filePath != path || !identical(_session, session)) return;
      DateTime? modified;
      try {
        modified = await repository.modified(path);
      } catch (_) {
        // The committed receipt remains valid even if derived stat refresh fails.
      }
      if (filePath == path && identical(_session, session)) {
        onSaved(modified);
      }
    });
    _metadataWrites = task.catchError((Object e) {
      session.errorMessage = 'Could not save: $e';
      if (identical(_session, session)) notifyListeners();
    });
    try {
      await _metadataWrites;
    } finally {
      session.pendingWrites--;
      if (identical(_session, session)) notifyListeners();
    }
  }

  /// Flush an outstanding autosave and await all serialized writes. The host
  /// separately owns derived indexes and their lifecycle.
  Future<void> flushPendingMetadata() async {
    if (_persistDebounce != null) await doPersistMetadata();
    await _metadataWrites;
  }

  void persistMoveComments(String updatedPgnMovetext) {
    final game = selectedGame();
    if (game == null || filePath == null) return;
    persistMoveCommentsFor(game, updatedPgnMovetext);
  }

  /// Like [persistMoveComments] but bound to a specific [game] object, so
  /// debounced edits that flush after the user has switched games still patch
  /// the game they were typed on.
  ///
  /// The in-memory game is always updated, so a pasted collection's "Copy
  /// PGN" carries the edits too; only the write to disk needs a file — and
  /// [writeToFile] can withhold even that. Solitaire's guess notes use it:
  /// finishing a game used to rewrite the reader's PGN on disk with a
  /// "(revealed)" on every move, which nobody asked for. Amend mode is the
  /// mode that says "changes are saved to the file"; a drill is not.
  void persistMoveCommentsFor(
    PgnGameEntry game,
    String updatedPgnMovetext, {
    bool writeToFile = true,
  }) {
    rememberPersistedGame(game);
    if (writeToFile) {
      _session.screenOnly.remove(game);
      _session.edited.add(game);
    } else {
      _session.screenOnly.putIfAbsent(game, () => game.pgnText);
    }

    // Cut where the parser says the movetext starts, not at the last
    // `]`-terminated line: a comment that wraps onto a line ending in `]`
    // (`{ [%eval 0.17]` / `[%clk 0:03:00] }`) put that boundary in the middle
    // of the movetext, and a header-less game — which `splitPgnIntoGames`
    // supports — has no such line at all, so `.last` threw.
    final text = game.pgnText;
    final headerPart = text
        .substring(0, movetextStart(text).clamp(0, text.length))
        .trimRight();
    final updatedText = headerPart.isEmpty
        ? '$updatedPgnMovetext\n'
        : '$headerPart\n\n$updatedPgnMovetext\n';
    if (game.pgnText != updatedText) {
      game.pgnText = updatedText;
      // A bound callback can outlive the collection it was editing. Only
      // changes to the currently loaded games invalidate its snapshots.
      if (allGames.contains(game)) {
        // Movetext can add/remove moves and variations, not just comments.
        // Cancel an older build too: until a fresh index is built, position
        // searches must replay the updated PGN instead of using stale hits.
        onContentChanged(resetIndex: true);
        notifyListeners();
      }
    }

    if (!writeToFile || filePath == null) return;
    unawaited(persistMetadata());
  }
}

/// In-memory navigation handle. Only its creating editor can restore it, and
/// only with the exact captured path and ordered game identities.
class PgnCollectionEditContext {
  PgnCollectionEditContext._(this._owner, this._path, this._games, this._edits);
  final Object _owner;
  final String? _path;
  final List<PgnGameEntry> _games;
  final _CollectionEdits _edits;
}

/// All mutable save bookkeeping for one adopted collection. This stays private
/// so callers cannot forge baselines, unblock uncertain writes or expose drill
/// overlays to persistence. Navigation retains the ledger, not a frozen receipt.
class _CollectionEdits {
  PgnSnapshot? baseline;
  PgnOpenResult? readFailure;
  String? uncertainPath;
  String capturedContent = '';
  bool wholeReplacement = false;
  String? errorMessage;
  PgnWriteResult? outcome;
  bool autoSaveBlocked = false;
  int pendingWrites = 0;
  Map<PgnGameEntry, String> persisted = Map.identity();

  /// Only these games need rating/summary header serialization before saving.
  final Set<PgnGameEntry> dirty = Set.identity();

  /// Deliberately retained after saving to distinguish our edits on later writes.
  final Set<PgnGameEntry> edited = Set.identity();

  /// Durable movetext substituted for the live drill-only annotations. A later
  /// deliberate annotation/rating edit removes its substitution; perspective
  /// edits patch the durable header without exposing drill notes.
  final Map<PgnGameEntry, String> screenOnly = Map.identity();
}
