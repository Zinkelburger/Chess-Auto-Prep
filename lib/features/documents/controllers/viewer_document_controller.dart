import '../repositories/viewer_position_index_repository.dart';
import '../repositories/viewer_opening_repository.dart';
import '../repositories/viewer_solitaire_repository.dart';
import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'pgn_collection_editor.dart';
import 'viewer_collection_controller.dart';
import 'viewer_filter_controller.dart';
import 'viewer_presentation_controller.dart';
import 'viewer_reading_controller.dart';
import 'viewer_library_controller.dart';
import '../models/pgn_document.dart';
import '../models/pgn_workspace_snapshot.dart';
import '../models/viewer_collection_load.dart';
import '../models/viewer_filter_selection.dart';
import '../models/viewer_perspective.dart';
import '../repositories/desktop_fullscreen_port.dart';
import '../repositories/pgn_collection_decoder.dart';
import '../repositories/pgn_collection_filter.dart';
import '../repositories/pgn_collection_repository.dart';
import '../repositories/pgn_library_repository.dart';
import '../repositories/viewer_preferences_repository.dart';
import '../../../models/pgn_filter_models.dart';
import '../../../models/pgn_game_entry.dart';
import '../repositories/viewer_analysis_port.dart';
import '../../../chess_core/pgn/pgn_opening_headers.dart';
import '../../../utils/safe_change_notifier.dart';
import 'pgn_fen_index.dart';
import '../repositories/pgn_viewer_handle.dart';

/// Owns collection loading, document replacement, filtering and recovery.
/// Reading modes and persistence commands have their own public owners; this
/// controller has no forwarding API or mirrored child errors.
class ViewerDocumentController extends ChangeNotifier with SafeChangeNotifier {
  ViewerDocumentController({
    required DesktopFullscreenPort window,
    required this.positionIndex,
    required this.openings,
    required this.solitaireRepository,
    required this.collectionRepository,
    required this.collectionDecoder,
    required this.collectionFilter,
    required this.library,
    required this.preferences,
    required PgnViewerHandle pgnWidgetController,
    required ViewerAnalysisPort analysisController,
    this.isActive = _alwaysActive,
    this.schedulePostFrame,
    this.onReclaimFocus,
  }) {
    editor = PgnCollectionEditor(
      repository: collectionRepository,
      prepareReplacement: _prepareRecoveryReplacement,
      path: () => filePath,
      games: () => collection.games,
      collectionPreamble: () => collectionPreamble,
      selectedGame: () => collection.visibleGames.isEmpty
          ? null
          : collection.visibleGames[collection.selectedIndex],
      isActive: isActive,
      onReclaimFocus: onReclaimFocus,
      onContentChanged: ({required resetIndex}) {
        if (resetIndex) positionIndexController.reset();
        _markCollectionChanged();
      },
      onSavedCopy: (path) {
        filePath = path;
        loadedFileModified = null;
        positionIndexController.reset();
        unawaited(reading.saveSession());
      },
      onSaved: (modified) {
        if (isDisposed) return;
        loadedFileModified = modified;
      },
    );
    presentation = ViewerPresentationController(
      window: window,
      onChanged: notifyListeners,
      onReclaimFocus: onReclaimFocus,
    );
    reading = ViewerReadingController(
      collection: collection,
      handle: pgnWidgetController,
      analysis: analysisController,
      presentation: presentation,
      openings: openings,
      solitaireRepository: solitaireRepository,
      preferences: preferences,
      path: () => filePath,
      collectionLoading: () => isLoading,
      index: () => positionIndexController.value,
      onAnnotatedGame: persistMoveCommentsFor,
      isActive: isActive,
      schedulePostFrame: schedulePostFrame,
      onReclaimFocus: onReclaimFocus,
    );
  }

  final ViewerPositionIndexRepository positionIndex;
  final ViewerOpeningRepository openings;
  final ViewerSolitaireRepository solitaireRepository;
  final PgnCollectionRepository collectionRepository;
  final PgnCollectionDecoder collectionDecoder;
  final PgnCollectionFilter collectionFilter;
  late final filters = ViewerFilterController(collectionFilter);
  final PgnLibraryRepository library;
  final ViewerPreferencesRepository preferences;
  late final PgnCollectionEditor editor;
  Future<void Function()> _prepareRecoveryReplacement(
    String content,
    String? path, {
    int? expectedGames,
  }) async {
    final decoded = await collectionDecoder.decode(content);
    final entries = List<PgnGameEntry>.of(decoded.games);
    if ((entries.isEmpty && expectedGames != 0) ||
        (expectedGames != null && entries.length != expectedGames)) {
      throw const FormatException('No valid games in the document');
    }
    return () {
      _abandonInFlightWork();
      _adoptCollection(
        path: path,
        entries: entries,
        newPerspective: Perspective.forCollection(
          entries,
          current: presentation.perspective,
        ),
        preamble: decoded.preamble,
        flushOutgoing: false,
      );
      if (expectedGames == null) unawaited(reading.loadCurrentGame());
      notifyListeners();
    };
  }

  PgnWorkspaceSnapshot captureWorkspace() => editor.captureWorkspace(
    gameIndex: collection.visibleGames.isEmpty
        ? 0
        : collection.games.indexOf(
            collection.visibleGames[collection.selectedIndex],
          ),
    ply: collection.visibleGames.isEmpty
        ? 0
        : reading.resumePlyFor(
            collection.visibleGames[collection.selectedIndex],
          ),
    flipped: presentation.boardFlipped,
  );

  Future<void> restoreWorkspace(PgnWorkspaceSnapshot snapshot) async {
    await editor.restoreWorkspace(snapshot);
    final epoch = _loadEpoch;
    if (collection.games.isNotEmpty) {
      collection.select(
        snapshot.gameIndex.clamp(0, collection.games.length - 1),
      );
      reading.bookmark(
        collection.games[collection.selectedIndex],
        snapshot.ply,
      );
      await reading.loadCurrentGame(enrich: false);
      if (!_isCurrentLoad(epoch)) return;
    }
    presentation.restoreBoard(flipped: snapshot.flipped);
    notifyListeners();
  }

  void persistMoveCommentsFor(
    PgnGameEntry game,
    String movetext, {
    bool writeToFile = true,
  }) {
    if (isDisposed || !collection.containsGame(game)) return;
    editor.persistMoveCommentsFor(game, movetext, writeToFile: writeToFile);
  }

  late final ViewerReadingController reading;
  late final Listenable changes = Listenable.merge([
    this,
    editor,
    reading,
    libraryState,
  ]);
  final bool Function() isActive;
  final void Function(void Function() callback)? schedulePostFrame;
  final VoidCallback? onReclaimFocus;

  static bool _alwaysActive() => true;

  // File state
  String? filePath;

  /// Label for a collection opened from captured content instead of a file.
  String? _contentTitle;
  String? get collectionTitle =>
      filePath == null ? _contentTitle : p.basenameWithoutExtension(filePath!);

  /// Modification time of [filePath] as it was when this collection was read,
  /// or null for a collection with no backing file.
  ///
  /// Held so a caller can ask whether the loaded copy is still the file: the
  /// games cache is written behind this controller's back — the review of your
  /// recent games patches every game it analyses with the scores it found —
  /// and a screen that reuses an already-loaded collection would otherwise
  /// show the pre-patch text, graph and all missing.
  DateTime? loadedFileModified;
  final collection = ViewerCollectionController();

  void _markCollectionChanged() {
    collection.markContentChanged();
    filters.sourceChanged();
  }

  Future<void> persistViewerPreference(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (isDisposed || !isActive()) return;
      errorMessage = 'Could not save Viewer preferences. Try again.';
      notifyListeners();
    }
  }

  /// A deliberate file/handoff request always wins over startup restoration.
  Future<void> restoreLastSession() async {
    if (_loadEpoch != 0 || isDisposed) return;
    try {
      final path = await reading.sessions.lastFile();
      if (!_isCurrentLoad(0) || path == null) return;
      if (!await library.exists(path)) return;
      if (!_isCurrentLoad(0)) return;
      await loadFile(path);
    } catch (_) {
      if (!_isCurrentLoad(0)) return;
      errorMessage = 'Could not restore the previous reading session.';
      notifyListeners();
    }
  }

  /// Collection requests are independent of selected-game analysis.
  int _loadEpoch = 0;

  bool _isCurrentLoad(int epoch) =>
      !isDisposed && isActive() && epoch == _loadEpoch;

  /// Text above the first game in the loaded file — a `;`/`%` banner, which
  /// is not a game and so is not in [collection.games]. Held here because a write
  /// rewrites the file from [collection.games] alone and would otherwise delete it.
  String collectionPreamble = '';

  late final ViewerPresentationController presentation;

  Map<String, String>? get _currentHeaders =>
      collection.selectedIndex >= 0 &&
          collection.selectedIndex < collection.visibleGames.length
      ? collection.visibleGames[collection.selectedIndex].headers
      : null;
  void setPerspective(Perspective value) {
    presentation.setPerspective(value, _currentHeaders);
    unawaited(persistPerspective());
  }

  Future<void> persistPerspective() =>
      editor.setPerspectiveHeader(presentation.perspective.toHeaderValue());

  late final PgnFenIndex positionIndexController = PgnFenIndex(
    repository: positionIndex,
    isActive: isActive,
    onChanged: notifyListeners,
  );

  bool _loadingCollection = false;
  bool get isLoading => _loadingCollection || filters.isLoading;

  late final libraryState = ViewerLibraryController(
    library: library,
    preferences: preferences,
    isActive: isActive,
  );

  String? errorMessage;

  @override
  void dispose() {
    unawaited(reading.saveSession());
    _loadEpoch++;
    filters.dispose();
    presentation.dispose();
    reading.dispose();
    libraryState.dispose();
    _openingEpoch++;
    positionIndexController.cancel();
    final flush = editor.flushPendingMetadata();
    unawaited(flush.catchError((Object _) {}).whenComplete(editor.dispose));
    super.dispose();
  }

  /// End work tied to the departing collection before invoking cancellation
  /// callbacks. Pending document writes retain their own captured destination;
  /// they are flushed by adoption/close and are never treated as cancelled.
  bool _abandoningWork = false;

  @override
  void notifyListeners() {
    // Cancellation can synchronously notify through playback or Solitaire.
    // The replacing command publishes once its collection transition is ready.
    if (!_abandoningWork) super.notifyListeners();
  }

  int _abandonInFlightWork() {
    final revision = ++_loadEpoch;
    _openingEpoch++;
    filters.invalidate();
    _loadingCollection = false;
    isPreparingCollection = false;
    reading.restoringSession = false;
    _abandoningWork = true;
    try {
      positionIndexController.reset();
      reading.abandon();
    } finally {
      _abandoningWork = false;
    }
    return revision;
  }

  /// Install one collection with its edit ledger and initial reading state.
  /// Every caller abandons superseded work before adopting the replacement.
  void _adoptCollection({
    required String? path,
    required List<PgnGameEntry> entries,
    required Perspective newPerspective,
    String preamble = '',
    String? contentTitle,
    PgnSnapshot? baseline,
    bool flushOutgoing = true,
    PgnCollectionEditContext? editContext,
  }) {
    // Capture the outgoing collection's pending metadata before its path
    // and games are replaced.
    if (flushOutgoing) unawaited(editor.flushPendingMetadata());
    _openingEpoch++;
    filePath = path;
    _contentTitle = contentTitle;
    // Whoever adopted a collection knows the mtime if there is one; a
    // from-memory collection has none. Cleared here so it can never outlive
    // the file it described.
    loadedFileModified = null;
    collection.adopt(entries);
    _markCollectionChanged();
    editor.adoptPersistedGames(
      collection.games,
      baseline: baseline,
      context: editContext,
    );
    collectionPreamble = preamble;
    filters.reset();
    reading.resetForCollection();
    presentation.restoreBoard(perspective: newPerspective);
  }

  /// [restoreSavedSlice] — reapply the slice persisted for this file. Off for
  /// single-game handoffs (Games page "Review"): a leftover slice there only
  /// hides the target game and confuses the count display.
  Future<bool> loadFile(String path, {bool restoreSavedSlice = true}) async {
    if (isDisposed || !isActive() || !editor.canReplaceCollection()) {
      return false;
    }
    unawaited(reading.saveSession());
    final loadEpoch = _abandonInFlightWork();
    errorMessage = null;
    final fileName = p.basename(path);

    _loadingCollection = true;
    notifyListeners();
    try {
      final PgnSnapshot snapshot;
      final DecodedPgnCollection? decoded;
      final DateTime? modified;
      try {
        if (!_isCurrentLoad(loadEpoch)) return false;
        final opened = await collectionRepository.open(path);
        if (!_isCurrentLoad(loadEpoch)) return false;
        switch (opened) {
          case PgnMissing():
            return _failCollectionLoad(loadEpoch, 'File not found: $fileName');
          case PgnReadFailed():
            return _failCollectionLoad(loadEpoch, 'Could not read $fileName');
          case PgnOpened(snapshot: final observed):
            snapshot = observed;
            decoded = await _decodeCollection(
              snapshot.content,
              loadEpoch,
              fileName: fileName,
            );
        }
        if (!_isCurrentLoad(loadEpoch) || decoded == null) return false;
        modified = await collectionRepository.modified(path);
      } catch (_) {
        return _failCollectionLoad(loadEpoch, 'Could not read $fileName');
      }
      if (!_isCurrentLoad(loadEpoch)) return false;
      // Manual edits or a recovery action may have started during the read.
      // The initial permission to replace is not valid for that newer state.
      if (!editor.canReplaceCollection()) {
        if (_isCurrentLoad(loadEpoch)) {
          _loadingCollection = false;
          notifyListeners();
        }
        return false;
      }
      final entries = List<PgnGameEntry>.of(decoded.games);

      reading.restoringSession = true;
      _adoptCollection(
        path: path,
        entries: entries,
        newPerspective: Perspective.forCollection(
          entries,
          current: presentation.perspective,
        ),
        preamble: decoded.preamble,
        baseline: snapshot,
      );
      loadedFileModified = modified;
      notifyListeners();

      await libraryState.addToRecentFiles(path);
      if (!_isCurrentLoad(loadEpoch)) return false;
      final detect = await preferences.autoDetectOpenings();
      if (!_isCurrentLoad(loadEpoch)) return false;
      autoDetectOpenings = detect;
      // A saved filter can depend on inferred opening tags. Ordinary opens
      // should display the game before classifying the entire collection.
      final savedSlice = restoreSavedSlice
          ? await preferences.loadSlice(path)
          : null;
      if (!_isCurrentLoad(loadEpoch)) return false;
      final needsOpeningTags =
          savedSlice?.headerFilters.any(
            (filter) => filter.field == 'ECO' || filter.field == 'Opening',
          ) ??
          false;
      if (savedSlice != null) {
        if (needsOpeningTags) {
          await classifyOpenings();
          if (!_isCurrentLoad(loadEpoch)) return false;
        }
        // Reuse a saved position index when restoring position filters.
        // Deferring this read must not force those filters to replay all games.
        if ((savedSlice.positionInput?.trim().isNotEmpty ?? false) ||
            savedSlice.additionalPositions.any(
              (position) => position.trim().isNotEmpty,
            )) {
          await positionIndexController.tryLoadPersisted(path, _indexSource);
          if (!_isCurrentLoad(loadEpoch)) return false;
        }
        await _restoreSavedSlice(savedSlice, entries);
      }
      if (restoreSavedSlice) {
        if (!_isCurrentLoad(loadEpoch)) return false;
        final session = await reading.sessions.load(path);
        if (!_isCurrentLoad(loadEpoch)) return false;
        if (session != null) {
          _applySortMode(session.sortMode);
          final index = session.locate(collection.games);
          if (index >= 0) {
            final game = collection.games[index];
            reading.bookmark(game, session.ply);
            final filteredIndex = collection.visibleGames.indexOf(game);
            if (filteredIndex >= 0) collection.select(filteredIndex);
          }
        }
      }
      reading.restoringSession = false;
      _loadingCollection = false;
      final selectionRevision = collection.selectionRevision;
      final selectedGame = collection.selectedGame;
      await reading.loadCurrentGame();
      if (!_isCurrentLoad(loadEpoch) ||
          collection.selectionRevision != selectionRevision ||
          !identical(collection.selectedGame, selectedGame))
        return false;
      await reading.saveSession();
      if (!_isCurrentLoad(loadEpoch)) return false;
      unawaited(_prepareCollection(loadEpoch, classify: !needsOpeningTags));
      return _isCurrentLoad(loadEpoch);
    } catch (e) {
      if (!_isCurrentLoad(loadEpoch)) return false;
      _loadingCollection = false;
      reading.restoringSession = false;
      errorMessage = 'Could not open $fileName: $e';
      notifyListeners();
      return false;
    }
  }

  bool _failCollectionLoad(int epoch, String message) {
    if (!_isCurrentLoad(epoch)) return false;
    _loadingCollection = false;
    errorMessage = message;
    notifyListeners();
    return false;
  }

  Future<DecodedPgnCollection?> _decodeCollection(
    String content,
    int epoch, {
    String? fileName,
  }) async {
    if (!_isCurrentLoad(epoch)) return null;
    String message;
    if (content.trim().isEmpty) {
      message = fileName == null
          ? 'Clipboard is empty — copy some PGN first'
          : 'File is empty: $fileName';
    } else {
      try {
        final decoded = await collectionDecoder.decode(content);
        if (!_isCurrentLoad(epoch)) return null;
        if (decoded.games.isNotEmpty) return decoded;
        message = fileName == null
            ? 'No valid PGN games found in the pasted text'
            : 'No valid PGN games in $fileName';
      } catch (_) {
        message = fileName == null
            ? 'Could not parse the pasted PGN'
            : 'Could not parse $fileName';
      }
    }
    _failCollectionLoad(epoch, message);
    return null;
  }

  /// Adopt a decoded in-memory document through the same collection boundary
  /// as file loading. This synchronous handoff validates draft protection and
  /// invalidates outgoing async work before publishing. The host can then await
  /// [reading.loadCurrentGame] to restore reader/analysis state. Returns the request
  /// revision, or null when adoption is refused.
  int? adoptDecodedCollection(
    DecodedPgnCollection document, {
    String? initialFen,
    String? title,
  }) {
    if (isDisposed || !isActive() || !editor.canReplaceCollection()) {
      return null;
    }
    unawaited(reading.saveSession());
    final revision = _abandonInFlightWork();
    errorMessage = null;
    _adoptCollection(
      path: null,
      entries: document.games,
      newPerspective: Perspective.forCollection(
        document.games,
        current: presentation.perspective,
      ),
      preamble: document.preamble,
      contentTitle: title,
    );
    reading.pgnInitialFen = initialFen;
    if (collection.games.isEmpty) reading.currentPosition = Chess.initial;
    notifyListeners();
    return revision;
  }

  /// Load PGN games directly from raw text (e.g. pasted from the clipboard).
  /// Held in memory only — there is no backing file, so rating/comment edits
  /// are not persisted to disk.
  ///
  /// [initialFen] parks the first game on that position instead of its start.
  /// It has to be handed in here rather than set afterwards: the viewer widget
  /// reads it during the build this load triggers, which is the only moment
  /// the freshly parsed game and the cursor request meet.
  Future<bool> loadPgnContent(
    String content, {
    String? initialFen,
    String? title,
  }) async {
    if (isDisposed || !isActive() || !editor.canReplaceCollection()) {
      return false;
    }
    unawaited(reading.saveSession());
    final loadEpoch = _abandonInFlightWork();
    errorMessage = null;
    _loadingCollection = true;
    notifyListeners();
    final decoded = await _decodeCollection(content, loadEpoch);
    if (!_isCurrentLoad(loadEpoch) || decoded == null) return false;
    if (!editor.canReplaceCollection()) {
      if (_isCurrentLoad(loadEpoch)) {
        _loadingCollection = false;
        notifyListeners();
      }
      return false;
    }
    final adoptedEpoch = adoptDecodedCollection(
      decoded,
      initialFen: initialFen,
      title: title,
    );
    if (adoptedEpoch == null || !_isCurrentLoad(adoptedEpoch)) return false;

    await reading.loadCurrentGame();
    if (!_isCurrentLoad(adoptedEpoch)) return false;
    try {
      final detect = await preferences.autoDetectOpenings();
      if (!_isCurrentLoad(adoptedEpoch)) return false;
      autoDetectOpenings = detect;
    } catch (_) {
      if (!_isCurrentLoad(adoptedEpoch)) return false;
      autoDetectOpenings = false;
      errorMessage = 'Could not load opening-detection preferences.';
      notifyListeners();
    }
    unawaited(_prepareCollection(adoptedEpoch));
    return _isCurrentLoad(adoptedEpoch);
  }

  /// Capture the live collection and reading cursor for app navigation. Games
  /// remain shared objects so edits made before leaving are kept; list order,
  /// filters and the selected position are independent of subsequent visits.
  Future<bool> Function() captureNavigationContext() {
    reading.rememberCurrentPlace();
    final entries = List<PgnGameEntry>.of(collection.games);
    final editContext = editor.captureEditContext();
    final visibleIndices = collection.visibleIndices;
    final path = filePath;
    final contentTitle = _contentTitle;
    final modified = loadedFileModified;
    final preamble = collectionPreamble;
    final viewPerspective = presentation.perspective;
    final flipped = presentation.boardFlipped;
    final gameIndex = collection.selectedIndex;
    final filterSelection = filters.selection;
    final sorting = collection.sortMode;
    final bookmarks = reading.captureBookmarks();
    final cursorFen = reading.handle.currentFen;
    final cursorPly = reading.handle.mainLineIndex;
    final initialFen = reading.pgnInitialFen;
    return () async {
      if (isDisposed || !isActive() || !editor.canReplaceCollection()) {
        return false;
      }
      final loadEpoch = _abandonInFlightWork();
      _adoptCollection(
        path: path,
        entries: List.of(entries),
        newPerspective: viewPerspective,
        preamble: preamble,
        contentTitle: contentTitle,
        editContext: editContext,
      );
      loadedFileModified = modified;
      collection.restoreView(
        indices: visibleIndices,
        selectedIndex: gameIndex,
        sortMode: sorting,
      );
      filters.restoreSelection(filterSelection);
      reading.restoreBookmarks(bookmarks);
      reading.pgnInitialFen = cursorFen ?? initialFen;
      _loadingCollection = false;
      errorMessage = null;
      filters.clearPendingRestore();
      if (collection.visibleGames.isEmpty) {
        reading.currentPosition = Chess.initial;
      }
      notifyListeners();
      final selectionRevision = collection.selectionRevision;
      final selectedGame = collection.selectedGame;
      await reading.loadCurrentGame();
      if (!_isCurrentLoad(loadEpoch) ||
          collection.selectionRevision != selectionRevision ||
          !identical(collection.selectedGame, selectedGame))
        return false;
      presentation.restoreBoard(flipped: flipped);
      notifyListeners();
      // The reader may keep the same PGN widget (and therefore skip parsing)
      // when two visits show identical game text. Explicitly restore its
      // cursor after the restored collection has reached the widget tree.
      schedulePostFrame?.call(() {
        if (!_isCurrentLoad(loadEpoch) ||
            collection.selectionRevision != selectionRevision ||
            !identical(collection.selectedGame, selectedGame))
          return;
        reading.handle.goToMainLineIndex(cursorPly);
      });
      // Resume enrichment if this visit was left before it finished. Its
      // retained games may differ from today's file, so rebuild their index.
      unawaited(_prepareCollection(loadEpoch, restoreIndex: false));
      return true;
    };
  }

  /// Close the loaded collection and put the viewer back on its start screen
  /// ("No PGN loaded" — browse button plus the recent list).
  ///
  /// Two things are deliberately *not* cleared: the recent-files list (it is
  /// the way back in) and the slice persisted on disk for this file, so
  /// reopening it still restores what you were looking at.
  void closeFile() {
    if (!editor.canReplaceCollection()) return;
    unawaited(reading.saveSession());
    unawaited(reading.closeSession());
    _abandonInFlightWork();
    errorMessage = null;
    // An empty collection: _adoptCollection nulls the protagonist fields the
    // same way this used to by hand.
    _adoptCollection(
      path: null,
      entries: <PgnGameEntry>[],
      newPerspective: const Perspective(),
    );
    reading.currentPosition = Chess.initial;
    presentation.restoreBoard(flipped: false);
    notifyListeners();
  }

  List<GameRecord> get _indexSource => [
    for (final game in collection.games)
      (
        headers: Map<String, String>.unmodifiable(game.headers),
        pgnText: game.pgnText,
      ),
  ];

  bool isPreparingCollection = false;

  /// Optional collection-wide work never holds the reader's loading overlay.
  Future<void> _prepareCollection(
    int epoch, {
    bool classify = true,
    bool restoreIndex = true,
  }) async {
    if (!_isCurrentLoad(epoch)) return;
    isPreparingCollection = true;
    notifyListeners();
    try {
      // Yield a frame before preparing snapshots for the workers.
      await Future<void>.delayed(Duration.zero);
      if (!_isCurrentLoad(epoch)) return;
      if (classify) await classifyOpenings();
      if (!_isCurrentLoad(epoch)) return;
      final path = filePath;
      if (restoreIndex &&
          path != null &&
          positionIndexController.value == null) {
        await positionIndexController.tryLoadPersisted(path, _indexSource);
      }
      if (!_isCurrentLoad(epoch)) return;
      if (positionIndexController.value == null) await _buildFenIndex();
    } catch (e) {
      if (_isCurrentLoad(epoch)) {
        debugPrint('Collection preparation failed: $e');
      }
    } finally {
      if (_isCurrentLoad(epoch)) {
        isPreparingCollection = false;
        notifyListeners();
      }
    }
  }

  Future<void> _buildFenIndex() {
    final gameData = collection.games
        .map(
          (g) => (
            headers: Map<String, String>.from(g.headers),
            pgnText: g.pgnText,
          ),
        )
        .toList();
    return positionIndexController.build(gameData, filePath: filePath);
  }

  bool autoDetectOpenings = true;
  int _openingEpoch = 0;

  void setAutoDetectOpenings(bool value) {
    if (autoDetectOpenings == value) return;
    autoDetectOpenings = value;
    _openingEpoch++;
    notifyListeners();
    if (value) unawaited(classifyOpenings());
  }

  /// Add missing tags to every game and save through the conflict-aware writer.
  Future<void> classifyOpenings() async {
    if (!autoDetectOpenings || collection.games.isEmpty) return;
    final games = collection.games;
    if (!games.any(needsOpeningHeaders)) return;
    final epoch = ++_openingEpoch;
    final contentRevision = collection.contentRevision;
    final openings = await this.openings.classify(_indexSource);
    if (isDisposed ||
        !isActive() ||
        !autoDetectOpenings ||
        !identical(collection.games, games) ||
        epoch != _openingEpoch ||
        contentRevision != collection.contentRevision) {
      return;
    }
    var changed = false;
    for (var i = 0; i < games.length; i++) {
      final opening = openings[i];
      if (opening == null) continue;
      editor.rememberPersistedGame(games[i]);
      if (fillOpeningHeaders(games[i], opening)) changed = true;
    }
    if (changed) {
      _markCollectionChanged();
      notifyListeners();
      if (editor.autoSave) await editor.doPersistMetadata();
    }
  }

  Future<void> _restoreSavedSlice(
    SliceConfig config,
    List<PgnGameEntry> entries,
  ) => _computeFilter(config, entries, restoring: true);

  Future<void> _computeFilter(
    SliceConfig config,
    List<PgnGameEntry> entries, {
    bool restoring = false,
  }) async {
    final previous = filters.selection;
    final pending = filters.compute(
      config,
      () => [
        for (final game in entries)
          (headers: game.headers, pgnText: game.pgnText),
      ],
      fenIndex: () => positionIndexController.value,
      restoring: restoring,
    );
    final request = filters.revision;
    notifyListeners();
    final selection = await pending;
    if (isDisposed || !isActive() || !filters.isCurrent(request)) return;
    if (selection == null || identical(selection, previous)) {
      notifyListeners();
      return;
    }
    _publishFilter(selection, restoring: restoring);
  }

  void _publishFilter(
    ViewerFilterSelection selection, {
    bool restoring = false,
  }) {
    final request = filters.revision;
    final path = filePath;
    if (!restoring) reading.rememberCurrentPlace();
    collection.applyFilter(selection.indices!);
    _applySortMode(null);
    reading.pgnInitialFen = null;
    if (!restoring) reading.tree.clearTree();
    notifyListeners();
    if (!filters.isCurrent(request) || restoring) return;
    unawaited(_persistFilter(path, selection.config));
    if (reading.tree.showOpeningTree) unawaited(reading.tree.rebuild());
    unawaited(reading.loadCurrentGame());
  }

  void applySlice(List<int> indices, SliceConfig config) {
    final wasLoading = filters.isLoading;
    final hadFilterError = filters.error != null;
    final changed = filters.apply(indices, config, collection.games.length);
    if (!changed) {
      if (wasLoading || hadFilterError) notifyListeners();
      return;
    }
    _publishFilter(filters.selection);
  }

  void resetFilters() {
    reading.rememberCurrentPlace();
    filters.reset();
    final request = filters.revision;
    final path = filePath;
    collection.resetFilter();
    _applySortMode(null);
    reading.pgnInitialFen = null;
    reading.tree.clearTree();
    notifyListeners();
    if (!filters.isCurrent(request)) return;
    unawaited(_persistFilter(path, const SliceConfig.empty()));
    if (reading.tree.showOpeningTree) unawaited(reading.tree.rebuild());
    unawaited(reading.loadCurrentGame());
  }

  Future<void> removeSliceChip(int index) async {
    final config = filters.withoutChip(index);
    if (config != null) await recomputeAndApplyConfig(config);
  }

  Future<void> applySlicePreset(HeaderFilterConfig filter) =>
      recomputeAndApplyConfig(filters.withPreset(filter));

  Future<void> recomputeAndApplyConfig(SliceConfig config) async {
    if (config.isEmpty) {
      resetFilters();
      return;
    }
    await _computeFilter(config, collection.games);
  }

  Future<void> _persistFilter(String? path, SliceConfig config) async {
    if (path == null) return;
    await persistViewerPreference(() => preferences.saveSlice(path, config));
  }

  void setSortMode(GameSortMode mode) {
    reading.rememberCurrentPlace();
    _applySortMode(mode, resetSelection: true);
    reading.pgnInitialFen = null;
    notifyListeners();
    unawaited(reading.loadCurrentGame());
  }

  /// Reorder newest-first *without* moving the cursor — for arrivals that are
  /// about to select a game by identity ([GameSortMode.dateDesc]). Unlike
  /// [setSortMode] this keeps no game loaded, because the caller is about to
  /// pick one and loading the wrong one first is a wasted parse and a visible
  /// flash of someone else's game.
  void sortNewestFirst() {
    if (collection.sortMode == GameSortMode.dateDesc) return;
    _applySortMode(GameSortMode.dateDesc);
    notifyListeners();
  }

  void _applySortMode(GameSortMode? mode, {bool resetSelection = false}) {
    reading.tree.clearCache();
    collection.sort(
      mode ?? collection.sortMode,
      resetSelection: resetSelection,
    );
  }

  String? defaultExportFileName() {
    if (filePath == null) return null;
    return '${p.basenameWithoutExtension(filePath!)}_slice.pgn';
  }

  String buildExportContent() {
    return '${collection.visibleGames.map((g) => g.pgnText).join('\n\n')}\n';
  }
}
