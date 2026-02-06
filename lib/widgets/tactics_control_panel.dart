import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:chess/chess.dart' as chess;

import '../core/app_state.dart';
import '../models/tactics_position.dart';
import '../services/tactics_database.dart';
import '../services/tactics_engine.dart';
import '../services/tactics_import_service.dart';
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
  DateTime? _startTime;
  String _feedback = '';
  bool _showSolution = false;
  bool _autoAdvance = true;  // Auto-advance setting (matches Python default)
  String? _importStatus;
  bool _isImporting = false;
  int _newPositionsFound = 0;

  // Import controllers
  late TextEditingController _lichessUserController;
  late TextEditingController _lichessCountController;
  late TextEditingController _chessComUserController;
  late TextEditingController _chessComCountController;
  late TextEditingController _stockfishDepthController;

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

    // Initialize controllers from AppState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final appState = context.read<AppState>();
        _lichessUserController.text = appState.lichessUsername ?? '';
        _chessComUserController.text = appState.chesscomUsername ?? '';
        
        context.read<AppState>().setMoveAttemptedCallback(_onMoveAttempted);
      }
    });

    // Listen for tab changes to enter/exit analysis mode
    _tabController.addListener(() {
      if (mounted) {
        final appState = context.read<AppState>();
        if (_tabController.index == 1) {
          appState.enterAnalysisMode();
        } else {
          appState.exitAnalysisMode();
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
            tabs: const [
              Tab(text: 'Tactic'),
              Tab(text: 'PGN'),
            ],
          ),

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildTacticTab(),
                _buildAnalysisTab(),
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
                      final isAtStartingPosition = appState.currentGame.fen == _currentPosition!.fen;
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
                            'Solution: ${_engine.getSolution(_currentPosition!)}',
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
                          onPressed: _importStatus == null ? _importLichess : null,
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
                          onPressed: _importStatus == null ? _importChessCom : null,
                          child: const Text('Import'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Stockfish Depth Row
                    Row(
                      children: [
                        SizedBox(
                          width: 140,
                          child: TextField(
                            controller: _stockfishDepthController,
                            decoration: const InputDecoration(
                              labelText: 'Stockfish Depth',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            keyboardType: TextInputType.number,
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
                  color: Colors.green.withOpacity(0.1),
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
              
            // Database management buttons - always show when not importing
            if (!_isImporting) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_database.positions.isNotEmpty)
                    TextButton(
                      onPressed: () {
                        _database.clearPositions().then((_) => setState(() {}));
                      },
                      child: const Text('Clear Database'),
                    ),
                  if (_database.positions.isNotEmpty)
                    const SizedBox(width: 16),
                  TextButton(
                    onPressed: () async {
                      await _database.clearAnalyzedGames();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Cleared analyzed games history. Games will be re-analyzed on next import.')),
                        );
                        setState(() {});
                      }
                    },
                    child: Text('Reset Analyzed Games${_database.analyzedGameIds.isNotEmpty ? " (${_database.analyzedGameIds.length})" : ""}'),
                  ),
                ],
              ),
            ],
          ],

        ],
      ),
    );
  }

  /// Tooltip styled for keyboard shortcut hints
  Widget _shortcutTooltip({required String message, required Widget child}) {
    return Tooltip(
      message: message,
      waitDuration: const Duration(seconds: 1),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(4),
      ),
      textStyle: const TextStyle(
        color: Colors.white,
        fontSize: 12,
      ),
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

        // Show the move that was played
        if (pos.userMove.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'You played: ${pos.userMove}',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ],
    );
  }

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
      controller: _pgnViewerController,
      onPositionChanged: (position) {
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

  void _resetAnalysis() {
    if (_currentPosition == null) return;
    
    // Clear ephemeral moves in the PGN viewer
    _pgnViewerController.clearEphemeralMoves();
    
    // Reset the board to the initial tactic position
    final appState = context.read<AppState>();
    final game = chess.Chess.fromFEN(_currentPosition!.fen);
    appState.setCurrentGame(game);
    
    // Reset solved state and feedback
    setState(() {
      _positionSolved = false;
      _feedback = '';
      _showSolution = false;
      _startTime = DateTime.now();
    });
  }

  Color _getFeedbackColor() {
    if (_feedback.contains('Correct')) return Colors.green;
    return Colors.red;
  }

  Future<void> _importLichess() async {
    final appState = context.read<AppState>();
    final importService = TacticsImportService();
    final username = _lichessUserController.text.trim();
    final count = int.tryParse(_lichessCountController.text) ?? 20;
    final depth = (int.tryParse(_stockfishDepthController.text) ?? 15).clamp(1, 25);

    if (username.isEmpty) {
      _showUsernameRequired('Lichess');
      return;
    }

    setState(() {
      _importStatus = 'Initializing...';
      _isImporting = true;
      _newPositionsFound = 0;
      appState.setLoading(true);
    });

    try {
      // Initialize the import service (loads analyzed game IDs)
      await importService.initialize();
      
      final positions = await importService.importGamesFromLichess(
        username,
        maxGames: count,
        depth: depth,
        progressCallback: (msg) {
          if (mounted) setState(() => _importStatus = '$msg • Found $_newPositionsFound tactics');
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
          appState.setLoading(false);
        });
      }
    }
  }

  Future<void> _importChessCom() async {
    final appState = context.read<AppState>();
    final importService = TacticsImportService();
    final username = _chessComUserController.text.trim();
    final count = int.tryParse(_chessComCountController.text) ?? 20;
    final depth = (int.tryParse(_stockfishDepthController.text) ?? 15).clamp(1, 25);

    if (username.isEmpty) {
      _showUsernameRequired('Chess.com');
      return;
    }

    setState(() {
      _importStatus = 'Initializing...';
      _isImporting = true;
      _newPositionsFound = 0;
      appState.setLoading(true);
    });

    try {
      // Initialize the import service (loads analyzed game IDs)
      await importService.initialize();
      
      final positions = await importService.importGamesFromChessCom(
        username,
        maxGames: count,
        depth: depth,
        progressCallback: (msg) {
          if (mounted) setState(() => _importStatus = '$msg • Found $_newPositionsFound tactics');
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
          appState.setLoading(false);
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
    });

    // Reset ephemeral moves in the PGN viewer
    _pgnViewerController.clearEphemeralMoves();

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
    if (_positionSolved) return;

    // Use TacticsEngine for proper move validation
    final result = _engine.checkMove(_currentPosition!, moveUci);
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

    setState(() {
      _positionSolved = true;
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

    // After a brief moment, reset the board and clear feedback
    if (_currentPosition != null) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted && _currentPosition != null) {
          try {
            final appState = context.read<AppState>();
            final game = chess.Chess.fromFEN(_currentPosition!.fen);
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
