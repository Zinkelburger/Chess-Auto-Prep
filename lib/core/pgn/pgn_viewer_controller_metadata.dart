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
  set errorMessage(String? value);
  Map<PgnGameEntry, String> _persistedGames = Map.identity();
  Future<void> _metadataWrites = Future.value();

  void adoptPersistedGames(List<PgnGameEntry> games) {
    _persistedGames = Map.identity();
    for (final game in games) {
      _persistedGames[game] = game.pgnText;
    }
  }

  void rememberPersistedGame(PgnGameEntry game) =>
      _persistedGames.putIfAbsent(game, () => game.pgnText);

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

  /// Forget every screen-only substitution — the collection they described
  /// is going away.
  void clearScreenOnlyMovetext() => _screenOnlyMovetext.clear();

  void setRating(int stars) {
    if (filteredGames.isEmpty) return;
    final game = filteredGames[currentGameIndex];
    rememberPersistedGame(game);
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
    final originals = _persistedGames;
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

    final output = {
      for (final g in games) g: _screenOnlyMovetext[g] ?? g.pgnText,
    };
    final task = _metadataWrites.then((_) async {
      final edits = <String, String>{
        for (final g in games)
          if (originals[g] != null && originals[g]!.trim() != output[g]!.trim())
            originals[g]!: output[g]!,
      };
      if (edits.isEmpty) return;
      try {
        await StorageFactory.instance.updateFile(path, (current) {
          if (current == null) throw StateError('The source file is missing.');
          return patchPgnDocument(current, edits);
        });
      } catch (e) {
        // Preserve the edited snapshot even if the user has already navigated
        // away. This is a recovery document, never a replacement of the source.
        final recovery =
            'recovery/pgn-${DateTime.now().microsecondsSinceEpoch}.pgn';
        try {
          await StorageFactory.instance.writeFile(
            recovery,
            '${output.values.join('\n\n')}\n',
            createOnly: true,
          );
          errorMessage =
              'Changes could not be merged with $path. A recovery copy was saved to $recovery. $e';
        } catch (recoveryError) {
          errorMessage =
              'Changes to $path are unsaved: $e. Recovery save also failed: $recoveryError';
        }
        if (filePath == path && identical(allGames, games)) {
          _dirtyGames.addAll(dirty);
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
      errorMessage = null;
      loadedFileModified = (await StorageFactory.instance.fileStat(
        path,
      ))?.modified;
      _fenIndex.markStale();
    });
    _metadataWrites = task.catchError((Object e) {
      errorMessage = 'Could not save: $e';
      notifyListeners();
    });
    await _metadataWrites;
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
    await _metadataWrites;
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
    rememberPersistedGame(game);
    if (writeToFile) {
      _screenOnlyMovetext.remove(game);
    } else {
      _screenOnlyMovetext.putIfAbsent(game, () => game.pgnText);
    }

    final headerEnd = _headerBlockEndRe.allMatches(game.pgnText).last;
    final headerPart = game.pgnText.substring(0, headerEnd.end);
    game.pgnText = '$headerPart\n$updatedPgnMovetext\n';

    if (!writeToFile || filePath == null) return;
    unawaited(persistMetadata());
  }
}

final RegExp _headerBlockEndRe = RegExp(r'\]\s*\n');
