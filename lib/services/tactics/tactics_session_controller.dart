/// Session state, move validation, and training statistics for tactics puzzles.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../models/tactics_position.dart';
import '../../models/tactics_session_settings.dart';
import '../../utils/fen_utils.dart';
import '../tactics_database.dart';
import '../tactics_engine.dart';

/// Board updates the UI must apply after session logic runs.
class TacticsBoardUpdate {
  const TacticsBoardUpdate({
    this.applyMoveUci,
    this.setFen,
    this.san,
  });

  final String? applyMoveUci;
  final String? setFen;

  /// SAN of the move, so the PGN viewer can stay in sync in real time.
  final String? san;
}

/// FEN and orientation for loading a tactic onto the main board.
class TacticsPositionSetup {
  const TacticsPositionSetup({
    required this.fen,
    required this.flipBoard,
  });

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

class TacticsSessionController extends ChangeNotifier {
  TacticsSessionController({
    TacticsDatabase? database,
    TacticsEngine? engine,
    this.onBoardUpdate,
  })  : database = database ?? TacticsDatabase(),
        engine = engine ?? TacticsEngine();

  final TacticsDatabase database;
  final TacticsEngine engine;

  /// Async board writes (opponent replies, wrong-answer reset).
  void Function(TacticsBoardUpdate update)? onBoardUpdate;

  /// Full position load (e.g. auto-advance to next puzzle).
  void Function(TacticsPositionSetup setup)? onPositionSetup;

  /// Free-play moves (analysis mode, or after the puzzle is resolved).
  void Function(String moveUci)? onAnalysisMove;

  /// A user move was accepted and advanced the solution line.
  VoidCallback? onUserMoveAccepted;

  /// Auto-advance ran past the last queued puzzle — the session is over.
  /// (Manual navigation reports completion through [skipPosition] returning
  /// `null` instead.)
  VoidCallback? onSessionCompleted;

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

  ReviewSession get currentSession => database.currentSession;

  /// PGN viewer move number / side, parsed from [positionContext].
  ({int? moveNumber, bool? isWhiteToPlay}) parsePositionContext(
    String positionContext,
  ) {
    final match = RegExp(r'Move (\d+)').firstMatch(positionContext);
    if (match == null) return (moveNumber: null, isWhiteToPlay: null);
    return (
      moveNumber: int.tryParse(match.group(1)!),
      isWhiteToPlay: positionContext.contains('White'),
    );
  }

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
        position.fen, () => SessionPuzzleOutcome.unattempted);
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

    final isWhiteToMove = position.positionContext.contains('White');
    return TacticsPositionSetup(
      fen: position.fen,
      flipBoard: !isWhiteToMove,
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
    _browseIndex =
        _browseQueue.indexWhere((p) => p.fen == position.fen).clamp(0, _browseQueue.length - 1);
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
      flipBoard: !currentPosition!.positionContext.contains('White'),
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
    final index =
        database.positions.indexWhere((p) => p.fen == currentPosition!.fen);
    if (index != -1) {
      currentPosition = database.positions[index];
      notifyListeners();
    }
  }

  /// Entry point for a move played on the tactics board or typed into the
  /// move input. Routes to [onAnalysisMove] when not in an active puzzle
  /// attempt, otherwise validates the move against the solution line and
  /// pushes the result through [onBoardUpdate] / [onUserMoveAccepted].
  void handleMoveAttempted({
    required String moveUci,
    required String boardFen,
    required bool inAnalysisMode,
    TacticsSchedule? schedule,
    TacticsIsMounted? isMounted,
  }) {
    if (currentPosition == null) return;

    if (inAnalysisMode || positionSolved || showSolution) {
      onAnalysisMove?.call(moveUci);
      return;
    }

    final prevIndex = currentMoveIndex;
    final update = processMoveAttempt(
      moveUci: moveUci,
      boardFen: boardFen,
      schedule: schedule ?? (delay, action) => Future.delayed(delay, action),
      isMounted: isMounted ?? () => true,
    );
    if (update != null) {
      onBoardUpdate?.call(update);
      if (currentMoveIndex > prevIndex) {
        onUserMoveAccepted?.call();
      }
    }
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

      schedule(const Duration(milliseconds: 500), () {
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
            onBoardUpdate?.call(
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

        waitingForOpponent = false;
        feedback = '';
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
      database
          .recordAttempt(currentPosition!, TacticsResult.correct, timeTaken)
          .then((_) {
        if (isMounted()) refreshCurrentPosition();
      });
    }

    if (autoAdvance) {
      schedule(const Duration(milliseconds: 1500), () {
        if (!isMounted() || !positionSolved) return;
        final setup = skipPosition();
        if (setup != null) {
          onPositionSetup?.call(setup);
        } else {
          onSessionCompleted?.call();
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
      database
          .recordAttempt(
        currentPosition!,
        TacticsResult.incorrect,
        timeTaken,
      )
          .then((_) {
        if (isMounted()) refreshCurrentPosition();
      });
    }

    schedule(const Duration(milliseconds: 600), () {
      if (!isMounted() || currentPosition == null) return;
      final resetFen = fenAfterIncorrect();
      if (resetFen != null) {
        onBoardUpdate?.call(TacticsBoardUpdate(setFen: resetFen));
      }
      feedback = '';
      notifyListeners();
    });
  }

  /// FEN to restore after a wrong answer (may differ from initial on multi-move).
  String? fenAfterIncorrect() => currentTacticFen ?? currentPosition?.fen;
}
