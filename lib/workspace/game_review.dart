import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_edit.dart';
import '../chess/pgn/game_review.dart';
import '../chess/pgn/game_tree.dart';
import '../diagnostics/log.dart';
import '../engines/engine.dart';
import '../engines/engine_line.dart';
import '../engines/engine_supervisor.dart';
import '../engines/fixed_depth.dart';
import 'document_session.dart';
import 'engine_jobs.dart';
import 'latest.dart';

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
  final _reviews = Latest();
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
    if (running && identical(session.chapter, _chapter)) {
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
    _reviews.cancel();
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
    final ticket = _reviews.begin();
    final requestedDepth = depth;
    _chapter = chapter;
    running = true;
    completed = 0;
    total = positions.length;
    problem = null;
    _values.clear();
    notifyListeners();
    bool current() => ticket.current && identical(session.chapter, chapter);
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

  /// While every game of the file is being reviewed: which one of how many.
  ({int game, int of})? batch;

  /// The games of the open file a review of them all would cover: each one
  /// read whole, with moves, that carries no review yet.
  List<int> get unreviewedGames {
    final chapter = session.chapter;
    if (chapter == null || chapter.lines.length < 2) return const [];
    return [
      for (final (index, line) in chapter.lines.indexed)
        if (line.isWhole &&
            line.tree != null &&
            line.tree!.children.isNotEmpty &&
            !hasReview(line.tree!))
          index,
    ];
  }

  /// Whether every game can be reviewed now: the review writes into each,
  /// so the file must take edits and the switch must be on.
  bool get canReviewAll =>
      !running &&
      annotate &&
      session.readOnly == null &&
      session.shownTo == null &&
      unreviewedGames.isNotEmpty;

  /// Reviews every game of the open file that has no review, one after
  /// another, writing each into its game as it ends: one undoable edit per
  /// game. Moving between the games goes on while it runs; another file, an
  /// edit to a game's main line or Stop ends it, keeping what was written.
  Future<void> startAll() async {
    if (_disposed || running) return;
    session.snapshot();
    final source = session.source;
    final chapter = session.chapter;
    if (source == null || chapter == null) return;
    final games = [
      for (final index in unreviewedGames)
        (index: index, fens: _mainlineFens(chapter.lines[index].tree!)),
    ];
    if (games.isEmpty) return;
    if (!_jobs.take(this, 'Reviewing the games', kind: EngineJobKind.review)) {
      problem = _jobs.blockingMessage;
      notifyListeners();
      return;
    }
    final ticket = _reviews.begin();
    final requestedDepth = depth;
    running = true;
    problem = null;
    // Not one game's review: moving to another game does not end it.
    _chapter = null;
    bool current() => ticket.current && session.source == source;
    try {
      final started = await launch();
      if (started case StartFailed(:final reason)) throw EngineFailure(reason);
      final engine = _engine = (started as Started).engine;
      for (final (number, game) in games.indexed) {
        if (!current()) return;
        batch = (game: number + 1, of: games.length);
        completed = 0;
        total = game.fens.length;
        notifyListeners();
        final values = <ReviewValue>[];
        for (final fen in game.fens) {
          if (!current()) return;
          values.add(await _evaluate(engine, fen, requestedDepth));
          completed++;
          notifyListeners();
        }
        if (!current()) return;
        _applying = true;
        try {
          problem = session.apply(
            (now) => _sameMainline(now, game.index, game.fens)
                ? annotateGame(now, values, game: game.index)
                : const ChapterUnchanged(),
          );
        } finally {
          _applying = false;
        }
      }
    } on Object catch (error) {
      if (current()) {
        log.w('review every game', error);
        problem = 'The review of the games could not finish: $error';
      }
    } finally {
      batch = null;
      _search = null;
      final engine = _engine;
      _engine = null;
      try {
        await engine?.quit();
      } on Object catch (error) {
        log.w('close game review engine', error);
      }
      running = false;
      _jobs.release(this);
      if (!_disposed) notifyListeners();
    }
  }

  /// Whether game [index] of [chapter] still has the main line [fens] were
  /// read from: a review of positions the game no longer reaches is not
  /// written into it.
  static bool _sameMainline(Chapter chapter, int index, List<Fen> fens) {
    final tree = index < chapter.lines.length
        ? chapter.lines[index].tree
        : null;
    if (tree == null) return false;
    final now = _mainlineFens(tree);
    if (now.length != fens.length) return false;
    for (var ply = 0; ply < now.length; ply++) {
      if (now[ply].position != fens[ply].position) return false;
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
    _reviews.close();
    stop();
    session.anyChange.removeListener(_follow);
    super.dispose();
  }
}
