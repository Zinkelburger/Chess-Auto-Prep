/// State owner for the manual puzzle creator.
///
/// Three steps:
///   1. [CreatorStep.setup]          — set up the start position (wraps a
///      [BoardEditorController], seedable from a FEN).
///   2. [CreatorStep.recordSolution] — play the solution line on a legal
///      board; the first recorded move belongs to the side to move in the
///      start FEN (= the solver), matching the trainer's convention that
///      user moves sit at even indices of `correctLine`.
///   3. [CreatorStep.details]        — note, star rating, target set.
///
/// [buildPuzzle] emits a [TacticsPosition] with `mistakeType: 'custom'` and
/// empty game fields — the trainer only needs `fen` + `correctLine`.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';
import 'board_editor_controller.dart';

enum CreatorStep { setup, recordSolution, details }

class PuzzleCreatorController extends ChangeNotifier {
  PuzzleCreatorController({String? initialFen})
    : editor = BoardEditorController(initialFen: initialFen);

  final BoardEditorController editor;

  CreatorStep _step = CreatorStep.setup;
  CreatorStep get step => _step;

  Position? _startPosition;
  Position? _currentPosition;
  final List<String> _solutionSan = [];

  /// The position the puzzle starts from (fixed when leaving setup).
  Position? get startPosition => _startPosition;

  /// The live board during solution recording.
  Position? get currentPosition => _currentPosition;

  /// The recorded solution line in SAN.
  List<String> get solutionSan => List.unmodifiable(_solutionSan);

  /// The solver plays the first move of the line.
  Side? get solverSide => _startPosition?.turn;

  // ── Step transitions ─────────────────────────────────────────────────

  /// Setup → record.  Requires a valid editor position.
  bool startRecording() {
    final position = editor.validPosition;
    if (position == null) return false;
    _startPosition = position;
    _currentPosition = position;
    _solutionSan.clear();
    _step = CreatorStep.recordSolution;
    notifyListeners();
    return true;
  }

  /// Record → setup (keeps the editor state; discards the recorded line).
  void backToSetup() {
    _startPosition = null;
    _currentPosition = null;
    _solutionSan.clear();
    _step = CreatorStep.setup;
    notifyListeners();
  }

  /// Record → details.  Requires at least one recorded move.
  bool finishRecording() {
    if (_solutionSan.isEmpty) return false;
    _step = CreatorStep.details;
    notifyListeners();
    return true;
  }

  /// Details → record (solution stays; more moves may be appended).
  void backToRecording() {
    _step = CreatorStep.recordSolution;
    notifyListeners();
  }

  // ── Solution recording ───────────────────────────────────────────────

  /// Play a legal [move] on the recording board, appending its SAN to the
  /// solution.  Returns `false` when no recording is active or the move is
  /// illegal.
  bool playMove(Move move) {
    final pos = _currentPosition;
    if (_step != CreatorStep.recordSolution || pos == null) return false;
    try {
      final (next, san) = pos.makeSan(move);
      _currentPosition = next;
      _solutionSan.add(san);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// SAN variant of [playMove] — preferred from board callbacks because SAN
  /// sidesteps the UCI castling-encoding mismatch (e1g1 vs e1h1).
  bool playMoveSan(String san) {
    final pos = _currentPosition;
    if (_step != CreatorStep.recordSolution || pos == null) return false;
    final move = pos.parseSan(san);
    if (move == null) return false;
    return playMove(move);
  }

  /// Remove the last recorded move (replays the line from the start).
  void undoLastMove() {
    if (_solutionSan.isEmpty || _startPosition == null) return;
    _solutionSan.removeLast();
    var pos = _startPosition!;
    for (final san in _solutionSan) {
      final move = pos.parseSan(san);
      if (move == null) break; // unreachable: the line replays itself
      pos = pos.play(move);
    }
    _currentPosition = pos;
    notifyListeners();
  }

  // ── Output ───────────────────────────────────────────────────────────

  /// `"Move N, White/Black to play"` — same shape the importer writes, so
  /// board flipping and move-number parsing keep working.
  String get positionContext {
    final pos = _startPosition;
    if (pos == null) return 'Move 1, White to play';
    final side = pos.turn == Side.white ? 'White' : 'Black';
    return 'Move ${pos.fullmoves}, $side to play';
  }

  /// Build the puzzle from the recorded state.
  TacticsPosition buildPuzzle({
    String note = '',
    int rating = 0,
    String gameWhite = '',
    String gameBlack = '',
  }) {
    final start = _startPosition;
    if (start == null || _solutionSan.isEmpty) {
      throw StateError('No recorded solution to build a puzzle from');
    }
    return TacticsPosition(
      fen: start.fen,
      userMove: '',
      correctLine: List.of(_solutionSan),
      mistakeType: TacticsSessionSettings.customMistakeType,
      mistakeAnalysis: note,
      positionContext: positionContext,
      gameWhite: gameWhite,
      gameBlack: gameBlack,
      gameResult: '*',
      gameDate: _today(),
      gameId: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      rating: rating,
    );
  }

  static String _today() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return '${now.year}.$mm.$dd';
  }

  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }
}
