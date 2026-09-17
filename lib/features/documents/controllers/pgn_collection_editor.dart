import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../utils/safe_change_notifier.dart';
import '../../../models/pgn_game_entry.dart';
import '../../../chess_core/pgn/pgn_text.dart' show extractHeaders;
import '../../../chess_core/pgn/study_metadata.dart';
import '../../../chess_core/pgn/mainline_lexer.dart' show movetextStart;
import '../models/pgn_document.dart';
import '../models/document_save_state.dart';
import '../repositories/document_save_actions.dart';
import '../repositories/pgn_collection_repository.dart';

/// Owns collection edit tracking, autosave scheduling and serialized writes.
/// Suppliers follow the legacy host's current collection; each write captures
/// its games and baseline before awaiting. No widget or storage singleton owns
/// this state. The remaining viewer migration will make game cores private.
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
  final Future<void Function()> Function(String content, String? path)?
  prepareReplacement;
  final PgnCollectionRepository repository;
  final _changes = StreamController<DocumentSaveState>.broadcast(sync: true);
  final _retainedDrafts = <RetainedDocumentDraft>[];
  PgnSnapshot? _baseline;
  PgnOpenResult? _readFailure;
  String? _uncertainPath;
  String _capturedContent = '';
  bool _reloading = false;
  bool _copying = false;
  bool _wholeReplacement = false;
  @override
  Stream<DocumentSaveState> get changes => _changes.stream;
  @override
  DocumentSaveState get state => DocumentSaveState(
    path: filePath ?? '',
    content: _capturedContent,
    baseline: _baseline,
    dirtyOverride:
        hasUnsavedChanges || (filePath == null && allGames.isNotEmpty),
    pendingEdits: hasUnsavedChanges,
    outcome: lastResult,
    readFailure: _readFailure,
    uncertainPath: _uncertainPath,
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
      return await repository.open(_uncertainPath ?? filePath ?? '');
    } catch (error) {
      return PgnReadFailed(error);
    }
  }

  @override
  void keepEditing() {
    if (state.busy || isDisposed) return;
    if (lastResult is! PgnWriteUncertain) lastResult = null;
    errorMessage = null;
    _readFailure = null;
    notifyListeners();
  }

  @override
  Future<PgnWriteResult?> saveCopy(String destination) async {
    if (isDisposed || state.busy || allGames.isEmpty) return null;
    persistDebounce?.cancel();
    persistDebounce = null;
    final source = allGames;
    final output = snapshotForSave();
    final content = _serialize(output);
    _capturedContent = content;
    final previous = lastResult;
    final previousUncertainPath = _uncertainPath;
    _copying = true;
    notifyListeners();
    PgnWriteResult result;
    try {
      result = await repository.create(destination, content);
    } catch (error) {
      result = PgnWriteUncertain(error: error, before: null, observed: null);
    }
    if (!isDisposed && identical(source, allGames)) {
      if (result is PgnSaved) {
        onSavedCopy(result.after.path);
        _persistedGames = Map.identity()..addAll(output);
        _baseline = result.after;
        _wholeReplacement = false;
        _uncertainPath = null;
        _readFailure = null;
        errorMessage = null;
      } else {
        lastResult =
            previous is PgnWriteUncertain && result is! PgnWriteUncertain
            ? previous
            : result;
        _uncertainPath = result is PgnWriteUncertain
            ? destination
            : previousUncertainPath;
        _autoSaveBlocked = true;
        errorMessage = _describe(lastResult!);
      }
    }
    _copying = false;
    notifyListeners();
    // Late edits stay dirty. Saving the copy does not start an implicit write.
    return result;
  }

  @override
  Future<void> reloadPreservingDraft() async {
    if (isDisposed || state.busy || prepareReplacement == null) return;
    persistDebounce?.cancel();
    persistDebounce = null;
    final source = allGames;
    _reloading = true;
    _readFailure = null;
    notifyListeners();
    try {
      final opened = await inspectCurrent();
      if (opened is! PgnOpened) {
        _readFailure = opened;
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
      _baseline = opened.snapshot;
      _capturedContent = opened.snapshot.content;
      _autoSaveBlocked = true;
      _uncertainPath = null;
      lastResult = null;
    } catch (error) {
      _readFailure = PgnReadFailed(error);
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
      baseline: _baseline,
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
    persistDebounce?.cancel();
    persistDebounce = null;
    final draft = _retainedDrafts[index];
    final source = allGames;
    final baseline = _baseline;
    final currentPath = filePath;
    final outcome = lastResult;
    final uncertainPath = _uncertainPath;
    _reloading = true;
    _readFailure = null;
    notifyListeners();
    try {
      final adopt = await prepareReplacement!(draft.content, currentPath);
      if (isDisposed || !identical(source, allGames)) return;
      final displaced = await _retainCurrentDraft();
      if (isDisposed || !identical(source, allGames)) return;
      adopt();
      _retainedDrafts.removeAt(index);
      if (displaced != null) _retainedDrafts.add(displaced);
      _baseline = baseline;
      _capturedContent = draft.content;
      _wholeReplacement = true;
      _editedGames.addAll(allGames);
      _autoSaveBlocked = true;
      if (outcome is PgnWriteUncertain) {
        lastResult = outcome;
        _uncertainPath = uncertainPath;
      }
    } catch (error) {
      _readFailure = PgnReadFailed(error);
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
    persistDebounce?.cancel();
    persistDebounce = null;
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

  Timer? persistDebounce;
  String? errorMessage;
  final _outcomes = Expando<PgnWriteResult>();
  PgnWriteResult? get lastResult => _outcomes[_persistedGames];
  set lastResult(PgnWriteResult? value) => _outcomes[_persistedGames] = value;
  bool autoSave = true;
  final _blocked = Expando<bool>();
  bool get _autoSaveBlocked => _blocked[_persistedGames] ?? false;
  set _autoSaveBlocked(bool value) => _blocked[_persistedGames] = value;
  int _pendingWrites = 0;
  bool get isSaving => _pendingWrites > 0;
  bool get needsSaveRecovery => _autoSaveBlocked || _retainedDrafts.isNotEmpty;

  bool get hasUnsavedChanges =>
      _wholeReplacement ||
      _dirtyGames.isNotEmpty ||
      _editedGames.any(
        (g) =>
            (_screenOnlyMovetext[g] ?? g.pgnText).trim() !=
            (_persistedGames[g] ?? g.pgnText).trim(),
      );

  void setAutoSave(bool value) {
    if (autoSave == value) return;
    autoSave = value;
    persistDebounce?.cancel();
    persistDebounce = null;
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
      errorMessage =
          'Unsaved changes — save or discard them before closing or opening another PGN.';
      notifyListeners();
      return false;
    }
    return true;
  }

  void discardChanges() {
    persistDebounce?.cancel();
    persistDebounce = null;
    for (final g in _editedGames) {
      final original = _persistedGames[g];
      if (original == null) continue;
      g.pgnText = original;
      g.headers
        ..clear()
        ..addAll(extractHeaders(original));
      g.studyRating = int.tryParse(g.headers['StudyRating'] ?? '') ?? 0;
      g.studySummary = g.headers['StudySummary'] ?? '';
    }
    _wholeReplacement = false;
    _dirtyGames.clear();
    _editedGames.clear();
    _screenOnlyMovetext.clear();
    errorMessage = null;
    lastResult = null;
    onContentChanged(resetIndex: true);
    notifyListeners();
  }

  Map<PgnGameEntry, String> _persistedGames = Map.identity();
  Future<void> _metadataWrites = Future.value();

  void adoptPersistedGames(List<PgnGameEntry> games, {PgnSnapshot? baseline}) {
    _baseline = baseline;
    _capturedContent = baseline?.content ?? '';
    _wholeReplacement = false;
    _uncertainPath = null;
    _readFailure = null;
    errorMessage = null;
    _dirtyGames.clear();
    _persistedGames = Map.identity();
    for (final game in games) {
      _persistedGames[game] = game.pgnText;
    }
  }

  void rememberPersistedGame(PgnGameEntry game) {
    _persistedGames.putIfAbsent(game, () => game.pgnText);
    _editedGames.add(game);
  }

  /// Games whose rating or summary changed since the last write.  Their
  /// `[StudyRating]` / `[StudySummary]` headers are rewritten at persist
  /// time; every other game's text is written as it stands.  Rewriting all
  /// of them — in a `compute` that copied the whole collection into another
  /// isolate — was the cost of every comment edit.
  final Set<PgnGameEntry> _dirtyGames = Set.identity();

  /// Movetext as it stood before something annotated a game *for the screen
  /// only* — solitaire's guess notes. [doPersistMetadata] writes this in
  /// place of the live text, so the drill's "(revealed)" notes can sit in the
  /// movetext, ride along with Copy PGN and Add to study, and still never
  /// reach the reader's file behind their back. A later deliberate write to
  /// the same game (a comment edit, an engine review, a star) drops the
  /// substitution: at that point the in-memory copy is the one that counts.
  final Map<PgnGameEntry, String> _screenOnlyMovetext = Map.identity();

  /// Games this session has actually changed. Not cleared after a write: it
  /// is what a *later* write needs in order to tell our edits apart from
  /// whatever else has reached the file since, and re-substituting text that
  /// is already on disk costs nothing.
  final Set<PgnGameEntry> _editedGames = Set.identity();

  /// Forget which games were edited — the collection they belong to is going
  /// away. Paired with [clearScreenOnlyMovetext].
  void clearEditedGames() => _editedGames.clear();

  /// Forget every screen-only substitution — the collection they described
  /// is going away.
  void clearScreenOnlyMovetext() => _screenOnlyMovetext.clear();

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
    _dirtyGames.add(game);
    _editedGames.add(game);
    if (changed) onContentChanged(resetIndex: false);
    notifyListeners();
    unawaited(persistMetadata());
    onReclaimFocus?.call();
  }

  Future<void> persistMetadata() async {
    persistDebounce?.cancel();
    persistDebounce = null;
    if (!autoSave || _autoSaveBlocked || _reloading || _copying) return;
    persistDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(doPersistMetadata());
    });
  }

  /// Snapshot all games for Save As, including staged metadata edits.
  Map<PgnGameEntry, String> snapshotForSave() {
    _prepareMetadata();
    return {for (final g in allGames) g: _screenOnlyMovetext[g] ?? g.pgnText};
  }

  List<PgnGameEntry> _prepareMetadata() {
    final dirty = List.of(_dirtyGames);
    _dirtyGames.clear();
    // A game the user has just rated is a game they touched: write what is
    // in memory, notes and all, rather than a snapshot taken before them.
    for (final g in dirty) {
      _screenOnlyMovetext.remove(g);
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
    persistDebounce?.cancel();
    persistDebounce = null;
    final path = filePath;
    if (path == null ||
        !isActive() ||
        _autoSaveBlocked ||
        _reloading ||
        _copying) {
      return;
    }
    final games = allGames;
    final preamble = collectionPreamble();
    final originals = _persistedGames;
    final dirty = _prepareMetadata();
    final wholeReplacement = _wholeReplacement;
    final baseline = _baseline;

    final output = {
      for (final g in games) g: _screenOnlyMovetext[g] ?? g.pgnText,
    };
    _capturedContent = _serialize(output);
    _pendingWrites++;
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
        result = (_blocked[originals] ?? false)
            ? _outcomes[originals]!
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
      _outcomes[originals] = result;
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
        errorMessage = recovery != null
            ? 'Changes could not be merged with $path. A recovery copy was saved to $recovery. ${_describe(result)}'
            : 'Changes to $path are unsaved: ${_describe(result)}. Recovery save also failed: $recoveryError';
        _blocked[originals] = true;
        if (filePath == path && identical(allGames, games)) {
          _dirtyGames.addAll(dirty);
          // A failed or uncertain operation never resumes implicitly.
          _autoSaveBlocked = true;
          if (result is PgnWriteUncertain) _uncertainPath = path;
        }
        notifyListeners();
        return;
      }
      for (final g in games) {
        originals[g] = output[g]!;
      }
      // Everything past this point writes back to *controller* state, which
      // is only ours while the collection we wrote is still the loaded one —
      // and it may not be, because `_adoptCollection` fires this flush and
      // then immediately replaces the collection.  Stamping regardless would
      // hang the outgoing file's mtime on the incoming collection (defeating
      // every staleness check) and mark the incoming FEN index stale for a
      // write that never touched it.
      if (filePath != path || !identical(allGames, games)) return;
      // This write is ours, and the in-memory copy above already matches it.
      // Re-stamping keeps a caller comparing mtimes from reading our own save
      // as somebody else's edit and reloading the whole file for nothing.
      _baseline = result.after;
      _wholeReplacement = false;
      _uncertainPath = null;
      _readFailure = null;
      errorMessage = null;
      lastResult = result;
      DateTime? modified;
      try {
        modified = await repository.modified(path);
      } catch (_) {
        // The committed receipt remains valid even if derived stat refresh fails.
      }
      if (filePath == path && identical(allGames, games)) {
        onSaved(modified);
      }
    });
    _metadataWrites = task.catchError((Object e) {
      errorMessage = 'Could not save: $e';
      notifyListeners();
    });
    try {
      await _metadataWrites;
    } finally {
      _pendingWrites--;
      notifyListeners();
    }
  }

  /// Flush an outstanding autosave and await all serialized writes. The host
  /// separately owns derived indexes and their lifecycle.
  Future<void> flushPendingMetadata() async {
    if (persistDebounce != null) await doPersistMetadata();
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
      _screenOnlyMovetext.remove(game);
      _editedGames.add(game);
    } else {
      _screenOnlyMovetext.putIfAbsent(game, () => game.pgnText);
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
