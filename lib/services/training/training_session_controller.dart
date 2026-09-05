import 'dart:async';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/repertoire_controller.dart';
import '../../models/build_tree_node.dart' show BuildTreeNode;
import '../../models/line_status.dart';
import '../../models/repertoire_line.dart';
import '../../models/repertoire_metadata.dart';
import '../../models/repertoire_move_progress.dart';
import '../../models/repertoire_review_entry.dart'
    show RepertoireReviewEntry, ReviewRating;
import '../../models/completed_move.dart';
import '../../models/training_settings.dart';
import '../../utils/pgn_comment_utils.dart' show filterDisplayComment;
import '../../utils/chess_utils.dart' show isNullMoveSan, playSanOrNullMove;
import '../../utils/safe_change_notifier.dart';
import '../asked_questions_store.dart';
import '../generation/tree_my_ease.dart' show computeLinePlayability;
import '../generation/tree_serialization.dart' show deserializeTree;
import '../line_metrics_helpers.dart' show walkTreeForLine;
import '../repertoire_review_service.dart';
import '../repertoire_service.dart';
import '../storage/storage_factory.dart';
import 'chapter_layout.dart';
import 'move_display.dart';
export 'move_display.dart' show MoveDisplayInfo;
import 'move_validation.dart' as validation;
import 'chapter_scope.dart';
import 'learn_phase.dart';
import 'replay_phase.dart';
import 'review_progress_store.dart';
import 'training_phase.dart';
import 'training_run.dart';

/// Manages repertoire training session state: phases, line queue, move validation,
/// progress persistence, and session statistics.
class TrainingSessionController extends ChangeNotifier with SafeChangeNotifier {
  final RepertoireService repertoireService;
  final RepertoireReviewService reviewService;

  /// Remembers the ask-once prompts (currently "sort into chapters?") so a
  /// file is never asked twice.
  final AskedQuestionsStore askedQuestions;

  TrainingSessionController({
    RepertoireService? repertoireService,
    RepertoireReviewService? reviewService,
    AskedQuestionsStore? askedQuestions,
  }) : repertoireService = repertoireService ?? RepertoireService(),
       reviewService = reviewService ?? RepertoireReviewService(),
       askedQuestions = askedQuestions ?? AskedQuestionsStore() {
    session.addListener(_onSessionChanged);
    learn = LearnPhase(this);
    replay = ReplayPhase(this);
  }

  /// New-line walkthrough (acknowledge / quiz). The controller still exposes
  /// the same methods the trainer UI binds to; they delegate here.
  late final LearnPhase learn;

  /// Missed-move replay after a drill with mistakes.
  late final ReplayPhase replay;

  final RepertoireController session = RepertoireController();

  // -- Data --
  RepertoireMetadata? repertoire;
  List<RepertoireLine> lines = [];

  /// Persisted review state: schedules, per-move streaks, history writes.
  /// Owns everything that outlives the session; this controller owns what the
  /// user is looking at right now.
  late final ReviewProgressStore progress = ReviewProgressStore(
    reviewService: reviewService,
    repertoireService: repertoireService,
    settings: () => settings,
    repertoireId: () => repertoireId,
  );

  Map<String, RepertoireReviewEntry> get reviewMap => progress.byLine;
  Map<String, RepertoireMoveProgress> get moveProgressMap =>
      progress.moveProgress;
  TrainingSettings settings = TrainingSettings();

  // -- Source & modes --

  /// True when the loaded source is a study (custom puzzles), not a
  /// repertoire.  Studies parse with per-chapter solver colours and skip the
  /// playability/tree machinery.
  bool sourceIsStudy = false;

  /// Repertoire mode walks new lines through the learn phase; tactics mode
  /// always quizzes cold (a puzzle's solution must not be shown first).
  TrainingMode trainingMode = TrainingMode.repertoire;

  /// The user's hand-set answer to "which side does this file train?", or
  /// null when nobody has overridden the file's own answer. Non-null is what
  /// makes the trainer stop trusting the `// Color:` header and the move-tree
  /// inference for this file.
  bool? colorOverrideIsWhite;

  /// Spaced repetition (due-queue + Again/Hard/Good/Easy) or linear (every
  /// line once, in order, no scheduling).
  RepetitionMode repetitionMode = RepetitionMode.spaced;

  /// What the current run is working through. Learn walks untrained lines,
  /// Review walks due ones; auto-next stays inside the intent so a Learn
  /// session is never interrupted by a due line (and vice versa).
  TrainingIntent sessionIntent = TrainingIntent.learn;

  /// What this sitting covers and what comes next — the run scope, the cap,
  /// and the message when it ends.
  late final TrainingRun run = TrainingRun(
    repetitionMode: () => repetitionMode,
    settings: () => settings,
    reviewMap: () => reviewMap,
  );

  /// True once a run has nothing left to show. The trainer displays the
  /// session summary instead of asking the user to rate the last line again.
  bool runComplete = false;

  /// Lines completed during this linear session (line ids).
  final Set<String> _linearDone = {};

  /// Per-line playability scores from the generated tree (0 = hardest, 1 = easiest).
  /// Empty when no tree.json exists for the repertoire.
  Map<String, double> playabilityMap = {};

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

  /// Colour the loaded source trains, read from its first line. Answers the
  /// question before a line is picked — board orientation on the browse
  /// screens, and the browser subtitle — where [isWhiteLine] has no line to
  /// look at and would always say White.
  bool get sourceIsBlack =>
      lines.isNotEmpty && lines.first.color.toLowerCase() == 'black';
  String get repertoireId => repertoire?.filePath ?? '';
  int get effectiveLineLength => currentLineLength;

  /// Bumped when a new line starts; collaborators abort stale async pacing.
  int get lineGeneration => _lineGeneration;

  Future<void> advanceLearnPhase() => learn.advance();
  void learnAcknowledged() => learn.acknowledged();
  Future<void> handleLearnQuizMove(CompletedMove move) =>
      learn.handleQuizMove(move);
  void startReplayPhase() => replay.start();
  Future<void> handleReplayMove(CompletedMove move) => replay.handleMove(move);
  void setupReplayPosition() => replay.setupPosition();
  void completeLine() => _finishLine();

  /// Lets phase collaborators notify without calling the protected
  /// [ChangeNotifier.notifyListeners] from another library.
  void emitChange() => notifyListeners();

  void _onSessionChanged() => notifyListeners();

  @override
  void dispose() {
    _lineGeneration++;
    learn.cancelPending();
    // Get the session's schedules into the PGN before the timer that would
    // have done it is cancelled.
    unawaited(progress.flushHeaders());
    progress.dispose();
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
      startLine(currentLine, intent: sessionIntent, keepRunScope: true);
    }
  }

  /// Record that this file trains [isWhite]'s side and reload with it.
  ///
  /// Getting the side wrong makes every line quiz the opponent's moves, and a
  /// third-party course export says nothing about which side it is for — so
  /// this override has to exist, has to survive a restart, and has to be
  /// reachable while looking at the wrong-side lines. Passing null forgets the
  /// override and hands the question back to the file.
  Future<void> setTrainingColor(bool? isWhite) async {
    if (sourceIsStudy || colorOverrideIsWhite == isWhite) return;
    colorOverrideIsWhite = isWhite;
    final filePath = repertoire?.filePath;
    // Reload before the write: the user should see the board flip now, not
    // after a file round-trip.
    final reloaded = loadRepertoire();
    if (filePath != null) {
      if (isWhite == null) {
        await askedQuestions.forget(
          AskedQuestion.trainingColor,
          subject: filePath,
        );
      } else {
        await askedQuestions.record(
          AskedQuestion.trainingColor,
          subject: filePath,
          answer: isWhite,
          note: 'set by hand in the trainer',
        );
      }
    }
    await reloaded;
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
      // A hand-set colour beats everything: it exists precisely because the
      // file and the inference between them got it wrong.
      colorOverrideIsWhite = loadIsStudy
          ? null
          : await askedQuestions.boolAnswerFor(
              AskedQuestion.trainingColor,
              subject: filePath,
            );
      if (generation != _loadGeneration) return;
      final parsedLines = await repertoireService.parseRepertoireFile(
        filePath,
        trainingColor: colorOverrideIsWhite == null
            ? null
            : (colorOverrideIsWhite! ? 'white' : 'black'),
        // Study puzzles: the solver is whoever moves first in each chapter.
        colorFromStartingSide: loadIsStudy,
        // Imported courses declare no `// Color:`; without this every Black
        // repertoire would quiz the user on White's moves.
        inferColorWhenUnknown: !loadIsStudy,
      );
      if (generation != _loadGeneration) return; // superseded mid-parse
      if (parsedLines.isEmpty) {
        error = loadIsStudy
            ? 'No chapters with moves to train.'
            : 'No trainable lines found.';
        return;
      }

      final allEntries = await reviewService.loadAll();
      final loadedMoveProgress = await reviewService.loadMoveProgress();
      if (generation != _loadGeneration) return;
      final otherRepertoires = allEntries
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
      await reviewService.saveAll(merged, repertoireId: filePath);
      if (generation != _loadGeneration) return;

      lines = parsedLines;
      // The browser sits beside an idle board, so park it on this source's own
      // starting position rather than leaving the last line's board up.
      session.setPositionFromFen(parsedLines.first.startPosition.fen);
      progress.adopt(
        byLine: {for (final e in merged) e.lineId: e},
        moveProgress: reviewService.indexMoveProgress(
          loadedMoveProgress
              .where((mp) => mp.repertoireId == filePath)
              .toList(),
        ),
        otherRepertoires: otherRepertoires,
      );

      if (loadIsStudy) {
        // No generated tree for studies — clear any repertoire leftovers.
        _treeRoot = null;
        _treeIsWhite = null;
        playabilityMap = {};
      } else {
        await _loadTreeAndComputePlayability(filePath, parsedLines);
        if (generation != _loadGeneration) return;
      }

      _linearDone.clear();
      await chapterScope.resolveLayout(filePath, isStudy: loadIsStudy);
      if (generation != _loadGeneration) return;
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
      }
    } catch (e) {
      debugPrint('[TrainingController] Failed to load tree: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // LINE MANAGEMENT
  // ---------------------------------------------------------------------------

  /// Chapter grouping, detection, and scoping.  Owns everything about *which
  /// chapter a line is in*; this controller keeps ownership of the queue and
  /// of notifying listeners, so each mutator below is "ask the scope, then
  /// rebuild and repaint if it says something changed".
  late final ChapterScope chapterScope = ChapterScope(
    askedQuestions: askedQuestions,
    settings: () => settings,
    lines: () => lines,
    sourceIsStudy: () => sourceIsStudy,
  );

  /// Sentinel [activeChapter] for "the lines this file's chapter scheme
  /// doesn't cover" — a real chapter name can never be a NUL byte.
  static const ungroupedChapter = ChapterScope.ungrouped;

  /// Chapter the trainer is currently scoped to, or null for all lines.
  /// Filters the line list, the due queue, and Learn/Review advancement.
  String? get activeChapter => chapterScope.activeChapter;

  /// Chapter layout this file appears to use, waiting on the user's answer
  /// ("Looks like a course export — sort into chapters?"). Null when the file
  /// has no detectable layout or the question was already answered.
  ChapterLayoutProposal? get pendingChapterPrompt => chapterScope.pendingPrompt;

  /// The user said "keep one flat list" for this file.
  bool get chaptersDeclined => chapterScope.declined;

  bool get canOfferChapters => chapterScope.canOffer;

  /// The chapter a line belongs to under the current grouping setting.
  String? chapterOf(RepertoireLine line) => chapterScope.chapterOf(line);

  /// Whether [line] belongs to [chapter]; null means "all chapters" and
  /// [ungroupedChapter] means "the lines with no chapter of their own".
  bool lineInChapter(RepertoireLine line, String? chapter) =>
      chapterScope.contains(line, chapter);

  /// Distinct chapters in file order. Empty when the source has none.
  List<String> get chapters => chapterScope.names;

  /// Lines the chapter scheme leaves out (an intro game with no title, say).
  bool get hasUngroupedLines => chapterScope.hasUngroupedLines;

  /// Scope training to [chapter] (null = all chapters) and rebuild the queue.
  void setActiveChapter(String? chapter) {
    if (!chapterScope.setActive(chapter)) return;
    dueQueue = _buildQueue();
    notifyListeners();
  }

  /// The chapter grouping source changed — the old filter may not exist
  /// under the new scheme, so drop it and rebuild.
  void onChapterSettingsChanged() {
    chapterScope.onSettingsChanged();
    dueQueue = _buildQueue();
    notifyListeners();
  }

  /// Answer the "sort into chapters?" prompt. The choice is remembered per
  /// file, so the question is asked once and stays changeable from the
  /// trainer header.
  Future<void> answerChapterPrompt(bool useChapters) =>
      chapterScope.answerPrompt(
        useChapters,
        filePath: repertoire?.filePath,
        // Repaint as soon as the grouping is live, before the answer reaches
        // disk — the user should not wait on a file write to see the change.
        onApplied: () {
          dueQueue = _buildQueue();
          notifyListeners();
        },
      );

  /// Drop the chapter prompt without recording an answer (the dialog was
  /// dismissed rather than answered), so the next load asks again.
  void dismissChapterPrompt() {
    if (chapterScope.dismissPrompt()) notifyListeners();
  }

  /// Re-open the chapter prompt from the header ("Chapters…"), so a "no"
  /// answer is never final.
  void reopenChapterPrompt() {
    if (chapterScope.reopenPrompt()) notifyListeners();
  }

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
      chapterScope.scopedLines,
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

  // ---------------------------------------------------------------------------
  // LEARN / REVIEW RUNS
  // ---------------------------------------------------------------------------

  /// Lines in the current scope with each status — what the Learn and Review
  /// buttons are enabled from.
  LineCounts countsFor({String? chapter}) => countLines([
    for (final line in lines)
      if (lineInChapter(line, chapter)) line,
  ], reviewMap);

  /// Start working through untrained lines in the active chapter.
  void startLearnSession() => _startSession(TrainingIntent.learn);

  /// Start working through the lines that are due in the active chapter.
  void startReviewSession() => _startSession(TrainingIntent.review);

  void _startSession(TrainingIntent intent) {
    dueQueue = _buildQueue();
    run.begin(dueQueue, intent);
    final line = run.next(dueQueue, intent);
    if (line == null) {
      // Nothing to do in this scope: say so instead of dropping the user into
      // an unrelated line (the old buttons fell back to dueQueue.first, which
      // threw on an empty queue).
      final message = run.completeMessage(intent);
      run.clear();
      feedback = message;
      notifyListeners();
      return;
    }
    startLine(line, intent: intent, keepRunScope: true);
  }

  /// Lines still ahead in this run — what the Train tab counts down.
  ///
  /// Counted once per notification: the screen reads it several times per
  /// build, and every read walked the queue with a status lookup per line.
  int get remainingInRun =>
      _remainingInRun ??= run.remaining(dueQueue, sessionIntent);

  int? _remainingInRun;

  @override
  void notifyListeners() {
    _remainingInRun = null;
    super.notifyListeners();
  }

  /// Start [line] now. [intent] is what the rest of the run should work
  /// through; by default it follows the line's own status, so clicking an
  /// untrained line starts a Learn run and clicking a due one a Review run.
  ///
  /// [keepRunScope] is for the Learn/Review buttons, which have just decided
  /// what this sitting covers. Picking a line off the list instead is a
  /// deliberate "train this one", so it drops the cap rather than refusing to
  /// continue past a set the user never asked for.
  void startLine(
    RepertoireLine? line, {
    TrainingIntent? intent,
    bool keepRunScope = false,
  }) {
    if (line == null) return;
    if (!keepRunScope) run.clear();
    sessionIntent =
        intent ??
        (_isLineNew(line) ? TrainingIntent.learn : TrainingIntent.review);
    runComplete = false;
    learn.cancelPending();

    resetBoard(line);

    var effectiveLength = settings.trainingDepth != null
        ? settings.trainingDepth!.clamp(1, line.moves.length)
        : line.moves.length;
    // A `[%tend]` marker ends the quiz after the marked move; anything past
    // it in the chapter is post-mortem context, not solution. Ignored when it
    // would leave nothing to train (end marked before the start).
    final markerEnd = line.puzzleEndIndex;
    if (markerEnd != null && markerEnd >= (line.puzzleStartIndex ?? 0)) {
      effectiveLength = (markerEnd + 1).clamp(1, effectiveLength);
    }

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
    // A `[%tstart]` marker pins where the quiz begins: moves before it are
    // prelude that auto-plays in every mode (they are context, not solution).
    // Without a marker, tactics mode never auto-plays intro moves — they ARE
    // the solution — and repertoire mode optionally skips to the first
    // annotated move.
    final markerStart = line.puzzleStartIndex;
    trainingStartIndex = markerStart != null && markerStart < effectiveLength
        ? markerStart
        : (trainingMode == TrainingMode.repertoire &&
                  settings.skipToFirstComment
              ? _firstCommentIndex()
              : 0);
    notifyListeners();
    onLineStarted?.call();

    unawaited(
      Future.microtask(() async {
        if (!await playIntroMoves()) return;
        if (phase == TrainingPhase.learning) {
          await advanceLearnPhase();
        } else {
          await advanceDrillPhase();
        }
      }),
    );
  }

  /// Put the board on [line]'s first position with no history.
  ///
  /// Always a fresh tree from the line's own FEN. `clearMoveHistory()` keeps
  /// the previous tree's starting FEN, so the old "clear unless the line has
  /// a set-up position" branch left a line that starts from the initial
  /// position on the *previous* puzzle's board, where none of its moves were
  /// legal. Every phase that rewinds a line (start, learn → drill, replay)
  /// goes through here.
  void resetBoard(RepertoireLine line) {
    session.setPositionFromFen(line.startPosition.fen);
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
  Future<bool> playIntroMoves() async {
    if (trainingStartIndex <= 0 || currentLine == null) return true;
    final generation = _lineGeneration;

    playingIntro = true;
    waitingForUser = false;
    notifyListeners();

    for (int i = 0; i < trainingStartIndex; i++) {
      await Future.delayed(Duration(milliseconds: settings.introSpeedMs));
      if (generation != _lineGeneration) return false;

      final san = currentLine!.moves[i];
      if (playSanOrNullMove(session.position, san) == null) {
        error = 'Invalid move in line: $san';
        playingIntro = false;
        notifyListeners();
        return false;
      }
      session.playMove(san);
      final isUser = isUserMove(i);
      final display = buildMoveDisplay(currentLine, i, isOpponent: !isUser);
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
    learn.cancelPending();
    rebuildQueueAndAdvance();
  }

  /// Restart the current line from the beginning (learn phase again if the
  /// line is still new).
  void restartLine() {
    if (currentLine == null) return;
    startLine(currentLine, intent: sessionIntent, keepRunScope: true);
  }

  /// Leave the active line and return to the line browser. Nothing is rated
  /// or persisted; the queue is refreshed.
  void stopSession() {
    learn.cancelPending();
    // Leaving the line is the natural moment to pay off the batched PGN
    // writes: the user has stopped answering, so the pause costs nothing.
    unawaited(progress.flushHeaders());
    _lineGeneration++;
    runComplete = false;
    run.clear();
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
    // Park the idle board on the source's own start, as loadRepertoire does;
    // clearing history alone would keep the last line's set-up position.
    if (lines.isNotEmpty) {
      resetBoard(lines.first);
    } else {
      session.clearMoveHistory();
    }
    dueQueue = _buildQueue();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // DRILL PHASE
  // ---------------------------------------------------------------------------

  bool isUserMove(int moveIndex) {
    if (currentLine == null) return false;
    if (isNullMoveSan(currentLine!.moves[moveIndex])) return false;
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
      if (isUserMove(currentMoveIndex)) {
        _prepareDrillMove();
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
    if (playSanOrNullMove(session.position, san) == null) {
      error = 'Could not play opponent move $san';
      notifyListeners();
      return;
    }
    session.playMove(san);

    final display = buildMoveDisplay(currentLine, moveIndex, isOpponent: true);
    currentPairOpponent = display;
    currentPairUser = null;

    final annotation = currentLine!.comments[moveIndex.toString()];
    currentAnnotation = annotation;
    notifyListeners();
  }

  void _prepareDrillMove() {
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
    final isCorrect = validation.isCorrectUserMove(
      session.position,
      move,
      expectedSan,
    );

    if (isCorrect) {
      updateMoveProgress(currentLine!, currentMoveIndex, wasCorrect: true);
      final display = buildMoveDisplay(
        currentLine,
        currentMoveIndex,
        isOpponent: false,
      );
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

      final display = buildMoveDisplay(
        currentLine,
        currentMoveIndex,
        isOpponent: false,
      );
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
    _tallySessionResult(hadMistake: hadMistake);
    await progress.recordCompletion(line, hadMistake: hadMistake);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // RATING & PROGRESS
  // ---------------------------------------------------------------------------

  /// Fold one finished line into the running session counters.
  void _tallySessionResult({required bool hadMistake}) {
    if (hadMistake) {
      sessionIncorrect++;
      sessionStreak = 0;
      return;
    }
    sessionCorrect++;
    sessionStreak++;
    if (sessionStreak > sessionBestStreak) {
      sessionBestStreak = sessionStreak;
    }
  }

  Future<void> rateLine(ReviewRating rating) async {
    final line = currentLine;
    if (line == null) return;
    // Linear mode has no ratings — completion was recorded in _finishLine;
    // a stray rating call (keyboard shortcut) just advances.
    if (repetitionMode == RepetitionMode.linear) {
      rebuildQueueAndAdvance();
      return;
    }

    final hadMistake = lineHadMistake;
    await progress.recordRating(line, rating, hadMistake: hadMistake);
    _tallySessionResult(hadMistake: hadMistake);
    notifyListeners();

    if (settings.autoNext) {
      rebuildQueueAndAdvance();
    } else {
      dueQueue = _buildQueue();
      notifyListeners();
    }
  }

  /// Advance to the next line of the current run (Learn or Review), or finish
  /// the session when the scope is exhausted.
  void rebuildQueueAndAdvance() {
    dueQueue = _buildQueue();

    final next = run.next(
      dueQueue,
      sessionIntent,
      afterLineId: currentLine?.id,
    );
    if (next == null) {
      phase = TrainingPhase.finished;
      runComplete = true;
      feedback = run.completeMessage(sessionIntent);
      run.clear();
      unawaited(progress.flushHeaders());
      notifyListeners();
      return;
    }
    startLine(next, intent: sessionIntent, keepRunScope: true);
  }

  /// Rebuild the due queue after a settings change (review order, depth…).
  void updateDueQueue() {
    dueQueue = _buildQueue();
    notifyListeners();
  }

  /// Bulk-set which lines count as learned without training them — for lines
  /// the user already knows from elsewhere (another tool, over-the-board
  /// experience). Lines in [checkedLineIds] that are new get seeded as
  /// learned; learned lines left unchecked are reset to new. Returns how
  /// many lines changed state.
  ///
  /// [within] limits the pass to those line ids (the lines the user could
  /// actually see): with a chapter filter active, learned lines outside the
  /// chapter must not be reset just because they weren't on screen.
  Future<int> applyLearnedSelection(
    Set<String> checkedLineIds, {
    Set<String>? within,
  }) => progress.applyLearnedSelection(
    lines,
    checkedLineIds,
    within: within,
    // Repaint as soon as the in-memory state is right, before the writes —
    // marking a whole course learned should not feel like it hangs.
    onApplied: () {
      dueQueue = _buildQueue();
      notifyListeners();
    },
  );

  void updateMoveProgress(
    RepertoireLine line,
    int moveIndex, {
    required bool wasCorrect,
  }) => progress.recordMove(line, moveIndex, wasCorrect: wasCorrect);

  double moveDifficulty(RepertoireLine line, int moveIndex) =>
      progress.moveDifficulty(line, moveIndex);

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
    // A second Next (double-click, or Space landing after the click) must
    // not step the cursor past the move that was waiting.
    if (!opponentWaitingForAck) return;
    opponentWaitingForAck = false;
    currentAnnotation = null;
    notifyListeners();
    unawaited(
      Future.microtask(() {
        if (phase == TrainingPhase.learning) {
          currentMoveIndex++;
          unawaited(advanceLearnPhase());
        } else {
          currentMoveIndex++;
          unawaited(advanceDrillPhase());
        }
      }),
    );
  }
}
