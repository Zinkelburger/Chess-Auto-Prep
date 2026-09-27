import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/tournament/config.dart';
import '../../chess/tournament/result.dart';
import '../../engines/engine_supervisor.dart';
import '../../diagnostics/log.dart';
import '../../engines/playing_engine.dart';
import '../../chess/fen.dart';
import '../../storage/pending_writes.dart';
import '../../storage/tournaments.dart';
import 'game_runner.dart';

/// App-lifetime tournament work. A failed checkpoint retains the exact save
/// operation; no more games start until its user-visible retry succeeds.
final class TournamentRun extends ChangeNotifier {
  TournamentRun({
    required this.store,
    required this.launch,
    required this.pending,
    required this.activityChanged,
  });
  final TournamentStore store;
  final TournamentLauncher launch;
  final PendingWrites pending;
  final void Function(bool running) activityChanged;
  List<Tournament> history = const [];
  List<TournamentEngine> engines = const [];
  Tournament? selected;
  Tournament? _active;
  LiveGame? live;
  String? problem;
  String? engineReport;
  bool running = false;
  bool stopping = false;
  bool registryBusy = false;
  bool _disposed = false;
  int _reading = 0;
  String? _pgn;
  String? _retryPgn;
  bool _retryStarts = false;
  PendingObligation<TournamentResult<Tournament>>? _save;
  Future<void> _saving = Future.value();
  final _completed = <int, PlayedGame>{};
  bool get canRetry => _save != null;
  String? get activeId => _active?.id;

  Future<void> refresh() async {
    final ticket = ++_reading;
    final listed = await store.list();
    final registry = await store.engines();
    if (_disposed || ticket != _reading) return;
    switch (listed) {
      case TournamentSaved(:final value):
        history = value;
        if (!running)
          selected =
              value.where((t) => t.id == selected?.id).firstOrNull ??
              value.firstOrNull;
      case TournamentFailed(:final message):
        problem = message;
    }
    switch (registry) {
      case TournamentSaved(:final value):
        if (!registryBusy) engines = value;
      case TournamentFailed(:final message):
        engineReport = message;
    }
    _notify();
  }

  void select(Tournament value) {
    selected = value;
    _notify();
  }

  Future<void> start(TournamentConfig config) async {
    if (running || canRetry || _disposed) return;
    if (config.problem case final message?) {
      problem = message;
      _notify();
      return;
    }
    _reading++;
    stopping = false;
    final now = DateTime.now().toUtc();
    final initial = Tournament({
      'version': 1,
      'id': 'match-${now.microsecondsSinceEpoch}',
      'createdAt': now.toIso8601String(),
      'status': 'pending',
      'config': config.json,
      'games': <Object>[],
    });
    _active = initial;
    selected = initial;
    _pgn = null;
    _retryPgn = null;
    problem = null;
    _saving = Future.value();
    _retryStarts = true;
    _save = pending.accept<TournamentResult<Tournament>>(
      resource: this,
      label: 'Create tournament',
      work: () => store.create(initial),
      problem: _failed,
    );
    if (!await _commit()) return;
    _retryStarts = false;
    await _play(config);
  }

  Future<void> _play(TournamentConfig config) async {
    if (_disposed) return;
    running = true;
    _completed.clear();
    activityChanged(true);
    _notify();
    final work = _schedule(config);
    pending.watch(this, work);
    await work;
  }

  Future<void> _schedule(TournamentConfig config) async {
    final schedule = config.schedule;
    var next = 0;
    Future<void> worker() async {
      while (!stopping && next < schedule.length) {
        final pair = schedule[next++];
        final game = await TournamentGameRunner(
          config: config,
          pairing: pair,
          launch: launch,
          stopping: () => stopping,
          onPosition: (value) {
            live = value;
            _notify();
          },
        ).play();
        _completed[pair.index] = game;
        _saving = _saving.then((_) => _checkpoint());
        await _saving;
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < config.concurrency; i++) worker(),
      ]);
      if (!canRetry) {
        final after = _active!.changed({
          'status': stopping ? 'stopped' : 'completed',
          'finishedAt': DateTime.now().toUtc().toIso8601String(),
        });
        await _persist(after, _pgn ?? '');
      }
    } on Object catch (error) {
      stopping = true;
      problem = 'Tournament failed: $error';
      log.e('run tournament', error);
    } finally {
      running = false;
      live = null;
      activityChanged(false);
      _notify();
    }
  }

  Future<void> _checkpoint() async {
    if (canRetry) return;
    final keys = _completed.keys.toList()..sort();
    final records = <Map<String, Object?>>[];
    final texts = <String>[];
    for (final key in keys) {
      final game = _completed[key]!;
      records.add({...game.record.json, 'gameIndex': records.length});
      texts.add(game.pgn);
    }
    final after = _active!.changed({'status': 'running', 'games': records});
    if (!await _persist(after, texts.join('\n'))) stopping = true;
  }

  Future<bool> _persist(Tournament after, String pgn) {
    final before = _active!;
    final expected = _pgn;
    _retryPgn = pgn;
    _save = pending.accept<TournamentResult<Tournament>>(
      resource: this,
      label: 'Save tournament',
      work: () => store.save(before, after, pgn, expectedPgn: expected),
      problem: _failed,
    );
    return _commit();
  }

  Future<bool> _commit() async {
    final save = _save;
    if (save == null) return false;
    final result = await save.run();
    if (result case TournamentSaved(:final value)) {
      _active = value;
      if (selected == null || selected!.id == value.id) selected = value;
      history = [value, ...history.where((t) => t.id != value.id)];
      _pgn = _retryPgn;
      _save = null;
      problem = null;
      _notify();
      return true;
    }
    problem = (result as TournamentFailed).message;
    _notify();
    return false;
  }

  Future<void> retrySave() async {
    if (running || !canRetry || _disposed) return;
    if (!await _commit()) return;
    if (_retryStarts) {
      _retryStarts = false;
      await _play(_active!.config);
    } else {
      // Games already in flight when a checkpoint failed are still retained
      // in memory. Commit their results before marking this stopped run done.
      await _checkpoint();
      if (!canRetry)
        await _persist(
          _active!.changed({
            'status': 'stopped',
            'finishedAt': DateTime.now().toUtc().toIso8601String(),
          }),
          _pgn ?? '',
        );
    }
  }

  void stop() {
    if (!running && !canRetry) return;
    stopping = true;
    _notify();
  }

  Future<void> remove(Tournament value) async {
    if (running && value.id == _active?.id ||
        canRetry && value.id == _active?.id)
      return;
    final result = await pending.track(
      this,
      store.remove(value),
      label: 'Remove tournament',
      obligation: ('remove', value.id),
      problem: _failed,
    );
    if (_disposed) return;
    switch (result) {
      case TournamentSaved():
        await refresh();
      case TournamentFailed(:final message):
        problem = message;
    }
    _notify();
  }

  Future<bool> verify(TournamentEngine spec) async {
    if (registryBusy || running) return false;
    if (spec.options.entries.any(
      (e) => '${e.key}${e.value}'.contains(RegExp(r'[\r\n]')),
    )) {
      engineReport = 'Engine options must be single lines.';
      _notify();
      return false;
    }
    registryBusy = true;
    engineReport = 'Testing ${spec.name}…';
    _notify();
    bool valid = false;
    try {
      final started = await launch(spec);
      if (started case StartFailed(:final reason)) {
        engineReport = reason;
        return false;
      }
      final engine = (started as Started).engine;
      try {
        if (engine is! PlayingEngine) {
          engineReport = 'The engine cannot play moves.';
          return false;
        }
        final search = engine.play(
          Fen.initial,
          const [],
          const MoveBudget(depth: 1, deadline: Duration(seconds: 20)),
        );
        final answers = await Future.wait<Object?>([
          search.bestMove,
          search.analysis.lines.drain<void>(),
        ]);
        valid = legalOpeningMove(answers.first as String?);
        engineReport = valid
            ? '${engine.name}: UCI ready; legal move verified.'
            : 'The engine returned no legal opening move.';
      } finally {
        await engine.quit();
      }
    } on Object catch (error) {
      log.w('verify tournament engine', error);
      engineReport = 'Engine test failed: $error';
    } finally {
      registryBusy = false;
      _notify();
    }
    return valid;
  }

  Future<void> keepEngines(List<TournamentEngine> values) async {
    if (registryBusy || running) return;
    registryBusy = true;
    _notify();
    final result = await pending.track(
      this,
      store.saveEngines(engines, values),
      label: 'Engine registry',
      obligation: store,
      problem: _failed,
    );
    if (!_disposed) {
      if (result is TournamentSaved<void>) {
        engines = List.unmodifiable(values);
        engineReport = 'Engine settings saved.';
      }
      if (result case TournamentFailed(:final message)) engineReport = message;
      registryBusy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    stopping = true;
    _disposed = true;
    _reading++;
    super.dispose();
  }
}

String? _failed<T>(TournamentResult<T> result) => switch (result) {
  TournamentFailed(:final message) => message,
  TournamentSaved() => null,
};
