/// Solitaire ("guess the move") mode for the PGN viewer, extracted from
/// `PgnViewerController`.
///
/// Sits between [SolitaireController] — which owns the guessing rules, timers
/// and score, and knows nothing about a viewer — and the [PgnViewerHandle]
/// that drives the board and movetext. Everything here is that translation:
/// the setup step before a session, starting one against the current game,
/// routing a board move to either a guess or an exploratory variation, and
/// writing the finished guess log back into the game.
///
/// `PgnViewerController` keeps its public solitaire API and delegates here, so
/// call-sites in the screens are unchanged.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/solitaire_trophy_service.dart';
import 'pgn_viewer_handle.dart';
import 'solitaire_controller.dart';

/// The choices offered before a session starts. Mutable while the setup strip
/// is open; read once by [ViewerSolitaireSession.begin].
class SolitaireSetup {
  /// Which side's moves to guess. Defaults to the side at the bottom of the
  /// board.
  bool userIsWhite;

  /// Begin at the move on screen instead of the start of the game — the
  /// moves before it stay visible.
  bool fromCurrentMove;

  /// Also drill the saved sidelines, in movetext order.
  bool includeVariations;

  /// Mainline ply the cursor was on when setup opened.
  final int currentMainlinePly;

  /// Whether "from this move" is on offer: the cursor is on the mainline,
  /// somewhere between the first and last move.
  final bool canStartHere;

  /// Whether the game has saved sidelines to drill.
  final bool hasSidelines;

  /// Where a "from here" session would pick the game up — "after 13.Nf3" —
  /// for the setup strip's label. Empty when unknown.
  ///
  /// Naming the move already on the board beats naming the move number:
  /// "move 13…" reads as a truncated string in a button, and the trailing
  /// ellipsis that means "Black to play" is notation, not prose.
  final String startHereLabel;

  /// How many moves the current choices would ask you to guess. Recomputed
  /// on every change, so the strip can say how big the drill is before you
  /// commit to it — and refuse to start one with nothing in it.
  int userMovesToGuess = 0;

  SolitaireSetup({
    required this.userIsWhite,
    required this.fromCurrentMove,
    required this.includeVariations,
    required this.currentMainlinePly,
    required this.canStartHere,
    required this.hasSidelines,
    this.startHereLabel = '',
  });

  /// The mainline ply a session with these choices would start from.
  int get startPly => fromCurrentMove && canStartHere ? currentMainlinePly : 0;

  /// "after 13.Nf3" / "after 13…Nf6" — the last mainline move played before
  /// [ply], given the game's mainline SANs. Empty at the start of the game.
  static String labelForPly(List<String> mainlineSans, int ply) {
    if (ply <= 0 || ply > mainlineSans.length) return '';
    final san = mainlineSans[ply - 1];
    final number = (ply - 1) ~/ 2 + 1;
    final whitePlayed = (ply - 1).isEven;
    return whitePlayed ? 'after $number.$san' : 'after $number…$san';
  }
}

class ViewerSolitaireSession {
  ViewerSolitaireSession({
    required this.handle,
    required this.hasGames,
    required this.userPlaysWhite,
    required this.stopAutoPlay,
    required this.onChanged,
  }) {
    controller.addListener(_onControllerChanged);
    controller.onStepPending = _showBefore;
    controller.onStepShown = _showAfter;
  }

  /// Board + movetext the session drives. Held directly rather than through a
  /// supplier because the controller never reassigns it.
  final PgnViewerHandle handle;

  /// Whether a game is loaded to guess through. Read through a supplier
  /// because the controller replaces its game list on every load and slice.
  final bool Function() hasGames;

  /// The side at the bottom of the board — the default side to guess for.
  final bool Function() userPlaysWhite;

  /// Auto-play and solitaire cannot both drive the board.
  final VoidCallback stopAutoPlay;

  /// Notify listeners (the controller's `notifyListeners`).
  final VoidCallback onChanged;

  /// Guessing rules, timers and score. Public so the viewer can read live
  /// session state (`feedback`, `canReveal`, `guessLog`) without this class
  /// re-exporting all of it.
  final SolitaireController controller = SolitaireController();

  static const _revealDelayKey = 'solitaire_reveal_delay_sec';
  static const _includeVariationsKey = 'solitaire_include_variations';

  bool get isActive => controller.active;

  /// The pending setup while the setup strip is open; null otherwise.
  SolitaireSetup? setup;
  bool get isConfiguring => setup != null;

  /// Remembered across games within the app: whether sidelines are drilled.
  bool _includeVariations = false;

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

  /// The toolbar button: opens setup, or leaves whatever state is open.
  void toggle() {
    if (isActive) {
      stop();
    } else if (isConfiguring) {
      cancelSetup();
    } else {
      beginSetup();
    }
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    controller.revealDelaySec = prefs.getInt(_revealDelayKey) ?? 60;
    _includeVariations = prefs.getBool(_includeVariationsKey) ?? false;
    final trophies = await SolitaireTrophyService.instance.loadAll();
    totalTrophyCount = trophies.length;
  }

  Future<void> setRevealDelay(int seconds) async {
    controller.revealDelaySec = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_revealDelayKey, seconds);
    onChanged();
  }

  // ── Setup ──

  void beginSetup() {
    if (!hasGames() || handle.mainLineLength == 0) return;
    final ply = handle.mainLineIndex;
    setup = SolitaireSetup(
      userIsWhite: userPlaysWhite(),
      fromCurrentMove: false,
      includeVariations: _includeVariations && handle.hasSavedSidelines,
      currentMainlinePly: ply,
      canStartHere:
          !handle.inVariation && ply > 0 && ply < handle.mainLineLength,
      hasSidelines: handle.hasSavedSidelines,
      startHereLabel: SolitaireSetup.labelForPly(handle.mainLineMoves, ply),
    );
    _recountSetup();
    onChanged();
  }

  /// Re-ask the script builder how many moves the pending choices would put
  /// in front of the user. Cheap enough to run on every toggle, and it is the
  /// only honest way to show the size of a variations drill up front.
  void _recountSetup() {
    final s = setup;
    if (s == null) return;
    final script = handle.buildSolitaireScript(
      fromMainlinePly: s.startPly,
      includeVariations: s.includeVariations,
    );
    s.userMovesToGuess = script == null
        ? 0
        : script.userMoveCount(s.userIsWhite);
  }

  void updateSetup({
    bool? userIsWhite,
    bool? fromCurrentMove,
    bool? includeVariations,
  }) {
    final s = setup;
    if (s == null) return;
    if (userIsWhite != null) s.userIsWhite = userIsWhite;
    if (fromCurrentMove != null) s.fromCurrentMove = fromCurrentMove;
    if (includeVariations != null) s.includeVariations = includeVariations;
    _recountSetup();
    onChanged();
  }

  void cancelSetup() {
    setup = null;
    onChanged();
  }

  /// Start the session the setup strip describes. Refused — with the strip
  /// left open — when the choices add up to no moves to guess.
  void begin() {
    final s = setup;
    if (s == null || s.userMovesToGuess == 0) return;
    setup = null;
    _includeVariations = s.includeVariations;
    unawaited(
      SharedPreferences.getInstance().then(
        (p) => p.setBool(_includeVariationsKey, s.includeVariations),
      ),
    );
    _start(
      userIsWhite: s.userIsWhite,
      fromMainlinePly: s.startPly,
      includeVariations: s.includeVariations,
    );
  }

  void _start({
    required bool userIsWhite,
    required int fromMainlinePly,
    required bool includeVariations,
  }) {
    if (!hasGames()) return;
    final script = handle.buildSolitaireScript(
      fromMainlinePly: fromMainlinePly,
      includeVariations: includeVariations,
    );
    // Nothing to guess (an empty game, or a side with no moves left from
    // here) would otherwise auto-play the whole script at 400 ms a move and
    // land on "Complete" without ever asking a question. Leave instead.
    if (script == null ||
        script.isEmpty ||
        script.userMoveCount(userIsWhite) == 0) {
      if (isActive) controller.stop();
      onChanged();
      return;
    }
    stopAutoPlay();
    handle.clearEphemeralMoves();
    // Rewind before the frontier is set, so the jump is not clamped against
    // a previous session's reveal state.
    handle.setSolitaireReveal(null);
    handle.goToMainLineIndex(fromMainlinePly);
    controller.start(script: script, userPlaysWhite: userIsWhite);
    onChanged();
  }

  /// A new game has loaded under a running session: start over on it, with
  /// the side taken from the board again (a per-game perspective may have
  /// flipped it) and the same sidelines choice.
  void restartForNewGame() {
    if (!isActive) return;
    _start(
      userIsWhite: userPlaysWhite(),
      fromMainlinePly: 0,
      includeVariations: _includeVariations,
    );
  }

  void stop() {
    if (isActive) controller.stop();
    onChanged();
  }

  void revealCurrentMove() {
    if (!isActive || !controller.waitingForUser) return;
    controller.revealMove();
  }

  void hintCurrentMove() {
    if (!isActive) return;
    controller.hintMove();
  }

  /// Route a board move: a guess when the board sits on the position the
  /// current step is asked from, exploratory analysis anywhere else.
  ///
  /// Browsing the revealed region, sitting inside a sideline the drill is not
  /// on, or playing on after completion is all recorded as the user's own
  /// variation, never judged.
  void handleBoardMove(String san) {
    final step = controller.currentStep;
    if (controller.isComplete ||
        !controller.waitingForUser ||
        step == null ||
        !_boardIsAt(step)) {
      handle.addEphemeralMove(san);
      return;
    }

    final correct = controller.handleMove(san);
    if (!correct) {
      // Show the wrong attempt live as an alternative at its position.
      handle.recordVariationMove(san);
    }
  }

  bool _boardIsAt(SolitaireStep step) {
    final ply = step.mainlinePly;
    if (ply != null) return !handle.inVariation && handle.mainLineIndex == ply;
    final parentId = step.parentNodeId;
    if (parentId == null) {
      return !handle.inVariation && handle.mainLineIndex == step.branchPly;
    }
    return handle.currentVariationNodeId == parentId;
  }

  // ── Board glue ──

  void _showBefore(SolitaireStep step) {
    final ply = step.mainlinePly;
    if (ply != null) {
      handle.goToMainLineIndex(ply);
      return;
    }
    final parent = step.parentNode;
    if (parent == null) {
      handle.goToMainLineIndex(step.branchPly);
    } else {
      handle.goToVariationNode(parent, step.branchPly);
    }
  }

  void _showAfter(SolitaireStep step) {
    final ply = step.mainlinePly;
    if (ply != null) {
      handle.goToMainLineIndex(ply + 1);
    } else {
      handle.goToVariationNode(step.node!, step.branchPly);
    }
  }

  void _onControllerChanged() {
    // Pushed before any navigation the controller triggers next, so a jump
    // to the new frontier is not clamped against the old one.
    handle.setSolitaireReveal(controller.active ? controller.reveal : null);
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
    if (!hasGames()) return;
    final mainNotes = <int, String>{};
    final mainWrong = <int, List<String>>{};
    final nodeNotes = <int, String>{};
    final nodeWrong = <int, List<String>>{};
    for (final g in controller.guessLog) {
      final step = g.step;
      final ply = step.mainlinePly;
      if (ply != null) {
        mainNotes[ply] = g.note;
        if (g.wrongAttempts.isNotEmpty) mainWrong[ply] = g.wrongAttempts;
        continue;
      }
      nodeNotes[step.node!.id] = g.note;
      final parentId = step.parentNodeId;
      if (g.wrongAttempts.isNotEmpty && parentId != null) {
        nodeWrong[parentId] = g.wrongAttempts;
      }
    }
    if (mainWrong.isNotEmpty) handle.addGuessVariations(mainWrong);
    if (nodeWrong.isNotEmpty) handle.addGuessNodeVariations(nodeWrong);
    if (mainNotes.isNotEmpty) handle.addGuessAnnotations(mainNotes);
    if (nodeNotes.isNotEmpty) handle.addGuessNodeAnnotations(nodeNotes);
  }

  void dispose() {
    controller.removeListener(_onControllerChanged);
    controller.dispose();
  }
}
