import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/bughouse/match.dart';
import '../../chess/bughouse/table.dart';
import '../../diagnostics/log.dart';
import '../../engines/hivemind_engine.dart';
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
    required Future<HivemindStart> Function() startEngine,
    required this.lab,
    required this.tables,
    DateTime Function() now = DateTime.now,
  }) : _store = store,
       _startEngine = startEngine,
       _now = now;

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
  String? _problem;
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
  String? get problem => _problem;

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
  /// games.
  Future<void> start(MatchConfig config) async {
    if (_run != null) return;
    _problem = null;
    final now = _now();
    final seeded = config.withSeed(now.millisecondsSinceEpoch & 0x7fffffff);
    switch (await _store.create(seeded, now)) {
      case MatchCreateFailed(:final detail):
        _say('Could not create the match directory: $detail');
      case MatchCreated(:final match):
        if (_disposed) return;
        _matches = [match, ..._matches];
        _selected = match.id;
        await _play(match);
    }
  }

  /// Goes on with a stopped or failed match from the game it had reached.
  Future<void> resume(String id) async {
    final match = _find(id);
    if (_run != null || match == null || !match.resumable) return;
    _problem = null;
    _selected = id;
    await _play(match.copyWith(clearError: true));
  }

  /// Stops the match; the game in flight is not kept.
  void stop() => _run?.runner?.stop();

  Future<void> _play(StoredMatch match) async {
    final start = match.config.start;
    if (start == null) {
      return _say('That is not a position yet — check the moves or the FEN.');
    }
    final run = _run = _Run(match.id, match.games.length + 1);
    var current = match.copyWith(status: MatchStatus.running);
    await _write(current);
    final engine = await _engine();
    if (engine == null || _disposed) {
      return _finish(
        run,
        current.copyWith(status: MatchStatus.failed, error: _problem),
      );
    }
    final runner = run.runner = MatchRunner(
      engine: engine,
      config: match.config,
      now: _now,
    );
    for (
      var index = current.games.length;
      index < match.config.games;
      index++
    ) {
      run.game = index + 1;
      notifyListeners();
      final game = await runner.play(
        index,
        start,
        onMove: (moves) => _moved(start, moves),
      );
      if (game == null || _disposed) break;
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
      _ when runner.stopped => MatchStatus.cancelled,
      _ => MatchStatus.completed,
    };
    await _finish(run, current.copyWith(status: status));
  }

  Future<Hivemind?> _engine() async {
    switch (await _startEngine()) {
      case HivemindStarted(:final engine):
        return engine;
      case HivemindStartFailed(:final reason):
        _problem = reason;
        return null;
    }
  }

  Future<void> _finish(_Run run, StoredMatch match) async {
    await _write(match.copyWith(finishedAt: _now()));
    if (!identical(_run, run)) return;
    _run = null;
    if (_following) _unfollow();
    if (match.status == MatchStatus.failed) _problem ??= match.error;
    if (!_disposed) notifyListeners();
  }

  /// The match kept in the list and written; a write that fails is said,
  /// and the run goes on — the next game writes the whole file again.
  Future<void> _write(StoredMatch match) async {
    _matches = [for (final m in _matches) m.id == match.id ? match : m];
    final problem = await _store.save(match);
    if (_disposed) return;
    if (problem != null) _problem = 'Could not save the match: $problem';
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

  Future<void> delete(String id) async {
    if (_run?.id == id) return;
    final problem = await _store.delete(id);
    if (_disposed) return;
    if (problem != null) return _say('Could not delete the match: $problem');
    _matches = [
      for (final m in _matches)
        if (m.id != id) m,
    ];
    notifyListeners();
  }

  StoredMatch? _find(String id) =>
      _matches.where((m) => m.id == id).firstOrNull;

  void _say(String problem) {
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
}
