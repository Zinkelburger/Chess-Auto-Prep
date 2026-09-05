/// Session state, move validation, and training statistics for tactics puzzles.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';
import '../../../utils/fen_utils.dart';
import '../services/tactics_database.dart';
import '../services/tactics_engine.dart';
import '../../../utils/safe_change_notifier.dart';

/// Board updates the UI must apply after session logic runs.
class TacticsBoardUpdate {
  const TacticsBoardUpdate({this.applyMoveUci, this.setFen, this.san});

  final String? applyMoveUci;
  final String? setFen;

  /// SAN of the move, so the PGN viewer can stay in sync in real time.
  final String? san;
}

/// FEN and orientation for loading a tactic onto the main board.
class TacticsPositionSetup {
  const TacticsPositionSetup({required this.fen, required this.flipBoard});

  final String fen;
  final bool flipBoard;
}

/// Callbacks for async delays and board writes (widget provides [AppState]).
typedef TacticsSchedule = void Function(Duration delay, VoidCallback action);
typedef TacticsIsMounted = bool Function();

/// How a single puzzle went within a session (first outcome wins; puzzles
/// navigated past without an attempt — including after revealing the
/// solution — stay [unattempted]).
enum SessionPuzzleOutcome { correct, incorrect, unattempted }

/// How the currently loaded puzzle was launched.
///
/// This single flag is the source of truth for everything that differs
/// between the two ways of playing a tactic:
///  * [session]  — "Start Practice Session": a scored queue with a recap at
///    the end. Editing is locked at the unsolved head (it would reveal the
///    answer); anything already seen is fair game.
///  * [browse]   — the play button on a Browse row: unscored, Previous/Next
///    walk the browse list as it was filtered/sorted at click time, and
///    navigating past either end (or the back button) returns to the list.
enum TacticsPlaySource { none, session, browse }

/// What the tactics control panel does on the session's behalf.
///
/// The controller is a plain service — it cannot touch the board, the PGN
/// tab, the tab bar or the focus tree, and the widgets that can are its
/// *siblings* under the shared providers, so they cannot call each other
/// directly either. This is the one seam between the two.
///
/// It used to be seven separate mutable callbacks on the controller, each
/// assigned in the panel's `initState` and nulled again in `dispose` — a
/// fourteen-line ritual where forgetting one line leaves a disposed widget
/// reachable. Attaching and detaching one value cannot be half-done.
class TacticsPanelHooks {
  const TacticsPanelHooks({
    this.applyBoardUpdate,
    this.showPosition,
    this.playAnalysisMove,
    this.sessionCompleted,
    this.back,
    this.start,
    this.navigationKey,
  });

  /// Async board writes (opponent replies, wrong-answer reset).
  final void Function(TacticsBoardUpdate update)? applyBoardUpdate;

  /// Full position load (e.g. auto-advance to the next puzzle).
  final void Function(TacticsPositionSetup setup)? showPosition;

  /// Free-play moves (analysis mode, or after the puzzle is resolved).
  final void Function(String moveUci)? playAnalysisMove;

  /// Auto-advance ran past the last queued puzzle — the session is over.
  /// (Manual navigation reports completion through [
  /// TacticsSessionController.skipPosition] returning `null` instead.)
  final VoidCallback? sessionCompleted;

  /// The app-bar back arrow: leave the current puzzle — back to the browse
  /// list for browse-launched play, otherwise end the session.
  final VoidCallback? back;

  /// Start a practice session with the saved settings and put its first
  /// puzzle on the board. Two buttons ask for this: Play on the Tactics card
  /// and Study tactics in the left pane.
  final VoidCallback? start;

  /// A navigation key pressed while the move-input field owns focus (Space,
  /// the arrows, J) — routed to the panel's trainer shortcuts so those
  /// keys drive the puzzle instead of typing into the field. Returns true
  /// when the key was consumed. The move input and the panel are siblings in
  /// the focus tree, so key events cannot bubble between them.
  final bool Function(LogicalKeyboardKey key)? navigationKey;
}

class TacticsSessionController extends ChangeNotifier with SafeChangeNotifier {
  TacticsSessionController({
    TacticsDatabase? database,
    TacticsEngine? engine,
    this._panel,
  }) : database = database ?? TacticsDatabase(),
       engine = engine ?? TacticsEngine();

  final TacticsDatabase database;
  final TacticsEngine engine;

  TacticsPanelHooks? _panel;

  /// What the control panel can do for this session, or null while no panel
  /// is mounted (see [TacticsPanelHooks]). Sibling widgets — the app bar's
  /// back arrow, the left pane's Study-tactics button, the move input — ask
  /// the panel through here.
  TacticsPanelHooks? get panel => _panel;

  /// Called by the control panel when it mounts.
  void attachPanel(TacticsPanelHooks hooks) => _panel = hooks;

  /// Called by the control panel when it disposes. Takes the hooks it
  /// attached so a panel torn down *after* its replacement mounted (a
  /// reparent across the layout breakpoint) cannot detach the live one.
  void detachPanel(TacticsPanelHooks hooks) {
    if (identical(_panel, hooks)) _panel = null;
  }

  /// The saved practice-session filters (expiry, mistake types, order).
  ///
  /// Owned here rather than inside the panel's start card because two surfaces
  /// now need them: the card that edits them, and the left pane's button, which
  /// has to say how many puzzles they queue up before you press it.
  TacticsSessionSettings sessionSettings = const TacticsSessionSettings();

  /// Replace [sessionSettings] (and persist them). Never called during build —
  /// it notifies.
  void setSessionSettings(TacticsSessionSettings settings, {bool save = true}) {
    if (settings == sessionSettings) return;
    sessionSettings = settings;
    if (save) settings.saveSoon();
    notifyListeners();
  }

  TacticsPosition? currentPosition;
  bool positionSolved = false;
  bool attemptRecorded = false;
  String feedback = '';
  bool showSolution = false;
  bool autoAdvance = true;

  int currentMoveIndex = 0;
  String? currentTacticFen;
  bool waitingForOpponent = false;

  /// Per-puzzle outcomes for the current (or just-finished) session, keyed
  /// by FEN in the order the puzzles were shown.  Cleared when a new session
  /// starts — not by [endSession], so the recap can still read it.
  final Map<String, SessionPuzzleOutcome> sessionOutcomes = {};

  /// See [TacticsPlaySource] — how the loaded puzzle was launched.
  TacticsPlaySource playSource = TacticsPlaySource.none;

  /// Browse mode: the visible list (filter/sort applied) snapshotted when the
  /// user hit play, and where we are in it. Previous/Next walk this queue.
  List<TacticsPosition> _browseQueue = const [];
  int _browseIndex = 0;

  /// Furthest queue slot reached this session — anything before it has been
  /// seen already, so revisiting it via Previous unlocks editing.
  int _sessionFurthestSlot = 0;

  DateTime? _startTime;

  bool get hasActivePosition => currentPosition != null;

  /// True when the shown puzzle is behind the session head (reached via
  /// Previous) — it's already completed/skipped, so revealing edit tools
  /// can't spoil an unsolved puzzle.
  bool get isViewingPastPuzzle =>
      currentPosition != null && database.isViewingPastSessionPuzzle;

  ReviewSession get currentSession => database.currentSession;

  void setAutoAdvance(bool value) {
    if (autoAdvance == value) return;
    autoAdvance = value;
    notifyListeners();
  }

  void toggleSolution() {
    showSolution = !showSolution;
    notifyListeners();
  }

  /// Start a review session and load the first position per [settings].
  TacticsPositionSetup? startSession([
    TacticsSessionSettings settings = const TacticsSessionSettings(),
  ]) {
    database.startSession(settings);
    sessionOutcomes.clear();
    if (database.sessionQueueLength == 0) return null;
    playSource = TacticsPlaySource.session;
    _sessionFurthestSlot = 0;
    return showCurrentPosition();
  }

  /// Start a session over exactly [subset] (e.g. "Retry mistakes" from the
  /// recap) and load the first position.
  TacticsPositionSetup? startRetrySession(List<TacticsPosition> subset) {
    database.startSessionWithPositions(subset);
    sessionOutcomes.clear();
    if (database.sessionQueueLength == 0) return null;
    playSource = TacticsPlaySource.session;
    _sessionFurthestSlot = 0;
    return showCurrentPosition();
  }

  /// Puzzles from the last session that weren't solved outright (failed or
  /// navigated past), in the order they were shown.
  List<TacticsPosition> get sessionMistakes {
    final mistakes = <TacticsPosition>[];
    for (final entry in sessionOutcomes.entries) {
      if (entry.value == SessionPuzzleOutcome.correct) continue;
      final index = database.positions.indexWhere((p) => p.fen == entry.key);
      if (index != -1) mistakes.add(database.positions[index]);
    }
    return mistakes;
  }

  /// Count of session puzzles with the given [outcome].
  int outcomeCount(SessionPuzzleOutcome outcome) =>
      sessionOutcomes.values.where((o) => o == outcome).length;

  void _recordOutcome(SessionPuzzleOutcome outcome) {
    final fen = currentPosition?.fen;
    if (fen == null) return;
    // First outcome wins; a revisited puzzle keeps its original result.
    if (sessionOutcomes[fen] == SessionPuzzleOutcome.unattempted) {
      sessionOutcomes[fen] = outcome;
    }
  }

  /// Load the position at [database.sessionPositionIndex].
  ///
  /// Returns setup for the board, or `null` when the session has no positions.
  TacticsPositionSetup? showCurrentPosition() {
    if (database.sessionQueueLength == 0) {
      endSession();
      return null;
    }

    final position = database.positions[database.sessionPositionIndex];
    if (database.sessionQueuePosition > _sessionFurthestSlot) {
      _sessionFurthestSlot = database.sessionQueuePosition;
    }

    sessionOutcomes.putIfAbsent(
      position.fen,
      () => SessionPuzzleOutcome.unattempted,
    );
    return _loadPosition(position);
  }

  /// Reset all per-puzzle state and put [position] on the board.
  TacticsPositionSetup _loadPosition(TacticsPosition position) {
    currentPosition = position;
    positionSolved = false;
    attemptRecorded = false;
    _startTime = DateTime.now();
    feedback = '';
    showSolution = false;
    currentMoveIndex = 0;
    currentTacticFen = position.fen;
    waitingForOpponent = false;

    notifyListeners();

    return TacticsPositionSetup(
      fen: position.fen,
      flipBoard: !position.whiteToPlay,
    );
  }

  /// Whether Previous has anywhere to go — the button grays out otherwise
  /// (the first puzzle of a session or a browse walk has no "previous").
  bool get hasPrevious => switch (playSource) {
    TacticsPlaySource.browse => _browseIndex > 0,
    TacticsPlaySource.session => database.sessionQueuePosition > 0,
    TacticsPlaySource.none => false,
  };

  /// Whether Skip/Next has anywhere to go. In a session this is always true
  /// while a puzzle is loaded — at the last puzzle Next *finishes* the
  /// session (recap). A browse walk at its last item has nothing next; the
  /// back button is the way out.
  bool get hasNext => switch (playSource) {
    TacticsPlaySource.browse => _browseIndex < _browseQueue.length - 1,
    TacticsPlaySource.session => true,
    TacticsPlaySource.none => false,
  };

  /// True when a session sits on its final queued puzzle — Next will finish
  /// the session rather than load another position (UI relabels it "Finish").
  bool get isAtLastSessionPuzzle =>
      playSource == TacticsPlaySource.session &&
      database.sessionQueueLength > 0 &&
      database.sessionQueuePosition == database.sessionQueueLength - 1;

  /// Go back one puzzle. Session mode stops at the first position; browse
  /// mode returns `null` past the first item — the caller should return to
  /// the browse list.
  TacticsPositionSetup? previousPosition() {
    if (playSource == TacticsPlaySource.browse) {
      if (_browseIndex <= 0) return null;
      _browseIndex--;
      return _loadPosition(_browseQueue[_browseIndex]);
    }
    if (database.sessionQueueLength == 0) return null;
    database.previousSessionPosition();
    return showCurrentPosition();
  }

  /// Advance to the next puzzle.  Returns `null` when the queue is exhausted
  /// — the session is over (caller shows the recap) or the browse walk is
  /// done (caller returns to the browse list).
  TacticsPositionSetup? skipPosition() {
    if (playSource == TacticsPlaySource.browse) {
      if (_browseIndex >= _browseQueue.length - 1) return null;
      _browseIndex++;
      return _loadPosition(_browseQueue[_browseIndex]);
    }
    if (database.sessionQueueLength == 0) return null;
    if (database.nextSessionPosition() == null) return null;
    return showCurrentPosition();
  }

  /// Set the star [rating] on the current position.
  Future<void> setRating(int rating) async {
    if (currentPosition == null) return;
    await database.setRating(currentPosition!.fen, rating);
    refreshCurrentPosition();
  }

  /// Browse: play [position] without starting a scored session.
  ///
  /// [browseQueue] is the browse list as displayed (filter/sort applied);
  /// Previous/Next walk it from [position]'s slot. Defaults to just the one
  /// position.
  TacticsPositionSetup? selectPosition(
    TacticsPosition position, {
    List<TacticsPosition>? browseQueue,
  }) {
    playSource = TacticsPlaySource.browse;
    _browseQueue = browseQueue == null || browseQueue.isEmpty
        ? [position]
        : browseQueue;
    _browseIndex = _browseQueue
        .indexWhere((p) => p.fen == position.fen)
        .clamp(0, _browseQueue.length - 1);
    return _loadPosition(_browseQueue[_browseIndex]);
  }

  /// Whether editing the loaded tactic is allowed right now.
  ///
  /// Editing shows the answer, so the unsolved puzzle at the head of a
  /// session stays locked. Everything else is fair game: browse-launched
  /// puzzles, solved/revealed ones, and earlier puzzles revisited via
  /// Previous.
  bool get canEditCurrent {
    if (currentPosition == null) return false;
    if (playSource != TacticsPlaySource.session) return true;
    if (positionSolved || showSolution) return true;
    return database.sessionQueuePosition < _sessionFurthestSlot;
  }

  /// The tactic on the board was edited: reload the [updated] version in
  /// place without changing how it was launched (a session stays a session,
  /// a browse walk stays a browse walk).
  TacticsPositionSetup? reloadCurrentPosition(TacticsPosition updated) {
    if (currentPosition == null) return null;
    if (playSource == TacticsPlaySource.browse) {
      _browseQueue = List.of(_browseQueue)..[_browseIndex] = updated;
    }
    return _loadPosition(updated);
  }

  /// Reset puzzle state for the current tactic (analysis reset / retry).
  TacticsPositionSetup? resetPuzzleState() {
    if (currentPosition == null) return null;
    positionSolved = false;
    feedback = '';
    showSolution = false;
    _startTime = DateTime.now();
    currentMoveIndex = 0;
    currentTacticFen = currentPosition!.fen;
    waitingForOpponent = false;
    notifyListeners();
    return TacticsPositionSetup(
      fen: currentPosition!.fen,
      flipBoard: !currentPosition!.whiteToPlay,
    );
  }

  void endSession() {
    currentPosition = null;
    playSource = TacticsPlaySource.none;
    _browseQueue = const [];
    _browseIndex = 0;
    notifyListeners();
  }

  void refreshCurrentPosition() {
    if (currentPosition == null) return;
    final index = database.positions.indexWhere(
      (p) => p.fen == currentPosition!.fen,
    );
    if (index != -1) {
      currentPosition = database.positions[index];
      notifyListeners();
    }
  }

  /// Entry point for a move played on the tactics board or typed into the
  /// move input. Routes to [TacticsPanelHooks.playAnalysisMove] when not in an active puzzle
  /// attempt, otherwise validates the move against the solution line and
  /// pushes the result through [TacticsPanelHooks.applyBoardUpdate].
  void handleMoveAttempted({
    required String moveUci,
    required String boardFen,
    required bool inAnalysisMode,
    TacticsSchedule? schedule,
    TacticsIsMounted? isMounted,
  }) {
    if (currentPosition == null) return;

    if (inAnalysisMode || positionSolved || showSolution) {
      _panel?.playAnalysisMove?.call(moveUci);
      return;
    }

    final update = processMoveAttempt(
      moveUci: moveUci,
      boardFen: boardFen,
      schedule: schedule ?? (delay, action) => Future.delayed(delay, action),
      isMounted: isMounted ?? () => true,
    );
    if (update != null) _panel?.applyBoardUpdate?.call(update);
  }

  /// Returns `null` when the move should be ignored (wrong FEN, solved, etc.).
  TacticsBoardUpdate? processMoveAttempt({
    required String moveUci,
    required String boardFen,
    required TacticsSchedule schedule,
    required TacticsIsMounted isMounted,
  }) {
    if (currentPosition == null) return null;
    if (positionSolved || waitingForOpponent) return null;

    final fen = currentTacticFen ?? currentPosition!.fen;
    if (normalizeFen(boardFen) != normalizeFen(fen)) return null;

    final result = engine.checkMoveAtIndex(
      currentPosition!,
      moveUci,
      fen,
      currentMoveIndex,
    );
    final timeTaken = _startTime != null
        ? DateTime.now().difference(_startTime!).inMilliseconds / 1000.0
        : 0.0;

    if (result == TacticsResult.correct) {
      _handleCorrectMove(
        timeTaken,
        moveUci: moveUci,
        schedule: schedule,
        isMounted: isMounted,
      );
      return TacticsBoardUpdate(applyMoveUci: moveUci);
    }

    _handleIncorrectMove(
      timeTaken,
      moveUci: moveUci,
      schedule: schedule,
      isMounted: isMounted,
    );
    return TacticsBoardUpdate(applyMoveUci: moveUci);
  }

  void _handleCorrectMove(
    double timeTaken, {
    String? moveUci,
    required TacticsSchedule schedule,
    required TacticsIsMounted isMounted,
  }) {
    // Advance currentTacticFen to include the user's just-played move so the
    // opponent callback (and the next FEN-validation check) see the right state.
    if (moveUci != null) {
      try {
        final pos = Chess.fromSetup(
          Setup.parseFen(currentTacticFen ?? currentPosition!.fen),
        );
        final move = Move.parse(moveUci);
        if (move != null) {
          currentTacticFen = pos.play(move).fen;
        }
      } catch (e) {
        debugPrint('[TacticsSession] FEN advance after user move failed: $e');
      }
    }

    currentMoveIndex++;

    final totalUserMoves = engine.userMoveCount(currentPosition!);
    final completedUserMoves = (currentMoveIndex + 1) ~/ 2;

    if (currentMoveIndex < currentPosition!.correctLine.length &&
        currentMoveIndex % 2 == 1) {
      waitingForOpponent = true;
      feedback = totalUserMoves > 1
          ? 'Correct! ($completedUserMoves/$totalUserMoves)'
          : 'Correct!';
      notifyListeners();

      // Long enough to register the move as correct before the reply lands;
      // at 500ms the two moves read as one blur.
      schedule(const Duration(milliseconds: 1000), () {
        if (!isMounted() || currentPosition == null) return;

        final opponentToken = currentPosition!.correctLine[currentMoveIndex];
        try {
          final pos = Chess.fromSetup(
            Setup.parseFen(currentTacticFen ?? currentPosition!.fen),
          );
          final opponentMove = pos.parseSan(opponentToken);
          if (opponentMove != null) {
            final (newPos, canonicalSan) = pos.makeSan(opponentMove);
            currentTacticFen = newPos.fen;
            _panel?.applyBoardUpdate?.call(
              TacticsBoardUpdate(setFen: newPos.fen, san: canonicalSan),
            );
          }
        } catch (e) {
          debugPrint('[TacticsSession] Opponent move failed: $e');
        }

        currentMoveIndex++;

        if (currentMoveIndex >= currentPosition!.correctLine.length) {
          _completeTactic(timeTaken, schedule: schedule, isMounted: isMounted);
          notifyListeners();
          return;
        }

        // The "Correct (1/2)" stays up until the next attempt — clearing it
        // here left the panel blank for the rest of the user's think.
        waitingForOpponent = false;
        notifyListeners();
      });
    } else {
      _completeTactic(timeTaken, schedule: schedule, isMounted: isMounted);
    }
  }

  void _completeTactic(
    double timeTaken, {
    required TacticsSchedule schedule,
    required TacticsIsMounted isMounted,
  }) {
    positionSolved = true;
    waitingForOpponent = false;
    feedback = 'Correct!';
    notifyListeners();

    if (!attemptRecorded) {
      attemptRecorded = true;
      _recordOutcome(SessionPuzzleOutcome.correct);
      unawaited(
        database
            .recordAttempt(currentPosition!, TacticsResult.correct, timeTaken)
            .then((_) {
              if (isMounted()) refreshCurrentPosition();
            })
            .catchError((Object error) {
              if (!isMounted()) return;
              feedback = 'Result is unsaved: $error';
              notifyListeners();
            }),
      );
    }

    if (autoAdvance) {
      // The full solution is on screen from this point; give it time to be
      // read before the next puzzle replaces it.
      schedule(const Duration(milliseconds: 3000), () {
        if (!isMounted() || !positionSolved) return;
        final setup = skipPosition();
        if (setup != null) {
          _panel?.showPosition?.call(setup);
        } else {
          _panel?.sessionCompleted?.call();
        }
      });
    }
  }

  void _handleIncorrectMove(
    double timeTaken, {
    String? moveUci,
    required TacticsSchedule schedule,
    required TacticsIsMounted isMounted,
  }) {
    feedback = 'Incorrect';
    notifyListeners();

    if (!attemptRecorded && currentPosition != null) {
      attemptRecorded = true;
      _recordOutcome(SessionPuzzleOutcome.incorrect);
      unawaited(
        database
            .recordAttempt(currentPosition!, TacticsResult.incorrect, timeTaken)
            .then((_) {
              if (isMounted()) refreshCurrentPosition();
            })
            .catchError((Object error) {
              if (!isMounted()) return;
              feedback = 'Result is unsaved: $error';
              notifyListeners();
            }),
      );
    }

    // Dwell on the wrong position long enough to actually see what was
    // played and why it fails — at 600ms the piece read as teleporting there
    // and back with a subliminal red flash.
    schedule(const Duration(milliseconds: 1200), () {
      if (!isMounted() || currentPosition == null) return;
      final resetFen = fenAfterIncorrect();
      if (resetFen != null) {
        _panel?.applyBoardUpdate?.call(TacticsBoardUpdate(setFen: resetFen));
      }
      // Keep "Incorrect" up after the board resets; the next attempt
      // replaces it.
      notifyListeners();
    });
  }

  /// FEN to restore after a wrong answer (may differ from initial on multi-move).
  String? fenAfterIncorrect() => currentTacticFen ?? currentPosition?.fen;
}
