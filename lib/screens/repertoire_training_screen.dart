/// Repertoire Trainer - Chessable-style line drilling with spaced repetition
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/repertoire_controller.dart';
import '../models/repertoire_line.dart';
import '../models/repertoire_move_progress.dart';
import '../models/repertoire_review_entry.dart';
import '../models/repertoire_review_history_entry.dart';
import '../models/training_settings.dart';
import '../services/repertoire_review_service.dart';
import '../services/repertoire_service.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/pgn_viewer_widget.dart';
import '../widgets/repertoire_lines_browser.dart';
import 'repertoire_selection_screen.dart';

// ---------------------------------------------------------------------------
// TRAINING PHASES
// ---------------------------------------------------------------------------

enum _TrainingPhase {
  learning, // User is being shown moves for the first time
  drilling, // User is being quizzed on moves
  replaying, // User replays wrong moves after line completes
  finished, // Line complete, awaiting rating or next line
}

// ---------------------------------------------------------------------------
// TRAINING SCREEN
// ---------------------------------------------------------------------------

class RepertoireTrainingScreen extends StatefulWidget {
  final Map<String, dynamic>? repertoire;
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
  // -- Services --
  final RepertoireService _repertoireService = RepertoireService();
  final RepertoireReviewService _reviewService = RepertoireReviewService();

  // -- Data --
  Map<String, dynamic>? _repertoire;
  List<RepertoireLine> _lines = [];
  List<RepertoireReviewEntry> _otherRepertoireEntries = [];
  Map<String, RepertoireReviewEntry> _reviewMap = {};
  Map<String, RepertoireMoveProgress> _moveProgressMap = {};
  TrainingSettings _settings = TrainingSettings();

  // -- Training state --
  List<RepertoireLine> _dueQueue = [];
  RepertoireLine? _currentLine;
  int _currentLineLength = 0;
  int _currentMoveIndex = 0;
  _TrainingPhase _phase = _TrainingPhase.drilling;
  bool _lineHadMistake = false;
  List<int> _wrongMoveIndices = [];
  int _replayIndex = 0;

  // Learn phase state
  bool _learnWaitingForAck = false;
  bool _learnQuizzing = false; // user must play back the move they just saw
  Timer? _learnTimer;

  late final RepertoireController _session;
  late TabController _tabController;

  bool _isLoading = true;
  String? _error;
  bool _waitingForUser = false;
  String? _feedback;
  String? _currentAnnotation;

  // -- PGN viewer --
  final PgnViewerController _pgnController = PgnViewerController();

  // -- Settings controllers --
  final TextEditingController _repetitionsController = TextEditingController();
  final TextEditingController _depthController = TextEditingController();
  final TextEditingController _delayController = TextEditingController();
  bool _settingsInitialized = false;

  bool get _isWhiteLine => _currentLine?.color.toLowerCase() != 'black';
  bool get _boardFlipped => !_isWhiteLine;
  String get _repertoireId => (_repertoire?['filePath'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _session = RepertoireController();
    _session.addListener(_onSessionChanged);
    _repertoire = widget.repertoire;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
    });
  }

  @override
  void dispose() {
    _learnTimer?.cancel();
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    _tabController.dispose();
    _repetitionsController.dispose();
    _depthController.dispose();
    _delayController.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    _settings = await TrainingSettings.load();
    if (!mounted) return;

    final appState = context.read<AppState>();
    if (appState.pendingRepertoirePath != null &&
        appState.currentMode == AppMode.repertoireTrainer) {
      _repertoire = {
        'filePath': appState.pendingRepertoirePath,
        'name': appState.pendingRepertoirePath!.split('/').last.replaceAll('.pgn', ''),
      };
      final lineId = appState.pendingLineId;
      appState.pendingRepertoirePath = null;
      appState.pendingLineId = null;
      await _loadRepertoire(startLineId: lineId);
    } else if (_repertoire != null) {
      await _loadRepertoire(startLineId: widget.startLineId);
    } else {
      await _selectRepertoire();
    }
  }

  // ---------------------------------------------------------------------------
  // REPERTOIRE LOADING
  // ---------------------------------------------------------------------------

  Future<void> _selectRepertoire() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => const RepertoireSelectionScreen()),
    );
    if (result != null) {
      setState(() => _repertoire = result);
      await _loadRepertoire();
    } else {
      setState(() {
        _isLoading = false;
        _error = 'Select a repertoire to start training.';
      });
    }
  }

  Future<void> _loadRepertoire({String? startLineId}) async {
    if (_repertoire == null) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _feedback = null;
    });

    try {
      final filePath = _repertoire!['filePath'] as String;
      final lines = await _repertoireService.parseRepertoireFile(filePath);
      if (lines.isEmpty) {
        setState(() {
          _error = 'No trainable lines found.';
          _isLoading = false;
        });
        return;
      }

      final allEntries = await _reviewService.loadAll();
      final moveProgress = await _reviewService.loadMoveProgress();
      _otherRepertoireEntries =
          allEntries.where((e) => e.repertoireId != filePath).toList();
      final currentEntries =
          allEntries.where((e) => e.repertoireId == filePath).toList();
      final merged = _reviewService.syncEntries(
        repertoireId: filePath,
        lines: lines,
        existing: currentEntries,
      );
      await _reviewService.saveAll([..._otherRepertoireEntries, ...merged]);

      setState(() {
        _lines = lines;
        _reviewMap = {for (final e in merged) e.lineId: e};
        _moveProgressMap = _reviewService.indexMoveProgress(
          moveProgress.where((mp) => mp.repertoireId == filePath).toList(),
        );
        _dueQueue = _reviewService.dueLinesInOrder(lines, _reviewMap);
      });

      _pickStartingLine(startLineId: startLineId);
    } catch (e) {
      setState(() => _error = 'Error loading repertoire: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // LINE MANAGEMENT
  // ---------------------------------------------------------------------------

  void _pickStartingLine({String? startLineId}) {
    if (_lines.isEmpty) return;
    RepertoireLine? initial;
    if (startLineId != null) {
      initial = _lines.firstWhere((l) => l.id == startLineId,
          orElse: () => _lines.first);
    } else if (_dueQueue.isNotEmpty) {
      initial = _dueQueue.first;
    } else {
      initial = _lines.first;
    }
    _startLine(initial);
  }

  bool _isLineNew(RepertoireLine line) {
    final entry = _reviewMap[line.id];
    return entry == null || entry.isNew;
  }

  void _startLine(RepertoireLine? line) {
    if (line == null) return;
    _learnTimer?.cancel();

    if (line.startPosition.fen != Chess.initial.fen) {
      _session.setPositionFromFen(line.startPosition.fen);
    } else {
      _session.clearMoveHistory();
    }

    final effectiveLength = _settings.trainingDepth != null
        ? _settings.trainingDepth!.clamp(1, line.moves.length)
        : line.moves.length;

    final isNew = _isLineNew(line);

    setState(() {
      _currentLine = line;
      _currentLineLength = effectiveLength;
      _currentMoveIndex = 0;
      _feedback = null;
      _currentAnnotation = null;
      _phase = isNew ? _TrainingPhase.learning : _TrainingPhase.drilling;
      _lineHadMistake = false;
      _wrongMoveIndices = [];
      _replayIndex = 0;
      _waitingForUser = false;
      _learnWaitingForAck = false;
      _learnQuizzing = false;
      _tabController.animateTo(0);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_phase == _TrainingPhase.learning) {
        _advanceLearnPhase();
      } else {
        _advanceDrillPhase();
      }
    });
  }

  void _nextLine() {
    _rebuildQueueAndAdvance();
  }

  // ---------------------------------------------------------------------------
  // LEARN PHASE - Show moves one at a time, then quiz immediately
  // ---------------------------------------------------------------------------

  Future<void> _advanceLearnPhase() async {
    if (_currentLine == null) return;
    if (_currentMoveIndex >= _currentLineLength) {
      // Done showing all moves; now drill the whole line
      _session.clearMoveHistory();
      if (_currentLine!.startPosition.fen != Chess.initial.fen) {
        _session.setPositionFromFen(_currentLine!.startPosition.fen);
      } else {
        _session.clearMoveHistory();
      }
      setState(() {
        _currentMoveIndex = 0;
        _phase = _TrainingPhase.drilling;
        _feedback = null;
        _currentAnnotation = null;
        _waitingForUser = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _advanceDrillPhase();
      });
      return;
    }

    // Show the current move on the board
    final san = _currentLine!.moves[_currentMoveIndex];
    final move = _session.position.parseSan(san);
    if (move == null) {
      setState(() => _error = 'Invalid move in line: $san');
      return;
    }
    _session.userPlayedMove(san);

    final annotation =
        _currentLine!.comments[_currentMoveIndex.toString()];

    setState(() {
      _currentAnnotation = annotation;
      _feedback = null;
      _waitingForUser = false;
    });

    final isUserMove = _isUserMove(_currentMoveIndex);

    if (!isUserMove) {
      // Opponent moves auto-play with a brief delay — nothing to memorize
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      _currentMoveIndex++;
      _advanceLearnPhase();
    } else if (_settings.learnRequiresClick) {
      // User move: wait for Space/Next acknowledgment
      setState(() => _learnWaitingForAck = true);
    } else if (annotation != null && annotation.isNotEmpty) {
      // Auto-advance mode: wait the configured delay when there's something to read
      _learnTimer = Timer(
        Duration(seconds: _settings.learnDelaySec),
        _learnAcknowledged,
      );
    } else {
      // Auto-advance mode, user move, no annotation: brief pause then advance
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      _currentMoveIndex++;
      _advanceLearnPhase();
    }
  }

  void _learnAcknowledged() {
    _learnTimer?.cancel();
    if (!mounted) return;
    // Undo the move so user must play it back from memory
    _session.goBack();
    setState(() {
      _learnWaitingForAck = false;
      _learnQuizzing = true;
      _waitingForUser = true;
      _feedback = 'Your move';
      _currentAnnotation = null;
    });
  }

  void _handleLearnQuizMove(CompletedMove move) async {
    if (_currentLine == null) return;
    final expectedSan = _currentLine!.moves[_currentMoveIndex];
    final isCorrect = _isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      _session.userPlayedMove(expectedSan);
      setState(() {
        _learnQuizzing = false;
        _waitingForUser = false;
        _feedback = 'Correct!';
      });
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      _currentMoveIndex++;
      _advanceLearnPhase();
    } else {
      // Wrong — show correct move, replay it, then ask again
      setState(() => _feedback = 'Wrong — the move is $expectedSan');
      await Future.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;
      // Play the correct move so they see it
      _session.userPlayedMove(expectedSan);
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      // Undo again, make them try once more
      _session.goBack();
      setState(() {
        _feedback = 'Try again';
        _waitingForUser = true;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // DRILL PHASE - Quiz user on moves
  // ---------------------------------------------------------------------------

  int get _effectiveLineLength => _currentLineLength;

  bool _isUserMove(int moveIndex) {
    if (_currentLine == null) return false;
    final startIsWhite = _currentLine!.startPosition.turn == Side.white;
    final isWhiteMove =
        startIsWhite ? (moveIndex % 2 == 0) : (moveIndex % 2 == 1);
    return (_isWhiteLine && isWhiteMove) || (!_isWhiteLine && !isWhiteMove);
  }

  Future<void> _advanceDrillPhase() async {
    if (_currentLine == null) return;
    final limit = _effectiveLineLength;

    while (_currentMoveIndex < limit) {
      if (_isUserMove(_currentMoveIndex)) {
        _prepareDrillMove(_currentMoveIndex);
        return;
      } else {
        await _playOpponentMove(_currentMoveIndex);
        _currentMoveIndex++;
      }
    }
    _onLineComplete();
  }

  Future<void> _playOpponentMove(int moveIndex) async {
    if (_currentLine == null) return;
    final san = _currentLine!.moves[moveIndex];
    final move = _session.position.parseSan(san);
    if (move == null) {
      setState(() => _error = 'Could not play opponent move $san');
      return;
    }
    _session.userPlayedMove(san);
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
  }

  void _prepareDrillMove(int moveIndex) {
    final annotation =
        _currentLine!.comments[moveIndex.toString()];
    setState(() {
      _waitingForUser = true;
      _currentAnnotation = annotation;
      _feedback = 'Your move';
    });
  }

  void _handleUserMove(CompletedMove move) async {
    if (!_waitingForUser || _currentLine == null) return;

    if (_phase == _TrainingPhase.learning && _learnQuizzing) {
      _handleLearnQuizMove(move);
      return;
    }

    if (_phase == _TrainingPhase.replaying) {
      _handleReplayMove(move);
      return;
    }

    final expectedSan = _currentLine!.moves[_currentMoveIndex];
    final isCorrect = _isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      _updateMoveProgress(_currentLine!, _currentMoveIndex, wasCorrect: true);
      _session.userPlayedMove(expectedSan);
      setState(() {
        _waitingForUser = false;
        _feedback = 'Correct!';
        _currentAnnotation = null;
      });
      _currentMoveIndex++;
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      _advanceDrillPhase();
    } else {
      _updateMoveProgress(_currentLine!, _currentMoveIndex, wasCorrect: false);
      _lineHadMistake = true;
      _wrongMoveIndices.add(_currentMoveIndex);

      setState(() {
        _feedback = 'Wrong — the move was $expectedSan';
      });
      await Future.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;

      _session.userPlayedMove(expectedSan);
      setState(() {
        _waitingForUser = false;
        _currentAnnotation = null;
      });
      _currentMoveIndex++;
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      _advanceDrillPhase();
    }
  }

  void _onLineComplete() {
    if (_lineHadMistake &&
        _settings.wrongMoveReplay &&
        _wrongMoveIndices.isNotEmpty) {
      _startReplayPhase();
    } else {
      setState(() {
        _phase = _TrainingPhase.finished;
        _waitingForUser = false;
        _feedback = 'Line complete — rate your recall.';
        _currentAnnotation = null;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // REPLAY PHASE
  // ---------------------------------------------------------------------------

  void _startReplayPhase() {
    _wrongMoveIndices = _wrongMoveIndices.toSet().toList()..sort();
    _replayIndex = 0;
    setState(() {
      _phase = _TrainingPhase.replaying;
      _feedback =
          'Replay missed moves (${_wrongMoveIndices.length} remaining)';
      _currentAnnotation = null;
    });
    _setupReplayPosition();
  }

  void _setupReplayPosition() {
    if (_currentLine == null) return;
    if (_replayIndex >= _wrongMoveIndices.length) {
      setState(() {
        _phase = _TrainingPhase.finished;
        _waitingForUser = false;
        _feedback = 'Line complete — rate your recall.';
        _currentAnnotation = null;
      });
      return;
    }

    final targetMoveIndex = _wrongMoveIndices[_replayIndex];

    if (_currentLine!.startPosition.fen != Chess.initial.fen) {
      _session.setPositionFromFen(_currentLine!.startPosition.fen);
    } else {
      _session.clearMoveHistory();
    }
    for (int i = 0; i < targetMoveIndex; i++) {
      _session.userPlayedMove(_currentLine!.moves[i]);
    }

    setState(() {
      _waitingForUser = true;
      _feedback =
          'Replay — ${_wrongMoveIndices.length - _replayIndex} left';
      _currentAnnotation = null;
    });
  }

  void _handleReplayMove(CompletedMove move) async {
    final targetMoveIndex = _wrongMoveIndices[_replayIndex];
    final expectedSan = _currentLine!.moves[targetMoveIndex];
    final isCorrect = _isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      _updateMoveProgress(_currentLine!, targetMoveIndex, wasCorrect: true);
      _session.userPlayedMove(expectedSan);
      setState(() {
        _feedback = 'Correct!';
        _waitingForUser = false;
      });
      _replayIndex++;
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      _setupReplayPosition();
    } else {
      _updateMoveProgress(_currentLine!, targetMoveIndex, wasCorrect: false);
      setState(() {
        _feedback = 'Try again — the move is $expectedSan';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // MOVE VALIDATION
  // ---------------------------------------------------------------------------

  bool _isCorrectUserMove(CompletedMove move, String expectedSan) {
    final expectedMove = _session.position.parseSan(expectedSan);
    if (expectedMove == null) return false;

    try {
      final expectedPos = _session.position.play(expectedMove);
      final userMove = Move.parse(move.uci);
      if (userMove == null) return false;
      final userPos = _session.position.play(userMove);
      if (userPos.fen == expectedPos.fen) return true;
    } catch (_) {}

    String normalizeSan(String san) =>
        san.replaceAll(RegExp(r'[+#?!]'), '').trim().toLowerCase();
    return normalizeSan(move.san) == normalizeSan(expectedSan);
  }

  // ---------------------------------------------------------------------------
  // RATING & PROGRESS
  // ---------------------------------------------------------------------------

  Future<void> _rateLine(ReviewRating rating) async {
    if (_currentLine == null) return;

    final existing = _reviewMap[_currentLine!.id] ??
        RepertoireReviewEntry(
          repertoireId: _repertoireId,
          lineId: _currentLine!.id,
          lineName: _currentLine!.name,
        );

    final hadMistake = _lineHadMistake;
    final updated = _reviewService.applyRating(existing, rating).copyWith(
          passCount: hadMistake ? existing.passCount : existing.passCount + 1,
          failCount: hadMistake ? existing.failCount + 1 : existing.failCount,
        );
    _reviewMap[_currentLine!.id] = updated;

    await _reviewService
        .saveAll([..._otherRepertoireEntries, ..._reviewMap.values]);
    await _reviewService.saveMoveProgress(
      _moveProgressMap.values.toList(),
      repertoireId: _repertoireId,
    );
    await _reviewService.appendHistory([
      RepertoireReviewHistoryEntry(
        repertoireId: _repertoireId,
        lineId: _currentLine!.id,
        timestampUtc: DateTime.now().toUtc(),
        rating: rating.name,
        hadMistake: hadMistake,
        sessionType: 'trainer',
      )
    ]);

    // Persist review metadata in PGN headers for portability
    _repertoireService.updateLineReviewHeaders(
      _repertoireId,
      _currentLine!.id,
      lastReview: updated.lastReviewedUtc,
      difficulty: updated.difficulty,
      intervalDays: updated.intervalDays,
      dueDate: updated.dueDateUtc,
      passCount: updated.passCount,
      failCount: updated.failCount,
    );

    if (_settings.autoNext) {
      _rebuildQueueAndAdvance();
    } else {
      setState(() {
        _dueQueue = _reviewService.dueLinesInOrder(_lines, _reviewMap);
      });
    }
  }

  void _rebuildQueueAndAdvance() {
    setState(() {
      _dueQueue = _reviewService.dueLinesInOrder(_lines, _reviewMap);
    });

    if (_dueQueue.isEmpty) {
      setState(() {
        _phase = _TrainingPhase.finished;
        _feedback = 'All lines reviewed!';
      });
      return;
    }

    int nextIndex = 0;
    if (_currentLine != null) {
      final currentOrderIndex =
          _lines.indexWhere((l) => l.id == _currentLine!.id);
      for (int i = 1; i <= _lines.length; i++) {
        final candidateIndex = (currentOrderIndex + i) % _lines.length;
        final candidate = _lines[candidateIndex];
        if (_reviewMap[candidate.id]?.isDue ?? true) {
          nextIndex = _dueQueue.indexWhere((l) => l.id == candidate.id);
          if (nextIndex >= 0) break;
        }
      }
    }
    _startLine(_dueQueue[nextIndex.clamp(0, _dueQueue.length - 1)]);
  }

  void _updateMoveProgress(RepertoireLine line, int moveIndex,
      {required bool wasCorrect}) {
    final key = '${line.id}:$moveIndex';
    final existing = _moveProgressMap[key];
    final threshold = _settings.correctStreakThreshold;

    if (wasCorrect) {
      final newStreak = (existing?.correctStreak ?? 0) + 1;
      final learned = newStreak >= threshold;
      _moveProgressMap[key] = RepertoireMoveProgress(
        repertoireId: _repertoireId,
        lineId: line.id,
        moveIndex: moveIndex,
        correctStreak: learned ? threshold : newStreak,
        learned: learned,
      );
    } else {
      _moveProgressMap[key] = RepertoireMoveProgress(
        repertoireId: _repertoireId,
        lineId: line.id,
        moveIndex: moveIndex,
        correctStreak: 0,
        learned: false,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  void _openInBuilder() {
    if (_repertoire == null) return;
    context.read<AppState>().switchToBuilder(
          repertoirePath: _repertoire!['filePath'] as String,
          lineId: _currentLine?.id,
        );
  }

  String _formatRelativeDate(DateTime date) {
    final diff = DateTime.now().toUtc().difference(date);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.month}/${date.day}';
  }

  double _moveDifficulty(RepertoireLine line, int moveIndex) {
    final key = '${line.id}:$moveIndex';
    final prog = _moveProgressMap[key];
    if (prog == null) return 0;
    return prog.correctStreak / _settings.correctStreakThreshold;
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        appBar: _buildAppBar(),
        body: _buildBody(),
      ),
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Spacebar to acknowledge learn phase
    if (event.logicalKey == LogicalKeyboardKey.space && _learnWaitingForAck) {
      _learnAcknowledged();
      return KeyEventResult.handled;
    }

    // 1-4 to rate when line is finished and rating buttons are shown
    if (_phase == _TrainingPhase.finished && _settings.showRatingButtons) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.digit1:
          _rateLine(ReviewRating.again);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.digit2:
          _rateLine(ReviewRating.hard);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.digit3:
          _rateLine(ReviewRating.good);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.digit4:
          _rateLine(ReviewRating.easy);
          return KeyEventResult.handled;
        default:
          break;
      }
    }

    return KeyEventResult.ignored;
  }

  PreferredSizeWidget _buildAppBar() {
    final theme = Theme.of(context);
    return AppBar(
      titleSpacing: 16,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Repertoire Trainer', style: theme.textTheme.titleMedium),
          if (_repertoire != null)
            Text(
              _repertoire!['name'] as String? ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      actions: [
        if (_repertoire != null)
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadRepertoire(),
          ),
        if (_repertoire != null)
          IconButton(
            tooltip: 'Open in Builder',
            icon: const Icon(Icons.construction),
            onPressed: _openInBuilder,
          ),
        const AppModeMenuButton(),
        IconButton(
          tooltip: 'Select repertoire',
          icon: const Icon(Icons.library_books),
          onPressed: _selectRepertoire,
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading repertoire...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _selectRepertoire,
              child: const Text('Select Repertoire'),
            ),
          ],
        ),
      );
    }

    if (_currentLine == null && _lines.isNotEmpty) {
      return Center(
        child: FilledButton(
          onPressed: _pickStartingLine,
          child: const Text('Start Training'),
        ),
      );
    }

    if (_lines.isEmpty) {
      return const Center(child: Text('No lines available.'));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 1100;
        if (isCompact) {
          return Column(
            children: [
              Expanded(flex: 4, child: _buildBoardPane()),
              const Divider(height: 1, thickness: 1),
              Expanded(flex: 5, child: _buildSidePane()),
            ],
          );
        }
        return Row(
          children: [
            Expanded(flex: 6, child: _buildBoardPane()),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(flex: 4, child: _buildSidePane()),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // BOARD PANE
  // ---------------------------------------------------------------------------

  Widget _buildBoardPane() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ChessBoardWidget(
                  key: ValueKey(_session.fen),
                  position: _session.position,
                  flipped: _boardFlipped,
                  enableUserMoves: _waitingForUser,
                  onMove: _handleUserMove,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeedbackText(ThemeData theme) {
    Color color = theme.colorScheme.onSurfaceVariant;
    if (_feedback!.startsWith('Correct')) {
      color = Colors.green;
    } else if (_feedback!.startsWith('Wrong') || _feedback!.startsWith('Try')) {
      color = theme.colorScheme.error;
    }
    return Text(
      _feedback!,
      style: theme.textTheme.titleSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SIDE PANE (TABS)
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // TRAIN TAB - Focused, minimal, only what you need right now
  // ---------------------------------------------------------------------------

  Widget _buildTrainTab() {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line name + progress
          if (_currentLine != null) ...[
            Text(
              _currentLine!.name,
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            _buildProgressIndicator(),
            const Divider(height: 16),
          ],

          // Current phase content
          Expanded(child: _buildPhaseContent(theme)),

          // Bottom controls
          const Divider(height: 16),
          _buildBottomControls(),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator() {
    if (_currentLine == null) return const SizedBox.shrink();
    final progress = _currentMoveIndex / _effectiveLineLength;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Move ${_currentMoveIndex + 1} / $_effectiveLineLength',
              style: theme.textTheme.bodySmall,
            ),
            const Spacer(),
            if (_phase == _TrainingPhase.learning)
              Text('Learning', style: TextStyle(
                color: Colors.blue[400], fontSize: 12)),
            if (_phase == _TrainingPhase.drilling)
              Text('Drilling', style: TextStyle(
                color: Colors.orange[400], fontSize: 12)),
            if (_phase == _TrainingPhase.replaying)
              Text('Replaying', style: TextStyle(
                color: Colors.red[400], fontSize: 12)),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
      ],
    );
  }

  Widget _buildPhaseContent(ThemeData theme) {
    switch (_phase) {
      case _TrainingPhase.learning:
        return _buildLearnContent(theme);
      case _TrainingPhase.drilling:
        return _buildDrillContent(theme);
      case _TrainingPhase.replaying:
        return _buildReplayContent(theme);
      case _TrainingPhase.finished:
        return _buildFinishedContent(theme);
    }
  }

  Widget _buildLearnContent(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_learnQuizzing) ...[
            Text(
              _feedback ?? 'Your move',
              style: theme.textTheme.titleSmall?.copyWith(
                color: _feedback != null && _feedback!.startsWith('Wrong')
                    ? theme.colorScheme.error
                    : _feedback == 'Correct!'
                        ? Colors.green
                        : null,
              ),
            ),
          ] else ...[
            if (_currentAnnotation != null &&
                _currentAnnotation!.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _currentAnnotation!,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_learnWaitingForAck) ...[
              SizedBox(
                width: double.infinity,
                child: Tooltip(
                  message: 'Keyboard shortcut: Space',
                  child: FilledButton.icon(
                    onPressed: _learnAcknowledged,
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: const Text('Next'),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildDrillContent(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_feedback != null && _feedback!.isNotEmpty) ...[
            _buildFeedbackText(theme),
            const SizedBox(height: 12),
          ],
          if (_currentAnnotation != null &&
              _currentAnnotation!.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _currentAnnotation!,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_currentLine != null &&
              _currentMoveIndex < _currentLine!.moves.length) ...[
            _buildMoveDifficultyChip(_currentMoveIndex),
          ],
        ],
      ),
    );
  }

  Widget _buildReplayContent(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_feedback != null && _feedback!.isNotEmpty) ...[
          _buildFeedbackText(theme),
          const SizedBox(height: 12),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Replaying missed moves',
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: Colors.orange[700]),
              ),
              const SizedBox(height: 4),
              Text(
                '${_replayIndex + 1} of ${_wrongMoveIndices.length}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFinishedContent(ThemeData theme) {
    final entry = _reviewMap[_currentLine?.id];

    // Auto-rate if rating buttons are disabled
    if (!_settings.showRatingButtons) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _phase != _TrainingPhase.finished) return;
        final autoRating = _lineHadMistake ? ReviewRating.again : ReviewRating.good;
        _rateLine(autoRating);
      });
      return Center(
        child: Text(
          _lineHadMistake ? 'Scheduling for review...' : 'Line complete!',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How well did you know this?',
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          _buildRatingButtons(),
          const SizedBox(height: 16),

          if (entry != null && entry.lastReviewedUtc != null) ...[
            Text(
              'Last reviewed: ${_formatRelativeDate(entry.lastReviewedUtc!)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
          ],
          if (entry != null)
            Text(
              'Pass: ${entry.passCount} / Fail: ${entry.failCount}',
              style: theme.textTheme.bodySmall,
            ),

          if (!_settings.autoNext) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _nextLine,
                icon: const Icon(Icons.skip_next),
                label: const Text('Next Line'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMoveDifficultyChip(int moveIndex) {
    final difficulty = _moveDifficulty(_currentLine!, moveIndex);
    final theme = Theme.of(context);

    String label;
    Color color;
    if (difficulty >= 1.0) {
      label = 'Memorized';
      color = Colors.green;
    } else if (difficulty > 0) {
      final pct = (difficulty * 100).round();
      label = '$pct% learned';
      color = Colors.orange;
    } else {
      label = 'New move';
      color = theme.colorScheme.onSurfaceVariant;
    }

    return Text(label, style: TextStyle(color: color, fontSize: 12));
  }

  Widget _buildBottomControls() {
    return Row(
      children: [
        Text('Auto-next', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 8),
        SizedBox(
          height: 24,
          child: Switch(
            value: _settings.autoNext,
            onChanged: (v) {
              setState(() => _settings.autoNext = v);
              _settings.save();
            },
          ),
        ),
        const Spacer(),
        if (_currentLine != null)
          Text(
            '${_dueQueue.length} due',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }

  Widget _buildRatingButtons() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _ratingButton(ReviewRating.again, 'Again', Colors.red, '1'),
        _ratingButton(ReviewRating.hard, 'Hard', Colors.orange, '2'),
        _ratingButton(ReviewRating.good, 'Good', Colors.blue, '3'),
        _ratingButton(ReviewRating.easy, 'Easy', Colors.green, '4'),
      ],
    );
  }

  Widget _ratingButton(
      ReviewRating rating, String label, Color color, String shortcut) {
    return Tooltip(
      message: 'Keyboard: $shortcut',
      child: OutlinedButton(
        onPressed: () => _rateLine(rating),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.5)),
        ),
        child: Text('$label ($shortcut)'),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // LINES TAB - Opening tree + lines browser
  // ---------------------------------------------------------------------------

  Widget _buildLinesTab() {
    return RepertoireLinesBrowser(
      lines: _lines,
      onLineSelected: (line) => _startLine(line),
      isExpanded: true,
    );
  }

  // ---------------------------------------------------------------------------
  // PGN TAB - Only available after line is finished (when auto-next is off)
  // ---------------------------------------------------------------------------

  Widget _buildPgnTab() {
    if (_currentLine == null) {
      return const Center(child: Text('No line loaded.'));
    }

    if (_phase != _TrainingPhase.finished) {
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
                  _currentLine!.name,
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
            pgnText: _currentLine!.fullPgn,
            controller: _pgnController,
            onPositionChanged: (position) {
              _session.setPositionFromFen(position.fen);
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // SETTINGS TAB
  // ---------------------------------------------------------------------------

  void _ensureSettingsControllers() {
    if (_settingsInitialized) return;
    _settingsInitialized = true;
    _repetitionsController.text = _settings.correctStreakThreshold.toString();
    _depthController.text = _settings.trainingDepth?.toString() ?? '';
    _delayController.text = _settings.learnDelaySec.toString();
  }

  Widget _buildSettingsTab() {
    _ensureSettingsControllers();
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings', style: theme.textTheme.titleMedium),
          const SizedBox(height: 20),

          // -- Repetitions --
          Text('Repetitions to memorize', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'A move is "memorized" after you get it right this '
            'many times in a row. (1–10)',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _repetitionsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: '3',
              ),
              onChanged: (value) {
                final n = int.tryParse(value);
                if (n != null && n >= 1 && n <= 10) {
                  _settings.correctStreakThreshold = n;
                  _settings.save();
                }
              },
            ),
          ),

          const SizedBox(height: 24),

          // -- Drill depth --
          Text('Drill depth (moves)', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Only drill the first N moves of each line. '
            'Leave empty to drill the entire line.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _depthController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: 'All',
              ),
              onChanged: (value) {
                if (value.trim().isEmpty) {
                  _settings.trainingDepth = null;
                  _settings.save();
                  return;
                }
                final n = int.tryParse(value);
                if (n != null && n >= 1 && n <= 200) {
                  _settings.trainingDepth = n;
                  _settings.save();
                }
              },
            ),
          ),

          const SizedBox(height: 24),

          // -- Replay missed moves --
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Replay missed moves',
                style: theme.textTheme.titleSmall),
            subtitle: const Text(
              'After a line, replay every move you got wrong '
              'before rating.',
            ),
            value: _settings.wrongMoveReplay,
            onChanged: (v) {
              setState(() => _settings.wrongMoveReplay = v);
              _settings.save();
            },
          ),

          // -- Rating buttons --
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Self-rate difficulty (1-4)',
                style: theme.textTheme.titleSmall),
            subtitle: const Text(
              'Show Again/Hard/Good/Easy buttons after each line. '
              'If off, difficulty is determined automatically from '
              'your mistakes.',
            ),
            value: _settings.showRatingButtons,
            onChanged: (v) {
              setState(() => _settings.showRatingButtons = v);
              _settings.save();
            },
          ),

          const Divider(height: 32),

          // -- Learn mode settings --
          Text('Learning new lines', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Manual advance',
                style: theme.textTheme.titleSmall),
            subtitle: const Text(
              'Press Next (or Space) to see the next move when '
              'learning. Turn off to auto-advance after a delay.',
            ),
            value: _settings.learnRequiresClick,
            onChanged: (v) {
              setState(() => _settings.learnRequiresClick = v);
              _settings.save();
            },
          ),

          if (!_settings.learnRequiresClick) ...[
            const SizedBox(height: 12),
            Text('Auto-advance delay (seconds)',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Seconds to show each annotated move before '
              'advancing. (1–15)',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 80,
              child: TextField(
                controller: _delayController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: '3',
                ),
                onChanged: (value) {
                  final n = int.tryParse(value);
                  if (n != null && n >= 1 && n <= 15) {
                    _settings.learnDelaySec = n;
                    _settings.save();
                  }
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
