import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

enum SolitaireFeedback { correct, incorrect }

/// A single user-guessed move with all attempts recorded.
class SolitaireGuess {
  final int ply;
  final String expectedSan;
  final List<String> wrongAttempts;
  final String correctSan;
  final bool wasRevealed;

  const SolitaireGuess({
    required this.ply,
    required this.expectedSan,
    required this.wrongAttempts,
    required this.correctSan,
    this.wasRevealed = false,
  });

  bool get firstTry => wrongAttempts.isEmpty && !wasRevealed;

  /// Human-readable annotation appended to the move's PGN comment when the
  /// game completes: "1st try", "Revealed", or "Tried: e5, d5 (3 tries)".
  String get note {
    if (wasRevealed) {
      return wrongAttempts.isEmpty
          ? 'Revealed'
          : 'Tried: ${wrongAttempts.join(", ")} then revealed';
    }
    if (firstTry) return '1st try';
    final tries = wrongAttempts.length + 1;
    return 'Tried: ${wrongAttempts.join(", ")} ($tries tries)';
  }
}

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

  /// Whether White is to move at the game's starting position (ply 0).
  /// False for games starting from a FEN where Black moves first.
  bool _whiteToMoveAtStart = true;

  /// Whether we're waiting for the user to guess.
  bool get waitingForUser {
    if (!_active) return false;
    if (_revealedPly >= _totalMoves) return false;
    final isWhiteTurn = (_revealedPly % 2 == 0) == _whiteToMoveAtStart;
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

  /// Number of moves the user revealed (gave up on).
  int _revealedCount = 0;
  int get revealedCount => _revealedCount;

  /// Whether the current game is complete.
  bool get isComplete => _active && _revealedPly >= _totalMoves;

  /// Log of all user guesses (one entry per user-side move, recorded on
  /// correct guess or reveal).
  final List<SolitaireGuess> _guessLog = [];
  List<SolitaireGuess> get guessLog => List.unmodifiable(_guessLog);

  /// Wrong attempts accumulated for the move currently being guessed.
  final List<String> _pendingWrongAttempts = [];

  /// Seconds before the reveal button becomes active (0 = always available).
  int revealDelaySec = 60;

  /// When the user started thinking about the current move.
  DateTime? _moveStartTime;
  DateTime? get moveStartTime => _moveStartTime;

  /// Seconds remaining before the reveal button activates. 0 when ready.
  int get revealCountdownSec {
    if (_moveStartTime == null || revealDelaySec <= 0) return 0;
    final elapsed = DateTime.now().difference(_moveStartTime!).inSeconds;
    return (revealDelaySec - elapsed).clamp(0, revealDelaySec);
  }

  bool get canReveal => waitingForUser && revealCountdownSec == 0;

  Timer? _feedbackTimer;
  Timer? _opponentTimer;
  Timer? _countdownTimer;

  /// Callbacks set by the parent controller.
  VoidCallback? onAdvancePosition;
  VoidCallback? onResetPosition;

  void start({
    required int mainLineLength,
    required bool userPlaysWhite,
    bool whiteToMoveAtStart = true,
  }) {
    _active = true;
    _totalMoves = mainLineLength;
    _userIsWhite = userPlaysWhite;
    _whiteToMoveAtStart = whiteToMoveAtStart;
    _revealedPly = 0;
    _currentAttempts = 0;
    _correctFirstTry = 0;
    _totalUserMoves = 0;
    _revealedCount = 0;
    _feedback = null;
    _opponentPlaying = false;
    _guessLog.clear();
    _pendingWrongAttempts.clear();
    _moveStartTime = null;
    _cancelTimers();
    notifyListeners();
    _maybePlayOpponent();
  }

  void stop() {
    _active = false;
    _feedback = null;
    _opponentPlaying = false;
    _moveStartTime = null;
    _cancelTimers();
    notifyListeners();
  }

  /// Called when the game changes underneath (next/prev game).
  void onGameChanged({
    required int mainLineLength,
    required bool userPlaysWhite,
    bool whiteToMoveAtStart = true,
  }) {
    if (!_active) return;
    _totalMoves = mainLineLength;
    _userIsWhite = userPlaysWhite;
    _whiteToMoveAtStart = whiteToMoveAtStart;
    _revealedPly = 0;
    _currentAttempts = 0;
    _correctFirstTry = 0;
    _totalUserMoves = 0;
    _revealedCount = 0;
    _feedback = null;
    _opponentPlaying = false;
    _guessLog.clear();
    _pendingWrongAttempts.clear();
    _moveStartTime = null;
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
      _guessLog.add(SolitaireGuess(
        ply: _revealedPly,
        expectedSan: expectedSan,
        wrongAttempts: List.of(_pendingWrongAttempts),
        correctSan: san,
      ));
      _pendingWrongAttempts.clear();
      _currentAttempts = 0;
      _feedback = SolitaireFeedback.correct;
      _revealedPly++;
      _moveStartTime = null;
      _countdownTimer?.cancel();
      notifyListeners();

      onAdvancePosition?.call();
      _scheduleFeedbackClear();
      _maybePlayOpponent();
      return true;
    } else {
      _currentAttempts++;
      _pendingWrongAttempts.add(san);
      _feedback = SolitaireFeedback.incorrect;
      notifyListeners();
      _scheduleFeedbackClear();
      onResetPosition?.call();
      return false;
    }
  }

  /// Reveal the correct move (give up). Logs it as a revealed guess.
  void revealMove(String expectedSan) {
    if (!_active || !waitingForUser) return;
    _totalUserMoves++;
    _revealedCount++;
    _guessLog.add(SolitaireGuess(
      ply: _revealedPly,
      expectedSan: expectedSan,
      wrongAttempts: List.of(_pendingWrongAttempts),
      correctSan: expectedSan,
      wasRevealed: true,
    ));
    _pendingWrongAttempts.clear();
    _currentAttempts = 0;
    _revealedPly++;
    _moveStartTime = null;
    _countdownTimer?.cancel();
    notifyListeners();

    onAdvancePosition?.call();
    _maybePlayOpponent();
  }

  /// If it's the opponent's turn, auto-advance after a delay.
  /// When it becomes the user's turn, starts the reveal countdown.
  void _maybePlayOpponent() {
    if (!_active) return;
    if (_revealedPly >= _totalMoves) {
      notifyListeners();
      return;
    }

    final isWhiteTurn = (_revealedPly % 2 == 0) == _whiteToMoveAtStart;
    if (isWhiteTurn == _userIsWhite) {
      _startRevealCountdown();
      return;
    }

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

  void _startRevealCountdown() {
    _moveStartTime = DateTime.now();
    _countdownTimer?.cancel();
    if (revealDelaySec > 0) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_active || !waitingForUser) {
          _countdownTimer?.cancel();
          return;
        }
        notifyListeners();
        if (revealCountdownSec <= 0) _countdownTimer?.cancel();
      });
    }
    notifyListeners();
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
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }
}
