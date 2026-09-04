/// Owns the bughouse matches: the saved ones, the one running, and which game
/// is on the boards.
///
/// It borrows the engine rather than owning one — see
/// [BughouseController.tournaments] — and it borrows the boards too: a game
/// being played, or a finished game clicked in the list, is handed back
/// through [showLine] and shown on the lab's own two boards. That is the whole
/// reason the feature lives inside the lab instead of on a screen of its own:
/// there is already a two-board viewer here, with reserves, seats and a
/// per-board movetext, and a match is a stack of games for it to show.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/app_paths.dart';
import '../../../utils/log.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/bughouse_history.dart';
import '../models/bughouse_tournament.dart';
import '../services/bughouse_engine.dart';
import '../services/bughouse_tournament_runner.dart';
import '../services/bughouse_tournament_store.dart';

class BughouseTournamentController extends ChangeNotifier
    with SafeChangeNotifier {
  BughouseTournamentController({
    required this.acquireEngine,
    required this.showLine,
    this.onIdle,
    BughouseTournamentStore? store,
  }) : _store = store {
    unawaited(_load());
  }

  /// Hands back the lab's engine, starting it if it is not up yet.
  final Future<BughouseAnalysisEngine> Function() acquireEngine;

  /// Puts a line on the lab's boards.
  final void Function(BughouseHistory line) showLine;

  /// Called once a match is over and the engine has nothing left to do, so
  /// whoever lent it out can take it back.
  final void Function()? onIdle;

  BughouseTournamentStore? _store;

  /// `Documents/bughouse_matches`, resolved on first use.
  Future<BughouseTournamentStore> _resolveStore() async {
    final existing = _store;
    if (existing != null) return existing;
    final documents = await AppPaths.documentsDirectory();
    return _store = BughouseTournamentStore(
      Directory(p.join(documents.path, kBughouseMatchesDirectoryName)),
    );
  }

  // ------------------------------------------------------------------- state

  List<StoredBughouseTournament> _matches = const [];

  /// Every saved match, newest first.
  List<StoredBughouseTournament> get matches => _matches;

  String? _selectedId;

  /// The match on screen, or null when none has been chosen yet.
  StoredBughouseTournament? get selected {
    final id = _selectedId;
    if (id == null) return _matches.isEmpty ? null : _matches.first;
    for (final match in _matches) {
      if (match.id == id) return match;
    }
    return _matches.isEmpty ? null : _matches.first;
  }

  BughouseTournamentRunner? _runner;
  String? _runningId;

  bool get isRunning => _runner != null;

  /// Which game of the running match is in progress, 1-based; 0 when idle.
  int _liveGameNumber = 0;
  int get liveGameNumber => _liveGameNumber;

  /// The game whose line is on the boards, 1-based; null when the boards are
  /// showing something else.
  int? _openGameNumber;
  int? get openGameNumber => _openGameNumber;

  String? _error;
  String? get error => _error;

  bool _loading = true;
  bool get isLoading => _loading;

  Future<void> _load() async {
    try {
      final store = await _resolveStore();
      final found = await store.list();
      if (isDisposed) return;
      _matches = found;
    } catch (e) {
      log.w('Could not read the bughouse matches: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void select(String id) {
    if (_selectedId == id) return;
    _selectedId = id;
    _openGameNumber = null;
    _error = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ running

  /// Starts a match. Returns as soon as the directory exists; the games arrive
  /// through [notifyListeners] as they finish.
  Future<void> start(BughouseTournamentConfig config) async {
    if (isRunning) return;
    _error = null;
    StoredBughouseTournament match;
    try {
      final store = await _resolveStore();
      match = await store.create(config);
    } catch (e) {
      _error = 'Could not create the match directory: $e';
      notifyListeners();
      return;
    }
    _matches = [match, ..._matches];
    _selectedId = match.id;
    _runningId = match.id;
    _openGameNumber = null;
    _liveGameNumber = 1;
    _replace(match.copyWith(status: BughouseTournamentStatus.running));
    notifyListeners();

    unawaited(_run(match.id, config));
  }

  Future<void> _run(String id, BughouseTournamentConfig config) async {
    final games = <BughouseGameRecord>[];
    var status = BughouseTournamentStatus.completed;
    String? failure;
    try {
      final engine = await acquireEngine();
      final runner = BughouseTournamentRunner(
        engine: engine,
        config: config,
        onGameFinished: (game) {
          games.add(game);
          _liveGameNumber = games.length + 1;
          final match = _find(id);
          if (match == null) return;
          _replace(match.copyWith(games: List.of(games)));
          unawaited(_persist(id));
          notifyListeners();
        },
        onPosition: (line) {
          // While a match runs the boards follow it — unless the user has
          // clicked a finished game, in which case they are reading and should
          // not have the board pulled out from under them.
          if (_openGameNumber != null) return;
          showLine(line);
        },
      );
      _runner = runner;
      notifyListeners();
      await runner.run();
      if (runner.isStopped) status = BughouseTournamentStatus.cancelled;
    } catch (e) {
      status = BughouseTournamentStatus.failed;
      failure = e is BughouseEngineFailure ? e.message : '$e';
      log.w('Bughouse match failed: $failure');
    } finally {
      _runner = null;
      _runningId = null;
      _liveGameNumber = 0;
      final match = _find(id);
      if (match != null) {
        _replace(
          match.copyWith(
            games: List.of(games),
            status: status,
            finishedAt: DateTime.now(),
            error: failure,
          ),
        );
        await _persist(id);
      }
      _error = failure;
      notifyListeners();
      onIdle?.call();
    }
  }

  /// Stops the match after the game in flight.
  void stop() {
    final runner = _runner;
    if (runner == null) return;
    runner.stop();
    notifyListeners();
  }

  // ------------------------------------------------------------------- games

  /// Puts one game of the selected match on the boards.
  void openGame(BughouseGameRecord game) {
    final match = selected;
    final start = match?.config.startState;
    if (start == null) return;
    _openGameNumber = game.number;
    showLine(replayBughouseGame(start, game.moves));
    notifyListeners();
  }

  /// Lets the boards follow the running match again.
  void followLiveGame() {
    if (_openGameNumber == null) return;
    _openGameNumber = null;
    notifyListeners();
  }

  /// Puts the match's starting position back on the boards — the opening you
  /// asked about, with none of the games on top of it.
  void showOpening() {
    final start = selected?.config.startState;
    if (start == null) return;
    _openGameNumber = null;
    showLine(BughouseHistory(start));
    notifyListeners();
  }

  Future<void> delete(String id) async {
    if (_runningId == id) stop();
    try {
      final store = await _resolveStore();
      await store.delete(id);
    } catch (e) {
      _error = 'Could not delete the match: $e';
    }
    _matches = [
      for (final match in _matches)
        if (match.id != id) match,
    ];
    if (_selectedId == id) _selectedId = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- internals

  StoredBughouseTournament? _find(String id) {
    for (final match in _matches) {
      if (match.id == id) return match;
    }
    return null;
  }

  void _replace(StoredBughouseTournament match) {
    _matches = [
      for (final existing in _matches)
        if (existing.id == match.id) match else existing,
    ];
  }

  /// Writes the match out. Every game as it finishes, so a crash, a quit or a
  /// power cut keeps what was already played — the same promise the engine
  /// tournament makes.
  Future<void> _persist(String id) async {
    final match = _find(id);
    if (match == null) return;
    try {
      final store = await _resolveStore();
      await store.save(match);
    } catch (e) {
      log.w('Could not save the bughouse match: $e');
    }
  }

  @override
  void dispose() {
    _runner?.stop();
    _runner = null;
    super.dispose();
  }
}
