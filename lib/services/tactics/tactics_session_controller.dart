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

  DateTime? _startTime;

  bool get hasActivePosition => currentPosition != null;

  /// True when the shown puzzle is behind the session head (reached via
  /// Previous) — it's already completed/skipped, so revealing edit tools
  /// can't spoil an unsolved puzzle.
  bool get isViewingPastPuzzle =>
      currentPosition != null && database.isViewingPastSessionPuzzle;

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
    return showCurrentPosition();
  }

  /// Start a session over exactly [subset] (e.g. "Retry mistakes" from the
  /// recap) and load the first position.
  TacticsPositionSetup? startRetrySession(List<TacticsPosition> subset) {
    database.startSessionWithPositions(subset);
    sessionOutcomes.clear();
    if (database.sessionQueueLength == 0) return null;
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

    sessionOutcomes.putIfAbsent(
        position.fen, () => SessionPuzzleOutcome.unattempted);
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

  TacticsPositionSetup? previousPosition() {
    if (database.sessionQueueLength == 0) return null;
    database.previousSessionPosition();
    return showCurrentPosition();
  }

  /// Advance to the next puzzle.  Returns `null` when the queue is exhausted
  /// — the session is over and the caller should show the recap.
  TacticsPositionSetup? skipPosition() {
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

  /// Browse: select a position without starting a scored session.
  TacticsPositionSetup? selectPosition(TacticsPosition position) {
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
