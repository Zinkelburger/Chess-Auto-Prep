// Part of pgn_viewer_controller.dart: metadata/comment persistence — study
// ratings, StudyRating/StudySummary header rewrites, and debounced move
// comment writes back to the source file. Same library as the controller, so
// private members resolve across the class/mixin boundary.
part of '../pgn_viewer_controller.dart';

/// Metadata/comment persistence for [PgnViewerController]. State shared with
/// the rest of the controller is declared abstract here and implemented by
/// the class; fields owned solely by this group live in this mixin.
mixin _MetadataOps on ChangeNotifier {
  // Implemented by PgnViewerController.
  bool Function() get isActive;
  VoidCallback? get onReclaimFocus;
  String? get filePath;
  DateTime? get loadedFileModified;
  set loadedFileModified(DateTime? value);
  List<PgnGameEntry> get allGames;
  List<PgnGameEntry> get filteredGames;
  int get currentGameIndex;
  PgnFenIndex get _fenIndex;

  Timer? persistDebounce;

  /// Games whose rating or summary changed since the last write.  Their
  /// `[StudyRating]` / `[StudySummary]` headers are rewritten at persist
  /// time; every other game's text is written as it stands.  Rewriting all
  /// of them — in a `compute` that copied the whole collection into another
  /// isolate — was the cost of every comment edit.
  final Set<PgnGameEntry> _dirtyGames = Set.identity();

  void setRating(int stars) {
    if (filteredGames.isEmpty) return;
    final game = filteredGames[currentGameIndex];
    game.studyRating = stars;
    _dirtyGames.add(game);
    notifyListeners();
    unawaited(persistMetadata());
    onReclaimFocus?.call();
  }

  Future<void> persistMetadata() async {
    persistDebounce?.cancel();
    persistDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(doPersistMetadata());
    });
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
    if (path == null || !isActive()) return;
    final games = allGames;
    final dirty = List.of(_dirtyGames);
    _dirtyGames.clear();

    if (dirty.isNotEmpty) {
      final rewritten = buildMetadataOutput([
        for (final g in dirty)
          (pgn: g.pgnText, rating: g.studyRating, summary: g.studySummary),
      ]);
      for (var i = 0; i < dirty.length; i++) {
        dirty[i].pgnText = rewritten[i];
      }
    }

    try {
      await StorageFactory.instance.writeFile(
        path,
        '${games.map((g) => g.pgnText).join('\n\n')}\n',
      );
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
      loadedFileModified = (await StorageFactory.instance.fileStat(
        path,
      ))?.modified;
      _fenIndex.markStale();
    } catch (e) {
      debugPrint('Failed to persist metadata: $e');
    }
  }

  /// Run a debounced persist now (for the collection currently loaded), and
  /// persist the FEN index if any write left its stamp behind.  Called when
  /// the collection is replaced or the controller is disposed.
  Future<void> flushPendingMetadata() async {
    // Captured before the first await.  This is called *by* the code that is
    // about to swap the collection out, so reading [filePath] afterwards
    // would name the file that is arriving and write the outgoing
    // collection's index into its `.fenidx`.
    final path = filePath;
    final total = allGames.length;
    if (persistDebounce != null) await doPersistMetadata();
    await _fenIndex.flushIfStale(filePath: path, gameTotal: total);
  }

  void persistMoveComments(String updatedPgnMovetext) {
    if (filteredGames.isEmpty || filePath == null) return;
    persistMoveCommentsFor(filteredGames[currentGameIndex], updatedPgnMovetext);
  }

  /// Like [persistMoveComments] but bound to a specific [game] object, so
  /// debounced edits that flush after the user has switched games still patch
  /// the game they were typed on.
  ///
  /// The in-memory game is always updated, so a pasted collection's "Copy
  /// PGN" carries the edits too; only the write to disk needs a file.
  void persistMoveCommentsFor(PgnGameEntry game, String updatedPgnMovetext) {
    final headerEnd = _headerBlockEndRe.allMatches(game.pgnText).last;
    final headerPart = game.pgnText.substring(0, headerEnd.end);
    game.pgnText = '$headerPart\n$updatedPgnMovetext\n';

    if (filePath == null) return;
    unawaited(persistMetadata());
  }
}

final RegExp _headerBlockEndRe = RegExp(r'\]\s*\n');
