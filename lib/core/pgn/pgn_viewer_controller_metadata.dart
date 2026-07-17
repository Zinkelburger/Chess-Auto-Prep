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
  List<PgnGameEntry> get allGames;
  List<PgnGameEntry> get filteredGames;
  int get currentGameIndex;
  PgnFenIndex get _fenIndex;

  Timer? persistDebounce;

  void setRating(int stars) {
    if (filteredGames.isEmpty) return;
    final game = filteredGames[currentGameIndex];
    game.studyRating = stars;
    notifyListeners();
    persistMetadata();
    onReclaimFocus?.call();
  }

  Future<void> persistMetadata() async {
    persistDebounce?.cancel();
    persistDebounce = Timer(const Duration(milliseconds: 300), () {
      doPersistMetadata();
    });
  }

  Future<void> doPersistMetadata() async {
    if (filePath == null) return;
    final gameData = allGames
        .map(
          (g) =>
              (pgn: g.pgnText, rating: g.studyRating, summary: g.studySummary),
        )
        .toList();

    final result = await compute(buildMetadataOutput, gameData);

    if (!isActive()) return;
    for (int i = 0; i < result.length && i < allGames.length; i++) {
      allGames[i].pgnText = result[i];
    }
    try {
      await StorageFactory.instance.writeFile(
        filePath!,
        '${result.join('\n\n')}\n',
      );
      _fenIndex.persist(filePath: filePath, gameTotal: allGames.length);
    } catch (e) {
      debugPrint('Failed to persist metadata: $e');
    }
  }

  void persistMoveComments(String updatedPgnMovetext) {
    if (filteredGames.isEmpty || filePath == null) return;
    persistMoveCommentsFor(filteredGames[currentGameIndex], updatedPgnMovetext);
  }

  /// Like [persistMoveComments] but bound to a specific [game] object, so
  /// debounced edits that flush after the user has switched games still patch
  /// the game they were typed on.
  void persistMoveCommentsFor(PgnGameEntry game, String updatedPgnMovetext) {
    if (filePath == null) return;

    final headerEnd = RegExp(r'\]\s*\n').allMatches(game.pgnText).last;
    final headerPart = game.pgnText.substring(0, headerEnd.end);
    game.pgnText = '$headerPart\n$updatedPgnMovetext\n';

    persistMetadata();
  }
}
