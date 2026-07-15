import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/repertoire_controller.dart';
import '../../models/build_tree_node.dart' show BuildTreeNode;
import '../../models/repertoire_line.dart';
import '../../models/repertoire_metadata.dart';
import '../../models/repertoire_move_progress.dart';
import '../../models/repertoire_review_entry.dart'
    show RepertoireReviewEntry, ReviewRating;
import '../../models/repertoire_review_history_entry.dart';
import '../../models/completed_move.dart';
import '../../models/training_settings.dart';
import '../../utils/pgn_comment_utils.dart' show filterDisplayComment;
import '../../utils/safe_change_notifier.dart';
import '../generation/tree_my_ease.dart' show computeLinePlayability;
import '../generation/tree_serialization.dart' show deserializeTree;
import '../line_metrics_helpers.dart' show walkTreeForLine;
import '../repertoire_review_service.dart';
import '../repertoire_service.dart';
import '../storage/storage_factory.dart';
import 'training_phase.dart';

/// Manages repertoire training session state: phases, line queue, move validation,
/// progress persistence, and session statistics.
class TrainingSessionController extends ChangeNotifier with SafeChangeNotifier {
  final RepertoireService repertoireService;
  final RepertoireReviewService reviewService;

  TrainingSessionController({
    RepertoireService? repertoireService,
    RepertoireReviewService? reviewService,
  }) : repertoireService = repertoireService ?? RepertoireService(),
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

  /// Per-line playability scores from the generated tree (0 = hardest, 1 = easiest).
  /// Empty when no tree.json exists for the repertoire.
  Map<String, double> playabilityMap = {};

  /// Per-line bottleneck info: (ply, quality, isOurMove).
  Map<String, ({int ply, double quality, bool isOurMove})> bottleneckMap = {};

  /// True when no tree.json was found for the current repertoire.
  bool get needsScoring => _treeRoot == null && lines.isNotEmpty;

  BuildTreeNode? _treeRoot;
  bool? _treeIsWhite;

  // -- Training state --
  List<RepertoireLine> dueQueue = [];
  RepertoireLine? currentLine;
  int currentLineLength = 0;
  int currentMoveIndex = 0;
  TrainingPhase phase = TrainingPhase.drilling;
  bool lineHadMistake = false;

  /// True when this line session started with the learn walkthrough (new line).
  bool? _hadLearnPhaseThisSession;
  bool get hadLearnPhaseThisSession => _hadLearnPhaseThisSession ?? false;
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

  /// True when opponent move has a comment and we're waiting for Next click.
  bool opponentWaitingForAck = false;

  /// Move index where active training begins. Moves before it are auto-played
  /// as an intro when [TrainingSettings.skipToFirstComment] is on.
  int trainingStartIndex = 0;

  /// True while the pre-comment intro moves are auto-playing on the board.
  bool playingIntro = false;

  /// Bumped on every line start (and dispose) so in-flight async pacing
  /// (intro playback, move-feedback delays) aborts instead of clobbering the
  /// new line's state.
  int _lineGeneration = 0;

  /// Called whenever a new line session begins (including auto-next).
  VoidCallback? onLineStarted;

  bool isLoading = true;
  String? error;

  /// Transition to idle (no repertoire loaded, not loading).
  void setIdle() {
    isLoading = false;
    error = null;
    notifyListeners();
  }

  bool waitingForUser = false;
  String? feedback;
  String? currentAnnotation;

  /// The opponent move in the current move-pair (persists while showing
  /// the user's move prompt and after user answers, until the pair is cleared).
  MoveDisplayInfo? currentPairOpponent;

  /// The user's move in the current pair (set after user plays correctly).
  MoveDisplayInfo? currentPairUser;

  bool get isWhiteLine => currentLine?.color.toLowerCase() != 'black';
  bool get boardFlipped => !isWhiteLine;
  String get repertoireId => repertoire?.filePath ?? '';
  int get effectiveLineLength => currentLineLength;

  void _onSessionChanged() => notifyListeners();

  @override
  void dispose() {
    _lineGeneration++;
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
      _otherRepertoireEntries = allEntries
          .where((e) => e.repertoireId != filePath)
          .toList();
      final currentEntries = allEntries
          .where((e) => e.repertoireId == filePath)
          .toList();
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

      await _loadTreeAndComputePlayability(filePath, parsedLines);

      dueQueue = reviewService.orderLinesForReview(
        lines,
        reviewMap,
        settings.reviewOrder,
        playabilityMap: playabilityMap,
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

  Future<void> _loadTreeAndComputePlayability(
    String filePath,
    List<RepertoireLine> parsedLines,
  ) async {
    _treeRoot = null;
    _treeIsWhite = null;
    playabilityMap = {};
    bottleneckMap = {};

    final base = p.withoutExtension(filePath);
    final treePath = '${base}_tree.json';
    final storage = StorageFactory.instance;

    try {
      if (!await storage.fileExists(treePath)) return;
      final json = await storage.readFile(treePath);
      if (json == null || json.isEmpty) return;

      final tree = deserializeTree(json);
      _treeRoot = tree.root;

      final config = tree.configSnapshot;
      _treeIsWhite = config['play_as_white'] as bool? ?? true;

      for (final line in parsedLines) {
        final linePath = walkTreeForLine(_treeRoot!, line.moves);
        if (linePath.length < 2) continue;

        final lp = computeLinePlayability(linePath, _treeIsWhite!);
        playabilityMap[line.id] = lp.playability;
        bottleneckMap[line.id] = (
          ply: lp.bottleneckPly,
          quality: lp.bottleneckQuality,
          isOurMove: lp.bottleneckIsOurMove,
        );
      }
    } catch (e) {
      debugPrint('[TrainingController] Failed to load tree: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // LINE MANAGEMENT
  // ---------------------------------------------------------------------------

  void pickStartingLine({String? startLineId}) {
    if (lines.isEmpty) return;
    RepertoireLine? initial;
    if (startLineId != null) {
      initial = lines.firstWhere(
        (l) => l.id == startLineId,
        orElse: () => lines.first,
      );
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
    _hadLearnPhaseThisSession = isNew;
    lineHadMistake = false;
    wrongMoveIndices = [];
    replayIndex = 0;
    waitingForUser = false;
    learnWaitingForAck = false;
    learnQuizzing = false;
    opponentWaitingForAck = false;
    currentPairOpponent = null;
    currentPairUser = null;
    _lineGeneration++;
    playingIntro = false;
    trainingStartIndex = settings.skipToFirstComment ? _firstCommentIndex() : 0;
    notifyListeners();
    onLineStarted?.call();

    Future.microtask(() async {
      if (!await _playIntroMoves()) return;
      if (phase == TrainingPhase.learning) {
        await advanceLearnPhase();
      } else {
        await advanceDrillPhase();
      }
    });
  }

  /// First move index (within the effective line length) whose comment has
  /// displayable prose. Returns 0 when no move qualifies, so the whole line
  /// is trained as before.
  int _firstCommentIndex() {
    if (currentLine == null) return 0;
    for (int i = 0; i < currentLineLength; i++) {
      final comment = currentLine!.comments[i.toString()];
      if (comment != null && filterDisplayComment(comment).isNotEmpty) {
        return i;
      }
    }
    return 0;
  }

  /// Auto-plays the moves before [trainingStartIndex] so the user watches the
  /// line take shape instead of drilling rote opening moves. Returns false if
  /// a new line (or dispose) interrupted playback.
  Future<bool> _playIntroMoves() async {
    if (trainingStartIndex <= 0 || currentLine == null) return true;
    final generation = _lineGeneration;

    playingIntro = true;
    waitingForUser = false;
    notifyListeners();

    for (int i = 0; i < trainingStartIndex; i++) {
      await Future.delayed(Duration(milliseconds: settings.introSpeedMs));
      if (generation != _lineGeneration) return false;

      final san = currentLine!.moves[i];
      if (session.position.parseSan(san) == null) {
        error = 'Invalid move in line: $san';
        playingIntro = false;
        notifyListeners();
        return false;
      }
      session.playMove(san);
      final isUser = _isUserMove(i);
      final display = _buildMoveDisplay(i, isOpponent: !isUser);
      if (isUser) {
        currentPairUser = display;
      } else {
        currentPairOpponent = display;
        currentPairUser = null;
      }
      currentMoveIndex = i + 1;
      notifyListeners();
    }

    await Future.delayed(Duration(milliseconds: settings.introSpeedMs));
    if (generation != _lineGeneration) return false;

    playingIntro = false;
    feedback = null;
    currentAnnotation = null;
    // Keep the opponent move as context for the first trained move; the
    // advance methods overwrite it when the next move is the opponent's.
    currentPairUser = null;
    notifyListeners();
    return true;
  }

  void nextLine() => rebuildQueueAndAdvance();

  // ---------------------------------------------------------------------------
  // LEARN PHASE
  // ---------------------------------------------------------------------------

  Future<void> advanceLearnPhase() async {
    if (currentLine == null) return;
    final generation = _lineGeneration;
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
      currentPairOpponent = null;
      currentPairUser = null;
      waitingForUser = false;
      notifyListeners();
      Future.microtask(() async {
        if (!await _playIntroMoves()) return;
        await advanceDrillPhase();
      });
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
    final isUserMove = _isUserMove(currentMoveIndex);
    final display = _buildMoveDisplay(
      currentMoveIndex,
      isOpponent: !isUserMove,
    );

    currentAnnotation = annotation;
    feedback = null;
    waitingForUser = false;

    if (!isUserMove) {
      currentPairOpponent = display;
      currentPairUser = null;
      notifyListeners();

      if (annotation != null && annotation.isNotEmpty) {
        opponentWaitingForAck = true;
        notifyListeners();
      } else {
        await Future.delayed(Duration(milliseconds: settings.moveSpeedMs));
        if (generation != _lineGeneration) return;
        currentMoveIndex++;
        await advanceLearnPhase();
      }
    } else {
      currentPairUser = display;
      notifyListeners();

      if (settings.learnRequiresClick) {
        learnWaitingForAck = true;
        notifyListeners();
      } else if (annotation != null && annotation.isNotEmpty) {
        _learnTimer = Timer(
          Duration(seconds: settings.learnDelaySec),
          learnAcknowledged,
        );
      } else {
        await Future.delayed(Duration(milliseconds: settings.moveSpeedMs));
        if (generation != _lineGeneration) return;
        currentMoveIndex++;
        await advanceLearnPhase();
      }
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
    final generation = _lineGeneration;
    final expectedSan = currentLine!.moves[currentMoveIndex];
    final isCorrect = isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      session.playMove(expectedSan);
      learnQuizzing = false;
      waitingForUser = false;
      feedback = 'Correct!';
      notifyListeners();
      await Future.delayed(Duration(milliseconds: settings.moveSpeedMs));
      if (generation != _lineGeneration) return;
      currentMoveIndex++;
      await advanceLearnPhase();
    } else {
      // Input stays off while the correction animates so a second answer
      // can't interleave with it; 'Try again' below re-enables it.
      waitingForUser = false;
      feedback = 'Wrong — the move is $expectedSan';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 1200));
      if (generation != _lineGeneration) return;
      session.playMove(expectedSan);
      await Future.delayed(const Duration(milliseconds: 800));
      if (generation != _lineGeneration) return;
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
    final isWhiteMove = startIsWhite
        ? (moveIndex % 2 == 0)
        : (moveIndex % 2 == 1);
    return (isWhiteLine && isWhiteMove) || (!isWhiteLine && !isWhiteMove);
  }

  Future<void> advanceDrillPhase() async {
    if (currentLine == null) return;
    final generation = _lineGeneration;
    final limit = effectiveLineLength;

    while (currentMoveIndex < limit) {
      if (_isUserMove(currentMoveIndex)) {
        _prepareDrillMove(currentMoveIndex);
        return;
      } else {
        _playOpponentMove(currentMoveIndex);
        if (opponentWaitingForAck) return;
        currentMoveIndex++;
        if (currentMoveIndex >= limit) {
          // Let the final opponent move register on the board before the
          // results panel replaces the card.
          await Future.delayed(Duration(milliseconds: settings.moveSpeedMs));
          if (generation != _lineGeneration) return;
        }
      }
    }
    _onLineComplete();
  }

  /// Plays the opponent reply with no trailing delay: the reply and the next
  /// "Your move" prompt land in the same frame. Pacing happens while the
  /// user's answered pair is still on screen (see [handleUserMove]).
  void _playOpponentMove(int moveIndex) {
    if (currentLine == null) return;
    final san = currentLine!.moves[moveIndex];
    final move = session.position.parseSan(san);
    if (move == null) {
      error = 'Could not play opponent move $san';
      notifyListeners();
      return;
    }
    session.playMove(san);

    final display = _buildMoveDisplay(moveIndex, isOpponent: true);
    currentPairOpponent = display;
    currentPairUser = null;

    final annotation = currentLine!.comments[moveIndex.toString()];
    currentAnnotation = annotation;
    notifyListeners();
  }

  void _prepareDrillMove(int moveIndex) {
    waitingForUser = true;
    currentAnnotation = null;
    feedback = null;
    currentPairUser = null;
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

    final generation = _lineGeneration;
    final expectedSan = currentLine!.moves[currentMoveIndex];
    final isCorrect = isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      updateMoveProgress(currentLine!, currentMoveIndex, wasCorrect: true);
      final display = _buildMoveDisplay(currentMoveIndex, isOpponent: false);
      session.playMove(expectedSan);
      waitingForUser = false;
      feedback = 'Correct!';
      currentPairUser = display;
      currentAnnotation = display.comment;
      notifyListeners();

      currentMoveIndex++;
      // Hold the completed pair + "Correct!" for the full pause, then swap
      // to the opponent's reply and next prompt in one update — no cleared
      // or opponent-only frames in between.
      await Future.delayed(Duration(milliseconds: settings.moveSpeedMs));
      if (generation != _lineGeneration) return;
      _clearPair();
      await advanceDrillPhase();
    } else {
      updateMoveProgress(currentLine!, currentMoveIndex, wasCorrect: false);
      lineHadMistake = true;
      wrongMoveIndices.add(currentMoveIndex);

      // Input off immediately so a second answer can't interleave with the
      // correction that plays out below.
      waitingForUser = false;
      feedback = 'Wrong — the move was $expectedSan';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 1200));
      if (generation != _lineGeneration) return;

      final display = _buildMoveDisplay(currentMoveIndex, isOpponent: false);
      session.playMove(expectedSan);
      currentPairUser = display;
      currentAnnotation = null;
      notifyListeners();
      currentMoveIndex++;
      await Future.delayed(Duration(milliseconds: settings.moveSpeedMs));
      if (generation != _lineGeneration) return;
      _clearPair();
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
    final generation = _lineGeneration;
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
      if (generation != _lineGeneration) return;
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

    final existing =
        reviewMap[currentLine!.id] ??
        RepertoireReviewEntry(
          repertoireId: repertoireId,
          lineId: currentLine!.id,
          lineName: currentLine!.name,
        );

    final hadMistake = lineHadMistake;
    final updated = reviewService
        .applyRating(existing, rating)
        .copyWith(
          passCount: hadMistake ? existing.passCount : existing.passCount + 1,
          failCount: hadMistake ? existing.failCount + 1 : existing.failCount,
        );
    reviewMap[currentLine!.id] = updated;

    await reviewService.saveAll([
      ..._otherRepertoireEntries,
      ...reviewMap.values,
    ]);
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
      ),
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
        playabilityMap: playabilityMap,
      );
      notifyListeners();
    }
  }

  void rebuildQueueAndAdvance() {
    dueQueue = reviewService.orderLinesForReview(
      lines,
      reviewMap,
      settings.reviewOrder,
      playabilityMap: playabilityMap,
    );

    if (dueQueue.isEmpty) {
      phase = TrainingPhase.finished;
      feedback = 'All caught up!';
      notifyListeners();
      return;
    }

    int nextIndex = 0;
    if (currentLine != null) {
      final currentQueueIndex = dueQueue.indexWhere(
        (l) => l.id == currentLine!.id,
      );
      if (currentQueueIndex >= 0) {
        nextIndex = (currentQueueIndex + 1) % dueQueue.length;
      }
    }
    startLine(dueQueue[nextIndex]);
  }

  /// Start the next unseen/new line from the queue.
  void startNextNew() {
    final line = dueQueue.firstWhere((l) {
      final entry = reviewMap[l.id];
      return entry == null || entry.isNew;
    }, orElse: () => dueQueue.first);
    startLine(line);
  }

  /// Start the next due-for-review (not new) line from the queue.
  void startNextDue() {
    final line = dueQueue.firstWhere((l) {
      final entry = reviewMap[l.id];
      return entry != null && !entry.isNew && entry.isDue;
    }, orElse: () => dueQueue.first);
    startLine(line);
  }

  void updateDueQueue(List<RepertoireLine> queue) {
    dueQueue = queue;
    notifyListeners();
  }

  void updateMoveProgress(
    RepertoireLine line,
    int moveIndex, {
    required bool wasCorrect,
  }) {
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

  // ---------------------------------------------------------------------------
  // MOVE DISPLAY HELPERS
  // ---------------------------------------------------------------------------

  /// Compute the full move number for a given move index in the current line.
  int _fullMoveNumber(int moveIndex) {
    if (currentLine == null) return 1;
    final startFullmoves = currentLine!.startPosition.fullmoves;
    final startIsWhite = currentLine!.startPosition.turn == Side.white;
    if (startIsWhite) {
      return startFullmoves + (moveIndex ~/ 2);
    } else {
      return startFullmoves + ((moveIndex + 1) ~/ 2);
    }
  }

  /// Whether the move at [moveIndex] is White's move.
  bool _isMoveWhite(int moveIndex) {
    if (currentLine == null) return true;
    final startIsWhite = currentLine!.startPosition.turn == Side.white;
    return startIsWhite ? (moveIndex % 2 == 0) : (moveIndex % 2 == 1);
  }

  /// Format a move as "1. e4" or "1... e5".
  String formatMoveNotation(int moveIndex, String san) {
    final num = _fullMoveNumber(moveIndex);
    final isWhite = _isMoveWhite(moveIndex);
    return isWhite ? '$num. $san' : '$num... $san';
  }

  /// Build a [MoveDisplayInfo] for the given move index.
  MoveDisplayInfo _buildMoveDisplay(int moveIndex, {bool isOpponent = false}) {
    if (currentLine == null) {
      return MoveDisplayInfo(
        moveIndex: moveIndex,
        san: '',
        fullMoveNumber: 1,
        isWhiteMove: true,
        isOpponentMove: isOpponent,
        comment: null,
      );
    }
    final san = currentLine!.moves[moveIndex];
    return MoveDisplayInfo(
      moveIndex: moveIndex,
      san: san,
      fullMoveNumber: _fullMoveNumber(moveIndex),
      isWhiteMove: _isMoveWhite(moveIndex),
      isOpponentMove: isOpponent,
      comment: currentLine!.comments[moveIndex.toString()],
    );
  }

  void _clearPair() {
    currentPairOpponent = null;
    currentPairUser = null;
    feedback = null;
    currentAnnotation = null;
  }

  void opponentAcknowledged() {
    opponentWaitingForAck = false;
    currentAnnotation = null;
    notifyListeners();
    Future.microtask(() {
      if (phase == TrainingPhase.learning) {
        currentMoveIndex++;
        advanceLearnPhase();
      } else {
        currentMoveIndex++;
        advanceDrillPhase();
      }
    });
  }
}

/// Information about a move to display in the Chessable-style panel.
class MoveDisplayInfo {
  final int moveIndex;
  final String san;
  final int fullMoveNumber;
  final bool isWhiteMove;
  final bool isOpponentMove;
  final String? comment;

  const MoveDisplayInfo({
    required this.moveIndex,
    required this.san,
    required this.fullMoveNumber,
    required this.isWhiteMove,
    required this.isOpponentMove,
    this.comment,
  });

  /// Formatted notation like "1. e4" or "1... e5"
  String get notation =>
      isWhiteMove ? '$fullMoveNumber. $san' : '$fullMoveNumber... $san';

  /// Label like "Black's move 1... e5" or "White's move 2. Nf3"
  String get moveLabel {
    final side = isWhiteMove ? "White's" : "Black's";
    return '$side move $notation';
  }

  /// Label for "Your move" display.
  String get yourMoveLabel => 'Your move $notation';
}
