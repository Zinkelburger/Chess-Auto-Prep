// Part of pgn_viewer_controller.dart: window/fullscreen handling plus board
// perspective and orientation. Same library as the controller, so private
// members resolve across the class/mixin boundary.
part of '../pgn_viewer_controller.dart';

/// Window/fullscreen and perspective/orientation operations for
/// [PgnViewerController]. State shared with the rest of the controller is
/// declared abstract here and implemented by the class; fields owned solely
/// by this group live in this mixin.
mixin _WindowOps on ChangeNotifier {
  // Implemented by PgnViewerController.
  bool Function() get isActive;
  VoidCallback? get onReclaimFocus;
  List<PgnGameEntry> get allGames;
  List<PgnGameEntry> get filteredGames;
  int get currentGameIndex;
  abstract Perspective perspective;
  abstract bool boardFlipped;
  Future<void> persistMetadata();

  // Perspective and flip changes re-seat an active solitaire session, since
  // the side being guessed for is derived from board orientation.
  bool get isSolitaireMode;
  void restartSolitaireForCurrentOrientation();

  bool isFullScreen = false;

  void orientBoardForCurrentGame() {
    if (filteredGames.isEmpty) return;
    final game = filteredGames[currentGameIndex];
    final w = (game.headers['White'] ?? '').toLowerCase().trim();
    final b = (game.headers['Black'] ?? '').toLowerCase().trim();

    switch (perspective.mode) {
      case PerspectiveMode.white:
        boardFlipped = false;
      case PerspectiveMode.black:
        boardFlipped = true;
      case PerspectiveMode.player:
        final target = perspective.playerName.toLowerCase().trim();
        // Exact match first so same-surname matchups still orient correctly.
        if (b == target) {
          boardFlipped = true;
        } else if (w == target) {
          boardFlipped = false;
        } else {
          // Collections mix name spellings ("Gashimov,V" / "Gashimov, Vugar"),
          // so fall back to surname comparison, like detectFileProtagonist.
          String surname(String s) => s.split(',').first.trim();
          final t = surname(target);
          final bMatch = t.isNotEmpty && surname(b) == t;
          final wMatch = t.isNotEmpty && surname(w) == t;
          if (bMatch && !wMatch) {
            boardFlipped = true;
          } else if (wMatch && !bMatch) {
            boardFlipped = false;
          }
        }
    }
    notifyListeners();
  }

  void setPerspective(Perspective p) {
    perspective = p;
    notifyListeners();
    unawaited(persistPerspective());
    orientBoardForCurrentGame();
    if (isSolitaireMode) restartSolitaireForCurrentOrientation();
    onReclaimFocus?.call();
  }

  Future<void> persistPerspective() async {
    if (allGames.isEmpty) return;
    final first = allGames.first;
    final value = perspective.toHeaderValue();
    first.headers['StudyPerspective'] = value;

    var pgn = first.pgnText;
    if (pgn.contains(RegExp(r'\[StudyPerspective\s+"[^"]*"\]'))) {
      pgn = pgn.replaceFirst(
        RegExp(r'\[StudyPerspective\s+"[^"]*"\]'),
        '[StudyPerspective "$value"]',
      );
    } else {
      final firstNewline = pgn.indexOf('\n');
      if (firstNewline != -1) {
        pgn =
            '${pgn.substring(0, firstNewline)}\n[StudyPerspective "$value"]${pgn.substring(firstNewline)}';
      }
    }
    first.pgnText = pgn;

    await persistMetadata();
  }

  void toggleBoardFlipped() {
    boardFlipped = !boardFlipped;
    notifyListeners();
    if (isSolitaireMode) restartSolitaireForCurrentOrientation();
  }

  Future<void> toggleFullScreen() async {
    final entering = !isFullScreen;
    await windowManager.setFullScreen(entering);
    if (!isActive()) return;
    isFullScreen = entering;
    notifyListeners();
    onReclaimFocus?.call();
  }

  Future<void> exitFullScreen() async {
    if (!isFullScreen) return;
    await windowManager.setFullScreen(false);
    if (!isActive()) return;
    isFullScreen = false;
    notifyListeners();
    onReclaimFocus?.call();
  }

  void onWindowLeaveFullScreen() {
    if (isActive() && isFullScreen) {
      isFullScreen = false;
      notifyListeners();
    }
  }

  void onWindowEnterFullScreen() {
    if (isActive() && !isFullScreen) {
      isFullScreen = true;
      notifyListeners();
    }
  }
}
