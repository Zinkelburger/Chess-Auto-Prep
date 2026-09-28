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
import 'engine_analysis.dart';

/// A bounded whole-game review. Navigation to another game or an edit cancels
/// it; completed results land as one undoable edit against the exact snapshot.
final class GameReview extends ChangeNotifier {
  GameReview({
    required this.session,
    required this.analysis,
    required this.launch,
  }) {
    session.anyChange.addListener(_follow);
  }
  final DocumentSession session;
  final EngineAnalysis analysis;
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

  List<ReviewValue?> get values {
    if (running && identical(session.chapter, _chapter))
      return List.unmodifiable(_values);
    final tree = session.tree;
    if (tree == null) return const [];
    final result = <ReviewValue?>[storedReviewValue(tree.rootComment)];
    var move = tree.children.firstOrNull;
    while (move != null) {
      result.add(storedReviewValue(move.comment));
      move = move.children.firstOrNull;
    }
    return result;
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
    final tree = chapter.tree;
    final positions = <Fen>[tree.rootFen];
    var move = tree.children.firstOrNull;
    while (move != null) {
      positions.add(move.fen);
      move = move.children.firstOrNull;
    }
    final ticket = ++_ticket;
    final requestedDepth = depth;
    _chapter = chapter;
    running = true;
    completed = 0;
    total = positions.length;
    problem = null;
    _values.clear();
    analysis.pause(this, 'Reviewing the game');
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
      _applying = true;
      try {
        problem = session.apply((now) => annotateGame(now, _values));
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
      if (!_disposed) {
        analysis.resume(this);
        notifyListeners();
      }
    }
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
