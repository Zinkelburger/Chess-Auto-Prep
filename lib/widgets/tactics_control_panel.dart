import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:chess/chess.dart' as chess;

import '../core/app_state.dart';
import '../models/tactics_position.dart';
import '../services/tactics_service.dart';
import 'pgn_viewer_widget.dart';

class TacticsControlPanel extends StatefulWidget {
  const TacticsControlPanel({super.key});

  @override
  State<TacticsControlPanel> createState() => _TacticsControlPanelState();
}

class _TacticsControlPanelState extends State<TacticsControlPanel>
    with TickerProviderStateMixin {

  late TabController _tabController;
  TacticsPosition? _currentPosition;
  bool _positionSolved = false;
  DateTime? _startTime;
  String _feedback = '';
  bool _showSolution = false;
  int _sessionCorrect = 0;
  int _sessionAttempted = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    // Listen for tab changes to enter/exit analysis mode
    _tabController.addListener(() {
      if (mounted) {
        final appState = context.read<AppState>();
        if (_tabController.index == 1) {
          // Analysis tab
          appState.enterAnalysisMode();
        } else {
          // Tactic tab
          appState.exitAnalysisMode();
        }
      }
    });

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
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Position info
          if (_currentPosition != null) ...[
            Text(
              _currentPosition!.positionContext,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text('Game: ${_currentPosition!.gameWhite} vs ${_currentPosition!.gameBlack}'),
            const SizedBox(height: 16),
          ],

          // Show the move that was actually played in the game
          if (_currentPosition != null && _currentPosition!.userMove.isNotEmpty) ...[
            Text(
              'You played: ${_currentPosition!.userMove}',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
          ],

          // Feedback
          if (_feedback.isNotEmpty) ...[
            Text(
              _feedback,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: _feedback == 'Correct!' ? Colors.green : Colors.red,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
          ],

          // Solution display
          if (_showSolution && _currentPosition != null) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Solution: ${_currentPosition!.correctLine.join(', ')}',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: Container()),
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

          // Action buttons
          if (_currentPosition != null) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _showSolution ? null : _onShowSolution,
                  child: const Text('Show Solution'),
                ),
                ElevatedButton(
                  onPressed: _onAnalyze,
                  child: const Text('Analyze'),
                ),
                ElevatedButton(
                  onPressed: _onSkipPosition,
                  child: const Text('Skip Position'),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // Session controls (only show when no active session)
          if (_currentPosition == null) ...[
            ElevatedButton(
              onPressed: _onStartSession,
              child: const Text('Start Practice Session'),
            ),
            const SizedBox(height: 16),
            // Load tactics button
            ElevatedButton.icon(
              onPressed: _onLoadTactics,
              icon: const Icon(Icons.psychology),
              label: const Text('Load Tactics'),
            ),
          ],

          // Stats (show during session)
          if (_sessionAttempted > 0) ...[
            Text(
              'Session: $_sessionCorrect/$_sessionAttempted (${(_sessionCorrect / _sessionAttempted * 100).toStringAsFixed(1)}%)',
              style: const TextStyle(fontSize: 12),
            ),
          ],

          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildAnalysisTab() {
    if (_currentPosition == null) {
      return const Padding(
        padding: EdgeInsets.all(8.0),
        child: Center(
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
            // Convert Position to chess.Chess for the app state
            final chessGame = chess.Chess.fromFEN(position.fen);
            appState.setCurrentGame(chessGame);
          }
        } catch (e) {
          // Handle conversion error
        }
      },
    );
  }

  void _onLoadTactics() async {
    final appState = context.read<AppState>();
    final tacticsService = TacticsService();

    if (appState.chesscomUsername == null) {
      _showUsernameRequired();
      return;
    }

    appState.setLoading(true);
    try {
      final positions = await tacticsService.generateTacticsFromLichess(
        appState.chesscomUsername!,
      );
      appState.setTacticsPositions(positions);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded ${positions.length} tactics positions')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load tactics: $e')),
      );
    } finally {
      appState.setLoading(false);
    }
  }

  void _onStartSession() {
    final appState = context.read<AppState>();
    if (appState.tacticsPositions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tactics positions loaded. Click "Load Tactics" first.')),
      );
      return;
    }

    _sessionCorrect = 0;
    _sessionAttempted = 0;
    _loadNextPosition();
  }

  void _loadNextPosition() {
    final appState = context.read<AppState>();
    if (appState.tacticsPositions.isEmpty || appState.currentPosition == null) {
      _sessionComplete();
      return;
    }

    setState(() {
      _currentPosition = appState.currentPosition;
      _positionSolved = false;
      _startTime = DateTime.now();
      _feedback = '';
      _showSolution = false;
    });

    // Set up the chess board with the position
    try {
      final game = chess.Chess.fromFEN(_currentPosition!.fen);
      appState.setCurrentGame(game);
    } catch (e) {
      setState(() {
        _feedback = 'Error loading position: $e';
      });
    }
  }

  void _sessionComplete() {
    setState(() {
      _currentPosition = null;
    });

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session Complete'),
        content: Text(
          'Great work!\n\n'
          'Positions attempted: $_sessionAttempted\n'
          'Correct: $_sessionCorrect\n'
          'Accuracy: ${_sessionAttempted > 0 ? (_sessionCorrect / _sessionAttempted * 100).toStringAsFixed(1) : 0}%'
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

  void _onShowSolution() {
    setState(() {
      _showSolution = true;
    });
  }

  void _onAnalyze() {
    _tabController.animateTo(1);
  }

  void _onSkipPosition() {
    _sessionAttempted++;
    final appState = context.read<AppState>();
    appState.removeCurrentTacticsPosition();
    _loadNextPosition();
  }

  void _copyFen() async {
    if (_currentPosition != null) {
      try {
        // Copy FEN to clipboard
        await Clipboard.setData(ClipboardData(text: _currentPosition!.fen));

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('FEN copied to clipboard')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to copy FEN to clipboard')),
          );
        }
      }
    }
  }

  void _onMoveAttempted(String moveUci) {
    if (_currentPosition == null || _positionSolved) return;

    // Check if the move matches any of the correct moves
    bool isCorrect = _validateMove(moveUci);

    setState(() {
      if (isCorrect) {
        _feedback = 'Correct!';
        _positionSolved = true;
        _sessionCorrect++;
        _sessionAttempted++;

        // Auto-advance after a delay
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            final appState = context.read<AppState>();
            appState.removeCurrentTacticsPosition();
            _loadNextPosition();
          }
        });
      } else {
        _feedback = 'Incorrect. Try again!';

        // Reset the board to the original position
        try {
          final game = chess.Chess.fromFEN(_currentPosition!.fen);
          context.read<AppState>().setCurrentGame(game);
        } catch (e) {
          // Handle error
        }
      }
    });
  }

  bool _validateMove(String moveUci) {
    if (_currentPosition == null) return false;

    print('=== TACTICS CONTROL PANEL MOVE VALIDATION ===');
    print('UCI move: "$moveUci"');
    print('Expected correct line: ${_currentPosition!.correctLine}');
    print('Expected best move: "${_currentPosition!.bestMove}"');

    // SIMPLE CHECK: Just check if the target square matches like Python does
    if (moveUci.length >= 4) {
      final targetSquare = moveUci.substring(2, 4); // e.g., "c7" from "d8c7"
      print('Target square: "$targetSquare"');

      for (final correctMove in _currentPosition!.correctLine) {
        // Extract target square from SAN move, accounting for +, #, etc.
        final cleanMove = correctMove.replaceAll(RegExp(r'[+#!?]'), ''); // Remove annotations

        // Extract the target square (last 2 chars after cleaning)
        if (cleanMove.length >= 2) {
          final expectedTarget = cleanMove.substring(cleanMove.length - 2);
          print('Checking "$targetSquare" == "$expectedTarget" from "$correctMove" (cleaned: "$cleanMove")');

          if (targetSquare.toLowerCase() == expectedTarget.toLowerCase()) {
            print('✓ MATCH: Target squares match');
            return true;
          }
        }
      }
    }

    print('✗ NO MATCH');
    print('===============================');
    return false;
  }

  bool _movesMatch(String moveSan, String correctMove) {
    // Remove annotations and compare
    final cleanMoveSan = moveSan.replaceAll(RegExp(r'[+#!?]+'), '');
    final cleanCorrectMove = correctMove.replaceAll(RegExp(r'[+#!?]+'), '');

    print('  _movesMatch: "$moveSan" -> "$cleanMoveSan" vs "$correctMove" -> "$cleanCorrectMove"');
    final result = cleanMoveSan.toLowerCase() == cleanCorrectMove.toLowerCase();
    print('  _movesMatch result: $result');

    return result;
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
}