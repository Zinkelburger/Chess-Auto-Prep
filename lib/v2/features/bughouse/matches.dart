import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/bughouse/match.dart';
import '../../chess/bughouse/table.dart';
import '../../diagnostics/log.dart';
import '../../engines/hivemind_engine.dart';
import '../../storage/pending_writes.dart';
import '../../storage/bughouse_matches.dart';
import 'bughouse_lab.dart';
import 'match_runner.dart';
import 'table_search.dart';

/// The lab's bughouse matches: the ones on disk, the one being played, and
/// which game is on the boards.
///
/// A match runs on a Hivemind of its own, started for the run and quit
/// after it, so the lab's tables keep theirs. Each finished game is written
/// at once, so the history fills in as the match runs and a quit loses at
/// most the game in flight. `Stop` drops that game, which is why a stopped
/// match resumes at the game it was playing rather than recording it half
/// played. While the boards follow the game being played, the tables stop
/// asking the engine about every position that goes by.
final class Matches extends ChangeNotifier {
  Matches({
    required MatchStore store,
    this.pendingWrites,
    required Future<HivemindStart> Function() startEngine,
    required this.lab,
    required this.tables,
    DateTime Function() now = DateTime.now,
  }) : _store = store,
       _startEngine = startEngine,
       _now = now;

  final PendingWrites? pendingWrites;
  bool _stopAsked = false;
  final MatchStore _store;
  final Future<HivemindStart> Function() _startEngine;
  final BughouseLab lab;
  final TableSearch tables;
  final DateTime Function() _now;

  List<StoredMatch> _matches = const [];
  String? _selected;
  _Run? _run;
  bool _following = false;
  int? _openGame;
  MatchProblem? _problem;
  bool _starting = false;
  bool _disposed = false;

  /// Newest first.
  List<StoredMatch> get matches => _matches;

  /// The match shown under the history: the one chosen, else the newest.
  StoredMatch? get selected =>
      _matches.where((m) => m.id == _selected).firstOrNull ??
      _matches.firstOrNull;

  /// The match being played and its game in flight (1-based), while one is.
  ({String id, int game})? get running => switch (_run) {
    final run? => (id: run.id, game: run.game),
    null => null,
  };

  /// Whether the boards follow the game being played.
  bool get following => _following;

  /// The finished game on the boards, by number, when the user opened one.
  int? get openGame => _openGame;

  /// What the last action could not do.
  MatchProblem? get problem => _problem;

  Future<void> load() async {
    final found = await _store.list();
    if (_disposed) return;
    // A match this app is playing is shown as its run knows it.
    final playing = _run == null ? null : _find(_run!.id);
    _matches = [
      for (final match in found) match.id == playing?.id ? playing! : match,
    ];
    notifyListeners();
  }

  void select(String id) {
    _selected = id;
    _openGame = null;
    notifyListeners();
  }

  /// A new match from [config], seeded now: its folder first, then the
  /// games. A second press while the first is on its way does nothing.
  Future<void> start(MatchConfig config) =>
      pendingWrites?.track(this, _start(config), label: 'Matches') ??
      _start(config);

  Future<void> _start(MatchConfig config) async {
    if (_run != null || _starting) return;
    _starting = true;
    _stopAsked = false;
    _problem = null;
    try {
      final now = _now();
      final seeded = config.withSeed(now.millisecondsSinceEpoch & 0x7fffffff);
      switch (await _store.create(seeded, now)) {
        case MatchCreateFailed(:final detail):
          _fail(CannotCreate(detail));
        case MatchCreated(:final match):
          if (_disposed) return;
          _matches = [match, ..._matches];
          _selected = match.id;
          await _play(match);
      }
    } finally {
      _starting = false;
    }
  }

  /// Goes on with a stopped or failed match from the game it had reached,
  /// as the file on disk has it — the old app may have written it since. A
  /// last game the engine failed in is played again.
  Future<void> resume(String id) =>
      pendingWrites?.track(this, _resume(id), label: 'Matches') ?? _resume(id);

  Future<void> _resume(String id) async {
    if (_run != null || _starting) return;
    _starting = true;
    _stopAsked = false;
    _problem = null;
    try {
      final onDisk = (await _store.list()).where((m) => m.id == id).firstOrNull;
      if (_disposed || onDisk == null || !onDisk.resumable) return;
      final games = [...onDisk.games];
      if (games.lastOrNull?.ending == MatchEnding.engineFailure) {
        games.removeLast();
      }
      _selected = id;
      await _play(onDisk.copyWith(clearError: true, games: games));
    } finally {
      _starting = false;
    }
  }

  /// Stops the match; the game in flight is not kept. Asked while the
  /// engine is still starting, the match stops as soon as it is up.
  void stop() {
    _stopAsked = true;
    final run = _run;
    if (run == null) return;
    run.stopAsked = true;
    run.runner?.stop();
  }

  Future<void> _play(StoredMatch match) async {
    final start = match.config.start;
    if (start == null) return _fail(const NotAPosition());
    final run = _run = _Run(match.id, match.games.length + 1)
      ..stopAsked = _stopAsked;
    var current = match.copyWith(status: MatchStatus.running);
    await _write(current);
    final engine = await _engine();
    if (engine == null) {
      return _finish(
        run,
        current.copyWith(status: MatchStatus.failed, error: _failure),
      );
    }
    if (_disposed || run.stopAsked) {
      unawaited(engine.quit());
      return _finish(run, current.copyWith(status: MatchStatus.cancelled));
    }
    final runner = run.runner = MatchRunner(
      engine: engine,
      config: match.config,
      now: _now,
    );
    for (var i = current.games.length; i < match.config.games; i++) {
      if (_disposed || runner.stopped) break;
      run.game = i + 1;
      notifyListeners();
      final game = await runner.play(i, start, onMove: (m) => _moved(start, m));
      if (game == null) break;
      current = current.copyWith(games: [...current.games, game]);
      await _write(current);
      if (game.ending == MatchEnding.engineFailure) {
        current = current.copyWith(
          status: MatchStatus.failed,
          error: game.detail,
        );
        break;
      }
    }
    unawaited(engine.quit());
    final status = switch (current.status) {
      MatchStatus.failed => MatchStatus.failed,
      _ when runner.stopped || _disposed => MatchStatus.cancelled,
      _ => MatchStatus.completed,
    };
    await _finish(run, current.copyWith(status: status));
  }

  /// Why the engine would not start, for the match's record.
  String? _failure;

  Future<Hivemind?> _engine() async {
    switch (await _startEngine()) {
      case HivemindStarted(:final engine):
        return engine;
      case HivemindStartFailed(:final reason):
        _failure = reason;
        _problem = EngineWouldNotStart(reason);
        return null;
    }
  }

  Future<void> _finish(_Run run, StoredMatch match) async {
    await _write(match.copyWith(finishedAt: _now()));
    if (!identical(_run, run)) return;
    _run = null;
    if (_following) _unfollow();
    if (match.status == MatchStatus.failed) {
      _problem ??= MatchEngineFailed(match.error ?? '');
    }
    if (!_disposed) notifyListeners();
  }

  /// The match kept in the list and written; a write that fails is said,
  /// and the run goes on — the next game writes the whole file again.
  Future<void> _write(StoredMatch match) async {
    _matches = [for (final m in _matches) m.id == match.id ? match : m];
    final write = _store.save(match);
    final problem =
        await (pendingWrites?.track(
              _store,
              write,
              label: 'Match results',
              obligation: (_store, match.id),
              problem: (detail) => detail,
            ) ??
            write);
    if (_disposed) return;
    if (problem != null) _problem = CannotSave(problem);
    notifyListeners();
  }

  void _moved(TablePosition start, List<String> moves) {
    if (_following) lab.showLine(replayGame(start, moves));
  }

  /// The boards follow the game being played, and the tables rest.
  void follow() {
    if (_run == null || _following) return;
    _following = true;
    _openGame = null;
    tables.rest(true);
    notifyListeners();
  }

  void _unfollow() {
    _following = false;
    if (!_disposed) tables.rest(false);
  }

  /// A finished game of the selected match on the boards, at its end.
  void open(MatchGame game) {
    final start = selected?.config.start;
    if (start == null) return;
    if (_following) _unfollow();
    _openGame = game.number;
    lab.showLine(replayGame(start, game.moves));
    notifyListeners();
  }

  /// The selected match's opening on the boards, none of its games on it.
  void showOpening() {
    final start = selected?.config.start;
    if (start == null) return;
    if (_following) _unfollow();
    _openGame = null;
    lab.showLine(replayGame(start, const []));
    notifyListeners();
  }

  Future<void> delete(String id) =>
      pendingWrites?.track(this, _delete(id), label: 'Matches') ?? _delete(id);

  Future<void> _delete(String id) async {
    if (_run?.id == id) return;
    final problem = await _store.delete(id);
    if (_disposed) return;
    if (problem != null) return _fail(CannotDelete(problem));
    _matches = [
      for (final m in _matches)
        if (m.id != id) m,
    ];
    notifyListeners();
  }

  StoredMatch? _find(String id) =>
      _matches.where((m) => m.id == id).firstOrNull;

  void _fail(MatchProblem problem) {
    log.w('bughouse match', problem);
    _problem = problem;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _run?.runner?.stop();
    super.dispose();
  }
}

/// The match being played: which, the game in flight, and its runner once
/// the engine is up.
final class _Run {
  _Run(this.id, this.game);

  final String id;
  int game;
  MatchRunner? runner;

  /// Stop was pressed before the runner existed.
  bool stopAsked = false;
}

/// Why a match could not be made, kept or played.
sealed class MatchProblem {
  const MatchProblem();
}

/// A stored start that does not read as a position.
final class NotAPosition extends MatchProblem {
  const NotAPosition();
}

final class CannotCreate extends MatchProblem {
  const CannotCreate(this.detail);

  final String detail;

  @override
  String toString() => 'create: $detail';
}

final class CannotSave extends MatchProblem {
  const CannotSave(this.detail);

  final String detail;
}

final class CannotDelete extends MatchProblem {
  const CannotDelete(this.detail);

  final String detail;

  @override
  String toString() => 'delete: $detail';
}

final class EngineWouldNotStart extends MatchProblem {
  const EngineWouldNotStart(this.reason);

  final String reason;
}

/// A game ended with the engine failing; the match stopped there.
final class MatchEngineFailed extends MatchProblem {
  const MatchEngineFailed(this.reason);

  final String reason;
}
