import 'dart:async';

import 'package:dartchess/dartchess.dart' show Move, Side;
import 'package:flutter/foundation.dart';

import '../chess/pgn/chapter_edits.dart' show playedAlready;
import '../chess/pgn/game_tree.dart';
import '../chess/fen.dart';
import '../chess/pgn/game_text.dart';
import '../chess/pgn/solitaire_record.dart';
import '../chess/pgn/study.dart';
import '../chess/pgn/tree_edit.dart';
import '../chess/pv_text.dart';
import '../engines/engine_supervisor.dart';
import '../engines/solitaire_evaluator.dart';
import 'document_session.dart';
import 'engine_analysis.dart';
import 'engine_jobs.dart';
import 'study_drafts.dart';

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
  Solitaire(
    this._session,
    this._analysis, {
    Future<EngineStart> Function()? launch,
    EngineJobs? jobs,
  }) : _launch = launch,
       _jobs = jobs {
    _session.addListener(_documentChanged);
    _session.cursorListenable.addListener(_cursorChanged);
  }

  static const replyDelay = Duration(milliseconds: 400);

  final DocumentSession _session;
  final EngineAnalysis _analysis;
  final Future<EngineStart> Function()? _launch;
  final EngineJobs? _jobs;
  SolitaireEvaluator? _evaluator;
  int _ticket = 0;
  bool _disposed = false;
  bool preparing = false;
  bool checking = false;
  String? problem;
  bool betterMove = false;
  int crowns = 0;
  int total = 0;
  final List<SolitaireAttempt> _attempts = [];
  List<SolitaireAttempt> get attempts => List.unmodifiable(_attempts);
  GameTree? _sourceTree;
  ChapterDraft? _sourceDraft;
  GameTree? _record;

  bool get waitingForReply => _reply != null;
  bool get atCurrentMove => _session.cursor == _frontier;
  bool get canGuess =>
      active &&
      !finished &&
      !checking &&
      !waitingForReply &&
      atCurrentMove &&
      _toMove(_frontier) == side;
  bool get canHint => canGuess && hint == null;
  bool get canReveal =>
      active &&
      !finished &&
      !waitingForReply &&
      atCurrentMove &&
      _toMove(_frontier) == side;
  int get accepted => guessed - revealed;

  /// A separate, immutable record: only the revealed prefix during play,
  /// and the whole annotated game at completion. Never an edit to the file.
  GameTree? get record {
    final source = _sourceTree;
    if (source == null) return null;
    return _record ??= finished
        ? solitaireReview(source, _attempts)
        : solitaireProgress(source, _attempts, _frontier);
  }

  ChapterDraft? get reviewDraft {
    final draft = _sourceDraft;
    final tree = record;
    if (!finished || draft == null || tree == null) return null;
    return ChapterDraft(
      name: '${draft.name} · Solitaire',
      orientation: side,
      moves: tree,
      tags: draft.tags,
      result: draft.result,
    );
  }

  String? get reviewPgn {
    final draft = reviewDraft;
    if (draft == null) return null;
    final root = draft.moves.rootFen;
    final tags = [
      for (final tag in draft.tags)
        if (tag is! PgnTag || (tag.key != 'FEN' && tag.key != 'SetUp')) tag,
      if (root != Fen.initial) ...[
        const PgnTag('SetUp', '1'),
        PgnTag('FEN', root.value),
      ],
    ];
    return writeGameText(
      tags,
      draft.moves,
      terminator: draft.result ?? '*',
      separator: '\n',
    );
  }

  void returnToGuess() => _session.goTo(_frontier);

  /// The shared reader previews an attempt on the same board without
  /// installing its tree as the user's document.
  void inspect(NodePath path) {
    final tree = record;
    if (tree == null) return;
    if (!finished) {
      if (_frontier.startsWith(path)) _session.goTo(path);
      return;
    }
    if (path.isRoot) return _session.goTo(path);
    final moves = pvMoves(
      tree.rootFen,
      tree.lineTo(path).map((node) => node.uci).toList(),
    );
    if (moves.isNotEmpty) {
      _session.showCommentLine(const NodePath.root(), moves, moves.length - 1);
    }
  }

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
    if (_evaluator != null) {
      problem = 'The previous engine check is closing. Try again.';
      notifyListeners();
      return;
    }
    problem = null;
    final launch = _launch;
    if (launch != null) {
      final evaluator = SolitaireEvaluator(launch);
      if (_jobs?.take(
            evaluator,
            'Checking Solitaire moves',
            kind: EngineJobKind.solitaire,
          ) ==
          false) {
        problem = _jobs!.blockingMessage;
        notifyListeners();
        return;
      }
      _evaluator = evaluator;
    }
    _ticket++;
    _sourceTree = _session.tree;
    _sourceDraft = gameDraft(_session);
    _attempts.clear();
    _record = null;
    total = _countFrom(from);
    crowns = 0;
    betterMove = false;
    checking = preparing = false;
    if (_session.orientation != side) _session.flip();
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
    _ticket++;
    checking = preparing = false;
    unawaited(_closeEvaluator());
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
    if (expected == null || !canGuess) return true;
    final chapter = _session.chapter;
    if (chapter == null) return true;
    final move = Move.parse(uci);
    final node = move == null
        ? null
        : moveNode(chapter.tree.fenAt(_frontier), move);
    if (node == null) return true;
    uci = node.uci;
    final evaluator = _evaluator;
    if (evaluator != null) {
      checking = true;
      notifyListeners();
      unawaited(_check(evaluator, expected, uci));
      return true;
    }
    final reached = playedAlready(chapter, at: _frontier, uci: uci);
    _answer(
      expected,
      uci,
      reached == expected
          ? SolitaireOutcome.gameMove
          : SolitaireOutcome.mistake,
    );
    return true;
  }

  Future<void> _check(
    SolitaireEvaluator evaluator,
    NodePath expected,
    String uci,
  ) async {
    final ticket = _ticket;
    final fen = _sourceTree!.fenAt(_frontier);
    final gameUci = _sourceTree!.nodeAt(expected)!.uci;
    final verdict = await evaluator.compare(fen, gameUci, uci);
    if (_disposed ||
        ticket != _ticket ||
        !active ||
        _expected != expected ||
        evaluator != _evaluator)
      return;
    checking = false;
    switch (verdict) {
      case SolitaireScored(
        :final accepted,
        :final better,
        :final gameScore,
        :final guessScore,
      ):
        problem = null;
        _answer(
          expected,
          uci,
          uci == gameUci
              ? SolitaireOutcome.gameMove
              : !accepted
              ? SolitaireOutcome.mistake
              : better
              ? SolitaireOutcome.betterMove
              : SolitaireOutcome.goodMove,
          evaluation: guessScore.forWhite(whiteToMove: side == Side.white).text,
          gameEvaluation: gameScore
              .forWhite(whiteToMove: side == Side.white)
              .text,
        );
      case SolitaireUnavailable():
        problem =
            'Engine check unavailable. Retry your move, play the game '
            'move, or give up this move.';
        if (uci == gameUci) {
          _answer(expected, uci, SolitaireOutcome.gameMove);
        } else {
          feedback = 'Your move has not been scored.';
          lastWrong = false;
          notifyListeners();
        }
    }
  }

  void _answer(
    NodePath expected,
    String uci,
    SolitaireOutcome outcome, {
    String? evaluation,
    String? gameEvaluation,
  }) {
    final san = pvMoves(_sourceTree!.fenAt(_frontier), [uci]).first.san;
    _attempts.add(
      SolitaireAttempt(
        at: _frontier,
        uci: uci,
        outcome: outcome,
        hinted: _hintUsed,
        evaluation: evaluation,
        gameEvaluation: gameEvaluation,
      ),
    );
    _record = null;
    betterMove = outcome == SolitaireOutcome.betterMove;
    if (outcome != SolitaireOutcome.mistake) {
      guessed++;
      if (betterMove) crowns++;
      if (_tries.isEmpty && !_hintUsed) firstTry++;
      if (_tries.isNotEmpty || _hintUsed) _miss(expected);
      feedback = switch (outcome) {
        SolitaireOutcome.betterMove => '$san — better than the game move!',
        SolitaireOutcome.goodMove =>
          '$san is a good move. The game played ${_san(expected)}.',
        _ => 'Correct: ${_san(expected)}',
      };
      lastWrong = false;
      _moveTo(expected);
      _turn();
    } else {
      if (!_tries.contains(san)) _tries = [..._tries, san];
      feedback = _launch == null
          ? 'Not the game move. Try again.'
          : '$san loses too much compared with the game move. Try again.';
      lastWrong = true;
      notifyListeners();
    }
  }

  /// Names the piece that moves.
  void showHint() {
    final expected = _expected;
    if (expected == null || !canHint) return;
    final san = _san(expected);
    hint = 'Move your ${_pieceOf(san)}.';
    if (!_hintUsed) hinted++;
    _hintUsed = true;
    notifyListeners();
  }

  /// Plays the game move for the user.
  void reveal() {
    final expected = _expected;
    if (expected == null || !canReveal) return;
    _ticket++;
    preparing = checking = false;
    _attempts.add(
      SolitaireAttempt(
        at: _frontier,
        uci: _sourceTree!.nodeAt(expected)!.uci,
        outcome: SolitaireOutcome.revealed,
        hinted: _hintUsed,
      ),
    );
    betterMove = false;
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
    _record = null;
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
      _ticket++;
      preparing = false;
      _record = null;
      unawaited(_closeEvaluator());
      _moving = true;
      _session.showOnlyTo(null);
      _moving = false;
      notifyListeners();
      return;
    }
    if (_toMove(_frontier) == side) {
      unawaited(_prepare());
      return;
    }
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
    if (_gameNow != _game ||
        !identical(_sourceTree, _session.tree) ||
        (!finished && _session.shownTo != _frontier)) {
      stop();
    }
  }

  int _countFrom(NodePath from) {
    var at = from;
    var count = 0;
    while (_session.tree?.nodeAt(at.mainChild) != null) {
      if (_toMove(at) == side) count++;
      at = at.mainChild;
    }
    return count;
  }

  Future<void> _prepare() async {
    final evaluator = _evaluator;
    final expected = _expected;
    if (evaluator == null || expected == null) return;
    final ticket = _ticket;
    final at = _frontier;
    preparing = true;
    notifyListeners();
    final ready = await evaluator.prepare(
      _sourceTree!.fenAt(at),
      _sourceTree!.nodeAt(expected)!.uci,
    );
    if (_disposed || ticket != _ticket || at != _frontier || !active) return;
    preparing = false;
    problem = ready
        ? null
        : 'Engine check unavailable. You can still find the '
              'game move or give up this move.';
    notifyListeners();
  }

  Future<void> _closeEvaluator() async {
    final evaluator = _evaluator;
    if (evaluator == null) return;
    await evaluator.cancel();
    _jobs?.release(evaluator);
    if (_evaluator == evaluator) _evaluator = null;
    if (!_disposed) notifyListeners();
  }

  void _cursorChanged() {
    if (_active && !_moving) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticket++;
    _reply?.cancel();
    unawaited(_closeEvaluator());
    _session.removeListener(_documentChanged);
    _session.cursorListenable.removeListener(_cursorChanged);
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
