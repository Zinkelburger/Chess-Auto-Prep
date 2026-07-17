import 'dart:async';
import 'dart:isolate';

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

part 'training_session_display.dart';
part 'training_session_validation.dart';
part 'training_session_learn.dart';
part 'training_session_replay.dart';

/// Manages repertoire training session state: phases, line queue, move validation,
/// progress persistence, and session statistics.
class TrainingSessionController extends ChangeNotifier
    with
        SafeChangeNotifier,
        _MoveDisplayMixin,
        _MoveValidationMixin,
        _LearnPhaseMixin,
        _ReplayPhaseMixin {
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

  // -- Source & modes --

  /// True when the loaded source is a study (custom puzzles), not a
  /// repertoire.  Studies parse with per-chapter solver colours and skip the
  /// playability/tree machinery.
  bool sourceIsStudy = false;

  /// Repertoire mode walks new lines through the learn phase; tactics mode
  /// always quizzes cold (a puzzle's solution must not be shown first).
  TrainingMode trainingMode = TrainingMode.repertoire;

  /// Spaced repetition (due-queue + Again/Hard/Good/Easy) or linear (every
  /// line once, in order, no scheduling).
  RepetitionMode repetitionMode = RepetitionMode.spaced;

  /// Lines completed during this linear session (line ids).
  final Set<String> _linearDone = {};

  /// Per-line playability scores from the generated tree (0 = hardest, 1 = easiest).
  /// Empty when no tree.json exists for the repertoire.
  Map<String, double> playabilityMap = {};

  /// Per-line bottleneck info: (ply, quality, isOurMove).
  Map<String, ({int ply, double quality, bool isOurMove})> bottleneckMap = {};

  /// True when no tree.json was found for the current repertoire.
  /// Studies have no generated tree — never prompt to score them.
  bool get needsScoring =>
      !sourceIsStudy && _treeRoot == null && lines.isNotEmpty;

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

  /// Bumped on every [loadRepertoire] call.  Parsing now runs off the UI
  /// isolate, so a study↔repertoire handoff can start a second load while the
  /// first is still parsing; the load holding the latest token wins and any
  /// older one bails instead of interleaving its lines/queue with the other
  /// load's source and mode.  Distinct from [_lineGeneration] (per-line
  /// pacing).
  int _loadGeneration = 0;

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
    sourceIsStudy = false;
    trainingMode = TrainingMode.repertoire;
    repetitionMode = RepetitionMode.spaced;
    notifyListeners();
  }

  /// Select a study as the training source: each chapter is one puzzle
  /// (start FEN + solution mainline).  Defaults to tactics mode with linear
  /// repetition; both stay user-switchable.
  void setStudySource(RepertoireMetadata value) {
    repertoire = value;
    sourceIsStudy = true;
    trainingMode = TrainingMode.tactics;
    repetitionMode = RepetitionMode.linear;
    notifyListeners();
  }

  /// Switch between repertoire (learn + drill) and tactics (cold solve).
  /// Restarts the in-progress line so the change takes effect immediately.
  void setTrainingMode(TrainingMode mode) {
    if (trainingMode == mode) return;
    trainingMode = mode;
    notifyListeners();
    if (currentLine != null && phase != TrainingPhase.finished) {
      startLine(currentLine);
    }
  }

  /// Switch between spaced repetition and linear scheduling.  Rebuilds the
  /// queue; the in-progress line keeps playing.
  void setRepetitionMode(RepetitionMode mode) {
    if (repetitionMode == mode) return;
    repetitionMode = mode;
    if (mode == RepetitionMode.linear) _linearDone.clear();
    dueQueue = _buildQueue();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // REPERTOIRE LOADING
  // ---------------------------------------------------------------------------

  Future<void> loadRepertoire({String? startLineId}) async {
    if (repertoire == null) return;
    // Capture the token and the source flag up front: `sourceIsStudy` is a
    // shared mutable field a concurrent handoff can flip while we await, so
    // this load must decide "study or repertoire" from its own snapshot.
    final generation = ++_loadGeneration;
    final loadIsStudy = sourceIsStudy;
    isLoading = true;
    error = null;
    feedback = null;
    notifyListeners();

    try {
      final filePath = repertoire!.filePath;
      final parsedLines = await repertoireService.parseRepertoireFile(
        filePath,
        // Study puzzles: the solver is whoever moves first in each chapter.
        colorFromStartingSide: loadIsStudy,
      );
      if (generation != _loadGeneration) return; // superseded mid-parse
      if (parsedLines.isEmpty) {
        error = loadIsStudy
            ? 'No chapters with moves to train.'
            : 'No trainable lines found.';
        return;
      }

      final allEntries = await reviewService.loadAll();
      final moveProgress = await reviewService.loadMoveProgress();
      if (generation != _loadGeneration) return;
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
      if (generation != _loadGeneration) return;

      lines = parsedLines;
      reviewMap = {for (final e in merged) e.lineId: e};
      moveProgressMap = reviewService.indexMoveProgress(
        moveProgress.where((mp) => mp.repertoireId == filePath).toList(),
      );

      if (loadIsStudy) {
        // No generated tree for studies — clear any repertoire leftovers.
        _treeRoot = null;
        _treeIsWhite = null;
        playabilityMap = {};
        bottleneckMap = {};
      } else {
        await _loadTreeAndComputePlayability(filePath, parsedLines);
        if (generation != _loadGeneration) return;
      }

      _linearDone.clear();
      dueQueue = _buildQueue();
      notifyListeners();

      // Land on the line browser; only jump straight into a line when the
      // caller asked for one (e.g. "Train this line" from the Builder).
      if (startLineId != null) {
        pickStartingLine(startLineId: startLineId);
      }
    } catch (e) {
      if (generation != _loadGeneration) return;
      error = 'Error loading repertoire: $e';
      notifyListeners();
    } finally {
      // Only the current load owns the loading flag; a superseded one must
      // leave it set so the winning load's spinner stays up.
      if (generation == _loadGeneration) {
        isLoading = false;
        notifyListeners();
      }
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

      // Multi-MB jsonDecode + recursive node build — off the UI isolate so
      // opening the trainer doesn't freeze the frame.
      final tree = await Isolate.run(() => deserializeTree(json));
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

  /// The review queue under the active repetition mode: spaced = due/new
  /// lines only; linear = every line not yet completed this session.
  List<RepertoireLine> _buildQueue() {
    // Studies carry no CumProb, so the default "by cumulative probability"
    // order would be meaningless — fall back to file (chapter) order.
    var order = settings.reviewOrder;
    if (sourceIsStudy && order == ReviewOrder.byImportance) {
      order = ReviewOrder.sequential;
    }
    final ordered = reviewService.orderLinesForReview(
      lines,
      reviewMap,
      order,
      playabilityMap: playabilityMap,
      dueOnly: repetitionMode == RepetitionMode.spaced,
    );
    if (repetitionMode == RepetitionMode.linear) {
      return [
        for (final line in ordered)
          if (!_linearDone.contains(line.id)) line,
      ];
    }
    return ordered;
  }

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

    // Tactics mode always quizzes cold — the learn walkthrough would show
    // the puzzle's solution.
    final isNew = trainingMode == TrainingMode.repertoire && _isLineNew(line);

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
    // Never auto-play intro moves in tactics mode — they are the solution.
    trainingStartIndex =
        trainingMode == TrainingMode.repertoire && settings.skipToFirstComment
        ? _firstCommentIndex()
        : 0;
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

  /// Skip the current line without rating it — it stays in the queue and the
  /// next line starts immediately.
  void skipLine() {
    if (currentLine == null) return;
    _learnTimer?.cancel();
    rebuildQueueAndAdvance();
  }

  /// Restart the current line from the beginning (learn phase again if the
  /// line is still new).
  void restartLine() {
    if (currentLine == null) return;
    startLine(currentLine);
  }

  /// Leave the active line and return to the line browser. Nothing is rated
  /// or persisted; the queue is refreshed.
  void stopSession() {
    _learnTimer?.cancel();
    _lineGeneration++;
    currentLine = null;
    phase = TrainingPhase.drilling;
    waitingForUser = false;
    feedback = null;
    currentAnnotation = null;
    currentPairOpponent = null;
    currentPairUser = null;
    learnWaitingForAck = false;
    learnQuizzing = false;
    opponentWaitingForAck = false;
    playingIntro = false;
    session.clearMoveHistory();
    dueQueue = _buildQueue();
    notifyListeners();
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
      _finishLine();
    }
  }

  /// Enter the finished phase.  In spaced mode the results panel asks for a
  /// rating; in linear mode the completion is recorded here (pass/fail, no
  /// scheduling) and the panel offers Next.
  @override
  void _finishLine() {
    phase = TrainingPhase.finished;
    waitingForUser = false;
    currentAnnotation = null;
    if (repetitionMode == RepetitionMode.linear) {
      final solvedClean = !lineHadMistake;
      feedback = trainingMode == TrainingMode.tactics
          ? (solvedClean ? 'Puzzle solved!' : 'Solved — with mistakes.')
          : (solvedClean ? 'Line complete!' : 'Line complete — with mistakes.');
      unawaited(_recordLinearCompletion());
    } else {
      feedback = 'Line complete — rate your recall.';
    }
    notifyListeners();
  }

  /// Linear-mode bookkeeping: pass/fail counts, session stats and history —
  /// but no spaced-repetition scheduling (the line stays "new" for SRS).
  Future<void> _recordLinearCompletion() async {
    final line = currentLine;
    if (line == null) return;
    _linearDone.add(line.id);
    // Drop the finished line from the queue synchronously so the results
    // panel's remaining count (and set-complete detection) are accurate.
    dueQueue = _buildQueue();

    final hadMistake = lineHadMistake;
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

    final existing =
        reviewMap[line.id] ??
        RepertoireReviewEntry(
          repertoireId: repertoireId,
          lineId: line.id,
          lineName: line.name,
        );
    reviewMap[line.id] = existing.copyWith(
      passCount: hadMistake ? existing.passCount : existing.passCount + 1,
      failCount: hadMistake ? existing.failCount + 1 : existing.failCount,
    );

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
        lineId: line.id,
        timestampUtc: DateTime.now().toUtc(),
        rating: '',
        hadMistake: hadMistake,
        sessionType: 'linear',
      ),
    ]);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // RATING & PROGRESS
  // ---------------------------------------------------------------------------

  Future<void> rateLine(ReviewRating rating) async {
    if (currentLine == null) return;
    // Linear mode has no ratings — completion was recorded in _finishLine;
    // a stray rating call (keyboard shortcut) just advances.
    if (repetitionMode == RepetitionMode.linear) {
      rebuildQueueAndAdvance();
      return;
    }

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
      dueQueue = _buildQueue();
      notifyListeners();
    }
  }

  void rebuildQueueAndAdvance() {
    dueQueue = _buildQueue();

    if (dueQueue.isEmpty) {
      phase = TrainingPhase.finished;
      feedback = repetitionMode == RepetitionMode.linear
          ? 'Set complete!'
          : 'All caught up!';
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
