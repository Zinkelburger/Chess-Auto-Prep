import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../repertoires/controllers/repertoire_board_controller.dart';
import '../../../models/line_status.dart';
import '../../../models/repertoire_line.dart';
import '../../repertoires/models/repertoire_metadata.dart';
import '../../../models/repertoire_move_progress.dart';
import '../../../models/repertoire_review_entry.dart'
    show RepertoireReviewEntry, ReviewRating;
import '../../../models/completed_move.dart';
import '../models/training_settings.dart';
import '../models/training_source_context.dart';
import '../models/training_configuration.dart';
import '../../settings/models/settings_state.dart';
import '../../../utils/chess_utils.dart' show isNullMoveSan, playSanOrNullMove;
import '../../../utils/safe_change_notifier.dart';
import '../repositories/training_answers.dart';
import '../repositories/training_review_repository.dart';
import 'training_settings_controller.dart';
import '../models/chapter_layout.dart';
import 'drill_phase.dart';
import '../models/move_display.dart';
export '../models/move_display.dart' show MoveDisplayInfo;
import '../models/move_validation.dart' as validation;
import 'chapter_scope.dart';
import 'learn_phase.dart';
import 'replay_phase.dart';
import 'review_progress_store.dart';
import '../models/training_phase.dart';
import 'training_run.dart';
import '../repositories/training_source_repository.dart';
import '../models/training_window.dart';

/// Manages repertoire training session state: phases, line queue, move validation,
/// progress persistence, and session statistics.
class TrainingSessionController extends ChangeNotifier with SafeChangeNotifier {
  final TrainingHeaderRepository headers;
  final TrainingSourceRepository _loader;
  final TrainingSettingsController configuration;
  final TrainingReviewRepository reviewService;

  /// Remembers the ask-once prompts (currently "sort into chapters?") so a
  /// file is never asked twice.
  final TrainingAnswers askedQuestions;

  TrainingSessionController({
    required this.session,
    required this.headers,
    required TrainingSourceRepository source,
    required this.configuration,
    required this.reviewService,
    required this.askedQuestions,
  }) : _loader = source {
    session.addListener(_onSessionChanged);
    learn = LearnPhase(this);
    replay = ReplayPhase(this);
    drill = DrillPhase(this);
    configuration.addListener(_configurationChanged);
  }

  /// New-line walkthrough (acknowledge / quiz). The controller still exposes
  /// the same methods the trainer UI binds to; they delegate here.
  late final LearnPhase learn;

  /// Missed-move replay after a drill with mistakes.
  late final ReplayPhase replay;

  /// The quiz itself: opponent moves play, the user answers theirs.
  late final DrillPhase drill;

  final RepertoireBoardController session;

  // -- Data --
  RepertoireMetadata? repertoire;
  List<RepertoireLine> lines = [];

  /// Persisted review state: schedules, per-move streaks, history writes.
  /// Owns everything that outlives the session; this controller owns what the
  /// user is looking at right now.
  late final ReviewProgressStore progress = ReviewProgressStore(
    reviewService: reviewService,
    headers: headers,
    settings: () => settings,
    repertoireId: () => repertoireId,
    onError: _progressErrorHandler(),
  );

  void Function(Object) _progressErrorHandler() {
    final generation = _loadGeneration;
    return (failure) {
      if (_disposed ||
          generation != _loadGeneration ||
          isLoading ||
          progress.editBusy ||
          progress.requiresReload) {
        return;
      }
      _retryFailure = progress.flushHeaders;
      error = 'Could not mirror training progress: $failure';
      notifyListeners();
    };
  }

  bool get progressNeedsReload => progress.requiresReload;
  bool get _canEditProgress =>
      !_disposed && !isLoading && error == null && !progress.editsBlocked;

  Map<String, RepertoireReviewEntry> get reviewMap => progress.byLine;
  Map<String, RepertoireMoveProgress> get moveProgressMap =>
      progress.moveProgress;
  TrainingSettings _settings = TrainingSettings();
  TrainingSettings get settings => _settings.snapshot();
  @visibleForTesting
  set settings(TrainingSettings value) => _settings = value.snapshot();

  /// Every auto-next line in one sitting uses the same committed configuration.
  /// Successful panel edits are adopted while browsing or at the next sitting.
  void _adoptConfiguration() {
    final committed = configuration.state.committed;
    if (committed == null) return;
    final previous = _settings;
    _settings = committed.toSettings();
    if (previous.chapterGrouping != _settings.chapterGrouping ||
        previous.chapterDelimiter != _settings.chapterDelimiter) {
      chapterScope.onSettingsChanged();
    }
  }

  void _configurationChanged() {
    if (_disposed) return;
    if (currentLine == null) {
      _adoptConfiguration();
      dueQueue = _buildQueue();
    }
    notifyListeners();
  }

  bool get settingsApplyNextSitting => currentLine != null;

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

  String loadingStatus = 'Reading repertoire…';

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
    _cancelSourceWork();
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
    _disposed = true;
    configuration.removeListener(_configurationChanged);
    chapterScope.cancelPending();
    _loadGeneration++;
    _invalidateLine();
    learn.cancelPending();
    // Get the session's schedules into the PGN before the timer that would
    // have done it is cancelled.
    unawaited(progress.flushHeaders());
    progress.dispose();
    session.removeListener(_onSessionChanged);
    session.dispose();
    super.dispose();
  }

  bool _disposed = false;

  Future<void> loadSettings() async {
    try {
      await configuration.ensureLoaded();
      if (!_disposed) _configurationChanged();
    } catch (_) {
      // The shared owner retains the failed state and the panel offers retry.
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> Function()? _retryFailure;

  Future<void> retryFailure() async {
    if (completionBusy || progress.editBusy) return;
    if (progressNeedsReload || _retryFailure == null) {
      try {
        await progress.retryRetainedOutcomes();
      } catch (failure) {
        error = 'An earlier training result still needs recovery: $failure';
        notifyListeners();
        return;
      }
      await loadRepertoire();
      return;
    }
    final retry = _retryFailure;
    _retryFailure = null;
    error = null;
    notifyListeners();
    if (retry != null) {
      await retry();
    } else {
      await loadRepertoire();
    }
  }

  void _invalidateLine() {
    _lineGeneration++;
    progress.abandonOutcomeRetries();
  }

  void _cancelSourceWork() {
    lines = [];
    dueQueue = [];
    isLoading = true;
    _retryFailure = null;
    error = null;
    _adoptConfiguration();
    _loadGeneration++;
    _invalidateLine();
    learn.cancelPending();
    chapterScope.cancelPending();
    currentLine = null;
    waitingForUser = false;
    run.clear();
    runComplete = false;
  }

  void setRepertoire(RepertoireMetadata? value) {
    _cancelSourceWork();
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
    _cancelSourceWork();
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
    final generation = _loadGeneration;
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
    if (_disposed ||
        generation != _loadGeneration ||
        repertoire?.filePath != filePath) {
      return;
    }
    await loadRepertoire();
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

  /// [startChapter] scopes the browser to one of the file's course chapters
  /// as it opens — the chapter the user tapped in the picker.
  Future<void> loadRepertoire({
    String? startLineId,
    String? startChapter,
  }) async {
    final source = repertoire;
    if (source == null) return;
    if (configuration.state.phase == SettingsPhase.failed &&
        configuration.state.committed == null) {
      final generation = _loadGeneration;
      isLoading = false;
      error = 'Training settings could not be loaded.';
      _retryFailure = () async {
        try {
          await configuration.retry();
        } catch (_) {
          /* Shared state retains the failure. */
        }
        if (_disposed || generation != _loadGeneration) return;
        await loadRepertoire(
          startLineId: startLineId,
          startChapter: startChapter,
        );
      };
      notifyListeners();
      return;
    }

    // Capture the token and the source flag up front: `sourceIsStudy` is a
    // shared mutable field a concurrent handoff can flip while we await, so
    // this load must decide "study or repertoire" from its own snapshot.
    final generation = ++_loadGeneration;
    bool stale() => generation != _loadGeneration;
    _invalidateLine();
    learn.cancelPending();
    currentLine = null;
    waitingForUser = false;
    run.clear();
    final loadIsStudy = sourceIsStudy;
    isLoading = true;
    loadingStatus = 'Reading repertoire…';
    playabilityMap = {};
    error = null;
    feedback = null;
    notifyListeners();

    try {
      await progress.prepareSourceLoad();
      if (stale()) return;
      final filePath = source.filePath;
      // A hand-set colour beats everything: it exists precisely because the
      // file and the inference between them got it wrong.
      final loadedColor = loadIsStudy
          ? null
          : await askedQuestions.boolAnswerFor(
              AskedQuestion.trainingColor,
              subject: filePath,
            );
      if (stale()) return;
      colorOverrideIsWhite = loadedColor;
      final loaded = await _loader.load(
        source,
        isStudy: loadIsStudy,
        colorOverrideIsWhite: colorOverrideIsWhite,
        isStale: stale,
        onStatus: (status) {
          if (stale()) return;
          loadingStatus = status;
          notifyListeners();
        },
      );
      if (stale() || loaded == null) return;
      if (loaded.lines.isEmpty) {
        error = loadIsStudy
            ? 'No chapters with moves to train.'
            : 'No trainable lines found.';
        return;
      }
      lines = loaded.lines;
      session.setPositionFromFen(loaded.lines.first.startPosition.fen);
      progress.onError = _progressErrorHandler();
      progress.adopt(
        sources: loaded.sources,
        byLine: loaded.reviewByLine,
        moveProgress: loaded.moveProgress,
        otherRepertoires: loaded.otherRepertoires,
      );
      // Difficulty is optional builder metadata. Only the difficulty sort
      // needs it before the first queue can be displayed.
      final wantsTree = !loadIsStudy && !loaded.isFolder;
      if (wantsTree && settings.reviewOrder == ReviewOrder.hardestFirst) {
        loadingStatus = 'Preparing difficulty order…';
        notifyListeners();
        await _loadPlayability(filePath, loaded.lines, generation);
        if (stale()) return;
      }

      _linearDone.clear();
      await chapterScope.resolveLayout(filePath, isStudy: loadIsStudy);
      if (stale()) return;
      if (startChapter != null && !loadIsStudy) {
        await chapterScope.adoptChapter(startChapter, filePath: filePath);
        if (stale()) return;
      }
      dueQueue = _buildQueue();
      notifyListeners();
      if (wantsTree && settings.reviewOrder != ReviewOrder.hardestFirst) {
        unawaited(_loadPlayability(filePath, loaded.lines, generation));
      }

      isLoading = false;
      // Land on the line browser; only jump straight into a line when the
      // caller asked for one (e.g. "Train this line" from the Builder).
      if (startLineId != null) {
        pickStartingLine(startLineId: startLineId);
      }
    } catch (e) {
      if (stale()) return;
      error = 'Error loading repertoire: $e';
      notifyListeners();
    } finally {
      // Only the current load owns the loading flag; a superseded one must
      // leave it set so the winning load's spinner stays up.
      if (!stale()) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Reads the generated tree's playability for [lines] and, when this
  /// load is still current, re-sorts a queue nobody has started yet.
  Future<void> _loadPlayability(
    String filePath,
    List<RepertoireLine> lines,
    int generation,
  ) async {
    bool stale() => generation != _loadGeneration;
    final scores = await _loader.playabilityFromTree(
      filePath,
      lines,
      isStale: stale,
    );
    if (stale()) return;
    playabilityMap = scores;
    if (!isLoading && currentLine == null) dueQueue = _buildQueue();
    notifyListeners();
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
    saveSettings: (before, after) async {
      await configuration.edit(
        TrainingConfiguration(after).changesFrom(TrainingConfiguration(before)),
      );
    },
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
    if (!_canEditProgress || _uncommittedResult) return;
    _adoptConfiguration();
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
  int get remainingInRun => runComplete
      ? 0
      : (_remainingInRun ??= run.remaining(dueQueue, sessionIntent));

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
    if (!_canEditProgress ||
        _uncommittedResult ||
        line == null ||
        !lines.any((current) => identical(current, line)) ||
        (reviewMap[line.id]?.excluded ?? false)) {
      return;
    }
    if (!keepRunScope) {
      _adoptConfiguration();
      run.clear();
    }
    sessionIntent =
        intent ??
        (_isLineNew(line) ? TrainingIntent.learn : TrainingIntent.review);
    runComplete = false;
    learn.cancelPending();

    resetBoard(line);

    final window = resolveTrainingWindow(
      line,
      settings: settings,
      mode: trainingMode,
    );

    // Tactics mode always quizzes cold — the learn walkthrough would show
    // the puzzle's solution.
    final isNew = trainingMode == TrainingMode.repertoire && _isLineNew(line);

    _invalidateLine();
    _clearPresentation();
    currentLine = line;
    currentLineLength = window.length;
    currentMoveIndex = 0;
    phase = isNew ? TrainingPhase.learning : TrainingPhase.drilling;
    _hadLearnPhaseThisSession = isNew;
    lineHadMistake = false;
    wrongMoveIndices = [];
    replayIndex = 0;
    trainingStartIndex = window.startIndex;
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

  /// Forget everything the card was showing: prompts, feedback, the move
  /// pair and every "waiting for the user" gate.
  void _clearPresentation() {
    waitingForUser = false;
    feedback = null;
    currentAnnotation = null;
    currentPairOpponent = null;
    currentPairUser = null;
    learnWaitingForAck = false;
    learnQuizzing = false;
    opponentWaitingForAck = false;
    playingIntro = false;
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

  /// Skip for this sitting without changing the saved schedule.
  void skipLine() {
    if (!canAdvance) return;
    run.skip(currentLine!.id);
    learn.cancelPending();
    rebuildQueueAndAdvance();
  }

  Future<void> setLineExcluded(RepertoireLine line, bool excluded) async {
    if (!_canEditProgress ||
        _uncommittedResult ||
        !lines.any((current) => identical(current, line))) {
      return;
    }
    final generation = _loadGeneration;
    if (excluded && currentLine?.id == line.id) learn.cancelPending();
    try {
      await progress.setExcluded(line, excluded);
      if (_disposed || generation != _loadGeneration) return;
      if (excluded && currentLine?.id == line.id) {
        rebuildQueueAndAdvance();
      } else {
        dueQueue = _buildQueue();
        notifyListeners();
      }
    } catch (failure) {
      _progressEditFailed(failure, generation);
    }
  }

  void _progressEditFailed(Object failure, int generation) {
    if (_disposed || generation != _loadGeneration) return;
    _retryFailure = null;
    error = 'Could not save training progress: $failure';
    notifyListeners();
  }

  /// Restart the current line from the beginning (learn phase again if the
  /// line is still new).
  void restartLine() {
    if (!canAdvance) return;
    startLine(currentLine, intent: sessionIntent, keepRunScope: true);
  }

  /// Leave the active line and return to the line browser. Nothing is rated
  /// or persisted; the queue is refreshed.
  void stopSession() {
    learn.cancelPending();
    // Leaving the line is the natural moment to pay off the batched PGN
    // writes: the user has stopped answering, so the pause costs nothing.
    unawaited(progress.flushHeaders());
    _invalidateLine();
    runComplete = false;
    run.clear();
    currentLine = null;
    _adoptConfiguration();
    phase = TrainingPhase.drilling;
    _clearPresentation();
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

  Future<void> advanceDrillPhase() => drill.advance();

  /// The user played [move]. Records the attempt, then hands the answer to
  /// whichever phase is asking: the learn quiz, the replay, or the drill.
  Future<void> handleUserMove(CompletedMove move) async {
    if (!_canEditProgress) return;
    if (!waitingForUser || currentLine == null) return;

    final attemptLine = currentLine!;
    final attemptGeneration = _lineGeneration;
    final attemptIndex = phase == TrainingPhase.replaying
        ? wrongMoveIndices[replayIndex]
        : currentMoveIndex;
    final expected = attemptLine.moves[attemptIndex];
    waitingForUser = false;
    try {
      await reviewService.recordAttempt(
        source: progress.sourceFor(attemptLine.sourcePath ?? repertoireId),
        repertoireId: attemptLine.sourcePath ?? repertoireId,
        lineId: attemptLine.persistedId,
        moveIndex: attemptIndex,
        fen: session.fen,
        playedSan: move.san,
        expectedSan: expected,
        correct: validation.isCorrectUserMove(session.position, move, expected),
        phase: phase.name,
      );
    } catch (e) {
      if (attemptGeneration != _lineGeneration) return;
      if (e is TrainingSourceChanged) progress.requireSourceReload();
      error = 'Could not save this attempt: $e';
      waitingForUser = true;
      notifyListeners();
      return;
    }
    if (attemptGeneration != _lineGeneration) return;
    waitingForUser = true;

    if (phase == TrainingPhase.learning && learnQuizzing) {
      await handleLearnQuizMove(move);
    } else if (phase == TrainingPhase.replaying) {
      await handleReplayMove(move);
    } else {
      await drill.handleMove(move);
    }
  }

  /// Finishing, persisting and advancing are one session-owned transition.
  /// A mounted results widget is never required to commit an automatic result.
  void _finishLine() {
    if (!_canEditProgress ||
        currentLine == null ||
        runComplete ||
        _completionGeneration == _lineGeneration) {
      return;
    }
    phase = TrainingPhase.finished;
    waitingForUser = false;
    currentAnnotation = null;
    if (repetitionMode == RepetitionMode.linear) {
      final clean = !lineHadMistake;
      feedback = trainingMode == TrainingMode.tactics
          ? (clean ? 'Puzzle solved!' : 'Solved — with mistakes.')
          : (clean ? 'Line complete!' : 'Line complete — with mistakes.');
      unawaited(_commitCompletion(null));
    } else if (!settings.showRatingButtons || hadLearnPhaseThisSession) {
      unawaited(
        _commitCompletion(
          lineHadMistake ? ReviewRating.again : ReviewRating.good,
        ),
      );
    } else {
      feedback = 'Line complete — rate your recall.';
    }
    notifyListeners();
  }

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

  int? _completionGeneration;
  int? _savingGeneration;
  int? _completedGeneration;
  bool get completionBusy => _savingGeneration == _lineGeneration;
  bool get completionCommitted => _completedGeneration == _lineGeneration;
  bool get _uncommittedResult =>
      currentLine != null &&
      !runComplete &&
      phase == TrainingPhase.finished &&
      !completionCommitted;
  bool get canAdvance =>
      _canEditProgress &&
      !completionBusy &&
      !runComplete &&
      currentLine != null &&
      (phase != TrainingPhase.finished || completionCommitted);

  bool get canRate =>
      _canEditProgress &&
      !runComplete &&
      currentLine != null &&
      phase == TrainingPhase.finished &&
      repetitionMode == RepetitionMode.spaced &&
      _completionGeneration != _lineGeneration &&
      error == null;

  double previewRatingInterval(ReviewRating rating) =>
      reviewService.previewInterval(
        reviewMap[currentLine?.id] ??
            RepertoireReviewEntry(
              repertoireId: repertoireId,
              lineId: currentLine?.id ?? '',
              lineName: currentLine?.name ?? '',
            ),
        rating,
      );

  Future<void> rateLine(ReviewRating rating) async {
    if (phase != TrainingPhase.finished ||
        (repetitionMode == RepetitionMode.spaced && !canRate)) {
      return;
    }
    if (repetitionMode == RepetitionMode.linear && completionCommitted) {
      nextLine();
      return;
    }
    await _commitCompletion(
      repetitionMode == RepetitionMode.linear ? null : rating,
    );
  }

  Future<void> _commitCompletion(ReviewRating? rating) async {
    final line = currentLine;
    if (!_canEditProgress ||
        line == null ||
        runComplete ||
        _completionGeneration == _lineGeneration) {
      return;
    }
    final generation = _lineGeneration;
    final sourceGeneration = _loadGeneration;
    _completionGeneration = generation;
    final attempt = Object();
    final hadMistake = lineHadMistake;
    final autoNext = settings.autoNext;
    // Retain the same decision through a partial-write retry. The progress
    // store already owns captured source bytes and resumable persistence stages.
    Future<void> persist() async {
      if (_disposed ||
          generation != _lineGeneration ||
          completionBusy ||
          completionCommitted) {
        return;
      }
      _savingGeneration = generation;
      notifyListeners();
      try {
        if (rating == null) {
          await progress.recordCompletion(
            line,
            attempt: attempt,
            hadMistake: hadMistake,
          );
        } else {
          await progress.recordRating(
            line,
            rating,
            attempt: attempt,
            hadMistake: hadMistake,
          );
        }
      } catch (failure) {
        if (progressNeedsReload) {
          _progressEditFailed(failure, sourceGeneration);
        } else if (!_disposed && generation == _lineGeneration) {
          _retryFailure = persist;
          error =
              'Could not save ${rating == null ? 'completion' : 'rating'}: $failure';
        }
        return;
      } finally {
        if (_savingGeneration == generation) _savingGeneration = null;
        if (!_disposed && generation == _lineGeneration) notifyListeners();
      }
      if (_disposed || generation != _lineGeneration) return;
      _completedGeneration = generation;
      if (rating == null) {
        _linearDone.add(line.id);
      } else {
        run.skip(line.id);
      }
      _tallySessionResult(hadMistake: hadMistake);
      if (autoNext) {
        rebuildQueueAndAdvance();
      } else {
        dueQueue = _buildQueue();
        notifyListeners();
      }
    }

    await persist();
  }

  /// Advance to the next line of the current run (Learn or Review), or finish
  /// the session when the scope is exhausted.
  void rebuildQueueAndAdvance() {
    if (!canAdvance) return;
    dueQueue = _buildQueue();

    final next = run.next(
      dueQueue,
      sessionIntent,
      afterLineId: currentLine?.id,
    );
    if (next == null) {
      _invalidateLine();
      waitingForUser = false;
      playingIntro = false;
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
  }) async {
    if (!_canEditProgress || currentLine != null) {
      throw StateError('Training progress is unavailable for bulk editing');
    }
    final generation = _loadGeneration;
    try {
      final changed = await progress.applyLearnedSelection(
        lines,
        checkedLineIds,
        within: within,
      );
      if (!_disposed && generation == _loadGeneration) {
        dueQueue = _buildQueue();
        notifyListeners();
      }
      return changed;
    } catch (failure) {
      _progressEditFailed(failure, generation);
      rethrow;
    }
  }

  void updateMoveProgress(
    RepertoireLine line,
    int moveIndex, {
    required bool wasCorrect,
  }) {
    if (_canEditProgress && lines.any((current) => identical(current, line))) {
      progress.recordMove(line, moveIndex, wasCorrect: wasCorrect);
    }
  }

  double moveDifficulty(RepertoireLine line, int moveIndex) =>
      progress.moveDifficulty(line, moveIndex);

  // ---------------------------------------------------------------------------
  // ACKNOWLEDGEMENTS
  // ---------------------------------------------------------------------------

  void opponentAcknowledged() {
    // A second Next (double-click, or Space landing after the click) must
    // not step the cursor past the move that was waiting.
    if (!opponentWaitingForAck) return;
    opponentWaitingForAck = false;
    currentAnnotation = null;
    notifyListeners();
    unawaited(
      Future.microtask(() {
        currentMoveIndex++;
        unawaited(
          phase == TrainingPhase.learning
              ? advanceLearnPhase()
              : advanceDrillPhase(),
        );
      }),
    );
  }
}
