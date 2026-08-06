/// Solitaire ("guess the move") mode for the PGN viewer, extracted from
/// `PgnViewerController`.
///
/// Sits between [SolitaireController] — which owns the guessing rules, timers
/// and score, and knows nothing about a viewer — and the [PgnViewerHandle]
/// that drives the board and movetext. Everything here is that translation:
/// starting a session against the current game, routing a board move to either
/// a guess or an exploratory variation, and writing the finished guess log back
/// into the game.
///
/// `PgnViewerController` keeps its public solitaire API and delegates here, so
/// call-sites in the screens are unchanged.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/solitaire_trophy_service.dart';
import 'pgn_viewer_handle.dart';
import 'solitaire_controller.dart';

class ViewerSolitaireSession {
  ViewerSolitaireSession({
    required this.handle,
    required this.hasGames,
    required this.hasFilePath,
    required this.userPlaysWhite,
    required this.currentPosition,
    required this.stopAutoPlay,
    required this.onChanged,
  });

  /// Board + movetext the session drives. Held directly rather than through a
  /// supplier because the controller never reassigns it.
  final PgnViewerHandle handle;

  /// Whether a game is loaded to guess through. Read through a supplier
  /// because the controller replaces its game list on every load and slice.
  final bool Function() hasGames;

  /// Whether the collection came from a file — guess notes are only written
  /// back when there is something to write them to.
  final bool Function() hasFilePath;

  /// Which side the user is guessing for (the controller derives this from
  /// board orientation, which the user can flip mid-session).
  final bool Function() userPlaysWhite;

  /// Board position the next guess will be judged against.
  final Position Function() currentPosition;

  /// Auto-play and solitaire cannot both drive the board.
  final VoidCallback stopAutoPlay;

  /// Notify listeners (the controller's `notifyListeners`).
  final VoidCallback onChanged;

  /// Guessing rules, timers and score. Public so the viewer can read live
  /// session state (`feedback`, `canReveal`, `guessLog`) without this class
  /// re-exporting all of it.
  final SolitaireController controller = SolitaireController();

  static const _revealDelayKey = 'solitaire_reveal_delay_sec';

  bool get isActive => controller.active;

  /// All-time trophy count, cached from the service so the app-bar counter
  /// doesn't hit storage on every rebuild. New trophies are detected after
  /// full-game analysis (see `detectSolitaireTrophies`) and folded in through
  /// [noteTrophiesEarned].
  int totalTrophyCount = 0;

  /// Guards against re-injecting guess notes on every notify after the game
  /// completes (which would double-append and clobber later comment edits).
  bool _guessesSaved = false;

  /// Fold newly awarded trophies into the cached count.
  void noteTrophiesEarned(int count) {
    if (count <= 0) return;
    totalTrophyCount += count;
    onChanged();
  }

  void toggle() {
    if (isActive) {
      controller.stop();
      onChanged();
    } else {
      _start();
    }
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    controller.revealDelaySec = prefs.getInt(_revealDelayKey) ?? 60;
    final trophies = await SolitaireTrophyService.instance.loadAll();
    totalTrophyCount = trophies.length;
  }

  Future<void> setRevealDelay(int seconds) async {
    controller.revealDelaySec = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_revealDelayKey, seconds);
    onChanged();
  }

  void _start() {
    if (!hasGames()) return;
    stopAutoPlay();
    handle.clearEphemeralMoves();
    handle.goToMainLineIndex(0);

    controller.onAdvancePosition = () {
      // Jump to the frontier rather than stepping forward: the user may have
      // navigated back into the revealed region when an advance fires.
      handle.goToMainLineIndex(controller.revealedPly);
      onChanged();
    };
    controller.onResetPosition = () {
      // no-op: board already shows the pre-move position since the move
      // wasn't applied to the widget
    };

    controller.start(
      mainLineLength: handle.mainLineLength,
      userPlaysWhite: userPlaysWhite(),
      whiteToMoveAtStart: currentPosition().turn == Side.white,
    );
    controller.removeListener(_onControllerChanged);
    controller.addListener(_onControllerChanged);
    onChanged();
  }

  /// Re-seat the session after the board is flipped or a new game loads: the
  /// side being guessed for is derived from orientation, so both change it.
  void restartForCurrentOrientation() {
    handle.goToMainLineIndex(0);
    controller.onGameChanged(
      mainLineLength: handle.mainLineLength,
      userPlaysWhite: userPlaysWhite(),
      whiteToMoveAtStart: currentPosition().turn == Side.white,
    );
  }

  void stop() => controller.stop();

  void revealCurrentMove() {
    if (!isActive || !controller.waitingForUser) return;
    final mainIdx = controller.revealedPly;
    final moveHistory = handle.mainLineMoves;
    if (mainIdx >= moveHistory.length) return;
    controller.revealMove(moveHistory[mainIdx]);
  }

  /// Route a board move: a guess at the frontier, exploratory analysis
  /// anywhere else.
  ///
  /// Only a move played at the frontier counts as a guess. Anywhere else —
  /// browsing the revealed region, inside a variation, or after completion —
  /// it's exploratory analysis recorded as the user's own variation.
  void handleBoardMove(String san) {
    if (controller.isComplete ||
        handle.inVariation ||
        handle.mainLineIndex != controller.revealedPly) {
      handle.addEphemeralMove(san);
      return;
    }

    final mainIdx = controller.revealedPly;
    final moveHistory = handle.mainLineMoves;
    if (mainIdx >= moveHistory.length) return;

    final expectedSan = moveHistory[mainIdx];
    final correct = controller.handleMove(san, currentPosition(), expectedSan);
    if (!correct) {
      // Show the wrong attempt live as a variation at its ply.
      handle.recordVariationMove(san);
    }
  }

  void _onControllerChanged() {
    if (controller.isComplete && !_guessesSaved) {
      _guessesSaved = true;
      _injectGuessComments();
    } else if (!controller.isComplete) {
      _guessesSaved = false;
    }
    onChanged();
  }

  /// On completion, save the solitaire results into the game: each guessed
  /// move's wrong attempts become real sideline variations (so the exported
  /// game shows what the solver tried), and a short note ("1st try",
  /// "Tried: …") rides on the move's comment. Both persist through the PGN
  /// widget's serializer, so the game's own annotations survive intact.
  void _injectGuessComments() {
    if (!hasGames() || !hasFilePath()) return;
    final notes = <int, String>{};
    final wrongByPly = <int, List<String>>{};
    for (final g in controller.guessLog) {
      notes[g.ply] = g.note;
      if (g.wrongAttempts.isNotEmpty) {
        wrongByPly[g.ply] = g.wrongAttempts;
      }
    }
    handle.addGuessVariations(wrongByPly);
    handle.addGuessAnnotations(notes);
  }

  void dispose() {
    controller.removeListener(_onControllerChanged);
    controller.dispose();
  }
}
