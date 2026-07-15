/// Repertoire Trainer - Chessable-style line drilling with spaced repetition
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../models/repertoire_metadata.dart';
import '../services/training/training_phase.dart';
import '../services/training/training_session_controller.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/pgn_viewer_widget.dart';
import '../widgets/trainer_keyboard_scope.dart';
import '../widgets/training/move_input_widget.dart';
import '../widgets/repertoire_list_body.dart';
import '../widgets/training/repertoire_selector_panel.dart';
import '../widgets/training/training_board_controls.dart';
import '../widgets/training/training_lines_panel.dart';
import '../widgets/training/training_progress_panel.dart';
import '../widgets/training/training_results_panel.dart';
import '../widgets/training/training_settings_panel.dart';
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _training = TrainingSessionController();
    _training.onLineStarted = () {
      if (mounted) _tabController.animateTo(0);
    };
    _training.addListener(_onTrainingChanged);
    _training.setRepertoire(widget.repertoire);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
    });
  }

  @override
  void dispose() {
    _training.removeListener(_onTrainingChanged);
    _training.dispose();
    _tabController.dispose();
    _repetitionsController.dispose();
    _depthController.dispose();
    _delayController.dispose();
    super.dispose();
  }

  void _onTrainingChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    await _training.loadSettings();
    if (!mounted) return;

    final appState = context.read<AppState>();
    if (appState.pendingRepertoirePath != null &&
        appState.currentMode == AppMode.repertoireTrainer) {
      _training.setRepertoire(
        RepertoireMetadata(
          filePath: appState.pendingRepertoirePath!,
          name: p.basenameWithoutExtension(appState.pendingRepertoirePath!),
          lastModified: DateTime.now(),
        ),
      );
      final lineId = appState.pendingLineId;
      appState.pendingRepertoirePath = null;
      appState.pendingLineId = null;
      await _training.loadRepertoire(startLineId: lineId);
    } else if (_training.repertoire != null) {
      await _training.loadRepertoire(startLineId: widget.startLineId);
    } else {
      _training.setIdle();
    }
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

  void _scoreInBuilder() {
    if (_training.repertoire == null) return;
    context.read<AppState>().switchToBuilder(
      repertoirePath: _training.repertoire!.filePath,
    );
  }

  String _formatRelativeDate(DateTime date) {
    final diff = DateTime.now().toUtc().difference(date);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.month}/${date.day}';
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

    if (isTextInputFocused()) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.slash && hasNoLetterModifiers) {
      _moveInputKey.currentState?.focus();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyJ && hasNoLetterModifiers) {
      final settings = _training.settings;
      settings.learnRequiresClick = !settings.learnRequiresClick;
      settings.save();
      setState(() {});
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  PreferredSizeWidget _buildAppBar() {
    final theme = Theme.of(context);
    final repertoire = _training.repertoire;
    return AppBar(
      titleSpacing: 16,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Repertoire Trainer', style: theme.textTheme.titleMedium),
          if (repertoire != null)
            Text(
              repertoire.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      actions: [
        if (repertoire != null)
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: () => _training.loadRepertoire(),
          ),
        if (repertoire != null)
          IconButton(
            tooltip: 'Open in Builder',
            icon: const Icon(Icons.construction),
            onPressed: _openInBuilder,
          ),
        IconButton(
          tooltip: 'Select repertoire',
          icon: const Icon(Icons.library_books),
          onPressed: _selectRepertoire,
        ),
        const AppModeMenuButton(),
        const SizedBox(width: 8),
      ],
    );
  }

  void _onRepertoireSelected(RepertoireMetadata repertoire) {
    _training.setRepertoire(repertoire);
    _training.loadRepertoire();
  }

  Widget _buildBody() {
    if (_training.repertoire == null && !_training.isLoading) {
      return RepertoireListBody(onSelected: _onRepertoireSelected);
    }

    final bootstrap = RepertoireSelectorPanel(
      isLoading: _training.isLoading,
      error: _training.error,
      hasLines: _training.lines.isNotEmpty,
      canStartTraining:
          _training.currentLine == null && _training.lines.isNotEmpty,
      onSelectRepertoire: _selectRepertoire,
      onStartTraining: _training.pickStartingLine,
    );

    if (_training.isLoading || _training.error != null) return bootstrap;
    if (_training.currentLine == null && _training.lines.isNotEmpty) {
      return bootstrap;
    }
    if (_training.lines.isEmpty) return bootstrap;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 1100;
        if (isCompact) {
          return Column(
            children: [
              Expanded(flex: 4, child: _buildBoardPane()),
              const Divider(height: 1, thickness: 1),
              Expanded(flex: 6, child: _buildSidePane()),
            ],
          );
        }
        return Row(
          children: [
            Expanded(flex: 5, child: _buildBoardPane()),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(flex: 5, child: _buildSidePane()),
          ],
        );
      },
    );
  }

  Widget _buildBoardPane() {
    return TrainingBoardPane(
      session: _training.session,
      boardFlipped: _training.boardFlipped,
      waitingForUser: _training.waitingForUser,
      onMove: _training.handleUserMove,
      moveInputKey: _moveInputKey,
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

  Widget _buildTrainTab() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_training.currentLine != null) ...[
            Text(
              _training.currentLine!.name,
              style: Theme.of(context).textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const Divider(height: 16),
          ],
          Expanded(
            child: _training.phase == TrainingPhase.finished
                ? TrainingResultsPanel(
                    phase: _training.phase,
                    currentLine: _training.currentLine,
                    dueQueue: _training.dueQueue,
                    reviewMap: _training.reviewMap,
                    repertoireId: _training.repertoireId,
                    lineHadMistake: _training.lineHadMistake,
                    hadLearnPhaseThisSession:
                        _training.hadLearnPhaseThisSession == true,
                    settings: _training.settings,
                    sessionCorrect: _training.sessionCorrect,
                    sessionIncorrect: _training.sessionIncorrect,
                    sessionStreak: _training.sessionStreak,
                    reviewService: _training.reviewService,
                    formatRelativeDate: _formatRelativeDate,
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
            dueQueueLength: _training.dueQueue.length,
            onAutoNextChanged: (v) {
              setState(() => _training.settings.autoNext = v);
              _training.settings.save();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLinesTab() {
    return TrainingLinesPanel(
      lines: _training.lines,
      reviewMap: _training.reviewMap,
      moveProgressMap: _training.moveProgressMap,
      playabilityMap: _training.playabilityMap,
      bottleneckMap: _training.bottleneckMap,
      needsScoring: _training.needsScoring,
      onLineSelected: _training.startLine,
      onStartNextNew: _training.startNextNew,
      onStartNextDue: _training.startNextDue,
      onScoreInBuilder: _scoreInBuilder,
    );
  }

  Widget _buildPgnTab() {
    if (_training.currentLine == null) {
      return const Center(child: Text('No line loaded.'));
    }

    if (_training.phase != TrainingPhase.finished) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text(
              'Complete the line to review PGN',
              style: TextStyle(color: Colors.grey[600]),
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
                  _training.currentLine!.name,
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: _openInBuilder,
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('Edit in Builder'),
              ),
            ],
          ),
        ),
        Expanded(
          child: PgnViewerWidget(
            pgnText: _training.currentLine!.fullPgn,
            controller: _pgnController,
            onPositionChanged: (position) {
              _training.session.setPositionFromFen(position.fen);
            },
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

  Widget _buildSettingsTab() {
    _ensureSettingsControllers();
    return TrainingSettingsPanel(
      settings: _training.settings,
      repetitionsController: _repetitionsController,
      depthController: _depthController,
      delayController: _delayController,
      lines: _training.lines,
      reviewMap: _training.reviewMap,
      playabilityMap: _training.playabilityMap,
      reviewService: _training.reviewService,
      onDueQueueUpdated: _training.updateDueQueue,
      onSettingsChanged: () => setState(() {}),
    );
  }
}
