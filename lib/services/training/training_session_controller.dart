import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../core/repertoire_controller.dart';
import '../../models/repertoire_line.dart';
import '../../models/repertoire_metadata.dart';
import '../../models/repertoire_move_progress.dart';
import '../../models/repertoire_review_entry.dart'
    show RepertoireReviewEntry, ReviewRating;
import '../../models/repertoire_review_history_entry.dart';
import '../../models/training_settings.dart';
import '../../widgets/chess_board_widget.dart';
import '../repertoire_review_service.dart';
import '../repertoire_service.dart';
import 'training_phase.dart';

/// Manages repertoire training session state: phases, line queue, move validation,
/// progress persistence, and session statistics.
class TrainingSessionController extends ChangeNotifier {
  final RepertoireService repertoireService;
  final RepertoireReviewService reviewService;

  TrainingSessionController({
    RepertoireService? repertoireService,
    RepertoireReviewService? reviewService,
  })  : repertoireService = repertoireService ?? RepertoireService(),
        reviewService = reviewService ?? RepertoireReviewService() {
    session.addListener(_onSessionChanged);
  }

  final RepertoireController session = RepertoireController();

  // -- Data --
  RepertoireMetadata? repertoire;
  List<RepertoireLine> lines = [];
  List<RepertoireReviewEntry> _otherRepertoireEntries = [];
  Map<String, RepertoireReviewEntry> reviewMap = {};
  Map<String, RepertoireMoveProgress> moveProgressMap = {};
  TrainingSettings settings = TrainingSettings();

  // -- Training state --
  List<RepertoireLine> dueQueue = [];
  RepertoireLine? currentLine;
  int currentLineLength = 0;
  int currentMoveIndex = 0;
  TrainingPhase phase = TrainingPhase.drilling;
  bool lineHadMistake = false;
  List<int> wrongMoveIndices = [];
  int replayIndex = 0;

  // -- Session statistics --
  int sessionCorrect = 0;
  int sessionIncorrect = 0;
  int sessionStreak = 0;
  int sessionBestStreak = 0;

  bool learnWaitingForAck = false;
  bool learnQuizzing = false;
  Timer? _learnTimer;

  /// Called whenever a new line session begins (including auto-next).
  VoidCallback? onLineStarted;

  bool isLoading = true;
  String? error;
  bool waitingForUser = false;
  String? feedback;
  String? currentAnnotation;

  bool get isWhiteLine => currentLine?.color.toLowerCase() != 'black';
  bool get boardFlipped => !isWhiteLine;
  String get repertoireId => repertoire?.filePath ?? '';
  int get effectiveLineLength => currentLineLength;

  void _onSessionChanged() => notifyListeners();

  @override
  void dispose() {
    _learnTimer?.cancel();
    session.removeListener(_onSessionChanged);
    session.dispose();
    super.dispose();
  }

  Future<void> loadSettings() async {
    settings = await TrainingSettings.load();
    notifyListeners();
  }

  void setRepertoire(RepertoireMetadata? value) {
    repertoire = value;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // REPERTOIRE LOADING
  // ---------------------------------------------------------------------------

  Future<void> loadRepertoire({String? startLineId}) async {
    if (repertoire == null) return;
    isLoading = true;
    error = null;
    feedback = null;
    notifyListeners();

    try {
      final filePath = repertoire!.filePath;
      final parsedLines = await repertoireService.parseRepertoireFile(filePath);
      if (parsedLines.isEmpty) {
        error = 'No trainable lines found.';
        isLoading = false;
        notifyListeners();
        return;
      }

      final allEntries = await reviewService.loadAll();
      final moveProgress = await reviewService.loadMoveProgress();
      _otherRepertoireEntries =
          allEntries.where((e) => e.repertoireId != filePath).toList();
      final currentEntries =
          allEntries.where((e) => e.repertoireId == filePath).toList();
      final merged = reviewService.syncEntries(
        repertoireId: filePath,
        lines: parsedLines,
        existing: currentEntries,
      );
      await reviewService.saveAll([..._otherRepertoireEntries, ...merged]);

      lines = parsedLines;
      reviewMap = {for (final e in merged) e.lineId: e};
      moveProgressMap = reviewService.indexMoveProgress(
        moveProgress.where((mp) => mp.repertoireId == filePath).toList(),
      );
      dueQueue = reviewService.orderLinesForReview(
        lines,
        reviewMap,
        settings.reviewOrder,
      );
      notifyListeners();

      pickStartingLine(startLineId: startLineId);
    } catch (e) {
      error = 'Error loading repertoire: $e';
      notifyListeners();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void clearSelectionError() {
    error = 'Select a repertoire to start training.';
    isLoading = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // LINE MANAGEMENT
  // ---------------------------------------------------------------------------

  void pickStartingLine({String? startLineId}) {
    if (lines.isEmpty) return;
    RepertoireLine? initial;
    if (startLineId != null) {
      initial = lines.firstWhere((l) => l.id == startLineId,
          orElse: () => lines.first);
    } else if (dueQueue.isNotEmpty) {
      initial = dueQueue.first;
    } else {
      initial = lines.first;
    }
    startLine(initial);
  }

  bool _isLineNew(RepertoireLine line) {
    final entry = reviewMap[line.id];
    return entry == null || entry.isNew;
  }

  void startLine(RepertoireLine? line) {
    if (line == null) return;
    _learnTimer?.cancel();

    if (line.startPosition.fen != Chess.initial.fen) {
      session.setPositionFromFen(line.startPosition.fen);
    } else {
      session.clearMoveHistory();
    }

    final effectiveLength = settings.trainingDepth != null
        ? settings.trainingDepth!.clamp(1, line.moves.length)
        : line.moves.length;

    final isNew = _isLineNew(line);

    currentLine = line;
    currentLineLength = effectiveLength;
    currentMoveIndex = 0;
    feedback = null;
    currentAnnotation = null;
    phase = isNew ? TrainingPhase.learning : TrainingPhase.drilling;
    lineHadMistake = false;
    wrongMoveIndices = [];
    replayIndex = 0;
    waitingForUser = false;
    learnWaitingForAck = false;
    learnQuizzing = false;
    notifyListeners();
    onLineStarted?.call();

    Future.microtask(() {
      if (phase == TrainingPhase.learning) {
        advanceLearnPhase();
      } else {
        advanceDrillPhase();
      }
    });
  }

  void nextLine() => rebuildQueueAndAdvance();

  // ---------------------------------------------------------------------------
  // LEARN PHASE
  // ---------------------------------------------------------------------------

  Future<void> advanceLearnPhase() async {
    if (currentLine == null) return;
    if (currentMoveIndex >= currentLineLength) {
      session.clearMoveHistory();
      if (currentLine!.startPosition.fen != Chess.initial.fen) {
        session.setPositionFromFen(currentLine!.startPosition.fen);
      } else {
        session.clearMoveHistory();
      }
      currentMoveIndex = 0;
      phase = TrainingPhase.drilling;
      feedback = null;
      currentAnnotation = null;
      waitingForUser = false;
      notifyListeners();
      Future.microtask(advanceDrillPhase);
      return;
    }

    final san = currentLine!.moves[currentMoveIndex];
    final move = session.position.parseSan(san);
    if (move == null) {
      error = 'Invalid move in line: $san';
      notifyListeners();
      return;
    }
    session.playMove(san);

    final annotation = currentLine!.comments[currentMoveIndex.toString()];

    currentAnnotation = annotation;
    feedback = null;
    waitingForUser = false;
    notifyListeners();

    final isUserMove = _isUserMove(currentMoveIndex);

    if (!isUserMove) {
      await Future.delayed(const Duration(milliseconds: 600));
      currentMoveIndex++;
      await advanceLearnPhase();
    } else if (settings.learnRequiresClick) {
      learnWaitingForAck = true;
      notifyListeners();
    } else if (annotation != null && annotation.isNotEmpty) {
      _learnTimer = Timer(
        Duration(seconds: settings.learnDelaySec),
        learnAcknowledged,
      );
    } else {
      await Future.delayed(const Duration(milliseconds: 800));
      currentMoveIndex++;
      await advanceLearnPhase();
    }
  }

  void learnAcknowledged() {
    _learnTimer?.cancel();
    session.goBack();
    learnWaitingForAck = false;
    learnQuizzing = true;
    waitingForUser = true;
    feedback = 'Your move';
    currentAnnotation = null;
    notifyListeners();
  }

  Future<void> handleLearnQuizMove(CompletedMove move) async {
    if (currentLine == null) return;
    final expectedSan = currentLine!.moves[currentMoveIndex];
    final isCorrect = isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      session.playMove(expectedSan);
      learnQuizzing = false;
      waitingForUser = false;
      feedback = 'Correct!';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 300));
      currentMoveIndex++;
      await advanceLearnPhase();
    } else {
      feedback = 'Wrong — the move is $expectedSan';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 1200));
      session.playMove(expectedSan);
      await Future.delayed(const Duration(milliseconds: 800));
      session.goBack();
      feedback = 'Try again';
      waitingForUser = true;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // DRILL PHASE
  // ---------------------------------------------------------------------------

  bool _isUserMove(int moveIndex) {
    if (currentLine == null) return false;
    final startIsWhite = currentLine!.startPosition.turn == Side.white;
    final isWhiteMove =
        startIsWhite ? (moveIndex % 2 == 0) : (moveIndex % 2 == 1);
    return (isWhiteLine && isWhiteMove) || (!isWhiteLine && !isWhiteMove);
  }

  Future<void> advanceDrillPhase() async {
    if (currentLine == null) return;
    final limit = effectiveLineLength;

    while (currentMoveIndex < limit) {
      if (_isUserMove(currentMoveIndex)) {
        _prepareDrillMove(currentMoveIndex);
        return;
      } else {
        await _playOpponentMove(currentMoveIndex);
        currentMoveIndex++;
      }
    }
    _onLineComplete();
  }

  Future<void> _playOpponentMove(int moveIndex) async {
    if (currentLine == null) return;
    final san = currentLine!.moves[moveIndex];
    final move = session.position.parseSan(san);
    if (move == null) {
      error = 'Could not play opponent move $san';
      notifyListeners();
      return;
    }
    session.playMove(san);
    await Future.delayed(const Duration(milliseconds: 400));
  }

  void _prepareDrillMove(int moveIndex) {
    final annotation = currentLine!.comments[moveIndex.toString()];
    waitingForUser = true;
    currentAnnotation = annotation;
    feedback = 'Your move';
    notifyListeners();
  }

  Future<void> handleUserMove(CompletedMove move) async {
    if (!waitingForUser || currentLine == null) return;

    if (phase == TrainingPhase.learning && learnQuizzing) {
      await handleLearnQuizMove(move);
      return;
    }

    if (phase == TrainingPhase.replaying) {
      await handleReplayMove(move);
      return;
    }

    final expectedSan = currentLine!.moves[currentMoveIndex];
    final isCorrect = isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      updateMoveProgress(currentLine!, currentMoveIndex, wasCorrect: true);
      session.playMove(expectedSan);
      waitingForUser = false;
      feedback = 'Correct!';
      currentAnnotation = null;
      notifyListeners();
      currentMoveIndex++;
      await Future.delayed(const Duration(milliseconds: 300));
      await advanceDrillPhase();
    } else {
      updateMoveProgress(currentLine!, currentMoveIndex, wasCorrect: false);
      lineHadMistake = true;
      wrongMoveIndices.add(currentMoveIndex);

      feedback = 'Wrong — the move was $expectedSan';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 1200));

      session.playMove(expectedSan);
      waitingForUser = false;
      currentAnnotation = null;
      notifyListeners();
      currentMoveIndex++;
      await Future.delayed(const Duration(milliseconds: 400));
      await advanceDrillPhase();
    }
  }

  void _onLineComplete() {
    if (lineHadMistake &&
        settings.wrongMoveReplay &&
        wrongMoveIndices.isNotEmpty) {
      startReplayPhase();
    } else {
      phase = TrainingPhase.finished;
      waitingForUser = false;
      feedback = 'Line complete — rate your recall.';
      currentAnnotation = null;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // REPLAY PHASE
  // ---------------------------------------------------------------------------

  void startReplayPhase() {
    wrongMoveIndices = wrongMoveIndices.toSet().toList()..sort();
    replayIndex = 0;
    phase = TrainingPhase.replaying;
    feedback = 'Replay missed moves (${wrongMoveIndices.length} remaining)';
    currentAnnotation = null;
    notifyListeners();
    setupReplayPosition();
  }

  void setupReplayPosition() {
    if (currentLine == null) return;
    if (replayIndex >= wrongMoveIndices.length) {
      phase = TrainingPhase.finished;
      waitingForUser = false;
      feedback = 'Line complete — rate your recall.';
      currentAnnotation = null;
      notifyListeners();
      return;
    }

    final targetMoveIndex = wrongMoveIndices[replayIndex];

    if (currentLine!.startPosition.fen != Chess.initial.fen) {
      session.setPositionFromFen(currentLine!.startPosition.fen);
    } else {
      session.clearMoveHistory();
    }
    for (int i = 0; i < targetMoveIndex; i++) {
      session.playMove(currentLine!.moves[i]);
    }

    waitingForUser = true;
    feedback = 'Replay — ${wrongMoveIndices.length - replayIndex} left';
    currentAnnotation = null;
    notifyListeners();
  }

  Future<void> handleReplayMove(CompletedMove move) async {
    final targetMoveIndex = wrongMoveIndices[replayIndex];
    final expectedSan = currentLine!.moves[targetMoveIndex];
    final isCorrect = isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      updateMoveProgress(currentLine!, targetMoveIndex, wasCorrect: true);
      session.playMove(expectedSan);
      feedback = 'Correct!';
      waitingForUser = false;
      notifyListeners();
      replayIndex++;
      await Future.delayed(const Duration(milliseconds: 500));
      setupReplayPosition();
    } else {
      updateMoveProgress(currentLine!, targetMoveIndex, wasCorrect: false);
      feedback = 'Try again — the move is $expectedSan';
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // MOVE VALIDATION
  // ---------------------------------------------------------------------------

  bool isCorrectUserMove(CompletedMove move, String expectedSan) {
    final expectedMove = session.position.parseSan(expectedSan);
    if (expectedMove == null) return false;

    try {
      final expectedPos = session.position.play(expectedMove);
      final userMove = Move.parse(move.uci);
      if (userMove == null) return false;
      final userPos = session.position.play(userMove);
      if (userPos.fen == expectedPos.fen) return true;
    } catch (_) {
      // invalid FEN — fall through to SAN comparison
    }

    String normalizeSan(String san) =>
        san.replaceAll(RegExp(r'[+#?!]'), '').trim().toLowerCase();
    return normalizeSan(move.san) == normalizeSan(expectedSan);
  }

  // ---------------------------------------------------------------------------
  // RATING & PROGRESS
  // ---------------------------------------------------------------------------

  Future<void> rateLine(ReviewRating rating) async {
    if (currentLine == null) return;

    final existing = reviewMap[currentLine!.id] ??
        RepertoireReviewEntry(
          repertoireId: repertoireId,
          lineId: currentLine!.id,
          lineName: currentLine!.name,
        );

    final hadMistake = lineHadMistake;
    final updated = reviewService.applyRating(existing, rating).copyWith(
          passCount: hadMistake ? existing.passCount : existing.passCount + 1,
          failCount: hadMistake ? existing.failCount + 1 : existing.failCount,
        );
    reviewMap[currentLine!.id] = updated;

    await reviewService
        .saveAll([..._otherRepertoireEntries, ...reviewMap.values]);
    await reviewService.saveMoveProgress(
      moveProgressMap.values.toList(),
      repertoireId: repertoireId,
    );
    await reviewService.appendHistory([
      RepertoireReviewHistoryEntry(
        repertoireId: repertoireId,
        lineId: currentLine!.id,
        timestampUtc: DateTime.now().toUtc(),
        rating: rating.name,
        hadMistake: hadMistake,
        sessionType: 'trainer',
      )
    ]);

    repertoireService.updateLineReviewHeaders(
      repertoireId,
      currentLine!.id,
      lastReview: updated.lastReviewedUtc,
      difficulty: updated.difficulty,
      intervalDays: updated.intervalDays,
      dueDate: updated.dueDateUtc,
      passCount: updated.passCount,
      failCount: updated.failCount,
    );

    if (hadMistake) {
      sessionIncorrect++;
      sessionStreak = 0;
    } else {
      sessionCorrect++;
      sessionStreak++;
      if (sessionStreak > sessionBestStreak) {
        sessionBestStreak = sessionStreak;
      }
    }
    notifyListeners();

    if (settings.autoNext) {
      rebuildQueueAndAdvance();
    } else {
      dueQueue = reviewService.orderLinesForReview(
        lines,
        reviewMap,
        settings.reviewOrder,
      );
      notifyListeners();
    }
  }

  void rebuildQueueAndAdvance() {
    dueQueue = reviewService.orderLinesForReview(
      lines,
      reviewMap,
      settings.reviewOrder,
    );

    if (dueQueue.isEmpty) {
      phase = TrainingPhase.finished;
      feedback = 'All caught up!';
      notifyListeners();
      return;
    }

    int nextIndex = 0;
    if (currentLine != null) {
      final currentQueueIndex =
          dueQueue.indexWhere((l) => l.id == currentLine!.id);
      if (currentQueueIndex >= 0) {
        nextIndex = (currentQueueIndex + 1) % dueQueue.length;
      }
    }
    startLine(dueQueue[nextIndex]);
  }

  void updateDueQueue(List<RepertoireLine> queue) {
    dueQueue = queue;
    notifyListeners();
  }

  void updateMoveProgress(RepertoireLine line, int moveIndex,
      {required bool wasCorrect}) {
    final key = '${line.id}:$moveIndex';
    final existing = moveProgressMap[key];
    final threshold = settings.correctStreakThreshold;

    if (wasCorrect) {
      final newStreak = (existing?.correctStreak ?? 0) + 1;
      final learned = newStreak >= threshold;
      moveProgressMap[key] = RepertoireMoveProgress(
        repertoireId: repertoireId,
        lineId: line.id,
        moveIndex: moveIndex,
        correctStreak: learned ? threshold : newStreak,
        learned: learned,
      );
    } else {
      moveProgressMap[key] = RepertoireMoveProgress(
        repertoireId: repertoireId,
        lineId: line.id,
        moveIndex: moveIndex,
        correctStreak: 0,
        learned: false,
      );
    }
  }

  double moveDifficulty(RepertoireLine line, int moveIndex) {
    final key = '${line.id}:$moveIndex';
    final prog = moveProgressMap[key];
    if (prog == null) return 0;
    return prog.correctStreak / settings.correctStreakThreshold;
  }
}
