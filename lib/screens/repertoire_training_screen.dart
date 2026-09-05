/// Repertoire Trainer - Chessable-style line drilling with spaced repetition,
/// plus a tactics mode for training studies of custom puzzles.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../features/repertoire/widgets/repertoire_toolbar.dart'
    show RepertoireSwitcherTitle;
import '../models/line_status.dart';
import '../models/repertoire_line.dart';
import '../models/repertoire_metadata.dart';
import '../models/training_settings.dart';
import '../services/training/training_phase.dart';
import '../services/training/training_session_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_shortcuts.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/app_breadcrumb_trail.dart';
import '../widgets/app_mode_switcher.dart';
import '../widgets/app_overflow_menu.dart';
import '../widgets/app_settings_button.dart';
import '../widgets/pgn_viewer_widget.dart';
import '../widgets/trainer_keyboard_scope.dart';
import '../widgets/training/chapter_reader_screen.dart';
import '../widgets/training/chapter_setup_dialog.dart';
import '../widgets/training/line_preview_dialog.dart';
import '../widgets/training/move_input_widget.dart';
import '../widgets/repertoire_list_body.dart';
import '../widgets/training/repertoire_selector_panel.dart';
import '../widgets/training/trainer_browser.dart';
import '../widgets/training/training_board_controls.dart';
import '../widgets/training/training_progress_panel.dart';
import '../widgets/training/training_results_panel.dart';
import '../widgets/training/training_settings_panel.dart';
import '../widgets/training/training_side_dialog.dart';
import 'repertoire_selection_screen.dart';

// ---------------------------------------------------------------------------
// TRAINING SCREEN
// ---------------------------------------------------------------------------

class RepertoireTrainingScreen extends StatefulWidget {
  final RepertoireMetadata? repertoire;
  final String? startLineId;

  const RepertoireTrainingScreen({
    super.key,
    this.repertoire,
    this.startLineId,
  });

  @override
  State<RepertoireTrainingScreen> createState() =>
      _RepertoireTrainingScreenState();
}

class _RepertoireTrainingScreenState extends State<RepertoireTrainingScreen>
    with TickerProviderStateMixin {
  late final TrainingSessionController _training;
  late TabController _tabController;

  final PgnViewerWidgetController _pgnController = PgnViewerWidgetController();
  final TextEditingController _repetitionsController = TextEditingController();
  final TextEditingController _depthController = TextEditingController();
  final TextEditingController _delayController = TextEditingController();
  final GlobalKey<MoveInputWidgetState> _moveInputKey = GlobalKey();
  bool _settingsInitialized = false;

  /// Line id whose PGN the user chose to peek at mid-training. Reset on every
  /// new line so spoilers never leak across lines.
  String? _pgnRevealedLineId;

  /// True while the "sort into chapters?" dialog is on screen, so a stream of
  /// controller notifications can't stack a second copy behind it.
  bool _chapterPromptOpen = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _training = TrainingSessionController();
    _training.onLineStarted = () {
      _pgnRevealedLineId = null;
      if (mounted) _tabController.animateTo(0);
    };
    _training.addListener(_onTrainingChanged);
    _training.setRepertoire(widget.repertoire);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initialize());
    });
  }

  AppState? _appStateRef;

  @override
  void dispose() {
    _appStateRef?.removeListener(_onAppStateChanged);
    _training.removeListener(_onTrainingChanged);
    _training.dispose();
    _tabController.dispose();
    _repetitionsController.dispose();
    _depthController.dispose();
    _delayController.dispose();
    super.dispose();
  }

  void _onTrainingChanged() {
    if (!mounted) return;
    setState(() {});
    _maybeShowChapterPrompt();
  }

  /// The file looks chapter-organised and the user hasn't answered for it —
  /// ask once, after the current frame (the notification can land mid-build).
  void _maybeShowChapterPrompt() {
    if (_training.pendingChapterPrompt == null || _chapterPromptOpen) return;
    _chapterPromptOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _showChapterPrompt());
  }

  Future<void> _showChapterPrompt() async {
    final proposal = _training.pendingChapterPrompt;
    if (!mounted || proposal == null) {
      _chapterPromptOpen = false;
      return;
    }
    final answer = await showChapterSetupDialog(
      context,
      proposal: proposal,
      chaptersCurrentlyOn:
          !_training.chaptersDeclined && _training.chapters.isNotEmpty,
    );
    _chapterPromptOpen = false;
    if (!mounted) return;
    if (answer == null) {
      // Dismissed without choosing: drop the prompt for this session but
      // don't record an answer, so the next load asks again.
      _training.dismissChapterPrompt();
      return;
    }
    await _training.answerChapterPrompt(answer);
  }

  Future<void> _initialize() async {
    await _training.loadSettings();
    if (!mounted) return;

    // The screen is cached in main_screen's IndexedStack, so later
    // builder/study → trainer handoffs arrive as AppState notifications,
    // not a fresh initState.
    final appState = context.read<AppState>();
    _appStateRef = appState;
    appState.addListener(_onAppStateChanged);

    if (_consumePendingSource(appState)) return;
    if (_training.repertoire != null) {
      await _training.loadRepertoire(startLineId: widget.startLineId);
    } else {
      _training.setIdle();
    }
  }

  void _onAppStateChanged() {
    final appState = _appStateRef;
    if (appState == null || !mounted) return;
    if (appState.currentMode != AppMode.repertoireTrainer) return;
    _consumePendingSource(appState);
  }

  /// Consume a pending repertoire or study handoff.  Returns true when a
  /// source was consumed and its load started.
  bool _consumePendingSource(AppState appState) {
    final handoff = appState.takeHandoff<TrainerHandoff>();
    if (handoff == null) return false;

    final metadata = RepertoireMetadata(
      filePath: handoff.sourcePath,
      name: p.basenameWithoutExtension(handoff.sourcePath),
      lastModified: DateTime.now(),
    );
    if (handoff.isStudy) {
      _training.setStudySource(metadata);
    } else {
      _training.setRepertoire(metadata);
    }
    unawaited(_training.loadRepertoire(startLineId: handoff.lineId));
    return true;
  }

  Future<void> _selectRepertoire() async {
    final result = await Navigator.of(context).push<RepertoireMetadata>(
      MaterialPageRoute(builder: (_) => const RepertoireSelectionScreen()),
    );
    if (result != null) {
      _training.setRepertoire(result);
      await _training.loadRepertoire();
    }
  }

  void _openInBuilder() {
    if (_training.repertoire == null) return;
    context.read<AppState>().switchToBuilder(
      repertoirePath: _training.repertoire!.filePath,
      lineId: _training.currentLine?.id,
    );
  }

  void _openInStudy() {
    if (_training.repertoire == null) return;
    context.read<AppState>().switchToStudyEdit(
      path: _training.repertoire!.filePath,
    );
  }

  /// Hand the exact board position over to the Builder (engine, explorer,
  /// editing). The Builder's Train button brings the loop back here.
  void _explorePosition() {
    if (_training.repertoire == null) return;
    context.read<AppState>().switchToBuilder(
      repertoirePath: _training.repertoire!.filePath,
      moveSequence: List.of(_training.session.currentMoveSequence),
    );
  }

  Future<void> _copyFen() async {
    await Clipboard.setData(ClipboardData(text: _training.session.fen));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('FEN copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Ancestor-only key handling (holdsFocus defaults to false): the scope must
    // not take primary focus, or it swallows typed moves (e.g. "e6") instead of
    // letting the move-input field receive them. Space still bubbles up to
    // _onKeyEvent to advance the Learn step.
    return TrainerKeyboardScope(
      onKeyEvent: _onKeyEvent,
      child: Scaffold(appBar: _buildAppBar(), body: _buildBody()),
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Space advances the Learn "Next" step. It's checked before the text-input
    // guard because space is never a valid move character (the move input
    // filters it out) and the disabled move-input field can retain focus. The
    // "Next" button also self-focuses (see _NextButton.autofocus), so this is a
    // secondary path — whichever the focused node is, space advances.
    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (_training.learnWaitingForAck) {
        _training.learnAcknowledged();
        return KeyEventResult.handled;
      }
      if (_training.opponentWaitingForAck) {
        _training.opponentAcknowledged();
        return KeyEventResult.handled;
      }
    }

    return handleKeyBindings(_keyBindings, event, node: node);
  }

  /// Trainer shortcuts, dispatched through [handleKeyBindings] (never while
  /// typing a move).
  List<KeyBinding> get _keyBindings => [
    ...KeyBinding.forShortcut(
      AppShortcut.focusMoveInput,
      'Focus move input',
      () => _moveInputKey.currentState?.focus(),
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.autoAdvance,
      'Toggle manual advance',
      () {
        final settings = _training.settings;
        settings.learnRequiresClick = !settings.learnRequiresClick;
        settings.saveSoon();
        setState(() {});
      },
    ),
    // The queue here is the lines being drilled, so "skip to the next one"
    // is the app-wide next-item pair rather than a screen-local S.
    ...KeyBinding.forShortcutIf(AppShortcut.nextItem, 'Skip to next line', () {
      if (_training.currentLine == null) return false;
      _training.skipLine();
      return true;
    }),
    ...KeyBinding.forShortcutIf(AppShortcut.restartLine, 'Restart line', () {
      if (_training.currentLine == null) return false;
      _training.restartLine();
      return true;
    }),
    // The app-wide Escape contract: leave what you are in. Here that is the
    // line being drilled — back to the browser, same as "Back to list".
    ...KeyBinding.forShortcutIf(AppShortcut.leave, 'Leave this line', () {
      if (_training.currentLine == null) return false;
      _training.stopSession();
      return true;
    }),
  ];

  PreferredSizeWidget _buildAppBar() {
    final theme = Theme.of(context);
    final repertoire = _training.repertoire;
    return AppBar(
      titleSpacing: 16,
      // The title *is* the repertoire picker, as in the Builder: what is
      // loaded reads as `Repertoire › Chapter ▾`, and tapping it swaps it. A
      // bare chapter name here ("Main") said nothing about which repertoire it
      // came from or that it could be changed.
      title: AppBarTitleWithTrail(
        title: RepertoireSwitcherTitle(
          title: repertoire == null
              ? Text('Select repertoire', style: theme.textTheme.titleMedium)
              : _repertoireCrumb(theme),
          onTap: _selectRepertoire,
        ),
      ),
      actions: [
        // Reload and the two hand-offs are occasional and sit in the overflow.
        const AppModeSwitcher(),
        AppOverflowMenu(
          entries: [
            if (repertoire != null)
              AppMenuEntry(
                label: 'Reload from disk',
                icon: Icons.refresh,
                onRun: () => unawaited(_training.loadRepertoire()),
              ),
            if (repertoire != null && _training.sourceIsStudy)
              AppMenuEntry(
                label: 'Edit study…',
                icon: Icons.menu_book_outlined,
                onRun: _openInStudy,
              )
            else if (repertoire != null)
              AppMenuEntry(
                label: 'Open in Builder',
                icon: Icons.construction,
                onRun: _openInBuilder,
              ),
            AppMenuEntry(
              label: 'App settings…',
              icon: Icons.settings,
              dividerAbove: true,
              onRun: () => openAppSettings(context),
            ),
          ],
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  /// Folder the loaded chapter belongs to, or null for a study (which is one
  /// file, so its parent directory names nothing the user chose).
  String? _repertoireFolder() {
    final repertoire = _training.repertoire;
    if (repertoire == null || _training.sourceIsStudy) return null;
    return p.basename(p.dirname(repertoire.filePath));
  }

  /// `Black Repertoire › Main` as one string, for headings that take text.
  String _repertoireTitle() {
    final name = _training.repertoire?.name ?? 'Repertoire';
    final folder = _repertoireFolder();
    return folder == null ? name : '$folder › $name';
  }

  /// The app bar's `Repertoire › Chapter` crumb: folder plain, chapter bold,
  /// the same weighting the Builder's breadcrumb uses.
  Widget _repertoireCrumb(ThemeData theme) {
    final name = _training.repertoire!.name;
    final folder = _repertoireFolder();
    final chapterStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    if (folder == null) {
      return Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: chapterStyle,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            folder,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
        ),
        const Icon(
          Icons.chevron_right,
          size: 18,
          color: AppColors.onSurfaceMuted,
        ),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: chapterStyle,
          ),
        ),
      ],
    );
  }

  void _onRepertoireSelected(RepertoireMetadata repertoire) {
    _training.setRepertoire(repertoire);
    unawaited(_training.loadRepertoire());
  }

  void _onStudySelected(RepertoireMetadata study) {
    _training.setStudySource(study);
    unawaited(_training.loadRepertoire());
  }

  /// Board on the left, panel on the right — the same frame in every state,
  /// so picking a repertoire, browsing chapters and drilling a line all look
  /// like the rest of the app instead of the board appearing out of nowhere
  /// once training starts.
  Widget _buildBody() {
    final training = _training.currentLine != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 1100;
        final board = training ? _buildBoardPane() : _buildIdleBoardPane();
        final panel = _buildPanel();
        if (isCompact) {
          return Column(
            children: [
              Expanded(flex: 4, child: board),
              const Divider(height: 1, thickness: 1),
              Expanded(flex: 6, child: panel),
            ],
          );
        }
        return Row(
          children: [
            Expanded(flex: 5, child: board),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(flex: 5, child: panel),
          ],
        );
      },
    );
  }

  /// What sits beside the board: the repertoire list, a load state, the
  /// chapter/line browser, or the training tabs.
  Widget _buildPanel() {
    if (_training.repertoire == null && !_training.isLoading) {
      return RepertoireListBody(
        onSelected: _onRepertoireSelected,
        onStudySelected: _onStudySelected,
      );
    }

    if (_training.isLoading ||
        _training.error != null ||
        _training.lines.isEmpty) {
      return RepertoireSelectorPanel(
        isLoading: _training.isLoading,
        error: _training.error,
        hasLines: _training.lines.isNotEmpty,
        canStartTraining: false,
        onSelectRepertoire: _selectRepertoire,
      );
    }

    // Chessable-style chapter home: browse every line, pick what to train.
    if (_training.currentLine == null) return _buildBrowser(dense: false);

    return _buildSidePane();
  }

  /// One browser used twice: beside the idle board while nothing is being
  /// trained, and dense inside the Lines tab once a line is running.
  Widget _buildBrowser({required bool dense}) {
    return TrainerBrowser(
      title: _repertoireTitle(),
      subtitle: _browserSubtitle(),
      lines: _training.lines,
      reviewMap: _training.reviewMap,
      chapterOf: _training.chapterOf,
      activeChapter: _training.activeChapter,
      onChapterSelected: _training.setActiveChapter,
      ungroupedChapter: TrainingSessionController.ungroupedChapter,
      onLearn: _training.startLearnSession,
      onReview: _training.startReviewSession,
      learnBatchSize: _sessionCap(_training.settings.newLinesPerSession),
      reviewBatchSize: _sessionCap(_training.settings.reviewsPerSession),
      onTrainLine: (line) => _training.startLine(line),
      onPreviewLine: _previewLine,
      onReadLines: _readLines,
      onApplyLearnedSelection: _applyLearnedSelection,
      // Only offered when the file actually has a layout to propose, and
      // never in the cramped side panel.
      onOpenChapterSetup: dense || !_training.canOfferChapters
          ? null
          : _training.reopenChapterPrompt,
      // A study's solver is per chapter, so there is no one side to set.
      playingWhite: _training.sourceIsStudy ? null : !_training.sourceIsBlack,
      onChangePlayingSide: _training.sourceIsStudy ? null : _chooseTrainingSide,
      onOpenSettings: dense ? null : _openSettingsDialog,
      introEnabled: _training.settings.skipToFirstComment,
      dense: dense,
    );
  }

  /// Lines one press of Learn/Review covers. Linear mode runs the whole set
  /// by definition, so it never advertises a batch.
  int _sessionCap(int setting) =>
      _training.repetitionMode == RepetitionMode.linear ? 0 : setting;

  /// "930 lines · spaced repetition" — what the two buttons will actually do.
  /// The side is deliberately *not* here: it has its own header control, and
  /// repeating it as grey text made it read as a label rather than a setting.
  String _browserSubtitle() {
    final parts = <String>[
      if (_training.sourceIsStudy) 'Study',
      _training.repetitionMode == RepetitionMode.linear
          ? 'every line once'
          : 'spaced repetition',
    ];
    return parts.join(' · ');
  }

  /// Ask which side this file trains, and reload with the answer.
  Future<void> _chooseTrainingSide() async {
    final choice = await showTrainingSideDialog(
      context,
      currentIsWhite: !_training.sourceIsBlack,
      overridden: _training.colorOverrideIsWhite != null,
    );
    if (choice == null) return;
    await _training.setTrainingColor(switch (choice) {
      TrainingSideChoice.white => true,
      TrainingSideChoice.black => false,
      TrainingSideChoice.fromFile => null,
    });
  }

  /// Trainer settings as a dialog — the landing page has no tab bar, and
  /// knobs belong behind one labelled entry point either way.
  Future<void> _openSettingsDialog() async {
    await showDialog<void>(
      context: context,
      // StatefulBuilder: the panel's switches and segmented buttons have to
      // repaint inside the dialog, which the screen's setState can't reach.
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620, maxHeight: 700),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Training settings',
                          style: Theme.of(dialogContext).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _buildSettingsTab(
                    onChanged: () {
                      setDialogState(() {});
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _buildBoardPane() {
    return TrainingBoardPane(
      session: _training.session,
      boardFlipped: _training.boardFlipped,
      waitingForUser: _training.waitingForUser,
      onMove: _training.handleUserMove,
      moveInputKey: _moveInputKey,
      // Non-move keys (S skip, J manual-advance, …) keep working as
      // shortcuts while a move is being typed; R stays typeable ("Rd1").
      onNavigationKey: (event) =>
          handleMoveInputNavigationKey(_keyBindings, event),
    );
  }

  /// The board while nothing is being trained: same size and place as the
  /// training board, but nothing to play or type into. Oriented to the colour
  /// the loaded source trains, so it already shows the side you'll be on.
  Widget _buildIdleBoardPane() {
    return TrainingBoardPane(
      session: _training.session,
      boardFlipped: _training.sourceIsBlack,
      waitingForUser: false,
      showMoveInput: false,
    );
  }

  Widget _buildSidePane() {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Train', icon: Icon(Icons.school, size: 16)),
            Tab(text: 'Lines', icon: Icon(Icons.account_tree, size: 16)),
            Tab(text: 'PGN', icon: Icon(Icons.description, size: 16)),
            Tab(text: 'Settings', icon: Icon(Icons.settings, size: 16)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildTrainTab(),
              _buildLinesTab(),
              _buildPgnTab(),
              _buildSettingsTab(),
            ],
          ),
        ),
      ],
    );
  }

  /// Only built while a line is running ([_buildPanel] shows the browser
  /// otherwise), so the line is never null here.
  Widget _buildTrainTab() {
    final line = _training.currentLine!;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TextButton.icon(
                onPressed: _training.stopSession,
                icon: const Icon(Icons.arrow_back, size: 16),
                // Name the chapter you would be going back to; "Chapter"
                // told you nothing about which one.
                label: Text(
                  _chapterTitle(_training.activeChapter),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: AppColors.onSurfaceSoft,
                ),
              ),
              const Spacer(),
              _trainTabIconButton(
                icon: Icons.travel_explore,
                tooltip:
                    'Explore this position in Builder\n'
                    '(engine, explorer, add moves)',
                onPressed: _explorePosition,
              ),
              _trainTabIconButton(
                icon: Icons.content_copy,
                tooltip: 'Copy FEN',
                onPressed: _copyFen,
              ),
              _trainTabIconButton(
                icon: Icons.replay,
                tooltip: 'Restart line',
                onPressed: _training.restartLine,
              ),
              _trainTabIconButton(
                icon: Icons.skip_next,
                tooltip: 'Skip to next line',
                onPressed: _training.skipLine,
              ),
            ],
          ),
          // Chapter *and* variation, over as many lines as it takes: while
          // drilling there is no list around the line to say which chapter
          // it came from, and course titles are long.
          Text(
            line.qualifiedName,
            style: Theme.of(context).textTheme.titleSmall,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            _training.sessionIntent == TrainingIntent.learn
                ? 'Learning'
                : 'Reviewing',
            style: AppTextStyles.caption,
          ),
          const Divider(height: 16),
          Expanded(
            child: _training.runComplete
                ? _buildRunCompletePanel()
                : _training.phase == TrainingPhase.finished
                ? TrainingResultsPanel(
                    phase: _training.phase,
                    currentLine: _training.currentLine,
                    dueQueue: _training.dueQueue,
                    reviewMap: _training.reviewMap,
                    repertoireId: _training.repertoireId,
                    lineHadMistake: _training.lineHadMistake,
                    hadLearnPhaseThisSession:
                        _training.hadLearnPhaseThisSession == true,
                    repetitionMode: _training.repetitionMode,
                    trainingMode: _training.trainingMode,
                    settings: _training.settings,
                    sessionCorrect: _training.sessionCorrect,
                    sessionIncorrect: _training.sessionIncorrect,
                    sessionStreak: _training.sessionStreak,
                    reviewService: _training.reviewService,
                    onRateLine: _training.rateLine,
                    onNextLine: _training.nextLine,
                  )
                : TrainingPhasePanel(
                    phase: _training.phase,
                    feedback: _training.feedback,
                    currentAnnotation: _training.currentAnnotation,
                    learnQuizzing: _training.learnQuizzing,
                    learnWaitingForAck: _training.learnWaitingForAck,
                    opponentWaitingForAck: _training.opponentWaitingForAck,
                    currentPairOpponent: _training.currentPairOpponent,
                    currentPairUser: _training.currentPairUser,
                    replayIndex: _training.replayIndex,
                    wrongMoveCount: _training.wrongMoveIndices.length,
                    currentLine: _training.currentLine,
                    currentMoveIndex: _training.currentMoveIndex,
                    waitingForUser: _training.waitingForUser,
                    isWhiteLine: _training.isWhiteLine,
                    playingIntro: _training.playingIntro,
                    moveDifficulty: _training.moveDifficulty,
                    onLearnAcknowledged: _training.learnAcknowledged,
                    onOpponentAcknowledged: _training.opponentAcknowledged,
                  ),
          ),
          const Divider(height: 16),
          TrainingBottomControls(
            settings: _training.settings,
            dueQueueLength: _training.remainingInRun,
            queueLabel: 'left in this run',
            onAutoNextChanged: (v) {
              setState(() => _training.settings.autoNext = v);
              _training.settings.saveSoon();
            },
          ),
        ],
      ),
    );
  }

  /// Shown when a Learn or Review run has nothing left: the summary plus the
  /// obvious next moves, never another rating prompt for the last line.
  Widget _buildRunCompletePanel() {
    final counts = countLines([
      for (final line in _training.lines)
        if (_training.lineInChapter(line, _training.activeChapter)) line,
    ], _training.reviewMap);

    return TrainingRunCompletePanel(
      title: _training.feedback ?? 'Session complete',
      sessionCorrect: _training.sessionCorrect,
      sessionIncorrect: _training.sessionIncorrect,
      sessionStreak: _training.sessionStreak,
      untrainedCount: counts.untrained,
      dueCount: counts.due,
      onBackToList: _training.stopSession,
      onLearn: _training.startLearnSession,
      onReview: _training.startReviewSession,
      learnBatchSize: _sessionCap(_training.settings.newLinesPerSession),
      reviewBatchSize: _sessionCap(_training.settings.reviewsPerSession),
    );
  }

  /// What to call the chapter scope in the UI: null is every line, the
  /// ungrouped sentinel is the lines no chapter claims.
  static String _chapterTitle(String? chapter) => chapter == null
      ? 'All lines'
      : chapter == TrainingSessionController.ungroupedChapter
      ? 'Other lines'
      : chapter;

  /// Small dense icon button for the Train tab header row.
  Widget _trainTabIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 17),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
    );
  }

  Widget _buildLinesTab() => _buildBrowser(dense: true);

  /// Read-only book view of a line: board + annotated movetext, with
  /// train/edit handoffs. Never touches training or review state.
  void _previewLine(RepertoireLine line) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => LinePreviewDialog(
          line: line,
          editLabel: _training.sourceIsStudy
              ? 'Edit in Study'
              : 'Edit in Builder',
          onEdit: () {
            Navigator.of(dialogContext).pop();
            if (_training.sourceIsStudy) {
              _openInStudy();
            } else if (_training.repertoire != null) {
              context.read<AppState>().switchToBuilder(
                repertoirePath: _training.repertoire!.filePath,
                lineId: line.id,
              );
            }
          },
          onTrain: () {
            Navigator.of(dialogContext).pop();
            _training.startLine(line);
          },
        ),
      ),
    );
  }

  /// Book view of a whole chapter (or the whole file when it has none): one
  /// board, every line's notes on one page. Never touches training state;
  /// train/edit hand off after the page closes, the same way the line
  /// preview does.
  Future<void> _readLines(List<RepertoireLine> lines) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChapterReaderScreen(
          repertoireName: _repertoireTitle(),
          chapterTitle: _chapterTitle(_training.activeChapter),
          lines: lines,
          reviewMap: _training.reviewMap,
          editLabel: _training.sourceIsStudy
              ? 'Edit in Study'
              : 'Edit in Builder',
          onEditLine: (line) {
            if (_training.sourceIsStudy) {
              _openInStudy();
            } else if (_training.repertoire != null) {
              context.read<AppState>().switchToBuilder(
                repertoirePath: _training.repertoire!.filePath,
                lineId: line.id,
              );
            }
          },
          onTrainLine: _training.startLine,
        ),
      ),
    );
  }

  Future<void> _applyLearnedSelection(
    Set<String> checkedLineIds,
    Set<String> scope,
  ) async {
    final changed = await _training.applyLearnedSelection(
      checkedLineIds,
      within: scope,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          changed == 0
              ? 'Learned lines unchanged.'
              : changed == 1
              ? '1 line updated.'
              : '$changed lines updated.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildPgnTab() {
    final line = _training.currentLine;
    if (line == null) {
      return const Center(child: Text('No line loaded.'));
    }

    final finished = _training.phase == TrainingPhase.finished;
    final revealed = finished || _pgnRevealedLineId == line.id;

    // Mid-training the PGN is a spoiler, so it sits behind one deliberate
    // click instead of a hard lock — you know what you're doing.
    if (!revealed) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.visibility_off_outlined,
              size: 48,
              color: AppColors.onSurfaceDim,
            ),
            const SizedBox(height: 12),
            Text(
              'The PGN spoils the line you\'re training.',
              style: AppTextStyles.body.copyWith(
                color: AppColors.onSurfaceMuted,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => setState(() => _pgnRevealedLineId = line.id),
              icon: const Icon(Icons.visibility_outlined, size: 16),
              label: const Text('Show PGN anyway'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  line.qualifiedName,
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: _training.sourceIsStudy
                    ? _openInStudy
                    : _openInBuilder,
                icon: const Icon(Icons.edit, size: 16),
                label: Text(
                  _training.sourceIsStudy ? 'Edit in Study' : 'Edit in Builder',
                ),
              ),
            ],
          ),
        ),
        if (!finished)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: AppColors.warning.withValues(alpha: 0.08),
            child: Text(
              'Peeking mid-training — clicking moves here won\'t touch the '
              'training board.',
              style: AppTextStyles.caption.copyWith(color: AppColors.warning),
            ),
          ),
        Expanded(
          child: PgnViewerWidget(
            pgnText: line.fullPgn,
            controller: _pgnController,
            // Only drive the shared board once the drill is over; mid-line it
            // would corrupt the trainer's position state.
            onPositionChanged: finished
                ? (position) {
                    _training.session.setPositionFromFen(position.fen);
                  }
                : null,
          ),
        ),
      ],
    );
  }

  void _ensureSettingsControllers() {
    if (_settingsInitialized) return;
    _settingsInitialized = true;
    _repetitionsController.text = _training.settings.correctStreakThreshold
        .toString();
    _depthController.text = _training.settings.trainingDepth?.toString() ?? '';
    _delayController.text = _training.settings.learnDelaySec.toString();
  }

  /// [onChanged] lets the settings dialog repaint itself; the tab version
  /// just rebuilds the screen.
  Widget _buildSettingsTab({VoidCallback? onChanged}) {
    _ensureSettingsControllers();
    final refresh = onChanged ?? () => setState(() {});
    return TrainingSettingsPanel(
      settings: _training.settings,
      repetitionsController: _repetitionsController,
      depthController: _depthController,
      delayController: _delayController,
      onQueueSettingsChanged: _training.updateDueQueue,
      onSettingsChanged: refresh,
      onChapterSettingsChanged: _training.onChapterSettingsChanged,
      trainingMode: _training.trainingMode,
      repetitionMode: _training.repetitionMode,
      onTrainingModeChanged: (mode) {
        _training.setTrainingMode(mode);
        refresh();
      },
      onRepetitionModeChanged: (mode) {
        _training.setRepetitionMode(mode);
        refresh();
      },
    );
  }
}
