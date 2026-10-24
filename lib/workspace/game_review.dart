import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/pgn/game_review.dart';
import '../chess/pgn/game_tree.dart';
import '../diagnostics/log.dart';
import '../engines/engine.dart';
import '../engines/engine_line.dart';
import '../engines/engine_supervisor.dart';
import '../engines/fixed_depth.dart';
import 'document_session.dart';
import 'engine_jobs.dart';

/// A bounded whole-game review. Navigation to another game or an edit cancels
/// it; completed results land as one undoable edit against the exact snapshot.
///
/// [startAll] reviews every game of the open file in turn instead, while the
/// user reads on: each game's review is written into it as it finishes, one
/// undoable edit each, unless the game's main line changed meanwhile. A game
/// already reviewed is passed over, so a review stopped part way goes on
/// where it left off. Only another file stops it.
///
/// Whether the review writes into the game is the user's choice, [annotate]:
/// turning it off takes the review's evaluations, marks and lines back out,
/// turning it on puts the last review back in. The graph shows either way.
///
/// A review is one of the heavy engine jobs ([EngineJobs]): it does not start
/// while another holds the machine, and none starts while it runs.
final class GameReview extends ChangeNotifier {
  GameReview({
    required this.session,
    required this._jobs,
    required this.launch,
  }) {
    session.anyChange.addListener(_follow);
  }
  final DocumentSession session;
  final EngineJobs _jobs;
  final Future<EngineStart> Function() launch;
  Engine? _engine;
  Search? _search;
  Object? _chapter;
  bool _disposed = false;
  bool _applying = false;
  int _ticket = 0;
  bool running = false;
  int completed = 0;
  int total = 0;
  String? problem;
  int depth = 14;
  final List<ReviewValue> _values = [];

  /// While every game of the file is reviewed: the game being reviewed,
  /// from 0, and how many the file has.
  ({int game, int games})? batch;
  String? _batchPath;

  /// Whether a finished review is written into the game.
  bool _annotate = true;

  /// The last finished review, for the game it was of, while that game's
  /// main line is still the one it reviewed.
  ({Object? game, List<Fen> fens, List<ReviewValue> values})? _last;

  Object? get _game => (session.source, session.game);

  List<ReviewValue>? get _lastHere {
    final last = _last;
    final tree = session.tree;
    if (last == null || last.game != _game || tree == null) return null;
    return _sameLine(_mainlineFens(tree), last.fens) ? last.values : null;
  }

  List<MoveNode> get _mainline {
    final result = <MoveNode>[];
    var move = session.tree?.children.firstOrNull;
    while (move != null) {
      result.add(move);
      move = move.children.firstOrNull;
    }
    return result;
  }

  /// Positions on the main line: the start, then after each move.
  int get positions => session.tree == null ? 0 : _mainline.length + 1;

  List<ReviewValue?> get values {
    final batch = this.batch;
    if (running &&
        (batch == null
            ? identical(session.chapter, _chapter)
            : batch.game == session.game)) {
      return List.unmodifiable(_values);
    }
    final tree = session.tree;
    if (tree == null) return const [];
    final List<ReviewValue?> stored = [
      storedReviewValue(tree.rootComment),
      for (final move in _mainline) storedReviewValue(move.comment),
    ];
    return _lastHere ?? stored;
  }

  /// Whether the game on the board carries this review's annotations.
  bool get annotated {
    final tree = session.tree;
    return tree != null && hasReview(tree);
  }

  /// What the switch shows: the game's own state once it has a review in
  /// it, otherwise what the next review will do.
  bool get annotate => annotated || _annotate;

  /// Whether the switch can change anything now.
  bool get canAnnotate =>
      !running &&
      session.readOnly == null &&
      (annotated || _lastHere != null || !values.any((v) => v != null));

  void setAnnotate(bool on) {
    _annotate = on;
    problem = null;
    if (!on && annotated) {
      problem = session.apply(removeReview);
    } else if (on && !annotated) {
      if (_lastHere case final values?) {
        problem = session.apply((now) => annotateGame(now, values));
      }
    }
    notifyListeners();
  }

  /// Whether every game of the open file can be reviewed now: a file of
  /// more than one game that this app may write, all of it on view.
  bool get canReviewAll =>
      !running &&
      session.readOnly == null &&
      session.shownTo == null &&
      (session.gameCount ?? 0) > 1;

  void _follow() {
    if (batch != null && session.source?.path != _batchPath) stop();
    if (!_applying &&
        _chapter != null &&
        !identical(_chapter, session.chapter)) {
      stop();
      _chapter = null;
      problem = null;
    }
    if (!_disposed) notifyListeners();
  }

  void stop() {
    _ticket++;
    final search = _search;
    if (search != null) unawaited(search.stop());
  }

  Future<void> start() async {
    if (_disposed || running) return;
    session.snapshot();
    final chapter = session.chapter;
    if (chapter == null || session.shownTo != null) return;
    if (chapter.game == null && chapter.lines.length != 1) {
      problem = 'Open a single game to review.';
      notifyListeners();
      return;
    }
    final positions = _mainlineFens(chapter.tree);
    if (!_jobs.take(this, 'Reviewing the game', kind: EngineJobKind.review)) {
      problem = _jobs.blockingMessage;
      notifyListeners();
      return;
    }
    final ticket = ++_ticket;
    final requestedDepth = depth;
    _chapter = chapter;
    running = true;
    completed = 0;
    total = positions.length;
    problem = null;
    _values.clear();
    notifyListeners();
    bool current() =>
        !_disposed && ticket == _ticket && identical(session.chapter, chapter);
    try {
      final started = await launch();
      if (started case StartFailed(:final reason)) throw EngineFailure(reason);
      final engine = _engine = (started as Started).engine;
      if (!current()) return;
      for (final fen in positions) {
        if (!current()) return;
        final value = await _evaluate(engine, fen, requestedDepth);
        if (!current()) return;
        _values.add(value);
        completed++;
        notifyListeners();
      }
      if (!current()) return;
      final values = List<ReviewValue>.unmodifiable(_values);
      _last = (game: _game, fens: positions, values: values);
      _applying = true;
      try {
        problem = session.readOnly != null
            ? null
            : _annotate
            ? session.apply((now) => annotateGame(now, values))
            : session.apply(removeReview);
        _chapter = session.chapter;
      } finally {
        _applying = false;
      }
    } on Object catch (error) {
      if (current()) {
        log.w('review game', error);
        problem = 'Game review could not finish: $error';
      }
    } finally {
      await _finish();
    }
  }

  /// The engine closed and the machine given back, whichever review ran.
  Future<void> _finish() async {
    _search = null;
    final engine = _engine;
    _engine = null;
    try {
      await engine?.quit();
    } on Object catch (error) {
      log.w('close game review engine', error);
      if (!_disposed) problem = 'The review engine could not close cleanly.';
    }
    batch = null;
    _batchPath = null;
    running = false;
    // The engine is free again, so another job may start.
    _jobs.release(this);
    if (!_disposed) notifyListeners();
  }

  /// Reviews every game of the open file, from the first, as the class
  /// comment says.
  Future<void> startAll() async {
    if (_disposed || !canReviewAll) return;
    session.snapshot();
    final path = session.source?.path;
    final games = session.chapter?.lines.length ?? 0;
    if (path == null || games == 0) return;
    if (!_jobs.take(this, 'Reviewing every game', kind: EngineJobKind.review)) {
      problem = _jobs.blockingMessage;
      notifyListeners();
      return;
    }
    final ticket = ++_ticket;
    final requestedDepth = depth;
    _batchPath = path;
    _chapter = null;
    running = true;
    problem = null;
    batch = (game: 0, games: games);
    notifyListeners();
    bool current() =>
        !_disposed && ticket == _ticket && session.source?.path == path;
    GameTree? treeOf(int game) {
      final lines = session.chapter?.lines;
      final line = lines == null || game >= lines.length ? null : lines[game];
      return line != null && line.isWhole ? line.tree : null;
    }

    try {
      final started = await launch();
      if (started case StartFailed(:final reason)) throw EngineFailure(reason);
      final engine = _engine = (started as Started).engine;
      for (var game = 0; game < games; game++) {
        if (!current()) return;
        final tree = treeOf(game);
        if (tree == null || hasReview(tree)) continue;
        final positions = _mainlineFens(tree);
        batch = (game: game, games: games);
        completed = 0;
        total = positions.length;
        _values.clear();
        notifyListeners();
        for (final fen in positions) {
          if (!current()) return;
          _values.add(await _evaluate(engine, fen, requestedDepth));
          completed++;
          notifyListeners();
        }
        if (!current()) return;
        // An edit to the game meanwhile leaves it as the user made it: the
        // review is of moves it may no longer have.
        final now = treeOf(game);
        if (now == null || !_sameLine(_mainlineFens(now), positions)) continue;
        final values = List<ReviewValue>.unmodifiable(_values);
        _applying = true;
        try {
          problem = session.apply((now) => annotateGameAt(now, game, values));
        } finally {
          _applying = false;
        }
        if (problem != null) return;
      }
    } on Object catch (error) {
      if (current()) {
        log.w('review every game', error);
        problem = 'Game review could not finish: $error';
      }
    } finally {
      await _finish();
    }
  }

  static bool _sameLine(List<Fen> a, List<Fen> b) {
    if (a.length != b.length) return false;
    for (var ply = 0; ply < a.length; ply++) {
      if (a[ply].position != b[ply].position) return false;
    }
    return true;
  }

  /// The start, then the position after each move of [tree]'s main line.
  static List<Fen> _mainlineFens(GameTree tree) {
    final positions = <Fen>[tree.rootFen];
    var move = tree.children.firstOrNull;
    while (move != null) {
      positions.add(move.fen);
      move = move.children.firstOrNull;
    }
    return positions;
  }

  Future<ReviewValue> _evaluate(Engine engine, Fen fen, int depth) async {
    final search = _search = engine.analyse(fen, multiPv: 1, depth: depth);
    EngineLine? verdict;
    await for (final line in search.lines) {
      if (line.multiPv == 1) verdict = line;
    }
    _search = null;
    if (verdict == null ||
        (verdict.depth < depth &&
            verdict.score is! MateIn &&
            verdict.pv.isNotEmpty)) {
      throw const EngineFailure(
        'The engine stopped before finishing a position.',
      );
    }
    final white = fen.whiteToMove ? verdict.score : verdict.score.negated;
    final eval = white is MateIn
        ? '#${white.mating ? '' : '-'}${white.moves.abs()}'
        : white.text;
    return ReviewValue(packedCp(white).cp, eval, verdict.pv);
  }

  void goTo(int ply) => session.cursor.goTo(NodePath.of(List.filled(ply, 0)));

  @override
  void dispose() {
    _disposed = true;
    stop();
    session.anyChange.removeListener(_follow);
    super.dispose();
  }
}
