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
/// Whether the review writes into the game is the user's choice, [annotate]:
/// turning it off takes the review's evaluations, marks and lines back out,
/// turning it on puts the last review back in. The graph shows either way.
///
/// A review is one of the heavy engine jobs ([EngineJobs]): it does not start
/// while another holds the machine, and none starts while it runs.
final class GameReview extends ChangeNotifier {
  GameReview({
    required this.session,
    required EngineJobs jobs,
    required this.launch,
  }) : _jobs = jobs {
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
    final fens = _mainlineFens(tree);
    if (fens.length != last.fens.length) return null;
    for (var ply = 0; ply < fens.length; ply++) {
      if (fens[ply].position != last.fens[ply].position) return null;
    }
    return last.values;
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
    if (running && identical(session.chapter, _chapter))
      return List.unmodifiable(_values);
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

  void _follow() {
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
    if (!_jobs.take(this, 'Reviewing the game')) {
      problem = 'Wait for the engine job under way to finish.';
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
      _search = null;
      final engine = _engine;
      _engine = null;
      try {
        await engine?.quit();
      } on Object catch (error) {
        log.w('close game review engine', error);
        if (!_disposed) problem = 'The review engine could not close cleanly.';
      }
      running = false;
      // The engine is free again, so another job may start.
      _jobs.release(this);
      if (!_disposed) notifyListeners();
    }
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

  void goTo(int ply) => session.goTo(NodePath.of(List.filled(ply, 0)));

  @override
  void dispose() {
    _disposed = true;
    stop();
    session.anyChange.removeListener(_follow);
    super.dispose();
  }
}
