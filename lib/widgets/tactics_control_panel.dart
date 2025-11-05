import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:chess/chess.dart' as chess;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../core/app_state.dart';
import '../models/tactics_position.dart';
import '../models/position_analysis.dart';
import '../services/tactics_database.dart';
import '../services/tactics_engine.dart';
import '../services/tactics_service.dart';
import '../services/fen_map_builder.dart';
import 'pgn_viewer_widget.dart';
import 'position_analysis_widget.dart';

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

  // Position history (for Previous button)
  final List<TacticsPosition> _positionHistory = [];
  int _historyIndex = -1;

  // Position analysis state
  PositionAnalysis? _positionAnalysis;
  bool _isAnalyzing = false;

  @override
  void initState() {
    super.initState();
    _database = TacticsDatabase();
    _engine = TacticsEngine();
    _tabController = TabController(length: 3, vsync: this);

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

    // Register move validation callback
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().setMoveAttemptedCallback(_onMoveAttempted);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadPositions() async {
    final count = await _database.loadPositions();
    if (count == 0 && mounted) {
      setState(() {});
    } else if (count > 0 && mounted) {
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
            Tab(text: 'Analysis'),
            Tab(text: 'Weak Positions'),
          ],
        ),

        // Tab content
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildTacticTab(),
              _buildAnalysisTab(),
              _buildPositionAnalysisTab(),
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
                color: _getFeedbackColor().withOpacity(0.1),
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
          ],

          // Settings (like Python's auto-advance checkbox)
          if (_currentPosition != null) ...[
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
            const SizedBox(height: 16),
          ],

          // Session controls (like Python)
          if (_currentPosition == null) ...[
            if (_database.positions.isEmpty) ...[
              Text(
                'No tactics positions found.\n\nUse the button below to load tactics from Lichess.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _onLoadTactics,
                icon: const Icon(Icons.psychology),
                label: const Text('Load Tactics from Lichess'),
              ),
            ] else ...[
              Text(
                '${_database.positions.length} tactics positions available.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _onStartSession,
                child: const Text('Start Practice Session'),
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

        // Mistake analysis (if available)
        if (pos.mistakeAnalysis.isNotEmpty) ...[
          Text(
            pos.mistakeAnalysis,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 12),
        ] else ...[
          Text(
            'Mistake: ${pos.mistakeType}',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 12),
        ],

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
      gameId: _currentPosition!.gameId,
      moveNumber: moveNumber,
      isWhiteToPlay: isWhiteToPlay,
      onPositionChanged: (position) {
        // Update the chess board when clicking moves in the PGN
        try {
          if (mounted) {
            final appState = context.read<AppState>();
            final chessGame = chess.Chess.fromFEN(position.fen);
            appState.setCurrentGame(chessGame);
          }
        } catch (e) {
          // Handle conversion error
        }
      },
    );
  }

  Color _getFeedbackColor() {
    if (_feedback.contains('Correct')) return Colors.green;
    if (_feedback.contains('partial') || _feedback.contains('good')) {
      return Colors.orange;
    }
    return Colors.red;
  }

  Future<void> _onLoadTactics() async {
    final appState = context.read<AppState>();
    final tacticsService = TacticsService();

    if (appState.chesscomUsername == null) {
      _showUsernameRequired();
      return;
    }

    setState(() => appState.setLoading(true));

    try {
      final positions = await tacticsService.generateTacticsFromLichess(
        appState.chesscomUsername!,
      );

      // Save to CSV database
      await _database.importAndSave(positions);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Loaded ${positions.length} tactics positions')),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load tactics: $e')),
        );
      }
    } finally {
      setState(() => appState.setLoading(false));
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
    if (_currentPosition == null || _positionSolved) return;

    // Use TacticsEngine for proper move validation
    final result = _engine.checkMove(_currentPosition!, moveUci);
    final timeTaken = _startTime != null
        ? DateTime.now().difference(_startTime!).inMilliseconds / 1000.0
        : 0.0;

    if (result == TacticsResult.correct) {
      _handleCorrectMove(timeTaken);
    } else if (result == TacticsResult.partial) {
      _handlePartialMove();
    } else {
      _handleIncorrectMove(timeTaken);
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

  void _handlePartialMove() {
    setState(() {
      _feedback = 'Good move, but not the best. Try again!';
    });
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

  void _showUsernameRequired() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Username Required'),
        content: const Text('Please set your Chess.com username in Settings first.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Build Position Analysis tab - matches Python's PositionAnalysisMode
  Widget _buildPositionAnalysisTab() {
    if (_isAnalyzing) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Analyzing weak positions...'),
          ],
        ),
      );
    }

    return PositionAnalysisWidget(
      analysis: _positionAnalysis,
      onAnalyze: _analyzeWeakPositions,
    );
  }

  /// Analyze weak positions from imported games - matches Python's game_analysis.py
  Future<void> _analyzeWeakPositions() async {
    final appState = context.read<AppState>();

    if (appState.chesscomUsername == null) {
      _showUsernameRequired();
      return;
    }

    setState(() => _isAnalyzing = true);

    try {
      // Load imported games from file
      final directory = await getApplicationDocumentsDirectory();
      final pgnFile = File('${directory.path}/imported_games.pgn');

      if (!await pgnFile.exists()) {
        if (mounted) {
          _showError('No imported games found. Please import games first.');
        }
        return;
      }

      final content = await pgnFile.readAsString();
      final pgnList = _splitPgnIntoGames(content);

      if (pgnList.isEmpty) {
        if (mounted) {
          _showError('No games found in imported_games.pgn');
        }
        return;
      }

      // Show color selection dialog
      final userIsWhite = await _showColorSelectionDialog();
      if (userIsWhite == null) return; // User cancelled

      // Build FEN map
      final fenBuilder = FenMapBuilder();
      await fenBuilder.processPgns(
        pgnList,
        appState.chesscomUsername!,
        userIsWhite,
      );

      // Create position analysis
      final analysis = await FenMapBuilder.fromFenMapBuilder(
        fenBuilder,
        pgnList,
      );

      if (mounted) {
        setState(() {
          _positionAnalysis = analysis;
          _isAnalyzing = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Found ${analysis.positionStats.length} positions to analyze',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to analyze positions: $e');
        setState(() => _isAnalyzing = false);
      }
    }
  }

  Future<bool?> _showColorSelectionDialog() async {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Color'),
        content: const Text('Which color do you want to analyze?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('White'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Black'),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  List<String> _splitPgnIntoGames(String content) {
    final games = <String>[];
    final lines = content.split('\n');

    String currentGame = '';
    bool inGame = false;

    for (final line in lines) {
      if (line.startsWith('[Event')) {
        if (inGame && currentGame.isNotEmpty) {
          games.add(currentGame);
        }
        currentGame = '$line\n';
        inGame = true;
      } else if (inGame) {
        currentGame += '$line\n';
      }
    }

    if (inGame && currentGame.isNotEmpty) {
      games.add(currentGame);
    }

    return games;
  }
}
