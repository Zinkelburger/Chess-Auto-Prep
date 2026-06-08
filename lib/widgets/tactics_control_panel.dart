import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:dartchess/dartchess.dart';

import '../core/app_state.dart';
import '../models/engine_settings.dart';
import '../models/tactics_session_settings.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/maia_factory.dart';
import '../services/tactics/tactics_import_coordinator.dart';
import '../services/tactics/tactics_session_controller.dart';
import '../services/tactics_database.dart';
import '../services/tactics_import_service.dart';
import '../services/storage/storage_factory.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import 'engine/inline_engine_bar.dart';
import 'pgn_viewer_widget.dart';
import 'pgn_with_engine.dart';
import 'tactics/tactics_browse_panel.dart';
import 'tactics/tactics_import_panel.dart';
import 'tactics/tactics_training_panel.dart';

class _ToggleInlineEngineIntent extends Intent {
  const _ToggleInlineEngineIntent();
}

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
  final PgnViewerWidgetController _pgnViewerController = PgnViewerWidgetController();

  /// Current arrow-key position in the solution line (-1 = at tactic start).
  int _solutionNavIndex = -1;

  /// Cached SAN solution for the current position so we don't recompute.
  List<String> _solutionSanCache = const [];

  /// FEN for which the ephemeral solution has already been seeded into the PGN.
  String? _solutionSeededForFen;

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
          _focusNode.requestFocus();
        } else {
          appState.exitAnalysisMode();
        }
      }
    });

    // Auto-load positions on startup
    _loadPositions();

    // Pre-warm Stockfish pool + Maia so imports start instantly.
    _warmUpEngines();
  }

  /// Fire-and-forget: spawn Stockfish workers and load the Maia ONNX model
  /// while the user is still looking at the import form.
  Future<void> _warmUpEngines() async {
    final pool = StockfishPool();
    final targetWorkers = EngineSettings().workers;
    await pool.ensureWorkers(targetWorkers);
    // Maia init is cheap after the first call (singleton).
    if (MaiaFactory.isAvailable) {
      try {
        await MaiaFactory.instance?.initialize();
      } catch (_) {}
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState ??= context.read<AppState>();
  }

  void _onSessionChanged() {
    if (mounted) {
      // When solution is toggled on, seed ephemeral moves into PGN once.
      if (_session.showSolution && _session.currentPosition != null) {
        _ensureSolutionSeeded();
      }
      setState(() {});
    }
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
      if (update.san != null) {
        _pgnViewerController.addEphemeralMove(update.san!);
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

  bool _isTextInputFocused() {
    final primaryFocus = FocusManager.instance.primaryFocus;
    return primaryFocus?.context?.widget is EditableText;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyE): _ToggleInlineEngineIntent(),
      },
      child: Actions(
        actions: {
          _ToggleInlineEngineIntent: CallbackAction<_ToggleInlineEngineIntent>(
            onInvoke: (_) {
              if (_session.currentPosition == null || _isTextInputFocused()) {
                return null;
              }
              InlineEngineBar.toggleEngine();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _focusNode.requestFocus(),
            child: Column(
              children: [
                TabBar(
                  controller: _tabController,
                  tabs: [
                    const Tab(text: 'Tactic'),
                    Tab(
                      text: _session.currentPosition != null ? 'PGN' : 'Browse',
                    ),
                  ],
                ),
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
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // Only handle key-down events, and only during active training
    if (event is! KeyDownEvent || _session.currentPosition == null) {
      return KeyEventResult.ignored;
    }

    if (_isTextInputFocused()) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    // Space — Toggle Solution
    if (key == LogicalKeyboardKey.space) {
      _session.toggleSolution();
      return KeyEventResult.handled;
    }

    // Left/Right arrow — navigate solution on Tactic tab, PGN on Analysis tab
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_tabController.index == 0 && _session.showSolution) {
        _solutionArrowForward();
      } else {
        _pgnViewerController.goForward();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_tabController.index == 0 && _session.showSolution) {
        _solutionArrowBack();
      } else {
        _pgnViewerController.goBack();
      }
      return KeyEventResult.handled;
    }

    // p — Previous position
    if (key == LogicalKeyboardKey.keyP) {
      _loadCurrentPosition(_session.previousPosition());
      return KeyEventResult.handled;
    }

    // n — Next / Skip position
    if (key == LogicalKeyboardKey.keyN) {
      _loadCurrentPosition(_session.skipPosition());
      return KeyEventResult.handled;
    }

    // j — Toggle auto-advance to next position
    if (key == LogicalKeyboardKey.keyJ) {
      _session.setAutoAdvance(!_session.autoAdvance);
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

    // 1-5 — Rate tactic (only after solve / show solution)
    if (_session.positionSolved || _session.showSolution) {
      int? star;
      if (key == LogicalKeyboardKey.digit1) star = 1;
      if (key == LogicalKeyboardKey.digit2) star = 2;
      if (key == LogicalKeyboardKey.digit3) star = 3;
      if (key == LogicalKeyboardKey.digit4) star = 4;
      if (key == LogicalKeyboardKey.digit5) star = 5;
      if (star != null) {
        final current = _session.currentPosition?.rating ?? 0;
        _session.setRating(current == star ? 0 : star);
        setState(() {});
        return KeyEventResult.handled;
      }
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
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final current = _session.currentPosition;
        final isAtStartingPosition = current == null ||
            _session.positionSolved ||
            appState.currentPosition.fen == current.fen;

        final ctx = current != null
            ? _session.parsePositionContext(current.positionContext)
            : (moveNumber: null, isWhiteToPlay: null);
        final solutionStartPly = ctx.moveNumber != null
            ? (ctx.moveNumber! - 1) * 2 + ((ctx.isWhiteToPlay ?? true) ? 0 : 1)
            : 0;
        final solutionSan = _session.showSolution && current != null
            ? _solutionSanCache.isNotEmpty
                ? _solutionSanCache
                : _session.engine.solutionLineToSan(current)
            : const <String>[];

        return SingleChildScrollView(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (current != null)
                TacticsTrainingPanel(
                  position: current,
                  engine: _session.engine,
                  currentMoveIndex: _session.currentMoveIndex,
                  positionSolved: _session.positionSolved,
                  isAtStartingPosition: isAtStartingPosition,
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
                  onSetRating: (rating) {
                    _session.setRating(rating);
                    setState(() {});
                  },
                  solutionSanMoves: solutionSan,
                  solutionStartPly: solutionStartPly,
                  activeSolutionMoveIndex:
                      _solutionNavIndex >= 0 ? _solutionNavIndex : null,
                  onSolutionMoveTapped: solutionSan.isNotEmpty
                      ? _onSolutionLineMoveTapped
                      : null,
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
                  positions: _database.positions,
                  onStartSession: _onStartSession,
                  clearDatabaseEnabled: !_import.isImporting,
                  onClearDatabase: _confirmClearDatabase,
                  onBrowseTactics: () => _tabController.animateTo(1),
                ),
            ],
          ),
        );
      },
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
        if (_tabController.index != 1) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _tabController.index != 1) return;
          final appState = context.read<AppState>();
          final pgnFen = normalizeFen(position.fen);
          final boardFen = normalizeFen(appState.currentPosition.fen);
          if (pgnFen == boardFen) return;
          appState.setCurrentPosition(position);
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
      onSetRating: (index, rating) async {
        final pos = _database.positions[index];
        await _database.setRating(pos.fen, rating);
        if (mounted) setState(() {});
      },
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

    _resetSolutionState();
    final setup = _session.resetPuzzleState();
    if (setup != null) _applyPositionSetup(setup);
    _syncPgnToCurrentTactic();
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

  void _onStartSession(TacticsSessionSettings settings) {
    final setup = _session.startSession(settings);
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
    _resetSolutionState();
    _applyPositionSetup(setup);
    _syncPgnToCurrentTactic();
    _focusNode.requestFocus();
  }

  // ─── Solution navigation ───────────────────────────────────────────────

  void _resetSolutionState() {
    _solutionNavIndex = -1;
    _solutionSanCache = const [];
    _solutionSeededForFen = null;
  }

  /// Seed the full solution as an ephemeral variation in the PGN viewer once
  /// per position. Subsequent Show Solution toggles / arrow presses reuse it.
  void _ensureSolutionSeeded() {
    final tactic = _session.currentPosition;
    if (tactic == null) return;
    if (_solutionSeededForFen == tactic.fen) return;

    final san = _session.engine.solutionLineToSan(tactic);
    if (san.isEmpty) return;

    _solutionSanCache = san;
    _solutionSeededForFen = tactic.fen;
    _solutionNavIndex = -1;

    _syncPgnToCurrentTactic();
    for (final move in san) {
      _pgnViewerController.addEphemeralMove(move);
    }
    for (int i = 0; i < san.length; i++) {
      _pgnViewerController.goBack();
    }
  }

  void _solutionArrowForward() {
    final san = _solutionSanCache;
    if (san.isEmpty) return;
    if (_solutionNavIndex >= san.length - 1) return;

    _solutionNavIndex++;
    _navigateSolutionBoard(_solutionNavIndex);
    _pgnViewerController.goForward();
    setState(() {});
  }

  void _solutionArrowBack() {
    if (_solutionNavIndex < 0) return;

    _solutionNavIndex--;
    _navigateSolutionBoard(_solutionNavIndex);
    _pgnViewerController.goBack();
    setState(() {});
  }

  /// Click handler: jump from wherever we are to [clickedIndex].
  void _onSolutionLineMoveTapped(List<String> sanMoves, int clickedIndex) {
    if (sanMoves.isEmpty || clickedIndex < 0) return;

    _ensureSolutionSeeded();

    final delta = clickedIndex - _solutionNavIndex;
    if (delta > 0) {
      for (int i = 0; i < delta; i++) {
        _pgnViewerController.goForward();
      }
    } else if (delta < 0) {
      for (int i = 0; i < -delta; i++) {
        _pgnViewerController.goBack();
      }
    }

    _solutionNavIndex = clickedIndex;
    _navigateSolutionBoard(clickedIndex);
    setState(() {});
  }

  /// Set the board position to the state after playing solution moves 0..index
  /// (or to the tactic start when index < 0).
  void _navigateSolutionBoard(int index) {
    final tactic = _session.currentPosition;
    if (tactic == null) return;

    try {
      Position pos = Chess.fromSetup(Setup.parseFen(tactic.fen));
      final san = _solutionSanCache;
      for (int i = 0; i <= index && i < san.length; i++) {
        final move = pos.parseSan(san[i]);
        if (move == null) break;
        pos = pos.play(move);
      }
      final appState = context.read<AppState>();
      appState.setCurrentPosition(pos);
    } catch (e) {
      debugPrint('[TacticsPanel] Solution board nav failed: $e');
    }
  }

  void _onAnalyze() {
    _tabController.animateTo(1);
    _focusNode.requestFocus();
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

    String? moveSan;
    try {
      final move = Move.parse(moveUci);
      if (move != null) {
        final (_, san) = appState.currentPosition.makeSan(move);
        moveSan = san;
      }
    } catch (_) {}

    final prevIndex = _session.currentMoveIndex;
    final update = _session.processMoveAttempt(
      moveUci: moveUci,
      boardFen: appState.currentPosition.fen,
      schedule: (delay, action) => Future.delayed(delay, action),
      isMounted: () => mounted,
    );
    if (update != null) {
      _applyBoardUpdate(update);
      if (moveSan != null && _session.currentMoveIndex > prevIndex) {
        _pgnViewerController.addEphemeralMove(moveSan);
      }
    }
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
      _pgnViewerController.addEphemeralMove(san);
    } catch (_) {}
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

