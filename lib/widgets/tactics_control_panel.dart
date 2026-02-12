import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:chess/chess.dart' as chess;

import '../core/app_state.dart';
import '../models/tactics_position.dart';
import '../services/tactics_database.dart';
import '../services/tactics_engine.dart';
import '../services/tactics_import_service.dart';
import '../services/storage/storage_factory.dart';
import '../utils/fen_utils.dart';
import 'pgn_viewer_widget.dart';

/// Tactics training control panel with import, review, and analysis.
class TacticsControlPanel extends StatefulWidget {
  const TacticsControlPanel({super.key});

  @override
  State<TacticsControlPanel> createState() => _TacticsControlPanelState();
}

class _TacticsControlPanelState extends State<TacticsControlPanel>
    with TickerProviderStateMixin {

  // Core components
  late TacticsDatabase _database;
  late TacticsEngine _engine;

  // Tab controller
  late TabController _tabController;

  // State
  TacticsPosition? _currentPosition;
  bool _positionSolved = false;
  bool _attemptRecorded = false;
  bool _skipNextPositionChanged = false;
  DateTime? _startTime;
  String _feedback = '';
  bool _showSolution = false;
  bool _autoAdvance = true;  // Auto-advance setting (matches Python default)
  String? _importStatus;
  bool _isImporting = false;
  int _newPositionsFound = 0;

  // Multi-move tactic state
  int _currentMoveIndex = 0;      // Index into correctLine for next expected user move
  String? _currentTacticFen;      // Board FEN before the current user move (for reset)
  bool _waitingForOpponent = false; // True while opponent response is being animated

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
    _engine = TacticsEngine();
    _tabController = TabController(length: 2, vsync: this);

    _lichessUserController = TextEditingController();
    _lichessCountController = TextEditingController(text: '20');
    _chessComUserController = TextEditingController();
    _chessComCountController = TextEditingController(text: '20');
    _stockfishDepthController = TextEditingController(text: '15');
    // Default cores: host cores - 2 (leave headroom for OS + main isolate), min 1
    final defaultCores = (TacticsImportService.availableCores - 2).clamp(1, 8);
    _coresController = TextEditingController(text: '$defaultCores');

    // Initialize controllers from AppState and reset board
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final appState = context.read<AppState>();
        _lichessUserController.text = appState.lichessUsername ?? '';
        _chessComUserController.text = appState.chesscomUsername ?? '';
        
        context.read<AppState>().setMoveAttemptedCallback(_onMoveAttempted);
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
          // NOTE: Do NOT set _skipNextPositionChanged here — setCurrentGame
          // doesn't trigger the PGN viewer's onPositionChanged callback, so
          // the flag would linger and cause the next PGN navigation to
          // silently skip the board update.
          final fen = _pgnViewerController.currentFen;
          if (fen != null) {
            appState.setCurrentGame(chess.Chess.fromFEN(fen));
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
  void dispose() {
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
    final count = await _database.loadPositions();
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
              Tab(text: _currentPosition != null ? 'PGN' : 'Browse'),
            ],
          ),

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildTacticTab(),
                _currentPosition != null
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
    if (event is! KeyDownEvent || _currentPosition == null) {
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
      _toggleSolution();
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
      _onPreviousPosition();
      return KeyEventResult.handled;
    }

    // n — Next / Skip position
    if (key == LogicalKeyboardKey.keyN) {
      _onSkipPosition();
      return KeyEventResult.handled;
    }

    // a — Analyze / Reset (same as the combined button)
    if (key == LogicalKeyboardKey.keyA) {
      final appState = context.read<AppState>();
      final isAtStartingPosition = appState.currentGame.fen == _currentPosition!.fen;
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
          // Position info (like Python's position_info label)
          if (_currentPosition != null) ...[
            _buildPositionInfo(),
            const SizedBox(height: 16),
          ],

          // Import Status Message (hidden during active training to avoid distraction)
          if (_importStatus != null && _currentPosition == null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_importStatus!)),
                    ],
                  ),
                  if (_database.analyzedGameIds.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${_database.analyzedGameIds.length} games already analyzed (will be skipped)',
                      style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                    ),
                  ],
                ],
              ),
            ),
          ],

          // Action buttons
          if (_currentPosition != null) ...[
            // Top row: Solution, Analyze/Reset (context-aware)
            Row(
              children: [
                Expanded(
                  child: _shortcutTooltip(
                    message: 'space',
                    child: ElevatedButton(
                      onPressed: _toggleSolution,
                      child: Text(_showSolution ? 'Hide Solution' : 'Show Solution'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final appState = context.watch<AppState>();
                      final isAtStartingPosition = _positionSolved || appState.currentGame.fen == _currentPosition!.fen;
                      if (isAtStartingPosition) {
                        return _shortcutTooltip(
                          message: 'a',
                          child: ElevatedButton(
                            onPressed: _onAnalyze,
                            child: const Text('Analyze'),
                          ),
                        );
                      } else {
                        return _shortcutTooltip(
                          message: 'a',
                          child: ElevatedButton.icon(
                            onPressed: _resetAnalysis,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('Reset'),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Bottom row: Previous, Skip
            Row(
              children: [
                Expanded(
                  child: _shortcutTooltip(
                    message: 'b',
                    child: ElevatedButton(
                      onPressed: _onPreviousPosition,
                      child: const Text('Previous'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _shortcutTooltip(
                    message: 'n',
                    child: ElevatedButton(
                      onPressed: _onSkipPosition,
                      child: const Text('Skip'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            CheckboxListTile(
              value: _autoAdvance,
              onChanged: (value) {
                setState(() {
                  _autoAdvance = value ?? true;
                });
              },
              title: const Text('Auto-advance to next position'),
              contentPadding: EdgeInsets.zero,
            ),

            // Feedback + Solution area — stacked so they overlay in the same spot
            Stack(
              children: [
                // Solution — always laid out to reserve space (no bounce)
                Visibility(
                  visible: _showSolution && _feedback.isEmpty,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            'Solution: ${_engine.getSolution(_currentPosition!, fromIndex: _currentMoveIndex)}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 14,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _showSolution ? _copyFen : null,
                          child: const Text('Copy FEN'),
                        ),
                      ],
                    ),
                  ),
                ),
                // Feedback overlay — sits on top, same position
                if (_feedback.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _getFeedbackColor().withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _getFeedbackColor()),
                    ),
                    child: Text(
                      _feedback,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _getFeedbackColor(),
                        fontSize: 16,
                      ),
                    ),
                  ),
              ],
            ),
          ],

          // Import controls (shown when no active position)
          if (_currentPosition == null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Import Games', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    
                    // Lichess Row
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _lichessUserController,
                            decoration: const InputDecoration(
                              labelText: 'Lichess Username',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (value) {
                              context.read<AppState>().setLichessUsername(value);
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: _lichessCountController,
                            decoration: const InputDecoration(
                              labelText: 'Recent Games',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _importStatus == null && _importFieldsValid ? _importLichess : null,
                          child: const Text('Import'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Chess.com Row
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _chessComUserController,
                            decoration: const InputDecoration(
                              labelText: 'Chess.com Username',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (value) {
                              context.read<AppState>().setChesscomUsername(value);
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: _chessComCountController,
                            decoration: const InputDecoration(
                              labelText: 'Recent Games',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _importStatus == null && _importFieldsValid ? _importChessCom : null,
                          child: const Text('Import'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Stockfish Depth + Cores Row
                    Row(
                      children: [
                        SizedBox(
                          width: 140,
                          child: TextField(
                            controller: _stockfishDepthController,
                            decoration: InputDecoration(
                              labelText: 'Stockfish Depth',
                              border: const OutlineInputBorder(),
                              isDense: true,
                              errorText: _depthError,
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: _validateDepth,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 140,
                          child: TextField(
                            controller: _coresController,
                            enabled: TacticsImportService.isParallelAvailable,
                            decoration: InputDecoration(
                              labelText: 'Cores',
                              border: const OutlineInputBorder(),
                              isDense: true,
                              errorText: _coresError,
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: _validateCores,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Start Session Button - always show if positions exist (even during import)
            if (_database.positions.isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _onStartSession,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                    backgroundColor: _isImporting 
                        ? Colors.green[700] 
                        : Theme.of(context).colorScheme.primaryContainer,
                  ),
                  icon: Icon(_isImporting ? Icons.play_circle : Icons.play_arrow),
                  label: Text(
                    _isImporting 
                        ? 'Start Training Now (${_database.positions.length} positions)'
                        : 'Start Practice Session (${_database.positions.length} positions)',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            
            // Info text during import
            if (_isImporting && _database.positions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Colors.green, size: 16),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'You can start training now! New tactics will be added as they\'re found.',
                        style: TextStyle(fontSize: 12, color: Colors.green),
                      ),
                    ),
                  ],
                ),
              ),
            ],
              
            // Database management buttons (always visible, disabled when empty/importing)
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Tooltip(
                  message: _database.positions.isEmpty
                      ? 'No positions in database'
                      : _isImporting
                          ? 'Import in progress'
                          : '',
                  child: TextButton.icon(
                    onPressed: !_isImporting && _database.positions.isNotEmpty
                        ? _confirmClearDatabase
                        : null,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Clear Database'),
                  ),
                ),
                const SizedBox(width: 16),
                Tooltip(
                  message: _database.positions.isEmpty
                      ? 'No tactics to browse'
                      : '',
                  child: TextButton.icon(
                    onPressed: _database.positions.isNotEmpty
                        ? () => _tabController.animateTo(1)
                        : null,
                    icon: const Icon(Icons.list_alt, size: 16),
                    label: const Text('Browse Tactics'),
                  ),
                ),
              ],
            ),
          ],

        ],
      ),
    );
  }

  /// Tooltip styled for keyboard shortcut hints.
  /// Uses [_DelayedTooltip] so every button independently enforces its own
  /// wait duration (Flutter's built-in Tooltip skips the delay after one
  /// tooltip has already been shown).
  Widget _shortcutTooltip({required String message, required Widget child}) {
    return _DelayedTooltip(
      message: message,
      waitDuration: const Duration(seconds: 1),
      child: child,
    );
  }

  /// Build position info display
  Widget _buildPositionInfo() {
    if (_currentPosition == null) return const SizedBox();

    final pos = _currentPosition!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Context (Move X, Color to play)
        Text(
          pos.positionContext,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 12),

        // Game info
        Text('Game: ${pos.gameWhite} vs ${pos.gameBlack}', style: const TextStyle(fontSize: 14)),
        // TODO: figure out an elegant way to show success %
        // Text('Success: ${(pos.successRate * 100).toStringAsFixed(1)}%', style: const TextStyle(fontSize: 14)),

        // Show the move that was played and what it allows
        if (pos.userMove.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'You played: ${pos.userMove}${pos.mistakeType}',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          if (pos.opponentBestResponse.isNotEmpty)
            Text(
              'Allows: ${pos.opponentBestResponse}',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
        ],

        // Multi-move tactic indicator
        if (_engine.userMoveCount(pos) > 1) ...[
          const SizedBox(height: 4),
          Text(
            'Multi-move tactic (${_engine.userMoveCount(pos)} moves)',
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Analysis (PGN) tab
  // ---------------------------------------------------------------------------

  Widget _buildAnalysisTab() {
    if (_currentPosition == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('Load a tactics position to analyze'),
        ),
      );
    }

    // Extract move number and player to move from position context
    int? moveNumber;
    bool? isWhiteToPlay;

    final positionContext = _currentPosition!.positionContext;
    final match = RegExp(r'Move (\d+)').firstMatch(positionContext);
    if (match != null) {
      moveNumber = int.tryParse(match.group(1)!);
      isWhiteToPlay = positionContext.contains('White');
    }

    return PgnViewerWidget(
      key: ValueKey('analysis_${_currentPosition!.gameId}'),
      gameId: _currentPosition!.gameId,
      moveNumber: moveNumber,
      isWhiteToPlay: isWhiteToPlay,
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
            final chessGame = chess.Chess.fromFEN(position.fen);
            appState.setCurrentGame(chessGame);
          }
        });
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Browse tab
  // ---------------------------------------------------------------------------

  Widget _buildBrowseTab() {
    if (_database.positions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text(
            'No tactics found yet.\nImport games to discover tactical positions.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      children: [
        // Header bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Text(
                '${_database.positions.length} tactics',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _confirmClearDatabase,
                icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                label: const Text('Clear All', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Column headers
        _buildBrowseHeader(),
        const Divider(height: 1),

        // Scrollable list of tactics
        Expanded(
          child: ListView.builder(
            itemCount: _database.positions.length,
            itemBuilder: (context, index) => _buildBrowseRow(index),
          ),
        ),
      ],
    );
  }

  Widget _buildBrowseHeader() {
    const headerStyle = TextStyle(
      fontWeight: FontWeight.bold,
      fontSize: 12,
      color: Colors.grey,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: const [
          SizedBox(width: 72), // space for action icons
          SizedBox(width: 32, child: Text('Type', style: headerStyle)),
          SizedBox(width: 8),
          Expanded(flex: 3, child: Text('Game', style: headerStyle)),
          SizedBox(width: 8),
          Expanded(flex: 2, child: Text('Context', style: headerStyle)),
          SizedBox(width: 8),
          Expanded(flex: 2, child: Text('Played → Best', style: headerStyle)),
          SizedBox(width: 8),
          SizedBox(width: 60, child: Text('Stats', style: headerStyle, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _buildBrowseRow(int index) {
    final pos = _database.positions[index];
    final isSelected = _currentPosition != null && _currentPosition!.fen == pos.fen;

    return InkWell(
      onTap: () => _selectTacticFromBrowse(index),
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3)
              : (index.isEven ? Colors.transparent : Colors.white.withValues(alpha: 0.02)),
          border: Border(
            bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            // Delete button
            IconButton(
              onPressed: () => _deleteTactic(index),
              icon: Icon(Icons.close, size: 16, color: Colors.red.withValues(alpha: 0.6)),
              tooltip: 'Delete tactic',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
            // Edit button
            IconButton(
              onPressed: () => _showEditDialog(index),
              icon: const Icon(Icons.edit, size: 16),
              tooltip: 'Edit tactic',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
            const SizedBox(width: 4),

            // Type badge
            SizedBox(
              width: 32,
              child: Text(
                pos.mistakeType,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: pos.mistakeType == '??' ? Colors.red : Colors.orange,
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Game (players)
            Expanded(
              flex: 3,
              child: Text(
                '${pos.gameWhite} vs ${pos.gameBlack}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),

            // Context (move number & color)
            Expanded(
              flex: 2,
              child: Text(
                pos.positionContext,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),

            // Played → Best
            Expanded(
              flex: 2,
              child: Text(
                '${pos.userMove} → ${pos.bestMove}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(width: 8),

            // Stats
            SizedBox(
              width: 60,
              child: Text(
                pos.reviewCount > 0
                    ? '${pos.successCount}/${pos.reviewCount} ${(pos.successRate * 100).toStringAsFixed(0)}%'
                    : 'new',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 12,
                  color: pos.reviewCount == 0
                      ? Colors.grey
                      : pos.successRate >= 0.7
                          ? Colors.green
                          : pos.successRate >= 0.4
                              ? Colors.orange
                              : Colors.red,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _selectTacticFromBrowse(int index) {
    final pos = _database.positions[index];
    try {
      final appState = context.read<AppState>();
      final game = chess.Chess.fromFEN(pos.fen);
      appState.setCurrentGame(game);

      // Orient the board to the side that's to move
      final isWhiteToMove = pos.positionContext.contains('White');
      appState.setBoardFlipped(!isWhiteToMove);

      setState(() {}); // refresh highlight
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading position: $e')),
        );
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
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
      setState(() {
        _currentPosition = null;
      });
      _resetBoardToStart();
    }
  }

  Future<void> _showEditDialog(int index) async {
    final pos = _database.positions[index];

    final correctLineCtrl = TextEditingController(text: pos.correctLine.join(' | '));
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
                  _readOnlyField('Stats', '${pos.successCount}/${pos.reviewCount} (${(pos.successRate * 100).toStringAsFixed(0)}%)'),
                const SizedBox(height: 16),
                const Text('Editable fields', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
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
            child: Text('$label:', style: const TextStyle(color: Colors.grey, fontSize: 12)),
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
    appState.setCurrentGame(chess.Chess());
    appState.setBoardFlipped(false);
  }


  /// Re-sync the PGN viewer's highlighted move to the current tactic position.
  void _syncPgnToCurrentTactic() {
    if (_currentPosition == null) return;
    final ctx = _currentPosition!.positionContext;
    final match = RegExp(r'Move (\d+)').firstMatch(ctx);
    if (match != null) {
      final moveNumber = int.tryParse(match.group(1)!);
      final isWhiteToPlay = ctx.contains('White');
      if (moveNumber != null) {
        _pgnViewerController.jumpToMove(moveNumber, isWhiteToPlay);
      }
    }
  }

  void _resetAnalysis() {
    if (_currentPosition == null) return;
    
    // Clear ephemeral moves and re-sync PGN highlight to tactic position.
    // Skip the redundant board update — we set the board explicitly below.
    _skipNextPositionChanged = true;
    _syncPgnToCurrentTactic();
    _skipNextPositionChanged = false;
    
    // Reset the board to the initial tactic position
    final appState = context.read<AppState>();
    final game = chess.Chess.fromFEN(_currentPosition!.fen);
    appState.setCurrentGame(game);
    
    // Reset solved state, feedback, and multi-move tracking
    setState(() {
      _positionSolved = false;
      _feedback = '';
      _showSolution = false;
      _startTime = DateTime.now();
      _currentMoveIndex = 0;
      _currentTacticFen = _currentPosition!.fen;
      _waitingForOpponent = false;
    });
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

  /// True when both Stockfish depth and cores fields pass validation.
  bool get _importFieldsValid => _depthValid && _coresValid;

  Color _getFeedbackColor() {
    if (_feedback.contains('Correct')) return Colors.green;
    return Colors.red;
  }

  Future<void> _importLichess() async {
    final importService = TacticsImportService();
    final username = _lichessUserController.text.trim();
    final count = int.tryParse(_lichessCountController.text) ?? 20;
    final depth = (int.tryParse(_stockfishDepthController.text) ?? 15).clamp(1, 25);
    final cores = (int.tryParse(_coresController.text) ?? 1).clamp(1, TacticsImportService.availableCores);

    if (username.isEmpty) {
      _showUsernameRequired('Lichess');
      return;
    }

    setState(() {
      _importStatus = 'Initializing...';
      _isImporting = true;
      _newPositionsFound = 0;
    });

    try {
      // Initialize the import service (loads analyzed game IDs)
      await importService.initialize();
      
      final positions = await importService.importGamesFromLichess(
        username,
        maxGames: count,
        depth: depth,
        maxCores: cores,
        progressCallback: (msg) {
          if (mounted) setState(() => _importStatus = msg);
        },
        onPositionFound: (position) {
          // Add position to database immediately for live training
          _database.addPosition(position);
          if (mounted) {
            setState(() {
              _newPositionsFound++;
            });
          }
        },
      );

      await _handleImportResults(positions);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _importStatus = null;
          _isImporting = false;
        });
      }
    }
  }

  Future<void> _importChessCom() async {
    final importService = TacticsImportService();
    final username = _chessComUserController.text.trim();
    final count = int.tryParse(_chessComCountController.text) ?? 20;
    final depth = (int.tryParse(_stockfishDepthController.text) ?? 15).clamp(1, 25);
    final cores = (int.tryParse(_coresController.text) ?? 1).clamp(1, TacticsImportService.availableCores);

    if (username.isEmpty) {
      _showUsernameRequired('Chess.com');
      return;
    }

    setState(() {
      _importStatus = 'Initializing...';
      _isImporting = true;
      _newPositionsFound = 0;
    });

    try {
      // Initialize the import service (loads analyzed game IDs)
      await importService.initialize();
      
      final positions = await importService.importGamesFromChessCom(
        username,
        maxGames: count,
        depth: depth,
        maxCores: cores,
        progressCallback: (msg) {
          if (mounted) setState(() => _importStatus = msg);
        },
        onPositionFound: (position) {
          // Add position to database immediately for live training
          _database.addPosition(position);
          if (mounted) {
            setState(() {
              _newPositionsFound++;
            });
          }
        },
      );

      await _handleImportResults(positions);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _importStatus = null;
          _isImporting = false;
        });
      }
    }
  }
  
  Future<void> _handleImportResults(List<TacticsPosition> _) async {
    await _loadPositions();
    
    if (mounted) {
      if (_newPositionsFound == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No new blunders found. Games may have already been analyzed.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added $_newPositionsFound new tactics positions')),
        );
      }
      setState(() {});
    }
  }

  void _onStartSession() {
    _database.startSession();
    if (_database.positions.isEmpty) return;
    _showCurrentPosition();
  }

  /// Show whatever position is at _database.sessionPositionIndex
  void _showCurrentPosition() {
    if (_database.positions.isEmpty) {
      _sessionComplete();
      return;
    }

    // Wrap index
    _database.sessionPositionIndex %= _database.positions.length;
    final position = _database.positions[_database.sessionPositionIndex];

    setState(() {
      _currentPosition = position;
      _positionSolved = false;
      _attemptRecorded = false;
      _startTime = DateTime.now();
      _feedback = '';
      _showSolution = false;
      _currentMoveIndex = 0;
      _currentTacticFen = position.fen;
      _waitingForOpponent = false;
    });

    // Re-sync PGN viewer to the new tactic position.
    // Skip the redundant board update from the PGN viewer's onPositionChanged
    // callback — we set the board explicitly below.
    _skipNextPositionChanged = true;
    _syncPgnToCurrentTactic();
    _skipNextPositionChanged = false;

    // Set up the chess board
    try {
      final appState = context.read<AppState>();
      final game = chess.Chess.fromFEN(position.fen);
      appState.setCurrentGame(game);

      // Set board orientation based on side to move
      final isWhiteToMove = position.positionContext.contains('White');
      appState.setBoardFlipped(!isWhiteToMove);
    } catch (e) {
      setState(() {
        _feedback = 'Error loading position: $e';
      });
    }

    // Re-grab keyboard focus for shortcuts
    _focusNode.requestFocus();
  }

  void _onPreviousPosition() {
    if (_database.positions.isEmpty) return;
    _database.sessionPositionIndex--;
    if (_database.sessionPositionIndex < 0) {
      _database.sessionPositionIndex = _database.positions.length - 1;
    }
    _showCurrentPosition();
  }

  void _onSkipPosition() {
    if (_database.positions.isEmpty) return;
    _database.sessionPositionIndex++;
    _showCurrentPosition();
  }

  void _toggleSolution() {
    setState(() {
      _showSolution = !_showSolution;
      if (_showSolution) _feedback = '';
    });
  }

  /// Refresh _currentPosition from the database so displayed stats are up to date
  void _refreshCurrentPosition() {
    if (_currentPosition == null) return;
    final index = _database.positions.indexWhere((p) => p.fen == _currentPosition!.fen);
    if (index != -1) {
      setState(() {
        _currentPosition = _database.positions[index];
      });
    }
  }

  void _onAnalyze() {
    _tabController.animateTo(1);
  }

  Future<void> _copyFen() async {
    if (_currentPosition != null) {
      try {
        await Clipboard.setData(ClipboardData(text: _currentPosition!.fen));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('FEN copied to clipboard')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to copy FEN')),
          );
        }
      }
    }
  }

  void _onMoveAttempted(String moveUci) {
    if (_currentPosition == null) return;

    final appState = context.read<AppState>();

    // In analysis mode, just add the move to the PGN editor
    if (appState.isAnalysisMode) {
      _addMoveToAnalysis(moveUci);
      return;
    }

    // In tactic mode, validate the move
    if (_positionSolved || _waitingForOpponent) return;

    // Only validate when the board is at the expected tactic position.
    // If the user navigated away (e.g. via PGN viewer), ignore the move.
    final fen = _currentTacticFen ?? _currentPosition!.fen;
    if (normalizeFen(appState.currentGame.fen) != normalizeFen(fen)) return;

    final result = _engine.checkMoveAtIndex(
      _currentPosition!,
      moveUci,
      fen,
      _currentMoveIndex,
    );
    final timeTaken = _startTime != null
        ? DateTime.now().difference(_startTime!).inMilliseconds / 1000.0
        : 0.0;

    if (result == TacticsResult.correct) {
      _handleCorrectMove(timeTaken, moveUci: moveUci);
    } else {
      _handleIncorrectMove(timeTaken, moveUci: moveUci);
    }
  }

  void _addMoveToAnalysis(String moveUci) {
    final appState = context.read<AppState>();
    final game = appState.currentGame;

    try {
      final from = moveUci.substring(0, 2);
      final to = moveUci.substring(2, 4);
      String? promotion;
      if (moveUci.length > 4) promotion = moveUci.substring(4);

      final moves = game.moves({'verbose': true});

      final match = moves.firstWhere(
        (m) => m['from'] == from && m['to'] == to &&
               (promotion == null || m['promotion'] == promotion),
        orElse: () => <String, dynamic>{},
      );

      if (match.isNotEmpty && match['san'] != null) {
        // Apply move to existing game object for smooth animation
        final moveMap = <String, String?>{'from': from, 'to': to};
        if (promotion != null) moveMap['promotion'] = promotion;
        game.move(moveMap);
        appState.notifyGameChanged();

        // Tell the PGN viewer about the move (for display only, skip board update)
        _skipNextPositionChanged = true;
        _pgnViewerController.addEphemeralMove(match['san'] as String);
      }
    } catch (e) {
      // Failed to convert move to SAN
    }
  }

  void _handleCorrectMove(double timeTaken, {String? moveUci}) {
    // Apply the correct move to the board so it's visually shown
    if (moveUci != null) {
      final appState = context.read<AppState>();
      final game = appState.currentGame;
      final from = moveUci.substring(0, 2);
      final to = moveUci.substring(2, 4);
      String? promotion;
      if (moveUci.length > 4) promotion = moveUci.substring(4, 5);

      final moveMap = <String, String?>{'from': from, 'to': to};
      if (promotion != null) moveMap['promotion'] = promotion;
      game.move(moveMap);
      appState.notifyGameChanged();
    }

    _currentMoveIndex++; // Advance past the user's move

    final totalUserMoves = _engine.userMoveCount(_currentPosition!);
    final completedUserMoves = (_currentMoveIndex + 1) ~/ 2;

    // Check if there's an opponent response to play next
    if (_currentMoveIndex < _currentPosition!.correctLine.length &&
        _currentMoveIndex % 2 == 1) {
      // Intermediate correct move — show brief feedback and queue opponent response
      setState(() {
        _waitingForOpponent = true;
        _feedback = totalUserMoves > 1
            ? 'Correct! ($completedUserMoves/$totalUserMoves)'
            : 'Correct!';
      });

      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted || _currentPosition == null) return;

        // Play the opponent's response from the correct line
        final appState = context.read<AppState>();
        final game = appState.currentGame;
        final opponentSan = _currentPosition!.correctLine[_currentMoveIndex];
        game.move(opponentSan);
        appState.notifyGameChanged();

        _currentMoveIndex++; // Advance past the opponent's move
        _currentTacticFen = game.fen; // Save FEN for reset on wrong answer

        // Edge case: PV ended right after opponent (even-length line)
        if (_currentMoveIndex >= _currentPosition!.correctLine.length) {
          _completeTactic(timeTaken);
          return;
        }

        setState(() {
          _feedback = '';
          _waitingForOpponent = false;
        });
      });
    } else {
      // All user moves completed — tactic solved!
      _completeTactic(timeTaken);
    }
  }

  /// Mark the tactic as fully solved, record the attempt, and auto-advance.
  void _completeTactic(double timeTaken) {
    setState(() {
      _positionSolved = true;
      _waitingForOpponent = false;
      _feedback = 'Correct!';
    });

    // Only record on first attempt per position encounter (binary: first-try = success)
    if (!_attemptRecorded) {
      _attemptRecorded = true;
      _database.recordAttempt(
        _currentPosition!,
        TacticsResult.correct,
        timeTaken,
      ).then((_) {
        if (mounted) {
          _refreshCurrentPosition();
        }
      });
    }

    // Auto-advance or enable skip button
    if (_autoAdvance) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && _positionSolved) {
          _onSkipPosition();
        }
      });
    }
  }

  void _handleIncorrectMove(double timeTaken, {String? moveUci}) {
    // Apply the incorrect move on the board so the user sees it briefly
    if (moveUci != null && _currentPosition != null) {
      final appState = context.read<AppState>();
      final game = appState.currentGame;
      final from = moveUci.substring(0, 2);
      final to = moveUci.substring(2, 4);
      String? promotion;
      if (moveUci.length > 4) promotion = moveUci.substring(4, 5);

      final moveMap = <String, String?>{'from': from, 'to': to};
      if (promotion != null) moveMap['promotion'] = promotion;
      game.move(moveMap);
      appState.notifyGameChanged();
    }

    setState(() {
      _feedback = 'Incorrect';
    });

    // Only record on first attempt per position encounter (binary: first-try wrong = failure)
    if (!_attemptRecorded && _currentPosition != null) {
      _attemptRecorded = true;
      _database.recordAttempt(
        _currentPosition!,
        TacticsResult.incorrect,
        timeTaken,
      ).then((_) {
        if (mounted) {
          _refreshCurrentPosition();
        }
      });
    }

    // After a brief moment, reset the board to the current tactic position
    // (for multi-move tactics this is where the current user move should be,
    // not necessarily the original FEN)
    if (_currentPosition != null) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted && _currentPosition != null) {
          try {
            final appState = context.read<AppState>();
            final fen = _currentTacticFen ?? _currentPosition!.fen;
            final game = chess.Chess.fromFEN(fen);
            appState.setCurrentGame(game);
          } catch (e) {
            // Handle error
          }
          setState(() {
            _feedback = '';
          });
        }
      });
    }
  }

  void _sessionComplete() {
    setState(() {
      _currentPosition = null;
    });
    _resetBoardToStart();

    final session = _database.currentSession;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session Complete'),
        content: Text(
          'Great work!\n\n'
          'Positions attempted: ${session.positionsAttempted}\n'
          'Correct: ${session.positionsCorrect}\n'
          'Incorrect: ${session.positionsIncorrect}\n'
          'Accuracy: ${(session.accuracy * 100).toStringAsFixed(1)}%'
        ),
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

/// A tooltip that **always** waits [waitDuration] before appearing, even when
/// the user moves quickly between tooltipped widgets.  Flutter's built-in
/// [Tooltip] has a global warm-up that skips the delay after one tooltip was
/// recently shown; this widget avoids that by managing its own hover timer and
/// overlay entry independently.
class _DelayedTooltip extends StatefulWidget {
  const _DelayedTooltip({
    required this.message,
    required this.waitDuration,
    required this.child,
  });

  final String message;
  final Duration waitDuration;
  final Widget child;

  @override
  State<_DelayedTooltip> createState() => _DelayedTooltipState();
}

class _DelayedTooltipState extends State<_DelayedTooltip>
    with SingleTickerProviderStateMixin {
  OverlayEntry? _overlayEntry;
  Timer? _showTimer;
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
  }

  @override
  void dispose() {
    _hideTooltip();
    _fadeController.dispose();
    super.dispose();
  }

  void _onEnter(PointerEvent _) {
    _showTimer?.cancel();
    _showTimer = Timer(widget.waitDuration, _showTooltip);
  }

  void _onExit(PointerEvent _) {
    _showTimer?.cancel();
    _showTimer = null;
    _hideTooltip();
  }

  void _showTooltip() {
    if (!mounted) return;
    _overlayEntry?.remove();

    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    _overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: offset.dx + size.width / 2 - _estimateWidth(widget.message) / 2,
        top: offset.dy + size.height + 4,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: IgnorePointer(
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(_overlayEntry!);
    _fadeController.forward(from: 0);
  }

  void _hideTooltip() {
    _fadeController.reset();
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  double _estimateWidth(String text) {
    // Rough estimate so the tooltip is roughly centred.
    return text.length * 8.0 + 16;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      child: widget.child,
    );
  }
}











