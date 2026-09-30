import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../chess/pgn/chapter_edits.dart' show playedAlready;
import '../chess/pgn/game_tree.dart';
import '../chess/pv_text.dart';
import 'document_session.dart';
import 'engine_analysis.dart';

/// One guess the user had to be helped with or got wrong, for the summary.
typedef SolitaireMiss = ({NodePath at, String played, List<String> tried});

/// Solitaire chess: the game on the board replayed with its moves hidden,
/// the user guessing one side's moves and the other side's played for them.
///
/// It reads the game's main line and writes nothing: the hidden part is
/// the session's [DocumentSession.showOnlyTo], so the move list, the note
/// and the cursor keys all stop at the move being guessed. Another game,
/// another file or anything else that shows the whole game again ends it.
final class Solitaire extends ChangeNotifier {
  Solitaire(this._session, this._analysis) {
    _session.addListener(_documentChanged);
  }

  static const replyDelay = Duration(milliseconds: 400);

  final DocumentSession _session;
  final EngineAnalysis _analysis;

  /// Whether the setup is showing, before a start.
  bool setting = false;

  /// The side the user guesses for.
  Side side = Side.white;

  /// Whether the guessing starts from the first move, or from the move on
  /// the board.
  bool fromStart = true;

  bool _active = false;
  bool get active => _active;

  /// The file and game the session is on; another one ends it.
  Object? _game;
  Object? get _gameNow => (_session.source?.path, _session.chapter?.game);

  /// The move the guessing has reached: the game is shown up to here.
  NodePath _frontier = const NodePath.root();

  /// What the pane says about the last guess, or null.
  String? feedback;
  bool lastWrong = false;

  /// The hint shown for the move being guessed, or null.
  String? hint;

  int guessed = 0;
  int firstTry = 0;
  int hinted = 0;
  int revealed = 0;
  final List<SolitaireMiss> misses = [];

  List<String> _tries = [];
  bool _hintUsed = false;
  Timer? _reply;

  /// Set while this moves the frontier, so its own change is not taken for
  /// the game being changed under it.
  bool _moving = false;

  bool get finished => _active && _expected == null;

  bool get canOffer =>
      _session.chapter != null && _session.tree?.children.isNotEmpty == true;

  /// How many of [side]'s main-line moves the setup would ask for.
  int get movesToGuess {
    final tree = _session.tree;
    if (tree == null) return 0;
    var at = _startPath;
    var count = 0;
    while (tree.nodeAt(at.mainChild) != null) {
      if (_toMove(at) == side) count++;
      at = at.mainChild;
    }
    return count;
  }

  /// Shows the setup: the side at the bottom guesses, from the start.
  void offer() {
    if (!canOffer || _active) return;
    side = _session.orientation;
    fromStart = true;
    setting = true;
    notifyListeners();
  }

  void cancelSetup() {
    if (!setting) return;
    setting = false;
    notifyListeners();
  }

  void setSide(Side value) {
    side = value;
    notifyListeners();
  }

  void setFromStart(bool value) {
    fromStart = value;
    notifyListeners();
  }

  void start() => _begin(_startPath);

  /// The same game again, from where the last run started.
  void again() => _begin(_started);

  NodePath _started = const NodePath.root();

  /// Shows the move at [at]; for a finished game, whose moves are all on view.
  void goTo(NodePath at) => _session.goTo(at);

  void _begin(NodePath from) {
    if (!canOffer || _session.tree?.nodeAt(from.mainChild) == null) return;
    _started = from;
    // The engine would read the answer out.
    if (_analysis.enabled) unawaited(_analysis.disable());
    setting = false;
    _active = true;
    _game = _gameNow;
    guessed = firstTry = hinted = revealed = 0;
    misses.clear();
    feedback = null;
    lastWrong = false;
    _moveTo(from);
    _turn();
  }

  /// Ends the session and shows the whole game again, where it was reached.
  void stop() {
    if (!_active && !setting) return;
    _reply?.cancel();
    _reply = null;
    final wasActive = _active;
    _active = false;
    setting = false;
    hint = null;
    feedback = null;
    if (wasActive) {
      _moving = true;
      _session.showOnlyTo(null);
      _moving = false;
    }
    notifyListeners();
  }

  /// A move made on the board; whether solitaire took it.
  bool play(String uci) {
    if (!_active) return false;
    final expected = _expected;
    if (expected == null || _reply != null) return true;
    if (_toMove(_frontier) != side) return true;
    final chapter = _session.chapter;
    if (chapter == null) return true;
    final reached = playedAlready(chapter, at: _frontier, uci: uci);
    if (reached == expected) {
      guessed++;
      if (_tries.isEmpty && !_hintUsed) firstTry++;
      if (_tries.isNotEmpty || _hintUsed) _miss(expected);
      feedback = 'Correct: ${_san(expected)}';
      lastWrong = false;
      _moveTo(expected);
      _turn();
    } else {
      final start = _session.tree?.fenAt(_frontier);
      final san = start == null ? null : pvMoves(start, [uci]).firstOrNull?.san;
      if (!_tries.contains(san ?? uci)) _tries = [..._tries, san ?? uci];
      feedback = 'Not the game move. Try again.';
      lastWrong = true;
      notifyListeners();
    }
    return true;
  }

  /// Names the piece that moves.
  void showHint() {
    final expected = _expected;
    if (expected == null || hint != null) return;
    final san = _san(expected);
    hint = 'Move your ${_pieceOf(san)}.';
    if (!_hintUsed) hinted++;
    _hintUsed = true;
    notifyListeners();
  }

  /// Plays the game move for the user.
  void reveal() {
    final expected = _expected;
    if (expected == null || _toMove(_frontier) != side) return;
    revealed++;
    guessed++;
    _miss(expected);
    feedback = 'The game move was ${_san(expected)}.';
    lastWrong = false;
    _moveTo(expected);
    _turn();
  }

  /// The move number and SAN of the move at [at], as the summary lists it.
  String moveLabel(NodePath at) {
    final white = _toMove(at.parent) == Side.white;
    final offset = _toMove(const NodePath.root()) == Side.white ? 0 : 1;
    final number = _firstMoveNumber + (at.indexes.length - 1 + offset) ~/ 2;
    final san = _san(at);
    return white ? '$number. $san' : '$number... $san';
  }

  /// The move number of the game's first move, from its starting position.
  int get _firstMoveNumber {
    final fen = _session.tree?.rootFen.value.split(' ');
    return fen == null || fen.length < 6 ? 1 : int.tryParse(fen[5]) ?? 1;
  }

  NodePath get _startPath {
    if (fromStart) return const NodePath.root();
    // Only the main line is guessed: from a sideline, its branch point.
    var at = _session.cursor;
    while (at.indexes.any((i) => i != 0)) {
      at = at.parent;
    }
    return at;
  }

  NodePath? get _expected {
    final next = _frontier.mainChild;
    return _session.tree?.nodeAt(next) == null ? null : next;
  }

  Side _toMove(NodePath at) {
    final tree = _session.tree;
    final fen = at.isRoot ? tree?.rootFen : tree?.nodeAt(at)?.fen;
    return fen?.whiteToMove ?? true ? Side.white : Side.black;
  }

  String _san(NodePath at) => _session.tree?.nodeAt(at)?.san ?? '';

  void _miss(NodePath at) =>
      misses.add((at: at, played: _san(at), tried: _tries));

  void _moveTo(NodePath at) {
    _frontier = at;
    _tries = [];
    _hintUsed = false;
    hint = null;
    _moving = true;
    _session.showOnlyTo(at);
    _session.goTo(at);
    _moving = false;
    notifyListeners();
  }

  /// Plays the other side's move after a moment, or does nothing while it
  /// is the user's to guess; at the end, the whole game comes back.
  void _turn() {
    final expected = _expected;
    if (expected == null) {
      _moving = true;
      _session.showOnlyTo(null);
      _moving = false;
      feedback = null;
      notifyListeners();
      return;
    }
    if (_toMove(_frontier) == side) return;
    _reply = Timer(replyDelay, () {
      _reply = null;
      if (!_active) return;
      final next = _expected;
      if (next == null) return;
      _moveTo(next);
      _turn();
    });
    notifyListeners();
  }

  /// Another game or document on the board ends the session.
  void _documentChanged() {
    if (_moving) return;
    if (setting && !canOffer) {
      setting = false;
      notifyListeners();
    }
    if (!_active) return;
    if (_gameNow != _game || (!finished && _session.shownTo != _frontier)) {
      stop();
    }
  }

  @override
  void dispose() {
    _reply?.cancel();
    _session.removeListener(_documentChanged);
    super.dispose();
  }
}

String _pieceOf(String san) {
  if (san.startsWith('O-O')) return 'king (castle)';
  return switch (san.isEmpty ? '' : san[0]) {
    'K' => 'king',
    'Q' => 'queen',
    'R' => 'rook',
    'B' => 'bishop',
    'N' => 'knight',
    _ => 'pawn',
  };
}
