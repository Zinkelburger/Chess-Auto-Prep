/// Chessable-style repertoire training screen
/// User makes moves on board that must match the PGN mainline
library;

import 'package:flutter/material.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess/chess.dart' as chess;

import '../models/repertoire_line.dart';
import '../services/repertoire_service.dart';
import '../widgets/chess_board_widget.dart';

enum TrainingResult { correct, incorrect, skipped }

class TrainingSession {
  final List<TrainingQuestion> questions;
  final Map<String, TrainingResult> results = {};
  int currentQuestionIndex = 0;

  TrainingSession(this.questions);

  TrainingQuestion get currentQuestion => questions[currentQuestionIndex];
  bool get isComplete => currentQuestionIndex >= questions.length;
  int get totalQuestions => questions.length;
  int get questionsAnswered => results.length;
  int get correctAnswers => results.values.where((r) => r == TrainingResult.correct).length;
}

class RepertoireTrainingScreen extends StatefulWidget {
  final Map<String, dynamic> repertoire;

  const RepertoireTrainingScreen({
    super.key,
    required this.repertoire,
  });

  @override
  State<RepertoireTrainingScreen> createState() => _RepertoireTrainingScreenState();
}

class _RepertoireTrainingScreenState extends State<RepertoireTrainingScreen> {
  final RepertoireService _repertoireService = RepertoireService();

  TrainingSession? _session;
  Position _currentPosition = Chess.initial;
  chess.Chess _displayGame = chess.Chess();
  bool _isLoading = true;
  String? _error;
  String? _feedback;
  bool _showingCorrectAnswer = false;

  @override
  void initState() {
    super.initState();
    _initializeTraining();
  }

  Future<void> _initializeTraining() async {
    setState(() => _isLoading = true);

    try {
      final filePath = widget.repertoire['filePath'] as String;
      final lines = await _repertoireService.parseRepertoireFile(filePath);

      if (lines.isEmpty) {
        setState(() {
          _error = 'No trainable lines found in repertoire';
          _isLoading = false;
        });
        return;
      }

      // Create training questions from all lines
      final questions = _repertoireService.createTrainingQuestions(lines);

      if (questions.isEmpty) {
        setState(() {
          _error = 'No training questions could be generated';
          _isLoading = false;
        });
        return;
      }

      // Shuffle for variety
      final shuffledQuestions = _repertoireService.shuffleQuestions(questions);

      setState(() {
        _session = TrainingSession(shuffledQuestions);
        _isLoading = false;
        _loadCurrentQuestion();
      });

    } catch (e) {
      setState(() {
        _error = 'Error loading repertoire: $e';
        _isLoading = false;
      });
    }
  }

  void _loadCurrentQuestion() {
    if (_session == null || _session!.isComplete) return;

    final question = _session!.currentQuestion;
    setState(() {
      _currentPosition = question.position;
      _displayGame = _createChessGameFromPosition(question.position);
      _feedback = null;
      _showingCorrectAnswer = false;
    });
  }

  /// Helper to convert dartchess Position to chess package Chess game
  chess.Chess _createChessGameFromPosition(Position position) {
    final game = chess.Chess();
    game.load(position.fen);
    return game;
  }

  void _handleUserMove(CompletedMove moveData) {
    if (_session == null || _session!.isComplete || _showingCorrectAnswer) return;

    final question = _session!.currentQuestion;
    final userMoveUci = moveData.uci;

    try {
      // Parse user move to SAN for comparison
      final userMove = _currentPosition.parseSan(moveData.san);
      if (userMove == null) return;

      final userMoveSan = moveData.san;

      // Check if the move is correct
      if (question.validateMove(userMoveSan)) {
        _handleCorrectMove();
      } else {
        _handleIncorrectMove();
      }
    } catch (e) {
      // Invalid move, ignore
    }
  }

  void _handleCorrectMove() {
    final question = _session!.currentQuestion;

    setState(() {
      _feedback = '✓ Correct! ${question.correctMove}';
      _session!.results[question.lineId + '_' + question.moveIndex.toString()] = TrainingResult.correct;
    });

    // Auto-advance after a short delay
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) _nextQuestion();
    });
  }

  void _handleIncorrectMove() {
    final question = _session!.currentQuestion;

    setState(() {
      _feedback = '✗ Incorrect. The correct move is ${question.correctMove}';
      _session!.results[question.lineId + '_' + question.moveIndex.toString()] = TrainingResult.incorrect;
      _showingCorrectAnswer = true;
    });
  }

  void _showCorrectMove() {
    if (_session == null || _session!.isComplete) return;

    final question = _session!.currentQuestion;
    setState(() {
      _feedback = '💡 Hint: ${question.correctMove}';
      _session!.results[question.lineId + '_' + question.moveIndex.toString()] = TrainingResult.skipped;
      _showingCorrectAnswer = true;
    });
  }

  void _nextQuestion() {
    if (_session == null) return;

    if (_session!.isComplete) {
      _showResults();
      return;
    }

    _session!.currentQuestionIndex++;
    _loadCurrentQuestion();
  }

  void _showResults() {
    final session = _session!;
    final correct = session.correctAnswers;
    final total = session.totalQuestions;
    final percentage = ((correct / total) * 100).round();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Training Complete!'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              percentage >= 80 ? Icons.emoji_events : Icons.thumb_up,
              size: 64,
              color: percentage >= 80 ? Colors.amber : Colors.blue,
            ),
            const SizedBox(height: 16),
            Text(
              '$correct / $total correct',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Text(
              '$percentage%',
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 16),
            Text(_getPerformanceMessage(percentage)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // Close dialog
              Navigator.pop(context); // Return to repertoire screen
            },
            child: const Text('Done'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context); // Close dialog
              _initializeTraining(); // Restart training
            },
            child: const Text('Train Again'),
          ),
        ],
      ),
    );
  }

  String _getPerformanceMessage(int percentage) {
    if (percentage >= 90) return 'Excellent! You know this repertoire well.';
    if (percentage >= 80) return 'Good work! Keep practicing.';
    if (percentage >= 70) return 'Not bad, but more practice needed.';
    return 'Keep studying - practice makes perfect!';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Repertoire Training'),
        actions: [
          if (_session != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  '${_session!.currentQuestionIndex + 1}/${_session!.totalQuestions}',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(),
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
            Text('Loading training questions...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Go Back'),
            ),
          ],
        ),
      );
    }

    if (_session == null || _session!.isComplete) {
      return const Center(child: Text('No training session'));
    }

    return Row(
      children: [
        // Left panel - Chess board (60%)
        Expanded(
          flex: 6,
          child: Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Question text
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          _session!.currentQuestion.questionText,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                        if (_feedback != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _feedback!,
                            style: TextStyle(
                              fontSize: 14,
                              color: _feedback!.startsWith('✓') ? Colors.green : Colors.red,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // Chess board
                Expanded(
                  child: ChessBoardWidget(
                    game: _displayGame,
                    flipped: !_session!.currentQuestion.isWhiteToMove,
                    onMove: _handleUserMove,
                  ),
                ),

                // Training controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: _showCorrectMove,
                      child: const Text('Show Hint'),
                    ),
                    if (_showingCorrectAnswer)
                      FilledButton(
                        onPressed: _nextQuestion,
                        child: const Text('Continue'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // Divider
        Container(width: 1, color: Colors.grey[300]),

        // Right panel - PGN viewer (40%)
        Expanded(
          flex: 4,
          child: Container(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Text(
                  'Line: ${_session!.currentQuestion.lineName}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Divider(),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey[700]!),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Current Line:',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Moves: ${_session!.currentQuestion.leadupMoves.join(' ')}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Next: ${_session!.currentQuestion.correctMove}',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: _showingCorrectAnswer ? Colors.orange : Colors.grey,
                            fontWeight: _showingCorrectAnswer ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        if (_session!.currentQuestion.comment != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _session!.currentQuestion.comment!,
                            style: const TextStyle(
                              color: Colors.green,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

