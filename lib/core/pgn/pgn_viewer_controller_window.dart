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
  void rememberPersistedGame(PgnGameEntry game);
  void _markCollectionChanged();

  bool isFullScreen = false;

  void orientBoardForCurrentGame() {
    if (filteredGames.isEmpty) return;
    final game = filteredGames[currentGameIndex];
    final flipped = switch (perspective.mode) {
      PerspectiveMode.white => false,
      PerspectiveMode.black => true,
      PerspectiveMode.player => _playerSitsAtBlack(
        game,
        perspective.playerName,
      ),
    };
    if (flipped != null) boardFlipped = flipped;
    notifyListeners();
  }

  /// Whether [playerName] is this game's Black player: true/false when the
  /// name is found on one side, null when it is on neither (or both), which
  /// leaves the current orientation alone.
  static bool? _playerSitsAtBlack(PgnGameEntry game, String playerName) {
    String normalized(String? s) => (s ?? '').toLowerCase().trim();
    final white = normalized(game.headers['White']);
    final black = normalized(game.headers['Black']);
    final target = normalized(playerName);
    // Exact match first so same-surname matchups still orient correctly.
    if (black == target) return true;
    if (white == target) return false;
    // Collections mix name spellings ("Gashimov,V" / "Gashimov, Vugar"),
    // so fall back to surname comparison, like detectFileProtagonist.
    String surname(String s) => s.split(',').first.trim();
    final t = surname(target);
    final blackMatch = t.isNotEmpty && surname(black) == t;
    final whiteMatch = t.isNotEmpty && surname(white) == t;
    if (blackMatch && !whiteMatch) return true;
    if (whiteMatch && !blackMatch) return false;
    return null;
  }

  void setPerspective(Perspective p) {
    perspective = p;
    notifyListeners();
    unawaited(persistPerspective());
    orientBoardForCurrentGame();
    onReclaimFocus?.call();
  }

  Future<void> persistPerspective() async {
    if (allGames.isEmpty) return;
    final first = allGames.first;
    rememberPersistedGame(first);
    final value = perspective.toHeaderValue();
    final oldHeader = first.headers['StudyPerspective'];
    first.headers['StudyPerspective'] = value;

    final pgn = upsertPgnHeader(first.pgnText, 'StudyPerspective', value);
    final changed = oldHeader != value || first.pgnText != pgn;
    first.pgnText = pgn;
    if (changed) {
      _markCollectionChanged();
      notifyListeners();
    }

    await persistMetadata();
  }

  /// Flipping only turns the board: a running solitaire session keeps the
  /// side it was started for.
  void toggleBoardFlipped() {
    boardFlipped = !boardFlipped;
    notifyListeners();
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
