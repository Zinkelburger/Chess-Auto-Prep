import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:dartchess/dartchess.dart' show Side;

import '../../chess/pv_text.dart';
import '../../engines/engine.dart';
import '../../engines/engine_line.dart';
import '../../engines/engine_supervisor.dart';
import '../../engines/fixed_depth.dart';
import 'player_analysis.dart';
import 'player_games.dart';

final class PlayerWeakness {
  const PlayerWeakness(this.position, this.score, this.line, this.unseen);
  final PlayerPosition position;

  /// From the player's perspective. Negative means a chance for us.
  final Score score;
  final List<String> line;
  final bool unseen;
  String get title =>
      unseen ? 'Strong reply absent from these games' : 'Unfavourable position';
  String get continuation => pvText(position.fen, line);
}

/// Finite engine work over a frozen player/colour corpus. Ordinary analysis
/// keeps its own engine; stopping this job never stops the board's engine.
final class PlayerHunt extends ChangeNotifier {
  PlayerHunt(this.analysis, this.launch) {
    analysis.addListener(_inputsChanged);
  }
  final PlayerAnalysis analysis;
  final Future<EngineStart> Function() launch;
  Engine? _engine;
  Search? _search;
  bool running = false, _disposed = false;
  int _ticket = 0, done = 0, total = 0;
  int depth = 14, limit = 100;
  String? error;
  List<PlayerWeakness> findings = [];
  PlayerCorpus? _corpus;
  Side? _side;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _inputsChanged() {
    if (!identical(_corpus, analysis.corpus) ||
        _side != analysis.side ||
        analysis.busy) {
      stop();
      findings = [];
      done = total = 0;
      _corpus = analysis.corpus;
      _side = analysis.side;
      _notify();
    }
  }

  Future<void> start() async {
    if (running || analysis.busy || analysis.corpus == null) return;
    _corpus = analysis.corpus;
    _side = analysis.side;
    final ticket = ++_ticket;
    running = true;
    done = 0;
    error = null;
    findings = [];
    final candidates = analysis.positions.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    final positions = candidates.take(limit).toList();
    total = positions.length;
    _notify();
    bool current() => !_disposed && ticket == _ticket;
    Engine? engine;
    try {
      if (!await analysis.currentSources())
        throw StateError('Saved games changed. Reload the player first.');
      if (!current()) return;
      switch (await launch()) {
        case Started(engine: final started):
          engine = started;
        case StartFailed(:final reason):
          throw StateError(reason);
      }
      if (!current()) return;
      _engine = engine;
      final scores = <String, int>{};
      for (final position in positions) {
        if (!current()) return;
        await _evaluate(engine, position, scores, ticket);
        done++;
        _notify();
      }
      if (!await analysis.currentSources()) {
        findings = [];
        throw StateError(
          'Games changed during analysis. Reload and run again.',
        );
      }
      if (!current()) return;
      analysis.evals.addAll(scores);
      analysis.changed();
    } on Object catch (e) {
      if (current()) error = '$e';
    } finally {
      await engine?.quit();
      if (current()) {
        running = false;
        _engine = null;
        _search = null;
        _notify();
      }
    }
  }

  Future<void> _evaluate(
    Engine engine,
    PlayerPosition position,
    Map<String, int> scores,
    int ticket,
  ) async {
    final search = engine.analyse(position.fen, multiPv: 1, depth: depth);
    _search = search;
    EngineLine? best;
    await for (final line in search.lines) {
      if (line.multiPv == 1) best = line;
    }
    if (_disposed || ticket != _ticket) return;
    if (best == null ||
        (best.depth < depth && best.score is! MateIn && best.pv.isNotEmpty))
      throw StateError(
        'The engine stopped before reaching the requested depth.',
      );
    final ourTurn = position.fen.whiteToMove == (position.side == Side.white);
    final score = ourTurn ? best.score : best.score.negated;
    final cp = packedCp(score).cp;
    scores[position.key] = cp;
    // Presence is taken from the full corpus, while frequency is from the
    // filtered view. Missing evidence is never called a forced refutation.
    final original = _corpus!.positions.firstWhere(
      (p) => p.key == position.key,
    );
    final unseen =
        !ourTurn &&
        best.pv.isNotEmpty &&
        !original.moves.containsKey(best.pv.first);
    if (cp <= -50 || (unseen && cp <= 30)) {
      findings.add(PlayerWeakness(position, score, best.pv, unseen));
      findings.sort(
        (a, b) => (b.position.count * (-packedCp(b.score).cp + 100)).compareTo(
          a.position.count * (-packedCp(a.score).cp + 100),
        ),
      );
    }
  }

  void stop() {
    _ticket++;
    final search = _search, engine = _engine;
    _search = null;
    _engine = null;
    running = false;
    if (search != null) unawaited(search.stop());
    if (engine != null) unawaited(engine.quit());
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    analysis.removeListener(_inputsChanged);
    stop();
    super.dispose();
  }
}
