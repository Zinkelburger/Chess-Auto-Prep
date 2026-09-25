import 'dart:async';
import 'dart:convert';

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
    PendingWrites? pendingWrites,
    required Future<HivemindStart> Function() startEngine,
    required this.lab,
    required this.tables,
    DateTime Function() now = DateTime.now,
  }) : pendingWrites = pendingWrites ?? PendingWrites(),
       _store = store,
       _startEngine = startEngine,
       _now = now;

  final PendingWrites pendingWrites;
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
  PendingObligation<MatchWriteProblem>? _checkpoint;
  PendingObligation<String?>? _exit;
  StoredMatch? _accepted;

  bool get canRetry =>
      (_checkpoint != null && !_checkpoint!.committed) ||
      (_exit != null && !_exit!.committed);
  bool get writable => !canRetry && pendingWrites.unfinished(_store).isEmpty;

  /// Save the same checkpoint, then leave resuming play to an explicit action.
  Future<void> retrySave() async {
    final exit = _exit;
    if (exit != null) {
      final detail = await exit.run();
      if (_disposed) return;
      if (detail != null) return _fail(MatchEngineFailed(detail));
      _exit = null;
    }
    final checkpoint = _checkpoint;
    final accepted = _accepted;
    if (checkpoint == null || accepted == null) {
      _problem = null;
      if (!_disposed) notifyListeners();
      return;
    }
    final detail = await checkpoint.run();
    if (_disposed) return;
    if (detail != null) return _fail(CannotSave(detail));
    _problem = null;
    _checkpoint = null;
    _accepted = null;
    _show(
      accepted.status == MatchStatus.running
          ? accepted.copyWith(status: MatchStatus.cancelled)
          : accepted,
    );
  }

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
    List<StoredMatch> found;
    try {
      found = await _store.list();
    } on Object catch (error) {
      return _fail(CannotLoad('$error'));
    }
    if (_disposed) return;
    if (_problem is CannotLoad) _problem = null;
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
      pendingWrites.track(this, _start(config), label: 'Matches');

  Future<void> _start(MatchConfig config) async {
    if (_disposed || _run != null || _starting || !writable) return;
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
    } on Object catch (error) {
      _fail(CannotCreate('$error'));
    } finally {
      _starting = false;
    }
  }

  /// Goes on with a stopped or failed match from the game it had reached,
  /// as the file on disk has it — the old app may have written it since. A
  /// last game the engine failed in is played again.
  Future<void> resume(String id) =>
      pendingWrites.track(this, _resume(id), label: 'Matches');

  Future<void> _resume(String id) async {
    if (_disposed || _run != null || _starting || !writable) return;
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
    } on Object catch (error) {
      _fail(CannotLoad('$error'));
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
    final current = match.copyWith(status: MatchStatus.running);
    Hivemind? engine;
    StoredMatch? finished;
    try {
      if (!await _write(current)) return;
      if (_disposed || run.stopAsked) {
        finished = current.copyWith(status: MatchStatus.cancelled);
        return;
      }
      engine = await _engine();
      if (engine == null) {
        finished = current.copyWith(
          status: MatchStatus.failed,
          error: _failure,
        );
      } else if (_disposed || run.stopAsked) {
        finished = current.copyWith(status: MatchStatus.cancelled);
      } else {
        finished = await _games(run, current, start, engine);
      }
    } on Object catch (error) {
      log.e('run bughouse match ${match.id}', error);
      _fail(MatchEngineFailed('$error'));
      finished = (_find(match.id) ?? current).copyWith(
        status: MatchStatus.failed,
        error: '$error',
      );
    } finally {
      // The run owns every engine returned by startup, even when an unexpected
      // factory/search failure interrupts normal result handling.
      try {
        if (engine != null) await _quit(engine);
        if (finished != null) await _finish(run, finished);
      } finally {
        _stopped(run);
      }
    }
  }

  Future<StoredMatch?> _games(
    _Run run,
    StoredMatch current,
    TablePosition start,
    Hivemind engine,
  ) async {
    final runner = run.runner = MatchRunner(
      engine: engine,
      config: current.config,
      now: _now,
    );
    for (var i = current.games.length; i < current.config.games; i++) {
      if (_disposed || runner.stopped) break;
      run.game = i + 1;
      notifyListeners();
      final game = await runner.play(i, start, onMove: (m) => _moved(start, m));
      if (game == null) break;
      current = current.copyWith(games: [...current.games, game]);
      if (!await _write(current)) return null;
      if (game.ending == MatchEnding.engineFailure) {
        return current.copyWith(status: MatchStatus.failed, error: game.detail);
      }
    }
    return current.copyWith(
      status: runner.stopped || _disposed
          ? MatchStatus.cancelled
          : MatchStatus.completed,
    );
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
    if (match.status == MatchStatus.failed) {
      _problem ??= MatchEngineFailed(match.error ?? '');
    }
  }

  Future<void> _quit(Hivemind engine) async {
    final exit = _exit = pendingWrites.accept<String?>(
      resource: _store,
      label: 'Match engine exit',
      work: () async {
        try {
          await engine.quit();
          return null;
        } on Object catch (error) {
          log.w('quit bughouse match engine', error);
          return 'Could not confirm engine exit: $error';
        }
      },
      problem: (detail) => detail,
    );
    final detail = await exit.run();
    if (detail == null) _exit = null;
  }

  void _stopped(_Run run) {
    if (!identical(_run, run)) return;
    _run = null;
    if (_following) _unfollow();
    final current = _find(run.id);
    if (current?.status == MatchStatus.running) {
      _show(current!.copyWith(status: MatchStatus.cancelled));
    } else if (!_disposed) {
      notifyListeners();
    }
  }

  void _show(StoredMatch match) {
    _matches = [for (final m in _matches) m.id == match.id ? match : m];
    if (!_disposed) notifyListeners();
  }

  /// Admission freezes the whole checkpoint. The app registry owns its retry
  /// even after this screen disappears; no later game can pass a failed write.
  Future<bool> _write(StoredMatch match) async {
    final encoded = jsonEncode(match.toJson());
    final store = _store;
    final token = MatchCheckpoint();
    final exit = _exit;
    final checkpoint = pendingWrites.accept<MatchWriteProblem>(
      resource: store,
      label: 'Match results',
      work: () async {
        final captured = StoredMatch.fromJson(
          jsonDecode(encoded) as Map<String, Object?>,
        ).copyWith(status: match.status);
        try {
          return await store.save(captured, checkpoint: token);
        } on Object catch (error) {
          log.e('save bughouse match ${captured.id}', error);
          return '$error';
        }
      },
      problem: (detail) => detail,
      blocked: () => exit?.detail ?? 'Save the earlier match checkpoint first.',
    );
    _checkpoint = checkpoint;
    _accepted = StoredMatch.fromJson(
      jsonDecode(encoded) as Map<String, Object?>,
    ).copyWith(status: match.status);
    final detail = await checkpoint.run();
    if (detail != null) {
      _fail(CannotSave(detail));
      return false;
    }
    _checkpoint = null;
    _accepted = null;
    _show(match);
    return true;
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
      pendingWrites.track(this, _delete(id), label: 'Matches');

  Future<void> _delete(String id) async {
    if (_disposed || _run?.id == id || !writable) return;
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

  @override
  String toString() => 'save: $detail';
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

final class CannotLoad extends MatchProblem {
  const CannotLoad(this.detail);
  final String detail;
}
