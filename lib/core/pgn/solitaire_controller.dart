import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

enum SolitaireFeedback { correct, incorrect }

/// Manages solitaire chess mode: the user guesses moves from a loaded PGN game
/// one at a time. Correct guesses reveal the move; the opponent's reply
/// auto-plays after a short delay.
class SolitaireController extends ChangeNotifier {
  bool _active = false;
  bool get active => _active;

  /// How far into the mainline the user has correctly guessed (0-based ply
  /// count: 0 = start position, 1 = after first move revealed, etc.).
  int _revealedPly = 0;
  int get revealedPly => _revealedPly;

  int _totalMoves = 0;
  int get totalMoves => _totalMoves;

  /// Which side the user is guessing (true = White, false = Black).
  bool _userIsWhite = true;
  bool get userIsWhite => _userIsWhite;

  /// Whether we're waiting for the user to guess.
  bool get waitingForUser {
    if (!_active) return false;
    if (_revealedPly >= _totalMoves) return false;
    final isWhiteTurn = _revealedPly % 2 == 0;
    return isWhiteTurn == _userIsWhite;
  }

  /// Whether an opponent auto-play is pending.
  bool _opponentPlaying = false;
  bool get opponentPlaying => _opponentPlaying;

  /// Brief feedback after a guess attempt.
  SolitaireFeedback? _feedback;
  SolitaireFeedback? get feedback => _feedback;

  /// Attempts on the current move.
  int _currentAttempts = 0;
  int get currentAttempts => _currentAttempts;

  /// Total moves guessed correctly on first try.
  int _correctFirstTry = 0;
  int get correctFirstTry => _correctFirstTry;

  /// Total user moves in this game (for accuracy calc).
  int _totalUserMoves = 0;
  int get totalUserMoves => _totalUserMoves;

  /// Whether the current game is complete.
  bool get isComplete => _active && _revealedPly >= _totalMoves;

  Timer? _feedbackTimer;
  Timer? _opponentTimer;

  /// Callbacks set by the parent controller.
  VoidCallback? onAdvancePosition;
  VoidCallback? onResetPosition;

  void start({required int mainLineLength, required bool userPlaysWhite}) {
    _active = true;
    _totalMoves = mainLineLength;
    _userIsWhite = userPlaysWhite;
    _revealedPly = 0;
    _currentAttempts = 0;
    _correctFirstTry = 0;
    _totalUserMoves = 0;
    _feedback = null;
    _opponentPlaying = false;
    _cancelTimers();
    notifyListeners();
    _maybePlayOpponent();
  }

  void stop() {
    _active = false;
    _feedback = null;
    _opponentPlaying = false;
    _cancelTimers();
    notifyListeners();
  }

  /// Called when the game changes underneath (next/prev game).
  void onGameChanged({required int mainLineLength, required bool userPlaysWhite}) {
    if (!_active) return;
    _totalMoves = mainLineLength;
    _userIsWhite = userPlaysWhite;
    _revealedPly = 0;
    _currentAttempts = 0;
    _correctFirstTry = 0;
    _totalUserMoves = 0;
    _feedback = null;
    _opponentPlaying = false;
    _cancelTimers();
    notifyListeners();
    _maybePlayOpponent();
  }

  /// Attempt to guess a move. Returns true if correct.
  ///
  /// [san] is the SAN the user played.
  /// [position] is the current board position (before the move).
  /// [expectedSan] is the next mainline move's SAN.
  bool handleMove(String san, Position position, String expectedSan) {
    if (!_active || !waitingForUser) return false;

    final isCorrect = _isCorrectMove(san, position, expectedSan);

    if (isCorrect) {
      _totalUserMoves++;
      if (_currentAttempts == 0) _correctFirstTry++;
      _currentAttempts = 0;
      _feedback = SolitaireFeedback.correct;
      _revealedPly++;
      notifyListeners();

      onAdvancePosition?.call();
      _scheduleFeedbackClear();
      _maybePlayOpponent();
      return true;
    } else {
      _currentAttempts++;
      _feedback = SolitaireFeedback.incorrect;
      notifyListeners();
      _scheduleFeedbackClear();
      onResetPosition?.call();
      return false;
    }
  }

  /// If it's the opponent's turn, auto-advance after a delay.
  void _maybePlayOpponent() {
    if (!_active) return;
    if (_revealedPly >= _totalMoves) {
      notifyListeners();
      return;
    }

    final isWhiteTurn = _revealedPly % 2 == 0;
    if (isWhiteTurn == _userIsWhite) return;

    _opponentPlaying = true;
    notifyListeners();

    _opponentTimer?.cancel();
    _opponentTimer = Timer(const Duration(milliseconds: 400), () {
      if (!_active) return;
      _revealedPly++;
      _opponentPlaying = false;
      onAdvancePosition?.call();
      notifyListeners();
      _maybePlayOpponent();
    });
  }

  void _scheduleFeedbackClear() {
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 1200), () {
      _feedback = null;
      notifyListeners();
    });
  }

  bool _isCorrectMove(String san, Position position, String expectedSan) {
    final expectedMove = position.parseSan(expectedSan);
    if (expectedMove == null) return false;

    try {
      final expectedPos = position.play(expectedMove);
      final userMove = position.parseSan(san);
      if (userMove == null) return false;
      final userPos = position.play(userMove);
      if (userPos.fen == expectedPos.fen) return true;
    } catch (_) {}

    String normalize(String s) =>
        s.replaceAll(RegExp(r'[+#?!]'), '').trim().toLowerCase();
    return normalize(san) == normalize(expectedSan);
  }

  void _cancelTimers() {
    _feedbackTimer?.cancel();
    _feedbackTimer = null;
    _opponentTimer?.cancel();
    _opponentTimer = null;
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }
}
