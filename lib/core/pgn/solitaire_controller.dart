import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../utils/safe_change_notifier.dart';
import 'solitaire_reveal.dart';
import 'solitaire_script.dart';

export 'solitaire_reveal.dart' show SolitaireReveal;
export 'solitaire_script.dart' show SolitaireScript, SolitaireStep;

enum SolitaireFeedback { correct, incorrect }

/// A single user-guessed move with all attempts recorded.
class SolitaireGuess {
  /// The move that was asked for, and where it lives in the game.
  final SolitaireStep step;
  final List<String> wrongAttempts;
  final String correctSan;
  final bool wasRevealed;
  final bool wasHinted;

  const SolitaireGuess({
    required this.step,
    required this.wrongAttempts,
    required this.correctSan,
    this.wasRevealed = false,
    this.wasHinted = false,
  });

  /// Mainline index of the guessed move, or -1 for a sideline move.
  int get ply => step.mainlinePly ?? -1;

  String get expectedSan => step.san;

  bool get firstTry => wrongAttempts.isEmpty && !wasRevealed && !wasHinted;

  /// Human-readable annotation appended to the move's PGN comment when the
  /// game completes: "1st try", "Hinted", "Revealed", or
  /// "Tried: e5, d5 (3 tries)".
  String get note {
    final tried = wrongAttempts.join(', ');
    if (wasRevealed) {
      return wrongAttempts.isEmpty ? 'Revealed' : 'Tried: $tried then revealed';
    }
    if (wasHinted) {
      return wrongAttempts.isEmpty ? 'Hinted' : 'Tried: $tried then hinted';
    }
    if (firstTry) return '1st try';
    final tries = wrongAttempts.length + 1;
    return 'Tried: $tried ($tries tries)';
  }
}

/// Manages solitaire chess mode: the user guesses moves from a loaded PGN game
/// one at a time, following a [SolitaireScript]. Correct guesses reveal the
/// move; the opponent's reply — and the premise move that opens a sideline in
/// a variations drill — auto-plays after a short delay.
///
/// Knows nothing about a viewer: the session wires [onStepPending] and
/// [onStepShown] to move the board.
class SolitaireController extends ChangeNotifier with SafeChangeNotifier {
  bool _active = false;
  bool get active => _active;

  List<SolitaireStep> _steps = const [];
  int _cursor = 0;

  /// Steps completed so far (guessed, revealed, or auto-played).
  int get completedSteps => _cursor;
  int get totalSteps => _steps.length;

  /// The step the session is on: awaiting the user's guess, about to be
  /// auto-played, or null when the script is finished.
  SolitaireStep? get currentStep =>
      _cursor < _steps.length ? _steps[_cursor] : null;

  /// Which side the user is guessing (true = White, false = Black).
  bool _userIsWhite = true;
  bool get userIsWhite => _userIsWhite;

  bool _drillsVariations = false;

  /// Whether sidelines are part of this session.
  bool get drillsVariations => _drillsVariations;

  int _revealedMainlinePly = 0;
  final Set<int> _revealedNodeIds = {};

  /// Mainline frontier: mainline moves at index `< revealedPly` are shown and
  /// navigation never walks past it.
  int get revealedPly => _revealedMainlinePly;

  SolitaireReveal get reveal => SolitaireReveal(
    mainlinePly: _revealedMainlinePly,
    nodeIds: Set.unmodifiable(_revealedNodeIds),
    hidesUnreachedSidelines: _drillsVariations,
  );

  /// Whether we're waiting for the user to guess.
  bool get waitingForUser {
    if (!_active) return false;
    final step = currentStep;
    if (step == null || step.isPremise) return false;
    return step.isWhiteMove == _userIsWhite;
  }

  /// Whether an opponent (or premise) auto-play is pending.
  bool _opponentPlaying = false;
  bool get opponentPlaying => _opponentPlaying;

  /// The sideline premise most recently shown, for the status cue. Cleared
  /// once the user's next guess lands.
  SolitaireStep? _lastPremise;
  SolitaireStep? get lastPremise => _lastPremise;

  /// Brief feedback after a guess attempt.
  SolitaireFeedback? _feedback;
  SolitaireFeedback? get feedback => _feedback;

  /// Attempts on the current move.
  int _currentAttempts = 0;
  int get currentAttempts => _currentAttempts;

  /// Total moves guessed correctly on first try.
  int _correctFirstTry = 0;
  int get correctFirstTry => _correctFirstTry;

  /// Total user moves so far (for accuracy calc).
  int _totalUserMoves = 0;
  int get totalUserMoves => _totalUserMoves;

  /// Number of moves the user revealed (gave up on).
  int _revealedCount = 0;
  int get revealedCount => _revealedCount;

  /// Number of moves the user took a hint on.
  int _hintedCount = 0;
  int get hintedCount => _hintedCount;

  /// How many moves the user will be asked in total.
  int _userMovesInScript = 0;
  int get userMovesInScript => _userMovesInScript;

  /// Whether the current game is complete.
  bool get isComplete => _active && _cursor >= _steps.length;

  /// Whether leaving now would throw something away.
  bool get hasProgress => _active && !isComplete && _guessLog.isNotEmpty;

  /// Log of all user guesses (one entry per user-side move, recorded on
  /// correct guess or reveal).
  final List<SolitaireGuess> _guessLog = [];
  List<SolitaireGuess> get guessLog => List.unmodifiable(_guessLog);

  /// Wrong attempts accumulated for the move currently being guessed.
  final List<String> _pendingWrongAttempts = [];

  /// Seconds before hint and reveal become available (0 = always available).
  int revealDelaySec = 60;

  /// When the user started thinking about the current move.
  DateTime? _moveStartTime;
  DateTime? get moveStartTime => _moveStartTime;

  /// Seconds remaining before hint and reveal activate. 0 when ready.
  int get revealCountdownSec {
    if (_moveStartTime == null || revealDelaySec <= 0) return 0;
    final elapsed = DateTime.now().difference(_moveStartTime!).inSeconds;
    return (revealDelaySec - elapsed).clamp(0, revealDelaySec);
  }

  bool get canReveal => waitingForUser && revealCountdownSec == 0;

  /// Square of the piece that makes the expected move, once hinted.
  String? _hintSquare;
  String? get hintSquare => _hintSquare;

  bool get canHint => canReveal && _hintSquare == null;

  Timer? _feedbackTimer;
  Timer? _opponentTimer;
  Timer? _countdownTimer;

  /// The board should show the position [SolitaireStep.before] — it is the
  /// user's turn to guess this step.
  void Function(SolitaireStep step)? onStepPending;

  /// [step] has just been completed; the board should show the position
  /// after it.
  void Function(SolitaireStep step)? onStepShown;

  void start({required SolitaireScript script, required bool userPlaysWhite}) {
    _active = true;
    _steps = List.unmodifiable(script.steps);
    _userIsWhite = userPlaysWhite;
    _drillsVariations = script.includesVariations;
    _revealedMainlinePly = script.startMainlinePly;
    _revealedNodeIds.clear();
    _userMovesInScript = script.userMoveCount(userPlaysWhite);
    _cursor = 0;
    _currentAttempts = 0;
    _correctFirstTry = 0;
    _totalUserMoves = 0;
    _revealedCount = 0;
    _hintedCount = 0;
    _feedback = null;
    _opponentPlaying = false;
    _lastPremise = null;
    _hintSquare = null;
    _guessLog.clear();
    _pendingWrongAttempts.clear();
    _moveStartTime = null;
    _cancelTimers();
    notifyListeners();
    _advance();
  }

  void stop() {
    _active = false;
    _feedback = null;
    _opponentPlaying = false;
    _hintSquare = null;
    _moveStartTime = null;
    _cancelTimers();
    notifyListeners();
  }

  /// Attempt to guess the current move. Returns true if correct.
  bool handleMove(String san) {
    if (!_active || !waitingForUser) return false;
    final step = currentStep!;

    if (_isCorrectMove(san, step.before, step.san)) {
      _totalUserMoves++;
      if (_currentAttempts == 0 && _hintSquare == null) _correctFirstTry++;
      if (_hintSquare != null) _hintedCount++;
      _guessLog.add(
        SolitaireGuess(
          step: step,
          wrongAttempts: List.of(_pendingWrongAttempts),
          correctSan: san,
          wasHinted: _hintSquare != null,
        ),
      );
      _feedback = SolitaireFeedback.correct;
      _completeStep(step);
      _lastPremise = null;
      notifyListeners();

      onStepShown?.call(step);
      _scheduleFeedbackClear();
      _advance();
      return true;
    }

    _currentAttempts++;
    _pendingWrongAttempts.add(san);
    _feedback = SolitaireFeedback.incorrect;
    notifyListeners();
    _scheduleFeedbackClear();
    return false;
  }

  /// Reveal the correct move (give up). Logs it as a revealed guess.
  void revealMove() {
    if (!_active || !waitingForUser) return;
    final step = currentStep!;
    _totalUserMoves++;
    _revealedCount++;
    _guessLog.add(
      SolitaireGuess(
        step: step,
        wrongAttempts: List.of(_pendingWrongAttempts),
        correctSan: step.san,
        wasRevealed: true,
        wasHinted: _hintSquare != null,
      ),
    );
    _completeStep(step);
    _lastPremise = null;
    notifyListeners();

    onStepShown?.call(step);
    _advance();
  }

  /// Highlight the piece that makes the expected move. Counts against a
  /// first-try score but not as a reveal.
  void hintMove() {
    if (!canHint) return;
    final step = currentStep!;
    final move = step.before.parseSan(step.san);
    if (move is! NormalMove) return;
    _hintSquare = move.from.name;
    notifyListeners();
  }

  void _completeStep(SolitaireStep step) {
    _cursor++;
    _pendingWrongAttempts.clear();
    _currentAttempts = 0;
    _hintSquare = null;
    _moveStartTime = null;
    _countdownTimer?.cancel();
    final ply = step.mainlinePly;
    if (ply != null) {
      if (ply + 1 > _revealedMainlinePly) _revealedMainlinePly = ply + 1;
    } else {
      _revealedNodeIds.add(step.node!.id);
    }
  }

  /// Move on to the next step: park the board for the user's guess, or
  /// auto-play an opponent move / sideline premise after a short delay.
  void _advance() {
    if (!_active) return;
    final step = currentStep;
    if (step == null) {
      notifyListeners();
      return;
    }

    if (!step.isPremise && step.isWhiteMove == _userIsWhite) {
      // A null-move gap or a sideline detour may have left the board short of
      // the position this step is guessed from.
      final ply = step.mainlinePly;
      if (ply != null && ply > _revealedMainlinePly) _revealedMainlinePly = ply;
      notifyListeners();
      onStepPending?.call(step);
      _startRevealCountdown();
      return;
    }

    _opponentPlaying = true;
    notifyListeners();

    _opponentTimer?.cancel();
    _opponentTimer = Timer(
      Duration(milliseconds: step.isPremise ? 700 : 400),
      () {
        if (!_active) return;
        _completeStep(step);
        _opponentPlaying = false;
        if (step.isPremise) _lastPremise = step;
        notifyListeners();
        onStepShown?.call(step);
        _advance();
      },
    );
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
      if (isDisposed) return;
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
    } catch (_) {
      // Illegal SAN or [Position.play] throw: fall through to a punctuation-
      // stripped string compare so a checkmate `Qh7#` still matches `Qh7`.
    }

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
