/// Repertoire trainer mode (Chessable-style full-line drilling)
library;

import 'dart:async';

import 'package:chess/chess.dart' as chess;
import 'package:flutter/material.dart';

import '../core/repertoire_controller.dart';
import '../models/repertoire_line.dart';
import '../models/repertoire_review_entry.dart';
import '../models/repertoire_move_progress.dart';
import '../models/repertoire_review_history_entry.dart';
import '../services/repertoire_review_service.dart';
import '../services/repertoire_service.dart';
import '../widgets/chess_board_widget.dart';
import 'repertoire_selection_screen.dart';

class RepertoireTrainingScreen extends StatefulWidget {
  final Map<String, dynamic>? repertoire;
  final String? startLineId;

  const RepertoireTrainingScreen({
    super.key,
    this.repertoire,
    this.startLineId,
  });

  @override
  State<RepertoireTrainingScreen> createState() => _RepertoireTrainingScreenState();
}

class _RepertoireTrainingScreenState extends State<RepertoireTrainingScreen>
    with TickerProviderStateMixin {
  final RepertoireService _repertoireService = RepertoireService();
  final RepertoireReviewService _reviewService = RepertoireReviewService();

  Map<String, dynamic>? _repertoire;
  List<RepertoireLine> _lines = [];
  List<RepertoireReviewEntry> _otherRepertoireEntries = [];
  Map<String, RepertoireReviewEntry> _reviewMap = {};
  Map<String, RepertoireMoveProgress> _moveProgressMap = {};

  List<RepertoireLine> _dueQueue = [];
  RepertoireLine? _currentLine;
  int _currentMoveIndex = 0;
  bool _lineHadMistake = false;

  // Unified session/game state shared with the board.
  late final RepertoireController _session;

  bool _isLoading = true;
  String? _error;
  bool _waitingForUser = false;
  bool _lineFinished = false;
  String? _feedback;
  String? _currentAnnotation;

  late final TabController _tabController = TabController(length: 2, vsync: this);

  bool get _isWhiteLine => _currentLine?.color.toLowerCase() != 'black';
  bool get _boardFlipped => !_isWhiteLine;

  @override
  void initState() {
    super.initState();
    _session = RepertoireController();
    _session.addListener(_onSessionChanged);
    _repertoire = widget.repertoire;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOrPromptSelection();
    });
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadOrPromptSelection() async {
    if (_repertoire == null) {
      await _selectRepertoire();
    } else {
      await _loadRepertoire();
    }
  }

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

  Future<void> _loadRepertoire() async {
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
          _error = 'No trainable lines found in repertoire.';
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

      // Persist merged entries so CSV always mirrors current lines.
      await _reviewService.saveAll([..._otherRepertoireEntries, ...merged]);

      setState(() {
        _lines = lines;
        _reviewMap = {for (final e in merged) e.lineId: e};
        _moveProgressMap = _reviewService.indexMoveProgress(
          moveProgress.where((mp) => mp.repertoireId == filePath).toList(),
        );
        _dueQueue = _reviewService.dueLinesInOrder(lines, _reviewMap);
      });

      _pickStartingLine();
    } catch (e) {
      setState(() {
        _error = 'Error loading repertoire: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _pickStartingLine() {
    if (_lines.isEmpty) return;
    RepertoireLine? initial;

    if (widget.startLineId != null) {
      initial =
          _lines.firstWhere((l) => l.id == widget.startLineId, orElse: () => _lines.first);
    } else if (_dueQueue.isNotEmpty) {
      initial = _dueQueue.first;
    } else {
      initial = _lines.first;
    }

    _startLine(initial);
  }

  void _startLine(RepertoireLine? line) {
    if (line == null) return;
    setState(() {
      _currentLine = line;
      _currentMoveIndex = 0;
      _feedback = null;
      _lineFinished = false;
      _waitingForUser = false;
      _currentAnnotation = null;
      _lineHadMistake = false;
      _session.clearMoveHistory();
    });

    // Kick off the first animation/move preparation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _advanceToNextUserTurn();
    });
  }

  bool _isUserMove(int moveIndex) {
    if (_currentLine == null) return false;
    final isWhiteMove = moveIndex % 2 == 0;
    return (_isWhiteLine && isWhiteMove) || (!_isWhiteLine && !isWhiteMove);
  }

  Future<void> _advanceToNextUserTurn() async {
    if (_currentLine == null) return;

    final moves = _currentLine!.moves;

    while (_currentMoveIndex < moves.length) {
      if (_isUserMove(_currentMoveIndex)) {
        await _prepareUserMove(_currentMoveIndex);
        return;
      } else {
        await _playOpponentMove(_currentMoveIndex);
        _currentMoveIndex++;
      }
    }

    setState(() {
      _lineFinished = true;
      _waitingForUser = false;
      _feedback = 'Line complete – rate it to continue.';
    });
  }

  Future<void> _playOpponentMove(int moveIndex) async {
    if (_currentLine == null) return;
    final san = _currentLine!.moves[moveIndex];
    final result = chess.Chess.fromFEN(_session.game.fen).move(san);
    if (result == false) {
      setState(() {
        _error = 'Could not play opponent move $san';
      });
      return;
    }

    _session.userPlayedMove(san);
    setState(() {
      _currentAnnotation = _currentLine!.comments[moveIndex.toString()];
    });

    // Brief pause so the user sees the move land.
    await Future.delayed(const Duration(milliseconds: 500));
  }

  Future<void> _prepareUserMove(int moveIndex) async {
    if (_currentLine == null) return;
    setState(() {
      _waitingForUser = true;
      _currentAnnotation = _currentLine!.comments[moveIndex.toString()];
      _feedback = 'Your move (${_isWhiteMoveIndex(moveIndex) ? "White" : "Black"})';
    });
  }

  bool _isWhiteMoveIndex(int moveIndex) => moveIndex % 2 == 0;

  void _handleUserMove(CompletedMove move) async {
    if (!_waitingForUser || _currentLine == null) return;

    final expectedSan = _currentLine!.moves[_currentMoveIndex];
    final isCorrect = _isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      _updateMoveProgress(_currentLine!, _currentMoveIndex, wasCorrect: true);
      _session.userPlayedMove(expectedSan);
      setState(() {
        _waitingForUser = false;
        _feedback = '✓ $expectedSan';
      });

      _currentMoveIndex++;
      await Future.delayed(const Duration(milliseconds: 350));
      _advanceToNextUserTurn();
    } else {
      _updateMoveProgress(_currentLine!, _currentMoveIndex, wasCorrect: false);
      _lineHadMistake = true;
      // Keep the position; do not advance until they play the correct move.
      setState(() {
        _feedback = 'Try again: expected $expectedSan';
      });
    }
  }

  String _uciFromMove(dynamic move) {
    if (move == null || move is bool) return '';
    final from = move['from'] as String? ?? '';
    final to = move['to'] as String? ?? '';
    final promo = move['promotion'] as String? ?? '';
    return (from + to + promo).toLowerCase();
  }

  bool _isCorrectUserMove(CompletedMove move, String expectedSan) {
    // Compute the expected resulting position by applying the PGN move.
    final expectedGame = chess.Chess.fromFEN(_session.game.fen);
    final expectedMove = expectedGame.move(expectedSan);
    if (expectedMove == null) return false;
    final expectedFen = expectedGame.fen;

    // Compute the user resulting position by applying the user's UCI move.
    final userGame = chess.Chess.fromFEN(_session.game.fen);
    final userMoveMap = <String, String>{
      'from': move.from,
      'to': move.to,
    };
    // handle promotion if present in UCI (e.g., e7e8q)
    if (move.uci.length > 4) {
      userMoveMap['promotion'] = move.uci.substring(4, 5);
    }
    final userResult = userGame.move(userMoveMap);
    if (userResult == false) return false;
    final userFen = userGame.fen;

    // If positions match, accept (handles castling O-O vs Kg8, etc.)
    if (userFen == expectedFen) return true;

    // Fallback: compare normalized SAN strings.
    String normalizeSan(String san) =>
        san.replaceAll(RegExp(r'[+#?!]'), '').trim().toLowerCase();
    if (normalizeSan(move.san) == normalizeSan(expectedSan)) return true;

    return false;
  }

  Future<void> _rateLine(ReviewRating rating) async {
    if (_currentLine == null) return;
    final repertoireId = (_repertoire?['filePath'] ?? '').toString();
    final existing = _reviewMap[_currentLine!.id] ??
        RepertoireReviewEntry(
          repertoireId: repertoireId,
          lineId: _currentLine!.id,
          lineName: _currentLine!.name,
        );

    final updated = _reviewService.applyRating(existing, rating);
    _reviewMap[_currentLine!.id] = updated;

    // Persist merged entries (current + others) to the CSV.
    await _reviewService
        .saveAll([..._otherRepertoireEntries, ..._reviewMap.values]);

    // Save move progress snapshot
    await _reviewService.saveMoveProgress(_moveProgressMap.values.toList());

    // Append review history
    await _reviewService.appendHistory([
      RepertoireReviewHistoryEntry(
        repertoireId: repertoireId,
        lineId: _currentLine!.id,
        timestampUtc: DateTime.now().toUtc(),
        rating: rating.name,
        hadMistake: _lineHadMistake,
        sessionType: 'trainer',
      )
    ]);

    _rebuildQueueAndAdvance();
  }

  void _rebuildQueueAndAdvance() {
    setState(() {
      _dueQueue = _reviewService.dueLinesInOrder(_lines, _reviewMap);
    });
    if (_dueQueue.isEmpty) {
      setState(() {
        _lineFinished = true;
        _feedback = 'All lines are up to date. Great job!';
      });
      return;
    }

    // Continue sequentially: move to the next due line after the current one if possible.
    int nextIndex = 0;
    if (_currentLine != null) {
      final currentOrderIndex = _lines.indexWhere((l) => l.id == _currentLine!.id);
      // Find the next due line in order
      for (int i = 1; i <= _lines.length; i++) {
        final candidateIndex = (currentOrderIndex + i) % _lines.length;
        final candidate = _lines[candidateIndex];
        if (_reviewMap[candidate.id]?.isDue ?? true) {
          nextIndex = _dueQueue.indexWhere((l) => l.id == candidate.id);
          if (nextIndex >= 0) break;
        }
      }
    }

    final nextLine = _dueQueue[nextIndex];
    _startLine(nextLine);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Repertoire Trainer'),
        actions: [
          if (_repertoire != null)
            IconButton(
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh),
              onPressed: _loadRepertoire,
            ),
          IconButton(
            tooltip: 'Select repertoire',
            icon: const Icon(Icons.library_books),
            onPressed: _selectRepertoire,
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
            Icon(Icons.error, size: 64, color: Colors.red),
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

    if (_currentLine == null) {
      return Center(
        child: FilledButton(
          onPressed: _pickStartingLine,
          child: const Text('Start Training'),
        ),
      );
    }

    return Row(
      children: [
        Expanded(
          flex: 6,
          child: _buildBoardPane(),
        ),
        Container(width: 1, color: Colors.grey[300]),
        Expanded(
          flex: 4,
          child: _buildRightPane(),
        ),
      ],
    );
  }

  Widget _buildBoardPane() {
    final entry = _reviewMap[_currentLine!.id];
    return Container(
      padding: const EdgeInsets.all(12),
            child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
              children: [
          _buildLineHeader(entry),
          const SizedBox(height: 12),
          Expanded(
            child: ChessBoardWidget(
              key: ValueKey(_session.fen),
              game: _session.game,
              flipped: _boardFlipped,
              enableUserMoves: _waitingForUser,
              onMove: _handleUserMove,
            ),
          ),
          const SizedBox(height: 8),
          _buildControlRow(),
        ],
      ),
    );
  }

  Widget _buildLineHeader(RepertoireReviewEntry? entry) {
    return Card(
      elevation: 1,
                  child: Padding(
        padding: const EdgeInsets.all(12),
                    child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
              _currentLine!.name,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Color: ${_isWhiteLine ? "White" : "Black"} • Moves: ${_currentLine!.moves.length}',
              style: TextStyle(color: Colors.grey[700]),
            ),
            if (entry != null) ...[
              const SizedBox(height: 4),
                          Text(
                entry.isDue
                    ? 'Due now • Difficulty ${entry.difficulty.toStringAsFixed(2)}'
                    : 'Next review ${entry.dueDateUtc}',
                            style: TextStyle(
                  color: entry.isDue ? Colors.orange[700] : Colors.green[700],
                  fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
    );
  }

  Widget _buildControlRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
                Expanded(
          child: Text(
            _feedback ?? 'Follow the prompts and play the move.',
            style: TextStyle(
              color: _feedback != null && _feedback!.startsWith('✓')
                  ? Colors.green
                  : Colors.blueGrey,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (_lineFinished) _buildRatingButtons(),
      ],
    );
  }

  Widget _buildRatingButtons() {
    final hasMistake = _lineHadMistake;
    return Wrap(
      spacing: 8,
                  children: [
        OutlinedButton(
          onPressed: () => _rateLine(ReviewRating.again),
          child: const Text('Again'),
        ),
        OutlinedButton(
          onPressed: () => _rateLine(ReviewRating.hard),
          child: const Text('Hard'),
        ),
        FilledButton.tonal(
          onPressed: hasMistake ? null : () => _rateLine(ReviewRating.good),
          child: const Text('Good'),
        ),
                      FilledButton(
          onPressed: hasMistake ? null : () => _rateLine(ReviewRating.easy),
          child: const Text('Easy'),
        ),
      ],
    );
  }

  Widget _buildRightPane() {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Move'),
            Tab(text: 'PGN'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildMoveTab(),
              _buildPgnTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMoveTab() {
    final moveNumber = (_currentMoveIndex ~/ 2) + 1;
    final isWhiteMove = _currentMoveIndex % 2 == 0;
    final san = _currentMoveIndex < _currentLine!.moves.length
        ? _currentLine!.moves[_currentMoveIndex]
        : null;
    final learnedCount = _countLearnedMoves(_currentLine!);
    final totalMoves = _currentLine!.moves.length;

    return Padding(
      padding: const EdgeInsets.all(12),
            child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
            'Current Move',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                    san != null ? '${isWhiteMove ? moveNumber : '...'} $san' : 'Line complete',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                  if (_currentAnnotation != null) ...[
                    const SizedBox(height: 6),
                        Text(
                      _currentAnnotation!,
                      style: const TextStyle(color: Colors.black87),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
          const SizedBox(height: 12),
          Text(
            'Learned moves: $learnedCount / $totalMoves (need 3 correct per move)',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          _buildMovesStreakRow(),
          const SizedBox(height: 12),
          Text(
            'Upcoming line (${_dueQueue.length} due):',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          _buildQueuePreview(),
        ],
      ),
    );
  }

  Widget _buildQueuePreview() {
    if (_dueQueue.isEmpty) {
      return const Text('All caught up!');
    }

    return SizedBox(
      height: 140,
      child: ListView.builder(
        itemCount: _dueQueue.length,
        itemBuilder: (context, index) {
          final line = _dueQueue[index];
          final isCurrent = _currentLine?.id == line.id;
          final learnedMoves = _countLearnedMoves(line);
          return ListTile(
            dense: true,
            title: Text(
              line.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${line.moves.take(6).join(' ')}${line.moves.length > 6 ? ' ...' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              '${learnedMoves}/${line.moves.length}',
              style: TextStyle(
                color: learnedMoves == line.moves.length ? Colors.green : Colors.blueGrey,
                fontWeight: FontWeight.w600,
              ),
            ),
            selected: isCurrent,
            onTap: () => _startLine(line),
          );
        },
      ),
    );
  }

  Widget _buildPgnTab() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: SelectableText(
          _currentLine?.fullPgn ?? '',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      ),
    );
  }

  void _updateMoveProgress(RepertoireLine line, int moveIndex, {required bool wasCorrect}) {
    final key = '${line.id}:$moveIndex';
    final existing = _moveProgressMap[key];
    if (wasCorrect) {
      final newStreak = ((existing?.correctStreak ?? 0) + 1);
      final learned = newStreak >= 3;
      _moveProgressMap[key] = RepertoireMoveProgress(
        repertoireId: (_repertoire?['filePath'] ?? '').toString(),
        lineId: line.id,
        moveIndex: moveIndex,
        correctStreak: learned ? 3 : newStreak,
        learned: learned,
      );
    } else {
      _moveProgressMap[key] = RepertoireMoveProgress(
        repertoireId: (_repertoire?['filePath'] ?? '').toString(),
        lineId: line.id,
        moveIndex: moveIndex,
        correctStreak: 0,
        learned: false,
      );
    }
  }

  int _countLearnedMoves(RepertoireLine line) {
    int learned = 0;
    for (int i = 0; i < line.moves.length; i++) {
      final key = '${line.id}:$i';
      final prog = _moveProgressMap[key];
      if (prog != null && prog.learned) learned++;
    }
    return learned;
  }

  Widget _buildMovesStreakRow() {
    if (_currentLine == null) return const SizedBox.shrink();
    final items = <Widget>[];
    for (int i = 0; i < _currentLine!.moves.length && i < 12; i++) {
      final key = '${_currentLine!.id}:$i';
      final prog = _moveProgressMap[key];
      final streak = prog?.correctStreak ?? 0;
      final learned = prog?.learned ?? false;
      items.add(Container(
        margin: const EdgeInsets.only(right: 6, bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: learned ? Colors.green[700] : Colors.blueGrey[800],
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '${i + 1}:${streak}/3',
          style: const TextStyle(fontSize: 11, color: Colors.white),
        ),
      ));
    }
    return Wrap(children: items);
  }

}
