/// Repertoire Trainer - Chessable-style line drilling with spaced repetition,
/// plus a tactics mode for training studies of custom puzzles.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/app_state.dart';
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
import '../widgets/chapter_list_body.dart' show ChapterPick;
import '../widgets/repertoire_list_body.dart';
import '../widgets/training/repertoire_selector_panel.dart';
import '../widgets/training/trainer_browser.dart';
import '../widgets/training/training_board_controls.dart';
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

class _RepertoireTrainingScreenState extends State<RepertoireTrainingScreen> {
  late final TrainingSessionController _training;
  bool _showPgn = false;

  final PgnViewerWidgetController _pgnController = PgnViewerWidgetController();
  final GlobalKey<MoveInputWidgetState> _moveInputKey = GlobalKey();

  /// Line id whose PGN the user chose to peek at mid-training. Reset on every
  /// new line so spoilers never leak across lines.
  String? _pgnRevealedLineId;

  /// Prevent duplicate chapter previews.
  bool _chapterPromptOpen = false;

  @override
  void initState() {
    super.initState();
    _training = TrainingSessionController();
    _training.onLineStarted = () {
      _pgnRevealedLineId = null;
      _showPgn = false;
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
    super.dispose();
  }

  void _onTrainingChanged() {
    if (!mounted) return;
    setState(() {});
  }

  // Grouping is an explicit preference, never an interruption on opening a file.
  void _openChapterSetup() {
    if (_chapterPromptOpen) return;
    _training.reopenChapterPrompt();
    _chapterPromptOpen = true;
    unawaited(_showChapterPrompt());
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
      // Dismissal keeps the current grouping without recording a preference.
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
    final pick = await Navigator.of(context).push<ChapterPick>(
      MaterialPageRoute(builder: (_) => const RepertoireSelectionScreen()),
    );
    if (pick != null) {
      _training.setRepertoire(pick.chapter);
      await _training.loadRepertoire(startChapter: pick.courseChapter);
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
      title: AppBarTitleWithTrail(
        title: AppOverflowMenu(
          tooltip: 'Repertoire',
          anchor: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: repertoire == null
                      ? Text(
                          'Select repertoire',
                          style: theme.textTheme.titleMedium,
                        )
                      : _repertoireCrumb(theme),
                ),
                const Icon(Icons.expand_more, size: 18),
              ],
            ),
          ),
          entries: [
            AppMenuEntry(
              label: 'Choose repertoire…',
              icon: Icons.folder_open,
              onRun: () => unawaited(_selectRepertoire()),
            ),
            if (repertoire != null) ...[
              AppMenuEntry(
                label: 'Reload from disk',
                icon: Icons.refresh,
                onRun: () => unawaited(_training.loadRepertoire()),
              ),
              AppMenuEntry(
                label: _training.sourceIsStudy
                    ? 'Edit study…'
                    : 'Open in Builder',
                icon: Icons.edit_outlined,
                onRun: _training.sourceIsStudy ? _openInStudy : _openInBuilder,
              ),
            ],
          ],
        ),
      ),
      actions: [
        const AppModeSwitcher(),
        TextButton.icon(
          onPressed: _openSettingsDialog,
          icon: const Icon(Icons.settings_outlined, size: 18),
          label: const Text('Training settings'),
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

  /// A course chapter tapped in the picker: open its file scoped to it.
  void _onCourseChapterSelected(RepertoireMetadata chapter, String course) {
    _training.setRepertoire(chapter);
    unawaited(_training.loadRepertoire(startChapter: course));
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
  /// chapter/line browser, or the current lesson.
  Widget _buildPanel() {
    if (_training.repertoire == null && !_training.isLoading) {
      return RepertoireListBody(
        onSelected: _onRepertoireSelected,
        onCourseChapterSelected: _onCourseChapterSelected,
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
        // Studies are edited in the Study editor, not the Builder.
        onOpenInBuilder:
            _training.repertoire != null && !_training.sourceIsStudy
            ? _openInBuilder
            : null,
      );
    }

    // Chessable-style chapter home: browse every line, pick what to train.
    if (_training.currentLine == null) return _buildBrowser();

    return _buildSidePane();
  }

  /// Choose material before starting a lesson.
  Widget _buildBrowser() {
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
      introEnabled: _training.settings.skipToFirstComment,
    );
  }

  /// Lines one press of Learn/Review covers. Linear mode runs the whole set
  /// by definition, so it never advertises a batch.
  int _sessionCap(int setting) =>
      _training.repetitionMode == RepetitionMode.linear ? 0 : setting;

  String _browserSubtitle() => _training.sourceIsStudy
      ? 'Choose a chapter or start practising.'
      : 'You play ${_training.sourceIsBlack ? 'Black' : 'White'} · Choose a chapter or start practising.';

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
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 1040,
          height: 760,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Training settings',
                        style: AppTextStyles.title,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close training settings',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListenableBuilder(
                  listenable: _training,
                  builder: (context, _) => _buildSettingsPanel(
                    onOpenAppSettings: () {
                      Navigator.of(dialogContext).pop();
                      unawaited(openAppSettings(this.context));
                    },
                  ),
                ),
              ),
            ],
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
    if (!_showPgn) return _buildTrainTab();
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _showPgn = false),
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Back to training'),
          ),
        ),
        Expanded(child: _buildPgnTab()),
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
                label: const Text(
                  'Back to lines',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: AppColors.onSurfaceSoft,
                ),
              ),
              const Spacer(),
              AppOverflowMenu(
                tooltip: 'Line actions',
                anchor: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Line', style: AppTextStyles.body),
                      Icon(Icons.expand_more, size: 18),
                    ],
                  ),
                ),
                entries: [
                  AppMenuEntry(
                    label: 'View moves and notes',
                    icon: Icons.description_outlined,
                    onRun: () => setState(() => _showPgn = true),
                  ),
                  AppMenuEntry(
                    label: 'Restart line',
                    icon: Icons.replay,
                    onRun: _training.restartLine,
                  ),
                  AppMenuEntry(
                    label: 'Skip to next line',
                    icon: Icons.skip_next,
                    onRun: _training.skipLine,
                  ),
                  AppMenuEntry(
                    label: 'Explore position in Builder',
                    icon: Icons.travel_explore,
                    onRun: _explorePosition,
                  ),
                  AppMenuEntry(
                    label: 'Copy FEN',
                    icon: Icons.content_copy,
                    onRun: () => unawaited(_copyFen()),
                  ),
                ],
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
          Text(
            '${_training.remainingInRun} lines left in this session',
            style: AppTextStyles.caption,
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

  Widget _buildSettingsPanel({VoidCallback? onOpenAppSettings}) {
    return TrainingSettingsPanel(
      settings: _training.settings,
      onQueueSettingsChanged: _training.updateDueQueue,
      onSettingsChanged: () {
        if (mounted) setState(() {});
      },
      onChapterSettingsChanged: _training.onChapterSettingsChanged,
      trainingMode: _training.trainingMode,
      repetitionMode: _training.repetitionMode,
      onTrainingModeChanged: _training.setTrainingMode,
      onRepetitionModeChanged: _training.setRepetitionMode,
      playingWhite: _training.repertoire == null || _training.sourceIsStudy
          ? null
          : !_training.sourceIsBlack,
      onChangePlayingSide: _chooseTrainingSide,
      onOpenChapterSetup: _training.canOfferChapters ? _openChapterSetup : null,
      chaptersDeclined: _training.chaptersDeclined,
      onOpenAppSettings: onOpenAppSettings,
    );
  }
}
