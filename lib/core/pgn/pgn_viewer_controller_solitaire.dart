// Part of pgn_viewer_controller.dart: solitaire ("guess the move") mode —
// starting/stopping sessions, reveal settings, guess handling, and guess-note
// injection. Same library as the controller, so private members resolve
// across the class/mixin boundary.
part of '../pgn_viewer_controller.dart';

/// Solitaire-mode operations for [PgnViewerController]. State shared with the
/// rest of the controller is declared abstract here and implemented by the
/// class; fields owned solely by this group live in this mixin.
mixin _SolitaireOps on ChangeNotifier {
  // Implemented by PgnViewerController.
  PgnViewerHandle get pgnWidgetController;
  List<PgnGameEntry> get filteredGames;
  String? get filePath;
  bool get boardFlipped;
  Position get currentPosition;
  void stopAutoPlay();

  // -- Solitaire mode --
  final SolitaireController solitaire = SolitaireController();

  bool get isSolitaireMode => solitaire.active;

  static const _revealDelayKey = 'solitaire_reveal_delay_sec';

  /// All-time trophy count (cached from service; earned in older sessions —
  /// solitaire no longer detects new ones, but the cabinet stays viewable).
  int totalTrophyCount = 0;

  // ---------------------------------------------------------------------------
  // SOLITAIRE MODE
  // ---------------------------------------------------------------------------

  void toggleSolitaire() {
    if (isSolitaireMode) {
      solitaire.stop();
      notifyListeners();
    } else {
      _startSolitaire();
    }
  }

  Future<void> loadSolitaireSettings() async {
    final prefs = await SharedPreferences.getInstance();
    solitaire.revealDelaySec = prefs.getInt(_revealDelayKey) ?? 60;
    final trophies = await SolitaireTrophyService.instance.loadAll();
    totalTrophyCount = trophies.length;
  }

  Future<void> setSolitaireRevealDelay(int seconds) async {
    solitaire.revealDelaySec = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_revealDelayKey, seconds);
    notifyListeners();
  }

  void _startSolitaire() {
    if (filteredGames.isEmpty) return;
    stopAutoPlay();
    pgnWidgetController.clearEphemeralMoves();
    pgnWidgetController.goToMainLineIndex(0);

    solitaire.onAdvancePosition = () {
      // Jump to the frontier rather than stepping forward: the user may have
      // navigated back into the revealed region when an advance fires.
      pgnWidgetController.goToMainLineIndex(solitaire.revealedPly);
      notifyListeners();
    };
    solitaire.onResetPosition = () {
      // no-op: board already shows the pre-move position since the move
      // wasn't applied to the widget
    };

    solitaire.start(
      mainLineLength: pgnWidgetController.mainLineLength,
      userPlaysWhite: !boardFlipped,
      whiteToMoveAtStart: currentPosition.turn == Side.white,
    );
    solitaire.removeListener(_onSolitaireChanged);
    solitaire.addListener(_onSolitaireChanged);
    notifyListeners();
  }

  void _restartSolitaireForCurrentOrientation() {
    pgnWidgetController.goToMainLineIndex(0);
    solitaire.onGameChanged(
      mainLineLength: pgnWidgetController.mainLineLength,
      userPlaysWhite: !boardFlipped,
      whiteToMoveAtStart: currentPosition.turn == Side.white,
    );
  }

  /// Append solitaire guess notes ("1st try", "Tried: …") to the guessed
  /// moves' comments via the PGN widget's serializer, so the game's own
  /// annotations and variations survive intact.
  void _injectGuessComments() {
    if (filteredGames.isEmpty || filePath == null) return;
    final notes = <int, String>{};
    for (final g in solitaire.guessLog) {
      notes[g.ply] = g.note;
    }
    pgnWidgetController.addGuessAnnotations(notes);
  }

  void revealCurrentMove() {
    if (!isSolitaireMode || !solitaire.waitingForUser) return;
    final mainIdx = solitaire.revealedPly;
    final moveHistory = pgnWidgetController.mainLineMoves;
    if (mainIdx >= moveHistory.length) return;
    solitaire.revealMove(moveHistory[mainIdx]);
  }

  /// Guards against re-injecting guess notes on every notify after the game
  /// completes (which would double-append and clobber later comment edits).
  bool _solitaireGuessesSaved = false;

  void _onSolitaireChanged() {
    if (solitaire.isComplete && !_solitaireGuessesSaved) {
      _solitaireGuessesSaved = true;
      _injectGuessComments();
    } else if (!solitaire.isComplete) {
      _solitaireGuessesSaved = false;
    }
    notifyListeners();
  }

  void _handleSolitaireMove(String san) {
    // Only a move played at the frontier counts as a guess. Anywhere else —
    // browsing the revealed region, inside a variation, or after completion —
    // it's exploratory analysis recorded as the user's own variation.
    if (solitaire.isComplete ||
        pgnWidgetController.inVariation ||
        pgnWidgetController.mainLineIndex != solitaire.revealedPly) {
      pgnWidgetController.addEphemeralMove(san);
      return;
    }

    final mainIdx = solitaire.revealedPly;
    final moveHistory = pgnWidgetController.mainLineMoves;
    if (mainIdx >= moveHistory.length) return;

    final expectedSan = moveHistory[mainIdx];
    final correct = solitaire.handleMove(san, currentPosition, expectedSan);
    if (!correct) {
      // Show the wrong attempt live as a variation at its ply.
      pgnWidgetController.recordVariationMove(san);
    }
  }
}
