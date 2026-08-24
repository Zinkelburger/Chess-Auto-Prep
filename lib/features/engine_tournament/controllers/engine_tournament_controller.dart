/// State owner for the Engine Tournament screen.
///
/// Holds the list of saved tournaments, the one being looked at, the engine
/// registry, and — while a match is running — the live board and the game in
/// progress. The heavy lifting all lives in `services/`; this is the layer
/// that turns it into something a widget can listen to.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../services/engine/stockfish_bundle.dart';
import '../../../services/storage/app_paths.dart';
import '../../../utils/log.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/crosstable.dart';
import '../models/engine_spec.dart';
import '../models/stored_tournament.dart';
import '../models/tournament_config.dart';
import '../services/crosstable_builder.dart';
import '../services/engine_game_runner.dart';
import '../services/engine_registry.dart';
import '../services/engine_tournament_runner.dart';
import '../services/engine_verification.dart';
import '../services/tournament_store.dart';

class EngineTournamentController extends ChangeNotifier
    with SafeChangeNotifier {
  TournamentStore? _store;
  EngineRegistry? _registry;

  /// Watches the tournaments directory so a run started elsewhere — an
  /// agent's `tournament_run`, a second window — fills in on screen instead
  /// of waiting for someone to press Refresh.
  StreamSubscription<FileSystemEvent>? _directoryWatch;
  Timer? _refreshDebounce;

  bool _loading = true;
  bool get isLoading => _loading;

  String? _error;
  String? get error => _error;

  List<StoredTournament> _tournaments = const [];
  List<StoredTournament> get tournaments => _tournaments;

  StoredTournament? _selected;
  StoredTournament? get selected => _selected;

  Crosstable? _crosstable;
  Crosstable? get crosstable => _crosstable;

  List<EngineSpec> _engines = const [EngineSpec.bundledStockfish];
  List<EngineSpec> get engines => _engines;

  // ── Live run ─────────────────────────────────────────────────────────────

  EngineTournamentRunner? _runner;
  bool get isRunning => _runner != null;

  /// Id of the tournament currently being played, if any.
  String? _runningId;
  String? get runningId => _runningId;

  String _liveStatus = '';
  String get liveStatus => _liveStatus;

  String? _liveFen;

  /// Board position of the game in progress, or null when nothing is running.
  String? get liveFen => _liveFen;

  String _liveMoveLabel = '';
  String get liveMoveLabel => _liveMoveLabel;

  /// Schedule indices of the games currently being played. With the default
  /// concurrency of one there is at most one.
  final Set<int> _inFlight = <int>{};

  /// The one game the live board mirrors. Several games in flight would
  /// otherwise fight over a single board and show a position from none of
  /// them, so the oldest-started game wins and the rest run quietly.
  int? _liveSlot;

  /// How many other games are running alongside the one on the board.
  int get liveBackgroundGames => _inFlight.isEmpty ? 0 : _inFlight.length - 1;

  /// Whether [tournament] is the one being played right now.
  bool isRunningTournament(String id) => _runningId == id;

  // ── Setup ────────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_store != null) {
      await refresh();
      return;
    }
    try {
      final root = await AppPaths.engineTournamentsDirectory(create: true);
      _store = TournamentStore(root);
      _registry = EngineRegistry(File(p.join(root.path, 'engines.json')));
      await refresh();
      _watchDirectory(root);
    } catch (e, st) {
      log.e('Engine tournament init failed', error: e, stackTrace: st);
      _error = '$e';
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    final store = _store;
    final registry = _registry;
    if (store == null || registry == null) return;
    _loading = true;
    notifyListeners();
    try {
      _tournaments = await store.list();
      _engines = await registry.loadAll();
      final selectedId = _selected?.id;
      final match = selectedId == null
          ? null
          : _tournaments.where((t) => t.id == selectedId).firstOrNull;
      _applySelection(match ?? _tournaments.firstOrNull);
      _error = null;
    } catch (e, st) {
      log.e('Engine tournament refresh failed', error: e, stackTrace: st);
      _error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Never throws: a directory that cannot be watched (inotify limits, a
  /// network mount) just means Refresh is the only way to see outside work.
  void _watchDirectory(Directory root) {
    try {
      _directoryWatch = root
          .watch(events: FileSystemEvent.all, recursive: true)
          .listen(
            (_) => _scheduleRefresh(),
            onError: (Object _) => unawaited(_directoryWatch?.cancel()),
            cancelOnError: true,
          );
    } catch (_) {
      _directoryWatch = null;
    }
  }

  /// A finishing game rewrites two files, once per game. Coalesce, or the
  /// screen re-reads the whole directory several times a second for nothing.
  void _scheduleRefresh() {
    // While this screen owns the run it already gets per-game updates, and a
    // reload would fight them.
    if (_runner != null || isDisposed) return;
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(refresh()),
    );
  }

  void select(StoredTournament tournament) {
    _applySelection(tournament);
    notifyListeners();
  }

  /// Select the tournament with this id if it is already loaded.
  ///
  /// Returns false when it is not, which is the caller's cue to re-read the
  /// directory — a tournament an agent created a moment ago may not be in
  /// the list yet.
  bool selectById(String id) {
    final match = _tournaments.where((t) => t.id == id).firstOrNull;
    if (match == null) return false;
    _applySelection(match);
    notifyListeners();
    return true;
  }

  void _applySelection(StoredTournament? tournament) {
    _selected = tournament;
    _crosstable = tournament == null
        ? null
        : buildCrosstable(tournament.config, tournament.games);
  }

  // ── Engines ──────────────────────────────────────────────────────────────

  /// Verify a candidate binary, then add it to the registry if it passes.
  ///
  /// The verification report comes back either way, so the caller can show
  /// exactly what went wrong when a file turns out not to be a UCI engine.
  Future<EngineVerification> addEngine(String path) async {
    final registry = _registry;
    if (registry == null) {
      return const EngineVerification(
        ok: false,
        message: 'Storage is not ready yet.',
      );
    }
    final report = await verifyUciEngine(path);
    if (!report.ok) return report;
    final spec = EngineSpec(
      id: newEngineId(),
      name: report.name.isEmpty
          ? p.basenameWithoutExtension(path)
          : report.name,
      executablePath: path,
    );
    _engines = await registry.add(spec);
    notifyListeners();
    return report;
  }

  /// Re-run the checks against an engine already in the registry.
  Future<EngineVerification> verifyEngine(EngineSpec spec) async {
    final path = spec.executablePath ?? await _bundledPath();
    return verifyUciEngine(path, arguments: spec.arguments);
  }

  /// Save an engine's settings. Works for the bundled entry too — its path
  /// stays runtime-resolved, only Hash/Threads/Ponder/options are stored.
  Future<void> updateEngine(EngineSpec spec) async {
    final registry = _registry;
    if (registry == null) return;
    _engines = await registry.update(spec);
    notifyListeners();
  }

  Future<void> removeEngine(String id) async {
    final registry = _registry;
    if (registry == null || id == EngineSpec.bundledId) return;
    _engines = await registry.remove(id);
    notifyListeners();
  }

  // ── Running ──────────────────────────────────────────────────────────────

  /// Create and play a tournament. Returns the finished state, or null when
  /// one is already running or storage never came up.
  Future<StoredTournament?> start(TournamentConfig config) async {
    final store = _store;
    if (store == null || _runner != null) return null;

    StoredTournament tournament;
    try {
      tournament = await store.create(config);
    } catch (e) {
      _error = 'Could not create the tournament: $e';
      notifyListeners();
      return null;
    }

    final runner = EngineTournamentRunner(
      store: store,
      resolveExecutable: (spec) async =>
          spec.executablePath ?? await _bundledPath(),
      onLog: (message) => log.i('[tournament] $message'),
    );
    _runner = runner;
    _runningId = tournament.id;
    _liveStatus = 'Starting…';
    _liveFen = config.startFen;
    _liveMoveLabel = '';
    _inFlight.clear();
    _liveSlot = null;
    _tournaments = [tournament, ..._tournaments];
    _applySelection(tournament);
    notifyListeners();

    final schedule = buildSchedule(config);

    try {
      final finished = await runner.run(
        tournament,
        onUpdate: (state) {
          _replaceTournament(state);
          if (_selected?.id == state.id) _applySelection(state);
          notifyListeners();
        },
        onGameStarted: (slot) {
          _inFlight.add(slot.index);
          if (_liveSlot == null) _adoptLiveSlot(slot, config);
          notifyListeners();
        },
        onGameFinished: (slot, _) {
          _inFlight.remove(slot.index);
          if (_liveSlot != slot.index) return;
          _liveSlot = null;
          final next = _inFlight.isEmpty
              ? null
              : _inFlight.reduce((a, b) => a < b ? a : b);
          if (next != null) _adoptLiveSlot(schedule[next], config);
          notifyListeners();
        },
        onMove: (slot, move) {
          if (slot.index != _liveSlot) return;
          _liveFen = move.fen;
          _liveMoveLabel = _describeMove(move);
          notifyListeners();
        },
      );
      return finished;
    } catch (e, st) {
      log.e('Tournament run failed', error: e, stackTrace: st);
      _error = '$e';
      return null;
    } finally {
      _runner = null;
      _runningId = null;
      _liveStatus = '';
      _liveFen = null;
      _liveMoveLabel = '';
      _inFlight.clear();
      _liveSlot = null;
      notifyListeners();
    }
  }

  void _adoptLiveSlot(ScheduledGame slot, TournamentConfig config) {
    final names = config.engines;
    _liveSlot = slot.index;
    _liveStatus =
        'Game ${slot.index + 1} of ${config.totalGames} — '
        '${names[slot.whiteIndex].name} vs ${names[slot.blackIndex].name}';
    _liveFen = config.startFen;
    _liveMoveLabel = '';
  }

  /// Stop after the games in flight finish their current move.
  void cancelRun() {
    _runner?.cancel();
    _liveStatus = 'Stopping…';
    notifyListeners();
  }

  Future<void> delete(String id) async {
    final store = _store;
    if (store == null || _runningId == id) return;
    await store.delete(id);
    _tournaments = _tournaments.where((t) => t.id != id).toList();
    if (_selected?.id == id) _applySelection(_tournaments.firstOrNull);
    notifyListeners();
  }

  void _replaceTournament(StoredTournament state) {
    final index = _tournaments.indexWhere((t) => t.id == state.id);
    final next = List.of(_tournaments);
    if (index < 0) {
      next.insert(0, state);
    } else {
      next[index] = state;
    }
    _tournaments = next;
  }

  Future<String> _bundledPath() => StockfishBundle.ensureExecutable();

  static String _describeMove(GameMoveEvent move) {
    final score = move.scoreMate != null
        ? '#${move.scoreMate}'
        : move.scoreCp != null
        ? '${move.scoreCp! >= 0 ? '+' : ''}${(move.scoreCp! / 100).toStringAsFixed(2)}'
        : '';
    final suffix = score.isEmpty ? '' : '  $score/${move.depth}';
    return '${move.moveNumber}${move.byWhite ? '.' : '...'} '
        '${move.san}$suffix';
  }

  @override
  void dispose() {
    _runner?.cancel();
    _refreshDebounce?.cancel();
    unawaited(_directoryWatch?.cancel());
    _directoryWatch = null;
    super.dispose();
  }
}
