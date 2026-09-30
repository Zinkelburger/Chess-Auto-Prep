import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../storage/player_reports.dart';

import 'package:flutter/foundation.dart';
import 'package:dartchess/dartchess.dart' show Side;

import '../../chess/pv_text.dart';
import '../../chess/fen.dart';
import '../../chess/generation/eval.dart';
import '../../engines/maia/move_policy.dart';
import 'practical_probe.dart';
import '../../engines/engine.dart';
import '../../engines/engine_line.dart';
import '../../engines/engine_supervisor.dart';
import '../../engines/fixed_depth.dart';
import 'player_analysis.dart';
import 'player_games.dart';

final class PlayerWeakness {
  const PlayerWeakness(
    this.position,
    this.score,
    this.line,
    this.unseen, {
    this.practicalGain,
  });
  final double? practicalGain;
  final PlayerPosition position;

  /// From the player's perspective. Negative means a chance for us.
  final Score score;
  final List<String> line;
  final bool unseen;
  String get title =>
      unseen ? 'Strong reply absent from these games' : 'Unfavourable position';
  String get continuation => pvText(position.fen, line);

  /// The position and the reply: the same across runs and settings, so a
  /// dismissal outlives the report it was made on.
  String get key => '${position.key} ${line.firstOrNull ?? ''}';
}

/// Finite engine work over a frozen player/colour corpus. Ordinary analysis
/// keeps its own engine; stopping this job never stops the board's engine.
final class PlayerHunt extends ChangeNotifier {
  PlayerHunt(this.analysis, this.launch, {this.model, PlayerReports? reports})
    : reports = reports ?? PlayerReports() {
    analysis.addListener(_inputsChanged);
  }
  final PlayerAnalysis analysis;
  final MovePolicy? model;
  final PlayerReports reports;
  Object? _inputs;
  String? _activeReportKey;
  Map<String, int> _scores = {};
  bool _practical = false;
  int _rating = 1800, _probes = 10, _depth = 14, _limit = 100;
  int _probed = 0;
  String? practicalWarning;
  final Future<EngineStart> Function() launch;
  Engine? _engine;
  Search? _search;
  bool running = false, _disposed = false;
  int _ticket = 0, done = 0, total = 0;
  String? error;
  List<PlayerWeakness> findings = [];
  PlayerCorpus? _corpus;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  int get depth => _depth;
  int get limit => _limit;
  bool get practical => _practical;
  int get rating => _rating;
  int get probes => _probes;

  /// Changes the settings of the next run, and drops the findings of other
  /// settings. Nothing changes while a run is going.
  void configure({
    int? depth,
    int? limit,
    bool? practical,
    int? rating,
    int? probes,
  }) {
    if (running) return;
    _depth = depth ?? _depth;
    _limit = limit ?? _limit;
    _practical = practical ?? _practical;
    _rating = rating ?? _rating;
    _probes = probes ?? _probes;
    _inputsChanged();
  }

  Object get _inputKey => (
    analysis.corpus,
    analysis.side,
    analysis.query,
    analysis.recentDays,
    analysis.speeds.join(','),
    analysis.minGames,
    analysis.minPly,
    depth,
    limit,
    practical,
    rating,
    probes,
  );
  String get _reportKey => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            analysis.fingerprint,
            analysis.side.name,
            analysis.query,
            analysis.recentDays,
            [for (final speed in analysis.speeds) speed.name]..sort(),
            analysis.minGames,
            analysis.minPly,
            depth,
            limit,
            practical,
            rating,
            probes,
          ]),
        ),
      )
      .toString();
  void _inputsChanged() {
    if (_inputs == _inputKey && !analysis.busy) return;
    _inputs = _inputKey;
    stop();
    findings = [];
    analysis.evals.clear();
    _scores = {};
    done = total = 0;
    _corpus = analysis.corpus;
    if (_corpus != null && !analysis.busy) unawaited(_restore(_ticket));
    _notify();
  }

  Future<void> _restore(int ticket) async {
    final data = await reports.read(_reportKey);
    if (_disposed || ticket != _ticket || data == null || running) return;
    try {
      final positions = {for (final p in analysis.positions) p.key: p};
      final restored = <PlayerWeakness>[];
      for (final row in data['findings'] as List) {
        final value = row as Map;
        final position = positions[value['position']];
        if (position == null) continue;
        final cp = value['cp'] as int;
        restored.add(
          PlayerWeakness(
            position,
            scoreFromPacked(cp),
            (value['pv'] as List).cast<String>(),
            value['unseen'] == true,
            practicalGain: (value['practical'] as num?)?.toDouble(),
          ),
        );
      }
      findings = restored;
      done = data['done'] as int;
      total = data['total'] as int;
      analysis.evals.addAll((data['evals'] as Map).cast<String, int>());
      analysis.changed();
      _notify();
    } on Object {
      /* A derived cache can be rebuilt with Analyze. */
    }
  }

  void _keep() {
    if (_corpus == null || done == 0) return;
    final data = <String, Object?>{
      'version': 1,
      'player': analysis.player?.id,
      'done': done,
      'total': total,
      'evals': Map.of(_scores),
      'findings': [
        for (final f in findings)
          {
            'position': f.position.key,
            'cp': packedCp(f.score).cp,
            'pv': f.line,
            'unseen': f.unseen,
            'practical': f.practicalGain,
          },
      ],
    };
    final key = _activeReportKey;
    if (key == null) return;
    final writing = reports.keep(key, data);
    analysis.pending.watch(this, writing);
  }

  Future<void> start() async {
    if (running || analysis.busy || analysis.corpus == null) return;
    _corpus = analysis.corpus;
    final ticket = ++_ticket;
    _activeReportKey = _reportKey;
    _inputs = _inputKey;
    running = true;
    done = 0;
    error = null;
    findings = [];
    analysis.evals.clear();
    _probed = 0;
    practicalWarning = null;
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
      final scores = _scores = <String, int>{};
      for (final position in positions) {
        if (!current()) return;
        await _evaluate(engine, position, scores, ticket);
        if (!current()) return;
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
      // Kept before the listeners hear of it, in case one ends this run.
      _keep();
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
    final ourTurn = position.fen.whiteToMove == (position.side == Side.white);
    final lines = await _lines(
      engine,
      position.fen,
      ticket,
      multiPv: !ourTurn && practical ? 3 : 1,
    );
    if (_disposed || ticket != _ticket) return;
    final best = lines.first;
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
    if (!ourTurn) await _probe(engine, position, lines, ticket);
  }

  Future<List<EngineLine>> _lines(
    Engine engine,
    Fen fen,
    int ticket, {
    int multiPv = 1,
  }) async {
    final search = engine.analyse(fen, multiPv: multiPv, depth: depth);
    _search = search;
    final lines = <int, EngineLine>{};
    await for (final line in search.lines) {
      lines[line.multiPv] = line;
    }
    if (_disposed || ticket != _ticket) return const [];
    final best = lines[1];
    if (best == null ||
        (best.depth < depth && best.score is! MateIn && best.pv.isNotEmpty))
      throw StateError(
        'The engine stopped before reaching the requested depth.',
      );
    return [
      for (final n in lines.keys.toList()..sort())
        if (lines[n]!.depth >= depth ||
            lines[n]!.score is MateIn ||
            lines[n]!.pv.isEmpty)
          lines[n]!,
    ];
  }

  Future<void> _probe(
    Engine engine,
    PlayerPosition position,
    List<EngineLine> lines,
    int ticket,
  ) async {
    final model = this.model;
    if (!practical ||
        model == null ||
        _probed >= probes ||
        practicalWarning != null)
      return;
    _probed++;
    final best = lines.first;
    final baseline = expectedScore(packedCp(best.score));
    for (final candidate in lines) {
      if (_disposed || ticket != _ticket) return;
      if (packedCp(best.score).cp - packedCp(candidate.score).cp > 50) continue;
      try {
        final estimate = await practicalScore(
          start: position.fen,
          candidate: candidate,
          model: model,
          rating: rating,
          cancelled: () => _disposed || ticket != _ticket,
          evaluate: (fen) async =>
              (await _lines(engine, fen, ticket)).firstOrNull,
        );
        if (_disposed || ticket != _ticket) return;
        if (estimate != null && estimate > baseline + .05)
          findings.add(
            PlayerWeakness(
              position,
              candidate.score.negated,
              candidate.pv,
              false,
              practicalGain: estimate - baseline,
            ),
          );
      } on Object catch (e) {
        practicalWarning = 'Practical search skipped: $e';
        return;
      }
    }
  }

  void stop() {
    if (running) _keep();
    _activeReportKey = null;
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

Score scoreFromPacked(int cp) {
  if (cp.abs() < mateSaturationCp) return Centipawns(cp);
  if (cp == mateBaseCp) return const MateIn(0).negated;
  return MateIn((mateBaseCp - cp.abs()) * cp.sign);
}
