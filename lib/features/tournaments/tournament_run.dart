import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/tournament/config.dart';
import '../../chess/tournament/result.dart';
import '../../diagnostics/log.dart';
import '../../storage/pending_writes.dart';
import '../../storage/tournaments.dart';
import '../../storage/tournament_inbox.dart';
import '../../workspace/engine_jobs.dart';
import 'engine_check.dart';
import 'game_runner.dart';
import 'schedule.dart';

/// App-lifetime tournament work. A failed checkpoint retains the exact save
/// operation; no more games start until its user-visible retry succeeds.
final class TournamentRun extends ChangeNotifier {
  TournamentRun({
    required this.store,
    required this.launch,
    required this.pending,
    required EngineJobs jobs,
    this.onOpenRequest,
    this.pickExecutable = _noFile,
  }) : _jobs = jobs;

  /// The file dialog that picks an engine binary to register.
  final Future<String?> Function() pickExecutable;
  final void Function()? onOpenRequest;
  final TournamentStore store;
  final TournamentLauncher launch;
  final PendingWrites pending;

  /// The machine's one heavy engine job: a tournament takes it before its
  /// first engine starts and does not start while a search, an audit or a
  /// review holds it, since each would get half the machine.
  final EngineJobs _jobs;
  List<Tournament> history = const [];
  List<TournamentEngine> engines = const [];
  Tournament? selected;
  Tournament? _active;
  LiveGame? live;
  String? problem;
  List<String> historyWarnings = const [];
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
  TournamentSchedule? _games;
  bool get canRetry => _save != null;
  String? get activeId => _active?.id;

  StreamSubscription<void>? _watch;
  Timer? _reload;
  Future<void>? _refreshing;
  bool _again = false;

  /// Start once at app launch, even if another mode is on screen.
  Future<void> listen() async {
    if (_disposed || _watch != null) return;
    if (store case TournamentNotifications signals) {
      _watch = signals.changes().listen(
        (_) {
          _reload?.cancel();
          _reload = Timer(
            const Duration(milliseconds: 600),
            () => unawaited(refresh()),
          );
        },
        onError: (Object error) {
          log.w('watch tournaments', error);
          problem = 'Tournament updates are unavailable. Use Refresh.';
          _notify();
        },
      );
    }
    await refresh();
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    _again = true;
    return _refreshing ??= _refreshLoop().whenComplete(
      () => _refreshing = null,
    );
  }

  Future<void> _refreshLoop() async {
    while (_again && !_disposed) {
      _again = false;
      await _readHistory();
    }
  }

  Future<void> _readHistory() async {
    final ticket = ++_reading;
    final listed = await store.list();
    final registry = await store.engines();
    if (_disposed || ticket != _reading) return;
    switch (listed) {
      case TournamentSaved(:final value, :final warnings):
        historyWarnings = warnings;
        history = value;
        if (!running && !canRetry)
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
    if (store case TournamentNotifications signals) {
      try {
        final id = await signals.takeRequest();
        if (_disposed || ticket != _reading || id == null) {
          _notify();
          return;
        }
        final found = history.where((t) => t.id == id).firstOrNull;
        if (found == null) {
          problem =
              'No tournament called "$id" under Documents/engine_tournaments.';
        } else {
          selected = found;
        }
        onOpenRequest?.call();
      } on Object catch (error) {
        log.w('open tournament request', error);
        problem =
            'The tournament request could not be read. Use Refresh to retry.';
      }
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
    if (!_takeEngines()) return;
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
    _games = null;
    problem = null;
    _retryStarts = true;
    _save = pending.accept<TournamentResult<Tournament>>(
      resource: this,
      label: 'Create tournament',
      work: () => store.create(initial),
      problem: _failed,
    );
    if (!await _commit()) return _jobs.release(this);
    _retryStarts = false;
    await _play(config);
  }

  /// Takes the machine for this run, or says why it cannot start yet.
  bool _takeEngines() {
    if (_jobs.take(this, 'Engine tournament', kind: EngineJobKind.tournament))
      return true;
    problem = _jobs.blockingMessage;
    _notify();
    return false;
  }

  Future<void> _play(TournamentConfig config) async {
    if (_disposed) return _jobs.release(this);
    running = true;
    final games = _games = TournamentSchedule(config, launch);
    _notify();
    final work = _schedule(games);
    pending.watch(this, work);
    await work;
  }

  Future<void> _schedule(TournamentSchedule games) async {
    try {
      await games.play(
        stopping: () => stopping,
        afterGame: (_, _) => _checkpoint(),
        onPosition: (value) {
          live = value;
          _notify();
        },
      );
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
      _jobs.release(this);
      _notify();
    }
  }

  Future<void> _checkpoint() async {
    final games = _games;
    if (canRetry || games == null) return;
    final (:records, :pgn) = games.finished;
    final after = _active!.changed({'status': 'running', 'games': records});
    if (!await _persist(after, pgn)) stopping = true;
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
    final starts = _retryStarts;
    if (starts && !_takeEngines()) return;
    if (!await _commit()) {
      if (starts) _jobs.release(this);
      return;
    }
    if (_retryStarts) {
      _retryStarts = false;
      await _play(_active!.config);
    } else if (!{'completed', 'stopped'}.contains(_active!.status)) {
      // A replayed final save leaves nothing to do. Otherwise games already in
      // flight when a checkpoint failed are still retained in memory: commit
      // them, then close the run as completed only if every game was played.
      await _checkpoint();
      final games = _games;
      if (!canRetry && games != null)
        await _persist(
          _active!.changed({
            'status':
                games.finished.records.length == games.config.schedule.length
                ? 'completed'
                : 'stopped',
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

  /// Tests [spec] before it may be registered; see [checkTournamentEngine].
  Future<EngineCheck> verify(TournamentEngine spec) async {
    if (registryBusy || running) {
      return const EngineRejected('Wait for the tournament to finish.', []);
    }
    registryBusy = true;
    engineReport = 'Testing ${spec.name}…';
    _notify();
    EngineCheck check;
    try {
      check = await checkTournamentEngine(launch, spec);
    } on Object catch (error) {
      log.w('verify tournament engine', error);
      check = EngineRejected('Engine test failed: $error', const []);
    }
    registryBusy = false;
    engineReport = switch (check) {
      EngineVerified(:final name) => '$name: UCI ready; legal move verified.',
      EngineRejected(:final reason) => reason,
    };
    _notify();
    return check;
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
    _jobs.release(this);
    _reading++;
    _reload?.cancel();
    unawaited(_watch?.cancel());
    super.dispose();
  }
}

Future<String?> _noFile() async => null;

String? _failed<T>(TournamentResult<T> result) => switch (result) {
  TournamentFailed(:final message) => message,
  TournamentSaved() => null,
};
