import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:dartchess/dartchess.dart';

import '../core/app_state.dart';
import '../models/engine_settings.dart';
import '../services/tactics/tactics_import_coordinator.dart';
import '../services/tactics/tactics_session_controller.dart';
import '../services/tactics_database.dart';
import '../services/tactics_import_service.dart';
import '../services/storage/storage_factory.dart';
import '../utils/app_messages.dart';
import 'pgn_viewer_widget.dart';
import 'pgn_with_engine.dart';
import 'tactics/tactics_browse_panel.dart';
import 'tactics/tactics_import_panel.dart';
import 'tactics/tactics_training_panel.dart';

/// Tactics training control panel with import, review, and analysis.
class TacticsControlPanel extends StatefulWidget {
  const TacticsControlPanel({super.key});

  @override
  State<TacticsControlPanel> createState() => _TacticsControlPanelState();
}

class _TacticsControlPanelState extends State<TacticsControlPanel>
    with TickerProviderStateMixin {
  AppState? _appState;

  late TacticsDatabase _database;
  late TacticsSessionController _session;
  late TacticsImportCoordinator _import;

  late TabController _tabController;
  bool _skipNextPositionChanged = false;

  // Import controllers
  late TextEditingController _lichessUserController;
  late TextEditingController _lichessCountController;
  late TextEditingController _chessComUserController;
  late TextEditingController _chessComCountController;
  late TextEditingController _stockfishDepthController;
  late TextEditingController _coresController;

  // Validation: _*Valid tracks logical state (immediate), _*Error is the
  // displayed red text (debounced so it doesn't flash while typing).
  bool _depthValid = true;
  bool _coresValid = true;
  String? _depthError;
  String? _coresError;
  Timer? _depthErrorTimer;
  Timer? _coresErrorTimer;

  // PGN Viewer controller for analysis tab
  final PgnViewerController _pgnViewerController = PgnViewerController();

  // Focus node for keyboard shortcuts during training
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _database = TacticsDatabase();
    _session = TacticsSessionController(database: _database);
    _import = TacticsImportCoordinator(database: _database);
    _session.onBoardUpdate = _applyBoardUpdate;
    _session.onPositionSetup = _loadPositionSetup;
    _session.addListener(_onSessionChanged);
    _import.addListener(_onImportChanged);
    _tabController = TabController(length: 2, vsync: this);

    _lichessUserController = TextEditingController();
    _lichessCountController = TextEditingController(text: '20');
    _chessComUserController = TextEditingController();
    _chessComCountController = TextEditingController(text: '20');
    _stockfishDepthController = TextEditingController(text: '15');
    final defaultCores = EngineSettings().workers;
    _coresController = TextEditingController(text: '$defaultCores');

    // Initialize controllers from AppState and reset board
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final appState = _appState ?? context.read<AppState>();
        _lichessUserController.text = appState.lichessUsername ?? '';
        _chessComUserController.text = appState.chesscomUsername ?? '';

        appState.setMoveAttemptedCallback(_onMoveAttempted);
        _resetBoardToStart();
      }
    });

    // Listen for tab changes to enter/exit analysis mode
    _tabController.addListener(() {
      if (mounted) {
        final appState = context.read<AppState>();
        if (_tabController.index == 1) {
          appState.enterAnalysisMode();
          // Sync the board to the PGN viewer's current position so that
          // moves made on the board match the PGN viewer's state.
          // Without this, solving a tactic advances the board past the
          // PGN viewer's position, causing analysis moves to silently fail.
          // NOTE: Do NOT set _skipNextPositionChanged here — setCurrentPosition
          // doesn't trigger the PGN viewer's onPositionChanged callback, so
          // the flag would linger and cause the next PGN navigation to
          // silently skip the board update.
          final fen = _pgnViewerController.currentFen;
          if (fen != null) {
            try {
              appState.setCurrentPosition(Chess.fromSetup(Setup.parseFen(fen)));
            } catch (e) { debugPrint('[TacticsPanel] Invalid FEN: $e'); }
          }
        } else {
          appState.exitAnalysisMode();
          // Don't reset the board position — keep whatever the PGN viewer
          // was showing so the two panels stay in sync. The user can click
          // "Reset" on the Tactic tab to return to the tactic position.
        }
      }
    });

    // Auto-load positions on startup
    _loadPositions();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState ??= context.read<AppState>();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  void _onImportChanged() {
    if (mounted) setState(() {});
  }

  void _applyBoardUpdate(TacticsBoardUpdate update) {
    if (!mounted) return;
    final appState = context.read<AppState>();
    try {
      if (update.applyMoveUci != null) {
        final move = Move.parse(update.applyMoveUci!);
        if (move != null) {
          appState.setCurrentPosition(appState.currentPosition.play(move));
          appState.notifyGameChanged();
        }
      } else if (update.setFen != null) {
        final position = Chess.fromSetup(Setup.parseFen(update.setFen!));
        appState.setCurrentPosition(position);
      }
    } catch (e) {
      debugPrint('[TacticsPanel] Board update failed: $e');
    }
  }

  void _applyPositionSetup(TacticsPositionSetup setup) {
    final appState = context.read<AppState>();
    try {
      final position = Chess.fromSetup(Setup.parseFen(setup.fen));
      appState.setCurrentPosition(position);
      appState.setBoardFlipped(setup.flipBoard);
    } catch (e) {
      setState(() {
        _session.feedback = 'Error loading position: $e';
      });
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _import.removeListener(_onImportChanged);
    _appState?.setMoveAttemptedCallback(null);
    _focusNode.dispose();
    _tabController.dispose();
    _lichessUserController.dispose();
    _lichessCountController.dispose();
    _chessComUserController.dispose();
    _chessComCountController.dispose();
    _stockfishDepthController.dispose();
    _coresController.dispose();
    _depthErrorTimer?.cancel();
    _coresErrorTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPositions() async {
    await _database.loadPositions();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Column(
        children: [
          // Tab bar
          TabBar(
            controller: _tabController,
            tabs: [
              const Tab(text: 'Tactic'),
              Tab(text: _session.currentPosition != null ? 'PGN' : 'Browse'),
            ],
          ),

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildTacticTab(),
                _session.currentPosition != null
                    ? _buildAnalysisTab()
                    : _buildBrowseTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // Only handle key-down events, and only during active training
    if (event is! KeyDownEvent || _session.currentPosition == null) {
      return KeyEventResult.ignored;
    }

    // Don't handle shortcuts when a text field has focus
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus != null && primaryFocus != _focusNode) {
      final context = primaryFocus.context;
      if (context != null) {
        final widget = context.widget;
        if (widget is EditableText) {
          return KeyEventResult.ignored;
        }
      }
    }

    final key = event.logicalKey;

    // Space — Toggle Solution
    if (key == LogicalKeyboardKey.space) {
      _session.toggleSolution();
      return KeyEventResult.handled;
    }

    // Left/Right arrow — PGN move navigation (works on both tabs)
    if (key == LogicalKeyboardKey.arrowRight) {
      _pgnViewerController.goForward();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _pgnViewerController.goBack();
      return KeyEventResult.handled;
    }

    // b — Previous position
    if (key == LogicalKeyboardKey.keyB) {
      _loadCurrentPosition(_session.previousPosition());
      return KeyEventResult.handled;
    }

    // n — Next / Skip position
    if (key == LogicalKeyboardKey.keyN) {
      _loadCurrentPosition(_session.skipPosition());
      return KeyEventResult.handled;
    }

    // a — Analyze / Reset (same as the combined button)
    if (key == LogicalKeyboardKey.keyA) {
      final appState = context.read<AppState>();
      final isAtStartingPosition =
          appState.currentPosition.fen == _session.currentPosition!.fen;
      if (isAtStartingPosition) {
        _onAnalyze();
      } else {
        _resetAnalysis();
      }
      return KeyEventResult.handled;
    }

    // Escape — Return to Tactic tab from PGN analysis
    if (key == LogicalKeyboardKey.escape) {
      if (_tabController.index != 0) {
        _tabController.animateTo(0);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  Widget _buildTacticTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_session.currentPosition != null)
            TacticsTrainingPanel(
              position: _session.currentPosition!,
              engine: _session.engine,
              currentMoveIndex: _session.currentMoveIndex,
              positionSolved: _session.positionSolved,
              showSolution: _session.showSolution,
              feedback: _session.feedback,
              autoAdvance: _session.autoAdvance,
              onToggleSolution: () => _session.toggleSolution(),
              onAnalyze: _onAnalyze,
              onResetAnalysis: _resetAnalysis,
              onPreviousPosition: () =>
                  _loadCurrentPosition(_session.previousPosition()),
              onSkipPosition: () =>
                  _loadCurrentPosition(_session.skipPosition()),
              onAutoAdvanceChanged: _session.setAutoAdvance,
              onCopyFen: _copyFen,
            )
          else
            TacticsImportPanel(
              importStatus: _import.importStatus,
              isImporting: _import.isImporting,
              activeImport: _import.activeImport,
              analyzedGameCount: _database.analyzedGameIds.length,
              lichessUserController: _lichessUserController,
              lichessCountController: _lichessCountController,
              chessComUserController: _chessComUserController,
              chessComCountController: _chessComCountController,
              stockfishDepthController: _stockfishDepthController,
              coresController: _coresController,
              depthError: _depthError,
              coresError: _coresError,
              importFieldsValid: _importFieldsValid,
              onValidateDepth: _validateDepth,
              onValidateCores: _validateCores,
              onImportLichess: _importLichess,
              onImportChessCom: _importChessCom,
              onDismissImportStatus: _import.dismissImportStatus,
              onCancelImport: _import.cancelImport,
              positionCount: _database.positions.length,
              onStartSession: _onStartSession,
              clearDatabaseEnabled: !_import.isImporting,
              onClearDatabase: _confirmClearDatabase,
              onBrowseTactics: () => _tabController.animateTo(1),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Analysis (PGN) tab
  // ---------------------------------------------------------------------------

  Widget _buildAnalysisTab() {
    if (_session.currentPosition == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('Load a tactics position to analyze'),
        ),
      );
    }

    final ctx = _session.parsePositionContext(
      _session.currentPosition!.positionContext,
    );

    return PgnWithEngine(
      key: ValueKey('analysis_${_session.currentPosition!.gameId}'),
      gameId: _session.currentPosition!.gameId,
      moveNumber: ctx.moveNumber,
      isWhiteToPlay: ctx.isWhiteToPlay,
      showStartEndButtons: false,
      controller: _pgnViewerController,
      onPositionChanged: (position) {
        // Skip if the board was already updated directly (e.g. from a board move)
        if (_skipNextPositionChanged) {
          _skipNextPositionChanged = false;
          return;
        }
        // Update the chess board when clicking moves in the PGN
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            final appState = context.read<AppState>();
            appState.setCurrentPosition(position);
          }
        });
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Browse tab
  // ---------------------------------------------------------------------------

  Widget _buildBrowseTab() {
    return TacticsBrowsePanel(
      positions: _database.positions,
      selectedFen: _session.currentPosition?.fen,
      onSelectTactic: _selectTacticFromBrowse,
      onDeleteTactic: _deleteTactic,
      onEditTactic: _showEditDialog,
      onClearAll: _confirmClearDatabase,
    );
  }

  void _selectTacticFromBrowse(int index) {
    final pos = _database.positions[index];
    try {
      final setup = _session.selectPosition(pos);
      if (setup != null) _applyPositionSetup(setup);
      _syncPgnToCurrentTactic();
      _focusNode.requestFocus();
    } catch (e) {
      debugPrint('Load position failed: $e');
      if (mounted) {
        showAppSnackBar(context, AppMessages.loadPositionFailed, isError: true);
      }
    }
  }

  void _deleteTactic(int index) async {
    final pos = _database.positions[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Tactic'),
        content: Text(
          'Delete this tactic?\n\n'
          '${pos.mistakeType} ${pos.gameWhite} vs ${pos.gameBlack}\n'
          '${pos.positionContext}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      _database.positions.removeAt(index);
      await _database.savePositions();
      setState(() {});
    }
  }

  void _confirmClearDatabase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Database'),
        content: Text(
          'Delete all ${_database.positions.length} tactics positions, '
          'imported PGNs, and analyzed-games history?\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      // Wipe everything: positions, analyzed-games list, and stored PGNs
      await _database.clearPositions();
      await _database.clearAnalyzedGames();
      await StorageFactory.instance.saveImportedPgns('');
      _session.endSession();
      _resetBoardToStart();
    }
  }

  Future<void> _showEditDialog(int index) async {
    final pos = _database.positions[index];

    final correctLineCtrl =
        TextEditingController(text: pos.correctLine.join(' | '));
    final mistakeTypeCtrl = TextEditingController(text: pos.mistakeType);
    final analysisCtrl = TextEditingController(text: pos.mistakeAnalysis);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit Tactic #${index + 1}'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Read-only context
                _readOnlyField('FEN', pos.fen),
                _readOnlyField('Game', '${pos.gameWhite} vs ${pos.gameBlack}'),
                _readOnlyField('Context', pos.positionContext),
                _readOnlyField('You Played', pos.userMove),
                _readOnlyField('Game ID', pos.gameId),
                if (pos.reviewCount > 0)
                  _readOnlyField('Stats',
                      '${pos.successCount}/${pos.reviewCount} (${(pos.successRate * 100).toStringAsFixed(0)}%)'),
                const SizedBox(height: 16),
                const Text('Editable fields',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),

                // Editable fields
                TextField(
                  controller: mistakeTypeCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Mistake Type',
                    hintText: '? or ??',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: correctLineCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Correct Line (pipe-separated)',
                    hintText: 'Nf3 | e4 | Bb5',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: analysisCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Analysis',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  maxLines: 3,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (saved == true && mounted) {
      final updated = pos.copyWith(
        correctLine: correctLineCtrl.text
            .split('|')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        mistakeType: mistakeTypeCtrl.text.trim(),
        mistakeAnalysis: analysisCtrl.text,
      );

      _database.positions[index] = updated;
      await _database.savePositions();
      setState(() {});
    }

    correctLineCtrl.dispose();
    mistakeTypeCtrl.dispose();
    analysisCtrl.dispose();
  }

  Widget _readOnlyField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text('$label:',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  /// Reset the board to the standard starting position (used when returning
  /// to the import screen so a stale tactic FEN isn't left on the board).
  void _resetBoardToStart() {
    final appState = context.read<AppState>();
    appState.setCurrentPosition(Chess.initial);
    appState.setBoardFlipped(false);
  }

  /// Re-sync the PGN viewer's highlighted move to the current tactic position.
  void _syncPgnToCurrentTactic() {
    if (_session.currentPosition == null) return;
    final ctx = _session.parsePositionContext(
      _session.currentPosition!.positionContext,
    );
    if (ctx.moveNumber != null) {
      _pgnViewerController.jumpToMove(
        ctx.moveNumber!,
        ctx.isWhiteToPlay ?? true,
      );
    }
  }

  void _resetAnalysis() {
    if (_session.currentPosition == null) return;

    _skipNextPositionChanged = true;
    _syncPgnToCurrentTactic();
    _skipNextPositionChanged = false;

    final setup = _session.resetPuzzleState();
    if (setup != null) _applyPositionSetup(setup);
  }

  void _validateDepth(String value) {
    final v = int.tryParse(value);
    String? error;
    if (v == null) {
      error = 'Must be a number';
    } else if (v < 1 || v > 25) {
      error = 'Must be 1–25';
    }

    _depthErrorTimer?.cancel();
    // Immediately update logical validity + clear error when valid.
    setState(() {
      _depthValid = error == null;
      if (error == null) _depthError = null;
    });
    // Debounce showing the red error text.
    if (error != null) {
      _depthErrorTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _depthError = error);
      });
    }
  }

  void _validateCores(String value) {
    final v = int.tryParse(value);
    final max = TacticsImportService.availableCores;
    String? error;
    if (v == null) {
      error = 'Must be a number';
    } else if (v < 1 || v > max) {
      error = 'Must be 1–$max';
    }

    _coresErrorTimer?.cancel();
    setState(() {
      _coresValid = error == null;
      if (error == null) _coresError = null;
    });
    if (error != null) {
      _coresErrorTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _coresError = error);
      });
    }
  }

  bool get _importFieldsValid => _depthValid && _coresValid;

  Future<void> _importLichess() => _runImport(TacticsImportSource.lichess, 'Lichess');

  Future<void> _importChessCom() =>
      _runImport(TacticsImportSource.chessCom, 'Chess.com');

  Future<void> _runImport(TacticsImportSource source, String platform) async {
    final username = source == TacticsImportSource.lichess
        ? _lichessUserController.text.trim()
        : _chessComUserController.text.trim();
    final count = int.tryParse(
          source == TacticsImportSource.lichess
              ? _lichessCountController.text
              : _chessComCountController.text,
        ) ??
        20;

    try {
      await _import.import(
        source: source,
        params: TacticsImportParams(
          username: username,
          maxGames: count,
          depth: (int.tryParse(_stockfishDepthController.text) ?? 15)
              .clamp(1, 25),
          cores: (int.tryParse(_coresController.text) ?? 1)
              .clamp(1, TacticsImportService.availableCores),
        ),
      );
    } on TacticsImportUsernameRequired {
      _showUsernameRequired(platform);
    } catch (e) {
      debugPrint('$platform import failed: $e');
      if (mounted) {
        _import.dismissImportStatus();
        showAppSnackBar(context, AppMessages.importFailed, isError: true);
      }
    }
  }

  void _onStartSession() {
    final setup = _session.startSession();
    if (setup == null) return;
    _loadPositionSetup(setup);
  }

  void _loadCurrentPosition(TacticsPositionSetup? setup) {
    if (setup == null) {
      _sessionComplete();
      return;
    }
    _loadPositionSetup(setup);
  }

  void _loadPositionSetup(TacticsPositionSetup setup) {
    _skipNextPositionChanged = true;
    _syncPgnToCurrentTactic();
    _skipNextPositionChanged = false;
    _applyPositionSetup(setup);
    _focusNode.requestFocus();
  }

  void _onAnalyze() {
    _tabController.animateTo(1);
  }

  Future<void> _copyFen() async {
    if (_session.currentPosition != null) {
      try {
        await Clipboard.setData(
          ClipboardData(text: _session.currentPosition!.fen),
        );
        if (mounted) {
          showAppSnackBar(context, AppMessages.fenCopied);
        }
      } catch (e) {
        debugPrint('Copy FEN failed: $e');
        if (mounted) {
          showAppSnackBar(context, AppMessages.clipboardWriteFailed,
              isError: true);
        }
      }
    }
  }

  void _onMoveAttempted(String moveUci) {
    if (_session.currentPosition == null) return;

    final appState = context.read<AppState>();

    if (appState.isAnalysisMode) {
      _addMoveToAnalysis(moveUci);
      return;
    }

    final update = _session.processMoveAttempt(
      moveUci: moveUci,
      boardFen: appState.currentPosition.fen,
      schedule: (delay, action) => Future.delayed(delay, action),
      isMounted: () => mounted,
    );
    if (update != null) _applyBoardUpdate(update);
  }

  void _addMoveToAnalysis(String moveUci) {
    final appState = context.read<AppState>();
    final position = appState.currentPosition;

    try {
      final move = Move.parse(moveUci);
      if (move == null) return;

      final (newPos, san) = position.makeSan(move);
      appState.setCurrentPosition(newPos);
      appState.notifyGameChanged();

      // Tell the PGN viewer about the move (for display only, skip board update)
      _skipNextPositionChanged = true;
      _pgnViewerController.addEphemeralMove(san);
    } catch (_) {
      // Failed to convert move to SAN
    }
  }

  void _sessionComplete() {
    _session.endSession();
    _resetBoardToStart();

    final session = _session.currentSession;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session Complete'),
        content: Text('Great work!\n\n'
            'Positions attempted: ${session.positionsAttempted}\n'
            'Correct: ${session.positionsCorrect}\n'
            'Incorrect: ${session.positionsIncorrect}\n'
            'Accuracy: ${(session.accuracy * 100).toStringAsFixed(1)}%'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showUsernameRequired(String platform) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Username Required'),
        content: Text('Please set your $platform username in Settings first.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

