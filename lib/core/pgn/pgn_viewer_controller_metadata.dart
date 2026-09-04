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
  String get collectionPreamble;
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
    if (filteredGames.isEmpty) return;
    final game = filteredGames[currentGameIndex];
    game.studyRating = stars;
    _dirtyGames.add(game);
    _editedGames.add(game);
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
      for (var i = 0; i < dirty.length; i++) {
        dirty[i].pgnText = rewritten[i];
      }
    }

    // The banner above the first game goes back on the front. It is not a
    // game, so it is not in [games], and this write is the whole file: without
    // it, starring a game deleted the reader's own header text.
    final preamble = collectionPreamble;
    final gameTexts = [
      for (final g in games) _screenOnlyMovetext[g] ?? g.pgnText,
    ];
    final body = gameTexts.join('\n\n');
    final edited = {
      for (var i = 0; i < games.length; i++)
        if (_editedGames.contains(games[i])) i,
    };
    try {
      final content = await _contentToWrite(
        path: path,
        gameTexts: gameTexts,
        edited: edited,
        wholeFile: preamble.isEmpty ? '$body\n' : '$preamble\n\n$body\n',
      );
      if (content == null) return;
      await StorageFactory.instance.writeFile(path, content);
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

  /// What this save should put in the file: the whole collection as we hold
  /// it, or — when the file has moved since we loaded it — that file with only
  /// our own edits substituted into it.
  ///
  /// A viewer save is a whole-file rewrite, which is only correct while our
  /// copy is the newest one. The app itself breaks that: the home review
  /// runner patches this very file in place while the viewer holds it open
  /// (`GamesLibraryService.patchGameMovetexts`), and a reader can edit it
  /// elsewhere. Blind-writing then reverted every one of those changes.
  ///
  /// Null means "write nothing": the file changed into something this merge
  /// does not recognise, and keeping it as it is beats overwriting it with a
  /// copy that predates whatever happened.
  Future<String?> _contentToWrite({
    required String path,
    required List<String> gameTexts,
    required Set<int> edited,
    required String wholeFile,
  }) async {
    final loadedAt = loadedFileModified;
    if (loadedAt == null) return wholeFile;
    final stat = await StorageFactory.instance.fileStat(path);
    // No stat is not evidence of a change (the file may simply be new), and
    // an unchanged mtime means our copy is still the newest one.
    if (stat == null || stat.modified == loadedAt) return wholeFile;

    final disk = await StorageFactory.instance.readFile(path);
    if (disk == null || disk.trim().isEmpty) return wholeFile;

    final unplaced = <int>[];
    final merged = mergeEditedGamesIntoDiskCopy(
      diskContent: disk,
      gameTexts: gameTexts,
      edited: edited,
      unplaced: unplaced,
    );
    if (merged == null) {
      debugPrint(
        'Not saving: $path changed on disk into a shape this merge does not '
        'recognise. The file was left as it is.',
      );
      return null;
    }
    if (unplaced.isNotEmpty) {
      debugPrint(
        'Saved ${path.split('/').last} around ${unplaced.length} game(s) that '
        'moved on disk; their edits were left out rather than written over '
        'the wrong game.',
      );
    }
    return merged;
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
    game.pgnText = headerPart.isEmpty
        ? '$updatedPgnMovetext\n'
        : '$headerPart\n\n$updatedPgnMovetext\n';

    if (!writeToFile || filePath == null) return;
    unawaited(persistMetadata());
  }
}
