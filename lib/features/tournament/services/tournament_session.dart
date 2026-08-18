/// Live state for one tournament: the roster, the simulation, the prep run.
///
/// Shared by the Tournament UI and the MCP bridge, so an agent editing the
/// roster and the user looking at it are always seeing the same thing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/app_paths.dart';
import '../../../utils/atomic_file.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/opponent_probability.dart';
import '../models/player_identity.dart';
import '../models/roster_entry.dart';
import 'clash_service.dart';
import 'event_simulator.dart';
import 'identity_resolver.dart';
import 'player_directory.dart';
import 'prep_export.dart';
import 'tournament_prep_service.dart';

/// Mixes in [SafeChangeNotifier] because prep runs are long-lived async work
/// started from the UI; without it a dispose during a run trips the
/// "used after being disposed" teardown race the boot test catches.
class TournamentSession extends ChangeNotifier with SafeChangeNotifier {
  static const _fileName = 'tournament_session.json';

  Roster _roster = const Roster();
  SimulationResult _simulation = SimulationResult.empty;
  TournamentPrepReport? _report;

  bool _isPreparing = false;
  PrepProgress? _progress;
  String? _lastError;

  TournamentPrepService? _prepService;

  Roster get roster => _roster;
  SimulationResult get simulation => _simulation;
  TournamentPrepReport? get report => _report;
  bool get isPreparing => _isPreparing;
  PrepProgress? get progress => _progress;
  String? get lastError => _lastError;

  // ── Roster mutation ────────────────────────────────────────────────────

  void setRoster(Roster roster) {
    _roster = roster;
    // Any previous run described a different field.
    _simulation = SimulationResult.empty;
    _report = null;
    notifyListeners();
  }

  /// Resolve identities against the bundled directory.
  ResolutionSummary resolveIdentities() {
    final summary = IdentityResolver.resolveRoster(
      _roster,
      directory: PlayerDirectory.instance,
    );
    _roster = summary.roster;
    notifyListeners();
    return summary;
  }

  void applyProposal({
    required String playerId,
    String? chesscomUsername,
    String? lichessUsername,
    required String evidence,
    IdentityConfidence confidence = IdentityConfidence.medium,
    List<String> alternates = const [],
  }) {
    _roster = IdentityResolver.applyProposal(
      _roster,
      playerId: playerId,
      chesscomUsername: chesscomUsername,
      lichessUsername: lichessUsername,
      evidence: evidence,
      confidence: confidence,
      alternates: alternates,
    );
    notifyListeners();
  }

  void confirmIdentity({
    required String playerId,
    String? chesscomUsername,
    String? lichessUsername,
  }) {
    _roster = IdentityResolver.confirm(
      _roster,
      playerId: playerId,
      chesscomUsername: chesscomUsername,
      lichessUsername: lichessUsername,
    );
    notifyListeners();
  }

  /// Apply a late change: a withdrawal, a maybe, a bye request, a fixed rating.
  /// Returns false when [playerId] is not on the roster.
  bool updateEntry(
    String playerId, {
    bool? withdrawn,
    double? attendanceProb,
    Set<int>? halfPointByeRounds,
    int? rating,
    bool? isMe,
  }) {
    final entry = _roster.entries.where((e) => e.id == playerId).firstOrNull;
    if (entry == null) return false;

    var next = _roster;
    if (isMe == true) {
      // Exactly one entrant can be us.
      next = next.copyWith(
        entries: next.entries
            .map((e) => e.isMe ? e.copyWith(isMe: false) : e)
            .toList(),
      );
    }

    final current = next.entries.firstWhere((e) => e.id == playerId);
    next = next.withEntry(
      current.copyWith(
        withdrawn: withdrawn,
        attendanceProb: attendanceProb,
        halfPointByeRounds: halfPointByeRounds,
        rating: rating,
        isMe: isMe,
      ),
    );

    _roster = next;
    notifyListeners();
    return true;
  }

  void addConstraint(String playerA, String playerB, {String? reason}) {
    _roster = _roster.copyWith(
      constraints: [
        ..._roster.constraints,
        PairingConstraint(playerA, playerB, reason: reason),
      ],
    );
    notifyListeners();
  }

  void setEventShape({String? eventName, int? rounds, bool? accelerated}) {
    _roster = _roster.copyWith(
      eventName: eventName,
      rounds: rounds,
      accelerated: accelerated,
    );
    notifyListeners();
  }

  // ── Simulation and prep ────────────────────────────────────────────────

  SimulationResult simulate({
    SimulationConfig config = const SimulationConfig(),
  }) {
    _simulation = EventSimulator.run(_roster, config: config);
    notifyListeners();
    return _simulation;
  }

  /// Run whole-event prep. Only one run at a time.
  Future<TournamentPrepReport> prepare({
    String? whiteRepertoirePath,
    String? blackRepertoirePath,
    ClashConfig clashConfig = const ClashConfig(),
    SimulationConfig simConfig = const SimulationConfig(),
    double minPairingProb = 0.05,
    int? maxOpponents,
  }) async {
    if (_isPreparing) {
      throw StateError('A prep run is already in progress.');
    }

    _isPreparing = true;
    _lastError = null;
    _progress = null;
    notifyListeners();

    try {
      final white = whiteRepertoirePath == null
          ? null
          : await TournamentPrepService.buildRepertoireTree(
              pgnPaths: [whiteRepertoirePath],
              isWhite: true,
            );
      final black = blackRepertoirePath == null
          ? null
          : await TournamentPrepService.buildRepertoireTree(
              pgnPaths: [blackRepertoirePath],
              isWhite: false,
            );

      final service = TournamentPrepService();
      _prepService = service;

      final report = await service.prepareEvent(
        roster: _roster,
        whiteRepertoire: white,
        blackRepertoire: black,
        clashConfig: clashConfig,
        simConfig: simConfig,
        minPairingProb: minPairingProb,
        maxOpponents: maxOpponents,
        onProgress: (p) {
          _progress = p;
          notifyListeners();
        },
      );

      _report = report;
      _simulation = report.simulation;
      return report;
    } catch (e) {
      _lastError = '$e';
      rethrow;
    } finally {
      _isPreparing = false;
      _prepService = null;
      _progress = null;
      notifyListeners();
    }
  }

  void cancelPrep() {
    _prepService?.cancel();
  }

  // ── Persistence ────────────────────────────────────────────────────────

  static Future<io.File> _sessionFile() async {
    final dir = await AppPaths.supportDirectory();
    return io.File(p.join(dir.path, _fileName));
  }

  /// Persist the roster so a tournament survives an app restart. The prep
  /// report is not saved — it is derived, and cheap enough to re-run once the
  /// opponents' games are already cached on disk.
  Future<void> save() async {
    _writing = true;
    try {
      final file = await _sessionFile();
      await writeTextFileAtomically(file, json.encode(_roster.toMap()));
    } catch (e) {
      // Persistence is a convenience, not the point of the call. Losing it
      // must not fail an import or an identity edit that otherwise succeeded.
      if (kDebugMode) debugPrint('[TournamentSession] save failed: $e');
    } finally {
      // Held briefly past the write so the watcher drops the events it
      // generated rather than reloading what we just wrote.
      Timer(const Duration(milliseconds: 400), () => _writing = false);
    }
  }

  Future<void> load() async {
    try {
      final file = await _sessionFile();
      if (!await file.exists()) return;
      final decoded =
          json.decode(await file.readAsString()) as Map<String, dynamic>;
      _roster = Roster.fromMap(decoded);
      notifyListeners();
    } catch (_) {
      // A corrupt session file must not stop the app booting; the user can
      // just import the entry list again.
    }
  }

  // ── Watching the shared roster ─────────────────────────────────────────

  StreamSubscription<io.FileSystemEvent>? _watch;
  Timer? _watchDebounce;

  /// True while we are writing, so our own change events are ignored.
  bool _writing = false;

  /// Reload whenever the standalone MCP server rewrites the roster.
  ///
  /// That server is a separate process editing the same file, so without this
  /// an agent resolving twenty accounts would leave the open app showing a
  /// stale field — the exact confusion a shared file is supposed to avoid.
  Future<void> startWatching() async {
    if (_watch != null) return;
    try {
      final file = await _sessionFile();
      final dir = file.parent;
      if (!await dir.exists()) return;

      // Watch the directory, not the file: an atomic rename replaces the
      // inode, and a file watch would follow the old one into oblivion.
      _watch = dir.watch(events: io.FileSystemEvent.all).listen((event) {
        if (!event.path.endsWith(_fileName)) return;
        if (_writing) return;
        // Writers are not atomic from our side of the fence; coalesce the
        // burst of events one save produces.
        _watchDebounce?.cancel();
        _watchDebounce = Timer(const Duration(milliseconds: 250), () => load());
      }, onError: (_) {});
    } catch (_) {
      // Watching is an optimization. Where it is unavailable the user can
      // still reopen the screen to pick up external edits.
    }
  }

  @override
  void dispose() {
    _watchDebounce?.cancel();
    unawaited(_watch?.cancel());
    super.dispose();
  }

  /// Repertoire PGNs available to clash against.
  static Future<List<String>> availableRepertoires() async {
    try {
      final dir = await AppPaths.repertoiresDirectory();
      if (!await dir.exists()) return const [];
      return dir
          .listSync()
          .whereType<io.File>()
          .map((f) => f.path)
          .where((path) => path.toLowerCase().endsWith('.pgn'))
          .toList()
        ..sort();
    } catch (_) {
      return const [];
    }
  }

  /// Export helpers, surfaced through both the UI and the MCP bridge.
  String exportPgn({int? limit}) =>
      _report == null ? '' : PrepExporter.toPgn(_report!, limit: limit);

  String exportBriefing({int limit = 10}) =>
      _report == null ? '' : PrepExporter.toBriefing(_report!, limit: limit);

  String exportRosterCsv() => PrepExporter.rosterToCsv(_roster);
}
