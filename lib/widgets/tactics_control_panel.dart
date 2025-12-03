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

/// Tactics training control panel - Flutter port of Python's TacticsWidget
/// Matches all features: position history, auto-advance, full stats, etc.
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
  DateTime? _startTime;
  String _feedback = '';
  bool _showSolution = false;
  bool _autoAdvance = true;  // Auto-advance setting (matches Python default)
  String? _importStatus;

  // Import controllers
  late TextEditingController _lichessUserController;
  late TextEditingController _lichessCountController;
  late TextEditingController _chessComUserController;
  late TextEditingController _chessComCountController;
  late TextEditingController _stockfishDepthController;

  // PGN Viewer controller for analysis tab
  final PgnViewerController _pgnViewerController = PgnViewerController();

  // Position history (for Previous button)
  final List<TacticsPosition> _positionHistory = [];
  int _historyIndex = -1;

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
    return Column(
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
    );
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

          // Feedback label (like Python)
          if (_feedback.isNotEmpty) ...[
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
            const SizedBox(height: 16),
          ],
          
          // Import Status Message
          if (_importStatus != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_importStatus!)),
                ],
              ),
            ),
          ],

          // Solution display (like Python's solution_widget)
          if (_showSolution && _currentPosition != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
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
                        onPressed: _copyFen,
                        child: const Text('Copy FEN'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Action buttons (like Python's action buttons)
          if (_currentPosition != null) ...[
            // Top row: Solution, Analyze
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _showSolution ? null : _onShowSolution,
                    child: const Text('Show Solution'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _onAnalyze,
                    child: const Text('Analyze'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Bottom row: Previous, Skip
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _historyIndex > 0 ? _onPreviousPosition : null,
                    child: const Text('Previous Position'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: !_autoAdvance || _positionSolved ? _onSkipPosition : null,
                    child: const Text('Skip Position'),
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
                          width: 80,
                          child: TextField(
                            controller: _lichessCountController,
                            decoration: const InputDecoration(
                              labelText: 'Games',
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
                          width: 80,
                          child: TextField(
                            controller: _chessComCountController,
                            decoration: const InputDecoration(
                              labelText: 'Games',
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

            // Start Session Button
            if (_database.positions.isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _onStartSession,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(
                    'Start Practice Session (${_database.positions.length} positions found)',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              
            if (_database.positions.isNotEmpty) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  _database.clearPositions().then((_) => setState(() {}));
                },
                child: const Text('Clear Database'),
              ),
            ],
          ],

          // Session stats (like Python)
          if (_database.currentSession.positionsAttempted > 0) ...[
            const SizedBox(height: 16),
            Text(
              'Session: ${_database.currentSession.positionsCorrect}/${_database.currentSession.positionsAttempted} '
              '(${(_database.currentSession.accuracy * 100).toStringAsFixed(1)}%)',
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ],
      ),
    );
  }

  /// Build position info display - matches Python's _update_position_info
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
        Text('Difficulty: ${pos.difficulty}/5', style: const TextStyle(fontSize: 14)),
        Text('Success rate: ${(pos.successRate * 100).toStringAsFixed(1)}%', style: const TextStyle(fontSize: 14)),
        Text('Reviews: ${pos.reviewCount}', style: const TextStyle(fontSize: 14)),

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
        // Use addPostFrameCallback to avoid setState during build
        print('TacticsControlPanel: onPositionChanged called with FEN: ${position.fen}');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            final appState = context.read<AppState>();
            final chessGame = chess.Chess.fromFEN(position.fen);
            print('TacticsControlPanel: Updating appState.currentGame');
            appState.setCurrentGame(chessGame);
          }
        });
      },
    );
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
      _importStatus = 'Starting import...';
      appState.setLoading(true);
    });

    try {
      final positions = await importService.importGamesFromLichess(
        username,
        maxGames: count,
        depth: depth,
        progressCallback: (msg) {
          if (mounted) setState(() => _importStatus = msg);
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
      _importStatus = 'Starting import...';
      appState.setLoading(true);
    });

    try {
      final positions = await importService.importGamesFromChessCom(
        username,
        maxGames: count,
        depth: depth,
        progressCallback: (msg) {
          if (mounted) setState(() => _importStatus = msg);
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
          appState.setLoading(false);
        });
      }
    }
  }
  
  Future<void> _handleImportResults(List<TacticsPosition> positions) async {
    if (positions.isEmpty) {
       if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No blunders found in recent games.')),
        );
      }
    } else {
      // Save to CSV database
      await _database.importAndSave(positions);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Generated ${positions.length} tactics positions')),
        );
        setState(() {});
      }
    }
  }

  void _onStartSession() {
    _database.startSession();
    _positionHistory.clear();
    _historyIndex = -1;
    _loadNextPosition();
  }

  void _loadNextPosition() {
    final positions = _database.getPositionsForReview(1);
    if (positions.isEmpty) {
      _sessionComplete();
      return;
    }

    final position = positions[0];

    // Add to history (only if we're not navigating backwards)
    if (_historyIndex == _positionHistory.length - 1) {
      _positionHistory.add(position);
      _historyIndex = _positionHistory.length - 1;
    } else {
      // We went back and then forward, update from this point
      _historyIndex++;
      if (_historyIndex >= _positionHistory.length) {
        _positionHistory.add(position);
        _historyIndex = _positionHistory.length - 1;
      }
    }

    setState(() {
      _currentPosition = position;
      _positionSolved = false;
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
  }

  void _onPreviousPosition() {
    if (_historyIndex <= 0) return;

    _historyIndex--;
    final position = _positionHistory[_historyIndex];

    setState(() {
      _currentPosition = position;
      _positionSolved = false;
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

      final isWhiteToMove = position.positionContext.contains('White');
      appState.setBoardFlipped(!isWhiteToMove);
    } catch (e) {
      setState(() {
        _feedback = 'Error loading position: $e';
      });
    }
  }

  void _onSkipPosition() {
    _loadNextPosition();
  }

  void _onShowSolution() {
    setState(() {
      _showSolution = true;
    });
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
      _handleCorrectMove(timeTaken);
    } else {
      _handleIncorrectMove(timeTaken);
    }
  }
  
  void _addMoveToAnalysis(String moveUci) {
    print('TacticsControlPanel: _addMoveToAnalysis called with UCI="$moveUci"');
    
    // Convert UCI to SAN for the PGN viewer
    final appState = context.read<AppState>();
    final game = appState.currentGame;
    
    print('TacticsControlPanel: Current game FEN: ${game.fen}');
    
    try {
      final from = moveUci.substring(0, 2);
      final to = moveUci.substring(2, 4);
      String? promotion;
      if (moveUci.length > 4) promotion = moveUci.substring(4);
      
      print('TacticsControlPanel: Looking for move from=$from to=$to promotion=$promotion');
      
      // Find the move in legal moves to get SAN
      final moves = game.moves({'verbose': true});
      print('TacticsControlPanel: Legal moves count: ${moves.length}');
      
      final match = moves.firstWhere(
        (m) => m['from'] == from && m['to'] == to && 
               (promotion == null || m['promotion'] == promotion),
        orElse: () => <String, dynamic>{},
      );
      
      if (match.isNotEmpty && match['san'] != null) {
        final san = match['san'] as String;
        print('TacticsControlPanel: Found SAN="$san", calling addEphemeralMove');
        
        // Add to the PGN viewer as an ephemeral move
        _pgnViewerController.addEphemeralMove(san);
      } else {
        print('TacticsControlPanel: ERROR - Could not find matching move!');
        print('TacticsControlPanel: Available moves: ${moves.map((m) => "${m['from']}${m['to']}").toList()}');
      }
    } catch (e) {
      print('TacticsControlPanel: Error adding move to analysis: $e');
    }
  }

  void _handleCorrectMove(double timeTaken) {
    setState(() {
      _positionSolved = true;
      _feedback = 'Correct!';
    });

    // Record the attempt
    _database.recordAttempt(
      _currentPosition!,
      TacticsResult.correct,
      timeTaken,
    );

    // Auto-advance or enable skip button
    if (_autoAdvance) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && _positionSolved) {
          _loadNextPosition();
        }
      });
    }

    // Update session stats display
    setState(() {});
  }

  void _handleIncorrectMove(double timeTaken) {
    setState(() {
      _feedback = 'Incorrect';
    });

    // Reset the board to original position
    if (_currentPosition != null) {
      try {
        final appState = context.read<AppState>();
        final game = chess.Chess.fromFEN(_currentPosition!.fen);
        appState.setCurrentGame(game);
      } catch (e) {
        // Handle error
      }
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
